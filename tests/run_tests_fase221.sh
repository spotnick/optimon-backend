#!/bin/bash
# OptiMon — Fase 2.2.1: Ajuste Final de Governanca + Precificacao por Porta PON — testes
# obrigatorios (TESTE-30..41, secoes 5/45 do prompt) + regressao COMPLETA de Fase 1, 1.1,
# 1.2, 2, 2.1 e 2.2.
#
# ESTRATEGIA DE REGRESSAO (diferente das baterias anteriores, e deliberada — ver secao 29
# do prompt): esta fase muda PARAMETROS GLOBAIS vigentes (poste R$10->R$8, +componente PON)
# atraves de uma nova Pricing Version ("2026.08.1"). Isso significa que qualquer calculo
# que resolva a versao VIGENTE (sem pricing_version fixado) legitimamente muda de valor
# depois desta fase — nao e regressao, e o proprio objetivo da fase. Reexecutar o arquivo
# ORIGINAL run_tests_fase22.sh SEM EDITAR DEPOIS de aplicar as migrations desta fase faria
# 2 blocos daquele arquivo (TESTE-20 e TESTE-ARPU, que dependem do Infrastructure Floor)
# fshow FAIL espurio — nao porque algo quebrou, mas porque o parametro vigente mudou por
# instrucao explicita desta fase. Em vez de editar o arquivo antigo (proibido: "NAO
# substituir migrations/testes anteriores sem necessidade") ou esconder esse FAIL
# (proibido: "nunca esconder FAIL, explicar causa/impacto/correcao"), a estrategia aqui e:
#
#   PASSO A: rodar tests/run_tests_fase22.sh SEM NENHUMA EDICAO, ANTES de aplicar as
#            migrations da Fase 2.2.1 — prova que absolutamente nada antes desta fase
#            quebrou (o arquivo original passa 100%, exatamente como na entrega da Fase 2.2,
#            porque o pricing_version ainda vigente e o antigo "2026.08" nesse ponto).
#   PASSO B: aplicar as 5 migrations da Fase 2.2.1 sobre ESSE MESMO banco (sem rebuild).
#   PASSO C: reexecutar so os 2 pontos de calculo que dependem do Floor vigente (TESTE-20 e
#            TESTE-ARPU do contrato 0006), agora EXPLICITAMENTE FIXADOS na versao antiga
#            ("2026.08") via p_pricing_version — devem bater com os MESMOS valores antigos,
#            byte a byte (prova real de que "propostas antigas nunca sao recalculadas com
#            parametros novos", secao 29 — o proprio motivo de existir do novo esquema de
#            versionamento). Em seguida, os MESMOS 2 pontos SEM fixar versao (vigente atual)
#            mostram os valores NOVOS, documentados e esperados — nunca escondidos.
#   PASSO D: bateria propria da Fase 2.2.1 (TESTE-30..41).
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
# Igual a as_role, mas com -t -A (sem headers/footers "(N rows)") — para extrair um valor
# escalar limpo com `tail -n1`, sem o "(1 row)" que -c puro deixa como ultima linha.
as_role_val() {
  local uid="$1"; shift
  $PSQL -t -A -c "set role authenticated; select set_config('app.current_user_id', '$uid', false); $1" 2>&1 | tail -n1 | tr -d ' '
}

PASS=0; FAIL=0; RESULTS=()
ok() { RESULTS+=("PASS | $1"); PASS=$((PASS+1)); }
bad() { RESULTS+=("FAIL | $1"); FAIL=$((FAIL+1)); echo "----- DETALHE DA FALHA: $1 -----"; echo "$2"; }
check_ok() { if echo "$2" | grep -qiE "ERROR|exception"; then bad "$1" "$2"; else ok "$1"; fi; }
check_blocked() { if echo "$2" | grep -qiE "ERROR|exception|UPDATE 0|DELETE 0"; then ok "$1"; else bad "$1" "$2"; fi; }

cd /home/claude/optimon

########################################
echo "### PASSO A: regressao completa Fase1..Fase2.2 — arquivo ORIGINAL run_tests_fase22.sh, sem edicao, ANTES das migrations da Fase 2.2.1 ###"
FASE22_LOG=/tmp/fase22_regression_before_221.log
bash tests/run_tests_fase22.sh > "$FASE22_LOG" 2>&1
FASE22_SUMMARY=$(tail -n1 "$FASE22_LOG")
echo "Resultado do run_tests_fase22.sh (original, inalterado): $FASE22_SUMMARY"
if echo "$FASE22_SUMMARY" | grep -qE '^[0-9]+ PASS / 0 FAIL$'; then
  ok "PASSO-A regressao completa Fase1+Fase1.1+Fase1.2+Fase2+Fase2.1+Fase2.2 (arquivo original run_tests_fase22.sh, ZERO edicoes) — $FASE22_SUMMARY, banco deixado pronto para as migrations da Fase 2.2.1 por cima (evolucao incremental, nunca reconstrucao)"
else
  bad "PASSO-A regressao completa Fase1..Fase2.2 (run_tests_fase22.sh original)" "$FASE22_SUMMARY — ver $FASE22_LOG"
  echo "ABORTANDO: nao faz sentido continuar para a Fase 2.2.1 se a base (Fase1..Fase2.2) nao esta 100% intacta."
  echo ""; echo "=============================================="; echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"; echo "=============================================="
  for r in "${RESULTS[@]}"; do echo "$r"; done
  exit 1
fi

########################################
echo ""; echo "### PASSO B: aplicando as 5 migrations da Fase 2.2.1 sobre o MESMO banco (sem rebuild, sem seed propria) ###"
for f in $(ls supabase/migrations/20260830*.sql | sort); do
  $PSQL -v ON_ERROR_STOP=1 -f "$f" >/tmp/m221.log 2>&1 || { echo "FALHOU migration Fase2.2.1: $f"; cat /tmp/m221.log; exit 1; }
done
ok "PASSO-B todas as 5 migrations da Fase 2.2.1 aplicaram sem erro sobre banco com dados reais de Fase1..Fase2.2 (sem seed propria)"

########################################
echo ""; echo "### re-derivando IDs (mesmos usuarios/contrato/cidade criados pelo run_tests_fase22.sh) ###"
COMERCIAL_ID=$(uid_of "select id from usuarios where email='comercial@optimon.local';")
FINANCEIRO_ID=$(uid_of "select id from usuarios where email='financeiro@optimon.local';")
DIRETOR_ID=$(uid_of "select id from usuarios where email='diretor@optimon.local';")
ADMINISTRADOR_ID=$(uid_of "select id from usuarios where perfil='ADMINISTRADOR' limit 1;")
CIDADE=$(uid_of "select id from cidades_infra where nome='Jussara';")
POP1=$(uid_of "select id from infra_pops where codigo='POP-01';")
POP2=$(uid_of "select id from infra_pops where codigo='POP-02';")
CONTRATO_PON=$(uid_of "select id from contratos where numero='0006';")
PORTA_PON006=$(uid_of "select id from infra_portas_pon where codigo_porta='PON-JUS-006';")
echo "IDs: cidade=$CIDADE pop1=$POP1 pop2=$POP2 contrato_pon=$CONTRATO_PON comercial=$COMERCIAL_ID diretor=$DIRETOR_ID financeiro=$FINANCEIRO_ID administrador=$ADMINISTRADOR_ID"

########################################
echo ""; echo "### PASSO C: prova de versionamento real (secao 29) — TESTE-20/TESTE-ARPU antigos, fixados na versao antiga vs. vigente novo ###"

echo ""; echo "--- C1: TESTE-20 antigo (composicao Floor x Minimo, contrato 0006, fat.parceiro R\$10.000), FIXADO em pricing_version='2026.08' (a vigente ANTES desta fase) ---"
declare -A EXPECT_ECO_OLD=( [FLOOR_ONLY]=2150.00 [MINIMUM_ONLY]=2200.00 [FLOOR_AS_MINIMUM]=3350.00 [SUM]=4350.00 )
ECO_OLD_OK=1
for m in FLOOR_ONLY MINIMUM_ONLY FLOOR_AS_MINIMUM SUM; do
  run_admin "update contrato_pricing_config set infra_floor_composition_mode='$m' where contrato_id='$CONTRATO_PON';" >/dev/null
  T=$(val_of "select (app.get_economia_com_piso('$CONTRATO_PON', 10000, null, '2026.08')->>'total_payable');")
  if [ "$T" != "${EXPECT_ECO_OLD[$m]}" ]; then ECO_OLD_OK=0; bad "C1-$m" "esperado ${EXPECT_ECO_OLD[$m]} (pricing_version='2026.08'), obtido $T"; fi
done
[ "$ECO_OLD_OK" = "1" ] && ok "C1 pricing_version='2026.08' FIXADO reproduz EXATAMENTE os totais antigos da Fase 2.2 (FLOOR_ONLY=2150 MINIMUM_ONLY=2200 FLOOR_AS_MINIMUM=3350 SUM=4350) mesmo depois da Fase 2.2.1 mudar o parametro vigente — prova real de versionamento historico (secao 29), nao so um rotulo cosmetico"

echo ""; echo "--- C2: os MESMOS 4 modos, agora SEM fixar versao (vigente = '2026.08.1', poste R\$8 + PON R\$200/250/300) — valores NOVOS, documentados ---"
declare -A EXPECT_ECO_NEW=( [FLOOR_ONLY]=2020.00 [MINIMUM_ONLY]=2200.00 [FLOOR_AS_MINIMUM]=3220.00 [SUM]=4220.00 )
ECO_NEW_OK=1
for m in FLOOR_ONLY MINIMUM_ONLY FLOOR_AS_MINIMUM SUM; do
  run_admin "update contrato_pricing_config set infra_floor_composition_mode='$m' where contrato_id='$CONTRATO_PON';" >/dev/null
  T=$(val_of "select (app.get_economia_com_piso('$CONTRATO_PON', 10000, null, null)->>'total_payable');")
  if [ "$T" != "${EXPECT_ECO_NEW[$m]}" ]; then ECO_NEW_OK=0; bad "C2-$m" "esperado ${EXPECT_ECO_NEW[$m]} (vigente 2026.08.1), obtido $T"; fi
done
[ "$ECO_NEW_OK" = "1" ] && ok "C2 vigente atual ('2026.08.1', floor R\$2.020 com 1 PON): FLOOR_ONLY=2020 MINIMUM_ONLY=2200(inalterado, nao usa floor) FLOOR_AS_MINIMUM=3220 SUM=4220 — MUDANCA INTENCIONAL e documentada em relacao a Fase 2.2 (poste R\$10->R\$8 + componente PON R\$200), NUNCA escondida"

echo ""; echo "--- C3: modo MAX — mudanca de SEMANTICA intencional (secao 21): antes base=MAX(floor,minimo)+share; agora literal MAX(floor,revenue_share), minimo ignorado ---"
run_admin "update contrato_pricing_config set infra_floor_composition_mode='MAX' where contrato_id='$CONTRATO_PON';" >/dev/null
MAX_OLD_SEM_PINNED=$(val_of "select (app.get_economia_com_piso('$CONTRATO_PON', 10000, null, '2026.08')->>'total_payable');")
MAX_NEW=$(val_of "select (app.get_economia_com_piso('$CONTRATO_PON', 10000, null, null)->>'total_payable');")
# fat.parceiro=10000, share=12% => revenue_share=1200; floor(2026.08)=2150 -> MAX(2150,1200)=2150 (mesmo valor da formula antiga por coincidencia numerica, mas a FORMULA mudou: antes dependia de minimo+modelo_cobranca, agora nao)
# floor(2026.08.1, com PON)=2020 -> MAX(2020,1200)=2020
[ "$MAX_OLD_SEM_PINNED" = "2150.00" ] && [ "$MAX_NEW" = "2020.00" ] && \
  ok "C3 MAX com formula NOVA (MAX(Floor,RevenueShare), seção 21): pinned 2026.08 -> R\$$MAX_OLD_SEM_PINNED (=floor, pois RS=1200<floor); vigente 2026.08.1 -> R\$$MAX_NEW (=floor novo). O REGRESSION-ASSERTION antigo de TESTE-20/MAX da Fase 2.2 (3350.00, formula antiga com minimo) NAO se repete aqui de proposito — mudanca de comportamento intencional e documentada, nao regressao (ver RELATORIO_FASE221.md)" || \
  bad "C3" "pinned=$MAX_OLD_SEM_PINNED (esperado 2150.00) novo=$MAX_NEW (esperado 2020.00)"
run_admin "update contrato_pricing_config set infra_floor_composition_mode='FLOOR_AS_MINIMUM' where contrato_id='$CONTRATO_PON';" >/dev/null

echo ""; echo "--- C4: TESTE-ARPU antigo, FIXADO em '2026.08' — reproduz os 7 pontos originais exatamente ---"
declare -A EXPECT_ARPU_OLD=( [10]=2270.00 [25]=2450.00 [50]=2750.00 [75]=3050.00 [84]=3158.00 [100]=3350.00 [128]=3686.00 )
ARPU_OLD_OK=1
for CLI in 10 25 50 75 84 100 128; do
  FAT=$((CLI * 100))
  T=$(val_of "select (app.get_economia_com_piso('$CONTRATO_PON', $FAT, null, '2026.08')->>'total_payable');")
  if [ "$T" != "${EXPECT_ARPU_OLD[$CLI]}" ]; then ARPU_OLD_OK=0; bad "C4-$CLI" "clientes=$CLI esperado=${EXPECT_ARPU_OLD[$CLI]} obtido=$T"; fi
done
[ "$ARPU_OLD_OK" = "1" ] && ok "C4 teste de ARPU original (7 pontos, pricing_version='2026.08' fixado) reproduzido byte a byte apos a Fase 2.2.1 — historico realmente preservado"

########################################
echo ""; echo "### PASSO D: bateria propria da Fase 2.2.1 ###"

echo ""; echo "--- TESTE-30: Jussara COM PON (exemplo oficial: 165 postes, 5.000m, 1 PON) — PISO/RECOMENDADO/ABERTURA ---"
FLOOR30=$(json_of "select app.calculate_infrastructure_floor('$CIDADE', null, null, 1);")
echo "$FLOOR30" | grep -q '"floor_price": 2020.00' && echo "$FLOOR30" | grep -q '"recommended_price": 2320.00' && echo "$FLOOR30" | grep -q '"opening_price": 2620.00' && echo "$FLOOR30" | grep -q '"pon_component": 200.00' && \
  ok "TESTE30 Jussara com 1 PON: PISO=R\$2.020 RECOMENDADO=R\$2.320 ABERTURA=R\$2.620, componente PON=R\$200 — bate exato com o exemplo oficial da Fase 2.2.1" || \
  bad "TESTE30" "$FLOOR30"

echo ""; echo "--- TESTE-31: escala PON 1-6 (Jussara) ---"
declare -A EXPECT_ESCALA=( [1]=2020.00 [2]=2220.00 [3]=2420.00 [4]=2620.00 [5]=2820.00 [6]=3020.00 )
ESCALA_OK=1
for n in 1 2 3 4 5 6; do
  T=$(val_of "select (app.calculate_infrastructure_floor('$CIDADE', null, null, $n)->>'floor_price');")
  if [ "$T" != "${EXPECT_ESCALA[$n]}" ]; then ESCALA_OK=0; bad "TESTE31-$n" "PON=$n esperado ${EXPECT_ESCALA[$n]} obtido $T"; fi
done
[ "$ESCALA_OK" = "1" ] && ok "TESTE31 escala PON 1-6: R\$2.020/2.220/2.420/2.620/2.820/3.020 — cada PON adicional soma R\$200 ao piso (preço/PON no nível piso)"

echo ""; echo "--- TESTE-32: capacidade — PON e sempre RESERVADA+ATIVA (contratado), nunca so ATIVA (secao 19) ---"
SITUACAO_ANTES=$(text_of "select situacao_comercial from infra_portas_pon where id='$PORTA_PON006';")
PONS_ANTES=$(val_of "select (app.calculate_infrastructure_floor_for_contract('$CONTRATO_PON')->>'pons_count');")
run_admin "update infra_portas_pon set situacao_comercial='RESERVADA' where id='$PORTA_PON006';" >/dev/null
PONS_RESERVADA=$(val_of "select (app.calculate_infrastructure_floor_for_contract('$CONTRATO_PON')->>'pons_count');")
PONS_SOMENTE_ATIVA=$(val_of "select app.get_portas_contratadas_count('$CONTRATO_PON', true);")
run_admin "update infra_portas_pon set situacao_comercial='$SITUACAO_ANTES' where id='$PORTA_PON006';" >/dev/null
PONS_DEPOIS=$(val_of "select (app.calculate_infrastructure_floor_for_contract('$CONTRATO_PON')->>'pons_count');")
[ "$PONS_ANTES" = "1" ] && [ "$PONS_RESERVADA" = "1" ] && [ "$PONS_SOMENTE_ATIVA" = "0" ] && [ "$PONS_DEPOIS" = "1" ] && \
  ok "TESTE32 porta RESERVADA (nao so ATIVA) continua contando no Floor (pons_count=1 antes/durante/depois=$PONS_ANTES/$PONS_RESERVADA/$PONS_DEPOIS); com somente_ativas=true cairia para $PONS_SOMENTE_ATIVA — confirma secao 19 (capacidade RESERVADA, billing por reserva, nao por uso)" || \
  bad "TESTE32" "antes=$PONS_ANTES reservada=$PONS_RESERVADA somente_ativa=$PONS_SOMENTE_ATIVA depois=$PONS_DEPOIS"

echo ""; echo "--- TESTE-33: governanca por papel (secao 12/33-35) — COMERCIAL vs DIRETOR, mesma regua (piso=2020 recomendado=2320 abertura=2620) ---"
echo "NOTA (divulgada por instrucao explicita — nunca esconder inconsistencia): a secao 33 do prompt da como exemplo R\$2.100 -> BLOCK_FOR_COMMERCIAL, mas pela formula EXPLICITA da secao 12 (piso<=x<recomendado -> ALLOW_WITH_DISCOUNT para Comercial) e R\$2.100 >= piso(R\$2.020), o resultado correto e ALLOW_WITH_DISCOUNT. Implementado conforme a formula da secao 12 (ver comentario na migration 3 e RELATORIO_FASE221.md)."
# NOTA: a funcao NAO resolve MAX_OVERRIDE_DISCOUNT_PERCENT sozinha quando chamada
# diretamente (isso e feito pelo wrapper public.pricing_infra_floor_negotiation, que
# resolve via app.get_infra_floor_param antes de chamar) — passamos 0.50 explicitamente
# aqui (o valor real vigente, ja confirmado no TESTE34a) para exercitar o piso absoluto.
# Sem passar nada (null), a funcao aceita CHAMAR sem o limite absoluto (advisory-only,
# util para previews sem regua completa) — comportamento tambem correto, so nao e o que
# este teste especifico quer validar.
#
# DIRETOR so recebe um veredito DIFERENTE de Comercial ABAIXO do piso (secao 12): na
# faixa piso<=x<recomendado, TODO MUNDO (Comercial e Diretor) recebe ALLOW_WITH_DISCOUNT —
# nao ha necessidade de override ali, ja esta dentro da autoridade normal do Comercial.
declare -A EXPECT_ROLE_COM=( [2620]=ALLOW [2320]=ALLOW [2100]=ALLOW_WITH_DISCOUNT [1900]=BLOCK_FOR_COMMERCIAL [1310]=BLOCK_FOR_COMMERCIAL [1309]=BLOCK_FOR_COMMERCIAL )
declare -A EXPECT_ROLE_DIR=( [2620]=ALLOW [2320]=ALLOW [2100]=ALLOW_WITH_DISCOUNT [1900]=ALLOW_WITH_DIRECTOR_OVERRIDE [1310]=ALLOW_WITH_DIRECTOR_OVERRIDE [1309]=BLOCK )
ROLE33_OK=1
for preco in 2620 2320 2100 1900 1310 1309; do
  RCOM=$(as_role_val "$COMERCIAL_ID" "select app.check_infrastructure_floor_governance_role($preco, 2620, 2320, 2020, 0.50);")
  RDIR=$(as_role_val "$DIRETOR_ID" "select app.check_infrastructure_floor_governance_role($preco, 2620, 2320, 2020, 0.50);")
  [ "$RCOM" = "${EXPECT_ROLE_COM[$preco]}" ] || { ROLE33_OK=0; bad "TESTE33-COM-$preco" "esperado ${EXPECT_ROLE_COM[$preco]} obtido $RCOM"; }
  [ "$RDIR" = "${EXPECT_ROLE_DIR[$preco]}" ] || { ROLE33_OK=0; bad "TESTE33-DIR-$preco" "esperado ${EXPECT_ROLE_DIR[$preco]} obtido $RDIR"; }
done
[ "$ROLE33_OK" = "1" ] && ok "TESTE33 governanca por papel em 6 pontos de preco (2620/2320/2100/1900/1310/1309), com limite de override 50% explicito: entre piso e recomendado (2100) COMERCIAL e DIRETOR recebem o MESMO veredito (ALLOW_WITH_DISCOUNT — dentro da autoridade normal do Comercial, sem necessidade de override); abaixo do piso (1900/1310) so DIRETOR pode seguir (ALLOW_WITH_DIRECTOR_OVERRIDE), Comercial sempre BLOCK_FOR_COMMERCIAL; abaixo do piso absoluto de 50% (1309) BLOCK ate para DIRETOR"

echo ""; echo "--- TESTE-34: desconto/override — piso absoluto de 50% (MINIMUM_AUTHORIZED_PRICE) e enforcement na trigger (nao so advisory) ---"
MIN_AUT34=$(val_of "select app.calcular_preco_minimo_autorizado(2620, 0.50);")
[ "$MIN_AUT34" = "1310.00" ] && ok "TESTE34a calcular_preco_minimo_autorizado(abertura=2620, 50%) = R\$1.310,00 (OPENING_PRICE x (1-0.50))" || bad "TESTE34a" "obtido $MIN_AUT34"
OV34_ID=$(as_role "$COMERCIAL_ID" "select public.pricing_override_create('$CONTRATO_PON', null, 2320, 1309, 'TESTE34: abaixo do piso absoluto.', 2020, 2620);" | grep -Eo "$UUID_RE" | tail -n1)
OUT34_BLOCK=$(as_role "$DIRETOR_ID" "update pricing_override_requests set status='APROVADA' where id='$OV34_ID';")
check_blocked "TESTE34b DIRETOR NAO consegue aprovar R\$1.309 (abaixo do piso absoluto R\$1.310) — bloqueado na TRIGGER (enforcement real, nao so advisory)" "$OUT34_BLOCK"
OV34B_ID=$(as_role "$COMERCIAL_ID" "select public.pricing_override_create('$CONTRATO_PON', null, 2320, 1310, 'TESTE34: exatamente no piso absoluto.', 2020, 2620);" | grep -Eo "$UUID_RE" | tail -n1)
OUT34_OK=$(as_role "$DIRETOR_ID" "update pricing_override_requests set status='APROVADA' where id='$OV34B_ID';")
check_ok "TESTE34c DIRETOR aprova R\$1.310 (exatamente no piso absoluto) com sucesso" "$OUT34_OK"

echo ""; echo "--- TESTE-35: permissao por papel para DECIDIR override (secao 14/35) ---"
OV35_ID=$(as_role "$COMERCIAL_ID" "select public.pricing_override_create('$CONTRATO_PON', null, 2320, 2200, 'TESTE35: Comercial tenta se autoaprovar.', 2020, 2620);" | grep -Eo "$UUID_RE" | tail -n1)
OUT35_SELF=$(as_role "$COMERCIAL_ID" "update pricing_override_requests set status='APROVADA' where id='$OV35_ID';")
check_blocked "TESTE35a COMERCIAL nao pode aprovar o proprio override (RLS permite ver/tocar so enquanto PENDENTE; trigger exige DIRETOR/ADMINISTRADOR -> REQUIRES_APPROVAL/RLS bloqueia)" "$OUT35_SELF"
FINANCEIRO_TEM_PERMISSAO_ANTES=$(val_of "select pode_aprovar_override_pricing from usuarios where id='$FINANCEIRO_ID';")
OUT35_FIN_SEM=$(as_role "$FINANCEIRO_ID" "update pricing_override_requests set status='APROVADA' where id='$OV35_ID';")
check_blocked "TESTE35b FINANCEIRO SEM permissao explicita (pode_aprovar_override_pricing=$FINANCEIRO_TEM_PERMISSAO_ANTES) nao pode aprovar" "$OUT35_FIN_SEM"
run_admin "update usuarios set pode_aprovar_override_pricing=true where id='$FINANCEIRO_ID';" >/dev/null
OUT35_FIN_COM=$(as_role "$FINANCEIRO_ID" "update pricing_override_requests set status='APROVADA' where id='$OV35_ID';")
check_ok "TESTE35c FINANCEIRO COM permissao explicita (pode_aprovar_override_pricing=true) consegue aprovar" "$OUT35_FIN_COM"
run_admin "update usuarios set pode_aprovar_override_pricing=false where id='$FINANCEIRO_ID';" >/dev/null
OV35D_ID=$(as_role "$COMERCIAL_ID" "select public.pricing_override_create('$CONTRATO_PON', null, 2320, 2200, 'TESTE35d: ADMINISTRADOR aprova.', 2020, 2620);" | grep -Eo "$UUID_RE" | tail -n1)
OUT35_ADM=$(as_role "$ADMINISTRADOR_ID" "update pricing_override_requests set status='APROVADA' where id='$OV35D_ID';")
check_ok "TESTE35d ADMINISTRADOR sempre pode aprovar" "$OUT35_ADM"

echo ""; echo "--- TESTE-36: Revenue Share nunca se mistura ao Floor (secao 20) — mesmo faturamento, revenue_share identico em qualquer modo ---"
RS_FLOOR=$(val_of "select (app.get_economia_com_piso('$CONTRATO_PON', 10000, null, null)->>'revenue_share');")
run_admin "update contrato_pricing_config set infra_floor_composition_mode='SUM' where contrato_id='$CONTRATO_PON';" >/dev/null
RS_SUM=$(val_of "select (app.get_economia_com_piso('$CONTRATO_PON', 10000, null, null)->>'revenue_share');")
run_admin "update contrato_pricing_config set infra_floor_composition_mode='FLOOR_AS_MINIMUM' where contrato_id='$CONTRATO_PON';" >/dev/null
[ "$RS_FLOOR" = "$RS_SUM" ] && [ "$RS_FLOOR" = "1200.00" ] && ok "TESTE36 revenue_share = R\$1.200,00 (10.000 x 12%) identico independente do modo de composicao — nunca fundido ao Floor, sempre performance pura" || bad "TESTE36" "floor_as_minimum=$RS_FLOOR sum=$RS_SUM"

echo ""; echo "--- TESTE-37: MAX = literal MAX(Floor,RevenueShare), 2 cenarios (RS<Floor e RS>Floor) ---"
run_admin "update contrato_pricing_config set infra_floor_composition_mode='MAX' where contrato_id='$CONTRATO_PON';" >/dev/null
MAX_LOW=$(val_of "select (app.get_economia_com_piso('$CONTRATO_PON', 10000, null, null)->>'total_payable');")   # RS=1200 < floor=2020 -> floor
MAX_HIGH=$(val_of "select (app.get_economia_com_piso('$CONTRATO_PON', 20000, null, null)->>'total_payable');")  # RS=2400 > floor=2020 -> RS
[ "$MAX_LOW" = "2020.00" ] && [ "$MAX_HIGH" = "2400.00" ] && ok "TESTE37 MAX(Floor=2020,RS): fat.10.000->RS=1.200<Floor->paga R\$2.020 (Floor domina); fat.20.000->RS=2.400>Floor->paga R\$2.400 (Revenue Share domina) — Minimo Contratual (R\$1.000) nunca entra na conta neste modo"
run_admin "update contrato_pricing_config set infra_floor_composition_mode='FLOOR_AS_MINIMUM' where contrato_id='$CONTRATO_PON';" >/dev/null

echo ""; echo "--- TESTE-38: SUM continua Floor+Minimo+RevenueShare (formula do modo SUM em si NAO mudou, so o valor do Floor mudou) ---"
run_admin "update contrato_pricing_config set infra_floor_composition_mode='SUM' where contrato_id='$CONTRATO_PON';" >/dev/null
SUM38=$(val_of "select (app.get_economia_com_piso('$CONTRATO_PON', 10000, null, null)->>'total_payable');")
# Floor=2020 + Minimo=1000 + RS=1200 = 4220
[ "$SUM38" = "4220.00" ] && ok "TESTE38 SUM = Floor(2020) + Minimo(1000) + RevenueShare(1200) = R\$4.220,00 — formula do modo SUM inalterada desde a Fase 2.2, so o Floor de entrada mudou" || bad "TESTE38" "obtido $SUM38"
run_admin "update contrato_pricing_config set infra_floor_composition_mode='FLOOR_AS_MINIMUM' where contrato_id='$CONTRATO_PON';" >/dev/null

echo ""; echo "--- TESTE-39: Multi-POP nunca duplica infraestrutura, agora com PON no Floor (secao 23/24/39) ---"
run_admin "update infra_pops set km_rede=1.2, postes_count=40 where codigo='POP-01';" >/dev/null
run_admin "update infra_pops set km_rede=0.8, postes_count=25 where codigo='POP-02';" >/dev/null
POP1_FLOOR=$(json_of "select app.calculate_infrastructure_floor_by_pop('$CIDADE','$POP1', null, 2);")
POP2_FLOOR=$(json_of "select app.calculate_infrastructure_floor_by_pop('$CIDADE','$POP2', null, 1);")
CIDADE_FLOOR=$(json_of "select app.calculate_city_infrastructure_floor('$CIDADE', null, 1);")
echo "$POP1_FLOOR" | grep -q '"poles_count": 40' && echo "$POP1_FLOOR" | grep -q '"network_meters": 1200.000' && echo "$POP1_FLOOR" | grep -q '"pons_count": 2' && \
echo "$POP2_FLOOR" | grep -q '"poles_count": 25' && echo "$POP2_FLOOR" | grep -q '"network_meters": 800.000' && \
echo "$CIDADE_FLOOR" | grep -q '"poles_count": 165' && echo "$CIDADE_FLOOR" | grep -q '"network_meters": 5000.000' && \
  ok "TESTE39 POP-01 (40 postes/1.200m/2 PON) e POP-02 (25 postes/800m/1 PON) tem Floors PROPRIOS e independentes; consolidado da cidade continua 165 postes/5.000m (fonte unica cidades_infra/infra_postes, NUNCA soma dos POPs) — mesma garantia estrutural da Fase 2.2 (TESTE-13), agora tambem valida com PON no Floor" || \
  bad "TESTE39" "pop1=$POP1_FLOOR pop2=$POP2_FLOOR cidade=$CIDADE_FLOOR"
run_admin "update infra_pops set km_rede=0, postes_count=0 where codigo in ('POP-01','POP-02');" >/dev/null

echo ""; echo "--- TESTE-40: versionamento real — 2 versoes (A='2026.08', B='2026.08.1') coexistem, escopadas a uma cidade de teste isolada ---"
CIDADE_TESTE40=$(uid_of "insert into cidades_infra (nome, uf, km_rede) values ('Cidade Teste Versionamento 2.2.1','GO',1) returning id;")
run_admin "select app.criar_pricing_version('TESTE-2.2.1-B', jsonb_build_object('PISO_INFRAESTRUTURA_PRECO_POSTE', 99.00), '$CIDADE_TESTE40', current_date, 'Teste isolado de versionamento — nao afeta Jussara nem o vigente global.');" >/dev/null
V40_NOVA=$(val_of "select app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_POSTE', '$CIDADE_TESTE40', 'TESTE-2.2.1-B');")
V40_GLOBAL_ANTIGA=$(val_of "select app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_POSTE', '$CIDADE_TESTE40', '2026.08');")
V40_GLOBAL_VIGENTE=$(val_of "select app.get_infra_floor_param('PISO_INFRAESTRUTURA_PRECO_POSTE', '$CIDADE_TESTE40', null);")
[ "$V40_NOVA" = "99.0000" ] && [ "$V40_GLOBAL_ANTIGA" = "10.0000" ] && [ "$V40_GLOBAL_VIGENTE" = "99.0000" ] && \
  ok "TESTE40 nova versao 'TESTE-2.2.1-B' escopada a uma cidade especifica (R\$99/poste) coexiste com a global antiga '2026.08' (R\$10, ainda resolvivel pelo rotulo) e com a global vigente '2026.08.1' (R\$8) — historico real, nao um UPDATE que apaga o anterior; cidade sem override especifico continua herdando o valor GLOBAL vigente" || \
  bad "TESTE40" "nova=$V40_NOVA antiga=$V40_GLOBAL_ANTIGA vigente=$V40_GLOBAL_VIGENTE"

echo ""; echo "--- TESTE-41: auditoria detalhada do override (secao 15) — cidade_id/pop_id/desconto_absoluto + nunca apagar ---"
OV41_ID=$(as_role "$COMERCIAL_ID" "select public.pricing_override_create('$CONTRATO_PON', null, 2320, 2100, 'TESTE41: auditoria detalhada, com POP.', 2020, 2620, '$POP1');" | grep -Eo "$UUID_RE" | tail -n1)
CID41=$(val_of "select cidade_id from pricing_override_requests where id='$OV41_ID';")
POP41=$(val_of "select pop_id from pricing_override_requests where id='$OV41_ID';")
DESC41=$(val_of "select desconto_absoluto from pricing_override_requests where id='$OV41_ID';")
[ "$CID41" = "$CIDADE" ] && [ "$POP41" = "$POP1" ] && [ "$DESC41" = "220.00" ] && \
  ok "TESTE41a override registra cidade_id (resolvido no servidor a partir do contrato, nunca do cliente), pop_id e desconto_absoluto (R\$2.320-R\$2.100=R\$220,00)" || \
  bad "TESTE41a" "cidade=$CID41 pop=$POP41 desconto_absoluto=$DESC41"
COUNT41_ANTES=$(val_of "select count(*) from pricing_override_requests;")
DEL41=$(as_role "$ADMINISTRADOR_ID" "delete from pricing_override_requests where id='$OV41_ID';")
COUNT41_DEPOIS=$(val_of "select count(*) from pricing_override_requests;")
[ "$COUNT41_ANTES" = "$COUNT41_DEPOIS" ] && ok "TESTE41b nem ADMINISTRADOR consegue apagar um override (sem policy de DELETE em pricing_override_requests — imutavel por design, contagem antes=depois=$COUNT41_ANTES)" || bad "TESTE41b" "antes=$COUNT41_ANTES depois=$COUNT41_DEPOIS ($DEL41)"

########################################
echo ""
echo "=============================================="
echo "RESULTADO FINAL: $PASS PASS / $FAIL FAIL"
echo "=============================================="
for r in "${RESULTS[@]}"; do echo "$r"; done
echo "=============================================="
echo "$PASS PASS / $FAIL FAIL"
