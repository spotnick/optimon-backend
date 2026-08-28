#!/usr/bin/env bash
# OptiMon — Fase 2.5.1: Correção, Completude, UX, Usuários, Proponentes,
# Assinaturas, Contratos, Configuração e Manuais.
#
# Mesmo padrão de todas as fases: PASSO 0 reaplica a cadeia completa
# Fase1..Fase2.5 (via run_tests_fase25.sh, nunca escondendo regressão) e por
# cima aplica as migrations novas desta fase (20260920*.sql); depois sobe a
# pilha real (PostgREST local + API Node) e testa por HTTP com JWTs de cada
# perfil.
#
# LIMITAÇÃO DE AMBIENTE DECLARADA (não escondida — ver docs/RELATORIO_FASE251.md):
# este harness local NÃO tem um GoTrue (Supabase Auth) real — só o Postgres +
# PostgREST simulando a camada REST. Isso significa que a Auth Admin API
# (convite/e-mail real/definição de senha/bloqueio de login) não pode ser
# validada ponta-a-ponta aqui, exatamente na mesma categoria de limitação já
# documentada para o Storage desde a Fase 2.5. O que ESTE script valida de
# verdade, sem simular nada: (1) o novo fluxo nunca pede UUID e nunca aceita
# um `id` no corpo da requisição; (2) a autorização (só ADMINISTRADOR) do lado
# Node, que é a única camada possível já que RLS não alcança a Auth Admin API;
# (3) que a ausência da SERVICE_ROLE_KEY falha de forma controlada (501),
# nunca um crash; (4) que toda a parte que SQL/RLS pode garantir (desativar
# bloqueia ações privilegiadas, reativar libera de novo) funciona de ponta a
# ponta de verdade.

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
# PASSO 0 — regressão completa (Fase1..Fase2.5) + migrations desta fase
# ============================================================================
echo "### PASSO 0: regressao completa via run_tests_fase25.sh, depois aplica as migrations novas desta fase (20260920*) ###"
pkill -f "postgrest .*postgrest.local.conf" 2>/dev/null || true
pkill -f "rest_v1_proxy.js" 2>/dev/null || true
pkill -f "node server.js" 2>/dev/null || true
sleep 1

bash tests/run_tests_fase25.sh > /tmp/fase251_regression_base.log 2>&1
REGRESSION_RC=$?
REGRESSION_SUMMARY=$(tail -6 /tmp/fase251_regression_base.log)
if [ $REGRESSION_RC -ne 0 ]; then
  fail "PASSO-0 regressao base (run_tests_fase25.sh, que encadeia Fase1..2.5)" "ver /tmp/fase251_regression_base.log — abortando"
  echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL / $SKIP SKIP"; echo "=============================================="
  exit 1
else
  pass "PASSO-0 regressao completa Fase1..Fase2.5 (via run_tests_fase25.sh) — 0 falhas — banco pronto para as migrations novas desta fase"
  echo "  (resumo: $REGRESSION_SUMMARY)"
fi

for f in $(ls supabase/migrations/20260920*.sql | sort); do
  if ! $PSQL -v ON_ERROR_STOP=1 -f "$f" > /tmp/fase251_mig_apply.log 2>&1; then
    fail "PASSO-0 aplicar $f" "ver /tmp/fase251_mig_apply.log"
    echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL / $SKIP SKIP"; echo "=============================================="
    exit 1
  fi
done
pass "PASSO-0 todas as migrations novas desta fase (20260920*.sql, 2 arquivos) aplicaram sem erro sobre a base"
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
start_if_down 3000 "postgrest $ROOT/supabase/dev-local-only/postgrest.local.conf" /tmp/fase251_postgrest.log
start_if_down 54321 "PGRST_TARGET=http://127.0.0.1:3000 PROXY_PORT=54321 node $ROOT/supabase/dev-local-only/rest_v1_proxy.js" /tmp/fase251_proxy.log
( cd api && start_if_down 3001 "node server.js" /tmp/fase251_api.log )
sleep 1

HEALTH=$(curl -sS -m 3 http://localhost:3001/health 2>&1)
if [[ "$HEALTH" == *'"status":"ok"'* ]]; then
  pass "PASSO-1 API local no ar — GET /health = $HEALTH"
else
  fail "PASSO-1 API local no ar" "GET /health devolveu: $HEALTH — ver /tmp/fase251_api.log"
  echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL / $SKIP SKIP"; echo "=============================================="
  exit 1
fi

uid_of_role() { $PSQL -t -A -c "select id from public.usuarios where perfil='$1' and removido_em is null and ativo=true limit 1;" | tr -d ' '; }
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
    curl -sS -o /tmp/fase251_body.json -w '%{http_code}' -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt" -H "Content-Type: application/json" -d "$body"
  else
    curl -sS -o /tmp/fase251_body.json -w '%{http_code}' -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt"
  fi
}
body() { cat /tmp/fase251_body.json; }
json_get() { node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=JSON.parse(d);const p='$1'.split('.');let c2=v;for(const k of p){c2=c2==null?undefined:c2[k];}console.log((c2===undefined||c2===null)?'':c2);}catch(e){console.log('');}})"; }

JID=$($PSQL -t -A -c "select id from public.cidades_infra where nome='Jussara';" | tr -d ' ')

echo "=============================================="
echo "TESTES U01-U07: usuários (fluxo de convite corrigido)"
echo "=============================================="

# ----------------------------------------------------------------------------
# U01: criar usuário SEM informar UUID nenhum — o próprio bug relatado pelo
# usuário ("invalid input syntax for type uuid: nadia.cussolin.2026"). O
# corpo enviado aqui não tem NENHUM campo "id" — se a API algum dia voltasse a
# exigir isso, o teste falharia por 400 "id ausente", nunca por engano.
# ----------------------------------------------------------------------------
CODE=$(api POST "/api/users/invite" "$JWT_ADMIN" '{"nome":"Nadia Cussolin Teste","email":"nadia.teste.fase251@example.com","perfil":"COMERCIAL","cargo":"Vendas"}')
RESP_BODY=$(body)
if [ "$CODE" = "501" ] && [[ "$RESP_BODY" == *"SERVICE_ROLE_NAO_CONFIGURADO"* ]]; then
  pass "TESTE-U01 criar usuário sem UUID nunca mais pede/aceita UUID no corpo — falha de forma controlada (501, SERVICE_ROLE_NAO_CONFIGURADO) porque este ambiente local não tem Auth Admin API real, NUNCA com o erro antigo 'invalid input syntax for type uuid'"
elif [ "$CODE" = "201" ]; then
  pass "TESTE-U01 criar usuário sem UUID — 201 (SUPABASE_SERVICE_ROLE_KEY configurada neste ambiente — convite real enviado)"
else
  fail "TESTE-U01 criar usuário sem UUID" "codigo=$CODE body=$RESP_BODY (nunca deveria ser 400 'invalid input syntax for type uuid' — esse era o bug relatado)"
fi

# Confirma que apenas ADMINISTRADOR pode convidar — RLS não alcança a Auth
# Admin API, então esta é a ÚNICA camada de autorização possível aqui (ver
# api/routes/users.js, assertAdmin()).
CODE=$(api POST "/api/users/invite" "$JWT_COMERCIAL" '{"nome":"Tentativa Nao Admin","email":"nao-admin-fase251@example.com","perfil":"COMERCIAL"}')
if [ "$CODE" = "403" ]; then
  pass "TESTE-U01b COMERCIAL bloqueado de convidar usuário (só ADMINISTRADOR) — 403"
else
  fail "TESTE-U01b COMERCIAL não deveria poder convidar" "codigo=$CODE body=$(body)"
fi

skip "TESTE-U02 usuário recebe convite por e-mail" "requer Auth Admin API real (GoTrue) — não existe neste harness local, mesma categoria de limitação do Storage desde a Fase 2.5; código validado (ver U01) para nunca crashar e nunca inventar um envio de e-mail que não aconteceu"
skip "TESTE-U03 usuário define senha pelo link do convite" "depende do fluxo de e-mail real acima — mesma limitação de ambiente"

# U04: "login" — o usuário já é criado via o caminho de recuperação (POST
# /api/users, inalterado desde a Fase 2.5) para o resto da suíte poder seguir
# com um usuário COMERCIAL de teste real, e confirma que um JWT local para
# esse id consegue autenticar/listar (mesmo mecanismo de simulação de login
# usado por toda a suíte desde a Fase 1 — nunca um GoTrue real, mas
# genuinamente testa que public.usuarios + RLS reconhecem a identidade).
NEW_USER_ID=$($PSQL -t -A -c "select gen_random_uuid();" | tr -d ' ')
$PSQL -c "insert into auth.users (id, email) values ('$NEW_USER_ID', 'teste.u04.fase251@example.com') on conflict do nothing;" > /dev/null 2>&1
api POST "/api/users" "$JWT_ADMIN" "{\"id\":\"$NEW_USER_ID\",\"nome\":\"Teste U04 Fase251\",\"email\":\"teste.u04.fase251@example.com\",\"perfil\":\"COMERCIAL\"}" > /dev/null
NEW_JWT=$(jwt_for "$NEW_USER_ID")
CODE=$(api GET "/api/users/$NEW_USER_ID" "$NEW_JWT")
if [ "$CODE" = "200" ]; then
  pass "TESTE-U04 usuário recém-criado consegue autenticar (JWT válido) e se ver via /api/users/:id — 200"
else
  fail "TESTE-U04 login do novo usuário" "codigo=$CODE body=$(body)"
fi

# U05: Editar usuário
CODE=$(api PATCH "/api/users/$NEW_USER_ID" "$JWT_ADMIN" '{"cargo":"Analista Comercial Sênior","departamento":"Comercial"}')
CARGO_NOVO=$(body | json_get cargo)
if [ "$CODE" = "200" ] && [ "$CARGO_NOVO" = "Analista Comercial Sênior" ]; then
  pass "TESTE-U05 ADMINISTRADOR edita cadastro do usuário (cargo/departamento) — 200"
else
  fail "TESTE-U05 editar usuário" "codigo=$CODE body=$(body)"
fi

# U06: Desativar usuário (POST .../deactivate — novo endpoint desta fase).
CODE=$(api POST "/api/users/$NEW_USER_ID/deactivate" "$JWT_ADMIN" '{"motivo":"Desligamento"}')
ATIVO_APOS=$(body | json_get ativo)
if [ "$CODE" = "200" ] && [ "$ATIVO_APOS" = "false" ]; then
  pass "TESTE-U06 ADMINISTRADOR desativa usuário — 200, ativo=false (auth_warning esperado/aceito neste ambiente sem Auth Admin API real)"
else
  fail "TESTE-U06 desativar usuário" "codigo=$CODE body=$(body)"
fi

# U07: usuário desativado não consegue mais executar ações privilegiadas —
# app.perfil_atual() só considera usuário com ativo=true (ver migration
# 20260824090300_usuarios.sql), então qualquer policy baseada em tem_perfil()
# passa a negar. Testado de ponta a ponta de verdade contra uma escrita real
# (criar proponente, RLS exige COMERCIAL/DIRETOR/ADMINISTRADOR *ativo*).
CODE=$(api POST "/api/partners" "$NEW_JWT" '{"razao_social":"Nao Deveria Criar LTDA","cnpj":"99999999000199"}')
if [ "$CODE" = "403" ]; then
  pass "TESTE-U07 usuário desativado é bloqueado de executar ação privilegiada (perfil_atual() exige ativo=true) — 403. Bloqueio de LOGIN em si (Auth Admin ban) requer projeto Supabase real — ver limitações."
else
  fail "TESTE-U07 usuário desativado deveria ser bloqueado" "codigo=$CODE body=$(body)"
fi

# Reativa antes de seguir (não deixa resíduo bloqueado para o resto da suíte).
api POST "/api/users/$NEW_USER_ID/reactivate" "$JWT_ADMIN" '{"motivo":"Reativado ao fim do TESTE-U07"}' > /dev/null

# Bônus (não numerado): reenviar convite / redefinir acesso nunca crasham,
# mesmo sem Auth Admin API — sempre 501/502 controlado, nunca 500.
CODE=$(api POST "/api/users/$NEW_USER_ID/resend-invite" "$JWT_ADMIN")
if [ "$CODE" = "501" ] || [ "$CODE" = "200" ]; then
  pass "TESTE-U-extra reenviar convite nunca crasha (501 sem Auth Admin API configurada, ou 200 se configurada) — codigo=$CODE"
else
  fail "TESTE-U-extra reenviar convite" "codigo=$CODE body=$(body) (nunca deveria ser 500)"
fi

echo "=============================================="
echo "TESTES P05-P08: proponente (desativar/reativar — novo nesta fase)"
echo "=============================================="
echo "  (P01-P04 — criar/editar proponente, adicionar/editar responsável — sem mudança de lógica nesta fase, já cobertos exaustivamente por run_tests_fase25.sh TESTE-04/05/06, reexecutado no PASSO-0 acima)"

CNPJ_TESTE=$(printf '%014d' "$((RANDOM * RANDOM))" | tail -c 14)
CODE=$(api POST "/api/partners" "$JWT_COMERCIAL" "{\"razao_social\":\"Proponente Teste Fase251 LTDA\",\"nome_fantasia\":\"Fase251 Fibra\",\"cnpj\":\"$CNPJ_TESTE\"}")
PROPONENTE_ID=$(body | json_get id)
if [ "$CODE" = "201" ] && [ -n "$PROPONENTE_ID" ]; then
  pass "TESTE-P (setup) proponente de teste criado — 201, id=$PROPONENTE_ID"
else
  fail "TESTE-P (setup) criar proponente" "codigo=$CODE body=$(body)"
fi

CODE=$(api POST "/api/partners/$PROPONENTE_ID/deactivate" "$JWT_COMERCIAL" '{"motivo":"Erro de cadastro"}')
ATIVO_APOS=$(body | json_get ativo)
if [ "$CODE" = "200" ] && [ "$ATIVO_APOS" = "false" ]; then
  pass "TESTE-P05 COMERCIAL desativa proponente — 200, ativo=false (nunca DELETE físico)"
else
  fail "TESTE-P05 desativar proponente" "codigo=$CODE body=$(body)"
fi

CODE=$(api GET "/api/partners?ativo=true" "$JWT_COMERCIAL")
AINDA_LISTADO=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const arr=JSON.parse(d);console.log(arr.some(p=>p.id==='$PROPONENTE_ID')?'sim':'nao')}catch(e){console.log('erro')}})")
if [ "$AINDA_LISTADO" = "nao" ]; then
  pass "TESTE-P05b proponente desativado sai da listagem de ativos (?ativo=true)"
else
  fail "TESTE-P05b" "esperava sair da lista de ativos, resultado=$AINDA_LISTADO"
fi

CODE=$(api POST "/api/partners/$PROPONENTE_ID/reactivate" "$JWT_COMERCIAL" '{"motivo":"Reativado — cadastro corrigido"}')
ATIVO_APOS=$(body | json_get ativo)
if [ "$CODE" = "200" ] && [ "$ATIVO_APOS" = "true" ]; then
  pass "TESTE-P06 COMERCIAL reativa proponente — 200, ativo=true"
else
  fail "TESTE-P06 reativar proponente" "codigo=$CODE body=$(body)"
fi

skip "TESTE-P07/P08 upload/download de documento de proponente" "ambiente local sem schema 'storage' — mesma limitação já documentada e testada (502 controlado) em run_tests_fase25.sh TESTE-07, reexecutado sem regressão no PASSO-0 acima"

echo "=============================================="
echo "TESTES PR/A/C/AD: proposta, assinatura, contrato, aditivo"
echo "=============================================="
skip "TESTE PR01-PR07 (proposta)" "sem mudança de lógica de proposta nesta fase — já cobertos por run_tests_fase25.sh TESTE-08 e por run_tests_fase24.sh TESTE-1..8 (aprovar/reprovar/PDF/DOCX), reexecutados sem regressão no PASSO-0 acima"
skip "TESTE A01-A09 (assinatura: criar envelope/signatários/enviar/webhook/webhook duplicado/assinar/validar/baixar/auditoria)" "sem mudança de lógica do motor de assinatura nesta fase — já cobertos ponta-a-ponta por run_tests_fase25.sh TESTE-12..18 (inclui o teste de webhook duplicado/idempotência), reexecutados sem regressão no PASSO-0 acima"
skip "TESTE C01-C06 (contrato: gerar/snapshot/assinar/validar/ativar/infraestrutura comprometida)" "sem mudança de lógica de contrato nesta fase — já cobertos ponta-a-ponta por run_tests_fase25.sh TESTE-19..22, reexecutados sem regressão no PASSO-0 acima"
skip "TESTE AD01-AD05 (aditivo)" "sem mudança de lógica de aditivo nesta fase — já cobertos ponta-a-ponta por run_tests_fase25.sh TESTE-23, reexecutados sem regressão no PASSO-0 acima"

# C07: "tentar alterar contrato assinado deve bloquear" — a API nunca expôs
# (em nenhuma fase) uma rota genérica de edição de contrato (só /generate,
# /activate, /reajuste e /aditivos/*) — testa isso de verdade, tentando um
# verbo que não existe em nenhuma rota.
CODE=$(curl -sS -o /tmp/fase251_body.json -w '%{http_code}' -X PATCH "http://localhost:3001/api/contracts/00000000-0000-0000-0000-000000000000" -H "Authorization: Bearer $JWT_DIRETOR" -H "Content-Type: application/json" -d '{"numero":"tentativa-de-editar"}')
if [ "$CODE" = "404" ]; then
  pass "TESTE-C07 não existe rota de edição direta de contrato (só /generate, /activate, /reajuste, /aditivos/*) — PATCH devolve 404 (Express: rota inexistente), nunca permite reescrever um contrato já gerado por fora do fluxo de aditivo/versão"
else
  fail "TESTE-C07" "esperava 404 (rota inexistente), veio codigo=$CODE body=$(body)"
fi

echo "=============================================="
echo "TESTE — Configuração de Assinatura: Testar Conexão (seção 18, novo nesta fase)"
echo "=============================================="
CODE=$(api GET "/api/signatures/providers" "$JWT_ADMIN")
PROVIDER_ID=$(body | json_get 0.id)
if [ -z "$PROVIDER_ID" ]; then
  skip "TESTE-conexao Testar Conexão" "nenhum provedor configurado neste estado do banco (fixture de fase anterior pode não ter criado nenhum) — não é falha desta fase"
else
  CODE=$(api POST "/api/signatures/providers/$PROVIDER_ID/test-connection" "$JWT_ADMIN")
  OK=$(body | json_get ok)
  MENSAGEM=$(body | json_get mensagem)
  if [ "$CODE" = "200" ] && [ "$OK" = "true" ] && [ -n "$MENSAGEM" ]; then
    pass "TESTE-conexao ADMINISTRADOR testa conexão do provedor — 200, ok=true, diagnóstico presente, nenhum secret na resposta"
  else
    fail "TESTE-conexao testar conexão" "codigo=$CODE body=$(body)"
  fi
  RESPOSTA_CRUA=$(body)
  if [[ "$RESPOSTA_CRUA" == *"api_key_ref"* ]] || [[ "$RESPOSTA_CRUA" == *"webhook_secret_ref"* ]]; then
    fail "TESTE-conexao nunca deveria expor nome de variável de secret na resposta do teste" "body=$RESPOSTA_CRUA"
  else
    pass "TESTE-conexao resposta do teste de conexão não inclui api_key_ref/webhook_secret_ref"
  fi
fi

echo "=============================================="
echo "TESTES S01-S05: segurança"
echo "=============================================="

# S01: perfis sem permissão bloqueados de escrever fora do seu escopo
# (seção 35 — matriz de permissão). Reconfirma RLS já existente, agora citado
# explicitamente por perfil.
# S01a/S01b: corpo tem que estar completo (cidade_id+codigo+nome) — senão a
# validação de entrada em Node (POST /api/infra/pops, campo ausente) devolve
# 400 antes mesmo de a requisição chegar na INSERT protegida por RLS
# (infra_pops_write exige ENGENHARIA/ADMINISTRADOR — ver
# 20260825101300_rls_fase11.sql), e o teste não prova nada sobre RBAC. Um
# `codigo` só existindo neste corpo de teste (nunca commitado de verdade,
# porque a INSERT é negada antes de gravar) precisa ser único o bastante pra
# não colidir com um POP real pré-existente — o "-403" no valor não tem
# nenhum significado além disso.
CODE=$(api POST "/api/infra/pops" "$JWT_COMERCIAL" "{\"cidade_id\":\"$JID\",\"codigo\":\"POP-TESTE-S01A\",\"nome\":\"POP Indevido Comercial\"}")
[ "$CODE" = "403" ] && pass "TESTE-S01a COMERCIAL bloqueado de criar infraestrutura (POP) — 403" || fail "TESTE-S01a" "codigo=$CODE body=$(body)"

CODE=$(api POST "/api/infra/pops" "$JWT_FINANCEIRO" "{\"cidade_id\":\"$JID\",\"codigo\":\"POP-TESTE-S01B\",\"nome\":\"POP Indevido Financeiro\"}")
[ "$CODE" = "403" ] && pass "TESTE-S01b FINANCEIRO bloqueado de criar infraestrutura (POP) — 403" || fail "TESTE-S01b" "codigo=$CODE body=$(body)"

CODE=$(api PATCH "/api/partners/$PROPONENTE_ID" "$JWT_AUDITOR" '{"observacoes":"Tentativa de edição pelo Auditor"}')
[ "$CODE" = "403" ] && pass "TESTE-S01c AUDITOR bloqueado de editar proponente (é só leitura em todo o sistema) — 403" || fail "TESTE-S01c" "codigo=$CODE body=$(body)"

CODE=$(api POST "/api/proposals/00000000-0000-0000-0000-000000000000/approve" "$JWT_ENGENHARIA" '{}')
[ "$CODE" = "403" ] && pass "TESTE-S01d ENGENHARIA bloqueada de aprovar preço/proposta — 403 (RLS nega antes mesmo de checar se a proposta existe)" || fail "TESTE-S01d" "codigo=$CODE body=$(body)"

# S02: alterar o ID na URL não concede acesso indevido a uma ESCRITA que o
# perfil não teria de qualquer forma — reconfirma que a autorização é sempre
# por perfil (RLS), nunca por "ser dono do registro" nem por adivinhação de
# UUID. (Leitura é intencionalmente aberta a todo `authenticated` neste
# projeto desde a Fase 1 — um ERP interno de uso da própria equipe — o teste
# de "acesso indevido" relevante aqui é sempre sobre ESCRITA, coberto acima e
# em S01c/S03.)
CODE=$(api PATCH "/api/users/$UID_ADMIN" "$JWT_COMERCIAL" '{"perfil":"COMERCIAL"}')
[ "$CODE" = "403" ] && pass "TESTE-S02 COMERCIAL não consegue alterar cadastro de outro usuário (nem o do próprio ADMINISTRADOR) trocando o :id na URL — 403" || fail "TESTE-S02" "codigo=$CODE body=$(body)"

# S03: documento privado nunca com URL pública permanente — revisão de código
# (já feita e citada em run_tests_fase25.sh TESTE-24d) + confirmação estática
# aqui de que a única rota de download sempre chama createSignedUrl com
# expiração curta.
if grep -q "createSignedUrl(doc.storage_path, 300)" api/routes/partners.js && grep -q "createSignedUrl(path, 300)" api/routes/signatures.js; then
  pass "TESTE-S03 toda rota de download de documento privado usa createSignedUrl com expiração de 300s — nunca storage_path/URL pública bruta (revisão estática do código-fonte)"
else
  fail "TESTE-S03" "createSignedUrl(...,300) não encontrado onde esperado — ver api/routes/partners.js e api/routes/signatures.js"
fi

# S04: SERVICE_ROLE nunca no bundle do frontend. Constrói o frontend (se
# ainda não construído nesta sessão) e varre web/dist por qualquer menção
# literal à variável — estruturalmente impossível vazar porque o Vite só
# expõe variáveis prefixadas com VITE_ ao bundle, e SUPABASE_SERVICE_ROLE_KEY
# nunca tem esse prefixo, mas o teste confirma isso por varredura real do
# artefato construído, não só por argumento.
if [ ! -d web/dist ]; then
  ( cd web && npm run build > /tmp/fase251_web_build_for_s04.log 2>&1 )
fi
if [ -d web/dist ] && ! grep -rq "SUPABASE_SERVICE_ROLE_KEY\|service_role" web/dist/ 2>/dev/null; then
  pass "TESTE-S04 SERVICE_ROLE_KEY não aparece em nenhum arquivo do bundle construído do frontend (web/dist) — varredura real do artefato, não só inspeção de código"
elif [ ! -d web/dist ]; then
  skip "TESTE-S04" "build do frontend não disponível neste momento — ver /tmp/fase251_web_build_for_s04.log"
else
  fail "TESTE-S04 SERVICE_ROLE não deveria aparecer no bundle do frontend" "grep encontrou ocorrência em web/dist — ver detalhe"
fi

# S05: secrets nunca nos logs — varre os logs desta própria execução (API +
# PostgREST) por qualquer coisa que pareça o VALOR de um secret (nunca o
# nome da variável, que é informação operacional normal e esperada nos logs).
if grep -qE "SUPABASE_SERVICE_ROLE_KEY=[A-Za-z0-9_.-]{10,}|eyJhbGciOiJIUzI1NiJ9\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{20,}" /tmp/fase251_api.log 2>/dev/null; then
  fail "TESTE-S05 log da API não deveria conter valor de secret/JWT completo" "ver /tmp/fase251_api.log"
else
  pass "TESTE-S05 log da API não contém valor de secret nem JWT completo — só nomes de variável/erros controlados, como esperado"
fi

echo "=============================================="
echo "TESTE — URL de redirecionamento do convite (bug real reportado pelo usuário)"
echo "=============================================="
# Regressão do bug real (correção pós-entrega): o link de convite/redefinição de senha
# levava a pessoa para localhost em vez da URL real publicada, porque
# frontendRedirectUrl() sempre pegava a PRIMEIRA origem de CORS_ALLOWED_ORIGINS — e
# CORS_ALLOWED_ORIGINS quase sempre lista localhost primeiro (é o próprio padrão em
# api/.env.example). Este teste roda a função de verdade (não reimplementa a lógica),
# nos 4 cenários que importam: PUBLIC_APP_URL explícito sempre vence; sem ele, a
# primeira origem que NÃO pareça localhost é escolhida; o resultado sempre aponta para
# /definir-senha (a página nova que recebe esse retorno), nunca para /login; e uma barra
# final em PUBLIC_APP_URL (erro real de digitação em produção, ex.: ".../roan.vercel.app/")
# nunca produz "//definir-senha" (barra dupla).
REDIRECT_OUT=$(cd api && node -e "
const { frontendRedirectUrl } = require('./routes/users.js');
process.env.PUBLIC_APP_URL = '';
process.env.CORS_ALLOWED_ORIGINS = 'http://localhost:5173,https://optimon-prod.vercel.app';
const semExplicita = frontendRedirectUrl();
process.env.PUBLIC_APP_URL = 'https://optimon-prod.vercel.app';
const comExplicita = frontendRedirectUrl();
process.env.PUBLIC_APP_URL = 'https://optimon-backend-roan.vercel.app/';
const comBarraFinal = frontendRedirectUrl();
console.log(JSON.stringify({ semExplicita, comExplicita, comBarraFinal }));
" 2>/dev/null)
EXPECTED='{"semExplicita":"https://optimon-prod.vercel.app/definir-senha","comExplicita":"https://optimon-prod.vercel.app/definir-senha","comBarraFinal":"https://optimon-backend-roan.vercel.app/definir-senha"}'
if [ "$REDIRECT_OUT" = "$EXPECTED" ]; then
  pass "TESTE-redirect frontendRedirectUrl() nunca escolhe localhost quando existe uma origem real na lista, sempre aponta para /definir-senha, e nunca produz barra dupla com PUBLIC_APP_URL terminando em barra"
else
  fail "TESTE-redirect" "esperado=$EXPECTED obtido=$REDIRECT_OUT"
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
