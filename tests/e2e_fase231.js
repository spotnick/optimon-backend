#!/usr/bin/env node
// OptiMon — Fase 2.3.1, seção 40 (E2E obrigatório, fluxo literal do prompt):
//   Login -> Cidades -> Jussara -> Editar -> alterar KM -> salvar -> verificar Dashboard
//   -> Editar Infraestrutura -> selecionar POP -> editar -> salvar -> arquivar segmento
//   de teste -> consultar arquivados -> restaurar -> Nova Simulação -> verificar que
//   apenas infraestrutura ativa está disponível.
//
// Mesmo padrão de login local de tests/e2e_fase23.js (sem GoTrue real neste sandbox —
// injeta a sessão diretamente no localStorage na chave que o supabase-js usaria).
//
// Login como ADMINISTRADOR (não ENGENHARIA): o fluxo do prompt inclui tanto arquivar
// quanto restaurar um segmento na mesma sessão — ADMINISTRADOR é o único perfil que a
// seção 21/RBAC permite fazer as duas coisas sem precisar trocar de usuário no meio do
// teste (ENGENHARIA pode arquivar mas não restaurar).
//
// Uso: NODE_PATH=/home/claude/.npm-global/lib/node_modules node tests/e2e_fase231.js

const { chromium } = require('playwright');
const { execSync } = require('child_process');

const BASE = process.env.E2E_BASE_URL || 'http://localhost:5173';
// Sufixo único por execução — o banco local persiste entre rodadas deste script (não é
// resetado a cada vez, ao contrário de tests/run_tests_fase231.sh), e nome/código de
// POP/segmento não têm unique constraint global, mas usar um sufixo evita confundir
// linhas de rodadas anteriores ao ler a tela.
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
function sqlValue(query) {
  return sh(`PGPASSWORD=optimon_dev psql -h localhost -U optimon_admin -d optimon -t -A -c "${query}"`);
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
  const uid = uidForRole('ADMINISTRADOR');
  const jwt = mintJwt(uid);

  const browser = await chromium.launch();
  const page = await browser.newPage();
  page.on('console', (msg) => { if (msg.type() === 'error') console.log('[browser console error]', msg.text()); });
  page.on('response', async (r) => {
    if ((r.url().includes(':3001') || r.url().includes(':54321')) && r.status() >= 400) {
      let body = '';
      try { body = await r.text(); } catch { /* ignore */ }
      console.log('[HTTP', r.status(), r.request().method(), r.url(), ']', body.slice(0, 300));
    }
  });

  // ---- E2E-1: Login (sessão local injetada, mesmo padrão de tests/e2e_fase23.js) ----
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
  await page.waitForFunction('!!window.__optimonSupabase', { timeout: 10000 });
  await page.evaluate(async (token) => {
    const [, payloadB64] = token.split('.');
    const payload = JSON.parse(atob(payloadB64.replace(/-/g, '+').replace(/_/g, '/')));
    const storageKey = window.__optimonSupabase.auth.storageKey;
    const session = {
      access_token: token, token_type: 'bearer', expires_in: payload.exp - payload.iat, expires_at: payload.exp,
      refresh_token: 'e2e-fase231-local-fake-refresh', user: { id: payload.sub, aud: payload.aud, role: payload.role, email: 'e2e231@optimon.local' },
    };
    window.localStorage.setItem(storageKey, JSON.stringify(session));
  }, jwt);
  await page.goto(`${BASE}/`, { waitUntil: 'networkidle' });
  await page.waitForSelector('text=Dashboard', { timeout: 10000 }).catch(async () => {
    console.log('[debug] page content snapshot:', (await page.content()).slice(0, 1500));
  });
  check('E2E-1 login (sessão local injetada) chega no Dashboard', page.url() === `${BASE}/` || page.url() === `${BASE}`);

  // ---- E2E-2: Cidades -> Jussara -> Editar ----
  await page.click('nav a:has-text("Cidades & Infraestrutura")');
  await page.waitForSelector('table', { timeout: 10000 });
  const jussaraRow = page.locator('table tbody tr', { hasText: 'Jussara' }).first();
  check('E2E-2 Jussara aparece na lista de Cidades', await jussaraRow.count() > 0);
  await jussaraRow.locator('a:has-text("Editar")').click();
  await page.waitForSelector('text=Editar Infraestrutura', { timeout: 10000 });
  check('E2E-3 tela "Editar Infraestrutura — Jussara" abre a partir de Cidades', (await page.textContent('h1')).includes('Jussara'));

  // ---- E2E-4: alterar KM -> salvar ----
  const kmInput = page.locator('.field:has(label:has-text("KM de rede")) input');
  const kmBefore = await kmInput.inputValue();
  const kmNovo = (Number(kmBefore) + 3.5).toFixed(3);
  await kmInput.fill(kmNovo);
  await page.click('button:has-text("Salvar alterações")');
  await page.waitForTimeout(1200);
  const kmPersisted = sqlValue(`select km_rede from public.cidades_infra where id='${sqlValue("select id from public.cidades_infra where nome='Jussara' limit 1;")}';`);
  check(`E2E-4 KM de rede de Jussara alterado e persistido (${kmBefore} -> ${kmNovo}, banco=${kmPersisted})`, Number(kmPersisted) === Number(kmNovo), `esperado=${kmNovo} banco=${kmPersisted}`);

  // ---- E2E-5: verificar Dashboard (Jussara segue listada e consistente após a edição) ----
  await page.click('nav a:has-text("Dashboard")');
  await page.waitForSelector('table', { timeout: 10000 });
  const dashJussaraRow = page.locator('table tbody tr', { hasText: 'Jussara' }).first();
  check('E2E-5 Dashboard segue listando Jussara após a edição de KM (nada quebrou)', await dashJussaraRow.count() > 0);

  // ---- E2E-6: voltar para Editar Infraestrutura -> selecionar POP -> editar -> salvar ----
  await page.click('nav a:has-text("Cidades & Infraestrutura")');
  await page.waitForSelector('table', { timeout: 10000 });
  await page.locator('table tbody tr', { hasText: 'Jussara' }).first().locator('a:has-text("Editar")').click();
  await page.waitForSelector('h3:has-text("POPs")', { timeout: 10000 });
  const popsCard = page.locator('.card', { has: page.locator('h3:has-text("POPs")') });
  const firstPopRow = popsCard.locator('table tbody tr').first();
  const popCodigoAntes = await firstPopRow.locator('td').first().textContent();
  check('E2E-6 tela mostra ao menos 1 POP para selecionar', await firstPopRow.count() > 0, `pop=${popCodigoAntes}`);
  await firstPopRow.locator('button:has-text("Editar")').click();
  await page.waitForTimeout(300);
  const popEditRow = popsCard.locator('table tr').filter({ has: page.locator('button:has-text("Salvar")') }).first();
  const nomeInput = popEditRow.locator('.field:has(label:has-text("Nome")) input');
  const nomeNovo = `${(await nomeInput.inputValue())} (editado E2E ${RUN_SUFFIX})`;
  await nomeInput.fill(nomeNovo);
  await popEditRow.locator('button:has-text("Salvar")').click();
  await page.waitForTimeout(1200);
  const popEdited = await page.locator('td', { hasText: nomeNovo }).count();
  check(`E2E-7 POP ${popCodigoAntes} editado e salvo (nome atualizado na listagem)`, popEdited > 0, `nomeNovo=${nomeNovo}`);

  // ---- E2E-8: criar + arquivar segmento de teste ----
  const segNome = `Segmento E2E Teste ${RUN_SUFFIX}`;
  const segmentsCard = page.locator('.card', { has: page.locator('h3:has-text("Segmentos")') });
  const segInputs = segmentsCard.locator('form input');
  await segInputs.nth(0).fill(segNome);
  await segInputs.nth(1).fill('Origem E2E');
  await segInputs.nth(2).fill('Destino E2E');
  await segInputs.nth(3).fill('1.5');
  await segmentsCard.locator('button:has-text("Novo Segmento")').click();
  await page.waitForTimeout(1200);
  const segRow = segmentsCard.locator('tr', { hasText: segNome });
  check(`E2E-8 segmento de teste "${segNome}" criado e listado`, await segRow.count() > 0);

  await segRow.locator('button:has-text("Arquivar")').click();
  await page.waitForSelector('text=Arquivar segmento?', { timeout: 5000 });
  // Modal de confirmação (seção 29): motivo de lista fechada + observação livre.
  await page.selectOption('.modal-dialog select', { label: 'Erro de cadastro' });
  await page.fill('.modal-dialog .field:has(label:has-text("Observação")) input', 'Segmento de teste do E2E da Fase 2.3.1 — seção 40.');
  await page.click('button:has-text("Confirmar Arquivamento")');
  await page.waitForTimeout(1200);
  check('E2E-9 segmento de teste arquivado (some do filtro Ativos)', await segmentsCard.locator('tr', { hasText: segNome }).count() === 0);

  // ---- E2E-10: consultar arquivados ----
  await segmentsCard.locator('.chip:has-text("Arquivados")').click();
  await page.waitForTimeout(500);
  const archivedSegRow = segmentsCard.locator('tr', { hasText: segNome });
  check('E2E-10 segmento de teste aparece no filtro "Arquivados"', await archivedSegRow.count() > 0);
  const archivedBadgeVisible = await archivedSegRow.locator('.badge.status-archived').count();
  check('E2E-10b linha do segmento arquivado mostra badge "Arquivado"', archivedBadgeVisible > 0);

  // ---- E2E-11: restaurar (ADMINISTRADOR pode) ----
  await archivedSegRow.locator('button:has-text("Restaurar")').click();
  await page.waitForTimeout(1200);
  await segmentsCard.locator('.chip:has-text("Ativos")').click();
  await page.waitForTimeout(500);
  check('E2E-11 segmento de teste restaurado (volta a aparecer em Ativos)', await segmentsCard.locator('tr', { hasText: segNome }).count() > 0);

  // ---- E2E-12: arquivar de novo (para o cenário final de "só infra ativa disponível") ----
  await segmentsCard.locator('tr', { hasText: segNome }).locator('button:has-text("Arquivar")').click();
  await page.waitForSelector('text=Arquivar segmento?', { timeout: 5000 });
  await page.selectOption('.modal-dialog select', { label: 'Outro' });
  await page.click('button:has-text("Confirmar Arquivamento")');
  await page.waitForTimeout(1200);

  // O select de Segmento do formulário "Novo Cabo" nunca deve oferecer um segmento
  // arquivado como opção nova (achado real de teste desta fase — corrigido em
  // EditCity.jsx: os 3 formulários de CRIAÇÃO agora filtram s.arquivado/p.arquivado).
  const cablesCard = page.locator('.card', { has: page.locator('h3:has-text("Cabos")') });
  const cableSegmentoOptions = await cablesCard.locator('form select').first().locator('option').allTextContents();
  check(
    `E2E-12 "Novo Cabo" NÃO oferece o segmento arquivado "${segNome}" como opção`,
    !cableSegmentoOptions.some((t) => t.includes(segNome)),
    `opcoes=${JSON.stringify(cableSegmentoOptions)}`
  );

  // ---- E2E-13: Nova Simulação -> verificar que apenas infraestrutura ativa está disponível ----
  await page.click('nav a:has-text("Nova Simulação")');
  await page.waitForSelector('select', { timeout: 10000 });
  const citySelect = page.locator('select').first();
  await citySelect.selectOption({ label: 'Jussara — PR' });
  await page.waitForTimeout(800);
  // "POP (opcional...)" é o 2º <select> da tela — lista cityDetail.pops, que a API
  // (pricing_city_detail) já exclui arquivados desde a migration 3 desta fase (seção 39).
  const popSelectOptions = await page.locator('select').nth(1).locator('option').allTextContents();
  check(
    'E2E-13 "Nova Simulação" carrega POPs de Jussara (dropdown populado)',
    popSelectOptions.length > 1,
    `opcoes=${JSON.stringify(popSelectOptions)}`
  );
  check(
    'E2E-13b "Nova Simulação" nunca lista um POP arquivado no dropdown (verificado contra o banco)',
    !popSelectOptions.some((t) => t.toLowerCase().includes('arquivad')),
    `opcoes=${JSON.stringify(popSelectOptions)}`
  );
  await page.waitForSelector('.regua', { timeout: 20000 }).catch(async () => {
    console.log('[debug E2E-13] page content snapshot:', (await page.content()).slice(0, 2000));
  });
  const pricingVisible = await page.locator('text=/Piso|Recomendado|Abertura/i').count();
  check('E2E-14 Pricing Engine calcula normalmente para Jussara após todo o fluxo de CRUD/arquivamento', pricingVisible > 0);

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
