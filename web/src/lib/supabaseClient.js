// OptiMon — cliente Supabase do FRONTEND.
//
// Seção 33/53: usado SÓ para autenticação (signInWithPassword, signOut, getSession,
// onAuthStateChange) — nunca para ler/escrever dados de negócio. Todo dado (cidades,
// preços, simulações, propostas, auditoria) passa pela API do Railway
// (ver src/lib/api.js), que recebe o JWT desta sessão e o repassa ao Supabase no
// servidor. A ANON_KEY é segura para expor no bundle publicado — é assim que o Supabase
// foi desenhado para funcionar; ela sozinha não abre nenhum dado (RLS decide tudo).

import { createClient } from '@supabase/supabase-js';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  // eslint-disable-next-line no-console
  console.warn('[optimon-web] VITE_SUPABASE_URL/VITE_SUPABASE_ANON_KEY não configurados — ver web/.env.example.');
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: { persistSession: true, autoRefreshToken: true },
});

// Hook só de DEV (eliminado do bundle de produção pelo Vite — import.meta.env.DEV é
// substituído estaticamente em build): permite injetar uma sessão de teste (JWT minted
// por supabase/dev-local-only/mint_jwt.js) sem precisar de um GoTrue real rodando local.
// Nunca existe fora de `npm run dev`.
if (import.meta.env.DEV) {
  window.__optimonSupabase = supabase;
}
