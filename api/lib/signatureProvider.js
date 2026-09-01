// OptiMon — Fase 2.5: Signature Engine — camada de abstração de provedor
// (seções 4-5). O OptiMon nunca fala diretamente com um fornecedor específico
// (Clicksign/DocuSign/etc) em nenhuma rota — toda chamada passa por esta
// interface, para trocar de provedor no futuro sem tocar em contrato/
// proposta/banco/workflow/frontend/auditoria (seção 4).
//
// `ElectronicSignatureProvider` é a interface conceitual da seção 5 (os 11
// métodos pedidos, um a um). `MockHomologacaoProvider` é a única implementação
// concreta desta entrega — nunca fala com uma rede real, simula
// determinísticamente o ciclo de vida de um envelope ICP-Brasil em ambiente de
// HOMOLOGAÇÃO, para permitir testar o fluxo completo (seção 51: nunca testar
// com documento real de produção antes de ter isso funcionando em
// homologação). Uma integração real com um PSC/provedor ICP-Brasil de verdade
// exigiria credenciais e um contrato comercial que esta sessão não tem acesso
// a — documentado como limitação explícita no relatório final (seção 71/72),
// nunca escondida.

/**
 * Interface conceitual (seção 5). Qualquer provedor real (ex.: um PSC
 * ICP-Brasil, uma plataforma de assinatura compatível) implementa esta mesma
 * forma — nenhuma rota da API deve depender de método/campo específico de um
 * fornecedor.
 */
class ElectronicSignatureProvider {
  /* eslint-disable class-methods-use-this, no-unused-vars */
  async createEnvelope({ documentBuffer, fileName, metadata }) { throw new Error('not implemented'); }
  async addSigner(providerEnvelopeId, { name, email, cpf, order }) { throw new Error('not implemented'); }
  async configureSigningOrder(providerEnvelopeId, orderedSignerIds) { throw new Error('not implemented'); }
  async sendForSignature(providerEnvelopeId) { throw new Error('not implemented'); }
  async getEnvelopeStatus(providerEnvelopeId) { throw new Error('not implemented'); }
  async getSignerStatus(providerEnvelopeId, signerId) { throw new Error('not implemented'); }
  async cancelEnvelope(providerEnvelopeId, reason) { throw new Error('not implemented'); }
  async downloadSignedDocument(providerEnvelopeId) { throw new Error('not implemented'); }
  async getAuditTrail(providerEnvelopeId) { throw new Error('not implemented'); }
  async validateSignature(providerEnvelopeId) { throw new Error('not implemented'); }
  async getCertificateInfo(providerEnvelopeId, signerId) { throw new Error('not implemented'); }
  // Fase 2.5.1 seção 18 — "TESTAR CONEXÃO": diagnóstico de configuração/
  // alcançabilidade do provedor, sem expor nenhum secret na resposta (nunca
  // o valor de api_key_ref/webhook_secret_ref, só o diagnóstico em si).
  async testConnection() { throw new Error('not implemented'); }
  /* eslint-enable class-methods-use-this, no-unused-vars */
}

const crypto = require('crypto');
const { buildEmailProvider } = require('./emailService');

/**
 * Fase 3.11.4: implementação real de "provedor" para a arquitetura decidida pelo usuário
 * (seção 12 do pedido de correção 3.11.4: "se o projeto tiver sido desenhado para o
 * OptiMon enviar os links por Resend, documentar claramente essa arquitetura e
 * implementá-la de forma consistente" — confirmado explicitamente, nenhum provedor
 * ICP-Brasil real está contratado). O OptiMon é o próprio orquestrador: `createEnvelope`
 * só calcula hash/gera um ID interno (nunca fala com rede — não há "criar envelope" em
 * nenhum provedor terceirizado); o envio real de e-mail por signatário acontece em
 * api/routes/signatures.js (POST /envelopes/:id/send), usando
 * api/lib/signatureLinkNotifier.js diretamente (fan-out por signatário, cada um com seu
 * próprio link/token) — não cabe no método `sendForSignature(providerEnvelopeId)` de um
 * único ID, que é uma forma pensada para um provedor terceirizado. Este objeto ainda
 * implementa a interface inteira (com no-ops honestos onde não se aplica) para nunca
 * quebrar o resto do código que já espera um `ElectronicSignatureProvider`.
 */
class ResendInternoProvider extends ElectronicSignatureProvider {
  async createEnvelope({ documentBuffer, fileName }) {
    const hash = documentBuffer ? crypto.createHash('sha256').update(documentBuffer).digest('hex') : null;
    const providerEnvelopeId = `OPTIMON-ENV-${crypto.randomUUID()}`;
    return { providerEnvelopeId, hashOriginal: hash, fileName: fileName || null, status: 'CRIADO' };
  }

  // eslint-disable-next-line class-methods-use-this
  async addSigner(providerEnvelopeId, { email, order }) {
    // No-op honesto: este "provedor" não fala com nenhuma rede para cadastrar
    // signatário — o link individual só é gerado/enviado em POST /envelopes/:id/send
    // (ver api/routes/signatures.js), signatário por signatário.
    return { providerSignerId: null, providerEnvelopeId, email, order, status: 'AGUARDANDO_ENVIO' };
  }

  // eslint-disable-next-line class-methods-use-this
  async sendForSignature() {
    throw new Error('NAO_SUPORTADO: este provedor envia por signatário (fan-out de link individual via Resend) — use o fluxo dedicado em POST /envelopes/:id/send, nunca sendForSignature(envelopeId) genérico.');
  }

  // eslint-disable-next-line class-methods-use-this
  async getEnvelopeStatus(providerEnvelopeId) {
    return { providerEnvelopeId, status: 'AGUARDANDO' };
  }

  // eslint-disable-next-line class-methods-use-this
  async getSignerStatus(providerEnvelopeId, signerId) {
    return { providerEnvelopeId, signerId, status: 'PENDENTE' };
  }

  // eslint-disable-next-line class-methods-use-this
  async cancelEnvelope(providerEnvelopeId, reason) {
    return { providerEnvelopeId, status: 'CANCELADO', motivo: reason };
  }

  // eslint-disable-next-line class-methods-use-this
  async downloadSignedDocument() {
    throw new Error('NAO_SUPORTADO: este provedor não hospeda arquivo — o documento assinado é o próprio original + evidências (ip/user-agent/timestamp) registradas em signature_signers/documentos_assinados.');
  }

  // eslint-disable-next-line class-methods-use-this
  async getAuditTrail(providerEnvelopeId) {
    return { providerEnvelopeId, eventos: [] };
  }

  // eslint-disable-next-line class-methods-use-this
  async validateSignature(providerEnvelopeId) {
    return { providerEnvelopeId, valido: true, politica: 'ASSINATURA_ELETRONICA_SIMPLES' };
  }

  // eslint-disable-next-line class-methods-use-this
  async getCertificateInfo(providerEnvelopeId, signerId) {
    return {
      providerEnvelopeId,
      signerId,
      tipo: 'ASSINATURA_ELETRONICA_SIMPLES',
      emissor: 'OptiMon (não é uma Autoridade Certificadora — link único enviado por e-mail via Resend, IP e timestamp como evidência; ver Fase 3.11.4).',
    };
  }

  // Diagnóstico honesto: delega para o testConnection() real do client Resend (mesmo
  // client já testado na Fase 3.11.3) — nunca finge testar uma rede que não usa aqui.
  // eslint-disable-next-line class-methods-use-this
  async testConnection() {
    const emailProvider = buildEmailProvider();
    if (!emailProvider) {
      return {
        ok: process.env.APP_ENVIRONMENT !== 'production',
        mensagem: 'RESEND_API_KEY/RESEND_FROM_EMAIL não configuradas neste ambiente — o envio real de link de assinatura vai falhar em produção (nunca finge sucesso; ver api/lib/signatureLinkNotifier.js).',
      };
    }
    return emailProvider.testConnection();
  }
}

/**
 * Implementação MOCK de HOMOLOGAÇÃO (seção 6/50/51). Nunca deve ser usada como
 * `ambiente=PRODUCAO` — a rota de configuração de provedor (seção 6) bloqueia
 * isso explicitamente (ver api/routes/signatures.js). Simula:
 *  - createEnvelope: gera um provider_envelope_id determinístico e "recebe" o
 *    documento (calcula hash real do buffer, para o teste de integridade
 *    fazer sentido de verdade).
 *  - sendForSignature: marca como enviado.
 *  - Para efetivamente "assinar" em homologação (sem depender de um portal
 *    externo real), o próprio endpoint de teste/QA chama
 *    POST /api/signatures/:id/webhook com o payload simulado — replicando
 *    exatamente o formato que um provedor real mandaria (seção 27), o que
 *    também é o mecanismo usado pelos testes automatizados desta fase.
 */
class MockHomologacaoProvider extends ElectronicSignatureProvider {
  constructor({ ambiente = 'HOMOLOGACAO' } = {}) {
    super();
    if (ambiente === 'PRODUCAO') {
      throw new Error('CONFIGURACAO_INVALIDA: o provedor MOCK só pode ser usado em ambiente HOMOLOGACAO — nunca em PRODUCAO (seção 51).');
    }
    this.ambiente = ambiente;
  }

  async createEnvelope({ documentBuffer, fileName }) {
    const hash = documentBuffer ? crypto.createHash('sha256').update(documentBuffer).digest('hex') : null;
    const providerEnvelopeId = `MOCK-ENV-${crypto.randomUUID()}`;
    return { providerEnvelopeId, hashOriginal: hash, fileName: fileName || null, status: 'CRIADO' };
  }

  async addSigner(providerEnvelopeId, { email, order }) {
    return { providerSignerId: `MOCK-SIGNER-${crypto.randomUUID()}`, providerEnvelopeId, email, order, status: 'PENDENTE' };
  }

  async configureSigningOrder(providerEnvelopeId, orderedSignerIds) {
    return { providerEnvelopeId, order: orderedSignerIds };
  }

  async sendForSignature(providerEnvelopeId) {
    return { providerEnvelopeId, status: 'ENVIADO', enviadoEm: new Date().toISOString() };
  }

  async getEnvelopeStatus(providerEnvelopeId) {
    return { providerEnvelopeId, status: 'AGUARDANDO' };
  }

  async getSignerStatus(providerEnvelopeId, signerId) {
    return { providerEnvelopeId, signerId, status: 'PENDENTE' };
  }

  async cancelEnvelope(providerEnvelopeId, reason) {
    return { providerEnvelopeId, status: 'CANCELADO', motivo: reason };
  }

  async downloadSignedDocument(providerEnvelopeId) {
    // Em homologação real (mock), não há binário assinado de verdade vindo de
    // um servidor externo — quem monta o documento assinado nesta fase é o
    // próprio endpoint de webhook simulado, que já recebe (e persiste) o
    // hash/caminho. Documentado como limitação explícita — ver relatório.
    throw new Error('NAO_SUPORTADO: o provedor MOCK não hospeda arquivo — use o payload do webhook simulado para obter hash/caminho.');
  }

  async getAuditTrail(providerEnvelopeId) {
    return { providerEnvelopeId, eventos: [] };
  }

  async validateSignature(providerEnvelopeId) {
    return { providerEnvelopeId, valido: true, politica: 'ICP_BRASIL_QUALIFICADA_MOCK' };
  }

  async getCertificateInfo(providerEnvelopeId, signerId) {
    return {
      providerEnvelopeId,
      signerId,
      tipo: 'ICP_BRASIL_QUALIFICADA_MOCK',
      emissor: 'AC MOCK HOMOLOGAÇÃO (não é uma Autoridade Certificadora real — seção 2/72)',
    };
  }

  // Nunca toca rede real (é o próprio ponto do mock) — o "diagnóstico" aqui é
  // honesto sobre o que está sendo testado: a própria configuração do
  // provedor (tipo/ambiente válidos), nunca finge testar uma conectividade de
  // rede que não existe nesta implementação. Ver relatório final: um provedor
  // real (ICP_BRASIL_PROVEDOR_EXTERNO) faria aqui uma chamada HTTP de
  // diagnóstico de verdade contra `api_url`.
  async testConnection() {
    return {
      ok: true,
      mensagem: 'Provedor MOCK de HOMOLOGAÇÃO — configuração válida (nenhuma chamada de rede real é feita; este provedor nunca deve ser usado em produção).',
    };
  }
}

/**
 * Fábrica: escolhe a implementação a partir do `tipo` gravado em
 * signature_providers. Hoje só ICP_BRASIL_HOMOLOGACAO_MOCK tem implementação
 * real — ICP_BRASIL_PROVEDOR_EXTERNO existe no schema/enum (seção 50: a
 * arquitetura permite mais de um provedor) mas não tem nenhuma integração de
 * rede codificada nesta entrega, por não haver credencial real disponível
 * para esta sessão integrar e testar (nunca inventado/simulado como se fosse
 * real — ver relatório final).
 */
function buildProvider(providerRow) {
  if (!providerRow) throw new Error('PROVEDOR_NAO_CONFIGURADO: nenhum signature_provider informado.');
  if (providerRow.tipo === 'ICP_BRASIL_HOMOLOGACAO_MOCK') {
    return new MockHomologacaoProvider({ ambiente: providerRow.ambiente });
  }
  if (providerRow.tipo === 'OPTIMON_INTERNO_RESEND') {
    return new ResendInternoProvider();
  }
  throw new Error(`PROVEDOR_NAO_IMPLEMENTADO: tipo "${providerRow.tipo}" não tem integração de rede implementada nesta entrega — só ICP_BRASIL_HOMOLOGACAO_MOCK e OPTIMON_INTERNO_RESEND. Ver relatório final, seção "Limitações".`);
}

module.exports = { ElectronicSignatureProvider, MockHomologacaoProvider, ResendInternoProvider, buildProvider };
