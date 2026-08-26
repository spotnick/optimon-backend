-- OptiMon — Fase 2.3.1: CRUD completo de infraestrutura.
-- Migration 4/4: 2 lacunas reais de schema encontradas ao implementar EDITAR (seções
-- 11/12/15) + GET /api/cities/:id passa a funcionar também para cidade arquivada
-- (seção 2 — "Visualizar" precisa funcionar mesmo para item arquivado).
--
-- LACUNA 1 (seções 11/12/15): o prompt desta fase pede "Status" e "Observações" como
-- campos editáveis de Segmento, Cabo e Poste — nenhuma das 3 tabelas tem essas colunas
-- hoje (só cidade e POP têm status desde a Fase 1/2.3; cabo/segmento/poste nunca
-- tiveram). Adicionadas de forma aditiva, mesmo padrão da coluna status de cidades_infra
-- na Fase 2.3: nunca um "estado" que sobrepõe removido_em (arquivamento continua sendo
-- só removido_em) — status aqui é operacional (ATIVO/MANUTENCAO), independente.

alter table public.infra_segmentos
  add column if not exists status text not null default 'ATIVO' check (status in ('ATIVO', 'MANUTENCAO')),
  add column if not exists observacoes text;
comment on column public.infra_segmentos.status is 'Fase 2.3.1 (seção 11): estado operacional, independente de removido_em (arquivamento).';

alter table public.infra_cabos
  add column if not exists status text not null default 'ATIVO' check (status in ('ATIVO', 'MANUTENCAO')),
  add column if not exists observacoes text;
comment on column public.infra_cabos.status is 'Fase 2.3.1 (seção 12): estado operacional, independente de removido_em (arquivamento).';

alter table public.infra_postes
  add column if not exists status text not null default 'ATIVO' check (status in ('ATIVO', 'MANUTENCAO')),
  add column if not exists observacoes text;
comment on column public.infra_postes.status is 'Fase 2.3.1 (seção 15): estado operacional, independente de removido_em (arquivamento).';

-- ============================================================================
-- LACUNA 2 (seção 2): GET /api/cities/:id ("Visualizar") deixava de funcionar assim que
-- a cidade era arquivada — pricing_city_detail() sempre filtrava removido_em is null e
-- lançava "Cidade não encontrada" (correto para o caso geral, errado para "ver o que já
-- arquivei"). CREATE OR REPLACE simples — mesma assinatura e mesmas colunas de retorno.
-- ============================================================================

create or replace function public.pricing_city_detail(p_cidade_id uuid)
returns jsonb
language plpgsql
stable
security invoker
as $$
declare
  v_cidade record;
  v_capacidade record;
  v_pops jsonb;
begin
  select id, nome, uf, codigo_ibge, endereco, km_rede, observacoes, status, removido_em
  into v_cidade
  from public.cidades_infra where id = p_cidade_id;

  if not found then
    raise exception 'Cidade % não encontrada.', p_cidade_id;
  end if;

  select * into v_capacidade from public.vw_capacidade_cidade where cidade_id = p_cidade_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'pop_id', pop.id,
    'codigo', pop.codigo,
    'nome', pop.nome,
    'tipo', pop.tipo,
    'endereco', pop.endereco,
    'latitude', pop.latitude,
    'longitude', pop.longitude,
    'capacidade_total', pop.capacidade_total,
    'status', pop.status,
    'observacoes', pop.observacoes
  ) order by pop.codigo), '[]'::jsonb)
  into v_pops
  from public.infra_pops pop
  where pop.cidade_id = p_cidade_id and pop.removido_em is null;

  return jsonb_build_object(
    'cidade_id', v_cidade.id,
    'nome', v_cidade.nome,
    'uf', v_cidade.uf,
    'codigo_ibge', v_cidade.codigo_ibge,
    'endereco', v_cidade.endereco,
    'km_rede', v_cidade.km_rede,
    'observacoes', v_cidade.observacoes,
    'status', v_cidade.status,
    'arquivada', v_cidade.removido_em is not null,
    'postes_count', coalesce((select sum(p.quantidade) from public.infra_postes p where p.cidade_id = v_cidade.id and p.removido_em is null), 0),
    'fibras_totais', coalesce(v_capacidade.fibras_totais, 0),
    'fibras_livres', coalesce(v_capacidade.fibras_livres, 0),
    'fibras_contratadas', coalesce(v_capacidade.fibras_contratadas, 0),
    'fibras_bloqueadas', coalesce(v_capacidade.fibras_bloqueadas, 0),
    'portas_pon_totais', coalesce(v_capacidade.portas_pon_totais, 0),
    'portas_contratadas', coalesce(v_capacidade.portas_contratadas, 0),
    'portas_disponiveis', coalesce(v_capacidade.portas_disponiveis, 0),
    'capacidade_maxima_clientes', coalesce(v_capacidade.capacidade_maxima_clientes, 0),
    'clientes_ativos', coalesce(v_capacidade.clientes_ativos, 0),
    'capacidade_disponivel_clientes', coalesce(v_capacidade.capacidade_disponivel_clientes, 0),
    'taxa_ocupacao', coalesce(v_capacidade.taxa_ocupacao, 0),
    'pops', v_pops
  );
end;
$$;
comment on function public.pricing_city_detail(uuid) is 'GET /api/cities/:id. Fase 2.3.1 (seção 2): não filtra mais removido_em — "Visualizar" precisa funcionar também para cidade arquivada (devolve "arquivada": true). A lista de POPs continua só ativos (visão operacional); a árvore completa com arquivados vem de pricing_city_infra_tree(id, true).';

-- ============================================================================
-- pricing_city_infra_tree ganha status/observacoes de segmento/cabo/poste no retorno
-- (mesma assinatura — só o conteúdo do jsonb muda).
-- ============================================================================

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
    'status', s.status, 'observacoes', s.observacoes, 'arquivado', s.removido_em is not null
  ) order by s.nome), '[]'::jsonb)
  into v_segmentos
  from public.infra_segmentos s
  where s.cidade_id = p_cidade_id and (p_incluir_arquivados or s.removido_em is null);

  select coalesce(jsonb_agg(jsonb_build_object(
    'poste_id', pt.id, 'identificacao', pt.identificacao, 'segmento_id', pt.segmento_id,
    'proprietario_terceiro', pt.proprietario_terceiro, 'quantidade', pt.quantidade, 'custo_mensal', pt.custo_mensal,
    'status', pt.status, 'observacoes', pt.observacoes, 'arquivado', pt.removido_em is not null
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
        'fabricante', cb.fabricante, 'segmento_id', cb.segmento_id, 'pop_id', cb.pop_id,
        'status', cb.status, 'observacoes', cb.observacoes, 'arquivado', cb.removido_em is not null,
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
comment on function public.pricing_city_infra_tree(uuid, boolean) is 'GET /api/infra/tree. Fase 2.3.1: acrescenta status/observacoes de segmento/cabo/poste e pop_id do cabo (para o formulário de edição saber o POP atual sem uma segunda chamada).';
