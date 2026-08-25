// OptiMon Pricing API — rotas de Cidades (seção 31).
// Handlers finos: validam entrada, chamam UM wrapper SQL, devolvem o resultado.

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  const status = /não encontrad/i.test(message) ? 404 : 400;
  return res.status(status).json({ error: message });
}

// GET /api/cities — lista de cidades com infraestrutura/capacidade consolidadas.
router.get('/', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_cities_list');
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/cities/:id — detalhe de uma cidade (infra + capacidade + POPs).
router.get('/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_city_detail', { p_cidade_id: req.params.id });
  if (error) return handleError(res, error);
  return res.json(data);
});

module.exports = router;
