// OptiMon Pricing API — Fase 3.8 (item 3.8-11): registro formal de equipamentos cedidos
// (OLT/ONU/ONT/fontes/switches) e workflow de devolução na rescisão contratual.
//
// public.ativos e public.ativos_devolucao já existiam desde a Fase 1 (seção 26), com RLS
// restrita a ENGENHARIA/ADMINISTRADOR — mas nunca tinham nenhuma rota de API (só eram
// lidas por GET /api/contracts/:id e pela minuta). Esta é a primeira vez que existe forma
// de cadastrar um ativo, vinculá-lo a um contrato, ou processar uma devolução — a
// autorização real (quem pode escrever) continua 100% na RLS do banco, esta rota só
// encaminha (mesma disciplina de api/routes/contracts.js).

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (/PERMISSAO_NEGADA|REQUIRES_APPROVAL/i.test(message) || /row-level security|permission denied/i.test(message)) {
    status = 403;
  } else if (/não encontrad|NAO_ENCONTRADO/i.test(message)) {
    status = 404;
  } else if (/VALIDATION/i.test(message)) {
    status = 400;
  } else if (/duplicate key|already exists|unique constraint/i.test(message)) {
    status = 409;
  } else if (/obrigatóri|inválido|violates check constraint|foreign key/i.test(message)) {
    status = 400;
  } else {
    status = 409;
  }
  return res.status(status).json({ error: message });
}

const TIPOS_ATIVO = ['OLT', 'ONU', 'ONT', 'FONTE', 'SWITCH', 'ROTEADOR', 'OUTRO'];

// GET /api/assets?contrato_id=&status=&parceiro_id= — lista com filtros. RLS: leitura
// aberta a todo usuário autenticado (mesma regra de sempre já foi assim desde a Fase 1).
router.get('/', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('ativos').select('*').is('removido_em', null).order('criado_em', { ascending: false });
  if (req.query.contrato_id) query = query.eq('contrato_id', req.query.contrato_id);
  if (req.query.status) query = query.eq('status', req.query.status);
  if (req.query.parceiro_id) query = query.eq('parceiro_id', req.query.parceiro_id);
  const { data, error } = await query;
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/assets/:id — detalhe, incluindo histórico de devolução (se houver).
router.get('/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const [{ data: ativo, error }, { data: devolucoes }] = await Promise.all([
    supabase.from('ativos').select('*').eq('id', req.params.id).maybeSingle(),
    supabase.from('ativos_devolucao').select('*').eq('ativo_id', req.params.id).order('criado_em', { ascending: false }),
  ]);
  if (error) return handleError(res, error);
  if (!ativo) return res.status(404).json({ error: `Ativo ${req.params.id} não encontrado.` });
  return res.json({ ...ativo, devolucoes: devolucoes || [] });
});

// POST /api/assets — cadastra um equipamento. RLS restringe a ENGENHARIA/ADMINISTRADOR.
router.post('/', async (req, res) => {
  const { tipo, fabricante, modelo, numero_serie, patrimonio, valor, localizacao, cidade_id, parceiro_id, contrato_id, status } = req.body || {};
  if (!TIPOS_ATIVO.includes(tipo)) return res.status(400).json({ error: `tipo deve ser um de: ${TIPOS_ATIVO.join(', ')}.` });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('ativos')
    .insert({
      tipo, fabricante: fabricante || null, modelo: modelo || null, numero_serie: numero_serie || null,
      patrimonio: patrimonio || null, valor: valor ?? null, localizacao: localizacao || null,
      cidade_id: cidade_id || null, parceiro_id: parceiro_id || null, contrato_id: contrato_id || null,
      status: status || 'ESTOQUE',
    })
    .select('*')
    .maybeSingle();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// PATCH /api/assets/:id — edita cadastro e/ou vincula a um contrato (ex.: sair de
// ESTOQUE e ser cedido em EM_USO num contrato específico).
router.patch('/:id', async (req, res) => {
  const campos = ['tipo', 'fabricante', 'modelo', 'numero_serie', 'patrimonio', 'valor', 'localizacao', 'cidade_id', 'parceiro_id', 'contrato_id', 'status'];
  const patch = {};
  for (const c of campos) if (c in (req.body || {})) patch[c] = req.body[c];
  if (patch.tipo && !TIPOS_ATIVO.includes(patch.tipo)) return res.status(400).json({ error: `tipo deve ser um de: ${TIPOS_ATIVO.join(', ')}.` });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('ativos').update(patch).eq('id', req.params.id).select('*').maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Ativo não encontrado.' });
  return res.json(data);
});

// DELETE /api/assets/:id — arquivamento lógico (removido_em), nunca DELETE físico —
// mesma disciplina de arquivamento já usada no resto do sistema (cidades/infra/etc.).
router.delete('/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('ativos').update({ removido_em: new Date().toISOString() }).eq('id', req.params.id).select('*').maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Ativo não encontrado.' });
  return res.json(data);
});

// POST /api/assets/:id/devolucao — abre uma ordem de devolução (rescisão contratual,
// seção 26) — data_solicitacao automática, data_devolucao ainda em aberto.
router.post('/:id/devolucao', async (req, res) => {
  const { contrato_id } = req.body || {};
  if (!contrato_id) return res.status(400).json({ error: 'contrato_id é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('ativos_devolucao')
    .insert({ ativo_id: req.params.id, contrato_id })
    .select('*')
    .maybeSingle();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// PATCH /api/assets/:id/devolucao/:devolucaoId — confirma a devolução (condição, data,
// eventuais perdas/danos, e o desfecho: DEVOLVIDO ou PERDIDO). O trigger
// fn_ativo_devolucao_aplica_status aplica esse status automaticamente em public.ativos —
// esta rota nunca escreve na tabela ativos diretamente, para as duas nunca divergirem.
router.patch('/:id/devolucao/:devolucaoId', async (req, res) => {
  const { condicao, valor_perdas_danos, status_final } = req.body || {};
  if (!['DEVOLVIDO', 'PERDIDO'].includes(status_final)) {
    return res.status(400).json({ error: 'status_final deve ser DEVOLVIDO ou PERDIDO.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('ativos_devolucao')
    .update({ condicao: condicao || null, valor_perdas_danos: valor_perdas_danos ?? null, status_final, data_devolucao: new Date().toISOString() })
    .eq('id', req.params.devolucaoId)
    .eq('ativo_id', req.params.id)
    .select('*')
    .maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Ordem de devolução não encontrada.' });
  return res.json(data);
});

module.exports = router;
