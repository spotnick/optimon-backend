-- OptiMon — OptiMap Fase 2 (fundação geográfica) — Migration 3/4: regras, funções de
-- escrita controlada e consultas geográficas.
--
-- Aditiva. Nenhuma função existente é substituída. Nada aqui escreve em tabela oficial
-- existente (cidades_infra, infra_*, contrato_fibras) — só lê, para validar vínculos.
--
-- Modelo de escrita (endurecido após revisão independente):
--   * NENHUMA escrita direta: authenticated não tem INSERT/UPDATE/DELETE em gis_postes,
--     gis_elementos, gis_trechos, gis_trecho_postes (Migration 4). Toda alteração da rede
--     passa pelas funções app.gis_* (SECURITY DEFINER, search_path fixo) que checam o perfil
--     (app.gis_exige_editor) e as regras de negócio — impossível contorná-las via PostgREST.
--   * Os triggers abaixo reforçam as invariantes mesmo assim (defesa em profundidade).
--   * Leituras espaciais (tile/bbox/busca) também são SECURITY DEFINER, aplicando a mesma
--     regra de perfil das policies (app.gis_pode_ver) — ver seção 5.
--   * Wrappers finos em public.optimap_* são a superfície do PostgREST/API.

-- ============================================================================
-- 1) Integridade
-- ============================================================================

-- 1.1 gis_postes_referencia só aceita fonte EXTERNA (dado próprio nunca entra como
--     "referência", e referência nunca é confundida com rede da NICK).
create or replace function app.fn_gis_ref_exige_fonte_externa()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  if not exists (select 1 from public.gis_fontes f where f.id = new.fonte_id and f.tipo = 'EXTERNA') then
    raise exception 'OPTIMAP_FONTE_INVALIDA: gis_postes_referencia exige fonte do tipo EXTERNA.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger trg_gis_ref_exige_fonte_externa
  before insert or update of fonte_id on public.gis_postes_referencia
  for each row execute function app.fn_gis_ref_exige_fonte_externa();

-- 1.2 Consistência de vínculos.
--   * Elemento/poste: mesma cidade do POP, do poste e do lote de faturamento.
--   * Trecho: segmento/cabo coerentes e da mesma cidade do trecho. As PONTAS podem estar em
--     outra cidade (backbone intermunicipal, ex.: CNE-JSR cadastrado em Jussara com origem
--     em Cianorte), mas precisam existir e estar ativas.
--   * Referências a poste/trecho/elemento são travadas com FOR SHARE: impede a corrida
--     "arquivar o poste" × "ligar um elemento a ele" em transações simultâneas (o
--     arquivamento trava a linha com FOR UPDATE — ver app.gis_arquivar).
create or replace function app.fn_gis_valida_vinculos()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
declare
  v_cidade uuid;
  v_seg uuid;
begin
  if tg_table_name = 'gis_postes' then
    if new.infra_poste_lote_id is not null then
      select cidade_id into v_cidade from public.infra_postes where id = new.infra_poste_lote_id and removido_em is null;
      if v_cidade is distinct from new.cidade_id then
        raise exception 'OPTIMAP_VINCULO_INVALIDO: o lote de postes (infra_postes) não existe, está arquivado ou pertence a outra cidade.' using errcode = 'check_violation';
      end if;
    end if;

  elsif tg_table_name = 'gis_elementos' then
    if new.pop_id is not null then
      select cidade_id into v_cidade from public.infra_pops where id = new.pop_id and removido_em is null;
      if v_cidade is distinct from new.cidade_id then
        raise exception 'OPTIMAP_VINCULO_INVALIDO: o POP não existe, está arquivado ou pertence a outra cidade.' using errcode = 'check_violation';
      end if;
    end if;
    if new.poste_id is not null then
      select cidade_id into v_cidade from public.gis_postes where id = new.poste_id and removido_em is null for share;
      if v_cidade is null then
        raise exception 'OPTIMAP_VINCULO_INVALIDO: poste inexistente ou arquivado.' using errcode = 'check_violation';
      end if;
      if v_cidade <> new.cidade_id then
        raise exception 'OPTIMAP_VINCULO_INVALIDO: o poste pertence a outra cidade.' using errcode = 'check_violation';
      end if;
    end if;

  elsif tg_table_name = 'gis_trechos' then
    -- Cabo informado sem segmento: herda o segmento do próprio cabo.
    if new.cabo_id is not null then
      select segmento_id into v_seg from public.infra_cabos where id = new.cabo_id and removido_em is null;
      if v_seg is null then
        raise exception 'OPTIMAP_VINCULO_INVALIDO: cabo inexistente ou arquivado.' using errcode = 'check_violation';
      end if;
      if new.segmento_id is null then
        new.segmento_id := v_seg;
      elsif v_seg <> new.segmento_id then
        raise exception 'OPTIMAP_VINCULO_INVALIDO: o cabo não pertence ao segmento informado.' using errcode = 'check_violation';
      end if;
    end if;
    if new.segmento_id is not null then
      select cidade_id into v_cidade from public.infra_segmentos where id = new.segmento_id and removido_em is null;
      if v_cidade is distinct from new.cidade_id then
        raise exception 'OPTIMAP_VINCULO_INVALIDO: o segmento não existe, está arquivado ou pertence a outra cidade.' using errcode = 'check_violation';
      end if;
    end if;
    if new.ponta_a_elemento_id is not null and new.ponta_a_elemento_id = new.ponta_b_elemento_id then
      raise exception 'OPTIMAP_VINCULO_INVALIDO: as duas pontas do trecho são o mesmo elemento.' using errcode = 'check_violation';
    end if;
    if new.ponta_a_pop_id is not null and new.ponta_a_pop_id = new.ponta_b_pop_id then
      raise exception 'OPTIMAP_VINCULO_INVALIDO: as duas pontas do trecho são o mesmo POP.' using errcode = 'check_violation';
    end if;
    if (new.ponta_a_elemento_id is not null and not exists (select 1 from public.gis_elementos where id = new.ponta_a_elemento_id and removido_em is null for share))
       or (new.ponta_b_elemento_id is not null and not exists (select 1 from public.gis_elementos where id = new.ponta_b_elemento_id and removido_em is null for share)) then
      raise exception 'OPTIMAP_VINCULO_INVALIDO: elemento de ponta inexistente ou arquivado.' using errcode = 'check_violation';
    end if;
    if (new.ponta_a_pop_id is not null and not exists (select 1 from public.infra_pops where id = new.ponta_a_pop_id and removido_em is null))
       or (new.ponta_b_pop_id is not null and not exists (select 1 from public.infra_pops where id = new.ponta_b_pop_id and removido_em is null)) then
      raise exception 'OPTIMAP_VINCULO_INVALIDO: POP de ponta inexistente ou arquivado.' using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;
create trigger trg_gis_postes_vinculos before insert or update on public.gis_postes
  for each row execute function app.fn_gis_valida_vinculos();
create trigger trg_gis_elementos_vinculos before insert or update on public.gis_elementos
  for each row execute function app.fn_gis_valida_vinculos();
create trigger trg_gis_trechos_vinculos before insert or update on public.gis_trechos
  for each row execute function app.fn_gis_valida_vinculos();

-- 1.3 gis_trecho_postes: só postes e trechos ativos (travados com FOR SHARE). Poste de outra
--     cidade é permitido DE PROPÓSITO: um backbone intermunicipal (ex.: CNE-JSR) passa por
--     postes das duas cidades, mas o trecho/segmento é cadastrado em uma só.
create or replace function app.fn_gis_trecho_poste_ativo()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  if not exists (select 1 from public.gis_postes where id = new.poste_id and removido_em is null for share) then
    raise exception 'OPTIMAP_VINCULO_INVALIDO: poste inexistente ou arquivado.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.gis_trechos where id = new.trecho_id and removido_em is null for share) then
    raise exception 'OPTIMAP_VINCULO_INVALIDO: trecho inexistente ou arquivado.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger trg_gis_trecho_postes_ativo before insert or update on public.gis_trecho_postes
  for each row execute function app.fn_gis_trecho_poste_ativo();

-- 1.3b Alterar a sequência de postes de um trecho VALIDADO o rebaixa (validação era sobre
--      o percurso anterior).
create or replace function app.fn_gis_trecho_postes_rebaixa()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
declare
  v_trecho uuid := coalesce(new.trecho_id, old.trecho_id);
begin
  if exists (select 1 from public.gis_trechos where id = v_trecho and estado = 'VALIDADO') then
    perform set_config('optimap.motivo', coalesce(nullif(current_setting('optimap.motivo', true), ''),
                       'Sequência de postes do trecho alterada — requer nova validação.'), true);
    update public.gis_trechos set estado = 'DOCUMENTADO' where id = v_trecho and estado = 'VALIDADO';
  end if;
  return null;
end;
$$;
create trigger trg_gis_trecho_postes_rebaixa after insert or update or delete on public.gis_trecho_postes
  for each row execute function app.fn_gis_trecho_postes_rebaixa();

-- 1.3c gis_fontes.tipo é imutável (uma fonte EXTERNA nunca vira PROPRIA, nem o contrário —
--      isso reclassificaria silenciosamente todos os dados já importados dela).
create or replace function app.fn_gis_fonte_tipo_imutavel()
returns trigger
language plpgsql
as $$
begin
  if new.tipo is distinct from old.tipo or new.codigo is distinct from old.codigo then
    raise exception 'OPTIMAP_FONTE_IMUTAVEL: tipo e código de uma fonte não podem ser alterados; crie uma nova fonte.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger trg_gis_fonte_tipo_imutavel before update on public.gis_fontes
  for each row execute function app.fn_gis_fonte_tipo_imutavel();

-- 1.4 Ciclo de estado (PLANEJADO / DOCUMENTADO / VALIDADO / DESATIVADO) e autoria
--   * nenhum registro nasce VALIDADO — validação é sempre um ato posterior e separado;
--   * criado_por = usuário autenticado no INSERT e imutável depois (não forjável);
--   * entrar em VALIDADO grava validado_por/validado_em (usuário autenticado obrigatório);
--   * sair de VALIDADO limpa validado_*; enquanto VALIDADO, validado_* não mudam;
--   * mudar a geometria (inclusive só a direção do traçado — ST_OrderingEquals) ou
--     qualquer vínculo físico (cidade, poste, POP, lote, referência, cabo, segmento,
--     pontas, tipo) de algo VALIDADO o rebaixa para DOCUMENTADO.
create or replace function app.fn_gis_ciclo_estado()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
declare
  v_cols text[];
  c text;
  v_mudou boolean := false;
begin
  if tg_op = 'INSERT' then
    if new.estado = 'VALIDADO' then
      raise exception 'OPTIMAP_ESTADO_INVALIDO: registro não pode nascer VALIDADO; valide em ato separado (app.gis_alterar_estado).' using errcode = 'check_violation';
    end if;
    new.criado_por := auth.uid();
    new.validado_por := null;
    new.validado_em := null;
    return new;
  end if;

  new.criado_por := old.criado_por;

  if old.estado = 'VALIDADO' and new.estado = 'VALIDADO' then
    v_mudou := not ST_OrderingEquals(old.geom, new.geom);
    v_cols := case tg_table_name
      when 'gis_postes'    then array['cidade_id', 'poste_referencia_id', 'infra_poste_lote_id']
      when 'gis_elementos' then array['cidade_id', 'tipo', 'poste_id', 'pop_id']
      when 'gis_trechos'   then array['cidade_id', 'cabo_id', 'segmento_id', 'ponta_a_elemento_id', 'ponta_a_pop_id',
                                      'ponta_b_elemento_id', 'ponta_b_pop_id', 'tipo_instalacao']
    end;
    foreach c in array v_cols loop
      v_mudou := v_mudou or (to_jsonb(old) -> c) is distinct from (to_jsonb(new) -> c);
    end loop;
    if v_mudou then
      new.estado := 'DOCUMENTADO';
      perform set_config('optimap.motivo', coalesce(nullif(current_setting('optimap.motivo', true), ''), 'Posição ou vínculo alterado — requer nova validação.'), true);
    end if;
  end if;

  if new.estado = 'VALIDADO' and old.estado is distinct from 'VALIDADO' then
    if auth.uid() is null then
      raise exception 'OPTIMAP_ESTADO_INVALIDO: validação exige usuário autenticado.' using errcode = 'insufficient_privilege';
    end if;
    new.validado_por := auth.uid();
    new.validado_em := now();
  elsif new.estado <> 'VALIDADO' then
    new.validado_por := null;
    new.validado_em := null;
  else
    new.validado_por := old.validado_por;
    new.validado_em := old.validado_em;
  end if;
  return new;
end;
$$;
create trigger trg_gis_postes_ciclo_estado before insert or update on public.gis_postes
  for each row execute function app.fn_gis_ciclo_estado();
create trigger trg_gis_elementos_ciclo_estado before insert or update on public.gis_elementos
  for each row execute function app.fn_gis_ciclo_estado();
create trigger trg_gis_trechos_ciclo_estado before insert or update on public.gis_trechos
  for each row execute function app.fn_gis_ciclo_estado();

-- 1.5 Histórico de estado → gis_validacoes (security definer: só este trigger escreve lá).
create or replace function app.fn_gis_historico_estado()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_evid uuid;
begin
  begin
    v_evid := nullif(current_setting('optimap.evidencia_documento_id', true), '')::uuid;
  exception when others then
    v_evid := null;
  end;
  insert into public.gis_validacoes (entidade, entidade_id, estado_anterior, estado_novo, motivo, evidencia_documento_id, usuario_id)
  values (tg_table_name, new.id,
          case when tg_op = 'INSERT' then null else old.estado end,
          new.estado,
          nullif(current_setting('optimap.motivo', true), ''),
          v_evid,
          auth.uid());
  return null;
end;
$$;
revoke all on function app.fn_gis_historico_estado() from public;

create trigger trg_gis_postes_historico_ins after insert on public.gis_postes
  for each row execute function app.fn_gis_historico_estado();
create trigger trg_gis_postes_historico_upd after update on public.gis_postes
  for each row when (old.estado is distinct from new.estado) execute function app.fn_gis_historico_estado();
create trigger trg_gis_elementos_historico_ins after insert on public.gis_elementos
  for each row execute function app.fn_gis_historico_estado();
create trigger trg_gis_elementos_historico_upd after update on public.gis_elementos
  for each row when (old.estado is distinct from new.estado) execute function app.fn_gis_historico_estado();
create trigger trg_gis_trechos_historico_ins after insert on public.gis_trechos
  for each row execute function app.fn_gis_historico_estado();
create trigger trg_gis_trechos_historico_upd after update on public.gis_trechos
  for each row when (old.estado is distinct from new.estado) execute function app.fn_gis_historico_estado();

-- 1.6 gis_validacoes é imutável (mesmo padrão de public.auditoria).
create or replace function app.fn_gis_validacoes_imutavel()
returns trigger
language plpgsql
as $$
begin
  raise exception 'OPTIMAP_HISTORICO_IMUTAVEL: gis_validacoes não aceita UPDATE/DELETE.' using errcode = 'insufficient_privilege';
end;
$$;
create trigger trg_gis_validacoes_imutavel before update or delete on public.gis_validacoes
  for each row execute function app.fn_gis_validacoes_imutavel();

-- ============================================================================
-- 2) Helpers
-- ============================================================================

create or replace function app.gis_ponto(p_lon double precision, p_lat double precision)
returns geometry
language sql
immutable
set search_path = public, extensions, pg_temp
as $$ select ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326); $$;

-- GeoJSON (objeto geometry) → geometry 4326, com tipo esperado.
create or replace function app.gis_geom_de_geojson(p_geojson jsonb, p_tipo_esperado text)
returns geometry
language plpgsql
immutable
set search_path = public, extensions, pg_temp
as $$
declare
  g geometry;
begin
  if p_geojson is null or jsonb_typeof(p_geojson) <> 'object' then
    raise exception 'OPTIMAP_GEOMETRIA_INVALIDA: GeoJSON ausente.' using errcode = 'invalid_parameter_value';
  end if;
  begin
    -- ST_Force2D: GeoJSON com altitude (Z) ou medida (M) é aceito e reduzido a 2D.
    g := ST_SetSRID(ST_Force2D(ST_GeomFromGeoJSON(p_geojson::text)), 4326);
  exception when others then
    raise exception 'OPTIMAP_GEOMETRIA_INVALIDA: GeoJSON não reconhecido (%).', sqlerrm using errcode = 'invalid_parameter_value';
  end;
  if GeometryType(g) <> upper(p_tipo_esperado) then
    raise exception 'OPTIMAP_GEOMETRIA_INVALIDA: esperado %, recebido %.', upper(p_tipo_esperado), GeometryType(g) using errcode = 'invalid_parameter_value';
  end if;
  if not app.gis_coordenada_valida(g) then
    raise exception 'OPTIMAP_GEOMETRIA_INVALIDA: coordenadas inválidas ou fora do Brasil.' using errcode = 'invalid_parameter_value';
  end if;
  return g;
end;
$$;

create or replace function app.gis_fonte_id(p_codigo text, p_exigir_propria boolean default true)
returns uuid
language plpgsql
stable
set search_path = public, extensions, pg_temp
as $$
declare
  v_id uuid;
  v_tipo text;
begin
  select id, tipo into v_id, v_tipo from public.gis_fontes where codigo = p_codigo and ativa;
  if v_id is null then
    raise exception 'OPTIMAP_FONTE_INVALIDA: fonte % inexistente ou inativa.', p_codigo using errcode = 'invalid_parameter_value';
  end if;
  if p_exigir_propria and v_tipo <> 'PROPRIA' then
    raise exception 'OPTIMAP_FONTE_INVALIDA: cadastro manual exige fonte PROPRIA (recebido %). Para usar um poste externo, promova-o (app.gis_promover_poste_referencia).', p_codigo using errcode = 'invalid_parameter_value';
  end if;
  return v_id;
end;
$$;

-- Fonte ÚNICA das regras de acesso do OptiMap: usada pelas policies de RLS (Migration 4) e
-- pelas funções de leitura espacial security definer abaixo — nunca duas listas de perfis.
create or replace function app.gis_pode_ver()
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$ select coalesce(app.tem_perfil('ADMINISTRADOR', 'DIRETOR', 'ENGENHARIA', 'COMERCIAL', 'AUDITOR'), false) $$;
comment on function app.gis_pode_ver() is 'OptiMap: perfis que veem o mapa (rede própria + referências). FINANCEIRO e usuários sem perfil ativo: não.';

create or replace function app.gis_pode_editar()
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$ select coalesce(app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR'), false) $$;
comment on function app.gis_pode_editar() is 'OptiMap: perfis que cadastram/editam/validam a rede própria.';

create or replace function app.gis_exige_editor()
returns void
language plpgsql
stable
set search_path = public, pg_temp
as $$
begin
  if not app.gis_pode_editar() then
    raise exception 'OPTIMAP_SEM_PERMISSAO: apenas ENGENHARIA ou ADMINISTRADOR podem alterar a rede no OptiMap.' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

-- ============================================================================
-- 3) Escrita controlada — ÚNICO caminho de escrita da rede própria.
--    SECURITY DEFINER + app.gis_exige_editor() + search_path fixo. Cada função zera o
--    contexto (optimap.motivo / optimap.evidencia_documento_id) logo no início, para que um
--    valor definido antes na mesma sessão nunca seja gravado no histórico por engano.
-- ============================================================================

create or replace function app.gis_zerar_contexto()
returns void
language sql
set search_path = public, pg_temp
as $$
  select set_config('optimap.motivo', '', true), set_config('optimap.evidencia_documento_id', '', true);
$$;

create or replace function app.gis_criar_poste(
  p_cidade_id uuid, p_lon double precision, p_lat double precision,
  p_codigo text default null, p_fonte_codigo text default 'NICK_CADASTRO_MANUAL',
  p_estado text default 'DOCUMENTADO', p_infra_poste_lote_id uuid default null,
  p_proprietario text default null, p_observacoes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_id uuid;
  v_geom geometry := app.gis_ponto(p_lon, p_lat);
begin
  perform app.gis_exige_editor();
  perform app.gis_zerar_contexto();
  if not app.gis_coordenada_valida(v_geom) then
    raise exception 'OPTIMAP_GEOMETRIA_INVALIDA: coordenadas inválidas ou fora do Brasil.' using errcode = 'invalid_parameter_value';
  end if;
  insert into public.gis_postes (codigo, geom, cidade_id, infra_poste_lote_id, proprietario, estado, fonte_id, observacoes)
  values (p_codigo, v_geom, p_cidade_id, p_infra_poste_lote_id, p_proprietario, p_estado,
          app.gis_fonte_id(p_fonte_codigo, true), p_observacoes)
  returning id into v_id;
  return v_id;
end;
$$;

-- Promoção explícita: "a NICK usa (ou vai usar) este poste externo". Cria um gis_postes
-- com a posição da referência e fonte = a da referência (origem honesta da coordenada).
-- A referência NUNCA é alterada.
create or replace function app.gis_promover_poste_referencia(
  p_poste_referencia_id uuid, p_estado text default 'DOCUMENTADO',
  p_cidade_id uuid default null, p_infra_poste_lote_id uuid default null,
  p_observacoes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r record;
  v_id uuid;
  v_existente uuid;
begin
  perform app.gis_exige_editor();
  perform app.gis_zerar_contexto();
  if p_estado not in ('PLANEJADO', 'DOCUMENTADO') then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: promoção cria poste PLANEJADO ou DOCUMENTADO (validação é ato separado).' using errcode = 'invalid_parameter_value';
  end if;
  select * into r from public.gis_postes_referencia where id = p_poste_referencia_id for share;
  if r.id is null then
    raise exception 'OPTIMAP_NAO_ENCONTRADO: poste de referência inexistente.' using errcode = 'no_data_found';
  end if;
  if r.estado_sincronizacao = 'EXCLUIDO_PELA_FONTE' then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: poste de referência marcado como excluído pela fonte.' using errcode = 'check_violation';
  end if;
  select id into v_existente from public.gis_postes where poste_referencia_id = r.id and removido_em is null;
  if v_existente is not null then
    raise exception 'OPTIMAP_JA_PROMOVIDO: este poste de referência já corresponde ao poste %.', v_existente using errcode = 'unique_violation';
  end if;
  if coalesce(p_cidade_id, r.cidade_id) is null then
    raise exception 'OPTIMAP_VINCULO_INVALIDO: informe a cidade (a referência não tem cidade associada).' using errcode = 'invalid_parameter_value';
  end if;
  if p_cidade_id is not null and r.cidade_id is not null and p_cidade_id <> r.cidade_id then
    raise exception 'OPTIMAP_VINCULO_INVALIDO: a cidade informada difere da cidade do poste de referência.' using errcode = 'check_violation';
  end if;

  perform set_config('optimap.motivo', 'Promovido a partir de poste de referência ' || r.id_externo, true);
  insert into public.gis_postes (codigo, geom, cidade_id, poste_referencia_id, infra_poste_lote_id, estado, fonte_id, observacoes)
  values (r.id_externo, r.geom, coalesce(p_cidade_id, r.cidade_id), r.id, p_infra_poste_lote_id, p_estado, r.fonte_id, p_observacoes)
  returning id into v_id;
  perform set_config('optimap.motivo', '', true);
  return v_id;
end;
$$;

create or replace function app.gis_criar_elemento(
  p_tipo text, p_cidade_id uuid, p_lon double precision default null, p_lat double precision default null,
  p_codigo text default null, p_nome text default null, p_poste_id uuid default null, p_pop_id uuid default null,
  p_fonte_codigo text default 'NICK_CADASTRO_MANUAL', p_estado text default 'DOCUMENTADO',
  p_atributos jsonb default '{}'::jsonb, p_observacoes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_id uuid;
  v_geom geometry;
begin
  perform app.gis_exige_editor();
  perform app.gis_zerar_contexto();
  if p_lon is not null and p_lat is not null then
    v_geom := app.gis_ponto(p_lon, p_lat);
  elsif p_poste_id is not null then
    select geom into v_geom from public.gis_postes where id = p_poste_id and removido_em is null for share;
    if v_geom is null then
      raise exception 'OPTIMAP_VINCULO_INVALIDO: poste inexistente ou arquivado.' using errcode = 'check_violation';
    end if;
  end if;
  if v_geom is null or not app.gis_coordenada_valida(v_geom) then
    raise exception 'OPTIMAP_GEOMETRIA_INVALIDA: informe coordenadas válidas ou um poste ativo.' using errcode = 'invalid_parameter_value';
  end if;
  insert into public.gis_elementos (tipo, codigo, nome, geom, cidade_id, poste_id, pop_id, estado, fonte_id, atributos, observacoes)
  values (p_tipo, p_codigo, p_nome, v_geom, p_cidade_id, p_poste_id, p_pop_id, p_estado,
          app.gis_fonte_id(p_fonte_codigo, true), coalesce(p_atributos, '{}'::jsonb), p_observacoes)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function app.gis_criar_trecho(
  p_cidade_id uuid, p_geojson jsonb,
  p_segmento_id uuid default null, p_cabo_id uuid default null,
  p_ponta_a_elemento_id uuid default null, p_ponta_a_pop_id uuid default null,
  p_ponta_b_elemento_id uuid default null, p_ponta_b_pop_id uuid default null,
  p_postes uuid[] default null, p_tipo_instalacao text default 'AEREO',
  p_fonte_codigo text default 'NICK_CADASTRO_MANUAL', p_estado text default 'DOCUMENTADO',
  p_codigo text default null, p_observacoes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_id uuid;
  i integer;
begin
  perform app.gis_exige_editor();
  perform app.gis_zerar_contexto();
  insert into public.gis_trechos (codigo, geom, cidade_id, segmento_id, cabo_id,
                                  ponta_a_elemento_id, ponta_a_pop_id, ponta_b_elemento_id, ponta_b_pop_id,
                                  tipo_instalacao, estado, fonte_id, observacoes)
  values (p_codigo, app.gis_geom_de_geojson(p_geojson, 'LINESTRING'), p_cidade_id, p_segmento_id, p_cabo_id,
          p_ponta_a_elemento_id, p_ponta_a_pop_id, p_ponta_b_elemento_id, p_ponta_b_pop_id,
          p_tipo_instalacao, p_estado, app.gis_fonte_id(p_fonte_codigo, true), p_observacoes)
  returning id into v_id;

  if p_postes is not null then
    for i in 1 .. coalesce(array_length(p_postes, 1), 0) loop
      insert into public.gis_trecho_postes (trecho_id, poste_id, ordem) values (v_id, p_postes[i], i);
    end loop;
  end if;
  return v_id;
end;
$$;

-- Troca de estado (inclui VALIDAR). Motivo obrigatório para VALIDADO e DESATIVADO.
create or replace function app.gis_alterar_estado(
  p_entidade text, p_id uuid, p_estado text, p_motivo text default null,
  p_evidencia_documento_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_rows integer;
begin
  perform app.gis_exige_editor();
  perform app.gis_zerar_contexto();
  if p_entidade not in ('gis_postes', 'gis_elementos', 'gis_trechos') then
    raise exception 'OPTIMAP_ENTIDADE_INVALIDA: %.', p_entidade using errcode = 'invalid_parameter_value';
  end if;
  if p_estado not in ('PLANEJADO', 'DOCUMENTADO', 'VALIDADO', 'DESATIVADO') then
    raise exception 'OPTIMAP_ESTADO_INVALIDO: %.', p_estado using errcode = 'invalid_parameter_value';
  end if;
  if p_estado in ('VALIDADO', 'DESATIVADO') and coalesce(btrim(p_motivo), '') = '' then
    raise exception 'OPTIMAP_MOTIVO_OBRIGATORIO: informe o motivo/evidência para %.', p_estado using errcode = 'invalid_parameter_value';
  end if;
  -- Evidência: documento precisa existir e estar ativo (public.documentos é legível por todo
  -- usuário autenticado desde a Fase 1, então "visível" = "existe e não removido").
  if p_evidencia_documento_id is not null
     and not exists (select 1 from public.documentos where id = p_evidencia_documento_id and removido_em is null) then
    raise exception 'OPTIMAP_EVIDENCIA_INVALIDA: documento inexistente ou removido.' using errcode = 'invalid_parameter_value';
  end if;
  perform set_config('optimap.motivo', coalesce(p_motivo, ''), true);
  perform set_config('optimap.evidencia_documento_id', coalesce(p_evidencia_documento_id::text, ''), true);
  execute format('update public.%I set estado = $1 where id = $2 and removido_em is null', p_entidade)
    using p_estado, p_id;
  get diagnostics v_rows = row_count;
  perform set_config('optimap.motivo', '', true);
  perform set_config('optimap.evidencia_documento_id', '', true);
  if v_rows = 0 then
    raise exception 'OPTIMAP_NAO_ENCONTRADO: % % inexistente, arquivado ou sem permissão.', p_entidade, p_id using errcode = 'no_data_found';
  end if;
end;
$$;

-- Corrige a posição/traçado. Elemento VALIDADO volta a DOCUMENTADO (regra 1.4).
create or replace function app.gis_alterar_geometria(
  p_entidade text, p_id uuid, p_geojson jsonb, p_motivo text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_tipo text;
  v_rows integer;
begin
  perform app.gis_exige_editor();
  perform app.gis_zerar_contexto();
  v_tipo := case p_entidade when 'gis_postes' then 'POINT' when 'gis_elementos' then 'POINT' when 'gis_trechos' then 'LINESTRING' end;
  if v_tipo is null then
    raise exception 'OPTIMAP_ENTIDADE_INVALIDA: %.', p_entidade using errcode = 'invalid_parameter_value';
  end if;
  perform set_config('optimap.motivo', coalesce(p_motivo, ''), true);
  execute format('update public.%I set geom = $1 where id = $2 and removido_em is null', p_entidade)
    using app.gis_geom_de_geojson(p_geojson, v_tipo), p_id;
  get diagnostics v_rows = row_count;
  perform set_config('optimap.motivo', '', true);
  if v_rows = 0 then
    raise exception 'OPTIMAP_NAO_ENCONTRADO: % % inexistente, arquivado ou sem permissão.', p_entidade, p_id using errcode = 'no_data_found';
  end if;
end;
$$;

-- Arquivar (soft delete, nunca DELETE físico). Bloqueia se ainda houver dependência ativa.
create or replace function app.gis_arquivar(p_entidade text, p_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_rows integer;
begin
  perform app.gis_exige_editor();
  perform app.gis_zerar_contexto();
  if coalesce(btrim(p_motivo), '') = '' then
    raise exception 'OPTIMAP_MOTIVO_OBRIGATORIO: informe o motivo do arquivamento.' using errcode = 'invalid_parameter_value';
  end if;
  if p_entidade not in ('gis_postes', 'gis_elementos', 'gis_trechos') then
    raise exception 'OPTIMAP_ENTIDADE_INVALIDA: %.', p_entidade using errcode = 'invalid_parameter_value';
  end if;
  -- Trava a linha ANTES de checar dependências: quem tentar ligar algo a ela ao mesmo
  -- tempo (FOR SHARE nos triggers de vínculo) espera e depois vê que foi arquivada.
  execute format('select 1 from public.%I where id = $1 and removido_em is null for update', p_entidade) using p_id;
  if p_entidade = 'gis_postes' then
    if exists (select 1 from public.gis_elementos where poste_id = p_id and removido_em is null)
       or exists (select 1 from public.gis_trecho_postes tp join public.gis_trechos t on t.id = tp.trecho_id
                  where tp.poste_id = p_id and t.removido_em is null) then
      raise exception 'OPTIMAP_DEPENDENCIA_ATIVA: há elementos ou trechos ativos usando este poste.' using errcode = 'foreign_key_violation';
    end if;
  elsif p_entidade = 'gis_elementos' then
    if exists (select 1 from public.gis_trechos where removido_em is null and (ponta_a_elemento_id = p_id or ponta_b_elemento_id = p_id)) then
      raise exception 'OPTIMAP_DEPENDENCIA_ATIVA: há trechos ativos ligados a este elemento.' using errcode = 'foreign_key_violation';
    end if;
  end if;

  execute format('update public.%I set removido_em = now(), observacoes = concat_ws(E''\n'', observacoes, $1) where id = $2 and removido_em is null', p_entidade)
    using '[ARQUIVADO ' || to_char(now(), 'YYYY-MM-DD') || '] ' || p_motivo, p_id;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'OPTIMAP_NAO_ENCONTRADO: % % inexistente, já arquivado ou sem permissão.', p_entidade, p_id using errcode = 'no_data_found';
  end if;
end;
$$;

-- Edição de atributos e vínculos (lista FECHADA de colunas por entidade; estado, geometria,
-- fonte, autoria e datas nunca passam por aqui). Vínculo físico alterado em algo VALIDADO
-- rebaixa para DOCUMENTADO (regra 1.4). p_dados: objeto JSON {coluna: valor}; null limpa.
create or replace function app.gis_alterar_atributos(p_entidade text, p_id uuid, p_dados jsonb, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_permitidas text[];
  k text;
  v_tipo text;
  v_rows integer;
begin
  perform app.gis_exige_editor();
  perform app.gis_zerar_contexto();
  v_permitidas := case p_entidade
    when 'gis_postes'    then array['codigo', 'proprietario', 'observacoes', 'infra_poste_lote_id']
    when 'gis_elementos' then array['tipo', 'codigo', 'nome', 'observacoes', 'atributos', 'poste_id', 'pop_id']
    when 'gis_trechos'   then array['codigo', 'observacoes', 'tipo_instalacao', 'cabo_id', 'segmento_id',
                                    'ponta_a_elemento_id', 'ponta_a_pop_id', 'ponta_b_elemento_id', 'ponta_b_pop_id']
  end;
  if v_permitidas is null then
    raise exception 'OPTIMAP_ENTIDADE_INVALIDA: %.', p_entidade using errcode = 'invalid_parameter_value';
  end if;
  if p_dados is null or jsonb_typeof(p_dados) <> 'object' or p_dados = '{}'::jsonb then
    raise exception 'OPTIMAP_DADOS_INVALIDOS: informe um objeto JSON com os campos a alterar.' using errcode = 'invalid_parameter_value';
  end if;
  for k in select jsonb_object_keys(p_dados) loop
    if not (k = any(v_permitidas)) then
      raise exception 'OPTIMAP_CAMPO_NAO_EDITAVEL: % não pode ser alterado por esta função em %.', k, p_entidade using errcode = 'invalid_parameter_value';
    end if;
  end loop;

  execute format('select 1 from public.%I where id = $1 and removido_em is null for update', p_entidade) using p_id;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'OPTIMAP_NAO_ENCONTRADO: % % inexistente ou arquivado.', p_entidade, p_id using errcode = 'no_data_found';
  end if;

  perform set_config('optimap.motivo', coalesce(p_motivo, ''), true);
  for k in select jsonb_object_keys(p_dados) loop
    select format_type(a.atttypid, a.atttypmod) into v_tipo
      from pg_attribute a where a.attrelid = ('public.' || p_entidade)::regclass and a.attname = k and not a.attisdropped;
    if v_tipo = 'jsonb' then
      execute format('update public.%I set %I = $1 where id = $2', p_entidade, k) using p_dados -> k, p_id;
    else
      execute format('update public.%I set %I = $1::%s where id = $2', p_entidade, k, v_tipo) using p_dados ->> k, p_id;
    end if;
  end loop;
  perform app.gis_zerar_contexto();
end;
$$;

-- Redefine a sequência de postes de um trecho. Trava o trecho com FOR UPDATE antes de tudo
-- (evita deadlock entre duas edições simultâneas da mesma sequência). Trecho VALIDADO é
-- rebaixado (trigger 1.3b).
create or replace function app.gis_definir_postes_trecho(p_trecho_id uuid, p_postes uuid[], p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  i integer;
begin
  perform app.gis_exige_editor();
  perform app.gis_zerar_contexto();
  perform 1 from public.gis_trechos where id = p_trecho_id and removido_em is null for update;
  if not found then
    raise exception 'OPTIMAP_NAO_ENCONTRADO: trecho inexistente ou arquivado.' using errcode = 'no_data_found';
  end if;
  if p_postes is not null and (select count(distinct x) from unnest(p_postes) x) <> cardinality(p_postes) then
    raise exception 'OPTIMAP_VINCULO_INVALIDO: poste repetido na sequência.' using errcode = 'invalid_parameter_value';
  end if;
  -- Motivo informado vai para o histórico caso o trecho VALIDADO seja rebaixado (1.3b).
  perform set_config('optimap.motivo', coalesce(p_motivo, ''), true);
  delete from public.gis_trecho_postes where trecho_id = p_trecho_id;
  for i in 1 .. coalesce(cardinality(p_postes), 0) loop
    insert into public.gis_trecho_postes (trecho_id, poste_id, ordem) values (p_trecho_id, p_postes[i], i);
  end loop;
  perform app.gis_zerar_contexto();
end;
$$;

-- ============================================================================
-- 4) Views de leitura (security_invoker = RLS do usuário + regra app.gis_pode_ver(), para
--    que FINANCEIRO/usuário sem perfil não veja nada do OptiMap, nem derivado de infra_*)
-- ============================================================================

create view public.vw_gis_pops with (security_invoker = true) as
select p.id, p.cidade_id, p.codigo, p.nome, p.tipo::text as tipo, p.status,
       app.gis_ponto(p.longitude::double precision, p.latitude::double precision) as geom
from public.infra_pops p
where (select app.gis_pode_ver())
  and p.removido_em is null
  and p.latitude is not null and p.longitude is not null
  and app.gis_coordenada_valida(app.gis_ponto(p.longitude::double precision, p.latitude::double precision));
comment on view public.vw_gis_pops is 'OptiMap: POPs com coordenada válida, como ponto. Lê infra_pops sem alterá-la; POP sem coordenada simplesmente não aparece no mapa (aparece em vw_gis_documentacao_incompleta).';

-- Lote faturável × postes georreferenciados. Só relatório: nunca corrige o lote.
create view public.vw_gis_conciliacao_lotes_postes with (security_invoker = true) as
select l.id as infra_poste_lote_id, l.cidade_id, l.identificacao, l.proprietario_terceiro,
       l.quantidade as quantidade_lote,
       count(gp.id) filter (where gp.removido_em is null and gp.estado <> 'DESATIVADO') as postes_georreferenciados,
       count(gp.id) filter (where gp.removido_em is null and gp.estado = 'VALIDADO') as postes_validados,
       l.quantidade - count(gp.id) filter (where gp.removido_em is null and gp.estado <> 'DESATIVADO') as diferenca,
       case
         when count(gp.id) filter (where gp.removido_em is null and gp.estado <> 'DESATIVADO') = l.quantidade then 'CONFERE'
         when count(gp.id) filter (where gp.removido_em is null and gp.estado <> 'DESATIVADO') < l.quantidade then 'FALTAM_GEORREFERENCIAR'
         else 'EXCEDE_LOTE'
       end as situacao
from public.infra_postes l
left join public.gis_postes gp on gp.infra_poste_lote_id = l.id
where (select app.gis_pode_ver()) and l.removido_em is null
group by l.id;
comment on view public.vw_gis_conciliacao_lotes_postes is 'OptiMap: quantidade do lote (infra_postes) × postes individuais georreferenciados. Divergência é só sinalizada; infra_postes nunca é alterada pelo OptiMap.';

-- Extensão declarada do segmento × comprimento desenhado dos trechos. Só relatório.
create view public.vw_gis_divergencia_extensao_segmento with (security_invoker = true) as
select s.id as segmento_id, s.cidade_id, s.nome,
       s.extensao_km as extensao_km_declarada,
       round(sum(t.comprimento_geo_m) / 1000.0, 3) as extensao_km_desenhada,
       case when s.extensao_km > 0
            then round((sum(t.comprimento_geo_m) / 1000.0 - s.extensao_km) / s.extensao_km * 100, 1)
       end as diferenca_pct,
       count(t.id) as trechos
from public.infra_segmentos s
join public.gis_trechos t on t.segmento_id = s.id and t.removido_em is null and t.estado <> 'DESATIVADO'
where (select app.gis_pode_ver()) and s.removido_em is null
group by s.id;
comment on view public.vw_gis_divergencia_extensao_segmento is 'OptiMap: compara infra_segmentos.extensao_km com o traçado desenhado. NUNCA atualiza extensao_km nem cidades_infra.km_rede (ambos afetam pricing).';

-- Documentação incompleta (para filtros "pendências" do mapa).
create view public.vw_gis_documentacao_incompleta with (security_invoker = true) as
select * from (
select 'infra_pops'::text as entidade, p.id, p.cidade_id, 'POP sem coordenada'::text as pendencia
  from public.infra_pops p where p.removido_em is null and (p.latitude is null or p.longitude is null)
union all
select 'gis_postes', gp.id, gp.cidade_id, 'Poste sem lote de faturamento (infra_postes)'
  from public.gis_postes gp where gp.removido_em is null and gp.estado <> 'DESATIVADO' and gp.infra_poste_lote_id is null
union all
select 'gis_elementos', e.id, e.cidade_id, e.tipo || ' sem poste nem POP associado'
  from public.gis_elementos e where e.removido_em is null and e.estado <> 'DESATIVADO' and e.poste_id is null and e.pop_id is null
union all
select 'gis_trechos', t.id, t.cidade_id, 'Trecho sem cabo associado'
  from public.gis_trechos t where t.removido_em is null and t.estado <> 'DESATIVADO' and t.cabo_id is null
union all
select 'gis_trechos', t.id, t.cidade_id, 'Trecho sem ponta A ou B definida'
  from public.gis_trechos t where t.removido_em is null and t.estado <> 'DESATIVADO'
   and ((t.ponta_a_elemento_id is null and t.ponta_a_pop_id is null) or (t.ponta_b_elemento_id is null and t.ponta_b_pop_id is null))
) pendencias
where (select app.gis_pode_ver());
comment on view public.vw_gis_documentacao_incompleta is 'OptiMap: lista de pendências de documentação por cidade.';

-- ============================================================================
-- 5) Consultas geográficas (o mapa NUNCA baixa a base inteira)
-- ============================================================================
--
-- gis_tile e gis_bbox são SECURITY DEFINER de propósito. Motivo (medido no sandbox): sob
-- RLS, o Postgres só usa um filtro como condição de índice se o operador for "leakproof";
-- o operador espacial && do PostGIS não é. Resultado: com RLS, toda consulta por área vira
-- varredura completa da tabela — inviável numa base de milhões de postes. Por isso estas
-- duas funções (e só elas) leem as tabelas gis_* com o privilégio do dono e aplicam
-- EXPLICITAMENTE a mesma regra da policy de SELECT (app.gis_pode_ver(), fonte única). Quem
-- não pode ver recebe tile/coleção vazia. Elas só leem; nenhuma escreve.

-- 5.1 Vector tile (MVT) por camada. Usado pelo MapLibre via API (JWT do usuário → RLS).
--     Em zoom baixo, postes de referência são agregados em grade (contagem), nunca
--     enviados um a um. Teto duro de feições por tile.
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
    return ''::bytea;   -- mesma regra da policy de SELECT
  end if;
  -- Zoom mínimo: abaixo dele o custo cresce com a base inteira (uma única chamada z0
  -- agregaria milhões de postes). O frontend usa os mesmos limites como minzoom da camada.
  -- Postes de referência: z ≥ 12 (medido: z10 sobre um aglomerado de 25 mil postes ≈ 320 ms;
  -- z12 ≈ 75 ms). Rede própria (volume muito menor): z ≥ 8.
  if (p_camada = 'postes_referencia' and p_z < 12) or (p_camada in ('postes', 'elementos', 'trechos') and p_z < 8) then
    return ''::bytea;
  end if;
  v_env3857 := ST_TileEnvelope(p_z, p_x, p_y);
  v_env4326 := ST_Transform(v_env3857, 4326);

  if p_camada = 'postes_referencia' then
    if p_z < 15 then
      -- agregação: célula ≈ 1/16 do tile
      v_cel := (ST_XMax(v_env3857) - ST_XMin(v_env3857)) / 16.0;
      select ST_AsMVT(q, 'postes_referencia_agregado', 4096, 'mvt_geom') into v_mvt from (
        select ST_AsMVTGeom(ST_Centroid(ST_Collect(ST_Transform(r.geom, 3857))), v_env3857, 4096, 64, true) as mvt_geom,
               count(*)::integer as quantidade
        from public.gis_postes_referencia r
        where r.geom && v_env4326 and (p_cidade_id is null or r.cidade_id = p_cidade_id)
        group by ST_SnapToGrid(ST_Transform(r.geom, 3857), v_cel, v_cel)
      ) q;
    else
      select ST_AsMVT(q, 'postes_referencia', 4096, 'mvt_geom') into v_mvt from (
        select ST_AsMVTGeom(ST_Transform(r.geom, 3857), v_env3857, 4096, 64, true) as mvt_geom,
               r.id::text as id, r.id_externo, r.situacao_fonte, r.estado_sincronizacao,
               exists (select 1 from public.gis_postes gp where gp.poste_referencia_id = r.id and gp.removido_em is null) as usado_pela_nick
        from public.gis_postes_referencia r
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

-- 5.2 GeoJSON por bbox (painéis, exportação pontual, testes). Limite duro de 5.000.
create or replace function app.gis_bbox(
  p_camada text, p_min_lon double precision, p_min_lat double precision,
  p_max_lon double precision, p_max_lat double precision,
  p_cidade_id uuid default null, p_limite integer default 2000
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_env geometry;
  v_lim integer := least(greatest(coalesce(p_limite, 2000), 1), 5000);
  v_feats jsonb;
  v_n integer;
begin
  if p_min_lon >= p_max_lon or p_min_lat >= p_max_lat then
    raise exception 'OPTIMAP_BBOX_INVALIDO.' using errcode = 'invalid_parameter_value';
  end if;
  if (p_max_lon - p_min_lon) * (p_max_lat - p_min_lat) > 0.25 then
    raise exception 'OPTIMAP_BBOX_GRANDE: área máxima por consulta é 0,25 grau² (~50×50 km). Use os tiles do mapa para áreas maiores.' using errcode = 'invalid_parameter_value';
  end if;
  if not app.gis_pode_ver() then
    return jsonb_build_object('type', 'FeatureCollection', 'features', '[]'::jsonb, 'truncado', false, 'limite', v_lim);
  end if;
  v_env := ST_MakeEnvelope(p_min_lon, p_min_lat, p_max_lon, p_max_lat, 4326);

  if p_camada = 'postes_referencia' then
    select jsonb_agg(f), count(*) into v_feats, v_n from (
      select jsonb_build_object('type', 'Feature', 'id', r.id, 'geometry', ST_AsGeoJSON(r.geom, 7)::jsonb,
               'properties', jsonb_build_object('camada', 'postes_referencia', 'id_externo', r.id_externo,
                 'situacao_fonte', r.situacao_fonte, 'estado_sincronizacao', r.estado_sincronizacao,
                 'data_referencia', r.data_referencia)) as f
      from public.gis_postes_referencia r
      where r.geom && v_env and (p_cidade_id is null or r.cidade_id = p_cidade_id)
      order by r.id_externo limit v_lim + 1) s;
  elsif p_camada = 'postes' then
    select jsonb_agg(f), count(*) into v_feats, v_n from (
      select jsonb_build_object('type', 'Feature', 'id', p.id, 'geometry', ST_AsGeoJSON(p.geom, 7)::jsonb,
               'properties', jsonb_build_object('camada', 'postes', 'codigo', p.codigo, 'estado', p.estado,
                 'poste_referencia_id', p.poste_referencia_id, 'infra_poste_lote_id', p.infra_poste_lote_id)) as f
      from public.gis_postes p
      where p.removido_em is null and p.geom && v_env and (p_cidade_id is null or p.cidade_id = p_cidade_id)
      order by p.criado_em limit v_lim + 1) s;
  elsif p_camada = 'elementos' then
    select jsonb_agg(f), count(*) into v_feats, v_n from (
      select jsonb_build_object('type', 'Feature', 'id', e.id, 'geometry', ST_AsGeoJSON(e.geom, 7)::jsonb,
               'properties', jsonb_build_object('camada', 'elementos', 'tipo', e.tipo, 'codigo', e.codigo,
                 'nome', e.nome, 'estado', e.estado)) as f
      from public.gis_elementos e
      where e.removido_em is null and e.geom && v_env and (p_cidade_id is null or e.cidade_id = p_cidade_id)
      order by e.criado_em limit v_lim + 1) s;
  elsif p_camada = 'trechos' then
    select jsonb_agg(f), count(*) into v_feats, v_n from (
      select jsonb_build_object('type', 'Feature', 'id', t.id, 'geometry', ST_AsGeoJSON(t.geom, 7)::jsonb,
               'properties', jsonb_build_object('camada', 'trechos', 'codigo', t.codigo, 'estado', t.estado,
                 'comprimento_geo_m', t.comprimento_geo_m, 'cabo_id', t.cabo_id, 'segmento_id', t.segmento_id)) as f
      from public.gis_trechos t
      where t.removido_em is null and t.geom && v_env and (p_cidade_id is null or t.cidade_id = p_cidade_id)
      order by t.criado_em limit v_lim + 1) s;
  elsif p_camada = 'pops' then
    select jsonb_agg(f), count(*) into v_feats, v_n from (
      select jsonb_build_object('type', 'Feature', 'id', p.id, 'geometry', ST_AsGeoJSON(p.geom, 7)::jsonb,
               'properties', jsonb_build_object('camada', 'pops', 'codigo', p.codigo, 'nome', p.nome,
                 'tipo', p.tipo, 'status', p.status)) as f
      from public.vw_gis_pops p
      where p.geom && v_env and (p_cidade_id is null or p.cidade_id = p_cidade_id)
      order by p.codigo limit v_lim + 1) s;
  else
    raise exception 'OPTIMAP_CAMADA_INVALIDA: %.', p_camada using errcode = 'invalid_parameter_value';
  end if;

  v_n := coalesce(v_n, 0);
  if v_n > v_lim then
    v_feats := (select jsonb_agg(x) from (select x from jsonb_array_elements(v_feats) x limit v_lim) z);
  end if;
  return jsonb_build_object('type', 'FeatureCollection',
                            'features', coalesce(v_feats, '[]'::jsonb),
                            'truncado', v_n > v_lim,
                            'limite', v_lim);
end;
$$;

revoke all on function app.gis_bbox(text, double precision, double precision, double precision, double precision, uuid, integer) from public;
grant execute on function app.gis_bbox(text, double precision, double precision, double precision, double precision, uuid, integer) to authenticated;

-- 5.3 Detalhe de um elemento (painel lateral): atributos, fonte (com termos/atribuição
--     para dado externo), vínculos e histórico de estado.
create or replace function app.gis_detalhe(p_camada text, p_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public, extensions, pg_temp
as $$
declare
  v jsonb;
  v_fonte uuid;
  v_tabela text;
begin
  v_tabela := case p_camada when 'postes_referencia' then 'gis_postes_referencia' when 'postes' then 'gis_postes'
                            when 'elementos' then 'gis_elementos' when 'trechos' then 'gis_trechos' end;
  if v_tabela is null then
    raise exception 'OPTIMAP_CAMADA_INVALIDA: %.', p_camada using errcode = 'invalid_parameter_value';
  end if;
  execute format('select to_jsonb(t) - ''geom'' || jsonb_build_object(''geometry'', ST_AsGeoJSON(t.geom, 7)::jsonb), t.fonte_id from public.%I t where t.id = $1', v_tabela)
    into v, v_fonte using p_id;
  if v is null then
    raise exception 'OPTIMAP_NAO_ENCONTRADO.' using errcode = 'no_data_found';
  end if;
  v := v || jsonb_build_object('camada', p_camada,
    'fonte', (select jsonb_build_object('codigo', f.codigo, 'nome', f.nome, 'tipo', f.tipo, 'atribuicao', f.atribuicao,
                                        'termos_uso', f.termos_uso, 'termos_verificados_em', f.termos_verificados_em,
                                        'url_origem', f.url_origem)
              from public.gis_fontes f where f.id = v_fonte));
  if p_camada = 'postes_referencia' then
    v := v || jsonb_build_object('poste_nick', (select jsonb_build_object('id', gp.id, 'estado', gp.estado)
                                                from public.gis_postes gp where gp.poste_referencia_id = p_id and gp.removido_em is null));
  else
    v := v || jsonb_build_object('historico_estado', coalesce((
      select jsonb_agg(jsonb_build_object('estado_anterior', h.estado_anterior, 'estado_novo', h.estado_novo,
                                          'motivo', h.motivo, 'usuario_id', h.usuario_id, 'criado_em', h.criado_em)
                       order by h.criado_em desc)
      from public.gis_validacoes h where h.entidade = v_tabela and h.entidade_id = p_id), '[]'::jsonb));
  end if;
  return v;
end;
$$;

-- 5.4 Busca: "lat, lon", número de poste (referência), código de poste/elemento/POP, cidade.
create or replace function app.gis_buscar(p_texto text, p_limite integer default 20)
returns jsonb
language plpgsql
stable
security definer   -- mesmo motivo de gis_tile/gis_bbox: LIKE não é leakproof (sem índice sob RLS)
set search_path = public, extensions, pg_temp
as $$
declare
  t text := btrim(coalesce(p_texto, ''));
  q text;   -- texto com %, _ e \ escapados para uso literal em LIKE
  m text[];
  v_lim integer := least(greatest(coalesce(p_limite, 20), 1), 50);
  v_res jsonb := '[]'::jsonb;
begin
  if length(t) < 2 or not app.gis_pode_ver() then
    return v_res;
  end if;
  m := regexp_match(t, '^\s*(-?\d{1,2}(?:[.,]\d+)?)\s*[;, ]\s*(-?\d{1,3}(?:[.,]\d+)?)\s*$');
  if m is not null then
    -- "lat, lon" (formato exibido pelo mapa da Copel e pelo Google Maps).
    if app.gis_coordenada_valida(app.gis_ponto(replace(m[2], ',', '.')::double precision, replace(m[1], ',', '.')::double precision)) then
      return jsonb_build_array(jsonb_build_object('tipo', 'coordenada', 'rotulo', t,
        'lon', replace(m[2], ',', '.')::double precision, 'lat', replace(m[1], ',', '.')::double precision));
    end if;
  end if;
  q := replace(replace(replace(t, '\', '\\'), '%', '\%'), '_', '\_');

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_res from (
    (select jsonb_build_object('tipo', 'cidade', 'id', c.id, 'rotulo', c.nome || '/' || c.uf) as x
       from public.cidades_infra c where c.removido_em is null and c.nome ilike '%' || q || '%' limit v_lim)
    union all
    (select jsonb_build_object('tipo', 'pop', 'id', p.id, 'rotulo', p.codigo || ' — ' || p.nome, 'lon', ST_X(p.geom), 'lat', ST_Y(p.geom))
       from public.vw_gis_pops p where p.codigo ilike '%' || q || '%' or p.nome ilike '%' || q || '%' limit v_lim)
    union all
    (select jsonb_build_object('tipo', 'poste_referencia', 'id', r.id, 'rotulo', 'Poste ' || r.id_externo, 'lon', ST_X(r.geom), 'lat', ST_Y(r.geom))
       from public.gis_postes_referencia r where r.id_externo like q || '%' order by (r.id_externo = t) desc, r.id_externo limit v_lim)
    union all
    (select jsonb_build_object('tipo', 'poste', 'id', p.id, 'rotulo', 'Poste NICK ' || p.codigo, 'lon', ST_X(p.geom), 'lat', ST_Y(p.geom))
       from public.gis_postes p where p.removido_em is null and p.codigo ilike q || '%' limit v_lim)
    union all
    (select jsonb_build_object('tipo', 'elemento', 'id', e.id, 'rotulo', e.tipo || ' ' || coalesce(e.codigo, e.nome, ''), 'lon', ST_X(e.geom), 'lat', ST_Y(e.geom))
       from public.gis_elementos e where e.removido_em is null and (e.codigo ilike '%' || q || '%' or e.nome ilike '%' || q || '%') limit v_lim)
    limit v_lim
  ) s;
  return v_res;
end;
$$;

-- ============================================================================
-- 6) Wrappers public.optimap_* (superfície do PostgREST/API — mesmo padrão pricing_*)
-- ============================================================================
create or replace function public.optimap_tile(p_camada text, p_z integer, p_x integer, p_y integer, p_cidade_id uuid default null)
returns bytea language sql stable security invoker as $$ select app.gis_tile(p_camada, p_z, p_x, p_y, p_cidade_id) $$;

create or replace function public.optimap_bbox(p_camada text, p_min_lon double precision, p_min_lat double precision,
  p_max_lon double precision, p_max_lat double precision, p_cidade_id uuid default null, p_limite integer default 2000)
returns jsonb language sql stable security invoker as $$ select app.gis_bbox(p_camada, p_min_lon, p_min_lat, p_max_lon, p_max_lat, p_cidade_id, p_limite) $$;

create or replace function public.optimap_detalhe(p_camada text, p_id uuid)
returns jsonb language sql stable security invoker as $$ select app.gis_detalhe(p_camada, p_id) $$;

create or replace function public.optimap_buscar(p_texto text, p_limite integer default 20)
returns jsonb language sql stable security invoker as $$ select app.gis_buscar(p_texto, p_limite) $$;

create or replace function public.optimap_criar_poste(p_cidade_id uuid, p_lon double precision, p_lat double precision,
  p_codigo text default null, p_fonte_codigo text default 'NICK_CADASTRO_MANUAL', p_estado text default 'DOCUMENTADO',
  p_infra_poste_lote_id uuid default null, p_proprietario text default null, p_observacoes text default null)
returns uuid language sql security invoker as $$
  select app.gis_criar_poste(p_cidade_id, p_lon, p_lat, p_codigo, p_fonte_codigo, p_estado, p_infra_poste_lote_id, p_proprietario, p_observacoes) $$;

create or replace function public.optimap_promover_poste_referencia(p_poste_referencia_id uuid, p_estado text default 'DOCUMENTADO',
  p_cidade_id uuid default null, p_infra_poste_lote_id uuid default null, p_observacoes text default null)
returns uuid language sql security invoker as $$
  select app.gis_promover_poste_referencia(p_poste_referencia_id, p_estado, p_cidade_id, p_infra_poste_lote_id, p_observacoes) $$;

create or replace function public.optimap_criar_elemento(p_tipo text, p_cidade_id uuid, p_lon double precision default null,
  p_lat double precision default null, p_codigo text default null, p_nome text default null, p_poste_id uuid default null,
  p_pop_id uuid default null, p_fonte_codigo text default 'NICK_CADASTRO_MANUAL', p_estado text default 'DOCUMENTADO',
  p_atributos jsonb default '{}'::jsonb, p_observacoes text default null)
returns uuid language sql security invoker as $$
  select app.gis_criar_elemento(p_tipo, p_cidade_id, p_lon, p_lat, p_codigo, p_nome, p_poste_id, p_pop_id, p_fonte_codigo, p_estado, p_atributos, p_observacoes) $$;

create or replace function public.optimap_criar_trecho(p_cidade_id uuid, p_geojson jsonb, p_segmento_id uuid default null,
  p_cabo_id uuid default null, p_ponta_a_elemento_id uuid default null, p_ponta_a_pop_id uuid default null,
  p_ponta_b_elemento_id uuid default null, p_ponta_b_pop_id uuid default null, p_postes uuid[] default null,
  p_tipo_instalacao text default 'AEREO', p_fonte_codigo text default 'NICK_CADASTRO_MANUAL',
  p_estado text default 'DOCUMENTADO', p_codigo text default null, p_observacoes text default null)
returns uuid language sql security invoker as $$
  select app.gis_criar_trecho(p_cidade_id, p_geojson, p_segmento_id, p_cabo_id, p_ponta_a_elemento_id, p_ponta_a_pop_id,
    p_ponta_b_elemento_id, p_ponta_b_pop_id, p_postes, p_tipo_instalacao, p_fonte_codigo, p_estado, p_codigo, p_observacoes) $$;

create or replace function public.optimap_alterar_estado(p_entidade text, p_id uuid, p_estado text, p_motivo text default null,
  p_evidencia_documento_id uuid default null)
returns void language sql security invoker as $$ select app.gis_alterar_estado(p_entidade, p_id, p_estado, p_motivo, p_evidencia_documento_id) $$;

create or replace function public.optimap_alterar_geometria(p_entidade text, p_id uuid, p_geojson jsonb, p_motivo text default null)
returns void language sql security invoker as $$ select app.gis_alterar_geometria(p_entidade, p_id, p_geojson, p_motivo) $$;

create or replace function public.optimap_alterar_atributos(p_entidade text, p_id uuid, p_dados jsonb, p_motivo text default null)
returns void language sql security invoker as $$ select app.gis_alterar_atributos(p_entidade, p_id, p_dados, p_motivo) $$;

create or replace function public.optimap_definir_postes_trecho(p_trecho_id uuid, p_postes uuid[], p_motivo text default null)
returns void language sql security invoker as $$ select app.gis_definir_postes_trecho(p_trecho_id, p_postes, p_motivo) $$;

create or replace function public.optimap_arquivar(p_entidade text, p_id uuid, p_motivo text)
returns void language sql security invoker as $$ select app.gis_arquivar(p_entidade, p_id, p_motivo) $$;

-- ============================================================================
-- 7) EXECUTE das funções SECURITY DEFINER app.gis_* (escrita e leitura espacial): só
--    authenticated — nunca PUBLIC/anon. Os helpers imutáveis/invoker (gis_coordenada_valida,
--    gis_ponto, gis_pode_ver, ...) mantêm o EXECUTE padrão: são usados em CHECKs e views e
--    precisam funcionar para qualquer papel que grave/leia as tabelas (inclusive o
--    service_role do Supabase, usado por importações em lote na Fase 4).
-- ============================================================================
do $$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname like 'gis\_%' and p.prosecdef
  loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
