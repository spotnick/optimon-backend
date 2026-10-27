#!/usr/bin/env bash
# OptiMap — Fase 2 (fundação geográfica): suíte de testes.
#
# Reconstrói o banco do zero (bootstrap_sandbox.sh: 131 migrations pré-existentes + 4 do
# OptiMap) e valida schema, regras, RLS, consultas geográficas, preservação das tabelas
# oficiais e desempenho com massa sintética. NUNCA rode contra o Supabase real.
#
# Uso: tests/optimap/run_tests_optimap_fase2.sh        (PGHOST=/tmp PGPORT=5432 por padrão)
set -uo pipefail
cd "$(dirname "$0")/../.."
export PGHOST="${PGHOST:-/tmp}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}"
DB=optimon

PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS+1)); echo "PASS | $1"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL | $1"; echo "       -> $2"; }

SQL()  { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" -c "$1" 2>&1; }
# Executa como usuário autenticado (RLS real): papel authenticated + auth.uid() = $1.
AS()   { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" -c "set role authenticated" -c "set app.current_user_id = '$1'" -c "$2" 2>&1; }
ANON() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" -c "set role anon" -c "$1" 2>&1; }

expect_eq()  { local name="$1" got="$2" want="$3"; [ "$got" = "$want" ] && pass "$name" || fail "$name" "esperado [$want], obtido [$got]"; }
expect_err() { local name="$1" out="$2" pat="$3"; echo "$out" | grep -q -- "$pat" && pass "$name" || fail "$name" "esperado erro contendo [$pat], obtido [$out]"; }

# Assinatura estrutural das tabelas oficiais (colunas, constraints, triggers, policies, índices).
ASSINATURA_SQL="
with t(n) as (values ('cidades_infra'),('infra_pops'),('infra_segmentos'),('infra_cabos'),('infra_fibras'),
                     ('infra_postes'),('infra_portas_pon'),('contrato_fibras'),('contratos'),('auditoria'))
select md5(string_agg(x, '|' order by x)) from (
  select 'col:'||c.table_name||'.'||c.column_name||':'||c.data_type||':'||c.is_nullable||':'||coalesce(c.column_default,'') x
    from information_schema.columns c join t on t.n = c.table_name where c.table_schema='public'
  union all select 'con:'||conrelid::regclass||':'||conname||':'||pg_get_constraintdef(oid) from pg_constraint
    where conrelid in (select ('public.'||n)::regclass from t)
  union all select 'trg:'||tg.tgrelid::regclass||':'||case when tg.tgisinternal then 'RI:'||coalesce(c.conname,'?') else tg.tgname end from pg_trigger tg
    left join pg_constraint c on c.oid = tg.tgconstraint
    where tg.tgrelid in (select ('public.'||n)::regclass from t)
      and not (tg.tgisinternal and (c.conrelid::regclass::text like 'gis\_%' or c.conrelid::regclass::text like 'staging.gis\_%'))
  union all select 'pol:'||tablename||':'||policyname||':'||coalesce(qual,'')||':'||coalesce(with_check,'') from pg_policies
    where schemaname='public' and tablename in (select n from t)
  union all select 'idx:'||indexname||':'||indexdef from pg_indexes where schemaname='public' and tablename in (select n from t)
) s;"

echo "== 0. Baseline: só as 131 migrations pré-existentes =="
OPTIMAP_DB=optimon ONLY_BASE=1 tests/optimap/bootstrap_sandbox.sh >/dev/null 2>&1 || { echo "bootstrap baseline falhou"; exit 1; }
ASSIN_BASE=$(SQL "$ASSINATURA_SQL")
FUNCS_AUDIT_SQL="select md5(string_agg(p.oid::regprocedure::text||md5(p.prosrc), '|' order by p.oid::regprocedure::text)) from pg_proc p where p.proname in ('fn_auditoria','registrar_auditoria_semantica','set_atualizado_em','tem_perfil','perfil_atual')"
FUNCS_AUDIT_BASE=$(SQL "$FUNCS_AUDIT_SQL")

echo "== 0. Instalação completa: 131 + OptiMap =="
BOOT=$(tests/optimap/bootstrap_sandbox.sh 2>&1 | tail -1)
expect_eq "T01 todas as migrations aplicam do zero, em ordem" "$BOOT" "OK: $(ls supabase/migrations/*.sql | wc -l) migrations aplicadas em optimon"
expect_eq "T02 PostGIS habilitado no schema extensions" "$(SQL "select extnamespace::regnamespace::text from pg_extension where extname='postgis'")" "extensions"
expect_eq "T03 nenhuma tabela oficial alterada (colunas/constraints/triggers inclusive internos/policies/índices)" "$(SQL "$ASSINATURA_SQL")" "$ASSIN_BASE"
# Única mudança nas tabelas oficiais: as FKs de entrada vindas das tabelas gis_* (o Postgres cria
# triggers internos de integridade referencial na tabela referenciada). Decisão documentada:
# impede apagar um POP/cabo/lote que o mapa documenta. (Fase 4: idem para as FKs do staging
# staging.gis_importacoes → cidades_infra/usuarios — integridade, não alteração da tabela.)
expect_eq "T03b FKs gis_* → tabelas oficiais são só as previstas" \
  "$(SQL "select string_agg(distinct confrelid::regclass::text, ',' order by confrelid::regclass::text) from pg_constraint where contype='f' and conrelid::regclass::text like 'gis\_%' and confrelid::regclass::text not like 'gis\_%' and confrelid::regclass::text not like 'staging.gis\_%'")" \
  "cidades_infra,documentos,infra_cabos,infra_pops,infra_postes,infra_segmentos,usuarios"

# ---------------------------------------------------------------------------
# Fixture (superusuário — simula dados já existentes no OptiMon)
# ---------------------------------------------------------------------------
U_ADM=11111111-0000-0000-0000-000000000001; U_DIR=11111111-0000-0000-0000-000000000002
U_ENG=11111111-0000-0000-0000-000000000003; U_COM=11111111-0000-0000-0000-000000000004
U_FIN=11111111-0000-0000-0000-000000000005; U_AUD=11111111-0000-0000-0000-000000000006
C_JSR=22222222-0000-0000-0000-000000000001; C_CNE=22222222-0000-0000-0000-000000000002
FIX=$(SQL "
insert into auth.users (id, email) values
 ('$U_ADM','adm@t'),('$U_DIR','dir@t'),('$U_ENG','eng@t'),('$U_COM','com@t'),('$U_FIN','fin@t'),('$U_AUD','aud@t');
insert into public.usuarios (id, nome, email, perfil) values
 ('$U_ADM','Adm','adm@t','ADMINISTRADOR'),('$U_DIR','Dir','dir@t','DIRETOR'),('$U_ENG','Eng','eng@t','ENGENHARIA'),
 ('$U_COM','Com','com@t','COMERCIAL'),('$U_FIN','Fin','fin@t','FINANCEIRO'),('$U_AUD','Aud','aud@t','AUDITOR');
insert into public.cidades_infra (id, nome, uf, codigo_ibge, km_rede) values
 ('$C_JSR','Jussara','PR','4112900', 12.5), ('$C_CNE','Cianorte','PR','4105508', 40);
insert into public.infra_segmentos (id, cidade_id, nome, origem, destino, extensao_km) values
 ('33333333-0000-0000-0000-000000000001','$C_JSR','BACKBONE CNE-JSR','CIANORTE','JUSSARA', 0.5),
 ('33333333-0000-0000-0000-000000000002','$C_CNE','CNE-URBANO','POP','BAIRRO', 3);
insert into public.infra_pops (id, cidade_id, codigo, nome, latitude, longitude) values
 ('44444444-0000-0000-0000-000000000001','$C_JSR','POP-JSR-01','POP Jussara', -23.621000, -52.469000),
 ('44444444-0000-0000-0000-000000000002','$C_JSR','POP-JSR-02','POP sem coordenada', null, null),
 ('44444444-0000-0000-0000-000000000003','$C_CNE','POP-CNE-01','POP Cianorte', -23.663000, -52.605000);
insert into public.infra_cabos (id, segmento_id, pop_id, identificacao, capacidade_fo) values
 ('55555555-0000-0000-0000-000000000001','33333333-0000-0000-0000-000000000001','44444444-0000-0000-0000-000000000001','AS80-12F CNE-JSR',12),
 ('55555555-0000-0000-0000-000000000002','33333333-0000-0000-0000-000000000002','44444444-0000-0000-0000-000000000003','CNE-06F',6);
insert into public.infra_fibras (id, cabo_id, numero_fibra, par_numero) values
 ('66666666-0000-0000-0000-000000000001','55555555-0000-0000-0000-000000000001',1,1);
insert into public.infra_postes (id, cidade_id, segmento_id, identificacao, proprietario_terceiro, quantidade, custo_mensal) values
 ('77777777-0000-0000-0000-000000000001','$C_JSR','33333333-0000-0000-0000-000000000001','JSR-LOTE-A','COPEL',3,20.16),
 ('77777777-0000-0000-0000-000000000002','$C_CNE',null,'CNE-LOTE-A','COPEL',10,67.20);
insert into public.parceiros (id, razao_social, cnpj) values ('88888888-0000-0000-0000-000000000001','PARCEIRO TESTE OPTIMAP','11222333000181');
insert into public.contratos (id, numero, parceiro_id, cidade_id, modelo, prazo_meses)
 values ('99999999-0000-0000-0000-000000000001','OPTIMAP-T-1','88888888-0000-0000-0000-000000000001','$C_JSR','DARK_FIBER',48);
insert into public.contrato_fibras (contrato_id, fibra_id) values ('99999999-0000-0000-0000-000000000001','66666666-0000-0000-0000-000000000001');
select 'ok';")
expect_eq "T04 fixture (usuários, cidades, POPs, segmentos, cabos, fibra, lotes, contrato_fibras)" "$(echo "$FIX" | tail -1)" "ok"

DADOS_OFICIAIS_SQL="select md5(string_agg(x,'|' order by x)) from (
  select 'c'||to_jsonb(c)::text x from public.cidades_infra c union all select 's'||to_jsonb(s)::text from public.infra_segmentos s
  union all select 'k'||to_jsonb(k)::text from public.infra_cabos k union all select 'f'||to_jsonb(f)::text from public.infra_fibras f
  union all select 'p'||to_jsonb(p)::text from public.infra_postes p union all select 'o'||to_jsonb(o)::text from public.infra_pops o
  union all select 'cf'||to_jsonb(cf)::text from public.contrato_fibras cf) z;"
DADOS_ANTES=$(SQL "$DADOS_OFICIAIS_SQL")

COPEL=$(SQL "select id from gis_fontes where codigo='COPEL_MAPA_PUBLICO'")
PROPRIA=$(SQL "select id from gis_fontes where codigo='NICK_CADASTRO_MANUAL'")
expect_eq "T05 fontes semeadas (1 EXTERNA Copel com termos registrados + 3 PROPRIA)" \
  "$(SQL "select count(*) filter (where tipo='EXTERNA' and termos_uso is not null)||'/'||count(*) filter (where tipo='PROPRIA') from gis_fontes")" "1/3"

echo "== 1. Postes de referência externos =="
REF1=$(AS $U_ADM "insert into gis_postes_referencia (fonte_id, id_externo, geom, cidade_id, codigo_ibge, situacao_fonte, atributos_fonte, data_referencia)
  values ('$COPEL','1000001', ST_SetSRID(ST_MakePoint(-52.4700,-23.6200),4326), '$C_JSR','4112900','DISPONIVEL','{\"num_seq_geo\":1000001,\"situacao\":\"DISPONIVEL\"}', now()) returning id" | tail -1)
[[ "$REF1" =~ ^[0-9a-f-]{36}$ ]] && pass "T06 ADMINISTRADOR grava poste de referência" || fail "T06 ADMINISTRADOR grava poste de referência" "$REF1"

expect_err "T07 idempotência: mesma fonte + id_externo não duplica (UNIQUE)" \
  "$(AS $U_ADM "insert into gis_postes_referencia (fonte_id, id_externo, geom, data_referencia) values ('$COPEL','1000001', ST_SetSRID(ST_MakePoint(-52.47,-23.62),4326), now())")" \
  "gis_postes_referencia_fonte_id_externo_key"
AS $U_ADM "insert into gis_postes_referencia (fonte_id, id_externo, geom, situacao_fonte, data_referencia) values ('$COPEL','1000001', ST_SetSRID(ST_MakePoint(-52.47,-23.62),4326), 'OCUPADO', now())
  on conflict (fonte_id, id_externo) do update set situacao_fonte = excluded.situacao_fonte, ultima_coleta_em = now()" >/dev/null
expect_eq "T08 reprocessar (upsert) mantém 1 registro e atualiza atributo" \
  "$(SQL "select count(*)||':'||max(situacao_fonte) from gis_postes_referencia where id_externo='1000001'")" "1:OCUPADO"

expect_err "T09 coordenada (0,0) rejeitada" \
  "$(AS $U_ADM "insert into gis_postes_referencia (fonte_id, id_externo, geom, data_referencia) values ('$COPEL','X0', ST_SetSRID(ST_MakePoint(0,0),4326), now())")" "check constraint"
expect_err "T10 lat/long trocadas rejeitadas" \
  "$(AS $U_ADM "insert into gis_postes_referencia (fonte_id, id_externo, geom, data_referencia) values ('$COPEL','X1', ST_SetSRID(ST_MakePoint(-23.62,-52.47),4326), now())")" "check constraint"
expect_err "T11 coordenada fora do Brasil rejeitada" \
  "$(AS $U_ADM "insert into gis_postes_referencia (fonte_id, id_externo, geom, data_referencia) values ('$COPEL','X2', ST_SetSRID(ST_MakePoint(-3.70,40.41),4326), now())")" "check constraint"
expect_err "T12 SRID diferente de 4326 rejeitado" \
  "$(AS $U_ADM "insert into gis_postes_referencia (fonte_id, id_externo, geom, data_referencia) values ('$COPEL','X3', ST_SetSRID(ST_MakePoint(-52.47,-23.62),3857), now())")" "SRID"
expect_err "T13 referência com fonte PROPRIA é rejeitada" \
  "$(AS $U_ADM "insert into gis_postes_referencia (fonte_id, id_externo, geom, data_referencia) values ('$PROPRIA','X4', ST_SetSRID(ST_MakePoint(-52.47,-23.62),4326), now())")" "OPTIMAP_FONTE_INVALIDA"

# Dois postes distintos a ~0,5 m um do outro: proximidade não é identidade.
REF2=$(AS $U_ADM "insert into gis_postes_referencia (fonte_id, id_externo, geom, cidade_id, data_referencia) values ('$COPEL','1000002', ST_SetSRID(ST_MakePoint(-52.469995,-23.62),4326), '$C_JSR', now()) returning id" | tail -1)
expect_eq "T14 dois postes a ~0,5 m com ids diferentes são mantidos separados" \
  "$(SQL "select count(*) from gis_postes_referencia where id_externo in ('1000001','1000002')")" "2"

expect_err "T15 ENGENHARIA não grava referência externa" \
  "$(AS $U_ENG "insert into gis_postes_referencia (fonte_id, id_externo, geom, data_referencia) values ('$COPEL','X5', ST_SetSRID(ST_MakePoint(-52.47,-23.62),4326), now())")" "row-level security"
expect_err "T16 referência não pode ser apagada (sem DELETE)" \
  "$(AS $U_ADM "delete from gis_postes_referencia where id='$REF1'")" "permission denied"

echo "== 2. Promoção referência → poste da NICK =="
REF1_ANTES=$(SQL "select md5(to_jsonb(r)::text) from gis_postes_referencia r where id='$REF1'")
P1=$(AS $U_ENG "select optimap_promover_poste_referencia('$REF1', 'DOCUMENTADO', null, '77777777-0000-0000-0000-000000000001')" | tail -1)
[[ "$P1" =~ ^[0-9a-f-]{36}$ ]] && pass "T17 ENGENHARIA promove poste de referência" || fail "T17 ENGENHARIA promove poste de referência" "$P1"
expect_eq "T18 promoção não altera o registro de referência" "$(SQL "select md5(to_jsonb(r)::text) from gis_postes_referencia r where id='$REF1'")" "$REF1_ANTES"
expect_eq "T19 poste promovido herda posição e fonte da referência (origem honesta)" \
  "$(SQL "select (p.geom = r.geom)::text||':'||(p.fonte_id = r.fonte_id)::text||':'||p.codigo from gis_postes p join gis_postes_referencia r on r.id=p.poste_referencia_id where p.id='$P1'")" "true:true:1000001"
expect_err "T20 promover a mesma referência duas vezes é bloqueado" \
  "$(AS $U_ENG "select optimap_promover_poste_referencia('$REF1')")" "OPTIMAP_JA_PROMOVIDO"
expect_err "T21 promoção não pode criar poste já VALIDADO" \
  "$(AS $U_ENG "select optimap_promover_poste_referencia('$REF2','VALIDADO')")" "OPTIMAP_ESTADO_INVALIDO"
expect_err "T22 COMERCIAL não promove" "$(AS $U_COM "select optimap_promover_poste_referencia('$REF2')")" "OPTIMAP_SEM_PERMISSAO"
expect_eq "T23 histórico registra criação com motivo da promoção" \
  "$(SQL "select estado_novo||':'||(motivo like 'Promovido%')::text||':'||(usuario_id='$U_ENG')::text from gis_validacoes where entidade_id='$P1'")" "DOCUMENTADO:true:true"

echo "== 3. Ciclo de estado e validação =="
P2=$(AS $U_ENG "select optimap_criar_poste('$C_JSR', -52.4680, -23.6210, 'JSR-P2', 'NICK_LEVANTAMENTO_CAMPO', 'PLANEJADO', '77777777-0000-0000-0000-000000000001')" | tail -1)
[[ "$P2" =~ ^[0-9a-f-]{36}$ ]] && pass "T24 cadastro manual de poste com fonte PROPRIA" || fail "T24 cadastro manual de poste com fonte PROPRIA" "$P2"
expect_err "T25 cadastro manual com fonte EXTERNA é recusado (usar promoção)" \
  "$(AS $U_ENG "select optimap_criar_poste('$C_JSR', -52.468, -23.621, 'X', 'COPEL_MAPA_PUBLICO')")" "OPTIMAP_FONTE_INVALIDA"
expect_err "T26 criar poste já VALIDADO é recusado" \
  "$(AS $U_ENG "select optimap_criar_poste('$C_JSR', -52.468, -23.621, 'X', 'NICK_CADASTRO_MANUAL', 'VALIDADO')")" "OPTIMAP_ESTADO_INVALIDO"
expect_err "T26b INSERT direto em gis_postes (PostgREST) negado — só via funções" \
  "$(AS $U_ENG "insert into gis_postes (geom, cidade_id, estado, fonte_id) values (ST_SetSRID(ST_MakePoint(-52.468,-23.621),4326), '$C_JSR', 'DOCUMENTADO', '$COPEL')")" "permission denied"
expect_err "T26c UPDATE direto (validar sem motivo pelo PostgREST) negado" \
  "$(AS $U_ENG "update gis_postes set estado='VALIDADO' where id='$P2'")" "permission denied"
expect_err "T27 validar sem motivo é recusado" "$(AS $U_ENG "select optimap_alterar_estado('gis_postes','$P2','VALIDADO')")" "OPTIMAP_MOTIVO_OBRIGATORIO"
AS $U_ENG "select optimap_alterar_estado('gis_postes','$P2','VALIDADO','Conferido em campo 21/10')" >/dev/null
expect_eq "T28 validação grava validado_por = usuário e validado_em" \
  "$(SQL "select estado||':'||(validado_por='$U_ENG')::text||':'||(validado_em is not null)::text from gis_postes where id='$P2'")" "VALIDADO:true:true"
expect_eq "T29 histórico da validação com estado anterior e motivo" \
  "$(SQL "select estado_anterior||'>'||estado_novo||':'||motivo from gis_validacoes where entidade_id='$P2' and estado_novo='VALIDADO'")" "PLANEJADO>VALIDADO:Conferido em campo 21/10"
SQL "update gis_postes set validado_por='$U_ADM', criado_por='$U_ADM' where id='$P2'" >/dev/null
expect_eq "T30 validado_por e criado_por não mudam nem por UPDATE de superusuário (trigger)" "$(SQL "select (validado_por='$U_ENG')::text||':'||(criado_por='$U_ENG')::text from gis_postes where id='$P2'")" "true:true"
AS $U_ENG "select optimap_alterar_geometria('gis_postes','$P2','{\"type\":\"Point\",\"coordinates\":[-52.46805,-23.62105]}','Ajuste GPS')" >/dev/null
expect_eq "T31 mover poste VALIDADO o rebaixa para DOCUMENTADO (revalidar)" \
  "$(SQL "select estado||':'||(validado_por is null)::text from gis_postes where id='$P2'")" "DOCUMENTADO:true"
expect_eq "T32 rebaixamento automático fica no histórico com motivo" \
  "$(SQL "select count(*) from gis_validacoes where entidade_id='$P2' and estado_anterior='VALIDADO' and estado_novo='DOCUMENTADO' and motivo='Ajuste GPS'")" "1"
expect_err "T33 COMERCIAL não valida" "$(AS $U_COM "select optimap_alterar_estado('gis_postes','$P2','VALIDADO','x')")" "OPTIMAP_SEM_PERMISSAO"
expect_err "T34 gis_validacoes imutável (UPDATE)" "$(SQL "update gis_validacoes set motivo='x'")" "OPTIMAP_HISTORICO_IMUTAVEL"
expect_err "T35 gis_validacoes imutável (DELETE)" "$(SQL "delete from gis_validacoes")" "OPTIMAP_HISTORICO_IMUTAVEL"
expect_err "T36 ENGENHARIA não insere histórico direto (só o trigger)" \
  "$(AS $U_ENG "insert into gis_validacoes (entidade, entidade_id, estado_novo) values ('gis_postes','$P2','VALIDADO')")" "permission denied"
expect_err "T37 GeoJSON com tipo errado é recusado" \
  "$(AS $U_ENG "select optimap_alterar_geometria('gis_postes','$P2','{\"type\":\"LineString\",\"coordinates\":[[-52.4,-23.6],[-52.5,-23.7]]}')")" "OPTIMAP_GEOMETRIA_INVALIDA"

echo "== 4. Vínculos com a infraestrutura existente =="
expect_err "T38 poste com lote (infra_postes) de outra cidade é recusado" \
  "$(AS $U_ENG "select optimap_criar_poste('$C_JSR', -52.468, -23.6215, 'X', 'NICK_CADASTRO_MANUAL', 'DOCUMENTADO', '77777777-0000-0000-0000-000000000002')")" "OPTIMAP_VINCULO_INVALIDO"
expect_err "T39 elemento ligado a POP de outra cidade é recusado" \
  "$(AS $U_ENG "select optimap_criar_elemento('CEO', '$C_JSR', -52.468, -23.621, 'CEO-X', null, null, '44444444-0000-0000-0000-000000000003')")" "OPTIMAP_VINCULO_INVALIDO"
E1=$(AS $U_ENG "select optimap_criar_elemento('CEO', '$C_JSR', null, null, 'CEO-JSR-01', 'Caixa 01', '$P2', null, 'NICK_LEVANTAMENTO_CAMPO', 'DOCUMENTADO', '{\"bandejas\":2}')" | tail -1)
expect_eq "T40 elemento sem coordenada herda posição do poste" \
  "$(SQL "select (e.geom = p.geom)::text from gis_elementos e join gis_postes p on p.id=e.poste_id where e.id='$E1'")" "true"
expect_err "T41 trecho com cabo de outro segmento é recusado" \
  "$(AS $U_ENG "select optimap_criar_trecho('$C_JSR', '{\"type\":\"LineString\",\"coordinates\":[[-52.469,-23.621],[-52.468,-23.621]]}', '33333333-0000-0000-0000-000000000001', '55555555-0000-0000-0000-000000000002')")" "OPTIMAP_VINCULO_INVALIDO"
# ~102,1 m de traçado (0,001° de longitude em −23,621° de latitude)
T1=$(AS $U_ENG "select optimap_criar_trecho('$C_JSR', '{\"type\":\"LineString\",\"coordinates\":[[-52.469,-23.621],[-52.468,-23.621]]}', null, '55555555-0000-0000-0000-000000000001', null, '44444444-0000-0000-0000-000000000001', '$E1', null, array['$P1'::uuid,'$P2'::uuid])" | tail -1)
expect_eq "T42 trecho herda o segmento do cabo" "$(SQL "select segmento_id from gis_trechos where id='$T1'")" "33333333-0000-0000-0000-000000000001"
expect_eq "T43 comprimento geodésico calculado (~102 m)" "$(SQL "select (comprimento_geo_m between 101 and 103)::text from gis_trechos where id='$T1'")" "true"
expect_eq "T44 sequência de postes do trecho gravada em ordem" "$(SQL "select string_agg(ordem::text, ',' order by ordem) from gis_trecho_postes where trecho_id='$T1'")" "1,2"
AS $U_ENG "select optimap_alterar_estado('gis_trechos','$T1','VALIDADO','Percorrido em campo')" >/dev/null
AS $U_ENG "select optimap_alterar_geometria('gis_trechos','$T1','{\"type\":\"LineString\",\"coordinates\":[[-52.468,-23.621],[-52.469,-23.621]]}','Inversão de sentido')" >/dev/null
expect_eq "T44b inverter só a direção do traçado VALIDADO também rebaixa (ST_OrderingEquals)" "$(SQL "select estado from gis_trechos where id='$T1'")" "DOCUMENTADO"
AS $U_ENG "select optimap_alterar_estado('gis_trechos','$T1','VALIDADO','Revalidado')" >/dev/null
SQL "delete from gis_trecho_postes where trecho_id='$T1' and ordem=2" >/dev/null
expect_eq "T44c alterar a sequência de postes de trecho VALIDADO rebaixa o trecho" "$(SQL "select estado from gis_trechos where id='$T1'")" "DOCUMENTADO"
SQL "insert into gis_trecho_postes (trecho_id, poste_id, ordem) values ('$T1','$P2',2)" >/dev/null
expect_err "T44d promover referência para cidade diferente da dela é recusado" \
  "$(AS $U_ENG "select optimap_promover_poste_referencia('$REF2','DOCUMENTADO','$C_CNE')")" "OPTIMAP_VINCULO_INVALIDO"
expect_err "T44e trecho com ponta em elemento arquivado é recusado" \
  "$(AS $U_ENG "select optimap_criar_trecho('$C_JSR', '{\"type\":\"LineString\",\"coordinates\":[[-52.469,-23.621],[-52.468,-23.622]]}', null, null, '00000000-0000-0000-0000-00000000dead')")" "OPTIMAP_VINCULO_INVALIDO"
expect_eq "T44f GeoJSON com altitude (Z) é aceito e gravado em 2D" \
  "$(AS $U_ENG "select optimap_alterar_geometria('gis_postes','$P1','{\"type\":\"Point\",\"coordinates\":[-52.4700,-23.6200,612.5]}','GPS com altitude')" >/dev/null; SQL "select ST_NDims(geom) from gis_postes where id='$P1'")" "2"
AS $U_ENG "select optimap_criar_elemento('CTO', '$C_JSR', -52.4665, -23.6215, 'CTO-POP2', null, null, '44444444-0000-0000-0000-000000000002')" >/dev/null
expect_err "T44g apagar um POP usado pelo mapa é bloqueado pela FK (proteção intencional)" \
  "$(SQL "delete from infra_pops where id='44444444-0000-0000-0000-000000000002'")" "gis_elementos_pop_id_fkey"
AS $U_ENG "select optimap_alterar_estado('gis_trechos','$T1','VALIDADO','Revalidado 2')" >/dev/null
AS $U_ENG "select optimap_definir_postes_trecho('$T1', array['$P2'::uuid,'$P1'::uuid], 'Ordem corrigida em campo')" >/dev/null
expect_eq "T44h redefinir postes do trecho (função) reordena e rebaixa VALIDADO com o motivo informado" \
  "$(SQL "select string_agg(p.codigo, ',' order by tp.ordem) from gis_trecho_postes tp join gis_postes p on p.id=tp.poste_id where tp.trecho_id='$T1'")|$(SQL "select estado from gis_trechos where id='$T1'")|$(SQL "select motivo from gis_validacoes where entidade_id='$T1' order by criado_em desc limit 1")" \
  "JSR-P2,1000001|DOCUMENTADO|Ordem corrigida em campo"
expect_err "T44i poste repetido na sequência é recusado" "$(AS $U_ENG "select optimap_definir_postes_trecho('$T1', array['$P2'::uuid,'$P2'::uuid])")" "OPTIMAP_VINCULO_INVALIDO"
AS $U_ENG "select optimap_alterar_atributos('gis_elementos','$E1','{\"nome\":\"Caixa 01 - esquina\",\"atributos\":{\"bandejas\":4}}')" >/dev/null
expect_eq "T44j editar atributos (nome e jsonb) pela função" "$(SQL "select nome||':'||(atributos->>'bandejas') from gis_elementos where id='$E1'")" "Caixa 01 - esquina:4"
expect_err "T44k campo fora da lista fechada (estado/geom/criado_por) é recusado" \
  "$(AS $U_ENG "select optimap_alterar_atributos('gis_postes','$P1','{\"criado_por\":\"$U_ADM\"}')")" "OPTIMAP_CAMPO_NAO_EDITAVEL"
AS $U_ENG "select optimap_alterar_estado('gis_elementos','$E1','VALIDADO','Conferida')" >/dev/null
AS $U_ENG "select optimap_alterar_atributos('gis_elementos','$E1','{\"pop_id\":\"44444444-0000-0000-0000-000000000001\"}','Ligada ao POP')" >/dev/null
expect_eq "T44l trocar vínculo (POP) de elemento VALIDADO rebaixa; trocar só o nome não" \
  "$(SQL "select estado from gis_elementos where id='$E1'")" "DOCUMENTADO"
expect_err "T44m evidência inexistente é recusada" \
  "$(AS $U_ENG "select optimap_alterar_estado('gis_elementos','$E1','VALIDADO','x','00000000-0000-0000-0000-0000000000aa')")" "OPTIMAP_EVIDENCIA_INVALIDA"
expect_eq "T45 divergência de extensão sinalizada sem alterar infra_segmentos" \
  "$(AS $U_ENG "select extensao_km_declarada||':'||extensao_km_desenhada||':'||diferenca_pct from vw_gis_divergencia_extensao_segmento where segmento_id='33333333-0000-0000-0000-000000000001'" | tail -1)" "0.500:0.102:-79.6"
expect_eq "T46 conciliação lote×postes (lote 3, 2 georreferenciados)" \
  "$(AS $U_ENG "select quantidade_lote||':'||postes_georreferenciados||':'||situacao from vw_gis_conciliacao_lotes_postes where infra_poste_lote_id='77777777-0000-0000-0000-000000000001'" | tail -1)" "3:2:FALTAM_GEORREFERENCIAR"
expect_eq "T47 pendências: POP sem coordenada aparece em documentação incompleta" \
  "$(AS $U_ENG "select count(*) from vw_gis_documentacao_incompleta where id='44444444-0000-0000-0000-000000000002'" | tail -1)" "1"

echo "== 5. Arquivamento =="
expect_err "T48 arquivar poste com elemento/trecho ativo é bloqueado" "$(AS $U_ENG "select optimap_arquivar('gis_postes','$P2','teste')")" "OPTIMAP_DEPENDENCIA_ATIVA"
expect_err "T49 arquivar sem motivo é recusado" "$(AS $U_ENG "select optimap_arquivar('gis_trechos','$T1','')")" "OPTIMAP_MOTIVO_OBRIGATORIO"
AS $U_ENG "select optimap_arquivar('gis_trechos','$T1','Traçado refeito')" >/dev/null
expect_eq "T50 trecho arquivado some do mapa (bbox) mas continua no banco" \
  "$(AS $U_ENG "select (optimap_bbox('trechos',-52.6,-23.7,-52.4,-23.5)->'features')::text" | tail -1):$(SQL "select count(*) from gis_trechos where id='$T1' and removido_em is not null")" "[]:1"
expect_err "T51 DELETE físico em gis_postes negado" "$(AS $U_ADM "delete from gis_postes where id='$P1'")" "permission denied"

# Corrida: arquivar poste (sessão 1, transação aberta) × ligar elemento a ele (sessão 2).
P_RACE=$(AS $U_ENG "select optimap_criar_poste('$C_JSR', -52.4690, -23.6230, 'JSR-RACE')" | tail -1)
( psql -X -q -d $DB -c "set role authenticated" -c "set app.current_user_id = '$U_ENG'" \
    -c "begin; select optimap_arquivar('gis_postes','$P_RACE','teste de corrida'); select pg_sleep(3); commit;" >/dev/null 2>&1 ) &
sleep 1
RACE_OUT=$(AS $U_ENG "select optimap_criar_elemento('CTO', '$C_JSR', null, null, 'CTO-RACE', null, '$P_RACE')")
wait
expect_err "T51b corrida arquivar×vincular: o vínculo espera o arquivamento e é recusado" "$RACE_OUT" "OPTIMAP_VINCULO_INVALIDO"
expect_eq "T51c nenhum elemento ativo ficou pendurado em poste arquivado" \
  "$(SQL "select count(*) from gis_elementos e join gis_postes p on p.id=e.poste_id where e.removido_em is null and p.removido_em is not null")" "0"

echo "== 6. RLS por perfil =="
for u in "$U_ADM:ADMINISTRADOR" "$U_DIR:DIRETOR" "$U_ENG:ENGENHARIA" "$U_COM:COMERCIAL" "$U_AUD:AUDITOR"; do
  uid=${u%%:*}; nome=${u##*:}
  expect_eq "T52 $nome lê postes de referência e rede própria" "$(AS $uid "select (select count(*) from gis_postes_referencia)>0 and (select count(*) from gis_postes)>0" | tail -1)" "t"
done
expect_eq "T53 FINANCEIRO não vê nada do OptiMap" \
  "$(AS $U_FIN "select (select count(*) from gis_postes_referencia)+(select count(*) from gis_postes)+(select count(*) from gis_elementos)+(select count(*) from gis_fontes)" | tail -1)" "0"
expect_err "T54 COMERCIAL não insere poste" \
  "$(AS $U_COM "insert into gis_postes (geom, cidade_id, fonte_id) values (ST_SetSRID(ST_MakePoint(-52.468,-23.621),4326), '$C_JSR', '$PROPRIA')")" "permission denied"
expect_err "T54b TRUNCATE do histórico negado (default privileges do Supabase revogados)" "$(AS $U_ENG "truncate gis_validacoes")" "permission denied"
expect_err "T54c ADMINISTRADOR não muda o tipo de uma fonte (EXTERNA→PROPRIA)" "$(AS $U_ADM "update gis_fontes set tipo='PROPRIA' where codigo='COPEL_MAPA_PUBLICO'")" "OPTIMAP_FONTE_IMUTAVEL"
expect_eq "T54d FINANCEIRO não vê nem as views derivadas do OptiMap" \
  "$(AS $U_FIN "select (select count(*) from vw_gis_pops)+(select count(*) from vw_gis_conciliacao_lotes_postes)+(select count(*) from vw_gis_documentacao_incompleta)" | tail -1)" "0"
expect_eq "T54e motivo forjado na sessão não chega ao histórico (funções zeram o contexto)" \
  "$(psql -X -q -At -d $DB -c "set role authenticated" -c "set app.current_user_id = '$U_ENG'" -c "set optimap.motivo = 'FORJADO'" -c "select optimap_criar_poste('$C_JSR', -52.4671, -23.6211, 'JSR-P9')" >/dev/null 2>&1; SQL "select count(*) from gis_validacoes where motivo='FORJADO'")" "0"
expect_eq "T55 ENGENHARIA não altera fontes (RLS: 0 linhas afetadas, fonte intacta)" \
  "$(AS $U_ENG "with u as (update gis_fontes set nome='x' where codigo='COPEL_MAPA_PUBLICO' returning 1) select count(*) from u" | tail -1):$(SQL "select nome like 'Copel%' from gis_fontes where codigo='COPEL_MAPA_PUBLICO'")" "0:t"
expect_err "T56 anon não acessa tabelas gis_*" "$(ANON "select count(*) from gis_postes_referencia")" "permission denied"
expect_err "T57 anon não executa wrappers optimap_*" "$(ANON "select optimap_buscar('1000001')")" "permission denied"
expect_eq "T58 nenhuma policy using(true) em tabelas gis_*" \
  "$(SQL "select count(*) from pg_policies where tablename like 'gis\_%' and (qual='true' or with_check='true')")" "0"

echo "== 7. Consultas geográficas =="
BB=$(AS $U_COM "select optimap_bbox('postes_referencia',-52.5,-23.65,-52.44,-23.6)" | tail -1)
expect_eq "T59 bbox devolve FeatureCollection com as referências da área" "$(echo "$BB" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["type"], len(d["features"]), d["truncado"])')" "FeatureCollection 2 False"
expect_eq "T60 bbox respeita limite e sinaliza truncado" "$(AS $U_COM "select (optimap_bbox('postes_referencia',-52.5,-23.65,-52.44,-23.6,null,1)->>'truncado')||':'||jsonb_array_length(optimap_bbox('postes_referencia',-52.5,-23.65,-52.44,-23.6,null,1)->'features')" | tail -1)" "true:1"
expect_err "T61 bbox inválido recusado" "$(AS $U_COM "select optimap_bbox('postes',-52.4,-23.6,-52.5,-23.7)")" "OPTIMAP_BBOX_INVALIDO"
expect_err "T62 camada inexistente recusada" "$(AS $U_COM "select optimap_bbox('clientes',-52.5,-23.7,-52.4,-23.6)")" "OPTIMAP_CAMADA_INVALIDA"
# tile z16 que contém (-52.47,-23.62)
read TX TY <<<"$(python3 -c 'import math;lat=-23.62;lon=-52.47;z=16;n=2**z;x=int((lon+180)/360*n);y=int((1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*n);print(x,y)')"
expect_eq "T63 tile MVT z16 com postes de referência (não vazio)" "$(AS $U_COM "select length(optimap_tile('postes_referencia',16,$TX,$TY))>0" | tail -1)" "t"
read TX12 TY12 <<<"$(python3 -c 'import math;lat=-23.62;lon=-52.47;z=12;n=2**z;x=int((lon+180)/360*n);y=int((1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*n);print(x,y)')"
expect_eq "T64 tile z12 agrega postes de referência (camada _agregado)" \
  "$(AS $U_COM "select position('postes_referencia_agregado' in encode(optimap_tile('postes_referencia',12,$TX12,$TY12),'escape'))>0" | tail -1)" "t"
expect_eq "T65 RLS vale dentro do tile: FINANCEIRO recebe tile vazio" "$(AS $U_FIN "select length(optimap_tile('postes_referencia',16,$TX,$TY))" | tail -1)" "0"
expect_err "T66 tile com z/x/y inválido recusado" "$(AS $U_COM "select optimap_tile('postes',3,99,0)")" "OPTIMAP_TILE_INVALIDO"
expect_eq "T67 tile de POPs só com POPs que têm coordenada" "$(AS $U_COM "select count(*) from vw_gis_pops" | tail -1)" "2"
expect_eq "T68 busca por 'lat, lon' (formato do mapa da Copel)" "$(AS $U_COM "select optimap_buscar('-23.6200, -52.4700')->0->>'tipo'" | tail -1)" "coordenada"
expect_eq "T69 busca pelo número do poste" "$(AS $U_COM "select optimap_buscar('1000002')->0->>'rotulo'" | tail -1)" "Poste 1000002"
expect_eq "T69b busca trata %/_ como texto literal (sem casar tudo)" "$(AS $U_COM "select jsonb_array_length(optimap_buscar('%%'))" | tail -1)" "0"
expect_err "T69c bbox maior que ~50×50 km é recusado" "$(AS $U_COM "select optimap_bbox('postes_referencia',-54.6,-26.7,-48.0,-22.5)")" "OPTIMAP_BBOX_GRANDE"
expect_eq "T69d tile de postes de referência abaixo do zoom 10 vem vazio (custo limitado)" "$(AS $U_COM "select length(optimap_tile('postes_referencia',5,11,17))" | tail -1)" "0"
expect_eq "T70 detalhe de referência traz fonte, atribuição e termos" \
  "$(AS $U_COM "select (optimap_detalhe('postes_referencia','$REF1')->'fonte'->>'atribuicao')||':'||((optimap_detalhe('postes_referencia','$REF1')->'fonte'->>'termos_uso') is not null)::text" | tail -1)" "Fonte: Copel Distribuição S.A.:true"
expect_eq "T71 detalhe de poste traz histórico de estado" "$(AS $U_COM "select jsonb_array_length(optimap_detalhe('postes','$P2')->'historico_estado')" | tail -1)" "3"

expect_eq "T71b service_role (importações em lote da Fase 4) consegue gravar referência (CHECKs com helpers públicos)" \
  "$(psql -X -q -At -d $DB -c "set role service_role" -c "insert into gis_postes_referencia (fonte_id, id_externo, geom, data_referencia) values ('$COPEL','SR-1', ST_SetSRID(ST_MakePoint(-52.47,-23.6205),4326), now()) returning 'ok'" 2>&1 | tail -1)" "ok"

echo "== 8. Auditoria =="
expect_eq "T72 escrita em gis_postes auditada em public.auditoria (com usuário)" \
  "$(SQL "select count(*)>0 from auditoria where entidade='gis_postes' and usuario_id='$U_ENG'")" "t"
expect_eq "T73 gis_postes_referencia não gera auditoria linha-a-linha (rastreio via lote)" "$(SQL "select count(*) from auditoria where entidade='gis_postes_referencia'")" "0"
expect_eq "T74 funções de auditoria existentes não foram alteradas (fn_auditoria / registrar_auditoria_semantica)" "$(SQL "$FUNCS_AUDIT_SQL")" "$FUNCS_AUDIT_BASE"

echo "== 9. Preservação dos dados oficiais =="
expect_eq "T75 cidades/segmentos/cabos/fibras/lotes/POPs/contrato_fibras inalterados após todas as operações" "$(SQL "$DADOS_OFICIAIS_SQL")" "$DADOS_ANTES"
expect_eq "T76 infra_postes.quantidade e cidades_infra.km_rede inalterados" \
  "$(SQL "select string_agg(quantidade::text, ',' order by identificacao) from infra_postes")|$(SQL "select string_agg(km_rede::text, ',' order by nome) from cidades_infra")" "10,3|40.000,12.500"

echo "== 10. Desempenho (massa sintética: ~40 mil postes — escala das 4 cidades) =="
SQL "insert into gis_postes_referencia (fonte_id, id_externo, geom, cidade_id, situacao_fonte, data_referencia)
  select '$COPEL', 'S'||g, ST_SetSRID(ST_MakePoint(-52.70 + random()*0.30, -23.75 + random()*0.20),4326),
         case when g % 2 = 0 then '$C_JSR'::uuid else '$C_CNE'::uuid end, 'DISPONIVEL', now()
  from generate_series(1, 40000) g; analyze gis_postes_referencia;" >/dev/null
expect_eq "T77 consulta por área usa o índice espacial GiST (contexto das funções de leitura)" \
  "$(SQL "explain select id from gis_postes_referencia where geom && ST_MakeEnvelope(-52.48,-23.63,-52.46,-23.61,4326)" | grep -c gis_postes_referencia_geom_gix)" "1"
# Tempo medido DENTRO do banco (sem custo de conexão/psql), como COMERCIAL (RLS + regra de
# perfil), pior de 3 execuções.
ms() { AS "$1" "do \$\$ declare t0 timestamptz; pior numeric := 0; x jsonb; y bytea; begin
  for i in 1..3 loop t0 := clock_timestamp(); $2; pior := greatest(pior, extract(epoch from clock_timestamp()-t0)*1000); end loop;
  raise notice 'MS=%', round(pior); end \$\$;" 2>&1 | grep -o 'MS=[0-9]*' | cut -d= -f2; }
read TXc TYc <<<"$(python3 -c 'import math;lat=-23.66;lon=-52.55;z=16;n=2**z;x=int((lon+180)/360*n);y=int((1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*n);print(x,y)')"
read TXa TYa <<<"$(python3 -c 'import math;lat=-23.66;lon=-52.55;z=12;n=2**z;x=int((lon+180)/360*n);y=int((1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*n);print(x,y)')"
T_Z16=$(ms $U_COM "y := optimap_tile('postes_referencia',16,$TXc,$TYc)")
T_Z12=$(ms $U_COM "y := optimap_tile('postes_referencia',12,$TXa,$TYa)")
T_BB=$(ms $U_COM "x := optimap_bbox('postes_referencia',-52.56,-23.67,-52.54,-23.65)")
echo "      (pior de 3, medido no banco) tile z16: ${T_Z16} ms | tile z12 agregado: ${T_Z12} ms | bbox ~2x2 km: ${T_BB} ms"
[ -n "$T_Z16" ] && [ "$T_Z16" -lt 200 ] && pass "T78 tile z16 < 200 ms com 40 mil postes" || fail "T78 tile z16 < 200 ms" "${T_Z16} ms"
[ -n "$T_Z12" ] && [ "$T_Z12" -lt 500 ] && pass "T79 tile z12 agregado < 500 ms com 40 mil postes" || fail "T79 tile z12 agregado < 500 ms" "${T_Z12} ms"
[ -n "$T_BB" ] && [ "$T_BB" -lt 200 ] && pass "T80 bbox de bairro < 200 ms" || fail "T80 bbox de bairro < 200 ms" "${T_BB} ms"
expect_eq "T81 tile agregado z12 nunca envia postes um a um" \
  "$(AS $U_COM "select position('id_externo' in encode(optimap_tile('postes_referencia',12,$TXa,$TYa),'escape'))=0" | tail -1)" "t"
echo "      tamanho em disco (tabela+índices) com ~40 mil postes: $(SQL "select pg_size_pretty(pg_total_relation_size('gis_postes_referencia'))")"

expect_eq "T82 bbox/tile aplicam a mesma regra de perfil da policy (FINANCEIRO recebe coleção vazia)" \
  "$(AS $U_FIN "select jsonb_array_length(optimap_bbox('postes_referencia',-52.56,-23.67,-52.54,-23.65)->'features')" | tail -1)" "0"
expect_eq "T83 policies e funções de leitura usam a mesma fonte de regra (app.gis_pode_ver)" \
  "$(SQL "select count(*) from pg_policies where schemaname='public' and tablename like 'gis\_%' and cmd='SELECT' and qual not like '%gis_pode_ver()%'")" "0"

if [ "${PERF_GRANDE:-0}" = "1" ]; then
  echo "== 11. Desempenho em escala estadual (1 milhão de postes em 40 aglomerados urbanos) =="
  SQL "insert into gis_postes_referencia (fonte_id, id_externo, geom, situacao_fonte, data_referencia)
    select '$COPEL', 'G'||g, ST_SetSRID(ST_MakePoint(-54.0 + (g % 40 / 8)*1.2 + random()*0.1, -26.0 + (g % 40 % 8)*0.4 + random()*0.1),4326), 'DISPONIVEL', now()
    from generate_series(1, 1000000) g; analyze gis_postes_referencia;" >/dev/null
  # Tempo medido DENTRO do banco (sem custo de conexão), como COMERCIAL (RLS + regra de perfil).
  tempo() { AS $U_COM "do \$\$ declare t0 timestamptz := clock_timestamp(); x bytea; begin x := optimap_tile('postes_referencia',$1,$2,$3); raise notice 'MS=% BYTES=%', round(extract(epoch from clock_timestamp()-t0)*1000), length(x); end \$\$;" 2>&1 | grep -o 'MS=[0-9]* BYTES=[0-9]*'; }
  # aglomerado 0: lon -54.0..-53.9, lat -26.0..-25.9
  for z in 16 15 14 12; do
    read X Y <<<"$(python3 -c "import math;lat=-25.95;lon=-53.95;z=$z;n=2**z;x=int((lon+180)/360*n);y=int((1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*n);print(x,y)")"
    R=$(tempo $z $X $Y); echo "      z$z: $R"
    MSV=$(echo "$R" | sed 's/MS=\([0-9]*\).*/\1/')
    [ -n "$MSV" ] && [ "$MSV" -lt 1500 ] && pass "T84 tile z$z sobre aglomerado de 25 mil postes (base de 1 milhão) < 1,5 s" || fail "T84 tile z$z < 1,5 s" "$R"
  done
  read X Y <<<"$(python3 -c "import math;lat=-25.95;lon=-53.95;z=10;n=2**z;x=int((lon+180)/360*n);y=int((1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*n);print(x,y)")"
  expect_eq "T85 abaixo do zoom 12 a camada de referência não é servida (custo limitado)" "$(tempo 10 $X $Y | sed 's/.*BYTES=//')" "0"
  echo "      tamanho em disco (tabela+índices) com ~1,04 milhão de postes: $(SQL "select pg_size_pretty(pg_total_relation_size('gis_postes_referencia'))")"
fi

echo
echo "================================================================"
echo "Resultado: $PASS PASS / $FAIL FAIL"
if [ $FAIL -gt 0 ]; then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
