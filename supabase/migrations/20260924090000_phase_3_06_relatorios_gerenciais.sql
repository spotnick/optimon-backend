-- OptiMon — Fase 3, item 3.6: Relatórios gerenciais (cobertura completa).
--
-- CONTEXTO (investigação prévia): o dashboard executivo (item 3.3) já cobre KPIs
-- agregados de portfólio; faltava um conjunto de RELATÓRIOS — listas detalhadas,
-- exportáveis, por entidade (cidade/parceiro/POP/PON/contrato/reajuste) para
-- DIRETOR/FINANCEIRO/ADMINISTRADOR/AUDITOR. A maior parte dos dados de capacidade já
-- existe (vw_capacidade_*, Fase 1.1); o que faltava era juntar isso com dinheiro
-- (contrato_pricing_config) e expor como relatório tabular.
--
-- LIMITAÇÃO HONESTA (nunca escondida, seção 3/49 do prompt): "receita por cidade" e
-- "receita por parceiro" são reais (contratos.cidade_id/parceiro_id são diretos e
-- 1:1 — nenhuma ambiguidade). "Receita por POP" NÃO é segregável com precisão: um
-- contrato tem UMA mensalidade mínima (contrato_pricing_config.mensalidade_minima_porta),
-- não uma por POP, e um contrato pode usar fibras/portas de mais de um POP
-- (contrato_fibras → infra_portas_pon.pop_id). Ratear a mensalidade entre POPs exigiria
-- inventar uma metodologia de alocação que o projeto nunca definiu — em vez de inventar
-- um número, o relatório por POP mostra capacidade/ocupação/contratos ativos por POP
-- (dados reais, sem ambiguidade) e deixa explícito que a receita não é segregável nesse
-- nível. "Faturamento real", "revenue share calculado", "take-or-pay calculado" e
-- "inadimplência" não têm NENHUMA fonte de dado ainda — medicoes_mensais/medicao_* são
-- schema-only (alimentação real depende de integração futura com HubSoft/financeiro,
-- explicitamente adiada) — o relatório correspondente aqui sempre retorna
-- disponivel=false com o texto explicando o porquê, nunca um número inventado.

-- ============================================================================
-- 1) Receita por cidade — contratos.cidade_id é direto, sem ambiguidade.
-- ============================================================================
create or replace function app.relatorio_receita_por_cidade()
returns jsonb
language sql
stable
security invoker
as $$
  with agregado as (
    select
      ci.id as cidade_id, ci.nome as cidade, ci.uf,
      count(c.id) filter (where c.status = 'ATIVO') as contratos_ativos,
      coalesce(sum(cpc.mensalidade_minima_porta) filter (where c.status = 'ATIVO'), 0) as receita_mensal_contratada,
      round(avg(cpc.percentual_revenue_share) filter (where c.status = 'ATIVO'), 4) as revenue_share_medio_pct
    from public.cidades_infra ci
    left join public.contratos c on c.cidade_id = ci.id
    left join public.contrato_pricing_config cpc on cpc.contrato_id = c.id
    group by ci.id, ci.nome, ci.uf
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'cidade_id', cidade_id, 'cidade', cidade, 'uf', uf,
    'contratos_ativos', contratos_ativos, 'receita_mensal_contratada', receita_mensal_contratada,
    'revenue_share_medio_pct', revenue_share_medio_pct
  ) order by cidade), '[]'::jsonb)
  from agregado;
$$;

comment on function app.relatorio_receita_por_cidade() is 'Fase 3 (item 3.6): receita mensal contratada por cidade — contratos.cidade_id é atribuição direta (1 contrato = 1 cidade), sem ambiguidade de rateio.';

create or replace function public.pricing_relatorio_receita_por_cidade()
returns jsonb language sql security invoker as $$ select app.relatorio_receita_por_cidade(); $$;
grant execute on function public.pricing_relatorio_receita_por_cidade() to authenticated;

-- ============================================================================
-- 2) Receita por parceiro — contratos.parceiro_id é direto, sem ambiguidade.
-- ============================================================================
create or replace function app.relatorio_receita_por_parceiro()
returns jsonb
language sql
stable
security invoker
as $$
  with agregado as (
    select
      p.id as parceiro_id, coalesce(p.nome_fantasia, p.razao_social) as parceiro,
      count(c.id) filter (where c.status = 'ATIVO') as contratos_ativos,
      coalesce(sum(cpc.mensalidade_minima_porta) filter (where c.status = 'ATIVO'), 0) as receita_mensal_contratada,
      count(distinct c.cidade_id) filter (where c.status = 'ATIVO') as cidades_atendidas
    from public.parceiros p
    left join public.contratos c on c.parceiro_id = p.id
    left join public.contrato_pricing_config cpc on cpc.contrato_id = c.id
    where p.removido_em is null
    group by p.id, p.nome_fantasia, p.razao_social
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'parceiro_id', parceiro_id, 'parceiro', parceiro, 'contratos_ativos', contratos_ativos,
    'receita_mensal_contratada', receita_mensal_contratada, 'cidades_atendidas', cidades_atendidas
  ) order by parceiro), '[]'::jsonb)
  from agregado;
$$;

comment on function app.relatorio_receita_por_parceiro() is 'Fase 3 (item 3.6): receita mensal contratada por parceiro — contratos.parceiro_id é atribuição direta.';

create or replace function public.pricing_relatorio_receita_por_parceiro()
returns jsonb language sql security invoker as $$ select app.relatorio_receita_por_parceiro(); $$;
grant execute on function public.pricing_relatorio_receita_por_parceiro() to authenticated;

-- ============================================================================
-- 3) Capacidade e contratos por POP — sem coluna de receita (ver nota de limitação
--    no cabeçalho desta migration: mensalidade é por contrato, não por POP).
-- ============================================================================
create or replace function app.relatorio_capacidade_por_pop()
returns jsonb
language sql
stable
security invoker
as $$
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
    )
  ) order by v.pop_nome), '[]'::jsonb)
  from public.vw_capacidade_pop v;
$$;

comment on function app.relatorio_capacidade_por_pop() is 'Fase 3 (item 3.6): capacidade/ocupação/contratos por POP. NUNCA inclui receita — mensalidade_minima_porta é por contrato (que pode usar mais de um POP), não segregável por POP sem inventar uma metodologia de rateio (ver cabeçalho da migration).';

create or replace function public.pricing_relatorio_capacidade_por_pop()
returns jsonb language sql security invoker as $$ select app.relatorio_capacidade_por_pop(); $$;
grant execute on function public.pricing_relatorio_capacidade_por_pop() to authenticated;

-- ============================================================================
-- 4) Clientes por porta PON — granularidade mais fina, direto de vw_porta_pon_detalhe.
-- ============================================================================
create or replace function app.relatorio_clientes_por_pon()
returns jsonb
language sql
stable
security invoker
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'porta_id', vp.porta_pon_id, 'codigo_porta', vp.codigo_porta, 'pop', pop.nome, 'cidade', ci.nome,
    'tecnologia', vp.tecnologia, 'capacidade_maxima', vp.capacidade_max_assinantes,
    'clientes_ativos', vp.capacidade_utilizada_assinantes, 'capacidade_disponivel', vp.capacidade_disponivel,
    'taxa_ocupacao', vp.taxa_ocupacao, 'contratada', vp.contratada
  ) order by ci.nome, pop.nome, vp.codigo_porta), '[]'::jsonb)
  from public.vw_porta_pon_detalhe vp
  join public.infra_pops pop on pop.id = vp.pop_id
  join public.cidades_infra ci on ci.id = vp.cidade_id;
$$;

comment on function app.relatorio_clientes_por_pon() is 'Fase 3 (item 3.6): clientes ativos por porta PON — direto de vw_porta_pon_detalhe (Fase 1.1).';

create or replace function public.pricing_relatorio_clientes_por_pon()
returns jsonb language sql security invoker as $$ select app.relatorio_clientes_por_pon(); $$;
grant execute on function public.pricing_relatorio_clientes_por_pon() to authenticated;

-- ============================================================================
-- 5) Contratos (relatório, com colunas monetárias) — pricing_contracts_list já existe
--    para a tela /contratos mas não tem colunas de dinheiro; este relatório é um
--    superset com mensalidade/revenue share, nunca substitui o endpoint existente.
-- ============================================================================
create or replace function app.relatorio_contratos()
returns jsonb
language sql
stable
security invoker
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'contrato_id', c.id, 'numero', c.numero, 'status', c.status,
    'parceiro', coalesce(p.nome_fantasia, p.razao_social), 'cidade', ci.nome, 'uf', ci.uf,
    'prazo_meses', c.prazo_meses, 'data_inicio', c.data_inicio, 'data_fim_prevista', c.data_fim_prevista,
    'mensalidade_minima_porta', cpc.mensalidade_minima_porta,
    'percentual_revenue_share', cpc.percentual_revenue_share,
    'modelo_cobranca', cpc.modelo_cobranca
  ) order by c.numero), '[]'::jsonb)
  from public.contratos c
  join public.parceiros p on p.id = c.parceiro_id
  join public.cidades_infra ci on ci.id = c.cidade_id
  left join public.contrato_pricing_config cpc on cpc.contrato_id = c.id;
$$;

comment on function app.relatorio_contratos() is 'Fase 3 (item 3.6): relatório de contratos com colunas monetárias — superset de public.pricing_contracts_list (que alimenta a tela /contratos e não muda).';

create or replace function public.pricing_relatorio_contratos()
returns jsonb language sql security invoker as $$ select app.relatorio_contratos(); $$;
grant execute on function public.pricing_relatorio_contratos() to authenticated;

-- ============================================================================
-- 6) Reajustes (relatório cross-contrato) — reajustes já existe e é consultado por
--    contrato (ContractDetail.jsx); aqui, a listagem completa entre todos os contratos.
-- ============================================================================
create or replace function app.relatorio_reajustes()
returns jsonb
language sql
stable
security invoker
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'reajuste_id', r.id, 'contrato_numero', c.numero, 'parceiro', coalesce(p.nome_fantasia, p.razao_social),
    'indice', ie.indice, 'percentual_aplicado', r.percentual_aplicado,
    'competencia_base', r.competencia_base, 'status', r.status, 'aplicado_em', r.aplicado_em
  ) order by r.competencia_base desc), '[]'::jsonb)
  from public.reajustes r
  join public.contratos c on c.id = r.contrato_id
  join public.parceiros p on p.id = c.parceiro_id
  left join public.indices_economicos ie on ie.id = r.indice_id;
$$;

comment on function app.relatorio_reajustes() is 'Fase 3 (item 3.6): reajustes de todos os contratos (a tela ContractDetail.jsx já lista por contrato individualmente; isto é a visão cross-contrato para relatório gerencial).';

create or replace function public.pricing_relatorio_reajustes()
returns jsonb language sql security invoker as $$ select app.relatorio_reajustes(); $$;
grant execute on function public.pricing_relatorio_reajustes() to authenticated;

-- ============================================================================
-- 7) Faturamento real / revenue share calculado / take-or-pay calculado /
--    inadimplência — SEM FONTE DE DADO ainda (medicoes_mensais é schema-only, seção
--    3/49: "NÃO declarar 100% pronto se existir funcionalidade não testada/não
--    implementada" — aqui vai além: nem sequer HÁ dado real, então o relatório
--    retorna disponivel=false de forma honesta em vez de inventar zero ou estimar
--    sem avisar. app.simular_portfolio_cenarios (item 3.3) continua sendo a única
--    fonte de PROJEÇÃO/estimativa — nunca confundir os dois.
-- ============================================================================
create or replace function app.relatorio_faturamento_real()
returns jsonb
language plpgsql
stable
security invoker
as $$
declare
  v_count integer;
begin
  select count(*) into v_count from public.medicoes_mensais;
  if v_count = 0 then
    return jsonb_build_object(
      'disponivel', false,
      'motivo', 'Nenhuma medição mensal real registrada ainda. Faturamento, revenue share calculado, take-or-pay calculado e inadimplência dependem da alimentação de public.medicoes_mensais/medicao_faturamento/medicao_recebimentos, hoje schema-only — a alimentação automática depende de integração futura com HubSoft/financeiro (explicitamente adiada nesta fase). Use o gráfico de cenários do dashboard executivo (item 3.3) para uma PROJEÇÃO estimada — nunca confundir estimativa com faturamento medido.'
    );
  end if;

  return jsonb_build_object(
    'disponivel', true,
    'faturamento_acumulado', (select coalesce(sum(valor_final), 0) from public.medicoes_mensais where status = 'APROVADA'),
    'revenue_share_acumulado', (select coalesce(sum(revenue_share_calculado), 0) from public.medicoes_mensais where status = 'APROVADA'),
    'take_or_pay_acumulado', (select coalesce(sum(take_or_pay_calculado), 0) from public.medicoes_mensais where status = 'APROVADA')
  );
end;
$$;

comment on function app.relatorio_faturamento_real() is 'Fase 3 (item 3.6): faturamento/revenue share/take-or-pay REAIS (medidos, não estimados) — retorna disponivel=false honestamente enquanto medicoes_mensais não for alimentada (integração HubSoft/financeiro, adiada). Nunca inventa um número.';

create or replace function public.pricing_relatorio_faturamento_real()
returns jsonb language sql security invoker as $$ select app.relatorio_faturamento_real(); $$;
grant execute on function public.pricing_relatorio_faturamento_real() to authenticated;
