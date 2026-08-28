# OptiMon — Referência da API interna (item 3.13)

Documento gerado nesta fase (Fase 3, item 3.13 — "Documentação da API interna: referência de endpoints") a partir da **leitura integral do código-fonte real** em `api/routes/*.js`, `api/middleware/auth.js` e `api/server.js` — nunca de memória ou suposição. Cada seção abaixo foi produzida lendo o arquivo de rota inteiro (não por amostragem), e cita nome exato de RPC/função/tabela quando a rota delega a ela.

**Metodologia e honestidade:** onde o código não faz nenhuma checagem de papel em JavaScript, isso é dito explicitamente ("nenhuma checagem no Node; RLS/RPC decide") — nunca se assume que "deve" haver uma restrição. Onde um comentário do código descreve uma regra que só existe no Postgres (RLS/RPC), o texto abaixo cita o comentário, mas a fonte de verdade real da regra é sempre o SQL, não este documento. Este arquivo não substitui a leitura do código-fonte para mudanças — é um mapa de navegação.

**Escopo:** cobre todas as rotas HTTP de negócio (as montadas com `requireAuth` em `api/server.js`, mais o webhook de assinaturas, que é a única exceção sem JWT de usuário). Não cobre `GET /health` nem `GET /api/version` (utilitários triviais, documentados na seção final) nem middlewares/libs internos além do estritamente necessário para explicar uma rota.

## Autenticação e base

- **Base URL:** definida pelo deploy (Railway) — não fixada em código, lida de variável de ambiente pelo frontend.
- **Autenticação:** toda rota (exceto o webhook de assinaturas) exige header `Authorization: Bearer <JWT>` — validado só pela **presença/formato** no middleware `requireAuth` (`api/middleware/auth.js`); a validade/expiração real do JWT e todo RBAC são resolvidos no Postgres via RLS quando a API repassa o token ao Supabase (`clientForRequest(req.userJwt)`). Uma chamada sem header, ou com esquema diferente de `Bearer`, recebe **401** `{ "error": "Authorization: Bearer <jwt> obrigatório." }` antes de chegar a qualquer rota.
- **CORS:** liberado só para as origens em `CORS_ALLOWED_ORIGINS` (nunca `*`); requisições sem header `Origin` (server-to-server, curl, health check) sempre passam.
- **Formato de erro:** por convenção em toda rota, um erro devolve `{ "error": "<mensagem>" }` — nunca stack trace nem detalhe de conexão. Cada arquivo de rota define seu próprio `handleError`/`handleSupabaseError`, mapeando padrões de texto da mensagem do Postgres (`RAISE EXCEPTION`) para um status HTTP; o mapeamento exato de cada arquivo está documentado no início da seção correspondente abaixo.
- **RBAC real:** com poucas exceções documentadas por rota (o helper `assertAdmin` de `users.js`, e algumas checagens locais em `partners.js`/`infra.js` para distinguir 403 de 404 depois de um UPDATE silenciosamente bloqueado por RLS), a API Node **não decide permissão** — ela é sempre resolvida por RLS/RPC no Postgres, usando o JWT do próprio usuário chamador. Isso significa que a ausência de uma checagem de papel citada abaixo não é uma falha de documentação: é o desenho do sistema.

---

## Pricing — `/api/pricing`

Arquivo: `api/routes/pricing.js`. Cada handler é fino: valida entrada mínima e delega para **uma** função/RPC SQL (`public.pricing_*`); toda a lógica de negócio (fórmulas, governança, RBAC) vive no banco — a API nunca decide preço nem contorna aprovação.

### Mapeamento de erro — `handleSupabaseError(res, error, opts = {})`
A partir de `error.message` (texto formatado pelo Postgres via `RAISE EXCEPTION`):
- `/REQUIRES_APPROVAL/i` → **403**.
- `/BLOCK|not-found|não encontrad/i` → **409**.
- Qualquer outro caso → **400**.
- Exceção: se `opts.role === 'COMERCIAL'` **e** a mensagem casa com `/não encontrad/i`, o status vira **403** (cobre um UPDATE filtrado silenciosamente pela RLS quando COMERCIAL tenta decidir um override que não é dele) — usado só em `POST /approve`.

| Rota | O que faz | Autorização | Parâmetros | Resposta |
|---|---|---|---|---|
| `POST /calculate` | Pricing Engine centralizado — recalcula tudo no banco, nunca confia em floor/recomendado/governança vindos do cliente. | Nenhuma no Node; `calculatePricing()` → RPC(s) sob RLS. | Body: `cidade_id`, `pop_id?`, `clientes`, `arpu`, `faturamento?`, `revenue_share_pct?`, `composicao_mode?`, `preco_proposto?`, `pons_count?`, `pricing_version?`. | JSON do helper. |
| `POST /simulate` | ScenarioSimulator. | Nenhuma no Node; RPC `pricing_simulate`. | Corpo inteiro repassado como `p_params`. | `data` da RPC. |
| `GET /projection` | Mesma projeção via query string. | Nenhuma no Node; RPC `pricing_projection`. | Query `params` (JSON, obrigatório, default `'{}'`). | `data`. **400** se JSON inválido. |
| `GET /roi` | ROI + payback nos horizontes pedidos, em paralelo. | Nenhuma no Node; RPCs `pricing_roi`/`pricing_payback`. | Query `projecao` (obrigatório, JSON), `investimento?` (default 0), `meses?` (CSV, default `12,36,48,60`). | `{ roi, payback }`. **400** se `projecao` inválido. |
| `POST /quote` | Preço mínimo/recomendado/premium + governança de um contrato. | Nenhuma no Node; RPC `pricing_quote`. | Body: `contrato_id` (obrig.), `preco_proposto?`. | `data`. **400** se faltar `contrato_id`. |
| `POST /override` | COMERCIAL solicita preço diferente do recomendado. | Nenhuma no Node; RPC `pricing_override_create` (governança no banco). | Body: `contrato_id`, `preco_recomendado`, `preco_solicitado`, `justificativa` (obrig.); `simulacao_id?`, `preco_piso?`, `preco_abertura?`, `pop_id?`. | **201** `{ override_id }`. |
| `POST /approve` | Aprova/rejeita um override pendente (DIRETOR/ADMINISTRADOR ou FINANCEIRO autorizado). | Regra só no banco; RPC `pricing_override_approve`. Erro consulta `pricing_current_user_role()` para decidir 403 vs 409. | Body: `override_id`, `aprovar` (boolean) (obrig.); `observacao?`. | `data`. **400** se faltar campo. |
| `GET /versions` | Histórico imutável de versões de pricing. | Nenhuma no Node; RPC `pricing_versions_list`. | Query `contrato_id` (obrig.). | `data`. **400** se ausente. |
| `GET /scenarios` | Lista simulações salvas. | Nenhuma no Node; RPC `pricing_scenarios_list`. | Query `contrato_id?`. | `data`. |
| `GET /capacity-by-pop` | Capacidade por POP + consolidado de um contrato. | Nenhuma no Node; RPC `pricing_capacity_by_pop`. | Query `contrato_id` (obrig.). | `data`. **400** se ausente. |
| `GET /infrastructure-floor` | Infrastructure Floor (piso/recomendado/abertura). | Nenhuma no Node; RPC `pricing_infrastructure_floor`. | Query `cidade_id` (obrig.); `pop_id?`, `pricing_version?`, `pons_count?`. | `data`. **400** se `cidade_id` ausente. |
| `GET /infra-floor-negotiation` | Régua comercial completa: posição, governança tri-state e por papel, descontos, preço mínimo autorizável. | Nenhuma no Node; RPC `pricing_infra_floor_negotiation`. | Query `preco_proposto`, `cidade_id` (obrig.); `pop_id?`, `pricing_version?`, `pons_count?`. | `data`. **400** se faltar obrigatório. |
| `GET /current-role` | Papel RBAC do usuário autenticado — só apoio de UI, nunca fonte de verdade de permissão. | Nenhuma no Node; RPC `pricing_current_user_role`. | — | `{ role }`. |
| `GET /economics-with-floor` | Infrastructure Floor + Minimum Contractual Fee + Revenue Share + Receita/Margem. | Nenhuma no Node; RPC `pricing_economics_with_floor`. | Query `contrato_id` (obrig.); `faturamento_parceiro?` (default 0), `pop_id?`, `pricing_version?`. | `data`. **400** se ausente. |
| `GET /fibras-indicadores` | Fibras totais/ocupadas/ociosas + Portas PON totais/disponíveis. | Nenhuma no Node; RPC `pricing_fibras_indicadores`. | Query `cidade_id` (obrig.); `pop_id?`. | `data`. **400** se ausente. |
| `GET /capacity-multipop-floor` | Quebra do Infrastructure Floor por POP + consolidado. | Nenhuma no Node; RPC `pricing_capacity_multipop_piso`. | Query `cidade_id` (obrig.). | `data`. **400** se ausente. |
| `POST /growth-curve` | Série "Crescimento da Base × Receita" / "Clientes × PONs". | Nenhuma no Node; RPC `pricing_growth_curve`. | Body: `clientes_max?`, `passos?` (default 20); resto vira `p_params`. | `data`. |
| `POST /horizon-table` | Tabela de projeção nos horizontes 12/36/48/60 (ou custom). | Nenhuma no Node; RPC `pricing_horizon_table`. | Body: `capex?` (0), `opex_mensal?` (0), `horizontes?` (`[12,36,48,60]`); resto vira `p_params`. | `data`. |
| `GET /ramp` | Regra de rampa de um contrato. | Nenhuma no Node; RPC `pricing_ramp_rules_list`. | Query `contrato_id?`. | `data`. |
| `GET /indices` | Índices econômicos coletados (ex.: IPCA). | Nenhuma no Node; RPC `pricing_indices_list`. | Query `indice?`, `limit?` (default 12). | `data`. |
| `GET /:id` | Busca um cálculo/simulação salvo por id. | Nenhuma no Node; RPC `pricing_simulation_get`. | Path `id`. | `data`. **404** se vazio. Posicionada por último de propósito, para não capturar `/versions`, `/scenarios` etc. |

---

## Cidades — `/api/cities`

Arquivo: `api/routes/cities.js`. Handlers finos que validam presença mínima e delegam a `app.criar_cidade/atualizar_cidade/arquivar_cidade/restaurar_cidade` via RPC.

### Mapeamento de erro — `handleError` (usa `statusForArchiveError` de `../lib/archiveAudit`)
`PERMISSAO_NEGADA` → **403** · "não encontrad..." → **404** · padrões de bloqueio de dependência ("não é possível arquivar", "possui ... ativ/ocupad/locad", "clientes ativos", "contrato ativo") → **409** · qualquer outra → **400**.

| Rota | O que faz | Autorização | Parâmetros | Resposta |
|---|---|---|---|---|
| `GET /` | Lista cidades com infraestrutura/capacidade consolidadas. | RPC `pricing_cities_list`. | Query `filtro?` (`ATIVOS` padrão \| `ARQUIVADOS` \| `TODOS`). | Array. `ATIVOS` chama a RPC sem parâmetros (compatibilidade retroativa); `ARQUIVADOS` é filtrado client-side sobre `p_incluir_arquivados: true`. |
| `GET /:id` | Detalhe de cidade (infra + capacidade + POPs). | RPC `pricing_city_detail`. | Path `id`. | JSON com `arquivada`. Funciona também arquivada. |
| `POST /` | Cadastra cidade. | RPC `pricing_city_create`. | Body: `nome`, `uf`, `km_rede` (obrig.); `codigo_ibge?`, `endereco?`, `observacoes?`, `status?` (`'ATIVA'`). | **201** `{ cidade_id }`. **400** se faltar obrigatório. |
| `PATCH /:id` | Edição parcial. | RPC `pricing_city_update`. | Path `id`. Body opcionais: `nome`, `uf`, `km_rede`, `codigo_ibge`, `endereco`, `observacoes`, `status`. | `{ ok: true }`. Campo ausente preserva valor atual. |
| `POST /:id/archive` | Arquiva cidade (soft, via `archiveWithAudit`). | RPC `pricing_city_archive`. | Path `id`. Body opcional: `motivo`, `observacao`. | `{ ok: true }`. **409** se houver contrato ativo (log `BLOCKED_ARCHIVE` automático best-effort). |
| `POST /:id/restore` | Restaura cidade arquivada. | "Só ADMINISTRADOR/DIRETOR" (comentário) — RPC `pricing_city_restore`, RBAC 100% no banco. | Path `id`. Body opcional: `motivo`. | `{ ok: true }`. |

---

## Infraestrutura — `/api/infra`

Arquivo: `api/routes/infra.js`. Cobre POPs, Segmentos, Cabos (+ Fibras), Postes e Portas PON, todos no mesmo padrão: `GET` lista/`GET :id`/`POST` criar/`PATCH` editar (direto via supabase-js, sob RLS + trigger de auditoria genérico) + `POST :id/archive`/`POST :id/restore` (sempre via wrappers SQL dedicados — nunca `UPDATE` direto em `removido_em`/`status`, porque é lá que vive a checagem de dependência e o registro semântico ARCHIVE/RESTORE/BLOCKED_ARCHIVE). Cabo é exceção também na criação: `pricing_cable_create_with_fibers` cria cabo+fibras numa transação.

### Mapeamento de erro — `handleError`
`PERMISSAO_NEGADA`/RLS → **403** · "não encontrad" → **404** · caso contrário, `statusForArchiveError`: **409** se bloqueio de dependência, senão **400**.

`applyRemovidoEmFiltro`: `filtro=ATIVOS` (default) → `removido_em is null`; `ARQUIVADOS` → `removido_em is not null`; `TODOS` → sem filtro. `archiveWithAudit` (mesmo helper de `cities.js`): em bloqueio (409), registra `BLOCKED_ARCHIVE` numa segunda chamada best-effort, porque a exceção original desfez qualquer log feito na mesma transação.

### GET /tree
`pricing_city_infra_tree` — árvore completa de uma cidade. Query `cidade_id` (obrig.), `incluir_arquivados?` (`'true'`, só enviado à RPC quando ativo). **400** se `cidade_id` ausente.

### POPs
| Rota | RPC/mecanismo | Parâmetros principais | Observação |
|---|---|---|---|
| `GET /pops` | RLS direto | `cidade_id` (obrig.), `filtro?` | Ordenado por `codigo`. |
| `GET /pops/:id` | RLS direto | Path `id` | Funciona arquivado. |
| `POST /pops` | RLS direto (ENGENHARIA/ADMINISTRADOR) | `cidade_id`, `codigo`, `nome` (obrig.); `tipo?`, `endereco?`, `latitude?`, `longitude?`, `capacidade_total?`, `status?`, `observacoes?` | **201**. |
| `PATCH /pops/:id` | RLS direto | Todos opcionais | Campo ausente preserva valor. |
| `POST /pops/:id/archive` | RPC `pricing_pop_archive` | `motivo?`, `observacao?` | Bloqueia se houver cabo não arquivado ou Porta PON não `INATIVA`. |
| `POST /pops/:id/restore` | RPC `pricing_pop_restore` ("Só ADMINISTRADOR/DIRETOR") | `motivo?` | |

### Segmentos
| Rota | RPC/mecanismo | Parâmetros principais | Observação |
|---|---|---|---|
| `GET /segments` | RLS direto | `cidade_id` (obrig.), `filtro?` | Ordenado por `nome`. |
| `GET /segments/:id` | RLS direto | Path `id` | Funciona arquivado. |
| `POST /segments` | RLS direto | `cidade_id`, `nome`, `origem`, `destino`, `extensao_km` (todos obrig.) | **201**. |
| `PATCH /segments/:id` | RLS direto | `nome?`, `origem?`, `destino?`, `extensao_km?`, `status?`, `observacoes?` | |
| `POST /segments/:id/archive` | RPC `pricing_segment_archive` | `motivo?`, `observacao?` | Bloqueia se houver cabo/poste não arquivados. |
| `POST /segments/:id/restore` | RPC `pricing_segment_restore` | `motivo?` | |

### Cabos + Fibras
| Rota | RPC/mecanismo | Parâmetros principais | Observação |
|---|---|---|---|
| `GET /cables` | RLS direto | `segmento_id` (obrig.), `filtro?` | Ordenado por `identificacao`. |
| `GET /cables/:id` | RLS direto | Path `id` | Funciona arquivado. |
| `POST /cables` | RPC `pricing_cable_create_with_fibers` | `segmento_id`, `identificacao`, `capacidade_fo` (obrig.); `pop_id?`, `fabricante?` | **201** `{ cabo_id }` — cria cabo+fibras juntos. |
| `PATCH /cables/:id` | RLS direto (UPDATE direto) | `identificacao?`, `capacidade_fo?`, `fabricante?`, `segmento_id?`, `pop_id?`, `status?`, `observacoes?` | Só corrige cadastro — não cria/remove fibra física. |
| `POST /cables/:id/archive` | RPC `pricing_cable_archive` | `motivo?`, `observacao?` | Bloqueia se fibra `OCUPADA`/`LOCADA`, em Porta PON, ou contrato ativo. |
| `POST /cables/:id/restore` | RPC `pricing_cable_restore` | `motivo?` | |
| `GET /cables/:id/fibers` | RLS direto | Path `id` (cabo) | Ordenado por `numero_fibra`. |
| `PATCH /fibers/:id` | RLS direto (UPDATE direto) | `status?` (`LIVRE`/`OCUPADA`/`RESERVADA`/`LOCADA`/`MANUTENCAO`/`BLOQUEADA`), `observacao?` — **400** se nenhum dos dois. | Só estado operacional — nunca vincula contrato (isso é `contrato_fibras`, fora daqui). Sem archive/delete isolado de fibra — só sai de circulação junto do cabo inteiro. |

### Postes
Sem archive/delete de dependência real — comentário do código: "nunca bloqueia".

| Rota | RPC/mecanismo | Parâmetros principais |
|---|---|---|
| `GET /poles` | RLS direto | `cidade_id` (obrig.), `filtro?` — ordenado por `criado_em`. |
| `GET /poles/:id` | RLS direto | Path `id`, funciona arquivado. |
| `POST /poles` | RLS direto | `cidade_id`, `quantidade` (obrig.); `segmento_id?`, `identificacao?`, `proprietario_terceiro?`, `custo_mensal?` (0). |
| `PATCH /poles/:id` | RLS direto | `identificacao?`, `segmento_id?`, `proprietario_terceiro?`, `quantidade?`, `custo_mensal?`, `status?`, `observacoes?`. |
| `POST /poles/:id/archive` | RPC `pricing_pole_archive` | `motivo?`, `observacao?` — nunca bloqueia (sem dependência estrutural). |
| `POST /poles/:id/restore` | RPC `pricing_pole_restore` | `motivo?`. |

### Portas PON
Sem coluna `removido_em` — "arquivar" reaproveita `status` (`ATIVA`/`INATIVA`/`MANUTENCAO`): arquivar = `INATIVA`, restaurar = `ATIVA`. Triggers no banco (`fn_valida_porta_pon_pop`, `fn_porta_pon_default_capacidade`) garantem consistência e aplicam 128 como capacidade padrão.

| Rota | RPC/mecanismo | Parâmetros principais |
|---|---|---|
| `GET /pon-ports` | RLS direto | `pop_id` (obrig.), `filtro?` (aqui `ARQUIVADOS` = `status='INATIVA'`) — ordenado por `codigo_porta`. |
| `GET /pon-ports/:id` | RLS direto | Path `id`, funciona arquivada. |
| `POST /pon-ports` | RLS direto + triggers | `fibra_id`, `pop_id`, `codigo_porta` (obrig.); `nome?`, `tecnologia?` (`'GPON'`), `capacidade_max_assinantes?`, `status?` (`'ATIVA'`). |
| `PATCH /pon-ports/:id` | RLS direto | `fibra_id?`, `pop_id?`, `codigo_porta?`, `nome?`, `tecnologia?`, `capacidade_max_assinantes?`, `status?`. **400** se tentar setar `status='INATIVA'` (usar `/archive`) ou mudar `status` de um registro já `INATIVA` (usar `/restore`) — as duas transições ficam reservadas às rotas dedicadas, para garantir a checagem de cliente ativo + auditoria. |
| `POST /pon-ports/:id/archive` | RPC `pricing_pon_port_archive` | `motivo?`, `observacao?` — bloqueia se houver cliente ativo. |
| `POST /pon-ports/:id/restore` | RPC `pricing_pon_port_restore` ("Só ADMINISTRADOR/DIRETOR") | `motivo?`. |

---

## Simulações — `/api/simulations`

Arquivo: `api/routes/simulations.js`. O cálculo em si acontece em `POST /api/pricing/calculate` sem gravar nada; esta rota só persiste um resultado já calculado, mediante confirmação do usuário.

**Mapeamento de erro:** `/obrigatóri|enum|invalid input/i` → **400**; qualquer outra → **409**.

| Rota | O que faz | Parâmetros | Resposta |
|---|---|---|---|
| `POST /` | Persiste uma simulação já calculada — RPC `pricing_simulation_save`. `resultado` nunca é recalculado aqui (deve vir de `/calculate`). | Body: `cidade_id`, `modelo`, `resultado` (obrig. — jsonb de `/calculate`); `parceiro_id?`, `pares_ou_clientes?`, `arpu?`, `revenue_share_pct?`, `prazo_meses?` (48). | **201**. **400** se faltar obrigatório. |
| `GET /` | Lista simulações salvas — RPC `pricing_scenarios_list`. | Query `contrato_id?`. | Array. |

---

## Propostas — `/api/proposals`

Arquivo: `api/routes/proposals.js`.

**Mapeamento de erro:** `PERMISSAO_NEGADA`/RLS → **403** · "não encontrad" → **404** · `MOTIVO_OBRIGATORIO`/"obrigatóri"/"inválido" → **400** · qualquer outra → **409**.

| Rota | O que faz | Autorização | Parâmetros | Resposta |
|---|---|---|---|---|
| `POST /` | "GERAR PROPOSTA" a partir de uma simulação salva — RPC `pricing_proposal_create`; snapshot nunca recalculado aqui. | RLS da RPC. | Body: `simulacao_id` (obrig.); `cidade_id?`, `parceiro_id?`, `contrato_id?`, `pricing_version_id?`, `override_request_id?`, `parceiro_nome_capa?`, `parceiro_cargo_contato?`, `validade_dias?` (só enviados se informados, compatibilidade retroativa). | **201**. **400** se faltar `simulacao_id`. |
| `GET /` | Lista propostas — RPC `pricing_proposals_list`. | RLS da RPC. | Query `contrato_id?`, `cidade_id?`, `status?`, `parceiro_id?`, `todas_versoes?`. | Array. |
| `GET /:id` | Detalhe completo (jsonb enriquecido) — RPC `pricing_proposal_get_by_id`. | RLS da RPC. | Path `id`. | JSON. **404** se não encontrada. |
| `GET /:id/public` | Visão externa filtrada (nunca inclui piso/abertura/desconto/governança) — RPC `pricing_proposal_external_view`. | Filtragem 100% no banco. | Path `id`. | JSON filtrado. **404**. |
| `GET /:id/versions` | Histórico de versões (V1/V2/V3...) — RPC `pricing_proposal_versions`. | RLS da RPC. | Path `id`. | Array. |
| `POST /:id/version` | Cria a próxima versão na mesma família — RPC `pricing_proposal_new_version`. | RLS da RPC. | Path `id`. Body `motivo?`. | **201**. |
| `POST /:id/duplicate` | Duplica em nova família própria, sempre RASCUNHO — RPC `pricing_proposal_duplicate`. | RLS da RPC. | Path `id`. Body `motivo?`. | **201**. |
| `POST /:id/approve` | Aprova a proposta — RPC `pricing_proposal_approve` (DIRETOR/ADMINISTRADOR, no banco). | RLS/RPC. | Path `id`. Body `motivo?` (exigido pela RPC se preço abaixo do piso). | **200**. **400** `MOTIVO_OBRIGATORIO` se faltar quando exigido. |
| `POST /:id/reject` | Rejeita — RPC `pricing_proposal_reject`, `motivo` sempre obrigatório (checado na própria rota). | RLS/RPC. | Path `id`. Body `motivo` (obrig.). | **200**. **400** se ausente. |
| `POST /:id/status` | Demais transições (ENVIADA/EM_NEGOCIACAO/ACEITA/EXPIRADA/CANCELADA) — RPC `pricing_proposal_change_status`. | RLS da RPC. | Path `id`. Body `status` (obrig.), `motivo?`. | **200**. **400** se faltar `status`. |
| `GET /:id/export` | Gera PDF/DOCX da proposta no servidor (`generateProposalPdf`/`generateProposalDocx`), registra exportação (RPC `pricing_proposal_register_export`) antes de devolver o binário. | RLS das RPCs envolvidas. | Query `formato?` (`PDF`\|`DOCX`, default PDF), `modo?` (`'externa'` → EXTERNA, senão INTERNA). | Binário com `Content-Disposition: attachment; filename="OPTIMON_Proposta_<Cidade>_<Parceiro>_<AAAAMMDD>.<ext>"`. **400** formato inválido, **404** não encontrada, **500** falha de geração. |

---

## Proponentes/Parceiros — `/api/partners`

Arquivo: `api/routes/partners.js`. "Proponente" é a tabela `parceiros` (existente desde a Fase 1), estendida — nunca uma tabela paralela. Documentos vão para o bucket privado `documentos` (signed URL de curto prazo, nunca URL pública fixa).

### Mapeamento de erro — `handleError`
`PERMISSAO_NEGADA`/RLS → **403** · "não encontrad" → **404** · `duplicate key`/`already exists`/`unique constraint` (e fallback padrão) → **409** · `obrigatóri`/`inválido`/`violates check constraint`/`foreign key` → **400**.

Helper `logSemanticEventBestEffort` — RPC `pricing_log_semantic_event` em `try/catch` que descarta falha (nunca derruba a resposta principal).

| Rota | O que faz | Autorização | Parâmetros | Resposta |
|---|---|---|---|---|
| `GET /` | Lista proponentes (exclui removidos), ordenado por `nome_fantasia`. | RLS de `parceiros`. | Query `q?` (busca ilike), `ativo?` (`true`\|`false`\|`todos`). | Array (`PROPONENTE_FIELDS`). |
| `GET /:id` | Detalhe. | RLS. | Path `id`. | Objeto. **404**. |
| `POST /` | Cadastra proponente — "RLS já exige COMERCIAL/DIRETOR/ADMINISTRADOR" (comentário). | RLS de `parceiros`. | Body: `razao_social`, `cnpj` (obrig.); demais campos cadastrais opcionais. | **201**. **400** se faltar obrigatório. |
| `PATCH /:id` | Edição parcial. | RLS `parceiros_update` (COMERCIAL/DIRETOR/ADMINISTRADOR) — Node distingue 403 (existe mas RLS bloqueou) de 404 (não existe) via segunda leitura. | Path `id`. Body: qualquer subconjunto de campos cadastrais + `ativo`. | **200**. **400** nenhum campo. **403**/**404** conforme acima. |
| `POST /:id/deactivate` | Desativa (`ativo=false`) + log semântico `PARTNER_DEACTIVATE`. | Mesma RLS do PATCH. | Path `id`. Body `motivo?`. | **200**. Mesmo padrão 403/404. |
| `POST /:id/reactivate` | Reativa (`ativo=true`) + log `PARTNER_REACTIVATE`. | Mesma RLS. | Path `id`. Body `motivo?`. | **200**. |
| `GET /:id/responsaveis` | Lista responsáveis (contatos) do proponente. | RLS de `parceiros_responsaveis`. | Path `id`. Query `incluir_removidos?` (`'true'` — Fase 3, item 3.9). | Array (`RESPONSAVEL_FIELDS`), ordenado por `nome`. |
| `POST /:id/responsaveis` | Cadastra responsável. | RLS. | Path `id`. Body: `nome`, `tipo` (obrig. — `REPRESENTANTE_LEGAL`\|`RESPONSAVEL_COMERCIAL`\|`RESPONSAVEL_FINANCEIRO`\|`RESPONSAVEL_TECNICO`\|`TESTEMUNHA`\|`OUTRO`); demais opcionais. | **201**. **400** se faltar obrig. |
| `PATCH /:id/responsaveis/:respId` | Edição parcial, incl. vínculo de documento comprobatório. | RLS. | Path `id`, `respId`. Body: qualquer subconjunto. | **200**. **400** nenhum campo. **404**. |
| `DELETE /:id/responsaveis/:respId` | Remoção lógica (`ativo:false`, `removido_em:now()`) — nunca DELETE físico. | RLS. | Path `id`, `respId`. | **200** registro marcado removido. **404**. |
| `POST /:id/responsaveis/:respId/restore` | Restaura (`removido_em:null`, `ativo:true`) — rota dedicada, nunca via PATCH genérico. | RLS. | Path `id`, `respId`. | **200**. **404**. |
| `GET /:id/documentos` | Lista documentos do proponente (`proponente_documento=true`, não removidos). | RLS de `documentos`. | Path `id`. | Array (`DOCUMENTO_FIELDS`), ordenado por `criado_em` desc. |
| `POST /:id/documentos` | Upload multipart → Storage privado + linha de metadado. | RLS de `storage.objects` (client escopado ao JWT, nunca service_role). | Path `id`. Multipart campo `arquivo` (obrig., `multer`, limite 20MB, memória). Body `tipo`, `titulo` (obrig.); `responsavel_id?`, `validade?`. | **201**. **400** falta arquivo/tipo/titulo. **502** falha de upload. |
| `GET /documentos/:docId/download` | Signed URL de 300s para download. | RLS de `documentos` decide visibilidade — se a linha não vier, **404** antes de tentar gerar URL. | Path `docId`. | `{ id, titulo, status, url, expira_em_segundos: 300 }`. **404**. **502** falha na geração. |

---

## Auditoria — `/api/audit`

Arquivo: `api/routes/audit.js`. **Mapeamento de erro:** todo erro de RPC vira **400** (sem outra distinção).

| Rota | O que faz | Parâmetros | Resposta |
|---|---|---|---|
| `GET /` | Trilha de auditoria — RPC `pricing_audit_list`. | Query opcionais: `limit?` (100), `entidade?`, `usuario_id?`, `entidade_id?` (só enviado à RPC quando informado, compatibilidade retroativa). | Array. |
| `POST /login` | Registra evento de auditoria de login — RPC `pricing_log_login`. Chamado uma vez pelo frontend logo após `supabase.auth.signInWithPassword()`. | — | **204**. Não é a autenticação em si (sempre feita pelo Supabase Auth/GoTrue diretamente pelo frontend) — só o registro do evento. |

---

## Usuários — `/api/users`

Arquivo: `api/routes/users.js`. Expõe CRUD dos campos cadastrais de `public.usuarios`; RLS (`usuarios_admin_all`: só ADMINISTRADOR escreve, qualquer `authenticated` lê) protege a tabela em si. Usa a **Auth Admin API** (`SUPABASE_SERVICE_ROLE_KEY`, `api/lib/supabaseAdmin.js`) — a única exceção do projeto à regra "nunca service_role no backend" — para convite/gestão de identidade em `auth.users`; compensada pelo helper `assertAdmin`.

### Mapeamento de erro — `handleError`
`error.code === 'SERVICE_ROLE_NAO_CONFIGURADO'` → **501** · `PERMISSAO_NEGADA`/RLS → **403** · "não encontrad"/`NAO_ENCONTRADO` → **404** · `duplicate key`/`already exists`/`unique constraint`/`already registered` → **409** · `obrigatóri`/`inválido`/`violates check constraint`/`foreign key`/`MOTIVO_OBRIGATORIO`/`USUARIO_POSSUI_HISTORICO`/`ULTIMO_ADMINISTRADOR`/`NAO_PERMITIDO` → **400**.

### `assertAdmin(req)` (linha ~163)
Extrai o `sub` do JWT (sem verificar assinatura — já validada a montante), lê a própria linha em `usuarios` com o client escopado ao JWT do chamador (nunca service_role), e exige `perfil==='ADMINISTRADOR' && ativo===true`; senão lança `PERMISSAO_NEGADA`. Existe porque a Auth Admin API não passa pelo Postgres — RLS não a alcança.

`emptyToNull()` normaliza string vazia/só-espaços para `null` antes de INSERT/UPDATE (corrige órfão em `auth.users` causado por `cpf=''` batendo no CHECK). `frontendRedirectUrl()` monta a URL pós-convite/redefinição de senha.

| Rota | O que faz | Autorização | Parâmetros | Resposta |
|---|---|---|---|---|
| `GET /` | Lista usuários (exclui removidos); enriquece com `status_auth` se chamador for ADMINISTRADOR e Admin API disponível. | `assertAdmin` só dentro de try/catch — falha nunca derruba a listagem básica. | Query `perfil?`, `ativo?`, `q?`, `include_orphans?` (só com ADMINISTRADOR+Admin API). | Array (`SELECT_FIELDS` + `status_auth`). Com `include_orphans=true`, acrescenta linhas sintéticas `status_auth:'ORFAO_SEM_PERFIL'`. |
| `GET /health` | Diagnóstico de integridade `auth.users` × `public.usuarios` (não altera nada). | `assertAdmin` obrigatório. | — | `{ verificado_em, auth_admin_disponivel, ..., identidades_auth_orfas, perfis_sem_auth, integro }`. Registrada antes de `/:id` de propósito (evita casar `id="health"`). |
| `GET /:id` | Busca usuário por id. | Nenhuma extra; RLS de leitura. | Path `id`. | Objeto. **404**. |
| `POST /invite` | Cria identidade Auth (convite por e-mail) + perfil, numa chamada. | `assertAdmin` obrigatório. | Body: `nome`, `email`, `perfil` (obrig.); demais opcionais. | **201**. Máquina de estados A/B/C/D (ver Observações). |
| `POST /reconcile` | Completa o perfil para uma identidade Auth já existente (Estado C) — nunca cria identidade nova nem reenvia e-mail. | `assertAdmin` obrigatório + **501** se Admin API indisponível. | Body: `email`, `nome`, `perfil` (obrig.); demais opcionais. | **201**. **409** se já registrado (Estado B). **404** se não existir Auth. |
| `POST /:id/resend-invite` | Reenvia e-mail de convite Auth. | `assertAdmin` obrigatório. | Path `id`. | `{ message }`. **404**. |
| `POST /:id/reset-access` | Dispara e-mail de redefinição de senha (GoTrue), via `anonClient()`. | `assertAdmin` obrigatório. | Path `id`. | `{ message }`. **404**. **502** falha no GoTrue. |
| `POST /:id/deactivate` | `ativo=false` + ban real na Auth se disponível (`ban_duration:'87600h'`). | `assertAdmin` obrigatório (helper `setUserActive`). | Path `id`. Body `motivo?`. | Usuário atualizado + `auth_warning?` se o ban falhar (graceful degradation). **404**. |
| `POST /:id/reactivate` | `ativo=true` + desbane (`ban_duration:'none'`). | `assertAdmin` obrigatório. | Path `id`. Body `motivo?`. | Igual ao deactivate. |
| `POST /:id/hard-delete` | Exclusão física real (diferente do soft-delete de `/deactivate`) — toda a regra (nunca a si mesmo, nunca o último ADMINISTRADOR, varredura de ~19 tabelas, auditoria antes do DELETE) vive na RPC `pricing_usuario_excluir_fisicamente`. | `assertAdmin` obrigatório. | Path `id`. Body `motivo` (obrig., **400** `MOTIVO_OBRIGATORIO` se ausente). | `{ message, auth_warning? }`. Bloqueada se houver qualquer vínculo de auditoria/aprovação/criação. |
| `POST /` | Caminho de recuperação — completa `usuarios` para um `auth.users.id` já existente por outra via. | Nenhuma no Node; RLS `usuarios_admin_all`. | Body: `id`, `nome`, `email`, `perfil` (obrig.); demais opcionais. | **201**. **400**. |
| `PATCH /:id` | Atualização cadastral (inclui `perfil`/`ativo`). | "Só ADMINISTRADOR (RLS)" — Node distingue 403 (existe, bloqueado) de 404 (não existe) via segunda leitura. | Path `id`. Body: qualquer subconjunto, ao menos um. | Objeto atualizado. **400** nenhum campo. |
| `POST /me/touch-access` | Registra "último acesso" do próprio usuário logado. | RPC `usuarios_touch_last_access` (SECURITY DEFINER estreito — só `auth.uid()` próprio). | — | **204**. |

---

## Assinaturas — `/api/signatures`

Arquivo: `api/routes/signatures.js`, exporta **dois** routers: `router` (autenticado) e `webhookRouter` (montado antes de `requireAuth`/`express.json()` — ver subseção especial).

### Mapeamento de erro — `handleError`
`PERMISSAO_NEGADA`/RLS → **403** · "não encontrad"/`NAO_ENCONTRADO` → **404** · `MOTIVO_OBRIGATORIO`/`SEM_SIGNATARIOS`/`STATUS_INVALIDO`/`CONFIGURACAO_INVALIDA` → **400** · `duplicate key`/`unique constraint` → **409** · `obrigatóri`/`inválido`/`violates check constraint`/`foreign key` → **400** · qualquer outra → **409**.

| Rota | O que faz | Autorização | Parâmetros | Resposta |
|---|---|---|---|---|
| `GET /providers` | Lista provedores de assinatura configurados — RPC `pricing_signature_providers_list()`. | Nenhuma extra no Node. | — | Array (`PROVIDER_FIELDS`). `api_key_ref`/`webhook_secret_ref` nunca saem como valor. |
| `POST /providers` | Cria provedor. | RLS `signature_providers_write` (ADMINISTRADOR/DIRETOR). Bloqueia explicitamente `tipo=ICP_BRASIL_HOMOLOGACAO_MOCK` + `ambiente=PRODUCAO` no Node. | Body: `nome`, `tipo`, `ambiente` (obrig.); demais opcionais. | **201** (`PROVIDER_FIELDS_ADMIN`). **400** falta campo ou MOCK+PRODUCAO. |
| `PATCH /providers/:id` | Atualiza provedor. | Mesma RLS. | Path `id`. Body: qualquer subconjunto. | **200**. **400**/**404**. |
| `POST /providers/:id/test-connection` | Testa conexão (`buildProvider().testConnection()`), grava resultado + log de auditoria semântica. | Escrita do resultado protegida por RLS — se bloqueada, `persistido:false` sem erro. | Path `id`. | `{...resultado, persistido}`. **404**. |
| `GET /envelopes` | Lista envelopes, filtros opcionais. | RLS de `signature_envelopes`. | Query `proposta_id?`, `contrato_id?`, `aditivo_id?`, `status?`. | Array (`ENVELOPE_FIELDS`), ordenado por `criado_em desc`. |
| `GET /envelopes/:id` | Detalhe + signatários. | RLS. | Path `id`. | `{...envelope, signatarios}`. **404**. |
| `POST /envelopes` | Cria envelope; se `tipo_documento=PROPOSTA` sem upload, gera PDF automaticamente; envia ao provedor; sobe original ao Storage. | RLS. | Multipart campo `arquivo` (via `multer`, 20MB). Body: `tipo_documento`, `provider_id` (obrig.); `proposta_id?`, `contrato_id?`, `aditivo_id?`. | **201** + `storage_warning?`. **400**/**404**. **502** falha no provedor. **LIMITAÇÃO:** CONTRATO/ADITIVO exigem PDF por upload manual — geração automática a partir de `modelos_contrato` não foi construída nesta fase. |
| `POST /envelopes/:id/signers` | Adiciona signatário — RPC `pricing_signature_signer_add`; replica no provedor best-effort. | RLS da RPC. | Path `id`. Body: `nome`, `email`, `papel` (obrig.); `ordem?`, `cpf?`, `responsavel_id?`. | **201**. **400**/**404**. |
| `POST /envelopes/:id/send` | Envia ao provedor + registra via RPC `pricing_signature_envelope_send`. | RLS. | Path `id`. | **200**. **404**. **502** falha no provedor. |
| `POST /envelopes/:id/cancel` | Cancela envelope — RPC `pricing_signature_envelope_cancel`. | "Só DIRETOR/ADMINISTRADOR" (RLS de `app.cancelar_envelope_assinatura`). | Path `id`. Body `motivo` (obrig.). | **200**. **400**. |
| `GET /envelopes/:id/document` | Signed URL (300s) do documento assinado (ou original). | RLS + Storage. | Path `id`. | `{url, validado, expira_em_segundos:300}`. **404**. **502**. |
| `GET /envelopes/:id/audit` | Eventos + evidências do envelope. | RLS. | Path `id`. | `{eventos, evidencias}`. |
| `POST /envelopes/:id/validate` | Aciona validação — RPC `pricing_signature_validate`; lógica real em `app.validar_assinatura` (`status=ASSINADO` sozinho nunca é prova). | RLS. | Path `id`. | **200**. |

### Webhook — `POST /api/signatures/webhook` (montagem especial, sem JWT de usuário)

Mounting em `server.js` **antes** de `express.json()` e **antes** de `requireAuth` — precisa do corpo bruto para validar HMAC. É a única rota HTTP desta API sem JWT de usuário (quem chama é o provedor externo).

**Autenticidade validada por HMAC-SHA256:** corpo lido via `express.raw({type:'*/*', limit:'5mb'})` e parseado manualmente; o nome da env var do secret é obtido via RPC `pricing_signature_webhook_secret_ref(p_provider_envelope_id)` chamada com `anonClient()` (a RPC devolve só o **nome**, nunca o valor); lê `process.env[secretRef]` (**500** se não configurada); calcula `HMAC-SHA256(secret, corpo_bruto)` e compara com `crypto.timingSafeEqual` contra o header `X-Signature` (ou `X-Webhook-Signature`); só processa (RPC `pricing_signature_webhook_event_by_provider_id`, idempotente por `evento_externo_id`) se bater.

**Body:** `provider_envelope_id`, `evento_externo_id`, `tipo_evento` (obrig.); demais campos de evento opcionais. **Resposta:** **200** com retorno da RPC. **400** JSON malformado/campo obrigatório ausente. **404** lookup do secret não encontra o envelope. **401** HMAC não bate. **500** secret não configurado.

---

## Contratos — `/api/contracts`

Arquivo: `api/routes/contracts.js`. A geração automática de contrato ("GERAR CONTRATO") e a ativação com checagem de conflito de infraestrutura são SQL puro (`app.gerar_contrato_de_proposta`/`app.ativar_contrato`) — as rotas só expõem essas funções.

### Mapeamento de erro — `handleError`
`PERMISSAO_NEGADA`/`REQUIRES_APPROVAL`/RLS → **403** · "não encontrad"/`NAO_ENCONTRADO` → **404** · `MOTIVO_OBRIGATORIO`/`STATUS_INVALIDO`/`PRAZO_MINIMO`/`ASSINATURA_PENDENTE`/`CONFLITO`/`INFRA_NAO_ALOCADA` → **400** · `duplicate key`/`unique constraint` → **409** · `obrigatóri`/`inválido`/`violates check constraint`/`foreign key` → **400** · qualquer outra → **409**.

| Rota | O que faz | Autorização | Parâmetros | Resposta |
|---|---|---|---|---|
| `GET /` | Lista contratos — RPC `pricing_contracts_list`. | RLS da RPC. | Query `filtro?` (`TODOS`\|`ATIVOS`\|`EM_ASSINATURA`\|`EXPIRANDO`\|`EXPIRADOS`\|`CANCELADOS`\|`SUSPENSOS`). | Array. |
| `GET /:id` | Detalhe completo: contrato+parceiro+cidade, pricing_config, fibras alocadas, aditivos, reajustes, envelopes CONTRATO, guardrails (`contrato_regras`), clientes reservados, ativos — tudo via `Promise.all`. | RLS por tabela. | Path `id`. | Objeto agregado. **404**. |
| `PATCH /:id/regras` | Edita guardrails contratuais (exclusividade, fibra de terceiros, rede própria, preferência, etc.) via `upsert`. | "RLS já restringe a DIRETOR/ADMINISTRADOR" (`contrato_regras_write`). | Path `id`. Body: qualquer subconjunto dos ~14 campos de guardrail. | **200**. |
| `POST /:id/clientes-reservados` | Adiciona cliente reservado (ex.: exceção Prefeitura). | "RLS restringe a DIRETOR/ADMINISTRADOR". | Path `id`. Body `cliente_nome` (obrig.); `cnpj_cpf?`, `cidade_id?`, `motivo?`. | **201**. **400**. |
| `PATCH /:id/clientes-reservados/:reservaId` | Libera/re-reserva cliente. | RLS. | Path `id`, `reservaId`. Body `status` (obrig., `RESERVADO`\|`LIBERADO`). | **200**. **400**/**404**. |
| `GET /:id/minuta` | Gera minuta de contrato em PDF/DOCX (Fase 3, item 3.7) — `generateContratoPdf`/`generateContratoDocx`, dados via RPC `pricing_contrato_documento_dados`, exportação registrada via `pricing_contrato_registrar_exportacao_minuta` antes do binário. | RLS das RPCs. | Query `formato?` (`PDF`\|`DOCX`, default PDF). | Binário `Content-Disposition: ...OPTIMON_Minuta_<Cidade>_<RazaoSocial>_<AAAAMMDD>.<ext>`. **400**/**404**/**500**. Documento sempre rotulado "MINUTA SUJEITA À APROVAÇÃO JURÍDICA". |
| `POST /generate` | "GERAR CONTRATO" a partir de proposta assinada — RPC `pricing_contract_generate_from_proposal`. | RLS/RPC. | Body `proposta_id` (obrig.); `prazo_minimo_excecao?`, `motivo_excecao_prazo?`. | **201**. **400**. |
| `POST /:id/activate` | Ativa contrato (checagem de conflito de infraestrutura) — RPC `pricing_contract_activate`. | RLS/RPC. | Path `id`. | **200**. **400** `CONFLITO`/`INFRA_NAO_ALOCADA`. |
| `POST /:id/reajuste` | Aplica reajuste (nunca reescreve histórico — sempre novo evento) — RPC `pricing_contract_apply_reajuste`. | RLS/RPC. | Path `id`. Body `percentual` (obrig.); `competencia_base?`, `indice_id?`, `motivo?`. | **201** `{reajuste_id}`. **400**. |
| `GET /:id/aditivos` | Lista aditivos do contrato. | RLS. | Path `id`. | Array, ordenado por `numero`. |
| `POST /:id/aditivos` | Cria aditivo em RASCUNHO. | "RLS `contrato_aditivos_insert` restringe a COMERCIAL/DIRETOR/ADMINISTRADOR". | Path `id`. Body `numero`, `tipo`, `descricao` (obrig.); `data?`, `inicio_vigencia?`, `fim_vigencia?`. | **201**. **400**/**409** (unicidade `(contrato_id,numero)`). |
| `PATCH /:id/aditivos/:aditivoId` | Se `status` presente → RPC `pricing_addendum_change_status` (`aprovado_por` sempre `auth.uid()` no banco, nunca do body); senão UPDATE direto de `descricao`/`inicio_vigencia`/`fim_vigencia`. | RPC `app.aprovar_aditivo` ou RLS `contrato_aditivos_update`. | Path `id`, `aditivoId`. Body `status?` **ou** campos de conteúdo. | **200**. **400**/**404**. |
| `POST /:id/aditivos/:aditivoId/send-signature` | Vincula envelope já criado (via `/api/signatures/envelopes`) ao aditivo — RPC `pricing_addendum_send_signature`. | RLS. | Path `id`, `aditivoId`. Body `envelope_id` (obrig.). | **200**. **400**. |
| `POST /:id/aditivos/:aditivoId/activate` | Ativa aditivo — RPC `pricing_addendum_activate`. | RLS. | Path `id`, `aditivoId`. | **200**. |
| `GET /dashboard/resumo` | Resumo do dashboard contratual — RPC `pricing_dashboard_contratual`. | RLS. | — | Objeto. |
| `POST /dashboard/gerar-alertas` | Gera alertas contratuais — RPC `pricing_alerts_generate`. | RLS. | — | `{alertas_criados}`. |
| `GET /dashboard/alertas` | Lista alertas — tabela `alertas`. | RLS. | Query `resolvido?` (`'false'`/ausente → não resolvidos; `'true'` → resolvidos). | Array, ordenado por `criado_em desc`. |
| `POST /dashboard/alertas/:id/resolver` | Resolve um alerta (Fase 3, item 3.11) — RPC `pricing_alerta_resolver`. | "DIRETOR/FINANCEIRO/ENGENHARIA/ADMINISTRADOR" (RLS/RPC). | Path `id`. | **200**. **403**/**404**. |
| `GET /dashboard/capacidade` | Capacidade agregada do portfólio (Fase 3, item 3.3) — RPC `pricing_dashboard_capacidade`. | RLS. | — | Objeto. |
| `GET /dashboard/cenarios-portfolio` | Receita acumulada em 3 cenários nos horizontes pedidos (Fase 3, item 3.3) — RPC `pricing_dashboard_cenarios_portfolio`. **Estimativa** a partir do MRR contratado hoje. | RLS. | Query `horizontes?` (CSV de meses, default `12,36,48,60`). | Objeto. |

---

## Relatórios — `/api/reports`

Arquivo: `api/routes/reports.js`. Cada rota chama uma única wrapper SQL pública, "security invoker" (roda sob a RLS de quem chamou) — nenhuma regra de negócio/RBAC vive no arquivo. **Limitações documentadas no próprio código:** receita por POP não é segregável; faturamento real/revenue-share real/take-or-pay real/inadimplência dependem de `medicoes_mensais`, ainda schema-only (sem dado real).

**Mapeamento de erro:** todo erro de RPC → **400**; `:tipo` desconhecido → **404**.

**Dicionário `REPORTS`** (tipo → RPC → nome de arquivo CSV): `receita-por-cidade` → `pricing_relatorio_receita_por_cidade`; `receita-por-parceiro` → `pricing_relatorio_receita_por_parceiro`; `capacidade-por-pop` → `pricing_relatorio_capacidade_por_pop`; `clientes-por-pon` → `pricing_relatorio_clientes_por_pon`; `contratos` → `pricing_relatorio_contratos`; `reajustes` → `pricing_relatorio_reajustes`.

| Rota | O que faz | Parâmetros | Resposta |
|---|---|---|---|
| `GET /:tipo` | Relatório como JSON (array de linhas). | Path `tipo` (deve estar em `REPORTS`). | Array. **404** se `tipo` desconhecido. |
| `GET /:tipo/csv` | Mesmo relatório, como download CSV (`toCsv()` de `../lib/csvReport`). | Path `tipo`. | CSV, `Content-Disposition: attachment; filename="OPTIMON_<filename>_<AAAA-MM-DD>.csv"`. |
| `GET /faturamento-real/status` | Status (disponível/não) do relatório de faturamento real — fora do dicionário `REPORTS` por ter formato de retorno diferente. | — | JSON cru da RPC `pricing_relatorio_faturamento_real`. **Nota de discrepância:** o comentário do código rotula esta rota como `GET /faturamento-real`, mas o path real registrado é `/faturamento-real/status` — uma chamada a `/faturamento-real` sem `/status` cai na rota genérica `GET /:tipo`, que devolve 404 (tipo inexistente em `REPORTS`). |

---

## Utilitários fora de `requireAuth`

| Rota | O que faz |
|---|---|
| `GET /health` | `{ status: 'ok', service: 'optimon-api' }` — contrato exato exigido pelo checklist de deploy. Sem autenticação. |
| `GET /api/version` | Informações de versão do build (`getVersionInfo()`) — nunca inclui segredos. Sem autenticação. |

---

## Contagem de endpoints documentados

Pricing (18) + Cidades (6) + Infraestrutura (24) + Simulações (2) + Propostas (11) + Proponentes (16) + Auditoria (2) + Usuários (13) + Assinaturas (13 autenticadas + 1 webhook) + Contratos (20) + Relatórios (3) + Utilitários (2) = **131 endpoints HTTP**, cada um lido no código-fonte real antes de ser listado aqui.
