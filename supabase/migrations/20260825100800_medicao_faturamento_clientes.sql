-- OptiMon — Fase 1.1
-- Detalhe opcional de faturamento por cliente/porta PON (seção 26). Quando o parceiro
-- não puder identificar o cliente individualmente, a medição agregada de
-- medicao_faturamento (Fase 1) continua sendo aceita normalmente — esta tabela é um
-- complemento, não uma obrigação.

create table public.medicao_faturamento_clientes (
  id uuid primary key default gen_random_uuid(),
  medicao_id uuid not null references public.medicoes_mensais(id) on delete restrict,
  porta_pon_id uuid references public.infra_portas_pon(id) on delete set null,
  cliente_identificador text,
  valor_faturado numeric(14,2) not null check (valor_faturado >= 0),
  competencia date not null,
  criado_em timestamptz not null default now()
);
create index medicao_faturamento_clientes_medicao_idx on public.medicao_faturamento_clientes (medicao_id);
create index medicao_faturamento_clientes_porta_idx on public.medicao_faturamento_clientes (porta_pon_id);

comment on table public.medicao_faturamento_clientes is 'Detalhe opcional por cliente/porta PON para revenue share granular (seção 26/27). cliente_identificador é o id/login do cliente no HubSoft — nulo quando só a medição agregada estiver disponível.';
