-- OptiMon — Fase 2.2: Infrastructure Floor + Régua Comercial
-- Migration 1/4: schema aditivo (nenhuma tabela/coluna/migration anterior é alterada em
-- seu comportamento já existente — só colunas novas com DEFAULT que preservam o
-- comportamento atual para toda linha já existente).
--
-- Conceito novo (seção 2/12): "Infrastructure Floor" / "Piso de Infraestrutura" é uma
-- POLÍTICA COMERCIAL de monetização mínima da infraestrutura óptica (postes + metros de
-- rede), NUNCA o custo real (isso já existe, separado, em custos_infraestrutura desde a
-- Fase 2: HISTORICAL_CAPEX/EXISTING_OPEX/INCREMENTAL_OPEX/INCREMENTAL_CAPEX/
-- ALLOCATED_COST/REVENUE_EXISTING — nenhum desses tipos é tocado aqui).

-- 1) pricing_parametros ganha escopo opcional por CIDADE (seção 14: "GLOBAL com
--    possibilidade de override por CIDADE"). Todas as ~30 chaves já existentes continuam
--    com cidade_id NULL (global) — comportamento 100% preservado; a troca da constraint
--    unique única (chave) por 2 índices únicos parciais é reversível e não apaga nem
--    reordena nenhuma linha existente.
alter table public.pricing_parametros add column if not exists cidade_id uuid references public.cidades_infra(id) on delete cascade;

alter table public.pricing_parametros drop constraint if exists pricing_parametros_chave_key;

create unique index if not exists pricing_parametros_chave_global_uidx
  on public.pricing_parametros (chave) where cidade_id is null;

create unique index if not exists pricing_parametros_chave_cidade_uidx
  on public.pricing_parametros (chave, cidade_id) where cidade_id is not null;

create index if not exists pricing_parametros_cidade_idx on public.pricing_parametros (cidade_id);

comment on column public.pricing_parametros.cidade_id is 'Fase 2.2 (seção 14): NULL = parâmetro GLOBAL (comportamento de todas as fases anteriores, preservado). Preenchido = override específico para essa cidade, com precedência sobre o valor global ao resolver o mesmo "chave" (ver app.get_infra_floor_param). Suporte a override por POP fica para uma fase futura (seção 14 do prompt).';

-- 2) infra_pops ganha 2 colunas analíticas opcionais (seção 24/27): quebra por POP do
--    "piso de infraestrutura", SEM nunca ser a fonte da consolidação da cidade (que
--    continua sempre lida de cidades_infra.km_rede / SUM(infra_postes.quantidade) —
--    nunca recomputada somando POPs, para nunca duplicar metros — seção 24).
alter table public.infra_pops add column if not exists km_rede numeric(10,3) not null default 0 check (km_rede >= 0);
alter table public.infra_pops add column if not exists postes_count integer not null default 0 check (postes_count >= 0);

comment on column public.infra_pops.km_rede is 'Fase 2.2 (seção 24/27): extensão de rede (km) atribuível a ESTE POP — referência econômica analítica para a quebra "por POP" do Infrastructure Floor. Opcional/informativa: o consolidado da cidade nunca é a soma desta coluna entre os POPs, é sempre lido direto de cidades_infra.km_rede (nunca duplicar, seção 24).';
comment on column public.infra_pops.postes_count is 'Fase 2.2 (seção 24/27): quantidade de postes atribuível a ESTE POP — mesma lógica analítica/opcional de km_rede. O consolidado da cidade continua sempre SUM(infra_postes.quantidade) por cidade_id.';

-- 3) Composição Floor × Mínimo Contratual (seção 32/33) — nunca somar os dois
--    silenciosamente. Modalidade explícita por contrato, default FLOOR_AS_MINIMUM
--    (seção 32: "Default recomendado: FLOOR_AS_MINIMUM").
do $$ begin
  create type public.infra_floor_composition_mode as enum ('FLOOR_ONLY', 'MINIMUM_ONLY', 'FLOOR_AS_MINIMUM', 'SUM', 'MAX');
exception when duplicate_object then null;
end $$;

alter table public.contrato_pricing_config
  add column if not exists infra_floor_composition_mode public.infra_floor_composition_mode not null default 'FLOOR_AS_MINIMUM';

alter table public.contrato_pricing_config
  add column if not exists minimum_infrastructure_floor_enforced boolean not null default true;

comment on column public.contrato_pricing_config.infra_floor_composition_mode is 'Fase 2.2 (seção 32/33): como compor Infrastructure Floor (F) × Minimum Contractual Fee (M) ao calcular o total a pagar — FLOOR_ONLY (só F, M vira informativo), MINIMUM_ONLY (só M, comportamento 100% igual ao pré-Fase-2.2), FLOOR_AS_MINIMUM (default — F assume o papel de M no motor SOMA/MAX com Revenue Share já existente, ex.: MAX(F, Revenue Share)), SUM (F+M somados como base), MAX (maior entre F e M como base). Nunca soma F+M "por acidente" (seção 32).';
comment on column public.contrato_pricing_config.minimum_infrastructure_floor_enforced is 'Fase 2.2 (seção 18): quando TRUE (default), nenhum total a pagar calculado por app.get_economia_com_piso pode ficar abaixo do Infrastructure Floor, seja qual for infra_floor_composition_mode — rede de proteção final, aplicada depois da composição escolhida.';

-- 4) Parâmetros globais do Infrastructure Floor (seção 3/13) — valores literais do
--    prompt, nunca hard-coded no código: R$10,00/poste/mês; R$0,10 / R$0,15 / R$0,20 por
--    metro/mês (piso/recomendado/abertura). "Pricing version" (seção 15) é o mês de
--    vigência (to_char(vigente_desde,'YYYY.MM'), ex.: "2026.08") — reaproveita o mesmo
--    mecanismo de versionamento temporal (vigente_desde/vigente_ate) que TODOS os outros
--    parâmetros de pricing já usam desde a Fase 1, em vez de criar uma tabela paralela de
--    "versão" só para este conceito nesta correção incremental.
insert into public.pricing_parametros (chave, valor, unidade, descricao) values
  ('PISO_INFRAESTRUTURA_PRECO_POSTE', 10.00, 'BRL/poste/mês', 'Infrastructure Floor (seção 3/13): preço comercial por poste/mês. Política de monetização mínima da infraestrutura — NUNCA o custo real (esse fica em custos_infraestrutura). GLOBAL, com override possível por cidade.'),
  ('PISO_INFRAESTRUTURA_PRECO_METRO_PISO', 0.10, 'BRL/metro/mês', 'Infrastructure Floor (seção 3/6/13): régua comercial — nível PISO/RESERVA, menor valor comercial padrão permitido por metro de rede/mês.'),
  ('PISO_INFRAESTRUTURA_PRECO_METRO_RECOMENDADO', 0.15, 'BRL/metro/mês', 'Infrastructure Floor (seção 3/7/13): régua comercial — nível RECOMENDADO por metro de rede/mês.'),
  ('PISO_INFRAESTRUTURA_PRECO_METRO_ABERTURA', 0.20, 'BRL/metro/mês', 'Infrastructure Floor (seção 3/8/13): régua comercial — nível ABERTURA (valor sugerido inicialmente pelo sistema ao Comercial) por metro de rede/mês.')
on conflict (chave) where cidade_id is null do nothing;
