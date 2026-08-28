-- OptiMon — Fase 3, seção 4-6: CORREÇÃO CRÍTICA — "Preço Proposto" passa a ser
-- o valor efetivamente usado em toda a proposta e no contrato gerado a partir
-- dela, em vez de só alimentar um rótulo de governança.
--
-- CAUSA RAIZ (achada por investigação de código, não assumida — dois bugs
-- reais e independentes, mesma raiz conceitual):
--
-- 1) app.simular_precificacao_completa (20260831090100_phase_deploy_02_calculate_pricing_full.sql)
--    já usava `preco_proposto` para classificar a régua (desconto/governança),
--    mas o campo `total_payable` — o valor que alimenta receita/ROI/payback na
--    tela de simulação e o snapshot congelado da proposta — SEMPRE foi
--    calculado por `composicao_mode` (piso × revenue share, herdado da Fase
--    2.2, anterior ao conceito de "preço proposto" da Fase 2.4), nunca a
--    partir do preço realmente negociado. Resultado: digitar R$ 2.700 numa
--    proposta cujo piso/revenue-share compõem R$ 2.020 fazia a régua mostrar
--    "Liberado" mas a receita projetada continuava usando R$ 2.020 — o
--    comercial via um número, o sistema usava outro.
--
-- 2) app.gerar_contrato_de_proposta (20260913090400_phase_2_5_05_modelos_contrato_geracao_automatica.sql)
--    grava `contrato_pricing_config.mensalidade_minima_porta` (o mínimo
--    Take-or-Pay real do contrato — ver app.calcular_minimo_contratual) a
--    partir de `snapshot->>'recommended'` (o preço RECOMENDADO da régua),
--    nunca do preço efetivamente negociado/aprovado na proposta. Mesmo depois
--    de corrigir o item 1 acima, um contrato gerado a partir de uma proposta
--    aprovada a R$ 2.700 continuaria cobrando o mínimo mensal de R$ 2.400
--    (recomendado) — ou, na direção oposta, um desconto aprovado por um
--    DIRETOR (abaixo do recomendado, dentro do limite de 50%) seria ignorado
--    e o contrato cobraria o recomendado cheio mesmo assim.
--
-- Nenhuma tabela nova, nenhuma coluna nova, nenhuma policy alterada — as duas
-- funções continuam com a MESMA assinatura (create or replace), então nenhum
-- outro caller precisa mudar. `composicao_mode` continua calculado e exposto
-- (renomeado para `piso_garantido_composicao` dentro do resultado, nunca mais
-- como `total_payable`) para quem hoje usa esse número como referência de
-- garantia mínima de infraestrutura — só deixa de ser confundido com "o preço
-- da proposta".

create or replace function app.simular_precificacao_completa(p_params jsonb)
returns jsonb
language plpgsql
stable
as $$
declare
  v_cidade_id uuid := nullif(p_params->>'cidade_id', '')::uuid;
  v_pop_id uuid := nullif(p_params->>'pop_id', '')::uuid;
  v_pricing_version text := nullif(p_params->>'pricing_version', '');
  v_clientes integer := coalesce((p_params->>'clientes')::integer, 0);
  v_arpu numeric := coalesce((p_params->>'arpu')::numeric, 0);
  v_faturamento numeric := nullif(p_params->>'faturamento', '')::numeric;
  v_revenue_share_pct numeric := coalesce((p_params->>'revenue_share_pct')::numeric, 0.12);
  v_composicao_mode text := coalesce(p_params->>'composicao_mode', 'MAX');
  v_preco_proposto numeric := nullif(p_params->>'preco_proposto', '')::numeric;
  v_minimo_contratual numeric := coalesce((p_params->>'minimo_contratual')::numeric, 0);
  v_pons_count integer := nullif(p_params->>'pons_count', '')::integer;

  v_floor jsonb;
  v_abertura numeric;
  v_recomendado numeric;
  v_piso numeric;
  v_max_discount numeric;
  v_min_autorizado numeric;
  v_base numeric;
  v_piso_garantido_composicao numeric;
  v_total_payable numeric;
  v_receita_parceiro numeric;
  v_desconto jsonb;
  v_governanca jsonb;
begin
  if v_cidade_id is null then
    raise exception 'cidade_id é obrigatório para calcular a precificação (seção 32).';
  end if;

  if v_pons_count is null then
    v_pons_count := app.pons_necessarias_para_clientes(v_clientes, v_cidade_id, v_pricing_version);
  end if;

  v_floor := app.calculate_infrastructure_floor(v_cidade_id, v_pop_id, v_pricing_version, v_pons_count);
  v_abertura := (v_floor ->> 'opening_price')::numeric;
  v_recomendado := (v_floor ->> 'recommended_price')::numeric;
  v_piso := (v_floor ->> 'floor_price')::numeric;

  -- Sem preço proposto explícito (tela ainda não negociou), a régua usa o RECOMENDADO
  -- como referência — nunca assume ABERTURA nem PISO por padrão.
  if v_preco_proposto is null then
    v_preco_proposto := v_recomendado;
  end if;

  v_max_discount := app.get_infra_floor_param('MAX_OVERRIDE_DISCOUNT_PERCENT', v_cidade_id, v_pricing_version);
  v_min_autorizado := app.calcular_preco_minimo_autorizado(v_abertura, v_max_discount);
  v_desconto := app.calcular_desconto_comercial(v_abertura, v_preco_proposto, v_recomendado);
  v_governanca := jsonb_build_object(
    'tri_state', app.check_infrastructure_floor_governance(v_preco_proposto, v_recomendado, v_piso),
    'por_papel', app.check_infrastructure_floor_governance_role(v_preco_proposto, v_abertura, v_recomendado, v_piso, v_max_discount)
  );

  if v_faturamento is null then
    v_faturamento := round(v_clientes * v_arpu, 2);
  end if;

  -- FASE 3 (seção 4/15): "toda a proposta" (receita, ROI, payback, e o que o
  -- contrato gerado a partir dela vai cobrar) usa EXATAMENTE o preço
  -- proposto — nunca um valor recalculado por composição piso/revenue-share.
  -- A composição antiga continua calculada como referência de garantia
  -- mínima de infraestrutura (Take-or-Pay técnico), exposta à parte, mas
  -- nunca mais confundida com "o preço da proposta".
  declare
    v_revenue_share numeric := round(coalesce(v_faturamento, 0) * coalesce(v_revenue_share_pct, 0), 2);
  begin
    if v_composicao_mode = 'FLOOR_ONLY' then
      v_piso_garantido_composicao := v_piso;
    elsif v_composicao_mode = 'MINIMUM_ONLY' then
      v_piso_garantido_composicao := v_minimo_contratual;
    elsif v_composicao_mode = 'MAX' then
      v_piso_garantido_composicao := greatest(v_piso, v_revenue_share);
    elsif v_composicao_mode = 'SUM' then
      v_piso_garantido_composicao := v_piso + v_minimo_contratual + v_revenue_share;
    else
      v_base := app.calcular_composicao_piso_minimo(v_composicao_mode::infra_floor_composition_mode, v_piso, v_minimo_contratual);
      v_piso_garantido_composicao := v_base;
    end if;

    v_total_payable := v_preco_proposto;
    v_receita_parceiro := coalesce(v_faturamento, 0) - v_total_payable;

    return jsonb_build_object(
      'cidade_id', v_cidade_id,
      'pop_id', v_pop_id,
      'pricing_version', coalesce(v_pricing_version, v_floor->>'pricing_version'),
      'clientes', v_clientes,
      'pons_count', v_pons_count,
      'arpu', v_arpu,
      'faturamento', v_faturamento,
      'floor', v_piso,
      'recommended', v_recomendado,
      'opening', v_abertura,
      'preco_proposto', v_preco_proposto,
      'revenue_share_pct', v_revenue_share_pct,
      'revenue_share_value', v_revenue_share,
      'composicao_mode', v_composicao_mode,
      'piso_garantido_composicao', round(v_piso_garantido_composicao, 2),
      'total_payable', round(v_total_payable, 2),
      'partner_revenue', round(v_receita_parceiro, 2),
      'partner_margin', case when coalesce(v_faturamento, 0) > 0 then round(v_receita_parceiro / v_faturamento, 4) else null end,
      'discount', v_desconto,
      'max_override_discount_percent', v_max_discount,
      'preco_minimo_autorizado', v_min_autorizado,
      'governance_status', v_governanca
    );
  end;
end;
$$;
comment on function app.simular_precificacao_completa(jsonb) is 'Pricing Engine centralizado (seção 32). FASE 3 (seção 4-6): total_payable agora é sempre o preco_proposto (o valor comercial efetivamente pretendido) — nunca mais um valor recalculado por composicao_mode (piso × revenue share). A composição antiga continua disponível em piso_garantido_composicao, como referência de garantia mínima de infraestrutura, nunca mais confundida com o preço da proposta.';

-- ============================================================================
-- app.gerar_contrato_de_proposta: o mínimo mensal do contrato passa a vir do
-- preço efetivamente negociado/aprovado na proposta, nunca do "recomendado".
-- COALESCE preserva a compatibilidade com propostas já existentes (criadas
-- antes desta correção): preco_proposto sempre foi gravado corretamente no
-- snapshot desde a Fase 2.4, então a ordem de preferência é
-- preco_proposto → total_payable → recommended (só cai no recomendado se o
-- snapshot for de uma versão muito antiga sem nenhum dos dois campos).
-- ============================================================================
create or replace function app.gerar_contrato_de_proposta(p_proposta_id uuid, p_prazo_minimo_excecao boolean default false, p_motivo_excecao_prazo text default null)
returns public.contratos
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prop public.propostas_comerciais;
  v_sim public.simulacoes;
  v_contrato public.contratos;
  v_numero text;
  v_modelo contrato_modelo;
  v_prazo integer;
  v_snapshot jsonb;
  v_revenue_share numeric;
  v_faturamento numeric;
  v_preco_negociado numeric;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem gerar contrato a partir de uma proposta.';
  end if;

  select * into v_prop from public.propostas_comerciais where id = p_proposta_id;
  if v_prop.id is null then
    raise exception 'NAO_ENCONTRADA: proposta % não encontrada ou sem permissão de leitura.', p_proposta_id;
  end if;

  if v_prop.status <> 'ASSINADA' then
    raise exception 'STATUS_INVALIDO: só é possível gerar contrato a partir de uma proposta ASSINADA (seção 52) — status atual: %.', v_prop.status;
  end if;

  if v_prop.contrato_id is not null then
    raise exception 'JA_GERADO: esta proposta já gerou o contrato % — use aditivo para alterações (seção 39), nunca gerar de novo.', v_prop.contrato_id;
  end if;

  if v_prop.parceiro_id is null or v_prop.cidade_id is null then
    raise exception 'DADOS_INCOMPLETOS: proposta sem parceiro_id/cidade_id — não é possível gerar contrato.';
  end if;

  select * into v_sim from public.simulacoes where id = v_prop.simulacao_id;
  v_snapshot := v_prop.snapshot;

  v_modelo := coalesce(v_sim.modelo, 'HIBRIDO_REVENUE_SHARE'::contrato_modelo);
  v_prazo := coalesce((v_snapshot->>'prazo_meses')::integer, v_sim.prazo_meses, 48);
  v_revenue_share := (v_snapshot->>'revenue_share_pct')::numeric;
  v_faturamento := (v_snapshot->>'faturamento')::numeric;
  v_preco_negociado := coalesce(
    nullif(v_snapshot->>'preco_proposto', '')::numeric,
    nullif(v_snapshot->>'total_payable', '')::numeric,
    nullif(v_snapshot->>'recommended', '')::numeric
  );

  if v_prazo < 48 and not p_prazo_minimo_excecao then
    raise exception 'PRAZO_MINIMO: contrato mínimo é de 48 meses (seção 32) — prazo da proposta é % meses; use uma exceção autorizada para prosseguir.', v_prazo;
  end if;

  if p_prazo_minimo_excecao and (p_motivo_excecao_prazo is null or trim(p_motivo_excecao_prazo) = '') then
    raise exception 'MOTIVO_OBRIGATORIO: prazo abaixo de 48 meses exige motivo da exceção (seção 32).';
  end if;

  v_numero := 'CONTR-' || to_char(now(), 'YYYYMMDD') || '-' || substr(gen_random_uuid()::text, 1, 8);

  insert into public.contratos (
    numero, parceiro_id, cidade_id, modelo, status, prazo_meses,
    prazo_minimo_excecao, aprovado_por, aprovado_em
  ) values (
    v_numero, v_prop.parceiro_id, v_prop.cidade_id, v_modelo, 'RASCUNHO', v_prazo,
    p_prazo_minimo_excecao,
    case when p_prazo_minimo_excecao then auth.uid() else null end,
    case when p_prazo_minimo_excecao then now() else null end
  )
  returning * into v_contrato;

  insert into public.contrato_pricing_config (contrato_id, percentual_revenue_share, mensalidade_minima_porta)
  values (v_contrato.id, v_revenue_share, v_preco_negociado);

  insert into public.contrato_regras (contrato_id)
  values (v_contrato.id);

  insert into public.contrato_versions (contrato_id, versao, motivo, snapshot, criado_por)
  values (v_contrato.id, 1, 'Geração automática a partir da proposta ' || v_prop.numero || ' (Fase 2.5, seção 30).', v_snapshot, auth.uid());

  update public.propostas_comerciais
     set contrato_id = v_contrato.id,
         status = 'CONTRATO_GERADO'
   where id = v_prop.id;

  perform app.registrar_auditoria_semantica('contratos', v_contrato.id, 'CONTRACT_GENERATE',
    'Gerado automaticamente a partir da proposta ' || v_prop.numero,
    null, to_jsonb(v_contrato));

  return v_contrato;
end;
$$;

comment on function app.gerar_contrato_de_proposta(uuid, boolean, text) is 'Fase 2.5 seções 30-31/52. FASE 3 (seção 4/15): mensalidade_minima_porta agora vem do preço efetivamente negociado/aprovado na proposta (preco_proposto), nunca do recomendado — um desconto aprovado por DIRETOR ou um valor acima da abertura passam a valer de verdade no contrato gerado. SECURITY DEFINER (com checagem de RBAC explícita no início): escreve em duas tabelas com policies diferentes (ver comentário anterior desta função, preservado).';
