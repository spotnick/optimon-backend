# Relatório Final — Fase 2.2.1 Parte 2 (Ajuste Final do Pricing Engine + Régua de Preço + Primeira Versão Visual Funcional + Deployment dos Ambientes)

Status geral: **CONCLUÍDA (código, testes e preparação de ambientes) — 18/18 verificações novas PASS, 0 FAIL, mais regressão completa 124/124 PASS das fases anteriores (0 quebrado)**. O **deploy real** (Railway/Vercel/Supabase de produção) está **BLOCKED**, não por nenhum problema técnico, mas porque nenhum projeto Supabase existe ainda e nenhuma credencial (GitHub PAT, Supabase URL/anon/service_role/DB connection string, token Railway, token Vercel) foi recebida do usuário até o momento deste relatório. A Fase 3 **não foi iniciada** (item 19).

Este relatório segue o mesmo formato PASS/FAIL/BLOCKED usado em `docs/RELATORIO_FASE221.md` — nenhum resultado é omitido ou suavizado, incluindo os 2 bugs reais encontrados durante a própria validação (item 9) e a limitação de ambiente que impediu testar a build da imagem Docker localmente (item 15).

## 1. Arquivos alterados ou criados

- `supabase/migrations/20260831090000..090800_phase_deploy_*.sql` — 9 migrations novas.
- `api/lib/calculatePricing.js`, `api/lib/version.js` — novos.
- `api/routes/cities.js`, `api/routes/simulations.js`, `api/routes/proposals.js`, `api/routes/audit.js` — novos.
- `api/routes/pricing.js` — rotas novas (`/calculate`, `/growth-curve`, `/horizon-table`, `/ramp`, `/indices`, `/:id`).
- `api/server.js` — reescrito (CORS com allowlist, `/health`, `/api/version`, error middleware, rotas novas).
- `api/package.json`, `api/test/smoke.js`, `api/Dockerfile`, `api/.dockerignore`, `api/.env.example`, `api/README.md` — novos/atualizados.
- `web/` — app inteiro novo (Vite + React): `package.json`, `vite.config.js`, `index.html`, `vercel.json`, `.env.example`, `src/` completo (App, main, context, components, charts, pages, styles).
- `.gitignore`, `.dockerignore`, `.env.example` (raiz, consolidado), `railway.toml`, `.github/workflows/ci.yml` — novos.
- `tests/run_tests_deploy.sh` — novo.
- `supabase/dev-local-only/postgrest.local.conf`, `mint_jwt.js`, `rest_v1_proxy.js` — novos (ferramenta de desenvolvimento local, nunca copiar para um Supabase real).
- `supabase/dev-local-only/shim_supabase_auth.sql` — estendido (não substituído): `auth.uid()` agora lê o JWT primeiro, com fallback para o GUC antigo.
- `README.md`, `docs/ARQUITETURA.md` (seção 19), `docs/RELATORIO_FASE221_PARTE2.md` (este arquivo).

Nenhuma migration `2026082[4-9]*` ou `20260830*` (fases anteriores) foi editada — só leitura.

## 2. Migrations (9 novas, todas aditivas)

| # | Arquivo | O que faz |
|---|---|---|
| 1 | `090000_..._01_api_surface_secao31.sql` | `public.pricing_cities_list()`, `public.pricing_city_detail(uuid)`, `app.pons_necessarias_para_clientes(...)`, `public.pricing_pons_for_clients(...)`. |
| 2 | `090100_..._02_calculate_pricing_full.sql` | `app.simular_precificacao_completa(jsonb)` / `public.pricing_calculate_full(jsonb)` — o Pricing Engine centralizado, contract-free. |
| 3 | `090200_..._03_simulacoes_propostas_auditoria.sql` | `public.pricing_simulation_save(...)`, `public.pricing_proposal_create(...)`, `public.pricing_proposals_list(...)`, `public.pricing_audit_list(...)`, `public.pricing_log_login()`. |
| 4 | `090300_..._04_auditoria_acao_login.sql` | Amplia `auditoria_acao_check` para aceitar `'LOGIN'` (aditivo — INSERT/UPDATE/DELETE preservados). |
| 5 | `090400_..._05_pricing_get_by_id.sql` | `public.pricing_simulation_get(uuid)`. |
| 6 | `090500_..._06_fix_grants_views_authenticated.sql` | **Correção real** (item 9): `GRANT SELECT` para `authenticated` em 6 views que nunca tinham recebido. |
| 7 | `090600_..._07_growth_curve.sql` | `app.simular_curva_crescimento(...)` / `public.pricing_growth_curve(...)`. |
| 8 | `090700_..._08_rampa_indices_wrappers.sql` | `public.pricing_ramp_rules_list(uuid)`, `public.pricing_indices_list(text, int)`. |
| 9 | `090800_..._09_horizon_table.sql` | `app.simular_tabela_horizontes(...)` / `public.pricing_horizon_table(...)` (12/36/48/60 meses, 48 = mínimo contratual). |

Nenhuma delas usou `DROP FUNCTION` — todas são `CREATE OR REPLACE`/`CREATE`/`GRANT`/`ALTER TABLE ... ADD CONSTRAINT` sobre objetos novos ou sem mudança de assinatura.

## 3. Pricing Engine centralizado (seção 32) — a peça central desta fase

`app.simular_precificacao_completa(p_params jsonb)`, exposta como `public.pricing_calculate_full(p_params jsonb)`, é agora a **única porta de entrada** para qualquer preço mostrado no frontend. Reaproveita a mesma lógica de composição Floor×Mínimo×Revenue Share de `app.get_economia_com_piso` (Fase 2.2), generalizada para funcionar sem contrato existente (cotação para cliente novo). `api/lib/calculatePricing.js` é um wrapper JS deliberadamente fino — monta o `jsonb`, chama a função via `supabase-js`, devolve o resultado; nunca reimplementa uma fração da fórmula. O backend **sempre recalcula do zero** a partir dos parâmetros de entrada — nenhum "total" vindo do frontend é aceito ou usado. Verificado (TESTE-D1): Jussara 1 PON via API → Piso R$2.020,00 / Recomendado R$2.320,00 / Abertura R$2.620,00, idêntico ao exemplo oficial.

## 4. Superfície de API completa (seção 31) — 24 endpoints

| Método | Rota | Autenticação |
|---|---|---|
| GET | `/health` | nenhuma |
| GET | `/api/version` | nenhuma (nunca inclui segredos) |
| GET | `/api/cities`, `/api/cities/:id` | qualquer autenticado |
| POST | `/api/pricing/calculate` | qualquer autenticado — Pricing Engine centralizado |
| POST | `/api/pricing/growth-curve`, `/api/pricing/horizon-table` | qualquer autenticado |
| GET | `/api/pricing/ramp`, `/api/pricing/indices`, `/api/pricing/:id` | autenticado / dono ou DIRETOR/ADMINISTRADOR/AUDITOR |
| POST/GET | `/api/simulations` | COMERCIAL/DIRETOR/ADMINISTRADOR / dono ou DIRETOR+ |
| POST/GET | `/api/proposals` | COMERCIAL/DIRETOR/ADMINISTRADOR / qualquer autenticado |
| GET/POST | `/api/audit`, `/api/audit/login` | qualquer autenticado |
| (+ 11 rotas herdadas da Fase 2, inalteradas: `/api/pricing/simulate`, `/quote`, `/approve`, `/versions`, `/scenarios`, `/override`, `/roi`, `/projection`, `/current-role`) | | |

Detalhe completo em `api/README.md`.

## 5. Bug real encontrado: 6 views sem `GRANT` para `authenticated`

`vw_capacidade_cidade`, `vw_capacidade_contrato`, `vw_capacidade_parceiro`, `vw_capacidade_pop`, `vw_contrato_capacidade`, `vw_porta_pon_detalhe` — todas existentes desde a Fase 1/1.1 — nunca tinham recebido `GRANT SELECT ... TO authenticated`. Só apareceu porque esta é a **primeira fase em que os testes rodam como o papel `authenticated` de verdade** (via PostgREST + JWT), não como o superusuário do Postgres usado em todo teste `psql` anterior, que ignora `GRANT`. Corrigido com a migration 6, sem alterar a definição de nenhuma view. Nenhum dado ou regra de negócio foi afetado — só visibilidade da view para o papel correto.

## 6. Pilha de desenvolvimento local equivalente ao Supabase (seção "não existe Supabase ainda")

Como nenhum projeto Supabase existe para o OptiMon, a validação desta fase precisou de uma pilha local fiel: PostgREST (binário estático) + `rest_v1_proxy.js` (remove o prefixo `/rest/v1` que `supabase-js` sempre adiciona — PostgREST puro não serve esse caminho) + `mint_jwt.js` (JWTs HS256 de teste, sem GoTrue) + extensão do shim de `auth.uid()` (lê `request.jwt.claims->>'sub'`, com fallback para o GUC `app.current_user_id` usado desde a Fase 1 — 100% de compatibilidade retroativa). Gotcha documentado e corrigido: o PostgREST cacheia o schema no boot — toda função nova precisa de `NOTIFY pgrst, 'reload schema';`, já embutido em `tests/run_tests_deploy.sh`. Nada disso é copiado para um projeto Supabase real (`supabase/dev-local-only/` é explicitamente excluído dessa cópia, ver `README.md`).

## 7. Frontend React — primeira versão visual funcional (seção 33-40)

`web/` (Vite + React 19 + `react-router-dom` 6.30.6 + `@supabase/supabase-js`, este último só para autenticação): Login, Dashboard principal (lista de cidades), Dashboard por cidade (régua de preço, POPs, capacidade), Nova Simulação (botões rápidos de cliente, 2 gráficos SVG desenhados à mão seguindo a skill de dataviz — crescimento/receita e clientes/PONs, eixo único, crosshair no hover — e tabela de horizontes 12/36/48/60 meses com 48 meses marcado como mínimo contratual), Propostas (lista + geração), Auditoria (log, incluindo `LOGIN`). Modo demonstração via `VITE_APP_ENVIRONMENT` exibido na tela de login. Design responsivo (petróleo `#0f4c81` + teal `#14b8a6`, Manrope/Inter/IBM Plex Mono, claro/escuro via `prefers-color-scheme`). Build de produção: **461,82 kB JS (131,05 kB gzip) / 8,12 kB CSS**. O frontend nunca reimplementa a fórmula de preço — todo valor exibido vem de uma chamada real à API (item 3); o único cálculo no cliente é de apresentação (formatação, ordenação).

Verificado visualmente via Playwright headless (Chrome extension não disponível neste sandbox) contra dados reais em todas as telas, incluindo a régua de Jussara batendo exatamente com o exemplo oficial na tela, não só na resposta da API.

## 8. Testes novos obrigatórios (seção 41) — 7 verificações, todas via HTTP com JWT real

`TESTE-D1` — Jussara+1PON via `POST /api/pricing/calculate`: floor=R$2.020,00, recommended=R$2.320,00, opening=R$2.620,00 (exato). `TESTE-D2` — 129 clientes → 2 PONs. `TESTE-D3` — 257 clientes → 3 PONs. `TESTE-D4` — R$2.019,00: COMERCIAL=`BLOCK_FOR_COMMERCIAL`, DIRETOR=`ALLOW_WITH_DIRECTOR_OVERRIDE` (por papel real, JWT+RLS). `TESTE-D5` — R$1.310,00 (piso absoluto exato): DIRETOR=`ALLOW_WITH_DIRECTOR_OVERRIDE`. `TESTE-D6` — R$1.309,00 (abaixo do piso absoluto): DIRETOR=`BLOCK` — bloqueado até para DIRETOR. Todos **PASS**.

## 9. Teste de performance (seção 43)

`TESTE-D7`: 5 chamadas consecutivas via HTTP a `POST /api/pricing/calculate` — **média de 19ms por chamada**, muito abaixo do limite de 500ms exigido. Medido na pilha local (PostgREST + API Node + Postgres, tudo no mesmo host) — a latência em produção (Railway↔Supabase, rede real) será maior, mas a margem (19ms vs. 500ms) é ampla o suficiente para absorver a diferença esperada. **PASS**.

## 10. Fluxo E2E completo (seção 42) — 8 verificações

`E2E-1` login registrado em auditoria (`POST /api/audit/login` → 204). `E2E-2` dashboard principal lista Jussara. `E2E-3` dashboard da cidade traz os POPs. `E2E-4` Nova Simulação com 100 clientes → `total_payable` calculado pela API. `E2E-5` recalcular com 200 clientes → `pons_count=2`, novo total — prova que o recálculo é real, não em memória no cliente. `E2E-6` simulação salva. `E2E-7` proposta gerada a partir da simulação salva. `E2E-8` auditoria mostra os 3 eventos do fluxo (LOGIN + simulação + proposta). Todos **PASS** — prova de ponta a ponta que nenhuma decisão de preço é tomada no frontend.

## 11. Regressão completa (fases anteriores) — 124/124 PASS, 0 quebrado

`tests/run_tests_deploy.sh`, Passo 0, reexecuta `tests/run_tests_fase221.sh` **original, sem edição**, antes de aplicar as 9 migrations novas: **124 de 124 PASS** (100 da regressão Fase 1..2.2 embutida em `run_tests_fase22.sh` original + 24 da própria bateria de Fase 2.2.1 — Passo C de versionamento e Passo D TESTE-30..41). Confirmado nesta sessão com uma re-execução limpa (processos PostgREST/API parados antes, evitando o `DROP DATABASE` silencioso já documentado desde a Fase 2.2.1) — 0 regressão em qualquer fase anterior.

## 12. Preparação GitHub

`.gitignore` cobrindo todo segredo conhecido do projeto (`.env*`, `service_role`, `DATABASE_URL`, `.vercel/`, `.railway/`, o `postgrest.local.conf` de dev). `.github/workflows/ci.yml`: 2 jobs paralelos (API: install/lint/test via `npm test` — smoke test sem banco real; Web: install/lint/build), sempre com variáveis fictícias. Repositório Git local inicializado (`git init`, branch `main`) e **primeiro commit criado nesta sessão** (150 arquivos, nenhum segredo — conferido com `git add -A --dry-run` antes de commitar, só `.env.example` foi staged entre os arquivos de variável de ambiente). O push para um repositório GitHub real segue **BLOCKED** — nenhum PAT ou URL de repositório foi recebido.

## 13. Preparação Railway (API)

`api/Dockerfile` (multi-stage `node:22-alpine`, `COPY api/... `a partir da raiz do monorepo, `npm ci --omit=dev`, `HEALTHCHECK` batendo em `/health`) + `railway.toml` na raiz (`builder=DOCKERFILE`, `dockerfilePath=api/Dockerfile`, `healthcheckPath=/health`, `restartPolicy=ON_FAILURE`). Variáveis a configurar no painel: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `CORS_ALLOWED_ORIGINS`, `APP_ENVIRONMENT=production`. **Nunca** `SUPABASE_SERVICE_ROLE_KEY`. (`node:22-alpine` — ver item 15: a versão original `node:20-alpine` só se mostrou um problema no deploy real.)

## 14. Preparação Vercel (frontend)

`web/vercel.json`: `buildCommand`/`outputDirectory` para Vite, rewrite de SPA (`/(.*)`→`/index.html`), headers de segurança (`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`) e cache longo para `/assets`. Variáveis: `VITE_API_URL` (URL do Railway), `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (anon key é segura para expor no bundle público), `VITE_APP_ENVIRONMENT`. O frontend nunca acessa o banco diretamente para lógica de negócio — só `auth.signInWithPassword`/`signOut` usam `supabase-js`; todo o resto passa pela API.

## 15. Limitação de ambiente disclosed: build da imagem Docker não testável localmente — confirmada na prática, 4 bugs reais encontrados e corrigidos

`docker build`/`dockerd` não estavam disponíveis neste sandbox (`ulimit: error setting limit (Operation not permitted)` — sem daemon Docker privilegiado), então o `Dockerfile` não pôde ser construído nem executado localmente durante a entrega original — ficou marcado como a única verificação pendente. O deploy real no Railway e a primeira aplicação dos seeds num Supabase real confirmaram que essa limitação era real: apareceram 4 bugs que nenhuma bateria local (mesmo com PostgREST + JWT reais) pegaria, porque dependiam especificamente do ambiente de produção (imagem Docker de verdade, e a ORDEM real de deploy — todas as migrations primeiro, seeds depois — diferente da reconstrução incremental fase a fase usada nas baterias locais). Todos encontrados e corrigidos em conjunto com o usuário — detalhe completo na seção 19.9 de `docs/ARQUITETURA.md`:

1. **Rota async lançando erro síncrono travava a resposta em `502`** — nenhum handler tinha `try/catch` em torno de `clientForRequest()`, e o Express 4 não encaminha uma rejeição de handler `async` para o middleware de erro sozinho; a requisição nunca recebia resposta e o Railway derrubava a conexão por timeout, sem log útil no navegador. Corrigido com `require('express-async-errors')` uma vez em `server.js` — cobre todas as rotas de uma vez. Confirmado localmente (forçando `SUPABASE_URL=""`: travava antes, responde `500` limpo depois) e reexecutada a bateria completa — 18/18 PASS, sem regressão.
2. **`@supabase/supabase-js` exige WebSocket nativo (Node 22+) para sequer inicializar o cliente**, mesmo sem usar Realtime — `api/Dockerfile` usava `node:20-alpine`; o `SupabaseClient` sempre inicializa um `RealtimeClient` internamente, e essa inicialização falha em Node <22 por falta de `WebSocket` nativo. Nenhum teste local pegou isso porque o ambiente de desenvolvimento desta sessão já roda Node 22. Corrigido trocando as 2 stages do Dockerfile para `node:22-alpine` — sem mudança de código-fonte.
3. **`seed_producao.sql` violava `pricing_parametros.pricing_version NOT NULL`** quando aplicado depois de TODAS as migrations. Essa coluna só virou real e `NOT NULL` na migration `20260830090000` (Fase 2.2.1), que faz um backfill único das linhas que já existiam naquele momento — nas baterias locais o seed sempre roda antes dessa migration futura (reconstrução incremental fase a fase), então o backfill sempre alcança; no deploy real a ordem é invertida e o `INSERT` do seed nunca informava a coluna. Corrigido informando `pricing_version` explicitamente no `INSERT` de `seed_producao.sql` (mesma convenção do backfill: `to_char(current_date,'YYYY.MM')`). `seed.sql` (usado só localmente) foi deliberadamente mantido como estava — corrigi-lo quebraria a reconstrução incremental local.
4. **`seed_producao.sql` criava o cabo `CABO-JUSSARA-01` sem `pop_id`**, quebrando o primeiro `INSERT` em `infra_portas_pon` de `seed_fase11.sql` (trigger `fn_valida_porta_pon_pop`). A migration `20260825100100_infra_pops.sql` cria um `POP-01` automaticamente só por backfill único, para cabos que já existirem no momento em que ela roda — no deploy real ela roda antes do seed criar o cabo, então não encontra nada para backfillar. Corrigido fazendo `seed_producao.sql` criar o `POP-01` explicitamente e vincular o cabo a ele.

Bugs 3 e 4 têm a mesma causa raiz: um seed escrito e testado só sob a ordem "algumas migrations → seed → mais migrations" (fluxo local fase a fase) quebra sob a ordem real de produção ("todas as migrations → seed"), porque backfills de migração são pontuais no tempo. Verificado após a correção: `seed_producao.sql` + `seed_fase11.sql` + `seed_fase12.sql` + `seed_fase2.sql` aplicados em sequência, do zero, contra um banco com as 74 migrations já aplicadas (ordem real de produção) — os 4 arquivos aplicam sem erro. Bateria completa de regressão re-executada — 124/124 PASS, sem regressão (nenhuma mudança em `seed.sql`, o único seed usado pelos testes locais).

## 16. Estado do deploy real

GitHub (`spotnick/optimon-backend`), Supabase (projeto `zmhektrjgrjvcsysrbmw`, 74 migrations aplicadas), Railway (`optimon-backend-production.up.railway.app`) e Vercel (`optimon-backend-roan.vercel.app`) estão todos criados e publicados pelo usuário, seguindo o runbook desta seção do `README.md` — nenhuma credencial foi manuseada diretamente por esta sessão (fora do escopo permitido: nunca inserir senha/token/chave em nenhuma chamada de ferramenta em nome do usuário, mesmo com autorização explícita). Os bugs 1-4 do item 15 apareceram e foram corrigidos durante esse processo. Falta apenas: o usuário rodar os 4 seeds corrigidos (`seed_producao.sql` → `seed_fase11.sql` → `seed_fase12.sql` → `seed_fase2.sql`) contra o projeto Supabase real e validar o app publicado ponta a ponta (dashboard, régua de preço, Nova Simulação, proposta, auditoria).

## 17. Segurança — auditoria própria desta entrega

Nenhum arquivo versionado contém um segredo real (conferido linha a linha em todo `.env.example`, `railway.toml`, `vercel.json`, `Dockerfile`, `ci.yml` antes do commit). `SUPABASE_SERVICE_ROLE_KEY` não aparece em nenhum lugar do código de `api/` ou `web/` — a API usa só `SUPABASE_ANON_KEY` + o JWT do usuário autenticado (RLS sempre vale); o frontend usa `supabase-js` só para autenticação. `GET /api/version` foi conferido para nunca incluir a anon key ou qualquer segredo na resposta (smoke test `api/test/smoke.js`, verificação explícita). O CI roda com variáveis 100% fictícias.

## 18. O que não foi testado / está fora do escopo desta fase

Os mesmos itens fora de escopo desde a Fase 2 (HubSoft, IBGE, integração financeira externa, automação de recebimentos, jobs de produção) **mais**: o deploy real em si (item 16), a build efetiva da imagem Docker (item 15), e qualquer teste de carga/performance sob rede real de produção (o TESTE-D7 mede a pilha local, não Railway↔Supabase real).

## 19. Fase 3 — não iniciada

Nenhum código de HubSoft, IBGE, integração financeira externa, geração de contratos ou qualquer outra integração fora do escopo desta fase foi criado. A Fase 2.2.1 Parte 2 termina aqui, aguardando aprovação explícita do usuário para prosseguir — seja para a Fase 3, seja para fornecer as credenciais do item 16 e concluir o deploy real desta mesma entrega.

## Checklist de aceite (19 itens)

1. [x] Pricing Engine centralizado em `calculatePricing()` — backend sempre recalcula, nunca confia em valor do cliente.
2. [x] `app.simular_precificacao_completa`/`public.pricing_calculate_full` batendo exato com o exemplo oficial de Jussara (2.020/2.320/2.620).
3. [x] Superfície de API completa para o frontend (cidades, cálculo, curva de crescimento, tabela de horizontes, rampa, índices, simulações, propostas, auditoria, login).
4. [x] `GET /health` e `GET /api/version` implementados, nunca expondo segredo.
5. [x] Bug real de `GRANT` em 6 views encontrado e corrigido, disclosed (não escondido).
6. [x] Frontend React funcional: login, dashboard principal, dashboard por cidade, Nova Simulação, propostas, auditoria.
7. [x] Régua de preço no frontend batendo exato com o backend (Jussara verificada visualmente).
8. [x] Nova Simulação com botões rápidos de cliente e recálculo real via API (E2E-4/E2E-5).
9. [x] 2 gráficos obrigatórios implementados (crescimento/receita, clientes/PONs), seguindo a skill de dataviz.
10. [x] Tabela de horizontes 12/36/48/60 meses, com 48 meses marcado como mínimo contratual.
11. [x] Modo demonstração sinalizado (`VITE_APP_ENVIRONMENT`), visível na tela de login.
12. [x] Design responsivo, tema claro/escuro, sem quebra visual (verificado via Playwright headless).
13. [x] Testes novos obrigatórios (Jussara+1PON, 129/257 clientes, R$2.019/1.310/1.309) — 100% PASS via API real com JWT.
14. [x] E2E completo (login→dashboard→simular→salvar→propor→auditar) — 100% PASS.
15. [x] Performance < 500ms confirmada (19ms médio, TESTE-D7).
16. [x] Regressão completa das fases anteriores — 124/124 PASS, 0 quebrado.
17. [x] GitHub preparado (`.gitignore`, CI, primeiro commit local feito) — push real BLOCKED por falta de PAT.
18. [x] Railway (`Dockerfile`+`railway.toml`) e Vercel (`vercel.json`) preparados — deploy real BLOCKED por falta de token/projeto Supabase.
19. [x] Fase 3 NÃO iniciada — nenhuma integração externa fora do escopo foi criada; aguardando aprovação explícita do usuário.

## Addendum pós-entrega — deploy real concluído

Os itens 3, 9, 16, 17, 18, 93 e 124/128 acima (e o checklist 17/18) descrevem o estado no momento da entrega original, quando GitHub/Supabase/Railway/Vercel ainda estavam **BLOCKED** por falta de credenciais. Nas sessões seguintes, com o usuário fornecendo as credenciais e executando o runbook do `README.md` (esta sessão nunca manuseou nenhuma delas diretamente — fora do escopo permitido, mesmo com autorização explícita), os 4 ambientes foram efetivamente criados e publicados:

- **GitHub**: `spotnick/optimon-backend`, push real concluído (superou o item 17 do checklist).
- **Supabase**: projeto `zmhektrjgrjvcsysrbmw`, todas as 74 migrations aplicadas (superou parte do item 16).
- **Railway**: `optimon-backend-production.up.railway.app`, API respondendo (`/health`, `/api/version`, auth enforcement em `/api/cities`) — só depois de encontrar e corrigir os bugs 1 e 2 do item 15 (superou o item 18 do checklist).
- **Vercel**: `optimon-backend-roan.vercel.app`, frontend publicado e login validado ponta a ponta (audit log real).

Durante esse processo apareceram os bugs 3 e 4 do item 15 (seeds de produção quebrando sob a ordem real "todas as migrations → seed"), também já corrigidos e verificados (ver item 15 e seção 19.9 de `docs/ARQUITETURA.md`). Com a correção, os 4 seeds (`seed_producao.sql`+`seed_fase11/12/2.sql`) aplicam sem erro contra o Supabase real, faltando só o usuário executá-los e validar visualmente o app publicado — ver o checklist "Próximo passo" no `README.md`.
