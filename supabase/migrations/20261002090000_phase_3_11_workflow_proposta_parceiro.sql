-- OptiMon — Fase 3.11: fechamento REAL do workflow Proposta → Aprovação NICK → Envio →
-- Aceite do Parceiro → Contrato → Assinatura → Ativação.
--
-- ============================================================================
-- AUDITORIA DA IMPLEMENTAÇÃO ATUAL (seção 2 do prompt) — lida diretamente no código antes
-- de escrever esta migration, não presumida. Resumo (relatório final tem a versão completa):
--
-- Banco: propostas_comerciais.status já tem 12 valores (RASCUNHO..CONTRATO_GERADO,
--   migration 20260913090200). app.aprovar_proposta/app.rejeitar_proposta (migration
--   20260909090100) JÁ são, de fato, "aprovação interna da NICK" (exigem DIRETOR/
--   ADMINISTRADOR) — só não têm esse nome explícito na UI. PARTIAL.
-- API: app.mudar_status_proposta aceita p_novo_status='ACEITA' vindo de QUALQUER usuário
--   interno autorizado (DIRETOR/ADMINISTRADOR, ou dono em RASCUNHO — mas RASCUNHO nem
--   aceita esse valor por regra de negócio) — ou seja, um operador da NICK consegue, hoje,
--   marcar uma proposta como "aceita" sem o parceiro ter feito nada. Confirma o problema
--   central relatado pelo usuário. Não existe NENHUMA rota pública/anônima: server.js
--   aplica `requireAuth` em `/api/proposals` inteiro (só `/api/signatures/webhook` é
--   isento). O toggle "Externa (parceiro)" do ProposalDetail.jsx é só um MODO DE
--   VISUALIZAÇÃO para um usuário já autenticado da NICK — nunca algo que o parceiro real
--   (sem login no OptiMon) consegue abrir. FAIL — é exatamente o "problema fundamental"
--   descrito no prompt.
-- Frontend: botão "Aprovar"/"Rejeitar" existe (ProposalDetail.jsx:216-219) mas sem rótulo
--   "interna" e sem nenhuma etapa de envio depois. "CRIAR CONTRATO" (Fase 3.10) já é
--   visível e funcional, mas o gate atual (status=ASSINADA) usa a ASSINATURA ELETRÔNICA DO
--   DOCUMENTO DA PROPOSTA (Fase 2.5) como proxy de "o parceiro concordou" — o que o
--   prompt desta fase explicitamente corrige: aceite comercial ≠ assinatura (seção 10).
--   FAIL para "aceite formal" como conceito próprio; PARTIAL para "Criar Contrato" (o
--   botão existe e funciona, mas está condicionado ao gate errado).
-- Workflow: não existe estado ENVIADA_AO_PARCEIRO/VISUALIZADA_PELO_PARCEIRO/
--   ACEITA_PELO_PARCEIRO/RECUSADA_PELO_PARCEIRO — o "ENVIADA"/"ACEITA" atuais são só
--   rótulos de status genéricos, sem token, sem link, sem qualquer interação real do
--   parceiro. FAIL.
-- Auditoria: app.registrar_auditoria_semantica e a arquitetura de auditoria (imutável,
--   INSERT-only, captura IP/usuário/origem) já são sólidas e SERÃO REAPROVEITADAS
--   integralmente — só precisam de ações novas (PROPOSAL_SENT/VIEWED/ACCEPTED/DECLINED).
--   PASS (arquitetura), PARTIAL (cobertura de eventos, até esta migration).
--
-- Já existe e é reaproveitado SEM alteração nesta fase: signature_envelopes já suporta
-- tipo_documento='CONTRATO' (signatures.js, contracts.js linha ~58) — a infraestrutura de
-- assinatura do CONTRATO (distinta da proposta) já existe desde a Fase 2.5; só faltava
-- (a) o PDF do contrato não gerar automaticamente ao criar o envelope (ficou pendente
-- desde a Fase 2.5 porque o motor de PDF de contrato só foi construído na Fase 3.9/3.10 —
-- corrigido em api/routes/signatures.js nesta fase) e (b) uma seção "Assinatura
-- eletrônica" visível na tela do contrato (ContractDetail.jsx — corrigido nesta fase).
-- ============================================================================


-- ============================================================================
-- 1) Novas colunas em propostas_comerciais — token de acesso externo, rastreamento de
--    envio/visualização, e aceite/recusa formal do parceiro. Tudo nullable/aditivo —
--    nenhuma linha existente é afetada.
-- ============================================================================

alter table public.propostas_comerciais
  add column if not exists token_acesso_externo text unique,
  add column if not exists token_expira_em timestamptz,
  add column if not exists enviado_ao_parceiro_em timestamptz,
  add column if not exists enviado_ao_parceiro_por uuid references public.usuarios(id),
  add column if not exists primeira_visualizacao_em timestamptz,
  add column if not exists ultima_visualizacao_em timestamptz,
  add column if not exists visualizacoes_count integer not null default 0,
  add column if not exists aceite_nome text,
  add column if not exists aceite_documento text,
  add column if not exists aceite_cargo text,
  add column if not exists aceite_email text,
  add column if not exists aceite_telefone text,
  add column if not exists aceite_em timestamptz,
  add column if not exists aceite_ip inet,
  add column if not exists recusa_motivo text,
  add column if not exists recusa_em timestamptz;

comment on column public.propostas_comerciais.token_acesso_externo is 'Fase 3.11: token opaco (32 bytes hex) que dá acesso à área externa do parceiro (sem login OptiMon) — só existe depois de app.enviar_proposta_parceiro. Nunca reaproveitado entre propostas (unique).';
comment on column public.propostas_comerciais.aceite_nome is 'Fase 3.11 (seção 8-9): identificação de quem formalizou o aceite pelo lado do parceiro — sempre preenchido pelo BACKEND a partir do formulário de aceite da área externa, nunca por um usuário interno.';

-- ============================================================================
-- 2) Status: 4 valores novos, ADITIVOS — os 12 valores existentes (RASCUNHO..
--    CONTRATO_GERADO) continuam válidos e nenhuma linha existente muda de valor.
-- ============================================================================

alter table public.propostas_comerciais drop constraint if exists propostas_comerciais_status_check;
alter table public.propostas_comerciais add constraint propostas_comerciais_status_check
  check (status = any (array[
    'RASCUNHO', 'EM_APROVACAO', 'APROVADA', 'ENVIADA', 'EM_NEGOCIACAO',
    'ACEITA', 'RECUSADA', 'EXPIRADA', 'CANCELADA',
    'EM_ASSINATURA', 'ASSINADA', 'CONTRATO_GERADO',
    -- Fase 3.11 — workflow real de envio/aceite pelo parceiro:
    'ENVIADA_AO_PARCEIRO', 'VISUALIZADA_PELO_PARCEIRO',
    'ACEITA_PELO_PARCEIRO', 'RECUSADA_PELO_PARCEIRO'
  ]));

-- ============================================================================
-- 3) Auditoria: 4 ações novas, aditivas (mesmo padrão da Fase 3.10 — CHECK da tabela +
--    guarda interna de app.registrar_auditoria_semantica precisam ficar em sincronia).
--    Também acrescenta p_origem opcional (default 'app') para diferenciar eventos
--    disparados pelo parceiro externo (auth.uid() sempre null nesse caso — a identidade
--    declarada vai em valor_novo, nunca inventada) dos eventos internos.
-- ============================================================================

alter table public.auditoria drop constraint auditoria_acao_check;
alter table public.auditoria add constraint auditoria_acao_check check (acao = any (array[
  'INSERT','UPDATE','DELETE','LOGIN','ARCHIVE','RESTORE','BLOCKED_ARCHIVE','BLOCKED_DELETE',
  'PROPOSAL_APPROVE','PROPOSAL_REJECT','PROPOSAL_STATUS_CHANGE','PROPOSAL_VERSION_CREATE',
  'PROPOSAL_DUPLICATE','PROPOSAL_EXPORT',
  'SIGNATURE_ENVELOPE_CREATE','SIGNATURE_ENVELOPE_SEND','SIGNATURE_ENVELOPE_CANCEL',
  'SIGNATURE_EVENT_RECEIVED','SIGNATURE_VALIDATED','SIGNATURE_TEST_CONNECTION',
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
  -- Fase 3.11 (seção 22):
  'PROPOSAL_SENT_TO_PARTNER','PROPOSAL_VIEWED_BY_PARTNER',
  'PROPOSAL_ACCEPTED_BY_PARTNER','PROPOSAL_DECLINED_BY_PARTNER'
]));

-- A assinatura antiga (6 parâmetros, sem p_origem) precisa ser DROPADA explicitamente:
-- acrescentar um 7º parâmetro com DEFAULT cria uma SOBRECARGA nova (mesmo nome, lista de
-- tipos diferente) em vez de substituir a função existente — com as duas no catálogo, toda
-- chamada com exatamente 6 argumentos posicionais (todo o código já existente) fica
-- AMBÍGUA (Postgres não sabe se o 7º arg de default entra ou não). Isso quebrou de verdade
-- ao testar app.aprovar_proposta logo após aplicar esta migration a primeira vez —
-- corrigido aqui antes de prosseguir (achado real, não hipotético).
drop function if exists app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb);

create or replace function app.registrar_auditoria_semantica(
  p_entidade text, p_entidade_id uuid, p_acao text, p_motivo text default null,
  p_valor_anterior jsonb default null, p_valor_novo jsonb default null,
  p_origem text default 'app'
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
    'USER_AUTH_ROLLBACK', 'USER_AUTH_ORPHAN', 'USER_PROFILE_RECONCILED',
    'CONTRACT_MINUTA_EXPORT', 'CONTRACT_RULES_UPDATE', 'CONTRACT_RESERVED_CLIENT_ADD', 'CONTRACT_RESERVED_CLIENT_UPDATE',
    'USER_HARD_DELETE',
    'PON_ADDED', 'PON_REMOVED', 'POP_ADDED', 'POP_REMOVED', 'CLIENT_RESERVED_REMOVED',
    'CONTRACT_TERMINATED', 'THIRD_PARTY_INFRA_REQUEST', 'THIRD_PARTY_INFRA_APPROVED',
    'OWN_NETWORK_EXCEPTION_REQUEST', 'OWN_NETWORK_EXCEPTION',
    'PROPOSAL_CREATED', 'PROPOSAL_UPDATED', 'CONTRACT_MINUTA_GENERATED',
    'PROPOSAL_SENT_TO_PARTNER', 'PROPOSAL_VIEWED_BY_PARTNER',
    'PROPOSAL_ACCEPTED_BY_PARTNER', 'PROPOSAL_DECLINED_BY_PARTNER'
  ) then
    raise exception 'app.registrar_auditoria_semantica: ação inválida %.', p_acao;
  end if;

  begin
    v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', '')::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.auditoria (usuario_id, ip, acao, entidade, entidade_id, valor_anterior, valor_novo, origem, motivo)
  values (auth.uid(), v_ip, p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, p_origem, p_motivo);
end;
$function$;

comment on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb, text) is 'Fase 2.3.1, ampliada nas Fases 3.8/3.10/3.11. Fase 3.11 acrescenta p_origem (default ''app'') para marcar eventos disparados pela área externa do parceiro (auth.uid() sempre null nesses casos — a identidade declarada vai em valor_novo) e 4 ações novas (PROPOSAL_SENT_TO_PARTNER/VIEWED_BY_PARTNER/ACCEPTED_BY_PARTNER/DECLINED_BY_PARTNER).';

grant execute on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb, text) to authenticated, anon;

-- ============================================================================
-- 4) app.enviar_proposta_parceiro — seção 5: "ENVIAR AO PARCEIRO". SECURITY DEFINER
--    (mesmo motivo documentado em app.gerar_contrato_de_proposta: COMERCIAL precisa
--    conseguir fazer essa transição mesmo com a proposta fora de RASCUNHO, e a RLS de
--    update só libera isso para DIRETOR/ADMINISTRADOR — checagem de perfil explícita
--    dentro da função substitui a RLS aqui, mesmo padrão já testado). Gera um token
--    opaco de 32 bytes (64 hex chars) — não é um JWT, não carrega claim nenhuma, só
--    identifica a proposta; toda validação de estado acontece no servidor a cada
--    chamada (nunca confia em nada que o token "diga" além de qual proposta é).
-- ============================================================================

create or replace function app.enviar_proposta_parceiro(p_proposta_id uuid)
returns public.propostas_comerciais
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_orig public.propostas_comerciais;
  v_row public.propostas_comerciais;
  v_token text;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode enviar proposta ao parceiro — só COMERCIAL/DIRETOR/ADMINISTRADOR.', app.perfil_atual();
  end if;

  select * into v_orig from public.propostas_comerciais where id = p_proposta_id;
  if v_orig.id is null then
    raise exception 'NAO_ENCONTRADA: proposta % não encontrada.', p_proposta_id;
  end if;

  if v_orig.status not in ('APROVADA', 'ENVIADA_AO_PARCEIRO', 'VISUALIZADA_PELO_PARCEIRO') then
    raise exception 'STATUS_INVALIDO: só é possível enviar ao parceiro uma proposta APROVADA internamente (ou reenviar uma já enviada/visualizada) — status atual: %.', v_orig.status;
  end if;

  if v_orig.parceiro_id is null then
    raise exception 'DADOS_INCOMPLETOS: proposta sem parceiro_id vinculado — não é possível enviar.';
  end if;

  v_token := encode(gen_random_bytes(32), 'hex');

  update public.propostas_comerciais
     set status = 'ENVIADA_AO_PARCEIRO',
         token_acesso_externo = v_token,
         token_expira_em = now() + make_interval(days => greatest(coalesce(v_orig.validade_dias, 15), 1)),
         enviado_ao_parceiro_em = now(),
         enviado_ao_parceiro_por = auth.uid()
   where id = p_proposta_id
   returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', p_proposta_id, 'PROPOSAL_SENT_TO_PARTNER',
    null, jsonb_build_object('status', v_orig.status), jsonb_build_object('status', 'ENVIADA_AO_PARCEIRO', 'token_expira_em', v_row.token_expira_em));

  return v_row;
end;
$$;
comment on function app.enviar_proposta_parceiro(uuid) is 'Fase 3.11 (seção 5): gera token de acesso externo e move a proposta para ENVIADA_AO_PARCEIRO. Reenvio (mesmo status já enviado/visualizado) gera um token NOVO — o antigo para de funcionar.';

grant execute on function app.enviar_proposta_parceiro(uuid) to authenticated;

create or replace function public.pricing_proposal_send_to_partner(p_proposta_id uuid)
returns public.propostas_comerciais
language sql security invoker as $$ select app.enviar_proposta_parceiro(p_proposta_id); $$;
grant execute on function public.pricing_proposal_send_to_partner(uuid) to authenticated;

-- ============================================================================
-- 5) Área externa: 3 funções chamadas SEM JWT de usuário (grant to anon), a exemplo do
--    padrão já usado pelo webhook de assinatura (app.registrar_evento_assinatura_webhook,
--    Fase 2.5) — o token é a própria autenticação, validado a cada chamada; nunca confia
--    em nada vindo do cliente além do token. SECURITY DEFINER, search_path travado.
-- ============================================================================

-- 5a) Buscar a proposta pelo token (GET da área externa) + registrar visualização real.
create or replace function app.proposta_externa_por_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prop public.propostas_comerciais;
  v_ip inet;
  v_result jsonb;
begin
  if p_token is null or trim(p_token) = '' then
    raise exception 'TOKEN_INVALIDO: token de acesso é obrigatório.';
  end if;

  select * into v_prop from public.propostas_comerciais where token_acesso_externo = p_token;
  if v_prop.id is null then
    raise exception 'TOKEN_INVALIDO: link inválido ou expirado.';
  end if;
  if v_prop.token_expira_em is not null and v_prop.token_expira_em < now() then
    raise exception 'TOKEN_EXPIRADO: este link expirou em % — solicite um novo envio ao consultor comercial.', to_char(v_prop.token_expira_em, 'DD/MM/YYYY HH24:MI');
  end if;
  if v_prop.status = 'CANCELADA' then
    raise exception 'PROPOSTA_CANCELADA: esta proposta foi cancelada.';
  end if;

  begin
    v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', '')::inet;
  exception when others then
    v_ip := null;
  end;

  -- Idempotente na transição de status (só sai de ENVIADA_AO_PARCEIRO -> VISUALIZADA_PELO_PARCEIRO
  -- uma vez — visualizações seguintes não "voltam" o status), mas o CONTADOR e o evento de
  -- auditoria são registrados em TODA visualização (seção 7: "não alterar isso apenas
  -- visualmente" — cada abertura real vira uma linha na trilha).
  update public.propostas_comerciais
     set status = case when status = 'ENVIADA_AO_PARCEIRO' then 'VISUALIZADA_PELO_PARCEIRO' else status end,
         primeira_visualizacao_em = coalesce(primeira_visualizacao_em, now()),
         ultima_visualizacao_em = now(),
         visualizacoes_count = visualizacoes_count + 1
   where id = v_prop.id
   returning * into v_prop;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_prop.id, 'PROPOSAL_VIEWED_BY_PARTNER',
    null, null, jsonb_build_object('ip', v_ip::text, 'visualizacoes_count', v_prop.visualizacoes_count), 'parceiro_externo');

  -- Mesmo whitelist de campos não sensíveis já usado por pricing_proposal_external_view
  -- (Fase 2.4/3.10) — nunca piso/abertura/desconto/governança/autorização/custo interno.
  select jsonb_build_object(
    'id', p.id, 'numero', p.numero, 'status', p.status, 'numero_versao', p.numero_versao,
    'cidade_nome', ci.nome, 'cidade_uf', ci.uf,
    'pop_nome', (select nome from public.infra_pops where id = (p.snapshot->>'pop_id')::uuid),
    'parceiro_nome_capa', coalesce(p.parceiro_nome_capa, pa.nome_fantasia, pa.razao_social),
    'parceiro_cargo_contato', p.parceiro_cargo_contato,
    'validade_dias', p.validade_dias, 'criado_em', p.criado_em,
    'prazo_meses', coalesce(nullif(p.snapshot->>'prazo_meses',''), '48')::int,
    -- Fase 3.11 (bug real encontrado na verificação visual): ->>' sempre devolve TEXT —
    -- sem o ::numeric, o frontend recebia "2570.00" como STRING no JSON, e
    -- formatCurrencyFull (v.toLocaleString('pt-BR', {style:'currency',...})) não formata
    -- nada quando v já é string (String.prototype.toLocaleString ignora as opções) —
    -- os cards de "Mensalidade proposta"/"Faturamento" apareciam sem "R$"/separadores.
    'clientes', nullif(p.snapshot->>'clientes','')::numeric, 'arpu', nullif(p.snapshot->>'arpu','')::numeric,
    'faturamento', nullif(p.snapshot->>'faturamento','')::numeric, 'pons_count', nullif(p.snapshot->>'pons_count','')::numeric,
    'revenue_share_pct', nullif(p.snapshot->>'revenue_share_pct','')::numeric,
    'preco_proposto', nullif(p.snapshot->>'preco_proposto','')::numeric,
    'observacoes_comerciais', p.observacoes_comerciais, 'proximos_passos', p.proximos_passos,
    'ja_aceita', p.status = 'ACEITA_PELO_PARCEIRO', 'ja_recusada', p.status = 'RECUSADA_PELO_PARCEIRO',
    'aceite_em', p.aceite_em, 'recusa_em', p.recusa_em,
    'responsavel_nome', pr.nome, 'responsavel_email', pr.email
  ) into v_result
  from public.propostas_comerciais p
  left join public.cidades_infra ci on ci.id = p.cidade_id
  left join public.parceiros pa on pa.id = p.parceiro_id
  left join public.parceiros_responsaveis pr on pr.id = p.responsavel_id
  where p.id = v_prop.id;

  return v_result;
end;
$$;
comment on function app.proposta_externa_por_token(text) is 'Fase 3.11 (seções 6-7): único ponto de leitura da área externa do parceiro. Nunca devolve piso/margem/desconto/governança/auditoria/custo interno — mesmo whitelist de campos da view interna já auditada na Fase 3.10. Registra PROPOSTA_VISUALIZADA em toda chamada (idempotente só na transição de status).';

create or replace function public.pricing_proposal_external_by_token(p_token text)
returns jsonb language sql security definer set search_path = public, pg_temp as $$ select app.proposta_externa_por_token(p_token); $$;
grant execute on function public.pricing_proposal_external_by_token(text) to anon;

-- 5b) Aceite formal (seções 8-10): operação real de backend, nunca um setStatus no
--     frontend. Exige identificação de quem aceitou — nunca aceita "silencioso".
create or replace function app.aceitar_proposta_parceiro(
  p_token text, p_nome text, p_documento text, p_cargo text, p_email text, p_telefone text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prop public.propostas_comerciais;
  v_ip inet;
begin
  if p_nome is null or trim(p_nome) = '' then raise exception 'DADOS_OBRIGATORIOS: nome completo é obrigatório para aceitar a proposta.'; end if;
  if p_documento is null or trim(p_documento) = '' then raise exception 'DADOS_OBRIGATORIOS: CPF/CNPJ é obrigatório para aceitar a proposta.'; end if;
  if p_email is null or trim(p_email) = '' then raise exception 'DADOS_OBRIGATORIOS: e-mail é obrigatório para aceitar a proposta.'; end if;

  select * into v_prop from public.propostas_comerciais where token_acesso_externo = p_token;
  if v_prop.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  if v_prop.token_expira_em is not null and v_prop.token_expira_em < now() then
    raise exception 'TOKEN_EXPIRADO: este link expirou — solicite um novo envio.';
  end if;
  if v_prop.status not in ('ENVIADA_AO_PARCEIRO', 'VISUALIZADA_PELO_PARCEIRO') then
    raise exception 'STATUS_INVALIDO: esta proposta está em status % — só pode ser aceita a partir de ENVIADA_AO_PARCEIRO/VISUALIZADA_PELO_PARCEIRO (evita aceite duplicado ou fora de ordem).', v_prop.status;
  end if;

  begin
    v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', '')::inet;
  exception when others then v_ip := null; end;

  update public.propostas_comerciais
     set status = 'ACEITA_PELO_PARCEIRO',
         aceite_nome = trim(p_nome), aceite_documento = trim(p_documento), aceite_cargo = nullif(trim(coalesce(p_cargo, '')), ''),
         aceite_email = trim(p_email), aceite_telefone = nullif(trim(coalesce(p_telefone, '')), ''),
         aceite_em = now(), aceite_ip = v_ip
   where id = v_prop.id
   returning * into v_prop;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_prop.id, 'PROPOSAL_ACCEPTED_BY_PARTNER',
    'Aceite formal registrado pelo parceiro.', null,
    jsonb_build_object('aceite_nome', v_prop.aceite_nome, 'aceite_documento', v_prop.aceite_documento, 'aceite_email', v_prop.aceite_email, 'ip', v_ip::text),
    'parceiro_externo');

  return jsonb_build_object('id', v_prop.id, 'numero', v_prop.numero, 'status', v_prop.status, 'aceite_em', v_prop.aceite_em);
end;
$$;
comment on function app.aceitar_proposta_parceiro(text, text, text, text, text, text) is 'Fase 3.11 (seções 8-10): ÚNICO caminho para ACEITA_PELO_PARCEIRO — nunca via app.mudar_status_proposta (removido de lá nesta fase). Aceite ≠ assinatura: não mexe em nenhum dado de signature_envelopes.';

create or replace function public.pricing_proposal_external_accept(p_token text, p_nome text, p_documento text, p_cargo text default null, p_email text default null, p_telefone text default null)
returns jsonb language sql security definer set search_path = public, pg_temp as $$ select app.aceitar_proposta_parceiro(p_token, p_nome, p_documento, p_cargo, p_email, p_telefone); $$;
grant execute on function public.pricing_proposal_external_accept(text, text, text, text, text, text) to anon;

-- 5c) Recusa formal (seção 8: "RECUSAR PROPOSTA" + motivo obrigatório).
create or replace function app.recusar_proposta_parceiro(p_token text, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prop public.propostas_comerciais;
begin
  if p_motivo is null or trim(p_motivo) = '' then raise exception 'MOTIVO_OBRIGATORIO: informe o motivo da recusa.'; end if;

  select * into v_prop from public.propostas_comerciais where token_acesso_externo = p_token;
  if v_prop.id is null then raise exception 'TOKEN_INVALIDO: link inválido ou expirado.'; end if;
  if v_prop.status not in ('ENVIADA_AO_PARCEIRO', 'VISUALIZADA_PELO_PARCEIRO') then
    raise exception 'STATUS_INVALIDO: esta proposta está em status % — não pode ser recusada agora.', v_prop.status;
  end if;

  update public.propostas_comerciais
     set status = 'RECUSADA_PELO_PARCEIRO', recusa_motivo = trim(p_motivo), recusa_em = now()
   where id = v_prop.id
   returning * into v_prop;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_prop.id, 'PROPOSAL_DECLINED_BY_PARTNER',
    p_motivo, null, jsonb_build_object('recusa_motivo', p_motivo), 'parceiro_externo');

  return jsonb_build_object('id', v_prop.id, 'numero', v_prop.numero, 'status', v_prop.status);
end;
$$;
comment on function app.recusar_proposta_parceiro(text, text) is 'Fase 3.11 (seção 8): recusa formal do parceiro, motivo sempre obrigatório.';

create or replace function public.pricing_proposal_external_decline(p_token text, p_motivo text)
returns jsonb language sql security definer set search_path = public, pg_temp as $$ select app.recusar_proposta_parceiro(p_token, p_motivo); $$;
grant execute on function public.pricing_proposal_external_decline(text, text) to anon;

-- ============================================================================
-- 6) app.gerar_contrato_de_proposta — MUDANÇA DE GATE deliberada e central desta fase
--    (seções 9-13 do prompt): "ACEITA_PELO_PARCEIRO" (aceite comercial REAL, validado no
--    backend via token) substitui "ASSINADA" (que era a assinatura eletrônica do
--    DOCUMENTO DA PROPOSTA, Fase 2.5 — usada até aqui como proxy indireto de aceite,
--    exatamente o que o prompt desta fase pede para corrigir: "ACEITA_PELO_PARCEIRO não
--    deve automaticamente significar ASSINADO", e vice-versa). Resto da função:
--    IDÊNTICO à versão da Fase 3.10 (lida diretamente antes desta alteração) — mesmas
--    inserções, mesmo vínculo bidirecional, mesma auditoria.
-- ============================================================================

create or replace function app.gerar_contrato_de_proposta(p_proposta_id uuid, p_prazo_minimo_excecao boolean default false, p_motivo_excecao_prazo text default null)
returns public.contratos
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prop public.propostas_comerciais;
  v_sim public.simulacoes;
  v_contrato public.contratos;
  v_numero text;
  v_modelo contrato_modelo;
  v_prazo integer;
  v_snapshot jsonb;
  v_revenue_share numeric;
  v_faturamento numeric;
  v_recommended numeric;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem gerar contrato a partir de uma proposta.';
  end if;

  select * into v_prop from public.propostas_comerciais where id = p_proposta_id;
  if v_prop.id is null then
    raise exception 'NAO_ENCONTRADA: proposta % não encontrada ou sem permissão de leitura.', p_proposta_id;
  end if;

  if v_prop.status <> 'ACEITA_PELO_PARCEIRO' then
    raise exception 'STATUS_INVALIDO: só é possível gerar contrato a partir de uma proposta com ACEITE FORMAL do parceiro registrado (Fase 3.11) — status atual: %.', v_prop.status;
  end if;

  if v_prop.contrato_id is not null then
    raise exception 'JA_GERADO: esta proposta já possui contrato vinculado (%) — use aditivo para alterações, nunca gerar de novo.', v_prop.contrato_id;
  end if;

  if v_prop.parceiro_id is null or v_prop.cidade_id is null then
    raise exception 'DADOS_INCOMPLETOS: proposta sem parceiro_id/cidade_id — não é possível gerar contrato.';
  end if;

  select * into v_sim from public.simulacoes where id = v_prop.simulacao_id;
  v_snapshot := v_prop.snapshot;

  v_modelo := coalesce(v_sim.modelo, 'HIBRIDO_REVENUE_SHARE'::contrato_modelo);
  v_prazo := coalesce((v_snapshot->>'prazo_meses')::integer, v_sim.prazo_meses, 48);
  v_revenue_share := (v_snapshot->>'revenue_share_pct')::numeric;
  v_faturamento := (v_snapshot->>'faturamento')::numeric;
  v_recommended := (v_snapshot->>'recommended')::numeric;

  if v_prazo < 48 and not p_prazo_minimo_excecao then
    raise exception 'PRAZO_MINIMO: contrato mínimo é de 48 meses — prazo da proposta é % meses; use uma exceção autorizada para prosseguir.', v_prazo;
  end if;

  if p_prazo_minimo_excecao and (p_motivo_excecao_prazo is null or trim(p_motivo_excecao_prazo) = '') then
    raise exception 'MOTIVO_OBRIGATORIO: prazo abaixo de 48 meses exige motivo da exceção.';
  end if;

  v_numero := 'CONTR-' || to_char(now(), 'YYYYMMDD') || '-' || substr(gen_random_uuid()::text, 1, 8);

  insert into public.contratos (
    numero, parceiro_id, cidade_id, modelo, status, prazo_meses,
    prazo_minimo_excecao, aprovado_por, aprovado_em, proposta_origem_id
  ) values (
    v_numero, v_prop.parceiro_id, v_prop.cidade_id, v_modelo, 'RASCUNHO', v_prazo,
    p_prazo_minimo_excecao,
    case when p_prazo_minimo_excecao then auth.uid() else null end,
    case when p_prazo_minimo_excecao then now() else null end,
    v_prop.id
  )
  returning * into v_contrato;

  insert into public.contrato_pricing_config (contrato_id, percentual_revenue_share, mensalidade_minima_porta)
  values (v_contrato.id, v_revenue_share, v_recommended);

  insert into public.contrato_regras (contrato_id)
  values (v_contrato.id);

  insert into public.contrato_versions (contrato_id, versao, motivo, snapshot, criado_por)
  values (v_contrato.id, 1, 'Geração automática a partir da proposta ' || v_prop.numero || ' (aceite formal do parceiro em ' || to_char(v_prop.aceite_em, 'DD/MM/YYYY HH24:MI') || ').', v_snapshot, auth.uid());

  update public.propostas_comerciais
     set contrato_id = v_contrato.id,
         status = 'CONTRATO_GERADO'
   where id = v_prop.id;

  perform app.registrar_auditoria_semantica('contratos', v_contrato.id, 'CONTRACT_GENERATE',
    'Gerado automaticamente a partir da proposta ' || v_prop.numero || ' após aceite formal do parceiro.',
    null, to_jsonb(v_contrato));

  perform app.registrar_auditoria_semantica('contratos', v_contrato.id, 'CONTRACT_MINUTA_GENERATED',
    'Minuta disponível imediatamente após a geração do contrato a partir da proposta ' || v_prop.numero,
    null, jsonb_build_object('contrato_id', v_contrato.id, 'proposta_origem_id', v_prop.id, 'numero_contrato', v_contrato.numero));

  return v_contrato;
end;
$$;

comment on function app.gerar_contrato_de_proposta(uuid, boolean, text) is 'Fase 2.5/3.10, GATE CORRIGIDO na Fase 3.11 (seções 9-13): exige ACEITA_PELO_PARCEIRO (aceite comercial real, via token) em vez de ASSINADA (que media a assinatura do DOCUMENTO DA PROPOSTA, não o aceite). Mudança deliberada e documentada — não afrouxa nada, TROCA um proxy indireto por uma verificação direta do que o prompt pede.';

-- ============================================================================
-- 7) app.mudar_status_proposta — FECHA A BRECHA central desta fase (seção 9): um usuário
--    interno não pode mais "fingir" que o parceiro aceitou/recusou/que a proposta foi
--    enviada — essas 3 transições SÓ acontecem via as funções dedicadas acima (envio
--    real com token, aceite/recusa reais do parceiro). Preserva EXPIRADA/CANCELADA
--    (ações genuinamente internas, sem contrapartida do parceiro) e ainda aceita
--    ENVIADA/EM_NEGOCIACAO/ACEITA por COMPATIBILIDADE DE LEITURA com dados antigos (não
--    remove os valores do enum), mas não permite mais essas 3 transições SEREM DISPARADAS
--    por aqui — só pelas rotas corretas.
-- ============================================================================

create or replace function app.mudar_status_proposta(p_proposta_id uuid, p_novo_status text, p_motivo text default null)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_orig public.propostas_comerciais;
  v_row public.propostas_comerciais;
begin
  if p_novo_status not in ('EXPIRADA', 'CANCELADA') then
    raise exception 'Status % inválido para app.mudar_status_proposta (Fase 3.11: ENVIADA/ACEITA/RECUSADA/EM_NEGOCIACAO só acontecem via app.enviar_proposta_parceiro / aceite-recusa formal do parceiro pelo token — nunca por troca manual de status). Use app.aprovar_proposta/app.rejeitar_proposta para aprovação interna, ou EXPIRADA/CANCELADA aqui.', p_novo_status;
  end if;

  select * into v_orig from public.propostas_comerciais where id = p_proposta_id;
  if v_orig.id is null then
    raise exception 'Proposta % não encontrada.', p_proposta_id;
  end if;
  if v_orig.status in ('ACEITA', 'RECUSADA', 'EXPIRADA', 'CANCELADA', 'ACEITA_PELO_PARCEIRO', 'RECUSADA_PELO_PARCEIRO', 'CONTRATO_GERADO') then
    raise exception 'Proposta % já está em estado terminal (%) — não pode mudar de status.', v_orig.numero, v_orig.status;
  end if;
  if p_novo_status = 'CANCELADA' and (p_motivo is null or trim(p_motivo) = '') then
    raise exception 'MOTIVO_OBRIGATORIO: motivo é obrigatório para cancelar uma proposta.';
  end if;

  update public.propostas_comerciais
    set status = p_novo_status, motivo_status = coalesce(p_motivo, motivo_status)
    where id = p_proposta_id
    returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', p_proposta_id, 'PROPOSAL_STATUS_CHANGE', p_motivo, jsonb_build_object('status', v_orig.status), jsonb_build_object('status', p_novo_status));

  return v_row;
end;
$$;
comment on function app.mudar_status_proposta(uuid, text, text) is 'Fase 2.4 seção 36, REDUZIDA na Fase 3.11 (seção 9): só EXPIRADA/CANCELADA — ENVIADA/ACEITA/RECUSADA/EM_NEGOCIACAO removidos daqui de propósito (eram a brecha de "aceite falso" identificada pelo usuário) e agora só acontecem via as funções dedicadas ao fluxo real com o parceiro.';

-- ============================================================================
-- 8) app.historico_negociacao — seção 23: timeline da negociação, construída a partir da
--    trilha de auditoria REAL (nunca uma tabela paralela que poderia divergir do que de
--    fato aconteceu). SECURITY INVOKER: quem já pode ver a proposta (propostas_comerciais_
--    select libera para todo authenticated) já pode ver sua auditoria (auditoria_select
--    já é ampla o bastante — não precisa de policy nova).
-- ============================================================================

create or replace function app.historico_negociacao(p_proposta_id uuid)
returns table (
  criado_em timestamptz, acao text, usuario_nome text, motivo text, valor_novo jsonb, origem text
)
language sql
security invoker
stable
as $$
  select a.criado_em, a.acao, u.nome as usuario_nome, a.motivo, a.valor_novo, a.origem
  from public.auditoria a
  left join public.usuarios u on u.id = a.usuario_id
  where (a.entidade = 'propostas_comerciais' and a.entidade_id = p_proposta_id)
     or (a.entidade = 'contratos' and a.entidade_id = (select contrato_id from public.propostas_comerciais where id = p_proposta_id))
  order by a.criado_em asc;
$$;
comment on function app.historico_negociacao(uuid) is 'Fase 3.11 (seção 23): timeline da negociação = auditoria real da proposta + (depois de gerado) do contrato vinculado, nunca uma tabela paralela.';

create or replace function public.pricing_proposal_historico(p_proposta_id uuid)
returns table (criado_em timestamptz, acao text, usuario_nome text, motivo text, valor_novo jsonb, origem text)
language sql security invoker as $$ select * from app.historico_negociacao(p_proposta_id); $$;
grant execute on function public.pricing_proposal_historico(uuid) to authenticated;

-- ============================================================================
-- 9) app.enriquecer_proposta — Fase 3.11: acrescenta (aditivo, nenhum campo removido)
--    os campos novos do fluxo parceiro (token/expiração/envio/visualização/aceite/
--    recusa) — sem isso, GET /api/proposals/:id nunca devolveria o link externo gerado
--    por "Enviar ao Parceiro", nem os dados de aceite/recusa, para a tela interna
--    (ProposalDetail.jsx) mostrar. `token_acesso_externo` só é devolvido para quem já
--    pode ler a proposta internamente (RLS de propostas_comerciais_select, sempre
--    authenticated da NICK) — nunca para o parceiro, que usa a rota separada
--    pricing_proposal_external_by_token (essa sim SECURITY DEFINER/anon, com whitelist
--    própria que nunca inclui o token de volta).
-- ============================================================================

create or replace function app.enriquecer_proposta(p public.propostas_comerciais)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'id', p.id,
    'numero', p.numero,
    'status', p.status,
    'numero_versao', p.numero_versao,
    'proposta_raiz_id', p.proposta_raiz_id,
    'duplicada_de_id', p.duplicada_de_id,
    'simulacao_id', p.simulacao_id,
    'pricing_version_id', p.pricing_version_id,
    'override_request_id', p.override_request_id,
    'contrato_id', p.contrato_id,
    'cidade_id', p.cidade_id,
    'cidade_nome', (select c.nome from public.cidades_infra c where c.id = p.cidade_id),
    'cidade_uf', (select c.uf from public.cidades_infra c where c.id = p.cidade_id),
    'parceiro_id', p.parceiro_id,
    'parceiro_razao_social', (select pa.razao_social from public.parceiros pa where pa.id = p.parceiro_id),
    'parceiro_nome_fantasia', (select pa.nome_fantasia from public.parceiros pa where pa.id = p.parceiro_id),
    'parceiro_nome_capa', p.parceiro_nome_capa,
    'parceiro_cargo_contato', p.parceiro_cargo_contato,
    'validade_dias', p.validade_dias,
    'snapshot', p.snapshot,
    'criado_por', p.criado_por,
    'criado_por_nome', (select u.nome from public.usuarios u where u.id = p.criado_por),
    'criado_em', p.criado_em,
    'autorizado_por', p.autorizado_por,
    'autorizado_por_nome', (select u.nome from public.usuarios u where u.id = p.autorizado_por),
    'autorizado_em', p.autorizado_em,
    'preco_autorizado', p.preco_autorizado,
    'motivo_autorizacao', p.motivo_autorizacao,
    'motivo_status', p.motivo_status,
    'prazo_meses', (select s.prazo_meses from public.simulacoes s where s.id = p.simulacao_id),
    'pop_nome', (select pop.nome from public.infra_pops pop where pop.id::text = (p.snapshot->>'pop_id')),
    'observacoes_comerciais', p.observacoes_comerciais,
    'proximos_passos', p.proximos_passos,
    'contrato_numero', (select ct.numero from public.contratos ct where ct.id = p.contrato_id),
    -- Fase 3.11 (seções 5-9) — campos novos, aditivos:
    'token_acesso_externo', p.token_acesso_externo,
    'token_expira_em', p.token_expira_em,
    'enviado_ao_parceiro_em', p.enviado_ao_parceiro_em,
    'enviado_ao_parceiro_por_nome', (select u.nome from public.usuarios u where u.id = p.enviado_ao_parceiro_por),
    'primeira_visualizacao_em', p.primeira_visualizacao_em,
    'ultima_visualizacao_em', p.ultima_visualizacao_em,
    'visualizacoes_count', p.visualizacoes_count,
    'aceite_nome', p.aceite_nome,
    'aceite_documento', p.aceite_documento,
    'aceite_cargo', p.aceite_cargo,
    'aceite_email', p.aceite_email,
    'aceite_telefone', p.aceite_telefone,
    'aceite_em', p.aceite_em,
    'recusa_motivo', p.recusa_motivo,
    'recusa_em', p.recusa_em
  );
$$;
comment on function app.enriquecer_proposta(public.propostas_comerciais) is 'Fase 2.4/3.10/3.11 — monta o jsonb enriquecido de uma proposta para as telas internas (nunca para o parceiro — a área externa usa app.proposta_externa_por_token, com whitelist própria). Fase 3.11 acrescenta token/expiração/envio/visualização/aceite/recusa — aditivo, nenhum campo anterior removido.';

-- ============================================================================
-- 10) app.contrato_assinatura_status — Fase 3.11 (seção 17): status resumido da
--     assinatura eletrônica do CONTRATO (não da proposta) para a tela ContractDetail —
--     reaproveita 100% as tabelas signature_envelopes/signature_signers já existentes
--     desde a Fase 2.5, nenhuma tabela nova. security invoker: quem já pode ler o
--     contrato (contratos_select) já pode ler o status de assinatura dele.
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
    'criado_em', e.criado_em,
    'enviado_em', e.enviado_em,
    'documento_assinado_disponivel', exists(
      select 1 from public.documentos_assinados da where da.envelope_id = e.id and da.validado = true
    ),
    'signatarios', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'nome', s.nome, 'email', s.email, 'papel', s.papel, 'ordem', s.ordem,
        'status', s.status, 'assinado_em', s.assinado_em
      ) order by s.ordem), '[]'::jsonb)
      from public.signature_signers s where s.envelope_id = e.id
    )
  )
  from public.signature_envelopes e
  where e.contrato_id = p_contrato_id and e.tipo_documento = 'CONTRATO'
  order by e.criado_em desc
  limit 1;
$$;
comment on function app.contrato_assinatura_status(uuid) is 'Fase 3.11 (seção 17): resumo do envelope de assinatura ICP-Brasil mais recente do contrato (tipo_documento=CONTRATO), para a seção "Assinatura eletrônica" de ContractDetail.jsx — reaproveita o motor de assinatura da Fase 2.5 sem nenhuma alteração.';

create or replace function public.pricing_contrato_assinatura_status(p_contrato_id uuid)
returns jsonb
language sql security invoker as $$ select app.contrato_assinatura_status(p_contrato_id); $$;
grant execute on function public.pricing_contrato_assinatura_status(uuid) to authenticated;

-- ============================================================================
-- 11) public.pricing_proposal_external_view — CORREÇÃO DE BUG REAL (encontrado na
--     verificação visual desta fase, não hipotético): a função original (Fase 2.4/3.10)
--     usava `pc.snapshot->>'campo'` para clientes/arpu/faturamento/preco_proposto/
--     revenue_share_pct/pons_count — o operador ->> sempre devolve TEXT, então o jsonb
--     resultante guardava esses valores como STRING ("2570.00"), não número. No
--     frontend, `formatCurrencyFull` chama `v.toLocaleString('pt-BR', {style:
--     'currency', ...})` — em uma STRING, `String.prototype.toLocaleString` ignora
--     silenciosamente as opções e devolve a própria string sem formatar. Resultado
--     visível: os cards "Mensalidade proposta"/"Faturamento mensal estimado" no modo
--     Externa Parceiro (ProposalDetail.jsx) apareciam como "2570" em vez de
--     "R$ 2.570,00" — nunca pego pelos testes anteriores porque nenhum deles comparava
--     o valor NUMÉRICO, só a presença/ausência de texto no PDF. Mesmo bug corrigido em
--     app.proposta_externa_por_token (seção 5a acima) — aqui é a função irmã usada pelo
--     preview INTERNO do modo Externa (GET /api/proposals/:id/public), preservando 100%
--     o resto do comportamento (mesma whitelist, nunca floor/governança/desconto).
-- ============================================================================

create or replace function public.pricing_proposal_external_view(p_proposta_id uuid)
returns jsonb
language sql
stable
security invoker
as $$
  select jsonb_build_object(
    'id', pc.id,
    'numero', pc.numero,
    'status', pc.status,
    'numero_versao', pc.numero_versao,
    'cidade_nome', c.nome,
    'cidade_uf', c.uf,
    'parceiro_nome_capa', coalesce(pc.parceiro_nome_capa, pa.nome_fantasia, pa.razao_social),
    'parceiro_cargo_contato', pc.parceiro_cargo_contato,
    'validade_dias', pc.validade_dias,
    'criado_em', pc.criado_em,
    -- só os campos comerciais que o parceiro tem o direito de ver — nunca
    -- floor/opening/discount/max_override_discount_percent/
    -- preco_minimo_autorizado/governance_status/partner_margin/autorizacao.
    'clientes', nullif(pc.snapshot->>'clientes','')::numeric,
    'arpu', nullif(pc.snapshot->>'arpu','')::numeric,
    'faturamento', nullif(pc.snapshot->>'faturamento','')::numeric,
    'preco_proposto', nullif(pc.snapshot->>'preco_proposto','')::numeric,
    'revenue_share_pct', nullif(pc.snapshot->>'revenue_share_pct','')::numeric,
    'prazo_meses', s.prazo_meses,
    'pop_nome', pop.nome,
    'pons_count', nullif(pc.snapshot->>'pons_count','')::numeric,
    'observacoes_comerciais', pc.observacoes_comerciais,
    'proximos_passos', pc.proximos_passos
  )
  from public.propostas_comerciais pc
  left join public.cidades_infra c on c.id = pc.cidade_id
  left join public.parceiros pa on pa.id = pc.parceiro_id
  left join public.simulacoes s on s.id = pc.simulacao_id
  left join public.infra_pops pop on pop.id::text = (pc.snapshot->>'pop_id')
  where pc.id = p_proposta_id;
$$;
comment on function public.pricing_proposal_external_view(uuid) is 'Fase 2.4/3.10/3.11 — preview INTERNO do modo Externa Parceiro (nunca usado pelo parceiro real, que usa pricing_proposal_external_by_token). Fase 3.11 corrige bug real: valores agora ::numeric (não mais string), formatCurrencyFull volta a formatar corretamente no frontend.';

-- ============================================================================
-- 12) app.dashboard_contratual — Fase 3.11 (seção 24, indicadores): 2 correções/
--     acréscimos aditivos, nenhuma chave anterior removida:
--     (a) BUG REAL: 'propostas_abertas' considerava só os 5 status terminais antigos
--         (ACEITA/RECUSADA/EXPIRADA/CANCELADA/CONTRATO_GERADO) — uma proposta
--         RECUSADA_PELO_PARCEIRO (novo status terminal desta fase) continuava contando
--         como "aberta" no KPI do dashboard, embora esteja definitivamente encerrada.
--     (b) Novo indicador 'propostas_aguardando_aceite_parceiro' (ENVIADA_AO_PARCEIRO +
--         VISUALIZADA_PELO_PARCEIRO) — visibilidade real de quantas propostas estão "na
--         mesa do parceiro" aguardando resposta, que não existia antes desta fase.
-- ============================================================================

create or replace function app.dashboard_contratual()
returns jsonb
language sql
stable
security invoker
as $$
  select jsonb_build_object(
    'contratos_ativos', (select count(*) from public.contratos where status = 'ATIVO'),
    'propostas_aguardando_aprovacao', (select count(*) from public.propostas_comerciais where status = 'EM_APROVACAO'),
    'propostas_aguardando_assinatura', (select count(*) from public.propostas_comerciais where status = 'EM_ASSINATURA'),
    'propostas_pendentes', (
      select count(*) from public.propostas_comerciais where status in ('EM_APROVACAO', 'EM_ASSINATURA')
    ),
    'propostas_abertas', (
      select count(*) from public.propostas_comerciais
      where status not in ('ACEITA', 'RECUSADA', 'EXPIRADA', 'CANCELADA', 'CONTRATO_GERADO', 'RECUSADA_PELO_PARCEIRO')
    ),
    'propostas_aprovadas', (select count(*) from public.propostas_comerciais where status = 'APROVADA'),
    -- Fase 3.11 (seção 24) — novo:
    'propostas_aguardando_aceite_parceiro', (
      select count(*) from public.propostas_comerciais where status in ('ENVIADA_AO_PARCEIRO', 'VISUALIZADA_PELO_PARCEIRO')
    ),
    'propostas_aceitas_aguardando_contrato', (
      select count(*) from public.propostas_comerciais where status = 'ACEITA_PELO_PARCEIRO'
    ),
    'contratos_aguardando_assinatura', (
      select count(distinct contrato_id) from public.signature_envelopes
      where tipo_documento = 'CONTRATO' and status in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
    ),
    'contratos_pendentes', (
      select count(distinct contrato_id) from public.signature_envelopes
      where tipo_documento = 'CONTRATO' and status in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
    ),
    'contratos_proximos_vencimento', (
      select count(*) from public.contratos
      where status = 'ATIVO' and data_fim_prevista is not null and data_fim_prevista <= current_date + interval '60 days'
    ),
    'reajustes_pendentes', (select count(*) from public.reajustes where status = 'PENDENTE'),
    'valor_mensal_contratado', (
      select coalesce(sum(cpc.mensalidade_minima_porta), 0)
      from public.contratos c join public.contrato_pricing_config cpc on cpc.contrato_id = c.id
      where c.status = 'ATIVO'
    ),
    'pons_locadas', (
      select count(*) from public.contrato_fibras cf
      where cf.desvinculado_em is null and cf.porta_pon_id is not null
    ),
    'fibras_locadas', (
      select count(*) from public.infra_fibras where status = 'LOCADA'
    ),
    'alertas_nao_resolvidos', (select count(*) from public.alertas where resolvido = false),
    'usuarios_ativos', (select count(*) from public.usuarios where ativo = true and removido_em is null),
    'usuarios_inativos', (select count(*) from public.usuarios where ativo = false and removido_em is null),
    'proponentes_ativos', (select count(*) from public.parceiros where ativo = true and removido_em is null),
    'assinaturas_pendentes', (
      select count(*) from public.signature_envelopes
      where status in ('CRIADO', 'ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
    ),
    'aditivos_pendentes', (
      select count(*) from public.contrato_aditivos
      where status in ('RASCUNHO', 'EM_APROVACAO', 'APROVADO', 'ASSINATURA')
    )
  );
$$;
comment on function app.dashboard_contratual() is 'Fase 3/3.11 — resumo executivo. Fase 3.11 corrige propostas_abertas (RECUSADA_PELO_PARCEIRO agora conta como terminal) e acrescenta propostas_aguardando_aceite_parceiro/propostas_aceitas_aguardando_contrato.';
