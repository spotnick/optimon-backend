// OptiMon Pricing API — Fase 2.5.1: a ÚNICA exceção documentada à regra
// "nunca service_role nesta API" (ver api/lib/supabaseClient.js, seção
// 33/53 do prompt original, e a decisão completa em docs/ARQUITETURA.md
// seção 24 / docs/RELATORIO_FASE251.md).
//
// POR QUE ESTA EXCEÇÃO EXISTE (seção 4 do prompt-mestre desta fase pede
// exatamente essa avaliação antes de implementar):
//
// Convidar um usuário — criar a identidade dele em `auth.users` e disparar o
// e-mail de definição de senha do Supabase Auth — é uma operação da AUTH
// ADMIN API do Supabase (GoTrue), não uma escrita numa tabela do schema
// public/app. RLS não existe (nem poderia existir) sobre essa operação: RLS é
// um mecanismo do Postgres que se aplica a linhas de tabela, e `auth.users`
// nem é gerenciável por uma migration deste projeto. Não existe, dentro do
// produto Supabase, nenhuma forma de uma ANON_KEY ou de um JWT de usuário
// comum criar/convidar OUTRO usuário — é sempre e só a Admin API, que exige a
// SERVICE_ROLE_KEY. Não há alternativa dentro da plataforma.
//
// A "gambiarra" que o prompt-mestre explicitamente pede para NUNCA fazer
// seria inserir diretamente em `auth.users` via SQL (bypassando o Supabase
// Auth) — isso quebraria o fluxo real de e-mail de convite/confirmação/senha,
// deixaria o usuário sem conseguir logar de verdade, e é exatamente o tipo de
// atalho que este projeto rejeitou desde a decisão original de nunca usar
// service_role. Em vez disso, a decisão tomada aqui é usar a Admin API real
// do Supabase — mas de forma cirurgicamente restrita:
//
// --------------------------------------------------------------------------
// 1. Este módulo é o ÚNICO lugar de toda a API que importa a
//    SERVICE_ROLE_KEY.
// 2. Ele expõe SOMENTE `client.auth.admin` (inviteUserByEmail/
//    updateUserById/listUsers/getUserById) — NUNCA um client genérico com
//    `.from('qualquer_tabela')`. Nenhuma leitura/escrita de dado de negócio
//    passa por aqui — todas continuam indo por `clientForRequest` (JWT do
//    próprio usuário, RLS real, seção 33/53 preservada 100%).
// 3. Toda rota que chama este módulo (api/routes/users.js) SEMPRE verifica
//    antes, usando o client ESCOPADO AO JWT DE QUEM CHAMOU (nunca este
//    client), que quem está chamando é ADMINISTRADOR — porque essa é a
//    única camada de autorização possível aqui (RLS não alcança a Auth
//    Admin API). Essa checagem é o "RBAC" desta única exceção, documentada
//    em cada rota que a usa.
// 4. SUPABASE_SERVICE_ROLE_KEY só pode existir como variável de ambiente do
//    BACKEND (Railway) — nunca no Vercel, nunca no bundle do frontend,
//    nunca commitada (ver api/.env.example). Se não estiver configurada, as
//    rotas que dependem dela falham de forma controlada (501), nunca
//    silenciosamente e nunca com um fallback inseguro.
// --------------------------------------------------------------------------
const { createClient } = require('@supabase/supabase-js');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

let _client = null;

function adminAuthAvailable() {
  return !!(SUPABASE_URL && SERVICE_ROLE_KEY);
}

/**
 * @returns {import('@supabase/supabase-js').GoTrueAdminApi} SOMENTE o
 * namespace `auth.admin` — nunca o client inteiro, para que seja
 * estruturalmente impossível uma rota futura usar isto para `.from(...)`
 * numa tabela por engano.
 */
function adminAuth() {
  if (!adminAuthAvailable()) {
    const err = new Error('SERVICE_ROLE_NAO_CONFIGURADO: defina SUPABASE_SERVICE_ROLE_KEY no ambiente do backend (Railway) para habilitar convite/desativação/redefinição de acesso de usuário. NUNCA configure essa variável no Vercel ou em qualquer bundle de frontend.');
    err.code = 'SERVICE_ROLE_NAO_CONFIGURADO';
    throw err;
  }
  if (!_client) {
    _client = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  }
  return _client.auth.admin;
}

module.exports = { adminAuth, adminAuthAvailable };
