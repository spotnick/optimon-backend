// OptiMon Pricing API — Fase 3.11.4 (seções 12-13): área externa do signatário — link
// individual de assinatura eletrônica. Rota SEM `requireAuth` (mirror deliberado de
// api/routes/proposalsExternal.js — mesma razão: quem chama é o signatário, de fora, sem
// login no OptiMon; a credencial é o próprio token opaco de alta entropia).
//
// GET só visualiza (nunca representa assinatura — seção 13, itens 6-7: abrir o link só
// gera o evento OPENED). POST /assinar é o único caminho que grava ASSINADO, e só depois
// da declaração explícita marcada.

const express = require('express');
const { anonClient } = require('../lib/supabaseClient');

const router = express.Router();

function clientIp(req) {
  return req.ip || req.headers['x-forwarded-for'] || null;
}

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (/TOKEN_INVALIDO|NAO_ENCONTRAD/i.test(message)) {
    status = 404;
  } else if (/TOKEN_EXPIRADO|STATUS_INVALIDO|ENVELOPE_CANCELADO|ASSINATURA_DUPLICADA/i.test(message)) {
    status = 409;
  } else if (/DADOS_OBRIGATORIOS|MOTIVO_OBRIGATORIO|DECLARACAO_OBRIGATORIA|obrigatóri|inválido/i.test(message)) {
    status = 400;
  } else {
    status = 400;
  }
  return res.status(status).json({ error: message });
}

// GET /api/signatures/external/:token — carrega o documento pelo token e registra a
// abertura (SIGNATURE_OPENED). Isto é SÓ visualização.
router.get('/:token', async (req, res) => {
  const supabase = anonClient();
  const { data, error } = await supabase.rpc('pricing_signature_external_by_token', { p_token: req.params.token });
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/signatures/external/:token/document — link assinado de curto prazo para o
// PDF original (mesmo padrão de signed URL de curto prazo já usado em GET
// /api/signatures/envelopes/:id/document — nunca uma URL pública fixa).
router.get('/:token/document', async (req, res) => {
  const supabase = anonClient();
  const { data: info, error } = await supabase.rpc('pricing_signature_external_by_token', { p_token: req.params.token });
  if (error) return handleError(res, error);
  if (!info?.documento_disponivel) return res.status(404).json({ error: 'Documento ainda não disponível para este envelope.' });

  const { data: envelope, error: envError } = await supabase.from('signature_envelopes').select('documento_original_storage_path').eq('id', info.envelope_id).maybeSingle();
  if (envError || !envelope?.documento_original_storage_path) return res.status(404).json({ error: 'Caminho do documento não encontrado.' });

  const { data: signed, error: signError } = await supabase.storage.from('documentos').createSignedUrl(envelope.documento_original_storage_path, 300);
  if (signError) return res.status(502).json({ error: `Falha ao gerar link de download: ${signError.message}.` });
  return res.json({ url: signed.signedUrl, expira_em_segundos: 300 });
});

// POST /api/signatures/external/:token/assinar — só aqui ASSINADO é gravado (seção 13,
// itens 8-9).
router.post('/:token/assinar', async (req, res) => {
  const { nome, documento, declaracao } = req.body || {};
  const supabase = anonClient();
  const { data, error } = await supabase.rpc('pricing_signature_external_assinar', {
    p_token: req.params.token,
    p_nome_confirmacao: nome ?? null,
    p_documento_confirmacao: documento ?? null,
    p_declaracao: declaracao === true,
    p_ip: clientIp(req),
    p_user_agent: req.headers['user-agent'] || null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/signatures/external/:token/recusar — recusa formal (motivo obrigatório).
router.post('/:token/recusar', async (req, res) => {
  const { motivo } = req.body || {};
  const supabase = anonClient();
  const { data, error } = await supabase.rpc('pricing_signature_external_recusar', {
    p_token: req.params.token,
    p_motivo: motivo ?? null,
    p_ip: clientIp(req),
    p_user_agent: req.headers['user-agent'] || null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

module.exports = router;
