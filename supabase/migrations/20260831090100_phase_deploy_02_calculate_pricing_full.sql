-- OptiMon — Fase 2.2.1 (Parte 2) — seção 32: "Pricing Engine centralizado no backend".
--
-- app.simular_precificacao_completa / public.pricing_calculate_full são a fonte única de
-- verdade que api/lib/calculatePricing.js chama — o frontend React NUNCA reimplementa a
-- fórmula (seção 32/33), só exibe o que este wrapper devolve. Diferente de
-- pricing_economics_with_floor (que exige um contrato_id já existente), esta função
-- calcula "do zero" a partir de cidade/pop/clientes/ARPU — exatamente o que a tela "NOVA
-- SIMULAÇÃO" (seção 22/35) precisa antes de qualquer contrato existir. Reaproveita as
-- MESMAS funções de composição (app.calcular_composicao_piso_minimo, o caso especial MAX
-- literal da Fase 2.2.1) para nunca divergir do que já vale para contratos reais.

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
  v_composicao_mode text := coalesce(p_params->>'composicao_mode', 'MAX');
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
  v_total_payable numeric;
  v_receita_parceiro numeric;
  v_desconto jsonb;
  v_governanca jsonb;
begin
  if v_cidade_id is null then
    raise exception 'cidade_id é obrigatório para calcular a precificação (seção 32).';
  end if;

  -- Seção 25/41: se pons_count não veio explícito (infra já provisionada), deriva de
  -- clientes via ceil(clientes/capacidade) — nunca os dois se contradizem silenciosamente,
  -- pons_count explícito sempre vence (reflete a infraestrutura de fato instalada).
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

  -- Mesma lógica de composição de app.get_economia_com_piso (seção 21 da Fase 2.2.1),
  -- só que parametrizada diretamente em vez de lida de contrato_pricing_config — nunca
  -- diverge da fórmula usada para contratos reais.
  declare
    v_revenue_share numeric := round(coalesce(v_faturamento, 0) * coalesce(v_revenue_share_pct, 0), 2);
  begin
    if v_composicao_mode = 'FLOOR_ONLY' then
      v_total_payable := v_piso;
    elsif v_composicao_mode = 'MINIMUM_ONLY' then
      v_total_payable := v_minimo_contratual;
    elsif v_composicao_mode = 'MAX' then
      v_total_payable := greatest(v_piso, v_revenue_share);
    elsif v_composicao_mode = 'SUM' then
      v_total_payable := v_piso + v_minimo_contratual + v_revenue_share;
    else
      v_base := app.calcular_composicao_piso_minimo(v_composicao_mode::infra_floor_composition_mode, v_piso, v_minimo_contratual);
      v_total_payable := v_base;
    end if;

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
comment on function app.simular_precificacao_completa(jsonb) is 'Pricing Engine centralizado (seção 32) — cálculo completo a partir de cidade/pop/clientes/ARPU, sem exigir contrato prévio. Fonte única para POST /api/pricing/calculate.';

create or replace function public.pricing_calculate_full(p_params jsonb)
returns jsonb
language sql
stable
security invoker
as $$
  select app.simular_precificacao_completa(p_params);
$$;
comment on function public.pricing_calculate_full(jsonb) is 'POST /api/pricing/calculate — Pricing Engine completo (seção 32). Entrada: {cidade_id, pop_id?, clientes, arpu, faturamento?, revenue_share_pct?, composicao_mode?, preco_proposto?, pons_count?, pricing_version?}. Backend sempre recalcula — seção 33.';

grant execute on function public.pricing_calculate_full(jsonb) to authenticated;
