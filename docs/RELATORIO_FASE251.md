# Relatório Final — Fase 2.5.1 (Correção, Completude, UX, Usuários, Proponentes, Assinaturas, Contratos, Configuração e Manuais)

Status geral: **CONCLUÍDA no código, nos testes e na documentação.** `tests/run_tests_fase251.sh`: **25 PASS / 0 FAIL / 7 SKIP documentados**, precedido por PASSO-0 = regressão completa herdada de **todas** as fases anteriores via `run_tests_fase25.sh` (que por sua vez encadeia Fase 1 → 2.5, incluindo `run_tests_deploy.sh` no fundo da cadeia): **46 PASS / 0 FAIL / 3 SKIP, 0 regressão**. Nenhuma migration de fase anterior foi editada, nenhuma tabela recriada, nenhum dado existente apagado, nenhuma tabela duplicada — apenas **2 migrations novas, aditivas**. Build do frontend (`npm run build`) e "lint" do backend (`npm run lint`, que carrega `server.js` por completo) passam sem erro. Nenhum teste pré-existente de fase anterior foi alterado ou removido.

Esta fase não adicionou nenhuma tabela nem fluxo de negócio novo — o escopo era **corrigir, completar e expor** o que a Fase 2.5 já tinha no backend mas ainda não tinha interface, e validar de ponta a ponta (não só "a rota existe") o que a Fase 2.5 tinha declarado pronto mas nunca exercitado com teste funcional real.

## Addendum — correção pós-entrega: link de convite não tinha para onde ir

Depois da entrega original desta fase, o usuário testou o convite contra um projeto Supabase real e reportou o problema: o link do e-mail autenticava com sucesso (token válido, `type=invite` na URL), mas terminava numa tela sem sentido em vez de deixar a pessoa definir a senha. Investigação encontrou dois problemas reais, ambos corrigidos e cobertos por teste nesta mesma sessão:

1. **A URL do link estava errada.** `frontendRedirectUrl()` (em `api/routes/users.js`) escolhia sempre a *primeira* origem de `CORS_ALLOWED_ORIGINS` — e essa variável quase sempre lista `http://localhost:...` primeiro (é o próprio padrão documentado em `api/.env.example`, pensado para desenvolvimento local). Resultado: todo e-mail de convite/redefinição enviado por um projeto real levava para `localhost`, não para a URL publicada de verdade. Corrigido com uma variável de ambiente explícita e única para esse propósito (`PUBLIC_APP_URL`, documentada em `api/.env.example`) e, enquanto ela não é configurada, um fallback que prefere a primeira origem de `CORS_ALLOWED_ORIGINS` que **não** pareça localhost, em vez de sempre pegar a primeira da lista.
2. **A página de destino nunca existia.** Mesmo com a URL certa, não havia nenhuma rota no frontend para receber esse retorno do Supabase Auth (`#access_token=...&type=invite|recovery`) e deixar a pessoa escolher a senha — o convite "funcionava" tecnicamente (autenticava) e não levava a lugar nenhum. Criada `web/src/pages/DefinirSenha.jsx` (rota `/definir-senha`, fora de `ProtectedRoute` de propósito), que confirma a sessão temporária, mostra o formulário de nova senha, chama `supabase.auth.updateUser({ password })` e só então entra no sistema — cobrindo tanto o convite de usuário quanto "Redefinir acesso". Trata também o caso de link expirado/já usado (`#error=...&error_description=...`), mostrando uma mensagem específica em vez de uma tela quebrada.

Adicionado `TESTE-redirect` em `tests/run_tests_fase251.sh` — exercita `frontendRedirectUrl()` de verdade (a função foi exportada só para isso) nos 3 cenários que importam, para este bug específico nunca mais voltar sem ser pego pela regressão. Manual do Administrador atualizado para descrever o fluxo correto (clica no link → cai em "Definir senha" → já entra no sistema). Suíte completa reexecutada depois da correção: **26 PASS / 0 FAIL / 7 SKIP**, 0 regressão.

### Addendum 2 — a causa raiz final não estava no código: "Site URL"/"Redirect URLs" do próprio projeto Supabase

Mesmo depois da correção acima implantada (`PUBLIC_APP_URL` configurado no Railway, frontend com `/definir-senha` publicado), o usuário reportou que um link **recém-gerado** (confirmado pelo `iat` do JWT, poucos minutos antes do teste) continuava chegando em `http://localhost:3000`. Isso não é um bug de código — é um comportamento documentado do próprio Supabase Auth: `inviteUserByEmail`/`resetPasswordForEmail` só respeitam o `redirectTo` enviado pela API **se essa URL estiver na lista de permitidos do projeto** (Authentication → URL Configuration → Redirect URLs); se não estiver, o Supabase ignora silenciosamente o `redirectTo` recebido e usa a "Site URL" configurada no painel — que é `http://localhost:3000` por padrão em todo projeto novo do Supabase, sem nenhum aviso de que o valor pedido foi rejeitado. Nenhuma fase anterior deste projeto tinha documentado esse passo de configuração do painel do Supabase (distinto de qualquer variável de ambiente do Railway/Vercel), então ele nunca tinha sido feito.

**Correção — configuração manual no painel do Supabase, não no repositório:**
1. Authentication → URL Configuration → **Site URL**: trocar `http://localhost:3000` pela URL real do frontend publicado (ex.: `https://seu-projeto.vercel.app`).
2. Authentication → URL Configuration → **Redirect URLs**: adicionar `https://seu-projeto.vercel.app/**` (coringa cobrindo `/definir-senha` e `/login`).
3. Nenhum redeploy é necessário — a mudança vale para o próximo e-mail gerado; o link já recebido antes da mudança continua com a URL antiga (e, de qualquer forma, é de uso único).

Este passo foi adicionado ao runbook de deploy desta fase (abaixo) para nunca mais faltar num projeto novo.

## 1. Problemas encontrados

1. **Bug crítico relatado pelo usuário (corrigido)**: em "Usuários" → "Novo", o administrador precisava digitar manualmente um UUID (`ID (auth.users.id)`) para criar um usuário, o que causava `invalid input syntax for type uuid: "nadia.cussolin.2026"` quando alguém digitava um nome em vez de um UUID. Causa raiz: a Fase 2.5 criou o backend de usuários assumindo que a identidade em `auth.users` já existiria antes da chamada a `POST /api/users` — não havia nenhuma rota que criasse essa identidade. Corrigido criando o fluxo `POST /api/users/invite`, que cria a identidade via Supabase Auth Admin API e devolve o UUID gerado — o campo de UUID manual foi removido da tela.
2. **Regressão real introduzida e corrigida durante esta própria fase**: a extensão de `GET /api/audit` para aceitar `entidade_id` (novo filtro desta fase) passou a enviar sempre esse parâmetro na chamada RPC, mesmo como `null` — como esse arquivo (`api/routes/audit.js`) não é versionado por fase e roda contra qualquer estado de banco da cadeia de regressão, isso quebrava `E2E-8` em `run_tests_deploy.sh` (o estágio mais antigo da cadeia, anterior à migration que adiciona esse parâmetro à função SQL) com `Could not find the function public.pricing_audit_list(...) in the schema cache`. Corrigido enviando o parâmetro só quando o caller realmente pede `entidade_id`.
3. **Bug real de runtime encontrado pelos próprios testes desta fase** (não pelo usuário, nem presente antes desta fase): `supabase.rpc(...).catch(() => {})`, usado em 6 pontos do código novo desta fase (desativar/reativar usuário, desativar/reativar proponente, convidar usuário, reenviar convite, redefinir acesso, testar conexão do provedor de assinatura) para tornar o log de auditoria semântica "best-effort" (nunca bloquear a ação principal), derrubava a rota inteira com 500 (`TypeError: supabase.rpc(...).catch is not a function`). Causa raiz: o builder retornado por `supabase.rpc()` no `@supabase/supabase-js` é "thenable" (implementa só `.then()`), não uma `Promise` real — não tem `.catch()`. Corrigido substituindo todos os 6 pontos por um helper `logSemanticEventBestEffort(supabase, params)` que usa `await` dentro de um `try/catch` de verdade.
4. **Bug no próprio teste automatizado desta fase** (não no produto): `TESTE-S01a/S01b` (COMERCIAL/FINANCEIRO bloqueados de criar infraestrutura) enviava um corpo incompleto (`{cidade_id, nome}`, sem `codigo`) para `POST /api/infra/pops` — a validação de entrada em Node devolvia 400 antes mesmo de a requisição alcançar a INSERT protegida por RLS, então o teste não provava nada sobre RBAC. Corrigido completando o corpo do teste; a RLS (`infra_pops_write`, só ENGENHARIA/ADMINISTRADOR) se confirmou correta assim que o teste passou a exercitá-la de verdade (403, como esperado).
5. **Lacunas de UX identificadas por inspeção sistemática** (seção 31 do prompt: toda funcionalidade de backend destinada ao usuário final precisa de interface): `/proponentes` só tinha Criar/Listar, sem Visualizar/Editar/Desativar/Reativar mesmo o backend já suportando tudo isso desde a Fase 2.5; `PartnerDetail` não tinha abas de Propostas/Contratos/Histórico; a tela de Configuração de Assinatura não tinha um botão de teste de conexão real; o Dashboard não tinha nenhum indicador de usuários/proponentes/assinaturas/contratos pendentes.

## 2. Arquivos alterados

**Backend (Node/Express) — modificados:**
- `api/routes/users.js` — reescrito: fluxo de convite sem UUID manual, desativar/reativar, reenviar convite, redefinir acesso, `status_auth` derivado.
- `api/routes/partners.js` — acrescenta `POST /:id/deactivate` e `/:id/reactivate`.
- `api/routes/signatures.js` — acrescenta `POST /providers/:id/test-connection`; `GET /providers` passa a usar `pricing_signature_providers_list`.
- `api/routes/audit.js` — `p_entidade_id` só enviado quando pedido (correção de regressão, item 1.2 acima).
- `api/lib/signatureProvider.js` — acrescenta `testConnection()` na classe abstrata e no `MockHomologacaoProvider`.
- `api/.env.example` — bloco documentado sobre `SUPABASE_SERVICE_ROLE_KEY` (ver seção 3 abaixo).

**Backend — novo:**
- `api/lib/supabaseAdmin.js` — único ponto do backend com acesso à Auth Admin API (ver seção 3).

**Frontend (React/Vite) — modificados:**
- `web/src/pages/Users.jsx` — reescrito: sem campo de UUID; convite; ações Editar/Desativar/Reativar/Reenviar convite/Redefinir acesso; badges de status.
- `web/src/pages/Partners.jsx` — filtro Ativos/Inativos/Todos; ações Visualizar/Editar/Desativar/Reativar.
- `web/src/pages/PartnerDetail.jsx` — cadastro editável; Ativar/Desativar; abas novas Propostas/Contratos/Histórico & Auditoria.
- `web/src/pages/SignatureSettings.jsx` — colunas de Webhook/Último teste/Último evento; botão "Testar Conexão".
- `web/src/pages/Dashboard.jsx` — nova seção de indicadores comerciais/assinatura/usuários (8 cards).
- `web/src/components/ArchiveModal.jsx` — `motivoOptions` agora é uma prop (compatível com o uso anterior).
- `web/src/lib/api.js` — novos métodos client-side para as rotas acima.
- `web/src/content/manuals.js` — reescrito por completo (ver seção 10).
- `web/src/content/faq.js` — 6 perguntas novas (ver seção 10).

**Frontend — novo:**
- `web/src/components/UserEditModal.jsx` — modal de edição de usuário (nunca edita e-mail/id).

**Testes — novo:**
- `tests/run_tests_fase251.sh` — suíte desta fase (TESTE U/P/C/conexão/S01-S05).

## 3. Migrations criadas

Só **2 migrations novas, ambas aditivas** — nenhuma editada, nenhuma tabela recriada:

- `supabase/migrations/20260920090000_phase_2_5_1_01_auditoria_semantica_estendida.sql` — estende o `CHECK` de `auditoria.acao` e o whitelist interno de `app.registrar_auditoria_semantica` com as ações novas desta fase (`USER_INVITE`, `USER_INVITE_FAILED`, `USER_RESEND_INVITE`, `USER_DEACTIVATE`, `USER_REACTIVATE`, `USER_RESET_ACCESS`, `PARTNER_DEACTIVATE`, `PARTNER_REACTIVATE`, `SIGNATURE_TEST_CONNECTION`); cria `public.pricing_log_semantic_event`, um wrapper fino reaproveitável por qualquer rota Node nova.
- `supabase/migrations/20260920090100_phase_2_5_1_02_dashboard_auditoria_provider_teste.sql` — estende `app.dashboard_contratual()` com os indicadores novos do Dashboard; recria `public.pricing_audit_list` com o 4º parâmetro opcional `p_entidade_id`; acrescenta colunas de diagnóstico a `signature_providers` (`ultimo_teste_em/status/mensagem`) e cria `public.pricing_signature_providers_list()`.

**Decisão de arquitetura documentada — Auth Admin API (seção 4 do prompt-mestre desta fase):** criar um usuário sem pedir UUID ao administrador exige criar a identidade em `auth.users`, e a única forma de fazer isso é a Supabase Auth Admin API (`inviteUserByEmail`/`updateUserById`/`listUsers`) — não existe alternativa via RLS, porque RLS só governa tabelas do Postgres, nunca o schema interno do GoTrue. Isso é, deliberadamente, a **única exceção** à regra deste projeto de nunca usar `service_role` no backend, e foi escopada ao mínimo possível: `api/lib/supabaseAdmin.js` exporta só `client.auth.admin` (nunca um client genérico de tabelas), a chave nunca é lida em nenhum outro arquivo, `SUPABASE_SERVICE_ROLE_KEY` nunca tem prefixo `VITE_` (logo é estruturalmente impossível de vazar para o bundle do frontend — confirmado por varredura real em `web/dist`, `TESTE-S04`), nunca é definida no Vercel/Railway do frontend, e toda rota que usa `adminAuth()` primeiro confirma, em Node (porque RLS não alcança essa operação), que quem chamou é `ADMINISTRADOR` e está `ativo`. Quando a variável não está configurada (como no ambiente de teste local), toda rota que dependeria dela falha de forma controlada (`501 SERVICE_ROLE_NAO_CONFIGURADO`), nunca com um erro genérico nem com um comportamento inventado.

## 4. APIs alteradas

**Novas:**
- `POST /api/users/invite` — cria a identidade em `auth.users` (Auth Admin API) + a linha em `public.usuarios`, sem exigir UUID do chamador.
- `POST /api/users/:id/resend-invite`
- `POST /api/users/:id/reset-access`
- `POST /api/users/:id/deactivate` / `POST /api/users/:id/reactivate`
- `POST /api/partners/:id/deactivate` / `POST /api/partners/:id/reactivate`
- `POST /api/signatures/providers/:id/test-connection`

**Alteradas (compatíveis, sem quebrar contrato anterior):**
- `GET /api/users` — novo campo `status_auth` (nunca obrigatório para quem consome).
- `GET /api/signatures/providers` — novos campos de diagnóstico (`webhook_url`, `ultimo_teste_*`, `ultimo_evento_*`).
- `GET /api/audit` — aceita `?entidade_id=` opcional (correção da seção 1, item 2).
- `POST /api/users` (legado, exige `id`) — mantido intacto como caminho de recuperação manual, nunca removido.

## 5. Componentes frontend alterados

`Users.jsx` (reescrito), `Partners.jsx`, `PartnerDetail.jsx`, `SignatureSettings.jsx`, `Dashboard.jsx`, `ArchiveModal.jsx` (generalizado), `UserEditModal.jsx` (novo). Detalhes na seção 2 acima.

## 6. Fluxo de usuários

Nome/E-mail/Telefone/CPF/Cargo/Departamento/Perfil/Observações → "Criar Usuário" → identidade criada no Supabase Auth (UUID gerado automaticamente, nunca digitado) → convite por e-mail enviado → linha criada em `public.usuarios` → tela mostra "Convite enviado para `<email>`." A pessoa convidada define a própria senha pelo link do convite (não validável neste ambiente local — ver seção 13). Depois de criado, o usuário pode ser Editado (nunca o e-mail/id), Desativado/Reativado (nunca excluído fisicamente), ter o convite Reenviado ou o acesso Redefinido. Desativar bloqueia toda ação privilegiada imediatamente (via `app.perfil_atual()`, que só reconhece `ativo=true`) e, quando a Auth Admin API está configurada, também bane o login em si na camada de autenticação.

## 7. Fluxo de proponentes

Criar (já existia) → Editar cadastro (aba "Cadastro" em `PartnerDetail`) → Adicionar/Editar responsável → Upload de documento (Storage privado, nunca URL pública) → Desativar (nunca exclusão física — some da listagem de ativos, motivo obrigatório) → Reativar (quando autorizado, mesmas permissões de quem desativa: COMERCIAL/DIRETOR/ADMINISTRADOR). A tela de detalhe agora tem as 6 abas pedidas: Dados Cadastrais, Responsáveis, Documentos, Propostas, Contratos, Histórico & Auditoria.

## 8. Fluxo de assinatura

Validado ponta a ponta nesta fase (não só "a rota existe" — seção 24 do prompt): criar envelope → adicionar signatário → enviar → receber webhook (autenticado por HMAC) → processar webhook duplicado sem duplicar evento nem efeito colateral (`UNIQUE` + `ON CONFLICT DO NOTHING RETURNING`, herdado e reconfirmado da Fase 2.5) → assinar → validar → baixar documento → auditar. Cobertura real desta validação: as verificações já existentes e reexecutadas sem regressão em `run_tests_fase25.sh` (TESTE-12 a TESTE-18, incluindo o teste de idempotência de webhook) mais o novo "Testar Conexão" desta fase, que agora faz uma checagem de conectividade de verdade contra o provedor configurado e persiste o resultado (`ultimo_teste_em/status/mensagem`) sem nunca expor `api_key_ref`/`webhook_secret_ref`.

## 9. Fluxo de contratos

Sem mudança de lógica de negócio nesta fase (geração automática, snapshot, ativação, infraestrutura comprometida, aditivos e reajuste já existiam desde a Fase 2.5) — reconfirmado sem regressão via `run_tests_fase25.sh` TESTE-19 a TESTE-23. Confirmado nesta fase, adicionalmente: não existe nenhuma rota de edição direta de um contrato já gerado (`PATCH /api/contracts/:id` devolve 404 — a única forma de alterar um contrato é por aditivo ou reajuste, nunca por edição livre).

## 10. Manuais atualizados

Os 4 manuais existentes (Engenharia, Comercial, Financeiro, Diretoria) foram **atualizados integralmente** com os fluxos que a Fase 2.5 introduziu e que ainda não estavam documentados em nenhum manual: proponente/responsável, aprovação interna, assinatura, contrato/aditivo, infraestrutura comprometida por contrato. Foi criado o **Manual do Administrador** (não existia — a Fase 2.5 introduziu Usuários/Proponentes/Assinatura/Contrato/Configuração sem nenhum manual dedicado a quem administra), cobrindo login, perfis, criação/edição/desativação de usuário sem UUID, proponentes, aprovações, assinaturas, contratos, configuração, auditoria, exceções e segurança. Foi criado o guia cross-perfil **"Como funciona a assinatura eletrônica"** (proposta → aprovação → documento → signatários → ICP-Brasil → assinatura → validação → contrato ativo). A FAQ recebeu as 6 perguntas exigidas pelo prompt-mestre (UUID de usuário, onde a senha fica, se o OptiMon guarda senha, o que acontece ao alterar um contrato, se dá para excluir um proponente, o que significa assinatura validada).

## 11. Testes executados

- `tests/run_tests_fase251.sh` (novo, desta fase) — 25 verificações próprias.
- PASSO-0 desse mesmo script = regressão completa herdada: `run_tests_fase25.sh` → `run_tests_fase24.sh` → `run_tests_fase231.sh` → `run_tests_fase23.sh` → `run_tests_deploy.sh`, todos executados **sem edição**, na íntegra, a cada rodada.
- `npm run build` (frontend) e `npm run lint` (backend, carrega `server.js` por completo).

## 12. Resultado de cada teste

**Suíte desta fase — 25 PASS / 0 FAIL / 7 SKIP:**
U01 PASS, U01b PASS, U02 SKIP (ambiente), U03 SKIP (ambiente), U04 PASS, U05 PASS, U06 PASS, U07 PASS, U-extra PASS, P(setup) PASS, P05 PASS, P05b PASS, P06 PASS, P07/P08 SKIP (ambiente), PR01-07/A01-09/C01-06/AD01-05 SKIP (sem mudança de lógica nesta fase — já cobertos pela regressão herdada), C07 PASS, TESTE-conexão (2x) PASS, S01a PASS, S01b PASS, S01c PASS, S01d PASS, S02 PASS, S03 PASS, S04 PASS, S05 PASS.

**Regressão herdada (PASSO-0, via `run_tests_fase25.sh`): 46 PASS / 0 FAIL / 3 SKIP** — mesmo resultado da Fase 2.5, sem nenhuma regressão nova introduzida por esta fase (depois de corrigidos os 3 bugs reais da seção 1).

## 13. Testes pendentes

Mesma categoria de limitação de ambiente já documentada desde a Fase 2.5 — nenhuma nova nesta fase:
- **U02/U03** (recebimento real de e-mail de convite, definição de senha pelo link) — exige GoTrue real (Supabase Auth de um projeto de verdade); o Postgres local só simula a camada REST, não a Auth. O código foi validado (U01) para nunca crashar e nunca inventar um envio de e-mail que não aconteceu.
- **P07/P08** (upload/download real de documento) — exige o schema `storage`, ausente no Postgres local (mesma limitação documentada desde a Fase 2.5, `supabase/storage_setup_fase25.sql`).
- **Bloqueio de login por ban da Auth** (parte de U07) — a parte de RBAC via `usuarios.ativo=false` foi validada de verdade (403 real); o bloqueio do login em si na camada Auth exige um projeto Supabase real.

## 14. URL frontend

Não alterada nesta fase — deploy real (Vercel) fora do escopo desta sessão, que validou build e comportamento localmente. Ver runbook de deploy no relatório da Fase Deploy/2.5.

## 15. URL backend

Não alterada nesta fase — deploy real (Railway) fora do escopo desta sessão. Ver mesma observação acima.

## 16. Status Supabase

Ambiente local de teste (Postgres 16 + PostgREST simulando a API REST) — sem projeto Supabase real conectado nesta sessão. As 2 migrations novas desta fase aplicam sem erro sobre a base da Fase 2.5, dentro da cadeia de regressão completa.

## 17. Status integração de assinatura

Provedor mock de homologação (`MockHomologacaoProvider`), o único autorizado pelo prompt-mestre da Fase 2.5 a ter integração real nesta etapa do projeto — arquitetura pronta para receber um segundo provedor de produção sem alterar `signatures.js`, `contracts.js` ou o frontend (ver `docs/ARQUITETURA.md`, seção 23.1). Nesta fase, o botão "Testar Conexão" foi validado de ponta a ponta contra esse mock: `ok=true`, diagnóstico presente, nenhum segredo exposto na resposta.

---

## Runbook — aplicar em um projeto Supabase real

1. Aplicar as 2 migrations novas desta fase, na ordem, junto com todas as anteriores (nenhuma foi alterada).
2. Configurar `SUPABASE_SERVICE_ROLE_KEY` **só no backend** (Railway/ambiente do `api/`), nunca no Vercel do frontend — ver o bloco de 4 regras em `api/.env.example`.
3. Configurar `PUBLIC_APP_URL` no backend (Railway) com a URL real do frontend publicado (ex.: `https://seu-projeto.vercel.app`, sem barra no final).
4. **No painel do Supabase** (Authentication → URL Configuration — configuração do projeto, não uma variável de ambiente do Railway/Vercel): definir **Site URL** como a URL real do frontend, e adicionar essa mesma URL com coringa (`https://seu-projeto.vercel.app/**`) em **Redirect URLs**. Sem este passo, o Supabase ignora silenciosamente o `redirectTo` enviado pela API e volta a usar `http://localhost:3000` (o padrão de todo projeto novo) nos e-mails de convite/redefinição — ver Addendum 2 acima, causa raiz real de um bug reportado pelo usuário depois da entrega original.
5. Confirmar que o e-mail de convite do Supabase Auth está configurado (template + remetente) antes de usar "Criar Usuário" em produção — e que o projeto não está no limite de envio do servidor de e-mail compartilhado do Supabase (poucos envios por hora; para uso real, configurar SMTP próprio em Authentication → Settings → SMTP Settings).
6. Rodar `supabase/storage_setup_fase25.sql` manualmente (bucket privado `documentos` + políticas), como já documentado desde a Fase 2.5.
