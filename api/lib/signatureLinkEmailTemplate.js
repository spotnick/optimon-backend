// OptiMon — Fase 3.11.4 (seção 12): template do e-mail com o link individual de
// assinatura eletrônica. Função pura — nada de rede/banco aqui. Mirror direto de
// api/lib/otpEmailTemplate.js (Fase 3.11.3), mesma estrutura visual/de código, adaptado
// ao conteúdo do convite de assinatura em vez do código de confirmação de aceite.
//
// Nunca inclui piso/margem/desconto/governança/custo interno/dado interno da NICK — só
// recebe o necessário para o convite (nome do signatário, tipo/número do documento,
// link). Inclui uma frase curta e honesta sobre a natureza da assinatura (seção
// "PRINCÍPIO ICP-BRASIL FIRST" do schema original — nunca sugerir uma certificação que
// este sistema não oferece).

function subjectFor(tipoDocumento) {
  const rotulo = { PROPOSTA: 'da proposta', CONTRATO: 'do contrato', ADITIVO: 'do aditivo contratual' }[tipoDocumento] || 'do documento';
  return `OptiMon — Assinatura eletrônica ${rotulo}`;
}

function escapeHtml(str) {
  return String(str ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function rotuloDocumento(tipoDocumento) {
  return { PROPOSTA: 'Proposta comercial', CONTRATO: 'Contrato', ADITIVO: 'Aditivo contratual' }[tipoDocumento] || 'Documento';
}

function buildSignatureLinkEmail({ nome, tipoDocumento, numeroDocumento, proponente, link, expiraDias }) {
  const nomeSeg = nome || 'representante';
  const numeroSeg = numeroDocumento || '—';
  const proponenteSeg = proponente || '—';
  const dias = Number.isFinite(Number(expiraDias)) ? Number(expiraDias) : 30;
  const subject = subjectFor(tipoDocumento);
  const docLabel = rotuloDocumento(tipoDocumento);

  const text = [
    `Olá, ${nomeSeg}.`,
    '',
    `Você foi convidado a assinar eletronicamente o seguinte documento no OptiMon:`,
    '',
    `${docLabel}: ${numeroSeg}`,
    `Empresa: ${proponenteSeg}`,
    '',
    'Para revisar e assinar, acesse o link abaixo:',
    '',
    link,
    '',
    `Este link é pessoal e intransferível, válido por ${dias} dias.`,
    '',
    'Esta é uma assinatura eletrônica simples (evidenciada por link único enviado a este',
    'e-mail, IP e data/hora do aceite) — não é uma assinatura ICP-Brasil qualificada.',
    '',
    'Se você não esperava este e-mail, ignore-o.',
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
              <p style="margin:0 0 16px;font-size:15px;line-height:1.5;">Você foi convidado a assinar eletronicamente o seguinte documento:</p>
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px;font-size:14px;">
                <tr><td style="padding:4px 0;color:#555;">${escapeHtml(docLabel)}</td><td style="padding:4px 0;text-align:right;font-weight:bold;">${escapeHtml(numeroSeg)}</td></tr>
                <tr><td style="padding:4px 0;color:#555;">Empresa</td><td style="padding:4px 0;text-align:right;font-weight:bold;">${escapeHtml(proponenteSeg)}</td></tr>
              </table>
              <p style="margin:0 0 20px;text-align:center;">
                <a href="${escapeHtml(link)}" style="display:inline-block;background:#0f2540;color:#ffffff;font-size:15px;font-weight:bold;padding:14px 28px;border-radius:6px;text-decoration:none;">Revisar e assinar</a>
              </p>
              <p style="margin:0 0 16px;font-size:13px;line-height:1.5;color:#555;">Este link é pessoal e intransferível, válido por ${dias} dias.</p>
              <p style="margin:0 0 16px;font-size:12px;line-height:1.5;color:#888;">Esta é uma assinatura eletrônica simples (evidenciada por link único enviado a este e-mail, IP e data/hora do aceite) — não é uma assinatura ICP-Brasil qualificada.</p>
              <p style="margin:0 0 24px;font-size:13px;line-height:1.5;color:#555;">Se você não esperava este e-mail, ignore-o.</p>
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

module.exports = { buildSignatureLinkEmail };
