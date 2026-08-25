-- OptiMon — Fase 2.1
-- Seções 5-8: Pricing Engine REAL do Cenário 2 (Porta PON + Revenue Share). Bug real
-- confirmado antes desta migration: public.pricing_quote() para qualquer contrato que
-- não fosse DARK_FIBER apenas LIA contrato_pricing_config.preco_minimo_porta/
-- preco_recomendado_porta/preco_premium_porta — colunas que nunca são preenchidas por
-- nenhuma função (confirmado: contrato 0006 do seed Fase 2 tem as três NULL). Ou seja,
-- "quote" de um contrato Porta PON sempre devolvia preço nulo. Esta migration cria o
-- motor de cálculo de verdade, espelhando a mesma disciplina já usada no Dark Fiber
-- (app.calcular_preco_minimo/recomendado/premium_dark_fiber, Fase 2 seções 11-13):
-- custo incremental real, margem/risco parametrizáveis (mesmas colunas de
-- contrato_pricing_config já usadas pelo Dark Fiber — reaproveitadas, não duplicadas),
-- escassez de capacidade, exclusividade, múltiplos POPs, capacidade reservada.

-- app.get_disponibilidade_porta_pon_cidade(): fração de capacidade de assinantes ainda
-- disponível nas portas PON de uma cidade (análogo a get_disponibilidade_fibra_cidade,
-- mas medindo capacidade de porta, não fibra livre) — base para o fator de escassez do
-- Cenário 2 (reaproveita app.get_capacity_scarcity_factor, seção 14, já genérica).
create or replace function app.get_disponibilidade_porta_pon_cidade(p_cidade_id uuid)
returns numeric
language sql
stable
as $$
  select case when coalesce(sum(p.capacidade_max_assinantes), 0) = 0 then 0
    else round(sum(p.capacidade_disponivel)::numeric / sum(p.capacidade_max_assinantes), 4)
  end
  from public.infra_portas_pon p
  join public.infra_pops pop on pop.id = p.pop_id
  where pop.cidade_id = p_cidade_id;
$$;
comment on function app.get_disponibilidade_porta_pon_cidade(uuid) is 'Seção 14 aplicada ao Cenário 2: fração (0..1) da capacidade de assinantes ainda disponível nas portas PON da cidade — usada por app.calcular_preco_recomendado_porta_pon() via app.get_capacity_scarcity_factor().';

-- Multiplicadores comerciais do Cenário 2. Mesma disciplina da seção 65 já aplicada ao
-- Dark Fiber: não inventamos números novos. RECOMENDADO/PREMIUM herdam o mesmo valor já
-- aprovado para o Dark Fiber (1.20/1.50, Fase 1) — ainda não há uma revisão comercial
-- específica desses multiplicadores para Cenário 2; sinalizado no relatório da Fase 2.1
-- para o Financeiro/Diretor revisar. Os três bônus de premium nascem NEUTROS (1.00) —
-- mesmo padrão do Dark Fiber (DARK_FIBER_PREMIO_EXCLUSIVIDADE/MULTIPOP, Fase 2).
insert into public.pricing_parametros (chave, valor, unidade, descricao) values
  ('PORTA_PON_MULTIPLICADOR_RECOMENDADO', 1.20, 'x', 'Preço recomendado (Cenário 2) = mínimo × este fator × escassez. Valor herdado do multiplicador equivalente do Dark Fiber (DARK_FIBER_MULTIPLICADOR_RECOMENDADO) — sem revisão comercial específica para Cenário 2 ainda (seção 65/Fase 2.1).'),
  ('PORTA_PON_MULTIPLICADOR_PREMIUM', 1.50, 'x', 'Preço premium (Cenário 2) = recomendado × este fator × bônus. Valor herdado do multiplicador equivalente do Dark Fiber — sem revisão comercial específica para Cenário 2 ainda (seção 65/Fase 2.1).'),
  ('PORTA_PON_PREMIO_EXCLUSIVIDADE', 1.00, 'x', 'PARAMETRIZÁVEL (seção 8/65) — multiplicador extra do preço premium quando o contrato tem exclusividade. 1.00 = sem efeito até o negócio definir.'),
  ('PORTA_PON_PREMIO_MULTIPOP', 1.00, 'x', 'PARAMETRIZÁVEL (seção 8/65) — multiplicador extra do preço premium por múltiplos POPs. 1.00 = sem efeito até o negócio definir.'),
  ('PORTA_PON_PREMIO_CAPACIDADE_RESERVADA', 1.00, 'x', 'PARAMETRIZÁVEL (seção 8/65) — multiplicador extra do preço premium quando o contrato tem portas em situação RESERVADA (capacidade reservada além da ativa). 1.00 = sem efeito até o negócio definir.')
on conflict (chave) do nothing;

-- Seção 6: PREÇO MÍNIMO — recuperação do custo incremental, margem mínima configurada,
-- proteção contra operação deficitária (piso comercial por porta × portas contratadas,
-- nunca abaixo do custo real) e risco. A viabilidade mínima do PARCEIRO (seção 35/57) é
-- verificada à parte por app.avaliar_viabilidade_parceiro()/app.classificar_negocio() —
-- não entra como termo desta fórmula porque depende do faturamento simulado do parceiro
-- (ARPU × clientes), que não existe ainda neste ponto (preço mínimo é calculado ANTES da
-- simulação de clientes) — documentado explicitamente, não inventado silenciosamente.
create or replace function app.calcular_preco_minimo_porta_pon(p_contrato_id uuid)
returns numeric
language plpgsql
stable
as $$
declare
  v_config record;
  v_portas integer;
  v_piso_porta numeric;
  v_base numeric;
begin
  select margem_minima_percent, fator_risco_percent into v_config
  from public.contrato_pricing_config where contrato_id = p_contrato_id;

  v_portas := greatest(coalesce(app.get_portas_contratadas_count(p_contrato_id, false), 0), 1);

  select valor into v_piso_porta from public.pricing_parametros
  where chave = 'HIBRIDO_MENSALIDADE_MINIMA_PORTA_PADRAO' and (vigente_ate is null or vigente_ate >= current_date);

  v_base := greatest(
    coalesce(app.get_custo_base_precificacao(p_contrato_id), 0),
    coalesce(v_piso_porta, 0) * v_portas
  );

  return round(v_base * (1 + coalesce(v_config.margem_minima_percent, 0) + coalesce(v_config.fator_risco_percent, 0)), 2);
end;
$$;
comment on function app.calcular_preco_minimo_porta_pon(uuid) is 'PREÇO MÍNIMO — Cenário 2 (seção 6, Fase 2.1) = MAX(custo incremental+alocado do contrato, piso comercial por porta × portas contratadas) × (1 + margem mínima + risco). Motor de cálculo de verdade — não lê mais contrato_pricing_config.preco_minimo_porta (coluna nunca preenchida).';

-- Seção 7: PREÇO RECOMENDADO — melhor equilíbrio entre remuneração OptiMon, crescimento/
-- margem do parceiro (a rampa de maturação já reduz a cobrança nos primeiros meses,
-- dando fôlego ao parceiro — seção 25) e ocupação da infraestrutura (fator de escassez:
-- quanto menos capacidade de porta PON sobra na cidade, maior o valor econômico do que
-- resta). Sempre > mínimo (multiplicador e fator de escassez sempre >= 1).
create or replace function app.calcular_preco_recomendado_porta_pon(p_contrato_id uuid)
returns numeric
language plpgsql
stable
as $$
declare
  v_minimo numeric;
  v_multiplicador numeric;
  v_cidade_id uuid;
  v_disponibilidade numeric;
  v_fator_escassez numeric;
begin
  v_minimo := app.calcular_preco_minimo_porta_pon(p_contrato_id);

  select valor into v_multiplicador from public.pricing_parametros
  where chave = 'PORTA_PON_MULTIPLICADOR_RECOMENDADO' and (vigente_ate is null or vigente_ate >= current_date);

  select cidade_id into v_cidade_id from public.contratos where id = p_contrato_id;
  v_disponibilidade := app.get_disponibilidade_porta_pon_cidade(v_cidade_id);
  v_fator_escassez := coalesce(app.get_capacity_scarcity_factor(v_disponibilidade), 1);

  return round(v_minimo * coalesce(v_multiplicador, 1) * v_fator_escassez, 2);
end;
$$;
comment on function app.calcular_preco_recomendado_porta_pon(uuid) is 'PREÇO RECOMENDADO — Cenário 2 (seção 7, Fase 2.1) = preço mínimo × multiplicador comercial × fator de escassez de capacidade de porta PON na cidade. "Por que foi escolhido" é exatamente essa composição — nunca um número solto.';

-- Seção 8: PREÇO PREMIUM — exclusividade, capacidade reservada, escassez (já embutida
-- via preço recomendado), múltiplos POPs, prazo/risco (via margem/risco já compostos no
-- mínimo). NUNCA "recomendado × 2" fixo — cada bônus é parametrizável, default neutro.
create or replace function app.calcular_preco_premium_porta_pon(p_contrato_id uuid)
returns numeric
language plpgsql
stable
as $$
declare
  v_recomendado numeric;
  v_multiplicador_premium numeric;
  v_premio_exclusividade numeric;
  v_premio_multipop numeric;
  v_premio_reservada numeric;
  v_exclusivo boolean;
  v_qtd_pops integer;
  v_tem_reservada boolean;
begin
  v_recomendado := app.calcular_preco_recomendado_porta_pon(p_contrato_id);

  select valor into v_multiplicador_premium from public.pricing_parametros
  where chave = 'PORTA_PON_MULTIPLICADOR_PREMIUM' and (vigente_ate is null or vigente_ate >= current_date);
  select valor into v_premio_exclusividade from public.pricing_parametros where chave = 'PORTA_PON_PREMIO_EXCLUSIVIDADE';
  select valor into v_premio_multipop from public.pricing_parametros where chave = 'PORTA_PON_PREMIO_MULTIPOP';
  select valor into v_premio_reservada from public.pricing_parametros where chave = 'PORTA_PON_PREMIO_CAPACIDADE_RESERVADA';

  select coalesce(exclusividade_comercial, false) into v_exclusivo
  from public.contrato_regras where contrato_id = p_contrato_id;

  select count(distinct p.pop_id) into v_qtd_pops
  from public.contrato_fibras cf
  join public.infra_portas_pon p on p.id = cf.porta_pon_id
  where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null;

  select exists(
    select 1 from public.contrato_fibras cf
    join public.infra_portas_pon p on p.id = cf.porta_pon_id
    where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null and p.situacao_comercial = 'RESERVADA'
  ) into v_tem_reservada;

  return round(
    v_recomendado
    * coalesce(v_multiplicador_premium, 1)
    * (case when coalesce(v_exclusivo, false) then coalesce(v_premio_exclusividade, 1) else 1 end)
    * (case when coalesce(v_qtd_pops, 0) > 1 then coalesce(v_premio_multipop, 1) else 1 end)
    * (case when coalesce(v_tem_reservada, false) then coalesce(v_premio_reservada, 1) else 1 end)
  , 2);
end;
$$;
comment on function app.calcular_preco_premium_porta_pon(uuid) is 'PREÇO PREMIUM — Cenário 2 (seção 8, Fase 2.1) = recomendado × multiplicador comercial × bônus exclusividade × bônus multi-POP × bônus capacidade reservada. Todos os bônus parametrizáveis (pricing_parametros), nunca "recomendado × 2".';

-- public.pricing_quote() (API, seção 50): corrigido para chamar o motor real do
-- Cenário 2 em vez de ler colunas sempre nulas. Comportamento do Dark Fiber inalterado.
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
    v_minimo := app.calcular_preco_minimo_porta_pon(p_contrato_id);
    v_recomendado := app.calcular_preco_recomendado_porta_pon(p_contrato_id);
    v_premium := app.calcular_preco_premium_porta_pon(p_contrato_id);
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
comment on function public.pricing_quote(uuid, numeric) is 'POST /api/pricing/quote — preço mínimo/recomendado/premium + governança (seções 36, 49). Corrigido na Fase 2.1 (seção 5): Cenário 2 agora usa app.calcular_preco_minimo/recomendado/premium_porta_pon (motor de cálculo real) em vez de ler contrato_pricing_config.preco_minimo_porta/recomendado/premium (colunas nunca preenchidas por nenhuma função — sempre devolviam null).';
