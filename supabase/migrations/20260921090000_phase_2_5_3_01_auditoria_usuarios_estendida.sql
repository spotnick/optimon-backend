-- OptiMon — Fase 2.5.3 (seção 9/18): CORREÇÃO DEFINITIVA — USUÁRIOS AUTH x
-- public.usuarios. Sétima extensão da mesma auditoria semântica única desde
-- a Fase 2.3.1 — nunca uma tabela paralela, nunca uma segunda função de log
-- (ver docs/ARQUITETURA.md seção 24/25). Só ACRESCENTA 7 ações novas às duas
-- listas (constraint da tabela + whitelist interna da função), preservando
-- 100% das ações já existentes — nenhuma removida, nenhuma redefinida.
--
-- As 7 ações novas cobrem cada etapa do fluxo de convite/reconciliação
-- redesenhado nesta fase (api/routes/users.js), de forma que o rastro de
-- auditoria por si só já responde "o que aconteceu" sem precisar olhar log
-- de aplicação:
--   USER_INVITE_STARTED    — administrador iniciou um convite (antes de tocar
--                             a Auth Admin API; best-effort, nunca bloqueia).
--   USER_AUTH_CREATED      — identidade criada com sucesso em auth.users.
--   USER_PROFILE_CREATED   — INSERT em public.usuarios completou com sucesso.
--   USER_INVITE_COMPLETED  — as duas etapas acima concluíram: convite 100%
--                             bem-sucedido (Estado A → completo).
--   USER_AUTH_ROLLBACK     — INSERT em public.usuarios falhou e a identidade
--                             Auth recém-criada NESTA MESMA OPERAÇÃO foi
--                             revertida (deleteUser) com sucesso — nenhum
--                             órfão ficou para trás.
--   USER_AUTH_ORPHAN       — uma identidade Auth ficou (ou já estava) órfã,
--                             sem public.usuarios correspondente — seja
--                             porque o rollback acima falhou, seja porque o
--                             diagnóstico (GET /api/users/health) encontrou
--                             uma pré-existente (Estado C).
--   USER_PROFILE_RECONCILED — POST /api/users/reconcile completou o cadastro
--                             em public.usuarios para uma identidade Auth que
--                             já existia (Estado C), sem reenviar convite e
--                             sem criar nova identidade.

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
    'USER_INVITE', 'USER_INVITE_FAILED', 'USER_RESEND_INVITE',
    'USER_DEACTIVATE', 'USER_REACTIVATE', 'USER_RESET_ACCESS',
    'PARTNER_DEACTIVATE', 'PARTNER_REACTIVATE',
    'SIGNATURE_TEST_CONNECTION',
    -- Fase 2.5.3 — novas ações, todas aditivas:
    'USER_INVITE_STARTED', 'USER_AUTH_CREATED', 'USER_PROFILE_CREATED', 'USER_INVITE_COMPLETED',
    'USER_AUTH_ROLLBACK', 'USER_AUTH_ORPHAN', 'USER_PROFILE_RECONCILED'
  ]));

comment on constraint auditoria_acao_check on public.auditoria is 'Fase 2.5.3 (seção 9/18): acrescenta as 7 ações do fluxo redesenhado de convite/rollback/reconciliação de usuários (Estados A/B/C/D). Mantém 100% das ações já existentes — nenhuma removida.';

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
    'SIGNATURE_TEST_CONNECTION',
    'USER_INVITE_STARTED', 'USER_AUTH_CREATED', 'USER_PROFILE_CREATED', 'USER_INVITE_COMPLETED',
    'USER_AUTH_ROLLBACK', 'USER_AUTH_ORPHAN', 'USER_PROFILE_RECONCILED'
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

comment on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb) is 'Fase 2.5.3: mesma função desde a Fase 2.3.1 (seção 28) — só a whitelist interna cresceu (7 ações novas de convite/rollback/reconciliação). SECURITY DEFINER para poder inserir em auditoria mesmo sem policy de INSERT para authenticated; sempre grava auth.uid() do chamador, nunca um usuario_id arbitrário vindo de parâmetro.';
