-- OptiMon — Fase 3, item 3.16 (Testes obrigatórios TESTE 01-50 + segurança +
-- regressão completa): CORREÇÃO DE 2 BUGS REAIS, PRÉ-EXISTENTES, ACHADOS PELA
-- BATERIA DE TESTES desta fase (tests/testes_obrigatorios_teste01_50.sh,
-- TESTE-11). Migration ADITIVA — nenhuma tabela recriada, nenhuma regra de
-- negócio já correta alterada ou simplificada; só conserta o que estava
-- genuinely quebrado.
--
-- BUG 1 — public.pricing_override_approve() (criada na Fase 2.10, migration
-- 20260827100900_phase_2_10_api_public_wrappers.sql) SEMPRE falhava com erro
-- de tipo do Postgres, para QUALQUER chamador (inclusive DIRETOR/ADMINISTRADOR
-- com permissão total):
--   ERROR: column "status" is of type solicitacao_status but expression is of type text
-- Causa: `set status = case when p_aprovar then 'APROVADA' else 'REJEITADA' end`
-- produz um valor `text` sem cast explícito para o enum `solicitacao_status` —
-- o Postgres não faz esse cast implícito dentro de uma expressão CASE usada
-- como alvo de UPDATE. Ou seja: a rota POST /api/pricing/approve nunca
-- funcionou de fato em nenhum ambiente que já tenha rodado esta migration —
-- toda decisão de override (aprovar OU rejeitar) sempre retornava 500. Corrigido
-- adicionando o cast explícito `::solicitacao_status` a cada ramo do CASE.
--
-- BUG 2 — a policy de RLS `pricing_override_requests_update` (criada na Fase
-- 2.09, migration 20260827100800_phase_2_09_auditoria_rls.sql) nunca foi
-- estendida quando a Fase 2.2.1 (seção 35, migration
-- 20260830090200_phase_2_2_1_03_governanca_por_perfil_e_override.sql) deu ao
-- trigger fn_override_decisao() a lógica para permitir que um FINANCEIRO com
-- usuarios.pode_aprovar_override_pricing=true decida um override. Como a
-- policy de UPDATE só libera a linha para DIRETOR/ADMINISTRADOR ou para o
-- próprio solicitante enquanto PENDENTE, um FINANCEIRO nunca conseguia
-- alcançar a linha via RLS para começo de conversa — o UPDATE afetava 0
-- linhas (silenciosamente) e o trigger, que já tinha a lógica certa, nunca
-- chegava a rodar. Ou seja: a permissão explícita da seção 35 da Fase 2.2.1
-- está documentada e implementada no trigger desde aquela fase, mas NUNCA
-- funcionou de fato, porque a policy de RLS (de uma fase anterior) não foi
-- atualizada junto. Corrigido estendendo a policy (drop + recreate, mesma
-- convenção usada em todo o projeto para alterar uma policy existente) para
-- também liberar a linha quando `app.tem_perfil('FINANCEIRO')` e a coluna
-- `pode_aprovar_override_pricing` do usuário é true — EXATAMENTE a mesma
-- condição que o trigger já usa, apenas replicada na camada de visibilidade
-- de linha. O comportamento para todo mundo que já funcionava (DIRETOR,
-- ADMINISTRADOR, o próprio solicitante enquanto PENDENTE, e um FINANCEIRO
-- SEM a permissão explícita — que continua bloqueado) não muda em nada.

create or replace function public.pricing_override_approve(p_override_id uuid, p_aprovar boolean, p_observacao text default null::text)
returns public.pricing_override_requests
language plpgsql
as $function$
declare
  v_row public.pricing_override_requests;
begin
  update public.pricing_override_requests
  set status = case when p_aprovar then 'APROVADA'::solicitacao_status else 'REJEITADA'::solicitacao_status end
  where id = p_override_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Override % não encontrado ou já decidido.', p_override_id;
  end if;
  return v_row;
end;
$function$;
comment on function public.pricing_override_approve(uuid, boolean, text) is 'Fase 2.10 (wrapper público de RPC) + correção Fase 3.16: aplica a decisão (aprovar/rejeitar) sobre um override de preço pendente. BUGFIX 3.16: o CASE agora faz cast explícito para solicitacao_status — antes desta correção, TODA chamada (mesmo de DIRETOR/ADMINISTRADOR) falhava com erro de tipo do Postgres e a decisão nunca era persistida. A autorização em si continua 100% na RLS (pricing_override_requests_update) e no trigger fn_override_decisao — esta função não verifica perfil.';

drop policy if exists pricing_override_requests_update on public.pricing_override_requests;
create policy pricing_override_requests_update on public.pricing_override_requests for update to authenticated
  using (
    app.tem_perfil('DIRETOR', 'ADMINISTRADOR')
    or (solicitado_por = auth.uid() and status = 'PENDENTE')
    or (app.tem_perfil('FINANCEIRO') and coalesce((select pode_aprovar_override_pricing from public.usuarios where id = auth.uid()), false))
  )
  with check (
    app.tem_perfil('DIRETOR', 'ADMINISTRADOR')
    or (solicitado_por = auth.uid() and status = 'PENDENTE')
    or (app.tem_perfil('FINANCEIRO') and coalesce((select pode_aprovar_override_pricing from public.usuarios where id = auth.uid()), false))
  );
comment on policy pricing_override_requests_update on public.pricing_override_requests is 'RLS permite ao próprio Comercial editar a solicitação enquanto PENDENTE (ex.: refinar justificativa); a decisão em si (mudar status) é bloqueada pelo trigger fn_override_decisao para quem não é DIRETOR/ADMINISTRADOR, mesmo que a policy deixe passar a UPDATE. BUGFIX Fase 3.16: adicionado o terceiro ramo (FINANCEIRO + pode_aprovar_override_pricing=true) — a Fase 2.2.1 (seção 35) já dava essa permissão no trigger fn_override_decisao, mas a policy nunca foi estendida para deixar a linha visível para esse UPDATE, então a permissão documentada nunca funcionava de fato. Um FINANCEIRO sem a flag explícita continua bloqueado, agora silenciosamente pela própria RLS (0 linhas afetadas) em vez de alcançar o trigger.';
