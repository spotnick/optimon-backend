// OptiMon — cliente da API (Railway). Todo dado de negócio passa por aqui — nunca por
// chamadas diretas ao Supabase (seção 32/33). Cada função pega o JWT da sessão atual e
// manda como Authorization: Bearer <jwt>; o servidor sempre recalcula/revalida tudo.

import { supabase } from './supabaseClient';

const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:3001';

class ApiError extends Error {
  constructor(message, status, payload) {
    super(message);
    this.status = status;
    // Fase 2.5.3: /api/users/invite e /api/users/reconcile agora devolvem
    // campos estruturados no corpo de erro (state: 'B_JA_REGISTRADO' |
    // 'C_AUTH_ORFAO' | 'D_PERFIL_ORFAO', auth_user_id, rollback) para o
    // frontend poder oferecer a ação certa (ex.: "Recuperar Perfil") em vez
    // de só mostrar o texto do erro — ver api/routes/users.js.
    this.payload = payload || null;
    this.state = payload?.state || null;
  }
}

async function request(path, { method = 'GET', body } = {}) {
  const { data: { session } } = await supabase.auth.getSession();
  const token = session?.access_token;

  const res = await fetch(`${API_URL}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  if (res.status === 204) return null;

  let payload = null;
  try {
    payload = await res.json();
  } catch {
    // resposta sem corpo JSON (ex.: erro de rede genérico) — segue com payload null.
  }

  // BUG REAL encontrado em produção (Fase 2.5.1, correção pós-entrega): 207 Multi-Status
  // está dentro da faixa 200-299, então `res.ok` era true para ele — POST
  // /api/users/invite usava 207 propositalmente para sinalizar sucesso PARCIAL (identidade
  // criada no Supabase Auth, mas o INSERT em public.usuarios falhou), mas como isso nunca
  // era tratado como erro aqui, a tela de Usuários exibia sempre a mensagem de sucesso
  // padrão ("Convite enviado para <e-mail>.") — o admin nunca via o aviso real, e o
  // usuário nunca aparecia na listagem porque a linha em public.usuarios nunca existiu.
  // A Fase 2.5.3 removeu esse 207 da própria rota (agora responde 400/409/500 com rollback
  // controlado — ver api/routes/users.js) — o check abaixo continua aqui como cinto de
  // segurança permanente contra regressão: nenhum futuro 2xx parcial volta a ser engolido.
  if (!res.ok || res.status === 207) {
    throw new ApiError(payload?.error || `Erro ${res.status} ao chamar ${path}.`, res.status, payload);
  }
  return payload;
}

export const api = {
  health: () => request('/health'),
  version: () => request('/api/version'),

  cities: {
    list: (filtro) => request(`/api/cities${filtro ? `?filtro=${filtro}` : ''}`),
    detail: (id) => request(`/api/cities/${id}`),
    create: (body) => request('/api/cities', { method: 'POST', body }),
    update: (id, body) => request(`/api/cities/${id}`, { method: 'PATCH', body }),
    archive: (id, body) => request(`/api/cities/${id}/archive`, { method: 'POST', body }),
    restore: (id, body) => request(`/api/cities/${id}/restore`, { method: 'POST', body }),
  },

  infra: {
    // incluirArquivados=true traz também POP/segmento/cabo/poste arquivados e Porta PON
    // INATIVA — usado pela tela "Editar Infraestrutura" (filtro ATIVOS/ARQUIVADOS/TODOS
    // é aplicado no cliente sobre essa árvore completa, seção 20).
    tree: (cidadeId, incluirArquivados) =>
      request(`/api/infra/tree?cidade_id=${cidadeId}${incluirArquivados ? '&incluir_arquivados=true' : ''}`),

    createPop: (body) => request('/api/infra/pops', { method: 'POST', body }),
    updatePop: (id, body) => request(`/api/infra/pops/${id}`, { method: 'PATCH', body }),
    archivePop: (id, body) => request(`/api/infra/pops/${id}/archive`, { method: 'POST', body }),
    restorePop: (id, body) => request(`/api/infra/pops/${id}/restore`, { method: 'POST', body }),

    listSegments: (cidadeId) => request(`/api/infra/segments?cidade_id=${cidadeId}`),
    createSegment: (body) => request('/api/infra/segments', { method: 'POST', body }),
    updateSegment: (id, body) => request(`/api/infra/segments/${id}`, { method: 'PATCH', body }),
    archiveSegment: (id, body) => request(`/api/infra/segments/${id}/archive`, { method: 'POST', body }),
    restoreSegment: (id, body) => request(`/api/infra/segments/${id}/restore`, { method: 'POST', body }),

    createCable: (body) => request('/api/infra/cables', { method: 'POST', body }),
    updateCable: (id, body) => request(`/api/infra/cables/${id}`, { method: 'PATCH', body }),
    archiveCable: (id, body) => request(`/api/infra/cables/${id}/archive`, { method: 'POST', body }),
    restoreCable: (id, body) => request(`/api/infra/cables/${id}/restore`, { method: 'POST', body }),
    cableFibers: (cableId) => request(`/api/infra/cables/${cableId}/fibers`),
    updateFiber: (id, body) => request(`/api/infra/fibers/${id}`, { method: 'PATCH', body }),

    createPole: (body) => request('/api/infra/poles', { method: 'POST', body }),
    updatePole: (id, body) => request(`/api/infra/poles/${id}`, { method: 'PATCH', body }),
    archivePole: (id, body) => request(`/api/infra/poles/${id}/archive`, { method: 'POST', body }),
    restorePole: (id, body) => request(`/api/infra/poles/${id}/restore`, { method: 'POST', body }),

    createPonPort: (body) => request('/api/infra/pon-ports', { method: 'POST', body }),
    updatePonPort: (id, body) => request(`/api/infra/pon-ports/${id}`, { method: 'PATCH', body }),
    archivePonPort: (id, body) => request(`/api/infra/pon-ports/${id}/archive`, { method: 'POST', body }),
    restorePonPort: (id, body) => request(`/api/infra/pon-ports/${id}/restore`, { method: 'POST', body }),
  },

  pricing: {
    calculate: (params) => request('/api/pricing/calculate', { method: 'POST', body: params }),
    growthCurve: (params) => request('/api/pricing/growth-curve', { method: 'POST', body: params }),
    horizonTable: (params) => request('/api/pricing/horizon-table', { method: 'POST', body: params }),
    get: (id) => request(`/api/pricing/${id}`),
    currentRole: () => request('/api/pricing/current-role'),
    infraFloorNegotiation: (query) => request(`/api/pricing/infra-floor-negotiation?${new URLSearchParams(query)}`),
    fibrasIndicadores: (query) => request(`/api/pricing/fibras-indicadores?${new URLSearchParams(query)}`),
    ramp: () => request('/api/pricing/ramp'),
    indices: (indice) => request(`/api/pricing/indices${indice ? `?indice=${indice}` : ''}`),
    override: (body) => request('/api/pricing/override', { method: 'POST', body }),
    approve: (body) => request('/api/pricing/approve', { method: 'POST', body }),
    // Fase 3.8 (item 3.8-12): capacidade + receita rateada por POP de um contrato
    // Multi-POP — a rota já existia desde a Fase 2.1 (backend), mas nunca tinha sido
    // chamada por nenhuma tela do frontend até agora.
    capacityByPop: (contratoId) => request(`/api/pricing/capacity-by-pop?contrato_id=${contratoId}`),
  },

  simulations: {
    save: (body) => request('/api/simulations', { method: 'POST', body }),
    list: (contratoId) => request(`/api/simulations${contratoId ? `?contrato_id=${contratoId}` : ''}`),
  },

  proposals: {
    create: (body) => request('/api/proposals', { method: 'POST', body }),
    list: (params = {}) => request(`/api/proposals?${new URLSearchParams(params)}`),
    get: (id) => request(`/api/proposals/${id}`),
    getPublic: (id) => request(`/api/proposals/${id}/public`),
    versions: (id) => request(`/api/proposals/${id}/versions`),
    newVersion: (id, body = {}) => request(`/api/proposals/${id}/version`, { method: 'POST', body }),
    duplicate: (id, body = {}) => request(`/api/proposals/${id}/duplicate`, { method: 'POST', body }),
    approve: (id, body = {}) => request(`/api/proposals/${id}/approve`, { method: 'POST', body }),
    reject: (id, body) => request(`/api/proposals/${id}/reject`, { method: 'POST', body }),
    changeStatus: (id, body) => request(`/api/proposals/${id}/status`, { method: 'POST', body }),
    // Fase 3.10 (Problema 2, seção 2.1): edita capa/observações comerciais/próximos
    // passos depois da criação — única rota que permite isso (POST / só aceita capa na
    // criação).
    update: (id, body) => request(`/api/proposals/${id}`, { method: 'PATCH', body }),
    // Export não passa por request() — é um download binário (PDF/DOCX) autenticado, não
    // JSON; ver ProposalDetail.jsx (busca com fetch() + Blob, mesmo padrão de token).
    exportPath: (id, formato, modo) => `/api/proposals/${id}/export?formato=${formato}${modo ? `&modo=${modo}` : ''}`,
  },

  partners: {
    list: (params = {}) => request(`/api/partners?${new URLSearchParams(params)}`),
    get: (id) => request(`/api/partners/${id}`),
    create: (body) => request('/api/partners', { method: 'POST', body }),
    update: (id, body) => request(`/api/partners/${id}`, { method: 'PATCH', body }),
    deactivate: (id, body = {}) => request(`/api/partners/${id}/deactivate`, { method: 'POST', body }),
    reactivate: (id, body = {}) => request(`/api/partners/${id}/reactivate`, { method: 'POST', body }),
    responsaveis: (id, incluirRemovidos) => request(`/api/partners/${id}/responsaveis${incluirRemovidos ? '?incluir_removidos=true' : ''}`),
    addResponsavel: (id, body) => request(`/api/partners/${id}/responsaveis`, { method: 'POST', body }),
    updateResponsavel: (id, respId, body) => request(`/api/partners/${id}/responsaveis/${respId}`, { method: 'PATCH', body }),
    removeResponsavel: (id, respId) => request(`/api/partners/${id}/responsaveis/${respId}`, { method: 'DELETE' }),
    restoreResponsavel: (id, respId) => request(`/api/partners/${id}/responsaveis/${respId}/restore`, { method: 'POST' }),
    documentos: (id) => request(`/api/partners/${id}/documentos`),
    // Upload multipart — não passa por request() (JSON-only); ver uploadMultipart abaixo.
    uploadDocumento: (id, formData) => uploadMultipart(`/api/partners/${id}/documentos`, formData),
    documentoDownloadUrl: (docId) => request(`/api/partners/documentos/${docId}/download`),
  },

  users: {
    list: (params = {}) => request(`/api/users?${new URLSearchParams(params)}`),
    get: (id) => request(`/api/users/${id}`),
    create: (body) => request('/api/users', { method: 'POST', body }),
    // Fase 2.5.1 — fluxo novo: convida via Supabase Auth + completa o
    // cadastro numa chamada só, nunca pede UUID (ver api/routes/users.js).
    invite: (body) => request('/api/users/invite', { method: 'POST', body }),
    resendInvite: (id) => request(`/api/users/${id}/resend-invite`, { method: 'POST' }),
    resetAccess: (id) => request(`/api/users/${id}/reset-access`, { method: 'POST' }),
    deactivate: (id, body = {}) => request(`/api/users/${id}/deactivate`, { method: 'POST', body }),
    reactivate: (id, body = {}) => request(`/api/users/${id}/reactivate`, { method: 'POST', body }),
    // Fase 3 (item 3.8): exclusão FÍSICA controlada — nunca confundir com deactivate
    // (soft-delete) acima. Só ADMINISTRADOR, motivo obrigatório, e sempre bloqueada pelo
    // servidor se o usuário tiver qualquer histórico vinculado.
    hardDelete: (id, body) => request(`/api/users/${id}/hard-delete`, { method: 'POST', body }),
    update: (id, body) => request(`/api/users/${id}`, { method: 'PATCH', body }),
    touchAccess: () => request('/api/users/me/touch-access', { method: 'POST' }),
    // Fase 2.5.3 — Estado C (identidade Auth sem perfil): completa o
    // cadastro sem reenviar convite nem criar identidade nova.
    reconcile: (body) => request('/api/users/reconcile', { method: 'POST', body }),
    // Fase 2.5.3 — diagnóstico de integridade Auth x public.usuarios, usado
    // pelo indicador em Usuários e pela tela /usuarios/saude.
    health: () => request('/api/users/health'),
  },

  signatures: {
    providers: () => request('/api/signatures/providers'),
    createProvider: (body) => request('/api/signatures/providers', { method: 'POST', body }),
    updateProvider: (id, body) => request(`/api/signatures/providers/${id}`, { method: 'PATCH', body }),
    testConnection: (id) => request(`/api/signatures/providers/${id}/test-connection`, { method: 'POST' }),
    envelopes: (params = {}) => request(`/api/signatures/envelopes?${new URLSearchParams(params)}`),
    envelope: (id) => request(`/api/signatures/envelopes/${id}`),
    createEnvelope: (formData) => uploadMultipart('/api/signatures/envelopes', formData),
    addSigner: (id, body) => request(`/api/signatures/envelopes/${id}/signers`, { method: 'POST', body }),
    send: (id) => request(`/api/signatures/envelopes/${id}/send`, { method: 'POST' }),
    cancel: (id, body) => request(`/api/signatures/envelopes/${id}/cancel`, { method: 'POST', body }),
    document: (id) => request(`/api/signatures/envelopes/${id}/document`),
    audit: (id) => request(`/api/signatures/envelopes/${id}/audit`),
    validate: (id) => request(`/api/signatures/envelopes/${id}/validate`, { method: 'POST' }),
  },

  contracts: {
    list: (filtro) => request(`/api/contracts${filtro ? `?filtro=${filtro}` : ''}`),
    get: (id) => request(`/api/contracts/${id}`),
    generate: (body) => request('/api/contracts/generate', { method: 'POST', body }),
    activate: (id) => request(`/api/contracts/${id}/activate`, { method: 'POST' }),
    // Fase 3.8 (item 3.8-14): encerrar (fim natural) ou rescindir (antecipado) — motivo
    // sempre obrigatório (ver app.encerrar_contrato).
    terminate: (id, body) => request(`/api/contracts/${id}/terminate`, { method: 'POST', body }),
    reajuste: (id, body) => request(`/api/contracts/${id}/reajuste`, { method: 'POST', body }),
    aditivos: (id) => request(`/api/contracts/${id}/aditivos`),
    createAditivo: (id, body) => request(`/api/contracts/${id}/aditivos`, { method: 'POST', body }),
    updateAditivo: (id, aditivoId, body) => request(`/api/contracts/${id}/aditivos/${aditivoId}`, { method: 'PATCH', body }),
    sendAditivoSignature: (id, aditivoId, body) => request(`/api/contracts/${id}/aditivos/${aditivoId}/send-signature`, { method: 'POST', body }),
    activateAditivo: (id, aditivoId) => request(`/api/contracts/${id}/aditivos/${aditivoId}/activate`, { method: 'POST' }),
    dashboard: () => request('/api/contracts/dashboard/resumo'),
    gerarAlertas: () => request('/api/contracts/dashboard/gerar-alertas', { method: 'POST' }),
    alertas: (params = {}) => request(`/api/contracts/dashboard/alertas?${new URLSearchParams(params)}`),
    resolverAlerta: (id) => request(`/api/contracts/dashboard/alertas/${id}/resolver`, { method: 'POST' }),
    dashboardCapacidade: () => request('/api/contracts/dashboard/capacidade'),
    dashboardCenariosPortfolio: (horizontes) => request(`/api/contracts/dashboard/cenarios-portfolio${horizontes ? `?horizontes=${horizontes.join(',')}` : ''}`),
    // Fase 3 (item 3.7): minuta de contrato (documento gerado, sempre "SUJEITA À
    // APROVAÇÃO JURÍDICA") + guardrails contratuais (exclusividade/fibra de terceiros/
    // rede própria) + clientes reservados (ex.: exceção Prefeitura).
    minutaPath: (id, formato) => `/api/contracts/${id}/minuta?formato=${formato}`,
    updateRegras: (id, body) => request(`/api/contracts/${id}/regras`, { method: 'PATCH', body }),
    addClienteReservado: (id, body) => request(`/api/contracts/${id}/clientes-reservados`, { method: 'POST', body }),
    updateClienteReservado: (id, reservaId, body) => request(`/api/contracts/${id}/clientes-reservados/${reservaId}`, { method: 'PATCH', body }),
    // Fase 3.8 (itens 3.8-09/3.8-10): workflow Engenharia → Comercial → Diretoria para
    // exceção de fibra de terceiros / rede própria.
    addRegraSolicitacao: (id, body) => request(`/api/contracts/${id}/regras-solicitacoes`, { method: 'POST', body }),
    parecerEngenharia: (id, solId, body) => request(`/api/contracts/${id}/regras-solicitacoes/${solId}/parecer-engenharia`, { method: 'PATCH', body }),
    parecerComercial: (id, solId, body) => request(`/api/contracts/${id}/regras-solicitacoes/${solId}/parecer-comercial`, { method: 'PATCH', body }),
    decidirRegraSolicitacao: (id, solId, body) => request(`/api/contracts/${id}/regras-solicitacoes/${solId}/decidir`, { method: 'PATCH', body }),
  },

  audit: {
    list: (params = {}) => request(`/api/audit?${new URLSearchParams(params)}`),
    logLogin: () => request('/api/audit/login', { method: 'POST' }),
  },

  reports: {
    get: (tipo) => request(`/api/reports/${tipo}`),
    faturamentoReal: () => request('/api/reports/faturamento-real/status'),
    csvPath: (tipo) => `/api/reports/${tipo}/csv`,
  },

  // Fase 3.8 (item 3.8-11): registro formal de equipamentos cedidos (OLT/ONU/ONT/fonte/
  // switch) e devolução na rescisão contratual.
  assets: {
    list: (params = {}) => request(`/api/assets?${new URLSearchParams(params)}`),
    get: (id) => request(`/api/assets/${id}`),
    create: (body) => request('/api/assets', { method: 'POST', body }),
    update: (id, body) => request(`/api/assets/${id}`, { method: 'PATCH', body }),
    archive: (id) => request(`/api/assets/${id}`, { method: 'DELETE' }),
    abrirDevolucao: (id, body) => request(`/api/assets/${id}/devolucao`, { method: 'POST', body }),
    confirmarDevolucao: (id, devolucaoId, body) => request(`/api/assets/${id}/devolucao/${devolucaoId}`, { method: 'PATCH', body }),
  },
};

// Download autenticado de binário (export PDF/DOCX de proposta — seção 8/9). Devolve
// {blob, fileName} pronto pra disparar o download no navegador (ver ProposalDetail.jsx).
async function apiDownload(path) {
  const { data: { session } } = await supabase.auth.getSession();
  const token = session?.access_token;
  const res = await fetch(`${API_URL}${path}`, {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });
  if (!res.ok) {
    let message = `Erro ${res.status} ao baixar o arquivo.`;
    try { message = (await res.json())?.error || message; } catch { /* corpo não-JSON */ }
    throw new ApiError(message, res.status);
  }
  const disposition = res.headers.get('Content-Disposition') || '';
  const match = disposition.match(/filename="?([^"]+)"?/);
  const fileName = match ? match[1] : 'proposta.pdf';
  const blob = await res.blob();
  return { blob, fileName };
}

// Upload multipart autenticado (documento de proponente / documento original de um
// envelope de assinatura, Fase 2.5 seções 19/24) — nunca passa por request() porque o
// corpo é FormData, não JSON (o navegador define o Content-Type multipart com boundary
// sozinho; nunca setamos esse header manualmente, senão o boundary se perde).
async function uploadMultipart(path, formData) {
  const { data: { session } } = await supabase.auth.getSession();
  const token = session?.access_token;
  const res = await fetch(`${API_URL}${path}`, {
    method: 'POST',
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    body: formData,
  });
  let payload = null;
  try { payload = await res.json(); } catch { /* sem corpo JSON */ }
  if (!res.ok) throw new ApiError(payload?.error || `Erro ${res.status} ao enviar arquivo para ${path}.`, res.status);
  return payload;
}

export { ApiError, apiDownload };
