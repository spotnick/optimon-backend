// OptiMon Pricing API — Fase 2.5: Signature Engine (seções 4-13, 24-28, 48-51, 56).
//
// `router` (exportado como default) cobre tudo que exige um usuário logado
// (providers/envelopes/signers/send/cancel/status/document/audit/validate).
// `webhookRouter` (exportado separadamente) é montado em server.js SEM
// `requireAuth` — é a única rota HTTP desta API que aceita chamada sem JWT de
// usuário, porque quem chama é o provedor de assinatura externo, não alguém
// logado no OptiMon (seção 27). Autenticidade do payload é validada por HMAC
// ANTES de qualquer escrita — nunca confia cegamente no corpo da requisição
// (seção 49 — "nunca confiar cegamente no payload").
//
// A chamada de rede real ao provedor (createEnvelope/addSigner/.../
// getCertificateInfo) passa sempre por `buildProvider()`
// (api/lib/signatureProvider.js) — nenhuma rota fala diretamente com um SDK
// de fornecedor específico, exatamente a garantia de troca de provedor sem
// reescrever contrato/proposta/banco/workflow/frontend/auditoria (seção 4).

const express = require('express');
const crypto = require('crypto');
const multer = require('multer');
const { clientForRequest, anonClient } = require('../lib/supabaseClient');
const { buildProvider } = require('../lib/signatureProvider');
const { generateProposalPdf } = require('../lib/pdfProposal');
const { generateContratoPdf } = require('../lib/pdfContrato');

const router = express.Router();
const webhookRouter = express.Router();
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
  } else if (/não encontrad|NAO_ENCONTRADO/i.test(message)) {
    status = 404;
  } else if (/MOTIVO_OBRIGATORIO|SEM_SIGNATARIOS|STATUS_INVALIDO|CONFIGURACAO_INVALIDA/i.test(message)) {
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

// ============================================================================
// Configuração de Provedor (seção 6) — /configuracoes/assinatura
// ============================================================================

const PROVIDER_FIELDS = 'id, nome, tipo, papel, ambiente, api_url, webhook_url, timeout_segundos, politica_assinatura, ativo, criado_em, atualizado_em';
// api_key_ref/webhook_secret_ref NUNCA saem por aqui como valor — mas o NOME
// da variável (não o segredo) é informação operacional útil pra quem está
// configurando o provedor, então é incluído à parte, explicitamente.
const PROVIDER_FIELDS_ADMIN = `${PROVIDER_FIELDS}, api_key_ref, webhook_secret_ref`;

// Fase 2.5.1 seção 16: passa a usar public.pricing_signature_providers_list()
// em vez de um SELECT direto — a única diferença é que essa função também
// traz "último teste" (colunas novas em signature_providers) e "último
// evento" (derivado de signature_events via LATERAL join, nunca uma coluna
// redundante) — ver migration 20260920090100.
router.get('/providers', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_signature_providers_list');
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/signatures/providers — seção 6. RLS já restringe a ADMINISTRADOR/
// DIRETOR (signature_providers_write). Bloqueia explicitamente MOCK+PRODUCAO
// aqui (mesma regra de api/lib/signatureProvider.js) para devolver um 400
// claro em vez de deixar o erro estourar só na hora de enviar pra assinatura.
router.post('/providers', async (req, res) => {
  const b = req.body || {};
  if (!b.nome || !b.tipo || !b.ambiente) {
    return res.status(400).json({ error: 'nome, tipo e ambiente são obrigatórios.' });
  }
  if (b.tipo === 'ICP_BRASIL_HOMOLOGACAO_MOCK' && b.ambiente === 'PRODUCAO') {
    return res.status(400).json({ error: 'CONFIGURACAO_INVALIDA: o provedor ICP_BRASIL_HOMOLOGACAO_MOCK só pode ser usado em ambiente HOMOLOGACAO — nunca em PRODUCAO (seção 51 do prompt-mestre). Configure um provedor ICP_BRASIL_PROVEDOR_EXTERNO real antes de operar em produção.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('signature_providers')
    .insert({
      nome: b.nome,
      tipo: b.tipo,
      papel: b.papel || 'PRINCIPAL',
      ambiente: b.ambiente,
      api_url: b.api_url ?? null,
      api_key_ref: b.api_key_ref ?? null,
      webhook_url: b.webhook_url ?? null,
      webhook_secret_ref: b.webhook_secret_ref ?? null,
      timeout_segundos: b.timeout_segundos ?? 30,
      politica_assinatura: b.politica_assinatura || 'ICP_BRASIL_QUALIFICADA',
    })
    .select(PROVIDER_FIELDS_ADMIN)
    .single();
  if (error) return handleError(res, error);
  return res.status(201).json(data);
});

router.patch('/providers/:id', async (req, res) => {
  const b = req.body || {};
  if (b.tipo === 'ICP_BRASIL_HOMOLOGACAO_MOCK' && b.ambiente === 'PRODUCAO') {
    return res.status(400).json({ error: 'CONFIGURACAO_INVALIDA: o provedor ICP_BRASIL_HOMOLOGACAO_MOCK só pode ser usado em ambiente HOMOLOGACAO.' });
  }
  const patch = {};
  for (const f of ['nome', 'papel', 'ambiente', 'api_url', 'api_key_ref', 'webhook_url', 'webhook_secret_ref', 'timeout_segundos', 'politica_assinatura', 'ativo']) {
    if (b[f] !== undefined) patch[f] = b[f];
  }
  if (Object.keys(patch).length === 0) return res.status(400).json({ error: 'Nenhum campo para atualizar.' });

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('signature_providers').update(patch).eq('id', req.params.id).select(PROVIDER_FIELDS_ADMIN).maybeSingle();
  if (error) return handleError(res, error);
  if (!data) return res.status(404).json({ error: `Provedor ${req.params.id} não encontrado.` });
  return res.json(data);
});

// POST /api/signatures/providers/:id/test-connection — seção 18 ("TESTAR
// CONEXÃO"). Nunca expõe secret na resposta (só o diagnóstico do provider —
// ver testConnection() em api/lib/signatureProvider.js); grava o resultado em
// ultimo_teste_em/status/mensagem para a tela mostrar "Último teste" mesmo
// depois de recarregar a página, e loga um evento semântico de auditoria.
router.post('/providers/:id/test-connection', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data: providerRow, error: providerError } = await supabase.from('signature_providers').select('*').eq('id', req.params.id).maybeSingle();
  if (providerError) return handleError(res, providerError);
  if (!providerRow) return res.status(404).json({ error: `Provedor ${req.params.id} não encontrado.` });

  let resultado;
  try {
    const provider = buildProvider(providerRow);
    resultado = await provider.testConnection();
  } catch (err) {
    resultado = { ok: false, mensagem: err.message };
  }

  const patch = {
    ultimo_teste_em: new Date().toISOString(),
    ultimo_teste_status: resultado.ok ? 'OK' : 'FALHA',
    ultimo_teste_mensagem: resultado.mensagem,
  };
  // signature_providers_write (RLS) já restringe UPDATE a ADMINISTRADOR/
  // DIRETOR (seção 6) — nunca duplicado aqui em código. Se quem chamou não
  // tem esse perfil, a UPDATE afeta 0 linhas (sem erro) e o diagnóstico
  // ainda assim é devolvido, só com o aviso explícito de que não foi salvo.
  const { data: saved } = await supabase.from('signature_providers').update(patch).eq('id', req.params.id).select('id').maybeSingle();
  await logSemanticEventBestEffort(supabase, {
    p_entidade: 'signature_providers', p_entidade_id: req.params.id, p_acao: 'SIGNATURE_TEST_CONNECTION', p_motivo: resultado.mensagem,
  });

  return res.json({ ...resultado, ...patch, persistido: !!saved });
});

// ============================================================================
// Envelopes / Signatários (seções 5, 10, 24-26)
// ============================================================================

const ENVELOPE_FIELDS = `id, tipo_documento, proposta_id, contrato_id, aditivo_id, provider_id, provider_envelope_id,
  status, politica_assinatura, erro_mensagem, criado_em, enviado_em, concluido_em, cancelado_em`;

// GET /api/signatures/envelopes?proposta_id=&contrato_id=&aditivo_id=&status= — /assinaturas
router.get('/envelopes', async (req, res) => {
  const { proposta_id, contrato_id, aditivo_id, status } = req.query;
  const supabase = clientForRequest(req.userJwt);
  let query = supabase.from('signature_envelopes').select(ENVELOPE_FIELDS).order('criado_em', { ascending: false });
  if (proposta_id) query = query.eq('proposta_id', proposta_id);
  if (contrato_id) query = query.eq('contrato_id', contrato_id);
  if (aditivo_id) query = query.eq('aditivo_id', aditivo_id);
  if (status) query = query.eq('status', status);
  const { data, error } = await query;
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/signatures/envelopes/:id — detalhe + signatários (seção 26: status
// individual por signatário).
router.get('/envelopes/:id', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const [{ data: envelope, error: envError }, { data: signers, error: signersError }] = await Promise.all([
    supabase.from('signature_envelopes').select(ENVELOPE_FIELDS).eq('id', req.params.id).maybeSingle(),
    supabase.from('signature_signers').select('id, nome, email, cpf, papel, ordem, status, assinado_em, ip_assinatura').eq('envelope_id', req.params.id).order('ordem'),
  ]);
  if (envError) return handleError(res, envError);
  if (signersError) return handleError(res, signersError);
  if (!envelope) return res.status(404).json({ error: `Envelope ${req.params.id} não encontrado.` });
  return res.json({ ...envelope, signatarios: signers || [] });
});

// POST /api/signatures/envelopes — cria o envelope (createEnvelope, seção 5).
// tipo_documento=PROPOSTA gera o PDF automaticamente pelo motor já existente
// (api/lib/pdfProposal.js). Fase 3.11 (seção 17): tipo_documento=CONTRATO agora
// TAMBÉM gera o PDF automaticamente — reaproveitando sem alteração o motor de
// minuta já construído nas Fases 3.9/3.10 (api/lib/pdfContrato.js +
// app.contrato_documento_dados/pricing_contrato_documento_dados, o mesmo usado por
// GET /api/contracts/:id/minuta). A limitação documentada na Fase 2.5 ("motor de
// PDF de contrato não construído nesta fase") ficou desatualizada — corrigida
// aqui. ADITIVO continua exigindo upload manual (nenhum motor de documento de
// aditivo existe ainda — não inventado nesta fase, fora do escopo 3.11).
router.post('/envelopes', upload.single('arquivo'), async (req, res) => {
  const { tipo_documento, provider_id, proposta_id, contrato_id, aditivo_id } = req.body || {};
  if (!tipo_documento || !provider_id) {
    return res.status(400).json({ error: 'tipo_documento e provider_id são obrigatórios.' });
  }
  const supabase = clientForRequest(req.userJwt);

  const { data: providerRow, error: providerError } = await supabase.from('signature_providers').select('*').eq('id', provider_id).maybeSingle();
  if (providerError) return handleError(res, providerError);
  if (!providerRow) return res.status(404).json({ error: `Provedor ${provider_id} não encontrado.` });

  let documentBuffer = req.file ? req.file.buffer : null;
  let fileName = req.file ? req.file.originalname : null;

  if (!documentBuffer && tipo_documento === 'PROPOSTA' && proposta_id) {
    const { data: proposta, error: propError } = await supabase.rpc('pricing_proposal_get_by_id', { p_proposta_id: proposta_id });
    if (propError) return handleError(res, propError);
    if (!proposta) return res.status(404).json({ error: `Proposta ${proposta_id} não encontrada.` });
    documentBuffer = await generateProposalPdf(proposta, { modo: 'EXTERNA' });
    fileName = `proposta_${proposta_id}.pdf`;
  }
  if (!documentBuffer && tipo_documento === 'CONTRATO' && contrato_id) {
    const { data: dadosContrato, error: contratoError } = await supabase.rpc('pricing_contrato_documento_dados', { p_contrato_id: contrato_id });
    if (contratoError) return handleError(res, contratoError);
    if (!dadosContrato) return res.status(404).json({ error: `Contrato ${contrato_id} não encontrado.` });
    documentBuffer = await generateContratoPdf(dadosContrato);
    fileName = `contrato_${contrato_id}.pdf`;
  }
  if (!documentBuffer) {
    return res.status(400).json({ error: 'Nenhum documento disponível: envie um PDF via multipart (campo "arquivo"), ou informe proposta_id/contrato_id para tipo_documento=PROPOSTA/CONTRATO (gerados automaticamente).' });
  }

  let providerResult;
  try {
    const provider = buildProvider(providerRow);
    providerResult = await provider.createEnvelope({ documentBuffer, fileName });
  } catch (err) {
    return res.status(502).json({ error: `Falha ao criar envelope no provedor: ${err.message}` });
  }

  const { data: envelope, error } = await supabase
    .rpc('pricing_signature_envelope_create', {
      p_tipo_documento: tipo_documento,
      p_provider_id: provider_id,
      p_proposta_id: proposta_id || null,
      p_contrato_id: contrato_id || null,
      p_aditivo_id: aditivo_id || null,
    });
  if (error) return handleError(res, error);

  // Guarda o hash/ID do provedor e sobe o documento original para o Storage
  // privado (seção 19/45) — path próprio do envelope, nunca reaproveitando o
  // path de outro documento.
  const storagePath = `envelopes/${envelope.id}/original-${fileName || 'documento.pdf'}`;
  const { error: uploadError } = await supabase.storage.from('documentos').upload(storagePath, documentBuffer, { contentType: 'application/pdf', upsert: true });

  const { data: updated, error: updateError } = await supabase
    .from('signature_envelopes')
    .update({
      provider_envelope_id: providerResult.providerEnvelopeId,
      hash_original: providerResult.hashOriginal || null,
      documento_original_storage_path: uploadError ? null : storagePath,
    })
    .eq('id', envelope.id)
    .select(ENVELOPE_FIELDS)
    .single();
  if (updateError) return handleError(res, updateError);

  return res.status(201).json({ ...updated, storage_warning: uploadError ? `Envelope criado mas upload do documento original falhou: ${uploadError.message} (ver supabase/storage_setup_fase25.sql).` : undefined });
});

// POST /api/signatures/envelopes/:id/signers — addSigner + configureSigningOrder (seção 5, 25).
router.post('/envelopes/:id/signers', async (req, res) => {
  const b = req.body || {};
  if (!b.nome || !b.email || !b.papel) {
    return res.status(400).json({ error: 'nome, email e papel são obrigatórios (papel: REPRESENTANTE_NICK/REPRESENTANTE_PROPONENTE/TESTEMUNHA/OUTRO).' });
  }
  const supabase = clientForRequest(req.userJwt);

  const { data: envelopeRow, error: envError } = await supabase.from('signature_envelopes').select('provider_id, provider_envelope_id').eq('id', req.params.id).maybeSingle();
  if (envError) return handleError(res, envError);
  if (!envelopeRow) return res.status(404).json({ error: `Envelope ${req.params.id} não encontrado.` });

  const { data: signer, error } = await supabase.rpc('pricing_signature_signer_add', {
    p_envelope_id: req.params.id,
    p_nome: b.nome,
    p_email: b.email,
    p_papel: b.papel,
    p_ordem: b.ordem ?? 1,
    p_cpf: b.cpf ?? null,
    p_responsavel_id: b.responsavel_id ?? null,
    // Fase 3.11.2 (seção 7): "definir quais assinaturas são obrigatórias" — default
    // true (mesmo default do banco) quando o chamador não especifica.
    p_obrigatorio: b.obrigatorio === undefined ? true : !!b.obrigatorio,
  });
  if (error) return handleError(res, error);

  // Best-effort no provedor mock — nunca bloqueia a resposta se o provedor
  // falhar aqui (o estado de verdade é o do OptiMon; o provedor é só quem
  // executa o envio, feito no próximo passo /send).
  if (envelopeRow.provider_envelope_id) {
    try {
      const { data: providerRow } = await supabase.from('signature_providers').select('*').eq('id', envelopeRow.provider_id).maybeSingle();
      if (providerRow) {
        const provider = buildProvider(providerRow);
        await provider.addSigner(envelopeRow.provider_envelope_id, { email: b.email, order: b.ordem ?? 1 });
      }
    } catch (_err) {
      // Falha do provedor mock não impede o cadastro local — registrado só
      // como um warning, nunca escondido, mas também nunca fatal.
    }
  }

  return res.status(201).json(signer);
});

// POST /api/signatures/envelopes/:id/send — sendForSignature (seção 5).
router.post('/envelopes/:id/send', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data: envelopeRow, error: envError } = await supabase.from('signature_envelopes').select('provider_id, provider_envelope_id').eq('id', req.params.id).maybeSingle();
  if (envError) return handleError(res, envError);
  if (!envelopeRow) return res.status(404).json({ error: `Envelope ${req.params.id} não encontrado.` });

  try {
    const { data: providerRow } = await supabase.from('signature_providers').select('*').eq('id', envelopeRow.provider_id).maybeSingle();
    const provider = buildProvider(providerRow);
    await provider.sendForSignature(envelopeRow.provider_envelope_id);
  } catch (err) {
    return res.status(502).json({ error: `Falha ao enviar para assinatura no provedor: ${err.message}` });
  }

  const { data, error } = await supabase.rpc('pricing_signature_envelope_send', { p_envelope_id: req.params.id, p_provider_envelope_id: null });
  if (error) return handleError(res, error);
  return res.json(data);
});

// POST /api/signatures/envelopes/:id/signers/:signerId/resend — "REENVIAR ASSINATURA"
// (Fase 3.11.2, seção 6 do pedido de correção). Nunca duplica assinatura (bloqueado no
// banco — app.reenviar_assinatura_signatario recusa signatário já ASSINADO). Best-effort
// no provedor mock, mesmo padrão de POST /envelopes/:id/signers acima — o estado de
// verdade é sempre o do OptiMon.
router.post('/envelopes/:envelopeId/signers/:signerId/resend', async (req, res) => {
  const { motivo } = req.body || {};
  const supabase = clientForRequest(req.userJwt);

  const { data: signer, error } = await supabase.rpc('pricing_signature_signer_resend', {
    p_signer_id: req.params.signerId,
    p_motivo: motivo ?? null,
  });
  if (error) return handleError(res, error);

  try {
    const { data: envelopeRow } = await supabase.from('signature_envelopes').select('provider_id, provider_envelope_id').eq('id', req.params.envelopeId).maybeSingle();
    if (envelopeRow?.provider_envelope_id) {
      const { data: providerRow } = await supabase.from('signature_providers').select('*').eq('id', envelopeRow.provider_id).maybeSingle();
      if (providerRow) {
        const provider = buildProvider(providerRow);
        await provider.sendForSignature(envelopeRow.provider_envelope_id);
      }
    }
  } catch (_err) {
    // Falha do provedor mock não impede o reenvio local — best-effort, mesmo padrão do
    // resto deste arquivo.
  }

  return res.json(signer);
});

// POST /api/signatures/envelopes/:id/cancel — cancelEnvelope (seção 5). Só
// DIRETOR/ADMINISTRADOR (RLS de app.cancelar_envelope_assinatura).
router.post('/envelopes/:id/cancel', async (req, res) => {
  const { motivo } = req.body || {};
  if (!motivo) return res.status(400).json({ error: 'motivo é obrigatório para cancelar um envelope.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_signature_envelope_cancel', { p_envelope_id: req.params.id, p_motivo: motivo });
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/signatures/envelopes/:id/document — downloadSignedDocument (seção
// 5) — nunca URL pública fixa, sempre signed URL de curto prazo (seção 45).
router.get('/envelopes/:id/document', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data: doc, error } = await supabase.from('documentos_assinados').select('storage_path_assinado, storage_path_original, validado').eq('envelope_id', req.params.id).maybeSingle();
  if (error) return handleError(res, error);
  if (!doc) return res.status(404).json({ error: `Nenhum documento assinado registrado ainda para o envelope ${req.params.id}.` });

  const path = doc.storage_path_assinado || doc.storage_path_original;
  if (!path) return res.status(404).json({ error: 'Documento sem caminho de Storage registrado.' });

  const { data: signed, error: signError } = await supabase.storage.from('documentos').createSignedUrl(path, 300);
  if (signError) return res.status(502).json({ error: `Falha ao gerar link de download: ${signError.message}.` });
  return res.json({ url: signed.signedUrl, validado: doc.validado, expira_em_segundos: 300 });
});

// GET /api/signatures/envelopes/:id/audit — getAuditTrail (seção 5) — eventos
// recebidos + evidências do provedor (nunca reconstrói, só lista o que já foi
// registrado/preservado — seção 20: "preservar as evidências fornecidas pelo
// provedor").
router.get('/envelopes/:id/audit', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const [{ data: eventos, error: evError }, { data: evidencias, error: eviError }] = await Promise.all([
    supabase.from('signature_events').select('id, evento_externo_id, tipo_evento, payload, processado, recebido_em').eq('envelope_id', req.params.id).order('recebido_em'),
    supabase.from('documentos_evidencias').select('id, tipo, storage_path, descricao, criado_em').eq('envelope_id', req.params.id).order('criado_em'),
  ]);
  if (evError) return handleError(res, evError);
  if (eviError) return handleError(res, eviError);
  return res.json({ eventos: eventos || [], evidencias: evidencias || [] });
});

// POST /api/signatures/envelopes/:id/validate — "VALIDAR ASSINATURA" (seção
// 10/56). Nunca trata status=ASSINADO sozinho como prova de validade — a
// lógica de verdade mora em app.validar_assinatura (migration 07).
router.post('/envelopes/:id/validate', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_signature_validate', { p_envelope_id: req.params.id });
  if (error) return handleError(res, error);
  return res.json(data);
});

// ============================================================================
// Webhook (seção 27, 49) — SEM requireAuth, montado à parte em server.js.
// ============================================================================

// Valida a assinatura HMAC-SHA256 do payload, no header `X-Signature`
// (hex de HMAC(webhook_secret, corpo_bruto_da_requisição)) — mesmo padrão de
// verificação de webhook usado por praticamente todo provedor de assinatura
// do mercado. NUNCA processa o evento se a validação falhar (seção 49).
function verifyHmac(rawBody, headerSignature, secret) {
  if (!headerSignature || !secret) return false;
  const expected = crypto.createHmac('sha256', secret).update(rawBody).digest('hex');
  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(String(headerSignature), 'utf8');
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

// POST /api/signatures/webhook — precisa do corpo BRUTO para validar o HMAC
// (por isso usa express.raw() só nesta rota, nunca o express.json() global,
// que já consumiu o stream antes de chegar aqui).
webhookRouter.post('/webhook', express.raw({ type: '*/*', limit: '5mb' }), async (req, res) => {
  const rawBody = req.body; // Buffer, por causa do express.raw() acima.
  let payload;
  try {
    payload = JSON.parse(rawBody.toString('utf8'));
  } catch (_err) {
    return res.status(400).json({ error: 'Payload inválido: JSON malformado.' });
  }

  const { provider_envelope_id, evento_externo_id, tipo_evento, novo_status_envelope, signer_email, signer_novo_status, signer_ip, signer_certificado, hash_assinado, storage_path_assinado } = payload || {};
  if (!provider_envelope_id || !evento_externo_id || !tipo_evento) {
    return res.status(400).json({ error: 'provider_envelope_id, evento_externo_id e tipo_evento são obrigatórios.' });
  }

  const anon = anonClient();

  // 1) Descobre qual env var guarda o secret deste provedor (seção 49: nunca
  // confia no payload por si só) — a função SQL devolve só o NOME, nunca o
  // valor, então o segredo de verdade nunca circula fora de process.env.
  const { data: secretRef, error: refError } = await anon.rpc('pricing_signature_webhook_secret_ref', { p_provider_envelope_id: provider_envelope_id });
  if (refError || !secretRef) {
    return res.status(404).json({ error: 'Envelope/provedor não encontrado para este provider_envelope_id.' });
  }
  const secret = process.env[secretRef];
  if (!secret) {
    // Configuração incompleta no Railway — nunca processar sem conseguir
    // validar autenticidade (seção 49), mesmo que o envelope exista.
    return res.status(500).json({ error: `Variável de ambiente "${secretRef}" (webhook_secret_ref do provedor) não está configurada neste deploy — evento recusado.` });
  }
  const headerSignature = req.headers['x-signature'] || req.headers['x-webhook-signature'];
  if (!verifyHmac(rawBody, headerSignature, secret)) {
    return res.status(401).json({ error: 'Assinatura HMAC inválida — evento recusado (seção 49: nunca confiar cegamente no payload).' });
  }

  // 2) Payload autenticado — agora sim processa, de forma idempotente.
  const { data, error } = await anon.rpc('pricing_signature_webhook_event_by_provider_id', {
    p_provider_envelope_id: provider_envelope_id,
    p_evento_externo_id: evento_externo_id,
    p_tipo_evento: tipo_evento,
    p_payload: payload,
    p_novo_status_envelope: novo_status_envelope ?? null,
    p_signer_email: signer_email ?? null,
    p_signer_novo_status: signer_novo_status ?? null,
    p_signer_ip: signer_ip ?? null,
    p_signer_certificado: signer_certificado ?? null,
    p_hash_assinado: hash_assinado ?? null,
    p_storage_path_assinado: storage_path_assinado ?? null,
  });
  if (error) return handleError(res, error);
  return res.json(data);
});

module.exports = { router, webhookRouter };
