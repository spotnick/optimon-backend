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

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (error?.code === 'SERVICE_ROLE_NAO_CONFIGURADO') {
    status = 501;
  } else if (/PERMISSAO_NEGADA/i.test(message) || /row-level security|permission denied/i.test(message)) {
    status = 403;
  } else if (/não encontrad/i.test(message)) {
    status = 404;
  } else if (/duplicate key|already exists|unique constraint|already been registered|already registered/i.test(message)) {
    status = 409;
  } else if (/obrigatóri|inválido|violates check constraint|foreign key/i.test(message)) {
    status = 400;
  } else {
    status = 409;
  }
  return res.status(status).json({ error: message });
}

// URL de redirecionamento pós-convite/redefinição de senha — deriva da
// primeira origem de CORS_ALLOWED_ORIGINS (a URL real do frontend publicado),
// nunca uma segunda variável de ambiente redundante.
function frontendRedirectUrl() {
  const first = (process.env.CORS_ALLOWED_ORIGINS || '').split(',')[0]?.trim();
  return first ? `${first}/login` : undefined;
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
  const { perfil, ativo, q } = req.query;
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('usuarios').select(SELECT_FIELDS).is('removido_em', null).order('nome');
  if (perfil) query = query.eq('perfil', perfil);
  if (ativo === 'true') query = query.eq('ativo', true);
  if (ativo === 'false') query = query.eq('ativo', false);
  if (q) query = query.or(`nome.ilike.%${q}%,email.ilike.%${q}%`);

  const { data, error } = await query;
  if (error) return handleError(res, error);

  let statusById = new Map();
  if (adminAuthAvailable()) {
    try {
      await assertAdmin(req);
      const { data: authList, error: authError } = await adminAuth().listUsers({ page: 1, perPage: 200 });
      if (!authError && authList?.users) {
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
  return res.json(enriched);
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
    .insert({ id, nome, email, telefone: telefone ?? null, cpf: cpf ?? null, cargo: cargo ?? null, departamento: departamento ?? null, perfil, observacoes: observacoes ?? null })
    .select(SELECT_FIELDS)
    .single();
}

// POST /api/users/invite — Fase 2.5.1, o fluxo novo (seções 1-5): nome/e-mail/
// telefone/cpf/cargo/departamento/perfil/observações → Supabase Auth cria a
// identidade e envia o e-mail de convite → perfil completado em
// public.usuarios. Nunca pede UUID. Só ADMINISTRADOR (checado aqui, porque
// RLS não alcança a Auth Admin API — ver cabeçalho do arquivo).
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

  let authUser;
  try {
    const { data, error } = await adminAuth().inviteUserByEmail(email, {
      data: { nome },
      redirectTo: frontendRedirectUrl(),
    });
    if (error) throw error;
    authUser = data.user;
  } catch (err) {
    // Registra a tentativa falha (ex.: e-mail já cadastrado) — nunca some
    // sem deixar rastro na auditoria (seção 34).
    try {
      const supabase = clientForRequest(req.userJwt);
      await supabase.rpc('pricing_log_semantic_event', {
        p_entidade: 'usuarios', p_entidade_id: null, p_acao: 'USER_INVITE_FAILED', p_motivo: `${email}: ${err.message}`,
      });
    } catch (_logErr) { /* nunca deixa a auditoria derrubar a resposta de erro real */ }
    return handleError(res, err);
  }

  const supabase = clientForRequest(req.userJwt);
  const { data: profile, error: profileError } = await completeProfile(supabase, {
    id: authUser.id, nome, email, telefone, cpf, cargo, departamento, perfil, observacoes,
  });
  if (profileError) {
    // A identidade em auth.users já foi criada e o e-mail já saiu — não dá
    // para desfazer isso (e não deveríamos: o convite é legítimo). Devolve um
    // erro claro com o id gerado, para que POST /api/users (o caminho de
    // recuperação abaixo) complete manualmente se este passo falhar por
    // algum motivo transitório.
    return res.status(207).json({
      error: `Identidade criada no Supabase Auth (id=${authUser.id}) e convite enviado, mas o cadastro em public.usuarios falhou: ${profileError.message}. Repita usando POST /api/users com este id.`,
      auth_user_id: authUser.id,
    });
  }

  await logSemanticEventBestEffort(supabase, {
    p_entidade: 'usuarios', p_entidade_id: authUser.id, p_acao: 'USER_INVITE', p_motivo: null, p_valor_novo: profile,
  });

  return res.status(201).json({ ...profile, message: `Convite enviado para ${email}.` });
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
