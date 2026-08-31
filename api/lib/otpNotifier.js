// OptiMon — Fase 3.11.2: canal de ENTREGA do código de confirmação (OTP) do aceite
// externo. Reescrito na Fase 3.11.3 (seções 1-6 do pedido de correção real do Resend).
//
// Mesma divisão de responsabilidade já usada para a assinatura eletrônica (Fase 2.5,
// api/lib/signatureProvider.js): o OptiMon nunca fala diretamente com um provedor de
// e-mail dentro de uma rota — toda "entrega" passa por esta interface.
//
// Investigação real da Fase 3.11.3 (não presumida — ver cabeçalho da migration
// 20261004090000_phase_3_11_03_resend_real_parceiro_obrigatorio.sql): o Resend JÁ ESTÁ
// configurado neste projeto (SMTP do Supabase Auth, usado hoje só para convite/reset de
// senha de usuários NICK — api/routes/users.js) e RESEND_API_KEY já existe como
// variável de ambiente na Railway, confirmado diretamente pelo usuário. O motivo pelo
// qual o fluxo de OTP não usava essa infraestrutura: nunca existiu, em código, um client
// HTTP direto para a API do Resend (só o SMTP interno do GoTrue, que não serve para
// mandar e-mail arbitrário a um parceiro externo sem conta — decisão arquitetural já
// tomada e repetida desde a Fase 3.11: o parceiro NUNCA faz login no OptiMon, nunca tem
// linha em auth.users). `ResendOtpNotifier` é esse client que faltava — usa
// api/lib/emailService.js (ResendEmailProvider), que lê RESEND_API_KEY/RESEND_FROM_EMAIL
// só de process.env (nunca hardcoded — ver .env.example para o nome exato das
// variáveis a configurar/confirmar na Railway).
//
// `ConsoleDevNotifier` continua existindo, mas agora estritamente como um FALLBACK DE
// DESENVOLVIMENTO/TESTE — nunca roda quando APP_ENVIRONMENT=production, mesmo que
// RESEND_API_KEY esteja ausente (falha alto e claro em vez de fingir sucesso — seção 6:
// "mecanismo especial de teste deve ficar claramente separado de produção"). O código em
// texto puro, quando este fallback é usado, NUNCA é devolvido na resposta HTTP — só
// escrito no log do próprio servidor (console.log), igual sempre foi.

const { buildEmailProvider } = require('./emailService');
const { buildOtpEmail } = require('./otpEmailTemplate');

class ConsoleDevNotifier {
  constructor() {
    this.canal = 'DEV_LOG';
  }

  async sendOtp({ email, nome, numero, proponente, otp, expiraEm, expiraMinutos, tentativaId }) {
    if (process.env.APP_ENVIRONMENT === 'production') {
      // Nunca finge sucesso em produção — seção 6: mecanismo de teste nunca em prod.
      throw new Error('RESEND_NAO_CONFIGURADO: RESEND_API_KEY/RESEND_FROM_EMAIL ausentes em produção (APP_ENVIRONMENT=production) — o fallback de log de desenvolvimento nunca roda em produção. Configure as variáveis na Railway.');
    }
    // eslint-disable-next-line no-console
    console.log(
      `[DEV-OTP-NAO-E-EMAIL-REAL] destinatario=${email} nome="${nome}" tentativa_id=${tentativaId || '?'} proposta=${numero || '?'} `
      + `proponente="${proponente || '?'}" codigo=${otp} expira_em=${expiraEm} `
      + '— RESEND_API_KEY/RESEND_FROM_EMAIL não configuradas neste ambiente (ver api/lib/emailService.js); este código NUNCA é devolvido ao navegador do parceiro.'
    );
    return { enviado: false, canal: 'DEV_LOG', emailId: null, aviso: 'Nenhum provedor de e-mail real configurado neste ambiente — código disponível apenas no log do servidor (ambiente de desenvolvimento/homologação, nunca produção).' };
  }

  // eslint-disable-next-line class-methods-use-this
  async testConnection() {
    return { ok: process.env.APP_ENVIRONMENT !== 'production', mensagem: 'Fallback de log de desenvolvimento (DEV_LOG) — nenhuma chamada de rede real. Nunca disponível quando APP_ENVIRONMENT=production.' };
  }
}

class ResendOtpNotifier {
  constructor(provider) {
    this.provider = provider;
    this.canal = 'RESEND';
  }

  async sendOtp({ email, nome, numero, proponente, otp, expiraEm, expiraMinutos }) {
    const { subject, text, html } = buildOtpEmail({ nome, numero, proponente, otp, expiraMinutos });
    const { emailId } = await this.provider.send({ to: email, subject, html, text });
    // Fase 3.11.3 (seção 8): isto é só "Resend aceitou a requisição" — nunca "entregue".
    return { enviado: true, canal: 'RESEND', emailId, aviso: null };
  }

  async testConnection() {
    return this.provider.testConnection();
  }
}

/**
 * Fábrica: escolhe a implementação a partir de process.env (nunca decide "está em
 * produção" com base em nada além de APP_ENVIRONMENT, mesma variável já usada em todo o
 * resto do projeto — ver .env.example). RESEND_API_KEY + RESEND_FROM_EMAIL presentes →
 * sempre usa o Resend real, em qualquer ambiente (não há razão para NÃO usar o provedor
 * real em dev/staging se a chave estiver configurada — só produção SEM a chave é que
 * precisa falhar alto e claro em vez de cair no log).
 */
function buildOtpNotifier() {
  const provider = buildEmailProvider();
  if (provider) return new ResendOtpNotifier(provider);
  return new ConsoleDevNotifier();
}

module.exports = { buildOtpNotifier, ConsoleDevNotifier, ResendOtpNotifier };
