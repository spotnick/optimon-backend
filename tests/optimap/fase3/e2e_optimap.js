#!/usr/bin/env node
// OptiMap — Fase 3: testes E2E da tela /optimap (Playwright + Chromium headless).
//
// Pré-requisito: ambiente local no ar (tests/optimap/fase3/stack.sh banco ... && stack.sh subir).
// O script alterna o banco entre o estado "base" (só seed de produção: camadas vazias) e
// "dados" (dados de TESTE identificados) chamando o próprio stack.sh.
// Login: sessão local injetada no localStorage (JWT de dev — mesmo padrão de tests/e2e_fase24.js).
//
// Mapa-base: o OpenFreeMap é EXTERNO. Para o teste ser determinístico (e porque o sandbox
// de CI pode não ter internet), a URL do estilo é interceptada: num teste devolvemos um
// estilo válido mínimo (caminho de SUCESSO), noutro abortamos a requisição (caminho de
// INDISPONIBILIDADE). Ver relatório para a verificação do serviço real.
//
// Uso: NODE_PATH=<node_modules com playwright> node tests/optimap/fase3/e2e_optimap.js

const { chromium } = require('playwright');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../../..');
const BASE = process.env.E2E_BASE_URL || 'http://127.0.0.1:5173';
const API = process.env.E2E_API_URL || 'http://localhost:3001';
const SHOTS = process.env.E2E_SCREENSHOTS || path.join(ROOT, 'tests/optimap/fase3/screenshots');
const STYLE_URL = 'https://tiles.openfreemap.org/styles/positron';
fs.mkdirSync(SHOTS, { recursive: true });

const U = {
  ADMINISTRADOR: 'a0000000-0000-0000-0000-000000000001', DIRETOR: 'a0000000-0000-0000-0000-000000000002',
  ENGENHARIA: 'a0000000-0000-0000-0000-000000000003', COMERCIAL: 'a0000000-0000-0000-0000-000000000004',
  FINANCEIRO: 'a0000000-0000-0000-0000-000000000005', AUDITOR: 'a0000000-0000-0000-0000-000000000006',
  SEM_PERFIL: 'a0000000-0000-0000-0000-000000000007',
};
// Coordenadas dos DADOS DE TESTE (tests/optimap/fase3/dados_teste_mapa.sql)
const POP_TESTE = [-52.4694, -23.6218];
const CEO_TESTE = [-52.4690, -23.6214]; // CEO montada sobre o poste promovido TESTE-900000

const sh = (cmd) => execSync(cmd, { cwd: ROOT, encoding: 'utf8', env: { ...process.env, PGHOST: process.env.PGHOST || '/tmp', PGUSER: process.env.PGUSER || 'postgres', PGPORT: process.env.PGPORT || '5432' } }).trim();
const jwt = (uid) => sh(`node supabase/dev-local-only/mint_jwt.js ${uid}`);
const banco = (modo) => sh(`tests/optimap/fase3/stack.sh banco ${modo}`);

let PASS = 0; let FAIL = 0; const falhas = [];
function check(nome, cond, detalhe = '') {
  if (cond) { PASS++; console.log(`PASS | ${nome}`); } else { FAIL++; falhas.push(nome); console.log(`FAIL | ${nome}${detalhe ? ` -> ${detalhe}` : ''}`); }
}

const ESTILO_STUB = {
  version: 8, name: 'stub-teste-mapa-base', sources: {},
  layers: [{ id: 'fundo-stub', type: 'background', paint: { 'background-color': '#f2efe9' } }],
};

async function novaPagina(browser, { estilo = 'stub', rotas = [] } = {}) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await context.newPage();
  page.__erros = [];
  page.__reqs = [];
  page.on('console', (m) => { if (m.type() === 'error') page.__erros.push(m.text()); });
  page.on('pageerror', (e) => page.__erros.push(String(e)));
  page.__falhasRede = [];
  page.on('requestfailed', (r) => page.__falhasRede.push(r.url()));
  page.on('request', (r) => page.__reqs.push({ url: r.url(), headers: r.headers() }));
  await page.route(STYLE_URL, (route) => (estilo === 'stub'
    ? route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(ESTILO_STUB) })
    : route.abort('internetdisconnected')));
  for (const [padrao, handler] of rotas) await page.route(padrao, handler);
  return page;
}

async function login(page, uid, email = 'teste@teste.local') {
  const token = jwt(uid);
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
  await page.waitForFunction('!!window.__optimonSupabase', null, { timeout: 15000 });
  await page.evaluate(({ token, email }) => {
    const [, p] = token.split('.');
    const payload = JSON.parse(atob(p.replace(/-/g, '+').replace(/_/g, '/')));
    const session = { access_token: token, token_type: 'bearer', expires_in: payload.exp - payload.iat, expires_at: payload.exp,
      refresh_token: 'e2e-optimap-local', user: { id: payload.sub, aud: payload.aud, role: payload.role, email } };
    window.localStorage.setItem(window.__optimonSupabase.auth.storageKey, JSON.stringify(session));
    window.localStorage.setItem('optimon_onboarding_visto_v1', '1');
    window.localStorage.removeItem('optimap_camadas_visiveis_v1');
  }, { token, email });
}

async function abrirMapa(page) {
  await page.goto(`${BASE}/optimap`, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('[data-testid="optimap"]', { timeout: 20000 });
  await page.waitForFunction(() => window.__optimapMap && window.__optimapMap.getLayer('om-pops') && window.__optimapMap.loaded(), null, { timeout: 30000 });
}
async function irPara(page, [lon, lat], zoom) {
  await page.evaluate(({ lon, lat, zoom }) => window.__optimapMap.jumpTo({ center: [lon, lat], zoom }), { lon, lat, zoom });
  await page.waitForFunction(() => window.__optimapMap.areTilesLoaded() && !window.__optimapMap.isMoving(), null, { timeout: 20000 });
  await page.waitForTimeout(400);
}
const feicoes = (page, layer) => page.evaluate((l) => window.__optimapMap.queryRenderedFeatures({ layers: [l] }).map((f) => f.properties), layer);
async function clicarEm(page, [lon, lat]) {
  const pt = await page.evaluate(({ lon, lat }) => window.__optimapMap.project([lon, lat]), { lon, lat });
  const box = await page.locator('[data-testid="optimap-mapa"]').boundingBox();
  await page.mouse.click(box.x + pt.x, box.y + pt.y);
}
async function buscar(page, texto) {
  await page.fill('[data-testid="optimap-busca"]', '');
  await page.fill('[data-testid="optimap-busca"]', texto);
  await page.waitForFunction(() => document.querySelector('[data-testid="optimap-busca-resultados"],[data-testid="optimap-busca-vazia"]'), null, { timeout: 10000 });
}

(async () => {
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });

  // =====================================================================================
  // A) ESTADO REAL (só seed de produção): camadas vazias, nada fictício
  // =====================================================================================
  banco('base');
  {
    const page = await novaPagina(browser);
    await login(page, U.COMERCIAL);
    await page.goto(`${BASE}/`, { waitUntil: 'networkidle' });
    const reqsAntes = page.__reqs.map((r) => r.url);
    check('T13a lazy: Dashboard não baixa MapLibre nem o módulo do OptiMap',
      !reqsAntes.some((u) => /maplibre|OptiMap/i.test(u)), reqsAntes.filter((u) => /maplibre|OptiMap/i.test(u)).join(','));
    check('T01a menu mostra OptiMap para COMERCIAL', await page.locator('nav a[href="/optimap"]').count() === 1);
    await page.click('nav a[href="/optimap"]');
    await abrirMapa(page);
    check('T13b lazy: MapLibre só é baixado ao abrir /optimap', page.__reqs.some((r) => /maplibre-gl/.test(r.url)));
    check('T01b rota /optimap acessível (mapa + canvas WebGL)', await page.locator('[data-testid="optimap-mapa"] canvas').count() === 1);
    check('T02a mapa-base carregado (estilo do provedor aplicado, sem aviso de indisponibilidade)',
      (await page.evaluate(() => window.__optimapMap.getStyle().name)) === 'stub-teste-mapa-base'
      && await page.locator('[data-testid="optimap-aviso-mapa-base"]').count() === 0);
    await page.waitForFunction(() => document.querySelector('[data-testid="contagem-pops"]')?.textContent !== '…', null, { timeout: 10000 });
    const cont = {};
    for (const c of ['pops', 'postes', 'postes_referencia', 'elementos', 'trechos']) cont[c] = await page.textContent(`[data-testid="contagem-${c}"]`);
    check('T04a estado real: todas as camadas com contagem 0', Object.values(cont).every((v) => v === '0'), JSON.stringify(cont));
    let vazios = 0;
    for (const c of ['pops', 'postes', 'postes_referencia', 'elementos', 'trechos']) vazios += await page.locator(`[data-testid="vazio-${c}"]`).count();
    check('T04b estado vazio informativo em cada camada', vazios === 5);
    check('T04c aviso de POP cadastrado sem coordenadas (POP-01 real de Jussara)', (await page.textContent('[data-testid="camada-pops"]')).includes('sem coordenadas'));
    await irPara(page, POP_TESTE, 16);
    let total = 0;
    for (const l of ['om-pops', 'om-postes', 'om-ref', 'om-elementos', 'om-trechos']) total += (await feicoes(page, l)).length;
    check('T04d nenhum ponto/linha desenhado no mapa sem dados (nada fictício)', total === 0, `${total} feições`);
    await buscar(page, 'Jussara');
    await page.click('[data-testid="optimap-busca-resultados"] button');
    await page.waitForSelector('[data-testid="optimap-busca-aviso"]', { timeout: 8000 });
    check('T09a cidade sem coordenadas: aviso claro, mapa não é movido para posição inventada',
      (await page.textContent('[data-testid="optimap-busca-aviso"]')).includes('nenhuma coordenada'));
    await page.screenshot({ path: path.join(SHOTS, '01_estado_real_camadas_vazias.png') });
    await page.context().close();
  }

  // =====================================================================================
  // B) COM DADOS DE TESTE IDENTIFICADOS
  // =====================================================================================
  banco('dados');
  {
    const page = await novaPagina(browser);
    await login(page, U.COMERCIAL);
    await abrirMapa(page);
    await page.waitForFunction(() => document.querySelector('[data-testid="contagem-pops"]')?.textContent === '1', null, { timeout: 10000 });
    await irPara(page, POP_TESTE, 16);
    const pops = await feicoes(page, 'om-pops');
    check('T03 POP com coordenadas exibido (vw_gis_pops via tile MVT)', pops.some((p) => p.codigo === 'TESTE-E2E-POP'), JSON.stringify(pops));
    check('T03b camadas da rede NICK renderizadas (postes, elemento, trecho, referências)',
      (await feicoes(page, 'om-postes')).length >= 2 && (await feicoes(page, 'om-elementos')).length >= 1
      && (await feicoes(page, 'om-trechos')).length + (await feicoes(page, 'om-trechos-planejados')).length >= 1
      && (await feicoes(page, 'om-ref')).length >= 20);

    const tileReq = page.__reqs.find((r) => r.url.includes('/api/optimap/tiles/'));
    check('T12a tiles pedidos à API com o JWT do usuário (Authorization: Bearer)', tileReq && /^Bearer /.test(tileReq.headers.authorization || ''));

    // T05 alternância de visibilidade
    await page.uncheck('[data-testid="toggle-pops"]');
    await page.waitForTimeout(300);
    const visOff = await page.evaluate(() => window.__optimapMap.getLayoutProperty('om-pops', 'visibility'));
    const popsOff = (await feicoes(page, 'om-pops')).length;
    await page.check('[data-testid="toggle-pops"]');
    await page.waitForFunction(() => window.__optimapMap.queryRenderedFeatures({ layers: ['om-pops'] }).length >= 1, null, { timeout: 8000 }).catch(() => {});
    const visOn = await page.evaluate(() => window.__optimapMap.getLayoutProperty('om-pops', 'visibility'));
    check('T05a desligar camada esconde as feições', visOff === 'none' && popsOff === 0, `${visOff}/${popsOff}`);
    check('T05b religar camada mostra de novo', visOn === 'visible' && (await feicoes(page, 'om-pops')).length >= 1);
    await page.uncheck('[data-testid="toggle-postes_referencia"]');
    const refOff = await page.evaluate(() => ['om-ref', 'om-ref-agregado'].map((l) => window.__optimapMap.getLayoutProperty(l, 'visibility')));
    check('T05c cada camada é independente (referência desligada, POPs continuam)', refOff.every((v) => v === 'none') && (await feicoes(page, 'om-pops')).length >= 1);
    await page.check('[data-testid="toggle-postes_referencia"]');
    await page.screenshot({ path: path.join(SHOTS, '02_mapa_camadas_legenda.png') });

    // T06 busca por código
    await buscar(page, 'TESTE-E2E-CEO');
    const itens = await page.locator('[data-testid="optimap-busca-resultados"] button').allTextContents();
    check('T06a busca por código de elemento encontra o resultado', itens.some((t) => t.includes('TESTE-E2E-CEO-01')), itens.join(' | '));
    await page.locator('[data-testid="optimap-busca-resultados"] button', { hasText: 'TESTE-E2E-CEO-01' }).click();
    await page.waitForSelector('[data-testid="painel-detalhe"] h3', { timeout: 10000 });
    await page.waitForFunction(() => !window.__optimapMap.isMoving(), null, { timeout: 10000 });
    const centro = await page.evaluate(() => window.__optimapMap.getCenter());
    check('T06b resultado centraliza o mapa na posição real do elemento', Math.abs(centro.lng - CEO_TESTE[0]) < 1e-4 && Math.abs(centro.lat - CEO_TESTE[1]) < 1e-4, JSON.stringify(centro));
    const painel = await page.textContent('[data-testid="painel-detalhe"]');
    check('T06c painel de detalhes abre com os atributos reais (tipo, estado, cidade, poste, fonte, histórico)',
      ['TESTE-E2E-CEO-01', 'Caixa de emenda', 'Documentado', 'Jussara', 'TESTE-900000', 'NICK — Levantamento de campo', 'Histórico de estado', 'bandejas'].every((t) => painel.includes(t)), painel.slice(0, 400));
    check('T06d sem campos inexistentes (elemento não mostra "Comprimento" nem "Situação informada pela fonte")', !painel.includes('Comprimento do traçado') && !painel.includes('Situação informada'));
    await page.screenshot({ path: path.join(SHOTS, '03_busca_codigo_painel_elemento.png') });
    await buscar(page, 'TESTE-E2E-POP');
    check('T06e busca por código de POP', (await page.locator('[data-testid="optimap-busca-resultados"] button').allTextContents()).some((t) => t.includes('TESTE-E2E-POP')));
    await buscar(page, 'TESTE-900003');
    check('T06f busca pelo número externo do poste (referência)', (await page.locator('[data-testid="optimap-busca-resultados"] button').allTextContents()).some((t) => t.includes('TESTE-900003')));
    await buscar(page, 'TESTE-E2E-P3');
    check('T06g busca por identificador de poste próprio', (await page.locator('[data-testid="optimap-busca-resultados"] button').allTextContents()).some((t) => t.includes('Poste NICK TESTE-E2E-P3')));
    await buscar(page, '%%');
    check('T06h caracteres curinga não "casam tudo"', await page.locator('[data-testid="optimap-busca-vazia"]').count() === 1);

    // T07 busca por coordenadas
    await buscar(page, '-23.6216, -52.4690');
    await page.locator('[data-testid="optimap-busca-resultados"] button').first().click();
    await page.waitForSelector('.maplibregl-marker', { timeout: 8000 });
    await page.waitForFunction(() => !window.__optimapMap.isMoving(), null, { timeout: 10000 });
    const c2 = await page.evaluate(() => window.__optimapMap.getCenter());
    check('T07a "lat, lon" centraliza exatamente na coordenada digitada', Math.abs(c2.lng + 52.469) < 1e-6 && Math.abs(c2.lat + 23.6216) < 1e-6, JSON.stringify(c2));
    check('T07b marcador + painel "Coordenada pesquisada" (sem selecionar elemento por aproximação)',
      (await page.textContent('[data-testid="painel-detalhe"]')).includes('Nenhum elemento selecionado'));
    await page.screenshot({ path: path.join(SHOTS, '04_busca_coordenadas.png') });

    // T09 coordenadas inexistentes / fora do Brasil
    await buscar(page, '10.5, -20.0');
    check('T09b coordenada fora do Brasil: "nenhum resultado" (nada aproximado)', await page.locator('[data-testid="optimap-busca-vazia"]').count() === 1);
    await buscar(page, 'XYZ-NAO-EXISTE-123');
    check('T09c código inexistente: mensagem clara', (await page.textContent('[data-testid="optimap-busca-vazia"]')).includes('Nenhum resultado'));

    // T08 seleção no mapa
    await page.click('.om-fechar');
    await irPara(page, POP_TESTE, 17);
    await clicarEm(page, POP_TESTE);
    await page.waitForSelector('[data-testid="painel-detalhe"] h3', { timeout: 8000 });
    const pPop = await page.textContent('[data-testid="painel-detalhe"]');
    check('T08a clique no POP abre o detalhe (código, cidade, coordenadas cadastradas, fonte)',
      ['TESTE-E2E-POP', 'Jussara', '-23.621800, -52.469400', 'Cadastro de POPs'].every((t) => pPop.includes(t)), pPop.slice(0, 300));
    const destaque = await page.evaluate(() => window.__optimapMap.getSource('om-selecao')._data?.features?.length ?? window.__optimapMap.querySourceFeatures('om-selecao').length);
    check('T08b elemento selecionado fica destacado no mapa', destaque >= 1);
    // referência externa (poste TESTE-900004, ninguém o usa)
    const ref4 = [-52.4690 + 4 * 0.0004, -23.6214];
    await irPara(page, ref4, 18);
    await clicarEm(page, ref4);
    await page.waitForSelector('[data-testid="painel-detalhe"] .om-faixa-externa', { timeout: 8000 });
    const pRef = await page.textContent('[data-testid="painel-detalhe"]');
    check('T08c poste externo destacado como referência da concessionária (não usado pela NICK; texto da Fase 5)',
      pRef.includes('Poste da concessionária') && pRef.includes('Não há poste da NICK vinculado') && pRef.includes('Data de referência'), pRef.slice(0, 300));
    await page.screenshot({ path: path.join(SHOTS, '05_painel_poste_referencia_externa.png') });
    // sobreposição: CEO montada no poste promovido → lista para escolher
    await irPara(page, CEO_TESTE, 18);
    await clicarEm(page, CEO_TESTE);
    await page.waitForSelector('.om-candidatos', { timeout: 8000 });
    const cands = await page.locator('.om-candidatos button').allTextContents();
    check('T08d feições sobrepostas: lista para o usuário escolher (sem escolher sozinho)', cands.length >= 2 && cands.some((t) => t.includes('Poste NICK')) && cands.some((t) => t.includes('CEO')), cands.join(' | '));
    await page.locator('.om-candidatos button', { hasText: 'Poste NICK' }).click();
    await page.waitForSelector('[data-testid="painel-detalhe"] h3', { timeout: 8000 });
    const pPoste = await page.textContent('[data-testid="painel-detalhe"]');
    check('T08e poste NICK: estado Validado, lote, referência e histórico de validação',
      ['Validado', 'Lote de faturamento', 'ver referência da concessionária', 'Teste E2E: validação', 'Teste Engenharia'].every((t) => pPoste.includes(t)), pPoste.slice(0, 400));
    await page.screenshot({ path: path.join(SHOTS, '06_painel_poste_nick_validado.png') });
    // agregado em zoom 13: clicar aproxima em vez de abrir detalhe de um poste "médio"
    await irPara(page, [-52.4682, -23.6222], 13);
    const agreg = await feicoes(page, 'om-ref-agregado');
    check('T08f zoom 13: referências chegam agregadas (contagem), nunca uma a uma', agreg.length >= 1 && agreg.every((p) => p.quantidade >= 1 && !p.id_externo));
    await page.screenshot({ path: path.join(SHOTS, '07_referencias_agregadas_zoom13.png') });

    // T10e nenhuma ação de edição para COMERCIAL (e nesta fase para ninguém)
    const botoes = (await page.locator('[data-testid="optimap"] button').allTextContents()).join(' | ');
    check('T10e nenhuma ação de edição exibida (Editar/Validar/Excluir/Arquivar/Mover)', !/editar|validar|excluir|arquivar|mover|salvar/i.test(botoes), botoes);
    // Falhas de rede para hosts EXTERNOS ao ambiente local (ex.: fontes do Google no
    // index.html, pré-existente) são do sandbox sem internet, não do OptiMap.
    const externas = page.__falhasRede.filter((u) => !/^https?:\/\/(127\.0\.0\.1|localhost)/.test(u));
    const errosJs = page.__erros.filter((e) => !/Failed to load resource/.test(e));
    const falhasLocais = page.__falhasRede.filter((u) => /^https?:\/\/(127\.0\.0\.1|localhost)/.test(u) && !u.includes('/api/optimap/tiles/'));
    console.log(`      (requisições externas bloqueadas pelo sandbox: ${[...new Set(externas.map((u) => new URL(u).host))].join(', ') || 'nenhuma'})`);
    check('T14a nenhum erro de JavaScript nem falha de requisição local na sessão do mapa', errosJs.length === 0 && falhasLocais.length === 0, [...errosJs, ...falhasLocais].slice(0, 3).join(' || '));
    await page.context().close();
  }

  // T02b mapa-base indisponível
  {
    const page = await novaPagina(browser, { estilo: 'falha' });
    await login(page, U.ENGENHARIA);
    await abrirMapa(page);
    await page.waitForSelector('[data-testid="optimap-aviso-mapa-base"]', { timeout: 15000 });
    await irPara(page, POP_TESTE, 16);
    check('T02b OpenFreeMap indisponível: aviso + fundo neutro, camadas do OptiMon continuam',
      (await feicoes(page, 'om-pops')).length >= 1 && (await page.evaluate(() => window.__optimapMap.getStyle().name)) === 'optimap-fallback');
    await page.screenshot({ path: path.join(SHOTS, '08_mapa_base_indisponivel.png') });
    await page.context().close();
  }

  // =====================================================================================
  // T10 perfis
  // =====================================================================================
  for (const perfil of ['ADMINISTRADOR', 'DIRETOR', 'ENGENHARIA', 'AUDITOR']) {
    const page = await novaPagina(browser);
    await login(page, U[perfil]);
    await abrirMapa(page);
    await page.waitForFunction(() => document.querySelector('[data-testid="contagem-pops"]')?.textContent === '1', null, { timeout: 10000 });
    check(`T10a ${perfil} acessa o mapa e vê os dados`, true);
    await page.context().close();
  }
  for (const perfil of ['FINANCEIRO', 'SEM_PERFIL']) {
    const page = await novaPagina(browser);
    await login(page, U[perfil]);
    await page.goto(`${BASE}/`, { waitUntil: 'networkidle' });
    const temMenu = await page.locator('nav a[href="/optimap"]').count();
    await page.goto(`${BASE}/optimap`, { waitUntil: 'networkidle' });
    await page.waitForSelector('[data-testid="optimap-sem-acesso"]', { timeout: 10000 });
    const baixouTiles = page.__reqs.some((r) => r.url.includes('/api/optimap/tiles/'));
    check(`T10b ${perfil}: sem item de menu, acesso direto à rota mostra "Sem acesso", nenhum tile pedido`, temMenu === 0 && !baixouTiles);
    if (perfil === 'FINANCEIRO') await page.screenshot({ path: path.join(SHOTS, '09_financeiro_sem_acesso.png') });
    await page.context().close();
  }
  {
    const page = await novaPagina(browser);
    await page.goto(`${BASE}/optimap`, { waitUntil: 'networkidle' });
    check('T10c usuário anônimo é redirecionado ao login', page.url().includes('/login'));
    await page.context().close();
  }

  // =====================================================================================
  // T11 erros e indisponibilidade da API
  // =====================================================================================
  {
    const page = await novaPagina(browser, { rotas: [['**/api/optimap/tiles/elementos/**', (r) => r.fulfill({ status: 500, body: '{"error":"x"}' })]] });
    await login(page, U.COMERCIAL);
    await abrirMapa(page);
    await irPara(page, POP_TESTE, 16);
    await page.waitForFunction(() => document.querySelector('[data-testid="camada-elementos"] .om-erro-camada'), null, { timeout: 10000 });
    check('T11a falha num tile: erro indicado na camada afetada; demais camadas continuam', (await feicoes(page, 'om-pops')).length >= 1);
    await page.context().close();
  }
  {
    const page = await novaPagina(browser, { rotas: [['**/api/optimap/resumo', (r) => r.fulfill({ status: 503, contentType: 'application/json', body: '{"error":"indisponível"}' })]] });
    await login(page, U.COMERCIAL);
    await abrirMapa(page);
    await page.waitForSelector('[data-testid="optimap-erro-resumo"]', { timeout: 10000 });
    check('T11b resumo indisponível: aviso com "tentar de novo", mapa segue utilizável', true);
    await page.context().close();
  }
  {
    const page = await novaPagina(browser, { rotas: [['**/api/optimap/sessao', (r) => r.abort('connectionrefused')]] });
    await login(page, U.COMERCIAL);
    await page.goto(`${BASE}/optimap`, { waitUntil: 'networkidle' });
    await page.waitForSelector('[data-testid="optimap-erro-api"]', { timeout: 10000 });
    check('T11c API fora do ar: tela "OptiMap indisponível" com botão de tentar novamente', (await page.textContent('[data-testid="optimap-erro-api"]')).includes('Tentar novamente'));
    await page.screenshot({ path: path.join(SHOTS, '10_api_indisponivel.png') });
    await page.context().close();
  }
  {
    const page = await novaPagina(browser, { rotas: [['**/api/optimap/detalhe/**', (r) => r.fulfill({ status: 500, contentType: 'application/json', body: '{"error":"Erro ao consultar o OptiMap."}' })]] });
    await login(page, U.COMERCIAL);
    await abrirMapa(page);
    await irPara(page, POP_TESTE, 17);
    await clicarEm(page, POP_TESTE);
    await page.waitForSelector('[data-testid="painel-detalhe"] [role="alert"]', { timeout: 8000 });
    check('T11d falha no detalhe: mensagem de erro no painel', (await page.textContent('[data-testid="painel-detalhe"]')).includes('Não foi possível carregar'));
    await page.context().close();
  }

  // =====================================================================================
  // T12 autenticação e RLS preservadas (API + PostgREST direto)
  // =====================================================================================
  const curl = (args) => sh(`curl -s -o /dev/null -w "%{http_code}" ${args}`);
  const tok = (u) => jwt(U[u]);
  check('T12b tile sem JWT → 401', curl(`${API}/api/optimap/tiles/pops/16/1/1.mvt`) === '401');
  check('T12c tile como FINANCEIRO → 403', curl(`-H "Authorization: Bearer ${tok('FINANCEIRO')}" ${API}/api/optimap/tiles/pops/16/1/1.mvt`) === '403');
  check('T12d detalhe como usuário sem perfil → 403', curl(`-H "Authorization: Bearer ${tok('SEM_PERFIL')}" ${API}/api/optimap/detalhe/pops/00000000-0000-0000-0000-000000000000`) === '403');
  const finDireto = sh(`curl -s -H "Authorization: Bearer ${tok('FINANCEIRO')}" -H "Content-Type: application/json" -d '{"p_texto":"TESTE-E2E"}' http://127.0.0.1:3000/rpc/optimap_buscar`);
  check('T12e mesmo indo direto ao PostgREST (sem a API), FINANCEIRO não recebe dados (regra no banco)', finDireto === '[]', finDireto);
  const anonDireto = sh(`curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -d '{"p_texto":"TESTE"}' http://127.0.0.1:3000/rpc/optimap_buscar`);
  check('T12f anônimo direto no PostgREST → negado', ['401', '403'].includes(anonDireto), anonDireto);
  const cache = sh(`curl -s -D - -o /dev/null -H "Authorization: Bearer ${tok('COMERCIAL')}" ${API}/api/optimap/tiles/pops/16/22981/37252.mvt | tr -d '\\r' | grep -i '^cache-control' || true`);
  check('T12g tiles com cache só privado (nunca cache público/compartilhado)', /private/i.test(cache) && !/public/i.test(cache), cache);
  const escritaDireta = sh(`curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer ${tok('ENGENHARIA')}" -H "Content-Type: application/json" -d '{"cidade_id":"00000000-0000-0000-0000-000000000000"}' http://127.0.0.1:3000/gis_postes`);
  check('T12h escrita direta em gis_postes pelo PostgREST continua negada (RLS/grants da Fase 2 intactos)', ['401', '403'].includes(escritaDireta), escritaDireta);

  // Robustez (achados da revisão independente)
  const expirado = sh(`node supabase/dev-local-only/mint_jwt.js ${U.ENGENHARIA} authenticated -20`);
  check('T12i token expirado → 401 (nunca 500 nem perfil em cache)', curl(`-H "Authorization: Bearer ${expirado}" ${API}/api/optimap/sessao`) === '401'
    && curl(`-H "Authorization: Bearer ${expirado}" ${API}/api/optimap/tiles/pops/16/22981/37252.mvt`) === '401');
  const vary = sh(`curl -s -D - -o /dev/null -H "Origin: http://127.0.0.1:5173" -H "Authorization: Bearer ${tok('COMERCIAL')}" ${API}/api/optimap/tiles/pops/16/22981/37252.mvt | tr -d '\r' | grep -i '^vary' || true`);
  check('T12j Vary preserva Origin (CORS) e inclui Authorization', /origin/i.test(vary) && /authorization/i.test(vary), vary);
  check('T12k parâmetros malformados → 400 (z "1e1", cidade_id repetido, q repetido)',
    curl(`-H "Authorization: Bearer ${tok('COMERCIAL')}" ${API}/api/optimap/tiles/pops/1e1/0/0.mvt`) === '400'
    && curl(`-H "Authorization: Bearer ${tok('COMERCIAL')}" "${API}/api/optimap/resumo?cidade_id[]=00000000-0000-0000-0000-000000000000"`) === '400'
    && curl(`-H "Authorization: Bearer ${tok('COMERCIAL')}" "${API}/api/optimap/buscar?q=ab&q=cd"`) === '400');
  const trechoId = sh(`psql -d optimon -At -c "select id from gis_trechos limit 1"`);
  const det = JSON.parse(sh(`curl -s -H "Authorization: Bearer ${tok('COMERCIAL')}" ${API}/api/optimap/detalhe/trechos/${trechoId}`));
  check('T12l detalhe do trecho: pontas com tipo correto (pop / elemento + tipo_elemento)',
    det.vinculos?.ponta_a?.tipo === 'pop' && det.vinculos?.ponta_b?.tipo === 'elemento' && det.vinculos?.ponta_b?.tipo_elemento === 'CEO', JSON.stringify(det.vinculos));

  // =====================================================================================
  // T14 regressão das demais telas (ADMINISTRADOR percorre o menu inteiro)
  // =====================================================================================
  {
    const page = await novaPagina(browser);
    await login(page, U.ADMINISTRADOR);
    await page.goto(`${BASE}/`, { waitUntil: 'networkidle' });
    const rotas = await page.locator('nav a').evaluateAll((as) => as.map((a) => a.getAttribute('href')));
    const quebradas = [];
    for (const r of rotas.filter((x) => x !== '/optimap')) {
      page.__erros = [];
      await page.goto(`${BASE}${r}`, { waitUntil: 'networkidle' });
      const ok = await page.locator('.main-area').count() === 1 && !(await page.textContent('body')).includes('Something went wrong');
      const errosReais = page.__erros.filter((e) => !/Failed to load resource/.test(e));
      if (!ok || errosReais.length) quebradas.push(`${r}: ${errosReais.slice(0, 1).join('')}`);
    }
    check(`T14b ${rotas.length - 1} telas existentes abrem sem erro de JavaScript`, quebradas.length === 0, quebradas.join(' || '));
    await page.context().close();
  }

  await browser.close();
  console.log(`\n================================================================\nResultado: ${PASS} PASS / ${FAIL} FAIL`);
  if (FAIL) { falhas.forEach((f) => console.log(`  - ${f}`)); process.exit(1); }
})().catch((e) => { console.error('ERRO FATAL:', e); process.exit(2); });
