-- OptiMon — Fase 3, item 3.8: exclusão FÍSICA controlada de usuário (só ADMINISTRADOR —
-- não existe perfil "OWNER" separado neste RBAC de 6 perfis, "OWNER" do prompt-mestre
-- mapeia para ADMINISTRADOR).
--
-- Até aqui só existia soft-delete (usuarios.ativo, ver POST /:id/deactivate) — nenhuma
-- rota jamais fazia DELETE físico. A coluna `usuarios.removido_em` existe desde a Fase 1
-- mas nunca era escrita por ninguém (achado ao investigar este item).
--
-- POR QUE "CONTROLADA": public.usuarios é referenciado por FK (sem ON DELETE CASCADE/SET
-- NULL — todas NO ACTION, o padrão do Postgres) a partir de ~19 tabelas, entre elas
-- public.auditoria.usuario_id. A auditoria é IMUTÁVEL (nunca UPDATE/DELETE) — então a
-- exclusão física NUNCA pode apagar/alterar uma linha de auditoria para "liberar" o
-- usuário. Em vez disso, esta função varre exaustivamente toda tabela que referencia
-- usuarios(id) e BLOQUEIA a exclusão (com a lista exata do que está bloqueando) sempre
-- que existir qualquer vínculo — cobrindo exatamente o caso de uso real de "exclusão
-- física controlada": remover um cadastro criado por engano/duplicado/teste ANTES de ele
-- ter qualquer atividade real no sistema. Para qualquer usuário com histórico, o caminho
-- correto continua sendo a desativação (soft-delete, já existente) — nunca esta função.
--
-- Salvaguardas adicionais: motivo obrigatório; ninguém pode excluir a si mesmo; nunca
-- remove o último ADMINISTRADOR ativo (travaria o próprio sistema); e o evento é sempre
-- gravado na auditoria (via app.registrar_auditoria_semantica, SECURITY DEFINER) ANTES do
-- DELETE em si — mesmo depois do usuário não existir mais em public.usuarios, o registro
-- de quem foi excluído, por quem e por quê permanece para sempre (auditoria.entidade_id
-- não tem FK — é só um uuid genérico usado por todo tipo de entidade, então continua
-- resolvendo/consultável sem violar nenhuma restrição, mesmo "apontando" para um usuário
-- que não existe mais).
--
-- A remoção da IDENTIDADE em auth.users (Supabase Auth) é um passo SEPARADO, feito pela
-- API depois que esta função confirma que o DELETE em public.usuarios teve sucesso — a
-- FK `usuarios.id references auth.users(id) on delete restrict` já impedia deletar a
-- identidade Auth enquanto o perfil existisse, então a ordem (perfil primeiro, Auth
-- depois) é obrigatória. Essa chamada à Auth Admin API usa a mesma exceção já documentada
-- em api/lib/supabaseAdmin.js — nunca é feita aqui em SQL.

-- CORREÇÃO (achada ao testar esta migration): public.auditoria tem uma constraint CHECK
-- própria (auditoria_acao_check) — uma segunda lista de ações permitidas, SEPARADA da
-- lista dentro de app.registrar_auditoria_semantica. A migration da Fase 3 item 3.7
-- (20260925090000) só atualizou a lista dentro da função e esqueceu esta constraint —
-- CONTRACT_MINUTA_EXPORT/CONTRACT_RULES_UPDATE/CONTRACT_RESERVED_CLIENT_ADD/
-- CONTRACT_RESERVED_CLIENT_UPDATE teriam falhado com "violates check constraint
-- auditoria_acao_check" na primeira chamada real (reproduzido durante o smoke test desta
-- migration, ao testar USER_HARD_DELETE). Corrigido aqui recriando a constraint com a
-- MESMA lista completa (todas as ações já existentes + as 4 da Fase 3.7 + USER_HARD_DELETE
-- desta fase) — nenhuma ação antiga removida.
alter table public.auditoria drop constraint if exists auditoria_acao_check;
alter table public.auditoria add constraint auditoria_acao_check
  check (acao = any (array[
    'INSERT', 'UPDATE', 'DELETE', 'LOGIN',
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
    -- Fase 3, item 3.7 (corrigido aqui — faltava nesta constraint):
    'CONTRACT_MINUTA_EXPORT', 'CONTRACT_RULES_UPDATE', 'CONTRACT_RESERVED_CLIENT_ADD', 'CONTRACT_RESERVED_CLIENT_UPDATE',
    -- Fase 3, item 3.8:
    'USER_HARD_DELETE'
  ]));

comment on constraint auditoria_acao_check on public.auditoria is 'Fase 3 (item 3.8): corrige um gap da migration da Fase 3.7 (que só tinha atualizado a whitelist dentro da função, não esta constraint) e acrescenta USER_HARD_DELETE. Mantém 100% das ações já existentes — nenhuma removida.';

create or replace function app.registrar_auditoria_semantica(
  p_entidade text,
  p_entidade_id uuid,
  p_acao text,
  p_motivo text default null,
  p_valor_anterior jsonb default null,
  p_valor_novo jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
    'USER_HARD_DELETE'
  ) then
    raise exception 'app.registrar_auditoria_semantica: ação inválida %.', p_acao;
  end if;

  begin
    v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', '')::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.auditoria (usuario_id, ip, acao, entidade, entidade_id, valor_anterior, valor_novo, motivo, origem)
  values (auth.uid(), v_ip, p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, p_motivo, 'API');
end;
$$;

comment on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb) is 'Fase 3 (item 3.8): mesma função desde a Fase 2.3.1 — só a whitelist interna cresceu (USER_HARD_DELETE). SECURITY DEFINER para poder inserir em auditoria mesmo sem policy de INSERT para authenticated; sempre grava auth.uid() do chamador, nunca um usuario_id arbitrário vindo de parâmetro.';

create or replace function app.excluir_usuario_fisicamente(p_usuario_id uuid, p_motivo text)
returns void
language plpgsql
security invoker
as $$
declare
  v_usuario public.usuarios%rowtype;
  v_bloqueios text[] := array[]::text[];
  v_count integer;
  v_outros_admins integer;
begin
  -- Checagem explícita (não só RLS): esta função grava auditoria via helper
  -- SECURITY DEFINER antes do DELETE, então precisa recusar ANTES disso — se
  -- dependesse só da RLS da tabela, um não-ADMINISTRADOR passaria por todo o
  -- resto e só o DELETE final seria silenciosamente ignorado (0 linhas), com
  -- um evento de auditoria "USER_HARD_DELETE" gravado por engano.
  if not app.tem_perfil('ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só ADMINISTRADOR pode excluir fisicamente um usuário.';
  end if;

  if p_motivo is null or trim(p_motivo) = '' then
    raise exception 'MOTIVO_OBRIGATORIO: a exclusão física exige um motivo explícito.';
  end if;

  if p_usuario_id = auth.uid() then
    raise exception 'NAO_PERMITIDO: você não pode excluir fisicamente o próprio usuário.';
  end if;

  select * into v_usuario from public.usuarios where id = p_usuario_id and removido_em is null;
  if not found then
    raise exception 'NAO_ENCONTRADO: usuário % não encontrado (ou já removido).', p_usuario_id;
  end if;

  if v_usuario.perfil = 'ADMINISTRADOR' then
    select count(*) into v_outros_admins from public.usuarios
      where perfil = 'ADMINISTRADOR' and ativo = true and removido_em is null and id <> p_usuario_id;
    if v_outros_admins = 0 then
      raise exception 'ULTIMO_ADMINISTRADOR: não é possível excluir o último ADMINISTRADOR ativo do sistema.';
    end if;
  end if;

  -- Varredura exaustiva de toda tabela que referencia usuarios(id) (ver
  -- levantamento no cabeçalho desta migration) — nunca apaga/altera nada
  -- dessas tabelas, só verifica existência para decidir bloquear ou não.
  select count(*) into v_count from public.auditoria where usuario_id = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('auditoria (%s)', v_count)); end if;

  select count(*) into v_count from public.contratos where aprovado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('contratos.aprovado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.contrato_versions where criado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('contrato_versions.criado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.ativos_devolucao where registrado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('ativos_devolucao.registrado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.contrato_regras_solicitacoes where solicitado_por = p_usuario_id or decidido_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('contrato_regras_solicitacoes (%s)', v_count)); end if;

  select count(*) into v_count from public.medicoes_mensais where aprovado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('medicoes_mensais.aprovado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.pricing_parametros where criado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('pricing_parametros.criado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.pricing_versions where criado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('pricing_versions.criado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.simulacoes where criado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('simulacoes.criado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.indices_economicos where validado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('indices_economicos.validado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.alertas where resolvido_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('alertas.resolvido_por (%s)', v_count)); end if;

  select count(*) into v_count from public.documentos where criado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('documentos.criado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.contrato_aditivos where aprovado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('contrato_aditivos.aprovado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.custos_infraestrutura where criado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('custos_infraestrutura.criado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.pricing_override_requests where solicitado_por = p_usuario_id or decidido_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('pricing_override_requests (%s)', v_count)); end if;

  select count(*) into v_count from public.propostas_comerciais where criado_por = p_usuario_id or autorizado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('propostas_comerciais (%s)', v_count)); end if;

  select count(*) into v_count from public.signature_envelopes where criado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('signature_envelopes.criado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.documentos_assinados where validado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('documentos_assinados.validado_por (%s)', v_count)); end if;

  select count(*) into v_count from public.modelos_contrato where aprovado_por = p_usuario_id;
  if v_count > 0 then v_bloqueios := array_append(v_bloqueios, format('modelos_contrato.aprovado_por (%s)', v_count)); end if;

  if array_length(v_bloqueios, 1) > 0 then
    raise exception 'USUARIO_POSSUI_HISTORICO: não é possível excluir fisicamente — existem registros vinculados em: %. Use a desativação (soft-delete, já existente) em vez disso — ela preserva o histórico/auditoria e bloqueia o acesso do usuário imediatamente.', array_to_string(v_bloqueios, '; ');
  end if;

  -- Grava a auditoria ANTES do DELETE — depois disso o usuário não existe mais
  -- em public.usuarios, mas o registro de quem/quando/por quê permanece para
  -- sempre (auditoria nunca é apagada/alterada).
  perform app.registrar_auditoria_semantica(
    'usuarios', p_usuario_id, 'USER_HARD_DELETE', p_motivo,
    to_jsonb(v_usuario) - 'cpf', -- nunca grava CPF (documento sensível) na auditoria — nome/email/perfil já bastam para rastreabilidade
    null
  );

  delete from public.usuarios where id = p_usuario_id;
end;
$$;

comment on function app.excluir_usuario_fisicamente(uuid, text) is 'Fase 3 (item 3.8): exclusão FÍSICA controlada de usuário — só ADMINISTRADOR, motivo obrigatório, nunca a si mesmo, nunca o último ADMINISTRADOR ativo, e SEMPRE bloqueada se existir qualquer vínculo em auditoria/aprovações/criações (auditoria é imutável — a exclusão física nunca a altera, só é recusada quando ela existiria). Ver cabeçalho da migration para a lista completa de tabelas verificadas.';

create or replace function public.pricing_usuario_excluir_fisicamente(p_usuario_id uuid, p_motivo text)
returns void language sql as $$ select app.excluir_usuario_fisicamente(p_usuario_id, p_motivo); $$;
grant execute on function public.pricing_usuario_excluir_fisicamente(uuid, text) to authenticated;
