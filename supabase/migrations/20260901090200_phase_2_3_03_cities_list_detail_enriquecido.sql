-- OptiMon — Fase 2.3: Módulo de Gestão de Cidades e Infraestrutura
-- Migration 3/3: enriquece pricing_cities_list/pricing_city_detail com os campos que a
-- tela "Cidades & Infraestrutura" (seção 6) e a visão consolidada (seção 20) pedem e que
-- as versões da Fase Deploy ainda não devolviam: status, FOs totais/ociosas, portas PON,
-- fibras bloqueadas.

-- create or replace não pode mudar o tipo de retorno de uma função "returns table(...)"
-- (os novos campos alteram o tipo composto implícito) — precisa dropar antes.
drop function if exists public.pricing_cities_list();

create function public.pricing_cities_list()
returns table (
  cidade_id uuid,
  nome text,
  uf character(2),
  status text,
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
  where c.removido_em is null
  order by c.nome;
$$;
comment on function public.pricing_cities_list() is 'GET /api/cities — lista de cidades com infraestrutura e capacidade consolidadas (seção 6/31 Fase 2.3: agora inclui status, FOs totais/ociosas e portas PON, além do que a Fase Deploy já devolvia).';

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
  select id, nome, uf, codigo_ibge, endereco, km_rede, observacoes, status
  into v_cidade
  from public.cidades_infra where id = p_cidade_id and removido_em is null;

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
comment on function public.pricing_city_detail(uuid) is 'GET /api/cities/:id — detalhe de uma cidade (infra + capacidade + POPs) (seção 20 Fase 2.3: agora inclui status e fibras_bloqueadas, e cada POP no array vem completo — endereço/lat/long/capacidade/observações — para alimentar a tela de edição de infraestrutura sem uma segunda chamada).';
