#!/usr/bin/env node
// OptiMap — Fase 4: testes E2E das telas de importação (/optimap/importacoes) com Playwright.
//
// Pré-requisito: ambiente local da Fase 3 no ar (tests/optimap/fase3/stack.sh subir). Este
// script recria o banco (stack.sh banco base = migrations + usuários de teste + seed real de
// Jussara) e usa ARQUIVOS DE TESTE no formato do coletor, gerados aqui, com números de poste
// 99xxxxxxxx (fora da faixa da Copel) — nunca apresentados como dado real.
//
// Uso: NODE_PATH=<node_modules com playwright> node tests/optimap/fase4/e2e_importacoes.js

const { chromium } = require('playwright');
const { execSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '../../..');
const BASE = process.env.E2E_BASE_URL || 'http://127.0.0.1:5173';
const SHOTS = process.env.E2E_SCREENSHOTS || path.join(ROOT, 'tests/optimap/fase4/screenshots');
const STYLE_URL = 'https://tiles.openfreemap.org/styles/positron';
fs.mkdirSync(SHOTS, { recursive: true });
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'optimap-f4-'));

const U = {
  ADMINISTRADOR: 'a0000000-0000-0000-0000-000000000001', DIRETOR: 'a0000000-0000-0000-0000-000000000002',
  ENGENHARIA: 'a0000000-0000-0000-0000-000000000003', COMERCIAL: 'a0000000-0000-0000-0000-000000000004',
};
const env = { ...process.env, PGHOST: process.env.PGHOST || '/tmp', PGUSER: process.env.PGUSER || 'postgres', PGPORT: process.env.PGPORT || '5432' };
const sh = (cmd) => execSync(cmd, { cwd: ROOT, encoding: 'utf8', env }).trim();
const sql = (q) => sh(`psql -X -d optimon -At -c "${q.replace(/"/g, '\\"')}"`);
const jwt = (uid) => sh(`node supabase/dev-local-only/mint_jwt.js ${uid}`);

let PASS = 0; let FAIL = 0; const falhas = [];
function check(nome, cond, detalhe = '') {
  if (cond) { PASS++; console.log(`PASS | ${nome}`); } else { FAIL++; falhas.push(nome); console.log(`FAIL | ${nome}${detalhe ? ` -> ${detalhe}` : ''}`); }
}

// ---------------------------------------------------------------------------
// Arquivos de teste no formato do coletor (optimap-referencia-postes/1)
// ---------------------------------------------------------------------------
function postesBase(qtd) {
  const lista = [];
  for (let k = 0; k < qtd; k++) {
    lista.push({
      id: String(9900000000 + k),
      lon: Number((-52.478 + (k % 50) * 0.0004).toFixed(6)),
      lat: Number((-23.630 + Math.floor(k / 50) * 0.0004).toFixed(6)),
      situacao: k % 4 === 0 ? 'Ocupado' : 'Disponível',
      objectid: k + 1,
    });
  }
  return lista;
}
function arquivo(nome, postes, coletadoEm) {
  const features = postes
    .map((p) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: [p.lon, p.lat] },
      properties: { num_seq_geo: p.id, situacao: p.situacao, indic_ps_particular: 'N', objectid: p.objectid } }))
    .sort((a, b) => a.properties.num_seq_geo.localeCompare(b.properties.num_seq_geo));
  const doc = {
    type: 'FeatureCollection',
    optimap: {
      formato: 'optimap-referencia-postes/1', fonte: 'COPEL_MAPA_PUBLICO', camada: 'TESTE-E2E', coletor: 'e2e-fase4',
      coletado_em: coletadoEm, municipio: { ibge: '4112900', nome: 'Jussara', uf: 'PR' }, limite_municipal: 'teste',
      total_retangulo: features.length, baixados: features.length, fora_do_municipio: 0, duplicados: 0, invalidos: 0,
      total: features.length, sha256_features: crypto.createHash('sha256').update(JSON.stringify(features)).digest('hex'),
    },
    features,
  };
  const f = path.join(TMP, nome);
  fs.writeFileSync(f, JSON.stringify(doc));
  return { f, doc };
}

const A = postesBase(2000);
const ARQ_A = arquivo('copel_4112900_jussara_2026-10-21.geojson', A, '2026-10-21T10:00:00.000Z');
// Coleta seguinte: 10 mudam de situação, 1 desloca 60 m (conflito), 30 somem, 1 novo.
const B = A.slice(0, 1970).map((p, k) => ({ ...p,
  situacao: k >= 1 && k <= 10 ? (p.situacao === 'Ocupado' ? 'Disponível' : 'Ocupado') : p.situacao,
  lat: k === 20 ? Number((p.lat + 60 / 111320).toFixed(6)) : p.lat,
  objectid: p.objectid + 5000 }));
B.push({ id: '9900009999', lon: -52.47, lat: -23.62, situacao: 'Disponível', objectid: 99999 });
const ARQ_B = arquivo('copel_4112900_jussara_2026-10-22.geojson', B, '2026-10-22T10:00:00.000Z');
// Arquivo adulterado: coordenada editada depois da coleta (hash não confere).
const adulterado = JSON.parse(fs.readFileSync(ARQ_A.f, 'utf8'));
adulterado.features[0].geometry.coordinates[0] = -52.5;
const ARQ_X = path.join(TMP, 'adulterado.geojson');
fs.writeFileSync(ARQ_X, JSON.stringify(adulterado));

// ---------------------------------------------------------------------------
const ESTILO_STUB = { version: 8, name: 'stub', sources: {}, layers: [{ id: 'fundo', type: 'background', paint: { 'background-color': '#f2efe9' } }] };
async function novaPagina(browser) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await context.newPage();
  page.__erros = [];
  page.on('pageerror', (e) => page.__erros.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error') page.__erros.push(m.text()); });
  await page.route(STYLE_URL, (r) => r.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(ESTILO_STUB) }));
  return page;
}
async function login(page, uid) {
  const token = jwt(uid);
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
  await page.waitForFunction('!!window.__optimonSupabase', null, { timeout: 15000 });
  await page.evaluate(({ token }) => {
    const payload = JSON.parse(atob(token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
    const session = { access_token: token, token_type: 'bearer', expires_in: payload.exp - payload.iat, expires_at: payload.exp,
      refresh_token: 'e2e-f4', user: { id: payload.sub, aud: payload.aud, role: payload.role, email: 'e2e@teste.local' } };
    window.localStorage.setItem(window.__optimonSupabase.auth.storageKey, JSON.stringify(session));
    window.localStorage.setItem('optimon_onboarding_visto_v1', '1');
  }, { token });
}
const texto = (page, sel) => page.locator(sel).first().textContent();
const contagem = async (page, classe) => Number((await texto(page, `[data-testid="imp-cartao-${classe}"] .oi-cartao-valor`)).replace(/\D/g, ''));
async function abrirDetalhe(page, id) {
  await page.goto(`${BASE}/optimap/importacoes/${id}`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('[data-testid="importacao-detalhe"]', { timeout: 20000 });
  await page.waitForSelector('[data-testid="imp-item"]', { timeout: 20000 });
}
async function enviar(page, arquivoPath) {
  await page.goto(`${BASE}/optimap/importacoes`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('[data-testid="imp-envio"]', { timeout: 20000 });
  await page.setInputFiles('[data-testid="imp-arquivo"]', arquivoPath);
  await page.click('[data-testid="imp-enviar"]');
}

(async () => {
  sh('tests/optimap/fase3/stack.sh banco base');
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });

  // --- E01 COMERCIAL não acessa importações -----------------------------------------
  {
    const page = await novaPagina(browser);
    await login(page, U.COMERCIAL);
    await page.goto(`${BASE}/optimap`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="optimap-status"]', { timeout: 20000 });
    check('E01a COMERCIAL: mapa sem link para importações', await page.locator('[data-testid="optimap-link-importacoes"]').count() === 0);
    await page.goto(`${BASE}/optimap/importacoes`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="imp-sem-acesso"]', { timeout: 20000 });
    check('E01b COMERCIAL: /optimap/importacoes mostra “sem acesso”', true);
    await page.context().close();
  }

  // --- E02 ENGENHARIA envia o arquivo e vê a prévia -----------------------------------
  let idA;
  {
    const page = await novaPagina(browser);
    await login(page, U.ENGENHARIA);
    await page.goto(`${BASE}/optimap`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="optimap-link-importacoes"]', { timeout: 20000 });
    await page.click('[data-testid="optimap-link-importacoes"]');
    await page.waitForSelector('[data-testid="imp-lista-vazia"]', { timeout: 20000 });
    check('E02a ENGENHARIA chega às importações pelo mapa (lista vazia, formulário de envio)', await page.locator('[data-testid="imp-envio"]').count() === 1);
    await page.screenshot({ path: path.join(SHOTS, '01_lista_vazia_envio.png') });

    await page.setInputFiles('[data-testid="imp-arquivo"]', ARQ_X);
    await page.click('[data-testid="imp-enviar"]');
    await page.waitForSelector('[data-testid="imp-envio-erro"]', { timeout: 20000 });
    check('E02b arquivo adulterado (hash do coletor não confere) é recusado', /hash/.test(await texto(page, '[data-testid="imp-envio-erro"]')));

    const t0 = Date.now();
    await enviar(page, ARQ_A.f);
    await page.waitForSelector('[data-testid="importacao-detalhe"]', { timeout: 60000 });
    await page.waitForSelector('[data-testid="imp-item"]', { timeout: 20000 });
    idA = page.url().split('/').pop();
    console.log(`      envio + prévia de 2.000 postes pela interface: ${Date.now() - t0} ms`);
    check('E02c prévia: 2.000 NOVOS, status Prévia', await contagem(page, 'NOVO') === 2000 && /Prévia/.test(await texto(page, '[data-testid="imp-status"]')));
    check('E02d nada gravado antes da aprovação', sql('select count(*) from gis_postes_referencia') === '0');
    check('E02e cidade casada com a Jussara do OptiMon (seed real, por nome)', /cidade OptiMon: Jussara/.test(await texto(page, '.page-header p')));
    check('E02f ENGENHARIA não vê o botão Aprovar', await page.locator('[data-testid="imp-aprovar"]').count() === 0);
    await page.waitForFunction(() => document.querySelector('[data-testid="imp-mapa"] canvas'), null, { timeout: 20000 });
    await page.waitForTimeout(1500);
    await page.screenshot({ path: path.join(SHOTS, '02_previa_novos.png') });
    check('E02g sem erros de JavaScript', page.__erros.filter((e) => !/Failed to load resource/.test(e)).length === 0, page.__erros.join(' | '));
    await page.context().close();
  }

  // --- E03 DIRETOR aprova ------------------------------------------------------------
  {
    const page = await novaPagina(browser);
    await login(page, U.DIRETOR);
    await abrirDetalhe(page, idA);
    await page.click('[data-testid="imp-aprovar"]');
    await page.waitForSelector('[data-testid="imp-modal"]');
    await page.screenshot({ path: path.join(SHOTS, '03_confirmar_aprovacao.png') });
    await page.click('[data-testid="imp-modal-confirmar"]');
    await page.waitForSelector('[data-testid="imp-mensagem"]', { timeout: 60000 });
    check('E03a aprovação aplicada: mensagem com 2.000 incluídos e status Importada',
      /2\.000 incluídos/.test(await texto(page, '[data-testid="imp-mensagem"]')) && /Importada/.test(await texto(page, '[data-testid="imp-status"]')));
    check('E03b banco: 2.000 postes de referência CONFIRMADO (externos; nenhum poste NICK criado)',
      sql("select count(*) filter (where estado_sincronizacao='CONFIRMADO')||'/'||(select count(*) from gis_postes) from gis_postes_referencia") === '2000/0');
    await page.screenshot({ path: path.join(SHOTS, '04_importada.png') });
    await page.goto(`${BASE}/optimap`, { waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => /2\.000/.test(document.querySelector('[data-testid="contagem-postes_referencia"]')?.textContent || ''), null, { timeout: 20000 });
    check('E03c mapa principal passa a contar 2.000 postes de referência', true);
    await page.context().close();
  }

  // --- E04 reimportação: conflitos e ausentes ------------------------------------------
  let idB;
  {
    const page = await novaPagina(browser);
    await login(page, U.ENGENHARIA);
    await enviar(page, ARQ_B.f);
    await page.waitForSelector('[data-testid="importacao-detalhe"]', { timeout: 60000 });
    await page.waitForSelector('[data-testid="imp-item"]', { timeout: 20000 });
    idB = page.url().split('/').pop();
    const c = {};
    for (const k of ['NOVO', 'ATUALIZADO', 'SEM_ALTERACAO', 'CONFLITO', 'AUSENTE']) c[k] = await contagem(page, k);
    check('E04a prévia: 1 novo, 10 atualizados, 1959 sem alteração, 1 conflito, 30 ausentes', JSON.stringify(c) === JSON.stringify({ NOVO: 1, ATUALIZADO: 10, SEM_ALTERACAO: 1959, CONFLITO: 1, AUSENTE: 30 }), JSON.stringify(c));
    check('E04b bloqueio exibido: conflitos sem decisão', await page.locator('[data-testid="imp-bloqueio-CONFLITOS_SEM_DECISAO"]').count() === 1);
    await page.click('[data-testid="imp-cartao-CONFLITO"]');
    await page.waitForSelector('[data-testid="imp-aplicar"]', { timeout: 10000 });
    await page.waitForTimeout(1200); // mapa enquadra o conflito (animação)
    await page.screenshot({ path: path.join(SHOTS, '05_conflito_pendente.png') });
    await page.click('[data-testid="imp-aplicar"]');
    await page.waitForSelector('[data-testid="imp-decisao"]', { timeout: 10000 });
    check('E04c ENGENHARIA decide “Aplicar” e o bloqueio some', await page.locator('[data-testid="imp-bloqueio-CONFLITOS_SEM_DECISAO"]').count() === 0);
    await page.click('[data-testid="imp-cartao-AUSENTE"]');
    await page.waitForTimeout(800);
    await page.screenshot({ path: path.join(SHOTS, '06_ausentes.png') });
    await page.context().close();
  }
  {
    const page = await novaPagina(browser);
    await login(page, U.DIRETOR);
    await abrirDetalhe(page, idB);
    await page.click('[data-testid="imp-aprovar"]');
    await page.click('[data-testid="imp-modal-confirmar"]');
    await page.waitForSelector('[data-testid="imp-mensagem"]', { timeout: 60000 });
    const msg = await texto(page, '[data-testid="imp-mensagem"]');
    check('E04d aprovação: 1 incluído, 11 atualizados, 30 não localizados', /1 incluídos, 11 atualizados/.test(msg) && /30 marcados como não localizados/.test(msg), msg);
    check('E04e ausentes NÃO apagados (2.001 postes; 30 não localizados)',
      sql("select count(*)||'/'||count(*) filter (where estado_sincronizacao='NAO_LOCALIZADO_ULTIMA_COLETA') from gis_postes_referencia") === '2001/30');
    await page.context().close();
  }

  // --- E05 reversão (ADMINISTRADOR) ----------------------------------------------------
  {
    const page = await novaPagina(browser);
    await login(page, U.DIRETOR);
    await abrirDetalhe(page, idB);
    check('E05a DIRETOR não vê o botão Reverter', await page.locator('[data-testid="imp-reverter"]').count() === 0);
    await page.context().close();
  }
  {
    const page = await novaPagina(browser);
    await login(page, U.ADMINISTRADOR);
    await abrirDetalhe(page, idB);
    await page.click('[data-testid="imp-reverter"]');
    check('E05b reverter exige motivo (botão desabilitado sem motivo)', await page.locator('[data-testid="imp-modal-confirmar"]').isDisabled());
    await page.fill('[data-testid="imp-motivo"]', 'Teste E2E da reversão');
    await page.screenshot({ path: path.join(SHOTS, '07_reverter.png') });
    await page.click('[data-testid="imp-modal-confirmar"]');
    await page.waitForSelector('[data-testid="imp-mensagem"]', { timeout: 60000 });
    check('E05c reversão completa e status Revertida', /Reversão completa/.test(await texto(page, '[data-testid="imp-mensagem"]')) && /Revertida/.test(await texto(page, '[data-testid="imp-status"]')));
    check('E05d banco volta ao estado da 1ª importação (2.000 postes, nenhum não localizado, nenhum “ATUALIZADO”)',
      sql("select count(*)||'/'||count(*) filter (where estado_sincronizacao<>'CONFIRMADO') from gis_postes_referencia") === '2000/0');
    await page.screenshot({ path: path.join(SHOTS, '08_revertida.png') });
    await page.goto(`${BASE}/optimap/importacoes`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="imp-lista"]', { timeout: 20000 });
    check('E05e lista mostra as 2 importações com status', (await page.locator('[data-testid="imp-lista"] tbody tr').count()) === 2);
    await page.screenshot({ path: path.join(SHOTS, '09_lista.png') });
    check('E05f auditoria registrou o ciclo', sql("select string_agg(acao, ',' order by criado_em) from auditoria where entidade='gis_importacoes' and acao in ('IMPORT_APPLY','IMPORT_REVERT')") === 'IMPORT_APPLY,IMPORT_APPLY,IMPORT_REVERT');
    await page.context().close();
  }

  await browser.close();
  fs.rmSync(TMP, { recursive: true, force: true });
  console.log(`\n================================================================\nResultado: ${PASS} PASS / ${FAIL} FAIL`);
  if (FAIL) { falhas.forEach((f) => console.log(`  - ${f}`)); process.exit(1); }
})().catch((e) => { console.error('ERRO FATAL:', e); process.exit(2); });
