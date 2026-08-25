-- OptiMon — Fase 1
-- Contratos de exploração econômica da infraestrutura, e seu histórico versionado.

create table public.contratos (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique,
  parceiro_id uuid not null references public.parceiros(id) on delete restrict,
  cidade_id uuid not null references public.cidades_infra(id) on delete restrict,
  modelo contrato_modelo not null,
  status contrato_status not null default 'RASCUNHO',
  data_inicio date,
  data_fim_prevista date,
  prazo_meses integer not null check (prazo_meses > 0),
  prazo_minimo_excecao boolean not null default false,
  aprovado_por uuid references public.usuarios(id),
  aprovado_em timestamptz,
  revenue_share_base revenue_share_base not null default 'BASE_FATURAMENTO',
  versao_atual integer not null default 1,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz
);

-- Prazo mínimo contratual de 48 meses (seção 11), salvo aprovação expressa (prazo_minimo_excecao).
alter table public.contratos
  add constraint contratos_prazo_minimo check (prazo_meses >= 48 or prazo_minimo_excecao = true);

-- Exceção de prazo mínimo exige quem aprovou registrado.
alter table public.contratos
  add constraint contratos_excecao_precisa_aprovador
  check (prazo_minimo_excecao = false or aprovado_por is not null);

create index contratos_parceiro_idx on public.contratos (parceiro_id);
create index contratos_cidade_idx on public.contratos (cidade_id);
create index contratos_status_idx on public.contratos (status);

create trigger trg_contratos_atualizado_em
  before update on public.contratos
  for each row execute function public.set_atualizado_em();

comment on table public.contratos is 'Contrato comercial entre o ISP proprietário e um parceiro para exploração da infraestrutura ociosa.';
comment on column public.contratos.prazo_minimo_excecao is 'Se true, contrato foi aprovado com prazo abaixo de 48 meses por DIRETOR/ADMINISTRADOR (seção 11).';

-- Histórico imutável de versões do contrato (seção 37 — nenhum contrato aprovado é alterado silenciosamente).
create table public.contrato_versions (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  versao integer not null,
  motivo text not null,
  snapshot jsonb not null,
  criado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(),
  unique (contrato_id, versao)
);

comment on table public.contrato_versions is 'Snapshot completo do contrato a cada alteração pós-aprovação. Nunca sobrescrito (V1, V2, V3...).';
