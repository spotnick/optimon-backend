-- OptiMon — Seed complementar da Fase 1.2.
-- NÃO mexe em supabase/seed.sql nem supabase/seed_fase11.sql — roda por cima dos dois,
-- depois das migrations da Fase 1.2. Demonstra: cliente_porta_pon (clientes reais
-- consumindo capacidade da porta), modelo SOMA como padrão quando não especificado,
-- mínimo cobrado sobre portas reservadas (seção 6), compartilhamento aprovado por
-- ADMINISTRADOR, e aditivo do novo tipo ALTERACAO_CAPACIDADE.

do $$
declare
  v_admin_id uuid;
  v_cidade_id uuid;
  v_pop1_id uuid;
  v_cabo1_id uuid;
  v_fibra_fo07 uuid;
  v_fibra_fo09 uuid;
  v_porta4_id uuid;
  v_porta5_id uuid;
  v_parceiro_b uuid;
  v_parceiro_c uuid;
  v_contrato_b uuid;
  v_contrato_c uuid;
begin
  select id into v_admin_id from public.usuarios where perfil = 'ADMINISTRADOR' order by criado_em limit 1;
  select id into v_cidade_id from public.cidades_infra where nome = 'Jussara' and uf = 'PR';
  select id into v_cabo1_id from public.infra_cabos where identificacao = 'CABO-JUSSARA-01';
  select pop_id into v_pop1_id from public.infra_cabos where identificacao = 'CABO-JUSSARA-01';
  select id into v_fibra_fo07 from public.infra_fibras where cabo_id = v_cabo1_id and numero_fibra = 7;
  select id into v_fibra_fo09 from public.infra_fibras where cabo_id = v_cabo1_id and numero_fibra = 9;
  select id into v_parceiro_b from public.parceiros where razao_social = 'Parceiro Fibra Jussara B LTDA';
  select id into v_contrato_b from public.contratos where numero = '0003';

  if v_admin_id is null or v_cabo1_id is null or v_contrato_b is null then
    raise exception 'Seed da Fase 1.2 depende dos seeds da Fase 1 e da Fase 1.1 já terem sido aplicados.';
  end if;

  -- Nova porta PON-JUS-004 (FO07/POP-01), vinculada ao contrato 0003 (Parceiro B, que já
  -- usava PON-JUS-002) — demonstra um contrato crescendo por aditivo sem par (seção 1).
  insert into public.infra_portas_pon (fibra_id, pop_id, nome, codigo_porta, tecnologia)
  values (v_fibra_fo07, v_pop1_id, 'Porta Parceiro B — POP-01 (2ª porta)', 'PON-JUS-004', 'GPON')
  returning id into v_porta4_id;

  insert into public.contrato_aditivos (contrato_id, numero, tipo, descricao, inicio_vigencia, status, snapshot_anterior, snapshot_novo, aprovado_por, aprovado_em)
  values (
    v_contrato_b, 1, 'ALTERACAO_CAPACIDADE',
    'Inclusão da porta PON-JUS-004 (FO07/POP-01) — Parceiro B expande capacidade contratada (seção 15).',
    current_date, 'APROVADO',
    jsonb_build_object('portas', jsonb_build_array('PON-JUS-002')),
    jsonb_build_object('portas', jsonb_build_array('PON-JUS-002', 'PON-JUS-004')),
    v_admin_id, now()
  );

  insert into public.contrato_fibras (contrato_id, fibra_id, porta_pon_id, capacidade_clientes, observacoes)
  values (v_contrato_b, v_fibra_fo07, v_porta4_id, 128, 'Incluída via aditivo 001 da Fase 1.2 — 2ª porta do Parceiro B.');

  -- Clientes reais na nova porta (seção 11/12) — PENDENTE não conta capacidade,
  -- ATIVO conta, CANCELADO deixa de contar. capacidade_utilizada_assinantes/
  -- situacao_comercial da porta são recalculados automaticamente pelos triggers.
  insert into public.cliente_porta_pon (cliente_identificador, cliente_hubsoft_id, contrato_id, porta_pon_id, pop_id, fibra_id, status, origem)
  values
    ('CLIENTE-JUS-1001', null, v_contrato_b, v_porta4_id, v_pop1_id, v_fibra_fo07, 'ATIVO', 'MANUAL'),
    ('CLIENTE-JUS-1002', 'HS-88291', v_contrato_b, v_porta4_id, v_pop1_id, v_fibra_fo07, 'ATIVO', 'HUBSOFT'),
    ('CLIENTE-JUS-1003', null, v_contrato_b, v_porta4_id, v_pop1_id, v_fibra_fo07, 'PENDENTE', 'MANUAL');

  -- Terceiro parceiro/contrato: dark fiber pura, SEM especificar modelo_cobranca em
  -- contrato_pricing_config — demonstra o DEFAULT SOMA da Fase 1.2 (seção 3, Teste 3) e
  -- cobranca_portas_reservadas=true cobrando sobre a porta contratada mesmo antes de ter
  -- clientes (seção 6).
  insert into public.parceiros (razao_social, cnpj)
  values ('Parceiro Dark Fiber Jussara C LTDA', '11222333000343')
  returning id into v_parceiro_c;

  insert into public.contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status, data_inicio)
  values ('0004', v_parceiro_c, v_cidade_id, 'DARK_FIBER', 48, 'ATIVO', current_date)
  returning id into v_contrato_c;

  insert into public.infra_portas_pon (fibra_id, pop_id, nome, codigo_porta, tecnologia)
  values (v_fibra_fo09, v_pop1_id, 'Porta Parceiro C — POP-01', 'PON-JUS-005', 'GPON')
  returning id into v_porta5_id;

  insert into public.contrato_fibras (contrato_id, fibra_id, porta_pon_id, capacidade_clientes)
  values (v_contrato_c, v_fibra_fo09, v_porta5_id, 128);

  -- Sem informar modelo_cobranca: resolve para 'SOMA' pelo novo DEFAULT da coluna.
  insert into public.contrato_pricing_config (contrato_id, mensalidade_minima_porta)
  values (v_contrato_c, 1000);

  insert into public.contrato_regras (contrato_id, exclusividade_comercial)
  values (v_contrato_c, false);

  raise notice 'Seed Fase 1.2 aplicado. porta4=%, contrato_b=%, contrato_c=%, porta5=%', v_porta4_id, v_contrato_b, v_contrato_c, v_porta5_id;
end $$;
