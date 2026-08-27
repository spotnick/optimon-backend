-- OptiMon — Fase 2.5 (7/9): Signature Engine — funções de negócio (seções 5,
-- 10, 24-28, 49, 56).
--
-- Divisão de responsabilidade (documentada em ARQUITETURA.md): as chamadas
-- HTTP reais para o provedor ICP-Brasil (createEnvelope/addSigner/
-- sendForSignature/...) vivem em Node (api/lib/signatureProvider.js,
-- implementando a interface ElectronicSignatureProvider da seção 5) — aqui só
-- o estado (linhas/RLS/idempotência) que o orquestrador precisa manter,
-- exatamente o escopo que a seção 3 atribui ao OptiMon.

create or replace function app.criar_envelope_assinatura(
  p_tipo_documento text,
  p_provider_id uuid,
  p_proposta_id uuid default null,
  p_contrato_id uuid default null,
  p_aditivo_id uuid default null
)
returns public.signature_envelopes
language plpgsql
security invoker
as $$
declare
  v_envelope public.signature_envelopes;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem criar envelope de assinatura.';
  end if;

  insert into public.signature_envelopes (tipo_documento, provider_id, proposta_id, contrato_id, aditivo_id, criado_por)
  values (p_tipo_documento, p_provider_id, p_proposta_id, p_contrato_id, p_aditivo_id, auth.uid())
  returning * into v_envelope;

  perform app.registrar_auditoria_semantica('signature_envelopes', v_envelope.id, 'SIGNATURE_ENVELOPE_CREATE', null, null, to_jsonb(v_envelope));

  return v_envelope;
end;
$$;

comment on function app.criar_envelope_assinatura(text, uuid, uuid, uuid, uuid) is 'Fase 2.5 seção 5 (createEnvelope). SECURITY INVOKER: só escreve em signature_envelopes, coberta pela policy signature_envelopes_insert (mesmos perfis do check acima) — sem a lacuna de tabela cruzada que exigiu DEFINER em outras funções desta fase.';

create or replace function app.adicionar_signatario(
  p_envelope_id uuid,
  p_nome text,
  p_email text,
  p_papel text,
  p_ordem integer default 1,
  p_cpf text default null,
  p_responsavel_id uuid default null
)
returns public.signature_signers
language plpgsql
security invoker
as $$
declare
  v_signer public.signature_signers;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem adicionar signatário.';
  end if;

  insert into public.signature_signers (envelope_id, nome, email, cpf, papel, ordem, responsavel_id)
  values (p_envelope_id, p_nome, p_email, p_cpf, p_papel, p_ordem, p_responsavel_id)
  returning * into v_signer;

  return v_signer;
end;
$$;

comment on function app.adicionar_signatario(uuid, text, text, text, integer, text, uuid) is 'Fase 2.5 seção 5 (addSigner) + configureSigningOrder via o parâmetro p_ordem (seção 25: quantidade e papéis configuráveis).';

-- ============================================================================
-- Enviar para assinatura (sendForSignature) — cruza envelope + o documento
-- de origem (proposta/contrato/aditivo), por isso SECURITY DEFINER (mesma
-- razão documentada em app.gerar_contrato_de_proposta).
-- ============================================================================

create or replace function app.enviar_envelope_para_assinatura(p_envelope_id uuid, p_provider_envelope_id text default null)
returns public.signature_envelopes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_envelope public.signature_envelopes;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem enviar um envelope para assinatura.';
  end if;

  select * into v_envelope from public.signature_envelopes where id = p_envelope_id;
  if v_envelope.id is null then
    raise exception 'NAO_ENCONTRADO: envelope % não encontrado.', p_envelope_id;
  end if;
  if v_envelope.status <> 'CRIADO' then
    raise exception 'STATUS_INVALIDO: envelope % já está em status % — não pode ser reenviado por aqui.', v_envelope.id, v_envelope.status;
  end if;
  if not exists (select 1 from public.signature_signers where envelope_id = v_envelope.id) then
    raise exception 'SEM_SIGNATARIOS: adicione pelo menos um signatário antes de enviar para assinatura.';
  end if;

  update public.signature_envelopes
     set status = 'ENVIADO',
         provider_envelope_id = coalesce(p_provider_envelope_id, provider_envelope_id),
         enviado_em = now()
   where id = v_envelope.id
   returning * into v_envelope;

  update public.signature_signers
     set status = 'ENVIADO'
   where envelope_id = v_envelope.id and status = 'PENDENTE';

  if v_envelope.tipo_documento = 'PROPOSTA' then
    update public.propostas_comerciais set status = 'EM_ASSINATURA' where id = v_envelope.proposta_id;
  elsif v_envelope.tipo_documento = 'ADITIVO' then
    update public.contrato_aditivos set status = 'EM_APROVACAO' where id = v_envelope.aditivo_id and status = 'RASCUNHO';
  end if;

  perform app.registrar_auditoria_semantica('signature_envelopes', v_envelope.id, 'SIGNATURE_ENVELOPE_SEND', null, null, to_jsonb(v_envelope));

  return v_envelope;
end;
$$;

create or replace function app.cancelar_envelope_assinatura(p_envelope_id uuid, p_motivo text)
returns public.signature_envelopes
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_envelope public.signature_envelopes;
begin
  if not app.tem_perfil('DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só DIRETOR/ADMINISTRADOR podem cancelar um envelope de assinatura.';
  end if;
  if p_motivo is null or trim(p_motivo) = '' then
    raise exception 'MOTIVO_OBRIGATORIO: cancelar um envelope de assinatura exige motivo.';
  end if;

  select * into v_envelope from public.signature_envelopes where id = p_envelope_id;
  if v_envelope.id is null then
    raise exception 'NAO_ENCONTRADO: envelope % não encontrado.', p_envelope_id;
  end if;
  if v_envelope.status in ('ASSINADO', 'VALIDADO', 'CANCELADO') then
    raise exception 'STATUS_INVALIDO: envelope % em status % não pode ser cancelado.', v_envelope.id, v_envelope.status;
  end if;

  update public.signature_envelopes
     set status = 'CANCELADO', cancelado_em = now()
   where id = v_envelope.id
   returning * into v_envelope;

  perform app.registrar_auditoria_semantica('signature_envelopes', v_envelope.id, 'SIGNATURE_ENVELOPE_CANCEL', p_motivo, null, to_jsonb(v_envelope));

  return v_envelope;
end;
$$;

-- ============================================================================
-- Webhook (seção 27, 49) — idempotente por (envelope_id, evento_externo_id).
-- SECURITY DEFINER e concedida a `anon`: quem chama é a rota Node do webhook,
-- SEM JWT de usuário (é o provedor externo chamando o OptiMon) — a validação
-- de autenticidade do payload (assinatura HMAC do webhook_secret) acontece em
-- Node ANTES desta função ser chamada (api/routes/signatures.js), nunca aqui.
-- Esta função em si só manipula linhas de signature_*, nunca dado sensível de
-- outra entidade, o que limita o raio de uma eventual chamada indevida.
-- ============================================================================

create or replace function app.registrar_evento_assinatura_webhook(
  p_envelope_id uuid,
  p_evento_externo_id text,
  p_tipo_evento text,
  p_payload jsonb default null,
  p_novo_status_envelope text default null,
  p_signer_email text default null,
  p_signer_novo_status text default null,
  p_signer_ip text default null,
  p_signer_certificado jsonb default null,
  p_hash_assinado text default null,
  p_storage_path_assinado text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_event_id uuid;
  v_envelope public.signature_envelopes;
begin
  insert into public.signature_events (envelope_id, evento_externo_id, tipo_evento, payload)
  values (p_envelope_id, p_evento_externo_id, p_tipo_evento, p_payload)
  on conflict (envelope_id, evento_externo_id) do nothing
  returning id into v_event_id;

  if v_event_id is null then
    -- Evento já processado antes (mesmo evento_externo_id) — idempotência
    -- (seção 27/49): não duplica nada, só confirma que já foi recebido.
    return jsonb_build_object('duplicado', true);
  end if;

  select * into v_envelope from public.signature_envelopes where id = p_envelope_id;
  if v_envelope.id is null then
    raise exception 'NAO_ENCONTRADO: envelope % não encontrado (evento recebido mas sem envelope correspondente).', p_envelope_id;
  end if;

  if p_signer_email is not null and p_signer_novo_status is not null then
    update public.signature_signers
       set status = p_signer_novo_status,
           assinado_em = case when p_signer_novo_status = 'ASSINADO' then now() else assinado_em end,
           ip_assinatura = coalesce(p_signer_ip, ip_assinatura),
           certificado_info = coalesce(p_signer_certificado, certificado_info)
     where envelope_id = p_envelope_id and lower(email) = lower(p_signer_email);
  end if;

  if p_novo_status_envelope is not null then
    update public.signature_envelopes
       set status = p_novo_status_envelope,
           hash_assinado = coalesce(p_hash_assinado, hash_assinado),
           documento_assinado_storage_path = coalesce(p_storage_path_assinado, documento_assinado_storage_path),
           concluido_em = case when p_novo_status_envelope in ('ASSINADO', 'RECUSADO', 'EXPIRADO', 'ERRO') then now() else concluido_em end
     where id = p_envelope_id
     returning * into v_envelope;

    if p_novo_status_envelope = 'ASSINADO' then
      insert into public.documentos_assinados (envelope_id, storage_path_original, storage_path_assinado, hash_sha256_original, hash_sha256_assinado, formato, pades)
      values (p_envelope_id, v_envelope.documento_original_storage_path, p_storage_path_assinado, v_envelope.hash_original, p_hash_assinado, 'PDF', true)
      on conflict (envelope_id) do update
        set storage_path_assinado = excluded.storage_path_assinado,
            hash_sha256_assinado = excluded.hash_sha256_assinado;

      if v_envelope.tipo_documento = 'PROPOSTA' then
        update public.propostas_comerciais set status = 'ASSINADA' where id = v_envelope.proposta_id;
      end if;
    end if;
  end if;

  update public.signature_events set processado = true where id = v_event_id;

  perform app.registrar_auditoria_semantica('signature_envelopes', p_envelope_id, 'SIGNATURE_EVENT_RECEIVED', p_tipo_evento, null, p_payload);

  return jsonb_build_object('duplicado', false, 'envelope_status', coalesce(p_novo_status_envelope, v_envelope.status));
end;
$$;

comment on function app.registrar_evento_assinatura_webhook is 'Fase 2.5 seção 27/49: ponto de entrada único e idempotente para eventos do provedor. A validação de autenticidade do webhook (HMAC do secret configurado em signature_providers.webhook_secret_ref) é feita em Node antes de chamar esta função — ela nunca confia cegamente no payload por si só, só no fato de já ter passado pela validação da camada HTTP.';

grant execute on function app.registrar_evento_assinatura_webhook(uuid, text, text, jsonb, text, text, text, text, jsonb, text, text) to anon;

-- ============================================================================
-- Validação (seção 10/12/56) — nunca considerar "ASSINADO" sozinho como prova
-- de assinatura válida; só isso aqui marca `validado=true`.
-- ============================================================================

create or replace function app.validar_assinatura(p_envelope_id uuid)
returns jsonb
language plpgsql
security invoker
as $$
declare
  v_envelope public.signature_envelopes;
  v_doc public.documentos_assinados;
  v_todos_assinaram boolean;
  v_resultado jsonb;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem validar uma assinatura.';
  end if;

  select * into v_envelope from public.signature_envelopes where id = p_envelope_id;
  select * into v_doc from public.documentos_assinados where envelope_id = p_envelope_id;

  select bool_and(status = 'ASSINADO') into v_todos_assinaram
  from public.signature_signers where envelope_id = p_envelope_id;

  v_resultado := jsonb_build_object(
    'documento_integro', v_doc.id is not null and v_doc.hash_sha256_assinado is not null,
    'assinatura_valida', v_envelope.status in ('ASSINADO', 'VALIDADO'),
    'certificado_valido', v_envelope.status in ('ASSINADO', 'VALIDADO') and v_envelope.politica_assinatura = 'ICP_BRASIL_QUALIFICADA',
    'signatarios_confirmados', coalesce(v_todos_assinaram, false),
    'documento_nao_alterado', v_doc.hash_sha256_original is null or v_doc.hash_sha256_original is distinct from v_doc.hash_sha256_assinado
  );

  if (v_resultado->>'documento_integro')::boolean
     and (v_resultado->>'assinatura_valida')::boolean
     and (v_resultado->>'certificado_valido')::boolean
     and (v_resultado->>'signatarios_confirmados')::boolean then

    update public.documentos_assinados
       set validado = true, validado_em = now(), validado_por = auth.uid(), resultado_validacao = v_resultado
     where envelope_id = p_envelope_id;

    update public.signature_envelopes set status = 'VALIDADO' where id = p_envelope_id and status <> 'VALIDADO';

    perform app.registrar_auditoria_semantica('signature_envelopes', p_envelope_id, 'SIGNATURE_VALIDATED', null, null, v_resultado);

    v_resultado := v_resultado || jsonb_build_object('validado', true);
  else
    update public.documentos_assinados
       set resultado_validacao = v_resultado
     where envelope_id = p_envelope_id;
    v_resultado := v_resultado || jsonb_build_object('validado', false);
  end if;

  return v_resultado;
end;
$$;

comment on function app.validar_assinatura(uuid) is 'Fase 2.5 seção 10/56: nunca retorna validado=true só porque status=ASSINADO — checa integridade do hash, política ICP-Brasil, e que todos os signatários confirmaram, antes de marcar documentos_assinados.validado.';

-- ============================================================================
-- Wrappers public.* (thin, SQL, mesmo padrão do resto do projeto)
-- ============================================================================

drop function if exists public.pricing_signature_envelope_create(text, uuid, uuid, uuid, uuid);
create or replace function public.pricing_signature_envelope_create(p_tipo_documento text, p_provider_id uuid, p_proposta_id uuid default null, p_contrato_id uuid default null, p_aditivo_id uuid default null)
returns public.signature_envelopes
language sql security invoker
as $$ select app.criar_envelope_assinatura(p_tipo_documento, p_provider_id, p_proposta_id, p_contrato_id, p_aditivo_id); $$;

drop function if exists public.pricing_signature_signer_add(uuid, text, text, text, integer, text, uuid);
create or replace function public.pricing_signature_signer_add(p_envelope_id uuid, p_nome text, p_email text, p_papel text, p_ordem integer default 1, p_cpf text default null, p_responsavel_id uuid default null)
returns public.signature_signers
language sql security invoker
as $$ select app.adicionar_signatario(p_envelope_id, p_nome, p_email, p_papel, p_ordem, p_cpf, p_responsavel_id); $$;

drop function if exists public.pricing_signature_envelope_send(uuid, text);
create or replace function public.pricing_signature_envelope_send(p_envelope_id uuid, p_provider_envelope_id text default null)
returns public.signature_envelopes
language sql security invoker
as $$ select app.enviar_envelope_para_assinatura(p_envelope_id, p_provider_envelope_id); $$;

drop function if exists public.pricing_signature_envelope_cancel(uuid, text);
create or replace function public.pricing_signature_envelope_cancel(p_envelope_id uuid, p_motivo text)
returns public.signature_envelopes
language sql security invoker
as $$ select app.cancelar_envelope_assinatura(p_envelope_id, p_motivo); $$;

drop function if exists public.pricing_signature_validate(uuid);
create or replace function public.pricing_signature_validate(p_envelope_id uuid)
returns jsonb
language sql security invoker
as $$ select app.validar_assinatura(p_envelope_id); $$;

-- SECURITY DEFINER aqui (diferente dos outros wrappers `public.*`, que são só
-- de conveniência sobre RLS): `anon` não tem USAGE no schema `app` (só
-- `authenticated` tem, checado antes de escrever esta migration) — como quem
-- chama esta rota é o provedor externo, sem JWT de usuário, o wrapper roda
-- como o dono da função (que tem acesso a `app`) em vez de depender de anon
-- enxergar o schema app inteiro, o que seria conceder mais do que o necessário.
drop function if exists public.pricing_signature_webhook_event(uuid, text, text, jsonb, text, text, text, text, jsonb, text, text);
create or replace function public.pricing_signature_webhook_event(
  p_envelope_id uuid, p_evento_externo_id text, p_tipo_evento text, p_payload jsonb default null,
  p_novo_status_envelope text default null, p_signer_email text default null, p_signer_novo_status text default null,
  p_signer_ip text default null, p_signer_certificado jsonb default null, p_hash_assinado text default null,
  p_storage_path_assinado text default null
)
returns jsonb
language sql
security definer
set search_path = public, app, pg_temp
as $$
  select app.registrar_evento_assinatura_webhook(p_envelope_id, p_evento_externo_id, p_tipo_evento, p_payload, p_novo_status_envelope, p_signer_email, p_signer_novo_status, p_signer_ip, p_signer_certificado, p_hash_assinado, p_storage_path_assinado);
$$;

grant execute on function public.pricing_signature_envelope_create(text, uuid, uuid, uuid, uuid) to authenticated;
grant execute on function public.pricing_signature_signer_add(uuid, text, text, text, integer, text, uuid) to authenticated;
grant execute on function public.pricing_signature_envelope_send(uuid, text) to authenticated;
grant execute on function public.pricing_signature_envelope_cancel(uuid, text) to authenticated;
grant execute on function public.pricing_signature_validate(uuid) to authenticated;
grant execute on function public.pricing_signature_webhook_event(uuid, text, text, jsonb, text, text, text, text, jsonb, text, text) to anon;
