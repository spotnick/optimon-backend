-- OptiMon — Fase 2.5 (13, correção aditiva): resolução do nome do secret de
-- webhook (seção 27/49) para validação HMAC feita em Node, ANTES de chamar
-- qualquer RPC de evento.
--
-- A rota Node do webhook precisa saber QUAL variável de ambiente
-- (`signature_providers.webhook_secret_ref` — só o NOME, nunca o valor real,
-- disciplina de "nunca guardar segredo de verdade no banco" já usada em toda
-- a Fase 2.5) usar para validar a assinatura HMAC do payload recebido — mas
-- só sabe o `provider_envelope_id` do payload nesse ponto, e `anon` não pode
-- consultar signature_envelopes/signature_providers diretamente (RLS só libera
-- para `authenticated`). Mesma solução das migrations 12/07: uma função
-- SECURITY DEFINER estreita, que devolve só o nome da variável (nunca a linha
-- inteira, nunca o segredo em si).

create or replace function app.obter_webhook_secret_ref(p_provider_envelope_id text)
returns text
language sql
security definer
set search_path = public, pg_temp
as $$
  select sp.webhook_secret_ref
  from public.signature_envelopes se
  join public.signature_providers sp on sp.id = se.provider_id
  where se.provider_envelope_id = p_provider_envelope_id;
$$;

comment on function app.obter_webhook_secret_ref(text) is 'Fase 2.5 seção 27/49: devolve só o NOME da variável de ambiente do secret (nunca o segredo em si, nunca a linha completa de signature_providers) — usado pela rota Node do webhook para saber com qual chave validar o HMAC antes de processar o evento.';

drop function if exists public.pricing_signature_webhook_secret_ref(text);
create or replace function public.pricing_signature_webhook_secret_ref(p_provider_envelope_id text)
returns text
language sql
security definer
set search_path = public, app, pg_temp
as $$ select app.obter_webhook_secret_ref(p_provider_envelope_id); $$;

grant execute on function public.pricing_signature_webhook_secret_ref(text) to anon;
