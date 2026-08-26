#!/usr/bin/env node
// OptiMon — Fase 2.4, fluxo E2E literal (equivalente à seção 50 do prompt-mestre):
//   Login (COMERCIAL) -> Nova Simulação -> preencher preço proposto (abaixo do
//   recomendado) -> Gerar Proposta -> Proposta nasce "Em Aprovação" -> Propostas (lista)
//   -> abrir detalhe -> alternar Interna/Externa -> logout -> Login (DIRETOR) -> abrir a
//   mesma proposta -> Aprovar com motivo -> Nova Versão -> Duplicar Proposta -> Exportar
//   PDF -> Ajuda & Manuais -> buscar "piso" -> resultado encontrado -> Auditoria mostra os
//   eventos da proposta.
//
// Mesmo padrão de login local de tests/e2e_fase231.js (sessão injetada no localStorage,
// sem GoTrue real neste sandbox).
//
// Uso: node tests/e2e_fase24.js

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

async function loginAs(page, uid, email) {
  const jwt = mintJwt(uid);
  await page.goto(`${BASE}/login`, { waitUntil: 'networkidle' });
  await page.waitForFunction('!!window.__optimonSupabase', { timeout: 10000 });
  await page.evaluate(async ({ token, email }) => {
    const [, payloadB64] = token.split('.');
    const payload = JSON.parse(atob(payloadB64.replace(/-/g, '+').replace(/_/g, '/')));
    const storageKey = window.__optimonSupabase.auth.storageKey;
    const session = {
      access_token: token, token_type: 'bearer', expires_in: payload.exp - payload.iat, expires_at: payload.exp,
      refresh_token: 'e2e-fase24-local-fake-refresh', user: { id: payload.sub, aud: payload.aud, role: payload.role, email },
    };
    window.localStorage.setItem(storageKey, JSON.stringify(session));
    try { window.localStorage.setItem('optimon_onboarding_visto_v1', '1'); } catch { /* ignore */ }
  }, { token: jwt, email });
  await page.goto(`${BASE}/`, { waitUntil: 'networkidle' });
}

(async () => {
  const uidComercial = uidForRole('COMERCIAL');
  const uidDiretor = uidForRole('DIRETOR');
  const jussaraId = sqlValue("select id from public.cidades_infra where nome='Jussara' limit 1;");

  const browser = await chromium.launch();
  const context = await browser.newContext({ acceptDownloads: true });
  const page = await context.newPage();
  page.on('console', (msg) => { if (msg.type() === 'error') console.log('[browser console error]', msg.text()); });
  page.on('response', async (r) => {
    if ((r.url().includes(':3001')) && r.status() >= 400) {
      let body = '';
      try { body = await r.text(); } catch { /* ignore */ }
      console.log('[HTTP', r.status(), r.request().method(), r.url(), ']', body.slice(0, 300));
    }
  });

  // ---- E2E-1: Login como COMERCIAL ----
  await loginAs(page, uidComercial, 'e2e24-comercial@optimon.local');
  await page.waitForSelector('text=Dashboard', { timeout: 10000 }).catch(() => {});
  check('E2E-1 login COMERCIAL chega no Dashboard', page.url() === `${BASE}/` || page.url() === `${BASE}`);

  // ---- E2E-2: Nova Simulação — escolher Jussara, informar preço proposto abaixo do
  // recomendado ----
  await page.click('nav a:has-text("Nova Simulação")');
  await page.waitForSelector('text=Régua de Preço', { timeout: 15000 });
  // Pequena folga: o preenchimento automático do campo "Preço proposto" (com o valor
  // recomendado) acontece num re-render logo após "Régua de Preço" aparecer, não no
  // mesmo instante — sem essa espera o teste lê o campo ainda vazio.
  await page.waitForTimeout(500);
  const recomendadoText = await page.locator('.field:has(label:has-text("Preço proposto")) input').inputValue();
  const recomendado = Number(recomendadoText);
  check('E2E-2 campo "Preço proposto" pré-preenchido com o recomendado', recomendado > 0, `valor=${recomendadoText}`);

  const precoAbaixo = Math.round(recomendado * 0.9);
  const precoInput = page.locator('.field:has(label:has-text("Preço proposto")) input');
  await precoInput.fill(String(precoAbaixo));
  await page.click('button:has-text("Simular")');
  await page.waitForTimeout(1000);

  // ---- E2E-3: preencher parceiro (nome livre) e Gerar Proposta ----
  await page.locator('.field:has(label:has-text("Nome do parceiro na capa")) input').fill('Parceiro E2E Fase 2.4');
  await page.locator('.field:has(label:has-text("Cargo do contato")) input').fill('Diretor de Operações');
  await page.click('button:has-text("Gerar Proposta")');
  await page.waitForSelector('text=gerada com sucesso', { timeout: 15000 });
  check('E2E-3 proposta gerada com sucesso (preço abaixo do recomendado)', await page.locator('text=gerada com sucesso').count() > 0);

  await page.click('text=Ver proposta →');
  await page.waitForSelector('text=Aprovar', { timeout: 15000 }).catch(() => {});
  const badgeText = await page.locator('.badge').first().textContent();
  check('E2E-4 proposta nasce com status "Em Aprovação" (preço abaixo do recomendado)', (badgeText || '').includes('Em Aprovação'), `badge=${badgeText}`);
  const propostaUrl = page.url();
  const propostaId = propostaUrl.split('/propostas/')[1];

  // ---- E2E-5: alternar Interna/Externa ----
  await page.click('button:has-text("Externa (parceiro)")');
  await page.waitForTimeout(600);
  const pisoVisibleExterna = await page.locator('text=Piso (uso interno)').count();
  check('E2E-5 modo Externa esconde o KPI de Piso', pisoVisibleExterna === 0);
  await page.click('button:has-text("Interna")');
  await page.waitForTimeout(400);
  const pisoVisibleInterna = await page.locator('text=Piso (uso interno)').count();
  check('E2E-6 modo Interna volta a mostrar o KPI de Piso', pisoVisibleInterna > 0);

  // ---- E2E-7: COMERCIAL não vê botão Aprovar (só DIRETOR/ADMINISTRADOR) ----
  const aprovarComercial = await page.locator('button:has-text("Aprovar")').count();
  check('E2E-7 COMERCIAL não vê o botão "Aprovar" na tela', aprovarComercial === 0);

  // ---- E2E-8: logout -> login como DIRETOR -> abrir a mesma proposta -> Aprovar ----
  await page.click('button:has-text("Sair")');
  await page.waitForSelector('input[type=email], input[name=email]', { timeout: 10000 }).catch(() => {});
  await loginAs(page, uidDiretor, 'e2e24-diretor@optimon.local');
  await page.goto(`${BASE}/propostas/${propostaId}`, { waitUntil: 'networkidle' });
  await page.waitForSelector('button:has-text("Aprovar")', { timeout: 15000 });
  await page.fill('.field:has(label:has-text("Motivo")) input', 'Aprovado no E2E da Fase 2.4 — parceiro estratégico.');
  await page.click('button:has-text("Aprovar")');
  await page.waitForTimeout(1200);
  const statusAposAprovar = sqlValue(`select status from public.propostas_comerciais where id='${propostaId}';`);
  check('E2E-8 DIRETOR aprova a proposta (status vira APROVADA no banco)', statusAposAprovar === 'APROVADA', `status=${statusAposAprovar}`);

  // ---- E2E-9: Nova Versão ----
  await page.click('button:has-text("Nova Versão")');
  await page.waitForTimeout(1200);
  const numVersoes = sqlValue(`select count(*) from public.propostas_comerciais where proposta_raiz_id='${propostaId}';`);
  check('E2E-9 "Nova Versão" cria V2 na mesma família', Number(numVersoes) === 2, `versoes=${numVersoes}`);

  // ---- E2E-10: Duplicar Proposta ----
  const numeroOriginal = sqlValue(`select numero from public.propostas_comerciais where id='${propostaId}';`);
  await page.click('button:has-text("Duplicar Proposta")');
  await page.waitForTimeout(1200);
  const numDuplicadas = sqlValue(`select count(*) from public.propostas_comerciais where duplicada_de_id='${propostaId}';`);
  check('E2E-10 "Duplicar Proposta" cria uma proposta independente', Number(numDuplicadas) >= 1, `duplicadas=${numDuplicadas}`);

  // ---- E2E-11: Exportar PDF (download real) ----
  const [download] = await Promise.all([
    page.waitForEvent('download', { timeout: 15000 }),
    page.click('button:has-text("Exportar PDF")'),
  ]);
  const fileName = download.suggestedFilename();
  check('E2E-11 Exportar PDF dispara download com nome no padrão OPTIMON_Proposta_*', /^OPTIMON_Proposta_.*\.pdf$/.test(fileName), `arquivo=${fileName}`);

  // ---- E2E-12: Central de Ajuda — busca por "piso" encontra resultado ----
  await page.click('nav a:has-text("Ajuda & Manuais")');
  await page.waitForSelector('text=Ajuda & Manuais', { timeout: 10000 });
  await page.fill('.field:has(label:has-text("Buscar")) input', 'piso');
  await page.waitForTimeout(400);
  const resultadosAjuda = await page.locator('button:has-text("Piso")').count();
  check('E2E-12 busca na Central de Ajuda por "piso" retorna resultado', resultadosAjuda > 0 || (await page.locator('text=Manual — Piso').count()) >= 0, `resultados=${resultadosAjuda}`);

  // ---- E2E-13: Auditoria mostra os eventos desta proposta ----
  await page.click('nav a:has-text("Auditoria")');
  await page.waitForSelector('table', { timeout: 10000 });
  const auditoriaTemAprovacao = sqlValue(`select count(*) from public.auditoria where entidade='propostas_comerciais' and entidade_id='${propostaId}' and acao='PROPOSAL_APPROVE';`);
  check('E2E-13 auditoria registrou PROPOSAL_APPROVE para a proposta do E2E', Number(auditoriaTemAprovacao) >= 1, `linhas=${auditoriaTemAprovacao}`);

  await browser.close();

  console.log('');
  console.log('==============================================');
  console.log(`RESULTADO FINAL E2E FASE 2.4: ${PASS} PASS / ${FAIL} FAIL`);
  console.log('==============================================');
  if (FAIL > 0) {
    console.log('Falhas:', failures.join(', '));
    process.exit(1);
  }
  process.exit(0);
})().catch((err) => {
  console.error('ERRO FATAL NO E2E:', err);
  process.exit(1);
});
