-- OptiMon — Fase 2
-- Seções 5, 6, 11, 12, 13, 14: Cenário 1 (Dark Fiber) — unidades de precificação,
-- escassez de capacidade, preço mínimo/recomendado/premium. Nada hard-coded: toda
-- margem/risco/multiplicador vem de contrato_pricing_config ou pricing_parametros, com
-- fallback NEUTRO (0 ou 1x, nunca um percentual inventado) quando o negócio ainda não
-- configurou o valor — seção 65 ("não inventar premissas financeiras").

-- Seção 6: PER_FIBER / PER_KM / PER_PON / PER_POP / HYBRID — o enum já existia desde a
-- Fase 1.1 em português (POR_FIBRA/POR_KM/POR_PORTA/POR_POP); só falta o modelo misto.
alter type public.metodo_precificacao_dark_fiber add value if not exists 'HIBRIDO';
comment on type public.metodo_precificacao_dark_fiber is 'PER_FIBER=POR_FIBRA, PER_KM=POR_KM, PER_PON=POR_PORTA, PER_POP=POR_POP, HYBRID=HIBRIDO (seção 6) — nomes em português por consistência com o restante do schema.';

-- Seção 11/12/13/35: parâmetros de precificação por contrato — todos nullable (seção 65:
-- "quando um valor econômico ainda não estiver definido, não inventar, marcar
-- PARAMETRIZÁVEL"). As funções abaixo tratam NULL como 0/neutro e documentam isso.
alter table public.contrato_pricing_config
  add column margem_minima_percent numeric(6,5) check (margem_minima_percent is null or margem_minima_percent between 0 and 5),
  add column fator_risco_percent numeric(6,5) check (fator_risco_percent is null or fator_risco_percent between 0 and 5),
  add column payback_minimo_meses integer check (payback_minimo_meses is null or payback_minimo_meses > 0),
  add column margem_minima_parceiro_percent numeric(6,5) check (margem_minima_parceiro_percent is null or margem_minima_parceiro_percent between 0 and 1);

comment on column public.contrato_pricing_config.margem_minima_percent is 'minimum_margin_percent (seção 11). NULL = PARAMETRIZÁVEL/A DEFINIR, tratado como 0 (sem margem mínima adicional) até a área comercial configurar — nunca um percentual inventado.';
comment on column public.contrato_pricing_config.fator_risco_percent is 'risk_percent (seção 11). Mesma regra: NULL tratado como 0, nunca inventado.';
comment on column public.contrato_pricing_config.payback_minimo_meses is 'minimum_payback_months (seção 11) — usado só como informação de alerta (app.avaliar_payback_minimo), não altera a fórmula de preço.';
comment on column public.contrato_pricing_config.margem_minima_parceiro_percent is 'partner_minimum_margin (seção 35). NULL = sem limite configurado (nenhum alerta de inviabilidade é gerado).';

-- Seção 14: escassez de capacidade — faixas configuráveis (os percentuais do prompt são
-- exemplo conceitual explícito do usuário, não valor inventado por Claude).
create table public.pricing_faixas_escassez (
  id uuid primary key default gen_random_uuid(),
  disponibilidade_min numeric(5,4) not null check (disponibilidade_min >= 0),
  disponibilidade_max numeric(5,4) check (disponibilidade_max is null or disponibilidade_max <= 1),
  fator numeric(6,4) not null check (fator > 0),
  rotulo text not null,
  criado_em timestamptz not null default now(),
  check (disponibilidade_max is null or disponibilidade_max > disponibilidade_min)
);
comment on table public.pricing_faixas_escassez is 'Seção 14: capacity_scarcity_factor. Faixas de disponibilidade → fator multiplicador, sempre configuráveis (não hard-coded em função).';

insert into public.pricing_faixas_escassez (disponibilidade_min, disponibilidade_max, fator, rotulo) values
  (0.50, null, 1.00, 'NORMAL — 50%+ capacidade livre'),
  (0.30, 0.50, 1.15, 'MODERADO — 30% a 50% capacidade livre'),
  (0.10, 0.30, 1.35, 'ALTO — 10% a 30% capacidade livre'),
  (0.00, 0.10, 1.60, 'PREMIUM — menos de 10% capacidade livre');

create or replace function app.get_capacity_scarcity_factor(p_disponibilidade numeric)
returns numeric
language sql
stable
as $$
  select fator from public.pricing_faixas_escassez
  where p_disponibilidade >= disponibilidade_min
    and (disponibilidade_max is null or p_disponibilidade < disponibilidade_max)
  order by disponibilidade_min desc
  limit 1;
$$;
comment on function app.get_capacity_scarcity_factor(numeric) is 'capacity_scarcity_factor (seção 14): fator multiplicador conforme a faixa de disponibilidade (0..1) em pricing_faixas_escassez.';

-- Disponibilidade de fibra na cidade (base para escassez do Cenário 1 — Dark Fiber).
create or replace function app.get_disponibilidade_fibra_cidade(p_cidade_id uuid)
returns numeric
language sql
stable
as $$
  select case when count(*) = 0 then 0
    else round(count(*) filter (where f.status = 'LIVRE')::numeric / count(*), 4)
  end
  from public.infra_fibras f
  join public.infra_cabos cb on cb.id = f.cabo_id
  join public.infra_segmentos s on s.id = cb.segmento_id
  where s.cidade_id = p_cidade_id;
$$;

-- Pares de fibra contratados (unidade comercial do Dark Fiber — 2 fibras = 1 par).
create or replace function app.get_pares_contratados_dark_fiber(p_contrato_id uuid)
returns integer
language sql
stable
as $$
  select ceil(count(distinct f.par_numero) / 1.0)::integer
  from public.contrato_fibras cf
  join public.infra_fibras f on f.id = cf.fibra_id
  where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null and cf.fibra_id is not null;
$$;

-- Seção 11: PREÇO MÍNIMO = custo incremental/alocado (nunca histórico — app.get_custo_base_precificacao)
-- OU o piso global parametrizável (DARK_FIBER_PRECO_MINIMO_PAR_MES × pares), o que for
-- maior — nunca cobrar abaixo do custo real nem abaixo do piso comercial já parametrizado
-- desde a Fase 1. Sobre essa base, soma-se risco + margem mínima (ambos podem ser 0/
-- PARAMETRIZÁVEL — seção 65).
create or replace function app.calcular_preco_minimo_dark_fiber(p_contrato_id uuid)
returns numeric
language plpgsql
stable
as $$
declare
  v_config record;
  v_cidade_id uuid;
  v_pares integer;
  v_piso_par numeric;
  v_base numeric;
begin
  select margem_minima_percent, fator_risco_percent into v_config
  from public.contrato_pricing_config where contrato_id = p_contrato_id;

  select cidade_id into v_cidade_id from public.contratos where id = p_contrato_id;
  v_pares := greatest(coalesce(app.get_pares_contratados_dark_fiber(p_contrato_id), 0), 1);

  select valor into v_piso_par from public.pricing_parametros
  where chave = 'DARK_FIBER_PRECO_MINIMO_PAR_MES' and (vigente_ate is null or vigente_ate >= current_date);

  v_base := greatest(
    coalesce(app.get_custo_base_precificacao(p_contrato_id), 0),
    coalesce(v_piso_par, 0) * v_pares
  );

  return round(v_base * (1 + coalesce(v_config.margem_minima_percent, 0) + coalesce(v_config.fator_risco_percent, 0)), 2);
end;
$$;

comment on function app.calcular_preco_minimo_dark_fiber(uuid) is 'PREÇO MÍNIMO (seção 11) = MAX(custo incremental+alocado, piso global por par) × (1 + margem mínima + risco). margem/risco tratados como 0 quando não parametrizados (seção 65), nunca inventados.';

-- Seção 12: PREÇO RECOMENDADO = mínimo × multiplicador comercial (parametrizável desde a
-- Fase 1: DARK_FIBER_MULTIPLICADOR_RECOMENDADO=1.20) × fator de escassez — garante
-- recomendado > mínimo sempre que o multiplicador é > 1 e o fator de escassez >= 1.
create or replace function app.calcular_preco_recomendado_dark_fiber(p_contrato_id uuid)
returns numeric
language plpgsql
stable
as $$
declare
  v_minimo numeric;
  v_multiplicador numeric;
  v_cidade_id uuid;
  v_disponibilidade numeric;
  v_fator_escassez numeric;
begin
  v_minimo := app.calcular_preco_minimo_dark_fiber(p_contrato_id);

  select valor into v_multiplicador from public.pricing_parametros
  where chave = 'DARK_FIBER_MULTIPLICADOR_RECOMENDADO' and (vigente_ate is null or vigente_ate >= current_date);

  select cidade_id into v_cidade_id from public.contratos where id = p_contrato_id;
  v_disponibilidade := app.get_disponibilidade_fibra_cidade(v_cidade_id);
  v_fator_escassez := coalesce(app.get_capacity_scarcity_factor(v_disponibilidade), 1);

  return round(v_minimo * coalesce(v_multiplicador, 1) * v_fator_escassez, 2);
end;
$$;

comment on function app.calcular_preco_recomendado_dark_fiber(uuid) is 'PREÇO RECOMENDADO (seção 12) = preço mínimo × multiplicador comercial × fator de escassez (valor econômico da capacidade). > preço mínimo por construção (multiplicador e fator sempre >= 1).';

-- Seção 13: PREÇO PREMIUM — NUNCA "recomendado × 2" fixo. Multiplicador comercial próprio
-- (parametrizável, já existia: DARK_FIBER_MULTIPLICADOR_PREMIUM=1.50) × bônus por
-- exclusividade/multi-POP/capacidade reservada — cada bônus é PARAMETRIZÁVEL com default
-- neutro (1.0 = sem efeito) até o negócio decidir o valor (seção 65).
insert into public.pricing_parametros (chave, valor, unidade, descricao) values
  ('DARK_FIBER_PREMIO_EXCLUSIVIDADE', 1.00, 'x', 'PARAMETRIZÁVEL (seção 13/65) — multiplicador extra do preço premium quando o contrato tem exclusividade. 1.00 = sem efeito até o negócio definir.'),
  ('DARK_FIBER_PREMIO_MULTIPOP', 1.00, 'x', 'PARAMETRIZÁVEL (seção 13/65) — multiplicador extra do preço premium por múltiplos POPs. 1.00 = sem efeito até o negócio definir.')
on conflict (chave) do nothing;

create or replace function app.calcular_preco_premium_dark_fiber(p_contrato_id uuid)
returns numeric
language plpgsql
stable
as $$
declare
  v_recomendado numeric;
  v_multiplicador_premium numeric;
  v_premio_exclusividade numeric;
  v_premio_multipop numeric;
  v_exclusivo boolean;
  v_qtd_pops integer;
begin
  v_recomendado := app.calcular_preco_recomendado_dark_fiber(p_contrato_id);

  select valor into v_multiplicador_premium from public.pricing_parametros
  where chave = 'DARK_FIBER_MULTIPLICADOR_PREMIUM' and (vigente_ate is null or vigente_ate >= current_date);
  select valor into v_premio_exclusividade from public.pricing_parametros where chave = 'DARK_FIBER_PREMIO_EXCLUSIVIDADE';
  select valor into v_premio_multipop from public.pricing_parametros where chave = 'DARK_FIBER_PREMIO_MULTIPOP';

  select coalesce(exclusividade_comercial, false) into v_exclusivo
  from public.contrato_regras where contrato_id = p_contrato_id;

  select count(distinct p.pop_id) into v_qtd_pops
  from public.contrato_fibras cf
  join public.infra_portas_pon p on p.id = cf.porta_pon_id
  where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null;

  return round(
    v_recomendado
    * coalesce(v_multiplicador_premium, 1)
    * (case when coalesce(v_exclusivo, false) then coalesce(v_premio_exclusividade, 1) else 1 end)
    * (case when coalesce(v_qtd_pops, 0) > 1 then coalesce(v_premio_multipop, 1) else 1 end)
  , 2);
end;
$$;

comment on function app.calcular_preco_premium_dark_fiber(uuid) is 'PREÇO PREMIUM (seção 13) = recomendado × multiplicador comercial × bônus exclusividade × bônus multi-POP. Lógica parametrizável, nunca "recomendado × 2" fixo.';

-- Seção 11 (payback mínimo): informativo — não altera preço, só sinaliza.
create or replace function app.avaliar_payback_minimo(p_contrato_id uuid, p_payback_meses integer)
returns text
language plpgsql
stable
as $$
declare
  v_minimo integer;
begin
  select payback_minimo_meses into v_minimo from public.contrato_pricing_config where contrato_id = p_contrato_id;
  if v_minimo is null then
    return 'PARAMETRIZÁVEL — minimum_payback_months não definido para este contrato.';
  end if;
  if p_payback_meses is null then
    return 'N/A — payback não recuperado no horizonte analisado.';
  end if;
  if p_payback_meses <= v_minimo then
    return 'OK — payback dentro do mínimo exigido (' || v_minimo || ' meses).';
  end if;
  return 'ATENÇÃO — payback (' || p_payback_meses || ' meses) acima do mínimo exigido (' || v_minimo || ' meses).';
end;
$$;
