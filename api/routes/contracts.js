// OptiMon Pricing API — Fase 2.5: /contratos + /contratos/:id/aditivos +
// dashboard contratual + alertas (seções 32-42).
//
// Geração automática (GERAR CONTRATO, seção 32-33) e ativação com checagem de
// conflito de infraestrutura (seção 36) já são SQL puro
// (app.gerar_contrato_de_proposta / app.ativar_contrato, migrations 05/06) —
// esta rota só expõe essas funções já testadas via psql, sem reimplementar
// nenhuma regra aqui.

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');
const { generateContratoPdf } = require('../lib/pdfContrato');
const { generateContratoDocx } = require('../lib/docxContrato');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (/PERMISSAO_NEGADA|REQUIRES_APPROVAL/i.test(message) || /row-level security|permission denied/i.test(message)) {
    status = 403;
  } else if (/não encontrad|NAO_ENCONTRADO/i.test(message)) {
    status = 404;
  } else if (/MOTIVO_OBRIGATORIO|STATUS_INVALIDO|PRAZO_MINIMO|ASSINATURA_PENDENTE|CONFLITO|INFRA_NAO_ALOCADA/i.test(message)) {
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

// GET /api/contracts?filtro=TODOS|ATIVOS|EM_ASSINATURA|EXPIRANDO|EXPIRADOS|CANCELADOS|SUSPENSOS
router.get('/', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_contracts_list', { p_filtro: req.query.filtro || null });
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/contracts/:id — detalhe (contrato + config de pricing + fibras
// alocadas + aditivos + reajustes + envelope de assinatura do contrato).
router.get('/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const [
    { data: contrato, error: cError }, { data: pricingConfig }, { data: fibras }, { data: aditivos },
    { data: reajustes }, { data: envelopes }, { data: regras }, { data: clientesReservados }, { data: ativos },
  ] = await Promise.all([
    supabase.from('contratos').select('*, parceiros(id, razao_social, nome_fantasia, cnpj), cidades_infra(id, nome, uf)').eq('id', req.params.id).maybeSingle(),
    supabase.from('contrato_pricing_config').select('*').eq('contrato_id', req.params.id).maybeSingle(),
    supabase.from('contrato_fibras').select('id, fibra_id, porta_pon_id, vinculado_em, desvinculado_em').eq('contrato_id', req.params.id).is('desvinculado_em', null),
    supabase.from('contrato_aditivos').select('id, numero, tipo, descricao, status, data, criado_em').eq('contrato_id', req.params.id).order('numero'),
    supabase.from('reajustes').select('id, competencia_base, percentual_aplicado, status, aplicado_em').eq('contrato_id', req.params.id).order('competencia_base', { ascending: false }),
    supabase.from('signature_envelopes').select('id, status, provider_id, enviado_em, concluido_em').eq('contrato_id', req.params.id).eq('tipo_documento', 'CONTRATO'),
    // Fase 3 (item 3.7): guardrails contratuais (exclusividade, fibra de terceiros, rede
    // própria, direito de preferência) — já existiam desde a Fase 1 (seção 21-24) mas
    // nunca eram devolvidos por esta rota nem mostrados em lugar nenhum.
    supabase.from('contrato_regras').select('*').eq('contrato_id', req.params.id).maybeSingle(),
    supabase.from('contrato_clientes_reservados').select('*').eq('contrato_id', req.params.id).order('cliente_nome'),
    supabase.from('ativos').select('id, tipo, fabricante, modelo, numero_serie, patrimonio, valor, status').eq('contrato_id', req.params.id).is('removido_em', null),
  ]);
  if (cError) return handleError(res, cError);
  if (!contrato) return res.status(404).json({ error: `Contrato ${req.params.id} não encontrado.` });
  return res.json({
    ...contrato,
    pricing_config: pricingConfig || null,
    fibras_alocadas: fibras || [],
    aditivos: aditivos || [],
    reajustes: reajustes || [],
    envelopes_assinatura: envelopes || [],
    regras: regras || null,
    clientes_reservados: clientesReservados || [],
    ativos: ativos || [],
  });
});

// PATCH /api/contracts/:id/regras — Fase 3 (item 3.7): editar guardrails contratuais
// (exclusividade/fibra de terceiros/rede própria/direito de preferência/área). RLS já
// restringe a escrita a DIRETOR/ADMINISTRADOR (contrato_regras_write) — a rota só
// encaminha, nunca decide RBAC aqui.
router.patch('/:id/regras', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const campos = [
    'exclusividade_comercial', 'exclusividade_tipo', 'area_exclusividade', 'exclusividade_cidade_id',
    'exclusividade_pop_id', 'exclusividade_servico', 'exclusividade_capacidade_max', 'exclusividade_prazo_meses',
    'proibe_fibra_terceiros', 'proibe_rede_propria', 'direito_preferencia', 'exige_aprovacao_expansao',
    'permite_outros_parceiros', 'direito_proprietario_explorar_capacidade_remanescente', 'observacoes',
  ];
  const patch = {};
  for (const c of campos) if (c in (req.body || {})) patch[c] = req.body[c];
  const { data, error } = await supabase
    .from('contrato_regras')
    .upsert({ contrato_id: req.params.id, ...patch }, { onConflict: 'contrato_id' })
    .select('*')
    .maybeSingle();
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/contracts/:id/clientes-reservados — Fase 3 (item 3.7): adicionar cliente
// reservado (ex.: exceção Prefeitura, seção 24). RLS restringe a DIRETOR/ADMINISTRADOR.
router.post('/:id/clientes-reservados', async (req, res) => {
  const { cliente_nome, cnpj_cpf, cidade_id, motivo } = req.body || {};
  if (!cliente_nome) return res.status(400).json({ error: 'cliente_nome é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('contrato_clientes_reservados')
    .insert({ contrato_id: req.params.id, cliente_nome, cnpj_cpf: cnpj_cpf || null, cidade_id: cidade_id || null, motivo: motivo || null })
    .select('*')
    .maybeSingle();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// PATCH /api/contracts/:id/clientes-reservados/:reservaId — liberar (ou re-reservar) um
// cliente reservado.
router.patch('/:id/clientes-reservados/:reservaId', async (req, res) => {
  const { status } = req.body || {};
  if (!['RESERVADO', 'LIBERADO'].includes(status)) return res.status(400).json({ error: 'status deve ser RESERVADO ou LIBERADO.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('contrato_clientes_reservados')
    .update({ status })
    .eq('id', req.params.reservaId)
    .eq('contrato_id', req.params.id)
    .select('*')
    .maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: 'Cliente reservado não encontrado.' });
  return res.json(data);
});

// GET /api/contracts/:id/minuta?formato=PDF|DOCX — Fase 3 (item 3.7): gera e devolve a
// MINUTA DE CONTRATO (documento gerado no servidor, nunca "imprimir a tela"), registrando
// a exportação na auditoria antes de devolver o binário — mesmo padrão de
// GET /api/proposals/:id/export.
router.get('/:id/minuta', async (req, res) => {
  const formato = String(req.query.formato || 'PDF').toUpperCase();
  if (!['PDF', 'DOCX'].includes(formato)) {
    return res.status(400).json({ error: 'formato deve ser PDF ou DOCX.' });
  }

  const supabase = clientForRequest(req.userJwt);
  const { data: dados, error: fetchError } = await supabase.rpc('pricing_contrato_documento_dados', { p_contrato_id: req.params.id });
  if (fetchError) return handleError(res, fetchError);
  if (!dados) return res.status(404).json({ error: `Contrato ${req.params.id} não encontrado.` });

  try {
    const buffer = formato === 'PDF' ? await generateContratoPdf(dados) : await generateContratoDocx(dados);

    const { error: exportError } = await supabase.rpc('pricing_contrato_registrar_exportacao_minuta', {
      p_contrato_id: req.params.id,
      p_formato: formato,
      p_versao_rotulo: `V${dados.contrato?.versao_atual ?? 1}`,
    });
    if (exportError) return handleError(res, exportError);

    const slug = (s) => (s || 'NA').normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-zA-Z0-9]+/g, '_').replace(/^_+|_+$/g, '');
    const dataStr = new Date().toISOString().slice(0, 10).replace(/-/g, '');
    const fileName = `OPTIMON_Minuta_${slug(dados.cidade?.nome)}_${slug(dados.parceiro?.razao_social)}_${dataStr}.${formato.toLowerCase()}`;

    res.setHeader('Content-Type', formato === 'PDF' ? 'application/pdf' : 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
    res.setHeader('Content-Disposition', `attachment; filename="${fileName}"`);
    return res.send(buffer);
  } catch (err) {
    return res.status(500).json({ error: err?.message || 'Falha ao gerar a minuta do contrato.' });
  }
});

// POST /api/contracts/generate — "GERAR CONTRATO" (seção 32-33). Nunca
// inventa cláusula — só preenche dados a partir da proposta já ASSINADA.
router.post('/generate', async (req, res) => {
  const { proposta_id, prazo_minimo_excecao, motivo_excecao_prazo } = req.body || {};
  if (!proposta_id) return res.status(400).json({ error: 'proposta_id é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_contract_generate_from_proposal', {
    p_proposta_id: proposta_id,
    p_prazo_minimo_excecao: !!prazo_minimo_excecao,
    p_motivo_excecao_prazo: motivo_excecao_prazo ?? null,
  });
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// POST /api/contracts/:id/activate — seção 36: bloqueia com motivo se houver
// conflito de infraestrutura ou se a infra ainda não foi alocada.
router.post('/:id/activate', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_contract_activate', { p_contrato_id: req.params.id });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/contracts/:id/reajuste — seção 40. Nunca reescreve valor
// histórico — sempre um novo evento em `reajustes` + nova `pricing_versions`.
router.post('/:id/reajuste', async (req, res) => {
  const { percentual, competencia_base, indice_id, motivo } = req.body || {};
  if (percentual === undefined || percentual === null) {
    return res.status(400).json({ error: 'percentual é obrigatório (ex.: 0.045 para 4,5%).' });
  }
  const supabase = clientForRequest(req.userJwt);
  const params = { p_contrato_id: req.params.id, p_percentual: percentual };
  if (competencia_base) params.p_competencia_base = competencia_base;
  if (indice_id) params.p_indice_id = indice_id;
  if (motivo) params.p_motivo = motivo;
  const { data, error } = await supabase.rpc('pricing_contract_apply_reajuste', params);
  if (error) return handleError(res, error);
  return res.status(201).json({ reajuste_id: data });
});

// ============================================================================
// Aditivos (seção 39) — RASCUNHO → EM_APROVACAO → APROVADO → ASSINATURA → ATIVO
// ============================================================================

// GET /api/contracts/:id/aditivos
router.get('/:id/aditivos', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('contrato_aditivos').select('*').eq('contrato_id', req.params.id).order('numero');
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/contracts/:id/aditivos — cria em RASCUNHO. `numero` é definido
// pelo próprio banco via constraint de unicidade (contrato_id, numero) — o
// chamador informa o próximo número livre; RLS (contrato_aditivos_insert) já
// restringe a COMERCIAL/DIRETOR/ADMINISTRADOR.
router.post('/:id/aditivos', async (req, res) => {
  const b = req.body || {};
  if (!b.numero || !b.tipo || !b.descricao) {
    return res.status(400).json({ error: 'numero, tipo e descricao são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('contrato_aditivos')
    .insert({
      contrato_id: req.params.id,
      numero: b.numero,
      tipo: b.tipo,
      descricao: b.descricao,
      data: b.data || undefined,
      inicio_vigencia: b.inicio_vigencia ?? null,
      fim_vigencia: b.fim_vigencia ?? null,
    })
    .select('*')
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// PATCH /api/contracts/:id/aditivos/:aditivoId — dois casos:
//  1) `status` presente (EM_APROVACAO/APROVADO/REJEITADO): passa pela RPC
//     app.aprovar_aditivo (migration 15) — `aprovado_por` é sempre auth.uid()
//     no servidor, NUNCA aceito do corpo da requisição.
//  2) só campos de conteúdo (descricao/vigência): UPDATE direto, coberto pela
//     mesma RLS de sempre (contrato_aditivos_update).
router.patch('/:id/aditivos/:aditivoId', async (req, res) => {
  const b = req.body || {};
  const supabase = clientForRequest(req.userJwt);

  if (b.status !== undefined) {
    const { data, error } = await supabase.rpc('pricing_addendum_change_status', { p_aditivo_id: req.params.aditivoId, p_novo_status: b.status });
    if (error) return handleError(res, error);
    return res.json(data);
  }

  const patch = {};
  for (const f of ['descricao', 'inicio_vigencia', 'fim_vigencia']) {
    if (b[f] !== undefined) patch[f] = b[f];
  }
  if (Object.keys(patch).length === 0) return res.status(400).json({ error: 'Nenhum campo para atualizar.' });

  const { data, error } = await supabase.from('contrato_aditivos').update(patch).eq('id', req.params.aditivoId).eq('contrato_id', req.params.id).select('*').maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: `Aditivo ${req.params.aditivoId} não encontrado ou sem permissão.` });
  return res.json(data);
});

// POST /api/contracts/:id/aditivos/:aditivoId/send-signature — vincula um
// envelope já criado (POST /api/signatures/envelopes, tipo_documento=ADITIVO)
// e fecha o ciclo do aditivo (RASCUNHO→APROVAÇÃO→ASSINATURA→ATIVO, seção 39).
router.post('/:id/aditivos/:aditivoId/send-signature', async (req, res) => {
  const { envelope_id } = req.body || {};
  if (!envelope_id) return res.status(400).json({ error: 'envelope_id é obrigatório (crie o envelope antes via POST /api/signatures/envelopes com tipo_documento=ADITIVO).' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_addendum_send_signature', { p_aditivo_id: req.params.aditivoId, p_envelope_id: envelope_id });
  if (error) return handleError(res, error);
  return res.json(data);
});

router.post('/:id/aditivos/:aditivoId/activate', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_addendum_activate', { p_aditivo_id: req.params.aditivoId });
  if (error) return handleError(res, error);
  return res.json(data);
});

// ============================================================================
// Dashboard contratual + alertas (seções 41-42)
// ============================================================================

router.get('/dashboard/resumo', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_dashboard_contratual');
  if (error) return handleError(res, error);
  return res.json(data);
});

router.post('/dashboard/gerar-alertas', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_alerts_generate');
  if (error) return handleError(res, error);
  return res.json({ alertas_criados: data });
});

router.get('/dashboard/alertas', async (req, res) => {
  const { resolvido } = req.query;
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('alertas').select('*').order('criado_em', { ascending: false });
  if (resolvido === 'false' || resolvido === undefined) query = query.eq('resolvido', false);
  if (resolvido === 'true') query = query.eq('resolvido', true);
  const { data, error } = await query;
  if (error) return handleError(res, error);
  return res.json(data);
});

// Fase 3 (item 3.11): resolver um alerta individual (DIRETOR/FINANCEIRO/ENGENHARIA/ADMINISTRADOR).
router.post('/dashboard/alertas/:id/resolver', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_alerta_resolver', { p_alerta_id: req.params.id });
  if (error) return handleError(res, error);
  return res.json(data);
});

// Fase 3 (item 3.3): capacidade agregada do portfólio (fibras livres/locadas, PONs
// total/ocupadas) — rollup de vw_capacidade_cidade, com detalhe por cidade.
router.get('/dashboard/capacidade', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_dashboard_capacidade');
  if (error) return handleError(res, error);
  return res.json(data);
});

// Fase 3 (item 3.3): receita acumulada do portfólio em 3 cenários (conservador/
// recomendado/otimista), nos horizontes pedidos (default 12/36/48/60 — 48 = prazo
// contratual mínimo, não confundir com os demais, que são só cenários analíticos).
// ESTIMATIVA a partir do MRR contratado hoje — ver campo 'observacao' na resposta.
router.get('/dashboard/cenarios-portfolio', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const horizontesParam = req.query.horizontes;
  const p_horizontes = horizontesParam
    ? String(horizontesParam).split(',').map((v) => parseInt(v, 10)).filter((v) => Number.isFinite(v))
    : [12, 36, 48, 60];
  const { data, error } = await supabase.rpc('pricing_dashboard_cenarios_portfolio', { p_horizontes });
  if (error) return handleError(res, error);
  return res.json(data);
});

module.exports = router;
