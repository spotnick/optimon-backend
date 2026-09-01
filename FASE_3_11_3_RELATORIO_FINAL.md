# OptiMon — Relatório Final — Fase 3.11.3
## Correção real do Resend + OTP + vínculo obrigatório do parceiro

Data: 31/08/2026
Execução: 99 testes automatizados de backend/banco (`tests/run_tests_fase311.sh`, exit code 0) + 7 checagens visuais reais em navegador (`tests/visual_fase3113.js`, Playwright/Chromium), ambos executados agora, do zero, para este relatório — não reaproveitados de memória.

---

## REGRA FUNDAMENTAL (seção 25) — como foi aplicada

Antes de escrever qualquer linha de código desta fase, foi feita auditoria real do repositório (grep completo por `resend`, `nodemailer`, `smtp`, `RESEND_API_KEY`, envio de e-mail) e uma pergunta direta ao usuário. A resposta confirmou: o Resend **já está configurado e pago**, mas hoje serve **apenas** como relay SMTP por trás do Supabase Auth (convite/redefinição de senha de usuários internos do OptiMon — tabela `auth.users`). Parceiros externos nunca recebem linha em `auth.users`, então esse caminho é estruturalmente inacessível para o fluxo de OTP de aceite de proposta. O usuário também confirmou que uma `RESEND_API_KEY` real já existe como variável de ambiente na Railway (produção), embora nenhum código do repositório jamais a tivesse lido.

Conclusão real: não faltava "integrar o Resend" — faltava o client HTTP direto que usa essa chave já existente para o caso de uso que o Supabase Auth não cobre. Foi isso que foi construído (`api/lib/emailService.js`), reaproveitando a chave e a infraestrutura já pagas, em vez de propor uma segunda integração paralela.

O mesmo princípio foi aplicado ao "parceiro obrigatório": o campo já era visualmente obrigatório no formulário antes desta fase, mas nada impedia — nem no backend, nem no banco — a criação de uma proposta sem `parceiro_id` por qualquer outro caminho (API direta, duplicação, versionamento, banco). Os três níveis foram auditados e corrigidos separadamente (ver bloco PARCEIRO OBRIGATÓRIO abaixo).

---

## BLOCO 1 — RESEND (seções 3–9)

| Item | Status |
|---|---|
| Configuração existente encontrada | **SIM** — Resend já configurado como SMTP do Supabase Auth; `RESEND_API_KEY` já existe na Railway (confirmado pelo usuário) |
| API utilizada (client HTTP direto implementado) | **SIM** — `api/lib/emailService.js`, `ResendEmailProvider`, chama `POST https://api.resend.com/emails` via `fetch` nativo (sem nova dependência) |
| E-mail realmente enviado (Resend real, neste ambiente de execução) | **NÃO** — este ambiente de sandbox não possui `RESEND_API_KEY`/`RESEND_FROM_EMAIL` reais; nenhuma chamada real ao Resend foi feita ou poderia ser feita aqui |
| E-mail realmente entregue (caixa de entrada real) | **NÃO** — mesma razão acima; depende do webhook real do Resend apontando para a Railway em produção |
| OTP confirmado (fluxo completo, ponta a ponta) | **SIM, mas via fallback DEV_LOG** — o fluxo completo (gerar OTP → "enviar" → recuperar o código → confirmar → `ACEITA_PELO_PARCEIRO`) foi provado 100% real neste ambiente, usando o canal de desenvolvimento (nunca o Resend real, porque a chave real não está disponível aqui) |

### O que foi provado de verdade nesta sandbox (execução real, não simulada)
- `buildEmailProvider()` nunca finge estar configurado: devolve `null` quando faltam as variáveis, e o sistema then usa o fallback `ConsoleDevNotifier` — que **recusa operar** (lança erro, não finge sucesso) se `APP_ENVIRONMENT=production` sem uma chave real (TESTE-89).
- `ResendEmailProvider.send()` foi testado com `fetch` mockado nos três cenários reais de uma chamada HTTP: sucesso (retorna `emailId`), rejeição do provedor (HTTP não-2xx → erro `RESEND_REJEITOU_ENVIO`), falha de rede (`RESEND_INDISPONIVEL`) — em nenhum caso a API key aparece na mensagem de erro (TESTE-88).
- A API key nunca vaza por serialização acidental (`JSON.stringify`, `Object.keys`) — testado diretamente (TESTE-87), corrigido nesta fase com `WeakMap` + getter, depois que um teste real pegou o vazamento com a implementação ingênua original.
- O webhook `/api/webhooks/resend` tem verificação real de assinatura Svix (`svix-id`.`svix-timestamp`.corpo bruto, HMAC-SHA256, tolerância de 5 min): assinatura válida é aceita (TESTE-91), assinatura adulterada é rejeitada com 401 (TESTE-92), ausência de `RESEND_WEBHOOK_SECRET` recusa processar com 500 controlado, nunca aceitando sem poder validar (TESTE-94).
- O fluxo principal real (Etapas 8–9 do E2E) gerou o OTP, "enviou" pelo canal disponível neste ambiente (DEV_LOG), gravou corretamente `email_status=EMAIL_SOLICITADO`/`email_canal=DEV_LOG` (TESTE-90), e o OTP foi de fato confirmado pelo parceiro (não apenas gerado — distinção exigida pela seção 8).
- Os estados `OTP_GERADO` / `EMAIL_SOLICITADO` / `EMAIL_ACEITO_PELO_RESEND` / `EMAIL_ENTREGUE` / `EMAIL_FALHOU` / `EMAIL_REJEITADO` existem como coluna própria (`email_status`) e nunca são confundidos com o status da tentativa/proposta em si — "OTP criado" e "e-mail enviado" são registros independentes, exatamente como a seção 8 exige.

### O que NÃO pôde ser provado aqui, e por quê
Esta sandbox de desenvolvimento não tem, e não pode ter, uma `RESEND_API_KEY` real nem acesso a uma caixa de e-mail real. Portanto o envio real ao Resend, a entrega real numa caixa de entrada, e o teste no domínio real de produção (`https://optimon.com.br`, seção 23) **não foram e não podiam ser executados neste ambiente**. Isto não é declarado como PASS. Para fechar este bloco de verdade, falta apenas: configurar `RESEND_API_KEY`/`RESEND_FROM_EMAIL`/`RESEND_WEBHOOK_SECRET` no ambiente real da Railway (a chave já existe, segundo o usuário — falta só `RESEND_FROM_EMAIL` com o domínio remetente real verificado no Resend, e o `RESEND_WEBHOOK_SECRET` do endpoint configurado no painel do Resend apontando para `https://<host-da-api>/api/webhooks/resend`) e repetir o teste E2E (seção 18) contra o ambiente real, recebendo o e-mail numa caixa real.

---

## BLOCO 2 — PARCEIRO OBRIGATÓRIO (seções 10–17)

| Camada | Status | Evidência |
|---|---|---|
| Frontend | **PASS** | Campo `Parceiro / Proponente *` obrigatório, `required`/`aria-required`, borda vermelha e aviso inline quando vazio, botão "Gerar Proposta" desabilitado sem parceiro — verificado em navegador real (Playwright), 7/7 checagens visuais PASS |
| Backend | **PASS** | `POST /api/proposals` valida formato antes de tocar o banco (`400 PARTNER_REQUIRED`) e a função de banco valida existência/atividade (`404 PARTNER_NOT_FOUND`, `400 PARTNER_INACTIVE`) — nunca confia no frontend |
| Banco | **PASS** | `CHECK (parceiro_id IS NOT NULL) NOT VALID` na tabela `propostas_comerciais` (bloqueia todo INSERT/UPDATE futuro sem revalidar/quebrar histórico); validação redundante dentro de `pricing_proposal_create`, `app.duplicar_proposta`, `app.criar_versao_proposta`; trigger `app.impedir_troca_parceiro_proposta` bloqueia troca de parceiro fora de `RASCUNHO` |
| Simulação → proposta | **PASS** | Mesma rota/função de criação (não existe tela de "conversão" separada nesta arquitetura) — bloqueada nas mesmas condições, testado tanto sem parceiro quanto com parceiro válido (caso feliz não quebrou) |
| Testes negativos (seção 17) | **7/7 PASS** (+ 1 variação extra também PASS) | ver tabela abaixo |

### Testes negativos obrigatórios (seção 17) — todos BLOQUEADOS como exigido

| # | Cenário exigido pela seção 17 | Teste | Resultado |
|---|---|---|---|
| 1 | Criar proposta sem parceiro (via interface/API) | TESTE-74 (`parceiro_id` ausente) / TESTE-75 (`parceiro_id` string vazia) | BLOQUEADO — `400 PARTNER_REQUIRED` |
| 2 | Criar proposta com parceiro inexistente | TESTE-76 | BLOQUEADO — `404 PARTNER_NOT_FOUND` |
| 3 | Criar proposta com parceiro inativo | TESTE-77 | BLOQUEADO — `400 PARTNER_INACTIVE` |
| 4 | Criar proposta sem parceiro via API (bypass da interface) | TESTE-78 (direto no Postgres, sem Node/API nenhum) | BLOQUEADO — `PARTNER_REQUIRED` mesmo pulando a API inteira |
| 5 | Gerar proposta a partir de simulação sem parceiro vinculado | TESTE-79 | BLOQUEADO |
| 6 | Alterar/remover parceiro de proposta já aceita | TESTE-81 (`ACEITA_PELO_PARCEIRO`) | BLOQUEADO — `PARTNER_LOCKED` |
| 7 | Alterar parceiro de proposta com contrato gerado | TESTE-82 (`CONTRATO_GERADO`) | BLOQUEADO — `PARTNER_LOCKED` |

Cobertura adicional (não exigida explicitamente pela seção 17, mas coerente com a seção 14 — duplicação/versionamento): duplicar (TESTE-83) ou criar nova versão (TESTE-84) de uma proposta histórica sem parceiro também é bloqueado.

### Levantamento real do banco (seção 13)
`SELECT count(*) FROM propostas_comerciais WHERE parceiro_id IS NULL` foi executado contra o banco real de teste: **3 propostas históricas** sem parceiro foram encontradas (dados de fases anteriores a esta correção). Elas foram **preservadas, nunca alteradas ou apagadas** — a constraint usa `NOT VALID` exatamente para não tocar histórico. IDs e status ficam registrados no log de execução da suíte (`TESTE-85`); qualquer decisão de regularizar esses 3 registros históricos é uma decisão de negócio do usuário, não uma correção técnica automática.

---

## BLOCO 3 — E2E (seções 18–19)

| Métrica | Valor |
|---|---|
| TOTAL de testes automatizados na suíte completa (Fase 3.11 + 3.11.2 + 3.11.3, sem regressão) | 99 |
| PASS | 99 |
| FAIL | 0 |
| PARTIAL | 0 |
| DEPENDÊNCIA EXTERNA (não executável nesta sandbox) | Envio/recebimento real via Resend + teste no domínio de produção `optimon.com.br` (seção 23) — depende de credenciais reais da Railway/Resend, fora do alcance deste ambiente |

O fluxo E2E completo da seção 18 foi executado de ponta a ponta contra a aplicação real (Postgres real + PostgREST + API Express real + frontend React real via Playwright para a parte visual, curl real para a parte de API): criação de parceiro de teste → simulação → proposta → aprovação interna → envio ao parceiro → link externo → preenchimento do representante → solicitação de OTP → geração e registro do OTP → confirmação do OTP → `ACEITA_PELO_PARCEIRO` → auditoria registrada → geração de contrato → vínculo proposta↔contrato confirmado. A única etapa que, nesta sandbox, usa o canal DEV_LOG em vez do Resend real é exatamente a etapa de envio do e-mail (por ausência de credencial real) — todas as demais 17 etapas são reais e passaram.

Testes negativos do E2E (seção 19) — todos confirmados:
- Abrir o link externo **não** marca como aceita (TESTE do fluxo principal, estado permanece `ENVIADA_AO_PARCEIRO`/`VISUALIZADA_PELO_PARCEIRO` até o OTP real).
- Preencher o formulário **não** marca como aceita.
- OTP errado, expirado ou reutilizado **não** marca como aceita (suíte da Fase 3.11.2, reexecutada sem regressão nesta fase).
- Proposta sem parceiro **não** chega a ser criada (bloco 2 acima).

Nenhuma regressão: os testes das Fases 3.11 e 3.11.2 (fluxo de aceite/OTP/assinatura anteriores a esta correção) continuam passando sem alteração.

---

## Segurança e exposição de dados (seções 20–22)

- O OTP em texto puro nunca é logado, nunca aparece na resposta HTTP, nunca é persistido em texto puro no banco (hash + pepper, mesmo padrão já existente antes desta fase — preservado integralmente).
- `RESEND_API_KEY` nunca aparece em log, resposta de API, ou serialização de objeto (testado e corrigido nesta fase — ver TESTE-87).
- O template de e-mail usa apenas nome, número da proposta, proponente e o próprio OTP — nenhum dado de piso técnico/margem/governança/campo interno (`NICK`) é incluído.
- Nada do que já funcionava foi alterado além do necessário: fluxo de OTP, segurança existente, token externo, revogação, auditoria, proposta externa, contrato, assinatura e identidade visual permanecem intactos (confirmado pelos 71 testes pré-existentes continuando 100% verdes).

---

## CRITÉRIO DE CONCLUSÃO — avaliação item a item

1. Não é possível criar proposta sem parceiro, por nenhum caminho testado (frontend, API, duplicação, versionamento, simulação, banco direto) — **PASS**
2. Toda proposta válida tem parceiro vinculado — **PASS**
3. OTP é gerado corretamente — **PASS**
4. O OptiMon efetivamente usa o Resend já configurado (client real implementado e testado, não mais só um placeholder de log) — **PASS**
5. O Resend aceita o envio — **NÃO PROVADO NESTA SANDBOX** (sem credencial real disponível aqui; código pronto e testado com mocks, falta ativar em produção)
6. O e-mail chega ao destinatário real — **NÃO PROVADO NESTA SANDBOX** (mesma razão)
7. O parceiro usa o OTP — **PASS** (provado ponta a ponta via canal DEV_LOG neste ambiente)
8. A aceitação é registrada — **PASS**
9. A auditoria é registrada — **PASS**
10. O contrato é bloqueado antes da aceitação — **PASS** (regra preexistente, confirmada sem regressão)
11. O contrato pode ser gerado após a aceitação — **PASS**
12. Nenhum dado interno (NICK) é exposto — **PASS**

**Resultado consolidado: PASS em 10 de 12 condições, comprovado com execução real nesta sandbox. As 2 condições restantes (itens 5 e 6 — envio e entrega reais pelo Resend) exigem credenciais reais de produção que não existem neste ambiente de desenvolvimento; não são declaradas como PASS só porque o código está pronto e testado com mocks — conforme a instrução explícita da seção 25/CRITÉRIO DE CONCLUSÃO de nunca declarar PASS apenas porque o endpoint respondeu positivamente em teste controlado.**

---

## Para fechar 100% (ação do usuário, fora do alcance desta sandbox)

1. Confirmar/definir `RESEND_FROM_EMAIL` com um domínio realmente verificado no painel do Resend (nunca inventado por aqui).
2. Confirmar que `RESEND_API_KEY` já presente na Railway é válida (pode ser checada com `testConnection()`, já implementado em `emailService.js`, sem gastar cota).
3. Criar o webhook no painel do Resend apontando para `https://<host-da-api-em-produção>/api/webhooks/resend`, copiar o `RESEND_WEBHOOK_SECRET` gerado e configurá-lo na Railway.
4. Repetir o teste E2E da seção 18 contra o domínio real `https://optimon.com.br` (seção 23), com um parceiro de teste real recebendo o e-mail numa caixa de entrada real.
5. Só então declarar PASS os itens 5 e 6 do critério de conclusão.

---

## Arquivos desta fase

Novos: `supabase/migrations/20261004090000_phase_3_11_03_resend_real_parceiro_obrigatorio.sql`, `api/lib/emailService.js`, `api/lib/otpEmailTemplate.js`, `api/routes/emailWebhooks.js`, `tests/visual_fase3113.js`.
Reescritos: `api/lib/otpNotifier.js`.
Modificados: `api/routes/proposalsExternal.js`, `api/routes/proposals.js`, `api/server.js`, `api/.env.example`, `web/src/pages/NewSimulation.jsx`, `tests/run_tests_fase311.sh`.

Todos sincronizados nesta sessão para `E:\OneDrive\Downloads\Projetos Claude\OptiMon - Cessão de Rede\optimon\` (sem conflitos de edição detectados).
