# OptiMon — Plano Técnico de Arquitetura (Fase 1 + Fase 1.1 + Fase 1.2 + Fase 2)

> Optical Asset & Pricing Management
> Documento gerado a partir do Prompt Mestre de Desenvolvimento do OptiMon (2026-08-24), atualizado pela Fase 1.1 — Correções de Modelagem, Capacidade PON, Contratos e Governança (2026-08-25), pela Fase 1.2 — Hardening do Modelo Comercial e Preparação para o Pricing Engine (2026-08-26) — e pela Fase 2 — Pricing Engine + Simulador Comercial + ROI (2026-08-27).
> Este documento cobre a arquitetura geral do produto e o detalhamento da **Fase 1** (Banco + Auth + Infraestrutura + Parceiros + Contratos), da **Fase 1.1** (porta PON como unidade comercial real, POPs, aditivos, metas, exclusividade escopada — ver seção 11), da **Fase 1.2** (SOMA como modelo híbrido padrão, capacidade contratada×reservada×ativa, conflito compartilhamento×exclusividade, relação cliente→porta PON — ver seção 14) e da **Fase 2** (núcleo econômico completo: custos classificados, Dark Fiber mínimo/recomendado/premium, Revenue Share/SOMA/MAX, rampa, reajuste, projeção financeira, ROI, payback, economia do parceiro, governança de preço, override, auditoria, API source-only e dashboard comercial — ver seção 15). As fases seguintes (HubSoft, Financeiro, IBGE, Alertas/Auditoria avançada, Propostas/Documentos) estão descritas no roteiro ao final, mas não são implementadas nesta entrega — a Fase 2 não iniciou automaticamente a Fase 3, por instrução explícita do Prompt Mestre.

## 1. Visão do produto

O OptiMon não é uma calculadora nem um dashboard. É o sistema de registro (system of record) que um ISP proprietário de infraestrutura usa para:

- saber exatamente quanta capacidade óptica ociosa existe, cidade a cidade, fibra a fibra, par a par;
- transformar essa capacidade em contratos comerciais com parceiros (Dark Fiber ou Fibra+OLT+Revenue Share);
- garantir que cláusulas de exclusividade territorial, clientes reservados e proibições contratuais sejam **aplicadas pelo sistema**, não apenas descritas em papel;
- conciliar o que o parceiro diz que faturou com o que o HubSoft e o financeiro dele mostram (Revenue Assurance);
- manter histórico auditável e imutável de tudo que afeta dinheiro ou compromissos contratuais.

O modelo de negócio **não é rede neutra**: o proprietário cede a infraestrutura (e, opcionalmente, OLT/ONU/HubSoft), mas não atende, não instala, não cobra e não dá suporte ao cliente final do parceiro. Isso importa para o desenho de dados porque o OptiMon nunca vai armazenar operação de suporte ao cliente final — só o que afeta o contrato entre proprietário e parceiro.

## 2. Stack tecnológica

| Camada | Escolha | Observações |
|---|---|---|
| Frontend | Next.js + React + TypeScript, deploy na Vercel | Sem acesso direto a credenciais de integrações externas; consome só a API interna. |
| Backend | Node.js + TypeScript, deploy no Railway | API-first, REST. Toda integração externa (HubSoft, financeiro do parceiro, IBGE) passa por aqui. |
| Banco | Supabase (PostgreSQL 16) | RLS habilitado em todas as tabelas sensíveis; migrations versionadas em `supabase/migrations`. |
| Auth | Supabase Auth | JWT com claim de perfil (role) sincronizada em tabela `usuarios`. |
| Jobs | Railway Worker + scheduler/cron | Redis só entra se surgir necessidade real de fila/cache (não incluído na Fase 1). |
| Storage | Supabase Storage | Documentos/propostas/contratos assinados (Fase 8). |

Regra de segurança que atravessa tudo: **a `service_role key` do Supabase nunca chega ao frontend**. O frontend usa a `anon key` + RLS; operações privilegiadas (ex.: aprovar contrato, aplicar reajuste em massa) passam pelo backend, que usa a service role internamente e reforça as regras de negócio antes de tocar o banco — RLS é a segunda barreira, não a única.

## 3. RBAC — perfis e granularidade

Perfis: `ADMINISTRADOR`, `DIRETOR`, `COMERCIAL`, `FINANCEIRO`, `ENGENHARIA`, `AUDITOR`.

Resumo de capacidades (a matriz completa vira políticas RLS na migration `0090_rls_policies.sql`):

- **COMERCIAL**: cadastra oportunidades e parceiros, simula preços, gera propostas. Não altera parâmetros globais de pricing, não apaga medições, não altera contratos aprovados nem regras de exclusividade.
- **DIRETOR**: aprova pricing, contratos, exceções (ex.: prazo < 48 meses); altera parâmetros comerciais.
- **ENGENHARIA**: cadastra infraestrutura, fibras, controla ocupação e ativos.
- **FINANCEIRO**: consulta medições, valida faturamento, acompanha recebimentos, processa reajustes.
- **AUDITOR**: leitura total, incluindo logs; nunca escreve.
- **ADMINISTRADOR**: superset operacional (gestão de usuários/perfis, parâmetros de sistema).

Implementação: tabela `usuarios` (1:1 com `auth.users` do Supabase) carrega o `perfil`; uma função `auth.perfil_atual()` (SQL, `SECURITY DEFINER`) lê esse perfil a partir do `auth.uid()` e é usada em todas as policies de RLS. Isso evita repetir `EXISTS (SELECT ...)` em cada policy e facilita auditoria da própria matriz de permissão.

## 4. Modelo de dados — visão geral

Cadeia principal de relacionamento — **atualizada na Fase 1.1** e refinada na **Fase 1.2**: a unidade física continua sendo a fibra, mas a unidade comercial deixou de ser o par e passou a ser a **porta PON** (ver seção 11), e o **POP** entrou entre cidade e cabo. A partir da Fase 1.2, cada porta PON também se liga diretamente a clientes reais (`cliente_porta_pon`, seção 14.4), preparando a integração HubSoft:

```
CIDADE → POP → CABO → FIBRA → PORTA PON → CONTRATO → PARCEIRO
                             → CLIENTES  → FATURAMENTO → RECEBIMENTO → PRICING → RECEITA → ROI
```

Convenções aplicadas em toda tabela nova:

- PK `uuid` (`gen_random_uuid()`, extensão `pgcrypto`).
- `criado_em` / `atualizado_em` (trigger genérico `set_atualizado_em`).
- FKs explícitas com `ON DELETE RESTRICT` (nunca `CASCADE` em dados financeiros/contratuais — perda de histórico é inaceitável).
- **Soft delete** (`removido_em timestamptz`) em vez de `DELETE` físico para: `contratos`, `medicoes_mensais`, `medicao_faturamento`, `medicao_recebimentos`, `pricing_versions`, `documentos`, `auditoria`. Tabelas de cadastro simples (ex. `parceiros`, `cidades_infra`) também usam soft delete para não quebrar FKs históricas.
- `auditoria` nunca aceita `UPDATE`/`DELETE` (reforçado por trigger + RLS — ver seção 8).
- Enums de domínio nativos do Postgres (`fibra_status`, `perfil_usuario`, `contrato_status`, etc.) em vez de strings livres.

O detalhamento tabela a tabela está nos comentários (`COMMENT ON TABLE/COLUMN`) dentro das próprias migrations — a intenção é que o schema seja autoexplicativo via `\d+` / `information_schema`, sem depender só deste documento.

### 4.1 Grupos de tabelas (Fase 1)

1. **Infraestrutura óptica**: `cidades_infra`, `infra_cabos`, `infra_segmentos`, `infra_fibras`, `infra_postes`, `ativos`.
2. **Comercial**: `parceiros`, `contratos`, `contrato_fibras`, `contrato_ativos`, `contrato_regras`, `contrato_clientes_reservados`.
3. **Medição / Revenue Assurance** (estrutura criada na Fase 1, alimentada de verdade a partir da Fase 4/5): `medicoes_mensais`, `medicao_clientes`, `medicao_faturamento`, `medicao_recebimentos`.
4. **Pricing** (estrutura criada na Fase 1; motor de cálculo entra na Fase 2): `pricing_parametros`, `pricing_versions`, `simulacoes`.
5. **Suporte transversal**: `indices_economicos`, `reajustes`, `alertas`, `documentos`, `integracoes`, `integracao_logs`, `auditoria`, `usuarios`.

## 5. Controle de capacidade óptica

**Atualizado na Fase 1.1** — ver seção 11 para o modelo completo (porta PON, POP, status separado em 3 dimensões). Resumo: `par_numero` em `infra_fibras` continua existindo (duas fibras do mesmo cabo ainda podem ser identificadas como par, e `vw_pares_disponiveis` continua funcionando), mas **não é mais requisito de comercialização** — um contrato pode usar 1, 2 ou N fibras, formem par ou não. `contrato_fibras` continua sendo a fonte de verdade de "qual contrato usa qual fibra" (agora com `porta_pon_id` opcional), e a atualização automática de status ao vincular/desvincular um contrato agora mexe só em `status_contratual`, nunca em `status_comercial` — corrige um bug real da Fase 1 (ver seção 11.1).

## 6. Exclusividade, clientes reservados e bloqueios (seção 21-24)

`contrato_regras` guarda, por contrato: exclusividade comercial (bool), área de exclusividade (texto/geometria simples nesta fase), proibição de fibra de terceiros, proibição de rede própria, direito de preferência, exigência de aprovação. `contrato_clientes_reservados` lista clientes (ex.: Prefeitura de Jussara) que o parceiro nunca pode vender/atender/prospectar/migrar sem aprovação expressa — a validação de bloqueio de proposta comercial para cliente reservado é responsabilidade do backend (Fase 2, ao implementar `/api/propostas`), mas a tabela e a constraint de unicidade (`cliente + contrato`) já existem na Fase 1.

Workflow de aprovação (solicitação → aprovação/rejeição) para fibra de terceiros e rede própria é modelado como uma tabela leve `contrato_regras_solicitacoes` (status `PENDENTE/APROVADA/REJEITADA`, quem decidiu, quando), sempre auditado via a tabela `auditoria` central.

## 7. Governança de contratos e pricing (seção 14 e 37)

Nenhum contrato aprovado é alterado silenciosamente. `contratos` tem `versao_atual` e a tabela `contrato_versions` (histórico completo, snapshot em `jsonb`) recebe uma linha nova a cada alteração pós-aprovação — o registro antigo nunca é sobrescrito. O mesmo padrão vale para pricing: `pricing_versions` versiona parâmetros comerciais (V1/V2/V3...), preservando o snapshot aplicado em cada período, para que reajustes nunca recalculem contratos históricos.

## 8. Auditoria (seção 33)

Tabela `auditoria` única para o sistema todo: `usuario_id`, `criado_em`, `ip`, `acao`, `entidade`, `entidade_id`, `valor_anterior jsonb`, `valor_novo jsonb`, `origem`, `motivo`. Populada por triggers genéricos (`fn_auditoria()`) — não depende de o backend lembrar de logar. RLS na tabela: `INSERT` liberado só via `SECURITY DEFINER` function chamada pelos triggers; `UPDATE`/`DELETE` bloqueados para todos os perfis, inclusive `ADMINISTRADOR`.

**Fase 1.1**: `fn_auditoria()` passou a tentar capturar o IP do cliente via `current_setting('request.headers')` (o jeito como PostgREST/Supabase expõem o header `x-forwarded-for`), com fallback seguro para `null` fora desse contexto — na Fase 1 a coluna `ip` nunca era preenchida. Também foi corrigida uma lacuna: `contrato_regras_solicitacoes` (aprovação de fibra de terceiros/rede própria) nunca tinha trigger de auditoria na Fase 1. Tabelas auditadas hoje: `contratos`, `contrato_regras`, `contrato_regras_solicitacoes`, `contrato_clientes_reservados`, `contrato_aditivos`, `contrato_metas`, `contrato_pricing_config`, `contrato_fibras`, `pricing_parametros`, `pricing_versions`, `medicoes_mensais`, `usuarios`, `ativos`, `integracoes`, `infra_pops`, `infra_portas_pon`.

## 9. API interna (contrato para a Fase 2 em diante)

Endpoints já reservados na Fase 1 (implementação dos handlers é Fase 2+, mas o desenho de dados já suporta todos):

```
/api/cidades
/api/fibras
/api/ativos
/api/parceiros
/api/contratos
/api/contratos/{id}/regras
/api/contratos/{id}/medicoes
/api/pricing/simular
/api/pricing/recalcular
/api/roi
/api/reajustes
/api/indices
/api/alertas
/api/integracoes/hubsoft
/api/integracoes/financeiro
/api/propostas
/api/documentos
/api/auditoria
```

## 10. Pricing Engine — estrutura de módulos (preparação para Fase 2)

```
backend/src/pricing/
  dark-fiber/        # Preço = taxa_base + (pares × km × preço_par_km)
  hybrid/             # Mensalidade = Fixo + MAX(Revenue Share, Take-or-Pay)
  revenue-share/
  take-or-pay/
  ramp/               # rampa de maturação, parametrizável por contrato
  reajuste/           # aplica IPCA/índice validado, gera nova pricing_version
  roi/
  simulator/          # 12/36/48/60 meses, dark fiber vs híbrido
```

Regra dura: fórmulas de pricing nunca ficam em controllers HTTP — só nesses módulos, cobertos por testes unitários (Fase 2). A Fase 1 já cria as tabelas (`pricing_parametros`, `pricing_versions`, `simulacoes`) para que nenhum valor comercial fique hard-coded, mesmo antes do motor existir.

## 11. Fase 1.1 — porta PON, POP, capacidade, aditivos, metas e exclusividade escopada

A Fase 1.1 corrige um erro conceitual da Fase 1: o par óptico **não** é a unidade comercial do OptiMon. É a **porta PON**.

### 13.1 Conceitos

- **Fibra** (`infra_fibras`) — continua sendo a unidade física. Nada muda aqui estruturalmente, mas o campo único `status` da Fase 1 foi separado em três dimensões independentes, porque um único campo estava misturando três perguntas diferentes:
  - `status_operacional` — a fibra funciona fisicamente? (`ATIVA`, `MANUTENCAO`, `ROMPIDA`, `DESATIVADA`) — gerido por ENGENHARIA.
  - `status_comercial` — pode ser oferecida a parceiros? (`LIVRE`, `RESERVADA`, `BLOQUEADA`) — decisão de política comercial, nunca alterada automaticamente por vínculo/desvínculo de contrato.
  - `status_contratual` — está vinculada a um contrato agora? (`DISPONIVEL`, `VINCULADA`) — só isto o trigger de vínculo contratual mexe.

  Essa separação corrige um bug real da Fase 1: o trigger de sincronização jogava a fibra para `LIVRE` sempre que um contrato era desvinculado — se uma fibra algum dia fosse `BLOQUEADA` (ex.: reservada à Prefeitura) e, por engano, chegasse a ser contratada e depois desvinculada, ela voltaria a aparecer como `LIVRE`. Agora `status_comercial` nunca é tocado por esse trigger. O campo `status` original foi mantido (compatibilidade), mas marcado como `DEPRECATED`.

- **POP** (`infra_pops`) — Ponto de Presença. Uma cidade tem N POPs (`PRINCIPAL`, `DISTRIBUICAO`, `ACESSO`, `OUTRO`). Um cabo (`infra_cabos.pop_id`) pertence a um POP; a fibra herda o POP do seu cabo.

- **Porta PON** (`infra_portas_pon`) — a unidade comercial. 1 fibra → até 1 porta PON → até `capacidade_max_assinantes` clientes (128 por padrão, mas **parametrizável**: o valor vive em `pricing_parametros.PORTA_PON_CAPACIDADE_MAX_PADRAO`, nunca hard-coded em DDL — um trigger só usa esse parâmetro como *fallback* quando a porta é criada sem capacidade explícita). `capacidade_disponivel` e `taxa_ocupacao` são colunas geradas (`GENERATED ALWAYS AS ... STORED`) — nunca divergem do que está em `capacidade_max/utilizada_assinantes`. Um `CHECK` impede `capacidade_utilizada_assinantes > capacidade_max_assinantes` (cliente nunca pode superar a capacidade da porta) e um trigger valida que a porta aponta para uma fibra cujo cabo realmente pertence ao POP declarado.

- **Cliente ≠ fibra**: a cadeia é `Cliente → Porta PON → Fibra → POP → Contrato → Parceiro`. Uma porta pode ter de 1 a 128 clientes; o parceiro paga pela disponibilidade da porta/fibra, não por cliente.

### 13.2 Contrato como unidade de cessão flexível

`contrato_fibras` ganhou `porta_pon_id`, `capacidade_clientes`, `status`, `observacoes` e `compartilhamento_autorizado`. Um contrato pode usar **1 fibra isolada** — não existe mais nenhuma exigência de segunda fibra para formar par. A constraint que impede a mesma fibra (ou a mesma porta) em dois contratos ativos simultâneos continua existindo (`contrato_fibras_fibra_ativa_idx` / `contrato_fibras_porta_ativa_idx`), mas agora tem uma válvula de escape explícita: quando `compartilhamento_autorizado = true`, o índice parcial deixa de aplicar — é a exceção "modelo de compartilhamento autorizado" pedida no prompt.

Um contrato pode usar portas em **múltiplos POPs** ao mesmo tempo — não há relação obrigatória "1 contrato = 1 infraestrutura". `vw_capacidade_contrato.pops_utilizados` mostra quantos POPs distintos um contrato usa.

### 13.3 Aditivos e metas

`contrato_aditivos` registra inclusão/exclusão de fibras/portas e outras alterações pós-assinatura, sempre com `snapshot_anterior`/`snapshot_novo`. Um trigger (`fn_aditivo_gera_versao`) gera **automaticamente** uma nova `contrato_versions` quando o aditivo é aprovado — nenhum aditivo altera o contrato original silenciosamente.

`contrato_metas` guarda metas de desempenho por período (clientes mínimos, faturamento mínimo, ocupação mínima) com uma `consequencia` sempre parametrizável (`SEM_CONSEQUENCIA`, `RENEGOCIACAO`, `PERDA_DE_EXCLUSIVIDADE`, `REDUCAO_DE_CAPACIDADE`, `NOTIFICACAO`, `RESCISAO`, `OUTRA`) — rescisão automática nunca é o comportamento padrão.

### 13.4 Modelo comercial parametrizável por contrato

`contrato_pricing_config` (1:1 com `contratos`) define, por contrato:

- `modelo_cobranca`: `MAX` (Modelo A — `MAX(mensalidade mínima, revenue share)`) ou `SOMA` (Modelo B — `mensalidade mínima + revenue share`).
- `base_calculo_revenue_share`: `FATURAMENTO_BRUTO` / `FATURAMENTO_LIQUIDO` / `FATURAMENTO_ELEGIVEL`.
- `modelo_minimo`: `POR_PORTA` (mínimo × nº de portas) ou `GLOBAL` (um mínimo único para o contrato).
- `rampa_aplica_a`: `FIXO_MINIMO` / `REVENUE_SHARE` / `AMBOS`.
- `metodo_precificacao_dark_fiber`: `POR_PORTA` / `POR_FIBRA` / `POR_KM` / `POR_POP`.

Não existe fórmula global fixa no sistema — o Pricing Engine da Fase 2 lê esta tabela por contrato. `medicao_faturamento_clientes` complementa `medicao_faturamento` (Fase 1) com detalhe opcional por cliente/porta PON, para revenue share granular quando o parceiro conseguir identificar o cliente — a medição agregada continua aceita quando não conseguir.

### 13.5 Exclusividade escopada e conflito entre parceiros

`contrato_regras` ganhou escopo explícito de exclusividade: `exclusividade_cidade_id`, `exclusividade_pop_id`, `exclusividade_servico`, `exclusividade_capacidade_max`, `exclusividade_prazo_meses` — uma constraint impede `exclusividade_comercial = true` sem nenhum escopo definido (não pode mais significar "cidade inteira" por omissão). `direito_proprietario_explorar_capacidade_remanescente` e `permite_outros_parceiros` são parametrizáveis por contrato (ambos default `true`).

A função `app.check_contract_conflict(cidade_id, parceiro_id, pop_id, servico)` retorna `ALLOW` / `BLOCK` / `REQUIRES_APPROVAL` antes de uma nova contratação, considerando exclusividade de outros parceiros ativos escopada por POP/cidade/serviço. Como ainda não existe backend (ver seção 14), a função vive no banco — o backend da Fase 2 a chama antes de aprovar qualquer contrato, mas mesmo um acesso direto ao banco já fica coberto pela regra.

### 13.6 Segurança e visibilidade de dados sensíveis

Todas as policies de RLS passaram a declarar `to authenticated` explicitamente (na Fase 1 o papel era implícito). Dados financeiros por medição (`medicoes_mensais`, `medicao_clientes`, `medicao_faturamento`, `medicao_recebimentos`, `medicao_faturamento_clientes`) deixaram de ser legíveis por todo perfil interno — agora só `FINANCEIRO`/`DIRETOR`/`ADMINISTRADOR`/`AUDITOR`. `vw_integracoes_seguro` expõe as integrações sem a coluna de credenciais, com o próprio filtro de perfil embutido na view (views não têm RLS própria).

### 13.7 Views de capacidade

`vw_capacidade_cidade` foi recriada (colunas novas — fibras + portas PON + clientes) e três views novas foram adicionadas: `vw_capacidade_pop`, `vw_capacidade_parceiro`, `vw_capacidade_contrato`. Todas se apoiam em `vw_porta_pon_detalhe`, que resolve "esta porta está contratada agora?" uma única vez.

### 13.8 O que fica assumidamente incompleto nesta fase (sem backend)

- Bloqueio 100% automático de "proposta para cliente reservado" depende de um objeto "proposta com cliente nomeado" que só existe de fato com a integração HubSoft (Fase 4). O que existe hoje: `contrato_clientes_reservados` funcional e auditado.
- O teste "`GET /api/integracoes` não retorna secrets" não é executável — não existe API ainda. O que existe: RLS restringe a tabela crua a `ADMINISTRADOR`, e `vw_integracoes_seguro` nunca expõe a coluna de credenciais.
- Take-or-Pay e rampa em R$ não são calculáveis — não existe Pricing Engine (Fase 2). O que foi validado: os parâmetros existem, são parametrizáveis (sem hard-code) e o contrato já declara qual fórmula/base usar.

## 12. Roteiro de fases (do Prompt Mestre, seção 40)

| Fase | Escopo |
|---|---|
| 1 (esta entrega) | Banco + Auth + Infraestrutura + Parceiros + Contratos |
| 1.1 (esta entrega) | Porta PON como unidade comercial, POPs, aditivos, metas, exclusividade escopada |
| 1.2 (esta entrega) | Hardening comercial: SOMA padrão, capacidade contratada×reservada×ativa, conflito compartilhamento×exclusividade, cliente→porta PON, preparação de pricing |
| 2 (esta entrega) | Pricing Engine completo (Dark Fiber + Revenue Share) + Simulador Comercial + Projeção Financeira + ROI + Payback + Governança + Override + Dashboard + API source-only — ver seção 15 |
| 3 | Dashboard de produção (deploy real) + Relatórios executivos persistidos |
| 4 | Integração HubSoft |
| 5 | Integração financeira dos parceiros (adapters REST/Webhook/SFTP-CSV) |
| 6 | IBGE/SIDRA + reajustes automáticos |
| 7 | Alertas + auditoria avançada |
| 8 | Propostas + contratos + documentos |

> A Fase 2 não avança automaticamente para a Fase 3 (seção 66 do Prompt Mestre) — a próxima etapa será definida pelo usuário.

Ao final de cada fase: rodar testes, validar migrations/RLS/permissões/fórmulas, documentar mudanças, sem quebrar o que já existe.

## 13. O que esta entrega NÃO inclui (de propósito)

Conforme instrução explícita do Prompt Mestre ("comece analisando a arquitetura e gere primeiro o plano técnico e o schema/migrations — não pule para uma UI superficial"), esta entrega é **banco + arquitetura**, sem código de frontend/backend ainda. Os próximos passos naturais são: (a) scaffold do projeto Next.js/Node, (b) autenticação Supabase ligada à tabela `usuarios`, (c) CRUD de cidades/fibras/parceiros/contratos, (d) início do Pricing Engine (Fase 2). A Fase 1.2 manteve essa mesma disciplina — é hardening de modelagem/integridade, não a implementação do Pricing Engine, do Dashboard, do HubSoft ou de qualquer UI (ver seção 14.8).

## 14. Fase 1.2 — Hardening do modelo comercial e preparação para o Pricing Engine

Quatro correções comerciais/estruturais sobre o que a Fase 1.1 entregou, sem reconstruir nada e sem apagar as 34 migrations anteriores: 7 migrations novas (prefixo `20260826...`), só `ALTER`/`CREATE` aditivos.

### 14.1 SOMA como modelo híbrido padrão

`contrato_pricing_config.modelo_cobranca` passou a ter `DEFAULT 'SOMA'` (era `MAX`). Como `ALTER COLUMN ... SET DEFAULT` nunca reescreve linhas já gravadas, os dois contratos do seed da Fase 1.1 continuam exatamente como foram criados (0002 = MAX, 0003 = SOMA) — só *novos* `INSERT`s sem informar o modelo passam a resolver para SOMA (testado explicitamente). MAX continua disponível e é escolha explícita do contrato, nunca removido.

A fórmula (`app.calcular_cobranca_hibrida`) e o mínimo contratual (`app.calcular_minimo_contratual`) foram implementados como funções SQL/PLpgSQL — não é o Pricing Engine completo da Fase 2 (sem dark fiber, ROI, payback, rampa em R$), é só a fórmula MÍNIMO+SHARE / MAX(MÍNIMO,SHARE) descrita nas seções 2/3 do prompt, parametrizada por `contrato_pricing_config` (nunca 12% fixo no código — vem de `pricing_parametros.REVENUE_SHARE_PADRAO` como fallback quando o contrato não especifica).

### 14.2 Capacidade: contratada × reservada × ativa

Cada porta PON (`infra_portas_pon`) ganhou `situacao_comercial` (`DISPONIVEL`/`RESERVADA`/`ATIVA`), mantida por `app.recalcular_situacao_porta()` — nunca editada manualmente, sempre derivada de (a) existir vínculo ativo em `contrato_fibras` e (b) a porta ter algum cliente real. A partir disso, `capacidade_contratada_assinantes`, `capacidade_ativa_assinantes` e `capacidade_reservada_assinantes` são colunas geradas (nunca divergem), e cinco funções por contrato (`app.get_contract_capacity`, `get_reserved_capacity`, `get_active_capacity`, `get_occupied_capacity`, `get_available_capacity`) + a view `vw_contrato_capacidade` dão as duas métricas de ocupação da seção 7 do prompt lado a lado (sobre capacidade ativa vs. sobre capacidade contratada), sempre identificáveis separadamente.

A reserva de capacidade não é gratuita por padrão: `contrato_pricing_config.cobranca_portas_reservadas` (default `true`) faz `calcular_minimo_contratual()` cobrar sobre **todas** as portas contratadas (reservadas + ativas), não só as ativas — parametrizável por contrato para o caso especial de `false`.

### 14.3 Compartilhamento × exclusividade — nunca os dois ao mesmo tempo

Uma lacuna real da Fase 1.1 foi corrigida aqui: o índice único parcial que impedia dois vínculos exclusivos na mesma porta (`contrato_fibras_porta_ativa_idx`) só considerava linhas com `compartilhamento_autorizado=false` entre si — nada impedia um vínculo `compartilhamento_autorizado=TRUE` coexistir com outro `FALSE` na mesma porta ao mesmo tempo. O trigger novo `fn_valida_conflito_compartilhamento` fecha essa lacuna para qualquer forma de escrita (inclusive SQL direto, não só via uma futura API): um recurso (fibra ou porta PON) só pode estar **EXCLUSIVA** ou **COMPARTILHADA**, nunca as duas.

`compartilhamento_autorizado` continua com `DEFAULT false` (era assim desde a Fase 1.1). Ativar `true` — seja o primeiro vínculo do recurso ou juntar-se a um recurso já compartilhado — agora exige `DIRETOR`/`ADMINISTRADOR`; `ENGENHARIA` pode gravar em `contrato_fibras` (RLS de escrita já permitia desde a Fase 1.1) mas o trigger bloqueia especificamente essa ação com uma exceção `REQUIRES_APPROVAL`, coerente com a seção 9 do prompt ("ENGENHARIA pode solicitar, mas não aprovar").

`app.check_resource_conflict()` é a checagem pura (não grava nada) que combina essa regra de recurso físico com a exclusividade territorial já existente (`app.check_contract_conflict`, Fase 1.1) — mesma precedência ALLOW < REQUIRES_APPROVAL < BLOCK.

### 14.4 Cliente → Porta PON

Tabela nova `cliente_porta_pon` (`cliente_identificador`, `cliente_hubsoft_id` opcional, `contrato_id`, `porta_pon_id`, `pop_id`, `fibra_id`, `status` `ATIVO`/`SUSPENSO`/`CANCELADO`/`PENDENTE`/`MIGRADO`, `origem`) — preparação explícita para a integração HubSoft da Fase 4, sem assumir que o cliente já tem ID do HubSoft hoje. Só clientes `ATIVO` consomem capacidade da porta; a contagem é recalculada automaticamente a cada mudança (`fn_cliente_porta_pon_sync_capacidade`), inclusive gerando os alertas `CAPACIDADE_80`/`90`/`100` (thresholds parametrizáveis em `pricing_parametros`, nunca hard-coded) e bloqueando com `CAPACITY_EXCEEDED` qualquer tentativa de ativar além de `capacidade_max_assinantes` — a regra vive no banco, não só no frontend.

Portas sem nenhuma linha em `cliente_porta_pon` (as três do seed da Fase 1.1: PON-JUS-001/002/003) nunca são tocadas por essa sincronização — continuam com o valor de `capacidade_utilizada_assinantes` que já tinham, intocado, até o dia em que ganharem sua primeira linha real.

### 14.5 Aditivos e exclusividade — tipos ampliados

`contrato_aditivos.tipo` ganhou `ALTERACAO_CAPACIDADE`, `ALTERACAO_EXCLUSIVIDADE` e `ALTERACAO_REGRAS_COBRANCA` (além dos tipos já existentes desde a Fase 1.1) — cobre explicitamente o que a seção 15 do prompt pede. `contrato_regras` ganhou `exclusividade_tipo` (TERRITORIAL/SERVICO/CAPACIDADE/MISTA) — campo informativo; o escopo que efetivamente bloqueia (cidade/POP/serviço/capacidade/prazo) já existia desde a Fase 1.1.

### 14.6 Solicitações sempre nascem PENDENTE

Outra lacuna fechada: a policy de `INSERT` de `contrato_regras_solicitacoes` (Fase 1) permitia que `COMERCIAL` criasse a solicitação, mas nunca restringia o `status` informado nesse `INSERT` — só a policy de `UPDATE` ("decide") era restrita a `DIRETOR`/`ADMINISTRADOR`. Um `INSERT` direto já como `APROVADA` não era barrado pela RLS. O trigger `fn_solicitacao_nasce_pendente` fecha isso: toda solicitação nasce `PENDENTE`, a menos que quem a crie já seja `DIRETOR`/`ADMINISTRADOR`.

### 14.7 Segurança e auditoria

`cliente_porta_pon` entrou na auditoria automática (`trg_aud_cliente_porta_pon`) e ganhou RLS própria (leitura geral; escrita para `COMERCIAL`/`ENGENHARIA`/`DIRETOR`/`ADMINISTRADOR`; exclusão só `ADMINISTRADOR`). Nada muda em `vw_integracoes_seguro`/RLS de `integracoes` (já corretas desde a Fase 1.1) — o teste de que credenciais nunca aparecem fora do `ADMINISTRADOR` foi reexecutado (seção 17 da bateria de testes) e continua passando.

### 14.8 O que a Fase 1.2 deliberadamente NÃO fez

Por instrução explícita do prompt (seção 32, "não avançar para Fase 2"): nenhum Pricing Engine completo (dark fiber por km/POP, ROI, payback, simulação de cenários, rampa em R$ de verdade), nenhum Dashboard, nenhum HubSoft, nenhuma API REST, nenhuma UI. As duas funções de cálculo desta fase (`calcular_minimo_contratual`, `calcular_cobranca_hibrida`) existem só porque os testes obrigatórios 1/2/3/6/7 da seção 29 do prompt exigem um resultado numérico verificável — são deliberadamente estreitas (a fórmula MÍNIMO+SHARE/MAX, nada além disso).

## 15. Fase 2 — Pricing Engine, Simulador Comercial e ROI

10 migrations novas (prefixo `20260827...`), todas `CREATE`/`ALTER` aditivos — nenhuma migration anterior (Fase 1/1.1/1.2) foi tocada, nenhuma tabela existente foi reconstruída. A Fase 2 constrói o núcleo econômico do OptiMon sobre o modelo comercial que a Fase 1.2 deixou pronto (SOMA padrão, capacidade contratada×reservada×ativa, cliente→porta PON).

### 15.1 Custos da infraestrutura (seções 7-10)

`custos_infraestrutura` classifica cada custo com `cost_type` (`HISTORICAL_CAPEX` / `EXISTING_OPEX` / `INCREMENTAL_OPEX` / `INCREMENTAL_CAPEX` / `ALLOCATED_COST` / `REVENUE_EXISTING` / `OTHER`), com descrição, valor, periodicidade, cidade, POP/poste/cabo/ativo/contrato opcionais, `metodo_rateio`, `percentual_alocacao`, vigência (`data_inicio`/`data_fim`) e observações. Duas constraints nomeadas (`custos_infraestrutura_incremental_opex_precisa_origem` / `_capex_precisa_origem`) impedem que um custo `INCREMENTAL_*` exista sem uma origem clara (contrato ou método de rateio) — não dá para marcar algo como "custo incremental" sem dizer de onde ele vem.

**A regra central da seção 7 é aplicada em `app.get_custo_base_precificacao(contrato_id)`**: soma apenas `INCREMENTAL_OPEX` e `INCREMENTAL_CAPEX` ligados diretamente ao contrato, mais `ALLOCATED_COST` rateado proporcionalmente à fração de fibras que aquele contrato ocupa do total da cidade. `HISTORICAL_CAPEX`, `EXISTING_OPEX` e `REVENUE_EXISTING` **nunca** entram na base de precificação — são custos/receitas que já existiam antes do contrato e não são repassáveis automaticamente ao parceiro, exatamente como a seção 7 exige ("não considerar automaticamente todo o custo histórico da rede como custo incremental"). `app.ratear_custo(custo_id)` devolve o valor rateado por unidade (poste/km/fibra/porta, conforme `metodo_rateio` escolhido pelo usuário — seção 10).

**Caso Jussara (seção 8), classificado no seed (seção 9)**: dos 4 custos reais informados no prompt, os 165 postes (R$ 1.108,80/mês) entraram como `ALLOCATED_COST`/`POR_POSTE` (rateável), o link 1 Gbps (R$ 1.500/mês) e a manutenção terceirizada (R$ 500/mês) entraram como `EXISTING_OPEX` (custo que já existe independente de qualquer parceiro novo), e o contrato da Prefeitura (R$ 11.000/mês) entrou como `REVENUE_EXISTING` (receita que já existe, não custo). Nenhum `HISTORICAL_CAPEX` foi semeado — o prompt não informa o valor histórico de implantação da rede, e a seção 65 proíbe inventar esse número. Isso significa, na prática, que **nenhum dos 4 custos de Jussara entra automaticamente na base de precificação de um novo contrato** — só entraria se o usuário classificasse explicitamente uma fração como `INCREMENTAL_*` ligada ao contrato, que é exatamente o comportamento pedido pela seção 8 ("não assumir que 100% desses custos devem ser repassados ao parceiro").

### 15.2 Dark Fiber — mínimo, recomendado, premium e escassez (seções 5-6, 11-14)

`metodo_precificacao_dark_fiber` (enum já existente desde a Fase 1.1/1.2) ganhou o valor `HIBRIDO`, completando as 5 unidades de precificação da seção 6: `POR_FIBRA` / `POR_KM` / `POR_PON` / `POR_POP` / `HIBRIDO` (mapeado ao `pricing_method` do prompt: `PER_FIBER`/`PER_KM`/`PER_PON`/`PER_POP`/`HYBRID`).

`contrato_pricing_config` ganhou 4 colunas nullable: `margem_minima_percent`, `fator_risco_percent`, `payback_minimo_meses`, `margem_minima_parceiro_percent` — todas `NULL` por padrão (seção 65: nenhum valor é inventado; um contrato sem esses parâmetros configurados faz as funções de preço devolverem `NULL` em vez de aplicar um número que ninguém pediu).

- **`app.calcular_preco_minimo_dark_fiber(contrato_id)`** = `MAX(custo_base_precificação, piso_global_por_par × pares_contratados) × (1 + margem_minima_percent + fator_risco_percent)`. Considera custo incremental (15.1), risco, prazo (via `payback_minimo_meses`, avaliado por `app.avaliar_payback_minimo`) e capacidade contratada (pares).
- **`app.calcular_preco_recomendado_dark_fiber(contrato_id)`** = preço mínimo × `DARK_FIBER_MULTIPLICADOR_RECOMENDADO` (parâmetro global, 1,20 — já seedado na Fase 1) × `capacity_scarcity_factor` (escassez). Sempre > preço mínimo por construção (multiplicador > 1 e fator de escassez ≥ 1).
- **`app.calcular_preco_premium_dark_fiber(contrato_id)`** = preço recomendado × `DARK_FIBER_MULTIPLICADOR_PREMIUM` (1,50, já seedado) × bônus de exclusividade (`DARK_FIBER_PREMIO_EXCLUSIVIDADE`) × bônus multi-POP (`DARK_FIBER_PREMIO_MULTIPOP`) — ambos seedados como **1,00 (neutro)** porque o prompt não define um valor concreto para esses bônus (seção 65); a lógica está pronta e é parametrizável, mas hoje o premium não recebe sobretaxa automática por exclusividade/multi-POP até que alguém configure esses parâmetros. Deliberadamente **não** é "recomendado × 2" (seção 13).
- **`app.get_capacity_scarcity_factor(cidade_id)`** lê `pricing_faixas_escassez` (faixas configuráveis, seed literal da seção 14: disponibilidade > 50% → fator 1,00; 30%-50% → 1,15; 10%-30% → 1,35; < 10% → 1,60) a partir de `app.get_disponibilidade_fibra_cidade`.

### 15.3 Revenue Share, SOMA/MAX, break-even (seções 15-21, 42)

O modelo de Cenário 2 (Porta PON + Revenue Share) já existia em grande parte desde a Fase 1.2 (`app.calcular_cobranca_hibrida`, `app.calcular_minimo_contratual`, `modelo_cobranca` SOMA/MAX, `minimum_scope` PER_PON/PER_CONTRACT, `cobranca_portas_reservadas` default `TRUE`, `revenue_share_percent` default 12% sobre `base_calculo_revenue_share`). A Fase 2 completa esse cenário com:

- **`app.calcular_breakeven_faturamento(contrato_id)`** = `mínimo / revenue_share_percent` — ponto em que Revenue Share ultrapassa o mínimo (seção 42).
- **`app.calcular_breakeven_clientes(contrato_id, arpu)`** = `ceil(breakeven_faturamento / arpu)`.
- **`app.get_portas_necessarias(clientes, capacidade_por_porta)`** = `ceil(clientes / capacidade)`, com fallback para `pricing_parametros.PORTA_PON_CAPACIDADE_MAX_PADRAO` quando a capacidade não é informada (nunca hard-coded — seções 20, 23, 44).

### 15.4 ARPU, simulador de clientes, crescimento, rampa (seções 22-26)

ARPU (com crescimento anual opcional) e cenários de clientes (fixos ou por checkpoints) são parâmetros de entrada do `ScenarioSimulator` (15.6), não tabelas — o simulador é uma ferramenta de "e se", não um cadastro. `pricing_ramp_rules` guarda a rampa de maturação como dado, não como código: `month_start`, `month_end` (nullable = "em diante"), `percentage`, `component` (`FIXO_MINIMO`/`REVENUE_SHARE`/`AMBOS`), com escopo por contrato ou global (`contrato_id` nullable). Seed default replica o exemplo literal do prompt: meses 1-3 → 50%, 4-6 → 75%, 7+ → 100%, aplicado a `AMBOS` os componentes. `app.get_fator_rampa(contrato_id, mes, componente)` resolve contrato → global → 1,00 (sem rampa) como fallback.

### 15.5 Reajuste anual (seções 27-29)

`contrato_pricing_config.indice_reajuste` (`IPCA` default / `IGPM` / `FIXO` / `SEM_REAJUSTE`). **Não há integração automática com IBGE nesta fase** (proibido pela seção 54) — `app.aplicar_reajuste_contrato(contrato_id, percentual, competencia_base, indice_id, motivo)` aplica o percentual **informado manualmente**, snapshota o estado anterior em `pricing_versions` (nova versão, nunca sobrescreve a antiga), registra em `reajustes` (status `APLICADO`) e só então atualiza os valores correntes do contrato — preservando o histórico e nunca recalculando cobranças passadas. Só `FINANCEIRO`/`ADMINISTRADOR` podem chamá-la (checado dentro da própria função, que é a única exceção `SECURITY DEFINER` desta fase, documentada e auditada — ver 15.9).

Contrato mínimo continua **48 meses** (regra já existente desde a Fase 1). O simulador (15.6) aceita qualquer `meses_horizonte` para análise (12/36/48/60), mas isso nunca é interpretado como autorização para um contrato mais curto — são apenas horizontes de leitura do resultado, nunca um prazo contratual.

### 15.6 ScenarioSimulator, projeção financeira, ROI, payback, margem (seções 30-33, 37-41)

**`app.simular_projecao(params jsonb)`** é o `ScenarioSimulator` da seção 51 — recebe um contrato de parâmetros (mínimo mensal, revenue share %, ARPU inicial e crescimento, clientes iniciais e modo de crescimento `LINEAR` ou `CHECKPOINTS`, capacidade por porta, CAPEX incremental, OPEX incremental, meses de horizonte) e devolve, mês a mês: clientes, portas necessárias, ARPU do mês, faturamento do parceiro, fator de rampa, mínimo (com rampa), revenue share (com rampa), receita OptiMon (SOMA ou MAX conforme o contrato), OPEX incremental, resultado, margem, CAPEX do mês, fluxo de caixa e os acumulados — exatamente as colunas da tabela da seção 30.

- **ROI** (`app.calcular_roi`): `(fluxo_de_caixa_acumulado_líquido_de_CAPEX_no_mês_N) / investimento`. Se investimento = 0, devolve `null`/"N/A — sem CAPEX incremental" em vez de dividir por zero (seção 31) — nunca inventa um ROI para um cenário sem CAPEX.
- **Payback** (`app.calcular_payback`): primeiro mês em que o fluxo de caixa acumulado (líquido de CAPEX) ≥ investimento; se nunca ocorrer no horizonte simulado, devolve "Não recuperado no período" (seção 32).
- **Margem**: calculada em 3 granularidades por mês (mensal, acumulada, sobre receita) e nunca mistura margem do parceiro com margem do OptiMon — são calculadas por funções e campos distintos (15.7 trata a margem do parceiro).

Os 3 gráficos das seções 39-41 (Receita OptiMon × crescimento do parceiro identificando o ponto Revenue Share > Mínimo; fluxo de caixa acumulado; ocupação da capacidade) são renderizados no dashboard (15.10) a partir da mesma saída de `simular_projecao` — não há dado calculado separadamente para o gráfico.

### 15.7 Economia do parceiro e viabilidade (seções 34-35, 56-57)

**`app.calcular_economia_parceiro(faturamento_parceiro, pagamento_optimon, custos_proprios_parceiro)`** implementa literalmente a cadeia da seção 34: faturamento − pagamento OptiMon = receita restante − custos próprios = margem estimada do parceiro. **`app.avaliar_viabilidade_parceiro(contrato_id, margem_percentual_parceiro)`** compara contra `margem_minima_parceiro_percent` (seção 15.2) e devolve um alerta textual ("MODELO COMERCIAL POTENCIALMENTE INVIÁVEL PARA O PARCEIRO") quando abaixo do limite — **nunca bloqueia** a simulação nem a proposta, só avisa (seção 35).

**`app.classificar_negocio(contrato_id, margem_percentual_parceiro, roi_optimon)`** implementa a seção 57: `INVIAVEL` quando a margem do parceiro está abaixo do mínimo configurado; `VIAVEL` quando está no mínimo ou acima; `EXCELENTE` quando margem do parceiro **e** ROI do OptiMon estão acima dos respectivos limites. Como o prompt não define esses limites de "excelência" (nem o mínimo padrão de viabilidade do parceiro além do exemplo ilustrativo de 20%), a função devolve `PARAMETRIZÁVEL` quando os parâmetros necessários não estão configurados — nunca um valor calculado sobre um limiar inventado (disciplina da seção 65).

### 15.8 Governança de preço e override manual (seções 46, 48-49, 60)

**`app.check_pricing_governance(preco_proposto, preco_minimo, preco_recomendado)`** implementa a régua da seção 49: `preco >= recomendado` → `ALLOW` (Comercial gera proposta livremente); `mínimo <= preço < recomendado` → `REQUIRES_APPROVAL` (exige justificativa); `preço < mínimo` → `BLOCK` (só contornável via override aprovado por Diretor).

`pricing_override_requests` (seção 48): `desconto_percentual` é **coluna gerada** (`(preco_recomendado - preco_solicitado) / preco_recomendado`) — nunca editável diretamente, para o desconto exibido nunca divergir do preço realmente solicitado. `justificativa` tem `CHECK` de não-vazio. Um trigger (`fn_override_nasce_pendente`) garante que toda solicitação nasce `PENDENTE` (Comercial não pode inserir já `APROVADA`); outro (`fn_override_decisao`) torna a decisão imutável depois de tomada e exige `DIRETOR`/`ADMINISTRADOR` para decidir — Comercial nunca se autoaprova, e a RLS reforça a mesma regra independentemente do trigger.

`propostas_comerciais` guarda o **snapshot imutável** da seção 60 (cidade, POP, fibras, portas, capacidade, modelo, mínimo, revenue share, ARPU, clientes, rampa, reajuste, prazo, preço, ROI, payback, `pricing_version`) em uma coluna `jsonb`; um trigger (`fn_proposta_snapshot_imutavel`) impede alterar esse snapshot depois de criado — propostas antigas nunca são recalculadas com regras novas, mesmo que os parâmetros globais mudem depois.

`pricing_versions` (tabela já existente desde a Fase 1) continua sendo o mecanismo de versionamento (seção 46): cada reajuste ou mudança de parâmetro gera uma nova versão numerada, a antiga nunca é sobrescrita.

### 15.9 Auditoria e segurança (seções 47, 53)

Triggers de auditoria cobrem as 5 tabelas novas da Fase 2 (`custos_infraestrutura`, `pricing_ramp_rules`, `pricing_override_requests`, `propostas_comerciais`, além de `simulacoes` e `reajustes`, este último em `UPDATE`) — criação de simulação, alteração de parâmetros, geração de proposta, aprovação, alteração de pricing/margem/revenue share/mínimo e override manual ficam todos na tabela `auditoria` central (mesmo padrão desde a Fase 1: `INSERT` só via trigger, `UPDATE`/`DELETE` bloqueados para todo perfil).

RLS nas 5 tabelas novas segue a mesma matriz de perfis das fases anteriores: leitura ampla onde faz sentido comercial (ex.: `custos_infraestrutura` legível por todos os perfis autenticados), escrita restrita por perfil (`custos_infraestrutura`: `FINANCEIRO`/`ENGENHARIA`/`ADMINISTRADOR`; `pricing_faixas_escassez`/`pricing_ramp_rules`: `DIRETOR`/`ADMINISTRADOR`; `pricing_override_requests`: leitura pelo dono + `DIRETOR`/`ADMINISTRADOR`/`FINANCEIRO`/`AUDITOR`, escrita de criação por `COMERCIAL`/`DIRETOR`/`ADMINISTRADOR`, decisão só por `DIRETOR`/`ADMINISTRADOR`; `propostas_comerciais`: leitura ampla, escrita de criação por `COMERCIAL`/`DIRETOR`/`ADMINISTRADOR`, alteração só pelo dono enquanto `RASCUNHO` ou por `DIRETOR`/`ADMINISTRADOR`). `COMERCIAL` nunca tem `UPDATE` liberado nas tabelas de parâmetro global de pricing (`contrato_pricing_config`, `pricing_faixas_escassez`, `pricing_ramp_rules`) — pode simular, criar proposta e solicitar override, nunca alterar parâmetro global (seção 53), confirmado pelo teste F12-R8/TESTE19c.

**Única exceção `SECURITY DEFINER` desta fase**: `app.aplicar_reajuste_contrato()`, porque precisa escrever em `contrato_pricing_config`, cuja RLS de escrita geral é `DIRETOR`/`ADMINISTRADOR`-only, mas reajuste é operação de `FINANCEIRO`. A função **não contorna a checagem de perfil** — ela mesma faz `app.tem_perfil('FINANCEIRO','ADMINISTRADOR')` explicitamente no corpo antes de escrever, e é a única função de toda a Fase 2 com esse privilégio elevado, documentada em comentário no próprio SQL. Todas as outras ~30 funções novas são `SECURITY INVOKER` (ou funções puras sem escrita).

### 15.10 API do Pricing Engine e Dashboard (seções 50-51, 58-59)

**Restrição de exposição do PostgREST**: como nas fases anteriores, toda a lógica de negócio vive em funções `app.*`, mas o PostgREST do Supabase só expõe funções do schema `public` por padrão. A migration `20260827100900` cria 9 funções finas `public.pricing_*` (`SECURITY INVOKER`, nunca elevam privilégio) que encaminham para os endpoints da seção 50: `pricing_simulate`, `pricing_projection`, `pricing_roi`, `pricing_payback` (chamada junto de `pricing_roi` no endpoint `/roi`), `pricing_quote`, `pricing_override_create`, `pricing_override_approve`, `pricing_versions_list`, `pricing_scenarios_list`.

`api/` (código-fonte apenas, **sem deploy nesta entrega** — proibido pela seção 54, "jobs de produção" e "integrações externas" ficam para fases futuras) contém o esqueleto Express que expõe esses 8 endpoints REST da seção 50 (`POST /simulate`, `GET /projection`, `GET /roi`, `POST /quote`, `POST /override`, `POST /approve`, `GET /versions`, `GET /scenarios`), sempre repassando o JWT do usuário autenticado ao Supabase (nunca `service_role`) — a API nunca decide preço nem contorna RBAC/RLS, só encaminha para os wrappers `public.pricing_*` (seção 51: "as engines são os serviços SQL, não este arquivo").

**Serviços separados (seção 51)**: em vez de um controller único, a lógica está dividida em ~10 grupos de função por responsabilidade — `CostEngine` (15.1), `PricingEngine`/Dark Fiber (15.2), `RevenueShareEngine` (15.3), `RampEngine` (15.4), `AdjustmentEngine` (15.5), `ScenarioSimulator`/`ROICalculator`/`PaybackCalculator` (15.6), `PartnerEconomicsCalculator` (15.7), `CapacityCalculator` (`get_portas_necessarias`, funções de capacidade herdadas da Fase 1.2).

`dashboard/optimon-pricing-dashboard.html` é a tela "Pricing Engine" da seção 58: formulário com Cidade/POP/Portas/Capacidade/Parceiro/Modelo/Clientes/ARPU/Mínimo/Revenue Share/Prazo, botão **"GERAR SIMULAÇÃO"** (seção 59) que roda o mesmo motor (espelhado em JS e verificado numericamente idêntico ao SQL — ver seção "Testes executados" do relatório final) e apresenta preço mínimo/recomendado/premium em destaque, receita OptiMon/parceiro, ROI, payback, break-even e os 3 gráficos das seções 39-41, mais uma tabela de comparação Dark Fiber × Porta PON+Revenue Share (seção 38). Um campo dedicado "Preço proposto" testa a governança (seção 49) sem confundir o preço com rampa aplicada com o preço-base mínimo/recomendado.

### 15.11 O que a Fase 2 deliberadamente NÃO fez (seções 54, 65)

Por instrução explícita do prompt: nenhuma integração HubSoft, nenhuma integração IBGE (o reajuste é aplicado manualmente, com índice informado por quem tem perfil FINANCEIRO/ADMINISTRADOR), nenhuma integração financeira externa, nenhuma automação de recebimentos, nenhum job de produção, nenhuma API hospedada (o código de `api/` existe mas não roda em lugar nenhum nesta entrega). A arquitetura já separa esses pontos de extensão (tabela `integracoes`, desde a Fase 1) para que essas integrações entrem depois sem reconstrução.

## 16. Fase 2.1 — Correções de consistência comercial do Pricing Engine

A Fase 2.1 é uma correção incremental sobre a Fase 2: **4 migrations novas** (prefixo `20260828`, todas `CREATE OR REPLACE`/`CREATE TRIGGER`/`INSERT ... ON CONFLICT DO NOTHING`), nenhuma migration das Fases 1/1.1/1.2/2 foi alterada, nenhum dado histórico foi reconstruído. Motivada por uma revisão funcional que encontrou 3 inconsistências reais entre o que o Pricing Engine calculava e a decisão comercial vigente ("1 fibra óptica individual → 1 porta PON, capacidade padrão até 128 clientes").

### 16.1 Fibra individual como unidade comercial padrão (seções 1-2)

Até a Fase 2, `app.get_pares_contratados_dark_fiber()` contava `distinct par_numero` das fibras de um contrato — ou seja, cobrava por **par físico**, não por fibra individualmente contratada. Isso divergia da decisão comercial vigente e podia sub ou super-contar dependendo de como as fibras de um contrato se relacionavam fisicamente em pares.

`app.get_fibras_contratadas_dark_fiber(contrato_id)` (nova) conta `distinct fibra_id` — a fibra individual é a unidade. `app.calcular_preco_minimo_dark_fiber()` foi alterada (`CREATE OR REPLACE`, mesma assinatura) para usar essa nova função e um novo piso `DARK_FIBER_PRECO_MINIMO_FIBRA_MES` (R$1.500,00/fibra/mês — valor herdado do piso por par já aprovado na Fase 2, sinalizado no relatório como pendente de revisão específica por fibra). `app.get_pares_contratados_dark_fiber()` foi **preservada, não removida** (marcada `DEPRECATED` via `COMMENT ON FUNCTION`) — nenhum código legado que ainda a chame quebra, mas o motor de preço padrão não a usa mais. Os métodos de precificação (`POR_FIBRA`/`POR_KM`/`POR_PORTA`/`POR_POP`/`HIBRIDO`, seção 15.2) não foram alterados — `POR_FIBRA` já significava fibra individual desde a Fase 1.1, só o cálculo do mínimo Dark Fiber que ainda contava em pares.

### 16.2 Cenário 2 (Porta PON + Revenue Share) ganhou um motor de preço real (seções 5-8)

Achado mais grave da revisão: `contrato_pricing_config.preco_minimo_porta/preco_recomendado_porta/preco_premium_porta` existiam desde o início da Fase 2 (com `CHECK (preco_minimo_porta <= preco_recomendado_porta)`, sinal de que deveriam ser preenchidas por um motor de cálculo), mas **nenhuma função jamais escrevia nelas** — `public.pricing_quote()` para contratos não-Dark-Fiber apenas lia essas colunas, sempre `NULL`. Confirmado empiricamente: o contrato 0006 (seed Fase 2, Cenário 2) tinha as 3 colunas `NULL` e `pricing_quote()` devolvia preço mínimo/recomendado/premium `null`.

Três funções novas, espelhando estrutura e forma de fórmula das equivalentes de Dark Fiber (16.1/15.2):

- **`app.calcular_preco_minimo_porta_pon(contrato_id)`** = `MAX(custo_base_precificação, piso_global_por_porta × portas_contratadas) × (1 + margem + risco)` — usa `app.get_portas_contratadas_count` (Fase 1.2) e o mesmo `app.get_custo_base_precificacao` (Fase 2, agnóstico de cenário) do Dark Fiber.
- **`app.calcular_preco_recomendado_porta_pon(contrato_id)`** = mínimo × `PORTA_PON_MULTIPLICADOR_RECOMENDADO` (1,20 — herdado do valor já aprovado para Dark Fiber, seção 65) × fator de escassez de **capacidade de porta PON na cidade** (`app.get_disponibilidade_porta_pon_cidade`, nova função, análoga a `get_disponibilidade_fibra_cidade` mas lendo `infra_portas_pon.capacidade_disponivel`).
- **`app.calcular_preco_premium_porta_pon(contrato_id)`** = recomendado × `PORTA_PON_MULTIPLICADOR_PREMIUM` (1,50, herdado) × bônus de exclusividade/multi-POP/capacidade reservada — todos seedados como **1,00 (neutro)**, mesma disciplina da seção 65 já usada no Dark Fiber: a lógica está pronta e é parametrizável, mas não há sobretaxa automática até o negócio configurar um valor.

`public.pricing_quote()` foi alterada (`CREATE OR REPLACE`, mesma assinatura) para chamar essas 3 funções em vez de ler as colunas sempre-nulas. As colunas `preco_*_porta` continuam existindo na tabela (nunca foram a fonte de verdade — não alteramos dado histórico), só deixaram de ser lidas pelo motor.

### 16.3 Rampa agora respeita `rampa_aplica_a` por componente (seção 4)

`contrato_pricing_config.rampa_aplica_a` (`FIXO_MINIMO`/`REVENUE_SHARE`/`AMBOS`, `NOT NULL DEFAULT 'FIXO_MINIMO'` desde a Fase 1.1) nunca era lido por `app.simular_projecao()` (a função do `ScenarioSimulator`, construída na Fase 2): a rampa sempre era aplicada aos dois componentes (mínimo e revenue share) via a regra global `AMBOS`, ignorando a configuração por contrato. Como todo contrato que nunca configurou esse campo explicitamente herda `FIXO_MINIMO` por padrão — incluindo o contrato seed 0006 — isso significava que **todo contrato do sistema tinha a rampa aplicada incorretamente ao revenue share também**, quando a configuração implícita dizia para ramp-ar só o mínimo.

`app.simular_projecao()` foi alterada (`CREATE OR REPLACE`, mesma assinatura) para resolver `rampa_aplica_a` (do contrato, quando `contrato_id` é informado; senão do parâmetro `p_params->>'rampa_aplica_a'`, default `AMBOS` para simulações "soltas" sem contrato) e calcular `fator_rampa_minimo` e `fator_rampa_revenue_share` **independentemente**: cada um só recebe o fator de rampa do mês se o componente correspondente estiver autorizado por `rampa_aplica_a` (ou se for `AMBOS`); caso contrário, fator = 1,00 (sem rampa). Os dois fatores agora aparecem em cada mês do jsonb de saída, junto com `rampa_aplica_a` no nível superior — o dashboard (16.6) exibe os dois.

### 16.4 Viabilidade do parceiro em 4 níveis (seção 11)

`app.classificar_negocio()` (Fase 2, seção 57) tinha 3 saídas: `INVIAVEL` / `VIAVEL` / `EXCELENTE` (mais `PARAMETRIZÁVEL` quando faltam limiares). A Fase 2.1 insere um nível intermediário **MARGEM BAIXA** entre `INVIAVEL` e `VIAVEL`: margem do parceiro já cumpre o mínimo de viabilidade (`margem_minima_parceiro_percent` do contrato ou `VIABILIDADE_MARGEM_PARCEIRO_MINIMA_PADRAO` global), mas ainda está abaixo de um limiar "confortável" novo, `VIABILIDADE_MARGEM_PARCEIRO_CONFORTAVEL_PADRAO`. Esse novo parâmetro nasce **sem seed** (mesma disciplina da seção 65 já usada para `EXCELENCIA_ROI_MINIMO_PADRAO` na Fase 2): sem ele configurado, a função nunca produz `MARGEM BAIXA` e colapsa direto em `VIAVEL`/`EXCELENTE`, exatamente o comportamento da Fase 2 — nenhum contrato existente muda de classificação até o negócio configurar o novo limiar.

### 16.5 Multi-POP: capacidade por POP de um contrato específico (seção 12)

A capacidade consolidada por contrato (`vw_capacidade_contrato`) e por POP city-wide (`vw_capacidade_pop`) já existiam desde a Fase 1.1. Faltava mostrar a capacidade **por POP de um contrato específico**, lado a lado com o consolidado — é isso que `app.get_capacidade_multi_pop_contrato(contrato_id)` (nova) expõe, com wrapper público `public.pricing_capacity_by_pop` (mesmo padrão `SECURITY INVOKER` dos outros 9 wrappers `pricing_*`) e nova rota `GET /api/pricing/capacity-by-pop?contrato_id=...`. Testado com um contrato de 3 POPs (2+3+1 portas = 6 portas / 768 capacidade consolidada).

### 16.6 Auditoria: 2 lacunas fechadas (seção 14)

Consulta sistemática a `information_schema.triggers` (em vez de assumir cobertura) encontrou exatamente 2 tabelas de infraestrutura/pricing sem trigger de auditoria: `infra_fibras` (a fibra física em si — só o vínculo `contrato_fibras` era auditado) e `pricing_faixas_escassez` (os fatores de escassez da seção 14 da Fase 2, apesar de a RLS já restringir escrita a `DIRETOR`/`ADMINISTRADOR`). Ambas ganharam `trg_aud_*` chamando o mesmo `fn_auditoria()` central usado por todas as outras tabelas desde a Fase 1.

### 16.7 Dashboard (seção 3)

`dashboard/optimon-pricing-dashboard.html` foi atualizado para espelhar 16.1-16.5 em JS: campo "fibras contratadas" (não mais "pares"), rótulos "Fibras contratadas"/"fibra(s) óptica(s)" (nunca mais "par(es) de fibra"), rótulo "X Porta(s) PON × Y clientes" para o Cenário 2, chip de seleção `rampa_aplica_a`, motor `portaPonPrecos()` espelhando 16.2, `classificarNegocio()` de 4 níveis espelhando 16.4, e duas tabelas novas: capacidade Multi-POP (16.5) e o teste econômico completo da seção 9 (10/25/50/75/84/100/128 clientes). Todas as fórmulas JS foram verificadas numericamente idênticas às funções SQL correspondentes (mesma disciplina da Fase 2).

### 16.8 O que a Fase 2.1 deliberadamente NÃO fez

Não reconstruiu nenhuma tabela, não alterou nenhuma migration das Fases 1/1.1/1.2/2, não migrou dado histórico de "par" para "fibra" (a mudança é só de qual unidade o motor de preço conta daqui para frente), não inventou nenhum valor numérico sem análogo aprovado (piso por fibra e multiplicadores do Cenário 2 são explicitamente marcados como herdados/pendentes de revisão de negócio no relatório final), não iniciou a Fase 3.

Por instrução explícita da seção 65, os seguintes valores **não foram inventados** e continuam `NULL`/parametrizáveis até serem configurados por um usuário com o perfil adequado: `margem_minima_percent`, `fator_risco_percent`, `payback_minimo_meses`, `margem_minima_parceiro_percent` (por contrato), os limiares de "excelência" de `app.classificar_negocio`, e os bônus de exclusividade/multi-POP do preço premium Dark Fiber (seedados como 1,00 = neutro, não como um valor de mercado assumido). Onde o prompt forneceu um exemplo numérico literal (revenue share 12%, faixas de escassez, rampa 50/75/100%, multiplicadores Dark Fiber 1,20/1,50), esse valor foi seedado como **default configurável**, nunca hard-coded em código — qualquer um desses defaults pode ser sobrescrito por contrato sem migration nova.

## 17. Fase 2.2 — Infrastructure Floor + Régua Comercial

A Fase 2.2 acrescenta uma camada de **política comercial** nova sobre o Pricing Engine existente: o "Infrastructure Floor" / "Piso de Infraestrutura", que monetiza a infraestrutura óptica física (postes + metros de rede) como um piso de negociação, com uma régua comercial de 3 níveis (Abertura/Recomendado/Piso) e governança de aprovação. **4 migrations novas** (prefixo `20260829`), 100% aditivas (`ALTER TABLE ADD COLUMN`, `CREATE OR REPLACE FUNCTION`, `CREATE TRIGGER` guardado por checagem de existência, `CREATE TYPE` guardado por `exception when duplicate_object`, `INSERT ... ON CONFLICT DO NOTHING`) — nenhuma migration das Fases 1/1.1/1.2/2/2.1 foi alterada, nenhum dado histórico foi reconstruído.

### 17.1 Conceito central: política comercial, nunca custo real (seções 2/12/43)

O ponto mais importante da Fase 2.2, repetido em todo o código e nos comentários das migrations: Infrastructure Floor é uma **decisão de monetização mínima** da infraestrutura óptica (postes + metros de rede), não uma medição de custo. Os custos reais continuam exatamente onde estavam desde a Fase 2 — `custos_infraestrutura` (`HISTORICAL_CAPEX`/`EXISTING_OPEX`/`INCREMENTAL_OPEX`/`INCREMENTAL_CAPEX`/`ALLOCATED_COST`/`REVENUE_EXISTING`) — e nenhuma linha dessa tabela foi tocada. Nenhuma função nova lê ou escreve em `custos_infraestrutura`; o Infrastructure Floor é calculado inteiramente a partir de `cidades_infra.km_rede` e `infra_postes.quantidade`.

### 17.2 `app.calculate_infrastructure_floor()` — a fórmula (seção 21/22)

```
PISO         = (postes × R$/poste/mês)  + (metros_de_rede × R$/metro/mês — nível PISO)
RECOMENDADO  = (postes × R$/poste/mês)  + (metros_de_rede × R$/metro/mês — nível RECOMENDADO)
ABERTURA     = (postes × R$/poste/mês)  + (metros_de_rede × R$/metro/mês — nível ABERTURA)
```

Sem `p_pop_id` (consolidado da cidade — caso normal), os totais vêm de `cidades_infra.km_rede` (campo existente desde a Fase 1, nunca antes referenciado por nenhuma função — descoberto na investigação de schema desta fase) e `SUM(infra_postes.quantidade)` por cidade; **nunca** da soma de `infra_segmentos.extensao_km`, que está poluída por segmentos ad-hoc criados pelos próprios scripts de teste das fases anteriores e daria um total errado. Com `p_pop_id` informado, usa os campos analíticos opcionais `infra_pops.km_rede`/`postes_count` (17.5) — uma quebra por POP, nunca a fonte da verdade da cidade.

Os 4 parâmetros (`PISO_INFRAESTRUTURA_PRECO_POSTE`=R$10,00/poste/mês, `PISO_INFRAESTRUTURA_PRECO_METRO_PISO`=R$0,10, `_RECOMENDADO`=R$0,15, `_ABERTURA`=R$0,20 — todos por metro/mês) são **sempre parametrizáveis**, nunca hard-coded, e suportam override por cidade (17.3). Validado byte-a-byte contra o exemplo oficial do prompt — Jussara, 165 postes, 5.000 metros de rede:

| | postes | componente postes | metros | componente metros | **total** |
|---|---|---|---|---|---|
| PISO | 165 | R$1.650,00 (×R$10,00) | 5.000 | R$500,00 (×R$0,10) | **R$2.150,00** |
| RECOMENDADO | 165 | R$1.650,00 | 5.000 | R$750,00 (×R$0,15) | **R$2.400,00** |
| ABERTURA | 165 | R$1.650,00 | 5.000 | R$1.000,00 (×R$0,20) | **R$2.650,00** |

### 17.3 Parametrização com override por cidade, sem quebrar nenhum parâmetro global existente (seção 13/14)

`pricing_parametros` ganhou uma coluna `cidade_id` (nullable, `references cidades_infra`). A antiga constraint `unique(chave)` foi trocada por **2 índices únicos parciais**: `unique(chave) where cidade_id is null` (preserva 100% das ~30 chaves globais já existentes, todas com `cidade_id` `NULL`) e `unique(chave, cidade_id) where cidade_id is not null` (permite, no máximo, um override por cidade por chave). `app.get_infra_floor_param(chave, cidade_id, pricing_version)` resolve com prioridade: valor específico da cidade > valor global. Testado (TESTE-2): um override de Jussara para R$12,00/poste muda o piso para R$2.480,00; removido o override, volta a R$2.150,00 — as chaves globais nunca foram tocadas.

### 17.4 "Pricing version" sem tabela nova (seção 15)

Em vez de criar uma tabela de versionamento paralela, a Fase 2.2 reaproveita o mecanismo temporal `vigente_desde`/`vigente_ate` que **todo** parâmetro de pricing já usa desde a Fase 1. `pricing_version` é derivado como `to_char(vigente_desde, 'YYYY.MM')` (ex.: `"2026.08"`). Como os índices únicos de `pricing_parametros` permitem no máximo uma linha vigente por `(chave, cidade_id)` — igual a todo parâmetro desde a Fase 1 — o valor de cada parâmetro é sempre o atual; não existe um arquivo histórico de valores superados. `p_pricing_version` explícito não é decorativo: quando informado e **não bate** com a vigência atual de nenhum parâmetro (nem específico da cidade, nem global), a função falha explicitamente (`RAISE EXCEPTION`) em vez de aplicar o parâmetro vigente por engano — a proteção real da seção 15 (nunca recalcular uma proposta antiga silenciosamente com um parâmetro que já mudou), dentro do que o esquema de parâmetro único-por-chave já suportava desde a Fase 1 (TESTE-3).

### 17.5 Multi-POP nunca duplica metros (seção 24)

`infra_pops` ganhou 2 colunas analíticas opcionais, `km_rede numeric` e `postes_count integer` (default 0), para permitir uma quebra "por POP" do Infrastructure Floor. Por design, o consolidado da cidade **nunca** é a soma dessas colunas entre os POPs — é sempre lido diretamente de `cidades_infra.km_rede`/`SUM(infra_postes.quantidade)`, mecanicamente impossível de duplicar metros mesmo que os dados por POP estejam incompletos ou desatualizados. `app.get_capacidade_multi_pop_piso(cidade_id)` expõe os dois lados lado a lado. Testado (TESTE-13): mesmo preenchendo POP-01 com 1,2km/40 postes manualmente, o consolidado da cidade continuou exatamente 5.000m/165 postes.

### 17.6 Régua comercial e governança (seções 9-11/20/37-39)

- **`app.classificar_posicao_regua(proposto, abertura, recomendado, piso)`** — 6 rótulos de exibição: `PREÇO DE ABERTURA` (≥ abertura), `DENTRO DA RÉGUA` (entre recomendado e abertura), `PREÇO RECOMENDADO` (= recomendado), `DESCONTO SOBRE RECOMENDADO` (entre piso e recomendado), `PREÇO DE RESERVA` (= piso), `BLOCKED` (< piso).
- **`app.check_infrastructure_floor_governance(proposto, recomendado, piso)`** — veredito de aprovação em 3 níveis: `ALLOW` (≥ recomendado), `ALLOW_WITH_DISCOUNT` (entre piso e recomendado, inclusive), `BLOCK` (< piso). É uma função **nova e separada** de `app.check_pricing_governance` (Fase 2, escada de 2 níveis mínimo/recomendado, usada por `pricing_quote` para Dark Fiber/Cenário 2) — as duas coexistem sem se sobrepor; nenhuma foi alterada para dar lugar à outra.
- **`app.calcular_desconto_comercial(abertura, proposto, recomendado)`** — desconto absoluto e percentual sobre abertura e sobre recomendado, para a UI mostrar "quanto desconto está sendo pedido" nos dois referenciais.

Testado (TESTE-4 a TESTE-9) com os 5 preços de exemplo do prompt sobre a régua de Jussara (Abertura R$2.650 / Recomendado R$2.400 / Piso R$2.150): R$2.650→`ALLOW`, R$2.400→`ALLOW`, R$2.250→`ALLOW_WITH_DISCOUNT`, R$2.150→`ALLOW_WITH_DISCOUNT`, R$2.149→`BLOCK`.

### 17.7 Composição Floor × Mínimo Contratual — nunca soma "por acidente" (seção 32/33)

O ponto de maior risco de bug da fase: o Infrastructure Floor coexiste com o Mínimo Contratual por Porta PON (Fase 1.2) e o Revenue Share (Fase 2) — sem regra explícita, seria fácil somar os três "sem querer". `contrato_pricing_config.infra_floor_composition_mode` (enum novo, default `FLOOR_AS_MINIMUM`) torna a composição **explícita**, por contrato:

- `FLOOR_ONLY` — só o Floor conta; Mínimo Contratual vira informativo; nem o Revenue Share é somado por cima (caminho puro, sem passar pelo motor SOMA/MAX existente).
- `MINIMUM_ONLY` — só o Mínimo Contratual conta; comportamento **100% idêntico ao pré-Fase-2.2** (garantia de regressão por construção).
- `FLOOR_AS_MINIMUM` (default recomendado do prompt) — o Floor assume o papel do Mínimo no motor SOMA/MAX com Revenue Share já existente desde a Fase 2 (`app.calcular_cobranca_hibrida`, inalterado).
- `SUM` — Floor + Mínimo somados como base, depois combinados com o Revenue Share pelo motor existente.
- `MAX` — o maior entre Floor e Mínimo como base, depois combinado com o Revenue Share.

Testado (TESTE-11/TESTE-20) contra o contrato 0006 (mínimo R$1.000, share 12%): os 5 modos produzem 5 totais diferentes e nunca coincidem por acaso (exceto `FLOOR_AS_MINIMUM`≡`MAX` quando Floor > Mínimo, matematicamente esperado).

`contrato_pricing_config.minimum_infrastructure_floor_enforced` (boolean, default `true`) é uma **rede de proteção final**, aplicada depois da composição escolhida: se o total calculado (qualquer que seja o modo) ficar abaixo do Floor, ele é elevado até o Floor. Testado (TESTE-12): com `MINIMUM_ONLY` e faturamento baixo, o total calculado (R$1.060,00) fica abaixo do piso (R$2.150,00); com `enforced=true` sobe para R$2.150,00; com `enforced=false` permanece em R$1.060,00 — opt-out sempre explícito, nunca implícito.

### 17.8 Indicadores analíticos — nunca substituem a fórmula principal (seções 25-27)

`app.get_fibras_indicadores_cidade(cidade_id, pop_id?)` conta fibras totais/ociosas/ocupadas (`status_comercial = 'LIVRE'` = ociosa, mesmo enum da Fase 1) e Portas PON totais/disponíveis (`situacao_comercial = 'DISPONIVEL'` — enum próprio de `infra_portas_pon`, **diferente** do enum de fibra; um erro de copiar-colar `'LIVRE'` para este campo foi pego e corrigido antes da migration ser aplicada). `app.get_valor_infra_floor_por_fibra(floor, fibras_ociosas)` e `app.get_valor_infra_floor_por_porta_pon(floor, portas_contratadas)` reexpressam o mesmo Floor "por unidade" — indicadores de apoio à análise de escala, nunca uma segunda fórmula de preço. Ambos retornam `NULL` (nunca dividem por zero) quando o denominador é 0.

O exemplo oficial "10 fibras ociosas" do prompt é sobre o cabo/POP que atende o contrato 0006 (POP-01, `CABO-JUSSARA-01`: 10 `LIVRE` + 2 `BLOQUEADA`) — a cidade inteira tem mais fibra ociosa própria em `CABO-JUSSARA-02` (POP-02), então o teste (TESTE-14) escopa por POP, não pela cidade inteira, e roda **antes** de qualquer cabo de teste das seções de regressão ser criado no mesmo script — do contrário o número conta fibra de teste junto com a real e deixa de bater com o exemplo do prompt.

### 17.9 Break-even e escala de Portas PON (seção 34/35)

`app.calcular_breakeven_infra_floor(floor, share_pct)` = `floor / share_pct` (faturamento do parceiro necessário para o Revenue Share sozinho cobrir o Floor) e `app.calcular_breakeven_infra_floor_clientes(floor, share_pct, arpu)` = `ceil(breakeven / arpu)`. Para Jussara (Floor R$2.150, share 12%): R$17.916,67/mês = 180 clientes com ARPU R$100 (TESTE-18). `app.calcular_escala_pon_para_meta(clientes_meta, capacidade_por_porta)` calcula quantas Portas PON uma meta de clientes exige e devolve um texto de insight lembrando para recalcular Floor/Share/Mínimo a cada escala — testado com 128 clientes (1 porta, dentro da capacidade máxima) e 180 clientes (2 portas, TESTE-19).

### 17.10 Auditoria e override do Diretor (seções 40-43)

`cidades_infra` nunca teve trigger de auditoria desde a Fase 1 — lacuna real, fechada aqui com o mesmo `trg_aud_*`/`fn_auditoria()` central de todas as outras tabelas, porque `km_rede` agora é insumo direto de um preço comercial (TESTE-21). `pricing_override_requests` ganhou 2 colunas nullable, `preco_piso`/`preco_abertura`, para registrar a régua completa no momento de uma negociação abaixo do piso — reaproveitando o mesmo fluxo de aprovação já testado desde a Fase 2 (nasce `PENDENTE`, só `DIRETOR`/`ADMINISTRADOR` decide, auditado), em vez de criar uma tabela de override paralela.

`public.pricing_override_create()` recebeu 2 parâmetros novos opcionais no final (`p_preco_piso`, `p_preco_abertura`) via `CREATE OR REPLACE`. **Isso expôs um bug real durante o desenvolvimento**: o Postgres só substitui uma função com a **mesma assinatura** — acrescentar parâmetros (mesmo com `DEFAULT`) cria uma segunda função sobrecarregada, e qualquer chamada com exatamente 5 argumentos posicionais (o padrão usado por todo código desde a Fase 2, ex.: o teste REG19) passou a ser **ambígua** entre as duas (`ERROR: function ... is not unique`) — quebrando exatamente a compatibilidade retroativa que a seção 40 pedia para preservar. Corrigido com um `DROP FUNCTION IF EXISTS` (assinatura antiga de 5 parâmetros) antes do `CREATE OR REPLACE` de 7 parâmetros, dentro da mesma migration — resultado: uma única função, aceitando 5, 6 ou 7 argumentos via `DEFAULT`, sem ambiguidade (TESTE-22a/b).

### 17.11 API e dashboard (seção 36/44)

5 rotas novas em `api/routes/pricing.js` (mesmo padrão fino de sempre — validam entrada, chamam 1 wrapper `public.pricing_*`, devolvem o resultado): `GET /infrastructure-floor`, `GET /infra-floor-negotiation` (a "função comercial" completa: régua + posição + governança + desconto, tudo em uma chamada), `GET /economics-with-floor`, `GET /fibras-indicadores`, `GET /capacity-multipop-floor`; `POST /override` estendida para aceitar `preco_piso`/`preco_abertura` opcionais. `dashboard/optimon-pricing-dashboard.html` ganhou um novo grupo de campos "Infrastructure Floor" no rail (postes, km de rede, os 4 preços, chips de composição, toggle de enforced, fibras ociosas), um card com o Floor e seus indicadores por fibra/PON, o gráfico da régua (3 degraus + bloqueado, com o nível atual destacado conforme o preço proposto), a linha de negociação ao vivo (posição + governança + desconto), e 2 tabelas novas (comparação econômica com o piso e o teste de ARPU completo). Todas as fórmulas JS foram verificadas como espelho byte-a-byte das funções SQL desta seção via Playwright headless, incluindo os 5 preços de exemplo de governança e os 5 modos de composição.

### 17.12 O que a Fase 2.2 deliberadamente NÃO fez

Não reconstruiu nenhuma tabela, não alterou nenhuma migration das Fases 1/1.1/1.2/2/2.1, não tocou em `custos_infraestrutura` (custo real permanece completamente separado da política comercial do Floor), não assumiu um modo de composição implícito (todos os 5 são explícitos e nenhum é "o certo" por padrão além do `FLOOR_AS_MINIMUM` recomendado pelo próprio prompt), não iniciou a Fase 3. O único ajuste feito FORA do escopo das 4 migrations originalmente planejadas foi o `DROP FUNCTION` de 17.10 — uma correção de um bug real de sobrecarga introduzido pela própria Fase 2.2, dentro da mesma migration que o causou, não uma alteração de migration de fase anterior.

## 18. Fase 2.2.1 — Ajuste Final de Governança + Precificação por Porta PON

A Fase 2.2.1 faz dois ajustes comerciais sobre o Infrastructure Floor da Fase 2.2: (1) a Porta PON passa a ser um **componente direto da fórmula do Floor**, não só um indicador analítico derivado dele; (2) a governança de aprovação passa a ser **ciente do papel (role)** de quem está decidindo, com um piso absoluto de desconto de override que nem Diretor/Administrador podem ultrapassar. **6 migrations novas** (prefixo `20260830`), aplicadas sobre o banco com dados reais de Fase 1 até Fase 2.2 (sem seed própria, sem reconstrução) — a 6ª migration é uma correção encontrada e corrigida durante a própria validação desta fase (seção 18.9).

### 18.1 Nova fórmula do Floor — Porta PON como componente (seção 3/6-8)

```
INFRASTRUCTURE FLOOR = (POSTES × PREÇO_POSTE) + (METROS_REDE × PREÇO_METRO) + (PONS × PREÇO_PON)
```

O preço do poste **não varia** por nível da régua (só existiu 1 preço de poste desde a Fase 2.2); metro e PON têm 3 preços cada (piso/recomendado/abertura). `app.calculate_infrastructure_floor()` ganhou um 4º parâmetro `p_pons_count integer default null` — **sempre informado por quem chama, nunca inferido** (seção 16/19): sem informação (`NULL`), vira 0, preservando 100% de compatibilidade com toda chamada anterior à Fase 2.2.1 que só queria postes+metros. `app.calculate_infrastructure_floor_for_contract(contrato_id, pop_id?, pricing_version?)` é a função nova que resolve o número real de PONs de um contrato via `app.get_portas_contratadas_count(contrato_id, somente_ativas=false)` (função da Fase 1.2, **não alterada**) — deliberadamente `false`: billing é por **capacidade reservada** (`situacao_comercial` em `RESERVADA` ou `ATIVA`), não por uso real (TESTE-32 comprova: uma porta `RESERVADA` conta no Floor exatamente como uma `ATIVA`; só cai para 0 se filtrarmos por `somente_ativas=true`, que não é o que o billing usa).

Exemplo oficial (Jussara, 165 postes, 5.000m, 1 PON, Pricing Version "2026.08.1"): **PISO R$2.020,00 · RECOMENDADO R$2.320,00 · ABERTURA R$2.620,00** (componente PON: R$200/250/300 por nível). Escala de 1 a 6 PONs: R$2.020,00 / 2.220,00 / 2.420,00 / 2.620,00 / 2.820,00 / 3.020,00 — cada PON adicional soma exatos R$200,00 ao piso (TESTE-30/31).

### 18.2 Novos parâmetros oficiais (seção 4) — sempre versionados, nunca hard-coded

| Parâmetro | Piso | Recomendado | Abertura |
|---|---|---|---|
| `PISO_INFRAESTRUTURA_PRECO_POSTE` | R$8,00/mês (era R$10,00 na Fase 2.2) | — (preço único) | — |
| `PISO_INFRAESTRUTURA_PRECO_METRO_*` | R$0,10 | R$0,15 | R$0,20 (inalterados) |
| `PISO_INFRAESTRUTURA_PRECO_PON_*` | R$200,00 | R$250,00 | R$300,00 (novos) |
| `MAX_OVERRIDE_DISCOUNT_PERCENT` | 50% (novo — seção 18.4) | | |

Os 8 parâmetros nascem juntos sob uma única Pricing Version, `"2026.08.1"`, via `app.criar_pricing_version()` (seção 18.3) — nunca como 8 `UPDATE`s soltos.

### 18.3 Versionamento real de parâmetros (seção 29) — a correção mais estrutural desta fase

Investigando a estrutura existente **antes de escrever qualquer migration** (exigência explícita do prompt), foi identificada uma lacuna real herdada da Fase 2.2: `pricing_parametros.pricing_version` **não existia como coluna** — era só um rótulo calculado on-the-fly (`to_char(vigente_desde, 'YYYY.MM')`), e o único índice único da tabela permitia **no máximo 1 linha, para sempre**, por `(chave, cidade_id)`. "Versionamento" era puramente cosmético: mudar um parâmetro sempre fazia `UPDATE` na mesma linha, apagando o valor anterior de fato. A seção 29 desta fase exige explicitamente que uma proposta antiga nunca seja recalculada com parâmetros novos — impossível de cumprir de verdade sob esse esquema.

Corrigido com uma coluna `pricing_version text not null` real (todas as ~34 linhas existentes migradas com o rótulo equivalente, sem mudar nenhum valor) e a troca dos 2 índices antigos por 4 novos índices parciais: um garantindo **uma única linha vigente** (`vigente_ate is null`) por chave/escopo, outro garantindo um **rótulo de versão único** por chave/escopo — juntos, permitem histórico real (várias linhas fechadas coexistindo) sem nunca ter 2 vigências abertas ao mesmo tempo. `app.criar_pricing_version(pricing_version, valores jsonb, cidade_id?, vigente_desde?, descricao?)` é o bump atômico canônico: fecha a linha vigente anterior de cada chave tocada e insere a nova sob o rótulo novo — chaves novas (como os 3 parâmetros de PON) simplesmente nascem na nova versão, sem linha anterior para fechar. `app.get_infra_floor_param()` passou a resolver por **rótulo exato** de versão quando informado, em vez de casar por mês.

**Prova real, não só teórica** (bateria de testes, passo C): fixando `pricing_version='2026.08'` explicitamente, `app.get_economia_com_piso()` para o contrato 0006 devolve **exatamente** os mesmos 4 totais da Fase 2.2 (R$2.150,00 / 2.200,00 / 3.350,00 / 4.350,00) mesmo depois de todas as migrations desta fase aplicadas e o parâmetro vigente já ter mudado — histórico genuinamente preservado, não um rótulo que só parecia preservado.

### 18.4 Governança por papel + piso absoluto de override (seção 12/13/14/35)

`app.check_infrastructure_floor_governance_role(preco_proposto, preco_abertura, preco_recomendado, preco_piso, max_override_discount_percent?)` resolve 5 vereditos, com o papel de quem está avaliando resolvido **sempre no servidor** via `app.perfil_atual()` (nunca informado pelo cliente — mesma filosofia de segurança de todo o RLS do sistema):

- `proposto ≥ recomendado` → **ALLOW** (qualquer papel).
- `piso ≤ proposto < recomendado` → **ALLOW_WITH_DISCOUNT**, **para qualquer papel** — essa faixa já é autoridade normal do Comercial; Diretor não recebe um veredito especial aqui, só abaixo do piso é que o papel passa a importar.
- `proposto < piso`: **BLOCK_FOR_COMMERCIAL** para COMERCIAL (não pode se autoaprovar); **ALLOW_WITH_DIRECTOR_OVERRIDE** para DIRETOR/ADMINISTRADOR (ou FINANCEIRO com `usuarios.pode_aprovar_override_pricing=true` — coluna nova, minimalista, default `false`) — **exceto** se `proposto` também estiver abaixo do piso absoluto (próximo item), quando vira **BLOCK** para todos.

`app.calcular_preco_minimo_autorizado(preco_abertura, max_override_discount_percent)` = `ABERTURA × (1 − MAX_OVERRIDE_DISCOUNT_PERCENT)` — para Jussara (abertura R$2.620, 50%): **R$1.310,00**. Esse piso é aplicado em **dois lugares**, não só um: como função consultável (advisory, para a UI mostrar o limite antes de tentar) e — mais importante — **dentro da trigger `fn_override_decisao`** (`BEFORE UPDATE` em `pricing_override_requests`, já existente desde a Fase 2), que agora `RAISE EXCEPTION` se `preco_solicitado < preco_minimo_autorizado`. Verificado empiricamente: DIRETOR tentando aprovar R$1.309,00 é bloqueado pela própria trigger (`BLOCK: ... nenhum perfil pode aprovar abaixo deste piso absoluto`); R$1.310,00 exato aprova com sucesso (TESTE-34). O check só roda quando `preco_abertura` está preenchido (fluxos de override anteriores à Fase 2.2, sem régua de Floor, continuam intocados).

**Discrepância documentada, nunca escondida** (seção 12 vs. seção 33 do prompt): pela fórmula explícita da seção 12, R$2.100,00 (acima do piso de Jussara, R$2.020,00) deveria ser `ALLOW_WITH_DISCOUNT` — mas o exemplo da seção 33 sugere `BLOCK_FOR_COMMERCIAL` para esse mesmo valor. Implementada a fórmula explícita (seção 12), não o número do exemplo (seção 33), com a decisão registrada em comentário na migration e verificada empiricamente (`R$2.100 → ALLOW_WITH_DISCOUNT` para ambos os papéis, TESTE-33).

### 18.5 Quem pode DECIDIR um override (seção 14/35) — RLS + trigger, dupla camada

`usuarios.pode_aprovar_override_pricing` (novo, `boolean not null default false`) é a única mudança de schema para o caminho do Financeiro. A decisão em si continua 100% no banco: a policy de `UPDATE` de `pricing_override_requests` (inalterada desde a Fase 2.2) já restringe quem consegue sequer **tocar** a linha — Comercial só enquanto `PENDENTE` e sendo o próprio solicitante (nunca aprovando, porque aprovar exige mudar o status, e a condição da policy exige que o status permaneça `PENDENTE`); a trigger `fn_override_decisao` acrescenta o caminho do Financeiro (`FINANCEIRO` + `pode_aprovar_override_pricing=true`) ao lado de `DIRETOR`/`ADMINISTRADOR`. Testado nos 4 papéis (TESTE-35): Comercial tentando se autoaprovar é bloqueado pela RLS (a linha simplesmente não casa para `UPDATE`); Financeiro sem a permissão explícita é bloqueado; Financeiro com a permissão aprova; Administrador sempre aprova.

### 18.6 `MAX` — mudança de comportamento intencional (seção 21)

O modo de composição `MAX`, que já existia desde a Fase 2.2 (`base = MAX(Floor, Mínimo)`, depois combinado com o Revenue Share via `modelo_cobranca`), foi **redefinido** para a fórmula literal desta fase: `TOTAL_PAYABLE = MAX(Infrastructure_Floor, Revenue_Share)` — sem Mínimo Contratual, sem depender de `modelo_cobranca`. É uma **mudança de comportamento deliberada e documentada**, não um efeito colateral: o teste de regressão da Fase 2.2 para `MAX` (que esperava R$3.350,00, calculado com Mínimo) foi conscientemente **não repetido** nessa forma — em vez disso, o passo C da bateria desta fase mostra os dois números lado a lado (pinned em `'2026.08'`: R$2.150,00, formula antiga por coincidência numérica igual ao Floor da época; vigente `'2026.08.1'`: R$2.020,00, formula nova) com a mudança de fórmula explicada em comentário SQL e no teste (TESTE-37). Os outros 4 modos (`FLOOR_ONLY`/`MINIMUM_ONLY`/`FLOOR_AS_MINIMUM`/`SUM`) mantêm exatamente a mesma fórmula da Fase 2.2 — só o valor de entrada do Floor mudou (TESTE-38 confirma `SUM` = Floor+Mínimo+RevenueShare com os números novos). `contrato_pricing_config.infra_floor_composition_mode` teve seu `DEFAULT` alterado de `FLOOR_AS_MINIMUM` para `MAX` (só para contratos **novos** — `ALTER COLUMN ... SET DEFAULT` nunca muda valores já persistidos; o contrato 0006/Jussara continua `FLOOR_AS_MINIMUM` explicitamente).

### 18.7 Multi-POP com PON (seção 23/24/39)

Nenhuma mudança de função foi necessária para a garantia de não-duplicação — ela já existia desde a Fase 2.2 (TESTE-13): `app.calculate_infrastructure_floor_by_pop()` lê `infra_pops.km_rede`/`infra_pops.postes_count` (colunas próprias, preenchidas manualmente por POP); `app.calculate_city_infrastructure_floor()` lê `cidades_infra.km_rede`/soma de `infra_postes.quantidade` — duas fontes de dado **independentes**, nunca somadas uma com a outra em código nenhum. Reverificado nesta fase (TESTE-39) com um cenário de 2 POPs com contagens de PON distintas: POP-01 (40 postes/1.200m/2 PONs) e POP-02 (25 postes/800m/1 PON) têm Floors próprios; o consolidado da cidade continua 165 postes/5.000m, nunca a soma dos POPs.

### 18.8 Auditoria detalhada do override (seção 15)

`pricing_override_requests` ganhou `cidade_id` (resolvido **no servidor**, a partir de `contratos.cidade_id` — nunca aceito do cliente, mesma filosofia de todo o resto desta fase), `pop_id` (opcional, validado para pertencer à mesma cidade do contrato) e `desconto_absoluto` (coluna gerada, `preco_recomendado − preco_solicitado`, complementando o `desconto_percentual` já existente desde a Fase 2.2). `public.pricing_override_create()` recebeu `p_pop_id` como parâmetro final opcional — **`DROP FUNCTION` antes do `CREATE OR REPLACE`** (mesma disciplina da Fase 2.2, seção 17.10), já que a assinatura muda. Simplificações deliberadas, documentadas aqui: `opportunity_id` do prompt mapeia para `contrato_id` (OptiMon não tem uma entidade "oportunidade" de CRM separada); "motivo da exceção" é o mesmo campo que `justificativa`, sem duplicar. "Nunca apagar um override" já era garantido estruturalmente desde a Fase 2.2 (nenhuma policy de `DELETE` na tabela) — reverificado empiricamente nesta fase com uma tentativa real de `DELETE` como `ADMINISTRADOR` (`DELETE 0`, TESTE-41b), sem necessidade de nova migration.

### 18.9 Bug encontrado e corrigido durante a própria validação: PON em versões antigas

Ao montar a bateria de regressão (passo C, fixando `pricing_version='2026.08'` para reproduzir os números antigos), `app.calculate_infrastructure_floor()` **lançava exceção** em vez de devolver um resultado: a função sempre resolve incondicionalmente os 3 preços de PON via `app.get_infra_floor_param()`, e esses parâmetros simplesmente não existiam sob o rótulo `'2026.08'` (nasceram só em `'2026.08.1'`). Isso tornaria **impossível** recalcular qualquer proposta antiga que precisasse ser reexibida ou auditada depois — o oposto do que a seção 29 pede. Corrigido com um 4º parâmetro opcional `p_default` em `app.get_infra_floor_param()` (devolve o default em vez de lançar exceção quando o parâmetro não existe sob a versão pedida) e os 3 preços de PON em `calculate_infrastructure_floor()` passando `p_default := 0` — uma versão anterior à existência de PON no Floor **não tinha** esse componente, e R$0,00 é o valor correto, não um placeholder. A correção não muda nenhum cálculo com a versão vigente atual (que sempre tem os 3 parâmetros definidos); só torna consultas históricas pré-Fase-2.2.1 novamente calculáveis. **A primeira tentativa de corrigir isso reintroduziu, momentaneamente, o mesmo bug de sobrecarga da seção 17.10/18.8**: `CREATE OR REPLACE` com um parâmetro novo (mesmo com `DEFAULT`) criou um segundo `get_infra_floor_param` de 4 argumentos coexistindo com o de 3, deixando toda chamada de 3 argumentos ambígua (`function ... is not unique`) — pego imediatamente ao validar a própria migration, corrigido com `DROP FUNCTION IF EXISTS` antes do `CREATE OR REPLACE`, dentro da mesma migration 6.

### 18.10 API e dashboard (seção 14/36/44)

`api/routes/pricing.js`: `handleSupabaseError` passou a distinguir **403** (mensagens `REQUIRES_APPROVAL` — sempre um problema de permissão/papel) de **409** (mensagens `BLOCK`/não encontrado — regra de negócio sobre o preço em si), cumprindo a seção 14 ("Comercial: 403/BLOCKED"); `POST /approve` consulta o papel de quem chamou (nova rota `GET /current-role` / `public.pricing_current_user_role()`) só para escolher o envelope HTTP certo quando a RLS já bloqueou silenciosamente (`UPDATE` afetando 0 linhas) — a decisão de permissão em si continua inteiramente no banco. `POST /override` aceita `pop_id` opcional; `GET /infrastructure-floor` e `GET /infra-floor-negotiation` aceitam `pons_count` opcional. Dashboard: rail novo com contagem de PONs e os 3 preços de PON, chip de "papel de quem está avaliando" (COMERCIAL/DIRETOR/ADMINISTRADOR/FINANCEIRO) com o mesmo veredito de 5 estados espelhado em JS, indicador do preço mínimo autorizável, e a régua renomeada para "régua de preço" (nunca "margem de negociação" — termo reservado para o conceito, distinto, de margem do parceiro). Espelho JS verificado byte-a-byte via Playwright headless contra o exemplo de Jussara, a escala de 1-6 PONs e os 6 pontos de governança por papel — incluindo a correção da seção 18.4 (Diretor não tem veredito especial entre piso e recomendado).

### 18.11 O que a Fase 2.2.1 deliberadamente NÃO fez

Não reescreveu nenhuma tabela ou função sem necessidade, não substituiu nenhuma migration de fase anterior, não alterou nenhuma regra já aprovada que não estivesse explicitamente mencionada neste prompt (Revenue Share continua 12% default, representando só performance, nunca fundido ao Floor — TESTE-36), não iniciou a Fase 3 (HubSoft, IBGE, integração financeira, geração de contratos ou qualquer outra integração externa). As únicas 2 mudanças de comportamento em relação à Fase 2.2 — a fórmula do modo `MAX` (seção 18.6) e a resolução da discrepância seção-12-vs-seção-33 (seção 18.4) — foram deliberadas, instruídas pelo próprio prompt, e documentadas em detalhe em vez de escondidas atrás de uma regressão silenciosamente ajustada.

## 19. Fase 2.2.1 Parte 2 — Ajuste Final do Pricing Engine + Régua de Preço + Primeira Versão Visual Funcional + Deployment

Onde as fases anteriores entregaram o motor de preço e a governança como funções SQL auditáveis via `psql`, esta fase entrega a **primeira versão visualmente funcional do OptiMon acessível pela internet**: um Pricing Engine centralizado exposto por uma API real, um frontend React completo consumindo essa API, e os 4 ambientes de deploy (GitHub, Supabase, Railway, Vercel) preparados — sem recriar banco, sem apagar migration, sem duplicar tabela, sem iniciar a Fase 3. **9 migrations novas** (prefixo `20260831`) sobre o banco com dados reais de Fase 1 até Fase 2.2.1 (sem seed própria, sem reconstrução).

### 19.1 Pricing Engine centralizado — uma única porta de entrada (seção 32)

Toda tela do frontend que precisa de um preço chama exatamente uma função: `app.simular_precificacao_completa(p_params jsonb)` (schema `app`, a lógica de verdade) exposta como `public.pricing_calculate_full(p_params jsonb)` (o wrapper `SECURITY INVOKER`, seguindo o padrão de `20260827100900_phase_2_10_api_public_wrappers.sql`), chamada pela API via `api/lib/calculatePricing.js` — um wrapper JS deliberadamente fino, que só monta o `jsonb` e repassa a resposta, nunca reimplementa nem uma parcela da fórmula em JavaScript. A composição do Floor×Mínimo×Revenue Share dentro dessa função reaproveita literalmente a mesma lógica de `app.get_economia_com_piso` (Fase 2.2), agora generalizada para funcionar sem exigir um contrato já existente — o requisito da seção 32 era permitir cotar um preço para um cliente novo, sem contrato ainda. Verificado byte-a-byte contra o exemplo oficial de Jussara (1 PON, 0 clientes adicionais): Piso R$2.020,00 / Recomendado R$2.320,00 / Abertura R$2.620,00 — os mesmos números da Fase 2.2.1, agora vindos de uma função contract-free.

O princípio de segurança desta fase, seguido em toda a superfície nova: **o backend nunca confia em um total vindo do cliente**. `POST /api/pricing/calculate` sempre recalcula do zero a partir dos parâmetros de entrada (cidade, clientes, ARPU, revenue share %); nada que o frontend envie como "total já calculado" é aceito ou usado — o frontend só exibe o que a API devolve.

### 19.2 Superfície de API que faltava para o frontend (seção 31)

Wrappers novos, todos `SECURITY INVOKER`, `GRANT EXECUTE` só para `authenticated`, seguindo exatamente o padrão de `20260827100900...`: `public.pricing_cities_list()` / `public.pricing_city_detail(uuid)` (dashboard principal e por cidade), `app.pons_necessarias_para_clientes(clientes, cidade_id, pricing_version)` / `public.pricing_pons_for_clients(...)` (escala de Portas PON — `ceil(clientes / 128)`, 128 sendo a capacidade de uma Porta PON desde a Fase 1.1), `app.simular_curva_crescimento(...)` / `public.pricing_growth_curve(...)` (gráfico de crescimento), `app.simular_tabela_horizontes(...)` / `public.pricing_horizon_table(...)` (tabela 12/36/48/60 meses, com 48 meses marcado por `minimo_contratual_flag` — o prazo mínimo contratual desde a Fase 1), `public.pricing_ramp_rules_list(uuid)` / `public.pricing_indices_list(text, int)` (rampa e índices de reajuste), `public.pricing_simulation_save(...)` / `public.pricing_simulation_get(uuid)` / `public.pricing_proposal_create(...)` / `public.pricing_proposals_list(...)` (Nova Simulação → Proposta), `public.pricing_audit_list(...)` (tela de Auditoria) e `public.pricing_log_login()` (`SECURITY DEFINER`, insere em `auditoria` só para `auth.uid()`, nunca para outro usuário).

`auditoria_acao_check` (CHECK constraint existente desde a Fase 1) só aceitava `INSERT`/`UPDATE`/`DELETE` — ampliada de forma aditiva para aceitar também `LOGIN`, sem remover nenhum valor aceito antes.

### 19.3 Bug real encontrado: 6 views nunca tinham `GRANT` para `authenticated`

Descoberto só porque, pela primeira vez desde a Fase 1, os testes desta fase rodam **como o papel `authenticated` de verdade** (via PostgREST + JWT), não como o superusuário do Postgres usado por todos os scripts `psql` anteriores — que ignora `GRANT`/RLS por definição. `vw_capacidade_cidade`, `vw_capacidade_contrato`, `vw_capacidade_parceiro`, `vw_capacidade_pop`, `vw_contrato_capacidade` e `vw_porta_pon_detalhe` (todas views de capacidade, existentes desde a Fase 1/1.1) nunca tinham recebido `GRANT SELECT ... TO authenticated` — um bug latente que não quebrava nenhum teste anterior porque nenhum teste anterior consultava essas views por fora da superusuária. Corrigido com uma migration aditiva de `GRANT`, sem alterar a definição de nenhuma view.

### 19.4 Pilha de desenvolvimento local equivalente ao Supabase (sem Supabase ainda)

Como nenhum projeto Supabase existe ainda para o OptiMon (ver seção "Deploy real" do `README.md`), esta fase precisou validar a superfície nova exatamente como ela vai rodar em produção — com RLS real, JWT real, papéis reais — sem um Supabase disponível. Montado em `supabase/dev-local-only/` (nunca copiado para um projeto Supabase real): PostgREST (binário estático) servindo `public`/`app` sobre o Postgres local; um proxy Node (`rest_v1_proxy.js`) removendo o prefixo `/rest/v1` que `@supabase/supabase-js` sempre adiciona (PostgREST puro não serve esse caminho); `mint_jwt.js`, gerando JWTs HS256 válidos para qualquer papel de teste sem precisar de um GoTrue rodando; e uma extensão do shim de `auth.uid()` (`shim_supabase_auth.sql`, existente desde a Fase 1) para ler `request.jwt.claims ->> 'sub'` (a convenção real do PostgREST/Supabase) com fallback para `app.current_user_id` (o GUC usado por todo teste `psql` desde a Fase 1) — 100% de compatibilidade retroativa, nenhum script de teste anterior precisou mudar. Gotcha documentado: o PostgREST cacheia o schema no boot — toda função nova exige `NOTIFY pgrst, 'reload schema';` para ficar visível, já embutido em `tests/run_tests_deploy.sh`.

### 19.5 Frontend React — primeira versão visual funcional (seção 33-40)

`web/` (Vite + React 19 + `react-router-dom` + `@supabase/supabase-js`, usado só para autenticação — nunca para acessar dados de negócio diretamente, sempre via a API): tela de Login; Dashboard principal (lista de cidades); Dashboard por cidade (a régua de preço de Jussara, POPs, capacidade); Nova Simulação (botões rápidos de cliente, os 2 gráficos exigidos — crescimento/receita e clientes/PONs, ambos SVG desenhado à mão seguindo a skill de dataviz: eixo único, linhas finas de 2px, legenda, crosshair no hover — e a tabela de horizontes 12/36/48/60 meses com 48 meses marcado como mínimo contratual); Propostas (lista + geração); Auditoria (log, incluindo eventos `LOGIN`). Modo demonstração sinalizado por `VITE_APP_ENVIRONMENT` (`"PRODUÇÃO"` vs. `"DEMONSTRAÇÃO"`), exibido na tela de login. Design responsivo (petróleo `#0f4c81` + teal `#14b8a6`, Manrope/Inter/IBM Plex Mono, modo claro/escuro por `prefers-color-scheme`) verificado visualmente via Playwright headless contra dados reais em todas as telas — inclusive a régua de Jussara batendo exatamente com o exemplo oficial na tela, não só na API.

O frontend **nunca reimplementa a fórmula de preço**: toda tela que mostra um valor calculado chama a API (seção 19.1); o único cálculo feito no cliente é de apresentação (formatação de moeda, ordenação de tabela).

### 19.6 Deploy: GitHub, Railway, Vercel, Supabase (seção 6-8)

`.gitignore` cobrindo todo segredo conhecido do projeto (nunca versionar `SUPABASE_SERVICE_ROLE_KEY`, `JWT_SECRET`, `DATABASE_URL` com senha, tokens de Railway/Vercel/GitHub/HubSoft); `.github/workflows/ci.yml` com 2 jobs paralelos (API: install/lint/test; Web: install/lint/build), sempre com variáveis fictícias, nunca um segredo real em CI; `api/Dockerfile` (multi-stage `node:22-alpine`, `npm ci --omit=dev`, `HEALTHCHECK`) + `railway.toml` na raiz; `web/vercel.json` (SPA — todas as rotas caem em `index.html` — e headers de segurança); `.env.example` consolidado documentando exatamente quais variáveis cada ambiente precisa, sem nenhum valor real. Nenhum projeto Supabase existe ainda para o OptiMon — quando existir, as 74 migrations em `supabase/migrations/` se aplicam em sequência, sem alterar nenhuma das anteriores. Ver o `README.md`, seção "Deploy real", para o estado exato do que falta (credenciais do usuário) e o que já está pronto.

### 19.7 Bateria de testes desta fase (seção 41-43)

`tests/run_tests_deploy.sh` — **18 de 18 verificações passando**, testando por HTTP contra a pilha real (PostgREST local + API Node/Express), não só via `psql`: PASSO-0 (regressão total + migrations novas aplicando sem erro), PASSO-1 (API local no ar), TESTE-D1 (Jussara 1 PON via API, valores exatos), TESTE-D2/D3 (129→2 PONs, 257→3 PONs), TESTE-D4/D5/D6 (as 3 fronteiras de governança do prompt — R$2.019,00/R$1.310,00/R$1.309,00 — via JWT real de COMERCIAL e DIRETOR, incluindo o piso absoluto bloqueando até o DIRETOR), TESTE-D7 (performance real: média de 5 chamadas HTTP a `POST /api/pricing/calculate` abaixo de 500ms), e E2E-1..E2E-8 (fluxo comercial completo — login, dashboard, dashboard da cidade, simular, recalcular, salvar simulação, gerar proposta, conferir auditoria). Detalhe teste a teste no `README.md` e no relatório final desta entrega.

### 19.8 O que esta fase deliberadamente NÃO fez

Não criou um projeto Supabase (a criação de contas está fora do que esta sessão pode executar — depende do usuário); não fez deploy real no Railway/Vercel (bloqueado até o usuário fornecer os tokens); não testou a build da imagem Docker localmente (este ambiente de desenvolvimento não tem um daemon Docker privilegiado disponível — a build será validada na primeira execução real do Railway, que constrói a partir do mesmo `Dockerfile` e `railway.toml` já prontos); não iniciou a Fase 3. Nenhuma dessas é uma pendência escondida — todas estão listadas aqui, no `README.md` e no relatório final, com o motivo exato de cada uma.

### 19.9 Quatro bugs reais encontrados só no deploy real (pós-entrega, corrigidos com o usuário em produção)

A limitação da seção 19.8 (build Docker não testável localmente) se confirmou na prática: o primeiro deploy real no Railway e a primeira aplicação dos seeds num Supabase real expuseram quatro problemas que nenhuma bateria local — mesmo com PostgREST + JWT reais — conseguiria pegar, porque dependiam especificamente do ambiente de produção (imagem Docker de verdade, rede real até o Supabase, e a ORDEM real de deploy: todas as migrations primeiro, seeds depois — diferente da reconstrução incremental fase-a-fase usada nas baterias locais).

**1. Rota async que lança erro síncrono travava a resposta em vez de responder (502).** Nenhum handler tinha `try/catch` em torno de `clientForRequest()` (`api/lib/supabaseClient.js`), e o Express 4 não encaminha automaticamente uma rejeição de handler `async` para o middleware de erro — um `throw` síncrono dentro de `createClient()` (por exemplo, se `SUPABASE_URL` estivesse vazia) virava uma promise rejeitada sem handler, a requisição nunca recebia resposta, e o Railway derrubava a conexão com `502` depois do timeout, sem nenhum log útil do lado do cliente. Corrigido adicionando `require('express-async-errors')` uma única vez em `server.js` (antes de qualquer `express.Router()` ser criado) — resolve para todas as rotas de uma vez, sem editar cada arquivo em `routes/`. Reproduzido e confirmado localmente (forçando `SUPABASE_URL=""`): antes da correção a requisição ficava pendurada; depois, responde `500 {"error":"Erro interno."}` imediatamente, com o erro completo logado no servidor. Bateria completa re-executada após a correção — 18/18 PASS, sem regressão.

**2. `@supabase/supabase-js` exige WebSocket nativo (Node 22+) para inicializar, mesmo sem usar Realtime.** A causa raiz real do `502`/`500` em produção: `api/Dockerfile` usava `node:20-alpine`, mas o `SupabaseClient` sempre inicializa um `RealtimeClient` internamente ao ser construído (mesmo quando a aplicação nunca assina nenhum canal de Realtime — esta API só usa `.rpc()`), e essa inicialização exige `WebSocket` nativo do runtime, disponível de forma estável só a partir do Node 22 (o próprio pacote já emite um aviso de depreciação para Node ≤20, mas o erro em si é fatal, não só um aviso). Nenhum teste local pegou isso porque o ambiente de desenvolvimento desta sessão já roda Node 22 nativamente — só apareceu na imagem Docker real do Railway. Corrigido trocando as duas stages do `api/Dockerfile` de `node:20-alpine` para `node:22-alpine`. Não exigiu nenhuma mudança de código-fonte, só da imagem base.

**3. `supabase/seed_producao.sql` violava `pricing_parametros.pricing_version NOT NULL` quando aplicado depois de TODAS as migrations.** A coluna `pricing_version` nasceu como um `to_char(vigente_desde,'YYYY.MM')` calculado on-the-fly e só virou coluna real, `NOT NULL`, na migration `20260830090000` (Fase 2.2.1) — que faz o backfill (`update ... set pricing_version = to_char(vigente_desde,'YYYY.MM') where pricing_version is null`) das linhas que **já existiam** naquele momento. Nas baterias locais, `seed.sql`/`seed_producao.sql` sempre rodam logo depois só das migrations da Fase 1 (reconstrução incremental fase a fase — ver seção 19.9 acima sobre a ordem), então o backfill dessa migration futura sempre alcança as linhas do seed quando ela finalmente roda. No deploy real, a ordem é invertida (todas as 74 migrations primeiro, seed por último): a coluna já existe e já é `NOT NULL` no momento do `INSERT`, mas o `INSERT` de `pricing_parametros` em `seed_producao.sql` nunca informava essa coluna — violação de constraint, seed inteiro abortado. Corrigido informando `pricing_version` explicitamente no `INSERT` (`to_char(current_date,'YYYY.MM')`, mesma convenção do backfill da migration). **Importante:** `supabase/seed.sql` (usado só nas baterias locais) foi deliberadamente **mantido como estava** — corrigi-lo do mesmo jeito quebraria a reconstrução incremental local, porque nela a coluna genuinamente não existe ainda no momento em que `seed.sql` roda; os dois arquivos têm o mesmo texto de INSERT por coincidência de terem a mesma origem, não porque precisam ser idênticos.

**4. `supabase/seed_producao.sql` criava `CABO-JUSSARA-01` sem `pop_id`, quebrando o primeiro `INSERT` em `infra_portas_pon` de `seed_fase11.sql`.** A migration `20260825100100_infra_pops.sql` (Fase 1.1) cria a tabela `infra_pops` e faz um backfill **único, na hora em que a migration roda**: para todo cabo que já existir SEM `pop_id` naquele momento, cria um `POP-01` (`PRINCIPAL`) e associa. Isso funciona nas baterias locais porque `seed.sql` (que cria `CABO-JUSSARA-01` sem `pop_id`) sempre roda ANTES dessa migration, na reconstrução incremental fase a fase — o backfill encontra o cabo e o corrige. No deploy real, a migration já rodou (e não achou nenhum cabo, pois `seed_producao.sql` ainda nem tinha rodado) quando o cabo é finalmente criado — fica com `pop_id` nulo para sempre, e o primeiro `insert into infra_portas_pon` de `seed_fase11.sql` falha na trigger `fn_valida_porta_pon_pop` ('Fibra ... está associada a um cabo sem POP definido'). Corrigido fazendo `seed_producao.sql` criar o `POP-01` explicitamente (mesmo código/nome/tipo que o backfill da migration usaria) e vincular `CABO-JUSSARA-01` a ele no próprio `INSERT`. Mesmo raciocínio do bug 3: `seed.sql` não precisou de mudança, só `seed_producao.sql`.

Os bugs 1 e 2 foram encontrados e corrigidos em conjunto com o usuário, olhando os logs reais do Railway (`[optimon-api] erro não tratado: ...`) depois do primeiro deploy. Os bugs 3 e 4 foram encontrados ao aplicar os seeds pela primeira vez contra um Supabase real já com todas as migrations aplicadas (ordem que nenhuma bateria local reproduz) — mesma causa raiz nos dois: um seed escrito e testado só sob a ordem "algumas migrations → seed → mais migrations" quebra sob a ordem real de produção "todas as migrations → seed", porque backfills de migração são inerentemente pontuais no tempo. Verificado depois da correção: `seed_producao.sql` + `seed_fase11.sql` + `seed_fase12.sql` + `seed_fase2.sql` aplicados em sequência, do zero, contra um banco com as 74 migrations já aplicadas (a ordem real de produção) — os 4 arquivos aplicam sem erro. Bateria completa de regressão re-executada — 124/124 PASS, sem regressão (nenhuma mudança em `seed.sql`, que é o único seed usado pelos testes locais).

## 20. Fase 2.3 — Módulo de Gestão de Cidades e Infraestrutura

Onde toda fase anterior tratava Jussara-PR como o único registro de cidade do sistema (rota fixa `/cidades/jussara`, item de menu "Jussara — PR", componentes que assumiam essa cidade), esta fase remove por completo esse tratamento especial e entrega o CRUD real de cidades e infraestrutura que faltava para o OptiMon deixar de ser uma demonstração de caso único e virar, de fato, um **produto multi-cidade** (regra fundamental da seção 3 do Prompt Mestre desta fase, reiterada na seção 42). **4 migrations novas** (prefixo `20260901`) sobre o banco com dados reais de Fase 1 até Fase 2.2.1 Parte 2 — sem recriar tabela, sem apagar migration, sem duplicar coluna.

### 20.1 Decisão de arquitetura: wrappers SQL só onde a regra de negócio exige (seção 13)

Ao contrário das fases anteriores, que expunham quase toda escrita via função SQL (`app.*` + wrapper `public.*`), a maior parte do CRUD novo desta fase (POP, segmento, poste, status de fibra, porta PON) é feita por **INSERT/UPDATE direto na tabela a partir do Express**, via `supabase-js` com o JWT do usuário (nunca a service role) — porque a RLS por perfil (`app.tem_perfil()`, já existente desde a Fase 1) e os triggers de auditoria genéricos (`fn_auditoria()`) já dão autorização e rastreamento completos sem precisar de uma função SQL no meio. Só dois casos ganharam wrapper dedicado, porque têm regra de negócio real que uma tabela sozinha não expressa: `cidade` (criar/editar exige validação; arquivar exige checar contrato ativo — seção 20.3) e `cabo+fibras` (criar um cabo precisa gerar N fibras na mesma transação, atomicamente — seção 20.2). Essa é uma leitura deliberada da instrução da seção 13 ("criar só os wrappers necessários"), documentada aqui e no relatório final para nunca ser confundida com uma omissão.

### 20.2 `app.criar_cabo_com_fibras` — o único wrapper que precisa ser atômico

`POST /api/infra/cables` chama `app.criar_cabo_com_fibras(p_segmento_id, p_identificacao, p_capacidade_fo, p_pop_id, p_fabricante)` (exposta como `public.pricing_cable_create_with_fibers`, `SECURITY INVOKER`), que faz `INSERT` em `infra_cabos` e depois um `generate_series(1, p_capacidade_fo)` inserindo uma linha em `infra_fibras` por número de fibra, tudo dentro da mesma função — se qualquer fibra falhar, o cabo inteiro não é criado (nunca um cabo com fibras faltando). Devolve só o `cabo_id`; o frontend busca a lista de fibras separadamente (`GET /api/infra/cables/:id/fibers`), evitando um payload gigante numa única resposta para cabos de alta capacidade.

### 20.3 CRUD de cidades com regra de arquivamento (seções 8-10)

`app.criar_cidade`/`app.atualizar_cidade`/`app.arquivar_cidade` (wrappers `public.pricing_city_create`/`pricing_city_update`/`pricing_city_archive`) adicionam uma coluna `status` a `cidades_infra` (`ATIVA`/`ARQUIVADA`, default `ATIVA`) e reaproveitam a coluna `removido_em` (existente desde a Fase 1) para o "soft delete" — arquivar nunca é um `DELETE` físico. A regra de bloqueio (seção 10/31/32) é: **bloquear o arquivamento só quando existir um `contrato` com `status='ATIVO'` para aquela cidade** — não quando a cidade meramente tiver POP/cabo/fibra/poste cadastrado. Essa é uma leitura literal do texto e do cenário de teste oficial da seção 31/32 (arquivar Jussara, que tem contrato ativo, deve falhar com a mensagem exata "Não é possível arquivar uma cidade com contrato ativo."; arquivar uma cidade de teste sem contrato deve funcionar mesmo já tendo POP/cabo/fibra cadastrados) — documentada aqui para nunca ser confundida com um bug caso alguém espere o bloqueio também por mera existência de infraestrutura.

### 20.4 Lacuna de auditoria fechada: `infra_segmentos`/`infra_cabos`/`infra_postes` nunca tinham trigger (seção 38)

Um bug latente desde que essas 3 tabelas foram criadas (Fase 1/1.1): tinham a estrutura para receber o trigger genérico `fn_auditoria()` (o mesmo padrão já usado em `cidades_infra`, `infra_pops`, `infra_fibras`, `infra_portas_pon` desde suas respectivas fases de origem), mas o `CREATE TRIGGER` correspondente nunca tinha sido escrito. Corrigido com `trg_aud_infra_segmentos`/`trg_aud_infra_cabos`/`trg_aud_infra_postes` (AFTER INSERT OR UPDATE OR DELETE, mesma assinatura das demais) — nenhuma tabela recriada, nenhum dado existente tocado. Com isso, as 7 tabelas de infraestrutura que a seção 38 pede (`cidades_infra`, `infra_pops`, `infra_cabos`, `infra_segmentos`, `infra_fibras`, `infra_postes`, `infra_portas_pon`) têm cobertura de auditoria automática — usuário/data/hora/ação/dados anteriores/dados novos capturados pelo mesmo `fn_auditoria()` de sempre, testado explicitamente pelos casos AUD-1..AUD-16 (ver `README.md` e `docs/RELATORIO_FASE23.md`).

### 20.5 `pricing_cities_list()`/`pricing_city_detail()` enriquecidas — o mesmo bug de `returns table` da Fase 2.2

Igual ao que já tinha acontecido na Fase 2.2 (seção 17.10) e de novo na Fase 2.2.1 (seção 18), adicionar colunas ao retorno de `pricing_cities_list()` (status, FOs totais/ociosas, portas PON) mudou o tipo composto implícito de uma função `returns table(...)`, e o Postgres recusa um `CREATE OR REPLACE` que muda o tipo de retorno (`ERROR: cannot change return type of existing function`) — corrigido com `DROP FUNCTION IF EXISTS` antes do `CREATE FUNCTION`, mesma disciplina já documentada nas fases anteriores. `pricing_city_detail()` (que devolve `jsonb`, não uma tabela tipada) não teve esse problema — só precisou de `CREATE OR REPLACE` normal para incluir `status`/`fibras_bloqueadas` e o array de POPs completo (endereço/lat/long/capacidade/observações, evitando uma segunda chamada da tela de edição de infraestrutura).

### 20.6 Nova função `pricing_city_infra_tree(uuid)` — visão consolidada (seção 20)

Uma função só de leitura que devolve, num único `jsonb`, a árvore completa de uma cidade — POPs → segmentos → cabos → fibras, mais os postes — para alimentar a tela "Editar Infraestrutura" sem N chamadas separadas por nível. `STABLE`, `SECURITY INVOKER`, exposta como `public.pricing_city_infra_tree`.

### 20.7 Frontend: remoção completa do tratamento especial de Jussara

`App.jsx` perdeu a rota fixa `/cidades/jussara`; `Layout.jsx` perdeu o item de menu "Jussara — PR" (agora só "Cidades & Infraestrutura", genérico); `Dashboard.jsx`, `NewSimulation.jsx` e `CityDetail.jsx` foram revisados para nunca assumir uma cidade específica — todo lugar que antes segurava um id fixo agora lê a lista de cidades da API e deixa o usuário escolher. 3 telas novas: `Cities.jsx` (lista com busca), `NewCity.jsx` (cadastro, redireciona para a edição de infraestrutura ao salvar) e `EditCity.jsx` (a maior tela nova — 6 sub-componentes: dados da cidade, POPs, segmentos, cabos/fibras, postes, portas PON). Confirmado por teste automatizado (seção 20.9, SEC3/SEC5) que nenhuma referência a "jussara" (case-insensitive) sobrou em `web/src`.

### 20.8 Backend: `api/routes/infra.js` (novo) + `api/routes/cities.js` (reescrito)

`cities.js` ganhou `POST`/`PATCH`/`POST .../archive`, todos mapeando o erro de RBAC/RLS do Postgres para o HTTP correto (403 para bloqueio de permissão, 409 para o bloqueio de arquivamento com contrato ativo, com a mensagem literal da seção 20.3 repassada ao cliente). `infra.js` é arquivo novo, com toda a superfície de POP/segmento/cabo/fibra/poste/porta PON descrita nas seções 20.1-20.2 acima. Nenhuma rota nova ignora `clientForRequest(req.userJwt)` — a mesma disciplina desde a Fase 2.2.1 Parte 2 de nunca usar a service role na API.

### 20.9 Bateria de testes desta fase (seções 26-33, 38, 40)

`tests/run_tests_fase23.sh` — **54 de 54 verificações passando**, reexecutando `tests/run_tests_deploy.sh` **original, sem editar**, como PASSO-0 (o que por sua vez reexecuta toda a cadeia Fase 1→2.2.1) antes de aplicar as 4 migrations novas — a cadeia completa soma 196 verificações, 0 quebrado. Testes próprios: SEC3/SEC5 (ausência de qualquer "jussara" hard-coded), TESTE-C1..C9 (cidade nova do zero, com Pricing Engine calculando para ela), TESTE-A1..A3 (segunda cidade sem afetar Jussara), TESTE-E1..E3/I1/I2 (edição + isolamento, com baseline de Jussara capturado dinamicamente no início do script — necessário porque cada fase anterior já deixou fixtures próprios sobre a mesma Jussara, então um número fixo tipo "12 FO" só seria literal logo após um `seed.sql` puro), TESTE-P1..P9 (RBAC por rota nos 4 perfis), AUD-1..AUD-16 (seção 20.4, incluindo os 2 casos de UPDATE via SQL direto em cabo/poste — que não têm endpoint de edição na especificação — para provar que o trigger cobre a tabela mesmo sem uma rota dedicada; nesses 2 casos `usuario_id` é `NULL` corretamente, porque não há JWT de requisição associado a um `UPDATE` feito fora da API, e o teste reflete isso explicitamente em vez de exigir um usuário que não existe) e TESTE-AR1..AR5 (arquivamento com e sem contrato ativo). O E2E obrigatório da seção 40 (`tests/e2e_fase23.js`, Playwright real contra o frontend Vite/React, autenticando por injeção de sessão em `localStorage` — o mesmo padrão da Fase 2.2.1 Parte 2, já que não existe GoTrue real neste ambiente) roda à parte: **11 de 11 PASS**.

Duas correções reais, ambas disclosed: o `DROP FUNCTION` de `pricing_cities_list()` (seção 20.5, mesma classe de bug já vista 2 vezes antes nesta arquitetura) e um `waitForTimeout(2000)` fixo no E2E-9 que corria contra as 3 chamadas concorrentes de `runSimulation()` (`calculate`/`growth-curve`/`horizon-table`) — o cálculo em si sempre respondia 200, mas 2 segundos nem sempre bastava para as 3 resolverem em Chromium headless "frio", então a régua de preço às vezes ainda não tinha renderizado no momento da checagem; corrigido trocando o sleep fixo por `page.waitForSelector('.regua', ...)`.

### 20.10 O que esta fase deliberadamente NÃO fez

Não criou nenhuma "cidade demo" especial nem qualquer código específico para Jussara — Jussara continua sendo só o primeiro registro real do banco (seção 42 do Prompt Mestre). Não iniciou a Fase 3. Não aplicou as 4 migrations novas nem publicou o código desta fase nos ambientes reais (GitHub/Supabase/Railway/Vercel) já existentes desde a Fase 2.2.1 Parte 2 — depende do usuário executar o runbook incremental da seção "Deploy real" do `README.md`, pelo mesmo motivo de sempre (esta sessão nunca manuseia credencial real, mesmo com autorização explícita). Nenhuma dessas é uma pendência escondida — todas listadas aqui, no `README.md` e no relatório final, com o checklist de aceite de 22 itens marcando exatamente qual é o único item ainda pendente.

## 21. Fase 2.3.1 — CRUD Completo (Cidades, POPs, Segmentos, Cabos, Fibras, Postes, Portas PON)

A Fase 2.3 deu às telas de Cidades & Infraestrutura só a ação de **criar**; esta fase completa o CRUD de verdade — Visualizar/Editar/Arquivar/Restaurar — nas 7 entidades, sempre com exclusão lógica (nunca `DELETE` físico), com bloqueio automático de arquivamento por dependência ativa e restauração restrita a `ADMINISTRADOR`/`DIRETOR`. **4 migrations novas** (prefixo `20260902`), todas aditivas.

### 21.1 Auditoria semântica em cima da genérica, não em substituição (seção 28)

A auditoria genérica por trigger (`fn_auditoria()`, desde a Fase 1) já registra toda alteração como `UPDATE` com dados anteriores/novos — isso não muda. O que faltava era um rótulo semântico distinguindo um arquivamento/restauração/bloqueio de um `UPDATE` qualquer. Em vez de reescrever o trigger (arriscado, tocaria toda tabela auditada desde a Fase 1), cada função de arquivar/restaurar chama `app.registrar_auditoria_semantica()` (nova, `SECURITY DEFINER`, uso interno — nunca exposta via PostgREST) logo depois do `UPDATE` — um arquivamento bem-sucedido gera 2 linhas de auditoria (`UPDATE` genérico + `ARCHIVE` semântico), intencional. Bloqueios são um caso à parte: um `RAISE EXCEPTION` desfaz a transação inteira, inclusive qualquer `INSERT` de auditoria feito antes dele — por isso `BLOCKED_ARCHIVE`/`BLOCKED_DELETE` não são gravados dentro da função SQL que bloqueia; é a API, ao capturar o erro (transação já abortada), que chama `public.pricing_log_blocked_action` numa segunda chamada RPC, numa transação nova.

### 21.2 Regra de bloqueio por entidade (seções 11-17)

Cada `app.arquivar_*` tem sua própria checagem, refletindo a leitura literal do prompt: cidade bloqueia só por `contrato` `ATIVO` (herdado da Fase 2.3, seção 20.3 — não por mera existência de infraestrutura); POP bloqueia por cabo ou Porta PON **ativos**; segmento bloqueia por cabo ou lote de postes **ativos**; cabo bloqueia por fibra `OCUPADA`/`LOCADA`, Porta PON **ativa** (`status <> 'INATIVA'`), ou vínculo de contrato ativo (`contrato_fibras.desvinculado_em is null`); poste nunca bloqueia (sem dependência estrutural com outra tabela no modelo atual); Porta PON bloqueia por cliente ativo (`capacidade_utilizada_assinantes > 0`). Porta PON não ganhou coluna `removido_em` própria — "arquivar" reaproveita a coluna `status` já existente desde a Fase 1.1 (`ATIVA`/`INATIVA`/`MANUTENCAO`): arquivar = `status` → `INATIVA`; restaurar = de volta a `ATIVA`.

### 21.3 Bug real de arquitetura: `app.restaurar_*` como `SECURITY INVOKER` deixava `DIRETOR` sem efeito nenhum

O bug mais sério encontrado durante a validação desta fase. As 6 funções `app.restaurar_cidade/pop/segmento/cabo/poste/porta_pon` já faziam sua própria checagem de RBAC (`app.tem_perfil('ADMINISTRADOR', 'DIRETOR')`) antes de tocar a tabela — mas rodavam como `SECURITY INVOKER`, então o `UPDATE` que de fato limpa `removido_em` (ou `status`) continuava sujeito à *policy* de escrita/`UPDATE` de cada tabela (`infra_*_write`/`cidades_infra_update`), que só inclui `ENGENHARIA`/`ADMINISTRADOR` — nunca `DIRETOR`, porque essas *policies* nunca foram pensadas para modelar "quem pode restaurar", só "quem pode editar". Para `ADMINISTRADOR` isso batia por coincidência (está nos dois grupos) e mascarava o problema; para `DIRETOR`, RLS filtra silenciosamente as linhas visíveis ao `UPDATE` — não lança erro de permissão — então o comando "funcionava" sem afetar nenhuma linha: a API respondia `200`, a auditoria `RESTORE` era gravada normalmente (chamada incondicional, sem checar `ROW_COUNT`), e o dado no banco nunca mudava. Só percebido consultando o estado real da linha depois de um "restaurar" bem-sucedido segundo o próprio teste — o mesmo padrão de falso-positivo já documentado para `app.registrar_auditoria_semantica` na seção 21.1 (uma função `SECURITY INVOKER` chamando algo que precisa de privilégio elevado, sem o ter). Corrigido convertendo as 6 funções para `SECURITY DEFINER` com `search_path` fixo (`public, pg_temp`) — a mesma justificativa já usada para `registrar_auditoria_semantica`: só eleva privilégio para uma função que já se autoriza sozinha, nunca para pular a autorização.

### 21.4 Bug real de frontend: infraestrutura arquivada continuava selecionável para um vínculo novo

Os formulários de criação de Cabo (`CablesSection`), lote de Postes (`PolesSection`) e Porta PON (`PonPortsSection`), em `EditCity.jsx`, listavam POPs/Segmentos sem filtrar `arquivado` — um cabo novo, por exemplo, podia ser criado apontando para um segmento já arquivado. Corrigido filtrando as 3 listas de criação para só oferecer itens ativos (`!p.arquivado`/`!s.arquivado`), e também as fibras disponíveis para Porta PON nova (excluindo cabos arquivados, mesmo que uma fibra individual ainda esteja `LIVRE`). Os formulários de *edição* (`CableEditForm`/`PoleEditForm`) preservam o vínculo já existente mesmo que tenha sido arquivado depois, mas também não oferecem um segundo vínculo novo a algo arquivado — coberto pelo E2E (seção 21.6).

### 21.5 Infraestrutura arquivada nunca conta no Pricing Engine nem no Dashboard (seção 39)

`vw_capacidade_cidade`/`vw_porta_pon_detalhe` passam a excluir infraestrutura arquivada por padrão; `pricing_cities_list`/`pricing_city_detail` ganham a flag `arquivada`; `pricing_city_infra_tree` só inclui itens arquivados quando `p_incluir_arquivados=true` é passado explicitamente (usado pela tela "Editar Infraestrutura", que precisa mostrar tudo e filtrar no cliente por seção) — o `GET /api/infra/tree` público, sem esse parâmetro, nunca vaza infraestrutura arquivada para nenhum outro consumidor.

### 21.6 Bateria de testes desta fase (seções 31-39, 40)

`tests/run_tests_fase231.sh` — **81 de 81 verificações passando**, reexecutando `tests/run_tests_fase23.sh` **original, sem editar**, como PASSO-0 (que por sua vez reexecuta toda a cadeia Fase 1→2.3, 196 verificações) antes de aplicar as 4 migrations novas. Testes próprios: SECAO 31-37 (CRUD completo + bloqueio + auditoria de cada uma das 7 entidades), SECAO 38 (RBAC nos 6 perfis), SECAO 39 (exclusão do Pricing/Dashboard, seção 21.5). O E2E obrigatório da seção 40 (`tests/e2e_fase231.js`, Playwright real contra o frontend, mesmo padrão de autenticação local da Fase 2.3) roda à parte: **16 de 16 PASS**, seguindo literalmente o fluxo do prompt (login → Jussara → editar KM → Dashboard → editar POP → arquivar/consultar/restaurar segmento de teste → Nova Simulação → confirma que só infraestrutura ativa fica disponível).

### 21.7 O que esta fase deliberadamente NÃO fez

Não iniciou a Fase 3 — por instrução explícita da seção 42 do Prompt Mestre desta fase ("NÃO iniciar nova fase. Entregar relatório completo dos testes e aguardar aprovação."). Deploy real não fazia parte do escopo desta fase (diferente da Fase 2.3, que tinha isso como item pendente do checklist) — só validação local completa e relatório. Nenhuma migration de fase anterior foi editada, nenhuma tabela recriada, nenhum endpoint `DELETE` genérico foi criado em nenhuma rota. Checklist de aceite completo (28 itens, 28/28 PASS) em `docs/RELATORIO_FASE231.md`.

## 22. Fase 2.4 — Manuais Operacionais + Central de Ajuda + Módulo Profissional de Propostas + Exportação PDF/DOCX + Histórico e Controle de Versões

Esta fase tem duas frentes independentes: uma Central de Ajuda (manuais por perfil, glossário, FAQ, busca, tooltips, onboarding) e, como ponto central, transformar o módulo de Propostas — desde a Fase 1 uma listagem simples — num documento comercial profissional com dois modos de visualização, exportação real em PDF/DOCX, versionamento e um fluxo de aprovação com governança. **2 migrations novas** (prefixo `20260909`), todas aditivas.

### 22.1 Por que `numero_versao`/`proposta_raiz_id` viraram colunas, e não uma tabela de histórico separada

A decisão de modelagem central desta fase: cada versão de uma proposta é uma **linha nova e completa** em `propostas_comerciais` (não um diff, não uma tabela de auditoria à parte) — necessário porque o modelo de negócio exige que cada versão seja um snapshot imutável e auditável por si só (preço, cenário, status e autorização podem divergir entre V1 e V2). O desafio foi preservar a identidade "isto é a mesma proposta, revisão 2" sem violar `UNIQUE(numero)` (herdado da Fase 2.2.1) nem sem inventar uma segunda chave primária. A solução: `proposta_raiz_id` aponta sempre para a V1 da família (própria trigger `fn_proposta_raiz_id_default` garante isso até em INSERTs "soltos", fora de `criar_versao_proposta`), e `numero_versao` é um inteiro simples incrementado por família — a query de "só a última versão" (usada por padrão em `pricing_proposals_list`) é uma correlated subquery em cima de `max(numero_versao)`, sem precisar de uma coluna "é a versão atual" que teria que ser mantida sincronizada.

### 22.2 O bug de numeração de versão — e por que ele só apareceu no teste de correção semântica, não em nenhuma checagem de schema

`app.criar_versao_proposta` originalmente omitia `numero` da lista de colunas do INSERT, deixando o valor vir do default da coluna (um gerador aleatório/sequencial independente). O SQL executava sem erro, a linha era criada, a auditoria `PROPOSAL_VERSION_CREATE` era gravada — nenhuma dessas camadas detecta o problema, porque nenhuma delas sabe que "V2 deveria compartilhar a raiz do número de V1" é uma regra de negócio, não uma restrição de schema. Só foi pego porque o teste (`TESTE-8a`) fez uma asserção de conteúdo, não só de status HTTP: comparou o `numero` retornado de V2 contra o `numero` de V1 concatenado com `-V2`. Corrigido buscando `numero` da linha raiz (`select numero from propostas_comerciais where id = v_raiz_id`) e montando `v_raiz_numero || '-V' || v_proxima_versao` explicitamente antes do INSERT — sempre a partir da raiz, nunca da versão anterior, para não empilhar sufixo (`-V2-V3`) numa cadeia V2→V3→V4.

### 22.3 `SECURITY INVOKER` continua correto aqui — ao contrário do padrão `SECURITY DEFINER` da Fase 2.3.1

A Fase 2.3.1 (seção 21.3 acima) precisou converter `app.restaurar_*` para `SECURITY DEFINER` porque a *policy* de `UPDATE` das tabelas de infraestrutura não cobria `DIRETOR`, mesmo esse perfil sendo permitido pela checagem de RBAC da função. Antes de repetir esse padrão aqui por hábito, a *policy* `_update` existente em `propostas_comerciais` foi lida com atenção: `(DIRETOR/ADMINISTRADOR) OR (criado_por = auth.uid() AND status = 'RASCUNHO')` — isso já cobre exatamente os mesmos perfis que `app.aprovar_proposta`/`rejeitar_proposta`/`mudar_status_proposta` permitem via `app.tem_perfil()`. Não havia o mesmo descompasso, então as 5 funções de transição de status foram mantidas `SECURITY INVOKER` — e, ao contrário do bug da Fase 2.3.1 (onde um `UPDATE` sem efeito voltava `200` silenciosamente), aqui um `UPDATE` bloqueado por RLS de um perfil não coberto pela *policy* gera um erro Postgres real (a cláusula `WITH CHECK` rejeita a linha), não um "sucesso" vazio — verificado explicitamente antes de decidir não converter, e confirmado no teste (`TESTE-3`: COMERCIAL tentando aprovar recebe `403` de verdade, mapeado do erro RLS pelo `handleError` da API).

### 22.4 A fronteira Interna × Externa — duas camadas independentes, de propósito

O requisito mais sensível desta fase: o modo Externa (o que um parceiro veria) nunca pode conter piso, abertura, desconto ou qualquer dado de governança/autorização. Em vez de confiar numa única camada, a fronteira foi implementada duas vezes, com raciocínios diferentes: (1) no banco, `public.pricing_proposal_external_view` é uma função *whitelist-only* — ela nunca vê os campos sensíveis para começar, porque eles simplesmente não estão na lista de chaves que ela extrai do jsonb interno; é o mecanismo que atende `GET /:id/public`, pensado para nunca vazar mesmo que um bug apareça em outro lugar. (2) na geração de documento (`proposalDocumentModel.js`), a decisão foi **não duplicar a busca de dados** — o PDF/DOCX sempre busca o jsonb interno completo via `pricing_proposal_get_by_id` (é mais simples manter uma função de enriquecimento só), e cada seção do documento decide o que renderizar com base em `modo`. Essa segunda camada é mais arriscada por design (o dado sensível chega até o código de geração, só não é escrito na saída) — por isso foi verificada de forma automatizada e não só por inspeção: `tests/run_tests_fase24.sh` roda `pdftotext` sobre o PDF gerado em modo Externa e faz `grep -iE` por "piso mínimo mensal garantido", "desconto máximo permitido", "governança (avaliação automática)" e "autorizado por" — um vazamento de texto nessas seções teria feito o teste falhar antes de qualquer entrega.

### 22.5 Por que PDF via `pdfkit` e DOCX via `docx` — nenhuma dependência nativa

A imagem Docker de produção do backend (`api/Dockerfile`) é `node:22-alpine`, publicada no Railway. Gerar PDF "renderizando a tela" (um navegador headless tipo Puppeteer/Playwright) ou usando uma lib de gráfico com dependência de canvas nativo (`node-canvas`, que compila contra `cairo`/`pango`) arriscaria quebrar esse build — Alpine usa `musl` em vez de `glibc`, e dependências nativas compiladas para Debian/Ubuntu frequentemente falham silenciosamente ou exigem pacotes de sistema extras não presentes na imagem mínima. `pdfkit` e `docx` foram escolhidos especificamente por serem puramente JavaScript, sem `node-gyp`/binário nativo algum. A consequência dessa escolha: os 4 "gráficos" da proposta são desenhados como barras vetoriais com primitivas (`rect`/`text`) no PDF (não uma lib de charting), e como tabelas de dados editáveis no DOCX (não uma imagem embutida) — um tradeoff arquitetural deliberado e documentado, não uma limitação escondida; o pacote `docx` não tem suporte nativo a gráfico vetorial sem a mesma classe de dependência nativa que se optou por evitar.

### 22.6 Status automático na criação × motivo obrigatório na aprovação — dois momentos diferentes da mesma regra

`pricing_proposal_create` decide o status na hora de criar comparando `preco_proposto` com `recommended` (não com `floor`): abaixo do recomendado → `EM_APROVACAO`, senão → `RASCUNHO`. Isso cobre igualmente o caso "entre piso e recomendado" e o caso "abaixo do piso" — ambos nascem `EM_APROVACAO`, porque na criação a única pergunta é "isso precisa de aprovação?". A pergunta mais específica — "isso precisa de justificativa por estar abaixo do piso?" — só é respondida depois, no momento da aprovação em si (`app.aprovar_proposta`, comparando `preco` com `floor` especificamente): se estiver abaixo do piso e nenhum motivo foi enviado, a função recusa com `MOTIVO_OBRIGATORIO`, mapeado pela API para `400`. Separar as duas checagens em momentos diferentes evita duplicar a mesma lógica de comparação em dois lugares e reflete o fluxo real: um COMERCIAL pode salvar um rascunho abaixo do piso sem nenhuma justificativa ainda — a exigência só bloqueia quando alguém de fato tenta aprovar.

### 22.7 Bateria de testes desta fase (TESTE 0-11)

`tests/run_tests_fase24.sh` — **31 de 31 verificações passando**, reexecutando `tests/run_tests_fase231.sh` **original, sem editar**, como PASSO-0 (que por sua vez reexecuta toda a cadeia Fase 1→2.3.1) antes de aplicar as 2 migrations novas. O E2E obrigatório (`tests/e2e_fase24.js`, Playwright real contra o frontend, mesmo padrão de autenticação local por injeção de sessão em `localStorage`) roda à parte: **13 de 13 PASS**. Detalhe teste a teste, e os 4 bugs reais encontrados durante a própria validação (numeração de versão, quebra de regressão encadeada por parâmetro novo enviado incondicionalmente, `Content-Disposition` não exposto em CORS cross-origin, e um `save()`/`restore()` desnecessário quebrando a geração de PDF), estão em `docs/RELATORIO_FASE24.md`.

### 22.8 O que esta fase deliberadamente NÃO fez

Não iniciou a Fase 3 — por instrução do Prompt Mestre desta fase ("NÃO iniciar nova fase até todos os itens do checklist estarem PASS. Entregar relatório final detalhado."). Deploy real não fazia parte do escopo desta fase — só validação local completa e relatório, mesmo padrão da Fase 2.3.1. Não criou nenhuma página HTML pública dedicada para `/propostas/:id/public` — só o endpoint de API que a alimentaria (`pricing_proposal_external_view`), já testado e pronto. Nenhuma migration de fase anterior foi editada, nenhuma tabela recriada, nenhum dado existente apagado. Checklist de aceite completo (23 itens, 23/23 PASS) em `docs/RELATORIO_FASE24.md`.

## 23. Fase 2.5 — Gestão de Usuários + Proponentes + Responsáveis + Aprovação Interna + Assinatura Eletrônica ICP-Brasil + Contrato Automático + Aditivos + Gestão do Ciclo Proposta → Contrato

Fase mais extensa do projeto até aqui: fecha o ciclo comercial inteiro, de Usuário até Contrato Ativo, e introduz o motor de assinatura eletrônica como orquestrador — nunca como Autoridade Certificadora própria. **14 migrations novas** (prefixo `20260913`), todas aditivas. Relatório completo (16 seções + checklist de 28 itens) em `docs/RELATORIO_FASE25.md`; este bloco cobre só as decisões de arquitetura que valem registrar aqui, no mesmo padrão das seções anteriores.

### 23.1 "ICP-Brasil First" como restrição de arquitetura, não como feature

O requisito mais rígido do prompt-mestre desta fase é negativo: OptiMon nunca pode se tornar uma Autoridade Certificadora, um PSC ou um substituto de HSM — só um orquestrador que fala com provedores reais. Isso foi traduzido em uma decisão de código concreta: `api/lib/signatureProvider.js` define `ElectronicSignatureProvider` como uma classe abstrata com 11 métodos, todos lançando "não implementado" por padrão — nenhuma lógica de negócio do resto do sistema (SQL ou Node) importa ou conhece `MockHomologacaoProvider` diretamente; tudo passa pela fábrica `buildProvider(providerRow)`, que decide a implementação concreta em tempo de execução a partir de `signature_providers.tipo`. Trocar de mock para um provedor real de produção é, por construção, trocar uma linha de configuração no banco — nunca uma mudança de código em `signatures.js`, `contracts.js` ou nas funções SQL. O reforço dessa restrição no próprio banco: `signature_providers` tem um CHECK que impede a combinação `tipo = 'ICP_BRASIL_HOMOLOGACAO_MOCK'` com `ambiente = 'PRODUCAO'` — não é possível "ir para produção" com o mock nem por engano de configuração.

### 23.2 Por que o webhook de assinatura precisou de `anon` — e o bug real que isso escondia

`POST /api/signatures/webhook` é chamado pelo provedor de assinatura externo, que não tem (e não deveria ter) um JWT de usuário OptiMon — por isso a rota é montada com `anonClient()` (sem `Authorization` de usuário) e as funções SQL que ela chama (`registrar_evento_assinatura_webhook`, e as variantes por `provider_id`) são concedidas a `anon`. Isso expôs, pela primeira vez neste projeto, um caminho de código realmente exercitado como `anon` via HTTP — nenhuma fase anterior tinha testado isso de ponta a ponta. Três descobertas em cadeia, nessa ordem: (1) `anon` não atravessa o schema `app` mesmo com `GRANT EXECUTE` direto na função (confirmado via `has_schema_privilege`) — corrigido tornando o wrapper `public.*` `SECURITY DEFINER`; (2) o `SUPABASE_ANON_KEY` local nunca tinha sido uma JWT real, só um placeholder de string — como `postgrest.local.conf` valida qualquer `Authorization` presente como JWT (não só quando `anon` está configurado como role default), um token mal formado gerava erro de autenticação, não anonimato; (3) a primeira correção mintou um JWT com `sub` de UUID zerado — sintaticamente válido, então `auth.uid()` devolvia esse UUID inexistente como se fosse um usuário real, violando a FK de auditoria (`auditoria.usuario_id`). A correção final usa `sub = "anon-key-no-user"` (formato não-UUID), fazendo o cast `::uuid` dentro de `auth.uid()` falhar de propósito e resolver para `NULL` — exatamente o comportamento de uma chave anônima real do Supabase, onde não existe usuário nenhum atrelado ao token. Ver `docs/RELATORIO_FASE25.md`, seção 11, item 4, para a cadeia completa de causa raiz.

### 23.3 Idempotência do webhook — por que `UNIQUE` + `ON CONFLICT DO NOTHING RETURNING`, e não uma checagem prévia

Provedores de assinatura reentregam eventos (rede instável, retry automático do lado deles) — o prompt-mestre exige idempotência explícita. A escolha de implementação: `signature_events` tem `UNIQUE(envelope_id, evento_externo_id)`, e o INSERT do evento é `INSERT ... ON CONFLICT (envelope_id, evento_externo_id) DO NOTHING RETURNING id`. Se a linha já existisse, nenhuma linha volta do `RETURNING` — o handler detecta isso e responde `200` sem reprocessar nenhum efeito colateral (sem tocar `signature_signers`, sem tocar `documentos_assinados`, sem gravar auditoria de novo). A alternativa óbvia — `SELECT` antes do `INSERT` para checar se o evento já existe — foi descartada por ter uma janela de corrida entre o `SELECT` e o `INSERT` sob concorrência real (dois retries do provedor chegando quase simultaneamente); o `UNIQUE` + `ON CONFLICT` é atômico por construção. Testado de forma real, não só por inspeção: `TESTE-16c` reenvia literalmente o mesmo payload de evento já processado e confirma que a contagem de eventos continua exatamente 2, não 3.

### 23.4 Divisão de responsabilidade: contrato decide "comprometido", Engenharia decide "qual fibra"

`app.ativar_contrato` exige que pelo menos uma linha exista em `contrato_fibras` antes de ativar (senão `INFRA_NAO_ALOCADA`) — mas em nenhum momento essa função ou qualquer função de geração de contrato escolhe *qual* fibra ou PON alocar. Essa é uma decisão de separação de responsabilidade deliberada, não uma lacuna: a camada de pricing/proposta/contrato trabalha inteiramente em nível agregado (quantas portas, qual capacidade, qual cidade); a seleção de um recurso físico específico (`contrato_fibras`, RLS restrita a ENGENHARIA) continua sendo sempre um passo manual e humano, feito por quem de fato conhece o estado físico da rede naquele momento. Automatizar essa escolha exigiria um algoritmo de alocação de topologia que está fora do escopo do prompt-mestre desta fase — e mais importante, misturaria uma decisão comercial (o contrato existe) com uma decisão técnica (qual fibra específica atende), que o projeto mantém deliberadamente em camadas RLS diferentes desde a Fase 1.1.

### 23.5 Bateria de testes desta fase (TESTE 01-25)

`tests/run_tests_fase25.sh` — **46 de 46 verificações passando, 0 falhas, 3 SKIP documentados** (ausência do schema `storage` no Postgres local — limitação de ambiente, não de código), reexecutando `tests/run_tests_fase24.sh` **original, sem editar**, como PASSO-0 (que por sua vez encadeia toda a cadeia Fase 1 → 2.4) antes de aplicar as 14 migrations novas — com uma única falha de regressão aceita e explicada (seção 12 de `docs/RELATORIO_FASE25.md`: o `partners.js` desta fase sempre seleciona colunas que só existem a partir desta fase, então rodar a Fase 2.4 isolada quebra essa única verificação por incompatibilidade histórica inevitável). Os 5 bugs reais encontrados durante a própria validação — RLS sem GRANT em 8 tabelas novas, `anon` não atravessando o schema `app`, 403 relatado como 404 em updates bloqueados por RLS, a cadeia completa do bug de JWT anônimo (seção 23.2 acima), e um bug de tratamento de `null` no próprio script de teste — estão detalhados em `docs/RELATORIO_FASE25.md`, seção 11.

### 23.6 O que esta fase deliberadamente NÃO fez

Não iniciou a Fase 3. Não integrou um provedor de assinatura real de produção — só o mock de homologação, exatamente como o prompt-mestre autorizou ("apenas um provedor precisa de integração real nesta fase"), com a arquitetura já pronta para receber um segundo provedor sem alterar o motor. Não inseriu texto jurídico real em `modelos_contrato` — só um esqueleto explicitamente marcado como placeholder, porque o texto oficial precisa vir do jurídico da NICK. Não validou Storage real do Supabase ponta-a-ponta (schema ausente no Postgres local) — o bucket e as políticas RLS estão prontos em `supabase/storage_setup_fase25.sql`, fora da cadeia de migrations de propósito, para rodar manualmente contra um projeto real. Nenhuma migration de fase anterior foi editada, nenhuma tabela recriada, nenhum dado existente apagado. Checklist de aceite completo (28 itens, 28/28 PASS) em `docs/RELATORIO_FASE25.md`.

## 24. Fase 2.5.1 — Correção, Completude, UX, Usuários, Proponentes, Assinaturas, Contratos, Configuração e Manuais

Fase de correção e fechamento, não de expansão de escopo: nenhuma tabela nova, nenhum fluxo de negócio novo — o objetivo era corrigir um bug crítico relatado pelo usuário, expor no frontend o que a Fase 2.5 já tinha pronto só no backend, e validar de ponta a ponta o que a Fase 2.5 tinha marcado como pronto mas nunca exercitado com teste funcional real. **2 migrations novas** (prefixo `20260920`), ambas aditivas. Relatório completo (17 itens do checklist do prompt-mestre) em `docs/RELATORIO_FASE251.md`; este bloco cobre só as decisões de arquitetura que valem registrar aqui.

### 24.1 A exceção de `service_role`, escopada ao mínimo: Auth Admin API só para identidade

O bug relatado pelo usuário ("preciso digitar um UUID para criar usuário") existia porque a Fase 2.5 desenhou `public.usuarios` e sua RLS completa, mas nunca desenhou *quem cria a identidade em `auth.users`* — e RLS não alcança essa pergunta, porque RLS governa tabelas do Postgres, nunca o schema interno do GoTrue. A única API que cria/gerencia identidades de autenticação é a Supabase Auth Admin API, que exige `service_role`. Isso forçou a primeira exceção deliberada, nesta arquitetura, à regra "nunca `service_role` no backend" — e a exceção foi desenhada para ser a menor possível: `api/lib/supabaseAdmin.js` expõe *só* `client.auth.admin` (nunca um client genérico de acesso a tabelas, que poderia contornar RLS em qualquer lugar do sistema), a chave nunca aparece em nenhum outro arquivo do backend, nunca tem prefixo `VITE_` (logo é estruturalmente impossível de vazar para o bundle do frontend, verificado por varredura real do artefato construído, não só por inspeção de código), e cada rota que a usa confirma primeiro, em Node — porque é a única camada capaz de checar isso — que quem chamou é `ADMINISTRADOR` e está `ativo`. Quando a variável não está configurada, toda rota dependente falha de forma controlada e explícita (`501 SERVICE_ROLE_NAO_CONFIGURADO`) em vez de um erro genérico ou de um comportamento inventado — essa é a mesma filosofia de "graceful degradation, nunca gambiarra silenciosa" já usada para a limitação de Storage desde a Fase 2.5.

### 24.2 `supabase.rpc(...).catch()` não existe — um bug de biblioteca, não de lógica

Um bug real (não presente antes desta fase) apareceu em 6 pontos do código novo, todos com o mesmo formato: `await supabase.rpc('pricing_log_semantic_event', {...}).catch(() => {})`, escrito para tornar o log de auditoria semântica best-effort (nunca travar a ação principal se o log falhar). O `@supabase/supabase-js` devolve, para `.rpc()` (e para qualquer builder de query), um objeto "thenable" — implementa só `.then()`, o mínimo exigido por `await`, mas não implementa `.catch()` nem `.finally()`, porque não é uma `Promise` real. Encadear `.catch()` direto nesse retorno lança `TypeError: ...catch is not a function` — e como isso acontece *depois* da ação principal já ter tido sucesso (a UPDATE em `usuarios`/`parceiros` já tinha sido commitada), o efeito era pior do que simplesmente não logar: a rota inteira caía com 500 mesmo tendo funcionado. Encontrado pelos próprios testes novos desta fase (`TESTE-U06`, `P05`, `P06`, `TESTE-conexão`), nunca por inspeção de código. Corrigido substituindo os 6 pontos por um helper `logSemanticEventBestEffort(supabase, params)` — `await` dentro de um `try/catch` real, o único jeito correto de tratar erro de um thenable que não é uma Promise completa.

### 24.3 Por que um Node route file compartilhado é um risco de regressão silenciosa

O segundo bug real desta fase (a extensão de `GET /api/audit` para aceitar `entidade_id`) reforça um padrão arquitetural já registrado na Fase 2.5.1: arquivos de rota Node **não são versionados por fase** — a única versão de `api/routes/*.js` existente roda contra *todo* estado de banco da cadeia de regressão, inclusive estados anteriores à migration que uma mudança recente assume que já existe. Enviar sempre `p_entidade_id` (mesmo como `null`) fazia o PostgREST tentar resolver a função pelo conjunto completo de 4 parâmetros nomeados — e falhar contra qualquer banco anterior à migration `20260920090100`, porque a resolução de função do PostgREST é por assinatura exata de nomes recebidos, não por "parâmetros extras com default são ignorados". A correção (só incluir a chave quando o caller pede) é o mesmo padrão já usado em `cities.js` (`POST /:id/archive`) desde a Fase 2.3.1 — mantido como convenção do projeto sempre que um Node route file ganha um parâmetro novo em uma função SQL que só existe a partir de uma migration específica.

### 24.4 Bateria de testes desta fase

`tests/run_tests_fase251.sh` — **25 de 25 verificações passando, 0 falhas, 7 SKIP documentados** (mesma categoria de limitação de ambiente já aceita desde a Fase 2.5: sem GoTrue real e sem schema `storage` no Postgres local), reexecutando `tests/run_tests_fase25.sh` **original, sem editar**, como PASSO-0 — que por sua vez encadeia toda a cadeia Fase 1 → 2.5 (incluindo `run_tests_deploy.sh` no fundo da cadeia) — **46 PASS / 0 FAIL / 3 SKIP, sem nenhuma regressão nova**. Os 3 bugs reais encontrados durante a própria validação desta fase — o `.rpc().catch()` inexistente (seção 24.2), a regressão de `p_entidade_id` em `audit.js` (seção 24.3), e um corpo de requisição incompleto no próprio script de teste (`TESTE-S01a/S01b`, que fazia a validação de entrada em Node responder antes da RLS, mascarando o que o teste deveria provar) — estão detalhados em `docs/RELATORIO_FASE251.md`, seção 1.

### 24.5 O que esta fase deliberadamente NÃO fez

Não iniciou a Fase 3. Não alterou nenhuma regra de negócio de proposta, contrato, aditivo ou motor de assinatura — só expôs no frontend o que já existia no backend e corrigiu os 3 bugs reais encontrados. Não integrou um segundo provedor de assinatura de produção. Não validou o recebimento real de e-mail de convite nem a definição de senha pelo link (exige GoTrue real de um projeto Supabase de verdade — o código foi validado para nunca crashar e nunca inventar um envio que não aconteceu, mas o e-mail em si não pôde ser recebido neste ambiente local). Nenhuma migration de fase anterior foi editada, nenhuma tabela recriada, nenhum dado existente apagado, nenhuma tabela duplicada. Relatório completo (17 itens do checklist do prompt-mestre) em `docs/RELATORIO_FASE251.md`.

### 24.6 Addendum — o convite real expôs um gap que o ambiente local não conseguia testar

A limitação de ambiente admitida na seção 24.5 ("não validou o recebimento real de e-mail de convite") deixou de ser hipotética assim que o usuário testou contra um projeto Supabase real: o e-mail chegou, o link autenticou (token válido, `type=invite`), e a navegação terminava numa tela sem sentido. Dois problemas reais, nenhum deles visível num Postgres+PostgREST local sem GoTrue: (1) `frontendRedirectUrl()` escolhia sempre a *primeira* origem de `CORS_ALLOWED_ORIGINS` como base do link — e essa lista quase sempre tem `localhost` primeiro, por ser o próprio padrão de `.env.example` pensado para desenvolvimento; (2) mesmo com a URL certa, nunca existiu uma página no frontend para receber o retorno do Supabase Auth (`#access_token=...&type=invite`) e deixar a pessoa definir a senha — o "fluxo de convite" da Fase 2.5.1 original só cobria a metade do backend (criar a identidade, disparar o e-mail), nunca a metade do frontend que fecha o ciclo. Corrigido com uma variável de ambiente explícita (`PUBLIC_APP_URL`) para o primeiro problema e a página nova `web/src/pages/DefinirSenha.jsx` (rota `/definir-senha`, fora de `ProtectedRoute`) para o segundo, mais um teste de regressão (`TESTE-redirect`) que exercita a função de verdade para este bug específico nunca mais escapar despercebido.

Mesmo depois dessa correção implantada, o mesmo sintoma (link novo, ainda em `localhost:3000`) voltou a acontecer — e dessa vez a causa raiz não estava em nenhum arquivo deste repositório: é um comportamento do próprio Supabase Auth. `inviteUserByEmail`/`resetPasswordForEmail` só respeitam o `redirectTo` enviado pela API se essa URL estiver na lista de permitidos do projeto (Authentication → URL Configuration → Redirect URLs, no painel do Supabase); se não estiver, o Supabase ignora silenciosamente o valor pedido e usa a "Site URL" configurada no painel, que é `http://localhost:3000` por padrão em todo projeto novo — sem nenhum aviso de que o `redirectTo` foi rejeitado. Nenhum código deste projeto tem como detectar ou contornar isso a partir do backend: é configuração exclusiva do painel do Supabase, documentada agora como passo obrigatório no runbook (Addendum 2 de `docs/RELATORIO_FASE251.md`).
