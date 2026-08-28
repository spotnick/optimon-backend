// OptiMon Pricing API — rotas de Proponente (seções 16-19) + Responsáveis + Documentos.
//
// DECISÃO DE ARQUITETURA (ver migration 02 e docs/ARQUITETURA.md seção 23):
// "Proponente" = a tabela `parceiros` já existente desde a Fase 1, estendida —
// nunca uma tabela nova paralela. Esta rota, que na Fase 2.4 só tinha um GET de
// leitura, ganha aqui o CRUD completo de proponente + os sub-recursos
// responsáveis/documentos (seções 17-19).
//
// Storage (seção 19/45): documentos de proponente vão para o bucket privado
// `documentos` (ver supabase/storage_setup_fase25.sql — não uma migration, por
// esse bucket exigir o schema `storage`, que só existe num projeto Supabase
// real, nunca no Postgres puro do harness de teste local desta sessão — ver o
// cabeçalho daquele arquivo e o relatório final para o detalhe completo dessa
// limitação de ambiente). Upload/download nunca expõem uma URL pública fixa —
// sempre um signed URL de curto prazo, gerado só depois que a linha de
// metadado em `documentos` já passou pela RLS (select=todos autenticados,
// igual ao resto do projeto — o ID da linha por si só não entrega o arquivo).

const express = require('express');
const multer = require('multer');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 20 * 1024 * 1024 } });

// Auditoria semântica é sempre best-effort — nunca deve derrubar uma resposta
// cuja ação principal já teve sucesso. supabase-js devolve, para .rpc(), um
// builder "thenable" (só implementa .then(), não .catch()/.finally() — não é
// uma Promise real); encadear `.catch()` direto nele lança `TypeError:
// ...catch is not a function` e derruba a rota com 500 (bug encontrado nos
// testes da Fase 2.5.1). Por isso sempre `await` dentro de um try/catch.
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

const PROPONENTE_FIELDS = `id, razao_social, nome_fantasia, cnpj, email_contato, telefone_contato, responsavel_comercial,
  inscricao_estadual, inscricao_municipal, endereco_logradouro, endereco_numero, endereco_complemento, endereco_bairro,
  endereco_cidade, endereco_uf, endereco_cep, site, observacoes, ativo, criado_em, atualizado_em`;

// ============================================================================
// Proponente (parceiros)
// ============================================================================

// GET /api/partners?q=&ativo= — lista (mantém compatibilidade com o formato
// enxuto que a Fase 2.4 já consumia no seletor de proposta).
router.get('/', async (req, res) => {
  const { q, ativo } = req.query;
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('parceiros').select(PROPONENTE_FIELDS).is('removido_em', null).order('nome_fantasia', { ascending: true, nullsFirst: false });
  if (ativo === 'true' || ativo === undefined) query = query.eq('ativo', true);
  if (ativo === 'false') query = query.eq('ativo', false);
  if (ativo === 'todos') query = supabase.from('parceiros').select(PROPONENTE_FIELDS).is('removido_em', null).order('nome_fantasia');
  if (q) query = query.or(`razao_social.ilike.%${q}%,nome_fantasia.ilike.%${q}%,cnpj.ilike.%${q}%`);

  const { data, error } = await query;
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/partners/:id
router.get('/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('parceiros').select(PROPONENTE_FIELDS).eq('id', req.params.id).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: `Proponente ${req.params.id} não encontrado.` });
  return res.json(data);
});

// POST /api/partners — cadastrar proponente (seção 16). RLS já exige
// COMERCIAL/DIRETOR/ADMINISTRADOR — Node nunca duplica essa checagem.
router.post('/', async (req, res) => {
  const b = req.body || {};
  if (!b.razao_social || !b.cnpj) {
    return res.status(400).json({ error: 'razao_social e cnpj são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('parceiros')
    .insert({
      razao_social: b.razao_social,
      nome_fantasia: b.nome_fantasia ?? null,
      cnpj: b.cnpj,
      email_contato: b.email_contato ?? null,
      telefone_contato: b.telefone_contato ?? null,
      responsavel_comercial: b.responsavel_comercial ?? null,
      inscricao_estadual: b.inscricao_estadual ?? null,
      inscricao_municipal: b.inscricao_municipal ?? null,
      endereco_logradouro: b.endereco_logradouro ?? null,
      endereco_numero: b.endereco_numero ?? null,
      endereco_complemento: b.endereco_complemento ?? null,
      endereco_bairro: b.endereco_bairro ?? null,
      endereco_cidade: b.endereco_cidade ?? null,
      endereco_uf: b.endereco_uf ?? null,
      endereco_cep: b.endereco_cep ?? null,
      site: b.site ?? null,
      observacoes: b.observacoes ?? null,
    })
    .select(PROPONENTE_FIELDS)
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// PATCH /api/partners/:id — edição cadastral. NUNCA reescreve retroativamente
// propostas/contratos já gerados (seção 44) — esses guardam snapshot próprio,
// não uma referência viva a este registro; este PATCH só afeta cadastro futuro.
router.patch('/:id', async (req, res) => {
  const b = req.body || {};
  const patch = {};
  for (const f of ['razao_social', 'nome_fantasia', 'email_contato', 'telefone_contato', 'responsavel_comercial',
    'inscricao_estadual', 'inscricao_municipal', 'endereco_logradouro', 'endereco_numero', 'endereco_complemento',
    'endereco_bairro', 'endereco_cidade', 'endereco_uf', 'endereco_cep', 'site', 'observacoes', 'ativo']) {
    if (b[f] !== undefined) patch[f] = b[f];
  }
  if (Object.keys(patch).length === 0) return res.status(400).json({ error: 'Nenhum campo para atualizar.' });

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('parceiros').update(patch).eq('id', req.params.id).select(PROPONENTE_FIELDS).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) {
    // RLS bloqueia a UPDATE em silêncio (0 linhas, sem erro) — distingue
    // "não existe" de "existe mas sem permissão" com uma leitura à parte
    // (parceiros_select libera todo authenticated, então não vaza nada novo).
    const { data: exists } = await supabase.from('parceiros').select('id').eq('id', req.params.id).maybeSingle();
    if (exists) return res.status(403).json({ error: 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem editar proponente.' });
    return res.status(404).json({ error: `Proponente ${req.params.id} não encontrado.` });
  }
  return res.json(data);
});

// POST /api/partners/:id/deactivate e /reactivate — Fase 2.5.1 (seções 9-10).
// A escrita em si já era possível via PATCH {ativo}; estas rotas só
// acrescentam o registro semântico de auditoria ao lado da mesma UPDATE
// (mesma RLS de sempre — parceiros_update, COMERCIAL/DIRETOR/ADMINISTRADOR),
// para o "porquê" (motivo) ficar registrado, não só o "o quê".
async function setPartnerActive(req, res, ativo) {
  const { motivo } = req.body || {};
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('parceiros').update({ ativo }).eq('id', req.params.id).select(PROPONENTE_FIELDS).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) {
    const { data: exists } = await supabase.from('parceiros').select('id').eq('id', req.params.id).maybeSingle();
    if (exists) return res.status(403).json({ error: 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem desativar/reativar proponente.' });
    return res.status(404).json({ error: `Proponente ${req.params.id} não encontrado.` });
  }
  await logSemanticEventBestEffort(supabase, {
    p_entidade: 'parceiros', p_entidade_id: req.params.id, p_acao: ativo ? 'PARTNER_REACTIVATE' : 'PARTNER_DEACTIVATE', p_motivo: motivo || null,
  });
  return res.json(data);
}
router.post('/:id/deactivate', (req, res) => setPartnerActive(req, res, false));
router.post('/:id/reactivate', (req, res) => setPartnerActive(req, res, true));

// ============================================================================
// Responsáveis (seção 17-18)
// ============================================================================

const RESPONSAVEL_FIELDS = 'id, parceiro_id, nome, cpf, cargo, departamento, email, telefone, whatsapp, tipo, representante_legal, documento_comprobatorio_id, ativo, criado_em, atualizado_em';

// GET /api/partners/:id/responsaveis?incluir_removidos=true — Fase 3 (item 3.9):
// por padrão só traz responsáveis ativos (removido_em is null, mesmo comportamento de
// sempre), mas agora aceita incluir_removidos=true para a tela poder oferecer
// "Restaurar" — sem esse parâmetro, um responsável removido ficava permanentemente
// invisível, sem nenhuma forma de reencontrá-lo pela UI (gap encontrado ao auditar
// completude de CRUD).
router.get('/:id/responsaveis', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('parceiros_responsaveis').select(RESPONSAVEL_FIELDS).eq('parceiro_id', req.params.id);
  if (req.query.incluir_removidos !== 'true') query = query.is('removido_em', null);
  const { data, error } = await query.order('nome');
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/partners/:id/responsaveis — seção 17. `representante_legal=true` é
// só um indicador de papel — NUNCA implica poder de assinar por si só (seção
// 18): a autoridade real só vem de um documento comprobatório anexado (ver
// PATCH .../responsaveis/:respId com documento_comprobatorio_id).
router.post('/:id/responsaveis', async (req, res) => {
  const b = req.body || {};
  if (!b.nome || !b.tipo) {
    return res.status(400).json({ error: 'nome e tipo são obrigatórios (tipo: REPRESENTANTE_LEGAL/RESPONSAVEL_COMERCIAL/RESPONSAVEL_FINANCEIRO/RESPONSAVEL_TECNICO/TESTEMUNHA/OUTRO).' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('parceiros_responsaveis')
    .insert({
      parceiro_id: req.params.id,
      nome: b.nome,
      cpf: b.cpf ?? null,
      cargo: b.cargo ?? null,
      departamento: b.departamento ?? null,
      email: b.email ?? null,
      telefone: b.telefone ?? null,
      whatsapp: b.whatsapp ?? null,
      tipo: b.tipo,
      representante_legal: !!b.representante_legal,
    })
    .select(RESPONSAVEL_FIELDS)
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// PATCH /api/partners/:id/responsaveis/:respId — inclui vincular o documento
// comprobatorio (Contrato Social/Procuração/Ata) que efetivamente atesta poder
// de representação (seção 18).
router.patch('/:id/responsaveis/:respId', async (req, res) => {
  const b = req.body || {};
  const patch = {};
  for (const f of ['nome', 'cpf', 'cargo', 'departamento', 'email', 'telefone', 'whatsapp', 'tipo', 'representante_legal', 'documento_comprobatorio_id', 'ativo']) {
    if (b[f] !== undefined) patch[f] = b[f];
  }
  if (Object.keys(patch).length === 0) return res.status(400).json({ error: 'Nenhum campo para atualizar.' });

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('parceiros_responsaveis')
    .update(patch)
    .eq('id', req.params.respId)
    .eq('parceiro_id', req.params.id)
    .select(RESPONSAVEL_FIELDS)
    .maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: `Responsável ${req.params.respId} não encontrado.` });
  return res.json(data);
});

// DELETE lógico — nunca DELETE físico (disciplina do projeto).
router.delete('/:id/responsaveis/:respId', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('parceiros_responsaveis')
    .update({ ativo: false, removido_em: new Date().toISOString() })
    .eq('id', req.params.respId)
    .eq('parceiro_id', req.params.id)
    .select(RESPONSAVEL_FIELDS)
    .maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: `Responsável ${req.params.respId} não encontrado.` });
  return res.json(data);
});

// POST /api/partners/:id/responsaveis/:respId/restore — Fase 3 (item 3.9): restaura um
// responsável removido (limpa removido_em, reativa). Rota dedicada em vez de aceitar
// removido_em na whitelist do PATCH acima — removido_em nunca é um campo livremente
// setável pelo cliente, só por um caminho controlado e explícito, mesmo padrão de
// restauração já usado para cidades/POPs/segmentos em outras telas do sistema.
router.post('/:id/responsaveis/:respId/restore', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('parceiros_responsaveis')
    .update({ ativo: true, removido_em: null })
    .eq('id', req.params.respId)
    .eq('parceiro_id', req.params.id)
    .select(RESPONSAVEL_FIELDS)
    .maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: `Responsável ${req.params.respId} não encontrado.` });
  return res.json(data);
});

// ============================================================================
// Documentos do proponente (seção 19) — Storage privado, nunca bucket público.
// ============================================================================

const DOCUMENTO_FIELDS = 'id, parceiro_id, responsavel_id, tipo, titulo, versao, validade, status, criado_em';

// GET /api/partners/:id/documentos
router.get('/:id/documentos', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('documentos')
    .select(DOCUMENTO_FIELDS)
    .eq('parceiro_id', req.params.id)
    .eq('proponente_documento', true)
    .is('removido_em', null)
    .order('criado_em', { ascending: false });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/partners/:id/documentos — multipart/form-data (campo `arquivo`) +
// tipo/titulo/responsavel_id/validade. Sobe para Storage com o client
// escopado ao JWT do usuário (RLS de storage.objects decide, nunca a
// service_role) e só então grava a linha de metadado.
router.post('/:id/documentos', upload.single('arquivo'), async (req, res) => {
  const { tipo, titulo, responsavel_id, validade } = req.body || {};
  if (!req.file) return res.status(400).json({ error: 'arquivo é obrigatório (multipart/form-data, campo "arquivo").' });
  if (!tipo || !titulo) return res.status(400).json({ error: 'tipo e titulo são obrigatórios.' });

  const supabase = clientForRequest(req.userJwt);
  const safeName = req.file.originalname.replace(/[^a-zA-Z0-9._-]+/g, '_');
  const storagePath = `${req.params.id}/${tipo}/${Date.now()}-${safeName}`;

  const { error: uploadError } = await supabase.storage
    .from('documentos')
    .upload(storagePath, req.file.buffer, { contentType: req.file.mimetype, upsert: false });
  if (uploadError) {
    return res.status(502).json({ error: `Falha ao enviar arquivo para o Storage: ${uploadError.message}. Verifique se supabase/storage_setup_fase25.sql já foi executado neste projeto Supabase.` });
  }

  const { data, error } = await supabase
    .from('documentos')
    .insert({
      parceiro_id: req.params.id,
      responsavel_id: responsavel_id || null,
      tipo,
      titulo,
      storage_path: storagePath,
      validade: validade || null,
      proponente_documento: true,
    })
    .select(DOCUMENTO_FIELDS)
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

// GET /api/partners/documentos/:docId/download — nunca devolve o storage_path
// cru nem uma URL pública; sempre um signed URL de curto prazo (seção 45).
// A checagem "este usuário pode ver este documento" acontece na própria
// consulta a `documentos` (RLS) — se a linha não vier, 404 antes de sequer
// tentar gerar a URL assinada.
router.get('/documentos/:docId/download', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data: doc, error } = await supabase.from('documentos').select('id, storage_path, titulo, status').eq('id', req.params.docId).maybeSingle();
  if (error) return handleError(res, error);
  if (!doc) return res.status(404).json({ error: `Documento ${req.params.docId} não encontrado.` });

  const { data: signed, error: signError } = await supabase.storage.from('documentos').createSignedUrl(doc.storage_path, 300);
  if (signError) return res.status(502).json({ error: `Falha ao gerar link de download: ${signError.message}.` });

  return res.json({ id: doc.id, titulo: doc.titulo, status: doc.status, url: signed.signedUrl, expira_em_segundos: 300 });
});

module.exports = router;
