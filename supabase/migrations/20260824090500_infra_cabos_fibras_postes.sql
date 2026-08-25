-- OptiMon — Fase 1
-- Infraestrutura óptica: segmentos, cabos, fibras individuais e postes.

create table public.infra_segmentos (
  id uuid primary key default gen_random_uuid(),
  cidade_id uuid not null references public.cidades_infra(id) on delete restrict,
  nome text not null,
  origem text not null,
  destino text not null,
  extensao_km numeric(10,3) not null check (extensao_km >= 0),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz
);
create index infra_segmentos_cidade_idx on public.infra_segmentos (cidade_id);
create trigger trg_infra_segmentos_atualizado_em
  before update on public.infra_segmentos
  for each row execute function public.set_atualizado_em();

create table public.infra_cabos (
  id uuid primary key default gen_random_uuid(),
  segmento_id uuid not null references public.infra_segmentos(id) on delete restrict,
  identificacao text not null,
  capacidade_fo integer not null check (capacidade_fo > 0),
  fabricante text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz,
  unique (segmento_id, identificacao)
);
create trigger trg_infra_cabos_atualizado_em
  before update on public.infra_cabos
  for each row execute function public.set_atualizado_em();

-- Cada linha é UMA fibra física. Duas fibras com o mesmo par_numero formam um PAR comercializável.
create table public.infra_fibras (
  id uuid primary key default gen_random_uuid(),
  cabo_id uuid not null references public.infra_cabos(id) on delete restrict,
  numero_fibra integer not null check (numero_fibra > 0),
  par_numero integer not null check (par_numero > 0),
  status fibra_status not null default 'LIVRE',
  observacao text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (cabo_id, numero_fibra)
);
create index infra_fibras_status_idx on public.infra_fibras (status);
create index infra_fibras_par_idx on public.infra_fibras (cabo_id, par_numero);
create trigger trg_infra_fibras_atualizado_em
  before update on public.infra_fibras
  for each row execute function public.set_atualizado_em();

comment on table public.infra_fibras is 'Fibra óptica individual. Sempre é possível saber qual contrato usa qual fibra via contrato_fibras (seção 6 do Prompt Mestre).';
comment on column public.infra_fibras.status is 'LIVRE, OCUPADA, RESERVADA, LOCADA, MANUTENCAO ou BLOQUEADA.';

-- Uma linha pode representar um lote de postes com o mesmo proprietário/custo unitário
-- (prática comum: aluguel de postes é faturado em lote pela concessionária, não poste a poste),
-- ou um poste individual quando quantidade = 1.
create table public.infra_postes (
  id uuid primary key default gen_random_uuid(),
  cidade_id uuid not null references public.cidades_infra(id) on delete restrict,
  segmento_id uuid references public.infra_segmentos(id) on delete set null,
  identificacao text,
  proprietario_terceiro text,
  quantidade integer not null default 1 check (quantidade > 0),
  custo_mensal numeric(12,2) not null default 0 check (custo_mensal >= 0),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz
);
create index infra_postes_cidade_idx on public.infra_postes (cidade_id);
create trigger trg_infra_postes_atualizado_em
  before update on public.infra_postes
  for each row execute function public.set_atualizado_em();

comment on column public.infra_postes.proprietario_terceiro is 'Concessionária dona do poste (ex.: distribuidora de energia), quando o poste não é próprio.';
comment on column public.infra_postes.quantidade is 'Quantidade de postes representados por esta linha (lote). custo_mensal é o custo agregado do lote, não por poste.';
