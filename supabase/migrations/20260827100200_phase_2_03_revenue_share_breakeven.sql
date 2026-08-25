-- OptiMon — Fase 2
-- Seções 15-21 (SOMA/MAX/mínimo por porta/portas reservadas/capacidade/revenue share) já
-- foram implementadas na Fase 1.2 (contrato_pricing_config.modelo_cobranca,
-- modelo_minimo=PER_PON/PER_CONTRACT via POR_PORTA/GLOBAL, cobranca_portas_reservadas=
-- charge_reserved_ports, app.calcular_minimo_contratual, app.calcular_cobranca_hibrida) —
-- nada é refeito aqui, só o que faltava: BREAK-EVEN (seção 42) e o helper de múltiplas
-- portas (seções 23/44), que dependem dessas peças mas ainda não existiam.

-- Seção 42: faturamento de equilíbrio — ponto em que Revenue Share = Mínimo. Também o
-- ponto identificado no gráfico principal da seção 39.
create or replace function app.calcular_breakeven_faturamento(p_contrato_id uuid)
returns numeric
language plpgsql
stable
as $$
declare
  v_minimo numeric;
  v_percentual numeric;
begin
  v_minimo := app.calcular_minimo_contratual(p_contrato_id);
  select percentual_revenue_share into v_percentual from public.contrato_pricing_config where contrato_id = p_contrato_id;

  if v_percentual is null or v_percentual = 0 then
    return null; -- sem revenue share configurado, não existe ponto de equilíbrio
  end if;

  return round(v_minimo / v_percentual, 2);
end;
$$;

comment on function app.calcular_breakeven_faturamento(uuid) is 'Seção 42: break_even_revenue = mínimo / revenue_share_percent. Exemplo do prompt: R$1.000 / 12% = R$8.333,33.';

create or replace function app.calcular_breakeven_clientes(p_contrato_id uuid, p_arpu numeric)
returns integer
language plpgsql
stable
as $$
declare
  v_breakeven numeric;
begin
  if p_arpu is null or p_arpu <= 0 then
    return null;
  end if;
  v_breakeven := app.calcular_breakeven_faturamento(p_contrato_id);
  if v_breakeven is null then
    return null;
  end if;
  return ceil(v_breakeven / p_arpu)::integer;
end;
$$;

comment on function app.calcular_breakeven_clientes(uuid, numeric) is 'Seção 42: nº de clientes para o Revenue Share superar o mínimo, arredondado para cima. Exemplo do prompt: R$8.333,33 / R$100 ARPU = 83,33 → 84 clientes.';

-- Seções 23/44: quantidade de Portas PON necessárias para atender N clientes, respeitando
-- a capacidade por porta (parametrizável, nunca hard-coded — mesma fonte da Fase 1.1:
-- PORTA_PON_CAPACIDADE_MAX_PADRAO, ou a capacidade explícita informada).
create or replace function app.get_portas_necessarias(p_clientes integer, p_capacidade_por_porta integer default null)
returns integer
language plpgsql
stable
as $$
declare
  v_capacidade integer;
begin
  v_capacidade := p_capacidade_por_porta;
  if v_capacidade is null then
    select valor::integer into v_capacidade from public.pricing_parametros
    where chave = 'PORTA_PON_CAPACIDADE_MAX_PADRAO' and (vigente_ate is null or vigente_ate >= current_date);
  end if;

  if v_capacidade is null or v_capacidade <= 0 or p_clientes is null or p_clientes <= 0 then
    return 0;
  end if;

  return ceil(p_clientes::numeric / v_capacidade)::integer;
end;
$$;

comment on function app.get_portas_necessarias(integer, integer) is 'Seções 23/44: ceil(clientes / capacidade_por_porta). Exemplo do prompt: 1000 clientes / 128 = 8 portas; 200/128 = 2 portas.';
