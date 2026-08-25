-- OptiMon — Fase 2.1 (correções de consistência comercial sobre a Fase 2)
-- Seção 1/2: a unidade comercial padrão do Dark Fiber passa a ser a FIBRA ÓPTICA
-- INDIVIDUAL, não mais o "par de fibra". O conceito de par continua existindo
-- tecnicamente (par_numero em infra_fibras, vw_pares_disponiveis — nunca apagados),
-- mas o Pricing Engine PADRÃO (calcular_preco_minimo_dark_fiber) passa a contar e
-- cobrar por fibra individual. Migration puramente aditiva: nenhuma função antiga é
-- apagada, nenhuma migration da Fase 1/1.1/1.2/2 é tocada.

-- app.get_fibras_contratadas_dark_fiber(): conta FIBRAS INDIVIDUAIS vinculadas ao
-- contrato (contrato_fibras.fibra_id, vínculo ativo) — em vez de agrupar por
-- par_numero como get_pares_contratados_dark_fiber() fazia. Essa é a diferença real:
-- um contrato com 2 fibras que NÃO formam par físico (par_numero diferente) hoje era
-- contado como "2 pares" (cobrando por 4 fibras-equivalente); com esta função passa a
-- ser contado corretamente como "2 fibras".
create or replace function app.get_fibras_contratadas_dark_fiber(p_contrato_id uuid)
returns integer
language sql
stable
as $$
  select count(distinct cf.fibra_id)::integer
  from public.contrato_fibras cf
  where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null and cf.fibra_id is not null;
$$;
comment on function app.get_fibras_contratadas_dark_fiber(uuid) is 'Seção 1 (Fase 2.1): fibras ópticas individuais contratadas (contagem real de contrato_fibras.fibra_id, não de par_numero). Unidade comercial PADRÃO do Dark Fiber a partir da Fase 2.1 — usada por app.calcular_preco_minimo_dark_fiber().';

comment on function app.get_pares_contratados_dark_fiber(uuid) is 'DEPRECATED a partir da Fase 2.1 (seção 1) — "par de fibra" deixou de ser a unidade comercial padrão do Pricing Engine. Mantida sem alteração só para uso técnico (enlaces que realmente operam em par) e para não quebrar quem já a chame; o motor de preço passou a usar app.get_fibras_contratadas_dark_fiber().';

-- Piso comercial por FIBRA INDIVIDUAL. Não inventamos um número novo: herdamos o
-- mesmo valor já aprovado do piso por par (DARK_FIBER_PRECO_MINIMO_PAR_MES = 1500,
-- seedado na Fase 1) e aplicamos agora por fibra — o que é uma correção de UNIDADE
-- de cobrança, não uma nova premissa financeira (seção 65). Efeito prático: um
-- contrato com 2 fibras que formam 1 par físico (ex.: contrato 0005 do seed Fase 2,
-- fibras 11+12) passa de "1 par × R$1.500" para "2 fibras × R$1.500" — dobra o piso
-- para o mesmo par físico, porque agora as 2 fibras individuais são precificadas
-- separadamente, como o negócio decidiu (seção 1). O valor numérico em si (R$1.500)
-- não foi inventado agora; fica sinalizado no relatório da Fase 2.1 para o
-- Financeiro/Diretor revisar se o número certo por fibra individual é outro.
insert into public.pricing_parametros (chave, valor, unidade, descricao) values
  ('DARK_FIBER_PRECO_MINIMO_FIBRA_MES', 1500.00, 'BRL',
   'Piso comercial por FIBRA INDIVIDUAL/mês — Cenário 1 (Dark Fiber), seção 1 da Fase 2.1. Valor herdado do antigo piso por par (DARK_FIBER_PRECO_MINIMO_PAR_MES); ainda não houve revisão comercial específica para a nova unidade (fibra individual) — recomenda-se ao Financeiro/Diretor revisar.')
on conflict (chave) do nothing;

comment on column public.pricing_parametros.valor is 'DARK_FIBER_PRECO_MINIMO_PAR_MES permanece na tabela (não apagado — seção "não apagar migrations/dados anteriores"), mas não é mais lido por app.calcular_preco_minimo_dark_fiber() a partir da Fase 2.1; ficou reservado a usos técnicos futuros que precisem do conceito de par.';

-- app.calcular_preco_minimo_dark_fiber(): agora usa FIBRAS contratadas (não pares).
-- Resto da fórmula idêntico à Fase 2 (seção 11): MAX(custo incremental/alocado, piso
-- comercial por fibra × fibras) × (1 + margem mínima + risco).
create or replace function app.calcular_preco_minimo_dark_fiber(p_contrato_id uuid)
returns numeric
language plpgsql
stable
as $$
declare
  v_config record;
  v_fibras integer;
  v_piso_fibra numeric;
  v_base numeric;
begin
  select margem_minima_percent, fator_risco_percent into v_config
  from public.contrato_pricing_config where contrato_id = p_contrato_id;

  v_fibras := greatest(coalesce(app.get_fibras_contratadas_dark_fiber(p_contrato_id), 0), 1);

  select valor into v_piso_fibra from public.pricing_parametros
  where chave = 'DARK_FIBER_PRECO_MINIMO_FIBRA_MES' and (vigente_ate is null or vigente_ate >= current_date);

  v_base := greatest(
    coalesce(app.get_custo_base_precificacao(p_contrato_id), 0),
    coalesce(v_piso_fibra, 0) * v_fibras
  );

  return round(v_base * (1 + coalesce(v_config.margem_minima_percent, 0) + coalesce(v_config.fator_risco_percent, 0)), 2);
end;
$$;
comment on function app.calcular_preco_minimo_dark_fiber(uuid) is 'PREÇO MÍNIMO (seção 11, corrigido pela seção 1 da Fase 2.1) = MAX(custo incremental+alocado, piso comercial por FIBRA INDIVIDUAL × fibras contratadas) × (1 + margem mínima + risco). Fibra individual é a unidade comercial padrão — "par" não é mais usado pelo motor de preço padrão.';

-- ===========================================================================
-- Seção 4 (Fase 2.1): a rampa precisa respeitar rampa_aplica_a INTEGRALMENTE.
--
-- Bug real encontrado: app.simular_projecao() (Fase 2) já separava o cálculo de
-- fator de rampa do mínimo e do revenue share (chamando app.get_fator_rampa com
-- 'FIXO_MINIMO' e 'REVENUE_SHARE' respectivamente), mas NUNCA olhava para
-- contrato_pricing_config.rampa_aplica_a — sempre aplicava a rampa aos DOIS
-- componentes, mesmo quando o contrato estava configurado como FIXO_MINIMO (que
-- deveria significar "só o mínimo recebe rampa, revenue share sempre 100%") ou
-- REVENUE_SHARE (só o share recebe rampa, mínimo sempre 100%). Isso é agravado por
-- rampa_aplica_a ter DEFAULT 'FIXO_MINIMO' desde a Fase 1.1 — ou seja, todo contrato
-- que nunca configurou esse campo explicitamente (inclusive o contrato 0006 do seed
-- Fase 2) estava, na prática, tendo o revenue share rampeado incorretamente.
--
-- Correção: app.simular_projecao() agora resolve rampa_aplica_a (do contrato real,
-- ou do parâmetro rampa_aplica_a em p_params quando contrato_id é null — simulação
-- ad hoc, default 'AMBOS' para preservar o comportamento anterior de quem não
-- informar nada) e só aplica o fator de rampa ao componente autorizado; o outro
-- componente recebe fator 1.00 (100%, sem rampa) nesse mês.
create or replace function app.simular_projecao(p_params jsonb)
returns jsonb
language plpgsql
stable
as $$
declare
  v_contrato_id uuid := nullif(p_params->>'contrato_id', '')::uuid;
  v_modelo public.modelo_cobranca;
  v_capacidade integer;
  v_clientes_iniciais integer := coalesce((p_params->>'clientes_iniciais')::integer, 0);
  v_modo text := coalesce(p_params->>'modo_crescimento', 'LINEAR');
  v_crescimento_mensal integer := coalesce((p_params->>'crescimento_mensal')::integer, 0);
  v_meta_final integer := nullif(p_params->>'meta_final_clientes', '')::integer;
  v_checkpoints jsonb := coalesce(p_params->'checkpoints', '[]'::jsonb);
  v_meses integer := coalesce((p_params->>'meses_horizonte')::integer, 48);
  v_arpu0 numeric := coalesce((p_params->>'arpu_inicial')::numeric, 0);
  v_arpu_cresc numeric := coalesce((p_params->>'arpu_crescimento_anual_percent')::numeric, 0);
  v_minimo_base numeric;
  v_percentual numeric;
  v_rampa_aplica_a public.rampa_alvo;
  v_capex numeric := coalesce((p_params->>'capex_incremental')::numeric, 0);
  v_opex numeric := coalesce((p_params->>'opex_incremental_mensal')::numeric, 0);
  v_reajuste_anual numeric := coalesce((p_params->>'reajuste_percentual_anual')::numeric, 0);
  v_meses_arr jsonb := '[]'::jsonb;
  m integer;
  v_clientes integer;
  v_portas integer;
  v_arpu numeric;
  v_faturamento_parceiro numeric;
  v_fator_reajuste numeric;
  v_fator_rampa_minimo numeric;
  v_fator_rampa_share numeric;
  v_minimo numeric;
  v_share numeric;
  v_receita_optimon numeric;
  v_resultado numeric;
  v_margem numeric;
  v_capex_mes numeric;
  v_fluxo numeric;
  v_resultado_acumulado numeric := 0;
  v_capex_acumulado numeric := 0;
  v_fluxo_acumulado numeric := 0;
  cp record;
  v_cp_anterior_mes integer;
  v_cp_anterior_clientes integer;
begin
  if v_contrato_id is not null then
    select modelo_cobranca, percentual_revenue_share, rampa_aplica_a into v_modelo, v_percentual, v_rampa_aplica_a
    from public.contrato_pricing_config where contrato_id = v_contrato_id;
    v_minimo_base := app.calcular_minimo_contratual(v_contrato_id);
  else
    v_modelo := coalesce(nullif(p_params->>'modelo_cobranca', '')::public.modelo_cobranca, 'SOMA');
    v_percentual := coalesce((p_params->>'revenue_share_percent')::numeric, 0);
    v_minimo_base := coalesce((p_params->>'minimo_mensal')::numeric, 0);
    -- Simulação ad hoc (sem contrato real): default 'AMBOS' preserva o comportamento
    -- da Fase 2 para quem não informar rampa_aplica_a explicitamente nos parâmetros.
    v_rampa_aplica_a := coalesce(nullif(p_params->>'rampa_aplica_a', '')::public.rampa_alvo, 'AMBOS');
  end if;

  v_capacidade := nullif(p_params->>'capacidade_por_porta', '')::integer;
  if v_capacidade is null then
    select valor::integer into v_capacidade from public.pricing_parametros
    where chave = 'PORTA_PON_CAPACIDADE_MAX_PADRAO' and (vigente_ate is null or vigente_ate >= current_date);
  end if;

  for m in 1..greatest(v_meses, 1) loop
    -- 1) Clientes do mês, conforme o modo de crescimento escolhido (seção 24).
    if v_modo = 'CHECKPOINTS' then
      v_cp_anterior_mes := 0; v_cp_anterior_clientes := v_clientes_iniciais;
      v_clientes := v_clientes_iniciais;
      for cp in select (value->>'mes')::integer as mes, (value->>'clientes')::integer as clientes
                from jsonb_array_elements(v_checkpoints) order by (value->>'mes')::integer loop
        if m >= cp.mes then
          v_clientes := cp.clientes;
          v_cp_anterior_mes := cp.mes;
          v_cp_anterior_clientes := cp.clientes;
        elsif m > v_cp_anterior_mes then
          -- interpolação linear entre o checkpoint anterior e este.
          v_clientes := v_cp_anterior_clientes + round(
            (cp.clientes - v_cp_anterior_clientes)::numeric * (m - v_cp_anterior_mes) / nullif(cp.mes - v_cp_anterior_mes, 0)
          )::integer;
          exit;
        end if;
      end loop;
    else
      v_clientes := v_clientes_iniciais + v_crescimento_mensal * (m - 1);
      if v_meta_final is not null then
        v_clientes := least(v_clientes, v_meta_final);
      end if;
    end if;
    v_clientes := greatest(v_clientes, 0);

    -- 2) Portas necessárias (seções 23/44).
    v_portas := app.get_portas_necessarias(v_clientes, v_capacidade);

    -- 3) ARPU com crescimento anual opcional (seção 22 — composto a cada 12 meses).
    v_arpu := v_arpu0 * power(1 + v_arpu_cresc, floor((m - 1) / 12.0));
    v_faturamento_parceiro := round(v_clientes * v_arpu, 2);

    -- 4) Reajuste anual simulado sobre o mínimo/share (seção 29 — composto a cada 12 meses;
    --    é só uma projeção hipotética, não altera o contrato real — isso é feito por
    --    app.aplicar_reajuste_contrato quando o reajuste é de fato aplicado).
    v_fator_reajuste := power(1 + v_reajuste_anual, floor((m - 1) / 12.0));

    -- 5) Mínimo e Revenue Share, cada um com sua própria rampa de maturação (seção 25/26),
    --    respeitando INTEGRALMENTE rampa_aplica_a (seção 4 da Fase 2.1): o componente que
    --    não está autorizado a receber rampa fica sempre em 100% (fator 1.00) nesse mês —
    --    nunca cai no fallback da régua global "AMBOS" por engano.
    v_fator_rampa_minimo := case when v_rampa_aplica_a in ('FIXO_MINIMO', 'AMBOS')
      then app.get_fator_rampa(v_contrato_id, m, 'FIXO_MINIMO') else 1.00 end;
    v_fator_rampa_share := case when v_rampa_aplica_a in ('REVENUE_SHARE', 'AMBOS')
      then app.get_fator_rampa(v_contrato_id, m, 'REVENUE_SHARE') else 1.00 end;

    v_minimo := round(v_minimo_base * v_fator_reajuste * v_fator_rampa_minimo, 2);
    v_share := round(v_faturamento_parceiro * coalesce(v_percentual, 0) * v_fator_reajuste * v_fator_rampa_share, 2);

    -- 6) Cobrança total conforme o modelo (SOMA/MAX — Fase 1.2, testado nos testes 5/6).
    v_receita_optimon := case when v_modelo = 'SOMA' then v_minimo + v_share else greatest(v_minimo, v_share) end;

    v_resultado := round(v_receita_optimon - v_opex, 2);
    v_margem := case when v_receita_optimon > 0 then round(v_resultado / v_receita_optimon, 4) else null end;
    v_capex_mes := case when m = 1 then v_capex else 0 end;
    v_fluxo := v_resultado - v_capex_mes;

    v_resultado_acumulado := v_resultado_acumulado + v_resultado;
    v_capex_acumulado := v_capex_acumulado + v_capex_mes;
    v_fluxo_acumulado := v_fluxo_acumulado + v_fluxo;

    v_meses_arr := v_meses_arr || jsonb_build_object(
      'mes', m,
      'clientes', v_clientes,
      'portas', v_portas,
      'faturamento_parceiro', v_faturamento_parceiro,
      'fator_rampa_minimo', v_fator_rampa_minimo,
      'fator_rampa_revenue_share', v_fator_rampa_share,
      'revenue_share', v_share,
      'minimo', v_minimo,
      'receita_optimon', v_receita_optimon,
      'opex_incremental', v_opex,
      'resultado', v_resultado,
      'margem', v_margem,
      'capex', v_capex_mes,
      'fluxo_caixa', v_fluxo,
      'resultado_acumulado', round(v_resultado_acumulado, 2),
      'fluxo_caixa_acumulado', round(v_fluxo_acumulado, 2)
    );
  end loop;

  return jsonb_build_object(
    'parametros', p_params,
    'rampa_aplica_a', v_rampa_aplica_a,
    'capex_total', v_capex,
    'meses', v_meses_arr
  );
end;
$$;

comment on function app.simular_projecao(jsonb) is 'ScenarioSimulator (seção 51): projeção financeira mês a mês (seção 30). Corrigido na Fase 2.1 (seção 4): a rampa de maturação agora respeita integralmente contrato_pricing_config.rampa_aplica_a (FIXO_MINIMO = só o mínimo é rampeado; REVENUE_SHARE = só o share; AMBOS = os dois) — antes, os dois componentes eram sempre rampeados juntos, ignorando essa configuração.';
