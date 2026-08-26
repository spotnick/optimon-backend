-- OptiMon — Fase 2.3: Módulo de Gestão de Cidades e Infraestrutura
-- Migration 4/4: uma única consulta que devolve toda a árvore de infraestrutura de uma
-- cidade (segmentos, postes, POPs -> cabos -> fibras, POPs -> portas PON) — alimenta a
-- tela "Editar Infraestrutura" (seção 21) sem N chamadas separadas por POP/cabo.

create or replace function public.pricing_city_infra_tree(p_cidade_id uuid)
returns jsonb
language plpgsql
stable
security invoker
as $$
declare
  v_cidade record;
  v_segmentos jsonb;
  v_postes jsonb;
  v_pops jsonb;
begin
  select id, nome, uf, status into v_cidade
  from public.cidades_infra where id = p_cidade_id and removido_em is null;

  if not found then
    raise exception 'Cidade % não encontrada.', p_cidade_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'segmento_id', s.id, 'nome', s.nome, 'origem', s.origem, 'destino', s.destino, 'extensao_km', s.extensao_km
  ) order by s.nome), '[]'::jsonb)
  into v_segmentos
  from public.infra_segmentos s
  where s.cidade_id = p_cidade_id and s.removido_em is null;

  select coalesce(jsonb_agg(jsonb_build_object(
    'poste_id', pt.id, 'identificacao', pt.identificacao, 'segmento_id', pt.segmento_id,
    'proprietario_terceiro', pt.proprietario_terceiro, 'quantidade', pt.quantidade, 'custo_mensal', pt.custo_mensal
  ) order by pt.criado_em), '[]'::jsonb)
  into v_postes
  from public.infra_postes pt
  where pt.cidade_id = p_cidade_id and pt.removido_em is null;

  select coalesce(jsonb_agg(jsonb_build_object(
    'pop_id', pop.id, 'codigo', pop.codigo, 'nome', pop.nome, 'tipo', pop.tipo,
    'endereco', pop.endereco, 'latitude', pop.latitude, 'longitude', pop.longitude,
    'capacidade_total', pop.capacidade_total, 'status', pop.status, 'observacoes', pop.observacoes,
    'cabos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'cabo_id', cb.id, 'identificacao', cb.identificacao, 'capacidade_fo', cb.capacidade_fo,
        'fabricante', cb.fabricante, 'segmento_id', cb.segmento_id,
        'fibras', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'fibra_id', f.id, 'numero_fibra', f.numero_fibra, 'par_numero', f.par_numero,
            'status', f.status, 'observacao', f.observacao
          ) order by f.numero_fibra), '[]'::jsonb)
          from public.infra_fibras f where f.cabo_id = cb.id
        )
      ) order by cb.identificacao), '[]'::jsonb)
      from public.infra_cabos cb where cb.pop_id = pop.id and cb.removido_em is null
    ),
    'portas_pon', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'porta_id', pp.id, 'codigo_porta', pp.codigo_porta, 'nome', pp.nome, 'tecnologia', pp.tecnologia,
        'status', pp.status, 'capacidade_max_assinantes', pp.capacidade_max_assinantes,
        'capacidade_utilizada_assinantes', pp.capacidade_utilizada_assinantes,
        'fibra_id', pp.fibra_id, 'numero_fibra', f2.numero_fibra, 'cabo_identificacao', cb2.identificacao
      ) order by pp.codigo_porta), '[]'::jsonb)
      from public.infra_portas_pon pp
      join public.infra_fibras f2 on f2.id = pp.fibra_id
      join public.infra_cabos cb2 on cb2.id = f2.cabo_id
      where pp.pop_id = pop.id
    )
  ) order by pop.codigo), '[]'::jsonb)
  into v_pops
  from public.infra_pops pop
  where pop.cidade_id = p_cidade_id and pop.removido_em is null;

  return jsonb_build_object(
    'cidade_id', v_cidade.id, 'nome', v_cidade.nome, 'uf', v_cidade.uf, 'status', v_cidade.status,
    'segmentos', v_segmentos, 'postes', v_postes, 'pops', v_pops
  );
end;
$$;
comment on function public.pricing_city_infra_tree(uuid) is 'Fase 2.3 (seção 21): GET /api/infra/tree?cidade_id=... — árvore completa (segmentos, postes, POPs->cabos->fibras, POPs->portas PON) para a tela "Editar Infraestrutura", em 1 chamada.';

grant execute on function public.pricing_city_infra_tree(uuid) to authenticated;
