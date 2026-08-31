// OptiMon — Fase 3.11.2: canal de ENTREGA do código de confirmação (OTP) do aceite
// externo (seção 1, itens 10-11 do pedido de correção).
//
// Mesma divisão de responsabilidade já usada para a assinatura eletrônica (Fase 2.5,
// api/lib/signatureProvider.js): o OptiMon nunca fala diretamente com um provedor de
// e-mail específico — toda "entrega" passa por esta interface, para trocar de canal no
// futuro (Resend/SES/SMTP/etc.) sem tocar em nenhuma rota nem na lógica de geração/
// validação do OTP (que já é 100% real e fica inteiramente em api/routes/
// proposalsExternal.js + as funções app.iniciar_aceite_proposta_parceiro/
// app.confirmar_aceite_proposta_parceiro).
//
// Investigação real feita nesta fase (não presumida): este projeto NUNCA teve nenhuma
// infraestrutura de envio de e-mail transacional arbitrário — grep em todo api/lib e
// api/routes não encontra nenhuma lib de e-mail (nodemailer/Resend/SendGrid/SMTP). A
// única coisa parecida que existe é o Supabase Auth (auth.admin.inviteUserByEmail /
// auth.resetPasswordForEmail, usados em api/routes/users.js) — mas isso é o serviço de
// e-mail TEMPLATIZADO do GoTrue, escopado a convite/redefinição de senha de USUÁRIOS do
// OptiMon; não existe (e não deveria existir) um jeito de mandar um e-mail arbitrário de
// OTP por ali, e reaproveitar login/GoTrue para o parceiro externo contrariaria a
// decisão arquitetural, já tomada e repetida em toda a Fase 3.11, de que o parceiro
// NUNCA faz login no OptiMon.
//
// `ConsoleDevNotifier` é a única implementação concreta desta entrega: nunca fala com
// rede real, e — ponto crítico de segurança — o código em texto puro NUNCA é devolvido
// na resposta HTTP que o navegador do parceiro recebe (isso anularia o propósito do
// OTP). Ele só é escrito no log do próprio servidor (console.log), que só quem opera o
// backend consegue ler — exatamente como os testes automatizados desta fase o
// recuperam (grep no log do servidor local, nunca lendo a coluna otp_hash do banco,
// que é só o hash). Uma integração real de e-mail exigiria uma conta/credencial de
// provedor que esta sessão não tem — documentada como limitação explícita no relatório
// final, nunca escondida (mesmo padrão já usado para MockHomologacaoProvider).
function buildOtpNotifier() {
  return {
    /**
     * "Envia" o código — nesta implementação, só loga no servidor. NUNCA retorna o
     * código para quem chamou usar na resposta HTTP (ver api/routes/proposalsExternal.js
     * — o valor de retorno aqui é ignorado de propósito no caminho de resposta ao
     * parceiro).
     */
    async sendOtp({ email, nome, propostaNumero, otp, expiraEm }) {
      // eslint-disable-next-line no-console
      console.log(
        `[DEV-OTP-NAO-E-EMAIL-REAL] destinatario=${email} nome="${nome}" proposta=${propostaNumero} codigo=${otp} expira_em=${expiraEm} `
        + '— nenhum provedor de e-mail está configurado neste projeto (ver api/lib/otpNotifier.js); este código NUNCA é devolvido ao navegador do parceiro.'
      );
      return { enviado: false, canal: 'DEV_LOG', aviso: 'Nenhum provedor de e-mail real configurado — código disponível apenas no log do servidor (ambiente de desenvolvimento/homologação).' };
    },
  };
}

module.exports = { buildOtpNotifier };
