-- OptiMon — Fase 1.1
-- Views de capacidade por cidade/POP/parceiro/contrato (seção 13).
-- vw_pares_disponiveis (Fase 1) é mantida como está — informativa, já que par deixou
-- de ser requisito de comercialização, mas continua útil para quem quiser negociar
-- em pares por conveniência.

-- View-base reaproveitada pelas quatro views pedidas — evita duplicar a lógica de
-- "esta porta está contratada agora" em cada uma.
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

comment on view public.vw_porta_pon_detalhe is 'Base para as views de capacidade: cada porta PON com sua fibra/cabo/POP/cidade e se está contratada agora (Fase 1.1).';

-- A view da Fase 1 tinha colunas com nomes diferentes (capacidade_total_fo etc.) —
-- CREATE OR REPLACE não permite renomear/reordenar colunas, só recriar do zero.
drop view if exists public.vw_capacidade_cidade;

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

comment on view public.vw_capacidade_cidade is 'Capacidade agregada por cidade: fibras (total/bloqueadas/contratadas/livres) + portas PON (total/contratadas/disponíveis) + clientes (seção 13, substitui a versão simplificada da Fase 1).';

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

comment on view public.vw_capacidade_pop is 'Capacidade agregada por POP — exemplo da seção 13 (Jussara/POP-01: 10 fibras disponíveis, 4 portas contratadas, 512 capacidade, 180 ativos, 35,16% ocupação).';

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

comment on view public.vw_capacidade_parceiro is 'Capacidade contratada e ocupação por parceiro, considerando só contratos ATIVO (seção 13).';

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

comment on view public.vw_capacidade_contrato is 'Capacidade por contrato, incluindo quantos POPs distintos ele usa — suporta contrato com portas em múltiplos POPs (seção 12/13).';
