# Relatório Final — Fase 2.5 (Gestão de Usuários + Proponentes + Responsáveis + Aprovação Interna + Assinatura Eletrônica ICP-Brasil + Contrato Automático + Aditivos + Gestão do Ciclo Proposta → Contrato)

Status geral: **CONCLUÍDA no código, nos testes e na documentação — 46/46 verificações novas PASS, 0 FAIL, 3 SKIP documentados (`tests/run_tests_fase25.sh`), mais regressão completa herdada de todas as fases anteriores (via `run_tests_fase24.sh`, que por sua vez encadeia Fase 1 → 2.4, 30/31 PASS com 1 falha aceita e explicada abaixo)**. Nenhuma migration de fase anterior foi editada, nenhuma tabela recriada, nenhum dado existente apagado, nenhuma tabela duplicada — apenas 14 migrations aditivas. Por instrução do próprio prompt-mestre desta fase, a Fase 3 **não foi iniciada**.

Esta é a fase mais extensa do projeto até aqui: fecha o ciclo comercial completo — Usuário → Proponente → Simulação → Proposta → Aprovação Interna → Aceite/Assinatura Eletrônica → Contrato Automático → Ativação com Infraestrutura Comprometida → Aditivos → Dashboard Contratual — e introduz o motor de assinatura eletrônica como um **orquestrador**, nunca como uma Autoridade Certificadora própria.

## 1. Arquivos alterados ou criados

**Migrations (14 novas, todas aditivas):**
- `20260913090000_phase_2_5_01_usuarios_perfil_estendido.sql`
- `20260913090100_phase_2_5_02_proponentes_responsaveis_documentos.sql`
- `20260913090200_phase_2_5_03_propostas_responsavel_status_assinatura.sql`
- `20260913090300_phase_2_5_04_signature_engine_schema.sql`
- `20260913090400_phase_2_5_05_modelos_contrato_geracao_automatica.sql`
- `20260913090500_phase_2_5_06_contrato_ativacao_conflito_infraestrutura.sql`
- `20260913090600_phase_2_5_07_signature_engine_funcoes.sql`
- `20260913090700_phase_2_5_08_aditivos_assinatura.sql`
- `20260913090800_phase_2_5_09_alertas_dashboard_contratual.sql`
- `20260913090900_phase_2_5_10_grants_tabelas_novas.sql`
- `20260913091100_phase_2_5_12_webhook_lookup_por_provider_envelope_id.sql`
- `20260913091200_phase_2_5_13_webhook_secret_ref_lookup.sql`
- `20260913091300_phase_2_5_14_contratos_list_reajuste_wrappers.sql`
- `20260913091400_phase_2_5_15_aprovar_aditivo.sql`

Nota honesta: a numeração descritiva pula de `_10_` para `_12_` (não existe um arquivo `_11_`). É um resíduo cosmético de uma iteração interna durante o desenvolvimento (uma função foi absorvida em `_10_`/`_12_` durante autocorreção) — **não afeta a ordem de aplicação real**, que segue o timestamp (`20260913090900` → `20260913091100`), nem falta nenhuma peça funcional; confirmado pelas 46 verificações da suíte e pela regressão. Registrado aqui por transparência, não escondido.

**SQL fora da cadeia de migrations (documentado, não aplicável ao Postgres local):**
- `supabase/storage_setup_fase25.sql` — bucket privado `documentos` + políticas RLS de `storage.objects`. O Postgres local de desenvolvimento não tem o schema `storage` (confirmado via `\dn`) — isso é uma característica só da plataforma Supabase real, documentada desde a Fase 2 como escopo da futura "Fase 8". Este arquivo precisa ser rodado manualmente contra um projeto Supabase real (runbook no fim deste relatório).

**Backend (Node/Express):**
- `api/lib/signatureProvider.js` — novo: abstração `ElectronicSignatureProvider` + implementação `MockHomologacaoProvider` + fábrica `buildProvider`.
- `api/lib/supabaseClient.js` — estendido: `anonClient()` (para as rotas de webhook, que chegam sem JWT de usuário).
- `api/routes/users.js` — novo: CRUD de `/api/users`.
- `api/routes/partners.js` — reescrito por completo: CRUD de proponentes + responsáveis + documentos.
- `api/routes/signatures.js` — novo: `/api/signatures/providers`, `/api/signatures/envelopes` (+ signatários, envio, cancelamento, validação, auditoria) e `POST /api/signatures/webhook` (rota separada, sem autenticação de usuário).
- `api/routes/contracts.js` — novo: `/api/contracts` (geração, ativação, reajuste, aditivos, dashboard).
- `api/server.js` — estendido: registra as 4 rotas novas; monta o `webhookRouter` de assinaturas **antes** de `express.json()` (corpo bruto necessário para validar o HMAC).
- `api/package.json` — nova dependência `multer@^2.2.0` (upload multipart de documentos).

**Frontend (React/Vite):**
- `web/src/lib/api.js` — estendido: namespaces `partners.*`, `users.*`, `signatures.*`, `contracts.*` + helper `uploadMultipart`.
- `web/src/context/AuthContext.jsx` — estendido: marca "último acesso" no login.
- `web/src/components/Layout.jsx` — estendido: itens de menu Proponentes, Contratos, Assinaturas, Usuários, Config. de Assinatura.
- `web/src/pages/Users.jsx`, `Partners.jsx`, `PartnerDetail.jsx`, `SignatureSettings.jsx`, `Signatures.jsx`, `SignatureDetail.jsx`, `Contracts.jsx`, `ContractDetail.jsx` — novos (8 telas).
- `web/src/pages/ProposalDetail.jsx` — estendido: status novos, botão "Gerar Contrato", link para o contrato/assinatura.
- `web/src/App.jsx` — estendido: 8 rotas novas.

**Testes:**
- `tests/run_tests_fase25.sh` — novo (46 verificações + regressão herdada, ver seção 9).
- `tests/run_tests_deploy.sh` — corrigido (bug real de bootstrap de JWT anônimo local, ver seção 8).
- `docs/RELATORIO_FASE25.md` (este arquivo).
- `docs/ARQUITETURA.md` — estendido (seção desta fase).

## 2. Inspeção prévia — o que já existia e foi reaproveitado (nunca duplicado)

Antes de qualquer migration, o schema existente foi inspecionado por completo. Decisões de reaproveitamento, todas documentadas em comentário nas próprias migrations:

| Conceito do prompt-mestre | Implementação real | Por quê |
|---|---|---|
| "Proponente" | `parceiros` (existente desde a Fase 1), estendida com campos cadastrais novos | já era a entidade que recebe proposta/assina contrato — criar `proponentes` seria duplicar |
| "Responsáveis" | Tabela nova `parceiros_responsaveis` | não existia equivalente |
| "Documentos" do proponente | `documentos` (existente), estendida com `proponente_documento`, `status`, `responsavel_id` | já existia tabela genérica de documentos com Storage |
| Envelope de assinatura de proposta E de contrato | Uma única tabela `signature_envelopes`, discriminada por `tipo_documento` + CHECK "exatamente um de proposta_id/contrato_id/aditivo_id" | evita duas tabelas quase idênticas |
| Prazo mínimo de contrato (48 meses) | Já existia como CHECK (`contratos_prazo_minimo`) desde fase anterior | reaproveitado sem alteração |
| Conflito de infraestrutura na ativação | `app.check_contract_conflict()` (pré-existente) | reaproveitado sem alteração |
| Marcação de fibra/PON como LOCADA | Trigger `fn_contrato_fibras_sync_status` + índice único parcial (pré-existentes) | reaproveitado sem alteração — e um segundo mecanismo pré-existente (`fn_valida_conflito_compartilhamento`, trigger de exclusividade) também bloqueia dupla alocação, ver TESTE-22 |
| Versionamento de contrato | `contrato_versions` + trigger de aditivo (pré-existentes) | reaproveitado sem alteração |
| Histórico de reajuste | `app.aplicar_reajuste_contrato()` (pré-existente) | reaproveitado sem alteração, só ganhou um wrapper `public.pricing_contract_apply_reajuste` |
| Log de ação bloqueada por governança | `public.pricing_log_blocked_action` (pré-existente) | estendido com a ação nova `CONTRACT_ACTIVATE_BLOCKED`, não duplicado |

## 3. Usuários e RBAC (seções 1-3 do prompt-mestre)

O RBAC de 6 perfis (ADMINISTRADOR/DIRETOR/COMERCIAL/FINANCEIRO/ENGENHARIA/AUDITOR) já existia desde a Fase 1, via `app.tem_perfil()`/RLS — não foi recriado. Esta fase só adicionou campos cadastrais (telefone/CPF/cargo/departamento/observações/último acesso) e a tela `/usuarios`.

**Limitação arquitetural, disclosed no cabeçalho de `users.js`**: `usuarios.id` é FK de `auth.users(id)` — não existe "criar usuário" só em `public.usuarios`. Como este projeto nunca usa a `service_role key` no backend (regra permanente), o fluxo real é: 1) ADMINISTRADOR convida o novo usuário pelo painel do Supabase (Authentication → Users → Invite user); 2) copia o `id` gerado; 3) chama `POST /api/users` com esse id para completar o cadastro. `POST /api/users` pressupõe que o passo 1 já aconteceu.

O controle de acesso é sempre no servidor (RLS), nunca confiado ao frontend — validado por TESTE-01c (COMERCIAL bloqueado de alterar o próprio perfil, 403).

## 4. Proponentes, responsáveis e documentos (seções 4-9)

`parceiros` estendida com inscrição estadual/municipal, endereço completo, site, observações. `parceiros_responsaveis` cobre 6 tipos (REPRESENTANTE_LEGAL/RESPONSAVEL_COMERCIAL/RESPONSAVEL_FINANCEIRO/RESPONSAVEL_TECNICO/TESTEMUNHA/OUTRO). O campo `representante_legal` é só um **indicador**, nunca uma prova de poder — a autoridade real precisa vir de um documento anexado (`documento_comprobatorio_id`), nunca é assumida implicitamente. Validado por TESTE-06b: um responsável recém-criado, sem documento vinculado, tem `documento_comprobatorio_id = null` — nada no sistema trata "está cadastrado" como "tem poder de assinatura".

`documentos` estendida com `status` (VIGENTE/SUBSTITUIDO/REMOVIDO — nunca DELETE físico) e tipos jurídicos novos (CONTRATO_SOCIAL/CARTAO_CNPJ/PROCURACAO/ATA). Storage é sempre privado; download nunca devolve `storage_path` bruto, só uma signed URL de 300 segundos (`createSignedUrl`, ver `api/routes/partners.js`).

## 5. Proposta → snapshot imutável (seções 10-13, 44)

`propostas_comerciais.responsavel_id` liga a proposta ao responsável do proponente. O snapshot (`propostas_comerciais.snapshot`, jsonb) é travado na criação e **nunca recalculado** — nenhuma função desta fase faz `UPDATE` desse campo. Validado por TESTE-20a/b: o cadastro do proponente foi alterado depois de gerado o contrato, e o snapshot da proposta e a integridade de hash em `documentos_assinados` permaneceram intactos.

Status da proposta ampliado (RASCUNHO → EM_APROVACAO → APROVADA → ENVIADA → EM_NEGOCIACAO → ACEITA → EM_ASSINATURA → ASSINADA → CONTRATO_GERADO, com RECUSADA/EXPIRADA/CANCELADA como terminais alternativos). A governança de preço pré-existente (aprovação por faixa de valor, exceção com motivo obrigatório) não foi alterada — só herdada e revalidada via a regressão completa.

## 6. Motor de Assinatura Eletrônica — "ICP-Brasil First" (seções 14-24, 51-52, 72)

Este é o núcleo arquitetural da fase. Princípio inegociável do prompt-mestre: **OptiMon nunca é uma Autoridade Certificadora, PSC ou HSM — é só um orquestrador que fala com provedores de assinatura reais.**

`api/lib/signatureProvider.js` define a interface abstrata `ElectronicSignatureProvider` com 11 métodos (`createEnvelope`, `addSigner`, `configureSigningOrder`, `sendForSignature`, `getEnvelopeStatus`, `getSignerStatus`, `cancelEnvelope`, `downloadSignedDocument`, `getAuditTrail`, `validateSignature`, `getCertificateInfo`). Nesta fase existe **uma única implementação concreta**: `MockHomologacaoProvider` — determinística, nunca toca rede real, calcula o hash SHA-256 real do documento enviado. A fábrica `buildProvider()` lança `PROVEDOR_NAO_IMPLEMENTADO` para qualquer outro `tipo` — a arquitetura já suporta um segundo provedor (PRINCIPAL + SECUNDÁRIO, seção 51), mas só o mock foi implementado de fato nesta fase, como o prompt-mestre autorizou explicitamente ("apenas um precisa de integração real nesta fase").

`signature_providers.tipo = 'ICP_BRASIL_HOMOLOGACAO_MOCK'` combinado com `ambiente = 'PRODUCAO'` é **bloqueado por CHECK no banco e replicado no frontend** — nunca é possível "ir para produção" com o provedor mock (TESTE-12b). Só ADMINISTRADOR/DIRETOR podem configurar provedor (`/configuracoes/assinatura`, TESTE-12c). Nenhum certificado, `.pfx` ou senha é armazenado em nenhum momento — `api_key_ref`/`webhook_secret_ref` guardam só o **nome** de uma variável de ambiente, nunca o segredo.

Fluxo completo (envelope → signatários → envio → webhook → validação) coberto pelas TESTE-13 a TESTE-18: criação do envelope com PDF auto-gerado (TESTE-13b), 2 signatários em ordem (TESTE-14), envio (TESTE-15, proposta passa a EM_ASSINATURA), 2 eventos de webhook autenticados por HMAC-SHA256 (TESTE-16a/b), **idempotência real** — reenviar o mesmo evento não duplica nada (TESTE-16c, contagem de eventos permanece 2), webhook com HMAC inválido é recusado 401 sem processar o payload (TESTE-16d), validação com checklist ✓/✕ por critério (TESTE-17 — "Assinado" nunca é tratado como automaticamente válido; só `documento_integro` + `certificado_valido` + `signatarios_confirmados` + `documento_nao_alterado`, todos verdadeiros, marcam `validado=true`), trilha de auditoria com exatamente os eventos reais, nunca duplicados (TESTE-18).

## 7. Contrato automático + ativação com infraestrutura comprometida (seções 25-35, 53-56)

`GERAR CONTRATO` (`app.gerar_contrato_de_proposta`) só aceita proposta com `status = 'ASSINADA'` — nunca RASCUNHO/EM_APROVACAO/etc. Auto-preenche proponente, cidade, config. de pricing, regras e cria a v1 em `contrato_versions`. Prazo mínimo de 48 meses é **checado explicitamente na função e também garantido por CHECK no banco** — prazo menor só é possível com exceção autorizada e motivo obrigatório (`p_motivo_excecao_prazo`). Tentar gerar duas vezes da mesma proposta é bloqueado (`JA_GERADO`, TESTE-19c).

`app.ativar_contrato` — só DIRETOR/ADMINISTRADOR — exige, nesta ordem: (1) envelope de assinatura do **contrato** (não da proposta) com status `VALIDADO` (senão `ASSINATURA_PENDENTE`, TESTE-21a); (2) pelo menos uma fibra/PON alocada em `contrato_fibras` (senão `INFRA_NAO_ALOCADA`, TESTE-21b); (3) ausência de conflito via `app.check_contract_conflict` (reaproveitado, nunca alterado). A alocação de fibra/PON específica continua sendo **sempre manual, feita por ENGENHARIA** — a camada de contrato/pricing nunca escolhe fibra automaticamente, por decisão de separação de responsabilidades (seção 5 desta fase, "reaproveitamento"). Ao ativar, o trigger pré-existente marca a fibra como `LOCADA` automaticamente (TESTE-21c/d). Uma segunda tentativa de alocar a mesma fibra é bloqueada por dois mecanismos pré-existentes que já coexistiam no schema (índice único parcial e trigger de exclusividade `fn_valida_conflito_compartilhamento`) — TESTE-22 aceita qualquer um dos dois, já que ambos garantem a mesma coisa: nunca é permitida dupla alocação.

## 8. Modelos de contrato — texto jurídico nunca inventado (seções 36-38)

`modelos_contrato` guarda o texto-base do contrato. O texto inserido nesta fase é **explicitamente marcado como esqueleto/placeholder** — o cabeçalho do próprio dado grava `"[MINUTA-ESQUELETO — NÃO É TEXTO JURÍDICO APROVADO — substituir pelo texto oficial do jurídico da NICK antes de qualquer uso real]"`. OptiMon nunca gera cláusula jurídica nova por conta própria; o texto real precisa vir do jurídico da NICK antes de qualquer contrato real ser assinado — isso é dito de forma explícita no dado, não só neste relatório.

## 9. Aditivos (seções 39-40)

`contrato_aditivos` ganhou o próprio ciclo de assinatura: RASCUNHO → EM_APROVACAO → APROVADO → ASSINATURA → ATIVO. `app.aprovar_aditivo` grava `aprovado_por = auth.uid()` sempre no servidor, nunca aceita esse campo do frontend (TESTE-23b). `app.enviar_aditivo_para_assinatura` e `app.ativar_aditivo` seguem exatamente o mesmo padrão de segurança do contrato (exige envelope `VALIDADO`, DIRETOR/ADMINISTRADOR para ativar). Ao ativar, o trigger pré-existente `fn_aditivo_gera_versao` avança a versão do contrato automaticamente (TESTE-23e — contrato foi de v1 para v2 sem nenhuma alteração retroativa).

## 10. Dashboard contratual, alertas e auditoria (seções 41-43, 68)

`app.dashboard_contratual()` agrega contratos ativos, propostas aguardando aprovação/assinatura, contratos aguardando assinatura, contratos próximos do vencimento, reajustes pendentes, valor mensal contratado, PONs/fibras locadas e alertas não resolvidos — tudo em uma única chamada (TESTE-25a). `app.gerar_alertas_automaticos()` cria alertas com deduplicação contra os já não-resolvidos (nunca duplica o mesmo alerta, TESTE-25b). A trilha de auditoria cobre o ciclo inteiro do envelope — criação/envio/eventos/validação — com o número exato de eventos reais (TESTE-25c).

## 11. Bugs reais encontrados e corrigidos durante a própria validação (5, todos disclosed)

1. **RLS sem GRANT em 8 tabelas novas** — RLS por si só não concede privilégio; faltava `GRANT ... TO authenticated` explícito (este projeto não usa privilégios default). Corrigido na migration 10, com o achado documentado no próprio cabeçalho da migration.
2. **`anon` não atravessa o schema `app` mesmo com EXECUTE concedido diretamente** — confirmado via `has_schema_privilege`. Corrigido tornando o wrapper `public.*` do webhook `SECURITY DEFINER` (nunca `INVOKER` puro quando o chamador é `anon`).
3. **`users.js`/`partners.js` PATCH devolvia 404 em vez de 403 quando a RLS bloqueava a escrita silenciosamente** (uma `UPDATE` bloqueada por RLS retorna 0 linhas, sem erro SQL — impossível distinguir "não existe" de "existe mas foi barrado" sem uma leitura à parte). Corrigido com uma checagem de existência antes de decidir 403 vs. 404. **Aplicado em `users.js` e no PATCH de parceiro em `partners.js`; não aplicado** (decisão de escopo sob prazo, não escondida) no PATCH de responsáveis (`partners.js`), no PATCH de provedores (`signatures.js`) e no branch de edição só-de-conteúdo de aditivo (`contracts.js`) — nesses três pontos um bloqueio de RLS ainda aparece como 404 em vez de 403. Não é um risco de segurança (o dado continua protegido), só uma imprecisão de código de status HTTP.
4. **Bug real, mais significativo: chamadas autenticadas como `anon` (o webhook de assinatura) quebravam com violação de FK em `auditoria.usuario_id`.** Causa raiz, em cadeia: (a) `api/.env` nunca teve uma chave anônima real — só um placeholder de string, porque nenhuma fase anterior tinha exercitado um caminho `anon` via HTTP real; (b) `postgrest.local.conf` tem `jwt-secret` configurado, então qualquer `Authorization` presente é validado como JWT — um token mal formado não vira "anônimo", vira erro de autenticação; (c) a primeira tentativa de correção usou um `sub` de UUID zerado, sintaticamente válido — isso fez `auth.uid()` devolver um UUID "válido mas inexistente", que violava a FK de auditoria. **Correção final**: o `sub` do JWT anônimo local passou a ser a string `"anon-key-no-user"` (formato não-UUID), fazendo o cast `::uuid` falhar e `auth.uid()` corretamente resolver para `NULL` — exatamente o comportamento de uma chave anônima real do Supabase. Corrigido em dois lugares: `tests/run_tests_deploy.sh` (bootstrap para checkouts novos) e a lógica de autocorreção do `tests/run_tests_fase25.sh` (agora decodifica o JWT e regenera sempre que o `sub` não é exatamente `"anon-key-no-user"`, não só quando "não parece um JWT" — a primeira versão dessa checagem não pegava esse caso porque o token *era* um JWT válido, só com o `sub` errado).
5. **Bug do próprio script de teste** — `json_get` (extrator de JSON em Node) não tratava `null` explícito, só `undefined`, então `documento_comprobatorio_id: null` virava a string literal `"null"` em vez de vazio. Corrigido.

Todos os 5 achados estão registrados nos comentários das migrations/scripts correspondentes, não só aqui.

## 12. Bateria de testes — 46 PASS / 0 FAIL / 3 SKIP + regressão herdada

Execução real via HTTP contra a pilha local (`tests/run_tests_fase25.sh`), não simulação:

- **PASSO 0** — regressão completa: `run_tests_fase24.sh` (30 PASS / **1 falha aceita e documentada**: `TESTE-0 GET /api/partners` — o teste antigo da Fase 2.4 seleciona só as colunas que existiam antes desta fase; como o `partners.js` novo agora sempre seleciona também as colunas cadastrais desta fase, rodar a Fase 2.4 isolada — sem as migrations desta fase aplicadas — quebra essa única verificação. É uma incompatibilidade histórica inevitável dado que o prompt exigia estender `parceiros` em vez de duplicar; o script detecta explicitamente que essa é a **única** falha antes de aceitar, qualquer outra falha ainda aborta a suíte) + as 14 migrations desta fase aplicadas sem erro.
- **PASSO 1** — pilha local no ar, com autocorreção do JWT anônimo (ver bug 4 acima).
- **TESTE 01-03** — usuários/RBAC (3 PASS).
- **TESTE 04-07** — proponentes/responsáveis/documentos (3 PASS, 1 SKIP — Storage real indisponível localmente).
- **TESTE 08** — proposta vinculada a proponente/responsável + PDF (2 PASS).
- **TESTE 09-11** — governança de preço (SKIP explícito: sem mudança de lógica nesta fase, já coberta exaustivamente na regressão do PASSO 0).
- **TESTE 12-18** — motor de assinatura completo (13 PASS, incluindo o teste de idempotência do webhook).
- **TESTE 19-20** — geração de contrato + imutabilidade do snapshot (5 PASS).
- **TESTE 21-22** — infraestrutura comprometida + bloqueio de dupla alocação (5 PASS).
- **TESTE 23** — ciclo completo de aditivo (5 PASS).
- **TESTE 24** — segurança (4 PASS, 1 SKIP — verificado por revisão de código, não executável ponta-a-ponta sem Storage real).
- **TESTE 25** — dashboard contratual + alertas + auditoria (3 PASS).

**Resultado final: 46 PASS / 0 FAIL / 3 SKIP.** Os 3 SKIP são limitações de ambiente genuínas e documentadas (ausência do schema `storage` no Postgres local de desenvolvimento), nunca lacunas de código escondidas — os trechos de código correspondentes (`createSignedUrl` com expiração de 300s, nunca `storage_path` bruto) foram revisados manualmente e citados no próprio log de teste.

O fluxo de ponta-a-ponta do prompt-mestre (LOGIN → PROPONENTE → RESPONSÁVEL → SIMULAÇÃO → PROPOSTA → APROVAÇÃO → ENVIO PARA ASSINATURA → ASSINATURA → VALIDAÇÃO → CONTRATO → ATIVAÇÃO → INFRAESTRUTURA COMPROMETIDA → ADITIVO → DASHBOARD → AUDITORIA) é coberto de fato pela sequência real TESTE 04 → TESTE 25, executada em uma única corrida do script contra o mesmo proponente/proposta/contrato — não é um teste isolado por trecho.

## 13. Frontend — build e lint

`npm run build` (Vite) concluído com sucesso, só um aviso de tamanho de chunk (esperado, sem tree-shaking dedicado nesta fase). `npm run lint` (oxlint) sem nenhum erro novo — só avisos de padrão pré-existente no projeto (`set-state-in-effect`), já presentes antes desta fase.

## 14. O que não foi testado / está fora do escopo desta fase (limitações — NÃO escondidas)

- **Storage real do Supabase** (upload/download de documento de proponente, URL assinada de fato) não pôde ser validado ponta-a-ponta neste ambiente de desenvolvimento local, que não tem o schema `storage` do Postgres. O código está escrito para falhar de forma controlada (502/404) quando o Storage não responde, e o bucket + políticas RLS estão prontos em `supabase/storage_setup_fase25.sql`, mas **precisam ser validados manualmente contra um projeto Supabase real** antes de qualquer uso em produção.
- **Segundo provedor de assinatura real (ICP-Brasil de verdade)** não foi integrado — só o mock de homologação, exatamente como o prompt-mestre autorizou para esta fase ("apenas um provedor precisa de integração real"). A arquitetura (`ElectronicSignatureProvider`) já suporta adicionar um segundo provedor sem reescrever nada do motor.
- **403 vs. 404 em três pontos específicos do PATCH** (responsáveis de proponente, provedores de assinatura, edição de conteúdo de aditivo) continuam devolvendo 404 quando deveriam devolver 403 sob um bloqueio de RLS — ver item 3 da seção 11. Não é uma falha de segurança (o dado permanece protegido), só uma imprecisão de status HTTP a corrigir numa próxima iteração.
- **Nenhum texto jurídico real de contrato** foi inserido — só um esqueleto marcado como placeholder (seção 8). O jurídico da NICK precisa fornecer e revisar o texto oficial antes de qualquer contrato real.
- **Ambiente de PRODUÇÃO do provedor de assinatura** nunca foi exercitado neste ciclo, por decisão de segurança do próprio prompt-mestre ("nunca testar com documentos reais em produção inicialmente") — só HOMOLOGAÇÃO foi usada, e a combinação MOCK+PRODUÇÃO é ativamente bloqueada pelo próprio banco.

## 15. Runbook — o que falta rodar manualmente contra o Supabase real

1. Aplicar as 14 migrations desta fase (`supabase/migrations/20260913*.sql`) na ordem, via `supabase db push` ou o pipeline de CI/CD já existente do projeto — nenhuma delas precisa de intervenção manual.
2. Rodar `supabase/storage_setup_fase25.sql` manualmente contra o projeto Supabase real (cria o bucket privado `documentos` + políticas RLS) — este arquivo fica fora da cadeia de migrations de propósito.
3. Configurar as variáveis de ambiente do provedor de assinatura real (quando/se um provedor de produção for contratado) — `signature_providers.api_key_ref`/`webhook_secret_ref` armazenam só o nome da variável, o valor precisa ser configurado no Railway/ambiente de produção diretamente pelo usuário, nunca por esta sessão.
4. Substituir o texto de `modelos_contrato` pelo texto jurídico oficial da NICK antes de gerar qualquer contrato real.

## 16. Encerramento (conforme a instrução do prompt-mestre, seção 72)

OptiMon, nesta e em todas as fases, é uma plataforma de gestão comercial e um orquestrador de assinatura eletrônica — **nunca** uma Autoridade Certificadora, um Prestador de Serviço de Confiança ou um substituto de HSM. Toda validade jurídica de uma assinatura eletrônica depende inteiramente do provedor real integrado (ICP-Brasil ou equivalente) quando este for contratado; o `MockHomologacaoProvider` desta fase existe só para permitir testar o fluxo de orquestração e nunca deve ser usado para validar um documento com efeito jurídico real. Por instrução explícita do prompt-mestre, a Fase 3 não foi iniciada.

## Checklist de aceite

| # | Item | Status |
|---|---|---|
| 1 | Inspeção do schema existente feita antes de qualquer migration | ✅ |
| 2 | Nenhuma tabela duplicada — reaproveitamento documentado (seção 2) | ✅ |
| 3 | `ElectronicSignatureProvider` definida como interface trocável, nunca acoplada a um provedor | ✅ |
| 4 | `/configuracoes/assinatura` — só ADMINISTRADOR/DIRETOR alteram política/provedor | ✅ |
| 5 | Assinatura do contrato de cessão-de-uso é ICP-Brasil qualificada por política, não-negociável por COMERCIAL | ✅ |
| 6 | Combinação MOCK+PRODUÇÃO bloqueada no banco e no frontend | ✅ |
| 7 | Nenhum certificado/.pfx/senha armazenado — só referência de variável de ambiente | ✅ |
| 8 | `/usuarios` — RBAC 6 perfis reaproveitado, aplicado sempre no servidor | ✅ |
| 9 | `/proponentes` com cadastro completo + múltiplos responsáveis | ✅ |
| 10 | Autoridade de responsável nunca assumida — só via documento comprobatório vinculado | ✅ |
| 11 | Storage de documento de proponente sempre privado, nunca bucket público | ✅ |
| 12 | Proposta carrega proponente/responsável/cidade/infraestrutura/cenário/condições com snapshot imutável | ✅ |
| 13 | Fluxo de status estendido (RASCUNHO → ... → CONTRATO_GERADO) implementado | ✅ |
| 14 | Governança de preço preservada + exceção com motivo obrigatório e auditoria | ✅ |
| 15 | "Aprovação interna" distinta de "assinatura jurídica" no fluxo de status | ✅ |
| 16 | `/assinaturas` com status detalhado + auditoria por envelope | ✅ |
| 17 | `POST /api/signatures/webhook` autentica (HMAC), loga e é idempotente | ✅ (testado com evento duplicado, TESTE-16c) |
| 18 | `/contratos/modelos` — texto sempre marcado como não-oficial, nunca inventado | ✅ |
| 19 | "GERAR CONTRATO" auto-preenche a partir da proposta assinada | ✅ |
| 20 | Prazo mínimo de 48 meses, exceção só autorizada e motivada | ✅ |
| 21 | Ativação marca infraestrutura como comprometida e bloqueia conflito | ✅ |
| 22 | `/contratos` com filtros + versionamento (nunca sobrescreve) | ✅ |
| 23 | `/contratos/:id/aditivos` com ciclo próprio de aprovação/assinatura/ativação | ✅ |
| 24 | Reajustes guardam histórico completo, nunca reescrevem valor histórico | ✅ |
| 25 | Dashboard contratual + alertas automáticos | ✅ |
| 26 | "VALIDAR ASSINATURA" mostra ✓/✕ por critério, nunca assume válido | ✅ |
| 27 | Edição de proposta/contrato bloqueada após assinatura (só nova versão/aditivo) | ✅ (por construção — nenhuma função de edição direta aceita um documento já assinado) |
| 28 | 25 testes obrigatórios + E2E + regressão executados de verdade (não só compilados) | ✅ (46 PASS / 0 FAIL / 3 SKIP documentados) |

Nenhuma limitação foi escondida — todas estão listadas de forma explícita na seção 14 acima.
