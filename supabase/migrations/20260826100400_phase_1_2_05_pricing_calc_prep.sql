-- OptiMon — Fase 1.2
-- Seções 2, 6, 21: preparação de cálculo para o Pricing Engine da Fase 2 — só o que os
-- testes obrigatórios desta fase exigem (fórmula SOMA/MAX do mínimo + revenue share, e o
-- mínimo calculado sobre portas contratadas). NÃO é o Pricing Engine completo (dark
-- fiber, ROI, payback, rampas em R$, simulação de cenários — isso continua na Fase 2,
-- seção 32).

-- app.get_portas_contratadas_count(): conta portas do contrato por situação comercial —
-- base para o mínimo "por porta" (seção 6/7).
create or replace function app.get_portas_contratadas_count(p_contrato_id uuid, p_somente_ativas boolean default false)
returns integer
language sql
stable
as $$
  select count(*)::integer
  from public.infra_portas_pon p
  join public.contrato_fibras cf on cf.porta_pon_id = p.id
  where cf.contrato_id = p_contrato_id
    and cf.desvinculado_em is null
    and p.situacao_comercial = any (
      case when p_somente_ativas then array['ATIVA']::public.porta_pon_situacao_comercial[]
           else array['RESERVADA','ATIVA']::public.porta_pon_situacao_comercial[]
      end
    );
$$;

comment on function app.get_portas_contratadas_count(uuid, boolean) is 'Conta portas RESERVADAS+ATIVAS (contratadas) do contrato, ou só ATIVAS quando p_somente_ativas=true — base do mínimo "por porta" (seção 6).';

-- app.calcular_minimo_contratual() (seção 6): PORTA CONTRATADA = CAPACIDADE RESERVADA
-- PARA O PARCEIRO — a reserva não é gratuita por padrão (cobranca_portas_reservadas=true
-- cobra sobre TODAS as portas contratadas, não só as ativas). Nunca lógica fixa: lê tudo
-- de contrato_pricing_config, que é sempre parametrizável por contrato.
create or replace function app.calcular_minimo_contratual(p_contrato_id uuid)
returns numeric
language plpgsql
stable
as $$
declare
  v_config record;
  v_qtd_portas integer;
begin
  select modelo_minimo, mensalidade_minima_porta, cobranca_portas_reservadas
  into v_config
  from public.contrato_pricing_config
  where contrato_id = p_contrato_id;

  if not found then
    return 0;
  end if;

  if v_config.modelo_minimo = 'GLOBAL' then
    return coalesce(v_config.mensalidade_minima_porta, 0);
  end if;

  -- POR_PORTA: cobranca_portas_reservadas=true (padrão) considera TODAS as portas
  -- contratadas (reservadas + ativas) — exemplo da seção 6: 5 portas × R$1.000 = R$5.000
  -- mesmo com só 2 ativas. Se false, cobra só pelas portas efetivamente ATIVAS.
  v_qtd_portas := app.get_portas_contratadas_count(p_contrato_id, not coalesce(v_config.cobranca_portas_reservadas, true));

  return coalesce(v_config.mensalidade_minima_porta, 0) * v_qtd_portas;
end;
$$;

comment on function app.calcular_minimo_contratual(uuid) is 'Mínimo financeiro do contrato (seção 6): GLOBAL = mensalidade_minima_porta fixo; POR_PORTA = mensalidade_minima_porta × qtd. de portas (todas as contratadas se cobranca_portas_reservadas=true, só as ativas se false). Preparação para a Fase 2 — não inclui rampa/reajuste/take-or-pay ainda.';

-- app.calcular_cobranca_hibrida() (seções 2/3): fórmula SOMA (padrão) ou MAX, conforme
-- contrato_pricing_config.modelo_cobranca — nunca fixa no código. p_faturamento é o valor
-- já apurado (medição/HubSoft, Fase 4+); aqui só a fórmula, sem apuração de faturamento.
create or replace function app.calcular_cobranca_hibrida(p_contrato_id uuid, p_faturamento numeric)
returns numeric
language plpgsql
stable
as $$
declare
  v_modelo public.modelo_cobranca;
  v_percentual numeric;
  v_minimo numeric;
  v_share numeric;
begin
  select modelo_cobranca, percentual_revenue_share
  into v_modelo, v_percentual
  from public.contrato_pricing_config
  where contrato_id = p_contrato_id;

  if not found then
    raise exception 'Contrato % não possui contrato_pricing_config cadastrado.', p_contrato_id;
  end if;

  v_minimo := app.calcular_minimo_contratual(p_contrato_id);
  v_share := coalesce(p_faturamento, 0) * coalesce(v_percentual, 0);

  if v_modelo = 'SOMA' then
    return v_minimo + v_share;
  else
    return greatest(v_minimo, v_share);
  end if;
end;
$$;

comment on function app.calcular_cobranca_hibrida(uuid, numeric) is 'COBRANÇA = MÍNIMO + REVENUE SHARE (modelo SOMA, padrão a partir da Fase 1.2) ou MAX(MÍNIMO, REVENUE SHARE) (modelo MAX) — seções 2/3. Testes 1/2/3 desta fase validam exatamente esta função contra os exemplos literais do prompt.';
