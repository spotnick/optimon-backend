-- OptiMon — Seed complementar da Fase 2 (seções 8, 43, 56 do Prompt Mestre).
-- Roda por cima de Fase 1 + seed.sql + Fase 1.1 + seed_fase11.sql + Fase 1.2 +
-- seed_fase12.sql + migrations da Fase 2. Faz duas coisas:
--   1) Classifica os custos REAIS do caso Jussara em custos_infraestrutura, sem assumir
--      que 100% vira custo do parceiro (seção 8/9) — nenhum valor é inventado, todos vêm
--      literalmente da planilha do prompt.
--   2) Cria os dois contratos de cenário de teste (Cenário 1 Dark Fiber e Cenário 2 Porta
--      PON + Revenue Share) sobre a infraestrutura ociosa de Jussara, para os testes
--      obrigatórios 1-3 e o TESTE ECONÔMICO OBRIGATÓRIO (seção 56).

do $$
declare
  v_admin_id uuid;
  v_cidade_id uuid;
  v_pop1_id uuid;
  v_cabo1_id uuid;
  v_poste_id uuid;
  v_fibra_par6_a uuid; -- fibra 11
  v_fibra_par6_b uuid; -- fibra 12
  v_fibra_porta uuid;  -- fibra 10 (par 5, livre)
  v_parceiro_dark uuid;
  v_parceiro_pon uuid;
  v_contrato_dark uuid;
  v_contrato_pon uuid;
  v_porta_id uuid;
begin
  select id into v_admin_id from public.usuarios where perfil = 'ADMINISTRADOR' limit 1;
  select id into v_cidade_id from public.cidades_infra where nome = 'Jussara' and uf = 'PR';
  select id into v_cabo1_id from public.infra_cabos where identificacao = 'CABO-JUSSARA-01';
  select pop_id into v_pop1_id from public.infra_cabos where identificacao = 'CABO-JUSSARA-01';
  select id into v_poste_id from public.infra_postes where cidade_id = v_cidade_id limit 1;

  if v_cidade_id is null or v_cabo1_id is null then
    raise exception 'Seed Fase 2 requer o seed base (Jussara) já aplicado.';
  end if;

  ------------------------------------------------------------------
  -- 1) Custos reais de Jussara (seção 8), classificados (seção 9) —
  -- valores literais da planilha do prompt, nenhum inventado.
  ------------------------------------------------------------------

  -- Postes: já existe em infra_postes (seed.sql, Fase 1) — 165 postes, R$1.108,80/mês.
  -- Custo compartilhado da rede inteira (todo mundo que usa a rede se beneficia da
  -- passagem em poste), rateável por poste/km/fibra/porta conforme o método escolhido —
  -- por isso ALLOCATED_COST, não INCREMENTAL (não foi causado por nenhum parceiro
  -- específico, já existia antes de qualquer contrato comercial).
  insert into public.custos_infraestrutura
    (descricao, valor, periodicidade, cidade_id, poste_id, cost_type, metodo_rateio, percentual_alocacao, observacoes, criado_por)
  values
    ('Aluguel de postes (concessionária de energia) — rede Jussara', 1108.80, 'MENSAL', v_cidade_id, v_poste_id,
     'ALLOCATED_COST', 'POR_POSTE', 1.0,
     'Valor literal da planilha (seção 8). Rateável por poste/km/fibra/porta (seção 10) — app.ratear_custo() calcula R$/unidade sob demanda.', v_admin_id);

  -- Link 1Gbps (R$1.500/mês): uplink da OPERAÇÃO ATUAL da Prefeitura/atendimento próprio
  -- de Jussara — continua existindo com ou sem qualquer parceiro novo. EXISTING_OPEX,
  -- nunca repassado como "custo incremental" de um parceiro dark fiber (seção 7/8).
  insert into public.custos_infraestrutura
    (descricao, valor, periodicidade, cidade_id, cost_type, percentual_alocacao, observacoes, criado_por)
  values
    ('Link 1Gbps — operação atual (atendimento Prefeitura/intranet)', 1500.00, 'MENSAL', v_cidade_id,
     'EXISTING_OPEX', 1.0, 'Existe independente de qualquer parceiro novo — não é custo incremental (seção 7).', v_admin_id);

  -- Manutenção terceirizada (R$500/mês): idem — operação já existente.
  insert into public.custos_infraestrutura
    (descricao, valor, periodicidade, cidade_id, cost_type, percentual_alocacao, observacoes, criado_por)
  values
    ('Equipe de manutenção terceirizada — rede Jussara', 500.00, 'MENSAL', v_cidade_id,
     'EXISTING_OPEX', 1.0, 'Manutenção da rede já existente, independe de novos parceiros (seção 7).', v_admin_id);

  -- Contrato da Prefeitura (R$11.000/mês): RECEITA, nunca custo — só para dar contexto
  -- econômico completo da operação (seção 8 lista o valor; seção 9 tem o tipo dedicado).
  insert into public.custos_infraestrutura
    (descricao, valor, periodicidade, cidade_id, cost_type, percentual_alocacao, observacoes, criado_por)
  values
    ('Contrato Prefeitura Municipal de Jussara — 22 pontos, 500Mbps internet + 1Gbps LAN-to-LAN', 11000.00, 'MENSAL', v_cidade_id,
     'REVENUE_EXISTING', 1.0, 'Receita já existente — nunca somada aos custos do parceiro (seção 8/9). Fibras 1-2 (par 1) permanecem BLOQUEADAS para este uso (seção 8/seed Fase 1).', v_admin_id);

  -- Nenhum HISTORICAL_CAPEX é semeado aqui: o prompt não informa o valor de implantação
  -- original da rede (seção 8 não lista esse número) — seção 65 proíbe inventar um valor
  -- econômico não definido. A estrutura (cost_type HISTORICAL_CAPEX) já existe e aceita
  -- o valor assim que o negócio o informar.

  ------------------------------------------------------------------
  -- 2) Cenário 1 — Dark Fiber (seções 5, 43): 1 par livre (fibras 11+12, par 6) de
  -- CABO-JUSSARA-01, vendido como fibra escura pura.
  ------------------------------------------------------------------
  select id into v_fibra_par6_a from public.infra_fibras where cabo_id = v_cabo1_id and numero_fibra = 11;
  select id into v_fibra_par6_b from public.infra_fibras where cabo_id = v_cabo1_id and numero_fibra = 12;

  insert into public.parceiros (razao_social, cnpj) values ('Parceiro Dark Fiber Jussara D LTDA', '11222333000505')
  returning id into v_parceiro_dark;

  insert into public.contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status, data_inicio)
  values ('0005', v_parceiro_dark, v_cidade_id, 'DARK_FIBER', 48, 'ATIVO', current_date)
  returning id into v_contrato_dark;

  insert into public.contrato_fibras (contrato_id, fibra_id) values (v_contrato_dark, v_fibra_par6_a);
  insert into public.contrato_fibras (contrato_id, fibra_id) values (v_contrato_dark, v_fibra_par6_b);

  insert into public.contrato_regras (contrato_id, exclusividade_comercial) values (v_contrato_dark, false);

  -- margem_minima_percent/fator_risco_percent: valores DE EXEMPLO só para este cenário de
  -- teste ter uma saída numérica de referência — livremente editáveis, nunca um "valor
  -- oficial" da política comercial (que continua PARAMETRIZÁVEL/A DEFINIR por padrão —
  -- seção 65 — quando nenhum contrato os especifica).
  insert into public.contrato_pricing_config
    (contrato_id, modelo_cobranca, metodo_precificacao_dark_fiber, margem_minima_percent, fator_risco_percent, payback_minimo_meses)
  values
    (v_contrato_dark, 'MAX', 'POR_FIBRA', 0.15, 0.05, 24);

  ------------------------------------------------------------------
  -- 3) Cenário 2 — Porta PON + Revenue Share (seções 15, 43, 56): 1 Porta PON, 128
  -- clientes de capacidade, mínimo R$1.000 (parametrizado — HIBRIDO_FIXO_MES já existia
  -- desde a Fase 1), revenue share 12% (padrão desde a Fase 1.2). ARPU e a curva de
  -- clientes (10/25/50/75/100/128) são parâmetros de SIMULAÇÃO — passados na hora de
  -- chamar app.simular_projecao(), não persistidos aqui (seção 22: "o simulador deverá
  -- permitir informar" — é entrada do usuário, não um dado fixo do contrato).
  ------------------------------------------------------------------
  select id into v_fibra_porta from public.infra_fibras where cabo_id = v_cabo1_id and numero_fibra = 10;

  insert into public.parceiros (razao_social, cnpj) values ('Parceiro Porta PON Jussara E LTDA', '11222333000686')
  returning id into v_parceiro_pon;

  insert into public.contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status, data_inicio)
  values ('0006', v_parceiro_pon, v_cidade_id, 'HIBRIDO_REVENUE_SHARE', 48, 'ATIVO', current_date)
  returning id into v_contrato_pon;

  insert into public.infra_portas_pon (fibra_id, pop_id, nome, codigo_porta, tecnologia, capacidade_max_assinantes)
  values (v_fibra_porta, v_pop1_id, 'Porta Parceiro E — cenário econômico Fase 2', 'PON-JUS-006', 'GPON', 128)
  returning id into v_porta_id;

  insert into public.contrato_fibras (contrato_id, fibra_id, porta_pon_id) values (v_contrato_pon, v_fibra_porta, v_porta_id);

  insert into public.contrato_regras (contrato_id, exclusividade_comercial) values (v_contrato_pon, false);

  insert into public.contrato_pricing_config
    (contrato_id, modelo_cobranca, modelo_minimo, mensalidade_minima_porta, percentual_revenue_share, margem_minima_parceiro_percent)
  values
    (v_contrato_pon, 'SOMA', 'GLOBAL', 1000.00, 0.12, 0.20);

  raise notice 'Seed Fase 2 aplicado. custo(postes/link/manutencao/prefeitura) classificados; contrato_dark=% (0005, par 6 livre); contrato_pon=% (0006, PON-JUS-006, 128 capacidade).', v_contrato_dark, v_contrato_pon;
end $$;
