-- OptiMon — Fase 2
-- Seções 25-26: rampa de maturação como TABELA (não mais só parâmetros soltos como na
-- Fase 1 — RAMPA_MESES_1_3_PCT etc. continuam existindo em pricing_parametros e viram o
-- SEED default global aqui, mas cada contrato pode ter sua própria régua de rampa).

create table public.pricing_ramp_rules (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid references public.contratos(id) on delete cascade, -- null = régua padrão global
  month_start integer not null check (month_start >= 1),
  month_end integer check (month_end is null or month_end >= month_start), -- null = "em diante"
  percentage numeric(6,5) not null check (percentage > 0 and percentage <= 5),
  component public.rampa_alvo not null default 'AMBOS', -- FIXO_MINIMO / REVENUE_SHARE / AMBOS (enum já existia, Fase 1.1)
  criado_em timestamptz not null default now()
);
create index pricing_ramp_rules_contrato_idx on public.pricing_ramp_rules (contrato_id);

comment on table public.pricing_ramp_rules is 'Seção 25: month_start/month_end/percentage/component. Sem contrato_id = régua padrão (seed abaixo, espelhando RAMPA_MESES_1_3_PCT/4_6/7+ da Fase 1). Aplicada sobre o componente configurado em contrato_pricing_config.rampa_aplica_a — nunca hard-coded em função.';

-- Régua padrão global — os mesmos 3 degraus já parametrizados desde a Fase 1 (seção 26 do
-- prompt: exemplo literal 50%/75%/100%), agora como linhas de tabela em vez de só
-- pricing_parametros soltos (pricing_parametros continua existindo, sem duplicar valor —
-- os 3 parâmetros antigos ficam só como referência histórica/compatibilidade).
insert into public.pricing_ramp_rules (contrato_id, month_start, month_end, percentage, component) values
  (null, 1, 3, 0.50, 'AMBOS'),
  (null, 4, 6, 0.75, 'AMBOS'),
  (null, 7, null, 1.00, 'AMBOS');

-- app.get_fator_rampa(): resolve o fator de um contrato específico para um mês e
-- componente — usa a régua do contrato se existir, senão cai na régua padrão global
-- (contrato_id is null). Nunca uma rampa fixa no código (seção 25).
create or replace function app.get_fator_rampa(p_contrato_id uuid, p_mes integer, p_componente public.rampa_alvo default 'AMBOS')
returns numeric
language plpgsql
stable
as $$
declare
  v_fator numeric;
begin
  select percentage into v_fator
  from public.pricing_ramp_rules
  where contrato_id = p_contrato_id
    and month_start <= p_mes and (month_end is null or month_end >= p_mes)
    and (component = p_componente or component = 'AMBOS' or p_componente = 'AMBOS')
  order by month_start desc
  limit 1;

  if v_fator is not null then
    return v_fator;
  end if;

  -- fallback: régua padrão global (contrato_id is null)
  select percentage into v_fator
  from public.pricing_ramp_rules
  where contrato_id is null
    and month_start <= p_mes and (month_end is null or month_end >= p_mes)
    and (component = p_componente or component = 'AMBOS' or p_componente = 'AMBOS')
  order by month_start desc
  limit 1;

  return coalesce(v_fator, 1.00);
end;
$$;

comment on function app.get_fator_rampa(uuid, integer, public.rampa_alvo) is 'Seção 25/26: fator de rampa (0..1+) para o mês/componente, usando a régua do contrato se existir, senão a régua global padrão (1/3=50%, 4/6=75%, 7+=100%). Fallback final é 1.00 (sem rampa) se nem a régua global cobrir o mês.';
