#!/bin/bash
set -uo pipefail
export PGPASSWORD=optimon_dev
PSQL="psql -h localhost -U optimon_admin -d optimon"
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

uid_of() { $PSQL -t -A -c "$1" 2>&1 | grep -Eo "$UUID_RE" | head -n1; }
run_admin() { $PSQL -c "$1" 2>&1; }
as_role() {
  local uid="$1"; shift
  $PSQL -c "set role authenticated; select set_config('app.current_user_id', '$uid', false); $1" 2>&1
}

PASS=0; FAIL=0; RESULTS=()
ok() { RESULTS+=("OK   | $1"); PASS=$((PASS+1)); }
bad() { RESULTS+=("FAIL | $1"); FAIL=$((FAIL+1)); echo "----- DETALHE DA FALHA: $1 -----"; echo "$2" | tail -6; }
check_ok() { # desc, out
  if echo "$2" | grep -qiE "ERROR|exception"; then bad "$1" "$2"; else ok "$1"; fi
}
check_blocked() { # desc, out
  if echo "$2" | grep -qiE "ERROR|exception"; then ok "$1"; else bad "$1" "$2"; fi
}

########################################
echo "### REBUILD DO ZERO ###"
sudo -u postgres psql -c "DROP DATABASE IF EXISTS optimon;" >/dev/null
sudo -u postgres psql -c "CREATE DATABASE optimon OWNER optimon_admin;" >/dev/null
cd /home/claude/optimon
$PSQL -v ON_ERROR_STOP=1 -f supabase/dev-local-only/shim_supabase_auth.sql >/dev/null || { echo "shim falhou"; exit 1; }
for f in $(ls supabase/migrations/20260824*.sql | sort); do
  $PSQL -v ON_ERROR_STOP=1 -f "$f" >/tmp/m.log 2>&1 || { echo "FALHOU migration Fase1: $f"; cat /tmp/m.log; exit 1; }
done
$PSQL -v ON_ERROR_STOP=1 -f supabase/seed.sql >/tmp/s1.log 2>&1 || { echo "FALHOU seed Fase1"; cat /tmp/s1.log; exit 1; }

echo "### checkpoint Fase 1 (antes da 1.1) ###"
CHECK_FIBRAS=$($PSQL -t -A -c "select count(*) from infra_fibras;")
CHECK_LIVRES=$($PSQL -t -A -c "select count(*) from infra_fibras where status='LIVRE';")
CHECK_BLOQ=$($PSQL -t -A -c "select count(*) from infra_fibras where status='BLOQUEADA';")
echo "fibras=$CHECK_FIBRAS livres=$CHECK_LIVRES bloqueadas=$CHECK_BLOQ"
[ "$CHECK_FIBRAS" = "12" ] && ok "Checkpoint regressão: 12 FO cadastradas" || bad "Checkpoint 12 FO" "encontrado=$CHECK_FIBRAS"
[ "$CHECK_BLOQ" = "2" ] && ok "Checkpoint regressão: 2 FO bloqueadas (Prefeitura)" || bad "Checkpoint 2 FO bloqueadas" "encontrado=$CHECK_BLOQ"
[ "$CHECK_LIVRES" = "10" ] && ok "Checkpoint regressão: 10 FO livres logo após seed Fase 1" || bad "Checkpoint 10 FO livres" "encontrado=$CHECK_LIVRES"

for f in $(ls supabase/migrations/20260825*.sql | sort); do
  $PSQL -v ON_ERROR_STOP=1 -f "$f" >/tmp/m2.log 2>&1 || { echo "FALHOU migration Fase1.1: $f"; cat /tmp/m2.log; exit 1; }
done
ok "Todas as 14 migrations da Fase 1.1 aplicaram sem erro sobre banco com dados reais"

$PSQL -v ON_ERROR_STOP=1 -f supabase/seed_fase11.sql >/tmp/s2.log 2>&1 || { echo "FALHOU seed Fase1.1"; cat /tmp/s2.log; exit 1; }
ok "Seed complementar da Fase 1.1 aplicado sem erro"

########################################
echo "### criando usuários de teste (um por perfil) ###"
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
CABO2=$(uid_of "select id from infra_cabos where identificacao='CABO-JUSSARA-02';")
CONTRATO_A=$(uid_of "select id from contratos where numero='0002';")
PARCEIRO_A=$(uid_of "select parceiro_id from contratos where numero='0002';")

echo "IDs: cidade=$CIDADE pop1=$POP1 pop2=$POP2"

########################################
echo ""; echo "### TESTE A: FIBRA INDIVIDUAL ###"
FIBRA_A=$(uid_of "select id from infra_fibras where cabo_id='$CABO2' and numero_fibra=3;")
run_admin "update infra_fibras set status_comercial='RESERVADA' where id='$FIBRA_A';" >/dev/null
PARCEIRO_C=$(uid_of "insert into parceiros (razao_social, cnpj) values ('Parceiro Teste A LTDA','99988877000100') returning id;")
CONTRATO_C=$(uid_of "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('9001','$PARCEIRO_C','$CIDADE','DARK_FIBER',48,'ATIVO') returning id;")
OUT=$(as_role "$ENGENHARIA_ID" "insert into contrato_fibras (contrato_id, fibra_id) values ('$CONTRATO_C','$FIBRA_A');")
check_ok "A1 contratar 1 unica fibra sem exigir par" "$OUT"
ST=$($PSQL -t -A -c "select status_contratual from infra_fibras where id='$FIBRA_A';")
[ "$ST" = "VINCULADA" ] && ok "A2 fibra contratada virou VINCULADA" || bad "A2" "status=$ST"
run_admin "update contrato_fibras set desvinculado_em = now() where contrato_id='$CONTRATO_C' and fibra_id='$FIBRA_A';" >/dev/null
ST2=$($PSQL -t -A -c "select status_comercial from infra_fibras where id='$FIBRA_A';")
[ "$ST2" = "RESERVADA" ] && ok "A3 desvincular NAO reverte status_comercial para LIVRE (bug Fase1 corrigido)" || bad "A3" "status_comercial=$ST2"

echo ""; echo "### TESTE B/K: CAPACIDADE DA PORTA PON (max 128) ###"
OUT=$(run_admin "update infra_portas_pon set capacidade_utilizada_assinantes = 128 where codigo_porta='PON-JUS-001';")
check_ok "B1 inserir exatamente 128 clientes (limite) permitido" "$OUT"
OUT=$(run_admin "update infra_portas_pon set capacidade_utilizada_assinantes = 129 where codigo_porta='PON-JUS-001';")
check_blocked "B2/K clientes > capacidade maxima (129) bloqueado pela constraint" "$OUT"
run_admin "update infra_portas_pon set capacidade_utilizada_assinantes = 10 where codigo_porta='PON-JUS-001';" >/dev/null

echo ""; echo "### TESTE C: MULTIPLAS PORTAS NO MESMO POP ###"
FIBRA_C1=$(uid_of "select id from infra_fibras where cabo_id='$CABO2' and numero_fibra=4;")
FIBRA_C2=$(uid_of "select id from infra_fibras where cabo_id='$CABO2' and numero_fibra=5;")
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FIBRA_C1','$POP2','PON-JUS-004');" >/dev/null
run_admin "insert into infra_portas_pon (fibra_id, pop_id, codigo_porta) values ('$FIBRA_C2','$POP2','PON-JUS-005');" >/dev/null
TOTAL_POP2=$($PSQL -t -A -c "select portas_pon_totais from vw_capacidade_pop where pop_codigo='POP-02';")
DISP_POP2=$($PSQL -t -A -c "select portas_disponiveis from vw_capacidade_pop where pop_codigo='POP-02';")
[ "$TOTAL_POP2" = "3" ] && ok "C1 POP-02 agora tem 3 portas PON (1 contratada + 2 novas livres)" || bad "C1" "total=$TOTAL_POP2"
[ "$DISP_POP2" = "2" ] && ok "C2 as 2 portas novas continuam disponiveis (nao contratadas)" || bad "C2" "disponiveis=$DISP_POP2"
VERSAO_ANTES=$($PSQL -t -A -c "select versao_atual from contratos where numero='0002';")
[ "$VERSAO_ANTES" = "2" ] && ok "C3 aditivo aprovado no seed ja gerou versao_atual=2 automaticamente" || bad "C3" "versao_atual=$VERSAO_ANTES"
QTD_VERSIONS=$($PSQL -t -A -c "select count(*) from contrato_versions where contrato_id='$CONTRATO_A';")
[ "$QTD_VERSIONS" = "1" ] && ok "C4 contrato_versions tem o snapshot do aditivo (historico preservado)" || bad "C4" "qtd=$QTD_VERSIONS"

echo ""; echo "### TESTE D: MULTIPLOS POPs / CAPACIDADE CONSOLIDADA ###"
POPS_USADOS=$($PSQL -t -A -c "select pops_utilizados from vw_capacidade_contrato where contrato_numero='0002';")
[ "$POPS_USADOS" = "2" ] && ok "D1 contrato 0002 usa portas em 2 POPs diferentes (via aditivo)" || bad "D1" "pops=$POPS_USADOS"
NPOPS=$($PSQL -t -A -c "select count(*) from infra_pops where cidade_id='$CIDADE';")
[ "$NPOPS" -ge "2" ] && ok "D2 cidade Jussara tem multiplos POPs ($NPOPS)" || bad "D2" "npops=$NPOPS"

echo ""; echo "### TESTE E/F: PRICING PARAMETRIZAVEL (sem Pricing Engine ainda) ###"
MODELO_A=$($PSQL -t -A -c "select modelo_cobranca from contrato_pricing_config where contrato_id='$CONTRATO_A';")
MODELO_B=$($PSQL -t -A -c "select modelo_cobranca from contrato_pricing_config c join contratos ct on ct.id=c.contrato_id where ct.numero='0003';")
[ "$MODELO_A" = "MAX" ] && [ "$MODELO_B" = "SOMA" ] && ok "E1 dois contratos, dois modelos de cobranca distintos (A=MAX, B=SOMA) - nao ha formula global fixa" || bad "E1" "A=$MODELO_A B=$MODELO_B"
HC=$($PSQL -t -A -c "select count(*) from pricing_parametros where chave='PORTA_PON_CAPACIDADE_MAX_PADRAO' and valor=128;")
[ "$HC" = "1" ] && ok "E2 capacidade padrao 128 vive em pricing_parametros (nao hard-coded)" || bad "E2" "count=$HC"

echo ""; echo "### TESTE G: EXCLUSIVIDADE ESCOPADA / checkContractConflict ###"
R1=$($PSQL -t -A -c "select app.check_contract_conflict('$CIDADE','00000000-0000-0000-0000-000000000000'::uuid,'$POP2'::uuid);")
[ "$R1" = "ALLOW" ] && ok "G1 exclusividade so no POP-01 -> nova contratacao no POP-02 = ALLOW" || bad "G1" "resultado=$R1"
R2=$($PSQL -t -A -c "select app.check_contract_conflict('$CIDADE','00000000-0000-0000-0000-000000000000'::uuid,'$POP1'::uuid);")
[ "$R2" = "REQUIRES_APPROVAL" ] && ok "G2 mesmo POP com permite_outros_parceiros=true -> REQUIRES_APPROVAL" || bad "G2" "resultado=$R2"
run_admin "update contrato_regras set exclusividade_pop_id=null, exclusividade_cidade_id='$CIDADE', permite_outros_parceiros=false where contrato_id='$CONTRATO_A';" >/dev/null
R3=$($PSQL -t -A -c "select app.check_contract_conflict('$CIDADE','00000000-0000-0000-0000-000000000000'::uuid,'$POP2'::uuid);")
[ "$R3" = "BLOCK" ] && ok "G3 exclusividade na cidade toda + permite_outros_parceiros=false -> BLOCK mesmo em POP diferente" || bad "G3" "resultado=$R3"
run_admin "update contrato_regras set exclusividade_pop_id='$POP1', exclusividade_cidade_id='$CIDADE', permite_outros_parceiros=true where contrato_id='$CONTRATO_A';" >/dev/null

echo ""; echo "### TESTE H: FIBRA DE TERCEIROS (workflow) ###"
OUT=$(as_role "$COMERCIAL_ID" "insert into contrato_regras_solicitacoes (contrato_id, tipo, descricao, solicitado_por) values ('$CONTRATO_A','FIBRA_TERCEIROS','teste','$COMERCIAL_ID');")
check_ok "H1 COMERCIAL pode solicitar (nasce PENDENTE)" "$OUT"
SOLIC_ID=$(uid_of "select id from contrato_regras_solicitacoes where contrato_id='$CONTRATO_A' and tipo='FIBRA_TERCEIROS' order by criado_em desc limit 1;")
ST3=$($PSQL -t -A -c "select status from contrato_regras_solicitacoes where id='$SOLIC_ID';")
[ "$ST3" = "PENDENTE" ] && ok "H2 solicitacao nasce PENDENTE" || bad "H2" "status=$ST3"
OUT=$(as_role "$COMERCIAL_ID" "update contrato_regras_solicitacoes set status='APROVADA', decidido_por='$COMERCIAL_ID' where id='$SOLIC_ID';")
check_blocked "H3 COMERCIAL NAO pode aprovar a propria solicitacao" "$OUT"
OUT=$(as_role "$DIRETOR_ID" "update contrato_regras_solicitacoes set status='APROVADA', decidido_por='$DIRETOR_ID', decidido_em=now() where id='$SOLIC_ID';")
check_ok "H4 DIRETOR pode aprovar" "$OUT"
AUD_H=$($PSQL -t -A -c "select count(*) from auditoria where entidade='contrato_regras_solicitacoes' and entidade_id='$SOLIC_ID';")
[ "$AUD_H" -ge "2" ] && ok "H5 solicitacao e aprovacao ficaram auditadas (lacuna da Fase 1 corrigida)" || bad "H5" "linhas_auditoria=$AUD_H"

echo ""; echo "### TESTE I: REDE PROPRIA (mesmo workflow) ###"
OUT=$(as_role "$COMERCIAL_ID" "insert into contrato_regras_solicitacoes (contrato_id, tipo, descricao, solicitado_por) values ('$CONTRATO_A','REDE_PROPRIA','teste rede propria','$COMERCIAL_ID');")
check_ok "I1 COMERCIAL solicita excecao de rede propria" "$OUT"
SOLIC2_ID=$(uid_of "select id from contrato_regras_solicitacoes where contrato_id='$CONTRATO_A' and tipo='REDE_PROPRIA' order by criado_em desc limit 1;")
OUT=$(as_role "$DIRETOR_ID" "update contrato_regras_solicitacoes set status='REJEITADA', decidido_por='$DIRETOR_ID', decidido_em=now() where id='$SOLIC2_ID';")
check_ok "I2 DIRETOR pode rejeitar" "$OUT"

echo ""; echo "### TESTE J: PREFEITURA / CLIENTE RESERVADO ###"
OUT=$(as_role "$COMERCIAL_ID" "insert into contrato_clientes_reservados (contrato_id, cliente_nome) values ('$CONTRATO_A','Prefeitura Municipal de Jussara');")
check_blocked "J1 COMERCIAL nao pode cadastrar cliente reservado" "$OUT"
OUT=$(as_role "$DIRETOR_ID" "insert into contrato_clientes_reservados (contrato_id, cliente_nome, motivo) values ('$CONTRATO_A','Prefeitura Municipal de Jussara','Cliente da operacao atual - nao disponivel a parceiros');")
check_ok "J2 DIRETOR pode cadastrar cliente reservado" "$OUT"
AUD_J=$($PSQL -t -A -c "select count(*) from auditoria where entidade='contrato_clientes_reservados';")
[ "$AUD_J" -ge "1" ] && ok "J3 cadastro de cliente reservado foi auditado" || bad "J3" "linhas=$AUD_J"

echo ""; echo "### TESTE L: CONTRATO MINIMO 48 MESES (regressao) ###"
for meses in 24 36 47; do
  OUT=$(run_admin "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses) values ('teste-$meses','$PARCEIRO_C','$CIDADE','DARK_FIBER',$meses);")
  check_blocked "L-$meses meses sem excecao -> rejeitado" "$OUT"
done
OUT=$(run_admin "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, status) values ('teste-48','$PARCEIRO_C','$CIDADE','DARK_FIBER',48,'ATIVO');")
check_ok "L-48 meses permitido" "$OUT"
OUT=$(run_admin "insert into contratos (numero, parceiro_id, cidade_id, modelo, prazo_meses, prazo_minimo_excecao, aprovado_por) values ('teste-excecao','$PARCEIRO_C','$CIDADE','DARK_FIBER',12,true,'$DIRETOR_ID');")
check_ok "L-excecao aprovada por DIRETOR permite prazo menor" "$OUT"

echo ""; echo "### TESTE M: ADITIVOS (versionamento) ###"
AUD_ADIT=$($PSQL -t -A -c "select count(*) from auditoria where entidade='contrato_aditivos';")
[ "$AUD_ADIT" -ge "1" ] && ok "M1 aditivo do seed foi auditado" || bad "M1" "linhas=$AUD_ADIT"
SNAP=$($PSQL -t -A -c "select motivo from contrato_versions where contrato_id='$CONTRATO_A' order by versao desc limit 1;")
echo "$SNAP" | grep -q "ADITIVO" && ok "M2 contrato_versions registra o motivo do aditivo" || bad "M2" "motivo=$SNAP"

echo ""; echo "### TESTE N: SEGURANCA / RBAC ###"
OUT=$(as_role "$COMERCIAL_ID" "update pricing_parametros set valor=1 where chave='DARK_FIBER_PRECO_MINIMO_PAR_MES';")
$PSQL -c "select 1" >/dev/null
UPD=$(as_role "$COMERCIAL_ID" "update pricing_parametros set valor=1 where chave='DARK_FIBER_PRECO_MINIMO_PAR_MES'; select valor from pricing_parametros where chave='DARK_FIBER_PRECO_MINIMO_PAR_MES';")
echo "$UPD" | grep -q " 1500" && ok "N1 COMERCIAL nao altera pricing (RLS bloqueou, valor continua 1500)" || bad "N1" "$UPD"
OUT=$(as_role "$ENGENHARIA_ID" "update pricing_parametros set valor=1 where chave='DARK_FIBER_PRECO_MINIMO_PAR_MES'; select valor from pricing_parametros where chave='DARK_FIBER_PRECO_MINIMO_PAR_MES';")
echo "$OUT" | grep -q " 1500" && ok "N2 ENGENHARIA nao altera pricing" || bad "N2" "$OUT"
OUT=$(as_role "$FINANCEIRO_ID" "insert into infra_fibras (cabo_id, numero_fibra, par_numero) values ('$CABO2', 99, 50);")
check_blocked "N3 FINANCEIRO nao altera infraestrutura" "$OUT"
OUT=$(as_role "$AUDITOR_ID" "insert into parceiros (razao_social, cnpj) values ('Nao deveria existir','00000000000000');")
check_blocked "N4 AUDITOR nao escreve em nada" "$OUT"
OUT=$(as_role "$COMERCIAL_ID" "select * from integracoes;")
LINHAS=$(as_role "$COMERCIAL_ID" "select count(*) from integracoes;" | grep -Eo '^\s*[0-9]+\s*$' | tr -d ' ')
COLS_SEGURO=$($PSQL -t -A -c "select string_agg(column_name, ',') from information_schema.columns where table_name='vw_integracoes_seguro';")
echo "$COLS_SEGURO" | grep -qv "credenciais" && ok "N5 view segura de integracoes nao tem coluna de credenciais ($COLS_SEGURO)" || bad "N5" "$COLS_SEGURO"

echo ""; echo "### TESTE O: AUDITORIA (regressao + novas tabelas) ###"
for ent in contratos infra_portas_pon contrato_aditivos pricing_parametros usuarios integracoes contrato_regras_solicitacoes contrato_clientes_reservados; do
  C=$($PSQL -t -A -c "select count(*) from auditoria where entidade='$ent';")
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
MED_ID=$(uid_of "insert into medicoes_mensais (contrato_id, competencia, status) values ('$CONTRATO_A','2026-08-01','APROVADA') returning id;")
IMUT=$($PSQL -t -A -c "select imutavel from medicoes_mensais where id='$MED_ID';")
[ "$IMUT" = "t" ] && ok "Regressao: medicao aprovada vira imutavel" || bad "Regressao imutavel" "imutavel=$IMUT"
OUT=$(run_admin "update medicoes_mensais set valor_final=999 where id='$MED_ID';")
check_blocked "Regressao: update em medicao imutavel bloqueado" "$OUT"

########################################
echo ""
echo "=============================================="
echo "RESULTADO FINAL: $PASS OK / $FAIL FALHAS"
echo "=============================================="
for r in "${RESULTS[@]}"; do echo "$r"; done
echo "=============================================="
echo "$PASS OK / $FAIL FALHAS"
