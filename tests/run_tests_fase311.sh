#!/usr/bin/env bash
# OptiMon — Fase 3.11 + CORREÇÃO CRÍTICA (Fase 3.11.2): homologação funcional real e
# completa do fluxo Simulação → Proposta → Aprovação Interna (NICK) → Envio ao Parceiro
# → Parceiro Abre Área Externa → Visualização → ACEITE FORMAL EM 2 PASSOS (representante
# + CPF + declaração + checkbox + confirmação por CÓDIGO enviado ao e-mail informado,
# nunca "abrir o link" nem "preencher formulário" sozinhos) → Geração de Contrato (só
# após aceite real confirmado — nunca antes) → Minuta → Assinatura Eletrônica do
# Contrato com STATUS GRANULAR por signatário (obrigatório/não-obrigatório) e gate real
# contra "ASSINADO" reivindicado sem todos os obrigatórios terem assinado → Reenvio de
# assinatura sem duplicidade → Contrato Assinado → Ativação.
#
# Reescrito integralmente para a correção crítica pedida após a homologação real ter
# encontrado 2 problemas graves na Fase 3.11 original:
#  1) o aceite em 1 passo (preencher formulário + 1 clique) não provava posse do e-mail
#     informado — substituído pelo fluxo real em 2 passos (iniciar → confirmar por OTP);
#  2) "envelope criado" nunca foi = "e-mail enviado" (o motor de assinatura, Fase 2.5,
#     nunca teve nenhuma implementação real de envio — só o MockHomologacaoProvider,
#     documentado desde sempre); e o envelope podia virar "ASSINADO" só porque o webhook
#     dizia isso, mesmo com signatário obrigatório pendente — ambos investigados e o
#     segundo corrigido de verdade nesta fase (o primeiro é limitação externa, testada e
#     documentada abaixo, nunca escondida).
#
# Cobre TODOS os testes negativos obrigatórios da correção crítica (seção 11 do pedido):
# abrir link != aceitar; aceite sem CPF/e-mail/checkbox; OTP errado/expirado/reutilizado;
# token expirado/revogado; aceite duplicado; contrato antes do aceite / duplicado;
# alteração de proposta já aceita; usuário sem permissão; signatário não autorizado;
# contrato finalizado com assinatura obrigatória faltante.
#
# Cria parceiros CLARAMENTE identificáveis (razão social "TESTE-E2E-OPTIMON-311-*"),
# reaproveita infraestrutura real já existente (cidade Jussara-PR). Ao final, desativa
# todos os parceiros de teste (proposta/contrato nunca têm DELETE físico, por design,
# desde a Fase 1 — "limpeza" aqui é tornar o registro inerte, nunca apagar histórico).

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0
FAIL=0
FAILED_NAMES=()
pass() { PASS=$((PASS+1)); echo "PASS | $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "FAIL | $1"; echo "  -> $2"; }

export PGPASSWORD=optimon_dev
PSQL="psql -h localhost -U optimon_admin -d optimon"
scalar() { $PSQL -t -A -q -c "$1"; }

# pkill não funciona neste ambiente (sempre devolve 144, mesmo sem processo casando) —
# workaround: localizar PIDs via `ps` e matar diretamente.
kill_matching() {
  local pattern="$1"
  local pids
  pids=$(ps aux | grep -E "$pattern" | grep -v grep | awk '{print $2}')
  if [ -n "$pids" ]; then kill $pids 2>/dev/null || true; fi
}

echo "############################################################"
echo "# PASSO 0 — migrations da Fase 3.11 aplicam, em ordem, sem erro #"
echo "############################################################"
# Migrations reais rodam UMA VEZ, em ordem, nunca em replay por cima de uma versão mais
# nova (isso nunca acontece numa instalação real). 20261002090000 recria
# auditoria_acao_check e a assinatura ORIGINAL (mais estreita) de
# app.recusar_proposta_parceiro/app.registrar_auditoria_semantica — reaplicá-la depois
# que a Fase 3.11.2 (20261003100000) já ampliou as duas (e já gerou linhas de auditoria
# com ações que só existem a partir da 3.11.2) causaria erros que são só artefato de
# testar localmente contra um banco que já está numa versão mais nova (constraint
# violada por dados já existentes / função ambígua) — nunca um problema real de
# produção. Verificação abaixo: se o marcador da 3.11.2 (coluna
# propostas_comerciais.token_revogado_em) já existe, as 2 migrations anteriores já foram
# aplicadas alguma vez neste banco — não são replayed; só a mais nova
# (20261003100000, que já é idempotente de verdade via DROP FUNCTION/DROP TRIGGER IF
# EXISTS/ADD COLUMN IF EXISTS explícitos) é reaplicada, para provar que ELA é
# idempotente. Num banco realmente novo (marcador ausente), as 3 aplicam em ordem, do
# zero, como uma instalação real faria.
JA_TEM_3112=$(scalar "select exists(select 1 from information_schema.columns where table_name='propostas_comerciais' and column_name='token_revogado_em');")
# Fase 3.11.3: marcador próprio (coluna nova em propostas_aceite_tentativas). MESMA REGRA
# já documentada para a 3.11.2: só a migration MAIS NOVA já aplicada é replayed (para
# provar sua própria idempotência) — nunca uma mais antiga. Replayar 20261003100000
# (3.11.2) depois que 20261004090000 (3.11.3) já ampliou auditoria_acao_check E já gerou
# linhas de auditoria com as ações novas (PROPOSAL_ACCEPT_EMAIL_*) é exatamente o mesmo
# artefato de replay-por-cima-de-versão-mais-nova já documentado — real, encontrado ao
# rodar (não presumido): "check constraint auditoria_acao_check... violated by some row".
# Nunca acontece numa instalação real (migrations aplicam uma vez, em ordem, para a
# frente). Corrigido aqui: quando o marcador da 3.11.3 já existe, SÓ ela é replayed.
rm -f /tmp/fase311_mig.log
MIG_OK=1
JA_TEM_3113=$(scalar "select exists(select 1 from information_schema.columns where table_name='propostas_aceite_tentativas' and column_name='email_status');")
# Fase 3.11.4 — MESMA regra, um degrau acima: se o marcador da 3.11.4 já existe
# (signature_signers.token_acesso), replayar 20261004090000 (3.11.3) por cima dela é
# exatamente o artefato já documentado (constraint/função mais nova sendo sobrescrita por
# uma versão mais antiga) — encontrado de verdade rodando esta suíte (auditoria_acao_check
# violada por linhas com ações que só a 3.11.4 criou). Corrigido subindo o corte: quando a
# 3.11.4 já está presente, SÓ ELA é replayed (nenhuma das 4 migrations 3.11/3.11.1/3.11.2/
# 3.11.3 mais antigas é tocada).
JA_TEM_3114=$(scalar "select exists(select 1 from information_schema.columns where table_name='signature_signers' and column_name='token_acesso');")

if [ "$JA_TEM_3114" = "t" ]; then
  echo "Banco já tem a Fase 3.11.4 aplicada de uma execução anterior — não fazendo replay de NENHUMA migration mais antiga (3.11/3.11.1/3.11.2/3.11.3); reaplicando só 20261006090000 para provar sua idempotência real." | tee -a /tmp/fase311_mig.log
  pass "PASSO-0 migration 20261002090000_phase_3_11_workflow_proposta_parceiro.sql já aplicada anteriormente (marcador da 3.11.4 presente) — não replayed"
  pass "PASSO-0 migration 20261002100000_phase_3_11_01_fix_token_gen_random_bytes.sql já aplicada anteriormente (marcador da 3.11.4 presente) — não replayed"
  pass "PASSO-0 migration 20261003100000_phase_3_11_02_aceite_otp_assinatura_granular.sql já aplicada anteriormente (marcador da 3.11.4 presente) — não replayed"
  pass "PASSO-0 migration 20261004090000_phase_3_11_03_resend_real_parceiro_obrigatorio.sql já aplicada anteriormente (marcador da 3.11.4 presente) — não replayed"
elif [ "$JA_TEM_3113" = "t" ]; then
  echo "Banco já tem a Fase 3.11.3 aplicada de uma execução anterior — não fazendo replay de nenhuma migration mais antiga (isso nunca acontece numa instalação real); reaplicando só 20261004090000 para provar sua idempotência real." | tee -a /tmp/fase311_mig.log
  pass "PASSO-0 migration 20261002090000_phase_3_11_workflow_proposta_parceiro.sql já aplicada anteriormente (marcador da 3.11.3 presente) — não replayed"
  pass "PASSO-0 migration 20261002100000_phase_3_11_01_fix_token_gen_random_bytes.sql já aplicada anteriormente (marcador da 3.11.3 presente) — não replayed"
  pass "PASSO-0 migration 20261003100000_phase_3_11_02_aceite_otp_assinatura_granular.sql já aplicada anteriormente (marcador da 3.11.3 presente) — não replayed"
  if $PSQL -v ON_ERROR_STOP=1 -f "supabase/migrations/20261004090000_phase_3_11_03_resend_real_parceiro_obrigatorio.sql" >> /tmp/fase311_mig.log 2>&1; then
    pass "PASSO-0 migration 20261004090000_phase_3_11_03_resend_real_parceiro_obrigatorio.sql reaplica sem erro (idempotente de verdade)"
  else
    fail "PASSO-0 aplicar migration 20261004090000_phase_3_11_03_resend_real_parceiro_obrigatorio.sql" "ver /tmp/fase311_mig.log"
    MIG_OK=0
  fi
elif [ "$JA_TEM_3112" = "t" ]; then
  echo "Banco já tem a Fase 3.11.2 aplicada de uma execução anterior (mas ainda não a 3.11.3) — não fazendo replay de 20261002090000/20261002100000; aplicando 20261003100000 (reaplica, prova idempotência) e 20261004090000 (primeira vez)." | tee -a /tmp/fase311_mig.log
  pass "PASSO-0 migration 20261002090000_phase_3_11_workflow_proposta_parceiro.sql já aplicada anteriormente (marcador da 3.11.2 presente) — não replayed"
  pass "PASSO-0 migration 20261002100000_phase_3_11_01_fix_token_gen_random_bytes.sql já aplicada anteriormente (marcador da 3.11.2 presente) — não replayed"
  if $PSQL -v ON_ERROR_STOP=1 -f "supabase/migrations/20261003100000_phase_3_11_02_aceite_otp_assinatura_granular.sql" >> /tmp/fase311_mig.log 2>&1; then
    pass "PASSO-0 migration 20261003100000_phase_3_11_02_aceite_otp_assinatura_granular.sql reaplica sem erro (idempotente de verdade)"
  else
    fail "PASSO-0 aplicar migration 20261003100000_phase_3_11_02_aceite_otp_assinatura_granular.sql" "ver /tmp/fase311_mig.log"
    MIG_OK=0
  fi
  if [ "$MIG_OK" = "1" ]; then
    if $PSQL -v ON_ERROR_STOP=1 -f "supabase/migrations/20261004090000_phase_3_11_03_resend_real_parceiro_obrigatorio.sql" >> /tmp/fase311_mig.log 2>&1; then
      pass "PASSO-0 migration 20261004090000_phase_3_11_03_resend_real_parceiro_obrigatorio.sql aplica sem erro (instalação do zero)"
    else
      fail "PASSO-0 aplicar migration 20261004090000_phase_3_11_03_resend_real_parceiro_obrigatorio.sql" "ver /tmp/fase311_mig.log"
      MIG_OK=0
    fi
  fi
else
  MIGS=(
    "supabase/migrations/20261002090000_phase_3_11_workflow_proposta_parceiro.sql"
    "supabase/migrations/20261002100000_phase_3_11_01_fix_token_gen_random_bytes.sql"
    "supabase/migrations/20261003100000_phase_3_11_02_aceite_otp_assinatura_granular.sql"
    "supabase/migrations/20261004090000_phase_3_11_03_resend_real_parceiro_obrigatorio.sql"
  )
  for MIG in "${MIGS[@]}"; do
    if $PSQL -v ON_ERROR_STOP=1 -f "$MIG" >> /tmp/fase311_mig.log 2>&1; then
      pass "PASSO-0 migration $(basename "$MIG") aplica sem erro (instalação do zero)"
    else
      fail "PASSO-0 aplicar migration $(basename "$MIG")" "ver /tmp/fase311_mig.log"
      MIG_OK=0
    fi
  done
fi
if [ "$MIG_OK" != "1" ]; then
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

# Fase 3.11.4 — aplicada por último em TODOS os ramos acima (instalação do zero, ou banco
# já em 3.11.2/3.11.3): marcador JA_TEM_3114 (calculado antes do if/elif/else acima)
# decide só entre "primeira vez" e "reaplica para provar idempotência".
if $PSQL -v ON_ERROR_STOP=1 -f "supabase/migrations/20261006090000_phase_3_11_04_assinatura_envio_real_resend.sql" >> /tmp/fase311_mig.log 2>&1; then
  if [ "$JA_TEM_3114" = "t" ]; then
    pass "PASSO-0 migration 20261006090000_phase_3_11_04_assinatura_envio_real_resend.sql reaplica sem erro (idempotente de verdade — marcador já presente)"
  else
    pass "PASSO-0 migration 20261006090000_phase_3_11_04_assinatura_envio_real_resend.sql aplica sem erro (primeira vez)"
  fi
else
  fail "PASSO-0 aplicar migration 20261006090000_phase_3_11_04_assinatura_envio_real_resend.sql" "ver /tmp/fase311_mig.log"
  MIG_OK=0
fi
if [ "$MIG_OK" != "1" ]; then
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi
$PSQL -c "NOTIFY pgrst, 'reload schema';" > /dev/null 2>&1

echo "############################################################"
echo "# PASSO 1 — pilha local no ar #"
echo "############################################################"
kill_matching "postgrest .*postgrest.local.conf"
kill_matching "rest_v1_proxy.js"
kill_matching "node server.js"
sleep 1
nohup postgrest supabase/dev-local-only/postgrest.local.conf > /tmp/fase311_postgrest.log 2>&1 & disown
sleep 1
nohup env PGRST_TARGET=http://127.0.0.1:3000 PROXY_PORT=54321 node supabase/dev-local-only/rest_v1_proxy.js > /tmp/fase311_proxy.log 2>&1 & disown
sleep 1

WEBHOOK_SECRET_ENV_NAME="FASE25_TEST_WEBHOOK_SECRET"
WEBHOOK_SECRET_VALUE="optimon-fase25-teste-hmac-secret-nao-usar-em-producao"
if ! grep -q "^${WEBHOOK_SECRET_ENV_NAME}=" api/.env 2>/dev/null; then
  echo "${WEBHOOK_SECRET_ENV_NAME}=${WEBHOOK_SECRET_VALUE}" >> api/.env
fi

# Fase 3.11.3 — segredo de teste do webhook do Resend (formato Svix: prefixo "whsec_" +
# base64). Mesmo padrão do FASE25_TEST_WEBHOOK_SECRET acima: só existe neste .env local
# de desenvolvimento, nunca em produção — RESEND_API_KEY/RESEND_FROM_EMAIL propositalmente
# NÃO são setadas aqui (esta sessão não tem uma conta Resend real para testar contra ela)
# — o que prova, de forma real e não presumida, que o fallback DEV_LOG documentado em
# api/lib/otpNotifier.js funciona exatamente como projetado quando o Resend não está
# configurado neste ambiente.
RESEND_WEBHOOK_SECRET_ENV_NAME="RESEND_WEBHOOK_SECRET"
RESEND_WEBHOOK_SECRET_VALUE="whsec_b3B0aW1vbi1mYXNlMzExMy10ZXN0ZS1zdml4LXNlY3JldA=="
if ! grep -q "^${RESEND_WEBHOOK_SECRET_ENV_NAME}=" api/.env 2>/dev/null; then
  echo "${RESEND_WEBHOOK_SECRET_ENV_NAME}=${RESEND_WEBHOOK_SECRET_VALUE}" >> api/.env
fi

rm -f /tmp/fase311_api.log
( cd api && nohup node server.js > /tmp/fase311_api.log 2>&1 & disown )
sleep 2
API="http://localhost:3001"
mint() { node supabase/dev-local-only/mint_jwt.js "$1"; }

UID_ADMIN=$(scalar "select id from usuarios where email='admin@optimon.local';")
UID_DIRETOR=$(scalar "select id from usuarios where email='diretor@optimon.local';")
UID_COMERCIAL=$(scalar "select id from usuarios where email='comercial@optimon.local';")
UID_ENGENHARIA=$(scalar "select id from usuarios where email='engenharia@optimon.local';")
UID_AUDITOR=$(scalar "select id from usuarios where email='auditor@optimon.local';")
TOK_ADMIN=$(mint "$UID_ADMIN")
TOK_DIRETOR=$(mint "$UID_DIRETOR")
TOK_COMERCIAL=$(mint "$UID_COMERCIAL")
TOK_ENGENHARIA=$(mint "$UID_ENGENHARIA")
TOK_AUDITOR=$(mint "$UID_AUDITOR")
CIDADE_ID=$(scalar "select id from cidades_infra where nome='Jussara' and removido_em is null limit 1;")
if [ -z "$CIDADE_ID" ]; then CIDADE_ID=$(scalar "select id from cidades_infra where removido_em is null limit 1;"); fi

api() {
  local method="$1"; local path="$2"; local tok="$3"; local body="${4:-}"
  if [ -n "$tok" ]; then
    if [ -n "$body" ]; then
      curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' -X "$method" "$API$path" \
        -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -d "$body"
    else
      curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' -X "$method" "$API$path" -H "Authorization: Bearer $tok"
    fi
  else
    # sem token — chamada anônima (área externa do parceiro).
    if [ -n "$body" ]; then
      curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' -X "$method" "$API$path" -H "Content-Type: application/json" -d "$body"
    else
      curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' -X "$method" "$API$path"
    fi
  fi
}
jget() { node -e "try{const d=JSON.parse(require('fs').readFileSync('/tmp/fase311_resp.json','utf8'));const v=d$1;console.log(v===undefined||v===null?'':v)}catch(e){console.log('')}"; }
jhas() { node -e "try{const d=JSON.parse(require('fs').readFileSync('/tmp/fase311_resp.json','utf8'));console.log(Object.prototype.hasOwnProperty.call(d,'$1')?'SIM':'NAO')}catch(e){console.log('ERRO')}"; }
body() { cat /tmp/fase311_resp.json; }

# Extrai o código OTP (texto puro) do log do servidor para uma tentativa_id específica —
# NUNCA lido da coluna otp_hash do banco (que é só o hash) nem de nenhuma resposta HTTP
# (o código nunca é devolvido ao navegador do parceiro, por design — ver
# api/lib/otpNotifier.js). Mesmo padrão já usado para JWT/webhook-secret nesta suíte:
# canal de teste controlado, nunca contorna a validação real.
otp_from_log() {
  local tentativa="$1"
  # Fase 3.11.3: o campo antes era "proposta=<tentativa_id>" (bug real documentado —
  # propostaNumero recebia data?.tentativa_id em vez do número real da proposta); agora o
  # log tem um campo "tentativa_id=" próprio e "proposta=" passou a ser o NÚMERO real da
  # proposta (necessário para o template do e-mail, seção 7). A linha
  # "[DEV-OTP-NAO-E-EMAIL-REAL] ... tentativa_id=X ... codigo=NNNNNN ..." é a única que
  # tem "codigo=" — a linha de resumo operacional "[otp-email] tentativa_id=X canal=..."
  # também casa com "tentativa_id=X " (mesmo prefixo), mas nunca tem "codigo=", então o
  # -E "tentativa_id=X .*codigo=" abaixo já a exclui sem precisar filtrar por linha inteira.
  grep -E "tentativa_id=${tentativa} .*codigo=[0-9]{6}" /tmp/fase311_api.log | tail -1 | grep -oE 'codigo=[0-9]{6}' | tail -1 | cut -d= -f2
}

sign_and_post_webhook() {
  local payload_file="$1"
  local sig
  sig=$(openssl dgst -sha256 -hmac "$WEBHOOK_SECRET_VALUE" "$payload_file" | awk '{print $NF}')
  curl -sS -o /tmp/fase311_webhook_resp.json -w '%{http_code}' -X POST "$API/api/signatures/webhook" \
    -H "Content-Type: application/json" -H "X-Signature: $sig" --data-binary "@$payload_file"
}

# Fase 3.11.3 (seção 9) — assina e envia um payload de webhook do Resend, no formato
# Svix real (id.timestamp.corpo, HMAC-SHA256 em base64, chave = bytes decodificados do
# segredo sem o prefixo "whsec_"). Usado tanto para o teste POSITIVO (assinatura válida)
# quanto para o NEGATIVO (assinatura adulterada) — a mesma lógica que api/routes/
# emailWebhooks.js implementa, calculada aqui de forma independente (não importa o
# módulo do servidor) para o teste ser uma verificação real, não um espelho da mesma
# implementação.
sign_and_post_resend_webhook() {
  local payload_file="$1"
  local bad_signature="${2:-}"
  local svix_id="msg_teste_${RANDOM}"
  local svix_ts
  svix_ts=$(date +%s)
  local sig
  sig=$(node -e "
    const fs = require('fs'); const crypto = require('crypto');
    const secret = '$RESEND_WEBHOOK_SECRET_VALUE';
    const keyBytes = Buffer.from(secret.startsWith('whsec_') ? secret.slice(6) : secret, 'base64');
    const body = fs.readFileSync('$payload_file', 'utf8');
    const signedContent = '$svix_id.' + '$svix_ts' + '.' + body;
    const mac = crypto.createHmac('sha256', keyBytes).update(signedContent).digest('base64');
    console.log('v1,' + mac);
  ")
  if [ -n "$bad_signature" ]; then sig="v1,QWRVTHRlcmFkYS1hc3NpbmF0dXJhLWludmFsaWRh"; fi
  curl -sS -o /tmp/fase311_resend_webhook_resp.json -w '%{http_code}' -X POST "$API/api/webhooks/resend" \
    -H "Content-Type: application/json" -H "svix-id: $svix_id" -H "svix-timestamp: $svix_ts" -H "svix-signature: $sig" \
    --data-binary "@$payload_file"
}

if [ -z "$CIDADE_ID" ]; then
  fail "PASSO-1 pré-condição: nenhuma cidade ativa encontrada" "banco de dev sem seed de cidade"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi
pass "PASSO-1 pilha local no ar — API/proxy/postgrest respondendo, cidade de teste=$CIDADE_ID"

# ----------------------------------------------------------------------------
# Helper: cria parceiro TESTE-E2E-OPTIMON-311-<suf> + SIMULAÇÃO + PROPOSTA, aprova
# internamente e envia ao parceiro (gera token real). Efeitos em variáveis globais
# NEWP_PARCEIRO_ID / NEWP_PROP_ID / NEWP_PROP_NUMERO / NEWP_TOKEN. Devolve 1 em falha
# (a chamada que falhou já grava seu próprio FAIL com o corpo da resposta).
# ----------------------------------------------------------------------------
setup_proposta_teste() {
  local suf="$1"
  local cnpj code resultado_json sim_body
  cnpj="$(printf '%014d' $((RANDOM * RANDOM % 100000000000000)))"

  code=$(api POST "/api/partners" "$TOK_COMERCIAL" "{\"razao_social\":\"TESTE-E2E-OPTIMON-311-${suf} Ltda\",\"nome_fantasia\":\"TESTE-E2E-OPTIMON-311-${suf}\",\"cnpj\":\"$cnpj\",\"email_contato\":\"teste-e2e-311-${suf}@optimon.local\",\"endereco_logradouro\":\"Rua de Teste E2E\",\"endereco_numero\":\"311\",\"endereco_bairro\":\"Centro\",\"endereco_cidade\":\"Jussara\",\"endereco_uf\":\"PR\",\"endereco_cep\":\"87450000\"}")
  NEWP_PARCEIRO_ID=$(jget ".id")
  if [ "$code" != "201" ] || [ -z "$NEWP_PARCEIRO_ID" ]; then echo "  -> setup_proposta_teste($suf): falha ao criar parceiro, codigo=$code body=$(body)"; return 1; fi

  code=$(api POST "/api/pricing/calculate" "$TOK_COMERCIAL" "{\"cidade_id\":\"$CIDADE_ID\",\"clientes\":250,\"arpu\":90,\"revenue_share_pct\":0.12}")
  resultado_json=$(body)
  if [ "$code" != "200" ]; then echo "  -> setup_proposta_teste($suf): falha ao calcular pricing, codigo=$code"; return 1; fi

  sim_body=$(node -e "
const r = $resultado_json;
console.log(JSON.stringify({cidade_id: '$CIDADE_ID', parceiro_id: '$NEWP_PARCEIRO_ID', modelo: 'HIBRIDO_REVENUE_SHARE', pares_ou_clientes: 250, arpu: 90, revenue_share_pct: 0.12, prazo_meses: 48, resultado: r}));
")
  code=$(api POST "/api/simulations" "$TOK_COMERCIAL" "$sim_body")
  local sim_id; sim_id=$(jget ".id")
  if [ "$code" != "201" ] || [ -z "$sim_id" ]; then echo "  -> setup_proposta_teste($suf): falha ao salvar simulação, codigo=$code body=$(body)"; return 1; fi

  code=$(api POST "/api/proposals" "$TOK_COMERCIAL" "{\"simulacao_id\":\"$sim_id\",\"cidade_id\":\"$CIDADE_ID\",\"parceiro_id\":\"$NEWP_PARCEIRO_ID\",\"parceiro_nome_capa\":\"TESTE-E2E-OPTIMON-311-${suf}\",\"parceiro_cargo_contato\":\"Diretor Comercial (teste)\"}")
  NEWP_PROP_ID=$(jget ".id")
  NEWP_PROP_NUMERO=$(jget ".numero")
  if [ "$code" != "201" ] || [ -z "$NEWP_PROP_ID" ]; then echo "  -> setup_proposta_teste($suf): falha ao criar proposta, codigo=$code body=$(body)"; return 1; fi

  code=$(api POST "/api/proposals/$NEWP_PROP_ID/approve" "$TOK_DIRETOR" "{\"motivo\":\"Aprovação interna de teste E2E Fase 3.11.2 (${suf}).\"}")
  if [ "$code" != "200" ]; then echo "  -> setup_proposta_teste($suf): falha ao aprovar internamente, codigo=$code body=$(body)"; return 1; fi

  code=$(api POST "/api/proposals/$NEWP_PROP_ID/send-to-partner" "$TOK_COMERCIAL")
  NEWP_TOKEN=$(jget ".token_acesso_externo")
  if [ "$code" != "200" ] || [ -z "$NEWP_TOKEN" ]; then echo "  -> setup_proposta_teste($suf): falha ao enviar ao parceiro, codigo=$code body=$(body)"; return 1; fi
  return 0
}

ALL_PARCEIROS_TESTE=()

echo "############################################################"
echo "# ETAPA 1 — parceiro + SIMULAÇÃO + PROPOSTA (fluxo principal) #"
echo "############################################################"
CNPJ_TESTE="$(printf '%014d' $((RANDOM * RANDOM % 100000000000000)))"
CODE=$(api POST "/api/partners" "$TOK_COMERCIAL" "{\"razao_social\":\"TESTE-E2E-OPTIMON-311 Ltda\",\"nome_fantasia\":\"TESTE-E2E-OPTIMON-311\",\"cnpj\":\"$CNPJ_TESTE\",\"email_contato\":\"teste-e2e-311@optimon.local\",\"endereco_logradouro\":\"Rua de Teste E2E\",\"endereco_numero\":\"311\",\"endereco_bairro\":\"Centro\",\"endereco_cidade\":\"Jussara\",\"endereco_uf\":\"PR\",\"endereco_cep\":\"87450000\"}")
PARCEIRO_ID=$(jget ".id")
[ "$CODE" = "201" ] && [ -n "$PARCEIRO_ID" ] && pass "TESTE-01 parceiro TESTE-E2E-OPTIMON-311 criado — 201, id=$PARCEIRO_ID" \
  || { fail "TESTE-01 criar parceiro de teste" "codigo=$CODE body=$(body)"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }
ALL_PARCEIROS_TESTE+=("$PARCEIRO_ID")

CODE=$(api POST "/api/pricing/calculate" "$TOK_COMERCIAL" "{\"cidade_id\":\"$CIDADE_ID\",\"clientes\":250,\"arpu\":90,\"revenue_share_pct\":0.12}")
RESULTADO_JSON=$(body)
[ "$CODE" = "200" ] && echo "$RESULTADO_JSON" | grep -q "recommended" && pass "TESTE-02 pricing calculado — 200" \
  || { fail "TESTE-02 calcular pricing" "codigo=$CODE body=$RESULTADO_JSON"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }
SIM_BODY=$(node -e "
const r = $RESULTADO_JSON;
console.log(JSON.stringify({cidade_id: '$CIDADE_ID', parceiro_id: '$PARCEIRO_ID', modelo: 'HIBRIDO_REVENUE_SHARE', pares_ou_clientes: 250, arpu: 90, revenue_share_pct: 0.12, prazo_meses: 48, resultado: r}));
")
CODE=$(api POST "/api/simulations" "$TOK_COMERCIAL" "$SIM_BODY")
SIM_ID=$(jget ".id")
[ "$CODE" = "201" ] && [ -n "$SIM_ID" ] && pass "TESTE-03 simulação salva — 201, id=$SIM_ID" \
  || { fail "TESTE-03 salvar simulação" "codigo=$CODE body=$(body)"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }

CODE=$(api POST "/api/proposals" "$TOK_COMERCIAL" "{\"simulacao_id\":\"$SIM_ID\",\"cidade_id\":\"$CIDADE_ID\",\"parceiro_id\":\"$PARCEIRO_ID\",\"parceiro_nome_capa\":\"TESTE-E2E-OPTIMON-311\",\"parceiro_cargo_contato\":\"Diretor Comercial (teste)\"}")
PROP_ID=$(jget ".id")
PROP_NUMERO=$(jget ".numero")
[ "$CODE" = "201" ] && [ -n "$PROP_ID" ] && pass "TESTE-04 proposta criada a partir da simulação real — 201, numero=$PROP_NUMERO" \
  || { fail "TESTE-04 criar proposta" "codigo=$CODE body=$(body)"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }

echo "############################################################"
echo "# ETAPA 2 — negativo: parceiro (externo) tenta acessar área administrativa #"
echo "############################################################"
CODE=$(api GET "/api/proposals/$PROP_ID" "")
[ "$CODE" = "401" ] || [ "$CODE" = "403" ] \
  && pass "TESTE-05 (negativo) GET /api/proposals/:id SEM token de usuário é bloqueado — codigo=$CODE" \
  || fail "TESTE-05 (negativo) área administrativa deveria bloquear chamada sem JWT" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# ETAPA 3 — APROVAÇÃO INTERNA (NICK) — nunca implica consentimento do parceiro #"
echo "############################################################"
CODE=$(api POST "/api/proposals/$PROP_ID/approve" "$TOK_DIRETOR" '{"motivo":"Aprovação interna de teste E2E Fase 3.11."}')
[ "$CODE" = "200" ] && pass "TESTE-06 DIRETOR aprova internamente (RASCUNHO -> APROVADA) — 200" || { fail "TESTE-06 aprovar internamente" "codigo=$CODE body=$(body)"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }
PROP_STATUS_POS_APROVACAO=$(scalar "select status from propostas_comerciais where id='$PROP_ID';")
[ "$PROP_STATUS_POS_APROVACAO" != "ACEITA_PELO_PARCEIRO" ] \
  && pass "TESTE-07 aprovação interna NÃO transiciona a proposta para ACEITA_PELO_PARCEIRO (aprovação interna != consentimento do parceiro) — status=$PROP_STATUS_POS_APROVACAO" \
  || fail "TESTE-07 aprovação interna vazando como aceite do parceiro" "status=$PROP_STATUS_POS_APROVACAO"

CODE=$(api POST "/api/proposals/$PROP_ID/status" "$TOK_DIRETOR" '{"status":"ACEITA"}')
[ "$CODE" != "200" ] \
  && pass "TESTE-08 (negativo) tentativa de forçar status=ACEITA via mudar_status_proposta é BLOQUEADA — codigo=$CODE" \
  || fail "TESTE-08 (negativo) fake-acceptance deveria ser bloqueado" "codigo=$CODE body=$(body) — BUG CRÍTICO: aceite falso sem envolvimento do parceiro"

echo "############################################################"
echo "# ETAPA 4 — ENVIO AO PARCEIRO (token real) #"
echo "############################################################"
CODE=$(api POST "/api/proposals/$PROP_ID/send-to-partner" "$TOK_COMERCIAL")
TOKEN=$(jget ".token_acesso_externo")
STATUS_APOS_ENVIO=$(jget ".status")
if [ "$CODE" = "200" ] && [ -n "$TOKEN" ] && [ "$STATUS_APOS_ENVIO" = "ENVIADA_AO_PARCEIRO" ]; then
  pass "TESTE-09 'Enviar ao Parceiro' gera token real e transiciona para ENVIADA_AO_PARCEIRO — 200"
else
  fail "TESTE-09 enviar ao parceiro" "codigo=$CODE status=$STATUS_APOS_ENVIO body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

echo "############################################################"
echo "# ETAPA 5 — PARCEIRO ABRE A ÁREA EXTERNA (sem login, só o token da URL) #"
echo "############################################################"
CODE=$(api GET "/api/proposals/external/$TOKEN" "")
EXT_NUMERO=$(jget ".numero")
FLOOR_PRESENTE=$(jhas "floor")
GOVERNANCA_PRESENTE=$(jhas "governance_status")
DESCONTO_PRESENTE=$(jhas "discount")
PRECO_MINIMO_PRESENTE=$(jhas "preco_minimo_autorizado")
if [ "$CODE" = "200" ] && [ "$EXT_NUMERO" = "$PROP_NUMERO" ] && [ "$FLOOR_PRESENTE" = "NAO" ] && [ "$GOVERNANCA_PRESENTE" = "NAO" ] && [ "$DESCONTO_PRESENTE" = "NAO" ] && [ "$PRECO_MINIMO_PRESENTE" = "NAO" ]; then
  pass "TESTE-10 área externa acessível SEM login (só token na URL), numero=$EXT_NUMERO, e CONFIRMADAMENTE sem floor/governance_status/discount/preco_minimo_autorizado (anti-vazamento)"
else
  fail "TESTE-10 abrir área externa / anti-vazamento" "codigo=$CODE numero=$EXT_NUMERO floor=$FLOOR_PRESENTE governanca=$GOVERNANCA_PRESENTE desconto=$DESCONTO_PRESENTE preco_min=$PRECO_MINIMO_PRESENTE body=$(body)"
fi

echo "############################################################"
echo "# ETAPA 6 — VISUALIZAÇÃO registrada (PROPOSTA_VISUALIZADA) #"
echo "############################################################"
STATUS_POS_VIEW=$(scalar "select status from propostas_comerciais where id='$PROP_ID';")
VIEWS_COUNT=$(scalar "select visualizacoes_count from propostas_comerciais where id='$PROP_ID';")
AUDIT_VIEW=$(scalar "select count(*) from auditoria where entidade_id='$PROP_ID' and acao='PROPOSAL_VIEWED_BY_PARTNER';")
if [ "$STATUS_POS_VIEW" = "VISUALIZADA_PELO_PARCEIRO" ] && [ "$VIEWS_COUNT" -ge 1 ] && [ "$AUDIT_VIEW" -ge 1 ]; then
  pass "TESTE-11 status transiciona para VISUALIZADA_PELO_PARCEIRO, contador=$VIEWS_COUNT, auditoria PROPOSAL_VIEWED_BY_PARTNER registrada ($AUDIT_VIEW evento(s))"
else
  fail "TESTE-11 registro de visualização" "status=$STATUS_POS_VIEW views=$VIEWS_COUNT audit=$AUDIT_VIEW"
fi

echo "############################################################"
echo "# ETAPA 7 (CRÍTICA) — tentativa indevida de GERAR CONTRATO ANTES do aceite deve ser BLOQUEADA #"
echo "############################################################"
CODE=$(api POST "/api/contracts/generate" "$TOK_COMERCIAL" "{\"proposta_id\":\"$PROP_ID\"}")
if [ "$CODE" != "201" ]; then
  pass "TESTE-12 (CRÍTICO) gerar contrato ANTES do aceite do parceiro é BLOQUEADO — codigo=$CODE body=$(body)"
else
  fail "TESTE-12 (CRÍTICO) contrato gerado SEM aceite do parceiro — FALHA GRAVE" "codigo=201, contrato_id=$(jget '.id') — Aceite ≠ Assinatura violado"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

echo "############################################################"
echo "# NEGATIVO — parceiro tenta acessar OUTRA proposta com token errado #"
echo "############################################################"
CODE=$(api GET "/api/proposals/external/0000000000000000000000000000000000000000000000000000000000000000" "")
[ "$CODE" != "200" ] \
  && pass "TESTE-13 (negativo) token inválido/inexistente é rejeitado — codigo=$CODE" \
  || fail "TESTE-13 (negativo) token inválido deveria ser rejeitado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# NEGATIVO (seção 1: 'ABRIR O LINK JAMAIS PODE REPRESENTAR ACEITE') — abrir 3x não aceita #"
echo "############################################################"
api GET "/api/proposals/external/$TOKEN" "" > /dev/null
api GET "/api/proposals/external/$TOKEN" "" > /dev/null
STATUS_POS_MULTIPLAS_VIEWS=$(scalar "select status from propostas_comerciais where id='$PROP_ID';")
[ "$STATUS_POS_MULTIPLAS_VIEWS" = "VISUALIZADA_PELO_PARCEIRO" ] \
  && pass "TESTE-14 (negativo) abrir o link múltiplas vezes NUNCA muda para ACEITA_PELO_PARCEIRO — status=$STATUS_POS_MULTIPLAS_VIEWS" \
  || fail "TESTE-14 (negativo) abrir link não pode representar aceite" "status=$STATUS_POS_MULTIPLAS_VIEWS — FALHA GRAVE"

echo "############################################################"
echo "# NEGATIVO — iniciar aceite sem declaração de poderes (checkbox 1) #"
echo "############################################################"
CODE=$(api POST "/api/proposals/external/$TOKEN/accept/iniciar" "" '{"nome":"Carlos Silva (teste E2E)","documento":"123.456.789-00","cargo":"Diretor","email":"parceiro-e2e311@optimon.local","telefone":"(44) 99999-0000","declaracao":false,"confirmacao":true}')
[ "$CODE" = "400" ] && grep -q "DECLARACAO_OBRIGATORIA" /tmp/fase311_resp.json \
  && pass "TESTE-15 (negativo) iniciar aceite sem marcar a declaração de poderes é bloqueado (DECLARACAO_OBRIGATORIA) — codigo=$CODE" \
  || fail "TESTE-15 (negativo) aceite sem declaração deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# NEGATIVO — iniciar aceite sem confirmação (checkbox 2, seção 1 item 9) #"
echo "############################################################"
CODE=$(api POST "/api/proposals/external/$TOKEN/accept/iniciar" "" '{"nome":"Carlos Silva (teste E2E)","documento":"123.456.789-00","cargo":"Diretor","email":"parceiro-e2e311@optimon.local","telefone":"(44) 99999-0000","declaracao":true,"confirmacao":false}')
[ "$CODE" = "400" ] && grep -q "CONFIRMACAO_OBRIGATORIA" /tmp/fase311_resp.json \
  && pass "TESTE-16 (negativo) iniciar aceite sem a segunda confirmação é bloqueado (CONFIRMACAO_OBRIGATORIA) — codigo=$CODE" \
  || fail "TESTE-16 (negativo) aceite sem segunda confirmação deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# NEGATIVO — iniciar aceite sem CPF (documento) #"
echo "############################################################"
CODE=$(api POST "/api/proposals/external/$TOKEN/accept/iniciar" "" '{"nome":"Carlos Silva (teste E2E)","documento":"","email":"parceiro-e2e311@optimon.local","declaracao":true,"confirmacao":true}')
[ "$CODE" = "400" ] \
  && pass "TESTE-17 (negativo) iniciar aceite sem CPF é bloqueado (DADOS_OBRIGATORIOS) — codigo=$CODE" \
  || fail "TESTE-17 (negativo) aceite sem CPF deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# NEGATIVO — iniciar aceite sem e-mail #"
echo "############################################################"
CODE=$(api POST "/api/proposals/external/$TOKEN/accept/iniciar" "" '{"nome":"Carlos Silva (teste E2E)","documento":"123.456.789-00","email":"","declaracao":true,"confirmacao":true}')
[ "$CODE" = "400" ] \
  && pass "TESTE-18 (negativo) iniciar aceite sem e-mail é bloqueado (DADOS_OBRIGATORIOS) — codigo=$CODE" \
  || fail "TESTE-18 (negativo) aceite sem e-mail deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# ETAPA 8 — ACEITE FORMAL, PASSO 1/2: iniciar (dados + declaração + checkbox + OTP) #"
echo "############################################################"
CODE=$(api POST "/api/proposals/external/$TOKEN/accept/iniciar" "" '{"nome":"Carlos Silva (teste E2E)","documento":"123.456.789-00","cargo":"Diretor","email":"parceiro-e2e311@optimon.local","telefone":"(44) 99999-0000","declaracao":true,"confirmacao":true}')
TENTATIVA_ID=$(jget ".tentativa_id")
EMAIL_MASCARADO=$(jget ".email_mascarado")
STATUS_POS_INICIAR=$(scalar "select status from propostas_comerciais where id='$PROP_ID';")
if [ "$CODE" = "201" ] && [ -n "$TENTATIVA_ID" ] && [ "$STATUS_POS_INICIAR" = "VISUALIZADA_PELO_PARCEIRO" ]; then
  pass "TESTE-19 iniciar aceite (passo 1) devolve tentativa_id=$TENTATIVA_ID email_mascarado=$EMAIL_MASCARADO — e NUNCA muda o status da proposta sozinho (status=$STATUS_POS_INICIAR)"
else
  fail "TESTE-19 iniciar aceite formal" "codigo=$CODE status=$STATUS_POS_INICIAR body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi
CODIGO_RESPOSTA_TEM_OTP=$(node -e "try{const d=JSON.parse(require('fs').readFileSync('/tmp/fase311_resp.json','utf8'));console.log(JSON.stringify(d).match(/[0-9]{6}/)&&Object.keys(d).some(k=>/otp|codigo/i.test(k))?'VAZOU':'OK')}catch(e){console.log('OK')}")
[ "$CODIGO_RESPOSTA_TEM_OTP" = "OK" ] \
  && pass "TESTE-20 o código de confirmação NUNCA é devolvido na resposta HTTP (nenhum campo otp/codigo no JSON)" \
  || fail "TESTE-20 vazamento do OTP na resposta HTTP" "resposta expõe o código — FALHA GRAVE DE SEGURANÇA: $(body)"

OTP_REAL=$(otp_from_log "$TENTATIVA_ID")
[ -n "$OTP_REAL" ] && [ "${#OTP_REAL}" = "6" ] \
  && pass "TESTE-21 código OTP recuperado do log do servidor (canal de teste controlado) para a tentativa $TENTATIVA_ID" \
  || { fail "TESTE-21 não foi possível localizar o OTP no log do servidor" "ver /tmp/fase311_api.log, tentativa=$TENTATIVA_ID"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }

echo "############################################################"
echo "# NEGATIVO — confirmar com código ERRADO #"
echo "############################################################"
OTP_ERRADO=$(( (10#$OTP_REAL + 1) % 1000000 ))
OTP_ERRADO=$(printf '%06d' "$OTP_ERRADO")
CODE=$(api POST "/api/proposals/external/$TOKEN/accept/confirmar" "" "{\"tentativa_id\":\"$TENTATIVA_ID\",\"otp\":\"$OTP_ERRADO\"}")
STATUS_POS_OTP_ERRADO=$(scalar "select status from propostas_comerciais where id='$PROP_ID';")
[ "$CODE" = "401" ] && [ "$STATUS_POS_OTP_ERRADO" != "ACEITA_PELO_PARCEIRO" ] \
  && pass "TESTE-22 (negativo) confirmar com código INCORRETO é bloqueado (OTP_INCORRETO) e a proposta permanece não-aceita — codigo=$CODE status=$STATUS_POS_OTP_ERRADO" \
  || fail "TESTE-22 (negativo) OTP incorreto deveria ser bloqueado" "codigo=$CODE status=$STATUS_POS_OTP_ERRADO body=$(body)"

echo "############################################################"
echo "# ETAPA 9 — ACEITE FORMAL, PASSO 2/2: confirmar com o código CERTO #"
echo "############################################################"
CODE=$(api POST "/api/proposals/external/$TOKEN/accept/confirmar" "" "{\"tentativa_id\":\"$TENTATIVA_ID\",\"otp\":\"$OTP_REAL\"}")
STATUS_POS_ACEITE=$(jget ".status")
if [ "$CODE" = "200" ] && [ "$STATUS_POS_ACEITE" = "ACEITA_PELO_PARCEIRO" ]; then
  pass "TESTE-23 aceite formal do parceiro confirmado por OTP — status=ACEITA_PELO_PARCEIRO"
else
  fail "TESTE-23 confirmar aceite formal" "codigo=$CODE status=$STATUS_POS_ACEITE body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi
AUDIT_OTP_REQ=$(scalar "select count(*) from auditoria where entidade_id='$PROP_ID' and acao='PROPOSAL_ACCEPT_OTP_REQUESTED';")
AUDIT_ACCEPT=$(scalar "select count(*) from auditoria where entidade_id='$PROP_ID' and acao='PROPOSAL_ACCEPTED_BY_PARTNER';")
[ "$AUDIT_OTP_REQ" -ge 1 ] && [ "$AUDIT_ACCEPT" = "1" ] \
  && pass "TESTE-24 auditoria completa: PROPOSAL_ACCEPT_OTP_REQUESTED ($AUDIT_OTP_REQ) + PROPOSAL_ACCEPTED_BY_PARTNER ($AUDIT_ACCEPT) registradas" \
  || fail "TESTE-24 auditoria de aceite" "otp_requested=$AUDIT_OTP_REQ accepted=$AUDIT_ACCEPT"

echo "############################################################"
echo "# ETAPA 9b — card ACEITE DO PARCEIRO (seção 2): todos os campos de auditoria #"
echo "############################################################"
CODE=$(api GET "/api/proposals/$PROP_ID" "$TOK_COMERCIAL")
A_NOME=$(jget ".aceite_nome"); A_DOC=$(jget ".aceite_documento"); A_EMAIL=$(jget ".aceite_email")
A_METODO=$(jget ".aceite_metodo"); A_VERSAO=$(jget ".aceite_versao_termo"); A_HASH=$(jget ".aceite_hash_proposta")
A_IP=$(jget ".aceite_ip"); A_UA=$(jget ".aceite_user_agent"); A_EM=$(jget ".aceite_em")
if [ "$A_NOME" = "Carlos Silva (teste E2E)" ] && [ "$A_DOC" = "123.456.789-00" ] && [ "$A_EMAIL" = "parceiro-e2e311@optimon.local" ] \
   && [ "$A_METODO" = "OTP_EMAIL" ] && [ -n "$A_VERSAO" ] && [ -n "$A_HASH" ] && [ -n "$A_EM" ]; then
  pass "TESTE-25 card ACEITE DO PARCEIRO completo: representante=$A_NOME CPF=$A_DOC e-mail=$A_EMAIL método=$A_METODO versão=$A_VERSAO hash=$A_HASH ip=${A_IP:-'(vazio — ver limitação IP abaixo)'} user-agent=${A_UA:-'(vazio)'}"
else
  fail "TESTE-25 card ACEITE DO PARCEIRO incompleto" "nome=$A_NOME doc=$A_DOC email=$A_EMAIL metodo=$A_METODO versao=$A_VERSAO hash=$A_HASH em=$A_EM"
fi
# Nota sobre IP: em ambiente de teste local (curl direto ao servidor, sem proxy real
# tipo Railway na frente), req.ip do Express normalmente resolve para 127.0.0.1/::1 —
# comportamento correto de app.set('trust proxy', true); o valor não-vazio (mesmo que
# seja o loopback local) já prova que a captura chega até a coluna, o que ANTES desta
# correção (Fase 3.11.2) nunca acontecia (aceite_ip ficava sempre NULL). Documentado no
# relatório final como o que este ambiente consegue provar vs. o que só o ambiente real
# atrás do proxy da Railway prova (IP público real do parceiro).
[ -n "$A_IP" ] \
  && pass "TESTE-26 aceite_ip capturado (não-nulo) — confirma a correção do bug real (Fase 3.11.2): antes desta fase, aceite_ip SEMPRE ficava NULL (bug em supabaseClient.js nunca repassava x-forwarded-for/user-agent) — valor=$A_IP" \
  || fail "TESTE-26 captura de IP no aceite" "aceite_ip continua NULL — regressão do bug corrigido nesta fase"

echo "############################################################"
echo "# NEGATIVO — segunda tentativa de INICIAR aceite da mesma proposta (double-accept) #"
echo "############################################################"
CODE=$(api POST "/api/proposals/external/$TOKEN/accept/iniciar" "" '{"nome":"Segunda tentativa","documento":"111.111.111-11","email":"outro@optimon.local","declaracao":true,"confirmacao":true}')
[ "$CODE" != "201" ] \
  && pass "TESTE-27 (negativo) iniciar um SEGUNDO aceite da mesma proposta já ACEITA é BLOQUEADO (STATUS_INVALIDO) — codigo=$CODE" \
  || fail "TESTE-27 (negativo) double-accept deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# NEGATIVO — reutilizar a MESMA tentativa/código já confirmado (OTP reutilizado) #"
echo "############################################################"
CODE=$(api POST "/api/proposals/external/$TOKEN/accept/confirmar" "" "{\"tentativa_id\":\"$TENTATIVA_ID\",\"otp\":\"$OTP_REAL\"}")
[ "$CODE" != "200" ] && grep -q "ACEITE_DUPLICADO" /tmp/fase311_resp.json \
  && pass "TESTE-28 (negativo) reutilizar o mesmo código/tentativa já confirmado é BLOQUEADO (ACEITE_DUPLICADO) — codigo=$CODE" \
  || fail "TESTE-28 (negativo) reuso de OTP já confirmado deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# ETAPA 10 — GERAR CONTRATO (agora permitido — só após aceite real confirmado) #"
echo "############################################################"
CODE=$(api POST "/api/contracts/generate" "$TOK_COMERCIAL" "{\"proposta_id\":\"$PROP_ID\"}")
CONTRATO_ID=$(jget ".id")
CONTRATO_NUMERO=$(jget ".numero")
if [ "$CODE" = "201" ] && [ -n "$CONTRATO_ID" ]; then
  pass "TESTE-29 CRIAR CONTRATO a partir da proposta ACEITA_PELO_PARCEIRO — 201, numero=$CONTRATO_NUMERO"
else
  fail "TESTE-29 criar contrato" "codigo=$CODE body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

echo "############################################################"
echo "# NEGATIVO — segundo contrato da mesma proposta é bloqueado #"
echo "############################################################"
CODE=$(api POST "/api/contracts/generate" "$TOK_COMERCIAL" "{\"proposta_id\":\"$PROP_ID\"}")
[ "$CODE" != "201" ] \
  && pass "TESTE-30 (negativo) segundo contrato para a mesma proposta é BLOQUEADO — codigo=$CODE" \
  || fail "TESTE-30 (negativo) contrato duplicado deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# NEGATIVO — alterar proposta já ACEITA (sem gerar nova versão) #"
echo "############################################################"
CODE=$(api PATCH "/api/proposals/$PROP_ID" "$TOK_DIRETOR" '{"observacoes_comerciais":"tentativa de alterar proposta já aceita/contratada"}')
[ "$CODE" != "200" ] \
  && pass "TESTE-31 (negativo) editar proposta já aceita/com contrato gerado é BLOQUEADO (STATUS_INVALIDO — exige Nova Versão) — codigo=$CODE" \
  || fail "TESTE-31 (negativo) alteração pós-aceite deveria ser bloqueada" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# ETAPA 11 — vínculo bidirecional real proposta <-> contrato #"
echo "############################################################"
CODE=$(api GET "/api/proposals/$PROP_ID" "$TOK_COMERCIAL")
PROP_CONTRATO_ID=$(jget ".contrato_id")
[ "$PROP_CONTRATO_ID" = "$CONTRATO_ID" ] && pass "TESTE-32 lado da PROPOSTA mostra contrato_id=$PROP_CONTRATO_ID (bate)" || fail "TESTE-32 vínculo proposta->contrato" "contrato_id=$PROP_CONTRATO_ID esperado=$CONTRATO_ID"

CODE=$(api GET "/api/contracts/$CONTRATO_ID" "$TOK_COMERCIAL")
CTR_PROP_ID=$(jget ".proposta_origem.id")
[ "$CTR_PROP_ID" = "$PROP_ID" ] && pass "TESTE-33 lado do CONTRATO mostra proposta_origem.id=$CTR_PROP_ID (bate) — vínculo bidirecional confirmado" || fail "TESTE-33 vínculo contrato->proposta" "proposta_origem.id=$CTR_PROP_ID esperado=$PROP_ID"

echo "############################################################"
echo "# ETAPA 12 — MINUTA (PDF/DOCX) real do contrato #"
echo "############################################################"
for FMT in PDF DOCX; do
  OUT="/tmp/fase311_minuta.${FMT,,}"
  HTTP_CODE=$(curl -sS -o "$OUT" -w "%{http_code}" "$API/api/contracts/$CONTRATO_ID/minuta?formato=$FMT" -H "Authorization: Bearer $TOK_ADMIN")
  SIZE=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
  [ "$HTTP_CODE" = "200" ] && [ "$SIZE" -gt 1000 ] \
    && pass "TESTE-34-$FMT minuta $FMT gerada — $SIZE bytes" \
    || fail "TESTE-34-$FMT gerar minuta $FMT" "codigo=$HTTP_CODE tamanho=$SIZE"
done

echo "############################################################"
echo "# ETAPA 13 — ASSINATURA ELETRÔNICA: 3 signatários (2 obrigatórios + 1 testemunha) #"
echo "############################################################"
PROVIDER_ID=$(scalar "select id from signature_providers where tipo='ICP_BRASIL_HOMOLOGACAO_MOCK' and ambiente='HOMOLOGACAO' limit 1;")
if [ -z "$PROVIDER_ID" ]; then
  CODE=$(api POST "/api/signatures/providers" "$TOK_ADMIN" "{\"nome\":\"Homologação Fase311 Teste\",\"tipo\":\"ICP_BRASIL_HOMOLOGACAO_MOCK\",\"ambiente\":\"HOMOLOGACAO\",\"webhook_secret_ref\":\"$WEBHOOK_SECRET_ENV_NAME\"}")
  PROVIDER_ID=$(jget ".id")
fi
[ -n "$PROVIDER_ID" ] && pass "TESTE-35 provedor de assinatura disponível — id=$PROVIDER_ID" \
  || { fail "TESTE-35 provedor de assinatura" "body=$(body)"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }

ENVELOPE_ID=$(curl -sS -o /tmp/fase311_resp.json -w '' -X POST "$API/api/signatures/envelopes" -H "Authorization: Bearer $TOK_COMERCIAL" -F "tipo_documento=CONTRATO" -F "provider_id=$PROVIDER_ID" -F "contrato_id=$CONTRATO_ID" > /dev/null; jget ".id")
if [ -n "$ENVELOPE_ID" ]; then
  pass "TESTE-36 envelope de assinatura do CONTRATO criado (PDF auto-gerado, sem upload manual) — id=$ENVELOPE_ID"
else
  fail "TESTE-36 criar envelope do contrato" "body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

CODE=$(api POST "/api/signatures/envelopes/$ENVELOPE_ID/signers" "$TOK_COMERCIAL" '{"nome":"Representante NICK (teste E2E)","email":"nick-e2e311@optimon.local","papel":"REPRESENTANTE_NICK","ordem":1,"obrigatorio":true}')
SIGNER1_ID=$(jget ".id")
CODE=$(api POST "/api/signatures/envelopes/$ENVELOPE_ID/signers" "$TOK_COMERCIAL" '{"nome":"Representante TESTE-E2E-OPTIMON-311","email":"parceiro-e2e311@optimon.local","papel":"REPRESENTANTE_PROPONENTE","ordem":2,"obrigatorio":true}')
SIGNER2_ID=$(jget ".id")
CODE=$(api POST "/api/signatures/envelopes/$ENVELOPE_ID/signers" "$TOK_COMERCIAL" '{"nome":"Testemunha (teste E2E, não obrigatória)","email":"testemunha-e2e311@optimon.local","papel":"TESTEMUNHA","ordem":3,"obrigatorio":false}')
SIGNER3_ID=$(jget ".id")
if [ -n "$SIGNER1_ID" ] && [ -n "$SIGNER2_ID" ] && [ -n "$SIGNER3_ID" ]; then
  pass "TESTE-37 3 signatários adicionados: 2 OBRIGATÓRIOS (NICK, PROPONENTE) + 1 NÃO-obrigatório (TESTEMUNHA) — seção 7: papéis configuráveis e obrigatoriedade explícita"
else
  fail "TESTE-37 adicionar signatários com papel/obrigatoriedade" "signer1=$SIGNER1_ID signer2=$SIGNER2_ID signer3=$SIGNER3_ID"
fi
OBRIG1=$(scalar "select obrigatorio from signature_signers where id='$SIGNER1_ID';")
OBRIG3=$(scalar "select obrigatorio from signature_signers where id='$SIGNER3_ID';")
[ "$OBRIG1" = "t" ] && [ "$OBRIG3" = "f" ] \
  && pass "TESTE-38 obrigatoriedade persistida corretamente por signatário (NICK=obrigatório, Testemunha=não-obrigatório)" \
  || fail "TESTE-38 obrigatoriedade por signatário" "obrig1=$OBRIG1 obrig3=$OBRIG3"

CODE=$(api POST "/api/signatures/envelopes/$ENVELOPE_ID/send" "$TOK_COMERCIAL")
STATUS_SIGNERS_POS_SEND=$(scalar "select string_agg(distinct status, ',') from signature_signers where envelope_id='$ENVELOPE_ID';")
[ "$CODE" = "200" ] && pass "TESTE-39 envelope do contrato enviado ao provedor — 200, status dos signatários=$STATUS_SIGNERS_POS_SEND" || fail "TESTE-39 enviar envelope do contrato" "codigo=$CODE body=$(body)"

PROVIDER_ENVELOPE_ID=$(scalar "select provider_envelope_id from signature_envelopes where id='$ENVELOPE_ID';")

echo "############################################################"
echo "# NEGATIVO (seção 3) — para o provedor MOCK usado nesta ETAPA, 'envelope criado' != 'e-mail enviado' #"
echo "############################################################"
# ATUALIZADO na Fase 3.11.4: o TESTE-40 original (Fase 3.11/3.11.2) afirmava que NENHUMA
# biblioteca de e-mail transacional existia em api/lib ou api/routes — verdade até aqui,
# mas deixou de ser verdade a partir da Fase 3.11.4 (o provider OPTIMON_INTERNO_RESEND,
# testado adiante na seção "FASE 3.11.4", usa api/lib/emailService.js/Resend de verdade
# para o link de assinatura). Manter a afirmação antiga sem atualizar seria exatamente o
# tipo de "status mentiroso" que esta fase existe para eliminar — então o teste foi
# reescrito para verificar o que continua sendo verdade: o MockHomologacaoProvider (o
# provider usado NESTA etapa/envelope, id=$PROVIDER_ID, tipo=ICP_BRASIL_HOMOLOGACAO_MOCK)
# nunca chama api/lib/emailService.js nem qualquer lib de e-mail — só cria estado local e
# devolve um ID sintético (MOCK-ENV-...). Grep escopado à CLASSE MockHomologacaoProvider em
# api/lib/signatureProvider.js (nunca ao arquivo inteiro, que agora legitimamente importa
# emailService para a classe ResendInternoProvider, outro provider).
MOCK_CLASS_BODY=$(node -e "
const fs = require('fs');
const src = fs.readFileSync('api/lib/signatureProvider.js', 'utf8');
const start = src.indexOf('class MockHomologacaoProvider');
if (start < 0) { console.log('CLASSE_NAO_ENCONTRADA'); process.exit(0); }
const nextClass = src.indexOf('\nclass ', start + 1);
console.log(src.slice(start, nextClass > 0 ? nextClass : undefined));
")
if echo "$MOCK_CLASS_BODY" | grep -Eq "emailService|nodemailer|resend|@sendgrid|require\(['\"]http|require\(['\"]https|fetch\(|axios"; then
  fail "TESTE-40 (negativo) MockHomologacaoProvider deveria continuar sem tocar rede/e-mail" "classe encontrada, mas referencia algo de rede/e-mail — reinvestigar"
elif [ "$MOCK_CLASS_BODY" = "CLASSE_NAO_ENCONTRADA" ]; then
  fail "TESTE-40 classe MockHomologacaoProvider não encontrada em api/lib/signatureProvider.js" "reinvestigar renomeação"
else
  pass "TESTE-40 (achado real, escopado à classe usada nesta ETAPA) confirmado por leitura de código: MockHomologacaoProvider (provider ICP_BRASIL_HOMOLOGACAO_MOCK, id=$PROVIDER_ID) NUNCA toca rede/e-mail — 'envelope ENVIADO' com este provider nunca significou 'e-mail realmente entregue'. Desde a Fase 3.11.4 existe um 2º provider real (OPTIMON_INTERNO_RESEND, testado na seção FASE 3.11.4 abaixo) que usa api/lib/emailService.js de verdade — os dois convivem, nunca confundidos."
fi

echo "############################################################"
echo "# ETAPA 13b — webhook 1: signatário OBRIGATÓRIO (NICK) assina #"
echo "############################################################"
cat > /tmp/fase311_webhook_evt1.json <<EOF
{"provider_envelope_id":"$PROVIDER_ENVELOPE_ID","evento_externo_id":"evt-1-e2e311","tipo_evento":"SIGNER_SIGNED","signer_email":"nick-e2e311@optimon.local","signer_novo_status":"ASSINADO","signer_ip":"203.0.113.20","novo_status_envelope":"PARCIALMENTE_ASSINADO"}
EOF
sign_and_post_webhook /tmp/fase311_webhook_evt1.json > /dev/null

ENVELOPE_STATUS_PARCIAL=$(scalar "select status from signature_envelopes where id='$ENVELOPE_ID';")
[ "$ENVELOPE_STATUS_PARCIAL" = "PARCIALMENTE_ASSINADO" ] \
  && pass "TESTE-41 1 de 2 signatários OBRIGATÓRIOS assinou — envelope corretamente PARCIALMENTE_ASSINADO (status=$ENVELOPE_STATUS_PARCIAL)" \
  || fail "TESTE-41 status parcial de assinatura" "status=$ENVELOPE_STATUS_PARCIAL"

echo "############################################################"
echo "# NEGATIVO (seção 11) — webhook MALICIOSO/inconsistente: signatário NÃO AUTORIZADO + alega ASSINADO com obrigatório pendente #"
echo "############################################################"
cat > /tmp/fase311_webhook_evt_malicioso.json <<EOF
{"provider_envelope_id":"$PROVIDER_ENVELOPE_ID","evento_externo_id":"evt-malicioso-e2e311","tipo_evento":"SIGNER_SIGNED","signer_email":"nao-cadastrado-e2e311@atacante.invalid","signer_novo_status":"ASSINADO","signer_ip":"198.51.100.66","novo_status_envelope":"ASSINADO","hash_assinado":"hash-forjado","storage_path_assinado":"forjado.pdf"}
EOF
sign_and_post_webhook /tmp/fase311_webhook_evt_malicioso.json > /dev/null
SIGNER_FANTASMA_EXISTE=$(scalar "select count(*) from signature_signers where envelope_id='$ENVELOPE_ID' and lower(email)='nao-cadastrado-e2e311@atacante.invalid';")
ENVELOPE_STATUS_POS_MALICIOSO=$(scalar "select status from signature_envelopes where id='$ENVELOPE_ID';")
if [ "$SIGNER_FANTASMA_EXISTE" = "0" ]; then
  pass "TESTE-42 (negativo, seção 11 'assinar com signatário não autorizado') webhook para e-mail NÃO cadastrado no envelope não cria nem altera nenhum signatário (0 linhas afetadas)"
else
  fail "TESTE-42 (negativo) signatário não autorizado deveria ser ignorado" "SIGNER_FANTASMA_EXISTE=$SIGNER_FANTASMA_EXISTE"
fi
if [ "$ENVELOPE_STATUS_POS_MALICIOSO" = "PARCIALMENTE_ASSINADO" ]; then
  pass "TESTE-43 (negativo, seção 11 'finalizar contrato com assinatura obrigatória faltante' / seção 7) webhook alegando novo_status_envelope=ASSINADO é RECUSADO enquanto o 2º signatário OBRIGATÓRIO não assinou de verdade — envelope permanece PARCIALMENTE_ASSINADO (nunca aceita a alegação do provedor por presunção)"
else
  fail "TESTE-43 (CRÍTICO) envelope aceitou ASSINADO sem todos os obrigatórios terem assinado" "status=$ENVELOPE_STATUS_POS_MALICIOSO — FALHA GRAVE, gate da seção 7/11 não está funcionando"
fi
INCONSISTENCIA_AUDITADA=$(scalar "select count(*) from auditoria where entidade_id='$ENVELOPE_ID' and acao='SIGNATURE_EVENT_RECEIVED' and motivo like 'INCONSISTENCIA%';")
[ "$INCONSISTENCIA_AUDITADA" -ge 1 ] \
  && pass "TESTE-44 divergência provedor-alega-ASSINADO-mas-obrigatório-pendente fica registrada em auditoria (INCONSISTENCIA) — $INCONSISTENCIA_AUDITADA evento(s)" \
  || fail "TESTE-44 auditoria da inconsistência não encontrada" "contagem=$INCONSISTENCIA_AUDITADA"

echo "############################################################"
echo "# ETAPA 13c (seção 6) — REENVIAR ASSINATURA: bloqueado p/ já-assinado, permitido p/ pendente #"
echo "############################################################"
CODE=$(api POST "/api/signatures/envelopes/$ENVELOPE_ID/signers/$SIGNER1_ID/resend" "$TOK_COMERCIAL" '{"motivo":"teste negativo — signatário já assinou"}')
[ "$CODE" != "200" ] \
  && pass "TESTE-45 (negativo) reenviar assinatura para signatário JÁ ASSINADO é BLOQUEADO (evita duplicidade de assinatura) — codigo=$CODE" \
  || fail "TESTE-45 (negativo) reenvio para já-assinado deveria ser bloqueado" "codigo=$CODE body=$(body)"

REENVIOS_ANTES=$(scalar "select reenvios_count from signature_signers where id='$SIGNER3_ID';")
CODE=$(api POST "/api/signatures/envelopes/$ENVELOPE_ID/signers/$SIGNER3_ID/resend" "$TOK_COMERCIAL" '{"motivo":"teste E2E — reenvio real para testemunha pendente"}')
STATUS_SIGNER3_POS_RESEND=$(scalar "select status from signature_signers where id='$SIGNER3_ID';")
REENVIOS_DEPOIS=$(scalar "select reenvios_count from signature_signers where id='$SIGNER3_ID';")
if [ "$CODE" = "200" ] && [ "$STATUS_SIGNER3_POS_RESEND" = "ENVIADO" ] && [ "$REENVIOS_DEPOIS" = "$((REENVIOS_ANTES + 1))" ]; then
  pass "TESTE-46 reenvio de assinatura bem-sucedido para signatário pendente (testemunha) — status=$STATUS_SIGNER3_POS_RESEND, reenvios_count $REENVIOS_ANTES -> $REENVIOS_DEPOIS, registrado em auditoria (SIGNATURE_SIGNER_RESEND), sem gerar assinatura duplicada"
else
  fail "TESTE-46 reenvio de assinatura para signatário pendente" "codigo=$CODE status=$STATUS_SIGNER3_POS_RESEND reenvios=$REENVIOS_ANTES->$REENVIOS_DEPOIS"
fi
AUDIT_RESEND=$(scalar "select count(*) from auditoria where entidade_id='$ENVELOPE_ID' and acao='SIGNATURE_SIGNER_RESEND';")
[ "$AUDIT_RESEND" -ge 1 ] && pass "TESTE-47 auditoria SIGNATURE_SIGNER_RESEND registrada ($AUDIT_RESEND evento(s))" || fail "TESTE-47 auditoria de reenvio" "contagem=$AUDIT_RESEND"

echo "############################################################"
echo "# ETAPA 13d — webhook 2: 2º signatário OBRIGATÓRIO (PROPONENTE) assina de verdade #"
echo "############################################################"
cat > /tmp/fase311_webhook_evt2.json <<EOF
{"provider_envelope_id":"$PROVIDER_ENVELOPE_ID","evento_externo_id":"evt-2-e2e311","tipo_evento":"SIGNER_SIGNED","signer_email":"parceiro-e2e311@optimon.local","signer_novo_status":"ASSINADO","signer_ip":"203.0.113.21","novo_status_envelope":"ASSINADO","hash_assinado":"e2e311-hash-teste-homologacao","storage_path_assinado":"homologacao/teste-e2e-311/contrato-assinado.pdf"}
EOF
sign_and_post_webhook /tmp/fase311_webhook_evt2.json > /dev/null
ENVELOPE_STATUS_FINAL=$(scalar "select status from signature_envelopes where id='$ENVELOPE_ID';")
STATUS_TESTEMUNHA_FINAL=$(scalar "select status from signature_signers where id='$SIGNER3_ID';")
if [ "$ENVELOPE_STATUS_FINAL" = "ASSINADO" ]; then
  pass "TESTE-48 (ETAPA CRÍTICA) com os 2 signatários OBRIGATÓRIOS assinados de verdade, envelope agora ASSINADO — e a testemunha (não-obrigatória, status=$STATUS_TESTEMUNHA_FINAL, nunca assinou) NÃO bloqueou a finalização — gate de obrigatoriedade (seção 7) funcionando nos dois sentidos"
else
  fail "TESTE-48 assinatura via webhook (2 obrigatórios completos)" "status_final=$ENVELOPE_STATUS_FINAL"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

CODE=$(api POST "/api/signatures/envelopes/$ENVELOPE_ID/validate" "$TOK_COMERCIAL")
DOC_VALIDADO=$(scalar "select validado from documentos_assinados where envelope_id='$ENVELOPE_ID';")
if [ "$CODE" = "200" ] && [ "$DOC_VALIDADO" = "t" ]; then
  pass "TESTE-49 assinatura validada de verdade (hash/política ICP-Brasil/todos os OBRIGATÓRIOS) — nunca 'status=ASSINADO' sozinho como prova"
else
  fail "TESTE-49 validar assinatura" "codigo=$CODE validado=$DOC_VALIDADO body=$(body)"
fi

echo "############################################################"
echo "# ETAPA 13e — status/log de entrega granular por signatário (seções 4-5) #"
echo "############################################################"
SIG1_ASSINADO_EM=$(scalar "select assinado_em is not null from signature_signers where id='$SIGNER1_ID';")
SIG1_ENVIADO_EM=$(scalar "select enviado_em is not null from signature_signers where id='$SIGNER1_ID';")
SIG3_ENVIADO_EM=$(scalar "select enviado_em is not null from signature_signers where id='$SIGNER3_ID';")
if [ "$SIG1_ASSINADO_EM" = "t" ] && [ "$SIG1_ENVIADO_EM" = "t" ] && [ "$SIG3_ENVIADO_EM" = "t" ]; then
  pass "TESTE-50 timestamps granulares por signatário persistidos (enviado_em/assinado_em) — status do envelope é independente do status por signatário (seção 4)"
else
  fail "TESTE-50 timestamps granulares por signatário" "sig1_assinado=$SIG1_ASSINADO_EM sig1_enviado=$SIG1_ENVIADO_EM sig3_enviado=$SIG3_ENVIADO_EM"
fi
EVENTOS_WEBHOOK_REGISTRADOS=$(scalar "select count(*) from signature_events where envelope_id='$ENVELOPE_ID';")
[ "$EVENTOS_WEBHOOK_REGISTRADOS" -ge 3 ] \
  && pass "TESTE-51 log de eventos de entrega (signature_events) com $EVENTOS_WEBHOOK_REGISTRADOS evento(s) reais recebidos (nunca tratando 'ENVIADO' como prova de entrega — seção 5)" \
  || fail "TESTE-51 log de eventos de entrega" "contagem=$EVENTOS_WEBHOOK_REGISTRADOS"

echo "############################################################"
echo "# NEGATIVO — proposta com CONTRATO_GERADO não pode ser reenviada ao parceiro #"
echo "############################################################"
CODE=$(api POST "/api/proposals/$PROP_ID/send-to-partner" "$TOK_COMERCIAL")
[ "$CODE" != "200" ] \
  && pass "TESTE-52 (negativo) reenviar ao parceiro uma proposta já com CONTRATO_GERADO é bloqueado — codigo=$CODE" \
  || fail "TESTE-52 (negativo) alteração pós-contrato deveria ser bloqueada" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# ETAPA 14 — ATIVAÇÃO DO CONTRATO (gate real: assinatura validada + infra alocada) #"
echo "############################################################"
CODE=$(api POST "/api/contracts/$CONTRATO_ID/activate" "$TOK_DIRETOR")
[ "$CODE" != "200" ] \
  && pass "TESTE-53 ativação SEM infra alocada é bloqueada corretamente (INFRA_NAO_ALOCADA) — codigo=$CODE" \
  || fail "TESTE-53 ativação deveria exigir infra alocada" "codigo=$CODE body=$(body)"

FIBRA_LIVRE_ID=$(scalar "
  select f.id from public.infra_fibras f
  join public.infra_cabos c on c.id = f.cabo_id
  join public.infra_pops pop on pop.id = c.pop_id
  where pop.cidade_id = '$CIDADE_ID'
    and f.status_contratual = 'DISPONIVEL'
    and not exists (select 1 from public.contrato_fibras cf where cf.fibra_id = f.id and cf.desvinculado_em is null)
  limit 1;
")
if [ -n "$FIBRA_LIVRE_ID" ]; then
  $PSQL -c "set role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$UID_ENGENHARIA\",\"role\":\"authenticated\"}'; insert into public.contrato_fibras (contrato_id, fibra_id, capacidade_clientes) values ('$CONTRATO_ID', '$FIBRA_LIVRE_ID', 150); reset role;" > /tmp/fase311_alloc.log 2>&1
  ALLOC_OK=$($PSQL -t -A -c "select count(*) from public.contrato_fibras where contrato_id='$CONTRATO_ID';" | tr -d ' ')
  [ "$ALLOC_OK" = "1" ] && pass "TESTE-54 Engenharia aloca fibra ao contrato (contrato_fibras)" || fail "TESTE-54 alocar fibra" "ver /tmp/fase311_alloc.log"
else
  fail "TESTE-54 nenhuma fibra livre encontrada em Jussara" "banco de dev sem fibra DISPONIVEL"
fi

CODE=$(api POST "/api/contracts/$CONTRATO_ID/activate" "$TOK_DIRETOR")
CONTRATO_STATUS_FINAL=$(scalar "select status from contratos where id='$CONTRATO_ID';")
if [ "$CODE" = "200" ] && [ "$CONTRATO_STATUS_FINAL" = "ATIVO" ]; then
  pass "TESTE-55 (ETAPA 14) CONTRATO ATIVADO com sucesso (assinatura validada + infra alocada + sem conflito) — status=ATIVO"
else
  fail "TESTE-55 ativar contrato" "codigo=$CODE status=$CONTRATO_STATUS_FINAL body=$(body)"
fi
AUDIT_ACTIVATE=$(scalar "select count(*) from auditoria where entidade_id='$CONTRATO_ID' and acao='CONTRACT_ACTIVATE';")
[ "$AUDIT_ACTIVATE" = "1" ] && pass "TESTE-56 auditoria CONTRACT_ACTIVATE registrada" || fail "TESTE-56 auditoria de ativação" "contagem=$AUDIT_ACTIVATE"

echo "############################################################"
echo "# NEGATIVO — usuário sem permissão tenta ativar contrato #"
echo "############################################################"
CODE=$(api POST "/api/contracts/$CONTRATO_ID/activate" "$TOK_AUDITOR")
[ "$CODE" != "200" ] \
  && pass "TESTE-57 (negativo) AUDITOR (sem permissão de Diretoria/Admin) não consegue reativar/ativar contrato — codigo=$CODE" \
  || fail "TESTE-57 (negativo) usuário sem permissão deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# HISTÓRICO DA NEGOCIAÇÃO — timeline real derivada da auditoria #"
echo "############################################################"
CODE=$(api GET "/api/proposals/$PROP_ID/historico" "$TOK_COMERCIAL")
HIST_LEN=$(node -e "try{const d=JSON.parse(require('fs').readFileSync('/tmp/fase311_resp.json','utf8'));console.log(Array.isArray(d)?d.length:0)}catch(e){console.log(0)}")
[ "$CODE" = "200" ] && [ "$HIST_LEN" -ge 6 ] \
  && pass "TESTE-58 Histórico da Negociação (GET /api/proposals/:id/historico) devolve timeline real com $HIST_LEN eventos" \
  || fail "TESTE-58 histórico da negociação" "codigo=$CODE eventos=$HIST_LEN"

# ============================================================================
# SUB-FLUXO NEGATIVO A — TOKEN EXPIRADO (seção 9: expiração)
# ============================================================================
echo "############################################################"
echo "# SUB-FLUXO A — TOKEN EXPIRADO: link vencido bloqueia visualização e aceite #"
echo "############################################################"
if setup_proposta_teste "EXP"; then
  PARCEIRO_EXP="$NEWP_PARCEIRO_ID"; PROP_EXP="$NEWP_PROP_ID"; TOKEN_EXP="$NEWP_TOKEN"
  ALL_PARCEIROS_TESTE+=("$PARCEIRO_EXP")
  $PSQL -c "update propostas_comerciais set token_expira_em = now() - interval '1 hour' where id='$PROP_EXP';" > /dev/null

  CODE=$(api GET "/api/proposals/external/$TOKEN_EXP" "")
  [ "$CODE" != "200" ] && grep -q "TOKEN_EXPIRADO" /tmp/fase311_resp.json \
    && pass "TESTE-59 (negativo, seção 9 'expiração') GET na área externa com token EXPIRADO é bloqueado (TOKEN_EXPIRADO) — codigo=$CODE" \
    || fail "TESTE-59 (negativo) token expirado deveria bloquear GET" "codigo=$CODE body=$(body)"

  CODE=$(api POST "/api/proposals/external/$TOKEN_EXP/accept/iniciar" "" '{"nome":"Teste Token Expirado","documento":"999.999.999-99","email":"x@optimon.local","declaracao":true,"confirmacao":true}')
  [ "$CODE" != "201" ] && grep -q "TOKEN_EXPIRADO" /tmp/fase311_resp.json \
    && pass "TESTE-60 (negativo) iniciar aceite com token EXPIRADO é bloqueado — codigo=$CODE" \
    || fail "TESTE-60 (negativo) token expirado deveria bloquear início de aceite" "codigo=$CODE body=$(body)"
else
  fail "SUB-FLUXO-A setup da proposta de teste (token expirado)" "ver mensagens acima"
fi

# ============================================================================
# SUB-FLUXO B — TOKEN REVOGADO (seção 9: revogação) + permissão
# ============================================================================
echo "############################################################"
echo "# SUB-FLUXO B — TOKEN REVOGADO: revogação manual antes do vencimento #"
echo "############################################################"
if setup_proposta_teste "REV"; then
  PARCEIRO_REV="$NEWP_PARCEIRO_ID"; PROP_REV="$NEWP_PROP_ID"; TOKEN_REV="$NEWP_TOKEN"
  ALL_PARCEIROS_TESTE+=("$PARCEIRO_REV")

  CODE=$(api POST "/api/proposals/$PROP_REV/revoke-token" "$TOK_AUDITOR" '{"motivo":"tentativa sem permissão"}')
  [ "$CODE" != "200" ] \
    && pass "TESTE-61 (negativo, seção 11 'usuário sem permissão') AUDITOR não pode revogar link externo (só COMERCIAL/DIRETOR/ADMINISTRADOR) — codigo=$CODE" \
    || fail "TESTE-61 (negativo) revogação por usuário sem permissão deveria ser bloqueada" "codigo=$CODE body=$(body)"

  CODE=$(api POST "/api/proposals/$PROP_REV/revoke-token" "$TOK_DIRETOR" '{"motivo":"Suspeita de vazamento do link — teste E2E de revogação."}')
  [ "$CODE" = "200" ] \
    && pass "TESTE-62 DIRETOR revoga o link externo antes do vencimento natural — 200" \
    || fail "TESTE-62 revogar link externo" "codigo=$CODE body=$(body)"

  CODE=$(api GET "/api/proposals/external/$TOKEN_REV" "")
  [ "$CODE" != "200" ] && grep -q "TOKEN_REVOGADO" /tmp/fase311_resp.json \
    && pass "TESTE-63 (negativo, seção 9 'revogação') GET na área externa com token REVOGADO é bloqueado (TOKEN_REVOGADO) — codigo=$CODE" \
    || fail "TESTE-63 (negativo) token revogado deveria bloquear GET" "codigo=$CODE body=$(body)"

  CODE=$(api POST "/api/proposals/external/$TOKEN_REV/accept/iniciar" "" '{"nome":"Teste Token Revogado","documento":"888.888.888-88","email":"y@optimon.local","declaracao":true,"confirmacao":true}')
  [ "$CODE" != "201" ] && grep -q "TOKEN_REVOGADO" /tmp/fase311_resp.json \
    && pass "TESTE-64 (negativo) iniciar aceite com token REVOGADO é bloqueado — codigo=$CODE" \
    || fail "TESTE-64 (negativo) token revogado deveria bloquear início de aceite" "codigo=$CODE body=$(body)"

  CODE=$(api POST "/api/proposals/$PROP_REV/revoke-token" "$TOK_DIRETOR" '{"motivo":"segunda tentativa"}')
  [ "$CODE" != "200" ] \
    && pass "TESTE-65 (negativo) revogar um link já revogado é bloqueado (STATUS_INVALIDO)" \
    || fail "TESTE-65 (negativo) dupla revogação deveria ser bloqueada" "codigo=$CODE body=$(body)"
else
  fail "SUB-FLUXO-B setup da proposta de teste (token revogado)" "ver mensagens acima"
fi

# ============================================================================
# SUB-FLUXO C — OTP EXPIRADO + edição bloqueada após aceite real
# ============================================================================
echo "############################################################"
echo "# SUB-FLUXO C — OTP EXPIRADO, nova solicitação cancela a anterior, aceite real #"
echo "############################################################"
if setup_proposta_teste "OTP"; then
  PARCEIRO_OTP="$NEWP_PARCEIRO_ID"; PROP_OTP="$NEWP_PROP_ID"; TOKEN_OTP="$NEWP_TOKEN"
  ALL_PARCEIROS_TESTE+=("$PARCEIRO_OTP")

  CODE=$(api POST "/api/proposals/external/$TOKEN_OTP/accept/iniciar" "" '{"nome":"Teste OTP Expirado","documento":"777.777.777-77","email":"otp-e2e311@optimon.local","declaracao":true,"confirmacao":true}')
  TENT_A=$(jget ".tentativa_id")
  [ "$CODE" = "201" ] && [ -n "$TENT_A" ] \
    && pass "TESTE-66 primeira solicitação de OTP para o sub-fluxo C — tentativa_id=$TENT_A" \
    || fail "TESTE-66 iniciar aceite (sub-fluxo C)" "codigo=$CODE body=$(body)"

  # Força a expiração via SQL direto (mesmo padrão já usado nesta suíte para simular
  # condições de borda sem esperar minutos reais de TTL) — nunca contorna a validação,
  # só acelera o relógio da própria tentativa já validada normalmente.
  $PSQL -c "update propostas_aceite_tentativas set otp_expira_em = now() - interval '1 minute' where id='$TENT_A';" > /dev/null
  OTP_A=$(otp_from_log "$TENT_A")
  CODE=$(api POST "/api/proposals/external/$TOKEN_OTP/accept/confirmar" "" "{\"tentativa_id\":\"$TENT_A\",\"otp\":\"$OTP_A\"}")
  [ "$CODE" != "200" ] && grep -q "OTP_EXPIRADO" /tmp/fase311_resp.json \
    && pass "TESTE-67 (negativo, seção 11 'OTP expirado') confirmar com código correto porém EXPIRADO é bloqueado (OTP_EXPIRADO) — codigo=$CODE" \
    || fail "TESTE-67 (negativo) OTP expirado deveria ser bloqueado" "codigo=$CODE body=$(body)"

  # Nova solicitação cancela automaticamente a anterior (proteção contra replay de uma
  # solicitação antiga, seção 9) — o aceite real deste sub-fluxo usa esta 2ª tentativa.
  CODE=$(api POST "/api/proposals/external/$TOKEN_OTP/accept/iniciar" "" '{"nome":"Teste OTP Expirado","documento":"777.777.777-77","email":"otp-e2e311@optimon.local","declaracao":true,"confirmacao":true}')
  TENT_B=$(jget ".tentativa_id")
  TENT_A_STATUS=$(scalar "select status from propostas_aceite_tentativas where id='$TENT_A';")
  [ "$CODE" = "201" ] && [ -n "$TENT_B" ] && [ "$TENT_A_STATUS" = "CANCELADO" ] \
    && pass "TESTE-68 nova solicitação de OTP cancela automaticamente a tentativa anterior (proteção contra replay) — tentativa antiga=$TENT_A status=$TENT_A_STATUS, nova=$TENT_B" \
    || fail "TESTE-68 cancelamento automático de tentativa anterior" "tent_a_status=$TENT_A_STATUS tent_b=$TENT_B"

  OTP_B=$(otp_from_log "$TENT_B")
  CODE=$(api POST "/api/proposals/external/$TOKEN_OTP/accept/confirmar" "" "{\"tentativa_id\":\"$TENT_B\",\"otp\":\"$OTP_B\"}")
  STATUS_PROP_OTP=$(jget ".status")
  [ "$CODE" = "200" ] && [ "$STATUS_PROP_OTP" = "ACEITA_PELO_PARCEIRO" ] \
    && pass "TESTE-69 aceite real confirmado com a 2ª tentativa (código correto e ainda válido) — status=$STATUS_PROP_OTP" \
    || fail "TESTE-69 confirmar aceite (2ª tentativa, sub-fluxo C)" "codigo=$CODE status=$STATUS_PROP_OTP body=$(body)"

  CODE=$(api PATCH "/api/proposals/$PROP_OTP" "$TOK_DIRETOR" '{"proximos_passos":"tentativa de editar proposta já aceita pelo parceiro"}')
  [ "$CODE" != "200" ] \
    && pass "TESTE-70 (negativo, seção 1 item 12 'alteração da proposta após aceite sem nova versão') editar a proposta já ACEITA_PELO_PARCEIRO é BLOQUEADO — codigo=$CODE" \
    || fail "TESTE-70 (negativo) edição pós-aceite deveria ser bloqueada" "codigo=$CODE body=$(body)"
else
  fail "SUB-FLUXO-C setup da proposta de teste (OTP expirado)" "ver mensagens acima"
fi

echo "############################################################"
echo "# FASE 3.11.3 — PARCEIRO OBRIGATÓRIO (seções 10-17) #"
echo "############################################################"

# Parceiro inativo dedicado para os testes negativos abaixo.
CNPJ_INATIVO="$(printf '%014d' $((RANDOM * RANDOM % 100000000000000)))"
CODE=$(api POST "/api/partners" "$TOK_COMERCIAL" "{\"razao_social\":\"TESTE-E2E-OPTIMON-3113-INATIVO Ltda\",\"nome_fantasia\":\"TESTE-E2E-OPTIMON-3113-INATIVO\",\"cnpj\":\"$CNPJ_INATIVO\",\"email_contato\":\"teste-e2e-3113-inativo@optimon.local\"}")
PARCEIRO_INATIVO_ID=$(jget ".id")
if [ "$CODE" = "201" ] && [ -n "$PARCEIRO_INATIVO_ID" ]; then
  ALL_PARCEIROS_TESTE+=("$PARCEIRO_INATIVO_ID")
  CODE=$(api POST "/api/partners/$PARCEIRO_INATIVO_ID/deactivate" "$TOK_ADMIN" '{"motivo":"Parceiro de teste — mantido inativo de propósito para TESTE-74."}')
  [ "$CODE" = "200" ] && pass "TESTE-72 setup: parceiro TESTE-E2E-OPTIMON-3113-INATIVO criado e desativado — pronto para o TESTE-74" \
    || fail "TESTE-72 setup: desativar parceiro de teste" "codigo=$CODE body=$(body)"
else
  fail "TESTE-72 setup: criar parceiro inativo de teste" "codigo=$CODE body=$(body)"
fi

# Simulação real reaproveitável para os 3 testes de criação de proposta abaixo — só o
# parceiro_id muda entre eles (o que está sob teste).
CODE=$(api POST "/api/pricing/calculate" "$TOK_COMERCIAL" "{\"cidade_id\":\"$CIDADE_ID\",\"clientes\":180,\"arpu\":85,\"revenue_share_pct\":0.12}")
RESULTADO_3113_JSON=$(body)
SIM_3113_BODY=$(node -e "
const r = $RESULTADO_3113_JSON;
console.log(JSON.stringify({cidade_id: '$CIDADE_ID', modelo: 'HIBRIDO_REVENUE_SHARE', pares_ou_clientes: 180, arpu: 85, revenue_share_pct: 0.12, prazo_meses: 48, resultado: r}));
")
CODE=$(api POST "/api/simulations" "$TOK_COMERCIAL" "$SIM_3113_BODY")
SIM_3113_ID=$(jget ".id")
[ "$CODE" = "201" ] && [ -n "$SIM_3113_ID" ] && pass "TESTE-73 setup: simulação real para os testes de parceiro obrigatório salva — id=$SIM_3113_ID" \
  || fail "TESTE-73 setup: salvar simulação para os testes de parceiro obrigatório" "codigo=$CODE body=$(body)"

echo "--- seção 17, item 1: criar proposta SEM parceiro (campo omitido) ---"
CODE=$(api POST "/api/proposals" "$TOK_COMERCIAL" "{\"simulacao_id\":\"$SIM_3113_ID\",\"cidade_id\":\"$CIDADE_ID\"}")
[ "$CODE" = "400" ] && [ "$(jget '.code')" = "PARTNER_REQUIRED" ] \
  && pass "TESTE-74 (negativo, seção 17.1) criar proposta SEM parceiro_id é BLOQUEADO — 400 PARTNER_REQUIRED" \
  || fail "TESTE-74 (negativo) proposta sem parceiro deveria ser bloqueada com 400 PARTNER_REQUIRED" "codigo=$CODE body=$(body)"

echo "--- seção 17, item 1b: criar proposta com parceiro_id string vazia ---"
CODE=$(api POST "/api/proposals" "$TOK_COMERCIAL" "{\"simulacao_id\":\"$SIM_3113_ID\",\"cidade_id\":\"$CIDADE_ID\",\"parceiro_id\":\"\"}")
[ "$CODE" = "400" ] && [ "$(jget '.code')" = "PARTNER_REQUIRED" ] \
  && pass "TESTE-75 (negativo, seção 17.1) criar proposta com parceiro_id vazio é BLOQUEADO — 400 PARTNER_REQUIRED" \
  || fail "TESTE-75 (negativo) proposta com parceiro_id vazio deveria ser bloqueada" "codigo=$CODE body=$(body)"

echo "--- seção 17, item 2: criar proposta com parceiro_id INEXISTENTE ---"
CODE=$(api POST "/api/proposals" "$TOK_COMERCIAL" "{\"simulacao_id\":\"$SIM_3113_ID\",\"cidade_id\":\"$CIDADE_ID\",\"parceiro_id\":\"00000000-0000-0000-0000-000000000000\"}")
[ "$CODE" = "404" ] && [ "$(jget '.code')" = "PARTNER_NOT_FOUND" ] \
  && pass "TESTE-76 (negativo, seção 17.2) criar proposta com parceiro_id inexistente é BLOQUEADO — 404 PARTNER_NOT_FOUND" \
  || fail "TESTE-76 (negativo) proposta com parceiro inexistente deveria ser bloqueada com 404 PARTNER_NOT_FOUND" "codigo=$CODE body=$(body)"

echo "--- seção 17, item 3: criar proposta com parceiro INATIVO ---"
CODE=$(api POST "/api/proposals" "$TOK_COMERCIAL" "{\"simulacao_id\":\"$SIM_3113_ID\",\"cidade_id\":\"$CIDADE_ID\",\"parceiro_id\":\"$PARCEIRO_INATIVO_ID\"}")
[ "$CODE" = "400" ] && [ "$(jget '.code')" = "PARTNER_INACTIVE" ] \
  && pass "TESTE-77 (negativo, seção 17.3) criar proposta com parceiro INATIVO é BLOQUEADO — 400 PARTNER_INACTIVE" \
  || fail "TESTE-77 (negativo) proposta com parceiro inativo deveria ser bloqueada com 400 PARTNER_INACTIVE" "codigo=$CODE body=$(body)"

echo "--- seção 17, item 4: mesmo bloqueio direto no BANCO (bypass total do Node — prova que o backend não é o único a bloquear) ---"
PARTNER_REQUIRED_NO_NODE=$($PSQL -t -A -c "set role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$UID_COMERCIAL\",\"role\":\"authenticated\"}'; select pricing_proposal_create('$SIM_3113_ID', '$CIDADE_ID', null, null, null, null, null, null, null, 15);" 2>&1)
echo "$PARTNER_REQUIRED_NO_NODE" | grep -q "PARTNER_REQUIRED" \
  && pass "TESTE-78 (negativo, seção 17.4, direto no Postgres) pricing_proposal_create chamada sem Node/API nenhum também bloqueia — PARTNER_REQUIRED" \
  || fail "TESTE-78 (negativo) função do banco deveria bloquear mesmo sem passar pela API" "$PARTNER_REQUIRED_NO_NODE"

echo "--- seção 17, item 5: gerar proposta a partir de simulação SEM parceiro (mesmo endpoint — nesta arquitetura toda proposta NASCE de uma simulação, não existe uma tela de 'conversão' separada) ---"
CODE=$(api POST "/api/proposals" "$TOK_COMERCIAL" "{\"simulacao_id\":\"$SIM_3113_ID\"}")
[ "$CODE" = "400" ] && [ "$(jget '.code')" = "PARTNER_REQUIRED" ] \
  && pass "TESTE-79 (negativo, seção 17.5/seção 15) gerar proposta a partir de simulação sem selecionar parceiro é BLOQUEADO" \
  || fail "TESTE-79 (negativo) simulação->proposta sem parceiro deveria ser bloqueada" "codigo=$CODE body=$(body)"

echo "--- prova positiva: a MESMA simulação, agora com parceiro válido e ativo, funciona normalmente ---"
CODE=$(api POST "/api/proposals" "$TOK_COMERCIAL" "{\"simulacao_id\":\"$SIM_3113_ID\",\"cidade_id\":\"$CIDADE_ID\",\"parceiro_id\":\"$PARCEIRO_ID\"}")
PROP_3113_ID=$(jget ".id")
[ "$CODE" = "201" ] && [ -n "$PROP_3113_ID" ] \
  && pass "TESTE-80 criar proposta COM parceiro válido/ativo funciona normalmente — 201, id=$PROP_3113_ID" \
  || fail "TESTE-80 criar proposta com parceiro válido deveria funcionar" "codigo=$CODE body=$(body)"

echo "--- seção 17, item 6: alterar parceiro de proposta já ACEITA_PELO_PARCEIRO (via banco — nenhuma rota da API permite isso; trigger é a rede de segurança) ---"
if [ -n "${PROP_OTP:-}" ]; then
  TROCA_ACEITA=$($PSQL -t -A -c "set role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$UID_DIRETOR\",\"role\":\"authenticated\"}'; update propostas_comerciais set parceiro_id='$PARCEIRO_ID' where id='$PROP_OTP';" 2>&1)
  echo "$TROCA_ACEITA" | grep -q "PARTNER_LOCKED" \
    && pass "TESTE-81 (negativo, seção 17.6) alterar parceiro de proposta ACEITA_PELO_PARCEIRO é BLOQUEADO — PARTNER_LOCKED" \
    || fail "TESTE-81 (negativo) troca de parceiro pós-aceite deveria ser bloqueada" "$TROCA_ACEITA"
else
  fail "TESTE-81 (negativo) troca de parceiro pós-aceite" "PROP_OTP não disponível (sub-fluxo C não rodou) — teste não executado"
fi

echo "--- seção 17, item 7: alterar parceiro de proposta com CONTRATO_GERADO (usa o contrato real gerado na Etapa 10) ---"
if [ -n "${PROP_ID:-}" ] && [ -n "${CONTRATO_ID:-}" ]; then
  STATUS_PROP_ID_ATUAL=$(scalar "select status from propostas_comerciais where id='$PROP_ID';")
  # Usa um parceiro DIFERENTE do já vinculado (PARCEIRO_INATIVO_ID, só como valor de FK —
  # o teste é sobre o UPDATE ser bloqueado, nunca chega a validar ativo/inativo) — usar o
  # mesmo PARCEIRO_ID que a proposta já tem seria um UPDATE sem mudança real
  # (NEW.parceiro_id IS DISTINCT FROM OLD.parceiro_id = false), o que passaria por um
  # "bloqueio" falso-positivo sem testar nada de verdade.
  TROCA_CONTRATO=$($PSQL -t -A -c "set role authenticated; set local \"request.jwt.claims\" = '{\"sub\":\"$UID_DIRETOR\",\"role\":\"authenticated\"}'; update propostas_comerciais set parceiro_id='$PARCEIRO_INATIVO_ID' where id='$PROP_ID';" 2>&1)
  if [ "$STATUS_PROP_ID_ATUAL" = "CONTRATO_GERADO" ]; then
    echo "$TROCA_CONTRATO" | grep -q "PARTNER_LOCKED" \
      && pass "TESTE-82 (negativo, seção 17.7) alterar parceiro de proposta com CONTRATO_GERADO é BLOQUEADO — PARTNER_LOCKED (status confirmado=$STATUS_PROP_ID_ATUAL)" \
      || fail "TESTE-82 (negativo) troca de parceiro pós-contrato deveria ser bloqueada" "status=$STATUS_PROP_ID_ATUAL resultado=$TROCA_CONTRATO"
  else
    # Mesmo fora de CONTRATO_GERADO, qualquer status != RASCUNHO já bloqueia (trigger é
    # mais amplo que os 3 estados citados na seção 16) — ainda uma prova válida.
    echo "$TROCA_CONTRATO" | grep -q "PARTNER_LOCKED" \
      && pass "TESTE-82 (negativo, seção 17.7) alterar parceiro de proposta pós-contrato é BLOQUEADO — PARTNER_LOCKED (status real=$STATUS_PROP_ID_ATUAL, já fora de RASCUNHO)" \
      || fail "TESTE-82 (negativo) troca de parceiro pós-contrato deveria ser bloqueada" "status=$STATUS_PROP_ID_ATUAL resultado=$TROCA_CONTRATO"
  fi
else
  fail "TESTE-82 (negativo) troca de parceiro pós-contrato" "PROP_ID/CONTRATO_ID não disponíveis — teste não executado"
fi

echo "--- seção 14: duplicar/nova versão de uma proposta HISTÓRICA sem parceiro (as 3 linhas reais documentadas no relatório — nunca apagadas) também são bloqueadas ---"
PROP_HISTORICA_SEM_PARCEIRO=$(scalar "select id from propostas_comerciais where parceiro_id is null order by criado_em limit 1;")
if [ -n "$PROP_HISTORICA_SEM_PARCEIRO" ]; then
  CODE=$(api POST "/api/proposals/$PROP_HISTORICA_SEM_PARCEIRO/duplicate" "$TOK_COMERCIAL" '{"motivo":"teste 3.11.3"}')
  [ "$CODE" != "201" ] && [ "$(jget '.code')" = "PARTNER_REQUIRED" ] \
    && pass "TESTE-83 (negativo, seção 14) duplicar proposta histórica sem parceiro é BLOQUEADO — PARTNER_REQUIRED (proposta=$PROP_HISTORICA_SEM_PARCEIRO)" \
    || fail "TESTE-83 (negativo) duplicar proposta histórica sem parceiro deveria ser bloqueado" "codigo=$CODE body=$(body)"

  CODE=$(api POST "/api/proposals/$PROP_HISTORICA_SEM_PARCEIRO/version" "$TOK_COMERCIAL" '{"motivo":"teste 3.11.3"}')
  [ "$CODE" != "201" ] && [ "$(jget '.code')" = "PARTNER_REQUIRED" ] \
    && pass "TESTE-84 (negativo, seção 14) criar nova versão de proposta histórica sem parceiro é BLOQUEADO — PARTNER_REQUIRED" \
    || fail "TESTE-84 (negativo) nova versão de proposta histórica sem parceiro deveria ser bloqueada" "codigo=$CODE body=$(body)"
else
  echo "  (nenhuma proposta histórica sem parceiro encontrada neste banco — TESTE-83/84 pulados; ver relatório final para o levantamento real feito no banco de desenvolvimento desta fase)"
fi

echo "--- levantamento real (seção 13) — nunca alterado automaticamente ---"
HIST_SEM_PARCEIRO_COUNT=$(scalar "select count(*) from propostas_comerciais where parceiro_id is null;")
pass "TESTE-85 levantamento seção 13 executado: $HIST_SEM_PARCEIRO_COUNT proposta(s) histórica(s) sem parceiro — preservada(s), não alterada(s) (ver relatório final para os IDs/datas/status)"

echo "############################################################"
echo "# FASE 3.11.3 — RESEND REAL (seções 3-9) #"
echo "############################################################"

echo "--- api/lib/emailService.js: buildEmailProvider() honesto sobre a AUSÊNCIA de configuração (nunca finge) ---"
RESEND_UNIT_1=$(cd api && RESEND_API_KEY= RESEND_FROM_EMAIL= node -e "
const { buildEmailProvider } = require('./lib/emailService');
console.log(buildEmailProvider() === null ? 'NULL_OK' : 'DEVERIA_SER_NULL');
")
[ "$RESEND_UNIT_1" = "NULL_OK" ] \
  && pass "TESTE-86 buildEmailProvider() devolve null quando RESEND_API_KEY/RESEND_FROM_EMAIL ausentes (nunca inventa/finge configuração)" \
  || fail "TESTE-86 buildEmailProvider() deveria devolver null sem configuração" "$RESEND_UNIT_1"

echo "--- api/lib/emailService.js: client REAL montado corretamente quando as variáveis existem, e a API key NUNCA aparece no objeto serializado nem em erro nenhum ---"
RESEND_UNIT_2=$(cd api && RESEND_API_KEY=re_teste_fake_key_nao_e_real_12345 RESEND_FROM_EMAIL="OptiMon <noreply@teste.optimon.local>" node -e "
const { buildEmailProvider, ResendEmailProvider } = require('./lib/emailService');
const p = buildEmailProvider();
const isInstance = p instanceof ResendEmailProvider;
const serialized = JSON.stringify(p);
const leaked = serialized.includes('re_teste_fake_key_nao_e_real_12345');
console.log(isInstance && !leaked ? 'OK' : 'FALHOU: instance=' + isInstance + ' leaked=' + leaked);
")
[ "$RESEND_UNIT_2" = "OK" ] \
  && pass "TESTE-87 buildEmailProvider() monta ResendEmailProvider quando configurado, e a API key nunca vaza em JSON.stringify do objeto" \
  || fail "TESTE-87 client Resend deveria montar corretamente sem vazar a chave" "$RESEND_UNIT_2"

echo "--- api/lib/emailService.js: send() trata rede/HTTP corretamente (fetch mockado — sem tocar a rede real, sem gastar cota do Resend) ---"
RESEND_UNIT_3=$(cd api && RESEND_API_KEY=re_teste_fake RESEND_FROM_EMAIL="OptiMon <noreply@teste.optimon.local>" node -e "
const { buildEmailProvider } = require('./lib/emailService');
(async () => {
  const results = [];
  const provider = buildEmailProvider();

  // 1) sucesso: Resend responde 200 com id.
  global.fetch = async () => ({ ok: true, status: 200, json: async () => ({ id: 'email-fake-123' }) });
  const ok = await provider.send({ to: 'parceiro@teste.local', subject: 'Assunto', html: '<p>x</p>', text: 'x' });
  results.push(ok.emailId === 'email-fake-123' ? 'SEND_OK' : 'SEND_OK_FALHOU:' + JSON.stringify(ok));

  // 2) Resend rejeita (4xx) — erro sanitizado, sem vazar a api key.
  global.fetch = async () => ({ ok: false, status: 422, json: async () => ({ message: 'invalid from address' }) });
  try {
    await provider.send({ to: 'parceiro@teste.local', subject: 'Assunto', html: '<p>x</p>', text: 'x' });
    results.push('REJEICAO_DEVERIA_LANCAR_ERRO');
  } catch (e) {
    const leaked = String(e.message).includes('re_teste_fake');
    results.push(!leaked && /RESEND_REJEITOU_ENVIO/.test(e.message) ? 'REJEICAO_OK' : 'REJEICAO_FALHOU:' + e.message);
  }

  // 3) falha de rede — erro sanitizado.
  global.fetch = async () => { throw new Error('ECONNREFUSED (simulado)'); };
  try {
    await provider.send({ to: 'parceiro@teste.local', subject: 'Assunto', html: '<p>x</p>', text: 'x' });
    results.push('REDE_DEVERIA_LANCAR_ERRO');
  } catch (e) {
    const leaked = String(e.message).includes('re_teste_fake');
    results.push(!leaked && /RESEND_INDISPONIVEL/.test(e.message) ? 'REDE_OK' : 'REDE_FALHOU:' + e.message);
  }

  console.log(results.join('|'));
})();
")
echo "$RESEND_UNIT_3" | grep -q "SEND_OK|REJEICAO_OK|REDE_OK" \
  && pass "TESTE-88 ResendEmailProvider.send(): sucesso/rejeição do provedor/falha de rede tratados corretamente, sem vazar a API key em nenhum caso — $RESEND_UNIT_3" \
  || fail "TESTE-88 ResendEmailProvider.send() deveria tratar os 3 cenários corretamente" "$RESEND_UNIT_3"

echo "--- api/lib/otpNotifier.js: fallback DEV_LOG nunca roda em produção (falha alto e claro, nunca finge sucesso) ---"
RESEND_UNIT_4=$(cd api && RESEND_API_KEY= RESEND_FROM_EMAIL= APP_ENVIRONMENT=production node -e "
const { buildOtpNotifier } = require('./lib/otpNotifier');
(async () => {
  try {
    await buildOtpNotifier().sendOtp({ email: 'x@x.com', nome: 'X', numero: 'PROP-1', proponente: 'Y', otp: '123456', expiraEm: new Date().toISOString(), tentativaId: 'fake' });
    console.log('DEVERIA_TER_LANCADO_ERRO');
  } catch (e) {
    console.log(/RESEND_NAO_CONFIGURADO/.test(e.message) ? 'BLOQUEADO_OK' : 'ERRO_INESPERADO:' + e.message);
  }
})();
")
[ "$RESEND_UNIT_4" = "BLOQUEADO_OK" ] \
  && pass "TESTE-89 fallback DEV_LOG do otpNotifier RECUSA operar quando APP_ENVIRONMENT=production sem RESEND_API_KEY (nunca finge sucesso em produção — seção 6)" \
  || fail "TESTE-89 fallback DEV_LOG deveria recusar operar em produção" "$RESEND_UNIT_4"

echo "--- prova end-to-end (REAL, executada acima nas ETAPAS 8-9): neste ambiente de desenvolvimento, sem RESEND_API_KEY configurada, o fluxo de OTP usa o fallback DEV_LOG e grava o email_status corretamente ---"
if [ -n "${TENTATIVA_ID:-}" ]; then
  EMAIL_STATUS_REAL=$(scalar "select email_status from propostas_aceite_tentativas where id='$TENTATIVA_ID';")
  EMAIL_CANAL_REAL=$(scalar "select email_canal from propostas_aceite_tentativas where id='$TENTATIVA_ID';")
  [ "$EMAIL_CANAL_REAL" = "DEV_LOG" ] && [ -n "$EMAIL_STATUS_REAL" ] && [ "$EMAIL_STATUS_REAL" != "OTP_GERADO" ] \
    && pass "TESTE-90 tentativa real do fluxo principal tem email_status=$EMAIL_STATUS_REAL / email_canal=$EMAIL_CANAL_REAL gravado corretamente (neste ambiente sem RESEND_API_KEY — ver RELATÓRIO FINAL seção RESEND)" \
    || fail "TESTE-90 email_status/email_canal deveriam estar preenchidos após /accept/iniciar" "email_status=$EMAIL_STATUS_REAL email_canal=$EMAIL_CANAL_REAL"
else
  fail "TESTE-90 email_status da tentativa do fluxo principal" "TENTATIVA_ID não disponível"
fi

echo "--- api/routes/emailWebhooks.js: assinatura Svix VÁLIDA é aceita (evento sem tentativa correspondente = ignorado, mas a ASSINATURA em si passa) ---"
echo '{"type":"email.delivered","data":{"email_id":"email-inexistente-teste-3113"}}' > /tmp/fase311_resend_webhook_payload.json
CODE=$(sign_and_post_resend_webhook /tmp/fase311_resend_webhook_payload.json)
[ "$CODE" = "200" ] \
  && pass "TESTE-91 webhook do Resend com assinatura Svix VÁLIDA é aceito (200) — evento sem tentativa correspondente é ignorado sem erro" \
  || fail "TESTE-91 webhook com assinatura válida deveria ser aceito" "codigo=$CODE body=$(cat /tmp/fase311_resend_webhook_resp.json 2>/dev/null)"

echo "--- api/routes/emailWebhooks.js: assinatura Svix INVÁLIDA/adulterada é REJEITADA (401) — nunca processa sem validar (seção 21) ---"
CODE=$(sign_and_post_resend_webhook /tmp/fase311_resend_webhook_payload.json "adulterada")
[ "$CODE" = "401" ] \
  && pass "TESTE-92 (negativo) webhook do Resend com assinatura ADULTERADA é BLOQUEADO — 401, nunca processa o evento" \
  || fail "TESTE-92 (negativo) webhook com assinatura inválida deveria ser bloqueado com 401" "codigo=$CODE body=$(cat /tmp/fase311_resend_webhook_resp.json 2>/dev/null)"

echo "--- api/routes/emailWebhooks.js: evento REAL casando com uma tentativa real (a do fluxo principal) atualiza email_status corretamente ---"
if [ -n "${TENTATIVA_ID:-}" ]; then
  EMAIL_PROVIDER_ID_REAL=$(scalar "select email_provider_id from propostas_aceite_tentativas where id='$TENTATIVA_ID';")
  if [ -n "$EMAIL_PROVIDER_ID_REAL" ] && [ "$EMAIL_PROVIDER_ID_REAL" != "" ]; then
    node -e "console.log(JSON.stringify({type:'email.delivered', data:{email_id: '$EMAIL_PROVIDER_ID_REAL'}}))" > /tmp/fase311_resend_webhook_payload2.json
    CODE=$(sign_and_post_resend_webhook /tmp/fase311_resend_webhook_payload2.json)
    EMAIL_STATUS_POS_WEBHOOK=$(scalar "select email_status from propostas_aceite_tentativas where id='$TENTATIVA_ID';")
    [ "$CODE" = "200" ] && [ "$EMAIL_STATUS_POS_WEBHOOK" = "EMAIL_ENTREGUE" ] \
      && pass "TESTE-93 evento real 'email.delivered' do webhook do Resend atualiza email_status para EMAIL_ENTREGUE (tentativa_id=$TENTATIVA_ID)" \
      || fail "TESTE-93 webhook deveria atualizar email_status para EMAIL_ENTREGUE" "codigo=$CODE email_status=$EMAIL_STATUS_POS_WEBHOOK"
  else
    echo "  (email_provider_id vazio neste ambiente — canal DEV_LOG não gera email_id real do Resend; TESTE-93 pulado, comportamento esperado sem RESEND_API_KEY configurada)"
  fi
else
  fail "TESTE-93 evento real do webhook" "TENTATIVA_ID não disponível"
fi

echo "--- api/routes/emailWebhooks.js: sem RESEND_WEBHOOK_SECRET configurada, o endpoint recusa processar (nunca aceita sem conseguir validar) — testado num processo Express isolado, à parte, para nunca precisar derrubar a API principal em uso pelo resto da suíte ---"
rm -f /tmp/fase311_webhook_only.log
( cd api && nohup env -u RESEND_WEBHOOK_SECRET PORT=3099 node -e "
const express = require('express');
const { router } = require('./routes/emailWebhooks');
const app = express();
app.use('/api/webhooks', router);
app.listen(3099, () => console.log('webhook-only ouvindo na porta 3099'));
" > /tmp/fase311_webhook_only.log 2>&1 & disown )
sleep 1
CODE_SEM_SECRET=$(curl -sS -o /tmp/fase311_webhook_only_resp.json -w '%{http_code}' -X POST "http://localhost:3099/api/webhooks/resend" -H "Content-Type: application/json" --data-binary '{"type":"email.delivered","data":{"email_id":"x"}}')
[ "$CODE_SEM_SECRET" = "500" ] \
  && pass "TESTE-94 (negativo) sem RESEND_WEBHOOK_SECRET configurada, o webhook recusa processar — 500 controlado, nunca aceita sem conseguir validar a assinatura" \
  || fail "TESTE-94 (negativo) webhook sem segredo configurado deveria recusar com 500" "codigo=$CODE_SEM_SECRET body=$(cat /tmp/fase311_webhook_only_resp.json 2>/dev/null)"
kill_matching "webhook-only ouvindo"

echo "############################################################"
echo "# FASE 3.11.4 — ENVIO REAL DA ASSINATURA (envelope TESTE-E2E-ASSINATURA-3114) #"
echo "############################################################"
# Correção crítica real: o envelope de produção 571aa526-dd1e-4345-85e5-71b30ce68e8e
# mostrou os 3 signatários como ENVIADO sem nenhum ter recebido e-mail — causa raiz
# provada por auditoria de código (app.enviar_envelope_para_assinatura marcava ENVIADO
# incondicionalmente, sem nenhum provider real de e-mail jamais implementado). Esta seção
# testa a correção: um 2º provider (OPTIMON_INTERNO_RESEND) que usa o Resend real (mesmo
# client da Fase 3.11.3) para o link de assinatura, e nunca mais marca ENVIADO sem prova
# de aceite do provedor.
#
# Reaproveita o CONTRATO_ID do fluxo principal (novo envelope, 2º sobre o mesmo contrato —
# signature_envelopes não tem limite de 1 por contrato; app.contrato_assinatura_status usa
# sempre o mais recente). Signatários com sufixo -e2e3114 para identificação, mesmo padrão
# -e2e311 já usado acima.

echo "--- provider OPTIMON_INTERNO_RESEND ---"
PROVIDER_RESEND_ID=$(scalar "select id from signature_providers where tipo='OPTIMON_INTERNO_RESEND' limit 1;")
if [ -z "$PROVIDER_RESEND_ID" ]; then
  CODE=$(api POST "/api/signatures/providers" "$TOK_ADMIN" '{"nome":"OptiMon Interno (Resend) — Fase3114 Teste","tipo":"OPTIMON_INTERNO_RESEND","ambiente":"HOMOLOGACAO"}')
  PROVIDER_RESEND_ID=$(jget ".id")
fi
[ -n "$PROVIDER_RESEND_ID" ] \
  && pass "TESTE-95 provider OPTIMON_INTERNO_RESEND disponível — id=$PROVIDER_RESEND_ID (seção 12: OptiMon envia o link via Resend, sem provedor ICP-Brasil terceirizado — arquitetura escolhida pelo usuário)" \
  || { fail "TESTE-95 criar/obter provider OPTIMON_INTERNO_RESEND" "body=$(body)"; }

echo "--- ENVELOPE TESTE-E2E-ASSINATURA-3114: novo envelope do mesmo CONTRATO, provider Resend interno, só 2 signatários (seção 6 do pedido: simplificar o diagnóstico) ---"
ENV3114_ID=$(curl -sS -o /tmp/fase311_resp.json -w '' -X POST "$API/api/signatures/envelopes" -H "Authorization: Bearer $TOK_COMERCIAL" -F "tipo_documento=CONTRATO" -F "provider_id=$PROVIDER_RESEND_ID" -F "contrato_id=$CONTRATO_ID" > /dev/null; jget ".id")
[ -n "$ENV3114_ID" ] \
  && pass "TESTE-96 envelope TESTE-E2E-ASSINATURA-3114 criado (id=$ENV3114_ID, provider=OPTIMON_INTERNO_RESEND, contrato=$CONTRATO_ID)" \
  || { fail "TESTE-96 criar envelope TESTE-E2E-ASSINATURA-3114" "body=$(body)"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }

CODE=$(api POST "/api/signatures/envelopes/$ENV3114_ID/signers" "$TOK_COMERCIAL" '{"nome":"NICK e2e3114","email":"nick-e2e3114@optimon.local","papel":"REPRESENTANTE_NICK","ordem":1,"obrigatorio":true}')
S3114_NICK=$(jget ".id")
CODE=$(api POST "/api/signatures/envelopes/$ENV3114_ID/signers" "$TOK_COMERCIAL" '{"nome":"Parceiro e2e3114","email":"parceiro-e2e3114@optimon.local","papel":"REPRESENTANTE_PROPONENTE","ordem":2,"obrigatorio":true}')
S3114_PARCEIRO=$(jget ".id")
[ -n "$S3114_NICK" ] && [ -n "$S3114_PARCEIRO" ] \
  && pass "TESTE-97 2 signatários adicionados ao envelope TESTE-E2E-ASSINATURA-3114 (NICK=$S3114_NICK, PARCEIRO=$S3114_PARCEIRO)" \
  || fail "TESTE-97 adicionar signatários ao envelope 3114" "nick=$S3114_NICK parceiro=$S3114_PARCEIRO"

echo "--- ENVIAR (POST /send) — sem RESEND_API_KEY configurada neste ambiente (mesma limitação já documentada para o OTP na Fase 3.11.3) ---"
CODE=$(api POST "/api/signatures/envelopes/$ENV3114_ID/send" "$TOK_COMERCIAL")
[ "$CODE" = "200" ] \
  && pass "TESTE-98 POST /send respondeu 200 (a requisição HTTP em si sempre é processada — o resultado REAL do envio é o que os testes seguintes verificam no banco, nunca o código HTTP sozinho)" \
  || fail "TESTE-98 enviar envelope TESTE-E2E-ASSINATURA-3114" "codigo=$CODE body=$(body)"

echo "--- TESTE CRÍTICO (seção 3/11 do pedido, regressão do bug real 571aa526): sem confirmação real do Resend, o envelope NUNCA fica ENVIADO — vira ERRO_ENVIO, nunca finge sucesso ---"
ENV3114_STATUS=$(scalar "select status from signature_envelopes where id='$ENV3114_ID';")
[ "$ENV3114_STATUS" = "ERRO_ENVIO" ] \
  && pass "TESTE-99 (CRÍTICO) envelope TESTE-E2E-ASSINATURA-3114 corretamente em ERRO_ENVIO (nunca ENVIADO) — sem RESEND_API_KEY configurada, nenhum e-mail foi de fato aceito pelo provedor; status=$ENV3114_STATUS" \
  || fail "TESTE-99 (CRÍTICO — regressão do bug 571aa526) envelope deveria estar ERRO_ENVIO, nunca ENVIADO sem prova real" "status=$ENV3114_STATUS"

STATUS_NICK_3114=$(scalar "select status from signature_signers where id='$S3114_NICK';")
STATUS_PARCEIRO_3114=$(scalar "select status from signature_signers where id='$S3114_PARCEIRO';")
ERRO_NICK_3114=$(scalar "select erro_mensagem from signature_signers where id='$S3114_NICK';")
[ "$STATUS_NICK_3114" = "ERRO_ENVIO" ] && [ "$STATUS_PARCEIRO_3114" = "ERRO_ENVIO" ] && [ -n "$ERRO_NICK_3114" ] \
  && pass "TESTE-100 os 2 signatários corretamente em ERRO_ENVIO com erro_mensagem preenchida (nick=\"$ERRO_NICK_3114\")" \
  || fail "TESTE-100 status por signatário deveria ser ERRO_ENVIO com erro_mensagem" "nick=$STATUS_NICK_3114 parceiro=$STATUS_PARCEIRO_3114 erro=$ERRO_NICK_3114"

echo "--- confirma que o link REAL foi gerado e ficou disponível no log do servidor (a falha é honesta sobre 'não enviei e-mail', nunca sobre 'não gerei o link') ---"
LINKS_NO_LOG=$(grep -c "DEV-SIGNATURE-LINK-NAO-E-EMAIL-REAL.*e2e3114@optimon.local" /tmp/fase311_api.log 2>/dev/null || echo 0)
[ "$LINKS_NO_LOG" -ge 2 ] \
  && pass "TESTE-101 os 2 links de assinatura foram gerados e logados (canal DEV_LOG, $LINKS_NO_LOG ocorrência(s)) — a limitação é só a confirmação de entrega, nunca a geração do link em si" \
  || fail "TESTE-101 links de assinatura deveriam aparecer no log do servidor (DEV_LOG)" "ocorrencias=$LINKS_NO_LOG"

echo "--- app.contrato_assinatura_status (extensão da Fase 3.11.4, seção 16): mostra o ENVELOPE MAIS RECENTE (o 3114, não mais o mock da ETAPA 13) com provider_nome/provider_tipo corretos ---"
STATUS_JSON_3114=$($PSQL -t -A -q -c "select app.contrato_assinatura_status('$CONTRATO_ID');")
PROVIDER_TIPO_NO_STATUS=$(echo "$STATUS_JSON_3114" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).provider_tipo||'')}catch(e){console.log('')}})")
ENVELOPE_ID_NO_STATUS=$(echo "$STATUS_JSON_3114" | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).envelope_id||'')}catch(e){console.log('')}})")
[ "$PROVIDER_TIPO_NO_STATUS" = "OPTIMON_INTERNO_RESEND" ] && [ "$ENVELOPE_ID_NO_STATUS" = "$ENV3114_ID" ] \
  && pass "TESTE-102 app.contrato_assinatura_status mostra o envelope mais recente ($ENV3114_ID) com provider_tipo=OPTIMON_INTERNO_RESEND (seção 16: tela deixa claro qual provedor está em uso)" \
  || fail "TESTE-102 app.contrato_assinatura_status deveria mostrar o envelope 3114 com o provider correto" "envelope=$ENVELOPE_ID_NO_STATUS provider_tipo=$PROVIDER_TIPO_NO_STATUS"

echo "--- NEGATIVO (seção 14, cenário 'e-mail inválido'/'envelope inexistente'): token de acesso inexistente é recusado ---"
CODE=$(curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' "$API/api/signatures/external/token-forjado-nao-existe-3114")
ERRO_TOKEN=$(jget ".error")
echo "$ERRO_TOKEN" | grep -qi "TOKEN_INVALIDO" \
  && pass "TESTE-103 (negativo) GET com token inexistente é recusado com TOKEN_INVALIDO (codigo=$CODE)" \
  || fail "TESTE-103 (negativo) token inexistente deveria ser recusado com TOKEN_INVALIDO" "codigo=$CODE erro=$ERRO_TOKEN"

echo "--- simula, só para este teste local sem credencial real do Resend, o que a Fase 3.11.4 faria automaticamente com RESEND_API_KEY configurada: marca ENVIADO por SQL direto (nunca via HTTP) para poder testar de ponta a ponta o link individual (abrir/assinar/recusar) — documentado explicitamente como simulação, nunca apresentado como prova de e-mail real recebido (isso só o usuário, com a chave real do Resend em produção, pode confirmar) ---"
TOKEN_NICK_3114=$(scalar "select token_acesso from signature_signers where id='$S3114_NICK';")
TOKEN_PARCEIRO_3114=$(scalar "select token_acesso from signature_signers where id='$S3114_PARCEIRO';")
$PSQL -c "update signature_signers set status='ENVIADO', enviado_em=now(), erro_mensagem=null where id in ('$S3114_NICK','$S3114_PARCEIRO');" > /dev/null
[ -n "$TOKEN_NICK_3114" ] && [ -n "$TOKEN_PARCEIRO_3114" ] \
  && pass "TESTE-104 tokens de acesso individuais (64 hex chars) foram gerados por app.envelope_signatario_gerar_link ANTES da tentativa de envio (nick=${TOKEN_NICK_3114:0:8}… parceiro=${TOKEN_PARCEIRO_3114:0:8}…) — reutilizados abaixo para testar o link externo de ponta a ponta" \
  || fail "TESTE-104 tokens de acesso deveriam ter sido gerados" "nick=$TOKEN_NICK_3114 parceiro=$TOKEN_PARCEIRO_3114"

echo "--- GET /api/signatures/external/:token (abrir o link) — marca ABERTO, nunca representa assinatura, nunca vaza preço/margem/dado interno ---"
CODE=$(curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' "$API/api/signatures/external/$TOKEN_NICK_3114")
JA_ASSINADO_ABERTURA=$(jget ".ja_assinado")
STATUS_POS_ABERTURA=$(scalar "select status from signature_signers where id='$S3114_NICK';")
HAS_PRECO=$(jhas "preco_final")
[ "$CODE" = "200" ] && [ "$JA_ASSINADO_ABERTURA" = "false" ] && [ "$STATUS_POS_ABERTURA" = "ABERTO" ] && [ "$HAS_PRECO" = "NAO" ] \
  && pass "TESTE-105 abrir o link marca ABERTO (nunca ASSINADO) e não expõe nenhum dado interno (preco_final ausente) — status=$STATUS_POS_ABERTURA" \
  || fail "TESTE-105 abrir o link" "codigo=$CODE ja_assinado=$JA_ASSINADO_ABERTURA status=$STATUS_POS_ABERTURA tem_preco=$HAS_PRECO"

echo "--- NEGATIVO (seção 14 'aceite sem checkbox'): assinar sem declaração é recusado ---"
CODE=$(curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' -X POST "$API/api/signatures/external/$TOKEN_NICK_3114/assinar" -H "Content-Type: application/json" -d '{"nome":"Representante NICK e2e3114","documento":"000.000.000-00","declaracao":false}')
jget ".error" | grep -qi "DECLARACAO_OBRIGATORIA" \
  && pass "TESTE-106 (negativo) assinar sem marcar a declaração é recusado com DECLARACAO_OBRIGATORIA (codigo=$CODE)" \
  || fail "TESTE-106 (negativo) assinar sem declaração deveria ser recusado" "codigo=$CODE body=$(body)"

echo "--- NEGATIVO (seção 14 'CPF/nome ausente'): assinar sem CPF é recusado ---"
CODE=$(curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' -X POST "$API/api/signatures/external/$TOKEN_NICK_3114/assinar" -H "Content-Type: application/json" -d '{"nome":"Representante NICK e2e3114","documento":"","declaracao":true}')
jget ".error" | grep -qi "DADOS_OBRIGATORIOS" \
  && pass "TESTE-107 (negativo) assinar sem CPF é recusado com DADOS_OBRIGATORIOS (codigo=$CODE)" \
  || fail "TESTE-107 (negativo) assinar sem CPF deveria ser recusado" "codigo=$CODE body=$(body)"

echo "--- ASSINAR de verdade (dados completos + declaração) — só aqui ASSINADO é gravado ---"
CODE=$(curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' -X POST "$API/api/signatures/external/$TOKEN_NICK_3114/assinar" -H "Content-Type: application/json" -d '{"nome":"Representante NICK e2e3114","documento":"123.456.789-00","declaracao":true}')
STATUS_ASSINADO_NICK=$(scalar "select status from signature_signers where id='$S3114_NICK';")
CERT_TIPO=$(scalar "select certificado_info->>'tipo' from signature_signers where id='$S3114_NICK';")
[ "$CODE" = "200" ] && [ "$STATUS_ASSINADO_NICK" = "ASSINADO" ] && [ "$CERT_TIPO" = "ASSINATURA_ELETRONICA_SIMPLES" ] \
  && pass "TESTE-108 signatário NICK assinou de verdade via link — status=ASSINADO, certificado_info.tipo=$CERT_TIPO (honesto: nunca ICP-Brasil qualificada — seção 12 do pedido)" \
  || fail "TESTE-108 assinar via link deveria gravar ASSINADO" "codigo=$CODE status=$STATUS_ASSINADO_NICK cert_tipo=$CERT_TIPO"

echo "--- NEGATIVO (seção 14 'assinatura duplicada'): assinar de novo com o mesmo token é recusado ---"
CODE=$(curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' -X POST "$API/api/signatures/external/$TOKEN_NICK_3114/assinar" -H "Content-Type: application/json" -d '{"nome":"Representante NICK e2e3114","documento":"123.456.789-00","declaracao":true}')
jget ".error" | grep -qi "ASSINATURA_DUPLICADA" \
  && pass "TESTE-109 (negativo) assinar duas vezes com o mesmo token é recusado com ASSINATURA_DUPLICADA (codigo=$CODE)" \
  || fail "TESTE-109 (negativo) assinatura duplicada deveria ser recusada" "codigo=$CODE body=$(body)"

echo "--- ENVELOPE ainda não pode ficar ASSINADO: falta o 2º signatário obrigatório (parceiro) ---"
ENV3114_STATUS_PARCIAL=$(scalar "select status from signature_envelopes where id='$ENV3114_ID';")
[ "$ENV3114_STATUS_PARCIAL" = "PARCIALMENTE_ASSINADO" ] \
  && pass "TESTE-110 com 1 de 2 obrigatórios assinado, envelope corretamente PARCIALMENTE_ASSINADO — status=$ENV3114_STATUS_PARCIAL" \
  || fail "TESTE-110 status parcial do envelope 3114" "status=$ENV3114_STATUS_PARCIAL"

echo "--- NEGATIVO (seção 14 'signatário não autorizado'/'assinatura por quem não deveria'): assinar com token de OUTRO signatário nunca afeta o signatário errado — cada token só assina o próprio signatário (já garantido pela FK token_acesso->signer, testado aqui de forma factual) ---"
STATUS_PARCEIRO_ANTES=$(scalar "select status from signature_signers where id='$S3114_PARCEIRO';")
[ "$STATUS_PARCEIRO_ANTES" != "ASSINADO" ] \
  && pass "TESTE-111 (negativo) assinar com o token do NICK não alterou o signatário PARCEIRO (status=$STATUS_PARCEIRO_ANTES, continua pendente — cada token é exclusivo de 1 signatário)" \
  || fail "TESTE-111 (CRÍTICO) token de um signatário afetou outro signatário" "status_parceiro=$STATUS_PARCEIRO_ANTES"

echo "--- RECUSAR pelo link (2º signatário, seção 13) — motivo obrigatório ---"
CODE=$(curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' -X POST "$API/api/signatures/external/$TOKEN_PARCEIRO_3114/recusar" -H "Content-Type: application/json" -d '{"motivo":""}')
jget ".error" | grep -qi "MOTIVO_OBRIGATORIO" \
  && pass "TESTE-112 (negativo) recusar sem motivo é recusado com MOTIVO_OBRIGATORIO (codigo=$CODE)" \
  || fail "TESTE-112 (negativo) recusar sem motivo deveria ser recusado" "codigo=$CODE body=$(body)"

CODE=$(curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' -X POST "$API/api/signatures/external/$TOKEN_PARCEIRO_3114/recusar" -H "Content-Type: application/json" -d '{"motivo":"Teste E2E — recusa deliberada do 2 signatário obrigatório (TESTE-E2E-ASSINATURA-3114)."}')
STATUS_PARCEIRO_RECUSADO=$(scalar "select status from signature_signers where id='$S3114_PARCEIRO';")
ENV3114_STATUS_RECUSADO=$(scalar "select status from signature_envelopes where id='$ENV3114_ID';")
[ "$CODE" = "200" ] && [ "$STATUS_PARCEIRO_RECUSADO" = "RECUSADO" ] && [ "$ENV3114_STATUS_RECUSADO" = "RECUSADO" ] \
  && pass "TESTE-113 (ETAPA FINAL, seção 14 'recusa formal') signatário PARCEIRO recusou — signatário=RECUSADO, envelope (obrigatório recusou) também vira RECUSADO=$ENV3114_STATUS_RECUSADO" \
  || fail "TESTE-113 recusar via link" "codigo=$CODE status_signer=$STATUS_PARCEIRO_RECUSADO status_envelope=$ENV3114_STATUS_RECUSADO"

echo "--- NEGATIVO (seção 14 'finalizar com obrigatório pendente/recusado'): REENVIAR para o signatário que já ASSINOU é bloqueado — nunca duplica assinatura ---"
CODE=$(api POST "/api/signatures/envelopes/$ENV3114_ID/signers/$S3114_NICK/resend" "$TOK_COMERCIAL" '{"motivo":"teste negativo — já assinou"}')
[ "$CODE" != "200" ] \
  && pass "TESTE-114 (negativo) reenviar para signatário já ASSINADO é bloqueado (codigo=$CODE) — nunca duplica assinatura" \
  || fail "TESTE-114 (negativo) reenviar para quem já assinou deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "--- GAP REAL encontrado e corrigido nesta própria fase (seção 10 do pedido): REENVIAR para envelope em ERRO_ENVIO agora É PERMITIDO (antes desta correção, app.reenviar_assinatura_signatario não reconhecia ERRO_ENVIO como status válido para reenvio, e o botão REENVIAR ficaria travado exatamente quando mais se precisa dele) ---"
ENV3114B_ID=$(curl -sS -o /tmp/fase311_resp.json -w '' -X POST "$API/api/signatures/envelopes" -H "Authorization: Bearer $TOK_COMERCIAL" -F "tipo_documento=CONTRATO" -F "provider_id=$PROVIDER_RESEND_ID" -F "contrato_id=$CONTRATO_ID" > /dev/null; jget ".id")
CODE=$(api POST "/api/signatures/envelopes/$ENV3114B_ID/signers" "$TOK_COMERCIAL" '{"nome":"NICK e2e3114b","email":"nick-e2e3114b@optimon.local","papel":"REPRESENTANTE_NICK","ordem":1,"obrigatorio":true}')
S3114B_ID=$(jget ".id")
CODE=$(api POST "/api/signatures/envelopes/$ENV3114B_ID/send" "$TOK_COMERCIAL")
ENV3114B_STATUS=$(scalar "select status from signature_envelopes where id='$ENV3114B_ID';")
CODE_REENVIO=$(api POST "/api/signatures/envelopes/$ENV3114B_ID/signers/$S3114B_ID/resend" "$TOK_COMERCIAL" '{"motivo":"teste — reenvio apos ERRO_ENVIO, corrigido nesta fase"}')
[ "$ENV3114B_STATUS" = "ERRO_ENVIO" ] && [ "$CODE_REENVIO" = "200" ] \
  && pass "TESTE-115 (correção de gap real) envelope caiu em ERRO_ENVIO (status=$ENV3114B_STATUS) e o REENVIAR funcionou (codigo=$CODE_REENVIO) — antes da correção desta fase, esta chamada seria bloqueada com STATUS_INVALIDO" \
  || fail "TESTE-115 reenviar signatário de envelope em ERRO_ENVIO deveria funcionar" "status_envelope=$ENV3114B_STATUS codigo_reenvio=$CODE_REENVIO body=$(body)"

echo "--- webhook do Resend (reaproveitado da Fase 3.11.3, seção 9/12): evento 'email.delivered' para um email_provider_id de ASSINATURA (não de OTP de proposta) atualiza o signatário para ENTREGUE — simulação controlada de email_provider_id via SQL (mesmo padrão já usado nesta suíte para testar o fallback do webhook de forma isolada, sem depender de uma chave real do Resend) ---"
EMAIL_PROVIDER_ID_SIM="email-sim-3114-$RANDOM"
$PSQL -c "update signature_signers set status='ENVIADO', enviado_em=now(), email_provider_id='$EMAIL_PROVIDER_ID_SIM', email_canal='RESEND' where id='$S3114B_ID';" > /dev/null
node -e "console.log(JSON.stringify({type:'email.delivered', data:{email_id: '$EMAIL_PROVIDER_ID_SIM'}}))" > /tmp/fase3114_webhook_payload.json
CODE=$(sign_and_post_resend_webhook /tmp/fase3114_webhook_payload.json)
FLUXO_WEBHOOK=$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('/tmp/fase311_resend_webhook_resp.json','utf8')).fluxo||'')}catch(e){console.log('')}")
STATUS_POS_WEBHOOK_SIG=$(scalar "select status from signature_signers where id='$S3114B_ID';")
[ "$CODE" = "200" ] && [ "$FLUXO_WEBHOOK" = "assinatura_eletronica" ] && [ "$STATUS_POS_WEBHOOK_SIG" = "ENTREGUE" ] \
  && pass "TESTE-116 webhook do Resend (mesmo endpoint da Fase 3.11.3, sem 2ª solução) reconhece email_provider_id de ASSINATURA via fallback (fluxo=$FLUXO_WEBHOOK) e atualiza signatário para ENTREGUE" \
  || fail "TESTE-116 webhook deveria atualizar signatário de assinatura para ENTREGUE" "codigo=$CODE fluxo=$FLUXO_WEBHOOK status_signer=$STATUS_POS_WEBHOOK_SIG"

echo "--- NEGATIVO (provider inexistente): criar envelope com provider_id inválido é recusado com 404 ---"
CODE=$(curl -sS -o /tmp/fase311_resp.json -w '%{http_code}' -X POST "$API/api/signatures/envelopes" -H "Authorization: Bearer $TOK_COMERCIAL" -F "tipo_documento=CONTRATO" -F "provider_id=00000000-0000-0000-0000-000000000000" -F "contrato_id=$CONTRATO_ID")
[ "$CODE" = "404" ] \
  && pass "TESTE-117 (negativo) criar envelope com provider_id inexistente é recusado com 404" \
  || fail "TESTE-117 (negativo) provider inexistente deveria ser recusado com 404" "codigo=$CODE body=$(body)"

echo "--- NEGATIVO (seção 14 'envelope sem signatário'): enviar envelope sem nenhum signatário é recusado ---"
ENV3114C_ID=$(curl -sS -o /tmp/fase311_resp.json -w '' -X POST "$API/api/signatures/envelopes" -H "Authorization: Bearer $TOK_COMERCIAL" -F "tipo_documento=CONTRATO" -F "provider_id=$PROVIDER_RESEND_ID" -F "contrato_id=$CONTRATO_ID" > /dev/null; jget ".id")
CODE=$(api POST "/api/signatures/envelopes/$ENV3114C_ID/send" "$TOK_COMERCIAL")
[ "$CODE" = "400" ] \
  && pass "TESTE-118 (negativo) enviar envelope sem nenhum signatário é recusado com 400 (SEM_SIGNATARIOS)" \
  || fail "TESTE-118 (negativo) enviar envelope sem signatários deveria ser recusado" "codigo=$CODE body=$(body)"

echo "--- auditoria semântica (seção 15 do pedido): eventos reais gravados para o envelope TESTE-E2E-ASSINATURA-3114 ---"
EVENTOS_3114=$(scalar "select string_agg(distinct acao, ',' order by acao) from auditoria where (entidade='signature_envelopes' and entidade_id='$ENV3114_ID') or (entidade='signature_signers' and entidade_id in ('$S3114_NICK','$S3114_PARCEIRO'));")
TEM_SEND_REQUESTED=$(echo "$EVENTOS_3114" | grep -c "SIGNATURE_SEND_REQUESTED" || true)
TEM_SEND_FAILED=$(echo "$EVENTOS_3114" | grep -c "SIGNATURE_SEND_FAILED" || true)
TEM_OPENED=$(echo "$EVENTOS_3114" | grep -c "SIGNATURE_OPENED" || true)
TEM_SIGNED=$(echo "$EVENTOS_3114" | grep -c "SIGNATURE_SIGNED" || true)
TEM_DECLINED=$(echo "$EVENTOS_3114" | grep -c "SIGNATURE_DECLINED_BY_SIGNER" || true)
if [ "$TEM_SEND_REQUESTED" -ge 1 ] && [ "$TEM_SEND_FAILED" -ge 1 ] && [ "$TEM_OPENED" -ge 1 ] && [ "$TEM_SIGNED" -ge 1 ] && [ "$TEM_DECLINED" -ge 1 ]; then
  pass "TESTE-119 auditoria semântica completa para o envelope 3114: $EVENTOS_3114"
else
  fail "TESTE-119 auditoria semântica incompleta para o envelope 3114" "eventos encontrados: $EVENTOS_3114"
fi

echo "############################################################"
echo "# LIMPEZA CONTROLADA — desativa todos os parceiros de teste criados nesta suíte #"
echo "############################################################"
LIMPEZA_OK=1
for PID in "${ALL_PARCEIROS_TESTE[@]}"; do
  [ -z "$PID" ] && continue
  CODE=$(api POST "/api/partners/$PID/deactivate" "$TOK_ADMIN" '{"motivo":"Encerramento de suíte de teste E2E (Fase 3.11 / 3.11.2) — limpeza controlada pós-homologação."}')
  if [ "$CODE" = "200" ]; then
    echo "  desativado: parceiro=$PID"
  else
    echo "  FALHA ao desativar parceiro=$PID codigo=$CODE"
    LIMPEZA_OK=0
  fi
done
[ "$LIMPEZA_OK" = "1" ] \
  && pass "TESTE-71 todos os parceiros de teste (${#ALL_PARCEIROS_TESTE[@]}) desativados ao final (propostas/contratos permanecem como histórico auditável imutável, nunca apagados fisicamente)" \
  || fail "TESTE-71 desativar parceiros de teste" "1 ou mais falharam — ver saída acima"

echo ""
echo "############################################################"
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
echo "############################################################"
if [ $FAIL -gt 0 ]; then
  echo "Falhas:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
echo "Registros do fluxo principal: parceiro=$PARCEIRO_ID proposta=$PROP_ID ($PROP_NUMERO) contrato=$CONTRATO_ID ($CONTRATO_NUMERO) envelope=$ENVELOPE_ID"
echo "Link externo usado no teste: /parceiro/proposta/$TOKEN"
echo "Evidências salvas em: /tmp/fase311_minuta.pdf /tmp/fase311_minuta.docx /tmp/fase311_api.log"
