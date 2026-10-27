#!/usr/bin/env node
// OptiMap — Fase 5: E2E (Playwright) das cores do mapa, filtro por empresa, marcação "ocupado
// sem projeto", listas do CES e tela de empresas.
//
// Pré-requisito: ambiente local da Fase 3 no ar (tests/optimap/fase3/stack.sh subir). O banco é
// recriado aqui (stack.sh banco base) e recebe, pelo fluxo normal da API:
//   * os postes REAIS da Copel de Cianorte (arquivo do coletor da Fase 4);
//   * as listas REAIS do CES da NICK e da AYOTECH coletadas em 27/10/2026.
// Tudo isso só no Postgres local; nada toca o Supabase de produção.
//
// Uso: node tests/optimap/fase5/e2e_fase5.js <copel_cianorte.geojson> <ces_nick.geojson> <ces_ayotech.geojson>

const { chromium } = require('playwright');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../../..');
const BASE = process.env.E2E_BASE_URL || 'http://127.0.0.1:5173';
const API = process.env.E2E_API_URL || 'http://localhost:3001';
const SHOTS = process.env.E2E_SCREENSHOTS || path.join(ROOT, 'tests/optimap/fase5/screenshots');
const STYLE_URL = 'https://tiles.openfreemap.org/styles/positron';
fs.mkdirSync(SHOTS, { recursive: true });
const [ARQ_COPEL, ARQ_NICK, ARQ_AYO] = process.argv.slice(2);
if (!ARQ_COPEL || !ARQ_NICK || !ARQ_AYO) { console.error('uso: e2e_fase5.js <copel_cianorte> <ces_nick> <ces_ayotech>'); process.exit(2); }

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

async function apiUpload(uid, rota, arquivo) {
  const fd = new FormData();
  fd.append('arquivo', new Blob([fs.readFileSync(arquivo)], { type: 'application/geo+json' }), path.basename(arquivo));
  const r = await fetch(`${API}${rota}`, { method: 'POST', headers: { Authorization: `Bearer ${jwt(uid)}` }, body: fd });
  const j = await r.json();
  if (!r.ok) throw new Error(`${rota}: ${r.status} ${JSON.stringify(j)}`);
  return j;
}
async function apiPost(uid, rota, body) {
  const r = await fetch(`${API}${rota}`, { method: 'POST', headers: { Authorization: `Bearer ${jwt(uid)}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
  const j = await r.json();
  if (!r.ok) throw new Error(`${rota}: ${r.status} ${JSON.stringify(j)}`);
  return j;
}

const ESTILO_STUB = { version: 8, name: 'stub', sources: {}, layers: [{ id: 'fundo', type: 'background', paint: { 'background-color': '#f2efe9' } }] };
async function novaPagina(browser) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await context.newPage();
  page.__erros = [];
  page.on('pageerror', (e) => page.__erros.push(String(e)));
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) page.__erros.push(m.text()); });
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
      refresh_token: 'e2e-f5', user: { id: payload.sub, aud: payload.aud, role: payload.role, email: 'e2e@teste.local' } };
    window.localStorage.setItem(window.__optimonSupabase.auth.storageKey, JSON.stringify(session));
    window.localStorage.setItem('optimon_onboarding_visto_v1', '1');
  }, { token });
}
async function abrirMapa(page, centro, zoom) {
  await page.goto(`${BASE}/optimap`, { waitUntil: 'domcontentloaded' });
  await page.waitForFunction('window.__optimapMap && window.__optimapMap.getLayer("om-ref")', null, { timeout: 30000 });
  await page.evaluate(({ centro, zoom }) => window.__optimapMap.jumpTo({ center: centro, zoom }), { centro, zoom });
  await page.waitForFunction('window.__optimapMap.areTilesLoaded() && window.__optimapMap.loaded()', null, { timeout: 30000 });
  await page.waitForTimeout(800);
}
// Clica no poste; se houver vários no ponto, escolhe o do número pedido na lista de candidatos.
async function clicarPoste(page, lon, lat, idExterno) {
  const pt = await page.evaluate(({ lon, lat }) => {
    const p = window.__optimapMap.project([lon, lat]);
    const r = window.__optimapMap.getCanvasContainer().getBoundingClientRect();
    return { x: p.x, y: p.y, px: p.x + r.left, py: p.y + r.top };
  }, { lon, lat });
  const dbg = await page.evaluate(({ x, y }) => ({ f: window.__optimapMap.queryRenderedFeatures([[x - 6, y - 6], [x + 6, y + 6]]).map((f) => f.layer.id + ':' + (f.properties.id_externo || '')), filtro: JSON.stringify(window.__optimapMap.getFilter('om-ref')).slice(0, 200) }), pt);
  await page.mouse.click(pt.px, pt.py);
  await page.waitForSelector('[data-testid="painel-detalhe"]', { timeout: 20000 }).catch(async (e) => { await page.screenshot({ path: path.join(SHOTS, 'dbg_clique.png') }); console.log('DBG', JSON.stringify(pt), JSON.stringify(dbg)); throw e; });
  await page.waitForFunction(() => !document.querySelector('[data-testid="painel-detalhe"] .om-carregando'), null, { timeout: 20000 });
  const cand = page.locator('.om-candidatos button', { hasText: idExterno });
  if (await cand.count()) await cand.first().click();
}
const contarCategorias = (page) => page.evaluate(() => {
  const m = window.__optimapMap;
  const fs = m.queryRenderedFeatures({ layers: ['om-ref'] });
  const cor = m.getPaintProperty('om-ref', 'circle-color');
  const out = { total: fs.length };
  // cor efetiva por feição: avalia a expressão de categoria do próprio estilo
  fs.forEach((f) => { const c = f.layer.paint['circle-color']; const k = typeof c === 'object' ? `${c.r.toFixed(2)},${c.g.toFixed(2)},${c.b.toFixed(2)}` : String(c); out[k] = (out[k] || 0) + 1; });
  out._cats = {};
  fs.forEach((f) => { out._cats[f.properties.categoria] = (out._cats[f.properties.categoria] || 0) + 1; });
  out._expr = JSON.stringify(cor).length;
  return out;
});

(async () => {
  sh('tests/optimap/fase3/stack.sh banco base');
  // O PostgREST reconecta ao banco recriado e recarrega o schema: espera a API responder.
  for (let i = 0; i < 60; i++) {
    const r = await fetch(`${API}/api/optimap/sessao`, { headers: { Authorization: `Bearer ${jwt(U.ADMINISTRADOR)}` } }).catch(() => null);
    if (r && r.ok) break;
    sql("notify pgrst, 'reload schema'");
    await new Promise((ok) => setTimeout(ok, 1000));
  }
  // Postes da Copel de Cianorte (fluxo normal da Fase 4)
  const imp = await apiUpload(U.ENGENHARIA, '/api/optimap/importacoes', ARQ_COPEL);
  await apiPost(U.ADMINISTRADOR, `/api/optimap/importacoes/${imp.id}/aprovar`, {});
  const nRef = Number(sql("select count(*) from gis_postes_referencia"));
  check('E00 postes reais de Cianorte importados (Fase 4)', nRef > 10000, `${nRef}`);

  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });

  // --- E01 COMERCIAL: sem acesso às listas do CES, vê empresas, sem botão de marcar ---------
  {
    const page = await novaPagina(browser);
    await login(page, U.COMERCIAL);
    await page.goto(`${BASE}/optimap/ces`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="ces-sem-acesso"]', { timeout: 20000 });
    check('E01a COMERCIAL: /optimap/ces mostra “sem acesso”', true);
    await page.goto(`${BASE}/optimap/empresas`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="emp-item"]', { timeout: 20000 });
    check('E01b COMERCIAL vê as 2 empresas, sem “Nova empresa”', await page.locator('[data-testid="emp-item"]').count() === 2 && await page.locator('[data-testid="emp-nova"]').count() === 0);
    await page.close();
  }

  // --- E02 ENGENHARIA envia a lista real da NICK pela tela ----------------------------------
  let idNick;
  {
    const page = await novaPagina(browser);
    await login(page, U.ENGENHARIA);
    await page.goto(`${BASE}/optimap/ces`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="ces-envio"]', { timeout: 20000 });
    await page.setInputFiles('[data-testid="ces-arquivo"]', ARQ_NICK);
    await page.click('[data-testid="ces-enviar"]');
    await page.waitForSelector('[data-testid="ces-detalhe"]', { timeout: 60000 });
    idNick = page.url().split('/').pop();
    const novas = Number((await page.locator('[data-testid="ces-cartao-NOVA"] .oi-cartao-valor').textContent()).replace(/\D/g, ''));
    check('E02a prévia da NICK: 5.341 novas', novas === 5341, String(novas));
    check('E02b ENGENHARIA não vê “Aprovar”', await page.locator('[data-testid="ces-aprovar"]').count() === 0);
    await page.waitForSelector('[data-testid="ces-conferencia"]');
    await page.screenshot({ path: path.join(SHOTS, 'f5_01_previa_ces_nick.png'), fullPage: true });
    check('E02c sem erros de página', page.__erros.length === 0, page.__erros.join(' | '));
    await page.close();
  }

  // --- E03 DIRETOR aprova pela tela ---------------------------------------------------------
  {
    const page = await novaPagina(browser);
    await login(page, U.DIRETOR);
    await page.goto(`${BASE}/optimap/ces/${idNick}`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="ces-aprovar"]', { timeout: 20000 });
    await page.click('[data-testid="ces-aprovar"]');
    await page.click('[data-testid="imp-modal-confirmar"]');
    await page.waitForSelector('[data-testid="ces-mensagem"]', { timeout: 60000 });
    const msg = await page.locator('[data-testid="ces-mensagem"]').textContent();
    check('E03a DIRETOR aprova: 5.341 novas', /5\.341 novas/.test(msg), msg);
    await page.waitForSelector('[data-testid="ces-conferencia"]');
    const linhas = await page.locator('[data-testid="ces-conferencia"] tbody tr').allTextContents();
    console.log('      conferência NICK:', linhas.join(' || '));
    check('E03b conferência mostra Cianorte com a tabela do CES (2.838)', linhas.some((l) => /Cianorte/i.test(l) && /2\.838/.test(l)), linhas.join(' | '));
    await page.screenshot({ path: path.join(SHOTS, 'f5_02_ces_nick_aplicada.png'), fullPage: true });
    await page.close();
  }

  // --- AYOTECH pela API ---------------------------------------------------------------------
  const ayo = await apiUpload(U.ADMINISTRADOR, '/api/optimap/ces', ARQ_AYO);
  const rAyo = await apiPost(U.ADMINISTRADOR, `/api/optimap/ces/${ayo.id}/aprovar`, {});
  check('E04 AYOTECH aplicada: 391 novas', rAyo.novas === 391, JSON.stringify(rAyo));
  const ambas = Number(sql("select count(*) from (select poste_referencia_id from gis_ocupacoes where estado='ATIVA' group by 1 having count(distinct empresa_id)=2) z"));
  check('E05 postes com as duas empresas = 55', ambas === 55, String(ambas));

  // --- E06 mapa: cores, legenda, filtro por empresa -----------------------------------------
  const E_AYO = sql("select id from gis_empresas where cnpj='30353855000167'");
  // centro: um poste ocupado pelas duas empresas
  const [lon, lat, idComum] = sql("select ST_X(r.geom)||','||ST_Y(r.geom)||','||r.id_externo from gis_postes_referencia r where r.id in (select poste_referencia_id from gis_ocupacoes where estado='ATIVA' group by 1 having count(distinct empresa_id)=2) order by r.id_externo limit 1").split(',');
  {
    const page = await novaPagina(browser);
    await login(page, U.COMERCIAL);
    await abrirMapa(page, [Number(lon), Number(lat)], 16.5);
    const c1 = await contarCategorias(page);
    console.log('      categorias renderizadas (todas):', JSON.stringify(c1._cats));
    check('E06a legenda com 6 categorias e filtro de empresa', await page.locator('[data-testid="optimap-legenda-categorias"] li').count() === 6 && await page.locator('[data-testid="optimap-filtro-empresa"] option').count() === 3);
    check('E06b há postes azuis (projeto aprovado) no mapa', (c1._cats.PROJETO_APROVADO || 0) > 0, JSON.stringify(c1._cats));
    await page.screenshot({ path: path.join(SHOTS, 'f5_03_mapa_cores_todas.png') });
    // só projeto aprovado
    for (const cat of ['SEM_PROJETO', 'INDISPONIVEL', 'POSSIVEL', 'DISPONIVEL', 'OUTRO']) await page.uncheck(`[data-testid="toggle-categoria-${cat}"]`);
    await page.waitForTimeout(600);
    const c2 = await contarCategorias(page);
    check('E06c desmarcar categorias esconde os postes delas', c2.total === (c1._cats.PROJETO_APROVADO || 0) && Object.keys(c2._cats).join() === 'PROJETO_APROVADO', JSON.stringify(c2._cats));
    await page.screenshot({ path: path.join(SHOTS, 'f5_04_mapa_so_aprovados.png') });
    await page.selectOption('[data-testid="optimap-filtro-empresa"]', E_AYO);
    await page.waitForTimeout(600);
    const azuisAyo = await page.evaluate((e) => window.__optimapMap.queryRenderedFeatures({ layers: ['om-ref'] }).filter((f) => (f.properties.emp_ap || '').includes(`|${e}|`)).length, E_AYO);
    const c3 = await contarCategorias(page);
    check('E06d filtro AYOTECH: só os postes aprovados dela continuam azuis', c3.total === azuisAyo && azuisAyo > 0 && azuisAyo < c2.total, `${c3.total} vs ${azuisAyo} (todas: ${c2.total})`);
    await page.screenshot({ path: path.join(SHOTS, 'f5_05_mapa_filtro_ayotech.png') });
    // restaura
    await page.selectOption('[data-testid="optimap-filtro-empresa"]', '');
    for (const cat of ['SEM_PROJETO', 'INDISPONIVEL', 'POSSIVEL', 'DISPONIVEL', 'OUTRO']) await page.check(`[data-testid="toggle-categoria-${cat}"]`);
    // clica no poste compartilhado → painel com as duas empresas, sem botão de marcar (COMERCIAL)
    await page.evaluate(({ lon, lat }) => window.__optimapMap.jumpTo({ center: [lon, lat], zoom: 18 }), { lon: Number(lon), lat: Number(lat) });
    await page.waitForFunction('window.__optimapMap.areTilesLoaded() && window.__optimapMap.loaded()', null, { timeout: 30000 });
    await page.waitForTimeout(500);
    await clicarPoste(page, Number(lon), Number(lat), idComum);
    await page.waitForSelector('[data-testid="painel-ocupacoes"]', { timeout: 20000 });
    const ocup = await page.locator('[data-testid="ocupacao"]').allTextContents();
    check('E06e popup do poste: NICK e AYOTECH com UC', ocup.length === 2 && ocup.some((t) => /515903403178/.test(t)) && ocup.some((t) => /638231603159/.test(t)), ocup.join(' | '));
    check('E06f COMERCIAL não vê “Marcar ocupado sem projeto”', await page.locator('[data-testid="ocupacao-marcar"]').count() === 0);
    await page.screenshot({ path: path.join(SHOTS, 'f5_06_painel_duas_empresas.png') });
    check('E06g sem erros de página', page.__erros.length === 0, page.__erros.join(' | '));
    await page.close();
  }

  // --- E07 ENGENHARIA marca "ocupado sem projeto" num poste livre --------------------------
  {
    const [lon2, lat2, idExt] = sql(`select ST_X(r.geom)||','||ST_Y(r.geom)||','||r.id_externo from gis_postes_referencia r
       where not exists (select 1 from gis_ocupacoes o where o.poste_referencia_id=r.id)
         and not exists (select 1 from gis_postes_referencia x where x.id<>r.id and ST_DWithin(x.geom::geography, r.geom::geography, 15))
       order by ST_Distance(r.geom, ST_SetSRID(ST_MakePoint(${Number(lon)},${Number(lat)}),4326)) limit 1`).split(',');
    const page = await novaPagina(browser);
    await login(page, U.ENGENHARIA);
    await abrirMapa(page, [Number(lon2), Number(lat2)], 18);
    await clicarPoste(page, Number(lon2), Number(lat2), idExt);
    await page.waitForSelector('[data-testid="ocupacao-marcar"]', { timeout: 20000 });
    await page.click('[data-testid="ocupacao-marcar"]');
    await page.fill('[data-testid="form-ocupacao-motivo"]', 'E2E: cabo existente sem projeto');
    await page.click('[data-testid="form-ocupacao-confirmar"]');
    await page.waitForSelector('.om-ocupacao-sem_projeto', { timeout: 20000 });
    check('E07a marcação aparece no painel', true);
    await page.waitForFunction((id) => window.__optimapMap.queryRenderedFeatures({ layers: ['om-ref'] }).some((f) => f.properties.id_externo === id && f.properties.categoria === 'SEM_PROJETO'), idExt, { timeout: 20000 })
      .then(() => check('E07b poste fica vermelho no mapa (tile recarregado)', true))
      .catch(() => check('E07b poste fica vermelho no mapa (tile recarregado)', false));
    await page.screenshot({ path: path.join(SHOTS, 'f5_07_marcacao_sem_projeto.png') });
    // encerra
    await page.click('[data-testid="ocupacao-encerrar"]');
    await page.fill('[data-testid="form-ocupacao-motivo"]', 'E2E: marcado por teste');
    await page.click('[data-testid="form-ocupacao-confirmar"]');
    await page.waitForSelector('.om-historico-ocupacoes', { timeout: 20000 });
    check('E07c encerrar mantém histórico', Number(sql(`select count(*) from gis_ocupacoes where id_externo='${idExt}' and estado='ENCERRADA'`)) === 1);
    check('E07d sem erros de página', page.__erros.length === 0, page.__erros.join(' | '));
    await page.close();
  }

  // --- E08 ADMIN: empresas + conferência ----------------------------------------------------
  {
    const page = await novaPagina(browser);
    await login(page, U.ADMINISTRADOR);
    await page.goto(`${BASE}/optimap/empresas`, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('[data-testid="emp-item"]', { timeout: 20000 });
    check('E08a ADMIN vê “Nova empresa”', await page.locator('[data-testid="emp-nova"]').count() === 1);
    await page.locator('[data-testid="emp-conferir"]').first().click();
    await page.waitForSelector('[data-testid="ces-conferencia"]', { timeout: 20000 });
    check('E08b conferência abre na tela de empresas', true);
    await page.screenshot({ path: path.join(SHOTS, 'f5_08_empresas.png'), fullPage: true });
    await page.close();
  }

  await browser.close();
  console.log(`\n== RESULTADO E2E Fase 5: ${PASS} passaram, ${FAIL} falharam ==`);
  if (FAIL) { falhas.forEach((f) => console.log(`  - ${f}`)); process.exit(1); }
})().catch((e) => { console.error(e); process.exit(1); });
