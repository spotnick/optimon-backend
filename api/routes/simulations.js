// OptiMon Pricing API — rotas de Simulações (seções 22, 29, 31, 35).
// "NOVA SIMULAÇÃO" (a função mais importante do Comercial, seção 35): calcula (sem
// gravar nada) via /api/pricing/calculate, e só persiste quando o usuário confirma via
// POST /api/simulations — nunca grava a cada tecla digitada.

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  const status = /obrigatóri|enum|invalid input/i.test(message) ? 400 : 409;
  return res.status(status).json({ error: message });
}

// POST /api/simulations — persiste uma simulação já calculada (seção 22/29).
// Corpo: { cidade_id, parceiro_id, modelo, pares_ou_clientes, arpu, revenue_share_pct,
//          prazo_meses, resultado } — "resultado" é o jsonb devolvido por
// POST /api/pricing/calculate (nunca recalculado aqui — se o cliente quer salvar um
// resultado diferente, precisa chamar /calculate de novo primeiro, para que o servidor
// tenha validado os números — seção 33).
router.post('/', async (req, res) => {
  const { cidade_id, parceiro_id, modelo, pares_ou_clientes, arpu, revenue_share_pct, prazo_meses, resultado } = req.body || {};
  if (!cidade_id || !modelo || !resultado) {
    return res.status(400).json({ error: 'cidade_id, modelo e resultado são obrigatórios (resultado vem de POST /api/pricing/calculate).' });
  }

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_simulation_save', {
    p_cidade_id: cidade_id,
    p_parceiro_id: parceiro_id ?? null,
    p_modelo: modelo,
    p_pares_ou_clientes: pares_ou_clientes ?? null,
    p_arpu: arpu ?? null,
    p_revenue_share_pct: revenue_share_pct ?? null,
    p_prazo_meses: prazo_meses ?? 48,
    p_resultado: resultado,
  });
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// GET /api/simulations?contrato_id=... — simulações salvas (reaproveita pricing_scenarios_list).
router.get('/', async (req, res) => {
  const { contrato_id } = req.query;
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_scenarios_list', { p_contrato_id: contrato_id ?? null });
  if (error) return handleError(res, error);
  return res.json(data);
});

module.exports = router;
