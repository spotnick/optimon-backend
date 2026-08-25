-- OptiMon — Fase 2.2: Infrastructure Floor + Régua Comercial
-- Migration 3/4: régua comercial (desconto, governança, posição na régua — seções 6-11,
-- 20, 37-39), composição Floor×Mínimo (seção 32/33) e breakeven do piso (seção 34).

-- app.calcular_desconto_comercial (seção 10/38): desconto absoluto/percentual sobre a
-- ABERTURA (seção 10, sempre calculado) e, quando um "recomendado" é informado, também
-- sobre o RECOMENDADO (seção 38 — métrica adicional/contextual, não substitui a de cima).
create or replace function app.calcular_desconto_comercial(p_preco_abertura numeric, p_preco_proposto numeric, p_preco_recomendado numeric default null)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_desc_abs_abertura numeric;
  v_desc_pct_abertura numeric;
  v_desc_abs_recomendado numeric;
  v_desc_pct_recomendado numeric;
begin
  if p_preco_abertura is null or p_preco_proposto is null or p_preco_abertura = 0 then
    return jsonb_build_object('desconto_absoluto_abertura', null, 'desconto_percentual_abertura', null, 'desconto_absoluto_recomendado', null, 'desconto_percentual_recomendado', null);
  end if;

  v_desc_abs_abertura := round(p_preco_abertura - p_preco_proposto, 2);
  v_desc_pct_abertura := round((p_preco_abertura - p_preco_proposto) / p_preco_abertura, 4);

  if p_preco_recomendado is not null and p_preco_recomendado <> 0 then
    v_desc_abs_recomendado := round(p_preco_recomendado - p_preco_proposto, 2);
    v_desc_pct_recomendado := round((p_preco_recomendado - p_preco_proposto) / p_preco_recomendado, 4);
  end if;

  return jsonb_build_object(
    'desconto_absoluto_abertura', v_desc_abs_abertura,
    'desconto_percentual_abertura', v_desc_pct_abertura,
    'desconto_absoluto_recomendado', v_desc_abs_recomendado,
    'desconto_percentual_recomendado', v_desc_pct_recomendado
  );
end;
$$;
comment on function app.calcular_desconto_comercial(numeric, numeric, numeric) is 'Fase 2.2 (seção 10/38): desconto absoluto/percentual do preço proposto sobre a ABERTURA (seção 10, principal — ex.: abertura R$2.650, proposta R$2.400 → desconto R$250/9,43%) e, opcionalmente, sobre o RECOMENDADO (seção 38, métrica adicional).';

-- app.classificar_posicao_regua (seção 9/20/37): rótulo textual da posição do preço
-- proposto na régua de 3 níveis. Distinto de check_infrastructure_floor_governance
-- (abaixo) — este é o RÓTULO de exibição, aquele é o VEREDITO de aprovação.
create or replace function app.classificar_posicao_regua(p_preco_proposto numeric, p_preco_abertura numeric, p_preco_recomendado numeric, p_preco_piso numeric)
returns text
language plpgsql
immutable
as $$
begin
  if p_preco_proposto is null or p_preco_abertura is null or p_preco_recomendado is null or p_preco_piso is null then
    return 'PARAMETRIZÁVEL — régua incompleta.';
  end if;

  if p_preco_proposto >= p_preco_abertura then return 'PREÇO DE ABERTURA';
  elsif p_preco_proposto = p_preco_recomendado then return 'PREÇO RECOMENDADO';
  elsif p_preco_proposto > p_preco_recomendado then return 'DENTRO DA RÉGUA';
  elsif p_preco_proposto = p_preco_piso then return 'PREÇO DE RESERVA';
  elsif p_preco_proposto > p_preco_piso then return 'DESCONTO SOBRE RECOMENDADO';
  else return 'BLOCKED';
  end if;
end;
$$;
comment on function app.classificar_posicao_regua(numeric, numeric, numeric, numeric) is 'Fase 2.2 (seção 9/20/37): rótulo de posição na régua comercial (ABERTURA→RECOMENDADO→PISO→BLOQUEADO), espelhando literalmente os 6 exemplos da seção 20 (R$2.650/2.500/2.400/2.250/2.150/2.100 → PREÇO DE ABERTURA/DENTRO DA RÉGUA/PREÇO RECOMENDADO/DESCONTO SOBRE RECOMENDADO/PREÇO DE RESERVA/BLOCKED).';

-- app.check_infrastructure_floor_governance (seção 11/39): veredito de aprovação — 3
-- saídas (ALLOW / ALLOW_WITH_DISCOUNT / BLOCK), distinto do app.check_pricing_governance
-- já existente da Fase 2 (usado pelo Cenário 2/Dark Fiber, com REQUIRES_APPROVAL — não
-- alterado, continua em uso onde já era usado).
create or replace function app.check_infrastructure_floor_governance(p_preco_proposto numeric, p_preco_recomendado numeric, p_preco_piso numeric)
returns text
language plpgsql
immutable
as $$
begin
  if p_preco_proposto is null or p_preco_recomendado is null or p_preco_piso is null then
    return 'PARAMETRIZÁVEL — régua não definida, governança não pode ser avaliada.';
  end if;

  if p_preco_proposto >= p_preco_recomendado then
    return 'ALLOW';
  elsif p_preco_proposto >= p_preco_piso then
    return 'ALLOW_WITH_DISCOUNT';
  else
    return 'BLOCK';
  end if;
end;
$$;
comment on function app.check_infrastructure_floor_governance(numeric, numeric, numeric) is 'Fase 2.2 (seção 11/39): preço >= recomendado (cobre também >= abertura, pois abertura > recomendado por construção) → ALLOW; recomendado > preço >= piso → ALLOW_WITH_DISCOUNT (exige justificativa, seção 39); preço < piso → BLOCK (só Diretor autoriza via o override já existente da Fase 2, ver public.pricing_override_create).';

-- app.calcular_composicao_piso_minimo (seção 32/33): resolve a BASE (antes de combinar
-- com Revenue Share) a partir de infra_floor_composition_mode — nunca soma Floor+Mínimo
-- "por acidente".
create or replace function app.calcular_composicao_piso_minimo(p_modo public.infra_floor_composition_mode, p_infrastructure_floor numeric, p_minimo_contratual numeric)
returns numeric
language sql
immutable
as $$
  select case p_modo
    when 'FLOOR_ONLY' then p_infrastructure_floor
    when 'MINIMUM_ONLY' then p_minimo_contratual
    when 'FLOOR_AS_MINIMUM' then p_infrastructure_floor
    when 'SUM' then p_infrastructure_floor + p_minimo_contratual
    when 'MAX' then greatest(p_infrastructure_floor, p_minimo_contratual)
  end;
$$;
comment on function app.calcular_composicao_piso_minimo(public.infra_floor_composition_mode, numeric, numeric) is 'Fase 2.2 (seção 32/33): FLOOR_ONLY e FLOOR_AS_MINIMUM têm o mesmo valor de BASE (o Floor) mas destinos diferentes em app.get_economia_com_piso — FLOOR_ONLY ignora Revenue Share por completo (total = Floor, ponto final); FLOOR_AS_MINIMUM alimenta essa base no motor SOMA/MAX com Revenue Share já existente (ex.: MAX(Floor, Revenue Share), seção 33). MINIMUM_ONLY preserva 100% o comportamento pré-Fase-2.2 (Floor vira só informativo).';

-- app.calcular_breakeven_infra_floor / _clientes (seção 34): mesma forma dos breakevens
-- já existentes (Fase 2), mas tomando o Infrastructure Floor como referência em vez do
-- mínimo contratual — os dois conceitos coexistem (seção 16), nenhum substitui o outro.
create or replace function app.calcular_breakeven_infra_floor(p_infrastructure_floor numeric, p_revenue_share_percent numeric)
returns numeric
language sql
immutable
as $$
  select case when p_revenue_share_percent is null or p_revenue_share_percent = 0 then null
              else round(p_infrastructure_floor / p_revenue_share_percent, 2) end;
$$;
comment on function app.calcular_breakeven_infra_floor(numeric, numeric) is 'Fase 2.2 (seção 34): break_even_revenue = infrastructure_floor / revenue_share_percent. Para Jussara (piso R$2.150, share 12%): R$17.916,67 — mesma forma de app.calcular_breakeven_faturamento (Fase 2), mas tomando o Floor como referência em vez do mínimo contratual (os dois coexistem, seção 16).';

create or replace function app.calcular_breakeven_infra_floor_clientes(p_infrastructure_floor numeric, p_revenue_share_percent numeric, p_arpu numeric)
returns integer
language plpgsql
immutable
as $$
declare
  v_breakeven numeric;
begin
  if p_arpu is null or p_arpu <= 0 then return null; end if;
  v_breakeven := app.calcular_breakeven_infra_floor(p_infrastructure_floor, p_revenue_share_percent);
  if v_breakeven is null then return null; end if;
  return ceil(v_breakeven / p_arpu)::integer;
end;
$$;
comment on function app.calcular_breakeven_infra_floor_clientes(numeric, numeric, numeric) is 'Fase 2.2 (seção 34): ceil(breakeven_revenue / ARPU) — Jussara com ARPU R$100: ceil(17916.67/100) = 180 clientes. Como 1 Porta PON só comporta 128 (capacidade padrão, Fase 2.1), o sistema deve comunicar que com 1 PON o Revenue Share nunca supera o Floor dentro da capacidade máxima — ver app.calcular_escala_pon_para_meta abaixo.';

-- app.calcular_escala_pon_para_meta (seção 34/35): quantas Portas PON são necessárias
-- para atingir uma meta de clientes, e se 1 única PON basta para superar o Floor via
-- Revenue Share (insight comercial explícito pedido na seção 34).
create or replace function app.calcular_escala_pon_para_meta(p_clientes_meta integer, p_capacidade_por_porta integer default 128)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_portas integer;
begin
  v_portas := app.get_portas_necessarias(p_clientes_meta, p_capacidade_por_porta);
  return jsonb_build_object(
    'clientes_meta', p_clientes_meta,
    'capacidade_por_porta', p_capacidade_por_porta,
    'portas_pon_necessarias', v_portas,
    'insight', case
      when p_clientes_meta <= p_capacidade_por_porta then
        format('Com 1 Porta PON e a meta de %s clientes (dentro da capacidade máxima de %s), o Revenue Share pode não superar o Infrastructure Floor — verifique o breakeven em clientes antes de comprometer a proposta.', p_clientes_meta, p_capacidade_por_porta)
      else
        format('Meta de %s clientes exige %s Portas PON (capacidade de %s cada) — recalcule Infrastructure Floor, Revenue Share, Mínimo e Total a cada escala de porta (seção 35).', p_clientes_meta, v_portas, p_capacidade_por_porta)
    end
  );
end;
$$;
comment on function app.calcular_escala_pon_para_meta(integer, integer) is 'Fase 2.2 (seção 34/35): quantas Portas PON uma meta de clientes exige (reaproveita app.get_portas_necessarias, Fase 2, inalterada) + o insight comercial da seção 34 sobre a relação entre capacidade de 1 PON e o breakeven do Floor.';

-- app.get_economia_com_piso (seção 17/30): a "comparação econômica" completa que a tela
-- de simulação deve mostrar — Infrastructure Floor, Minimum Contractual Fee, Revenue
-- Share, Total a Pagar, Receita OptiMon, Receita do Parceiro, Margem do Parceiro. Nunca
-- assume Floor+Mínimo automaticamente (seção 32) — usa a composição configurada no
-- contrato, com o Floor como rede de proteção final quando enforced=true (seção 18).
create or replace function app.get_economia_com_piso(p_contrato_id uuid, p_faturamento_parceiro numeric, p_pop_id uuid default null, p_pricing_version text default null)
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

  v_floor_data := app.calculate_infrastructure_floor(v_contrato.cidade_id, p_pop_id, p_pricing_version);
  v_floor := (v_floor_data ->> 'floor_price')::numeric;
  v_minimo := app.calcular_minimo_contratual(p_contrato_id);
  v_revenue_share := round(coalesce(p_faturamento_parceiro, 0) * coalesce(v_config.percentual_revenue_share, 0), 2);

  if v_config.infra_floor_composition_mode = 'FLOOR_ONLY' then
    -- Floor sozinho é o total — Revenue Share fica só informativo (nunca somado aqui).
    v_total_payable := v_floor;
  elsif v_config.infra_floor_composition_mode = 'MINIMUM_ONLY' then
    -- Comportamento 100% igual ao pré-Fase-2.2: Floor é só informativo.
    v_total_payable := app.calcular_cobranca_hibrida(p_contrato_id, p_faturamento_parceiro);
  else
    v_base := app.calcular_composicao_piso_minimo(v_config.infra_floor_composition_mode, v_floor, v_minimo);
    v_total_payable := case when v_config.modelo_cobranca = 'SOMA' then v_base + v_revenue_share
                             else greatest(v_base, v_revenue_share) end;
  end if;

  -- Rede de proteção final (seção 18): com minimum_infrastructure_floor_enforced=true,
  -- nenhum total calculado pode ficar abaixo do Floor, qualquer que seja o modo escolhido.
  if v_config.minimum_infrastructure_floor_enforced and v_total_payable < v_floor then
    v_total_payable := v_floor;
  end if;

  v_receita_parceiro := coalesce(p_faturamento_parceiro, 0) - v_total_payable;

  return jsonb_build_object(
    'contrato_id', p_contrato_id,
    'infrastructure_floor', v_floor,
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
comment on function app.get_economia_com_piso(uuid, numeric, uuid, text) is 'Fase 2.2 (seção 17/30): comparação econômica completa (Infrastructure Floor, Minimum Contractual Fee, Revenue Share, Total a Pagar, Receita OptiMon/Parceiro, Margem do Parceiro) — a composição do total nunca soma Floor+Mínimo por acidente (seção 32), segue infra_floor_composition_mode do contrato, e nunca fica abaixo do Floor quando minimum_infrastructure_floor_enforced=true (seção 18). Não altera app.calcular_cobranca_hibrida nem app.calcular_minimo_contratual (Fase 2/1.2) — só as reaproveita.';
