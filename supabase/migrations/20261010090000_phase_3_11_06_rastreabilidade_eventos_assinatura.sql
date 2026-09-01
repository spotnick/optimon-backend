-- OptiMon — Fase 3.11.6 (seção 1/2/3): rastreabilidade real da assinatura.
--
-- CAUSA RAIZ (investigada por leitura de código, nunca presumida — ver
-- FASE_3_11_6_RELATORIO_FINAL.md seção "EVENTOS / WEBHOOK" para o detalhe completo):
-- `public.signature_events` foi criada na Fase 2.5 (migration 20260913090300) para
-- receber webhooks de um provedor de assinatura eletrônica real (ICP-Brasil), via
-- app.registrar_evento_assinatura_webhook[_por_provider_id]. A partir da Fase 3.11.3/
-- 3.11.4, o projeto passou a usar o provedor OPTIMON_INTERNO_RESEND (nunca um
-- provedor externo de assinatura) — o único webhook real que existe hoje é o do
-- Resend (api/routes/emailWebhooks.js), que relata só EVENTOS DE E-MAIL (sent/
-- delivered/bounced/complained/failed), nunca "documento assinado". Esse webhook
-- NUNCA chama app.registrar_evento_assinatura_webhook — ele chama
-- app.registrar_status_email_assinatura_por_provider_id (para o link de assinatura)
-- ou app.registrar_status_email_aceite_por_provider_id (para o aceite de proposta),
-- nenhuma das duas grava em signature_events. Resultado: signature_events está
-- estruturalmente órfã/vazia nesta arquitetura — e é exatamente essa tabela (vazia)
-- que GET /api/signatures/envelopes/:id/audit consulta, o que explica 100% do
-- sintoma relatado ("Evento recebido em: Nenhum evento recebido ainda.") mesmo com
-- contratos genuinamente assinados em produção.
--
-- O trilho REAL e completo dos eventos (SIGNATURE_SIGNER_ADDED, SIGNATURE_SEND_
-- REQUESTED, SIGNATURE_DELIVERED, SIGNATURE_OPENED, SIGNATURE_ACCEPT_OTP_REQUESTED,
-- SIGNATURE_SIGNED, SIGNATURE_VALIDATED, SIGNATURE_DOCUMENT_ASSINADO_GERADO etc.)
-- já existe, rico e correto, na tabela `auditoria` (via app.registrar_auditoria_
-- semantica) — só nunca foi essa tabela que a UI consultava.
--
-- CORREÇÃO (nunca cosmética, nunca "esconder o problema"):
--  1) api/routes/signatures.js (GET /envelopes/:id/audit) passa a também consultar
--     `auditoria` (entidade='signature_envelopes'/'signature_signers') e devolver
--     uma trilha unificada — dado real, não a tabela errada.
--  2) signature_events é reaproveitada (nunca substituída por uma tabela nova) como
--     o livro-razão de RECEBIMENTO de webhook em si — o único evento verdadeiramente
--     "externo" que existe hoje é a chamada do Resend. envelope_id passa a aceitar
--     NULL (nem todo webhook recebido é resolvível a um envelope: pode ser de um
--     e-mail de aceite de PROPOSTA, ou de um payload desconhecido/rejeitado), e
--     ganha as colunas que a seção 2 do pedido pede (provider, processado_em,
--     resultado, erro, payload_hash) para diferenciar "recebido" de "processado" e
--     dar prova de idempotência/rejeição.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) signature_events — envelope_id vira opcional; novas colunas de rastreio.
-- ----------------------------------------------------------------------------

alter table public.signature_events
  alter column envelope_id drop not null;

alter table public.signature_events
  add column if not exists signer_id uuid references public.signature_signers(id) on delete set null,
  add column if not exists provider text not null default 'RESEND_EMAIL_WEBHOOK',
  add column if not exists processado_em timestamptz,
  add column if not exists resultado text not null default 'PENDENTE',
  add column if not exists erro text,
  add column if not exists payload_hash text;

alter table public.signature_events drop constraint if exists signature_events_resultado_check;
alter table public.signature_events add constraint signature_events_resultado_check
  check (resultado = any (array['PENDENTE', 'PROCESSADO', 'REJEITADO', 'DESCONHECIDO']));

comment on column public.signature_events.provider is 'Fase 3.11.6: identifica a origem do webhook (hoje só RESEND_EMAIL_WEBHOOK existe de fato) — parte da chave de idempotência junto com evento_externo_id.';
comment on column public.signature_events.resultado is 'Fase 3.11.6: PENDENTE (recebido, ainda não processado) / PROCESSADO (aplicado com sucesso) / REJEITADO (assinatura inválida ou payload rejeitado) / DESCONHECIDO (evento que não corresponde a nenhuma tentativa/envelope conhecido — registrado sem quebrar o sistema, seção 3 do pedido).';
comment on column public.signature_events.processado_em is 'Fase 3.11.6: distingue "recebido" (recebido_em, sempre no ato do webhook) de "processado" (processado_em, só quando o resultado — PROCESSADO/REJEITADO/DESCONHECIDO — é decidido).';

-- A Fase 2.5 já populou signature_events com eventos sintéticos de homologação
-- (app.registrar_evento_assinatura_webhook, nunca um webhook real do Resend), cuja
-- unicidade era só (envelope_id, evento_externo_id) — o mesmo evento_externo_id
-- textual (ex.: "evt-2-e2e311") foi reaproveitado por vários envelopes de teste
-- diferentes ao longo das fases. Isso colide com a nova chave global (provider,
-- evento_externo_id) abaixo. Corrige sem apagar histórico: essas linhas PRÉ-
-- EXISTENTES recebem uma tag de provider que preserva o envelope de origem — nunca
-- alterando evento_externo_id nem qualquer outro dado. Idempotente por natureza (só
-- casa provider='RESEND_EMAIL_WEBHOOK', que essas linhas deixam de ter após rodar).
update public.signature_events
   set provider = 'LEGADO_FASE_2_5_TESTE:' || envelope_id::text
 where provider = 'RESEND_EMAIL_WEBHOOK'
   and envelope_id is not null;

-- Idempotência real (seção 3): a chave (envelope_id, evento_externo_id) antiga não
-- protege quando envelope_id é NULL (NULLs nunca colidem em UNIQUE). A partir de
-- agora, (provider, evento_externo_id) é a chave de idempotência — evento_externo_id
-- é o svix-id do Resend, único por tentativa de entrega de webhook, nunca reciclado.
drop index if exists signature_events_provider_evento_externo_uk;
create unique index signature_events_provider_evento_externo_uk
  on public.signature_events(provider, evento_externo_id);

create index if not exists signature_events_recebido_em_idx on public.signature_events(recebido_em desc);

-- ----------------------------------------------------------------------------
-- 2) Funções de registro do webhook — mesmo padrão SECURITY DEFINER app.* +
--    wrapper public.pricing_* granted to anon (nunca inventar um 2º padrão).
-- ----------------------------------------------------------------------------

create or replace function app.registrar_webhook_recebido(
  p_provider text,
  p_evento_externo_id text,
  p_tipo_evento text,
  p_payload jsonb,
  p_payload_hash text default null
)
returns table(evento_id uuid, duplicado boolean)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_existing uuid;
  v_new uuid;
begin
  select se.id into v_existing from public.signature_events se
   where se.provider = p_provider and se.evento_externo_id = p_evento_externo_id;
  if v_existing is not null then
    return query select v_existing, true;
    return;
  end if;

  insert into public.signature_events (
    envelope_id, evento_externo_id, tipo_evento, payload, payload_hash, provider,
    processado, resultado, recebido_em
  ) values (
    null, p_evento_externo_id, p_tipo_evento, p_payload, p_payload_hash, p_provider,
    false, 'PENDENTE', now()
  )
  on conflict (provider, evento_externo_id) do nothing
  returning id into v_new;

  if v_new is null then
    -- corrida entre o SELECT acima e o INSERT: outra chamada concorrente venceu.
    -- Mesmo efeito de idempotência, só que descoberto um passo depois.
    select se.id into v_new from public.signature_events se
     where se.provider = p_provider and se.evento_externo_id = p_evento_externo_id;
    return query select v_new, true;
    return;
  end if;

  return query select v_new, false;
end;
$$;
comment on function app.registrar_webhook_recebido(text, text, text, jsonb, text) is 'Fase 3.11.6 (seção 2/3): primeiro passo de todo webhook — registra o RECEBIMENTO (recebido_em=now(), resultado=PENDENTE) antes de qualquer processamento, e devolve duplicado=true sem criar linha nova se o mesmo (provider, evento_externo_id) já existir. Isso é a prova de "evento recebido" e a garantia de idempotência (mesmo evento enviado 2x → só um efeito).';

create or replace function app.marcar_webhook_processado(
  p_evento_id uuid, p_envelope_id uuid default null, p_signer_id uuid default null
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.signature_events
     set processado = true,
         processado_em = now(),
         resultado = 'PROCESSADO',
         envelope_id = coalesce(p_envelope_id, envelope_id),
         signer_id = coalesce(p_signer_id, signer_id)
   where id = p_evento_id;
$$;
comment on function app.marcar_webhook_processado(uuid, uuid, uuid) is 'Fase 3.11.6: segundo passo — chamado só depois que o efeito real (ex.: atualizar signature_signers) já foi aplicado com sucesso. processado_em != recebido_em na prática (mesmo que por poucos ms) é a prova de "evento processado" distinta de "evento recebido".';

create or replace function app.marcar_webhook_rejeitado(p_evento_id uuid, p_erro text)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.signature_events
     set processado = false, processado_em = now(), resultado = 'REJEITADO', erro = p_erro
   where id = p_evento_id;
$$;
comment on function app.marcar_webhook_rejeitado(uuid, text) is 'Fase 3.11.6 (seção 3): evento chegou (recebido_em já gravado), mas foi recusado — payload malformado, adulterado, ou uma condição de negócio inválida. Nunca derruba o sistema: só marca o próprio evento.';

create or replace function app.marcar_webhook_desconhecido(p_evento_id uuid, p_detalhe text default null)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.signature_events
     set processado = false, processado_em = now(), resultado = 'DESCONHECIDO', erro = p_detalhe
   where id = p_evento_id;
$$;
comment on function app.marcar_webhook_desconhecido(uuid, text) is 'Fase 3.11.6 (seção 3): tipo de evento não mapeado ou email_provider_id que não corresponde a nenhuma tentativa/envelope conhecido — registrado como recebido, marcado DESCONHECIDO, nunca derruba o sistema nem gera erro 500.';

create or replace function public.pricing_signature_webhook_recebido(
  p_provider text, p_evento_externo_id text, p_tipo_evento text, p_payload jsonb, p_payload_hash text default null
)
returns table(evento_id uuid, duplicado boolean)
language sql security definer set search_path = public, pg_temp as $$
  select * from app.registrar_webhook_recebido(p_provider, p_evento_externo_id, p_tipo_evento, p_payload, p_payload_hash);
$$;
grant execute on function public.pricing_signature_webhook_recebido(text, text, text, jsonb, text) to anon;

create or replace function public.pricing_signature_webhook_processado(
  p_evento_id uuid, p_envelope_id uuid default null, p_signer_id uuid default null
)
returns void
language sql security definer set search_path = public, pg_temp as $$
  select app.marcar_webhook_processado(p_evento_id, p_envelope_id, p_signer_id);
$$;
grant execute on function public.pricing_signature_webhook_processado(uuid, uuid, uuid) to anon;

create or replace function public.pricing_signature_webhook_rejeitado(p_evento_id uuid, p_erro text)
returns void
language sql security definer set search_path = public, pg_temp as $$
  select app.marcar_webhook_rejeitado(p_evento_id, p_erro);
$$;
grant execute on function public.pricing_signature_webhook_rejeitado(uuid, text) to anon;

create or replace function public.pricing_signature_webhook_desconhecido(p_evento_id uuid, p_detalhe text default null)
returns void
language sql security definer set search_path = public, pg_temp as $$
  select app.marcar_webhook_desconhecido(p_evento_id, p_detalhe);
$$;
grant execute on function public.pricing_signature_webhook_desconhecido(uuid, text) to anon;

-- ----------------------------------------------------------------------------
-- 3) app.registrar_status_email_assinatura_por_provider_id passa a devolver
--    envelope_id também (só um campo a mais no jsonb — nunca muda o efeito
--    já existente) para que o webhook consiga associar o evento ao envelope.
-- ----------------------------------------------------------------------------

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
  return jsonb_build_object('signer_id', v_signer.id, 'envelope_id', v_signer.envelope_id, 'evento', p_evento);
end;
$$;
comment on function app.registrar_status_email_assinatura_por_provider_id(text, text, text) is 'Fase 3.11.4, estendida na Fase 3.11.6: agora também devolve envelope_id no jsonb (mesmo efeito de antes, só um campo a mais) — usado por api/routes/emailWebhooks.js para associar o evento de signature_events ao envelope correto.';

-- ----------------------------------------------------------------------------
-- 4) Grant de SELECT em signature_events já existente cobre a leitura da UI
--    (authenticated). Nenhuma policy nova necessária.
-- ----------------------------------------------------------------------------

-- ============================================================================
-- OptiMon — Fase 3.11.6 (seção 7/8): CPF no aceite da proposta.
--
-- Investigação real (nunca presumida): app.iniciar_aceite_proposta_parceiro (Fase
-- 3.11.2) só checava p_documento não-vazio — nunca validava dígito verificador nem
-- rejeitava sequências óbvias (000.000.000-00, 111.111.111-11 etc.), diferente do
-- que a assinatura de contrato já faz desde a Fase 3.11.5 (app.cpf_valido, chamada
-- por app.assinatura_externa_assinar_iniciar). Corrigido aqui reaproveitando A MESMA
-- função app.cpf_valido (nunca um 2º validador) no mesmo ponto do fluxo.
--
-- Normalização (pedido explícito: "123.456.789-00 = 12345678900, nunca armazenar
-- versões inconsistentes"): documento_normalizado (só dígitos) é adicionado como
-- coluna PRÓPRIA, gravada ao lado do valor como o parceiro digitou — nunca
-- substituindo esse valor. A razão: propostas_comerciais.aceite_documento já é
-- exibido formatado (com pontuação) no card "ACEITE DO PARCEIRO" do frontend desde a
-- Fase 3.11.2 — mudar esse valor para só-dígitos quebraria essa exibição sem
-- necessidade. O ponto real da normalização (nunca tratar "123.456.789-00" e
-- "12345678900" como CPFs DIFERENTES) é resolvido comparando/armazenando sempre a
-- forma normalizada em paralelo — nunca uma segunda fonte de verdade inconsistente.
-- ============================================================================

alter table public.propostas_aceite_tentativas add column if not exists documento_normalizado text;
alter table public.propostas_comerciais add column if not exists aceite_documento_normalizado text;

comment on column public.propostas_aceite_tentativas.documento_normalizado is 'Fase 3.11.6 (seção 7): CPF só dígitos (regexp_replace(documento, ''\D'','''',''g'')) — nunca a única forma armazenada (documento preserva o que o parceiro digitou, para exibição), usada para nunca tratar duas grafias do mesmo CPF como identidades diferentes.';

create or replace function app.iniciar_aceite_proposta_parceiro(
  p_token text,
  p_nome text,
  p_documento text,
  p_cargo text,
  p_email text,
  p_telefone text,
  p_declaracao boolean,
  p_confirmacao boolean,
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
  v_prop public.propostas_comerciais;
  v_tentativa_id uuid;
  v_expira timestamptz;
  v_documento_normalizado text;
begin
  if p_nome is null or trim(p_nome) = '' then raise exception 'DADOS_OBRIGATORIOS: nome completo do representante é obrigatório.'; end if;
  if p_documento is null or trim(p_documento) = '' then raise exception 'DADOS_OBRIGATORIOS: CPF do representante é obrigatório.'; end if;
  -- Fase 3.11.6 (seção 7): mesma validação real (dígito verificador, mod 11, rejeita
  -- sequências repetidas) já usada na assinatura do contrato — nunca só formato/tamanho,
  -- e nunca só no frontend (aqui é impossível de contornar chamando a API direto).
  if not app.cpf_valido(p_documento) then
    raise exception 'CPF_INVALIDO: CPF informado não é válido — confira os números digitados.';
  end if;
  if p_email is null or trim(p_email) = '' then raise exception 'DADOS_OBRIGATORIOS: e-mail é obrigatório.'; end if;
  if p_declaracao is distinct from true then
    raise exception 'DECLARACAO_OBRIGATORIA: é necessário declarar que é representante autorizado da empresa e possui poderes para manifestar o aceite.';
  end if;
  if p_confirmacao is distinct from true then
    raise exception 'CONFIRMACAO_OBRIGATORIA: é necessário confirmar o aceite e autorizar o prosseguimento para elaboração do contrato.';
  end if;
  if p_otp_hash is null or length(p_otp_hash) < 32 then
    raise exception 'OTP_INVALIDO: falha interna ao gerar o código de confirmação — tente novamente.';
  end if;

  select * into v_prop from public.propostas_comerciais where token_acesso_externo = p_token;
  if v_prop.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  if v_prop.token_revogado_em is not null then
    raise exception 'TOKEN_REVOGADO: este link foi revogado — solicite um novo envio ao consultor comercial.';
  end if;
  if v_prop.token_expira_em is not null and v_prop.token_expira_em < now() then
    raise exception 'TOKEN_EXPIRADO: este link expirou — solicite um novo envio.';
  end if;
  if v_prop.status not in ('ENVIADA_AO_PARCEIRO', 'VISUALIZADA_PELO_PARCEIRO') then
    raise exception 'STATUS_INVALIDO: esta proposta está em status % — não pode receber um novo aceite (evita aceite duplicado, de proposta expirada/cancelada, ou fora de ordem).', v_prop.status;
  end if;

  -- Nunca deixa 2 tentativas AGUARDANDO_OTP simultâneas para a mesma proposta — evita
  -- ambiguidade sobre qual código vale (proteção contra replay de uma solicitação antiga).
  update public.propostas_aceite_tentativas
     set status = 'CANCELADO'
   where proposta_id = v_prop.id and status = 'AGUARDANDO_OTP';

  v_expira := now() + make_interval(mins => greatest(coalesce(p_otp_ttl_minutos, 10), 1));
  v_documento_normalizado := regexp_replace(p_documento, '\D', '', 'g');

  insert into public.propostas_aceite_tentativas
    (proposta_id, token_hash, nome, documento, documento_normalizado, cargo, email, telefone, declaracao_aceita, confirmacao_aceita,
     otp_hash, otp_expira_em, ip, user_agent)
  values
    (v_prop.id, md5(p_token), trim(p_nome), trim(p_documento), v_documento_normalizado, nullif(trim(coalesce(p_cargo, '')), ''), trim(lower(p_email)),
     nullif(trim(coalesce(p_telefone, '')), ''), true, true, p_otp_hash, v_expira, p_ip, p_user_agent)
  returning id into v_tentativa_id;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_prop.id, 'PROPOSAL_ACCEPT_OTP_REQUESTED',
    'Código de confirmação solicitado para efetivar o aceite formal.', null,
    jsonb_build_object('tentativa_id', v_tentativa_id, 'nome', trim(p_nome), 'email', trim(lower(p_email)), 'user_agent', p_user_agent),
    'parceiro_externo', p_ip);

  return jsonb_build_object('tentativa_id', v_tentativa_id, 'expira_em', v_expira);
end;
$$;
comment on function app.iniciar_aceite_proposta_parceiro(text, text, text, text, text, text, boolean, boolean, text, integer, text, text) is 'Fase 3.11.2, estendida na Fase 3.11.6 (seção 7): passo 1 do aceite — agora valida CPF de verdade (app.cpf_valido) e grava documento_normalizado, além de tudo que já validava antes (nome/documento/e-mail obrigatórios, declaração, confirmação, OTP). Nunca muda propostas_comerciais.status.';

create or replace function app.confirmar_aceite_proposta_parceiro(
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
  v_prop public.propostas_comerciais;
  v_tent public.propostas_aceite_tentativas;
  v_max_tentativas constant integer := 5;
  v_hash_proposta text;
  v_ip_final inet;
begin
  select * into v_prop from public.propostas_comerciais where token_acesso_externo = p_token;
  if v_prop.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  if v_prop.token_revogado_em is not null then
    raise exception 'TOKEN_REVOGADO: este link foi revogado — solicite um novo envio ao consultor comercial.';
  end if;

  select * into v_tent from public.propostas_aceite_tentativas
   where id = p_tentativa_id and proposta_id = v_prop.id
   for update;
  if v_tent.id is null then
    raise exception 'TENTATIVA_INVALIDA: nenhuma solicitação de código encontrada para esta proposta — solicite um novo código.';
  end if;

  if v_tent.status = 'CONFIRMADO' then
    raise exception 'ACEITE_DUPLICADO: este aceite já foi confirmado anteriormente — não é possível confirmar duas vezes.';
  end if;
  if v_tent.status = 'CANCELADO' then
    raise exception 'TENTATIVA_EXPIRADA: este código não é mais válido (substituído por um mais recente ou cancelado) — solicite um novo.';
  end if;
  if v_tent.otp_expira_em < now() then
    update public.propostas_aceite_tentativas set status = 'EXPIRADO' where id = v_tent.id;
    raise exception 'OTP_EXPIRADO: o código de confirmação expirou — solicite um novo.';
  end if;
  if v_tent.otp_tentativas >= v_max_tentativas then
    update public.propostas_aceite_tentativas set status = 'CANCELADO' where id = v_tent.id;
    raise exception 'OTP_BLOQUEADO: número máximo de tentativas incorretas excedido — solicite um novo código.';
  end if;
  if v_prop.status not in ('ENVIADA_AO_PARCEIRO', 'VISUALIZADA_PELO_PARCEIRO') then
    raise exception 'STATUS_INVALIDO: esta proposta está em status % — aceite não pode ser confirmado (evita aceite duplicado, de proposta expirada/cancelada, ou fora de ordem).', v_prop.status;
  end if;

  if p_otp_hash_attempt is null or v_tent.otp_hash is distinct from p_otp_hash_attempt then
    update public.propostas_aceite_tentativas set otp_tentativas = otp_tentativas + 1 where id = v_tent.id;
    perform app.registrar_auditoria_semantica('propostas_comerciais', v_prop.id, 'PROPOSAL_ACCEPT_OTP_FAILED',
      'Código de confirmação incorreto informado pelo parceiro.', null,
      jsonb_build_object('tentativa_id', v_tent.id, 'tentativa_numero', v_tent.otp_tentativas + 1, 'max_tentativas', v_max_tentativas),
      'parceiro_externo', p_ip);
    raise exception 'OTP_INCORRETO: código de confirmação incorreto (tentativa % de %).', v_tent.otp_tentativas + 1, v_max_tentativas;
  end if;

  v_hash_proposta := md5(coalesce(v_prop.snapshot::text, '') || '|' || coalesce(v_prop.snapshot->>'preco_proposto', '') || '|' || coalesce(v_prop.numero_versao::text, ''));

  begin
    v_ip_final := nullif(split_part(coalesce(p_ip, v_tent.ip, ''), ',', 1), '')::inet;
  exception when others then
    v_ip_final := null;
  end;

  update public.propostas_aceite_tentativas set status = 'CONFIRMADO', confirmado_em = now() where id = v_tent.id;

  update public.propostas_comerciais
     set status = 'ACEITA_PELO_PARCEIRO',
         aceite_nome = v_tent.nome,
         aceite_documento = v_tent.documento,
         aceite_documento_normalizado = v_tent.documento_normalizado,
         aceite_cargo = v_tent.cargo,
         aceite_email = v_tent.email,
         aceite_telefone = v_tent.telefone,
         aceite_em = now(),
         aceite_ip = v_ip_final,
         aceite_user_agent = coalesce(p_user_agent, v_tent.user_agent),
         aceite_metodo = 'OTP_EMAIL',
         aceite_versao_termo = 'v1-2026-08',
         aceite_hash_proposta = v_hash_proposta,
         aceite_token_hash = md5(p_token)
   where id = v_prop.id
   returning * into v_prop;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_prop.id, 'PROPOSAL_ACCEPTED_BY_PARTNER',
    'Aceite formal confirmado pelo parceiro (código de confirmação validado — declaração de poderes e dupla confirmação registradas).',
    null,
    jsonb_build_object(
      'aceite_nome', v_prop.aceite_nome, 'aceite_documento', v_prop.aceite_documento, 'aceite_email', v_prop.aceite_email,
      'metodo', v_prop.aceite_metodo, 'versao_termo', v_prop.aceite_versao_termo, 'hash_proposta', v_prop.aceite_hash_proposta,
      'user_agent', v_prop.aceite_user_agent, 'tentativa_id', v_tent.id
    ),
    'parceiro_externo', p_ip);

  return jsonb_build_object('id', v_prop.id, 'numero', v_prop.numero, 'status', v_prop.status, 'aceite_em', v_prop.aceite_em);
end;
$$;
comment on function app.confirmar_aceite_proposta_parceiro(text, uuid, text, text, text) is 'Fase 3.11.2, estendida na Fase 3.11.6 (seção 8): passo 2 do aceite — agora também propaga documento_normalizado para propostas_comerciais.aceite_documento_normalizado (vinculação do CPF normalizado à evidência do aceite). Comportamento de validação de OTP/status idêntico ao de antes.';

-- ============================================================================
-- OptiMon — Fase 3.11.6 (seção 5/6): PDF final "PROPOSTA ACEITA ELETRONICAMENTE" +
-- certificado. Mirror EXATO do padrão já construído para o contrato (Fase 3.11.5:
-- documentos_assinados + gerarDocumentoAssinadoContrato + pdfContrato.js
-- opts.certificado) — nunca um 2º motor/padrão. Distingue MINUTA (documento gerado
-- sob demanda desde a Fase 2.4, nunca persistido) / PROPOSTA ENVIADA (status já
-- existente) / PROPOSTA ACEITA (status ACEITA_PELO_PARCEIRO, já existente) / PROPOSTA
-- ACEITA E VALIDADA (o par storage_path_original + storage_path_aceite desta seção —
-- "validada" no sentido de: o documento que o parceiro efetivamente aceitou está
-- persistido e vinculado ao certificado, nunca regenerável de forma diferente).
-- ============================================================================

create table if not exists public.propostas_documentos_assinados (
  id uuid primary key default gen_random_uuid(),
  proposta_id uuid not null unique references public.propostas_comerciais(id) on delete cascade,
  storage_path_original text,
  storage_path_aceite text,
  hash_sha256_original text,
  hash_sha256_aceite text,
  criado_em timestamptz not null default now(),
  concluido_em timestamptz
);
comment on table public.propostas_documentos_assinados is 'Fase 3.11.6 (seção 5): mirror de public.documentos_assinados (Fase 2.5), mas para a PROPOSTA — storage_path_original é a minuta exatamente como estava no momento do aceite (nunca sobrescrita depois de gravada uma vez — ver app.registrar_documentos_proposta_aceite); storage_path_aceite é o PDF final "PROPOSTA ACEITA ELETRONICAMENTE" com a página de certificado.';

create index if not exists propostas_documentos_assinados_proposta_idx on public.propostas_documentos_assinados(proposta_id);

alter table public.propostas_documentos_assinados enable row level security;
drop policy if exists propostas_documentos_assinados_select on public.propostas_documentos_assinados;
create policy propostas_documentos_assinados_select
  on public.propostas_documentos_assinados for select
  to authenticated
  using (true);
-- Nenhuma policy de INSERT/UPDATE para authenticated/anon — só via
-- app.registrar_documentos_proposta_aceite (SECURITY DEFINER), mesmo padrão de
-- documentos_assinados (Fase 2.5).

-- auditoria_acao_check ganha 1 ação nova (nunca remove nenhuma existente).
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
  -- Fase 3.11.6:
  'PROPOSAL_ACCEPT_DOCUMENT_GENERATED',
  'CLEANUP_HOMOLOGACAO'
]));

-- app.registrar_auditoria_semantica também precisa da whitelist ampliada (mesma lista
-- da tabela acima) — CREATE OR REPLACE preserva tudo que já existia, só acrescenta.
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
    'CLEANUP_HOMOLOGACAO'
  ) then
    raise exception 'ACAO_INVALIDA: % não está na whitelist de ações semânticas de auditoria.', p_acao;
  end if;

  begin
    v_ip := nullif(p_ip, '')::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, valor_anterior, valor_novo, origem, motivo, ip)
  values (auth.uid(), p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, coalesce(p_origem, 'app'), p_motivo, v_ip);
end;
$function$;
comment on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb, text, text) is 'Fase 2.3.1, estendida a cada fase — Fase 3.11.6 acrescenta PROPOSAL_ACCEPT_DOCUMENT_GENERATED e CLEANUP_HOMOLOGACAO. SECURITY DEFINER para poder inserir em auditoria mesmo sem policy de INSERT para authenticated; sempre grava auth.uid() do chamador, nunca um usuario_id arbitrário vindo de parâmetro.';

-- ----------------------------------------------------------------------------
-- RPCs anônimas escopadas por token (mesmo padrão de todo proposalsExternal.js):
-- dados completos p/ gerar o PDF, dados do certificado, registrar os caminhos,
-- e ler os caminhos já registrados.
-- ----------------------------------------------------------------------------

create or replace function app.proposta_documento_dados_por_token(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app.enriquecer_proposta(pc)
    from public.propostas_comerciais pc
   where pc.token_acesso_externo = p_token
     and pc.aceite_em is not null;
$$;
comment on function app.proposta_documento_dados_por_token(text) is 'Fase 3.11.6 (seção 5): mesmo shape de public.pricing_proposal_get_by_id (app.enriquecer_proposta), mas escopado por token e só depois de aceite_em preenchido (aceite real confirmado) — nunca antes disso. Usado para gerar o PDF final (original + aceite) sem exigir sessão de staff.';

create or replace function public.pricing_proposta_documento_dados_por_token(p_token text)
returns jsonb
language sql security definer set search_path = public, pg_temp as $$
  select app.proposta_documento_dados_por_token(p_token);
$$;
grant execute on function public.pricing_proposta_documento_dados_por_token(text) to anon;

create or replace function app.proposta_aceite_certificado_dados_por_token(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case when pc.aceite_em is null then null else jsonb_build_object(
    'proposta_id', pc.id,
    'numero', pc.numero,
    'aceite_nome', pc.aceite_nome,
    'aceite_documento', pc.aceite_documento,
    'aceite_documento_normalizado', pc.aceite_documento_normalizado,
    'aceite_cargo', pc.aceite_cargo,
    'aceite_email', pc.aceite_email,
    'aceite_ip', pc.aceite_ip::text,
    'aceite_user_agent', pc.aceite_user_agent,
    'aceite_metodo', pc.aceite_metodo,
    'aceite_em', pc.aceite_em,
    'aceite_versao_termo', pc.aceite_versao_termo,
    'aceite_hash_proposta', pc.aceite_hash_proposta,
    'aceite_token_hash', pc.aceite_token_hash
  ) end
  from public.propostas_comerciais pc
  where pc.token_acesso_externo = p_token;
$$;
comment on function app.proposta_aceite_certificado_dados_por_token(text) is 'Fase 3.11.6 (seção 6): dados exatos do certificado (nome/CPF/e-mail/IP/data-hora/método/hash) — nunca inclui otp_hash nem qualquer segredo. Devolve null se a proposta ainda não foi aceita (aceite_em is null) — nunca gera certificado de um aceite que não aconteceu.';

create or replace function public.pricing_proposta_aceite_certificado_dados_por_token(p_token text)
returns jsonb
language sql security definer set search_path = public, pg_temp as $$
  select app.proposta_aceite_certificado_dados_por_token(p_token);
$$;
grant execute on function public.pricing_proposta_aceite_certificado_dados_por_token(text) to anon;

create or replace function app.registrar_documentos_proposta_aceite(
  p_token text, p_storage_path_original text, p_hash_original text,
  p_storage_path_aceite text default null, p_hash_aceite text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prop public.propostas_comerciais;
  v_row public.propostas_documentos_assinados;
begin
  select * into v_prop from public.propostas_comerciais where token_acesso_externo = p_token;
  if v_prop.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  if v_prop.aceite_em is null then
    raise exception 'STATUS_INVALIDO: proposta ainda não foi aceita — não é possível registrar o documento de aceite.';
  end if;

  insert into public.propostas_documentos_assinados
    (proposta_id, storage_path_original, hash_sha256_original, storage_path_aceite, hash_sha256_aceite, concluido_em)
  values
    (v_prop.id, p_storage_path_original, p_hash_original, p_storage_path_aceite, p_hash_aceite, now())
  on conflict (proposta_id) do update set
    -- nunca substitui um storage_path_original já gravado (seção 5: "nunca substituir
    -- a minuta/original") — só preenche se ainda estiver null.
    storage_path_original = coalesce(public.propostas_documentos_assinados.storage_path_original, excluded.storage_path_original),
    hash_sha256_original = coalesce(public.propostas_documentos_assinados.hash_sha256_original, excluded.hash_sha256_original),
    storage_path_aceite = coalesce(excluded.storage_path_aceite, public.propostas_documentos_assinados.storage_path_aceite),
    hash_sha256_aceite = coalesce(excluded.hash_sha256_aceite, public.propostas_documentos_assinados.hash_sha256_aceite),
    concluido_em = now()
  returning * into v_row;

  if p_storage_path_aceite is not null then
    perform app.registrar_auditoria_semantica('propostas_comerciais', v_prop.id, 'PROPOSAL_ACCEPT_DOCUMENT_GENERATED',
      'PDF final da proposta aceita (com certificado de aceite eletrônico) gerado.', null,
      jsonb_build_object('storage_path_aceite', p_storage_path_aceite, 'hash_sha256_aceite', p_hash_aceite),
      'sistema', null);
  end if;

  return jsonb_build_object(
    'proposta_id', v_row.proposta_id, 'storage_path_original', v_row.storage_path_original,
    'storage_path_aceite', v_row.storage_path_aceite
  );
end;
$$;
comment on function app.registrar_documentos_proposta_aceite(text, text, text, text, text) is 'Fase 3.11.6 (seção 5): registra os caminhos do Storage para a minuta original E o PDF final de aceite — nunca sobrescreve storage_path_original depois de gravado (COALESCE explícito). Escopado por token, exige aceite_em já preenchido.';

create or replace function public.pricing_proposta_documento_aceite_registrar(
  p_token text, p_storage_path_original text, p_hash_original text,
  p_storage_path_aceite text default null, p_hash_aceite text default null
)
returns jsonb
language sql security definer set search_path = public, pg_temp as $$
  select app.registrar_documentos_proposta_aceite(p_token, p_storage_path_original, p_hash_original, p_storage_path_aceite, p_hash_aceite);
$$;
grant execute on function public.pricing_proposta_documento_aceite_registrar(text, text, text, text, text) to anon;

create or replace function app.proposta_documento_por_token(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case when pc.id is null then null else jsonb_build_object(
    'storage_path_original', pda.storage_path_original,
    'storage_path_aceite', pda.storage_path_aceite,
    'disponivel_original', pda.storage_path_original is not null,
    'disponivel_aceite', pda.storage_path_aceite is not null
  ) end
  from public.propostas_comerciais pc
  left join public.propostas_documentos_assinados pda on pda.proposta_id = pc.id
  where pc.token_acesso_externo = p_token;
$$;
comment on function app.proposta_documento_por_token(text) is 'Fase 3.11.6 (seção 5): consulta os caminhos já registrados (ou disponivel_*=false, nunca um erro, se ainda não gerado) — usado pelas rotas GET .../document e .../document-aceite.';

create or replace function public.pricing_proposta_documento_por_token(p_token text)
returns jsonb
language sql security definer set search_path = public, pg_temp as $$
  select app.proposta_documento_por_token(p_token);
$$;
grant execute on function public.pricing_proposta_documento_por_token(text) to anon;

-- Leitura por STAFF (authenticated), mesmo padrão de segurança do resto do projeto
-- (RLS já filtra o que authenticated pode ver em propostas_comerciais).
create or replace function app.proposta_documento_por_id(p_proposta_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select case when pda.proposta_id is null then jsonb_build_object('disponivel_original', false, 'disponivel_aceite', false) else jsonb_build_object(
    'storage_path_original', pda.storage_path_original,
    'storage_path_aceite', pda.storage_path_aceite,
    'disponivel_original', pda.storage_path_original is not null,
    'disponivel_aceite', pda.storage_path_aceite is not null
  ) end
  from public.propostas_comerciais pc
  left join public.propostas_documentos_assinados pda on pda.proposta_id = pc.id
  where pc.id = p_proposta_id;
$$;

create or replace function public.pricing_proposta_documento_por_id(p_proposta_id uuid)
returns jsonb
language sql security invoker set search_path = public, pg_temp as $$
  select app.proposta_documento_por_id(p_proposta_id);
$$;
grant execute on function public.pricing_proposta_documento_por_id(uuid) to authenticated;
comment on function public.pricing_proposta_documento_por_id(uuid) is 'Fase 3.11.6: leitura, por STAFF, dos caminhos do documento de aceite da proposta (mesmo shape de pricing_proposta_documento_por_token) — security invoker, RLS de propostas_comerciais/propostas_documentos_assinados já decide o que authenticated pode ver.';
