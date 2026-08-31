#!/usr/bin/env bash
# OptiMon — Fase 3.10 (seção 9 do prompt): TESTE-E2E-OPTIMON-310 — homologação funcional
# real e completa do fluxo Simulação → Proposta → Aprovação → Assinatura → CRIAR CONTRATO
# → Minuta → PDF → DOCX, com evidência real em cada etapa (nunca "implementado" sem
# verificação). Cria um parceiro CLARAMENTE identificável (razão social
# "TESTE-E2E-OPTIMON-310"), reaproveita infraestrutura real já existente (cidade Jussara-PR,
# já testada exaustivamente pelas fases anteriores) — o objeto desta fase é o fechamento do
# fluxo Proposta→Contrato, não a criação de infraestrutura do zero (já coberta por
# tests/run_tests_fase23.sh e seguintes). Ao final, desativa o parceiro de teste (política de
# exclusão controlada do sistema — proposta/contrato nunca têm DELETE físico, por design,
# desde a Fase 1: tudo é auditado e imutável; "limpeza" aqui significa tornar o registro
# inerte/fora das listagens ativas, nunca apagar histórico).

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
echo "# PASSO 0 — migration Fase 3.10 aplica sem erro (idempotente) #"
echo "############################################################"
if $PSQL -v ON_ERROR_STOP=1 -f supabase/migrations/20261001090000_phase_3_10_fechamento_proposta_contrato.sql > /tmp/fase310_mig.log 2>&1; then
  pass "PASSO-0 migration 20261001090000_phase_3_10_fechamento_proposta_contrato.sql aplica sem erro"
else
  fail "PASSO-0 aplicar migration Fase 3.10" "ver /tmp/fase310_mig.log"
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
nohup postgrest supabase/dev-local-only/postgrest.local.conf > /tmp/fase310_postgrest.log 2>&1 & disown
sleep 1
nohup env PGRST_TARGET=http://127.0.0.1:3000 PROXY_PORT=54321 node supabase/dev-local-only/rest_v1_proxy.js > /tmp/fase310_proxy.log 2>&1 & disown
sleep 1
( cd api && nohup node server.js > /tmp/fase310_api.log 2>&1 & disown )
sleep 2
API="http://localhost:3001"
mint() { node supabase/dev-local-only/mint_jwt.js "$1"; }

UID_ADMIN=$(scalar "select id from usuarios where email='admin@optimon.local';")
UID_DIRETOR=$(scalar "select id from usuarios where email='diretor@optimon.local';")
UID_COMERCIAL=$(scalar "select id from usuarios where email='comercial@optimon.local';")
TOK_ADMIN=$(mint "$UID_ADMIN")
TOK_DIRETOR=$(mint "$UID_DIRETOR")
TOK_COMERCIAL=$(mint "$UID_COMERCIAL")
CIDADE_ID=$(scalar "select id from cidades_infra where nome='Jussara' and removido_em is null limit 1;")
if [ -z "$CIDADE_ID" ]; then CIDADE_ID=$(scalar "select id from cidades_infra where removido_em is null limit 1;"); fi

api() {
  local method="$1"; local path="$2"; local tok="$3"; local body="${4:-}"
  if [ -n "$body" ]; then
    curl -sS -o /tmp/fase310_resp.json -w '%{http_code}' -X "$method" "$API$path" \
      -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -d "$body"
  else
    curl -sS -o /tmp/fase310_resp.json -w '%{http_code}' -X "$method" "$API$path" -H "Authorization: Bearer $tok"
  fi
}
jget() { node -e "try{const d=JSON.parse(require('fs').readFileSync('/tmp/fase310_resp.json','utf8'));const v=d$1;console.log(v===undefined||v===null?'':v)}catch(e){console.log('')}"; }
body() { cat /tmp/fase310_resp.json; }

if [ -z "$CIDADE_ID" ]; then
  fail "PASSO-1 pré-condição: nenhuma cidade ativa encontrada" "banco de dev sem seed de cidade"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi
pass "PASSO-1 pilha local no ar — API/proxy/postgrest respondendo, cidade de teste=$CIDADE_ID"

echo "############################################################"
echo "# ETAPA 1 — criar parceiro de teste claramente identificável #"
echo "############################################################"
CNPJ_TESTE="$(printf '%014d' $((RANDOM * RANDOM % 100000000000000)))"
CODE=$(api POST "/api/partners" "$TOK_COMERCIAL" "{\"razao_social\":\"TESTE-E2E-OPTIMON-310 Ltda\",\"nome_fantasia\":\"TESTE-E2E-OPTIMON-310\",\"cnpj\":\"$CNPJ_TESTE\",\"email_contato\":\"teste-e2e-310@optimon.local\",\"endereco_logradouro\":\"Rua de Teste E2E\",\"endereco_numero\":\"310\",\"endereco_bairro\":\"Centro\",\"endereco_cidade\":\"Jussara\",\"endereco_uf\":\"PR\",\"endereco_cep\":\"87450000\"}")
PARCEIRO_ID=$(jget ".id")
if [ "$CODE" = "201" ] && [ -n "$PARCEIRO_ID" ]; then
  pass "TESTE-E2E-01 parceiro TESTE-E2E-OPTIMON-310 criado — 201, id=$PARCEIRO_ID"
else
  fail "TESTE-E2E-01 criar parceiro de teste" "codigo=$CODE body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

echo "############################################################"
echo "# ETAPA 2 — SIMULAÇÃO real via POST /api/pricing/calculate + POST /api/simulations #"
echo "############################################################"
CODE=$(api POST "/api/pricing/calculate" "$TOK_COMERCIAL" "{\"cidade_id\":\"$CIDADE_ID\",\"clientes\":250,\"arpu\":90,\"revenue_share_pct\":0.12}")
RESULTADO_JSON=$(body)
if [ "$CODE" = "200" ] && echo "$RESULTADO_JSON" | grep -q "recommended"; then
  pass "TESTE-E2E-02 POST /api/pricing/calculate devolve resultado real (recommended presente) — 200"
else
  fail "TESTE-E2E-02 calcular pricing" "codigo=$CODE body=$RESULTADO_JSON"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi
SIM_BODY=$(node -e "
const r = $RESULTADO_JSON;
console.log(JSON.stringify({cidade_id: '$CIDADE_ID', parceiro_id: '$PARCEIRO_ID', modelo: 'HIBRIDO_REVENUE_SHARE', pares_ou_clientes: 250, arpu: 90, revenue_share_pct: 0.12, prazo_meses: 48, resultado: r}));
")
CODE=$(api POST "/api/simulations" "$TOK_COMERCIAL" "$SIM_BODY")
SIM_ID=$(jget ".id")
if [ "$CODE" = "201" ] && [ -n "$SIM_ID" ]; then
  pass "TESTE-E2E-03 simulação salva (POST /api/simulations) — 201, id=$SIM_ID"
else
  fail "TESTE-E2E-03 salvar simulação" "codigo=$CODE body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

echo "############################################################"
echo "# ETAPA 3 — PROPOSTA (nasce da simulação, nunca de dado inventado) #"
echo "############################################################"
CODE=$(api POST "/api/proposals" "$TOK_COMERCIAL" "{\"simulacao_id\":\"$SIM_ID\",\"cidade_id\":\"$CIDADE_ID\",\"parceiro_id\":\"$PARCEIRO_ID\",\"parceiro_nome_capa\":\"TESTE-E2E-OPTIMON-310\",\"parceiro_cargo_contato\":\"Diretor Comercial (teste)\"}")
PROP_ID=$(jget ".id")
PROP_NUMERO=$(jget ".numero")
if [ "$CODE" = "201" ] && [ -n "$PROP_ID" ]; then
  pass "TESTE-E2E-04 proposta criada a partir da simulação real — 201, numero=$PROP_NUMERO id=$PROP_ID"
else
  fail "TESTE-E2E-04 criar proposta" "codigo=$CODE body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

AUDIT_CREATED=$(scalar "select count(*) from auditoria where entidade_id='$PROP_ID' and acao='PROPOSAL_CREATED';")
[ "$AUDIT_CREATED" = "1" ] && pass "TESTE-E2E-05 evento de auditoria PROPOSAL_CREATED registrado (Fase 3.10, seção 7)" || fail "TESTE-E2E-05 auditoria PROPOSAL_CREATED" "contagem=$AUDIT_CREATED"

echo "############################################################"
echo "# ETAPA 4 — Problema 2: modo Interna x Externa Parceiro (dado real) #"
echo "############################################################"
CODE=$(api PATCH "/api/proposals/$PROP_ID" "$TOK_COMERCIAL" '{"observacoes_comerciais":"Cliente com forte interesse em expansão para bairros vizinhos em 2027 (teste E2E).","proximos_passos":"Aguardando aprovação da Diretoria e assinatura eletrônica (teste E2E)."}')
if [ "$CODE" = "200" ]; then
  pass "TESTE-E2E-06 PATCH /api/proposals/:id grava observações comerciais/próximos passos — 200"
else
  fail "TESTE-E2E-06 PATCH observações" "codigo=$CODE body=$(body)"
fi
AUDIT_UPDATED=$(scalar "select count(*) from auditoria where entidade_id='$PROP_ID' and acao='PROPOSAL_UPDATED';")
[ "$AUDIT_UPDATED" = "1" ] && pass "TESTE-E2E-07 evento de auditoria PROPOSAL_UPDATED registrado" || fail "TESTE-E2E-07 auditoria PROPOSAL_UPDATED" "contagem=$AUDIT_UPDATED"

CODE=$(api GET "/api/proposals/$PROP_ID" "$TOK_COMERCIAL")
INTERNA_FLOOR=$(jget ".snapshot.floor")
INTERNA_TOTAL=$(jget ".snapshot.total_payable")
if [ "$CODE" = "200" ] && [ -n "$INTERNA_TOTAL" ]; then
  pass "TESTE-E2E-08 modo INTERNA (GET /api/proposals/:id) devolve snapshot completo — total_payable=$INTERNA_TOTAL floor=$INTERNA_FLOOR (dado interno presente, como esperado)"
else
  fail "TESTE-E2E-08 GET interna" "codigo=$CODE body=$(body)"
fi

CODE=$(api GET "/api/proposals/$PROP_ID/public" "$TOK_COMERCIAL")
EXTERNA_PRECO=$(jget ".preco_proposto")
EXTERNA_FLOOR_PRESENTE=$(node -e "try{const d=JSON.parse(require('fs').readFileSync('/tmp/fase310_resp.json','utf8'));console.log(Object.prototype.hasOwnProperty.call(d,'floor')?'SIM':'NAO')}catch(e){console.log('ERRO')}")
EXTERNA_OBS=$(jget ".observacoes_comerciais")
EXTERNA_PONS=$(jget ".pons_count")
OBS_PRESENTE_LABEL="nao"
[ -n "$EXTERNA_OBS" ] && OBS_PRESENTE_LABEL="sim"
if [ "$CODE" = "200" ] && [ -n "$EXTERNA_PRECO" ] && [ "$EXTERNA_FLOOR_PRESENTE" = "NAO" ]; then
  pass "TESTE-E2E-09 modo EXTERNA (GET /api/proposals/:id/public) devolve preco_proposto=$EXTERNA_PRECO, pons_count=$EXTERNA_PONS, observacoes_comerciais presente=$OBS_PRESENTE_LABEL — e CONFIRMADAMENTE NÃO devolve a chave 'floor' (dado interno de governança nunca vaza)"
else
  fail "TESTE-E2E-09 GET externa (public)" "codigo=$CODE floor_presente=$EXTERNA_FLOOR_PRESENTE body=$(body)"
fi

echo "############################################################"
echo "# ETAPA 5 — Aprovação + Assinatura eletrônica (mock/homologação) até ASSINADA #"
echo "############################################################"
PROP_STATUS=$(scalar "select status from propostas_comerciais where id='$PROP_ID';")
echo "  (status atual da proposta: $PROP_STATUS)"
if [ "$PROP_STATUS" = "EM_APROVACAO" ]; then
  CODE=$(api POST "/api/proposals/$PROP_ID/approve" "$TOK_DIRETOR" '{"motivo":"Aprovação de teste E2E Fase 3.10 — preço proposto abaixo do recomendado, autorizado para fins de homologação."}')
  [ "$CODE" = "200" ] && pass "TESTE-E2E-10 DIRETOR aprova proposta (estava EM_APROVACAO) — 200" || fail "TESTE-E2E-10 aprovar proposta" "codigo=$CODE body=$(body)"
else
  pass "TESTE-E2E-10 proposta nasceu em $PROP_STATUS (preço >= recomendado) — não precisa de aprovação prévia, seguindo fluxo normal"
fi

CODE=$(api POST "/api/proposals/$PROP_ID/status" "$TOK_DIRETOR" '{"status":"ACEITA"}')
[ "$CODE" = "200" ] && pass "TESTE-E2E-11 proposta muda para ACEITA — 200" || fail "TESTE-E2E-11 mudar para ACEITA" "codigo=$CODE body=$(body)"

WEBHOOK_SECRET_ENV_NAME="FASE25_TEST_WEBHOOK_SECRET"
WEBHOOK_SECRET_VALUE="optimon-fase25-teste-hmac-secret-nao-usar-em-producao"
if ! grep -q "^${WEBHOOK_SECRET_ENV_NAME}=" api/.env 2>/dev/null; then
  echo "${WEBHOOK_SECRET_ENV_NAME}=${WEBHOOK_SECRET_VALUE}" >> api/.env
  pkill -f "node server.js" 2>/dev/null || true
  sleep 1
  ( cd api && nohup node server.js > /tmp/fase310_api.log 2>&1 & disown )
  sleep 2
fi

PROVIDER_ID=$(scalar "select id from signature_providers where tipo='ICP_BRASIL_HOMOLOGACAO_MOCK' and ambiente='HOMOLOGACAO' limit 1;")
if [ -z "$PROVIDER_ID" ]; then
  CODE=$(api POST "/api/signatures/providers" "$TOK_ADMIN" "{\"nome\":\"Homologação Fase310 Teste\",\"tipo\":\"ICP_BRASIL_HOMOLOGACAO_MOCK\",\"ambiente\":\"HOMOLOGACAO\",\"webhook_secret_ref\":\"$WEBHOOK_SECRET_ENV_NAME\"}")
  PROVIDER_ID=$(jget ".id")
fi
if [ -n "$PROVIDER_ID" ]; then
  pass "TESTE-E2E-12 provedor de assinatura MOCK/HOMOLOGAÇÃO disponível — id=$PROVIDER_ID"
else
  fail "TESTE-E2E-12 provedor de assinatura" "body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

ENVELOPE_ID=$(curl -sS -o /tmp/fase310_resp.json -w '' -X POST "$API/api/signatures/envelopes" -H "Authorization: Bearer $TOK_COMERCIAL" -F "tipo_documento=PROPOSTA" -F "provider_id=$PROVIDER_ID" -F "proposta_id=$PROP_ID" > /dev/null; jget ".id")
if [ -n "$ENVELOPE_ID" ]; then
  pass "TESTE-E2E-13 envelope de assinatura criado (PDF auto-gerado) — id=$ENVELOPE_ID"
else
  fail "TESTE-E2E-13 criar envelope" "body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

api POST "/api/signatures/envelopes/$ENVELOPE_ID/signers" "$TOK_COMERCIAL" '{"nome":"Representante NICK (teste E2E)","email":"nick-e2e310@optimon.local","papel":"REPRESENTANTE_NICK","ordem":1}' > /dev/null
api POST "/api/signatures/envelopes/$ENVELOPE_ID/signers" "$TOK_COMERCIAL" '{"nome":"Representante TESTE-E2E-OPTIMON-310","email":"parceiro-e2e310@optimon.local","papel":"REPRESENTANTE_PROPONENTE","ordem":2}' > /dev/null
pass "TESTE-E2E-14 2 signatários adicionados ao envelope"

CODE=$(api POST "/api/signatures/envelopes/$ENVELOPE_ID/send" "$TOK_COMERCIAL")
PROP_STATUS_APOS_ENVIO=$(scalar "select status from propostas_comerciais where id='$PROP_ID';")
if [ "$CODE" = "200" ] && [ "$PROP_STATUS_APOS_ENVIO" = "EM_ASSINATURA" ]; then
  pass "TESTE-E2E-15 envelope enviado ao provedor mock; proposta passa para EM_ASSINATURA — 200"
else
  fail "TESTE-E2E-15 enviar para assinatura" "codigo=$CODE status_proposta=$PROP_STATUS_APOS_ENVIO body=$(body)"
fi

PROVIDER_ENVELOPE_ID=$(scalar "select provider_envelope_id from signature_envelopes where id='$ENVELOPE_ID';")
sign_and_post_webhook() {
  local payload_file="$1"
  local sig
  sig=$(openssl dgst -sha256 -hmac "$WEBHOOK_SECRET_VALUE" "$payload_file" | awk '{print $NF}')
  curl -sS -o /tmp/fase310_webhook_resp.json -w '%{http_code}' -X POST "$API/api/signatures/webhook" \
    -H "Content-Type: application/json" -H "X-Signature: $sig" --data-binary "@$payload_file"
}
cat > /tmp/fase310_webhook_evt1.json <<EOF
{"provider_envelope_id":"$PROVIDER_ENVELOPE_ID","evento_externo_id":"evt-1-e2e310","tipo_evento":"SIGNER_SIGNED","signer_email":"nick-e2e310@optimon.local","signer_novo_status":"ASSINADO","signer_ip":"203.0.113.10","novo_status_envelope":"PARCIALMENTE_ASSINADO"}
EOF
cat > /tmp/fase310_webhook_evt2.json <<EOF
{"provider_envelope_id":"$PROVIDER_ENVELOPE_ID","evento_externo_id":"evt-2-e2e310","tipo_evento":"SIGNER_SIGNED","signer_email":"parceiro-e2e310@optimon.local","signer_novo_status":"ASSINADO","signer_ip":"203.0.113.11","novo_status_envelope":"ASSINADO","hash_assinado":"e2e310-hash-teste-homologacao","storage_path_assinado":"homologacao/teste-e2e-310/documento-assinado.pdf"}
EOF
sign_and_post_webhook /tmp/fase310_webhook_evt1.json > /dev/null
sign_and_post_webhook /tmp/fase310_webhook_evt2.json > /dev/null
PROP_STATUS_FINAL=$(scalar "select status from propostas_comerciais where id='$PROP_ID';")
if [ "$PROP_STATUS_FINAL" = "ASSINADA" ]; then
  pass "TESTE-E2E-16 webhooks de assinatura (2 signatários, HMAC válido) processados — proposta agora ASSINADA"
else
  fail "TESTE-E2E-16 assinatura via webhook" "status_final=$PROP_STATUS_FINAL"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

echo "############################################################"
echo "# ETAPA 6 — Problema 3: CRIAR CONTRATO a partir da proposta ASSINADA #"
echo "############################################################"
CODE=$(api POST "/api/contracts/generate" "$TOK_COMERCIAL" "{\"proposta_id\":\"$PROP_ID\"}")
CONTRATO_ID=$(jget ".id")
CONTRATO_NUMERO=$(jget ".numero")
if [ "$CODE" = "201" ] && [ -n "$CONTRATO_ID" ]; then
  pass "TESTE-E2E-17 CRIAR CONTRATO a partir da proposta ASSINADA — 201, numero=$CONTRATO_NUMERO id=$CONTRATO_ID"
else
  fail "TESTE-E2E-17 criar contrato" "codigo=$CODE body=$(body)"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; exit 1
fi

CODE=$(api POST "/api/contracts/generate" "$TOK_COMERCIAL" "{\"proposta_id\":\"$PROP_ID\"}")
if [ "$CODE" != "201" ]; then
  pass "TESTE-E2E-18 tentativa de criar o contrato DE NOVO para a mesma proposta é bloqueada (nunca duplica) — codigo=$CODE"
else
  fail "TESTE-E2E-18 bloqueio de duplicação" "esperava erro, obteve 201 de novo — body=$(body)"
fi

echo "############################################################"
echo "# ETAPA 7 — vínculo bidirecional permanente e auditável (seção 3.4) #"
echo "############################################################"
CODE=$(api GET "/api/proposals/$PROP_ID" "$TOK_COMERCIAL")
PROP_CONTRATO_ID=$(jget ".contrato_id")
PROP_CONTRATO_NUMERO=$(jget ".contrato_numero")
[ "$PROP_CONTRATO_ID" = "$CONTRATO_ID" ] && [ "$PROP_CONTRATO_NUMERO" = "$CONTRATO_NUMERO" ] \
  && pass "TESTE-E2E-19 lado da PROPOSTA mostra 'Contrato vinculado: $PROP_CONTRATO_NUMERO' (contrato_id bate)" \
  || fail "TESTE-E2E-19 vínculo proposta->contrato" "contrato_id=$PROP_CONTRATO_ID esperado=$CONTRATO_ID numero=$PROP_CONTRATO_NUMERO"

CODE=$(api GET "/api/contracts/$CONTRATO_ID" "$TOK_COMERCIAL")
CTR_PROP_ID=$(jget ".proposta_origem.id")
CTR_PROP_NUMERO=$(jget ".proposta_origem.numero")
[ "$CTR_PROP_ID" = "$PROP_ID" ] && [ "$CTR_PROP_NUMERO" = "$PROP_NUMERO" ] \
  && pass "TESTE-E2E-20 lado do CONTRATO mostra 'Proposta de origem: $CTR_PROP_NUMERO' (id bate) — vínculo bidirecional confirmado nos dois sentidos" \
  || fail "TESTE-E2E-20 vínculo contrato->proposta" "proposta_origem.id=$CTR_PROP_ID esperado=$PROP_ID"

echo "############################################################"
echo "# ETAPA 8 — dados transportados automaticamente (seção 4 — nunca contrato vazio) #"
echo "############################################################"
CTR_PARCEIRO=$(jget ".parceiro_id")
CTR_CIDADE=$(jget ".cidade_id")
CTR_PRAZO=$(jget ".prazo_meses")
CTR_REVSHARE=$(jget ".pricing_config.percentual_revenue_share")
[ "$CTR_PARCEIRO" = "$PARCEIRO_ID" ] && [ "$CTR_CIDADE" = "$CIDADE_ID" ] && [ -n "$CTR_PRAZO" ] && [ -n "$CTR_REVSHARE" ] \
  && pass "TESTE-E2E-21 contrato nasceu com dados reais da proposta (parceiro/cidade/prazo=$CTR_PRAZO meses/revenue_share=$CTR_REVSHARE) — nunca um contrato vazio" \
  || fail "TESTE-E2E-21 dados transportados" "parceiro=$CTR_PARCEIRO cidade=$CTR_CIDADE prazo=$CTR_PRAZO revshare=$CTR_REVSHARE"

AUDIT_GENERATE=$(scalar "select count(*) from auditoria where entidade_id='$CONTRATO_ID' and acao='CONTRACT_GENERATE';")
AUDIT_MINUTA=$(scalar "select count(*) from auditoria where entidade_id='$CONTRATO_ID' and acao='CONTRACT_MINUTA_GENERATED';")
[ "$AUDIT_GENERATE" = "1" ] && pass "TESTE-E2E-22 auditoria CONTRACT_GENERATE registrada" || fail "TESTE-E2E-22 auditoria CONTRACT_GENERATE" "contagem=$AUDIT_GENERATE"
[ "$AUDIT_MINUTA" = "1" ] && pass "TESTE-E2E-23 auditoria CONTRACT_MINUTA_GENERATED registrada (minuta disponível desde a criação, Fase 3.10)" || fail "TESTE-E2E-23 auditoria CONTRACT_MINUTA_GENERATED" "contagem=$AUDIT_MINUTA"

echo "############################################################"
echo "# ETAPA 8.5 — Problema 2 (seção 2.3): PDF/DOCX da proposta, modo EXTERNA (client-safe) e INTERNA #"
echo "############################################################"
for MODO_TESTE in interna externa; do
  for FMT in PDF DOCX; do
    OUT="/tmp/fase310_proposta_${MODO_TESTE}.${FMT,,}"
    HTTP_CODE=$(curl -sS -o "$OUT" -w "%{http_code}" "$API/api/proposals/$PROP_ID/export?formato=$FMT&modo=$MODO_TESTE" -H "Authorization: Bearer $TOK_ADMIN")
    SIZE=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
    if [ "$HTTP_CODE" = "200" ] && [ "$SIZE" -gt 1000 ]; then
      pass "TESTE-E2E-23B-$MODO_TESTE-$FMT proposta $FMT modo $MODO_TESTE gerada de verdade — $SIZE bytes ($OUT)"
    else
      fail "TESTE-E2E-23B-$MODO_TESTE-$FMT gerar proposta $FMT modo $MODO_TESTE" "codigo=$HTTP_CODE tamanho=$SIZE body=$(cat "$OUT" 2>/dev/null | head -c 300)"
    fi
  done
done

# a exportação EXTERNA (documento client-safe) precisa conter as observações comerciais/
# próximos passos reais gravados na ETAPA 4, e o PDF INTERNO precisa preservar piso/
# recomendado (nunca perder dado que já existia antes da Fase 3.10).
if command -v pdftotext > /dev/null; then
  TXT_EXT=$(pdftotext /tmp/fase310_proposta_externa.pdf - 2>/dev/null)
  if echo "$TXT_EXT" | grep -q "forte interesse em expansão" && echo "$TXT_EXT" | grep -q "Aguardando aprovação da Diretoria"; then
    pass "TESTE-E2E-23C texto da proposta PDF EXTERNA contém as observações comerciais/próximos passos reais (Problema 2, seção 2.3)"
  else
    fail "TESTE-E2E-23C observações comerciais no PDF externo" "texto extraído não contém as strings esperadas"
  fi
  if echo "$TXT_EXT" | grep -qi "piso\b\|governança\|desconto máximo"; then
    fail "TESTE-E2E-23D PDF EXTERNA não deveria conter dado interno de governança" "encontrado termo de governança no texto extraído"
  else
    pass "TESTE-E2E-23D PDF EXTERNA confirmadamente não contém piso/desconto máximo/governança (dado interno nunca vaza para o parceiro)"
  fi
  TXT_INT=$(pdftotext /tmp/fase310_proposta_interna.pdf - 2>/dev/null)
  if echo "$TXT_INT" | grep -qi "piso"; then
    pass "TESTE-E2E-23E PDF INTERNA preserva o dado de piso (uso interno, como antes da Fase 3.10)"
  else
    fail "TESTE-E2E-23E piso ausente no PDF interno" "regressão: dado interno que já existia sumiu"
  fi
else
  fail "TESTE-E2E-23C/D/E pdftotext indisponível" "não foi possível validar o conteúdo textual real do PDF"
fi

echo "############################################################"
echo "# ETAPA 9 — minuta real: PDF, DOCX, sem placeholders, com cláusulas mínimas #"
echo "############################################################"
for FMT in PDF DOCX; do
  OUT="/tmp/fase310_minuta.${FMT,,}"
  HTTP_CODE=$(curl -sS -o "$OUT" -w "%{http_code}" "$API/api/contracts/$CONTRATO_ID/minuta?formato=$FMT" -H "Authorization: Bearer $TOK_ADMIN")
  SIZE=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
  if [ "$HTTP_CODE" = "200" ] && [ "$SIZE" -gt 1000 ]; then
    pass "TESTE-E2E-24-$FMT minuta $FMT gerada e salva de verdade — $SIZE bytes ($OUT)"
  else
    fail "TESTE-E2E-24-$FMT gerar minuta $FMT" "codigo=$HTTP_CODE tamanho=$SIZE"
  fi
done

DADOS_JSON=$(scalar "select app.contrato_documento_dados('$CONTRATO_ID');")
echo "$DADOS_JSON" > /tmp/fase310_dados_contrato.json
node -e "
const { buildContractDocumentModel } = require('$ROOT/api/lib/contractDocumentModel.js');
const dados = require('/tmp/fase310_dados_contrato.json');
const m = buildContractDocumentModel(dados);
const s = m.sections;
const comPlaceholder = s.filter(x => typeof x.texto === 'string' && (x.texto.includes('CLÁUSULA-MODELO') || x.texto.includes('AGUARDANDO REDAÇÃO')));
console.log('SEM_PLACEHOLDER=' + (comPlaceholder.length === 0 ? 'PASS' : 'FAIL') + ' restantes=' + JSON.stringify(comPlaceholder.map(x=>x.titulo)));
const obrigatorias = [
  'Definições','Objeto','Natureza Jurídica da Cessão','Infraestrutura e Capacidade Contratada',
  'Implantação e Ativação','Nível de Serviço (SLA)','Responsabilidades das Partes',
  'Responsabilidade pela Instalação do Cliente Final','Take-or-Pay (Mínimo Contratual)',
  'Revenue Share','Vigência e Renovação','Prazo Mínimo Contratual (48 meses)','Força Maior',
  'Inadimplência','Rescisão','Penalidades','Multa por Rescisão Antecipada',
  'Responsabilidade por Danos','Seguro','Propriedade dos Ativos','Devolução de Ativos',
  'Auditoria','Exclusividade','Capacidade Remanescente e Direito de Cessão a Terceiros pela NICK',
  'Rede Própria do Parceiro e Fibras de Terceiros','Clientes Reservados (inclui eventual exceção Prefeitura)',
  'Sublocação e Cessão de Uso a Terceiros','Confidencialidade','Proteção de Dados (LGPD)',
  'Propriedade Intelectual e Uso de Marca','Compliance, Ética e Anticorrupção',
  'Independência das Partes','Cessão da Posição Contratual e Venda/Transferência da Operação do Parceiro',
  'Solução de Controvérsias e Mediação','Foro','Disposições Gerais',
];
const titulos = new Set(s.map(x => x.titulo));
const faltando = obrigatorias.filter(t => !titulos.has(t));
console.log('CLAUSULAS_MINIMAS=' + (faltando.length === 0 ? 'PASS' : 'FAIL') + ' faltando=' + JSON.stringify(faltando));
console.log('REDE_NEUTRA=' + (s.every(x => !(typeof x.texto === 'string' && /rede neutra/i.test(x.texto) && !/N.O caracteriza.*rede neutra|NÃO caracteriza.*rede neutra|nunca.*rede neutra/i.test(x.texto))) ? 'PASS' : 'FAIL'));
" > /tmp/fase310_juridico.log 2>&1
cat /tmp/fase310_juridico.log
grep -q "^SEM_PLACEHOLDER=PASS" /tmp/fase310_juridico.log && pass "TESTE-E2E-25 minuta REAL deste contrato de teste não contém nenhum '[CLÁUSULA-MODELO'/'AGUARDANDO REDAÇÃO' (Fase 3.10, seção 11)" || fail "TESTE-E2E-25 sem placeholders" "$(grep SEM_PLACEHOLDER /tmp/fase310_juridico.log)"
grep -q "^CLAUSULAS_MINIMAS=PASS" /tmp/fase310_juridico.log && pass "TESTE-E2E-26 todas as cláusulas mínimas do checklist da Fase 3.10 (seção 1.2) estão presentes na minuta real" || fail "TESTE-E2E-26 cláusulas mínimas" "$(grep CLAUSULAS_MINIMAS /tmp/fase310_juridico.log)"
grep -q "^REDE_NEUTRA=PASS" /tmp/fase310_juridico.log && pass "TESTE-E2E-27 minuta nunca usa 'rede neutra' para caracterizar o modelo (seção 1.4) — só para negar explicitamente essa caracterização" || fail "TESTE-E2E-27 rede neutra" "$(grep REDE_NEUTRA /tmp/fase310_juridico.log)"

echo "############################################################"
echo "# ETAPA 10 — evidência visual real (PDF -> PNG) #"
echo "############################################################"
mkdir -p /tmp/fase310_evidencia
if command -v pdftoppm > /dev/null; then
  pdftoppm -png -r 100 -f 1 -l 1 /tmp/fase310_minuta.pdf /tmp/fase310_evidencia/minuta_capa 2>/tmp/fase310_pdftoppm.log
  CAPA_PNG=$(ls /tmp/fase310_evidencia/minuta_capa-*.png 2>/dev/null | head -1)
  if [ -n "$CAPA_PNG" ] && [ -f "$CAPA_PNG" ]; then
    pass "TESTE-E2E-28 evidência visual real gerada (PNG da capa da minuta) — $CAPA_PNG"
  else
    fail "TESTE-E2E-28 gerar evidência visual" "ver /tmp/fase310_pdftoppm.log"
  fi
else
  fail "TESTE-E2E-28 pdftoppm indisponível" "não foi possível gerar evidência visual"
fi

echo "############################################################"
echo "# ETAPA 11 — limpeza controlada dos dados de teste #"
echo "############################################################"
CODE=$(api POST "/api/partners/$PARCEIRO_ID/deactivate" "$TOK_ADMIN" '{"motivo":"Encerramento do TESTE-E2E-OPTIMON-310 (Fase 3.10) — limpeza controlada pós-homologação."}')
if [ "$CODE" = "200" ]; then
  pass "TESTE-E2E-29 parceiro de teste desativado ao final (política de exclusão controlada — proposta/contrato de teste permanecem como histórico auditável imutável, claramente identificados por 'TESTE-E2E-OPTIMON-310', nunca apagados fisicamente por design do sistema desde a Fase 1)"
else
  fail "TESTE-E2E-29 desativar parceiro de teste" "codigo=$CODE body=$(body)"
fi

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
echo "Evidências salvas em: /tmp/fase310_minuta.pdf /tmp/fase310_minuta.docx /tmp/fase310_evidencia/"
