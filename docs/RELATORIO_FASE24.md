# Relatório Final — Fase 2.4 (Manuais Operacionais + Central de Ajuda + Módulo Profissional de Propostas + Exportação PDF/DOCX + Histórico e Controle de Versões)

Status geral: **CONCLUÍDA no código, nos testes e na documentação — 31/31 verificações novas PASS, 0 FAIL (`tests/run_tests_fase24.sh`), mais 13/13 no E2E Playwright obrigatório (`tests/e2e_fase24.js`), mais regressão completa herdada de todas as fases anteriores (via `run_tests_fase231.sh`, que por sua vez encadeia Fase 1→2.3.1, 0 quebrado)**. Nenhuma migration de fase anterior foi editada, nenhuma tabela recriada, nenhum dado existente apagado — só 2 migrations aditivas. Por instrução do Prompt Mestre desta fase ("NÃO iniciar nova fase até todos os itens do checklist estarem PASS. Entregar relatório final detalhado."), a Fase 3 **não foi iniciada**.

**Nota sobre a fonte do escopo desta fase**: esta implementação foi retomada a partir de uma conversa cujo histórico bruto (a colagem original de 51 seções do prompt-mestre da Fase 2.4) não pôde ser recuperado nesta sessão — ela pertence a uma sessão anterior já compactada, e uma tentativa de localizá-la no transcript desta sessão só encontrou meu próprio resumo do que havia sido pedido, não o texto original seção a seção. O escopo abaixo foi implementado, testado e documentado com base nesse resumo detalhado (retido fielmente, inclusive a citação literal da instrução de encerramento). Isso é dito aqui de forma transparente: o checklist de aceite ao final cobre os itens que constam desse resumo — não há citação literal de número de seção do prompt original além dos que já haviam sido registrados antes da compactação.

Esta fase acrescenta duas frentes ao OptiMon: (1) uma Central de Ajuda com manuais por perfil, glossário, FAQ, busca, tooltips contextuais e onboarding de primeiro acesso; e (2), como ponto central da fase, transforma o módulo de Propostas — que desde a Fase 1 era uma tela simples de listagem — num documento comercial profissional de 28 seções, com dois modos de visualização (Interna/Externa), cenários de sensibilidade, projeções financeiras, gráficos, exportação real em PDF e DOCX, histórico de versões e um fluxo de aprovação com governança.

## 1. Arquivos alterados ou criados

**Migrations (2 novas, todas aditivas):**
- `supabase/migrations/20260909090000_phase_2_4_01_propostas_versionamento_capa_status.sql`
- `supabase/migrations/20260909090100_phase_2_4_02_propostas_funcoes_versao_aprovacao.sql`

**Backend:**
- `api/routes/partners.js` — novo (`GET /api/partners`, gap fechado nesta fase: parceiros existiam desde a Fase 1 mas nunca tinham rota própria).
- `api/routes/proposals.js` — reescrito por completo (11 rotas).
- `api/lib/proposalDocumentModel.js` — novo (modelo único de dados do documento: cenários, projeções, gráficos, 28 seções, usado por PDF e DOCX).
- `api/lib/pdfProposal.js` — novo (geração de PDF real via `pdfkit`).
- `api/lib/docxProposal.js` — novo (geração de DOCX real via `docx`).
- `api/server.js` — estendido (rota `/api/partners`, `exposedHeaders: ['Content-Disposition']` no CORS).
- `api/package.json` — `pdfkit` e `docx` adicionados como dependências.

**Frontend:**
- `web/src/lib/api.js` — estendido (`proposals.*`, `partners.list`, `apiDownload`).
- `web/src/pages/NewSimulation.jsx` — estendido (parceiro/preço proposto/validade na geração da proposta, tooltips).
- `web/src/pages/Proposals.jsx` — reescrito (lista com filtro de status, versão, link para detalhe).
- `web/src/pages/ProposalDetail.jsx` — novo (Interna/Externa, cenários, projeções, gráficos, aprovação, exportação, histórico de versões).
- `web/src/pages/Help.jsx` — novo (`/ajuda`, busca, manuais, glossário, FAQ).
- `web/src/content/manuals.js`, `glossario.js`, `faq.js` — novos (conteúdo dos 4 manuais por perfil, glossário, FAQ).
- `web/src/components/HelpTooltip.jsx` — novo (tooltip contextual "?").
- `web/src/components/OnboardingModal.jsx` — novo (onboarding de primeiro acesso).
- `web/src/components/Layout.jsx`, `web/src/App.jsx` — estendidos (menu "Ajuda & Manuais", rotas `/propostas/:id` e `/ajuda`).

**Testes:**
- `tests/run_tests_fase24.sh` — novo (31 verificações + regressão completa via `run_tests_fase231.sh`, sem editar).
- `tests/e2e_fase24.js` — novo (13 verificações, Playwright real).
- `docs/RELATORIO_FASE24.md` (este arquivo).

## 2. Migrations (2 novas, todas aditivas)

| # | Arquivo | O que faz |
|---|---|---|
| 1 | `090000_..._01_propostas_versionamento_capa_status.sql` | Novas colunas em `propostas_comerciais`: `numero_versao`, `proposta_raiz_id`, `duplicada_de_id`, `parceiro_nome_capa`, `parceiro_cargo_contato`, `validade_dias`, `autorizado_por`, `autorizado_em`, `preco_autorizado`, `motivo_autorizacao`, `motivo_status`. Migra `'REJEITADA'` → `'RECUSADA'` e recria `propostas_comerciais_status_check` com os 9 valores. Backfill de `proposta_raiz_id = id` nas linhas existentes. Trigger `trg_proposta_raiz_id_default` (auto-seta `proposta_raiz_id` em INSERT quando nulo). Amplia `auditoria_acao_check` com as 6 novas ações de proposta. |
| 2 | `090100_..._02_propostas_funcoes_versao_aprovacao.sql` | As funções de negócio (seção 3 abaixo), as views enriquecidas (seção 4) e a view externa segura (seção 5). |

## 3. Funções de negócio novas (`app.*`, SQL-first, `public.*` como wrapper fino)

| Função | O que faz | Segurança |
|---|---|---|
| `app.duplicar_proposta` | Cria uma proposta nova e independente (`numero` próprio, `proposta_raiz_id` própria família), vinculada só via `duplicada_de_id`. | `SECURITY INVOKER` |
| `app.criar_versao_proposta` | Cria V2/V3/... na mesma família — `numero` sempre derivado da raiz (`{numero_raiz}-V{n}`, nunca empilhado), preservando a identidade "mesma proposta, nova revisão". | `SECURITY INVOKER` |
| `app.aprovar_proposta` | Só DIRETOR/ADMINISTRADOR (`app.tem_perfil`). Exige `motivo` quando `preço < piso`. Grava `autorizado_por`/`autorizado_em`/`preco_autorizado`/`motivo_autorizacao`. | `SECURITY INVOKER` |
| `app.rejeitar_proposta` | `motivo` sempre obrigatório. Bloqueia se já em estado terminal. | `SECURITY INVOKER` |
| `app.mudar_status_proposta` | Transições permitidas: ENVIADA/EM_NEGOCIACAO/ACEITA/EXPIRADA/CANCELADA. Bloqueia a partir de estado terminal. `motivo` obrigatório para CANCELADA. | `SECURITY INVOKER` |
| `app.registrar_exportacao_proposta` | Só grava o evento de auditoria `PROPOSAL_EXPORT` (chamado pela API depois de gerar o arquivo). | `SECURITY DEFINER` |

Todas as 5 primeiras foram mantidas como `SECURITY INVOKER` (e não convertidas para `SECURITY DEFINER`, ao contrário do padrão usado na Fase 2.3.1 para `restaurar_*`) porque, desta vez, a *policy* de `UPDATE` existente em `propostas_comerciais` (`(DIRETOR/ADMINISTRADOR) OR (criado_por = auth.uid() AND status = 'RASCUNHO')`) já cobre exatamente os mesmos perfis que a checagem de RBAC de cada função permite — verificado explicitamente antes de implementar, e confirmado nos testes (TESTE-3: COMERCIAL tentando aprovar recebe `403`, não um "sucesso" que na verdade não mudou nada no banco).

`app.registrar_auditoria_semantica` (já existente desde a Fase 2.3.1) foi estendida para aceitar as 6 novas ações de proposta.

## 4. Status ampliado (4 → 9 valores) e cálculo automático na criação

`RASCUNHO, EM_APROVACAO, APROVADA, ENVIADA, EM_NEGOCIACAO, ACEITA, RECUSADA, EXPIRADA, CANCELADA` (`'REJEITADA'` antigo migrado para `'RECUSADA'`).

`pricing_proposal_create` calcula o status automaticamente: `preco_proposto >= recommended` → `RASCUNHO`; `preco_proposto < recommended` (inclui o caso abaixo do piso) → `EM_APROVACAO`. A distinção "abaixo do piso exige motivo" só é verificada depois, no momento da aprovação (`app.aprovar_proposta`), comparando o preço com o piso especificamente — não na criação.

## 5. Segurança Interna × Externa (o ponto mais sensível desta fase)

Duas camadas independentes garantem que o modo Externa nunca expõe piso, abertura, desconto, governança ou autorização:

1. **Banco**: `public.pricing_proposal_external_view` é uma função *whitelist-only* — só retorna os campos explicitamente listados (`id, numero, status, numero_versao, cidade_nome, cidade_uf, parceiro_nome_capa, parceiro_cargo_contato, validade_dias, criado_em, clientes, arpu, faturamento, preco_proposto, revenue_share_pct, prazo_meses`), nunca `floor`/`opening`/`discount`/`governance_status`/`autorizado_por`/`motivo_autorizacao`. É essa função que atende `GET /api/proposals/:id/public`.
2. **Geração de documento**: `api/lib/proposalDocumentModel.js` sempre busca o jsonb interno completo (via `pricing_proposal_get_by_id`), mas cada uma das 28 seções decide, com base em `modo`, quais campos incluir — as seções 11 (Composição de Preço × Condições Comerciais) e 26 (Governança e Autorização × Status da Proposta) têm textos e tabelas inteiramente diferentes por modo.

Verificado de forma automatizada: `tests/run_tests_fase24.sh` (TESTE-9b) extrai o texto do PDF gerado em modo Externa via `pdftotext` e confirma, com `grep -iE`, ausência literal de "piso mínimo mensal garantido", "desconto máximo permitido", "governança (avaliação automática)" e "autorizado por". O mesmo tipo de checagem foi feito manualmente contra o DOCX (extração de texto do XML dentro do zip) durante o desenvolvimento.

## 6. Documento de proposta — 28 seções, 3 cenários, 4 projeções, 4 gráficos

`buildProposalDocumentModel` (em `proposalDocumentModel.js`) monta:
- **3 cenários de sensibilidade** (Conservador/Base/Agressivo, ±15% de clientes), recalculando o total pago com a mesma lógica de composição (MAX/SOMA/outro modo) do motor de precificação do backend.
- **4 horizontes de projeção** (12/36/48/60 meses) — 48 meses rotulado como "mínimo contratual" quando coincide com o prazo do contrato, 60 meses sempre rotulado como "(projeção)".
- **4 gráficos** — o gráfico de composição de preço (#3) é o único que muda de conteúdo por modo: Interna mostra piso/abertura/recomendado/proposto; Externa mostra mensal × total do contrato.
- **28 seções** de texto/tabela, cobrindo capa, sumário executivo, dados do parceiro, composição de preço (ou condições comerciais, conforme modo), cenários, projeções, gráficos, governança (ou status, conforme modo), termos e assinatura.

## 7. Exportação PDF e DOCX — real, não captura de tela

**PDF** (`api/lib/pdfProposal.js`, `pdfkit`, puramente JS): capa com identidade visual própria, cabeçalho/rodapé com numeração de página em todas as páginas exceto a capa, tabelas desenhadas, e os 4 gráficos como barras vetoriais desenhadas com primitivas (`rect`/`text`) — sem depender de navegador headless ou de uma lib de canvas nativa, para não quebrar a imagem Docker `node:22-alpine` do Railway.

**DOCX** (`api/lib/docxProposal.js`, pacote `docx`, também puramente JS): mesma estrutura de 28 seções, totalmente editável no Word. Como `docx` não tem suporte nativo a gráfico vetorial sem depender de uma lib de canvas nativa (mesma restrição do PDF), os 4 "gráficos" são representados como tabelas de dados editáveis em vez de imagem — uma escolha arquitetural deliberada e documentada, não uma limitação escondida.

**Nome de arquivo**: `OPTIMON_Proposta_[Cidade]_[Parceiro]_[AAAAMMDD].pdf`/`.docx`, gerado no backend (`buildFileName`, com um `slug()` que remove acentos) e entregue via `Content-Disposition`. O `Access-Control-Expose-Headers: Content-Disposition` foi necessário (seção 8, bug 3) para que o frontend leia esse nome corretamente em requisição cross-origin.

## 8. Histórico de versões e duplicação

- **Nova Versão** (`app.criar_versao_proposta`): cria uma linha nova na mesma família (`proposta_raiz_id` preservado), com `numero_versao` incrementado e `numero` = `{numero_raiz}-V{n}` — sempre derivado da raiz, nunca empilhado (V3 não vira `...-V2-V3`).
- **Duplicar Proposta** (`app.duplicar_proposta`): cria uma proposta totalmente independente — `numero` próprio (via default da coluna), `proposta_raiz_id` própria — vinculada à original só por `duplicada_de_id`, para rastreabilidade sem acoplar o ciclo de vida.
- `GET /api/proposals/:id/versions` lista toda a família ordenada por `numero_versao`.

## 9. Central de Ajuda, manuais, tooltips e onboarding

- **4 manuais** por perfil (Engenharia/Comercial/Financeiro/Diretoria), cada um com múltiplas seções de conteúdo real cobrindo o sistema construído em todas as fases (infraestrutura, régua de preço, propostas, governança).
- **Glossário** (~23 termos) e **FAQ** (12 perguntas).
- **`/ajuda`**: busca acento-insensível sobre manuais/glossário/FAQ, com deep-link por `?manual=<slug>`, e o manual do próprio perfil do usuário destacado.
- **Tooltips contextuais** ("?") em campos-chave (Revenue Share %, Composição, Preço proposto, Piso).
- **Onboarding de primeiro acesso**: modal mostrado uma vez (`localStorage`), com atalho direto para o manual do perfil do usuário.

## 10. Bateria de testes — 31/31 novas + regressão herdada + E2E 13/13

`tests/run_tests_fase24.sh`: PASSO-0 reexecuta `tests/run_tests_fase231.sh` **original, sem editar** (que por sua vez reexecuta toda a cadeia Fase 1→2.3.1) e só depois aplica as 2 migrations novas desta fase. Cobre, na ordem: TESTE-0 (`GET /api/partners`, gap fechado); TESTE-1 (preço ≥ recomendado → RASCUNHO); TESTE-2 (preço abaixo do recomendado → EM_APROVACAO); TESTE-3 (COMERCIAL bloqueado ao aprovar, `403`); TESTE-4 (aprovar abaixo do piso sem motivo, `400`); TESTE-5 (DIRETOR aprova com motivo → APROVADA, `autorizado_por` preenchido, auditoria `PROPOSAL_APPROVE`); TESTE-6 (rejeitar sem motivo `400`, com motivo → RECUSADA, auditoria `PROPOSAL_REJECT`); TESTE-7 (ciclo ENVIADA→EM_NEGOCIACAO→ACEITA, bloqueio a partir de estado terminal `409`, auditoria `PROPOSAL_STATUS_CHANGE`); TESTE-8 (Nova Versão com `numero` derivado corretamente, auditoria `PROPOSAL_VERSION_CREATE`; Duplicar com `numero`/`proposta_raiz_id` independentes, auditoria `PROPOSAL_DUPLICATE`; `GET /versions` lista as 2 versões); TESTE-9 (export PDF interna/externa e DOCX interna — status/tamanho/content-type/nome de arquivo, mais a checagem `pdftotext` de que o PDF externo não vaza piso/desconto/governança/autorização, mais auditoria `PROPOSAL_EXPORT`); TESTE-10 (`GET /public` sem `floor`/`governance_status`/`autorizado_por`, com `preco_proposto` presente); RBAC negativo (ENGENHARIA bloqueada em `404` por não enxergar a simulação via RLS, AUDITOR bloqueado em `403` na policy de INSERT de propostas — dois pontos de bloqueio diferentes, ambos corretos, documentados inline no teste); TESTE-11 (`GET /api/proposals?status=` enriquecido com `cidade_nome`).

`tests/e2e_fase24.js` (Playwright real contra o frontend Vite/React): **13/13 PASS** — Login (COMERCIAL) → Nova Simulação → confirma "Preço proposto" pré-preenchido com o recomendado → informa preço abaixo do recomendado → preenche parceiro → Gerar Proposta → confirma sucesso → abre detalhe → confirma status "Em Aprovação" → alterna Externa (KPI de Piso escondido) → volta a Interna (KPI de Piso visível) → confirma que COMERCIAL não vê o botão Aprovar → logout → Login (DIRETOR) → mesma proposta → preenche motivo → Aprovar → confirma `APROVADA` no banco → Nova Versão (confirma 2 linhas na família) → Duplicar Proposta (confirma linha com `duplicada_de_id` correto) → Exportar PDF (download real do Playwright, nome no padrão `OPTIMON_Proposta_*.pdf`) → Ajuda & Manuais, busca "piso" (resultado encontrado) → Auditoria confirma `PROPOSAL_APPROVE` registrado para a proposta.

## 11. Bugs reais encontrados durante a própria validação (4, todos corrigidos e disclosed)

**Bug 1 — `app.criar_versao_proposta` quebrava a identidade "mesma proposta, nova versão" (bug de produto, pego pela própria asserção do teste).** O `numero` da nova versão estava sendo omitido do INSERT explícito, então regenerava via o default aleatório da coluna — V2 nascia com um `numero` completamente diferente e desconexo de V1. A restrição `UNIQUE(numero)` herdada da Fase 2.2.1 impede reusar o mesmo `numero` literal entre V1 e V2, então a correção deriva `numero` como `{numero_da_raiz}-V{n}` (buscado sempre a partir da linha raiz, para não empilhar sufixo em V3/V4) e o inclui explicitamente na lista de colunas do INSERT. TESTE-8a foi ajustado para a expectativa correta e passou a confirmar isso.

**Bug 2 — quebra de regressão encadeada por parâmetros novos enviados incondicionalmente.** `bash tests/run_tests_fase24.sh` falhava no PASSO-0 (dentro da própria cadeia `run_tests_fase231.sh`→`run_tests_fase23.sh`, no seu próprio passo E2E de gerar proposta) com `Could not find the function public.pricing_proposal_create(...)` — porque `api/routes/proposals.js`, um arquivo de código mutável compartilhado por toda a regressão, enviava incondicionalmente os 3 parâmetros novos desta fase mesmo rodando contra um snapshot de banco de fase anterior que ainda não os tinha. Corrigido no mesmo padrão já estabelecido em `api/routes/cities.js`: montar os parâmetros base e só incluir os novos condicionalmente (`if (x != null) params.p_x = x;`), aplicado em `POST /` e `GET /`.

**Bug 3 — nome do arquivo de exportação caía sempre no genérico `proposta.pdf`.** Requisição `fetch()` cross-origin (frontend em uma origem, API em outra) não expõe o header `Content-Disposition` ao JavaScript por padrão — `apiDownload()` (`web/src/lib/api.js`) lia `null` e caía no fallback. Corrigido adicionando `exposedHeaders: ['Content-Disposition']` ao `cors({...})` de `api/server.js`.

**Bug 4 — geração de PDF quebrava com "Syntax Error: Restoring state when no valid states to pop"** (só detectado extraindo o texto do PDF gerado via `pdftotext`, não visível checando só tamanho/status HTTP). Causado por `doc.save()`/`doc.restore()` desnecessários envolvendo a rotina de cabeçalho/rodapé, chamada num laço `switchToPage()` depois de todo o conteúdo já ter sido escrito. Corrigido removendo os `save()`/`restore()` — a rotina só define cor de preenchimento/traço e desenha texto/linha/retângulo, nada que exija salvar/restaurar estado gráfico.

Um quinto ponto, não um bug mas uma correção de conteúdo: o texto fixo da seção 23 ("com piso mínimo mensal garantido") vazava a palavra "piso" mesmo em modo Externa — corrigido tornando essa frase `modo`-consciente em `proposalDocumentModel.js` (Externa: "com valor mensal mínimo garantido à OptiMon"), e reverificado com `grep` sem ocorrências em PDF e DOCX.

## 12. Segurança — auditoria própria desta entrega

Nenhum arquivo versionado contém segredo real (conferido nas 2 migrations, em `api/routes/*.js`, `api/lib/*.js` e nos componentes novos do frontend antes do commit, via `git grep`). Nenhuma rota nova usa a service role. O backend nunca confia em valor vindo do frontend: status, piso, governança e autorização são sempre recalculados/decididos no banco — inclusive o próprio conteúdo do PDF/DOCX é montado a partir do jsonb retornado pelo Postgres, nunca de um valor enviado pelo cliente.

## 13. O que não foi testado / está fora do escopo desta fase

Deploy real (as 2 migrations desta fase ainda não foram aplicadas no Supabase de produção — ver "Deploy real" no `README.md`), integração HubSoft/IBGE/financeira externa, teste de carga/performance sob rede real de produção, e o link público (`/propostas/:id/public`) como página HTML própria — a rota de API que o alimenta (`pricing_proposal_external_view`) está pronta e testada, mas nenhuma tela pública dedicada foi pedida além da preparação do endpoint em si.

## 14. Fase 3 — não iniciada

Por instrução do Prompt Mestre desta fase ("NÃO iniciar nova fase até todos os itens acima estarem PASS. Entregar relatório final detalhado."), a Fase 2.4 termina aqui, aguardando aprovação explícita do usuário antes de qualquer trabalho novo.

## Checklist de aceite (23 itens)

1. [x] Menu "Ajuda & Manuais" com 4 manuais por perfil + Glossário + FAQ — seção 9 deste relatório.
2. [x] Central de Ajuda `/ajuda` com busca — seção 9.
3. [x] Tooltips contextuais "?" em campos-chave — seção 9.
4. [x] Onboarding de primeiro acesso — seção 9.
5. [x] Tela `/propostas` — lista com filtro de status, versão, criação — `web/src/pages/Proposals.jsx`.
6. [x] Documento de proposta com 28 seções — seção 6 deste relatório.
7. [x] Modo Interna mostra piso/margem/desconto; modo Externa nunca mostra — seção 5.
8. [x] Tabelas financeiras — cenários e projeções — seção 6.
9. [x] 3 cenários (Conservador/Base/Agressivo) — seção 6.
10. [x] Projeções 12/36/48/60 meses (48 = mínimo contratual, 60 = projeção) — seção 6.
11. [x] 4 gráficos profissionais — seção 6.
12. [x] Exportação PDF real (capa/cabeçalho/rodapé/paginação/tabelas/gráficos, não captura de tela) — seção 7.
13. [x] Exportação DOCX editável, mesma estrutura — seção 7.
14. [x] Nome de arquivo no padrão `OPTIMON_Proposta_[Cidade]_[Parceiro]_[AAAAMMDD].pdf/.docx` — seção 7.
15. [x] Histórico de versões (V1/V2/V3, nunca sobrescreve) — seção 8.
16. [x] Status ampliado (9 valores) — seção 4.
17. [x] "Duplicar Proposta" — seção 8.
18. [x] Fluxo de aprovação: abaixo do recomendado → EM_APROVACAO — seção 4, TESTE-2.
19. [x] Abaixo do piso exige autorização com motivo obrigatório (quem/quando/preço/motivo registrados) — seção 3/4, TESTE-4/5.
20. [x] Preparação do link público `/propostas/:id/public` sem dado interno — seção 5, TESTE-10.
21. [x] Os testes obrigatórios (TESTE 0-11) passando — 31/31 PASS.
22. [x] Fluxo E2E completo passando literalmente — 13/13 PASS.
23. [x] Regressão completa de todas as fases anteriores sem quebras — herdada via `run_tests_fase231.sh`, sem editar, 0 quebrado.
