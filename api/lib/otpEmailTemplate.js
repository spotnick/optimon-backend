// OptiMon — Fase 3.11.3 (seção 7): template do e-mail de confirmação do aceite (OTP).
// Função pura — nada de rede/banco aqui, só monta subject/text/html a partir dos dados
// já validados/reais (numero e parceiro_nome vêm de app.iniciar_aceite_proposta_
// parceiro, nunca inventados). Nunca inclui piso/margem/governança/custo interno/dado
// interno da NICK — nenhum desses campos sequer é recebido por esta função.
//
// Fase 3.11.5 (item 3 do relato de produção: "assinatura do contrato deve ter token de
// validação"): o mesmo template agora atende 2 contextos — 'proposta' (Fase 3.11.2,
// texto original, inalterado por padrão) e 'assinatura' (novo, usado por
// app.assinatura_externa_assinar_iniciar via signaturesExternal.js) — nunca um 2º
// template paralelo só para trocar 2 frases.

const SUBJECT_PROPOSTA = 'OptiMon — Código de confirmação do aceite da proposta';
const SUBJECT_ASSINATURA = 'OptiMon — Código de confirmação da assinatura eletrônica';
const SUBJECT = SUBJECT_PROPOSTA;

function escapeHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function buildOtpEmail({ nome, numero, proponente, otp, expiraMinutos, contexto = 'proposta', docLabel }) {
  const nomeSeg = nome || 'representante';
  const numeroSeg = numero || '—';
  const proponenteSeg = proponente || '—';
  const minutos = Number.isFinite(Number(expiraMinutos)) ? Number(expiraMinutos) : 10;
  const isAssinatura = contexto === 'assinatura';
  const subject = isAssinatura ? SUBJECT_ASSINATURA : SUBJECT_PROPOSTA;
  const acaoTexto = isAssinatura
    ? 'a confirmação da sua assinatura eletrônica do documento:'
    : 'a confirmação do aceite da proposta comercial:';
  const linhaLabel = isAssinatura ? (docLabel || 'Documento') : 'Proposta';

  const text = [
    `Olá, ${nomeSeg}.`,
    '',
    `Você solicitou ${acaoTexto}`,
    '',
    `${linhaLabel}: ${numeroSeg}`,
    `Empresa: ${proponenteSeg}`,
    '',
    'Seu código de confirmação é:',
    '',
    otp,
    '',
    `Este código é válido por ${minutos} minutos.`,
    '',
    'Se você não solicitou esta confirmação, ignore este e-mail.',
    '',
    'OptiMon',
    'Optical Asset & Pricing Management',
  ].join('\n');

  const html = `<!doctype html>
<html lang="pt-BR">
<body style="margin:0;padding:0;background:#f4f5f7;font-family:Arial,Helvetica,sans-serif;color:#1a1a2e;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f5f7;padding:32px 0;">
    <tr>
      <td align="center">
        <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:8px;overflow:hidden;">
          <tr>
            <td style="background:#0f2540;padding:20px 32px;">
              <span style="color:#ffffff;font-size:18px;font-weight:bold;letter-spacing:0.5px;">OptiMon</span>
            </td>
          </tr>
          <tr>
            <td style="padding:32px;">
              <p style="margin:0 0 16px;font-size:15px;line-height:1.5;">Olá, <strong>${escapeHtml(nomeSeg)}</strong>.</p>
              <p style="margin:0 0 16px;font-size:15px;line-height:1.5;">Você solicitou ${escapeHtml(acaoTexto)}</p>
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px;font-size:14px;">
                <tr><td style="padding:4px 0;color:#555;">${escapeHtml(linhaLabel)}</td><td style="padding:4px 0;text-align:right;font-weight:bold;">${escapeHtml(numeroSeg)}</td></tr>
                <tr><td style="padding:4px 0;color:#555;">Empresa</td><td style="padding:4px 0;text-align:right;font-weight:bold;">${escapeHtml(proponenteSeg)}</td></tr>
              </table>
              <p style="margin:0 0 8px;font-size:15px;line-height:1.5;">Seu código de confirmação é:</p>
              <p style="margin:0 0 20px;text-align:center;">
                <span style="display:inline-block;font-size:32px;font-weight:bold;letter-spacing:8px;background:#f0f3f8;color:#0f2540;padding:14px 24px;border-radius:6px;">${escapeHtml(otp)}</span>
              </p>
              <p style="margin:0 0 16px;font-size:13px;line-height:1.5;color:#555;">Este código é válido por ${minutos} minutos.</p>
              <p style="margin:0 0 24px;font-size:13px;line-height:1.5;color:#555;">Se você não solicitou esta confirmação, ignore este e-mail.</p>
              <p style="margin:0;font-size:13px;line-height:1.4;color:#888;border-top:1px solid #eee;padding-top:16px;">
                <strong style="color:#0f2540;">OptiMon</strong><br />
                Optical Asset &amp; Pricing Management
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;

  return { subject, text, html };
}

module.exports = { buildOtpEmail, SUBJECT, SUBJECT_PROPOSTA, SUBJECT_ASSINATURA };
