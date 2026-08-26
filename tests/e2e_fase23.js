#!/usr/bin/env node
// OptiMon — Fase 2.3, seção 40 (E2E obrigatório): Login -> Cidades -> Nova Cidade ->
// cadastrar Andirá -> salvar -> criar POP -> criar cabo -> visualizar cidade ->
// Nova Simulação -> selecionar Andirá -> simular -> visualizar Pricing -> voltar
// Dashboard -> confirmar duas cidades.
//
// Pré-requisito: a pilha local (PostgREST + proxy + API) e o `npm run dev` do frontend
// (web/) já precisam estar no ar — ver tests/run_tests_fase23.sh (sobe a pilha) e
// `cd web && npm run dev` (o front). Login real via GoTrue não existe neste sandbox (sem
// projeto Supabase); como já documentado em docs/ARQUITETURA.md (seção 19 da Fase Deploy),
// os testes locais autenticam via `window.__optimonSupabase` + um JWT local
// (mint_jwt.js) — aqui simulamos exatamente o que o formulário de login faria (guarda a
// sessão, dispara onAuthStateChange), só sem precisar de senha real.
//
// Uso: NODE_PATH=/home/claude/.npm-global/lib/node_modules node tests/e2e_fase23.js

const { chromium } = require('playwright');
const { execSync } = require('child_process');

const BASE = process.env.E2E_BASE_URL || 'http://localhost:5173';
// Nome único por execução — o banco local persiste entre rodadas deste script (não é
// resetado a cada vez, ao contrário de tests/run_tests_fase23.sh), e cidades_infra tem
// unique(nome, uf); sem isso, rodar o E2E duas vezes seguidas falharia com 400.
const RUN_SUFFIX = Date.now().toString(36).toUpperCase();

function sh(cmd) {
  return execSync(cmd, { encoding: 'utf8' }).trim();
}

function mintJwt(uid) {
  return sh(`node supabase/dev-local-only/mint_jwt.js ${uid}`);
}

function uidForRole(role) {
  return sh(
    `PGPASSWORD=optimon_dev psql -h localhost -U optimon_admin -d optimon -t -A -c "select id from public.usuarios where perfil='${role}' limit 1;"`
  );
}

let PASS = 0;
let FAIL = 0;
const failures = [];
function check(name, cond, detail = '') {
  if (cond) {
    PASS++;
    console.log(`PASS | ${name}`);
  } else {
    FAIL++;
    failures.push(name);
    console.log(`FAIL | ${name}${detail ? ` -> ${detail}` : ''}`);
  }
}

(async () => {
  const uid = uidForRole('ENGENHARIA');
  const jwt = mintJwt(uid);

  const browser = await chromium.launch();
  const page = await browser.newPage();
  page.on('console', (msg) => { if (msg.type() === 'error') console.log('[browser console error]', msg.text()); });
  page.on('response', (r) => { if (r.url().includes('54321') || r.url().includes('3001')) console.log('[response]', r.status(), r.url()); });

  // ---- E2E-1: "Login" (injeta a sessão, dispara o mesmo fluxo que o formulário real) ----
  // setSession() faz o gotrue-js chamar /auth/v1/... para validar — não existe localmente
  // (só temos PostgREST local, nunca um GoTrue real, ver docs/ARQUITETURA.md seção 19).
  // Em vez disso escrevemos a sessão diretamente na mesma chave de localStorage que o
  // client usa (sb-<host>-auth-token) — é exatamente o que o SDK leria de volta no boot,
  // sem nenhuma chamada de rede, e ainda testa o app real (AuthContext, ProtectedRoute,
  // onAuthStateChange) do mesmo jeito que um login de verdade deixaria a sessão.
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
  await page.waitForFunction('!!window.__optimonSupabase', { timeout: 10000 });
  const sessionResult = await page.evaluate(async (token) => {
    const [, payloadB64] = token.split('.');
    const payload = JSON.parse(atob(payloadB64.replace(/-/g, '+').replace(/_/g, '/')));
    const storageKey = window.__optimonSupabase.auth.storageKey;
    const session = {
      access_token: token,
      token_type: 'bearer',
      expires_in: payload.exp - payload.iat,
      expires_at: payload.exp,
      refresh_token: 'e2e-fase23-local-fake-refresh',
      user: { id: payload.sub, aud: payload.aud, role: payload.role, email: 'e2e@optimon.local' },
    };
    window.localStorage.setItem(storageKey, JSON.stringify(session));
    return { storageKey, sub: payload.sub };
  }, jwt);
  // Navegação de página inteira (não SPA) — obrigatória para o supabase-js reler a sessão
  // do localStorage no boot, exatamente como aconteceria depois de um login real seguido
  // de F5, ou de abrir o app numa aba nova já autenticado.
  await page.goto(`${BASE}/`, { waitUntil: 'networkidle' });
  await page.waitForSelector('text=Dashboard', { timeout: 10000 }).catch(async () => {
    console.log('[debug] page content snapshot:', (await page.content()).slice(0, 1500));
  });
  check('E2E-1 login (sessão local injetada) chega no Dashboard', page.url() === `${BASE}/` || page.url() === `${BASE}`, `url=${page.url()} sessionResult=${JSON.stringify(sessionResult)}`);

  // ---- E2E-2: Dashboard antes de criar Andirá — memoriza quantas cidades existem ----
  await page.waitForSelector('table', { timeout: 10000 });
  const citiesBefore = await page.locator('table tbody tr').count();
  check('E2E-2 Dashboard carrega tabela de cidades', citiesBefore > 0, `linhas=${citiesBefore}`);

  // ---- E2E-3: menu "Cidades & Infraestrutura" (nunca "Jussara — PR") ----
  const jussaraNav = await page.locator('nav a', { hasText: 'Jussara' }).count();
  check('E2E-3 menu NÃO tem item fixo "Jussara — PR"', jussaraNav === 0, `ocorrencias=${jussaraNav}`);
  await page.click('nav a:has-text("Cidades & Infraestrutura")');
  await page.waitForSelector('text=Cidades & Infraestrutura', { timeout: 10000 });
  check('E2E-4 tela "Cidades & Infraestrutura" abre a partir do menu', page.url().endsWith('/cidades'));

  // ---- E2E-5: Nova Cidade -> Andirá ----
  await page.click('a:has-text("+ Nova Cidade")');
  await page.waitForSelector('text=Nova Cidade', { timeout: 10000 });
  await page.fill('input[placeholder="ex.: Andirá"]', `Andirá E2E ${RUN_SUFFIX}`);
  await page.fill('input[placeholder="PR"]', 'PR');
  await page.fill('input[placeholder="10"]', '15');
  await page.click('button:has-text("Salvar e cadastrar infraestrutura")');
  await page.waitForSelector('text=Editar Infraestrutura', { timeout: 15000 });
  check(`E2E-5 cidade Andirá E2E ${RUN_SUFFIX} criada, redireciona para Editar Infraestrutura`, page.url().includes('/editar'));

  // ---- E2E-6: criar POP ----
  await page.fill('input[placeholder="POP-02"]', 'POP-01');
  await page.fill('input[placeholder="POP-02 — Distribuição"]', 'POP-01 — Principal');
  const popButtons = page.locator('button:has-text("+ Novo POP")');
  await popButtons.click();
  await page.waitForTimeout(1500);
  const popListed = await page.locator('text=POP-01 —').count();
  check('E2E-6 POP criado e listado na tela de infraestrutura', popListed > 0);

  // ---- E2E-7: criar segmento + cabo ----
  await page.fill('.card:has(h3:has-text("Segmentos")) input >> nth=0', 'Segmento E2E');
  const segInputs = page.locator('.card:has(h3:has-text("Segmentos")) input');
  await segInputs.nth(1).fill('POP-01');
  await segInputs.nth(2).fill('Centro');
  await segInputs.nth(3).fill('5');
  await page.click('.card:has(h3:has-text("Segmentos")) button:has-text("Novo Segmento")');
  await page.waitForTimeout(1500);

  const segSelect = page.locator('.card:has(h3:has-text("Cabos")) select >> nth=0');
  await segSelect.selectOption({ label: 'Segmento E2E' });
  const popSelect = page.locator('.card:has(h3:has-text("Cabos")) select >> nth=1');
  await popSelect.selectOption({ label: 'POP-01' });
  await page.fill('.card:has(h3:has-text("Cabos")) input[placeholder="CABO-02"]', 'CABO-E2E-01');
  await page.fill('.card:has(h3:has-text("Cabos")) input[type="number"]', '12');
  await page.click('.card:has(h3:has-text("Cabos")) button:has-text("Novo Cabo")');
  await page.waitForTimeout(1500);
  const cableListed = await page.locator('text=CABO-E2E-01').count();
  check('E2E-7 segmento + cabo criados (fibras geradas automaticamente)', cableListed > 0);

  // ---- E2E-8: voltar para o detalhe da cidade ----
  await page.click('text=Voltar para o detalhe da cidade');
  await page.waitForSelector('text=Régua de Preço', { timeout: 10000 }).catch(() => {});
  const hasRegua = await page.locator('text=Régua de Preço').count();
  check(`E2E-8 detalhe da cidade mostra a Régua de Preço para Andirá E2E ${RUN_SUFFIX} (genérico, não só Jussara)`, hasRegua > 0);

  // ---- E2E-9: Nova Simulação -> selecionar Andirá -> simular ----
  await page.click('nav a:has-text("Nova Simulação")');
  await page.waitForSelector('select', { timeout: 10000 });
  const citySelect = page.locator('select').first();
  await citySelect.selectOption({ label: `Andirá E2E ${RUN_SUFFIX} — PR` });
  const simulateBtn = page.locator('button:has-text("Simular"), button:has-text("Calcular")').first();
  if (await simulateBtn.count() > 0) {
    await simulateBtn.click();
  }
  // A régua de preço só aparece depois que os 3 requests concorrentes (calculate,
  // growth-curve, horizon-table) do runSimulation resolvem — um waitForTimeout fixo de
  // 2s é uma corrida (podem não ter terminado ainda, sobretudo em Chromium headless
  // "frio"). Espera pelo próprio elemento em vez de um sleep arbitrário.
  await page.waitForSelector('.regua', { timeout: 20000 }).catch(async () => {
    console.log('[debug E2E-9] page content snapshot:', (await page.content()).slice(0, 3000));
  });
  const pricingVisible = await page.locator('text=/Piso|Recomendado|Abertura/i').count();
  check(`E2E-9 Nova Simulação calcula Pricing para Andirá E2E ${RUN_SUFFIX} (não hard-coded para Jussara)`, pricingVisible > 0);

  // ---- E2E-10: Dashboard confirma múltiplas cidades ----
  await page.click('nav a:has-text("Dashboard")');
  await page.waitForSelector('table', { timeout: 10000 });
  const citiesAfter = await page.locator('table tbody tr').count();
  check(`E2E-10 Dashboard agora lista mais cidades que antes (Jussara + Andirá E2E ${RUN_SUFFIX} + demais)`, citiesAfter > citiesBefore, `antes=${citiesBefore} depois=${citiesAfter}`);
  const andiraOnDashboard = await page.locator(`text=Andirá E2E ${RUN_SUFFIX}`).count();
  check(`E2E-11 Andirá E2E ${RUN_SUFFIX} aparece no Dashboard ao lado de Jussara, sem tratamento especial`, andiraOnDashboard > 0);

  await browser.close();

  console.log('');
  console.log('==============================================');
  console.log(`RESULTADO FINAL: ${PASS} PASS / ${FAIL} FAIL`);
  console.log('==============================================');
  if (FAIL > 0) {
    console.log('Falhas:', failures.join(', '));
    process.exit(1);
  }
})().catch((err) => {
  console.error('ERRO FATAL NO E2E:', err);
  process.exit(1);
});
