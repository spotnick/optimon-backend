-- OptiMon — Fase 1.1
-- Seção 36: corrige a captura de IP (nunca era preenchida na Fase 1) e cobre lacunas
-- e tabelas novas na auditoria automática.

create or replace function public.fn_auditoria()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario uuid;
  v_ip inet;
begin
  begin
    v_usuario := auth.uid();
  exception when others then
    v_usuario := null;
  end;

  -- Em Supabase/PostgREST, o IP do cliente chega via o header padrão x-forwarded-for,
  -- exposto pela GUC request.headers. Fora desse contexto (ex.: chamada direta via
  -- psql, ou este ambiente de teste local) simplesmente não há IP — nunca é erro fatal.
  begin
    v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', '')::inet;
  exception when others then
    v_ip := null;
  end;

  if tg_op = 'INSERT' then
    insert into public.auditoria (usuario_id, ip, acao, entidade, entidade_id, valor_anterior, valor_novo)
    values (v_usuario, v_ip, 'INSERT', tg_table_name, new.id, null, to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    insert into public.auditoria (usuario_id, ip, acao, entidade, entidade_id, valor_anterior, valor_novo)
    values (v_usuario, v_ip, 'UPDATE', tg_table_name, new.id, to_jsonb(old), to_jsonb(new));
    return new;
  elsif tg_op = 'DELETE' then
    insert into public.auditoria (usuario_id, ip, acao, entidade, entidade_id, valor_anterior, valor_novo)
    values (v_usuario, v_ip, 'DELETE', tg_table_name, old.id, to_jsonb(old), null);
    return old;
  end if;
  return null;
end;
$$;

comment on function public.fn_auditoria() is 'Fase 1.1: agora também tenta capturar o IP do cliente via request.headers (PostgREST/Supabase), com fallback seguro para null fora desse contexto.';

-- Lacuna da Fase 1: solicitações de fibra de terceiros / rede própria nunca eram
-- auditadas (seção 36 pede explicitamente "aprovação de fibra de terceiros" e
-- "aprovação de rede própria" no log).
create trigger trg_aud_contrato_regras_solicitacoes
  after insert or update or delete on public.contrato_regras_solicitacoes
  for each row execute function public.fn_auditoria();

-- Tabelas novas da Fase 1.1 que representam decisões/alterações relevantes.
create trigger trg_aud_infra_pops
  after insert or update or delete on public.infra_pops
  for each row execute function public.fn_auditoria();

create trigger trg_aud_infra_portas_pon
  after insert or update or delete on public.infra_portas_pon
  for each row execute function public.fn_auditoria();

create trigger trg_aud_contrato_fibras
  after insert or update or delete on public.contrato_fibras
  for each row execute function public.fn_auditoria();

create trigger trg_aud_contrato_aditivos
  after insert or update or delete on public.contrato_aditivos
  for each row execute function public.fn_auditoria();

create trigger trg_aud_contrato_metas
  after insert or update or delete on public.contrato_metas
  for each row execute function public.fn_auditoria();

create trigger trg_aud_contrato_pricing_config
  after insert or update or delete on public.contrato_pricing_config
  for each row execute function public.fn_auditoria();
