-- OptiMon — Fase 2.5.1 (1/3): auditoria semântica para os novos fluxos de
-- usuário/proponente/assinatura desta fase (correção do fluxo de convite,
-- arquivar/reativar proponente, testar conexão de provedor).
--
-- Reaproveita 100% a infraestrutura já existente desde a Fase 2.3.1/2.5:
-- `public.auditoria` (mesma tabela única do sistema todo — nunca uma tabela
-- paralela) e `app.registrar_auditoria_semantica` (mesma função — nunca uma
-- segunda função de log). Só ACRESCENTA ações novas às duas listas
-- (constraint da tabela + whitelist interna da função), preservando 100% das
-- ações já existentes, e expõe um wrapper genérico em `public` para que
-- qualquer rota Node possa logar um evento semântico sem precisar de uma
-- função SQL dedicada por ação — só as ações que hoje têm lógica de negócio
-- própria (ex.: geração de contrato) continuam com sua função dedicada.

alter table public.auditoria drop constraint if exists auditoria_acao_check;
alter table public.auditoria add constraint auditoria_acao_check
  check (acao = any (array[
    'INSERT', 'UPDATE', 'DELETE', 'LOGIN',
    'ARCHIVE', 'RESTORE', 'BLOCKED_ARCHIVE', 'BLOCKED_DELETE',
    'PROPOSAL_APPROVE', 'PROPOSAL_REJECT', 'PROPOSAL_STATUS_CHANGE',
    'PROPOSAL_VERSION_CREATE', 'PROPOSAL_DUPLICATE', 'PROPOSAL_EXPORT',
    'SIGNATURE_ENVELOPE_CREATE', 'SIGNATURE_ENVELOPE_SEND', 'SIGNATURE_ENVELOPE_CANCEL',
    'SIGNATURE_EVENT_RECEIVED', 'SIGNATURE_VALIDATED',
    'CONTRACT_GENERATE', 'CONTRACT_ACTIVATE', 'CONTRACT_ACTIVATE_BLOCKED',
    'CONTRACT_ADDENDUM_CREATE', 'CONTRACT_ADDENDUM_APPROVE', 'CONTRACT_ADDENDUM_ACTIVATE',
    'CONTRACT_REAJUSTE_APLICADO',
    'USER_PROFILE_CREATE', 'USER_PROFILE_UPDATE',
    'PRICE_EXCEPTION_REQUEST',
    -- Fase 2.5.1 — novas ações, todas aditivas:
    'USER_INVITE', 'USER_INVITE_FAILED', 'USER_RESEND_INVITE',
    'USER_DEACTIVATE', 'USER_REACTIVATE', 'USER_RESET_ACCESS',
    'PARTNER_DEACTIVATE', 'PARTNER_REACTIVATE',
    'SIGNATURE_TEST_CONNECTION'
  ]));

comment on constraint auditoria_acao_check on public.auditoria is 'Fase 2.5.1 (seção 1-18/34): acrescenta as ações de convite/desativação/reativação/redefinição de usuário, arquivamento/reativação de proponente e teste de conexão de provedor de assinatura. Mantém 100% das ações já existentes — nenhuma removida.';

create or replace function app.registrar_auditoria_semantica(
  p_entidade text,
  p_entidade_id uuid,
  p_acao text,
  p_motivo text default null,
  p_valor_anterior jsonb default null,
  p_valor_novo jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ip inet;
begin
  if p_acao not in (
    'ARCHIVE', 'RESTORE', 'BLOCKED_ARCHIVE', 'BLOCKED_DELETE',
    'PROPOSAL_APPROVE', 'PROPOSAL_REJECT', 'PROPOSAL_STATUS_CHANGE',
    'PROPOSAL_VERSION_CREATE', 'PROPOSAL_DUPLICATE', 'PROPOSAL_EXPORT',
    'SIGNATURE_ENVELOPE_CREATE', 'SIGNATURE_ENVELOPE_SEND', 'SIGNATURE_ENVELOPE_CANCEL',
    'SIGNATURE_EVENT_RECEIVED', 'SIGNATURE_VALIDATED',
    'CONTRACT_GENERATE', 'CONTRACT_ACTIVATE', 'CONTRACT_ACTIVATE_BLOCKED',
    'CONTRACT_ADDENDUM_CREATE', 'CONTRACT_ADDENDUM_APPROVE', 'CONTRACT_ADDENDUM_ACTIVATE',
    'CONTRACT_REAJUSTE_APLICADO',
    'USER_PROFILE_CREATE', 'USER_PROFILE_UPDATE',
    'PRICE_EXCEPTION_REQUEST',
    'USER_INVITE', 'USER_INVITE_FAILED', 'USER_RESEND_INVITE',
    'USER_DEACTIVATE', 'USER_REACTIVATE', 'USER_RESET_ACCESS',
    'PARTNER_DEACTIVATE', 'PARTNER_REACTIVATE',
    'SIGNATURE_TEST_CONNECTION'
  ) then
    raise exception 'app.registrar_auditoria_semantica: ação inválida %.', p_acao;
  end if;

  begin
    v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', '')::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.auditoria (usuario_id, ip, acao, entidade, entidade_id, valor_anterior, valor_novo, motivo, origem)
  values (auth.uid(), v_ip, p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, p_motivo, 'API');
end;
$$;

comment on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb) is 'Fase 2.5.1: mesma função desde a Fase 2.3.1 (seção 28) — só a whitelist interna cresceu. SECURITY DEFINER para poder inserir em auditoria mesmo sem policy de INSERT para authenticated; sempre grava auth.uid() do chamador, nunca um usuario_id arbitrário vindo de parâmetro.';

-- Wrapper genérico em `public` (a única forma de um caller `authenticated`
-- via PostgREST chegar num `app.*`, já que só o schema `public` é exposto —
-- mesmo padrão de todo o projeto). Evita criar uma função SQL dedicada para
-- cada ação nova que não tem lógica de negócio própria além do log — a
-- escrita de fato (ex.: `usuarios.ativo = false`) continua acontecendo pela
-- rota PATCH já existente, sob a MESMA policy de RLS de sempre; este wrapper
-- só acrescenta o registro semântico ao lado dela.
create or replace function public.pricing_log_semantic_event(
  p_entidade text, p_entidade_id uuid, p_acao text, p_motivo text default null,
  p_valor_anterior jsonb default null, p_valor_novo jsonb default null
)
returns void
language sql
security invoker
as $$ select app.registrar_auditoria_semantica(p_entidade, p_entidade_id, p_acao, p_motivo, p_valor_anterior, p_valor_novo); $$;

comment on function public.pricing_log_semantic_event(text, uuid, text, text, jsonb, jsonb) is 'Fase 2.5.1: wrapper fino e genérico para qualquer rota Node registrar um evento semântico de auditoria (USER_INVITE/USER_DEACTIVATE/PARTNER_DEACTIVATE/SIGNATURE_TEST_CONNECTION/etc.) sem precisar de uma função SQL dedicada por ação. SECURITY INVOKER porque app.registrar_auditoria_semantica já é SECURITY DEFINER e já está grantada a authenticated — nenhuma elevação de privilégio adicional acontece aqui.';

grant execute on function public.pricing_log_semantic_event(text, uuid, text, text, jsonb, jsonb) to authenticated;
