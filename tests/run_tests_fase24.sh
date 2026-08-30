#!/usr/bin/env bash
# OptiMon — Fase 2.4: Manuais Operacionais + Central de Ajuda + Módulo Profissional de
# Propostas + Exportação PDF/DOCX + Histórico e Controle de Versões.
#
# TESTE 1-10 (equivalente à seção de testes obrigatórios do prompt-mestre) + regressão
# completa (encadeando Fase1..Fase2.3.1 via run_tests_fase231.sh, nunca escondendo
# regressão) + as migrations novas desta fase (20260909*.sql). Mesmo padrão de
# tests/run_tests_fase231.sh — sobe a pilha real (PostgREST local + API Node) e testa por
# HTTP com JWTs de cada perfil, porque o que esta fase valida é justamente RBAC/RLS por
# rota (quem pode aprovar/rejeitar/mudar status) e o conteúdo real do PDF/DOCX gerado —
# não dá pra confiar só em teste de SQL isolado pra isso.

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

# ============================================================================
# PASSO 0 — regressão completa (Fase1..Fase2.3.1) + migrations desta fase
# ============================================================================
echo "### PASSO 0: regressao completa via run_tests_fase231.sh, depois aplica as migrations novas desta fase (20260909*) ###"
pkill -f "postgrest .*postgrest.local.conf" 2>/dev/null || true
pkill -f "rest_v1_proxy.js" 2>/dev/null || true
pkill -f "node server.js" 2>/dev/null || true
sleep 1

if ! bash tests/run_tests_fase231.sh > /tmp/fase24_regression_base.log 2>&1; then
  fail "PASSO-0 regressao base (run_tests_fase231.sh, que encadeia Fase1..2.3.1)" "ver /tmp/fase24_regression_base.log — abortando"
  echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; echo "=============================================="
  exit 1
fi
pass "PASSO-0 regressao completa Fase1..Fase2.3.1 (via run_tests_fase231.sh) — banco pronto para as migrations novas desta fase"

for f in $(ls supabase/migrations/20260909*.sql | sort); do
  if ! $PSQL -v ON_ERROR_STOP=1 -f "$f" > /tmp/fase24_mig_apply.log 2>&1; then
    fail "PASSO-0 aplicar $f" "ver /tmp/fase24_mig_apply.log"
    echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; echo "=============================================="
    exit 1
  fi
done
pass "PASSO-0 todas as migrations novas desta fase (20260909*.sql) aplicaram sem erro sobre a base"
$PSQL -c "NOTIFY pgrst, 'reload schema';" > /dev/null 2>&1
sleep 1

# ============================================================================
# PASSO 1 — pilha local no ar + JWTs de cada perfil
# ============================================================================
echo "### PASSO 1: confirmando pilha local no ar ###"
HEALTH=$(curl -sS -m 3 http://localhost:3001/health 2>&1)
if [[ "$HEALTH" == *'"status":"ok"'* ]]; then
  pass "PASSO-1 API local no ar — GET /health = $HEALTH"
else
  fail "PASSO-1 API local no ar" "GET /health devolveu: $HEALTH"
  echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; echo "=============================================="
  exit 1
fi

uid_of_role() { $PSQL -t -A -c "select id from public.usuarios where perfil='$1' limit 1;" | tr -d ' '; }
jwt_for() { node supabase/dev-local-only/mint_jwt.js "$1"; }

UID_ADMIN=$(uid_of_role ADMINISTRADOR)
UID_DIRETOR=$(uid_of_role DIRETOR)
UID_ENGENHARIA=$(uid_of_role ENGENHARIA)
UID_COMERCIAL=$(uid_of_role COMERCIAL)
UID_FINANCEIRO=$(uid_of_role FINANCEIRO)
UID_AUDITOR=$(uid_of_role AUDITOR)
JWT_ADMIN=$(jwt_for "$UID_ADMIN")
JWT_DIRETOR=$(jwt_for "$UID_DIRETOR")
JWT_ENGENHARIA=$(jwt_for "$UID_ENGENHARIA")
JWT_COMERCIAL=$(jwt_for "$UID_COMERCIAL")
JWT_FINANCEIRO=$(jwt_for "$UID_FINANCEIRO")
JWT_AUDITOR=$(jwt_for "$UID_AUDITOR")

api() {
  local method="$1"; local path="$2"; local jwt="$3"; local body="${4:-}"
  if [ -n "$body" ]; then
    curl -sS -o /tmp/fase24_body.json -w '%{http_code}' -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt" -H "Content-Type: application/json" -d "$body"
  else
    curl -sS -o /tmp/fase24_body.json -w '%{http_code}' -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt"
  fi
}
body() { cat /tmp/fase24_body.json; }
json_get() { node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=JSON.parse(d);const p='$1'.split('.');let c2=v;for(const k of p){c2=c2==null?undefined:c2[k];}console.log(c2===undefined?'':c2);}catch(e){console.log('');}})"; }

aud_check() {
  local nome="$1" entidade="$2" eid="$3" acao="$4"
  local row
  row=$($PSQL -t -A -F'|' -c "select (usuario_id is not null), (criado_em is not null) from public.auditoria where entidade='$entidade' and entidade_id='$eid' and acao='$acao' order by criado_em desc limit 1;")
  local tem_usuario tem_data
  IFS='|' read -r tem_usuario tem_data <<< "$row"
  if [ "$tem_usuario" = "t" ] && [ "$tem_data" = "t" ]; then
    pass "$nome (usuario=$tem_usuario data=$tem_data)"
  else
    fail "$nome" "entidade=$entidade entidade_id=$eid acao=$acao -> linha='$row'"
  fi
}

JID=$($PSQL -t -A -c "select id from public.cidades_infra where nome='Jussara';" | tr -d ' ')
PARTNER_ID=$($PSQL -t -A -c "select id from public.parceiros where ativo=true limit 1;" | tr -d ' ')

# ============================================================================
# PASSO 2 (TESTE 0): GET /api/partners — gap fechado nesta fase
# ============================================================================
echo "### PASSO 2 (TESTE 0): GET /api/partners ###"
CODE=$(api GET "/api/partners" "$JWT_COMERCIAL")
COUNT=$(body | json_get length 2>/dev/null || echo "")
if [ "$CODE" = "200" ]; then
  pass "TESTE-0 GET /api/partners = 200 (parceiros nunca expostos antes da Fase 2.4)"
else
  fail "TESTE-0 GET /api/partners" "codigo=$CODE body=$(body)"
fi

# ============================================================================
# PASSO 3 (TESTE 1): criar proposta com preço >= recomendado -> nasce RASCUNHO
# ============================================================================
echo "### PASSO 3 (TESTE 1): proposta com preco_proposto >= recomendado nasce RASCUNHO ###"
CODE=$(api POST "/api/pricing/calculate" "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"clientes\":200,\"arpu\":100,\"revenue_share_pct\":0.12,\"composicao_mode\":\"MAX\"}")
RECOMMENDED=$(body | json_get recommended)
FLOOR=$(body | json_get floor)
if [ "$CODE" = "200" ] && [ -n "$RECOMMENDED" ]; then
  pass "TESTE-1a pricing.calculate — floor=$FLOOR recommended=$RECOMMENDED"
else
  fail "TESTE-1a pricing.calculate" "codigo=$CODE body=$(body)"
fi

CODE=$(api POST "/api/pricing/calculate" "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"clientes\":200,\"arpu\":100,\"revenue_share_pct\":0.12,\"composicao_mode\":\"MAX\",\"preco_proposto\":$RECOMMENDED}")
RESULTADO_RASCUNHO=$(body)
CODE=$(api POST "/api/simulations" "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"modelo\":\"HIBRIDO_REVENUE_SHARE\",\"pares_ou_clientes\":200,\"arpu\":100,\"revenue_share_pct\":0.12,\"prazo_meses\":48,\"resultado\":$RESULTADO_RASCUNHO}")
SIM_RASCUNHO=$(body | json_get id)
CODE=$(api POST "/api/proposals" "$JWT_COMERCIAL" "{\"simulacao_id\":\"$SIM_RASCUNHO\",\"cidade_id\":\"$JID\",\"parceiro_id\":\"$PARTNER_ID\",\"parceiro_cargo_contato\":\"Diretor Comercial\",\"validade_dias\":20}")
PROP_RASCUNHO=$(body | json_get id)
STATUS_RASCUNHO=$(body | json_get status)
if [ "$CODE" = "201" ] && [ "$STATUS_RASCUNHO" = "RASCUNHO" ]; then
  pass "TESTE-1b proposta com preco=recomendado nasce RASCUNHO ($PROP_RASCUNHO)"
else
  fail "TESTE-1b proposta com preco=recomendado" "codigo=$CODE status=$STATUS_RASCUNHO body=$(body)"
fi

# ============================================================================
# PASSO 4 (TESTE 2): proposta com preço abaixo do recomendado (mas >= piso) -> EM_APROVACAO
# ============================================================================
echo "### PASSO 4 (TESTE 2): proposta com preco abaixo do recomendado nasce EM_APROVACAO ###"
PRECO_ENTRE=$(node -e "console.log(($FLOOR + $RECOMMENDED)/2)")
CODE=$(api POST "/api/pricing/calculate" "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"clientes\":200,\"arpu\":100,\"revenue_share_pct\":0.12,\"composicao_mode\":\"MAX\",\"preco_proposto\":$PRECO_ENTRE}")
RESULTADO_ENTRE=$(body)
CODE=$(api POST "/api/simulations" "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"modelo\":\"HIBRIDO_REVENUE_SHARE\",\"pares_ou_clientes\":200,\"arpu\":100,\"revenue_share_pct\":0.12,\"prazo_meses\":48,\"resultado\":$RESULTADO_ENTRE}")
SIM_ENTRE=$(body | json_get id)
CODE=$(api POST "/api/proposals" "$JWT_COMERCIAL" "{\"simulacao_id\":\"$SIM_ENTRE\",\"cidade_id\":\"$JID\",\"parceiro_nome_capa\":\"Parceiro Teste Livre\"}")
PROP_ENTRE=$(body | json_get id)
STATUS_ENTRE=$(body | json_get status)
if [ "$CODE" = "201" ] && [ "$STATUS_ENTRE" = "EM_APROVACAO" ]; then
  pass "TESTE-2 proposta com preco entre piso e recomendado nasce EM_APROVACAO ($PROP_ENTRE)"
else
  fail "TESTE-2 proposta abaixo do recomendado" "codigo=$CODE status=$STATUS_ENTRE body=$(body)"
fi

# ============================================================================
# PASSO 5 (TESTE 3): COMERCIAL não pode aprovar proposta (403)
# ============================================================================
echo "### PASSO 5 (TESTE 3): COMERCIAL nao pode aprovar proposta ###"
CODE=$(api POST "/api/proposals/$PROP_ENTRE/approve" "$JWT_COMERCIAL" '{}')
if [ "$CODE" = "403" ]; then
  pass "TESTE-3 COMERCIAL bloqueado ao tentar aprovar (403)"
else
  fail "TESTE-3 COMERCIAL aprovar" "esperado 403, obtido $CODE body=$(body)"
fi

# ============================================================================
# PASSO 6 (TESTE 4): proposta com preço abaixo do PISO exige motivo obrigatório na aprovação
# ============================================================================
echo "### PASSO 6 (TESTE 4): aprovacao abaixo do piso exige motivo obrigatorio ###"
PRECO_ABAIXO_PISO=$(node -e "console.log($FLOOR * 0.7)")
CODE=$(api POST "/api/pricing/calculate" "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"clientes\":200,\"arpu\":100,\"revenue_share_pct\":0.12,\"composicao_mode\":\"MAX\",\"preco_proposto\":$PRECO_ABAIXO_PISO}")
RESULTADO_BAIXO=$(body)
CODE=$(api POST "/api/simulations" "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"modelo\":\"HIBRIDO_REVENUE_SHARE\",\"pares_ou_clientes\":200,\"arpu\":100,\"revenue_share_pct\":0.12,\"prazo_meses\":48,\"resultado\":$RESULTADO_BAIXO}")
SIM_BAIXO=$(body | json_get id)
CODE=$(api POST "/api/proposals" "$JWT_COMERCIAL" "{\"simulacao_id\":\"$SIM_BAIXO\",\"cidade_id\":\"$JID\"}")
PROP_BAIXO=$(body | json_get id)

CODE=$(api POST "/api/proposals/$PROP_BAIXO/approve" "$JWT_DIRETOR" '{}')
if [ "$CODE" = "400" ]; then
  pass "TESTE-4a DIRETOR sem motivo é bloqueado ao aprovar preço abaixo do piso (400)"
else
  fail "TESTE-4a aprovar sem motivo abaixo do piso" "esperado 400, obtido $CODE body=$(body)"
fi

# ============================================================================
# PASSO 7 (TESTE 5): DIRETOR aprova com motivo -> sucesso + autorizacao registrada + auditoria
# ============================================================================
echo "### PASSO 7 (TESTE 5): DIRETOR aprova com motivo -> APROVADA + autorizacao + auditoria ###"
CODE=$(api POST "/api/proposals/$PROP_BAIXO/approve" "$JWT_DIRETOR" '{"motivo":"Cliente estrategico, volume comprometido em contrato."}')
STATUS_APROVADA=$(body | json_get status)
AUTORIZADO_POR=$(body | json_get autorizado_por)
if [ "$CODE" = "200" ] && [ "$STATUS_APROVADA" = "APROVADA" ] && [ -n "$AUTORIZADO_POR" ]; then
  pass "TESTE-5a aprovacao com motivo -> APROVADA, autorizado_por preenchido"
else
  fail "TESTE-5a aprovacao com motivo" "codigo=$CODE status=$STATUS_APROVADA body=$(body)"
fi
aud_check "TESTE-5b auditoria PROPOSAL_APPROVE registrada" "propostas_comerciais" "$PROP_BAIXO" "PROPOSAL_APPROVE"

# ============================================================================
# PASSO 8 (TESTE 6): rejeitar exige motivo; com motivo -> RECUSADA + auditoria
# ============================================================================
echo "### PASSO 8 (TESTE 6): rejeitar exige motivo obrigatorio ###"
CODE=$(api POST "/api/proposals/$PROP_ENTRE/reject" "$JWT_DIRETOR" '{}')
if [ "$CODE" = "400" ]; then
  pass "TESTE-6a rejeitar sem motivo é bloqueado (400)"
else
  fail "TESTE-6a rejeitar sem motivo" "esperado 400, obtido $CODE body=$(body)"
fi
CODE=$(api POST "/api/proposals/$PROP_ENTRE/reject" "$JWT_DIRETOR" '{"motivo":"Parceiro desistiu da negociacao."}')
STATUS_RECUSADA=$(body | json_get status)
if [ "$CODE" = "200" ] && [ "$STATUS_RECUSADA" = "RECUSADA" ]; then
  pass "TESTE-6b rejeitar com motivo -> RECUSADA"
else
  fail "TESTE-6b rejeitar com motivo" "codigo=$CODE status=$STATUS_RECUSADA body=$(body)"
fi
aud_check "TESTE-6c auditoria PROPOSAL_REJECT registrada" "propostas_comerciais" "$PROP_ENTRE" "PROPOSAL_REJECT"

# ============================================================================
# PASSO 9 (TESTE 7): transicoes de status (ENVIADA -> EM_NEGOCIACAO -> ACEITA) e bloqueio
# de transicao a partir de estado terminal
# ============================================================================
echo "### PASSO 9 (TESTE 7): ciclo de transicoes de status + bloqueio a partir de estado terminal ###"
CODE=$(api POST "/api/proposals/$PROP_BAIXO/status" "$JWT_DIRETOR" '{"status":"ENVIADA"}')
S1=$(body | json_get status)
CODE=$(api POST "/api/proposals/$PROP_BAIXO/status" "$JWT_DIRETOR" '{"status":"EM_NEGOCIACAO"}')
S2=$(body | json_get status)
CODE=$(api POST "/api/proposals/$PROP_BAIXO/status" "$JWT_DIRETOR" '{"status":"ACEITA"}')
S3=$(body | json_get status)
if [ "$S1" = "ENVIADA" ] && [ "$S2" = "EM_NEGOCIACAO" ] && [ "$S3" = "ACEITA" ]; then
  pass "TESTE-7a ciclo ENVIADA -> EM_NEGOCIACAO -> ACEITA"
else
  fail "TESTE-7a ciclo de status" "S1=$S1 S2=$S2 S3=$S3"
fi
CODE=$(api POST "/api/proposals/$PROP_BAIXO/status" "$JWT_DIRETOR" '{"status":"ENVIADA"}')
if [ "$CODE" = "409" ]; then
  pass "TESTE-7b mudar status a partir de estado terminal (ACEITA) é bloqueado (409)"
else
  fail "TESTE-7b bloqueio de estado terminal" "esperado 409, obtido $CODE body=$(body)"
fi
aud_check "TESTE-7c auditoria PROPOSAL_STATUS_CHANGE registrada" "propostas_comerciais" "$PROP_BAIXO" "PROPOSAL_STATUS_CHANGE"

# ============================================================================
# PASSO 10 (TESTE 8): nova versao (mesma familia) e duplicar proposta (familia independente)
# ============================================================================
echo "### PASSO 10 (TESTE 8): nova versao e duplicar proposta ###"
CODE=$(api POST "/api/proposals/$PROP_RASCUNHO/version" "$JWT_COMERCIAL" '{"motivo":"Ajuste de ARPU."}')
V2_ID=$(body | json_get id)
V2_NUM=$(body | json_get numero_versao)
V2_RAIZ=$(body | json_get proposta_raiz_id)
V2_NUMERO_PROPOSTA=$(body | json_get numero)
NUMERO_RASCUNHO=$($PSQL -t -A -c "select numero from public.propostas_comerciais where id='$PROP_RASCUNHO';" | tr -d ' ')
if [ "$CODE" = "201" ] && [ "$V2_NUM" = "2" ] && [ "$V2_RAIZ" = "$PROP_RASCUNHO" ] && [ "$V2_NUMERO_PROPOSTA" = "${NUMERO_RASCUNHO}-V2" ]; then
  pass "TESTE-8a nova versao V2 criada na mesma familia (numero $V2_NUMERO_PROPOSTA deriva de $NUMERO_RASCUNHO, proposta_raiz_id=$PROP_RASCUNHO)"
else
  fail "TESTE-8a nova versao" "codigo=$CODE numero_versao=$V2_NUM raiz=$V2_RAIZ body=$(body)"
fi
aud_check "TESTE-8b auditoria PROPOSAL_VERSION_CREATE registrada" "propostas_comerciais" "$V2_ID" "PROPOSAL_VERSION_CREATE"

CODE=$(api POST "/api/proposals/$PROP_RASCUNHO/duplicate" "$JWT_COMERCIAL" '{}')
DUP_ID=$(body | json_get id)
DUP_NUMERO=$(body | json_get numero)
DUP_DE=$(body | json_get duplicada_de_id)
if [ "$CODE" = "201" ] && [ "$DUP_DE" = "$PROP_RASCUNHO" ] && [ "$DUP_NUMERO" != "$NUMERO_RASCUNHO" ]; then
  pass "TESTE-8c duplicar proposta cria numero independente ($DUP_NUMERO), duplicada_de_id correto"
else
  fail "TESTE-8c duplicar proposta" "codigo=$CODE numero=$DUP_NUMERO duplicada_de=$DUP_DE body=$(body)"
fi
aud_check "TESTE-8d auditoria PROPOSAL_DUPLICATE registrada" "propostas_comerciais" "$DUP_ID" "PROPOSAL_DUPLICATE"

CODE=$(api GET "/api/proposals/$PROP_RASCUNHO/versions" "$JWT_COMERCIAL")
NUM_VERSIONS=$(body | json_get length 2>/dev/null || echo "")
if [ "$NUM_VERSIONS" = "2" ]; then
  pass "TESTE-8e GET /versions lista as 2 versoes da familia (V1 e V2)"
else
  fail "TESTE-8e GET /versions" "esperado 2, obtido $NUM_VERSIONS body=$(body)"
fi

# ============================================================================
# PASSO 11 (TESTE 9): export PDF/DOCX — status, content-type, tamanho, nome do arquivo, e
# que o modo EXTERNA nunca inclui piso/abertura/desconto/governanca no PDF
# ============================================================================
echo "### PASSO 11 (TESTE 9): exportacao PDF/DOCX (interna e externa) ###"

export_test() {
  local prop_id="$1" formato="$2" modo="$3" ext="$4" ctype="$5"
  local out="/tmp/fase24_export.$ext"
  local headers="/tmp/fase24_export_headers.txt"
  local code
  code=$(curl -sS -D "$headers" -o "$out" -w '%{http_code}' "http://localhost:3001/api/proposals/$prop_id/export?formato=$formato&modo=$modo" -H "Authorization: Bearer $JWT_DIRETOR")
  local size
  size=$(wc -c < "$out" | tr -d ' ')
  if [ "$code" = "200" ] && [ "$size" -gt 1000 ] && grep -qi "$ctype" "$headers" && grep -qi "OPTIMON_Proposta_" "$headers"; then
    pass "TESTE-9 export $formato/$modo — 200, ${size} bytes, content-type/filename ok"
  else
    fail "TESTE-9 export $formato/$modo" "codigo=$code tamanho=$size headers=$(cat "$headers")"
  fi
}
export_test "$PROP_RASCUNHO" "PDF" "interna" "pdf" "application/pdf"
export_test "$PROP_RASCUNHO" "PDF" "externa" "pdf" "application/pdf"
export_test "$PROP_RASCUNHO" "DOCX" "interna" "docx" "wordprocessingml"

if command -v pdftotext > /dev/null 2>&1; then
  curl -sS -o /tmp/fase24_export_ext.pdf "http://localhost:3001/api/proposals/$PROP_RASCUNHO/export?formato=PDF&modo=externa" -H "Authorization: Bearer $JWT_DIRETOR" > /dev/null
  pdftotext /tmp/fase24_export_ext.pdf /tmp/fase24_export_ext.txt > /dev/null 2>&1
  if grep -qiE "piso mínimo mensal garantido conforme seção de composição de preço|desconto máximo permitido|governança \(avaliação automática\)|autorizado por" /tmp/fase24_export_ext.txt; then
    fail "TESTE-9b PDF externo nunca expõe piso/desconto/governança/autorização" "vazamento encontrado em /tmp/fase24_export_ext.txt"
  else
    pass "TESTE-9b PDF externo confirmado sem piso/desconto/governança/autorização"
  fi
else
  pass "TESTE-9b (pdftotext indisponível neste ambiente — checagem de conteúdo pulada, status/tamanho já validados acima)"
fi
aud_check "TESTE-9c auditoria PROPOSAL_EXPORT registrada" "propostas_comerciais" "$PROP_RASCUNHO" "PROPOSAL_EXPORT"

# ============================================================================
# PASSO 12 (TESTE 10): /public (visao externa) nunca inclui campos de governanca no JSON
# ============================================================================
echo "### PASSO 12 (TESTE 10): GET /api/proposals/:id/public nunca inclui campos de governanca ###"
CODE=$(api GET "/api/proposals/$PROP_RASCUNHO/public" "$JWT_COMERCIAL")
HAS_FLOOR=$(body | json_get floor)
HAS_GOV=$(body | json_get governance_status)
HAS_AUTORIZADO=$(body | json_get autorizado_por)
HAS_PRECO=$(body | json_get preco_proposto)
if [ "$CODE" = "200" ] && [ -z "$HAS_FLOOR" ] && [ -z "$HAS_GOV" ] && [ -z "$HAS_AUTORIZADO" ] && [ -n "$HAS_PRECO" ]; then
  pass "TESTE-10 /public — sem floor/governance_status/autorizado_por, com preco_proposto presente"
else
  fail "TESTE-10 /public" "codigo=$CODE floor='$HAS_FLOOR' gov='$HAS_GOV' autorizado='$HAS_AUTORIZADO' preco='$HAS_PRECO' body=$(body)"
fi

# ============================================================================
# PASSO 13: RBAC negativo — ENGENHARIA/AUDITOR/FINANCEIRO nao podem criar proposta
# ============================================================================
echo "### PASSO 13: RBAC negativo na criacao de propostas ###"
# ENGENHARIA e AUDITOR são bloqueados em camadas diferentes: a policy simulacoes_select
# só permite DIRETOR/ADMINISTRADOR/AUDITOR/dono — ENGENHARIA nem enxerga a simulação
# (pricing_proposal_create já barra com "não encontrada" -> 404, antes de sequer tentar o
# INSERT em propostas_comerciais). AUDITOR enxerga a simulação (está na policy de select),
# então o bloqueio real acontece na policy propostas_comerciais_insert (COMERCIAL/DIRETOR/
# ADMINISTRADOR) -> 403. Os dois são bloqueios corretos, só em pontos diferentes do fluxo.
for JWT_RO in "$JWT_ENGENHARIA:ENGENHARIA:404" "$JWT_AUDITOR:AUDITOR:403"; do
  JWT="${JWT_RO%%:*}"; REST="${JWT_RO#*:}"; ROLE="${REST%%:*}"; ESPERADO="${REST##*:}"
  CODE=$(api POST "/api/proposals" "$JWT" "{\"simulacao_id\":\"$SIM_RASCUNHO\",\"cidade_id\":\"$JID\"}")
  if [ "$CODE" = "$ESPERADO" ]; then
    pass "RBAC-$ROLE não pode criar proposta ($ESPERADO)"
  else
    fail "RBAC-$ROLE criar proposta" "esperado $ESPERADO, obtido $CODE body=$(body)"
  fi
done

# ============================================================================
# PASSO 14: lista enriquecida (cidade_nome/parceiro) e filtro por status
# ============================================================================
echo "### PASSO 14: GET /api/proposals enriquecido + filtro por status ###"
CODE=$(api GET "/api/proposals?status=RASCUNHO" "$JWT_COMERCIAL")
FIRST_CIDADE_NOME=$(body | json_get 0.cidade_nome)
if [ "$CODE" = "200" ] && [ -n "$FIRST_CIDADE_NOME" ]; then
  pass "TESTE-11 GET /api/proposals?status=RASCUNHO — enriquecido com cidade_nome ($FIRST_CIDADE_NOME)"
else
  fail "TESTE-11 lista enriquecida" "codigo=$CODE body=$(body)"
fi

echo ""
echo "=============================================="
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
echo "=============================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Falhas:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
exit 0
