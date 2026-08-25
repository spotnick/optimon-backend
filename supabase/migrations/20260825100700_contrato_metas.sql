-- OptiMon — Fase 1.1
-- Metas de desempenho por período (seção 20). Consequência é sempre parametrizável —
-- nunca assumir rescisão automática por padrão.

create type meta_consequencia as enum (
  'SEM_CONSEQUENCIA', 'RENEGOCIACAO', 'PERDA_DE_EXCLUSIVIDADE',
  'REDUCAO_DE_CAPACIDADE', 'NOTIFICACAO', 'RESCISAO', 'OUTRA'
);

create table public.contrato_metas (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  periodo_inicio date not null,
  periodo_fim date not null,
  clientes_minimos integer check (clientes_minimos is null or clientes_minimos >= 0),
  faturamento_minimo numeric(14,2) check (faturamento_minimo is null or faturamento_minimo >= 0),
  ocupacao_minima numeric(5,4) check (ocupacao_minima is null or ocupacao_minima between 0 and 1),
  capacidade_contratada integer check (capacidade_contratada is null or capacidade_contratada >= 0),
  consequencia meta_consequencia not null default 'SEM_CONSEQUENCIA',
  status text not null default 'ATIVA' check (status in ('ATIVA', 'CUMPRIDA', 'NAO_CUMPRIDA', 'CANCELADA')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (periodo_fim > periodo_inicio)
);
create index contrato_metas_contrato_idx on public.contrato_metas (contrato_id);
create trigger trg_contrato_metas_atualizado_em
  before update on public.contrato_metas
  for each row execute function public.set_atualizado_em();

comment on table public.contrato_metas is 'Metas de desempenho por período (ex.: rampa mês 1-3/4-6/7+). consequencia é sempre parametrizável — RESCISAO é uma opção entre várias, nunca o default automático (seção 20).';
