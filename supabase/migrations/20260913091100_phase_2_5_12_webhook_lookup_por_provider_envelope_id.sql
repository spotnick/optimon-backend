-- OptiMon — Fase 2.5 (12, correção aditiva): resolução de provider_envelope_id
-- → envelope_id no caminho do webhook (seções 27, 49).
--
-- BUG DE DESIGN encontrado ANTES de escrever a rota Node do webhook (nunca
-- chegou a rodar em produção): `app.registrar_evento_assinatura_webhook`
-- (migration 07) exige `p_envelope_id uuid` — o ID interno do OptiMon. Só que
-- um provedor de assinatura real manda, no payload do webhook, o ID DELE
-- (`provider_envelope_id`), nunca o UUID interno do OptiMon. A rota Node do
-- webhook roda sem JWT de usuário (é o provedor externo chamando, `anon`) — e
-- `signature_envelopes_select` só libera para `to authenticated`, então nem
-- uma consulta simples de tradução provider_envelope_id→id funcionaria com
-- `anon`. Em vez de afrouxar a policy de SELECT para anon (o que exporia todo
-- envelope pra qualquer chamada anônima), esta migration acrescenta uma
-- função SECURITY DEFINER estreita que só faz essa tradução internamente e
-- delega pro fluxo idempotente já existente — sem duplicar nenhuma lógica de
-- webhook, só resolvendo o identificador.

create or replace function app.registrar_evento_assinatura_webhook_por_provider_id(
  p_provider_envelope_id text,
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
  v_envelope_id uuid;
begin
  select id into v_envelope_id from public.signature_envelopes where provider_envelope_id = p_provider_envelope_id;
  if v_envelope_id is null then
    raise exception 'NAO_ENCONTRADO: nenhum envelope de assinatura com provider_envelope_id=% — evento do provedor ignorado.', p_provider_envelope_id;
  end if;

  return app.registrar_evento_assinatura_webhook(
    v_envelope_id, p_evento_externo_id, p_tipo_evento, p_payload, p_novo_status_envelope,
    p_signer_email, p_signer_novo_status, p_signer_ip, p_signer_certificado, p_hash_assinado, p_storage_path_assinado
  );
end;
$$;

comment on function app.registrar_evento_assinatura_webhook_por_provider_id is 'Fase 2.5 seção 27/49: único ponto de entrada usado pela rota Node do webhook — traduz o provider_envelope_id (o único identificador que um provedor externo real conhece) para o envelope_id interno, depois delega para app.registrar_evento_assinatura_webhook (idempotência inalterada, mesma tabela signature_events).';

drop function if exists public.pricing_signature_webhook_event_by_provider_id(text, text, text, jsonb, text, text, text, text, jsonb, text, text);
create or replace function public.pricing_signature_webhook_event_by_provider_id(
  p_provider_envelope_id text, p_evento_externo_id text, p_tipo_evento text, p_payload jsonb default null,
  p_novo_status_envelope text default null, p_signer_email text default null, p_signer_novo_status text default null,
  p_signer_ip text default null, p_signer_certificado jsonb default null, p_hash_assinado text default null,
  p_storage_path_assinado text default null
)
returns jsonb
language sql
security definer
set search_path = public, app, pg_temp
as $$
  select app.registrar_evento_assinatura_webhook_por_provider_id(p_provider_envelope_id, p_evento_externo_id, p_tipo_evento, p_payload, p_novo_status_envelope, p_signer_email, p_signer_novo_status, p_signer_ip, p_signer_certificado, p_hash_assinado, p_storage_path_assinado);
$$;

comment on function public.pricing_signature_webhook_event_by_provider_id is 'Fase 2.5: mesma razão de SECURITY DEFINER que public.pricing_signature_webhook_event (migration 07) — anon não tem USAGE no schema app.';

grant execute on function public.pricing_signature_webhook_event_by_provider_id(text, text, text, jsonb, text, text, text, text, jsonb, text, text) to anon;
