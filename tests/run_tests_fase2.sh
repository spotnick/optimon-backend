#!/bin/bash
# OptiMon — Fase 2: bateria de testes obrigatoria (secao 55, testes 1-23) + regressao
# completa da Fase 1, Fase 1.1 e Fase 1.2 (testes 24/25/26). Reconstroi o banco do zero a
# cada execucao, na ordem que prova nao quebrar dados existentes: migrations Fase 1 ->
# seed -> Fase 1.1 -> seed -> Fase 1.2 -> seed -> Fase 2 -> seed_fase2.
set -uo pipefail
export PGPASSWORD=optimon_dev
PSQL="psql -h localhost -U optimon_admin -d optimon"
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

uid_of() { $PSQL -t -A -c "$1" 2>&1 | grep -Eo "$UUID_RE" | head -n1; }
val_of() { $PSQL -t -A -c "$1" 2>&1 | head -n1 | tr -d ' '; }
# text_of preserves internal spaces (val_of strips ALL spaces via tr -d ' ', which is
# correct for numeric/uuid/enum values but corrupts free-text results like calcular_payback's
# "texto" field — "Não recuperado no período" would become "Nãorecuperadonoperíodo").
text_of() { $PSQL -t -A -c "$1" 2>&1 | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
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
echo "### REBUILD DO ZERO (Fase1 -> seed -> Fase1.1 -> seed -> Fase1.2 -> seed -> Fase2 -> seed) ###"
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
ok "Fase 1 (20 mig+seed) + Fase 1.1 (14 mig+seed) + Fase 1.2 (7 mig+seed) aplicadas sem erro, como pre-condicao"

for f in $(ls supabase/migrations/20260827*.sql | sort); do
  $PSQL -v ON_ERROR_STOP=1 -f "$f" >/tmp/m4.log 2>&1 || { echo "FALHOU migration Fase2: $f"; cat /tmp/m4.log; exit 1; }
done
ok "Todas as 10 migrations da Fase 2 aplicaram sem erro sobre banco com dados reais (Fase 1 + 1.1 + 1.2)"

$PSQL -v ON_ERROR_STOP=1 -f supabase/seed_fase2.sql >/tmp/s4.log 2>&1 || { echo "FALHOU seed Fase2"; cat /tmp/s4.log; exit 1; }
ok "Seed complementar da Fase 2 aplicado sem erro (custos Jussara + contratos 0005/0006)"

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

COMERCIAL_ID=$(uid_of "select id from usuarios where email='comercial@optimon.local';")
ENGENHARIA_ID=$(uid_of "select id from usuarios where email='engenharia@optimon.local';")
FINANCEIRO_ID=$(uid_of "select id from usuarios where email='financeiro@optimon.local';")
DIRETOR_ID=$(uid_of "select id from usuarios where email='diretor@optimon.local';")
AUDITOR_ID=$(uid_of "select id from usuarios where email='auditor@optimon.local';")

CIDADE=$(uid_of "select id from cidades_infra where nome='Jussara';")
POP1=$(uid_of "select id from infra_pops where codigo='POP-01';")
POP2=$(uid_of "select id from infra_pops where codigo='POP-02';")
CONTRATO_A=$(uid_of "select id from contratos where numero='0002';")
CONTRATO_DARK=$(uid_of "select id from contratos where numero='0005';")   # Cenario 1, seed Fase2
CONTRATO_PON=$(uid_of "select id from contratos where numero='0006';")    # Cenario 2, seed Fase2 (128 cap, min 1000, share 12%, SOMA)
PORTA_PON006=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-JUS-006';")
FIBRA_PON006=$(val_of "select fibra_id from infra_portas_pon where id='$PORTA_PON006';")

echo "IDs: cidade=$CIDADE pop1=$POP1 contrato_dark=$CONTRATO_DARK contrato_pon=$CONTRATO_PON porta006=$PORTA_PON006"

# Pool de fibras livres dedicado a este script (mesmo motivo da Fase 1.2: evitar
# qualquer risco de reusar uma fibra ja contratada por outro teste ou pelo seed).
SEG_POOL=$(uid_of "insert into infra_segmentos (cidade_id, nome, origem, destino, extensao_km) values ('$CIDADE','Ramal Pool Testes Fase2','POP-01','Pool',0.1) returning id;")
CABO_POOL=$(uid_of "insert into infra_cabos (segmento_id, pop_id, identificacao, capacidade_fo) values ('$SEG_POOL','$POP1','CABO-POOL-TESTES-FASE2',24) returning id;")
run_admin "insert into infra_fibras (cabo_id, numero_fibra, par_numero, status_operacional, status_comercial, status_contratual) select '$CABO_POOL', gs, ceil(gs/2.0), 'ATIVA','LIVRE','DISPONIVEL' from generate_series(1,24) gs;" >/dev/null
POOL_N=0
SEG_POOL2=$(uid_of "insert into infra_segmentos (cidade_id, nome, origem, destino, extensao_km) values ('$CIDADE','Ramal Pool Testes Fase2 POP2','POP-02','Pool',0.1) returning id;")
CABO_POOL2=$(uid_of "insert into infra_cabos (segmento_id, pop_id, identificacao, capacidade_fo) values ('$SEG_POOL2','$POP2','CABO-POOL-TESTES-FASE2-P2',24) returning id;")
run_admin "insert into infra_fibras (cabo_id, numero_fibra, par_numero, status_operacional, status_comercial, status_contratual) select '$CABO_POOL2', gs, ceil(gs/2.0), 'ATIVA','LIVRE','DISPONIVEL' from generate_series(1,24) gs;" >/dev/null
POOL2_N=0

########################################
echo ""; echo "=== TESTES OBRIGATORIOS DA FASE 2 (secao 55) ==="

echo ""; echo "--- TESTE 1: Jussara carregada corretamente (custos classificados) ---"
CT=$(val_of "select count(*) from custos_infraestrutura where cidade_id='$CIDADE';")
[ "$CT" = "4" ] && ok "TESTE1a Jussara: 4 custos classificados (postes/link/manutencao/prefeitura)" || bad "TESTE1a" "count=$CT"
ALOC=$(val_of "select count(*) from custos_infraestrutura where cidade_id='$CIDADE' and cost_type='ALLOCATED_COST';")
REV=$(val_of "select count(*) from custos_infraestrutura where cidade_id='$CIDADE' and cost_type='REVENUE_EXISTING';")
[ "$ALOC" = "1" ] && [ "$REV" = "1" ] && ok "TESTE1b classificacao correta: 1 ALLOCATED_COST (postes), 1 REVENUE_EXISTING (Prefeitura)" || bad "TESTE1b" "aloc=$ALOC rev=$REV"
POSTES=$($PSQL -t -A -c "select quantidade, custo_mensal from infra_postes;")
echo "$POSTES" | grep -q "165" && echo "$POSTES" | grep -q "1108.80" && ok "TESTE1c 165 postes / R\$1.108,80 preservados (dado real, nao alterado)" || bad "TESTE1c" "$POSTES"

echo ""; echo "--- TESTE 2: 1 Porta PON ---"
CAPMAX=$(val_of "select capacidade_max_assinantes from infra_portas_pon where id='$PORTA_PON006';")
[ "$CAPMAX" = "128" ] && ok "TESTE2 Porta PON PON-JUS-006 criada com capacidade 128" || bad "TESTE2" "capacidade=$CAPMAX"

echo ""; echo "--- TESTE 3: 128 clientes (100% ocupacao) ---"
run_admin "
do \$\$
declare i int;
begin
  for i in 1..128 loop
    insert into cliente_porta_pon (cliente_identificador, contrato_id, porta_pon_id, pop_id, fibra_id, status)
    values ('CLI-F2-'||i, '$CONTRATO_PON', '$PORTA_PON006', '$POP1', '$FIBRA_PON006', 'ATIVO');
  end loop;
end \$\$;" >/tmp/t3.log 2>&1
TAXA3=$(val_of "select taxa_ocupacao from infra_portas_pon where id='$PORTA_PON006';")
[ "$TAXA3" = "1.0000" ] && ok "TESTE3 128 clientes = 100% ocupacao ($TAXA3)" || bad "TESTE3" "$(tail -3 /tmp/t3.log); taxa=$TAXA3"

echo ""; echo "--- TESTE 4: 129 clientes exige segunda porta (get_portas_necessarias) ---"
PN4=$(val_of "select app.get_portas_necessarias(129,128);")
[ "$PN4" = "2" ] && ok "TESTE4 get_portas_necessarias(129,128) = $PN4" || bad "TESTE4" "portas=$PN4"

echo ""; echo "--- TESTE 5: SOMA (minimo 1000 + 12% de 10000 = 2200) ---"
C5=$(val_of "select app.calcular_cobranca_hibrida('$CONTRATO_PON', 10000);")
[ "$C5" = "2200.00000" ] && ok "TESTE5 SOMA: $C5" || bad "TESTE5" "esperado 2200, obtido $C5"

echo ""; echo "--- TESTE 6: MAX (MAX(1000,1200) = 1200) ---"
PARC_T6=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste MAX Fase2 LTDA','33344455000111') returning id;")
CONTR_T6=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-f2-max','$PARC_T6','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
run_admin "insert into contrato_pricing_config (contrato_id, modelo_cobranca, modelo_minimo, mensalidade_minima_porta, percentual_revenue_share) values ('$CONTR_T6','MAX','GLOBAL',1000,0.12);" >/dev/null
C6=$(val_of "select app.calcular_cobranca_hibrida('$CONTR_T6', 10000);")
[ "$C6" = "1200.00000" ] && ok "TESTE6 MAX: $C6" || bad "TESTE6" "esperado 1200, obtido $C6"

echo ""; echo "--- TESTE 7: Break-even (1000/12% = 8333.33) ---"
BE7=$(val_of "select app.calcular_breakeven_faturamento('$CONTRATO_PON');")
[ "$BE7" = "8333.33" ] && ok "TESTE7 break-even faturamento: $BE7" || bad "TESTE7" "esperado 8333.33, obtido $BE7"

echo ""; echo "--- TESTE 8: ARPU R\$100 -> ~84 clientes para superar o minimo ---"
BE8=$(val_of "select app.calcular_breakeven_clientes('$CONTRATO_PON', 100);")
[ "$BE8" = "84" ] && ok "TESTE8 break-even clientes (ARPU 100): $BE8" || bad "TESTE8" "esperado 84, obtido $BE8"

echo ""; echo "--- TESTE 9: Rampa (mes1=50%, mes4=75%, mes7=100%) ---"
R9A=$(val_of "select app.get_fator_rampa(null::uuid, 1, 'FIXO_MINIMO');")
R9B=$(val_of "select app.get_fator_rampa(null::uuid, 4, 'FIXO_MINIMO');")
R9C=$(val_of "select app.get_fator_rampa(null::uuid, 7, 'FIXO_MINIMO');")
[ "$R9A" = "0.50000" ] && [ "$R9B" = "0.75000" ] && [ "$R9C" = "1.00000" ] && \
  ok "TESTE9 rampa: mes1=$R9A mes4=$R9B mes7=$R9C" || bad "TESTE9" "mes1=$R9A mes4=$R9B mes7=$R9C"

echo ""; echo "--- TESTE 10: Reajuste anual (FINANCEIRO aplica 5%, historico preservado) ---"
PARC_T10=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Reajuste LTDA','33344455000202') returning id;")
CONTR_T10=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-f2-reajuste','$PARC_T10','$CIDADE','HIBRIDO_REVENUE_SHARE',48,'ATIVO') returning id;")
run_admin "insert into contrato_pricing_config (contrato_id, mensalidade_minima_porta, percentual_revenue_share) values ('$CONTR_T10',1000,0.12);" >/dev/null
OUT10_COM=$(as_role "$COMERCIAL_ID" "select app.aplicar_reajuste_contrato('$CONTR_T10', 0.05);")
check_blocked "TESTE10a COMERCIAL nao pode aplicar reajuste" "$OUT10_COM"
OUT10_FIN=$(as_role "$FINANCEIRO_ID" "select app.aplicar_reajuste_contrato('$CONTR_T10', 0.05);")
check_ok "TESTE10b FINANCEIRO aplica reajuste de 5%" "$OUT10_FIN"
NOVO_MIN=$(val_of "select mensalidade_minima_porta from contrato_pricing_config where contrato_id='$CONTR_T10';")
[ "$NOVO_MIN" = "1050.00" ] && ok "TESTE10c minimo reajustado: 1000 + 5% = $NOVO_MIN" || bad "TESTE10c" "minimo=$NOVO_MIN"
SNAP_OK=$(val_of "select (parametros->>'mensalidade_minima_porta')::numeric from pricing_versions where contrato_id='$CONTR_T10' order by versao desc limit 1;")
[ "$SNAP_OK" = "1000.00" ] && ok "TESTE10d snapshot em pricing_versions preserva o valor ANTIGO (1000), nunca recalculado" || bad "TESTE10d" "snapshot=$SNAP_OK"

echo ""; echo "--- TESTE 11: 48 meses (horizonte de projecao completo) ---"
N11=$(val_of "select jsonb_array_length(app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":10,\"crescimento_mensal\":2,\"meses_horizonte\":48}'::jsonb)->'meses');")
[ "$N11" = "48" ] && ok "TESTE11 projecao de 48 meses tem $N11 linhas" || bad "TESTE11" "linhas=$N11"

echo ""; echo "--- TESTE 12: 60 meses (horizonte de analise, nao altera prazo minimo do contrato) ---"
N12=$(val_of "select jsonb_array_length(app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":10,\"crescimento_mensal\":2,\"meses_horizonte\":60}'::jsonb)->'meses');")
[ "$N12" = "60" ] && ok "TESTE12 projecao de 60 meses tem $N12 linhas" || bad "TESTE12" "linhas=$N12"

echo ""; echo "--- TESTE 13: ROI (12000 CAPEX; N/A quando CAPEX=0) ---"
ROI13_NA=$(val_of "select (app.calcular_roi(app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":50,\"crescimento_mensal\":5,\"meses_horizonte\":24}'::jsonb),0,12)->>'roi');")
[ "$ROI13_NA" = "" ] && ok "TESTE13a ROI com CAPEX=0 -> null (N/A, sem divisao por zero)" || bad "TESTE13a" "roi=$ROI13_NA"
ROI13=$(val_of "select (app.calcular_roi(app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":50,\"crescimento_mensal\":5,\"meses_horizonte\":24,\"capex_incremental\":12000}'::jsonb),12000,24)->>'roi');")
[ -n "$ROI13" ] && ok "TESTE13b ROI@24m com CAPEX=12000: $ROI13" || bad "TESTE13b" "roi vazio"

echo ""; echo "--- TESTE 14: Payback (mes em que fluxo_caixa_acumulado >= investimento) ---"
PB14=$(val_of "select (app.calcular_payback(app.simular_projecao('{\"minimo_mensal\":1000,\"revenue_share_percent\":0.12,\"arpu_inicial\":100,\"clientes_iniciais\":50,\"crescimento_mensal\":5,\"meses_horizonte\":36,\"capex_incremental\":12000}'::jsonb),12000)->>'mes');")
[ -n "$PB14" ] && [ "$PB14" != "null" ] && ok "TESTE14a payback encontrado: mes $PB14" || bad "TESTE14a" "mes=$PB14"
PB14B=$(text_of "select (app.calcular_payback(app.simular_projecao('{\"minimo_mensal\":100,\"revenue_share_percent\":0.01,\"arpu_inicial\":10,\"clientes_iniciais\":1,\"crescimento_mensal\":0,\"meses_horizonte\":12,\"capex_incremental\":999999}'::jsonb),999999)->>'texto');")
echo "$PB14B" | grep -qi "Não recuperado\|nao recuperado" && ok "TESTE14b payback fora do horizonte: \"$PB14B\"" || bad "TESTE14b" "$PB14B"

echo ""; echo "--- TESTE 15: Margem do parceiro ---"
ME15=$(val_of "select (app.calcular_economia_parceiro(10000,2200,3000)->>'margem_estimada_parceiro')::numeric;")
[ "$ME15" = "4800" ] && ok "TESTE15a margem estimada do parceiro: 10000-2200-3000=$ME15" || bad "TESTE15a" "margem=$ME15"
V15=$(val_of "select app.avaliar_viabilidade_parceiro('$CONTRATO_PON', 0.10);")
echo "$V15" | grep -qi "ALERTA" && ok "TESTE15b margem 10% < minimo configurado (20%) -> alerta (nao bloqueia)" || bad "TESTE15b" "$V15"

echo ""; echo "--- TESTE 16: Preco abaixo do minimo -> BLOCK ---"
G16=$(val_of "select app.check_pricing_governance(900,1000,1500);")
[ "$G16" = "BLOCK" ] && ok "TESTE16 900 < 1000 -> $G16" || bad "TESTE16" "governanca=$G16"

echo ""; echo "--- TESTE 17: Preco entre minimo e recomendado -> REQUIRES_APPROVAL ---"
G17=$(val_of "select app.check_pricing_governance(1200,1000,1500);")
[ "$G17" = "REQUIRES_APPROVAL" ] && ok "TESTE17 1000<=1200<1500 -> $G17" || bad "TESTE17" "governanca=$G17"

echo ""; echo "--- TESTE 18: Preco acima do recomendado -> ALLOW ---"
G18=$(val_of "select app.check_pricing_governance(1600,1000,1500);")
[ "$G18" = "ALLOW" ] && ok "TESTE18 1600>=1500 -> $G18" || bad "TESTE18" "governanca=$G18"

echo ""; echo "--- TESTE 19: Override comercial gera auditoria ---"
AUD19_ANTES=$(val_of "select count(*) from auditoria where entidade='pricing_override_requests';")
OV19=$(as_role "$COMERCIAL_ID" "select public.pricing_override_create('$CONTRATO_PON', null, 1500, 1200, 'Cliente pediu desconto para fechar hoje.');" )
# tail -n1, nao head -n1: as_role() roda "set role; select set_config(...); <query>" numa unica
# chamada psql, e set_config() tambem devolve o valor que recebeu (o proprio uid do usuario) —
# esse uuid aparece ANTES do resultado real da query, entao head -n1 pegava o uid do COMERCIAL
# em vez do id da solicitacao de override (mascarando TESTE19c/19d: um UPDATE com id errado
# casa 0 linhas, o que check_blocked/check_ok liam como "bloqueado"/"ok" por acidente).
OV19_ID=$(echo "$OV19" | grep -Eo "$UUID_RE" | tail -n1)
[ -n "$OV19_ID" ] && ok "TESTE19a COMERCIAL cria solicitacao de override (id=$OV19_ID)" || bad "TESTE19a" "$OV19"
STATUS19=$(val_of "select status from pricing_override_requests where id='$OV19_ID';")
[ "$STATUS19" = "PENDENTE" ] && ok "TESTE19b nasce PENDENTE" || bad "TESTE19b" "status=$STATUS19"
OUT19_COM=$(as_role "$COMERCIAL_ID" "update pricing_override_requests set status='APROVADA' where id='$OV19_ID';")
check_blocked "TESTE19c COMERCIAL nao pode se autoaprovar" "$OUT19_COM"
OUT19_DIR=$(as_role "$DIRETOR_ID" "update pricing_override_requests set status='APROVADA' where id='$OV19_ID';")
check_ok "TESTE19d DIRETOR aprova o override" "$OUT19_DIR"
AUD19_DEPOIS=$(val_of "select count(*) from auditoria where entidade='pricing_override_requests';")
[ "$AUD19_DEPOIS" -gt "$AUD19_ANTES" ] && ok "TESTE19e override auditado ($AUD19_ANTES -> $AUD19_DEPOIS)" || bad "TESTE19e" "antes=$AUD19_ANTES depois=$AUD19_DEPOIS"

echo ""; echo "--- TESTE 20: Multiplos POPs (consolidacao de capacidade) ---"
PARC_T20=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste MultiPOP Fase2 LTDA','33344455000303') returning id;")
CONTR_T20=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-f2-multipop','$PARC_T20','$CIDADE','HIBRIDO_REVENUE_SHARE',48,'ATIVO') returning id;")
for i in 1 2; do
  POOL_N=$((POOL_N+1)); FID=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL' and numero_fibra=$POOL_N;")
  run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID','$POP1','PON-F2-T20-P1-$i');" >/dev/null
  PID=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-F2-T20-P1-$i';")
  run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTR_T20','$FID','$PID');" >/dev/null
done
POOL2_N=$((POOL2_N+1)); FID2=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL2' and numero_fibra=$POOL2_N;")
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID2','$POP2','PON-F2-T20-P2');" >/dev/null
PID2=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-F2-T20-P2';")
run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTR_T20','$FID2','$PID2');" >/dev/null
CAP20=$(val_of "select app.get_contract_capacity('$CONTR_T20');")
POPS20=$(val_of "select pops_utilizados from vw_capacidade_contrato where contrato_id='$CONTR_T20';")
[ "$CAP20" = "384" ] && [ "$POPS20" = "2" ] && ok "TESTE20 3 portas (2 POP-01 + 1 POP-02) = capacidade $CAP20 em $POPS20 POPs" || bad "TESTE20" "capacidade=$CAP20 pops=$POPS20"

echo ""; echo "--- TESTE 21: Multiplas Portas PON (200 clientes exige 2 portas de 128) ---"
PN21=$(val_of "select app.get_portas_necessarias(200,128);")
[ "$PN21" = "2" ] && ok "TESTE21 get_portas_necessarias(200,128) = $PN21" || bad "TESTE21" "portas=$PN21"

echo ""; echo "--- TESTE 22: Portas reservadas (3 portas x R\$1000 = R\$3000, so 1 ativa) ---"
PARC_T22=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste Reservadas Fase2 LTDA','33344455000404') returning id;")
CONTR_T22=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-f2-reservadas','$PARC_T22','$CIDADE','HIBRIDO_REVENUE_SHARE',48,'ATIVO') returning id;")
run_admin "insert into contrato_pricing_config (contrato_id, modelo_minimo, mensalidade_minima_porta) values ('$CONTR_T22','POR_PORTA',1000);" >/dev/null
declare -a PORTAS_T22=()
for i in 1 2 3; do
  POOL_N=$((POOL_N+1)); FID=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL' and numero_fibra=$POOL_N;")
  run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FID','$POP1','PON-F2-T22-$i');" >/dev/null
  PID=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-F2-T22-$i';")
  run_admin "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTR_T22','$FID','$PID');" >/dev/null
  PORTAS_T22+=("$PID")
done
PID_ATIVA="${PORTAS_T22[0]}"
POP_ATIVA=$(val_of "select pop_id from infra_portas_pon where id='$PID_ATIVA';")
FIB_ATIVA=$(val_of "select fibra_id from infra_portas_pon where id='$PID_ATIVA';")
run_admin "insert into cliente_porta_pon (cliente_identificador, contrato_id, porta_pon_id, pop_id, fibra_id, status) values ('CLI-T22','$CONTR_T22','$PID_ATIVA','$POP_ATIVA','$FIB_ATIVA','ATIVO');" >/dev/null
MIN22=$(val_of "select app.calcular_minimo_contratual('$CONTR_T22');")
[ "$MIN22" = "3000.00" ] && ok "TESTE22 minimo cobrado sobre 3 portas contratadas (so 1 ativa): $MIN22" || bad "TESTE22" "minimo=$MIN22"

echo ""; echo "--- TESTE 23: Capacidade (contratada/ativa/disponivel/ocupada) ---"
CONTRATADA23=$(val_of "select app.get_contract_capacity('$CONTRATO_PON');")
OCUPADA23=$(val_of "select app.get_occupied_capacity('$CONTRATO_PON');")
DISP23=$(val_of "select app.get_available_capacity('$CONTRATO_PON');")
[ "$CONTRATADA23" = "128" ] && [ "$OCUPADA23" = "128" ] && [ "$DISP23" = "0" ] && \
  ok "TESTE23 capacidade contrato_pon: contratada=$CONTRATADA23 ocupada=$OCUPADA23 disponivel=$DISP23" || \
  bad "TESTE23" "contratada=$CONTRATADA23 ocupada=$OCUPADA23 disponivel=$DISP23"

########################################
echo ""; echo "=== TESTE 24 — REGRESSAO COMPLETA DA FASE 1 ==="
POSTES24=$($PSQL -t -A -c "select quantidade, custo_mensal from infra_postes where identificacao like 'Lote%';")
echo "$POSTES24" | grep -q "165" && echo "$POSTES24" | grep -q "1108.80" && ok "F1-R1 165 postes / R\$1.108,80 preservados" || bad "F1-R1" "$POSTES24"
for meses in 24 36 47; do
  PARC_L=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Regressao F1 $meses LTDA','444${meses}5000${meses}') returning id;")
  OUT=$(run_admin "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses) values ('teste-f2-reg-$meses','$PARC_L','$CIDADE','DARK_FIBER',$meses);")
  check_blocked "F1-R2 $meses meses sem excecao -> rejeitado" "$OUT"
done
MED_ID=$(uid_of "insert into medicoes_mensais (contrato_id, competencia, status) values ('$CONTRATO_A','2026-10-01','APROVADA') returning id;")
IMUT=$(val_of "select imutavel from medicoes_mensais where id='$MED_ID';")
[ "$IMUT" = "t" ] && ok "F1-R3 medicao aprovada vira imutavel" || bad "F1-R3" "imutavel=$IMUT"
OUT=$(run_admin "update medicoes_mensais set valor_final=999 where id='$MED_ID';")
check_blocked "F1-R4 update em medicao imutavel bloqueado" "$OUT"
OUT=$(run_admin "delete from auditoria;")
check_blocked "F1-R5 DELETE em auditoria bloqueado (imutavel)" "$OUT"
OUT=$(as_role "$AUDITOR_ID" "insert into parceiros (razao_social, cnpj) values ('Nao deveria existir F1','00000000000201');")
check_blocked "F1-R6 AUDITOR nao escreve em nada" "$OUT"

echo ""; echo "=== TESTE 25 — REGRESSAO COMPLETA DA FASE 1.1 ==="
VERSAO_A=$(val_of "select versao_atual from contratos where numero='0002';")
[ "$VERSAO_A" = "2" ] && ok "F11-R1 aditivo do seed Fase1.1 gerou versao_atual=2 automaticamente" || bad "F11-R1" "versao=$VERSAO_A"
POPS_A=$(val_of "select pops_utilizados from vw_capacidade_contrato where contrato_numero='0002';")
[ "$POPS_A" = "2" ] && ok "F11-R2 contrato 0002 usa portas em 2 POPs (aditivo Fase1.1)" || bad "F11-R2" "pops=$POPS_A"
R1=$(val_of "select app.check_contract_conflict('$CIDADE','00000000-0000-0000-0000-000000000000'::uuid,'$POP2'::uuid);")
[ "$R1" = "ALLOW" ] && ok "F11-R3 exclusividade so no POP-01 -> POP-02 = ALLOW" || bad "F11-R3" "resultado=$R1"
R2=$(val_of "select app.check_contract_conflict('$CIDADE','00000000-0000-0000-0000-000000000000'::uuid,'$POP1'::uuid);")
[ "$R2" = "REQUIRES_APPROVAL" ] && ok "F11-R4 mesmo POP com permite_outros_parceiros=true -> REQUIRES_APPROVAL" || bad "F11-R4" "resultado=$R2"
OUT=$(as_role "$COMERCIAL_ID" "insert into contrato_regras_solicitacoes (contrato_id, tipo, descricao, solicitado_por) values ('$CONTRATO_A','FIBRA_TERCEIROS','teste f2','$COMERCIAL_ID');")
check_ok "F11-R5 COMERCIAL solicita fibra de terceiros (nasce PENDENTE)" "$OUT"
SOLIC_ID=$(uid_of "select id from contrato_regras_solicitacoes where contrato_id='$CONTRATO_A' and tipo='FIBRA_TERCEIROS' order by criado_em desc limit 1;")
OUT=$(as_role "$COMERCIAL_ID" "update contrato_regras_solicitacoes set status='APROVADA', decidido_por='$COMERCIAL_ID' where id='$SOLIC_ID';")
check_blocked "F11-R6 COMERCIAL nao pode se autoaprovar" "$OUT"
OUT=$(as_role "$DIRETOR_ID" "update contrato_regras_solicitacoes set status='APROVADA', decidido_por='$DIRETOR_ID', decidido_em=now() where id='$SOLIC_ID';")
check_ok "F11-R7 DIRETOR aprova" "$OUT"
HC=$(val_of "select count(*) from pricing_parametros where chave='PORTA_PON_CAPACIDADE_MAX_PADRAO' and valor=128;")
[ "$HC" = "1" ] && ok "F11-R8 capacidade padrao 128 continua parametrizavel (nao hard-coded)" || bad "F11-R8" "count=$HC"

echo ""; echo "=== TESTE 26 — REGRESSAO COMPLETA DA FASE 1.2 ==="
MODELO_B=$(val_of "select modelo_cobranca from contrato_pricing_config where contrato_id=(select id from contratos where numero='0003');")
[ "$MODELO_B" = "SOMA" ] && ok "F12-R1 contrato 0003 preserva SOMA (nao alterado retroativamente pelo default)" || bad "F12-R1" "modelo=$MODELO_B"
PORTA_JUS003=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-JUS-003';")
FIBRA_JUS003=$(uid_of "select fibra_id from infra_portas_pon where codigo_porta='PON-JUS-003';")
PARC_T26=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Regressao F12 LTDA','33344455000505') returning id;")
CONTR_T26=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-f2-reg-compart','$PARC_T26','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
OUT26=$(as_role "$DIRETOR_ID" "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id) values ('$CONTR_T26','$FIBRA_JUS003','$PORTA_JUS003');")
check_blocked "F12-R2 PON-JUS-003 ja exclusiva de outro contrato -> BLOCK (compartilhamento x exclusividade)" "$OUT26"
POOL_N=$((POOL_N+1)); FIBRA_T26B=$(uid_of "select id from infra_fibras where cabo_id='$CABO_POOL' and numero_fibra=$POOL_N;")
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FIBRA_T26B','$POP1','PON-F2-T26B');" >/dev/null
PORTA_T26B=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-F2-T26B';")
OUT26B=$(as_role "$ENGENHARIA_ID" "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id, compartilhamento_autorizado) values ('$CONTR_T26','$FIBRA_T26B','$PORTA_T26B', true);")
check_blocked "F12-R3 ENGENHARIA nao pode autorizar compartilhamento (exige DIRETOR/ADMINISTRADOR)" "$OUT26B"
OUT26C=$(as_role "$DIRETOR_ID" "insert into contrato_fibras (contrato_id, fibra_id, porta_pon_id, compartilhamento_autorizado) values ('$CONTR_T26','$FIBRA_T26B','$PORTA_T26B', true);")
check_ok "F12-R4 DIRETOR autoriza compartilhamento" "$OUT26C"
CLI26=$(uid_of "insert into cliente_porta_pon (cliente_identificador, contrato_id, porta_pon_id, pop_id, fibra_id, status) values ('CLI-F2-R26','$CONTR_T26','$PORTA_T26B','$POP1','$FIBRA_T26B','ATIVO') returning id;")
UTIL26=$(val_of "select capacidade_utilizada_assinantes from infra_portas_pon where id='$PORTA_T26B';")
[ "$UTIL26" = "1" ] && ok "F12-R5 cliente_porta_pon ativado -> capacidade utilizada=$UTIL26" || bad "F12-R5" "utilizada=$UTIL26"
run_admin "update cliente_porta_pon set status='CANCELADO' where id='$CLI26';" >/dev/null
UTIL26B=$(val_of "select capacidade_utilizada_assinantes from infra_portas_pon where id='$PORTA_T26B';")
[ "$UTIL26B" = "0" ] && ok "F12-R6 cliente cancelado -> capacidade volta a $UTIL26B" || bad "F12-R6" "utilizada=$UTIL26B"
OUT26D=$(as_role "$COMERCIAL_ID" "insert into contrato_regras_solicitacoes (contrato_id, tipo, descricao, status) values ('$CONTR_T26','REDE_PROPRIA','teste','APROVADA');")
check_blocked "F12-R7 solicitacao so pode nascer PENDENTE (COMERCIAL nao insere ja aprovada)" "$OUT26D"
OUT26E=$(as_role "$COMERCIAL_ID" "insert into contrato_pricing_config (contrato_id, mensalidade_minima_porta) values ('$CONTR_T26', 1);")
check_blocked "F12-R8 COMERCIAL nao altera pricing (RBAC)" "$OUT26E"
for ent in cliente_porta_pon pricing_override_requests custos_infraestrutura; do
  C=$(val_of "select count(*) from auditoria where entidade='$ent';")
  [ "$C" -ge "1" ] && ok "F12-R9 auditoria cobre $ent ($C linhas)" || bad "F12-R9 $ent" "0 linhas"
done

########################################
echo ""
echo "=============================================="
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
echo "=============================================="
for r in "${RESULTS[@]}"; do echo "$r"; done
echo "=============================================="
echo "$PASS PASS / $FAIL FAIL"
