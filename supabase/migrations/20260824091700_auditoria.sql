-- OptiMon — Fase 1
-- Auditoria central (seção 33): alimentada por trigger, nunca editável/apagável.

create table public.auditoria (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid references public.usuarios(id),
  criado_em timestamptz not null default now(),
  ip inet,
  acao text not null check (acao in ('INSERT','UPDATE','DELETE')),
  entidade text not null,
  entidade_id uuid,
  valor_anterior jsonb,
  valor_novo jsonb,
  origem text not null default 'SISTEMA',
  motivo text
);
create index auditoria_entidade_idx on public.auditoria (entidade, entidade_id);
create index auditoria_criado_em_idx on public.auditoria (criado_em desc);

comment on table public.auditoria is 'Log de auditoria único do sistema. INSERT apenas via trigger (security definer); UPDATE/DELETE bloqueados para todos os perfis, inclusive ADMINISTRADOR.';

-- Função genérica: qualquer tabela com trigger apontando aqui é auditada automaticamente.
create or replace function public.fn_auditoria()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario uuid;
begin
  begin
    v_usuario := auth.uid();
  exception when others then
    v_usuario := null;
  end;

  if tg_op = 'INSERT' then
    insert into public.auditoria (usuario_id, acao, entidade, entidade_id, valor_anterior, valor_novo)
    values (v_usuario, 'INSERT', tg_table_name, new.id, null, to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    insert into public.auditoria (usuario_id, acao, entidade, entidade_id, valor_anterior, valor_novo)
    values (v_usuario, 'UPDATE', tg_table_name, new.id, to_jsonb(old), to_jsonb(new));
    return new;
  elsif tg_op = 'DELETE' then
    insert into public.auditoria (usuario_id, acao, entidade, entidade_id, valor_anterior, valor_novo)
    values (v_usuario, 'DELETE', tg_table_name, old.id, to_jsonb(old), null);
    return old;
  end if;
  return null;
end;
$$;

comment on function public.fn_auditoria() is 'Trigger genérico de auditoria. security definer para poder gravar em auditoria mesmo com RLS restritiva na tabela de origem.';

-- Impede qualquer alteração/remoção de registros de auditoria já gravados.
create or replace function public.fn_bloquear_alteracao_auditoria()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Registros de auditoria são imutáveis e não podem ser alterados ou apagados.';
end;
$$;

create trigger trg_auditoria_imutavel
  before update or delete on public.auditoria
  for each row execute function public.fn_bloquear_alteracao_auditoria();

-- Tabelas sensíveis auditadas automaticamente (seção 33: "usuário X alterou Revenue Share de 10% para 12%").
create trigger trg_aud_usuarios
  after insert or update or delete on public.usuarios
  for each row execute function public.fn_auditoria();

create trigger trg_aud_contratos
  after insert or update or delete on public.contratos
  for each row execute function public.fn_auditoria();

create trigger trg_aud_contrato_regras
  after insert or update or delete on public.contrato_regras
  for each row execute function public.fn_auditoria();

create trigger trg_aud_contrato_clientes_reservados
  after insert or update or delete on public.contrato_clientes_reservados
  for each row execute function public.fn_auditoria();

create trigger trg_aud_pricing_parametros
  after insert or update or delete on public.pricing_parametros
  for each row execute function public.fn_auditoria();

create trigger trg_aud_pricing_versions
  after insert or update or delete on public.pricing_versions
  for each row execute function public.fn_auditoria();

create trigger trg_aud_medicoes_mensais
  after insert or update or delete on public.medicoes_mensais
  for each row execute function public.fn_auditoria();

create trigger trg_aud_ativos
  after insert or update or delete on public.ativos
  for each row execute function public.fn_auditoria();

create trigger trg_aud_integracoes
  after insert or update or delete on public.integracoes
  for each row execute function public.fn_auditoria();
