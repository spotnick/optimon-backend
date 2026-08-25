-- OptiMon — Fase 1
-- Parceiros (empresas que exploram economicamente a capacidade ociosa).

create table public.parceiros (
  id uuid primary key default gen_random_uuid(),
  razao_social text not null,
  nome_fantasia text,
  cnpj char(14) not null,
  email_contato text,
  telefone_contato text,
  responsavel_comercial text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz,
  unique (cnpj)
);

alter table public.parceiros
  add constraint parceiros_cnpj_formato check (cnpj ~ '^[0-9]{14}$');

create trigger trg_parceiros_atualizado_em
  before update on public.parceiros
  for each row execute function public.set_atualizado_em();

comment on table public.parceiros is 'Empresas parceiras que contratam capacidade óptica/ativos do ISP proprietário.';
