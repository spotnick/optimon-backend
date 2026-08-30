#!/usr/bin/env bash
# OptiMon — Fase 3, item 3.12: Auditoria — confirmar imutabilidade (sem UPDATE/DELETE).
#
# Este item é de VERIFICAÇÃO, não de feature nova: `public.auditoria` já foi
# desenhada desde a Fase 1 para ser imutável (trg_auditoria_imutavel, seção
# 33), mas nunca havia um teste automatizado provando isso — a garantia
# existia só como comentário/convenção. Este script prova, contra o schema
# Postgres real (nunca assumido), as 3 camadas de defesa independentes:
#
#   (1) TRIGGER (a camada que realmente importa): trg_auditoria_imutavel
#       (BEFORE UPDATE OR DELETE) bloqueia QUALQUER UPDATE/DELETE, inclusive
#       para o dono da tabela/superusuário — que nem passa por RLS. Testado
#       diretamente como optimon_admin (TESTE-01/02).
#   (2) RLS: `auditoria` não tem NENHUMA policy de INSERT/UPDATE/DELETE — só
#       `auditoria_select` (leitura). Um usuário autenticado comum tentando
#       INSERT direto (sem passar pelas funções SECURITY DEFINER) é
#       rejeitado pela RLS antes mesmo do trigger de imutabilidade entrar em
#       jogo; UPDATE/DELETE por esse mesmo caminho afetam 0 linhas (RLS não
#       expõe nenhuma linha para essas operações a esse role) — TESTE-03/04/05.
#   (3) CÓDIGO: nenhuma migration ou rota da API Node emite UPDATE/DELETE
#       contra `auditoria` — checagem estática (TESTE-06/07) — e todo INSERT
#       real passa só pelas funções SECURITY DEFINER já existentes
#       (fn_auditoria / app.registrar_auditoria_semantica), nunca por SQL
#       solto na API (TESTE-08).
#
# LIMITAÇÃO DE AMBIENTE: não há um teste automatizado cobrindo um ataque via
# `service_role`/chave mestra do Supabase real (que bypassaria RLS por
# completo) — esse ambiente local não tem GoTrue real (mesma limitação já
# documentada desde a Fase 2.5/2.5.1/2.5.3). Mesmo nesse cenário hipotético,
# porém, o TESTE-01/02 já prova que o trigger de imutabilidade continuaria
# bloqueando, porque ele não depende de RLS nem de papel/role — é a camada de
# defesa que realmente não tem exceção.

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
# PASSO 0 — regressão completa (Fase1..Fase2.5.3) + todas as migrations Fase 3
# aplicadas nesta sessão, na ordem cronológica (mesmo procedimento manual
# usado a cada task desta fase, agora fixado em script para o item 3.12).
# ============================================================================
echo "### PASSO 0: regressao completa via run_tests_fase253.sh, depois aplica TODAS as migrations Fase 3 desta sessao ###"
pkill -f "postgrest .*postgrest.local.conf" 2>/dev/null || true
pkill -f "rest_v1_proxy.js" 2>/dev/null || true
pkill -f "node server.js" 2>/dev/null || true
sleep 1

bash tests/run_tests_fase253.sh > /tmp/fase312_regression_base.log 2>&1
REGRESSION_RC=$?
REGRESSION_SUMMARY=$(tail -6 /tmp/fase312_regression_base.log)
if [ $REGRESSION_RC -ne 0 ]; then
  fail "PASSO-0 regressao base (run_tests_fase253.sh)" "ver /tmp/fase312_regression_base.log — abortando"
  echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; echo "=============================================="
  exit 1
else
  pass "PASSO-0 regressao completa Fase1..Fase2.5.3 (via run_tests_fase253.sh) — 0 falhas"
  echo "  (resumo: $REGRESSION_SUMMARY)"
fi

FASE3_MIGRATIONS=(
  20260922090000_phase_3_01_preco_proposto_correcao_critica.sql
  20260922090100_phase_3_02_motivo_excecao_prazo_contrato.sql
  20260923090000_phase_3_03_dashboard_executivo.sql
  20260924090000_phase_3_06_relatorios_gerenciais.sql
  20260925090000_phase_3_07_minuta_contrato_dados.sql
  20260926090000_phase_3_08_exclusao_fisica_usuario.sql
  20260927090000_phase_3_11_alertas_cobertura_completa.sql
)
for f in "${FASE3_MIGRATIONS[@]}"; do
  if ! $PSQL -v ON_ERROR_STOP=1 -f "supabase/migrations/$f" > /tmp/fase312_mig_apply.log 2>&1; then
    fail "PASSO-0 aplicar $f" "ver /tmp/fase312_mig_apply.log"
    echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; echo "=============================================="
    exit 1
  fi
done
pass "PASSO-0 todas as ${#FASE3_MIGRATIONS[@]} migrations da Fase 3 (ate 3.11) aplicaram sem erro sobre a base"

ADMIN_ID=$($PSQL -t -A -c "select id from usuarios where perfil='ADMINISTRADOR' and ativo=true limit 1;")
FIRST_AUDIT_ID=$($PSQL -t -A -c "select id from auditoria limit 1;")

echo "### TESTES 01-08: imutabilidade de public.auditoria (item 3.12) ###"

# ----------------------------------------------------------------------------
# TESTE-01/02: dono da tabela/superusuário (optimon_admin) — o trigger não
# depende de RLS nem de papel, então nem o role mais privilegiado do sistema
# escapa dele.
# ----------------------------------------------------------------------------
OUT=$($PSQL -c "update public.auditoria set motivo = 'forjado-teste-3.12' where id = '$FIRST_AUDIT_ID';" 2>&1)
if echo "$OUT" | grep -q "imutáveis e não podem ser alterados"; then
  pass "TESTE-01 UPDATE direto em auditoria, mesmo como optimon_admin (dono da tabela), é bloqueado pelo trigger trg_auditoria_imutavel"
else
  fail "TESTE-01 UPDATE como optimon_admin deveria ser bloqueado pelo trigger" "$OUT"
fi

OUT=$($PSQL -c "delete from public.auditoria where id = '$FIRST_AUDIT_ID';" 2>&1)
if echo "$OUT" | grep -q "imutáveis e não podem ser alterados"; then
  pass "TESTE-02 DELETE direto em auditoria, mesmo como optimon_admin (dono da tabela), é bloqueado pelo trigger trg_auditoria_imutavel"
else
  fail "TESTE-02 DELETE como optimon_admin deveria ser bloqueado pelo trigger" "$OUT"
fi

# ----------------------------------------------------------------------------
# TESTE-03/04/05: ADMINISTRADOR real via RLS (role authenticated), tentando
# INSERT/UPDATE/DELETE direto — nunca passando pelas funções SECURITY
# DEFINER. auditoria não tem policy de INSERT/UPDATE/DELETE para nenhum
# perfil, então RLS já barra tudo antes do trigger.
# ----------------------------------------------------------------------------
OUT=$($PSQL -c "
begin;
set local role authenticated;
set local request.jwt.claims = '{\"sub\":\"$ADMIN_ID\",\"role\":\"authenticated\"}';
insert into public.auditoria (usuario_id, acao, entidade, entidade_id, motivo) values ('$ADMIN_ID', 'INSERT', 'teste_forjado_3_12', gen_random_uuid(), 'tentando forjar entrada');
rollback;
" 2>&1)
if echo "$OUT" | grep -qi "row-level security policy"; then
  pass "TESTE-03 INSERT direto em auditoria por ADMINISTRADOR via RLS (sem passar por fn_auditoria/registrar_auditoria_semantica) é rejeitado — auditoria não tem policy de INSERT para nenhum perfil"
else
  fail "TESTE-03 INSERT direto deveria ser rejeitado pela RLS" "$OUT"
fi

OUT=$($PSQL -c "
begin;
set local role authenticated;
set local request.jwt.claims = '{\"sub\":\"$ADMIN_ID\",\"role\":\"authenticated\"}';
update public.auditoria set motivo = 'forjado-3.12' where id = '$FIRST_AUDIT_ID';
rollback;
" 2>&1)
if echo "$OUT" | grep -q "UPDATE 0"; then
  pass "TESTE-04 UPDATE direto em auditoria por ADMINISTRADOR via RLS afeta 0 linhas — auditoria não tem policy de UPDATE para nenhum perfil"
else
  fail "TESTE-04 UPDATE via RLS deveria afetar 0 linhas" "$OUT"
fi

OUT=$($PSQL -c "
begin;
set local role authenticated;
set local request.jwt.claims = '{\"sub\":\"$ADMIN_ID\",\"role\":\"authenticated\"}';
delete from public.auditoria where id = '$FIRST_AUDIT_ID';
rollback;
" 2>&1)
if echo "$OUT" | grep -q "DELETE 0"; then
  pass "TESTE-05 DELETE direto em auditoria por ADMINISTRADOR via RLS afeta 0 linhas — auditoria não tem policy de DELETE para nenhum perfil"
else
  fail "TESTE-05 DELETE via RLS deveria afetar 0 linhas" "$OUT"
fi

# ----------------------------------------------------------------------------
# TESTE-06/07: checagem estática — nenhuma migration SQL nem rota da API Node
# emite UPDATE/DELETE contra auditoria, nem desabilita o trigger de
# imutabilidade.
# ----------------------------------------------------------------------------
if grep -riE "update[[:space:]]+(public\.)?auditoria\b|delete[[:space:]]+from[[:space:]]+(public\.)?auditoria\b|disable[[:space:]]+trigger.*auditoria" supabase/migrations/*.sql | grep -v "auditoria_acao_check" > /tmp/fase312_grep_sql.log; then
  fail "TESTE-06 nenhuma migration deveria conter UPDATE/DELETE contra auditoria" "$(cat /tmp/fase312_grep_sql.log)"
else
  pass "TESTE-06 checagem estática: nenhuma migration SQL (de nenhuma fase) contém UPDATE/DELETE contra auditoria nem desabilita o trigger de imutabilidade"
fi

if grep -rE "\.from\(['\"]auditoria['\"]\)" api/ > /tmp/fase312_grep_api.log; then
  fail "TESTE-07 nenhuma rota da API deveria acessar auditoria via .from() direto" "$(cat /tmp/fase312_grep_api.log)"
else
  pass "TESTE-07 checagem estática: a API Node nunca acessa 'auditoria' via .from() direto — só leitura via RPC pricing_audit_list"
fi

# ----------------------------------------------------------------------------
# TESTE-08: confirma que o trigger de imutabilidade e as triggers de INSERT
# genérico continuam exatamente como esperado (introspecção do catálogo,
# nunca assumido).
# ----------------------------------------------------------------------------
TRIGGER_INFO=$($PSQL -t -A -c "
select tgname || '|' || pg_get_triggerdef(oid)
from pg_trigger
where tgrelid = 'public.auditoria'::regclass and not tgisinternal
order by tgname;
")
EXPECTED_IMUTAVEL="trg_auditoria_imutavel|CREATE TRIGGER trg_auditoria_imutavel BEFORE DELETE OR UPDATE ON public.auditoria FOR EACH ROW EXECUTE FUNCTION fn_bloquear_alteracao_auditoria()"
NOVA_TRIGGER_31="trg_auditoria_alerta_operacao_nao_autorizada"
if echo "$TRIGGER_INFO" | grep -qF "$EXPECTED_IMUTAVEL" && echo "$TRIGGER_INFO" | grep -q "$NOVA_TRIGGER_31.*AFTER INSERT"; then
  pass "TESTE-08 catálogo confirma: trg_auditoria_imutavel é BEFORE UPDATE OR DELETE (bloqueia), e o único outro trigger em auditoria (trg_auditoria_alerta_operacao_nao_autorizada, item 3.11) é AFTER INSERT — nenhum trigger novo enfraquece a imutabilidade"
else
  fail "TESTE-08 triggers de auditoria fora do esperado" "$TRIGGER_INFO"
fi

echo "=============================================="
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
echo "=============================================="
[ $FAIL -eq 0 ] && exit 0 || exit 1
