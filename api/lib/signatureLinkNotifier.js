// OptiMon — Fase 3.11.4: canal de ENTREGA do link individual de assinatura eletrônica.
// Mirror direto de api/lib/otpNotifier.js (Fase 3.11.3) — mesma estrutura, mesmo client
// Resend real (api/lib/emailService.js), mesmo fallback DEV_LOG que nunca roda em
// produção (falha alto e claro em vez de fingir sucesso). Reaproveitado, nunca
// duplicado: nenhuma chamada de rede nova é inventada aqui.

const { buildEmailProvider } = require('./emailService');
const { buildSignatureLinkEmail } = require('./signatureLinkEmailTemplate');

class ConsoleDevSignatureNotifier {
  constructor() {
    this.canal = 'DEV_LOG';
  }

  async sendSignatureLink({ email, nome, tipoDocumento, numeroDocumento, proponente, link, expiraDias, signerId }) {
    if (process.env.APP_ENVIRONMENT === 'production') {
      throw new Error('RESEND_NAO_CONFIGURADO: RESEND_API_KEY/RESEND_FROM_EMAIL ausentes em produção (APP_ENVIRONMENT=production) — o fallback de log de desenvolvimento nunca roda em produção. Configure as variáveis na Railway.');
    }
    // eslint-disable-next-line no-console
    console.log(
      `[DEV-SIGNATURE-LINK-NAO-E-EMAIL-REAL] destinatario=${email} nome="${nome}" signer_id=${signerId || '?'} `
      + `documento=${tipoDocumento || '?'} numero=${numeroDocumento || '?'} link=${link} `
      + '— RESEND_API_KEY/RESEND_FROM_EMAIL não configuradas neste ambiente; este link NUNCA é devolvido ao navegador de quem está criando o envelope (só ao próprio signatário, por e-mail, quando o Resend está configurado).'
    );
    return { enviado: false, canal: 'DEV_LOG', emailId: null, aviso: 'Nenhum provedor de e-mail real configurado neste ambiente — link disponível apenas no log do servidor (ambiente de desenvolvimento/homologação, nunca produção).' };
  }

  // eslint-disable-next-line class-methods-use-this
  async testConnection() {
    return { ok: process.env.APP_ENVIRONMENT !== 'production', mensagem: 'Fallback de log de desenvolvimento (DEV_LOG) — nenhuma chamada de rede real. Nunca disponível quando APP_ENVIRONMENT=production.' };
  }
}

class ResendSignatureNotifier {
  constructor(provider) {
    this.provider = provider;
    this.canal = 'RESEND';
  }

  async sendSignatureLink({ email, nome, tipoDocumento, numeroDocumento, proponente, link, expiraDias }) {
    const { subject, text, html } = buildSignatureLinkEmail({ nome, tipoDocumento, numeroDocumento, proponente, link, expiraDias });
    const { emailId } = await this.provider.send({ to: email, subject, html, text });
    // Fase 3.11.4 (mesma disciplina da seção 8/Fase 3.11.3): isto é só "Resend aceitou a
    // requisição" — nunca "entregue" (ENTREGUE só vem do webhook, ver emailWebhooks.js).
    return { enviado: true, canal: 'RESEND', emailId, aviso: null };
  }

  async testConnection() {
    return this.provider.testConnection();
  }
}

function buildSignatureLinkNotifier() {
  const provider = buildEmailProvider();
  if (provider) return new ResendSignatureNotifier(provider);
  return new ConsoleDevSignatureNotifier();
}

module.exports = { buildSignatureLinkNotifier, ConsoleDevSignatureNotifier, ResendSignatureNotifier };
