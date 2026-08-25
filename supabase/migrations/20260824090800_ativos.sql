-- OptiMon — Fase 1
-- Ativos físicos (OLT/ONU/equipamentos) e controle de devolução na rescisão (seção 26).

create table public.ativos (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('OLT','ONU','SWITCH','ROTEADOR','OUTRO')),
  fabricante text,
  modelo text,
  numero_serie text,
  patrimonio text unique,
  valor numeric(12,2) check (valor >= 0),
  localizacao text,
  cidade_id uuid references public.cidades_infra(id) on delete set null,
  parceiro_id uuid references public.parceiros(id) on delete set null,
  contrato_id uuid references public.contratos(id) on delete set null,
  status ativo_status not null default 'ESTOQUE',
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz
);
create index ativos_contrato_idx on public.ativos (contrato_id);
create index ativos_status_idx on public.ativos (status);
create trigger trg_ativos_atualizado_em
  before update on public.ativos
  for each row execute function public.set_atualizado_em();

comment on table public.ativos is 'Equipamentos do ISP (preferencialmente comodato/locação — propriedade permanece do ISP, seção 26).';

create table public.ativos_devolucao (
  id uuid primary key default gen_random_uuid(),
  ativo_id uuid not null references public.ativos(id) on delete restrict,
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  data_solicitacao timestamptz not null default now(),
  data_devolucao timestamptz,
  condicao text,
  valor_perdas_danos numeric(12,2) check (valor_perdas_danos >= 0),
  registrado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now()
);

comment on table public.ativos_devolucao is 'Ordem de devolução de ativo na rescisão contratual: registro de condição e eventuais perdas/danos.';
