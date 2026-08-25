-- OptiMon — Fase 1
-- Exclusividade territorial/comercial, workflow de aprovação e clientes reservados
-- (seções 21 a 24 do Prompt Mestre — regra crítica do produto).

create table public.contrato_regras (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  exclusividade_comercial boolean not null default false,
  area_exclusividade text,
  proibe_fibra_terceiros boolean not null default true,
  proibe_rede_propria boolean not null default true,
  direito_preferencia boolean not null default false,
  exige_aprovacao_expansao boolean not null default true,
  observacoes text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (contrato_id)
);
create trigger trg_contrato_regras_atualizado_em
  before update on public.contrato_regras
  for each row execute function public.set_atualizado_em();

comment on table public.contrato_regras is 'Guardrails contratuais por contrato: exclusividade, proibições, direito de preferência.';
comment on column public.contrato_regras.area_exclusividade is 'Descrição textual da área de exclusividade nesta fase (ex.: bairros/CEPs). Geometria fica para fase futura se necessário.';

create table public.contrato_regras_solicitacoes (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  tipo text not null check (tipo in ('FIBRA_TERCEIROS','REDE_PROPRIA')),
  descricao text not null,
  status solicitacao_status not null default 'PENDENTE',
  solicitado_por uuid references public.usuarios(id),
  decidido_por uuid references public.usuarios(id),
  decidido_em timestamptz,
  criado_em timestamptz not null default now()
);
create index contrato_regras_solicitacoes_contrato_idx on public.contrato_regras_solicitacoes (contrato_id);

comment on table public.contrato_regras_solicitacoes is 'Workflow solicitação → aprovação/rejeição para exceções às seções 22 e 23 (fibra de terceiros / rede própria do parceiro).';

create table public.contrato_clientes_reservados (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  cliente_nome text not null,
  cnpj_cpf text,
  cidade_id uuid references public.cidades_infra(id) on delete set null,
  motivo text,
  status text not null default 'RESERVADO' check (status in ('RESERVADO','LIBERADO')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (contrato_id, cliente_nome)
);
create trigger trg_contrato_clientes_reservados_atualizado_em
  before update on public.contrato_clientes_reservados
  for each row execute function public.set_atualizado_em();

comment on table public.contrato_clientes_reservados is 'Clientes que o parceiro não pode vender/atender/prospectar/migrar sem aprovação expressa (ex.: Prefeitura de Jussara — seção 24).';
