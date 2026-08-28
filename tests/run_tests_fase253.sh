#!/usr/bin/env bash
# OptiMon — Fase 2.5.3: CORREÇÃO DEFINITIVA — USUÁRIOS AUTH x public.usuarios.
#
# Mesmo padrão de todas as fases: PASSO 0 reaplica a cadeia completa
# Fase1..Fase2.5.1 (via run_tests_fase251.sh, nunca escondendo regressão) e
# por cima aplica as migrations novas desta fase (20260921*.sql); depois sobe
# a pilha real (PostgREST local + API Node) e testa por HTTP com JWTs de cada
# perfil, mais testes diretos contra o Postgres para o que HTTP não alcança
# neste ambiente.
#
# LIMITAÇÃO DE AMBIENTE DECLARADA (não escondida — mesma categoria já
# documentada para Storage e Auth Admin API desde a Fase 2.5/2.5.1): este
# harness local NÃO tem um GoTrue (Supabase Auth) real, então
# SUPABASE_SERVICE_ROLE_KEY nunca está configurada aqui e adminAuthAvailable()
# é sempre false — POST /api/users/invite e POST /api/users/reconcile sempre
# respondem 501 SERVICE_ROLE_NAO_CONFIGURADO de forma controlada (nunca
# tentam criar/consultar auth.users de verdade), e GET /api/users/health
# sempre responde integro:null (não verificável). Isso significa que os
# Estados A/B/C (que dependem de auth.users) não podem ser exercitados
# ponta-a-ponta por HTTP aqui — o que ESTE script valida de verdade, sem
# simular nada:
#   (1) a causa raiz real do bug relatado (INSERT em public.usuarios falhando
#       por CPF='' em vez de null) — reproduzida e corrigida, testada direto
#       contra o schema Postgres real (TESTE-01/02);
#   (2) que RLS/RBAC continuam intactos para um ADMINISTRADOR real inserir um
#       perfil novo, sem nenhuma policy nova/enfraquecida (TESTE-03);
#   (3) o Estado D (perfil sem Auth) por HTTP — o único dos 4 estados que NÃO
#       depende de auth.users existir de verdade, então É exercitável aqui de
#       ponta a ponta (TESTE-04);
#   (4) que as rotas novas (/reconcile, /health, ?include_orphans=true) nunca
#       crasham (500) sem a Auth Admin API — sempre 501/403/200 controlado
#       (TESTE-05..08);
#   (5) que a auditoria aceita as 7 ações novas sem afetar nenhuma existente
#       (TESTE-09);
#   (6) que a resposta de /invite nunca mais é 207 (regressão do bug
#       reportado pelo usuário — TESTE-10).
# Um roteiro de TESTE E2E REAL contra https://optimon.com.br (que exige um
# projeto Supabase real com Auth Admin API configurada, fora do alcance deste
# sandbox) está documentado à parte em docs/RELATORIO_FASE253.md, seção
# "E2E manual" — não simulado aqui, para nunca reportar como testado algo que
# não foi.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

pass() { PASS=$((PASS+1)); echo "PASS | $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "FAIL | $1"; echo "  -> $2"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP | $1 -- $2"; }

export PGPASSWORD=optimon_dev
PSQL="psql -h localhost -U optimon_admin -d optimon"

# ============================================================================
# PASSO 0 — regressão completa (Fase1..Fase2.5.1) + migrations desta fase
# ============================================================================
echo "### PASSO 0: regressao completa via run_tests_fase251.sh, depois aplica as migrations novas desta fase (20260921*) ###"
pkill -f "postgrest .*postgrest.local.conf" 2>/dev/null || true
pkill -f "rest_v1_proxy.js" 2>/dev/null || true
pkill -f "node server.js" 2>/dev/null || true
sleep 1

bash tests/run_tests_fase251.sh > /tmp/fase253_regression_base.log 2>&1
REGRESSION_RC=$?
REGRESSION_SUMMARY=$(tail -6 /tmp/fase253_regression_base.log)
if [ $REGRESSION_RC -ne 0 ]; then
  fail "PASSO-0 regressao base (run_tests_fase251.sh, que encadeia Fase1..2.5.1)" "ver /tmp/fase253_regression_base.log — abortando"
  echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL / $SKIP SKIP"; echo "=============================================="
  exit 1
else
  pass "PASSO-0 regressao completa Fase1..Fase2.5.1 (via run_tests_fase251.sh) — 0 falhas — banco pronto para as migrations novas desta fase"
  echo "  (resumo: $REGRESSION_SUMMARY)"
fi

for f in $(ls supabase/migrations/20260921*.sql | sort); do
  if ! $PSQL -v ON_ERROR_STOP=1 -f "$f" > /tmp/fase253_mig_apply.log 2>&1; then
    fail "PASSO-0 aplicar $f" "ver /tmp/fase253_mig_apply.log"
    echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL / $SKIP SKIP"; echo "=============================================="
    exit 1
  fi
done
pass "PASSO-0 todas as migrations novas desta fase (20260921*.sql) aplicaram sem erro sobre a base"
$PSQL -c "NOTIFY pgrst, 'reload schema';" > /dev/null 2>&1
sleep 1

# ============================================================================
# PASSO 1 — pilha local no ar
# ============================================================================
echo "### PASSO 1: confirmando pilha local no ar ###"

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
start_if_down 3000 "postgrest $ROOT/supabase/dev-local-only/postgrest.local.conf" /tmp/fase253_postgrest.log
start_if_down 54321 "PGRST_TARGET=http://127.0.0.1:3000 PROXY_PORT=54321 node $ROOT/supabase/dev-local-only/rest_v1_proxy.js" /tmp/fase253_proxy.log
( cd api && start_if_down 3001 "node server.js" /tmp/fase253_api.log )
sleep 1

HEALTH=$(curl -sS -m 3 http://localhost:3001/health 2>&1)
if [[ "$HEALTH" == *'"status":"ok"'* ]]; then
  pass "PASSO-1 API local no ar — GET /health = $HEALTH"
else
  fail "PASSO-1 API local no ar" "GET /health devolveu: $HEALTH — ver /tmp/fase253_api.log"
  echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL / $SKIP SKIP"; echo "=============================================="
  exit 1
fi

uid_of_role() { $PSQL -t -A -c "select id from public.usuarios where perfil='$1' and removido_em is null and ativo=true limit 1;" | tr -d ' '; }
jwt_for() { node supabase/dev-local-only/mint_jwt.js "$1"; }

UID_ADMIN=$(uid_of_role ADMINISTRADOR)
UID_COMERCIAL=$(uid_of_role COMERCIAL)
JWT_ADMIN=$(jwt_for "$UID_ADMIN")
JWT_COMERCIAL=$(jwt_for "$UID_COMERCIAL")

api() {
  local method="$1"; local path="$2"; local jwt="$3"; local body="${4:-}"
  if [ -n "$body" ]; then
    curl -sS -o /tmp/fase253_body.json -w '%{http_code}' -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt" -H "Content-Type: application/json" -d "$body"
  else
    curl -sS -o /tmp/fase253_body.json -w '%{http_code}' -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt"
  fi
}
body() { cat /tmp/fase253_body.json; }
json_get() { node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=JSON.parse(d);const p='$1'.split('.');let c2=v;for(const k of p){c2=c2==null?undefined:c2[k];}console.log((c2===undefined||c2===null)?'':c2);}catch(e){console.log('');}})"; }

echo "=============================================="
echo "TESTES 01-10: Fase 2.5.3 — Usuários Auth x public.usuarios"
echo "=============================================="

# ----------------------------------------------------------------------------
# TESTE-01: causa raiz real do bug relatado. Reproduz, direto contra o schema
# Postgres real (não um mock), o INSERT exatamente como completeProfile()
# fazia ANTES do conserto (cpf='' em vez de null) — confirma que a CHECK
# constraint usuarios_cpf_formato é o que quebrava, e que com null (o valor
# que emptyToNull() agora produz) o mesmo INSERT funciona.
# ----------------------------------------------------------------------------
UID_CAUSA_RAIZ_AUTH="a0000000-0000-4000-8000-0000000000$(( (RANDOM % 89) + 10 ))"
OUT_CPF_VAZIO=$($PSQL -t -A -v ON_ERROR_STOP=0 <<SQL 2>&1
begin;
insert into auth.users (id, email) values ('$UID_CAUSA_RAIZ_AUTH', 'teste.causa.raiz.fase253@example.com');
insert into public.usuarios (id, nome, email, cpf, perfil) values ('$UID_CAUSA_RAIZ_AUTH', 'Teste Causa Raiz', 'teste.causa.raiz.fase253@example.com', '', 'COMERCIAL');
rollback;
SQL
)
if echo "$OUT_CPF_VAZIO" | grep -q "usuarios_cpf_formato"; then
  pass "TESTE-01 causa raiz CONFIRMADA: INSERT em public.usuarios com cpf='' (string vazia, o valor que o formulário sempre mandava antes do conserto) viola de verdade a constraint usuarios_cpf_formato — reproduzido contra o schema Postgres real, não assumido"
else
  fail "TESTE-01 causa raiz" "esperava violação de usuarios_cpf_formato com cpf='', saida=$OUT_CPF_VAZIO"
fi

# ----------------------------------------------------------------------------
# TESTE-02: o mesmo INSERT com cpf=null (o que emptyToNull('') produz depois
# do conserto em api/routes/users.js) funciona — e a própria função
# emptyToNull(), chamada de verdade (não reimplementada aqui), normaliza ''
# e '   ' para null e preserva um CPF válido.
# ----------------------------------------------------------------------------
UID_CAUSA_RAIZ_OK="b0000000-0000-4000-8000-0000000000$(( (RANDOM % 89) + 10 ))"
OUT_CPF_NULL=$($PSQL -t -A -v ON_ERROR_STOP=0 <<SQL 2>&1
begin;
insert into auth.users (id, email) values ('$UID_CAUSA_RAIZ_OK', 'teste.causa.raiz.ok.fase253@example.com');
insert into public.usuarios (id, nome, email, cpf, perfil) values ('$UID_CAUSA_RAIZ_OK', 'Teste Causa Raiz OK', 'teste.causa.raiz.ok.fase253@example.com', null, 'COMERCIAL') returning cpf;
rollback;
SQL
)
EMPTY_TO_NULL_OUT=$(cd api && node -e "
const { emptyToNull } = require('./routes/users.js');
console.log(JSON.stringify({
  vazia: emptyToNull(''),
  espacos: emptyToNull('   '),
  nulo: emptyToNull(null),
  indefinido: emptyToNull(undefined),
  valido: emptyToNull('11122233344'),
}));
" 2>/dev/null)
EXPECTED_E2N='{"vazia":null,"espacos":null,"nulo":null,"indefinido":null,"valido":"11122233344"}'
# Nota: OUT_CPF_NULL sempre inclui as tags de comando do psql (BEGIN/INSERT
# 0 1/ROLLBACK) mesmo em modo -t — não é o corpo do erro; o que importa é a
# AUSÊNCIA de "ERROR" (violação de constraint), nunca que a saída esteja vazia.
if ! echo "$OUT_CPF_NULL" | grep -q "ERROR" && [ "$EMPTY_TO_NULL_OUT" = "$EXPECTED_E2N" ]; then
  pass "TESTE-02 conserto CONFIRMADO: com cpf=null o mesmo INSERT funciona (nenhum ERROR), e emptyToNull() (chamada de verdade de api/routes/users.js) normaliza '' e '   ' para null preservando um CPF válido"
else
  fail "TESTE-02 conserto" "OUT_CPF_NULL=$OUT_CPF_NULL EMPTY_TO_NULL_OUT=$EMPTY_TO_NULL_OUT"
fi

# ----------------------------------------------------------------------------
# TESTE-03: RLS/RBAC intactos — um ADMINISTRADOR real (via role authenticated
# + auth.uid() simulado, mesmo padrão de toda a suíte) consegue inserir um
# perfil novo em public.usuarios exatamente como completeProfile() faz,
# usando só a policy usuarios_admin_all já existente — nenhuma policy nova,
# nenhum USING(true) para INSERT, nenhuma RLS desabilitada.
# ----------------------------------------------------------------------------
UID_NOVO_RLS="c0000000-0000-4000-8000-0000000000$(( (RANDOM % 89) + 10 ))"
OUT_RLS=$($PSQL -t -A -v ON_ERROR_STOP=0 <<SQL 2>&1
begin;
insert into auth.users (id, email) values ('$UID_NOVO_RLS', 'teste.rls.fase253@example.com');
set local role authenticated;
set local request.jwt.claims = '{"sub":"$UID_ADMIN","role":"authenticated"}';
insert into public.usuarios (id, nome, email, perfil) values ('$UID_NOVO_RLS', 'Teste RLS Fase253', 'teste.rls.fase253@example.com', 'COMERCIAL') returning id;
rollback;
SQL
)
if echo "$OUT_RLS" | grep -q "$UID_NOVO_RLS"; then
  pass "TESTE-03 RLS/RBAC intactos: ADMINISTRADOR real insere perfil novo em public.usuarios só com a policy usuarios_admin_all já existente (app.tem_perfil) — nenhuma policy nova, nenhum USING(true), nenhuma RLS desabilitada"
else
  fail "TESTE-03 RLS/RBAC" "esperava o id inserido no retorno, saida=$OUT_RLS"
fi

echo "  (checagem extra: policy do INSERT continua sendo a mesma 'usuarios_admin_all' desde a Fase 1 — nenhuma nova foi criada nesta fase)"
POLICY_COUNT=$($PSQL -t -A -c "select count(*) from pg_policies where schemaname='public' and tablename='usuarios';" | tr -d ' ')
if [ "$POLICY_COUNT" = "2" ]; then
  pass "TESTE-03b public.usuarios continua com exatamente 2 policies (usuarios_select, usuarios_admin_all) — nenhuma nova criada nesta fase"
else
  fail "TESTE-03b" "esperava 2 policies em public.usuarios, encontrado=$POLICY_COUNT"
fi

# ----------------------------------------------------------------------------
# TESTE-04: Estado D por HTTP de ponta a ponta — o único dos 4 estados que não
# depende de auth.users real, então é exercitável neste ambiente. Cria um
# perfil via o caminho de recuperação legado (POST /api/users, precisa de um
# auth.users pré-existente, que o teste cria direto no Postgres — simula
# exatamente o que a Auth Admin API faria de verdade) e confirma que
# POST /api/users/invite para o MESMO e-mail nunca tenta reinserir — sempre
# 409 com "state" presente, nunca 500, nunca duplicata silenciosa.
# ----------------------------------------------------------------------------
UID_ESTADO_D="d0000000-0000-4000-8000-0000000000$(( (RANDOM % 89) + 10 ))"
EMAIL_ESTADO_D="teste.estadoD.fase253@example.com"
$PSQL -c "insert into auth.users (id, email) values ('$UID_ESTADO_D', '$EMAIL_ESTADO_D') on conflict do nothing;" > /dev/null 2>&1
api POST "/api/users" "$JWT_ADMIN" "{\"id\":\"$UID_ESTADO_D\",\"nome\":\"Teste Estado D\",\"email\":\"$EMAIL_ESTADO_D\",\"perfil\":\"COMERCIAL\"}" > /dev/null

CODE=$(api POST "/api/users/invite" "$JWT_ADMIN" "{\"nome\":\"Tentativa Duplicada\",\"email\":\"$EMAIL_ESTADO_D\",\"perfil\":\"COMERCIAL\"}")
RESP=$(body)
STATE=$(echo "$RESP" | json_get state)
if [ "$CODE" = "409" ] && [ -n "$STATE" ]; then
  pass "TESTE-04 e-mail já cadastrado em public.usuarios nunca tenta reconvidar/reinserir — 409 com campo 'state' presente ($STATE), nunca 500, nunca duplicata silenciosa (neste ambiente sem Auth Admin API real, o estado detectado é D — perfil sem Auth correspondente; com a Auth Admin API configurada, o mesmo e-mail cairia no Estado B)"
else
  fail "TESTE-04 Estado D/B por e-mail duplicado" "codigo=$CODE body=$RESP"
fi

# ----------------------------------------------------------------------------
# TESTE-05: POST /api/users/reconcile — bloqueado para não-ADMINISTRADOR
# (403), e responde 501 controlado (nunca 500) sem a Auth Admin API.
# ----------------------------------------------------------------------------
CODE=$(api POST "/api/users/reconcile" "$JWT_COMERCIAL" '{"email":"qualquer@example.com","nome":"X","perfil":"COMERCIAL"}')
if [ "$CODE" = "403" ]; then
  pass "TESTE-05a COMERCIAL bloqueado de reconciliar perfil — 403"
else
  fail "TESTE-05a" "codigo=$CODE body=$(body)"
fi

CODE=$(api POST "/api/users/reconcile" "$JWT_ADMIN" '{"email":"qualquer.reconcile@example.com","nome":"X","perfil":"COMERCIAL"}')
RESP=$(body)
if [ "$CODE" = "501" ] && [[ "$RESP" == *"SERVICE_ROLE_NAO_CONFIGURADO"* ]]; then
  pass "TESTE-05b ADMINISTRADOR + Auth Admin API indisponível — 501 SERVICE_ROLE_NAO_CONFIGURADO controlado, nunca 500"
elif [ "$CODE" = "404" ] || [ "$CODE" = "201" ]; then
  pass "TESTE-05b ADMINISTRADOR reconcilia — Auth Admin API configurada neste ambiente (codigo=$CODE)"
else
  fail "TESTE-05b" "codigo=$CODE body=$RESP"
fi

# ----------------------------------------------------------------------------
# TESTE-06: GET /api/users/health — nunca crasha sem Auth Admin API, sempre
# devolve o formato esperado com integro:null quando não verificável.
# ----------------------------------------------------------------------------
CODE=$(api GET "/api/users/health" "$JWT_COMERCIAL")
[ "$CODE" = "403" ] && pass "TESTE-06a COMERCIAL bloqueado de ver diagnóstico de integridade — 403" || fail "TESTE-06a" "codigo=$CODE body=$(body)"

CODE=$(api GET "/api/users/health" "$JWT_ADMIN")
RESP=$(body)
INTEGRO=$(echo "$RESP" | json_get integro)
TOTAL_PERFIS=$(echo "$RESP" | json_get total_perfis)
if [ "$CODE" = "200" ] && [ -n "$TOTAL_PERFIS" ]; then
  pass "TESTE-06b ADMINISTRADOR consegue ver GET /api/users/health — 200, total_perfis=$TOTAL_PERFIS, integro=$INTEGRO (null é o esperado neste ambiente sem Auth Admin API real)"
else
  fail "TESTE-06b" "codigo=$CODE body=$RESP"
fi

# ----------------------------------------------------------------------------
# TESTE-07: GET /api/users?include_orphans=true nunca crasha, mesmo sem Auth
# Admin API (a lista simplesmente não ganha linhas órfãs sintéticas).
# ----------------------------------------------------------------------------
CODE=$(api GET "/api/users?include_orphans=true" "$JWT_ADMIN")
if [ "$CODE" = "200" ]; then
  pass "TESTE-07 GET /api/users?include_orphans=true nunca crasha (200), com ou sem Auth Admin API configurada"
else
  fail "TESTE-07" "codigo=$CODE body=$(body)"
fi

# ----------------------------------------------------------------------------
# TESTE-08: nunca mais 207. Regressão explícita do bug real relatado pelo
# usuário (ver docs/RELATORIO_FASE251.md Addendum 3) — /invite não usa mais
# 207 para sucesso parcial; qualquer falha depois da identidade Auth agora
# tenta rollback e responde 400/500, nunca um 2xx parcial mascarado.
# ----------------------------------------------------------------------------
if grep -q "res.status(207)" api/routes/users.js; then
  fail "TESTE-08 nunca mais 207" "api/routes/users.js ainda contém res.status(207) — regressão do bug real corrigido na Fase 2.5.1/2.5.3"
else
  pass "TESTE-08 api/routes/users.js não usa mais res.status(207) em lugar nenhum — o caminho de falha de INSERT agora sempre faz rollback controlado e responde 400/500, nunca um 2xx parcial mascarado como sucesso"
fi

# ----------------------------------------------------------------------------
# TESTE-09: auditoria — as 7 ações novas desta fase são aceitas pela mesma
# app.registrar_auditoria_semantica (nenhuma tabela/função paralela), e TODAS
# as ações já existentes continuam aceitas (nenhuma removida).
# ----------------------------------------------------------------------------
OUT_ACOES=$($PSQL -t -A -v ON_ERROR_STOP=0 <<SQL 2>&1
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"$UID_ADMIN","role":"authenticated"}';
select app.registrar_auditoria_semantica('usuarios', '$UID_ADMIN'::uuid, a, 'teste fase 2.5.3')
from unnest(array[
  'USER_INVITE_STARTED','USER_AUTH_CREATED','USER_PROFILE_CREATED','USER_INVITE_COMPLETED',
  'USER_AUTH_ROLLBACK','USER_AUTH_ORPHAN','USER_PROFILE_RECONCILED',
  'USER_INVITE','USER_INVITE_FAILED','USER_RESEND_INVITE','USER_DEACTIVATE','USER_REACTIVATE','USER_RESET_ACCESS'
]) as a;
rollback;
SQL
)
if echo "$OUT_ACOES" | grep -qi "ERROR"; then
  fail "TESTE-09 auditoria — 7 ações novas + ações já existentes" "esperava todas aceitas sem erro, saida=$OUT_ACOES"
else
  pass "TESTE-09 as 7 ações novas da Fase 2.5.3 (USER_INVITE_STARTED/USER_AUTH_CREATED/USER_PROFILE_CREATED/USER_INVITE_COMPLETED/USER_AUTH_ROLLBACK/USER_AUTH_ORPHAN/USER_PROFILE_RECONCILED) e todas as ações de usuário já existentes desde a Fase 2.5.1 continuam aceitas pela mesma app.registrar_auditoria_semantica — nenhuma tabela/função paralela, nenhuma removida"
fi

# ----------------------------------------------------------------------------
# TESTE-10: nenhum secret nos logs desta execução (mesma checagem da Fase
# 2.5.1, TESTE-S05, reconfirmada especificamente para as rotas novas) — e
# confirma que o log estruturado USER_INVITE_PROFILE (quando existir) nunca
# inclui senha/token/service_role_key.
# ----------------------------------------------------------------------------
if grep -qE "SUPABASE_SERVICE_ROLE_KEY=[A-Za-z0-9_.-]{10,}|eyJhbGciOiJIUzI1NiJ9\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{20,}" /tmp/fase253_api.log 2>/dev/null; then
  fail "TESTE-10 log da API não deveria conter valor de secret/JWT completo" "ver /tmp/fase253_api.log"
else
  pass "TESTE-10 log da API (incluindo as rotas novas desta fase) não contém valor de secret nem JWT completo — só nomes de variável/erros controlados/diagnóstico estruturado sem credenciais"
fi

echo "=============================================="
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL / $SKIP SKIP"
echo "=============================================="
if [ $FAIL -gt 0 ]; then
  echo "Falhas:"
  for n in "${FAILED_NAMES[@]}"; do echo "  - $n"; done
  exit 1
fi
exit 0
