// OptiMon API — OptiMap (Fase 3: mapa interativo inicial).
//
// Camada fina sobre as funções SQL da Fase 2 do OptiMap (supabase/migrations/20261021*):
//   public.optimap_tile / optimap_buscar / optimap_detalhe  (+ views vw_gis_*)
// Mesmo padrão de todas as rotas do OptiMon: cliente Supabase por requisição com a ANON_KEY
// + o JWT do próprio usuário (lib/supabaseClient.js) — RLS e as regras de perfil do banco
// (app.gis_pode_ver) continuam valendo em TODA chamada. Nenhuma chave privilegiada.
//
// Defesa em profundidade: além do banco, esta rota recusa com 403 quem não tem perfil de
// visualização do mapa (FINANCEIRO / usuário sem perfil). A lista abaixo espelha
// app.gis_pode_ver() — se divergir, o banco continua sendo a barreira real (devolve vazio).
//
// As escritas (Fases 4 e 5) ficam nos sub-roteadores montados no fim, sempre via funções SQL.

const express = require('express');
const crypto = require('crypto');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

const PERFIS_VER = new Set(['ADMINISTRADOR', 'DIRETOR', 'ENGENHARIA', 'COMERCIAL', 'AUDITOR']);
const PERFIS_EDITAR = new Set(['ADMINISTRADOR', 'ENGENHARIA']);
const CAMADAS_TILE = new Set(['pops', 'postes', 'postes_referencia', 'elementos', 'trechos']);
const CAMADAS_DETALHE = new Set(['pops', 'postes', 'postes_referencia', 'elementos', 'trechos']);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ---------------------------------------------------------------------------
// Perfil do usuário — cache curto em memória por token (evita 1 ida ao banco a cada tile).
// Chave = hash do JWT (o token em si nunca é guardado). Expira em 60 s; o banco continua
// aplicando a regra em todas as consultas, então o cache só afeta a mensagem 403.
// ---------------------------------------------------------------------------
const roleCache = new Map();
const ROLE_TTL_MS = 60 * 1000;

const JWT_ERRO_RE = /PGRST30\d|JWT expired|JWSError|JWT|invalid token|token is expired/i;

// exp (segundos) do payload do JWT — só para LIMITAR a vida da entrada de cache. O token em
// si é validado pelo PostgREST/Supabase na consulta de perfil; aqui nada é confiado a ele.
function expDoJwt(token) {
  try {
    const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
    return typeof payload.exp === 'number' ? payload.exp * 1000 : null;
  } catch {
    return null;
  }
}

function limparExpirados() {
  const agora = Date.now();
  for (const [k, v] of roleCache) if (v.expira <= agora) roleCache.delete(k);
  if (roleCache.size > 5000) roleCache.clear();
}

async function perfilDoUsuario(req) {
  const key = crypto.createHash('sha256').update(req.userJwt).digest('hex');
  const hit = roleCache.get(key);
  if (hit && hit.expira > Date.now()) return hit.promessa;
  const exp = expDoJwt(req.userJwt);
  if (exp !== null && exp <= Date.now()) {
    throw Object.assign(new Error('Sessão expirada.'), { status: 401 });
  }
  // Uma única consulta por token mesmo com dezenas de tiles pedidos ao mesmo tempo.
  const promessa = (async () => {
    const supabase = clientForRequest(req.userJwt);
    const { data, error } = await supabase.rpc('pricing_current_user_role');
    if (error) {
      const status = JWT_ERRO_RE.test(`${error.code || ''} ${error.message || ''}`) ? 401 : 503;
      throw Object.assign(new Error(status === 401 ? 'Sessão inválida ou expirada.' : 'Serviço de dados indisponível.'), { status });
    }
    return data || null;
  })();
  roleCache.set(key, { promessa, expira: Math.min(Date.now() + ROLE_TTL_MS, exp ?? Infinity) });
  promessa.catch(() => roleCache.delete(key)); // erro nunca fica em cache
  limparExpirados();
  return promessa;
}

router.use(async (req, res, next) => {
  try {
    const role = await perfilDoUsuario(req);
    if (!PERFIS_VER.has(role)) {
      return res.status(403).json({ error: 'Seu perfil não tem acesso ao OptiMap.', role: role || null });
    }
    req.optimapRole = role;
    return next();
  } catch (e) {
    const status = e.status || 503;
    return res.status(status).json({ error: status === 401 ? 'Sessão inválida ou expirada. Entre novamente.' : 'Não foi possível verificar o perfil do usuário.' });
  }
});

function statusPara(message = '', code = '') {
  if (JWT_ERRO_RE.test(`${code} ${message}`)) return 401;
  if (/OPTIMAP_SEM_PERMISSAO|permission denied/i.test(message)) return 403;
  if (/OPTIMAP_NAO_ENCONTRADO/.test(message)) return 404;
  if (/OPTIMAP_[A-Z_]+/.test(message)) return 400;
  return 500;
}
function erro(res, error) {
  const message = error?.message || 'Erro inesperado.';
  const status = statusPara(message, error?.code);
  // Só mensagens de domínio (OPTIMAP_*) chegam ao cliente; erros internos/do Postgres
  // (nomes de tabela/função) nunca vazam.
  const publica = {
    401: 'Sessão inválida ou expirada. Entre novamente.',
    403: 'Sem permissão para esta consulta.',
    500: 'Erro ao consultar o OptiMap.',
  }[status];
  return res.status(status).json({ error: publica && !/^OPTIMAP_/.test(message) ? publica : message });
}

// Parâmetros de query vindos repetidos (?a=1&a=2 / ?a[]=x) chegam como array — recusados.
const textoUnico = (v) => (typeof v === 'string' ? v : undefined);

// ---------------------------------------------------------------------------
// GET /api/optimap/sessao — o que a interface pode mostrar para este perfil.
// ---------------------------------------------------------------------------
router.get('/sessao', (req, res) => {
  const r = req.optimapRole;
  res.json({
    role: r, pode_ver: true, pode_editar: PERFIS_EDITAR.has(r),
    // Fase 4 — importação de postes de referência (a regra efetiva continua no banco).
    pode_ver_importacoes: ['ADMINISTRADOR', 'DIRETOR', 'ENGENHARIA'].includes(r),
    pode_importar: ['ADMINISTRADOR', 'ENGENHARIA'].includes(r),
    pode_aprovar_importacao: ['ADMINISTRADOR', 'DIRETOR'].includes(r),
    pode_reverter_importacao: r === 'ADMINISTRADOR',
    // Fase 5 — empresas, ocupações e listas do CES.
    pode_marcar_ocupacao: PERFIS_EDITAR.has(r),
    pode_gerir_empresas: r === 'ADMINISTRADOR',
  });
});

// ---------------------------------------------------------------------------
// GET /api/optimap/resumo[?cidade_id=] — contagem confiável por camada (consultas
// "head + count exact" sob RLS; nenhuma linha é transferida).
// ---------------------------------------------------------------------------
router.get('/resumo', async (req, res) => {
  const cidade_id = req.query.cidade_id;
  if (cidade_id !== undefined && (typeof cidade_id !== 'string' || !UUID_RE.test(cidade_id))) return res.status(400).json({ error: 'cidade_id inválido.' });
  const supabase = clientForRequest(req.userJwt);
  const contar = async (tabela, { ativos = false } = {}) => {
    let q = supabase.from(tabela).select('id', { count: 'exact', head: true });
    if (ativos) q = q.is('removido_em', null);
    if (cidade_id) q = q.eq('cidade_id', cidade_id);
    const { count, error } = await q;
    if (error) throw error;
    return count ?? 0;
  };
  try {
    const [pops, postes, postes_referencia, elementos, trechos] = await Promise.all([
      contar('vw_gis_pops'),
      contar('gis_postes', { ativos: true }),
      contar('gis_postes_referencia'),
      contar('gis_elementos', { ativos: true }),
      contar('gis_trechos', { ativos: true }),
    ]);
    let pendQ = supabase.from('vw_gis_documentacao_incompleta').select('id', { count: 'exact', head: true }).eq('entidade', 'infra_pops');
    if (cidade_id) pendQ = pendQ.eq('cidade_id', cidade_id);
    const { count: pops_sem_coordenada, error: e2 } = await pendQ;
    if (e2) throw e2;
    return res.json({ camadas: { pops, postes, postes_referencia, elementos, trechos }, pops_sem_coordenada: pops_sem_coordenada ?? 0 });
  } catch (e) {
    return erro(res, e);
  }
});

// ---------------------------------------------------------------------------
// GET /api/optimap/tiles/:camada/:z/:x/:y.mvt — vector tile (MVT) para o MapLibre.
// public.optimap_tile devolve bytea; via PostgREST/JSON ele chega como string "\x<hex>".
// Tile vazio → 204 (o MapLibre trata como tile sem feições). Cache só PRIVADO e curto:
// dado interno nunca vai para cache compartilhado (CDN/proxy).
// ---------------------------------------------------------------------------
router.get('/tiles/:camada/:z/:x/:y.mvt', async (req, res) => {
  const { camada } = req.params;
  if (!CAMADAS_TILE.has(camada)) return res.status(400).json({ error: 'Camada inválida.' });
  if (!/^\d{1,2}$/.test(req.params.z) || !/^\d{1,7}$/.test(req.params.x) || !/^\d{1,7}$/.test(req.params.y)) {
    return res.status(400).json({ error: 'Tile inválido.' });
  }
  const z = Number(req.params.z);
  const x = Number(req.params.x);
  const y = Number(req.params.y);
  if (z > 22 || x >= 2 ** z || y >= 2 ** z) return res.status(400).json({ error: 'Tile inválido.' });
  const cidade_id = req.query.cidade_id;
  if (cidade_id !== undefined && (typeof cidade_id !== 'string' || !UUID_RE.test(cidade_id))) return res.status(400).json({ error: 'cidade_id inválido.' });

  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_tile', {
    p_camada: camada, p_z: z, p_x: x, p_y: y, p_cidade_id: cidade_id || null,
  });
  if (error) return erro(res, error);

  res.set('Cache-Control', 'private, max-age=30');
  res.vary('Authorization'); // acrescenta (não apaga o Vary: Origin do CORS)
  const hex = typeof data === 'string' ? data.replace(/^\\x/, '') : '';
  if (!hex) return res.status(204).end();
  res.set('Content-Type', 'application/vnd.mapbox-vector-tile');
  return res.send(Buffer.from(hex, 'hex'));
});

// ---------------------------------------------------------------------------
// GET /api/optimap/buscar?q= — cidade, POP, poste (NICK), número externo, elemento,
// "lat, lon". Usa public.optimap_buscar (escape de %/_ e regra de perfil no banco).
// ---------------------------------------------------------------------------
router.get('/buscar', async (req, res) => {
  if (req.query.q !== undefined && textoUnico(req.query.q) === undefined) return res.status(400).json({ error: 'Parâmetro q inválido.' });
  const q = (textoUnico(req.query.q) || '').trim();
  if (q.length < 2) return res.json([]);
  if (q.length > 120) return res.status(400).json({ error: 'Texto de busca muito longo.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_buscar', { p_texto: q, p_limite: 20 });
  if (error) return erro(res, error);
  return res.json(Array.isArray(data) ? data : []);
});

// ---------------------------------------------------------------------------
// GET /api/optimap/cidades/:id/extensao — enquadramento da cidade no mapa, calculado SÓ a
// partir de coordenadas realmente cadastradas (POPs com lat/long). Sem coordenadas →
// bbox null (a interface avisa; nunca inventa uma posição para a cidade).
// ---------------------------------------------------------------------------
router.get('/cidades/:id/extensao', async (req, res) => {
  if (!UUID_RE.test(req.params.id)) return res.status(400).json({ error: 'id inválido.' });
  const supabase = clientForRequest(req.userJwt);
  const { data: pops, error } = await supabase.from('vw_gis_pops').select('id').eq('cidade_id', req.params.id);
  if (error) return erro(res, error);
  if (!pops || pops.length === 0) return res.json({ bbox: null, base: 'POPs com coordenadas', quantidade: 0 });
  const { data: coords, error: e2 } = await supabase
    .from('infra_pops').select('latitude, longitude').in('id', pops.map((p) => p.id));
  if (e2) return erro(res, e2);
  const lons = coords.map((c) => Number(c.longitude));
  const lats = coords.map((c) => Number(c.latitude));
  return res.json({
    bbox: [Math.min(...lons), Math.min(...lats), Math.max(...lons), Math.max(...lats)],
    base: 'POPs com coordenadas',
    quantidade: coords.length,
  });
});

// ---------------------------------------------------------------------------
// GET /api/optimap/detalhe/:camada/:id — painel lateral.
// postes / postes_referencia / elementos / trechos: public.optimap_detalhe (atributos +
// fonte + histórico) enriquecido com os NOMES dos vínculos (cidade, POP, segmento, cabo,
// lote, poste, usuários). pops: vw_gis_pops (regra de perfil) + infra_pops.
// Só o elemento pedido é transferido — nunca a rede inteira.
// ---------------------------------------------------------------------------
async function nomes(supabase, tabela, colunas, ids) {
  const lista = [...new Set(ids.filter(Boolean))];
  if (lista.length === 0) return {};
  const { data } = await supabase.from(tabela).select(`id, ${colunas}`).in('id', lista);
  return Object.fromEntries((data || []).map((r) => [r.id, r]));
}

router.get('/detalhe/:camada/:id', async (req, res) => {
  const { camada, id } = req.params;
  if (!CAMADAS_DETALHE.has(camada)) return res.status(400).json({ error: 'Camada inválida.' });
  if (!UUID_RE.test(id)) return res.status(400).json({ error: 'id inválido.' });
  const supabase = clientForRequest(req.userJwt);

  if (camada === 'pops') {
    const { data: vis, error } = await supabase.from('vw_gis_pops').select('id, cidade_id, codigo, nome, tipo, status').eq('id', id).maybeSingle();
    if (error) return erro(res, error);
    if (!vis) return res.status(404).json({ error: 'POP não encontrado ou sem coordenadas cadastradas.' });
    const { data: pop, error: e2 } = await supabase
      .from('infra_pops').select('endereco, latitude, longitude, capacidade_total, observacoes, km_rede, postes_count, atualizado_em')
      .eq('id', id).maybeSingle();
    if (e2) return erro(res, e2);
    if (!pop) return res.status(404).json({ error: 'POP não encontrado.' });
    const cid = await nomes(supabase, 'cidades_infra', 'nome, uf', [vis.cidade_id]);
    return res.json({
      camada, ...vis, ...pop,
      cidade: cid[vis.cidade_id] || null,
      geometry: { type: 'Point', coordinates: [Number(pop.longitude), Number(pop.latitude)] },
      fonte: { codigo: 'OPTIMON_INFRA_POPS', nome: 'Cadastro de POPs do OptiMon (infra_pops)', tipo: 'PROPRIA' },
    });
  }

  const { data: d, error } = await supabase.rpc('optimap_detalhe', { p_camada: camada, p_id: id });
  if (error) return erro(res, error);
  if (!d) return res.status(404).json({ error: 'Elemento não encontrado.' });
  // Arquivado (soft delete) não aparece nos tiles nem na busca — o detalhe segue a mesma regra.
  if (d.removido_em) return res.status(404).json({ error: 'Elemento arquivado.' });

  // Fase 5: ocupações (empresa / contrato / UC) do poste de referência.
  let ocupacoes;
  if (camada === 'postes_referencia') {
    const { data: oc, error: e3 } = await supabase.rpc('optimap_ocupacoes_do_poste', { p_poste_referencia_id: id });
    if (e3) return erro(res, e3);
    ocupacoes = oc || [];
  }
  const usuarioIds = [d.criado_por, d.validado_por, ...((d.historico_estado || []).map((h) => h.usuario_id)),
    ...((ocupacoes || []).map((o) => o.criado_por))];
  const [cid, pops, segs, cabos, lotes, postes, elems, users] = await Promise.all([
    nomes(supabase, 'cidades_infra', 'nome, uf', [d.cidade_id]),
    nomes(supabase, 'infra_pops', 'codigo, nome', [d.pop_id, d.ponta_a_pop_id, d.ponta_b_pop_id]),
    nomes(supabase, 'infra_segmentos', 'nome', [d.segmento_id]),
    nomes(supabase, 'infra_cabos', 'identificacao, capacidade_fo', [d.cabo_id]),
    nomes(supabase, 'infra_postes', 'identificacao, quantidade, proprietario_terceiro', [d.infra_poste_lote_id]),
    nomes(supabase, 'gis_postes', 'codigo, estado', [d.poste_id]),
    nomes(supabase, 'gis_elementos', 'tipo, codigo, nome', [d.ponta_a_elemento_id, d.ponta_b_elemento_id]),
    nomes(supabase, 'usuarios', 'nome', usuarioIds),
  ]);
  const ref = (map, key) => (key ? map[key] || { id: key } : null);
  // "tipo" da ponta = 'elemento' | 'pop' (o tipo do elemento — CEO/CTO... — vai em tipo_elemento).
  const ponta = (em, pm, elementoId, popId) => {
    if (elementoId) { const e = ref(em, elementoId); return { ...e, tipo_elemento: e.tipo || null, tipo: 'elemento' }; }
    if (popId) return { ...ref(pm, popId), tipo: 'pop' };
    return null;
  };
  return res.json({
    ...d,
    vinculos: {
      cidade: ref(cid, d.cidade_id),
      pop: ref(pops, d.pop_id),
      segmento: ref(segs, d.segmento_id),
      cabo: ref(cabos, d.cabo_id),
      lote_postes: ref(lotes, d.infra_poste_lote_id),
      poste: ref(postes, d.poste_id),
      ponta_a: ponta(elems, pops, d.ponta_a_elemento_id, d.ponta_a_pop_id),
      ponta_b: ponta(elems, pops, d.ponta_b_elemento_id, d.ponta_b_pop_id),
    },
    ...(ocupacoes ? { ocupacoes } : {}),
    usuarios: Object.fromEntries(Object.entries(users).map(([k, v]) => [k, v.nome])),
  });
});

// Fase 4 — importações (montado depois do middleware de perfil acima).
router.use('/importacoes', require('./optimapImportacoes'));
// Fase 5 — empresas, ocupações e listas do CES.
router.use('/ces', require('./optimapCes'));
router.use('/', require('./optimapEmpresas'));

module.exports = router;
