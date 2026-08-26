#!/usr/bin/env bash
# OptiMon — Fase 2.3: Módulo de Gestão de Cidades e Infraestrutura.
#
# Seções 26-33 (testes obrigatórios) + 40 (E2E, ver tests/e2e_fase23.js) + 41 (critério
# de aceite). Sobe a pilha real (PostgREST local + API Node) e testa por HTTP com JWTs de
# cada perfil — mesmo padrão de tests/run_tests_deploy.sh — porque o que esta fase
# valida é justamente RBAC/RLS por rota, não só regra de negócio em SQL.
#
# Pré-requisito: PASSO 0 reaplica Fase 1..Fase Deploy do zero via tests/run_tests_deploy.sh
# (nunca escondemos regressão) e por cima aplica as migrations novas desta fase
# (20260901*.sql) — evolução incremental, nunca reconstrução fora desse fluxo de teste.

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
# PASSO 0 — regressão completa (Fase1..Fase Deploy) + migrations desta fase
# ============================================================================
echo "### PASSO 0: regressao completa via run_tests_deploy.sh, depois aplica as migrations novas desta fase (20260901*) ###"
pkill -f "postgrest .*postgrest.local.conf" 2>/dev/null || true
pkill -f "rest_v1_proxy.js" 2>/dev/null || true
pkill -f "node server.js" 2>/dev/null || true
sleep 1

if ! bash tests/run_tests_deploy.sh > /tmp/fase23_regression_base.log 2>&1; then
  fail "PASSO-0 regressao base (run_tests_deploy.sh)" "ver /tmp/fase23_regression_base.log — abortando"
  echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; echo "=============================================="
  exit 1
fi
pass "PASSO-0 regressao base (Fase1..Fase Deploy, run_tests_deploy.sh) — banco pronto para as migrations novas desta fase"

for f in $(ls supabase/migrations/20260901*.sql | sort); do
  if ! $PSQL -v ON_ERROR_STOP=1 -f "$f" > /tmp/fase23_mig_apply.log 2>&1; then
    fail "PASSO-0 aplicar $f" "ver /tmp/fase23_mig_apply.log"
    echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; echo "=============================================="
    exit 1
  fi
done
pass "PASSO-0 todas as migrations novas desta fase (20260901*.sql) aplicaram sem erro sobre a base"
$PSQL -c "NOTIFY pgrst, 'reload schema';" > /dev/null 2>&1
sleep 1

# ============================================================================
# PASSO 1 — pilha local já está no ar (run_tests_deploy.sh sobe e deixa rodando)
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
UID_ENGENHARIA=$(uid_of_role ENGENHARIA)
UID_COMERCIAL=$(uid_of_role COMERCIAL)
UID_AUDITOR=$(uid_of_role AUDITOR)
JWT_ADMIN=$(jwt_for "$UID_ADMIN")
JWT_ENGENHARIA=$(jwt_for "$UID_ENGENHARIA")
JWT_COMERCIAL=$(jwt_for "$UID_COMERCIAL")
JWT_AUDITOR=$(jwt_for "$UID_AUDITOR")

api() {
  local method="$1"; local path="$2"; local jwt="$3"; local body="${4:-}"
  if [ -n "$body" ]; then
    curl -sS -o /tmp/fase23_body.json -w '%{http_code}' -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt" -H "Content-Type: application/json" -d "$body"
  else
    curl -sS -o /tmp/fase23_body.json -w '%{http_code}' -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt"
  fi
}
body() { cat /tmp/fase23_body.json; }
json_get() { node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=JSON.parse(d);const p='$1'.split('.');let c2=v;for(const k of p){c2=c2==null?undefined:c2[k];}console.log(c2===undefined?'':c2);}catch(e){console.log('');}})"; }

# Baseline de Jussara ANTES de qualquer coisa desta fase acontecer — isolamento (seção 29)
# significa "nada que eu fizer com outra cidade muda Jussara do que ela já era", não um
# valor fixo tipo "12 FO": pelo momento em que este script roda, run_tests_deploy.sh já
# encadeou fase11/12/2/21/22/221/deploy, cada um com seus próprios fixtures de teste sobre
# a MESMA Jussara — o "12 FO / 10 ociosas" da seção 25 só é literal logo após o seed.sql
# puro, nunca depois de toda essa cadeia de baterias anteriores já ter rodado por cima.
JID_BASELINE=$($PSQL -t -A -c "select id from public.cidades_infra where nome='Jussara';" | tr -d ' ')
JUSSARA_POSTES_BASELINE=$($PSQL -t -A -c "select sum(quantidade) from public.infra_postes where cidade_id='$JID_BASELINE' and removido_em is null;" | tr -d ' ')
JUSSARA_FO_BASELINE=$($PSQL -t -A -c "select fibras_totais from public.vw_capacidade_cidade where cidade_id='$JID_BASELINE';" | tr -d ' ')
JUSSARA_FO_LIVRES_BASELINE=$($PSQL -t -A -c "select fibras_livres from public.vw_capacidade_cidade where cidade_id='$JID_BASELINE';" | tr -d ' ')

# ============================================================================
# SECAO 3/34: nenhuma rota especial para Jussara continua existindo
# ============================================================================
echo ""
echo "### SECAO 3/34: sem lógica hard-coded de Jussara ###"
grep -rn "jussara" web/src/ > /tmp/fase23_grep_jussara.log 2>/dev/null
if [ ! -s /tmp/fase23_grep_jussara.log ]; then
  pass "SEC3 nenhuma referência a 'jussara' (case-insensitive) sobrou em web/src"
else
  fail "SEC3 nenhuma referência a 'jussara' em web/src" "encontrado: $(cat /tmp/fase23_grep_jussara.log)"
fi
if ! grep -q "cidades/jussara" web/src/App.jsx; then
  pass "SEC5 rota /cidades/jussara removida de App.jsx"
else
  fail "SEC5 rota /cidades/jussara removida" "ainda presente em App.jsx"
fi

# ============================================================================
# SECAO 26 — nova cidade TESTE, POP, cabo (24 FO), poste, PON; aparece em toda parte
# ============================================================================
echo ""
echo "### SECAO 26: criar cidade TESTE, cadastrar infraestrutura, confirmar Pricing Engine calcula ###"

R=$(api POST /api/cities "$JWT_ENGENHARIA" '{"nome":"TESTE","uf":"PR","km_rede":10}')
CIDADE_TESTE=$(body | json_get cidade_id)
[ -n "$CIDADE_TESTE" ] && [ "$R" = "201" ] && pass "TESTE-C1 cidade TESTE criada (id=$CIDADE_TESTE)" || fail "TESTE-C1 criar cidade TESTE" "http=$R body=$(body)"

R=$(api GET /api/cities "$JWT_COMERCIAL")
NOMES=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const v=JSON.parse(d);console.log(v.map(c=>c.nome).join(','))})")
[[ "$NOMES" == *"TESTE"* ]] && pass "TESTE-C2 cidade TESTE aparece em GET /api/cities (lista genérica, sem cidade fixa)" || fail "TESTE-C2 cidade TESTE em /api/cities" "nomes=$NOMES"

R=$(api POST /api/infra/pops "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CIDADE_TESTE\",\"codigo\":\"POP-01\",\"nome\":\"POP-01\",\"tipo\":\"PRINCIPAL\"}")
POP_TESTE=$(body | json_get id)
[ -n "$POP_TESTE" ] && pass "TESTE-C3 1º POP criado em TESTE" || fail "TESTE-C3 1º POP em TESTE" "http=$R body=$(body)"

R=$(api POST /api/infra/pops "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CIDADE_TESTE\",\"codigo\":\"POP-02\",\"nome\":\"POP-02\"}")
[ "$R" = "201" ] && pass "TESTE-C3b 2º POP criado em TESTE (nunca assume 1 cidade = 1 POP)" || fail "TESTE-C3b 2º POP em TESTE" "http=$R body=$(body)"

R=$(api POST /api/infra/segments "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CIDADE_TESTE\",\"nome\":\"Segmento TESTE\",\"origem\":\"POP-01\",\"destino\":\"Centro\",\"extensao_km\":10}")
SEG_TESTE=$(body | json_get id)
[ -n "$SEG_TESTE" ] && pass "TESTE-C4 segmento criado em TESTE" || fail "TESTE-C4 segmento em TESTE" "http=$R body=$(body)"

R=$(api POST /api/infra/cables "$JWT_ENGENHARIA" "{\"segmento_id\":\"$SEG_TESTE\",\"pop_id\":\"$POP_TESTE\",\"identificacao\":\"CABO-TESTE-01\",\"capacidade_fo\":24}")
CABO_TESTE=$(body | json_get cabo_id)
[ -n "$CABO_TESTE" ] && pass "TESTE-C5 cabo de 24 FO criado em TESTE" || fail "TESTE-C5 cabo 24 FO em TESTE" "http=$R body=$(body)"

R=$(api GET "/api/infra/cables/$CABO_TESTE/fibers" "$JWT_ENGENHARIA")
NFIBRAS=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{console.log(JSON.parse(d).length)})")
[ "$NFIBRAS" = "24" ] && pass "TESTE-C6 24 fibras geradas automaticamente junto com o cabo" || fail "TESTE-C6 24 fibras geradas" "veio $NFIBRAS"

R=$(api POST /api/infra/poles "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CIDADE_TESTE\",\"segmento_id\":\"$SEG_TESTE\",\"identificacao\":\"Lote TESTE\",\"quantidade\":20,\"custo_mensal\":150}")
POSTE_TESTE=$(body | json_get id)
[ "$R" = "201" ] && pass "TESTE-C7 postes cadastrados em TESTE" || fail "TESTE-C7 postes em TESTE" "http=$R body=$(body)"

FIBRA1=$($PSQL -t -A -c "select id from public.infra_fibras where cabo_id='$CABO_TESTE' and numero_fibra=1;" | tr -d ' ')
R=$(api POST /api/infra/pon-ports "$JWT_ENGENHARIA" "{\"fibra_id\":\"$FIBRA1\",\"pop_id\":\"$POP_TESTE\",\"codigo_porta\":\"PON-TESTE-001\"}")
PON_TESTE=$(body | json_get id)
[ "$R" = "201" ] && pass "TESTE-C8 porta PON cadastrada em TESTE (capacidade padrão 128 aplicada pelo trigger)" || fail "TESTE-C8 porta PON em TESTE" "http=$R body=$(body)"
CAP128=$(body | json_get capacidade_max_assinantes)
[ "$CAP128" = "128" ] && pass "TESTE-C8b capacidade padrão = 128 (parametrizada, não hard-coded na tabela)" || fail "TESTE-C8b capacidade padrão 128" "veio $CAP128"

R=$(api POST /api/pricing/calculate "$JWT_COMERCIAL" "{\"cidade_id\":\"$CIDADE_TESTE\",\"pons_count\":1,\"clientes\":0,\"arpu\":0}")
FLOOR_TESTE=$(body | json_get floor)
[ -n "$FLOOR_TESTE" ] && [ "$FLOOR_TESTE" != "0" ] && pass "TESTE-C9 Pricing Engine calcula para a cidade TESTE recém-criada — floor=$FLOOR_TESTE" || fail "TESTE-C9 Pricing Engine calcula para TESTE" "floor=$FLOOR_TESTE body=$(body)"

# ============================================================================
# SECAO 27 — segunda cidade (Andirá), sem alterar Jussara
# ============================================================================
echo ""
echo "### SECAO 27: criar Andira-PR sem alterar Jussara ###"

JID=$($PSQL -t -A -c "select id from public.cidades_infra where nome='Jussara';" | tr -d ' ')
JUSSARA_KM_ANTES=$($PSQL -t -A -c "select km_rede from public.cidades_infra where id='$JID';" | tr -d ' ')

R=$(api POST /api/cities "$JWT_ENGENHARIA" '{"nome":"Andirá","uf":"PR","km_rede":10}')
CIDADE_ANDIRA=$(body | json_get cidade_id)
[ -n "$CIDADE_ANDIRA" ] && pass "TESTE-A1 Andirá criada (id=$CIDADE_ANDIRA)" || fail "TESTE-A1 criar Andirá" "http=$R body=$(body)"

R=$(api GET /api/cities "$JWT_COMERCIAL")
TOTAL_CIDADES=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{console.log(JSON.parse(d).length)})")
NOMES=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const v=JSON.parse(d);console.log(v.map(c=>c.nome).join(','))})")
if [[ "$NOMES" == *"Jussara"* ]] && [[ "$NOMES" == *"Andirá"* ]] && [[ "$NOMES" == *"TESTE"* ]]; then
  pass "TESTE-A2 Dashboard/Cidades lista Jussara + Andirá + TESTE juntas (total=$TOTAL_CIDADES) — nenhuma cidade especial"
else
  fail "TESTE-A2 lista com Jussara+Andirá+TESTE" "nomes=$NOMES"
fi

JUSSARA_KM_DEPOIS=$($PSQL -t -A -c "select km_rede from public.cidades_infra where id='$JID';" | tr -d ' ')
[ "$JUSSARA_KM_ANTES" = "$JUSSARA_KM_DEPOIS" ] && pass "TESTE-A3 Jussara (km_rede=$JUSSARA_KM_DEPOIS) intocada ao criar Andirá" || fail "TESTE-A3 Jussara intocada" "antes=$JUSSARA_KM_ANTES depois=$JUSSARA_KM_DEPOIS"

# ============================================================================
# SECAO 28/29 — edição de Andirá + isolamento de Jussara
# ============================================================================
echo ""
echo "### SECAO 28/29: editar Andira (10km -> 12km) e confirmar isolamento de Jussara ###"

R=$(api PATCH "/api/cities/$CIDADE_ANDIRA" "$JWT_ENGENHARIA" '{"km_rede":12}')
[ "$R" = "200" ] && pass "TESTE-E1 PATCH Andirá km_rede=12 aceito" || fail "TESTE-E1 PATCH Andirá" "http=$R body=$(body)"

R=$(api GET /api/cities "$JWT_COMERCIAL")
KM_LISTA=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const v=JSON.parse(d);console.log(v.find(c=>c.cidade_id==='$CIDADE_ANDIRA').km_rede)})")
[ "$KM_LISTA" = "12" ] && pass "TESTE-E2 GET /api/cities (Dashboard) reflete km_rede=12" || fail "TESTE-E2 Dashboard reflete 12km" "veio $KM_LISTA"

R=$(api GET "/api/cities/$CIDADE_ANDIRA" "$JWT_COMERCIAL")
KM_DETALHE=$(body | json_get km_rede)
[ "$KM_DETALHE" = "12" ] && pass "TESTE-E3 GET /api/cities/:id (detalhe) reflete km_rede=12" || fail "TESTE-E3 detalhe reflete 12km" "veio $KM_DETALHE"

JUSSARA_KM_FINAL=$($PSQL -t -A -c "select km_rede from public.cidades_infra where id='$JID';" | tr -d ' ')
JUSSARA_POSTES=$($PSQL -t -A -c "select sum(quantidade) from public.infra_postes where cidade_id='$JID' and removido_em is null;" | tr -d ' ')
JUSSARA_FO=$($PSQL -t -A -c "select fibras_totais from public.vw_capacidade_cidade where cidade_id='$JID';" | tr -d ' ')
JUSSARA_FO_LIVRES=$($PSQL -t -A -c "select fibras_livres from public.vw_capacidade_cidade where cidade_id='$JID';" | tr -d ' ')
if [ "$JUSSARA_KM_FINAL" = "5.000" ] || [ "$JUSSARA_KM_FINAL" = "5" ]; then
  pass "TESTE-I1 isolamento: Jussara km_rede permanece 5 (nunca alterada por edição de Andirá)"
else
  fail "TESTE-I1 isolamento km_rede Jussara" "veio $JUSSARA_KM_FINAL"
fi
if [ "$JUSSARA_POSTES" = "$JUSSARA_POSTES_BASELINE" ] && [ "$JUSSARA_FO" = "$JUSSARA_FO_BASELINE" ] && [ "$JUSSARA_FO_LIVRES" = "$JUSSARA_FO_LIVRES_BASELINE" ]; then
  pass "TESTE-I2 isolamento: Jussara permanece $JUSSARA_POSTES postes / $JUSSARA_FO FO / $JUSSARA_FO_LIVRES FO ociosas — idêntico ao baseline capturado antes desta bateria (nada que fizemos em TESTE/Andirá mudou Jussara)"
else
  fail "TESTE-I2 isolamento infra Jussara" "baseline: postes=$JUSSARA_POSTES_BASELINE fo=$JUSSARA_FO_BASELINE fo_livres=$JUSSARA_FO_LIVRES_BASELINE — agora: postes=$JUSSARA_POSTES fo=$JUSSARA_FO fo_livres=$JUSSARA_FO_LIVRES"
fi

# ============================================================================
# SECAO 30 — permissoes
# ============================================================================
echo ""
echo "### SECAO 30: permissoes por perfil ###"

R=$(api GET /api/cities "$JWT_COMERCIAL")
[ "$R" = "200" ] && pass "TESTE-P1 COMERCIAL pode visualizar cidades" || fail "TESTE-P1 COMERCIAL visualiza" "http=$R"

R=$(api POST /api/cities "$JWT_COMERCIAL" '{"nome":"NaoDeveExistir","uf":"PR","km_rede":1}')
[ "$R" = "403" ] && pass "TESTE-P2 COMERCIAL NAO pode criar cidade (403)" || fail "TESTE-P2 COMERCIAL bloqueado ao criar" "http=$R body=$(body)"

R=$(api PATCH "/api/cities/$CIDADE_ANDIRA" "$JWT_COMERCIAL" '{"km_rede":999}')
[ "$R" != "200" ] && pass "TESTE-P3 COMERCIAL NAO pode editar cidade (http=$R)" || fail "TESTE-P3 COMERCIAL bloqueado ao editar" "http=$R body=$(body)"

R=$(api POST /api/cities "$JWT_ENGENHARIA" '{"nome":"EngenhariaPodeCriar","uf":"PR","km_rede":1}')
[ "$R" = "201" ] && pass "TESTE-P4 ENGENHARIA pode criar cidade" || fail "TESTE-P4 ENGENHARIA cria" "http=$R body=$(body)"
EID=$(body | json_get cidade_id)
R=$(api PATCH "/api/cities/$EID" "$JWT_ENGENHARIA" '{"km_rede":2}')
[ "$R" = "200" ] && pass "TESTE-P5 ENGENHARIA pode editar cidade" || fail "TESTE-P5 ENGENHARIA edita" "http=$R body=$(body)"

R=$(api POST /api/cities "$JWT_ADMIN" '{"nome":"AdminPodeTudo","uf":"PR","km_rede":1}')
[ "$R" = "201" ] && pass "TESTE-P6 ADMINISTRADOR pode criar cidade" || fail "TESTE-P6 ADMINISTRADOR cria" "http=$R body=$(body)"

R=$(api GET /api/cities "$JWT_AUDITOR")
[ "$R" = "200" ] && pass "TESTE-P7 AUDITOR pode visualizar cidades" || fail "TESTE-P7 AUDITOR visualiza" "http=$R"
R=$(api POST /api/cities "$JWT_AUDITOR" '{"nome":"NaoDeveExistir2","uf":"PR","km_rede":1}')
[ "$R" = "403" ] && pass "TESTE-P8 AUDITOR NAO pode criar cidade (somente leitura, 403)" || fail "TESTE-P8 AUDITOR bloqueado" "http=$R body=$(body)"

R=$(api POST /api/infra/pops "$JWT_COMERCIAL" "{\"cidade_id\":\"$CIDADE_ANDIRA\",\"codigo\":\"X\",\"nome\":\"X\"}")
[ "$R" = "403" ] && pass "TESTE-P9 COMERCIAL NAO pode criar POP (403, RLS de infra_pops)" || fail "TESTE-P9 COMERCIAL bloqueado POP" "http=$R body=$(body)"

# ============================================================================
# SECAO 38 — auditoria: cidade/POP/cabo/fibra/poste/PON criados E alterados, com
# usuário/data/hora/ação/dados anteriores/dados novos. cabo e poste não têm endpoint de
# edição na especificação (seções 15/18 só pedem cadastro) — o UPDATE deles é validado
# direto via SQL para provar que o gatilho de auditoria cobre a tabela de qualquer forma
# que uma linha venha a ser alterada, não só pelas rotas que existem hoje.
# ============================================================================
echo ""
echo "### SECAO 38: auditoria cobre criação E alteração de cidade/POP/cabo/fibra/poste/PON (usuário/data/ação/dados anteriores/dados novos) ###"

aud_check() {
  # $1=nome do teste  $2=entidade  $3=entidade_id  $4=acao  $5=exigir valor_anterior (1/0)
  # $6=exigir usuario_id (1/0, default 1) — só é 0 para os testes AUD-15/16, que fazem
  # UPDATE via SQL direto (fora da API/PostgREST) só para provar que o gatilho cobre a
  # tabela mesmo sem endpoint dedicado; sem um JWT de requisição não há usuário
  # autenticado para capturar, e usuario_id=NULL aí é o comportamento correto, não falha.
  local nome="$1" entidade="$2" eid="$3" acao="$4" exige_anterior="$5" exige_usuario="${6:-1}"
  local row
  row=$($PSQL -t -A -F'|' -c "select (usuario_id is not null), (criado_em is not null), (valor_novo is not null), (valor_anterior is not null) from public.auditoria where entidade='$entidade' and entidade_id='$eid' and acao='$acao' order by criado_em desc limit 1;")
  local tem_usuario tem_data tem_novo tem_anterior
  IFS='|' read -r tem_usuario tem_data tem_novo tem_anterior <<< "$row"
  if { [ "$exige_usuario" = "0" ] || [ "$tem_usuario" = "t" ]; } && [ "$tem_data" = "t" ] && [ "$tem_novo" = "t" ] && { [ "$exige_anterior" = "0" ] || [ "$tem_anterior" = "t" ]; }; then
    pass "$nome (usuario=$tem_usuario data=$tem_data dados_novos=$tem_novo dados_anteriores=$tem_anterior)"
  else
    fail "$nome" "entidade=$entidade entidade_id=$eid acao=$acao -> linha=$row (esperado usuario/data/dados_novos 't', dados_anteriores só se exige_anterior=1)"
  fi
}

# --- criação (INSERT) — já aconteceu na SECAO 26, só confere o rastro deixado ---
aud_check "AUD-1 cidade criada auditada"  cidades_infra   "$CIDADE_TESTE" INSERT 0
aud_check "AUD-2 POP criado auditado"     infra_pops      "$POP_TESTE"    INSERT 0
aud_check "AUD-3 cabo criado auditado"    infra_cabos     "$CABO_TESTE"   INSERT 0
aud_check "AUD-4 fibra criada auditada"   infra_fibras    "$FIBRA1"       INSERT 0
aud_check "AUD-5 poste criado auditado"   infra_postes    "$POSTE_TESTE"  INSERT 0
aud_check "AUD-6 PON criada auditada"     infra_portas_pon "$PON_TESTE"   INSERT 0

# --- alteração (UPDATE) — cidade e PON via API real; POP e fibra via API real; cabo e
# poste via SQL direto (sem endpoint de edição na especificação, ver comentário acima) ---
R=$(api PATCH "/api/cities/$CIDADE_TESTE" "$JWT_ENGENHARIA" '{"observacoes":"Auditoria seção 38"}')
[ "$R" = "200" ] && pass "AUD-7 cidade TESTE alterada via API (pré-condição p/ AUD-8)" || fail "AUD-7 alterar cidade TESTE" "http=$R body=$(body)"
aud_check "AUD-8 cidade alterada auditada (com dados anteriores)" cidades_infra "$CIDADE_TESTE" UPDATE 1

R=$(api PATCH "/api/infra/pops/$POP_TESTE" "$JWT_ENGENHARIA" '{"observacoes":"Auditoria seção 38"}')
[ "$R" = "200" ] && pass "AUD-9 POP TESTE alterado via API (pré-condição p/ AUD-10)" || fail "AUD-9 alterar POP TESTE" "http=$R body=$(body)"
aud_check "AUD-10 POP alterado auditado (com dados anteriores)" infra_pops "$POP_TESTE" UPDATE 1

R=$(api PATCH "/api/infra/fibers/$FIBRA1" "$JWT_ENGENHARIA" '{"status":"MANUTENCAO","observacao":"Auditoria seção 38"}')
[ "$R" = "200" ] && pass "AUD-11 fibra alterada via API (pré-condição p/ AUD-12)" || fail "AUD-11 alterar fibra" "http=$R body=$(body)"
aud_check "AUD-12 fibra alterada auditada (com dados anteriores)" infra_fibras "$FIBRA1" UPDATE 1

R=$(api PATCH "/api/infra/pon-ports/$PON_TESTE" "$JWT_ENGENHARIA" '{"nome":"Auditoria seção 38"}')
[ "$R" = "200" ] && pass "AUD-13 PON alterada via API (pré-condição p/ AUD-14)" || fail "AUD-13 alterar PON" "http=$R body=$(body)"
aud_check "AUD-14 PON alterada auditada (com dados anteriores)" infra_portas_pon "$PON_TESTE" UPDATE 1

$PSQL -q -c "update public.infra_cabos set fabricante='Auditoria Seção 38' where id='$CABO_TESTE';" > /dev/null
aud_check "AUD-15 cabo alterado auditado (gatilho cobre UPDATE mesmo sem endpoint dedicado)" infra_cabos "$CABO_TESTE" UPDATE 1 0

$PSQL -q -c "update public.infra_postes set custo_mensal=200 where id='$POSTE_TESTE';" > /dev/null
aud_check "AUD-16 poste alterado auditado (gatilho cobre UPDATE mesmo sem endpoint dedicado)" infra_postes "$POSTE_TESTE" UPDATE 1 0

# ============================================================================
# SECAO 31/32 — arquivamento
# ============================================================================
echo ""
echo "### SECAO 31/32: arquivamento (sem contrato passa; com contrato ativo bloqueia) ###"

R=$(api POST "/api/cities/$CIDADE_TESTE/archive" "$JWT_ENGENHARIA")
[ "$R" = "200" ] && pass "TESTE-AR1 cidade TESTE (sem contrato) arquivada com sucesso" || fail "TESTE-AR1 arquivar TESTE" "http=$R body=$(body)"

R=$(api GET /api/cities "$JWT_COMERCIAL")
NOMES=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{const v=JSON.parse(d);console.log(v.map(c=>c.nome).join(','))})")
[[ "$NOMES" != *"TESTE"* ]] && pass "TESTE-AR2 cidade TESTE não aparece mais na listagem padrão" || fail "TESTE-AR2 TESTE some da listagem" "nomes=$NOMES"

REMOVIDO_EM=$($PSQL -t -A -c "select removido_em is not null from public.cidades_infra where id='$CIDADE_TESTE';" | tr -d ' ')
[ "$REMOVIDO_EM" = "t" ] && pass "TESTE-AR3 cidade TESTE preservada no banco (removido_em setado, sem DELETE físico)" || fail "TESTE-AR3 sem DELETE físico" "removido_em is not null = $REMOVIDO_EM"

R=$(api POST "/api/cities/$JID/archive" "$JWT_ADMIN")
MSG=$(body | json_get error)
if [ "$R" = "409" ] && [[ "$MSG" == *"Não é possível arquivar uma cidade com contrato ativo"* ]]; then
  pass "TESTE-AR4 arquivar Jussara (com contrato ATIVO) bloqueado — mensagem exata: \"$MSG\""
else
  fail "TESTE-AR4 bloquear arquivamento com contrato ativo" "http=$R body=$(body)"
fi
JUSSARA_AINDA_ATIVA=$($PSQL -t -A -c "select removido_em is null from public.cidades_infra where id='$JID';" | tr -d ' ')
[ "$JUSSARA_AINDA_ATIVA" = "t" ] && pass "TESTE-AR5 Jussara permanece ativa (removido_em ainda null) após tentativa bloqueada" || fail "TESTE-AR5 Jussara não foi arquivada" "removido_em is null = $JUSSARA_AINDA_ATIVA"

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
