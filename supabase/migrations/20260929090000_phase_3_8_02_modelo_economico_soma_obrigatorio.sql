-- OptiMon — Fase 3.8, item 2/3 (Correção do modelo econômico oficial): elimina
-- toda lógica de "MAX(mínimo/piso, revenue share)" do Pricing Engine — o modelo
-- oficial passa a ser, sem exceção, MÍNIMO + REVENUE SHARE (sempre somado).
--
-- CONFIRMADO EXPLICITAMENTE COM O USUÁRIO (não foi assumido): existem hoje 2
-- dimensões independentes que produziam "MAX" em vez de soma:
--   1) contrato_pricing_config.modelo_cobranca ('SOMA'/'MAX') — usada por
--      app.calcular_cobranca_hibrida e pelo ramo genérico de
--      app.get_economia_com_piso/app.simular_projecao.
--   2) contrato_pricing_config.infra_floor_composition_mode — tem um valor
--      'MAX' PRÓPRIO (Fase 2.2.1, seção 21), que desde aquela fase é o DEFAULT
--      para contratos NOVOS e faz greatest(floor, revenue_share) diretamente,
--      ignorando modelo_cobranca por completo.
-- No ambiente de teste local, 3 de 9 contratos usavam modelo_cobranca='MAX' e
-- 1 usava infra_floor_composition_mode='MAX' — todos passam a ser calculados
-- como SOMA a partir desta migration. O usuário confirmou explicitamente que
-- isso muda o valor mensal cobrado desses contratos e aprovou essa mudança.
--
-- Nenhuma tabela é recriada, nenhum valor de enum é removido (DROP VALUE não
-- existe nativamente no Postgres sem reconstruir o tipo — mudança de alto
-- risco e desnecessária aqui). Em vez disso: (a) toda função de cálculo para
-- de ramificar em MAX — o valor 'MAX', se algum dia reaparecer numa linha,
-- passa a se comportar de forma idêntica a FLOOR_AS_MINIMUM/SOMA, nunca mais
-- greatest(); (b) as linhas hoje em MAX são normalizadas para o valor
-- correspondente em SOMA/FLOOR_AS_MINIMUM, para o dado parar de mentir sobre o
-- que está de fato sendo calculado; (c) os defaults das colunas mudam para
-- refletir SOMA/FLOOR_AS_MINIMUM em contratos novos; (d) a UI para de oferecer
-- "MAX" como opção selecionável.

-- 1) app.calcular_cobranca_hibrida — sempre mínimo + revenue share.
create or replace function app.calcular_cobranca_hibrida(p_contrato_id uuid, p_faturamento numeric)
returns numeric
language plpgsql
stable
as $$
declare
  v_percentual numeric;
  v_minimo numeric;
  v_share numeric;
begin
  select percentual_revenue_share
  into v_percentual
  from public.contrato_pricing_config
  where contrato_id = p_contrato_id;

  if not found then
    raise exception 'Contrato % não possui contrato_pricing_config cadastrado.', p_contrato_id;
  end if;

  v_minimo := app.calcular_minimo_contratual(p_contrato_id);
  v_share := coalesce(p_faturamento, 0) * coalesce(v_percentual, 0);

  return v_minimo + v_share;
end;
$$;
comment on function app.calcular_cobranca_hibrida(uuid, numeric) is 'COBRANÇA = MÍNIMO + REVENUE SHARE — modelo econômico oficial único desde a Fase 3.8 (item 3, correção crítica). Até a Fase 3.8 esta função também aceitava um modo "MAX" (greatest(mínimo, revenue share)), pedido explicitamente pela Fase 1.2 — removido: o prompt da Fase 3.8 identificou essa opção como uma inconsistência a corrigir, confirmado com o usuário, e agora ela sempre soma.';

-- 2) app.calcular_composicao_piso_minimo — 'MAX' deixa de ser greatest(); vira
--    idêntico a FLOOR_AS_MINIMUM (o Floor sozinho alimenta a base, que depois
--    sempre soma com Revenue Share em quem chama esta função). Preserva o
--    enum (nenhuma linha antiga quebra), só muda o que ele SIGNIFICA na prática.
create or replace function app.calcular_composicao_piso_minimo(p_modo public.infra_floor_composition_mode, p_infrastructure_floor numeric, p_minimo_contratual numeric)
returns numeric
language sql
immutable
as $$
  select case p_modo
    when 'FLOOR_ONLY' then p_infrastructure_floor
    when 'MINIMUM_ONLY' then p_minimo_contratual
    when 'FLOOR_AS_MINIMUM' then p_infrastructure_floor
    when 'SUM' then p_infrastructure_floor + p_minimo_contratual
    when 'MAX' then p_infrastructure_floor
  end;
$$;
comment on function app.calcular_composicao_piso_minimo(public.infra_floor_composition_mode, numeric, numeric) is 'Fase 2.2 (seção 32/33), corrigido na Fase 3.8 (item 3): ''MAX'' deixou de fazer greatest(floor, mínimo) — agora é idêntico a FLOOR_AS_MINIMUM (usa só o Floor como base), porque a base sempre soma com Revenue Share em quem chama esta função (nunca mais greatest com Revenue Share em lugar nenhum do sistema). Mantido no enum só para não quebrar linhas antigas — nenhuma linha nova deveria usar este valor (ver default da coluna, alterado nesta mesma migration).';

-- 3) app.get_economia_com_piso — remove o ramo literal 'MAX' (que ignorava
--    modelo_cobranca) e remove o fallback greatest() do ramo genérico: a base
--    (floor/mínimo, conforme o modo de composição) SEMPRE soma com Revenue
--    Share, para qualquer contrato, independente de modelo_cobranca.
create or replace function app.get_economia_com_piso(p_contrato_id uuid, p_faturamento_parceiro numeric, p_pop_id uuid default null, p_pricing_version text default null)
returns jsonb
language plpgsql
stable
as $$
declare
  v_contrato record;
  v_config record;
  v_floor_data jsonb;
  v_floor numeric;
  v_minimo numeric;
  v_revenue_share numeric;
  v_base numeric;
  v_total_payable numeric;
  v_receita_parceiro numeric;
begin
  select id, cidade_id into v_contrato from public.contratos where id = p_contrato_id;
  if not found then
    raise exception 'Contrato % não encontrado.', p_contrato_id;
  end if;

  select modelo_cobranca, percentual_revenue_share, infra_floor_composition_mode, minimum_infrastructure_floor_enforced
  into v_config
  from public.contrato_pricing_config
  where contrato_id = p_contrato_id;

  if not found then
    raise exception 'Contrato % não possui contrato_pricing_config cadastrado.', p_contrato_id;
  end if;

  v_floor_data := app.calculate_infrastructure_floor_for_contract(p_contrato_id, p_pop_id, p_pricing_version);
  v_floor := (v_floor_data ->> 'floor_price')::numeric;
  v_minimo := app.calcular_minimo_contratual(p_contrato_id);
  v_revenue_share := round(coalesce(p_faturamento_parceiro, 0) * coalesce(v_config.percentual_revenue_share, 0), 2);

  if v_config.infra_floor_composition_mode = 'FLOOR_ONLY' then
    v_total_payable := v_floor;
  elsif v_config.infra_floor_composition_mode = 'MINIMUM_ONLY' then
    v_total_payable := app.calcular_cobranca_hibrida(p_contrato_id, p_faturamento_parceiro);
  else
    -- Fase 3.8 (item 3): sempre soma — o ramo literal 'MAX' (greatest(floor,
    -- revenue_share), Fase 2.2.1 seção 21) e o fallback greatest() por
    -- modelo_cobranca (Fase 2.2) foram os dois pontos identificados como a
    -- inconsistência a corrigir. 'MAX' como infra_floor_composition_mode cai
    -- aqui e usa o Floor como base (ver calcular_composicao_piso_minimo,
    -- corrigida acima) — resultado idêntico a FLOOR_AS_MINIMUM.
    v_base := app.calcular_composicao_piso_minimo(v_config.infra_floor_composition_mode, v_floor, v_minimo);
    v_total_payable := v_base + v_revenue_share;
  end if;

  if v_config.minimum_infrastructure_floor_enforced and v_total_payable < v_floor then
    v_total_payable := v_floor;
  end if;

  v_receita_parceiro := coalesce(p_faturamento_parceiro, 0) - v_total_payable;

  return jsonb_build_object(
    'contrato_id', p_contrato_id,
    'infrastructure_floor', v_floor,
    'pons_count', (v_floor_data ->> 'pons_count')::integer,
    'minimum_contractual_fee', v_minimo,
    'revenue_share', v_revenue_share,
    'composicao_mode', v_config.infra_floor_composition_mode,
    'modelo_cobranca', v_config.modelo_cobranca,
    'minimum_infrastructure_floor_enforced', v_config.minimum_infrastructure_floor_enforced,
    'total_payable', round(v_total_payable, 2),
    'receita_optimon', round(v_total_payable, 2),
    'receita_parceiro', round(v_receita_parceiro, 2),
    'margem_parceiro', case when coalesce(p_faturamento_parceiro, 0) > 0 then round(v_receita_parceiro / p_faturamento_parceiro, 4) else null end
  );
end;
$$;
comment on function app.get_economia_com_piso(uuid, numeric, uuid, text) is 'Fase 2.2 (seção 17/30) + Fase 2.2.1 (seções 16/21), corrigido na Fase 3.8 (item 3): modelo econômico oficial único é MÍNIMO/FLOOR + REVENUE SHARE (sempre somado) — nenhum ramo greatest() sobrevive. FLOOR_ONLY (só floor, sem RS) e MINIMUM_ONLY (mínimo+RS via calcular_cobranca_hibrida) continuam disponíveis por não implementarem MAX — servem casos legítimos distintos (ex.: Dark Fiber sem componente de Revenue Share). Rede de proteção "enforced" inalterada.';

-- 4) app.simular_projecao — mesma correção (projeção financeira do simulador
--    de cenários, Fase 2 seção 55/2.6): sempre soma, nunca mais greatest().
create or replace function app.simular_projecao(p_params jsonb)
returns jsonb
language plpgsql
stable
as $$
declare
  v_contrato_id uuid := nullif(p_params->>'contrato_id', '')::uuid;
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
  v_rampa_aplica_a public.rampa_alvo;
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
  v_fator_rampa_minimo numeric;
  v_fator_rampa_share numeric;
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
    select percentual_revenue_share, rampa_aplica_a into v_percentual, v_rampa_aplica_a
    from public.contrato_pricing_config where contrato_id = v_contrato_id;
    v_minimo_base := app.calcular_minimo_contratual(v_contrato_id);
  else
    v_percentual := coalesce((p_params->>'revenue_share_percent')::numeric, 0);
    v_minimo_base := coalesce((p_params->>'minimo_mensal')::numeric, 0);
    -- Simulação ad hoc (sem contrato real): default 'AMBOS' preserva o comportamento
    -- da Fase 2 para quem não informar rampa_aplica_a explicitamente nos parâmetros.
    v_rampa_aplica_a := coalesce(nullif(p_params->>'rampa_aplica_a', '')::public.rampa_alvo, 'AMBOS');
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

    -- 5) Mínimo e Revenue Share, cada um com sua própria rampa de maturação (seção 25/26),
    --    respeitando INTEGRALMENTE rampa_aplica_a (seção 4 da Fase 2.1): o componente que
    --    não está autorizado a receber rampa fica sempre em 100% (fator 1.00) nesse mês —
    --    nunca cai no fallback da régua global "AMBOS" por engano.
    v_fator_rampa_minimo := case when v_rampa_aplica_a in ('FIXO_MINIMO', 'AMBOS')
      then app.get_fator_rampa(v_contrato_id, m, 'FIXO_MINIMO') else 1.00 end;
    v_fator_rampa_share := case when v_rampa_aplica_a in ('REVENUE_SHARE', 'AMBOS')
      then app.get_fator_rampa(v_contrato_id, m, 'REVENUE_SHARE') else 1.00 end;

    v_minimo := round(v_minimo_base * v_fator_reajuste * v_fator_rampa_minimo, 2);
    v_share := round(v_faturamento_parceiro * coalesce(v_percentual, 0) * v_fator_reajuste * v_fator_rampa_share, 2);

    -- 6) Cobrança total: modelo econômico oficial único desde a Fase 3.8 (item 3) —
    --    sempre mínimo + revenue share, nunca mais greatest() (o modo 'MAX' da Fase
    --    1.2 foi identificado como a inconsistência a corrigir e removido).
    v_receita_optimon := v_minimo + v_share;

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
      'fator_rampa_minimo', v_fator_rampa_minimo,
      'fator_rampa_revenue_share', v_fator_rampa_share,
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
    'rampa_aplica_a', v_rampa_aplica_a,
    'capex_total', v_capex,
    'meses', v_meses_arr
  );
end;
$$;
comment on function app.simular_projecao(jsonb) is 'Fase 2/2.1 (seções 22-33/55) + Fase 2.6, corrigido na Fase 3.8 (item 3): projeção mês-a-mês do simulador de cenários. Cobrança total = mínimo + revenue share, sempre somado (modo "MAX" da Fase 1.2 removido — identificado como a inconsistência a corrigir).';

-- 5) app.simular_precificacao_completa — default de composicao_mode deixa de
--    ser 'MAX'; o ramo literal 'MAX' é removido (cai no ramo genérico, que já
--    trata 'MAX' como FLOOR_ONLY-equivalente via calcular_composicao_piso_minimo
--    corrigida acima). Esta função já não usa a composição para o valor
--    efetivamente cobrado desde a Fase 3.1 (o preço proposto é sempre o que
--    é cobrado) — a composição aqui é só a referência de garantia mínima,
--    mas precisa da mesma correção por consistência e honestidade do dado.
create or replace function app.simular_precificacao_completa(p_params jsonb)
returns jsonb
language plpgsql
stable
as $$
declare
  v_cidade_id uuid := nullif(p_params->>'cidade_id', '')::uuid;
  v_pop_id uuid := nullif(p_params->>'pop_id', '')::uuid;
  v_pricing_version text := nullif(p_params->>'pricing_version', '');
  v_clientes integer := coalesce((p_params->>'clientes')::integer, 0);
  v_arpu numeric := coalesce((p_params->>'arpu')::numeric, 0);
  v_faturamento numeric := nullif(p_params->>'faturamento', '')::numeric;
  v_revenue_share_pct numeric := coalesce((p_params->>'revenue_share_pct')::numeric, 0.12);
  v_composicao_mode text := coalesce(p_params->>'composicao_mode', 'FLOOR_AS_MINIMUM');
  v_preco_proposto numeric := nullif(p_params->>'preco_proposto', '')::numeric;
  v_minimo_contratual numeric := coalesce((p_params->>'minimo_contratual')::numeric, 0);
  v_pons_count integer := nullif(p_params->>'pons_count', '')::integer;

  v_floor jsonb;
  v_abertura numeric;
  v_recomendado numeric;
  v_piso numeric;
  v_max_discount numeric;
  v_min_autorizado numeric;
  v_base numeric;
  v_piso_garantido_composicao numeric;
  v_total_payable numeric;
  v_receita_parceiro numeric;
  v_desconto jsonb;
  v_governanca jsonb;
begin
  if v_cidade_id is null then
    raise exception 'cidade_id é obrigatório para calcular a precificação (seção 32).';
  end if;

  if v_pons_count is null then
    v_pons_count := app.pons_necessarias_para_clientes(v_clientes, v_cidade_id, v_pricing_version);
  end if;

  v_floor := app.calculate_infrastructure_floor(v_cidade_id, v_pop_id, v_pricing_version, v_pons_count);
  v_abertura := (v_floor ->> 'opening_price')::numeric;
  v_recomendado := (v_floor ->> 'recommended_price')::numeric;
  v_piso := (v_floor ->> 'floor_price')::numeric;

  -- Sem preço proposto explícito (tela ainda não negociou), a régua usa o RECOMENDADO
  -- como referência — nunca assume ABERTURA nem PISO por padrão.
  if v_preco_proposto is null then
    v_preco_proposto := v_recomendado;
  end if;

  v_max_discount := app.get_infra_floor_param('MAX_OVERRIDE_DISCOUNT_PERCENT', v_cidade_id, v_pricing_version);
  v_min_autorizado := app.calcular_preco_minimo_autorizado(v_abertura, v_max_discount);
  v_desconto := app.calcular_desconto_comercial(v_abertura, v_preco_proposto, v_recomendado);
  v_governanca := jsonb_build_object(
    'tri_state', app.check_infrastructure_floor_governance(v_preco_proposto, v_recomendado, v_piso),
    'por_papel', app.check_infrastructure_floor_governance_role(v_preco_proposto, v_abertura, v_recomendado, v_piso, v_max_discount)
  );

  if v_faturamento is null then
    v_faturamento := round(v_clientes * v_arpu, 2);
  end if;

  -- FASE 3 (seção 4/15): "toda a proposta" (receita, ROI, payback, e o que o
  -- contrato gerado a partir dela vai cobrar) usa EXATAMENTE o preço
  -- proposto — nunca um valor recalculado por composição piso/revenue-share.
  -- A composição antiga continua calculada como referência de garantia
  -- mínima de infraestrutura (Take-or-Pay técnico), exposta à parte, mas
  -- nunca mais confundida com "o preço da proposta".
  declare
    v_revenue_share numeric := round(coalesce(v_faturamento, 0) * coalesce(v_revenue_share_pct, 0), 2);
  begin
    if v_composicao_mode = 'FLOOR_ONLY' then
      v_piso_garantido_composicao := v_piso;
    elsif v_composicao_mode = 'MINIMUM_ONLY' then
      v_piso_garantido_composicao := v_minimo_contratual;
    elsif v_composicao_mode = 'SUM' then
      v_piso_garantido_composicao := v_piso + v_minimo_contratual + v_revenue_share;
    else
      -- Fase 3.8 (item 3): ramo literal 'MAX' removido — cai aqui, e
      -- calcular_composicao_piso_minimo (corrigida nesta mesma migration)
      -- trata 'MAX' como FLOOR_AS_MINIMUM (usa só o Floor), nunca mais
      -- greatest(piso, revenue_share).
      v_base := app.calcular_composicao_piso_minimo(v_composicao_mode::infra_floor_composition_mode, v_piso, v_minimo_contratual);
      v_piso_garantido_composicao := v_base;
    end if;

    v_total_payable := v_preco_proposto;
    v_receita_parceiro := coalesce(v_faturamento, 0) - v_total_payable;

    return jsonb_build_object(
      'cidade_id', v_cidade_id,
      'pop_id', v_pop_id,
      'pricing_version', coalesce(v_pricing_version, v_floor->>'pricing_version'),
      'clientes', v_clientes,
      'pons_count', v_pons_count,
      'arpu', v_arpu,
      'faturamento', v_faturamento,
      'floor', v_piso,
      'recommended', v_recomendado,
      'opening', v_abertura,
      'preco_proposto', v_preco_proposto,
      'revenue_share_pct', v_revenue_share_pct,
      'revenue_share_value', v_revenue_share,
      'composicao_mode', v_composicao_mode,
      'piso_garantido_composicao', round(v_piso_garantido_composicao, 2),
      'total_payable', round(v_total_payable, 2),
      'partner_revenue', round(v_receita_parceiro, 2),
      'partner_margin', case when coalesce(v_faturamento, 0) > 0 then round(v_receita_parceiro / v_faturamento, 4) else null end,
      'discount', v_desconto,
      'max_override_discount_percent', v_max_discount,
      'preco_minimo_autorizado', v_min_autorizado,
      'governance_status', v_governanca
    );
  end;
end;
$$;
comment on function app.simular_precificacao_completa(jsonb) is 'Fase 2.2/2.2.1 + Fase 3 (seção 4/15) + Fase 3.8 (item 3): régua comercial completa da proposta. O valor efetivamente cobrado é sempre o preço proposto (desde a Fase 3.1); "piso_garantido_composicao" é só referência de garantia mínima, agora também sem greatest() — default de composicao_mode passou de MAX para FLOOR_AS_MINIMUM.';

-- 6) Normaliza os dados já existentes (aprovado explicitamente pelo usuário):
--    contratos hoje em MAX passam a refletir, no próprio dado, o modo pelo
--    qual já vão ser calculados a partir de agora — SOMA/FLOOR_AS_MINIMUM.
update public.contrato_pricing_config set modelo_cobranca = 'SOMA' where modelo_cobranca = 'MAX';
update public.contrato_pricing_config set infra_floor_composition_mode = 'FLOOR_AS_MINIMUM' where infra_floor_composition_mode = 'MAX';

-- 7) Defaults de coluna para contratos NOVOS: SOMA já era o default de
--    modelo_cobranca desde sempre (mantido); infra_floor_composition_mode
--    tinha DEFAULT 'MAX' desde a Fase 2.2.1 (seção 21) — corrigido para
--    FLOOR_AS_MINIMUM, que agora é o modo recomendado oficial.
alter table public.contrato_pricing_config alter column infra_floor_composition_mode set default 'FLOOR_AS_MINIMUM';
comment on column public.contrato_pricing_config.infra_floor_composition_mode is 'Fase 2.2 (seção 32/33) + Fase 2.2.1 (seção 21), corrigido na Fase 3.8 (item 3): como compor Infrastructure Floor (F) × Minimum Contractual Fee (M) na base que depois SEMPRE soma com Revenue Share. Default FLOOR_AS_MINIMUM para contratos novos a partir desta fase (antes era MAX, Fase 2.2.1 — revertido: MAX foi identificado como a inconsistência a corrigir). ''MAX'' continua um valor válido do enum por compatibilidade, mas agora se comporta de forma idêntica a FLOOR_AS_MINIMUM (nunca mais greatest com Revenue Share) — nenhuma linha nova deveria usar esse valor.';
