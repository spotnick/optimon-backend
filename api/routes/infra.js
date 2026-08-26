// OptiMon Pricing API — rotas de Infraestrutura (Fase 2.3, seções 14-21).
//
// POP/segmento/poste/porta PON: INSERT/UPDATE diretos nas tabelas via supabase-js. A
// autorização real é a RLS de cada tabela (ENGENHARIA/ADMINISTRADOR escrevem, qualquer
// authenticated lê — já existente desde a Fase 1.1) e os triggers de auditoria (também já
// existentes ou adicionados nesta fase) cobrem o log de qualquer jeito — um wrapper SQL
// aqui só duplicaria a mesma checagem sem lógica de negócio nova (seção 13: "criar
// somente wrappers necessários"). Cabo é a exceção: cria fibras junto, numa transação —
// isso sim é lógica real, por isso usa o wrapper public.pricing_cable_create_with_fibers.

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (/PERMISSAO_NEGADA/i.test(message) || /row-level security/i.test(message)) {
    status = 403;
  } else if (/não encontrad/i.test(message)) {
    status = 404;
  } else {
    status = 400;
  }
  return res.status(status).json({ error: message });
}

// GET /api/infra/tree?cidade_id=... — árvore completa para "Editar Infraestrutura".
router.get('/tree', async (req, res) => {
  const { cidade_id } = req.query;
  if (!cidade_id) return res.status(400).json({ error: 'cidade_id é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_city_infra_tree', { p_cidade_id: cidade_id });
  if (error) return handleError(res, error);
  return res.json(data);
});

// ---------------------------------------------------------------------------------
// POPs (seção 14)
// ---------------------------------------------------------------------------------

router.post('/pops', async (req, res) => {
  const { cidade_id, codigo, nome, tipo, endereco, latitude, longitude, capacidade_total, status, observacoes } = req.body || {};
  if (!cidade_id || !codigo || !nome) {
    return res.status(400).json({ error: 'cidade_id, codigo e nome são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('infra_pops')
    .insert({ cidade_id, codigo, nome, tipo: tipo || 'ACESSO', endereco, latitude, longitude, capacidade_total, status: status || 'ATIVO', observacoes })
    .select()
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

router.patch('/pops/:id', async (req, res) => {
  const { codigo, nome, tipo, endereco, latitude, longitude, capacidade_total, status, observacoes } = req.body || {};
  const patch = {};
  for (const [k, v] of Object.entries({ codigo, nome, tipo, endereco, latitude, longitude, capacidade_total, status, observacoes })) {
    if (v !== undefined) patch[k] = v;
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_pops').update(patch).eq('id', req.params.id).select().single();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'POP não encontrado.' });
  return res.json(data);
});

// ---------------------------------------------------------------------------------
// Segmentos (seção 16)
// ---------------------------------------------------------------------------------

router.get('/segments', async (req, res) => {
  const { cidade_id } = req.query;
  if (!cidade_id) return res.status(400).json({ error: 'cidade_id é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_segmentos').select('*').eq('cidade_id', cidade_id).is('removido_em', null).order('nome');
  if (error) return handleError(res, error);
  return res.json(data);
});

router.post('/segments', async (req, res) => {
  const { cidade_id, nome, origem, destino, extensao_km } = req.body || {};
  if (!cidade_id || !nome || !origem || !destino || extensao_km == null) {
    return res.status(400).json({ error: 'cidade_id, nome, origem, destino e extensao_km são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('infra_segmentos')
    .insert({ cidade_id, nome, origem, destino, extensao_km })
    .select()
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// ---------------------------------------------------------------------------------
// Cabos + fibras (seções 15, 17) — via wrapper (gera as fibras juntas, 1 transação).
// ---------------------------------------------------------------------------------

router.post('/cables', async (req, res) => {
  const { segmento_id, identificacao, capacidade_fo, pop_id, fabricante } = req.body || {};
  if (!segmento_id || !identificacao || !capacidade_fo) {
    return res.status(400).json({ error: 'segmento_id, identificacao e capacidade_fo são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_cable_create_with_fibers', {
    p_segmento_id: segmento_id,
    p_identificacao: identificacao,
    p_capacidade_fo: capacidade_fo,
    p_pop_id: pop_id ?? null,
    p_fabricante: fabricante ?? null,
  });
  if (error) return handleError(res, error);
  return res.status(201).json({ cabo_id: data });
});

router.get('/cables/:id/fibers', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_fibras').select('*').eq('cabo_id', req.params.id).order('numero_fibra');
  if (error) return handleError(res, error);
  return res.json(data);
});

// PATCH /api/infra/fibers/:id — muda status/observação de UMA fibra (seção 17: LIVRE,
// OCUPADA, RESERVADA, LOCADA, MANUTENCAO, BLOQUEADA). Nunca usado para vincular contrato
// (isso passa por contrato_fibras, fora do escopo desta tela) — só estado operacional.
router.patch('/fibers/:id', async (req, res) => {
  const { status, observacao } = req.body || {};
  const patch = {};
  if (status !== undefined) patch.status = status;
  if (observacao !== undefined) patch.observacao = observacao;
  if (Object.keys(patch).length === 0) {
    return res.status(400).json({ error: 'Informe status e/ou observacao.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_fibras').update(patch).eq('id', req.params.id).select().single();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Fibra não encontrada.' });
  return res.json(data);
});

// ---------------------------------------------------------------------------------
// Postes (seção 18)
// ---------------------------------------------------------------------------------

router.post('/poles', async (req, res) => {
  const { cidade_id, segmento_id, identificacao, proprietario_terceiro, quantidade, custo_mensal } = req.body || {};
  if (!cidade_id || !quantidade) {
    return res.status(400).json({ error: 'cidade_id e quantidade são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('infra_postes')
    .insert({ cidade_id, segmento_id: segmento_id ?? null, identificacao, proprietario_terceiro, quantidade, custo_mensal: custo_mensal ?? 0 })
    .select()
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// ---------------------------------------------------------------------------------
// Portas PON (seção 19) — trigger fn_valida_porta_pon_pop já garante fibra/POP consistentes;
// trigger fn_porta_pon_default_capacidade já aplica os 128 padrão quando não informado.
// ---------------------------------------------------------------------------------

router.post('/pon-ports', async (req, res) => {
  const { fibra_id, pop_id, codigo_porta, nome, tecnologia, capacidade_max_assinantes, status } = req.body || {};
  if (!fibra_id || !pop_id || !codigo_porta) {
    return res.status(400).json({ error: 'fibra_id, pop_id e codigo_porta são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('infra_portas_pon')
    .insert({ fibra_id, pop_id, codigo_porta, nome, tecnologia: tecnologia || 'GPON', capacidade_max_assinantes: capacidade_max_assinantes ?? null, status: status || 'ATIVA' })
    .select()
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

router.patch('/pon-ports/:id', async (req, res) => {
  const { codigo_porta, nome, tecnologia, capacidade_max_assinantes, status } = req.body || {};
  const patch = {};
  for (const [k, v] of Object.entries({ codigo_porta, nome, tecnologia, capacidade_max_assinantes, status })) {
    if (v !== undefined) patch[k] = v;
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_portas_pon').update(patch).eq('id', req.params.id).select().single();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Porta PON não encontrada.' });
  return res.json(data);
});

module.exports = router;
