// OptiMon Pricing API — rotas de Proposta Comercial.
// Fase 2.2.1 (seção 29/31): criar/listar. Fase 2.4 (módulo profissional de propostas):
// detalhe, versionamento (nova versão/duplicar), aprovação/rejeição/mudança de status,
// registro de exportação PDF/DOCX, e a visão externa (nunca expõe piso/abertura/
// desconto/governança — filtrada no banco, ver pricing_proposal_external_view).

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');
const { generateProposalPdf } = require('../lib/pdfProposal');
const { generateProposalDocx } = require('../lib/docxProposal');

const router = express.Router();

function handleError(res, error) {
  const message = error?.message || 'Erro inesperado.';
  let status;
  if (/PERMISSAO_NEGADA/i.test(message) || /row-level security/i.test(message)) {
    status = 403;
  } else if (/não encontrad/i.test(message)) {
    status = 404;
  } else if (/MOTIVO_OBRIGATORIO/i.test(message)) {
    status = 400;
  } else if (/obrigatóri|inválido/i.test(message)) {
    status = 400;
  } else {
    status = 409;
  }
  return res.status(status).json({ error: message });
}

// Nome de arquivo padrão (seção 8): OPTIMON_Proposta_[Cidade]_[Parceiro]_[AAAAMMDD].ext
function buildFileName(proposta, ext) {
  const slug = (s) =>
    (s || 'NA')
      .normalize('NFD').replace(/[̀-ͯ]/g, '')
      .replace(/[^a-zA-Z0-9]+/g, '')
      .trim() || 'NA';
  const cidade = slug(proposta.cidade_nome);
  const parceiro = slug(proposta.parceiro_nome_capa || proposta.parceiro_nome_fantasia || proposta.parceiro_razao_social);
  const data = (proposta.criado_em || new Date().toISOString()).slice(0, 10).replace(/-/g, '');
  return `OPTIMON_Proposta_${cidade}_${parceiro}_${data}.${ext}`;
}

// POST /api/proposals — "GERAR PROPOSTA" (seção 29 + Fase 2.4 seção 6: capa/validade).
// simulacao_id é obrigatório; o snapshot é montado a partir do resultado já salvo na
// simulação (nunca recalculado aqui) — inclusive o preço proposto, que já deve ter sido
// definido na etapa de simulação (POST /api/simulations, via p_params.preco_proposto).
router.post('/', async (req, res) => {
  const {
    simulacao_id, cidade_id, parceiro_id, contrato_id, pricing_version_id, override_request_id,
    parceiro_nome_capa, parceiro_cargo_contato, validade_dias,
  } = req.body || {};
  if (!simulacao_id) {
    return res.status(400).json({ error: 'simulacao_id é obrigatório — gere/salve a simulação primeiro (POST /api/simulations).' });
  }

  const supabase = clientForRequest(req.userJwt);
  // Só manda os parâmetros novos da Fase 2.4 (capa/versionamento) quando o chamador de
  // fato informou algum deles — chamar sem eles deixa esta rota compatível com a
  // assinatura de pricing_proposal_create de QUALQUER fase anterior à 2.4 (mesmo padrão
  // de routes/cities.js — achado real rodando a cadeia de regressão completa: sem isso,
  // os E2E das fases 1..2.3.1 — que rodam com só as migrations até ali, nunca as desta
  // fase — quebram com "function ... not found in schema cache").
  const params = {
    p_simulacao_id: simulacao_id,
    p_cidade_id: cidade_id ?? null,
    p_parceiro_id: parceiro_id ?? null,
    p_contrato_id: contrato_id ?? null,
    p_pricing_version_id: pricing_version_id ?? null,
    p_override_request_id: override_request_id ?? null,
  };
  if (parceiro_nome_capa != null) params.p_parceiro_nome_capa = parceiro_nome_capa;
  if (parceiro_cargo_contato != null) params.p_parceiro_cargo_contato = parceiro_cargo_contato;
  if (validade_dias != null) params.p_validade_dias = validade_dias;

  const { data, error } = await supabase.rpc('pricing_proposal_create', params);
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// GET /api/proposals?contrato_id=&cidade_id=&status=&parceiro_id=&todas_versoes=true
router.get('/', async (req, res) => {
  const { contrato_id, cidade_id, status, parceiro_id, todas_versoes } = req.query;
  const supabase = clientForRequest(req.userJwt);
  // Mesma compatibilidade de cadeia de regressão do POST / acima: só manda os filtros
  // novos da Fase 2.4 quando usados, pra continuar batendo com a assinatura de
  // pricing_proposals_list de fases anteriores à 2.4.
  const params = { p_contrato_id: contrato_id ?? null, p_cidade_id: cidade_id ?? null };
  if (status) params.p_status = status;
  if (parceiro_id) params.p_parceiro_id = parceiro_id;
  if (todas_versoes === 'true') params.p_somente_ultima_versao = false;

  const { data, error } = await supabase.rpc('pricing_proposals_list', params);
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/proposals/:id — detalhe completo (documento de 28 seções é montado no
// frontend a partir deste jsonb enriquecido).
router.get('/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_proposal_get_by_id', { p_proposta_id: req.params.id });
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: `Proposta ${req.params.id} não encontrada.` });
  return res.json(data);
});

// GET /api/proposals/:id/public — visão externa (seção 46, prep). Filtrada no banco —
// nunca inclui piso/abertura/desconto/governança/autorização (ver migration).
router.get('/:id/public', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_proposal_external_view', { p_proposta_id: req.params.id });
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: `Proposta ${req.params.id} não encontrada.` });
  return res.json(data);
});

// PATCH /api/proposals/:id — Fase 3.10 (Problema 2, seção 2.1): única rota que permite
// editar parceiro_nome_capa/parceiro_cargo_contato/observacoes_comerciais/proximos_passos
// depois da criação — não existia nenhuma antes desta fase (POST / só aceita os 2
// primeiros campos, e só na criação). RLS decide quem pode (dono em RASCUNHO, ou
// DIRETOR/ADMINISTRADOR) — a rota não faz checagem de perfil própria, mesmo padrão do
// resto deste arquivo.
router.patch('/:id', async (req, res) => {
  const { parceiro_nome_capa, parceiro_cargo_contato, observacoes_comerciais, proximos_passos } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_proposal_update_display_fields', {
    p_proposta_id: req.params.id,
    p_parceiro_nome_capa: parceiro_nome_capa ?? null,
    p_parceiro_cargo_contato: parceiro_cargo_contato ?? null,
    p_observacoes_comerciais: observacoes_comerciais ?? null,
    p_proximos_passos: proximos_passos ?? null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/proposals/:id/versions — histórico de versões (V1/V2/V3..., seção 40).
router.get('/:id/versions', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_proposal_versions', { p_proposta_id: req.params.id });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/proposals/:id/version — cria a próxima versão (V2/V3...) na mesma família.
router.post('/:id/version', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_proposal_new_version', {
    p_proposta_id: req.params.id,
    p_motivo: req.body?.motivo ?? null,
  });
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// POST /api/proposals/:id/duplicate — "Duplicar Proposta" (seção 41): nova proposta
// independente (própria família de versão), sempre RASCUNHO.
router.post('/:id/duplicate', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_proposal_duplicate', {
    p_proposta_id: req.params.id,
    p_motivo: req.body?.motivo ?? null,
  });
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// POST /api/proposals/:id/approve — aprovação (DIRETOR/ADMINISTRADOR). motivo é
// obrigatório quando o preço proposto está abaixo do piso (seção 38).
router.post('/:id/approve', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_proposal_approve', {
    p_proposta_id: req.params.id,
    p_motivo: req.body?.motivo ?? null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/proposals/:id/reject — rejeição (motivo sempre obrigatório, seção 37).
router.post('/:id/reject', async (req, res) => {
  const { motivo } = req.body || {};
  if (!motivo) return res.status(400).json({ error: 'motivo é obrigatório para rejeitar uma proposta.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_proposal_reject', { p_proposta_id: req.params.id, p_motivo: motivo });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/proposals/:id/status — demais transições (ENVIADA/EM_NEGOCIACAO/ACEITA/
// EXPIRADA/CANCELADA — seção 36).
router.post('/:id/status', async (req, res) => {
  const { status, motivo } = req.body || {};
  if (!status) return res.status(400).json({ error: 'status é obrigatório.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_proposal_change_status', {
    p_proposta_id: req.params.id,
    p_novo_status: status,
    p_motivo: motivo ?? null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/proposals/:id/export?formato=PDF|DOCX — gera e devolve o arquivo (seções
// 8/9/39/42: nunca é "imprimir a tela", documento gerado no servidor com pdfkit/docx),
// registrando a exportação na auditoria antes de devolver o binário.
router.get('/:id/export', async (req, res) => {
  const formato = String(req.query.formato || 'PDF').toUpperCase();
  if (!['PDF', 'DOCX'].includes(formato)) {
    return res.status(400).json({ error: 'formato deve ser PDF ou DOCX.' });
  }

  const supabase = clientForRequest(req.userJwt);
  const { data: proposta, error: fetchError } = await supabase.rpc('pricing_proposal_get_by_id', { p_proposta_id: req.params.id });
  if (fetchError) return handleError(res, fetchError);
  if (!proposta) return res.status(404).json({ error: `Proposta ${req.params.id} não encontrada.` });

  const modo = req.query.modo === 'externa' ? 'EXTERNA' : 'INTERNA';

  try {
    const fileName = buildFileName(proposta, formato.toLowerCase());
    const buffer = formato === 'PDF'
      ? await generateProposalPdf(proposta, { modo })
      : await generateProposalDocx(proposta, { modo });

    const { error: exportError } = await supabase.rpc('pricing_proposal_register_export', {
      p_proposta_id: req.params.id,
      p_formato: formato,
      p_versao_rotulo: `V${proposta.numero_versao} (${modo})`,
    });
    if (exportError) return handleError(res, exportError);

    res.setHeader('Content-Type', formato === 'PDF' ? 'application/pdf' : 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
    res.setHeader('Content-Disposition', `attachment; filename="${fileName}"`);
    return res.send(buffer);
  } catch (err) {
    return res.status(500).json({ error: err?.message || 'Falha ao gerar o documento da proposta.' });
  }
});

module.exports = router;
