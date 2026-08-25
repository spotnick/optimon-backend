-- OptiMon — Fase 2.1
-- Seção 12: Multi-POP — a capacidade consolidada por contrato (vw_capacidade_contrato,
-- Fase 1.1) e por POP (vw_capacidade_pop, Fase 1.1, city-wide) já existiam desde a Fase
-- 1.1 e já são exercitadas pelo TESTE 20 da Fase 2 (3 portas em 2 POPs = 384 capacidade
-- consolidada). O que faltava: uma forma de mostrar a capacidade POR POP de um contrato
-- específico (não city-wide) lado a lado com o consolidado — é isso que esta migration
-- expõe, para o dashboard/API (seção 50) não precisar recalcular isso em JS.

create or replace function app.get_capacidade_multi_pop_contrato(p_contrato_id uuid)
returns jsonb
language sql
stable
as $$
  with por_pop as (
    select
      pop.id as pop_id,
      pop.codigo as pop_codigo,
      pop.nome as pop_nome,
      count(distinct p.id) as portas,
      coalesce(sum(p.capacidade_max_assinantes), 0) as capacidade_maxima,
      coalesce(sum(p.capacidade_utilizada_assinantes), 0) as clientes_ativos,
      coalesce(sum(p.capacidade_disponivel), 0) as capacidade_disponivel
    from public.contrato_fibras cf
    join public.infra_portas_pon p on p.id = cf.porta_pon_id
    join public.infra_pops pop on pop.id = p.pop_id
    where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null and cf.porta_pon_id is not null
    group by pop.id, pop.codigo, pop.nome
  )
  select jsonb_build_object(
    'pops', coalesce(jsonb_agg(jsonb_build_object(
      'pop_id', pop_id, 'pop_codigo', pop_codigo, 'pop_nome', pop_nome,
      'portas', portas, 'capacidade_maxima', capacidade_maxima,
      'clientes_ativos', clientes_ativos, 'capacidade_disponivel', capacidade_disponivel
    ) order by pop_codigo), '[]'::jsonb),
    'consolidado', jsonb_build_object(
      'pops_utilizados', count(*),
      'portas_total', coalesce(sum(portas), 0),
      'capacidade_maxima_total', coalesce(sum(capacidade_maxima), 0),
      'clientes_ativos_total', coalesce(sum(clientes_ativos), 0),
      'capacidade_disponivel_total', coalesce(sum(capacidade_disponivel), 0)
    )
  )
  from por_pop;
$$;
comment on function app.get_capacidade_multi_pop_contrato(uuid) is 'Seção 12 (Fase 2.1): capacidade por POP + consolidado de um contrato específico (complementa vw_capacidade_pop, que é city-wide, e vw_capacidade_contrato, que só devolve o total). Exemplo da seção 12: POP-01=2 portas/256, POP-02=3 portas/384, POP-03=1 porta/128 → consolidado 6 portas/768.';

-- Wrapper público (seção 50 — mesmo padrão dos outros 9 wrappers pricing_*).
create or replace function public.pricing_capacity_by_pop(p_contrato_id uuid)
returns jsonb
language sql
stable
security invoker
as $$
  select app.get_capacidade_multi_pop_contrato(p_contrato_id);
$$;
comment on function public.pricing_capacity_by_pop(uuid) is 'Seção 12/50 (Fase 2.1) — capacidade por POP + consolidado de um contrato, para o dashboard/API não recalcular isso em JS.';
grant execute on function public.pricing_capacity_by_pop(uuid) to authenticated;
