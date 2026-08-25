#!/bin/bash
# OptiMon — Fase 1.2: bateria de testes obrigatoria (secao 29) + regressao completa da
# Fase 1 e Fase 1.1 (Teste 20). Reconstroi o banco do zero a cada execucao, na mesma
# ordem que prova nao quebrar dados existentes: migrations Fase 1 -> seed.sql ->
# migrations Fase 1.1 -> seed_fase11.sql -> migrations Fase 1.2 -> seed_fase12.sql.
set -uo pipefail
export PGPASSWORD=optimon_dev
PSQL="psql -h localhost -U optimon_admin -d optimon"
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

uid_of() { $PSQL -t -A -c "$1" 2>&1 | grep -Eo "$UUID_RE" | head -n1; }
val_of() { $PSQL -t -A -c "$1" 2>&1 | head -n1 | tr -d ' '; }
run_admin() { $PSQL -c "$1" 2>&1; }
as_role() {
  local uid="$1"; shift
  $PSQL -c "set role authenticated; select set_config('app.current_user_id', '$uid', false); $1" 2>&1
}

PASS=0; FAIL=0; RESULTS=()
ok() { RESULTS+=("PASS | $1"); PASS=$((PASS+1)); }
bad() { RESULTS+=("FAIL | $1"); FAIL=$((FAIL+1)); echo "----- DETALHE DA FALHA: $1 -----"; echo "$2"; }
check_ok() { if echo "$2" | grep -qiE "ERROR|exception"; then bad "$1" "$2"; else ok "$1"; fi; }
# "UPDATE 0"/"DELETE 0" tambem conta como bloqueado: RLS pode filtrar a linha em vez de
# lancar excecao (a UPDATE/DELETE simplesmente nao atinge nenhuma linha) — mesmo
# comportamento ja documentado na Fase 1.1 (H3), nao e uma falha do harness.
check_blocked() { if echo "$2" | grep -qiE "ERROR|exception|UPDATE 0|DELETE 0"; then ok "$1"; else bad "$1" "$2"; fi; }

########################################
echo "### REBUILD DO ZERO (Fase 1 -> seed -> Fase 1.1 -> seed -> Fase 1.2 -> seed) ###"
sudo -u postgres psql -c "DROP DATABASE IF EXISTS optimon;" >/dev/null
sudo -u postgres psql -c "CREATE DATABASE optimon OWNER optimon_admin;" >/dev/null
cd /home/claude/optimon
$PSQL -v ON_ERROR_STOP=1 -f supabase/dev-local-only/shim_supabase_auth.sql >/dev/null || { echo "shim falhou"; exit 1; }
for f in $(ls supabase/migrations/20260824*.sql | sort); do
  $PSQL -v ON_ERROR_STOP=1 -f "$f" >/tmp/m1.log 2>&1 || { echo "FALHOU migration Fase1: $f"; cat /tmp/m1.log; exit 1; }
done
$PSQL -v ON_ERROR_STOP=1 -f supabase/seed.sql >/tmp/s1.log 2>&1 || { echo "FALHOU seed Fase1"; cat /tmp/s1.log; exit 1; }
for f in $(ls supabase/migrations/20260825*.sql | sort); do
  $PSQL -v ON_ERROR_STOP=1 -f "$f" >/tmp/m2.log 2>&1 || { echo "FALHOU migration Fase1.1: $f"; cat /tmp/m2.log; exit 1; }
done
$PSQL -v ON_ERROR_STOP=1 -f supabase/seed_fase11.sql >/tmp/s2.log 2>&1 || { echo "FALHOU seed Fase1.1"; cat /tmp/s2.log; exit 1; }
ok "Fase 1 (20 migrations + seed) e Fase 1.1 (14 migrations + seed) aplicadas sem erro, como pre-condicao"

for f in $(ls supabase/migrations/20260826*.sql | sort); do
  $PSQL -v ON_ERROR_STOP=1 -f "$f" >/tmp/m3.log 2>&1 || { echo "FALHOU migration Fase1.2: $f"; cat /tmp/m3.log; exit 1; }
done
ok "Todas as 7 migrations da Fase 1.2 aplicaram sem erro sobre banco com dados reais (Fase 1 + Fase 1.1)"

$PSQL -v ON_ERROR_STOP=1 -f supabase/seed_fase12.sql >/tmp/s3.log 2>&1 || { echo "FALHOU seed Fase1.2"; cat /tmp/s3.log; exit 1; }
ok "Seed complementar da Fase 1.2 aplicado sem erro"

########################################
echo "### criando usuarios de teste (um por perfil) ###"
run_admin "
do \$\$
declare v_id uuid;
begin
  insert into auth.users (email) values ('comercial@optimon.local') returning id into v_id;
  insert into public.usuarios (id, nome, email, perfil) values (v_id, 'Teste Comercial', 'comercial@optimon.local', 'COMERCIAL');
  insert into auth.users (email) values ('engenharia@optimon.local') returning id into v_id;
  insert into public.usuarios (id, nome, email, perfil) values (v_id, 'Teste Engenharia', 'engenharia@optimon.local', 'ENGENHARIA');
  insert into auth.users (email) values ('financeiro@optimon.local') returning id into v_id;
  insert into public.usuarios (id, nome, email, perfil) values (v_id, 'Teste Financeiro', 'financeiro@optimon.local', 'FINANCEIRO');
  insert into auth.users (email) values ('diretor@optimon.local') returning id into v_id;
  insert into public.usuarios (id, nome, email, perfil) values (v_id, 'Teste Diretor', 'diretor@optimon.local', 'DIRETOR');
  insert into auth.users (email) values ('auditor@optimon.local') returning id into v_id;
  insert into public.usuarios (id, nome, email, perfil) values (v_id, 'Teste Auditor', 'auditor@optimon.local', 'AUDITOR');
end \$\$;" >/dev/null

ADMIN_ID=$(uid_of "select id from usuarios where email='admin@optimon.local';")
COMERCIAL_ID=$(uid_of "select id from usuarios where email='comercial@optimon.local';")
ENGENHARIA_ID=$(uid_of "select id from usuarios where email='engenharia@optimon.local';")
FINANCEIRO_ID=$(uid_of "select id from usuarios where email='financeiro@optimon.local';")
DIRETOR_ID=$(uid_of "select id from usuarios where email='diretor@optimon.local';")
AUDITOR_ID=$(uid_of "select id from usuarios where email='auditor@optimon.local';")

CIDADE=$(uid_of "select id from cidades_infra where nome='Jussara';")
POP1=$(uid_of "select id from infra_pops where codigo='POP-01';")
POP2=$(uid_of "select id from infra_pops where codigo='POP-02';")
CABO1=$(uid_of "select id from infra_cabos where identificacao='CABO-JUSSARA-01';")
CABO2=$(uid_of "select id from infra_cabos where identificacao='CABO-JUSSARA-02';")
CONTRATO_A=$(uid_of "select id from contratos where numero='0002';")
CONTRATO_B=$(uid_of "select id from contratos where numero='0003';")
CONTRATO_C=$(uid_of "select id from contratos where numero='0004';")
PARCEIRO_A=$(uid_of "select parceiro_id from contratos where numero='0002';")
PARCEIRO_C=$(uid_of "select parceiro_id from contratos where numero='0004';")

echo "IDs: cidade=$CIDADE pop1=$POP1 pop2=$POP2 contrato_a=$CONTRATO_A contrato_b=$CONTRATO_B contrato_c=$CONTRATO_C"

# Pools de fibras livres dedicados a este script de teste — evita qualquer risco de
# reusar sem querer uma fibra ja contratada por outro teste (CABO1/CABO2 do seed real
# tem poucas fibras livres e sao compartilhadas por varios cenarios). Cada teste que
# precisa de "uma fibra qualquer, livre, num POP conhecido" saca da pool certa em vez de
# adivinhar numero_fibra em CABO1/CABO2 diretamente.
SEG_POOL1=$(uid_of "insert into infra_segmentos (cidade_id, nome, origem, destino, extensao_km) values ('$CIDADE','Ramal Pool Testes POP-01','POP-01','Pool',0.1) returning id;")
CABO_POOL1=$(uid_of "insert into infra_cabos (segmento_id, pop_id, identificacao, capacidade_fo) values ('$SEG_POOL1','$POP1','CABO-POOL-TESTES-POP1',24) returning id;")
run_admin "insert into infra_fibras (cabo_id, numero_fibra, par_numero, status_operacional, status_comercial, status_contratual) select '$CABO_POOL1', gs, ceil(gs/2.0), 'ATIVA','LIVRE','DISPONIVEL' from generate_series(1,24) gs;" >/dev/null
SEG_POOL2=$(uid_of "insert into infra_segmentos (cidade_id, nome, origem, destino, extensao_km) values ('$CIDADE','Ramal Pool Testes POP-02','POP-02','Pool',0.1) returning id;")
CABO_POOL2=$(uid_of "insert into infra_cabos (segmento_id, pop_id, identificacao, capacidade_fo) values ('$SEG_POOL2','$POP2','CABO-POOL-TESTES-POP2',24) returning id;")
run_admin "insert into infra_fibras (cabo_id, numero_fibra, par_numero, status_operacional, status_comercial, status_contratual) select '$CABO_POOL2', gs, ceil(gs/2.0), 'ATIVA','LIVRE','DISPONIVEL' from generate_series(1,24) gs;" >/dev/null
POOL1_N=0; POOL2_N=0
# NAO usar uma funcao chamada via $(...) para isto: command substitution roda em
# subshell, e o incremento de POOL1_N/POOL2_N dentro dela se perderia ao retornar
# (cada chamada voltaria a pegar sempre a fibra 1). Por isso o incremento e feito
# inline no shell principal, e so a consulta (que nao precisa manter estado) via uid_of.

########################################
echo ""; echo "=== TESTES OBRIGATORIOS DA FASE 1.2 (secao 29) ==="

echo ""; echo "--- TESTE 1: SOMA (minimo R\$1000 + 12% de R\$10000 = R\$2200) ---"
COBRANCA1=$(val_of "select app.calcular_cobranca_hibrida('$CONTRATO_B', 10000);")
[ "$COBRANCA1" = "2200.00000" ] && ok "TESTE1 SOMA: 1000 + 1200 = $COBRANCA1" || bad "TESTE1 SOMA" "esperado 2200, obtido $COBRANCA1"

echo ""; echo "--- TESTE 2: MAX (minimo R\$1000, revenue share R\$1200 -> MAX=1200) ---"
# fixture dedicado com modelo_minimo GLOBAL para bater com os numeros literais do prompt
# (contrato_a do seed usa POR_PORTA x 2 portas = 2000, que testaria uma conta diferente).
PARCEIRO_T2=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste MAX LTDA','22233344000155') returning id;")
CONTRATO_T2=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-max','$PARCEIRO_T2','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
run_admin "insert into contrato_pricing_config (contrato_id, modelo_cobranca, modelo_minimo, mensalidade_minima_porta, percentual_revenue_share) values ('$CONTRATO_T2','MAX','GLOBAL',1000,0.12);" >/dev/null
COBRANCA2=$(val_of "select app.calcular_cobranca_hibrida('$CONTRATO_T2', 10000);")
[ "$COBRANCA2" = "1200.00000" ] && ok "TESTE2 MAX: MAX(1000,1200) = $COBRANCA2" || bad "TESTE2 MAX" "esperado 1200, obtido $COBRANCA2"

echo ""; echo "--- TESTE 3: DEFAULT (contrato sem especificar modelo -> SOMA) ---"
PARCEIRO_T3=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Default LTDA','22233344000246') returning id;")
CONTRATO_T3=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-default','$PARCEIRO_T3','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
run_admin "insert into contrato_pricing_config (contrato_id, mensalidade_minima_porta) values ('$CONTRATO_T3', 500);" >/dev/null
MODELO3=$(val_of "select modelo_cobranca from contrato_pricing_config where contrato_id='$CONTRATO_T3';")
[ "$MODELO3" = "SOMA" ] && ok "TESTE3 DEFAULT: modelo_cobranca resolveu para $MODELO3 sem ser informado" || bad "TESTE3 DEFAULT" "modelo=$MODELO3"

echo ""; echo "--- TESTE 4/5: CAPACIDADE DA PORTA (128 permite, 129 bloqueia) ---"
POOL2_N=$((POOL2_N+1)); FIBRA_T4=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL2' and numero_fibra=$POOL2_N;")
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FIBRA_T4','$POP2','PON-TESTE-CAP');" >/dev/null
PORTA_T4=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-TESTE-CAP';")
PARCEIRO_T4=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Capacidade LTDA','22233344000337') returning id;")
CONTRATO_T4=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-cap','$PARCEIRO_T4','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTRATO_T4','$FIBRA_T4','$PORTA_T4');" >/dev/null
run_admin "
do \$\$
declare i int;
begin
  for i in 1..128 loop
    insert into cliente_porta_pon (cliente_identificador, contrato_id, porta_pon_id, pop_id, fibra_id, status)
    values ('CLI-CAP-'||i, '$CONTRATO_T4', '$PORTA_T4', '$POP2', '$FIBRA_T4', 'ATIVO');
  end loop;
end \$\$;" >/tmp/t4.log 2>&1
TAXA4=$(val_of "select taxa_ocupacao from infra_portas_pon where id='$PORTA_T4';")
[ "$TAXA4" = "1.0000" ] && ok "TESTE4 CAPACIDADE: 128/128 = 100% ($TAXA4)" || bad "TESTE4 CAPACIDADE" "$(cat /tmp/t4.log | tail -3); taxa=$TAXA4"
OUT5=$(run_admin "insert into cliente_porta_pon (cliente_identificador, contrato_id, porta_pon_id, pop_id, fibra_id, status) values ('CLI-CAP-129','$CONTRATO_T4','$PORTA_T4','$POP2','$FIBRA_T4','ATIVO');")
echo "$OUT5" | grep -q "CAPACITY_EXCEEDED" && ok "TESTE5 EXCEDENTE: cliente 129 rejeitado com CAPACITY_EXCEEDED" || bad "TESTE5 EXCEDENTE" "$OUT5"

echo ""; echo "--- TESTE 6: CAPACIDADE RESERVADA (5 portas contratadas, 3 ativas, 2 reservadas) ---"
PARCEIRO_T6=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Reservada LTDA','22233344000418') returning id;")
CONTRATO_T6=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-reservada','$PARCEIRO_T6','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
run_admin "insert into contrato_pricing_config (contrato_id, modelo_minimo, mensalidade_minima_porta) values ('$CONTRATO_T6','POR_PORTA',1000);" >/dev/null
declare -a PORTAS_T6=()
for idxfo in 1 2 3 4; do
  POOL1_N=$((POOL1_N+1)); FIBRA_LOOP=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL1' and numero_fibra=$POOL1_N;")
  run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FIBRA_LOOP','$POP1','PON-TESTE-6-$idxfo');" >/dev/null
  PORTA_LOOP=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-TESTE-6-$idxfo';")
  run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTRATO_T6','$FIBRA_LOOP','$PORTA_LOOP');" >/dev/null
  PORTAS_T6+=("$PORTA_LOOP")
done
# 5a porta: POP-02 (pool dedicada)
POOL2_N=$((POOL2_N+1)); FIBRA_5A=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL2' and numero_fibra=$POOL2_N;")
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FIBRA_5A','$POP2','PON-TESTE-6-5A');" >/dev/null
PORTA_5A=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-TESTE-6-5A';")
run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTRATO_T6','$FIBRA_5A','$PORTA_5A');" >/dev/null
PORTAS_T6+=("$PORTA_5A")
# ativa 3 das 5 (1 cliente cada)
for idx in 0 1 2; do
  PID="${PORTAS_T6[$idx]}"
  PPID_POP=$(val_of "select pop_id from infra_portas_pon where id='$PID';")
  PPID_FIB=$(val_of "select fibra_id from infra_portas_pon where id='$PID';")
  run_admin "insert into cliente_porta_pon (cliente_identificador, contrato_id, porta_pon_id, pop_id, fibra_id, status) values ('CLI-T6-$idx','$CONTRATO_T6','$PID','$PPID_POP','$PPID_FIB','ATIVO');" >/dev/null
done
CONTRATADAS6=$(val_of "select portas_contratadas from vw_contrato_capacidade where contrato_id='$CONTRATO_T6';")
ATIVAS6=$(val_of "select portas_ativas from vw_contrato_capacidade where contrato_id='$CONTRATO_T6';")
RESERVADAS6=$(val_of "select portas_reservadas from vw_contrato_capacidade where contrato_id='$CONTRATO_T6';")
[ "$CONTRATADAS6" = "5" ] && [ "$ATIVAS6" = "3" ] && [ "$RESERVADAS6" = "2" ] && \
  ok "TESTE6 CAPACIDADE RESERVADA: contratadas=$CONTRATADAS6 ativas=$ATIVAS6 reservadas=$RESERVADAS6" || \
  bad "TESTE6 CAPACIDADE RESERVADA" "contratadas=$CONTRATADAS6 ativas=$ATIVAS6 reservadas=$RESERVADAS6"

echo ""; echo "--- TESTE 7: COBRANCA RESERVADA (5 portas x R\$1000 = R\$5000, mesmo com so 3 ativas) ---"
MINIMO7=$(val_of "select app.calcular_minimo_contratual('$CONTRATO_T6');")
[ "$MINIMO7" = "5000.00" ] && ok "TESTE7 COBRANCA RESERVADA: minimo=$MINIMO7" || bad "TESTE7 COBRANCA RESERVADA" "minimo=$MINIMO7"

echo ""; echo "--- TESTE 8: COMPARTILHAMENTO (PON exclusiva, 2o contrato tenta -> BLOCK) ---"
PORTA_JUS003=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-JUS-003';")
FIBRA_JUS003=$(uid_of "select fibra_id from infra_portas_pon where codigo_porta='PON-JUS-003';")
PARCEIRO_T8=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Compartilhamento LTDA','22233344000590') returning id;")
CONTRATO_T8=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-compart','$PARCEIRO_T8','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
OUT8=$(as_role "$DIRETOR_ID" "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTRATO_T8','$FIBRA_JUS003','$PORTA_JUS003');")
check_blocked "TESTE8 COMPARTILHAMENTO: PON-JUS-003 ja exclusiva de outro contrato -> BLOCK" "$OUT8"

echo ""; echo "--- TESTE 9: COMPARTILHAMENTO AUTORIZADO (1o compartilhado, 2o exige aprovacao) ---"
POOL1_N=$((POOL1_N+1)); FIBRA_T9=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL1' and numero_fibra=$POOL1_N;")
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FIBRA_T9','$POP1','PON-TESTE-9');" >/dev/null
PORTA_T9=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-TESTE-9';")
PARCEIRO_T9A=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Compart A LTDA','22233344000681') returning id;")
PARCEIRO_T9B=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Compart B LTDA','22233344000772') returning id;")
CONTRATO_T9A=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-compart-a','$PARCEIRO_T9A','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
CONTRATO_T9B=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-compart-b','$PARCEIRO_T9B','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
OUT9A=$(as_role "$DIRETOR_ID" "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id, compartilhamento_autorizado) values ('$CONTRATO_T9A','$FIBRA_T9','$PORTA_T9', true);")
check_ok "TESTE9a DIRETOR autoriza 1o vinculo compartilhado" "$OUT9A"
OUT9B_ENG=$(as_role "$ENGENHARIA_ID" "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id, compartilhamento_autorizado) values ('$CONTRATO_T9B','$FIBRA_T9','$PORTA_T9', true);")
check_blocked "TESTE9b ENGENHARIA nao pode juntar 2o vinculo numa porta ja compartilhada sem aprovacao (REQUIRES_APPROVAL)" "$OUT9B_ENG"
OUT9B_DIR=$(as_role "$DIRETOR_ID" "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id, compartilhamento_autorizado) values ('$CONTRATO_T9B','$FIBRA_T9','$PORTA_T9', true);")
check_ok "TESTE9c DIRETOR pode aprovar o 2o vinculo compartilhado" "$OUT9B_DIR"

echo ""; echo "--- TESTE 10/11: CLIENTE/PON (ativar e cancelar) ---"
# Reaproveita a 4a porta do TESTE6 (ainda RESERVADA, sem cliente) — evita puxar mais uma
# fibra da pool so para isso.
PORTA_T10="${PORTAS_T6[3]}"
FIBRA_T10=$(val_of "select fibra_id from infra_portas_pon where id='$PORTA_T10';")
CLI10=$(uid_of "insert into cliente_porta_pon (cliente_identificador, contrato_id, porta_pon_id, pop_id, fibra_id, status) values ('CLIENTE-001','$CONTRATO_T6','$PORTA_T10','$POP1','$FIBRA_T10','ATIVO') returning id;")
UTIL10=$(val_of "select capacidade_utilizada_assinantes from infra_portas_pon where id='$PORTA_T10';")
[ "$UTIL10" = "1" ] && ok "TESTE10 CLIENTE/PON: capacidade utilizada = $UTIL10 apos ativar CLIENTE-001" || bad "TESTE10 CLIENTE/PON" "utilizada=$UTIL10"
run_admin "update cliente_porta_pon set status='CANCELADO' where id='$CLI10';" >/dev/null
UTIL11=$(val_of "select capacidade_utilizada_assinantes from infra_portas_pon where id='$PORTA_T10';")
[ "$UTIL11" = "0" ] && ok "TESTE11 CLIENTE CANCELADO: capacidade reduziu para $UTIL11" || bad "TESTE11 CLIENTE CANCELADO" "utilizada=$UTIL11"

echo ""; echo "--- TESTE 12: MULTIPLOS POPs (2+1+2 = 5 portas no mesmo contrato) ---"
POP3=$(uid_of "insert into infra_pops (cidade_id, codigo, nome, tipo) values ('$CIDADE','POP-03','POP-03 Teste','DISTRIBUICAO') returning id;")
SEG3=$(uid_of "insert into infra_segmentos (cidade_id, nome, origem, destino, extensao_km) values ('$CIDADE','Ramal Teste POP-03','POP-03','Teste',0.5) returning id;")
CABO3=$(uid_of "insert into infra_cabos (segmento_id, pop_id, identificacao, capacidade_fo) values ('$SEG3','$POP3','CABO-TESTE-03',4) returning id;")
run_admin "insert into infra_fibras (cabo_id, numero_fibra, par_numero, status_operacional, status_comercial, status_contratual) select '$CABO3', gs, ceil(gs/2.0), 'ATIVA','LIVRE','DISPONIVEL' from generate_series(1,4) gs;" >/dev/null
PARCEIRO_T12=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste MultiPOP LTDA','22233344000863') returning id;")
CONTRATO_T12=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-multipop','$PARCEIRO_T12','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
# 2 portas em POP-01 (pool dedicada)
for idxfo in 1 2; do
  POOL1_N=$((POOL1_N+1)); FID=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL1' and numero_fibra=$POOL1_N;")
  run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID','$POP1','PON-TESTE-12-P1-$idxfo');" >/dev/null
  PID=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-TESTE-12-P1-$idxfo';")
  run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTRATO_T12','$FID','$PID');" >/dev/null
done
# 1 porta em POP-02 (pool dedicada)
POOL2_N=$((POOL2_N+1)); FID_P2=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL2' and numero_fibra=$POOL2_N;")
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID_P2','$POP2','PON-TESTE-12-P2');" >/dev/null
PID_P2=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-TESTE-12-P2';")
run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTRATO_T12','$FID_P2','$PID_P2');" >/dev/null
# 2 portas em POP-03
for fo in 1 3; do
  FID=$(uid_of "select id from infra_fibras where cabo_id='$CABO3' and numero_fibra=$fo;")
  run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID','$POP3','PON-TESTE-12-P3-$fo');" >/dev/null
  PID=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-TESTE-12-P3-$fo';")
  run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTRATO_T12','$FID','$PID');" >/dev/null
done
TOTAL12=$(val_of "select portas_contratadas from vw_contrato_capacidade where contrato_id='$CONTRATO_T12';")
POPS12=$(val_of "select pops_utilizados from vw_capacidade_contrato where contrato_id='$CONTRATO_T12';")
[ "$TOTAL12" = "5" ] && [ "$POPS12" = "3" ] && ok "TESTE12 MULTIPLOS POPs: 2+1+2 = $TOTAL12 portas em $POPS12 POPs" || bad "TESTE12 MULTIPLOS POPs" "total=$TOTAL12 pops=$POPS12"

echo ""; echo "--- TESTE 13: EXCLUSIVIDADE (cidade inteira -> BLOCK em qualquer POP) ---"
PARCEIRO_T13=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Exclusividade LTDA','22233344000944') returning id;")
CONTRATO_T13=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-exclus','$PARCEIRO_T13','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
run_admin "insert into contrato_regras (contrato_id, exclusividade_comercial, exclusividade_cidade_id, exclusividade_tipo, permite_outros_parceiros) values ('$CONTRATO_T13', true, '$CIDADE', 'TERRITORIAL', false);" >/dev/null
R13=$(val_of "select app.check_contract_conflict('$CIDADE', '$PARCEIRO_T12', '$POP3');")
[ "$R13" = "BLOCK" ] && ok "TESTE13 EXCLUSIVIDADE: cidade inteira exclusiva -> $R13 mesmo em POP diferente" || bad "TESTE13 EXCLUSIVIDADE" "resultado=$R13"
# Neutraliza a exclusividade de cidade inteira criada so para este teste — senao ela
# "vaza" e passa a bloquear qualquer checagem de conflito na mesma cidade nos testes
# seguintes (inclusive a regressao G1/G2 da Fase 1.1, que usa a mesma $CIDADE).
run_admin "update contrato_regras set exclusividade_comercial=false where contrato_id='$CONTRATO_T13';" >/dev/null

echo ""; echo "--- TESTE 14: CAPACIDADE REMANESCENTE (sem exclusividade -> ALLOW) ---"
R14=$(val_of "select app.check_contract_conflict('$CIDADE', '$PARCEIRO_T13', '$POP1');")
# PARCEIRO_A tem exclusividade so no POP-01 com permite_outros_parceiros=true (seed Fase 1.1) -> REQUIRES_APPROVAL; testamos aqui um POP livre de exclusividade (POP-02/03) para o caminho ALLOW puro.
R14B=$(val_of "select app.check_contract_conflict('$CIDADE', '$PARCEIRO_T13', '$POP2');")
[ "$R14B" = "ALLOW" ] && ok "TESTE14 CAPACIDADE REMANESCENTE: POP sem exclusividade conflitante -> $R14B" || bad "TESTE14 CAPACIDADE REMANESCENTE" "resultado=$R14B (R14 POP1=$R14)"

echo ""; echo "--- TESTE 15: PREFEITURA (reservada, parceiro tenta -> BLOCK) ---"
OUT15=$(as_role "$COMERCIAL_ID" "insert into contrato_clientes_reservados (contrato_id, cliente_nome) values ('$CONTRATO_T13','Prefeitura Municipal Teste');")
check_blocked "TESTE15 PREFEITURA: COMERCIAL nao pode cadastrar/liberar cliente reservado" "$OUT15"

echo ""; echo "--- TESTE 16: 48 MESES (47 bloqueia, 48 permite) ---"
OUT16A=$(run_admin "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses) values ('teste-47m','$PARCEIRO_T13','$CIDADE','DARK_FIBER',47);")
check_blocked "TESTE16 47 meses sem excecao -> BLOCK" "$OUT16A"
OUT16B=$(run_admin "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-48m','$PARCEIRO_T13','$CIDADE','DARK_FIBER',48,'ATIVO');")
check_ok "TESTE16 48 meses -> ALLOW" "$OUT16B"

echo ""; echo "--- TESTE 17: SEGURANCA (secrets nao aparecem fora do ADMINISTRADOR) ---"
COLS17=$($PSQL -t -A -c "select string_agg(column_name, ',') from information_schema.columns where table_name='vw_integracoes_seguro';")
echo "$COLS17" | grep -qv "credencia" && ok "TESTE17a vw_integracoes_seguro nao expoe coluna de credenciais ($COLS17)" || bad "TESTE17a" "$COLS17"
run_admin "insert into integracoes (nome, tipo, status, credenciais_criptografadas) values ('HubSoft-Teste','REST_API','ATIVA','segredo-fake-nao-e-real');" >/dev/null
LINHAS17=$(as_role "$COMERCIAL_ID" "select count(*) from integracoes;" | grep -Eo '^\s*[0-9]+\s*$' | tr -d ' ')
[ "$LINHAS17" = "0" ] && ok "TESTE17b COMERCIAL le 0 linhas de integracoes (RLS ADMINISTRADOR-only, credenciais nunca chegam a outros perfis)" || bad "TESTE17b" "linhas=$LINHAS17"

echo ""; echo "--- TESTE 18: RBAC ---"
OUT18A=$(as_role "$COMERCIAL_ID" "insert into contrato_pricing_config (contrato_id, mensalidade_minima_porta) values ('$CONTRATO_T13', 1);")
check_blocked "TESTE18a COMERCIAL nao altera pricing" "$OUT18A"
OUT18B=$(as_role "$COMERCIAL_ID" "update contrato_regras set exclusividade_comercial=false where contrato_id='$CONTRATO_T13';")
check_blocked "TESTE18b COMERCIAL nao aprova/altera exclusividade" "$OUT18B"
OUT18C=$(as_role "$COMERCIAL_ID" "insert into contrato_regras_solicitacoes (contrato_id, tipo, descricao, solicitado_por, status) values ('$CONTRATO_T13','REDE_PROPRIA','teste','$COMERCIAL_ID','APROVADA');")
check_blocked "TESTE18c COMERCIAL nao aprova rede propria (so pode inserir PENDENTE, e mesmo assim nao decide)" "$OUT18C"
OUT18D=$(as_role "$AUDITOR_ID" "insert into parceiros (razao_social, cnpj) values ('Nao deveria existir 18','00000000000001');")
check_blocked "TESTE18d AUDITOR nao altera dados" "$OUT18D"

echo ""; echo "--- TESTE 19: AUDITORIA (porta, contrato, pricing, exclusividade) ---"
AUD_PORTA_ANTES=$(val_of "select count(*) from auditoria where entidade='infra_portas_pon';")
run_admin "update infra_portas_pon set nome='Renomeada teste 19' where id='$PORTA_T10';" >/dev/null
AUD_PORTA_DEPOIS=$(val_of "select count(*) from auditoria where entidade='infra_portas_pon';")
[ "$AUD_PORTA_DEPOIS" -gt "$AUD_PORTA_ANTES" ] && ok "TESTE19a alteracao de Porta PON auditada ($AUD_PORTA_ANTES -> $AUD_PORTA_DEPOIS)" || bad "TESTE19a" "antes=$AUD_PORTA_ANTES depois=$AUD_PORTA_DEPOIS"
AUD_CONTRATO_ANTES=$(val_of "select count(*) from auditoria where entidade='contratos' and entidade_id='$CONTRATO_T13';")
run_admin "update contratos set data_inicio=current_date where id='$CONTRATO_T13';" >/dev/null
AUD_CONTRATO_DEPOIS=$(val_of "select count(*) from auditoria where entidade='contratos' and entidade_id='$CONTRATO_T13';")
[ "$AUD_CONTRATO_DEPOIS" -gt "$AUD_CONTRATO_ANTES" ] && ok "TESTE19b alteracao de Contrato auditada" || bad "TESTE19b" "antes=$AUD_CONTRATO_ANTES depois=$AUD_CONTRATO_DEPOIS"
AUD_PRICING_ANTES=$(val_of "select count(*) from auditoria where entidade='contrato_pricing_config';")
run_admin "update contrato_pricing_config set percentual_revenue_share=0.15 where contrato_id='$CONTRATO_T2';" >/dev/null
AUD_PRICING_DEPOIS=$(val_of "select count(*) from auditoria where entidade='contrato_pricing_config';")
[ "$AUD_PRICING_DEPOIS" -gt "$AUD_PRICING_ANTES" ] && ok "TESTE19c alteracao de Pricing/Revenue Share auditada" || bad "TESTE19c" "antes=$AUD_PRICING_ANTES depois=$AUD_PRICING_DEPOIS"
AUD_EXCL_ANTES=$(val_of "select count(*) from auditoria where entidade='contrato_regras';")
run_admin "update contrato_regras set exclusividade_tipo='MISTA' where contrato_id='$CONTRATO_T13';" >/dev/null
AUD_EXCL_DEPOIS=$(val_of "select count(*) from auditoria where entidade='contrato_regras';")
[ "$AUD_EXCL_DEPOIS" -gt "$AUD_EXCL_ANTES" ] && ok "TESTE19d alteracao de Exclusividade auditada" || bad "TESTE19d" "antes=$AUD_EXCL_ANTES depois=$AUD_EXCL_DEPOIS"

########################################
echo ""; echo "=== TESTE 20 — REGRESSAO COMPLETA DA FASE 1 E FASE 1.1 (rodada sobre o banco com a Fase 1.2 aplicada) ==="

echo ""; echo "### TESTE A: FIBRA INDIVIDUAL ###"
POOL2_N=$((POOL2_N+1)); FIBRA_A=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL2' and numero_fibra=$POOL2_N;")
run_admin "update infra_fibras set status_comercial='RESERVADA' where id='$FIBRA_A';" >/dev/null
PARCEIRO_REG=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Regressao LTDA','99988877000100') returning id;")
CONTRATO_REG=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('9001','$PARCEIRO_REG','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
OUT=$(as_role "$ENGENHARIA_ID" "insert into contrato_fibras (contrato_id, fibra_id) values ('$CONTRATO_REG','$FIBRA_A');")
check_ok "A1 contratar 1 unica fibra sem exigir par" "$OUT"
ST=$(val_of "select status_contratual from infra_fibras where id='$FIBRA_A';")
[ "$ST" = "VINCULADA" ] && ok "A2 fibra contratada virou VINCULADA" || bad "A2" "status=$ST"
run_admin "update contrato_fibras set desvinculado_em = now() where contrato_id='$CONTRATO_REG' and fibra_id='$FIBRA_A';" >/dev/null
ST2=$(val_of "select status_comercial from infra_fibras where id='$FIBRA_A';")
[ "$ST2" = "RESERVADA" ] && ok "A3 desvincular NAO reverte status_comercial para LIVRE (bug Fase1 continua corrigido)" || bad "A3" "status_comercial=$ST2"

echo ""; echo "### TESTE B/K: CAPACIDADE DA PORTA PON (max 128) — checagem original via UPDATE direto ###"
OUT=$(run_admin "update infra_portas_pon set capacidade_utilizada_assinantes = 128 where codigo_porta='PON-JUS-001';")
check_ok "B1 ajustar para exatamente 128 clientes (limite) permitido" "$OUT"
OUT=$(run_admin "update infra_portas_pon set capacidade_utilizada_assinantes = 129 where codigo_porta='PON-JUS-001';")
check_blocked "B2/K clientes > capacidade maxima (129) bloqueado pela constraint" "$OUT"
run_admin "update infra_portas_pon set capacidade_utilizada_assinantes = 10 where codigo_porta='PON-JUS-001';" >/dev/null

echo ""; echo "### TESTE C: MULTIPLAS PORTAS NO MESMO POP ###"
POOL2_N=$((POOL2_N+1)); FIBRA_C1=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL2' and numero_fibra=$POOL2_N;")
POOL2_N=$((POOL2_N+1)); FIBRA_C2=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL2' and numero_fibra=$POOL2_N;")
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FIBRA_C1','$POP2','PON-REG-004');" >/dev/null
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FIBRA_C2','$POP2','PON-REG-005');" >/dev/null
VERSAO_ANTES=$(val_of "select versao_atual from contratos where numero='0002';")
[ "$VERSAO_ANTES" = "2" ] && ok "C3 aditivo aprovado no seed da Fase 1.1 ja gerou versao_atual=2 automaticamente" || bad "C3" "versao_atual=$VERSAO_ANTES"
QTD_VERSIONS=$(val_of "select count(*) from contrato_versions where contrato_id='$CONTRATO_A';")
[ "$QTD_VERSIONS" -ge "1" ] && ok "C4 contrato_versions tem o snapshot do aditivo (historico preservado)" || bad "C4" "qtd=$QTD_VERSIONS"

echo ""; echo "### TESTE D: MULTIPLOS POPs / CAPACIDADE CONSOLIDADA ###"
POPS_USADOS=$(val_of "select pops_utilizados from vw_capacidade_contrato where contrato_numero='0002';")
[ "$POPS_USADOS" = "2" ] && ok "D1 contrato 0002 usa portas em 2 POPs diferentes (via aditivo)" || bad "D1" "pops=$POPS_USADOS"
NPOPS=$(val_of "select count(*) from infra_pops where cidade_id='$CIDADE';")
[ "$NPOPS" -ge "2" ] && ok "D2 cidade Jussara tem multiplos POPs ($NPOPS)" || bad "D2" "npops=$NPOPS"

echo ""; echo "### TESTE E/F: PRICING PARAMETRIZAVEL ###"
MODELO_A=$(val_of "select modelo_cobranca from contrato_pricing_config where contrato_id='$CONTRATO_A';")
MODELO_B=$(val_of "select modelo_cobranca from contrato_pricing_config where contrato_id='$CONTRATO_B';")
[ "$MODELO_A" = "MAX" ] && [ "$MODELO_B" = "SOMA" ] && ok "E1 contrato 0002=MAX e 0003=SOMA preservados (nao alterados retroativamente pelo novo default)" || bad "E1" "A=$MODELO_A B=$MODELO_B"
HC=$(val_of "select count(*) from pricing_parametros where chave='PORTA_PON_CAPACIDADE_MAX_PADRAO' and valor=128;")
[ "$HC" = "1" ] && ok "E2 capacidade padrao 128 continua em pricing_parametros (nao hard-coded)" || bad "E2" "count=$HC"

echo ""; echo "### TESTE G: EXCLUSIVIDADE ESCOPADA / checkContractConflict (Fase 1.1) ###"
R1=$(val_of "select app.check_contract_conflict('$CIDADE','00000000-0000-0000-0000-000000000000'::uuid,'$POP2'::uuid);")
[ "$R1" = "ALLOW" ] && ok "G1 exclusividade so no POP-01 -> nova contratacao no POP-02 = ALLOW" || bad "G1" "resultado=$R1"
R2=$(val_of "select app.check_contract_conflict('$CIDADE','00000000-0000-0000-0000-000000000000'::uuid,'$POP1'::uuid);")
[ "$R2" = "REQUIRES_APPROVAL" ] && ok "G2 mesmo POP com permite_outros_parceiros=true -> REQUIRES_APPROVAL" || bad "G2" "resultado=$R2"

echo ""; echo "### TESTE H: FIBRA DE TERCEIROS (workflow) ###"
OUT=$(as_role "$COMERCIAL_ID" "insert into contrato_regras_solicitacoes (contrato_id, tipo, descricao, solicitado_por) values ('$CONTRATO_A','FIBRA_TERCEIROS','teste','$COMERCIAL_ID');")
check_ok "H1 COMERCIAL pode solicitar (nasce PENDENTE)" "$OUT"
SOLIC_ID=$(uid_of "select id from contrato_regras_solicitacoes where contrato_id='$CONTRATO_A' and tipo='FIBRA_TERCEIROS' order by criado_em desc limit 1;")
OUT=$(as_role "$COMERCIAL_ID" "update contrato_regras_solicitacoes set status='APROVADA', decidido_por='$COMERCIAL_ID' where id='$SOLIC_ID';")
check_blocked "H3 COMERCIAL NAO pode aprovar a propria solicitacao" "$OUT"
OUT=$(as_role "$DIRETOR_ID" "update contrato_regras_solicitacoes set status='APROVADA', decidido_por='$DIRETOR_ID', decidido_em=now() where id='$SOLIC_ID';")
check_ok "H4 DIRETOR pode aprovar" "$OUT"

echo ""; echo "### TESTE J: PREFEITURA / CLIENTE RESERVADO (Fase 1) ###"
OUT=$(as_role "$COMERCIAL_ID" "insert into contrato_clientes_reservados (contrato_id, cliente_nome) values ('$CONTRATO_A','Prefeitura Municipal de Jussara (regressao)');")
check_blocked "J1 COMERCIAL nao pode cadastrar cliente reservado" "$OUT"
OUT=$(as_role "$DIRETOR_ID" "insert into contrato_clientes_reservados (contrato_id, cliente_nome, motivo) values ('$CONTRATO_A','Prefeitura Municipal de Jussara (regressao)','Cliente da operacao atual - nao disponivel a parceiros');")
check_ok "J2 DIRETOR pode cadastrar cliente reservado" "$OUT"

echo ""; echo "### TESTE L: CONTRATO MINIMO 48 MESES (regressao) ###"
for meses in 24 36 47; do
  OUT=$(run_admin "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses) values ('teste-reg-$meses','$PARCEIRO_REG','$CIDADE','DARK_FIBER',$meses);")
  check_blocked "L-$meses meses sem excecao -> rejeitado" "$OUT"
done
OUT=$(run_admin "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-reg-48','$PARCEIRO_REG','$CIDADE','DARK_FIBER',48,'ATIVO');")
check_ok "L-48 meses permitido" "$OUT"

echo ""; echo "### TESTE N: SEGURANCA / RBAC (regressao) ###"
UPD=$(as_role "$COMERCIAL_ID" "update pricing_parametros set valor=1 where chave='DARK_FIBER_PRECO_MINIMO_PAR_MES'; select valor from pricing_parametros where chave='DARK_FIBER_PRECO_MINIMO_PAR_MES';")
echo "$UPD" | grep -q " 1500" && ok "N1 COMERCIAL nao altera pricing (RLS bloqueou, valor continua 1500)" || bad "N1" "$UPD"
OUT=$(as_role "$FINANCEIRO_ID" "insert into infra_fibras (cabo_id, numero_fibra, par_numero) values ('$CABO2', 99, 50);")
check_blocked "N3 FINANCEIRO nao altera infraestrutura" "$OUT"
OUT=$(as_role "$AUDITOR_ID" "insert into parceiros (razao_social, cnpj) values ('Nao deveria existir regressao','00000000000099');")
check_blocked "N4 AUDITOR nao escreve em nada" "$OUT"

echo ""; echo "### TESTE O: AUDITORIA (regressao) ###"
for ent in contratos infra_portas_pon contrato_aditivos pricing_parametros usuarios integracoes contrato_regras_solicitacoes contrato_clientes_reservados cliente_porta_pon; do
  C=$(val_of "select count(*) from auditoria where entidade='$ent';")
  [ "$C" -ge "1" ] && ok "O-auditoria cobre $ent ($C linhas)" || bad "O-auditoria $ent" "0 linhas"
done
OUT=$(run_admin "update auditoria set motivo='hack' where true;")
check_blocked "O-UPDATE em auditoria bloqueado" "$OUT"
OUT=$(run_admin "delete from auditoria;")
check_blocked "O-DELETE em auditoria bloqueado" "$OUT"

echo ""; echo "### REGRESSAO FASE 1: medicao imutavel, postes, RLS geral ###"
POSTES=$($PSQL -t -A -c "select quantidade, custo_mensal from infra_postes where identificacao like 'Lote%';")
echo "$POSTES" | grep -q "165" && ok "Regressao: 165 postes preservados" || bad "Regressao postes" "$POSTES"
echo "$POSTES" | grep -q "1108.80" && ok "Regressao: custo R\$1.108,80/mes preservado" || bad "Regressao custo postes" "$POSTES"
MED_ID=$(uid_of "insert into medicoes_mensais (contrato_id, competencia, status) values ('$CONTRATO_A','2026-09-01','APROVADA') returning id;")
IMUT=$(val_of "select imutavel from medicoes_mensais where id='$MED_ID';")
[ "$IMUT" = "t" ] && ok "Regressao: medicao aprovada vira imutavel" || bad "Regressao imutavel" "imutavel=$IMUT"
OUT=$(run_admin "update medicoes_mensais set valor_final=999 where id='$MED_ID';")
check_blocked "Regressao: update em medicao imutavel bloqueado" "$OUT"

########################################
echo ""
echo "=============================================="
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
echo "=============================================="
for r in "${RESULTS[@]}"; do echo "$r"; done
echo "=============================================="
echo "$PASS PASS / $FAIL FAIL"
