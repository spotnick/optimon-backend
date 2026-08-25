-- OptiMon — Fase 2.2.1 (Parte 2) — seções 29, 31, 34: salvar simulação, gerar/listar
-- proposta comercial, consultar auditoria, registrar login. Reaproveita as tabelas
-- `simulacoes`, `propostas_comerciais` e `auditoria` já existentes (Fase 1) — nenhuma
-- tabela nova. RLS das tabelas-base já resolve permissão (COMERCIAL/DIRETOR/ADMINISTRADOR
-- podem inserir simulação e proposta — políticas de 20260824091900_rls_policies.sql,
-- inalteradas).

-- ============================================================================
-- 1) SALVAR SIMULAÇÃO — POST /api/simulations (seção 31)
-- ============================================================================

create or replace function public.pricing_simulation_save(
  p_cidade_id uuid,
  p_parceiro_id uuid,
  p_modelo public.contrato_modelo,
  p_pares_ou_clientes integer,
  p_arpu numeric,
  p_revenue_share_pct numeric,
  p_prazo_meses integer,
  p_resultado jsonb
)
returns public.simulacoes
language sql
security invoker
as $$
  insert into public.simulacoes (cidade_id, parceiro_id, modelo, pares_ou_clientes, arpu, revenue_share_pct, prazo_meses, resultado, criado_por)
  values (p_cidade_id, p_parceiro_id, p_modelo, p_pares_ou_clientes, p_arpu, p_revenue_share_pct, p_prazo_meses, p_resultado, auth.uid())
  returning *;
$$;
comment on function public.pricing_simulation_save(uuid, uuid, public.contrato_modelo, integer, numeric, numeric, integer, jsonb) is 'POST /api/simulations — persiste o resultado de pricing_calculate_full para poder virar proposta (seção 22/29/31). SECURITY INVOKER: RLS de simulacoes (só COMERCIAL/DIRETOR/ADMINISTRADOR) continua valendo.';

-- ============================================================================
-- 2) PROPOSTA COMERCIAL — POST /api/proposals, GET /api/proposals (seção 29/31)
-- ============================================================================

create or replace function public.pricing_proposal_create(
  p_simulacao_id uuid,
  p_cidade_id uuid default null,
  p_parceiro_id uuid default null,
  p_contrato_id uuid default null,
  p_pricing_version_id uuid default null,
  p_override_request_id uuid default null,
  p_snapshot jsonb default null
)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_snapshot jsonb;
  v_row public.propostas_comerciais;
begin
  if p_simulacao_id is null then
    raise exception 'simulacao_id é obrigatório — proposta sempre nasce de uma simulação salva (seção 29).';
  end if;

  -- Sem snapshot explícito, monta a partir do resultado já salvo na simulação — a
  -- proposta nunca precisa recalcular nada (fonte única: o que a simulação já congelou).
  if p_snapshot is null then
    select resultado into v_snapshot from public.simulacoes where id = p_simulacao_id;
    if v_snapshot is null then
      raise exception 'Simulação % não encontrada ou sem resultado salvo.', p_simulacao_id;
    end if;
  else
    v_snapshot := p_snapshot;
  end if;

  insert into public.propostas_comerciais (simulacao_id, cidade_id, parceiro_id, contrato_id, pricing_version_id, override_request_id, snapshot, criado_por, status)
  values (p_simulacao_id, p_cidade_id, p_parceiro_id, p_contrato_id, p_pricing_version_id, p_override_request_id, v_snapshot, auth.uid(), 'RASCUNHO')
  returning * into v_row;

  return v_row;
end;
$$;
comment on function public.pricing_proposal_create(uuid, uuid, uuid, uuid, uuid, uuid, jsonb) is 'POST /api/proposals — "GERAR PROPOSTA" (seção 29). snapshot é imutável após criação (trigger fn_proposta_snapshot_imutavel, seção 60 da Fase 2).';

create or replace function public.pricing_proposals_list(p_contrato_id uuid default null, p_cidade_id uuid default null)
returns setof public.propostas_comerciais
language sql
stable
security invoker
as $$
  select * from public.propostas_comerciais
  where (p_contrato_id is null or contrato_id = p_contrato_id)
    and (p_cidade_id is null or cidade_id = p_cidade_id)
  order by criado_em desc;
$$;
comment on function public.pricing_proposals_list(uuid, uuid) is 'GET /api/proposals — histórico de propostas (seção 31), respeitando a policy propostas_comerciais_select (todos autenticados veem, seção 29).';

-- ============================================================================
-- 3) AUDITORIA — GET /api/audit (seção 31/34)
-- ============================================================================

create or replace function public.pricing_audit_list(p_limit integer default 100, p_entidade text default null, p_usuario_id uuid default null)
returns setof public.auditoria
language sql
stable
security invoker
as $$
  select * from public.auditoria
  where (p_entidade is null or entidade = p_entidade)
    and (p_usuario_id is null or usuario_id = p_usuario_id)
  order by criado_em desc
  limit least(coalesce(p_limit, 100), 500);
$$;
comment on function public.pricing_audit_list(integer, text, uuid) is 'GET /api/audit — trilha de auditoria (seção 31/34/45), respeitando auditoria_select (todo authenticated vê, imutável por trigger).';

-- Login (seção 34) não é uma alteração de linha em nenhuma tabela de negócio, então não
-- tem trigger de auditoria natural — este wrapper SECURITY DEFINER (mesmo padrão de
-- fn_auditoria, que já bypassa RLS de auditoria por ser dono da tabela) registra um evento
-- explícito assim que o frontend confirma o login. Só grava para o PRÓPRIO usuário
-- autenticado (auth.uid()) — nunca aceita um usuario_id arbitrário do chamador.
create or replace function public.pricing_log_login()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ip inet;
begin
  begin
    v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', '')::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.auditoria (usuario_id, ip, acao, entidade, entidade_id, valor_anterior, valor_novo)
  values (auth.uid(), v_ip, 'LOGIN', 'auth', auth.uid(), null, null);
end;
$$;
comment on function public.pricing_log_login() is 'Chamado uma vez pelo frontend logo após login bem-sucedido (seção 18/34) — registra o evento de LOGIN na auditoria. SECURITY DEFINER só para poder inserir em auditoria (sem policy de INSERT para authenticated, por design); só grava auth.uid() do próprio chamador, nunca um usuario_id arbitrário.';

grant execute on function
  public.pricing_simulation_save(uuid, uuid, public.contrato_modelo, integer, numeric, numeric, integer, jsonb),
  public.pricing_proposal_create(uuid, uuid, uuid, uuid, uuid, uuid, jsonb),
  public.pricing_proposals_list(uuid, uuid),
  public.pricing_audit_list(integer, text, uuid),
  public.pricing_log_login()
to authenticated;
