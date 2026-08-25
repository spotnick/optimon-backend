-- OptiMon — Fase 2.2.1: Ajuste Final de Governança + Precificação por Porta PON
-- Migration 3/4: nova governança por perfil (seção 12), limite máximo de desconto de
-- override (seção 13), permissão explícita para FINANCEIRO (seção 35), MAX como composição
-- default recomendada para contratos novos (seção 21).

-- 1) usuarios ganha 1 coluna opcional (seção 35: "Financeiro tentando override: BLOCKED,
--    salvo se possuir permissão explicitamente configurada") — default FALSE preserva 100%
--    do comportamento atual (nenhum FINANCEIRO existente ganha permissão de aprovar override
--    s.
alter table public.usuarios add column if not exists pode_aprovar_override_pricing boolean not null default false;
comment on column public.usuarios.pode_aprovar_override_pricing is 'Fase 2.2.1 (seção 35): permissão explícita para um usuário FINANCEIRO aprovar override de Infrastructure Floor abaixo do piso — DIRETOR/ADMINISTRADOR sempre podem, independentemente desta coluna. Default FALSE: nenhum FINANCEIRO ganha a permissão automaticamente.';

-- 2) Limite máximo de desconto de override (seção 13): preço mínimo autorizável, calculado
--    sobre o preço de ABERTURA (nunca sobre o recomendado ou o piso).
create or replace function app.calcular_preco_minimo_autorizado(p_preco_abertura numeric, p_max_override_discount_percent numeric)
returns numeric
language sql
immutable
as $$
  select case when p_preco_abertura is null or p_max_override_discount_percent is null then null
              else round(p_preco_abertura * (1 - p_max_override_discount_percent), 2) end;
$$;
comment on function app.calcular_preco_minimo_autorizado(numeric, numeric) is 'Fase 2.2.1 (seção 13): MINIMUM_AUTHORIZED_PRICE = OPENING_PRICE × (1 - MAX_OVERRIDE_DISCOUNT_PERCENT). Abaixo deste valor, NENHUM perfil (nem Diretor/Administrador) pode aprovar override — é um piso absoluto, não um piso "sujeito à aprovação". Exemplo oficial: abertura R$2.620,00 × (1-50%) = R$1.310,00.';

-- 3) Governança por perfil (seção 12) — 5 vereditos possíveis. Resolve o perfil
--    INTERNAMENTE via app.perfil_atual() (nunca recebido como parâmetro do chamador, para
--    não ser falsificável pela API/cliente — mesmo padrão de segurança de toda RLS do
--    sistema desde a Fase 1).
--
--    IMPORTANTE — divergência encontrada entre a seção 12 (regra) e a seção 33 (exemplo de
--    teste) deste prompt, documentada no relatório de entrega: a seção 12 define a régua
--    como "proposto >= abertura -> ALLOW; proposto < abertura e >= recomendado -> ALLOW;
--    proposto < recomendado e >= piso -> ALLOW_WITH_DISCOUNT; proposto < piso ->
--    BLOCK_FOR_COMMERCIAL". Sob essa régua, com o piso de Jussara em R$2.020, um preço de
--    R$2.100 (>= piso) deveria ser ALLOW_WITH_DISCOUNT — mas a seção 33 lista R$2.100 como
--    "BLOCK_FOR_COMMERCIAL", o que só seria consistente se o piso fosse > R$2.100. Esta
--    implementação segue a FÓRMULA explícita da seção 12 (a regra em si, não um exemplo
--    numérico isolado que contradiz a própria régua que o prompt define) — ver TESTE-33 e
--    o item 14 do relatório de entrega para o teste que exercita corretamente o limiar.
create or replace function app.check_infrastructure_floor_governance_role(
  p_preco_proposto numeric,
  p_preco_abertura numeric,
  p_preco_recomendado numeric,
  p_preco_piso numeric,
  p_max_override_discount_percent numeric default null
)
returns text
language plpgsql
stable
as $$
declare
  v_perfil public.perfil_usuario;
  v_pode_override boolean;
  v_min_autorizado numeric;
begin
  if p_preco_proposto is null or p_preco_abertura is null or p_preco_recomendado is null or p_preco_piso is null then
    return 'PARAMETRIZÁVEL — régua não definida, governança não pode ser avaliada.';
  end if;

  -- Seção 12: ">= abertura" e "< abertura e >= recomendado" colapsam na prática em ">=
  -- recomendado" (abertura >= recomendado por construção da régua) — mantido como um único
  -- ramo ALLOW, exatamente equivalente ao check tri-estado já usado desde a Fase 2.2.
  if p_preco_proposto >= p_preco_recomendado then
    return 'ALLOW';
  elsif p_preco_proposto >= p_preco_piso then
    return 'ALLOW_WITH_DISCOUNT';
  end if;

  -- proposto < piso: Comercial nunca aprova sozinho (seção 12/14). Diretor/Administrador
  -- (ou Financeiro com permissão explícita, seção 35) podem executar override — mas só até
  -- o limite absoluto de MAX_OVERRIDE_DISCOUNT_PERCENT sobre a abertura (seção 13);
  -- nenhum perfil aprova abaixo desse piso absoluto.
  v_perfil := app.perfil_atual();
  v_pode_override := v_perfil in ('DIRETOR', 'ADMINISTRADOR')
    or (v_perfil = 'FINANCEIRO' and coalesce((select pode_aprovar_override_pricing from public.usuarios where id = auth.uid()), false));

  if not v_pode_override then
    return 'BLOCK_FOR_COMMERCIAL';
  end if;

  v_min_autorizado := app.calcular_preco_minimo_autorizado(p_preco_abertura, p_max_override_discount_percent);
  if v_min_autorizado is not null and p_preco_proposto < v_min_autorizado then
    return 'BLOCK';
  end if;

  return 'ALLOW_WITH_DIRECTOR_OVERRIDE';
end;
$$;
comment on function app.check_infrastructure_floor_governance_role(numeric, numeric, numeric, numeric, numeric) is 'Fase 2.2.1 (seção 12/13/14/35): veredito de governança CIENTE DE PERFIL (resolvido internamente via app.perfil_atual(), nunca recebido do chamador). ALLOW / ALLOW_WITH_DISCOUNT (>= piso) / BLOCK_FOR_COMMERCIAL (< piso, perfil sem permissão de override) / ALLOW_WITH_DIRECTOR_OVERRIDE (< piso, perfil autorizado E dentro do limite de 50% sobre a abertura) / BLOCK (abaixo do limite absoluto — nenhum perfil aprova). Coexiste com app.check_infrastructure_floor_governance (Fase 2.2, tri-estado, sem noção de perfil) sem alterá-la — quem já consome o campo antigo continua recebendo ALLOW/ALLOW_WITH_DISCOUNT/BLOCK sem mudança de comportamento.';

-- 4) public.pricing_infra_floor_negotiation — MESMA assinatura da migration 2/4 desta fase
--    (numeric, uuid, uuid, text, integer): CREATE OR REPLACE seguro, só o corpo muda, para
--    expor também o veredito ciente de perfil e o preço mínimo autorizado.
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
  v_max_discount numeric;
  v_min_autorizado numeric;
begin
  v_floor := app.calculate_infrastructure_floor(p_cidade_id, p_pop_id, p_pricing_version, p_pons_count);
  v_abertura := (v_floor ->> 'opening_price')::numeric;
  v_recomendado := (v_floor ->> 'recommended_price')::numeric;
  v_piso := (v_floor ->> 'floor_price')::numeric;
  v_desconto := app.calcular_desconto_comercial(v_abertura, p_preco_proposto, v_recomendado);
  v_max_discount := app.get_infra_floor_param('MAX_OVERRIDE_DISCOUNT_PERCENT', p_cidade_id, p_pricing_version);
  v_min_autorizado := app.calcular_preco_minimo_autorizado(v_abertura, v_max_discount);

  return v_floor || jsonb_build_object(
    'preco_proposto', p_preco_proposto,
    'posicao_regua', app.classificar_posicao_regua(p_preco_proposto, v_abertura, v_recomendado, v_piso),
    'governanca', app.check_infrastructure_floor_governance(p_preco_proposto, v_recomendado, v_piso),
    'governanca_comercial', app.check_infrastructure_floor_governance_role(p_preco_proposto, v_abertura, v_recomendado, v_piso, v_max_discount),
    'max_override_discount_percent', v_max_discount,
    'preco_minimo_autorizado', v_min_autorizado,
    'desconto', v_desconto,
    'diferenca_sobre_piso', round(p_preco_proposto - v_piso, 2),
    'diferenca_sobre_recomendado', round(p_preco_proposto - v_recomendado, 2)
  );
end;
$$;
comment on function public.pricing_infra_floor_negotiation(numeric, uuid, uuid, text, integer) is 'Fase 2.2 (seções 9/10/11/20/37-39) + Fase 2.2.1 (seções 12/13/16): régua comercial completa, agora com componente PON e o veredito ciente de perfil ("governanca_comercial": ALLOW/ALLOW_WITH_DISCOUNT/BLOCK_FOR_COMMERCIAL/ALLOW_WITH_DIRECTOR_OVERRIDE/BLOCK) + o preço mínimo autorizado (limite de 50% sobre a abertura). O campo "governanca" tri-estado (Fase 2.2) permanece inalterado para compatibilidade.';

-- 5) fn_override_decisao — MESMA assinatura de trigger (sem parâmetros, sempre segura para
--    CREATE OR REPLACE). Dois acréscimos: (a) Financeiro com permissão explícita passa a
--    poder decidir, ao lado de Diretor/Administrador; (b) abaixo do preço mínimo autorizado
--    (seção 13), a aprovação é bloqueada para QUALQUER perfil — piso absoluto, não sujeito a
--    exceção. Só se aplica quando a solicitação tem preco_abertura preenchido (overrides
--    relacionados ao Infrastructure Floor, Fase 2.2 em diante) — overrides antigos, sem
--    preco_abertura, continuam exatamente como antes (nenhuma regra nova retroativa).
create or replace function public.fn_override_decisao()
returns trigger
language plpgsql
as $$
declare
  v_cidade_id uuid;
  v_max_discount numeric;
  v_min_autorizado numeric;
  v_pode_decidir boolean;
begin
  if old.status <> 'PENDENTE' then
    raise exception 'BLOCK: solicitação de override % já foi decidida (%) — decisões são imutáveis.', old.id, old.status;
  end if;

  if new.status <> old.status then
    v_pode_decidir := app.tem_perfil('DIRETOR', 'ADMINISTRADOR')
      or (app.tem_perfil('FINANCEIRO') and coalesce((select pode_aprovar_override_pricing from public.usuarios where id = auth.uid()), false));

    if not v_pode_decidir then
      raise exception 'REQUIRES_APPROVAL: decisão sobre override de preço exige DIRETOR/ADMINISTRADOR (ou FINANCEIRO com permissão explícita — seção 35 da Fase 2.2.1).';
    end if;

    if new.status = 'APROVADA' and new.preco_abertura is not null then
      select cidade_id into v_cidade_id from public.contratos where id = new.contrato_id;
      v_max_discount := app.get_infra_floor_param('MAX_OVERRIDE_DISCOUNT_PERCENT', v_cidade_id, null);
      v_min_autorizado := app.calcular_preco_minimo_autorizado(new.preco_abertura, v_max_discount);
      if v_min_autorizado is not null and new.preco_solicitado < v_min_autorizado then
        raise exception 'BLOCK: preço solicitado (R$%) está abaixo do limite máximo de desconto autorizável (% por cento de R$% = R$%) — nenhum perfil pode aprovar abaixo deste piso absoluto (seção 13 da Fase 2.2.1).',
          new.preco_solicitado, round(v_max_discount * 100, 2), new.preco_abertura, v_min_autorizado;
      end if;
    end if;

    new.decidido_por := auth.uid();
    new.decidido_em := now();
  end if;

  return new;
end;
$$;
comment on function public.fn_override_decisao() is 'Fase 2 (seção 49) + Fase 2.2.1 (seções 13/35): decisão sobre override de preço exige DIRETOR/ADMINISTRADOR, ou FINANCEIRO com usuarios.pode_aprovar_override_pricing=true. Para overrides do Infrastructure Floor (preco_abertura preenchido), aprovar abaixo de MINIMUM_AUTHORIZED_PRICE (abertura × (1 - limite máximo de desconto)) é bloqueado para QUALQUER perfil — piso absoluto. Decisões continuam imutáveis (old.status <> PENDENTE sempre bloqueia).';

-- 6) Redefinição do modo de composição MAX (seção 21) — ACHADO nesta fase: o modo 'MAX' já
--    existia desde a Fase 2.2, mas com semântica diferente da fórmula literal desta seção.
--    Antes: base = MAX(Floor, Mínimo Contratual), depois combinada com Revenue Share via
--    modelo_cobranca (SOMA soma; MAX tira o maior) — ex.: contrato 0006 (SOMA, floor
--    R$2.150, RS R$1.200) dava R$3.350 (base 2150 SOMADO com RS). A seção 21 desta fase
--    pede a fórmula literal TOTAL_PAYABLE = MAX(INFRASTRUCTURE_FLOOR, REVENUE_SHARE) —
--    SEM o Mínimo Contratual e SEM depender de modelo_cobranca. É uma mudança de
--    comportamento INTENCIONAL e explicitamente instruída por esta fase (não uma regressão
--    silenciosa): o modo 'MAX' passa a ser tratado como um caminho especial, igual a
--    FLOOR_ONLY/MINIMUM_ONLY já eram desde a Fase 2.2, em vez de cair no ramo genérico
--    combinado com modelo_cobranca. Documentado no relatório de entrega (o teste
--    REG-11-MAX/TESTE-20 da Fase 2.2 é reexecutado com o valor NOVO, não o antigo, e a
--    divergência fica explicada, não escondida).
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

  v_floor_data := app.calculate_infrastructure_floor_for_contract(p_contrato_id, p_pop_id, p_pricing_version);
  v_floor := (v_floor_data ->> 'floor_price')::numeric;
  v_minimo := app.calcular_minimo_contratual(p_contrato_id);
  v_revenue_share := round(coalesce(p_faturamento_parceiro, 0) * coalesce(v_config.percentual_revenue_share, 0), 2);

  if v_config.infra_floor_composition_mode = 'FLOOR_ONLY' then
    v_total_payable := v_floor;
  elsif v_config.infra_floor_composition_mode = 'MINIMUM_ONLY' then
    v_total_payable := app.calcular_cobranca_hibrida(p_contrato_id, p_faturamento_parceiro);
  elsif v_config.infra_floor_composition_mode = 'MAX' then
    -- Fase 2.2.1 (seção 21): fórmula literal, sem Mínimo Contratual, sem depender de
    -- modelo_cobranca — "Default recomendado: MAX(Infrastructure Floor, Revenue Share)".
    v_total_payable := greatest(v_floor, v_revenue_share);
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
comment on function app.get_economia_com_piso(uuid, numeric, uuid, text) is 'Fase 2.2 (seção 17/30) + Fase 2.2.1 (seções 16/21): comparação econômica completa. Infrastructure Floor inclui o componente PON. Composição: FLOOR_ONLY (só floor, ignora mínimo e RS), MINIMUM_ONLY (100% pré-Fase-2.2), MAX (Fase 2.2.1, seção 21: MAX(Floor,RevenueShare) literal, ignora mínimo e modelo_cobranca — mudança intencional de comportamento vs. Fase 2.2, ver relatório), FLOOR_AS_MINIMUM/SUM (combinam com modelo_cobranca, inalterados desde a Fase 2.2). Rede de proteção "enforced" inalterada.';

-- 7) MAX como composição default RECOMENDADA para contratos novos (seção 21) — só o
--    DEFAULT da coluna muda; nenhum contrato existente (cujo valor já foi gravado
--    explicitamente na Fase 2.2, ex.: FLOOR_AS_MINIMUM no contrato 0006) é alterado por
--    este ALTER.
alter table public.contrato_pricing_config alter column infra_floor_composition_mode set default 'MAX';
comment on column public.contrato_pricing_config.infra_floor_composition_mode is 'Fase 2.2 (seção 32/33) + Fase 2.2.1 (seção 21): como compor Infrastructure Floor (F) × Minimum Contractual Fee (M). Default MAX para contratos NOVOS a partir desta fase (seção 21: "Default recomendado: MAX" = MAX(Infrastructure Floor, Revenue Share) via FLOOR_ONLY combinado com o motor SOMA/MAX existente) — contratos já configurados explicitamente (ex.: FLOOR_AS_MINIMUM) mantêm seu modo, nenhuma migração de dado retroativa. Nenhuma modalidade foi removida (FLOOR_ONLY/MINIMUM_ONLY/FLOOR_AS_MINIMUM/SUM/MAX todas continuam disponíveis, seção 21/37/38).';
