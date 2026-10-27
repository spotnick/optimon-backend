-- OptiMon — OptiMap Fase 5 (item 01): empresas ocupantes e ocupações de postes.
--
-- Aprovado pelo usuário em 27/10/2026. Aditiva: nenhuma tabela oficial de infraestrutura é
-- alterada; nenhuma tabela/função anterior é removida.
--
--   public.gis_empresas         — empresas do grupo com contrato de compartilhamento com a Copel.
--   public.gis_ocupacoes        — "a empresa X ocupa o poste N":
--                                   PROJETO_APROVADO (origem CES — lista oficial da Copel) ou
--                                   SEM_PROJETO (origem MARCACAO — engenharia marca no mapa).
--                                 Nada é apagado: ausência na lista do CES vira
--                                 NAO_CONSTA_ULTIMA_LISTA; marcação desfeita vira ENCERRADA.
--   staging.gis_ces_*           — importação da lista do CES com prévia/aprovação/reversão
--                                 (mesmo desenho da Fase 4).
--
-- A ocupação é ligada ao poste pelo NÚMERO do poste Copel (id_externo = num_seq_geo) e, quando
-- existe, ao poste de referência do mapa público (poste_referencia_id). Nunca por proximidade.

-- ============================================================================
-- Fonte CES (externa: dado da Copel, acessado com o login da própria empresa)
-- ============================================================================
insert into public.gis_fontes (codigo, nome, tipo, descricao, url_origem, termos_uso, atribuicao, permite_redistribuicao, observacoes)
values ('COPEL_CES', 'CES — Compartilhamento de Estruturas (Copel)', 'EXTERNA',
        'Pontos (postes) com projeto aprovado da empresa ocupante, conforme o sistema CES da Copel.',
        'https://www.copel.com/cesweb/',
        'Dado da própria empresa ocupante, consultado com o login dela no CES. Uso interno; não redistribuir. A coleta filtra apenas a empresa selecionada no CES — dados de outras empresas não são baixados.',
        'Copel — CES', false, 'Coleta pelo navegador, na sessão do usuário, com a empresa selecionada no CES.')
on conflict (codigo) do nothing;

-- ============================================================================
-- public.gis_empresas
-- ============================================================================
create table public.gis_empresas (
  id uuid primary key default gen_random_uuid(),
  razao_social text not null check (length(btrim(razao_social)) > 0),
  nome_fantasia text,
  cnpj char(14) not null check (cnpj ~ '^[0-9]{14}$'),
  uc_copel text check (uc_copel is null or uc_copel ~ '^[0-9]{1,20}$'),
  contrato_copel text,
  ativa boolean not null default true,
  observacoes text,
  criado_por uuid references public.usuarios(id) default auth.uid(),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint gis_empresas_cnpj_key unique (cnpj)
);
create trigger trg_gis_empresas_atualizado_em before update on public.gis_empresas
  for each row execute function public.set_atualizado_em();
create trigger trg_auditoria_gis_empresas after insert or update or delete on public.gis_empresas
  for each row execute function public.fn_auditoria();
comment on table public.gis_empresas is 'OptiMap Fase 5: empresas do grupo com contrato de compartilhamento de postes com a Copel (uma linha por CNPJ). Edição só por ADMINISTRADOR (app.gis_empresa_salvar).';

-- Empresas informadas pelo usuário (27/10/2026). Número do contrato fica para o cadastro na tela.
insert into public.gis_empresas (razao_social, nome_fantasia, cnpj, uc_copel, criado_por)
values ('RODRIGO BORGHI DA SILVA CIA LTDA', 'NICK NETWORK', '08930086000163', '515903403178', null),
       ('AYOTECH TELECOMUNICACOES LTDA', 'AYOTECH', '30353855000167', '638231603159', null)
on conflict (cnpj) do nothing;

-- ============================================================================
-- staging.gis_ces_importacoes (criada antes de gis_ocupacoes por causa da FK)
-- ============================================================================
create table staging.gis_ces_importacoes (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.gis_empresas(id) on delete restrict,
  status text not null default 'RECEBIDA' check (status in (
    'RECEBIDA', 'PREVIA', 'IMPORTADA', 'REJEITADA', 'DESCARTADA', 'REVERTIDA', 'REVERTIDA_PARCIALMENTE')),
  data_referencia timestamptz not null,
  arquivo_nome_original text not null,
  arquivo_hash text not null check (arquivo_hash ~ '^[0-9a-f]{64}$'),
  arquivo_tamanho_bytes bigint check (arquivo_tamanho_bytes is null or arquivo_tamanho_bytes >= 0),
  metadados jsonb not null default '{}'::jsonb check (jsonb_typeof(metadados) = 'object'),
  total_declarado integer check (total_declarado is null or total_declarado >= 0),
  total_recebido integer not null default 0 check (total_recebido >= 0),
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
create index gis_ces_importacoes_empresa_idx on staging.gis_ces_importacoes (empresa_id, status);
create index gis_ces_importacoes_criado_em_idx on staging.gis_ces_importacoes (criado_em desc);
create unique index gis_ces_importacoes_aberta_uidx on staging.gis_ces_importacoes (empresa_id)
  where status in ('RECEBIDA', 'PREVIA');
create trigger trg_gis_ces_importacoes_atualizado_em before update on staging.gis_ces_importacoes
  for each row execute function public.set_atualizado_em();
create trigger trg_gis_ces_importacoes_sem_delete before delete on staging.gis_ces_importacoes
  for each row execute function public.fn_bloquear_alteracao_auditoria();
comment on table staging.gis_ces_importacoes is 'OptiMap Fase 5: 1 linha por lista do CES recebida (escopo = empresa). RECEBIDA→PREVIA→IMPORTADA(→REVERTIDA[_PARCIALMENTE]) ou →REJEITADA/DESCARTADA. Nunca apagada.';

-- ============================================================================
-- public.gis_ocupacoes
-- ============================================================================
create table public.gis_ocupacoes (
  id uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.gis_empresas(id) on delete restrict,
  id_externo text not null check (length(btrim(id_externo)) > 0),
  poste_referencia_id uuid references public.gis_postes_referencia(id) on delete restrict,
  geom geometry(Point, 4326) not null check (app.gis_coordenada_valida(geom)),
  tipo text not null check (tipo in ('PROJETO_APROVADO', 'SEM_PROJETO')),
  origem text not null check (origem in ('CES', 'MARCACAO')),
  estado text not null default 'ATIVA' check (estado in ('ATIVA', 'NAO_CONSTA_ULTIMA_LISTA', 'ENCERRADA')),
  data_referencia timestamptz not null default now(),
  ultima_importacao_id uuid references staging.gis_ces_importacoes(id) on delete restrict,
  motivo text,
  criado_por uuid references public.usuarios(id) default auth.uid(),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  encerrado_por uuid references public.usuarios(id),
  encerrado_em timestamptz,
  motivo_encerramento text,
  check ((origem = 'CES') = (tipo = 'PROJETO_APROVADO')),
  check (origem <> 'MARCACAO' or length(btrim(coalesce(motivo, ''))) >= 3),
  check (estado <> 'NAO_CONSTA_ULTIMA_LISTA' or origem = 'CES'),
  check ((estado = 'ENCERRADA') = (encerrado_em is not null)),
  check (estado <> 'ENCERRADA' or length(btrim(coalesce(motivo_encerramento, ''))) > 0)
);
-- No máximo uma ocupação viva por empresa + poste + tipo.
create unique index gis_ocupacoes_viva_uidx on public.gis_ocupacoes (empresa_id, id_externo, tipo) where estado <> 'ENCERRADA';
create index gis_ocupacoes_referencia_ativa_idx on public.gis_ocupacoes (poste_referencia_id) where estado = 'ATIVA';
create index gis_ocupacoes_id_externo_idx on public.gis_ocupacoes (id_externo);
create index gis_ocupacoes_empresa_idx on public.gis_ocupacoes (empresa_id, tipo, estado);
create index gis_ocupacoes_geom_gix on public.gis_ocupacoes using gist (geom);
create trigger trg_gis_ocupacoes_atualizado_em before update on public.gis_ocupacoes
  for each row execute function public.set_atualizado_em();
-- Auditoria linha a linha só das MARCAÇÕES (poucas, feitas à mão). As ocupações do CES
-- (milhares por lista) são rastreadas pelo lote de importação + log de alterações.
create trigger trg_auditoria_gis_ocupacoes_marcacao_ins after insert on public.gis_ocupacoes
  for each row when (new.origem = 'MARCACAO') execute function public.fn_auditoria();
create trigger trg_auditoria_gis_ocupacoes_marcacao_upd after update on public.gis_ocupacoes
  for each row when (new.origem = 'MARCACAO') execute function public.fn_auditoria();
create trigger trg_gis_ocupacoes_marcacao_sem_delete before delete on public.gis_ocupacoes
  for each row when (old.origem = 'MARCACAO') execute function public.fn_bloquear_alteracao_auditoria();
comment on table public.gis_ocupacoes is 'OptiMap Fase 5: ocupação de um poste Copel por uma empresa do grupo. PROJETO_APROVADO vem do CES (importação); SEM_PROJETO é marcado pela engenharia no mapa. Ligação pelo número do poste (id_externo), nunca por proximidade.';

-- ============================================================================
-- staging.gis_ces_itens / staging.gis_ces_alteracoes
-- ============================================================================
create table staging.gis_ces_itens (
  id bigint generated always as identity primary key,
  importacao_id uuid not null references staging.gis_ces_importacoes(id) on delete restrict,
  linha integer check (linha is null or linha >= 0),          -- null só para AUSENTE
  id_externo text,
  lon double precision,
  lat double precision,
  geom geometry(Point, 4326),
  classificacao text not null default 'PENDENTE' check (classificacao in (
    'PENDENTE', 'NOVA', 'MANTIDA', 'REATIVADA', 'INVALIDO', 'DUPLICADO', 'AUSENTE')),
  motivo text,
  ocupacao_id uuid,            -- ocupação existente correspondente (MANTIDA/REATIVADA/AUSENTE)
  referencia_id uuid,          -- poste do mapa público com o mesmo número (se existir)
  retrato_md5 text,
  alertas jsonb not null default '[]'::jsonb check (jsonb_typeof(alertas) = 'array'),
  check ((classificacao = 'AUSENTE') = (linha is null)),
  check (classificacao not in ('INVALIDO', 'DUPLICADO') or motivo is not null),
  check (classificacao not in ('MANTIDA', 'REATIVADA', 'AUSENTE') or ocupacao_id is not null)
);
create unique index gis_ces_itens_linha_uidx on staging.gis_ces_itens (importacao_id, linha) where linha is not null;
create index gis_ces_itens_classificacao_idx on staging.gis_ces_itens (importacao_id, classificacao);
create index gis_ces_itens_id_externo_idx on staging.gis_ces_itens (importacao_id, id_externo);
create index gis_ces_itens_ocupacao_idx on staging.gis_ces_itens (ocupacao_id) where ocupacao_id is not null;

create table staging.gis_ces_alteracoes (
  id bigint generated always as identity primary key,
  ordem bigserial not null,
  importacao_id uuid not null references staging.gis_ces_importacoes(id) on delete restrict,
  item_id bigint not null references staging.gis_ces_itens(id) on delete restrict,
  ocupacao_id uuid not null,   -- sem FK: a reversão de um INSERT remove a ocupação
  id_externo text not null,
  operacao text not null check (operacao in ('INSERT', 'UPDATE')),
  valor_anterior jsonb,
  valor_novo jsonb not null check (jsonb_typeof(valor_novo -> 'md5') = 'string'),
  aplicado_em timestamptz not null default now(),
  aplicado_por uuid not null references public.usuarios(id),
  revertido boolean not null default false,
  revertido_em timestamptz,
  revertido_por uuid references public.usuarios(id),
  motivo_nao_revertido text,
  check (operacao <> 'INSERT' or valor_anterior is null),
  check (operacao <> 'UPDATE' or valor_anterior is not null),
  check (revertido = false or (revertido_em is not null and revertido_por is not null))
);
create index gis_ces_alteracoes_importacao_idx on staging.gis_ces_alteracoes (importacao_id, ordem desc);
create index gis_ces_alteracoes_item_idx on staging.gis_ces_alteracoes (item_id);

create or replace function staging.fn_gis_ces_bloquear_alteracao_log()
returns trigger
language plpgsql
as $$
begin
  if new.importacao_id is distinct from old.importacao_id or new.item_id is distinct from old.item_id
     or new.ordem is distinct from old.ordem or new.ocupacao_id is distinct from old.ocupacao_id
     or new.id_externo is distinct from old.id_externo or new.operacao is distinct from old.operacao
     or new.valor_anterior is distinct from old.valor_anterior or new.valor_novo is distinct from old.valor_novo
     or new.aplicado_em is distinct from old.aplicado_em or new.aplicado_por is distinct from old.aplicado_por
     or (old.revertido and not new.revertido)
  then
    raise exception 'staging.gis_ces_alteracoes: só os campos de reversão podem mudar — o restante é o registro imutável do que foi aplicado.';
  end if;
  return new;
end;
$$;
create trigger trg_gis_ces_alteracoes_imutavel before update on staging.gis_ces_alteracoes
  for each row execute function staging.fn_gis_ces_bloquear_alteracao_log();
create trigger trg_gis_ces_alteracoes_sem_delete before delete on staging.gis_ces_alteracoes
  for each row execute function public.fn_bloquear_alteracao_auditoria();

-- ============================================================================
-- Privilégios e RLS
-- ============================================================================
revoke all on public.gis_empresas, public.gis_ocupacoes from public, anon, authenticated;
grant select on public.gis_empresas, public.gis_ocupacoes to authenticated;
alter table public.gis_empresas enable row level security;
alter table public.gis_ocupacoes enable row level security;
-- Decisão do usuário: todos os perfis que veem o mapa veem as ocupações de todas as empresas.
create policy gis_empresas_select on public.gis_empresas for select to authenticated using ((select app.gis_pode_ver()));
create policy gis_ocupacoes_select on public.gis_ocupacoes for select to authenticated using ((select app.gis_pode_ver()));
-- Sem policy de escrita: tudo via app.gis_empresa_salvar / app.gis_ocupacao_* / app.gis_ces_*.

revoke all on staging.gis_ces_importacoes, staging.gis_ces_itens, staging.gis_ces_alteracoes from public, anon, authenticated;
grant select on staging.gis_ces_importacoes, staging.gis_ces_itens, staging.gis_ces_alteracoes to authenticated;
revoke all on sequence staging.gis_ces_alteracoes_ordem_seq from public, anon, authenticated;
alter table staging.gis_ces_importacoes enable row level security;
alter table staging.gis_ces_itens enable row level security;
alter table staging.gis_ces_alteracoes enable row level security;
create policy gis_ces_importacoes_select on staging.gis_ces_importacoes for select to authenticated
  using (
    (select app.tem_perfil('ADMINISTRADOR', 'DIRETOR'))
    or ((select app.tem_perfil('ENGENHARIA')) and criado_por = (select auth.uid()))
  );
create policy gis_ces_itens_select on staging.gis_ces_itens for select to authenticated
  using (exists (select 1 from staging.gis_ces_importacoes i where i.id = gis_ces_itens.importacao_id));
create policy gis_ces_alteracoes_select on staging.gis_ces_alteracoes for select to authenticated
  using (exists (select 1 from staging.gis_ces_importacoes i where i.id = gis_ces_alteracoes.importacao_id));
