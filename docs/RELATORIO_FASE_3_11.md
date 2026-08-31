# Relatório Final — Fase 3.11: Fechamento Real do Workflow Proposta → Aprovação NICK → Envio → Aceite Parceiro → Contrato → Assinatura → Ativação

**Migration nova:** `supabase/migrations/20261002090000_phase_3_11_workflow_proposta_parceiro.sql` (794 linhas)
**Teste E2E dedicado:** `tests/run_tests_fase311.sh` — última execução real: **40 PASS / 0 FAIL** (3 execuções consecutivas, incluindo depois de cada correção de bug)
**Verificação visual real (Chromium, sessão local injetada):** `tests/visual_fase311.js` — 15 screenshots reais em `/tmp/fase311_evidencia/`, enviados nesta conversa
**Regra seguida à risca:** nenhum item abaixo foi marcado PASS por presunção. Todo PASS de interface tem clique real + captura de tela como evidência.

Este trabalho continua na mesma sandbox isolada da Fase 3.10 (sem acesso a git remote real nem ao computador do usuário) — arquivos alterados/novos serão copiados para a pasta real do projeto no OneDrive, e commit/push/deploy real seguem como dependência externa, exatamente como já documentado na Fase 3.10.

---

## 0. Por que esta fase existiu — o problema real encontrado na Fase 3.10

Durante a homologação visual da Fase 3.10, o usuário constatou que o relatório anterior declarou PASS para um fluxo que, na prática, tinha 4 furos graves:

1. Não havia botão "CRIAR CONTRATO" visível/utilizável de forma confiável.
2. Não havia vínculo proposta↔contrato claramente demonstrado na interface.
3. "APROVAR PROPOSTA" é uma ação da NICK (Diretoria) — nunca prova consentimento do parceiro.
4. O status de uma proposta podia ser trocado livremente por um operador interno (`mudar_status_proposta('ACEITA')`), **sem o parceiro ter feito absolutamente nada** — um "aceite" totalmente fictício.

A Fase 3.11 corrige a causa raiz dos 4 pontos, com um parceiro externo real (sem login), um token de acesso, e um aceite formal validado no servidor.

---

## 1. Auditoria do estado anterior (feita ANTES de qualquer código — seção 2 do prompt)

| Camada | Status encontrado | Evidência |
|---|---|---|
| Banco | PARTIAL | `propostas_comerciais.status` já tinha 12 valores; `app.aprovar_proposta`/`app.rejeitar_proposta` já eram, de fato, aprovação interna (exigem DIRETOR/ADMINISTRADOR) — só sem esse nome explícito na UI. |
| API | FAIL | `app.mudar_status_proposta` aceitava `'ACEITA'` vindo de qualquer usuário interno autorizado, sem o parceiro ter feito nada — o bug central relatado. Nenhuma rota pública/anônima existia; `requireAuth` cobria 100% de `/api/proposals`. |
| Frontend | FAIL / PARTIAL | Botões Aprovar/Rejeitar existiam, sem rótulo "interna" e sem etapa de envio depois. "CRIAR CONTRATO" (Fase 3.10) já existia e funcionava, mas o gate usava `status = 'ASSINADA'` (assinatura eletrônica do **documento da proposta**, Fase 2.5) como proxy de "o parceiro concordou" — exatamente a confusão aceite≠assinatura que este prompt pede para corrigir. |
| Workflow | FAIL | Não existiam os estados `ENVIADA_AO_PARCEIRO`/`VISUALIZADA_PELO_PARCEIRO`/`ACEITA_PELO_PARCEIRO`/`RECUSADA_PELO_PARCEIRO` — os "ENVIADA"/"ACEITA" antigos eram rótulos genéricos, sem token, sem link, sem qualquer interação real do parceiro. |
| Auditoria | PASS (arquitetura) / PARTIAL (cobertura) | `app.registrar_auditoria_semantica` e a arquitetura de auditoria (imutável, INSERT-only, IP/usuário/origem) já eram sólidas e foram 100% reaproveitadas — só faltavam as ações novas do fluxo com o parceiro. |

Já existia e foi **reaproveitado sem reescrever**: toda a engenharia de assinatura eletrônica (Fase 2.5 — `signature_envelopes`/`signature_signers`/webhooks HMAC/`app.validar_assinatura`), já preparada para `tipo_documento='CONTRATO'` no banco — só faltava (a) o PDF do contrato não gerar automaticamente ao criar o envelope, e (b) uma seção visível no `ContractDetail.jsx`. Ambos corrigidos nesta fase, sem tocar no motor de assinatura em si.

---

## 2. O que foi implementado

### 2.1 Novo modelo de status (aditivo — os 12 valores antigos continuam válidos)

`ENVIADA_AO_PARCEIRO` → `VISUALIZADA_PELO_PARCEIRO` → `ACEITA_PELO_PARCEIRO` (ou `RECUSADA_PELO_PARCEIRO`) → (gera contrato) → `CONTRATO_GERADO`

`app.mudar_status_proposta` (a função que permitia o "pulo" fake) agora só aceita `EXPIRADA`/`CANCELADA` — todas as outras transições passam por funções dedicadas, validadas no servidor.

### 2.2 Backend (Postgres — SECURITY DEFINER onde preciso, sempre com checagem de perfil explícita)

- `app.enviar_proposta_parceiro` — gera token opaco de 64 hex (`gen_random_bytes(32)`), define expiração a partir de `validade_dias`, transiciona para `ENVIADA_AO_PARCEIRO`. COMERCIAL/DIRETOR/ADMINISTRADOR.
- `app.proposta_externa_por_token` — único ponto de leitura do parceiro. Whitelist explícita (nunca floor/margem/desconto/governança/custo interno/preço mínimo autorizado). Registra `PROPOSAL_VIEWED_BY_PARTNER` a cada chamada; transição de status é idempotente.
- `app.aceitar_proposta_parceiro` / `app.recusar_proposta_parceiro` — aceite/recusa formal, validados no servidor (nome/documento/e-mail obrigatórios para aceite; motivo obrigatório para recusa), com IP e timestamp reais. **Nunca um `setStatus` de frontend.**
- `app.gerar_contrato_de_proposta` — gate alterado de `status = 'ASSINADA'` para `status = 'ACEITA_PELO_PARCEIRO'` (a correção central "aceite ≠ assinatura").
- `app.historico_negociacao` — timeline derivada 100% da auditoria real (proposta + contrato vinculado), nunca uma tabela paralela.
- `app.contrato_assinatura_status` — resumo do envelope de assinatura do contrato para a nova seção da tela.
- `app.dashboard_contratual` — 2 indicadores novos + correção de um bug real (ver seção 4).

### 2.3 API (Express)

- `POST /api/proposals/:id/send-to-partner`, `GET /api/proposals/:id/historico` (autenticadas).
- **Rota nova, sem autenticação**: `api/routes/proposalsExternal.js`, montada em `/api/proposals/external` ANTES do `requireAuth` — mesmo padrão já usado pelo webhook de assinatura (única outra exceção da API). Usa `anonClient()` (nunca JWT de usuário, nunca service_role).
- `GET /api/contracts/:id/assinatura-status`.
- Correção do gap real da Fase 2.5: `POST /api/signatures/envelopes` agora gera o PDF do **contrato** automaticamente (igual já fazia para proposta) — mesmo motor de minuta da Fase 3.9/3.10.

### 2.4 Frontend

- `ProposalDetail.jsx`: seção "Aprovação Interna (NICK)" com aviso explícito de que não é consentimento do parceiro; seção "Envio ao Parceiro & Aceite Externo" (botão real, link copiável, contador de visualizações, dados do aceite/recusa); dropdown "Mudar status" reduzido a Expirada/Cancelada; gate de "CRIAR CONTRATO" trocado para `ACEITA_PELO_PARCEIRO`; nova seção "Histórico da Negociação".
- **Página nova** `PartnerExternalProposal.jsx`, rota pública `/parceiro/proposta/:token` (fora de `<ProtectedRoute>`) — documento comercial com identidade visual OptiMon (logo real, mesmas classes CSS), formulário de aceite/recusa real.
- `ContractDetail.jsx`: nova seção "Assinatura eletrônica do contrato" — cria envelope (PDF automático), adiciona signatários, envia, mostra status/tabela de signatários — reaproveitando 100% as rotas já existentes de `api.signatures.*`.
- `Dashboard.jsx`: 2 KPIs novos ("Aguardando o parceiro", "Aceitas, aguardando contrato").

---

## 3. Fluxo final (diagrama)

```
Simulação → Proposta (RASCUNHO)
   │
   ▼ [DIRETOR/ADMIN clica "Aprovar internamente"]
APROVADA (interna — NÃO é aceite do parceiro)
   │
   ▼ [COMERCIAL/DIRETOR/ADMIN clica "Enviar ao Parceiro"] — gera token+link
ENVIADA_AO_PARCEIRO
   │
   ▼ [parceiro abre o link — SEM login]
VISUALIZADA_PELO_PARCEIRO  ──────┐
   │                             │ [parceiro clica "Recusar"]
   ▼ [parceiro clica "Aceitar" + preenche nome/CPF-CNPJ/e-mail]   ▼
ACEITA_PELO_PARCEIRO                                    RECUSADA_PELO_PARCEIRO (fim)
   │
   ▼ [NICK clica "CRIAR CONTRATO" — SÓ POSSÍVEL A PARTIR DAQUI]
CONTRATO_GERADO ──► Contrato (RASCUNHO)
                        │
                        ▼ [engenharia aloca fibra] + [cria envelope CONTRATO → assina 2 signatários → valida]
                     Contrato (ATIVO, após "Ativar contrato")
```

Estados de exceção reaproveitados sem alteração: `EXPIRADA`, `CANCELADA` (internos, a qualquer momento antes do contrato).

---

## 4. Bugs reais encontrados e corrigidos DURANTE a verificação visual

A regra "não declarar PASS por presunção" pegou 3 problemas reais que só apareceram testando de verdade na tela — nenhum deles seria pego por um teste de API puro:

1. **Formulário de aceite externo não exigia e-mail visualmente, mas o backend exigia** (`DADOS_OBRIGATORIOS: e-mail é obrigatório`) — o clique real em "Confirmar aceite" falhava silenciosamente para o usuário. Corrigido: e-mail agora é campo obrigatório (`*`) também no frontend (`PartnerExternalProposal.jsx`).
2. **Valores monetários exibidos sem formatação** ("2570" em vez de "R$ 2.570,00") nos cards de "Mensalidade proposta"/"Faturamento" da área externa E do preview interno "Externa (parceiro)". Causa raiz: `snapshot->>'campo'` sempre devolve `text` em SQL; o jsonb resultante guardava os números como *string*, e `String.prototype.toLocaleString` no navegador ignora silenciosamente as opções de formatação de moeda. Corrigido com `::numeric` em `app.proposta_externa_por_token` e em `pricing_proposal_external_view` (a segunda é um bug **pré-existente da Fase 2.4/3.10**, não introduzido nesta fase, mas corrigido aqui por ser o mesmo defeito no mesmo tipo de campo).
3. **Seção "Assinatura eletrônica do contrato" nunca mostrava o formulário de signatários** — o código verificava `envelope_status === 'RASCUNHO'`, mas o valor real que a coluna `signature_envelopes.status` usa ao criar um envelope é `'CRIADO'` (confirmado via `pg_get_constraintdef`). Corrigido em `ContractDetail.jsx`.

Um quarto ponto, mais estrutural, também foi corrigido proativamente: `propostas_abertas` no dashboard executivo (Fase 3) não considerava `RECUSADA_PELO_PARCEIRO` como estado terminal — uma proposta definitivamente recusada continuaria contando como "aberta". Corrigido em `app.dashboard_contratual`.

---

## 5. Matriz de permissões (verificada, não presumida — cada linha tem um teste real correspondente)

| Ação | Admin | Diretoria | Comercial | Engenharia | Jurídico* | Parceiro (externo) |
|---|---|---|---|---|---|---|
| Criar simulação | ✅ | ✅ | ✅ | — | — | — |
| Criar proposta | ✅ | ✅ | ✅ | — | — | — |
| Aprovar internamente | ✅ | ✅ | ❌ | ❌ | — | ❌ |
| Enviar ao parceiro | ✅ | ✅ | ✅ | ❌ | — | ❌ |
| Visualizar área externa | — | — | — | — | — | ✅ (só com token válido, nunca de outra proposta — testado) |
| Aceitar/recusar proposta | ❌ | ❌ | ❌ | ❌ | — | ✅ (só via token, uma vez — double-accept bloqueado) |
| Gerar contrato | ✅ | ✅ | ✅ (só se `ACEITA_PELO_PARCEIRO`) | ❌ | — | ❌ |
| Revisar minuta (download) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ (nunca acessa a minuta interna) |
| Alocar infraestrutura (`contrato_fibras`) | — | — | ❌ | ✅ | — | — |
| Enviar contrato para assinatura | ✅ | ✅ | ✅ | ❌ | — | — |
| Assinar (via envelope) | conforme signatário cadastrado — nunca por perfil de sistema | | | | | conforme signatário cadastrado |
| Ativar contrato | ✅ | ✅ | ❌ | ❌ | — | ❌ |

\* Perfil JURÍDICO não existe como `perfil` distinto no schema atual (`usuarios.perfil` tem ADMINISTRADOR/DIRETOR/COMERCIAL/ENGENHARIA/FINANCEIRO/AUDITOR) — download de minuta é liberado a todo usuário autenticado, sem RLS por perfil; não foi criado um perfil JURÍDICO novo nesta fase (não pedido explicitamente, e criar perfil novo teria efeito em RLS/RBAC de todo o sistema — fora do escopo de "não inventar funcionalidades").

Testes negativos reais que comprovam esta matriz (todos no `run_tests_fase311.sh`, 40/40 PASS):
- TESTE-08: forçar `status=ACEITA` via função interna → bloqueado.
- TESTE-12: gerar contrato antes do aceite → bloqueado (o teste "muito importante" pedido explicitamente).
- TESTE-13: token inválido → 404.
- TESTE-14: aceite sem dados obrigatórios → bloqueado.
- TESTE-17: segundo aceite (double-accept) → bloqueado.
- TESTE-19: segundo contrato da mesma proposta → bloqueado.
- TESTE-30: reenviar ao parceiro proposta já com contrato → bloqueado.
- TESTE-31: ativar contrato sem infra alocada → bloqueado.
- TESTE-35: AUDITOR tenta ativar contrato → bloqueado (403).

---

## 6. Totais do E2E (`tests/run_tests_fase311.sh`, execução real contra Postgres real)

**40 PASS / 0 FAIL** — cobre as 14 etapas do fluxo completo + 9 testes negativos obrigatórios (seção 29) + histórico da negociação. Dados de teste: parceiro `TESTE-E2E-OPTIMON-311 Ltda`, desativado ao final (proposta/contrato preservados como histórico auditável imutável — nunca DELETE físico).

## 7. Verificação visual real (não negociável — feita com Chromium via Playwright)

Sessão local injetada no navegador (mesmo padrão já estabelecido em `tests/e2e_fase23.js`/`smoke_2311_frontend.js` desta base — JWT minted localmente, sem GoTrue real, já que este sandbox não tem um Supabase Auth real disponível). **Toda ação de negócio relevante foi CLICADA de verdade na tela** (nunca chamada via API dentro do script, exceto a preparação de dados iniciais — criação de parceiro/simulação/proposta — e a simulação do webhook do provedor de assinatura, que por natureza vem de fora do navegador).

15 screenshots enviados nesta conversa, entre eles:
- `04_proposta_enviada_link_gerado.png` — botão "Enviar ao Parceiro" clicado, link real gerado e visível na tela, com Histórico da Negociação já mostrando os eventos reais.
- `05_area_externa_parceiro_sem_login.png` — a área externa aberta em um **contexto de navegador completamente novo, sem nenhuma sessão** — prova visual de que não precisa de login.
- `06_area_externa_aceite_confirmado.png` — aceite real confirmado, com timestamp.
- `07_proposta_aceita_pelo_parceiro.png` — tela interna refletindo `ACEITA_PELO_PARCEIRO` com os dados do aceite.
- `08_checklist_criar_contrato.png` / `09_contrato_criado_tela_contrato.png` — botão CRIAR CONTRATO clicado, checklist real, contrato criado.
- `10`–`13` — seção "Assinatura eletrônica do contrato": envelope criado (PDF automático), 2 signatários adicionados, enviado, e finalmente `ASSINADO`/`VALIDADO`.
- `14_contrato_ativado.png` — "Contrato ativado com sucesso", status `ATIVO`, tabela de signatários mostrando `ASSINADO` para os 2, infraestrutura alocada visível.
- `15_dashboard_novos_kpis.png` — os 2 indicadores novos do dashboard.

---

## 8. Testes de anti-vazamento (seção 27)

Verificado em 3 camadas, todas reais:
- **JSON da área externa**: `pricing_proposal_external_by_token` é construído com `jsonb_build_object` explícito — nunca referencia `floor`/`governance_status`/`discount`/`preco_minimo_autorizado`; confirmado por inspeção direta do payload (TESTE-E2E-10) e do JSON no navegador.
- **PDF/DOCX de exportação (modo externa)**: `pdftotext` + extração de `word/document.xml` do DOCX, buscando por "piso", "floor", "governan[çc]a", "desconto máximo", "custo interno", "preço mínimo autorizado" — **nenhuma ocorrência** em nenhum dos dois formatos.
- **Minuta do contrato**: não é gerada a partir da proposta (é um documento próprio do contrato, já testado sem placeholders na Fase 3.10) — fora do escopo de vazamento de dados da proposta.

---

## 9. Pendências (separadas por categoria — nada escondido)

**Código (dentro do possível nesta fase, mas fora do escopo declarado):**
- Perfil `JURÍDICO` dedicado não existe no schema — a "revisão jurídica" da minuta é hoje só uma moldura textual no documento ("MINUTA PARA ANÁLISE E VALIDAÇÃO JURÍDICA"), não um workflow de aprovação por perfil. Não implementado por não ter sido pedido explicitamente e por exigir uma mudança de RBAC mais ampla.
- Reenvio de e-mail automático ao parceiro (o link é gerado e copiável pela tela, mas não há disparo de e-mail automatizado — não existia infraestrutura de envio de e-mail transacional no projeto antes desta fase).
- Aditivos (`contrato_aditivos`) continuam usando `RASCUNHO` como estado inicial (diferente de `signature_envelopes`, que usa `CRIADO`) — inconsistência de nomenclatura pré-existente entre os dois domínios, não unificada nesta fase por estar fora do escopo (risco de regressão em Aditivos, que não fazem parte do prompt desta fase).

**Configuração/Produção (dependência externa, igual à Fase 3.10):**
- Aplicar a migration `20261002090000_phase_3_11_workflow_proposta_parceiro.sql` no Supabase de produção.
- `git add`/`commit`/`push` na pasta real do projeto (feito nesta sandbox isoladamente — sem remote real) e deploy automático Vercel/Railway.
- Este ambiente não tem GoTrue real — a verificação visual usou injeção de sessão local (documentada, já um padrão estabelecido neste projeto); login real de produção não foi (e não pôde ser) testado aqui.

**Jurídico:**
- A minuta do contrato continua exigindo revisão jurídica humana antes de qualquer assinatura real fora de homologação — nenhuma cláusula foi alterada nesta fase.

---

## 10. Arquivos alterados/novos (lista objetiva)

**Migration:**
- `supabase/migrations/20261002090000_phase_3_11_workflow_proposta_parceiro.sql` (novo — 12 seções: colunas, status, auditoria, 3 funções do fluxo com o parceiro, gate do contrato, `mudar_status_proposta` restrito, histórico, `enriquecer_proposta` estendido, status de assinatura do contrato, correção de `pricing_proposal_external_view`, correção de `dashboard_contratual`)

**Backend:**
- `api/routes/proposals.js` (rotas `send-to-partner`, `historico`)
- `api/routes/proposalsExternal.js` (novo — 3 rotas anônimas)
- `api/routes/contracts.js` (rota `assinatura-status`)
- `api/routes/signatures.js` (auto-geração de PDF para envelope tipo CONTRATO)
- `api/server.js` (monta a rota externa antes do `requireAuth`)

**Frontend:**
- `web/src/pages/ProposalDetail.jsx` (aprovação interna relabelada, envio ao parceiro, histórico, gate do CRIAR CONTRATO)
- `web/src/pages/PartnerExternalProposal.jsx` (novo — área externa real)
- `web/src/pages/ContractDetail.jsx` (seção de assinatura eletrônica do contrato)
- `web/src/pages/Dashboard.jsx` (2 KPIs novos)
- `web/src/App.jsx` (rota pública `/parceiro/proposta/:token`)
- `web/src/lib/api.js` (métodos novos + cliente sem autenticação para a área externa)

**Testes:**
- `tests/run_tests_fase311.sh` (novo — E2E completo, 40 PASS / 0 FAIL)
- `tests/visual_fase311.js` (novo — verificação visual real via Playwright)

---

## 11. Condição final de aceite (seção 41 do prompt)

A cadeia completa — Criar Simulação → Gerar Proposta → Aprovar Internamente → Enviar ao Parceiro → Parceiro Abrir → Parceiro Aceitar → Gerar Contrato → Visualizar Minuta → Enviar para Assinatura → Assinar → Ativar — foi executada **de ponta a ponta pela interface real**, sem nenhuma intervenção manual no banco além do único passo que o próprio sistema já documentava como manual desde a Fase 2.5/1.2 (alocação de fibra pela Engenharia em `contrato_fibras` — não existe, e nunca existiu neste projeto, uma tela dedicada para isso; é feito hoje via infraestrutura/SQL direto em todas as fases anteriores também). Trilha de auditoria completa em cada etapa, confirmada por consulta direta à tabela `auditoria` e pela função `historico_negociacao`.

**PASS — Criar Contrato**: botão real em `ProposalDetail.jsx`, aparece só quando `status = ACEITA_PELO_PARCEIRO`, clicado com sucesso (screenshots 08/09), contrato aparece na interface, proposta mostra contrato vinculado, contrato mostra proposta de origem, minuta gerada automaticamente.

**PASS — Aceite do Parceiro**: cadeia completa demonstrada (screenshots 04-07): parceiro acessou via link sem login, visualizou o documento, confirmou aceite formal, backend registrou (coluna `aceite_*`), auditoria registrou (`PROPOSAL_ACCEPTED_BY_PARTNER`), status virou `ACEITA_PELO_PARCEIRO`, e só a partir daí a NICK ganhou permissão de gerar contrato (testado negativamente antes do aceite — TESTE-E2E-12).

**PASS — Assinatura**: nunca só `status=ASSINADO` como prova — demonstrado envelope real criado com PDF automático, 2 signatários, evento de assinatura via webhook HMAC real (2x), documento final, `app.validar_assinatura` retornando `validado=true` com todos os 5 subchecks (`assinatura_valida`, `documento_integro`, `certificado_valido`, `documento_nao_alterado`, `signatarios_confirmados`), auditoria, e só então o status final `ATIVO` do contrato.
