-- OptiMon — Fase 2.5 (9/9): Dashboard contratual + alertas (seções 41-42).
--
-- `alertas` já existe desde a Fase 2 (com boa parte dos tipos da seção 42 já
-- cobertos: CONTRATO_PROXIMO_VENCIMENTO, REAJUSTE, FIBRA_EM_CONFLITO,
-- CAPACIDADE_EXCEDIDA, OPERACAO_NAO_AUTORIZADA) — só os tipos realmente novos
-- desta fase são acrescentados ao enum, e a tabela ganha `proposta_id` para
-- poder apontar um alerta direto a uma proposta (hoje só aponta contrato/
-- cidade/parceiro/porta PON).

alter type alerta_tipo add value if not exists 'APROVACAO_PENDENTE';
alter type alerta_tipo add value if not exists 'ASSINATURA_PENDENTE';
alter type alerta_tipo add value if not exists 'CONTRATO_PENDENTE';
alter type alerta_tipo add value if not exists 'DOCUMENTO_RECUSADO';
alter type alerta_tipo add value if not exists 'ERRO_INTEGRACAO_ASSINATURA';

alter table public.alertas
  add column if not exists proposta_id uuid references public.propostas_comerciais(id) on delete set null;

comment on column public.alertas.proposta_id is 'Fase 2.5 seção 42: alertas de aprovação/assinatura pendente apontam direto para a proposta, não só para o contrato (que pode nem existir ainda nesse ponto do fluxo).';

-- ============================================================================
-- Gera alertas automáticos a partir do estado atual (seção 42). Não duplica
-- um alerta ainda não resolvido para a MESMA entidade/tipo — chamada sob
-- demanda (ao abrir o dashboard), não um job agendado (fora do escopo desta
-- fase, mesma lista de "não implementado" de todas as fases anteriores).
-- ============================================================================

create or replace function app.gerar_alertas_automaticos()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_criados integer := 0;
  r record;
begin
  if not app.tem_perfil('DIRETOR', 'FINANCEIRO', 'ENGENHARIA', 'ADMINISTRADOR', 'COMERCIAL') then
    raise exception 'PERMISSAO_NEGADA: sem permissão para gerar alertas.';
  end if;

  -- Propostas aguardando aprovação
  for r in
    select p.id, p.numero from public.propostas_comerciais p
    where p.status = 'EM_APROVACAO'
      and not exists (
        select 1 from public.alertas a
        where a.proposta_id = p.id and a.tipo = 'APROVACAO_PENDENTE' and a.resolvido = false
      )
  loop
    insert into public.alertas (tipo, severidade, proposta_id, titulo, descricao)
    values ('APROVACAO_PENDENTE', 'ATENCAO', r.id, 'Proposta aguardando aprovação', 'Proposta ' || r.numero || ' está em EM_APROVACAO.');
    v_criados := v_criados + 1;
  end loop;

  -- Propostas aguardando assinatura
  for r in
    select p.id, p.numero from public.propostas_comerciais p
    where p.status = 'EM_ASSINATURA'
      and not exists (
        select 1 from public.alertas a
        where a.proposta_id = p.id and a.tipo = 'ASSINATURA_PENDENTE' and a.resolvido = false
      )
  loop
    insert into public.alertas (tipo, severidade, proposta_id, titulo, descricao)
    values ('ASSINATURA_PENDENTE', 'ATENCAO', r.id, 'Proposta aguardando assinatura', 'Proposta ' || r.numero || ' está em EM_ASSINATURA.');
    v_criados := v_criados + 1;
  end loop;

  -- Contratos aguardando assinatura (envelope enviado, ainda não validado)
  for r in
    select distinct c.id, c.numero from public.contratos c
    join public.signature_envelopes e on e.contrato_id = c.id
    where e.tipo_documento = 'CONTRATO' and e.status in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
      and not exists (
        select 1 from public.alertas a where a.contrato_id = c.id and a.tipo = 'CONTRATO_PENDENTE' and a.resolvido = false
      )
  loop
    insert into public.alertas (tipo, severidade, contrato_id, titulo, descricao)
    values ('CONTRATO_PENDENTE', 'ATENCAO', r.id, 'Contrato aguardando assinatura', 'Contrato ' || r.numero || ' tem envelope de assinatura em andamento.');
    v_criados := v_criados + 1;
  end loop;

  -- Documento recusado (proposta ou contrato)
  for r in
    select e.id as envelope_id, e.tipo_documento, e.proposta_id, e.contrato_id
    from public.signature_envelopes e
    where e.status = 'RECUSADO'
      and not exists (
        select 1 from public.alertas a
        where a.tipo = 'DOCUMENTO_RECUSADO'
          and a.resolvido = false
          and ((a.proposta_id is not distinct from e.proposta_id) and (a.contrato_id is not distinct from e.contrato_id))
      )
  loop
    insert into public.alertas (tipo, severidade, proposta_id, contrato_id, titulo, descricao)
    values ('DOCUMENTO_RECUSADO', 'CRITICO', r.proposta_id, r.contrato_id, 'Documento recusado na assinatura', 'Envelope ' || r.envelope_id || ' (' || r.tipo_documento || ') foi recusado por um signatário.');
    v_criados := v_criados + 1;
  end loop;

  -- Vencimento próximo (60 dias) — mesma lógica de CONTRATO_PROXIMO_VENCIMENTO
  -- já usada em fases anteriores, só chamada aqui também.
  for r in
    select c.id, c.numero from public.contratos c
    where c.status = 'ATIVO' and c.data_fim_prevista is not null
      and c.data_fim_prevista <= current_date + interval '60 days'
      and not exists (
        select 1 from public.alertas a where a.contrato_id = c.id and a.tipo = 'CONTRATO_PROXIMO_VENCIMENTO' and a.resolvido = false
      )
  loop
    insert into public.alertas (tipo, severidade, contrato_id, titulo, descricao)
    values ('CONTRATO_PROXIMO_VENCIMENTO', 'ATENCAO', r.id, 'Contrato próximo do vencimento', 'Contrato ' || r.numero || ' vence em até 60 dias.');
    v_criados := v_criados + 1;
  end loop;

  return v_criados;
end;
$$;

drop function if exists public.pricing_alerts_generate();
create or replace function public.pricing_alerts_generate()
returns integer
language sql security invoker
as $$ select app.gerar_alertas_automaticos(); $$;

grant execute on function public.pricing_alerts_generate() to authenticated;

-- ============================================================================
-- Dashboard contratual (seção 41)
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
    'contratos_aguardando_assinatura', (
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
    'alertas_nao_resolvidos', (select count(*) from public.alertas where resolvido = false)
  );
$$;

drop function if exists public.pricing_dashboard_contratual();
create or replace function public.pricing_dashboard_contratual()
returns jsonb
language sql security invoker
as $$ select app.dashboard_contratual(); $$;

grant execute on function public.pricing_dashboard_contratual() to authenticated;
