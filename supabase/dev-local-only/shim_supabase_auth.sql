-- NÃO FAZ PARTE DAS MIGRATIONS DO PRODUTO.
-- Usado só para validar o schema num Postgres puro (sem o stack completo do Supabase).
-- Em Supabase de verdade, o schema "auth" e a função auth.uid() já existem, gerenciados
-- pelo Supabase Auth — nunca rode este arquivo contra um projeto Supabase real.

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text
);

-- Fase deploy (parte 2, seção 39): para validar a API/frontend de ponta a ponta contra
-- PostgREST local (simulando a camada REST do Supabase) antes de existir um projeto
-- Supabase real, auth.uid() agora também lê o claim padrão que o PostgREST expõe como GUC
-- de sessão (request.jwt.claims ->> 'sub') — exatamente como o auth.uid() de um Supabase
-- real. O fallback para app.current_user_id é mantido 100% intacto: todos os scripts de
-- teste existentes (tests/run_tests_*.sh) continuam funcionando sem nenhuma alteração,
-- pois chamam set_config('app.current_user_id', ...) diretamente via psql, sem passar
-- por PostgREST/JWT nenhum.
create or replace function auth.uid()
returns uuid
language plpgsql
stable
as $$
declare
  v_from_jwt uuid;
begin
  begin
    v_from_jwt := nullif(current_setting('request.jwt.claims', true)::json ->> 'sub', '')::uuid;
  exception when others then
    v_from_jwt := null;
  end;
  if v_from_jwt is not null then
    return v_from_jwt;
  end if;
  return nullif(current_setting('app.current_user_id', true), '')::uuid;
end;
$$;

-- Fase 1.1: as migrations passaram a declarar "to authenticated" explicitamente nas
-- policies de RLS (seção 35) e a conceder privilégios a esse papel. Em Supabase real
-- os papéis anon/authenticated/service_role já existem — aqui simulamos os dois que
-- usamos para testar (NOLOGIN: só entra-se neles via SET ROLE).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
end $$;

grant execute on function auth.uid() to authenticated, anon;
grant usage on schema auth to authenticated, anon;

-- PostgREST local (dev-local-only/postgrest.local.conf) precisa de um único papel de
-- LOGIN ("authenticator", NOINHERIT — nunca herda privilégio de anon/authenticated
-- automaticamente) que ele usa para conectar e então faz SET ROLE para anon ou
-- authenticated a cada requisição, conforme o claim "role" do JWT — o mesmo mecanismo
-- usado por um projeto Supabase real.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login password 'optimon_dev_authenticator';
  end if;
end $$;

grant anon to authenticator;
grant authenticated to authenticator;
