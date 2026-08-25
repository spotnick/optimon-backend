-- OptiMon — Fase 1.1
-- Config comercial por contrato (seções 4, 5, 22-25). O Pricing Engine (Fase 2) lê
-- esta tabela para decidir a fórmula — nunca assume um modelo global único.

create type modelo_cobranca as enum ('MAX', 'SOMA'); -- Modelo A = MAX(fixo,share) | Modelo B = fixo+share
create type base_calculo_revenue_share as enum ('FATURAMENTO_BRUTO', 'FATURAMENTO_LIQUIDO', 'FATURAMENTO_ELEGIVEL');
create type modelo_minimo_contratual as enum ('POR_PORTA', 'GLOBAL');
create type rampa_alvo as enum ('FIXO_MINIMO', 'REVENUE_SHARE', 'AMBOS');
create type metodo_precificacao_dark_fiber as enum ('POR_PORTA', 'POR_FIBRA', 'POR_KM', 'POR_POP');

create table public.contrato_pricing_config (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  modelo_cobranca modelo_cobranca not null default 'MAX',
  base_calculo_revenue_share base_calculo_revenue_share not null default 'FATURAMENTO_BRUTO',
  modelo_minimo modelo_minimo_contratual not null default 'GLOBAL',
  rampa_aplica_a rampa_alvo not null default 'FIXO_MINIMO',
  metodo_precificacao_dark_fiber metodo_precificacao_dark_fiber,
  mensalidade_minima_porta numeric(12,2) check (mensalidade_minima_porta is null or mensalidade_minima_porta >= 0),
  percentual_revenue_share numeric(6,5) check (percentual_revenue_share is null or percentual_revenue_share between 0 and 1),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (contrato_id)
);
create trigger trg_contrato_pricing_config_atualizado_em
  before update on public.contrato_pricing_config
  for each row execute function public.set_atualizado_em();

comment on table public.contrato_pricing_config is 'Define, por contrato, qual fórmula comercial se aplica (seção 4: "o contrato deverá definir qual modelo está sendo utilizado" — nunca uma fórmula global fixa no código).';
comment on column public.contrato_pricing_config.modelo_cobranca is 'MAX = Modelo A: cobrança = MAX(mensalidade mínima, revenue share). SOMA = Modelo B: cobrança = mensalidade mínima + revenue share.';
comment on column public.contrato_pricing_config.modelo_minimo is 'POR_PORTA = mínimo contratual é (nº de portas × mínimo por porta). GLOBAL = um único mínimo para o contrato inteiro (seção 25).';
comment on column public.contrato_pricing_config.rampa_aplica_a is 'A rampa de maturação (pricing_parametros RAMPA_*) incide sobre o fixo mínimo, o revenue share, ou ambos — nunca fixo no controller (seção 24).';

-- Referências adicionais de pricing (continuam parametrizáveis, nunca hard-coded — seção 22/23).
insert into public.pricing_parametros (chave, valor, unidade, descricao) values
  ('DARK_FIBER_PRECO_POR_PORTA_MES', 1500, 'BRL', 'Preço por porta/mês quando metodo_precificacao_dark_fiber = POR_PORTA (seção 22).'),
  ('DARK_FIBER_PRECO_POR_POP_MES', 5000, 'BRL', 'Preço por POP/mês quando metodo_precificacao_dark_fiber = POR_POP (seção 22).'),
  ('HIBRIDO_MENSALIDADE_MINIMA_PORTA_PADRAO', 1000, 'BRL', 'Mensalidade mínima padrão por porta PON quando o contrato não define outro valor (seção 5).')
on conflict (chave) do nothing;
