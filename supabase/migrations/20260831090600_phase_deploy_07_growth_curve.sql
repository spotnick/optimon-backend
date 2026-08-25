-- OptiMon — Fase 2.2.1 (Parte 2) — seção 24/25: dados para os 2 gráficos do frontend.
-- "CRESCIMENTO DA BASE × RECEITA OPTIMON" e "CLIENTES × PONs NECESSÁRIAS" precisam de uma
-- série de pontos (não um cálculo único) — em vez do frontend chamar
-- POST /api/pricing/calculate uma vez por ponto (N round-trips, e reimplementaria a
-- decisão de "quais pontos plotar" fora do servidor), este wrapper devolve a curva
-- inteira em UMA chamada, reaproveitando app.simular_precificacao_completa ponto a ponto
-- — nunca uma fórmula nova, só o mesmo motor chamado em loop.

create or replace function app.simular_curva_crescimento(p_params jsonb, p_clientes_max integer default null, p_passos integer default 20)
returns jsonb
language plpgsql
stable
as $$
declare
  v_max integer := coalesce(p_clientes_max, greatest(coalesce((p_params->>'clientes')::integer, 128) * 2, 256));
  v_passos integer := greatest(coalesce(p_passos, 20), 2);
  v_passo_tamanho numeric := v_max::numeric / v_passos;
  v_pontos jsonb := '[]'::jsonb;
  v_clientes integer;
  v_ponto jsonb;
  i integer;
begin
  for i in 0..v_passos loop
    v_clientes := round(i * v_passo_tamanho)::integer;
    v_ponto := app.simular_precificacao_completa(p_params || jsonb_build_object('clientes', v_clientes, 'pons_count', null));
    v_pontos := v_pontos || jsonb_build_object(
      'clientes', v_clientes,
      'pons_count', v_ponto->>'pons_count',
      'floor', v_ponto->>'floor',
      'revenue_share_value', v_ponto->>'revenue_share_value',
      'total_payable', v_ponto->>'total_payable',
      'partner_revenue', v_ponto->>'partner_revenue',
      'faturamento', v_ponto->>'faturamento'
    );
  end loop;

  return v_pontos;
end;
$$;
comment on function app.simular_curva_crescimento(jsonb, integer, integer) is 'Série de pontos para os gráficos "CRESCIMENTO DA BASE × RECEITA OPTIMON" e "CLIENTES × PONs NECESSÁRIAS" (seção 24/25) — reaproveita simular_precificacao_completa ponto a ponto, nunca uma fórmula paralela.';

create or replace function public.pricing_growth_curve(p_params jsonb, p_clientes_max integer default null, p_passos integer default 20)
returns jsonb
language sql
stable
security invoker
as $$
  select app.simular_curva_crescimento(p_params, p_clientes_max, p_passos);
$$;
comment on function public.pricing_growth_curve(jsonb, integer, integer) is 'GET/POST apoio aos gráficos do frontend (seção 24/25) — mesma entrada de pricing_calculate_full, mais clientes_max/passos.';

grant execute on function public.pricing_growth_curve(jsonb, integer, integer) to authenticated;
