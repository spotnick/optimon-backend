-- OptiMon — Fase 2.2.1 (Parte 2) — seção 31: GET /api/pricing/:id.
-- Busca uma simulação/cálculo específico já salvo, por id — complementa
-- pricing_scenarios_list (que só filtra por contrato_id, nunca por id direto).

create or replace function public.pricing_simulation_get(p_id uuid)
returns public.simulacoes
language sql
stable
security invoker
as $$
  select * from public.simulacoes where id = p_id;
$$;
comment on function public.pricing_simulation_get(uuid) is 'GET /api/pricing/:id — busca um cálculo/simulação salvo por id (seção 31). RLS de simulacoes_select continua valendo (dono ou DIRETOR/ADMINISTRADOR/AUDITOR).';

grant execute on function public.pricing_simulation_get(uuid) to authenticated;
