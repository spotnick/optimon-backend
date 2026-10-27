# OptiMap — Fase 3: Mapa interativo inicial — Relatório de entrega

Data: 2026-10-21
Escopo: rota `/optimap` com mapa, camadas, legenda, busca e painel de detalhes (somente visualização).

**Nenhuma migration foi criada nem aplicada nesta fase.** Nada foi executado no Supabase de produção. Os testes rodaram num ambiente local completo: Postgres 16 + PostGIS, PostgREST, API Express e Vite.

---

## 0. Situação do repositório antes de começar (conferida, não presumida)

- `supabase/migrations/` na sua pasta tem **135 migrations**: as 131 anteriores e as 4 da Fase 2 do OptiMap (`20261021090000`–`20261021090300`). Os tamanhos são idênticos à versão testada na Fase 2.
- As funções usadas pela interface existem com estas assinaturas:
  - `public.optimap_tile(p_camada, p_z, p_x, p_y, p_cidade_id)` → `bytea`;
  - `public.optimap_buscar(p_texto, p_limite)` → `jsonb` (`[{tipo, id, rotulo, lon, lat}]`);
  - `public.optimap_detalhe(p_camada, p_id)` → `jsonb`.

  Elas foram usadas como estão, sem alteração.
- A API não tinha nenhuma rota de mapa. O frontend não tinha biblioteca de mapa.
- O seed de produção (Jussara) tem 1 POP **sem coordenadas**. No estado real, portanto, todas as camadas do mapa estão vazias, e a interface mostra isso.

## 1. Arquivos criados e modificados

| Arquivo | Tipo | O que é |
|---|---|---|
| `api/routes/optimap.js` | novo | Rotas `/api/optimap/*` (abaixo) |
| `api/server.js` | modificado | Monta `/api/optimap` com `requireAuth` (2 linhas) |
| `api/test/smoke.js` | modificado | +2 checagens: tiles e busca sem JWT → 401 |
| `web/src/pages/OptiMap.jsx` | novo | Tela do mapa |
| `web/src/optimap/config.js` | novo | Configuração central: mapa-base, zooms mínimos, cores, rótulos, camadas |
| `web/src/optimap/camadasMapa.js` | novo | Fontes MVT e estilos das camadas do MapLibre |
| `web/src/optimap/PainelDetalhe.jsx` | novo | Painel lateral de detalhes |
| `web/src/optimap/optimap.css` | novo | Estilos da tela, carregados só no chunk do mapa |
| `web/src/App.jsx` | modificado | Rota `/optimap` com `React.lazy` + `Suspense` |
| `web/src/components/Layout.jsx` | modificado | Item "OptiMap" no menu, só para perfis com acesso |
| `web/src/lib/api.js` | modificado | Namespace `api.optimap` e `optimapTileUrl` |
| `web/package.json` / `package-lock.json` | modificado | Dependência `maplibre-gl` **5.24.0** (versão exata) |
| `web/.env.example` | modificado | Variável opcional `VITE_OPTIMAP_STYLE_URL`, documentada |
| `tests/optimap/fase3/stack.sh` | novo | Sobe o ambiente local completo |
| `tests/optimap/fase3/usuarios_teste.sql` | novo | Um usuário por perfil, mais um sem perfil (só local) |
| `tests/optimap/fase3/dados_teste_mapa.sql` | novo | Dados de **teste** identificados (só local) |
| `tests/optimap/fase3/e2e_optimap.js` | novo | Suíte E2E (Playwright) |
| `tests/optimap/fase3/screenshots/*.png` | novo | Capturas geradas pela suíte |

**Sobre o MapLibre 6.x:** existe, mas a 6.15.0 foi publicada há 3 dias. Ficou a 5.24.0 (abril/2026), estável e madura, que atende tudo o que esta fase usa. A atualização para 6.x pode ser avaliada depois.

## 2. Rotas e componentes

**API** (todas exigem JWT; o cliente Supabase é criado por requisição com a ANON_KEY e o JWT do usuário — mesmo padrão do resto do OptiMon; nenhuma chave privilegiada):

| Rota | Usa | Observação |
|---|---|---|
| `GET /api/optimap/sessao` | `pricing_current_user_role` | Perfil e permissão de ver/editar |
| `GET /api/optimap/resumo` | `count` exato sob RLS em `vw_gis_pops`, `gis_*`, `vw_gis_documentacao_incompleta` | Contagem por camada sem transferir linhas |
| `GET /api/optimap/tiles/:camada/:z/:x/:y.mvt` | `optimap_tile` | Converte o `bytea` (`"\x…"`) em binário MVT; tile vazio → 204; `Cache-Control: private, max-age=30` + `Vary: Authorization` |
| `GET /api/optimap/buscar?q=` | `optimap_buscar` | Texto com até 120 caracteres |
| `GET /api/optimap/detalhe/:camada/:id` | `optimap_detalhe` (POPs: `vw_gis_pops` + `infra_pops`) | Um elemento por vez, com os nomes dos vínculos |
| `GET /api/optimap/cidades/:id/extensao` | `vw_gis_pops` + `infra_pops` | Enquadramento da cidade **só** com coordenadas cadastradas; sem elas, `bbox: null` |

**Defesa em profundidade:** a API recusa com 403 os perfis sem acesso (FINANCEIRO, usuário sem perfil). Mesmo assim, o banco continua aplicando `app.gis_pode_ver()` em toda consulta: ir direto ao PostgREST não devolve dados (teste T12e).

**Nenhuma rota duplicada:** não existia rota de mapa, e as rotas `infra` existentes não foram tocadas.

**Frontend:**
- **Carregamento sob demanda.** `React.lazy` deixa o MapLibre num chunk separado (`OptiMap-*.js`, 1,06 MB / 281 kB gzip, mais CSS de 78 kB). O bundle principal passou de 789,75 kB para 792,01 kB (+2,3 kB). O MapLibre só é baixado ao abrir `/optimap` (testes T13a/T13b).
- **Camadas** (vector tiles por área e zoom; nunca a base inteira):

  | Camada | Fonte dos dados | Visível a partir do zoom |
  |---|---|---|
  | POPs | `vw_gis_pops` | qualquer |
  | Trechos | `gis_trechos` | 8 (planejados tracejados) |
  | Elementos | `gis_elementos` | 8 (cor por tipo, contorno por estado) |
  | Postes NICK | `gis_postes` | 8 (cor por estado; planejado vazado) |
  | Postes de referência | `gis_postes_referencia` | 12 (agregados do 12 ao 14, individuais do 15 em diante) |

  Cada camada tem liga/desliga próprio (memorizado no navegador), contagem confiável, estado vazio explicativo e aviso de "aproxime o mapa" abaixo do zoom mínimo.
- **Legenda:** estados (validado, documentado, planejado), tipos de elemento e origem (referência externa, agrupamento, POP).
- **Busca no topo:**
  - aceita cidade, código de POP, poste próprio, número externo, código de elemento e "lat, lon";
  - escolher um resultado centraliza o mapa na posição real e abre o detalhe;
  - coordenada → marcador e painel "Coordenada pesquisada", sem selecionar elemento por aproximação;
  - cidade sem coordenadas → aviso, e o mapa não é movido;
  - nenhum resultado → mensagem clara.
- **Seleção:**
  - clique abre o detalhe e destaca o elemento;
  - pontos têm prioridade sobre linhas;
  - feições sobrepostas mostram uma **lista para o usuário escolher**;
  - clique num agrupamento de referências aproxima o mapa.
- **Painel de detalhes:**
  - mostra só os campos que existem no registro devolvido (schema real), com coordenadas WGS84 copiáveis;
  - inclui fonte, data de referência, termos e atribuição, vínculos (cidade, POP, segmento, cabo, lote, poste, pontas), atributos técnicos, validação e histórico de estado;
  - poste externo recebe a faixa "Referência da concessionária — não indica que a NICK utilize este poste" e a indicação de vínculo (ou não) com poste da NICK.
- **Estados da tela:**
  - carregamento visível ("carregando…");
  - mapa-base indisponível → fundo neutro e aviso;
  - falha numa camada → erro na própria camada;
  - resumo indisponível → aviso com "tentar de novo";
  - API fora do ar → tela "OptiMap indisponível";
  - sem permissão → "Sem acesso ao OptiMap".
- **Barra de status:** zoom, coordenada do cursor e perfil.
- **Responsivo básico:** abaixo de 900 px, os painéis viram faixas e a busca desce. A prioridade é desktop.
- **Edição:** nenhuma ação de edição aparece nesta fase, para nenhum perfil.

## 3. Mapa-base (dependência externa)

| Item | Detalhe |
|---|---|
| Provedor | OpenFreeMap, estilo Positron (`https://tiles.openfreemap.org/styles/positron`) — sem chave, sem cadastro |
| Configuração | Centralizada em `web/src/optimap/config.js`. Trocar de provedor = definir `VITE_OPTIMAP_STYLE_URL` (MapTiler, Stadia, PMTiles próprio) |
| Termos / limites | A página de início rápido do OpenFreeMap não declara SLA, menciona Termos de Serviço e Política de Privacidade e pede, para downloads offline, no máximo 4 requisições paralelas e User-Agent próprio. Os dados são © OpenStreetMap / OpenMapTiles; o MapLibre exibe a atribuição que vem no estilo |
| Indisponibilidade | Se o estilo não carregar em 8 s (ou der erro), o OptiMap usa um fundo neutro local e mostra aviso. As camadas do OptiMon, que vêm da nossa API, continuam funcionando |
| Geocodificação | O mapa não usa camadas de texto, então não depende das fontes (glyphs) do provedor. Não há geocodificação de endereço (nenhum serviço aprovado) |
| Verificação | O sandbox de testes **não tem acesso** a `tiles.openfreemap.org` (bloqueio de rede do ambiente). O estilo real foi conferido pela documentação pública do serviço. Nos testes, a URL do estilo é interceptada: um teste devolve um estilo válido (sucesso) e outro aborta (indisponibilidade). **Por isso as capturas mostram fundo liso, sem ruas.** No seu navegador, com internet, aparece o mapa do OpenFreeMap |

## 4. Testes executados e resultados

| Suíte | Resultado |
|---|---|
| E2E OptiMap (`tests/optimap/fase3/e2e_optimap.js`, Chromium headless com WebGL) | **60 PASS / 0 FAIL** (2 execuções completas seguidas, ambas sem falha) |
| Smoke da API (`api/test/smoke.js`, com as 2 checagens novas) | **9 PASS / 0 FAIL** |
| Suíte SQL da Fase 2 (`run_tests_optimap_fase2.sh`, sem a etapa de 1 milhão de postes) | **112 PASS / 0 FAIL** — migrations da Fase 2 intactas |
| Lint (`oxlint`) | 0 erros. 2 avisos novos, do mesmo tipo já existente em outras telas (`set-state-in-effect`) |
| Build de produção (`vite build`) | OK; MapLibre só no chunk do OptiMap (`grep maplibre` no chunk principal = 0) |

### 4.1 Cobertura dos 14 testes obrigatórios

| # | Teste obrigatório | Testes E2E |
|---|---|---|
| 1 | Rota acessível a autorizados | T01a/b, T10a (ADMIN, DIRETOR, ENGENHARIA, COMERCIAL, AUDITOR) |
| 2 | Mapa-base | T02a (estilo aplicado), T02b (indisponível → fundo neutro + aviso, camadas funcionando) |
| 3 | POPs com coordenadas | T03, T03b |
| 4 | Camadas vazias sem dado fictício | T04a–d (estado real do seed de produção: contagem 0, mensagens, nada desenhado) |
| 5 | Alternância de visibilidade | T05a–c |
| 6 | Busca por código | T06a–h (elemento, POP, número externo, poste próprio, curinga `%%`) |
| 7 | Busca por coordenadas | T07a/b (centraliza exatamente, marcador, sem aproximar elemento) |
| 8 | Seleção e painel | T08a–f (POP, referência externa, poste validado com histórico, sobreposição, agregados) |
| 9 | Coordenadas inexistentes | T09a (cidade sem coordenadas), T09b (fora do Brasil), T09c (código inexistente) |
| 10 | Perfis autorizados e não autorizados | T10a–c, T10e (FINANCEIRO e sem perfil: sem menu, "Sem acesso", nenhum tile pedido; anônimo → login; nenhuma ação de edição) |
| 11 | Erros e indisponibilidade da API | T11a (tile 500), T11b (resumo 503), T11c (API fora), T11d (detalhe 500) |
| 12 | Autenticação e RLS preservadas | T12a–l (JWT nos tiles; 401 sem token e com token expirado; 403 FINANCEIRO/sem perfil; PostgREST direto sem dados; anônimo negado; cache só privado com `Vary` correto; parâmetros malformados → 400; escrita direta em `gis_postes` continua negada) |
| 13 | Carregamento lazy | T13a/b e o build de produção |
| 14 | Sem regressão nas demais telas | T14a (mapa sem erro de JavaScript), T14b (as 13 telas do menu abertas como ADMINISTRADOR, sem erro) |

**Dados usados nos testes:** os testes com dados usam um conjunto **de teste identificado**, apenas no banco local. São itens com código `TESTE-E2E-*`, uma fonte externa "TESTE — referência fictícia", observação "DADO DE TESTE LOCAL" e o POP `TESTE-E2E-POP`. Esse conjunto não existe em nenhuma migration e não deve ser aplicado em lugar nenhum além do sandbox. O teste de estado vazio usa só o seed de produção.

### 4.2 Falhas pré-existentes (não causadas por esta fase)

- **Fontes do Google:** o `index.html` carrega fontes de `fonts.googleapis.com`, que o sandbox não alcança. Isso gera um erro de rede no console em qualquer tela. É pré-existente e ambiental; a suíte separa esse caso de falhas reais.
- **Cadeia legada de testes SQL:** continua parando nos 5 testes de data/versão de preço da Fase 2.2, como registrado na Fase 2.
- **E2E antigos** (`e2e_fase24.js` etc.): dependem de um banco montado pela cadeia legada (usuário `optimon_admin`, dados das fases 2.x) e não foram reexecutados. A regressão de interface foi coberta pelo T14b, que percorre todas as telas.

### 4.3 Revisão independente

Um revisor que não participou da escrita analisou a API e a tela e testou contra o ambiente local. **Nenhum caminho de vazamento de dados foi encontrado.** Ele confirmou:
- FINANCEIRO e usuário sem perfil bloqueados na API e no banco;
- token forjado recusado;
- nenhuma chave privilegiada;
- o token nunca é enviado ao provedor do mapa-base.

Os problemas de robustez apontados foram corrigidos e ganharam teste:

| Achado | Correção |
|---|---|
| Token expirado virava erro 500 e o perfil ficava em cache | Cache limitado à validade do JWT e resposta 401 (T12i) |
| `Vary: Authorization` apagava o `Vary: Origin` do CORS | O header passa a ser acrescentado, não substituído (T12j) |
| Tipo da ponta do trecho sobrescrito pelo tipo do elemento | Campo corrigido (T12l) |
| Corrida entre cliques: a resposta antiga sobrescrevia a seleção nova | Respostas antigas são descartadas |
| Parâmetros repetidos ou malformados davam erro 500 | Passam a dar 400 (T12k) |
| Avisos de erro de camada nunca eram limpos | Somem quando a camada volta a carregar |
| Mensagens do Postgres chegavam ao cliente | Mensagens internas não vazam mais |
| Elemento arquivado aparecia no detalhe | Retorna 404, como nos tiles e na busca |
| Re-render a cada movimento do mouse | Limitado a um por quadro |

Observação do revisor, **fora do escopo desta fase**: a política de leitura de `infra_pops`, anterior ao OptiMap, permite que qualquer usuário autenticado, inclusive FINANCEIRO, leia coordenadas de POP direto no PostgREST. A tela do OptiMap não expõe isso. Se essa política deve ser restringida é uma decisão separada.

## 5. Confirmações

- Nenhuma migration criada, alterada ou aplicada. Nada executado no Supabase de produção.
- `infra_postes`, `cidades_infra.km_rede`, `infra_segmentos.extensao_km` e `contrato_fibras` não são lidos para escrita nem alterados: a Fase 3 não tem nenhuma operação de escrita.
- Nenhuma RLS alterada. As rotas novas usam o JWT do usuário e as funções de segurança da Fase 2.
- Nenhuma coleta da Copel, nenhuma importação GIS, nenhum dado fictício apresentado como real.

## 6. Limitações conhecidas

1. **Mapa-base real não foi visto no sandbox** (sem acesso de rede ao OpenFreeMap). A validação visual com ruas precisa ser feita no seu navegador, seguindo a seção 7.
2. **Busca de cidade** enquadra o mapa só pelos POPs com coordenadas. Se nenhum POP da cidade tiver coordenada, a interface avisa e não move o mapa.
3. **Contagens** são do total por camada (não do recorte visível) e recarregam ao abrir a tela.
4. **Cache de perfil** na API: 60 s por token. Uma troca de perfil leva até 1 minuto para refletir na mensagem 403, mas o banco aplica a regra nova imediatamente.
5. **Bundle do mapa** (281 kB gzip) baixado só na primeira abertura de `/optimap`; depois fica em cache do navegador.
6. Edição, importação, desenho de cabos e validação de engenharia ficam para as fases seguintes.

## 7. Como executar e validar localmente

Pré-requisitos: Node 20+, Postgres 16 com PostGIS 3, binário `postgrest` (v12) no PATH.

```bash
# 1. dependências
cd api && npm ci && cd ../web && npm ci && cd ..

# 2. banco local (NUNCA aponte para o Supabase real)
#    - "base": estado real (seed de produção) → camadas vazias
#    - "dados": + dados de TESTE identificados
PGHOST=/tmp PGPORT=5432 PGUSER=postgres tests/optimap/fase3/stack.sh banco dados

# 3. sobe PostgREST :3000, proxy :54321, API :3001 e Vite :5173
tests/optimap/fase3/stack.sh subir

# 4. testes
(cd api && npm test)
NODE_PATH=<pasta com playwright instalado>/node_modules node tests/optimap/fase3/e2e_optimap.js

# 5. parar
tests/optimap/fase3/stack.sh parar
```

Para abrir manualmente:
1. Entre em `http://127.0.0.1:5173/login`.
2. Injete uma sessão de teste com `node supabase/dev-local-only/mint_jwt.js a0000000-0000-0000-0000-000000000004` (COMERCIAL), do mesmo jeito que `tests/e2e_fase24.js` faz.
3. Abra `/optimap`.
4. Busque `TESTE-E2E-POP`.

Com internet, o fundo é o OpenFreeMap; sem internet, aparece o aviso de mapa-base indisponível.

**Para produção (quando autorizado):**
- aplicar as migrations da Fase 4.1 e depois as 4 da Fase 2 do OptiMap;
- publicar a API (rota nova) e o frontend;
- liberar o domínio da Vercel em `CORS_ALLOWED_ORIGINS` (já é o caso hoje).

## 8. Capturas de tela (`tests/optimap/fase3/screenshots/`)

| Arquivo | Conteúdo |
|---|---|
| `01_estado_real_camadas_vazias.png` | Estado real: contagens 0, mensagens de vazio, cidade sem coordenadas |
| `02_mapa_camadas_legenda.png` | Camadas e legenda com dados de teste |
| `03_busca_codigo_painel_elemento.png` | Busca por código → painel da caixa de emenda |
| `04_busca_coordenadas.png` | Busca "lat, lon" com marcador |
| `05_painel_poste_referencia_externa.png` | Referência externa destacada |
| `06_painel_poste_nick_validado.png` | Poste da NICK validado, com histórico |
| `07_referencias_agregadas_zoom13.png` | Agregação no zoom 13 |
| `08_mapa_base_indisponivel.png` | Contingência do mapa-base |
| `09_financeiro_sem_acesso.png` | FINANCEIRO sem acesso |
| `10_api_indisponivel.png` | API fora do ar |
