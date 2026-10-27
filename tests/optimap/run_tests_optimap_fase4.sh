#!/usr/bin/env bash
# OptiMap — Fase 4 (importação de postes de referência): suíte de testes SQL.
#
# Reconstrói o banco do zero (bootstrap_sandbox.sh: todas as migrations, inclusive as 2 da
# Fase 4) e valida o fluxo completo: recebimento → prévia → comparação → conflitos →
# aprovação → reimportação → ausências → reversão seletiva, além de permissões, RLS,
# imutabilidade do log, auditoria e preservação das tabelas oficiais.
# NUNCA rode contra o Supabase real.
#
# Uso: tests/optimap/run_tests_optimap_fase4.sh     (PGHOST=/tmp PGPORT=5432 por padrão)
set -uo pipefail
cd "$(dirname "$0")/../.."
export PGHOST="${PGHOST:-/tmp}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}"
DB=optimon

PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS+1)); echo "PASS | $1"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL | $1"; echo "       -> $2"; }
SQL()  { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" -c "$1" 2>&1; }
AS()   { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" -c "set role authenticated" -c "set app.current_user_id = '$1'" -c "$2" 2>&1; }
ANON() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" -c "set role anon" -c "$1" 2>&1; }
expect_eq()  { local name="$1" got="$2" want="$3"; [ "$got" = "$want" ] && pass "$name" || fail "$name" "esperado [$want], obtido [$got]"; }
expect_err() { local name="$1" out="$2" pat="$3"; echo "$out" | grep -q -- "$pat" && pass "$name" || fail "$name" "esperado erro contendo [$pat], obtido [$out]"; }
ms() { date +%s%3N; }

echo "== 0. Sandbox =="
bash tests/optimap/bootstrap_sandbox.sh | tail -1

U_ADM=11111111-0000-0000-0000-000000000001; U_DIR=11111111-0000-0000-0000-000000000002
U_ENG=11111111-0000-0000-0000-000000000003; U_COM=11111111-0000-0000-0000-000000000004
U_FIN=11111111-0000-0000-0000-000000000005; U_AUD=11111111-0000-0000-0000-000000000006
U_ENG2=11111111-0000-0000-0000-000000000007
C_JSR=22222222-0000-0000-0000-000000000001; C_AND=22222222-0000-0000-0000-000000000003

FIX=$(SQL "
insert into auth.users (id, email) values
 ('$U_ADM','adm@t'),('$U_DIR','dir@t'),('$U_ENG','eng@t'),('$U_COM','com@t'),('$U_FIN','fin@t'),('$U_AUD','aud@t'),('$U_ENG2','eng2@t');
insert into public.usuarios (id, nome, email, perfil) values
 ('$U_ADM','Adm','adm@t','ADMINISTRADOR'),('$U_DIR','Dir','dir@t','DIRETOR'),('$U_ENG','Eng','eng@t','ENGENHARIA'),
 ('$U_COM','Com','com@t','COMERCIAL'),('$U_FIN','Fin','fin@t','FINANCEIRO'),('$U_AUD','Aud','aud@t','AUDITOR'),
 ('$U_ENG2','Eng2','eng2@t','ENGENHARIA');
insert into public.cidades_infra (id, nome, uf, codigo_ibge, km_rede) values
 ('$C_JSR','Jussara','PR','4112900', 12.5), ('$C_AND','Andira','PR', null, 8);
insert into public.infra_postes (id, cidade_id, identificacao, proprietario_terceiro, quantidade, custo_mensal) values
 ('77777777-0000-0000-0000-000000000001','$C_JSR','JSR-LOTE-A','COPEL',3,20.16);
-- Gerador de itens no formato que a API envia (somente teste).
create schema teste;
create function teste.itens(p_ini int, p_fim int, p_desloca_m jsonb default '{}', p_situacao jsonb default '{}', p_objectid_base int default 0)
returns jsonb language sql as \$\$
  select jsonb_agg(jsonb_build_object(
           'linha', k - p_ini,
           'id_externo', (100000 + k)::text,
           'lon', -52.47 + (k % 40) * 0.0005,
           'lat', -23.67 + (k / 40) * 0.0005 + coalesce((p_desloca_m ->> (100000 + k)::text)::float8, 0) / 111320.0,
           'situacao', coalesce(p_situacao ->> (100000 + k)::text, 'Disponível'),
           'atributos', jsonb_build_object('num_seq_geo', (100000 + k)::text, 'situacao', coalesce(p_situacao ->> (100000 + k)::text, 'Disponível'),
                                           'indic_ps_particular', 'N', 'objectid', p_objectid_base + k + 1)) order by k)
  from generate_series(p_ini, p_fim) k
\$\$;
create function teste.meta(p_ibge text, p_nome text, p_coletado text, p_total int) returns jsonb language sql as \$\$
  select jsonb_build_object('formato','optimap-referencia-postes/1','fonte','COPEL_MAPA_PUBLICO','coletor','coletar_copel/1.0',
    'coletado_em', p_coletado, 'municipio', jsonb_build_object('ibge', p_ibge, 'nome', p_nome, 'uf', 'PR'), 'total', p_total)
\$\$;
grant usage on schema teste to authenticated, anon; grant execute on all functions in schema teste to authenticated, anon;
select 'ok';")
expect_eq "T00 fixture (7 usuários, 2 cidades, lote infra_postes, gerador de teste)" "$(echo "$FIX" | tail -1)" "ok"

H1=$(printf 'a%.0s' {1..64}); H2=$(printf 'b%.0s' {1..64}); H3=$(printf 'c%.0s' {1..64}); H4=$(printf 'd%.0s' {1..64})
OFICIAIS_SQL="select md5(string_agg(x,'|' order by x)) from (
  select 'c'||to_jsonb(c)::text x from public.cidades_infra c union all select 'p'||to_jsonb(p)::text from public.infra_postes p
  union all select 'cf'||to_jsonb(cf)::text from public.contrato_fibras cf union all select 's'||to_jsonb(s)::text from public.infra_segmentos s) z;"
OFICIAIS_ANTES=$(SQL "$OFICIAIS_SQL")

echo "== 1. Recebimento e permissões =="
expect_err "T01 COMERCIAL não inicia importação" "$(AS $U_COM "select optimap_importacao_iniciar(teste.meta('4112900','Jussara','2026-10-20T12:00:00Z',1005),'a.geojson','$H1')")" "OPTIMAP_SEM_PERMISSAO"
expect_err "T02 FINANCEIRO não inicia importação" "$(AS $U_FIN "select optimap_importacao_iniciar(teste.meta('4112900','Jussara','2026-10-20T12:00:00Z',1005),'a.geojson','$H1')")" "OPTIMAP_SEM_PERMISSAO"
expect_err "T03 anon não executa nenhuma função de importação" "$(ANON "select optimap_importacao_listar()")" "permission denied"
expect_err "T04 formato desconhecido é recusado" "$(AS $U_ENG "select optimap_importacao_iniciar(teste.meta('4112900','Jussara','2026-10-20T12:00:00Z',1) || '{\"formato\":\"x\"}','a.geojson','$H1')")" "OPTIMAP_ARQUIVO_INVALIDO"
expect_err "T05 fonte PRÓPRIA não entra como referência externa" "$(AS $U_ENG "select optimap_importacao_iniciar(teste.meta('4112900','Jussara','2026-10-20T12:00:00Z',1) || '{\"fonte\":\"NICK_PROJETO\"}','a.geojson','$H1')")" "OPTIMAP_FONTE_INVALIDA"
expect_err "T06 data de coleta no futuro é recusada" "$(AS $U_ENG "select optimap_importacao_iniciar(teste.meta('4112900','Jussara','2099-01-01T00:00:00Z',1),'a.geojson','$H1')")" "OPTIMAP_ARQUIVO_INVALIDO"

I1=$(AS $U_ENG "select optimap_importacao_iniciar(teste.meta('4112900','Jussara','2026-10-20T12:00:00Z',1005),'copel_4112900_jussara_2026-10-20.geojson','$H1', 123456)")
expect_eq "T07 ENGENHARIA inicia: RECEBIDA, cidade casada pelo IBGE, auditoria IMPORT_RECEIVE" \
  "$(SQL "select status||'/'||(cidade_id='$C_JSR')||'/'||(select count(*) from auditoria where entidade_id=i.id and acao='IMPORT_RECEIVE') from staging.gis_importacoes i where id='$I1'")" "RECEBIDA/true/1"
expect_err "T08 segunda importação aberta do mesmo município é bloqueada" "$(AS $U_ADM "select optimap_importacao_iniciar(teste.meta('4112900','Jussara','2026-10-20T12:00:00Z',1),'b.geojson','$H2')")" "OPTIMAP_IMPORTACAO_EM_ABERTO"
IA=$(AS $U_ENG "select optimap_importacao_iniciar(teste.meta('4101101','Andirá','2026-10-20T12:00:00Z',1),'andira.geojson','$H2')")
expect_eq "T09 cidade sem código IBGE casada por nome+UF sem acento (Andirá ↔ Andira)" "$(SQL "select cidade_id from staging.gis_importacoes where id='$IA'")" "$C_AND"
AS $U_ENG "select optimap_importacao_descartar('$IA','teste')" >/dev/null

echo "== 2. Carga dos itens =="
expect_err "T10 outra ENGENHARIA não carrega itens na importação alheia" "$(AS $U_ENG2 "select optimap_importacao_adicionar_itens('$I1', teste.itens(0,10))")" "OPTIMAP_SEM_PERMISSAO"
expect_err "T11 lote acima de 2000 itens é recusado" "$(AS $U_ENG "select optimap_importacao_adicionar_itens('$I1', teste.itens(0,2000))")" "máximo 2000"
R=$(AS $U_ENG "select optimap_importacao_adicionar_itens('$I1', teste.itens(0,999))")
R=$(AS $U_ENG "select optimap_importacao_adicionar_itens('$I1', '[
  {\"linha\":1000,\"id_externo\":\"\",\"lon\":-52.4,\"lat\":-23.6,\"situacao\":\"Disponível\"},
  {\"linha\":1001,\"id_externo\":\"200001\",\"lon\":null,\"lat\":-23.6},
  {\"linha\":1002,\"id_externo\":\"200002\",\"lon\":10,\"lat\":10},
  {\"linha\":1003,\"id_externo\":\"100005\",\"lon\":-52.4675,\"lat\":-23.67,\"situacao\":\"Disponível\"},
  {\"linha\":1004,\"id_externo\":\"200003\",\"lon\":-52.465003,\"lat\":-23.67,\"situacao\":\"Disponível\"}]'::jsonb)")
expect_eq "T12 itens carregados em lotes (1000 + 5 especiais)" "$R" "1005"
expect_err "T13 reenvio do mesmo lote (linhas repetidas) é recusado" "$(AS $U_ENG "select optimap_importacao_adicionar_itens('$I1', teste.itens(0,5))")" "linha repetida"
expect_eq "T14 nada gravado em gis_postes_referencia antes da aprovação" "$(SQL "select count(*) from gis_postes_referencia")" "0"

echo "== 3. Prévia (importação inicial) =="
RES=$(AS $U_ENG "select optimap_importacao_processar('$I1')")
expect_eq "T15 classificação: 1001 NOVO, 3 INVALIDO, 1 DUPLICADO" \
  "$(SQL "select string_agg(classificacao||'='||n, ',' order by classificacao) from (select classificacao, count(*) n from staging.gis_importacao_itens where importacao_id='$I1' group by 1) x")" \
  "DUPLICADO=1,INVALIDO=3,NOVO=1001"
expect_eq "T16 motivos dos inválidos (sem número, sem coordenada, fora do Brasil)" \
  "$(SQL "select string_agg(motivo, ',' order by linha) from staging.gis_importacao_itens where importacao_id='$I1' and classificacao='INVALIDO'")" \
  "SEM_NUMERO_DO_POSTE,SEM_COORDENADA,COORDENADA_INVALIDA"
expect_eq "T17 coordenada próxima NÃO une postes: 200003 (0,3 m do 100010) é NOVO com alerta" \
  "$(SQL "select classificacao||'/'||(alertas->0->>'tipo')||'/'||(alertas->0->>'id_externo') from staging.gis_importacao_itens where importacao_id='$I1' and id_externo='200003'")" \
  "NOVO/POSTE_PROXIMO_COM_OUTRO_NUMERO/100010"
expect_eq "T18 status PREVIA, pode aprovar, auditoria IMPORT_PREVIEW_READY" \
  "$(SQL "select status||'/'||(resumo->>'pode_aprovar')||'/'||(select count(*) from auditoria where entidade_id=i.id and acao='IMPORT_PREVIEW_READY') from staging.gis_importacoes i where id='$I1'")" "PREVIA/true/1"
expect_eq "T19 RLS: dona vê, outra ENGENHARIA e COMERCIAL não veem, DIRETOR vê" \
  "$(AS $U_ENG "select jsonb_array_length(optimap_importacao_listar())")/$(AS $U_ENG2 "select jsonb_array_length(optimap_importacao_listar())")/$(AS $U_COM "select jsonb_array_length(optimap_importacao_listar())")/$(AS $U_DIR "select jsonb_array_length(optimap_importacao_listar())")" \
  "2/0/0/2"
expect_eq "T20 itens paginados e filtrados + GeoJSON da prévia" \
  "$(AS $U_ENG "select (optimap_importacao_itens('$I1','NOVO',null,10,0)->>'total')||'/'||jsonb_array_length(optimap_importacao_itens('$I1','NOVO',null,10,0)->'itens')||'/'||jsonb_array_length(optimap_importacao_previa_geojson('$I1')->'features')")" \
  "1001/10/1004"
expect_err "T21 escrita direta no staging é negada (só via funções)" "$(AS $U_ADM "update staging.gis_importacao_itens set classificacao='NOVO' where importacao_id='$I1'")" "permission denied"
expect_err "T22 ENGENHARIA não aprova" "$(AS $U_ENG "select optimap_importacao_aprovar('$I1')")" "OPTIMAP_SEM_PERMISSAO"

echo "== 4. Aprovação =="
RES=$(AS $U_DIR "select optimap_importacao_aprovar('$I1', false, 'piloto Jussara')")
expect_eq "T23 DIRETOR aprova: 1001 inseridos" "$(echo "$RES" | python3 -c 'import json,sys; print(json.load(sys.stdin)["inseridos"])')" "1001"
expect_eq "T24 postes gravados como referência CONFIRMADO, com município, cidade e lote de importação" \
  "$(SQL "select count(*)||'/'||count(*) filter (where estado_sincronizacao='CONFIRMADO' and codigo_ibge='4112900' and cidade_id='$C_JSR' and ultima_importacao_id='$I1' and data_referencia='2026-10-20T12:00:00Z') from gis_postes_referencia")" "1001/1001"
expect_eq "T25 log: 1001 INSERT; auditoria IMPORT_APPROVE + IMPORT_APPLY" \
  "$(SQL "select (select count(*) from staging.gis_importacao_alteracoes where importacao_id='$I1' and operacao='INSERT')||'/'||(select count(*) from auditoria where entidade_id='$I1' and acao in ('IMPORT_APPROVE','IMPORT_APPLY'))")" "1001/2"
expect_eq "T26 nenhum poste da NICK criado (externo nunca vira rede própria)" "$(SQL "select count(*) from gis_postes")" "0"
expect_err "T27 aprovar de novo é recusado" "$(AS $U_DIR "select optimap_importacao_aprovar('$I1')")" "OPTIMAP_ESTADO_INVALIDO"

echo "== 5. Reimportação com alterações, conflitos e ausências =="
P4=$(SQL "select id from gis_postes_referencia where id_externo='100004'")
AS $U_ENG "select optimap_promover_poste_referencia('$P4')" >/dev/null
SQL "update gis_postes_referencia set estado_sincronizacao='EXCLUIDO_PELA_FONTE' where id_externo='100007';
     update gis_postes_referencia set codigo_ibge='4105508' where id_externo='100008';" >/dev/null
I2=$(AS $U_ENG "select optimap_importacao_iniciar(teste.meta('4112900','Jussara','2026-10-21T12:00:00Z',901),'copel_4112900_jussara_2026-10-21.geojson','$H3')")
AS $U_ENG "select optimap_importacao_adicionar_itens('$I2', teste.itens(0,899,'{\"100002\":3,\"100003\":50,\"100004\":10}','{\"100001\":\"Ocupado\"}', 500000))" >/dev/null
AS $U_ENG "select optimap_importacao_adicionar_itens('$I2', '[{\"linha\":900,\"id_externo\":\"300000\",\"lon\":-52.44,\"lat\":-23.64,\"situacao\":\"Disponível\"}]')" >/dev/null
RES=$(AS $U_ENG "select optimap_importacao_processar('$I2')")
expect_eq "T28 classificação: 1 NOVO, 2 ATUALIZADO, 894 SEM_ALTERACAO, 4 CONFLITO, 101 AUSENTE" \
  "$(SQL "select string_agg(classificacao||'='||n, ',' order by classificacao) from (select classificacao, count(*) n from staging.gis_importacao_itens where importacao_id='$I2' group by 1) x")" \
  "ATUALIZADO=2,AUSENTE=101,CONFLITO=4,NOVO=1,SEM_ALTERACAO=894"
expect_eq "T29 motivos de conflito (50 m; 10 m com poste NICK; reapareceu; outro município)" \
  "$(SQL "select string_agg(id_externo||':'||motivo, ',' order by id_externo) from staging.gis_importacao_itens where importacao_id='$I2' and classificacao='CONFLITO'")" \
  "100003:DESLOCAMENTO_GRANDE,100004:DESLOCADO_COM_POSTE_NICK,100007:REAPARECEU_APOS_EXCLUSAO,100008:MUNICIPIO_DIFERENTE"
expect_eq "T30 diferenças registradas (situação 100001; posição 3 m no 100002) e objectid ignorado" \
  "$(SQL "select (select diffs->'situacao_fonte'->>'novo' from staging.gis_importacao_itens where importacao_id='$I2' and id_externo='100001')||'/'||(select round((diffs->'posicao'->>'distancia_m')::numeric) from staging.gis_importacao_itens where importacao_id='$I2' and id_externo='100002')||'/'||(select classificacao from staging.gis_importacao_itens where importacao_id='$I2' and id_externo='100006')")" \
  "Ocupado/3/SEM_ALTERACAO"
expect_eq "T31 ausentes são exatamente os 100 números que sumiram (100900..100999) + 200003" \
  "$(SQL "select count(*) from staging.gis_importacao_itens where importacao_id='$I2' and classificacao='AUSENTE' and (id_externo between '100900' and '100999' or id_externo='200003')")" "101"
expect_err "T32 aprovação bloqueada com conflitos sem decisão" "$(AS $U_DIR "select optimap_importacao_aprovar('$I2')")" "OPTIMAP_IMPORTACAO_BLOQUEADA"
ITS=$(SQL "select string_agg(id::text, ',') from staging.gis_importacao_itens where importacao_id='$I2' and id_externo in ('100003','100007')")
ITI=$(SQL "select string_agg(id::text, ',') from staging.gis_importacao_itens where importacao_id='$I2' and id_externo in ('100004','100008')")
ITN=$(SQL "select id from staging.gis_importacao_itens where importacao_id='$I2' and id_externo='300000'")
expect_err "T33 decisão só vale para itens em CONFLITO" "$(AS $U_ENG "select optimap_importacao_decidir('$I2', array[$ITN]::bigint[], 'APLICAR')")" "só itens em CONFLITO"
AS $U_ENG "select optimap_importacao_decidir('$I2', array[$ITS]::bigint[], 'APLICAR')" >/dev/null
R=$(AS $U_DIR "select optimap_importacao_decidir('$I2', array[$ITI]::bigint[], 'IGNORAR')")
expect_eq "T34 decisões registradas (ENGENHARIA e DIRETOR); sem pendências" "$(echo "$R" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["resumo"]["conflitos_pendentes"], d["resumo"]["pode_aprovar"])')" "0 True"

# Cadastro muda depois da prévia (edição direta de ADMINISTRADOR): a aprovação não pode usar prévia velha.
SQL "update gis_postes_referencia set situacao_fonte='X' where id_externo='100010'" >/dev/null
expect_err "T35 cadastro alterado após a prévia → OPTIMAP_PREVIA_DESATUALIZADA (nada gravado)" "$(AS $U_DIR "select optimap_importacao_aprovar('$I2')")" "OPTIMAP_PREVIA_DESATUALIZADA"
expect_eq "T36 ...e nada foi aplicado (300000 não existe; status PREVIA)" \
  "$(SQL "select (select count(*) from gis_postes_referencia where id_externo='300000')||'/'||(select status from staging.gis_importacoes where id='$I2')")" "0/PREVIA"
AS $U_ENG "select optimap_importacao_processar('$I2')" >/dev/null
expect_eq "T37 reprocessar mantém as decisões dos mesmos conflitos" \
  "$(SQL "select count(*) filter (where decisao is not null)||'/'||(select classificacao from staging.gis_importacao_itens where importacao_id='$I2' and id_externo='100010') from staging.gis_importacao_itens where importacao_id='$I2' and classificacao='CONFLITO'")" "4/ATUALIZADO"

RES=$(AS $U_ADM "select optimap_importacao_aprovar('$I2')")
expect_eq "T38 aplicado: 1 inserido, 5 atualizados (2+100010+2 APLICAR), 101 não localizados, 2 ignorados" \
  "$(echo "$RES" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["inseridos"], d["atualizados"], d["nao_localizados"], d["conflitos_ignorados"])')" "1 5 101 2"
expect_eq "T39 ausentes NÃO apagados: 1002 postes, 101 NAO_LOCALIZADO_ULTIMA_COLETA" \
  "$(SQL "select count(*)||'/'||count(*) filter (where estado_sincronizacao='NAO_LOCALIZADO_ULTIMA_COLETA') from gis_postes_referencia")" "1002/101"
expect_eq "T40 conflito APLICAR moveu 100003; IGNORAR manteve 100004 e o poste NICK não mudou" \
  "$(SQL "select (select round(ST_Distance(r.geom::geography, ST_SetSRID(ST_MakePoint(-52.4685,-23.67),4326)::geography)::numeric) from gis_postes_referencia r where id_externo='100003')||'/'||(select ST_Equals(r.geom, p.geom) from gis_postes_referencia r join gis_postes p on p.poste_referencia_id=r.id where r.id_externo='100004')")" "50/true"
expect_eq "T41 estados: 100001 ATUALIZADO, 100007 reapareceu→ATUALIZADO, 100006 CONFIRMADO; 100008 intocado" \
  "$(SQL "select string_agg(id_externo||':'||estado_sincronizacao||':'||coalesce(codigo_ibge,''), ',' order by id_externo) from gis_postes_referencia where id_externo in ('100001','100006','100007','100008')")" \
  "100001:ATUALIZADO:4112900,100006:CONFIRMADO:4112900,100007:ATUALIZADO:4112900,100008:CONFIRMADO:4105508"
expect_eq "T42 log guarda só o que mudou (100001: situação, atributos, datas, estado, importação)" \
  "$(SQL "select string_agg(k, ',' order by k) from staging.gis_importacao_alteracoes a, jsonb_object_keys(a.valor_anterior) k where a.importacao_id='$I2' and a.id_externo='100001'")" \
  "atributos_fonte,data_referencia,estado_sincronizacao,situacao_fonte,ultima_coleta_em,ultima_importacao_id"

echo "== 6. Bloqueios: coleta antiga, ausência em massa, rejeição, descarte =="
I3=$(AS $U_ENG "select optimap_importacao_iniciar(teste.meta('4112900','Jussara','2026-10-19T12:00:00Z',10),'antigo.geojson','$H4')")
AS $U_ENG "select optimap_importacao_adicionar_itens('$I3', teste.itens(0,9))" >/dev/null
RES=$(AS $U_ENG "select optimap_importacao_processar('$I3')")
expect_eq "T43 coleta mais antiga que a última aplicada bloqueia (e o 100003 volta a conflitar); ausência em massa exige confirmação" \
  "$(echo "$RES" | python3 -c 'import json,sys; d=json.load(sys.stdin); print([b["codigo"] for b in d["bloqueios"]], [a["codigo"] for a in d["avisos"]], d["pode_aprovar"])')" \
  "['CONFLITOS_SEM_DECISAO', 'COLETA_MAIS_ANTIGA_QUE_A_ULTIMA_IMPORTADA'] ['AUSENCIA_EM_MASSA'] False"
expect_err "T44 aprovação bloqueada" "$(AS $U_ADM "select optimap_importacao_aprovar('$I3', true)")" "OPTIMAP_IMPORTACAO_BLOQUEADA"
expect_err "T45 rejeição exige motivo" "$(AS $U_DIR "select optimap_importacao_rejeitar('$I3', '')")" "OPTIMAP_MOTIVO_OBRIGATORIO"
AS $U_DIR "select optimap_importacao_rejeitar('$I3', 'coleta antiga')" >/dev/null
expect_eq "T46 REJEITADA com auditoria IMPORT_REJECT" "$(SQL "select status||'/'||(select count(*) from auditoria where entidade_id='$I3' and acao='IMPORT_REJECT') from staging.gis_importacoes where id='$I3'")" "REJEITADA/1"
I4=$(AS $U_ENG "select optimap_importacao_iniciar(teste.meta('4112900','Jussara','2026-10-22T12:00:00Z',100),'parcial.geojson','$H4')")
AS $U_ENG "select optimap_importacao_adicionar_itens('$I4', teste.itens(20,119))" >/dev/null
AS $U_ENG "select optimap_importacao_processar('$I4')" >/dev/null
expect_err "T47 ausência em massa sem confirmação explícita → OPTIMAP_CONFIRMAR_AUSENCIAS" "$(AS $U_ADM "select optimap_importacao_aprovar('$I4')")" "OPTIMAP_CONFIRMAR_AUSENCIAS"
expect_err "T48 DIRETOR não descarta (só quem enviou ou ADMINISTRADOR)" "$(AS $U_DIR "select optimap_importacao_descartar('$I4')")" "OPTIMAP_SEM_PERMISSAO"
AS $U_ENG "select optimap_importacao_descartar('$I4', 'coleta incompleta')" >/dev/null
expect_eq "T49 DESCARTADA; nada aplicado (ainda 101 não localizados)" \
  "$(SQL "select (select status from staging.gis_importacoes where id='$I4')||'/'||count(*) filter (where estado_sincronizacao='NAO_LOCALIZADO_ULTIMA_COLETA') from gis_postes_referencia")" "DESCARTADA/101"

echo "== 7. Reversão seletiva =="
expect_err "T50 DIRETOR não reverte (só ADMINISTRADOR)" "$(AS $U_DIR "select optimap_importacao_reverter('$I1','x')")" "OPTIMAP_SEM_PERMISSAO"
expect_err "T51 reversão exige motivo" "$(AS $U_ADM "select optimap_importacao_reverter('$I1','')")" "OPTIMAP_MOTIVO_OBRIGATORIO"
RES=$(AS $U_ADM "select optimap_importacao_reverter('$I1','teste de reversão com importação posterior')")
expect_eq "T52 reverter a 1ª com a 2ª aplicada: nada que a 2ª tocou é desfeito (parcial)" \
  "$(echo "$RES" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d["revertidas_agora"], sorted(d["motivos"].items()))')" \
  "REVERTIDA_PARCIALMENTE 0 [('ALTERADO_MANUALMENTE_DEPOIS', 1), ('ALTERADO_POR_IMPORTACAO_POSTERIOR', 999), ('PROMOVIDO_A_POSTE_NICK', 1)]"
expect_eq "T53 ...e o cadastro continua com 1002 postes" "$(SQL "select count(*) from gis_postes_referencia")" "1002"
RES=$(AS $U_ADM "select optimap_importacao_reverter('$I2','coleta com problema')")
expect_eq "T54 reverter a 2ª: 100% desfeito" "$(echo "$RES" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d["pendentes"])')" "REVERTIDA 0"
expect_eq "T55 estado anterior restaurado (300000 removido; 100003 posição; 100001 situação; 100007 EXCLUIDO; ausentes CONFIRMADO)" \
  "$(SQL "select (select count(*) from gis_postes_referencia where id_externo='300000')||'/'||(select round(ST_Distance(geom::geography, ST_SetSRID(ST_MakePoint(-52.4685,-23.67),4326)::geography)::numeric) from gis_postes_referencia where id_externo='100003')||'/'||(select situacao_fonte from gis_postes_referencia where id_externo='100001')||'/'||(select estado_sincronizacao from gis_postes_referencia where id_externo='100007')||'/'||(select count(*) from gis_postes_referencia where estado_sincronizacao='NAO_LOCALIZADO_ULTIMA_COLETA')||'/'||(select count(*) from gis_postes_referencia where ultima_importacao_id='$I1')")" \
  "0/0/Disponível/EXCLUIDO_PELA_FONTE/0/1001"
expect_eq "T56 auditoria IMPORT_REVERT_PARTIAL (1ª) e IMPORT_REVERT (2ª)" \
  "$(SQL "select string_agg(acao, ',' order by criado_em) from auditoria where acao like 'IMPORT_REVERT%'")" "IMPORT_REVERT_PARTIAL,IMPORT_REVERT"
RES=$(AS $U_ADM "select optimap_importacao_reverter('$I1','nova tentativa após reverter a 2ª')")
expect_eq "T57 nova tentativa na 1ª: só ficam o poste promovido e os editados à mão" \
  "$(echo "$RES" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"], d["revertidas_agora"], sorted(d["motivos"].items()))')" \
  "REVERTIDA_PARCIALMENTE 997 [('ALTERADO_MANUALMENTE_DEPOIS', 3), ('PROMOVIDO_A_POSTE_NICK', 1)]"
expect_eq "T58 restam exatamente esses 4 postes; poste NICK intacto" \
  "$(SQL "select string_agg(id_externo, ',' order by id_externo) from gis_postes_referencia")/$(SQL "select count(*) from gis_postes where removido_em is null")" \
  "100004,100007,100008,100010/1"

echo "== 8. Imutabilidade, auditoria e preservação =="
expect_err "T59 log de alterações é imutável" "$(SQL "update staging.gis_importacao_alteracoes set valor_novo='{}' where importacao_id='$I1'")" "só os campos de reversão"
expect_err "T60 log de alterações não pode ser apagado" "$(SQL "delete from staging.gis_importacao_alteracoes where importacao_id='$I1'")" "ERROR"
expect_err "T61 importação não pode ser apagada" "$(SQL "delete from staging.gis_importacoes where id='$I3'")" "ERROR"
expect_eq "T62 tabelas oficiais (cidades_infra, infra_postes, infra_segmentos, contrato_fibras) intactas" "$(SQL "$OFICIAIS_SQL")" "$OFICIAIS_ANTES"
expect_eq "T63 auditoria registrou o ciclo completo (eventos IMPORT_* por tipo)" \
  "$(SQL "select string_agg(acao||'='||n, ',' order by acao) from (select acao, count(*) n from auditoria where entidade='gis_importacoes' group by 1) x")" \
  "IMPORT_APPLY=2,IMPORT_APPROVE=2,IMPORT_DISCARD=2,IMPORT_PREVIEW_READY=5,IMPORT_RECEIVE=5,IMPORT_REJECT=1,IMPORT_REVERT=1,IMPORT_REVERT_PARTIAL=2"

echo "== 9. Escala de uma cidade real (15 mil postes) =="
I5=$(AS $U_ENG "select optimap_importacao_iniciar(teste.meta('4105508','Cianorte','2026-10-22T12:00:00Z',15000),'cianorte.geojson','$H4')")
t0=$(ms); for s in 0 2000 4000 6000 8000 10000 12000 14000; do e=$((s+1999)); [ $e -gt 14999 ] && e=14999
  AS $U_ENG "select optimap_importacao_adicionar_itens('$I5', (select jsonb_agg(x || jsonb_build_object('linha', (x->>'linha')::int + $s, 'id_externo', (500000 + (x->>'linha')::int + $s)::text)) from jsonb_array_elements(teste.itens($s,$e)) x))" >/dev/null; done; t1=$(ms)
AS $U_ENG "select optimap_importacao_processar('$I5')" >/dev/null; t2=$(ms)
RES=$(AS $U_ADM "select optimap_importacao_aprovar('$I5')"); t3=$(ms)
echo "      carga 15 mil: $((t1-t0)) ms | prévia: $((t2-t1)) ms | aprovação: $((t3-t2)) ms"
expect_eq "T64 15 mil postes inseridos" "$(echo "$RES" | python3 -c 'import json,sys; print(json.load(sys.stdin)["inseridos"])')" "15000"
[ $((t2-t1)) -lt 15000 ] && [ $((t3-t2)) -lt 15000 ] && pass "T65 prévia e aprovação de 15 mil postes < 15 s cada" || fail "T65 desempenho" "prévia $((t2-t1)) ms, aprovação $((t3-t2)) ms"
t4=$(ms); RES=$(AS $U_ADM "select optimap_importacao_reverter('$I5','teste de desempenho')"); t5=$(ms)
echo "      reversão 15 mil: $((t5-t4)) ms"
expect_eq "T66 reversão de 15 mil postes completa" "$(echo "$RES" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" "REVERTIDA"
echo "      espaço do staging após os testes: $(SQL "select pg_size_pretty(sum(pg_total_relation_size(c.oid))) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='staging' and c.relkind='r' and c.relname like 'gis_%'")"

echo
echo "================================================================"
echo "Resultado: $PASS PASS / $FAIL FAIL"
for f in "${FAILED[@]}"; do echo "  - $f"; done
[ "$FAIL" -eq 0 ]
