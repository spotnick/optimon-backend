-- OptiMon — Fase 1
-- Tabela de usuários internos (1:1 com auth.users do Supabase Auth) e funções de RBAC.

create table public.usuarios (
  id uuid primary key references auth.users(id) on delete restrict,
  nome text not null,
  email text not null,
  perfil perfil_usuario not null,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz
);

create unique index usuarios_email_lower_idx on public.usuarios (lower(email));
create index usuarios_perfil_idx on public.usuarios (perfil) where removido_em is null;

create trigger trg_usuarios_atualizado_em
  before update on public.usuarios
  for each row execute function public.set_atualizado_em();

comment on table public.usuarios is 'Usuários internos do OptiMon (ISP). Perfil define RBAC (seção 4 do Prompt Mestre).';

-- app.perfil_atual(): perfil do usuário autenticado no momento (usado em todas as policies de RLS).
create or replace function app.perfil_atual()
returns perfil_usuario
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select perfil
  from public.usuarios
  where id = auth.uid()
    and removido_em is null
    and ativo = true;
$$;

comment on function app.perfil_atual() is 'Perfil RBAC do usuário autenticado (auth.uid()). Null se não houver usuário ativo correspondente.';

-- app.tem_perfil(...): true se o usuário autenticado tiver um dos perfis informados.
create or replace function app.tem_perfil(variadic perfis perfil_usuario[])
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app.perfil_atual() = any(perfis);
$$;

comment on function app.tem_perfil(perfil_usuario[]) is 'Helper de RLS: uso "using (app.tem_perfil(''DIRETOR'',''ADMINISTRADOR''))".';
