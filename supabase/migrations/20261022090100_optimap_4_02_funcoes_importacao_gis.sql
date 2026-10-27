-- OptiMon — OptiMap Fase 4 (item 02): funções da importação de postes de referência.
--
-- Fluxo (toda escrita via SECURITY DEFINER com checagem de perfil própria):
--   1. app.gis_importacao_iniciar          ENGENHARIA/ADMINISTRADOR  RECEBIDA   (IMPORT_RECEIVE)
--   2. app.gis_importacao_adicionar_itens  idem (lotes ≤ 2000)       RECEBIDA
--   3. app.gis_importacao_processar        idem                      → PREVIA   (IMPORT_PREVIEW_READY)
--   4. app.gis_importacao_decidir          idem + DIRETOR            conflitos: APLICAR/IGNORAR
--   5. app.gis_importacao_aprovar          ADMINISTRADOR/DIRETOR     → IMPORTADA (IMPORT_APPROVE + IMPORT_APPLY)
--      app.gis_importacao_rejeitar         ADMINISTRADOR/DIRETOR     → REJEITADA (IMPORT_REJECT)
--      app.gis_importacao_descartar        quem enviou/ADMINISTRADOR → DESCARTADA (IMPORT_DISCARD)
--   6. app.gis_importacao_reverter         ADMINISTRADOR             → REVERTIDA[_PARCIALMENTE] (IMPORT_REVERT[_PARTIAL])
--
-- Regras de negócio:
--   * Correspondência SÓ por fonte + id_externo (Copel: num_seq_geo). Coordenada próxima
--     nunca une dois postes — gera no máximo o alerta POSTE_PROXIMO_COM_OUTRO_NUMERO.
--   * Nada é apagado por ausência: poste do município que não veio no arquivo vira
--     NAO_LOCALIZADO_ULTIMA_COLETA. Ausência em massa (> 20% do município) exige confirmação.
--   * Poste externo nunca vira rede da NICK aqui: só gis_postes_referencia é escrita.
--     gis_postes (rede própria) é apenas LIDA para detectar conflito.
--   * Aprovação recalcula a prévia sob lock; se o resultado difere do que foi revisado,
--     aborta (OPTIMAP_PREVIA_DESATUALIZADA) sem gravar nada.
--   * Reversão percorre o log em ordem inversa e só desfaz o que continua exatamente como a
--     importação deixou (não sobrescreve importação posterior nem edição manual); o que não
--     puder ser desfeito fica registrado com o motivo e pode ser tentado de novo depois.

-- ============================================================================
-- 1) Helpers
-- ============================================================================
create or replace function app.gis_normalizar_nome(p text)
returns text
language sql
immutable
parallel safe
as $$
  select regexp_replace(lower(translate(btrim(coalesce(p, '')),
    'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ',
    'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn')), '\s+', ' ', 'g');
$$;

create or replace function app.gis_ts_txt(p timestamptz)
returns text
language sql
immutable
parallel safe
as $$ select to_char(p at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') $$;

-- Retrato determinístico dos campos que uma importação pode alterar num poste de referência.
-- Geometria em WKB hex (exata), datas em UTC com microssegundos — comparável entre sessões.
create or replace function app.gis_ref_retrato(r public.gis_postes_referencia)
returns jsonb
language sql
stable
set search_path = public, extensions, pg_temp
as $$
  select jsonb_build_object(
    'geom', encode(ST_AsBinary(r.geom), 'hex'),
    'cidade_id', r.cidade_id,
    'codigo_ibge', r.codigo_ibge,
    'situacao_fonte', r.situacao_fonte,
    'atributos_fonte', r.atributos_fonte,
    'data_referencia', app.gis_ts_txt(r.data_referencia),
    'ultima_coleta_em', app.gis_ts_txt(r.ultima_coleta_em),
    'estado_sincronizacao', r.estado_sincronizacao,
    'ultima_importacao_id', r.ultima_importacao_id
  );
$$;

-- Chaves de b cujo valor difere de a (valores de b).
create or replace function app.gis_jsonb_diferenca(a jsonb, b jsonb)
returns jsonb
language sql
immutable
parallel safe
as $$
  select coalesce(jsonb_object_agg(k, b -> k), '{}'::jsonb)
  from jsonb_object_keys(coalesce(b, '{}'::jsonb)) k
  where (a -> k) is distinct from (b -> k);
$$;

-- Subconjunto de a com as chaves de modelo.
create or replace function app.gis_jsonb_subconjunto(a jsonb, modelo jsonb)
returns jsonb
language sql
immutable
parallel safe
as $$
  select coalesce(jsonb_object_agg(k, a -> k), '{}'::jsonb)
  from jsonb_object_keys(coalesce(modelo, '{}'::jsonb)) k;
$$;

-- Carrega a importação com lock e confere quem pode mexer nela.
--   p_quem: 'EDITOR'   → ADMINISTRADOR, ou ENGENHARIA dona da importação
--           'DECISOR'  → EDITOR + DIRETOR
--           'APROVADOR'→ ADMINISTRADOR, DIRETOR
--           'ADMIN'    → ADMINISTRADOR
create or replace function app.gis_importacao_carregar(p_id uuid, p_quem text)
returns staging.gis_importacoes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v staging.gis_importacoes;
  v_ok boolean;
begin
  if p_id is null then
    raise exception 'OPTIMAP_NAO_ENCONTRADO: importação não informada.' using errcode = 'no_data_found';
  end if;
  select * into v from staging.gis_importacoes where id = p_id for update;
  if v.id is null then
    raise exception 'OPTIMAP_NAO_ENCONTRADO: importação inexistente.' using errcode = 'no_data_found';
  end if;
  v_ok := case p_quem
    when 'EDITOR' then app.tem_perfil('ADMINISTRADOR') or (app.tem_perfil('ENGENHARIA') and v.criado_por = auth.uid())
    when 'DECISOR' then app.tem_perfil('ADMINISTRADOR', 'DIRETOR') or (app.tem_perfil('ENGENHARIA') and v.criado_por = auth.uid())
    when 'APROVADOR' then app.tem_perfil('ADMINISTRADOR', 'DIRETOR')
    when 'ADMIN' then app.tem_perfil('ADMINISTRADOR')
    else false end;
  if not coalesce(v_ok, false) then
    raise exception 'OPTIMAP_SEM_PERMISSAO: seu perfil não pode executar esta ação nesta importação.' using errcode = 'insufficient_privilege';
  end if;
  return v;
end;
$$;

-- ============================================================================
-- 2) Iniciar: valida o cabeçalho do arquivo e abre a importação (RECEBIDA)
-- ============================================================================
create or replace function app.gis_importacao_iniciar(
  p_metadados jsonb, p_arquivo_nome text, p_arquivo_hash text, p_arquivo_tamanho bigint default null,
  p_observacoes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_fonte public.gis_fontes;
  v_ibge text;
  v_nome text;
  v_uf text;
  v_coletado timestamptz;
  v_total integer;
  v_cidade uuid;
  v_id uuid;
begin
  perform app.gis_exige_editor();
  if p_metadados is null or jsonb_typeof(p_metadados) <> 'object' then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: cabeçalho (bloco "optimap") ausente.' using errcode = 'invalid_parameter_value';
  end if;
  if p_metadados ->> 'formato' is distinct from 'optimap-referencia-postes/1' then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: formato "%" não suportado (esperado optimap-referencia-postes/1, gerado por tools/optimap/coletar_copel.mjs).',
      coalesce(p_metadados ->> 'formato', '(vazio)') using errcode = 'invalid_parameter_value';
  end if;
  select * into v_fonte from public.gis_fontes where codigo = p_metadados ->> 'fonte';
  if v_fonte.id is null or v_fonte.tipo <> 'EXTERNA' or not v_fonte.ativa then
    raise exception 'OPTIMAP_FONTE_INVALIDA: fonte "%" inexistente, inativa ou não EXTERNA.', p_metadados ->> 'fonte'
      using errcode = 'invalid_parameter_value';
  end if;

  v_ibge := p_metadados #>> '{municipio,ibge}';
  v_nome := btrim(coalesce(p_metadados #>> '{municipio,nome}', ''));
  v_uf := upper(btrim(coalesce(p_metadados #>> '{municipio,uf}', '')));
  if v_ibge is null or v_ibge !~ '^[0-9]{7}$' or v_nome = '' or v_uf !~ '^[A-Z]{2}$' then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: município (ibge/nome/uf) ausente ou inválido no cabeçalho.' using errcode = 'invalid_parameter_value';
  end if;
  begin
    v_coletado := (p_metadados ->> 'coletado_em')::timestamptz;
  exception when others then
    v_coletado := null;
  end;
  if v_coletado is null or v_coletado > now() + interval '1 day' or v_coletado < timestamptz '2000-01-01' then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: data da coleta (coletado_em) ausente ou inválida.' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_typeof(p_metadados -> 'total') = 'number' and (p_metadados ->> 'total')::numeric >= 0
     and (p_metadados ->> 'total')::numeric = trunc((p_metadados ->> 'total')::numeric) then
    v_total := (p_metadados ->> 'total')::integer;
  end if;
  if p_arquivo_hash is null or lower(p_arquivo_hash) !~ '^[0-9a-f]{64}$' then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: hash SHA-256 do arquivo inválido.' using errcode = 'invalid_parameter_value';
  end if;
  if length(btrim(coalesce(p_arquivo_nome, ''))) = 0 then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: nome do arquivo obrigatório.' using errcode = 'invalid_parameter_value';
  end if;

  -- Cidade da NICK: por código IBGE; senão por nome+UF sem acento. Só leitura.
  select id into v_cidade from public.cidades_infra where codigo_ibge = v_ibge and removido_em is null;
  if v_cidade is null then
    select id into v_cidade from public.cidades_infra
     where removido_em is null and uf = v_uf and app.gis_normalizar_nome(nome) = app.gis_normalizar_nome(v_nome);
  end if;

  begin
    insert into staging.gis_importacoes (fonte_id, municipio_ibge, municipio_nome, uf, cidade_id, data_referencia,
      arquivo_nome_original, arquivo_hash, arquivo_tamanho_bytes, metadados, total_declarado, criado_por, observacoes)
    values (v_fonte.id, v_ibge, v_nome, v_uf, v_cidade, v_coletado,
      left(btrim(p_arquivo_nome), 255), lower(p_arquivo_hash), p_arquivo_tamanho, p_metadados, v_total, auth.uid(), nullif(btrim(p_observacoes), ''))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'OPTIMAP_IMPORTACAO_EM_ABERTO: já existe uma importação em andamento para % (%). Conclua, rejeite ou descarte a anterior.', v_nome, v_ibge
      using errcode = 'unique_violation';
  end;

  perform app.registrar_auditoria_semantica('gis_importacoes', v_id, 'IMPORT_RECEIVE',
    format('Arquivo de postes de referência recebido: %s (%s-%s)', p_arquivo_nome, v_nome, v_uf), null,
    jsonb_build_object('fonte', v_fonte.codigo, 'municipio_ibge', v_ibge, 'arquivo_hash', lower(p_arquivo_hash),
                       'total_declarado', v_total, 'data_referencia', v_coletado, 'cidade_id', v_cidade),
    'optimap', null);
  return v_id;
end;
$$;

-- ============================================================================
-- 3) Adicionar itens (lotes de até 2000 postes)
-- ============================================================================
-- p_itens: [{"linha":0,"id_externo":"123","lon":-52.4,"lat":-23.6,"situacao":"Disponível","atributos":{...}}, ...]
create or replace function app.gis_importacao_adicionar_itens(p_importacao_id uuid, p_itens jsonb)
returns integer
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v staging.gis_importacoes;
  v_n integer;
begin
  v := app.gis_importacao_carregar(p_importacao_id, 'EDITOR');
  if v.status <> 'RECEBIDA' then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: itens só podem ser adicionados com a importação RECEBIDA (atual: %).', v.status using errcode = 'check_violation';
  end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: lote de itens vazio.' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_array_length(p_itens) > 2000 then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: lote com % itens (máximo 2000 por chamada).', jsonb_array_length(p_itens) using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from jsonb_array_elements(p_itens) e
              where jsonb_typeof(e) <> 'object' or jsonb_typeof(e -> 'linha') <> 'number'
                 or (e ->> 'linha')::numeric < 0 or (e ->> 'linha')::numeric <> trunc((e ->> 'linha')::numeric)
                 or (e ->> 'linha')::numeric > 10000000) then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: todo item precisa de "linha" inteira não negativa.' using errcode = 'invalid_parameter_value';
  end if;

  begin
    insert into staging.gis_importacao_itens (importacao_id, linha, id_externo, lon, lat, situacao_fonte, atributos_fonte, geom)
    select v.id, x.linha, x.id_externo, x.lon, x.lat, x.situacao, x.atributos,
           case when x.lon is not null and x.lat is not null and abs(x.lon) <= 180 and abs(x.lat) <= 90
                then ST_SetSRID(ST_MakePoint(x.lon, x.lat), 4326) end
    from (
      select (e ->> 'linha')::integer as linha,
             nullif(left(btrim(e ->> 'id_externo'), 64), '') as id_externo,
             case when jsonb_typeof(e -> 'lon') = 'number' then (e ->> 'lon')::double precision end as lon,
             case when jsonb_typeof(e -> 'lat') = 'number' then (e ->> 'lat')::double precision end as lat,
             nullif(left(btrim(e ->> 'situacao'), 100), '') as situacao,
             case when jsonb_typeof(e -> 'atributos') = 'object' then e -> 'atributos' else '{}'::jsonb end as atributos
      from jsonb_array_elements(p_itens) e
    ) x;
  exception when unique_violation then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: linha repetida (lote enviado duas vezes?).' using errcode = 'unique_violation';
  end;
  get diagnostics v_n = row_count;

  update staging.gis_importacoes set total_recebido = total_recebido + v_n where id = v.id;
  return v.total_recebido + v_n;
end;
$$;

-- ============================================================================
-- 4) Processamento (classificação) — interno, usado por processar e aprovar
-- ============================================================================
create or replace function app.gis_importacao_classificar(p_importacao_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v staging.gis_importacoes;
  v_resumo jsonb;
  v_existentes integer;
  v_ausentes integer;
  v_validos integer;
  v_bloqueios jsonb := '[]'::jsonb;
  v_avisos jsonb := '[]'::jsonb;
  v_ultima record;
begin
  select * into v from staging.gis_importacoes where id = p_importacao_id;

  -- Classificação calculada numa tabela temporária e gravada com UM único UPDATE, só nas
  -- linhas cujo resultado mudou. Recalcular uma prévia que não mudou (ex.: na aprovação) não
  -- reescreve nenhuma linha — evita inchar a tabela (o espaço do plano Free conta o inchaço).
  create temporary table if not exists _gis_calc (
    id bigint primary key, classificacao text, motivo text, referencia_id uuid, retrato_md5 text,
    diffs jsonb, distancia_m double precision, alertas jsonb
  ) on commit drop;
  truncate _gis_calc;
  -- Estatísticas atualizadas: sem isto o planejador estima 1 linha para os itens recém-
  -- carregados e troca o índice espacial por varredura (15 mil postes: 4 min em vez de 1 s).
  analyze staging.gis_importacao_itens;

  insert into _gis_calc (id, classificacao, motivo, referencia_id, retrato_md5, diffs, distancia_m, alertas)
  with f as (
    select i.id, i.linha, i.id_externo, i.geom, i.lon, i.lat, i.situacao_fonte, i.atributos_fonte,
           case
             when i.id_externo is null then 'SEM_NUMERO_DO_POSTE'
             when i.lon is null or i.lat is null then 'SEM_COORDENADA'
             when i.geom is null or not app.gis_coordenada_valida(i.geom) then 'COORDENADA_INVALIDA'
           end as invalido
      from staging.gis_importacao_itens i
     where i.importacao_id = v.id and i.linha is not null
  ), d as (
    -- Duplicados no arquivo: vale a 1ª ocorrência do número.
    select f.*, row_number() over w as n, first_value(f.linha) over w as primeira, first_value(f.geom) over w as geom_primeira
      from f where f.invalido is null
    window w as (partition by f.id_externo order by f.linha)
  ), rep as (
    select d.id_externo, bool_or(ST_Distance(d.geom::geography, d.geom_primeira::geography) > 0.5) as longe
      from d where d.n > 1 group by d.id_externo
  ), m as (
    -- Casamento com o cadastrado: fonte + id_externo, nada mais.
    select d.*, r.id as rid, r.geom as rgeom, r.situacao_fonte as rsit, r.atributos_fonte as ratr, r.codigo_ibge as ribge,
           r.estado_sincronizacao as rest, md5(app.gis_ref_retrato(r)::text) as rmd5,
           (select p.id from public.gis_postes p where p.poste_referencia_id = r.id and p.removido_em is null limit 1) as poste_nick,
           case when r.id is not null then round(ST_Distance(d.geom::geography, r.geom::geography)::numeric, 2)::double precision end as dist,
           coalesce(rep.longe, false) as repetido_longe
      from d left join public.gis_postes_referencia r on r.fonte_id = v.fonte_id and r.id_externo = d.id_externo
      left join rep on rep.id_externo = d.id_externo
     where d.n = 1
  ), c as (
    select m.*,
           nullif(
             case when m.rid is not null and m.situacao_fonte is distinct from m.rsit
                  then jsonb_build_object('situacao_fonte', jsonb_build_object('anterior', m.rsit, 'novo', m.situacao_fonte)) else '{}'::jsonb end
          -- objectid é identificador interno do serviço e muda sem significado: ignorado.
          || case when m.rid is not null and (m.atributos_fonte - 'objectid' - 'num_seq_geo' - 'situacao') is distinct from (m.ratr - 'objectid' - 'num_seq_geo' - 'situacao')
                  then jsonb_build_object('atributos_fonte', jsonb_build_object('anterior', m.ratr - 'objectid', 'novo', m.atributos_fonte - 'objectid')) else '{}'::jsonb end
          || case when m.dist > 0.5
                  then jsonb_build_object('posicao', jsonb_build_object('anterior', jsonb_build_array(ST_X(m.rgeom), ST_Y(m.rgeom)),
                                                                        'novo', jsonb_build_array(m.lon, m.lat), 'distancia_m', m.dist)) else '{}'::jsonb end
          || case when m.rid is not null and m.ribge is null
                  then jsonb_build_object('codigo_ibge', jsonb_build_object('anterior', null, 'novo', v.municipio_ibge)) else '{}'::jsonb end,
           '{}'::jsonb) as diffs,
           case
             when m.rid is null then null
             when m.rest = 'EXCLUIDO_PELA_FONTE' then 'REAPARECEU_APOS_EXCLUSAO'
             when m.ribge is not null and m.ribge <> v.municipio_ibge then 'MUNICIPIO_DIFERENTE'
             when m.dist > 5 and m.poste_nick is not null then 'DESLOCADO_COM_POSTE_NICK'
             when m.dist > 30 then 'DESLOCAMENTO_GRANDE'
           end as conflito
      from m
  )
  -- válidos (1ª ocorrência)
  select c.id,
         case when c.rid is null then 'NOVO' when c.conflito is not null then 'CONFLITO'
              when c.diffs is null then 'SEM_ALTERACAO' else 'ATUALIZADO' end,
         c.conflito, c.rid, c.rmd5, c.diffs, c.dist,
         -- Alertas (nunca mudam a classificação)
         coalesce(case when c.rid is null then (
             select jsonb_agg(jsonb_build_object('tipo', 'POSTE_PROXIMO_COM_OUTRO_NUMERO', 'id_externo', o.id_externo,
                                                 'distancia_m', round(o.dist::numeric, 2), 'origem', o.origem) order by o.dist)
               from (select distinct on (q.id_externo) q.* from (
                       select r.id_externo, ST_Distance(c.geom::geography, r.geom::geography) as dist, 'CADASTRADO' as origem
                         from public.gis_postes_referencia r
                        where r.fonte_id = v.fonte_id and r.id_externo <> c.id_externo
                          and r.geom && ST_Expand(c.geom, 0.00002) and ST_DWithin(c.geom::geography, r.geom::geography, 1.0)
                       union all
                       select o2.id_externo, ST_Distance(c.geom::geography, o2.geom::geography), 'ARQUIVO'
                         from staging.gis_importacao_itens o2
                        where o2.importacao_id = v.id and o2.linha is not null and o2.id_externo <> c.id_externo
                          and o2.geom && ST_Expand(c.geom, 0.00002) and ST_DWithin(c.geom::geography, o2.geom::geography, 1.0)
                     ) q order by q.id_externo, q.dist) o) end, '[]'::jsonb)
         || case when c.repetido_longe then jsonb_build_array(jsonb_build_object('tipo', 'NUMERO_REPETIDO_COM_POSICAO_DIFERENTE')) else '[]'::jsonb end
         || case when c.poste_nick is not null and (c.conflito is not null or c.diffs is not null)
                 then jsonb_build_array(jsonb_build_object('tipo', 'POSTE_NICK_VINCULADO', 'poste_id', c.poste_nick)) else '[]'::jsonb end
    from c
  union all
  -- duplicados
  select d.id, 'DUPLICADO', format('NUMERO_REPETIDO_NO_ARQUIVO (vale a linha %s)', d.primeira), null, null, null,
         round(ST_Distance(d.geom::geography, d.geom_primeira::geography)::numeric, 2)::double precision, '[]'::jsonb
    from d where d.n > 1
  union all
  -- inválidos
  select f.id, 'INVALIDO', f.invalido, null, null, null, null, '[]'::jsonb
    from f where f.invalido is not null;

  -- Grava só o que mudou. Decisão de conflito continua valendo se o conflito é o mesmo.
  update staging.gis_importacao_itens i
     set classificacao = c.classificacao, motivo = c.motivo, referencia_id = c.referencia_id, retrato_md5 = c.retrato_md5,
         diffs = c.diffs, distancia_m = c.distancia_m, alertas = c.alertas,
         decisao = case when c.classificacao = 'CONFLITO' and i.classificacao = 'CONFLITO' and i.motivo = c.motivo then i.decisao end,
         decidido_por = case when c.classificacao = 'CONFLITO' and i.classificacao = 'CONFLITO' and i.motivo = c.motivo then i.decidido_por end,
         decidido_em = case when c.classificacao = 'CONFLITO' and i.classificacao = 'CONFLITO' and i.motivo = c.motivo then i.decidido_em end
    from _gis_calc c
   where i.id = c.id
     and (i.classificacao, i.motivo, i.referencia_id, i.retrato_md5, i.diffs, i.distancia_m, i.alertas)
         is distinct from (c.classificacao, c.motivo, c.referencia_id, c.retrato_md5, c.diffs, c.distancia_m, c.alertas);

  -- 4.5 Ausentes: postes do mesmo escopo (fonte + município) que não vieram no arquivo.
  -- Sincroniza (remove os que deixaram de ser ausentes, inclui os novos, atualiza os que
  -- mudaram) — são linhas derivadas da prévia, nunca dado oficial.
  create temporary table if not exists _gis_aus (
    referencia_id uuid primary key, id_externo text, lon double precision, lat double precision, situacao_fonte text,
    atributos_fonte jsonb, geom geometry, retrato_md5 text, alertas jsonb
  ) on commit drop;
  truncate _gis_aus;
  insert into _gis_aus
  select r.id, r.id_externo, ST_X(r.geom), ST_Y(r.geom), r.situacao_fonte, r.atributos_fonte, r.geom, md5(app.gis_ref_retrato(r)::text),
         case when exists (select 1 from public.gis_postes p where p.poste_referencia_id = r.id and p.removido_em is null)
              then jsonb_build_array(jsonb_build_object('tipo', 'AUSENTE_COM_POSTE_NICK'))
              else '[]'::jsonb end
           || case when r.estado_sincronizacao = 'NAO_LOCALIZADO_ULTIMA_COLETA'
              then jsonb_build_array(jsonb_build_object('tipo', 'JA_NAO_LOCALIZADO'))
              else '[]'::jsonb end
    from public.gis_postes_referencia r
   where r.fonte_id = v.fonte_id and r.codigo_ibge = v.municipio_ibge
     and r.estado_sincronizacao <> 'EXCLUIDO_PELA_FONTE'
     and not exists (select 1 from staging.gis_importacao_itens i
                      where i.importacao_id = v.id and i.linha is not null and i.id_externo = r.id_externo);

  delete from staging.gis_importacao_itens i
   where i.importacao_id = v.id and i.classificacao = 'AUSENTE'
     and not exists (select 1 from _gis_aus a where a.referencia_id = i.referencia_id);
  update staging.gis_importacao_itens i
     set retrato_md5 = a.retrato_md5, alertas = a.alertas, situacao_fonte = a.situacao_fonte, atributos_fonte = a.atributos_fonte,
         geom = a.geom, lon = a.lon, lat = a.lat
    from _gis_aus a
   where i.importacao_id = v.id and i.classificacao = 'AUSENTE' and i.referencia_id = a.referencia_id
     and (i.retrato_md5, i.alertas) is distinct from (a.retrato_md5, a.alertas);
  insert into staging.gis_importacao_itens (importacao_id, linha, id_externo, lon, lat, situacao_fonte, atributos_fonte,
                                             geom, classificacao, referencia_id, retrato_md5, alertas)
  select v.id, null, a.id_externo, a.lon, a.lat, a.situacao_fonte, a.atributos_fonte, a.geom, 'AUSENTE', a.referencia_id, a.retrato_md5, a.alertas
    from _gis_aus a
   where not exists (select 1 from staging.gis_importacao_itens i
                      where i.importacao_id = v.id and i.classificacao = 'AUSENTE' and i.referencia_id = a.referencia_id);

  -- 4.6 Resumo, avisos e bloqueios
  select count(*) into v_existentes from public.gis_postes_referencia r
   where r.fonte_id = v.fonte_id and r.codigo_ibge = v.municipio_ibge and r.estado_sincronizacao <> 'EXCLUIDO_PELA_FONTE';
  select count(*) filter (where classificacao = 'AUSENTE' and not alertas @> '[{"tipo":"JA_NAO_LOCALIZADO"}]'),
         count(*) filter (where classificacao in ('NOVO', 'ATUALIZADO', 'SEM_ALTERACAO', 'CONFLITO'))
    into v_ausentes, v_validos
    from staging.gis_importacao_itens where importacao_id = v.id;

  if v_validos = 0 then
    v_bloqueios := v_bloqueios || jsonb_build_object('codigo', 'NENHUM_POSTE_VALIDO', 'mensagem', 'O arquivo não tem nenhum poste válido.');
  end if;
  if v.total_declarado is not null and v.total_declarado <> v.total_recebido then
    v_bloqueios := v_bloqueios || jsonb_build_object('codigo', 'ARQUIVO_INCOMPLETO',
      'mensagem', format('O cabeçalho declara %s postes, mas %s foram recebidos.', v.total_declarado, v.total_recebido));
  end if;
  if exists (select 1 from staging.gis_importacao_itens where importacao_id = v.id and classificacao = 'CONFLITO' and decisao is null) then
    v_bloqueios := v_bloqueios || jsonb_build_object('codigo', 'CONFLITOS_SEM_DECISAO', 'mensagem', 'Há conflitos aguardando decisão (aplicar ou ignorar).');
  end if;
  select id, data_referencia into v_ultima from staging.gis_importacoes
   where fonte_id = v.fonte_id and municipio_ibge = v.municipio_ibge and status = 'IMPORTADA' and id <> v.id
   order by data_referencia desc limit 1;
  if v_ultima.id is not null and v_ultima.data_referencia > v.data_referencia then
    v_bloqueios := v_bloqueios || jsonb_build_object('codigo', 'COLETA_MAIS_ANTIGA_QUE_A_ULTIMA_IMPORTADA',
      'mensagem', format('Já existe importação aplicada com coleta de %s, mais recente que esta.', app.gis_ts_txt(v_ultima.data_referencia)),
      'importacao_id', v_ultima.id);
  end if;
  if v_existentes >= 50 and v_ausentes > v_existentes * 0.20 then
    v_avisos := v_avisos || jsonb_build_object('codigo', 'AUSENCIA_EM_MASSA', 'exige_confirmacao', true,
      'mensagem', format('%s de %s postes já cadastrados no município (%s%%) não vieram no arquivo. Confirme que a coleta está completa.',
                         v_ausentes, v_existentes, round(100.0 * v_ausentes / v_existentes)));
  end if;
  if v.cidade_id is null then
    v_avisos := v_avisos || jsonb_build_object('codigo', 'MUNICIPIO_SEM_CIDADE_NICK',
      'mensagem', 'O município não corresponde a nenhuma cidade cadastrada no OptiMon; os postes ficam sem cidade associada.');
  end if;
  if exists (select 1 from staging.gis_importacoes where arquivo_hash = v.arquivo_hash and status = 'IMPORTADA' and id <> v.id) then
    v_avisos := v_avisos || jsonb_build_object('codigo', 'ARQUIVO_JA_IMPORTADO', 'mensagem', 'Este mesmo arquivo (hash) já foi importado antes.');
  end if;

  select jsonb_build_object(
    'contagens', coalesce(jsonb_object_agg(c.classificacao, c.n), '{}'::jsonb),
    'conflitos_pendentes', (select count(*) from staging.gis_importacao_itens where importacao_id = v.id and classificacao = 'CONFLITO' and decisao is null),
    'conflitos_por_motivo', (select coalesce(jsonb_object_agg(motivo, n), '{}'::jsonb) from (select motivo, count(*) n from staging.gis_importacao_itens
                               where importacao_id = v.id and classificacao = 'CONFLITO' group by motivo) m),
    'invalidos_por_motivo', (select coalesce(jsonb_object_agg(motivo, n), '{}'::jsonb) from (select motivo, count(*) n from staging.gis_importacao_itens
                               where importacao_id = v.id and classificacao = 'INVALIDO' group by motivo) m),
    'alertas_por_tipo', (select coalesce(jsonb_object_agg(t, n), '{}'::jsonb) from (select a ->> 'tipo' t, count(*) n
                               from staging.gis_importacao_itens, jsonb_array_elements(alertas) a where importacao_id = v.id group by 1) m),
    'situacao_no_arquivo', (select coalesce(jsonb_object_agg(coalesce(situacao_fonte, '(vazio)'), n), '{}'::jsonb) from (select situacao_fonte, count(*) n
                               from staging.gis_importacao_itens where importacao_id = v.id and linha is not null
                                and classificacao not in ('INVALIDO', 'DUPLICADO') group by 1) m),
    'cadastrados_no_municipio', v_existentes,
    'ausentes_que_mudam_de_estado', v_ausentes,
    'total_recebido', v.total_recebido,
    'total_declarado', v.total_declarado,
    'bloqueios', v_bloqueios,
    'avisos', v_avisos,
    'pode_aprovar', jsonb_array_length(v_bloqueios) = 0
  ) into v_resumo
  from (select classificacao, count(*) n from staging.gis_importacao_itens where importacao_id = v.id group by classificacao) c;

  update staging.gis_importacoes set resumo = v_resumo, processado_em = now() where id = v.id;
  return v_resumo;
end;
$$;

-- Impressão digital da prévia: o que o aprovador revisou.
create or replace function app.gis_importacao_digital(p_importacao_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select md5(coalesce(string_agg(concat_ws('|', coalesce(linha::text, 'A'), id_externo, classificacao, motivo, referencia_id::text,
                                           decisao, retrato_md5, diffs::text), E'\n'
                                 order by linha nulls last, referencia_id), ''))
    from staging.gis_importacao_itens where importacao_id = p_importacao_id;
$$;

create or replace function app.gis_importacao_processar(p_importacao_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v staging.gis_importacoes;
  v_resumo jsonb;
begin
  v := app.gis_importacao_carregar(p_importacao_id, 'EDITOR');
  if v.status not in ('RECEBIDA', 'PREVIA') then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: só importações RECEBIDA ou PREVIA podem ser processadas (atual: %).', v.status using errcode = 'check_violation';
  end if;
  if v.total_recebido = 0 then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: nenhum item recebido.' using errcode = 'check_violation';
  end if;
  v_resumo := app.gis_importacao_classificar(v.id);
  update staging.gis_importacoes set status = 'PREVIA' where id = v.id;
  perform app.registrar_auditoria_semantica('gis_importacoes', v.id, 'IMPORT_PREVIEW_READY',
    format('Prévia calculada: %s-%s', v.municipio_nome, v.uf), null,
    jsonb_build_object('contagens', v_resumo -> 'contagens', 'bloqueios', v_resumo -> 'bloqueios'), 'optimap', null);
  return v_resumo;
end;
$$;

-- ============================================================================
-- 5) Decisão sobre conflitos
-- ============================================================================
create or replace function app.gis_importacao_decidir(p_importacao_id uuid, p_item_ids bigint[], p_decisao text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v staging.gis_importacoes;
  v_n integer;
  v_resumo jsonb;
begin
  v := app.gis_importacao_carregar(p_importacao_id, 'DECISOR');
  if v.status <> 'PREVIA' then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: decisões só na PREVIA (atual: %).', v.status using errcode = 'check_violation';
  end if;
  if p_decisao is not null and p_decisao not in ('APLICAR', 'IGNORAR') then
    raise exception 'OPTIMAP_PARAMETRO_INVALIDO: decisão deve ser APLICAR, IGNORAR ou nula (desfazer).' using errcode = 'invalid_parameter_value';
  end if;
  if p_item_ids is null or cardinality(p_item_ids) = 0 then
    raise exception 'OPTIMAP_PARAMETRO_INVALIDO: informe os itens.' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from unnest(p_item_ids) x(id)
              where not exists (select 1 from staging.gis_importacao_itens i
                                 where i.id = x.id and i.importacao_id = v.id and i.classificacao = 'CONFLITO')) then
    raise exception 'OPTIMAP_PARAMETRO_INVALIDO: só itens em CONFLITO desta importação recebem decisão.' using errcode = 'invalid_parameter_value';
  end if;
  update staging.gis_importacao_itens
     set decisao = p_decisao,
         decidido_por = case when p_decisao is null then null else auth.uid() end,
         decidido_em = case when p_decisao is null then null else now() end
   where importacao_id = v.id and id = any(p_item_ids);
  get diagnostics v_n = row_count;

  -- Atualiza só o bloco de pendências do resumo (sem reclassificar).
  v_resumo := coalesce(v.resumo, '{}'::jsonb);
  v_resumo := jsonb_set(v_resumo, '{conflitos_pendentes}',
    to_jsonb((select count(*) from staging.gis_importacao_itens where importacao_id = v.id and classificacao = 'CONFLITO' and decisao is null)));
  v_resumo := jsonb_set(v_resumo, '{bloqueios}', coalesce((
    select jsonb_agg(b) from jsonb_array_elements(coalesce(v_resumo -> 'bloqueios', '[]'::jsonb)) b where b ->> 'codigo' <> 'CONFLITOS_SEM_DECISAO'), '[]'::jsonb)
    || case when (v_resumo ->> 'conflitos_pendentes')::integer > 0
            then jsonb_build_array(jsonb_build_object('codigo', 'CONFLITOS_SEM_DECISAO', 'mensagem', 'Há conflitos aguardando decisão (aplicar ou ignorar).'))
            else '[]'::jsonb end);
  v_resumo := jsonb_set(v_resumo, '{pode_aprovar}', to_jsonb(jsonb_array_length(v_resumo -> 'bloqueios') = 0));
  update staging.gis_importacoes set resumo = v_resumo where id = v.id;
  return jsonb_build_object('alterados', v_n, 'resumo', v_resumo);
end;
$$;

-- ============================================================================
-- 6) Aprovar e aplicar (atômico)
-- ============================================================================
create or replace function app.gis_importacao_aprovar(
  p_importacao_id uuid, p_confirmar_ausencias boolean default false, p_observacao text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v staging.gis_importacoes;
  v_digital_antes text;
  v_resumo jsonb;
  v_ins integer := 0;
  v_upd integer := 0;
  v_aus integer := 0;
  v_ign integer := 0;
  v_resultado jsonb;
begin
  v := app.gis_importacao_carregar(p_importacao_id, 'APROVADOR');
  if v.status <> 'PREVIA' then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: só importações em PREVIA podem ser aprovadas (atual: %).', v.status using errcode = 'check_violation';
  end if;

  -- Serializa importações/reversões do mesmo escopo e trava os postes envolvidos.
  perform pg_advisory_xact_lock(hashtextextended('optimap_importacao:' || v.fonte_id || ':' || v.municipio_ibge, 0));
  perform 1 from public.gis_postes_referencia r
   where r.fonte_id = v.fonte_id and r.codigo_ibge = v.municipio_ibge
   for update;
  perform 1 from public.gis_postes_referencia r
    join staging.gis_importacao_itens i on i.importacao_id = v.id and i.linha is not null and r.id_externo = i.id_externo
   where r.fonte_id = v.fonte_id
   for update of r;

  -- A prévia revisada ainda é a verdade? Recalcula e compara.
  v_digital_antes := app.gis_importacao_digital(v.id);
  v_resumo := app.gis_importacao_classificar(v.id);
  if app.gis_importacao_digital(v.id) <> v_digital_antes then
    raise exception 'OPTIMAP_PREVIA_DESATUALIZADA: o cadastro mudou desde a prévia. Reprocesse e revise antes de aprovar.'
      using errcode = 'serialization_failure';
  end if;
  if jsonb_array_length(v_resumo -> 'bloqueios') > 0 then
    raise exception 'OPTIMAP_IMPORTACAO_BLOQUEADA: %', (select string_agg(b ->> 'mensagem', ' ') from jsonb_array_elements(v_resumo -> 'bloqueios') b)
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(v_resumo -> 'avisos') a where (a ->> 'exige_confirmacao')::boolean)
     and not coalesce(p_confirmar_ausencias, false) then
    raise exception 'OPTIMAP_CONFIRMAR_AUSENCIAS: muitos postes cadastrados não vieram no arquivo. Confirme explicitamente para marcá-los como não localizados.'
      using errcode = 'check_violation';
  end if;

  -- Retrato de antes de cada poste que pode mudar (base do log "anterior/novo").
  create temporary table if not exists _gis_antes (id uuid primary key, antes jsonb) on commit drop;
  truncate _gis_antes;
  insert into _gis_antes
  select r.id, app.gis_ref_retrato(r)
    from staging.gis_importacao_itens i join public.gis_postes_referencia r on r.id = i.referencia_id
   where i.importacao_id = v.id and i.classificacao in ('ATUALIZADO', 'SEM_ALTERACAO', 'CONFLITO', 'AUSENTE');

  -- 6.1 NOVO → insere (e registra no log no mesmo comando). O log de inclusão guarda só a
  -- impressão (md5) do registro criado: o conteúdo é reconstituível do item + importação, e
  -- a reversão só precisa saber se o poste continua exatamente como foi criado.
  with ins as (
    insert into public.gis_postes_referencia (fonte_id, id_externo, geom, cidade_id, codigo_ibge, situacao_fonte, atributos_fonte,
                                              data_referencia, primeira_coleta_em, ultima_coleta_em, estado_sincronizacao, ultima_importacao_id)
    select v.fonte_id, i.id_externo, i.geom, v.cidade_id, v.municipio_ibge, i.situacao_fonte, i.atributos_fonte,
           v.data_referencia, v.data_referencia, v.data_referencia, 'CONFIRMADO', v.id
      from staging.gis_importacao_itens i
     where i.importacao_id = v.id and i.classificacao = 'NOVO'
     order by i.linha
    returning id, id_externo, md5(app.gis_ref_retrato(gis_postes_referencia)::text) as impressao
  )
  insert into staging.gis_importacao_alteracoes (importacao_id, item_id, referencia_id, id_externo, operacao, valor_anterior, valor_novo, aplicado_por)
  select v.id, i.id, ins.id, ins.id_externo, 'INSERT', null, jsonb_build_object('md5', ins.impressao), auth.uid()
    from ins join staging.gis_importacao_itens i on i.importacao_id = v.id and i.classificacao = 'NOVO' and i.id_externo = ins.id_externo
   order by i.linha;
  get diagnostics v_ins = row_count;

  -- 6.2 ATUALIZADO e CONFLITO com decisão APLICAR
  update public.gis_postes_referencia r
     set geom = case when i.distancia_m > 0.5 then i.geom else r.geom end,
         situacao_fonte = i.situacao_fonte,
         atributos_fonte = i.atributos_fonte,
         data_referencia = v.data_referencia,
         ultima_coleta_em = greatest(r.primeira_coleta_em, v.data_referencia),
         codigo_ibge = case when i.motivo = 'MUNICIPIO_DIFERENTE' then v.municipio_ibge else coalesce(r.codigo_ibge, v.municipio_ibge) end,
         cidade_id = case when i.motivo = 'MUNICIPIO_DIFERENTE' then v.cidade_id else coalesce(r.cidade_id, v.cidade_id) end,
         estado_sincronizacao = case when r.estado_sincronizacao = 'DIVERGENTE' and i.classificacao = 'ATUALIZADO' then 'DIVERGENTE' else 'ATUALIZADO' end,
         ultima_importacao_id = v.id
    from staging.gis_importacao_itens i
   where i.importacao_id = v.id and r.id = i.referencia_id
     and (i.classificacao = 'ATUALIZADO' or (i.classificacao = 'CONFLITO' and i.decisao = 'APLICAR'));
  get diagnostics v_upd = row_count;

  -- 6.3 SEM_ALTERACAO → confirma (renova a data da coleta)
  update public.gis_postes_referencia r
     set data_referencia = v.data_referencia,
         ultima_coleta_em = greatest(r.primeira_coleta_em, v.data_referencia),
         codigo_ibge = coalesce(r.codigo_ibge, v.municipio_ibge),
         cidade_id = coalesce(r.cidade_id, v.cidade_id),
         estado_sincronizacao = case when r.estado_sincronizacao = 'DIVERGENTE' then 'DIVERGENTE' else 'CONFIRMADO' end,
         ultima_importacao_id = v.id
    from staging.gis_importacao_itens i
   where i.importacao_id = v.id and i.classificacao = 'SEM_ALTERACAO' and r.id = i.referencia_id;

  -- 6.4 AUSENTE → NAO_LOCALIZADO_ULTIMA_COLETA (nunca apagado)
  update public.gis_postes_referencia r
     set estado_sincronizacao = 'NAO_LOCALIZADO_ULTIMA_COLETA', ultima_importacao_id = v.id
    from staging.gis_importacao_itens i
   where i.importacao_id = v.id and i.classificacao = 'AUSENTE' and r.id = i.referencia_id
     and r.estado_sincronizacao <> 'NAO_LOCALIZADO_ULTIMA_COLETA';
  get diagnostics v_aus = row_count;

  -- 6.5 Log de alterações: valor anterior dos campos que mudaram + impressão (md5) dos
  -- valores novos desses campos (o suficiente para a reversão saber se ainda estão iguais).
  with alt as (
    select i.id as item_id, i.linha, r.id, r.id_externo, b.antes, app.gis_ref_retrato(r) as depois
      from staging.gis_importacao_itens i join public.gis_postes_referencia r on r.id = i.referencia_id
      join _gis_antes b on b.id = r.id
     where i.importacao_id = v.id and i.classificacao in ('ATUALIZADO', 'SEM_ALTERACAO', 'CONFLITO', 'AUSENTE')
  )
  insert into staging.gis_importacao_alteracoes (importacao_id, item_id, referencia_id, id_externo, operacao, valor_anterior, valor_novo, aplicado_por)
  select v.id, a.item_id, a.id, a.id_externo, 'UPDATE',
         app.gis_jsonb_subconjunto(a.antes, app.gis_jsonb_diferenca(a.antes, a.depois)),
         jsonb_build_object('md5', md5(app.gis_jsonb_diferenca(a.antes, a.depois)::text)), auth.uid()
    from alt a
   where a.depois is distinct from a.antes
   order by a.linha nulls last, a.id_externo;

  select count(*) into v_ign from staging.gis_importacao_itens
   where importacao_id = v.id and classificacao = 'CONFLITO' and decisao = 'IGNORAR';

  update staging.gis_importacoes
     set status = 'IMPORTADA', aprovado_por = auth.uid(), aprovado_em = now(), resumo = v_resumo,
         observacoes = coalesce(nullif(btrim(p_observacao), ''), observacoes)
   where id = v.id;

  v_resultado := jsonb_build_object(
    'inseridos', v_ins,
    'atualizados', v_upd,
    'confirmados', (select count(*) from staging.gis_importacao_alteracoes a join staging.gis_importacao_itens i on i.id = a.item_id
                     where a.importacao_id = v.id and i.classificacao = 'SEM_ALTERACAO'),
    'nao_localizados', v_aus,
    'conflitos_ignorados', v_ign,
    'alteracoes_registradas', (select count(*) from staging.gis_importacao_alteracoes where importacao_id = v.id));

  perform app.registrar_auditoria_semantica('gis_importacoes', v.id, 'IMPORT_APPROVE',
    coalesce(nullif(btrim(p_observacao), ''), format('Importação aprovada: %s-%s', v.municipio_nome, v.uf)),
    jsonb_build_object('status', 'PREVIA'),
    jsonb_build_object('status', 'IMPORTADA', 'confirmou_ausencias', coalesce(p_confirmar_ausencias, false),
                       'aprovador_e_quem_enviou', v.criado_por = auth.uid()),
    'optimap', null);
  perform app.registrar_auditoria_semantica('gis_importacoes', v.id, 'IMPORT_APPLY',
    format('Postes de referência aplicados: %s-%s', v.municipio_nome, v.uf), null, v_resultado, 'optimap', null);
  return v_resultado;
end;
$$;

-- ============================================================================
-- 7) Rejeitar / descartar
-- ============================================================================
create or replace function app.gis_importacao_rejeitar(p_importacao_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v staging.gis_importacoes;
begin
  v := app.gis_importacao_carregar(p_importacao_id, 'APROVADOR');
  if v.status not in ('RECEBIDA', 'PREVIA') then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: só importações RECEBIDA/PREVIA podem ser rejeitadas (atual: %).', v.status using errcode = 'check_violation';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'OPTIMAP_MOTIVO_OBRIGATORIO: informe o motivo da rejeição.' using errcode = 'invalid_parameter_value';
  end if;
  update staging.gis_importacoes set status = 'REJEITADA', rejeitado_por = auth.uid(), rejeitado_em = now(), motivo_rejeicao = btrim(p_motivo)
   where id = v.id;
  perform app.registrar_auditoria_semantica('gis_importacoes', v.id, 'IMPORT_REJECT', btrim(p_motivo),
    jsonb_build_object('status', v.status), jsonb_build_object('status', 'REJEITADA'), 'optimap', null);
end;
$$;

create or replace function app.gis_importacao_descartar(p_importacao_id uuid, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v staging.gis_importacoes;
begin
  v := app.gis_importacao_carregar(p_importacao_id, 'EDITOR');
  if v.status not in ('RECEBIDA', 'PREVIA') then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: só importações RECEBIDA/PREVIA podem ser descartadas (atual: %).', v.status using errcode = 'check_violation';
  end if;
  update staging.gis_importacoes set status = 'DESCARTADA', descartado_por = auth.uid(), descartado_em = now()
   where id = v.id;
  perform app.registrar_auditoria_semantica('gis_importacoes', v.id, 'IMPORT_DISCARD', nullif(btrim(p_motivo), ''),
    jsonb_build_object('status', v.status), jsonb_build_object('status', 'DESCARTADA'), 'optimap', null);
end;
$$;

-- ============================================================================
-- 8) Reverter (seletiva, ordem inversa, sem reset)
-- ============================================================================
create or replace function app.gis_importacao_reverter(p_importacao_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v staging.gis_importacoes;
  a staging.gis_importacao_alteracoes;
  r public.gis_postes_referencia;
  va jsonb;
  v_atual jsonb;
  v_motivo text;
  v_ok integer := 0;
  v_falha integer := 0;
  v_pend integer;
  v_status text;
  v_resultado jsonb;
begin
  v := app.gis_importacao_carregar(p_importacao_id, 'ADMIN');
  if v.status not in ('IMPORTADA', 'REVERTIDA_PARCIALMENTE') then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: só importações IMPORTADA ou REVERTIDA_PARCIALMENTE podem ser revertidas (atual: %).', v.status using errcode = 'check_violation';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'OPTIMAP_MOTIVO_OBRIGATORIO: informe o motivo da reversão.' using errcode = 'invalid_parameter_value';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('optimap_importacao:' || v.fonte_id || ':' || v.municipio_ibge, 0));

  for a in select * from staging.gis_importacao_alteracoes
            where importacao_id = v.id and not revertido order by ordem desc
  loop
    v_motivo := null;
    select * into r from public.gis_postes_referencia where id = a.referencia_id for update;
    if r.id is null then
      v_motivo := 'REGISTRO_NAO_ENCONTRADO';
    else
      v_atual := app.gis_ref_retrato(r);
      -- Continua exatamente como esta importação deixou? (INSERT: registro inteiro;
      -- UPDATE: os campos que ela alterou.)
      if md5(case when a.operacao = 'INSERT' then v_atual else app.gis_jsonb_subconjunto(v_atual, a.valor_anterior) end::text)
         is distinct from a.valor_novo ->> 'md5' then
        v_motivo := case when r.ultima_importacao_id is distinct from v.id then 'ALTERADO_POR_IMPORTACAO_POSTERIOR'
                         else 'ALTERADO_MANUALMENTE_DEPOIS' end;
      elsif a.operacao = 'INSERT' and exists (select 1 from public.gis_postes p where p.poste_referencia_id = r.id) then
        v_motivo := 'PROMOVIDO_A_POSTE_NICK';
      end if;
    end if;

    if v_motivo is not null then
      update staging.gis_importacao_alteracoes set motivo_nao_revertido = v_motivo where id = a.id;
      v_falha := v_falha + 1;
      continue;
    end if;

    if a.operacao = 'INSERT' then
      -- Remove só o poste que ESTA importação criou e que ninguém tocou depois.
      -- O que foi incluído continua rastreável pelo item da importação + log imutável.
      delete from public.gis_postes_referencia where id = r.id;
    else
      va := a.valor_anterior;
      update public.gis_postes_referencia set
        geom = case when va ? 'geom' then ST_SetSRID(ST_GeomFromWKB(decode(va ->> 'geom', 'hex')), 4326) else geom end,
        cidade_id = case when va ? 'cidade_id' then (va ->> 'cidade_id')::uuid else cidade_id end,
        codigo_ibge = case when va ? 'codigo_ibge' then va ->> 'codigo_ibge' else codigo_ibge end,
        situacao_fonte = case when va ? 'situacao_fonte' then va ->> 'situacao_fonte' else situacao_fonte end,
        atributos_fonte = case when va ? 'atributos_fonte' then va -> 'atributos_fonte' else atributos_fonte end,
        data_referencia = case when va ? 'data_referencia' then (va ->> 'data_referencia')::timestamptz else data_referencia end,
        ultima_coleta_em = case when va ? 'ultima_coleta_em' then (va ->> 'ultima_coleta_em')::timestamptz else ultima_coleta_em end,
        estado_sincronizacao = case when va ? 'estado_sincronizacao' then va ->> 'estado_sincronizacao' else estado_sincronizacao end,
        ultima_importacao_id = case when va ? 'ultima_importacao_id' then (va ->> 'ultima_importacao_id')::uuid else ultima_importacao_id end
      where id = r.id;
    end if;
    update staging.gis_importacao_alteracoes
       set revertido = true, revertido_em = now(), revertido_por = auth.uid(), motivo_nao_revertido = null
     where id = a.id;
    v_ok := v_ok + 1;
  end loop;

  select count(*) into v_pend from staging.gis_importacao_alteracoes where importacao_id = v.id and not revertido;
  v_status := case when v_pend = 0 then 'REVERTIDA' else 'REVERTIDA_PARCIALMENTE' end;
  update staging.gis_importacoes
     set status = v_status, revertido_por = auth.uid(), revertido_em = now(), motivo_reversao = btrim(p_motivo)
   where id = v.id;

  v_resultado := jsonb_build_object('revertidas_agora', v_ok, 'nao_revertidas', v_falha, 'pendentes', v_pend, 'status', v_status,
    'motivos', (select coalesce(jsonb_object_agg(motivo_nao_revertido, n), '{}'::jsonb) from (
                 select motivo_nao_revertido, count(*) n from staging.gis_importacao_alteracoes
                  where importacao_id = v.id and not revertido group by 1) m));
  perform app.registrar_auditoria_semantica('gis_importacoes', v.id,
    case when v_pend = 0 then 'IMPORT_REVERT' else 'IMPORT_REVERT_PARTIAL' end, btrim(p_motivo),
    jsonb_build_object('status', v.status), v_resultado, 'optimap', null);
  return v_resultado;
end;
$$;

-- ============================================================================
-- 9) Leitura (SECURITY INVOKER — a RLS do staging decide quem vê o quê)
-- ============================================================================
create or replace function app.gis_importacao_listar(p_limite integer default 50, p_offset integer default 0)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(x order by x.criado_em desc), '[]'::jsonb) from (
    select i.id, i.status, i.municipio_ibge, i.municipio_nome, i.uf, i.cidade_id, i.data_referencia, i.arquivo_nome_original,
           i.total_recebido, i.total_declarado, i.criado_em, i.criado_por, i.aprovado_em, i.revertido_em,
           f.codigo as fonte, i.resumo -> 'contagens' as contagens, (i.resumo ->> 'pode_aprovar')::boolean as pode_aprovar
      from staging.gis_importacoes i join public.gis_fontes f on f.id = i.fonte_id
     order by i.criado_em desc
     limit least(greatest(coalesce(p_limite, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0)
  ) x;
$$;

create or replace function app.gis_importacao_detalhe(p_importacao_id uuid)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select to_jsonb(i) - 'metadados'
         || jsonb_build_object(
              'fonte', f.codigo,
              'metadados_coletor', i.metadados - 'limite_municipal',
              'cidade_nome', (select c.nome from public.cidades_infra c where c.id = i.cidade_id),
              'alteracoes', (select jsonb_build_object(
                                'total', count(*),
                                'inserts', count(*) filter (where operacao = 'INSERT'),
                                'updates', count(*) filter (where operacao = 'UPDATE'),
                                'revertidas', count(*) filter (where revertido))
                               from staging.gis_importacao_alteracoes a where a.importacao_id = i.id),
              'nao_revertidas_por_motivo', (select coalesce(jsonb_object_agg(m, n), '{}'::jsonb) from (
                                select motivo_nao_revertido m, count(*) n from staging.gis_importacao_alteracoes a
                                 where a.importacao_id = i.id and not revertido and motivo_nao_revertido is not null group by 1) q))
    from staging.gis_importacoes i join public.gis_fontes f on f.id = i.fonte_id
   where i.id = p_importacao_id;
$$;

create or replace function app.gis_importacao_itens(
  p_importacao_id uuid, p_classificacao text default null, p_busca text default null,
  p_limite integer default 100, p_offset integer default 0
)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  with base as (
    select it.* from staging.gis_importacao_itens it
     where it.importacao_id = p_importacao_id
       and (p_classificacao is null or it.classificacao = p_classificacao)
       and (nullif(btrim(p_busca), '') is null or it.id_externo like btrim(p_busca) || '%')
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'itens', coalesce((select jsonb_agg(jsonb_build_object(
                'id', b.id, 'linha', b.linha, 'id_externo', b.id_externo, 'lon', b.lon, 'lat', b.lat,
                'situacao_fonte', b.situacao_fonte, 'classificacao', b.classificacao, 'motivo', b.motivo,
                'referencia_id', b.referencia_id, 'diffs', b.diffs, 'distancia_m', b.distancia_m, 'alertas', b.alertas,
                'decisao', b.decisao, 'decidido_em', b.decidido_em,
                'aplicado', exists (select 1 from staging.gis_importacao_alteracoes a where a.item_id = b.id)) order by b.linha nulls last, b.id_externo)
              from (select * from base order by linha nulls last, id_externo
                     limit least(greatest(coalesce(p_limite, 100), 1), 1000) offset greatest(coalesce(p_offset, 0), 0)) b), '[]'::jsonb));
$$;

-- GeoJSON da prévia para o mapa (pontos do arquivo + ausentes; seta de deslocamento nos atualizados).
create or replace function app.gis_importacao_previa_geojson(p_importacao_id uuid, p_classificacoes text[] default null, p_limite integer default 30000)
returns jsonb
language sql
stable
set search_path = public, extensions, pg_temp
as $$
  select jsonb_build_object('type', 'FeatureCollection', 'features', coalesce(jsonb_agg(f), '[]'::jsonb))
  from (
    select jsonb_build_object('type', 'Feature', 'id', it.id,
             'geometry', ST_AsGeoJSON(it.geom, 7)::jsonb,
             'properties', jsonb_build_object('item_id', it.id, 'id_externo', it.id_externo, 'classificacao', it.classificacao,
                                              'situacao', it.situacao_fonte, 'motivo', it.motivo, 'decisao', it.decisao,
                                              'anterior', it.diffs #> '{posicao,anterior}')) as f
      from staging.gis_importacao_itens it
     where it.importacao_id = p_importacao_id and it.geom is not null
       and (p_classificacoes is null or it.classificacao = any(p_classificacoes))
     order by case it.classificacao when 'CONFLITO' then 0 when 'NOVO' then 1 when 'ATUALIZADO' then 2 when 'AUSENTE' then 3 else 4 end, it.id
     limit least(greatest(coalesce(p_limite, 30000), 1), 50000)
  ) x;
$$;

-- ============================================================================
-- 10) Wrappers public.optimap_importacao_* (superfície do PostgREST/API)
-- ============================================================================
-- processar/aprovar/reverter levam alguns segundos numa cidade inteira (15 mil postes:
-- ~1,5 s / ~5 s / ~3 s no sandbox). O papel authenticated do Supabase tem statement_timeout
-- de 8 s; o SET na função é "hoisted" pelo PostgREST (Function Settings) e vale só para
-- estas três chamadas — o limite global do papel não é alterado.
create or replace function public.optimap_importacao_iniciar(p_metadados jsonb, p_arquivo_nome text, p_arquivo_hash text,
  p_arquivo_tamanho bigint default null, p_observacoes text default null)
returns uuid language sql security invoker as $$ select app.gis_importacao_iniciar(p_metadados, p_arquivo_nome, p_arquivo_hash, p_arquivo_tamanho, p_observacoes) $$;
create or replace function public.optimap_importacao_adicionar_itens(p_importacao_id uuid, p_itens jsonb)
returns integer language sql security invoker as $$ select app.gis_importacao_adicionar_itens(p_importacao_id, p_itens) $$;
create or replace function public.optimap_importacao_processar(p_importacao_id uuid)
returns jsonb language sql security invoker set statement_timeout = '120s' as $$ select app.gis_importacao_processar(p_importacao_id) $$;
create or replace function public.optimap_importacao_decidir(p_importacao_id uuid, p_item_ids bigint[], p_decisao text)
returns jsonb language sql security invoker as $$ select app.gis_importacao_decidir(p_importacao_id, p_item_ids, p_decisao) $$;
create or replace function public.optimap_importacao_aprovar(p_importacao_id uuid, p_confirmar_ausencias boolean default false, p_observacao text default null)
returns jsonb language sql security invoker set statement_timeout = '120s' as $$ select app.gis_importacao_aprovar(p_importacao_id, p_confirmar_ausencias, p_observacao) $$;
create or replace function public.optimap_importacao_rejeitar(p_importacao_id uuid, p_motivo text)
returns void language sql security invoker as $$ select app.gis_importacao_rejeitar(p_importacao_id, p_motivo) $$;
create or replace function public.optimap_importacao_descartar(p_importacao_id uuid, p_motivo text default null)
returns void language sql security invoker as $$ select app.gis_importacao_descartar(p_importacao_id, p_motivo) $$;
create or replace function public.optimap_importacao_reverter(p_importacao_id uuid, p_motivo text)
returns jsonb language sql security invoker set statement_timeout = '120s' as $$ select app.gis_importacao_reverter(p_importacao_id, p_motivo) $$;
create or replace function public.optimap_importacao_listar(p_limite integer default 50, p_offset integer default 0)
returns jsonb language sql stable security invoker as $$ select app.gis_importacao_listar(p_limite, p_offset) $$;
create or replace function public.optimap_importacao_detalhe(p_importacao_id uuid)
returns jsonb language sql stable security invoker as $$ select app.gis_importacao_detalhe(p_importacao_id) $$;
create or replace function public.optimap_importacao_itens(p_importacao_id uuid, p_classificacao text default null, p_busca text default null,
  p_limite integer default 100, p_offset integer default 0)
returns jsonb language sql stable security invoker as $$ select app.gis_importacao_itens(p_importacao_id, p_classificacao, p_busca, p_limite, p_offset) $$;
create or replace function public.optimap_importacao_previa_geojson(p_importacao_id uuid, p_classificacoes text[] default null, p_limite integer default 30000)
returns jsonb language sql stable security invoker as $$ select app.gis_importacao_previa_geojson(p_importacao_id, p_classificacoes, p_limite) $$;

-- ============================================================================
-- 11) Privilégios de EXECUTE
-- ============================================================================
do $$
declare
  f regprocedure;
begin
  -- Funções internas (sem checagem própria de perfil ou só usadas por outras funções): ninguém de fora.
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname in ('gis_importacao_carregar', 'gis_importacao_classificar', 'gis_importacao_digital')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  -- Funções de fluxo e leitura: só authenticated (cada uma checa perfil / RLS).
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname like 'gis\_importacao\_%'
       and p.proname not in ('gis_importacao_carregar', 'gis_importacao_classificar', 'gis_importacao_digital')
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'optimap\_importacao\_%'
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
