-- OptiMon — Fase 1
-- Estrutura de pricing (o motor de cálculo em código é a Fase 2; aqui garantimos que
-- nenhum valor comercial fique hard-coded, seção 8/9/35).

create table public.pricing_parametros (
  id uuid primary key default gen_random_uuid(),
  chave text not null unique,
  valor numeric(14,4) not null,
  unidade text,
  descricao text,
  vigente_desde date not null default current_date,
  vigente_ate date,
  criado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create trigger trg_pricing_parametros_atualizado_em
  before update on public.pricing_parametros
  for each row execute function public.set_atualizado_em();

comment on table public.pricing_parametros is 'Parâmetros comerciais globais versionáveis (preço mínimo, multiplicadores, revenue share, etc.). Nunca hard-coded no backend.';

create table public.pricing_versions (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid references public.contratos(id) on delete restrict,
  versao integer not null,
  motivo text not null,
  parametros jsonb not null,
  indice_aplicado text,
  criado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(),
  unique (contrato_id, versao)
);

comment on table public.pricing_versions is 'Snapshot dos parâmetros de pricing aplicados a um contrato em cada versão (V1/V2/V3). Reajustes nunca recalculam versões antigas (seção 14).';

create table public.simulacoes (
  id uuid primary key default gen_random_uuid(),
  cidade_id uuid references public.cidades_infra(id) on delete set null,
  parceiro_id uuid references public.parceiros(id) on delete set null,
  modelo contrato_modelo not null,
  pares_ou_clientes integer not null check (pares_ou_clientes > 0),
  arpu numeric(10,2),
  revenue_share_pct numeric(5,4),
  take_or_pay_valor numeric(10,2),
  valor_fixo numeric(10,2),
  prazo_meses integer not null check (prazo_meses > 0),
  resultado jsonb not null,
  criado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now()
);
create index simulacoes_criado_por_idx on public.simulacoes (criado_por);

comment on table public.simulacoes is 'Simulações do comercial (tela de simulação, seção 30) — preço mín/recomendado/premium, receitas 12/36/48/60m, ROI, guardado em resultado (jsonb).';
