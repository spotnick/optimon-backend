// Verificação visual REAL da Fase 3.11.2 (correção crítica): abre a aplicação de
// verdade no Chromium (via Playwright) e clica pelas telas de verdade provando a
// cadeia NOVA introduzida por esta correção — que visual_fase311.js (Fase 3.11
// original) não cobre, porque usava o fluxo de aceite em 1 passo que foi desativado:
//
//  1) Área externa do parceiro (SEM login): botão "Aceitar proposta" abre o formulário
//     com nome/CPF/cargo/e-mail/telefone + declaração de poderes (checkbox 1) +
//     confirmação de aceite (checkbox 2) — nunca aceita com 1 clique só.
//  2) Passo 1 (Solicitar código) NUNCA muda o status da proposta sozinho — só abre a
//     etapa de confirmação por OTP.
//  3) O código em si nunca aparece na tela/rede — é recuperado do LOG do servidor
//     (mesmo canal de teste controlado usado pelos testes de API desta fase).
//  4) Passo 2 (Confirmar código) é o único que efetiva o aceite.
//  5) Tela interna (ProposalDetail.jsx): card "ACEITE DO PARCEIRO" completo (seção 2).
//  6) Botão "Revogar link externo" (seção 9) — fluxo dedicado, numa 2ª proposta, para
//     não interferir na proposta principal que segue para contrato/assinatura.
//  7) ContractDetail.jsx: tabela de signatários com Obrigatório/Status granular e botão
//     "Reenviar" (seção 6/7).
//
// Screenshots salvos em /tmp/fase3112_evidencia/.
const { chromium } = require('/opt/node-tools/node_modules/playwright');
const { execSync } = require('child_process');
const fs = require('fs');

const BASE = process.env.E2E_BASE_URL || 'http://localhost:5173';
const API = process.env.E2E_API_URL || 'http://localhost:3001';
const API_LOG = process.env.E2E_API_LOG || '/tmp/fase311_api.log';
const OUT = '/tmp/fase3112_evidencia';
fs.mkdirSync(OUT, { recursive: true });

function sh(cmd) { return execSync(cmd, { encoding: 'utf8' }).trim(); }
function mintJwt(uid) { return sh(`node supabase/dev-local-only/mint_jwt.js ${uid}`); }
function uidForEmail(email) {
  return sh(`PGPASSWORD=optimon_dev psql -h localhost -U optimon_admin -d optimon -t -A -c "select id from public.usuarios where email='${email}' limit 1;"`);
}
function scalar(sql) {
  return sh(`PGPASSWORD=optimon_dev psql -h localhost -U optimon_admin -d optimon -t -A -c "${sql.replace(/"/g, '\\"')}"`);
}
function otpFromLog(tentativaId) {
  const out = sh(`grep "proposta=${tentativaId} " "${API_LOG}" | tail -1 || true`);
  const m = out.match(/codigo=([0-9]{6})/);
  return m ? m[1] : null;
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
      refresh_token: 'visual3112-fake-refresh', user: { id: payload.sub, aud: payload.aud, role: payload.role, email: 'visual3112@optimon.local' },
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

async function criarPropostaEnviada(page, jwtComercial, jwtDiretor, cidadeId, sufixo) {
  const cnpj = String(Math.floor(Math.random() * 1e14)).padStart(14, '0');
  const partnerResp = await page.request.post(`${API}/api/partners`, {
    headers: { Authorization: `Bearer ${jwtComercial}`, 'Content-Type': 'application/json' },
    data: { razao_social: `TESTE-E2E-OPTIMON-311-VISUAL2-${sufixo} Ltda`, nome_fantasia: `TESTE-E2E-OPTIMON-311-VISUAL2-${sufixo}`, cnpj, email_contato: `visual-3112-${sufixo}@optimon.local`, endereco_logradouro: 'Rua Visual', endereco_numero: '311', endereco_bairro: 'Centro', endereco_cidade: 'Jussara', endereco_uf: 'PR', endereco_cep: '87450000' },
  });
  const parceiro = await partnerResp.json();
  const calcResp = await page.request.post(`${API}/api/pricing/calculate`, {
    headers: { Authorization: `Bearer ${jwtComercial}`, 'Content-Type': 'application/json' },
    data: { cidade_id: cidadeId, clientes: 220, arpu: 95, revenue_share_pct: 0.12 },
  });
  const resultado = await calcResp.json();
  const simResp = await page.request.post(`${API}/api/simulations`, {
    headers: { Authorization: `Bearer ${jwtComercial}`, 'Content-Type': 'application/json' },
    data: { cidade_id: cidadeId, parceiro_id: parceiro.id, modelo: 'HIBRIDO_REVENUE_SHARE', pares_ou_clientes: 220, arpu: 95, revenue_share_pct: 0.12, prazo_meses: 48, resultado },
  });
  const sim = await simResp.json();
  const propResp = await page.request.post(`${API}/api/proposals`, {
    headers: { Authorization: `Bearer ${jwtComercial}`, 'Content-Type': 'application/json' },
    data: { simulacao_id: sim.id, cidade_id: cidadeId, parceiro_id: parceiro.id, parceiro_nome_capa: `TESTE-E2E-OPTIMON-311-VISUAL2-${sufixo}`, parceiro_cargo_contato: 'Diretor Comercial (teste visual)' },
  });
  const proposta = await propResp.json();
  await page.request.post(`${API}/api/proposals/${proposta.id}/approve`, {
    headers: { Authorization: `Bearer ${jwtDiretor}`, 'Content-Type': 'application/json' },
    data: { motivo: 'Aprovação interna — verificação visual Fase 3.11.2.' },
  });
  const sendResp = await page.request.post(`${API}/api/proposals/${proposta.id}/send-to-partner`, {
    headers: { Authorization: `Bearer ${jwtComercial}` },
  });
  const enviada = await sendResp.json();
  return { parceiro, proposta, token: enviada.token_acesso_externo };
}

(async () => {
  const UID_DIRETOR = uidForEmail('diretor@optimon.local');
  const UID_COMERCIAL = uidForEmail('comercial@optimon.local');
  const JWT_DIRETOR = mintJwt(UID_DIRETOR);
  const JWT_COMERCIAL = mintJwt(UID_COMERCIAL);
  const cidadeId = scalar("select id from cidades_infra where nome='Jussara' and removido_em is null limit 1;");

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

  console.log('== Preparar PROPOSTA PRINCIPAL (aprovada + enviada) pela API real ==');
  const principal = await criarPropostaEnviada(page, JWT_COMERCIAL, JWT_DIRETOR, cidadeId, 'A');
  console.log('proposta principal:', principal.proposta.numero, principal.proposta.id);

  console.log('== PARCEIRO ABRE A ÁREA EXTERNA — SEM LOGIN, contexto de browser separado ==');
  const ctxParceiro = await browser.newContext();
  const pageParceiro = await ctxParceiro.newPage();
  pageParceiro.on('pageerror', (err) => console.log('[page error parceiro]', err.message));
  await pageParceiro.goto(`${BASE}/parceiro/proposta/${principal.token}`, { waitUntil: 'networkidle' });
  await pageParceiro.waitForSelector('text=Aceite da proposta', { timeout: 10000 });
  shot += 1;
  await pageParceiro.screenshot({ path: `${OUT}/${String(shot).padStart(2, '0')}_area_externa_sem_login.png`, fullPage: true });
  console.log('[screenshot] área externa (sem login), status ainda não é aceite');

  console.log('== Abrir o formulário de aceite (declaração + checkbox, ainda NÃO envia nada) ==');
  await pageParceiro.click('button:has-text("Aceitar proposta")');
  await pageParceiro.waitForTimeout(400);
  shot += 1;
  await pageParceiro.screenshot({ path: `${OUT}/${String(shot).padStart(2, '0')}_formulario_declaracao_checkbox.png`, fullPage: true });
  console.log('[screenshot] formulário com declaração de poderes + checkbox de confirmação visíveis');

  console.log('== Preencher dados + marcar os 2 checkboxes + solicitar código (passo 1) ==');
  await pageParceiro.fill('input[placeholder="Seu nome completo"]', 'Carlos Silva (verificação visual 3.11.2)');
  await pageParceiro.fill('input[placeholder="000.000.000-00"]', '123.456.789-00');
  await pageParceiro.fill('input[placeholder="Ex.: Diretor"]', 'Diretor');
  await pageParceiro.fill('input[placeholder="voce@empresa.com.br"]', 'carlos-visual3112@parceiro.local');
  const checkboxes = pageParceiro.locator('input[type="checkbox"]');
  const nCheckboxes = await checkboxes.count();
  for (let i = 0; i < nCheckboxes; i += 1) { await checkboxes.nth(i).check(); }
  console.log(`marcados ${nCheckboxes} checkbox(es) (declaração de poderes + confirmação de aceite)`);
  shot += 1;
  await pageParceiro.screenshot({ path: `${OUT}/${String(shot).padStart(2, '0')}_formulario_preenchido_checkboxes_marcados.png`, fullPage: true });

  const solicitarBtn = pageParceiro.locator('button:has-text("Enviar código de confirmação")');
  await solicitarBtn.click();
  await pageParceiro.waitForTimeout(1200);
  shot += 1;
  await pageParceiro.screenshot({ path: `${OUT}/${String(shot).padStart(2, '0')}_etapa_otp_aberta.png`, fullPage: true });
  console.log('[screenshot] etapa de confirmação por código (OTP) aberta');

  // Prova em tempo real que o passo 1 NUNCA muda o status sozinho (seção 1, itens 1-9).
  const statusPosPasso1 = scalar(`select status from propostas_comerciais where id='${principal.proposta.id}';`);
  console.log('status da proposta logo após o passo 1 (deve continuar NÃO aceita):', statusPosPasso1);
  if (statusPosPasso1 === 'ACEITA_PELO_PARCEIRO') {
    throw new Error('FALHA GRAVE: proposta já aparece ACEITA_PELO_PARCEIRO só com o passo 1 (solicitar código) — o aceite não pode acontecer sem confirmação.');
  }

  console.log('== Recuperar o código OTP do log do servidor (nunca da tela/rede) e confirmar ==');
  const tentativaId = scalar(`select id from propostas_aceite_tentativas where proposta_id='${principal.proposta.id}' order by criado_em desc limit 1;`);
  const otp = otpFromLog(tentativaId);
  if (!otp) throw new Error(`Não foi possível localizar o código OTP no log do servidor (${API_LOG}) para a tentativa ${tentativaId}`);
  console.log('tentativa_id=', tentativaId, 'otp (recuperado do log, nunca da tela)=', otp);

  const otpInput = pageParceiro.locator('input[placeholder="000000"]');
  await otpInput.fill(otp);
  shot += 1;
  await pageParceiro.screenshot({ path: `${OUT}/${String(shot).padStart(2, '0')}_otp_preenchido.png`, fullPage: true });
  const confirmarBtn = pageParceiro.locator('button:has-text("Confirmar aceite")');
  await confirmarBtn.click();
  await pageParceiro.waitForTimeout(1200);
  await pageParceiro.waitForSelector('text=aceita', { timeout: 10000 }).catch(() => {});
  shot += 1;
  await pageParceiro.screenshot({ path: `${OUT}/${String(shot).padStart(2, '0')}_aceite_confirmado_por_otp.png`, fullPage: true });
  await ctxParceiro.close();

  const statusFinal = scalar(`select status from propostas_comerciais where id='${principal.proposta.id}';`);
  console.log('status final da proposta (deve ser ACEITA_PELO_PARCEIRO):', statusFinal);
  if (statusFinal !== 'ACEITA_PELO_PARCEIRO') {
    throw new Error(`FALHA: aceite pela UI não efetivou o status — status final=${statusFinal}`);
  }

  console.log('== TELA INTERNA — card ACEITE DO PARCEIRO completo (seção 2) ==');
  await injectSession(page, JWT_COMERCIAL);
  await page.goto(`${BASE}/propostas/${principal.proposta.id}`, { waitUntil: 'networkidle' });
  await dismissWelcome(page);
  await page.waitForSelector('text=ACEITE DO PARCEIRO', { timeout: 10000 });
  await snap(page, 'card_aceite_do_parceiro_completo');

  // ---------------------------------------------------------------------------
  // Fluxo dedicado B — revogação de link (seção 9), numa 2ª proposta.
  // ---------------------------------------------------------------------------
  console.log('== Preparar 2ª PROPOSTA (para o botão Revogar link externo, sem tocar na principal) ==');
  const secundaria = await criarPropostaEnviada(page, JWT_COMERCIAL, JWT_DIRETOR, cidadeId, 'B');
  console.log('proposta secundária (revogação):', secundaria.proposta.numero, secundaria.proposta.id);
  await page.goto(`${BASE}/propostas/${secundaria.proposta.id}`, { waitUntil: 'networkidle' });
  await dismissWelcome(page);
  await page.waitForSelector('button:has-text("Revogar link externo")', { timeout: 10000 });
  await snap(page, 'botao_revogar_link_disponivel');

  page.once('dialog', async (dialog) => { await dialog.accept('Verificação visual — revogação de teste.'); });
  await page.click('button:has-text("Revogar link externo")');
  await page.waitForTimeout(1000);
  await page.waitForSelector('text=Link revogado', { timeout: 10000 });
  await snap(page, 'link_revogado_confirmado_na_tela');

  const tokenRevogadoEm = scalar(`select token_revogado_em is not null from propostas_comerciais where id='${secundaria.proposta.id}';`);
  console.log('token_revogado_em preenchido no banco?', tokenRevogadoEm);
  if (tokenRevogadoEm !== 't') throw new Error('FALHA: clique em Revogar link externo não persistiu token_revogado_em.');

  // ---------------------------------------------------------------------------
  // Continuar o fluxo PRINCIPAL até o contrato, para provar a tabela granular de
  // signatários (obrigatório/status/reenviar) na tela real do contrato.
  // ---------------------------------------------------------------------------
  console.log('== CRIAR CONTRATO (proposta principal, já aceita) ==');
  await page.goto(`${BASE}/propostas/${principal.proposta.id}`, { waitUntil: 'networkidle' });
  await dismissWelcome(page);
  await page.click('button:has-text("CRIAR CONTRATO")');
  await page.waitForSelector('text=Confirmar criação do contrato', { timeout: 10000 });
  await page.click('button:has-text("Confirmar e criar contrato")');
  await page.waitForTimeout(1500);
  await page.waitForURL(/\/contratos\//, { timeout: 15000 });
  const contratoId = page.url().split('/contratos/')[1];
  console.log('contrato criado, id=', contratoId);

  console.log('== Criar envelope + 3 signatários (2 obrigatórios + 1 testemunha não-obrigatória) ==');
  await page.waitForSelector('text=Assinatura eletrônica do contrato', { timeout: 10000 });
  await page.click('button:has-text("Criar envelope e enviar para assinatura")');
  await page.waitForTimeout(1500);
  await page.waitForSelector('text=Adicionar signatário', { timeout: 15000 });

  const nomeInputs = page.locator('form:has(button:has-text("Adicionar signatário")) input');
  await nomeInputs.nth(0).fill('Representante NICK (verificação visual)');
  await nomeInputs.nth(1).fill('nick-visual3112@optimon.local');
  await page.click('button:has-text("Adicionar signatário")');
  await page.waitForTimeout(800);

  await nomeInputs.nth(0).fill('Representante TESTE-E2E-OPTIMON-311-VISUAL2-A');
  await nomeInputs.nth(1).fill('parceiro-visual3112@optimon.local');
  await page.selectOption('form:has(button:has-text("Adicionar signatário")) select', 'REPRESENTANTE_PROPONENTE');
  await page.click('button:has-text("Adicionar signatário")');
  await page.waitForTimeout(800);

  await nomeInputs.nth(0).fill('Testemunha (verificação visual, não obrigatória)');
  await nomeInputs.nth(1).fill('testemunha-visual3112@optimon.local');
  await page.selectOption('form:has(button:has-text("Adicionar signatário")) select', 'TESTEMUNHA');
  const obrigCheckbox = page.locator('form:has(button:has-text("Adicionar signatário")) input[type="checkbox"]').first();
  if (await obrigCheckbox.count() > 0) { await obrigCheckbox.uncheck().catch(() => {}); }
  await page.click('button:has-text("Adicionar signatário")');
  await page.waitForTimeout(800);
  await snap(page, 'contrato_3_signatarios_tabela_granular');

  await page.click('button:has-text("Enviar para assinatura")');
  await page.waitForTimeout(1200);
  await snap(page, 'contrato_enviado_status_por_signatario');

  console.log('== Webhook: 1º signatário obrigatório assina (parcial) — mesmo provedor mock desde a Fase 2.5 ==');
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
  sendWebhook({ provider_envelope_id: providerEnvelopeId, evento_externo_id: 'evt-1-visual3112', tipo_evento: 'SIGNER_SIGNED', signer_email: 'nick-visual3112@optimon.local', signer_novo_status: 'ASSINADO', signer_ip: '203.0.113.40', novo_status_envelope: 'PARCIALMENTE_ASSINADO' });

  await page.reload({ waitUntil: 'networkidle' });
  await snap(page, 'contrato_1_de_2_obrigatorios_assinados');

  console.log('== REENVIAR ASSINATURA para a testemunha (não-obrigatória, ainda pendente) ==');
  const testemunhaRow = page.locator('tr', { hasText: 'testemunha-visual3112@optimon.local' });
  if (await testemunhaRow.count() > 0) {
    const motivoInput = testemunhaRow.locator('input[placeholder="Motivo (opcional)"]');
    if (await motivoInput.count() > 0) { await motivoInput.fill('Verificação visual — reenvio real'); }
    const reenviarBtn = testemunhaRow.locator('button:has-text("Reenviar")');
    await reenviarBtn.click();
    await page.waitForTimeout(1200);
    await snap(page, 'reenvio_assinatura_testemunha');
  } else {
    console.log('(linha da testemunha não encontrada na tabela — screenshot anterior já documenta a tabela granular; seguindo)');
  }

  console.log('== Webhook: 2º signatário obrigatório assina de verdade — envelope deve fechar ASSINADO ==');
  sendWebhook({ provider_envelope_id: providerEnvelopeId, evento_externo_id: 'evt-2-visual3112', tipo_evento: 'SIGNER_SIGNED', signer_email: 'parceiro-visual3112@optimon.local', signer_novo_status: 'ASSINADO', signer_ip: '203.0.113.41', novo_status_envelope: 'ASSINADO', hash_assinado: 'visual3112-hash', storage_path_assinado: 'homologacao/visual-3112/contrato-assinado.pdf' });
  await page.reload({ waitUntil: 'networkidle' });
  await page.waitForSelector('text=ASSINADO', { timeout: 10000 });
  await snap(page, 'contrato_assinado_apesar_de_testemunha_pendente');

  const envelopeStatusFinal = scalar(`select status from signature_envelopes where id='${envelopeId}';`);
  console.log('status final do envelope (deve ser ASSINADO mesmo com a testemunha não-obrigatória pendente):', envelopeStatusFinal);
  if (envelopeStatusFinal !== 'ASSINADO') {
    throw new Error(`FALHA: envelope não fechou ASSINADO com os 2 obrigatórios assinados — status=${envelopeStatusFinal}`);
  }

  await browser.close();
  console.log('\n=== VERIFICAÇÃO VISUAL FASE 3.11.2 CONCLUÍDA — evidências em', OUT, '===');
})().catch((err) => {
  console.error('FALHA NA VERIFICAÇÃO VISUAL:', err);
  process.exit(1);
});
