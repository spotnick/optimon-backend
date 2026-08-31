// Verificação visual REAL da Fase 3.11.3 — campo "Parceiro / Proponente" obrigatório na
// tela de Nova Simulação (seções 10-11 do pedido). Abre a aplicação de verdade no
// Chromium (Playwright), navega pela tela real e comprova visualmente:
//   1) O rótulo do campo mostra "Parceiro / Proponente *" (asterisco vermelho).
//   2) Sem parceiro selecionado: mensagem de erro visível "Selecione o parceiro/
//      proponente antes de criar a proposta." e botão "Gerar Proposta" DESABILITADO.
//   3) Ao selecionar um parceiro real: a mensagem some e o botão fica habilitado.
//   4) Gerar a proposta de verdade funciona (fecha o ciclo: campo obrigatório não
//      impede o caso feliz).
// Screenshots salvos em /tmp/fase3113_evidencia/.
const { chromium } = require('/opt/node-tools/node_modules/playwright');
const { execSync } = require('child_process');
const fs = require('fs');

const BASE = process.env.E2E_BASE_URL || 'http://localhost:5173';
const API = process.env.E2E_API_URL || 'http://localhost:3001';
const OUT = '/tmp/fase3113_evidencia';
fs.mkdirSync(OUT, { recursive: true });

function sh(cmd) { return execSync(cmd, { encoding: 'utf8' }).trim(); }
function mintJwt(uid) { return sh(`node supabase/dev-local-only/mint_jwt.js ${uid}`); }
function uidForEmail(email) {
  return sh(`PGPASSWORD=optimon_dev psql -h localhost -U optimon_admin -d optimon -t -A -c "select id from public.usuarios where email='${email}' limit 1;"`);
}
function scalar(sql) {
  return sh(`PGPASSWORD=optimon_dev psql -h localhost -U optimon_admin -d optimon -t -A -c "${sql.replace(/"/g, '\\"')}"`);
}

async function injectSession(page, jwt) {
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
  await page.waitForFunction('!!window.__optimonSupabase', { timeout: 10000 });
  await page.evaluate(async (token) => {
    const [, payloadB64] = token.split('.');
    const payload = JSON.parse(atob(payloadB64.replace(/-/g, '+').replace(/_/g, '/')));
    const storageKey = window.__optimonSupabase.auth.storageKey;
    const session = {
      access_token: token, token_type: 'bearer', expires_in: payload.exp - payload.iat, expires_at: payload.exp,
      refresh_token: 'visual3113-fake-refresh', user: { id: payload.sub, aud: payload.aud, role: payload.role, email: 'visual3113@optimon.local' },
    };
    window.localStorage.setItem(storageKey, JSON.stringify(session));
  }, jwt);
}

async function dismissWelcome(page) {
  try {
    const btn = page.locator('button:has-text("Explorar sozinho")');
    await btn.waitFor({ state: 'visible', timeout: 2000 });
    await btn.click();
    await page.waitForTimeout(300);
  } catch { /* modal não apareceu — segue normalmente */ }
}

let shot = 0;
async function snap(page, name) {
  shot += 1;
  const file = `${OUT}/${String(shot).padStart(2, '0')}_${name}.png`;
  await page.screenshot({ path: file, fullPage: true });
  console.log('[screenshot]', file);
}

const results = [];
function check(label, ok, detail) {
  results.push({ label, ok, detail });
  console.log(`[${ok ? 'PASS' : 'FAIL'}]`, label, detail ? `— ${detail}` : '');
}

(async () => {
  const UID_COMERCIAL = uidForEmail('comercial@optimon.local');
  const JWT_COMERCIAL = mintJwt(UID_COMERCIAL);

  // Parceiro real de teste (visível no dropdown) — criado via API, mesmo padrão da
  // suíte de testes.
  const cnpj = String(Math.floor(Math.random() * 1e14)).padStart(14, '0');

  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await ctx.newPage();

  await injectSession(page, JWT_COMERCIAL);
  await page.goto(`${BASE}/simulacao`, { waitUntil: 'networkidle' });
  await dismissWelcome(page);

  const partnerResp = await page.request.post(`${API}/api/partners`, {
    headers: { Authorization: `Bearer ${JWT_COMERCIAL}`, 'Content-Type': 'application/json' },
    data: { razao_social: 'TESTE-VISUAL-OPTIMON-3113 Ltda', nome_fantasia: 'TESTE-VISUAL-OPTIMON-3113', cnpj, email_contato: 'teste-visual-3113@optimon.local' },
  });
  const parceiro = await partnerResp.json();
  check('parceiro de teste criado via API para o dropdown', partnerResp.ok(), `id=${parceiro.id}`);

  await page.reload({ waitUntil: 'networkidle' });
  await dismissWelcome(page);
  await page.waitForSelector('.card:has-text("Régua de Preço"), .kpi-card', { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(800);

  // 1) rótulo com asterisco.
  const labelText = await page.locator('.field:has(select) label:has-text("Parceiro")').first().innerText().catch(() => '');
  check('rótulo do campo mostra "Parceiro / Proponente *"', /Parceiro\s*\/\s*Proponente/.test(labelText) && labelText.includes('*'), `texto real="${labelText}"`);
  await snap(page, 'campo_parceiro_obrigatorio_vazio');

  // 2) mensagem de erro + botão desabilitado sem parceiro selecionado.
  const avisoVisivel = await page.locator('text=Selecione o parceiro/proponente antes de criar a proposta.').first().isVisible().catch(() => false);
  check('mensagem "Selecione o parceiro/proponente antes de criar a proposta." visível sem seleção', avisoVisivel);

  const botaoGerar = page.locator('button:has-text("Gerar Proposta")');
  const desabilitadoAntes = await botaoGerar.isDisabled().catch(() => null);
  check('botão "Gerar Proposta" DESABILITADO sem parceiro selecionado', desabilitadoAntes === true, `disabled=${desabilitadoAntes}`);

  // 3) seleciona o parceiro real — mensagem some, botão habilita.
  const select = page.locator('select').filter({ has: page.locator(`option:has-text("TESTE-VISUAL-OPTIMON-3113")`) }).first();
  await select.selectOption({ label: 'TESTE-VISUAL-OPTIMON-3113' });
  await page.waitForTimeout(300);
  await snap(page, 'parceiro_selecionado');

  const avisoSumiu = await page.locator('text=Selecione o parceiro/proponente antes de criar a proposta.').first().isVisible().catch(() => false);
  check('mensagem de obrigatoriedade some depois de selecionar o parceiro', !avisoSumiu);

  const desabilitadoDepois = await botaoGerar.isDisabled().catch(() => null);
  check('botão "Gerar Proposta" HABILITADO depois de selecionar o parceiro', desabilitadoDepois === false, `disabled=${desabilitadoDepois}`);

  // 4) caso feliz: gerar a proposta de verdade funciona com o campo preenchido.
  await botaoGerar.click();
  await page.waitForSelector('text=gerada com sucesso', { timeout: 15000 }).catch(() => {});
  await snap(page, 'proposta_gerada_com_sucesso');
  const sucesso = await page.locator('text=gerada com sucesso').first().isVisible().catch(() => false);
  check('proposta gerada com sucesso com parceiro preenchido (caso feliz não quebrou)', sucesso);

  await browser.close();

  const fails = results.filter((r) => !r.ok);
  console.log('\n=== RESULTADO VISUAL FASE 3.11.3 ===');
  console.log(`${results.length - fails.length}/${results.length} PASS`);
  if (fails.length) {
    console.log('FALHAS:', fails.map((f) => f.label).join(' | '));
    process.exit(1);
  }
})().catch((err) => {
  console.error('ERRO FATAL:', err);
  process.exit(1);
});
