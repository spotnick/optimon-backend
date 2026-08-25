-- OptiMon — Fase 2.2.1 (Parte 2) — seções 27/28: exibir a Rampa e preparar a estrutura de
-- Reajuste (IPCA/IGP-M) na tela de simulação, sem o frontend consultar tabela nenhuma
-- diretamente — só mais 2 wrappers finos, mesmo padrão de sempre.

create or replace function public.pricing_ramp_rules_list(p_contrato_id uuid default null)
returns setof public.pricing_ramp_rules
language sql
stable
security invoker
as $$
  select * from public.pricing_ramp_rules
  where contrato_id is not distinct from p_contrato_id
  order by month_start;
$$;
comment on function public.pricing_ramp_rules_list(uuid) is 'Seção 27 — regra de rampa (meses 1-3/4-6/7+) para exibir no simulador. Sem contrato_id, devolve a regra padrão global.';

create or replace function public.pricing_indices_list(p_indice text default null, p_limit integer default 12)
returns setof public.indices_economicos
language sql
stable
security invoker
as $$
  select * from public.indices_economicos
  where p_indice is null or indice = p_indice
  order by competencia desc
  limit least(coalesce(p_limit, 12), 60);
$$;
comment on function public.pricing_indices_list(text, integer) is 'Seção 28 — índices econômicos (IPCA/IGP-M) já coletados, para a estrutura de reajuste do simulador. Sem fetch automático do IBGE ainda (arquitetura preparada, seção 28 não exige mais que isso agora).';

grant execute on function
  public.pricing_ramp_rules_list(uuid),
  public.pricing_indices_list(text, integer)
to authenticated;
