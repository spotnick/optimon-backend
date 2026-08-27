// OptiMon Pricing API — cliente Supabase por requisição.
//
// Seção 53: "service_role nunca no frontend" — e, nesta implementação, nunca no backend
// desta API também. Cada requisição autenticada cria um cliente Supabase usando a
// ANON_KEY + o JWT do próprio usuário (repassado no header Authorization), de forma que
// toda chamada RPC roda com o RBAC/RLS reais do usuário — exatamente como aconteceria se
// o frontend chamasse o Supabase diretamente. A API não é um caminho para bypassar
// segurança, é só uma camada fina de conveniência/validação.

const { createClient } = require('@supabase/supabase-js');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;

if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  // Falha explícita e cedo — nunca seguir em frente sem as duas variáveis, e nunca cair
  // silenciosamente para algum outro valor "de conveniência".
  console.warn('[optimon-api] SUPABASE_URL/SUPABASE_ANON_KEY não configurados — ver api/.env.example.');
}

/**
 * Cria um client Supabase escopado ao JWT do usuário autenticado desta requisição.
 * @param {string} userJwt — token do header `Authorization: Bearer <jwt>`.
 */
function clientForRequest(userJwt) {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${userJwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/**
 * Cliente Supabase anônimo (sem JWT de usuário) — só para a ÚNICA rota desta
 * API que não exige `requireAuth`: o webhook de assinatura (Fase 2.5, seção
 * 27/49), chamado pelo provedor externo, nunca por um usuário logado. Chama
 * só RPCs com grant explícito para `anon` (ex.:
 * pricing_signature_webhook_event_by_provider_id) — nunca a service_role, e
 * nunca usado fora dessa rota.
 */
function anonClient() {
  return createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

module.exports = { clientForRequest, anonClient };
