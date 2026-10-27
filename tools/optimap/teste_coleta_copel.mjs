#!/usr/bin/env node
// OptiMap — TESTE DE VIABILIDADE da coleta do mapa público da Copel (antes da Fase 4).
//
// Objetivo: descobrir, com o MÍNIMO de requisições, se a camada pública traz o que o
// OptiMap precisa (número do poste, coordenadas, situação) para as cidades da NICK.
// NÃO baixa a base: são 7 requisições no total, uma a cada 3 segundos.
//   1) metadados da camada (campos, limite por página, paginação, sistema de coordenadas)
//   2) total de postes na camada inteira (só a contagem)
//   3) contagem por cidade (Jussara, Cianorte, Piraí do Sul, Ribeirão Claro) — só números
//   4) amostra de 10 postes de Jussara (atributos + coordenadas)
// Para no primeiro erro (403/429/5xx) e nunca tenta contornar bloqueio.
//
// Decisão registrada: coleta automatizada decidida e assumida pela NICK (relatório OptiMap
// Fase 1, Adendo 2). O robots.txt da Copel desautoriza acesso automatizado a /arcgis/.
//
// Uso (Node 18+):  node tools/optimap/teste_coleta_copel.mjs
// Opcional: OPTIMAP_CONTATO="seu-email@empresa" para identificar a NICK no User-Agent.
// Saída: tools/optimap/saida/teste_coleta_<data>/ (JSONs brutos + resumo.txt)

import { mkdirSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const CAMADA = process.env.OPTIMAP_COPEL_URL
  || 'https://www.copel.com/arcgis/rest/services/Hosted/MapaPublicoCompartilhamento/FeatureServer/0';
const INTERVALO_MS = 3000;
const CONTATO = process.env.OPTIMAP_CONTATO ? ` contato: ${process.env.OPTIMAP_CONTATO}` : '';
const USER_AGENT = `OptiMon-NICK-Network/teste-viabilidade (consulta pontual;${CONTATO})`;

// Retângulos aproximados (±~4 km) ao redor do centro urbano de cada cidade, em WGS84.
// Servem só para CONTAR; não são limites oficiais de município.
const CIDADES = [
  { nome: 'Jussara-PR', bbox: [-52.505, -23.655, -52.435, -23.590] },
  { nome: 'Cianorte-PR', bbox: [-52.660, -23.705, -52.555, -23.620] },
  { nome: 'Piraí do Sul-PR', bbox: [-49.985, -24.565, -49.910, -24.490] },
  { nome: 'Andirá-PR', bbox: [-50.265, -23.085, -50.195, -23.020] },
];

// `--so-contagem`: refaz SÓ a contagem por cidade (1 requisição por cidade), sem metadados,
// total ou amostra. Ex.: node tools/optimap/teste_coleta_copel.mjs --so-contagem Andirá
const SO_CONTAGEM = process.argv.includes('--so-contagem');
const FILTRO = process.argv.slice(2).filter((a) => !a.startsWith('--')).map((a) => a.toLowerCase());
const CIDADES_ALVO = FILTRO.length ? CIDADES.filter((c) => FILTRO.some((f) => c.nome.toLowerCase().includes(f))) : CIDADES;

const aqui = dirname(fileURLToPath(import.meta.url));
const pasta = join(aqui, 'saida', `teste_coleta_${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}`);
mkdirSync(pasta, { recursive: true });

const linhas = [];
const log = (s = '') => { console.log(s); linhas.push(s); };
const espera = (ms) => new Promise((r) => setTimeout(r, ms));
let primeira = true;

async function consultar(rotulo, caminho, params) {
  if (!primeira) await espera(INTERVALO_MS);
  primeira = false;
  const url = `${CAMADA}${caminho}?${new URLSearchParams({ ...params, f: 'json' })}`;
  let res;
  try {
    res = await fetch(url, { headers: { 'User-Agent': USER_AGENT, Accept: 'application/json' }, signal: AbortSignal.timeout(30000) });
  } catch (e) {
    throw new Error(`${rotulo}: falha de rede (${e.message})`);
  }
  const texto = await res.text();
  writeFileSync(join(pasta, `${rotulo}.json`), texto);
  if (!res.ok) throw new Error(`${rotulo}: HTTP ${res.status} — parando (sem novas tentativas).`);
  let json;
  try { json = JSON.parse(texto); } catch { throw new Error(`${rotulo}: resposta não é JSON (início: ${texto.slice(0, 120)})`); }
  if (json.error) throw new Error(`${rotulo}: serviço respondeu erro ${json.error.code}: ${json.error.message}${json.error.code === 499 || json.error.code === 498 ? ' (exige token — camada NÃO é pública)' : ''}`);
  return json;
}

const envelope = (b) => ({
  geometry: b.join(','), geometryType: 'esriGeometryEnvelope', inSR: '4326', spatialRel: 'esriSpatialRelIntersects',
});

try {
  log('OptiMap — teste de viabilidade da camada pública da Copel');
  log(`Camada: ${CAMADA}`);
  log(`Data: ${new Date().toLocaleString('pt-BR')}`);
  log('');

  if (SO_CONTAGEM) {
    log('== Contagem por cidade (modo --so-contagem)');
    for (const c of CIDADES_ALVO) {
      const r = await consultar(`3_contagem_${c.nome.replace(/[^A-Za-z]/g, '')}`, '/query', { where: '1=1', returnCountOnly: 'true', ...envelope(c.bbox) });
      log(`${c.nome.padEnd(20)} ${Number(r.count).toLocaleString('pt-BR')} postes`);
    }
    process.exit(0);
  }

  // 1) metadados
  const meta = await consultar('1_metadados', '', {});
  const campos = (meta.fields || []).map((f) => `${f.name} (${f.type.replace('esriFieldType', '')}${f.alias && f.alias !== f.name ? `, "${f.alias}"` : ''})`);
  log('== 1. Metadados da camada');
  log(`Nome: ${meta.name} | geometria: ${meta.geometryType} | SR: ${meta.extent?.spatialReference?.latestWkid || meta.extent?.spatialReference?.wkid || '?'}`);
  log(`Capacidades: ${meta.capabilities} | máx. registros por consulta: ${meta.maxRecordCount} | paginação: ${meta.advancedQueryCapabilities?.supportsPagination ?? '?'}`);
  log(`Formatos: ${meta.supportedQueryFormats || '?'} | copyright: ${meta.copyrightText || '(vazio)'}`);
  log(`Descrição: ${(meta.description || '(vazia)').replace(/<[^>]+>/g, ' ').trim().slice(0, 200)}`);
  log(`Campos (${campos.length}): ${campos.join('; ')}`);
  const nomes = new Set((meta.fields || []).map((f) => f.name.toLowerCase()));
  const essenciais = ['num_seq_geo', 'latitude', 'longitude', 'situacao'];
  log(`Campos essenciais presentes: ${essenciais.map((c) => `${c}=${nomes.has(c) ? 'SIM' : 'NÃO'}`).join(', ')}`);
  log('');

  // 2) total
  const total = await consultar('2_contagem_total', '/query', { where: '1=1', returnCountOnly: 'true' });
  log('== 2. Total de postes na camada inteira');
  log(`${Number(total.count).toLocaleString('pt-BR')} postes`);
  log('');

  // 3) por cidade
  log('== 3. Contagem por cidade (retângulo aproximado do centro urbano)');
  const porCidade = {};
  for (const c of CIDADES) {
    const r = await consultar(`3_contagem_${c.nome.replace(/[^A-Za-z]/g, '')}`, '/query', { where: '1=1', returnCountOnly: 'true', ...envelope(c.bbox) });
    porCidade[c.nome] = r.count;
    log(`${c.nome.padEnd(20)} ${Number(r.count).toLocaleString('pt-BR')} postes`);
  }
  log('');

  // 4) amostra Jussara
  const amostra = await consultar('4_amostra_jussara', '/query', {
    where: '1=1', outFields: '*', returnGeometry: 'true', outSR: '4326', resultRecordCount: '10', ...envelope(CIDADES[0].bbox),
  });
  const feats = amostra.features || [];
  log(`== 4. Amostra de Jussara (${feats.length} postes)`);
  feats.forEach((f, i) => {
    const a = f.attributes || {};
    const g = f.geometry || {};
    log(`${String(i + 1).padStart(2)}. ${JSON.stringify(a)} | geometria: ${g.x ?? '?'}, ${g.y ?? '?'}`);
  });
  log('');

  // Conclusão automática
  log('== Conclusão preliminar');
  const temCampos = essenciais.every((c) => nomes.has(c));
  const cidadesComDados = Object.entries(porCidade).filter(([, n]) => n > 0).map(([k]) => k);
  if (!temCampos) log('- ATENÇÃO: faltam campos essenciais — a camada não atende sozinha.');
  else log('- Campos essenciais (número do poste, coordenadas, situação) disponíveis.');
  if (cidadesComDados.length === 0) log('- ATENÇÃO: nenhuma das 4 cidades tem postes nesta camada (provável recorte regional, ex.: Cafelândia).');
  else log(`- Cidades com postes na camada: ${cidadesComDados.join(', ')}.`);
  if (meta.maxRecordCount) log(`- Coleta completa de uma cidade exigiria ~${Math.max(...Object.values(porCidade).map((n) => Math.ceil(n / meta.maxRecordCount)), 0)} página(s) por cidade (limite ${meta.maxRecordCount}/página).`);
} catch (e) {
  log('');
  log(`INTERROMPIDO: ${e.message}`);
  process.exitCode = 1;
} finally {
  writeFileSync(join(pasta, 'resumo.txt'), `${linhas.join('\n')}\n`);
  console.log(`\nArquivos salvos em: ${pasta}`);
}
