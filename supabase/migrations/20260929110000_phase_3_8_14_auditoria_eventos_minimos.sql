-- OptiMon — Fase 3.8 (item 3.8-14): auditoria — eventos mínimos faltantes.
--
-- INVESTIGAÇÃO PRÉVIA (refeita do zero, não presumida): public.auditoria já tem um campo
-- semântico (`acao`, restrito por check constraint) e uma função dedicada
-- (app.registrar_auditoria_semantica) usada por dezenas de fluxos de negócio, além do
-- trigger genérico fn_auditoria (INSERT/UPDATE/DELETE cru) presente em ~30 tabelas. Dos 9
-- tipos de evento apontados como faltantes:
--   - PON_ADDED/PON_REMOVED, POP_ADDED/POP_REMOVED, CLIENT_RESERVED_REMOVED,
--     THIRD_PARTY_INFRA_REQUEST/APPROVED, OWN_NETWORK_EXCEPTION: a LINHA que muda já é
--     gravada pelo trigger genérico (quem/quando/antes/depois) — a lacuna real é só
--     semântica (não dá pra filtrar "todo POP removido" sem vasculhar entidade+jsonb).
--   - CONTRACT_TERMINATED: lacuna REAL de funcionalidade — não existe hoje nenhuma rota
--     de API nem função SQL para encerrar/rescindir um contrato (contrato_status já tem
--     ENCERRADO/RESCINDIDO no enum, mas nada os escreve). Corrigido nesta migration com
--     app.encerrar_contrato(), no mesmo padrão de app.ativar_contrato() (Fase 2.5).
--   - Achado adicional (não fazia parte da lista original, mas é da mesma classe de bug):
--     CONTRACT_RESERVED_CLIENT_ADD/CONTRACT_RESERVED_CLIENT_UPDATE já estavam na whitelist
--     de app.registrar_auditoria_semantica desde a Fase 3 (20260925090000) mas NUNCA eram
--     chamados — api/routes/contracts.js insere/atualiza contrato_clientes_reservados
--     direto via supabase-js, sem nenhuma chamada semântica. Mais um rótulo "morto".
--     Corrigido via trigger nesta migration (sem tocar a rota).

-- ============================================================================
-- 1) Amplia a whitelist de ações semânticas (tabela + função) — aditivo, nunca remove
--    nenhum rótulo existente.
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
  -- Fase 3.8 (item 3.8-14) — rótulos novos:
  'PON_ADDED','PON_REMOVED','POP_ADDED','POP_REMOVED','CLIENT_RESERVED_REMOVED',
  'CONTRACT_TERMINATED','THIRD_PARTY_INFRA_REQUEST','THIRD_PARTY_INFRA_APPROVED',
  'OWN_NETWORK_EXCEPTION_REQUEST','OWN_NETWORK_EXCEPTION'
]));

create or replace function app.registrar_auditoria_semantica(p_entidade text, p_entidade_id uuid, p_acao text, p_motivo text default null, p_valor_anterior jsonb default null, p_valor_novo jsonb default null)
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
    -- Fase 3.8 (item 3.8-14):
    'PON_ADDED', 'PON_REMOVED', 'POP_ADDED', 'POP_REMOVED', 'CLIENT_RESERVED_REMOVED',
    'CONTRACT_TERMINATED', 'THIRD_PARTY_INFRA_REQUEST', 'THIRD_PARTY_INFRA_APPROVED',
    'OWN_NETWORK_EXCEPTION_REQUEST', 'OWN_NETWORK_EXCEPTION'
  ) then
    raise exception 'app.registrar_auditoria_semantica: ação inválida %.', p_acao;
  end if;

  begin
    v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', '')::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.auditoria (usuario_id, ip, acao, entidade, entidade_id, valor_anterior, valor_novo, origem, motivo)
  values (auth.uid(), v_ip, p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, 'app', p_motivo);
end;
$function$;

comment on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb) is 'Fase 2.3.1, ampliada na Fase 3.8 (item 3.8-14) com 10 rótulos novos (PON/POP added/removed, exceções de fibra de terceiros/rede própria, encerramento de contrato, cliente reservado liberado).';

-- ============================================================================
-- 2) PON_ADDED / PON_REMOVED — trigger dedicado em infra_portas_pon. "Removido" aqui é o
--    equivalente semântico do arquivamento já existente (status → INATIVA, ver
--    api/routes/infra.js POST /pon-ports/:id/archive) — este trigger AFTER complementa o
--    ARCHIVE genérico já emitido por lá com um rótulo específico e filtrável.
-- ============================================================================
create or replace function public.fn_aud_infra_portas_pon_semantico()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if TG_OP = 'INSERT' then
    perform app.registrar_auditoria_semantica('infra_portas_pon', new.id, 'PON_ADDED', null, null, to_jsonb(new));
  elsif TG_OP = 'UPDATE' and new.status = 'INATIVA' and old.status is distinct from 'INATIVA' then
    perform app.registrar_auditoria_semantica('infra_portas_pon', new.id, 'PON_REMOVED', null, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$$;

create trigger trg_aud_infra_portas_pon_semantico
  after insert or update on public.infra_portas_pon
  for each row execute function public.fn_aud_infra_portas_pon_semantico();

comment on function public.fn_aud_infra_portas_pon_semantico() is 'Fase 3.8 (item 3.8-14): emite PON_ADDED/PON_REMOVED em complemento ao trigger genérico trg_aud_infra_portas_pon (que continua gravando INSERT/UPDATE/DELETE cru) — nunca o substitui.';

-- ============================================================================
-- 3) POP_ADDED / POP_REMOVED — mesmo padrão em infra_pops ("removido" = removido_em
--    preenchido pela 1ª vez, via public.pricing_pop_archive já existente).
-- ============================================================================
create or replace function public.fn_aud_infra_pops_semantico()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if TG_OP = 'INSERT' then
    perform app.registrar_auditoria_semantica('infra_pops', new.id, 'POP_ADDED', null, null, to_jsonb(new));
  elsif TG_OP = 'UPDATE' and new.removido_em is not null and old.removido_em is null then
    perform app.registrar_auditoria_semantica('infra_pops', new.id, 'POP_REMOVED', null, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$$;

create trigger trg_aud_infra_pops_semantico
  after insert or update on public.infra_pops
  for each row execute function public.fn_aud_infra_pops_semantico();

comment on function public.fn_aud_infra_pops_semantico() is 'Fase 3.8 (item 3.8-14): emite POP_ADDED/POP_REMOVED em complemento ao trigger genérico trg_aud_infra_pops.';

-- ============================================================================
-- 4) CONTRACT_RESERVED_CLIENT_ADD (finalmente conectado — rótulo existia desde a Fase 3
--    sem nenhum chamador) e CLIENT_RESERVED_REMOVED — não existe rota de exclusão física
--    de cliente reservado (api/routes/contracts.js só tem POST de criação e PATCH de
--    status RESERVADO/LIBERADO); "removido" no sentido de negócio é a liberação
--    (status → LIBERADO), que é o evento real que existe no sistema hoje.
-- ============================================================================
create or replace function public.fn_aud_clientes_reservados_semantico()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if TG_OP = 'INSERT' then
    perform app.registrar_auditoria_semantica('contrato_clientes_reservados', new.id, 'CONTRACT_RESERVED_CLIENT_ADD', null, null, to_jsonb(new));
  elsif TG_OP = 'UPDATE' and new.status = 'LIBERADO' and old.status is distinct from 'LIBERADO' then
    perform app.registrar_auditoria_semantica('contrato_clientes_reservados', new.id, 'CLIENT_RESERVED_REMOVED', null, to_jsonb(old), to_jsonb(new));
  elsif TG_OP = 'UPDATE' then
    perform app.registrar_auditoria_semantica('contrato_clientes_reservados', new.id, 'CONTRACT_RESERVED_CLIENT_UPDATE', null, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$$;

create trigger trg_aud_clientes_reservados_semantico
  after insert or update on public.contrato_clientes_reservados
  for each row execute function public.fn_aud_clientes_reservados_semantico();

comment on function public.fn_aud_clientes_reservados_semantico() is 'Fase 3.8 (item 3.8-14): finalmente conecta CONTRACT_RESERVED_CLIENT_ADD/UPDATE (rótulos "mortos" desde a Fase 3) e adiciona CLIENT_RESERVED_REMOVED (liberação de reserva — não existe exclusão física de cliente reservado no sistema).';

-- ============================================================================
-- 5) THIRD_PARTY_INFRA_REQUEST/APPROVED e OWN_NETWORK_EXCEPTION_REQUEST/EXCEPTION —
--    trigger dedicado em contrato_regras_solicitacoes (workflow de 3 etapas, item
--    3.8-09/10), em complemento a fn_regra_solicitacao_aplica_excecao (que já aplica o
--    EFEITO da aprovação, mas não emitia nenhum rótulo semântico de auditoria).
-- ============================================================================
create or replace function public.fn_aud_regra_solicitacao_semantico()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_acao_request text;
  v_acao_aprovada text;
begin
  v_acao_request := case new.tipo when 'FIBRA_TERCEIROS' then 'THIRD_PARTY_INFRA_REQUEST' else 'OWN_NETWORK_EXCEPTION_REQUEST' end;
  v_acao_aprovada := case new.tipo when 'FIBRA_TERCEIROS' then 'THIRD_PARTY_INFRA_APPROVED' else 'OWN_NETWORK_EXCEPTION' end;

  if TG_OP = 'INSERT' then
    perform app.registrar_auditoria_semantica('contrato_regras_solicitacoes', new.id, v_acao_request, new.descricao, null, to_jsonb(new));
  elsif TG_OP = 'UPDATE' and new.status = 'APROVADA' and old.status is distinct from 'APROVADA' then
    perform app.registrar_auditoria_semantica('contrato_regras_solicitacoes', new.id, v_acao_aprovada, null, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$$;

create trigger trg_aud_regra_solicitacao_semantico
  after insert or update on public.contrato_regras_solicitacoes
  for each row execute function public.fn_aud_regra_solicitacao_semantico();

comment on function public.fn_aud_regra_solicitacao_semantico() is 'Fase 3.8 (item 3.8-14): THIRD_PARTY_INFRA_REQUEST/APPROVED (tipo=FIBRA_TERCEIROS) e OWN_NETWORK_EXCEPTION_REQUEST/OWN_NETWORK_EXCEPTION (tipo=REDE_PROPRIA), em complemento ao trigger genérico e ao efeito já aplicado por fn_regra_solicitacao_aplica_excecao.';

-- ============================================================================
-- 6) CONTRACT_TERMINATED — lacuna REAL: não existia nenhuma forma de encerrar/rescindir
--    um contrato. app.encerrar_contrato() segue o mesmo padrão de app.ativar_contrato()
--    (Fase 2.5): SECURITY DEFINER com checagem de RBAC explícita, motivo obrigatório,
--    desvincula toda infraestrutura ainda ativa (reaproveita o trigger já existente
--    fn_contrato_fibras_sync_status, que libera infra_fibras.status automaticamente).
-- ============================================================================
alter table public.contratos
  add column data_fim_real date,
  add column motivo_encerramento text;
comment on column public.contratos.data_fim_real is 'Fase 3.8 (item 3.8-14): data efetiva de encerramento/rescisão — preenchida só por app.encerrar_contrato(), nunca editável diretamente. Distinta de data_fim_prevista (calculada a partir do prazo contratual).';
comment on column public.contratos.motivo_encerramento is 'Fase 3.8 (item 3.8-14): motivo obrigatório do encerramento/rescisão — nunca um contrato é encerrado sem justificativa registrada.';

create or replace function app.encerrar_contrato(p_contrato_id uuid, p_tipo contrato_status, p_motivo text)
returns public.contratos
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_contrato public.contratos;
begin
  if not app.tem_perfil('DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só DIRETOR/ADMINISTRADOR podem encerrar/rescindir um contrato.';
  end if;

  if p_tipo not in ('ENCERRADO', 'RESCINDIDO') then
    raise exception 'VALIDATION: tipo deve ser ENCERRADO (fim natural do prazo) ou RESCINDIDO (encerramento antecipado/por descumprimento).';
  end if;

  if p_motivo is null or trim(p_motivo) = '' then
    raise exception 'VALIDATION: motivo do encerramento é obrigatório.';
  end if;

  select * into v_contrato from public.contratos where id = p_contrato_id;
  if v_contrato.id is null then
    raise exception 'NAO_ENCONTRADO: contrato % não encontrado.', p_contrato_id;
  end if;

  if v_contrato.status not in ('ATIVO', 'SUSPENSO') then
    raise exception 'STATUS_INVALIDO: contrato % está em status % — só um contrato ATIVO ou SUSPENSO pode ser encerrado/rescindido por aqui.', v_contrato.numero, v_contrato.status;
  end if;

  -- Desvincula toda infraestrutura ainda ativa — reaproveita fn_contrato_fibras_sync_status
  -- (já existente desde a Fase 1), que libera infra_fibras.status = 'LIVRE' automaticamente
  -- a cada linha desvinculada. Nunca libera infraestrutura "por baixo" sem esse rastro.
  update public.contrato_fibras
     set desvinculado_em = now()
   where contrato_id = v_contrato.id and desvinculado_em is null;

  update public.contratos
     set status = p_tipo,
         data_fim_real = current_date,
         motivo_encerramento = p_motivo
   where id = v_contrato.id
   returning * into v_contrato;

  perform app.registrar_auditoria_semantica('contratos', v_contrato.id, 'CONTRACT_TERMINATED', p_motivo, null, to_jsonb(v_contrato));

  return v_contrato;
end;
$$;

comment on function app.encerrar_contrato(uuid, contrato_status, text) is 'Fase 3.8 (item 3.8-14): encerra (fim natural) ou rescinde (antecipado) um contrato ATIVO/SUSPENSO — motivo sempre obrigatório, desvincula infraestrutura automaticamente, emite CONTRACT_TERMINATED. Único caminho de escrita para contrato_status = ENCERRADO/RESCINDIDO — não existia nenhum antes desta migration.';

create or replace function public.pricing_contract_terminate(p_contrato_id uuid, p_tipo text, p_motivo text)
returns public.contratos
language sql
security invoker
as $$
  select app.encerrar_contrato(p_contrato_id, p_tipo::contrato_status, p_motivo);
$$;
comment on function public.pricing_contract_terminate(uuid, text, text) is 'Fase 3.8 (item 3.8-14) — wrapper público de app.encerrar_contrato, mesmo padrão dos outros wrappers pricing_*.';
grant execute on function public.pricing_contract_terminate(uuid, text, text) to authenticated;
