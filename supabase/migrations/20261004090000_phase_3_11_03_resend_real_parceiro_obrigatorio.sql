-- OptiMon — Fase 3.11.3: CORREÇÃO REAL DO RESEND + OTP + VÍNCULO OBRIGATÓRIO DO PARCEIRO.
--
-- ============================================================================
-- INVESTIGAÇÃO REAL FEITA NESTA FASE (não presumida — seção 25 "REGRA FUNDAMENTAL"):
-- ============================================================================
-- Repositório inteiro varrido (grep de "resend"/"RESEND_API_KEY"/"nodemailer"/"SMTP" em
-- todo api/lib, api/routes, package.json, .env, .env.example, railway.toml, todas as
-- migrations) e também a pasta real do usuário no OneDrive (via bridge) — NENHUM client
-- Resend, NENHUMA RESEND_API_KEY, NENHUMA Edge Function de e-mail existe em código neste
-- projeto, em nenhuma das duas cópias. Perguntado diretamente ao usuário (não presumido):
-- confirmou que o Resend hoje está configurado como SMTP do Supabase Auth (usado só para
-- convite/redefinição de senha de USUÁRIOS do OptiMon via auth.admin.inviteUserByEmail —
-- ver api/routes/users.js) e que RESEND_API_KEY JÁ EXISTE como variável de ambiente na
-- Railway (backend), mas nenhum código deste projeto ainda a lê/usa para OTP.
-- Conclusão real (não "Resend precisa ser integrado" — a pergunta certa, seção 25): o
-- Resend já existe e já está pago/configurado; falta só o client HTTP direto (o SMTP do
-- Supabase Auth não serve para o parceiro externo, que nunca tem linha em auth.users —
-- decisão arquitetural repetida desde a Fase 3.11). Esta migration prepara o lado banco
-- para esse client real (api/lib/emailService.js + otpNotifier.js reescritos nesta
-- mesma fase) — nunca inventa nem move a chave: RESEND_API_KEY/RESEND_FROM_EMAIL
-- continuam só em process.env no Railway, lidos em api/lib/emailService.js.
--
-- ============================================================================
-- PARTE 1 — VÍNCULO OBRIGATÓRIO DO PARCEIRO (seções 10-17)
-- ============================================================================
--
-- Levantamento real (não presumido) rodado nesta fase, ambiente local:
--   select count(*) from propostas_comerciais where parceiro_id is null;  -- 3
--   select count(*) from propostas_comerciais;                            -- 39
--   3 propostas históricas SEM parceiro (RASCUNHO/RECUSADA/ACEITA, criadas 2026-08-31
--   03:04:2x-4x — antes desta correção existir). NÃO apagadas, NÃO alteradas (seção 13:
--   "não alterar dados históricos automaticamente sem regra segura") — documentadas aqui
--   e no relatório final.
--
-- Por isso a coluna permanece NULLABLE (um ALTER COLUMN SET NOT NULL quebraria essas 3
-- linhas reais), mas ganha uma CHECK CONSTRAINT "NOT VALID": em Postgres, NOT VALID
-- pula a varredura de validação das linhas JÁ EXISTENTES no momento do ALTER TABLE, mas
-- passa a valer para TODO INSERT e TODO UPDATE a partir de agora — exatamente o efeito
-- pedido ("se a regra do sistema permitir tornar NOT NULL sem quebrar registros
-- históricos, implementar constraint adequada"): histórico preservado, futuro bloqueado.

alter table public.propostas_comerciais drop constraint if exists propostas_comerciais_parceiro_obrigatorio;
alter table public.propostas_comerciais add constraint propostas_comerciais_parceiro_obrigatorio
  check (parceiro_id is not null) not valid;

comment on constraint propostas_comerciais_parceiro_obrigatorio on public.propostas_comerciais is
  'Fase 3.11.3 (seções 10-13): toda proposta NOVA (INSERT) ou qualquer UPDATE que toque parceiro_id precisa de um parceiro_id não nulo — aplicada com NOT VALID de propósito: não revalida as 3 linhas históricas sem parceiro (RASCUNHO/RECUSADA/ACEITA, criadas antes desta correção) para não alterar dado histórico automaticamente (seção 13), mas bloqueia 100% dos casos novos a partir de agora, em qualquer caminho (função, PostgREST direto, admin). Backend (api/routes/proposals.js) e as funções abaixo dão o erro amigável ANTES de chegar aqui; esta constraint é a rede de segurança final que não confia só no aplicativo (seção 12/25).';

-- ----------------------------------------------------------------------------
-- 1) pricing_proposal_create — único caminho real de criação "do zero" (confirmado por
--    grep: nenhuma outra função app.criar_proposta* existe). Mesma assinatura da versão
--    vigente (20261001090000) — CREATE OR REPLACE simples, sem DROP. Acrescenta só a
--    validação de parceiro (3 exceções com código previsível, que api/routes/
--    proposals.js mapeia para 400 PARTNER_REQUIRED / 404 PARTNER_NOT_FOUND / 400
--    PARTNER_INACTIVE — seção 12) — todo o resto do corpo é idêntico ao já entregue.
-- ----------------------------------------------------------------------------

create or replace function public.pricing_proposal_create(
  p_simulacao_id uuid,
  p_cidade_id uuid default null,
  p_parceiro_id uuid default null,
  p_contrato_id uuid default null,
  p_pricing_version_id uuid default null,
  p_override_request_id uuid default null,
  p_snapshot jsonb default null,
  p_parceiro_nome_capa text default null,
  p_parceiro_cargo_contato text default null,
  p_validade_dias integer default 15
)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_snapshot jsonb;
  v_row public.propostas_comerciais;
  v_floor numeric;
  v_recommended numeric;
  v_preco numeric;
  v_status text;
  v_parceiro public.parceiros;
begin
  if p_simulacao_id is null then
    raise exception 'simulacao_id é obrigatório — proposta sempre nasce de uma simulação salva (seção 29).';
  end if;

  -- Fase 3.11.3 (seções 10/12): parceiro/proponente obrigatório — não confia no
  -- frontend (seção 12 "NÃO CONFIAR NO FRONTEND"). NULL/vazio, inexistente e inativo
  -- são os 3 casos explicitamente exigidos pela seção 10, cada um com código próprio.
  if p_parceiro_id is null then
    raise exception 'PARTNER_REQUIRED: A proposta deve estar vinculada a um parceiro/proponente.';
  end if;

  select * into v_parceiro from public.parceiros where id = p_parceiro_id;
  if v_parceiro.id is null then
    raise exception 'PARTNER_NOT_FOUND: Parceiro % não encontrado.', p_parceiro_id;
  end if;
  if v_parceiro.ativo is not true then
    raise exception 'PARTNER_INACTIVE: Parceiro % está inativo — não é possível criar proposta para um parceiro inativo.', p_parceiro_id;
  end if;

  if p_snapshot is null then
    select resultado into v_snapshot from public.simulacoes where id = p_simulacao_id;
    if v_snapshot is null then
      raise exception 'Simulação % não encontrada ou sem resultado salvo.', p_simulacao_id;
    end if;
  else
    v_snapshot := p_snapshot;
  end if;

  v_floor := nullif(v_snapshot->>'floor', '')::numeric;
  v_recommended := nullif(v_snapshot->>'recommended', '')::numeric;
  v_preco := coalesce(nullif(v_snapshot->>'preco_proposto', '')::numeric, v_recommended);

  if v_recommended is not null and v_preco is not null and v_preco < v_recommended then
    v_status := 'EM_APROVACAO';
  else
    v_status := 'RASCUNHO';
  end if;

  insert into public.propostas_comerciais (
    simulacao_id, cidade_id, parceiro_id, contrato_id, pricing_version_id, override_request_id,
    snapshot, criado_por, status, parceiro_nome_capa, parceiro_cargo_contato, validade_dias
  )
  values (
    p_simulacao_id, p_cidade_id, p_parceiro_id, p_contrato_id, p_pricing_version_id, p_override_request_id,
    v_snapshot, auth.uid(), v_status, p_parceiro_nome_capa, p_parceiro_cargo_contato, coalesce(p_validade_dias, 15)
  )
  returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_row.id, 'PROPOSAL_CREATED',
    'Proposta criada a partir da simulação ' || p_simulacao_id::text,
    null, to_jsonb(v_row));

  return v_row;
end;
$$;
comment on function public.pricing_proposal_create(uuid, uuid, uuid, uuid, uuid, uuid, jsonb, text, text, integer) is 'POST /api/proposals — "GERAR PROPOSTA". Fase 3.11.3 (seções 10-12): parceiro_id agora obrigatório, validado (existe + ativo) — PARTNER_REQUIRED/PARTNER_NOT_FOUND/PARTNER_INACTIVE. Status inicial automático: preço < recomendado → EM_APROVACAO.';

grant execute on function public.pricing_proposal_create(uuid, uuid, uuid, uuid, uuid, uuid, jsonb, text, text, integer) to authenticated;

-- ----------------------------------------------------------------------------
-- 2) app.duplicar_proposta / app.criar_versao_proposta (seção 14 "TODAS AS FORMAS DE
--    CRIAR PROPOSTA" — duplicação e nova versão também são "criação"). Ambas herdam
--    parceiro_id da proposta original — em teoria já não deveria ser nulo (a partir de
--    agora nada novo nasce sem parceiro), mas se a ORIGINAL for uma das 3 linhas
--    históricas sem parceiro, ou se o parceiro foi desativado depois, valida de novo em
--    vez de propagar uma proposta nova já inválida (defesa em profundidade — mesmo
--    espírito da seção 25 aplicada aqui: nunca assumir que "já validou uma vez" é
--    suficiente para sempre). Mesma assinatura das versões vigentes — CREATE OR REPLACE
--    simples.
-- ----------------------------------------------------------------------------

create or replace function app.duplicar_proposta(p_proposta_id uuid, p_motivo text default null)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_orig public.propostas_comerciais;
  v_row public.propostas_comerciais;
  v_parceiro public.parceiros;
begin
  select * into v_orig from public.propostas_comerciais where id = p_proposta_id;
  if v_orig.id is null then
    raise exception 'Proposta % não encontrada.', p_proposta_id;
  end if;

  if v_orig.parceiro_id is null then
    raise exception 'PARTNER_REQUIRED: A proposta original não possui parceiro/proponente vinculado — não é possível duplicar (seção 14). Corrija a proposta de origem primeiro.';
  end if;
  select * into v_parceiro from public.parceiros where id = v_orig.parceiro_id;
  if v_parceiro.id is null then
    raise exception 'PARTNER_NOT_FOUND: Parceiro % (da proposta original) não encontrado.', v_orig.parceiro_id;
  end if;
  if v_parceiro.ativo is not true then
    raise exception 'PARTNER_INACTIVE: Parceiro % (da proposta original) está inativo — não é possível duplicar.', v_orig.parceiro_id;
  end if;

  insert into public.propostas_comerciais (
    simulacao_id, cidade_id, parceiro_id, contrato_id, pricing_version_id, override_request_id,
    snapshot, criado_por, status, parceiro_nome_capa, parceiro_cargo_contato, validade_dias,
    duplicada_de_id, numero_versao
  )
  values (
    v_orig.simulacao_id, v_orig.cidade_id, v_orig.parceiro_id, v_orig.contrato_id,
    v_orig.pricing_version_id, v_orig.override_request_id, v_orig.snapshot, auth.uid(), 'RASCUNHO',
    v_orig.parceiro_nome_capa, v_orig.parceiro_cargo_contato, v_orig.validade_dias,
    v_orig.id, 1
  )
  returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_row.id, 'PROPOSAL_DUPLICATE', p_motivo, null, jsonb_build_object('duplicada_de_id', v_orig.id, 'duplicada_de_numero', v_orig.numero));

  return v_row;
end;
$$;
comment on function app.duplicar_proposta(uuid, text) is 'Fase 2.4 seção 41, endurecida na Fase 3.11.3 (seção 14): revalida que a proposta original tem parceiro ativo antes de duplicar — nunca propaga uma proposta nova sem parceiro.';

create or replace function app.criar_versao_proposta(p_proposta_id uuid, p_motivo text default null)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_orig public.propostas_comerciais;
  v_raiz_id uuid;
  v_raiz_numero text;
  v_proxima_versao integer;
  v_numero text;
  v_row public.propostas_comerciais;
  v_parceiro public.parceiros;
begin
  select * into v_orig from public.propostas_comerciais where id = p_proposta_id;
  if v_orig.id is null then
    raise exception 'Proposta % não encontrada.', p_proposta_id;
  end if;

  if v_orig.parceiro_id is null then
    raise exception 'PARTNER_REQUIRED: A proposta original não possui parceiro/proponente vinculado — não é possível criar nova versão (seção 14). Corrija a proposta de origem primeiro.';
  end if;
  select * into v_parceiro from public.parceiros where id = v_orig.parceiro_id;
  if v_parceiro.id is null then
    raise exception 'PARTNER_NOT_FOUND: Parceiro % (da proposta original) não encontrado.', v_orig.parceiro_id;
  end if;
  if v_parceiro.ativo is not true then
    raise exception 'PARTNER_INACTIVE: Parceiro % (da proposta original) está inativo — não é possível criar nova versão.', v_orig.parceiro_id;
  end if;

  v_raiz_id := coalesce(v_orig.proposta_raiz_id, v_orig.id);
  select numero into v_raiz_numero from public.propostas_comerciais where id = v_raiz_id;
  select coalesce(max(numero_versao), 0) + 1 into v_proxima_versao
    from public.propostas_comerciais where proposta_raiz_id = v_raiz_id;
  v_numero := v_raiz_numero || '-V' || v_proxima_versao;

  insert into public.propostas_comerciais (
    numero, simulacao_id, cidade_id, parceiro_id, contrato_id, pricing_version_id, override_request_id,
    snapshot, criado_por, status, parceiro_nome_capa, parceiro_cargo_contato, validade_dias,
    proposta_raiz_id, numero_versao
  )
  values (
    v_numero, v_orig.simulacao_id, v_orig.cidade_id, v_orig.parceiro_id, v_orig.contrato_id,
    v_orig.pricing_version_id, v_orig.override_request_id, v_orig.snapshot, auth.uid(), 'RASCUNHO',
    v_orig.parceiro_nome_capa, v_orig.parceiro_cargo_contato, v_orig.validade_dias,
    v_raiz_id, v_proxima_versao
  )
  returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_row.id, 'PROPOSAL_VERSION_CREATE', p_motivo, null, jsonb_build_object('versao_anterior_id', v_orig.id, 'numero_versao', v_proxima_versao));

  return v_row;
end;
$$;
comment on function app.criar_versao_proposta(uuid, text) is 'Fase 2.4 seção 40, endurecida na Fase 3.11.3 (seção 14): revalida que a proposta original tem parceiro ativo antes de criar nova versão.';

-- ----------------------------------------------------------------------------
-- 3) Trigger: impede TROCA de parceiro depois que a proposta sai de RASCUNHO (seção 16).
--    Hoje NENHUMA rota da API permite editar parceiro_id (confirmado por leitura de
--    api/routes/proposals.js: o único PATCH existente só edita parceiro_nome_capa/
--    parceiro_cargo_contato/observacoes_comerciais/proximos_passos) — mas a seção 12 é
--    explícita ("não confiar somente na interface"), então este trigger é a rede de
--    segurança no NÍVEL DO BANCO: bloqueia qualquer UPDATE que mude parceiro_id fora de
--    RASCUNHO, mesmo vindo de uma rota futura, de PostgREST direto, ou de acesso
--    administrativo — cobre com folga os estados citados na seção 16 (APROVADA/ENVIADA_
--    AO_PARCEIRO/VISUALIZADA_PELO_PARCEIRO/ACEITA_PELO_PARCEIRO/CONTRATO_GERADO/ASSINADA)
--    porque bloqueia a partir de QUALQUER status que não seja RASCUNHO.
-- ----------------------------------------------------------------------------

create or replace function app.impedir_troca_parceiro_proposta()
returns trigger
language plpgsql
as $$
begin
  if new.parceiro_id is distinct from old.parceiro_id and old.status <> 'RASCUNHO' then
    raise exception 'PARTNER_LOCKED: não é possível alterar o parceiro/proponente de uma proposta que já saiu de RASCUNHO (status atual: %) — seção 16. Gere uma nova versão/duplicata se precisar mudar o parceiro.', old.status;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_impedir_troca_parceiro_proposta on public.propostas_comerciais;
create trigger trg_impedir_troca_parceiro_proposta
  before update on public.propostas_comerciais
  for each row execute function app.impedir_troca_parceiro_proposta();

comment on function app.impedir_troca_parceiro_proposta() is 'Fase 3.11.3 (seção 16): bloqueia troca de parceiro_id fora de RASCUNHO — inclui, sem se limitar a, ACEITA_PELO_PARCEIRO/CONTRATO_GERADO/ASSINADA (os 3 estados citados como "totalmente bloqueado" na seção 16).';

-- ============================================================================
-- PARTE 2 — RESEND REAL + RASTREIO DE ENTREGA DO E-MAIL DE OTP (seções 5-9, 20)
-- ============================================================================
--
-- Fase 3.11.2 já criou propostas_aceite_tentativas com o hash do OTP e o status de
-- CONFIRMAÇÃO (AGUARDANDO_OTP/CONFIRMADO/EXPIRADO/CANCELADO). Esta fase acrescenta um
-- rastreio SEPARADO — email_status — para o ciclo de vida do E-MAIL em si (seção 8: "não
-- considerar OTP criado = e-mail enviado, nem Resend respondeu 200 = e-mail recebido").
-- As 2 colunas nunca se confundem: email_status nunca é alterado só porque um envio foi
-- solicitado (seção 9, "não alterar status do OTP só porque o envio foi solicitado" — e
-- aqui é ainda mais estrito: nem a coluna de EMAIL é avançada para ACEITO/ENTREGUE sem
-- confirmação real do provedor).

alter table public.propostas_aceite_tentativas
  add column if not exists email_status text not null default 'OTP_GERADO',
  add column if not exists email_provider_id text,
  add column if not exists email_canal text,
  add column if not exists email_status_atualizado_em timestamptz,
  add column if not exists email_ultimo_erro text;

alter table public.propostas_aceite_tentativas drop constraint if exists propostas_aceite_tentativas_email_status_check;
alter table public.propostas_aceite_tentativas add constraint propostas_aceite_tentativas_email_status_check
  check (email_status = any (array[
    'OTP_GERADO', 'EMAIL_SOLICITADO', 'EMAIL_ACEITO_PELO_RESEND', 'EMAIL_ENTREGUE',
    'EMAIL_FALHOU', 'EMAIL_REJEITADO'
  ]));

create index if not exists propostas_aceite_tentativas_email_provider_id_idx
  on public.propostas_aceite_tentativas(email_provider_id) where email_provider_id is not null;

comment on column public.propostas_aceite_tentativas.email_status is 'Fase 3.11.3 (seção 8): estado real de ENTREGA do e-mail — nunca confundir com a coluna "status" (que é o ciclo de vida do CÓDIGO: AGUARDANDO_OTP/CONFIRMADO/EXPIRADO/CANCELADO). OTP_GERADO (default, no INSERT) → EMAIL_SOLICITADO (Node está chamando o Resend) → EMAIL_ACEITO_PELO_RESEND (Resend devolveu 200 + email_id) → EMAIL_ENTREGUE (webhook "delivered" real, quando o Resend manda). EMAIL_FALHOU/EMAIL_REJEITADO são estados terminais de erro (falha no envio / bounce / complaint via webhook).';
comment on column public.propostas_aceite_tentativas.email_provider_id is 'Fase 3.11.3: o "email_id" devolvido pela Resend (nunca o conteúdo do e-mail, nunca o OTP) — usado para casar eventos do webhook (seção 9) com esta tentativa.';
comment on column public.propostas_aceite_tentativas.email_canal is 'Fase 3.11.3: "RESEND" (envio real) ou "DEV_LOG" (fallback só em ambiente não-produção, sem RESEND_API_KEY — ver api/lib/otpNotifier.js) — nunca DEV_LOG em produção (checado em Node).';

-- ----------------------------------------------------------------------------
-- 4) Auditoria: acrescenta as ações de e-mail nas 2 whitelists existentes (a do CHECK da
--    tabela public.auditoria e a validação amigável dentro de app.registrar_auditoria_
--    semantica, 8-arg — mesma versão usada por todo o fluxo externo do parceiro).
-- ----------------------------------------------------------------------------

alter table public.auditoria drop constraint if exists auditoria_acao_check;
alter table public.auditoria add constraint auditoria_acao_check check (acao = any (array[
  'INSERT','UPDATE','DELETE','LOGIN','ARCHIVE','RESTORE','BLOCKED_ARCHIVE','BLOCKED_DELETE',
  'PROPOSAL_APPROVE','PROPOSAL_REJECT','PROPOSAL_STATUS_CHANGE','PROPOSAL_VERSION_CREATE',
  'PROPOSAL_DUPLICATE','PROPOSAL_EXPORT',
  'SIGNATURE_ENVELOPE_CREATE','SIGNATURE_ENVELOPE_SEND','SIGNATURE_ENVELOPE_CANCEL',
  'SIGNATURE_EVENT_RECEIVED','SIGNATURE_VALIDATED','SIGNATURE_TEST_CONNECTION',
  'SIGNATURE_SIGNER_RESEND',
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
  -- Fase 3.11.3 (seções 8-9/20):
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

-- ----------------------------------------------------------------------------
-- 5) app.iniciar_aceite_proposta_parceiro — CREATE OR REPLACE (mesma assinatura, sem
--    DROP): passa a devolver também numero/parceiro_nome, para o Node montar o e-mail
--    real (seção 7: [NÚMERO] e [PROPONENTE]) sem precisar de uma 2ª consulta e sem
--    hardcodar/inventar nada (o nome vem de parceiro_nome_capa quando preenchido —
--    mesmo campo que já aparece na capa da proposta — com fallback para
--    razao_social/nome_fantasia do parceiro cadastrado).
-- ----------------------------------------------------------------------------

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
  v_parceiro_nome text;
begin
  if p_nome is null or trim(p_nome) = '' then raise exception 'DADOS_OBRIGATORIOS: nome completo do representante é obrigatório.'; end if;
  if p_documento is null or trim(p_documento) = '' then raise exception 'DADOS_OBRIGATORIOS: CPF do representante é obrigatório.'; end if;
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

  update public.propostas_aceite_tentativas
     set status = 'CANCELADO'
   where proposta_id = v_prop.id and status = 'AGUARDANDO_OTP';

  v_expira := now() + make_interval(mins => greatest(coalesce(p_otp_ttl_minutos, 10), 1));

  insert into public.propostas_aceite_tentativas
    (proposta_id, token_hash, nome, documento, cargo, email, telefone, declaracao_aceita, confirmacao_aceita,
     otp_hash, otp_expira_em, ip, user_agent)
  values
    (v_prop.id, md5(p_token), trim(p_nome), trim(p_documento), nullif(trim(coalesce(p_cargo, '')), ''), trim(lower(p_email)),
     nullif(trim(coalesce(p_telefone, '')), ''), true, true, p_otp_hash, v_expira, p_ip, p_user_agent)
  returning id into v_tentativa_id;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_prop.id, 'PROPOSAL_ACCEPT_OTP_REQUESTED',
    'Código de confirmação solicitado para efetivar o aceite formal.', null,
    jsonb_build_object('tentativa_id', v_tentativa_id, 'nome', trim(p_nome), 'email', trim(lower(p_email)), 'user_agent', p_user_agent),
    'parceiro_externo', p_ip);

  -- Fase 3.11.3 (seção 7): nome do proponente para o template do e-mail — mesmo dado já
  -- exibido na capa da proposta, nunca inventado.
  select coalesce(v_prop.parceiro_nome_capa, nullif(trim(coalesce(pa.nome_fantasia, pa.razao_social, '')), ''))
    into v_parceiro_nome
    from public.parceiros pa where pa.id = v_prop.parceiro_id;

  return jsonb_build_object(
    'tentativa_id', v_tentativa_id, 'expira_em', v_expira,
    'numero', v_prop.numero, 'parceiro_nome', v_parceiro_nome
  );
end;
$$;

comment on function app.iniciar_aceite_proposta_parceiro(text, text, text, text, text, text, boolean, boolean, text, integer, text, text) is 'Fase 3.11.2 (seção 1, itens 1-9), estendida na Fase 3.11.3 (seção 7): passo 1 do aceite — além de tentativa_id/expira_em, agora também devolve numero/parceiro_nome (para o template real do e-mail de OTP). Nunca muda propostas_comerciais.status.';

-- ----------------------------------------------------------------------------
-- 6) Rastreio de status do E-MAIL — 2 RPCs SECURITY DEFINER (mesmo padrão de
--    propostas_aceite_tentativas: RLS habilitado sem nenhuma policy, só estas funções
--    escrevem). Uma por tentativa_id (usada pelo Node logo após chamar/receber resposta
--    do Resend em /accept/iniciar) e uma por email_provider_id (usada pelo webhook do
--    Resend — seção 9 — que só conhece o "email_id", nunca o tentativa_id). Mesmo padrão
--    já usado para o webhook de assinatura (pricing_signature_webhook_event_by_provider_id).
--    NUNCA toca propostas_aceite_tentativas.status (o ciclo do CÓDIGO) nem
--    propostas_comerciais.status — só email_status/email_provider_id/email_canal
--    (seção 9: "não alterar status do OTP só porque o envio foi solicitado").
-- ----------------------------------------------------------------------------

create or replace function app.registrar_status_email_aceite(
  p_tentativa_id uuid,
  p_email_status text,
  p_email_provider_id text default null,
  p_email_canal text default null,
  p_detalhe text default null,
  p_ip text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tent public.propostas_aceite_tentativas;
  v_acao text;
begin
  if p_email_status not in ('EMAIL_SOLICITADO', 'EMAIL_ACEITO_PELO_RESEND', 'EMAIL_ENTREGUE', 'EMAIL_FALHOU', 'EMAIL_REJEITADO') then
    raise exception 'EMAIL_STATUS_INVALIDO: % não é um status de e-mail válido.', p_email_status;
  end if;

  select * into v_tent from public.propostas_aceite_tentativas where id = p_tentativa_id for update;
  if v_tent.id is null then
    raise exception 'TENTATIVA_INVALIDA: nenhuma tentativa de aceite encontrada para tentativa_id %.', p_tentativa_id;
  end if;

  update public.propostas_aceite_tentativas
     set email_status = p_email_status,
         email_provider_id = coalesce(p_email_provider_id, email_provider_id),
         email_canal = coalesce(p_email_canal, email_canal),
         email_status_atualizado_em = now(),
         email_ultimo_erro = case when p_email_status in ('EMAIL_FALHOU', 'EMAIL_REJEITADO') then p_detalhe else email_ultimo_erro end
   where id = p_tentativa_id;

  v_acao := case p_email_status
    when 'EMAIL_SOLICITADO' then 'PROPOSAL_ACCEPT_EMAIL_REQUESTED'
    when 'EMAIL_ACEITO_PELO_RESEND' then 'PROPOSAL_ACCEPT_EMAIL_ACCEPTED_BY_PROVIDER'
    when 'EMAIL_ENTREGUE' then 'PROPOSAL_ACCEPT_EMAIL_DELIVERED'
    when 'EMAIL_FALHOU' then 'PROPOSAL_ACCEPT_EMAIL_FAILED'
    when 'EMAIL_REJEITADO' then 'PROPOSAL_ACCEPT_EMAIL_BOUNCED'
  end;

  -- Nunca registra o OTP nem o conteúdo do e-mail (seção 20) — só email_id (mascarado
  -- não é necessário, não é PII) e o status.
  perform app.registrar_auditoria_semantica('propostas_comerciais', v_tent.proposta_id, v_acao,
    p_detalhe, null,
    jsonb_build_object('tentativa_id', p_tentativa_id, 'email_status', p_email_status, 'email_provider_id', coalesce(p_email_provider_id, v_tent.email_provider_id)),
    'sistema', p_ip);

  return jsonb_build_object('tentativa_id', p_tentativa_id, 'email_status', p_email_status);
end;
$$;
comment on function app.registrar_status_email_aceite(uuid, text, text, text, text, text) is 'Fase 3.11.3 (seção 8-9): grava o estado real de entrega do e-mail de OTP (nunca o OTP em si) e o evento de auditoria correspondente. Chamada pelo Node logo após solicitar/receber resposta do Resend em /accept/iniciar.';

-- security DEFINER (não invoker): esta função é chamada pelo Node como `anon` (mesmo
-- padrão de public.pricing_proposal_external_accept_iniciar acima) — `anon` não tem
-- USAGE no schema `app`, então uma função SQL "invoker" simples seria inlinada e
-- executada com os privilégios do próprio `anon`, batendo em "permission denied for
-- schema app" (erro real encontrado e corrigido nesta mesma fase, ao testar de verdade
-- em vez de assumir que funcionaria).
create or replace function public.pricing_proposal_accept_email_status(
  p_tentativa_id uuid, p_email_status text, p_email_provider_id text default null,
  p_email_canal text default null, p_detalhe text default null, p_ip text default null
)
returns jsonb
language sql security definer set search_path = public, pg_temp as $$
  select app.registrar_status_email_aceite(p_tentativa_id, p_email_status, p_email_provider_id, p_email_canal, p_detalhe, p_ip);
$$;
grant execute on function public.pricing_proposal_accept_email_status(uuid, text, text, text, text, text) to anon;

create or replace function app.registrar_status_email_aceite_por_provider_id(
  p_email_provider_id text,
  p_email_status text,
  p_detalhe text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tent public.propostas_aceite_tentativas;
begin
  select * into v_tent from public.propostas_aceite_tentativas where email_provider_id = p_email_provider_id
   order by criado_em desc limit 1;
  if v_tent.id is null then
    raise exception 'TENTATIVA_INVALIDA: nenhuma tentativa encontrada para email_provider_id %.', p_email_provider_id;
  end if;
  return app.registrar_status_email_aceite(v_tent.id, p_email_status, p_email_provider_id, null, p_detalhe, null);
end;
$$;
comment on function app.registrar_status_email_aceite_por_provider_id(text, text, text) is 'Fase 3.11.3 (seção 9): usada pelo webhook do Resend (POST /api/webhooks/resend), que só conhece o email_id — mesmo padrão de app.registrar_evento_assinatura_webhook/pricing_signature_webhook_event_by_provider_id.';

create or replace function public.pricing_proposal_accept_email_status_por_provider_id(
  p_email_provider_id text, p_email_status text, p_detalhe text default null
)
returns jsonb
language sql security definer set search_path = public, pg_temp as $$
  select app.registrar_status_email_aceite_por_provider_id(p_email_provider_id, p_email_status, p_detalhe);
$$;
grant execute on function public.pricing_proposal_accept_email_status_por_provider_id(text, text, text) to anon;

-- Fim da Fase 3.11.3 (parte SQL) — restante (client Resend real, template do e-mail,
-- webhook Express, campo obrigatório no frontend, backend não confiando no frontend,
-- testes) em api/lib/emailService.js, api/lib/otpNotifier.js, api/routes/
-- proposalsExternal.js, api/routes/proposals.js, api/routes/emailWebhooks.js,
-- web/src/pages/NewSimulation.jsx e tests/run_tests_fase311.sh.
