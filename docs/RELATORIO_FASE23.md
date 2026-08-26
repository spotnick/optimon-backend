# Relatório Final — Fase 2.3 (Módulo de Gestão de Cidades e Infraestrutura)

Status geral: **CONCLUÍDA no código, nos testes e na documentação — 54/54 verificações novas PASS, 0 FAIL, mais 11/11 no E2E Playwright obrigatório, mais regressão completa 196/196 PASS de todas as fases anteriores (0 quebrado)**. O único item do checklist de aceite (seção 41 do Prompt Mestre) ainda em aberto é o **deploy real desta entrega** — os 4 ambientes (GitHub/Supabase/Railway/Vercel) já existem e já estão publicados desde a Fase 2.2.1 Parte 2, mas as 4 migrations e o código novos desta fase ainda não foram enviados a eles, porque isso exige credenciais que esta sessão nunca manuseia (nem com autorização explícita do usuário — ver seção 8 abaixo). A Fase 3 **não foi iniciada** (item 21 do checklist).

Este relatório segue o mesmo formato PASS/FAIL/PENDENTE usado nos relatórios das fases anteriores — nenhum resultado é omitido ou suavizado, incluindo os 2 bugs reais encontrados durante a própria validação (item 6) e o item de deploy ainda pendente (item 8).

## 1. Arquivos alterados ou criados

- `supabase/migrations/20260901090000..090300_phase_2_3_*.sql` — 4 migrations novas.
- `api/routes/infra.js` — novo (POP/segmento/cabo/fibra/poste/porta PON).
- `api/routes/cities.js` — reescrito (POST/PATCH/archive + mapeamento de erro RBAC/RLS para HTTP).
- `api/server.js` — monta `/api/infra`.
- `web/src/lib/api.js` — métodos `cities.create/update/archive` e `infra.*`.
- `web/src/pages/Cities.jsx`, `NewCity.jsx`, `EditCity.jsx` — novos.
- `web/src/App.jsx`, `web/src/components/Layout.jsx`, `web/src/pages/Dashboard.jsx`, `web/src/pages/NewSimulation.jsx`, `web/src/pages/CityDetail.jsx` — editados para remover o tratamento especial de Jussara e ligar as rotas/telas novas.
- `tests/run_tests_fase23.sh` — novo (54 verificações + regressão completa via `run_tests_deploy.sh` original).
- `tests/e2e_fase23.js` — novo (E2E Playwright obrigatório da seção 40, 11 verificações).
- `README.md`, `docs/ARQUITETURA.md` (seção 20), `docs/RELATORIO_FASE23.md` (este arquivo).

Nenhuma migration de fase anterior (`2026082[4-9]*`, `20260830*`, `20260831*`) foi editada — só leitura. Nenhuma tabela recriada, nenhum dado existente apagado.

## 2. Migrations (4 novas, todas aditivas)

| # | Arquivo | O que faz |
|---|---|---|
| 1 | `090000_..._01_cidades_status_e_crud.sql` | Coluna `status` em `cidades_infra`; `app.criar_cidade`/`atualizar_cidade`/`arquivar_cidade` (bloqueio só por contrato `ATIVO`); wrappers `public.pricing_city_create`/`pricing_city_update`/`pricing_city_archive`. |
| 2 | `090100_..._02_infra_auditoria_gap_e_cabo_wrapper.sql` | Triggers de auditoria que faltavam em `infra_segmentos`/`infra_cabos`/`infra_postes` (lacuna aberta desde a Fase 1/1.1 — ver `docs/ARQUITETURA.md`, seção 20.4); `app.criar_cabo_com_fibras` (transação atômica) + wrapper `public.pricing_cable_create_with_fibers`. |
| 3 | `090200_..._03_cities_list_detail_enriquecido.sql` | `pricing_cities_list()` (com `DROP FUNCTION` antes — muda o tipo de retorno) e `pricing_city_detail()` enriquecidas: status, FOs totais/ociosas, portas PON, array de POPs completo. |
| 4 | `090300_..._04_infra_tree.sql` | `pricing_city_infra_tree(uuid)` — visão consolidada POP→segmento→cabo→fibra+postes num único JSON. |

## 3. Regra fundamental (seção 3/42) — Jussara sem nenhum código especial

Confirmado por teste automatizado, não só por inspeção manual: `grep -rn "jussara" web/src/` (case-insensitive) devolve zero ocorrências (SEC3), e a rota fixa `/cidades/jussara` não existe mais em `App.jsx` (SEC5). O menu não tem mais o item fixo "Jussara — PR" (E2E-3). Jussara continua sendo o primeiro registro real do banco — nada na Fase 2.3 apaga ou recria seus dados — mas é tratada por todo o código exatamente como qualquer outra cidade: mesma rota, mesmo componente, mesma API.

## 4. CRUD de cidades e infraestrutura (seções 6-21)

Cidades: criar (`POST /api/cities`), editar (`PATCH /api/cities/:id`), arquivar (`POST /api/cities/:id/archive`, soft delete via `removido_em`, nunca `DELETE` físico), listar com busca (`Cities.jsx`). Infraestrutura, tudo por cidade e sem limite de quantidade por cidade (testado explicitamente com 2 POPs numa mesma cidade — TESTE-C3b): POP (`POST`/`PATCH /api/infra/pops`), segmento (`POST /api/infra/segments`), cabo com fibras geradas automaticamente na mesma transação (`POST /api/infra/cables`, seção 20.2 de `docs/ARQUITETURA.md`), fibra individual com os 6 status da seção 17 (`PATCH /api/infra/fibers/:id`), poste (`POST /api/infra/poles`), porta PON com capacidade padrão de 128 aplicada por trigger — parametrizada, não hard-coded (`POST`/`PATCH /api/infra/pon-ports`). Visão consolidada por cidade via `GET /api/cities/:id` (enriquecida) e `GET /api/infra/tree?cidade_id=...` (a árvore completa).

## 5. RBAC e RLS (seções 9, 30)

Reaproveita `app.tem_perfil()` e a RLS por perfil já existentes desde a Fase 1 — nenhuma tabela de infraestrutura nova precisou de uma política nova, todas herdam a mesma disciplina. Verificado por API real com JWT de cada perfil (TESTE-P1..P9): COMERCIAL visualiza mas não cria/edita cidade nem cria POP (403 em todos os 3 casos); ENGENHARIA cria e edita cidade; ADMINISTRADOR cria; AUDITOR só visualiza, bloqueado ao tentar criar (403).

## 6. Bugs reais encontrados durante a própria validação (2, ambos corrigidos e disclosed)

**Bug 1 — `pricing_cities_list()` não aceitava `CREATE OR REPLACE` depois de ganhar colunas novas.** Mesma classe de erro já vista 2 vezes antes nesta arquitetura (Fase 2.2 e Fase 2.2.1): o Postgres recusa `CREATE OR REPLACE FUNCTION` quando o retorno de uma função `returns table(...)` muda de tipo composto (`ERROR: cannot change return type of existing function`). Corrigido com `DROP FUNCTION IF EXISTS public.pricing_cities_list();` antes do `CREATE FUNCTION`, na mesma migration.

**Bug 2 — E2E-9 (Nova Simulação calcula Pricing para a cidade nova) falhava de forma intermitente.** Não era um bug de cálculo — as 3 chamadas concorrentes de `runSimulation()` (`POST /api/pricing/calculate`, `/growth-curve`, `/horizon-table`) sempre respondiam `200`, confirmado lendo os logs de rede do próprio Playwright. O teste usava `page.waitForTimeout(2000)` fixo antes de checar se a régua de preço apareceu na tela, mas a régua só renderiza depois que as 3 chamadas resolvem — e 2 segundos é uma corrida contra um Chromium headless "frio", nem sempre suficiente. Corrigido trocando o sleep fixo por `page.waitForSelector('.regua', { timeout: 20000 })`, que espera o elemento de verdade aparecer em vez de um tempo arbitrário — sem alterar nenhum código de produção, só o teste.

## 7. Bateria de testes (seções 26-33, 38, 40) — 54/54 + 11/11, regressão completa 196/196

`tests/run_tests_fase23.sh`: PASSO-0 reexecuta `tests/run_tests_deploy.sh` **original, sem editar** (que por sua vez reexecuta toda a cadeia Fase 1→1.1→1.2→2→2.1→2.2→2.2.1, 142 verificações) e só depois aplica as 4 migrations novas — nenhuma regressão escondida em nenhum nível da cadeia. Testes próprios desta fase:

- **SEC3/SEC5** (regra fundamental): ausência de "jussara" hard-coded, rota fixa removida.
- **TESTE-C1..C9** (seção 26): cidade nova (TESTE) criada do zero por API — 2 POPs, 1 segmento, 1 cabo de 24 FO com as 24 fibras geradas automaticamente, postes, 1 porta PON com capacidade padrão 128, e o Pricing Engine calculando de verdade para essa cidade.
- **TESTE-A1..A3** (seção 27): segunda cidade (Andirá) criada sem alterar Jussara.
- **TESTE-E1..E3, TESTE-I1/I2** (seções 28-29): edição de Andirá (10km→12km) refletida no Dashboard e no detalhe; isolamento de Jussara (km_rede, postes, FO totais, FO ociosas) comparado contra um baseline capturado dinamicamente no início do script — necessário porque cada fase anterior já deixou fixtures próprios sobre a mesma Jussara, então um número fixo não seria confiável.
- **TESTE-P1..P9** (seção 30): RBAC por rota nos 4 perfis (ver item 5 acima).
- **AUD-1..AUD-16** (seção 38): usuário/data/hora/ação/dados anteriores/dados novos confirmados para criação **e** alteração de cidade, POP, cabo, fibra, poste e porta PON — 6 casos de INSERT, 4 de UPDATE via API real (cidade/POP/fibra/PON) e 2 de UPDATE via SQL direto (cabo/poste, que não têm endpoint de edição na especificação — seções 15/18 só pedem cadastro), provando que o trigger genérico `fn_auditoria()` cobre a tabela de qualquer forma que ela venha a ser alterada, não só pelas rotas que existem hoje. Nos 2 casos de SQL direto, `usuario_id` fica `NULL` corretamente (não há JWT de requisição associado), e o teste reflete isso explicitamente em vez de exigir um usuário que genuinamente não existe nesse caminho.
- **TESTE-AR1..AR5** (seções 31-32): arquivamento sem contrato ativo funciona (soft delete, cidade some da listagem padrão, preservada no banco); arquivar Jussara (contrato `ATIVO`) é bloqueado com a mensagem exata do prompt; Jussara permanece ativa depois da tentativa bloqueada.

`tests/e2e_fase23.js` (Playwright real contra o frontend Vite/React, autenticando por injeção de sessão em `localStorage` — mesmo padrão da Fase 2.2.1 Parte 2, já que não existe GoTrue real neste ambiente de desenvolvimento): **11/11 PASS** — login → Dashboard → menu "Cidades & Infraestrutura" (sem item fixo de Jussara) → Nova Cidade (Andirá) → salvar → criar POP → criar segmento+cabo (fibras geradas automaticamente) → voltar ao detalhe da cidade (Régua de Preço genérica, não só de Jussara) → Nova Simulação → selecionar Andirá → simular → Dashboard confirmando as duas cidades lado a lado, sem tratamento especial para nenhuma.

## 8. Estado do deploy real — único item pendente

GitHub (`spotnick/optimon-backend`), Supabase (projeto `zmhektrjgrjvcsysrbmw`), Railway e Vercel já existem e já estão publicados desde a Fase 2.2.1 Parte 2 (ver `docs/RELATORIO_FASE221_PARTE2.md`, addendum). O que falta é só o incremento desta fase chegar até eles: aplicar as 4 migrations novas no Supabase real e publicar o código novo (`api/routes/infra.js`, `api/routes/cities.js`, as 3 telas novas do frontend) no Railway/Vercel. Nenhuma credencial foi manuseada por esta sessão para isso — mesma linha de sempre, que não é atravessada nem com autorização explícita do usuário. Runbook incremental completo (passo a passo, comandos prontos para copiar) em `README.md`, seção "Deploy real" → "Passo a passo da Fase 2.3 (incremental)".

## 9. Segurança — auditoria própria desta entrega

Nenhum arquivo versionado contém segredo real (conferido linha a linha nas 4 migrations, em `api/routes/infra.js`/`cities.js` e nos componentes novos do frontend antes do commit). Nenhuma rota nova em `infra.js`/`cities.js` usa a service role — todas passam por `clientForRequest(req.userJwt)`, a mesma disciplina desde a Fase 2.2.1 Parte 2. O backend nunca confia em valor vindo do frontend: toda tela que mostra um preço continua chamando `POST /api/pricing/calculate`, que recalcula a partir da cidade selecionada e dos parâmetros de entrada.

## 10. O que não foi testado / está fora do escopo desta fase

Os mesmos itens fora de escopo desde a Fase 2 (HubSoft, IBGE, integração financeira externa, automação de recebimentos, jobs de produção) **mais**: o deploy real em si (item 8), e qualquer teste de carga/performance sob rede real de produção.

## 11. Fase 3 — não iniciada

Nenhum código de HubSoft, IBGE, integração financeira externa, geração de contratos ou qualquer outra integração fora do escopo desta fase foi criado. A Fase 2.3 termina aqui, aguardando: (a) o usuário concluir o deploy real (item 8) e (b) aprovação explícita do usuário para prosseguir para a Fase 3 — nenhuma das duas coisas acontece automaticamente, por instrução direta das seções 41/42 do Prompt Mestre desta fase.

## Checklist de aceite (22 itens, seção 41 do Prompt Mestre)

1. [x] Jussara não estiver hard-coded — confirmado por teste automatizado (SEC3/SEC5, item 3).
2. [x] Cidades possuir CRUD funcional — criar/editar/arquivar via API real (item 4).
3. [x] Nova cidade funcionar — TESTE-C1/TESTE-A1 e E2E-5.
4. [x] Editar cidade funcionar — TESTE-E1..E3.
5. [x] Arquivar cidade funcionar — TESTE-AR1..AR5.
6. [x] POP funcionar — TESTE-C3/C3b, E2E-6.
7. [x] Cabo funcionar — TESTE-C5, E2E-7.
8. [x] Fibra funcionar — TESTE-C6, AUD-11/12 (alteração de status).
9. [x] Postes funcionar — TESTE-C7.
10. [x] PON funcionar — TESTE-C8/C8b.
11. [x] Pricing usar cidade selecionada — TESTE-C9, E2E-9 (Andirá, não Jussara).
12. [x] Dashboard mostrar todas as cidades — TESTE-A2, E2E-10.
13. [x] Nova Simulação mostrar todas as cidades — E2E-9 (seletor genérico).
14. [x] RBAC funcionar — TESTE-P1..P9.
15. [x] RLS funcionar — TESTE-P9 (bloqueio de POP por COMERCIAL via RLS de `infra_pops`) + toda a regressão herdada.
16. [x] Auditoria funcionar — AUD-1..AUD-16 (item 6 acima).
17. [x] Jussara permanecer íntegra — TESTE-A3, TESTE-I1/I2, TESTE-AR4/AR5.
18. [x] Andirá poder ser criada — TESTE-A1, E2E-5.
19. [x] Multi-cidade funcionar — TESTE-A2 (Jussara+Andirá+TESTE juntas), E2E-10/11.
20. [x] Multi-POP funcionar — TESTE-C3b (2 POPs na mesma cidade).
21. [ ] Deploy funcionar — **PENDENTE**: os 4 ambientes já existem e já estão publicados (Fase 2.2.1 Parte 2), mas o incremento desta fase (4 migrations + código novo) ainda não foi enviado a eles (item 8 acima). Runbook pronto em `README.md`.
22. [x] Teste E2E passar — `tests/e2e_fase23.js`, 11/11 PASS.

**21 de 22 itens PASS.** Por instrução explícita da seção 41 ("NÃO iniciar nova fase até todos os itens acima estarem PASS"), a Fase 3 não deve começar até o item 21 também estar PASS — o que depende só do usuário executar o runbook da seção 8/`README.md`, sem nenhuma mudança de código pendente da parte desta sessão.
