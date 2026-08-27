-- OptiMon — Fase 2.5 (3/9): Proposta — vínculo de responsável + status estendido
-- para cobrir o ciclo até a assinatura e geração do contrato (seções 20-21).
--
-- `propostas_comerciais.parceiro_id` já existe (é o "proponente_id" da seção 20 —
-- ver decisão de arquitetura na migration 02). Falta só `responsavel_id`.
--
-- Status: a Fase 2.4 já tem 9 valores (RASCUNHO..CANCELADA) cobrindo o fluxo de
-- aprovação comercial. A seção 21 desta fase estende esse MESMO fluxo (não cria
-- um paralelo) até a assinatura e geração de contrato — 3 valores novos:
-- EM_ASSINATURA ("EM ACEITE/ASSINATURA" da seção 21), ASSINADA, CONTRATO_GERADO.

alter table public.propostas_comerciais
  add column if not exists responsavel_id uuid references public.parceiros_responsaveis(id) on delete set null;

comment on column public.propostas_comerciais.responsavel_id is 'Fase 2.5 seção 20: responsável do proponente vinculado a esta proposta (signatário previsto). Snapshot do nome/cargo do responsável já é preservado em `snapshot` no momento da criação — igual ao já feito para o proponente.';

alter table public.propostas_comerciais drop constraint if exists propostas_comerciais_status_check;
alter table public.propostas_comerciais add constraint propostas_comerciais_status_check
  check (status = any (array[
    'RASCUNHO', 'EM_APROVACAO', 'APROVADA', 'ENVIADA', 'EM_NEGOCIACAO',
    'ACEITA', 'RECUSADA', 'EXPIRADA', 'CANCELADA',
    'EM_ASSINATURA', 'ASSINADA', 'CONTRATO_GERADO'
  ]));

-- Auditoria semântica: novas ações desta fase (assinatura, contrato, usuários,
-- documentos de proponente). Mantém a mesma lista já existente — só acrescenta.
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
    'PRICE_EXCEPTION_REQUEST'
  ]));

-- IP também nos eventos semânticos (a auditoria genérica de fn_auditoria() já
-- captura via o header x-forwarded-for repassado pelo PostgREST — seção 24/28
-- pede o mesmo para aprovação/assinatura, que passam por aqui).
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
    'PRICE_EXCEPTION_REQUEST'
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
