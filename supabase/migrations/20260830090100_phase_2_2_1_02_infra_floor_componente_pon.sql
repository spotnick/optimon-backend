-- OptiMon — Fase 2.2.1: Ajuste Final de Governança + Precificação por Porta PON
-- Migration 2/4: Infrastructure Floor passa a incluir o componente PON (seção 3/16), com
-- as funções de conveniência calculate_infrastructure_floor_by_pop()/
-- calculate_city_infrastructure_floor()/calculate_infrastructure_floor_for_contract()
-- (seção 24).
--
-- IMPORTANTE (lição aprendida na Fase 2.2, seção 40 daquela fase, repetida aqui de
-- propósito): CREATE OR REPLACE só substitui uma função de MESMA assinatura. Acrescentar um
-- parâmetro novo (mesmo com DEFAULT) cria uma SEGUNDA função sobrecarregada e deixa toda
-- chamada com a aridade antiga ambígua. Por isso, toda função cuja assinatura muda nesta
-- migration é precedida por um DROP FUNCTION IF EXISTS da assinatura antiga.

-- 1) app.calculate_infrastructure_floor — novo parâmetro opcional p_pons_count no final.
drop function if exists app.calculate_infrastructure_floor(uuid, uuid, text);

create or replace function app.calculate_infrastructure_floor(
  p_cidade_id uuid,
  p_pop_id uuid default null,
  p_pricing_version text default null,
  p_pons_count integer default null
)
returns jsonb
language plpgsql
stable
as $$
declare
  v_cidade record;
  v_pop record;
  v_poles_count integer;
  v_network_meters numeric;
  v_pons_count integer;
  v_price_pole numeric;
  v_price_meter_floor numeric;
  v_price_meter_recommended numeric;
  v_price_meter_opening numeric;
  v_price_pon_floor numeric;
  v_price_pon_recommended numeric;
  v_price_pon_opening numeric;
  v_pole_component numeric;
  v_floor_meter_component numeric;
  v_recommended_meter_component numeric;
  v_opening_meter_component numeric;
  v_floor_pon_component numeric;
  v_recommended_pon_component numeric;
  v_opening_pon_component numeric;
  v_pricing_version_label text;
begin
  select id, nome, km_rede into v_cidade from public.cidades_infra where id = p_cidade_id and removido_em is null;
  if not found then
    raise exception 'Cidade % não encontrada.', p_cidade_id;
  end if;

  if p_pop_id is not null then
    select id, codigo, km_rede, postes_count into v_pop from public.infra_pops where id = p_pop_id and cidade_id = p_cidade_id and removido_em is null;
    if not found then
      raise exception 'POP % não encontrado (ou não pertence à cidade %).', p_pop_id, p_cidade_id;
    end if;
    v_poles_count := v_pop.postes_count;
    v_network_meters := v_pop.km_rede * 1000;
  else
    select coalesce(sum(quantidade), 0) into v_poles_count from public.infra_postes where cidade_id = p_cidade_id and removido_em is null;
    v_network_meters := v_cidade.km_rede * 1000;
  end if;

  -- PONs (seção 16/19): NUNCA inferido daqui — é sempre o que o chamador informar (a
  -- quantidade de Portas PON CONTRATADAS/reservadas, não o número de clientes). Sem
  -- informação (NULL, ex.: uma consulta puramente de infraestrutura física, sem contrato
  -- associado), o componente PON é 0 — preserva compatibilidade com chamadas que só querem
  -- postes+metros.
  v_pons_count := coalesce(p_pons_count, 0);

  if v_poles_count < 0 then
    raise exception 'poles_count não pode ser negativo (obtido %).', v_poles_count;
  end if;
  if v_network_meters < 0 then
    raise exception 'network_meters não pode ser negativo (obtido %).', v_network_meters;
  end if;
  if v_pons_count < 0 then
    raise exception 'pons_count não pode ser negativo (obtido %).', v_pons_count;
  end if;

  v_price_pole := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_POSTE', p_cidade_id, p_pricing_version);
  v_price_meter_floor := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_METRO_PISO', p_cidade_id, p_pricing_version);
  v_price_meter_recommended := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_METRO_RECOMENDADO', p_cidade_id, p_pricing_version);
  v_price_meter_opening := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_METRO_ABERTURA', p_cidade_id, p_pricing_version);
  v_price_pon_floor := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_PON_PISO', p_cidade_id, p_pricing_version);
  v_price_pon_recommended := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_PON_RECOMENDADO', p_cidade_id, p_pricing_version);
  v_price_pon_opening := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_PON_ABERTURA', p_cidade_id, p_pricing_version);

  if v_price_pole < 0 or v_price_meter_floor < 0 or v_price_meter_recommended < 0 or v_price_meter_opening < 0
     or v_price_pon_floor < 0 or v_price_pon_recommended < 0 or v_price_pon_opening < 0 then
    raise exception 'Preços do Infrastructure Floor não podem ser negativos.';
  end if;

  -- Fórmula (seção 3/6/7/8): PISO/RECOMENDADO/ABERTURA = postes×preço_poste +
  -- metros×preço_metro(nível) + pons×preço_pon(nível). O preço do poste NÃO varia por
  -- nível da régua (só metro e PON têm 3 preços — piso/recomendado/abertura).
  v_pole_component := v_poles_count * v_price_pole;
  v_floor_meter_component := v_network_meters * v_price_meter_floor;
  v_recommended_meter_component := v_network_meters * v_price_meter_recommended;
  v_opening_meter_component := v_network_meters * v_price_meter_opening;
  v_floor_pon_component := v_pons_count * v_price_pon_floor;
  v_recommended_pon_component := v_pons_count * v_price_pon_recommended;
  v_opening_pon_component := v_pons_count * v_price_pon_opening;

  -- Rótulo de versão exibido: se p_pricing_version foi informado, é ele mesmo; senão, o
  -- rótulo da linha VIGENTE do parâmetro poste (representativo — todos os 8 parâmetros do
  -- Floor são sempre versionados juntos por app.criar_pricing_version, seção 29) — nunca
  -- mais um to_char(current_date) "adivinhado", que podia divergir do rótulo real da
  -- vigência em uso (bug silencioso corrigido nesta fase).
  if p_pricing_version is not null then
    v_pricing_version_label := p_pricing_version;
  else
    select pricing_version into v_pricing_version_label
    from public.pricing_parametros
    where chave = 'PISO_INFRAESTRUTURA_PRECO_POSTE' and (cidade_id = p_cidade_id or cidade_id is null) and vigente_ate is null
    order by cidade_id nulls last limit 1;
  end if;

  return jsonb_build_object(
    'cidade_id', p_cidade_id,
    'pop_id', p_pop_id,
    'pricing_version', v_pricing_version_label,
    'poles_count', v_poles_count,
    'network_meters', v_network_meters,
    'pons_count', v_pons_count,
    'price_per_pole', v_price_pole,
    'price_per_meter_floor', v_price_meter_floor,
    'price_per_meter_recommended', v_price_meter_recommended,
    'price_per_meter_opening', v_price_meter_opening,
    'price_per_pon_floor', v_price_pon_floor,
    'price_per_pon_recommended', v_price_pon_recommended,
    'price_per_pon_opening', v_price_pon_opening,
    'pole_component', round(v_pole_component, 2),
    'meter_component', round(v_floor_meter_component, 2),
    'pon_component', round(v_floor_pon_component, 2),
    'floor_price', round(v_pole_component + v_floor_meter_component + v_floor_pon_component, 2),
    'recommended_price', round(v_pole_component + v_recommended_meter_component + v_recommended_pon_component, 2),
    'opening_price', round(v_pole_component + v_opening_meter_component + v_opening_pon_component, 2)
  );
end;
$$;
comment on function app.calculate_infrastructure_floor(uuid, uuid, text, integer) is 'Fase 2.2 (seção 21/22) + Fase 2.2.1 (seção 3/16): PISO/RECOMENDADO/ABERTURA = (postes×preço_poste) + (metros×preço_metro do nível) + (pons×preço_pon do nível). p_pons_count é SEMPRE informado pelo chamador (nunca inferido aqui) — é a quantidade de Portas PON contratadas/reservadas, não o número de clientes (seção 19). p_pons_count NULL/omitido = componente PON zero (compatibilidade com consultas de infraestrutura pura). Continua sendo política comercial, nunca "custo real" (custos_infraestrutura, inalterada).';

-- 2) Funções de conveniência (seção 23/24) — visão por POP e visão consolidada da cidade,
--    reaproveitando a MESMA função central (nenhuma lógica duplicada) e a MESMA garantia
--    "nunca duplicar infraestrutura" já provada na Fase 2.2 (o consolidado sempre lê
--    cidades_infra/infra_postes, nunca soma os POPs).
create or replace function app.calculate_infrastructure_floor_by_pop(p_cidade_id uuid, p_pop_id uuid, p_pricing_version text default null, p_pons_count integer default null)
returns jsonb
language sql
stable
as $$
  select app.calculate_infrastructure_floor(p_cidade_id, p_pop_id, p_pricing_version, p_pons_count);
$$;
comment on function app.calculate_infrastructure_floor_by_pop(uuid, uuid, text, integer) is 'Fase 2.2.1 (seção 24): quebra do Infrastructure Floor por POP específico — alias explícito sobre app.calculate_infrastructure_floor(p_pop_id preenchido), sem lógica duplicada.';

create or replace function app.calculate_city_infrastructure_floor(p_cidade_id uuid, p_pricing_version text default null, p_pons_count integer default null)
returns jsonb
language sql
stable
as $$
  select app.calculate_infrastructure_floor(p_cidade_id, null, p_pricing_version, p_pons_count);
$$;
comment on function app.calculate_city_infrastructure_floor(uuid, text, integer) is 'Fase 2.2.1 (seção 24): Infrastructure Floor consolidado da cidade — alias explícito sobre app.calculate_infrastructure_floor(p_pop_id null), a fonte única que nunca duplica metros/postes somando POPs.';

-- 3) app.calculate_infrastructure_floor_for_contract — resolve cidade e PONs CONTRATADAS
--    (app.get_portas_contratadas_count, Fase 1.2, já existente e inalterada) a partir de um
--    contrato real, e delega para a função central. É o novo ponto de entrada "por
--    contrato" que os cálculos econômicos (get_economia_com_piso, migration 3/4) passam a
--    usar em vez de montar o piso sem PON.
create or replace function app.calculate_infrastructure_floor_for_contract(p_contrato_id uuid, p_pop_id uuid default null, p_pricing_version text default null)
returns jsonb
language plpgsql
stable
as $$
declare
  v_cidade_id uuid;
  v_pons_count integer;
begin
  select cidade_id into v_cidade_id from public.contratos where id = p_contrato_id;
  if not found then
    raise exception 'Contrato % não encontrado.', p_contrato_id;
  end if;

  -- get_portas_contratadas_count(contrato_id, somente_ativas default false): usamos o
  -- default (todas as portas CONTRATADAS, não só as ativas) porque a cobrança do PON é pela
  -- capacidade contratada/reservada, não pelo uso corrente (seção 19) — mesmo raciocínio já
  -- usado desde a Fase 1.2 para o mínimo contratual por porta.
  v_pons_count := app.get_portas_contratadas_count(p_contrato_id, false);

  return app.calculate_infrastructure_floor(v_cidade_id, p_pop_id, p_pricing_version, v_pons_count);
end;
$$;
comment on function app.calculate_infrastructure_floor_for_contract(uuid, uuid, text) is 'Fase 2.2.1 (seção 16/24): Infrastructure Floor de um contrato específico, incluindo o componente PON calculado a partir das Portas PON efetivamente contratadas (app.get_portas_contratadas_count, Fase 1.2, inalterada) — nunca por número de clientes.';

-- 4) Wrappers dependentes: mesma correção DROP+CREATE para não deixar nenhuma chamada
--    antiga ambígua.
drop function if exists public.pricing_infrastructure_floor(uuid, uuid, text);
create or replace function public.pricing_infrastructure_floor(p_cidade_id uuid, p_pop_id uuid default null, p_pricing_version text default null, p_pons_count integer default null)
returns jsonb
language sql
stable
security invoker
as $$
  select app.calculate_infrastructure_floor(p_cidade_id, p_pop_id, p_pricing_version, p_pons_count);
$$;
comment on function public.pricing_infrastructure_floor(uuid, uuid, text, integer) is 'Fase 2.2 (seção 21) + Fase 2.2.1 (seção 16): wrapper público de app.calculate_infrastructure_floor, agora com p_pons_count opcional.';
grant execute on function public.pricing_infrastructure_floor(uuid, uuid, text, integer) to authenticated;

drop function if exists public.pricing_infra_floor_negotiation(numeric, uuid, uuid, text);
create or replace function public.pricing_infra_floor_negotiation(p_preco_proposto numeric, p_cidade_id uuid, p_pop_id uuid default null, p_pricing_version text default null, p_pons_count integer default null)
returns jsonb
language plpgsql
stable
security invoker
as $$
declare
  v_floor jsonb;
  v_abertura numeric;
  v_recomendado numeric;
  v_piso numeric;
  v_desconto jsonb;
begin
  v_floor := app.calculate_infrastructure_floor(p_cidade_id, p_pop_id, p_pricing_version, p_pons_count);
  v_abertura := (v_floor ->> 'opening_price')::numeric;
  v_recomendado := (v_floor ->> 'recommended_price')::numeric;
  v_piso := (v_floor ->> 'floor_price')::numeric;
  v_desconto := app.calcular_desconto_comercial(v_abertura, p_preco_proposto, v_recomendado);

  return v_floor || jsonb_build_object(
    'preco_proposto', p_preco_proposto,
    'posicao_regua', app.classificar_posicao_regua(p_preco_proposto, v_abertura, v_recomendado, v_piso),
    'governanca', app.check_infrastructure_floor_governance(p_preco_proposto, v_recomendado, v_piso),
    'desconto', v_desconto,
    'diferenca_sobre_piso', round(p_preco_proposto - v_piso, 2)
  );
end;
$$;
comment on function public.pricing_infra_floor_negotiation(numeric, uuid, uuid, text, integer) is 'Fase 2.2 (seções 9/10/11/20/37-39) + Fase 2.2.1 (seção 16, p_pons_count): régua comercial completa, agora com o componente PON no piso/recomendado/abertura. O veredito de governança por perfil (BLOCK_FOR_COMMERCIAL/ALLOW_WITH_DIRECTOR_OVERRIDE) é exposto por public.pricing_infra_floor_negotiation_v2 (migration 3/4) — este wrapper mantém o campo "governanca" tri-estado (ALLOW/ALLOW_WITH_DISCOUNT/BLOCK) por compatibilidade com quem já o consome.';
grant execute on function public.pricing_infra_floor_negotiation(numeric, uuid, uuid, text, integer) to authenticated;

-- 5) app.get_economia_com_piso — mesma assinatura (CREATE OR REPLACE seguro, sem overload):
--    passa a resolver o Infrastructure Floor incluindo o componente PON, via
--    app.calculate_infrastructure_floor_for_contract() em vez de montar o piso sem PON.
create or replace function app.get_economia_com_piso(p_contrato_id uuid, p_faturamento_parceiro numeric, p_pop_id uuid DEFAULT NULL::uuid, p_pricing_version text DEFAULT NULL::text)
returns jsonb
language plpgsql
stable
as $$
declare
  v_contrato record;
  v_config record;
  v_floor_data jsonb;
  v_floor numeric;
  v_minimo numeric;
  v_revenue_share numeric;
  v_base numeric;
  v_total_payable numeric;
  v_receita_parceiro numeric;
begin
  select id, cidade_id into v_contrato from public.contratos where id = p_contrato_id;
  if not found then
    raise exception 'Contrato % não encontrado.', p_contrato_id;
  end if;

  select modelo_cobranca, percentual_revenue_share, infra_floor_composition_mode, minimum_infrastructure_floor_enforced
  into v_config
  from public.contrato_pricing_config
  where contrato_id = p_contrato_id;

  if not found then
    raise exception 'Contrato % não possui contrato_pricing_config cadastrado.', p_contrato_id;
  end if;

  -- Fase 2.2.1 (seção 16): o Floor agora inclui o componente PON, resolvido pelas Portas
  -- PON efetivamente contratadas — não mais só postes+metros.
  v_floor_data := app.calculate_infrastructure_floor_for_contract(p_contrato_id, p_pop_id, p_pricing_version);
  v_floor := (v_floor_data ->> 'floor_price')::numeric;
  v_minimo := app.calcular_minimo_contratual(p_contrato_id);
  v_revenue_share := round(coalesce(p_faturamento_parceiro, 0) * coalesce(v_config.percentual_revenue_share, 0), 2);

  if v_config.infra_floor_composition_mode = 'FLOOR_ONLY' then
    v_total_payable := v_floor;
  elsif v_config.infra_floor_composition_mode = 'MINIMUM_ONLY' then
    v_total_payable := app.calcular_cobranca_hibrida(p_contrato_id, p_faturamento_parceiro);
  else
    v_base := app.calcular_composicao_piso_minimo(v_config.infra_floor_composition_mode, v_floor, v_minimo);
    v_total_payable := case when v_config.modelo_cobranca = 'SOMA' then v_base + v_revenue_share
                             else greatest(v_base, v_revenue_share) end;
  end if;

  if v_config.minimum_infrastructure_floor_enforced and v_total_payable < v_floor then
    v_total_payable := v_floor;
  end if;

  v_receita_parceiro := coalesce(p_faturamento_parceiro, 0) - v_total_payable;

  return jsonb_build_object(
    'contrato_id', p_contrato_id,
    'infrastructure_floor', v_floor,
    'pons_count', (v_floor_data ->> 'pons_count')::integer,
    'minimum_contractual_fee', v_minimo,
    'revenue_share', v_revenue_share,
    'composicao_mode', v_config.infra_floor_composition_mode,
    'modelo_cobranca', v_config.modelo_cobranca,
    'minimum_infrastructure_floor_enforced', v_config.minimum_infrastructure_floor_enforced,
    'total_payable', round(v_total_payable, 2),
    'receita_optimon', round(v_total_payable, 2),
    'receita_parceiro', round(v_receita_parceiro, 2),
    'margem_parceiro', case when coalesce(p_faturamento_parceiro, 0) > 0 then round(v_receita_parceiro / p_faturamento_parceiro, 4) else null end
  );
end;
$$;
comment on function app.get_economia_com_piso(uuid, numeric, uuid, text) is 'Fase 2.2 (seção 17/30) + Fase 2.2.1 (seção 16, 20-22): comparação econômica completa — Infrastructure Floor agora inclui o componente PON (via app.calculate_infrastructure_floor_for_contract). Revenue Share continua representando só performance/faturamento do parceiro (seção 20 — não incorporado no Floor). Composição Floor×Mínimo e a rede de proteção "enforced" continuam inalteradas (seção 21/22 desta fase: nenhuma modalidade removida).';
