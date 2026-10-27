-- OptiMon — OptiMap Fase 4 (item 01): IMPORTAÇÃO DE POSTES DE REFERÊNCIA — staging/prévia.
--
-- Área de trabalho para importar o arquivo gerado pelo coletor por município
-- (tools/optimap/coletar_copel.mjs, formato `optimap-referencia-postes/1`) em
-- public.gis_postes_referencia SOMENTE depois de prévia, comparação, validação e aprovação.
--
-- Tabelas novas no schema `staging` (criado na Fase 4.1), separadas das de infraestrutura
-- da Fase 4.1 — aquelas têm tipo_entidade/tabela_oficial fechados em infra_* e não são
-- tocadas aqui:
--   staging.gis_importacoes          — 1 linha por arquivo recebido (escopo fonte+município).
--   staging.gis_importacao_itens     — 1 linha por poste do arquivo, já classificado, e 1 linha
--                                      por poste já cadastrado que NÃO veio no arquivo (AUSENTE).
--   staging.gis_importacao_alteracoes — log imutável do que a aprovação realmente gravou
--                                      (só os campos alterados: anterior/novo). É a base da
--                                      reversão seletiva.
--
-- Garantias desta migration (aditiva):
--   * Nenhuma tabela oficial de infraestrutura (cidades_infra, infra_*, contrato_fibras) é
--     alterada. gis_postes_referencia só ganha a FK de ultima_importacao_id (prevista na
--     Fase 2: "FK para o lote de importação entra na Fase 4").
--   * Nenhuma policy using(true). Leitura por perfil; NENHUMA escrita direta para
--     authenticated — tudo passa pelas funções app.gis_importacao_* (item 02).
--   * Nada é apagado: importações rejeitadas/descartadas/revertidas ficam para histórico.

-- ============================================================================
-- staging.gis_importacoes
-- ============================================================================
create table staging.gis_importacoes (
  id uuid primary key default gen_random_uuid(),
  fonte_id uuid not null references public.gis_fontes(id) on delete restrict,

  status text not null default 'RECEBIDA' check (status in (
    'RECEBIDA',               -- arquivo recebido, itens sendo carregados
    'PREVIA',                 -- itens classificados, aguardando revisão/aprovação
    'IMPORTADA',              -- aprovada e aplicada (atomicamente) em gis_postes_referencia
    'REJEITADA',              -- recusada pelo aprovador (motivo obrigatório)
    'DESCARTADA',             -- abandonada por quem enviou
    'REVERTIDA',              -- 100% das alterações desfeitas
    'REVERTIDA_PARCIALMENTE'  -- parte não pôde ser desfeita (ver motivo_nao_revertido)
  )),

  -- Escopo: o arquivo cobre UM município inteiro de UMA fonte. É o escopo usado para
  -- detectar postes ausentes (nunca apagados — viram NAO_LOCALIZADO_ULTIMA_COLETA).
  municipio_ibge char(7) not null check (municipio_ibge ~ '^[0-9]{7}$'),
  municipio_nome text not null,
  uf char(2) not null check (uf ~ '^[A-Z]{2}$'),
  -- Cidade da NICK correspondente (cidades_infra), quando existir. Só leitura de
  -- cidades_infra — nada é gravado lá.
  cidade_id uuid references public.cidades_infra(id) on delete restrict,

  -- Momento da coleta na fonte (metadado `coletado_em` do arquivo) = data_referencia dos postes.
  data_referencia timestamptz not null,

  arquivo_nome_original text not null,
  arquivo_hash text not null check (arquivo_hash ~ '^[0-9a-f]{64}$'),
  arquivo_tamanho_bytes bigint check (arquivo_tamanho_bytes is null or arquivo_tamanho_bytes >= 0),
  -- Bloco `optimap` do arquivo, como veio (contagens do coletor, limite municipal usado...).
  metadados jsonb not null default '{}'::jsonb check (jsonb_typeof(metadados) = 'object'),
  total_declarado integer check (total_declarado is null or total_declarado >= 0),
  total_recebido integer not null default 0 check (total_recebido >= 0),

  -- Resumo da prévia (contagens por classificação, alertas). Recalculado a cada processamento.
  resumo jsonb,
  processado_em timestamptz,

  criado_por uuid not null references public.usuarios(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),

  aprovado_por uuid references public.usuarios(id),
  aprovado_em timestamptz,
  rejeitado_por uuid references public.usuarios(id),
  rejeitado_em timestamptz,
  motivo_rejeicao text,
  descartado_por uuid references public.usuarios(id),
  descartado_em timestamptz,
  revertido_por uuid references public.usuarios(id),
  revertido_em timestamptz,
  motivo_reversao text,
  observacoes text,

  check ((aprovado_em is null) = (aprovado_por is null)),
  check (status <> 'IMPORTADA' or aprovado_em is not null),
  check ((rejeitado_em is null) = (rejeitado_por is null)),
  check (status <> 'REJEITADA' or (rejeitado_em is not null and length(btrim(coalesce(motivo_rejeicao, ''))) > 0)),
  check ((descartado_em is null) = (descartado_por is null)),
  check (status <> 'DESCARTADA' or descartado_em is not null),
  check ((revertido_em is null) = (revertido_por is null)),
  check (status not in ('REVERTIDA', 'REVERTIDA_PARCIALMENTE')
         or (revertido_em is not null and length(btrim(coalesce(motivo_reversao, ''))) > 0))
);

create index gis_importacoes_escopo_idx on staging.gis_importacoes (fonte_id, municipio_ibge, status);
create index gis_importacoes_criado_por_idx on staging.gis_importacoes (criado_por);
create index gis_importacoes_criado_em_idx on staging.gis_importacoes (criado_em desc);
-- Uma importação em aberto por escopo: evita duas prévias concorrentes do mesmo município
-- calculadas sobre o mesmo estado e aprovadas em sequência.
create unique index gis_importacoes_escopo_aberto_uidx on staging.gis_importacoes (fonte_id, municipio_ibge)
  where status in ('RECEBIDA', 'PREVIA');

create trigger trg_gis_importacoes_atualizado_em before update on staging.gis_importacoes
  for each row execute function public.set_atualizado_em();

comment on table staging.gis_importacoes is 'OptiMap Fase 4: 1 linha por arquivo de postes de referência recebido (escopo fonte+município). Fluxo RECEBIDA→PREVIA→IMPORTADA(→REVERTIDA/REVERTIDA_PARCIALMENTE), ou →REJEITADA/DESCARTADA antes de importar. Nunca apagada.';

-- ============================================================================
-- staging.gis_importacao_itens
-- ============================================================================
create table staging.gis_importacao_itens (
  id bigint generated always as identity primary key,
  importacao_id uuid not null references staging.gis_importacoes(id) on delete restrict,

  -- Posição do poste no arquivo (0..n-1). NULL só para AUSENTE (não veio no arquivo).
  linha integer check (linha is null or linha >= 0),

  -- Como veio no arquivo (nada inventado; texto bruto quando não conversível).
  id_externo text,
  lon double precision,
  lat double precision,
  situacao_fonte text,
  atributos_fonte jsonb not null default '{}'::jsonb check (jsonb_typeof(atributos_fonte) = 'object'),
  geom geometry(Point, 4326),

  classificacao text not null default 'PENDENTE' check (classificacao in (
    'PENDENTE',       -- carregado, ainda não processado
    'NOVO',           -- id_externo inexistente na fonte → será inserido
    'ATUALIZADO',     -- situação/atributo/posição mudou → será atualizado
    'SEM_ALTERACAO',  -- igual ao cadastrado → só renova data da coleta
    'INVALIDO',       -- sem número, coordenada ausente/inválida → nunca aplicado
    'DUPLICADO',      -- mesmo número repetido no arquivo → só a 1ª ocorrência vale
    'CONFLITO',       -- exige decisão humana (APLICAR/IGNORAR) antes da aprovação
    'AUSENTE'         -- cadastrado no escopo e ausente no arquivo → NAO_LOCALIZADO_ULTIMA_COLETA
  )),
  motivo text,                      -- motivo do INVALIDO/DUPLICADO/CONFLITO
  referencia_id uuid,               -- poste de referência existente correspondente (ou criado)
  retrato_md5 text,                 -- impressão do cadastrado no processamento (detecta mudança antes da aprovação)
  diffs jsonb,                      -- {campo: {anterior, novo}} para ATUALIZADO/CONFLITO
  distancia_m double precision,     -- deslocamento em relação ao cadastrado
  alertas jsonb not null default '[]'::jsonb check (jsonb_typeof(alertas) = 'array'),

  decisao text check (decisao in ('APLICAR', 'IGNORAR')),
  decidido_por uuid references public.usuarios(id),
  decidido_em timestamptz,

  check ((decisao is null) = (decidido_por is null)),
  check ((decidido_em is null) = (decidido_por is null)),
  check (decisao is null or classificacao = 'CONFLITO'),
  check (classificacao not in ('INVALIDO', 'DUPLICADO', 'CONFLITO') or motivo is not null),
  check ((classificacao = 'AUSENTE') = (linha is null)),
  check (classificacao not in ('ATUALIZADO', 'SEM_ALTERACAO', 'CONFLITO', 'AUSENTE') or referencia_id is not null)
);

create unique index gis_importacao_itens_linha_uidx on staging.gis_importacao_itens (importacao_id, linha) where linha is not null;
create index gis_importacao_itens_classificacao_idx on staging.gis_importacao_itens (importacao_id, classificacao);
create index gis_importacao_itens_id_externo_idx on staging.gis_importacao_itens (importacao_id, id_externo);
create index gis_importacao_itens_geom_gix on staging.gis_importacao_itens using gist (geom);
create index gis_importacao_itens_referencia_idx on staging.gis_importacao_itens (referencia_id) where referencia_id is not null;

comment on table staging.gis_importacao_itens is 'OptiMap Fase 4: cada poste do arquivo (classificado) + cada poste do escopo ausente no arquivo (AUSENTE). Correspondência SÓ por fonte + id_externo (Copel: num_seq_geo) — proximidade de coordenadas nunca une dois postes; no máximo gera alerta.';

-- ============================================================================
-- staging.gis_importacao_alteracoes — log imutável do que foi aplicado
-- ============================================================================
create table staging.gis_importacao_alteracoes (
  id bigint generated always as identity primary key,
  -- Ordinal real de aplicação; a reversão percorre em ordem decrescente.
  ordem bigserial not null,
  importacao_id uuid not null references staging.gis_importacoes(id) on delete restrict,
  item_id bigint not null references staging.gis_importacao_itens(id) on delete restrict,
  referencia_id uuid not null,      -- sem FK: a reversão de um INSERT remove a linha
  id_externo text not null,
  operacao text not null check (operacao in ('INSERT', 'UPDATE')),
  -- UPDATE: valor_anterior = campos que mudaram (com o valor de antes); valor_novo = {"md5"}
  -- dos valores novos desses campos. INSERT: valor_novo = {"md5"} do registro criado (o
  -- conteúdo vem do item + importação). Compacto de propósito: o plano Free do Supabase tem
  -- 500 MB e cada coleta das cidades gera uma linha por poste.
  valor_anterior jsonb,
  valor_novo jsonb not null check (jsonb_typeof(valor_novo -> 'md5') = 'string'),
  aplicado_em timestamptz not null default now(),
  aplicado_por uuid not null references public.usuarios(id),

  -- Únicos campos que podem mudar depois (reversão).
  revertido boolean not null default false,
  revertido_em timestamptz,
  revertido_por uuid references public.usuarios(id),
  motivo_nao_revertido text,

  check (operacao <> 'INSERT' or valor_anterior is null),
  check (operacao <> 'UPDATE' or valor_anterior is not null),
  check (revertido = false or (revertido_em is not null and revertido_por is not null))
);
create index gis_importacao_alteracoes_importacao_idx on staging.gis_importacao_alteracoes (importacao_id, ordem desc);
create index gis_importacao_alteracoes_item_idx on staging.gis_importacao_alteracoes (item_id);

comment on table staging.gis_importacao_alteracoes is 'OptiMap Fase 4: log imutável de cada INSERT/UPDATE aplicado em gis_postes_referencia por uma importação (campos alterados: anterior/novo). Base da reversão seletiva — nunca apagado.';

create or replace function staging.fn_gis_bloquear_alteracao_log()
returns trigger
language plpgsql
as $$
begin
  if new.importacao_id is distinct from old.importacao_id
     or new.item_id is distinct from old.item_id
     or new.ordem is distinct from old.ordem
     or new.referencia_id is distinct from old.referencia_id
     or new.id_externo is distinct from old.id_externo
     or new.operacao is distinct from old.operacao
     or new.valor_anterior is distinct from old.valor_anterior
     or new.valor_novo is distinct from old.valor_novo
     or new.aplicado_em is distinct from old.aplicado_em
     or new.aplicado_por is distinct from old.aplicado_por
     or (old.revertido and not new.revertido)
  then
    raise exception 'staging.gis_importacao_alteracoes: só os campos de reversão podem mudar — o restante é o registro imutável do que foi aplicado.';
  end if;
  return new;
end;
$$;

create trigger trg_gis_importacao_alteracoes_imutavel before update on staging.gis_importacao_alteracoes
  for each row execute function staging.fn_gis_bloquear_alteracao_log();
create trigger trg_gis_importacao_alteracoes_sem_delete before delete on staging.gis_importacao_alteracoes
  for each row execute function public.fn_bloquear_alteracao_auditoria();
create trigger trg_gis_importacoes_sem_delete before delete on staging.gis_importacoes
  for each row execute function public.fn_bloquear_alteracao_auditoria();

-- ============================================================================
-- FK prevista na Fase 2: poste de referência → importação que o gravou por último.
-- ============================================================================
alter table public.gis_postes_referencia
  add constraint gis_postes_referencia_ultima_importacao_fk
  foreign key (ultima_importacao_id) references staging.gis_importacoes(id) on delete restrict;
-- Sem índice em ultima_importacao_id de propósito: importações nunca são apagadas (trigger),
-- então a FK não precisa dele, e um índice nessa coluna impediria atualizações HOT a cada
-- coleta (toda confirmação muda essa coluna) — mais inchaço de índice no plano Free.

-- ============================================================================
-- Privilégios e RLS
-- ============================================================================
revoke all on staging.gis_importacoes, staging.gis_importacao_itens, staging.gis_importacao_alteracoes from public, anon, authenticated;
grant select on staging.gis_importacoes, staging.gis_importacao_itens, staging.gis_importacao_alteracoes to authenticated;
revoke all on sequence staging.gis_importacao_alteracoes_ordem_seq from public, anon, authenticated;

alter table staging.gis_importacoes enable row level security;
alter table staging.gis_importacao_itens enable row level security;
alter table staging.gis_importacao_alteracoes enable row level security;

-- Mesma matriz da Fase 4.1: ADMINISTRADOR e DIRETOR veem tudo (aprovam/revertem);
-- ENGENHARIA vê as próprias; demais perfis, nada.
create policy gis_importacoes_select on staging.gis_importacoes for select to authenticated
  using (
    (select app.tem_perfil('ADMINISTRADOR', 'DIRETOR'))
    or ((select app.tem_perfil('ENGENHARIA')) and criado_por = (select auth.uid()))
  );
create policy gis_importacao_itens_select on staging.gis_importacao_itens for select to authenticated
  using (exists (select 1 from staging.gis_importacoes i where i.id = gis_importacao_itens.importacao_id));
create policy gis_importacao_alteracoes_select on staging.gis_importacao_alteracoes for select to authenticated
  using (exists (select 1 from staging.gis_importacoes i where i.id = gis_importacao_alteracoes.importacao_id));
-- Nenhuma policy de INSERT/UPDATE/DELETE: escrita só via app.gis_importacao_* (SECURITY DEFINER).
