// OptiMon Pricing API — Fase 3.11 (seções 5-9), corrigida na Fase 3.11.2 (seção 1 do
// pedido de correção crítica): área externa do parceiro.
//
// Rota SEM `requireAuth` — a única outra exceção nesta API além do webhook de
// assinatura (api/routes/signatures.js). Quem chama é o parceiro, de fora, sem login
// no OptiMon — a credencial é o próprio token opaco (64 hex, alta entropia) gerado por
// app.enviar_proposta_parceiro, nunca um JWT.
//
// Fase 3.11.2: "abrir o link jamais pode representar aceite" já era verdade (GET só
// visualiza), mas o aceite em 1 passo (POST /:token/accept, preencher formulário e
// pronto) também era fraco demais — nada provava que quem preencheu o formulário tinha
// acesso à caixa de e-mail informada. Substituído por 2 rotas nunca chamado por 1 passo
// só: /accept/iniciar (gera e "envia" um código de confirmação — nunca muda o status da
// proposta) e /accept/confirmar (só aqui o aceite formal acontece, e só com o código
// certo). O código em si NUNCA aparece nesta resposta HTTP — ver api/lib/otpNotifier.js.
//
// Nunca expõe piso/margem/desconto/governança/custo interno/auditoria — a função do
// banco já devolve um jsonb com whitelist explícita de campos (seção 7), então não há
// nada a filtrar aqui: encaminhamos o retorno da RPC como está.

const express = require('express');
const crypto = require('crypto');
const { anonClient } = require('../lib/supabaseClient');
const { buildOtpNotifier } = require('../lib/otpNotifier');

const router = express.Router();
const otpNotifier = buildOtpNotifier();

// Fase 3.11.2: pepper de defesa em profundidade para o hash do OTP — o código em si já
// é de curta duração (10 min) + limitado a 5 tentativas + de uso único, então mesmo sem
// pepper o risco de força bruta contra o hash (se o banco vazasse) seria baixo; o pepper
// só torna isso ainda mais caro. Mesmo padrão de variável de ambiente com default de
// desenvolvimento documentado já usado para FASE25_TEST_WEBHOOK_SECRET — nunca usar o
// default em produção (ver .env.example).
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
  // Fase 3.11.2: IP real do parceiro (req.ip do Express, já configurado a partir de
  // X-Forwarded-For pelo Railway/proxy) — nunca o IP do próprio servidor Node (bug real
  // documentado na migration 20261003100000: o GUC request.headers do PostgREST só via
  // o IP de quem chama o PostgREST, que é sempre este servidor Node, nunca o navegador
  // do parceiro).
  return req.ip || req.headers['x-forwarded-for'] || null;
}

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (/TOKEN_INVALIDO|NAO_ENCONTRAD|TENTATIVA_INVALIDA/i.test(message)) {
    status = 404;
  } else if (/TOKEN_EXPIRADO|STATUS_INVALIDO|CANCELADA|ACEITE_DUPLICADO|TENTATIVA_EXPIRADA|OTP_EXPIRADO|OTP_BLOQUEADO/i.test(message)) {
    status = 409;
  } else if (/OTP_INCORRETO/i.test(message)) {
    status = 401;
  } else if (/DADOS_OBRIGATORIOS|MOTIVO_OBRIGATORIO|DECLARACAO_OBRIGATORIA|CONFIRMACAO_OBRIGATORIA|OTP_INVALIDO|obrigatóri|inválido/i.test(message)) {
    status = 400;
  } else {
    status = 400;
  }
  return res.status(status).json({ error: message });
}

// GET /api/proposals/external/:token — carrega a proposta pelo token (e já registra a
// visualização — PROPOSAL_VIEWED_BY_PARTNER — a cada chamada, seção 8). Isto é SÓ
// visualização — nunca representa aceite (seção 1, item "ABRIR O LINK JAMAIS PODE
// REPRESENTAR ACEITE" — inalterado desde a Fase 3.11, reconfirmado aqui).
router.get('/:token', async (req, res) => {
  const supabase = anonClient();
  const { data, error } = await supabase.rpc('pricing_proposal_external_by_token', {
    p_token: req.params.token,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/proposals/external/:token/accept/iniciar — passo 1 do aceite (Fase 3.11.2,
// seção 1, itens 1-9; e-mail REAL via Resend a partir da Fase 3.11.3): valida dados/
// declaração/checkbox, gera o OTP (em Node — o Postgres nunca vê o valor em texto
// puro), envia via otpNotifier (Resend real, ou fallback DEV_LOG fora de produção — ver
// api/lib/otpNotifier.js), e devolve só {tentativa_id, expira_em, email_mascarado,
// email_enviado} — NUNCA o código.
//
// Fase 3.11.3 (seção 8): "OTP criado" != "e-mail enviado" != "e-mail entregue" — por
// isso o Node grava, no PRÓPRIO banco (propostas_aceite_tentativas.email_status), cada
// transição real que observa: EMAIL_SOLICITADO logo antes de chamar o provedor,
// EMAIL_ACEITO_PELO_RESEND só depois que o Resend devolve 200 + email_id, e EMAIL_FALHOU
// se a chamada falhar — nunca assume sucesso silenciosamente.
router.post('/:token/accept/iniciar', async (req, res) => {
  const { nome, documento, cargo, email, telefone, declaracao, confirmacao } = req.body || {};
  const supabase = anonClient();

  const otp = generateOtp();
  const otpHash = hashOtp(otp);
  const OTP_TTL_MINUTOS = 10;

  const { data, error } = await supabase.rpc('pricing_proposal_external_accept_iniciar', {
    p_token: req.params.token,
    p_nome: nome ?? null,
    p_documento: documento ?? null,
    p_cargo: cargo ?? null,
    p_email: email ?? null,
    p_telefone: telefone ?? null,
    p_declaracao: declaracao === true,
    p_confirmacao: confirmacao === true,
    p_otp_hash: otpHash,
    p_otp_ttl_minutos: OTP_TTL_MINUTOS,
    p_ip: clientIp(req),
    p_user_agent: req.headers['user-agent'] || null,
  });
  if (error) return handleError(res, error);

  const tentativaId = data.tentativa_id;
  const ip = clientIp(req);

  // Só "envia" depois que a tentativa foi validada e persistida — nunca gera um OTP que
  // não tenha hash gravado no banco correspondente.
  await supabase.rpc('pricing_proposal_accept_email_status', {
    p_tentativa_id: tentativaId, p_email_status: 'EMAIL_SOLICITADO', p_ip: ip,
  });

  let envio;
  try {
    envio = await otpNotifier.sendOtp({
      email, nome, numero: data?.numero, proponente: data?.parceiro_nome, otp,
      expiraEm: data?.expira_em, expiraMinutos: OTP_TTL_MINUTOS, tentativaId,
    });
  } catch (sendErr) {
    // Nunca vaza detalhe sensível (chave/stack) no log nem na resposta — só a causa
    // sanitizada já lançada por api/lib/emailService.js.
    const detalhe = sendErr?.message || 'Falha desconhecida ao enviar e-mail.';
    console.error(`[otp-email] falha ao enviar OTP para tentativa_id=${tentativaId} (destinatário mascarado=${maskEmail(email)}):`, detalhe);
    await supabase.rpc('pricing_proposal_accept_email_status', {
      p_tentativa_id: tentativaId, p_email_status: 'EMAIL_FALHOU', p_detalhe: detalhe, p_ip: ip,
    });
    return res.status(502).json({
      error: 'EMAIL_ENVIO_FALHOU: não foi possível enviar o e-mail com o código de confirmação — tente novamente em instantes.',
      tentativa_id: tentativaId,
    });
  }

  await supabase.rpc('pricing_proposal_accept_email_status', {
    p_tentativa_id: tentativaId,
    p_email_status: envio.canal === 'RESEND' ? 'EMAIL_ACEITO_PELO_RESEND' : 'EMAIL_SOLICITADO',
    p_email_provider_id: envio.emailId || null,
    p_email_canal: envio.canal,
    p_ip: ip,
  });

  // Log de auditoria operacional (nunca conteúdo sensível — seção 5/21): só email_id,
  // destinatário mascarado, timestamp (implícito no log) e status.
  console.log(`[otp-email] tentativa_id=${tentativaId} canal=${envio.canal} email_id=${envio.emailId || '(n/a)'} destinatario=${maskEmail(email)} status=${envio.canal === 'RESEND' ? 'EMAIL_ACEITO_PELO_RESEND' : 'DEV_LOG'}`);

  return res.status(201).json({
    tentativa_id: tentativaId,
    expira_em: data.expira_em,
    email_mascarado: maskEmail(email),
    email_enviado: envio.canal === 'RESEND',
  });
});

// POST /api/proposals/external/:token/accept/confirmar — passo 2 (Fase 3.11.2, seção 1,
// itens 10-12): só aqui o aceite formal é efetivado, e só com o código certo.
router.post('/:token/accept/confirmar', async (req, res) => {
  const { tentativa_id, otp } = req.body || {};
  if (!tentativa_id || !otp) {
    return res.status(400).json({ error: 'DADOS_OBRIGATORIOS: tentativa_id e otp são obrigatórios.' });
  }
  const supabase = anonClient();
  const { data, error } = await supabase.rpc('pricing_proposal_external_accept_confirmar', {
    p_token: req.params.token,
    p_tentativa_id: tentativa_id,
    p_otp_hash_attempt: hashOtp(String(otp).trim()),
    p_ip: clientIp(req),
    p_user_agent: req.headers['user-agent'] || null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/proposals/external/:token/decline — recusa formal do parceiro (motivo
// sempre obrigatório). Não passa por OTP (o pedido de correção exige confirmação
// reforçada só para o ACEITE — recusar não gera nenhum compromisso comercial).
router.post('/:token/decline', async (req, res) => {
  const { motivo } = req.body || {};
  const supabase = anonClient();
  const { data, error } = await supabase.rpc('pricing_proposal_external_decline', {
    p_token: req.params.token,
    p_motivo: motivo ?? null,
    p_ip: clientIp(req),
    p_user_agent: req.headers['user-agent'] || null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

module.exports = router;
