// OptiMon Pricing API — rotas de Auditoria (seção 31, 34).

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

function handleError(res, error) {
  return res.status(400).json({ error: error?.message || 'Erro inesperado.' });
}

// GET /api/audit?limit=&entidade=&usuario_id=&entidade_id= — trilha de
// auditoria (seção 45). `entidade_id` é novo na Fase 2.5.1 (seção 11) — usado
// pela aba Histórico/Auditoria de /proponentes/:id para listar só os eventos
// de um registro específico.
router.get('/', async (req, res) => {
  const { limit, entidade, usuario_id, entidade_id } = req.query;
  const supabase = clientForRequest(req.userJwt);
  const params = {
    p_limit: limit ? Number(limit) : 100,
    p_entidade: entidade ?? null,
    p_usuario_id: usuario_id ?? null,
  };
  // Só inclui p_entidade_id quando de fato pedido — nunca manda a chave (nem
  // com valor null) quando o caller não passou `entidade_id`. Isso não é só
  // estética: PostgREST resolve a função pelo CONJUNTO de nomes de parâmetro
  // recebido, então enviar sempre as 4 chaves faria toda chamada exigir que
  // `pricing_audit_list` já tenha o parâmetro novo (migration 20260920) —
  // quebrando esta mesma rota contra qualquer estado de banco anterior a essa
  // migration (ex.: run_tests_deploy.sh, bem no início da cadeia de
  // regressão). Omitir a chave quando não usada mantém a chamada compatível
  // com a assinatura de 3 parâmetros que já existia desde a Fase 2.2.1 Parte 2.
  if (entidade_id) params.p_entidade_id = entidade_id;
  const { data, error } = await supabase.rpc('pricing_audit_list', params);
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
