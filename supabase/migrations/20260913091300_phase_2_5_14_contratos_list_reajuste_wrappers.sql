-- OptiMon — Fase 2.5 (14/14): /contratos — listagem com filtro (seção 37) +
-- exposição do reajuste já existente (seção 40) + detalhe enriquecido.
--
-- `app.aplicar_reajuste_contrato` (histórico completo/nunca reescreve valor
-- antigo) e `app.check_contract_conflict` já existem, completos, desde antes
-- desta fase — só ganham wrapper `public.*` aqui, sem nenhuma mudança de
-- lógica. O que realmente faltava era uma listagem enriquecida (nome de
-- parceiro/cidade, não só IDs) com os filtros de negócio da seção 37, que
-- nunca existiu antes (a Fase 2.4 só tinha listagem de PROPOSTA, não de
-- CONTRATO).

create or replace function app.contratos_list(p_filtro text default null)
returns table (
  id uuid, numero text, status contrato_status, parceiro_id uuid, parceiro_nome text,
  cidade_id uuid, cidade_nome text, prazo_meses integer, data_inicio date, data_fim_prevista date,
  versao_atual integer, criado_em timestamptz,
  em_assinatura boolean, dias_para_vencimento integer
)
language sql
stable
security invoker
as $$
  select
    c.id, c.numero, c.status, c.parceiro_id,
    coalesce(p.nome_fantasia, p.razao_social) as parceiro_nome,
    c.cidade_id, ci.nome as cidade_nome,
    c.prazo_meses, c.data_inicio, c.data_fim_prevista, c.versao_atual, c.criado_em,
    exists (
      select 1 from public.signature_envelopes se
      where se.contrato_id = c.id and se.tipo_documento = 'CONTRATO'
        and se.status in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
    ) as em_assinatura,
    (c.data_fim_prevista - current_date) as dias_para_vencimento
  from public.contratos c
  join public.parceiros p on p.id = c.parceiro_id
  join public.cidades_infra ci on ci.id = c.cidade_id
  where c.removido_em is null
    and (
      p_filtro is null or p_filtro = 'TODOS'
      or (p_filtro = 'ATIVOS' and c.status = 'ATIVO')
      or (p_filtro = 'SUSPENSOS' and c.status = 'SUSPENSO')
      or (p_filtro = 'CANCELADOS' and c.status in ('RESCINDIDO', 'ENCERRADO'))
      or (p_filtro = 'EM_ASSINATURA' and exists (
            select 1 from public.signature_envelopes se
            where se.contrato_id = c.id and se.tipo_documento = 'CONTRATO'
              and se.status in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
          ))
      or (p_filtro = 'EXPIRANDO' and c.status = 'ATIVO' and c.data_fim_prevista is not null
            and c.data_fim_prevista between current_date and current_date + interval '60 days')
      or (p_filtro = 'EXPIRADOS' and c.data_fim_prevista is not null and c.data_fim_prevista < current_date
            and c.status not in ('RESCINDIDO', 'ENCERRADO'))
    )
  order by c.criado_em desc;
$$;

drop function if exists public.pricing_contracts_list(text);
create or replace function public.pricing_contracts_list(p_filtro text default null)
returns table (
  id uuid, numero text, status contrato_status, parceiro_id uuid, parceiro_nome text,
  cidade_id uuid, cidade_nome text, prazo_meses integer, data_inicio date, data_fim_prevista date,
  versao_atual integer, criado_em timestamptz, em_assinatura boolean, dias_para_vencimento integer
)
language sql security invoker
as $$ select * from app.contratos_list(p_filtro); $$;

grant execute on function public.pricing_contracts_list(text) to authenticated;

-- ============================================================================
-- Reajuste (seção 40) — só wrapper, zero lógica nova.
-- ============================================================================

drop function if exists public.pricing_contract_apply_reajuste(uuid, numeric, date, uuid, text);
create or replace function public.pricing_contract_apply_reajuste(
  p_contrato_id uuid, p_percentual numeric, p_competencia_base date default (date_trunc('month', current_date))::date,
  p_indice_id uuid default null, p_motivo text default 'Reajuste anual'
)
returns uuid
language sql security invoker
as $$ select app.aplicar_reajuste_contrato(p_contrato_id, p_percentual, p_competencia_base, p_indice_id, p_motivo); $$;

grant execute on function public.pricing_contract_apply_reajuste(uuid, numeric, date, uuid, text) to authenticated;
