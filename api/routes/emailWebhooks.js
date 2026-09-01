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
    // Fase 3.11.6 (seção 3): "evento adulterado → rejeitado" precisa deixar rastro,
    // mesmo sem confiar em nada do payload — svix-id do header (não confiável, mas é
    // só uma chave de log) + hash do corpo bruto recebido, marcado REJEITADO na hora.
    // Aguardado (nunca fire-and-forget): recebido_em precisa estar gravado ANTES da
    // resposta voltar, senão "prova de evento recebido" vira uma corrida sem garantia
    // nenhuma. Best-effort só no sentido de que uma falha AQUI nunca muda o 401 (nunca
    // confiar cegamente no payload continua valendo acima de tudo).
    try {
      const anonForLog = anonClient();
      const payloadHash = crypto.createHash('sha256').update(rawBody).digest('hex');
      const { data, error: logError } = await anonForLog.rpc('pricing_signature_webhook_recebido', {
        p_provider: 'RESEND_EMAIL_WEBHOOK',
        p_evento_externo_id: req.headers['svix-id'] || `sem-svix-id:${payloadHash}`,
        p_tipo_evento: 'ASSINATURA_INVALIDA',
        p_payload: null,
        p_payload_hash: payloadHash,
      });
      if (!logError) {
        const row = Array.isArray(data) ? data[0] : data;
        if (row?.evento_id && !row?.duplicado) {
          await anonForLog.rpc('pricing_signature_webhook_rejeitado', { p_evento_id: row.evento_id, p_erro: 'Assinatura Svix inválida.' });
        }
      }
    } catch (_logErr) {
      // nunca deixa uma falha no LOG mudar o 401 nem derrubar a resposta.
    }
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

  // Fase 3.11.6 (seção 1/2/3): antes de qualquer processamento, registra o RECEBIMENTO
  // do webhook em signature_events — svix-id é a chave de idempotência (única por
  // tentativa de entrega, nunca reciclada pelo Resend). Isso dá prova de "evento
  // recebido" mesmo quando o processamento em si é ignorado/rejeitado/desconhecido, e
  // garante que um reenvio do MESMO evento pelo Resend (retry) nunca reaplica o efeito
  // duas vezes.
  const anon = anonClient();
  const svixId = req.headers['svix-id'];
  const payloadHash = crypto.createHash('sha256').update(rawBody).digest('hex');
  let eventoId = null;
  if (svixId) {
    const { data: recebido, error: recebidoError } = await anon.rpc('pricing_signature_webhook_recebido', {
      p_provider: 'RESEND_EMAIL_WEBHOOK',
      p_evento_externo_id: svixId,
      p_tipo_evento: tipoEvento,
      p_payload: payload,
      p_payload_hash: payloadHash,
    });
    if (recebidoError) {
      console.error('[resend-webhook] erro ao registrar recebimento do evento:', recebidoError.message);
      // Nunca deixa uma falha no LOG derrubar o processamento real (seção 3: evento
      // desconhecido/erro de registro nunca quebra o sistema) — segue sem eventoId.
    } else {
      const row = Array.isArray(recebido) ? recebido[0] : recebido;
      eventoId = row?.evento_id || null;
      if (row?.duplicado) {
        // Idempotência (seção 3): mesmo evento (mesmo svix-id) já foi recebido antes —
        // devolve 200 sem reprocessar, nunca reaplica a mudança de status duas vezes.
        return res.status(200).json({ duplicado: true, tipo_evento: tipoEvento, motivo: 'svix-id já processado anteriormente.' });
      }
    }
  }

  const novoStatus = EVENT_MAP[tipoEvento];
  if (novoStatus === undefined) {
    if (eventoId) await anon.rpc('pricing_signature_webhook_desconhecido', { p_evento_id: eventoId, p_detalhe: `tipo de evento não mapeado: ${tipoEvento}` });
    return res.status(200).json({ ignorado: true, motivo: `tipo de evento não mapeado: ${tipoEvento}` });
  }
  if (novoStatus === null) {
    if (eventoId) await anon.rpc('pricing_signature_webhook_processado', { p_evento_id: eventoId });
    return res.status(200).json({ ignorado: true, motivo: `evento informativo sem mudança de status: ${tipoEvento}` });
  }

  const detalhe = tipoEvento === 'email.bounced' || tipoEvento === 'email.complained' || tipoEvento === 'email.failed'
    ? `Evento Resend: ${tipoEvento}`
    : null;

  const { error } = await anon.rpc('pricing_proposal_accept_email_status_por_provider_id', {
    p_email_provider_id: emailId,
    p_email_status: novoStatus,
    p_detalhe: detalhe,
  });
  if (!error) {
    if (eventoId) await anon.rpc('pricing_signature_webhook_processado', { p_evento_id: eventoId });
    return res.status(200).json({ processado: true, tipo_evento: tipoEvento, novo_status: novoStatus, fluxo: 'proposta_otp' });
  }
  if (!/TENTATIVA_INVALIDA/i.test(error.message || '')) {
    console.error('[resend-webhook] erro ao registrar evento (fluxo OTP de proposta):', error.message);
    if (eventoId) await anon.rpc('pricing_signature_webhook_rejeitado', { p_evento_id: eventoId, p_erro: error.message });
    return res.status(500).json({ error: 'Erro ao registrar evento do webhook.' });
  }

  // Fase 3.11.4 (seção 9/12): este email_id não é de um OTP de proposta — reaproveita o
  // MESMO webhook (nunca uma segunda solução) para também cobrir o link de assinatura
  // eletrônica enviado por signatureLinkNotifier.js.
  const signatureEvento = { 'email.delivered': 'EMAIL_ENTREGUE', 'email.bounced': 'EMAIL_REJEITADO', 'email.complained': 'EMAIL_REJEITADO', 'email.failed': 'EMAIL_FALHOU' }[tipoEvento] || null;
  if (!signatureEvento) {
    if (eventoId) await anon.rpc('pricing_signature_webhook_desconhecido', { p_evento_id: eventoId, p_detalhe: 'email_id não corresponde a nenhuma tentativa de aceite de OTP nem a um envio de assinatura.' });
    return res.status(200).json({ ignorado: true, motivo: 'email_id não corresponde a nenhuma tentativa de aceite de OTP nem a um envio de assinatura.' });
  }
  const { data: sigData, error: sigError } = await anon.rpc('pricing_signature_email_status_por_provider_id', {
    p_email_provider_id: emailId, p_evento: signatureEvento, p_detalhe: detalhe,
  });
  if (sigError) {
    if (/TENTATIVA_INVALIDA/i.test(sigError.message || '')) {
      if (eventoId) await anon.rpc('pricing_signature_webhook_desconhecido', { p_evento_id: eventoId, p_detalhe: 'email_id não corresponde a nenhuma tentativa de aceite de OTP nem a um envio de assinatura.' });
      return res.status(200).json({ ignorado: true, motivo: 'email_id não corresponde a nenhuma tentativa de aceite de OTP nem a um envio de assinatura.' });
    }
    console.error('[resend-webhook] erro ao registrar evento (fluxo de assinatura):', sigError.message);
    if (eventoId) await anon.rpc('pricing_signature_webhook_rejeitado', { p_evento_id: eventoId, p_erro: sigError.message });
    return res.status(500).json({ error: 'Erro ao registrar evento do webhook.' });
  }

  if (eventoId) {
    const envelopeId = sigData?.envelope_id || null;
    const signerId = sigData?.signer_id || null;
    await anon.rpc('pricing_signature_webhook_processado', { p_evento_id: eventoId, p_envelope_id: envelopeId, p_signer_id: signerId });
  }

  return res.status(200).json({ processado: true, tipo_evento: tipoEvento, novo_status: signatureEvento, fluxo: 'assinatura_eletronica' });
});

module.exports = { router };
