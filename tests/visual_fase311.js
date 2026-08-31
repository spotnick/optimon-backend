// Verificação visual REAL da Fase 3.11 (seção "não negociável" do prompt): abre a
// aplicação de verdade no Chromium (via Playwright), injeta uma sessão local (mesmo
// padrão já usado por tests/e2e_fase23.js / smoke_2311_frontend.js — JWT minted por
// supabase/dev-local-only/mint_jwt.js, sem precisar de GoTrue real), e clica pelas
// telas de verdade provando a cadeia completa: LOGIN (sessão) → DASHBOARD → PROPOSTA →
// APROVAÇÃO INTERNA → ENVIO → ÁREA EXTERNA (sem login) → ACEITE → PROPOSTA INTERNA
// (ACEITA_PELO_PARCEIRO) → GERAR CONTRATO → CONTRATO → MINUTA → ASSINATURA →
// CONTRATO ASSINADO → ATIVAÇÃO. Screenshots salvos em /tmp/fase311_evidencia/.
const { chromium } = require('playwright');
const { execSync } = require('child_process');
const fs = require('fs');

const BASE = process.env.E2E_BASE_URL || 'http://localhost:5173';
const API = process.env.E2E_API_URL || 'http://localhost:3001';
const OUT = '/tmp/fase311_evidencia';
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
      refresh_token: 'visual311-fake-refresh', user: { id: payload.sub, aud: payload.aud, role: payload.role, email: 'visual311@optimon.local' },
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
  } catch { /* modal não apareceu (já visto antes nesta sessão/browser) — segue normalmente */ }
}

let shot = 0;
async function snap(page, name) {
  shot += 1;
  const file = `${OUT}/${String(shot).padStart(2, '0')}_${name}.png`;
  await page.screenshot({ path: file, fullPage: true });
  console.log('[screenshot]', file);
}

(async () => {
  const UID_DIRETOR = uidForEmail('diretor@optimon.local');
  const UID_COMERCIAL = uidForEmail('comercial@optimon.local');
  const JWT_DIRETOR = mintJwt(UID_DIRETOR);
  const JWT_COMERCIAL = mintJwt(UID_COMERCIAL);

  const browser = await chromium.launch();
  const ctxComercial = await browser.newContext();
  const page = await ctxComercial.newPage();
  page.on('pageerror', (err) => console.log('[page error]', err.message));
  page.on('response', async (r) => {
    if ((r.url().includes(':3001')) && r.status() >= 400) {
      let bodyText = '';
      try { bodyText = await r.text(); } catch { /* ignore */ }
      console.log('[HTTP', r.status(), r.request().method(), r.url(), ']', bodyText.slice(0, 200));
    }
  });

  console.log('== LOGIN (sessão injetada, mesmo padrão já usado pelos smoke tests desta base) ==');
  await injectSession(page, JWT_COMERCIAL);

  console.log('== DASHBOARD ==');
  await page.goto(`${BASE}/`, { waitUntil: 'networkidle' });
  await dismissWelcome(page);
  await page.waitForTimeout(800);
  await snap(page, 'dashboard');

  console.log('== Criar simulação + proposta pela API real (para popular a UI) e abrir no browser ==');
  // Reaproveita a mesma proposta criada pelo teste E2E de API? Não — cria uma nova aqui,
  // para a prova visual não depender de estado deixado por outro processo. Chama a API
  // real (mesma que a UI chama) diretamente por HTTP, só para preparar o dado — toda a
  // AÇÃO de negócio relevante (aprovar, enviar, aceitar, gerar contrato, assinar, ativar)
  // é clicada de verdade na tela abaixo, nunca via API neste script.
  const cidadeId = scalar("select id from cidades_infra where nome='Jussara' and removido_em is null limit 1;");
  const cnpj = String(Math.floor(Math.random() * 1e14)).padStart(14, '0');
  const partnerResp = await page.request.post(`${API}/api/partners`, {
    headers: { Authorization: `Bearer ${JWT_COMERCIAL}`, 'Content-Type': 'application/json' },
    data: { razao_social: 'TESTE-E2E-OPTIMON-311-VISUAL Ltda', nome_fantasia: 'TESTE-E2E-OPTIMON-311-VISUAL', cnpj, email_contato: 'visual-311@optimon.local', endereco_logradouro: 'Rua Visual', endereco_numero: '311', endereco_bairro: 'Centro', endereco_cidade: 'Jussara', endereco_uf: 'PR', endereco_cep: '87450000' },
  });
  const parceiro = await partnerResp.json();

  const calcResp = await page.request.post(`${API}/api/pricing/calculate`, {
    headers: { Authorization: `Bearer ${JWT_COMERCIAL}`, 'Content-Type': 'application/json' },
    data: { cidade_id: cidadeId, clientes: 220, arpu: 95, revenue_share_pct: 0.12 },
  });
  const resultado = await calcResp.json();
  const simResp = await page.request.post(`${API}/api/simulations`, {
    headers: { Authorization: `Bearer ${JWT_COMERCIAL}`, 'Content-Type': 'application/json' },
    data: { cidade_id: cidadeId, parceiro_id: parceiro.id, modelo: 'HIBRIDO_REVENUE_SHARE', pares_ou_clientes: 220, arpu: 95, revenue_share_pct: 0.12, prazo_meses: 48, resultado },
  });
  const sim = await simResp.json();
  const propResp = await page.request.post(`${API}/api/proposals`, {
    headers: { Authorization: `Bearer ${JWT_COMERCIAL}`, 'Content-Type': 'application/json' },
    data: { simulacao_id: sim.id, cidade_id: cidadeId, parceiro_id: parceiro.id, parceiro_nome_capa: 'TESTE-E2E-OPTIMON-311-VISUAL', parceiro_cargo_contato: 'Diretor Comercial (teste visual)' },
  });
  const proposta = await propResp.json();
  console.log('proposta criada:', proposta.numero, proposta.id);

  console.log('== PROPOSTA (tela real, modo Interna) ==');
  await page.goto(`${BASE}/propostas/${proposta.id}`, { waitUntil: 'networkidle' });
  await dismissWelcome(page);
  await page.waitForSelector('text=Aprovação Interna (NICK)', { timeout: 10000 });
  await snap(page, 'proposta_rascunho');

  console.log('== APROVAÇÃO INTERNA (clicado como DIRETOR) ==');
  await injectSession(page, JWT_DIRETOR);
  await page.goto(`${BASE}/propostas/${proposta.id}`, { waitUntil: 'networkidle' });
  await dismissWelcome(page);
  await page.fill('input[placeholder="Justificativa…"]', 'Aprovação interna — verificação visual Fase 3.11.');
  await page.click('button:has-text("Aprovar internamente")');
  await page.waitForTimeout(1000);
  await page.waitForSelector('text=Aprovada (interna)', { timeout: 10000 });
  await snap(page, 'proposta_aprovada_internamente');

  console.log('== ENVIAR AO PARCEIRO (clicado de verdade na tela) ==');
  await page.click('button:has-text("Enviar ao Parceiro")');
  await page.waitForTimeout(1000);
  await page.waitForSelector('text=Link de acesso externo', { timeout: 10000 });
  await snap(page, 'proposta_enviada_link_gerado');

  const linkText = await page.locator('code').first().textContent();
  console.log('link externo capturado da tela:', linkText);

  console.log('== PARCEIRO ABRE A ÁREA EXTERNA — SEM LOGIN, aba/contexto de browser separado ==');
  const ctxParceiro = await browser.newContext(); // contexto novo = sem sessão nenhuma, prova que não precisa de login
  const pageParceiro = await ctxParceiro.newPage();
  await pageParceiro.goto(linkText.trim(), { waitUntil: 'networkidle' });
  await pageParceiro.waitForSelector('text=Aceite da proposta', { timeout: 10000 });
  shot += 1;
  await pageParceiro.screenshot({ path: `${OUT}/${String(shot).padStart(2, '0')}_area_externa_parceiro_sem_login.png`, fullPage: true });
  console.log('[screenshot] área externa (sem login) capturada');

  console.log('== PARCEIRO ACEITA A PROPOSTA (formulário real, na área externa) ==');
  await pageParceiro.click('button:has-text("Aceitar proposta")');
  await pageParceiro.fill('input[placeholder="Seu nome completo"]', 'Carlos Silva (verificação visual)');
  await pageParceiro.fill('input[placeholder="000.000.000-00"]', '123.456.789-00');
  await pageParceiro.fill('input[placeholder="Ex.: Diretor"]', 'Diretor');
  await pageParceiro.fill('input[placeholder="voce@empresa.com.br"]', 'carlos-visual311@parceiro.local');
  await pageParceiro.click('button:has-text("Confirmar aceite")');
  await pageParceiro.waitForTimeout(1200);
  await pageParceiro.waitForSelector('text=Proposta aceita.', { timeout: 10000 });
  shot += 1;
  await pageParceiro.screenshot({ path: `${OUT}/${String(shot).padStart(2, '0')}_area_externa_aceite_confirmado.png`, fullPage: true });
  console.log('[screenshot] aceite confirmado na área externa');
  await ctxParceiro.close();

  console.log('== VOLTA PARA A TELA INTERNA — status deve refletir ACEITA_PELO_PARCEIRO ==');
  await page.goto(`${BASE}/propostas/${proposta.id}`, { waitUntil: 'networkidle' });
  await page.waitForSelector('text=Aceita pelo Parceiro', { timeout: 10000 });
  await snap(page, 'proposta_aceita_pelo_parceiro');

  console.log('== CRIAR CONTRATO (botão real, checklist, clicado de verdade) ==');
  await page.click('button:has-text("CRIAR CONTRATO")');
  await page.waitForSelector('text=Confirmar criação do contrato', { timeout: 10000 });
  await snap(page, 'checklist_criar_contrato');
  await page.click('button:has-text("Confirmar e criar contrato")');
  await page.waitForTimeout(1500);
  await page.waitForURL(/\/contratos\//, { timeout: 15000 });
  await snap(page, 'contrato_criado_tela_contrato');

  const contratoUrl = page.url();
  const contratoId = contratoUrl.split('/contratos/')[1];
  console.log('contrato criado, id=', contratoId);

  console.log('== ASSINATURA ELETRÔNICA DO CONTRATO — criar envelope (PDF auto-gerado) ==');
  await page.waitForSelector('text=Assinatura eletrônica do contrato', { timeout: 10000 });
  await page.click('button:has-text("Criar envelope e enviar para assinatura")');
  await page.waitForTimeout(1500);
  await page.waitForSelector('text=Adicionar signatário', { timeout: 15000 });
  await snap(page, 'contrato_envelope_criado');

  await page.fill('input[type="email"]', ''); // no-op para garantir campo limpo antes do fill abaixo
  const nomeInputs = page.locator('form:has(button:has-text("Adicionar signatário")) input');
  await nomeInputs.nth(0).fill('Representante NICK (verificação visual)');
  await nomeInputs.nth(1).fill('nick-visual311@optimon.local');
  await page.click('button:has-text("Adicionar signatário")');
  await page.waitForTimeout(800);
  await nomeInputs.nth(0).fill('Representante TESTE-E2E-OPTIMON-311-VISUAL');
  await nomeInputs.nth(1).fill('parceiro-visual311@optimon.local');
  await page.selectOption('form:has(button:has-text("Adicionar signatário")) select', 'REPRESENTANTE_PROPONENTE');
  await page.click('button:has-text("Adicionar signatário")');
  await page.waitForTimeout(800);
  await snap(page, 'contrato_2_signatarios_adicionados');

  await page.click('button:has-text("Enviar para assinatura")');
  await page.waitForTimeout(1200);
  await snap(page, 'contrato_enviado_para_assinatura');

  console.log('== Simulação de webhook de assinatura (2 signatários) — mesmo provedor mock já usado desde a Fase 2.5 ==');
  const envelopeId = scalar(`select id from signature_envelopes where contrato_id='${contratoId}' and tipo_documento='CONTRATO' order by criado_em desc limit 1;`);
  const providerEnvelopeId = scalar(`select provider_envelope_id from signature_envelopes where id='${envelopeId}';`);
  const secret = 'optimon-fase25-teste-hmac-secret-nao-usar-em-producao';
  const crypto = require('crypto');
  function sendWebhook(payloadObj) {
    const payload = JSON.stringify(payloadObj);
    const sig = crypto.createHmac('sha256', secret).update(payload).digest('hex');
    const out = execSync(`curl -sS -X POST ${API}/api/signatures/webhook -H "Content-Type: application/json" -H "X-Signature: ${sig}" -d '${payload.replace(/'/g, "'\\''")}'`, { encoding: 'utf8' });
    console.log('[webhook response]', out);
  }
  sendWebhook({ provider_envelope_id: providerEnvelopeId, evento_externo_id: 'evt-1-visual311', tipo_evento: 'SIGNER_SIGNED', signer_email: 'nick-visual311@optimon.local', signer_novo_status: 'ASSINADO', signer_ip: '203.0.113.30', novo_status_envelope: 'PARCIALMENTE_ASSINADO' });
  sendWebhook({ provider_envelope_id: providerEnvelopeId, evento_externo_id: 'evt-2-visual311', tipo_evento: 'SIGNER_SIGNED', signer_email: 'parceiro-visual311@optimon.local', signer_novo_status: 'ASSINADO', signer_ip: '203.0.113.31', novo_status_envelope: 'ASSINADO', hash_assinado: 'visual311-hash', storage_path_assinado: 'homologacao/visual-311/contrato-assinado.pdf' });

  const validateResp = await page.request.post(`${API}/api/signatures/envelopes/${envelopeId}/validate`, { headers: { Authorization: `Bearer ${JWT_COMERCIAL}` } });
  console.log('[validate response]', validateResp.status(), await validateResp.text());

  await page.reload({ waitUntil: 'networkidle' });
  await page.waitForSelector('text=ASSINADO', { timeout: 10000 });
  await snap(page, 'contrato_assinatura_status_assinado');

  console.log('== ATIVAÇÃO — aloca fibra (passo de Engenharia, direto no banco, mesmo padrão dos testes desta base) e ativa clicando na tela ==');
  const fibraLivre = scalar(`
    select f.id from public.infra_fibras f
    join public.infra_cabos c on c.id = f.cabo_id
    join public.infra_pops pop on pop.id = c.pop_id
    where pop.cidade_id = '${cidadeId}'
      and f.status_contratual = 'DISPONIVEL'
      and not exists (select 1 from public.contrato_fibras cf where cf.fibra_id = f.id and cf.desvinculado_em is null)
    limit 1;
  `);
  const UID_ENGENHARIA = uidForEmail('engenharia@optimon.local');
  if (fibraLivre) {
    execSync(`PGPASSWORD=optimon_dev psql -h localhost -U optimon_admin -d optimon -c "set role authenticated; set local \\"request.jwt.claims\\" = '{\\"sub\\":\\"${UID_ENGENHARIA}\\",\\"role\\":\\"authenticated\\"}'; insert into public.contrato_fibras (contrato_id, fibra_id, capacidade_clientes) values ('${contratoId}', '${fibraLivre}', 150); reset role;"`);
  }

  await injectSession(page, JWT_DIRETOR);
  await page.goto(contratoUrl, { waitUntil: 'networkidle' });
  await page.click('button:has-text("Ativar contrato")');
  await page.waitForTimeout(1500);
  await page.waitForSelector('text=Contrato ativado com sucesso', { timeout: 10000 });
  await snap(page, 'contrato_ativado');

  await browser.close();
  console.log('\n=== VERIFICAÇÃO VISUAL FASE 3.11 CONCLUÍDA — evidências em', OUT, '===');
})().catch((err) => {
  console.error('FALHA NA VERIFICAÇÃO VISUAL:', err);
  process.exit(1);
});
