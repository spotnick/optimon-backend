#!/usr/bin/env node
// OptiMap — Fase 4: COLETOR de postes do mapa público da Copel, por município.
//
// Gera um arquivo GeoJSON para ser importado no OptiMon (tela OptiMap → Importações), onde
// passa por prévia, comparação e aprovação. Este script NÃO grava nada no OptiMon.
//
// Como funciona:
//   1. Busca o limite oficial do município no IBGE (API pública de malhas).
//   2. Conta os postes da Copel no retângulo do município e baixa em páginas de até 2.000,
//      ordenadas por objectid, com 3 s entre páginas (sem paralelismo).
//   3. Mantém só os postes DENTRO do polígono do município; descarta duplicados.
//   4. Salva: copel_<ibge>_<municipio>_<data>.geojson + resumo.txt + progresso.json.
//
// Salvaguardas (relatório OptiMap Fase 1, Adendo 2): identificação no User-Agent, 1
// requisição por vez, intervalo mínimo, para no primeiro erro (403/429/5xx/erro do
// serviço) sem tentar contornar; retoma de onde parou com --continuar.
// Decisão registrada: coleta automatizada decidida e assumida pela NICK.
//
// Uso (Node 18+), na pasta optimon:
//   node tools/optimap/coletar_copel.mjs --cidade "Jussara"
//   node tools/optimap/coletar_copel.mjs --cidade "Piraí do Sul" --uf PR
//   node tools/optimap/coletar_copel.mjs --ibge 4112900
//   node tools/optimap/coletar_copel.mjs --cidade "Jussara" --continuar   (retoma após erro)
// Opcional: OPTIMAP_CONTATO="email@dominio" identifica a NICK no User-Agent.

import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const VERSAO = 'coletar_copel/1.0';
const CAMADA = process.env.OPTIMAP_COPEL_URL
  || 'https://www.copel.com/arcgis/rest/services/Hosted/MapaPublicoCompartilhamento/FeatureServer/0';
const IBGE = process.env.OPTIMAP_IBGE_URL || 'https://servicodados.ibge.gov.br/api';
const PAGINA = 2000;
const INTERVALO_MS = Number(process.env.OPTIMAP_INTERVALO_MS || 3000);
const CONTATO = process.env.OPTIMAP_CONTATO ? ` contato: ${process.env.OPTIMAP_CONTATO}` : '';
// Cabeçalho HTTP só aceita ASCII: acento no User-Agent faz servidores responderem 400.
const soAscii = (t) => t.normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^\x20-\x7e]/g, '');
const UA = soAscii(`OptiMon-NICK-Network/${VERSAO} (coleta por municipio;${CONTATO})`);

// ---------------------------------------------------------------- argumentos
const args = process.argv.slice(2);
const arg = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined; };
const CIDADE = arg('--cidade');
const UF = (arg('--uf') || 'PR').toUpperCase();
const IBGE_ID = arg('--ibge');
const CONTINUAR = args.includes('--continuar');
if (!CIDADE && !IBGE_ID) {
  console.error('Informe --cidade "Nome" (e opcionalmente --uf PR) ou --ibge <código de 7 dígitos>.');
  process.exit(2);
}

const aqui = dirname(fileURLToPath(import.meta.url));
const espera = (ms) => new Promise((r) => setTimeout(r, ms));
const semAcento = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
let ultimaCopel = 0;

async function getJson(url, { copel = false } = {}) {
  if (copel) {
    const falta = ultimaCopel + INTERVALO_MS - Date.now();
    if (falta > 0) await espera(falta);
    ultimaCopel = Date.now();
  }
  let res;
  try {
    res = await fetch(url, { headers: { 'User-Agent': UA, Accept: 'application/json, application/geo+json' }, signal: AbortSignal.timeout(60000) });
  } catch (e) {
    throw new Error(`falha de rede em ${new URL(url).host} (${e.message})`);
  }
  const texto = await res.text();
  if (!res.ok) throw new Error(`${new URL(url).host} respondeu HTTP ${res.status} em ${new URL(url).pathname} — parando, sem novas tentativas.`);
  let json;
  try { json = JSON.parse(texto); } catch { throw new Error(`${new URL(url).host}: resposta não é JSON (${texto.slice(0, 100)})`); }
  if (json && json.error) throw new Error(`serviço respondeu erro ${json.error.code}: ${json.error.message}`);
  return json;
}

// ---------------------------------------------------------------- IBGE
async function resolverMunicipio() {
  if (IBGE_ID) {
    if (!/^\d{7}$/.test(IBGE_ID)) throw new Error('--ibge deve ter 7 dígitos.');
    const m = await getJson(`${IBGE}/v1/localidades/municipios/${IBGE_ID}`);
    return { ibge: String(m.id), nome: m.nome, uf: m.microrregiao?.mesorregiao?.UF?.sigla || UF };
  }
  const lista = await getJson(`${IBGE}/v1/localidades/estados/${UF}/municipios`);
  const alvo = semAcento(CIDADE);
  const achados = lista.filter((m) => semAcento(m.nome) === alvo);
  if (achados.length !== 1) {
    const parecidos = lista.filter((m) => semAcento(m.nome).includes(alvo)).map((m) => `${m.nome} (${m.id})`).slice(0, 8);
    throw new Error(`município "${CIDADE}"/${UF} não encontrado de forma única no IBGE.${parecidos.length ? ` Parecidos: ${parecidos.join(', ')} — use --ibge.` : ''}`);
  }
  return { ibge: String(achados[0].id), nome: achados[0].nome, uf: UF };
}

async function limiteMunicipio(ibge) {
  // v3 (qualidade=maxima); se indisponível, v4 (qualidade=4). GeoJSON em SIRGAS 2000 ≈ WGS84.
  const tentativas = [
    `${IBGE}/v3/malhas/municipios/${ibge}?formato=application/vnd.geo+json&qualidade=maxima`,
    `${IBGE}/v4/malhas/municipios/${ibge}?formato=application/vnd.geo+json&qualidade=4`,
  ];
  let ultimoErro;
  for (const url of tentativas) {
    try {
      const gj = await getJson(url);
      const geom = gj.type === 'FeatureCollection' ? gj.features?.[0]?.geometry : gj.type === 'Feature' ? gj.geometry : gj;
      if (geom && (geom.type === 'Polygon' || geom.type === 'MultiPolygon')) return { geom, url };
      ultimoErro = new Error('malha sem polígono');
    } catch (e) { ultimoErro = e; }
  }
  throw new Error(`não foi possível obter o limite do município no IBGE (${ultimoErro?.message}).`);
}

const poligonos = (g) => (g.type === 'Polygon' ? [g.coordinates] : g.coordinates);
function bboxDe(g) {
  let [x0, y0, x1, y1] = [Infinity, Infinity, -Infinity, -Infinity];
  for (const p of poligonos(g)) for (const [x, y] of p[0]) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); }
  return [x0, y0, x1, y1];
}
function noAnel(x, y, anel) {
  let dentro = false;
  for (let i = 0, j = anel.length - 1; i < anel.length; j = i++) {
    const [xi, yi] = anel[i]; const [xj, yj] = anel[j];
    if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) dentro = !dentro;
  }
  return dentro;
}
const noMunicipio = (x, y, g) => poligonos(g).some((p) => noAnel(x, y, p[0]) && !p.slice(1).some((buraco) => noAnel(x, y, buraco)));

// ---------------------------------------------------------------- principal
const linhas = [];
const log = (s = '') => { console.log(s); linhas.push(s); };

(async () => {
  const mun = await resolverMunicipio();
  const slug = semAcento(mun.nome).replace(/[^a-z0-9]+/g, '_');
  const pasta = join(aqui, 'saida', `copel_${mun.ibge}_${slug}`);
  mkdirSync(pasta, { recursive: true });
  const arqProgresso = join(pasta, 'progresso.json');

  log(`OptiMap — coleta Copel por município (${VERSAO})`);
  log(`Município: ${mun.nome}/${mun.uf} — IBGE ${mun.ibge}`);
  const { geom, url: urlMalha } = await limiteMunicipio(mun.ibge);
  const bbox = bboxDe(geom);
  log(`Limite municipal: IBGE (${urlMalha.includes('/v3/') ? 'malhas v3' : 'malhas v4'}) — retângulo ${bbox.map((v) => v.toFixed(4)).join(', ')}`);

  const envelope = { geometry: bbox.join(','), geometryType: 'esriGeometryEnvelope', inSR: '4326', spatialRel: 'esriSpatialRelIntersects' };
  const q = (p) => `${CAMADA}/query?${new URLSearchParams({ ...p, f: 'json' })}`;

  let progresso = { pagina: 0, total_retangulo: null, registros: [] };
  if (CONTINUAR && existsSync(arqProgresso)) {
    progresso = JSON.parse(readFileSync(arqProgresso, 'utf8'));
    log(`Retomando da página ${progresso.pagina + 1} (${progresso.registros.length} registros já baixados).`);
  }
  if (progresso.total_retangulo === null) {
    const c = await getJson(q({ where: '1=1', returnCountOnly: 'true', ...envelope }), { copel: true });
    progresso.total_retangulo = c.count;
  }
  const paginas = Math.ceil(progresso.total_retangulo / PAGINA);
  log(`Postes no retângulo do município: ${progresso.total_retangulo.toLocaleString('pt-BR')} → ${paginas} página(s) de até ${PAGINA}`);

  const coletadoEm = new Date().toISOString();
  try {
    for (let p = progresso.pagina; p < paginas; p++) {
      const r = await getJson(q({
        where: '1=1', ...envelope, outFields: 'objectid,num_seq_geo,latitude,longitude,situacao,indic_ps_particular',
        returnGeometry: 'true', outSR: '4326', orderByFields: 'objectid ASC', resultOffset: String(p * PAGINA), resultRecordCount: String(PAGINA),
      }), { copel: true });
      const feats = r.features || [];
      for (const f of feats) progresso.registros.push({ ...f.attributes, gx: f.geometry?.x ?? null, gy: f.geometry?.y ?? null });
      progresso.pagina = p + 1;
      writeFileSync(arqProgresso, JSON.stringify(progresso));
      process.stdout.write(`  página ${p + 1}/${paginas}: ${feats.length} registros\n`);
      if (feats.length === 0) break;
    }
  } catch (e) {
    writeFileSync(arqProgresso, JSON.stringify(progresso));
    log('');
    log(`INTERROMPIDO: ${e.message}`);
    log(`Progresso salvo (${progresso.registros.length} registros, página ${progresso.pagina}/${paginas}). Para retomar depois: adicione --continuar.`);
    writeFileSync(join(pasta, 'resumo.txt'), `${linhas.join('\n')}\n`);
    process.exit(1);
  }

  // filtro + validação
  const vistos = new Map();
  let fora = 0; let duplicados = 0; let invalidos = 0;
  for (const r of progresso.registros) {
    const lon = Number(r.longitude ?? r.gx);
    const lat = Number(r.latitude ?? r.gy);
    if (!r.num_seq_geo || !Number.isFinite(lon) || !Number.isFinite(lat)) { invalidos++; continue; }
    if (!noMunicipio(lon, lat, geom)) { fora++; continue; }
    const id = String(r.num_seq_geo);
    if (vistos.has(id)) { duplicados++; continue; }
    vistos.set(id, {
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [lon, lat] },
      properties: { num_seq_geo: id, situacao: r.situacao ?? null, indic_ps_particular: r.indic_ps_particular ?? null, objectid: r.objectid ?? null },
    });
  }
  const features = [...vistos.values()].sort((a, b) => a.properties.num_seq_geo.localeCompare(b.properties.num_seq_geo));
  const hashConteudo = createHash('sha256').update(JSON.stringify(features)).digest('hex');
  const situacoes = {};
  features.forEach((f) => { situacoes[f.properties.situacao] = (situacoes[f.properties.situacao] || 0) + 1; });

  const saida = {
    type: 'FeatureCollection',
    optimap: {
      formato: 'optimap-referencia-postes/1',
      fonte: 'COPEL_MAPA_PUBLICO',
      camada: CAMADA,
      coletor: VERSAO,
      coletado_em: coletadoEm,
      municipio: { ibge: mun.ibge, nome: mun.nome, uf: mun.uf },
      limite_municipal: urlMalha,
      total_retangulo: progresso.total_retangulo,
      baixados: progresso.registros.length,
      fora_do_municipio: fora,
      duplicados,
      invalidos,
      total: features.length,
      sha256_features: hashConteudo,
    },
    features,
  };
  const data = coletadoEm.slice(0, 10);
  const nomeArq = `copel_${mun.ibge}_${slug}_${data}.geojson`;
  writeFileSync(join(pasta, nomeArq), JSON.stringify(saida));

  log('');
  log(`Baixados: ${progresso.registros.length.toLocaleString('pt-BR')} | fora do município: ${fora} | duplicados: ${duplicados} | inválidos: ${invalidos}`);
  log(`POSTES NO MUNICÍPIO: ${features.length.toLocaleString('pt-BR')}`);
  log(`Situação: ${Object.entries(situacoes).map(([k, v]) => `${k} ${v}`).join(' · ')}`);
  log(`Arquivo para importar no OptiMon: ${join(pasta, nomeArq)}`);
  writeFileSync(join(pasta, 'resumo.txt'), `${linhas.join('\n')}\n`);
})().catch((e) => {
  console.error(`ERRO: ${e.message}`);
  process.exit(1);
});
