-- OptiMon — Fase 3.11.4: AUDITORIA E CORREÇÃO DO ENVIO REAL DE ASSINATURA ELETRÔNICA.
--
-- CAUSA RAIZ (comprovada por auditoria de código, seções 1-3 do pedido, sem alterar
-- nenhum código antes de terminar a auditoria): o ÚNICO provedor de assinatura já
-- implementado é `MockHomologacaoProvider` (api/lib/signatureProvider.js) — nunca toca
-- rede real, nunca envia e-mail nenhum, só simula um ciclo de vida determinístico. A
-- função `app.enviar_envelope_para_assinatura` marcava `status='ENVIADO'` de forma
-- INCONDICIONAL no momento em que era chamada, sem nenhuma prova real de que alguém
-- tentou notificar os signatários — daí o envelope real 571aa526 mostrar "ENVIADO" para
-- 3 destinatários que nunca receberam nada: não havia, e nunca houve, nenhum mecanismo
-- de envio real ligado a este fluxo. O Resend (Fase 3.11.3) é 100% independente disto —
-- nenhuma linha deste código antigo o chamava.
--
-- DECISÃO DE ARQUITETURA (confirmada explicitamente pelo usuário, seção 12 do pedido:
-- "documentar claramente essa arquitetura e implementá-la de forma consistente"): não
-- existe hoje contrato/credencial com nenhum provedor ICP-Brasil real (D4Sign/Clicksign/
-- DocuSign/ZapSign/Autentique) — em vez de inventar uma integração que não pode ser
-- testada de verdade, o OptiMon passa a ser o próprio orquestrador do envio: gera um
-- link de acesso individual (token opaco de alta entropia, MESMO padrão já usado e
-- testado para o link externo de aceite de proposta — app.enviar_proposta_parceiro) por
-- signatário, envia esse link por e-mail via o client Resend REAL já construído e testado
-- na Fase 3.11.3 (api/lib/emailService.js — reaproveitado, nunca duplicado), e registra
-- ASSINADO só quando o próprio signatário confirma no link (nunca por presunção).
--
-- IMPORTANTE (transparência jurídica — não é uma opinião jurídica, é uma descrição
-- técnica honesta, seção "PRINCÍPIO ICP-BRASIL FIRST" do schema original preservada):
-- isto é uma ASSINATURA ELETRÔNICA SIMPLES (evidenciada por link único enviado ao e-mail
-- cadastrado + IP + user-agent + timestamp), NUNCA uma assinatura ICP-Brasil qualificada
-- validada por uma Autoridade Certificadora — `certificado_info`/`pades` refletem isso
-- honestamente (ver função `app.confirmar_assinatura_via_link` abaixo). Se o negócio
-- precisar de assinatura ICP-Brasil qualificada para algum tipo de documento, isso exige
-- contratar um provedor real — `tipo='ICP_BRASIL_PROVEDOR_EXTERNO'` já existe no schema
-- para essa integração futura, sem quebrar nada do que é entregue aqui.

-- ============================================================================
-- 1) signature_providers.tipo — novo valor OPTIMON_INTERNO_RESEND.
-- ============================================================================

alter table public.signature_providers drop constraint if exists signature_providers_tipo_check;
alter table public.signature_providers add constraint signature_providers_tipo_check check (tipo = any (array[
  'ICP_BRASIL_HOMOLOGACAO_MOCK', 'ICP_BRASIL_PROVEDOR_EXTERNO', 'OPTIMON_INTERNO_RESEND'
]));

comment on constraint signature_providers_tipo_check on public.signature_providers is 'Fase 3.11.4: acrescenta OPTIMON_INTERNO_RESEND — o OptiMon envia o link de assinatura por e-mail via Resend (api/lib/emailService.js, mesmo client da Fase 3.11.3), sem depender de nenhum provedor ICP-Brasil terceirizado (nenhum está contratado — ver relatório final).';

-- ============================================================================
-- 2) signature_envelopes.status — novo valor ERRO_ENVIO (seção 3/11 do pedido: nunca
--    marcar ENVIADO sem prova real de aceite pelo provedor; se TODOS os envios de
--    signatário falharem, o envelope fica em ERRO_ENVIO, nunca em ENVIADO).
-- ============================================================================

alter table public.signature_envelopes drop constraint if exists signature_envelopes_status_check;
alter table public.signature_envelopes add constraint signature_envelopes_status_check check (status = any (array[
  'CRIADO', 'ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO', 'ASSINADO',
  'VALIDADO', 'RECUSADO', 'CANCELADO', 'EXPIRADO', 'ERRO', 'ERRO_ENVIO'
]));

-- ============================================================================
-- 3) signature_signers — novo valor ERRO_ENVIO + colunas do link de acesso individual
--    (mesmo padrão de token opaco de propostas_comerciais.token_acesso_externo) e de
--    rastreio do e-mail no Resend (mesmo padrão de propostas_aceite_tentativas.
--    email_provider_id/email_canal da Fase 3.11.3 — nunca uma solução nova).
-- ============================================================================

alter table public.signature_signers drop constraint if exists signature_signers_status_check;
alter table public.signature_signers add constraint signature_signers_status_check check (status = any (array[
  'PENDENTE', 'VISUALIZADO',
  'CRIADO', 'ENVIANDO', 'ENVIADO', 'ENTREGUE', 'ABERTO', 'ASSINADO', 'RECUSADO', 'EXPIRADO', 'ERRO', 'ERRO_ENVIO'
]));

alter table public.signature_signers
  add column if not exists token_acesso text unique,
  add column if not exists token_expira_em timestamptz,
  add column if not exists email_provider_id text,
  add column if not exists email_canal text;

comment on column public.signature_signers.token_acesso is 'Fase 3.11.4: token opaco de 64 hex chars (32 bytes CSPRNG) — a credencial do link individual de assinatura enviado por e-mail, mesmo padrão de propostas_comerciais.token_acesso_externo. Nunca um JWT, nunca carrega claim nenhuma — toda validação de estado acontece no servidor a cada chamada.';
comment on column public.signature_signers.email_provider_id is 'Fase 3.11.4: id do e-mail no Resend para ESTE signatário (mesmo papel de propostas_aceite_tentativas.email_provider_id) — usado pelo webhook do Resend (api/routes/emailWebhooks.js) para atualizar ENTREGUE/falha sem precisar de um 2º webhook.';

create index if not exists signature_signers_token_acesso_idx on public.signature_signers(token_acesso) where token_acesso is not null;
create index if not exists signature_signers_email_provider_id_idx on public.signature_signers(email_provider_id) where email_provider_id is not null;

-- ============================================================================
-- 4) Auditoria — novas ações (seção 15 do pedido): ENVELOPE_CREATED/SIGNER_ADDED já
--    existiam com outro nome (SIGNATURE_ENVELOPE_CREATE) — mantido, nunca renomeado
--    (quebraria histórico). As novas cobrem exatamente os eventos que faltavam: pedido
--    de envio, aceite/recusa do Resend, falha de envio, entrega, abertura do link,
--    assinatura real e recusa pelo signatário.
-- ============================================================================

alter table public.auditoria drop constraint if exists auditoria_acao_check;
alter table public.auditoria add constraint auditoria_acao_check check (acao = any (array[
  'INSERT','UPDATE','DELETE','LOGIN','ARCHIVE','RESTORE','BLOCKED_ARCHIVE','BLOCKED_DELETE',
  'PROPOSAL_APPROVE','PROPOSAL_REJECT','PROPOSAL_STATUS_CHANGE','PROPOSAL_VERSION_CREATE',
  'PROPOSAL_DUPLICATE','PROPOSAL_EXPORT',
  'SIGNATURE_ENVELOPE_CREATE','SIGNATURE_ENVELOPE_SEND','SIGNATURE_ENVELOPE_CANCEL',
  'SIGNATURE_EVENT_RECEIVED','SIGNATURE_VALIDATED','SIGNATURE_TEST_CONNECTION',
  'SIGNATURE_SIGNER_RESEND',
  -- Fase 3.11.4 (seção 15 do pedido):
  'SIGNATURE_SIGNER_ADDED','SIGNATURE_SEND_REQUESTED','SIGNATURE_SEND_ACCEPTED',
  'SIGNATURE_SEND_FAILED','SIGNATURE_ENVELOPE_SEND_FAILED','SIGNATURE_DELIVERED',
  'SIGNATURE_OPENED','SIGNATURE_SIGNED','SIGNATURE_DECLINED_BY_SIGNER','SIGNATURE_EMAIL_BOUNCED',
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
  'PROPOSAL_ACCEPT_EMAIL_COMPLAINED','PROPOSAL_ACCEPT_EMAIL_FAILED'
]));

drop function if exists app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb, text, text);

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
    'PROPOSAL_ACCEPT_EMAIL_COMPLAINED', 'PROPOSAL_ACCEPT_EMAIL_FAILED'
  ) then
    raise exception 'app.registrar_auditoria_semantica: ação inválida %.', p_acao;
  end if;

  if p_ip is not null then
    begin
      v_ip := nullif(split_part(p_ip, ',', 1), '')::inet;
    exception when others then
      v_ip := null;
    end;
  else
    begin
      v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', '')::inet;
    exception when others then
      v_ip := null;
    end;
  end if;

  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, valor_anterior, valor_novo, motivo, origem, ip)
  values (auth.uid(), p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, p_motivo, coalesce(p_origem, 'app'), v_ip);
end;
$function$;

grant execute on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb, text, text) to authenticated, anon;

-- ============================================================================
-- 5) app.envelope_signatario_gerar_link — gera o token opaco individual (seção 4/6 do
--    pedido: "REENVIAR deve realmente chamar a API do provedor" — aqui o "provedor" é o
--    próprio Resend, e gerar um token novo a cada tentativa de envio garante que um link
--    antigo (ex.: de um reenvio anterior) para de valer, mesmo padrão de
--    app.enviar_proposta_parceiro). Chamada pelo Node (usuário autenticado) ANTES de
--    tentar enviar o e-mail — nunca depois.
-- ============================================================================

create or replace function app.envelope_signatario_gerar_link(p_signer_id uuid, p_validade_dias integer default 30)
returns jsonb
language plpgsql
security invoker
as $$
declare
  v_signer public.signature_signers;
  v_token text;
  v_expira timestamptz;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem gerar link de assinatura.';
  end if;

  select * into v_signer from public.signature_signers where id = p_signer_id;
  if v_signer.id is null then
    raise exception 'NAO_ENCONTRADO: signatário % não encontrado.', p_signer_id;
  end if;
  if v_signer.status = 'ASSINADO' then
    raise exception 'STATUS_INVALIDO: signatário já assinou — não é possível gerar um novo link para quem já concluiu.';
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');
  v_expira := now() + make_interval(days => greatest(coalesce(p_validade_dias, 30), 1));

  update public.signature_signers
     set token_acesso = v_token, token_expira_em = v_expira
   where id = p_signer_id;

  return jsonb_build_object('signer_id', p_signer_id, 'token', v_token, 'expira_em', v_expira);
end;
$$;
comment on function app.envelope_signatario_gerar_link(uuid, integer) is 'Fase 3.11.4: gera (ou renova, a cada envio/reenvio) o token de acesso individual do link de assinatura — token novo invalida o antigo (mesmo padrão de app.enviar_proposta_parceiro).';

drop function if exists public.pricing_signature_signer_gerar_link(uuid, integer);
create or replace function public.pricing_signature_signer_gerar_link(p_signer_id uuid, p_validade_dias integer default 30)
returns jsonb
language sql security invoker
as $$ select app.envelope_signatario_gerar_link(p_signer_id, p_validade_dias); $$;
grant execute on function public.pricing_signature_signer_gerar_link(uuid, integer) to authenticated;

-- ============================================================================
-- 6) app.registrar_envio_signatario — grava o resultado REAL da tentativa de envio pelo
--    Resend (seção 3/11 do pedido: nunca ENVIADO sem prova de aceite do provedor). Chamada
--    pelo Node depois de tentar api/lib/emailService.js — nunca antes.
-- ============================================================================

create or replace function app.registrar_envio_signatario(
  p_signer_id uuid,
  p_sucesso boolean,
  p_email_provider_id text default null,
  p_email_canal text default null,
  p_erro_mensagem text default null
)
returns public.signature_signers
language plpgsql
security invoker
as $$
declare
  v_signer public.signature_signers;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem registrar envio de assinatura.';
  end if;

  if p_sucesso then
    update public.signature_signers
       set status = 'ENVIADO',
           enviado_em = now(),
           email_provider_id = coalesce(p_email_provider_id, email_provider_id),
           email_canal = coalesce(p_email_canal, email_canal),
           erro_mensagem = null,
           entregue_em = null,
           aberto_em = null
     where id = p_signer_id
     returning * into v_signer;
    perform app.registrar_auditoria_semantica('signature_signers', p_signer_id, 'SIGNATURE_SEND_ACCEPTED',
      format('E-mail aceito pelo Resend (canal=%s).', coalesce(p_email_canal, '?')), null,
      jsonb_build_object('email_provider_id', p_email_provider_id, 'email_canal', p_email_canal));
  else
    update public.signature_signers
       set status = 'ERRO_ENVIO',
           erro_mensagem = p_erro_mensagem
     where id = p_signer_id
     returning * into v_signer;
    perform app.registrar_auditoria_semantica('signature_signers', p_signer_id, 'SIGNATURE_SEND_FAILED',
      p_erro_mensagem, null, jsonb_build_object('erro', p_erro_mensagem));
  end if;

  if v_signer.id is null then
    raise exception 'NAO_ENCONTRADO: signatário % não encontrado.', p_signer_id;
  end if;

  return v_signer;
end;
$$;
comment on function app.registrar_envio_signatario(uuid, boolean, text, text, text) is 'Fase 3.11.4 (seção 3/11): ENVIADO só é gravado aqui, depois que o Node confirma que o Resend aceitou o e-mail (tem email_id) — nunca antes. Falha real vira ERRO_ENVIO, nunca ENVIADO silencioso.';

drop function if exists public.pricing_signature_signer_registrar_envio(uuid, boolean, text, text, text);
create or replace function public.pricing_signature_signer_registrar_envio(
  p_signer_id uuid, p_sucesso boolean, p_email_provider_id text default null,
  p_email_canal text default null, p_erro_mensagem text default null
)
returns public.signature_signers
language sql security invoker
as $$ select app.registrar_envio_signatario(p_signer_id, p_sucesso, p_email_provider_id, p_email_canal, p_erro_mensagem); $$;
grant execute on function public.pricing_signature_signer_registrar_envio(uuid, boolean, text, text, text) to authenticated;

-- ============================================================================
-- 7) app.finalizar_envio_envelope — decide o status do ENVELOPE depois de tentar enviar
--    para todos os signatários (seção 3/11: ENVIADO só com evidência suficiente; se
--    NENHUM signatário recebeu o e-mail de verdade, o envelope vai para ERRO_ENVIO, nunca
--    para ENVIADO). Preserva o cascade para propostas_comerciais/contrato_aditivos já
--    existente em app.enviar_envelope_para_assinatura (seção 17: não quebrar o que já
--    funciona), só que agora condicionado a pelo menos 1 envio real ter sido aceito.
-- ============================================================================

create or replace function app.finalizar_envio_envelope(p_envelope_id uuid)
returns public.signature_envelopes
language plpgsql
security invoker
as $$
declare
  v_envelope public.signature_envelopes;
  v_algum_sucesso boolean;
  v_status_final text;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem finalizar o envio de um envelope.';
  end if;

  select * into v_envelope from public.signature_envelopes where id = p_envelope_id;
  if v_envelope.id is null then
    raise exception 'NAO_ENCONTRADO: envelope % não encontrado.', p_envelope_id;
  end if;
  if v_envelope.status not in ('CRIADO', 'ERRO_ENVIO') then
    raise exception 'STATUS_INVALIDO: envelope % já está em status % — não pode ser reenviado por aqui.', v_envelope.id, v_envelope.status;
  end if;
  if not exists (select 1 from public.signature_signers where envelope_id = v_envelope.id) then
    raise exception 'SEM_SIGNATARIOS: adicione pelo menos um signatário antes de enviar para assinatura.';
  end if;

  select exists (
    select 1 from public.signature_signers
     where envelope_id = v_envelope.id and status = 'ENVIADO'
  ) into v_algum_sucesso;

  v_status_final := case when v_algum_sucesso then 'ENVIADO' else 'ERRO_ENVIO' end;

  update public.signature_envelopes
     set status = v_status_final,
         enviado_em = case when v_algum_sucesso then now() else enviado_em end,
         erro_mensagem = case when not v_algum_sucesso then 'Falha ao enviar e-mail para TODOS os signatários — nenhum e-mail foi aceito pelo Resend. Ver erro_mensagem de cada signatário.' else null end
   where id = v_envelope.id
   returning * into v_envelope;

  if v_algum_sucesso then
    if v_envelope.tipo_documento = 'PROPOSTA' then
      update public.propostas_comerciais set status = 'EM_ASSINATURA' where id = v_envelope.proposta_id;
    elsif v_envelope.tipo_documento = 'ADITIVO' then
      update public.contrato_aditivos set status = 'EM_APROVACAO' where id = v_envelope.aditivo_id and status = 'RASCUNHO';
    end if;
    perform app.registrar_auditoria_semantica('signature_envelopes', v_envelope.id, 'SIGNATURE_ENVELOPE_SEND',
      'Envio real solicitado — pelo menos 1 signatário recebeu o link por e-mail (Resend).', null, to_jsonb(v_envelope));
  else
    perform app.registrar_auditoria_semantica('signature_envelopes', v_envelope.id, 'SIGNATURE_ENVELOPE_SEND_FAILED',
      v_envelope.erro_mensagem, null, to_jsonb(v_envelope));
  end if;

  return v_envelope;
end;
$$;
comment on function app.finalizar_envio_envelope(uuid) is 'Fase 3.11.4 (seção 3/11): substitui a marcação incondicional de ENVIADO — só marca ENVIADO se pelo menos 1 signatário teve o e-mail REALMENTE aceito pelo Resend (ver app.registrar_envio_signatario); senão ERRO_ENVIO. Também aceita reenviar (ERRO_ENVIO -> tentar de novo).';

drop function if exists public.pricing_signature_envelope_finalizar_envio(uuid);
create or replace function public.pricing_signature_envelope_finalizar_envio(p_envelope_id uuid)
returns public.signature_envelopes
language sql security invoker
as $$ select app.finalizar_envio_envelope(p_envelope_id); $$;
grant execute on function public.pricing_signature_envelope_finalizar_envio(uuid) to authenticated;

-- ============================================================================
-- 8) Área externa do signatário (mirror deliberado de app.proposta_externa_por_token /
--    app.enviar_proposta_parceiro / app.recusar_proposta_parceiro, Fase 3.11/3.11.2 —
--    mesmo padrão de token opaco + validações + SECURITY DEFINER para `anon`, seção 12
--    do pedido: "não criar uma segunda solução sem necessidade").
-- ============================================================================

-- 8a) Visualizar pelo link — GET, nunca representa assinatura (seção 13, item 6/7:
--     "abrir o link" só gera o evento OPENED). Idempotente: reabrir o link não regride
--     nem duplica nada.
create or replace function app.assinatura_externa_por_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
  v_envelope public.signature_envelopes;
  v_resultado jsonb;
begin
  select * into v_signer from public.signature_signers where token_acesso = p_token;
  if v_signer.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  if v_signer.token_expira_em is not null and v_signer.token_expira_em < now() then
    raise exception 'TOKEN_EXPIRADO: este link expirou — solicite um novo envio.';
  end if;

  select * into v_envelope from public.signature_envelopes where id = v_signer.envelope_id;
  if v_envelope.status = 'CANCELADO' then
    raise exception 'ENVELOPE_CANCELADO: este envelope de assinatura foi cancelado.';
  end if;

  -- Marca ABERTO só na primeira vez e só avançando (nunca regride quem já assinou/
  -- recusou, nunca sobrescreve aberto_em já gravado — seção 11: evidência real, uma vez).
  if v_signer.status in ('ENVIADO', 'ENTREGUE') then
    update public.signature_signers
       set status = 'ABERTO', aberto_em = coalesce(aberto_em, now())
     where id = v_signer.id
     returning * into v_signer;
    perform app.registrar_auditoria_semantica('signature_signers', v_signer.id, 'SIGNATURE_OPENED',
      null, null, jsonb_build_object('envelope_id', v_envelope.id), 'signatario_externo');
  end if;

  -- Nunca expõe piso/margem/desconto/governança/dado interno NICK (seção 12/21 da Fase
  -- 3.11.3, reaplicado aqui): só o necessário para o signatário revisar e assinar.
  select jsonb_build_object(
    'signer_id', v_signer.id, 'nome', v_signer.nome, 'email', v_signer.email, 'papel', v_signer.papel,
    'status', v_signer.status, 'ja_assinado', v_signer.status = 'ASSINADO', 'ja_recusado', v_signer.status = 'RECUSADO',
    'envelope_id', v_envelope.id, 'tipo_documento', v_envelope.tipo_documento, 'envelope_status', v_envelope.status,
    'documento_disponivel', v_envelope.documento_original_storage_path is not null,
    'proposta_numero', (select numero from public.propostas_comerciais where id = v_envelope.proposta_id),
    'contrato_numero', (select numero from public.contratos where id = v_envelope.contrato_id)
  ) into v_resultado;

  return v_resultado;
end;
$$;
comment on function app.assinatura_externa_por_token(text) is 'Fase 3.11.4 (seção 13, itens 6-7): visualização pelo link — só registra OPENED, nunca representa assinatura. Mirror de app.proposta_externa_por_token.';

drop function if exists public.pricing_signature_external_by_token(text);
create or replace function public.pricing_signature_external_by_token(p_token text)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.assinatura_externa_por_token(p_token); $$;
grant execute on function public.pricing_signature_external_by_token(text) to anon;

-- 8b) Assinar pelo link — só aqui ASSINADO é gravado, e só com a declaração explícita
--     marcada (seção 13, itens 8-9: "Assinar" -> "Confirmar evento SIGNED"). Honesto sobre
--     a natureza da assinatura (ver cabeçalho da migration): ASSINATURA ELETRÔNICA
--     SIMPLES, nunca ICP-Brasil qualificada.
create or replace function app.confirmar_assinatura_via_link(
  p_token text, p_nome_confirmacao text, p_documento_confirmacao text, p_declaracao boolean,
  p_ip text default null, p_user_agent text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
  v_envelope public.signature_envelopes;
  v_todos_obrigatorios_assinaram boolean;
  v_ip_final inet;
begin
  if p_nome_confirmacao is null or trim(p_nome_confirmacao) = '' then
    raise exception 'DADOS_OBRIGATORIOS: nome completo é obrigatório para confirmar a assinatura.';
  end if;
  if p_documento_confirmacao is null or trim(p_documento_confirmacao) = '' then
    raise exception 'DADOS_OBRIGATORIOS: CPF é obrigatório para confirmar a assinatura.';
  end if;
  if p_declaracao is distinct from true then
    raise exception 'DECLARACAO_OBRIGATORIA: é necessário declarar que é você quem está assinando e que concorda com o conteúdo do documento.';
  end if;

  select * into v_signer from public.signature_signers where token_acesso = p_token for update;
  if v_signer.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  if v_signer.token_expira_em is not null and v_signer.token_expira_em < now() then
    raise exception 'TOKEN_EXPIRADO: este link expirou — solicite um novo envio.';
  end if;
  if v_signer.status = 'ASSINADO' then
    raise exception 'ASSINATURA_DUPLICADA: este signatário já assinou — não é possível assinar duas vezes.';
  end if;
  if v_signer.status = 'RECUSADO' then
    raise exception 'STATUS_INVALIDO: este signatário já recusou este documento.';
  end if;
  if v_signer.status not in ('ENVIADO', 'ENTREGUE', 'ABERTO') then
    raise exception 'STATUS_INVALIDO: signatário em status % — não é possível assinar agora.', v_signer.status;
  end if;

  select * into v_envelope from public.signature_envelopes where id = v_signer.envelope_id for update;
  if v_envelope.status = 'CANCELADO' then raise exception 'ENVELOPE_CANCELADO: este envelope foi cancelado.'; end if;

  begin
    v_ip_final := nullif(split_part(coalesce(p_ip, ''), ',', 1), '')::inet;
  exception when others then
    v_ip_final := null;
  end;

  update public.signature_signers
     set status = 'ASSINADO',
         assinado_em = now(),
         ip_assinatura = coalesce(p_ip, ip_assinatura),
         certificado_info = jsonb_build_object(
           'tipo', 'ASSINATURA_ELETRONICA_SIMPLES',
           'metodo', 'LINK_UNICO_EMAIL_RESEND',
           'nome_confirmado', trim(p_nome_confirmacao),
           'documento_confirmado', trim(p_documento_confirmacao),
           'user_agent', p_user_agent,
           'observacao', 'Não é uma assinatura ICP-Brasil qualificada validada por Autoridade Certificadora — evidenciada por link único enviado ao e-mail cadastrado, IP e timestamp (Fase 3.11.4).'
         )
   where id = v_signer.id
   returning * into v_signer;

  perform app.registrar_auditoria_semantica('signature_signers', v_signer.id, 'SIGNATURE_SIGNED',
    'Assinatura eletrônica simples confirmada pelo signatário via link individual.', null,
    jsonb_build_object('nome_confirmado', trim(p_nome_confirmacao), 'user_agent', p_user_agent), 'signatario_externo', p_ip);

  -- Fase 3.11.2 (seção 7), reaplicado aqui: NUNCA marca o envelope ASSINADO só porque
  -- este signatário assinou — recalcula se TODOS os obrigatórios já assinaram de verdade.
  select not exists (
    select 1 from public.signature_signers
     where envelope_id = v_envelope.id and obrigatorio and status <> 'ASSINADO'
  ) into v_todos_obrigatorios_assinaram;

  if coalesce(v_todos_obrigatorios_assinaram, false) then
    update public.signature_envelopes
       set status = 'ASSINADO', concluido_em = now()
     where id = v_envelope.id
     returning * into v_envelope;

    insert into public.documentos_assinados (envelope_id, storage_path_original, storage_path_assinado, hash_sha256_original, hash_sha256_assinado, formato, pades)
    values (v_envelope.id, v_envelope.documento_original_storage_path, v_envelope.documento_original_storage_path, v_envelope.hash_original, v_envelope.hash_original, 'PDF', false)
    on conflict (envelope_id) do update
      set storage_path_assinado = excluded.storage_path_assinado,
          hash_sha256_assinado = excluded.hash_sha256_assinado;

    if v_envelope.tipo_documento = 'PROPOSTA' then
      update public.propostas_comerciais set status = 'ASSINADA' where id = v_envelope.proposta_id;
    end if;

    perform app.registrar_auditoria_semantica('signature_envelopes', v_envelope.id, 'SIGNATURE_VALIDATED',
      'Todos os signatários obrigatórios assinaram — envelope concluído.', null, to_jsonb(v_envelope));
  else
    update public.signature_envelopes set status = 'PARCIALMENTE_ASSINADO' where id = v_envelope.id and status not in ('ASSINADO', 'VALIDADO');
  end if;

  return jsonb_build_object('signer_id', v_signer.id, 'status', v_signer.status, 'assinado_em', v_signer.assinado_em, 'envelope_status', v_envelope.status);
end;
$$;
comment on function app.confirmar_assinatura_via_link(text, text, text, boolean, text, text) is 'Fase 3.11.4 (seção 3/11/13): só aqui ASSINADO é gravado — nunca por presunção. Honesto sobre a natureza da assinatura (eletrônica simples, não ICP-Brasil qualificada). Recalcula obrigatórios antes de concluir o envelope, mesma correção da Fase 3.11.2.';

drop function if exists public.pricing_signature_external_assinar(text, text, text, boolean, text, text);
create or replace function public.pricing_signature_external_assinar(
  p_token text, p_nome_confirmacao text, p_documento_confirmacao text, p_declaracao boolean,
  p_ip text default null, p_user_agent text default null
)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.confirmar_assinatura_via_link(p_token, p_nome_confirmacao, p_documento_confirmacao, p_declaracao, p_ip, p_user_agent); $$;
grant execute on function public.pricing_signature_external_assinar(text, text, text, boolean, text, text) to anon;

-- 8c) Recusar pelo link — motivo sempre obrigatório (mesmo padrão de
--     app.recusar_proposta_parceiro).
create or replace function app.recusar_assinatura_via_link(p_token text, p_motivo text, p_ip text default null, p_user_agent text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
  v_envelope public.signature_envelopes;
begin
  if p_motivo is null or trim(p_motivo) = '' then raise exception 'MOTIVO_OBRIGATORIO: informe o motivo da recusa.'; end if;

  select * into v_signer from public.signature_signers where token_acesso = p_token for update;
  if v_signer.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  if v_signer.status = 'ASSINADO' then raise exception 'STATUS_INVALIDO: este signatário já assinou — não é possível recusar depois de assinar.'; end if;
  if v_signer.status = 'RECUSADO' then raise exception 'STATUS_INVALIDO: este signatário já recusou este documento.'; end if;

  select * into v_envelope from public.signature_envelopes where id = v_signer.envelope_id for update;

  update public.signature_signers
     set status = 'RECUSADO', erro_mensagem = trim(p_motivo)
   where id = v_signer.id
   returning * into v_signer;

  perform app.registrar_auditoria_semantica('signature_signers', v_signer.id, 'SIGNATURE_DECLINED_BY_SIGNER',
    trim(p_motivo), null, jsonb_build_object('user_agent', p_user_agent), 'signatario_externo', p_ip);

  if v_signer.obrigatorio then
    update public.signature_envelopes set status = 'RECUSADO' where id = v_envelope.id and status not in ('ASSINADO', 'VALIDADO');
  end if;

  return jsonb_build_object('signer_id', v_signer.id, 'status', v_signer.status);
end;
$$;

drop function if exists public.pricing_signature_external_recusar(text, text, text, text);
create or replace function public.pricing_signature_external_recusar(p_token text, p_motivo text, p_ip text default null, p_user_agent text default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.recusar_assinatura_via_link(p_token, p_motivo, p_ip, p_user_agent); $$;
grant execute on function public.pricing_signature_external_recusar(text, text, text, text) to anon;

-- ============================================================================
-- 9) Webhook do Resend reaproveitado (seção 9/12 do pedido: "não criar uma segunda
--    solução sem necessidade") — o mesmo webhook já construído/testado na Fase 3.11.3
--    (api/routes/emailWebhooks.js) passa a também procurar signature_signers por
--    email_provider_id quando não encontra uma tentativa de OTP de proposta.
-- ============================================================================

create or replace function app.registrar_status_email_assinatura_por_provider_id(
  p_email_provider_id text, p_evento text, p_detalhe text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
begin
  select * into v_signer from public.signature_signers where email_provider_id = p_email_provider_id
   order by enviado_em desc nulls last limit 1;
  if v_signer.id is null then
    raise exception 'TENTATIVA_INVALIDA: nenhum signatário encontrado para email_provider_id %.', p_email_provider_id;
  end if;

  if p_evento = 'EMAIL_ENTREGUE' and v_signer.status = 'ENVIADO' then
    update public.signature_signers set status = 'ENTREGUE', entregue_em = coalesce(entregue_em, now()) where id = v_signer.id;
    perform app.registrar_auditoria_semantica('signature_signers', v_signer.id, 'SIGNATURE_DELIVERED', p_detalhe, null, null);
  elsif p_evento in ('EMAIL_REJEITADO', 'EMAIL_FALHOU') and v_signer.status not in ('ASSINADO', 'RECUSADO') then
    update public.signature_signers set erro_mensagem = coalesce(p_detalhe, erro_mensagem) where id = v_signer.id;
    perform app.registrar_auditoria_semantica('signature_signers', v_signer.id, 'SIGNATURE_EMAIL_BOUNCED', p_detalhe, null, null);
  end if;
  -- Qualquer outro evento (ou signatário já ASSINADO/RECUSADO): idempotente, sem
  -- alteração — nunca regride um estado mais avançado (seção 11 do pedido).

  return jsonb_build_object('signer_id', v_signer.id, 'evento', p_evento);
end;
$$;
comment on function app.registrar_status_email_assinatura_por_provider_id(text, text, text) is 'Fase 3.11.4 (seção 9/12): reaproveita o webhook do Resend da Fase 3.11.3 — chamado como fallback quando o email_provider_id não corresponde a nenhuma tentativa de OTP de proposta (ver api/routes/emailWebhooks.js).';

drop function if exists public.pricing_signature_email_status_por_provider_id(text, text, text);
create or replace function public.pricing_signature_email_status_por_provider_id(p_email_provider_id text, p_evento text, p_detalhe text default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.registrar_status_email_assinatura_por_provider_id(p_email_provider_id, p_evento, p_detalhe); $$;
grant execute on function public.pricing_signature_email_status_por_provider_id(text, text, text) to anon;

-- ============================================================================
-- 10) app.contrato_assinatura_status — CREATE OR REPLACE (mesma assinatura): acrescenta
--     provider_nome/provider_tipo e ultimo_evento (seção 16 do pedido: "Envelope /
--     Provedor / Status / Criado em / Enviado em / Último evento" na tela). Nunca troca o
--     que já existia, só adiciona.
-- ============================================================================

create or replace function app.contrato_assinatura_status(p_contrato_id uuid)
returns jsonb
language sql
security invoker
stable
as $$
  select jsonb_build_object(
    'envelope_id', e.id,
    'envelope_status', e.status,
    'provider_envelope_id', e.provider_envelope_id,
    'provider_nome', sp.nome,
    'provider_tipo', sp.tipo,
    'criado_em', e.criado_em,
    'enviado_em', e.enviado_em,
    'erro_mensagem', e.erro_mensagem,
    'documento_assinado_disponivel', exists(
      select 1 from public.documentos_assinados da where da.envelope_id = e.id and da.validado = true
    ),
    'ultimo_evento', (
      select jsonb_build_object('acao', a.acao, 'em', a.criado_em)
      from public.auditoria a
      where a.entidade in ('signature_envelopes', 'signature_signers')
        and (a.entidade_id = e.id or a.entidade_id in (select s2.id from public.signature_signers s2 where s2.envelope_id = e.id))
      order by a.criado_em desc
      limit 1
    ),
    'signatarios', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'nome', s.nome, 'email', s.email, 'papel', s.papel, 'ordem', s.ordem, 'obrigatorio', s.obrigatorio,
        'status', s.status, 'enviado_em', s.enviado_em, 'entregue_em', s.entregue_em, 'aberto_em', s.aberto_em,
        'assinado_em', s.assinado_em, 'erro_mensagem', s.erro_mensagem, 'reenvios_count', s.reenvios_count,
        'provider_signer_id', s.provider_signer_id
      ) order by s.ordem), '[]'::jsonb)
      from public.signature_signers s where s.envelope_id = e.id
    )
  )
  from public.signature_envelopes e
  left join public.signature_providers sp on sp.id = e.provider_id
  where e.contrato_id = p_contrato_id and e.tipo_documento = 'CONTRATO'
  order by e.criado_em desc
  limit 1;
$$;
comment on function app.contrato_assinatura_status(uuid) is 'Fase 3.11.2 (seção 4/5), estendida na Fase 3.11.4 (seção 16 do pedido): acrescenta provider_nome/provider_tipo e ultimo_evento (derivado de public.auditoria — nunca uma coluna redundante) para a tela distinguir claramente ENVIADO de ENTREGUE/ABERTO/ASSINADO e mostrar qual provedor está em uso.';

-- ============================================================================
-- 11) app.reenviar_assinatura_signatario — CREATE OR REPLACE (mesma assinatura, seção 10):
--     GAP REAL encontrado testando esta própria fase — a lista de status do ENVELOPE que
--     admitem reenvio (da Fase 3.11.2) não incluía o novo 'ERRO_ENVIO' (que só passou a
--     existir nesta fase). Sem esta correção, um envelope que caiu em ERRO_ENVIO (porque o
--     Resend falhou) ficaria PRESO — "Reenviar" seria bloqueado com STATUS_INVALIDO
--     exatamente no caso em que reenviar é mais necessário. Único ponto que muda: o valor
--     novo acrescentado à lista — nenhuma outra regra desta função (bloqueio de
--     signatário já ASSINADO, reset de entregue_em/aberto_em, contagem de reenvios) muda.
-- ============================================================================

create or replace function app.reenviar_assinatura_signatario(p_signer_id uuid, p_motivo text default null)
returns public.signature_signers
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
  v_envelope public.signature_envelopes;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem reenviar assinatura.';
  end if;

  select * into v_signer from public.signature_signers where id = p_signer_id;
  if v_signer.id is null then raise exception 'NAO_ENCONTRADO: signatário % não encontrado.', p_signer_id; end if;

  if v_signer.status = 'ASSINADO' then
    raise exception 'STATUS_INVALIDO: signatário % já assinou — reenviar não é permitido (evita duplicidade de assinatura).', v_signer.nome;
  end if;

  select * into v_envelope from public.signature_envelopes where id = v_signer.envelope_id;
  if v_envelope.status not in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO', 'ERRO', 'ERRO_ENVIO') then
    raise exception 'STATUS_INVALIDO: envelope em status % não admite reenvio de signatário.', v_envelope.status;
  end if;

  update public.signature_signers
     set status = 'ENVIADO',
         enviado_em = now(),
         entregue_em = null,
         aberto_em = null,
         erro_mensagem = null,
         reenvios_count = reenvios_count + 1
   where id = p_signer_id
   returning * into v_signer;

  perform app.registrar_auditoria_semantica('signature_envelopes', v_envelope.id, 'SIGNATURE_SIGNER_RESEND',
    coalesce(p_motivo, 'Reenvio de assinatura solicitado.'), null,
    jsonb_build_object('signer_id', v_signer.id, 'signer_email', v_signer.email, 'reenvios_count', v_signer.reenvios_count));

  return v_signer;
end;
$$;
comment on function app.reenviar_assinatura_signatario(uuid, text) is 'Fase 3.11.2 (seção 6), corrigida na Fase 3.11.4 (seção 10): lista de status do envelope que admitem reenvio agora inclui ERRO_ENVIO — sem isso, um envelope que falhou o envio via Resend nunca poderia ser reenviado. O UPDATE otimista para ENVIADO aqui é sempre sobrescrito pelo resultado real de app.registrar_envio_signatario logo em seguida, para o provider OPTIMON_INTERNO_RESEND (ver api/routes/signatures.js).';

-- Fim da parte SQL da Fase 3.11.4 — restante (ResendSignatureLinkProvider real, rotas
-- /send e /resend nunca mais confiando cegamente no mock, área pública /api/signatures/
-- external/:token, reaproveitamento do webhook do Resend, frontend com Provedor/Criado
-- em/Último evento/⚠️ FALHA NO ENVIO, testes) em api/lib/signatureProvider.js,
-- api/lib/signatureLinkEmailTemplate.js, api/routes/signatures.js, api/routes/
-- signaturesExternal.js, api/routes/emailWebhooks.js, api/server.js,
-- web/src/pages/SignAssinatura.jsx, web/src/pages/ContractDetail.jsx, web/src/App.jsx,
-- tests/run_tests_fase311.sh.
