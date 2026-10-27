-- OptiMon — OptiMap Fase 2 (fundação geográfica) — Migration 1/4: PostGIS.
--
-- Aditiva. Habilita a extensão PostGIS no schema `extensions` (padrão do Supabase — mantém
-- `public` limpo e evita que as funções da extensão apareçam na API REST do PostgREST).
--
-- Dependências / impacto (documentados no relatório da Fase 2):
--   * O search_path padrão dos papéis do Supabase já inclui `extensions`, então tipos e
--     funções (geometry, ST_*) são resolvidos sem qualificação.
--   * A extensão cria a tabela de referência `extensions.spatial_ref_sys` (sistemas de
--     coordenadas, sem nenhum dado interno). O linter do Supabase pode alertar "RLS
--     desabilitado" nela — é tabela de catálogo da extensão, não dado do OptiMon.
--   * Se o PostGIS já estiver habilitado no projeto (em qualquer schema), o
--     `if not exists` torna esta migration um no-op.
--   * Nenhuma tabela ou dado existente é tocado.

create schema if not exists extensions;
create extension if not exists postgis with schema extensions;

-- No Supabase, `authenticated` já tem USAGE em `extensions` por padrão; explicitado aqui
-- porque as funções do OptiMap (security invoker) chamam ST_* com o papel do usuário.
-- Idempotente. `anon` não recebe nada.
grant usage on schema extensions to authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant usage on schema extensions to service_role;   -- já é padrão no Supabase
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'postgis') then
    raise exception 'OptiMap: PostGIS não pôde ser habilitado.';
  end if;
  -- PostGIS pré-existente fora de extensions/public quebraria a resolução de tipos (geometry)
  -- nas próximas migrations: aborta com mensagem clara em vez de falhar no meio.
  if (select extnamespace::regnamespace::text from pg_extension where extname = 'postgis') not in ('extensions', 'public') then
    raise exception 'OptiMap: PostGIS já instalado no schema %, fora do search_path esperado (extensions/public). Ajuste antes de aplicar o OptiMap.',
      (select extnamespace::regnamespace::text from pg_extension where extname = 'postgis');
  end if;
end $$;
