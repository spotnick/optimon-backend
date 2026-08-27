// OptiMon Pricing API — Fase 2.5 seção 14/15: /usuarios (Gestão de Usuários).
//
// RBAC (perfil_usuario, 6 valores) já existe desde a Fase 1; esta rota só expõe
// CRUD dos campos cadastrais novos (telefone/cpf/cargo/departamento/perfil/
// status/observacoes/ultimo_acesso) — nada de RLS/policy nova além da já
// existente `usuarios_admin_all` (só ADMINISTRADOR escreve; qualquer
// authenticated lê — confirmado via `\d usuarios` nesta sessão). O Node NUNCA
// reimplementa esse controle de acesso — só repassa o JWT e deixa o Postgres
// decidir (RLS é a fonte de verdade, igual ao resto do projeto).
//
// LIMITAÇÃO ARQUITETURAL EXPLÍCITA (não escondida — ver seção 71 do prompt e
// docs/RELATORIO_FASE25.md): `usuarios.id` é FK de `auth.users(id)` (Supabase
// Auth) — ou seja, não existe "criar usuário" só em `public.usuarios`. A
// identidade de autenticação (e-mail/senha ou magic link) tem que existir
// primeiro em auth.users. Esta API NUNCA usa a service_role key para criar
// usuários de autenticação (regra permanente deste projeto: service_role nunca
// no backend) — o fluxo real é: 1) ADMINISTRADOR convida o novo usuário pelo
// painel do Supabase (Authentication → Users → Invite user), o que cria a
// linha em auth.users e manda o e-mail de definição de senha; 2) o
// ADMINISTRADOR copia o id gerado; 3) chama POST /api/users com esse id para
// criar/completar o perfil em public.usuarios (nome/perfil/cargo/etc). Este
// endpoint pressupõe que o passo 1 já aconteceu — nunca tenta contornar isso.

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (/PERMISSAO_NEGADA/i.test(message) || /row-level security|permission denied/i.test(message)) {
    status = 403;
  } else if (/não encontrad/i.test(message)) {
    status = 404;
  } else if (/duplicate key|already exists|unique constraint/i.test(message)) {
    status = 409;
  } else if (/obrigatóri|inválido|violates check constraint|foreign key/i.test(message)) {
    status = 400;
  } else {
    status = 409;
  }
  return res.status(status).json({ error: message });
}

const SELECT_FIELDS = 'id, nome, email, telefone, cpf, cargo, departamento, perfil, ativo, observacoes, criado_em, atualizado_em, ultimo_acesso_em';

// GET /api/users?perfil=&ativo=&q= — lista (seção 14: nome/e-mail/telefone/cpf/
// cargo/departamento/perfil/status/criado_em/último acesso/observações).
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
  return res.json(data);
});

// GET /api/users/:id
router.get('/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('usuarios').select(SELECT_FIELDS).eq('id', req.params.id).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: `Usuário ${req.params.id} não encontrado.` });
  return res.json(data);
});

// POST /api/users — completa o perfil de um usuário JÁ convidado via Supabase
// Auth (ver limitação no cabeçalho). RLS (usuarios_admin_all) já garante que só
// ADMINISTRADOR pode inserir — o 403 do Postgres chega como está, sem
// duplicar a checagem de perfil aqui.
router.post('/', async (req, res) => {
  const { id, nome, email, telefone, cpf, cargo, departamento, perfil, observacoes } = req.body || {};
  if (!id || !nome || !email || !perfil) {
    return res.status(400).json({ error: 'id, nome, email e perfil são obrigatórios (id é o auth.users.id do usuário já convidado pelo Supabase Auth).' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('usuarios')
    .insert({ id, nome, email, telefone: telefone ?? null, cpf: cpf ?? null, cargo: cargo ?? null, departamento: departamento ?? null, perfil, observacoes: observacoes ?? null })
    .select(SELECT_FIELDS)
    .single();
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
