// OptiMon Pricing API — Fase 2.5 seção 14/15, CORRIGIDA na Fase 2.5.1
// (seções 1-8): /usuarios (Gestão de Usuários).
//
// RBAC (perfil_usuario, 6 valores) já existe desde a Fase 1; esta rota expõe
// CRUD dos campos cadastrais (telefone/cpf/cargo/departamento/perfil/status/
// observacoes/ultimo_acesso) — nada de RLS/policy nova além da já existente
// `usuarios_admin_all` (só ADMINISTRADOR escreve; qualquer authenticated lê).
// O Node NUNCA reimplementa esse controle de acesso para leitura/escrita de
// TABELA — RLS é sempre a fonte de verdade.
//
// BUG REAL CORRIGIDO NESTA FASE (ver docs/RELATORIO_FASE251.md, item 1): até
// a Fase 2.5, "criar usuário" pedia que o ADMINISTRADOR copiasse manualmente
// o `id` gerado pelo Supabase Auth (convite feito à parte, no painel do
// Supabase) — inaceitável como experiência final. Agora `POST /api/users/invite`
// faz o fluxo inteiro: nome/e-mail/telefone/cpf/cargo/departamento/perfil/
// observações → Supabase Auth cria a identidade e manda o e-mail de convite
// → o perfil é completado em public.usuarios — tudo numa chamada, nenhum UUID
// pedido ao administrador.
//
// Isso exige a Auth Admin API (SERVICE_ROLE_KEY) — a ÚNICA exceção do projeto
// à regra "nunca service_role no backend". A decisão completa, o motivo pelo
// qual não há alternativa dentro do Supabase, e as 4 salvaguardas que
// delimitam essa exceção estão documentadas em api/lib/supabaseAdmin.js e
// docs/ARQUITETURA.md seção 24 — leia antes de mexer nesta rota.
//
// Continua verdade, sem exceção: NUNCA senha própria é armazenada em
// public.usuarios — autenticação é sempre 100% Supabase Auth (seção 3).
//
// FASE 2.5.3 (CORREÇÃO DEFINITIVA — USUÁRIOS AUTH x public.usuarios, ver
// docs/RELATORIO_FASE253.md): a causa raiz real do "usuário criado em Auth
// mas nunca aparece em Usuários" foi diagnosticada e corrigida
// (emptyToNull() abaixo), e o fluxo de /invite foi redesenhado com uma
// máquina de estados explícita (A/B/C/D — ver o comentário da rota
// POST /invite) mais rollback controlado (nunca deleta uma identidade Auth
// pré-existente, só uma recém-criada na mesma operação) e um caminho de
// recuperação dedicado (POST /reconcile) para quando um órfão já existe.
// GET /health expõe o mesmo diagnóstico de integridade sem alterar nada.

const express = require('express');
const { clientForRequest, anonClient } = require('../lib/supabaseClient');
const { adminAuth, adminAuthAvailable } = require('../lib/supabaseAdmin');

const router = express.Router();

// Auditoria semântica é sempre best-effort — nunca deve derrubar uma resposta
// cuja ação principal já teve sucesso. BUG encontrado nos testes da Fase
// 2.5.1: supabase-js devolve um builder "thenable" para .rpc() (só implementa
// .then(), não .catch()/.finally() — não é uma Promise real), então
// `supabase.rpc(...).catch(() => {})` lança `TypeError: ...catch is not a
// function` e derruba a rota inteira com 500. O padrão correto é sempre
// `await` dentro de um try/catch — nunca encadear `.catch()` direto no
// retorno de `supabase.rpc(...)`.
async function logSemanticEventBestEffort(supabase, params) {
  try {
    await supabase.rpc('pricing_log_semantic_event', params);
  } catch (_err) {
    // intencional: log de auditoria nunca bloqueia a ação principal.
  }
}

// BUG REAL diagnosticado na Fase 2.5.3 (docs/RELATORIO_FASE253.md, item de
// causa raiz): o formulário "+ Novo Usuário" do frontend inicializa CPF (e os
// demais campos opcionais) como string vazia (''), nunca `undefined`/`null` —
// é assim que um <input> controlado do React se comporta quando o campo é
// deixado em branco. `cpf ?? null` (nullish coalescing) NÃO converte '' para
// null — só converte `null`/`undefined` — então uma string vazia seguia
// direto para o INSERT em public.usuarios. A tabela tem
// `constraint usuarios_cpf_formato check (cpf is null or cpf ~ '^[0-9]{11}$')`
// (migration 20260913090000), e '' não casa com o regex nem é null: o INSERT
// sempre falhava com "violates check constraint usuarios_cpf_formato" —
// reproduzido e confirmado diretamente contra o schema real nesta fase (ver
// docs/RELATORIO_FASE253.md) — DEPOIS que a identidade já tinha sido criada
// em auth.users e o e-mail de convite já tinha sido enviado, deixando um
// usuário órfão (existe em Auth, nunca aparece em Usuários) e tornando
// qualquer nova tentativa de convite um "already been registered" sem saída.
// Corrigido normalizando toda string vazia/só-espaços para null antes do
// INSERT — não só CPF: os demais campos de texto opcionais (telefone/cargo/
// departamento/observacoes) recebem o mesmo tratamento por consistência,
// mesmo não tendo CHECK constraint próprio, para nunca gravar '' onde o
// significado é "não informado".
function emptyToNull(value) {
  if (typeof value !== 'string') return value ?? null;
  const trimmed = value.trim();
  return trimmed === '' ? null : trimmed;
}

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (error?.code === 'SERVICE_ROLE_NAO_CONFIGURADO') {
    status = 501;
  } else if (/PERMISSAO_NEGADA/i.test(message) || /row-level security|permission denied/i.test(message)) {
    status = 403;
  } else if (/não encontrad|NAO_ENCONTRADO/i.test(message)) {
    status = 404;
  } else if (/duplicate key|already exists|unique constraint|already been registered|already registered/i.test(message)) {
    status = 409;
  } else if (/obrigatóri|inválido|violates check constraint|foreign key|MOTIVO_OBRIGATORIO|USUARIO_POSSUI_HISTORICO|ULTIMO_ADMINISTRADOR|NAO_PERMITIDO/i.test(message)) {
    status = 400;
  } else {
    status = 409;
  }
  return res.status(status).json({ error: message });
}

// URL de redirecionamento pós-convite/redefinição de senha.
//
// BUG REAL reportado pelo usuário (Fase 2.5.1, correção pós-entrega): a primeira versão
// desta função derivava a URL sempre da PRIMEIRA origem de CORS_ALLOWED_ORIGINS, para
// evitar uma segunda variável de ambiente redundante. Na prática isso quebrou o convite
// de verdade — CORS_ALLOWED_ORIGINS quase sempre lista `http://localhost:...` primeiro
// (é o próprio padrão documentado em api/.env.example, pensado para desenvolvimento
// local), então todo e-mail de convite/redefinição enviado por um projeto Supabase real
// redirecionava para localhost, nunca para a URL publicada de verdade — o usuário via o
// e-mail funcionar, o Supabase autenticar (token válido na URL), e a página seguinte
// nunca carregar/aparecer certo, porque não existe nenhum frontend rodando em
// localhost:3000 na máquina de quem recebeu o convite.
//
// Corrigido em duas camadas: (1) uma variável de ambiente explícita e única
// (PUBLIC_APP_URL) para esse propósito específico — sem ambiguidade de "qual das N
// origens de CORS é a de verdade"; (2) enquanto essa variável não é configurada, o
// fallback agora prefere a primeira origem de CORS_ALLOWED_ORIGINS que NÃO pareça
// localhost, em vez de sempre pegar a primeira da lista — nunca mais escolhe
// silenciosamente um endereço de desenvolvimento para um e-mail real.
// Fase 3.11.4: extraído para função própria (antes vivia só dentro de
// frontendRedirectUrl) — api/routes/signatures.js reaproveita ESTA MESMA resolução para
// montar o link de assinatura (nunca uma 2ª variável de ambiente para "a mesma URL base
// do frontend" — seção 12 do pedido: "não criar uma segunda solução sem necessidade").
function resolvePublicAppBaseUrl() {
  const explicit = (process.env.PUBLIC_APP_URL || '').trim();
  const origins = (process.env.CORS_ALLOWED_ORIGINS || '').split(',').map((o) => o.trim()).filter(Boolean);
  const nonLocal = origins.find((o) => !/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/i.test(o));
  // BUG REAL encontrado em produção: PUBLIC_APP_URL configurado com barra no final
  // (ex.: "https://optimon-backend-roan.vercel.app/") produzia URLs com barra dupla.
  // Remove qualquer barra final antes de concatenar o caminho — nunca confia que a
  // variável de ambiente foi digitada sem barra no final.
  const base = (explicit || nonLocal || origins[0] || '').replace(/\/+$/, '') || undefined;
  if (!explicit && base) {
    // eslint-disable-next-line no-console
    console.warn(`[optimon-api] PUBLIC_APP_URL não configurado — usando "${base}" (derivado de CORS_ALLOWED_ORIGINS) como URL base do frontend. Configure PUBLIC_APP_URL explicitamente para evitar ambiguidade.`);
  }
  return base;
}

function frontendRedirectUrl() {
  const base = resolvePublicAppBaseUrl();
  return base ? `${base}/definir-senha` : undefined;
}

const SELECT_FIELDS = 'id, nome, email, telefone, cpf, cargo, departamento, perfil, ativo, observacoes, criado_em, atualizado_em, ultimo_acesso_em';

// Camada de autorização desta ÚNICA exceção (ver cabeçalho): como a Auth
// Admin API não passa pelo Postgres, RLS não pode protegê-la — então
// `assertAdmin` abaixo lê o PRÓPRIO perfil de quem chamou (via o client
// escopado ao JWT do chamador, nunca a service_role) e recusa qualquer coisa
// que não seja ADMINISTRADOR ativo, antes de sequer tentar tocar em
// auth.admin.*. `req.userJwt` (setado por middleware/auth.js) só carrega o
// token — precisamos do `sub` (o próprio id) para a leitura acima, daí o
// decode abaixo (o token em si já foi validado pelo Postgres/PostgREST em
// toda chamada real; aqui só extraímos o claim, nunca confiamos nele sem a
// leitura de `usuarios` a seguir).
function decodeJwtSub(jwt) {
  try {
    const payload = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString('utf8'));
    return payload.sub || null;
  } catch (_err) {
    return null;
  }
}

async function assertAdmin(req) {
  const sub = decodeJwtSub(req.userJwt);
  if (!sub) {
    const err = new Error('PERMISSAO_NEGADA: token inválido.');
    throw err;
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('usuarios').select('perfil, ativo').eq('id', sub).maybeSingle();
  if (error) throw error;
  if (!data || data.perfil !== 'ADMINISTRADOR' || !data.ativo) {
    throw new Error('PERMISSAO_NEGADA: só ADMINISTRADOR pode gerenciar convite/acesso de usuário.');
  }
}

// GET /api/users?perfil=&ativo=&q= — lista (seção 14). Quando quem chama é
// ADMINISTRADOR e a Auth Admin API está configurada, enriquece cada linha com
// `status_auth` (ATIVO/CONVITE_PENDENTE/BLOQUEADO) — uma única chamada
// `listUsers()` para toda a lista, nunca N chamadas. Sem isso configurado
// (ambiente local, ou chamador não-ADMINISTRADOR), `status_auth` vem `null` e
// o frontend cai de volta para o status derivado só de `usuarios.ativo`
// (ATIVO/INATIVO) — nunca quebra, nunca esconde a limitação.
router.get('/', async (req, res) => {
  const { perfil, ativo, q, include_orphans } = req.query;
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('usuarios').select(SELECT_FIELDS).is('removido_em', null).order('nome');
  if (perfil) query = query.eq('perfil', perfil);
  if (ativo === 'true') query = query.eq('ativo', true);
  if (ativo === 'false') query = query.eq('ativo', false);
  if (q) query = query.or(`nome.ilike.%${q}%,email.ilike.%${q}%`);

  const { data, error } = await query;
  if (error) return handleError(res, error);

  let statusById = new Map();
  let isAdminCaller = false;
  let authUsers = [];
  if (adminAuthAvailable()) {
    try {
      await assertAdmin(req);
      isAdminCaller = true;
      const { data: authList, error: authError } = await adminAuth().listUsers({ page: 1, perPage: 200 });
      if (!authError && authList?.users) {
        authUsers = authList.users;
        for (const u of authList.users) {
          const banned = u.banned_until && new Date(u.banned_until).getTime() > Date.now();
          const status = banned ? 'BLOQUEADO' : (u.email_confirmed_at ? 'ATIVO' : 'CONVITE_PENDENTE');
          statusById.set(u.id, status);
        }
      }
    } catch (_err) {
      // Chamador não é ADMINISTRADOR, ou a Admin API falhou por algum motivo
      // de ambiente — nunca quebra a listagem básica por causa disso, só não
      // enriquece com status_auth.
    }
  }

  const enriched = (data || []).map((u) => ({
    ...u,
    status_auth: u.ativo === false ? 'INATIVO' : (statusById.get(u.id) || null),
  }));

  // Fase 2.5.3 (seção 6/18): ?include_orphans=true acrescenta linhas
  // sintéticas para identidades Auth órfãs (Estado C — ver seção 5/18), só
  // para quem já recebeu a lista enriquecida (ADMINISTRADOR + Admin API
  // disponível). Nunca inventa um `id` de public.usuarios para essas linhas
  // (não existe) — usa `auth_user_id` e `id: null`, para que o frontend saiba
  // que a única ação possível é "Recuperar Perfil" (POST /api/users/reconcile),
  // nunca Editar/Desativar (que dependem de um id em usuarios).
  let rows = enriched;
  if (include_orphans === 'true' && isAdminCaller) {
    const profileIds = new Set((data || []).map((u) => u.id));
    const orphanRows = authUsers
      .filter((u) => !profileIds.has(u.id))
      .map((u) => ({
        id: null,
        auth_user_id: u.id,
        nome: null,
        email: u.email,
        cargo: null,
        perfil: null,
        ativo: null,
        status_auth: 'ORFAO_SEM_PERFIL',
        criado_em: u.created_at,
        ultimo_acesso_em: null,
      }));
    rows = enriched.concat(orphanRows);
  }

  return res.json(rows);
});

// GET /api/users/health — Fase 2.5.3 (seção 7/18): diagnóstico de integridade
// entre auth.users e public.usuarios, sem alterar nada. Só ADMINISTRADOR
// (mesma exceção da Auth Admin API — RLS não alcança auth.users). Serve tanto
// o painel /usuarios/saude quanto o indicador de integridade em Usuários.
//
// BUG REAL encontrado nos testes desta fase (TESTE-06, tests/run_tests_fase253.sh):
// esta rota precisa vir ANTES de "GET /api/users/:id" abaixo — o Express
// casa rotas na ORDEM DE REGISTRO, então "/health" batia em ":id" primeiro
// (id="health"), e o Postgres rejeitava com "invalid input syntax for type
// uuid: \"health\"" (409, handleError()). O mesmo cuidado já vale para
// qualquer rota GET nova de segmento fixo sob /api/users — sempre antes de
// ":id".
router.get('/health', async (req, res) => {
  try {
    await assertAdmin(req);
  } catch (err) {
    return handleError(res, err);
  }

  const supabase = clientForRequest(req.userJwt);
  const { data: profiles, error: profilesError } = await supabase
    .from('usuarios').select('id, email, nome, criado_em').is('removido_em', null);
  if (profilesError) return handleError(res, profilesError);

  const authAvailable = adminAuthAvailable();
  let authUsers = [];
  let authCheckError = null;
  if (authAvailable) {
    try {
      authUsers = await listAllAuthUsers();
    } catch (err) {
      authCheckError = err.message;
    }
  }

  const profileIds = new Set((profiles || []).map((p) => p.id));
  const authIds = new Set(authUsers.map((u) => u.id));
  const podeVerificar = authAvailable && !authCheckError;

  const identidadesAuthOrfas = podeVerificar
    ? authUsers.filter((u) => !profileIds.has(u.id)).map((u) => ({ auth_user_id: u.id, email: u.email, criado_em: u.created_at }))
    : [];
  const perfisSemAuth = podeVerificar
    ? (profiles || []).filter((p) => !authIds.has(p.id)).map((p) => ({ id: p.id, email: p.email, nome: p.nome, criado_em: p.criado_em }))
    : [];

  return res.json({
    verificado_em: new Date().toISOString(),
    auth_admin_disponivel: authAvailable,
    auth_check_erro: authCheckError,
    total_perfis: (profiles || []).length,
    total_auth: podeVerificar ? authUsers.length : null,
    identidades_auth_orfas: identidadesAuthOrfas, // Estado C — ver seção 5/18
    perfis_sem_auth: perfisSemAuth, // Estado D — ver seção 5/18
    integro: podeVerificar ? (identidadesAuthOrfas.length === 0 && perfisSemAuth.length === 0) : null,
  });
});

// GET /api/users/:id
router.get('/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('usuarios').select(SELECT_FIELDS).eq('id', req.params.id).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: `Usuário ${req.params.id} não encontrado.` });
  return res.json(data);
});

// Insere/completa o perfil em public.usuarios para um id de auth.users já
// existente — lógica compartilhada por /invite (fluxo novo) e pelo POST '/'
// legado abaixo (mantido só como caminho de recuperação manual, ver seção 8).
async function completeProfile(supabase, { id, nome, email, telefone, cpf, cargo, departamento, perfil, observacoes }) {
  return supabase
    .from('usuarios')
    .insert({
      id,
      nome,
      email,
      telefone: emptyToNull(telefone),
      cpf: emptyToNull(cpf),
      cargo: emptyToNull(cargo),
      departamento: emptyToNull(departamento),
      perfil,
      observacoes: emptyToNull(observacoes),
    })
    .select(SELECT_FIELDS)
    .single();
}

// Fase 2.5.3 (seção 3/18, "REGRA 1:1"): a Auth Admin API do Supabase não tem
// um "getUserByEmail" direto (nem em `adminAuth()`, que expõe só o namespace
// `auth.admin` — ver api/lib/supabaseAdmin.js) — só `listUsers` paginado.
// Usado pelo pré-check de idempotência (Estados A/B/C/D) antes de qualquer
// convite/reconciliação, e por GET /api/users/health para o diagnóstico
// completo. Paginação com teto de segurança (25 páginas de 200 = 5000
// usuários) — nunca um loop infinito por página vazia mal comportada.
async function findAuthUserByEmail(email) {
  if (!adminAuthAvailable()) return null;
  const target = email.trim().toLowerCase();
  const perPage = 200;
  for (let page = 1; page <= 25; page += 1) {
    const { data, error } = await adminAuth().listUsers({ page, perPage });
    if (error) throw error;
    const users = data?.users || [];
    const found = users.find((u) => (u.email || '').toLowerCase() === target);
    if (found) return found;
    if (users.length < perPage) return null;
  }
  return null;
}

// Lista todas as identidades de auth.users (mesmo teto/paginação de
// findAuthUserByEmail acima) — usado por GET /api/users/health e por
// GET /api/users?include_orphans=true para achar Estado C (Auth sem perfil).
async function listAllAuthUsers() {
  if (!adminAuthAvailable()) return [];
  const perPage = 200;
  let all = [];
  for (let page = 1; page <= 25; page += 1) {
    const { data, error } = await adminAuth().listUsers({ page, perPage });
    if (error) throw error;
    const users = data?.users || [];
    all = all.concat(users);
    if (users.length < perPage) break;
  }
  return all;
}

// POST /api/users/invite — Fase 2.5.1 criou o fluxo (nome/e-mail/telefone/
// cpf/cargo/departamento/perfil/observações → Supabase Auth cria a identidade
// e envia o e-mail de convite → perfil completado em public.usuarios, tudo
// numa chamada, nunca pedindo UUID). A Fase 2.5.3 REDESENHA o que acontece
// quando algo dá errado no meio do caminho — ver
// docs/RELATORIO_FASE253.md e a seção 9/18 do prompt-mestre desta fase:
//
// BUG REAL que motivou o redesenho: a versão anterior devolvia HTTP 207
// quando o INSERT em public.usuarios falhava depois da identidade Auth já
// criada — o 207 (Multi-Status, ainda um 2xx) era lido como sucesso pelo
// wrapper HTTP genérico do frontend (`res.ok` é true para qualquer 2xx),
// então o administrador via "Convite enviado" numa caixa verde para um
// usuário que nunca apareceu no painel — e uma nova tentativa com o mesmo
// e-mail batia direto em "A user with this email address has already been
// registered", sem nenhum caminho de recuperação. A causa raiz REAL do
// INSERT falhar (diagnosticada nesta fase, não assumida — ver
// docs/RELATORIO_FASE253.md) era o formulário mandando '' em vez de null
// para CPF; já corrigida em completeProfile()/emptyToNull() acima. Mas o
// buraco estrutural continua existindo para QUALQUER outra causa de falha no
// INSERT (rede, RLS mal configurada em outro ambiente, etc.) — por isso o
// redesenho abaixo, e não só o conserto do CPF.
//
// Máquina de estados (seção 5/18, REGRA 1:1 entre auth.users e
// public.usuarios) — verificada ANTES de tentar qualquer coisa:
//   A) nem Auth nem perfil existem            → caminho normal (cria os dois).
//   B) Auth E perfil já existem                → 409, nunca recria.
//   C) só Auth existe (perfil ausente — órfão) → 409 com orientação explícita
//      para usar POST /api/users/reconcile (nunca reconvida — reconvidar um
//      e-mail que já existe em auth.users sempre falha com
//      "already been registered" no próprio Supabase, então nem tenta).
//   D) só o perfil existe (sem Auth correspondente — inconsistência crítica,
//      não deveria ser possível com a REGRA 1:1, mas o diagnóstico verifica
//      mesmo assim) → 409, bloqueia criação automática, pede recuperação
//      administrativa (não há "auth_user_id" correto para recriar sozinho).
router.post('/invite', async (req, res) => {
  const { nome, email, telefone, cpf, cargo, departamento, perfil, observacoes } = req.body || {};
  if (!nome || !email || !perfil) {
    return res.status(400).json({ error: 'nome, email e perfil são obrigatórios.' });
  }
  try {
    await assertAdmin(req);
  } catch (err) {
    return handleError(res, err);
  }

  const supabase = clientForRequest(req.userJwt);
  const emailNorm = email.trim();

  // Pré-checagem do estado (seção 5/18) — nunca tenta criar nada antes de
  // saber em qual dos 4 estados o e-mail já está.
  const { data: existingProfile, error: profileLookupError } = await supabase
    .from('usuarios').select(SELECT_FIELDS).ilike('email', emailNorm).is('removido_em', null).maybeSingle();
  if (profileLookupError) return handleError(res, profileLookupError);

  let existingAuth = null;
  try {
    existingAuth = await findAuthUserByEmail(emailNorm);
  } catch (err) {
    return handleError(res, err);
  }

  if (existingProfile && existingAuth) {
    // Estado B — já 100% cadastrado. Nunca recria.
    return res.status(409).json({
      error: `Já existe um usuário cadastrado com o e-mail ${emailNorm}.`,
      state: 'B_JA_REGISTRADO',
    });
  }
  if (existingProfile && !existingAuth) {
    // Estado D — inconsistência crítica (não deveria acontecer com a REGRA
    // 1:1, mas o diagnóstico verifica em vez de assumir). Nunca cria uma
    // identidade Auth nova com UUID próprio para "consertar" — UUID de
    // usuarios sempre vem do Supabase Auth (seção 3/18).
    await logSemanticEventBestEffort(supabase, {
      p_entidade: 'usuarios', p_entidade_id: existingProfile.id, p_acao: 'USER_AUTH_ORPHAN',
      p_motivo: `Estado D: perfil ${emailNorm} (id=${existingProfile.id}) existe em public.usuarios sem identidade correspondente em auth.users.`,
    });
    return res.status(409).json({
      error: `Inconsistência crítica: existe um cadastro em Usuários para ${emailNorm} sem identidade correspondente no Supabase Auth. Não é possível recriar automaticamente — contate um administrador de infraestrutura (ver GET /api/users/health).`,
      state: 'D_PERFIL_ORFAO',
      profile_id: existingProfile.id,
    });
  }
  if (!existingProfile && existingAuth) {
    // Estado C — exatamente o bug reportado nesta fase: identidade Auth
    // criada (e-mail de convite já enviado de verdade), perfil nunca
    // completado. Reenviar o convite falharia com "already been registered"
    // — em vez disso, orienta o caminho de recuperação que NÃO recria a
    // identidade nem reenvia e-mail.
    return res.status(409).json({
      error: `Já existe uma identidade de autenticação para ${emailNorm} sem cadastro completo em Usuários (falha anterior de cadastro). Use "Recuperar Perfil" (POST /api/users/reconcile) para completar o cadastro sem reenviar o convite.`,
      state: 'C_AUTH_ORFAO',
      auth_user_id: existingAuth.id,
    });
  }

  // Estado A — caminho normal.
  await logSemanticEventBestEffort(supabase, {
    p_entidade: 'usuarios', p_entidade_id: null, p_acao: 'USER_INVITE_STARTED', p_motivo: emailNorm,
  });

  let authUser;
  try {
    const { data, error } = await adminAuth().inviteUserByEmail(emailNorm, {
      data: { nome },
      redirectTo: frontendRedirectUrl(),
    });
    if (error) throw error;
    authUser = data.user;
  } catch (err) {
    // Registra a tentativa falha (ex.: e-mail já cadastrado) — nunca some
    // sem deixar rastro na auditoria (seção 34).
    await logSemanticEventBestEffort(supabase, {
      p_entidade: 'usuarios', p_entidade_id: null, p_acao: 'USER_INVITE_FAILED', p_motivo: `${emailNorm}: ${err.message}`,
    });
    return handleError(res, err);
  }

  await logSemanticEventBestEffort(supabase, {
    p_entidade: 'usuarios', p_entidade_id: authUser.id, p_acao: 'USER_AUTH_CREATED', p_motivo: emailNorm,
  });

  const { data: profile, error: profileError } = await completeProfile(supabase, {
    id: authUser.id, nome, email: emailNorm, telefone, cpf, cargo, departamento, perfil, observacoes,
  });

  if (profileError) {
    // DIAGNÓSTICO SEM MÁSCARA (seção 6/18): captura code/message/details/hint
    // reais do Postgres/PostgREST no log estruturado do Railway, sob a tag
    // USER_INVITE_PROFILE — nunca senha/token/service_role_key/credenciais
    // (nenhum desses três dados aparece nesta linha).
    // eslint-disable-next-line no-console
    console.error(
      `[optimon-api][USER_INVITE_PROFILE] INSERT em public.usuarios falhou — `
      + `auth_user_id=${authUser.id} email=${emailNorm} `
      + `code=${profileError.code || '?'} message=${profileError.message || '?'} `
      + `details=${profileError.details || '-'} hint=${profileError.hint || '-'}`,
    );

    // ROLLBACK CONTROLADO (seção 8/18): a identidade Auth só pode ser apagada
    // aqui porque foi criada NESTA MESMA operação, alguns milissegundos atrás
    // (authUser.id) — nunca uma identidade pré-existente. Isso é o que evita
    // o usuário órfão: se o rollback funcionar, o e-mail volta a ficar
    // totalmente livre para uma nova tentativa (nenhum Estado C criado).
    let rollbackOk = false;
    let rollbackErrorMsg = null;
    try {
      const { error: delErr } = await adminAuth().deleteUser(authUser.id);
      if (delErr) throw delErr;
      rollbackOk = true;
    } catch (err) {
      rollbackErrorMsg = err.message;
    }

    await logSemanticEventBestEffort(supabase, {
      p_entidade: 'usuarios',
      p_entidade_id: authUser.id,
      p_acao: rollbackOk ? 'USER_AUTH_ROLLBACK' : 'USER_AUTH_ORPHAN',
      p_motivo: rollbackOk
        ? `INSERT em usuarios falhou (${profileError.code || '?'}: ${profileError.message}) — identidade Auth revertida automaticamente.`
        : `INSERT em usuarios falhou (${profileError.code || '?'}: ${profileError.message}) — ROLLBACK da identidade Auth também falhou (${rollbackErrorMsg}); identidade ficou órfã (Estado C), use POST /api/users/reconcile.`,
    });

    if (rollbackOk) {
      return res.status(400).json({
        error: `Não foi possível completar o cadastro (${profileError.message}). A identidade de autenticação criada foi revertida automaticamente — nenhum e-mail de convite ficará pendente sem cadastro. Corrija os dados e tente novamente.`,
        rollback: true,
      });
    }
    return res.status(500).json({
      error: `Não foi possível completar o cadastro (${profileError.message}) e a reversão automática da identidade de autenticação também falhou (${rollbackErrorMsg}). A identidade ficou órfã — use GET /api/users/health para confirmar e POST /api/users/reconcile para recuperar sem reenviar o convite.`,
      rollback: false,
      auth_user_id: authUser.id,
    });
  }

  await logSemanticEventBestEffort(supabase, {
    p_entidade: 'usuarios', p_entidade_id: authUser.id, p_acao: 'USER_PROFILE_CREATED', p_valor_novo: profile,
  });
  await logSemanticEventBestEffort(supabase, {
    p_entidade: 'usuarios', p_entidade_id: authUser.id, p_acao: 'USER_INVITE_COMPLETED', p_valor_novo: profile,
  });

  return res.status(201).json({ ...profile, message: `Convite enviado para ${emailNorm}.` });
});

// POST /api/users/reconcile — Fase 2.5.3 (seção 5/18, Estado C): completa o
// cadastro em public.usuarios para uma identidade que já existe em
// auth.users (convite/e-mail já enviados numa tentativa anterior que falhou
// só no INSERT) — NUNCA cria uma identidade Auth nova, NUNCA reenvia e-mail
// de convite, e recusa explicitamente se o e-mail já estiver 100% cadastrado
// (Estado B) — reconciliação só se aplica ao Estado C.
router.post('/reconcile', async (req, res) => {
  const { email, nome, telefone, cpf, cargo, departamento, perfil, observacoes } = req.body || {};
  if (!email || !nome || !perfil) {
    return res.status(400).json({ error: 'email, nome e perfil são obrigatórios para reconciliar um perfil.' });
  }
  try {
    await assertAdmin(req);
  } catch (err) {
    return handleError(res, err);
  }
  if (!adminAuthAvailable()) {
    return res.status(501).json({ error: 'SERVICE_ROLE_NAO_CONFIGURADO: reconciliação depende da Auth Admin API — configure SUPABASE_SERVICE_ROLE_KEY no backend.' });
  }

  const emailNorm = email.trim();
  const supabase = clientForRequest(req.userJwt);

  const { data: existingProfile, error: profileLookupError } = await supabase
    .from('usuarios').select('id').ilike('email', emailNorm).is('removido_em', null).maybeSingle();
  if (profileLookupError) return handleError(res, profileLookupError);
  if (existingProfile) {
    return res.status(409).json({
      error: `Já existe cadastro completo para ${emailNorm} (Estado B) — reconciliação não se aplica a um cadastro já completo.`,
      state: 'B_JA_REGISTRADO',
    });
  }

  let existingAuth;
  try {
    existingAuth = await findAuthUserByEmail(emailNorm);
  } catch (err) {
    return handleError(res, err);
  }
  if (!existingAuth) {
    return res.status(404).json({
      error: `Nenhuma identidade de autenticação encontrada para ${emailNorm} — reconciliação só se aplica ao Estado C (identidade Auth sem perfil). Use POST /api/users/invite para um convite novo.`,
    });
  }

  const { data: profile, error: profileError } = await completeProfile(supabase, {
    id: existingAuth.id, nome, email: emailNorm, telefone, cpf, cargo, departamento, perfil, observacoes,
  });
  if (profileError) {
    // eslint-disable-next-line no-console
    console.error(
      `[optimon-api][USER_INVITE_PROFILE] reconcile: INSERT em public.usuarios falhou — `
      + `auth_user_id=${existingAuth.id} email=${emailNorm} `
      + `code=${profileError.code || '?'} message=${profileError.message || '?'} `
      + `details=${profileError.details || '-'} hint=${profileError.hint || '-'}`,
    );
    return handleError(res, profileError);
  }

  await logSemanticEventBestEffort(supabase, {
    p_entidade: 'usuarios', p_entidade_id: existingAuth.id, p_acao: 'USER_PROFILE_RECONCILED', p_valor_novo: profile,
  });

  return res.status(201).json({ ...profile, message: `Cadastro recuperado para ${emailNorm} — nenhum novo convite foi enviado (a identidade de autenticação já existia).` });
});

// POST /api/users/:id/resend-invite — seção 6.
router.post('/:id/resend-invite', async (req, res) => {
  try {
    await assertAdmin(req);
  } catch (err) {
    return handleError(res, err);
  }
  const supabase = clientForRequest(req.userJwt);
  const { data: user, error } = await supabase.from('usuarios').select('email').eq('id', req.params.id).maybeSingle();
  if (error) return handleError(res, error);
  if (!user) return res.status(404).json({ error: `Usuário ${req.params.id} não encontrado.` });

  try {
    const { error: inviteError } = await adminAuth().inviteUserByEmail(user.email, { redirectTo: frontendRedirectUrl() });
    if (inviteError) throw inviteError;
  } catch (err) {
    return handleError(res, err);
  }

  await logSemanticEventBestEffort(supabase, { p_entidade: 'usuarios', p_entidade_id: req.params.id, p_acao: 'USER_RESEND_INVITE' });
  return res.json({ message: `Convite reenviado para ${user.email}.` });
});

// POST /api/users/:id/reset-access — "Redefinir acesso" (seção 6): dispara o
// e-mail de redefinição de senha padrão do Supabase Auth. Não precisa de
// service_role (resetPasswordForEmail é uma operação pública do próprio
// GoTrue, pensada para ser chamada sem admin) — mas continua exigindo
// ADMINISTRADOR aqui porque é o admin disparando em nome de outra pessoa.
router.post('/:id/reset-access', async (req, res) => {
  try {
    await assertAdmin(req);
  } catch (err) {
    return handleError(res, err);
  }
  const supabase = clientForRequest(req.userJwt);
  const { data: user, error } = await supabase.from('usuarios').select('email').eq('id', req.params.id).maybeSingle();
  if (error) return handleError(res, error);
  if (!user) return res.status(404).json({ error: `Usuário ${req.params.id} não encontrado.` });

  const { error: resetError } = await anonClient().auth.resetPasswordForEmail(user.email, { redirectTo: frontendRedirectUrl() });
  if (resetError) {
    return res.status(502).json({ error: `Falha ao disparar redefinição de senha: ${resetError.message}` });
  }

  await logSemanticEventBestEffort(supabase, { p_entidade: 'usuarios', p_entidade_id: req.params.id, p_acao: 'USER_RESET_ACCESS' });
  return res.json({ message: `E-mail de redefinição de acesso enviado para ${user.email}.` });
});

// POST /api/users/:id/deactivate e /reactivate — seção 6/8. Sempre grava
// usuarios.ativo (o que já bloqueia toda ação privilegiada via
// app.perfil_atual(), que só considera usuário com ativo=true) e, quando a
// Admin API está configurada, também bane/desbane na Auth de verdade
// (bloqueia o login em si, não só as ações de negócio) — graceful degradation
// idêntico ao padrão já usado para Storage: se o ban na Auth falhar, a
// resposta inclui um aviso explícito, nunca escondido, mas nunca bloqueia a
// desativação lógica que já aconteceu com sucesso.
async function setUserActive(req, res, ativo) {
  try {
    await assertAdmin(req);
  } catch (err) {
    return handleError(res, err);
  }
  const { motivo } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('usuarios').update({ ativo }).eq('id', req.params.id).select(SELECT_FIELDS).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: `Usuário ${req.params.id} não encontrado.` });

  let authWarning;
  if (adminAuthAvailable()) {
    try {
      await adminAuth().updateUserById(req.params.id, { ban_duration: ativo ? 'none' : '87600h' });
    } catch (err) {
      authWarning = `Cadastro atualizado, mas não foi possível ${ativo ? 'desbloquear' : 'bloquear'} o login na Auth: ${err.message}`;
    }
  }

  await logSemanticEventBestEffort(supabase, {
    p_entidade: 'usuarios', p_entidade_id: req.params.id, p_acao: ativo ? 'USER_REACTIVATE' : 'USER_DEACTIVATE', p_motivo: motivo || null,
  });

  return res.json({ ...data, auth_warning: authWarning });
}
router.post('/:id/deactivate', (req, res) => setUserActive(req, res, false));
router.post('/:id/reactivate', (req, res) => setUserActive(req, res, true));

// POST /api/users/:id/hard-delete — Fase 3 (item 3.8): EXCLUSÃO FÍSICA CONTROLADA (só
// ADMINISTRADOR — "OWNER" do prompt-mestre mapeia para ADMINISTRADOR, único perfil deste
// RBAC com esse nível de privilégio). Diferente de /deactivate (soft-delete, sempre
// disponível e preserva tudo), isto REMOVE de verdade a linha de public.usuarios — só
// permitido quando o usuário não tem NENHUM vínculo em auditoria/aprovações/criações em
// nenhuma das ~19 tabelas que referenciam usuarios(id) (ver
// app.excluir_usuario_fisicamente, migration 20260926090000, para a lista completa e o
// motivo: a auditoria é imutável, então a exclusão física nunca pode "abrir espaço"
// apagando ou alterando uma linha de auditoria — ela é bloqueada em vez disso). Toda a
// validação (motivo obrigatório, nunca a si mesmo, nunca o último ADMINISTRADOR ativo, a
// varredura de vínculos, o registro em auditoria ANTES do DELETE) vive inteiramente na
// função SQL — esta rota só expõe a RPC já testada via psql, sem reimplementar nenhuma
// regra aqui (mesmo padrão de contracts.js).
//
// Depois que o perfil em public.usuarios é removido com sucesso, a rota tenta também
// remover a IDENTIDADE em auth.users (Supabase Auth) — só possível agora, porque a FK
// `usuarios.id references auth.users(id) on delete restrict` impedia isso enquanto o
// perfil existisse. Essa segunda chamada usa a Auth Admin API (mesma exceção documentada
// no cabeçalho deste arquivo) e nunca é obrigatória para a resposta ser 200: se falhar ou
// a Admin API não estiver configurada, a resposta inclui `auth_warning` — igual ao
// graceful degradation já usado em /deactivate e /reactivate — nunca esconde a limitação,
// nunca bloqueia a exclusão do perfil que já teve sucesso.
router.post('/:id/hard-delete', async (req, res) => {
  try {
    await assertAdmin(req);
  } catch (err) {
    return handleError(res, err);
  }
  const { motivo } = req.body || {};
  if (!motivo || !String(motivo).trim()) {
    return res.status(400).json({ error: 'MOTIVO_OBRIGATORIO: a exclusão física exige um motivo explícito.' });
  }

  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('pricing_usuario_excluir_fisicamente', { p_usuario_id: req.params.id, p_motivo: motivo });
  if (error) return handleError(res, error);

  let authWarning;
  if (adminAuthAvailable()) {
    try {
      const { error: delErr } = await adminAuth().deleteUser(req.params.id);
      if (delErr) throw delErr;
    } catch (err) {
      authWarning = `Cadastro excluído com sucesso, mas não foi possível remover a identidade correspondente na Auth: ${err.message}. Remova manualmente no painel do Supabase, se necessário.`;
    }
  } else {
    authWarning = 'Cadastro excluído com sucesso. A Auth Admin API não está configurada neste ambiente — a identidade em auth.users precisa ser removida manualmente no painel do Supabase.';
  }

  return res.json({ message: 'Usuário excluído fisicamente com sucesso.', auth_warning: authWarning });
});

// POST /api/users — CAMINHO DE RECUPERAÇÃO (não é mais o fluxo principal —
// ver /invite acima). Mantido para completar manualmente o cadastro de um id
// de auth.users que já existe por algum outro caminho (ex.: um convite feito
// direto no painel do Supabase, ou recuperação de uma falha parcial do
// /invite acima). RLS (usuarios_admin_all) garante que só ADMINISTRADOR pode
// inserir.
router.post('/', async (req, res) => {
  const { id, nome, email, telefone, cpf, cargo, departamento, perfil, observacoes } = req.body || {};
  if (!id || !nome || !email || !perfil) {
    return res.status(400).json({ error: 'id, nome, email e perfil são obrigatórios (id é o auth.users.id de uma identidade já existente — use POST /api/users/invite para o fluxo normal, que cria a identidade automaticamente).' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await completeProfile(supabase, { id, nome, email, telefone, cpf, cargo, departamento, perfil, observacoes });
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// PATCH /api/users/:id — atualização cadastral (inclui trocar perfil/ativo).
// Só ADMINISTRADOR (RLS) — nunca confia em nada vindo do frontend além disso.
router.patch('/:id', async (req, res) => {
  const { nome, telefone, cpf, cargo, departamento, perfil, ativo, observacoes } = req.body || {};
  const patch = {};
  if (nome != null) patch.nome = nome;
  if (telefone !== undefined) patch.telefone = telefone;
  if (cpf !== undefined) patch.cpf = cpf;
  if (cargo !== undefined) patch.cargo = cargo;
  if (departamento !== undefined) patch.departamento = departamento;
  if (perfil != null) patch.perfil = perfil;
  if (ativo != null) patch.ativo = ativo;
  if (observacoes !== undefined) patch.observacoes = observacoes;
  if (Object.keys(patch).length === 0) {
    return res.status(400).json({ error: 'Nenhum campo para atualizar.' });
  }

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('usuarios').update(patch).eq('id', req.params.id).select(SELECT_FIELDS).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) {
    // RLS bloqueia a UPDATE silenciosamente (0 linhas afetadas, sem erro) —
    // distingue "não existe" (404) de "existe mas sem permissão" (403)
    // fazendo uma leitura à parte (usuarios_select libera para todo
    // authenticated, então isso nunca vaza mais do que já era visível).
    const { data: exists } = await supabase.from('usuarios').select('id').eq('id', req.params.id).maybeSingle();
    if (exists) return res.status(403).json({ error: 'PERMISSAO_NEGADA: só ADMINISTRADOR pode alterar o cadastro de outro usuário.' });
    return res.status(404).json({ error: `Usuário ${req.params.id} não encontrado.` });
  }
  return res.json(data);
});

// POST /api/users/me/touch-access — chamado pelo frontend logo após o login
// (seção 14: "último acesso"). SECURITY DEFINER estreito no banco — só toca o
// próprio usuário (auth.uid()), nunca aceita um id de outro.
router.post('/me/touch-access', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('usuarios_touch_last_access');
  if (error) return handleError(res, error);
  return res.status(204).send();
});

module.exports = router;
// Exposta só para o teste de regressão do bug real desta correção (ver
// tests/run_tests_fase251.sh, "TESTE-redirect") — um Router do Express é uma função
// comum, então anexar uma propriedade nela não afeta `app.use('/api/users', ...)` em
// nada; nenhuma outra rota importa isto.
module.exports.frontendRedirectUrl = frontendRedirectUrl;
// Fase 3.11.4: reaproveitada por api/routes/signatures.js para montar o link de
// assinatura — mesma resolução de URL base, nunca uma 2ª variável de ambiente.
module.exports.resolvePublicAppBaseUrl = resolvePublicAppBaseUrl;
// Exposta pelo mesmo motivo, agora para tests/run_tests_fase253.sh testar
// diretamente o conserto da causa raiz (string vazia → null) sem precisar de
// HTTP/Postgres reais.
module.exports.emptyToNull = emptyToNull;
