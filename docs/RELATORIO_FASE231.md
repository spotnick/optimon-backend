# Relatório Final — Fase 2.3.1 (CRUD Completo: Cidades, POPs, Segmentos, Cabos, Fibras, Postes, Portas PON)

Status geral: **CONCLUÍDA no código, nos testes e na documentação — 81/81 verificações novas PASS, 0 FAIL, mais 16/16 no E2E Playwright obrigatório da seção 40, mais regressão completa herdada de todas as fases anteriores (196/196 PASS, via `run_tests_fase23.sh`, 0 quebrado)**. Nenhuma migration de fase anterior foi editada, nenhuma tabela recriada, nenhum dado existente apagado — só migrations aditivas. Por instrução explícita da seção 42 do Prompt Mestre ("NÃO iniciar nova fase. Entregar relatório completo dos testes e aguardar aprovação."), a Fase 3 **não foi iniciada**.

Esta fase transformou as telas "Cidades & Infraestrutura" / "Editar Infraestrutura" — que na Fase 2.3 só tinham ação de criar — em CRUD completo (Visualizar/Editar/Arquivar/Restaurar) para as 7 entidades de infraestrutura, sempre com exclusão lógica (nunca `DELETE` físico), com bloqueio automático quando há dependência ativa, modal de confirmação com motivo de lista fechada, RBAC restrito para restauração, e auditoria semântica completa.

## 1. Arquivos alterados ou criados

- `supabase/migrations/20260902090000..090300_phase_2_3_1_*.sql` — 4 migrations novas, todas aditivas.
- `api/lib/archiveAudit.js` — novo (helper compartilhado: chama o wrapper SQL de arquivar/restaurar, mapeia erro de bloqueio para `409` + grava `BLOCKED_ARCHIVE`/`BLOCKED_DELETE` numa segunda transação).
- `api/routes/cities.js` — estendido (`GET /?filtro=`, `POST /:id/restore` novos).
- `api/routes/infra.js` — reescrito por completo (de só criar+PATCH parcial de pops/fibras/portas PON, para CRUD+archive+restore das 6 entidades).
- `web/src/components/ArchiveModal.jsx` — novo (modal de confirmação reutilizável, motivo de lista fechada + observação livre).
- `web/src/lib/api.js` — estendido (`cities.list/archive/restore`, `infra.tree/archivePop.../restorePop...` para as 6 entidades).
- `web/src/pages/Cities.jsx`, `web/src/pages/EditCity.jsx` — estendidos com filtro Ativos/Arquivados/Todos, ações por linha (Visualizar/Editar/Arquivar/Restaurar) e gate de RBAC no frontend.
- `web/src/styles/components.css` — estilos novos (`.btn-danger`, `.row-actions`, `.badge.status-archived`, `.modal-overlay`/`.modal-dialog`).
- `tests/run_tests_fase231.sh` — novo (81 verificações + regressão completa via `run_tests_fase23.sh` original, sem editar).
- `tests/e2e_fase231.js` — novo (E2E Playwright obrigatório da seção 40, 16 verificações).
- `tests/smoke_2311_frontend.js` — smoke manual usado durante o desenvolvimento (não faz parte da suite formal, mantido no repositório por transparência).
- `docs/RELATORIO_FASE231.md` (este arquivo).

## 2. Migrations (4 novas, todas aditivas)

| # | Arquivo | O que faz |
|---|---|---|
| 1 | `090000_..._01_auditoria_semantica_e_restaurar_cidade.sql` | Amplia `auditoria_acao_check` para `ARCHIVE`/`RESTORE`/`BLOCKED_ARCHIVE`/`BLOCKED_DELETE`; `app.registrar_auditoria_semantica` (SECURITY DEFINER, uso interno); `public.pricing_log_blocked_action` (chamado pela API após capturar um bloqueio); `app.arquivar_cidade` ganha `p_motivo`/`p_observacao`; **`app.restaurar_cidade` novo** (só ADMINISTRADOR/DIRETOR). |
| 2 | `090100_..._02_arquivar_restaurar_pop_segmento_cabo_poste_pon.sql` | `app.arquivar_*`/`app.restaurar_*` para POP, Segmento, Cabo, Poste e Porta PON — cada um com sua checagem de dependência própria (seção 4 abaixo). Porta PON reaproveita a coluna `status` (`ATIVA`/`INATIVA`), sem coluna `removido_em` própria. |
| 3 | `090200_..._03_arquivados_fora_do_pricing_e_dashboard.sql` | `pricing_cities_list`/`pricing_city_detail` ganham a flag `arquivada`; `pricing_city_infra_tree` aceita `p_incluir_arquivados`; `vw_capacidade_cidade`/`vw_porta_pon_detalhe` passam a excluir infraestrutura arquivada por padrão — garante que o Pricing Engine e o Dashboard nunca contam o que foi arquivado. |
| 4 | `090300_..._04_status_observacoes_e_detail_arquivada.sql` | Colunas `status`/`observacoes` que faltavam em algumas tabelas de infraestrutura; `GET` de detalhe passa a expor `arquivada: true/false` para toda entidade. |

## 3. CRUD completo por entidade (Visualizar/Editar/Arquivar/Restaurar)

| Entidade | Endpoint base | Exclusão lógica | Bloqueio de arquivamento |
|---|---|---|---|
| Cidade | `/api/cities` | `removido_em` | Contrato/proposta/parceiro/PON em operação vinculados |
| POP | `/api/infra/pops` | `removido_em` | Cabo ou Porta PON ativos vinculados |
| Segmento | `/api/infra/segments` | `removido_em` | Cabo ou lote de postes ativos vinculados |
| Cabo | `/api/infra/cables` | `removido_em` | Fibra OCUPADA/LOCADA, Porta PON ativa, ou contrato ativo vinculados |
| Fibra | `/api/infra/fibers` | (sem arquivamento próprio — nunca é excluída isoladamente, seção 14; só o cabo inteiro arquiva) | — |
| Poste | `/api/infra/poles` | `removido_em` | Nunca bloqueia — sem dependência estrutural com outra tabela |
| Porta PON | `/api/infra/pon-ports` | `status = 'INATIVA'` (reaproveita coluna existente) | Cliente ativo (`capacidade_utilizada_assinantes > 0`) |

Toda entidade tem `GET` de lista (`?filtro=ATIVOS\|ARQUIVADOS\|TODOS`), `GET` de detalhe (funciona também arquivado — "Visualizar" nunca é bloqueado), `PATCH` de edição (só ativo), `POST .../archive` (com motivo/observação, seção 6 abaixo) e `POST .../restore`. **Nenhum endpoint `DELETE` genérico existe em nenhuma rota desta fase** — confirmado por inspeção de `api/routes/cities.js`/`infra.js` e testado explicitamente (CRUD-CB6: `DELETE /api/infra/cables/:id` → `404`, rota não existe).

## 4. Mensagens de bloqueio (texto exato testado)

- Cidade: *"Não é possível arquivar uma cidade com contrato ativo."*
- Segmento: *"Este segmento possui X cabo(s) e Y lote(s) de poste(s) ativos — arquive-os antes."*
- Cabo: *"Este cabo possui X fibra(s) ocupada(s)/locada(s), Y Porta(s) PON e Z vínculo(s) de contrato ativos — trate essas dependências antes."*
- Porta PON: *"PON possui clientes ativos e não pode ser arquivada."*

Cada bloqueio grava uma linha `BLOCKED_ARCHIVE` na auditoria com o motivo exato (seção 7).

## 5. RBAC (seção 30 herdada + seção 21 desta fase)

| Perfil | Criar/Editar infra | Arquivar | Restaurar | Só visualizar |
|---|---|---|---|---|
| ADMINISTRADOR | sim | sim | sim | — |
| DIRETOR | conforme governança herdada | não | **sim** | — |
| ENGENHARIA | sim | sim | não | — |
| COMERCIAL | não | não | não | sim |
| FINANCEIRO | não | não | não | sim |
| AUDITOR | não | não | não | sim (+ histórico de auditoria) |

Verificado por API real com JWT de cada um dos 6 perfis (RBAC-COMERCIAL/FINANCEIRO/AUDITOR não arquivam, mas visualizam; RBAC-ENGENHARIA não restaura, checado antes até da checagem de "já está arquivado"; CRUD-C9/CRUD-PON9 confirmam ENGENHARIA bloqueada em restore com `403`; CRUD-C10/CRUD-S7/CRUD-CB8/CRUD-PT5/CRUD-PON10 confirmam ADMINISTRADOR e DIRETOR restaurando com sucesso).

## 6. Modal de confirmação (seção 29)

Nenhum arquivamento acontece no clique direto — `ArchiveModal.jsx` sempre intercepta com: nome/tipo/cidade do item, motivo de lista fechada (`Infraestrutura desativada`, `Erro de cadastro`, `Substituição`, `Expansão`, `Alteração de projeto`, `Venda`, `Outro`) e observação livre opcional. Confirmado via Playwright (E2E-9/E2E-12: seleciona motivo, preenche observação, clica "Confirmar Arquivamento", só então a chamada de arquivar é disparada).

## 7. Auditoria semântica completa (seção 28)

Além da auditoria genérica por trigger (`fn_auditoria()`, já existente desde a Fase 1, que segue registrando toda alteração como `UPDATE` com dados anteriores/novos), cada arquivamento/restauração bem-sucedidos gravam **uma segunda linha semântica** (`ARCHIVE`/`RESTORE`) via `app.registrar_auditoria_semantica` — 2 linhas por operação, intencional, não duplicação por acidente. Um bloqueio (`RAISE EXCEPTION`) desfaz toda a transação, então `BLOCKED_ARCHIVE`/`BLOCKED_DELETE` são gravados pela API, numa segunda chamada RPC própria, depois de capturar o erro 409. Testado ponta a ponta com usuário/data/entidade/ação/motivo presentes em todos os 4 tipos de evento (`aud_check` em 20+ pontos do script formal).

## 8. Infraestrutura arquivada nunca aparece no Pricing Engine nem no Dashboard (seção 39)

`vw_capacidade_cidade` e `vw_porta_pon_detalhe` (migration 3) excluem infraestrutura arquivada por padrão. Testado isolando uma Porta PON com 1 cliente zerado, arquivando, e confirmando que `capacidade_maxima_clientes` da cidade cai exatamente na capacidade daquela porta (PRICE-1..4); e arquivando um POP com seu cabo dependente já arquivado antes, confirmando que a árvore de infraestrutura (`GET /api/infra/tree`) só lista o POP quando `incluir_arquivados=true` é passado explicitamente — nunca por padrão (PRICE-5..7).

## 9. Frontend atualiza sem refresh manual

Todo componente de seção (`PopsSection`, `SegmentsSection`, `CablesSection`, `PolesSection`, `PonPortsSection`) recebe um `onChanged` que recarrega a árvore inteira (`reload()`) depois de qualquer ação — criar, editar, arquivar, restaurar. Confirmado via Playwright (E2E-7/E2E-9/E2E-11: a lista muda de estado na mesma execução, sem `page.reload()`).

## 10. Bateria de testes (seções 31-39) — 81/81 novas + regressão herdada 196/196 + E2E 16/16

`tests/run_tests_fase231.sh`: PASSO-0 reexecuta `tests/run_tests_fase23.sh` **original, sem editar** (que por sua vez reexecuta toda a cadeia Fase 1→2.3, 196 verificações) e só depois aplica as 4 migrations novas.

- **SECAO 31** (Cidade): `CRUD-C1..C13` — criar, editar, `km_rede` persistido, arquivar, listar em ATIVOS/ARQUIVADOS, visualizar arquivada, ENGENHARIA bloqueada em restore (`403`), DIRETOR restaura com sucesso, Jussara com contrato ativo continua bloqueada.
- **SECAO 32** (POP): `CRUD-P1..P12` — criar, editar, bloqueio por cabo ativo, arquivar cabo dependente, arquivar POP, listar arquivado, ADMINISTRADOR restaura.
- **SECAO 33** (Segmento): `CRUD-S0..S7` — segmento isolado, editar, bloqueio por cabo ativo, arquivar cabo/segmento em cascata, DIRETOR restaura.
- **SECAO 34** (Cabo): `CRUD-CB0..CB8` — cabo isolado, editar, marcar fibra OCUPADA, bloqueio por fibra em uso, arquivar, fibra preservada no histórico, PATCH nunca expõe `DELETE`, ADMINISTRADOR restaura.
- **SECAO 35** (Fibra): `FIBRA-*` — as 6 transições de status (LIVRE/OCUPADA/RESERVADA/LOCADA/MANUTENCAO/BLOQUEADA).
- **SECAO 36** (Poste): `CRUD-PT1..PT5` — criar, editar, arquivar sem bloqueio (sem dependência estrutural), restaurar.
- **SECAO 37** (Porta PON): `CRUD-PON1..PON10` — criar, editar, `PATCH` rejeita mudança direta para/de `INATIVA` (só via `/archive`/`/restore`), bloqueio por cliente ativo, arquivar, ENGENHARIA bloqueada em restore, ADMINISTRADOR restaura.
- **SECAO 38** (RBAC): COMERCIAL/FINANCEIRO/AUDITOR não arquivam nada (`403`) mas visualizam; ENGENHARIA bloqueada em restore mesmo sem o item estar arquivado (RBAC checado antes do estado).
- **SECAO 39** (Pricing/Dashboard): `PRICE-1..7`, ver seção 8 acima.

`tests/e2e_fase231.js` (Playwright real contra o frontend Vite/React, mesmo padrão de autenticação local da Fase 2.3): **16/16 PASS** — segue literalmente o fluxo da seção 40: Login → Cidades → Jussara → Editar → alterar KM de rede (persistido no banco) → salvar → Dashboard segue consistente → Editar Infraestrutura → seleciona um POP → edita o nome → salva → cria e arquiva um segmento de teste → consulta o filtro Arquivados (badge visível) → restaura (ADMINISTRADOR) → arquiva de novo → confirma que o formulário "Novo Cabo" não oferece mais esse segmento arquivado como opção → Nova Simulação → confirma que o dropdown de POP nunca lista um POP arquivado → Pricing Engine calcula normalmente para Jussara ao final de todo o fluxo.

## 11. Bugs reais encontrados durante a própria validação (2 mais significativos, mais 6 menores — todos corrigidos e disclosed)

**Bug 1 (mais sério) — restaurar como DIRETOR não restaurava nada, silenciosamente, para TODAS as 6 entidades.** As 6 funções `app.restaurar_*` já faziam sua própria checagem de RBAC (`app.tem_perfil('ADMINISTRADOR', 'DIRETOR')`) logo no início, mas rodavam como `SECURITY INVOKER` — então o `UPDATE` que de fato limpa `removido_em` (ou `status`, no caso da Porta PON) continuava sujeito à *policy* de escrita/`UPDATE` de cada tabela, que só inclui `ENGENHARIA`/`ADMINISTRADOR`, nunca `DIRETOR`. Para ADMINISTRADOR isso batia por coincidência e mascarava o problema; para DIRETOR o `UPDATE` afetava silenciosamente **0 linhas** — RLS filtra linhas, não lança erro de permissão — então a API respondia `200`, a auditoria `RESTORE` era gravada normalmente, e mesmo assim o dado no banco nunca mudava. Só foi percebido consultando o estado real da linha após um "restaurar" bem-sucedido segundo o próprio teste (a auditoria e o HTTP `200` davam falso-positivo). Corrigido convertendo as 6 funções (`app.restaurar_cidade/pop/segmento/cabo/poste/porta_pon`) para `SECURITY DEFINER` com `search_path` fixo — mesmo padrão já usado em `app.registrar_auditoria_semantica` — já que cada uma já se autoriza sozinha antes de tocar a tabela.

**Bug 2 — infraestrutura arquivada continuava selecionável para vincular a um item NOVO.** Os formulários de criação de Cabo, lote de Postes e Porta PON, em `EditCity.jsx`, listavam POPs/Segmentos sem filtrar `arquivado` — um cabo novo podia ser criado apontando para um segmento já arquivado, por exemplo. Corrigido filtrando as 3 listas de criação para só oferecer itens ativos; os formulários de *edição* (que podem estar editando um item já vinculado a algo arquivado antes) preservam o vínculo atual mas também não oferecem um segundo vínculo novo a algo arquivado. Coberto pelo E2E (E2E-12).

**Bugs menores (6, todos corrigidos durante o próprio desenvolvimento desta fase):** função `registrar_auditoria_semantica` sem `GRANT EXECUTE` explícito para `authenticated` (uma função `SECURITY INVOKER` chamando uma `SECURITY DEFINER` revogada falha, porque o privilégio é checado contra `current_user` no ponto da chamada, não herdado); `archiveAudit.js` chamando `.catch()` num query builder do Supabase que não é uma `Promise` de verdade; filtro `ARQUIVADOS` de `GET /api/cities` checando o campo errado; `PATCH /api/infra/pon-ports/:id` permitindo bypass das regras de negócio de arquivar/restaurar ao aceitar `status` diretamente; `app.arquivar_cabo` bloqueado para sempre por qualquer Porta PON já arquivada vinculada (mesmo sem cliente ativo); e 3 pontos de chamada RPC que quebravam a regressão encadeada das fases anteriores por sempre enviarem um parâmetro novo mesmo quando o banco daquela fase ainda não tinha esse parâmetro (corrigido omitindo o parâmetro no caso padrão).

## 12. Segurança — auditoria própria desta entrega

Nenhum arquivo versionado contém segredo real (conferido nas 4 migrations, em `api/routes/*.js` e nos componentes novos do frontend antes do commit). Nenhuma rota nova usa a service role — todas passam por `clientForRequest(req.userJwt)`. O backend nunca confia em valor vindo do frontend: toda decisão de bloqueio, RBAC e recálculo de capacidade acontece no banco, não na API nem no React.

## 13. O que não foi testado / está fora do escopo desta fase

Deploy real (não fazia parte do escopo desta fase — só validação local completa e relatório, por instrução explícita da seção 42), integração HubSoft/IBGE/financeira externa, e qualquer teste de carga/performance sob rede real de produção — mesmos itens fora de escopo desde a Fase 2.

## 14. Fase 3 — não iniciada

Por instrução explícita da seção 42 do Prompt Mestre desta fase ("NÃO iniciar nova fase. Entregar relatório completo dos testes e aguardar aprovação."), a Fase 2.3.1 termina aqui, aguardando aprovação explícita do usuário antes de qualquer trabalho novo.

## Checklist de aceite (28 itens)

1. [x] Cidade tem CRUD completo (criar/editar/arquivar/restaurar) — SECAO 31.
2. [x] POP tem CRUD completo — SECAO 32.
3. [x] Segmento tem CRUD completo — SECAO 33.
4. [x] Cabo tem CRUD completo — SECAO 34.
5. [x] Fibra tem edição de status individual (sem arquivamento próprio, por design da seção 14) — `FIBRA-*`.
6. [x] Poste tem CRUD completo — SECAO 36.
7. [x] Porta PON tem CRUD completo (reaproveitando a coluna `status`) — SECAO 37.
8. [x] Nenhum `DELETE` físico em nenhuma entidade — nenhum endpoint `DELETE` genérico existe (CRUD-CB6).
9. [x] Bloqueio de arquivamento de cidade com contrato/proposta/parceiro/PON ativo — CRUD-C12/C13.
10. [x] Bloqueio de arquivamento de POP com cabo/PON ativo — CRUD-P6/P7.
11. [x] Bloqueio de arquivamento de segmento com cabo/poste ativo — CRUD-S3/S4.
12. [x] Bloqueio de arquivamento de cabo com fibra ocupada/locada/PON/contrato ativo — CRUD-CB3/CB4.
13. [x] Poste nunca bloqueia arquivamento — CRUD-PT3.
14. [x] Bloqueio de arquivamento de Porta PON com cliente ativo, mensagem exata — CRUD-PON4/PON5.
15. [x] Mensagens de bloqueio conferem literalmente com o especificado — seção 4 deste relatório.
16. [x] Restaurar restrito a ADMINISTRADOR/DIRETOR em todas as entidades — CRUD-C9/C10, RBAC-ENGENHARIA, CRUD-PON9/PON10.
17. [x] Modal de confirmação com motivo de lista fechada + observação — E2E-9/E2E-12.
18. [x] RBAC completo por perfil (6 perfis) — SECAO 38.
19. [x] Auditoria completa (CREATE/UPDATE/ARCHIVE/RESTORE/BLOCKED_ARCHIVE/BLOCKED_DELETE) com usuário/data/entidade/ação/antes/depois/motivo — seção 7 deste relatório.
20. [x] Pricing Engine nunca conta infraestrutura arquivada — PRICE-1..4.
21. [x] Dashboard nunca conta infraestrutura arquivada — PRICE-5..7.
22. [x] Frontend atualiza listas imediatamente após qualquer ação, sem refresh manual — E2E-7/E2E-9/E2E-11.
23. [x] Cenários de teste obrigatórios das seções 31-39 passando — 81/81 PASS.
24. [x] Fluxo E2E completo da seção 40 passando literalmente — 16/16 PASS.
25. [x] Regressão completa de todas as fases anteriores sem quebras — 196/196 PASS herdado (via `run_tests_fase23.sh`, sem editar).
26. [x] Nenhuma migration recriou o banco ou apagou dado existente — só 4 migrations aditivas, nenhuma anterior editada.
27. [x] Nenhum segredo real versionado — conferido antes do commit (seção 12).
28. [x] Documentação e relatório final entregues — este arquivo.

**28 de 28 itens PASS.** Por instrução explícita da seção 42 do Prompt Mestre, a Fase 3 não deve começar até o usuário aprovar explicitamente esta entrega.
