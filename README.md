# OptiMon — Optical Asset & Pricing Management

Entrega da **Fase 1** (Banco + Auth + Infraestrutura + Parceiros + Contratos) + **Fase 1.1** (porta PON como unidade comercial real, POPs, aditivos, metas, exclusividade escopada) + **Fase 1.2** (hardening comercial: SOMA como modelo híbrido padrão, capacidade contratada×reservada×ativa, conflito compartilhamento×exclusividade, relação cliente→porta PON, preparação de pricing) + **Fase 2** (Pricing Engine completo: custos classificados, Dark Fiber mínimo/recomendado/premium, Revenue Share/SOMA/MAX, rampa, reajuste, projeção financeira, ROI, payback, economia do parceiro, governança de preço, override, auditoria, API source-only e dashboard comercial) + **Fase 2.1** (correções de consistência comercial: fibra individual como unidade padrão do Dark Fiber, motor de preço real do Cenário 2/Porta PON, rampa respeitando `rampa_aplica_a` por componente, viabilidade em 4 níveis, capacidade Multi-POP por contrato, 2 lacunas de auditoria fechadas) + **Fase 2.2** (Infrastructure Floor / Piso de Infraestrutura: política comercial de monetização mínima da infraestrutura óptica — postes + metros de rede —, nunca custo real; régua comercial de 3 níveis Abertura/Recomendado/Piso com governança e desconto; composição explícita Floor×Mínimo Contratual sem somar por acidente; indicadores por fibra ociosa/Porta PON; break-even e escala de portas; parametrização com override por cidade e versionamento) + **Fase 2.2.1** (ajuste final de governança + precificação por Porta PON: Porta PON como componente direto do Floor — não só indicador —, novos preços oficiais (poste R$8,00, PON piso/recomendado/abertura R$200/250/300), governança de 5 estados ciente do papel de quem decide, piso absoluto de 50% de desconto de override enforçado até na trigger, versionamento real de parâmetros — não mais cosmético —, MAX redefinido como MAX(Floor,Revenue Share), auditoria detalhada do override com cidade/POP/desconto), conforme o Prompt Mestre de Desenvolvimento do OptiMon.

Banco de dados + arquitetura + API + dashboard comercial interativo, com uma **Fase 2.2.1 (Parte 2)**: "AJUSTE FINAL DO PRICING ENGINE + RÉGUA DE PREÇO + PRIMEIRA VERSÃO VISUAL FUNCIONAL + DEPLOYMENT DOS AMBIENTES" — o Pricing Engine centralizado no backend (`calculatePricing()`, nunca confia em valor vindo do cliente), uma superfície de API completa para o frontend, um frontend React funcional de ponta a ponta (login, dashboard, régua de preço, Nova Simulação, propostas, auditoria) e os 3 ambientes de deploy — GitHub, Railway (API) e Vercel (frontend), sobre um projeto Supabase (banco), já publicados de verdade (ver "Deploy real" abaixo). E agora com a **Fase 2.3**: "MÓDULO DE GESTÃO DE CIDADES E INFRAESTRUTURA" — o OptiMon deixa de ser um projeto de demonstração de uma única cidade (Jussara-PR hard-coded em rota/menu/componente) e passa a ser tratado como produto multi-cidade de verdade: CRUD completo de cidades (criar/editar/arquivar, nunca DELETE físico), CRUD de POP/segmento/cabo (com geração automática das fibras)/poste/porta PON, uma visão consolidada por cidade, RBAC/RLS por rota reaproveitando o mesmo `app.tem_perfil()` de sempre, e auditoria automática (via os mesmos triggers genéricos `fn_auditoria()`) cobrindo as 7 tabelas de infraestrutura. Jussara continua sendo o primeiro registro real do banco (e a baseline de regressão — nunca alterada por acidente), mas nenhum código a trata como especial. Ver `docs/RELATORIO_FASE23.md` para o relatório final e o checklist de aceite (22 itens) desta fase — inclusive o único item ainda pendente (deploy real desta entrega, ver "Deploy real" abaixo). A Fase 2.3 não avança automaticamente para a Fase 3 — a próxima etapa será definida pelo usuário (ver `docs/ARQUITETURA.md`, seção 12).

## O que tem aqui

```
docs/
  ARQUITETURA.md          # plano técnico completo: stack, RBAC, modelo de dados, Fase 1.1/1.2/2/2.1/2.2/2.2.1(P2)/2.3, fases
supabase/
  migrations/              # 78 migrations SQL (20 Fase 1 + 14 Fase 1.1 + 7 Fase 1.2 + 10 Fase 2 + 4 Fase 2.1 + 4 Fase 2.2
                             #   + 6 Fase 2.2.1 + 9 Fase 2.2.1 Parte 2/Deploy + 4 Fase 2.3), aplicar em sequência
  seed.sql                  # dados do primeiro caso real: Jussara-PR (Fase 1) — só para o shim local, insere em auth.users
  seed_producao.sql          # mesmo seed acima, mas localiza um usuário ADMINISTRADOR já criado via Supabase Auth
                               #   em vez de inserir em auth.users — use este contra um Supabase real
  seed_fase11.sql            # seed complementar da Fase 1.1: 2º POP, portas PON, aditivo, exclusividade escopada
  seed_fase12.sql             # seed complementar da Fase 1.2: 2ª porta do Parceiro B, contrato dark fiber com
                               #   modelo SOMA por default, clientes reais em cliente_porta_pon
  seed_fase2.sql               # seed complementar da Fase 2: custos reais de Jussara classificados
                               #   (postes/link/manutenção/Prefeitura) + contratos 0005 (Dark Fiber) e 0006 (Porta PON)
                               #   — reusado pelas Fases 2.1/2.2/2.2.1/2.2.1(P2) sem seed própria
  dev-local-only/            # NUNCA copiar para um projeto Supabase real — só para testar fora do Supabase
    shim_supabase_auth.sql  # simula auth.users/auth.uid()/authenticated/anon do Supabase p/ testar em Postgres puro
    postgrest.local.conf    # config do PostgREST local (Fase 2.2.1 P2 — simula a camada REST de um Supabase real)
    mint_jwt.js              # gera JWTs HS256 de teste (COMERCIAL/DIRETOR/etc.) sem depender do GoTrue
    rest_v1_proxy.js          # remove o prefixo /rest/v1 que supabase-js sempre adiciona, para falar com PostgREST puro
api/
  server.js, routes/, lib/, middleware/, Dockerfile, .dockerignore   # API REST do Pricing Engine — publicada no Railway
  routes/cities.js          # CRUD de cidades (criar/editar/arquivar) — Fase 2.3
  routes/infra.js            # CRUD de POP/segmento/cabo/fibra/poste/porta PON — Fase 2.3
web/
  src/pages/, src/components/, src/lib/, src/context/   # frontend React (Vite) — publicado no Vercel
  src/pages/Cities.jsx, NewCity.jsx, EditCity.jsx   # tela "Cidades & Infraestrutura" — Fase 2.3 (genérica p/ qualquer cidade)
  vercel.json              # rotas SPA + headers de segurança para o deploy no Vercel
dashboard/
  optimon-pricing-dashboard.html   # dashboard comercial interativo (seções 36-41, 58-59), self-contained
tests/
  run_tests_fase11.sh       # bateria de testes da Fase 1.1 (57 verificações + regressão Fase 1)
  run_tests_fase12.sh       # bateria de testes da Fase 1.2 (seção 29: testes 1–20 + regressão completa Fase 1/1.1)
  run_tests_fase2.sh        # bateria de testes da Fase 2 (seção 55: testes 1–26 + regressão completa Fase 1/1.1/1.2)
  run_tests_fase21.sh       # bateria de testes da Fase 2.1 (regressão Fase 1/1.1/1.2/2 + testes novos das correções)
  run_tests_fase22.sh       # bateria de testes da Fase 2.2 (TESTE-1..22 + ARPU + regressão completa Fase 1/1.1/1.2/2/2.1)
  run_tests_fase221.sh      # bateria de testes da Fase 2.2.1 (TESTE-30..41 + prova de versionamento real + regressão
                             #   completa Fase 1/1.1/1.2/2/2.1/2.2 — reexecuta run_tests_fase22.sh original, sem editar)
  run_tests_deploy.sh       # bateria de testes da Fase 2.2.1 Parte 2 (PASSO-0/1 + TESTE-D1..D7 + E2E-1..8, 18/18) —
                             #   sobe PostgREST local + a API real e testa por HTTP com JWT, não só via psql
  run_tests_fase23.sh       # bateria de testes da Fase 2.3 (seções 26-33/38, 54/54) — reexecuta run_tests_deploy.sh
                             #   original, sem editar, e por cima aplica as 4 migrations novas desta fase
  e2e_fase23.js              # E2E Playwright obrigatório da seção 40 (11/11) — login→Nova Cidade→POP→cabo→
                             #   Nova Simulação→Pricing→Dashboard, contra o frontend React real, não simulado
railway.toml                # configuração do serviço Railway (aponta para api/Dockerfile)
.github/workflows/ci.yml    # CI: lint+test da API e lint+build do frontend a cada push/PR (sem segredos reais)
.env.example                 # referência consolidada de todas as variáveis de ambiente (api/.env.example + web/.env.example)
```

As migrations da Fase 1 (prefixo `20260824...`), Fase 1.1 (`20260825...`), Fase 1.2 (`20260826...`), Fase 2 (`20260827...`), Fase 2.1 (`20260828...`), Fase 2.2 (`20260829...`) e Fase 2.2.1 (`20260830...`) **não foram alteradas** — a Fase 2.2.1 Parte 2 (deploy) é só migrations novas (prefixo `20260831...`) por cima: a superfície de API que faltava para o frontend (cidades, PONs a partir de clientes, salvar simulação/proposta, listar auditoria, registrar login), o `calculatePricing()` centralizado (`app.simular_precificacao_completa` / `public.pricing_calculate_full`), a curva de crescimento e a tabela de horizontes (12/36/48/60 meses), e uma correção real de `GRANT` em 6 views que nunca tinham sido testadas como o papel `authenticated` real (ver seção de testes abaixo). Nenhuma tabela existente foi recriada, nenhuma migration anterior foi tocada — só `CREATE OR REPLACE FUNCTION`/`GRANT`/`ALTER TABLE ... ADD CONSTRAINT` aditivos. A Fase 2.3 segue a mesma disciplina: 4 migrations novas (prefixo `20260901...`) — `status` em `cidades_infra` + wrappers de criar/editar/arquivar cidade, os triggers de auditoria que faltavam em `infra_segmentos`/`infra_cabos`/`infra_postes` + o wrapper transacional de criar cabo com as fibras já geradas juntas, `pricing_cities_list()`/`pricing_city_detail()` enriquecidas (precisaram de `DROP FUNCTION` antes do `CREATE OR REPLACE` porque mudam o tipo de retorno) e a nova `pricing_city_infra_tree()` — nenhuma tabela recriada, nenhuma migration de fase anterior tocada.

## Como aplicar num projeto Supabase real

1. Crie o projeto no Supabase (ou use um já existente).
2. Copie `supabase/migrations/*.sql` para dentro do seu projeto Supabase (`supabase/migrations/`) e rode `supabase db push`, ou aplique cada arquivo em ordem via `psql "$DATABASE_URL" -f supabase/migrations/XXXX.sql` — a ordem importa, os nomes já estão prefixados por timestamp.
3. **Não copie `dev-local-only/`** — o schema `auth` e os papéis `authenticated`/`anon` já existem de verdade no Supabase; o shim é só para testar fora do Supabase.
4. Se quiser os dados de exemplo (Jussara-PR — porta PON/POP/aditivo/pricing/custos/contratos Dark Fiber), primeiro crie um usuário real em Supabase → Authentication → Users ("Auto Confirm User" marcado), copie o UID gerado, e vincule ele a um perfil com `insert into public.usuarios (id, nome, email, perfil) values ('<UID>', 'Seu Nome', 'seu-email@exemplo.com', 'ADMINISTRADOR');`. Só então rode, em sequência, `supabase/seed_producao.sql`, `supabase/seed_fase11.sql`, `supabase/seed_fase12.sql` e `supabase/seed_fase2.sql`. **Não use `supabase/seed.sql`** contra um Supabase real — ele insere direto em `auth.users`, o que só funciona no shim de desenvolvimento local; `seed_producao.sql` é o mesmo seed da Fase 1, mas localizando o usuário ADMINISTRADOR que você já criou em vez de tentar criar um novo. A partir da Fase 2.1 (incluindo a 2.2, 2.2.1 e 2.2.1 Parte 2) nenhuma fase tem seed próprio — todas reaproveitam os mesmos dados do `seed_fase2.sql` (cidade Jussara, contratos 0005/0006). A Fase 2.2.1 muda o parâmetro vigente do Infrastructure Floor (`app.criar_pricing_version`, Pricing Version "2026.08.1") — se você já tinha propostas registradas sob a versão anterior ("2026.08"), elas continuam recalculáveis com os valores antigos passando `p_pricing_version` explicitamente nas funções (nunca recalculadas por acidente).
5. A API em `api/` agora é publicada de verdade (Railway) — ver a seção "Deploy real" abaixo. Para rodar localmente: `cd api && npm install && cp .env.example .env` (preencha `SUPABASE_URL`/`SUPABASE_ANON_KEY`, nunca `service_role`) `&& npm start` (ou `npm test` para o smoke test, `npm run lint`).
6. O frontend em `web/` é a primeira versão visual funcional (React/Vite) — publicado no Vercel. Para rodar localmente: `cd web && npm install && cp .env.example .env` (preencha `VITE_API_URL`, `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`) `&& npm run dev`.
7. O dashboard em `dashboard/optimon-pricing-dashboard.html` (entrega anterior, mantido) é self-contained (HTML+CSS+JS, sem build) — abra direto no navegador; ele simula com uma cópia em JS das mesmas fórmulas do banco, não chama a API. O frontend novo em `web/` é o substituto oficial: chama a API de verdade, nunca recalcula preço no cliente.

## Como validar localmente (sem Supabase, só Postgres)

Usado para validar esta entrega antes de enviar — reproduz o cenário real (Fase 1, 1.1 e 1.2 já em produção com dados, Fase 2 aplicada por cima):

```bash
createdb optimon
psql -d optimon -f supabase/dev-local-only/shim_supabase_auth.sql
for f in supabase/migrations/20260824*.sql; do psql -d optimon -f "$f"; done   # Fase 1
psql -d optimon -f supabase/seed.sql                                          # dados reais da Fase 1
for f in supabase/migrations/20260825*.sql; do psql -d optimon -f "$f"; done   # Fase 1.1 por cima
psql -d optimon -f supabase/seed_fase11.sql
for f in supabase/migrations/20260826*.sql; do psql -d optimon -f "$f"; done   # Fase 1.2 por cima
psql -d optimon -f supabase/seed_fase12.sql
for f in supabase/migrations/20260827*.sql; do psql -d optimon -f "$f"; done   # Fase 2 por cima
psql -d optimon -f supabase/seed_fase2.sql
for f in supabase/migrations/20260828*.sql; do psql -d optimon -f "$f"; done   # Fase 2.1 por cima (sem seed própria)
for f in supabase/migrations/20260829*.sql; do psql -d optimon -f "$f"; done   # Fase 2.2 por cima (sem seed própria)
for f in supabase/migrations/20260830*.sql; do psql -d optimon -f "$f"; done   # Fase 2.2.1 por cima (sem seed própria)
for f in supabase/migrations/20260831*.sql; do psql -d optimon -f "$f"; done   # Fase 2.2.1 Parte 2/Deploy (sem seed própria)
```

Ou, mais simples, rodar a bateria de testes já pronta: `bash tests/run_tests_fase221.sh` (só SQL, via `psql`) — ela reconstrói o banco do zero (reexecutando `run_tests_fase22.sh` original, sem editar, como passo 1) e imprime o resultado teste a teste. Para validar a pilha inteira por HTTP (PostgREST local + API + JWT/RLS reais, exatamente como o frontend chama em produção), rodar `bash tests/run_tests_deploy.sh` — requer o PostgREST local (ver `supabase/dev-local-only/`) e o Node instalado; sobe tudo, testa, e derruba os processos ao final.

### Fase 1, Fase 1.1 e Fase 1.2 — validadas (recapitulado das entregas anteriores)

As 41 migrations aplicam sem erro sobre dados reais. RLS por perfil funciona de verdade. Prazo mínimo de 48 meses, medição imutável, `auditoria` imutável, `checkContractConflict()`, capacidade de porta PON (128), aditivos com versionamento automático, SOMA/MAX, cliente→porta PON — tudo continua funcionando após a Fase 2 (ver regressão abaixo).

### Fase 2 — bateria de testes rodada nesta entrega

**65 de 65 verificações passando** (script `tests/run_tests_fase2.sh`, incluído nesta entrega, reconstrói o banco do zero a cada execução: Fase 1 → seed → Fase 1.1 → seed → Fase 1.2 → seed → Fase 2 → seed): os 23 testes obrigatórios da seção 55 do prompt que produzem um resultado verificável neste ambiente (Jussara carregada e classificada, 1 porta PON/128 clientes, 129 clientes exige 2ª porta, SOMA=R$2.200/MAX=R$1.200 com os números literais do prompt, break-even R$8.333,33/~84 clientes, rampa 50%/75%/100%, reajuste anual preservando histórico, projeção 48 e 60 meses, ROI com CAPEX=0→N/A e com CAPEX real, payback no mês certo e "não recuperado" fora do horizonte, margem do parceiro e alerta de viabilidade, governança BLOCK/REQUIRES_APPROVAL/ALLOW, override nascendo PENDENTE→auditado→aprovado só por Diretor, múltiplos POPs, múltiplas portas, portas reservadas cobrando mínimo mesmo ociosas, capacidade contratada×ativa×disponível) **mais** a regressão completa da Fase 1 (6 checagens), Fase 1.1 (8 checagens) e Fase 1.2 (9 checagens), todas rodadas de novo sobre o banco já com a Fase 2 aplicada — nenhuma funcionalidade aprovada anteriormente quebrou.

A primeira rodada bruta encontrou 4 falhas reais — todas no script de teste, não no motor de cálculo (confirmado calculando os mesmos valores manualmente via `psql` direto antes de tocar no script): (1) o helper `val_of()` remove todos os espaços do resultado (`tr -d ' '`), o que é correto para número/uuid/enum mas corrompe um campo de texto livre como "Não recuperado no período" — criado um helper `text_of()` separado que só remove espaços nas pontas; (2)/(3)/(4) o teste de override (seção 48) chamava `app.pricing_override_create` mas essa função só existe como `public.pricing_override_create` (é a função exposta ao PostgREST, seção 50) — chamar o schema errado fazia a chamada falhar silenciosamente, e o `grep` que extraía o UUID do resultado pegava por engano o UUID devolvido por `set_config()` (usado internamente para simular o usuário logado) em vez do UUID da solicitação de override real, mascarando os dois passos seguintes (que pareciam "passar" só porque comparavam contra um id inexistente, então davam "0 linhas afetadas" e o script tratava isso como "bloqueado corretamente" por acidente). Corrigidos os dois problemas (schema certo + extrair o último UUID do resultado, não o primeiro) e reexecutada a bateria completa: 65/65 PASS, incluindo TESTE19c (Comercial não pode se autoaprovar) e TESTE19d (Diretor aprova) agora verificados contra o registro real, não um id fantasma. Detalhe teste a teste no relatório final que acompanha esta entrega.

O que **não** foi testado por não existir ainda (limitação consciente da seção 54, não pendência escondida): integração HubSoft, integração IBGE (reajuste é manual nesta fase), integração financeira externa, automação de recebimentos, jobs de produção, deploy real da API/dashboard.

### Fase 2.1 — bateria de testes rodada nesta entrega

**67 de 67 verificações passando** (script `tests/run_tests_fase21.sh`, reconstrói o banco do zero: Fase 1→seed→Fase 1.1→seed→Fase 1.2→seed→Fase 2→seed_fase2→**Fase 2.1** sem seed própria): a regressão completa da Fase 2 (23 testes obrigatórios da seção 55, renomeados REG-1..REG-23, todos com os mesmos valores literais da Fase 2 — nada mudou) mais a regressão da Fase 1 (REG-24), Fase 1.1 (REG-25) e Fase 1.2 (REG-26), **mais** os testes novos da Fase 2.1: fibra individual vs. par (NOVO-1/2), TESTE-R1/R2/R3 de rampa por componente exatamente como pedido na seção 4 (FIXO_MINIMO: mínimo=50%/share=100%; REVENUE_SHARE: mínimo=100%/share=50%; AMBOS: 50%/50%), o motor real de preço mínimo/recomendado/premium do Cenário 2 (NOVO-4, contrato 0006: R$1.000,00/R$1.200,00/R$1.800,00, antes sempre `null`), `pricing_quote` devolvendo esses valores (NOVO-5), break-even revalidado (NOVO-6: R$8.333,33/84 clientes), o teste econômico completo da seção 9 nos 7 pontos exatos pedidos — 10/25/50/75/84/100/128 clientes (NOVO-7), viabilidade em 4 níveis incluindo o novo `MARGEM BAIXA` (NOVO-8), Multi-POP 2+3+1=6 portas/768 capacidade (NOVO-9), as 2 lacunas de auditoria fechadas (NOVO-10), preservação do contrato 0005 sem migração forçada de método (NOVO-11), ausência de qualquer wording "par(es) de fibra" no dashboard (NOVO-12), rota de API nova (NOVO-13) e evidência de que nenhuma migration das Fases 1/1.1/1.2/2 foi tocada nesta sessão (NOVO-14, via mtime — este ambiente de validação não tem `git`).

A primeira rodada bruta encontrou 6 falhas — todas no script de teste (números de exemplo escritos errado à mão e um nome de coluna errado num `INSERT` de teste), não no motor: os valores "esperados" do teste econômico (seção 9) para 10/25/50/75 clientes tinham sido calculados errado por mim ao escrever o teste (a fórmula real, já provada correta em REG-5/REG-7/REG-8 desde a Fase 2, é `SOMA = mínimo + faturamento×revenue_share%`; os números certos são R$1.120,00/R$1.300,00/R$1.600,00/R$1.900,00, não os R$2.000,00 que eu tinha escrito) — corrigido comparando contra a fórmula já testada, não inventando um novo número; o teste do nível `EXCELENTE` de viabilidade (NOVO-8d) falhava porque `EXCELENCIA_ROI_MINIMO_PADRAO` nasceu sem seed desde a Fase 2 (disciplina da seção 65) e eu não tinha configurado o parâmetro temporariamente antes de testar esse ramo — corrigido inserindo-o só para esse teste, como já era feito para o limiar "confortável"; e o teste de auditoria de `pricing_faixas_escassez` (NOVO-10b) usava um nome de coluna que não existe na tabela real (`fator_multiplicador` em vez de `fator`) — corrigido para um `UPDATE` na coluna certa. Reexecutada a bateria completa após as correções: 67/67 PASS.

O que **não** foi testado por não existir ainda: os mesmos itens fora de escopo da Fase 2 (HubSoft, IBGE, integração financeira, jobs de produção, deploy real).

### Fase 2.2 — bateria de testes rodada nesta entrega

**100 de 100 verificações passando** (script `tests/run_tests_fase22.sh`, reconstrói o banco do zero: Fase 1→seed→Fase 1.1→seed→Fase 1.2→seed→Fase 2→seed_fase2→Fase 2.1→**Fase 2.2**, as duas últimas sem seed próprio): a regressão completa de Fase 1/1.1/1.2/2 (REG-1..REG-26, mesmos valores literais desde a Fase 2 — nada mudou) e de Fase 2.1 (NOVO-1..NOVO-14) **mais** os 22 testes obrigatórios da Fase 2.2 e o teste final de ARPU: TESTE-1 (fórmula do Infrastructure Floor batendo 100% com o exemplo oficial de Jussara — 165 postes + 5.000m → Piso R$2.150,00/Recomendado R$2.400,00/Abertura R$2.650,00), TESTE-2/3 (override de parâmetro por cidade e proteção de `pricing_version`), TESTE-4..8 (governança nos 5 preços de exemplo do prompt: ALLOW/ALLOW/ALLOW_WITH_DISCOUNT/ALLOW_WITH_DISCOUNT/BLOCK), TESTE-9 (os 6 rótulos da régua), TESTE-10 (desconto comercial absoluto/percentual), TESTE-11/20 (os 5 modos de composição Floor×Mínimo, nunca somando por acidente), TESTE-12 (proteção `enforced` sobe o total até o piso quando necessário, e respeita opt-out explícito), TESTE-13 (Multi-POP nunca duplica metros mesmo com dado por POP preenchido), TESTE-14..17 (fibras ociosas/ocupadas e Portas PON disponíveis do exemplo oficial — 10 LIVRE/2 BLOQUEADA — e os indicadores por fibra/por Porta PON), TESTE-18 (break-even R$17.916,67/180 clientes), TESTE-19 (escala de Portas PON para meta de clientes), TESTE-21 (auditoria de `cidades_infra`, lacuna fechada), TESTE-22 (override com régua completa registrada, sem quebrar a chamada antiga de 5 argumentos) e o teste de ARPU (os 7 pontos de clientes — 10/25/50/75/84/100/128 — com Infrastructure Floor sobre o contrato 0006).

A primeira rodada bruta encontrou 1 falha real — não no script de teste, no próprio motor: a extensão de `public.pricing_override_create()` com 2 parâmetros novos opcionais (seção 40) foi feita via `CREATE OR REPLACE`, mas o Postgres só substitui uma função com a mesma assinatura — acrescentar parâmetros criou uma segunda função sobrecarregada, e qualquer chamada com exatamente 5 argumentos posicionais (o padrão usado desde a Fase 2) passou a ser ambígua entre as duas (`ERROR: function ... is not unique`), quebrando a própria compatibilidade retroativa que a seção 40 pedia para preservar. Corrigido com um `DROP FUNCTION IF EXISTS` da assinatura antiga de 5 parâmetros antes do `CREATE OR REPLACE` de 7, na mesma migration — resultado: uma única função, sem ambiguidade, aceitando 5, 6 ou 7 argumentos. Reexecutada a bateria completa após a correção: 100/100 PASS. Detalhe teste a teste no `docs/RELATORIO_FASE22.md` que acompanha esta entrega.

O que **não** foi testado por não existir ainda: os mesmos itens fora de escopo da Fase 2 (HubSoft, IBGE, integração financeira, jobs de produção, deploy real).

### Fase 2.2.1 — bateria de testes rodada nesta entrega

**124 de 124 verificações passando** (script `tests/run_tests_fase221.sh`): a estratégia de regressão desta fase é diferente das anteriores, de propósito — a Fase 2.2.1 muda parâmetros globais vigentes (poste R$10→R$8, +componente PON), então qualquer cálculo que resolva a versão vigente (sem fixar `pricing_version`) legitimamente muda de valor depois desta fase, não é regressão quebrada. O script roda em 4 passos: **Passo A** — reexecuta `tests/run_tests_fase22.sh`, o arquivo **original, sem nenhuma edição**, antes de aplicar as migrations desta fase: **100/100 PASS**, prova de que nada antes da Fase 2.2.1 quebrou. **Passo B** — aplica as 6 migrations novas (prefixo `20260830`) sobre esse mesmo banco. **Passo C** — prova real de versionamento histórico (seção 29): os mesmos cálculos do antigo TESTE-20/TESTE-ARPU, agora fixados explicitamente em `pricing_version='2026.08'`, reproduzem **exatamente** os totais antigos da Fase 2.2 (R$2.150,00/2.200,00/3.350,00/4.350,00 e os 7 pontos do teste de ARPU) mesmo com o parâmetro vigente já mudado — e os mesmos cálculos sem fixar versão mostram os valores novos, documentados, nunca escondidos (4 checagens: C1-C4). **Passo D** — bateria própria (TESTE-30 a TESTE-41): Jussara com 1 PON batendo exato com o exemplo oficial (Piso R$2.020,00/Recomendado R$2.320,00/Abertura R$2.620,00), escala de 1-6 PONs, capacidade RESERVADA contando como contratada (não só ATIVA), governança de 5 estados em 6 pontos de preço para COMERCIAL e DIRETOR, piso absoluto de 50% de desconto de override enforçado até para DIRETOR (bloqueado na trigger, não só advisory), permissão por papel para decidir (Comercial nunca, Financeiro só com permissão explícita, Diretor/Administrador sempre), Revenue Share nunca fundido ao Floor, MAX = literal MAX(Floor,RevenueShare) em 2 cenários, SUM com a fórmula inalterada, Multi-POP com PON nunca duplicando infraestrutura, 2 Pricing Versions coexistindo de verdade, e auditoria detalhada do override (cidade/POP/desconto) com "nunca apagar" reverificado.

Duas correções reais encontradas durante a própria validação (nunca escondidas — ver seção 18.9 de `docs/ARQUITETURA.md` para o detalhe completo): (1) `app.calculate_infrastructure_floor()` lançava exceção ao resolver uma `pricing_version` anterior à existência de PON (os 3 parâmetros de preço de PON não existiam sob o rótulo antigo) — corrigido com um `p_default` opcional em `app.get_infra_floor_param()`, devolvendo 0 (o valor correto: aquela época não tinha componente PON) em vez de quebrar a consulta; (2) a primeira tentativa de corrigir isso reintroduziu, momentaneamente, o mesmo bug de sobrecarga de função já visto na Fase 2.2 — `CREATE OR REPLACE` com um parâmetro novo criou uma segunda função ambígua — corrigido com `DROP FUNCTION IF EXISTS` antes do `CREATE OR REPLACE`, dentro da mesma migration que o causou. Detalhe teste a teste no `docs/RELATORIO_FASE221.md` que acompanha esta entrega.

O que **não** foi testado por não existir ainda: os mesmos itens fora de escopo das fases anteriores (HubSoft, IBGE, integração financeira, jobs de produção, deploy real).

### Fase 2.2.1 Parte 2 (Deploy + Pricing Engine centralizado + Frontend) — bateria de testes rodada nesta entrega

**18 de 18 verificações passando** (script `tests/run_tests_deploy.sh`, testa por HTTP contra um PostgREST local + a API Node/Express real — não só via `psql` como as baterias anteriores, para provar RLS/JWT/CORS/rotas de ponta a ponta exatamente como o frontend React chama em produção): **PASSO-0** reaplica `tests/run_tests_fase221.sh` original (sem editar) e por cima as 9 migrations novas desta fase, sem erro; **PASSO-1** confirma a API local no ar (`GET /health`); **TESTE-D1** recalcula Jussara com 1 Porta PON via `POST /api/pricing/calculate` e confere que bate exatamente com o exemplo oficial (Piso R$2.020,00/Recomendado R$2.320,00/Abertura R$2.620,00 — os mesmos valores da Fase 2.2.1, agora vindos do endpoint centralizado, não recalculados no frontend); **TESTE-D2/D3** confirmam a escala de Portas PON a partir do número de clientes (129 clientes → 2 PONs, 257 clientes → 3 PONs) via API; **TESTE-D4/D5/D6** confirmam as 3 fronteiras de governança do prompt nos preços de exemplo (R$2.019,00, R$1.310,00, R$1.309,00), chamando a API com um JWT real de COMERCIAL e de DIRETOR — inclusive o piso absoluto de 50% de desconto bloqueando até o DIRETOR em R$1.309,00 (abaixo do piso); **TESTE-D7** mede a performance real de `POST /api/pricing/calculate` (5 chamadas consecutivas via HTTP, não em memória) e confirma média abaixo de 500ms; **E2E-1..E2E-8** simulam o fluxo comercial completo de ponta a ponta como o frontend faz — login (LOGIN registrado em auditoria), dashboard principal (lista Jussara), dashboard Jussara (traz os POPs), Nova Simulação com 100 clientes, alterar para 200 clientes e recalcular (confirma 2 PONs), salvar a simulação, gerar a proposta, e conferir que a auditoria mostra os 3 eventos (LOGIN + simulação + proposta) do fluxo — prova que nada nesse caminho é decidido no frontend, tudo é uma chamada real ao backend que por sua vez chama o SQL.

Duas correções reais encontradas durante a própria validação, ambas disclosed (nunca escondidas): (1) 6 views (`vw_capacidade_cidade`, `vw_capacidade_contrato`, `vw_capacidade_parceiro`, `vw_capacidade_pop`, `vw_contrato_capacidade`, `vw_porta_pon_detalhe`) nunca tinham recebido `GRANT SELECT` para o papel `authenticated` — um bug latente desde a Fase 1/2 que só apareceu agora porque, pela primeira vez, os testes rodam como o papel `authenticated` de verdade via PostgREST+JWT, e não como o superusuário do Postgres (que ignora GRANT); corrigido com uma migration aditiva de `GRANT`. (2) o enum `simulacoes.modelo` só aceita `DARK_FIBER`/`HIBRIDO_REVENUE_SHARE` — um teste inicial usava `'REVENUE_SHARE'`, valor que nunca existiu; corrigido usando o valor real do enum. Nenhuma das duas exigiu recriar tabela, apagar migration ou tocar em dado existente.

O que **não** foi testado por não existir ainda: HubSoft, IBGE, integração financeira, jobs de produção (os mesmos itens fora de escopo desde a Fase 2) — e o **deploy real em si** (Railway/Vercel/Supabase de produção), que depende de credenciais que só o usuário pode fornecer (ver seção "Deploy real" abaixo). A build da imagem Docker (`api/Dockerfile`) não pôde ser testada localmente porque este ambiente de desenvolvimento não tem um daemon Docker privilegiado disponível — ficará validada na primeira build real do Railway.

### Fase 2.3 (Módulo de Gestão de Cidades e Infraestrutura) — bateria de testes rodada nesta entrega

**54 de 54 verificações passando** (script `tests/run_tests_fase23.sh`, mesma disciplina de nunca esconder regressão: **PASSO-0** reexecuta `tests/run_tests_deploy.sh` **original, sem editar** — que por sua vez reexecuta toda a cadeia Fase 1→1.1→1.2→2→2.1→2.2→2.2.1 — e só depois aplica as 4 migrations novas desta fase; a cadeia inteira soma **196 verificações, 0 quebrado**, antes mesmo de chegar nos testes próprios da Fase 2.3): SEC3/SEC5 confirmam que nenhuma referência a "jussara" (case-insensitive) sobrou em `web/src` e que a rota fixa `/cidades/jussara` foi removida; TESTE-C1..C9 (seção 26) criam uma cidade nova do zero (TESTE) inteiramente por API — 2 POPs (nunca assume 1 cidade = 1 POP), 1 segmento, 1 cabo de 24 FO com as 24 fibras geradas automaticamente junto, postes, 1 porta PON com a capacidade padrão de 128 aplicada pelo trigger (parametrizada, não hard-coded), e o Pricing Engine calculando de verdade para essa cidade recém-criada; TESTE-A1..A3 (seção 27) criam uma segunda cidade (Andirá) e confirmam que Jussara não muda; TESTE-E1..E3 + TESTE-I1/I2 (seções 28-29) editam Andirá (10km→12km) e confirmam isolamento total de Jussara — inclusive postes/FO/FO-ociosas comparados contra um baseline capturado dinamicamente no início do script, não um número fixo, porque cada fase anterior já deixou fixtures próprios sobre a mesma Jussara; TESTE-P1..P9 (seção 30) confirmam RBAC por rota nos 4 perfis (COMERCIAL só lê, ENGENHARIA/ADMINISTRADOR criam e editam, AUDITOR só lê, e RLS bloqueia até criação de POP por COMERCIAL); AUD-1..AUD-16 (seção 38) confirmam que a auditoria — usuário/data/hora/ação/dados anteriores/dados novos — cobre criação **e** alteração de cidade, POP, cabo, fibra, poste e porta PON: 6 INSERTs conferidos, 4 UPDATEs via API real (cidade/POP/fibra/PON) e 2 UPDATEs via SQL direto (cabo/poste, que não têm endpoint de edição na especificação — seções 15/18 só pedem cadastro — provando que o gatilho genérico `fn_auditoria()` cobre a tabela de qualquer forma que ela venha a ser alterada, não só pelas rotas que existem hoje); TESTE-AR1..AR5 (seções 31-32) confirmam arquivamento sem contrato ativo (sem `DELETE` físico — `removido_em` setado) e o bloqueio exato de arquivar Jussara (contrato `ATIVO`), com a mensagem literal do prompt. O E2E obrigatório da seção 40 (`tests/e2e_fase23.js`, Playwright real contra o frontend, não simulado) roda à parte: **11 de 11 PASS** — login → Cidades → Nova Cidade (Andirá) → salvar → criar POP → criar segmento+cabo → voltar ao detalhe da cidade (Régua de Preço genérica) → Nova Simulação → selecionar Andirá → simular → Dashboard confirmando as duas cidades lado a lado, sem tratamento especial para nenhuma.

Duas correções reais encontradas durante a própria validação, ambas disclosed: (1) `pricing_cities_list()`/`pricing_city_detail()` precisaram de `DROP FUNCTION IF EXISTS` antes do `CREATE OR REPLACE`, porque adicionar colunas ao retorno de uma função `returns table(...)` muda o tipo composto implícito e o Postgres recusa a substituição direta (`ERROR: cannot change return type of existing function`); (2) o E2E-9 (Nova Simulação calcula Pricing para a cidade nova) falhava de forma intermitente com um `waitForTimeout(2000)` fixo — não porque o cálculo estivesse errado (as 3 chamadas concorrentes de `runSimulation()` — `calculate`/`growth-curve`/`horizon-table` — sempre voltavam 200 — mas porque a régua de preço só renderiza depois que as 3 resolvem, e 2 segundos é uma corrida contra Chromium headless "frio"), corrigido trocando o sleep fixo por `page.waitForSelector('.regua', ...)`, que espera o elemento de verdade em vez de um tempo arbitrário. Nenhuma das duas exigiu recriar tabela, apagar migration ou mudar arquitetura. Detalhe teste a teste no `docs/RELATORIO_FASE23.md` que acompanha esta entrega.

O que **não** foi testado por não existir ainda: os mesmos itens fora de escopo das fases anteriores (HubSoft, IBGE, integração financeira, jobs de produção) — e a aplicação das 4 migrations desta fase + a publicação do código novo no ambiente de produção real (Railway/Vercel/Supabase já existentes desde a Fase 2.2.1 Parte 2, mas ainda não atualizados com o código desta fase — ver "Deploy real" abaixo, único item do checklist de aceite ainda pendente).

## Deploy real (GitHub + Supabase + Railway + Vercel)

Os 4 ambientes **já existem e já estão publicados de verdade** desde a Fase 2.2.1 Parte 2 — GitHub (`spotnick/optimon-backend`), Supabase (projeto `zmhektrjgrjvcsysrbmw`), Railway (API) e Vercel (frontend). O que a Fase 2.3 acrescenta (4 migrations SQL + as rotas/telas novas de Cidades & Infraestrutura) **ainda não foi enviado para esses ambientes** — nenhuma credencial foi manuseada nesta sessão para fazer isso (fora do escopo permitido: nunca inserir senha/token/chave em nenhuma chamada de ferramenta em nome do usuário, mesmo com autorização explícita), então os passos abaixo devem ser executados **pelo usuário**, no próprio terminal ou nos painéis Railway/Vercel/Supabase/GitHub. Tudo que não depende de segredo (código, migrations, Dockerfile, configs) já está pronto neste repositório.

- **GitHub**: `.gitignore` cobre todo segredo conhecido (`.env`, `service_role`, `DATABASE_URL`, tokens); `.github/workflows/ci.yml` roda lint+teste da API e lint+build do frontend a cada push/PR, só com variáveis fictícias (nunca um segredo real em CI).
- **Supabase**: projeto já existe, com as 74 migrations das Fases 1..2.2.1(P2) já aplicadas. Faltam só as 4 novas desta fase (`supabase/migrations/20260901*.sql`) — aplicar em ordem, nunca `dev-local-only/` (só simulação para ambiente sem Supabase) — nunca recriar o banco, nunca apagar migration existente.
- **Railway** (API): já publicado. `api/routes/infra.js` é arquivo novo e `api/routes/cities.js`/`api/server.js` foram alterados nesta fase — um novo push para `main` (se o serviço Railway estiver conectado ao GitHub) já dispara o redeploy automaticamente; senão, use "Redeploy" no painel depois do push.
- **Vercel** (frontend): já publicado. `web/src/pages/Cities.jsx`, `NewCity.jsx` e `EditCity.jsx` são novos, e várias telas existentes foram alteradas para remover a lógica fixa de Jussara — mesmo esquema: push para `main` dispara redeploy automático se o projeto Vercel estiver conectado ao GitHub, senão "Redeploy" manual no painel.
- **Pricing Engine centralizado**: continua sem mudar nesta fase — o frontend nunca calcula preço, toda tela que mostra um valor chama `POST /api/pricing/calculate` (`api/lib/calculatePricing.js` → `public.pricing_calculate_full` → `app.simular_precificacao_completa`), que sempre recalcula no servidor a partir dos parâmetros vigentes e da cidade selecionada, nunca confiando em um total vindo do cliente.

### Passo a passo da Fase 2.3 (incremental — os 4 ambientes já existem)

**1. GitHub — enviar o código novo**

```bash
git push origin main
```

(o `git remote add origin ...` e o primeiro `git push -u` já foram feitos em entregas anteriores — se este for um clone novo do zip, ver o passo a passo completo mais abaixo, na primeira entrega desta seção do histórico do repositório.)

**2. Supabase — aplicar só as 4 migrations novas**

Mesmo runbook de sempre (ver a seção "Como aplicar num projeto Supabase real" acima para os detalhes de `$env:PGCLIENTENCODING` no Windows), mas agora só precisa rodar os 4 arquivos novos — os 74 anteriores já estão aplicados. **Importante — `-v ON_ERROR_STOP=1` é obrigatório aqui** (os comandos abaixo já incluem): sem essa flag, o `psql` por padrão **não para nem sinaliza erro** quando uma instrução falha no meio de um arquivo — ele imprime o erro na tela e continua para a próxima instrução, e o `for`/`ForEach-Object` do runbook não percebe (o código de saída do `psql` continua sendo 0). Isso já aconteceu de verdade: um erro de encoding (`$env:PGCLIENTENCODING` não setado no PowerShell) no meio de `20260901090000_...sql` fez `CREATE FUNCTION app.criar_cidade(...)` (que tem comentário acentuado) falhar silenciosamente, e as funções que dependiam dela (`public.pricing_city_create`) nunca foram criadas — só apareceu depois, como `Could not find the function public.pricing_city_create(...) in the schema cache` no frontend.

```bash
export DATABASE_URL="postgresql://postgres:<SENHA_REAL>@db.<seu-projeto>.supabase.co:5432/postgres"
for f in supabase/migrations/20260901*.sql; do
  echo "Aplicando $f..."
  psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f "$f" || { echo "FALHOU em $f"; break; }
done
```

PowerShell (lembrando de `$env:PGCLIENTENCODING = "UTF8"` antes, pelo mesmo motivo já documentado acima — e confira com `echo $env:PGCLIENTENCODING` logo antes de rodar, já que não persiste entre janelas):

```powershell
$env:PGCLIENTENCODING = "UTF8"
$env:DATABASE_URL = "postgresql://postgres:<SENHA_REAL>@db.<seu-projeto>.supabase.co:5432/postgres"
Get-ChildItem "supabase\migrations\20260901*.sql" | Sort-Object Name | ForEach-Object {
  Write-Host "Aplicando $($_.Name)..."
  psql -v ON_ERROR_STOP=1 $env:DATABASE_URL -f $_.FullName
  if ($LASTEXITCODE -ne 0) {
    Write-Host "FALHOU em $($_.Name)"
  }
}
```

As 4 migrations desta fase são seguras para rodar de novo do zero se já rodaram parcialmente antes desta correção — todas usam `add column if not exists`, `create or replace function` e um `if not exists (...) then create trigger ...` explícito, então reaplicar não duplica nada nem quebra por "já existe".

**Antes de aplicar, um jeito rápido de confirmar o que realmente existe hoje no seu Supabase** — cole no SQL Editor do painel (interface web, sempre UTF-8, contorna de vez o problema de encoding do terminal):

```sql
select proname, pg_get_function_identity_arguments(oid)
from pg_proc
where proname in ('pricing_city_create', 'pricing_city_update', 'pricing_city_archive', 'pricing_city_infra_tree', 'pricing_cable_create_with_fibers');
```

Se vier menos de 5 linhas, pelo menos uma dessas migrations não terminou de aplicar — reaplique-as (pode ser mais simples colar o conteúdo de cada arquivo `.sql` direto no SQL Editor, um de cada vez, em vez de lutar com encoding de terminal). Depois de aplicar, use "Reload schema cache" em Project Settings → API no painel do Supabase se as rotas novas não aparecerem imediatamente.

**3. Railway e Vercel — redeploy**

Se os dois serviços já estão conectados ao repositório GitHub (o normal depois da configuração inicial), o `git push` do passo 1 já dispara o build e o redeploy de ambos automaticamente — só acompanhar os logs no painel de cada um. Senão, usar o botão "Redeploy" manual em cada painel.

**4. Validar em produção**

Depois dos 3 passos: abrir o frontend publicado, entrar com um usuário `ENGENHARIA` ou `ADMINISTRADOR`, ir em "Cidades & Infraestrutura", confirmar que Jussara aparece na lista (sem tratamento especial), criar uma cidade de teste pelo formulário, cadastrar um POP e um cabo, e conferir que a Régua de Preço calcula para essa cidade nova — o mesmo roteiro do `tests/e2e_fase23.js`, só que contra o ambiente real. Me avise (ou cole qualquer erro) que eu ajudo a depurar sem precisar ver nenhuma credencial, só as URLs e mensagens de erro.

### Passo a passo original (onboarding do zero — já executado; mantido de referência)

Os 4 passos abaixo descrevem o onboarding completo desde o primeiro deploy (Fase 2.2.1 Parte 2) — já foi executado e os 4 ambientes já estão no ar. Fica aqui só como referência caso você precise recriar algum ambiente do zero (ex.: um novo projeto Supabase de staging); para o dia a dia (como aplicar as migrations novas de uma fase), use o passo a passo incremental acima.

**1. GitHub — enviar o código**

```bash
git remote add origin https://github.com/spotnick/optimon-backend.git
git push -u origin main
```

O Git vai pedir usuário/senha no push — use seu usuário do GitHub e o Personal Access Token como senha (ou configure um credential helper). Depois de usar o PAT aqui, considere regenerá-lo no GitHub (Settings → Developer settings → Personal access tokens) já que ele circulou em texto puro nesta conversa.

**2. Supabase — aplicar as 74 migrations**

Pegue a senha real do banco em Project Settings → Database → Connection string (o valor que você colou tem `[YOUR-PASSWORD]` como placeholder, não a senha em si). Precisa do `psql` instalado (`psql --version` para conferir; se não tiver, instale o "Command Line Tools" do PostgreSQL — no Windows, `winget install PostgreSQL.PostgreSQL` ou o instalador em postgresql.org — só as ferramentas de cliente já bastam, não precisa instalar o servidor).

macOS/Linux (bash/zsh), a partir da raiz do repositório:

```bash
export DATABASE_URL="postgresql://postgres:<SENHA_REAL>@db.gwvdjqfevdcbhupzzpeu.supabase.co:5432/postgres"
for f in supabase/migrations/*.sql; do
  echo "Aplicando $f..."
  psql -v ON_ERROR_STOP=1 "$DATABASE_URL" -f "$f" || { echo "FALHOU em $f"; break; }
done
```

Windows (PowerShell), a partir da raiz do repositório — `export` e o `for ... in ... do` acima são sintaxe de bash e não rodam no PowerShell, o equivalente é:

```powershell
$env:PGCLIENTENCODING = "UTF8"
$env:DATABASE_URL = "postgresql://postgres:<SENHA_REAL>@db.gwvdjqfevdcbhupzzpeu.supabase.co:5432/postgres"

$arquivos = Get-ChildItem "supabase\migrations\*.sql" | Sort-Object Name
foreach ($f in $arquivos) {
  Write-Host "Aplicando $($f.Name)..."
  psql -v ON_ERROR_STOP=1 $env:DATABASE_URL -f $f.FullName
  if ($LASTEXITCODE -ne 0) {
    Write-Host "FALHOU em $($f.Name)"
    break
  }
}
```

`-v ON_ERROR_STOP=1` é tão essencial quanto `PGCLIENTENCODING` e por muito tempo faltou neste runbook — **sem ela, um erro no meio de um arquivo não para o `psql`**: ele imprime o erro e segue para a próxima instrução do mesmo arquivo, com código de saída 0 (sucesso) no final, então nem o `||`/`$LASTEXITCODE` do loop percebe. Foi exatamente assim que uma migration da Fase 2.3 aplicou "com sucesso" aparente no terminal, mas deixou uma função inteira faltando no banco (ver `docs/RELATORIO_FASE23.md` — a seção de troubleshooting, se você chegou aqui vindo de um erro `Could not find the function ... in the schema cache`). Com a flag, qualquer erro interrompe o `psql` imediatamente com código de saída 3, e o loop para de verdade no arquivo que falhou.

`$env:PGCLIENTENCODING = "UTF8"` é essencial no Windows: sem ela, o `psql` declara ao servidor que o texto vem em `WIN1252` (a codificação padrão do console do Windows), e qualquer migration com acento (praticamente todas, os comentários são em português) falha com `ERROR: character with byte sequence 0x... in encoding "WIN1252" has no equivalent in encoding "UTF8"` — agora, com `ON_ERROR_STOP=1`, esse erro interrompe o script na hora em vez de deixar migrations seguintes falharem em cascata (`function ... does not exist`) por dependerem de algo que devia ter sido criado e não foi. Se isso já aconteceu com você e o banco ficou pela metade (bem provável se você aplicou migrations antes desta correção do runbook), o mais seguro é resetar os schemas do projeto (só funciona limpo se o projeto ainda não tiver dados que você precise manter) e rodar tudo de novo já com a variável acima — **ou**, se o projeto já tem dados reais que você não quer perder (o caso mais comum agora que Jussara já está em produção), simplesmente reaplicar as migrations que faltaram: todas usam `create or replace function`/`if not exists`, então reaplicar não quebra nada, só preenche o que faltou.

```sql
-- Cole no SQL Editor do painel do Supabase. Não toca em auth/storage — só nos
-- schemas app/public, que são os que as migrations do OptiMon criam.
drop schema if exists app cascade;
drop schema if exists public cascade;

create schema public;
grant usage on schema public to postgres, anon, authenticated, service_role;
grant create on schema public to postgres;
alter default privileges in schema public grant all on tables to postgres, service_role;
alter default privileges in schema public grant all on functions to postgres, service_role;
alter default privileges in schema public grant all on sequences to postgres, service_role;
```

Um `ERROR: deadlock detected` isolado (costuma aparecer só em `20260825101300_rls_fase11.sql`, que mexe em RLS de várias tabelas de uma vez) é transitório — se acontecer, reaplique só aquele arquivo sozinho depois que o loop terminar.

Os arquivos já estão nomeados com prefixo de data — a ordem alfabética (`Sort-Object Name` / a expansão `*.sql` do bash) é a ordem correta de aplicação. Se alguma rota nova não aparecer imediatamente na API do Supabase, use "Reload schema cache" em Project Settings → API (o Supabase hospedado normalmente recarrega sozinho após DDL, mas o botão força na hora).

Se quiser os dados de exemplo (Jussara-PR), primeiro crie um usuário real em **Authentication → Users** no painel do Supabase (marque "Auto Confirm User"), copie o UID gerado, e vincule ele a um perfil rodando no **SQL Editor**:

```sql
insert into public.usuarios (id, nome, email, perfil)
values ('<UID_COPIADO>', 'Seu Nome', 'seu-email@exemplo.com', 'ADMINISTRADOR');
```

**Antes de rodar os seeds, confirme a variável de encoding da seção anterior na MESMA sessão do terminal** (`echo $env:PGCLIENTENCODING` deve responder `UTF8`) — ela não persiste entre janelas novas nem depois de reiniciar o computador, então se você abriu um terminal novo ou reiniciou a máquina desde a última vez, rode `$env:PGCLIENTENCODING = "UTF8"` (PowerShell) de novo antes de continuar. Sem isso, os seeds ainda aplicam (o `psql` não trava, ao contrário das migrations), mas o texto acentuado (descrições em português dos parâmetros de pricing, observações de fibra/poste etc.) é gravado corrompido no banco — silenciosamente, sem erro nenhum — porque o `psql` declara ao servidor que está enviando `WIN1252` quando na verdade é UTF-8. Se você já rodou algum seed sem essa variável e suspeita de texto corrompido (ex.: `descricao` de `pricing_parametros` aparecendo como `PreÃ§o mÃ­nimo`), rode `select chave, descricao from public.pricing_parametros;` no SQL Editor do Supabase para conferir — se estiver corrompido, apague as linhas afetadas (`delete from public.pricing_parametros;` é seguro pois o passo abaixo recria todas) e rode os seeds de novo, já com a variável setada.

Só então rode, na mesma sessão do terminal, `psql $env:DATABASE_URL -f supabase\seed_producao.sql` (PowerShell) ou `psql "$DATABASE_URL" -f supabase/seed_producao.sql` (bash), seguido de `seed_fase11.sql`, `seed_fase12.sql`, `seed_fase2.sql`, nessa ordem. **Nunca `supabase/seed.sql`** contra um Supabase real — esse insere direto em `auth.users`, o que só funciona no shim de desenvolvimento local (`supabase/dev-local-only/`); `seed_producao.sql` é o mesmo seed, mas localiza o usuário ADMINISTRADOR que você acabou de vincular em vez de tentar criar um novo, e já vem corrigido para rodar depois de TODAS as migrations aplicadas (a ordem real deste runbook) — versões anteriores deste arquivo quebravam nesse ponto com `null value in column "pricing_version"` ou com a trigger de porta PON reclamando de POP ausente; ambos corrigidos (ver `docs/ARQUITETURA.md`, seção 19.9, bugs 3 e 4).

**3. Railway — publicar a API**

Mais simples pelo painel: New Project → Deploy from GitHub repo → selecione `spotnick/optimon-backend` → em Settings, confirme que o build usa `api/Dockerfile` (já configurado via `railway.toml`) → em Variables, adicione `SUPABASE_URL`, `SUPABASE_ANON_KEY` (a chave `anon`, nunca a `service_role`), `CORS_ALLOWED_ORIGINS` (preencha depois de ter a URL do Vercel) e `APP_ENVIRONMENT=production`. Depois do deploy, confirme `https://<seu-servico>.up.railway.app/health` → `{"status":"ok","service":"optimon-api"}`.

**4. Vercel — publicar o frontend**

Também mais simples pelo painel: Add New → Project → importe `spotnick/optimon-backend` → Root Directory: `web` → Framework Preset: Vite (o `vercel.json` já traz o resto). Em Environment Variables: `VITE_API_URL` (a URL do Railway do passo 3), `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (a chave `anon`), `VITE_APP_ENVIRONMENT=PRODUÇÃO` (ou `DEMONSTRAÇÃO`). Depois de publicado, volte no Railway e preencha `CORS_ALLOWED_ORIGINS` com a URL do Vercel.

Depois dos 4 passos, me avise (ou cole o resultado de qualquer erro) que eu confiro os endpoints públicos e ajudo a depurar — sem precisar ver nenhuma credencial, só as URLs e mensagens de erro.

Esse onboarding completo já foi concluído em uma entrega anterior — os 4 ambientes estão criados e no ar (ver `docs/RELATORIO_FASE221_PARTE2.md`, addendum). O que falta **hoje** é só o incremento da Fase 2.3 (4 migrations + código novo) chegar até eles — ver "Passo a passo da Fase 2.3 (incremental)" no início desta seção.

## Próximos passos (Fase 3 em diante)

Ver `docs/ARQUITETURA.md`, seção 12 (roteiro completo), seção 15 (Fase 2), seção 16 (Fase 2.1), seção 17 (Fase 2.2 — Infrastructure Floor), seção 18 (Fase 2.2.1 — governança por papel + Porta PON como componente do Floor), seção 19 (Fase 2.2.1 Parte 2 — deploy, Pricing Engine centralizado, frontend React) e seção 20 (Fase 2.3 — Cidades & Infraestrutura multi-cidade). Por instrução explícita do Prompt Mestre (seção 41/42 da Fase 2.3), a próxima fase **não foi iniciada automaticamente** — a próxima etapa será definida pelo usuário, e por enquanto falta só um item do checklist de aceite da Fase 2.3: aplicar as 4 migrations novas e publicar o código desta fase nos ambientes reais já existentes (ver "Deploy real" acima) — nenhuma credencial foi manuseada por esta sessão para isso, como de costume.
