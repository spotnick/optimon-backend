-- OptiMon — OptiMap Fase 2 (fundação geográfica) — Migration 2/4: schema.
--
-- 100% aditiva: só tabelas NOVAS (prefixo gis_). Nenhuma tabela oficial existente
-- (cidades_infra, infra_*, contrato_fibras) ganha coluna, constraint ou trigger.
--
-- Princípio central (relatório Fase 1, seções 4 e 8): dado externo NUNCA é rede da NICK.
--   * gis_postes_referencia — postes de fontes externas (ex.: mapa público Copel). Só
--     referência; nunca vira infraestrutura própria sozinho.
--   * gis_postes / gis_elementos / gis_trechos — rede documentada pela NICK, com estado
--     PLANEJADO / DOCUMENTADO / VALIDADO / DESATIVADO.
--   * Promover um poste externo a poste usado pela NICK é sempre um ato explícito
--     (app.gis_promover_poste_referencia, Migration 3), que cria um gis_postes apontando
--     para a referência — a referência nunca é alterada por isso.
--
-- infra_postes continua sendo LOTE faturável (quantidade/custo_mensal, base do
-- Infrastructure Floor). gis_postes.infra_poste_lote_id só liga o poste individual ao lote
-- para conciliação por relatório — nunca altera quantidade nem custo.
--
-- Geometrias: SRID 4326 (WGS84, o mesmo do mapa da Copel). Comprimentos sempre em metros
-- via geography.

-- Tipos/funções do PostGIS são resolvidos pelo search_path padrão do Supabase
-- ("$user", public, extensions) — nenhuma alteração de search_path é feita aqui.

-- ============================================================================
-- Validação de coordenada (usada em CHECK constraints)
-- ============================================================================
-- Imutável e determinística: geometria válida, não vazia, SRID 4326 e dentro de um
-- envelope generoso do território brasileiro (lon −74,1..−28,6; lat −33,9..5,4). Rejeita
-- (0,0), lat/long trocadas (ex.: lat −52 cai fora) e lixo de digitação. Não verifica
-- município — isso é responsabilidade da importação (Fase 4), que conhece o escopo.
create or replace function app.gis_coordenada_valida(p_geom geometry)
returns boolean
language sql
immutable
parallel safe
set search_path = public, extensions, pg_temp
as $$
  select p_geom is not null
     and not ST_IsEmpty(p_geom)
     and ST_SRID(p_geom) = 4326
     and ST_IsValid(p_geom)
     and ST_XMin(p_geom) >= -74.1 and ST_XMax(p_geom) <= -28.6
     and ST_YMin(p_geom) >= -33.9 and ST_YMax(p_geom) <= 5.4;
$$;
comment on function app.gis_coordenada_valida(geometry) is 'OptiMap: geometria válida, SRID 4326 e dentro do envelope do Brasil. Usada em CHECK de todas as tabelas gis_*.';

-- ============================================================================
-- gis_fontes — catálogo de fontes de dados geográficos
-- ============================================================================
create table public.gis_fontes (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique check (codigo ~ '^[A-Z0-9_]+$'),
  nome text not null,
  tipo text not null check (tipo in ('EXTERNA', 'PROPRIA')),
  descricao text,
  url_origem text,
  termos_uso text,
  termos_verificados_em date,
  atribuicao text,
  permite_redistribuicao boolean not null default false,
  observacoes text,
  ativa boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create trigger trg_gis_fontes_atualizado_em before update on public.gis_fontes
  for each row execute function public.set_atualizado_em();

comment on table public.gis_fontes is 'OptiMap: origem de cada dado geográfico. EXTERNA = referência de terceiros (nunca rede da NICK); PROPRIA = levantamento/cadastro/projeto da NICK. Toda linha gis_* aponta para uma fonte.';
comment on column public.gis_fontes.termos_uso is 'Texto (ou resumo fiel) dos termos/condições da fonte, com a data de verificação em termos_verificados_em. Dado externo nunca é exibido fora do OptiMon interno.';

insert into public.gis_fontes (codigo, nome, tipo, descricao, url_origem, termos_uso, termos_verificados_em, atribuicao, permite_redistribuicao, observacoes) values
  ('COPEL_MAPA_PUBLICO', 'Copel — Mapa de Compartilhamento de Estruturas (público)', 'EXTERNA',
   'Camada pública "Posição postes compartilhados" (Hosted/MapaPublicoCompartilhamento/FeatureServer/0): número do poste (num_seq_geo), coordenadas WGS84, situação (disponibilidade) e indic_ps_particular.',
   'https://www.copel.com/portaldis/apps/webappviewer/index.html?id=c1fda25f7e5d459b9f05556cdac52bc0',
   'Aviso do aplicativo: os dados refletem o cadastro da Copel Distribuição e podem divergir do campo; para projetos, as empresas de telecomunicações devem confirmar as informações in loco, independentemente do status (disponibilidade); a Copel não se responsabiliza por inconsistências. Item sem licença declarada; robots.txt da Copel veda acesso automatizado a /arcgis/ — coleta automatizada decidida e assumida pela NICK (relatório OptiMap Fase 1, Adendo 2).',
   date '2026-10-21', 'Fonte: Copel Distribuição S.A.', false,
   'Somente uso interno. Coleta por município, com salvaguardas (Adendo 2).'),
  ('NICK_LEVANTAMENTO_CAMPO', 'NICK — Levantamento de campo', 'PROPRIA', 'Posição/atributos coletados em campo pela Engenharia da NICK.', null, null, null, null, false, null),
  ('NICK_PROJETO', 'NICK — Projeto', 'PROPRIA', 'Elementos previstos em projeto (inclusive projetos de ocupação enviados à concessionária).', null, null, null, null, false, null),
  ('NICK_CADASTRO_MANUAL', 'NICK — Cadastro manual no OptiMap', 'PROPRIA', 'Elemento posicionado manualmente no mapa por usuário autorizado.', null, null, null, null, false, null);

-- ============================================================================
-- gis_postes_referencia — postes de fontes externas (NUNCA rede da NICK)
-- ============================================================================
create table public.gis_postes_referencia (
  id uuid primary key default gen_random_uuid(),
  fonte_id uuid not null references public.gis_fontes(id) on delete restrict,
  -- Identificador estável na fonte (Copel: num_seq_geo). Nunca o objectid do serviço.
  id_externo text not null check (length(btrim(id_externo)) > 0),
  geom geometry(Point, 4326) not null check (app.gis_coordenada_valida(geom)),
  cidade_id uuid references public.cidades_infra(id) on delete restrict,
  codigo_ibge char(7),
  situacao_fonte text,
  -- Todos os atributos exatamente como vieram da fonte (nada inventado, nada traduzido).
  atributos_fonte jsonb not null default '{}'::jsonb check (jsonb_typeof(atributos_fonte) = 'object'),
  -- Data de referência do dado (momento da coleta/consulta na fonte).
  data_referencia timestamptz not null,
  primeira_coleta_em timestamptz not null default now(),
  ultima_coleta_em timestamptz not null default now(),
  estado_sincronizacao text not null default 'CONFIRMADO' check (estado_sincronizacao in (
    'CONFIRMADO',                     -- visto na última coleta, sem alteração relevante
    'ATUALIZADO',                     -- visto na última coleta, com atributo/posição alterados
    'DESATUALIZADO',                  -- data_referencia antiga (sem coleta recente)
    'DIVERGENTE',                     -- conflito com levantamento da NICK, aguardando análise
    'NAO_LOCALIZADO_ULTIMA_COLETA',   -- ausente na última coleta do mesmo escopo (nunca apagado)
    'EXCLUIDO_PELA_FONTE'             -- exclusão confirmada com evidência (decisão humana)
  )),
  -- FK para o lote de importação entra na Fase 4 (staging GIS), aditivamente.
  ultima_importacao_id uuid,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  -- Idempotência: reprocessar a mesma fonte nunca duplica o poste. Tabela nova (não é
  -- tabela oficial de infraestrutura), por isso a UNIQUE é legítima aqui.
  constraint gis_postes_referencia_fonte_id_externo_key unique (fonte_id, id_externo),
  check (ultima_coleta_em >= primeira_coleta_em)
);
create index gis_postes_referencia_geom_gix on public.gis_postes_referencia using gist (geom);
create index gis_postes_referencia_cidade_idx on public.gis_postes_referencia (cidade_id);
create index gis_postes_referencia_ibge_idx on public.gis_postes_referencia (codigo_ibge);
create index gis_postes_referencia_estado_idx on public.gis_postes_referencia (estado_sincronizacao);
create index gis_postes_referencia_id_externo_prefix_idx on public.gis_postes_referencia (id_externo text_pattern_ops);
create trigger trg_gis_postes_referencia_atualizado_em before update on public.gis_postes_referencia
  for each row execute function public.set_atualizado_em();

comment on table public.gis_postes_referencia is 'OptiMap: postes de fontes EXTERNAS (ex.: Copel). Referência apenas — a existência de um poste aqui não significa que a NICK o utilize, nem que haja cabo/caixa da NICK no local. Nunca apagado: ausência numa coleta vira NAO_LOCALIZADO_ULTIMA_COLETA.';
comment on column public.gis_postes_referencia.id_externo is 'Identificador estável do poste na fonte (Copel: num_seq_geo, o "número do poste" exibido no aplicativo). Chave de idempotência junto com fonte_id.';
comment on column public.gis_postes_referencia.situacao_fonte is 'Status de disponibilidade informado pela fonte, sem tradução (Copel: campo situacao).';

-- ============================================================================
-- gis_postes — postes individuais usados/projetados pela NICK
-- ============================================================================
create table public.gis_postes (
  id uuid primary key default gen_random_uuid(),
  codigo text,
  geom geometry(Point, 4326) not null check (app.gis_coordenada_valida(geom)),
  cidade_id uuid not null references public.cidades_infra(id) on delete restrict,
  poste_referencia_id uuid references public.gis_postes_referencia(id) on delete restrict,
  -- Lote faturável (infra_postes) em que este poste é cobrado — só para conciliação.
  infra_poste_lote_id uuid references public.infra_postes(id) on delete restrict,
  proprietario text,
  estado text not null default 'DOCUMENTADO' check (estado in ('PLANEJADO', 'DOCUMENTADO', 'VALIDADO', 'DESATIVADO')),
  fonte_id uuid not null references public.gis_fontes(id) on delete restrict,
  validado_por uuid references public.usuarios(id),
  validado_em timestamptz,
  observacoes text,
  criado_por uuid references public.usuarios(id) default auth.uid(),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz,
  check ((validado_em is null) = (validado_por is null)),
  check (estado <> 'VALIDADO' or validado_em is not null)
);
create index gis_postes_geom_gix on public.gis_postes using gist (geom);
create index gis_postes_cidade_idx on public.gis_postes (cidade_id);
create index gis_postes_estado_idx on public.gis_postes (estado) where removido_em is null;
create index gis_postes_lote_idx on public.gis_postes (infra_poste_lote_id);
-- Um poste de referência corresponde a no máximo um poste ativo da NICK.
create unique index gis_postes_referencia_ativa_uidx on public.gis_postes (poste_referencia_id)
  where poste_referencia_id is not null and removido_em is null;
create trigger trg_gis_postes_atualizado_em before update on public.gis_postes
  for each row execute function public.set_atualizado_em();

comment on table public.gis_postes is 'OptiMap: poste INDIVIDUAL que a NICK usa ou projeta usar. Diferente de infra_postes (lote faturável, base do Infrastructure Floor), que não é alterada por nada do OptiMap.';
comment on column public.gis_postes.infra_poste_lote_id is 'Lote de infra_postes em que este poste é faturado. Só conciliação (vw_gis_conciliacao_lotes_postes) — nunca recalcula quantidade/custo do lote.';

-- ============================================================================
-- gis_elementos — elementos pontuais da rede óptica da NICK
-- ============================================================================
create table public.gis_elementos (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('CEO', 'CTO', 'SPLITTER', 'RESERVA_TECNICA', 'DERIVACAO', 'OUTRO')),
  codigo text,
  nome text,
  geom geometry(Point, 4326) not null check (app.gis_coordenada_valida(geom)),
  cidade_id uuid not null references public.cidades_infra(id) on delete restrict,
  poste_id uuid references public.gis_postes(id) on delete restrict,
  pop_id uuid references public.infra_pops(id) on delete restrict,
  estado text not null default 'DOCUMENTADO' check (estado in ('PLANEJADO', 'DOCUMENTADO', 'VALIDADO', 'DESATIVADO')),
  fonte_id uuid not null references public.gis_fontes(id) on delete restrict,
  -- Atributos técnicos variáveis por tipo (ex.: capacidade de bandejas, razão do splitter,
  -- portas da CTO). Nada é preenchido automaticamente.
  atributos jsonb not null default '{}'::jsonb check (jsonb_typeof(atributos) = 'object'),
  validado_por uuid references public.usuarios(id),
  validado_em timestamptz,
  observacoes text,
  criado_por uuid references public.usuarios(id) default auth.uid(),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz,
  check ((validado_em is null) = (validado_por is null)),
  check (estado <> 'VALIDADO' or validado_em is not null)
);
create index gis_elementos_geom_gix on public.gis_elementos using gist (geom);
create index gis_elementos_cidade_tipo_idx on public.gis_elementos (cidade_id, tipo);
create index gis_elementos_estado_idx on public.gis_elementos (estado) where removido_em is null;
create index gis_elementos_poste_idx on public.gis_elementos (poste_id);
create index gis_elementos_pop_idx on public.gis_elementos (pop_id);
create trigger trg_gis_elementos_atualizado_em before update on public.gis_elementos
  for each row execute function public.set_atualizado_em();

comment on table public.gis_elementos is 'OptiMap: elementos pontuais da rede da NICK (caixas de emenda/CEO, CTO, splitter, reserva técnica, derivação). POPs continuam em infra_pops (vistos no mapa via vw_gis_pops).';

-- ============================================================================
-- gis_trechos — traçado linear de cabo
-- ============================================================================
create table public.gis_trechos (
  id uuid primary key default gen_random_uuid(),
  codigo text,
  geom geometry(LineString, 4326) not null check (app.gis_coordenada_valida(geom) and ST_NPoints(geom) >= 2),
  cidade_id uuid not null references public.cidades_infra(id) on delete restrict,
  segmento_id uuid references public.infra_segmentos(id) on delete restrict,
  cabo_id uuid references public.infra_cabos(id) on delete restrict,
  ponta_a_elemento_id uuid references public.gis_elementos(id) on delete restrict,
  ponta_a_pop_id uuid references public.infra_pops(id) on delete restrict,
  ponta_b_elemento_id uuid references public.gis_elementos(id) on delete restrict,
  ponta_b_pop_id uuid references public.infra_pops(id) on delete restrict,
  tipo_instalacao text not null default 'AEREO' check (tipo_instalacao in ('AEREO', 'SUBTERRANEO', 'MISTO')),
  -- Comprimento geodésico do traçado desenhado, em metros. Sempre derivado da geometria;
  -- NUNCA propagado para infra_segmentos.extensao_km nem cidades_infra.km_rede (pricing).
  comprimento_geo_m numeric(12,2) generated always as (round(ST_Length(geom::geography)::numeric, 2)) stored,
  estado text not null default 'DOCUMENTADO' check (estado in ('PLANEJADO', 'DOCUMENTADO', 'VALIDADO', 'DESATIVADO')),
  fonte_id uuid not null references public.gis_fontes(id) on delete restrict,
  validado_por uuid references public.usuarios(id),
  validado_em timestamptz,
  observacoes text,
  criado_por uuid references public.usuarios(id) default auth.uid(),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz,
  check (ponta_a_elemento_id is null or ponta_a_pop_id is null),
  check (ponta_b_elemento_id is null or ponta_b_pop_id is null),
  check ((validado_em is null) = (validado_por is null)),
  check (estado <> 'VALIDADO' or validado_em is not null)
);
create index gis_trechos_geom_gix on public.gis_trechos using gist (geom);
create index gis_trechos_cidade_idx on public.gis_trechos (cidade_id);
create index gis_trechos_segmento_idx on public.gis_trechos (segmento_id);
create index gis_trechos_cabo_idx on public.gis_trechos (cabo_id);
create index gis_trechos_estado_idx on public.gis_trechos (estado) where removido_em is null;
create trigger trg_gis_trechos_atualizado_em before update on public.gis_trechos
  for each row execute function public.set_atualizado_em();

comment on table public.gis_trechos is 'OptiMap: traçado geográfico de um cabo. Um cabo (infra_cabos) pode ter vários trechos. Pontas ligam a elementos (CEO/CTO...) ou POPs.';
comment on column public.gis_trechos.comprimento_geo_m is 'Comprimento geodésico do desenho (m). Divergência com infra_segmentos.extensao_km aparece em vw_gis_divergencia_extensao_segmento — nunca é corrigida automaticamente.';

-- ============================================================================
-- gis_trecho_postes — sequência ordenada de postes de um trecho
-- ============================================================================
create table public.gis_trecho_postes (
  id uuid primary key default gen_random_uuid(),
  trecho_id uuid not null references public.gis_trechos(id) on delete restrict,
  poste_id uuid not null references public.gis_postes(id) on delete restrict,
  ordem integer not null check (ordem > 0),
  criado_em timestamptz not null default now(),
  unique (trecho_id, ordem),
  unique (trecho_id, poste_id)
);
create index gis_trecho_postes_poste_idx on public.gis_trecho_postes (poste_id);

comment on table public.gis_trecho_postes is 'OptiMap: postes por onde um trecho passa, em ordem. Relação física documentada — nunca inferida por proximidade.';

-- ============================================================================
-- gis_validacoes — histórico imutável de mudanças de estado (validação de engenharia)
-- ============================================================================
create table public.gis_validacoes (
  id uuid primary key default gen_random_uuid(),
  entidade text not null check (entidade in ('gis_postes', 'gis_elementos', 'gis_trechos')),
  entidade_id uuid not null,
  estado_anterior text,
  estado_novo text not null,
  motivo text,
  evidencia_documento_id uuid references public.documentos(id) on delete restrict,
  usuario_id uuid references public.usuarios(id) default auth.uid(),
  criado_em timestamptz not null default now()
);
create index gis_validacoes_entidade_idx on public.gis_validacoes (entidade, entidade_id, criado_em desc);

comment on table public.gis_validacoes is 'OptiMap: cada mudança de estado (PLANEJADO/DOCUMENTADO/VALIDADO/DESATIVADO) de poste, elemento ou trecho, gravada automaticamente por trigger. Imutável.';
