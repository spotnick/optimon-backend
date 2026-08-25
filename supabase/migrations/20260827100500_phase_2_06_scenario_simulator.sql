-- OptiMon — Fase 2
-- Seções 22-24, 30-33, 44-45: ScenarioSimulator + ROICalculator + PaybackCalculator —
-- serviços separados (seção 51), cada um sua função, nenhuma lógica dentro de controller
-- único. app.simular_projecao() é o núcleo: recebe parâmetros (sempre explícitos, nunca
-- hard-coded — seção 65) e devolve a projeção mês a mês em jsonb; simulacoes.resultado
-- (tabela já existente desde a Fase 1) guarda esse jsonb como snapshot da simulação.
--
-- Contrato de entrada de app.simular_projecao(p_params jsonb):
--   contrato_id            uuid | null  — se informado, lê mínimo/revenue-share/modelo/rampa/
--                                         reajuste do contrato real; senão usa os campos abaixo.
--   modelo_cobranca        'SOMA' | 'MAX'            (default 'SOMA' se contrato_id is null)
--   capacidade_por_porta   integer                    (default PORTA_PON_CAPACIDADE_MAX_PADRAO)
--   clientes_iniciais      integer                    (default 0)
--   modo_crescimento       'LINEAR' | 'CHECKPOINTS'   (default 'LINEAR')
--   crescimento_mensal     integer                    (modo LINEAR, default 0 clientes/mês)
--   meta_final_clientes    integer | null             (teto opcional no modo LINEAR)
--   checkpoints            [{"mes":int,"clientes":int}, ...] (modo CHECKPOINTS, interpolação
--                                                       linear entre pontos, constante depois
--                                                       do último ponto — método documentado,
--                                                       não inventado silenciosamente)
--   meses_horizonte        integer                    (default 48 — o prazo contratual mínimo)
--   arpu_inicial            numeric                    (default 0)
--   arpu_crescimento_anual_percent numeric             (default 0 — seção 65: sem valor = 0)
--   minimo_mensal           numeric | null             (usado só se contrato_id is null)
--   revenue_share_percent   numeric | null             (usado só se contrato_id is null)
--   capex_incremental       numeric                    (default 0, aplicado 100% no mês 1)
--   opex_incremental_mensal numeric                    (default 0)
--   reajuste_percentual_anual numeric                  (default 0 — aplicado a cada 12 meses,
--                                                       simulação apenas, não altera o contrato)
create or replace function app.simular_projecao(p_params jsonb)
returns jsonb
language plpgsql
stable
as $$
declare
  v_contrato_id uuid := nullif(p_params->>'contrato_id', '')::uuid;
  v_modelo public.modelo_cobranca;
  v_capacidade integer;
  v_clientes_iniciais integer := coalesce((p_params->>'clientes_iniciais')::integer, 0);
  v_modo text := coalesce(p_params->>'modo_crescimento', 'LINEAR');
  v_crescimento_mensal integer := coalesce((p_params->>'crescimento_mensal')::integer, 0);
  v_meta_final integer := nullif(p_params->>'meta_final_clientes', '')::integer;
  v_checkpoints jsonb := coalesce(p_params->'checkpoints', '[]'::jsonb);
  v_meses integer := coalesce((p_params->>'meses_horizonte')::integer, 48);
  v_arpu0 numeric := coalesce((p_params->>'arpu_inicial')::numeric, 0);
  v_arpu_cresc numeric := coalesce((p_params->>'arpu_crescimento_anual_percent')::numeric, 0);
  v_minimo_base numeric;
  v_percentual numeric;
  v_capex numeric := coalesce((p_params->>'capex_incremental')::numeric, 0);
  v_opex numeric := coalesce((p_params->>'opex_incremental_mensal')::numeric, 0);
  v_reajuste_anual numeric := coalesce((p_params->>'reajuste_percentual_anual')::numeric, 0);
  v_meses_arr jsonb := '[]'::jsonb;
  m integer;
  v_clientes integer;
  v_portas integer;
  v_arpu numeric;
  v_faturamento_parceiro numeric;
  v_fator_reajuste numeric;
  v_minimo numeric;
  v_share numeric;
  v_receita_optimon numeric;
  v_resultado numeric;
  v_margem numeric;
  v_capex_mes numeric;
  v_fluxo numeric;
  v_resultado_acumulado numeric := 0;
  v_capex_acumulado numeric := 0;
  v_fluxo_acumulado numeric := 0;
  cp record;
  v_cp_anterior_mes integer;
  v_cp_anterior_clientes integer;
begin
  if v_contrato_id is not null then
    select modelo_cobranca, percentual_revenue_share into v_modelo, v_percentual
    from public.contrato_pricing_config where contrato_id = v_contrato_id;
    v_minimo_base := app.calcular_minimo_contratual(v_contrato_id);
  else
    v_modelo := coalesce(nullif(p_params->>'modelo_cobranca', '')::public.modelo_cobranca, 'SOMA');
    v_percentual := coalesce((p_params->>'revenue_share_percent')::numeric, 0);
    v_minimo_base := coalesce((p_params->>'minimo_mensal')::numeric, 0);
  end if;

  v_capacidade := nullif(p_params->>'capacidade_por_porta', '')::integer;
  if v_capacidade is null then
    select valor::integer into v_capacidade from public.pricing_parametros
    where chave = 'PORTA_PON_CAPACIDADE_MAX_PADRAO' and (vigente_ate is null or vigente_ate >= current_date);
  end if;

  for m in 1..greatest(v_meses, 1) loop
    -- 1) Clientes do mês, conforme o modo de crescimento escolhido (seção 24).
    if v_modo = 'CHECKPOINTS' then
      v_cp_anterior_mes := 0; v_cp_anterior_clientes := v_clientes_iniciais;
      v_clientes := v_clientes_iniciais;
      for cp in select (value->>'mes')::integer as mes, (value->>'clientes')::integer as clientes
                from jsonb_array_elements(v_checkpoints) order by (value->>'mes')::integer loop
        if m >= cp.mes then
          v_clientes := cp.clientes;
          v_cp_anterior_mes := cp.mes;
          v_cp_anterior_clientes := cp.clientes;
        elsif m > v_cp_anterior_mes then
          -- interpolação linear entre o checkpoint anterior e este.
          v_clientes := v_cp_anterior_clientes + round(
            (cp.clientes - v_cp_anterior_clientes)::numeric * (m - v_cp_anterior_mes) / nullif(cp.mes - v_cp_anterior_mes, 0)
          )::integer;
          exit;
        end if;
      end loop;
    else
      v_clientes := v_clientes_iniciais + v_crescimento_mensal * (m - 1);
      if v_meta_final is not null then
        v_clientes := least(v_clientes, v_meta_final);
      end if;
    end if;
    v_clientes := greatest(v_clientes, 0);

    -- 2) Portas necessárias (seções 23/44).
    v_portas := app.get_portas_necessarias(v_clientes, v_capacidade);

    -- 3) ARPU com crescimento anual opcional (seção 22 — composto a cada 12 meses).
    v_arpu := v_arpu0 * power(1 + v_arpu_cresc, floor((m - 1) / 12.0));
    v_faturamento_parceiro := round(v_clientes * v_arpu, 2);

    -- 4) Reajuste anual simulado sobre o mínimo/share (seção 29 — composto a cada 12 meses;
    --    é só uma projeção hipotética, não altera o contrato real — isso é feito por
    --    app.aplicar_reajuste_contrato quando o reajuste é de fato aplicado).
    v_fator_reajuste := power(1 + v_reajuste_anual, floor((m - 1) / 12.0));

    -- 5) Mínimo e Revenue Share, cada um com sua própria rampa de maturação (seção 25/26).
    v_minimo := round(v_minimo_base * v_fator_reajuste * app.get_fator_rampa(v_contrato_id, m, 'FIXO_MINIMO'), 2);
    v_share := round(v_faturamento_parceiro * coalesce(v_percentual, 0) * v_fator_reajuste * app.get_fator_rampa(v_contrato_id, m, 'REVENUE_SHARE'), 2);

    -- 6) Cobrança total conforme o modelo (SOMA/MAX — Fase 1.2, testado nos testes 5/6).
    v_receita_optimon := case when v_modelo = 'SOMA' then v_minimo + v_share else greatest(v_minimo, v_share) end;

    v_resultado := round(v_receita_optimon - v_opex, 2);
    v_margem := case when v_receita_optimon > 0 then round(v_resultado / v_receita_optimon, 4) else null end;
    v_capex_mes := case when m = 1 then v_capex else 0 end;
    v_fluxo := v_resultado - v_capex_mes;

    v_resultado_acumulado := v_resultado_acumulado + v_resultado;
    v_capex_acumulado := v_capex_acumulado + v_capex_mes;
    v_fluxo_acumulado := v_fluxo_acumulado + v_fluxo;

    v_meses_arr := v_meses_arr || jsonb_build_object(
      'mes', m,
      'clientes', v_clientes,
      'portas', v_portas,
      'faturamento_parceiro', v_faturamento_parceiro,
      'revenue_share', v_share,
      'minimo', v_minimo,
      'receita_optimon', v_receita_optimon,
      'opex_incremental', v_opex,
      'resultado', v_resultado,
      'margem', v_margem,
      'capex', v_capex_mes,
      'fluxo_caixa', v_fluxo,
      'resultado_acumulado', round(v_resultado_acumulado, 2),
      'fluxo_caixa_acumulado', round(v_fluxo_acumulado, 2)
    );
  end loop;

  return jsonb_build_object(
    'parametros', p_params,
    'capex_total', v_capex,
    'meses', v_meses_arr
  );
end;
$$;

comment on function app.simular_projecao(jsonb) is 'ScenarioSimulator (seção 51): projeção financeira mês a mês (seção 30) — clientes/portas/faturamento parceiro/revenue share/mínimo/receita OptiMon/opex incremental/resultado/margem/CAPEX/fluxo de caixa/cash flow acumulado. Cada linha em jsonb, guardada em simulacoes.resultado.';

-- app.calcular_roi(): ROICalculator (seção 51/31). ROI = (benefício líquido acumulado -
-- investimento) / investimento, lido diretamente de fluxo_caixa_acumulado no mês pedido
-- (que já é resultado_acumulado - capex_acumulado — ver comentário da função acima).
-- Nunca divide por zero (seção 31): investimento=0 → "N/A".
create or replace function app.calcular_roi(p_projecao jsonb, p_investimento numeric, p_mes integer)
returns jsonb
language plpgsql
stable
as $$
declare
  v_linha jsonb;
  v_fluxo_acumulado numeric;
begin
  if p_investimento is null or p_investimento = 0 then
    return jsonb_build_object('mes', p_mes, 'roi', null, 'texto', 'N/A — sem CAPEX incremental (seção 31).');
  end if;

  select value into v_linha from jsonb_array_elements(p_projecao->'meses') where (value->>'mes')::integer = p_mes;
  if v_linha is null then
    return jsonb_build_object('mes', p_mes, 'roi', null, 'texto', 'N/A — mês fora do horizonte simulado.');
  end if;

  v_fluxo_acumulado := (v_linha->>'fluxo_caixa_acumulado')::numeric;
  return jsonb_build_object(
    'mes', p_mes,
    'roi', round(v_fluxo_acumulado / p_investimento, 4),
    'texto', round((v_fluxo_acumulado / p_investimento) * 100, 2) || '%'
  );
end;
$$;

comment on function app.calcular_roi(jsonb, numeric, integer) is 'ROICalculator (seção 31): ROI no mês N = fluxo_caixa_acumulado(N) / investimento. Chamar para N = 12/36/48/60 (seção 31 pede os 4 horizontes).';

-- app.calcular_payback(): PaybackCalculator. "Mês em que Fluxo de caixa acumulado >=
-- investimento" (seção 32, literal — cash_flow_acumulado é fluxo_caixa_acumulado, já
-- líquido de CAPEX). Exemplo do prompt: CAPEX R$10.000, mês 14 com cash flow acumulado
-- R$10.500 → payback = 14 meses.
create or replace function app.calcular_payback(p_projecao jsonb, p_investimento numeric)
returns jsonb
language plpgsql
stable
as $$
declare
  r record;
begin
  if p_investimento is null or p_investimento = 0 then
    return jsonb_build_object('mes', null, 'texto', 'N/A — sem CAPEX incremental.');
  end if;

  for r in
    select (value->>'mes')::integer as mes, (value->>'fluxo_caixa_acumulado')::numeric as fluxo_caixa_acumulado
    from jsonb_array_elements(p_projecao->'meses')
    order by (value->>'mes')::integer
  loop
    if r.fluxo_caixa_acumulado >= p_investimento then
      return jsonb_build_object('mes', r.mes, 'texto', r.mes || ' meses');
    end if;
  end loop;

  return jsonb_build_object('mes', null, 'texto', 'Não recuperado no período (seção 32).');
end;
$$;

comment on function app.calcular_payback(jsonb, numeric) is 'PaybackCalculator (seção 32): primeiro mês em que fluxo_caixa_acumulado >= investimento. "Não recuperado no período" se nunca acontecer dentro do horizonte simulado.';
