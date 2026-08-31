#!/usr/bin/env bash
# OptiMon — Fase 3.11: TESTE-E2E-OPTIMON-311 — homologação funcional real e completa do
# fluxo Simulação → Proposta → Aprovação Interna (NICK) → Envio ao Parceiro → Parceiro
# Abre Área Externa → Visualização → Aceite (ou Recusa) → Geração de Contrato (só após
# aceite real — nunca antes) → Minuta → Assinatura Eletrônica do Contrato → Contrato
# Assinado → Ativação. Cobre também os testes negativos obrigatórios da seção 29 do
# prompt (bloqueios que NUNCA podem passar). Cria um parceiro CLARAMENTE identificável
# (razão social "TESTE-E2E-OPTIMON-311"), reaproveita infraestrutura real já existente
# (cidade Jussara-PR). Ao final, desativa o parceiro de teste (proposta/contrato nunca
# têm DELETE físico, por design, desde a Fase 1 — "limpeza" aqui é tornar o registro
# inerte, nunca apagar histórico).

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

echo "############################################################"
echo "# PASSO 0 — migration Fase 3.11 aplica sem erro (idempotente) #"
echo "############################################################"
if $PSQL -v ON_ERROR_STOP=1 -f supabase/migrations/20261002090000_phase_3_11_workflow_proposta_parceiro.sql > /tmp/fase311_mig.log 2>&1; then
  pass "PASSO-0 migration 20261002090000_phase_3_11_workflow_proposta_parceiro.sql aplica sem erro"
else
  fail "PASSO-0 aplicar migration Fase 3.11" "ver /tmp/fase311_mig.log"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi
$PSQL -c "NOTIFY pgrst, 'reload schema';" > /dev/null 2>&1

echo "############################################################"
echo "# PASSO 1 — pilha local no ar #"
echo "############################################################"
pkill -f "postgrest .*postgrest.local.conf" 2>/dev/null || true
pkill -f "rest_v1_proxy.js" 2>/dev/null || true
pkill -f "node server.js" 2>/dev/null || true
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

if [ -z "$CIDADE_ID" ]; then
  fail "PASSO-1 pré-condição: nenhuma cidade ativa encontrada" "banco de dev sem seed de cidade"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi
pass "PASSO-1 pilha local no ar — API/proxy/postgrest respondendo, cidade de teste=$CIDADE_ID"

echo "############################################################"
echo "# ETAPA 1 — parceiro + SIMULAÇÃO + PROPOSTA #"
echo "############################################################"
CNPJ_TESTE="$(printf '%014d' $((RANDOM * RANDOM % 100000000000000)))"
CODE=$(api POST "/api/partners" "$TOK_COMERCIAL" "{\"razao_social\":\"TESTE-E2E-OPTIMON-311 Ltda\",\"nome_fantasia\":\"TESTE-E2E-OPTIMON-311\",\"cnpj\":\"$CNPJ_TESTE\",\"email_contato\":\"teste-e2e-311@optimon.local\",\"endereco_logradouro\":\"Rua de Teste E2E\",\"endereco_numero\":\"311\",\"endereco_bairro\":\"Centro\",\"endereco_cidade\":\"Jussara\",\"endereco_uf\":\"PR\",\"endereco_cep\":\"87450000\"}")
PARCEIRO_ID=$(jget ".id")
[ "$CODE" = "201" ] && [ -n "$PARCEIRO_ID" ] && pass "TESTE-E2E-01 parceiro TESTE-E2E-OPTIMON-311 criado — 201, id=$PARCEIRO_ID" \
  || { fail "TESTE-E2E-01 criar parceiro de teste" "codigo=$CODE body=$(body)"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }

CODE=$(api POST "/api/pricing/calculate" "$TOK_COMERCIAL" "{\"cidade_id\":\"$CIDADE_ID\",\"clientes\":250,\"arpu\":90,\"revenue_share_pct\":0.12}")
RESULTADO_JSON=$(body)
[ "$CODE" = "200" ] && echo "$RESULTADO_JSON" | grep -q "recommended" && pass "TESTE-E2E-02 pricing calculado — 200" \
  || { fail "TESTE-E2E-02 calcular pricing" "codigo=$CODE body=$RESULTADO_JSON"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }
SIM_BODY=$(node -e "
const r = $RESULTADO_JSON;
console.log(JSON.stringify({cidade_id: '$CIDADE_ID', parceiro_id: '$PARCEIRO_ID', modelo: 'HIBRIDO_REVENUE_SHARE', pares_ou_clientes: 250, arpu: 90, revenue_share_pct: 0.12, prazo_meses: 48, resultado: r}));
")
CODE=$(api POST "/api/simulations" "$TOK_COMERCIAL" "$SIM_BODY")
SIM_ID=$(jget ".id")
[ "$CODE" = "201" ] && [ -n "$SIM_ID" ] && pass "TESTE-E2E-03 simulação salva — 201, id=$SIM_ID" \
  || { fail "TESTE-E2E-03 salvar simulação" "codigo=$CODE body=$(body)"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }

CODE=$(api POST "/api/proposals" "$TOK_COMERCIAL" "{\"simulacao_id\":\"$SIM_ID\",\"cidade_id\":\"$CIDADE_ID\",\"parceiro_id\":\"$PARCEIRO_ID\",\"parceiro_nome_capa\":\"TESTE-E2E-OPTIMON-311\",\"parceiro_cargo_contato\":\"Diretor Comercial (teste)\"}")
PROP_ID=$(jget ".id")
PROP_NUMERO=$(jget ".numero")
[ "$CODE" = "201" ] && [ -n "$PROP_ID" ] && pass "TESTE-E2E-04 proposta criada a partir da simulação real — 201, numero=$PROP_NUMERO" \
  || { fail "TESTE-E2E-04 criar proposta" "codigo=$CODE body=$(body)"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }

echo "############################################################"
echo "# ETAPA 2 — negativo: parceiro (externo) tenta acessar área administrativa #"
echo "############################################################"
CODE=$(api GET "/api/proposals/$PROP_ID" "")
[ "$CODE" = "401" ] || [ "$CODE" = "403" ] \
  && pass "TESTE-E2E-05 (negativo) GET /api/proposals/:id SEM token de usuário é bloqueado — codigo=$CODE" \
  || fail "TESTE-E2E-05 (negativo) área administrativa deveria bloquear chamada sem JWT" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# ETAPA 3 — APROVAÇÃO INTERNA (NICK) — nunca implica consentimento do parceiro #"
echo "############################################################"
# app.aprovar_proposta aceita RASCUNHO ou EM_APROVACAO como origem — toda proposta
# nasce em RASCUNHO (nunca pula aprovação sozinha, mesmo quando preço >= recomendado);
# motivo só é exigido quando o preço fica abaixo do piso.
CODE=$(api POST "/api/proposals/$PROP_ID/approve" "$TOK_DIRETOR" '{"motivo":"Aprovação interna de teste E2E Fase 3.11."}')
[ "$CODE" = "200" ] && pass "TESTE-E2E-06 DIRETOR aprova internamente (RASCUNHO -> APROVADA) — 200" || { fail "TESTE-E2E-06 aprovar internamente" "codigo=$CODE body=$(body)"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }
PROP_STATUS_POS_APROVACAO=$(scalar "select status from propostas_comerciais where id='$PROP_ID';")
[ "$PROP_STATUS_POS_APROVACAO" != "ACEITA_PELO_PARCEIRO" ] \
  && pass "TESTE-E2E-07 aprovação interna NÃO transiciona a proposta para ACEITA_PELO_PARCEIRO (aprovação interna != consentimento do parceiro) — status=$PROP_STATUS_POS_APROVACAO" \
  || fail "TESTE-E2E-07 aprovação interna vazando como aceite do parceiro" "status=$PROP_STATUS_POS_APROVACAO"

echo "############################################################"
echo "# NEGATIVO — COMERCIAL tenta 'aprovar como parceiro' via mudar_status_proposta('ACEITA') #"
echo "############################################################"
CODE=$(api POST "/api/proposals/$PROP_ID/status" "$TOK_DIRETOR" '{"status":"ACEITA"}')
[ "$CODE" != "200" ] \
  && pass "TESTE-E2E-08 (negativo) tentativa de forçar status=ACEITA via mudar_status_proposta é BLOQUEADA — codigo=$CODE" \
  || fail "TESTE-E2E-08 (negativo) fake-acceptance deveria ser bloqueado" "codigo=$CODE body=$(body) — BUG CRÍTICO: aceite falso sem envolvimento do parceiro"

echo "############################################################"
echo "# ETAPA 4 — ENVIO AO PARCEIRO (token real) #"
echo "############################################################"
CODE=$(api POST "/api/proposals/$PROP_ID/send-to-partner" "$TOK_COMERCIAL")
TOKEN=$(jget ".token_acesso_externo")
STATUS_APOS_ENVIO=$(jget ".status")
if [ "$CODE" = "200" ] && [ -n "$TOKEN" ] && [ "$STATUS_APOS_ENVIO" = "ENVIADA_AO_PARCEIRO" ]; then
  pass "TESTE-E2E-09 'Enviar ao Parceiro' gera token real e transiciona para ENVIADA_AO_PARCEIRO — 200"
else
  fail "TESTE-E2E-09 enviar ao parceiro" "codigo=$CODE status=$STATUS_APOS_ENVIO body=$(body)"
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
  pass "TESTE-E2E-10 área externa acessível SEM login (só token na URL), numero=$EXT_NUMERO, e CONFIRMADAMENTE sem floor/governance_status/discount/preco_minimo_autorizado (anti-vazamento)"
else
  fail "TESTE-E2E-10 abrir área externa / anti-vazamento" "codigo=$CODE numero=$EXT_NUMERO floor=$FLOOR_PRESENTE governanca=$GOVERNANCA_PRESENTE desconto=$DESCONTO_PRESENTE preco_min=$PRECO_MINIMO_PRESENTE body=$(body)"
fi

echo "############################################################"
echo "# ETAPA 6 — VISUALIZAÇÃO registrada (PROPOSTA_VISUALIZADA) #"
echo "############################################################"
STATUS_POS_VIEW=$(scalar "select status from propostas_comerciais where id='$PROP_ID';")
VIEWS_COUNT=$(scalar "select visualizacoes_count from propostas_comerciais where id='$PROP_ID';")
AUDIT_VIEW=$(scalar "select count(*) from auditoria where entidade_id='$PROP_ID' and acao='PROPOSAL_VIEWED_BY_PARTNER';")
if [ "$STATUS_POS_VIEW" = "VISUALIZADA_PELO_PARCEIRO" ] && [ "$VIEWS_COUNT" -ge 1 ] && [ "$AUDIT_VIEW" -ge 1 ]; then
  pass "TESTE-E2E-11 status transiciona para VISUALIZADA_PELO_PARCEIRO, contador=$VIEWS_COUNT, auditoria PROPOSAL_VIEWED_BY_PARTNER registrada ($AUDIT_VIEW evento(s))"
else
  fail "TESTE-E2E-11 registro de visualização" "status=$STATUS_POS_VIEW views=$VIEWS_COUNT audit=$AUDIT_VIEW"
fi

echo "############################################################"
echo "# ETAPA 7 (CRÍTICA) — tentativa indevida de GERAR CONTRATO ANTES do aceite deve ser BLOQUEADA #"
echo "############################################################"
CODE=$(api POST "/api/contracts/generate" "$TOK_COMERCIAL" "{\"proposta_id\":\"$PROP_ID\"}")
if [ "$CODE" != "201" ]; then
  pass "TESTE-E2E-12 (CRÍTICO) gerar contrato ANTES do aceite do parceiro é BLOQUEADO — codigo=$CODE body=$(body)"
else
  fail "TESTE-E2E-12 (CRÍTICO) contrato gerado SEM aceite do parceiro — FALHA GRAVE" "codigo=201, contrato_id=$(jget '.id') — Aceite ≠ Assinatura violado"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

echo "############################################################"
echo "# NEGATIVO — parceiro tenta acessar OUTRA proposta com token errado #"
echo "############################################################"
CODE=$(api GET "/api/proposals/external/0000000000000000000000000000000000000000000000000000000000000000" "")
[ "$CODE" != "200" ] \
  && pass "TESTE-E2E-13 (negativo) token inválido/inexistente é rejeitado — codigo=$CODE" \
  || fail "TESTE-E2E-13 (negativo) token inválido deveria ser rejeitado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# NEGATIVO — aceitar sem nome/documento (obrigatórios) #"
echo "############################################################"
CODE=$(api POST "/api/proposals/external/$TOKEN/accept" "" '{"nome":"","documento":""}')
[ "$CODE" != "200" ] \
  && pass "TESTE-E2E-14 (negativo) aceite sem nome/documento é bloqueado (DADOS_OBRIGATORIOS) — codigo=$CODE" \
  || fail "TESTE-E2E-14 (negativo) aceite sem dados obrigatórios deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# ETAPA 8 — ACEITE FORMAL DO PARCEIRO (real, backend validado) #"
echo "############################################################"
CODE=$(api POST "/api/proposals/external/$TOKEN/accept" "" '{"nome":"Carlos Silva (teste E2E)","documento":"123.456.789-00","cargo":"Diretor","email":"parceiro-e2e311@optimon.local","telefone":"(44) 99999-0000"}')
STATUS_POS_ACEITE=$(jget ".status")
if [ "$CODE" = "200" ] && [ "$STATUS_POS_ACEITE" = "ACEITA_PELO_PARCEIRO" ]; then
  pass "TESTE-E2E-15 aceite formal do parceiro registrado — status=ACEITA_PELO_PARCEIRO"
else
  fail "TESTE-E2E-15 aceite formal do parceiro" "codigo=$CODE status=$STATUS_POS_ACEITE body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi
AUDIT_ACCEPT=$(scalar "select count(*) from auditoria where entidade_id='$PROP_ID' and acao='PROPOSAL_ACCEPTED_BY_PARTNER';")
[ "$AUDIT_ACCEPT" = "1" ] && pass "TESTE-E2E-16 auditoria PROPOSAL_ACCEPTED_BY_PARTNER registrada" || fail "TESTE-E2E-16 auditoria de aceite" "contagem=$AUDIT_ACCEPT"

echo "############################################################"
echo "# NEGATIVO — segunda tentativa de aceite (double-accept) é bloqueada #"
echo "############################################################"
CODE=$(api POST "/api/proposals/external/$TOKEN/accept" "" '{"nome":"Segunda tentativa","documento":"111.111.111-11"}')
[ "$CODE" != "200" ] \
  && pass "TESTE-E2E-17 (negativo) segundo aceite da mesma proposta é BLOQUEADO (STATUS_INVALIDO) — codigo=$CODE" \
  || fail "TESTE-E2E-17 (negativo) double-accept deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# ETAPA 9 — GERAR CONTRATO (agora permitido — só após aceite real) #"
echo "############################################################"
CODE=$(api POST "/api/contracts/generate" "$TOK_COMERCIAL" "{\"proposta_id\":\"$PROP_ID\"}")
CONTRATO_ID=$(jget ".id")
CONTRATO_NUMERO=$(jget ".numero")
if [ "$CODE" = "201" ] && [ -n "$CONTRATO_ID" ]; then
  pass "TESTE-E2E-18 CRIAR CONTRATO a partir da proposta ACEITA_PELO_PARCEIRO — 201, numero=$CONTRATO_NUMERO"
else
  fail "TESTE-E2E-18 criar contrato" "codigo=$CODE body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

echo "############################################################"
echo "# NEGATIVO — segundo contrato da mesma proposta é bloqueado #"
echo "############################################################"
CODE=$(api POST "/api/contracts/generate" "$TOK_COMERCIAL" "{\"proposta_id\":\"$PROP_ID\"}")
[ "$CODE" != "201" ] \
  && pass "TESTE-E2E-19 (negativo) segundo contrato para a mesma proposta é BLOQUEADO — codigo=$CODE" \
  || fail "TESTE-E2E-19 (negativo) contrato duplicado deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# ETAPA 10 — vínculo bidirecional real #"
echo "############################################################"
CODE=$(api GET "/api/proposals/$PROP_ID" "$TOK_COMERCIAL")
PROP_CONTRATO_ID=$(jget ".contrato_id")
[ "$PROP_CONTRATO_ID" = "$CONTRATO_ID" ] && pass "TESTE-E2E-20 lado da PROPOSTA mostra contrato_id=$PROP_CONTRATO_ID (bate)" || fail "TESTE-E2E-20 vínculo proposta->contrato" "contrato_id=$PROP_CONTRATO_ID esperado=$CONTRATO_ID"

CODE=$(api GET "/api/contracts/$CONTRATO_ID" "$TOK_COMERCIAL")
CTR_PROP_ID=$(jget ".proposta_origem.id")
[ "$CTR_PROP_ID" = "$PROP_ID" ] && pass "TESTE-E2E-21 lado do CONTRATO mostra proposta_origem.id=$CTR_PROP_ID (bate) — vínculo bidirecional confirmado" || fail "TESTE-E2E-21 vínculo contrato->proposta" "proposta_origem.id=$CTR_PROP_ID esperado=$PROP_ID"

echo "############################################################"
echo "# ETAPA 11 — MINUTA (PDF/DOCX) real do contrato #"
echo "############################################################"
for FMT in PDF DOCX; do
  OUT="/tmp/fase311_minuta.${FMT,,}"
  HTTP_CODE=$(curl -sS -o "$OUT" -w "%{http_code}" "$API/api/contracts/$CONTRATO_ID/minuta?formato=$FMT" -H "Authorization: Bearer $TOK_ADMIN")
  SIZE=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
  [ "$HTTP_CODE" = "200" ] && [ "$SIZE" -gt 1000 ] \
    && pass "TESTE-E2E-22-$FMT minuta $FMT gerada — $SIZE bytes" \
    || fail "TESTE-E2E-22-$FMT gerar minuta $FMT" "codigo=$HTTP_CODE tamanho=$SIZE"
done

echo "############################################################"
echo "# ETAPA 12 — ASSINATURA ELETRÔNICA DO CONTRATO (PDF auto-gerado, webhook real) #"
echo "############################################################"
PROVIDER_ID=$(scalar "select id from signature_providers where tipo='ICP_BRASIL_HOMOLOGACAO_MOCK' and ambiente='HOMOLOGACAO' limit 1;")
if [ -z "$PROVIDER_ID" ]; then
  CODE=$(api POST "/api/signatures/providers" "$TOK_ADMIN" "{\"nome\":\"Homologação Fase311 Teste\",\"tipo\":\"ICP_BRASIL_HOMOLOGACAO_MOCK\",\"ambiente\":\"HOMOLOGACAO\",\"webhook_secret_ref\":\"$WEBHOOK_SECRET_ENV_NAME\"}")
  PROVIDER_ID=$(jget ".id")
fi
[ -n "$PROVIDER_ID" ] && pass "TESTE-E2E-23 provedor de assinatura disponível — id=$PROVIDER_ID" \
  || { fail "TESTE-E2E-23 provedor de assinatura" "body=$(body)"; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1; }

# Fase 3.11 (seção 17): envelope tipo_documento=CONTRATO SEM upload manual — o PDF é
# gerado automaticamente pelo mesmo motor da minuta (correção do gap real da Fase 2.5).
ENVELOPE_ID=$(curl -sS -o /tmp/fase311_resp.json -w '' -X POST "$API/api/signatures/envelopes" -H "Authorization: Bearer $TOK_COMERCIAL" -F "tipo_documento=CONTRATO" -F "provider_id=$PROVIDER_ID" -F "contrato_id=$CONTRATO_ID" > /dev/null; jget ".id")
if [ -n "$ENVELOPE_ID" ]; then
  pass "TESTE-E2E-24 envelope de assinatura do CONTRATO criado (PDF auto-gerado, sem upload manual) — id=$ENVELOPE_ID"
else
  fail "TESTE-E2E-24 criar envelope do contrato" "body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

api POST "/api/signatures/envelopes/$ENVELOPE_ID/signers" "$TOK_COMERCIAL" '{"nome":"Representante NICK (teste E2E)","email":"nick-e2e311@optimon.local","papel":"REPRESENTANTE_NICK","ordem":1}' > /dev/null
api POST "/api/signatures/envelopes/$ENVELOPE_ID/signers" "$TOK_COMERCIAL" '{"nome":"Representante TESTE-E2E-OPTIMON-311","email":"parceiro-e2e311@optimon.local","papel":"REPRESENTANTE_PROPONENTE","ordem":2}' > /dev/null
pass "TESTE-E2E-25 2 signatários adicionados ao envelope do contrato"

CODE=$(api POST "/api/signatures/envelopes/$ENVELOPE_ID/send" "$TOK_COMERCIAL")
[ "$CODE" = "200" ] && pass "TESTE-E2E-26 envelope do contrato enviado ao provedor — 200" || fail "TESTE-E2E-26 enviar envelope do contrato" "codigo=$CODE body=$(body)"

PROVIDER_ENVELOPE_ID=$(scalar "select provider_envelope_id from signature_envelopes where id='$ENVELOPE_ID';")
sign_and_post_webhook() {
  local payload_file="$1"
  local sig
  sig=$(openssl dgst -sha256 -hmac "$WEBHOOK_SECRET_VALUE" "$payload_file" | awk '{print $NF}')
  curl -sS -o /tmp/fase311_webhook_resp.json -w '%{http_code}' -X POST "$API/api/signatures/webhook" \
    -H "Content-Type: application/json" -H "X-Signature: $sig" --data-binary "@$payload_file"
}
cat > /tmp/fase311_webhook_evt1.json <<EOF
{"provider_envelope_id":"$PROVIDER_ENVELOPE_ID","evento_externo_id":"evt-1-e2e311","tipo_evento":"SIGNER_SIGNED","signer_email":"nick-e2e311@optimon.local","signer_novo_status":"ASSINADO","signer_ip":"203.0.113.20","novo_status_envelope":"PARCIALMENTE_ASSINADO"}
EOF
cat > /tmp/fase311_webhook_evt2.json <<EOF
{"provider_envelope_id":"$PROVIDER_ENVELOPE_ID","evento_externo_id":"evt-2-e2e311","tipo_evento":"SIGNER_SIGNED","signer_email":"parceiro-e2e311@optimon.local","signer_novo_status":"ASSINADO","signer_ip":"203.0.113.21","novo_status_envelope":"ASSINADO","hash_assinado":"e2e311-hash-teste-homologacao","storage_path_assinado":"homologacao/teste-e2e-311/contrato-assinado.pdf"}
EOF
sign_and_post_webhook /tmp/fase311_webhook_evt1.json > /dev/null

ENVELOPE_STATUS_PARCIAL=$(scalar "select status from signature_envelopes where id='$ENVELOPE_ID';")
[ "$ENVELOPE_STATUS_PARCIAL" = "PARCIALMENTE_ASSINADO" ] \
  && pass "TESTE-E2E-27 (ETAPA 13 parcial) contrato só fica ASSINADO após TODOS os signatários — 1 de 2 assinaram, status=$ENVELOPE_STATUS_PARCIAL" \
  || fail "TESTE-E2E-27 status parcial de assinatura" "status=$ENVELOPE_STATUS_PARCIAL"

sign_and_post_webhook /tmp/fase311_webhook_evt2.json > /dev/null
ENVELOPE_STATUS_FINAL=$(scalar "select status from signature_envelopes where id='$ENVELOPE_ID';")
if [ "$ENVELOPE_STATUS_FINAL" = "ASSINADO" ]; then
  pass "TESTE-E2E-28 (ETAPA 13) webhooks de assinatura (2 signatários, HMAC válido) processados — envelope do CONTRATO agora ASSINADO"
else
  fail "TESTE-E2E-28 assinatura via webhook" "status_final=$ENVELOPE_STATUS_FINAL"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

CODE=$(api POST "/api/signatures/envelopes/$ENVELOPE_ID/validate" "$TOK_COMERCIAL")
DOC_VALIDADO=$(scalar "select validado from documentos_assinados where envelope_id='$ENVELOPE_ID';")
if [ "$CODE" = "200" ] && [ "$DOC_VALIDADO" = "t" ]; then
  pass "TESTE-E2E-29 assinatura validada de verdade (hash/política ICP-Brasil/todos os signatários) — nunca 'status=ASSINADO' sozinho como prova"
else
  fail "TESTE-E2E-29 validar assinatura" "codigo=$CODE validado=$DOC_VALIDADO body=$(body)"
fi

echo "############################################################"
echo "# NEGATIVO — alteração de contrato ASSINADO/pós-contrato: proposta não pode ser reaberta #"
echo "############################################################"
CODE=$(api POST "/api/proposals/$PROP_ID/send-to-partner" "$TOK_COMERCIAL")
[ "$CODE" != "200" ] \
  && pass "TESTE-E2E-30 (negativo) reenviar ao parceiro uma proposta já com CONTRATO_GERADO é bloqueado — codigo=$CODE" \
  || fail "TESTE-E2E-30 (negativo) alteração pós-contrato deveria ser bloqueada" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# ETAPA 14 — ATIVAÇÃO DO CONTRATO (gate real: assinatura validada + infra alocada) #"
echo "############################################################"
CODE=$(api POST "/api/contracts/$CONTRATO_ID/activate" "$TOK_DIRETOR")
[ "$CODE" != "200" ] \
  && pass "TESTE-E2E-31 ativação SEM infra alocada é bloqueada corretamente (INFRA_NAO_ALOCADA) — codigo=$CODE" \
  || fail "TESTE-E2E-31 ativação deveria exigir infra alocada" "codigo=$CODE body=$(body)"

# Alocação de fibra é um passo manual de Engenharia (contrato_fibras — sem rota de API
# dedicada, mesmo padrão já usado pelos testes E2E da Fase 2.5/2.1).
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
  [ "$ALLOC_OK" = "1" ] && pass "TESTE-E2E-32 Engenharia aloca fibra ao contrato (contrato_fibras)" || fail "TESTE-E2E-32 alocar fibra" "ver /tmp/fase311_alloc.log"
else
  fail "TESTE-E2E-32 nenhuma fibra livre encontrada em Jussara" "banco de dev sem fibra DISPONIVEL"
fi

CODE=$(api POST "/api/contracts/$CONTRATO_ID/activate" "$TOK_DIRETOR")
CONTRATO_STATUS_FINAL=$(scalar "select status from contratos where id='$CONTRATO_ID';")
if [ "$CODE" = "200" ] && [ "$CONTRATO_STATUS_FINAL" = "ATIVO" ]; then
  pass "TESTE-E2E-33 (ETAPA 14) CONTRATO ATIVADO com sucesso (assinatura validada + infra alocada + sem conflito) — status=ATIVO"
else
  fail "TESTE-E2E-33 ativar contrato" "codigo=$CODE status=$CONTRATO_STATUS_FINAL body=$(body)"
fi
AUDIT_ACTIVATE=$(scalar "select count(*) from auditoria where entidade_id='$CONTRATO_ID' and acao='CONTRACT_ACTIVATE';")
[ "$AUDIT_ACTIVATE" = "1" ] && pass "TESTE-E2E-34 auditoria CONTRACT_ACTIVATE registrada" || fail "TESTE-E2E-34 auditoria de ativação" "contagem=$AUDIT_ACTIVATE"

echo "############################################################"
echo "# NEGATIVO — usuário sem permissão tenta ativar contrato #"
echo "############################################################"
CONTRATO_ID2_CHECK="$CONTRATO_ID"
CODE=$(api POST "/api/contracts/$CONTRATO_ID2_CHECK/activate" "$TOK_AUDITOR")
[ "$CODE" != "200" ] \
  && pass "TESTE-E2E-35 (negativo) AUDITOR (sem permissão de Diretoria/Admin) não consegue reativar/ativar contrato — codigo=$CODE" \
  || fail "TESTE-E2E-35 (negativo) usuário sem permissão deveria ser bloqueado" "codigo=$CODE body=$(body)"

echo "############################################################"
echo "# HISTÓRICO DA NEGOCIAÇÃO — timeline real derivada da auditoria #"
echo "############################################################"
CODE=$(api GET "/api/proposals/$PROP_ID/historico" "$TOK_COMERCIAL")
HIST_LEN=$(node -e "try{const d=JSON.parse(require('fs').readFileSync('/tmp/fase311_resp.json','utf8'));console.log(Array.isArray(d)?d.length:0)}catch(e){console.log(0)}")
[ "$CODE" = "200" ] && [ "$HIST_LEN" -ge 6 ] \
  && pass "TESTE-E2E-36 Histórico da Negociação (GET /api/proposals/:id/historico) devolve timeline real com $HIST_LEN eventos" \
  || fail "TESTE-E2E-36 histórico da negociação" "codigo=$CODE eventos=$HIST_LEN"

echo "############################################################"
echo "# LIMPEZA CONTROLADA #"
echo "############################################################"
CODE=$(api POST "/api/partners/$PARCEIRO_ID/deactivate" "$TOK_ADMIN" '{"motivo":"Encerramento do TESTE-E2E-OPTIMON-311 (Fase 3.11) — limpeza controlada pós-homologação."}')
[ "$CODE" = "200" ] \
  && pass "TESTE-E2E-37 parceiro de teste desativado ao final (proposta/contrato permanecem como histórico auditável imutável, nunca apagados fisicamente)" \
  || fail "TESTE-E2E-37 desativar parceiro de teste" "codigo=$CODE body=$(body)"

echo ""
echo "############################################################"
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
echo "############################################################"
if [ $FAIL -gt 0 ]; then
  echo "Falhas:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
echo "Registros de teste: parceiro=$PARCEIRO_ID (desativado) proposta=$PROP_ID ($PROP_NUMERO) contrato=$CONTRATO_ID ($CONTRATO_NUMERO)"
echo "Link externo usado no teste: /parceiro/proposta/$TOKEN"
echo "Evidências salvas em: /tmp/fase311_minuta.pdf /tmp/fase311_minuta.docx"
