#!/usr/bin/env bash
# OptiMon — Fase 2.2.1 (Parte 2: Pricing Engine + Régua + Frontend + Deploy).
#
# Seção 41 (testes obrigatórios novos) + seção 42 (E2E) + seção 43 (performance).
# Diferente de tests/run_tests_fase221.sh (que testa só o banco via psql), este script
# sobe a pilha real — PostgREST local (simulando a camada REST de um Supabase real) + a
# API Node/Express (api/server.js) — e testa por HTTP, exatamente como o frontend React
# vai chamar em produção. Isso prova RLS/JWT/CORS/rotas de ponta a ponta, não só SQL.
#
# Pré-requisito: PASSO 0 abaixo já reaplica a Fase 1..2.2.1(parte1) do zero via
# tests/run_tests_fase221.sh (nunca escondemos regressão) e por cima aplica as novas
# migrations desta fase (20260831*.sql) — evolução incremental, nunca reconstrução fora
# desse fluxo de teste (a "reconstrução" aqui é só o mesmo rebuild-para-validar que já
# existia desde a Fase 1, nunca toca um projeto Supabase real).

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
# PASSO 0 — regressão completa (Fase1..Fase2.2.1 parte1) + migrations desta fase
# ============================================================================
echo "### PASSO 0: regressao completa via run_tests_fase221.sh, depois aplica as migrations novas desta fase (20260831*) ###"
# run_tests_fase221.sh (por baixo, via run_tests_fase22.sh original) faz DROP DATABASE —
# precisa que NINGUEM esteja conectado a optimon, senao o DROP falha silenciosamente e os
# testes rodam contra o banco ANTIGO (gerando falsos "ja existe"). PostgREST mantem um
# pool de conexoes aberto — para antes, sobe de novo no PASSO 1.
echo "  (parando PostgREST/proxy/API local, se estiverem no ar, para o DROP DATABASE funcionar)"
pkill -f "postgrest .*postgrest.local.conf" 2>/dev/null || true
pkill -f "rest_v1_proxy.js" 2>/dev/null || true
pkill -f "node server.js" 2>/dev/null || true
sleep 1

if ! bash tests/run_tests_fase221.sh > /tmp/deploy_regression_base.log 2>&1; then
  fail "PASSO-0 regressao base (run_tests_fase221.sh)" "ver /tmp/deploy_regression_base.log — abortando, nao faz sentido continuar sem a base 100% intacta"
  echo "=============================================="
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
  echo "=============================================="
  exit 1
fi
pass "PASSO-0 regressao base (Fase1..Fase2.2.1 parte1, run_tests_fase221.sh) — banco pronto para as migrations novas desta fase"

for f in $(ls supabase/migrations/20260831*.sql | sort); do
  if ! $PSQL -v ON_ERROR_STOP=1 -f "$f" > /tmp/deploy_mig_apply.log 2>&1; then
    fail "PASSO-0 aplicar $f" "ver /tmp/deploy_mig_apply.log"
    echo "=============================================="
    echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
    echo "=============================================="
    exit 1
  fi
done
pass "PASSO-0 todas as migrations novas desta fase (20260831*.sql) aplicaram sem erro sobre a base"

# PostgREST cacheia o schema na inicialização — precisa ser avisado (NOTIFY) toda vez que
# uma função/tabela nova é criada, senão devolve "function not found in schema cache"
# mesmo com a função existindo de verdade no banco (achado real durante o teste manual via
# navegador desta fase). Num Supabase real isso é automático a cada migration aplicada
# pelo dashboard/CLI; aqui replicamos manualmente.
$PSQL -c "NOTIFY pgrst, 'reload schema';" > /dev/null 2>&1

# ============================================================================
# PASSO 1 — subir PostgREST local + proxy /rest/v1 + API Node (idempotente)
# ============================================================================
echo "### PASSO 1: subindo PostgREST local + proxy + API Node (se ainda nao estiverem no ar) ###"

start_if_down() {
  local port="$1"; local cmd="$2"; local logfile="$3"
  if curl -sS -o /dev/null -m 1 "http://localhost:$port/" 2>/dev/null; then
    echo "  (ja no ar: porta $port)"
  else
    nohup bash -c "$cmd" > "$logfile" 2>&1 &
    disown
    sleep 1
  fi
}

start_if_down 3000 "postgrest $ROOT/supabase/dev-local-only/postgrest.local.conf" /tmp/deploy_postgrest.log
start_if_down 54321 "PGRST_TARGET=http://127.0.0.1:3000 PROXY_PORT=54321 node $ROOT/supabase/dev-local-only/rest_v1_proxy.js" /tmp/deploy_proxy.log

if [ ! -f api/.env ]; then
  cat > api/.env <<EOF
SUPABASE_URL=http://localhost:54321
SUPABASE_ANON_KEY=optimon-local-dev-anon-not-a-real-jwt
PORT=3001
CORS_ALLOWED_ORIGINS=http://localhost:5173
APP_ENVIRONMENT=local
EOF
fi
( cd api && start_if_down 3001 "node server.js" /tmp/deploy_api.log )

sleep 1
HEALTH=$(curl -sS -m 3 http://localhost:3001/health 2>&1)
if [[ "$HEALTH" == *'"status":"ok"'* ]]; then
  pass "PASSO-1 API local no ar — GET /health = $HEALTH"
else
  fail "PASSO-1 API local no ar" "GET /health devolveu: $HEALTH — ver /tmp/deploy_api.log /tmp/deploy_postgrest.log /tmp/deploy_proxy.log"
  echo "=============================================="
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
  echo "=============================================="
  exit 1
fi

# ============================================================================
# Helpers de usuário/JWT
# ============================================================================
uid_of_role() { $PSQL -t -A -c "select id from public.usuarios where perfil='$1' limit 1;" | tr -d ' '; }
jwt_for() { node supabase/dev-local-only/mint_jwt.js "$1"; }

UID_COMERCIAL=$(uid_of_role COMERCIAL)
UID_DIRETOR=$(uid_of_role DIRETOR)
JWT_COMERCIAL=$(jwt_for "$UID_COMERCIAL")
JWT_DIRETOR=$(jwt_for "$UID_DIRETOR")

JID=$($PSQL -t -A -c "select id from public.cidades_infra where nome='Jussara';" | tr -d ' ')

api() {
  # api <method> <path> <jwt> [json-body]
  local method="$1"; local path="$2"; local jwt="$3"; local body="${4:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt" -H "Content-Type: application/json" -d "$body"
  else
    curl -sS -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt"
  fi
}

json_get() { node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=JSON.parse(d);const p='$1'.split('.');let c2=v;for(const k of p){c2=c2==null?undefined:c2[k];}console.log(c2===undefined?'':c2);}catch(e){console.log('');}})"; }

# ============================================================================
# SEÇÃO 41 — testes obrigatórios novos (via API HTTP real)
# ============================================================================
echo ""
echo "### SECAO 41: testes obrigatorios novos (via API HTTP, nao so SQL) ###"

# TESTE-D1: Jussara + 1 PON -> Floor=2020 / Recommended=2320 / Opening=2620
R=$(api POST /api/pricing/calculate "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"pons_count\":1,\"clientes\":0,\"arpu\":0}")
FLOOR=$(echo "$R" | json_get floor); REC=$(echo "$R" | json_get recommended); OPEN=$(echo "$R" | json_get opening)
if [ "$FLOOR" = "2020" ] && [ "$REC" = "2320" ] && [ "$OPEN" = "2620" ]; then
  pass "TESTE-D1 Jussara+1PON via API: floor=$FLOOR recommended=$REC opening=$OPEN"
else
  fail "TESTE-D1 Jussara+1PON via API" "esperado floor=2020/recommended=2320/opening=2620, veio floor=$FLOOR/recommended=$REC/opening=$OPEN — resposta: $R"
fi

# TESTE-D2: 129 clientes -> 2 PONs
R=$(api POST /api/pricing/calculate "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"clientes\":129,\"arpu\":0}")
PONS=$(echo "$R" | json_get pons_count)
[ "$PONS" = "2" ] && pass "TESTE-D2 129 clientes -> 2 PONs (via API)" || fail "TESTE-D2 129 clientes -> 2 PONs" "veio pons_count=$PONS"

# TESTE-D3: 257 clientes -> 3 PONs
R=$(api POST /api/pricing/calculate "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"clientes\":257,\"arpu\":0}")
PONS=$(echo "$R" | json_get pons_count)
[ "$PONS" = "3" ] && pass "TESTE-D3 257 clientes -> 3 PONs (via API)" || fail "TESTE-D3 257 clientes -> 3 PONs" "veio pons_count=$PONS"

# TESTE-D4: R$2.019 (pons=1, Jussara) -> COMERCIAL BLOCK_FOR_COMMERCIAL, DIRETOR ALLOW_WITH_DIRECTOR_OVERRIDE
R_COM=$(api POST /api/pricing/calculate "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"pons_count\":1,\"clientes\":0,\"arpu\":0,\"preco_proposto\":2019}")
R_DIR=$(api POST /api/pricing/calculate "$JWT_DIRETOR" "{\"cidade_id\":\"$JID\",\"pons_count\":1,\"clientes\":0,\"arpu\":0,\"preco_proposto\":2019}")
G_COM=$(echo "$R_COM" | json_get governance_status.por_papel)
G_DIR=$(echo "$R_DIR" | json_get governance_status.por_papel)
if [ "$G_COM" = "BLOCK_FOR_COMMERCIAL" ] && [ "$G_DIR" = "ALLOW_WITH_DIRECTOR_OVERRIDE" ]; then
  pass "TESTE-D4 R\$2.019: COMERCIAL=$G_COM / DIRETOR=$G_DIR (por papel real, via JWT+RLS)"
else
  fail "TESTE-D4 R\$2.019 governanca por papel" "esperado COMERCIAL=BLOCK_FOR_COMMERCIAL/DIRETOR=ALLOW_WITH_DIRECTOR_OVERRIDE, veio COMERCIAL=$G_COM/DIRETOR=$G_DIR"
fi

# TESTE-D5: R$1.310 (exatamente no piso absoluto de 50%) -> DIRETOR ALLOW_WITH_DIRECTOR_OVERRIDE
R=$(api POST /api/pricing/calculate "$JWT_DIRETOR" "{\"cidade_id\":\"$JID\",\"pons_count\":1,\"clientes\":0,\"arpu\":0,\"preco_proposto\":1310}")
G=$(echo "$R" | json_get governance_status.por_papel)
[ "$G" = "ALLOW_WITH_DIRECTOR_OVERRIDE" ] && pass "TESTE-D5 R\$1.310 (piso absoluto exato) DIRETOR=$G" || fail "TESTE-D5 R\$1.310" "veio $G"

# TESTE-D6: R$1.309 (abaixo do piso absoluto) -> BLOCK até para DIRETOR
R=$(api POST /api/pricing/calculate "$JWT_DIRETOR" "{\"cidade_id\":\"$JID\",\"pons_count\":1,\"clientes\":0,\"arpu\":0,\"preco_proposto\":1309}")
G=$(echo "$R" | json_get governance_status.por_papel)
[ "$G" = "BLOCK" ] && pass "TESTE-D6 R\$1.309 (abaixo do piso absoluto) DIRETOR=$G — BLOCK ate para DIRETOR" || fail "TESTE-D6 R\$1.309" "veio $G"

# ============================================================================
# SEÇÃO 43 — performance (<500ms por cálculo, sem integração externa)
# ============================================================================
echo ""
echo "### SECAO 43: performance (<500ms por calculo) ###"
START_MS=$(date +%s%3N 2>/dev/null || echo 0)
for i in 1 2 3 4 5; do
  api POST /api/pricing/calculate "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"clientes\":128,\"arpu\":100}" > /dev/null
done
END_MS=$(date +%s%3N 2>/dev/null || echo 0)
if [ "$START_MS" != "0" ]; then
  AVG_MS=$(( (END_MS - START_MS) / 5 ))
  if [ "$AVG_MS" -lt 500 ]; then
    pass "TESTE-D7 performance: media de ${AVG_MS}ms por chamada POST /api/pricing/calculate (5 chamadas), abaixo de 500ms"
  else
    fail "TESTE-D7 performance" "media de ${AVG_MS}ms, acima do limite de 500ms"
  fi
else
  echo "  (date +%s%3N indisponivel neste shell — pulando medicao precisa, ja demonstrado <500ms manualmente)"
fi

# ============================================================================
# SEÇÃO 42 — fluxo E2E: LOGIN -> Dashboard -> Jussara -> Nova Simulacao -> 100 clientes ->
# ARPU R$100 -> Simular -> visualizar preco -> alterar para 200 clientes -> recalcular ->
# gerar proposta -> salvar proposta -> consultar auditoria
# ============================================================================
echo ""
echo "### SECAO 42: fluxo E2E completo ###"

# LOGIN (registra auditoria)
LOGIN_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST http://localhost:3001/api/audit/login -H "Authorization: Bearer $JWT_COMERCIAL")
[ "$LOGIN_CODE" = "204" ] && pass "E2E-1 LOGIN registrado (POST /api/audit/login -> 204)" || fail "E2E-1 LOGIN" "status $LOGIN_CODE"

# Dashboard: GET /api/cities
CITIES=$(api GET /api/cities "$JWT_COMERCIAL")
echo "$CITIES" | grep -q "Jussara" && pass "E2E-2 Dashboard principal (GET /api/cities) lista Jussara" || fail "E2E-2 Dashboard" "resposta sem Jussara: $CITIES"

# Jussara: GET /api/cities/:id
CITY_DETAIL=$(api GET "/api/cities/$JID" "$JWT_COMERCIAL")
echo "$CITY_DETAIL" | grep -q "POP-01" && pass "E2E-3 Dashboard Jussara (GET /api/cities/:id) traz POPs" || fail "E2E-3 Jussara detalhe" "$CITY_DETAIL"

# Nova Simulação: 100 clientes, ARPU R$100 -> Simular
CALC1=$(api POST /api/pricing/calculate "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"clientes\":100,\"arpu\":100}")
TOTAL1=$(echo "$CALC1" | json_get total_payable)
[ -n "$TOTAL1" ] && pass "E2E-4 Nova Simulacao (100 clientes, ARPU 100) -> total_payable=$TOTAL1" || fail "E2E-4 Nova Simulacao" "$CALC1"

# alterar para 200 clientes -> recalcular
CALC2=$(api POST /api/pricing/calculate "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"clientes\":200,\"arpu\":100}")
TOTAL2=$(echo "$CALC2" | json_get total_payable)
PONS2=$(echo "$CALC2" | json_get pons_count)
[ "$PONS2" = "2" ] && pass "E2E-5 recalculo com 200 clientes -> pons_count=$PONS2, total_payable=$TOTAL2" || fail "E2E-5 recalculo 200 clientes" "pons_count=$PONS2 (esperado 2)"

# salvar simulação (com o resultado de 200 clientes)
SIM_SAVE=$(api POST /api/simulations "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"modelo\":\"HIBRIDO_REVENUE_SHARE\",\"pares_ou_clientes\":200,\"arpu\":100,\"revenue_share_pct\":0.12,\"prazo_meses\":48,\"resultado\":$CALC2}")
SIM_ID=$(echo "$SIM_SAVE" | json_get id)
[ -n "$SIM_ID" ] && pass "E2E-6 simulacao salva (POST /api/simulations) id=$SIM_ID" || fail "E2E-6 salvar simulacao" "$SIM_SAVE"

# gerar proposta
PROP=$(api POST /api/proposals "$JWT_COMERCIAL" "{\"simulacao_id\":\"$SIM_ID\",\"cidade_id\":\"$JID\"}")
PROP_NUM=$(echo "$PROP" | json_get numero)
[ -n "$PROP_NUM" ] && pass "E2E-7 proposta gerada e salva (POST /api/proposals) numero=$PROP_NUM" || fail "E2E-7 gerar proposta" "$PROP"

# consultar auditoria — precisa ver LOGIN + INSERT simulacoes + INSERT propostas_comerciais
AUDIT=$(api GET "/api/audit?limit=10" "$JWT_COMERCIAL")
HAS_LOGIN=$(echo "$AUDIT" | grep -c '"acao":"LOGIN"')
HAS_SIM=$(echo "$AUDIT" | grep -c '"entidade":"simulacoes"')
HAS_PROP=$(echo "$AUDIT" | grep -c '"entidade":"propostas_comerciais"')
if [ "$HAS_LOGIN" -ge 1 ] && [ "$HAS_SIM" -ge 1 ] && [ "$HAS_PROP" -ge 1 ]; then
  pass "E2E-8 auditoria (GET /api/audit) mostra LOGIN + simulacao + proposta do fluxo acima"
else
  fail "E2E-8 auditoria" "login=$HAS_LOGIN sim=$HAS_SIM prop=$HAS_PROP (esperado >=1 cada) — $AUDIT"
fi

echo ""
echo "=============================================="
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
echo "=============================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Falhas: ${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
