-- OptiMon — Fase 2.2.1 (Parte 2) — seção 26: tabela de simulação 12/36/48/60 meses.
-- Reaproveita app.simular_precificacao_completa (o MESMO motor da régua de preço da tela
-- de Nova Simulação) multiplicado pelo horizonte — nunca um cálculo paralelo. 48 meses é
-- o prazo contratual mínimo (nunca omitido da lista); 60 meses é só um cenário financeiro
-- adicional, não uma alternativa ao mínimo contratual.

create or replace function app.simular_tabela_horizontes(p_params jsonb, p_capex numeric default 0, p_opex_mensal numeric default 0, p_horizontes integer[] default array[12,36,48,60])
returns jsonb
language plpgsql
stable
as $$
declare
  v_ponto jsonb := app.simular_precificacao_completa(p_params);
  v_total_payable numeric := (v_ponto->>'total_payable')::numeric;
  v_partner_revenue numeric := (v_ponto->>'partner_revenue')::numeric;
  v_faturamento numeric := (v_ponto->>'faturamento')::numeric;
  v_resultado_mensal_parceiro numeric := v_partner_revenue - coalesce(p_opex_mensal, 0);
  v_linhas jsonb := '[]'::jsonb;
  h integer;
  v_receita_optimon numeric;
  v_receita_parceiro_total numeric;
  v_receita_total numeric;
  v_opex_total numeric;
  v_resultado numeric;
  v_roi numeric;
  v_payback_meses numeric;
begin
  foreach h in array p_horizontes loop
    v_receita_optimon := round(v_total_payable * h, 2);
    v_opex_total := round(coalesce(p_opex_mensal, 0) * h, 2);
    v_receita_parceiro_total := round(v_partner_revenue * h, 2);
    v_receita_total := round(v_faturamento * h, 2);
    v_resultado := round(v_receita_parceiro_total - v_opex_total, 2);

    v_roi := case when coalesce(p_capex, 0) > 0 then round((v_resultado - p_capex) / p_capex, 4) else null end;
    v_payback_meses := case when v_resultado_mensal_parceiro > 0 and coalesce(p_capex, 0) > 0
      then round(p_capex / v_resultado_mensal_parceiro, 1)
      else null
    end;

    v_linhas := v_linhas || jsonb_build_object(
      'meses', h,
      'minimo_contratual_flag', (h = 48),
      'receita_optimon', v_receita_optimon,
      'receita_parceiro', v_receita_parceiro_total,
      'receita_total', v_receita_total,
      'opex', v_opex_total,
      'resultado_parceiro', v_resultado,
      'roi', v_roi,
      'payback_meses', v_payback_meses
    );
  end loop;

  return jsonb_build_object('capex', coalesce(p_capex, 0), 'opex_mensal', coalesce(p_opex_mensal, 0), 'linhas', v_linhas);
end;
$$;
comment on function app.simular_tabela_horizontes(jsonb, numeric, numeric, integer[]) is 'Seção 26 — tabela 12/36/48/60 meses (48 = prazo contratual mínimo). Reaproveita app.simular_precificacao_completa, nunca um cálculo novo.';

create or replace function public.pricing_horizon_table(p_params jsonb, p_capex numeric default 0, p_opex_mensal numeric default 0, p_horizontes integer[] default array[12,36,48,60])
returns jsonb
language sql
stable
security invoker
as $$
  select app.simular_tabela_horizontes(p_params, p_capex, p_opex_mensal, p_horizontes);
$$;
comment on function public.pricing_horizon_table(jsonb, numeric, numeric, integer[]) is 'POST /api/pricing/horizon-table (seção 26).';

grant execute on function public.pricing_horizon_table(jsonb, numeric, numeric, integer[]) to authenticated;
