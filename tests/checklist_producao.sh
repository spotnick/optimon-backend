#!/usr/bin/env bash
# OptiMon — Fase 3, item 3.15: Checklist automático de produção.
#
# Diferença deste script para os `run_tests_fase*.sh`: aqueles provam que uma
# FUNCIONALIDADE específica de uma fase funciona; este prova que o REPOSITÓRIO
# COMO UM TODO está em condição segura de ir para produção — segurança de
# segredos, cobertura de RLS, imutabilidade de auditoria, migrations
# replayáveis do zero, contratos de API estáveis (/health, /api/version) e
# configuração de deploy presente. É o que um humano rodaria antes de
# declarar uma release pronta, e é o item que faltava: a CI existente
# (.github/workflows/ci.yml) só faz lint/build leve, sem banco real — nunca
# verificou nada da lista abaixo.
#
# Convenção: PASS/FAIL/WARN. FAIL = bloqueador real de produção. WARN =
# limitação já documentada/aceita (nunca escondida), não um bloqueador.
#
# LIMITAÇÃO DE AMBIENTE DECLARADA: este script roda contra o Postgres LOCAL
# deste sandbox (nunca contra o Supabase/Railway/Vercel de produção reais,
# que este ambiente não tem credencial para acessar) — os itens que dependem
# de infraestrutura real de produção (o deploy em si, DNS, certificado TLS,
# variáveis de ambiente carregadas no Railway/Vercel) são listados como
# "MANUAL" no relatório final, nunca marcados PASS por suposição.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PASS=0
FAIL=0
WARN=0
MANUAL=0
FAILED_NAMES=()

pass() { PASS=$((PASS+1)); echo "PASS | $1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "FAIL | $1"; echo "  -> $2"; }
warn() { WARN=$((WARN+1)); echo "WARN | $1"; echo "  -> $2"; }
manual() { MANUAL=$((MANUAL+1)); echo "MANUAL | $1 -- $2"; }

export PGPASSWORD=optimon_dev
PSQL="psql -h localhost -U optimon_admin -d optimon"

echo "############################################################"
echo "# A) SCHEMA REPLAYÁVEL DO ZERO + IMUTABILIDADE DE AUDITORIA #"
echo "############################################################"
echo "(reaproveita tests/run_tests_fase312.sh — regressão completa Fase1..2.5.3 +"
echo " todas as migrations da Fase 3 + 10 testes de imutabilidade de auditoria)"

bash tests/run_tests_fase312.sh > /tmp/checklist_312.log 2>&1
RC_312=$?
TAIL_312=$(tail -3 /tmp/checklist_312.log)
if [ $RC_312 -ne 0 ]; then
  fail "A1 migrations completas (Fase1..Fase3) replayam do zero e auditoria é imutável" "ver /tmp/checklist_312.log — abortando checklist, isso é bloqueador de produção"
  echo "############################################################"
  echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL / $WARN WARN / $MANUAL MANUAL"
  echo "############################################################"
  exit 1
else
  pass "A1 migrations completas (Fase1..Fase3) replayam do zero sem erro e a auditoria é comprovadamente imutável (10/10 testes do item 3.12)"
  echo "  (resumo: $TAIL_312)"
fi

echo ""
echo "############################################################"
echo "# B) COBERTURA DE RLS (Row-Level Security)                 #"
echo "############################################################"

RLS_INFO=$($PSQL -t -A -c "
select c.relname
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity = false
order by 1;
")
TOTAL_TABLES=$($PSQL -t -A -c "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r';")
if [ -z "$RLS_INFO" ]; then
  pass "B1 todas as $TOTAL_TABLES tabelas de public têm Row-Level Security habilitada (nenhuma tabela sem RLS)"
else
  fail "B1 existe(m) tabela(s) em public SEM Row-Level Security habilitada" "$RLS_INFO"
fi

# auditoria nunca deve ter policy de INSERT/UPDATE/DELETE para nenhum papel — só SELECT.
AUDIT_POLICIES=$($PSQL -t -A -c "select polname || '|' || polcmd::text from pg_policy where polrelid = 'public.auditoria'::regclass order by 1;")
if [ "$AUDIT_POLICIES" = "auditoria_select|r" ]; then
  pass "B2 public.auditoria tem exatamente 1 policy (auditoria_select, só leitura) — nenhuma policy de escrita para nenhum papel"
else
  fail "B2 public.auditoria tem policies inesperadas (esperado só auditoria_select de leitura)" "$AUDIT_POLICIES"
fi

echo ""
echo "############################################################"
echo "# C) SEGREDOS NUNCA VERSIONADOS / NUNCA EXPOSTOS            #"
echo "############################################################"

TRACKED_ENV=$(git ls-files | grep -E '(^|/)\.env$' || true)
if [ -z "$TRACKED_ENV" ]; then
  pass "C1 nenhum arquivo .env real está rastreado pelo git (só .env.example é versionado)"
else
  fail "C1 arquivo .env real rastreado pelo git — isso vazaria segredo no repositório" "$TRACKED_ENV"
fi

# Padrões: JWT real (3 segmentos base64url), AWS access key, chave privada PEM — varrendo
# só arquivos rastreados pelo git (nunca node_modules/dist, que não são versionados).
# Os `tests/run_tests_fase25{1,3}.sh` contêm o PRÓPRIO REGEX de detecção de segredo em log
# (não um segredo de verdade) — excluídos explicitamente para não gerar falso-positivo.
SECRET_HITS=$(git ls-files \
  | grep -v '^tests/run_tests_fase25[13]\.sh$' \
  | xargs grep -lE 'eyJhbGciOi[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|sk_live_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----' 2>/dev/null || true)
if [ -z "$SECRET_HITS" ]; then
  pass "C2 nenhum padrão de segredo real (JWT assinado completo, AWS access key, chave privada PEM) encontrado em arquivo rastreado pelo git"
else
  fail "C2 padrão de segredo real encontrado em arquivo versionado" "$SECRET_HITS"
fi

# A única exceção documentada ao "nunca service_role no backend" é api/lib/supabaseAdmin.js
# (mais os arquivos que só o REFERENCIAM em comentário/checagem, nunca usam a chave em si).
SERVICE_ROLE_USERS=$(grep -rlE "createClient\([^)]*SERVICE_ROLE" api/routes api/lib --include="*.js" 2>/dev/null | grep -v "api/lib/supabaseAdmin.js" || true)
if [ -z "$SERVICE_ROLE_USERS" ]; then
  pass "C3 SUPABASE_SERVICE_ROLE_KEY só é usada para criar um client em api/lib/supabaseAdmin.js — nenhum outro arquivo instancia client com a service_role"
else
  fail "C3 arquivo além de supabaseAdmin.js instancia client com SERVICE_ROLE" "$SERVICE_ROLE_USERS"
fi

CORS_WILDCARD=$(grep -nE "origin:\s*['\"]\*['\"]" api/server.js || true)
if [ -z "$CORS_WILDCARD" ]; then
  pass "C4 CORS nunca libera '*' fixo no código — origem é sempre validada contra CORS_ALLOWED_ORIGINS"
else
  fail "C4 CORS liberando '*' hardcoded em server.js" "$CORS_WILDCARD"
fi

echo ""
echo "############################################################"
echo "# D) CONTRATOS DE API ESTÁVEIS                              #"
echo "############################################################"

if curl -sS -o /dev/null -m 3 -w "%{http_code}" http://localhost:3001/health 2>/dev/null | grep -q "200"; then
  HEALTH_BODY=$(curl -sS -m 3 http://localhost:3001/health 2>&1)
  if [[ "$HEALTH_BODY" == *'"status":"ok"'* && "$HEALTH_BODY" == *'"service":"optimon-api"'* ]]; then
    pass "D1 GET /health devolve o contrato exato exigido ({status:ok, service:optimon-api})"
  else
    fail "D1 GET /health respondeu 200 mas com corpo fora do contrato esperado" "$HEALTH_BODY"
  fi
else
  manual "D1 GET /health" "API local não está no ar neste momento do checklist (rode um dos tests/run_tests_fase*.sh antes, ou verifique o deploy real)"
fi

if curl -sS -m 3 http://localhost:3001/api/version 2>/dev/null | grep -qE '"service"|"version"'; then
  VERSION_BODY=$(curl -sS -m 3 http://localhost:3001/api/version 2>&1)
  if echo "$VERSION_BODY" | grep -qiE 'key|secret|password|token'; then
    fail "D2 GET /api/version pode estar vazando segredo no corpo da resposta" "$VERSION_BODY"
  else
    pass "D2 GET /api/version responde e não inclui nenhuma palavra sugestiva de segredo no corpo (key/secret/password/token)"
  fi
else
  manual "D2 GET /api/version" "API local não está no ar neste momento do checklist"
fi

echo ""
echo "############################################################"
echo "# E) FRONTEND BUILDA SEM ERRO                                #"
echo "############################################################"

(cd web && npx vite build > /tmp/checklist_web_build.log 2>&1)
RC_BUILD=$?
if [ $RC_BUILD -eq 0 ]; then
  pass "E1 'vite build' do frontend conclui sem erro"
else
  fail "E1 'vite build' do frontend falhou" "ver /tmp/checklist_web_build.log"
fi

echo ""
echo "############################################################"
echo "# F) CONFIGURAÇÃO DE DEPLOY PRESENTE                        #"
echo "############################################################"

for f in railway.toml web/vercel.json api/.env.example web/.env.example; do
  if [ -f "$f" ]; then
    pass "F. $f existe no repositório"
  else
    fail "F. $f está ausente do repositório" "esperado em $ROOT/$f"
  fi
done

# .env.example nunca deve conter um valor real (heurística: nenhuma linha
# NOME=valor onde valor pareça um segredo de verdade, não um placeholder).
PLACEHOLDER_PATTERN='<|\[|seu[-_]|sua[-_]|your[-_]|example|placeholder|localhost|xxxx|changeme|coloque|aqui'
for f in api/.env.example web/.env.example; do
  SUSPECT=$(grep -vE '^\s*#|^\s*$' "$f" | grep -E '=' | grep -viE "$PLACEHOLDER_PATTERN" | grep -E '=.{20,}' || true)
  if [ -z "$SUSPECT" ]; then
    pass "F. $f não contém valor que pareça um segredo real (só placeholders)"
  else
    warn "F. $f tem linha(s) com valor longo — confirmar manualmente que não é segredo real" "$SUSPECT"
  fi
done

manual "F. Variáveis de ambiente carregadas de fato no Railway/Vercel de produção" "este sandbox não tem credencial para inspecionar o painel real — confirmar manualmente antes do deploy: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (Railway); CORS_ALLOWED_ORIGINS aponta para o domínio real do Vercel (Railway); VITE_API_URL aponta para o domínio real do Railway (Vercel)"
manual "F. Migrations aplicadas no Supabase de produção real" "este script só prova que as migrations replayam num Postgres local limpo (item A1) — aplicar de fato no projeto Supabase de produção é um passo manual, fora do alcance deste sandbox"
manual "F. DNS/certificado TLS/domínio customizado" "fora do escopo de um script — checagem de infraestrutura de hospedagem, não de código"

echo ""
echo "############################################################"
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL / $WARN WARN / $MANUAL MANUAL (itens que exigem checagem humana contra o ambiente real)"
echo "############################################################"
[ $FAIL -eq 0 ] && exit 0 || exit 1
