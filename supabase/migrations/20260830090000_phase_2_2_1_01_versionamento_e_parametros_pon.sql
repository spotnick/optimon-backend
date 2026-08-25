-- OptiMon — Fase 2.2.1: Ajuste Final de Governança + Precificação por Porta PON
-- Migration 1/4: versionamento REAL de pricing_parametros (histórico preservado, não só
-- rotulado) + novos parâmetros oficiais (poste R$8,00, PON piso/recomendado/abertura,
-- limite máximo de desconto de override).
--
-- LACUNA FECHADA (descoberta nesta fase): desde a Fase 2.2, "pricing_version" era só um
-- RÓTULO derivado de vigente_desde (to_char(...,'YYYY.MM')) — o índice único de
-- pricing_parametros permitia no máximo UMA linha por (chave, cidade_id), então não havia
-- como duas versões coexistirem: mudar um parâmetro sempre teria que fazer UPDATE na mesma
-- linha, apagando o valor anterior de fato (só o comentário dizia "nunca recalcular
-- histórico" — o esquema não impedia isso na prática). A seção 29 desta fase exige
-- explicitamente "não alterar propostas históricas quando os parâmetros mudarem" com um
-- exemplo de rótulo "2026.08.1" — impossível de cumprir de verdade sem guardar as duas
-- linhas (antiga fechada + nova vigente). Esta migration corrige isso: pricing_version
-- passa a ser uma coluna real, e múltiplas linhas históricas por (chave, cidade_id) passam
-- a ser permitidas — a unicidade agora é (a) uma linha "vigente" (vigente_ate IS NULL) por
-- chave/cidade e (b) um rótulo de versão único por chave/cidade.

-- 1) Coluna pricing_version real (antes só existia como um to_char() calculado on-the-fly).
alter table public.pricing_parametros add column if not exists pricing_version text;

-- Backfill: toda linha existente (todas as ~30 chaves globais + os 4 parâmetros do
-- Infrastructure Floor da Fase 2.2) ganha o rótulo equivalente ao que já era exibido antes
-- desta fase — nenhum valor muda, só passa a ter um rótulo persistido em vez de calculado.
update public.pricing_parametros set pricing_version = to_char(vigente_desde, 'YYYY.MM') where pricing_version is null;

alter table public.pricing_parametros alter column pricing_version set not null;

-- 2) Troca dos índices únicos: antes "no máximo 1 linha por (chave,cidade_id), sempre" —
--    agora "no máximo 1 linha VIGENTE (vigente_ate is null) por (chave,cidade_id)" e "no
--    máximo 1 linha por (chave,cidade_id,pricing_version)" — as duas juntas permitem
--    histórico real (várias linhas fechadas) sem nunca ter 2 vigências abertas ao mesmo
--    tempo nem 2 linhas com o mesmo rótulo de versão.
drop index if exists public.pricing_parametros_chave_global_uidx;
drop index if exists public.pricing_parametros_chave_cidade_uidx;

create unique index if not exists pricing_parametros_vigente_global_uidx
  on public.pricing_parametros (chave) where cidade_id is null and vigente_ate is null;

create unique index if not exists pricing_parametros_vigente_cidade_uidx
  on public.pricing_parametros (chave, cidade_id) where cidade_id is not null and vigente_ate is null;

create unique index if not exists pricing_parametros_versao_global_uidx
  on public.pricing_parametros (chave, pricing_version) where cidade_id is null;

create unique index if not exists pricing_parametros_versao_cidade_uidx
  on public.pricing_parametros (chave, cidade_id, pricing_version) where cidade_id is not null;

comment on column public.pricing_parametros.pricing_version is 'Fase 2.2.1 (seção 29): rótulo de versão real e persistido (ex.: "2026.08", "2026.08.1") — permite múltiplas linhas históricas por (chave,cidade_id), cada uma com vigente_ate preenchido quando superada. Junto com vigente_desde/vigente_ate, garante que uma proposta antiga (que gravou o rótulo de versão usado no momento) nunca é recalculada com um parâmetro que já mudou.';

-- 3) app.criar_pricing_version(): bump atômico de um conjunto de parâmetros para uma nova
--    versão — fecha a linha vigente anterior de cada chave tocada (vigente_ate = véspera da
--    nova vigência) e insere a nova linha vigente com o rótulo novo. É a forma canônica de
--    mudar um parâmetro de pricing daqui para frente (em vez de UPDATE direto, que apagaria
--    o histórico); chaves que ainda não existiam (ex.: os parâmetros de PON, novos nesta
--    fase) simplesmente nascem na nova versão, sem linha anterior para fechar.
create or replace function app.criar_pricing_version(
  p_pricing_version text,
  p_valores jsonb,
  p_cidade_id uuid default null,
  p_vigente_desde date default current_date,
  p_descricao text default null
)
returns integer
language plpgsql
as $$
declare
  v_chave text;
  v_valor numeric;
  v_count integer := 0;
begin
  if p_pricing_version is null or btrim(p_pricing_version) = '' then
    raise exception 'p_pricing_version é obrigatório.';
  end if;

  for v_chave, v_valor in select key, value::numeric from jsonb_each_text(p_valores)
  loop
    update public.pricing_parametros
       set vigente_ate = p_vigente_desde - 1
     where chave = v_chave
       and (cidade_id = p_cidade_id or (cidade_id is null and p_cidade_id is null))
       and vigente_ate is null;

    insert into public.pricing_parametros (chave, valor, cidade_id, pricing_version, vigente_desde, descricao)
    values (v_chave, v_valor, p_cidade_id, p_pricing_version, p_vigente_desde, p_descricao);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
comment on function app.criar_pricing_version(text, jsonb, uuid, date, text) is 'Fase 2.2.1 (seção 29): cria uma nova Pricing Version de forma atômica — para cada chave em p_valores, fecha a linha vigente anterior (vigente_ate) e insere a nova linha vigente com o rótulo p_pricing_version. Propostas antigas que gravaram o rótulo anterior continuam resolvendo para os valores antigos via app.get_infra_floor_param(..., p_pricing_version).';

-- 4) app.get_infra_floor_param() — CREATE OR REPLACE com a MESMA assinatura (nenhuma
--    ambiguidade de overload): passa a resolver por pricing_version (rótulo exato) quando
--    informado, em vez de casar por mês (to_char); sem p_pricing_version, resolve a linha
--    VIGENTE (vigente_ate is null) — comportamento equivalente ao anterior, agora apoiado
--    em histórico real em vez de só uma linha por chave.
create or replace function app.get_infra_floor_param(p_chave text, p_cidade_id uuid, p_pricing_version text default null)
returns numeric
language plpgsql
stable
as $$
declare
  v_valor numeric;
begin
  if p_pricing_version is not null then
    select valor into v_valor
    from public.pricing_parametros
    where chave = p_chave and (cidade_id = p_cidade_id or cidade_id is null)
      and pricing_version = p_pricing_version
    order by cidade_id nulls last
    limit 1;

    if not found then
      raise exception 'Pricing version "%": não existe uma vigência de "%" para essa versão (nem específica da cidade, nem global).', p_pricing_version, p_chave;
    end if;
  else
    select valor into v_valor
    from public.pricing_parametros
    where chave = p_chave and (cidade_id = p_cidade_id or cidade_id is null)
      and vigente_ate is null
    order by cidade_id nulls last
    limit 1;

    if not found then
      raise exception 'Parâmetro "%" não está configurado (nem para a cidade, nem globalmente).', p_chave;
    end if;
  end if;

  return v_valor;
end;
$$;
comment on function app.get_infra_floor_param(text, uuid, text) is 'Fase 2.2 (seção 14/15) + Fase 2.2.1 (seção 29): resolve um parâmetro do Infrastructure Floor priorizando override por cidade sobre o global. Com p_pricing_version, casa pelo RÓTULO exato de versão (não mais por mês) — permite múltiplas versões no mesmo mês (ex.: "2026.08" e "2026.08.1"). Sem p_pricing_version, resolve a linha vigente atual (vigente_ate is null).';

-- 5) Nova Pricing Version "2026.08.1" (seção 4/29): poste sobe de R$10,00 para R$8,00;
--    metros piso/recomendado/abertura permanecem nos mesmos valores (R$0,10/0,15/0,20) mas
--    são fechados e reabertos junto, para que TODO o conjunto de parâmetros do Infrastructure
--    Floor fique sob um único rótulo de versão coerente (o exemplo da seção 29 lista os 8
--    parâmetros juntos sob "2026.08.1" — versionar em bloco evita ficar rastreando qual
--    parâmetro mudou em qual submês); PON piso/recomendado/abertura e o limite máximo de
--    desconto de override nascem nesta versão (chaves novas, sem linha anterior a fechar).
select app.criar_pricing_version(
  '2026.08.1',
  jsonb_build_object(
    'PISO_INFRAESTRUTURA_PRECO_POSTE', 8.00,
    'PISO_INFRAESTRUTURA_PRECO_METRO_PISO', 0.10,
    'PISO_INFRAESTRUTURA_PRECO_METRO_RECOMENDADO', 0.15,
    'PISO_INFRAESTRUTURA_PRECO_METRO_ABERTURA', 0.20,
    'PISO_INFRAESTRUTURA_PRECO_PON_PISO', 200.00,
    'PISO_INFRAESTRUTURA_PRECO_PON_RECOMENDADO', 250.00,
    'PISO_INFRAESTRUTURA_PRECO_PON_ABERTURA', 300.00,
    'MAX_OVERRIDE_DISCOUNT_PERCENT', 0.50
  ),
  null,
  current_date,
  'Fase 2.2.1 (seções 4/29): poste R$10,00->R$8,00; PON piso/recomendado/abertura novos; limite máximo de desconto de override (50% sobre o preço de abertura).'
);
