-- OptiMon — Fase 2
-- Seções 28-29: motor de reajuste. IPCA/IGP-M/FIXO/SEM_REAJUSTE, índice inserido
-- manualmente ou por série já cadastrada (indices_economicos, Fase 1) — SEM integração
-- automática com IBGE nesta fase (seção 28, explícito). Preserva histórico: reajustes e
-- pricing_versions nunca são alterados depois de criados; só o valor VIGENTE do contrato
-- avança para frente (cobranças antigas nunca são recalculadas).

alter table public.contrato_pricing_config
  add column indice_reajuste text not null default 'IPCA' check (indice_reajuste in ('IPCA', 'IGPM', 'FIXO', 'SEM_REAJUSTE'));

comment on column public.contrato_pricing_config.indice_reajuste is 'Seção 28: índice de reajuste do contrato — IPCA (padrão), IGPM, FIXO (percentual definido em contrato) ou SEM_REAJUSTE. Sem integração automática com IBGE nesta fase — valor aplicado manualmente via app.aplicar_reajuste_contrato().';

-- app.aplicar_reajuste_contrato(): SECURITY DEFINER porque precisa gravar em
-- contrato_pricing_config (cuja RLS geral é DIRETOR/ADMINISTRADOR-only, para proteger
-- edição livre de pricing comercial) através de uma operação financeira estreita e
-- auditada — por isso o próprio corpo da função reforça a checagem de perfil
-- (FINANCEIRO/ADMINISTRADOR, igual à policy de `reajustes`) em vez de depender só da RLS
-- da tabela de destino. O trigger de auditoria de contrato_pricing_config dispara
-- normalmente mesmo assim (SECURITY DEFINER não pula triggers, só RLS).
create or replace function app.aplicar_reajuste_contrato(
  p_contrato_id uuid,
  p_percentual numeric,
  p_competencia_base date default date_trunc('month', current_date)::date,
  p_indice_id uuid default null,
  p_motivo text default 'Reajuste anual'
)
returns uuid
language plpgsql
security definer
set search_path = public, app, pg_temp
as $$
declare
  v_versao integer;
  v_snapshot jsonb;
  v_pricing_version_id uuid;
  v_reajuste_id uuid;
  v_indice_texto text;
begin
  if not app.tem_perfil('FINANCEIRO', 'ADMINISTRADOR') then
    raise exception 'REQUIRES_APPROVAL: aplicar reajuste é uma operação financeira — exige perfil FINANCEIRO ou ADMINISTRADOR (seção 53).';
  end if;

  select indice_reajuste into v_indice_texto from public.contrato_pricing_config where contrato_id = p_contrato_id;
  if v_indice_texto is null then
    raise exception 'Contrato % não possui contrato_pricing_config cadastrado.', p_contrato_id;
  end if;
  if v_indice_texto = 'SEM_REAJUSTE' then
    raise exception 'Contrato % está configurado como SEM_REAJUSTE — reajuste não aplicável (seção 28).', p_contrato_id;
  end if;

  -- 1) Snapshot IMUTÁVEL do estado atual, antes de mudar nada (nova pricing_version).
  select to_jsonb(cpc.*) into v_snapshot from public.contrato_pricing_config cpc where contrato_id = p_contrato_id;
  select coalesce(max(versao), 0) + 1 into v_versao from public.pricing_versions where contrato_id = p_contrato_id;

  insert into public.pricing_versions (contrato_id, versao, motivo, parametros, indice_aplicado, criado_por)
  values (p_contrato_id, v_versao, p_motivo, v_snapshot, v_indice_texto, auth.uid())
  returning id into v_pricing_version_id;

  -- 2) Log imutável do reajuste em si (nunca editado depois de aplicado).
  insert into public.reajustes (contrato_id, indice_id, competencia_base, percentual_aplicado, pricing_version_gerada, aplicado_por, status)
  values (p_contrato_id, p_indice_id, p_competencia_base, p_percentual, v_pricing_version_id, coalesce((select email from public.usuarios where id = auth.uid()), 'SISTEMA'), 'APLICADO')
  returning id into v_reajuste_id;

  -- 3) Valor VIGENTE avança para frente — cobranças já apuradas (medicoes/faturamento
  -- antigos) nunca são recalculadas; só o que vier depois desta data usa o novo valor.
  update public.contrato_pricing_config
  set mensalidade_minima_porta = round(coalesce(mensalidade_minima_porta, 0) * (1 + p_percentual), 2),
      preco_minimo_porta = case when preco_minimo_porta is null then null else round(preco_minimo_porta * (1 + p_percentual), 2) end,
      preco_recomendado_porta = case when preco_recomendado_porta is null then null else round(preco_recomendado_porta * (1 + p_percentual), 2) end,
      preco_premium_porta = case when preco_premium_porta is null then null else round(preco_premium_porta * (1 + p_percentual), 2) end
  where contrato_id = p_contrato_id;

  return v_reajuste_id;
end;
$$;

comment on function app.aplicar_reajuste_contrato(uuid, numeric, date, uuid, text) is 'Seções 27-29: aplica reajuste anual — grava snapshot imutável (pricing_versions), loga o reajuste (reajustes) e avança o valor vigente do contrato. Nunca recalcula versões/reajustes antigos. Exemplo do prompt: R$1.000 + IPCA 5% = R$1.050 no ano seguinte.';
