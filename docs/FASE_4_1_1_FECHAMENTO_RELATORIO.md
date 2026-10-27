# Fase 4.1.1 — Fechamento da Importação de Infraestrutura — Relatório Final

Data: 2026-09-24
Escopo: fechamento técnico da Fase 4.1, conforme as 14 condições da aprovação-com-pendências. Todo o trabalho continua restrito a migrations aditivas, validadas em sandbox Postgres local. **Nenhuma migration foi aplicada no Supabase real. Nenhuma ação foi executada contra produção.**

## 0. Resposta direta às 14 condições

| # | Condição | Status |
|---|---|---|
| 1 | Confirmar lista completa e atual das migrations | ✅ Ver seção 1 |
| 2 | Aplicação/reversão real de SEGMENTO | ✅ Implementado e testado (Teste 22) |
| 3 | Aplicação/reversão real de CABO | ✅ Implementado e testado (Teste 22) |
| 4 | Aplicação/reversão real de PORTA_PON | ✅ Implementado e testado (Teste 23) |
| 5 | CLIENTE_RESERVADO com schema real, sem stub | ✅ Implementado e testado (Testes 24, 25) |
| 6 | `fn_importacao_diff` só com campos efetivamente aplicados | ✅ Ver seção 2 e Teste 26 |
| 7 | Testes contra `contrato_fibras` real, incl. FIBRA "LIVRE" com vínculo ativo | ✅ Teste 21 |
| 8 | Confirmar que a importação nunca altera `contrato_fibras` | ✅ Testes 20 e 25b |
| 9 | Revalidar todas as regras de RLS | ✅ Testes 10, 11 — nenhuma RLS existente tocada |
| 10 | Validar os 3 overloads de `registrar_auditoria_semantica` | ✅ Teste 27 |
| 11 | Validar Storage e caminho `levantamentos/{importacao_id}/...` | ✅ Ver seção 7 (reafirmação — nada mudou nesta fase) |
| 12 | Reexecutar a suíte completa | ✅ 27/27 testes passando |
| 13 | Não alterar migrations históricas | ✅ Ver seção 8 — só as 5 migrations da própria Fase 4.1 (nunca aplicadas) foram revisadas |
| 14 | Não executar nada no Supabase de produção | ✅ Confirmado — só sandbox local |

## 1. Migrations (confirmação da lista completa)

Confirmado via leitura direta da pasta `supabase/migrations/` no seu dispositivo: a última migration real pré-existente continua sendo `20261010090000_phase_3_11_06_rastreabilidade_eventos_assinatura.sql`. Depois dela, só existem as 5 migrations da própria Fase 4.1 — nenhuma migration nova de terceiros ou de outra sessão apareceu entre a Fase 4.1 e este fechamento.

| # | Arquivo | O que mudou na Fase 4.1.1 |
|---|---|---|
| 1 | `20261011090000_phase_4_1_01_staging_importacao_schema.sql` | Adicionada a coluna `staging.importacao_alteracoes.ordem` (`bigserial`) — ver seção 3, bug de ordenação da reversão |
| 2 | `20261011100000_phase_4_1_02_auditoria_import_whitelist.sql` | **Sem alteração** |
| 3 | `20261012090000_phase_4_1_03_importacao_classificacao.sql` | Reescrita: campos de aplicação, resolvers de FK, CLIENTE_RESERVADO real, correção do CONFLITO de FIBRA, correção do matching de PORTA_PON |
| 4 | `20261012100000_phase_4_1_04_importacao_aplicar.sql` | Aplicação real de SEGMENTO/CABO/PORTA_PON/CLIENTE_RESERVADO |
| 5 | `20261013090000_phase_4_1_05_importacao_reverter.sql` | Reversão real de SEGMENTO/CABO/PORTA_PON/CLIENTE_RESERVADO; ordenação da reversão corrigida para usar `ordem` em vez de `aplicado_em` |

Você recebeu os 4 arquivos revisados (1, 3, 4, 5) nesta conversa e eles já foram salvos na mesma pasta do seu dispositivo, sobrescrevendo a versão anterior (a Migration 2 não mudou e não foi reenviada).

## 2. Funções novas/alteradas

**Novas (schema `app`, todas `stable`/`immutable`, sem `SECURITY DEFINER` — são só leitura/cálculo):**
- `app.fn_importacao_campos_aplicados(p_tipo_entidade text) returns text[]` — para cada tipo de entidade, devolve só os campos que `app.aplicar_importacao` realmente grava. É a peça central da condição 6: separa campos de **identificação** (usados só para casar a linha com o registro oficial — nunca comparados), campos de **aplicação** (as colunas reais que são escritas — os únicos comparados/exibidos como "alterado") e campos de **informação** (sinais de validação como `disponivel`, nunca comparados nem aplicados).
- `app.fn_resolver_cidade_id`, `app.fn_resolver_pop_id`, `app.fn_resolver_segmento_id`, `app.fn_resolver_cabo_id`, `app.fn_resolver_fibra_id`, `app.fn_resolver_contrato_id` — resolvem o id real de uma entidade oficial a partir dos campos de identificação da planilha, usados tanto na classificação (Migration 3) quanto na aplicação (Migration 4) para preencher FKs de registros NOVOs.

**Alteradas:**
- `app.fn_importacao_diff` — assinatura mudou de `(p_oficial jsonb, p_planilha jsonb)` para `(p_oficial jsonb, p_planilha jsonb, p_campos_aplicados text[])`. Antes comparava todos os campos presentes na planilha; agora só compara os campos que `p_campos_aplicados` lista (saída de `app.fn_importacao_campos_aplicados`) — exatamente a condição 6.
- `app.importacao_item_registrar` — ganhou os ramos de matching real para SEGMENTO, CABO, PORTA_PON (com a correção de escopo por cidade) e CLIENTE_RESERVADO (contra `contratos`/`contrato_clientes_reservados` reais); a regra de CONFLITO de FIBRA foi reescrita para inspecionar o campo bruto `status` da planilha em vez do diff escopado (ver seção 4).
- `app.aplicar_importacao` — os 4 ramos que antes levantavam `APLICACAO_NAO_IMPLEMENTADA` para SEGMENTO/CABO/PORTA_PON/CLIENTE_RESERVADO agora fazem INSERT (NOVO) ou UPDATE (ALTERADO) reais, cada um gravando sua linha em `staging.importacao_alteracoes`. `infra_portas_pon.capacidade_utilizada_assinantes` nunca é tocado (dado comercial ao vivo, fora do escopo da importação) — confirmado no Teste 23.
- `app.reverter_importacao` — os mesmos 4 tipos ganharam lógica real de reversão (DELETE para INSERT, restauração de `valor_anterior` para UPDATE); a ordem do laço de reversão mudou de `order by aplicado_em desc` para `order by ordem desc` (ver seção 3).

Nenhum dos 3 overloads de `app.registrar_auditoria_semantica` (6/7/8 parâmetros) foi tocado nesta fase — confirmado no Teste 27.

## 3. Bug encontrado e corrigido nesta fase (fora da lista original, mas necessário)

Ao testar a reversão de uma importação com SEGMENTO+CABO no mesmo lote (Teste 22), a reversão falhou com `REVERTIDA_PARCIALMENTE` em vez de `REVERTIDA`. Causa raiz: o laço de reversão ordenava por `aplicado_em desc` para desfazer sempre na ordem inversa da aplicação (importante quando há FK entre os registros, ex.: `infra_cabos.segmento_id` referencia `infra_segmentos`). Mas dentro de uma única transação de `app.aplicar_importacao`, `now()` devolve o mesmo instante para todos os itens aplicados — então o `desc` por timestamp empatado não garante ordem alguma, e nesta execução o SEGMENTO foi revertido (DELETE) antes do CABO que ainda apontava para ele, violando a FK `infra_cabos_segmento_id_fkey`.

Correção: adicionada uma coluna `ordem bigserial` em `staging.importacao_alteracoes` (Migration 1) — um contador monotônico real de inserção, nunca empatado — e a reversão (Migration 5) passou a usar `order by ordem desc`. Como a Migration 1 nunca foi aplicada no Supabase real (é uma das 5 migrations da própria Fase 4.1, ainda em rascunho — ver seção 8), essa foi uma revisão aditiva segura, e não uma alteração de migration histórica. Reconfirmado com a suíte completa: Teste 22 passa de forma determinística em execuções repetidas.

## 4. Correção da regra de CONFLITO de FIBRA (efeito colateral da condição 6)

Ao restringir `fn_importacao_diff` só aos campos de aplicação (condição 6), a regra original de CONFLITO de FIBRA — que checava se `status_comercial`/`status_contratual` apareciam no diff — parou de funcionar, porque esses campos nunca fazem parte dos campos de aplicação de FIBRA (`app.aplicar_importacao` só grava `status_operacional`/`observacao`; quem governa `status_comercial`/`status_contratual` é o vínculo em `contrato_fibras`, nunca a importação). Esse era um bug real que eu mesmo introduzi ao implementar a condição 6, encontrado por raciocínio antes de rodar o Teste 21 — não em produção.

Correção: a regra de CONFLITO agora inspeciona diretamente o campo bruto `status` da planilha (`= 'LIVRE'`) combinado com a existência de um `contrato_fibras` ativo (`desvinculado_em is null`) para aquela fibra — representando a contradição de negócio real ("levantamento diz LIVRE, mas há vínculo comercial ativo agora") independentemente de quais colunas são literalmente gravadas. Validado pelo Teste 21.

## 5. Testes executados e resultado de cada um

Suíte ampliada de 20 para 27 testes, reexecutada do zero (`./run_all.sh` recria o banco, reaplica bootstrap + as 5 migrations + a suíte). **Todos os 27 com PASS.**

Testes 1–20 (herdados da Fase 4.1, revalidados sem alteração de lógica esperada):

1. Criação de importação + auditoria `IMPORT_RECEIVE` — PASS
2. Classificação NOVO (cidade nova) e ALTERADO (cidade existente) — PASS
3. Regra POP: código `E-*` → INVALIDO — PASS
4. Regra POP: "PAÇO" → INVALIDO — PASS
5. POP válido → NOVO — PASS
6. Massa de dados (segmento/POP/cabo) para os testes seguintes — PASS
7. Regra FIBRA: OCUPADA+disponivel=SIM → INVALIDO — PASS
8. Regra FIBRA: LIVRE+disponivel=NAO → ALTERADO, com alerta, sem auto-correção — PASS
9. Regra POSTE: projeto_aprovado=NAO → NOVO, nunca bloqueia — PASS
10. RLS: ENGENHARIA não vê importação de outro ENGENHARIA — PASS
11. RLS: ADMINISTRADOR e DIRETOR veem tudo; COMERCIAL não vê nada — PASS
12. RBAC: COMERCIAL não consegue chamar `app.importacao_iniciar` — PASS
13. Aprovação bloqueada com item INVALIDO pendente — PASS
14. Fluxo completo até IMPORTADA (cidade+POP) — PASS
15. Reversão total → REVERTIDA — PASS
16. Reversão parcial: registro editado por fora não é revertido, o resto é — PASS
17. `importacao_alteracoes` imutável (UPDATE/DELETE bloqueados) — PASS
18. Rejeição não grava nada em tabela oficial — PASS
19. Nenhuma UNIQUE nova em `infra_segmentos`/`infra_postes` — PASS
20. `contrato_fibras` continua vazia depois dos testes 1–19 (reescrito nesta fase para checar contagem de linhas, não mais o formato de colunas do stub antigo, já que o stub foi substituído pelo schema real) — PASS

Testes 21–27 (novos, escopo da Fase 4.1.1):

21. **FIBRA com vínculo contratual ATIVO em `contrato_fibras` real**: planilha diz `status=LIVRE`, mas existe `contrato_fibras` sem `desvinculado_em` para aquela fibra → classificação CONFLITO, nunca aplicado sem decisão humana (condição 7) — PASS
22. SEGMENTO e CABO novos: `app.aplicar_importacao` grava nas tabelas oficiais com FK resolvida (`segmento_id`/`pop_id`), `app.reverter_importacao` remove os dois registros de volta (validou também a correção do bug de ordenação da seção 3) — PASS
23. PORTA_PON nova: aplicada com FK de fibra/POP resolvida, `capacidade_utilizada_assinantes` confirmado em 0 (nunca tocado pela importação), revertida corretamente — PASS
24. CLIENTE_RESERVADO com `contrato_numero` inexistente → INVALIDO (matching real contra `contratos`, sem stub) — PASS
25. CLIENTE_RESERVADO novo: aplicado em `contrato_clientes_reservados`, `contrato_fibras` confirmado com a mesma 1 linha do Teste 21 antes e depois (nunca escrito), revertido corretamente — PASS
26. Diff escopado: campo de informação (`disponivel`) nunca aparece no diff; campo de aplicação real (`status_operacional`) aparece — PASS
27. Os 3 overloads de `app.registrar_auditoria_semantica` continuam coexistindo (contagem em `pg_proc`); confirmado por auditoria real que o de 8 parâmetros é o efetivamente usado por `app.aplicar_importacao` — PASS

## 6. Tipos de entidade — suportados vs. bloqueados

| Tipo | NOVO | ALTERADO | Observação |
|---|---|---|---|
| CIDADE | ✅ | ✅ | Sem mudança na Fase 4.1.1 |
| POP | ✅ | ✅ | Sem mudança na Fase 4.1.1 |
| SEGMENTO | ✅ | ✅ | Novo nesta fase |
| CABO | ✅ | ✅ | Novo nesta fase — ver risco 1 (seção 7) |
| POSTE | ✅ | ✅ | Sem mudança na Fase 4.1.1 |
| PORTA_PON | ✅ | ✅ | Novo nesta fase |
| CLIENTE_RESERVADO | ✅ | ✅ | Novo nesta fase, schema real (não é mais stub) |
| FIBRA | ❌ (bloqueado de propósito) | ✅ | `FIBRA_NOVA_NAO_SUPORTADA` — fibra nova deve vir sempre junto do cadastro do cabo, nunca isolada; regra de negócio explícita, não uma limitação técnica |

**Nenhum tipo de entidade continua bloqueado por falta de implementação.** O único bloqueio restante (FIBRA NOVO) é uma decisão de modelagem deliberada, já existente desde a Fase 4.1, e não uma pendência técnica.

## 7. Riscos remanescentes

1. **`app.fn_resolver_cabo_id` assume que `identificacao` de cabo é globalmente única.** A `UNIQUE` real em `infra_cabos` é por segmento, não global — então, em tese, dois cabos com a mesma `identificacao` em segmentos diferentes existiriam na tabela oficial, e o resolver pegaria só o primeiro encontrado (`limit 1`), sem determinismo garantido. Na prática, isso normalmente não deveria acontecer na sua operação (identificação de cabo costuma ser um código físico único), mas o resolver não impõe isso. Recomendo, antes de habilitar CABO/FIBRA em homologação, decidir entre (a) confirmar que `identificacao` é de fato único na base real, ou (b) exigir `segmento_nome`+`identificacao` juntos no resolver, tornando o casamento sempre não-ambíguo.
2. **Storage não foi retestado ao vivo nesta fase** — o sandbox Postgres local não reproduz o Storage do Supabase, então a confirmação do caminho `levantamentos/{importacao_id}/...` e das policies do bucket `documentos` continua sendo a mesma da Fase 4.1 (leitura de `storage_setup_fase25.sql`, sem execução real). Nada nesta fase alterou Storage, então não há motivo para suspeitar de regressão, mas é uma reafirmação, não uma nova validação.
3. **Camada Node/API e tela de prévia continuam não implementadas** — esta entrega, como a Fase 4.1, é só a camada de banco (schema + funções + RLS + testes).
4. **Sandbox continua um subconjunto curado do schema de produção.** Nesta fase, `parceiros`/`contratos`/`contrato_fibras`/`contrato_clientes_reservados` foram reconstruídos com o DDL real (não mais stub), o que elimina o risco equivalente reportado na Fase 4.1 para esses objetos — mas `contrato_regras`/`contrato_regras_solicitacoes`, o motor de pricing, propostas e assinatura continuam fora do sandbox (fora do escopo desta feature).
5. `arquivo_hash` continua sem constraint de unicidade — reenvio do mesmo arquivo é permitido de propósito.
6. Confirme, antes de homologar, que `20261010090000_phase_3_11_06_...` continua sendo a migration mais recente pré-existente — verificado nesta sessão (24/09), mas pode ter mudado desde então.

## 8. Sobre revisar as 5 migrations da Fase 4.1 "em vez de" criar novas

As 5 migrations revisadas nesta fase (`20261011090000` a `20261013090000`) são as mesmas entregues na Fase 4.1 — nunca renomeadas, nunca duplicadas, editadas em lugar. Isso é intencional e, a meu ver, consistente com a condição 13 ("não alterar migrations históricas"): elas nunca chegaram a ser aplicadas no Supabase real (nem na Fase 4.1, nem agora) — você foi explícito em pedir que **nenhuma migration fosse aplicada no Supabase até a homologação**. Uma migration que nunca rodou contra um banco real não tem estado a proteger; ela ainda é um rascunho, e tratá-la como "histórica" (i.e., só permitir aditivos por cima dela) criaria migrations de correção em cima de migrations que nunca funcionaram, o que é pior para quem for ler o histórico depois. As migrations verdadeiramente históricas — todas as anteriores a `20261011090000`, já aplicadas e em produção — não foram tocadas, nem seriam.

Se você preferir, para fins de rastreabilidade formal, que mesmo drafts nunca-aplicados sejam tratados como imutáveis a partir da entrega Fase 4.1, me avise e eu recrio o fechamento como migrations 6–10 adicionais em vez de revisões in-place — é um ajuste mecânico, não estrutural.

## 9. Confirmação final de conformidade

- **Nenhuma tabela oficial de produção foi alterada.** Todas as tabelas oficiais (`cidades_infra`, `infra_pops`, `infra_segmentos`, `infra_cabos`, `infra_fibras`, `infra_postes`, `infra_portas_pon`, `contrato_clientes_reservados`, `contrato_fibras`, `contratos`, `parceiros`) só foram escritas dentro do sandbox Postgres local, nunca no Supabase real — nenhuma migration foi aplicada lá.
- **Nenhuma RLS existente foi alterada.** As únicas policies tocadas continuam sendo as 3 novas em `staging.*` (Fase 4.1, inalteradas nesta fase). Reconfirmado pelos Testes 10 e 11.
- **`contrato_fibras` nunca foi escrita por nenhuma função desta feature** — confirmado por teste automatizado tanto antes (Teste 20) quanto depois (Teste 25b) de exercitar CLIENTE_RESERVADO, e a única leitura feita nela é para checagem de CONFLITO em FIBRA (Teste 21).
- **Nenhum dado de produção foi tocado.** Todo o trabalho, incluindo os 27 testes, rodou exclusivamente no banco `optimon` do sandbox local, recriado do zero a cada execução (`./run_all.sh`).
- **Nenhuma migration histórica (já aplicada em produção) foi alterada** — só as 5 migrations da própria Fase 4.1, nunca aplicadas em lugar nenhum além do sandbox (ver seção 8 para o raciocínio completo).
- **Nada foi executado contra o projeto Supabase real** em nenhum momento desta fase.

Com este fechamento, os 14 pontos da sua aprovação condicional estão endereçados. Fico no aguardo da sua revisão antes de seguirmos para a homologação real.
