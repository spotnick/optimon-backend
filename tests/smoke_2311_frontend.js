// Smoke test manual (não faz parte da suite formal — só para verificar visualmente que o
// CRUD de infraestrutura da Fase 2.3.1 funciona ponta a ponta no browser antes de escrever
// os testes formais). Mesmo padrão de login local de tests/e2e_fase23.js.
const { chromium } = require('playwright');
const { execSync } = require('child_process');

const BASE = process.env.E2E_BASE_URL || 'http://localhost:5173';

function sh(cmd) {
  return execSync(cmd, { encoding: 'utf8' }).trim();
}
function mintJwt(uid) {
  return sh(`node supabase/dev-local-only/mint_jwt.js ${uid}`);
}
function uidForRole(role) {
  return sh(`PGPASSWORD=optimon_dev psql -h localhost -U optimon_admin -d optimon -t -A -c "select id from public.usuarios where perfil='${role}' limit 1;"`);
}

(async () => {
  const uid = uidForRole('ADMINISTRADOR');
  const jwt = mintJwt(uid);
  const browser = await chromium.launch();
  const page = await browser.newPage();
  page.on('console', (msg) => { if (msg.type() === 'error') console.log('[console error]', msg.text()); });
  page.on('pageerror', (err) => console.log('[page error]', err.message));
  page.on('response', async (r) => {
    if ((r.url().includes(':3001') || r.url().includes(':54321')) && r.status() >= 400) {
      let body = '';
      try { body = await r.text(); } catch { /* ignore */ }
      console.log('[HTTP', r.status(), r.request().method(), r.url(), ']', body.slice(0, 300));
    }
  });

  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
  await page.waitForFunction('!!window.__optimonSupabase', { timeout: 10000 });
  await page.evaluate(async (token) => {
    const [, payloadB64] = token.split('.');
    const payload = JSON.parse(atob(payloadB64.replace(/-/g, '+').replace(/_/g, '/')));
    const storageKey = window.__optimonSupabase.auth.storageKey;
    const session = {
      access_token: token, token_type: 'bearer', expires_in: payload.exp - payload.iat, expires_at: payload.exp,
      refresh_token: 'smoke-fake-refresh', user: { id: payload.sub, aud: payload.aud, role: payload.role, email: 'smoke@optimon.local' },
    };
    window.localStorage.setItem(storageKey, JSON.stringify(session));
  }, jwt);
  await page.goto(`${BASE}/cidades`, { waitUntil: 'networkidle' });
  await page.waitForSelector('table', { timeout: 10000 });
  console.log('OK: /cidades carregou com tabela');

  // filtro chips
  const chips = await page.locator('.chip').allTextContents();
  console.log('chips cidades:', chips);
  await page.click('.chip:has-text("Arquivadas")');
  await page.waitForTimeout(500);
  const archivedRows = await page.locator('table tbody tr').count();
  console.log('linhas em Arquivadas:', archivedRows);
  const archivedBadges = await page.locator('.badge.status-archived').count();
  console.log('badges "Arquivada" visiveis:', archivedBadges);
  await page.click('.chip:has-text("Ativas")');
  await page.waitForTimeout(500);

  // abrir uma cidade ativa e ir para editar
  const firstEditLink = page.locator('table tbody tr a:has-text("Editar")').first();
  const cityRowText = await page.locator('table tbody tr').first().locator('td').first().textContent();
  console.log('abrindo edição da cidade:', cityRowText);
  await firstEditLink.click();
  await page.waitForSelector('text=Editar Infraestrutura', { timeout: 10000 });
  console.log('OK: chegou em Editar Infraestrutura');

  // POPs section: checar filtro chips e criar um POP de teste, editar e arquivar
  await page.waitForSelector('h3:has-text("POPs")', { timeout: 10000 });
  const codigoInput = page.locator('input[placeholder="POP-02"]');
  await codigoInput.fill('POP-SMOKE-01');
  await page.fill('input[placeholder="POP-02 — Distribuição"]', 'POP Smoke Teste');
  await page.click('button:has-text("+ Novo POP")');
  await page.waitForTimeout(1200);
  const popRow = page.locator('tr', { hasText: 'POP-SMOKE-01' });
  const popRowCount = await popRow.count();
  console.log('POP-SMOKE-01 criado, linhas encontradas:', popRowCount);

  if (popRowCount > 0) {
    await popRow.locator('button:has-text("Editar")').click();
    await page.waitForTimeout(300);
    console.log('OK: form de edição do POP abriu');
    // O form de edição vira uma <tr><td colspan> logo após a linha original — captura o
    // <tr> seguinte da tabela de POPs e clica no Salvar exato dentro dele (evita colidir
    // com "Salvar alterações" do form da cidade, que também casa em :has-text("Salvar")).
    const popsTable = page.locator('.card', { has: page.locator('h3:has-text("POPs")') }).locator('table');
    const editFormRow = popsTable.locator('tr').filter({ has: page.locator('button:has-text("Salvar")') }).first();
    await editFormRow.locator('button:has-text("Salvar")').click();
    await page.waitForTimeout(1000);
    console.log('OK: salvou edição do POP');

    // arquivar
    await page.screenshot({ path: '/tmp/smoke_after_save.png', fullPage: true });
    const rowCountAfterSave = await page.locator('tr', { hasText: 'POP-SMOKE-01' }).count();
    console.log('linhas POP-SMOKE-01 apos salvar:', rowCountAfterSave);
    const popRow2 = page.locator('tr', { hasText: 'POP-SMOKE-01' }).first();
    await popRow2.locator('button:has-text("Arquivar")').click({ timeout: 8000 });
    await page.waitForSelector('text=Arquivar POP?', { timeout: 5000 });
    console.log('OK: modal de confirmação abriu');
    await page.click('button:has-text("Confirmar Arquivamento")');
    await page.waitForTimeout(1200);
    console.log('OK: arquivamento confirmado (verificando filtro ARQUIVADOS)...');

    const popsSection = page.locator('.card', { has: page.locator('h3:has-text("POPs")') });
    await popsSection.locator('.chip:has-text("Arquivados")').click();
    await page.waitForTimeout(500);
    const archivedPopVisible = await page.locator('tr', { hasText: 'POP-SMOKE-01' }).count();
    console.log('POP-SMOKE-01 aparece em Arquivados:', archivedPopVisible);

    const restoreBtn = page.locator('tr', { hasText: 'POP-SMOKE-01' }).locator('button:has-text("Restaurar")');
    const restoreVisible = await restoreBtn.count();
    console.log('botao Restaurar visivel (ADMINISTRADOR):', restoreVisible);
    if (restoreVisible > 0) {
      await restoreBtn.click();
      await page.waitForTimeout(1000);
      console.log('OK: restaurado');
    }
  }

  await page.screenshot({ path: '/tmp/smoke_editcity.png', fullPage: true });
  console.log('screenshot salvo em /tmp/smoke_editcity.png');

  await browser.close();
})().catch((err) => {
  console.error('SMOKE FAILED:', err);
  process.exit(1);
});
