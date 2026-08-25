-- OptiMon — Fase 1.2
-- Seção 15: aditivo precisa poder cobrir explicitamente alteração de capacidade,
-- exclusividade e regras de cobrança — não só inclusão/exclusão de porta/prazo/comercial
-- genérico como na Fase 1.1. Amplia o CHECK de contrato_aditivos.tipo (aditivo) e
-- adiciona o campo "tipo" de exclusividade que faltava na lista da seção 20 (território,
-- POP, serviço, capacidade, vigência já existiam desde a Fase 1.1).

-- Descobre o nome real do CHECK de contrato_aditivos.tipo (criado sem nome explícito na
-- Fase 1.1) para trocá-lo sem adivinhar a convenção de nomenclatura do Postgres.
do $$
declare
  v_nome_constraint text;
begin
  select con.conname into v_nome_constraint
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  where rel.relname = 'contrato_aditivos'
    and con.contype = 'c'
    and pg_get_constraintdef(con.oid) like '%tipo = ANY%';

  if v_nome_constraint is not null then
    execute format('alter table public.contrato_aditivos drop constraint %I', v_nome_constraint);
  end if;
end $$;

alter table public.contrato_aditivos
  add constraint contrato_aditivos_tipo_check check (tipo in (
    'INCLUSAO_FIBRA', 'INCLUSAO_PORTA', 'EXCLUSAO_FIBRA', 'EXCLUSAO_PORTA',
    'ALTERACAO_PRAZO', 'ALTERACAO_COMERCIAL', 'ALTERACAO_CAPACIDADE',
    'ALTERACAO_EXCLUSIVIDADE', 'ALTERACAO_REGRAS_COBRANCA', 'OUTRO'
  ));

comment on column public.contrato_aditivos.tipo is 'Fase 1.2 (seção 15): amplia os tipos herdados da Fase 1.1 com ALTERACAO_CAPACIDADE, ALTERACAO_EXCLUSIVIDADE e ALTERACAO_REGRAS_COBRANCA — todo aditivo aprovado gera nova contrato_versions automaticamente (trigger fn_aditivo_gera_versao, Fase 1.1), nunca sobrescreve em silêncio.';

-- Seção 20: "a exclusividade deverá sempre possuir: tipo, território, POP, serviço,
-- capacidade, vigência". Território/POP/serviço/capacidade/vigência já existiam desde a
-- Fase 1.1 (exclusividade_cidade_id/exclusividade_pop_id/exclusividade_servico/
-- exclusividade_capacidade_max/exclusividade_prazo_meses) — só faltava o "tipo".
-- Campo informativo/opcional: não substitui o CHECK de escopo já existente
-- (contrato_regras_exclusividade_precisa_escopo, Fase 1.1), só documenta a natureza da
-- exclusividade quando ela é aplicada.
alter table public.contrato_regras
  add column exclusividade_tipo text check (exclusividade_tipo is null or exclusividade_tipo in (
    'TERRITORIAL', 'SERVICO', 'CAPACIDADE', 'MISTA'
  ));

comment on column public.contrato_regras.exclusividade_tipo is 'Natureza da exclusividade (seção 20) — TERRITORIAL (cidade/POP), SERVICO, CAPACIDADE ou MISTA. Campo informativo; o escopo de fato (o que efetivamente bloqueia) continua sendo cidade/POP/serviço/capacidade/prazo, já validados desde a Fase 1.1.';
