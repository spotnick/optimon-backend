-- OptiMon — Fase 1.1
-- Porta PON: a unidade comercial real do OptiMon (seções 1-3, 6, 9).
-- Uma fibra individual + splitter atende até N assinantes (128 por padrão, mas
-- parametrizável — nunca hard-coded aqui, o valor vive em pricing_parametros).

create type pon_tecnologia as enum ('GPON', 'XG-PON', 'XGS-PON', 'OUTRA');
create type porta_pon_status as enum ('ATIVA', 'INATIVA', 'MANUTENCAO');

-- Parâmetro de referência — NÃO um default hard-coded na coluna. A aplicação/seed lê
-- daqui; o trigger fn_porta_pon_default_capacidade só usa isto como fallback quando
-- a capacidade não é informada explicitamente na criação da porta.
insert into public.pricing_parametros (chave, valor, unidade, descricao)
values ('PORTA_PON_CAPACIDADE_MAX_PADRAO', 128, 'assinantes', 'Capacidade padrão de assinantes por porta PON quando não especificada explicitamente (seção 2 do prompt de Fase 1.1).')
on conflict (chave) do nothing;

create table public.infra_portas_pon (
  id uuid primary key default gen_random_uuid(),
  fibra_id uuid not null references public.infra_fibras(id) on delete restrict,
  pop_id uuid not null references public.infra_pops(id) on delete restrict,
  nome text,
  codigo_porta text not null,
  tecnologia pon_tecnologia not null default 'GPON',
  capacidade_max_assinantes integer,
  capacidade_reservada_assinantes integer not null default 0,
  capacidade_utilizada_assinantes integer not null default 0,
  status porta_pon_status not null default 'ATIVA',
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (fibra_id),
  unique (pop_id, codigo_porta),
  check (capacidade_max_assinantes is null or capacidade_max_assinantes > 0),
  check (capacidade_reservada_assinantes >= 0),
  check (capacidade_utilizada_assinantes >= 0),
  -- item 33: "clientes > capacidade máxima" deve ser impedido pelo banco.
  check (capacidade_max_assinantes is null or capacidade_utilizada_assinantes <= capacidade_max_assinantes),
  check (capacidade_max_assinantes is null or capacidade_reservada_assinantes <= capacidade_max_assinantes)
);
create index infra_portas_pon_pop_idx on public.infra_portas_pon (pop_id);
create index infra_portas_pon_status_idx on public.infra_portas_pon (status);
create trigger trg_infra_portas_pon_atualizado_em
  before update on public.infra_portas_pon
  for each row execute function public.set_atualizado_em();

comment on table public.infra_portas_pon is '1 fibra → até 1 porta PON → até capacidade_max_assinantes clientes (seção 3). Cliente nunca é 1:1 com fibra.';
comment on column public.infra_portas_pon.capacidade_utilizada_assinantes is 'Clientes ativos reais nessa porta (alimentado pela conciliação com HubSoft na Fase 4 — na Fase 1.1 é atualizado manualmente/via seed).';

-- capacidade_max_assinantes é preenchido a partir de PORTA_PON_CAPACIDADE_MAX_PADRAO
-- quando não informado — mantém o valor 128 fora do código/DDL (parametrizável de verdade).
create or replace function public.fn_porta_pon_default_capacidade()
returns trigger
language plpgsql
as $$
begin
  if new.capacidade_max_assinantes is null then
    select valor::integer into new.capacidade_max_assinantes
    from public.pricing_parametros
    where chave = 'PORTA_PON_CAPACIDADE_MAX_PADRAO'
      and (vigente_ate is null or vigente_ate >= current_date);

    if new.capacidade_max_assinantes is null then
      raise exception 'Não foi possível determinar capacidade_max_assinantes: informe explicitamente ou cadastre o parâmetro PORTA_PON_CAPACIDADE_MAX_PADRAO.';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_porta_pon_default_capacidade
  before insert on public.infra_portas_pon
  for each row execute function public.fn_porta_pon_default_capacidade();

-- Colunas derivadas — sempre consistentes por construção (evita divergência, mesmo
-- design já usado nas views de capacidade da Fase 1).
alter table public.infra_portas_pon
  add column capacidade_disponivel integer generated always as (capacidade_max_assinantes - capacidade_utilizada_assinantes) stored,
  add column taxa_ocupacao numeric(6,4) generated always as (
    case when capacidade_max_assinantes > 0
      then round(capacidade_utilizada_assinantes::numeric / capacidade_max_assinantes, 4)
      else 0
    end
  ) stored;

comment on column public.infra_portas_pon.capacidade_disponivel is 'capacidade_max_assinantes - capacidade_utilizada_assinantes (seção 6). Coluna gerada — nunca diverge.';
comment on column public.infra_portas_pon.taxa_ocupacao is 'clientes_ativos / capacidade_max_assinantes (seção 6). Coluna gerada.';

-- item 9: a fibra da porta PON precisa pertencer ao mesmo POP declarado na porta.
create or replace function public.fn_valida_porta_pon_pop()
returns trigger
language plpgsql
as $$
declare
  v_pop_cabo uuid;
begin
  select c.pop_id into v_pop_cabo
  from public.infra_fibras f
  join public.infra_cabos c on c.id = f.cabo_id
  where f.id = new.fibra_id;

  if v_pop_cabo is null then
    raise exception 'Fibra % está associada a um cabo sem POP definido — associe o cabo a um POP antes de criar a porta PON.', new.fibra_id;
  end if;

  if v_pop_cabo <> new.pop_id then
    raise exception 'Porta PON aponta para pop_id % mas a fibra % pertence ao POP % (via cabo). Fibra deve pertencer à infraestrutura do POP informado (seção 9).', new.pop_id, new.fibra_id, v_pop_cabo;
  end if;

  return new;
end;
$$;

create trigger trg_valida_porta_pon_pop
  before insert or update on public.infra_portas_pon
  for each row execute function public.fn_valida_porta_pon_pop();
