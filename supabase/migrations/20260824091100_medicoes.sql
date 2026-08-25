-- OptiMon — Fase 1
-- Medição mensal por contrato e Revenue Assurance (estrutura; a alimentação automática
-- via HubSoft/financeiro entra nas fases 4/5).

create table public.medicoes_mensais (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  competencia date not null,
  clientes_ativos integer check (clientes_ativos >= 0),
  faturamento_parceiro numeric(14,2) check (faturamento_parceiro >= 0),
  fator_rampa numeric(4,3) check (fator_rampa between 0 and 1),
  revenue_share_calculado numeric(14,2),
  take_or_pay_calculado numeric(14,2),
  valor_fixo numeric(14,2),
  valor_final numeric(14,2),
  status text not null default 'ABERTA' check (status in ('ABERTA','EM_APROVACAO','APROVADA','REJEITADA')),
  aprovado_por uuid references public.usuarios(id),
  aprovado_em timestamptz,
  imutavel boolean not null default false,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz,
  unique (contrato_id, competencia)
);
create index medicoes_mensais_contrato_idx on public.medicoes_mensais (contrato_id);
create trigger trg_medicoes_mensais_atualizado_em
  before update on public.medicoes_mensais
  for each row execute function public.set_atualizado_em();

comment on table public.medicoes_mensais is 'Fechamento mensal do contrato (job monthly_contract_closing, seção 20). Imutável após aprovação (seção 17).';

create or replace function public.fn_medicao_imutavel()
returns trigger
language plpgsql
as $$
begin
  -- Em UPDATE, se a linha já estava marcada imutável, nenhuma alteração é permitida.
  if tg_op = 'UPDATE' and old.imutavel then
    raise exception 'Medição do contrato % (competência %) já aprovada e é imutável.', old.contrato_id, old.competencia;
  end if;

  -- Cobre tanto a transição por UPDATE (status muda para APROVADA) quanto o caso de a
  -- linha já nascer aprovada via INSERT (ex.: carga/seed) — em ambos, trava a linha.
  if new.status = 'APROVADA' and (tg_op = 'INSERT' or old.status <> 'APROVADA') then
    new.imutavel := true;
    new.aprovado_em := coalesce(new.aprovado_em, now());
  end if;

  return new;
end;
$$;

create trigger trg_medicao_imutavel
  before insert or update on public.medicoes_mensais
  for each row execute function public.fn_medicao_imutavel();

create table public.medicao_clientes (
  id uuid primary key default gen_random_uuid(),
  medicao_id uuid not null references public.medicoes_mensais(id) on delete restrict,
  clientes_declarados_parceiro integer check (clientes_declarados_parceiro >= 0),
  clientes_hubsoft integer check (clientes_hubsoft >= 0),
  divergencia integer generated always as
    (coalesce(clientes_hubsoft, 0) - coalesce(clientes_declarados_parceiro, 0)) stored,
  criado_em timestamptz not null default now()
);
create index medicao_clientes_medicao_idx on public.medicao_clientes (medicao_id);

comment on table public.medicao_clientes is 'Revenue Assurance: base declarada pelo parceiro vs. base no HubSoft (seção 17).';

create table public.medicao_faturamento (
  id uuid primary key default gen_random_uuid(),
  medicao_id uuid not null references public.medicoes_mensais(id) on delete restrict,
  origem text not null check (origem in ('PARCEIRO_DECLARADO','HUBSOFT','ERP_PARCEIRO')),
  valor numeric(14,2) not null check (valor >= 0),
  referencia_externa text,
  criado_em timestamptz not null default now()
);
create index medicao_faturamento_medicao_idx on public.medicao_faturamento (medicao_id);

create table public.medicao_recebimentos (
  id uuid primary key default gen_random_uuid(),
  medicao_id uuid not null references public.medicoes_mensais(id) on delete restrict,
  valor_recebido numeric(14,2) not null check (valor_recebido >= 0),
  data_recebimento date,
  origem text,
  referencia_externa text,
  criado_em timestamptz not null default now()
);
create index medicao_recebimentos_medicao_idx on public.medicao_recebimentos (medicao_id);
