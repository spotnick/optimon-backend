# OptiMap — Fase 1: Diagnóstico e Viabilidade

Data: 2026-10-20
Escopo: somente análise. **Nenhuma migration criada, nenhum código alterado, nada executado no banco.**

Legenda usada em todo o documento:
- **[FATO]** — verificado diretamente (leitura do repositório ou resposta real de serviço).
- **[INFERÊNCIA]** — conclusão técnica a partir dos fatos, não confirmada.
- **[PENDENTE]** — depende de acesso, autorização ou confirmação sua/da Copel.

---

## 0. Resumo executivo

1. **O OptiMon hoje não tem nenhuma capacidade geográfica.** Sem PostGIS, sem coluna de geometria, sem biblioteca de mapa. A única coordenada existente é `infra_pops.latitude/longitude` (numeric). [FATO]
2. **`infra_postes` não pode virar o cadastro geográfico de postes.** É um lote faturável (`quantidade`, `custo_mensal`) que alimenta o Infrastructure Floor via `SUM(quantidade)`. Mexer na semântica quebraria o pricing. O OptiMap precisa de tabelas próprias de postes individuais, ligadas ao lote por FK opcional. [FATO + recomendação]
3. **A camada pública da Copel existe, mas é muito mais pobre do que o esperado.** O app usa ArcGIS Enterprise + Web AppBuilder; o Web Map tem **uma única camada**, "Posição postes compartilhados", com **6 campos**: `objectid`, `num_seq_geo`, `longitude`, `latitude`, `situacao`, `indic_ps_particular`. **Não há campo de ocupantes, altura, tipo ou material na camada pública identificada.** [FATO]
4. **A extração automatizada dessa camada não está autorizada.** O `robots.txt` da Copel tem `Disallow: /arcgis/` (exatamente o caminho do serviço de dados), e o item não declara licença nem termos de uso (`licenseInfo` e `accessInformation` vazios). Sem licença, a premissa é "todos os direitos reservados". Não consultei o serviço de dados e não recomendo integrar com ele. [FATO + recomendação]
5. **Há sinal de que a camada pública cobre só um recorte regional** (descrição do item: "CAFELANDIA PR ,REGIAO 03", ~38 KB, extent do Web Map minúsculo), e não os ~3,4 milhões de postes da Copel. [INFERÊNCIA]
6. **Caminho recomendado:** pedir à Copel, como ocupante com contrato, uma **exportação oficial** (CSV/Shapefile/GeoJSON) dos postes das cidades-piloto, usando `num_seq_geo` como chave estável. O OptiMap passa a ter um **importador de arquivos GIS autorizados**, e não um conector com o serviço da Copel.
7. **Recomendações técnicas:** PostGIS no Supabase + **MapLibre GL JS** no frontend + **vector tiles (MVT) gerados pelo PostGIS** e servidos pela API do Railway com o JWT do usuário. Importação **por cidade** agora; arquitetura preparada para crescer até a base integral sem reconstrução.

---

## 1. Diagnóstico da arquitetura atual

### 1.1 Stack [FATO]

| Camada | O que existe |
|---|---|
| Banco | Supabase/Postgres, **131 migrations** (`20260824090000` → `20261013090000`). Extensões: só `pgcrypto` e `pg_trgm`. |
| Lógica | Quase toda em SQL (`app.*` com wrappers `public.pricing_*` expostos ao PostgREST). |
| API | Node/Express (`api/server.js`), Docker no Railway, `requireAuth` exige `Bearer <jwt>`; o cliente Supabase é criado **por requisição com ANON_KEY + JWT do usuário** — RLS real sempre aplicada, sem service_role na API de usuário. |
| Frontend | React 19 + Vite 8 + react-router 6 na Vercel. Sem UI kit; gráficos próprios. **Nenhuma biblioteca de mapa.** |
| Storage | Bucket privado `documentos` (Fase 2.5); a Fase 4.1 reaproveita o prefixo `levantamentos/{importacao_id}/`. |
| Testes | Shell + Postgres local reconstruído do zero (`tests/run_tests_*.sh`), e2e/visual em Node. |

### 1.2 Tabelas de infraestrutura [FATO]

| Tabela | Pontos relevantes para o OptiMap |
|---|---|
| `cidades_infra` | `nome`, `uf`, `codigo_ibge` (UNIQUE), `km_rede` (usado no pricing), `status`. Sem geometria/limite municipal. |
| `infra_pops` | `codigo` UNIQUE por cidade, **`latitude/longitude numeric(9,6)`** (opcionais), `tipo`, `status`, `km_rede`/`postes_count` analíticos. |
| `infra_segmentos` | `origem`/`destino` **em texto livre**, `extensao_km` declarado, `status`, `observacoes`. Sem traçado. |
| `infra_cabos` | `segmento_id` (obrigatório), `pop_id`, `identificacao` UNIQUE **por segmento** (não global), `capacidade_fo`. |
| `infra_fibras` | Uma linha por fibra; status dividido em `status_operacional` / `status_comercial` / `status_contratual` (Fase 1.1). `status` legado ainda existe. |
| `infra_postes` | **Lote**: `quantidade`, `custo_mensal` agregado, `proprietario_terceiro`, `segmento_id` opcional, `status`, `observacoes`. Consumido por `SUM(quantidade)` no Infrastructure Floor. |
| `infra_portas_pon` | 1 porta por fibra (`unique(fibra_id)`), por POP; capacidade com colunas geradas. |
| `contrato_fibras` | Vínculo contrato × fibra/porta; índices únicos parciais de exclusividade. **Não será tocado.** |

Hierarquia real: `CIDADE → POP → (SEGMENTO) → CABO → FIBRA → PORTA PON → CONTRATO`. Hoje **nenhum elemento além do POP tem posição**, e não existem caixas de emenda, CTOs, splitters nem traçados.

### 1.3 RLS e auditoria [FATO]

- Infra (`cidades_infra`, `infra_*`): `SELECT to authenticated using (true)`; escrita só `ENGENHARIA`/`ADMINISTRADOR` via `app.tem_perfil(...)`.
- Staging da Fase 4.1: **nunca** `using(true)` — ADMINISTRADOR/DIRETOR veem tudo, ENGENHARIA só as próprias, demais perfis sem acesso.
- Perfis: `ADMINISTRADOR, DIRETOR, COMERCIAL, FINANCEIRO, ENGENHARIA, AUDITOR`.
- Auditoria: `public.auditoria` via trigger genérico `fn_auditoria()` (`to_jsonb(old/new)`), imutável; mais 3 overloads de `app.registrar_auditoria_semantica`.

### 1.4 Importação da Fase 4.1 [FATO]

Fluxo `RECEBIDA → EM_VALIDACAO → PREVIA → APROVADA → IMPORTADA` (+ REJEITADA/DESCARTADA/REVERTIDA/REVERTIDA_PARCIALMENTE), classificação `NOVO/ALTERADO/SEM_ALTERACAO/CONFLITO/INVALIDO`, matching por `chave_natural` só no staging (sem UNIQUE nova em tabela oficial), log imutável `importacao_alteracoes` com `ordem bigserial` e reversão seletiva que preserva edições posteriores. **As 5 migrations da Fase 4.1 ainda não foram aplicadas no Supabase real.** É o padrão certo para copiar no OptiMap.

### 1.5 Planilha de levantamento [FATO]

`Levantamento_Infraestrutura_OptiMon.xlsx`: aba **Postes é por rota/lote** (quantidade, locador, valor), **sem coordenadas**. Nenhuma aba tem lat/long, exceto o que vier dos POPs. Ou seja: hoje não existe nenhuma fonte interna de geometria de rede.

---

## 2. Tecnologia de mapa recomendada

**Recomendação: MapLibre GL JS + vector tiles (MVT) gerados pelo PostGIS.**

| Critério | Leaflet | MapLibre GL JS |
|---|---|---|
| Licença/custo | BSD-2, grátis | BSD-3, grátis (fork open-source do Mapbox GL v1) |
| Renderização | DOM/Canvas — degrada acima de ~10–20 mil pontos sem plugins | WebGL — centenas de milhares de feições com fluidez |
| Vector tiles | Só via plugin | Nativo |
| Estilo por atributo (estado de validação, tipo, fonte) | Manual | Expressões declarativas no estilo |
| Clustering | Plugin | Nativo para GeoJSON; para MVT, agregação no servidor por zoom |
| Desenho/edição de geometria | Leaflet.draw / Geoman (maduros) | `terra-draw` ou `maplibre-gl-draw` (bons, um pouco menos maduros) |
| Peso no bundle | ~40 KB | ~250 KB gzip (carregado só na rota do OptiMap, via lazy import) |

Justificativa: a meta declarada é crescer até uma base potencialmente de milhões de postes. Com Leaflet isso exigiria reescrever a camada de dados depois; com MapLibre + MVT o mesmo frontend serve para 4 cidades ou para o Paraná inteiro. [INFERÊNCIA técnica]

**Entrega dos dados:** rota na API do Railway `GET /api/optimap/tiles/:camada/:z/:x/:y.mvt` chamando uma função SQL `security invoker` que usa `ST_AsMVT` — o JWT do usuário é repassado (MapLibre suporta `transformRequest` para o header `Authorization`), então a **RLS continua valendo nos tiles**. Detalhes de um elemento vêm por endpoint JSON separado (`/api/optimap/elementos/:id`).

**Mapa-base:** não usar os tiles do `tile.openstreetmap.org` em produção (a política de uso do OSM proíbe uso intenso por aplicações). Opções [PENDENTE — sua escolha]:
- OpenFreeMap (grátis, sem chave) — risco de disponibilidade sem SLA;
- MapTiler / Stadia (pago com plano gratuito; ~US$ 0–25/mês no volume esperado);
- Protomaps PMTiles do Brasil/PR hospedado no próprio Supabase Storage ou Vercel (custo ~zero, mais trabalho inicial).
Imagem de satélite é útil em campo, mas é sempre paga em volume; tratar como opcional.

---

## 3. Possibilidade real de acesso aos dados da Copel

### 3.1 O que foi verificado [FATO]

| Item | Resultado |
|---|---|
| Plataforma | **ArcGIS Enterprise** ("Portal da Copel Distribuição", REST 9.2) + **Web AppBuilder 2D** (config 2.21, tema Foldable 2.8) |
| App (`c1fda25f…`) | "Mapa de compartilhamento Paraná", público, owner `portaladmin`, título interno "Mapa de Compartilhamento de Estruturas no Estado do Paraná – Copel Distribuição S.A." |
| Web Map | `05a1de287f614d55983cd0d3f4665af9`, público, modificado em 26/01/2026; tags "compartilhamento PS", "fibra", "cordoalhas" |
| Camada | **1 operationalLayer**: "Posição postes compartilhados" — **Hosted Feature Service** `https://www.copel.com/arcgis/rest/services/Hosted/MapaPublicoCompartilhamento/FeatureServer/0` (item `957450a9fb184cf18e98f6419909c4fd`) |
| Campos (popup) | `objectid`, `num_seq_geo`, `longitude`, `latitude`, `situacao`, `indic_ps_particular` — coordenadas exibidas com 6 casas decimais |
| Referência espacial | Web Map em 102100/3857 (Web Mercator), mapa-base Esri World Street Map |
| Autenticação | Portal com segurança por token para itens privados; **os itens acima são públicos** |
| Licença/termos | `licenseInfo` = null, `accessInformation` = null, portal sem termos, splash sem texto de aviso |
| robots.txt | **`Disallow: /arcgis/`** e `Disallow: /copelgeoimg/` para todos os agentes |
| Outros itens | App "Mapa de compartilhamento Paraná-Export" (`dcda27a3…`, 12/2025) e Web Maps regionais (Cafelândia, Londrina Etapa 5, Apucarana Etapa 2, "Projeto e Obras") |

### 3.2 O que NÃO foi verificado (por decisão, não por falha) [PENDENTE]

Por causa do `Disallow: /arcgis/`, **não consultei o FeatureServer**. Portanto não sei: `maxRecordCount`, capabilities (Query/Extract), paginação, formatos de saída, tipos dos campos, contagem total, contagem em Cianorte, `copyrightText`, se o serviço exige token. Não foi tentado nenhum contorno.

Se você quiser confirmar esses metadados, pode abrir manualmente no navegador a URL do serviço com `?f=pjson` — é uma consulta humana pontual a metadados, não extração. Mas isso **não** muda a conclusão sobre uso: o que autoriza armazenamento permanente é licença/contrato, não a disponibilidade técnica.

### 3.3 Conclusões

- **O que você descreveu (ocupantes, identificação, coordenadas) não bate com a camada pública identificada**: há coordenadas e um identificador (`num_seq_geo`), mas **não há ocupantes**. Pode ser que o app mostre ocupantes em outra tela ou para usuários logados — isso precisa ser verificado por você ou pela Copel. [PENDENTE]
- `num_seq_geo` é o melhor candidato a **identificador estável** do poste (parece o sequencial do GIS da Copel). Estabilidade a longo prazo precisa ser confirmada pela Copel. [INFERÊNCIA]
- A camada parece conter **postes com situação de compartilhamento**, não o cadastro técnico completo, e talvez só um recorte regional. [INFERÊNCIA]
- **Não implementar scraping nem integração direta com o serviço público.**

### 3.4 Alternativas autorizadas (em ordem de preferência)

1. **Exportação oficial da Copel** pelo gestor do contrato de compartilhamento ou pela "Plataforma de Gestão de Compartilhamento de Estruturas", pedindo: postes das cidades-piloto (ou dos que a NICK ocupa/projeta) com `num_seq_geo`, coordenadas, município, situação e — se possível — ocupantes e características técnicas, **com autorização escrita para armazenamento interno** e periodicidade de atualização. A NICK tem legitimidade como ocupante contratada.
2. **Projetos aprovados da própria NICK** — os projetos de ocupação enviados à Copel já trazem os postes com numeração; são dados da NICK e podem ser importados sem restrição.
3. **Levantamento de campo** (GPS/app) da Engenharia — fonte primária da rede própria em qualquer cenário.
4. **BDGD/ANEEL** (dados abertos, Plano de Dados Abertos) — pública e licenciada, mas **não confirmei que contenha postes como entidade**; as entidades citadas em literatura são de rede/transformadores/consumidores. Vale uma verificação dirigida. [PENDENTE]

Contexto regulatório [FATO, fontes externas]: a nova resolução conjunta ANEEL/Anatel (aprovada pela Aneel em 12/2025, pendências na Anatel e uma 2ª resolução sobre posteiros em discussão em 08/2026) **não** prevê, nas fontes consultadas, obrigação de a distribuidora publicar cadastro de postes/ocupantes. Não é base para extração.

---

## 4. Camadas e atributos efetivamente identificados

| Camada | Campo | Uso no OptiMap |
|---|---|---|
| Posição postes compartilhados | `objectid` | **Não usar como chave** — interno do serviço, pode mudar a cada republicação |
| | `num_seq_geo` | Chave externa (`id_externo`) |
| | `latitude`, `longitude` | Geometria (WGS84; exibidas com 6 casas ≈ 0,1 m de resolução numérica — a **precisão real** de campo é desconhecida) |
| | `situacao` | Atributo da fonte, guardado como veio (domínio de valores desconhecido) |
| | `indic_ps_particular` | Atributo da fonte (provável "poste particular") |

Nenhum campo de ocupantes, cidade/município, data de atualização ou atributos técnicos. Município teria que ser derivado por geometria (limite IBGE) — o que exige carregar malha municipal do IBGE (dado aberto). [INFERÊNCIA]

---

## 5. Condições de uso e limitações conhecidas

- Sem licença declarada → sem autorização para armazenamento permanente ou redistribuição. [FATO + interpretação]
- `robots.txt` veda acesso automatizado a `/arcgis/`. [FATO]
- Mesmo com dado autorizado, o OptiMap deve guardar por registro: **fonte, data de referência, condição de uso/licença e atribuição**, e restringir a visualização a perfis internos. Nada de dado da Copel em telas externas (proposta ao parceiro, assinatura).
- Os ocupantes, se vierem, são um retrato com data — nunca "verdade atual".

---

## 6. Estimativa de volume e desempenho [INFERÊNCIA]

Base: Copel ≈ **3,4 milhões de postes em 409 municípios** (fonte pública, 01/2025). Densidade média ≈ 0,3 poste/habitante no PR.

| Cenário | Postes (estimativa) | Tabela + índices (PostGIS, ~10 atributos + jsonb da fonte) |
|---|---|---|
| Cianorte | ~25 mil | ~10 MB |
| Jussara | ~2–3 mil | ~1 MB |
| Piraí do Sul | ~7–8 mil | ~3 MB |
| Ribeirão Claro | ~3–4 mil | ~1,5 MB |
| **4 cidades** | **~40 mil** | **~15–20 MB** |
| Paraná inteiro | ~3,4 milhões | **~1,3–2 GB** (linha ~250–350 B + GiST ~60 B + B-trees) |

Desempenho:
- Consulta por bbox com índice GiST: milissegundos em qualquer dos cenários.
- MVT por tile em zoom ≥ 14 (bairro): tipicamente < 100 ms; em zoom baixo é preciso **agregar** (grade/cluster no servidor) ou omitir a camada de postes — senão um tile do estado inteiro carregaria milhões de pontos.
- Carga inicial de 40 mil linhas: segundos. De 3,4 milhões: dezenas de minutos em lotes, melhor como job assíncrono.

---

## 7. Importação integral × por cidade

| Critério | A — Por cidade | B — Base integral |
|---|---|---|
| Autorização | Pedido pequeno e justificável (cidades onde a NICK atua) | Pedido grande; improvável sem acordo formal |
| Armazenamento | ~20 MB | ~1,5–2 GB — **acima do plano Free do Supabase (500 MB)**; cabe no Pro (8 GB incluídos) |
| Tempo de carga | segundos | dezenas de minutos, job assíncrono |
| Atualização | Simples, por cidade | Diferencial pesado; exige controle de "não localizado" em larga escala |
| Valor operacional | Alto (onde há rede) | Baixo fora da área de atuação |
| Mapa no navegador | Trivial | Exige MVT + agregação (já previsto) |

**Recomendação: Alternativa A agora**, com o modelo de dados indexado por `fonte + município/geometria`, de modo que B seja só "mais lotes de importação" se um dia houver autorização e interesse. Não é limitação por receio de volume: tecnicamente B é viável no plano Pro; o que impede hoje é **autorização** e **custo-benefício**.

---

## 8. Modelo de dados recomendado

Princípio: **5 conceitos separados** — referência externa, documentado, planejado, validado e pendente de revisão — sem nunca promover dado externo a rede própria automaticamente.

### 8.1 Pré-requisito

`create extension if not exists postgis with schema extensions;` — migration nova e aditiva. Impactos: cria `spatial_ref_sys` (o linter do Supabase alerta sobre RLS nela; é tabela de referência, sem dados internos), aumenta o tempo do `run_all.sh` local (o sandbox precisa ter PostGIS instalado). Geometrias em **SRID 4326**; comprimentos via `geography`.

### 8.2 Tabelas novas (prefixo `gis_`, schema `public`; staging no schema `staging`)

| Tabela | Papel | Campos principais |
|---|---|---|
| `gis_fontes` | Catálogo de fontes | `codigo` (ex.: `COPEL_EXPORT_OFICIAL`, `PROJETO_NICK`, `LEVANTAMENTO_CAMPO`, `BDGD`), `nome`, `licenca_texto`, `atribuicao`, `permite_armazenamento`, `permite_redistribuicao`, `documento_autorizacao_id` (→ `documentos`), `ativa` |
| `gis_postes_referencia` | **Postes externos** (nunca rede da NICK) | `fonte_id`, `id_externo` (`num_seq_geo`), `geom Point`, `cidade_id` (nullable, derivado), `codigo_ibge`, `atributos_fonte jsonb` (tudo como veio), `situacao_fonte`, `ocupantes_fonte jsonb` + `ocupantes_data_ref`, `data_referencia`, `ultima_importacao_id`, `estado_sincronizacao` (`CONFIRMADO`, `DESATUALIZADO`, `DIVERGENTE`, `NAO_LOCALIZADO_ULTIMA_CONSULTA`, `EXCLUIDO_PELA_FONTE`). **UNIQUE (fonte_id, id_externo)** — tabela nova, não oficial; é o que garante a idempotência. |
| `gis_postes` | **Postes que a NICK usa ou projeta** (individuais) | `codigo_interno`, `geom`, `cidade_id`, `poste_referencia_id` (nullable → externo), `infra_poste_lote_id` (nullable → `infra_postes`, o lote em que é faturado), `estado` (`PLANEJADO`, `DOCUMENTADO`, `VALIDADO`, `DESATIVADO`), `origem_fonte_id`, `validado_por/em`, `observacoes`, `removido_em` |
| `gis_elementos` | Elementos pontuais da rede | `tipo` (`CEO`/caixa de emenda, `CTO`, `SPLITTER`, `RESERVA_TECNICA`, `DERIVACAO`, `OUTRO`), `codigo`, `geom`, `poste_id` (nullable), `pop_id` (nullable → `infra_pops`), `estado`, `atributos jsonb` (portas, razão do splitter etc.), `removido_em` |
| `gis_trechos` | Traçado linear de cabo | `geom LineString`, `cabo_id` (nullable → `infra_cabos`), `segmento_id` (nullable → `infra_segmentos`), `ponta_a_elemento_id`, `ponta_b_elemento_id` (ou POP), `comprimento_geo_m` (calculado), `estado`, `removido_em` |
| `gis_trecho_postes` | Sequência ordenada de postes do trecho | `trecho_id`, `poste_id`, `ordem` |
| `gis_validacoes` | Histórico de validação de engenharia | `entidade`, `entidade_id`, `estado_anterior`, `estado_novo`, `evidencia_documento_id`, `usuario_id`, `em` |
| `staging.gis_importacoes` / `staging.gis_importacao_itens` / `staging.gis_importacao_alteracoes` | Prévia/aprovação/reversão de arquivos GIS | Mesmo desenho da Fase 4.1, com classificação extra `NAO_LOCALIZADO` e campos de geometria |

Fase 5+ (não na primeira versão): `gis_fusoes` (fibra × fibra dentro de uma CEO) e associação fibra × trecho, para chegar a rastreamento ponta a ponta.

**Por que staging separado e não estender `staging.importacao_itens`:** a tabela da Fase 4.1 tem `CHECK` fechado de `tipo_entidade` e `arquivo_*` obrigatórios voltados à planilha. Embora ela ainda não esteja aplicada em produção, misturar os dois fluxos acopla a homologação da Fase 4.1 ao OptiMap. Recomendo tabelas irmãs com as mesmas funções-padrão. [PENDENTE — sua decisão; a alternativa é estender a Fase 4.1 antes de homologá-la]

### 8.3 Os 5 estados da prompt, mapeados

| Conceito pedido | Onde vive |
|---|---|
| Referência externa | `gis_postes_referencia` (nunca vira rede da NICK sozinho) |
| Documentado | `gis_postes` / `gis_elementos` / `gis_trechos` com `estado = DOCUMENTADO` |
| Planejado | mesmas tabelas, `estado = PLANEJADO` |
| Validado | `estado = VALIDADO` + registro em `gis_validacoes` |
| Pendente de revisão | `staging.gis_importacao_itens` antes da aprovação |

Promoção externo → próprio é **sempre um ato explícito** de ENGENHARIA ("usar este poste na rota X"), que cria um `gis_postes` apontando para o externo — o externo continua intacto.

---

## 9. Integração com as tabelas existentes

| Tabela existente | Integração proposta | O que **não** fazer |
|---|---|---|
| `cidades_infra` | `cidade_id` nas tabelas `gis_*`; opcionalmente `gis_municipios` com limites IBGE (dado aberto) por `codigo_ibge` | Não adicionar geometria a `cidades_infra` |
| `infra_pops` | Começar por **view** `vw_gis_pops` (`ST_MakePoint(longitude, latitude)` onde não-nulo) — zero alteração. Mais tarde, se necessário, coluna gerada `geom` (aditiva) | Não exigir coordenada (POPs atuais podem não ter) |
| `infra_segmentos` | `gis_trechos.segmento_id`. Relatório de divergência `extensao_km` × soma de `comprimento_geo_m` | **Nunca** atualizar `extensao_km` ou `cidades_infra.km_rede` a partir da geometria automaticamente — ambos afetam pricing/Floor |
| `infra_cabos` | `gis_trechos.cabo_id` | Não criar UNIQUE global em `identificacao` |
| `infra_fibras` | Mapa **lê** `status_operacional/comercial/contratual` existentes para filtros | Não criar um 4º conceito de status de fibra |
| `infra_postes` (lote) | `gis_postes.infra_poste_lote_id` + view de conciliação `quantidade` × `count(gis_postes)` por lote | Não transformar lote em individual nem mudar `quantidade` |
| `infra_portas_pon` | Exibição por POP / CTO (via `gis_elementos.atributos`) | Não tocar `capacidade_utilizada_assinantes` |
| `contrato_fibras` | Somente leitura (ex.: "fibras vinculadas neste trecho") | **Nenhuma escrita** |
| `documentos` / bucket `documentos` | Fotos, levantamentos e autorizações da Copel com prefixo `optimap/...` | Nunca bucket público |
| `auditoria` | Trigger `fn_auditoria()` nas tabelas `gis_*` + `registrar_auditoria_semantica` para validação/importação | — |

---

## 10. Proposta de interface do OptiMap

- **Menu:** novo item "OptiMap" (rota `/optimap`, carregamento lazy para não pesar o restante do app).
- **Tela principal:** mapa em tela cheia; à esquerda, painel de **camadas** (POPs, Postes NICK, Postes de referência, Trechos, CEOs, CTOs) com legenda e contagem visível; topo com **busca** (cidade, código de POP/poste, `num_seq_geo`, coordenada "lat, long", endereço via geocoder — o geocoder também é serviço externo com custo/termos [PENDENTE]).
- **Filtros:** cidade, tipo de elemento, estado (`PLANEJADO/DOCUMENTADO/VALIDADO`), fonte, "pendente de revisão", "documentação incompleta", "divergência".
- **Simbologia:** a origem precisa ser óbvia — postes externos em cinza vazado; elementos NICK em cores sólidas por estado; tracejado para planejado; contorno de alerta para divergência.
- **Painel de detalhe (direita):** atributos, **fonte + data de referência + licença** sempre visíveis para dados externos, histórico de alterações, documentos/fotos anexos, ações conforme o perfil (validar, editar geometria, promover poste externo).
- **Seleção múltipla** (retângulo/laço) → exportar CSV/GeoJSON (fase 6).
- **Modo edição** (ENGENHARIA/ADMINISTRADOR): posicionar ponto, desenhar trecho "encaixando" em postes, mover vértice; toda gravação passa por função SQL auditada.
- **Tela de importação GIS:** upload → prévia em mapa + tabela (novos/alterados/conflitos/não localizados) → aprovação → aplicar → histórico/reverter, igual ao fluxo da Fase 4.1.

---

## 11. Segurança, auditoria e permissões

Proposta de matriz (a validar):

| Ação | ADMIN | DIRETOR | ENGENHARIA | COMERCIAL | FINANCEIRO | AUDITOR |
|---|---|---|---|---|---|---|
| Ver rede própria no mapa | ✓ | ✓ | ✓ | ✓? | — | ✓ |
| Ver postes de referência externa | ✓ | ✓ | ✓ | — | — | ✓ |
| Editar/cadastrar elementos | ✓ | — | ✓ | — | — | — |
| Validar (→ VALIDADO) | ✓ | — | ✓ | — | — | — |
| Iniciar importação GIS | ✓ | — | ✓ (só as próprias) | — | — | — |
| Aprovar/reverter importação | ✓ | ✓ | — | — | — | — |
| Administrar fontes/licenças | ✓ | — | — | — | — | — |
| Consultar histórico | ✓ | ✓ | ✓ | — | — | ✓ |

- **Sem `using(true)`** em nenhuma tabela `gis_*`, mesmo para SELECT (diferente das `infra_*` atuais) — dado externo licenciado e dado de rede são sensíveis. "COMERCIAL vê a rede própria?" é decisão sua [PENDENTE].
- Escrita só por funções `app.*` `security invoker` (o padrão da Fase 4.1), RLS como segunda barreira.
- Tiles MVT gerados com o JWT do usuário → a RLS se aplica aos tiles também. Sem cache público de tiles internos (cache só privado, por usuário/perfil).
- Nenhuma RLS existente é alterada. Nenhuma chave privilegiada no frontend.

---

## 12. Plano de implementação por fases (ajustado ao diagnóstico)

| Fase | Entrega | Observação |
|---|---|---|
| **1 (esta)** | Diagnóstico | Concluída, aguardando aprovação |
| **2 — Fundação geográfica** | Migration PostGIS + tabelas `gis_*` + staging GIS + RLS + funções de leitura por bbox/MVT + testes no sandbox | Nada aplicado em produção sem autorização expressa |
| **3 — Mapa inicial** | Rota `/optimap`, MapLibre, mapa-base, camadas de **POPs (dados que já existem)** e postes/elementos, filtros, painel de detalhe, legenda, identificação de fonte | Primeiro valor real usa só dado próprio |
| **4 — Importação GIS autorizada** | Importador de **arquivos** (CSV com lat/long, GeoJSON, KML/KMZ, Shapefile zipado) com prévia, comparação, idempotência por `(fonte, id_externo)`, conflitos, não localizados, aprovação, reversão. **Piloto: 1 cidade** (sugestão: Jussara — menor e com seed conhecido) | Substitui a ideia de "extração do serviço Copel" pelo recebimento de arquivo oficial |
| **5 — Documentação da rede** | Cadastro/edição de trechos, CEOs, CTOs, splitters; ligação com segmentos/cabos/POPs; conciliação de lotes de postes e de `extensao_km` | Fusões fibra-a-fibra numa subfase 5.x |
| **6 — Expansão** | Mais cidades, exportações (CSV/GeoJSON/KML), relatórios por cidade, comparação Copel × Engenharia, atualizações periódicas se a Copel fornecer | Base integral só com autorização |

Paralelo, fora do código: **pedido formal à Copel** (seção 3.4) — é o caminho crítico da Fase 4.

---

## 13. Testes necessários

**Banco (sandbox com PostGIS):**
1. Reimportar o mesmo arquivo não duplica (idempotência por `fonte_id + id_externo`).
2. Coordenadas inválidas (fora de −90/90, −180/180, (0,0), fora do PR/da cidade, lat/long trocadas) → INVALIDO com motivo.
3. Mesmo `id_externo` com coordenada movida > limiar → ALTERADO/CONFLITO, nunca sobrescrita silenciosa.
4. Dois externos distintos a < 1 m entre si → ambos mantidos (proximidade não é identidade).
5. Registro ausente na nova carga → `NAO_LOCALIZADO_ULTIMA_CONSULTA`, **nunca** excluído.
6. Correspondência sem id externo (por atributo + distância) com ambiguidade → CONFLITO para decisão humana.
7. Promoção externo → `gis_postes` não altera o registro externo.
8. Reversão seletiva preserva edição manual posterior (mesmo teste 16 da Fase 4.1).
9. RLS: cada perfil vê/escreve só o previsto na matriz; COMERCIAL/FINANCEIRO sem acesso a referência externa.
10. `contrato_fibras`, `infra_postes.quantidade`, `infra_segmentos.extensao_km` e `cidades_infra.km_rede` inalterados após qualquer operação do OptiMap.
11. Regressão completa das suítes existentes (incluindo os 27 testes da Fase 4.1.1) com PostGIS habilitado.

**Desempenho:** dataset sintético de 40 mil e de 3,4 milhões de postes; medir consulta por bbox e geração de MVT nos zooms 10/14/17 (meta: < 200 ms por tile em zoom ≥ 14) e garantir que nenhum endpoint devolve mais que N feições.

**Frontend:** smoke/visual (Playwright, já usado no projeto) da rota `/optimap`: carrega, alterna camadas, clica e abre detalhe, respeita perfil.

---

## 14. Riscos, custos e pontos pendentes

**Riscos**
1. **Legal/licença Copel** — maior risco. Mitigação: só arquivo oficial com autorização escrita registrada em `gis_fontes`.
2. **Expectativa sobre ocupantes** — a camada pública identificada não tem esse dado.
3. **Cobertura da camada pública pode ser só regional** (Cafelândia/Região 03).
4. **Estabilidade de `num_seq_geo`** não confirmada.
5. **Confusão de semântica** entre lote (`infra_postes`) e poste individual — mitigada pela separação de tabelas e conciliação só por relatório.
6. **Pricing contaminado por geometria** — mitigado pela regra de nunca atualizar `km_rede`/`extensao_km` automaticamente.
7. **Sandbox de testes** precisa de PostGIS instalado; aumenta a complexidade do `run_all.sh`.

**Custos estimados** [INFERÊNCIA]
| Item | Custo |
|---|---|
| PostGIS no Supabase | sem custo adicional (extensão nativa) |
| Armazenamento — 4 cidades | desprezível (~20 MB) |
| Armazenamento — PR inteiro | ~1,5–2 GB → exige plano Pro (US$ 25/mês já cobre 8 GB) |
| Mapa-base | US$ 0 (OpenFreeMap/PMTiles próprio) a ~US$ 25/mês (MapTiler/Stadia) |
| Geocodificação de endereço | opcional; gratuita com limites ou paga por uso |
| Railway (MVT) | CPU marginal para o volume de 4 cidades |

**Pontos que dependem de você**
1. Plano atual do Supabase (Free ou Pro)?
2. A NICK tem acesso à Plataforma de Gestão de Compartilhamento da Copel ou um gestor de contrato para pedir a exportação? Os projetos aprovados da NICK (com numeração de postes) estão disponíveis em algum formato?
3. COMERCIAL deve ver a rede própria no mapa?
4. Staging GIS separado (recomendado) ou estender a Fase 4.1 antes de homologá-la?
5. Preferência de mapa-base (gratuito sem SLA × pago com SLA × PMTiles próprio)?
6. Cidade-piloto: Jussara (sugerida) ou outra?
7. Uso em campo pelo celular é requisito da primeira versão? (Muda prioridade de UX e de modo offline.)

---

## Fontes externas

- Portal ArcGIS da Copel — itens `c1fda25f7e5d459b9f05556cdac52bc0` (app), `05a1de287f614d55983cd0d3f4665af9` (Web Map), `957450a9fb184cf18e98f6419909c4fd` (Feature Service), via `https://www.copel.com/portaldis/sharing/rest/...`
- `https://www.copel.com/robots.txt`
- [Cenário Energia — Copel conclui diagnóstico de fiação nos postes em 409 municípios (27/01/2025)](https://cenarioenergia.com.br/2025/01/27/copel-conclui-diagnostico-de-fiacao-nos-postes-em-409-municipios-do-parana/)
- [TI Inside — Copel reúne empresas de telecom para tratar de cabos nos postes (10/09/2025)](https://tiinside.com.br/10/09/2025/copel-reune-empresas-de-telecom-para-tratar-de-cabos-nos-postes/)
- [Demarest — Anatel e Aneel avançam em medidas para disciplinar o uso de postes](https://www.demarest.com.br/anatel-e-aneel-avancam-em-medidas-para-disciplinar-o-uso-de-postes-no-brasil/)
- [Teletime — Aneel quer definir regras a posteiros (26/08/2026)](https://teletime.com.br/26/08/2026/aneel-quer-definir-regras-a-posteiros-antes-de-discutir-metodologia-de-precos-dos-postes/)
- [Artigo SBA sobre a BDGD](https://ojs.sba.org.br/index.php/cba/article/download/4305/3789/6405)

---

## Adendo 1 — Respostas do usuário e verificação no aplicativo (2026-10-21)

### Respostas recebidas
1. Supabase: plano **Free** hoje; pode migrar se necessário.
2. Fonte de postes: **somente o mapa público da Copel** (sem acesso à Plataforma de Gestão de Compartilhamento nem a gestor de contrato).
3. COMERCIAL **pode ver** o mapa.
4. Staging separado × estender Fase 4.1: sem preferência → decisão técnica: **staging GIS separado** (seção 8.2).
5. Mapa-base: apresentar opções (abaixo).
6. Cidade-piloto: **Jussara**.
7. Uso em campo pelo celular: **não obrigatório** na 1ª versão → desktop primeiro, layout responsivo básico.

### Verificação no aplicativo (navegador, uso normal, sem aceitar os termos) [FATO]
O aplicativo exibe na abertura um aviso com **caixa "Eu concordo com os termos e condições acima"**. Texto relevante:
- Ao clicar num elemento, o usuário vê **"as coordenadas do ponto e o número do poste"**.
- Dados em **WGS84**.
- "Os dados aqui apresentados refletem o cadastro da base de dados da Copel Distribuição, que pode conter divergências em relação à situação de campo. Para a apresentação de projetos, **independente do status do poste (disponibilidade)**, as empresas de telecomunicações devem realizar a confirmação destas informações in loco. A Copel não se responsabiliza por inconsistências."

Consequências:
- `situacao` é o **status de disponibilidade** do poste para compartilhamento. **Ocupantes não são exibidos** pelo aplicativo.
- A finalidade declarada é apoiar **projetos de empresas de telecom** — uso compatível com consulta pela NICK. Os termos **não autorizam nem proíbem** expressamente armazenamento/cópia em massa; o `robots.txt` continua vedando acesso automatizado a `/arcgis/`.
- O próprio texto reforça o princípio do OptiMap: dado Copel = **referência**, validação **em campo**.

### Estratégia de fonte revisada (só mapa público)
| Opção | Como funciona | Conformidade | Esforço para Jussara (~165 postes ocupados) |
|---|---|---|---|
| **A. Registro assistido** | Engenharia consulta o mapa da Copel, clica no poste e registra no OptiMap `número do poste + coordenadas + status + data da consulta` (campo de colar/formulário rápido) | Total — uso humano previsto pelos termos | ~1 dia de trabalho |
| **B. Referência por link** | OptiMap guarda só o número do poste e abre o mapa Copel na coordenada para consulta | Total | Complementar à A |
| **C. Autorização por e-mail** | Pedido simples à área de compartilhamento da Copel (a NICK já paga aluguel de postes — há relação comercial) para consulta automatizada da camada pública em municípios específicos | Total após resposta escrita | Conector pequeno, implementável depois sem mudar o modelo |
| D. Extração automatizada sem autorização | — | **Não recomendada** (`robots.txt`) | — |

**Recomendação:** A + B agora (resolvem Jussara inteira), C em paralelo; o importador GIS da Fase 4 passa a aceitar também o lote produzido pela opção C se/quando autorizado.

### Mapa-base — opções
| Opção | Custo | Prós | Contras |
|---|---|---|---|
| OpenFreeMap | Grátis, sem chave | Zero configuração | Sem SLA |
| MapTiler (plano grátis → pago) | US$ 0 até ~100 mil carregamentos/mês; depois ~US$ 25+/mês | SLA, estilos prontos, satélite disponível (pago) | Chave de API, limite no grátis |
| Stadia Maps | Grátis para baixo volume; pago depois | Estilos bons | Chave/domínio, limite |
| PMTiles próprio (Protomaps, recorte PR) | ~US$ 0 (arquivo de algumas centenas de MB no Storage/Vercel) | Sem dependência externa | Montagem inicial e atualização manual; satélite não incluso |
| Esri World Street Map (o mesmo da Copel) | Exige conta ArcGIS Location Platform | Visual igual ao da Copel | Custo/termos Esri |

Sugestão: **começar com OpenFreeMap** (zero custo, troca é só configuração) e manter MapTiler como plano B com SLA.

### Plano Free do Supabase
- PostGIS funciona no Free.
- Volume de Jussara/4 cidades (dezenas de MB) cabe com folga no limite de 500 MB — **[PENDENTE]** medir o tamanho atual do banco antes da Fase 2.
- Base integral do PR exigiria Pro.

### Permissões ajustadas
COMERCIAL passa a ter **visualização** da rede própria e das referências externas (sem edição). Demais linhas da matriz da seção 11 mantidas.

---

## Adendo 2 — Decisão sobre a fonte Copel (2026-10-21)

**Decisão do usuário (NICK):** captura **automatizada direta** da camada pública `Hosted/MapaPublicoCompartilhamento/FeatureServer/0` (Opção 2), limitada aos campos públicos exibidos pelo aplicativo: número do poste (`num_seq_geo`), coordenadas e status de disponibilidade (`situacao`), além de `indic_ps_particular`.

Riscos registrados e aceitos pela NICK:
- O `robots.txt` da Copel veda acesso automatizado a `/arcgis/`; não há licença ou autorização escrita.
- Mesmo sem login, o servidor registra os acessos (IP, horário, volume) e pode limitar ou bloquear por IP ou alterar o serviço sem aviso.
- A camada pública pode ter cobertura parcial (descrição do item: "CAFELANDIA PR, REGIAO 03").

Salvaguardas obrigatórias no coletor:
1. Escopo por município (envelope/limite IBGE); começa por Jussara.
2. Primeiro passo sempre `returnCountOnly` (dry-run) antes de baixar.
3. Paginação respeitando o `maxRecordCount` do serviço; intervalo entre requisições (ex.: ≥ 2 s), sem paralelismo, janela fora do horário comercial.
4. User-Agent identificando a NICK e um e-mail de contato.
5. Parar ao primeiro 403/429/erro repetido; nunca trocar IP nem disfarçar o cliente.
6. Saída em arquivo GeoJSON → importação com prévia/aprovação (fonte `COPEL_MAPA_PUBLICO`, data de referência, termos registrados em `gis_fontes`).
7. Sem redistribuição; dados só para uso interno.
8. E-mail à Copel em paralelo, para formalizar.
