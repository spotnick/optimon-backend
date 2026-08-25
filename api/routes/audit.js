// OptiMon Pricing API — rotas de Auditoria (seção 31, 34).

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

function handleError(res, error) {
  return res.status(400).json({ error: error?.message || 'Erro inesperado.' });
}

// GET /api/audit?limit=&entidade=&usuario_id= — trilha de auditoria (seção 45).
router.get('/', async (req, res) => {
  const { limit, entidade, usuario_id } = req.query;
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_audit_list', {
    p_limit: limit ? Number(limit) : 100,
    p_entidade: entidade ?? null,
    p_usuario_id: usuario_id ?? null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/audit/login — chamado pelo frontend uma única vez, logo após
// supabase.auth.signInWithPassword() ter sucesso (seção 18/34). Não é a autenticação em
// si (isso é sempre Supabase Auth, direto do frontend com a ANON_KEY pública — GoTrue não
// pode ser "proxied" por um backend próprio) — é só o registro do evento de auditoria.
router.post('/login', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('pricing_log_login');
  if (error) return handleError(res, error);
  return res.status(204).end();
});

module.exports = router;
