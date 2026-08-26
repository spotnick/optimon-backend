-- OptiMon — Fase 2.3.1: CRUD completo (Cidades, POPs, Segmentos, Cabos, Fibras,
-- Postes, Portas PON e demais ativos de infraestrutura).
-- Migration 1/4: fundação de auditoria semântica (ARCHIVE/RESTORE/BLOCKED_ARCHIVE/
-- BLOCKED_DELETE, seção 28) + o primeiro RESTAURAR real do módulo (cidade — a Fase 2.3
-- só tinha ARQUIVAR, seção 21 desta fase pede RESTAURAR para todas as entidades).
--
-- DECISÃO DE ARQUITETURA (documentada aqui e no relatório final): a auditoria genérica
-- por trigger (fn_auditoria(), existente desde a Fase 1) já registra toda alteração como
-- 'UPDATE' com dados anteriores/novos — isso nunca muda nesta fase. O que faltava é a
-- seção 28 pedir rótulos semânticos (ARCHIVE/RESTORE/BLOCKED_ARCHIVE/BLOCKED_DELETE)
-- distintos de um UPDATE genérico. Em vez de reescrever o trigger (arriscado, tocaria
-- toda tabela auditada desde a Fase 1), cada função de arquivar/restaurar desta fase
-- insere UMA linha semântica adicional via app.registrar_auditoria_semantica — logo,
-- um arquivamento bem-sucedido gera 2 linhas de auditoria (a UPDATE genérica do trigger
-- + a ARCHIVE semântica com o motivo), o que é intencional, não duplicação por acidente.
--
-- Para o caso BLOCKED_ARCHIVE/BLOCKED_DELETE (seção 28) há um problema real: a função
-- SQL bloqueia com RAISE EXCEPTION (mesmo padrão testado e aprovado desde a Fase 2.3),
-- e uma exceção desfaz TODA a transação — inclusive qualquer INSERT feito na auditoria
-- antes do RAISE. Por isso o registro de BLOCKED_* não é feito dentro da função SQL que
-- bloqueia; é a API (api/routes/*.js) que, ao capturar o erro de bloqueio (uma
-- transação já abortada) chama public.pricing_log_blocked_action em uma SEGUNDA chamada
-- RPC — uma transação nova, que persiste mesmo com a primeira tendo sido desfeita.

-- ============================================================================
-- 1) auditoria_acao_check — amplia para ARCHIVE/RESTORE/BLOCKED_ARCHIVE/BLOCKED_DELETE
--    (aditivo: INSERT/UPDATE/DELETE/LOGIN, já ampliado na Fase 2.2.1 Parte 2, preservados).
-- ============================================================================

alter table public.auditoria drop constraint if exists auditoria_acao_check;
alter table public.auditoria add constraint auditoria_acao_check
  check (acao = any (array['INSERT', 'UPDATE', 'DELETE', 'LOGIN', 'ARCHIVE', 'RESTORE', 'BLOCKED_ARCHIVE', 'BLOCKED_DELETE']));

-- ============================================================================
-- 2) app.registrar_auditoria_semantica — uso interno (não exposta ao PostgREST). Único
--    propósito: inserir em auditoria (que não tem policy de INSERT para authenticated,
--    por design, desde a Fase 1) sem dar a nenhuma função de escrita normal privilégio
--    amplo de SECURITY DEFINER — só esta função, de escopo mínimo, roda como definer.
-- ============================================================================

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
begin
  if p_acao not in ('ARCHIVE', 'RESTORE', 'BLOCKED_ARCHIVE', 'BLOCKED_DELETE') then
    raise exception 'app.registrar_auditoria_semantica: ação inválida %.', p_acao;
  end if;

  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, valor_anterior, valor_novo, motivo, origem)
  values (auth.uid(), p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, p_motivo, 'API');
end;
$$;
comment on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb) is 'Fase 2.3.1 (seção 28): insere uma linha de auditoria semântica (ARCHIVE/RESTORE/BLOCKED_ARCHIVE/BLOCKED_DELETE), sempre com auth.uid() do chamador — nunca um usuario_id arbitrário. SECURITY DEFINER só para poder inserir em auditoria (sem policy de INSERT para authenticated, mesmo motivo de public.pricing_log_login desde a Fase 2.2.1 Parte 2). Uso interno — chamada só pelas funções app.arquivar_*/app.restaurar_* desta migration em diante.';

-- Nunca exposta a PostgREST diretamente — app não está em db-schemas (só "public"), então
-- nenhum cliente HTTP alcança esta função de jeito nenhum, com ou sem GRANT. Só é
-- alcançável via chamada SQL interna partindo de app.arquivar_*/app.restaurar_* (todas
-- SECURITY INVOKER, de propósito — preservam RLS/tem_perfil() avaliados como o usuário
-- real, não como o dono da função) ou de public.pricing_log_blocked_action (essa sim
-- SECURITY DEFINER). Privilégio de EXECUTE é sempre checado contra o current_user no
-- ponto da chamada — para uma função SECURITY INVOKER isso é o próprio "authenticated",
-- nunca o dono da função por herança — por isso authenticated PRECISA do GRANT explícito
-- abaixo (um REVOKE aqui, como uma versão anterior desta migration tinha, quebra TODO
-- arquivamento/restauração do sistema com "permission denied for function
-- registrar_auditoria_semantica" assim que chamado pelo caminho HTTP autenticado real —
-- só não aparecia em teste manual via psql porque optimon_admin, dono da função, nunca
-- precisa desse grant).
grant execute on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb) to authenticated;

-- ============================================================================
-- 3) public.pricing_log_blocked_action — chamada pela API (nunca pelo frontend
--    diretamente) depois de capturar um erro de bloqueio de arquivamento/exclusão.
--    Restringe p_acao a só BLOCKED_ARCHIVE/BLOCKED_DELETE — nunca deixa a API gravar
--    um ARCHIVE/RESTORE "de verdade" por aqui (esses só saem das funções app.* que
--    fazem a mudança de estado de fato, nunca da API sozinha).
-- ============================================================================

create or replace function public.pricing_log_blocked_action(
  p_entidade text,
  p_entidade_id uuid,
  p_acao text,
  p_motivo text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_acao not in ('BLOCKED_ARCHIVE', 'BLOCKED_DELETE') then
    raise exception 'pricing_log_blocked_action: só aceita BLOCKED_ARCHIVE ou BLOCKED_DELETE (recebido %).', p_acao;
  end if;
  perform app.registrar_auditoria_semantica(p_entidade, p_entidade_id, p_acao, p_motivo);
end;
$$;
comment on function public.pricing_log_blocked_action(text, uuid, text, text) is 'Fase 2.3.1 (seção 28): chamada pela API logo após capturar um 409 de arquivamento/exclusão bloqueados — registra o evento numa transação própria (a que tentou arquivar já foi desfeita pelo RAISE EXCEPTION). Nunca aceita ARCHIVE/RESTORE, só os dois BLOCKED_*.';

grant execute on function public.pricing_log_blocked_action(text, uuid, text, text) to authenticated;

-- ============================================================================
-- 4) app.arquivar_cidade — ganha p_motivo/p_observacao (seção 29) e passa a registrar
--    ARCHIVE semântico no sucesso. Mesmo comportamento de bloqueio (RAISE EXCEPTION) da
--    Fase 2.3 — só parâmetros novos no final. IMPORTANTE (mesmo bug já visto e corrigido
--    nas Fases 2.2/2.2.1): CREATE OR REPLACE com parâmetros novos no final NÃO substitui
--    a função de 1 argumento, cria uma segunda função sobrecarregada — e qualquer chamada
--    antiga com só o uuid vira ambígua ("function ... is not unique"). DROP explícito
--    antes evita isso, como em todas as fases anteriores que mexeram em assinatura.
-- ============================================================================

drop function if exists app.arquivar_cidade(uuid);

create or replace function app.arquivar_cidade(p_cidade_id uuid, p_motivo text default null, p_observacao text default null)
returns void
language plpgsql
security invoker
as $$
declare
  v_contratos_ativos integer;
begin
  if not app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode arquivar cidades — só ENGENHARIA ou ADMINISTRADOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.cidades_infra where id = p_cidade_id and removido_em is null) then
    raise exception 'Cidade % não encontrada (ou já arquivada).', p_cidade_id;
  end if;

  select count(*) into v_contratos_ativos
  from public.contratos
  where cidade_id = p_cidade_id and status = 'ATIVO';

  if v_contratos_ativos > 0 then
    raise exception 'Não é possível arquivar uma cidade com contrato ativo.';
  end if;

  update public.cidades_infra set removido_em = now() where id = p_cidade_id;

  perform app.registrar_auditoria_semantica(
    'cidades_infra', p_cidade_id, 'ARCHIVE',
    coalesce(p_motivo, 'Não informado') || coalesce(': ' || nullif(btrim(p_observacao), ''), '')
  );
end;
$$;
comment on function app.arquivar_cidade(uuid, text, text) is 'Fase 2.3.1 (seção 6/29): POST /api/cities/:id/archive. Bloqueia com contrato ATIVO (mensagem literal preservada da Fase 2.3). p_motivo/p_observacao (seção 29) vão para a auditoria semântica ARCHIVE.';

-- ============================================================================
-- 5) app.restaurar_cidade — a novidade real desta fase para cidade (seção 6/21):
--    limpa removido_em, exige ADMINISTRADOR/DIRETOR (seção 21 — restauração é mais
--    sensível que arquivar, então mais restrita que app.tem_perfil('ENGENHARIA', ...)).
-- ============================================================================

-- BUG REAL ENCONTRADO EM TESTE (regressão completa desta fase): DIRETOR "restaura" uma
-- cidade, a API responde 200, a auditoria semântica RESTORE é gravada — mas
-- removido_em NUNCA volta a NULL. Causa raiz: esta função era SECURITY INVOKER, então o
-- `update public.cidades_infra ...` roda com o RLS do chamador real. A policy
-- "cidades_infra_update" (FOR UPDATE) só permite ENGENHARIA/ADMINISTRADOR — DIRETOR não
-- está nela. Para ADMINISTRADOR a policy bate e o update funciona; para DIRETOR a policy
-- filtra a linha e o UPDATE afeta 0 linhas, SEM lançar erro nenhum (RLS não é uma
-- permissão binária que dá "permission denied": ela apenas restringe quais linhas o
-- comando enxerga, então um UPDATE sem linhas visíveis "funciona" e não muda nada). O
-- app.registrar_auditoria_semantica é chamado logo em seguida incondicionalmente, sem
-- checar quantas linhas o UPDATE realmente afetou — por isso a auditoria RESTORE e o
-- HTTP 200 mascaravam o bug (confirmado com uma query direta: cidade seguia com
-- removido_em preenchido após um DIRETOR "restaurar" com sucesso aparente).
--
-- Esta função já faz sua própria checagem explícita de RBAC (app.tem_perfil('ADMINISTRADOR',
-- 'DIRETOR')) logo no início — exatamente a mesma justificativa documentada acima para
-- app.registrar_auditoria_semantica ser SECURITY DEFINER: só eleva privilégio para uma
-- função que já se autoriza sozinha, nunca para pular a autorização. Convertendo para
-- SECURITY DEFINER (dono = optimon_admin, que não sofre RLS por ser dono das tabelas),
-- o UPDATE deixa de depender de o chamador também caber na policy de UPDATE da tabela —
-- que nunca foi pensada para cobrir "quem pode restaurar", só "quem pode editar".
create or replace function app.restaurar_cidade(p_cidade_id uuid, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tem_perfil('ADMINISTRADOR', 'DIRETOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode restaurar cidades — só ADMINISTRADOR ou DIRETOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.cidades_infra where id = p_cidade_id and removido_em is not null) then
    raise exception 'Cidade % não encontrada entre as arquivadas.', p_cidade_id;
  end if;

  update public.cidades_infra set removido_em = null where id = p_cidade_id;

  perform app.registrar_auditoria_semantica('cidades_infra', p_cidade_id, 'RESTORE', p_motivo);
end;
$$;
comment on function app.restaurar_cidade(uuid, text) is 'Fase 2.3.1 (seção 6/21): POST /api/cities/:id/restore. Só ADMINISTRADOR/DIRETOR (seção 21 — restaurar é mais sensível que arquivar). SECURITY DEFINER (bug real corrigido em teste: DIRETOR não está na policy de UPDATE de cidades_infra, então como SECURITY INVOKER o update silenciosamente afetava 0 linhas para DIRETOR). Limpa removido_em; registra RESTORE semântico.';

-- Mesmo GRANT explícito de EXECUTE que app.registrar_auditoria_semantica exige (ver
-- comentário longo acima): SECURITY DEFINER não muda quem pode CHAMAR a função, só quem
-- ela roda COMO depois de chamada — authenticated ainda precisa do EXECUTE para alcançá-la
-- a partir de public.pricing_city_restore (também SECURITY INVOKER, de propósito, para
-- preservar app.tem_perfil() avaliado como o usuário real na entrada da checagem).
grant execute on function app.restaurar_cidade(uuid, text) to authenticated;

-- ============================================================================
-- 6) Wrappers públicos — pricing_city_archive ganha parâmetros novos no final (mesmo
--    DROP explícito primeiro, mesmo motivo do item 4 acima); pricing_city_restore é novo.
-- ============================================================================

drop function if exists public.pricing_city_archive(uuid);

create or replace function public.pricing_city_archive(p_cidade_id uuid, p_motivo text default null, p_observacao text default null)
returns void
language sql
security invoker
as $$
  select app.arquivar_cidade(p_cidade_id, p_motivo, p_observacao);
$$;
comment on function public.pricing_city_archive(uuid, text, text) is 'POST /api/cities/:id/archive (seção 6).';

create or replace function public.pricing_city_restore(p_cidade_id uuid, p_motivo text default null)
returns void
language sql
security invoker
as $$
  select app.restaurar_cidade(p_cidade_id, p_motivo);
$$;
comment on function public.pricing_city_restore(uuid, text) is 'POST /api/cities/:id/restore (seção 6/21).';

grant execute on function
  public.pricing_city_archive(uuid, text, text),
  public.pricing_city_restore(uuid, text)
to authenticated;
