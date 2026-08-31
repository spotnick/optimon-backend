// OptiMon — Fase 3.11.3: Email Service — camada de abstração de PROVEDOR DE E-MAIL
// (mesma divisão de responsabilidade já usada para assinatura eletrônica, api/lib/
// signatureProvider.js): nenhuma rota fala diretamente com o SDK/API de um provedor
// específico — toda chamada passa por esta interface.
//
// Investigação real feita na Fase 3.11.3 (não presumida — ver comentário no topo da
// migration 20261004090000): este projeto NUNCA teve client de e-mail transacional em
// código (grep completo, sem resultado), mas o usuário confirmou que o Resend JÁ ESTÁ
// pago/configurado — hoje só como SMTP do Supabase Auth (convite/redefinição de senha de
// usuários do OptiMon), e que RESEND_API_KEY já existe como variável de ambiente na
// Railway. `ResendEmailProvider` é o client HTTP direto que faltava — chama a API REST
// do Resend (https://api.resend.com/emails) usando fetch nativo (Node 22, sem precisar
// adicionar a dependência "resend" ao package.json), lendo a chave e o remetente SÓ de
// process.env (nunca hardcoded, nunca inventado — seções 3/4 do pedido).

const RESEND_API_URL = 'https://api.resend.com';

/**
 * Interface conceitual — qualquer provedor real (Resend, SES, um SMTP genérico) segue
 * esta mesma forma. Nenhuma rota deve depender de método/campo específico de fornecedor.
 */
class EmailProvider {
  /* eslint-disable class-methods-use-this, no-unused-vars */
  async send({ to, subject, html, text }) { throw new Error('not implemented'); }
  // Diagnóstico de configuração/alcançabilidade — nunca expõe a chave em si (mesmo
  // padrão de ElectronicSignatureProvider.testConnection, seção 18 da Fase 2.5.1).
  async testConnection() { throw new Error('not implemented'); }
  /* eslint-enable class-methods-use-this, no-unused-vars */
}

/**
 * Client HTTP real da API do Resend (https://resend.com/docs/api-reference/emails/send-email).
 * Nunca loga a API key; nunca devolve a API key em nenhum retorno.
 */
// Campo privado de classe (# — nunca aparece em Object.keys/JSON.stringify/console.log
// de uma instância, ao contrário de uma propriedade comum `this.apiKey`) — defesa em
// profundidade (seção 21) contra vazamento acidental caso alguém, no futuro, logue ou
// serialize o objeto provider inteiro por engano em vez de só o resultado de send().
const apiKeys = new WeakMap();

class ResendEmailProvider extends EmailProvider {
  constructor({ apiKey, from }) {
    super();
    if (!apiKey) {
      throw new Error('CONFIGURACAO_INVALIDA: RESEND_API_KEY não informada ao ResendEmailProvider.');
    }
    if (!from) {
      throw new Error('CONFIGURACAO_INVALIDA: RESEND_FROM_EMAIL não informado ao ResendEmailProvider — seção 4: nunca inventar um remetente, use o endereço/domínio REAL já validado no Resend.');
    }
    apiKeys.set(this, apiKey);
    this.from = from;
  }

  get apiKey() {
    return apiKeys.get(this);
  }

  async send({ to, subject, html, text }) {
    if (!to) throw new Error('EMAIL_DESTINATARIO_OBRIGATORIO: destinatário do e-mail é obrigatório.');
    if (!subject) throw new Error('EMAIL_ASSUNTO_OBRIGATORIO: assunto do e-mail é obrigatório.');

    let res;
    try {
      res = await fetch(`${RESEND_API_URL}/emails`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${this.apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ from: this.from, to: [to], subject, html, text }),
      });
    } catch (networkErr) {
      // Nunca inclui this.apiKey na mensagem — só a causa de rede.
      throw new Error(`RESEND_INDISPONIVEL: falha de rede ao chamar a API do Resend (${networkErr.message || 'erro desconhecido'}).`);
    }

    let body;
    try {
      body = await res.json();
    } catch (_parseErr) {
      body = null;
    }

    if (!res.ok) {
      // O Resend devolve {name, message} de erro — nunca ecoa a API key, nunca ecoa o
      // corpo inteiro (pode conter o destinatário) além do necessário para diagnóstico.
      const msg = body?.message || `HTTP ${res.status}`;
      throw new Error(`RESEND_REJEITOU_ENVIO: ${msg} (status ${res.status}).`);
    }

    if (!body?.id) {
      throw new Error('RESEND_RESPOSTA_INESPERADA: o Resend respondeu 2xx mas sem "id" de e-mail — não é possível confirmar aceite pelo provedor.');
    }

    // Fase 3.11.3 (seção 8): isto é só "Resend aceitou a requisição" (EMAIL_ACEITO_
    // PELO_RESEND) — NUNCA "e-mail entregue" (isso só vem do webhook, seção 9).
    return { emailId: body.id };
  }

  // Nunca envia um e-mail de teste de verdade (isso gastaria uma cota real e poderia
  // confundir o destinatário) — a checagem real e honesta de configuração é: a chave e o
  // remetente estão presentes, e a API do Resend está alcançável e aceita a chave (GET
  // /domains é a chamada mais barata que exige autenticação válida, sem efeito colateral).
  async testConnection() {
    let res;
    try {
      res = await fetch(`${RESEND_API_URL}/domains`, {
        headers: { Authorization: `Bearer ${this.apiKey}` },
      });
    } catch (networkErr) {
      return { ok: false, mensagem: `Falha de rede ao contatar a API do Resend: ${networkErr.message || 'erro desconhecido'}.` };
    }
    if (res.status === 401 || res.status === 403) {
      return { ok: false, mensagem: 'RESEND_API_KEY configurada, mas rejeitada pelo Resend (401/403) — verifique se a chave é válida e está ativa.' };
    }
    if (!res.ok) {
      return { ok: false, mensagem: `Resend respondeu HTTP ${res.status} ao checar domínios.` };
    }
    let body;
    try {
      body = await res.json();
    } catch (_e) {
      body = null;
    }
    const dominios = Array.isArray(body?.data) ? body.data.map((d) => d.name) : [];
    const remetenteDominio = String(this.from).split('@')[1]?.replace(/>$/, '');
    const dominioValidado = dominios.includes(remetenteDominio);
    return {
      ok: true,
      mensagem: dominioValidado
        ? `Conectividade OK — domínio do remetente (${remetenteDominio}) está entre os domínios verificados no Resend.`
        : `Conectividade OK, mas o domínio do remetente (${remetenteDominio || 'desconhecido'}) NÃO aparece na lista de domínios verificados do Resend — confirme RESEND_FROM_EMAIL.`,
      dominioValidado,
    };
  }
}

/**
 * Fábrica: lê RESEND_API_KEY/RESEND_FROM_EMAIL de process.env — nunca de outro lugar,
 * nunca com um valor inventado como fallback (seção 3/4: "não inventar" o domínio
 * remetente). Devolve null quando não configurado — quem chama (api/lib/otpNotifier.js)
 * decide o que fazer com isso (nunca decide aqui, para manter esta camada burra/
 * reaproveitável por qualquer outro e-mail transacional que o OptiMon vier a precisar).
 */
function buildEmailProvider() {
  const apiKey = process.env.RESEND_API_KEY;
  const from = process.env.RESEND_FROM_EMAIL;
  if (!apiKey || !from) return null;
  return new ResendEmailProvider({ apiKey, from });
}

module.exports = { EmailProvider, ResendEmailProvider, buildEmailProvider };
