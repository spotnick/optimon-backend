// OptiMap — Fase 5: lista de postes com PROJETO APROVADO no CES (Copel), por empresa.
//
// Montado DENTRO de routes/optimap.js (/api/optimap/ces). Mesmo desenho da Fase 4: a API só lê
// o arquivo gerado pela coleta no CES (formato optimap-ocupacoes-ces/1), confere a integridade
// e envia em lotes; perfis, estados, classificação, aprovação e reversão vivem no banco
// (app.gis_ces_* via wrappers public.optimap_ces_*), chamados com o JWT do próprio usuário.
// Nada vira ocupação no upload: o arquivo vira PRÉVIA e só é aplicado por /:id/aprovar.

const express = require('express');
const crypto = require('crypto');
const multer = require('multer');
const { clientForRequest } = require('../lib/supabaseClient');
const { _erro: erro } = require('./optimapImportacoes');

const router = express.Router();

const PERFIS_CES = new Set(['ADMINISTRADOR', 'DIRETOR', 'ENGENHARIA']);
const PERFIS_ENVIAR = new Set(['ADMINISTRADOR', 'ENGENHARIA']);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CLASSIFICACOES = new Set(['NOVA', 'MANTIDA', 'REATIVADA', 'INVALIDO', 'DUPLICADO', 'AUSENTE']);
const LOTE = 2000;
const TAMANHO_MAX = 20 * 1024 * 1024;
const POSTES_MAX = 100000;

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: TAMANHO_MAX, files: 1 } });

router.use((req, res, next) => {
  if (!PERFIS_CES.has(req.optimapRole)) return res.status(403).json({ error: 'Seu perfil não tem acesso às listas do CES.' });
  res.set('Cache-Control', 'no-store');
  return next();
});

const idValido = (req, res, next) => (UUID_RE.test(req.params.id) ? next() : res.status(400).json({ error: 'id inválido.' }));
const inteiro = (v, padrao, min, max) => {
  if (v === undefined) return padrao;
  if (typeof v !== 'string' || !/^\d{1,7}$/.test(v)) return null;
  const n = Number(v);
  return n < min || n > max ? null : n;
};

function lerArquivo(buffer) {
  let doc;
  try {
    doc = JSON.parse(buffer.toString('utf8'));
  } catch {
    throw Object.assign(new Error('O arquivo não é um JSON válido.'), { status: 400 });
  }
  if (!doc || doc.type !== 'FeatureCollection' || !Array.isArray(doc.features)) {
    throw Object.assign(new Error('O arquivo não é um GeoJSON FeatureCollection.'), { status: 400 });
  }
  const meta = doc.optimap;
  if (!meta || typeof meta !== 'object' || meta.formato !== 'optimap-ocupacoes-ces/1') {
    throw Object.assign(new Error('Arquivo sem o cabeçalho de lista do CES (formato optimap-ocupacoes-ces/1).'), { status: 400 });
  }
  if (doc.features.length === 0) throw Object.assign(new Error('A lista não tem postes.'), { status: 400 });
  if (doc.features.length > POSTES_MAX) throw Object.assign(new Error(`Lista com mais de ${POSTES_MAX} postes.`), { status: 400 });
  const hashFeatures = crypto.createHash('sha256').update(JSON.stringify(doc.features)).digest('hex');
  if (typeof meta.sha256_features !== 'string' || meta.sha256_features !== hashFeatures) {
    throw Object.assign(new Error('O conteúdo do arquivo não confere com o hash gravado na coleta (arquivo alterado depois?). Gere a lista novamente.'), { status: 400 });
  }
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const itens = doc.features.map((f, linha) => {
    const p = f && typeof f.properties === 'object' && f.properties ? f.properties : {};
    const g = f && f.geometry;
    const ponto = g && g.type === 'Point' && Array.isArray(g.coordinates) ? g.coordinates : [];
    return { linha, id_externo: p.num_seq_geo == null ? null : String(p.num_seq_geo), lon: num(ponto[0]), lat: num(ponto[1]) };
  });
  return { meta, itens };
}

// POST /api/optimap/ces  (multipart: arquivo, observacoes?)
router.post('/', (req, res, next) => {
  if (!PERFIS_ENVIAR.has(req.optimapRole)) return res.status(403).json({ error: 'Apenas ENGENHARIA ou ADMINISTRADOR enviam listas do CES.' });
  return upload.single('arquivo')(req, res, (e) => {
    if (e) return res.status(400).json({ error: e.code === 'LIMIT_FILE_SIZE' ? `Arquivo maior que ${TAMANHO_MAX / 1024 / 1024} MB.` : 'Falha ao receber o arquivo.' });
    return next();
  });
}, async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'Envie o arquivo .geojson no campo "arquivo".' });
  let lido;
  try {
    lido = lerArquivo(req.file.buffer);
  } catch (e) {
    return res.status(e.status || 400).json({ error: e.message });
  }
  const observacoes = typeof req.body?.observacoes === 'string' ? req.body.observacoes.slice(0, 1000) : null;
  const supabase = clientForRequest(req.userJwt);
  const { data: id, error } = await supabase.rpc('optimap_ces_iniciar', {
    p_metadados: lido.meta,
    p_arquivo_nome: (req.file.originalname || 'ces.geojson').slice(0, 255),
    p_arquivo_hash: crypto.createHash('sha256').update(req.file.buffer).digest('hex'),
    p_arquivo_tamanho: req.file.size,
    p_observacoes: observacoes,
  });
  if (error) return erro(res, error);
  try {
    for (let i = 0; i < lido.itens.length; i += LOTE) {
      const { error: e } = await supabase.rpc('optimap_ces_adicionar_itens', { p_importacao_id: id, p_itens: lido.itens.slice(i, i + LOTE) });
      if (e) throw e;
    }
    const { data: resumo, error: e2 } = await supabase.rpc('optimap_ces_processar', { p_importacao_id: id });
    if (e2) throw e2;
    return res.status(201).json({ id, resumo });
  } catch (e) {
    await supabase.rpc('optimap_ces_descartar', { p_importacao_id: id, p_motivo: 'Falha durante o envio do arquivo.' });
    return erro(res, e);
  }
});

router.get('/', async (req, res) => {
  const limite = inteiro(req.query.limite, 50, 1, 200);
  const offset = inteiro(req.query.offset, 0, 0, 1000000);
  if (limite === null || offset === null) return res.status(400).json({ error: 'Paginação inválida.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_ces_listar', { p_limite: limite, p_offset: offset });
  if (error) return erro(res, error);
  const lista = Array.isArray(data) ? data : [];
  const ids = [...new Set(lista.map((i) => i.criado_por).filter(Boolean))];
  let nomes = {};
  if (ids.length) {
    const { data: us } = await supabase.from('usuarios').select('id, nome').in('id', ids);
    nomes = Object.fromEntries((us || []).map((u) => [u.id, u.nome]));
  }
  return res.json(lista.map((i) => ({ ...i, criado_por_nome: nomes[i.criado_por] || null })));
});

router.get('/:id', idValido, async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_ces_detalhe', { p_importacao_id: req.params.id });
  if (error) return erro(res, error);
  if (!data) return res.status(404).json({ error: 'Lista não encontrada.' });
  const ids = [data.criado_por, data.aprovado_por, data.rejeitado_por, data.descartado_por, data.revertido_por].filter(Boolean);
  const { data: us } = await supabase.from('usuarios').select('id, nome').in('id', [...new Set(ids)]);
  return res.json({ ...data, usuarios: Object.fromEntries((us || []).map((u) => [u.id, u.nome])), papel: req.optimapRole });
});

router.get('/:id/itens', idValido, async (req, res) => {
  const { classificacao, busca } = req.query;
  if (classificacao !== undefined && (typeof classificacao !== 'string' || !CLASSIFICACOES.has(classificacao))) return res.status(400).json({ error: 'Classificação inválida.' });
  if (busca !== undefined && (typeof busca !== 'string' || busca.length > 64)) return res.status(400).json({ error: 'Busca inválida.' });
  const limite = inteiro(req.query.limite, 100, 1, 1000);
  const offset = inteiro(req.query.offset, 0, 0, 1000000);
  if (limite === null || offset === null) return res.status(400).json({ error: 'Paginação inválida.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_ces_itens', {
    p_importacao_id: req.params.id, p_classificacao: classificacao || null, p_busca: busca || null, p_limite: limite, p_offset: offset,
  });
  if (error) return erro(res, error);
  return res.json(data || { total: 0, itens: [] });
});

router.get('/:id/previa.geojson', idValido, async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_ces_previa_geojson', { p_importacao_id: req.params.id });
  if (error) return erro(res, error);
  res.set('Content-Type', 'application/geo+json');
  return res.send(JSON.stringify(data || { type: 'FeatureCollection', features: [] }));
});

router.post('/:id/reprocessar', idValido, async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_ces_processar', { p_importacao_id: req.params.id });
  if (error) return erro(res, error);
  return res.json({ resumo: data });
});

router.post('/:id/aprovar', idValido, async (req, res) => {
  const { confirmar_ausencias: confirmar = false, observacao = null } = req.body || {};
  if (typeof confirmar !== 'boolean' || (observacao !== null && typeof observacao !== 'string')) return res.status(400).json({ error: 'Parâmetros inválidos.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_ces_aprovar', {
    p_importacao_id: req.params.id, p_confirmar_ausencias: confirmar, p_observacao: observacao ? observacao.slice(0, 1000) : null,
  });
  if (error) return erro(res, error);
  return res.json(data);
});

const comMotivo = (rpc, obrigatorio) => async (req, res) => {
  const motivo = req.body?.motivo;
  if (motivo !== undefined && motivo !== null && typeof motivo !== 'string') return res.status(400).json({ error: 'Motivo inválido.' });
  if (obrigatorio && (!motivo || motivo.trim().length < 3)) return res.status(400).json({ error: 'Informe o motivo.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc(rpc, { p_importacao_id: req.params.id, p_motivo: motivo ? motivo.slice(0, 1000) : null });
  if (error) return erro(res, error);
  return res.json(data ?? { ok: true });
};
router.post('/:id/rejeitar', idValido, comMotivo('optimap_ces_rejeitar', true));
router.post('/:id/descartar', idValido, comMotivo('optimap_ces_descartar', false));
router.post('/:id/reverter', idValido, comMotivo('optimap_ces_reverter', true));

module.exports = router;
module.exports._lerArquivo = lerArquivo;
