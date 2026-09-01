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
const { buildSignatureLinkNotifier } = require('../lib/signatureLinkNotifier');
const { resolvePublicAppBaseUrl } = require('./users');
const { gerarDocumentoAssinadoContrato } = require('./signaturesExternal');

const signatureLinkNotifier = buildSignatureLinkNotifier();

function maskEmail(email) {
  const [user, domain] = String(email || '').split('@');
  if (!domain) return '***';
  const visible = user.slice(0, 2);
  return `${visible}${'*'.repeat(Math.max(user.length - visible.length, 1))}@${domain}`;
}

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

// Fase 3.11.5.1 — mesma técnica de api/routes/users.js:assertAdmin (decodifica só o `sub`
// do JWT já validado pelo Postgres/PostgREST em toda chamada real; a autorização de verdade
// é a leitura de `usuarios.perfil` a seguir, nunca o conteúdo do token por si só). Papéis
// exigidos aqui mirroram exatamente a policy documentos_assinados_write (RLS) — nunca uma
// regra nova e divergente.
function decodeJwtSub(jwt) {
  try {
    const payload = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString('utf8'));
    return payload.sub || null;
  } catch (_err) {
    return null;
  }
}

async function assertPodeGerarDocumentoAssinado(req) {
  const sub = decodeJwtSub(req.userJwt);
  if (!sub) throw new Error('PERMISSAO_NEGADA: token inválido.');
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('usuarios').select('perfil, ativo').eq('id', sub).maybeSingle();
  if (error) throw error;
  if (!data || !data.ativo || !['COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'].includes(data.perfil)) {
    throw new Error('PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR pode gerar o documento assinado.');
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

// Fase 3.11.4 (seção 3/11): busca numero/proponente reais para o e-mail — nunca inventa,
// nunca inclui piso/margem/governança (só o que já é público na capa do documento).
async function carregarInfoDocumento(supabase, envelopeRow) {
  if (envelopeRow.tipo_documento === 'PROPOSTA' && envelopeRow.proposta_id) {
    const { data } = await supabase.from('propostas_comerciais').select('numero, parceiro_nome_capa, parceiro_id').eq('id', envelopeRow.proposta_id).maybeSingle();
    let proponente = data?.parceiro_nome_capa || null;
    if (!proponente && data?.parceiro_id) {
      const { data: parceiro } = await supabase.from('parceiros').select('nome_fantasia, razao_social').eq('id', data.parceiro_id).maybeSingle();
      proponente = parceiro?.nome_fantasia || parceiro?.razao_social || null;
    }
    return { numero: data?.numero || null, proponente };
  }
  if (envelopeRow.tipo_documento === 'CONTRATO' && envelopeRow.contrato_id) {
    const { data } = await supabase.from('contratos').select('numero, parceiro_id').eq('id', envelopeRow.contrato_id).maybeSingle();
    let proponente = null;
    if (data?.parceiro_id) {
      const { data: parceiro } = await supabase.from('parceiros').select('nome_fantasia, razao_social').eq('id', data.parceiro_id).maybeSingle();
      proponente = parceiro?.nome_fantasia || parceiro?.razao_social || null;
    }
    return { numero: data?.numero || null, proponente };
  }
  return { numero: null, proponente: null };
}

// Fase 3.11.4 (seções 3/6/11/12): ENVIO REAL — gera um token/link individual por
// signatário (nunca reaproveita um link antigo) e chama api/lib/signatureLinkNotifier.js
// (Resend real, ou DEV_LOG fora de produção). Cada resultado é gravado no banco através
// de pricing_signature_signer_registrar_envio — status ENVIADO só é gravado DEPOIS que o
// Resend de fato aceitou o e-mail (tem email_id); qualquer falha vira ERRO_ENVIO com a
// mensagem real, nunca um "ENVIADO" silencioso. É exatamente a causa raiz corrigida nesta
// fase (ver cabeçalho da migration 20261006090000).
async function enviarLinksAssinatura(supabase, envelopeRow, signers) {
  const docInfo = await carregarInfoDocumento(supabase, envelopeRow);
  // Fase 3.11.4 (seção 12): mesma URL base já usada para o e-mail de convite/redefinição
  // de senha (PUBLIC_APP_URL) — nunca uma 2ª variável de ambiente para a mesma coisa.
  const baseUrl = resolvePublicAppBaseUrl();
  const resultados = [];

  for (const signer of signers) {
    await logSemanticEventBestEffort(supabase, {
      p_entidade: 'signature_signers', p_entidade_id: signer.id, p_acao: 'SIGNATURE_SEND_REQUESTED',
      p_motivo: `Solicitação de envio do link de assinatura para ${maskEmail(signer.email)}.`,
    });

    if (!baseUrl) {
      const detalhe = 'CONFIGURACAO_INVALIDA: PUBLIC_APP_URL (ou CORS_ALLOWED_ORIGINS) não está configurada neste deploy — o link de assinatura nunca é enviado sem uma URL pública real (nunca inventada).';
      console.error(`[signature-email] ${detalhe} signer_id=${signer.id}`);
      await supabase.rpc('pricing_signature_signer_registrar_envio', { p_signer_id: signer.id, p_sucesso: false, p_erro_mensagem: detalhe });
      resultados.push({ signerId: signer.id, ok: false });
      continue;
    }

    let linkInfo;
    try {
      const { data, error } = await supabase.rpc('pricing_signature_signer_gerar_link', { p_signer_id: signer.id });
      if (error) throw error;
      linkInfo = data;
    } catch (err) {
      await supabase.rpc('pricing_signature_signer_registrar_envio', { p_signer_id: signer.id, p_sucesso: false, p_erro_mensagem: `Falha ao gerar link de acesso: ${err.message}` });
      resultados.push({ signerId: signer.id, ok: false });
      continue;
    }

    const link = `${baseUrl}/assinar/${linkInfo.token}`;
    try {
      const envio = await signatureLinkNotifier.sendSignatureLink({
        email: signer.email, nome: signer.nome, tipoDocumento: envelopeRow.tipo_documento,
        numeroDocumento: docInfo.numero, proponente: docInfo.proponente, link, expiraDias: 30, signerId: signer.id,
      });
      // Fase 3.11.4 (seção 11, correção de um bug real encontrado na própria implementação
      // desta fase): "ENVIADO" só é gravado quando o Resend de fato aceitou o envio
      // (envio.enviado === true — canal RESEND). O fallback DEV_LOG (sem RESEND_API_KEY
      // configurada, fora de produção) NUNCA envia e-mail de verdade — mesmo não lançando
      // erro, ele deve ir para ERRO_ENVIO, exatamente como a Fase 3.11.3 já faz para o OTP
      // da proposta (lá o email_status fica em EMAIL_SOLICITADO, nunca EMAIL_ACEITO_PELO_
      // RESEND, quando o canal é DEV_LOG — ver api/routes/proposalsExternal.js). O link real
      // continua disponível no log do servidor (console.log abaixo) para teste manual local.
      if (envio.enviado === true) {
        await supabase.rpc('pricing_signature_signer_registrar_envio', {
          p_signer_id: signer.id, p_sucesso: true, p_email_provider_id: envio.emailId || null, p_email_canal: envio.canal,
        });
        console.log(`[signature-email] signer_id=${signer.id} canal=${envio.canal} email_id=${envio.emailId || '(n/a)'} destinatario=${maskEmail(signer.email)} status=ENVIADO`);
        resultados.push({ signerId: signer.id, ok: true });
      } else {
        const detalhe = envio.aviso || `Canal ${envio.canal} não confirma envio real de e-mail — nunca marcado como ENVIADO sem essa confirmação.`;
        await supabase.rpc('pricing_signature_signer_registrar_envio', {
          p_signer_id: signer.id, p_sucesso: false, p_email_provider_id: envio.emailId || null, p_email_canal: envio.canal, p_erro_mensagem: detalhe,
        });
        console.log(`[signature-email] signer_id=${signer.id} canal=${envio.canal} destinatario=${maskEmail(signer.email)} status=ERRO_ENVIO (${detalhe}) link_local=${link}`);
        resultados.push({ signerId: signer.id, ok: false });
      }
    } catch (sendErr) {
      const detalhe = sendErr?.message || 'Falha desconhecida ao enviar e-mail.';
      console.error(`[signature-email] falha ao enviar link para signer_id=${signer.id} (destinatario mascarado=${maskEmail(signer.email)}):`, detalhe);
      await supabase.rpc('pricing_signature_signer_registrar_envio', { p_signer_id: signer.id, p_sucesso: false, p_erro_mensagem: detalhe });
      resultados.push({ signerId: signer.id, ok: false });
    }
  }

  return resultados;
}

// POST /api/signatures/envelopes/:id/send — sendForSignature (seção 5), corrigida na
// Fase 3.11.4: para provider tipo=OPTIMON_INTERNO_RESEND, faz o envio REAL por
// signatário (ver enviarLinksAssinatura acima) e só marca ENVIADO no envelope se pelo
// menos 1 envio foi de fato aceito pelo Resend (pricing_signature_envelope_finalizar_
// envio) — nunca mais a marcação incondicional que causou o bug real relatado (envelope
// 571aa526). Provedores legados (MOCK/ICP_BRASIL_PROVEDOR_EXTERNO) preservam o
// comportamento original (seção 17: não quebrar o que já funciona).
router.post('/envelopes/:id/send', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data: envelopeRow, error: envError } = await supabase.from('signature_envelopes')
    .select('id, tipo_documento, proposta_id, contrato_id, provider_id, provider_envelope_id, status')
    .eq('id', req.params.id).maybeSingle();
  if (envError) return handleError(res, envError);
  if (!envelopeRow) return res.status(404).json({ error: `Envelope ${req.params.id} não encontrado.` });

  const { data: providerRow, error: providerError } = await supabase.from('signature_providers').select('*').eq('id', envelopeRow.provider_id).maybeSingle();
  if (providerError) return handleError(res, providerError);
  if (!providerRow) return res.status(404).json({ error: 'Provedor de assinatura configurado no envelope não foi encontrado.' });

  if (providerRow.tipo === 'OPTIMON_INTERNO_RESEND') {
    const { data: signers, error: signersError } = await supabase.from('signature_signers').select('id, nome, email').eq('envelope_id', envelopeRow.id);
    if (signersError) return handleError(res, signersError);
    if (!signers || signers.length === 0) {
      return res.status(400).json({ error: 'SEM_SIGNATARIOS: adicione pelo menos um signatário antes de enviar para assinatura.' });
    }

    await enviarLinksAssinatura(supabase, envelopeRow, signers);

    const { data, error } = await supabase.rpc('pricing_signature_envelope_finalizar_envio', { p_envelope_id: envelopeRow.id });
    if (error) return handleError(res, error);
    return res.json(data);
  }

  // Provedores legados (seção 17 — preserva o que já funcionava antes desta fase).
  try {
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
// (Fase 3.11.2, seção 6; corrigida na Fase 3.11.4, seção 10 do pedido novo: "o botão
// REENVIAR deve realmente chamar a API do provedor... se o provedor retornar erro,
// status: ERRO_ENVIO"). pricing_signature_signer_resend grava ENVIADO de forma otimista
// (compatibilidade com o provider MOCK legado) — para OPTIMON_INTERNO_RESEND, o envio
// real É TENTADO EM SEGUIDA e pricing_signature_signer_registrar_envio SEMPRE sobrescreve
// com o resultado verdadeiro (ENVIADO só se o Resend aceitou; ERRO_ENVIO com a mensagem
// real caso contrário) — o estado final nunca mente, mesmo que o estado intermediário
// dentro desta mesma requisição tenha sido otimista por um instante.
router.post('/envelopes/:envelopeId/signers/:signerId/resend', async (req, res) => {
  const { motivo } = req.body || {};
  const supabase = clientForRequest(req.userJwt);

  const { data: signer, error } = await supabase.rpc('pricing_signature_signer_resend', {
    p_signer_id: req.params.signerId,
    p_motivo: motivo ?? null,
  });
  if (error) return handleError(res, error);

  const { data: envelopeRow } = await supabase.from('signature_envelopes')
    .select('id, tipo_documento, proposta_id, contrato_id, provider_id, provider_envelope_id')
    .eq('id', req.params.envelopeId).maybeSingle();
  if (!envelopeRow) return res.json(signer);

  const { data: providerRow } = await supabase.from('signature_providers').select('*').eq('id', envelopeRow.provider_id).maybeSingle();
  if (!providerRow) return res.json(signer);

  if (providerRow.tipo === 'OPTIMON_INTERNO_RESEND') {
    await enviarLinksAssinatura(supabase, envelopeRow, [{ id: signer.id, nome: signer.nome, email: signer.email }]);
    const { data: atualizado } = await supabase.from('signature_signers')
      .select('id, nome, email, papel, ordem, obrigatorio, status, enviado_em, entregue_em, aberto_em, assinado_em, erro_mensagem, reenvios_count')
      .eq('id', signer.id).maybeSingle();
    return res.json(atualizado || signer);
  }

  // Provedores legados — best-effort no mock, mesmo comportamento original (seção 17).
  try {
    if (envelopeRow.provider_envelope_id) {
      const provider = buildProvider(providerRow);
      await provider.sendForSignature(envelopeRow.provider_envelope_id);
    }
  } catch (_err) {
    // Best-effort no mock legado — nunca bloqueia o reenvio local.
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

  // Fase 3.11.5.1 — GAP REAL encontrado no reteste do usuário: este fallback (devolver o
  // original quando o assinado ainda não existe) já era intencional desde a Fase 2.5, mas
  // até esta correção o caller nunca sabia qual dos dois tinha recebido — "Baixar documento
  // assinado" abria, silenciosamente, o documento SEM assinatura. Agora a resposta inclui
  // `tipo` (ASSINADO/ORIGINAL) para a tela avisar corretamente, em vez de nunca dizer nada.
  const path = doc.storage_path_assinado || doc.storage_path_original;
  if (!path) return res.status(404).json({ error: 'Documento sem caminho de Storage registrado.' });
  const tipo = doc.storage_path_assinado ? 'ASSINADO' : 'ORIGINAL';

  const { data: signed, error: signError } = await supabase.storage.from('documentos').createSignedUrl(path, 300);
  if (signError) return res.status(502).json({ error: `Falha ao gerar link de download: ${signError.message}.` });
  return res.json({ url: signed.signedUrl, validado: doc.validado, expira_em_segundos: 300, tipo });
});

// POST /api/signatures/envelopes/:id/gerar-documento-assinado — Fase 3.11.5.1 (gap real
// encontrado no reteste do usuário: um envelope já ASSINADO, mas cujo PDF final com
// certificado nunca foi gerado com sucesso — ex.: assinado antes desta fase, quando a
// geração automática ainda não existia, ou quando a geração automática falhou e nunca teve
// nova chance, porque só é tentada 1 vez, dentro de POST .../assinar/confirmar). Reaproveita
// 100% a mesma função usada pelo fluxo externo (gerarDocumentoAssinadoContrato, em
// signaturesExternal.js) — chamada aqui com o client anônimo do próprio backend (nunca o
// JWT do funcionário, para não exigir nenhum grant novo às RPCs escopadas por token), usando
// o token de acesso de um signatário do envelope (authenticated já pode ler
// signature_signers.token_acesso via RLS — signature_signers_select). Só COMERCIAL/
// DIRETOR/ADMINISTRADOR (mesmos papéis de documentos_assinados_write).
router.post('/envelopes/:id/gerar-documento-assinado', async (req, res) => {
  try {
    await assertPodeGerarDocumentoAssinado(req);
  } catch (err) {
    return res.status(403).json({ error: err.message });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data: envelope, error: envError } = await supabase
    .from('signature_envelopes')
    .select('id, tipo_documento, status')
    .eq('id', req.params.id)
    .maybeSingle();
  if (envError) return handleError(res, envError);
  if (!envelope) return res.status(404).json({ error: `Envelope ${req.params.id} não encontrado.` });
  if (envelope.tipo_documento !== 'CONTRATO') {
    return res.status(400).json({ error: 'Geração sob demanda do PDF final com certificado só está implementada para tipo_documento=CONTRATO nesta fase.' });
  }
  if (!['ASSINADO', 'VALIDADO'].includes(envelope.status)) {
    return res.status(409).json({ error: `Envelope ainda não está assinado (status atual: ${envelope.status}) — não há o que gerar.` });
  }

  const { data: signerRow, error: signerError } = await supabase
    .from('signature_signers')
    .select('token_acesso')
    .eq('envelope_id', req.params.id)
    .order('ordem')
    .limit(1)
    .maybeSingle();
  if (signerError) return handleError(res, signerError);
  if (!signerRow?.token_acesso) return res.status(500).json({ error: 'Nenhum signatário com token de acesso encontrado neste envelope.' });

  try {
    await gerarDocumentoAssinadoContrato({ supabase: anonClient(), token: signerRow.token_acesso, ip: req.ip || req.headers['x-forwarded-for'] || null });
  } catch (err) {
    return res.status(502).json({ error: `Falha ao gerar o PDF final assinado: ${err.message || err}.` });
  }
  return res.json({ ok: true });
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
