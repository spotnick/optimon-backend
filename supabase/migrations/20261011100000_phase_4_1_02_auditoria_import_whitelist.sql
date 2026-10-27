-- OptiMon — Fase 4.1 (item 02): amplia a whitelist de auditoria para os eventos
-- semânticos da importação de infraestrutura.
--
-- Aditivo em 2 pontos, nenhum dos dois remove nada do que já existia (mesma disciplina já
-- usada em todas as extensões anteriores desta whitelist):
--   1) public.auditoria.acao CHECK constraint — DROP + ADD com a lista antiga inteira mais
--      os eventos novos no final.
--   2) app.registrar_auditoria_semantica(8 params) — a assinatura REAL e atualmente usada
--      (confirmada por leitura de 20261010090000_phase_3_11_06_..., a migration mais
--      recente do projeto — ver relatório enviado ao usuário antes desta migration). As
--      versões de 6 e 7 parâmetros NÃO são tocadas por esta migration — continuam exatamente
--      como estão, intocadas (condição do usuário: "não presumir, não alterar funcionalidade
--      existente").
--
-- 10 eventos novos (IMPORT_*), cobrindo o ciclo de vida completo de staging.importacoes:
--   IMPORT_RECEIVE        — upload recebido, status RECEBIDA.
--   IMPORT_VALIDATE       — validação automática concluída, status EM_VALIDACAO→PREVIA.
--   IMPORT_PREVIEW_READY  — prévia pronta para revisão do usuário.
--   IMPORT_APPROVE        — usuário aprovou (APROVAR E IMPORTAR), status PREVIA→APROVADA.
--   IMPORT_APPLY          — app.aplicar_importacao concluiu com sucesso, status→IMPORTADA.
--   IMPORT_APPLY_FAILED   — app.aplicar_importacao abortou (transação revertida por inteiro).
--   IMPORT_REJECT         — usuário rejeitou antes de aprovar, status→REJEITADA.
--   IMPORT_DISCARD        — usuário descartou a importação, status→DESCARTADA.
--   IMPORT_REVERT         — app.reverter_importacao reverteu 100% dos itens, status→REVERTIDA.
--   IMPORT_REVERT_PARTIAL — reversão parcial (algum item não pôde ser revertido — ver
--                            Migration 4, staging.importacao_alteracoes.motivo_nao_revertido),
--                            status→REVERTIDA_PARCIALMENTE.

alter table public.auditoria drop constraint if exists auditoria_acao_check;
alter table public.auditoria add constraint auditoria_acao_check check (acao = any (array[
  'INSERT','UPDATE','DELETE','LOGIN','ARCHIVE','RESTORE','BLOCKED_ARCHIVE','BLOCKED_DELETE',
  'PROPOSAL_APPROVE','PROPOSAL_REJECT','PROPOSAL_STATUS_CHANGE','PROPOSAL_VERSION_CREATE',
  'PROPOSAL_DUPLICATE','PROPOSAL_EXPORT',
  'SIGNATURE_ENVELOPE_CREATE','SIGNATURE_ENVELOPE_SEND','SIGNATURE_ENVELOPE_CANCEL',
  'SIGNATURE_EVENT_RECEIVED','SIGNATURE_VALIDATED','SIGNATURE_TEST_CONNECTION',
  'SIGNATURE_SIGNER_RESEND',
  'SIGNATURE_SIGNER_ADDED','SIGNATURE_SEND_REQUESTED','SIGNATURE_SEND_ACCEPTED',
  'SIGNATURE_SEND_FAILED','SIGNATURE_ENVELOPE_SEND_FAILED','SIGNATURE_DELIVERED',
  'SIGNATURE_OPENED','SIGNATURE_SIGNED','SIGNATURE_DECLINED_BY_SIGNER','SIGNATURE_EMAIL_BOUNCED',
  'SIGNATURE_ACCEPT_OTP_REQUESTED','SIGNATURE_ACCEPT_OTP_FAILED','SIGNATURE_DOCUMENT_ASSINADO_GERADO',
  'CONTRACT_GENERATE','CONTRACT_ACTIVATE','CONTRACT_ACTIVATE_BLOCKED',
  'CONTRACT_ADDENDUM_CREATE','CONTRACT_ADDENDUM_APPROVE','CONTRACT_ADDENDUM_ACTIVATE',
  'CONTRACT_REAJUSTE_APLICADO','CONTRACT_MINUTA_EXPORT','CONTRACT_RULES_UPDATE',
  'CONTRACT_RESERVED_CLIENT_ADD','CONTRACT_RESERVED_CLIENT_UPDATE',
  'USER_PROFILE_CREATE','USER_PROFILE_UPDATE','PRICE_EXCEPTION_REQUEST',
  'USER_INVITE','USER_INVITE_FAILED','USER_RESEND_INVITE','USER_DEACTIVATE','USER_REACTIVATE',
  'USER_RESET_ACCESS','PARTNER_DEACTIVATE','PARTNER_REACTIVATE',
  'USER_INVITE_STARTED','USER_AUTH_CREATED','USER_PROFILE_CREATED','USER_INVITE_COMPLETED',
  'USER_AUTH_ROLLBACK','USER_AUTH_ORPHAN','USER_PROFILE_RECONCILED','USER_HARD_DELETE',
  'PON_ADDED','PON_REMOVED','POP_ADDED','POP_REMOVED','CLIENT_RESERVED_REMOVED',
  'CONTRACT_TERMINATED','THIRD_PARTY_INFRA_REQUEST','THIRD_PARTY_INFRA_APPROVED',
  'OWN_NETWORK_EXCEPTION_REQUEST','OWN_NETWORK_EXCEPTION',
  'PROPOSAL_CREATED','PROPOSAL_UPDATED','CONTRACT_MINUTA_GENERATED',
  'PROPOSAL_SENT_TO_PARTNER','PROPOSAL_VIEWED_BY_PARTNER',
  'PROPOSAL_ACCEPTED_BY_PARTNER','PROPOSAL_DECLINED_BY_PARTNER',
  'PROPOSAL_ACCEPT_OTP_REQUESTED','PROPOSAL_ACCEPT_OTP_FAILED','PROPOSAL_ACCEPT_BLOCKED',
  'PROPOSAL_TOKEN_REVOKED',
  'PROPOSAL_ACCEPT_EMAIL_REQUESTED','PROPOSAL_ACCEPT_EMAIL_ACCEPTED_BY_PROVIDER',
  'PROPOSAL_ACCEPT_EMAIL_DELIVERED','PROPOSAL_ACCEPT_EMAIL_BOUNCED',
  'PROPOSAL_ACCEPT_EMAIL_COMPLAINED','PROPOSAL_ACCEPT_EMAIL_FAILED',
  'PROPOSAL_ACCEPT_DOCUMENT_GENERATED',
  'CLEANUP_HOMOLOGACAO',
  -- Fase 4.1 (Importação de Infraestrutura):
  'IMPORT_RECEIVE', 'IMPORT_VALIDATE', 'IMPORT_PREVIEW_READY', 'IMPORT_APPROVE',
  'IMPORT_APPLY', 'IMPORT_APPLY_FAILED', 'IMPORT_REJECT', 'IMPORT_DISCARD',
  'IMPORT_REVERT', 'IMPORT_REVERT_PARTIAL'
]));

-- app.registrar_auditoria_semantica (8 params — a assinatura real e atual) recebe a MESMA
-- lista ampliada na whitelist interna. CREATE OR REPLACE preserva tudo que já existia.
create or replace function app.registrar_auditoria_semantica(
  p_entidade text, p_entidade_id uuid, p_acao text, p_motivo text default null,
  p_valor_anterior jsonb default null, p_valor_novo jsonb default null,
  p_origem text default 'app', p_ip text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_ip inet;
begin
  if p_acao not in (
    'ARCHIVE', 'RESTORE', 'BLOCKED_ARCHIVE', 'BLOCKED_DELETE',
    'PROPOSAL_APPROVE', 'PROPOSAL_REJECT', 'PROPOSAL_STATUS_CHANGE',
    'PROPOSAL_VERSION_CREATE', 'PROPOSAL_DUPLICATE', 'PROPOSAL_EXPORT',
    'SIGNATURE_ENVELOPE_CREATE', 'SIGNATURE_ENVELOPE_SEND', 'SIGNATURE_ENVELOPE_CANCEL',
    'SIGNATURE_EVENT_RECEIVED', 'SIGNATURE_VALIDATED', 'SIGNATURE_SIGNER_RESEND',
    'SIGNATURE_SIGNER_ADDED', 'SIGNATURE_SEND_REQUESTED', 'SIGNATURE_SEND_ACCEPTED',
    'SIGNATURE_SEND_FAILED', 'SIGNATURE_ENVELOPE_SEND_FAILED', 'SIGNATURE_DELIVERED',
    'SIGNATURE_OPENED', 'SIGNATURE_SIGNED', 'SIGNATURE_DECLINED_BY_SIGNER', 'SIGNATURE_EMAIL_BOUNCED',
    'SIGNATURE_ACCEPT_OTP_REQUESTED', 'SIGNATURE_ACCEPT_OTP_FAILED', 'SIGNATURE_DOCUMENT_ASSINADO_GERADO',
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
    'USER_AUTH_ROLLBACK', 'USER_AUTH_ORPHAN', 'USER_PROFILE_RECONCILED',
    'CONTRACT_MINUTA_EXPORT', 'CONTRACT_RULES_UPDATE', 'CONTRACT_RESERVED_CLIENT_ADD', 'CONTRACT_RESERVED_CLIENT_UPDATE',
    'USER_HARD_DELETE',
    'PON_ADDED', 'PON_REMOVED', 'POP_ADDED', 'POP_REMOVED', 'CLIENT_RESERVED_REMOVED',
    'CONTRACT_TERMINATED', 'THIRD_PARTY_INFRA_REQUEST', 'THIRD_PARTY_INFRA_APPROVED',
    'OWN_NETWORK_EXCEPTION_REQUEST', 'OWN_NETWORK_EXCEPTION',
    'PROPOSAL_CREATED', 'PROPOSAL_UPDATED', 'CONTRACT_MINUTA_GENERATED',
    'PROPOSAL_SENT_TO_PARTNER', 'PROPOSAL_VIEWED_BY_PARTNER',
    'PROPOSAL_ACCEPTED_BY_PARTNER', 'PROPOSAL_DECLINED_BY_PARTNER',
    'PROPOSAL_ACCEPT_OTP_REQUESTED', 'PROPOSAL_ACCEPT_OTP_FAILED', 'PROPOSAL_ACCEPT_BLOCKED',
    'PROPOSAL_TOKEN_REVOKED',
    'PROPOSAL_ACCEPT_EMAIL_REQUESTED', 'PROPOSAL_ACCEPT_EMAIL_ACCEPTED_BY_PROVIDER',
    'PROPOSAL_ACCEPT_EMAIL_DELIVERED', 'PROPOSAL_ACCEPT_EMAIL_BOUNCED',
    'PROPOSAL_ACCEPT_EMAIL_COMPLAINED', 'PROPOSAL_ACCEPT_EMAIL_FAILED',
    'PROPOSAL_ACCEPT_DOCUMENT_GENERATED',
    'CLEANUP_HOMOLOGACAO',
    -- Fase 4.1:
    'IMPORT_RECEIVE', 'IMPORT_VALIDATE', 'IMPORT_PREVIEW_READY', 'IMPORT_APPROVE',
    'IMPORT_APPLY', 'IMPORT_APPLY_FAILED', 'IMPORT_REJECT', 'IMPORT_DISCARD',
    'IMPORT_REVERT', 'IMPORT_REVERT_PARTIAL'
  ) then
    raise exception 'app.registrar_auditoria_semantica: ação % não está na whitelist.', p_acao;
  end if;

  if p_ip is not null then
    begin
      v_ip := p_ip::inet;
    exception when others then
      v_ip := null;
    end;
  end if;

  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, valor_anterior, valor_novo, origem, motivo, ip)
  values (auth.uid(), p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, p_origem, p_motivo, v_ip);
end;
$function$;
