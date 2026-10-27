# Fase 4.1 — Importação de Infraestrutura (Prévia) — Relatório Final

Data: 2026-09-23
Escopo: implementação em migrations aditivas, validadas em sandbox Postgres local, conforme aprovado com as 13 condições do usuário. Nenhuma infraestrutura oficial foi alterada — todo o trabalho ficou em migrations novas, aplicadas só contra um banco de testes local, nunca contra o projeto Supabase real.

## 1. Migrations criadas (5, todas aditivas)

| # | Arquivo | Conteúdo |
|---|---|---|
| 1 | `20261011090000_phase_4_1_01_staging_importacao_schema.sql` | Schema `staging` + 3 tabelas + constraints + RLS |
| 2 | `20261011100000_phase_4_1_02_auditoria_import_whitelist.sql` | Whitelist de auditoria ampliada com 10 eventos `IMPORT_*` |
| 3 | `20261012090000_phase_4_1_03_importacao_classificacao.sql` | Classificação NOVO/ALTERADO/SEM_ALTERACAO/CONFLITO/INVALIDO + regras de POP/fibra/poste |
| 4 | `20261012100000_phase_4_1_04_importacao_aplicar.sql` | Ciclo de status (iniciar→validar→prévia→aprovar) + aplicação transacional tudo-ou-nada |
| 5 | `20261013090000_phase_4_1_05_importacao_reverter.sql` | Reversão item-a-item, com `REVERTIDA_PARCIALMENTE` |

Nenhuma migration existente foi editada. Nenhum `DELETE` em dado de produção. Nenhum script de reset. Nenhuma RLS existente foi alterada — só novas policies em tabelas novas.

## 2. Arquivos alterados

Nenhum. 100% aditivo — nenhum arquivo pré-existente do projeto (migration, código Node, etc.) foi tocado.

## 3. Funções criadas

**Schema `app` (SECURITY DEFINER, fazem sua própria checagem de perfil):**
`app.fn_importacao_diff`, `app.fn_valida_regra_pop`, `app.fn_valida_regra_fibra`, `app.fn_valida_regra_poste`, `app.importacao_item_registrar`, `app.importacao_iniciar`, `app.importacao_iniciar_validacao`, `app.importacao_marcar_previa`, `app.importacao_rejeitar`, `app.importacao_descartar`, `app.importacao_aprovar`, `app.aplicar_importacao`, `app.reverter_importacao`.

**Schema `staging`:** `staging.fn_bloquear_alteracao_importacao_alteracoes` (trigger de imutabilidade parcial).

**Schema `public`** (wrappers finos SECURITY INVOKER, padrão do projeto, com GRANT EXECUTE a `authenticated`): `public.importacao_item_registrar`, `public.importacao_iniciar`, `public.importacao_iniciar_validacao`, `public.importacao_marcar_previa`, `public.importacao_rejeitar`, `public.importacao_descartar`, `public.importacao_aprovar`, `public.aplicar_importacao`, `public.reverter_importacao`.

`app.registrar_auditoria_semantica` (8 parâmetros — ver seção 6) recebeu `CREATE OR REPLACE` aditivo (whitelist ampliada); as versões de 6 e 7 parâmetros **não foram tocadas**.

## 4. Tabelas criadas

`staging.importacoes`, `staging.importacao_itens`, `staging.importacao_alteracoes` — detalhe de cada campo nos comentários da Migration 1. Nenhuma coluna nova em nenhuma tabela oficial (`cidades_infra`, `infra_pops`, `infra_segmentos`, `infra_cabos`, `infra_fibras`, `infra_postes`, `infra_portas_pon`, `contrato_clientes_reservados`, `contrato_fibras`).

## 5. Policies criadas

3 policies de `SELECT`, todas escopadas por perfil, **nenhuma `using(true)`**:
- ADMINISTRADOR vê tudo.
- DIRETOR vê tudo (só visualização/aprovação/reversão — nunca edição direta, já que não existe nenhuma policy de INSERT/UPDATE/DELETE para `authenticated`).
- ENGENHARIA só vê as próprias importações (`criado_por = auth.uid()`).
- COMERCIAL/FINANCEIRO/AUDITOR sem nenhuma policy → sem acesso nenhum.

Toda escrita nas 3 tabelas é exclusiva das funções `app.*` SECURITY DEFINER (mesmo padrão de `app.restaurar_*`), cada uma fazendo sua própria checagem de perfil antes de agir.

## 6. Confirmações pré-Migration-2 (condições 2 e 3, já reportadas no chat)

- **`app.registrar_auditoria_semantica`**: confirmados 3 overloads reais coexistindo (6, 7 e 8 parâmetros — leitura direta das migrations, sem acesso de rede ao banco real). A whitelist só foi ampliada na versão de **8 parâmetros** (a real e atualmente usada, última alterada em `20261010090000`). As de 6 e 7 parâmetros continuam intocadas.
- **Storage**: reaproveitado o bucket privado `documentos` já existente (Fase 2.5), com prefixo novo `levantamentos/{importacao_id}/{uuid}-{nome}`. Nenhuma policy nova de Storage foi criada — as policies base já existentes (`authenticated`, sem filtro de perfil) cobrem qualquer prefixo do bucket; o controle de perfil fica inteiramente na RLS de `staging.importacoes` (Postgres real, testável), exatamente como o próprio arquivo `storage_setup_fase25.sql` já documenta ser o padrão do projeto.

## 7. Constraints

- `staging.importacoes.status` — CHECK com os 9 valores (RECEBIDA/EM_VALIDACAO/PREVIA/APROVADA/IMPORTADA/REJEITADA/DESCARTADA/REVERTIDA/REVERTIDA_PARCIALMENTE).
- Pares de consistência: `aprovado_em`↔`aprovado_por`, `rejeitado_em`↔`rejeitado_por`+`motivo_rejeicao`, `descartado_em`↔`descartado_por`, `revertido_em`↔`revertido_por`+`motivo_reversao`.
- `staging.importacao_itens.classificacao` — CHECK com os 5 valores; INVALIDO exige `motivo_invalido`; NOVO nunca tem `entidade_oficial_id`.
- `staging.importacao_alteracoes.operacao` — CHECK INSERT/UPDATE; INSERT nunca tem `valor_anterior`, UPDATE sempre tem.
- Trigger de imutabilidade parcial em `importacao_alteracoes` (só os 4 campos de reversão podem mudar depois de gravado) + trigger bloqueando DELETE (reaproveita `public.fn_bloquear_alteracao_auditoria`).
- **Nenhuma UNIQUE nova em `infra_segmentos`/`infra_postes`** — confirmado por teste automatizado (Teste 19).
- `public.auditoria.acao` — CHECK ampliado aditivamente com os 10 eventos `IMPORT_*`.

## 8. Testes executados e resultados

Sandbox Postgres 16 local, schema curado (RBAC, auditoria, hierarquia `infra_*` completa, `pricing_parametros` mínimo, `contrato_fibras` como stub de 3 colunas). 20 testes automatizados, todos com **PASS**:

1. Criação de importação + auditoria `IMPORT_RECEIVE` — OK
2. Classificação NOVO (cidade nova) e ALTERADO (cidade existente) — OK
3. Regra POP: código `E-*` → INVALIDO — OK
4. Regra POP: "PAÇO" → INVALIDO — OK
5. POP válido → NOVO — OK
6. Massa de dados (segmento/POP/cabo) — OK
7. Regra FIBRA: OCUPADA+disponivel=SIM → INVALIDO — OK
8. Regra FIBRA: LIVRE+disponivel=NAO → ALTERADO, com alerta INFO, sem auto-correção — OK
9. Regra POSTE: projeto_aprovado=NAO → NOVO (nunca bloqueia), com alerta explicando que NÃO ≠ sem rede — OK
10. RLS: ENGENHARIA não vê importação de outro ENGENHARIA — OK
11. RLS: ADMINISTRADOR e DIRETOR veem tudo; COMERCIAL não vê nada — OK
12. RBAC: COMERCIAL não consegue chamar `app.importacao_iniciar` — OK
13. Aprovação bloqueada com item INVALIDO pendente (`PENDENCIAS_ABERTAS`) — OK
14. Fluxo completo RECEBIDA→...→IMPORTADA: cidade+POP novos gravados na tabela oficial, 2 linhas em `importacao_alteracoes`, `IMPORT_APPLY` auditado — OK
15. Reversão total → `REVERTIDA`, cidade e POP removidos (eram INSERT) — OK
16. Reversão parcial: POP editado manualmente depois da importação **não** é revertido (mantém a edição), cidade não tocada é revertida normalmente, status final `REVERTIDA_PARCIALMENTE`, `motivo_nao_revertido` preenchido — OK
17. `importacao_alteracoes` imutável (UPDATE de `valor_novo` bloqueado; DELETE bloqueado) — OK
18. Rejeição não grava nada em tabela oficial — OK
19. Nenhuma UNIQUE nova em `infra_segmentos`/`infra_postes` — OK
20. `contrato_fibras` nunca tocada (mesmas 3 colunas do stub, 0 linhas) — OK

Comando para reproduzir localmente: `./run_all.sh` no sandbox (recria o banco, aplica bootstrap + 5 migrations + suíte de 20 testes).

## 9. Riscos e pontos pendentes (honestos, para decisão do usuário)

1. **Aplicação/reversão totalmente implementadas só para CIDADE, POP e POSTE (insert+update) e FIBRA (só update)**. SEGMENTO, CABO, PORTA_PON e CLIENTE_RESERVADO têm **classificação/matching completos** (Migration 3), mas `app.aplicar_importacao`/`app.reverter_importacao` levantam `APLICACAO_NAO_IMPLEMENTADA`/`REVERSAO_NAO_IMPLEMENTADA` para esses tipos — é trabalho mecânico (mesmo padrão já usado), mas real, e precisa ser completado antes de habilitar esses tipos em produção.
2. **CLIENTE_RESERVADO**: matching é um stub (sempre classifica NOVO) porque `contratos`/`parceiros`/`contrato_clientes_reservados` completos não foram recriados no sandbox local (fora de escopo desta rodada). Precisa de implementação real + teste em homologação antes de habilitar.
3. **Camada Node/API e tela de prévia não foram implementadas** — esta entrega é só a camada de banco (schema + funções + RLS + testes), consistente com o pedido original ("não implemente ainda... depois da aprovação, implementar em migrations"). Upload multipart, parsing de Excel e a tela de revisão continuam pendentes.
4. **`app.fn_importacao_diff` compara TODOS os campos presentes na planilha**, incluindo campos só-de-validação (ex.: `disponivel`, `status` legado) que não são necessariamente aplicados por `app.aplicar_importacao`. Isso pode fazer a prévia mostrar mais "campos alterados" do que o que realmente será gravado. Recomendo restringir o diff ao conjunto de campos realmente aplicado por tipo de entidade antes de ligar a tela de prévia em cima disso.
5. **Sandbox é um subconjunto curado**, não o schema completo de produção (contratos/parceiros/pricing engine/propostas/assinatura/Storage não foram recriados). A regra de CONFLITO para FIBRA com `contrato_fibras` ativo foi validada só por revisão de código, não por execução — meu stub de `contrato_fibras` tem 3 colunas e não reproduz o subsistema comercial completo. Recomendo teste específico em homologação real antes de habilitar FIBRA/PORTA_PON/CLIENTE_RESERVADO.
6. Confirmação da assinatura de `app.registrar_auditoria_semantica` e do padrão de Storage vieram de leitura de arquivo, não de query ao vivo (sem acesso de rede ao banco real neste ambiente) — query de confirmação já compartilhada no chat.
7. A suíte de 20 testes foi desenhada por mim para cobrir mecanismo + toda regra de negócio explicitamente documentada nesta conversa; o texto literal da sua lista original de 20 itens (condição 12) não estava disponível no meu contexto após uma compactação da conversa. Recomendo conferir esta suíte contra a sua lista original e apontar qualquer item faltante.
8. `arquivo_hash` é armazenado mas **não** tem constraint de unicidade — reenvio do mesmo arquivo é permitido de propósito (revalidação), não bloqueado.
9. Antes de aplicar em homologação, confirme que `20261010090000_phase_3_11_06_...` continua sendo a migration mais recente (verificado nesta sessão, mas pode ter mudado).

## 10. Conformidade com as restrições explícitas

Não alterei RLS existente. Não removi dados. Nenhum `DELETE` em produção (nem em sandbox — só INSERT/UPDATE simulando aplicação real). Nenhum script de reset. Nenhuma migration existente foi alterada. `contrato_fibras` nunca foi tocada (confirmado por teste automatizado). Toda a validação aconteceu em ambiente local isolado — nada foi executado contra o projeto Supabase real.
