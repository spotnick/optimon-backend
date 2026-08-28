# Relatório Final — Fase 3 (Hardening + Completude + Homologação + Implantação Operacional)

Status geral: **CONCLUÍDA no escopo instruído pelo usuário** — *"Faz completo! Deixando para depois: integração HubSoft (preciso de docs/credenciais da API, que não tenho), integração real com IBGE/SIDRA."* Os 16 itens do prompt-mestre (3.1 a 3.16) estão implementados, testados de forma real contra o Postgres/API local e documentados; os 2 itens explicitamente adiados pelo próprio usuário (HubSoft, IBGE/SIDRA real) permanecem NÃO INICIADOS, por decisão do usuário, não por omissão. Nenhuma migration de fase anterior foi editada, nenhuma tabela recriada, nenhum dado apagado, nenhuma regra já correta foi simplificada ou enfraquecida — toda mudança desta fase é aditiva (9 migrations novas, `20260922090000` a `20260928090000`).

`tests/testes_obrigatorios_teste01_50.sh` (item 3.16): **52 PASS / 0 FAIL** (50 testes numerados + PASSO-0 de regressão completa), que por sua vez encadeia `tests/checklist_producao.sh` → `tests/run_tests_fase312.sh` → `tests/run_tests_fase253.sh` → ... → a suíte da Fase 1 — toda a cadeia de testes de todas as fases do projeto, do zero, sem pular nenhuma. Build do frontend (`vite build`) passa sem erro.

## 1. Itens adiados por instrução explícita do usuário (não iniciados)

| Item | Motivo do adiamento |
|---|---|
| Integração HubSoft | Usuário declarou não ter documentação nem credenciais da API — não há como implementar uma integração real sem o contrato de API do provedor. Nenhum código ou schema especulativo foi criado para isso. |
| Integração real com IBGE/SIDRA | Mesma categoria — adiada por decisão explícita do usuário nesta mesma instrução, não por dificuldade técnica identificada nesta fase. |

Nenhuma menção a HubSoft ou IBGE/SIDRA aparece em nenhuma migration, rota ou componente desta fase — o sistema continua sem qualquer dependência oculta desses dois provedores.

## 2. Status por módulo (itens 3.1 a 3.16)

### 3.1 — Régua de preço: preço proposto passa a ser o valor real usado

Migration `20260922090000_phase_3_01_preco_proposto_correcao_critica.sql`. **Bug real corrigido** (achado por investigação de código, não por suposição): `app.simular_precificacao_completa` calculava a régua comercial mas nunca propagava o "preço proposto" efetivamente escolhido pelo usuário para a proposta/contrato gerados a partir dela — o valor usado na prática era sempre o recomendado, não o negociado. Corrigido de ponta a ponta (função de simulação → proposta → geração de contrato), sem alterar a fórmula da régua em si (Fase 2.2/2.2.1, inalterada).

### 3.2 — Prazo contratual mínimo (48 meses) vs. horizontes analíticos (12/36/60)

Migration `20260922090100_phase_3_02_motivo_excecao_prazo_contrato.sql`. Auditoria confirmou que a separação entre "horizonte de simulação" (analítico, livre) e "prazo real do contrato" (`contratos_prazo_minimo`, CHECK desde a Fase 1) já estava correta em todas as camadas — o item se resumiu a adicionar `contratos.motivo_excecao_prazo` (texto, obrigatório quando o prazo foge do padrão de 48 meses) para rastrear e justificar exceções, sem afrouxar o CHECK existente.

### 3.3 — Dashboard executivo: KPIs completos + gráfico de receita acumulada

Migration `20260923090000_phase_3_03_dashboard_executivo.sql`. Estendeu `app.dashboard_contratual` (mesma função, `create or replace`, Fase 2.5.1/2.5.3) para expor chaves que já eram calculadas mas nunca chegavam ao frontend, acrescentou contagens de propostas abertas/aprovadas, um agregado de capacidade em nível de portfólio (antes só existia por cidade) e a série de receita acumulada por cenário para o gráfico do dashboard.

### 3.6 — Relatórios gerenciais: cobertura completa

Migration `20260924090000_phase_3_06_relatorios_gerenciais.sql` + `api/routes/reports.js` (novo) + `api/lib/csvReport.js` (novo). Relatórios tabulares exportáveis por cidade/parceiro/POP/PON/contrato/reajuste, para DIRETOR/FINANCEIRO/ADMINISTRADOR/AUDITOR, reaproveitando as views de capacidade já existentes desde a Fase 1.1 (`vw_capacidade_*`) combinadas com `contrato_pricing_config`.

### 3.7 — Minuta de contrato: completude de cláusulas + rótulo de aprovação jurídica

Migration `20260925090000_phase_3_07_minuta_contrato_dados.sql` + `api/lib/contractDocumentModel.js`, `api/lib/pdfContrato.js`, `api/lib/docxContrato.js` (novos, espelhando o padrão já usado para propostas). Toda minuta gerada (PDF e DOCX) carrega, de forma fixa, o rótulo **"MINUTA SUJEITA À APROVAÇÃO JURÍDICA"** (confirmado por `TESTE-40` da bateria 3.16) — nunca é apresentada como documento juridicamente definitivo. Reúne numa única chamada tudo que o gerador precisa: contrato, config de precificação, guardrails contratuais (exclusividade/fibra de terceiros/rede própria — Fase 1), clientes reservados (inclui a exceção Prefeitura), ativos vinculados, fibras, aditivos e reajustes.

### 3.8 — Exclusão física controlada de usuário

Migration `20260926090000_phase_3_08_exclusao_fisica_usuario.sql`. Até esta fase só existia soft-delete (`usuarios.ativo`); a coluna `usuarios.removido_em` existia desde a Fase 1 mas nunca era escrita por ninguém — achado ao investigar este item. Agora existe `public.pricing_usuario_excluir_fisicamente()`, restrita a ADMINISTRADOR (não existe perfil "OWNER" separado neste RBAC de 6 perfis — mapeado para ADMINISTRADOR), que: bloqueia auto-exclusão (`TESTE-15` da bateria 3.16 confirma), bloqueia exclusão de usuário com histórico vinculado (`USUARIO_POSSUI_HISTORICO`), e grava um snapshot em auditoria com o CPF explicitamente removido do JSON antes de gravar (`to_jsonb(v_usuario) - 'cpf'`, confirmado por `TESTE-24`). Documentado no manual do Administrador (item 3.14) — a manual antiga afirmava "nunca existe exclusão física de usuário", o que se tornou falso a partir desta migration e foi corrigido.

### 3.9 — Proponentes/Responsáveis: CRUD e classificação

Sem nova migration de schema — auditoria confirmou o CRUD já completo desde a Fase 2.5.1. Acrescentado suporte a `?incluir_removidos=true` em `GET /:id/responsaveis` e a rota de restauração `POST /:id/responsaveis/:respId/restore` (`api/routes/partners.js`), fechando a última lacuna (listar/restaurar responsável removido).

### 3.10 — Assinatura eletrônica: status ICP-Brasil

Sem nova migration — item de honestidade de status, não de código novo. `web/src/pages/SignatureSettings.jsx` declara explicitamente, em destaque: **"Status ICP-Brasil: NÃO TESTADO com provedor real"** e "Nenhum documento assinado neste sistema hoje tem validade jurídica ICP-Brasil real" — hoje só o provedor de homologação (mock) está implementado. `ElectronicSignatureProvider` (Fase 2.5) já é a abstração pronta para plugar um provedor real sem tocar em contrato/proposta/banco/frontend, mas nenhum provedor real foi integrado nesta fase (fora do escopo instruído).

### 3.11 — Alertas: cobertura completa dos tipos pedidos

Migration `20260927090000_phase_3_11_alertas_cobertura_completa.sql` + `web/src/pages/Alerts.jsx` (nova tela `/alertas`). **Achado real**: o comentário de cabeçalho de uma migration anterior (`20260913090800`) afirmava que os tipos `REAJUSTE`, `FIBRA_EM_CONFLITO`, `CAPACIDADE_EXCEDIDA` e `OPERACAO_NAO_AUTORIZADA` já estavam cobertos — não estavam; nenhum código gerava esses 4 tipos. De 20 valores possíveis de `alerta_tipo`, só 8 eram efetivamente gerados antes desta fase. Adicionados 4 novos (`FIM_CARENCIA`, `REAJUSTE`, `ATIVO_NAO_DEVOLVIDO`, `OPERACAO_NAO_AUTORIZADA`, este último via trigger em `auditoria`), com justificativa honesta e específica documentada no cabeçalho da migration para os 8 tipos que permanecem NÃO implementados (ex.: `FIBRA_EM_CONFLITO` é estruturalmente impossível dado os índices únicos parciais já existentes desde a Fase 1.1 — não é uma lacuna, é uma garantia mais forte que o alerta seria). Idempotência confirmada (`TESTE-36`): chamar `app.gerar_alertas_automaticos()` de novo sem mudança de estado gera 0 alertas novos.

### 3.12 — Auditoria: confirmar imutabilidade (sem UPDATE/DELETE)

`tests/run_tests_fase312.sh` (novo, 10 testes, 10 PASS / 0 FAIL). Prova em 3 camadas independentes: (1) o trigger `trg_auditoria_imutavel` bloqueia UPDATE/DELETE mesmo para o dono da tabela/superusuário, sem exceção de papel; (2) a RLS de `auditoria` tem exatamente 1 policy (`auditoria_select`, só leitura) — nenhuma policy de escrita existe para nenhum papel, então um UPDATE/DELETE via `authenticated` nem chega a acionar o trigger (0 linhas afetadas); (3) checagem estática (grep) confirmando que nenhuma migration nem rota da API tenta escrever em `auditoria` fora da função central `app.registrar_auditoria_semantica`.

### 3.13 — Documentação da API interna

`docs/API_REFERENCE.md` (novo). ~131 endpoints documentados em 11 arquivos de rota + endpoints utilitários, com nomes de RPC/função exatos, parâmetros, formatos de resposta e limitações citadas do próprio código. Achado e documentado (não corrigido em código, por não ter sido pedido): uma divergência entre o comentário de `GET /api/reports/faturamento-real/status` e a rota realmente registrada — o comentário está desatualizado, o comportamento real da rota está correto.

### 3.14 — Manuais por perfil: reescrita completa

`web/src/content/manuals.js`. 7 manuais agora (antes 6) — **manual novo do perfil AUDITOR**, que não existia. Corrigida uma afirmação falsa no manual do Administrador ("nunca existe exclusão física de usuário", tornada falsa pelo item 3.8) e adicionadas seções novas em todos os manuais cobrindo os recursos desta fase (alertas, relatórios, minuta de contrato, guardrails contratuais, exclusão física).

### 3.15 — Checklist automático de produção

`tests/checklist_producao.sh` (novo). Diferente dos `run_tests_fase*.sh` (que provam que uma funcionalidade específica funciona): prova que o repositório como um todo está em condição segura de produção — 100% das tabelas de `public` com RLS habilitada, `auditoria` com exatamente a policy de leitura esperada, nenhum `.env` real versionado, nenhum padrão de segredo real (JWT/AWS key/PEM) em arquivo rastreado pelo git, `SUPABASE_SERVICE_ROLE_KEY` só instanciada em `api/lib/supabaseAdmin.js`, sem CORS `'*'` hardcoded, contratos de `/health` e `/api/version` estáveis, build do frontend limpo, e presença dos arquivos de configuração de deploy. **16 PASS / 0 FAIL / 0 WARN / 3 MANUAL** — os 3 itens `MANUAL` (variáveis de ambiente carregadas de fato no Railway/Vercel de produção; migrations aplicadas no Supabase de produção real; DNS/certificado TLS) exigem acesso a infraestrutura real que este ambiente não tem e são honestamente reportados como pendentes de verificação humana, nunca marcados PASS por suposição — ver seção 4.

### 3.16 — Testes obrigatórios TESTE 01-50 + segurança + regressão completa

`tests/testes_obrigatorios_teste01_50.sh` (novo). 50 testes numerados em 8 categorias (Autenticação; RBAC por perfil; Imutabilidade e integridade de dados; Segurança de dados sensíveis; Isolamento entre entidades/integridade referencial; Fluxos de negócio ponta-a-ponta; Alertas e auditoria semântica; Regressão completa por fase), executados de verdade contra o Postgres/API locais, precedidos por uma regressão completa (PASSO-0, via `checklist_producao.sh`). **Resultado final: 52 PASS / 0 FAIL.**

**2 bugs reais, pré-existentes (de fases anteriores a esta sessão), achados por esta bateria e corrigidos** na migration `20260928090000_phase_3_16_correcao_override_pricing_financeiro.sql` — ver seção 3 abaixo para o detalhe completo.

## 3. Bugs reais encontrados e corrigidos nesta fase

A bateria de testes do item 3.16 (não a inspeção de código) achou 2 bugs pré-existentes e independentes na função pública `public.pricing_override_approve()` e na RLS de `pricing_override_requests` — ambos presentes desde fases anteriores a esta sessão (Fase 2.10 e Fase 2.2.1, respectivamente), nunca antes exercitados de ponta a ponta por um teste real:

1. **`pricing_override_approve()` sempre falhava, para QUALQUER chamador.** A instrução `set status = case when p_aprovar then 'APROVADA' else 'REJEITADA' end` produzia um valor `text` sem cast para o enum `solicitacao_status`, e o Postgres não faz esse cast implícito dentro de um `CASE` usado como alvo de `UPDATE`. Resultado: `ERROR: column "status" is of type solicitacao_status but expression is of type text` — a rota `POST /api/pricing/approve` nunca funcionou de fato em nenhum ambiente que já tivesse essa migration aplicada, mesmo para DIRETOR/ADMINISTRADOR com permissão total. Corrigido com cast explícito em cada ramo do `CASE`.

2. **FINANCEIRO nunca conseguia aprovar override, mesmo com a permissão explícita concedida.** A Fase 2.2.1 (seção 35) deu ao trigger `fn_override_decisao()` a lógica para permitir que um FINANCEIRO com `usuarios.pode_aprovar_override_pricing=true` decidisse um override — mas a policy de RLS de `UPDATE` em `pricing_override_requests` (de uma fase anterior, 2.09) nunca foi estendida para deixar essa linha visível para esse UPDATE. Um FINANCEIRO com a flag `true` tinha sua atualização silenciosamente filtrada pela RLS (0 linhas afetadas) antes mesmo do trigger — que já tinha a lógica certa — chegar a rodar. Corrigido estendendo a policy (drop + recreate, mesma convenção usada em todo o projeto) com o terceiro ramo já usado pelo trigger, replicado na camada de visibilidade de linha.

Ambas as correções são estritamente aditivas: mesma assinatura de função, mesmo nome de policy, comportamento de todo mundo que já funcionava (DIRETOR, ADMINISTRADOR, o próprio solicitante enquanto PENDENTE, e um FINANCEIRO sem a flag — que continua bloqueado) inalterado. Reconfirmado por teste direto: DIRETOR aprova normalmente; FINANCEIRO sem a flag continua bloqueado (agora por RLS silenciosa, relatando "não encontrado", em vez de um erro de tipo do Postgres); FINANCEIRO com a flag `true` agora aprova de fato — a permissão documentada desde a Fase 2.2.1 finalmente funciona.

## 4. Testes manuais pendentes (exigem infraestrutura real, fora do alcance deste sandbox)

Nenhum destes é um "quase pronto" escondido — são, por natureza, inverificáveis sem acesso à infraestrutura real de produção (Railway/Vercel/Supabase), e continuam honestamente listados como pendentes, não fabricados como PASS:

1. **Variáveis de ambiente carregadas de fato no Railway (API) e Vercel (frontend).** Confirmar manualmente antes/depois do deploy: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (Railway); `CORS_ALLOWED_ORIGINS` apontando para o domínio real do Vercel (Railway); `VITE_API_URL` apontando para o domínio real do Railway (Vercel).
2. **As 9 migrations novas desta fase (`20260922090000` a `20260928090000`) aplicadas no projeto Supabase de produção real.** Este sandbox só prova que elas replayam sem erro num Postgres local limpo — aplicar de fato em produção é um passo manual.
3. **DNS/certificado TLS/domínio customizado** — checagem de infraestrutura de hospedagem, fora do escopo de qualquer script.
4. **Roteiro de assinatura eletrônica com provedor ICP-Brasil real** (item 3.10) — hoje só o provedor de homologação (mock) foi testado; nenhum documento assinado neste sistema tem validade jurídica real até que um provedor real seja integrado e testado end-to-end.
5. **Teste E2E real contra o domínio de produção** (mesma limitação já documentada desde a Fase 2.5.3) — exige autenticar como ADMINISTRADOR num projeto Supabase de produção, que este ambiente não tem credencial para fazer.

## 5. O que fica para depois (por instrução explícita do usuário)

- Integração HubSoft — aguardando documentação/credenciais da API do provedor.
- Integração real com IBGE/SIDRA — aguardando decisão/priorização do usuário.

Nenhuma dessas duas pendências bloqueia o restante do sistema — todo o schema, RLS, API e frontend desta fase funcionam de forma completa e independente delas.
