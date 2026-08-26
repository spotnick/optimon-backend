// OptiMon — cliente da API (Railway). Todo dado de negócio passa por aqui — nunca por
// chamadas diretas ao Supabase (seção 32/33). Cada função pega o JWT da sessão atual e
// manda como Authorization: Bearer <jwt>; o servidor sempre recalcula/revalida tudo.

import { supabase } from './supabaseClient';

const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:3001';

class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
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

  if (!res.ok) {
    throw new ApiError(payload?.error || `Erro ${res.status} ao chamar ${path}.`, res.status);
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
  },

  simulations: {
    save: (body) => request('/api/simulations', { method: 'POST', body }),
    list: (contratoId) => request(`/api/simulations${contratoId ? `?contrato_id=${contratoId}` : ''}`),
  },

  proposals: {
    create: (body) => request('/api/proposals', { method: 'POST', body }),
    list: (params = {}) => request(`/api/proposals?${new URLSearchParams(params)}`),
  },

  audit: {
    list: (params = {}) => request(`/api/audit?${new URLSearchParams(params)}`),
    logLogin: () => request('/api/audit/login', { method: 'POST' }),
  },
};

export { ApiError };
