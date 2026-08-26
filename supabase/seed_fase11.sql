-- OptiMon — Seed complementar da Fase 1.1.
-- NÃO mexe em supabase/seed.sql (Fase 1) — roda por cima dele, depois das migrations
-- da Fase 1.1. Demonstra POPs múltiplos, porta PON, fibra individual sem par,
-- contrato usando 2 POPs via aditivo, e os dois modelos de cobrança (A e B).

do $$
declare
  v_admin_id uuid;
  v_cidade_id uuid;
  v_pop1_id uuid;
  v_pop2_id uuid;
  v_cabo1_id uuid;
  v_cabo2_id uuid;
  v_segmento2_id uuid;
  v_fibra_fo03 uuid;
  v_fibra_fo05 uuid;
  v_fibra_pop2 uuid;
  v_porta1_id uuid;
  v_porta2_id uuid;
  v_porta3_id uuid;
  v_parceiro_a uuid;
  v_parceiro_b uuid;
  v_contrato_a uuid;
  v_contrato_b uuid;
begin
  select id into v_admin_id from public.usuarios where perfil = 'ADMINISTRADOR' order by criado_em limit 1;
  select id into v_cidade_id from public.cidades_infra where nome = 'Jussara' and uf = 'PR';
  select id into v_cabo1_id from public.infra_cabos where identificacao = 'CABO-JUSSARA-01';
  select pop_id into v_pop1_id from public.infra_cabos where identificacao = 'CABO-JUSSARA-01';
  select id into v_fibra_fo03 from public.infra_fibras where cabo_id = v_cabo1_id and numero_fibra = 3;
  select id into v_fibra_fo05 from public.infra_fibras where cabo_id = v_cabo1_id and numero_fibra = 5;

  if v_admin_id is null or v_cidade_id is null or v_cabo1_id is null then
    raise exception 'Seed da Fase 1.1 depende do seed da Fase 1 (supabase/seed.sql) já ter sido aplicado.';
  end if;

  -- POP-02: segundo POP da mesma cidade, com seu próprio segmento/cabo/fibras
  -- (fisicamente uma rota de distribuição distinta de POP-01 — seção 7 do prompt).
  insert into public.infra_pops (cidade_id, codigo, nome, tipo, observacoes)
  values (v_cidade_id, 'POP-02', 'POP-02 — Distribuição Setor Norte', 'DISTRIBUICAO', 'Criado no seed da Fase 1.1 para demonstrar múltiplos POPs por cidade.')
  returning id into v_pop2_id;

  insert into public.infra_segmentos (cidade_id, nome, origem, destino, extensao_km)
  values (v_cidade_id, 'Ramal POP-02', 'POP-02', 'Setor Norte', 1.2)
  returning id into v_segmento2_id;

  insert into public.infra_cabos (segmento_id, pop_id, identificacao, capacidade_fo)
  values (v_segmento2_id, v_pop2_id, 'CABO-JUSSARA-02', 6)
  returning id into v_cabo2_id;

  insert into public.infra_fibras (cabo_id, numero_fibra, par_numero, status, status_operacional, status_comercial, status_contratual)
  select v_cabo2_id, gs, ceil(gs / 2.0), 'LIVRE', 'ATIVA', 'LIVRE', 'DISPONIVEL'
  from generate_series(1, 6) gs;

  select id into v_fibra_pop2 from public.infra_fibras where cabo_id = v_cabo2_id and numero_fibra = 1;

  -- Portas PON: FO03 e FO05 do cabo original (POP-01), conforme o exemplo do próprio
  -- prompt de Fase 1.1 ("FO 03 → Porta PON Parceiro A", "FO 05 → Porta PON Parceiro B").
  insert into public.infra_portas_pon (fibra_id, pop_id, nome, codigo_porta, tecnologia, capacidade_utilizada_assinantes)
  values (v_fibra_fo03, v_pop1_id, 'Porta Parceiro A — POP-01', 'PON-JUS-001', 'GPON', 10)
  returning id into v_porta1_id;

  insert into public.infra_portas_pon (fibra_id, pop_id, nome, codigo_porta, tecnologia, capacidade_utilizada_assinantes)
  values (v_fibra_fo05, v_pop1_id, 'Porta Parceiro B — POP-01', 'PON-JUS-002', 'GPON', 100)
  returning id into v_porta2_id;

  insert into public.infra_portas_pon (fibra_id, pop_id, nome, codigo_porta, tecnologia, capacidade_utilizada_assinantes)
  values (v_fibra_pop2, v_pop2_id, 'Porta Parceiro A — POP-02', 'PON-JUS-003', 'GPON', 0)
  returning id into v_porta3_id;

  -- Parceiros e contratos — cada um com 1 fibra individual (não par!), 48 meses.
  insert into public.parceiros (razao_social, cnpj)
  values ('Parceiro Fibra Jussara A LTDA', '11222333000181')
  returning id into v_parceiro_a;

  insert into public.parceiros (razao_social, cnpj)
  values ('Parceiro Fibra Jussara B LTDA', '11222333000262')
  returning id into v_parceiro_b;

  insert into public.contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status, data_inicio)
  values ('0002', v_parceiro_a, v_cidade_id, 'HIBRIDO_REVENUE_SHARE', 48, 'ATIVO', current_date)
  returning id into v_contrato_a;

  insert into public.contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status, data_inicio)
  values ('0003', v_parceiro_b, v_cidade_id, 'HIBRIDO_REVENUE_SHARE', 48, 'ATIVO', current_date)
  returning id into v_contrato_b;

  -- Vínculo fibra individual + porta (sem exigir segunda fibra para formar par).
  insert into public.contrato_fibras (contrato_id, fibra_id, porta_pon_id, capacidade_clientes)
  values (v_contrato_a, v_fibra_fo03, v_porta1_id, 128);

  insert into public.contrato_fibras (contrato_id, fibra_id, porta_pon_id, capacidade_clientes)
  values (v_contrato_b, v_fibra_fo05, v_porta2_id, 128);

  -- Modelo A (MAX) para o contrato de Parceiro A; Modelo B (SOMA) para Parceiro B —
  -- demonstra que a fórmula é definida por contrato, não fixa no sistema (seção 4).
  insert into public.contrato_pricing_config (contrato_id, modelo_cobranca, base_calculo_revenue_share, modelo_minimo, rampa_aplica_a, mensalidade_minima_porta, percentual_revenue_share)
  values (v_contrato_a, 'MAX', 'FATURAMENTO_BRUTO', 'POR_PORTA', 'FIXO_MINIMO', 1000, 0.12);

  insert into public.contrato_pricing_config (contrato_id, modelo_cobranca, base_calculo_revenue_share, modelo_minimo, rampa_aplica_a, mensalidade_minima_porta, percentual_revenue_share)
  values (v_contrato_b, 'SOMA', 'FATURAMENTO_ELEGIVEL', 'GLOBAL', 'AMBOS', 1000, 0.12);

  -- Exclusividade escopada: Parceiro A é exclusivo só no POP-01 (não na cidade toda) e
  -- o proprietário permite outros parceiros mediante aprovação — exemplo literal da
  -- seção 19 (POP-02 deve dar ALLOW; POP-01 deve dar REQUIRES_APPROVAL).
  insert into public.contrato_regras (contrato_id, exclusividade_comercial, exclusividade_cidade_id, exclusividade_pop_id, permite_outros_parceiros, direito_proprietario_explorar_capacidade_remanescente)
  values (v_contrato_a, true, v_cidade_id, v_pop1_id, true, true);

  insert into public.contrato_regras (contrato_id, exclusividade_comercial)
  values (v_contrato_b, false);

  -- Meta de rampa (seção 20) — sem assumir rescisão automática.
  insert into public.contrato_metas (contrato_id, periodo_inicio, periodo_fim, clientes_minimos, ocupacao_minima, consequencia, status)
  values (v_contrato_a, current_date, current_date + interval '3 months', 10, 0.05, 'SEM_CONSEQUENCIA', 'ATIVA');
  insert into public.contrato_metas (contrato_id, periodo_inicio, periodo_fim, clientes_minimos, ocupacao_minima, consequencia, status)
  values (v_contrato_a, current_date + interval '6 months', current_date + interval '48 months', 60, 0.40, 'RENEGOCIACAO', 'ATIVA');

  -- Aditivo: Parceiro A cresce e passa a usar também uma porta em POP-02 — histórico
  -- preservado, nova versão gerada automaticamente ao aprovar (seção 11/37).
  insert into public.contrato_aditivos (contrato_id, numero, tipo, descricao, inicio_vigencia, status, snapshot_anterior, snapshot_novo, aprovado_por, aprovado_em)
  values (
    v_contrato_a, 1, 'INCLUSAO_PORTA',
    'Inclusão da porta PON-JUS-003 (POP-02) ao contrato — expansão de capacidade do Parceiro A.',
    current_date, 'APROVADO',
    jsonb_build_object('portas', jsonb_build_array('PON-JUS-001')),
    jsonb_build_object('portas', jsonb_build_array('PON-JUS-001', 'PON-JUS-003')),
    v_admin_id, now()
  );

  insert into public.contrato_fibras (contrato_id, fibra_id, porta_pon_id, capacidade_clientes, observacoes)
  values (v_contrato_a, v_fibra_pop2, v_porta3_id, 128, 'Incluída via aditivo 001 — contrato agora usa portas em 2 POPs distintos.');

  raise notice 'Seed Fase 1.1 aplicado. pop2=%, contrato_a=%, contrato_b=%', v_pop2_id, v_contrato_a, v_contrato_b;
end $$;
