// OptiMon — Fase 3.11.3 (seção 9): webhook do Resend (eventos sent/delivered/bounced/
// complained/failed do e-mail de OTP). Investigação real: este projeto não tinha nenhum
// webhook de e-mail (só o de assinatura eletrônica, api/routes/signatures.js) — este é
// novo, seguindo EXATAMENTE o mesmo padrão já usado ali e no de assinatura por
// provider_id (pricing_signature_webhook_event_by_provider_id): corpo BRUTO (para
// validar a assinatura), SEM requireAuth (quem chama é o Resend, nunca um usuário
// logado), e nunca confia no payload antes de validar a assinatura.
//
// O Resend assina webhooks no formato Svix (https://resend.com/docs/dashboard/webhooks/
// verify-webhooks-requests): headers `svix-id`/`svix-timestamp`/`svix-signature`, corpo
// assinado = "{svix-id}.{svix-timestamp}.{corpo bruto}", segredo em base64 com prefixo
// "whsec_" (o HMAC de verdade usa os bytes decodificados, sem o prefixo). Como esta
// sessão não tem um webhook do Resend real para testar contra um payload de verdade, a
// implementação segue a especificação pública ao pé da letra — documentado como
// verificação a fazer em produção antes de confiar cegamente (ver relatório final).

const express = require('express');
const crypto = require('crypto');
const { anonClient } = require('../lib/supabaseClient');

const router = express.Router();

const SVIX_TOLERANCE_SECONDS = 5 * 60; // 5 minutos — mesma janela recomendada pelo Svix.

function verifySvixSignature({ svixId, svixTimestamp, svixSignature, rawBody, secret }) {
  if (!svixId || !svixTimestamp || !svixSignature || !secret) return false;

  const tsNum = Number(svixTimestamp);
  if (!Number.isFinite(tsNum)) return false;
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSeconds - tsNum) > SVIX_TOLERANCE_SECONDS) return false; // anti-replay

  const secretBytes = Buffer.from(secret.startsWith('whsec_') ? secret.slice('whsec_'.length) : secret, 'base64');
  const signedContent = `${svixId}.${svixTimestamp}.${rawBody.toString('utf8')}`;
  const expected = crypto.createHmac('sha256', secretBytes).update(signedContent).digest('base64');

  // svix-signature pode trazer várias assinaturas espaço-separadas, formato "v1,<base64>".
  const candidates = String(svixSignature).split(' ').map((s) => s.split(',')[1]).filter(Boolean);
  const expectedBuf = Buffer.from(expected, 'base64');
  return candidates.some((candidate) => {
    let candidateBuf;
    try {
      candidateBuf = Buffer.from(candidate, 'base64');
    } catch (_e) {
      return false;
    }
    return candidateBuf.length === expectedBuf.length && crypto.timingSafeEqual(candidateBuf, expectedBuf);
  });
}

// Mapa evento Resend → nosso email_status (seção 8). "sent" já foi registrado como
// EMAIL_ACEITO_PELO_RESEND no momento do envio (resposta 2xx da API) — um evento
// "email.sent" do webhook é redundante mas inofensivo (idempotente: mesmo status).
const EVENT_MAP = {
  'email.sent': 'EMAIL_ACEITO_PELO_RESEND',
  'email.delivered': 'EMAIL_ENTREGUE',
  'email.delivery_delayed': null, // não é nem sucesso nem falha — não altera o estado.
  'email.bounced': 'EMAIL_REJEITADO',
  'email.complained': 'EMAIL_REJEITADO',
  'email.failed': 'EMAIL_FALHOU',
};

// POST /api/webhooks/resend — precisa do corpo BRUTO (express.raw, montado ANTES do
// express.json() global em server.js — mesmo comentário/padrão de api/routes/
// signatures.js).
router.post('/resend', express.raw({ type: '*/*', limit: '2mb' }), async (req, res) => {
  const rawBody = req.body; // Buffer.
  const secret = process.env.RESEND_WEBHOOK_SECRET;
  if (!secret) {
    // Nunca processa sem conseguir validar autenticidade (seção 21) — configuração
    // incompleta no Railway é um 500 controlado, nunca um "aceita mesmo assim".
    return res.status(500).json({ error: 'RESEND_WEBHOOK_SECRET não está configurada neste deploy — evento recusado.' });
  }

  const ok = verifySvixSignature({
    svixId: req.headers['svix-id'],
    svixTimestamp: req.headers['svix-timestamp'],
    svixSignature: req.headers['svix-signature'],
    rawBody,
    secret,
  });
  if (!ok) {
    return res.status(401).json({ error: 'Assinatura do webhook inválida — evento recusado (nunca confiar cegamente no payload).' });
  }

  let payload;
  try {
    payload = JSON.parse(rawBody.toString('utf8'));
  } catch (_err) {
    return res.status(400).json({ error: 'Payload inválido: JSON malformado.' });
  }

  const tipoEvento = payload?.type;
  const emailId = payload?.data?.email_id || payload?.data?.id;
  if (!tipoEvento || !emailId) {
    // Responde 200 (não é um erro do Resend, só um evento que não reconhecemos/não se
    // aplica) — evita retry desnecessário do lado do provedor.
    return res.status(200).json({ ignorado: true, motivo: 'type/data.email_id ausentes.' });
  }

  const novoStatus = EVENT_MAP[tipoEvento];
  if (novoStatus === undefined) {
    return res.status(200).json({ ignorado: true, motivo: `tipo de evento não mapeado: ${tipoEvento}` });
  }
  if (novoStatus === null) {
    return res.status(200).json({ ignorado: true, motivo: `evento informativo sem mudança de status: ${tipoEvento}` });
  }

  const anon = anonClient();
  const { error } = await anon.rpc('pricing_proposal_accept_email_status_por_provider_id', {
    p_email_provider_id: emailId,
    p_email_status: novoStatus,
    p_detalhe: tipoEvento === 'email.bounced' || tipoEvento === 'email.complained' || tipoEvento === 'email.failed'
      ? `Evento Resend: ${tipoEvento}`
      : null,
  });
  if (error) {
    // Nenhuma tentativa encontrada para este email_id (ex.: e-mail de outro fluxo que
    // não o de OTP) — não é um erro de segurança, só não se aplica aqui.
    if (/TENTATIVA_INVALIDA/i.test(error.message || '')) {
      return res.status(200).json({ ignorado: true, motivo: 'email_id não corresponde a nenhuma tentativa de aceite de OTP.' });
    }
    console.error('[resend-webhook] erro ao registrar evento:', error.message);
    return res.status(500).json({ error: 'Erro ao registrar evento do webhook.' });
  }

  return res.status(200).json({ processado: true, tipo_evento: tipoEvento, novo_status: novoStatus });
});

module.exports = { router };
