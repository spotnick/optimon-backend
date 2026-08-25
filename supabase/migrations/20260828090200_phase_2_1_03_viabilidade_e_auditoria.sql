-- OptiMon — Fase 2.1
-- Seção 11: classificação de viabilidade em 4 níveis (EXCELENTE / VIÁVEL / MARGEM BAIXA
-- / INVIÁVEL) em vez dos 3 da Fase 2 (EXCELENTE / NEGÓCIO VIÁVEL / NEGÓCIO INVIÁVEL).
-- Seção 14: fecha 2 lacunas reais de auditoria confirmadas nesta revisão — infra_fibras
-- e pricing_faixas_escassez nunca tinham trigger de auditoria (verificado consultando
-- information_schema.triggers: toda tabela de pricing da Fase 2 tinha auditoria, exceto
-- estas duas).

-- Novo limiar PARAMETRIZÁVEL — mesma disciplina de EXCELENCIA_ROI_MINIMO_PADRAO (Fase 2):
-- nasce SEM SEED (não inventamos o valor). Enquanto não for configurado pelo negócio, a
-- classificação nunca produz "MARGEM BAIXA" (colapsa em VIÁVEL/EXCELENTE, como na Fase 2).
comment on function app.classificar_negocio(uuid, numeric, numeric) is 'Seção 57 (Fase 2) + seção 11 (Fase 2.1) — substituída abaixo por versão de 4 níveis.';

create or replace function app.classificar_negocio(p_contrato_id uuid, p_margem_percentual_parceiro numeric, p_roi_optimon numeric default null)
returns text
language plpgsql
stable
as $$
declare
  v_margem_minima numeric;
  v_margem_confortavel numeric;
  v_roi_excelencia numeric;
begin
  select margem_minima_parceiro_percent into v_margem_minima from public.contrato_pricing_config where contrato_id = p_contrato_id;
  if v_margem_minima is null then
    select valor into v_margem_minima from public.pricing_parametros
    where chave = 'VIABILIDADE_MARGEM_PARCEIRO_MINIMA_PADRAO' and (vigente_ate is null or vigente_ate >= current_date);
  end if;

  if v_margem_minima is null or p_margem_percentual_parceiro is null then
    return 'PARAMETRIZÁVEL — defina partner_minimum_margin (contrato) ou VIABILIDADE_MARGEM_PARCEIRO_MINIMA_PADRAO (global) para classificar (seção 57).';
  end if;

  if p_margem_percentual_parceiro < v_margem_minima then
    return 'INVIÁVEL';
  end if;

  -- Seção 11 (Fase 2.1): faixa "MARGEM BAIXA" — margem do parceiro já cumpre o mínimo de
  -- viabilidade, mas ainda está abaixo do limiar "confortável" configurado. Só existe
  -- quando VIABILIDADE_MARGEM_PARCEIRO_CONFORTAVEL_PADRAO estiver definido (seção 65: não
  -- inventamos onde termina "baixa" e começa "confortável" — sem o parâmetro, o negócio
  -- classifica direto como VIÁVEL/EXCELENTE, exatamente como na Fase 2).
  select valor into v_margem_confortavel from public.pricing_parametros
  where chave = 'VIABILIDADE_MARGEM_PARCEIRO_CONFORTAVEL_PADRAO' and (vigente_ate is null or vigente_ate >= current_date);

  if v_margem_confortavel is not null and p_margem_percentual_parceiro < v_margem_confortavel then
    return 'MARGEM BAIXA';
  end if;

  select valor into v_roi_excelencia from public.pricing_parametros
  where chave = 'EXCELENCIA_ROI_MINIMO_PADRAO' and (vigente_ate is null or vigente_ate >= current_date);

  if v_roi_excelencia is not null and p_roi_optimon is not null and p_roi_optimon >= v_roi_excelencia then
    return 'EXCELENTE';
  end if;

  return 'VIÁVEL';
end;
$$;

comment on function app.classificar_negocio(uuid, numeric, numeric) is 'Seção 57 (Fase 2) + seção 11 (Fase 2.1): 4 níveis — INVIÁVEL (margem parceiro < mínimo configurado) / MARGEM BAIXA (>= mínimo mas < limiar confortável, só quando VIABILIDADE_MARGEM_PARCEIRO_CONFORTAVEL_PADRAO estiver configurado) / VIÁVEL (>= mínimo, sem limiar confortável definido ou já acima dele) / EXCELENTE (margem OK + ROI OptiMon >= EXCELENCIA_ROI_MINIMO_PADRAO). PARAMETRIZÁVEL quando os limiares base não existem — nunca um limiar inventado.';

-- Seção 14 (Fase 2.1): auditoria de alterações em fibra (infra_fibras) e em escassez
-- (pricing_faixas_escassez) — as duas lacunas reais encontradas nesta revisão.
create trigger trg_aud_infra_fibras
  after insert or update or delete on public.infra_fibras
  for each row execute function public.fn_auditoria();
comment on trigger trg_aud_infra_fibras on public.infra_fibras is 'Seção 14 (Fase 2.1) — lacuna real: infra_fibras nunca teve trigger de auditoria (só contrato_fibras, o vínculo, era auditado). Cobre alterações na fibra física em si (status, par_numero, etc.).';

create trigger trg_aud_pricing_faixas_escassez
  after insert or update or delete on public.pricing_faixas_escassez
  for each row execute function public.fn_auditoria();
comment on trigger trg_aud_pricing_faixas_escassez on public.pricing_faixas_escassez is 'Seção 14 (Fase 2.1) — lacuna real: pricing_faixas_escassez (fatores de escassez, seção 14 da Fase 2) nunca teve trigger de auditoria, apesar de a RLS já restringir escrita a DIRETOR/ADMINISTRADOR.';
