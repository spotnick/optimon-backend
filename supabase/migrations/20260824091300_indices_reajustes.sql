-- OptiMon — Fase 1
-- Índices econômicos (IPCA/IBGE) e reajustes contratuais (seção 14/15).

create table public.indices_economicos (
  id uuid primary key default gen_random_uuid(),
  indice text not null default 'IPCA',
  competencia date not null,
  valor_mensal numeric(8,5) not null,
  valor_acumulado_12m numeric(8,5),
  fonte text not null default 'IBGE/SIDRA',
  coletado_em timestamptz not null default now(),
  validado boolean not null default false,
  validado_por uuid references public.usuarios(id),
  validado_em timestamptz,
  unique (indice, competencia)
);

comment on table public.indices_economicos is 'Séries de índices econômicos coletadas pelo EconomicIndexService. Reajuste automático só usa índice validado=true (seção 15).';

create table public.reajustes (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  indice_id uuid references public.indices_economicos(id) on delete restrict,
  competencia_base date not null,
  percentual_aplicado numeric(8,5) not null,
  pricing_version_gerada uuid references public.pricing_versions(id),
  aplicado_por text not null default 'SISTEMA',
  aplicado_em timestamptz not null default now(),
  status text not null default 'PENDENTE' check (status in ('PENDENTE','APLICADO','ERRO')),
  erro_detalhe text
);
create index reajustes_contrato_idx on public.reajustes (contrato_id);

comment on table public.reajustes is 'Registro de cada aplicação de reajuste a um contrato — sempre gera nova pricing_version, nunca recalcula histórico.';
