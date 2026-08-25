-- OptiMon — Fase 2.2.1: Ajuste Final de Governança + Precificação por Porta PON
-- Migration 6/6: correção — resolver o Infrastructure Floor sob uma Pricing Version
-- ANTERIOR à introdução do componente PON (ex.: "2026.08", a vigente antes desta fase)
-- não pode lançar exceção só porque os parâmetros de preço de PON ainda não existiam
-- naquela versão. Descoberto ao validar a própria bateria de regressão desta fase (seção
-- 29: "propostas antigas nunca são recalculadas com parâmetros novos" — mas eram
-- literalmente IMPOSSÍVEIS de recalcular até esta correção, porque
-- app.calculate_infrastructure_floor sempre resolvia os 3 preços de PON
-- incondicionalmente, mesmo quando pons_count=0 ou a versão pedida é anterior a PON
-- existir). Corrigido ANTES de qualquer teste/relatório usar o resultado — não é uma
-- mudança de comportamento em produção (a versão vigente atual sempre tem os 3
-- parâmetros de PON definidos, então nada muda para cálculos normais), só torna
-- consultas históricas pré-Fase-2.2.1 novamente calculáveis.
--
-- app.get_infra_floor_param() ganha um 4º parâmetro opcional p_default: quando informado
-- (not null) e o parâmetro não existir para o filtro pedido, devolve p_default em vez de
-- lançar exceção. DROP + CREATE (mesmo bug de overload-ambiguidade da Fase 2.2,
-- pricing_override_create: CREATE OR REPLACE com um parâmetro novo, mesmo com default,
-- criou um SEGUNDO get_infra_floor_param de 4 argumentos coexistindo com o antigo de 3,
-- deixando as chamadas de 3 argumentos ambíguas — "function ... is not unique",
-- verificado empiricamente ao validar esta própria migration; corrigido com DROP antes do
-- CREATE, mesma disciplina já aplicada às outras funções desta fase).
drop function if exists app.get_infra_floor_param(text, uuid, text);

create or replace function app.get_infra_floor_param(p_chave text, p_cidade_id uuid, p_pricing_version text default null, p_default numeric default null)
returns numeric
language plpgsql
stable
as $function$
declare
  v_valor numeric;
begin
  if p_pricing_version is not null then
    select valor into v_valor
    from public.pricing_parametros
    where chave = p_chave and (cidade_id = p_cidade_id or cidade_id is null)
      and pricing_version = p_pricing_version
    order by cidade_id nulls last
    limit 1;

    if not found then
      if p_default is not null then
        return p_default;
      end if;
      raise exception 'Pricing version "%": não existe uma vigência de "%" para essa versão (nem específica da cidade, nem global).', p_pricing_version, p_chave;
    end if;
  else
    select valor into v_valor
    from public.pricing_parametros
    where chave = p_chave and (cidade_id = p_cidade_id or cidade_id is null)
      and vigente_ate is null
    order by cidade_id nulls last
    limit 1;

    if not found then
      if p_default is not null then
        return p_default;
      end if;
      raise exception 'Parâmetro "%" não está configurado (nem para a cidade, nem globalmente).', p_chave;
    end if;
  end if;

  return v_valor;
end;
$function$;
comment on function app.get_infra_floor_param(text, uuid, text, numeric) is 'Fase 2.2 (seção 14/15) + Fase 2.2.1 (seção 29): resolve um parâmetro do Infrastructure Floor priorizando override por cidade sobre o global. Com p_pricing_version, casa pelo RÓTULO exato de versão. p_default (Fase 2.2.1, correção): quando informado, evita exceção para parâmetros que ainda não existiam numa versão histórica pedida (ex.: preços de PON, inexistentes antes de "2026.08.1") — devolve o default em vez de quebrar a consulta de uma proposta antiga.';

-- app.calculate_infrastructure_floor(): CREATE OR REPLACE com a MESMA assinatura de 4
-- argumentos (nenhuma mudança de aridade) — só os 3 get_infra_floor_param() dos preços de
-- PON passam a usar p_default := 0 (uma versão sem PON definido significa, por
-- definição, que o Floor daquela época não tinha componente PON — R$0 é o valor
-- correto, não um placeholder).
create or replace function app.calculate_infrastructure_floor(p_cidade_id uuid, p_pop_id uuid default null, p_pricing_version text default null, p_pons_count integer default null)
returns jsonb
language plpgsql
stable
as $function$
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
  -- Fase 2.2.1 (correção): p_default:=0 — uma pricing_version anterior à introdução do
  -- componente PON ("2026.08" e mais antigas) simplesmente não tinha esses parâmetros;
  -- 0 é o valor correto (Floor daquela época era só postes+metros), não uma exceção.
  v_price_pon_floor := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_PON_PISO', p_cidade_id, p_pricing_version, 0);
  v_price_pon_recommended := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_PON_RECOMENDADO', p_cidade_id, p_pricing_version, 0);
  v_price_pon_opening := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_PON_ABERTURA', p_cidade_id, p_pricing_version, 0);

  if v_price_pole < 0 or v_price_meter_floor < 0 or v_price_meter_recommended < 0 or v_price_meter_opening < 0
     or v_price_pon_floor < 0 or v_price_pon_recommended < 0 or v_price_pon_opening < 0 then
    raise exception 'Preços do Infrastructure Floor não podem ser negativos.';
  end if;

  v_pole_component := v_poles_count * v_price_pole;
  v_floor_meter_component := v_network_meters * v_price_meter_floor;
  v_recommended_meter_component := v_network_meters * v_price_meter_recommended;
  v_opening_meter_component := v_network_meters * v_price_meter_opening;
  v_floor_pon_component := v_pons_count * v_price_pon_floor;
  v_recommended_pon_component := v_pons_count * v_price_pon_recommended;
  v_opening_pon_component := v_pons_count * v_price_pon_opening;

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
$function$;
comment on function app.calculate_infrastructure_floor(uuid, uuid, text, integer) is 'Fase 2.2 (seção 21/22) + Fase 2.2.1 (seção 3/6-8): Infrastructure Floor = postes×preço_poste + metros×preço_metro(nível) + PONs×preço_pon(nível). Uma pricing_version anterior à existência do componente PON resolve o preço de PON como 0 (correção — ver comentário acima e migration 06), nunca lança exceção.';
