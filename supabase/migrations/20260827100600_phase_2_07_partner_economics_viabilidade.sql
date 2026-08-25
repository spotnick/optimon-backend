-- OptiMon — Fase 2
-- Seções 34-35, 57: PartnerEconomicsCalculator (seção 51) — o negócio precisa ser bom
-- para as duas partes, não só maximizar a receita do OptiMon (seção 62). Classificação
-- de viabilidade (seção 57) usa parâmetros configuráveis; quando ainda não configurados,
-- a função NUNCA inventa um limiar — devolve "PARAMETRIZÁVEL", nunca uma classificação
-- fabricada (seção 65).

-- app.calcular_economia_parceiro(): Faturamento (-) pagamento OptiMon (=) receita
-- restante (-) custos próprios estimados (=) margem estimada do parceiro (seção 34).
create or replace function app.calcular_economia_parceiro(p_faturamento_parceiro numeric, p_pagamento_optimon numeric, p_custos_proprios_parceiro numeric default 0)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'faturamento_parceiro', coalesce(p_faturamento_parceiro, 0),
    'pagamento_optimon', coalesce(p_pagamento_optimon, 0),
    'receita_restante', coalesce(p_faturamento_parceiro, 0) - coalesce(p_pagamento_optimon, 0),
    'custos_proprios_parceiro', coalesce(p_custos_proprios_parceiro, 0),
    'margem_estimada_parceiro', (coalesce(p_faturamento_parceiro, 0) - coalesce(p_pagamento_optimon, 0)) - coalesce(p_custos_proprios_parceiro, 0),
    'margem_percentual_parceiro', case when coalesce(p_faturamento_parceiro, 0) > 0
      then round((((coalesce(p_faturamento_parceiro, 0) - coalesce(p_pagamento_optimon, 0)) - coalesce(p_custos_proprios_parceiro, 0)) / p_faturamento_parceiro), 4)
      else null
    end
  );
$$;

comment on function app.calcular_economia_parceiro(numeric, numeric, numeric) is 'Seção 34: economia do parceiro. Faturamento - pagamento OptiMon = receita restante; receita restante - custos próprios = margem estimada do parceiro.';

-- app.avaliar_viabilidade_parceiro(): seção 35 — ALERTA (não bloqueio automático) quando
-- a margem do parceiro fica abaixo do limite configurado (partner_minimum_margin, por
-- contrato; sem fallback global inventado — se não configurado, não há alerta possível,
-- e a função diz isso explicitamente).
create or replace function app.avaliar_viabilidade_parceiro(p_contrato_id uuid, p_margem_percentual_parceiro numeric)
returns text
language plpgsql
stable
as $$
declare
  v_minimo numeric;
begin
  select margem_minima_parceiro_percent into v_minimo from public.contrato_pricing_config where contrato_id = p_contrato_id;

  if v_minimo is null then
    return 'PARAMETRIZÁVEL — partner_minimum_margin não definido para este contrato (seção 35).';
  end if;
  if p_margem_percentual_parceiro is null then
    return 'N/A — margem do parceiro não informada.';
  end if;
  if p_margem_percentual_parceiro < v_minimo then
    return 'ALERTA: MODELO COMERCIAL POTENCIALMENTE INVIÁVEL PARA O PARCEIRO (margem estimada ' || round(p_margem_percentual_parceiro * 100, 2) || '% abaixo do mínimo configurado ' || round(v_minimo * 100, 2) || '%).';
  end if;
  return 'OK — margem do parceiro dentro do limite configurado.';
end;
$$;

comment on function app.avaliar_viabilidade_parceiro(uuid, numeric) is 'Seção 35: alerta (não bloqueia) quando margem do parceiro < partner_minimum_margin. Nunca fabrica um limiar quando não configurado.';

-- Seção 57: classificação de negócio. Limiares configuráveis via pricing_parametros —
-- propositalmente SEM valor padrão inserido aqui (nenhuma linha é semeada para
-- VIABILIDADE_MARGEM_PARCEIRO_MINIMA_PADRAO / EXCELENCIA_ROI_MINIMO_PADRAO): até o
-- negócio decidir e cadastrar esses parâmetros, a função devolve PARAMETRIZÁVEL em vez de
-- uma classificação fabricada — mas a REGRA em si (não é "só visual") já está pronta e
-- passa a classificar de verdade assim que os parâmetros existirem.
create or replace function app.classificar_negocio(p_contrato_id uuid, p_margem_percentual_parceiro numeric, p_roi_optimon numeric default null)
returns text
language plpgsql
stable
as $$
declare
  v_margem_minima numeric;
  v_roi_excelencia numeric;
begin
  select margem_minima_parceiro_percent into v_margem_minima from public.contrato_pricing_config where contrato_id = p_contrato_id;
  if v_margem_minima is null then
    select valor into v_margem_minima from public.pricing_parametros
    where chave = 'VIABILIDADE_MARGEM_PARCEIRO_MINIMA_PADRAO' and (vigente_ate is null or vigente_ate >= current_date);
  end if;

  if v_margem_minima is null or p_margem_percentual_parceiro is null then
    return 'PARAMETRIZÁVEL — defina partner_minimum_margin (contrato) ou VIABILIDADE_MARGEM_PARCEIRO_MINIMA_PADRAO (global) para classificar (seção 57).';
  end if;

  if p_margem_percentual_parceiro < v_margem_minima then
    return 'NEGÓCIO INVIÁVEL';
  end if;

  select valor into v_roi_excelencia from public.pricing_parametros
  where chave = 'EXCELENCIA_ROI_MINIMO_PADRAO' and (vigente_ate is null or vigente_ate >= current_date);

  if v_roi_excelencia is not null and p_roi_optimon is not null and p_roi_optimon >= v_roi_excelencia then
    return 'EXCELENTE';
  end if;

  return 'NEGÓCIO VIÁVEL';
end;
$$;

comment on function app.classificar_negocio(uuid, numeric, numeric) is 'Seção 57: INVIAVEL (margem parceiro < mínimo configurado) / VIAVEL (>= mínimo) / EXCELENTE (margem parceiro OK + ROI OptiMon >= EXCELENCIA_ROI_MINIMO_PADRAO, quando este parâmetro existir). Regra de classificação de verdade, não só rótulo visual — mas nunca classifica com limiar inventado.';
