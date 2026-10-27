# OptiMap — Fase 2: Fundação geográfica — Relatório

Data: 2026-10-21
Escopo aprovado: estrutura de dados com PostGIS, separação entre dados externos e rede própria, permissões, consultas geográficas, testes e documentação. Mapa de fundo escolhido: OpenFreeMap (usado na Fase 3).

**Nada foi aplicado no Supabase real.** Todo o trabalho rodou num Postgres 16 + PostGIS 3.4 local, recriado do zero a cada execução.

---

## 1. Entregáveis

| Arquivo | Conteúdo |
|---|---|
| `supabase/migrations/20261021090000_optimap_2_01_postgis.sql` | Habilita PostGIS no schema `extensions` (padrão Supabase); aborta se já existir em schema inesperado |
| `supabase/migrations/20261021090100_optimap_2_02_schema.sql` | 7 tabelas novas `gis_*`, validação de coordenada, fontes semeadas |
| `supabase/migrations/20261021090200_optimap_2_03_regras_e_funcoes.sql` | Integridade, ciclo de estado, funções de escrita, views, tiles MVT, bbox, busca, detalhe, wrappers `public.optimap_*` |
| `supabase/migrations/20261021090300_optimap_2_04_rls_auditoria.sql` | Privilégios, RLS por perfil, auditoria |
| `tests/optimap/bootstrap_sandbox.sh` | Recria o banco de teste do zero (simula o search_path e os *default privileges* do Supabase) |
| `tests/optimap/run_tests_optimap_fase2.sh` | Suíte da fase (`PERF_GRANDE=1` adiciona o teste com 1 milhão de postes) |

Todas as migrations são **novas e aditivas**. Nenhuma migration histórica foi editada.

## 2. Modelo de dados

| Tabela | Papel |
|---|---|
| `gis_fontes` | Catálogo de fontes. `EXTERNA` (Copel) × `PROPRIA` (levantamento de campo, projeto, cadastro manual da NICK). A fonte Copel guarda URL, termos do aplicativo, data de verificação e a decisão de coleta (Adendo 2 da Fase 1). Tipo e código são imutáveis. |
| `gis_postes_referencia` | Postes **externos**: `id_externo` (= número do poste da Copel), ponto WGS84, cidade, situação da fonte, atributos brutos, data de referência, estado de sincronização (`CONFIRMADO`, `ATUALIZADO`, `DESATUALIZADO`, `DIVERGENTE`, `NAO_LOCALIZADO_ULTIMA_COLETA`, `EXCLUIDO_PELA_FONTE`). `UNIQUE(fonte, id_externo)` garante a idempotência. Nunca é apagado. |
| `gis_postes` | Postes **individuais que a NICK usa ou projeta**. Ligação opcional à referência externa e ao lote faturável (`infra_postes`). |
| `gis_elementos` | CEO (caixa de emenda), CTO, splitter, reserva técnica, derivação. Ligação opcional a poste e/ou POP. |
| `gis_trechos` | Traçado (LineString) de cabo, com cabo/segmento, pontas (elemento ou POP) e comprimento geodésico calculado. |
| `gis_trecho_postes` | Sequência ordenada de postes de cada trecho. |
| `gis_validacoes` | Histórico imutável de mudanças de estado (quem, quando, de/para, motivo, evidência). |

Estados da rede própria: `PLANEJADO`, `DOCUMENTADO`, `VALIDADO`, `DESATIVADO`.

**`infra_postes` continua sendo lote.** O OptiMap só a lê (view de conciliação "lote × postes georreferenciados"), sem alterar quantidade nem custo.

## 3. Regras garantidas pelo banco

- **Dado externo nunca vira rede da NICK sozinho.** A promoção (`optimap_promover_poste_referencia`) é um ato explícito. Ela cria um `gis_postes` com a posição e a fonte da referência e não altera a referência. Cada referência só pode ser promovida uma vez, e a cidade precisa ser a mesma.
- **Coordenadas** são validadas em toda tabela: SRID 4326, geometria válida e dentro do Brasil. Isso recusa (0,0), latitude e longitude trocadas e pontos fora do país.
- **Proximidade não é identidade:** dois postes a 0,5 m de distância, com números diferentes, continuam separados.
- **Validação:**
  - nada nasce `VALIDADO`;
  - validar exige motivo e registra quem validou;
  - `validado_por` e `criado_por` não podem ser forjados;
  - mudar a posição, inverter o sentido de um traçado, trocar um vínculo físico ou mexer na sequência de postes de algo `VALIDADO` o rebaixa para `DOCUMENTADO`, com motivo no histórico.
- **Vínculos coerentes:**
  - lote, POP e poste precisam ser da mesma cidade;
  - o cabo precisa pertencer ao segmento;
  - as pontas do trecho precisam existir e estar ativas.

  Pontas em outra cidade são permitidas de propósito, por causa dos backbones intermunicipais, como Cianorte–Jussara.
- **Edição controlada:**
  - `optimap_alterar_atributos` aceita uma lista fechada de campos por entidade (código, nome, observações, atributos técnicos, vínculos);
  - estado, geometria, fonte e autoria nunca passam por ela;
  - `optimap_definir_postes_trecho` redefine a sequência de postes com travamento contra edição simultânea;
  - a evidência de validação precisa ser um documento existente e ativo.
- **Arquivamento é lógico.** É bloqueado enquanto houver dependência ativa e protegido contra corrida entre transações (arquivar × ligar ao mesmo tempo).
- **Pricing intocado.** `extensao_km`, `km_rede`, `infra_postes.quantidade` e `contrato_fibras` nunca são escritos. Divergências entre o declarado e o desenhado aparecem só em views de relatório.

## 4. Segurança e permissões

| Ação | ADMIN | DIRETOR | ENGENHARIA | COMERCIAL | AUDITOR | FINANCEIRO | anon |
|---|---|---|---|---|---|---|---|
| Ver mapa (rede própria + referências) | ✓ | ✓ | ✓ | ✓ | ✓ | — | — |
| Cadastrar/editar/validar rede própria | ✓ | — | ✓ | — | — | — | — |
| Gravar postes de referência e fontes | ✓ | — | — | — | — | — | — |

- **Escrita só pelas funções.** `authenticated` não tem INSERT, UPDATE nem DELETE nas tabelas da rede própria. Toda escrita passa pelas funções `app.gis_*` (SECURITY DEFINER, `search_path` fixo, checagem de perfil). Um POST ou PATCH direto no PostgREST não contorna as regras.
- **RLS:** nenhuma policy `using(true)`. As regras de perfil vêm de uma única fonte (`app.gis_pode_ver` / `app.gis_pode_editar`), usada tanto pelas policies quanto pelas funções de leitura.
- **Leituras espaciais** (tile, bbox, busca) são SECURITY DEFINER por desempenho. Sob RLS, o Postgres não usa o índice espacial, porque o operador `&&` do PostGIS não é *leakproof*: medimos 1 s por consulta com apenas 40 mil postes. Essas funções aplicam explicitamente a mesma regra de perfil: FINANCEIRO e usuários sem perfil recebem resposta vazia.
- **Privilégios padrão do Supabase** (que dão ALL, inclusive TRUNCATE, a `anon`/`authenticated` em tabelas novas) são revogados primeiro, antes de conceder o mínimo.
- **Auditoria:** o trigger existente `fn_auditoria` foi ligado às tabelas da rede própria. `gis_postes_referencia` ficou fora de propósito: uma coleta de cidade gravaria dezenas de milhares de linhas no plano Free. A rastreabilidade dela vem do lote de importação da Fase 4. A whitelist de ações semânticas não foi alterada.

## 5. Consultas geográficas (o mapa nunca baixa a base inteira)

- `optimap_tile(camada, z, x, y)`: vector tile (MVT) para o MapLibre.
  - Postes de referência são agregados em grade entre os zooms 12 e 14 e enviados um a um a partir do zoom 15.
  - Postes de referência não são servidos abaixo do zoom 12; rede própria (postes, elementos, trechos), abaixo do zoom 8.
  - Teto de 20 mil feições por tile.
- `optimap_bbox`: GeoJSON por área. Máximo de 0,25 grau² (~50×50 km) e de 5.000 feições, com indicação de "truncado".
- `optimap_buscar`: aceita "lat, lon" (formato do mapa da Copel), número do poste, código de poste, elemento ou POP, e nome de cidade.
- `optimap_detalhe`: atributos, fonte (com termos e atribuição para dado externo), vínculos e histórico.
- Views:
  - `vw_gis_pops`: POPs com coordenada;
  - `vw_gis_conciliacao_lotes_postes`;
  - `vw_gis_divergencia_extensao_segmento`;
  - `vw_gis_documentacao_incompleta`.

## 6. Testes — resultado real

`tests/optimap/run_tests_optimap_fase2.sh` com `PERF_GRANDE=1`: **117 PASS / 0 FAIL**. O banco foi recriado do zero em cada execução.

O que a suíte cobre:
- instalação limpa das 135 migrations;
- assinatura estrutural das tabelas oficiais idêntica à do baseline, incluindo triggers internos;
- funções de auditoria existentes inalteradas;
- idempotência, coordenadas inválidas, proximidade, fonte errada;
- promoção, ciclo de estado e rebaixamentos;
- edição de atributos e da sequência de postes;
- gravação pelo `service_role` (usado na importação em lote da Fase 4);
- vínculos, arquivamento e corrida entre transações;
- RLS por perfil e anon, TRUNCATE negado, escrita direta negada, contexto forjado ignorado;
- tiles, bbox, busca e detalhe;
- preservação byte a byte dos dados oficiais e do `contrato_fibras`.

Desempenho medido dentro do banco, pior de 3 execuções, como COMERCIAL:

| Cenário | Tile z16 | Tile z15 | Tile z14 | Tile z12 (agregado) | Tile z10 (agregado) | Bbox de bairro |
|---|---|---|---|---|---|---|
| 40 mil postes (escala das 4 cidades) | 13 ms | — | — | 66 ms | — | 14 ms |
| 1,04 milhão (40 aglomerados de 25 mil) | 15 ms | 15 ms | 20 ms | 77 ms | não servido (zoom mínimo 12) | — |

| Tamanho em disco (tabela + índices) | |
|---|---|
| 40 mil postes | 16 MB |
| 1,04 milhão de postes | 389 MB |
| Paraná inteiro (~3,4 milhões, extrapolação) | ~1,3 GB → exige plano Pro |

**Convivência com dados reais:**
- O OptiMap foi aplicado sobre um banco populado com `seed_producao.sql` (Jussara, lote de 165 postes).
- As 4 migrations aplicaram sem erro, e os dados oficiais ficaram idênticos.
- A conciliação já mostra "165 no lote / 0 georreferenciados".

**Regressão das suítes legadas:** a cadeia `run_tests_fase312.sh` para na Fase 2.2 com 5 falhas (`NOVO12`, `NOVO12b`, `NOVO13`, `NOVO14`, `TESTE3a`). Elas aparecem **mesmo sem as migrations do OptiMap no banco**: são pré-existentes e ligadas à versão de preço/data (ex.: `pricing_version 2026.10`). Não foram causadas por esta fase; recomenda-se revisá-las separadamente.

## 7. Revisão independente

Um revisor que não participou da escrita testou as migrations com provas de conceito, em duas rodadas.
- **1ª rodada:** 3 problemas altos, 6 médios e 6 baixos.
- **2ª rodada** (reverificação das correções): 11 fechados e 2 novos problemas causados pelas próprias correções — o `service_role` perdia acesso, e não havia como editar atributos depois de criar o registro. Ambos foram corrigidos e cobertos por testes (T44h–T44m, T71b).

Os principais achados corrigidos:
- escrita direta pelo PostgREST contornava as regras: a escrita foi revogada;
- um trecho validado podia ter o sentido invertido sem perder a validação;
- corrida entre arquivar e vincular;
- busca sem escape e sem índice;
- TRUNCATE herdado dos privilégios padrão do Supabase.

**Pontos residuais aceitos e documentados:**
- **Postes de outra cidade num trecho:** permitido de propósito, para backbones intermunicipais.
- **Tamanho da auditoria:** a auditoria de `gis_postes`/`gis_trechos` guarda a geometria completa a cada alteração. É aceitável no volume da rede própria; reavaliar se o banco crescer.

**Decisão consciente mantida:** as FKs das tabelas `gis_*` para tabelas oficiais (cidades, POPs, segmentos, cabos, lotes, usuários, documentos) criam triggers internos de integridade nessas tabelas. O efeito é desejado: não é possível apagar um POP, cabo ou lote que o mapa documenta. A reversão de importação da Fase 4.1 trata cada item com savepoint; um item em uso fica "não revertido", com motivo, e a importação termina como `REVERTIDA_PARCIALMENTE`, sem quebrar.

## 8. Pendências e próximos passos

1. **Aplicação no Supabase:** só com sua autorização expressa.
   - Antes, medir o tamanho atual do banco (plano Free: 500 MB).
   - Confirmar que as migrations da Fase 4.1 serão aplicadas antes destas, pela ordem de timestamp.
2. **Fase 3 — Mapa inicial:** rota `/optimap`, MapLibre + OpenFreeMap, camadas, painel de detalhe, busca, filtros.
   - A API do Railway precisa de uma rota de tiles que repasse o JWT do usuário.
3. **Fase 4 — Coletor Copel + importação:**
   - área de pré-validação da importação geográfica;
   - coletor por município com as salvaguardas do Adendo 2;
   - prévia, aprovação e reversão;
   - piloto em Jussara.
4. Avaliar as 5 falhas pré-existentes da suíte legada da Fase 2.2.
