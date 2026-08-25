-- OptiMon — Fase 1.2
-- Seções 4, 5, 7, 14: separar CONTRATADA × RESERVADA × ATIVA (nunca confundir capacidade
-- da porta, clientes ativos, portas contratadas/reservadas/ativas — item 4), e expor
-- funções de agregação por contrato (item 7) + alertas de capacidade parametrizáveis
-- (item 14). Tudo por cima do que a Fase 1.1 criou em infra_portas_pon — nenhuma coluna
-- é removida, capacidade_disponivel/taxa_ocupacao continuam com o mesmo significado.

-- situacao_comercial da PORTA (não confundir com porta_pon_status, que é o estado físico
-- ATIVA/INATIVA/MANUTENCAO já existente desde a Fase 1.1 — aqui é o estado COMERCIAL):
--   DISPONIVEL: não está vinculada a nenhum contrato_fibras ativo agora.
--   RESERVADA:  está vinculada a um contrato ativo, mas ainda sem clientes reais (seção 5).
--   ATIVA:      está vinculada a um contrato ativo E tem pelo menos 1 cliente real (seção 5).
create type public.porta_pon_situacao_comercial as enum ('DISPONIVEL', 'RESERVADA', 'ATIVA');

alter table public.infra_portas_pon
  add column situacao_comercial public.porta_pon_situacao_comercial not null default 'DISPONIVEL';

create index infra_portas_pon_situacao_comercial_idx on public.infra_portas_pon (situacao_comercial);

comment on column public.infra_portas_pon.situacao_comercial is 'CONTRATADA×RESERVADA×ATIVA da seção 5: DISPONIVEL (sem contrato), RESERVADA (contratada, 0 clientes), ATIVA (contratada, >=1 cliente). Mantida por app.recalcular_situacao_porta(), nunca editada manualmente.';

-- app.recalcular_situacao_porta(): única fonte de verdade para o cálculo acima — chamada
-- tanto quando contrato_fibras muda (vínculo/desvínculo) quanto quando a contagem real de
-- clientes muda (via cliente_porta_pon, seção 12). Evita duplicar a mesma lógica em dois
-- triggers diferentes.
create or replace function app.recalcular_situacao_porta(p_porta_pon_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_porta_pon_id is null then
    return;
  end if;

  update public.infra_portas_pon p
  set situacao_comercial = case
      when not exists (
        select 1 from public.contrato_fibras cf
        where cf.porta_pon_id = p.id and cf.desvinculado_em is null
      ) then 'DISPONIVEL'::public.porta_pon_situacao_comercial
      when p.capacidade_utilizada_assinantes > 0 then 'ATIVA'::public.porta_pon_situacao_comercial
      else 'RESERVADA'::public.porta_pon_situacao_comercial
    end
  where p.id = p_porta_pon_id;
end;
$$;

comment on function app.recalcular_situacao_porta(uuid) is 'Recalcula infra_portas_pon.situacao_comercial a partir do vínculo ativo em contrato_fibras e de capacidade_utilizada_assinantes (seção 5). Chamada por triggers em contrato_fibras e em cliente_porta_pon — nunca a lógica duplicada em dois lugares.';

-- Backfill: aplica a mesma regra a toda porta já cadastrada (Fase 1.1) — não altera
-- capacidade_utilizada_assinantes de ninguém, só classifica o que já existe.
do $$
declare
  r record;
begin
  for r in select id from public.infra_portas_pon loop
    perform app.recalcular_situacao_porta(r.id);
  end loop;
end $$;

-- Trigger em contrato_fibras: qualquer inclusão/alteração/desvínculo de porta recalcula
-- a situação da(s) porta(s) envolvida(s) — cobre o caso de porta_pon_id mudar num UPDATE.
create or replace function public.fn_contrato_fibras_recalcula_situacao_porta()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'DELETE' then
    perform app.recalcular_situacao_porta(old.porta_pon_id);
    return old;
  end if;

  perform app.recalcular_situacao_porta(new.porta_pon_id);
  if TG_OP = 'UPDATE' and old.porta_pon_id is distinct from new.porta_pon_id then
    perform app.recalcular_situacao_porta(old.porta_pon_id);
  end if;
  return new;
end;
$$;

create trigger trg_contrato_fibras_recalcula_situacao_porta
  after insert or update or delete on public.contrato_fibras
  for each row execute function public.fn_contrato_fibras_recalcula_situacao_porta();

-- Colunas de capacidade por porta pedidas na seção 4 — geradas, nunca divergem, e cada
-- uma calculada só a partir de colunas simples da própria linha (uma coluna GENERATED do
-- Postgres não pode referenciar outra coluna GENERATED, por isso cada uma repete a mesma
-- base em vez de subtrair as outras entre si).
--
-- capacidade_reservada_assinantes já existia (Fase 1.1, sempre 0 — nunca foi usada de
-- verdade). Recriada aqui como coluna gerada de verdade, sem quebrar o nome/contrato já
-- publicado. CASCADE derruba as 5 views de capacidade da Fase 1.1 que leem esta coluna
-- (vw_porta_pon_detalhe e as 4 que dependem dela) — todas são recriadas mais abaixo,
-- IDÊNTICAS em definição (só a fonte de capacidade_reservada_assinantes passa a ser real
-- em vez de sempre 0), nenhuma view deixa de existir.
alter table public.infra_portas_pon drop column capacidade_reservada_assinantes cascade;
alter table public.infra_portas_pon
  add column capacidade_reservada_assinantes integer generated always as (
    case when situacao_comercial = 'RESERVADA' then capacidade_max_assinantes else 0 end
  ) stored;
comment on column public.infra_portas_pon.capacidade_reservada_assinantes is 'Capacidade (assinantes) da porta quando RESERVADA (contratada, ainda sem clientes reais) — 0 quando DISPONIVEL ou ATIVA (seção 4/5). Coluna gerada.';

alter table public.infra_portas_pon
  add column capacidade_contratada_assinantes integer generated always as (
    case when situacao_comercial in ('RESERVADA', 'ATIVA') then capacidade_max_assinantes else 0 end
  ) stored,
  add column capacidade_ativa_assinantes integer generated always as (
    case when situacao_comercial = 'ATIVA' then capacidade_max_assinantes else 0 end
  ) stored,
  add column clientes_ativos integer generated always as (capacidade_utilizada_assinantes) stored;

comment on column public.infra_portas_pon.capacidade_contratada_assinantes is 'capacidade_max_assinantes quando a porta está CONTRATADA (RESERVADA ou ATIVA), 0 quando DISPONIVEL (seção 4).';
comment on column public.infra_portas_pon.capacidade_ativa_assinantes is 'capacidade_max_assinantes quando a porta está ATIVA (>=1 cliente real), 0 caso contrário (seção 4/7 — usado para somar "256" no exemplo de 2 portas ativas × 128).';
comment on column public.infra_portas_pon.clientes_ativos is 'Alias de capacidade_utilizada_assinantes com o nome literal pedido na seção 4/12 — mesma fonte de verdade, sem duplicar dado.';

-- Seção 14: thresholds de alerta de capacidade — parametrizáveis, nunca hard-coded.
insert into public.pricing_parametros (chave, valor, unidade, descricao) values
  ('ALERTA_CAPACIDADE_PORTA_80', 0.80, 'percentual', 'Threshold de alerta CAPACIDADE_80 (seção 14) — percentual de ocupação da porta PON que dispara o alerta informativo.'),
  ('ALERTA_CAPACIDADE_PORTA_90', 0.90, 'percentual', 'Threshold de alerta CAPACIDADE_90 (seção 14).'),
  ('ALERTA_CAPACIDADE_PORTA_100', 1.00, 'percentual', 'Threshold de alerta CAPACIDADE_100 — porta no limite máximo (seção 14).')
on conflict (chave) do nothing;

-- Novos tipos de alerta de capacidade (seção 14). CAPACIDADE_EXCEDIDA já existia desde a
-- Fase 1 no enum alerta_tipo.
alter type public.alerta_tipo add value if not exists 'CAPACIDADE_80';
alter type public.alerta_tipo add value if not exists 'CAPACIDADE_90';
alter type public.alerta_tipo add value if not exists 'CAPACIDADE_100';

-- alertas ganha referência opcional à porta PON — necessário para os alertas de
-- capacidade por porta (seção 14) apontarem para o recurso exato.
alter table public.alertas
  add column porta_pon_id uuid references public.infra_portas_pon(id) on delete set null;
create index alertas_porta_pon_idx on public.alertas (porta_pon_id);

comment on column public.alertas.porta_pon_id is 'Porta PON de referência para alertas de capacidade (CAPACIDADE_80/90/100/EXCEDIDA — seção 14). Nulo para alertas que não são de porta específica.';

-- app.check_port_capacity() — seção 13: regra de capacidade vive no banco, nunca só no
-- frontend. Retorna ALLOW ou CAPACITY_EXCEEDED sem alterar nada (checagem pura).
create or replace function app.check_port_capacity(p_porta_pon_id uuid, p_incremento integer default 1)
returns text
language sql
stable
as $$
  select case
    when coalesce(p.capacidade_utilizada_assinantes, 0) + p_incremento > p.capacidade_max_assinantes
      then 'CAPACITY_EXCEEDED'
    else 'ALLOW'
  end
  from public.infra_portas_pon p
  where p.id = p_porta_pon_id;
$$;

comment on function app.check_port_capacity(uuid, integer) is 'ALLOW / CAPACITY_EXCEEDED — checagem pura de capacidade da porta (seção 13). O bloqueio de verdade acontece no trigger de cliente_porta_pon (Fase 1.2, arquivo 03), que chama esta função antes de cada ativação.';

-- Seção 7: funções de agregação de capacidade POR CONTRATO. Consideram só as portas
-- vinculadas a este contrato via contrato_fibras ativo (desvinculado_em is null, status
-- ATIVO) — a mesma porta nunca conta duas vezes porque contrato_fibras_porta_ativa_idx
-- (Fase 1.1) já impede 2 vínculos exclusivos simultâneos na mesma porta.
create or replace function app.get_contract_capacity(p_contrato_id uuid)
returns integer
language sql
stable
as $$
  select coalesce(sum(p.capacidade_contratada_assinantes), 0)::integer
  from public.infra_portas_pon p
  join public.contrato_fibras cf on cf.porta_pon_id = p.id
  where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null;
$$;
comment on function app.get_contract_capacity(uuid) is 'Capacidade CONTRATADA total do contrato = soma de capacidade_max_assinantes de todas as portas vinculadas (RESERVADAS + ATIVAS). Exemplo seção 7: 5 portas × 128 = 640.';

create or replace function app.get_reserved_capacity(p_contrato_id uuid)
returns integer
language sql
stable
as $$
  select coalesce(sum(p.capacidade_reservada_assinantes), 0)::integer
  from public.infra_portas_pon p
  join public.contrato_fibras cf on cf.porta_pon_id = p.id
  where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null;
$$;
comment on function app.get_reserved_capacity(uuid) is 'Capacidade RESERVADA do contrato = soma de capacidade_max_assinantes só das portas contratadas ainda sem cliente real (seção 5/7).';

create or replace function app.get_active_capacity(p_contrato_id uuid)
returns integer
language sql
stable
as $$
  select coalesce(sum(p.capacidade_ativa_assinantes), 0)::integer
  from public.infra_portas_pon p
  join public.contrato_fibras cf on cf.porta_pon_id = p.id
  where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null;
$$;
comment on function app.get_active_capacity(uuid) is 'Capacidade ATIVA do contrato = soma de capacidade_max_assinantes só das portas com >=1 cliente real. Exemplo seção 7: 2 portas ativas × 128 = 256.';

create or replace function app.get_occupied_capacity(p_contrato_id uuid)
returns integer
language sql
stable
as $$
  select coalesce(sum(p.capacidade_utilizada_assinantes), 0)::integer
  from public.infra_portas_pon p
  join public.contrato_fibras cf on cf.porta_pon_id = p.id
  where cf.contrato_id = p_contrato_id and cf.desvinculado_em is null;
$$;
comment on function app.get_occupied_capacity(uuid) is 'Clientes reais conectados no contrato (soma de clientes_ativos de todas as portas vinculadas). Exemplo seção 7: 120 clientes.';

create or replace function app.get_available_capacity(p_contrato_id uuid)
returns integer
language sql
stable
as $$
  select app.get_contract_capacity(p_contrato_id) - app.get_occupied_capacity(p_contrato_id);
$$;
comment on function app.get_available_capacity(uuid) is 'Capacidade contratada ainda não ocupada por clientes reais = get_contract_capacity() - get_occupied_capacity() (ex.: 640 - 120 = 520).';

-- View de conveniência: as duas métricas de ocupação da seção 7 lado a lado, sempre
-- identificáveis separadamente (120/256 = 46,875% da capacidade ATIVA vs. 120/640 =
-- 18,75% da capacidade CONTRATADA) + as contagens de portas da seção 5.
create or replace view public.vw_contrato_capacidade as
select
  c.id as contrato_id,
  c.numero as contrato_numero,
  count(p.id) filter (where p.situacao_comercial in ('RESERVADA', 'ATIVA')) as portas_contratadas,
  count(p.id) filter (where p.situacao_comercial = 'ATIVA') as portas_ativas,
  count(p.id) filter (where p.situacao_comercial = 'RESERVADA') as portas_reservadas,
  app.get_contract_capacity(c.id) as capacidade_contratada,
  app.get_reserved_capacity(c.id) as capacidade_reservada,
  app.get_active_capacity(c.id) as capacidade_ativa,
  app.get_occupied_capacity(c.id) as clientes_ativos,
  app.get_available_capacity(c.id) as capacidade_disponivel,
  case when app.get_active_capacity(c.id) > 0
    then round(app.get_occupied_capacity(c.id)::numeric / app.get_active_capacity(c.id), 4)
    else 0
  end as taxa_ocupacao_capacidade_ativa,
  case when app.get_contract_capacity(c.id) > 0
    then round(app.get_occupied_capacity(c.id)::numeric / app.get_contract_capacity(c.id), 4)
    else 0
  end as taxa_ocupacao_capacidade_contratada
from public.contratos c
left join public.contrato_fibras cf on cf.contrato_id = c.id and cf.desvinculado_em is null
left join public.infra_portas_pon p on p.id = cf.porta_pon_id
group by c.id, c.numero;

comment on view public.vw_contrato_capacidade is 'Portas contratadas/ativas/reservadas + as duas métricas de ocupação da seção 7 (sobre capacidade ativa vs. sobre capacidade contratada), nunca confundidas uma com a outra.';

-- Recria as 5 views da Fase 1.1 derrubadas pelo CASCADE acima — definições IDÊNTICAS às
-- de supabase/migrations/20260825101000_capacidade_views.sql. Nenhuma coluna, nome ou
-- semântica muda para quem já consome essas views; só a fonte de capacidade_reservada_assinantes
-- passa a ser real (antes sempre 0).
create or replace view public.vw_porta_pon_detalhe as
select
  pp.id as porta_pon_id,
  pp.codigo_porta,
  pp.tecnologia,
  pp.status as porta_status,
  pp.capacidade_max_assinantes,
  pp.capacidade_reservada_assinantes,
  pp.capacidade_utilizada_assinantes,
  pp.capacidade_disponivel,
  pp.taxa_ocupacao,
  f.id as fibra_id,
  f.status_comercial,
  f.status_contratual,
  cb.id as cabo_id,
  cb.pop_id,
  pop.cidade_id,
  cf.contrato_id,
  (cf.contrato_id is not null) as contratada
from public.infra_portas_pon pp
join public.infra_fibras f on f.id = pp.fibra_id
join public.infra_cabos cb on cb.id = f.cabo_id
join public.infra_pops pop on pop.id = cb.pop_id
left join lateral (
  select cf2.contrato_id
  from public.contrato_fibras cf2
  where cf2.porta_pon_id = pp.id and cf2.desvinculado_em is null
  order by cf2.vinculado_em desc
  limit 1
) cf on true;

comment on view public.vw_porta_pon_detalhe is 'Base para as views de capacidade: cada porta PON com sua fibra/cabo/POP/cidade e se está contratada agora (Fase 1.1; recriada na Fase 1.2 só por causa do CASCADE de capacidade_reservada_assinantes).';

create view public.vw_capacidade_cidade as
with fibras as (
  select pop.cidade_id,
    count(f.id) as fibras_totais,
    count(f.id) filter (where f.status_comercial = 'BLOQUEADA') as fibras_bloqueadas,
    count(f.id) filter (where f.status_contratual = 'VINCULADA') as fibras_contratadas,
    count(f.id) filter (where f.status_comercial = 'LIVRE' and f.status_contratual = 'DISPONIVEL') as fibras_livres
  from public.infra_fibras f
  join public.infra_cabos cb on cb.id = f.cabo_id
  join public.infra_pops pop on pop.id = cb.pop_id
  group by pop.cidade_id
),
portas as (
  select cidade_id,
    count(*) as portas_pon_totais,
    count(*) filter (where contratada) as portas_contratadas,
    count(*) filter (where not contratada) as portas_disponiveis,
    coalesce(sum(capacidade_max_assinantes), 0) as capacidade_maxima_clientes,
    coalesce(sum(capacidade_utilizada_assinantes), 0) as clientes_ativos,
    coalesce(sum(capacidade_disponivel), 0) as capacidade_disponivel_clientes
  from public.vw_porta_pon_detalhe
  group by cidade_id
)
select
  ci.id as cidade_id,
  ci.nome as cidade,
  coalesce(fibras.fibras_totais, 0) as fibras_totais,
  coalesce(fibras.fibras_bloqueadas, 0) as fibras_bloqueadas,
  coalesce(fibras.fibras_contratadas, 0) as fibras_contratadas,
  coalesce(fibras.fibras_livres, 0) as fibras_livres,
  coalesce(portas.portas_pon_totais, 0) as portas_pon_totais,
  coalesce(portas.portas_contratadas, 0) as portas_contratadas,
  coalesce(portas.portas_disponiveis, 0) as portas_disponiveis,
  coalesce(portas.capacidade_maxima_clientes, 0) as capacidade_maxima_clientes,
  coalesce(portas.clientes_ativos, 0) as clientes_ativos,
  coalesce(portas.capacidade_disponivel_clientes, 0) as capacidade_disponivel_clientes,
  case when coalesce(portas.capacidade_maxima_clientes, 0) > 0
    then round(portas.clientes_ativos::numeric / portas.capacidade_maxima_clientes, 4)
    else 0
  end as taxa_ocupacao
from public.cidades_infra ci
left join fibras on fibras.cidade_id = ci.id
left join portas on portas.cidade_id = ci.id;

comment on view public.vw_capacidade_cidade is 'Capacidade agregada por cidade: fibras (total/bloqueadas/contratadas/livres) + portas PON (total/contratadas/disponíveis) + clientes (Fase 1.1, recriada na Fase 1.2 por causa do CASCADE).';

create or replace view public.vw_capacidade_pop as
with fibras as (
  select cb.pop_id,
    count(f.id) as fibras_totais,
    count(f.id) filter (where f.status_comercial = 'BLOQUEADA') as fibras_bloqueadas,
    count(f.id) filter (where f.status_contratual = 'VINCULADA') as fibras_contratadas,
    count(f.id) filter (where f.status_comercial = 'LIVRE' and f.status_contratual = 'DISPONIVEL') as fibras_livres
  from public.infra_fibras f
  join public.infra_cabos cb on cb.id = f.cabo_id
  group by cb.pop_id
)
select
  pop.id as pop_id,
  pop.cidade_id,
  pop.codigo as pop_codigo,
  pop.nome as pop_nome,
  coalesce(fibras.fibras_totais, 0) as fibras_totais,
  coalesce(fibras.fibras_bloqueadas, 0) as fibras_bloqueadas,
  coalesce(fibras.fibras_contratadas, 0) as fibras_contratadas,
  coalesce(fibras.fibras_livres, 0) as fibras_livres,
  count(vp.porta_pon_id) as portas_pon_totais,
  count(vp.porta_pon_id) filter (where vp.contratada) as portas_contratadas,
  count(vp.porta_pon_id) filter (where not vp.contratada) as portas_disponiveis,
  coalesce(sum(vp.capacidade_max_assinantes), 0) as capacidade_maxima_clientes,
  coalesce(sum(vp.capacidade_utilizada_assinantes), 0) as clientes_ativos,
  coalesce(sum(vp.capacidade_disponivel), 0) as capacidade_disponivel_clientes,
  case when coalesce(sum(vp.capacidade_max_assinantes), 0) > 0
    then round(sum(vp.capacidade_utilizada_assinantes)::numeric / sum(vp.capacidade_max_assinantes), 4)
    else 0
  end as taxa_ocupacao
from public.infra_pops pop
left join fibras on fibras.pop_id = pop.id
left join public.vw_porta_pon_detalhe vp on vp.pop_id = pop.id
group by pop.id, pop.cidade_id, pop.codigo, pop.nome, fibras.fibras_totais, fibras.fibras_bloqueadas, fibras.fibras_contratadas, fibras.fibras_livres;

comment on view public.vw_capacidade_pop is 'Capacidade agregada por POP (Fase 1.1, recriada na Fase 1.2 por causa do CASCADE).';

create or replace view public.vw_capacidade_parceiro as
select
  p.id as parceiro_id,
  p.razao_social,
  count(distinct c.id) as contratos_ativos,
  count(distinct vp.porta_pon_id) filter (where vp.contratada) as portas_contratadas,
  coalesce(sum(vp.capacidade_max_assinantes) filter (where vp.contratada), 0) as capacidade_maxima_clientes,
  coalesce(sum(vp.capacidade_utilizada_assinantes) filter (where vp.contratada), 0) as clientes_ativos,
  case when coalesce(sum(vp.capacidade_max_assinantes) filter (where vp.contratada), 0) > 0
    then round(sum(vp.capacidade_utilizada_assinantes) filter (where vp.contratada)::numeric / sum(vp.capacidade_max_assinantes) filter (where vp.contratada), 4)
    else 0
  end as taxa_ocupacao
from public.parceiros p
left join public.contratos c on c.parceiro_id = p.id and c.status = 'ATIVO'
left join public.vw_porta_pon_detalhe vp on vp.contrato_id = c.id
group by p.id, p.razao_social;

comment on view public.vw_capacidade_parceiro is 'Capacidade contratada e ocupação por parceiro (Fase 1.1, recriada na Fase 1.2 por causa do CASCADE).';

create or replace view public.vw_capacidade_contrato as
select
  c.id as contrato_id,
  c.numero as contrato_numero,
  c.parceiro_id,
  c.status as contrato_status,
  count(distinct vp.porta_pon_id) as portas_pon,
  count(distinct vp.pop_id) as pops_utilizados,
  coalesce(sum(vp.capacidade_max_assinantes), 0) as capacidade_maxima_clientes,
  coalesce(sum(vp.capacidade_utilizada_assinantes), 0) as clientes_ativos,
  case when coalesce(sum(vp.capacidade_max_assinantes), 0) > 0
    then round(sum(vp.capacidade_utilizada_assinantes)::numeric / sum(vp.capacidade_max_assinantes), 4)
    else 0
  end as taxa_ocupacao
from public.contratos c
left join public.vw_porta_pon_detalhe vp on vp.contrato_id = c.id
group by c.id, c.numero, c.parceiro_id, c.status;

comment on view public.vw_capacidade_contrato is 'Capacidade por contrato (Fase 1.1, recriada na Fase 1.2 por causa do CASCADE).';
