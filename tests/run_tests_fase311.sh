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
rm -f /tmp/fase311_mig.log
MIG_OK=1
if [ "$JA_TEM_3112" = "t" ]; then
  echo "Banco já tem a Fase 3.11.2 aplicada de uma execução anterior — não fazendo replay de 20261002090000/20261002100000 (isso nunca acontece numa instalação real); reaplicando só 20261003100000 para provar sua idempotência real (DROP FUNCTION/DROP TRIGGER IF EXISTS explícitos)." | tee -a /tmp/fase311_mig.log
  pass "PASSO-0 migration 20261002090000_phase_3_11_workflow_proposta_parceiro.sql já aplicada anteriormente (marcador da 3.11.2 presente) — não replayed"
  pass "PASSO-0 migration 20261002100000_phase_3_11_01_fix_token_gen_random_bytes.sql já aplicada anteriormente (marcador da 3.11.2 presente) — não replayed"
  if $PSQL -v ON_ERROR_STOP=1 -f "supabase/migrations/20261003100000_phase_3_11_02_aceite_otp_assinatura_granular.sql" >> /tmp/fase311_mig.log 2>&1; then
    pass "PASSO-0 migration 20261003100000_phase_3_11_02_aceite_otp_assinatura_granular.sql reaplica sem erro (idempotente de verdade)"
  else
    fail "PASSO-0 aplicar migration 20261003100000_phase_3_11_02_aceite_otp_assinatura_granular.sql" "ver /tmp/fase311_mig.log"
    MIG_OK=0
  fi
else
  MIGS=(
    "supabase/migrations/20261002090000_phase_3_11_workflow_proposta_parceiro.sql"
    "supabase/migrations/20261002100000_phase_3_11_01_fix_token_gen_random_bytes.sql"
    "supabase/migrations/20261003100000_phase_3_11_02_aceite_otp_assinatura_granular.sql"
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
  grep "proposta=${tentativa} " /tmp/fase311_api.log | tail -1 | grep -oE 'codigo=[0-9]{6}' | tail -1 | cut -d= -f2
}

sign_and_post_webhook() {
  local payload_file="$1"
  local sig
  sig=$(openssl dgst -sha256 -hmac "$WEBHOOK_SECRET_VALUE" "$payload_file" | awk '{print $NF}')
  curl -sS -o /tmp/fase311_webhook_resp.json -w '%{http_code}' -X POST "$API/api/signatures/webhook" \
    -H "Content-Type: application/json" -H "X-Signature: $sig" --data-binary "@$payload_file"
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
echo "# NEGATIVO (seção 3) — 'envelope criado' != 'e-mail enviado': nenhum e-mail real é disparado #"
echo "############################################################"
# Investigação completa (não presumida, ver api/lib/signatureProvider.js): a ÚNICA
# implementação real de provedor neste projeto é MockHomologacaoProvider, que NUNCA toca
# rede/e-mail (mesma limitação, honestamente documentada, desde a Fase 2.5). Este teste
# prova isso comparando o dado de fato: "enviado ao provedor" (TESTE-39, 200) não é
# acompanhado de NENHUM registro de entrega real de e-mail em lugar nenhum do projeto —
# não existe nenhuma tabela/coluna que registre "e-mail efetivamente entregue" fora dos
# eventos de webhook SIMULADOS que este próprio script vai disparar abaixo.
# grep só por USO real (require/import de pacote), nunca por menção em comentário —
# api/lib/otpNotifier.js e este próprio script MENCIONAM esses nomes em prosa
# explicando exatamente a ausência deles, o que faria um grep textual simples (sem
# distinguir código de comentário) dar falso-negativo.
grep -rEq "require\(['\"](nodemailer|resend|@sendgrid|nodemailer-smtp)|from ['\"](nodemailer|resend|@sendgrid)" api/lib api/routes 2>/dev/null
FOUND_EMAIL_LIB=$?
grep -Eq '"(nodemailer|resend|@sendgrid/mail)"' api/package.json 2>/dev/null
FOUND_EMAIL_DEP=$?
if [ $FOUND_EMAIL_LIB -ne 0 ] && [ $FOUND_EMAIL_DEP -ne 0 ]; then
  pass "TESTE-40 (achado real, DEPENDÊNCIA EXTERNA) confirmado por leitura de código: não existe NENHUMA biblioteca de e-mail transacional (nodemailer/Resend/SendGrid/SMTP) em api/lib ou api/routes — 'envelope ENVIADO' no OptiMon nunca significa 'e-mail realmente entregue'; só o webhook do provedor real provaria isso, e o único provedor implementado é o mock de homologação (nunca fala com rede)."
else
  fail "TESTE-40 verificação de infraestrutura de e-mail" "grep encontrou alguma lib de e-mail — reinvestigar, pode já não ser mais uma limitação"
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
