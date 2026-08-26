-- OptiMon — Fase 2.3.1: CRUD completo de infraestrutura.
-- Migration 3/4: itens arquivados nunca entram em capacidade/Pricing Engine/Dashboard
-- (seções 26-27) — bug real encontrado nesta fase, não só um requisito novo: as views de
-- capacidade (vw_porta_pon_detalhe, vw_capacidade_cidade) existem desde a Fase 1/1.1,
-- de quando nem POP nem cabo tinham uma noção de "arquivado" — nunca filtravam
-- removido_em, porque a coluna não existia ainda quando foram escritas. Corrigido aqui,
-- de forma aditiva (CREATE OR REPLACE VIEW com a mesma lista de colunas — nenhum
-- consumidor downstream quebra).

-- ============================================================================
-- 1) vw_porta_pon_detalhe — base de todas as views de capacidade (cidade/POP/contrato/
--    parceiro). Passa a excluir Porta PON arquivada (status = INATIVA) e Porta PON cujo
--    cabo/POP tenha sido arquivado — mesma lista de colunas de sempre, CREATE OR REPLACE
--    seguro.
-- ============================================================================

create or replace view public.vw_porta_pon_detalhe as
select
  pp.id as porta_pon_id,
  pp.codigo_porta,
  pp.tecnologia,
  pp.status as porta_status,
  pp.capacidade_max_assinantes,
  pp.capacidade_reservada_assinantes,
  pp.capacidade_utilizada_assinantes,
  pp.capacidade_disponivel,
  pp.taxa_ocupacao,
  f.id as fibra_id,
  f.status_comercial,
  f.status_contratual,
  cb.id as cabo_id,
  cb.pop_id,
  pop.cidade_id,
  cf.contrato_id,
  cf.contrato_id is not null as contratada
from infra_portas_pon pp
  join infra_fibras f on f.id = pp.fibra_id
  join infra_cabos cb on cb.id = f.cabo_id
  join infra_pops pop on pop.id = cb.pop_id
  left join lateral (
    select cf2.contrato_id
    from contrato_fibras cf2
    where cf2.porta_pon_id = pp.id and cf2.desvinculado_em is null
    order by cf2.vinculado_em desc
    limit 1
  ) cf on true
where pp.status <> 'INATIVA'
  and cb.removido_em is null
  and pop.removido_em is null;

comment on view public.vw_porta_pon_detalhe is 'Base para as views de capacidade: cada porta PON com sua fibra/cabo/POP/cidade e se está contratada agora. Fase 2.3.1 (seção 27): exclui Porta PON arquivada (status INATIVA) e Porta PON cujo cabo/POP tenha sido arquivado — bug real de views herdadas da Fase 1/1.1, de antes de "arquivado" existir no modelo.';

-- ============================================================================
-- 2) vw_capacidade_cidade — a CTE de fibras contava toda fibra de todo cabo, mesmo com
--    o cabo ou o POP arquivados. A CTE de portas já herda a correção do item 1
--    automaticamente (consome vw_porta_pon_detalhe). Mesma lista de colunas de sempre.
-- ============================================================================

create or replace view public.vw_capacidade_cidade as
with fibras as (
  select
    pop.cidade_id,
    count(f.id) as fibras_totais,
    count(f.id) filter (where f.status_comercial = 'BLOQUEADA') as fibras_bloqueadas,
    count(f.id) filter (where f.status_contratual = 'VINCULADA') as fibras_contratadas,
    count(f.id) filter (where f.status_comercial = 'LIVRE' and f.status_contratual = 'DISPONIVEL') as fibras_livres
  from infra_fibras f
    join infra_cabos cb on cb.id = f.cabo_id
    join infra_pops pop on pop.id = cb.pop_id
  where cb.removido_em is null and pop.removido_em is null
  group by pop.cidade_id
), portas as (
  select
    vw_porta_pon_detalhe.cidade_id,
    count(*) as portas_pon_totais,
    count(*) filter (where vw_porta_pon_detalhe.contratada) as portas_contratadas,
    count(*) filter (where not vw_porta_pon_detalhe.contratada) as portas_disponiveis,
    coalesce(sum(vw_porta_pon_detalhe.capacidade_max_assinantes), 0) as capacidade_maxima_clientes,
    coalesce(sum(vw_porta_pon_detalhe.capacidade_utilizada_assinantes), 0) as clientes_ativos,
    coalesce(sum(vw_porta_pon_detalhe.capacidade_disponivel), 0) as capacidade_disponivel_clientes
  from vw_porta_pon_detalhe
  group by vw_porta_pon_detalhe.cidade_id
)
select
  ci.id as cidade_id,
  ci.nome as cidade,
  coalesce(fibras.fibras_totais, 0) as fibras_totais,
  coalesce(fibras.fibras_bloqueadas, 0) as fibras_bloqueadas,
  coalesce(fibras.fibras_contratadas, 0) as fibras_contratadas,
  coalesce(fibras.fibras_livres, 0) as fibras_livres,
  coalesce(portas.portas_pon_totais, 0) as portas_pon_totais,
  coalesce(portas.portas_contratadas, 0) as portas_contratadas,
  coalesce(portas.portas_disponiveis, 0) as portas_disponiveis,
  coalesce(portas.capacidade_maxima_clientes, 0) as capacidade_maxima_clientes,
  coalesce(portas.clientes_ativos, 0) as clientes_ativos,
  coalesce(portas.capacidade_disponivel_clientes, 0) as capacidade_disponivel_clientes,
  case
    when coalesce(portas.capacidade_maxima_clientes, 0) > 0 then round(portas.clientes_ativos::numeric / portas.capacidade_maxima_clientes::numeric, 4)
    else 0::numeric
  end as taxa_ocupacao
from cidades_infra ci
  left join fibras on fibras.cidade_id = ci.id
  left join portas on portas.cidade_id = ci.id;

comment on view public.vw_capacidade_cidade is 'Fase 2.3.1 (seção 27): a CTE de fibras agora exclui cabo/POP arquivados (bug real herdado da Fase 1/1.1); a CTE de portas herda a correção de vw_porta_pon_detalhe automaticamente.';

-- GRANTs de authenticated para as 2 views recriadas: CREATE OR REPLACE VIEW preserva
-- GRANTs existentes normalmente, mas reforçando explicitamente aqui por segurança (mesmo
-- bug de "view sem GRANT" já visto na Fase 2.2.1 Parte 2 — nunca mais silencioso).
grant select on public.vw_porta_pon_detalhe, public.vw_capacidade_cidade to authenticated;

-- ============================================================================
-- 3) pricing_cities_list / pricing_city_infra_tree — ganham p_incluir_arquivados
--    (default false) para alimentar o filtro ATIVOS/ARQUIVADOS/TODOS (seção 20). Ambas
--    mudam de assinatura (parâmetro novo) — DROP explícito antes, mesmo motivo de sempre
--    (evitar a ambiguidade de sobrecarga já documentada nas Fases 2.2/2.2.1/2.3.1).
-- ============================================================================

drop function if exists public.pricing_cities_list();
drop function if exists public.pricing_cities_list(boolean);

create function public.pricing_cities_list(p_incluir_arquivados boolean default false)
returns table (
  cidade_id uuid,
  nome text,
  uf character(2),
  status text,
  arquivada boolean,
  km_rede numeric,
  postes_count bigint,
  pops_count bigint,
  fibras_totais bigint,
  fibras_ociosas bigint,
  portas_pon_totais bigint,
  capacidade_maxima_clientes bigint,
  clientes_ativos bigint,
  taxa_ocupacao numeric
)
language sql
stable
security invoker
as $$
  select
    c.id,
    c.nome,
    c.uf,
    c.status,
    c.removido_em is not null,
    c.km_rede,
    coalesce((select sum(p.quantidade) from public.infra_postes p where p.cidade_id = c.id and p.removido_em is null), 0),
    coalesce((select count(*) from public.infra_pops pop where pop.cidade_id = c.id and pop.removido_em is null), 0),
    coalesce(v.fibras_totais, 0),
    coalesce(v.fibras_livres, 0),
    coalesce(v.portas_pon_totais, 0),
    coalesce(v.capacidade_maxima_clientes, 0),
    coalesce(v.clientes_ativos, 0),
    v.taxa_ocupacao
  from public.cidades_infra c
  left join public.vw_capacidade_cidade v on v.cidade_id = c.id
  where p_incluir_arquivados or c.removido_em is null
  order by c.nome;
$$;
comment on function public.pricing_cities_list(boolean) is 'GET /api/cities — lista de cidades. Fase 2.3.1 (seção 20): p_incluir_arquivados=true mostra também cidades arquivadas (campo "arquivada" no retorno, filtro ATIVOS/ARQUIVADOS/TODOS da tela "Infraestrutura Arquivada").';

grant execute on function public.pricing_cities_list(boolean) to authenticated;

drop function if exists public.pricing_city_infra_tree(uuid);

create or replace function public.pricing_city_infra_tree(p_cidade_id uuid, p_incluir_arquivados boolean default false)
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
  from public.cidades_infra where id = p_cidade_id and (p_incluir_arquivados or removido_em is null);

  if not found then
    raise exception 'Cidade % não encontrada.', p_cidade_id;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'segmento_id', s.id, 'nome', s.nome, 'origem', s.origem, 'destino', s.destino, 'extensao_km', s.extensao_km,
    'arquivado', s.removido_em is not null
  ) order by s.nome), '[]'::jsonb)
  into v_segmentos
  from public.infra_segmentos s
  where s.cidade_id = p_cidade_id and (p_incluir_arquivados or s.removido_em is null);

  select coalesce(jsonb_agg(jsonb_build_object(
    'poste_id', pt.id, 'identificacao', pt.identificacao, 'segmento_id', pt.segmento_id,
    'proprietario_terceiro', pt.proprietario_terceiro, 'quantidade', pt.quantidade, 'custo_mensal', pt.custo_mensal,
    'arquivado', pt.removido_em is not null
  ) order by pt.criado_em), '[]'::jsonb)
  into v_postes
  from public.infra_postes pt
  where pt.cidade_id = p_cidade_id and (p_incluir_arquivados or pt.removido_em is null);

  select coalesce(jsonb_agg(jsonb_build_object(
    'pop_id', pop.id, 'codigo', pop.codigo, 'nome', pop.nome, 'tipo', pop.tipo,
    'endereco', pop.endereco, 'latitude', pop.latitude, 'longitude', pop.longitude,
    'capacidade_total', pop.capacidade_total, 'status', pop.status, 'observacoes', pop.observacoes,
    'arquivado', pop.removido_em is not null,
    'cabos', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'cabo_id', cb.id, 'identificacao', cb.identificacao, 'capacidade_fo', cb.capacidade_fo,
        'fabricante', cb.fabricante, 'segmento_id', cb.segmento_id, 'arquivado', cb.removido_em is not null,
        'fibras', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'fibra_id', f.id, 'numero_fibra', f.numero_fibra, 'par_numero', f.par_numero,
            'status', f.status, 'observacao', f.observacao
          ) order by f.numero_fibra), '[]'::jsonb)
          from public.infra_fibras f where f.cabo_id = cb.id
        )
      ) order by cb.identificacao), '[]'::jsonb)
      from public.infra_cabos cb where cb.pop_id = pop.id and (p_incluir_arquivados or cb.removido_em is null)
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
      where pp.pop_id = pop.id and (p_incluir_arquivados or pp.status <> 'INATIVA')
    )
  ) order by pop.codigo), '[]'::jsonb)
  into v_pops
  from public.infra_pops pop
  where pop.cidade_id = p_cidade_id and (p_incluir_arquivados or pop.removido_em is null);

  return jsonb_build_object(
    'cidade_id', v_cidade.id, 'nome', v_cidade.nome, 'uf', v_cidade.uf, 'status', v_cidade.status,
    'segmentos', v_segmentos, 'postes', v_postes, 'pops', v_pops
  );
end;
$$;
comment on function public.pricing_city_infra_tree(uuid, boolean) is 'GET /api/infra/tree?cidade_id=...&filtro=... — árvore completa da cidade. Fase 2.3.1 (seção 20): p_incluir_arquivados=true inclui POP/cabo/segmento/poste arquivados e Porta PON INATIVA, cada item marcado com "arquivado"/status para o frontend distinguir; false (padrão) mantém o comportamento da Fase 2.3 (só ativos).';

grant execute on function public.pricing_city_infra_tree(uuid, boolean) to authenticated;
