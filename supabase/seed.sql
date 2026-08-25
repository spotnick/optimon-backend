-- OptiMon — Seed do primeiro caso real (Jussara-PR), seções 7 e 43 do Prompt Mestre.
-- Roda por cima das migrations da Fase 1. Não inclui nenhum contrato de parceiro
-- (ainda não há parceiro onboardado) — só a infraestrutura e a reserva da Prefeitura.

do $$
declare
  v_admin_auth_id uuid;
  v_admin_id uuid;
  v_cidade_id uuid;
  v_segmento_id uuid;
  v_cabo_id uuid;
  i integer;
  v_par integer;
begin
  -- Usuário administrador de exemplo.
  -- Em Supabase real, este id vem de um usuário já criado via Supabase Auth
  -- (supabase.auth.admin.createUser ou signup) — aqui simulamos via o shim de dev.
  insert into auth.users (email) values ('admin@optimon.local')
  returning id into v_admin_auth_id;

  insert into public.usuarios (id, nome, email, perfil)
  values (v_admin_auth_id, 'Administrador OptiMon', 'admin@optimon.local', 'ADMINISTRADOR')
  returning id into v_admin_id;

  -- Cidade
  insert into public.cidades_infra (nome, uf, km_rede, observacoes)
  values ('Jussara', 'PR', 5, 'Primeiro caso real de implantação do OptiMon.')
  returning id into v_cidade_id;

  -- Segmento único cobrindo toda a rede da cidade nesta fase inicial.
  insert into public.infra_segmentos (cidade_id, nome, origem, destino, extensao_km)
  values (v_cidade_id, 'Rede Jussara - troncal principal', 'POP Jussara', 'Limite urbano', 5)
  returning id into v_segmento_id;

  -- Cabo de 12 fibras.
  insert into public.infra_cabos (segmento_id, identificacao, capacidade_fo)
  values (v_segmento_id, 'CABO-JUSSARA-01', 12)
  returning id into v_cabo_id;

  -- 12 fibras: pares 1..6. Par 1 (fibras 1 e 2) reservado para a Prefeitura -> BLOQUEADA.
  -- Pares 2..6 (fibras 3..12) ficam LIVRE = 10 fibras ociosas = 5 pares disponíveis.
  for i in 1..12 loop
    v_par := ceil(i / 2.0);
    insert into public.infra_fibras (cabo_id, numero_fibra, par_numero, status, observacao)
    values (
      v_cabo_id,
      i,
      v_par,
      case when v_par = 1 then 'BLOQUEADA' else 'LIVRE' end::fibra_status,
      case when v_par = 1 then 'Uso da Prefeitura Municipal de Jussara — não disponível a parceiros.' else null end
    );
  end loop;

  -- Postes (lote único, custo agregado mensal conforme planilha).
  insert into public.infra_postes (cidade_id, segmento_id, identificacao, proprietario_terceiro, quantidade, custo_mensal)
  values (v_cidade_id, v_segmento_id, 'Lote de postes - rede Jussara', 'Concessionária local de energia', 165, 1108.80);

  -- Parâmetros de pricing de referência (seção 8, 9, 10, 43 — nada hard-coded no backend).
  insert into public.pricing_parametros (chave, valor, unidade, descricao, criado_por) values
    ('DARK_FIBER_PRECO_MINIMO_PAR_MES', 1500, 'BRL', 'Preço mínimo por par/mês — Cenário 1 (Dark Fiber).', v_admin_id),
    ('DARK_FIBER_PRECO_PAR_KM_MES', 300, 'BRL', 'Preço por par-km/mês — Cenário 1 (Dark Fiber).', v_admin_id),
    ('DARK_FIBER_MULTIPLICADOR_RECOMENDADO', 1.20, 'x', 'Preço recomendado = mínimo × este fator.', v_admin_id),
    ('DARK_FIBER_MULTIPLICADOR_PREMIUM', 1.50, 'x', 'Preço premium = mínimo × este fator.', v_admin_id),
    ('HIBRIDO_FIXO_MES', 1000, 'BRL', 'Parcela fixa mensal — Cenário 2 (Fibra + OLT + Revenue Share).', v_admin_id),
    ('HIBRIDO_REVENUE_SHARE_PCT', 0.12, '%', 'Percentual de Revenue Share sobre o faturamento bruto do parceiro.', v_admin_id),
    ('HIBRIDO_VALOR_MINIMO_CLIENTE', 12, 'BRL', 'Valor mínimo por cliente para cálculo de Take-or-Pay.', v_admin_id),
    ('HIBRIDO_CLIENTES_MINIMO_TAKE_OR_PAY', 100, 'clientes', 'Quantidade mínima de clientes para Take-or-Pay.', v_admin_id),
    ('RAMPA_MESES_1_3_PCT', 0.50, '%', 'Fator de rampa de maturação — meses 1 a 3.', v_admin_id),
    ('RAMPA_MESES_4_6_PCT', 0.75, '%', 'Fator de rampa de maturação — meses 4 a 6.', v_admin_id),
    ('RAMPA_MES_7_MAIS_PCT', 1.00, '%', 'Fator de rampa de maturação — mês 7 em diante.', v_admin_id),
    ('CONTRATO_PRAZO_MINIMO_MESES', 48, 'meses', 'Prazo mínimo padrão de contrato (seção 11).', v_admin_id);

  raise notice 'Seed Jussara-PR aplicado. cidade_id=%, cabo_id=%', v_cidade_id, v_cabo_id;
end $$;
