-- OptiMon — Fase 3, item 3.3: Dashboard executivo (KPIs completos + gráfico de
-- receita acumulada em cenários).
--
-- CONTEXTO (investigação prévia, seção 3/49 do prompt): o dashboard atual
-- (app.dashboard_contratual, Fase 2.5.1/2.5.3) já cobre boa parte dos KPIs pedidos, mas
-- (a) várias chaves já calculadas nunca chegam ao frontend, (b) faltam duas contagens de
-- propostas (abertas/aprovadas), (c) não existe nenhum agregado de capacidade em nível de
-- portfólio (só por cidade, via CityDetail), e (d) não existe nenhum gráfico de receita
-- acumulada em cenários (conservador/recomendado/otimista) — o único motor de
-- horizonte/ROI/payback existente (app.simular_tabela_horizontes, app.calcular_roi,
-- app.calcular_payback) opera sobre UMA simulação isolada, nunca sobre o portfólio real de
-- contratos ativos.
--
-- LIMITAÇÃO HONESTA (documentada aqui e no relatório final, nunca escondida): não existe
-- ainda medição real de faturamento mês a mês (medicoes_mensais está schema-only — a
-- alimentação automática depende de integração com HubSoft/financeiro, explicitamente
-- adiada pelo usuário para uma fase futura). Por isso "receita acumulada" aqui é uma
-- PROJEÇÃO estimada a partir da mensalidade contratada hoje (contrato_pricing_config,
-- já com o preço efetivamente negociado desde a correção da seção 3.1) e de taxas de
-- crescimento mensal parametrizadas — nunca faturamento medido de fato. Isso é sinalizado
-- explicitamente no jsonb retornado (campo 'observacao') e deve ser marcado como estimativa
-- na UI, nunca apresentado como número medido.

-- ============================================================================
-- 1) app.dashboard_contratual — acrescenta contagens de propostas que faltavam
--    (mesma assinatura, só mais duas chaves no jsonb — nenhum chamador existente quebra).
-- ============================================================================
create or replace function app.dashboard_contratual()
returns jsonb
language sql
stable
security invoker
as $$
  select jsonb_build_object(
    'contratos_ativos', (select count(*) from public.contratos where status = 'ATIVO'),
    'propostas_aguardando_aprovacao', (select count(*) from public.propostas_comerciais where status = 'EM_APROVACAO'),
    'propostas_aguardando_assinatura', (select count(*) from public.propostas_comerciais where status = 'EM_ASSINATURA'),
    'propostas_pendentes', (
      select count(*) from public.propostas_comerciais where status in ('EM_APROVACAO', 'EM_ASSINATURA')
    ),
    -- Fase 3 (item 3.3): "propostas abertas" = todo status que ainda não chegou num
    -- estado terminal (ACEITA/RECUSADA/EXPIRADA/CANCELADA/CONTRATO_GERADO) — nunca
    -- confundir com propostas_pendentes (só aprovação+assinatura).
    'propostas_abertas', (
      select count(*) from public.propostas_comerciais
      where status not in ('ACEITA', 'RECUSADA', 'EXPIRADA', 'CANCELADA', 'CONTRATO_GERADO')
    ),
    'propostas_aprovadas', (select count(*) from public.propostas_comerciais where status = 'APROVADA'),
    'contratos_aguardando_assinatura', (
      select count(distinct contrato_id) from public.signature_envelopes
      where tipo_documento = 'CONTRATO' and status in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
    ),
    'contratos_pendentes', (
      select count(distinct contrato_id) from public.signature_envelopes
      where tipo_documento = 'CONTRATO' and status in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
    ),
    'contratos_proximos_vencimento', (
      select count(*) from public.contratos
      where status = 'ATIVO' and data_fim_prevista is not null and data_fim_prevista <= current_date + interval '60 days'
    ),
    'reajustes_pendentes', (select count(*) from public.reajustes where status = 'PENDENTE'),
    'valor_mensal_contratado', (
      select coalesce(sum(cpc.mensalidade_minima_porta), 0)
      from public.contratos c join public.contrato_pricing_config cpc on cpc.contrato_id = c.id
      where c.status = 'ATIVO'
    ),
    'pons_locadas', (
      select count(*) from public.contrato_fibras cf
      where cf.desvinculado_em is null and cf.porta_pon_id is not null
    ),
    'fibras_locadas', (
      select count(*) from public.infra_fibras where status = 'LOCADA'
    ),
    'alertas_nao_resolvidos', (select count(*) from public.alertas where resolvido = false),
    'usuarios_ativos', (select count(*) from public.usuarios where ativo = true and removido_em is null),
    'usuarios_inativos', (select count(*) from public.usuarios where ativo = false and removido_em is null),
    'proponentes_ativos', (select count(*) from public.parceiros where ativo = true and removido_em is null),
    'assinaturas_pendentes', (
      select count(*) from public.signature_envelopes
      where status in ('CRIADO', 'ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
    ),
    'aditivos_pendentes', (
      select count(*) from public.contrato_aditivos
      where status in ('RASCUNHO', 'EM_APROVACAO', 'APROVADO', 'ASSINATURA')
    )
  );
$$;

-- public.pricing_dashboard_contratual já existe e não muda (mesma assinatura, só mais
-- chaves no retorno).

-- ============================================================================
-- 2) app.dashboard_capacidade_portfolio() — rollup de vw_capacidade_cidade para o
--    portfólio inteiro (fibras livres/locadas, PONs total/ocupadas, capacidade
--    máxima/disponível) — a view já existe desde a Fase 1.1 (seção 13) e nunca tinha
--    consumidor em nível de portfólio, só por cidade (CityDetail.jsx).
-- ============================================================================
create or replace function app.dashboard_capacidade_portfolio()
returns jsonb
language sql
stable
security invoker
as $$
  select jsonb_build_object(
    'fibras_totais', coalesce(sum(fibras_totais), 0),
    'fibras_livres', coalesce(sum(fibras_livres), 0),
    'fibras_locadas', coalesce(sum(fibras_contratadas), 0),
    'fibras_bloqueadas', coalesce(sum(fibras_bloqueadas), 0),
    'pons_totais', coalesce(sum(portas_pon_totais), 0),
    'pons_ocupadas', coalesce(sum(portas_contratadas), 0),
    'pons_disponiveis', coalesce(sum(portas_disponiveis), 0),
    'capacidade_maxima_clientes', coalesce(sum(capacidade_maxima_clientes), 0),
    'capacidade_disponivel_clientes', coalesce(sum(capacidade_disponivel_clientes), 0),
    'clientes_ativos', coalesce(sum(clientes_ativos), 0),
    'taxa_ocupacao_portfolio', case when coalesce(sum(capacidade_maxima_clientes), 0) > 0
      then round(sum(clientes_ativos)::numeric / sum(capacidade_maxima_clientes), 4)
      else 0
    end,
    'por_cidade', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'cidade_id', cidade_id, 'cidade', cidade,
        'fibras_totais', fibras_totais, 'fibras_livres', fibras_livres, 'fibras_locadas', fibras_contratadas,
        'pons_totais', portas_pon_totais, 'pons_ocupadas', portas_contratadas,
        'taxa_ocupacao', taxa_ocupacao
      ) order by cidade), '[]'::jsonb)
      from public.vw_capacidade_cidade
    )
  )
  from public.vw_capacidade_cidade;
$$;

comment on function app.dashboard_capacidade_portfolio() is 'Fase 3 (item 3.3): rollup de vw_capacidade_cidade (Fase 1.1, seção 13) para o portfólio inteiro — fibras livres/locadas, PONs total/ocupadas, capacidade máxima/disponível, com detalhe por cidade.';

create or replace function public.pricing_dashboard_capacidade()
returns jsonb
language sql security invoker
as $$ select app.dashboard_capacidade_portfolio(); $$;
grant execute on function public.pricing_dashboard_capacidade() to authenticated;

-- ============================================================================
-- 3) Parâmetros de crescimento mensal por cenário — nunca hard-coded (seção 3/49:
--    "nenhum valor comercial hard-coded no frontend"), sempre lidos de pricing_parametros,
--    igual a todos os outros parâmetros comerciais do projeto desde a Fase 1.
--    Valores default conservadores/explícitos — o proprietário pode ajustar depois pela
--    tabela pricing_parametros sem precisar de nova migration.
-- ============================================================================
-- pricing_parametros.pricing_version é NOT NULL desde a Fase 2.2.1 (seção 29) — segue a
-- mesma convenção de app.criar_pricing_version()/backfill: to_char(vigente_desde, 'YYYY.MM').
-- O conflito é contra o índice único parcial "vigência global atual" (cidade_id is null e
-- vigente_ate is null) — precisa repetir o WHERE do índice no ON CONFLICT.
insert into public.pricing_parametros (chave, valor, unidade, descricao, pricing_version)
values
  ('CENARIO_CONSERVADOR_CRESCIMENTO_MENSAL_PCT', 0.0000, 'fracao',
   'Fase 3 (item 3.3): crescimento mensal do MRR do portfólio no cenário conservador (receita hoje mantida flat, sem novos contratos assumidos).',
   to_char(current_date, 'YYYY.MM')),
  ('CENARIO_RECOMENDADO_CRESCIMENTO_MENSAL_PCT', 0.0100, 'fracao',
   'Fase 3 (item 3.3): crescimento mensal do MRR do portfólio no cenário recomendado (ritmo histórico moderado de novos contratos/upsell).',
   to_char(current_date, 'YYYY.MM')),
  ('CENARIO_OTIMISTA_CRESCIMENTO_MENSAL_PCT', 0.0250, 'fracao',
   'Fase 3 (item 3.3): crescimento mensal do MRR do portfólio no cenário otimista (expansão acelerada).',
   to_char(current_date, 'YYYY.MM'))
on conflict (chave) where cidade_id is null and vigente_ate is null do nothing;

-- ============================================================================
-- 4) app.simular_portfolio_cenarios() — projeção de receita acumulada do portfólio
--    inteiro (não uma simulação isolada) em 3 cenários, nos horizontes pedidos
--    (default 12/36/48/60), com ROI/payback reaproveitando literalmente
--    app.calcular_roi/app.calcular_payback (Fase 2, seção 51) — nenhuma lógica de
--    ROI/payback duplicada, só a agregação de portfólio + os multiplicadores de cenário,
--    que são inteiramente novos.
--
--    Base (MRR mês 0) = soma de contrato_pricing_config.mensalidade_minima_porta dos
--    contratos ATIVO — o mesmo valor que, desde a correção da seção 3.1, já reflete o
--    preço efetivamente negociado/aprovado (nunca mais o "recomendado" da régua).
--    CAPEX = soma de app.get_custo_base_precificacao(contrato_id) dos contratos ATIVO
--    (Fase 2, seção 7/8 — só custo incremental/alocado, nunca custo histórico da rede
--    inteira).
--
--    Cada cenário aplica sua própria taxa de crescimento mensal composta sobre o MRR
--    base — os 3 cenários partem do MESMO MRR atual (mês 0), divergindo só na
--    trajetória futura assumida.
-- ============================================================================
create or replace function app.simular_portfolio_cenarios(p_horizontes integer[] default array[12,36,48,60])
returns jsonb
language plpgsql
stable
as $$
declare
  v_mrr_base numeric;
  v_capex_total numeric;
  v_cresc_conservador numeric;
  v_cresc_recomendado numeric;
  v_cresc_otimista numeric;
  v_max_mes integer;
  v_cenarios jsonb := '{}'::jsonb;
  v_nome text;
  v_taxa numeric;
  v_meses jsonb;
  v_mes integer;
  v_mrr_mes numeric;
  v_receita_acumulada numeric;
  v_fluxo_acumulado numeric;
  v_projecao jsonb;
  v_horizonte_rows jsonb;
  v_h integer;
  v_linha_mes jsonb;
begin
  select coalesce(sum(cpc.mensalidade_minima_porta), 0) into v_mrr_base
  from public.contratos c join public.contrato_pricing_config cpc on cpc.contrato_id = c.id
  where c.status = 'ATIVO';

  select coalesce(sum(app.get_custo_base_precificacao(c.id)), 0) into v_capex_total
  from public.contratos c where c.status = 'ATIVO';

  v_cresc_conservador := coalesce(app.get_infra_floor_param('CENARIO_CONSERVADOR_CRESCIMENTO_MENSAL_PCT', null, null), 0);
  v_cresc_recomendado := coalesce(app.get_infra_floor_param('CENARIO_RECOMENDADO_CRESCIMENTO_MENSAL_PCT', null, null), 0.01);
  v_cresc_otimista := coalesce(app.get_infra_floor_param('CENARIO_OTIMISTA_CRESCIMENTO_MENSAL_PCT', null, null), 0.025);

  select max(h) into v_max_mes from unnest(p_horizontes) as h;
  v_max_mes := coalesce(v_max_mes, 60);

  for v_nome, v_taxa in
    select * from (values
      ('conservador', v_cresc_conservador),
      ('recomendado', v_cresc_recomendado),
      ('otimista', v_cresc_otimista)
    ) as t(nome, taxa)
  loop
    v_meses := '[]'::jsonb;
    v_receita_acumulada := 0;
    for v_mes in 1..v_max_mes loop
      v_mrr_mes := round(v_mrr_base * power(1 + v_taxa, v_mes), 2);
      v_receita_acumulada := v_receita_acumulada + v_mrr_mes;
      v_fluxo_acumulado := v_receita_acumulada - v_capex_total;
      v_meses := v_meses || jsonb_build_object(
        'mes', v_mes,
        'mrr', v_mrr_mes,
        'receita_acumulada', round(v_receita_acumulada, 2),
        'fluxo_caixa_acumulado', round(v_fluxo_acumulado, 2)
      );
    end loop;

    v_projecao := jsonb_build_object('meses', v_meses);

    v_horizonte_rows := '[]'::jsonb;
    for v_h in select unnest(p_horizontes) order by 1 loop
      select value into v_linha_mes from jsonb_array_elements(v_meses) where (value->>'mes')::integer = v_h;
      v_horizonte_rows := v_horizonte_rows || jsonb_build_object(
        'meses', v_h,
        'receita_acumulada', coalesce((v_linha_mes->>'receita_acumulada')::numeric, null),
        'minimo_contratual_flag', (v_h = 48),
        'roi', app.calcular_roi(v_projecao, v_capex_total, v_h),
        'payback', app.calcular_payback(v_projecao, v_capex_total)
      );
    end loop;

    v_cenarios := v_cenarios || jsonb_build_object(v_nome, jsonb_build_object(
      'crescimento_mensal_pct', v_taxa,
      'horizontes', v_horizonte_rows
    ));
  end loop;

  return jsonb_build_object(
    'mrr_base', v_mrr_base,
    'capex_total', v_capex_total,
    'cenarios', v_cenarios,
    'observacao', 'ESTIMATIVA: projeção a partir do MRR contratado hoje (contrato_pricing_config) e de taxas de crescimento mensal parametrizadas (pricing_parametros) — não é faturamento medido. Medição real depende de integração futura com HubSoft/financeiro (fases 4/5), ainda não implementada.'
  );
end;
$$;

comment on function app.simular_portfolio_cenarios(integer[]) is 'Fase 3 (item 3.3): receita acumulada do portfólio em 3 cenários (conservador/recomendado/otimista), horizontes parametrizáveis (default 12/36/48/60 — 48 = prazo contratual mínimo, nunca confundir os dois). ROI/payback reaproveitam app.calcular_roi/app.calcular_payback (Fase 2, seção 51) sem duplicar lógica. Projeção estimada, não medição real — ver campo observacao no retorno.';

create or replace function public.pricing_dashboard_cenarios_portfolio(p_horizontes integer[] default array[12,36,48,60])
returns jsonb
language sql security invoker
as $$ select app.simular_portfolio_cenarios(p_horizontes); $$;
grant execute on function public.pricing_dashboard_cenarios_portfolio(integer[]) to authenticated;
