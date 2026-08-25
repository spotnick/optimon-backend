-- OptiMon — Fase 2.2: Infrastructure Floor + Régua Comercial
-- Migration 4/4: quebra Multi-POP do piso (seção 24), fechamento de lacuna de auditoria
-- (cidades_infra — km_rede agora vira insumo de precificação), extensão auditável do
-- override existente da Fase 2 (seção 40) e wrappers públicos para API/dashboard.

-- app.get_capacidade_multi_pop_piso (seção 24): quebra por POP + consolidado da cidade,
-- mesmo padrão de app.get_capacidade_multi_pop_contrato (Fase 2.1) — mas para o
-- Infrastructure Floor, não capacidade de portas PON. O consolidado NUNCA é a soma dos
-- POPs (evita duplicar metros), é sempre lido direto de cidades_infra.km_rede.
create or replace function app.get_capacidade_multi_pop_piso(p_cidade_id uuid)
returns jsonb
language sql
stable
as $$
  with por_pop as (
    select id as pop_id, codigo as pop_codigo, nome as pop_nome, km_rede, postes_count
    from public.infra_pops
    where cidade_id = p_cidade_id and removido_em is null
  )
  select jsonb_build_object(
    'cidade_id', p_cidade_id,
    'pops', coalesce((select jsonb_agg(jsonb_build_object(
      'pop_id', pop_id, 'pop_codigo', pop_codigo, 'pop_nome', pop_nome,
      'km_rede', km_rede, 'metros', km_rede * 1000, 'postes_count', postes_count
    ) order by pop_codigo) from por_pop), '[]'::jsonb),
    'consolidado_cidade', jsonb_build_object(
      -- Nunca soma dos POPs acima — sempre a fonte única (cidades_infra/infra_postes),
      -- exatamente para nunca duplicar os metros da rede (seção 24).
      'km_rede', (select km_rede from public.cidades_infra where id = p_cidade_id),
      'metros', (select km_rede * 1000 from public.cidades_infra where id = p_cidade_id),
      'postes_count', (select coalesce(sum(quantidade), 0) from public.infra_postes where cidade_id = p_cidade_id and removido_em is null)
    )
  );
$$;
comment on function app.get_capacidade_multi_pop_piso(uuid) is 'Fase 2.2 (seção 24): quebra do Infrastructure Floor por POP + consolidado da cidade. O consolidado é SEMPRE lido da fonte única (cidades_infra.km_rede / SUM(infra_postes)) — nunca recomputado somando a coluna analítica por POP, para nunca duplicar os metros da rede.';

-- Fechamento de lacuna de auditoria (mesma disciplina da Fase 2.1, seção 14 daquele
-- prompt): cidades_infra nunca teve trigger de auditoria; agora que km_rede alimenta
-- diretamente o Infrastructure Floor (preço comercial), uma alteração nesse campo precisa
-- ficar rastreada como qualquer outro parâmetro de pricing.
do $$ begin
  if not exists (
    select 1 from pg_trigger where tgname = 'trg_aud_cidades_infra' and tgrelid = 'public.cidades_infra'::regclass
  ) then
    create trigger trg_aud_cidades_infra
      after insert or update or delete on public.cidades_infra
      for each row execute function public.fn_auditoria();
  end if;
end $$;
comment on trigger trg_aud_cidades_infra on public.cidades_infra is 'Fase 2.2: lacuna real — cidades_infra nunca teve trigger de auditoria. km_rede agora é insumo direto do Infrastructure Floor (preço comercial), então uma alteração nele precisa ficar auditada como qualquer outro parâmetro de pricing.';

-- Extensão auditável do override já existente da Fase 2 (seção 40): registrar também
-- preço-piso e preço-abertura no MESMO fluxo já testado (nasce PENDENTE → só Diretor
-- aprova → auditado), em vez de criar uma tabela de override paralela. Colunas novas,
-- nullable, adicionadas por CREATE OR REPLACE com parâmetros NOVOS opcionais no final —
-- nenhuma chamada existente (ex.: REG19 da Fase 2/2.1) precisa mudar.
alter table public.pricing_override_requests add column if not exists preco_piso numeric(12,2) check (preco_piso is null or preco_piso >= 0);
alter table public.pricing_override_requests add column if not exists preco_abertura numeric(12,2) check (preco_abertura is null or preco_abertura >= 0);
comment on column public.pricing_override_requests.preco_piso is 'Fase 2.2 (seção 40): Infrastructure Floor no momento da solicitação, quando o override é sobre uma negociação abaixo do piso — NULL para overrides que não envolvem o Infrastructure Floor (ex.: os já existentes desde a Fase 2).';
comment on column public.pricing_override_requests.preco_abertura is 'Fase 2.2 (seção 40): preço de abertura da régua no momento da solicitação, quando aplicável.';

-- IMPORTANTE: create or replace só substitui uma função com a MESMA assinatura. Acrescentar
-- 2 parâmetros novos (mesmo com DEFAULT) muda a assinatura e faz o Postgres criar uma
-- SEGUNDA função sobrecarregada, deixando qualquer chamada com exatamente 5 argumentos
-- posicionais AMBÍGUA entre as duas (erro "function ... is not unique") — quebrando na
-- prática as chamadas antigas que a Fase 2.2 prometeu preservar (seção 40). O DROP abaixo
-- remove a função de 5 parâmetros antes de recriar com 7, garantindo uma única função
-- (agora aceitando 5, 6 ou 7 argumentos via DEFAULT) — sem ambiguidade.
drop function if exists public.pricing_override_create(uuid, uuid, numeric, numeric, text);

create or replace function public.pricing_override_create(
  p_contrato_id uuid,
  p_simulacao_id uuid,
  p_preco_recomendado numeric,
  p_preco_solicitado numeric,
  p_justificativa text,
  p_preco_piso numeric default null,
  p_preco_abertura numeric default null
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_id uuid;
begin
  insert into public.pricing_override_requests (contrato_id, simulacao_id, preco_recomendado, preco_solicitado, justificativa, preco_piso, preco_abertura)
  values (p_contrato_id, p_simulacao_id, p_preco_recomendado, p_preco_solicitado, p_justificativa, p_preco_piso, p_preco_abertura)
  returning id into v_id;
  return v_id;
end;
$$;
comment on function public.pricing_override_create(uuid, uuid, numeric, numeric, text, numeric, numeric) is 'Fase 2 (seção 48) + Fase 2.2 (seção 40): CREATE OR REPLACE só para aceitar 2 parâmetros NOVOS opcionais (preco_piso/preco_abertura) no final — todas as chamadas existentes desde a Fase 2 continuam funcionando sem alteração. Mesmo fluxo de sempre: nasce PENDENTE, só DIRETOR/ADMINISTRADOR decide (trigger fn_override_decisao, inalterada), auditado (trigger de auditoria, inalterada).';

-- Wrappers públicos (mesmo padrão SECURITY INVOKER das Fases 2/2.1 — a API nunca decide
-- preço, só encaminha).
create or replace function public.pricing_infrastructure_floor(p_cidade_id uuid, p_pop_id uuid default null, p_pricing_version text default null)
returns jsonb
language sql
stable
security invoker
as $$
  select app.calculate_infrastructure_floor(p_cidade_id, p_pop_id, p_pricing_version);
$$;
comment on function public.pricing_infrastructure_floor(uuid, uuid, text) is 'Fase 2.2 (seção 21) — wrapper público de app.calculate_infrastructure_floor.';
grant execute on function public.pricing_infrastructure_floor(uuid, uuid, text) to authenticated;

create or replace function public.pricing_infra_floor_negotiation(p_preco_proposto numeric, p_cidade_id uuid, p_pop_id uuid default null, p_pricing_version text default null)
returns jsonb
language plpgsql
stable
security invoker
as $$
declare
  v_floor jsonb;
  v_abertura numeric;
  v_recomendado numeric;
  v_piso numeric;
  v_desconto jsonb;
begin
  v_floor := app.calculate_infrastructure_floor(p_cidade_id, p_pop_id, p_pricing_version);
  v_abertura := (v_floor ->> 'opening_price')::numeric;
  v_recomendado := (v_floor ->> 'recommended_price')::numeric;
  v_piso := (v_floor ->> 'floor_price')::numeric;
  v_desconto := app.calcular_desconto_comercial(v_abertura, p_preco_proposto, v_recomendado);

  return v_floor || jsonb_build_object(
    'preco_proposto', p_preco_proposto,
    'posicao_regua', app.classificar_posicao_regua(p_preco_proposto, v_abertura, v_recomendado, v_piso),
    'governanca', app.check_infrastructure_floor_governance(p_preco_proposto, v_recomendado, v_piso),
    'desconto', v_desconto,
    'diferenca_sobre_piso', round(p_preco_proposto - v_piso, 2)
  );
end;
$$;
comment on function public.pricing_infra_floor_negotiation(numeric, uuid, uuid, text) is 'Fase 2.2 (seções 9/10/11/20/37-39) — "função comercial" completa: régua (abertura/recomendado/piso), posição do preço proposto, veredito de governança, desconto absoluto/percentual (sobre abertura e sobre recomendado) e diferença sobre o piso — tudo em uma chamada, para o dashboard/API não recompor isso em partes.';
grant execute on function public.pricing_infra_floor_negotiation(numeric, uuid, uuid, text) to authenticated;

create or replace function public.pricing_economics_with_floor(p_contrato_id uuid, p_faturamento_parceiro numeric, p_pop_id uuid default null, p_pricing_version text default null)
returns jsonb
language sql
stable
security invoker
as $$
  select app.get_economia_com_piso(p_contrato_id, p_faturamento_parceiro, p_pop_id, p_pricing_version);
$$;
comment on function public.pricing_economics_with_floor(uuid, numeric, uuid, text) is 'Fase 2.2 (seção 17/30) — wrapper público de app.get_economia_com_piso.';
grant execute on function public.pricing_economics_with_floor(uuid, numeric, uuid, text) to authenticated;

create or replace function public.pricing_fibras_indicadores(p_cidade_id uuid, p_pop_id uuid default null)
returns jsonb
language sql
stable
security invoker
as $$
  select app.get_fibras_indicadores_cidade(p_cidade_id, p_pop_id);
$$;
comment on function public.pricing_fibras_indicadores(uuid, uuid) is 'Fase 2.2 (seção 25-27) — wrapper público de app.get_fibras_indicadores_cidade.';
grant execute on function public.pricing_fibras_indicadores(uuid, uuid) to authenticated;

create or replace function public.pricing_capacity_multipop_piso(p_cidade_id uuid)
returns jsonb
language sql
stable
security invoker
as $$
  select app.get_capacidade_multi_pop_piso(p_cidade_id);
$$;
comment on function public.pricing_capacity_multipop_piso(uuid) is 'Fase 2.2 (seção 24) — wrapper público de app.get_capacidade_multi_pop_piso.';
grant execute on function public.pricing_capacity_multipop_piso(uuid) to authenticated;
