-- OptiMon — Fase 3.8 (item 3.8-12): Multi-POP — consolidação
-- Cidade→POP→Porta PON→Capacidade→Receita.
--
-- ESTADO ANTES DESTA MIGRATION (investigado, não presumido):
--   - Cidade→POP→Porta PON→Capacidade já estava completo e maduro desde as Fases 1.1/2.1:
--     schema (infra_pops, infra_portas_pon com CHECKs de capacidade), views de agregação
--     (vw_capacidade_pop etc.), relatório app.relatorio_capacidade_por_pop() e a função
--     por-contrato app.get_capacidade_multi_pop_contrato() (20260828090300).
--   - O único elo que faltava era "→Receita": a migration 20260924090000 (item 3.6)
--     documentou EXPLICITAMENTE que não incluía receita por POP porque "ratear a
--     mensalidade entre POPs exigiria inventar uma metodologia de alocação que o
--     projeto nunca definiu" — e deixou o relatório e a tela (web/src/pages/Reports.jsx)
--     dizendo "sem coluna de receita" em vez de inventar um número.
--   - Além disso, public.pricing_capacity_by_pop(contrato_id) (a função por-contrato) já
--     existia no backend desde a Fase 2.1 mas NUNCA foi chamada por nenhuma tela do
--     frontend (confirmado por grep) — outra tabela/função "morta" por falta de UI.
--
-- O QUE ESTA MIGRATION FAZ: define agora, de forma explícita e documentada, a
-- metodologia de rateio que faltava — e a aplica nos dois pontos (relatório city-wide e
-- função por-contrato), sem reescrever a lógica de capacidade já existente.
--
-- METODOLOGIA DE RATEIO (nova decisão de negócio, documentada aqui pela primeira vez):
--   Receita rateável de um contrato = contrato_pricing_config.mensalidade_minima_porta
--   (NUNCA o revenue share: seção do cabeçalho de 20260924090000 continua válida — o
--   valor de revenue share REAL depende de faturamento medido, que não existe ainda;
--   ratear um número que já não existe de verdade seria inventar dado sobre dado
--   inventado — não fazemos isso).
--   Essa mensalidade é distribuída entre os POPs que o contrato efetivamente usa
--   (contrato_fibras.porta_pon_id → infra_portas_pon.pop_id, vínculos ativos:
--   desvinculado_em is null), proporcionalmente ao PESO de cada vínculo:
--     peso do vínculo = coalesce(contrato_fibras.capacidade_clientes, 1)
--   ou seja: quando o vínculo tem uma capacidade contratada explícita (o caso comum de
--   acesso PON), o rateio usa essa capacidade real; quando não tem (ex.: dark fiber pura,
--   sem porta PON/capacidade_clientes definida), o vínculo entra com peso 1 (uma
--   "unidade" de alocação) — nunca fica de fora do rateio nem quebra a soma.
--   share_pop = soma dos pesos dos vínculos do contrato naquele POP / soma de TODOS os
--   pesos dos vínculos ativos do contrato (em qualquer POP).
--   receita_rateada_pop = mensalidade_minima_porta * share_pop.
--   Um contrato SEM nenhum vínculo com porta_pon_id (0 POPs) não aparece no rateio por
--   POP — sua receita segue 100% capturada em relatorio_receita_por_cidade (que nunca
--   dependeu de POP).
--   TRANSPARÊNCIA (nunca esconder que é estimativa): todo campo de receita por POP se
--   chama receita_mensal_rateada (nunca "receita_real"/"faturamento") e vem sempre
--   acompanhado do campo receita_metodologia explicando a fórmula, para nenhuma tela
--   apresentar isso como faturamento medido.

-- ============================================================================
-- 1) app.relatorio_capacidade_por_pop(): acrescenta receita_mensal_rateada e
--    receita_metodologia (CREATE OR REPLACE aditivo — mantém todos os campos
--    existentes; nenhum consumidor atual quebra, todos ganham 2 campos novos).
-- ============================================================================
create or replace function app.relatorio_capacidade_por_pop()
returns jsonb
language sql
stable
security invoker
as $$
  with peso_por_vinculo as (
    select
      p.pop_id,
      cf.contrato_id,
      coalesce(cf.capacidade_clientes, 1)::numeric as peso
    from public.contrato_fibras cf
    join public.infra_portas_pon p on p.id = cf.porta_pon_id
    join public.contratos c on c.id = cf.contrato_id
    where cf.desvinculado_em is null and cf.porta_pon_id is not null and c.status = 'ATIVO'
  ),
  peso_total_contrato as (
    select contrato_id, sum(peso) as peso_total from peso_por_vinculo group by contrato_id
  ),
  receita_por_pop as (
    select
      v.pop_id,
      sum((v.peso / t.peso_total) * coalesce(cpc.mensalidade_minima_porta, 0)) as receita_mensal_rateada
    from peso_por_vinculo v
    join peso_total_contrato t on t.contrato_id = v.contrato_id
    left join public.contrato_pricing_config cpc on cpc.contrato_id = v.contrato_id
    group by v.pop_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'pop_id', v.pop_id, 'pop', v.pop_nome, 'cidade_id', v.cidade_id,
    'fibras_totais', v.fibras_totais, 'fibras_livres', v.fibras_livres, 'fibras_locadas', v.fibras_contratadas,
    'pons_totais', v.portas_pon_totais, 'pons_ocupadas', v.portas_contratadas,
    'clientes_ativos', v.clientes_ativos, 'taxa_ocupacao', v.taxa_ocupacao,
    'contratos_distintos', (
      select count(distinct cf.contrato_id)
      from public.contrato_fibras cf
      join public.infra_portas_pon pp on pp.id = cf.porta_pon_id
      where pp.pop_id = v.pop_id and cf.desvinculado_em is null
    ),
    'receita_mensal_rateada', round(coalesce(rp.receita_mensal_rateada, 0), 2),
    'receita_metodologia', 'Estimativa: mensalidade mínima de cada contrato dividida entre os POPs que ele usa, proporcional à capacidade contratada (capacidade_clientes) em cada POP — nunca inclui revenue share (depende de faturamento medido, ainda não integrado) e nunca é faturamento real.'
  ) order by v.pop_nome), '[]'::jsonb)
  from public.vw_capacidade_pop v
  left join receita_por_pop rp on rp.pop_id = v.pop_id;
$$;

comment on function app.relatorio_capacidade_por_pop() is 'Fase 3.6, ampliada na Fase 3.8 (item 3.8-12): capacidade/ocupação/contratos por POP + receita_mensal_rateada (estimativa por rateio proporcional à capacidade contratada — ver metodologia no cabeçalho de 20260929103000_phase_3_8_12_multipop_receita_rateada.sql). Nunca é faturamento real medido.';

-- Wrapper público inalterado (mesmo nome/assinatura) — API e frontend recebem os 2
-- campos novos automaticamente, sem precisar de nenhuma mudança de rota.

-- ============================================================================
-- 2) app.get_capacidade_multi_pop_contrato(): mesma ampliação aditiva, agora no nível de
--    UM contrato específico — fecha o segundo gap encontrado (a função já existia desde
--    a Fase 2.1 mas nunca tinha receita nem estava ligada a nenhuma tela).
-- ============================================================================
create or replace function app.get_capacidade_multi_pop_contrato(p_contrato_id uuid)
returns jsonb
language sql
stable
as $$
  with vinculos as (
    select
      pop.id as pop_id, pop.codigo as pop_codigo, pop.nome as pop_nome,
      p.id as porta_id, coalesce(cf.capacidade_clientes, 1)::numeric as peso,
      p.capacidade_max_assinantes, p.capacidade_utilizada_assinantes, p.capacidade_disponivel
    from public.contrato_fibras cf
    join public.infra_portas_pon p on p.id = cf.porta_pon_id
    join public.infra_pops pop on pop.id = p.pop_id
    where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null and cf.porta_pon_id is not null
  ),
  peso_total as (select coalesce(sum(peso), 0) as total from vinculos),
  mensalidade as (
    select coalesce(mensalidade_minima_porta, 0) as valor from public.contrato_pricing_config where contrato_id = p_contrato_id
  ),
  por_pop as (
    select
      pop_id, pop_codigo, pop_nome,
      count(distinct porta_id) as portas,
      coalesce(sum(capacidade_max_assinantes), 0) as capacidade_maxima,
      coalesce(sum(capacidade_utilizada_assinantes), 0) as clientes_ativos,
      coalesce(sum(capacidade_disponivel), 0) as capacidade_disponivel,
      sum(peso) as peso_pop
    from vinculos
    group by pop_id, pop_codigo, pop_nome
  )
  select jsonb_build_object(
    'pops', coalesce(jsonb_agg(jsonb_build_object(
      'pop_id', pop_id, 'pop_codigo', pop_codigo, 'pop_nome', pop_nome,
      'portas', portas, 'capacidade_maxima', capacidade_maxima,
      'clientes_ativos', clientes_ativos, 'capacidade_disponivel', capacidade_disponivel,
      'receita_mensal_rateada', round(case when (select total from peso_total) > 0
        then (peso_pop / (select total from peso_total)) * (select valor from mensalidade) else 0 end, 2)
    ) order by pop_codigo), '[]'::jsonb),
    'consolidado', jsonb_build_object(
      'pops_utilizados', count(*),
      'portas_total', coalesce(sum(portas), 0),
      'capacidade_maxima_total', coalesce(sum(capacidade_maxima), 0),
      'clientes_ativos_total', coalesce(sum(clientes_ativos), 0),
      'capacidade_disponivel_total', coalesce(sum(capacidade_disponivel), 0),
      'receita_mensal_total', round((select valor from mensalidade), 2)
    ),
    'receita_metodologia', 'Estimativa: mensalidade mínima do contrato dividida entre os POPs que ele usa, proporcional à capacidade contratada (capacidade_clientes) em cada POP — nunca inclui revenue share e nunca é faturamento real.'
  )
  from por_pop;
$$;

comment on function app.get_capacidade_multi_pop_contrato(uuid) is 'Seção 12 (Fase 2.1), ampliada na Fase 3.8 (item 3.8-12): capacidade + receita_mensal_rateada por POP e consolidado de um contrato específico. Exemplo original da seção 12 preservado (POP-01=2 portas/256, POP-02=3/384, POP-03=1/128 → 6 portas/768), agora também com a receita estimada por POP.';

-- Wrapper público public.pricing_capacity_by_pop(uuid) inalterado — mesmo nome, mesma
-- assinatura, agora devolvendo também receita_mensal_rateada por POP e o total do
-- contrato. Nenhuma rota de API precisa mudar.
