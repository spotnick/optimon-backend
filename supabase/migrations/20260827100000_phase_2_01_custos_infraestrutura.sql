-- OptiMon — Fase 2
-- Seções 7, 8, 9, 10: classificação de custos + rateio. A rede JÁ EXISTE — o objetivo é
-- monetizar capacidade ociosa, não repassar 100% do custo histórico ao parceiro. Este
-- arquivo cria a estrutura; a decisão de QUANTO repassar continua sempre parametrizável
-- (percentual_alocacao por linha), nunca uma fórmula fixa no código.

create type public.cost_type as enum (
  'HISTORICAL_CAPEX',   -- já investido, sunk cost — nunca tratado como incremental (seção 7).
  'EXISTING_OPEX',      -- continua existindo com ou sem o parceiro (não evitável).
  'INCREMENTAL_OPEX',   -- opex causado especificamente por esta oportunidade (evitável).
  'INCREMENTAL_CAPEX',  -- capex adicional necessário para viabilizar esta oportunidade (evitável).
  'ALLOCATED_COST',     -- custo compartilhado da rede, rateado proporcionalmente ao uso.
  'REVENUE_EXISTING',   -- receita que a rede já gera hoje (ex.: contrato da Prefeitura) — nunca custo.
  'OTHER'
);

comment on type public.cost_type is 'Seção 9. Mapeamento conceitual da seção 7: NÃO EVITÁVEL = HISTORICAL_CAPEX/EXISTING_OPEX (existem com ou sem o parceiro, nunca entram na base de precificação incremental); EVITÁVEL/INCREMENTAL = INCREMENTAL_OPEX/INCREMENTAL_CAPEX (causados pela oportunidade); ALOCADO = ALLOCATED_COST (custo compartilhado, rateado). REVENUE_EXISTING nunca é custo — é receita já existente (ex.: Prefeitura), usada só para contexto econômico, nunca somada aos custos.';

create type public.metodo_rateio as enum ('POR_POSTE', 'POR_KM', 'POR_FIBRA', 'POR_PORTA');

create table public.custos_infraestrutura (
  id uuid primary key default gen_random_uuid(),
  descricao text not null,
  valor numeric(14,2) not null check (valor >= 0),
  periodicidade text not null default 'MENSAL' check (periodicidade in ('UNICO', 'MENSAL', 'ANUAL')),
  cidade_id uuid not null references public.cidades_infra(id) on delete restrict,
  pop_id uuid references public.infra_pops(id) on delete set null,
  poste_id uuid references public.infra_postes(id) on delete set null,
  cabo_id uuid references public.infra_cabos(id) on delete set null,
  ativo_id uuid references public.ativos(id) on delete set null,
  -- Custo INCREMENTAL pode (mas não precisa) já nascer amarrado a um contrato específico
  -- (ex.: equipamento comprado especificamente para este parceiro). Custos EXISTING/HISTORICAL
  -- nunca têm contrato_id — são da infraestrutura, não de um negócio específico (seção 7).
  contrato_id uuid references public.contratos(id) on delete set null,
  cost_type public.cost_type not null,
  metodo_rateio public.metodo_rateio,
  percentual_alocacao numeric(6,5) not null default 1.0 check (percentual_alocacao between 0 and 1),
  data_inicio date not null default current_date,
  data_fim date,
  observacoes text,
  criado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (data_fim is null or data_fim >= data_inicio),
  constraint custos_infraestrutura_incremental_opex_precisa_origem
    check (cost_type <> 'INCREMENTAL_OPEX' or contrato_id is not null or metodo_rateio is not null),
  constraint custos_infraestrutura_incremental_capex_precisa_origem
    check (cost_type <> 'INCREMENTAL_CAPEX' or contrato_id is not null or metodo_rateio is not null)
);
create index custos_infraestrutura_cidade_idx on public.custos_infraestrutura (cidade_id);
create index custos_infraestrutura_pop_idx on public.custos_infraestrutura (pop_id);
create index custos_infraestrutura_contrato_idx on public.custos_infraestrutura (contrato_id);
create index custos_infraestrutura_cost_type_idx on public.custos_infraestrutura (cost_type);
create trigger trg_custos_infraestrutura_atualizado_em
  before update on public.custos_infraestrutura
  for each row execute function public.set_atualizado_em();

comment on table public.custos_infraestrutura is 'Custos (e receita existente) da infraestrutura, classificados (seção 9) — cada linha é uma decisão explícita, nunca um cálculo automático "100% do histórico vira custo do parceiro".';
comment on column public.custos_infraestrutura.percentual_alocacao is 'Fração deste custo que efetivamente entra na base de precificação/rateio (seção 8) — permite reconhecer um custo sem repassá-lo integralmente. Default 1.0 (100%), sempre editável.';
comment on constraint custos_infraestrutura_incremental_opex_precisa_origem on public.custos_infraestrutura is 'INCREMENTAL_OPEX precisa estar amarrado a um contrato específico OU ter um método de rateio definido — nunca "incremental" sem se saber de onde vem nem como se calcula.';
comment on constraint custos_infraestrutura_incremental_capex_precisa_origem on public.custos_infraestrutura is 'Mesma regra para INCREMENTAL_CAPEX.';

-- app.ratear_custo(): aplica o método de rateio escolhido na própria linha (seção 10 —
-- "o usuário deverá poder escolher o método") e devolve o valor por unidade (poste/km/
-- fibra/porta). Puramente informativo — não decide sozinho quanto repassar.
create or replace function app.ratear_custo(p_custo_id uuid)
returns numeric
language plpgsql
stable
as $$
declare
  v_custo record;
  v_unidades numeric;
begin
  select * into v_custo from public.custos_infraestrutura where id = p_custo_id;
  if not found or v_custo.metodo_rateio is null then
    return null;
  end if;

  v_unidades := case v_custo.metodo_rateio
    when 'POR_POSTE' then (
      select coalesce(sum(quantidade), 0) from public.infra_postes
      where cidade_id = v_custo.cidade_id and removido_em is null
        and (v_custo.poste_id is null or id = v_custo.poste_id)
    )
    when 'POR_KM' then (
      select coalesce(sum(extensao_km), 0) from public.infra_segmentos
      where cidade_id = v_custo.cidade_id and removido_em is null
    )
    when 'POR_FIBRA' then (
      select count(*)::numeric from public.infra_fibras f
      join public.infra_cabos cb on cb.id = f.cabo_id
      join public.infra_segmentos s on s.id = cb.segmento_id
      where s.cidade_id = v_custo.cidade_id
        and (v_custo.cabo_id is null or cb.id = v_custo.cabo_id)
    )
    when 'POR_PORTA' then (
      select count(*)::numeric from public.infra_portas_pon p
      join public.infra_fibras f on f.id = p.fibra_id
      join public.infra_cabos cb on cb.id = f.cabo_id
      join public.infra_segmentos s on s.id = cb.segmento_id
      where s.cidade_id = v_custo.cidade_id
        and (v_custo.pop_id is null or p.pop_id = v_custo.pop_id)
    )
    else null
  end;

  if v_unidades is null or v_unidades = 0 then
    return null;
  end if;

  return round((v_custo.valor * v_custo.percentual_alocacao) / v_unidades, 4);
end;
$$;

comment on function app.ratear_custo(uuid) is 'Valor rateado por unidade (poste/km/fibra/porta, conforme metodo_rateio da própria linha — seção 10). Ex.: R$1.108,80 / 165 postes = R$6,72/poste.';

-- app.get_custo_base_precificacao(): a base de custo que efetivamente entra no cálculo do
-- preço mínimo (seção 11) — SOMENTE incremental (evitável) + alocado (rateado
-- proporcionalmente ao que este contrato usa). HISTORICAL_CAPEX, EXISTING_OPEX e
-- REVENUE_EXISTING NUNCA entram aqui — é exatamente o alerta explícito da seção 7/8: não
-- assumir que 100% do custo histórico da rede é custo incremental do parceiro.
create or replace function app.get_custo_base_precificacao(p_contrato_id uuid)
returns numeric
language plpgsql
stable
as $$
declare
  v_incremental numeric;
  v_alocado numeric := 0;
  v_cidade_id uuid;
  v_qtd_fibras_contrato numeric;
  v_qtd_fibras_totais numeric;
  r record;
begin
  select cidade_id into v_cidade_id from public.contratos where id = p_contrato_id;

  -- Incremental: custos amarrados diretamente a este contrato (evitável — só existe por
  -- causa desta oportunidade).
  select coalesce(sum(valor * percentual_alocacao), 0) into v_incremental
  from public.custos_infraestrutura
  where contrato_id = p_contrato_id
    and cost_type in ('INCREMENTAL_OPEX', 'INCREMENTAL_CAPEX')
    and (data_fim is null or data_fim >= current_date);

  -- Alocado: custos compartilhados da cidade (ALLOCATED_COST), rateados proporcionalmente
  -- à fração de fibras que este contrato ocupa no total de fibras da cidade — nunca 100%
  -- do custo do lote inteiro de postes/cabo para um único parceiro.
  select count(*)::numeric into v_qtd_fibras_contrato
  from public.contrato_fibras cf
  where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null;

  select count(*)::numeric into v_qtd_fibras_totais
  from public.infra_fibras f
  join public.infra_cabos cb on cb.id = f.cabo_id
  join public.infra_segmentos s on s.id = cb.segmento_id
  where s.cidade_id = v_cidade_id;

  if v_qtd_fibras_totais > 0 and v_qtd_fibras_contrato > 0 then
    for r in
      select valor, percentual_alocacao from public.custos_infraestrutura
      where cidade_id = v_cidade_id
        and cost_type = 'ALLOCATED_COST'
        and contrato_id is null
        and (data_fim is null or data_fim >= current_date)
    loop
      v_alocado := v_alocado + (r.valor * r.percentual_alocacao) * (v_qtd_fibras_contrato / v_qtd_fibras_totais);
    end loop;
  end if;

  return round(coalesce(v_incremental, 0) + coalesce(v_alocado, 0), 2);
end;
$$;

comment on function app.get_custo_base_precificacao(uuid) is 'Base de custo (mensal) usada no preço mínimo (seção 11): INCREMENTAL_* do contrato + ALLOCATED_COST rateado proporcionalmente à fração de fibras que o contrato usa. Nunca inclui HISTORICAL_CAPEX/EXISTING_OPEX/REVENUE_EXISTING — seção 7/8.';
