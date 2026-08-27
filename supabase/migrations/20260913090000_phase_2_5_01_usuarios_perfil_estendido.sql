-- OptiMon — Fase 2.5 (1/9): Gestão de Usuários — campos de perfil (seção 14).
-- RBAC (seção 15) já está implementado desde a Fase 1 via `perfil_usuario` (6 valores)
-- e `app.tem_perfil()`/RLS em toda tabela — nada duplicado aqui, só os campos
-- cadastrais que faltavam em `usuarios` e o registro de último acesso.

alter table public.usuarios
  add column if not exists telefone text,
  add column if not exists cpf text,
  add column if not exists cargo text,
  add column if not exists departamento text,
  add column if not exists observacoes text,
  add column if not exists ultimo_acesso_em timestamptz;

comment on column public.usuarios.telefone is 'Fase 2.5 seção 14.';
comment on column public.usuarios.cpf is 'Fase 2.5 seção 14 — armazenado como texto (11 dígitos), sem máscara.';
comment on column public.usuarios.cargo is 'Fase 2.5 seção 14.';
comment on column public.usuarios.departamento is 'Fase 2.5 seção 14.';
comment on column public.usuarios.observacoes is 'Fase 2.5 seção 14.';
comment on column public.usuarios.ultimo_acesso_em is 'Fase 2.5 seção 14 — atualizado por public.usuarios_touch_last_access(), chamado pelo frontend logo após o login.';

alter table public.usuarios drop constraint if exists usuarios_cpf_formato;
alter table public.usuarios add constraint usuarios_cpf_formato
  check (cpf is null or cpf ~ '^[0-9]{11}$');

-- ============================================================================
-- Último acesso: cada usuário só pode tocar o próprio registro (nunca o de
-- outro) — SECURITY DEFINER estreito, não um jeito de burlar `usuarios_admin_all`.
-- ============================================================================

create or replace function public.usuarios_touch_last_access()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.usuarios
     set ultimo_acesso_em = now()
   where id = auth.uid();
end;
$$;

grant execute on function public.usuarios_touch_last_access() to authenticated;

comment on function public.usuarios_touch_last_access() is 'Fase 2.5 seção 14: registra o último acesso do próprio usuário autenticado — nunca de outro (auth.uid() fixo, sem parâmetro de id).';
