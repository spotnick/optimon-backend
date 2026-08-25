// OptiMon Pricing API — rotas de Proposta Comercial (seção 29, 31).

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  const status = /obrigatóri/i.test(message) ? 400 : /não encontrad/i.test(message) ? 404 : 409;
  return res.status(status).json({ error: message });
}

// POST /api/proposals — "GERAR PROPOSTA" (seção 29). simulacao_id é obrigatório; o
// snapshot é montado a partir do resultado já salvo na simulação (nunca recalculado aqui).
router.post('/', async (req, res) => {
  const { simulacao_id, cidade_id, parceiro_id, contrato_id, pricing_version_id, override_request_id } = req.body || {};
  if (!simulacao_id) {
    return res.status(400).json({ error: 'simulacao_id é obrigatório — gere/salve a simulação primeiro (POST /api/simulations).' });
  }

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_proposal_create', {
    p_simulacao_id: simulacao_id,
    p_cidade_id: cidade_id ?? null,
    p_parceiro_id: parceiro_id ?? null,
    p_contrato_id: contrato_id ?? null,
    p_pricing_version_id: pricing_version_id ?? null,
    p_override_request_id: override_request_id ?? null,
  });
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// GET /api/proposals?contrato_id=...&cidade_id=... — histórico de propostas.
router.get('/', async (req, res) => {
  const { contrato_id, cidade_id } = req.query;
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_proposals_list', {
    p_contrato_id: contrato_id ?? null,
    p_cidade_id: cidade_id ?? null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

module.exports = router;
