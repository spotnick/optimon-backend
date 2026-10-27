-- OptiMon — Fase 4.1 (item 01): IMPORTAÇÃO DE INFRAESTRUTURA — schema de staging/prévia.
--
-- Cria um schema NOVO (`staging`), paralelo a `app`/`public`, com 3 tabelas. Nenhuma
-- coluna nova em tabela oficial (cidades_infra/infra_pops/infra_segmentos/infra_cabos/
-- infra_fibras/infra_postes/infra_portas_pon/contrato_clientes_reservados) — o objetivo
-- explícito desta feature é que NENHUM dado importado altere infraestrutura oficial antes
-- de aprovação explícita (APROVAR E IMPORTAR), então a área de trabalho fica inteiramente
-- separada.
--
-- staging.importacoes         — 1 linha por levantamento recebido (metadados + status).
-- staging.importacao_itens    — 1 linha por registro da planilha, já classificado
--                                (NOVO/ALTERADO/SEM_ALTERACAO/CONFLITO/INVALIDO).
-- staging.importacao_alteracoes — log imutável de toda alteração REAL aplicada em tabela
--                                oficial na aprovação — é o que torna a reversão seletiva
--                                (por importação, sem afetar o resto) possível.
--
-- Chaves naturais: NENHUMA constraint UNIQUE nova é criada em infra_segmentos/infra_postes
-- (que hoje não têm chave natural) só para facilitar o casamento planilha↔oficial — toda
-- lógica de correspondência fica na camada de staging (chave_natural jsonb em
-- importacao_itens), nunca em constraint de tabela oficial.
--
-- RLS: nenhuma policy usa `using (true)`. SELECT é escopado por perfil (ENGENHARIA só vê
-- as próprias importações; ADMINISTRADOR vê tudo; DIRETOR vê tudo, mas só para
-- visualizar/aprovar/reverter; COMERCIAL/FINANCEIRO/AUDITOR não têm policy = sem acesso).
-- Não existe NENHUMA policy de INSERT/UPDATE/DELETE para `authenticated` em nenhuma das 3
-- tabelas — toda escrita acontece exclusivamente através de funções SECURITY DEFINER em
-- `app.*` (Migrations seguintes desta fase), que fazem sua própria checagem de perfil via
-- app.tem_perfil(...) antes de agir — mesmo padrão já usado em app.restaurar_* e nos
-- registros de documentos_assinados/propostas_documentos_assinados. Isso dá uma única
-- superfície de escrita controlada e auditável, em vez de RLS de tabela tentando expressar
-- uma máquina de estados inteira.

create schema if not exists staging;
comment on schema staging is 'Fase 4.1: área de prévia/staging para importação de infraestrutura — nenhum dado aqui é oficial até aprovação explícita (app.aplicar_importacao).';

grant usage on schema staging to authenticated;

-- ============================================================================
-- staging.importacoes
-- ============================================================================
create table staging.importacoes (
  id uuid primary key default gen_random_uuid(),

  status text not null default 'RECEBIDA' check (status in (
    'RECEBIDA', 'EM_VALIDACAO', 'PREVIA', 'APROVADA', 'IMPORTADA',
    'REJEITADA', 'DESCARTADA', 'REVERTIDA', 'REVERTIDA_PARCIALMENTE'
  )),

  -- Metadados obrigatórios (spec: usuário, timestamp, arquivo original, hash, nº registros).
  criado_por uuid not null references public.usuarios(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),

  arquivo_nome_original text not null,
  arquivo_storage_path text not null,
  arquivo_hash text not null,
  arquivo_tamanho_bytes bigint check (arquivo_tamanho_bytes is null or arquivo_tamanho_bytes >= 0),
  total_registros integer check (total_registros is null or total_registros >= 0),

  -- Resultado agregado da validação automática (contagens por classificação, alertas,
  -- inconsistências) — o que a tela de prévia lê para montar o resumo/cidades/rotas/
  -- fibras/POPs/portas PON/postes/clientes reservados/inconsistências/alertas.
  resultado_validacao jsonb,

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
  check ((rejeitado_em is null) = (rejeitado_por is null)),
  check (status <> 'REJEITADA' or motivo_rejeicao is not null),
  check ((descartado_em is null) = (descartado_por is null)),
  check (status <> 'DESCARTADA' or descartado_por is not null),
  check ((revertido_em is null) = (revertido_por is null)),
  check (status not in ('REVERTIDA', 'REVERTIDA_PARCIALMENTE') or (revertido_em is not null and motivo_reversao is not null))
);

create index importacoes_status_idx on staging.importacoes (status);
create index importacoes_criado_por_idx on staging.importacoes (criado_por);
create index importacoes_criado_em_idx on staging.importacoes (criado_em desc);

create trigger trg_importacoes_atualizado_em before update on staging.importacoes
  for each row execute function public.set_atualizado_em();

comment on table staging.importacoes is 'Fase 4.1: 1 linha por levantamento de infraestrutura recebido. status é o único controle de fluxo (RECEBIDA→EM_VALIDACAO→PREVIA→APROVADA→IMPORTADA, ou →REJEITADA/DESCARTADA a qualquer momento antes de IMPORTADA, ou IMPORTADA→REVERTIDA/REVERTIDA_PARCIALMENTE). Nenhuma linha é apagada — mesmo REJEITADA/DESCARTADA ficam para histórico.';
comment on column staging.importacoes.arquivo_storage_path is 'Caminho do arquivo original no Storage — reaproveita o bucket privado `documentos` já existente (Fase 2.5), prefixo novo levantamentos/{importacao_id}/{uuid}-{nome}. Nunca uma 2ª cópia do binário no Postgres.';
comment on column staging.importacoes.arquivo_hash is 'SHA-256 do arquivo original — permite detectar reenvio do mesmo arquivo e comprovar integridade em auditoria.';
comment on column staging.importacoes.resultado_validacao is 'Resumo agregado (jsonb) que alimenta a tela de prévia: contagens por classificação (novo/alterado/sem_alteracao/conflito/invalido), por tipo de entidade, lista de alertas de regra de negócio (ex.: fibra OCUPADA+disponível=SIM).';

-- ============================================================================
-- staging.importacao_itens
-- ============================================================================
create table staging.importacao_itens (
  id uuid primary key default gen_random_uuid(),
  importacao_id uuid not null references staging.importacoes(id) on delete cascade,

  tipo_entidade text not null check (tipo_entidade in (
    'CIDADE', 'POP', 'SEGMENTO', 'CABO', 'FIBRA', 'POSTE', 'PORTA_PON', 'CLIENTE_RESERVADO'
  )),

  -- Nº da linha na planilha de origem — rastreabilidade para o usuário corrigir o arquivo.
  linha_planilha integer,

  -- Chave natural usada para casar com o registro oficial (ex.: {"cidade_nome":"...",
  -- "uf":"..."} para CIDADE; {"cidade_id":"...","codigo":"POP-02"} para POP). Vive só aqui —
  -- nenhuma tabela oficial ganha constraint nova por causa disso.
  chave_natural jsonb not null,

  -- Linha da planilha já normalizada (nomes de coluna internos, tipos convertidos).
  dados_planilha jsonb not null,

  -- Casamento com o oficial, quando existir.
  entidade_oficial_id uuid,
  dados_oficiais_atuais jsonb,

  classificacao text not null check (classificacao in (
    'NOVO', 'ALTERADO', 'SEM_ALTERACAO', 'CONFLITO', 'INVALIDO'
  )),

  -- Diferenças campo a campo (old vs new) para ALTERADO/CONFLITO — nunca overwrite silencioso.
  diffs jsonb,

  -- Alertas de regra de negócio desta linha (ex.: "PAÇO não é POP", "fibra OCUPADA com
  -- disponível=SIM é inválido", "poste com projeto_aprovado=NÃO mantém rede existente").
  alertas jsonb not null default '[]'::jsonb,

  valido boolean not null default true,
  motivo_invalido text,

  -- true depois que app.aplicar_importacao realmente gravou este item na tabela oficial.
  aplicado boolean not null default false,

  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),

  check (classificacao <> 'INVALIDO' or motivo_invalido is not null),
  check (classificacao <> 'INVALIDO' or valido = false),
  check (classificacao in ('ALTERADO', 'CONFLITO') or diffs is null or diffs = '[]'::jsonb),
  check (classificacao <> 'NOVO' or entidade_oficial_id is null)
);

create index importacao_itens_importacao_idx on staging.importacao_itens (importacao_id);
create index importacao_itens_tipo_idx on staging.importacao_itens (importacao_id, tipo_entidade);
create index importacao_itens_classificacao_idx on staging.importacao_itens (importacao_id, classificacao);
create index importacao_itens_entidade_oficial_idx on staging.importacao_itens (entidade_oficial_id) where entidade_oficial_id is not null;

create trigger trg_importacao_itens_atualizado_em before update on staging.importacao_itens
  for each row execute function public.set_atualizado_em();

comment on table staging.importacao_itens is 'Fase 4.1: 1 linha por registro da planilha, já classificado. CONFLITO/INVALIDO nunca são aplicados em app.aplicar_importacao — ficam bloqueando a importação em PREVIA até o usuário corrigir/reenviar ou a importação ser rejeitada/descartada.';
comment on column staging.importacao_itens.chave_natural is 'Campos usados para casar esta linha com um registro oficial (varia por tipo_entidade) — mecanismo de matching vive inteiramente aqui, nunca em constraint de tabela oficial.';

-- ============================================================================
-- staging.importacao_alteracoes — log imutável de alterações realmente aplicadas
-- ============================================================================
create table staging.importacao_alteracoes (
  id uuid primary key default gen_random_uuid(),
  -- Ordinal monotônico real (bigserial), distinto de aplicado_em: dentro de uma mesma
  -- transação de app.aplicar_importacao, now() retorna o MESMO instante para todos os
  -- itens aplicados, então aplicado_em sozinho não serve para ordenar a reversão quando
  -- há dependência entre tabelas (ex.: CABO referencia SEGMENTO por FK — reverter o
  -- SEGMENTO antes do CABO nesse caso quebra a constraint). ordem sempre cresce em ordem
  -- de inserção real, então app.reverter_importacao usa "order by ordem desc" para
  -- desfazer sempre na ordem inversa exata da aplicação, nunca por timestamp empatado.
  ordem bigserial not null,
  importacao_id uuid not null references staging.importacoes(id) on delete restrict,
  importacao_item_id uuid not null references staging.importacao_itens(id) on delete restrict,

  tabela_oficial text not null check (tabela_oficial in (
    'cidades_infra', 'infra_pops', 'infra_segmentos', 'infra_cabos', 'infra_fibras',
    'infra_postes', 'infra_portas_pon', 'contrato_clientes_reservados'
  )),
  registro_id uuid not null,
  operacao text not null check (operacao in ('INSERT', 'UPDATE')),

  valor_anterior jsonb,
  valor_novo jsonb not null,

  aplicado_em timestamptz not null default now(),
  aplicado_por uuid not null references public.usuarios(id),

  -- Preenchidos só na reversão — únicas colunas desta tabela que uma linha existente pode
  -- receber update (ver trg_importacao_alteracoes_imutavel abaixo).
  revertido boolean not null default false,
  revertido_em timestamptz,
  revertido_por uuid references public.usuarios(id),
  motivo_nao_revertido text,

  check (operacao <> 'INSERT' or valor_anterior is null),
  check (operacao <> 'UPDATE' or valor_anterior is not null),
  check (revertido = false or revertido_em is not null)
);

create index importacao_alteracoes_importacao_idx on staging.importacao_alteracoes (importacao_id);
create index importacao_alteracoes_registro_idx on staging.importacao_alteracoes (tabela_oficial, registro_id);

comment on table staging.importacao_alteracoes is 'Fase 4.1: log imutável de cada INSERT/UPDATE real aplicado em tabela oficial por uma aprovação de importação — nunca apagado. É o mecanismo que permite reverter SÓ as mudanças desta importação, sem tocar em nada aplicado por outra importação ou editado manualmente depois.';
comment on column staging.importacao_alteracoes.motivo_nao_revertido is 'Preenchido quando a reversão não conseguiu desfazer este item específico (ex.: registro foi alterado por outra importação/edição manual depois da aplicação) — a reversão de outros itens da mesma importação continua normalmente; ver Migration 4 (app.reverter_importacao).';

-- Imutabilidade parcial: qualquer campo pode ser alterado livremente só ANTES de existir a
-- linha (não se aplica a INSERT); depois de inserida, só revertido/revertido_em/
-- revertido_por/motivo_nao_revertido podem mudar — todo o resto (o que foi de fato
-- aplicado) é fixo para sempre, exatamente como public.auditoria.
create or replace function staging.fn_bloquear_alteracao_importacao_alteracoes()
returns trigger
language plpgsql
as $$
begin
  if new.importacao_id is distinct from old.importacao_id
     or new.importacao_item_id is distinct from old.importacao_item_id
     or new.tabela_oficial is distinct from old.tabela_oficial
     or new.registro_id is distinct from old.registro_id
     or new.operacao is distinct from old.operacao
     or new.valor_anterior is distinct from old.valor_anterior
     or new.valor_novo is distinct from old.valor_novo
     or new.aplicado_em is distinct from old.aplicado_em
     or new.aplicado_por is distinct from old.aplicado_por
  then
    raise exception 'staging.importacao_alteracoes: só os campos de reversão (revertido, revertido_em, revertido_por, motivo_nao_revertido) podem ser alterados após o registro existir — o restante é o log imutável do que foi realmente aplicado.';
  end if;
  return new;
end;
$$;

create trigger trg_importacao_alteracoes_imutavel before update on staging.importacao_alteracoes
  for each row execute function staging.fn_bloquear_alteracao_importacao_alteracoes();

create trigger trg_importacao_alteracoes_bloquear_delete before delete on staging.importacao_alteracoes
  for each row execute function public.fn_bloquear_alteracao_auditoria();

-- ============================================================================
-- RLS — perfil-scoped, nunca using(true) (ver comentário no topo do arquivo).
-- ============================================================================
alter table staging.importacoes enable row level security;
alter table staging.importacao_itens enable row level security;
alter table staging.importacao_alteracoes enable row level security;

create policy importacoes_select on staging.importacoes for select to authenticated
  using (
    app.tem_perfil('ADMINISTRADOR', 'DIRETOR')
    or (app.tem_perfil('ENGENHARIA') and criado_por = auth.uid())
  );

create policy importacao_itens_select on staging.importacao_itens for select to authenticated
  using (
    exists (
      select 1 from staging.importacoes i
      where i.id = importacao_itens.importacao_id
        and (
          app.tem_perfil('ADMINISTRADOR', 'DIRETOR')
          or (app.tem_perfil('ENGENHARIA') and i.criado_por = auth.uid())
        )
    )
  );

create policy importacao_alteracoes_select on staging.importacao_alteracoes for select to authenticated
  using (
    exists (
      select 1 from staging.importacoes i
      where i.id = importacao_alteracoes.importacao_id
        and (
          app.tem_perfil('ADMINISTRADOR', 'DIRETOR')
          or (app.tem_perfil('ENGENHARIA') and i.criado_por = auth.uid())
        )
    )
  );

comment on policy importacoes_select on staging.importacoes is 'Fase 4.1 (condição do usuário): ADMINISTRADOR vê tudo; DIRETOR vê tudo (só visualização/aprovação/reversão, nunca EDIT direto — não existe policy de UPDATE nesta tabela); ENGENHARIA só as próprias; COMERCIAL/FINANCEIRO/AUDITOR sem acesso (nenhuma policy cobre esses perfis). Propositalmente NUNCA using(true).';

-- Nenhuma policy de INSERT/UPDATE/DELETE para `authenticated` em nenhuma das 3 tabelas —
-- toda escrita é exclusiva das funções SECURITY DEFINER de app.* (Migrations 3 e 4 desta
-- fase), que rodam com o privilégio do owner (mesmo padrão de app.restaurar_*) e fazem sua
-- própria checagem de perfil antes de qualquer INSERT/UPDATE.

-- GRANT de base necessário para a RLS acima sequer ser avaliada (sem privilégio de tabela,
-- Postgres nega antes de checar qualquer policy). Só SELECT — nunca INSERT/UPDATE/DELETE
-- para `authenticated` (reforça, na camada de GRANT, a mesma decisão das policies acima).
grant select on staging.importacoes, staging.importacao_itens, staging.importacao_alteracoes to authenticated;
