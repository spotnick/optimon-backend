-- OptiMon — Fase 2.2: Infrastructure Floor + Régua Comercial
-- Migration 2/4: motor de cálculo do piso (calculate_infrastructure_floor, seção 21/22) +
-- indicadores analíticos de fibras/portas ociosas (seções 25-27).

-- app.get_infra_floor_param: resolve um parâmetro do Infrastructure Floor com override
-- por cidade (seção 14) e, opcionalmente, uma "pricing version" específica (seção 15 —
-- mês de vigência no formato 'YYYY.MM'; NULL = a versão vigente hoje). Prioriza o valor
-- específico da cidade sobre o global quando ambos existem para a mesma chave/versão.
create or replace function app.get_infra_floor_param(p_chave text, p_cidade_id uuid, p_pricing_version text default null)
returns numeric
language plpgsql
stable
as $$
declare
  v_valor numeric;
begin
  if p_pricing_version is not null then
    select valor into v_valor
    from public.pricing_parametros
    where chave = p_chave and (cidade_id = p_cidade_id or cidade_id is null)
      and to_char(vigente_desde, 'YYYY.MM') = p_pricing_version
    order by cidade_id nulls last
    limit 1;

    if not found then
      raise exception 'Pricing version "%": não existe uma vigência de "%" para essa versão (nem específica da cidade, nem global).', p_pricing_version, p_chave;
    end if;
  else
    select valor into v_valor
    from public.pricing_parametros
    where chave = p_chave and (cidade_id = p_cidade_id or cidade_id is null)
      and (vigente_ate is null or vigente_ate >= current_date)
    order by cidade_id nulls last
    limit 1;

    if not found then
      raise exception 'Parâmetro "%" não está configurado (nem para a cidade, nem globalmente).', p_chave;
    end if;
  end if;

  return v_valor;
end;
$$;
comment on function app.get_infra_floor_param(text, uuid, text) is 'Fase 2.2 (seção 14/15): resolve um parâmetro do Infrastructure Floor priorizando override por cidade sobre o global; com p_pricing_version, resolve o valor histórico vigente naquele mês (para nunca recalcular propostas antigas com parâmetro novo — seção 15).';

-- app.calculate_infrastructure_floor: função central da seção 21/22. Sem POP (p_pop_id
-- NULL) usa os totais consolidados da CIDADE (cidades_infra.km_rede, SUM(infra_postes) —
-- nunca a soma dos POPs, para nunca duplicar metros, seção 24); com POP, usa os campos
-- analíticos de infra_pops (seção 24/27).
create or replace function app.calculate_infrastructure_floor(p_cidade_id uuid, p_pop_id uuid default null, p_pricing_version text default null)
returns jsonb
language plpgsql
stable
as $$
declare
  v_cidade record;
  v_pop record;
  v_poles_count integer;
  v_network_meters numeric;
  v_price_pole numeric;
  v_price_meter_floor numeric;
  v_price_meter_recommended numeric;
  v_price_meter_opening numeric;
  v_pole_component numeric;
  v_floor_meter_component numeric;
  v_recommended_meter_component numeric;
  v_opening_meter_component numeric;
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

  -- Validações (seção 23) — defensivas: as CHECK constraints das tabelas de origem já
  -- impedem quantidade/extensao_km/km_rede negativos, então isto nunca deveria disparar
  -- na prática; mantido explícito porque a seção 23 pede a validação na própria função.
  if v_poles_count < 0 then
    raise exception 'poles_count não pode ser negativo (obtido %).', v_poles_count;
  end if;
  if v_network_meters < 0 then
    raise exception 'network_meters não pode ser negativo (obtido %).', v_network_meters;
  end if;

  v_price_pole := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_POSTE', p_cidade_id, p_pricing_version);
  v_price_meter_floor := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_METRO_PISO', p_cidade_id, p_pricing_version);
  v_price_meter_recommended := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_METRO_RECOMENDADO', p_cidade_id, p_pricing_version);
  v_price_meter_opening := app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_METRO_ABERTURA', p_cidade_id, p_pricing_version);

  if v_price_pole < 0 or v_price_meter_floor < 0 or v_price_meter_recommended < 0 or v_price_meter_opening < 0 then
    raise exception 'Preços do Infrastructure Floor não podem ser negativos.';
  end if;

  -- Fórmula (seção 22, pseudo-código do prompt, implementado literalmente):
  v_pole_component := v_poles_count * v_price_pole;
  v_floor_meter_component := v_network_meters * v_price_meter_floor;
  v_recommended_meter_component := v_network_meters * v_price_meter_recommended;
  v_opening_meter_component := v_network_meters * v_price_meter_opening;

  return jsonb_build_object(
    'cidade_id', p_cidade_id,
    'pop_id', p_pop_id,
    'pricing_version', coalesce(p_pricing_version, to_char(current_date, 'YYYY.MM')),
    'poles_count', v_poles_count,
    'network_meters', v_network_meters,
    'price_per_pole', v_price_pole,
    'price_per_meter_floor', v_price_meter_floor,
    'price_per_meter_recommended', v_price_meter_recommended,
    'price_per_meter_opening', v_price_meter_opening,
    'pole_component', round(v_pole_component, 2),
    'meter_component', round(v_floor_meter_component, 2),
    'floor_price', round(v_pole_component + v_floor_meter_component, 2),
    'recommended_price', round(v_pole_component + v_recommended_meter_component, 2),
    'opening_price', round(v_pole_component + v_opening_meter_component, 2)
  );
end;
$$;
comment on function app.calculate_infrastructure_floor(uuid, uuid, text) is 'Fase 2.2 (seção 21/22): PISO/RECOMENDADO/ABERTURA do Infrastructure Floor = (postes × preço/poste) + (metros × preço/metro do nível). É POLÍTICA COMERCIAL de monetização mínima, nunca "custo real" (seção 12/43) — os custos reais continuam em custos_infraestrutura, inalterados. p_pop_id NULL = consolidado da cidade (cidades_infra.km_rede / SUM(infra_postes), nunca soma de POPs — seção 24); p_pop_id preenchido = quebra analítica daquele POP (infra_pops.km_rede/postes_count, seção 27).';

-- app.get_fibras_indicadores_cidade (seção 25): fibras totais/ocupadas/ociosas + Portas
-- PON totais/disponíveis, escopado por cidade ou por POP (via infra_cabos.pop_id).
-- "Ociosa" = status_comercial = 'LIVRE' (mesmo enum usado desde a Fase 1: LIVRE = fibra
-- fisicamente disponível para contratação comercial; RESERVADA/BLOQUEADA não contam como
-- ociosa nem como "ocupada por contrato" — são estados à parte, refletidos em fibras_totais).
create or replace function app.get_fibras_indicadores_cidade(p_cidade_id uuid, p_pop_id uuid default null)
returns jsonb
language sql
stable
as $$
  with fibras as (
    select f.status_comercial
    from public.infra_fibras f
    join public.infra_cabos c on c.id = f.cabo_id
    join public.infra_segmentos s on s.id = c.segmento_id
    where s.cidade_id = p_cidade_id and (p_pop_id is null or c.pop_id = p_pop_id)
  ),
  portas as (
    select p.situacao_comercial
    from public.infra_portas_pon p
    join public.infra_pops pop on pop.id = p.pop_id
    where pop.cidade_id = p_cidade_id and (p_pop_id is null or p.pop_id = p_pop_id)
  )
  select jsonb_build_object(
    'fibras_totais', (select count(*) from fibras),
    'fibras_ociosas', (select count(*) from fibras where status_comercial = 'LIVRE'),
    'fibras_ocupadas', (select count(*) from fibras where status_comercial <> 'LIVRE'),
    'portas_pon_totais', (select count(*) from portas),
    'portas_pon_disponiveis', (select count(*) from portas where situacao_comercial = 'DISPONIVEL')
  );
$$;
comment on function app.get_fibras_indicadores_cidade(uuid, uuid) is 'Fase 2.2 (seção 25): metros totais (via calculate_infrastructure_floor), fibras totais/ocupadas/ociosas e Portas PON totais/disponíveis de uma cidade (ou de um POP específico) — nunca presume que toda a infraestrutura está locada (seção 25). Base para os indicadores por fibra/por PON (seção 26/27).';

-- Indicadores analíticos (seções 26-27) — NÃO substituem a fórmula principal do piso,
-- só reexpressam o mesmo valor "por unidade" para apoiar a análise comercial de escala.
create or replace function app.get_valor_infra_floor_por_fibra(p_infrastructure_floor numeric, p_fibras_ociosas integer)
returns numeric
language sql
immutable
as $$
  select case when p_fibras_ociosas is null or p_fibras_ociosas <= 0 then null
              else round(p_infrastructure_floor / p_fibras_ociosas, 2) end;
$$;
comment on function app.get_valor_infra_floor_por_fibra(numeric, integer) is 'Fase 2.2 (seção 26): "Valor da infraestrutura / fibra" = Infrastructure Floor ÷ fibras ociosas — indicador ANALÍTICO (nunca substitui a fórmula principal do piso). NULL quando não há fibra ociosa (divisão por zero evitada, não inventada).';

create or replace function app.get_valor_infra_floor_por_porta_pon(p_infrastructure_floor numeric, p_portas_pon integer)
returns numeric
language sql
immutable
as $$
  select case when p_portas_pon is null or p_portas_pon <= 0 then null
              else round(p_infrastructure_floor / p_portas_pon, 2) end;
$$;
comment on function app.get_valor_infra_floor_por_porta_pon(numeric, integer) is 'Fase 2.2 (seção 27): "Piso equivalente por Porta PON" = Infrastructure Floor ÷ Portas PON contratadas — ajuda o Comercial a analisar desconto por escala (nunca aplicado automaticamente, seção 28 — quantity_discount_rules fica para o futuro).';
