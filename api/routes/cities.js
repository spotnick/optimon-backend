// OptiMon Pricing API — rotas de Cidades (seção 31 da Fase Deploy + seção 11 da Fase 2.3).
// Handlers finos: validam entrada mínima (campo presente), chamam UM wrapper SQL, devolvem
// o resultado. Toda regra de negócio (obrigatoriedade real, RBAC, bloqueio de arquivamento)
// vive no banco (app.criar_cidade/atualizar_cidade/arquivar_cidade) — a API nunca decide,
// só encaminha, e nunca confia em nada vindo do frontend além de repassar ao Postgres.

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  // Mesma convenção usada em routes/pricing.js: a mensagem que o Postgres já formatou
  // (RAISE EXCEPTION) é o único sinal de status HTTP — nunca inspecionamos código interno.
  let status;
  if (/PERMISSAO_NEGADA/i.test(message)) {
    status = 403;
  } else if (/não encontrad/i.test(message)) {
    status = 404;
  } else if (/não é possível arquivar|contrato ativo/i.test(message)) {
    status = 409;
  } else {
    status = 400;
  }
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

// POST /api/cities — cadastro de cidade (seção 8/11). Nunca cria POP/infra junto — isso é
// um passo separado do fluxo (seção 22: Cidade -> +POP -> +segmento -> +cabo -> ...).
router.post('/', async (req, res) => {
  const { nome, uf, km_rede, codigo_ibge, endereco, observacoes, status } = req.body || {};
  if (!nome || !uf || km_rede == null) {
    return res.status(400).json({ error: 'nome, uf e km_rede são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_city_create', {
    p_nome: nome,
    p_uf: uf,
    p_km_rede: km_rede,
    p_codigo_ibge: codigo_ibge ?? null,
    p_endereco: endereco ?? null,
    p_observacoes: observacoes ?? null,
    p_status: status || 'ATIVA',
  });
  if (error) return handleError(res, error);
  return res.status(201).json({ cidade_id: data });
});

// PATCH /api/cities/:id — edição parcial (seção 11). Campo ausente/undefined preserva o
// valor atual — só nome/uf/km_rede recusam string vazia/valor inválido (validado no banco).
router.patch('/:id', async (req, res) => {
  const { nome, uf, km_rede, codigo_ibge, endereco, observacoes, status } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('pricing_city_update', {
    p_cidade_id: req.params.id,
    p_nome: nome ?? null,
    p_uf: uf ?? null,
    p_codigo_ibge: codigo_ibge ?? null,
    p_endereco: endereco ?? null,
    p_km_rede: km_rede ?? null,
    p_observacoes: observacoes ?? null,
    p_status: status ?? null,
  });
  if (error) return handleError(res, error);
  return res.json({ ok: true });
});

// POST /api/cities/:id/archive — nunca DELETE físico (seção 10). Bloqueia com contrato
// ATIVO — mensagem exata "Não é possível arquivar uma cidade com contrato ativo." (seção 32).
router.post('/:id/archive', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('pricing_city_archive', { p_cidade_id: req.params.id });
  if (error) return handleError(res, error);
  return res.json({ ok: true });
});

module.exports = router;
