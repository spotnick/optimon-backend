// OptiMon Pricing API — Fase 3.11 (seções 5-9): área externa do parceiro.
//
// Rota SEM `requireAuth` — a única outra exceção nesta API além do webhook de
// assinatura (api/routes/signatures.js). Quem chama é o parceiro, de fora, sem login
// no OptiMon — a credencial é o próprio token opaco (64 hex, alta entropia) gerado por
// app.enviar_proposta_parceiro, nunca um JWT. Por isso usa `anonClient()` (nunca
// `clientForRequest`/service_role) e chama só as 3 RPCs com grant explícito para
// `anon` (pricing_proposal_external_by_token/_accept/_decline — todas SECURITY
// DEFINER no banco, ver migration 20261002090000). Toda validação de negócio
// (token existe, não expirou, não cancelada, status correto, campos obrigatórios)
// acontece dentro dessas funções no Postgres — esta rota nunca decide nada sozinha,
// só encaminha.
//
// Nunca expõe piso/margem/desconto/governança/custo interno/auditoria — a função do
// banco já devolve um jsonb com whitelist explícita de campos (seção 7), então não há
// nada a filtrar aqui: encaminhamos o retorno da RPC como está.

const express = require('express');
const { anonClient } = require('../lib/supabaseClient');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (/TOKEN_INVALIDO|NAO_ENCONTRAD/i.test(message)) {
    status = 404;
  } else if (/TOKEN_EXPIRADO|STATUS_INVALIDO|CANCELADA/i.test(message)) {
    status = 409;
  } else if (/DADOS_OBRIGATORIOS|MOTIVO_OBRIGATORIO|obrigatóri|inválido/i.test(message)) {
    status = 400;
  } else {
    status = 400;
  }
  return res.status(status).json({ error: message });
}

// GET /api/proposals/external/:token — carrega a proposta pelo token (e já registra a
// visualização — PROPOSAL_VIEWED_BY_PARTNER — a cada chamada, seção 8).
router.get('/:token', async (req, res) => {
  const supabase = anonClient();
  const { data, error } = await supabase.rpc('pricing_proposal_external_by_token', {
    p_token: req.params.token,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/proposals/external/:token/accept — aceite formal do parceiro (seção 9).
// Nunca um setState de frontend: nome/documento/email obrigatórios, validado e
// registrado no servidor, com IP e timestamp reais.
router.post('/:token/accept', async (req, res) => {
  const { nome, documento, cargo, email, telefone } = req.body || {};
  const supabase = anonClient();
  const { data, error } = await supabase.rpc('pricing_proposal_external_accept', {
    p_token: req.params.token,
    p_nome: nome ?? null,
    p_documento: documento ?? null,
    p_cargo: cargo ?? null,
    p_email: email ?? null,
    p_telefone: telefone ?? null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/proposals/external/:token/decline — recusa formal do parceiro (motivo
// sempre obrigatório).
router.post('/:token/decline', async (req, res) => {
  const { motivo } = req.body || {};
  const supabase = anonClient();
  const { data, error } = await supabase.rpc('pricing_proposal_external_decline', {
    p_token: req.params.token,
    p_motivo: motivo ?? null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

module.exports = router;
