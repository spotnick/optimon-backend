// OptiMon Pricing API — Fase 3.11.4 (seções 12-13): área externa do signatário — link
// individual de assinatura eletrônica. Rota SEM `requireAuth` (mirror deliberado de
// api/routes/proposalsExternal.js — mesma razão: quem chama é o signatário, de fora, sem
// login no OptiMon; a credencial é o próprio token opaco de alta entropia).
//
// GET só visualiza (nunca representa assinatura — seção 13, itens 6-7: abrir o link só
// gera o evento OPENED). POST /assinar/confirmar é o único caminho que grava ASSINADO, e
// só depois da declaração explícita marcada E do código de confirmação (OTP) certo.
//
// Fase 3.11.5 (correções reais de 4 problemas encontrados pelo usuário testando em
// produção o fluxo real de ponta a ponta — ver cabeçalho da migration
// 20261008090000_phase_3_11_05_correcoes_pos_deploy.sql):
//   1. GET .../document devolvia 404 mesmo com o documento existindo (RLS bloqueando o
//      cliente anon) — corrigido usando a RPC SECURITY DEFINER escopada ao token, nunca
//      mais lendo signature_envelopes direto com o cliente anon.
//   2. CPF sem validação real — agora validado no banco (app.cpf_valido, dígito
//      verificador) dentro do passo /assinar/iniciar, nunca só no frontend.
//   3. Assinar virou 2 passos (POST /assinar/iniciar + POST /assinar/confirmar), com
//      código de confirmação (OTP) de 6 dígitos por e-mail — mirror exato do aceite de
//      proposta (Fase 3.11.2, api/routes/proposalsExternal.js). Substitui o antigo
//      POST /assinar de 1 passo só — nunca 2 soluções paralelas.
//   4. Nova rota GET .../document-assinado: só fica disponível depois que o PDF final
//      (com página de certificado de assinatura) é gerado de verdade pelo Node — nunca
//      uma cópia do original.
//
// Fase 3.11.5.1 (correção retroativa, gap real encontrado no reteste do usuário):
// gerarDocumentoAssinadoContrato() agora é exportada (router.gerarDocumentoAssinadoContrato)
// para ser reaproveitada por api/routes/signatures.js — uma rota AUTENTICADA nova
// (POST /envelopes/:id/gerar-documento-assinado) para o ADMINISTRADOR gerar/re-gerar o PDF
// final de um envelope que já foi assinado mas nunca teve o PDF gerado com sucesso (ex.:
// assinado antes desta fase, quando a única linha de documentos_assinados ficou "poluída"
// com uma cópia do original — ver migration 20261008100000_..._repara_..._retroativo.sql).
// Nenhuma lógica duplicada: é a mesma função, só chamada de um outro lugar.

const express = require('express');
const crypto = require('crypto');
const { anonClient } = require('../lib/supabaseClient');
const { buildOtpNotifier } = require('../lib/otpNotifier');
const { generateContratoPdf } = require('../lib/pdfContrato');

const router = express.Router();
const otpNotifier = buildOtpNotifier();

// Mesmo pepper/env var já usado em api/routes/proposalsExternal.js — nunca uma 2ª
// variável de ambiente só para trocar o contexto do hash.
const OTP_PEPPER = process.env.OTP_HASH_PEPPER || 'optimon-otp-pepper-dev-nao-usar-em-producao';

function hashOtp(otp) {
  return crypto.createHash('sha256').update(`${otp}:${OTP_PEPPER}`).digest('hex');
}

function generateOtp() {
  // 6 dígitos, 000000-999999 — crypto.randomInt é CSPRNG (não Math.random).
  return String(crypto.randomInt(0, 1000000)).padStart(6, '0');
}

function maskEmail(email) {
  const [user, domain] = String(email || '').split('@');
  if (!domain) return '***';
  const visible = user.slice(0, 2);
  return `${visible}${'*'.repeat(Math.max(user.length - visible.length, 1))}@${domain}`;
}

function clientIp(req) {
  return req.ip || req.headers['x-forwarded-for'] || null;
}

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (/TOKEN_INVALIDO|NAO_ENCONTRAD|TENTATIVA_INVALIDA/i.test(message)) {
    status = 404;
  } else if (/TOKEN_EXPIRADO|STATUS_INVALIDO|ENVELOPE_CANCELADO|ASSINATURA_DUPLICADA|TENTATIVA_EXPIRADA|OTP_EXPIRADO|OTP_BLOQUEADO/i.test(message)) {
    status = 409;
  } else if (/OTP_INCORRETO/i.test(message)) {
    status = 401;
  } else if (/DADOS_OBRIGATORIOS|MOTIVO_OBRIGATORIO|DECLARACAO_OBRIGATORIA|CPF_INVALIDO|OTP_INVALIDO|obrigatóri|inválido/i.test(message)) {
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
// PDF ORIGINAL (revisão antes de assinar). Fase 3.11.5: antes lia signature_envelopes
// direto com o cliente anon (bloqueado pela RLS to authenticated — bug real de produção,
// "Caminho do documento não encontrado" mesmo com o caminho existindo) — corrigido para
// usar a RPC SECURITY DEFINER escopada ao token, mesmo padrão do resto deste arquivo.
router.get('/:token/document', async (req, res) => {
  const supabase = anonClient();
  const { data: path, error } = await supabase.rpc('pricing_signature_external_documento_path', { p_token: req.params.token });
  if (error) return handleError(res, error);
  if (!path) return res.status(404).json({ error: 'Documento ainda não disponível para este envelope.' });

  const { data: signed, error: signError } = await supabase.storage.from('documentos').createSignedUrl(path, 300);
  if (signError) return res.status(502).json({ error: `Falha ao gerar link de download: ${signError.message}.` });
  return res.json({ url: signed.signedUrl, expira_em_segundos: 300 });
});

// GET /api/signatures/external/:token/document-assinado — Fase 3.11.5 (item 4 do relato
// de produção): PDF FINAL, com a página de certificado de assinatura eletrônica de todos
// os signatários — só existe depois que POST /assinar/confirmar gerar o último signatário
// obrigatório e o Node terminar de montar e subir o PDF de verdade (nunca uma cópia do
// original, nunca disponível antes de existir de fato).
router.get('/:token/document-assinado', async (req, res) => {
  const supabase = anonClient();
  const { data: path, error } = await supabase.rpc('pricing_signature_external_documento_assinado_path', { p_token: req.params.token });
  if (error) return handleError(res, error);
  if (!path) return res.status(404).json({ error: 'O PDF final assinado ainda não está pronto — tente novamente em instantes.' });

  const { data: signed, error: signError } = await supabase.storage.from('documentos').createSignedUrl(path, 300);
  if (signError) return res.status(502).json({ error: `Falha ao gerar link de download: ${signError.message}.` });
  return res.json({ url: signed.signedUrl, expira_em_segundos: 300 });
});

// POST /api/signatures/external/:token/assinar/iniciar — Fase 3.11.5 (item 3 do relato:
// "deve ter token de validação para garantir quem está assinando"), passo 1 do novo
// fluxo de 2 passos — mirror exato de POST /api/proposals/external/:token/accept/iniciar
// (Fase 3.11.2): valida nome/CPF real (dígito verificador, no banco)/declaração, gera o
// OTP (em Node — o Postgres nunca vê o valor em texto puro), envia por e-mail (Resend
// real, ou DEV_LOG fora de produção), e devolve só {tentativa_id, expira_em,
// email_mascarado, email_enviado} — NUNCA o código. Signature_signers.status só muda
// para ASSINADO no passo 2 (/assinar/confirmar), com o código certo.
router.post('/:token/assinar/iniciar', async (req, res) => {
  const { nome, documento, declaracao } = req.body || {};
  const supabase = anonClient();

  const otp = generateOtp();
  const otpHash = hashOtp(otp);
  const OTP_TTL_MINUTOS = 10;
  const ip = clientIp(req);

  const { data, error } = await supabase.rpc('pricing_signature_external_assinar_iniciar', {
    p_token: req.params.token,
    p_nome: nome ?? null,
    p_documento: documento ?? null,
    p_declaracao: declaracao === true,
    p_otp_hash: otpHash,
    p_otp_ttl_minutos: OTP_TTL_MINUTOS,
    p_ip: ip,
    p_user_agent: req.headers['user-agent'] || null,
  });
  if (error) return handleError(res, error);

  // Precisa do e-mail/rótulo do documento para o template — carrega via GET .../:token
  // (mesma RPC pública já usada acima, sem repetir lógica de acesso).
  const { data: info } = await supabase.rpc('pricing_signature_external_by_token', { p_token: req.params.token });
  const email = info?.email;
  const numero = info?.contrato_numero || info?.proposta_numero || null;
  const docLabel = info?.tipo_documento === 'CONTRATO' ? 'Contrato' : info?.tipo_documento === 'PROPOSTA' ? 'Proposta' : 'Documento';
  const tentativaId = data.tentativa_id;

  let envio;
  try {
    envio = await otpNotifier.sendOtp({
      email, nome, numero, proponente: 'OptiMon', otp,
      expiraEm: data?.expira_em, expiraMinutos: OTP_TTL_MINUTOS, tentativaId,
      contexto: 'assinatura', docLabel,
    });
  } catch (sendErr) {
    const detalhe = sendErr?.message || 'Falha desconhecida ao enviar e-mail.';
    console.error(`[otp-email-assinatura] falha ao enviar OTP para tentativa_id=${tentativaId} (destinatário mascarado=${maskEmail(email)}):`, detalhe);
    return res.status(502).json({
      error: 'EMAIL_ENVIO_FALHOU: não foi possível enviar o e-mail com o código de confirmação — tente novamente em instantes.',
      tentativa_id: tentativaId,
    });
  }

  console.log(`[otp-email-assinatura] tentativa_id=${tentativaId} canal=${envio.canal} email_id=${envio.emailId || '(n/a)'} destinatario=${maskEmail(email)} status=${envio.canal === 'RESEND' ? 'EMAIL_ACEITO_PELO_RESEND' : 'DEV_LOG'}`);

  return res.status(201).json({
    tentativa_id: tentativaId,
    expira_em: data.expira_em,
    email_mascarado: maskEmail(email),
    email_enviado: envio.canal === 'RESEND',
  });
});

// POST /api/signatures/external/:token/assinar/confirmar — passo 2: só aqui ASSINADO é
// gravado, e só com o código certo (Fase 3.11.5, item 3). Quando este for o último
// signatário obrigatório (envelope_status volta ASSINADO), gera de verdade o PDF final
// com certificado (item 4) — melhor esforço: se a geração falhar, a assinatura em si
// continua válida (já commitada no passo anterior via RPC) e documento_assinado_
// disponivel simplesmente continua false até uma nova tentativa funcionar.
router.post('/:token/assinar/confirmar', async (req, res) => {
  const { tentativa_id, otp } = req.body || {};
  if (!tentativa_id || !otp) {
    return res.status(400).json({ error: 'DADOS_OBRIGATORIOS: tentativa_id e otp são obrigatórios.' });
  }
  const supabase = anonClient();
  const ip = clientIp(req);
  const { data, error } = await supabase.rpc('pricing_signature_external_assinar_confirmar', {
    p_token: req.params.token,
    p_tentativa_id: tentativa_id,
    p_otp_hash_attempt: hashOtp(String(otp).trim()),
    p_ip: ip,
    p_user_agent: req.headers['user-agent'] || null,
  });
  if (error) return handleError(res, error);

  if (data?.envelope_status === 'ASSINADO' && data?.tipo_documento === 'CONTRATO') {
    try {
      await gerarDocumentoAssinadoContrato({ supabase, token: req.params.token, ip });
    } catch (pdfErr) {
      // Nunca derruba a resposta de sucesso da assinatura por causa disso — a
      // assinatura em si já está gravada e válida. Só loga: o PDF final fica
      // indisponível (documento_assinado_disponivel=false) até uma nova tentativa.
      console.error(`[documento-assinado] falha ao gerar PDF final para envelope ${data.envelope_id}:`, pdfErr?.message || pdfErr);
    }
  }

  return res.json(data);
});

// Fase 3.11.5 (item 4 do relato): gera o PDF final REAL (mesmo motor da minuta,
// api/lib/pdfContrato.js — nunca um 2º gerador) já em modo "ASSINADO", com uma página
// de certificado de assinatura eletrônica (nome/CPF confirmados, e-mail, IP, data/hora,
// método, hash do documento original) para cada signatário, e registra o resultado.
// Só chamada para tipo_documento=CONTRATO (o caso real testado em produção) — PROPOSTA
// fica documentado como limitação conhecida, nunca inventada uma solução parcial.
async function gerarDocumentoAssinadoContrato({ supabase, token, ip }) {
  const [{ data: dadosContrato, error: dadosError }, { data: certificado, error: certError }] = await Promise.all([
    supabase.rpc('pricing_signature_external_documento_dados_contrato', { p_token: token }),
    supabase.rpc('pricing_signature_external_certificado_dados', { p_token: token }),
  ]);
  if (dadosError) throw dadosError;
  if (certError) throw certError;

  const buffer = await generateContratoPdf(dadosContrato, { certificado });
  const storagePath = `envelopes/${certificado.envelope_id}/assinado-${Date.now()}.pdf`;
  const { error: uploadError } = await supabase.storage.from('documentos').upload(storagePath, buffer, { contentType: 'application/pdf', upsert: true });
  if (uploadError) throw uploadError;

  const hash = crypto.createHash('sha256').update(buffer).digest('hex');
  const { error: registrarError } = await supabase.rpc('pricing_signature_external_documento_assinado_registrar', {
    p_token: token, p_storage_path: storagePath, p_hash: hash, p_ip: ip,
  });
  if (registrarError) throw registrarError;

  console.log(`[documento-assinado] PDF final gerado e registrado para envelope ${certificado.envelope_id} (storage_path=${storagePath})`);
}

// POST /api/signatures/external/:token/recusar — recusa formal (motivo obrigatório).
// Não passa por OTP (mesmo critério de proposalsExternal.js: confirmação reforçada só
// para o que gera compromisso — assinar; recusar não precisa).
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

// Fase 3.11.5.1: expõe a função no próprio objeto router (uma função Express já é um
// objeto JS válido) — server.js continua fazendo `app.use(..., signaturesExternalRoutes)`
// sem nenhuma mudança; signatures.js só acrescenta
// `require('./signaturesExternal').gerarDocumentoAssinadoContrato`.
router.gerarDocumentoAssinadoContrato = gerarDocumentoAssinadoContrato;

module.exports = router;
