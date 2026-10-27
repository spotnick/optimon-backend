-- OptiMon — OptiMap Fase 5 (item 02): funções de empresas, ocupações, importação do CES e
-- categoria de cor dos postes no mapa.
--
-- Perfis (mesma matriz da Fase 4):
--   empresas: ADMINISTRADOR edita; todos que veem o mapa leem.
--   marcação "ocupado sem projeto": ENGENHARIA / ADMINISTRADOR.
--   lista do CES: enviar/processar/descartar = ENGENHARIA (próprias) / ADMINISTRADOR;
--                 decidir? (não há conflito); aprovar/rejeitar = ADMINISTRADOR / DIRETOR;
--                 reverter = ADMINISTRADOR.

-- ============================================================================
-- 1) Helpers
-- ============================================================================
create or replace function app.gis_ocup_retrato(o public.gis_ocupacoes)
returns jsonb
language sql
stable
set search_path = public, extensions, pg_temp
as $$
  select jsonb_build_object(
    'geom', encode(ST_AsBinary(o.geom), 'hex'),
    'poste_referencia_id', o.poste_referencia_id,
    'estado', o.estado,
    'data_referencia', app.gis_ts_txt(o.data_referencia),
    'ultima_importacao_id', o.ultima_importacao_id,
    'encerrado_por', o.encerrado_por,
    'encerrado_em', app.gis_ts_txt(o.encerrado_em),
    'motivo_encerramento', o.motivo_encerramento
  );
$$;

create or replace function app.gis_ces_carregar(p_id uuid, p_quem text)
returns staging.gis_ces_importacoes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v staging.gis_ces_importacoes;
  v_ok boolean;
begin
  select * into v from staging.gis_ces_importacoes where id = p_id for update;
  if v.id is null then
    raise exception 'OPTIMAP_NAO_ENCONTRADO: importação inexistente.' using errcode = 'no_data_found';
  end if;
  v_ok := case p_quem
    when 'EDITOR' then app.tem_perfil('ADMINISTRADOR') or (app.tem_perfil('ENGENHARIA') and v.criado_por = auth.uid())
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
-- 2) Empresas
-- ============================================================================
create or replace function app.gis_empresa_salvar(
  p_id uuid, p_razao_social text, p_nome_fantasia text, p_cnpj text, p_uc_copel text default null,
  p_contrato_copel text default null, p_ativa boolean default true, p_observacoes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cnpj text := regexp_replace(coalesce(p_cnpj, ''), '\D', '', 'g');
  v_uc text := nullif(regexp_replace(coalesce(p_uc_copel, ''), '\D', '', 'g'), '');
  v_id uuid;
begin
  if not app.tem_perfil('ADMINISTRADOR') then
    raise exception 'OPTIMAP_SEM_PERMISSAO: apenas ADMINISTRADOR cadastra empresas.' using errcode = 'insufficient_privilege';
  end if;
  if length(btrim(coalesce(p_razao_social, ''))) = 0 then
    raise exception 'OPTIMAP_PARAMETRO_INVALIDO: razão social obrigatória.' using errcode = 'invalid_parameter_value';
  end if;
  if v_cnpj !~ '^[0-9]{14}$' then
    raise exception 'OPTIMAP_PARAMETRO_INVALIDO: CNPJ deve ter 14 dígitos.' using errcode = 'invalid_parameter_value';
  end if;
  begin
    if p_id is null then
      insert into public.gis_empresas (razao_social, nome_fantasia, cnpj, uc_copel, contrato_copel, ativa, observacoes)
      values (btrim(p_razao_social), nullif(btrim(p_nome_fantasia), ''), v_cnpj, v_uc, nullif(btrim(p_contrato_copel), ''),
              coalesce(p_ativa, true), nullif(btrim(p_observacoes), ''))
      returning id into v_id;
    else
      update public.gis_empresas
         set razao_social = btrim(p_razao_social), nome_fantasia = nullif(btrim(p_nome_fantasia), ''), cnpj = v_cnpj,
             uc_copel = v_uc, contrato_copel = nullif(btrim(p_contrato_copel), ''), ativa = coalesce(p_ativa, true),
             observacoes = nullif(btrim(p_observacoes), '')
       where id = p_id
      returning id into v_id;
      if v_id is null then
        raise exception 'OPTIMAP_NAO_ENCONTRADO: empresa inexistente.' using errcode = 'no_data_found';
      end if;
    end if;
  exception when unique_violation then
    raise exception 'OPTIMAP_PARAMETRO_INVALIDO: já existe empresa com este CNPJ.' using errcode = 'unique_violation';
  end;
  return v_id;
end;
$$;

-- ============================================================================
-- 3) Marcação pela engenharia: "ocupamos sem projeto aprovado"
-- ============================================================================
create or replace function app.gis_ocupacao_marcar(p_poste_referencia_id uuid, p_empresa_id uuid, p_motivo text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r public.gis_postes_referencia;
  e public.gis_empresas;
  v_id uuid;
begin
  perform app.gis_exige_editor();
  if length(btrim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'OPTIMAP_MOTIVO_OBRIGATORIO: descreva a ocupação (ex.: cabo existente sem projeto, levantamento de campo de dd/mm).' using errcode = 'invalid_parameter_value';
  end if;
  select * into r from public.gis_postes_referencia where id = p_poste_referencia_id for share;
  if r.id is null then
    raise exception 'OPTIMAP_NAO_ENCONTRADO: poste inexistente.' using errcode = 'no_data_found';
  end if;
  select * into e from public.gis_empresas where id = p_empresa_id;
  if e.id is null or not e.ativa then
    raise exception 'OPTIMAP_PARAMETRO_INVALIDO: empresa inexistente ou inativa.' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from public.gis_ocupacoes o where o.empresa_id = e.id and o.id_externo = r.id_externo
              and o.tipo = 'PROJETO_APROVADO' and o.estado = 'ATIVA') then
    raise exception 'OPTIMAP_JA_OCUPADO: este poste já tem projeto aprovado no CES para %.', coalesce(e.nome_fantasia, e.razao_social)
      using errcode = 'unique_violation';
  end if;
  begin
    insert into public.gis_ocupacoes (empresa_id, id_externo, poste_referencia_id, geom, tipo, origem, estado, data_referencia, motivo)
    values (e.id, r.id_externo, r.id, r.geom, 'SEM_PROJETO', 'MARCACAO', 'ATIVA', now(), btrim(p_motivo))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'OPTIMAP_JA_OCUPADO: já existe marcação "sem projeto" ativa deste poste para %.', coalesce(e.nome_fantasia, e.razao_social)
      using errcode = 'unique_violation';
  end;
  return v_id;
end;
$$;

create or replace function app.gis_ocupacao_encerrar(p_ocupacao_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  o public.gis_ocupacoes;
begin
  perform app.gis_exige_editor();
  if length(btrim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'OPTIMAP_MOTIVO_OBRIGATORIO: informe o motivo.' using errcode = 'invalid_parameter_value';
  end if;
  select * into o from public.gis_ocupacoes where id = p_ocupacao_id for update;
  if o.id is null then
    raise exception 'OPTIMAP_NAO_ENCONTRADO: ocupação inexistente.' using errcode = 'no_data_found';
  end if;
  if o.origem <> 'MARCACAO' then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: ocupação com projeto aprovado vem do CES; ela só muda por nova lista do CES.' using errcode = 'check_violation';
  end if;
  if o.estado = 'ENCERRADA' then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: marcação já encerrada.' using errcode = 'check_violation';
  end if;
  update public.gis_ocupacoes
     set estado = 'ENCERRADA', encerrado_por = auth.uid(), encerrado_em = now(), motivo_encerramento = btrim(p_motivo)
   where id = o.id;
end;
$$;

-- ============================================================================
-- 4) Importação da lista do CES
-- ============================================================================
create or replace function app.gis_ces_iniciar(
  p_metadados jsonb, p_arquivo_nome text, p_arquivo_hash text, p_arquivo_tamanho bigint default null, p_observacoes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  e public.gis_empresas;
  v_cnpj text;
  v_coletado timestamptz;
  v_total integer;
  v_id uuid;
begin
  perform app.gis_exige_editor();
  if p_metadados is null or jsonb_typeof(p_metadados) <> 'object'
     or p_metadados ->> 'formato' is distinct from 'optimap-ocupacoes-ces/1'
     or p_metadados ->> 'fonte' is distinct from 'COPEL_CES' then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: arquivo não é uma lista do CES no formato optimap-ocupacoes-ces/1.' using errcode = 'invalid_parameter_value';
  end if;
  if p_metadados ->> 'tipo_ocupacao' is distinct from 'PROJETO_APROVADO' then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: a lista do CES só pode trazer postes com projeto aprovado.' using errcode = 'invalid_parameter_value';
  end if;
  v_cnpj := regexp_replace(coalesce(p_metadados #>> '{empresa,cnpj}', ''), '\D', '', 'g');
  select * into e from public.gis_empresas where cnpj = v_cnpj;
  if e.id is null then
    raise exception 'OPTIMAP_EMPRESA_NAO_CADASTRADA: a empresa do arquivo (CNPJ %) não está cadastrada no OptiMap.', coalesce(nullif(v_cnpj, ''), '?')
      using errcode = 'invalid_parameter_value';
  end if;
  if not e.ativa then
    raise exception 'OPTIMAP_PARAMETRO_INVALIDO: a empresa % está inativa.', e.razao_social using errcode = 'invalid_parameter_value';
  end if;
  begin
    v_coletado := (p_metadados ->> 'coletado_em')::timestamptz;
  exception when others then
    v_coletado := null;
  end;
  if v_coletado is null or v_coletado > now() + interval '1 day' or v_coletado < timestamptz '2000-01-01' then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: data da coleta (coletado_em) ausente ou inválida.' using errcode = 'invalid_parameter_value';
  end if;
  if jsonb_typeof(p_metadados -> 'total') = 'number' then
    v_total := (p_metadados ->> 'total')::numeric::integer;
  end if;
  if p_arquivo_hash is null or lower(p_arquivo_hash) !~ '^[0-9a-f]{64}$' or length(btrim(coalesce(p_arquivo_nome, ''))) = 0 then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: nome ou hash do arquivo inválido.' using errcode = 'invalid_parameter_value';
  end if;
  begin
    insert into staging.gis_ces_importacoes (empresa_id, data_referencia, arquivo_nome_original, arquivo_hash, arquivo_tamanho_bytes,
                                             metadados, total_declarado, criado_por, observacoes)
    values (e.id, v_coletado, left(btrim(p_arquivo_nome), 255), lower(p_arquivo_hash), p_arquivo_tamanho, p_metadados, v_total,
            auth.uid(), nullif(btrim(p_observacoes), ''))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'OPTIMAP_IMPORTACAO_EM_ABERTO: já existe uma lista do CES em andamento para %. Conclua, rejeite ou descarte a anterior.', e.razao_social
      using errcode = 'unique_violation';
  end;
  perform app.registrar_auditoria_semantica('gis_ces_importacoes', v_id, 'IMPORT_RECEIVE',
    format('Lista do CES recebida: %s (%s)', p_arquivo_nome, e.razao_social), null,
    jsonb_build_object('empresa_id', e.id, 'cnpj', e.cnpj, 'total_declarado', v_total, 'data_referencia', v_coletado, 'arquivo_hash', lower(p_arquivo_hash)),
    'optimap', null);
  return v_id;
end;
$$;

create or replace function app.gis_ces_adicionar_itens(p_importacao_id uuid, p_itens jsonb)
returns integer
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v staging.gis_ces_importacoes;
  v_n integer;
begin
  v := app.gis_ces_carregar(p_importacao_id, 'EDITOR');
  if v.status <> 'RECEBIDA' then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: itens só podem ser adicionados com a importação RECEBIDA (atual: %).', v.status using errcode = 'check_violation';
  end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 or jsonb_array_length(p_itens) > 2000 then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: lote vazio ou acima de 2000 itens.' using errcode = 'invalid_parameter_value';
  end if;
  if exists (select 1 from jsonb_array_elements(p_itens) x
              where jsonb_typeof(x) <> 'object' or jsonb_typeof(x -> 'linha') <> 'number'
                 or (x ->> 'linha')::numeric < 0 or (x ->> 'linha')::numeric <> trunc((x ->> 'linha')::numeric)) then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: todo item precisa de "linha" inteira não negativa.' using errcode = 'invalid_parameter_value';
  end if;
  begin
    insert into staging.gis_ces_itens (importacao_id, linha, id_externo, lon, lat, geom)
    select v.id, q.linha, q.id_externo, q.lon, q.lat,
           case when q.lon is not null and q.lat is not null and abs(q.lon) <= 180 and abs(q.lat) <= 90
                then ST_SetSRID(ST_MakePoint(q.lon, q.lat), 4326) end
      from (select (x ->> 'linha')::integer as linha,
                   nullif(left(btrim(x ->> 'id_externo'), 64), '') as id_externo,
                   case when jsonb_typeof(x -> 'lon') = 'number' then (x ->> 'lon')::double precision end as lon,
                   case when jsonb_typeof(x -> 'lat') = 'number' then (x ->> 'lat')::double precision end as lat
              from jsonb_array_elements(p_itens) x) q;
  exception when unique_violation then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: linha repetida (lote enviado duas vezes?).' using errcode = 'unique_violation';
  end;
  get diagnostics v_n = row_count;
  update staging.gis_ces_importacoes set total_recebido = total_recebido + v_n where id = v.id;
  return v.total_recebido + v_n;
end;
$$;

-- Classificação em passagem única (grava só o que mudou — sem inchaço ao recalcular).
create or replace function app.gis_ces_classificar(p_importacao_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v staging.gis_ces_importacoes;
  v_fonte_copel uuid;
  v_ativas integer;
  v_ausentes integer;
  v_validos integer;
  v_bloqueios jsonb := '[]'::jsonb;
  v_avisos jsonb := '[]'::jsonb;
  v_ultima record;
  v_resumo jsonb;
begin
  select * into v from staging.gis_ces_importacoes where id = p_importacao_id;
  select id into v_fonte_copel from public.gis_fontes where codigo = 'COPEL_MAPA_PUBLICO';

  create temporary table if not exists _gis_ces_calc (
    id bigint primary key, classificacao text, motivo text, ocupacao_id uuid, referencia_id uuid, retrato_md5 text, alertas jsonb
  ) on commit drop;
  truncate _gis_ces_calc;
  analyze staging.gis_ces_itens;

  insert into _gis_ces_calc
  with f as (
    select i.id, i.linha, i.id_externo, i.geom,
           case when i.id_externo is null then 'SEM_NUMERO_DO_POSTE'
                when i.lon is null or i.lat is null then 'SEM_COORDENADA'
                when i.geom is null or not app.gis_coordenada_valida(i.geom) then 'COORDENADA_INVALIDA' end as invalido
      from staging.gis_ces_itens i
     where i.importacao_id = v.id and i.linha is not null
  ), d as (
    select f.*, row_number() over w as n, first_value(f.linha) over w as primeira
      from f where f.invalido is null
    window w as (partition by f.id_externo order by f.linha)
  ), m as (
    select d.*, o.id as oid, o.estado as oestado, md5(app.gis_ocup_retrato(o)::text) as omd5,
           (select r.id from public.gis_postes_referencia r where r.fonte_id = v_fonte_copel and r.id_externo = d.id_externo) as rid,
           exists (select 1 from public.gis_ocupacoes s where s.empresa_id = v.empresa_id and s.id_externo = d.id_externo
                    and s.tipo = 'SEM_PROJETO' and s.estado = 'ATIVA') as tem_marcacao
      from d left join public.gis_ocupacoes o
        on o.empresa_id = v.empresa_id and o.id_externo = d.id_externo and o.tipo = 'PROJETO_APROVADO' and o.estado <> 'ENCERRADA'
     where d.n = 1
  )
  select m.id,
         case when m.oid is null then 'NOVA' when m.oestado = 'ATIVA' then 'MANTIDA' else 'REATIVADA' end,
         null, m.oid, m.rid, m.omd5,
         case when m.rid is null then jsonb_build_array(jsonb_build_object('tipo', 'FORA_DO_MAPA_PUBLICO')) else '[]'::jsonb end
         || case when m.tem_marcacao then jsonb_build_array(jsonb_build_object('tipo', 'ENCERRA_MARCACAO_SEM_PROJETO')) else '[]'::jsonb end
    from m
  union all
  select d.id, 'DUPLICADO', format('NUMERO_REPETIDO_NO_ARQUIVO (vale a linha %s)', d.primeira), null, null, null, '[]'::jsonb
    from d where d.n > 1
  union all
  select f.id, 'INVALIDO', f.invalido, null, null, null, '[]'::jsonb
    from f where f.invalido is not null;

  update staging.gis_ces_itens i
     set classificacao = c.classificacao, motivo = c.motivo, ocupacao_id = c.ocupacao_id, referencia_id = c.referencia_id,
         retrato_md5 = c.retrato_md5, alertas = c.alertas
    from _gis_ces_calc c
   where i.id = c.id
     and (i.classificacao, i.motivo, i.ocupacao_id, i.referencia_id, i.retrato_md5, i.alertas)
         is distinct from (c.classificacao, c.motivo, c.ocupacao_id, c.referencia_id, c.retrato_md5, c.alertas);

  -- Ausentes: ocupações ATIVAS com projeto aprovado desta empresa que não vieram na lista.
  create temporary table if not exists _gis_ces_aus (ocupacao_id uuid primary key, id_externo text, geom geometry, retrato_md5 text) on commit drop;
  truncate _gis_ces_aus;
  insert into _gis_ces_aus
  select o.id, o.id_externo, o.geom, md5(app.gis_ocup_retrato(o)::text)
    from public.gis_ocupacoes o
   where o.empresa_id = v.empresa_id and o.tipo = 'PROJETO_APROVADO' and o.estado = 'ATIVA'
     and not exists (select 1 from staging.gis_ces_itens i where i.importacao_id = v.id and i.linha is not null and i.id_externo = o.id_externo);
  delete from staging.gis_ces_itens i
   where i.importacao_id = v.id and i.classificacao = 'AUSENTE'
     and not exists (select 1 from _gis_ces_aus a where a.ocupacao_id = i.ocupacao_id);
  update staging.gis_ces_itens i set retrato_md5 = a.retrato_md5
    from _gis_ces_aus a
   where i.importacao_id = v.id and i.classificacao = 'AUSENTE' and i.ocupacao_id = a.ocupacao_id and i.retrato_md5 is distinct from a.retrato_md5;
  insert into staging.gis_ces_itens (importacao_id, linha, id_externo, lon, lat, geom, classificacao, ocupacao_id, retrato_md5)
  select v.id, null, a.id_externo, ST_X(a.geom), ST_Y(a.geom), a.geom, 'AUSENTE', a.ocupacao_id, a.retrato_md5
    from _gis_ces_aus a
   where not exists (select 1 from staging.gis_ces_itens i where i.importacao_id = v.id and i.classificacao = 'AUSENTE' and i.ocupacao_id = a.ocupacao_id);

  -- Resumo / bloqueios / avisos
  select count(*) into v_ativas from public.gis_ocupacoes
   where empresa_id = v.empresa_id and tipo = 'PROJETO_APROVADO' and estado = 'ATIVA';
  select count(*) filter (where classificacao = 'AUSENTE'),
         count(*) filter (where classificacao in ('NOVA', 'MANTIDA', 'REATIVADA'))
    into v_ausentes, v_validos
    from staging.gis_ces_itens where importacao_id = v.id;
  if v_validos = 0 then
    v_bloqueios := v_bloqueios || jsonb_build_object('codigo', 'NENHUM_POSTE_VALIDO', 'mensagem', 'A lista não tem nenhum poste válido.');
  end if;
  if v.total_declarado is not null and v.total_declarado <> v.total_recebido then
    v_bloqueios := v_bloqueios || jsonb_build_object('codigo', 'ARQUIVO_INCOMPLETO',
      'mensagem', format('O cabeçalho declara %s postes, mas %s foram recebidos.', v.total_declarado, v.total_recebido));
  end if;
  select id, data_referencia into v_ultima from staging.gis_ces_importacoes
   where empresa_id = v.empresa_id and status = 'IMPORTADA' and id <> v.id order by data_referencia desc limit 1;
  if v_ultima.id is not null and v_ultima.data_referencia > v.data_referencia then
    v_bloqueios := v_bloqueios || jsonb_build_object('codigo', 'COLETA_MAIS_ANTIGA_QUE_A_ULTIMA_IMPORTADA',
      'mensagem', format('Já existe lista aplicada com coleta de %s, mais recente que esta.', app.gis_ts_txt(v_ultima.data_referencia)));
  end if;
  if v_ativas >= 50 and v_ausentes > v_ativas * 0.20 then
    v_avisos := v_avisos || jsonb_build_object('codigo', 'AUSENCIA_EM_MASSA', 'exige_confirmacao', true,
      'mensagem', format('%s de %s postes com projeto aprovado desta empresa (%s%%) não vieram na lista. Confirme que a coleta está completa.',
                         v_ausentes, v_ativas, round(100.0 * v_ausentes / v_ativas)));
  end if;
  if exists (select 1 from staging.gis_ces_importacoes where arquivo_hash = v.arquivo_hash and status = 'IMPORTADA' and id <> v.id) then
    v_avisos := v_avisos || jsonb_build_object('codigo', 'ARQUIVO_JA_IMPORTADO', 'mensagem', 'Esta mesma lista (hash) já foi importada antes.');
  end if;

  select jsonb_build_object(
    'contagens', coalesce(jsonb_object_agg(c.classificacao, c.n), '{}'::jsonb),
    'alertas_por_tipo', (select coalesce(jsonb_object_agg(t, n), '{}'::jsonb) from (select a ->> 'tipo' t, count(*) n
                           from staging.gis_ces_itens, jsonb_array_elements(alertas) a where importacao_id = v.id group by 1) z),
    'ativas_antes', v_ativas,
    'total_recebido', v.total_recebido,
    'total_declarado', v.total_declarado,
    'bloqueios', v_bloqueios,
    'avisos', v_avisos,
    'pode_aprovar', jsonb_array_length(v_bloqueios) = 0
  ) into v_resumo
  from (select classificacao, count(*) n from staging.gis_ces_itens where importacao_id = v.id group by classificacao) c;

  update staging.gis_ces_importacoes set resumo = v_resumo, processado_em = now() where id = v.id;
  return v_resumo;
end;
$$;

create or replace function app.gis_ces_digital(p_importacao_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select md5(coalesce(string_agg(concat_ws('|', coalesce(linha::text, 'A'), id_externo, classificacao, motivo, ocupacao_id::text,
                                           referencia_id::text, retrato_md5, alertas::text), E'\n'
                                 order by linha nulls last, ocupacao_id), ''))
    from staging.gis_ces_itens where importacao_id = p_importacao_id;
$$;

create or replace function app.gis_ces_processar(p_importacao_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v staging.gis_ces_importacoes;
  v_resumo jsonb;
begin
  v := app.gis_ces_carregar(p_importacao_id, 'EDITOR');
  if v.status not in ('RECEBIDA', 'PREVIA') then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: só listas RECEBIDA ou PREVIA podem ser processadas (atual: %).', v.status using errcode = 'check_violation';
  end if;
  if v.total_recebido = 0 then
    raise exception 'OPTIMAP_ARQUIVO_INVALIDO: nenhum item recebido.' using errcode = 'check_violation';
  end if;
  v_resumo := app.gis_ces_classificar(v.id);
  update staging.gis_ces_importacoes set status = 'PREVIA' where id = v.id;
  perform app.registrar_auditoria_semantica('gis_ces_importacoes', v.id, 'IMPORT_PREVIEW_READY', 'Prévia da lista do CES calculada', null,
    jsonb_build_object('contagens', v_resumo -> 'contagens', 'bloqueios', v_resumo -> 'bloqueios'), 'optimap', null);
  return v_resumo;
end;
$$;

create or replace function app.gis_ces_aprovar(p_importacao_id uuid, p_confirmar_ausencias boolean default false, p_observacao text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v staging.gis_ces_importacoes;
  v_digital text;
  v_resumo jsonb;
  v_novas integer := 0;
  v_mantidas integer := 0;
  v_ausentes integer := 0;
  v_encerradas integer := 0;
  v_resultado jsonb;
begin
  v := app.gis_ces_carregar(p_importacao_id, 'APROVADOR');
  if v.status <> 'PREVIA' then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: só listas em PREVIA podem ser aprovadas (atual: %).', v.status using errcode = 'check_violation';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('optimap_ces:' || v.empresa_id, 0));
  perform 1 from public.gis_ocupacoes where empresa_id = v.empresa_id and estado <> 'ENCERRADA' for update;

  v_digital := app.gis_ces_digital(v.id);
  v_resumo := app.gis_ces_classificar(v.id);
  if app.gis_ces_digital(v.id) <> v_digital then
    raise exception 'OPTIMAP_PREVIA_DESATUALIZADA: as ocupações mudaram desde a prévia. Recalcule e revise antes de aprovar.' using errcode = 'serialization_failure';
  end if;
  if jsonb_array_length(v_resumo -> 'bloqueios') > 0 then
    raise exception 'OPTIMAP_IMPORTACAO_BLOQUEADA: %', (select string_agg(b ->> 'mensagem', ' ') from jsonb_array_elements(v_resumo -> 'bloqueios') b)
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from jsonb_array_elements(v_resumo -> 'avisos') a where (a ->> 'exige_confirmacao')::boolean)
     and not coalesce(p_confirmar_ausencias, false) then
    raise exception 'OPTIMAP_CONFIRMAR_AUSENCIAS: muitos postes com projeto aprovado não vieram na lista. Confirme explicitamente.' using errcode = 'check_violation';
  end if;

  create temporary table if not exists _gis_ces_antes (id uuid primary key, antes jsonb) on commit drop;
  truncate _gis_ces_antes;
  insert into _gis_ces_antes
  select o.id, app.gis_ocup_retrato(o) from public.gis_ocupacoes o
   where o.empresa_id = v.empresa_id and o.estado <> 'ENCERRADA'
     and (o.id in (select ocupacao_id from staging.gis_ces_itens where importacao_id = v.id and ocupacao_id is not null)
          or (o.tipo = 'SEM_PROJETO' and o.estado = 'ATIVA'));

  -- NOVA → cria ocupação (posição do mapa público quando o poste existe lá; senão a do CES)
  with ins as (
    insert into public.gis_ocupacoes (empresa_id, id_externo, poste_referencia_id, geom, tipo, origem, estado, data_referencia, ultima_importacao_id)
    select v.empresa_id, i.id_externo, i.referencia_id, coalesce(r.geom, i.geom), 'PROJETO_APROVADO', 'CES', 'ATIVA', v.data_referencia, v.id
      from staging.gis_ces_itens i left join public.gis_postes_referencia r on r.id = i.referencia_id
     where i.importacao_id = v.id and i.classificacao = 'NOVA'
     order by i.linha
    returning id, id_externo, md5(app.gis_ocup_retrato(gis_ocupacoes)::text) as impressao
  )
  insert into staging.gis_ces_alteracoes (importacao_id, item_id, ocupacao_id, id_externo, operacao, valor_anterior, valor_novo, aplicado_por)
  select v.id, i.id, ins.id, ins.id_externo, 'INSERT', null, jsonb_build_object('md5', ins.impressao), auth.uid()
    from ins join staging.gis_ces_itens i on i.importacao_id = v.id and i.classificacao = 'NOVA' and i.id_externo = ins.id_externo
   order by i.linha;
  get diagnostics v_novas = row_count;

  -- MANTIDA / REATIVADA → ATIVA, data da lista
  update public.gis_ocupacoes o
     set estado = 'ATIVA', data_referencia = v.data_referencia, ultima_importacao_id = v.id,
         poste_referencia_id = coalesce(o.poste_referencia_id, i.referencia_id)
    from staging.gis_ces_itens i
   where i.importacao_id = v.id and i.classificacao in ('MANTIDA', 'REATIVADA') and o.id = i.ocupacao_id;
  get diagnostics v_mantidas = row_count;

  -- AUSENTE → NAO_CONSTA_ULTIMA_LISTA (nunca apagada)
  update public.gis_ocupacoes o
     set estado = 'NAO_CONSTA_ULTIMA_LISTA', ultima_importacao_id = v.id
    from staging.gis_ces_itens i
   where i.importacao_id = v.id and i.classificacao = 'AUSENTE' and o.id = i.ocupacao_id;
  get diagnostics v_ausentes = row_count;

  -- Marcação "sem projeto" da mesma empresa num poste que agora tem projeto aprovado → encerrada
  update public.gis_ocupacoes o
     set estado = 'ENCERRADA', encerrado_por = auth.uid(), encerrado_em = now(),
         motivo_encerramento = 'Projeto aprovado no CES (lista de ' || to_char(v.data_referencia at time zone 'America/Sao_Paulo', 'DD/MM/YYYY') || ')'
    from staging.gis_ces_itens i
   where i.importacao_id = v.id and i.classificacao in ('NOVA', 'MANTIDA', 'REATIVADA')
     and o.empresa_id = v.empresa_id and o.id_externo = i.id_externo and o.tipo = 'SEM_PROJETO' and o.estado = 'ATIVA';
  get diagnostics v_encerradas = row_count;

  -- Log das atualizações (anterior dos campos alterados + impressão dos novos)
  insert into staging.gis_ces_alteracoes (importacao_id, item_id, ocupacao_id, id_externo, operacao, valor_anterior, valor_novo, aplicado_por)
  select v.id, x.item_id, x.id, x.id_externo, 'UPDATE',
         app.gis_jsonb_subconjunto(x.antes, app.gis_jsonb_diferenca(x.antes, x.depois)),
         jsonb_build_object('md5', md5(app.gis_jsonb_diferenca(x.antes, x.depois)::text)), auth.uid()
    from (
      select coalesce(it.id, it2.id) as item_id, o.id, o.id_externo, b.antes, app.gis_ocup_retrato(o) as depois,
             coalesce(it.linha, it2.linha) as linha
        from _gis_ces_antes b join public.gis_ocupacoes o on o.id = b.id
        left join staging.gis_ces_itens it on it.importacao_id = v.id and it.ocupacao_id = o.id
        left join staging.gis_ces_itens it2 on it.id is null and it2.importacao_id = v.id and it2.linha is not null
                                           and it2.id_externo = o.id_externo and o.tipo = 'SEM_PROJETO'
    ) x
   where x.depois is distinct from x.antes and x.item_id is not null
   order by x.linha nulls last, x.id_externo;

  update staging.gis_ces_importacoes
     set status = 'IMPORTADA', aprovado_por = auth.uid(), aprovado_em = now(), resumo = v_resumo,
         observacoes = coalesce(nullif(btrim(p_observacao), ''), observacoes)
   where id = v.id;

  v_resultado := jsonb_build_object('novas', v_novas, 'mantidas', v_mantidas, 'nao_constam', v_ausentes,
    'marcacoes_encerradas', v_encerradas,
    'alteracoes_registradas', (select count(*) from staging.gis_ces_alteracoes where importacao_id = v.id));
  perform app.registrar_auditoria_semantica('gis_ces_importacoes', v.id, 'IMPORT_APPROVE',
    coalesce(nullif(btrim(p_observacao), ''), 'Lista do CES aprovada'), jsonb_build_object('status', 'PREVIA'),
    jsonb_build_object('status', 'IMPORTADA', 'confirmou_ausencias', coalesce(p_confirmar_ausencias, false),
                       'aprovador_e_quem_enviou', v.criado_por = auth.uid()), 'optimap', null);
  perform app.registrar_auditoria_semantica('gis_ces_importacoes', v.id, 'IMPORT_APPLY', 'Ocupações do CES aplicadas', null, v_resultado, 'optimap', null);
  return v_resultado;
end;
$$;

create or replace function app.gis_ces_rejeitar(p_importacao_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v staging.gis_ces_importacoes;
begin
  v := app.gis_ces_carregar(p_importacao_id, 'APROVADOR');
  if v.status not in ('RECEBIDA', 'PREVIA') then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: só listas RECEBIDA/PREVIA podem ser rejeitadas (atual: %).', v.status using errcode = 'check_violation';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'OPTIMAP_MOTIVO_OBRIGATORIO: informe o motivo da rejeição.' using errcode = 'invalid_parameter_value';
  end if;
  update staging.gis_ces_importacoes set status = 'REJEITADA', rejeitado_por = auth.uid(), rejeitado_em = now(), motivo_rejeicao = btrim(p_motivo)
   where id = v.id;
  perform app.registrar_auditoria_semantica('gis_ces_importacoes', v.id, 'IMPORT_REJECT', btrim(p_motivo),
    jsonb_build_object('status', v.status), jsonb_build_object('status', 'REJEITADA'), 'optimap', null);
end;
$$;

create or replace function app.gis_ces_descartar(p_importacao_id uuid, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v staging.gis_ces_importacoes;
begin
  v := app.gis_ces_carregar(p_importacao_id, 'EDITOR');
  if v.status not in ('RECEBIDA', 'PREVIA') then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: só listas RECEBIDA/PREVIA podem ser descartadas (atual: %).', v.status using errcode = 'check_violation';
  end if;
  update staging.gis_ces_importacoes set status = 'DESCARTADA', descartado_por = auth.uid(), descartado_em = now() where id = v.id;
  perform app.registrar_auditoria_semantica('gis_ces_importacoes', v.id, 'IMPORT_DISCARD', nullif(btrim(p_motivo), ''),
    jsonb_build_object('status', v.status), jsonb_build_object('status', 'DESCARTADA'), 'optimap', null);
end;
$$;

create or replace function app.gis_ces_reverter(p_importacao_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v staging.gis_ces_importacoes;
  a staging.gis_ces_alteracoes;
  o public.gis_ocupacoes;
  va jsonb;
  v_atual jsonb;
  v_motivo text;
  v_ok integer := 0;
  v_falha integer := 0;
  v_pend integer;
  v_status text;
  v_resultado jsonb;
begin
  v := app.gis_ces_carregar(p_importacao_id, 'ADMIN');
  if v.status not in ('IMPORTADA', 'REVERTIDA_PARCIALMENTE') then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: só listas IMPORTADA ou REVERTIDA_PARCIALMENTE podem ser revertidas (atual: %).', v.status using errcode = 'check_violation';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then
    raise exception 'OPTIMAP_MOTIVO_OBRIGATORIO: informe o motivo da reversão.' using errcode = 'invalid_parameter_value';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('optimap_ces:' || v.empresa_id, 0));

  for a in select * from staging.gis_ces_alteracoes where importacao_id = v.id and not revertido order by ordem desc loop
    v_motivo := null;
    select * into o from public.gis_ocupacoes where id = a.ocupacao_id for update;
    if o.id is null then
      v_motivo := 'REGISTRO_NAO_ENCONTRADO';
    else
      v_atual := app.gis_ocup_retrato(o);
      if md5(case when a.operacao = 'INSERT' then v_atual else app.gis_jsonb_subconjunto(v_atual, a.valor_anterior) end::text)
         is distinct from a.valor_novo ->> 'md5' then
        v_motivo := case when o.ultima_importacao_id is distinct from v.id and o.origem = 'CES' then 'ALTERADO_POR_IMPORTACAO_POSTERIOR'
                         else 'ALTERADO_MANUALMENTE_DEPOIS' end;
      end if;
    end if;
    if v_motivo is not null then
      update staging.gis_ces_alteracoes set motivo_nao_revertido = v_motivo where id = a.id;
      v_falha := v_falha + 1;
      continue;
    end if;
    if a.operacao = 'INSERT' then
      delete from public.gis_ocupacoes where id = o.id;   -- só ocupações CES criadas por esta lista
    else
      va := a.valor_anterior;
      update public.gis_ocupacoes set
        geom = case when va ? 'geom' then ST_SetSRID(ST_GeomFromWKB(decode(va ->> 'geom', 'hex')), 4326) else geom end,
        poste_referencia_id = case when va ? 'poste_referencia_id' then (va ->> 'poste_referencia_id')::uuid else poste_referencia_id end,
        estado = case when va ? 'estado' then va ->> 'estado' else estado end,
        data_referencia = case when va ? 'data_referencia' then (va ->> 'data_referencia')::timestamptz else data_referencia end,
        ultima_importacao_id = case when va ? 'ultima_importacao_id' then (va ->> 'ultima_importacao_id')::uuid else ultima_importacao_id end,
        encerrado_por = case when va ? 'encerrado_por' then (va ->> 'encerrado_por')::uuid else encerrado_por end,
        encerrado_em = case when va ? 'encerrado_em' then (va ->> 'encerrado_em')::timestamptz else encerrado_em end,
        motivo_encerramento = case when va ? 'motivo_encerramento' then va ->> 'motivo_encerramento' else motivo_encerramento end
      where id = o.id;
    end if;
    update staging.gis_ces_alteracoes set revertido = true, revertido_em = now(), revertido_por = auth.uid(), motivo_nao_revertido = null where id = a.id;
    v_ok := v_ok + 1;
  end loop;

  select count(*) into v_pend from staging.gis_ces_alteracoes where importacao_id = v.id and not revertido;
  v_status := case when v_pend = 0 then 'REVERTIDA' else 'REVERTIDA_PARCIALMENTE' end;
  update staging.gis_ces_importacoes set status = v_status, revertido_por = auth.uid(), revertido_em = now(), motivo_reversao = btrim(p_motivo)
   where id = v.id;
  v_resultado := jsonb_build_object('revertidas_agora', v_ok, 'nao_revertidas', v_falha, 'pendentes', v_pend, 'status', v_status,
    'motivos', (select coalesce(jsonb_object_agg(motivo_nao_revertido, n), '{}'::jsonb) from (
                  select motivo_nao_revertido, count(*) n from staging.gis_ces_alteracoes where importacao_id = v.id and not revertido group by 1) z));
  perform app.registrar_auditoria_semantica('gis_ces_importacoes', v.id,
    case when v_pend = 0 then 'IMPORT_REVERT' else 'IMPORT_REVERT_PARTIAL' end, btrim(p_motivo),
    jsonb_build_object('status', v.status), v_resultado, 'optimap', null);
  return v_resultado;
end;
$$;

-- Leitura (INVOKER — RLS decide)
create or replace function app.gis_ces_listar(p_limite integer default 50, p_offset integer default 0)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(x order by x.criado_em desc), '[]'::jsonb) from (
    select i.id, i.status, i.empresa_id, e.razao_social, e.nome_fantasia, i.data_referencia, i.arquivo_nome_original,
           i.total_recebido, i.criado_em, i.criado_por, i.aprovado_em, i.revertido_em,
           i.resumo -> 'contagens' as contagens, (i.resumo ->> 'pode_aprovar')::boolean as pode_aprovar
      from staging.gis_ces_importacoes i join public.gis_empresas e on e.id = i.empresa_id
     order by i.criado_em desc
     limit least(greatest(coalesce(p_limite, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0)
  ) x;
$$;

-- Conferência por município: tabela "Consulta Pontos" do CES (gravada no arquivo da lista
-- informada, ou da última lista aplicada) × ocupações ativas no OptiMap × lote de postes do
-- OptiMon (infra_postes) da cidade.
create or replace function app.gis_ces_conferencia(p_empresa_id uuid, p_importacao_id uuid default null)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  with municipios as (
    select distinct on (gi.municipio_ibge) gi.municipio_ibge, gi.municipio_nome, gi.cidade_id
      from staging.gis_importacoes gi order by gi.municipio_ibge, gi.criado_em desc
  ), lista as (
    select coalesce(p_importacao_id,
             (select id from staging.gis_ces_importacoes where empresa_id = p_empresa_id
                 and status in ('IMPORTADA', 'REVERTIDA_PARCIALMENTE') order by data_referencia desc limit 1)) as id
  ), pontos as (
    -- ocupações ativas (origem 'A') e postes válidos da lista conferida (origem 'L')
    select 'A' as origem, o.poste_referencia_id as ref
      from public.gis_ocupacoes o
     where o.empresa_id = p_empresa_id and o.tipo = 'PROJETO_APROVADO' and o.estado = 'ATIVA'
    union all
    select 'L', it.referencia_id
      from staging.gis_ces_itens it, lista
     where it.importacao_id = lista.id and it.classificacao in ('NOVA', 'MANTIDA', 'REATIVADA')
  ), por_municipio as (
    select coalesce(c.nome, m.municipio_nome, '(poste fora do mapa público)') as municipio,
           coalesce(r.cidade_id, m.cidade_id) as cidade_id,
           count(*) filter (where p.origem = 'A') as ativas,
           count(*) filter (where p.origem = 'L') as na_lista
      from pontos p
      left join public.gis_postes_referencia r on r.id = p.ref
      left join public.cidades_infra c on c.id = r.cidade_id
      left join municipios m on m.municipio_ibge = r.codigo_ibge
     group by 1, 2
  ), ces as (
    select k as municipio_ces, (vv)::integer as n
      from staging.gis_ces_importacoes i join lista on lista.id = i.id,
           jsonb_each_text(i.metadados #> '{referencia_ces,por_cidade}') as t(k, vv)
     where i.empresa_id = p_empresa_id
  ), lotes as (
    select p.cidade_id, sum(p.quantidade) as n
      from public.infra_postes p where p.removido_em is null group by p.cidade_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'municipio', coalesce(a.municipio, ces.municipio_ces),
           'ativas_optimap', coalesce(a.ativas, 0),
           'na_lista', case when (select id from lista) is not null then coalesce(a.na_lista, 0) end,
           'tabela_ces', ces.n,
           'lote_optimap', l.n) order by coalesce(a.municipio, ces.municipio_ces)), '[]'::jsonb)
    from por_municipio a
    full join ces on app.gis_normalizar_nome(ces.municipio_ces) = app.gis_normalizar_nome(a.municipio)
    left join lotes l on l.cidade_id = a.cidade_id;
$$;

create or replace function app.gis_ces_detalhe(p_importacao_id uuid)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select to_jsonb(i) - 'metadados'
         || jsonb_build_object(
              'empresa', (select jsonb_build_object('id', e.id, 'razao_social', e.razao_social, 'nome_fantasia', e.nome_fantasia,
                                                    'cnpj', e.cnpj, 'uc_copel', e.uc_copel, 'contrato_copel', e.contrato_copel)
                            from public.gis_empresas e where e.id = i.empresa_id),
              'metadados_coletor', i.metadados,
              'alteracoes', (select jsonb_build_object('total', count(*), 'inserts', count(*) filter (where operacao = 'INSERT'),
                                                       'updates', count(*) filter (where operacao = 'UPDATE'),
                                                       'revertidas', count(*) filter (where revertido))
                               from staging.gis_ces_alteracoes a where a.importacao_id = i.id),
              'nao_revertidas_por_motivo', (select coalesce(jsonb_object_agg(m, n), '{}'::jsonb) from (
                               select motivo_nao_revertido m, count(*) n from staging.gis_ces_alteracoes a
                                where a.importacao_id = i.id and not revertido and motivo_nao_revertido is not null group by 1) q),
              'conferencia', app.gis_ces_conferencia(i.empresa_id, i.id))
    from staging.gis_ces_importacoes i
   where i.id = p_importacao_id;
$$;

create or replace function app.gis_ces_itens(p_importacao_id uuid, p_classificacao text default null, p_busca text default null,
  p_limite integer default 100, p_offset integer default 0)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  with base as (
    select it.* from staging.gis_ces_itens it
     where it.importacao_id = p_importacao_id
       and (p_classificacao is null or it.classificacao = p_classificacao)
       and (nullif(btrim(p_busca), '') is null or it.id_externo like btrim(p_busca) || '%')
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'itens', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'linha', b.linha, 'id_externo', b.id_externo, 'lon', b.lon, 'lat', b.lat,
                'classificacao', b.classificacao, 'motivo', b.motivo, 'alertas', b.alertas,
                'situacao_copel', (select r.situacao_fonte from public.gis_postes_referencia r where r.id = b.referencia_id),
                'aplicado', exists (select 1 from staging.gis_ces_alteracoes a where a.item_id = b.id)) order by b.linha nulls last, b.id_externo)
              from (select * from base order by linha nulls last, id_externo
                     limit least(greatest(coalesce(p_limite, 100), 1), 1000) offset greatest(coalesce(p_offset, 0), 0)) b), '[]'::jsonb));
$$;

create or replace function app.gis_ces_previa_geojson(p_importacao_id uuid)
returns jsonb
language sql
stable
set search_path = public, extensions, pg_temp
as $$
  select jsonb_build_object('type', 'FeatureCollection', 'features', coalesce(jsonb_agg(f), '[]'::jsonb))
  from (
    select jsonb_build_object('type', 'Feature', 'id', it.id, 'geometry', ST_AsGeoJSON(it.geom, 7)::jsonb,
             'properties', jsonb_build_object('item_id', it.id, 'id_externo', it.id_externo, 'classificacao', it.classificacao)) as f
      from staging.gis_ces_itens it
     where it.importacao_id = p_importacao_id and it.geom is not null
     limit 50000
  ) x;
$$;

-- Ocupações de um poste (painel do mapa)
create or replace function app.gis_ocupacoes_do_poste(p_poste_referencia_id uuid)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id, 'tipo', o.tipo, 'origem', o.origem, 'estado', o.estado, 'data_referencia', o.data_referencia,
           'motivo', o.motivo, 'criado_em', o.criado_em, 'criado_por', o.criado_por,
           'encerrado_em', o.encerrado_em, 'motivo_encerramento', o.motivo_encerramento,
           'empresa', jsonb_build_object('id', e.id, 'razao_social', e.razao_social, 'nome_fantasia', e.nome_fantasia,
                                         'cnpj', e.cnpj, 'uc_copel', e.uc_copel, 'contrato_copel', e.contrato_copel))
           order by (o.estado = 'ATIVA') desc, o.tipo, o.criado_em desc), '[]'::jsonb)
    from public.gis_ocupacoes o join public.gis_empresas e on e.id = o.empresa_id
   where o.poste_referencia_id = p_poste_referencia_id
      or o.id_externo = (select r.id_externo from public.gis_postes_referencia r where r.id = p_poste_referencia_id);
$$;

-- ============================================================================
-- 5) Mapa: categoria de cor dos postes de referência (CREATE OR REPLACE aditivo de
--    app.gis_tile — só a camada postes_referencia ganha 'categoria', 'cat_fonte', 'emp_ap',
--    'emp_sp' (e 'ocupados' no agregado);
--    as demais camadas ficam exatamente como na Fase 2).
--    Prioridade: PROJETO_APROVADO > SEM_PROJETO > INDISPONIVEL > POSSIVEL > DISPONIVEL > OUTRO.
-- ============================================================================
create or replace function app.gis_categoria_poste(p_situacao text, p_aprovado boolean, p_sem_projeto boolean)
returns text
language sql
immutable
parallel safe
as $$
  select case
    when p_aprovado then 'PROJETO_APROVADO'
    when p_sem_projeto then 'SEM_PROJETO'
    when app.gis_normalizar_nome(p_situacao) = 'indisponivel' then 'INDISPONIVEL'
    when app.gis_normalizar_nome(p_situacao) like 'possivel%' then 'POSSIVEL'
    when app.gis_normalizar_nome(p_situacao) = 'disponivel' then 'DISPONIVEL'
    else 'OUTRO' end;
$$;

create or replace function app.gis_tile(p_camada text, p_z integer, p_x integer, p_y integer, p_cidade_id uuid default null)
returns bytea
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_env3857 geometry;
  v_env4326 geometry;
  v_mvt bytea;
  v_limite constant integer := 20000;
  v_cel double precision;
begin
  if p_z < 0 or p_z > 22 or p_x < 0 or p_y < 0 or p_x >= (1 << p_z) or p_y >= (1 << p_z) then
    raise exception 'OPTIMAP_TILE_INVALIDO: z/x/y fora do intervalo.' using errcode = 'invalid_parameter_value';
  end if;
  if not app.gis_pode_ver() then
    return ''::bytea;
  end if;
  if (p_camada = 'postes_referencia' and p_z < 12) or (p_camada in ('postes', 'elementos', 'trechos') and p_z < 8) then
    return ''::bytea;
  end if;
  v_env3857 := ST_TileEnvelope(p_z, p_x, p_y);
  v_env4326 := ST_Transform(v_env3857, 4326);

  if p_camada = 'postes_referencia' then
    if p_z < 15 then
      v_cel := (ST_XMax(v_env3857) - ST_XMin(v_env3857)) / 16.0;
      select ST_AsMVT(q, 'postes_referencia_agregado', 4096, 'mvt_geom') into v_mvt from (
        select ST_AsMVTGeom(ST_Centroid(ST_Collect(ST_Transform(r.geom, 3857))), v_env3857, 4096, 64, true) as mvt_geom,
               count(*)::integer as quantidade,
               count(oc.poste_referencia_id)::integer as ocupados
        from public.gis_postes_referencia r
        left join (select distinct o.poste_referencia_id from public.gis_ocupacoes o
                    where o.estado = 'ATIVA' and o.poste_referencia_id is not null and o.geom && v_env4326) oc
               on oc.poste_referencia_id = r.id
        where r.geom && v_env4326 and (p_cidade_id is null or r.cidade_id = p_cidade_id)
        group by ST_SnapToGrid(ST_Transform(r.geom, 3857), v_cel, v_cel)
      ) q;
    else
      select ST_AsMVT(q, 'postes_referencia', 4096, 'mvt_geom') into v_mvt from (
        select ST_AsMVTGeom(ST_Transform(r.geom, 3857), v_env3857, 4096, 64, true) as mvt_geom,
               r.id::text as id, r.id_externo, r.situacao_fonte, r.estado_sincronizacao,
               exists (select 1 from public.gis_postes gp where gp.poste_referencia_id = r.id and gp.removido_em is null) as usado_pela_nick,
               app.gis_categoria_poste(r.situacao_fonte, oc.emp_ap is not null, oc.emp_sp is not null) as categoria,
               app.gis_categoria_poste(r.situacao_fonte, false, false) as cat_fonte,
               coalesce(oc.emp_ap, '') as emp_ap,
               coalesce(oc.emp_sp, '') as emp_sp
        from public.gis_postes_referencia r
        left join lateral (
          -- "|uuid|uuid|": o filtro por empresa do mapa recalcula a cor no cliente.
          select '|' || string_agg(distinct o.empresa_id::text, '|') filter (where o.tipo = 'PROJETO_APROVADO') || '|' as emp_ap,
                 '|' || string_agg(distinct o.empresa_id::text, '|') filter (where o.tipo = 'SEM_PROJETO') || '|' as emp_sp
            from public.gis_ocupacoes o where o.poste_referencia_id = r.id and o.estado = 'ATIVA'
        ) oc on true
        where r.geom && v_env4326 and (p_cidade_id is null or r.cidade_id = p_cidade_id)
        limit v_limite
      ) q;
    end if;

  elsif p_camada = 'postes' then
    select ST_AsMVT(q, 'postes', 4096, 'mvt_geom') into v_mvt from (
      select ST_AsMVTGeom(ST_Transform(p.geom, 3857), v_env3857, 4096, 64, true) as mvt_geom,
             p.id::text as id, p.codigo, p.estado, (p.poste_referencia_id is not null) as tem_referencia
      from public.gis_postes p
      where p.removido_em is null and p.geom && v_env4326 and (p_cidade_id is null or p.cidade_id = p_cidade_id)
      limit v_limite
    ) q;

  elsif p_camada = 'elementos' then
    select ST_AsMVT(q, 'elementos', 4096, 'mvt_geom') into v_mvt from (
      select ST_AsMVTGeom(ST_Transform(e.geom, 3857), v_env3857, 4096, 64, true) as mvt_geom,
             e.id::text as id, e.tipo, e.codigo, e.nome, e.estado
      from public.gis_elementos e
      where e.removido_em is null and e.geom && v_env4326 and (p_cidade_id is null or e.cidade_id = p_cidade_id)
      limit v_limite
    ) q;

  elsif p_camada = 'trechos' then
    select ST_AsMVT(q, 'trechos', 4096, 'mvt_geom') into v_mvt from (
      select ST_AsMVTGeom(ST_Transform(t.geom, 3857), v_env3857, 4096, 64, true) as mvt_geom,
             t.id::text as id, t.codigo, t.estado, t.tipo_instalacao, t.comprimento_geo_m::double precision as comprimento_m
      from public.gis_trechos t
      where t.removido_em is null and t.geom && v_env4326 and (p_cidade_id is null or t.cidade_id = p_cidade_id)
      limit v_limite
    ) q;

  elsif p_camada = 'pops' then
    select ST_AsMVT(q, 'pops', 4096, 'mvt_geom') into v_mvt from (
      select ST_AsMVTGeom(ST_Transform(p.geom, 3857), v_env3857, 4096, 64, true) as mvt_geom,
             p.id::text as id, p.codigo, p.nome, p.tipo, p.status
      from public.vw_gis_pops p
      where p.geom && v_env4326 and (p_cidade_id is null or p.cidade_id = p_cidade_id)
      limit v_limite
    ) q;

  else
    raise exception 'OPTIMAP_CAMADA_INVALIDA: %.', p_camada using errcode = 'invalid_parameter_value';
  end if;

  return coalesce(v_mvt, ''::bytea);
end;
$$;
revoke all on function app.gis_tile(text, integer, integer, integer, uuid) from public;
grant execute on function app.gis_tile(text, integer, integer, integer, uuid) to authenticated;

-- ============================================================================
-- 6) Wrappers public.optimap_* (superfície do PostgREST/API)
-- ============================================================================
create or replace function public.optimap_empresa_salvar(p_id uuid, p_razao_social text, p_nome_fantasia text, p_cnpj text,
  p_uc_copel text default null, p_contrato_copel text default null, p_ativa boolean default true, p_observacoes text default null)
returns uuid language sql security invoker as $$
  select app.gis_empresa_salvar(p_id, p_razao_social, p_nome_fantasia, p_cnpj, p_uc_copel, p_contrato_copel, p_ativa, p_observacoes) $$;
create or replace function public.optimap_ocupacao_marcar(p_poste_referencia_id uuid, p_empresa_id uuid, p_motivo text)
returns uuid language sql security invoker as $$ select app.gis_ocupacao_marcar(p_poste_referencia_id, p_empresa_id, p_motivo) $$;
create or replace function public.optimap_ocupacao_encerrar(p_ocupacao_id uuid, p_motivo text)
returns void language sql security invoker as $$ select app.gis_ocupacao_encerrar(p_ocupacao_id, p_motivo) $$;
create or replace function public.optimap_ocupacoes_do_poste(p_poste_referencia_id uuid)
returns jsonb language sql stable security invoker as $$ select app.gis_ocupacoes_do_poste(p_poste_referencia_id) $$;
create or replace function public.optimap_ces_iniciar(p_metadados jsonb, p_arquivo_nome text, p_arquivo_hash text,
  p_arquivo_tamanho bigint default null, p_observacoes text default null)
returns uuid language sql security invoker as $$ select app.gis_ces_iniciar(p_metadados, p_arquivo_nome, p_arquivo_hash, p_arquivo_tamanho, p_observacoes) $$;
create or replace function public.optimap_ces_adicionar_itens(p_importacao_id uuid, p_itens jsonb)
returns integer language sql security invoker as $$ select app.gis_ces_adicionar_itens(p_importacao_id, p_itens) $$;
create or replace function public.optimap_ces_processar(p_importacao_id uuid)
returns jsonb language sql security invoker set statement_timeout = '120s' as $$ select app.gis_ces_processar(p_importacao_id) $$;
create or replace function public.optimap_ces_aprovar(p_importacao_id uuid, p_confirmar_ausencias boolean default false, p_observacao text default null)
returns jsonb language sql security invoker set statement_timeout = '120s' as $$ select app.gis_ces_aprovar(p_importacao_id, p_confirmar_ausencias, p_observacao) $$;
create or replace function public.optimap_ces_rejeitar(p_importacao_id uuid, p_motivo text)
returns void language sql security invoker as $$ select app.gis_ces_rejeitar(p_importacao_id, p_motivo) $$;
create or replace function public.optimap_ces_descartar(p_importacao_id uuid, p_motivo text default null)
returns void language sql security invoker as $$ select app.gis_ces_descartar(p_importacao_id, p_motivo) $$;
create or replace function public.optimap_ces_reverter(p_importacao_id uuid, p_motivo text)
returns jsonb language sql security invoker set statement_timeout = '120s' as $$ select app.gis_ces_reverter(p_importacao_id, p_motivo) $$;
create or replace function public.optimap_ces_listar(p_limite integer default 50, p_offset integer default 0)
returns jsonb language sql stable security invoker as $$ select app.gis_ces_listar(p_limite, p_offset) $$;
create or replace function public.optimap_ces_detalhe(p_importacao_id uuid)
returns jsonb language sql stable security invoker as $$ select app.gis_ces_detalhe(p_importacao_id) $$;
create or replace function public.optimap_ces_itens(p_importacao_id uuid, p_classificacao text default null, p_busca text default null,
  p_limite integer default 100, p_offset integer default 0)
returns jsonb language sql stable security invoker as $$ select app.gis_ces_itens(p_importacao_id, p_classificacao, p_busca, p_limite, p_offset) $$;
create or replace function public.optimap_ces_previa_geojson(p_importacao_id uuid)
returns jsonb language sql stable security invoker as $$ select app.gis_ces_previa_geojson(p_importacao_id) $$;
create or replace function public.optimap_ces_conferencia(p_empresa_id uuid)
returns jsonb language sql stable security invoker as $$ select app.gis_ces_conferencia(p_empresa_id, null) $$;

-- ============================================================================
-- 7) EXECUTE
-- ============================================================================
do $$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname in ('gis_ces_carregar', 'gis_ces_classificar', 'gis_ces_digital')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app'
       and (p.proname like 'gis\_ces\_%' or p.proname in ('gis_empresa_salvar', 'gis_ocupacao_marcar', 'gis_ocupacao_encerrar', 'gis_ocupacoes_do_poste'))
       and p.proname not in ('gis_ces_carregar', 'gis_ces_classificar', 'gis_ces_digital')
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'optimap\_ces\_%' or p.proname in ('optimap_empresa_salvar', 'optimap_ocupacao_marcar', 'optimap_ocupacao_encerrar', 'optimap_ocupacoes_do_poste'))
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
