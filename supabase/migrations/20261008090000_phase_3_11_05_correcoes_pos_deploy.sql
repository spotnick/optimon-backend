-- ============================================================================
-- OptiMon — Fase 3.11.5: correções de 4 problemas reais encontrados pelo usuário
-- testando de ponta a ponta, EM PRODUÇÃO, o fluxo real de assinatura (Fase 3.11.4) —
-- e-mail recebido de verdade via Resend, contrato assinado de verdade. Relato literal:
--
--   1. "ao clicar em Revisar documento (PDF): Caminho do documento não encontrado" —
--      GET /api/signatures/external/:token/document devolvia 404 mesmo com o caminho
--      existindo de verdade no banco.
--   2. "O campo de CPF está sem validação" — o campo aceitava qualquer texto.
--   3. "Para assinatura do contrato deve ter token de validação para garantir quem
--      está assinado" — hoje só o link único (e-mail) evidencia quem assina; sem uma
--      segunda confirmação (o mesmo padrão OTP já usado no ACEITE da proposta,
--      Fase 3.11.2), qualquer pessoa com acesso momentâneo à caixa de e-mail (ou ao
--      link, se encaminhado) assina sem provar de novo que é o dono do e-mail.
--   4. "Após assinado o contrato deve ter como ser visualizado em PDF com todas as
--      informações da assinatura" — hoje documentos_assinados.storage_path_assinado é
--      gravado como CÓPIA do original (Fase 3.11.4, seção 8b) — nunca um PDF real com
--      certificado de assinatura (quem assinou, CPF confirmado, IP, data/hora, método).
--
-- CAUSA RAIZ do item 1 (investigada, não presumida — leitura de código confirmou):
-- api/routes/signaturesExternal.js fazia `anonClient().from('signature_envelopes')
-- .select(...)` direto — mas a policy signature_envelopes_select (migration
-- 20260913090300) é `to authenticated` só, sem nenhuma policy para `anon`. A leitura
-- sempre voltava 0 linhas (RLS bloqueando silenciosamente, sem erro), daí o "caminho
-- não encontrado" mesmo com o caminho presente no banco. Gap de teste real: a suíte
-- automatizada nunca chamava GET .../document (só .../assinar e .../recusar) —
-- corrigido nos testes abaixo também, para nunca mais deixar essa rota sem cobertura.
--
-- DECISÃO DE ARQUITETURA para os itens 3/4 (mirror deliberado, nunca uma 2ª solução):
--   - Item 3 usa EXATAMENTE o mesmo mecanismo de 2 passos (iniciar → confirmar, com
--     OTP de 6 dígitos por e-mail, hash com pepper, 5 tentativas, expiração de 10 min)
--     já construído e testado na Fase 3.11.2 para o aceite de proposta pelo parceiro —
--     mesma tabela de staging (signature_assinatura_tentativas, mirror de
--     propostas_aceite_tentativas), mesmas funções SECURITY DEFINER, mesmo
--     otpNotifier/template (Node), mesmo componente de UI (mirror de
--     PartnerExternalProposal.jsx).
--   - Item 4 gera, em Node (pdfkit, mesmo motor da minuta — api/lib/pdfContrato.js),
--     um PDF final REAL no momento em que o envelope vira ASSINADO: o mesmo conteúdo
--     do contrato + uma página de CERTIFICADO DE ASSINATURA ELETRÔNICA (nome/CPF
--     confirmados, e-mail, IP, data/hora, método, hash do documento original) — nunca
--     uma cópia do arquivo original. Este arquivo SQL só prepara o acesso (funções
--     SECURITY DEFINER escopadas ao token) — a geração do PDF em si é Node (pdfkit não
--     roda dentro do Postgres).
-- ============================================================================

-- ============================================================================
-- 1) app.cpf_valido — validação REAL de CPF (dígitos verificadores, mod 11), nunca só
--    formato/tamanho. Rejeita sequências óbvias (000.000.000-00, 111.111.111-11, ...),
--    que passam em qualquer checagem de "11 dígitos" mas nunca são CPFs válidos.
-- ============================================================================

create or replace function app.cpf_valido(p_cpf text)
returns boolean
language plpgsql
immutable
as $$
declare
  v text;
  v_soma int;
  v_i int;
  v_resto int;
  v_d1 int;
  v_d2 int;
begin
  if p_cpf is null then return false; end if;
  v := regexp_replace(p_cpf, '\D', '', 'g');
  if length(v) <> 11 then return false; end if;
  if v ~ '^(\d)\1{10}$' then return false; end if;

  v_soma := 0;
  for v_i in 1..9 loop
    v_soma := v_soma + (substr(v, v_i, 1))::int * (11 - v_i);
  end loop;
  v_resto := (v_soma * 10) % 11;
  if v_resto = 10 then v_resto := 0; end if;
  v_d1 := v_resto;
  if v_d1 <> (substr(v, 10, 1))::int then return false; end if;

  v_soma := 0;
  for v_i in 1..10 loop
    v_soma := v_soma + (substr(v, v_i, 1))::int * (12 - v_i);
  end loop;
  v_resto := (v_soma * 10) % 11;
  if v_resto = 10 then v_resto := 0; end if;
  v_d2 := v_resto;
  if v_d2 <> (substr(v, 11, 1))::int then return false; end if;

  return true;
end;
$$;
comment on function app.cpf_valido(text) is 'Fase 3.11.5 (item 2 do relato do usuário: "campo de CPF está sem validação"): algoritmo real dos dígitos verificadores (mod 11), não só contagem de dígitos. Usado no passo de assinatura (app.assinatura_externa_assinar_iniciar) — nunca só no frontend, para nunca poder ser contornado chamando a API direto.';

-- ============================================================================
-- 2) auditoria_acao_check + registrar_auditoria_semantica — acrescenta as ações novas
--    desta fase (nunca remove nenhuma das existentes — lista completa herdada da Fase
--    3.11.4, migration 20261006090000).
-- ============================================================================

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
  -- Fase 3.11.5:
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
  'PROPOSAL_ACCEPT_EMAIL_COMPLAINED','PROPOSAL_ACCEPT_EMAIL_FAILED'
]));

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

-- ============================================================================
-- 3) Corrige o BUG REAL do item 1 (404 "Caminho do documento não encontrado"): novas
--    funções SECURITY DEFINER, escopadas ao token (mesmo padrão de
--    app.assinatura_externa_por_token), para o Node nunca mais precisar ler
--    signature_envelopes direto com o cliente anon (bloqueado por RLS).
-- ============================================================================

create or replace function app.assinatura_externa_documento_original_path(p_token text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
  v_envelope public.signature_envelopes;
begin
  select * into v_signer from public.signature_signers where token_acesso = p_token;
  if v_signer.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  if v_signer.token_expira_em is not null and v_signer.token_expira_em < now() then
    raise exception 'TOKEN_EXPIRADO: este link expirou — solicite um novo envio.';
  end if;
  select * into v_envelope from public.signature_envelopes where id = v_signer.envelope_id;
  if v_envelope.status = 'CANCELADO' then raise exception 'ENVELOPE_CANCELADO: este envelope foi cancelado.'; end if;
  return v_envelope.documento_original_storage_path;
end;
$$;
comment on function app.assinatura_externa_documento_original_path(text) is 'Fase 3.11.5 (correção do bug real de produção — 404 "Caminho do documento não encontrado"): antes, signaturesExternal.js lia signature_envelopes direto com o cliente anon, bloqueado pela RLS to authenticated (signature_envelopes_select) — a leitura sempre voltava vazia mesmo com o caminho existindo. Mesmo padrão SECURITY DEFINER + token opaco já usado em todo o resto deste arquivo.';

drop function if exists public.pricing_signature_external_documento_path(text);
create or replace function public.pricing_signature_external_documento_path(p_token text)
returns text language sql security definer set search_path = public, pg_temp
as $$ select app.assinatura_externa_documento_original_path(p_token); $$;
grant execute on function public.pricing_signature_external_documento_path(text) to anon;

-- ============================================================================
-- 4) Suporte ao item 4 (PDF final assinado com certificado): getters/registrador do
--    documento assinado + dados para a geração do PDF (Node/pdfkit) — sempre escopados
--    ao token, nunca ao usuário chamar com um contrato_id arbitrário.
-- ============================================================================

create or replace function app.assinatura_externa_documento_assinado_path(p_token text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
  v_envelope public.signature_envelopes;
  v_path text;
begin
  select * into v_signer from public.signature_signers where token_acesso = p_token;
  if v_signer.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  select * into v_envelope from public.signature_envelopes where id = v_signer.envelope_id;
  if v_envelope.status not in ('ASSINADO', 'VALIDADO') then
    raise exception 'STATUS_INVALIDO: o PDF final assinado ainda não está disponível — o envelope está em status %.', v_envelope.status;
  end if;
  select storage_path_assinado into v_path from public.documentos_assinados where envelope_id = v_envelope.id;
  return v_path;
end;
$$;

drop function if exists public.pricing_signature_external_documento_assinado_path(text);
create or replace function public.pricing_signature_external_documento_assinado_path(p_token text)
returns text language sql security definer set search_path = public, pg_temp
as $$ select app.assinatura_externa_documento_assinado_path(p_token); $$;
grant execute on function public.pricing_signature_external_documento_assinado_path(text) to anon;

create or replace function app.assinatura_externa_documento_assinado_registrar(p_token text, p_storage_path text, p_hash text default null, p_ip text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
  v_envelope public.signature_envelopes;
begin
  if p_storage_path is null or trim(p_storage_path) = '' then
    raise exception 'DADOS_OBRIGATORIOS: caminho do documento assinado é obrigatório.';
  end if;
  select * into v_signer from public.signature_signers where token_acesso = p_token;
  if v_signer.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  select * into v_envelope from public.signature_envelopes where id = v_signer.envelope_id;
  if v_envelope.status not in ('ASSINADO', 'VALIDADO') then
    raise exception 'STATUS_INVALIDO: envelope em status % — só é possível registrar o PDF final assinado depois de concluído.', v_envelope.status;
  end if;

  update public.documentos_assinados
     set storage_path_assinado = p_storage_path,
         hash_sha256_assinado = coalesce(p_hash, hash_sha256_assinado)
   where envelope_id = v_envelope.id;

  perform app.registrar_auditoria_semantica('signature_envelopes', v_envelope.id, 'SIGNATURE_DOCUMENT_ASSINADO_GERADO',
    'PDF final assinado (com certificado de assinatura eletrônica de todos os signatários) gerado e registrado.', null,
    jsonb_build_object('storage_path', p_storage_path), 'signatario_externo', p_ip);

  return jsonb_build_object('ok', true, 'envelope_id', v_envelope.id);
end;
$$;

drop function if exists public.pricing_signature_external_documento_assinado_registrar(text, text, text, text);
create or replace function public.pricing_signature_external_documento_assinado_registrar(p_token text, p_storage_path text, p_hash text default null, p_ip text default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.assinatura_externa_documento_assinado_registrar(p_token, p_storage_path, p_hash, p_ip); $$;
grant execute on function public.pricing_signature_external_documento_assinado_registrar(text, text, text, text) to anon;

-- Dados do contrato (mesmo formato de app.contrato_documento_dados, já usado para
-- gerar a minuta original — nunca uma 2ª fonte de verdade) para o Node regenerar o PDF
-- final, agora em modo ASSINADO. security invoker de app.contrato_documento_dados
-- herda o papel elevado desta função (definer) — mesmo mecanismo que já dá a toda
-- função SECURITY DEFINER deste arquivo acesso a tabelas com RLS to authenticated.
create or replace function app.assinatura_externa_documento_dados_contrato(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
  v_envelope public.signature_envelopes;
begin
  select * into v_signer from public.signature_signers where token_acesso = p_token;
  if v_signer.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  select * into v_envelope from public.signature_envelopes where id = v_signer.envelope_id;
  if v_envelope.tipo_documento <> 'CONTRATO' or v_envelope.contrato_id is null then
    raise exception 'STATUS_INVALIDO: este envelope não é de um contrato.';
  end if;
  if v_envelope.status not in ('ASSINADO', 'VALIDADO') then
    raise exception 'STATUS_INVALIDO: envelope em status % — dados do contrato assinado só ficam disponíveis depois de concluído.', v_envelope.status;
  end if;
  return app.contrato_documento_dados(v_envelope.contrato_id);
end;
$$;

drop function if exists public.pricing_signature_external_documento_dados_contrato(text);
create or replace function public.pricing_signature_external_documento_dados_contrato(p_token text)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.assinatura_externa_documento_dados_contrato(p_token); $$;
grant execute on function public.pricing_signature_external_documento_dados_contrato(text) to anon;

-- Dados de TODOS os signatários + envelope (para a página de certificado — nome/CPF
-- confirmados, e-mail, IP, data/hora, método) — genérico para CONTRATO ou PROPOSTA.
create or replace function app.assinatura_externa_certificado_dados(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
  v_envelope public.signature_envelopes;
  v_result jsonb;
begin
  select * into v_signer from public.signature_signers where token_acesso = p_token;
  if v_signer.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  select * into v_envelope from public.signature_envelopes where id = v_signer.envelope_id;
  if v_envelope.status not in ('ASSINADO', 'VALIDADO') then
    raise exception 'STATUS_INVALIDO: certificado só fica disponível depois do envelope concluído (status atual: %).', v_envelope.status;
  end if;

  select jsonb_build_object(
    'envelope_id', v_envelope.id, 'tipo_documento', v_envelope.tipo_documento,
    'contrato_id', v_envelope.contrato_id, 'proposta_id', v_envelope.proposta_id,
    'hash_original', v_envelope.hash_original, 'criado_em', v_envelope.criado_em, 'concluido_em', v_envelope.concluido_em,
    'provider_nome', (select nome from public.signature_providers where id = v_envelope.provider_id),
    'signatarios', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nome', s.nome, 'email', s.email, 'papel', s.papel, 'status', s.status,
        'assinado_em', s.assinado_em, 'ip_assinatura', s.ip_assinatura, 'certificado_info', s.certificado_info
      ) order by s.ordem)
      from public.signature_signers s where s.envelope_id = v_envelope.id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

drop function if exists public.pricing_signature_external_certificado_dados(text);
create or replace function public.pricing_signature_external_certificado_dados(p_token text)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.assinatura_externa_certificado_dados(p_token); $$;
grant execute on function public.pricing_signature_external_certificado_dados(text) to anon;

-- ============================================================================
-- 5) app.assinatura_externa_por_token — acrescenta documento_assinado_disponivel
--    (nunca inferido por igualdade de caminho — só true quando um PDF REAL já foi
--    gerado e registrado por app.assinatura_externa_documento_assinado_registrar).
-- ============================================================================

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

  if v_signer.status in ('ENVIADO', 'ENTREGUE') then
    update public.signature_signers
       set status = 'ABERTO', aberto_em = coalesce(aberto_em, now())
     where id = v_signer.id
     returning * into v_signer;
    perform app.registrar_auditoria_semantica('signature_signers', v_signer.id, 'SIGNATURE_OPENED',
      null, null, jsonb_build_object('envelope_id', v_envelope.id), 'signatario_externo');
  end if;

  select jsonb_build_object(
    'signer_id', v_signer.id, 'nome', v_signer.nome, 'email', v_signer.email, 'papel', v_signer.papel,
    'status', v_signer.status, 'ja_assinado', v_signer.status = 'ASSINADO', 'ja_recusado', v_signer.status = 'RECUSADO',
    'envelope_id', v_envelope.id, 'tipo_documento', v_envelope.tipo_documento, 'envelope_status', v_envelope.status,
    'documento_disponivel', v_envelope.documento_original_storage_path is not null,
    'documento_assinado_disponivel', exists(
      select 1 from public.documentos_assinados da where da.envelope_id = v_envelope.id and da.storage_path_assinado is not null
    ),
    'proposta_numero', (select numero from public.propostas_comerciais where id = v_envelope.proposta_id),
    'contrato_numero', (select numero from public.contratos where id = v_envelope.contrato_id)
  ) into v_resultado;

  return v_resultado;
end;
$$;
comment on function app.assinatura_externa_por_token(text) is 'Fase 3.11.4 (seção 13, itens 6-7), estendida na Fase 3.11.5 com documento_assinado_disponivel (item 4 do relato do usuário): visualização pelo link — só registra OPENED, nunca representa assinatura. documento_assinado_disponivel só vira true depois de um PDF REAL (com certificado) ser gerado e registrado — nunca por presunção.';

-- ============================================================================
-- 6) signature_assinatura_tentativas — staging da confirmação por OTP da ASSINATURA
--    (item 3 do relato: "deve ter token de validação para garantir quem está
--    assinando"). Mirror exato de propostas_aceite_tentativas (Fase 3.11.2): RLS
--    habilitado SEM NENHUMA policy — só acessível via as funções SECURITY DEFINER
--    abaixo.
-- ============================================================================

create table if not exists public.signature_assinatura_tentativas (
  id uuid primary key default gen_random_uuid(),
  signer_id uuid not null references public.signature_signers(id) on delete cascade,
  token_hash text not null,
  nome text not null,
  documento text not null,
  declaracao_aceita boolean not null default false,
  otp_hash text not null,
  otp_expira_em timestamptz not null,
  otp_tentativas integer not null default 0,
  status text not null default 'AGUARDANDO_OTP' check (status = any (array['AGUARDANDO_OTP', 'CONFIRMADO', 'EXPIRADO', 'CANCELADO'])),
  ip text,
  user_agent text,
  criado_em timestamptz not null default now(),
  confirmado_em timestamptz
);

comment on table public.signature_assinatura_tentativas is 'Fase 3.11.5 (item 3 do relato de produção): registro de CADA tentativa de assinatura externa, com o código de confirmação (hash, nunca texto puro) e o contador de tentativas erradas — mirror exato de propostas_aceite_tentativas (Fase 3.11.2). Uma assinatura só é gravada (signature_signers.status=ASSINADO) depois de app.assinatura_externa_assinar_confirmar validar o código.';

create index if not exists signature_assinatura_tentativas_signer_idx on public.signature_assinatura_tentativas(signer_id, status);

alter table public.signature_assinatura_tentativas enable row level security;
-- Sem nenhuma policy — mesmo motivo de propostas_aceite_tentativas: só as funções
-- SECURITY DEFINER abaixo (rodando como dono da função) leem/escrevem esta tabela.

drop trigger if exists trg_aud_signature_assinatura_tentativas on public.signature_assinatura_tentativas;
create trigger trg_aud_signature_assinatura_tentativas
  after insert or delete or update on public.signature_assinatura_tentativas
  for each row execute function public.fn_auditoria();

-- ============================================================================
-- 7) app.assinatura_externa_assinar_iniciar — passo 1 (mirror de
--    app.iniciar_aceite_proposta_parceiro): valida nome/CPF(real, dígito
--    verificador)/declaração, gera a tentativa com o OTP, mas NUNCA marca ASSINADO.
-- ============================================================================

create or replace function app.assinatura_externa_assinar_iniciar(
  p_token text,
  p_nome text,
  p_documento text,
  p_declaracao boolean,
  p_otp_hash text,
  p_otp_ttl_minutos integer default 10,
  p_ip text default null,
  p_user_agent text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
  v_envelope public.signature_envelopes;
  v_tentativa_id uuid;
  v_expira timestamptz;
begin
  if p_nome is null or trim(p_nome) = '' then
    raise exception 'DADOS_OBRIGATORIOS: nome completo é obrigatório para confirmar a assinatura.';
  end if;
  if p_documento is null or trim(p_documento) = '' then
    raise exception 'DADOS_OBRIGATORIOS: CPF é obrigatório para confirmar a assinatura.';
  end if;
  if not app.cpf_valido(p_documento) then
    raise exception 'CPF_INVALIDO: CPF informado não é válido — confira os números digitados.';
  end if;
  if p_declaracao is distinct from true then
    raise exception 'DECLARACAO_OBRIGATORIA: é necessário declarar que é você quem está assinando e que concorda com o conteúdo do documento.';
  end if;
  if p_otp_hash is null or length(p_otp_hash) < 32 then
    raise exception 'OTP_INVALIDO: falha interna ao gerar o código de confirmação — tente novamente.';
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

  select * into v_envelope from public.signature_envelopes where id = v_signer.envelope_id;
  if v_envelope.status = 'CANCELADO' then raise exception 'ENVELOPE_CANCELADO: este envelope foi cancelado.'; end if;

  -- Nunca deixa 2 tentativas AGUARDANDO_OTP simultâneas para o mesmo signatário —
  -- evita ambiguidade sobre qual código vale (mesma proteção de propostas_aceite_tentativas).
  update public.signature_assinatura_tentativas
     set status = 'CANCELADO'
   where signer_id = v_signer.id and status = 'AGUARDANDO_OTP';

  v_expira := now() + make_interval(mins => greatest(coalesce(p_otp_ttl_minutos, 10), 1));

  insert into public.signature_assinatura_tentativas
    (signer_id, token_hash, nome, documento, declaracao_aceita, otp_hash, otp_expira_em, ip, user_agent)
  values
    (v_signer.id, md5(p_token), trim(p_nome), trim(p_documento), true, p_otp_hash, v_expira, p_ip, p_user_agent)
  returning id into v_tentativa_id;

  perform app.registrar_auditoria_semantica('signature_signers', v_signer.id, 'SIGNATURE_ACCEPT_OTP_REQUESTED',
    'Código de confirmação solicitado para efetivar a assinatura eletrônica.', null,
    jsonb_build_object('tentativa_id', v_tentativa_id, 'nome', trim(p_nome), 'user_agent', p_user_agent),
    'signatario_externo', p_ip);

  return jsonb_build_object('tentativa_id', v_tentativa_id, 'expira_em', v_expira);
end;
$$;
comment on function app.assinatura_externa_assinar_iniciar(text, text, text, boolean, text, integer, text, text) is 'Fase 3.11.5 (item 3 do relato de produção): passo 1 da assinatura — valida tudo (incluindo CPF real, dígito verificador) e cria a tentativa com o código de confirmação, mas NUNCA marca signature_signers.status=ASSINADO. Só app.assinatura_externa_assinar_confirmar faz isso, e só depois do código validado. Mirror de app.iniciar_aceite_proposta_parceiro (Fase 3.11.2).';

drop function if exists app.confirmar_assinatura_via_link(text, text, text, boolean, text, text);
drop function if exists public.pricing_signature_external_assinar(text, text, text, boolean, text, text);

create or replace function public.pricing_signature_external_assinar_iniciar(
  p_token text, p_nome text, p_documento text, p_declaracao boolean,
  p_otp_hash text, p_otp_ttl_minutos integer default 10, p_ip text default null, p_user_agent text default null
)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.assinatura_externa_assinar_iniciar(p_token, p_nome, p_documento, p_declaracao, p_otp_hash, p_otp_ttl_minutos, p_ip, p_user_agent); $$;
grant execute on function public.pricing_signature_external_assinar_iniciar(text, text, text, boolean, text, integer, text, text) to anon;

-- ============================================================================
-- 8) app.assinatura_externa_assinar_confirmar — passo 2 (mirror de
--    app.confirmar_aceite_proposta_parceiro): valida o código (hash x hash, nunca
--    texto puro), bloqueia tentativa expirada/excedida/duplicada, e SÓ AQUI grava
--    ASSINADO — mesmo corpo que app.confirmar_assinatura_via_link (Fase 3.11.4) tinha,
--    agora alimentado pelos dados JÁ VALIDADOS da tentativa confirmada por OTP.
-- ============================================================================

create or replace function app.assinatura_externa_assinar_confirmar(
  p_token text,
  p_tentativa_id uuid,
  p_otp_hash_attempt text,
  p_ip text default null,
  p_user_agent text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signer public.signature_signers;
  v_envelope public.signature_envelopes;
  v_tent public.signature_assinatura_tentativas;
  v_max_tentativas constant integer := 5;
  v_ip_final inet;
  v_todos_obrigatorios_assinaram boolean;
begin
  select * into v_signer from public.signature_signers where token_acesso = p_token for update;
  if v_signer.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  if v_signer.token_expira_em is not null and v_signer.token_expira_em < now() then
    raise exception 'TOKEN_EXPIRADO: este link expirou — solicite um novo envio.';
  end if;
  if v_signer.status = 'ASSINADO' then
    raise exception 'ASSINATURA_DUPLICADA: este signatário já assinou — não é possível assinar duas vezes.';
  end if;

  select * into v_tent from public.signature_assinatura_tentativas
   where id = p_tentativa_id and signer_id = v_signer.id
   for update;
  if v_tent.id is null then
    raise exception 'TENTATIVA_INVALIDA: nenhuma solicitação de código encontrada para esta assinatura — solicite um novo código.';
  end if;
  if v_tent.status = 'CONFIRMADO' then
    raise exception 'ASSINATURA_DUPLICADA: este código já foi confirmado anteriormente — não é possível confirmar duas vezes.';
  end if;
  if v_tent.status = 'CANCELADO' then
    raise exception 'TENTATIVA_EXPIRADA: este código não é mais válido (substituído por um mais recente ou cancelado) — solicite um novo.';
  end if;
  if v_tent.otp_expira_em < now() then
    update public.signature_assinatura_tentativas set status = 'EXPIRADO' where id = v_tent.id;
    raise exception 'OTP_EXPIRADO: o código de confirmação expirou — solicite um novo.';
  end if;
  if v_tent.otp_tentativas >= v_max_tentativas then
    update public.signature_assinatura_tentativas set status = 'CANCELADO' where id = v_tent.id;
    raise exception 'OTP_BLOQUEADO: número máximo de tentativas incorretas excedido — solicite um novo código.';
  end if;

  select * into v_envelope from public.signature_envelopes where id = v_signer.envelope_id for update;
  if v_envelope.status = 'CANCELADO' then raise exception 'ENVELOPE_CANCELADO: este envelope foi cancelado.'; end if;

  if p_otp_hash_attempt is null or v_tent.otp_hash is distinct from p_otp_hash_attempt then
    update public.signature_assinatura_tentativas set otp_tentativas = otp_tentativas + 1 where id = v_tent.id;
    perform app.registrar_auditoria_semantica('signature_signers', v_signer.id, 'SIGNATURE_ACCEPT_OTP_FAILED',
      'Código de confirmação incorreto informado pelo signatário.', null,
      jsonb_build_object('tentativa_id', v_tent.id, 'tentativa_numero', v_tent.otp_tentativas + 1, 'max_tentativas', v_max_tentativas),
      'signatario_externo', p_ip);
    raise exception 'OTP_INCORRETO: código de confirmação incorreto (tentativa % de %).', v_tent.otp_tentativas + 1, v_max_tentativas;
  end if;

  begin
    v_ip_final := nullif(split_part(coalesce(p_ip, v_tent.ip, ''), ',', 1), '')::inet;
  exception when others then
    v_ip_final := null;
  end;

  update public.signature_assinatura_tentativas set status = 'CONFIRMADO', confirmado_em = now() where id = v_tent.id;

  update public.signature_signers
     set status = 'ASSINADO',
         assinado_em = now(),
         ip_assinatura = coalesce(p_ip, ip_assinatura),
         certificado_info = jsonb_build_object(
           'tipo', 'ASSINATURA_ELETRONICA_SIMPLES',
           'metodo', 'LINK_UNICO_EMAIL_RESEND_MAIS_OTP_EMAIL',
           'nome_confirmado', v_tent.nome,
           'documento_confirmado', v_tent.documento,
           'user_agent', coalesce(p_user_agent, v_tent.user_agent),
           'tentativa_id', v_tent.id,
           'observacao', 'Não é uma assinatura ICP-Brasil qualificada validada por Autoridade Certificadora — evidenciada por link único enviado ao e-mail cadastrado + código de confirmação (OTP) enviado ao mesmo e-mail, CPF confirmado, IP e timestamp (Fase 3.11.5).'
         )
   where id = v_signer.id
   returning * into v_signer;

  perform app.registrar_auditoria_semantica('signature_signers', v_signer.id, 'SIGNATURE_SIGNED',
    'Assinatura eletrônica simples confirmada pelo signatário via link individual + código de confirmação (OTP).', null,
    jsonb_build_object('nome_confirmado', v_tent.nome, 'user_agent', p_user_agent, 'tentativa_id', v_tent.id), 'signatario_externo', p_ip);

  -- Nunca marca o envelope ASSINADO só porque este signatário assinou — recalcula se
  -- TODOS os obrigatórios já assinaram de verdade (mesma correção da Fase 3.11.2).
  select not exists (
    select 1 from public.signature_signers
     where envelope_id = v_envelope.id and obrigatorio and status <> 'ASSINADO'
  ) into v_todos_obrigatorios_assinaram;

  if coalesce(v_todos_obrigatorios_assinaram, false) then
    update public.signature_envelopes
       set status = 'ASSINADO', concluido_em = now()
     where id = v_envelope.id
     returning * into v_envelope;

    -- Fase 3.11.5 (item 4 do relato): storage_path_assinado/hash_sha256_assinado ficam
    -- NULL aqui de propósito (antes, Fase 3.11.4, eram gravados como CÓPIA do
    -- original — nunca um PDF real). Só app.assinatura_externa_documento_assinado_
    -- registrar os preenche, e só depois que o Node gerar de verdade o PDF final com
    -- a página de certificado — nunca presumido pronto antes de existir de fato.
    insert into public.documentos_assinados (envelope_id, storage_path_original, storage_path_assinado, hash_sha256_original, hash_sha256_assinado, formato, pades)
    values (v_envelope.id, v_envelope.documento_original_storage_path, null, v_envelope.hash_original, null, 'PDF', false)
    on conflict (envelope_id) do update
      set storage_path_original = excluded.storage_path_original,
          hash_sha256_original = excluded.hash_sha256_original;

    if v_envelope.tipo_documento = 'PROPOSTA' then
      update public.propostas_comerciais set status = 'ASSINADA' where id = v_envelope.proposta_id;
    end if;

    perform app.registrar_auditoria_semantica('signature_envelopes', v_envelope.id, 'SIGNATURE_VALIDATED',
      'Todos os signatários obrigatórios assinaram — envelope concluído.', null, to_jsonb(v_envelope));
  else
    update public.signature_envelopes set status = 'PARCIALMENTE_ASSINADO' where id = v_envelope.id and status not in ('ASSINADO', 'VALIDADO');
  end if;

  return jsonb_build_object(
    'signer_id', v_signer.id, 'status', v_signer.status, 'assinado_em', v_signer.assinado_em,
    'envelope_id', v_envelope.id, 'envelope_status', v_envelope.status,
    'tipo_documento', v_envelope.tipo_documento, 'contrato_id', v_envelope.contrato_id, 'proposta_id', v_envelope.proposta_id
  );
end;
$$;
comment on function app.assinatura_externa_assinar_confirmar(text, uuid, text, text, text) is 'Fase 3.11.5 (item 3 do relato de produção): passo 2 — só aqui ASSINADO é gravado, e só com o código de confirmação (OTP) certo. Mirror de app.confirmar_aceite_proposta_parceiro (Fase 3.11.2). Substitui app.confirmar_assinatura_via_link (Fase 3.11.4), que assinava em 1 passo só — nunca 2 soluções paralelas.';

create or replace function public.pricing_signature_external_assinar_confirmar(
  p_token text, p_tentativa_id uuid, p_otp_hash_attempt text, p_ip text default null, p_user_agent text default null
)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.assinatura_externa_assinar_confirmar(p_token, p_tentativa_id, p_otp_hash_attempt, p_ip, p_user_agent); $$;
grant execute on function public.pricing_signature_external_assinar_confirmar(text, uuid, text, text, text) to anon;
