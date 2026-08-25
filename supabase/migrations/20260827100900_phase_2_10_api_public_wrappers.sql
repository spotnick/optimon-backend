-- OptiMon — Fase 2
-- Seção 50: superfície pública da API. O PostgREST do Supabase só expõe funções do
-- schema `public` por padrão (o schema `app` — onde vive toda a lógica desta e das fases
-- anteriores — não é alcançável via REST/RPC direto). Este arquivo cria wrappers finos em
-- `public`, SECURITY INVOKER (roda com o perfil/RLS de quem chama — nunca eleva
-- privilégio), para cada endpoint da seção 50. api/routes/*.js (fora do banco) chama
-- estes wrappers via supabase-js.

create or replace function public.pricing_simulate(p_params jsonb)
returns jsonb
language sql
stable
security invoker
as $$
  select app.simular_projecao(p_params);
$$;
comment on function public.pricing_simulate(jsonb) is 'POST /api/pricing/simulate — ScenarioSimulator (seção 51).';

create or replace function public.pricing_projection(p_params jsonb)
returns jsonb
language sql
stable
security invoker
as $$
  select app.simular_projecao(p_params);
$$;
comment on function public.pricing_projection(jsonb) is 'GET /api/pricing/projection — mesma projeção de pricing_simulate, nome dedicado por clareza de API (seção 30/50).';

create or replace function public.pricing_roi(p_projecao jsonb, p_investimento numeric, p_meses integer[] default array[12,36,48,60])
returns jsonb
language sql
stable
security invoker
as $$
  select coalesce(jsonb_agg(app.calcular_roi(p_projecao, p_investimento, m)), '[]'::jsonb) from unnest(p_meses) as m;
$$;
comment on function public.pricing_roi(jsonb, numeric, integer[]) is 'GET /api/pricing/roi — ROI nos horizontes pedidos (seção 31: 12/36/48/60 meses por padrão).';

create or replace function public.pricing_payback(p_projecao jsonb, p_investimento numeric)
returns jsonb
language sql
stable
security invoker
as $$
  select app.calcular_payback(p_projecao, p_investimento);
$$;
comment on function public.pricing_payback(jsonb, numeric) is 'Payback dentro de GET /api/pricing/roi (seção 32) — exposto separado para o dashboard poder pedir só isso.';

create or replace function public.pricing_quote(p_contrato_id uuid, p_preco_proposto numeric default null)
returns jsonb
language plpgsql
stable
security invoker
as $$
declare
  v_modelo public.contrato_modelo;
  v_resultado jsonb;
  v_minimo numeric;
  v_recomendado numeric;
  v_premium numeric;
  v_governanca text;
begin
  select modelo into v_modelo from public.contratos where id = p_contrato_id;
  if v_modelo is null then
    raise exception 'Contrato % não encontrado.', p_contrato_id;
  end if;

  if v_modelo = 'DARK_FIBER' then
    v_minimo := app.calcular_preco_minimo_dark_fiber(p_contrato_id);
    v_recomendado := app.calcular_preco_recomendado_dark_fiber(p_contrato_id);
    v_premium := app.calcular_preco_premium_dark_fiber(p_contrato_id);
  else
    select preco_minimo_porta, preco_recomendado_porta, preco_premium_porta
    into v_minimo, v_recomendado, v_premium
    from public.contrato_pricing_config where contrato_id = p_contrato_id;
  end if;

  v_governanca := app.check_pricing_governance(p_preco_proposto, v_minimo, v_recomendado);

  v_resultado := jsonb_build_object(
    'contrato_id', p_contrato_id,
    'modelo', v_modelo,
    'preco_minimo', v_minimo,
    'preco_recomendado', v_recomendado,
    'preco_premium', v_premium,
    'preco_proposto', p_preco_proposto,
    'governanca', v_governanca,
    'breakeven_faturamento', app.calcular_breakeven_faturamento(p_contrato_id)
  );
  return v_resultado;
end;
$$;
comment on function public.pricing_quote(uuid, numeric) is 'POST /api/pricing/quote — preço mínimo/recomendado/premium + governança (seções 36, 49) para um contrato.';

create or replace function public.pricing_override_create(p_contrato_id uuid, p_simulacao_id uuid, p_preco_recomendado numeric, p_preco_solicitado numeric, p_justificativa text)
returns uuid
language sql
security invoker
as $$
  insert into public.pricing_override_requests (contrato_id, simulacao_id, preco_recomendado, preco_solicitado, justificativa)
  values (p_contrato_id, p_simulacao_id, p_preco_recomendado, p_preco_solicitado, p_justificativa)
  returning id;
$$;
comment on function public.pricing_override_create(uuid, uuid, numeric, numeric, text) is 'POST /api/pricing/override — abre solicitação (nasce PENDENTE — trigger fn_override_nasce_pendente, seção 48).';

create or replace function public.pricing_override_approve(p_override_id uuid, p_aprovar boolean, p_observacao text default null)
returns public.pricing_override_requests
language plpgsql
security invoker
as $$
declare
  v_row public.pricing_override_requests;
begin
  update public.pricing_override_requests
  set status = case when p_aprovar then 'APROVADA' else 'REJEITADA' end
  where id = p_override_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Override % não encontrado ou já decidido.', p_override_id;
  end if;
  return v_row;
end;
$$;
comment on function public.pricing_override_approve(uuid, boolean, text) is 'POST /api/pricing/approve — decisão exige DIRETOR/ADMINISTRADOR (RLS + trigger fn_override_decisao, seção 49). SECURITY INVOKER: roda com o perfil de quem chama, nunca eleva privilégio.';

create or replace function public.pricing_scenarios_list(p_contrato_id uuid default null)
returns setof public.simulacoes
language sql
stable
security invoker
as $$
  select * from public.simulacoes
  where p_contrato_id is null or (resultado->'parametros'->>'contrato_id')::uuid = p_contrato_id
  order by criado_em desc;
$$;
comment on function public.pricing_scenarios_list(uuid) is 'GET /api/pricing/scenarios — simulações salvas (seção 50).';

create or replace function public.pricing_versions_list(p_contrato_id uuid)
returns setof public.pricing_versions
language sql
stable
security invoker
as $$
  select * from public.pricing_versions where contrato_id = p_contrato_id order by versao desc;
$$;
comment on function public.pricing_versions_list(uuid) is 'GET /api/pricing/versions — histórico imutável de versões de pricing do contrato (seção 46/50).';

-- RLS das tabelas-base (contratos, simulacoes, pricing_versions, pricing_override_requests
-- etc.) já se aplica normalmente porque toda função acima é SECURITY INVOKER — nenhuma
-- eleva privilégio. Grants de execução para authenticated (mesmo padrão já usado desde a
-- Fase 1.1/1.2).
grant execute on function
  public.pricing_simulate(jsonb),
  public.pricing_projection(jsonb),
  public.pricing_roi(jsonb, numeric, integer[]),
  public.pricing_payback(jsonb, numeric),
  public.pricing_quote(uuid, numeric),
  public.pricing_override_create(uuid, uuid, numeric, numeric, text),
  public.pricing_override_approve(uuid, boolean, text),
  public.pricing_scenarios_list(uuid),
  public.pricing_versions_list(uuid)
to authenticated;
