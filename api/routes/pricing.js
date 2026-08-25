// OptiMon Pricing API — rotas do Pricing Engine (seção 50).
//
// Cada handler é deliberadamente fino: valida a entrada, chama UM wrapper SQL
// (public.pricing_*, ver supabase/migrations/20260827100900_phase_2_10_api_public_wrappers.sql)
// e devolve o resultado. Toda a lógica de negócio (fórmulas, governança, RBAC) vive no
// banco — a API nunca decide preço nem contorna aprovação, só encaminha (seção 51: as
// "engines" são os serviços SQL, não este arquivo).

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');
const { calculatePricing } = require('../lib/calculatePricing');

const router = express.Router();

function handleSupabaseError(res, error, opts = {}) {
  // Nunca vazar detalhes internos (stack trace, connection string) — só a mensagem que o
  // Postgres already formatou para o usuário final (ex.: "REQUIRES_APPROVAL: ...",
  // "BLOCK: ...", vindas de RAISE EXCEPTION nas próprias funções/triggers).
  const message = error?.message || 'Erro inesperado no Pricing Engine.';
  // Fase 2.2.1 (seção 14/35): "Comercial: 403/BLOCKED" ao tentar executar uma decisão de
  // override. REQUIRES_APPROVAL é sempre um problema de PERMISSÃO (papel errado) — mapeia
  // para 403. BLOCK (o piso absoluto de 50% de desconto, ou o BLOCK de governança
  // tri-state da Fase 2.2) é uma regra de NEGÓCIO sobre o preço em si, não sobre quem está
  // pedindo — continua 409, como antes desta fase (nenhum comportamento antigo muda).
  let status;
  if (/REQUIRES_APPROVAL/i.test(message)) {
    status = 403;
  } else if (/BLOCK|not-found|não encontrad/i.test(message)) {
    status = 409;
  } else {
    status = 400;
  }
  // opts.role (Fase 2.2.1): quando a chamada aconteceu com "0 linhas afetadas" e nenhuma
  // mensagem de erro específica (ex.: RLS filtrou silenciosamente a UPDATE de um override
  // já decidido/de outro usuário, sem passar pelo trigger) E o papel de quem chamou é
  // COMERCIAL, tratamos como um bloqueio de permissão (403) também — evita que Comercial
  // receba um 409 genérico "não encontrado" quando o motivo real é não poder decidir.
  if (opts.role === 'COMERCIAL' && /não encontrad/i.test(message)) {
    status = 403;
  }
  return res.status(status).json({ error: message });
}

// POST /api/pricing/calculate — Pricing Engine centralizado (seção 32/35). Corpo:
// {cidade_id, pop_id?, clientes, arpu, faturamento?, revenue_share_pct?, composicao_mode?,
// preco_proposto?, pons_count?, pricing_version?}. Nunca confia em floor/recomendado/
// governança vindos do cliente — sempre recalcula tudo no banco (seção 33). É a rota que
// alimenta a tela "NOVA SIMULAÇÃO" (seção 22) e os botões rápidos de clientes (seção 23).
router.post('/calculate', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await calculatePricing(supabase, req.body || {});
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// POST /api/pricing/simulate — ScenarioSimulator (seções 37, 51).
router.post('/simulate', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_simulate', { p_params: req.body });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/projection — mesma projeção, verbo GET com params na query (?params=<json>).
router.get('/projection', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  let params;
  try {
    params = JSON.parse(req.query.params || '{}');
  } catch {
    return res.status(400).json({ error: 'query param "params" precisa ser um JSON válido.' });
  }
  const { data, error } = await supabase.rpc('pricing_projection', { p_params: params });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/roi — ROI nos horizontes pedidos (default 12/36/48/60 — seção 31).
router.get('/roi', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  let projecao;
  try {
    projecao = JSON.parse(req.query.projecao);
  } catch {
    return res.status(400).json({ error: 'query param "projecao" precisa ser o jsonb devolvido por /simulate.' });
  }
  const investimento = Number(req.query.investimento || 0);
  const meses = req.query.meses ? req.query.meses.split(',').map(Number) : [12, 36, 48, 60];

  const [roiResp, paybackResp] = await Promise.all([
    supabase.rpc('pricing_roi', { p_projecao: projecao, p_investimento: investimento, p_meses: meses }),
    supabase.rpc('pricing_payback', { p_projecao: projecao, p_investimento: investimento }),
  ]);
  if (roiResp.error) return handleSupabaseError(res, roiResp.error);
  if (paybackResp.error) return handleSupabaseError(res, paybackResp.error);

  return res.json({ roi: roiResp.data, payback: paybackResp.data });
});

// POST /api/pricing/quote — preço mínimo/recomendado/premium + governança (seções 36, 49).
router.post('/quote', async (req, res) => {
  const { contrato_id, preco_proposto } = req.body || {};
  if (!contrato_id) return res.status(400).json({ error: 'contrato_id é obrigatório.' });

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_quote', {
    p_contrato_id: contrato_id,
    p_preco_proposto: preco_proposto ?? null,
  });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// POST /api/pricing/override — Comercial solicita preço diferente do recomendado (seção
// 48). preco_piso/preco_abertura são opcionais (Fase 2.2, seção 40): preenchidos quando o
// override é sobre uma negociação abaixo do Infrastructure Floor, para a auditoria
// carregar a régua inteira (abertura/recomendado/piso) no momento da solicitação. pop_id
// é opcional (Fase 2.2.1, seção 15/23): quando a negociação é por POP específico — o
// banco valida que o POP pertence à mesma cidade do contrato.
router.post('/override', async (req, res) => {
  const { contrato_id, simulacao_id, preco_recomendado, preco_solicitado, justificativa, preco_piso, preco_abertura, pop_id } = req.body || {};
  if (!contrato_id || preco_recomendado == null || preco_solicitado == null || !justificativa) {
    return res.status(400).json({ error: 'contrato_id, preco_recomendado, preco_solicitado e justificativa são obrigatórios.' });
  }

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_override_create', {
    p_contrato_id: contrato_id,
    p_simulacao_id: simulacao_id ?? null,
    p_preco_recomendado: preco_recomendado,
    p_preco_solicitado: preco_solicitado,
    p_justificativa: justificativa,
    p_preco_piso: preco_piso ?? null,
    p_preco_abertura: preco_abertura ?? null,
    p_pop_id: pop_id ?? null,
  });
  if (error) return handleSupabaseError(res, error);
  return res.status(201).json({ override_id: data });
});

// POST /api/pricing/approve — decisão exige DIRETOR/ADMINISTRADOR (ou FINANCEIRO com
// permissão explícita — RLS + trigger, seção 35/49 da Fase 2.2.1). A regra em si continua
// só no banco (fonte única de verdade) — a API só consulta o papel do próprio chamador
// (public.pricing_current_user_role(), seção 14) para decidir, em cima de um erro que o
// banco já produziu, se o envelope HTTP certo é 403 (Comercial sem permissão) ou 409
// (regra de negócio, ex.: abaixo do piso absoluto de desconto).
router.post('/approve', async (req, res) => {
  const { override_id, aprovar, observacao } = req.body || {};
  if (!override_id || typeof aprovar !== 'boolean') {
    return res.status(400).json({ error: 'override_id e aprovar (boolean) são obrigatórios.' });
  }

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_override_approve', {
    p_override_id: override_id,
    p_aprovar: aprovar,
    p_observacao: observacao ?? null,
  });
  if (error) {
    const { data: role } = await supabase.rpc('pricing_current_user_role');
    return handleSupabaseError(res, error, { role });
  }
  return res.json(data);
});

// GET /api/pricing/versions?contrato_id=... — histórico imutável de pricing (seção 46).
router.get('/versions', async (req, res) => {
  const { contrato_id } = req.query;
  if (!contrato_id) return res.status(400).json({ error: 'contrato_id é obrigatório.' });

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_versions_list', { p_contrato_id: contrato_id });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/scenarios?contrato_id=... — simulações salvas (seção 50).
router.get('/scenarios', async (req, res) => {
  const { contrato_id } = req.query;
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_scenarios_list', { p_contrato_id: contrato_id ?? null });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/capacity-by-pop?contrato_id=... — capacidade por POP + consolidado de
// um contrato específico (seção 12/50, Fase 2.1) — apoia a visão Multi-POP do dashboard.
router.get('/capacity-by-pop', async (req, res) => {
  const { contrato_id } = req.query;
  if (!contrato_id) return res.status(400).json({ error: 'contrato_id é obrigatório.' });

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_capacity_by_pop', { p_contrato_id: contrato_id });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/infrastructure-floor?cidade_id=...&pop_id=...&pricing_version=...&pons_count=...
// — Infrastructure Floor / Piso de Infraestrutura (seção 21, Fase 2.2; seção 3/6-8 da
// Fase 2.2.1 adiciona o componente PON): piso/recomendado/abertura calculados a partir de
// postes + metros de rede + Portas PON. pop_id, pricing_version e pons_count são
// opcionais (sem pop_id = consolidado da cidade; sem pricing_version = vigência atual;
// sem pons_count = 0, preserva chamadas que só querem postes+metros — seção 19).
router.get('/infrastructure-floor', async (req, res) => {
  const { cidade_id, pop_id, pricing_version, pons_count } = req.query;
  if (!cidade_id) return res.status(400).json({ error: 'cidade_id é obrigatório.' });

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_infrastructure_floor', {
    p_cidade_id: cidade_id,
    p_pop_id: pop_id ?? null,
    p_pricing_version: pricing_version ?? null,
    p_pons_count: pons_count !== undefined ? Number(pons_count) : null,
  });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/infra-floor-negotiation?preco_proposto=...&cidade_id=...&pop_id=...&pricing_version=...&pons_count=...
// — régua comercial completa (seções 9-11, 20, 37-39, Fase 2.2; seção 12/13/33-35 da Fase
// 2.2.1 adiciona governança por papel e o limite de override): posição na régua,
// governança tri-state (ALLOW/ALLOW_WITH_DISCOUNT/BLOCK) e governança por papel
// (ALLOW/ALLOW_WITH_DISCOUNT/BLOCK_FOR_COMMERCIAL/ALLOW_WITH_DIRECTOR_OVERRIDE/BLOCK),
// desconto sobre abertura e sobre recomendado, diferença sobre o piso e sobre o
// recomendado, preço mínimo autorizável — a "função comercial" da tela de preço proposto.
router.get('/infra-floor-negotiation', async (req, res) => {
  const { preco_proposto, cidade_id, pop_id, pricing_version, pons_count } = req.query;
  if (preco_proposto === undefined || !cidade_id) {
    return res.status(400).json({ error: 'preco_proposto e cidade_id são obrigatórios.' });
  }

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_infra_floor_negotiation', {
    p_preco_proposto: Number(preco_proposto),
    p_cidade_id: cidade_id,
    p_pop_id: pop_id ?? null,
    p_pricing_version: pricing_version ?? null,
    p_pons_count: pons_count !== undefined ? Number(pons_count) : null,
  });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/current-role — papel do usuário autenticado (seção 14/35, Fase
// 2.2.1). Apoia UI role-aware no dashboard (ex.: mostrar aviso "Comercial não pode
// aprovar override" antes mesmo de tentar) — nunca a fonte de verdade da permissão, só
// uma conveniência de exibição; a decisão real acontece sempre no banco.
router.get('/current-role', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_current_user_role');
  if (error) return handleSupabaseError(res, error);
  return res.json({ role: data });
});

// GET /api/pricing/economics-with-floor?contrato_id=...&faturamento_parceiro=...&pop_id=...&pricing_version=...
// — comparação econômica completa (seção 17/30, Fase 2.2): Infrastructure Floor, Minimum
// Contractual Fee, Revenue Share, Total a Pagar, Receita OptiMon/Parceiro, Margem do
// Parceiro — composição nunca soma Floor+Mínimo por acidente (seção 32).
router.get('/economics-with-floor', async (req, res) => {
  const { contrato_id, faturamento_parceiro, pop_id, pricing_version } = req.query;
  if (!contrato_id) return res.status(400).json({ error: 'contrato_id é obrigatório.' });

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_economics_with_floor', {
    p_contrato_id: contrato_id,
    p_faturamento_parceiro: Number(faturamento_parceiro || 0),
    p_pop_id: pop_id ?? null,
    p_pricing_version: pricing_version ?? null,
  });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/fibras-indicadores?cidade_id=...&pop_id=... — fibras totais/ocupadas/
// ociosas + Portas PON totais/disponíveis (seção 25, Fase 2.2). Não presume que toda a
// infraestrutura da cidade está locada.
router.get('/fibras-indicadores', async (req, res) => {
  const { cidade_id, pop_id } = req.query;
  if (!cidade_id) return res.status(400).json({ error: 'cidade_id é obrigatório.' });

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_fibras_indicadores', { p_cidade_id: cidade_id, p_pop_id: pop_id ?? null });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/capacity-multipop-floor?cidade_id=... — quebra do Infrastructure
// Floor por POP + consolidado da cidade (seção 24, Fase 2.2) — nunca duplica os metros.
router.get('/capacity-multipop-floor', async (req, res) => {
  const { cidade_id } = req.query;
  if (!cidade_id) return res.status(400).json({ error: 'cidade_id é obrigatório.' });

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_capacity_multipop_piso', { p_cidade_id: cidade_id });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// POST /api/pricing/growth-curve — série de pontos para os gráficos "CRESCIMENTO DA BASE
// × RECEITA OPTIMON" e "CLIENTES × PONs NECESSÁRIAS" (seção 24/25). Mesmo corpo de
// /calculate, mais clientes_max/passos opcionais.
router.post('/growth-curve', async (req, res) => {
  const { clientes_max, passos, ...params } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_growth_curve', {
    p_params: params,
    p_clientes_max: clientes_max ?? null,
    p_passos: passos ?? 20,
  });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// POST /api/pricing/horizon-table — tabela 12/36/48/60 meses (seção 26). Corpo:
// {...mesmo corpo de /calculate, capex?, opex_mensal?, horizontes?}.
router.post('/horizon-table', async (req, res) => {
  const { capex, opex_mensal, horizontes, ...params } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_horizon_table', {
    p_params: params,
    p_capex: capex ?? 0,
    p_opex_mensal: opex_mensal ?? 0,
    p_horizontes: horizontes ?? [12, 36, 48, 60],
  });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/ramp?contrato_id=... — regra de rampa (seção 27).
router.get('/ramp', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_ramp_rules_list', { p_contrato_id: req.query.contrato_id ?? null });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/indices?indice=IPCA&limit=12 — índices econômicos coletados (seção 28).
router.get('/indices', async (req, res) => {
  const { indice, limit } = req.query;
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_indices_list', { p_indice: indice ?? null, p_limit: limit ? Number(limit) : 12 });
  if (error) return handleSupabaseError(res, error);
  return res.json(data);
});

// GET /api/pricing/:id — busca um cálculo/simulação salvo por id (seção 31). Fica por
// ÚLTIMO de propósito: um path param genérico de 1 segmento (":id") casaria com
// /versions, /scenarios, /roi etc. se viesse antes — Express resolve rotas na ordem de
// registro, então todas as rotas GET literais acima precisam vir primeiro.
router.get('/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_simulation_get', { p_id: req.params.id });
  if (error) return handleSupabaseError(res, error);
  if (!data) return res.status(404).json({ error: `Simulação ${req.params.id} não encontrada.` });
  return res.json(data);
});

module.exports = router;
