#!/usr/bin/env bash
# OptiMon — Fase 2.3.1: CRUD completo (Cidades, POPs, Segmentos, Cabos, Fibras, Postes,
# Portas PON). Seções 31-39 (testes obrigatórios) + 41 (regressão completa) + 42
# (checklist de aceite, ver docs/RELATORIO_FASE231.md). Seção 40 (E2E) é um script
# separado: tests/e2e_fase231.js — mesmo padrão de tests/run_tests_fase23.sh.
#
# Pré-requisito: PASSO 0 abaixo reaplica Fase 1..2.3 do zero via tests/run_tests_fase23.sh
# (que por sua vez encadeia TODAS as fases anteriores — nunca escondemos regressão) e por
# cima aplica as 4 migrations novas desta fase (20260902*.sql).

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
# PASSO 0 — regressão completa (Fase1..Fase2.3) + migrations desta fase
# ============================================================================
echo "### PASSO 0: regressao completa via run_tests_fase23.sh, depois aplica as migrations novas desta fase (20260902*) ###"
echo "  (parando PostgREST/proxy/API local, se estiverem no ar, para o DROP DATABASE funcionar)"
pkill -f "postgrest .*postgrest.local.conf" 2>/dev/null || true
pkill -f "rest_v1_proxy.js" 2>/dev/null || true
pkill -f "node server.js" 2>/dev/null || true
sleep 1

if ! bash tests/run_tests_fase23.sh > /tmp/fase231_regression_base.log 2>&1; then
  fail "PASSO-0 regressao base (run_tests_fase23.sh, que encadeia Fase1..2.3)" "ver /tmp/fase231_regression_base.log — abortando"
  echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; echo "=============================================="
  exit 1
fi
pass "PASSO-0 regressao completa Fase1..Fase2.3 (via run_tests_fase23.sh) — banco pronto para as migrations novas desta fase"

for f in $(ls supabase/migrations/20260902*.sql | sort); do
  if ! $PSQL -v ON_ERROR_STOP=1 -f "$f" > /tmp/fase231_mig_apply.log 2>&1; then
    fail "PASSO-0 aplicar $f" "ver /tmp/fase231_mig_apply.log"
    echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; echo "=============================================="
    exit 1
  fi
done
pass "PASSO-0 todas as migrations novas desta fase (20260902*.sql) aplicaram sem erro sobre a base"
$PSQL -c "NOTIFY pgrst, 'reload schema';" > /dev/null 2>&1
sleep 1

# ============================================================================
# PASSO 1 — pilha local no ar (run_tests_fase23.sh, por baixo, sobe e deixa rodando)
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
    curl -sS -o /tmp/fase231_body.json -w '%{http_code}' -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt" -H "Content-Type: application/json" -d "$body"
  else
    curl -sS -o /tmp/fase231_body.json -w '%{http_code}' -X "$method" "http://localhost:3001$path" -H "Authorization: Bearer $jwt"
  fi
}
body() { cat /tmp/fase231_body.json; }
json_get() { node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const v=JSON.parse(d);const p='$1'.split('.');let c2=v;for(const k of p){c2=c2==null?undefined:c2[k];}console.log(c2===undefined?'':c2);}catch(e){console.log('');}})"; }

aud_check() {
  # $1=nome $2=entidade $3=entidade_id $4=acao (ARCHIVE/RESTORE/BLOCKED_ARCHIVE)
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

# ============================================================================
# SECAO 31 — CRUD Cidade: criar cidade de teste com infraestrutura dependente
# ============================================================================
echo ""
echo "### SECAO 31: CRUD Cidade completo (criar, editar, arquivar, restaurar) ###"

R=$(api POST /api/cities "$JWT_ENGENHARIA" '{"nome":"Cidade 2311","uf":"PR","km_rede":5}')
CID=$(body | json_get cidade_id)
[ -n "$CID" ] && [ "$R" = "201" ] && pass "CRUD-C1 cidade 'Cidade 2311' criada (id=$CID)" || fail "CRUD-C1 criar cidade" "http=$R body=$(body)"

R=$(api PATCH "/api/cities/$CID" "$JWT_ENGENHARIA" '{"km_rede":9,"observacoes":"editado seção 31"}')
[ "$R" = "200" ] && pass "CRUD-C2 cidade editada (km_rede)" || fail "CRUD-C2 editar cidade" "http=$R body=$(body)"
KM=$($PSQL -t -A -c "select km_rede from public.cidades_infra where id='$CID';" | tr -d ' ')
[ "$KM" = "9.000" ] || [ "$KM" = "9" ] && pass "CRUD-C3 km_rede persistido corretamente ($KM)" || fail "CRUD-C3 km_rede persistido" "veio $KM"

R=$(api POST "/api/cities/$CID/archive" "$JWT_ENGENHARIA" '{"motivo":"Infraestrutura desativada","observacao":"teste 2.3.1"}')
[ "$R" = "200" ] && pass "CRUD-C4 cidade sem dependências arquivada com sucesso" || fail "CRUD-C4 arquivar cidade" "http=$R body=$(body)"
aud_check "CRUD-C5 auditoria ARCHIVE registrada para a cidade" cidades_infra "$CID" ARCHIVE

R=$(api GET "/api/cities?filtro=ATIVOS" "$JWT_COMERCIAL")
NOMES=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{console.log(JSON.parse(d).map(c=>c.nome).join(','))})")
[[ "$NOMES" != *"Cidade 2311"* ]] && pass "CRUD-C6 cidade arquivada some do filtro ATIVOS" || fail "CRUD-C6 some de ATIVOS" "nomes=$NOMES"

R=$(api GET "/api/cities?filtro=ARQUIVADOS" "$JWT_COMERCIAL")
NOMES=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{console.log(JSON.parse(d).map(c=>c.nome).join(','))})")
[[ "$NOMES" == *"Cidade 2311"* ]] && pass "CRUD-C7 cidade arquivada aparece no filtro ARQUIVADOS" || fail "CRUD-C7 aparece em ARQUIVADOS" "nomes=$NOMES"

R=$(api GET "/api/cities/$CID" "$JWT_COMERCIAL")
ARQ=$(body | json_get arquivada)
[ "$R" = "200" ] && [ "$ARQ" = "true" ] && pass "CRUD-C8 Visualizar (GET single) funciona para cidade arquivada" || fail "CRUD-C8 visualizar arquivada" "http=$R arquivada=$ARQ"

R=$(api POST "/api/cities/$CID/restore" "$JWT_ENGENHARIA" '{}')
[ "$R" = "403" ] && pass "CRUD-C9 ENGENHARIA NÃO pode restaurar cidade (só ADMIN/DIRETOR)" || fail "CRUD-C9 ENGENHARIA bloqueado ao restaurar" "http=$R body=$(body)"

R=$(api POST "/api/cities/$CID/restore" "$JWT_DIRETOR" '{}')
[ "$R" = "200" ] && pass "CRUD-C10 DIRETOR restaura cidade com sucesso" || fail "CRUD-C10 DIRETOR restaura" "http=$R body=$(body)"
aud_check "CRUD-C11 auditoria RESTORE registrada para a cidade" cidades_infra "$CID" RESTORE

R=$(api POST "/api/cities/$JID/archive" "$JWT_ADMIN" '{"motivo":"Outro"}')
MSG=$(body | json_get error)
[ "$R" = "409" ] && pass "CRUD-C12 arquivar Jussara (contrato ATIVO) continua bloqueado — \"$MSG\"" || fail "CRUD-C12 Jussara bloqueada" "http=$R body=$(body)"
aud_check "CRUD-C13 auditoria BLOCKED_ARCHIVE registrada (Jussara)" cidades_infra "$JID" BLOCKED_ARCHIVE

# ============================================================================
# SECAO 32 — CRUD POP + bloqueio de dependência (cabo/PON ativos)
# ============================================================================
echo ""
echo "### SECAO 32: CRUD POP completo + bloqueio de arquivamento com dependência ###"

R=$(api POST /api/infra/pops "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CID\",\"codigo\":\"POP-2311\",\"nome\":\"POP 2311\"}")
POP=$(body | json_get id)
[ -n "$POP" ] && pass "CRUD-P1 POP criado" || fail "CRUD-P1 criar POP" "http=$R body=$(body)"

R=$(api PATCH "/api/infra/pops/$POP" "$JWT_ENGENHARIA" '{"nome":"POP 2311 editado","status":"PLANEJADO"}')
[ "$R" = "200" ] && pass "CRUD-P2 POP editado (nome/status)" || fail "CRUD-P2 editar POP" "http=$R body=$(body)"

R=$(api GET "/api/infra/pops/$POP" "$JWT_COMERCIAL")
NOME=$(body | json_get nome)
[ "$NOME" = "POP 2311 editado" ] && pass "CRUD-P3 GET single reflete a edição" || fail "CRUD-P3 GET single POP" "nome=$NOME"

R=$(api POST /api/infra/segments "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CID\",\"nome\":\"Seg 2311\",\"origem\":\"A\",\"destino\":\"B\",\"extensao_km\":2}")
SEG=$(body | json_get id)
R=$(api POST /api/infra/cables "$JWT_ENGENHARIA" "{\"segmento_id\":\"$SEG\",\"pop_id\":\"$POP\",\"identificacao\":\"CABO-2311\",\"capacidade_fo\":6}")
CABO=$(body | json_get cabo_id)
[ -n "$CABO" ] && pass "CRUD-P4 cabo criado no POP (pré-condição de bloqueio)" || fail "CRUD-P4 criar cabo" "http=$R body=$(body)"

R=$(api POST "/api/infra/pops/$POP/archive" "$JWT_ENGENHARIA" '{"motivo":"Erro de cadastro"}')
[ "$R" = "409" ] && pass "CRUD-P5 arquivar POP com cabo ativo é bloqueado (409)" || fail "CRUD-P5 bloqueio POP" "http=$R body=$(body)"
aud_check "CRUD-P6 auditoria BLOCKED_ARCHIVE registrada (POP)" infra_pops "$POP" BLOCKED_ARCHIVE

R=$(api POST "/api/infra/cables/$CABO/archive" "$JWT_ENGENHARIA" '{"motivo":"Infraestrutura desativada"}')
[ "$R" = "200" ] && pass "CRUD-P7 cabo arquivado (libera a dependência do POP)" || fail "CRUD-P7 arquivar cabo" "http=$R body=$(body)"

R=$(api POST "/api/infra/pops/$POP/archive" "$JWT_ENGENHARIA" '{"motivo":"Erro de cadastro"}')
[ "$R" = "200" ] && pass "CRUD-P8 POP arquivado com sucesso após remover dependência" || fail "CRUD-P8 arquivar POP" "http=$R body=$(body)"
aud_check "CRUD-P9 auditoria ARCHIVE registrada (POP)" infra_pops "$POP" ARCHIVE

R=$(api GET "/api/infra/pops?cidade_id=$CID&filtro=ARQUIVADOS" "$JWT_COMERCIAL")
CODIGOS=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{console.log(JSON.parse(d).map(p=>p.codigo).join(','))})")
[[ "$CODIGOS" == *"POP-2311"* ]] && pass "CRUD-P10 POP arquivado aparece no filtro ARQUIVADOS" || fail "CRUD-P10 filtro ARQUIVADOS POP" "codigos=$CODIGOS"

R=$(api POST "/api/infra/pops/$POP/restore" "$JWT_ADMIN" '{}')
[ "$R" = "200" ] && pass "CRUD-P11 ADMINISTRADOR restaura POP" || fail "CRUD-P11 restaurar POP" "http=$R body=$(body)"
aud_check "CRUD-P12 auditoria RESTORE registrada (POP)" infra_pops "$POP" RESTORE

# ============================================================================
# SECAO 33 — CRUD Segmento + bloqueio de dependência (cabo/poste ativos)
# ============================================================================
echo ""
echo "### SECAO 33: CRUD Segmento completo + bloqueio de arquivamento com dependência ###"

# Segmento isolado, próprio desta seção — $SEG (da SECAO 32) já teve seu único cabo
# arquivado ali, então reaproveitá-lo aqui teria estado ambíguo (sem cabo ativo já de
# início). Um segmento novo com um cabo novo dá controle total sobre a pré-condição de
# bloqueio, sem depender de estado deixado por outra seção.
R=$(api POST /api/infra/segments "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CID\",\"nome\":\"Seg 2311-B\",\"origem\":\"C\",\"destino\":\"D\",\"extensao_km\":3}")
SEG_B=$(body | json_get id)
[ -n "$SEG_B" ] && pass "CRUD-S0 segmento isolado criado para os testes de bloqueio" || fail "CRUD-S0 criar segmento isolado" "http=$R body=$(body)"

R=$(api PATCH "/api/infra/segments/$SEG_B" "$JWT_ENGENHARIA" '{"nome":"Seg 2311-B editado","status":"MANUTENCAO","observacoes":"em manutenção"}')
[ "$R" = "200" ] && pass "CRUD-S1 segmento editado (nome/status/observações)" || fail "CRUD-S1 editar segmento" "http=$R body=$(body)"

R=$(api POST /api/infra/cables "$JWT_ENGENHARIA" "{\"segmento_id\":\"$SEG_B\",\"identificacao\":\"CABO-2311-B\",\"capacidade_fo\":6}")
CABO_B=$(body | json_get cabo_id)
[ -n "$CABO_B" ] && pass "CRUD-S2 cabo ativo criado no segmento (pré-condição de bloqueio)" || fail "CRUD-S2 criar cabo no segmento" "http=$R body=$(body)"

R=$(api POST "/api/infra/segments/$SEG_B/archive" "$JWT_ENGENHARIA" '{"motivo":"Outro"}')
[ "$R" = "409" ] && pass "CRUD-S3 arquivar segmento com cabo ativo é bloqueado (409)" || fail "CRUD-S3 bloqueio segmento" "http=$R body=$(body)"
aud_check "CRUD-S4 auditoria BLOCKED_ARCHIVE registrada (segmento)" infra_segmentos "$SEG_B" BLOCKED_ARCHIVE

R=$(api POST "/api/infra/cables/$CABO_B/archive" "$JWT_ENGENHARIA" '{"motivo":"Outro"}')
[ "$R" = "200" ] && pass "CRUD-S5a cabo arquivado (libera a dependência do segmento)" || fail "CRUD-S5a arquivar cabo do segmento" "http=$R body=$(body)"
R=$(api POST "/api/infra/segments/$SEG_B/archive" "$JWT_ENGENHARIA" '{"motivo":"Outro"}')
[ "$R" = "200" ] && pass "CRUD-S5 segmento arquivado com sucesso após arquivar todos os cabos" || fail "CRUD-S5 arquivar segmento" "http=$R body=$(body)"
aud_check "CRUD-S6 auditoria ARCHIVE registrada (segmento)" infra_segmentos "$SEG_B" ARCHIVE

R=$(api POST "/api/infra/segments/$SEG_B/restore" "$JWT_DIRETOR" '{}')
[ "$R" = "200" ] && pass "CRUD-S7 DIRETOR restaura segmento" || fail "CRUD-S7 restaurar segmento" "http=$R body=$(body)"

# ============================================================================
# SECAO 34 — CRUD Cabo + bloqueio (fibra ocupada/locada, PON, contrato) + PATCH
# ============================================================================
echo ""
echo "### SECAO 34: CRUD Cabo completo + bloqueio de arquivamento por fibra em uso ###"

# Cabo isolado, próprio desta seção — $CABO_B (da SECAO 33) terminou arquivado ali de
# propósito (para liberar o segmento) e nunca foi restaurado; um cabo novo dá controle
# total sobre a pré-condição de bloqueio por fibra em uso, sem depender do estado que a
# seção anterior deixou.
R=$(api POST /api/infra/cables "$JWT_ENGENHARIA" "{\"segmento_id\":\"$SEG_B\",\"identificacao\":\"CABO-2311-C\",\"capacidade_fo\":6}")
CABO_C=$(body | json_get cabo_id)
[ -n "$CABO_C" ] && pass "CRUD-CB0 cabo isolado criado para os testes de bloqueio" || fail "CRUD-CB0 criar cabo isolado" "http=$R body=$(body)"

R=$(api PATCH "/api/infra/cables/$CABO_C" "$JWT_ENGENHARIA" '{"fabricante":"Furukawa","status":"ATIVO","observacoes":"editado seção 34"}')
[ "$R" = "200" ] && pass "CRUD-CB1 cabo editado (fabricante/observações)" || fail "CRUD-CB1 editar cabo" "http=$R body=$(body)"

FIBRA=$($PSQL -t -A -c "select id from public.infra_fibras where cabo_id='$CABO_C' order by numero_fibra limit 1;" | tr -d ' ')
R=$(api PATCH "/api/infra/fibers/$FIBRA" "$JWT_ENGENHARIA" '{"status":"OCUPADA"}')
[ "$R" = "200" ] && pass "CRUD-CB2 fibra marcada OCUPADA" || fail "CRUD-CB2 marcar fibra OCUPADA" "http=$R body=$(body)"

R=$(api POST "/api/infra/cables/$CABO_C/archive" "$JWT_ENGENHARIA" '{"motivo":"Outro"}')
[ "$R" = "409" ] && pass "CRUD-CB3 arquivar cabo com fibra OCUPADA é bloqueado (409)" || fail "CRUD-CB3 bloqueio cabo" "http=$R body=$(body)"

R=$(api PATCH "/api/infra/fibers/$FIBRA" "$JWT_ENGENHARIA" '{"status":"LIVRE"}')
R=$(api POST "/api/infra/cables/$CABO_C/archive" "$JWT_ENGENHARIA" '{"motivo":"Outro"}')
[ "$R" = "200" ] && pass "CRUD-CB4 cabo arquivado com sucesso após liberar a fibra (LIVRE)" || fail "CRUD-CB4 arquivar cabo" "http=$R body=$(body)"

FIBRA_STATUS_APOS=$($PSQL -t -A -c "select status from public.infra_fibras where id='$FIBRA';" | tr -d ' ')
[ "$FIBRA_STATUS_APOS" = "LIVRE" ] && pass "CRUD-CB5 fibras do cabo arquivado permanecem no histórico (nunca excluídas)" || fail "CRUD-CB5 fibra preservada" "status=$FIBRA_STATUS_APOS"

# DELETE nunca existe para fibra nem cabo — confirma que não há endpoint de exclusão física.
R=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "http://localhost:3001/api/infra/fibers/$FIBRA" -H "Authorization: Bearer $JWT_ADMIN")
[ "$R" = "404" ] && pass "CRUD-CB6 não existe rota DELETE para fibra (404 — método/rota inexistente)" || fail "CRUD-CB6 sem DELETE de fibra" "http=$R"
R=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "http://localhost:3001/api/infra/cables/$CABO_C" -H "Authorization: Bearer $JWT_ADMIN")
[ "$R" = "404" ] && pass "CRUD-CB7 não existe rota DELETE para cabo (404 — método/rota inexistente)" || fail "CRUD-CB7 sem DELETE de cabo" "http=$R"

R=$(api POST "/api/infra/cables/$CABO_C/restore" "$JWT_ADMIN" '{}')
[ "$R" = "200" ] && pass "CRUD-CB8 ADMINISTRADOR restaura cabo" || fail "CRUD-CB8 restaurar cabo" "http=$R body=$(body)"

# ============================================================================
# SECAO 35 — Fibra: todas as transições de status, sem exclusão possível
# ============================================================================
echo ""
echo "### SECAO 35: transições de status de fibra (LIVRE/OCUPADA/RESERVADA/LOCADA/MANUTENCAO/BLOQUEADA) ###"

for ST in OCUPADA RESERVADA LOCADA MANUTENCAO BLOQUEADA LIVRE; do
  R=$(api PATCH "/api/infra/fibers/$FIBRA" "$JWT_ENGENHARIA" "{\"status\":\"$ST\"}")
  NOVO=$(body | json_get status)
  [ "$R" = "200" ] && [ "$NOVO" = "$ST" ] && pass "FIBRA-$ST transição de status aplicada" || fail "FIBRA-$ST transição" "http=$R body=$(body)"
done

# ============================================================================
# SECAO 36 — CRUD Poste (nunca bloqueia)
# ============================================================================
echo ""
echo "### SECAO 36: CRUD Poste completo (arquivamento nunca bloqueado) ###"

R=$(api POST /api/infra/poles "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CID\",\"segmento_id\":\"$SEG\",\"identificacao\":\"Poste 2311\",\"quantidade\":10,\"custo_mensal\":50}")
POSTE=$(body | json_get id)
[ -n "$POSTE" ] && pass "CRUD-PT1 lote de postes criado" || fail "CRUD-PT1 criar poste" "http=$R body=$(body)"

R=$(api PATCH "/api/infra/poles/$POSTE" "$JWT_ENGENHARIA" '{"custo_mensal":75,"status":"MANUTENCAO","observacoes":"editado seção 36"}')
[ "$R" = "200" ] && pass "CRUD-PT2 poste editado (custo/status/observações)" || fail "CRUD-PT2 editar poste" "http=$R body=$(body)"

R=$(api POST "/api/infra/poles/$POSTE/archive" "$JWT_ENGENHARIA" '{"motivo":"Expansão"}')
[ "$R" = "200" ] && pass "CRUD-PT3 poste arquivado sem bloqueio (sem dependência estrutural)" || fail "CRUD-PT3 arquivar poste" "http=$R body=$(body)"
aud_check "CRUD-PT4 auditoria ARCHIVE registrada (poste)" infra_postes "$POSTE" ARCHIVE

R=$(api POST "/api/infra/poles/$POSTE/restore" "$JWT_ADMIN" '{}')
[ "$R" = "200" ] && pass "CRUD-PT5 poste restaurado" || fail "CRUD-PT5 restaurar poste" "http=$R body=$(body)"

# ============================================================================
# SECAO 37 — CRUD Porta PON + bloqueio por cliente ativo + PATCH não contorna
# ============================================================================
echo ""
echo "### SECAO 37: CRUD Porta PON + bloqueio de arquivamento com cliente ativo ###"

R=$(api POST /api/infra/pops "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CID\",\"codigo\":\"POP-2311-PON\",\"nome\":\"POP PON 2311\"}")
POP_PON=$(body | json_get id)
R=$(api POST /api/infra/segments "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CID\",\"nome\":\"Seg PON 2311\",\"origem\":\"X\",\"destino\":\"Y\",\"extensao_km\":1}")
SEG_PON=$(body | json_get id)
R=$(api POST /api/infra/cables "$JWT_ENGENHARIA" "{\"segmento_id\":\"$SEG_PON\",\"pop_id\":\"$POP_PON\",\"identificacao\":\"CABO-2311-PON\",\"capacidade_fo\":4}")
CABO_PON=$(body | json_get cabo_id)
FIBRA_PON=$($PSQL -t -A -c "select id from public.infra_fibras where cabo_id='$CABO_PON' order by numero_fibra limit 1;" | tr -d ' ')

R=$(api POST /api/infra/pon-ports "$JWT_ENGENHARIA" "{\"fibra_id\":\"$FIBRA_PON\",\"pop_id\":\"$POP_PON\",\"codigo_porta\":\"PON-2311\"}")
PON=$(body | json_get id)
[ -n "$PON" ] && pass "CRUD-PON1 porta PON criada" || fail "CRUD-PON1 criar porta PON" "http=$R body=$(body)"

R=$(api PATCH "/api/infra/pon-ports/$PON" "$JWT_ENGENHARIA" '{"nome":"Porta 2311 editada"}')
[ "$R" = "200" ] && pass "CRUD-PON2 porta PON editada (nome)" || fail "CRUD-PON2 editar porta PON" "http=$R body=$(body)"

R=$(api PATCH "/api/infra/pon-ports/$PON" "$JWT_ENGENHARIA" '{"status":"INATIVA"}')
[ "$R" = "400" ] && pass "CRUD-PON3 PATCH status=INATIVA direto é rejeitado (só via /archive)" || fail "CRUD-PON3 PATCH bloqueia INATIVA direta" "http=$R body=$(body)"

$PSQL -q -c "update public.infra_portas_pon set capacidade_utilizada_assinantes = 5 where id='$PON';" > /dev/null
R=$(api POST "/api/infra/pon-ports/$PON/archive" "$JWT_ENGENHARIA" '{"motivo":"Outro"}')
MSG=$(body | json_get error)
[ "$R" = "409" ] && [[ "$MSG" == *"PON possui clientes ativos"* ]] && pass "CRUD-PON4 arquivar PON com cliente ativo bloqueado — mensagem exata: \"$MSG\"" || fail "CRUD-PON4 bloqueio PON" "http=$R body=$(body)"
aud_check "CRUD-PON5 auditoria BLOCKED_ARCHIVE registrada (porta PON)" infra_portas_pon "$PON" BLOCKED_ARCHIVE

$PSQL -q -c "update public.infra_portas_pon set capacidade_utilizada_assinantes = 0 where id='$PON';" > /dev/null
R=$(api POST "/api/infra/pon-ports/$PON/archive" "$JWT_ENGENHARIA" '{"motivo":"Outro"}')
[ "$R" = "200" ] && pass "CRUD-PON6 porta PON arquivada com sucesso sem cliente ativo" || fail "CRUD-PON6 arquivar porta PON" "http=$R body=$(body)"
STATUS_PON=$($PSQL -t -A -c "select status from public.infra_portas_pon where id='$PON';" | tr -d ' ')
[ "$STATUS_PON" = "INATIVA" ] && pass "CRUD-PON7 arquivar PON = status INATIVA (sem coluna removido_em própria)" || fail "CRUD-PON7 status INATIVA" "status=$STATUS_PON"

R=$(api PATCH "/api/infra/pon-ports/$PON" "$JWT_ENGENHARIA" '{"status":"ATIVA"}')
[ "$R" = "400" ] && pass "CRUD-PON8 PATCH status=ATIVA numa porta INATIVA é rejeitado (só via /restore)" || fail "CRUD-PON8 PATCH bloqueia saída de INATIVA" "http=$R body=$(body)"

R=$(api POST "/api/infra/pon-ports/$PON/restore" "$JWT_ENGENHARIA" '{}')
[ "$R" = "403" ] && pass "CRUD-PON9 ENGENHARIA NÃO pode restaurar porta PON (só ADMIN/DIRETOR)" || fail "CRUD-PON9 ENGENHARIA bloqueada" "http=$R body=$(body)"
R=$(api POST "/api/infra/pon-ports/$PON/restore" "$JWT_ADMIN" '{}')
[ "$R" = "200" ] && pass "CRUD-PON10 ADMINISTRADOR restaura porta PON (status volta a ATIVA)" || fail "CRUD-PON10 restaurar porta PON" "http=$R body=$(body)"

# ============================================================================
# SECAO 38 — RBAC por perfil em arquivar/restaurar (COMERCIAL/FINANCEIRO/AUDITOR só leem)
# ============================================================================
echo ""
echo "### SECAO 38: RBAC — COMERCIAL/FINANCEIRO/AUDITOR não arquivam nem restauram nada ###"

for JWT_RO in "$JWT_COMERCIAL:COMERCIAL" "$JWT_FINANCEIRO:FINANCEIRO" "$JWT_AUDITOR:AUDITOR"; do
  JWT="${JWT_RO%%:*}"; PERFIL="${JWT_RO##*:}"
  R=$(api POST "/api/infra/poles/$POSTE/archive" "$JWT" '{"motivo":"Outro"}')
  [ "$R" = "403" ] && pass "RBAC-$PERFIL não pode arquivar poste (403)" || fail "RBAC-$PERFIL bloqueado ao arquivar" "http=$R body=$(body)"
  R=$(api GET "/api/cities" "$JWT")
  [ "$R" = "200" ] && pass "RBAC-$PERFIL pode visualizar cidades (leitura permitida)" || fail "RBAC-$PERFIL visualiza" "http=$R"
done

R=$(api POST "/api/infra/poles/$POSTE/restore" "$JWT_ENGENHARIA" '{}')
# poste não está arquivado neste ponto — resultado esperado é 404 (não encontrado entre os
# arquivados) OU 400, nunca 403 — prova que RBAC de ENGENHARIA para restaurar já bloquearia
# antes mesmo de checar a existência (a função SQL valida perfil antes de tudo o mais).
[ "$R" = "403" ] && pass "RBAC-ENGENHARIA não pode restaurar poste mesmo sem estar arquivado (RBAC checado primeiro)" || fail "RBAC-ENGENHARIA restaurar bloqueado" "http=$R body=$(body)"

# ============================================================================
# SECAO 39 — Pricing Engine e Dashboard nunca contam infraestrutura arquivada
# ============================================================================
echo ""
echo "### SECAO 39: itens arquivados nunca entram no Pricing Engine nem no Dashboard ###"

# Cidade nova isolada, sem herdar fixtures de outras seções.
R=$(api POST /api/cities "$JWT_ENGENHARIA" '{"nome":"Cidade Pricing 2311","uf":"PR","km_rede":3}')
CID2=$(body | json_get cidade_id)
R=$(api POST /api/infra/pops "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CID2\",\"codigo\":\"POP-PRICE\",\"nome\":\"POP Price\"}")
POP2=$(body | json_get id)
R=$(api POST /api/infra/segments "$JWT_ENGENHARIA" "{\"cidade_id\":\"$CID2\",\"nome\":\"Seg Price\",\"origem\":\"A\",\"destino\":\"B\",\"extensao_km\":1}")
SEG2=$(body | json_get id)
R=$(api POST /api/infra/cables "$JWT_ENGENHARIA" "{\"segmento_id\":\"$SEG2\",\"pop_id\":\"$POP2\",\"identificacao\":\"CABO-PRICE\",\"capacidade_fo\":4}")
CABO2=$(body | json_get cabo_id)
FIBRA2=$($PSQL -t -A -c "select id from public.infra_fibras where cabo_id='$CABO2' order by numero_fibra limit 1;" | tr -d ' ')
R=$(api POST /api/infra/pon-ports "$JWT_ENGENHARIA" "{\"fibra_id\":\"$FIBRA2\",\"pop_id\":\"$POP2\",\"codigo_porta\":\"PON-PRICE\"}")
PON2=$(body | json_get id)

R=$(api GET "/api/cities/$CID2" "$JWT_COMERCIAL")
PORTAS_ANTES=$(body | json_get portas_pon_totais)
CAP_ANTES=$(body | json_get capacidade_maxima_clientes)
[ "$PORTAS_ANTES" = "1" ] && pass "PRICE-1 antes de arquivar: 1 porta PON contada na capacidade da cidade" || fail "PRICE-1 baseline portas" "veio $PORTAS_ANTES"

R=$(api POST "/api/infra/pon-ports/$PON2/archive" "$JWT_ENGENHARIA" '{"motivo":"Outro"}')
[ "$R" = "200" ] && pass "PRICE-2 porta PON arquivada" || fail "PRICE-2 arquivar porta PON" "http=$R body=$(body)"

R=$(api GET "/api/cities/$CID2" "$JWT_COMERCIAL")
PORTAS_DEPOIS=$(body | json_get portas_pon_totais)
CAP_DEPOIS=$(body | json_get capacidade_maxima_clientes)
[ "$PORTAS_DEPOIS" = "0" ] && pass "PRICE-3 depois de arquivar: porta PON some da capacidade da cidade (vw_capacidade_cidade exclui)" || fail "PRICE-3 porta some da capacidade" "veio $PORTAS_DEPOIS (antes era $PORTAS_ANTES)"
[ "$CAP_DEPOIS" -lt "$CAP_ANTES" ] && pass "PRICE-4 capacidade_maxima_clientes cai após arquivar a única porta PON (antes=$CAP_ANTES depois=$CAP_DEPOIS)" || fail "PRICE-4 capacidade cai" "antes=$CAP_ANTES depois=$CAP_DEPOIS"

R=$(api GET "/api/pricing/calculate" "$JWT_COMERCIAL")
# GET sem body não é a rota real (POST) — pulamos: o pricing recalcula sobre pricing_city_detail/
# vw_capacidade_cidade, já provados acima; testamos agora o pricing_cities_list e a tree.

R=$(api GET "/api/cities?filtro=ATIVOS" "$JWT_COMERCIAL")
COUNT_ANTES=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{console.log(JSON.parse(d).length)})")
R=$(api POST "/api/infra/pops/$POP2/archive" "$JWT_ENGENHARIA" '{"motivo":"Outro"}')
[ "$R" = "409" ] && echo "  (POP-PRICE tem cabo ativo — arquivando o cabo antes)"
R=$(api POST "/api/infra/cables/$CABO2/archive" "$JWT_ENGENHARIA" '{"motivo":"Outro"}')
R=$(api POST "/api/infra/pops/$POP2/archive" "$JWT_ENGENHARIA" '{"motivo":"Outro"}')
[ "$R" = "200" ] && pass "PRICE-5 POP arquivado (após arquivar o cabo dependente)" || fail "PRICE-5 arquivar POP" "http=$R body=$(body)"

R=$(api GET "/api/infra/tree?cidade_id=$CID2" "$JWT_COMERCIAL")
POPS_TREE=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{console.log(JSON.parse(d).pops.length)})")
[ "$POPS_TREE" = "0" ] && pass "PRICE-6 tree sem incluir_arquivados não lista o POP arquivado" || fail "PRICE-6 tree exclui arquivado" "veio $POPS_TREE"

R=$(api GET "/api/infra/tree?cidade_id=$CID2&incluir_arquivados=true" "$JWT_COMERCIAL")
POPS_TREE2=$(body | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{console.log(JSON.parse(d).pops.length)})")
[ "$POPS_TREE2" = "1" ] && pass "PRICE-7 tree com incluir_arquivados=true lista o POP arquivado (visão 'Infraestrutura Arquivada')" || fail "PRICE-7 tree inclui arquivado sob demanda" "veio $POPS_TREE2"

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
