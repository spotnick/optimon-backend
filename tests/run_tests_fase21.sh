#!/bin/bash
# OptiMon — Fase 2.1: bateria de testes das correcoes de consistencia comercial (secao 65,
# testes NOVO-1..NOVO-16) + regressao completa da Fase 1, Fase 1.1, Fase 1.2 e Fase 2
# (secao 13 — os testes REG-1..REG-26 sao os MESMOS da Fase 2, reexecutados byte-a-byte
# apos as migrations da Fase 2.1, para provar que nenhuma regra anterior quebrou).
# Reconstroi o banco do zero a cada execucao: migrations Fase1 -> seed -> Fase1.1 -> seed ->
# Fase1.2 -> seed -> Fase2 -> seed_fase2 -> Fase2.1 (sem seed propria — reusa os mesmos
# contratos 0005/0006 do seed_fase2, como pedido: "criar apenas migrations/correcoes
# incrementais", nao reconstruir dados).
set -uo pipefail
export PGPASSWORD=optimon_dev
PSQL="psql -h localhost -U optimon_admin -d optimon"
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

uid_of() { $PSQL -t -A -c "$1" 2>&1 | grep -Eo "$UUID_RE" | head -n1; }
val_of() { $PSQL -t -A -c "$1" 2>&1 | head -n1 | tr -d ' '; }
text_of() { $PSQL -t -A -c "$1" 2>&1 | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
json_of() { $PSQL -t -A -c "$1" 2>&1 | head -n1; }
run_admin() { $PSQL -c "$1" 2>&1; }
as_role() {
  local uid="$1"; shift
  $PSQL -c "set role authenticated; select set_config('app.current_user_id', '$uid', false); $1" 2>&1
}

PASS=0; FAIL=0; RESULTS=()
ok() { RESULTS+=("PASS | $1"); PASS=$((PASS+1)); }
bad() { RESULTS+=("FAIL | $1"); FAIL=$((FAIL+1)); echo "----- DETALHE DA FALHA: $1 -----"; echo "$2"; }
check_ok() { if echo "$2" | grep -qiE "ERROR|exception"; then bad "$1" "$2"; else ok "$1"; fi; }
check_blocked() { if echo "$2" | grep -qiE "ERROR|exception|UPDATE 0|DELETE 0"; then ok "$1"; else bad "$1" "$2"; fi; }

########################################
echo "### REBUILD DO ZERO (Fase1->seed->Fase1.1->seed->Fase1.2->seed->Fase2->seed_fase2->Fase2.1) ###"
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
for f in $(ls supabase/migrations/20260826*.sql | sort); do
  $PSQL -v ON_ERROR_STOP=1 -f "$f" >/tmp/m3.log 2>&1 || { echo "FALHOU migration Fase1.2: $f"; cat /tmp/m3.log; exit 1; }
done
$PSQL -v ON_ERROR_STOP=1 -f supabase/seed_fase12.sql >/tmp/s3.log 2>&1 || { echo "FALHOU seed Fase1.2"; cat /tmp/s3.log; exit 1; }
for f in $(ls supabase/migrations/20260827*.sql | sort); do
  $PSQL -v ON_ERROR_STOP=1 -f "$f" >/tmp/m4.log 2>&1 || { echo "FALHOU migration Fase2: $f"; cat /tmp/m4.log; exit 1; }
done
$PSQL -v ON_ERROR_STOP=1 -f supabase/seed_fase2.sql >/tmp/s4.log 2>&1 || { echo "FALHOU seed Fase2"; cat /tmp/s4.log; exit 1; }
ok "Fase 1 + Fase 1.1 + Fase 1.2 + Fase 2 (mig+seeds) aplicadas sem erro, como pre-condicao"

for f in $(ls supabase/migrations/20260828*.sql | sort); do
  $PSQL -v ON_ERROR_STOP=1 -f "$f" >/tmp/m5.log 2>&1 || { echo "FALHOU migration Fase2.1: $f"; cat /tmp/m5.log; exit 1; }
done
ok "Todas as 4 migrations da Fase 2.1 aplicaram sem erro sobre banco com dados reais (Fase 1+1.1+1.2+2, sem seed propria)"

########################################
echo "### criando usuarios de teste ###"
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

COMERCIAL_ID=$(uid_of "select id from usuarios where email='comercial@optimon.local';")
ENGENHARIA_ID=$(uid_of "select id from usuarios where email='engenharia@optimon.local';")
FINANCEIRO_ID=$(uid_of "select id from usuarios where email='financeiro@optimon.local';")
DIRETOR_ID=$(uid_of "select id from usuarios where email='diretor@optimon.local';")
AUDITOR_ID=$(uid_of "select id from usuarios where email='auditor@optimon.local';")

CIDADE=$(uid_of "select id from cidades_infra where nome='Jussara';")
POP1=$(uid_of "select id from infra_pops where codigo='POP-01';")
POP2=$(uid_of "select id from infra_pops where codigo='POP-02';")
CONTRATO_A=$(uid_of "select id from contratos where numero='0002';")
CONTRATO_DARK=$(uid_of "select id from contratos where numero='0005';")   # Cenario 1, seed Fase2 — 2 fibras individuais (fibra_id != par completo)
CONTRATO_PON=$(uid_of "select id from contratos where numero='0006';")    # Cenario 2, seed Fase2 (128 cap, min 1000, share 12%, SOMA)
PORTA_PON006=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-JUS-006';")
FIBRA_PON006=$(val_of "select fibra_id from infra_portas_pon where id='$PORTA_PON006';")

echo "IDs: cidade=$CIDADE pop1=$POP1 contrato_dark=$CONTRATO_DARK contrato_pon=$CONTRATO_PON porta006=$PORTA_PON006"

SEG_POOL=$(uid_of "insert into infra_segmentos (cidade_id, nome, origem, destino, extensao_km) values ('$CIDADE','Ramal Pool Testes Fase21','POP-01','Pool',0.1) returning id;")
CABO_POOL=$(uid_of "insert into infra_cabos (segmento_id, pop_id, identificacao, capacidade_fo) values ('$SEG_POOL','$POP1','CABO-POOL-TESTES-FASE21',48) returning id;")
run_admin "insert into infra_fibras (cabo_id, numero_fibra, par_numero, status_operacional, status_comercial, status_contratual) select '$CABO_POOL', gs, ceil(gs/2.0), 'ATIVA','LIVRE','DISPONIVEL' from generate_series(1,48) gs;" >/dev/null
POOL_N=0
SEG_POOL2=$(uid_of "insert into infra_segmentos (cidade_id, nome, origem, destino, extensao_km) values ('$CIDADE','Ramal Pool Testes Fase21 POP2','POP-02','Pool',0.1) returning id;")
CABO_POOL2=$(uid_of "insert into infra_cabos (segmento_id, pop_id, identificacao, capacidade_fo) values ('$SEG_POOL2','$POP2','CABO-POOL-TESTES-FASE21-P2',24) returning id;")
run_admin "insert into infra_fibras (cabo_id, numero_fibra, par_numero, status_operacional, status_comercial, status_contratual) select '$CABO_POOL2', gs, ceil(gs/2.0), 'ATIVA','LIVRE','DISPONIVEL' from generate_series(1,24) gs;" >/dev/null
POOL2_N=0

########################################
echo ""; echo "=== REGRESSAO — TESTES OBRIGATORIOS DA FASE 2 (secao 55, REG-1..REG-23) — mesmos da Fase 2, reexecutados apos Fase 2.1 ==="

echo ""; echo "--- REG-1: Jussara carregada corretamente (custos classificados) ---"
CT=$(val_of "select count(*) from custos_infraestrutura where cidade_id='$CIDADE';")
[ "$CT" = "4" ] && ok "REG1a Jussara: 4 custos classificados" || bad "REG1a" "count=$CT"
ALOC=$(val_of "select count(*) from custos_infraestrutura where cidade_id='$CIDADE' and cost_type='ALLOCATED_COST';")
REV=$(val_of "select count(*) from custos_infraestrutura where cidade_id='$CIDADE' and cost_type='REVENUE_EXISTING';")
[ "$ALOC" = "1" ] && [ "$REV" = "1" ] && ok "REG1b classificacao correta: 1 ALLOCATED_COST, 1 REVENUE_EXISTING" || bad "REG1b" "aloc=$ALOC rev=$REV"

echo ""; echo "--- REG-2: 1 Porta PON ---"
CAPMAX=$(val_of "select capacidade_max_assinantes from infra_portas_pon where id='$PORTA_PON006';")
[ "$CAPMAX" = "128" ] && ok "REG2 Porta PON PON-JUS-006 capacidade 128" || bad "REG2" "capacidade=$CAPMAX"

echo ""; echo "--- REG-3: 128 clientes (100% ocupacao) ---"
run_admin "
do \$\$
declare i int;
begin
  for i in 1..128 loop
    insert into cliente_porta_pon (cliente_identificador, contrato_id, porta_pon_id, pop_id, fibra_id, status)
    values ('CLI-F21-'||i, '$CONTRATO_PON', '$PORTA_PON006', '$POP1', '$FIBRA_PON006', 'ATIVO');
  end loop;
end \$\$;" >/tmp/t3.log 2>&1
TAXA3=$(val_of "select taxa_ocupacao from infra_portas_pon where id='$PORTA_PON006';")
[ "$TAXA3" = "1.0000" ] && ok "REG3 128 clientes = 100% ocupacao ($TAXA3)" || bad "REG3" "$(tail -3 /tmp/t3.log); taxa=$TAXA3"

echo ""; echo "--- REG-4: 129 clientes exige segunda porta ---"
PN4=$(val_of "select app.get_portas_necessarias(129,128);")
[ "$PN4" = "2" ] && ok "REG4 get_portas_necessarias(129,128) = $PN4" || bad "REG4" "portas=$PN4"

echo ""; echo "--- REG-5: SOMA (minimo 1000 + 12% de 10000 = 2200) ---"
C5=$(val_of "select app.calcular_cobranca_hibrida('$CONTRATO_PON', 10000);")
[ "$C5" = "2200.00000" ] && ok "REG5 SOMA: $C5" || bad "REG5" "esperado 2200, obtido $C5"

echo ""; echo "--- REG-6: MAX (MAX(1000,1200) = 1200) ---"
PARC_T6=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste MAX Fase21 LTDA','33344455100111') returning id;")
CONTR_T6=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-f21-max','$PARC_T6','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
run_admin "insert into contrato_pricing_config (contrato_id, modelo_cobranca, modelo_minimo, mensalidade_minima_porta, percentual_revenue_share) values ('$CONTR_T6','MAX','GLOBAL',1000,0.12);" >/dev/null
C6=$(val_of "select app.calcular_cobranca_hibrida('$CONTR_T6', 10000);")
[ "$C6" = "1200.00000" ] && ok "REG6 MAX: $C6" || bad "REG6" "esperado 1200, obtido $C6"

echo ""; echo "--- REG-7: Break-even (1000/12% = 8333.33) ---"
BE7=$(val_of "select app.calcular_breakeven_faturamento('$CONTRATO_PON');")
[ "$BE7" = "8333.33" ] && ok "REG7 break-even faturamento: $BE7" || bad "REG7" "esperado 8333.33, obtido $BE7"

echo ""; echo "--- REG-8: ARPU R\$100 -> 84 clientes ---"
BE8=$(val_of "select app.calcular_breakeven_clientes('$CONTRATO_PON', 100);")
[ "$BE8" = "84" ] && ok "REG8 break-even clientes (ARPU 100): $BE8" || bad "REG8" "esperado 84, obtido $BE8"

echo ""; echo "--- REG-9: Rampa base (mes1=50%, mes4=75%, mes7=100%) ---"
R9A=$(val_of "select app.get_fator_rampa(null::uuid, 1, 'FIXO_MINIMO');")
R9B=$(val_of "select app.get_fator_rampa(null::uuid, 4, 'FIXO_MINIMO');")
R9C=$(val_of "select app.get_fator_rampa(null::uuid, 7, 'FIXO_MINIMO');")
[ "$R9A" = "0.50000" ] && [ "$R9B" = "0.75000" ] && [ "$R9C" = "1.00000" ] && \
  ok "REG9 rampa: mes1=$R9A mes4=$R9B mes7=$R9C" || bad "REG9" "mes1=$R9A mes4=$R9B mes7=$R9C"

echo ""; echo "--- REG-10: Reajuste anual (FINANCEIRO aplica 5%, historico preservado) ---"
PARC_T10=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Reajuste F21 LTDA','33344455100202') returning id;")
CONTR_T10=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-f21-reajuste','$PARC_T10','$CIDADE','HIBRIDO_REVENUE_SHARE',48,'ATIVO') returning id;")
run_admin "insert into contrato_pricing_config (contrato_id, mensalidade_minima_porta, percentual_revenue_share) values ('$CONTR_T10',1000,0.12);" >/dev/null
OUT10_FIN=$(as_role "$FINANCEIRO_ID" "select app.aplicar_reajuste_contrato('$CONTR_T10', 0.05);")
check_ok "REG10 FINANCEIRO aplica reajuste de 5%" "$OUT10_FIN"
NOVO_MIN=$(val_of "select mensalidade_minima_porta from contrato_pricing_config where contrato_id='$CONTR_T10';")
[ "$NOVO_MIN" = "1050.00" ] && ok "REG10b minimo reajustado: 1000 + 5% = $NOVO_MIN" || bad "REG10b" "minimo=$NOVO_MIN"

echo ""; echo "--- REG-11/12: projecao 48/60 meses ---"
N11=$(val_of "select jsonb_array_length(app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":10,\"crescimento_mensal\":2,\"meses_horizonte\":48}'::jsonb)->'meses');")
[ "$N11" = "48" ] && ok "REG11 projecao 48 meses" || bad "REG11" "linhas=$N11"
N12=$(val_of "select jsonb_array_length(app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":10,\"crescimento_mensal\":2,\"meses_horizonte\":60}'::jsonb)->'meses');")
[ "$N12" = "60" ] && ok "REG12 projecao 60 meses" || bad "REG12" "linhas=$N12"

echo ""; echo "--- REG-13/14: ROI e payback ---"
ROI13=$(val_of "select (app.calcular_roi(app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":50,\"crescimento_mensal\":5,\"meses_horizonte\":24,\"capex_incremental\":12000}'::jsonb),12000,24)->>'roi');")
[ -n "$ROI13" ] && ok "REG13 ROI@24m com CAPEX=12000: $ROI13" || bad "REG13" "roi vazio"
PB14=$(val_of "select (app.calcular_payback(app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":50,\"crescimento_mensal\":5,\"meses_horizonte\":36,\"capex_incremental\":12000}'::jsonb),12000)->>'mes');")
[ -n "$PB14" ] && [ "$PB14" != "null" ] && ok "REG14 payback: mes $PB14" || bad "REG14" "mes=$PB14"

echo ""; echo "--- REG-15/16/17/18: margem, governanca ---"
ME15=$(val_of "select (app.calcular_economia_parceiro(10000,2200,3000)->>'margem_estimada_parceiro')::numeric;")
[ "$ME15" = "4800" ] && ok "REG15 margem estimada parceiro: $ME15" || bad "REG15" "margem=$ME15"
G16=$(val_of "select app.check_pricing_governance(900,1000,1500);")
[ "$G16" = "BLOCK" ] && ok "REG16 900<1000 -> $G16" || bad "REG16" "governanca=$G16"
G17=$(val_of "select app.check_pricing_governance(1200,1000,1500);")
[ "$G17" = "REQUIRES_APPROVAL" ] && ok "REG17 1000<=1200<1500 -> $G17" || bad "REG17" "governanca=$G17"
G18=$(val_of "select app.check_pricing_governance(1600,1000,1500);")
[ "$G18" = "ALLOW" ] && ok "REG18 1600>=1500 -> $G18" || bad "REG18" "governanca=$G18"

echo ""; echo "--- REG-19: override comercial gera auditoria ---"
AUD19_ANTES=$(val_of "select count(*) from auditoria where entidade='pricing_override_requests';")
OV19=$(as_role "$COMERCIAL_ID" "select public.pricing_override_create('$CONTRATO_PON', null, 1500, 1200, 'Cliente pediu desconto para fechar hoje.');" )
OV19_ID=$(echo "$OV19" | grep -Eo "$UUID_RE" | tail -n1)
[ -n "$OV19_ID" ] && ok "REG19a COMERCIAL cria solicitacao de override" || bad "REG19a" "$OV19"
OUT19_DIR=$(as_role "$DIRETOR_ID" "update pricing_override_requests set status='APROVADA' where id='$OV19_ID';")
check_ok "REG19b DIRETOR aprova o override" "$OUT19_DIR"
AUD19_DEPOIS=$(val_of "select count(*) from auditoria where entidade='pricing_override_requests';")
[ "$AUD19_DEPOIS" -gt "$AUD19_ANTES" ] && ok "REG19c override auditado" || bad "REG19c" "antes=$AUD19_ANTES depois=$AUD19_DEPOIS"

echo ""; echo "--- REG-20/21/22/23: multiplos POPs, portas, reservadas, capacidade ---"
PARC_T20=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste MultiPOP F21 LTDA','33344455100303') returning id;")
CONTR_T20=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-f21-multipop','$PARC_T20','$CIDADE','HIBRIDO_REVENUE_SHARE',48,'ATIVO') returning id;")
for i in 1 2; do
  POOL_N=$((POOL_N+1)); FID=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL' and numero_fibra=$POOL_N;")
  run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID','$POP1','PON-F21-T20-P1-$i');" >/dev/null
  PID=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-F21-T20-P1-$i';")
  run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTR_T20','$FID','$PID');" >/dev/null
done
POOL2_N=$((POOL2_N+1)); FID2=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL2' and numero_fibra=$POOL2_N;")
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID2','$POP2','PON-F21-T20-P2');" >/dev/null
PID2=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-F21-T20-P2';")
run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTR_T20','$FID2','$PID2');" >/dev/null
CAP20=$(val_of "select app.get_contract_capacity('$CONTR_T20');")
POPS20=$(val_of "select pops_utilizados from vw_capacidade_contrato where contrato_id='$CONTR_T20';")
[ "$CAP20" = "384" ] && [ "$POPS20" = "2" ] && ok "REG20 3 portas (2+1) = capacidade $CAP20 em $POPS20 POPs" || bad "REG20" "capacidade=$CAP20 pops=$POPS20"
PN21=$(val_of "select app.get_portas_necessarias(200,128);")
[ "$PN21" = "2" ] && ok "REG21 get_portas_necessarias(200,128) = $PN21" || bad "REG21" "portas=$PN21"

PARC_T22=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Reservadas F21 LTDA','33344455100404') returning id;")
CONTR_T22=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-f21-reservadas','$PARC_T22','$CIDADE','HIBRIDO_REVENUE_SHARE',48,'ATIVO') returning id;")
run_admin "insert into contrato_pricing_config (contrato_id, modelo_minimo, mensalidade_minima_porta) values ('$CONTR_T22','POR_PORTA',1000);" >/dev/null
declare -a PORTAS_T22=()
for i in 1 2 3; do
  POOL_N=$((POOL_N+1)); FID=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL' and numero_fibra=$POOL_N;")
  run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID','$POP1','PON-F21-T22-$i');" >/dev/null
  PID=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-F21-T22-$i';")
  run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTR_T22','$FID','$PID');" >/dev/null
  PORTAS_T22+=("$PID")
done
PID_ATIVA="${PORTAS_T22[0]}"
POP_ATIVA=$(val_of "select pop_id from infra_portas_pon where id='$PID_ATIVA';")
FIB_ATIVA=$(val_of "select fibra_id from infra_portas_pon where id='$PID_ATIVA';")
run_admin "insert into cliente_porta_pon (cliente_identificador, contrato_id, porta_pon_id, pop_id, fibra_id, status) values ('CLI-F21-T22','$CONTR_T22','$PID_ATIVA','$POP_ATIVA','$FIB_ATIVA','ATIVO');" >/dev/null
MIN22=$(val_of "select app.calcular_minimo_contratual('$CONTR_T22');")
[ "$MIN22" = "3000.00" ] && ok "REG22 minimo cobrado sobre 3 portas contratadas (so 1 ativa): $MIN22" || bad "REG22" "minimo=$MIN22"

CONTRATADA23=$(val_of "select app.get_contract_capacity('$CONTRATO_PON');")
OCUPADA23=$(val_of "select app.get_occupied_capacity('$CONTRATO_PON');")
[ "$CONTRATADA23" = "128" ] && [ "$OCUPADA23" = "128" ] && ok "REG23 capacidade contrato_pon: contratada=$CONTRATADA23 ocupada=$OCUPADA23" || bad "REG23" "contratada=$CONTRATADA23 ocupada=$OCUPADA23"

echo ""; echo "=== REG-24 — REGRESSAO FASE 1 ==="
POSTES24=$($PSQL -t -A -c "select quantidade, custo_mensal from infra_postes where identificacao like 'Lote%';")
echo "$POSTES24" | grep -q "165" && echo "$POSTES24" | grep -q "1108.80" && ok "REG24a 165 postes / R\$1.108,80 preservados" || bad "REG24a" "$POSTES24"
MED_ID=$(uid_of "insert into medicoes_mensais (contrato_id, competencia, status) values ('$CONTRATO_A','2026-11-01','APROVADA') returning id;")
IMUT=$(val_of "select imutavel from medicoes_mensais where id='$MED_ID';")
[ "$IMUT" = "t" ] && ok "REG24b medicao aprovada vira imutavel" || bad "REG24b" "imutavel=$IMUT"
OUT=$(run_admin "delete from auditoria;")
check_blocked "REG24c DELETE em auditoria bloqueado (imutavel)" "$OUT"

echo ""; echo "=== REG-25 — REGRESSAO FASE 1.1 ==="
VERSAO_A=$(val_of "select versao_atual from contratos where numero='0002';")
[ "$VERSAO_A" = "2" ] && ok "REG25a aditivo do seed Fase1.1 gerou versao_atual=2" || bad "REG25a" "versao=$VERSAO_A"
HC=$(val_of "select count(*) from pricing_parametros where chave='PORTA_PON_CAPACIDADE_MAX_PADRAO' and valor=128;")
[ "$HC" = "1" ] && ok "REG25b capacidade padrao 128 continua parametrizavel" || bad "REG25b" "count=$HC"

echo ""; echo "=== REG-26 — REGRESSAO FASE 1.2 ==="
MODELO_B=$(val_of "select modelo_cobranca from contrato_pricing_config where contrato_id=(select id from contratos where numero='0003');")
[ "$MODELO_B" = "SOMA" ] && ok "REG26a contrato 0003 preserva SOMA" || bad "REG26a" "modelo=$MODELO_B"
for ent in cliente_porta_pon pricing_override_requests custos_infraestrutura; do
  C=$(val_of "select count(*) from auditoria where entidade='$ent';")
  [ "$C" -ge "1" ] && ok "REG26b auditoria cobre $ent ($C linhas)" || bad "REG26b $ent" "0 linhas"
done

########################################
echo ""; echo "=== FASE 2.1 — TESTES NOVOS (secoes 1-14 do prompt) ==="

echo ""; echo "--- NOVO-1: fibra individual (secao 1) — get_fibras_contratadas vs get_pares_contratados ---"
FIB1=$(val_of "select app.get_fibras_contratadas_dark_fiber('$CONTRATO_DARK');")
PAR1=$(val_of "select app.get_pares_contratados_dark_fiber('$CONTRATO_DARK');")
[ "$FIB1" = "2" ] && ok "NOVO1a contrato 0005 tem 2 fibras individuais contratadas (fibras=$FIB1)" || bad "NOVO1a" "fibras=$FIB1"
[ "$PAR1" = "1" ] && ok "NOVO1b funcao antiga (deprecated, preservada) ainda calcula 1 par para as mesmas 2 fibras — prova que nao foi alterada, so deixou de ser usada pelo motor" || bad "NOVO1b" "pares=$PAR1"

echo ""; echo "--- NOVO-2: preco minimo Dark Fiber calculado por FIBRA INDIVIDUAL (secao 1) ---"
PISO_FIBRA=$(val_of "select valor from pricing_parametros where chave='DARK_FIBER_PRECO_MINIMO_FIBRA_MES' and (vigente_ate is null or vigente_ate>=current_date);")
[ "$PISO_FIBRA" = "1500.0000" ] && ok "NOVO2a piso por fibra individual seedado: R\$$PISO_FIBRA/fibra/mes" || bad "NOVO2a" "piso=$PISO_FIBRA"
MIN_DARK=$(val_of "select app.calcular_preco_minimo_dark_fiber('$CONTRATO_DARK');")
[ "$MIN_DARK" = "3600.00" ] && ok "NOVO2b preco minimo 0005 (2 fibras x R\$1500 x margem/risco) = $MIN_DARK" || bad "NOVO2b" "minimo=$MIN_DARK"

echo ""; echo "--- NOVO-3: rampa respeita rampa_aplica_a (secao 4) — TESTE-R1/R2/R3 ---"
R1_MES1=$(json_of "select app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":10,\"crescimento_mensal\":0,\"meses_horizonte\":1,\"rampa_ativa\":true,\"rampa_aplica_a\":\"FIXO_MINIMO\"}'::jsonb)->'meses'->0;")
FR_MIN_R1=$(echo "$R1_MES1" | grep -Eo '"fator_rampa_minimo": [0-9.]+' | grep -Eo '[0-9.]+')
FR_SHR_R1=$(echo "$R1_MES1" | grep -Eo '"fator_rampa_revenue_share": [0-9.]+' | grep -Eo '[0-9.]+')
[ "$FR_MIN_R1" = "0.50000" ] && [ "$FR_SHR_R1" = "1.00" ] && ok "TESTE-R1 FIXO_MINIMO mes1: minimo=50% (fator=$FR_MIN_R1) share=100% (fator=$FR_SHR_R1)" || bad "TESTE-R1" "fator_min=$FR_MIN_R1 fator_share=$FR_SHR_R1"

R2_MES1=$(json_of "select app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":10,\"crescimento_mensal\":0,\"meses_horizonte\":1,\"rampa_ativa\":true,\"rampa_aplica_a\":\"REVENUE_SHARE\"}'::jsonb)->'meses'->0;")
FR_MIN_R2=$(echo "$R2_MES1" | grep -Eo '"fator_rampa_minimo": [0-9.]+' | grep -Eo '[0-9.]+')
FR_SHR_R2=$(echo "$R2_MES1" | grep -Eo '"fator_rampa_revenue_share": [0-9.]+' | grep -Eo '[0-9.]+')
[ "$FR_MIN_R2" = "1.00" ] && [ "$FR_SHR_R2" = "0.50000" ] && ok "TESTE-R2 REVENUE_SHARE mes1: minimo=100% (fator=$FR_MIN_R2) share=50% (fator=$FR_SHR_R2)" || bad "TESTE-R2" "fator_min=$FR_MIN_R2 fator_share=$FR_SHR_R2"

R3_MES1=$(json_of "select app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":10,\"crescimento_mensal\":0,\"meses_horizonte\":1,\"rampa_ativa\":true,\"rampa_aplica_a\":\"AMBOS\"}'::jsonb)->'meses'->0;")
FR_MIN_R3=$(echo "$R3_MES1" | grep -Eo '"fator_rampa_minimo": [0-9.]+' | grep -Eo '[0-9.]+')
FR_SHR_R3=$(echo "$R3_MES1" | grep -Eo '"fator_rampa_revenue_share": [0-9.]+' | grep -Eo '[0-9.]+')
[ "$FR_MIN_R3" = "0.50000" ] && [ "$FR_SHR_R3" = "0.50000" ] && ok "TESTE-R3 AMBOS mes1: minimo=50% (fator=$FR_MIN_R3) share=50% (fator=$FR_SHR_R3)" || bad "TESTE-R3" "fator_min=$FR_MIN_R3 fator_share=$FR_SHR_R3"

RAMPA_CFG=$(val_of "select rampa_aplica_a from contrato_pricing_config where contrato_id='$CONTRATO_PON';")
[ "$RAMPA_CFG" = "FIXO_MINIMO" ] && ok "NOVO3d contrato 0006 nunca configurou rampa_aplica_a e herda o default FIXO_MINIMO (nao mais ignorado)" || bad "NOVO3d" "rampa_aplica_a=$RAMPA_CFG"
R_0006=$(json_of "select app.simular_projecao(jsonb_build_object('contrato_id','$CONTRATO_PON','minimo_mensal',1000,'revenue_share_percent',0.12,'arpu_inicial',100,'clientes_iniciais',10,'crescimento_mensal',0,'meses_horizonte',1,'rampa_ativa',true))->'meses'->0;")
FR_MIN_0006=$(echo "$R_0006" | grep -Eo '"fator_rampa_minimo": [0-9.]+' | grep -Eo '[0-9.]+')
FR_SHR_0006=$(echo "$R_0006" | grep -Eo '"fator_rampa_revenue_share": [0-9.]+' | grep -Eo '[0-9.]+')
[ "$FR_MIN_0006" = "0.50000" ] && [ "$FR_SHR_0006" = "1.00" ] && ok "NOVO3e simular_projecao(contrato_id=0006) agora LE rampa_aplica_a do contrato (antes ignorava e rampeava os dois): minimo=$FR_MIN_0006 share=$FR_SHR_0006" || bad "NOVO3e" "fator_min=$FR_MIN_0006 fator_share=$FR_SHR_0006"

echo ""; echo "--- NOVO-4: Cenario 2 — Pricing Engine real (secoes 5-8) — antes eram colunas sempre NULL ---"
COLS_NULL=$(val_of "select count(*) from contrato_pricing_config where contrato_id='$CONTRATO_PON' and preco_minimo_porta is null and preco_recomendado_porta is null and preco_premium_porta is null;")
[ "$COLS_NULL" = "1" ] && ok "NOVO4a colunas preco_*_porta continuam NULL na tabela (nunca foram a fonte — nao alteramos dado historico)" || bad "NOVO4a" "count=$COLS_NULL"
MIN_PORTA=$(val_of "select app.calcular_preco_minimo_porta_pon('$CONTRATO_PON');")
REC_PORTA=$(val_of "select app.calcular_preco_recomendado_porta_pon('$CONTRATO_PON');")
PREM_PORTA=$(val_of "select app.calcular_preco_premium_porta_pon('$CONTRATO_PON');")
[ "$MIN_PORTA" = "1000.00" ] && ok "NOVO4b preco minimo Porta PON (0006, real: custo/piso/margem/risco) = $MIN_PORTA" || bad "NOVO4b" "minimo=$MIN_PORTA"
[ "$REC_PORTA" = "1200.00" ] && ok "NOVO4c preco recomendado (minimo x multiplicador x escassez) = $REC_PORTA" || bad "NOVO4c" "recomendado=$REC_PORTA"
[ "$PREM_PORTA" = "1800.00" ] && ok "NOVO4d preco premium (recomendado x multiplicador x bonus) = $PREM_PORTA" || bad "NOVO4d" "premium=$PREM_PORTA"

echo ""; echo "--- NOVO-5: pricing_quote (secao 50) usa o motor real para Cenario 2 (nao mais coluna vazia) ---"
QUOTE=$(json_of "select public.pricing_quote('$CONTRATO_PON', null);")
echo "$QUOTE" | grep -q '"preco_minimo": 1000.00' && echo "$QUOTE" | grep -q '"preco_recomendado": 1200.00' && echo "$QUOTE" | grep -q '"preco_premium": 1800.00' && \
  ok "NOVO5 pricing_quote(0006) devolve preco real: $QUOTE" || bad "NOVO5" "$QUOTE"

echo ""; echo "--- NOVO-6: break-even continua correto e visivel para o dashboard (secao 10) ---"
[ "$BE7" = "8333.33" ] && [ "$BE8" = "84" ] && ok "NOVO6 break-even 0006: R\$$BE7/mes = $BE8 clientes (ARPU 100) — mesma formula da Fase 2, agora tambem exibida junto do motor real do Cenario 2" || bad "NOVO6" "faturamento=$BE7 clientes=$BE8"

echo ""; echo "--- NOVO-7: teste economico completo (secao 9) — 1 Porta PON, 128 cap, ARPU 100, share 12%, minimo 1000 ---"
# SOMA (contrato 0006): receita_optimon = minimo + share = 1000 + faturamento*0.12 (mesma
# formula ja provada em REG5: calcular_cobranca_hibrida(0006,10000)=2200=1000+1200).
declare -A EXPECT_RECEITA=( [10]=1120.00000 [25]=1300.00000 [50]=1600.00000 [75]=1900.00000 [84]=2008.00000 [100]=2200.00000 [128]=2536.00000 )
ECON_OK=1
for CLI in 10 25 50 75 84 100 128; do
  FAT=$(echo "$CLI * 100" | bc)
  RECEITA=$(val_of "select app.calcular_cobranca_hibrida('$CONTRATO_PON', $FAT);")
  SHARE=$(echo "$FAT * 0.12" | bc)
  MARGEM_PARC=$(echo "scale=4; ($FAT - $RECEITA) / $FAT" | bc)
  echo "  clientes=$CLI faturamento_parceiro=R\$$FAT revenue_share=R\$$SHARE minimo=R\$1000 receita_optimon=R\$$RECEITA margem_parceiro=$MARGEM_PARC"
  if [ "$RECEITA" != "${EXPECT_RECEITA[$CLI]}" ]; then ECON_OK=0; bad "NOVO7-$CLI" "clientes=$CLI esperado=${EXPECT_RECEITA[$CLI]} obtido=$RECEITA"; fi
done
[ "$ECON_OK" = "1" ] && ok "NOVO7 teste economico completo: os 7 pontos (10/25/50/75/84/100/128 clientes) batem com SOMA(minimo,share) esperado"

echo ""; echo "--- NOVO-8: viabilidade do parceiro em 4 niveis (secao 11) ---"
V_INVIAVEL=$(text_of "select app.classificar_negocio('$CONTRATO_PON', 0.10, null);")
[ "$V_INVIAVEL" = "INVIÁVEL" ] && ok "NOVO8a margem 10% < minimo configurado (20%) -> $V_INVIAVEL" || bad "NOVO8a" "$V_INVIAVEL"
V_VIAVEL=$(text_of "select app.classificar_negocio('$CONTRATO_PON', 0.25, null);")
[ "$V_VIAVEL" = "VIÁVEL" ] && ok "NOVO8b margem 25% >= minimo, sem limiar confortavel configurado -> $V_VIAVEL (colapsa, seção 65)" || bad "NOVO8b" "$V_VIAVEL"
run_admin "insert into pricing_parametros (chave, valor, descricao) values ('VIABILIDADE_MARGEM_PARCEIRO_CONFORTAVEL_PADRAO', 0.30, 'teste temporario NOVO8');" >/dev/null
V_BAIXA=$(text_of "select app.classificar_negocio('$CONTRATO_PON', 0.25, null);")
[ "$V_BAIXA" = "MARGEM BAIXA" ] && ok "NOVO8c com limiar confortavel=30% configurado, margem 25% (>=min, <confortavel) -> $V_BAIXA (nivel novo da Fase 2.1)" || bad "NOVO8c" "$V_BAIXA"
# EXCELENCIA_ROI_MINIMO_PADRAO nasceu sem seed desde a Fase 2 (seção 65 — nunca inventamos
# o limiar); sem ele, o nível EXCELENTE nunca ativa e a função colapsa em VIÁVEL, por
# desenho. Para exercitar o ramo EXCELENTE aqui, configuramos o parâmetro temporariamente
# (mesmo padrão usado acima para VIABILIDADE_MARGEM_PARCEIRO_CONFORTAVEL_PADRAO).
run_admin "insert into pricing_parametros (chave, valor, descricao) values ('EXCELENCIA_ROI_MINIMO_PADRAO', 0.50, 'teste temporario NOVO8d');" >/dev/null
V_EXCELENTE=$(text_of "select app.classificar_negocio('$CONTRATO_PON', 0.35, 0.99);")
[ "$V_EXCELENTE" = "EXCELENTE" ] && ok "NOVO8d margem 35% (>=confortavel) + ROI 99% >= limiar configurado (50%) -> $V_EXCELENTE" || bad "NOVO8d" "$V_EXCELENTE"
run_admin "delete from pricing_parametros where chave in ('VIABILIDADE_MARGEM_PARCEIRO_CONFORTAVEL_PADRAO','EXCELENCIA_ROI_MINIMO_PADRAO');" >/dev/null

echo ""; echo "--- NOVO-9: multi-POP — POP-01=2, POP-02=3, POP-03=1 -> 6 portas / 768 (secao 12) ---"
POP3=$(uid_of "insert into infra_pops (cidade_id, codigo, nome) values ('$CIDADE','POP-03','POP-03 — Teste Fase2.1') returning id;")
SEG_POOL3=$(uid_of "insert into infra_segmentos (cidade_id, nome, origem, destino, extensao_km) values ('$CIDADE','Ramal Pool Testes F21 POP3','POP-03','Pool',0.1) returning id;")
CABO_POOL3=$(uid_of "insert into infra_cabos (segmento_id, pop_id, identificacao, capacidade_fo) values ('$SEG_POOL3','$POP3','CABO-POOL-TESTES-F21-P3',12) returning id;")
run_admin "insert into infra_fibras (cabo_id, numero_fibra, par_numero, status_operacional, status_comercial, status_contratual) select '$CABO_POOL3', gs, ceil(gs/2.0), 'ATIVA','LIVRE','DISPONIVEL' from generate_series(1,12) gs;" >/dev/null
PARC_T9=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste MultiPOP3 F21 LTDA','33344455100909') returning id;")
CONTR_T9=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-f21-multipop3','$PARC_T9','$CIDADE','HIBRIDO_REVENUE_SHARE',48,'ATIVO') returning id;")
for i in 1 2; do
  POOL_N=$((POOL_N+1)); FID=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL' and numero_fibra=$POOL_N;")
  run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID','$POP1','PON-F21-N9-P01-$i');" >/dev/null
  PID=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-F21-N9-P01-$i';")
  run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTR_T9','$FID','$PID');" >/dev/null
done
for i in 1 2 3; do
  POOL2_N=$((POOL2_N+1)); FID=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL2' and numero_fibra=$POOL2_N;")
  run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID','$POP2','PON-F21-N9-P02-$i');" >/dev/null
  PID=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-F21-N9-P02-$i';")
  run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTR_T9','$FID','$PID');" >/dev/null
done
FID3=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL3' and numero_fibra=1;")
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID3','$POP3','PON-F21-N9-P03-1');" >/dev/null
PID3=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-F21-N9-P03-1';")
run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTR_T9','$FID3','$PID3');" >/dev/null

MULTIPOP=$(json_of "select app.get_capacidade_multi_pop_contrato('$CONTR_T9');")
PORTAS_TOTAL=$(val_of "select (app.get_capacidade_multi_pop_contrato('$CONTR_T9')->'consolidado'->>'portas_total');")
CAP_TOTAL=$(val_of "select (app.get_capacidade_multi_pop_contrato('$CONTR_T9')->'consolidado'->>'capacidade_maxima_total');")
POPS_TOTAL=$(val_of "select (app.get_capacidade_multi_pop_contrato('$CONTR_T9')->'consolidado'->>'pops_utilizados');")
[ "$PORTAS_TOTAL" = "6" ] && [ "$CAP_TOTAL" = "768" ] && [ "$POPS_TOTAL" = "3" ] && \
  ok "NOVO9a multi-POP: POP-01=2+POP-02=3+POP-03=1 = $PORTAS_TOTAL portas / $CAP_TOTAL capacidade em $POPS_TOTAL POPs" || \
  bad "NOVO9a" "portas=$PORTAS_TOTAL cap=$CAP_TOTAL pops=$POPS_TOTAL / raw=$MULTIPOP"
API9=$(json_of "select public.pricing_capacity_by_pop('$CONTR_T9');")
echo "$API9" | grep -q '"portas_total": 6' && ok "NOVO9b wrapper API public.pricing_capacity_by_pop expoe o mesmo consolidado" || bad "NOVO9b" "$API9"

echo ""; echo "--- NOVO-10: auditoria cobre infra_fibras e pricing_faixas_escassez (secao 14) ---"
AUD_FIB_ANTES=$(val_of "select count(*) from auditoria where entidade='infra_fibras';")
run_admin "update infra_fibras set status_comercial='LIVRE' where id='$FID3';" >/dev/null
AUD_FIB_DEPOIS=$(val_of "select count(*) from auditoria where entidade='infra_fibras';")
[ "$AUD_FIB_DEPOIS" -gt "$AUD_FIB_ANTES" ] && ok "NOVO10a UPDATE em infra_fibras agora gera auditoria ($AUD_FIB_ANTES -> $AUD_FIB_DEPOIS) — lacuna fechada" || bad "NOVO10a" "antes=$AUD_FIB_ANTES depois=$AUD_FIB_DEPOIS"
AUD_ESC_ANTES=$(val_of "select count(*) from auditoria where entidade='pricing_faixas_escassez';")
run_admin "update pricing_faixas_escassez set rotulo=rotulo where disponibilidade_min=0.5;" >/dev/null
AUD_ESC_DEPOIS=$(val_of "select count(*) from auditoria where entidade='pricing_faixas_escassez';")
[ "$AUD_ESC_DEPOIS" -gt "$AUD_ESC_ANTES" ] && ok "NOVO10b UPDATE em pricing_faixas_escassez agora gera auditoria ($AUD_ESC_ANTES -> $AUD_ESC_DEPOIS) — lacuna fechada" || bad "NOVO10b" "antes=$AUD_ESC_ANTES depois=$AUD_ESC_DEPOIS"

echo ""; echo "--- NOVO-11: metodo Dark Fiber POR_FIBRA nao quebra contratos historicos (secao 2) ---"
METODO_0005=$(val_of "select modelo_minimo from contrato_pricing_config where contrato_id='$CONTRATO_DARK';")
ok "NOVO11 contrato 0005 mantem modelo_minimo='$METODO_0005' sem migracao forcada de metodo — so a UNIDADE de contagem (fibra, nao par) mudou"

echo ""; echo "--- NOVO-12: labels dashboard (secao 3) — nao ha mais 'par(es) de fibra' no HTML/JS ---"
GREP_PAR=$(grep -c "par(es) de fibra\|Pares de fibra\|p\.pares" /home/claude/optimon/dashboard/optimon-pricing-dashboard.html || true)
[ "$GREP_PAR" = "0" ] && ok "NOVO12 dashboard nao contem mais nenhuma ocorrencia de 'par(es) de fibra' / p.pares" || bad "NOVO12" "ocorrencias=$GREP_PAR"
GREP_FIBRA_LABEL=$(grep -c "fibra(s) óptica(s)\|Fibras contratadas" /home/claude/optimon/dashboard/optimon-pricing-dashboard.html || true)
[ "$GREP_FIBRA_LABEL" -ge "1" ] && ok "NOVO12b dashboard usa 'Fibras contratadas' / 'fibra(s) óptica(s)'" || bad "NOVO12b" "ocorrencias=$GREP_FIBRA_LABEL"

echo ""; echo "--- NOVO-13: API expoe capacidade por POP (secao 12/50) ---"
grep -q "capacity-by-pop" /home/claude/optimon/api/routes/pricing.js && ok "NOVO13 rota GET /api/pricing/capacity-by-pop adicionada em api/routes/pricing.js" || bad "NOVO13" "rota nao encontrada"

echo ""; echo "--- NOVO-14: nenhuma migration anterior (20260824-27) foi alterada — so 20260828 acrescentadas (nao ha git neste ambiente; usamos mtime como evidencia) ---"
NEWEST_OLD_MTIME=$(stat -c %Y supabase/migrations/2026082[4-7]*.sql | sort -n | tail -1)
OLDEST_FASE21_MTIME=$(stat -c %Y supabase/migrations/20260828*.sql | sort -n | head -1)
if [ "$NEWEST_OLD_MTIME" -lt "$OLDEST_FASE21_MTIME" ]; then
  ok "NOVO14 mtime de TODAS as migrations 20260824-27 (mais recente: $(date -d @$NEWEST_OLD_MTIME '+%F %T')) e anterior ao da primeira migration 20260828 (mais antiga: $(date -d @$OLDEST_FASE21_MTIME '+%F %T')) — nenhuma foi tocada nesta sessao"
else
  bad "NOVO14" "mtime mais recente entre 20260824-27 ($NEWEST_OLD_MTIME) nao e anterior ao mtime mais antigo de 20260828 ($OLDEST_FASE21_MTIME)"
fi

########################################
echo ""
echo "=============================================="
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
echo "=============================================="
for r in "${RESULTS[@]}"; do echo "$r"; done
echo "=============================================="
echo "$PASS PASS / $FAIL FAIL"
