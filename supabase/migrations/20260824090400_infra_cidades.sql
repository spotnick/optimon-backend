-- OptiMon — Fase 1
-- Infraestrutura óptica: cidades.

create table public.cidades_infra (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  uf char(2) not null,
  codigo_ibge char(7),
  endereco text,
  km_rede numeric(10,3) not null default 0 check (km_rede >= 0),
  observacoes text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz,
  unique (nome, uf),
  unique (codigo_ibge)
);

create trigger trg_cidades_infra_atualizado_em
  before update on public.cidades_infra
  for each row execute function public.set_atualizado_em();

comment on table public.cidades_infra is 'Cidades com infraestrutura óptica própria do ISP.';
comment on column public.cidades_infra.km_rede is 'Extensão total de rede na cidade, em km (referência econômica, seção 2 do Manual Comercial).';
