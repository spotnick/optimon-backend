-- OptiMon — Fase 1
-- Views de capacidade (evitam colunas redundantes/divergentes — seção 25).

create or replace view public.vw_pares_disponiveis as
select
  c.id as cabo_id,
  c.identificacao as cabo_identificacao,
  f.par_numero,
  count(*) filter (where f.status = 'LIVRE') as fibras_livres_no_par,
  count(*) as fibras_no_par,
  bool_and(f.status = 'LIVRE') as par_disponivel
from public.infra_fibras f
join public.infra_cabos c on c.id = f.cabo_id
group by c.id, c.identificacao, f.par_numero;

comment on view public.vw_pares_disponiveis is 'Um par (2 fibras) só está disponível se as duas fibras estiverem LIVRE.';

create or replace view public.vw_capacidade_cidade as
select
  ci.id as cidade_id,
  ci.nome as cidade,
  count(f.id) as capacidade_total_fo,
  count(f.id) filter (where f.status = 'LIVRE') as capacidade_livre_fo,
  count(f.id) filter (where f.status in ('RESERVADA','BLOQUEADA')) as capacidade_reservada_fo,
  count(f.id) filter (where f.status in ('LOCADA','OCUPADA')) as capacidade_contratada_fo
from public.cidades_infra ci
join public.infra_segmentos seg on seg.cidade_id = ci.id
join public.infra_cabos c on c.segmento_id = seg.id
join public.infra_fibras f on f.cabo_id = c.id
group by ci.id, ci.nome;

comment on view public.vw_capacidade_cidade is 'CAPACIDADE_TOTAL / LIVRE / RESERVADA / CONTRATADA por cidade, calculada a partir de infra_fibras.status (seção 25).';
