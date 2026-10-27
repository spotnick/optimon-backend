// OptiMap — Fase 4: importação de postes de referência (arquivo do coletor por município).
//
// Montado DENTRO de routes/optimap.js (/api/optimap/importacoes), depois do middleware de
// perfil do OptiMap. Toda regra (perfil, estados, classificação, aprovação, reversão) vive no
// banco (app.gis_importacao_* via wrappers public.optimap_importacao_*), chamado com o JWT do
// próprio usuário — a API só lê o arquivo, confere a integridade e envia em lotes.
//
// Nada é gravado em gis_postes_referencia no upload: o arquivo vira PRÉVIA no staging e só é
// aplicado por POST /:id/aprovar (ADMINISTRADOR/DIRETOR).

const express = require('express');
const crypto = require('crypto');
const multer = require('multer');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

const PERFIS_IMPORTACAO = new Set(['ADMINISTRADOR', 'DIRETOR', 'ENGENHARIA']);
const PERFIS_ENVIAR = new Set(['ADMINISTRADOR', 'ENGENHARIA']);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CLASSIFICACOES = new Set(['NOVO', 'ATUALIZADO', 'SEM_ALTERACAO', 'INVALIDO', 'DUPLICADO', 'CONFLITO', 'AUSENTE']);
const LOTE = 2000;
const TAMANHO_MAX = 60 * 1024 * 1024; // ~200 mil postes; uma cidade grande tem dezenas de milhares
const POSTES_MAX = 200000;

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: TAMANHO_MAX, files: 1 } });

const JWT_ERRO_RE = /PGRST30\d|JWT expired|JWSError|invalid token|token is expired/i;
function statusPara(message = '', code = '') {
  if (JWT_ERRO_RE.test(`${code} ${message}`)) return 401;
  if (/OPTIMAP_SEM_PERMISSAO|permission denied/i.test(message)) return 403;
  if (/OPTIMAP_NAO_ENCONTRADO/.test(message)) return 404;
  if (/OPTIMAP_(PREVIA_DESATUALIZADA|IMPORTACAO_EM_ABERTO)/.test(message)) return 409;
  if (/OPTIMAP_[A-Z_]+/.test(message)) return 400;
  if (/statement timeout|canceling statement/i.test(message)) return 504;
  return 500;
}
function erro(res, error) {
  const message = error?.message || 'Erro inesperado.';
  const status = statusPara(message, error?.code);
  const publica = {
    401: 'Sessão inválida ou expirada. Entre novamente.',
    403: 'Sem permissão para esta ação.',
    500: 'Erro ao processar a importação.',
    504: 'A operação demorou demais no banco de dados. Nada foi aplicado; tente novamente.',
  }[status];
  // Só mensagens de domínio (OPTIMAP_*) chegam ao cliente; erros internos nunca vazam.
  return res.status(status).json({ error: publica && !/OPTIMAP_/.test(message) ? publica : message.replace(/^.*?(OPTIMAP_)/s, '$1') });
}

router.use((req, res, next) => {
  if (!PERFIS_IMPORTACAO.has(req.optimapRole)) {
    return res.status(403).json({ error: 'Seu perfil não tem acesso às importações do OptiMap.' });
  }
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

// ---------------------------------------------------------------------------
// Leitura do arquivo: GeoJSON do coletor (formato optimap-referencia-postes/1).
// ---------------------------------------------------------------------------
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
  if (!meta || typeof meta !== 'object' || meta.formato !== 'optimap-referencia-postes/1') {
    throw Object.assign(new Error('Arquivo sem o cabeçalho do coletor do OptiMap (gere com tools/optimap/coletar_copel.mjs).'), { status: 400 });
  }
  if (doc.features.length === 0) throw Object.assign(new Error('O arquivo não tem postes.'), { status: 400 });
  if (doc.features.length > POSTES_MAX) throw Object.assign(new Error(`Arquivo com mais de ${POSTES_MAX} postes — importe um município por vez.`), { status: 400 });
  // Integridade: o coletor grava o SHA-256 da lista de postes. Arquivo editado depois da
  // coleta não confere e é recusado (dado externo não pode ser alterado à mão).
  const hashFeatures = crypto.createHash('sha256').update(JSON.stringify(doc.features)).digest('hex');
  if (typeof meta.sha256_features !== 'string' || meta.sha256_features !== hashFeatures) {
    throw Object.assign(new Error('O conteúdo do arquivo não confere com o hash gravado pelo coletor (arquivo alterado após a coleta?). Gere o arquivo novamente.'), { status: 400 });
  }
  const itens = doc.features.map((f, linha) => {
    const p = f && typeof f.properties === 'object' && f.properties ? f.properties : {};
    const g = f && f.geometry;
    const ponto = g && g.type === 'Point' && Array.isArray(g.coordinates) ? g.coordinates : [];
    const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
    return {
      linha,
      id_externo: p.num_seq_geo == null ? null : String(p.num_seq_geo),
      lon: num(ponto[0]),
      lat: num(ponto[1]),
      situacao: typeof p.situacao === 'string' ? p.situacao : null,
      atributos: p,
    };
  });
  // O limite municipal (URL) e as contagens do coletor ficam nos metadados; nada mais do arquivo.
  return { meta, itens };
}

// ---------------------------------------------------------------------------
// POST /api/optimap/importacoes  (multipart: arquivo, observacoes?)
// Recebe → carrega em lotes → calcula a prévia. Responde com o id e o resumo.
// ---------------------------------------------------------------------------
router.post('/', (req, res, next) => {
  if (!PERFIS_ENVIAR.has(req.optimapRole)) return res.status(403).json({ error: 'Apenas ENGENHARIA ou ADMINISTRADOR enviam arquivos.' });
  return upload.single('arquivo')(req, res, (e) => {
    if (e) {
      const msg = e.code === 'LIMIT_FILE_SIZE' ? `Arquivo maior que ${TAMANHO_MAX / 1024 / 1024} MB.` : 'Falha ao receber o arquivo.';
      return res.status(400).json({ error: msg });
    }
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
  const hashArquivo = crypto.createHash('sha256').update(req.file.buffer).digest('hex');
  const supabase = clientForRequest(req.userJwt);

  const { data: id, error } = await supabase.rpc('optimap_importacao_iniciar', {
    p_metadados: lido.meta,
    p_arquivo_nome: (req.file.originalname || 'arquivo.geojson').slice(0, 255),
    p_arquivo_hash: hashArquivo,
    p_arquivo_tamanho: req.file.size,
    p_observacoes: observacoes,
  });
  if (error) return erro(res, error);

  try {
    for (let i = 0; i < lido.itens.length; i += LOTE) {
      const { error: e } = await supabase.rpc('optimap_importacao_adicionar_itens', {
        p_importacao_id: id, p_itens: lido.itens.slice(i, i + LOTE),
      });
      if (e) throw e;
    }
    const { data: resumo, error: e2 } = await supabase.rpc('optimap_importacao_processar', { p_importacao_id: id });
    if (e2) throw e2;
    return res.status(201).json({ id, resumo });
  } catch (e) {
    // Carga interrompida: descarta a importação incompleta (fica no histórico como DESCARTADA)
    // para não travar o município com uma importação aberta pela metade.
    await supabase.rpc('optimap_importacao_descartar', { p_importacao_id: id, p_motivo: 'Falha durante o envio do arquivo.' });
    return erro(res, e);
  }
});

// GET /api/optimap/importacoes?limite=&offset=
router.get('/', async (req, res) => {
  const limite = inteiro(req.query.limite, 50, 1, 200);
  const offset = inteiro(req.query.offset, 0, 0, 1000000);
  if (limite === null || offset === null) return res.status(400).json({ error: 'Paginação inválida.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_importacao_listar', { p_limite: limite, p_offset: offset });
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

// GET /api/optimap/importacoes/:id
router.get('/:id', idValido, async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_importacao_detalhe', { p_importacao_id: req.params.id });
  if (error) return erro(res, error);
  if (!data) return res.status(404).json({ error: 'Importação não encontrada.' });
  const ids = [data.criado_por, data.aprovado_por, data.rejeitado_por, data.descartado_por, data.revertido_por].filter(Boolean);
  const { data: us } = await supabase.from('usuarios').select('id, nome').in('id', [...new Set(ids)]);
  return res.json({ ...data, usuarios: Object.fromEntries((us || []).map((u) => [u.id, u.nome])), papel: req.optimapRole });
});

// GET /api/optimap/importacoes/:id/itens?classificacao=&busca=&limite=&offset=
router.get('/:id/itens', idValido, async (req, res) => {
  const { classificacao, busca } = req.query;
  if (classificacao !== undefined && (typeof classificacao !== 'string' || !CLASSIFICACOES.has(classificacao))) {
    return res.status(400).json({ error: 'Classificação inválida.' });
  }
  if (busca !== undefined && (typeof busca !== 'string' || busca.length > 64)) return res.status(400).json({ error: 'Busca inválida.' });
  const limite = inteiro(req.query.limite, 100, 1, 1000);
  const offset = inteiro(req.query.offset, 0, 0, 1000000);
  if (limite === null || offset === null) return res.status(400).json({ error: 'Paginação inválida.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_importacao_itens', {
    p_importacao_id: req.params.id, p_classificacao: classificacao || null, p_busca: busca || null, p_limite: limite, p_offset: offset,
  });
  if (error) return erro(res, error);
  return res.json(data || { total: 0, itens: [] });
});

// GET /api/optimap/importacoes/:id/previa.geojson?classificacoes=NOVO,CONFLITO
router.get('/:id/previa.geojson', idValido, async (req, res) => {
  let classes = null;
  if (req.query.classificacoes !== undefined) {
    if (typeof req.query.classificacoes !== 'string') return res.status(400).json({ error: 'Classificações inválidas.' });
    classes = req.query.classificacoes.split(',').filter(Boolean);
    if (classes.length === 0 || classes.some((c) => !CLASSIFICACOES.has(c))) return res.status(400).json({ error: 'Classificações inválidas.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_importacao_previa_geojson', {
    p_importacao_id: req.params.id, p_classificacoes: classes, p_limite: 50000,
  });
  if (error) return erro(res, error);
  res.set('Content-Type', 'application/geo+json');
  return res.send(JSON.stringify(data || { type: 'FeatureCollection', features: [] }));
});

// POST /api/optimap/importacoes/:id/decisoes  { item_ids: [..], decisao: 'APLICAR'|'IGNORAR'|null }
router.post('/:id/decisoes', idValido, async (req, res) => {
  const { item_ids: itemIds, decisao } = req.body || {};
  if (!Array.isArray(itemIds) || itemIds.length === 0 || itemIds.length > 5000 || !itemIds.every((x) => Number.isSafeInteger(x) && x > 0)) {
    return res.status(400).json({ error: 'Informe item_ids (lista de inteiros).' });
  }
  if (decisao !== null && decisao !== 'APLICAR' && decisao !== 'IGNORAR') return res.status(400).json({ error: 'Decisão inválida.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_importacao_decidir', { p_importacao_id: req.params.id, p_item_ids: itemIds, p_decisao: decisao });
  if (error) return erro(res, error);
  return res.json(data);
});

// POST /api/optimap/importacoes/:id/reprocessar
router.post('/:id/reprocessar', idValido, async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_importacao_processar', { p_importacao_id: req.params.id });
  if (error) return erro(res, error);
  return res.json({ resumo: data });
});

// POST /api/optimap/importacoes/:id/aprovar  { confirmar_ausencias?: bool, observacao?: string }
router.post('/:id/aprovar', idValido, async (req, res) => {
  const { confirmar_ausencias: confirmar = false, observacao = null } = req.body || {};
  if (typeof confirmar !== 'boolean' || (observacao !== null && typeof observacao !== 'string')) return res.status(400).json({ error: 'Parâmetros inválidos.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_importacao_aprovar', {
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
router.post('/:id/rejeitar', idValido, comMotivo('optimap_importacao_rejeitar', true));
router.post('/:id/descartar', idValido, comMotivo('optimap_importacao_descartar', false));
router.post('/:id/reverter', idValido, comMotivo('optimap_importacao_reverter', true));

module.exports = router;
module.exports._lerArquivo = lerArquivo; // testes
