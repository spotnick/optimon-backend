// OptiMon Pricing API — rotas de Infraestrutura.
// Fase 2.3 (seções 14-21): criação. Fase 2.3.1 (CRUD completo — seções 8-21): edição
// (PATCH) + arquivamento/restauração (POST .../archive, .../restore) para POP, segmento,
// cabo, poste e porta PON, além de GET single por entidade e ?filtro=ATIVOS|ARQUIVADOS|
// TODOS nas listas (seção 20 — "Lixeira/Infraestrutura Arquivada").
//
// POP/segmento/poste: UPDATE direto via supabase-js para edição — a RLS de cada tabela
// (ENGENHARIA/ADMINISTRADOR escrevem) e o trigger de auditoria genérico já cobrem o log.
// Arquivar/restaurar SEMPRE passa pelos wrappers SQL dedicados (public.pricing_*_archive/
// restore, migration 20260902090100) — nunca um UPDATE direto em removido_em/status a
// partir daqui: é lá que vive a checagem real de dependência (seção 7/10/13/17) e o
// registro semântico de auditoria (ARCHIVE/RESTORE/BLOCKED_ARCHIVE). Cabo é a única
// exceção também na criação: cria fibras junto, numa transação — por isso usa o wrapper
// public.pricing_cable_create_with_fibers.

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');
const { archiveWithAudit, statusForArchiveError } = require('../lib/archiveAudit');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (/PERMISSAO_NEGADA/i.test(message) || /row-level security/i.test(message)) {
    status = 403;
  } else if (/não encontrad/i.test(message)) {
    status = 404;
  } else {
    status = statusForArchiveError(message) === 409 ? 409 : 400;
  }
  return res.status(status).json({ error: message });
}

// filtro=ATIVOS (padrão) | ARQUIVADOS | TODOS — mesmo padrão de GET /api/cities.
function applyRemovidoEmFiltro(query, filtro) {
  if (filtro === 'ATIVOS') return query.is('removido_em', null);
  if (filtro === 'ARQUIVADOS') return query.not('removido_em', 'is', null);
  return query; // TODOS
}

// GET /api/infra/tree?cidade_id=...&incluir_arquivados=true — árvore completa para "Editar
// Infraestrutura". incluir_arquivados=true traz também POP/segmento/cabo/poste arquivados e
// Porta PON INATIVA (seção 20 — visão "Infraestrutura Arquivada" reaproveita a mesma árvore).
router.get('/tree', async (req, res) => {
  const { cidade_id, incluir_arquivados } = req.query;
  if (!cidade_id) return res.status(400).json({ error: 'cidade_id é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  // Só manda p_incluir_arquivados quando true — omitir no caso comum (false/ausente)
  // mantém esta rota compatível com a assinatura de 1 parâmetro que
  // pricing_city_infra_tree tinha desde a Fase 2.3 (mesmo raciocínio do GET /api/cities,
  // ver comentário em routes/cities.js — achado real rodando a cadeia de regressão
  // completa desta fase).
  const rpcParams = { p_cidade_id: cidade_id };
  if (incluir_arquivados === 'true') rpcParams.p_incluir_arquivados = true;
  const { data, error } = await supabase.rpc('pricing_city_infra_tree', rpcParams);
  if (error) return handleError(res, error);
  return res.json(data);
});

// ---------------------------------------------------------------------------------
// POPs (seções 8-10)
// ---------------------------------------------------------------------------------

// GET /api/infra/pops?cidade_id=...&filtro=ATIVOS|ARQUIVADOS|TODOS
router.get('/pops', async (req, res) => {
  const { cidade_id, filtro } = req.query;
  if (!cidade_id) return res.status(400).json({ error: 'cidade_id é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('infra_pops').select('*').eq('cidade_id', cidade_id);
  query = applyRemovidoEmFiltro(query, (filtro || 'ATIVOS').toUpperCase());
  const { data, error } = await query.order('codigo');
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/infra/pops/:id — funciona também para POP arquivado ("Visualizar").
router.get('/pops/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_pops').select('*').eq('id', req.params.id).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'POP não encontrado.' });
  return res.json(data);
});

router.post('/pops', async (req, res) => {
  const { cidade_id, codigo, nome, tipo, endereco, latitude, longitude, capacidade_total, status, observacoes } = req.body || {};
  if (!cidade_id || !codigo || !nome) {
    return res.status(400).json({ error: 'cidade_id, codigo e nome são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('infra_pops')
    .insert({ cidade_id, codigo, nome, tipo: tipo || 'ACESSO', endereco, latitude, longitude, capacidade_total, status: status || 'ATIVO', observacoes })
    .select()
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// PATCH /api/infra/pops/:id — edição (seção 9): Código/Nome/Tipo/Endereço/Latitude/
// Longitude/Capacidade/Status/Observações. Campo ausente/undefined preserva o valor atual.
router.patch('/pops/:id', async (req, res) => {
  const { codigo, nome, tipo, endereco, latitude, longitude, capacidade_total, status, observacoes } = req.body || {};
  const patch = {};
  for (const [k, v] of Object.entries({ codigo, nome, tipo, endereco, latitude, longitude, capacidade_total, status, observacoes })) {
    if (v !== undefined) patch[k] = v;
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_pops').update(patch).eq('id', req.params.id).select().single();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'POP não encontrado.' });
  return res.json(data);
});

// POST /api/infra/pops/:id/archive — nunca DELETE físico (seção 10). Bloqueia se houver
// cabo não arquivado ou Porta PON não INATIVA vinculados. Aceita { motivo, observacao }.
router.post('/pops/:id/archive', async (req, res) => {
  const { motivo, observacao } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const result = await archiveWithAudit(
    supabase,
    'pricing_pop_archive',
    { p_pop_id: req.params.id, p_motivo: motivo ?? null, p_observacao: observacao ?? null },
    'infra_pops',
    req.params.id
  );
  if (result.error) return res.status(result.status).json({ error: result.error });
  return res.json({ ok: true });
});

// POST /api/infra/pops/:id/restore — seção 21. Só ADMINISTRADOR/DIRETOR (RBAC no banco).
router.post('/pops/:id/restore', async (req, res) => {
  const { motivo } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('pricing_pop_restore', { p_pop_id: req.params.id, p_motivo: motivo ?? null });
  if (error) return handleError(res, error);
  return res.json({ ok: true });
});

// ---------------------------------------------------------------------------------
// Segmentos (seção 11)
// ---------------------------------------------------------------------------------

router.get('/segments', async (req, res) => {
  const { cidade_id, filtro } = req.query;
  if (!cidade_id) return res.status(400).json({ error: 'cidade_id é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('infra_segmentos').select('*').eq('cidade_id', cidade_id);
  query = applyRemovidoEmFiltro(query, (filtro || 'ATIVOS').toUpperCase());
  const { data, error } = await query.order('nome');
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/infra/segments/:id — funciona também para segmento arquivado ("Visualizar").
router.get('/segments/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_segmentos').select('*').eq('id', req.params.id).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Segmento não encontrado.' });
  return res.json(data);
});

router.post('/segments', async (req, res) => {
  const { cidade_id, nome, origem, destino, extensao_km } = req.body || {};
  if (!cidade_id || !nome || !origem || !destino || extensao_km == null) {
    return res.status(400).json({ error: 'cidade_id, nome, origem, destino e extensao_km são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('infra_segmentos')
    .insert({ cidade_id, nome, origem, destino, extensao_km })
    .select()
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// PATCH /api/infra/segments/:id — edição (seção 11): Nome/Origem/Destino/Extensão/
// Observações/Status.
router.patch('/segments/:id', async (req, res) => {
  const { nome, origem, destino, extensao_km, status, observacoes } = req.body || {};
  const patch = {};
  for (const [k, v] of Object.entries({ nome, origem, destino, extensao_km, status, observacoes })) {
    if (v !== undefined) patch[k] = v;
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_segmentos').update(patch).eq('id', req.params.id).select().single();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Segmento não encontrado.' });
  return res.json(data);
});

// POST /api/infra/segments/:id/archive — bloqueia se houver cabo ou poste não arquivados
// vinculados a este segmento (seção 11/13).
router.post('/segments/:id/archive', async (req, res) => {
  const { motivo, observacao } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const result = await archiveWithAudit(
    supabase,
    'pricing_segment_archive',
    { p_segmento_id: req.params.id, p_motivo: motivo ?? null, p_observacao: observacao ?? null },
    'infra_segmentos',
    req.params.id
  );
  if (result.error) return res.status(result.status).json({ error: result.error });
  return res.json({ ok: true });
});

router.post('/segments/:id/restore', async (req, res) => {
  const { motivo } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('pricing_segment_restore', { p_segmento_id: req.params.id, p_motivo: motivo ?? null });
  if (error) return handleError(res, error);
  return res.json({ ok: true });
});

// ---------------------------------------------------------------------------------
// Cabos + fibras (seções 12-14, 17) — criação via wrapper (gera as fibras juntas, 1
// transação); edição/arquivamento operam só sobre o cabo (a fibra em si nunca é
// arquivada isoladamente — permanece no histórico do cabo, seção 14).
// ---------------------------------------------------------------------------------

// GET /api/infra/cables?segmento_id=...&filtro=ATIVOS|ARQUIVADOS|TODOS
router.get('/cables', async (req, res) => {
  const { segmento_id, filtro } = req.query;
  if (!segmento_id) return res.status(400).json({ error: 'segmento_id é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('infra_cabos').select('*').eq('segmento_id', segmento_id);
  query = applyRemovidoEmFiltro(query, (filtro || 'ATIVOS').toUpperCase());
  const { data, error } = await query.order('identificacao');
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/infra/cables/:id — funciona também para cabo arquivado ("Visualizar").
router.get('/cables/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_cabos').select('*').eq('id', req.params.id).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Cabo não encontrado.' });
  return res.json(data);
});

router.post('/cables', async (req, res) => {
  const { segmento_id, identificacao, capacidade_fo, pop_id, fabricante } = req.body || {};
  if (!segmento_id || !identificacao || !capacidade_fo) {
    return res.status(400).json({ error: 'segmento_id, identificacao e capacidade_fo são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_cable_create_with_fibers', {
    p_segmento_id: segmento_id,
    p_identificacao: identificacao,
    p_capacidade_fo: capacidade_fo,
    p_pop_id: pop_id ?? null,
    p_fabricante: fabricante ?? null,
  });
  if (error) return handleError(res, error);
  return res.status(201).json({ cabo_id: data });
});

// PATCH /api/infra/cables/:id — edição (seção 12): Identificação/Capacidade FO/
// Fabricante/Segmento/POP/Status/Observações. capacidade_fo aqui é só o campo de
// cadastro — mudar esse número NÃO cria nem remove fibras físicas já geradas (isso
// segue sendo feito só na criação, via pricing_cable_create_with_fibers); o valor serve
// para manter a etiqueta do cabo coerente quando corrigindo um erro de cadastro.
router.patch('/cables/:id', async (req, res) => {
  const { identificacao, capacidade_fo, fabricante, segmento_id, pop_id, status, observacoes } = req.body || {};
  const patch = {};
  for (const [k, v] of Object.entries({ identificacao, capacidade_fo, fabricante, segmento_id, pop_id, status, observacoes })) {
    if (v !== undefined) patch[k] = v;
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_cabos').update(patch).eq('id', req.params.id).select().single();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Cabo não encontrado.' });
  return res.json(data);
});

// POST /api/infra/cables/:id/archive — nunca arquiva com fibra OCUPADA/LOCADA, associada
// a Porta PON, ou vinculada a contrato ativo (seção 13).
router.post('/cables/:id/archive', async (req, res) => {
  const { motivo, observacao } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const result = await archiveWithAudit(
    supabase,
    'pricing_cable_archive',
    { p_cabo_id: req.params.id, p_motivo: motivo ?? null, p_observacao: observacao ?? null },
    'infra_cabos',
    req.params.id
  );
  if (result.error) return res.status(result.status).json({ error: result.error });
  return res.json({ ok: true });
});

router.post('/cables/:id/restore', async (req, res) => {
  const { motivo } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('pricing_cable_restore', { p_cabo_id: req.params.id, p_motivo: motivo ?? null });
  if (error) return handleError(res, error);
  return res.json({ ok: true });
});

router.get('/cables/:id/fibers', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_fibras').select('*').eq('cabo_id', req.params.id).order('numero_fibra');
  if (error) return handleError(res, error);
  return res.json(data);
});

// PATCH /api/infra/fibers/:id — muda status/observação de UMA fibra (seção 14: LIVRE,
// OCUPADA, RESERVADA, LOCADA, MANUTENCAO, BLOQUEADA). Nunca usado para vincular contrato
// (isso passa por contrato_fibras, fora do escopo desta tela) — só estado operacional.
// Não existe archive/delete de fibra isolada: ela só sai de circulação junto do cabo
// inteiro (seção 14 — "nunca permitir excluir uma fibra que faz parte da estrutura
// física de um cabo; deve permanecer no histórico").
router.patch('/fibers/:id', async (req, res) => {
  const { status, observacao } = req.body || {};
  const patch = {};
  if (status !== undefined) patch.status = status;
  if (observacao !== undefined) patch.observacao = observacao;
  if (Object.keys(patch).length === 0) {
    return res.status(400).json({ error: 'Informe status e/ou observacao.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_fibras').update(patch).eq('id', req.params.id).select().single();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Fibra não encontrada.' });
  return res.json(data);
});

// ---------------------------------------------------------------------------------
// Postes (seção 15)
// ---------------------------------------------------------------------------------

router.get('/poles', async (req, res) => {
  const { cidade_id, filtro } = req.query;
  if (!cidade_id) return res.status(400).json({ error: 'cidade_id é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('infra_postes').select('*').eq('cidade_id', cidade_id);
  query = applyRemovidoEmFiltro(query, (filtro || 'ATIVOS').toUpperCase());
  const { data, error } = await query.order('criado_em');
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/infra/poles/:id — funciona também para lote de postes arquivado ("Visualizar").
router.get('/poles/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_postes').select('*').eq('id', req.params.id).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Lote de postes não encontrado.' });
  return res.json(data);
});

router.post('/poles', async (req, res) => {
  const { cidade_id, segmento_id, identificacao, proprietario_terceiro, quantidade, custo_mensal } = req.body || {};
  if (!cidade_id || !quantidade) {
    return res.status(400).json({ error: 'cidade_id e quantidade são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('infra_postes')
    .insert({ cidade_id, segmento_id: segmento_id ?? null, identificacao, proprietario_terceiro, quantidade, custo_mensal: custo_mensal ?? 0 })
    .select()
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// PATCH /api/infra/poles/:id — edição (seção 15): Identificação/Segmento/Proprietário/
// Quantidade/Custo mensal/Status/Observações.
router.patch('/poles/:id', async (req, res) => {
  const { identificacao, segmento_id, proprietario_terceiro, quantidade, custo_mensal, status, observacoes } = req.body || {};
  const patch = {};
  for (const [k, v] of Object.entries({ identificacao, segmento_id, proprietario_terceiro, quantidade, custo_mensal, status, observacoes })) {
    if (v !== undefined) patch[k] = v;
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_postes').update(patch).eq('id', req.params.id).select().single();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Lote de postes não encontrado.' });
  return res.json(data);
});

// POST /api/infra/poles/:id/archive — nunca bloqueia (seção 15: sem dependência
// estrutural real de poste para outra tabela de infraestrutura).
router.post('/poles/:id/archive', async (req, res) => {
  const { motivo, observacao } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const result = await archiveWithAudit(
    supabase,
    'pricing_pole_archive',
    { p_poste_id: req.params.id, p_motivo: motivo ?? null, p_observacao: observacao ?? null },
    'infra_postes',
    req.params.id
  );
  if (result.error) return res.status(result.status).json({ error: result.error });
  return res.json({ ok: true });
});

router.post('/poles/:id/restore', async (req, res) => {
  const { motivo } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('pricing_pole_restore', { p_poste_id: req.params.id, p_motivo: motivo ?? null });
  if (error) return handleError(res, error);
  return res.json({ ok: true });
});

// ---------------------------------------------------------------------------------
// Portas PON (seções 16-17) — trigger fn_valida_porta_pon_pop já garante fibra/POP
// consistentes; trigger fn_porta_pon_default_capacidade já aplica os 128 padrão quando
// não informado. Sem coluna removido_em própria: "arquivar" reaproveita status
// (ATIVA/INATIVA/MANUTENCAO) — arquivar = INATIVA, restaurar = ATIVA (migration 2).
// ---------------------------------------------------------------------------------

// GET /api/infra/pon-ports?pop_id=...&filtro=ATIVOS|ARQUIVADOS|TODOS — ARQUIVADOS aqui
// significa status = INATIVA (não existe removido_em nesta tabela).
router.get('/pon-ports', async (req, res) => {
  const { pop_id, filtro } = req.query;
  if (!pop_id) return res.status(400).json({ error: 'pop_id é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('infra_portas_pon').select('*').eq('pop_id', pop_id);
  const f = (filtro || 'ATIVOS').toUpperCase();
  if (f === 'ATIVOS') query = query.neq('status', 'INATIVA');
  else if (f === 'ARQUIVADOS') query = query.eq('status', 'INATIVA');
  const { data, error } = await query.order('codigo_porta');
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/infra/pon-ports/:id — funciona também para Porta PON arquivada (status
// INATIVA) — "Visualizar".
router.get('/pon-ports/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('infra_portas_pon').select('*').eq('id', req.params.id).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Porta PON não encontrada.' });
  return res.json(data);
});

router.post('/pon-ports', async (req, res) => {
  const { fibra_id, pop_id, codigo_porta, nome, tecnologia, capacidade_max_assinantes, status } = req.body || {};
  if (!fibra_id || !pop_id || !codigo_porta) {
    return res.status(400).json({ error: 'fibra_id, pop_id e codigo_porta são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('infra_portas_pon')
    .insert({ fibra_id, pop_id, codigo_porta, nome, tecnologia: tecnologia || 'GPON', capacidade_max_assinantes: capacidade_max_assinantes ?? null, status: status || 'ATIVA' })
    .select()
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// PATCH /api/infra/pon-ports/:id — edição (seção 16): POP/Identificação/Fibra/
// Tecnologia/Capacidade/Status/Observações (não existe coluna observacoes nesta tabela
// hoje — "nome" cumpre esse papel de rótulo livre, único campo de texto opcional).
// A transição para/de INATIVA nunca passa por aqui — só por /archive (checa cliente ativo,
// seção 17) e /restore (só ADMINISTRADOR/DIRETOR, seção 21). Um PATCH direto de status
// contornaria as duas checagens (achado real ao desenhar esta rota: nada aqui impedia
// status=INATIVA sem checar clientes, nem status=ATIVA vindo de INATIVA sem RBAC de
// restauração) — por isso INATIVA é sempre rejeitado neste endpoint, nos dois sentidos.
router.patch('/pon-ports/:id', async (req, res) => {
  const { fibra_id, pop_id, codigo_porta, nome, tecnologia, capacidade_max_assinantes, status } = req.body || {};
  if (status === 'INATIVA') {
    return res.status(400).json({ error: 'Use o botão Arquivar para inativar uma Porta PON — garante a checagem de clientes ativos e o registro de auditoria correto.' });
  }
  const supabase = clientForRequest(req.userJwt);
  if (status !== undefined) {
    const { data: current, error: fetchError } = await supabase.from('infra_portas_pon').select('status').eq('id', req.params.id).maybeSingle();
    if (fetchError) return handleError(res, fetchError);
    if (!current) return res.status(404).json({ error: 'Porta PON não encontrada.' });
    if (current.status === 'INATIVA') {
      return res.status(400).json({ error: 'Use o botão Restaurar para reativar uma Porta PON arquivada — garante o RBAC e o registro de auditoria corretos.' });
    }
  }
  const patch = {};
  for (const [k, v] of Object.entries({ fibra_id, pop_id, codigo_porta, nome, tecnologia, capacidade_max_assinantes, status })) {
    if (v !== undefined) patch[k] = v;
  }
  const { data, error } = await supabase.from('infra_portas_pon').update(patch).eq('id', req.params.id).select().single();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Porta PON não encontrada.' });
  return res.json(data);
});

// POST /api/infra/pon-ports/:id/archive — bloqueia com a mensagem literal do prompt
// quando há cliente ativo (seção 17). "Arquivar" = status → INATIVA.
router.post('/pon-ports/:id/archive', async (req, res) => {
  const { motivo, observacao } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const result = await archiveWithAudit(
    supabase,
    'pricing_pon_port_archive',
    { p_porta_id: req.params.id, p_motivo: motivo ?? null, p_observacao: observacao ?? null },
    'infra_portas_pon',
    req.params.id
  );
  if (result.error) return res.status(result.status).json({ error: result.error });
  return res.json({ ok: true });
});

// POST /api/infra/pon-ports/:id/restore — status INATIVA → ATIVA. Só ADMINISTRADOR/
// DIRETOR (RBAC no banco).
router.post('/pon-ports/:id/restore', async (req, res) => {
  const { motivo } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('pricing_pon_port_restore', { p_porta_id: req.params.id, p_motivo: motivo ?? null });
  if (error) return handleError(res, error);
  return res.json({ ok: true });
});

module.exports = router;
