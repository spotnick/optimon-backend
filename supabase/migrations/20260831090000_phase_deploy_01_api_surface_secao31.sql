-- OptiMon — Fase 2.2.1 (Parte 2: "AJUSTE FINAL DO PRICING ENGINE + RÉGUA DE PREÇO +
-- PRIMEIRA VERSÃO VISUAL FUNCIONAL + DEPLOYMENT DOS AMBIENTES").
--
-- Seção 31/32: completa a superfície pública de API que faltava para o frontend React —
-- cidades, cálculo de PONs a partir de clientes, salvar simulação, criar/listar proposta,
-- listar auditoria, registrar login. Segue exatamente o padrão já estabelecido em
-- 20260827100900_phase_2_10_api_public_wrappers.sql: wrappers finos em `public`,
-- SECURITY INVOKER por padrão (RLS de quem chama vale sempre), plpgsql/sql conforme o caso,
-- GRANT EXECUTE só para `authenticated`. Nenhuma tabela nova, nenhuma migration anterior
-- alterada — só evolução incremental (seção "NÃO recriar/NÃO duplicar" do prompt).

-- ============================================================================
-- 1) CIDADES — GET /api/cities, GET /api/cities/:id (seção 31)
-- ============================================================================

create or replace function public.pricing_cities_list()
returns table (
  cidade_id uuid,
  nome text,
  uf character(2),
  km_rede numeric,
  postes_count bigint,
  pops_count bigint,
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
    c.km_rede,
    coalesce((select sum(p.quantidade) from public.infra_postes p where p.cidade_id = c.id and p.removido_em is null), 0),
    coalesce((select count(*) from public.infra_pops pop where pop.cidade_id = c.id and pop.removido_em is null), 0),
    coalesce(v.capacidade_maxima_clientes, 0),
    coalesce(v.clientes_ativos, 0),
    v.taxa_ocupacao
  from public.cidades_infra c
  left join public.vw_capacidade_cidade v on v.cidade_id = c.id
  where c.removido_em is null
  order by c.nome;
$$;
comment on function public.pricing_cities_list() is 'GET /api/cities — lista de cidades com infraestrutura e capacidade consolidadas (seção 31).';

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
  select id, nome, uf, codigo_ibge, endereco, km_rede, observacoes
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
    'km_rede', pop.km_rede,
    'postes_count', pop.postes_count,
    'status', pop.status
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
    'postes_count', coalesce((select sum(p.quantidade) from public.infra_postes p where p.cidade_id = v_cidade.id and p.removido_em is null), 0),
    'fibras_totais', v_capacidade.fibras_totais,
    'fibras_livres', v_capacidade.fibras_livres,
    'fibras_contratadas', v_capacidade.fibras_contratadas,
    'portas_pon_totais', v_capacidade.portas_pon_totais,
    'portas_disponiveis', v_capacidade.portas_disponiveis,
    'capacidade_maxima_clientes', v_capacidade.capacidade_maxima_clientes,
    'clientes_ativos', v_capacidade.clientes_ativos,
    'capacidade_disponivel_clientes', v_capacidade.capacidade_disponivel_clientes,
    'taxa_ocupacao', v_capacidade.taxa_ocupacao,
    'pops', v_pops
  );
end;
$$;
comment on function public.pricing_city_detail(uuid) is 'GET /api/cities/:id — detalhe de uma cidade (infra + capacidade + POPs) (seção 31/20).';

-- ============================================================================
-- 2) PONs NECESSÁRIAS A PARTIR DE CLIENTES — ceil(clientes / capacidade_da_porta)
--    (seções 25, 41: 129 clientes -> 2 PONs, 257 clientes -> 3 PONs)
-- ============================================================================

create or replace function app.pons_necessarias_para_clientes(p_clientes integer, p_cidade_id uuid default null, p_pricing_version text default null)
returns integer
language plpgsql
stable
as $$
declare
  v_capacidade numeric;
begin
  if p_clientes is null or p_clientes <= 0 then
    return 0;
  end if;

  v_capacidade := app.get_infra_floor_param('PORTA_PON_CAPACIDADE_MAX_PADRAO', p_cidade_id, p_pricing_version, 128);
  if v_capacidade is null or v_capacidade <= 0 then
    v_capacidade := 128;
  end if;

  return ceil(p_clientes::numeric / v_capacidade)::integer;
end;
$$;
comment on function app.pons_necessarias_para_clientes(integer, uuid, text) is 'ceil(clientes/capacidade_por_porta) — seção 25/41: 129->2 PONs, 257->3 PONs, 128->1 PON.';

create or replace function public.pricing_pons_for_clients(p_clientes integer, p_cidade_id uuid default null, p_pricing_version text default null)
returns jsonb
language sql
stable
security invoker
as $$
  select jsonb_build_object(
    'clientes', p_clientes,
    'pons_necessarias', app.pons_necessarias_para_clientes(p_clientes, p_cidade_id, p_pricing_version),
    'capacidade_por_porta', app.get_infra_floor_param('PORTA_PON_CAPACIDADE_MAX_PADRAO', p_cidade_id, p_pricing_version, 128)
  );
$$;
comment on function public.pricing_pons_for_clients(integer, uuid, text) is 'Apoia o gráfico "CLIENTES × PONs NECESSÁRIAS" (seção 25) e o simulador de clientes (seção 23).';

grant execute on function
  public.pricing_cities_list(),
  public.pricing_city_detail(uuid),
  public.pricing_pons_for_clients(integer, uuid, text)
to authenticated;
