-- OptiMon — Fase 1
-- Funções utilitárias reaproveitadas em várias tabelas.

create schema if not exists app;
comment on schema app is 'Funções auxiliares de aplicação (RBAC, helpers). Não confundir com o schema auth, gerenciado pelo Supabase Auth.';

create or replace function public.set_atualizado_em()
returns trigger
language plpgsql
as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;

comment on function public.set_atualizado_em() is 'Trigger genérico: mantém a coluna atualizado_em sempre corrente.';
