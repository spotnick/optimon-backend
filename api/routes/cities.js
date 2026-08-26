// OptiMon Pricing API — rotas de Cidades (seção 31 da Fase Deploy + seção 11 da Fase 2.3
// + CRUD completo da Fase 2.3.1: editar, arquivar E restaurar, filtro ativos/arquivados).
// Handlers finos: validam entrada mínima (campo presente), chamam UM wrapper SQL, devolvem
// o resultado. Toda regra de negócio (obrigatoriedade real, RBAC, bloqueio de arquivamento)
// vive no banco (app.criar_cidade/atualizar_cidade/arquivar_cidade/restaurar_cidade) — a
// API nunca decide, só encaminha, e nunca confia em nada vindo do frontend além de
// repassar ao Postgres.

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');
const { archiveWithAudit, statusForArchiveError } = require('../lib/archiveAudit');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  return res.status(statusForArchiveError(message)).json({ error: message });
}

// GET /api/cities — lista de cidades com infraestrutura/capacidade consolidadas.
// ?filtro=ATIVOS (padrão) | ARQUIVADOS | TODOS (seção 20 — filtro de "Infraestrutura
// Arquivada"). ARQUIVADOS filtra client-side sobre o resultado de incluir_arquivados=true
// — mais simples que uma 3ª variante de SQL, e a lista de cidades nunca é grande o
// suficiente para isso pesar.
router.get('/', async (req, res) => {
  const filtro = (req.query.filtro || 'ATIVOS').toUpperCase();
  const supabase = clientForRequest(req.userJwt);
  // Só manda p_incluir_arquivados quando realmente precisa (ARQUIVADOS/TODOS) — chamar
  // com {} no caso ATIVOS (o mais comum, de longe) deixa esta rota compatível com QUALQUER
  // versão de pricing_cities_list, inclusive a de zero parâmetros que existiu desde a Fase
  // Deploy até a Fase 2.3 (achado real rodando a cadeia de regressão completa desta fase:
  // sem isso, o "Dashboard" da Fase Deploy — que roda com só as migrations até ali, nunca
  // as desta fase — quebrava com "function ... not found in schema cache" mesmo sem
  // nenhuma dependência real do filtro ATIVOS em incluir_arquivados).
  const params = filtro === 'ATIVOS' ? {} : { p_incluir_arquivados: true };
  const { data, error } = await supabase.rpc('pricing_cities_list', params);
  if (error) return handleError(res, error);
  const rows = filtro === 'ARQUIVADOS' ? data.filter((c) => c.arquivada) : data;
  return res.json(rows);
});

// GET /api/cities/:id — detalhe de uma cidade (infra + capacidade + POPs). Funciona
// também para cidade arquivada (seção 2 — "Visualizar" sempre disponível), devolve
// "arquivada": true/false no corpo.
router.get('/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_city_detail', { p_cidade_id: req.params.id });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/cities — cadastro de cidade (seção 8/11). Nunca cria POP/infra junto — isso é
// um passo separado do fluxo (seção 22: Cidade -> +POP -> +segmento -> +cabo -> ...).
router.post('/', async (req, res) => {
  const { nome, uf, km_rede, codigo_ibge, endereco, observacoes, status } = req.body || {};
  if (!nome || !uf || km_rede == null) {
    return res.status(400).json({ error: 'nome, uf e km_rede são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_city_create', {
    p_nome: nome,
    p_uf: uf,
    p_km_rede: km_rede,
    p_codigo_ibge: codigo_ibge ?? null,
    p_endereco: endereco ?? null,
    p_observacoes: observacoes ?? null,
    p_status: status || 'ATIVA',
  });
  if (error) return handleError(res, error);
  return res.status(201).json({ cidade_id: data });
});

// PATCH /api/cities/:id — edição parcial (seção 5/11). Campo ausente/undefined preserva o
// valor atual — só nome/uf/km_rede recusam string vazia/valor inválido (validado no banco).
router.patch('/:id', async (req, res) => {
  const { nome, uf, km_rede, codigo_ibge, endereco, observacoes, status } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('pricing_city_update', {
    p_cidade_id: req.params.id,
    p_nome: nome ?? null,
    p_uf: uf ?? null,
    p_codigo_ibge: codigo_ibge ?? null,
    p_endereco: endereco ?? null,
    p_km_rede: km_rede ?? null,
    p_observacoes: observacoes ?? null,
    p_status: status ?? null,
  });
  if (error) return handleError(res, error);
  return res.json({ ok: true });
});

// POST /api/cities/:id/archive — nunca DELETE físico (seção 6/10). Bloqueia com contrato
// ATIVO — mensagem exata "Não é possível arquivar uma cidade com contrato ativo." (seção
// 7/32). Aceita { motivo, observacao } no corpo (seção 29).
router.post('/:id/archive', async (req, res) => {
  const { motivo, observacao } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  // p_motivo/p_observacao só entram no corpo da RPC quando informados — omitir quando
  // ausentes mantém esta rota compatível com a assinatura de 1 parâmetro que
  // pricing_city_archive tinha desde a Fase 2.3 (achado real rodando a cadeia de
  // regressão completa: POST /:id/archive já existia então, sempre chamado sem corpo
  // pelos testes daquela fase, e essa chamada quebrava contra qualquer estágio de banco
  // anterior a esta fase quando os parâmetros novos eram sempre enviados, mesmo como null).
  const rpcParams = { p_cidade_id: req.params.id };
  if (motivo !== undefined) rpcParams.p_motivo = motivo;
  if (observacao !== undefined) rpcParams.p_observacao = observacao;
  const result = await archiveWithAudit(
    supabase,
    'pricing_city_archive',
    rpcParams,
    'cidades_infra',
    req.params.id
  );
  if (result.error) return res.status(result.status).json({ error: result.error });
  return res.json({ ok: true });
});

// POST /api/cities/:id/restore — seção 6/21. Só ADMINISTRADOR/DIRETOR (RBAC no banco).
router.post('/:id/restore', async (req, res) => {
  const { motivo } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('pricing_city_restore', { p_cidade_id: req.params.id, p_motivo: motivo ?? null });
  if (error) return handleError(res, error);
  return res.json({ ok: true });
});

module.exports = router;
