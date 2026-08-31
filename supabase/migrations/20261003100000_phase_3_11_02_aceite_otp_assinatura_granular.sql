-- ============================================================================
-- OptiMon — Fase 3.11.2: CORREÇÃO CRÍTICA DO ACEITE EXTERNO E ASSINATURA ELETRÔNICA
--
-- Origem: homologação real encontrou dois problemas graves na Fase 3.11:
--
-- 1) O link externo (/parceiro/proposta/:token) permitia "aceite" só com
--    nome/CPF/e-mail digitados na hora — abrir o link nunca aceitava sozinho (isso já
--    estava certo), mas o preenchimento do formulário e um único clique em "Confirmar
--    aceite" bastavam para transicionar a proposta para ACEITA_PELO_PARCEIRO, sem
--    NENHUMA verificação de que quem preencheu o formulário realmente tem acesso à
--    caixa de e-mail informada. Não havia declaração de poderes, não havia checkbox de
--    confirmação em duas etapas, e não havia OTP. Esta migration substitui o aceite em
--    1 passo por um fluxo em 2 passos (iniciar → confirmar por código), com auditoria
--    completa (IP, user-agent, hash da proposta aceita, versão do termo).
--
-- 2) O envelope de assinatura eletrônica (Fase 2.5) nunca envia e-mail de verdade —
--    investigação completa (não presumida) confirmou que api/lib/signatureProvider.js
--    só tem UMA implementação real: MockHomologacaoProvider, que desde a Fase 2.5
--    NUNCA toca rede/e-mail (documentado no próprio arquivo, seção "Uma integração
--    real... exigiria credenciais e um contrato comercial que esta sessão não tem
--    acesso a"). Isto não é uma regressão desta fase — é uma limitação arquitetural
--    pré-existente, honestamente documentada desde a Fase 2.5 e reconfirmada agora.
--    O que ESTA migration corrige, de verdade, é o que estava fora do que um provedor
--    real relata: o envelope podia virar "ASSINADO" só porque o webhook (simulado)
--    dizia isso, mesmo que nem todos os signatários OBRIGATÓRIOS tivessem assinado —
--    corrigido abaixo (seção 9) para nunca aceitar isso sem checar de verdade,
--    reforçando o que app.validar_assinatura já fazia para documentos_assinados.validado
--    mas que faltava no próprio status do envelope.
--
-- Regras respeitadas (mesmas de toda a Fase 3.11):
--  - Migration NOVA e aditiva — nenhum arquivo já aplicado em produção é editado.
--  - CREATE OR REPLACE FUNCTION nunca muda a lista de parâmetros de uma função já
--    existente sem DROP FUNCTION explícito antes (armadilha de sobrecarga já
--    documentada nesta mesma fase) — usado em todo lugar necessário abaixo.
--  - Nenhuma dependência nova de pgcrypto (lição da Fase 3.11.1): todo hash aqui usa
--    md5() (núcleo do Postgres) ou gen_random_uuid() (núcleo desde o PG13) — nunca
--    gen_random_bytes/digest().
--  - O código de confirmação (OTP) em si é gerado e comparado em Node — o Postgres
--    nunca vê o valor em texto puro, só o hash (SHA-256 + pepper, calculado em
--    api/routes/proposalsExternal.js) — nem em log de auditoria, nem em coluna nenhuma.
-- ============================================================================

-- ============================================================================
-- 1) Novas colunas em propostas_comerciais — auditoria completa do aceite (seção 2 do
--    pedido: representante/CPF/e-mail/data-hora já existiam da Fase 3.11; faltavam
--    user-agent, método, versão do termo aceito e hash do que foi aceito).
-- ============================================================================

alter table public.propostas_comerciais
  add column if not exists aceite_user_agent text,
  add column if not exists aceite_metodo text,
  add column if not exists aceite_versao_termo text,
  add column if not exists aceite_hash_proposta text,
  add column if not exists aceite_token_hash text,
  add column if not exists token_revogado_em timestamptz,
  add column if not exists token_revogado_motivo text,
  add column if not exists token_revogado_por uuid;

comment on column public.propostas_comerciais.aceite_metodo is 'Fase 3.11.2: sempre ''OTP_EMAIL'' quando preenchido — nunca um aceite é registrado sem confirmação por código.';
comment on column public.propostas_comerciais.aceite_hash_proposta is 'Fase 3.11.2: md5(snapshot + preço + versão) no momento do aceite — permite provar depois exatamente qual conteúdo foi aceito, mesmo que a proposta seja duplicada/nova versão criada depois.';
comment on column public.propostas_comerciais.aceite_token_hash is 'Fase 3.11.2: md5() do token usado para aceitar (nunca o token em texto puro fica retido além da validade) — identificador do token para auditoria (seção 2: "identificador do token").';
comment on column public.propostas_comerciais.token_revogado_em is 'Fase 3.11.2 (seção 9): revogação manual do link externo por um usuário NICK, ANTES do vencimento natural (token_expira_em). Bloqueia visualização/aceite/recusa a partir deste instante — ver app.revogar_token_proposta.';

-- ============================================================================
-- 2) propostas_aceite_tentativas — staging do aceite ATÉ o OTP ser confirmado. Nenhum
--    dado aqui vira aceite formal sozinho — só depois de app.confirmar_aceite_
--    proposta_parceiro validar o código é que propostas_comerciais muda de status.
--    RLS habilitado SEM NENHUMA policy (nem para authenticated nem para anon): a única
--    forma de ler/escrever esta tabela é através das funções SECURITY DEFINER abaixo —
--    mesmo padrão já usado em signature_events (Fase 2.5) para o mesmo motivo (linha
--    "Nenhuma policy de INSERT para authenticated").
-- ============================================================================

create table if not exists public.propostas_aceite_tentativas (
  id uuid primary key default gen_random_uuid(),
  proposta_id uuid not null references public.propostas_comerciais(id) on delete cascade,
  token_hash text not null,
  nome text not null,
  documento text not null,
  cargo text,
  email text not null,
  telefone text,
  declaracao_aceita boolean not null default false,
  confirmacao_aceita boolean not null default false,
  otp_hash text not null,
  otp_expira_em timestamptz not null,
  otp_tentativas integer not null default 0,
  status text not null default 'AGUARDANDO_OTP' check (status = any (array['AGUARDANDO_OTP', 'CONFIRMADO', 'EXPIRADO', 'CANCELADO'])),
  ip text,
  user_agent text,
  criado_em timestamptz not null default now(),
  confirmado_em timestamptz
);

comment on table public.propostas_aceite_tentativas is 'Fase 3.11.2 (seções 1/2/9 do pedido): registro de CADA tentativa de aceite externo, com o código de confirmação (hash, nunca texto puro) e o contador de tentativas erradas — a "trilha de tentativas" exigida na auditoria. Uma proposta pode ter várias linhas aqui (uma por solicitação de código); só a que for CONFIRMADO efetiva o aceite.';

create index if not exists propostas_aceite_tentativas_proposta_idx on public.propostas_aceite_tentativas(proposta_id, status);

alter table public.propostas_aceite_tentativas enable row level security;
-- Sem nenhuma policy: RLS habilitado + nenhuma policy = ninguém (nem authenticated, nem
-- anon) lê/escreve por PostgREST direto — só via app.iniciar_aceite_proposta_parceiro/
-- app.confirmar_aceite_proposta_parceiro (SECURITY DEFINER, rodam como dono da função).

drop trigger if exists trg_aud_propostas_aceite_tentativas on public.propostas_aceite_tentativas;
create trigger trg_aud_propostas_aceite_tentativas
  after insert or delete or update on public.propostas_aceite_tentativas
  for each row execute function public.fn_auditoria();

-- ============================================================================
-- 3) app.registrar_auditoria_semantica — acrescenta p_ip (8º parâmetro, DEFAULT null).
--    Motivo real: current_setting('request.headers') só reflete o cabeçalho de quem
--    chamou o PostgREST — e quem chama é sempre o backend Node (api/lib/supabaseClient.js
--    clientForRequest/anonClient), nunca o navegador do usuário direto. Ou seja, o IP
--    capturado até aqui era sempre o IP do próprio servidor Node, nunca o do parceiro —
--    bug real, confirmado por leitura de código, silenciosamente presente desde a Fase
--    2.3.1 (fora do escopo desta correção pontual para todo o projeto, mas corrigido
--    aqui especificamente para a trilha de aceite do parceiro, que é o que a seção 2 do
--    pedido exige de verdade). A partir de agora, quem chama passa o IP real explicitamente
--    (req.ip do Express) — a tentativa de ler do GUC continua como fallback best-effort
--    para chamadas internas que não passem p_ip.
-- ============================================================================

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
  -- Fase 3.11.2:
  'PROPOSAL_ACCEPT_OTP_REQUESTED','PROPOSAL_ACCEPT_OTP_FAILED','PROPOSAL_ACCEPT_BLOCKED',
  'PROPOSAL_TOKEN_REVOKED'
]));

drop function if exists app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb, text);

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
    'PROPOSAL_TOKEN_REVOKED'
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

  insert into public.auditoria (usuario_id, ip, acao, entidade, entidade_id, valor_anterior, valor_novo, origem, motivo)
  values (auth.uid(), v_ip, p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, p_origem, p_motivo);
end;
$function$;

comment on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb, text, text) is 'Fase 2.3.1, ampliada nas Fases 3.8/3.10/3.11/3.11.2. p_ip (8º parâmetro): quando informado pelo chamador (Express repassando req.ip), tem prioridade sobre o GUC request.headers, que nunca reflete o IP real do navegador quando quem chama o PostgREST é o backend Node (bug real documentado nesta migration).';

grant execute on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb, text, text) to authenticated, anon;

-- ============================================================================
-- 4) app.aceitar_proposta_parceiro — NEUTRALIZADA. O aceite em 1 passo (sem OTP) foi
--    exatamente o problema real relatado ("abrir o link jamais pode representar
--    aceite" — e um formulário sem verificação de posse do e-mail é, na prática, quase
--    tão fraco quanto isso). Mantida com a MESMA assinatura (nunca removida — evita
--    quebrar o catálogo/grants existentes) mas agora sempre recusa, apontando para o
--    fluxo novo em 2 passos abaixo.
-- ============================================================================

create or replace function app.aceitar_proposta_parceiro(
  p_token text, p_nome text, p_documento text, p_cargo text, p_email text, p_telefone text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  raise exception 'FLUXO_ALTERADO: aceite direto (sem confirmação por código) foi desativado na Fase 3.11.2 — use app.iniciar_aceite_proposta_parceiro seguido de app.confirmar_aceite_proposta_parceiro. Abrir o link nunca é suficiente, e agora preencher o formulário também não é: é sempre exigida a confirmação do código enviado ao e-mail informado.';
end;
$$;

comment on function app.aceitar_proposta_parceiro(text, text, text, text, text, text) is 'DESATIVADA na Fase 3.11.2 — sempre levanta exceção. Mantida (mesma assinatura) só para não quebrar o catálogo; ver app.iniciar_aceite_proposta_parceiro/app.confirmar_aceite_proposta_parceiro.';

-- ============================================================================
-- 4b) REVOGAÇÃO do link externo (seção 9 do pedido: "Implementar: expiração;
--     REVOGAÇÃO; uso único para confirmação; proteção contra replay; log de tentativas;
--     bloqueio após aceite; não exposição de dados NICK internos."). Expiração natural
--     (token_expira_em) já existia desde a Fase 3.11; revogação MANUAL antes do
--     vencimento (ex.: suspeita de vazamento do link, mudança de interlocutor no
--     parceiro) não existia — gap real, corrigido aqui. app.proposta_externa_por_token
--     é recriada (mesma assinatura da Fase 3.11 original) só para acrescentar o
--     bloqueio por token_revogado_em — nenhum outro comportamento muda.
-- ============================================================================

create or replace function app.revogar_token_proposta(p_proposta_id uuid, p_motivo text default null)
returns public.propostas_comerciais
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_orig public.propostas_comerciais;
  v_row public.propostas_comerciais;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode revogar o link externo de uma proposta — só COMERCIAL/DIRETOR/ADMINISTRADOR.', app.perfil_atual();
  end if;

  select * into v_orig from public.propostas_comerciais where id = p_proposta_id;
  if v_orig.id is null then
    raise exception 'NAO_ENCONTRADA: proposta % não encontrada.', p_proposta_id;
  end if;
  if v_orig.token_acesso_externo is null then
    raise exception 'STATUS_INVALIDO: esta proposta nunca teve um link externo gerado.';
  end if;
  if v_orig.token_revogado_em is not null then
    raise exception 'STATUS_INVALIDO: este link já está revogado desde %.', to_char(v_orig.token_revogado_em, 'DD/MM/YYYY HH24:MI');
  end if;
  if v_orig.status not in ('ENVIADA_AO_PARCEIRO', 'VISUALIZADA_PELO_PARCEIRO') then
    raise exception 'STATUS_INVALIDO: só é possível revogar o link de uma proposta ainda aguardando o parceiro (status atual: %) — depois de aceita/recusada o link já para de aceitar novas ações.', v_orig.status;
  end if;

  update public.propostas_comerciais
     set token_revogado_em = now(), token_revogado_motivo = p_motivo, token_revogado_por = auth.uid()
   where id = p_proposta_id
   returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', p_proposta_id, 'PROPOSAL_TOKEN_REVOKED',
    p_motivo, jsonb_build_object('token_revogado_em', null), jsonb_build_object('token_revogado_em', v_row.token_revogado_em));

  return v_row;
end;
$$;
comment on function app.revogar_token_proposta(uuid, text) is 'Fase 3.11.2 (seção 9): revogação manual do link externo, antes do vencimento natural — bloqueia visualização/aceite/recusa a partir deste instante (ver checks em app.proposta_externa_por_token/iniciar/confirmar/recusar).';

create or replace function public.pricing_proposal_revoke_token(p_proposta_id uuid, p_motivo text default null)
returns public.propostas_comerciais
language sql security invoker as $$ select app.revogar_token_proposta(p_proposta_id, p_motivo); $$;
grant execute on function public.pricing_proposal_revoke_token(uuid, text) to authenticated;

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
  -- Fase 3.11.2 (seção 9): revogação manual bloqueia ATÉ a visualização — um link
  -- revogado para de funcionar por completo, não só para o aceite.
  if v_prop.token_revogado_em is not null then
    raise exception 'TOKEN_REVOGADO: este link foi revogado — solicite um novo envio ao consultor comercial.';
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

  update public.propostas_comerciais
     set status = case when status = 'ENVIADA_AO_PARCEIRO' then 'VISUALIZADA_PELO_PARCEIRO' else status end,
         primeira_visualizacao_em = coalesce(primeira_visualizacao_em, now()),
         ultima_visualizacao_em = now(),
         visualizacoes_count = visualizacoes_count + 1
   where id = v_prop.id
   returning * into v_prop;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_prop.id, 'PROPOSAL_VIEWED_BY_PARTNER',
    null, null, jsonb_build_object('ip', v_ip::text, 'visualizacoes_count', v_prop.visualizacoes_count), 'parceiro_externo');

  select jsonb_build_object(
    'id', p.id, 'numero', p.numero, 'status', p.status, 'numero_versao', p.numero_versao,
    'cidade_nome', ci.nome, 'cidade_uf', ci.uf,
    'pop_nome', (select nome from public.infra_pops where id = (p.snapshot->>'pop_id')::uuid),
    'parceiro_nome_capa', coalesce(p.parceiro_nome_capa, pa.nome_fantasia, pa.razao_social),
    'parceiro_cargo_contato', p.parceiro_cargo_contato,
    'validade_dias', p.validade_dias, 'criado_em', p.criado_em,
    'prazo_meses', coalesce(nullif(p.snapshot->>'prazo_meses',''), '48')::int,
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
comment on function app.proposta_externa_por_token(text) is 'Fase 3.11 (seções 6-7), recriada na Fase 3.11.2 (seção 9) só para acrescentar o bloqueio por token_revogado_em — resto do comportamento idêntico à versão original.';

-- ============================================================================
-- 5) app.iniciar_aceite_proposta_parceiro — passo 1 do aceite real (seção 1, itens
--    1-9 do pedido): valida token/status/dados obrigatórios/declaração/checkbox de
--    confirmação, gera uma tentativa com o HASH do código de confirmação (o código em
--    texto puro nunca chega ao Postgres — é gerado e "enviado" em Node, ver
--    api/routes/proposalsExternal.js). NUNCA muda o status da proposta — só depois do
--    OTP confirmado (passo 2) é que o aceite formal acontece.
-- ============================================================================

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

  -- Nunca deixa 2 tentativas AGUARDANDO_OTP simultâneas para a mesma proposta — evita
  -- ambiguidade sobre qual código vale (proteção contra replay de uma solicitação antiga).
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

  return jsonb_build_object('tentativa_id', v_tentativa_id, 'expira_em', v_expira);
end;
$$;

comment on function app.iniciar_aceite_proposta_parceiro(text, text, text, text, text, text, boolean, boolean, text, integer, text, text) is 'Fase 3.11.2 (seção 1, itens 1-9): passo 1 do aceite — valida tudo e cria a tentativa com o código de confirmação, mas NUNCA muda propostas_comerciais.status. Só app.confirmar_aceite_proposta_parceiro faz isso, e só depois do código validado.';

-- ============================================================================
-- 6) app.confirmar_aceite_proposta_parceiro — passo 2 (seção 1, itens 10-12): valida o
--    código (comparando hashes — nunca texto puro), bloqueia tentativa expirada/
--    excedida/duplicada, e SÓ AQUI efetiva o aceite formal (status, todos os campos de
--    auditoria, hash da proposta aceita, versão do termo).
-- ============================================================================

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

  -- Fase 3.11.2 (bug real encontrado em teste E2E real): propostas_comerciais NÃO tem
  -- coluna preco_proposto — o preço proposto vive dentro do snapshot (jsonb), mesmo
  -- padrão já usado por app.proposta_externa_por_token/enriquecer_proposta. A 1ª
  -- tentativa desta migration referenciava v_prop.preco_proposto (coluna inexistente),
  -- o que quebrava TODO aceite real com "record v_prop has no field preco_proposto" —
  -- só detectado porque o teste E2E realmente executa o passo 2 do aceite (não presume
  -- sucesso), exatamente o padrão de verificação exigido nesta correção.
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

comment on function app.confirmar_aceite_proposta_parceiro(text, uuid, text, text, text) is 'Fase 3.11.2 (seção 1, itens 10-12 + seção 2): passo 2 do aceite — só aqui a proposta vira ACEITA_PELO_PARCEIRO, e só depois do código de confirmação bater (comparação de hash, nunca texto puro). Bloqueia OTP incorreto/expirado/reutilizado, aceite duplicado, e proposta fora de status.';

-- ============================================================================
-- 7) app.recusar_proposta_parceiro — acrescenta p_ip/p_user_agent (mesma correção do
--    item 3 acima, aplicada à recusa por consistência). Precisa de DROP explícito
--    (mudança na lista de parâmetros).
-- ============================================================================

drop function if exists app.recusar_proposta_parceiro(text, text);

create or replace function app.recusar_proposta_parceiro(p_token text, p_motivo text, p_ip text default null, p_user_agent text default null)
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
  if v_prop.token_revogado_em is not null then
    raise exception 'TOKEN_REVOGADO: este link foi revogado.';
  end if;
  if v_prop.token_expira_em is not null and v_prop.token_expira_em < now() then
    raise exception 'TOKEN_EXPIRADO: este link expirou.';
  end if;
  if v_prop.status not in ('ENVIADA_AO_PARCEIRO', 'VISUALIZADA_PELO_PARCEIRO') then
    raise exception 'STATUS_INVALIDO: esta proposta está em status % — não pode ser recusada agora.', v_prop.status;
  end if;

  -- Recusar também invalida qualquer tentativa de aceite (OTP) ainda aberta.
  update public.propostas_aceite_tentativas set status = 'CANCELADO' where proposta_id = v_prop.id and status = 'AGUARDANDO_OTP';

  update public.propostas_comerciais
     set status = 'RECUSADA_PELO_PARCEIRO', recusa_motivo = trim(p_motivo), recusa_em = now()
   where id = v_prop.id
   returning * into v_prop;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_prop.id, 'PROPOSAL_DECLINED_BY_PARTNER',
    trim(p_motivo), null, jsonb_build_object('recusa_motivo', v_prop.recusa_motivo, 'user_agent', p_user_agent),
    'parceiro_externo', p_ip);

  return jsonb_build_object('id', v_prop.id, 'numero', v_prop.numero, 'status', v_prop.status, 'recusa_em', v_prop.recusa_em);
end;
$$;

drop function if exists public.pricing_proposal_external_decline(text, text);
create or replace function public.pricing_proposal_external_decline(p_token text, p_motivo text, p_ip text default null, p_user_agent text default null)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.recusar_proposta_parceiro(p_token, p_motivo, p_ip, p_user_agent); $$;
grant execute on function public.pricing_proposal_external_decline(text, text, text, text) to anon;

-- Wrappers públicos (SECURITY DEFINER — anon não enxerga o schema app, mesmo padrão já
-- usado por todos os outros wrappers *_external_* desde a migration original da Fase 3.11).
create or replace function public.pricing_proposal_external_accept_iniciar(
  p_token text, p_nome text, p_documento text, p_cargo text, p_email text, p_telefone text,
  p_declaracao boolean, p_confirmacao boolean, p_otp_hash text, p_otp_ttl_minutos integer default 10,
  p_ip text default null, p_user_agent text default null
)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.iniciar_aceite_proposta_parceiro(p_token, p_nome, p_documento, p_cargo, p_email, p_telefone, p_declaracao, p_confirmacao, p_otp_hash, p_otp_ttl_minutos, p_ip, p_user_agent); $$;
grant execute on function public.pricing_proposal_external_accept_iniciar(text, text, text, text, text, text, boolean, boolean, text, integer, text, text) to anon;

create or replace function public.pricing_proposal_external_accept_confirmar(
  p_token text, p_tentativa_id uuid, p_otp_hash_attempt text, p_ip text default null, p_user_agent text default null
)
returns jsonb language sql security definer set search_path = public, pg_temp
as $$ select app.confirmar_aceite_proposta_parceiro(p_token, p_tentativa_id, p_otp_hash_attempt, p_ip, p_user_agent); $$;
grant execute on function public.pricing_proposal_external_accept_confirmar(text, uuid, text, text, text) to anon;

-- O wrapper antigo (aceite em 1 passo) continua existindo (chama a função agora
-- neutralizada) — nunca removido do catálogo, só deixou de funcionar de propósito.

-- ============================================================================
-- 8) app.enriquecer_proposta — acrescenta os novos campos de auditoria do aceite
--    (seção 2 do pedido: Método/Versão aceita/Hash/user-agent) à tela interna.
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
    'aceite_ip', p.aceite_ip,
    'recusa_motivo', p.recusa_motivo,
    'recusa_em', p.recusa_em
  )
  -- jsonb_build_object tem limite de 100 argumentos (Postgres) — o objeto acima já
  -- estava perto do teto antes da Fase 3.11.2; os campos novos (seção 2 do pedido de
  -- correção: card "ACEITE DO PARCEIRO" completo) vão num segundo objeto concatenado
  -- com ||, nunca dentro da mesma chamada.
  || jsonb_build_object(
    'aceite_user_agent', p.aceite_user_agent,
    'aceite_metodo', p.aceite_metodo,
    'aceite_versao_termo', p.aceite_versao_termo,
    'aceite_hash_proposta', p.aceite_hash_proposta,
    'aceite_token_hash', p.aceite_token_hash,
    'token_revogado_em', p.token_revogado_em,
    'token_revogado_motivo', p.token_revogado_motivo
  );
$$;
comment on function app.enriquecer_proposta(public.propostas_comerciais) is 'Fase 2.4/3.10/3.11/3.11.2 — monta o jsonb enriquecido de uma proposta para as telas internas. Fase 3.11.2 acrescenta user-agent/método/versão do termo/hash do aceite + revogação do link — aditivo, nenhum campo anterior removido.';

-- ============================================================================
-- 9) signature_signers — status granular real (seção 4 do pedido) + obrigatoriedade
--    (seção 7) + timestamps de entrega/abertura + reenvio (seção 6).
-- ============================================================================

alter table public.signature_signers drop constraint if exists signature_signers_status_check;
alter table public.signature_signers add constraint signature_signers_status_check check (status = any (array[
  -- Vocabulário legado (Fase 2.5, linhas já gravadas continuam válidas):
  'PENDENTE', 'VISUALIZADO',
  -- Vocabulário novo (Fase 3.11.2, seção 4 do pedido):
  'CRIADO', 'ENVIANDO', 'ENVIADO', 'ENTREGUE', 'ABERTO', 'ASSINADO', 'RECUSADO', 'EXPIRADO', 'ERRO'
]));

alter table public.signature_signers
  add column if not exists obrigatorio boolean not null default true,
  add column if not exists enviado_em timestamptz,
  add column if not exists entregue_em timestamptz,
  add column if not exists aberto_em timestamptz,
  add column if not exists erro_mensagem text,
  add column if not exists reenvios_count integer not null default 0;

comment on column public.signature_signers.obrigatorio is 'Fase 3.11.2 (seção 7): quando true, este signatário precisa assinar para o envelope poder chegar a ASSINADO/VALIDADO (ver app.registrar_evento_assinatura_webhook e app.validar_assinatura). Default true — testemunhas/signatários adicionais podem ser marcados como não-obrigatórios explicitamente ao serem cadastrados.';

-- ============================================================================
-- 10) app.adicionar_signatario — acrescenta p_obrigatorio (precisa DROP: mudança na
--     lista de parâmetros).
-- ============================================================================

drop function if exists app.adicionar_signatario(uuid, text, text, text, integer, text, uuid);

create or replace function app.adicionar_signatario(
  p_envelope_id uuid,
  p_nome text,
  p_email text,
  p_papel text,
  p_ordem integer default 1,
  p_cpf text default null,
  p_responsavel_id uuid default null,
  p_obrigatorio boolean default true
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

  insert into public.signature_signers (envelope_id, nome, email, cpf, papel, ordem, responsavel_id, status, obrigatorio)
  values (p_envelope_id, p_nome, p_email, p_cpf, p_papel, p_ordem, p_responsavel_id, 'CRIADO', coalesce(p_obrigatorio, true))
  returning * into v_signer;

  return v_signer;
end;
$$;

comment on function app.adicionar_signatario(uuid, text, text, text, integer, text, uuid, boolean) is 'Fase 2.5 seção 5 (addSigner) + Fase 3.11.2 (seção 7: p_obrigatorio, default true — "definir quais assinaturas são obrigatórias"). Status inicial passa a ser CRIADO (vocabulário novo da seção 4) em vez de PENDENTE.';

drop function if exists public.pricing_signature_signer_add(uuid, text, text, text, integer, text, uuid);
create or replace function public.pricing_signature_signer_add(
  p_envelope_id uuid, p_nome text, p_email text, p_papel text, p_ordem integer default 1,
  p_cpf text default null, p_responsavel_id uuid default null, p_obrigatorio boolean default true
)
returns public.signature_signers
language sql security invoker
as $$ select app.adicionar_signatario(p_envelope_id, p_nome, p_email, p_papel, p_ordem, p_cpf, p_responsavel_id, p_obrigatorio); $$;
grant execute on function public.pricing_signature_signer_add(uuid, text, text, text, integer, text, uuid, boolean) to authenticated;

-- ============================================================================
-- 11) app.enviar_envelope_para_assinatura — registra enviado_em por signatário e usa o
--     novo status ENVIADO (já existia, sem mudança de vocabulário aqui) a partir de
--     CRIADO (em vez de PENDENTE, que era o default antigo).
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
     set status = 'ENVIADO', enviado_em = now()
   where envelope_id = v_envelope.id and status in ('PENDENTE', 'CRIADO');

  if v_envelope.tipo_documento = 'PROPOSTA' then
    update public.propostas_comerciais set status = 'EM_ASSINATURA' where id = v_envelope.proposta_id;
  elsif v_envelope.tipo_documento = 'ADITIVO' then
    update public.contrato_aditivos set status = 'EM_APROVACAO' where id = v_envelope.aditivo_id and status = 'RASCUNHO';
  end if;

  perform app.registrar_auditoria_semantica('signature_envelopes', v_envelope.id, 'SIGNATURE_ENVELOPE_SEND', null, null, to_jsonb(v_envelope));

  return v_envelope;
end;
$$;

-- ============================================================================
-- 12) app.registrar_evento_assinatura_webhook — seção 5 (log de entrega real:
--     entregue_em/aberto_em) + a correção crítica da seção 7: NUNCA aceitar
--     status_envelope=ASSINADO se algum signatário OBRIGATÓRIO ainda não assinou —
--     mesmo que o payload do webhook (provedor) diga que sim. Antes desta correção, o
--     envelope confiava cegamente no p_novo_status_envelope recebido; agora recalcula.
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
  v_status_final text;
  v_todos_obrigatorios_assinaram boolean;
begin
  insert into public.signature_events (envelope_id, evento_externo_id, tipo_evento, payload)
  values (p_envelope_id, p_evento_externo_id, p_tipo_evento, p_payload)
  on conflict (envelope_id, evento_externo_id) do nothing
  returning id into v_event_id;

  if v_event_id is null then
    return jsonb_build_object('duplicado', true);
  end if;

  select * into v_envelope from public.signature_envelopes where id = p_envelope_id;
  if v_envelope.id is null then
    raise exception 'NAO_ENCONTRADO: envelope % não encontrado (evento recebido mas sem envelope correspondente).', p_envelope_id;
  end if;

  -- Signatário não cadastrado neste envelope: a cláusula WHERE abaixo simplesmente não
  -- casa nenhuma linha (0 linhas afetadas) — nunca aplica a um signatário errado nem
  -- lança erro que pareça sucesso (seção 11: "assinar com signatário não autorizado"
  -- fica naturalmente bloqueado, sem side-effect nenhum).
  if p_signer_email is not null and p_signer_novo_status is not null then
    update public.signature_signers
       set status = p_signer_novo_status,
           entregue_em = case when p_signer_novo_status = 'ENTREGUE' and entregue_em is null then now() else entregue_em end,
           aberto_em = case when p_signer_novo_status = 'ABERTO' and aberto_em is null then now() else aberto_em end,
           assinado_em = case when p_signer_novo_status = 'ASSINADO' then now() else assinado_em end,
           erro_mensagem = case when p_signer_novo_status = 'ERRO' then (p_payload->>'erro_mensagem') else erro_mensagem end,
           ip_assinatura = coalesce(p_signer_ip, ip_assinatura),
           certificado_info = coalesce(p_signer_certificado, certificado_info)
     where envelope_id = p_envelope_id and lower(email) = lower(p_signer_email);
  end if;

  if p_novo_status_envelope is not null then
    v_status_final := p_novo_status_envelope;

    if p_novo_status_envelope = 'ASSINADO' then
      select not exists (
        select 1 from public.signature_signers
         where envelope_id = p_envelope_id and obrigatorio and status <> 'ASSINADO'
      ) into v_todos_obrigatorios_assinaram;

      if not coalesce(v_todos_obrigatorios_assinaram, false) then
        -- Fase 3.11.2 (seção 7): o provedor (ou o simulador de testes) alegou que o
        -- envelope está ASSINADO, mas nem todos os signatários OBRIGATÓRIOS assinaram
        -- de verdade segundo o próprio OptiMon — nunca aceito isso por presunção.
        -- Mantém o envelope em PARCIALMENTE_ASSINADO e registra a divergência.
        v_status_final := 'PARCIALMENTE_ASSINADO';
        perform app.registrar_auditoria_semantica('signature_envelopes', p_envelope_id, 'SIGNATURE_EVENT_RECEIVED',
          'INCONSISTENCIA: provedor sinalizou ASSINADO mas signatário(s) obrigatório(s) ainda pendente(s) — status NÃO aceito, mantido em PARCIALMENTE_ASSINADO.',
          null, p_payload);
      end if;
    end if;

    update public.signature_envelopes
       set status = v_status_final,
           hash_assinado = coalesce(p_hash_assinado, hash_assinado),
           documento_assinado_storage_path = coalesce(p_storage_path_assinado, documento_assinado_storage_path),
           erro_mensagem = case when v_status_final = 'ERRO' then (p_payload->>'erro_mensagem') else erro_mensagem end,
           concluido_em = case when v_status_final in ('ASSINADO', 'RECUSADO', 'EXPIRADO', 'ERRO') then now() else concluido_em end
     where id = p_envelope_id
     returning * into v_envelope;

    if v_status_final = 'ASSINADO' then
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

  return jsonb_build_object('duplicado', false, 'envelope_status', coalesce(v_status_final, v_envelope.status));
end;
$$;

comment on function app.registrar_evento_assinatura_webhook is 'Fase 2.5 seção 27/49, corrigida na Fase 3.11.2 (seção 7 do pedido de correção): nunca aceita status_envelope=ASSINADO só porque o payload do provedor diz isso — recalcula se todos os signatários OBRIGATÓRIOS já assinaram de verdade segundo as próprias linhas de signature_signers antes de honrar a transição. Também popula entregue_em/aberto_em/erro_mensagem por signatário (vocabulário de status da seção 4).';

grant execute on function app.registrar_evento_assinatura_webhook(uuid, text, text, jsonb, text, text, text, text, jsonb, text, text) to anon;

-- ============================================================================
-- 13) app.validar_assinatura — "signatarios_confirmados" agora considera só os
--     OBRIGATÓRIOS (mesma correção da seção 7, na camada de validação final).
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
  from public.signature_signers where envelope_id = p_envelope_id and obrigatorio;

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

comment on function app.validar_assinatura(uuid) is 'Fase 2.5 seção 10/56, corrigida na Fase 3.11.2 (seção 7): "signatarios_confirmados" agora exige ASSINADO só dos signatários OBRIGATÓRIOS — um signatário opcional (ex.: testemunha marcada como não-obrigatória) pendente não bloqueia mais a validação.';

-- ============================================================================
-- 14) app.reenviar_assinatura_signatario — "REENVIAR ASSINATURA" (seção 6 do pedido).
--     Nunca duplica assinatura: bloqueia reenvio para quem já assinou. Reseta os
--     timestamps de entrega/abertura do NOVO envio (o antigo fica só no histórico via
--     signature_events, nunca apagado) e registra motivo/usuário/novo envio.
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
  if v_envelope.status not in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO', 'ERRO') then
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

comment on function app.reenviar_assinatura_signatario(uuid, text) is 'Fase 3.11.2 (seção 6): REENVIAR ASSINATURA. SECURITY DEFINER pelo mesmo motivo de app.enviar_envelope_para_assinatura (cruza envelope+signatário); RLS de signature_signers já restringe quem pode SELECT/UPDATE em geral, mas o motivo/registro de auditoria por reenvio precisa ficar centralizado aqui.';

create or replace function public.pricing_signature_signer_resend(p_signer_id uuid, p_motivo text default null)
returns public.signature_signers
language sql security invoker
as $$ select app.reenviar_assinatura_signatario(p_signer_id, p_motivo); $$;
grant execute on function public.pricing_signature_signer_resend(uuid, text) to authenticated;

-- ============================================================================
-- 15) app.contrato_assinatura_status — expõe os novos campos granulares por
--     signatário (seção 4/5 do pedido) + erro_mensagem do envelope.
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
    'erro_mensagem', e.erro_mensagem,
    'documento_assinado_disponivel', exists(
      select 1 from public.documentos_assinados da where da.envelope_id = e.id and da.validado = true
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
  where e.contrato_id = p_contrato_id and e.tipo_documento = 'CONTRATO'
  order by e.criado_em desc
  limit 1;
$$;

-- ============================================================================
-- 16) pricing_proposal_update_display_fields — bloqueia edição depois do aceite/
--     contrato (seção 11 do pedido: "alterar proposta aceita" precisa ser bloqueado).
--     Antes desta correção, a única barreira era a RLS (que libera DIRETOR/ADMINISTRADOR
--     em qualquer status) — bug real confirmado por leitura de código: nada impedia
--     editar a capa de uma proposta já ACEITA_PELO_PARCEIRO/CONTRATO_GERADO.
-- ============================================================================

create or replace function public.pricing_proposal_update_display_fields(
  p_proposta_id uuid,
  p_parceiro_nome_capa text default null,
  p_parceiro_cargo_contato text default null,
  p_observacoes_comerciais text default null,
  p_proximos_passos text default null
)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_before public.propostas_comerciais;
  v_row public.propostas_comerciais;
begin
  select * into v_before from public.propostas_comerciais where id = p_proposta_id;
  if v_before.id is null then
    raise exception 'NAO_ENCONTRADA: proposta % não encontrada ou sem permissão de leitura.', p_proposta_id;
  end if;

  if v_before.status in ('ACEITA_PELO_PARCEIRO', 'CONTRATO_GERADO', 'ASSINADA', 'RECUSADA_PELO_PARCEIRO', 'EXPIRADA', 'CANCELADA') then
    raise exception 'STATUS_INVALIDO: proposta % está em status % — não pode mais ser editada (o parceiro já aceitou/recusou, ou a proposta está encerrada). Para mudar condições, crie uma Nova Versão.', p_proposta_id, v_before.status;
  end if;

  update public.propostas_comerciais
     set parceiro_nome_capa = coalesce(p_parceiro_nome_capa, parceiro_nome_capa),
         parceiro_cargo_contato = coalesce(p_parceiro_cargo_contato, parceiro_cargo_contato),
         observacoes_comerciais = coalesce(p_observacoes_comerciais, observacoes_comerciais),
         proximos_passos = coalesce(p_proximos_passos, proximos_passos)
   where id = p_proposta_id
   returning * into v_row;

  if v_row.id is null then
    raise exception 'PERMISSAO_NEGADA: sem permissão de editar esta proposta (RLS propostas_comerciais_update — só o dono com status RASCUNHO, ou DIRETOR/ADMINISTRADOR).';
  end if;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_row.id, 'PROPOSAL_UPDATED',
    'Campos de exibição/comerciais atualizados (capa e/ou observações comerciais e/ou próximos passos).',
    to_jsonb(v_before), to_jsonb(v_row));

  return v_row;
end;
$$;

comment on function public.pricing_proposal_update_display_fields is 'Fase 3.10, corrigida na Fase 3.11.2 (seção 11 do pedido de correção): agora bloqueia explicitamente qualquer edição depois de ACEITA_PELO_PARCEIRO/CONTRATO_GERADO/ASSINADA/RECUSADA_PELO_PARCEIRO/EXPIRADA/CANCELADA — antes disso a única barreira era a RLS, que libera DIRETOR/ADMINISTRADOR em qualquer status (bug real, confirmado por leitura de código).';
