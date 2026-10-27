#!/usr/bin/env bash
# OptiMon — OptiMap Fase 5 (empresas, ocupações, lista do CES e cores do mapa): suíte SQL.
#
# Reconstrói o banco do zero (bootstrap_sandbox.sh) e valida: cadastro de empresas,
# marcação "ocupado sem projeto" pela engenharia, importação da lista do CES (prévia,
# aprovação, reimportação com ausências, reversão seletiva), duas empresas no mesmo poste,
# categoria/empresas no tile, permissões, RLS e preservação das tabelas oficiais.
# NUNCA rode contra o Supabase real.
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

echo "== 0. Sandbox =="
bash tests/optimap/bootstrap_sandbox.sh | tail -1

U_ADM=11111111-0000-0000-0000-000000000001; U_DIR=11111111-0000-0000-0000-000000000002
U_ENG=11111111-0000-0000-0000-000000000003; U_COM=11111111-0000-0000-0000-000000000004
U_AUD=11111111-0000-0000-0000-000000000006; U_ENG2=11111111-0000-0000-0000-000000000007
C_CIA=22222222-0000-0000-0000-000000000001
E_NICK=$(SQL "select id from gis_empresas where cnpj='08930086000163'")
E_AYO=$(SQL "select id from gis_empresas where cnpj='30353855000167'")

FIX=$(SQL "
insert into auth.users (id, email) values ('$U_ADM','adm@t'),('$U_DIR','dir@t'),('$U_ENG','eng@t'),('$U_COM','com@t'),('$U_AUD','aud@t'),('$U_ENG2','eng2@t');
insert into public.usuarios (id, nome, email, perfil) values
 ('$U_ADM','Adm','adm@t','ADMINISTRADOR'),('$U_DIR','Dir','dir@t','DIRETOR'),('$U_ENG','Eng','eng@t','ENGENHARIA'),
 ('$U_COM','Com','com@t','COMERCIAL'),('$U_AUD','Aud','aud@t','AUDITOR'),('$U_ENG2','Eng2','eng2@t','ENGENHARIA');
insert into public.cidades_infra (id, nome, uf, codigo_ibge, km_rede) values ('$C_CIA','Cianorte','PR','4105508', 30);
insert into public.infra_postes (id, cidade_id, identificacao, proprietario_terceiro, quantidade, custo_mensal) values
 ('77777777-0000-0000-0000-000000000001','$C_CIA','CIA-LOTE-A','COPEL',150,20.16);
-- 200 postes de referência da Copel (mapa público): 300000..300199, situações variadas.
insert into public.gis_postes_referencia (fonte_id, id_externo, geom, cidade_id, codigo_ibge, situacao_fonte, data_referencia)
select (select id from gis_fontes where codigo='COPEL_MAPA_PUBLICO'), (300000+k)::text,
       ST_SetSRID(ST_MakePoint(-52.6 + (k%20)*0.0005, -23.65 + (k/20)*0.0005), 4326), '$C_CIA', '4105508',
       case k % 4 when 0 then 'Disponível' when 1 then 'Indisponível' when 2 then 'Possível disponibilidade' else 'Disponível' end,
       now() - interval '5 days'
  from generate_series(0,199) k;
create schema teste;
-- itens no formato que a API envia: ids 300000+k (k em [ini,fim]); fora_mapa = ids 900000+ sem referência.
create function teste.itens(p_ini int, p_fim int, p_extra int default 0) returns jsonb language sql as \$\$
  select jsonb_agg(x order by (x->>'linha')::int) from (
    select jsonb_build_object('linha', k - p_ini, 'id_externo', (300000+k)::text,
             'lon', -52.6 + (k%20)*0.0005 + 0.00001, 'lat', -23.65 + (k/20)*0.0005) x from generate_series(p_ini, p_fim) k
    union all
    select jsonb_build_object('linha', p_fim - p_ini + j, 'id_externo', (900000+j)::text, 'lon', -52.7, 'lat', -23.7)
      from generate_series(1, p_extra) j) z
\$\$;
create function teste.meta(p_cnpj text, p_coletado text, p_total int) returns jsonb language sql as \$\$
  select jsonb_build_object('formato','optimap-ocupacoes-ces/1','fonte','COPEL_CES','tipo_ocupacao','PROJETO_APROVADO',
    'coletor','ces-navegador/1.0','coletado_em', p_coletado, 'empresa', jsonb_build_object('cnpj', p_cnpj),
    'referencia_ces', jsonb_build_object('total_tabela_consulta_pontos', p_total, 'por_cidade', jsonb_build_object('CIANORTE', p_total)),
    'total', p_total)
\$\$;
grant usage on schema teste to authenticated, anon; grant execute on all functions in schema teste to authenticated, anon;
select 'ok';")
expect_eq "T00 fixture (6 usuários, Cianorte, lote, 200 postes Copel, empresas semeadas)" "$(echo "$FIX" | tail -1)/$( [ -n "$E_NICK" ] && [ -n "$E_AYO" ] && echo 2)" "ok/2"

H1=$(printf 'a%.0s' {1..64}); H2=$(printf 'b%.0s' {1..64}); H3=$(printf 'c%.0s' {1..64}); H4=$(printf 'd%.0s' {1..64})
OFICIAIS_SQL="select md5(string_agg(x,'|' order by x)) from (
  select 'c'||to_jsonb(c)::text x from public.cidades_infra c union all select 'p'||to_jsonb(p)::text from public.infra_postes p
  union all select 'cf'||to_jsonb(cf)::text from public.contrato_fibras cf union all select 's'||to_jsonb(s)::text from public.infra_segmentos s
  union all select 'r'||to_jsonb(r)::text from public.gis_postes_referencia r) z;"
OFICIAIS_ANTES=$(SQL "$OFICIAIS_SQL")
REF() { SQL "select id from gis_postes_referencia where id_externo='$1'"; }

echo "== 1. Empresas =="
expect_eq "T01 empresas semeadas com UC e CNPJ" "$(SQL "select string_agg(coalesce(nome_fantasia,'-')||':'||uc_copel, ',' order by cnpj) from gis_empresas")" "NICK NETWORK:515903403178,AYOTECH:638231603159"
expect_eq "T02 COMERCIAL e AUDITOR veem as empresas" "$(AS $U_COM "select count(*) from gis_empresas")/$(AS $U_AUD "select count(*) from gis_empresas")" "2/2"
expect_err "T03 anon não vê empresas" "$(ANON "select count(*) from gis_empresas")" "permission denied"
expect_err "T04 ENGENHARIA não cadastra empresa" "$(AS $U_ENG "select optimap_empresa_salvar(null,'X LTDA',null,'11222333000181')")" "OPTIMAP_SEM_PERMISSAO"
expect_err "T05 CNPJ inválido" "$(AS $U_ADM "select optimap_empresa_salvar(null,'X LTDA',null,'123')")" "OPTIMAP_PARAMETRO_INVALIDO"
expect_err "T06 CNPJ repetido" "$(AS $U_ADM "select optimap_empresa_salvar(null,'X LTDA',null,'08.930.086/0001-63')")" "já existe empresa"
E_X=$(AS $U_ADM "select optimap_empresa_salvar(null,'TERCEIRA LTDA','TER','11.222.333/0001-81','123','CT-9')")
expect_eq "T07 ADMIN cadastra empresa (máscara limpa)" "$(SQL "select cnpj||'/'||contrato_copel from gis_empresas where id='$E_X'")" "11222333000181/CT-9"
AS $U_ADM "select optimap_empresa_salvar('$E_X','TERCEIRA LTDA','TER','11222333000181','123','CT-9', false)" >/dev/null
expect_eq "T08 edição + auditoria da empresa" "$(SQL "select ativa::text||'/'||(select count(*)>=2 from auditoria where entidade_id='$E_X') from gis_empresas where id='$E_X'")" "false/true"
expect_err "T09 escrita direta em gis_empresas bloqueada (RLS/grant)" "$(AS $U_ADM "update gis_empresas set ativa=true where id='$E_X'")" "permission denied\|row-level\|UPDATE 0"

echo "== 2. Marcação 'ocupado sem projeto' =="
R5=$(REF 300005); R6=$(REF 300006)
expect_err "T10 COMERCIAL não marca" "$(AS $U_COM "select optimap_ocupacao_marcar('$R5','$E_NICK','cabo em campo')")" "OPTIMAP_SEM_PERMISSAO"
expect_err "T11 motivo obrigatório" "$(AS $U_ENG "select optimap_ocupacao_marcar('$R5','$E_NICK','')")" "OPTIMAP_MOTIVO_OBRIGATORIO"
expect_err "T12 empresa inativa recusada" "$(AS $U_ENG "select optimap_ocupacao_marcar('$R5','$E_X','cabo em campo')")" "OPTIMAP_PARAMETRO_INVALIDO"
M5=$(AS $U_ENG "select optimap_ocupacao_marcar('$R5','$E_NICK','cabo existente sem projeto (levantamento 20/10)')")
expect_eq "T13 ENGENHARIA marca SEM_PROJETO (auditada)" "$(SQL "select tipo||'/'||origem||'/'||estado||'/'||(select count(*) from auditoria where entidade_id='$M5') from gis_ocupacoes where id='$M5'")" "SEM_PROJETO/MARCACAO/ATIVA/1"
expect_err "T14 marcação duplicada recusada" "$(AS $U_ENG "select optimap_ocupacao_marcar('$R5','$E_NICK','de novo')")" "OPTIMAP_JA_OCUPADO"
M5A=$(AS $U_ENG "select optimap_ocupacao_marcar('$R5','$E_AYO','cabo da Ayotech')")
expect_eq "T15 outra empresa pode marcar o mesmo poste" "$(SQL "select count(*) from gis_ocupacoes where poste_referencia_id='$R5' and estado='ATIVA'")" "2"
M6=$(AS $U_ENG "select optimap_ocupacao_marcar('$R6','$E_NICK','marcação por engano')")
expect_err "T16 encerrar sem motivo" "$(AS $U_ENG "select optimap_ocupacao_encerrar('$M6','')")" "OPTIMAP_MOTIVO_OBRIGATORIO"
AS $U_ENG "select optimap_ocupacao_encerrar('$M6','marcado no poste errado')" >/dev/null
expect_eq "T17 encerrar mantém histórico" "$(SQL "select estado||'/'||(encerrado_por='$U_ENG')||'/'||motivo_encerramento from gis_ocupacoes where id='$M6'")" "ENCERRADA/true/marcado no poste errado"
expect_err "T18 ninguém apaga marcação" "$(SQL "delete from gis_ocupacoes where id='$M6'")" "OPTIMAP\|não pode\|bloque"
expect_eq "T19 ocupações do poste (painel) listam as 2 empresas" "$(AS $U_COM "select jsonb_array_length(optimap_ocupacoes_do_poste('$R5'))")" "2"

echo "== 3. Lista do CES — recebimento =="
expect_err "T20 COMERCIAL não envia lista" "$(AS $U_COM "select optimap_ces_iniciar(teste.meta('08930086000163','2026-10-20T12:00:00Z',100),'n.geojson','$H1')")" "OPTIMAP_SEM_PERMISSAO"
expect_err "T21 formato errado" "$(AS $U_ENG "select optimap_ces_iniciar(teste.meta('08930086000163','2026-10-20T12:00:00Z',100)||'{\"formato\":\"x\"}','n.geojson','$H1')")" "OPTIMAP_ARQUIVO_INVALIDO"
expect_err "T22 tipo diferente de PROJETO_APROVADO" "$(AS $U_ENG "select optimap_ces_iniciar(teste.meta('08930086000163','2026-10-20T12:00:00Z',100)||'{\"tipo_ocupacao\":\"SEM_PROJETO\"}','n.geojson','$H1')")" "OPTIMAP_ARQUIVO_INVALIDO"
expect_err "T23 empresa não cadastrada" "$(AS $U_ENG "select optimap_ces_iniciar(teste.meta('99999999000199','2026-10-20T12:00:00Z',100),'n.geojson','$H1')")" "OPTIMAP_EMPRESA_NAO_CADASTRADA"
expect_err "T24 coleta no futuro" "$(AS $U_ENG "select optimap_ces_iniciar(teste.meta('08930086000163','2099-01-01T00:00:00Z',100),'n.geojson','$H1')")" "OPTIMAP_ARQUIVO_INVALIDO"
# NICK: postes 300000..300099 (100) + 3 fora do mapa público + 1 duplicado + 1 inválido
I1=$(AS $U_ENG "select optimap_ces_iniciar(teste.meta('08930086000163','2026-10-20T12:00:00Z',105),'ces_nick.geojson','$H1', 1234)")
expect_eq "T25 lista recebida (RECEBIDA, auditoria IMPORT_RECEIVE)" "$(SQL "select status||'/'||(select count(*) from auditoria where entidade_id=i.id and acao='IMPORT_RECEIVE') from staging.gis_ces_importacoes i where id='$I1'")" "RECEBIDA/1"
expect_err "T26 segunda lista em aberto da mesma empresa" "$(AS $U_ENG "select optimap_ces_iniciar(teste.meta('08930086000163','2026-10-21T12:00:00Z',1),'n2.geojson','$H2')")" "OPTIMAP_IMPORTACAO_EM_ABERTO"
AS $U_ENG "select optimap_ces_adicionar_itens('$I1', teste.itens(0,99,3))" >/dev/null
N=$(AS $U_ENG "select optimap_ces_adicionar_itens('$I1', '[{\"linha\":103,\"id_externo\":\"300001\",\"lon\":-52.6,\"lat\":-23.65},{\"linha\":104,\"id_externo\":\"300150\"}]')")
expect_eq "T27 itens recebidos (105)" "$N" "105"
expect_err "T28 ENGENHARIA de outro usuário não mexe" "$(AS $U_ENG2 "select optimap_ces_processar('$I1')")" "OPTIMAP_SEM_PERMISSAO\|OPTIMAP_NAO_ENCONTRADO"
expect_eq "T29 ENGENHARIA alheia não vê a lista (RLS)" "$(AS $U_ENG2 "select count(*) from staging.gis_ces_importacoes")" "0"

echo "== 4. Prévia =="
RES=$(AS $U_ENG "select optimap_ces_processar('$I1')")
expect_eq "T30 contagens da prévia" "$(echo "$RES" | jq -c '.contagens' 2>/dev/null)" '{"NOVA":103,"INVALIDO":1,"DUPLICADO":1}'
expect_eq "T31 alertas: 3 fora do mapa público + 1 marcação a encerrar" "$(echo "$RES" | jq -c '.alertas_por_tipo')" '{"FORA_DO_MAPA_PUBLICO":3,"ENCERRA_MARCACAO_SEM_PROJETO":1}'
expect_eq "T32 pode aprovar, sem bloqueios" "$(echo "$RES" | jq -r '.pode_aprovar')" "true"
RES2=$(AS $U_ENG "select optimap_ces_processar('$I1')")
expect_eq "T33 reprocessar é idempotente" "$(echo "$RES2" | jq -c '.contagens')" '{"NOVA":103,"INVALIDO":1,"DUPLICADO":1}'
expect_eq "T34 nenhuma ocupação criada antes da aprovação" "$(SQL "select count(*) from gis_ocupacoes where origem='CES'")" "0"
expect_eq "T35 itens/detalhe/prévia legíveis por ENGENHARIA dona" \
  "$(AS $U_ENG "select (optimap_ces_itens('$I1','DUPLICADO')->>'total')||'/'||jsonb_array_length(optimap_ces_previa_geojson('$I1')->'features')||'/'||(optimap_ces_detalhe('$I1')->'empresa'->>'uc_copel')")" "1/104/515903403178"

expect_eq "T35b conferência na prévia: 100 da lista em Cianorte × 105 na tabela do CES (antes de aprovar)" "$(AS $U_ENG "select (x->>'na_lista')||'/'||(x->>'tabela_ces')||'/'||(x->>'ativas_optimap') from jsonb_array_elements(optimap_ces_detalhe('$I1')->'conferencia') x where x->>'municipio'='Cianorte'")" "100/105/0"
echo "== 5. Aprovação =="
expect_err "T36 ENGENHARIA não aprova" "$(AS $U_ENG "select optimap_ces_aprovar('$I1')")" "OPTIMAP_SEM_PERMISSAO"
RES=$(AS $U_DIR "select optimap_ces_aprovar('$I1', false, 'lista NICK')")
expect_eq "T37 DIRETOR aprova: 103 novas, 1 marcação encerrada" "$(echo "$RES" | jq -c '{novas,marcacoes_encerradas}')" '{"novas":103,"marcacoes_encerradas":1}'
expect_eq "T38 status IMPORTADA + auditorias APPROVE/APPLY" "$(SQL "select status||'/'||(select count(*) from auditoria where entidade_id=i.id and acao in ('IMPORT_APPROVE','IMPORT_APPLY')) from staging.gis_ces_importacoes i where id='$I1'")" "IMPORTADA/2"
expect_eq "T39 ocupações CES: 100 ligadas ao mapa público, 3 sem referência" "$(SQL "select count(poste_referencia_id)||'/'||count(*) filter (where poste_referencia_id is null) from gis_ocupacoes where origem='CES' and empresa_id='$E_NICK'")" "100/3"
expect_eq "T40 marcação NICK do 300005 encerrada pelo CES; a da AYOTECH continua" "$(SQL "select string_agg(e.nome_fantasia||':'||o.estado, ',' order by e.nome_fantasia) from gis_ocupacoes o join gis_empresas e on e.id=o.empresa_id where o.tipo='SEM_PROJETO' and o.id in ('$M5','$M5A')")" "AYOTECH:ATIVA,NICK NETWORK:ENCERRADA"
expect_err "T41 marcar SEM_PROJETO onde já há projeto aprovado da mesma empresa" "$(AS $U_ENG "select optimap_ocupacao_marcar('$(REF 300010)','$E_NICK','teste')")" "OPTIMAP_JA_OCUPADO"
expect_err "T42 encerrar ocupação vinda do CES é proibido" "$(AS $U_ADM "select optimap_ocupacao_encerrar((select id from gis_ocupacoes where origem='CES' limit 1),'teste')")" "OPTIMAP_ESTADO_INVALIDO"
expect_eq "T43 log: 103 INSERT + 1 UPDATE" "$(SQL "select string_agg(operacao||':'||n, ',' order by operacao) from (select operacao, count(*) n from staging.gis_ces_alteracoes where importacao_id='$I1' group by 1) z")" "INSERT:103,UPDATE:1"
expect_err "T44 log imutável" "$(SQL "update staging.gis_ces_alteracoes set id_externo='x' where importacao_id='$I1'")" "imut\|não pode\|bloque\|OPTIMAP"

echo "== 6. Segunda empresa (AYOTECH) com sobreposição =="
I2=$(AS $U_ENG "select optimap_ces_iniciar(teste.meta('30353855000167','2026-10-20T13:00:00Z',31),'ces_ayo.geojson','$H2')")
AS $U_ENG "select optimap_ces_adicionar_itens('$I2', teste.itens(90,120))" >/dev/null
AS $U_ENG "select optimap_ces_processar('$I2')" >/dev/null
RES=$(AS $U_ADM "select optimap_ces_aprovar('$I2')")
expect_eq "T45 AYOTECH: 31 novas (10 em postes que a NICK também ocupa)" "$(echo "$RES" | jq -r '.novas')/$(SQL "select count(*) from (select poste_referencia_id from gis_ocupacoes where tipo='PROJETO_APROVADO' and estado='ATIVA' group by 1 having count(distinct empresa_id)=2) z")" "31/10"
expect_eq "T46 marcação AYOTECH no 300005 não foi tocada (não está na lista dela)" "$(SQL "select estado from gis_ocupacoes where id='$M5A'")" "ATIVA"

echo "== 7. Tile: categoria e empresas =="
CAT_SQL="select r.id_externo||'='||app.gis_categoria_poste(r.situacao_fonte,
  exists(select 1 from gis_ocupacoes o where o.poste_referencia_id=r.id and o.estado='ATIVA' and o.tipo='PROJETO_APROVADO'),
  exists(select 1 from gis_ocupacoes o where o.poste_referencia_id=r.id and o.estado='ATIVA' and o.tipo='SEM_PROJETO'))
  from gis_postes_referencia r where r.id_externo in"
expect_eq "T47 prioridade de cor" "$(SQL "$CAT_SQL ('300005','300150','300151','300152','300153') order by 1" | tr '\n' ' ')" \
  "300005=PROJETO_APROVADO 300150=POSSIVEL 300151=DISPONIVEL 300152=DISPONIVEL 300153=INDISPONIVEL "
R_SP=$(REF 300160)
AS $U_ENG "select optimap_ocupacao_marcar('$R_SP','$E_AYO','cabo sem projeto')" >/dev/null
expect_eq "T48 SEM_PROJETO vence a situação da Copel" "$(SQL "$CAT_SQL ('300160')")" "300160=SEM_PROJETO"
# tile z16 cobrindo os postes; decodifica pela presença das chaves no MVT
Z=16; X=$(SQL "select floor((-52.598+180)/360*(1<<$Z))::int"); Y=$(SQL "select floor((1-ln(tan(radians(-23.648))+1/cos(radians(-23.648)))/pi())/2*(1<<$Z))::int")
TILE=$(AS $U_COM "select encode(optimap_tile('postes_referencia',$Z,$X,$Y),'escape')" 2>&1)
expect_eq "T49 tile individual tem categoria e empresas" "$(echo "$TILE" | grep -c "categoria" | awk '{print ($1>0)}')$(echo "$TILE" | grep -c "PROJETO_APROVADO" | awk '{print ($1>0)}')$(echo "$TILE" | grep -c "$E_AYO" | awk '{print ($1>0)}')" "111"
TA=$(AS $U_COM "select encode(optimap_tile('postes_referencia',13,$(SQL "select floor((-52.598+180)/360*(1<<13))::int"),$(SQL "select floor((1-ln(tan(radians(-23.648))+1/cos(radians(-23.648)))/pi())/2*(1<<13))::int")),'escape')" 2>&1)
expect_eq "T50 tile agregado tem 'ocupados'" "$(echo "$TA" | grep -c ocupados | awk '{print ($1>0)}')" "1"

echo "== 8. Reimportação NICK com ausências =="
I3=$(AS $U_ENG "select optimap_ces_iniciar(teste.meta('08930086000163','2026-10-25T12:00:00Z',95),'ces_nick2.geojson','$H3')")
AS $U_ENG "select optimap_ces_adicionar_itens('$I3', teste.itens(5,99))" >/dev/null
RES=$(AS $U_ENG "select optimap_ces_processar('$I3')")
expect_eq "T51 prévia: 95 mantidas, 8 ausentes (5 do início + 3 fora do mapa)" "$(echo "$RES" | jq -c '.contagens')" '{"AUSENTE":8,"MANTIDA":95}'
expect_eq "T52 sem aviso de ausência em massa (8 < 20%)" "$(echo "$RES" | jq -r '[.avisos[].codigo]|join(",")')" ""
RES=$(AS $U_ADM "select optimap_ces_aprovar('$I3')")
expect_eq "T53 aplicado: 95 mantidas, 8 não constam (nunca apagadas)" "$(echo "$RES" | jq -c '{mantidas,nao_constam}')/$(SQL "select count(*) from gis_ocupacoes where empresa_id='$E_NICK' and origem='CES'")" '{"mantidas":95,"nao_constam":8}/103'
expect_eq "T54 poste 300001 da NICK: NAO_CONSTA_ULTIMA_LISTA e sai do azul" "$(SQL "select estado from gis_ocupacoes where empresa_id='$E_NICK' and id_externo='300001' and tipo='PROJETO_APROVADO'")/$(SQL "$CAT_SQL ('300001')")" "NAO_CONSTA_ULTIMA_LISTA/300001=INDISPONIVEL"
expect_err "T55 lista mais antiga que a última importada é bloqueada" "$(AS $U_ENG "select optimap_ces_iniciar(teste.meta('08930086000163','2026-10-22T12:00:00Z',1),'velha.geojson','$H4')" >/dev/null; I4=$(SQL "select id from staging.gis_ces_importacoes where arquivo_hash='$H4'"); AS $U_ENG "select optimap_ces_adicionar_itens('$I4', teste.itens(0,0))" >/dev/null; AS $U_ENG "select optimap_ces_processar('$I4')")" "COLETA_MAIS_ANTIGA"
I4=$(SQL "select id from staging.gis_ces_importacoes where arquivo_hash='$H4'")
AS $U_ENG "select optimap_ces_descartar('$I4','teste')" >/dev/null
expect_eq "T56 descartada" "$(SQL "select status from staging.gis_ces_importacoes where id='$I4'")" "DESCARTADA"

expect_eq "T65 conferência Cianorte: 95 ativas × 95 na lista × 95 na tabela do CES × lote de 150 no OptiMon" "$(AS $U_ADM "select x->>'municipio'||'/'||(x->>'ativas_optimap')||'/'||(x->>'na_lista')||'/'||(x->>'tabela_ces')||'/'||(x->>'lote_optimap') from jsonb_array_elements(optimap_ces_conferencia('$E_NICK')) x where x->>'tabela_ces' is not null")" "Cianorte/95/95/95/150"

echo "== 9. Ausência em massa =="
H5=$(printf 'e%.0s' {1..64})
I5=$(AS $U_ENG "select optimap_ces_iniciar(teste.meta('08930086000163','2026-10-26T12:00:00Z',10),'parcial.geojson','$H5')")
AS $U_ENG "select optimap_ces_adicionar_itens('$I5', teste.itens(5,14))" >/dev/null
RES=$(AS $U_ENG "select optimap_ces_processar('$I5')")
expect_eq "T57 aviso AUSENCIA_EM_MASSA exige confirmação" "$(echo "$RES" | jq -r '.avisos[0].codigo+"/"+(.avisos[0].exige_confirmacao|tostring)')" "AUSENCIA_EM_MASSA/true"
expect_err "T58 aprovar sem confirmar" "$(AS $U_ADM "select optimap_ces_aprovar('$I5')")" "OPTIMAP_CONFIRMAR_AUSENCIAS"
AS $U_ADM "select optimap_ces_rejeitar('$I5','coleta incompleta')" >/dev/null
expect_eq "T59 rejeitada com motivo, nada aplicado" "$(SQL "select status from staging.gis_ces_importacoes where id='$I5'")/$(SQL "select count(*) from gis_ocupacoes where empresa_id='$E_NICK' and estado='ATIVA' and origem='CES'")" "REJEITADA/95"

echo "== 10. Reversão =="
expect_err "T60 só ADMIN reverte" "$(AS $U_DIR "select optimap_ces_reverter('$I3','teste')")" "OPTIMAP_SEM_PERMISSAO"
RES=$(AS $U_ADM "select optimap_ces_reverter('$I3','lista 25/10 errada')")
expect_eq "T61 reverter a 2ª lista NICK: tudo volta" "$(echo "$RES" | jq -c '{status,nao_revertidas}')/$(SQL "select count(*) from gis_ocupacoes where empresa_id='$E_NICK' and origem='CES' and estado='ATIVA'")" '{"status":"REVERTIDA","nao_revertidas":0}/103'
# Reverter a 1ª: a ocupação 300050 foi encerrada? não — simula alteração posterior: nova marcação não interfere;
# mas a reversão da 1ª deve apagar as 103 inseridas e reabrir a marcação do 300005.
RES=$(AS $U_ADM "select optimap_ces_reverter('$I1','teste de reversão')")
expect_eq "T62 reverter a 1ª lista: apaga só as ocupações CES dela e reabre a marcação" "$(echo "$RES" | jq -r '.status')/$(SQL "select count(*) from gis_ocupacoes where empresa_id='$E_NICK' and origem='CES'")/$(SQL "select estado from gis_ocupacoes where id='$M5'")" "REVERTIDA/0/ATIVA"
expect_eq "T63 AYOTECH intacta" "$(SQL "select count(*) from gis_ocupacoes where empresa_id='$E_AYO' and origem='CES' and estado='ATIVA'")" "31"
# reversão parcial: muda manualmente uma ocupação da AYOTECH (simula lista posterior) e reverte I2
SQL "update gis_ocupacoes set data_referencia = now() where empresa_id='$E_AYO' and id_externo='300090' and origem='CES'" >/dev/null
RES=$(AS $U_ADM "select optimap_ces_reverter('$I2','teste parcial')")
expect_eq "T64 reversão preserva alteração posterior (parcial)" "$(echo "$RES" | jq -c '{status,nao_revertidas}')/$(SQL "select count(*) from gis_ocupacoes where empresa_id='$E_AYO' and origem='CES'")" '{"status":"REVERTIDA_PARCIALMENTE","nao_revertidas":1}/1'

echo "== 11. Conferência, segurança e preservação =="
expect_err "T66 anon não executa funções CES" "$(ANON "select optimap_ces_listar()")" "permission denied"
expect_err "T67 funções internas não expostas" "$(AS $U_ADM "select app.gis_ces_classificar('$I1')")" "permission denied"
expect_eq "T68 nenhuma escrita direta em gis_ocupacoes por authenticated" "$(AS $U_ADM "insert into gis_ocupacoes (empresa_id,id_externo,geom,tipo,origem,motivo) values ('$E_NICK','1',ST_SetSRID(ST_MakePoint(-52,-23),4326),'SEM_PROJETO','MARCACAO','x')" 2>&1 | grep -c 'permission denied\|row-level')" "1"
expect_eq "T69 tabelas oficiais e postes de referência intactos" "$(SQL "$OFICIAIS_SQL")" "$OFICIAIS_ANTES"
expect_eq "T70 staging CES sem DELETE" "$(SQL "delete from staging.gis_ces_importacoes where id='$I4'" 2>&1 | grep -c -i 'bloque\|não\|proib\|exception\|erro\|error' | awk '{print ($1>0)}')" "1"

echo
echo "== RESULTADO: $PASS passaram, $FAIL falharam =="
[ $FAIL -eq 0 ] || { printf '  - %s\n' "${FAILED[@]}"; exit 1; }
