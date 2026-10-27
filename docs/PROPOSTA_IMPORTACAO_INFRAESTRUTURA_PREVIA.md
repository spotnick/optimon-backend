# IMPORTAÇÃO DE INFRAESTRUTURA — PRÉVIA
## Diagnóstico da arquitetura atual e proposta técnica (sem implementação)

Data: 23/09/2026. Escopo: só análise e proposta, conforme instrução explícita ("NÃO IMPLEMENTE AINDA"). Baseado em leitura direta das migrations reais do projeto (`supabase/migrations/`, ~130 arquivos, da Fase 1 à Fase 3.11.6), não em suposição.

---

## 1. Tabelas existentes relacionadas à infraestrutura

Cadeia real, na ordem de dependência (confirmada nas migrations `20260824090400`, `20260824090500`, `20260825100000/100100/100200`):

| Tabela | Chave natural hoje | Observação relevante para importação |
|---|---|---|
| `cidades_infra` | `unique(nome, uf)`, `unique(codigo_ibge)` | Único ponto de entrada da cadeia. `km_rede` é referência econômica, não estrutural. |
| `infra_pops` | `unique(cidade_id, codigo)` | 1 cidade → N POPs (corrigido na Fase 1.1 — nunca assumir 1:1). |
| `infra_segmentos` | **nenhuma** (`nome`/`origem`/`destino` livres, sem unique) | É exatamente o caso "E-000, E-001..." do levantamento de Piraí do Sul — hoje não há como o banco garantir que duas linhas com o mesmo código de campo sejam a mesma caixa de emenda. |
| `infra_cabos` | `unique(segmento_id, identificacao)`, `pop_id` (FK, nullable só por herança da Fase 1) | Pertence a 1 segmento e a 1 POP. |
| `infra_fibras` | `unique(cabo_id, numero_fibra)` | 3 dimensões de status desde a Fase 1.1: `status_operacional` (ATIVA/MANUTENCAO/ROMPIDA/DESATIVADA, gerido por Engenharia), `status_comercial` (LIVRE/RESERVADA/BLOQUEADA, nunca tocado por vínculo de contrato), `status_contratual` (DISPONIVEL/VINCULADA, mantido só pelo trigger de contrato). Campo legado `status` (LIVRE/OCUPADA/RESERVADA/LOCADA/MANUTENCAO/BLOQUEADA) ainda existe, DEPRECATED, só por compatibilidade. |
| `infra_postes` | **nenhuma** (`identificacao` é texto opcional) | Representa um LOTE de postes (campo `quantidade`), não 1 poste = 1 linha. `segmento_id` é nullable (`on delete set null`). |
| `infra_portas_pon` | `unique(fibra_id)`, `unique(pop_id, codigo_porta)` | 1 fibra → no máximo 1 porta PON. `capacidade_disponivel`/`taxa_ocupacao` são colunas geradas (nunca escritas diretamente). |
| `custos_infraestrutura` | — | Referencia `cidade_id`/`pop_id`/`poste_id`/`cabo_id`/`ativo_id`/`contrato_id`, todos `on delete set null` exceto `cidade_id` (`restrict`). Fora do escopo direto da importação de campo, mas é consumidor indireto (custo de poste). |
| `contrato_fibras` | `unique(fibra_id) where ativo`, `unique(porta_pon_id) where ativo` | **Não é alterado pela importação** — é o vínculo comercial. É o principal ponto de CONFLITO: uma fibra que o levantamento diz "LIVRE" mas que tem uma linha ativa aqui é uma contradição grave. |

Não existe, em nenhuma migration, qualquer estrutura de staging, importação, upload de planilha ou versionamento de levantamento. A funcionalidade pedida é 100% nova — confirmado por busca textual em todas as migrations (só ocorrências de "IMPORTANTE", nenhuma de "importação"/"staging"/"levantamento"/"planilha" como conceito de negócio).

## 2. Relacionamentos

```
cidades_infra
  └─ infra_pops (cidade_id)
       └─ infra_cabos (pop_id, segmento_id)
            └─ infra_fibras (cabo_id)
                 └─ infra_portas_pon (fibra_id, pop_id — precisa bater com o pop_id do cabo, validado por trigger)
                      └─ contrato_fibras (porta_pon_id) ─→ contratos
  └─ infra_segmentos (cidade_id)
       └─ infra_cabos (segmento_id)  [mesmo cabo acima]
       └─ infra_postes (segmento_id, nullable)
custos_infraestrutura ─→ (cidade_id obrigatório; pop_id/poste_id/cabo_id/contrato_id opcionais, todos SET NULL)
```

Todas as FKs entre as tabelas de infraestrutura em si são `ON DELETE RESTRICT` (a cadeia nunca perde integridade por exclusão em cascata) — mas nenhuma é relevante para a importação, porque a importação **nunca fará DELETE** na infraestrutura oficial (regra de segurança do próprio pedido). O relacionamento que importa aqui é RLS + auditoria: toda escrita em qualquer uma dessas 7 tabelas hoje passa por `app.tem_perfil('ENGENHARIA','ADMINISTRADOR')` (policy `*_write`, `for all`) — a importação vai precisar do mesmo gate, nunca um caminho de escrita paralelo mais permissivo.

## 3. Onde a staging deve ser criada

Schema novo dedicado: **`staging`** (paralelo a `public` e `app`, mesmo padrão de separação já usado pelo projeto — `app` para funções/RBAC, `public` para dados/API). Motivos:
- Isola fisicamente dados não-homologados de dados oficiais — impossível uma `SELECT *` acidental em código de produção misturar as duas coisas.
- Permite dar aos dados de staging uma política de RLS totalmente diferente da oficial (ex.: Engenharia vê e edita livremente sua própria prévia, sem o RBAC mais restrito de escrita da infraestrutura oficial) sem tocar em nenhuma policy existente.
- `DROP SCHEMA staging CASCADE` nunca é uma operação real proposta aqui (a regra pede explicitamente para não criar reset geral) — é só um argumento de design: o isolamento por schema deixa claro, para qualquer pessoa lendo o banco depois, que nada ali é oficial até ser aprovado.

Alternativa descartada: prefixar tabelas em `public` com `staging_*`. Descartada porque mistura namespace com as 30+ tabelas oficiais já existentes em `public`, dificulta granular RLS por schema, e não seria "aditivo" no mesmo sentido limpo de um schema novo.

## 4. Tabelas novas necessárias

### 4.1 Controle da importação (schema `staging`)

**`staging.importacoes`** — 1 linha por importação, com toda a metadata pedida:
`id uuid pk`, `status text` (enum-like, ver seção 9), `arquivo_nome text`, `arquivo_hash text`, `arquivo_storage_path text` (o Excel original fica em Supabase Storage, não no banco), `total_registros integer`, `resumo_validacao jsonb`, `criado_por uuid references usuarios(id)`, `criado_em timestamptz`, `aprovado_por uuid references usuarios(id)`, `aprovado_em timestamptz`, `revertido_por uuid references usuarios(id)`, `revertido_em timestamptz`, `motivo_reversao text`, `motivo_rejeicao text`, `erro_aplicacao text` (preenchido só se a aprovação falhar — ver seção 8).

**`staging.importacao_itens`** — 1 linha por registro da planilha, independente do tipo de entidade (cidade/POP/segmento/cabo/fibra/poste/porta/cliente reservado). Estrutura genérica com uma coluna `tipo_entidade text` e um `dados jsonb` (o registro cru, como veio da planilha, nunca reinterpretado destrutivamente) + colunas de resultado da comparação: `classificacao text` (NOVO/ALTERADO/SEM_ALTERACAO/CONFLITO/INVALIDO), `entidade_oficial_id uuid` (nullable — preenchido quando a comparação encontra correspondência oficial), `valor_atual jsonb` (snapshot do registro oficial no momento da prévia, só quando `entidade_oficial_id` não é nulo), `valor_novo jsonb` (o que a importação propõe), `diffs jsonb` (campos que mudam, já calculados, para a tela de prévia não precisar recalcular), `inconsistencias jsonb` (lista de alertas — ex. "fibra OCUPADA marcada como disponível"), `linha_planilha integer` (rastreabilidade até a célula original).

Por que genérico (1 tabela para todos os tipos) em vez de uma tabela de staging por entidade (`staging.cidades`, `staging.pops`, ...): a planilha real de Engenharia não chega estruturada por tabela — chega por aba/seção livre, com nomenclatura que muda de levantamento para levantamento (o próprio exemplo do pedido mostra isso: "PAÇO" e "E-000" são só texto até serem classificados). Um `jsonb` por item, com `tipo_entidade` decidido na etapa de validação (não no upload), dá a flexibilidade que a REGRA DE POPs exige ("não classificar automaticamente referências de rede como POP") sem precisar de uma migration nova toda vez que Engenharia mudar o layout da planilha. O preço dessa flexibilidade é validação em código de aplicação (Node), não em constraint de banco — mitigado pelas checagens da seção 5.

### 4.2 Rastreabilidade de alteração aplicada (para a reversão funcionar de verdade)

**`staging.importacao_alteracoes`** — 1 linha por alteração REAL aplicada à infraestrutura oficial no momento da aprovação (não confundir com `importacao_itens`, que existe antes da aprovação). Colunas: `id uuid pk`, `importacao_id uuid references staging.importacoes(id)`, `tabela_oficial text`, `registro_id uuid` (o id real em `public.infra_*`), `operacao text` (INSERT/UPDATE), `valor_anterior jsonb` (null se foi INSERT), `valor_aplicado jsonb`, `aplicado_em timestamptz`.

Esta tabela é o motor da reversão (seção 6): reverter uma importação nunca é "reprocessar a planilha ao contrário", é "para cada linha desta tabela, na ordem inversa, desfazer exatamente aquela operação — se foi INSERT, apagar o registro (se nada mais depende dele); se foi UPDATE, restaurar `valor_anterior` campo a campo". Isso é o que torna possível cumprir a regra 9: reverter só o que aquela importação tocou, preservando tudo que entrou depois por outra fonte.

### 4.3 Nada de novo nas tabelas oficiais

Nenhuma tabela oficial (`cidades_infra`, `infra_pops`, ...) precisa de coluna nova. A rastreabilidade "este registro veio de qual importação" fica só em `staging.importacao_alteracoes`, nunca como coluna em `infra_*` — evita alterar migrations existentes (regra explícita) e evita acoplar o schema oficial a um conceito (importação) que é operacional, não estrutural.

## 5. Constraints que devem ser criadas

- `staging.importacoes.status` — `check (status in ('RECEBIDA','EM_VALIDACAO','PREVIA','APROVADA','IMPORTADA','REJEITADA','DESCARTADA','REVERTIDA'))`, exatamente a lista pedida.
- Transições de status **não** ficam só numa constraint declarativa (Postgres não tem "state machine" nativa confiável para isso) — ficam garantidas por uma função central `app.mudar_status_importacao(...)` que é o único caminho permitido de UPDATE em `status` (reforçado por RLS: nenhuma policy de UPDATE direto em `staging.importacoes` para `authenticated` além dessa função, mesmo padrão SECURITY DEFINER já usado em `app.arquivar_pop`/`app.restaurar_pop`).
- `staging.importacao_itens.classificacao` — `check (classificacao in ('NOVO','ALTERADO','SEM_ALTERACAO','CONFLITO','INVALIDO'))`.
- `staging.importacao_itens.tipo_entidade` — `check (tipo_entidade in ('CIDADE','POP','SEGMENTO','CABO','FIBRA','POSTE','PORTA_PON','CLIENTE_RESERVADO'))` — lista fechada, nunca aberta, para a UI de prévia poder ter uma seção fixa por tipo.
- Validação de fibra (regra de negócio explícita do pedido) — **em duas camadas**, exatamente como pedido ("a interface deve sinalizar... o sistema deve implementar essa proteção também na camada de aplicação/banco"):
  1. Na aplicação (Node), ao processar cada item de fibra: se `status = OCUPADA` e `disponivel_optimon = SIM`, marca `classificacao = INVALIDO` com a inconsistência explícita, nunca deixa passar como NOVO/ALTERADO silenciosamente.
  2. No banco, como reforço estrutural: um `CHECK` (ou trigger, se a lógica precisar olhar duas colunas com nomes variáveis dentro do `jsonb`) em `staging.importacao_itens` que bloqueia a *aprovação* de qualquer item com essa combinação — nunca deixa a proteção depender só do código Node. Como o dado bruto é `jsonb` (seção 4.1), o CHECK real fica na função de aplicação (`app.aplicar_importacao`, seção 8), que recusa qualquer item OCUPADA+disponível antes de tocar a infraestrutura oficial — e adicionalmente, a tabela oficial `infra_fibras` ganha o mesmo tipo de proteção meses à frente, se o time decidir formalizar OCUPADA/disponível como colunas reais em vez de só o enum atual (fora do escopo desta importação — está listado aqui só para não perder a intenção da regra).
- `staging.importacao_alteracoes` — `unique(importacao_id, tabela_oficial, registro_id)`: uma importação nunca aplica duas operações no mesmo registro oficial (evita duplicidade de rastro de reversão).
- Trigger de imutabilidade em `staging.importacao_alteracoes`, mesmo padrão de `auditoria` (`trg_auditoria_imutavel`/`fn_bloquear_alteracao_auditoria`): depois de gravada, uma linha de alteração aplicada nunca é editada nem apagada — só a reversão formal (função dedicada) pode neutralizá-la, e mesmo assim sem apagar a linha (ver seção 6).

## 6. Como será feita a reversão

1. `app.reverter_importacao(p_importacao_id uuid, p_motivo text)`, só ADMINISTRADOR/DIRETOR (mesmo gate de `app.restaurar_*`), SECURITY DEFINER.
2. Exige `status = 'IMPORTADA'` (nunca reverte uma importação que nunca foi aplicada, nem uma já revertida).
3. Para cada linha de `staging.importacao_alteracoes` desta importação, **na ordem inversa da aplicação** (mais recente primeiro — importante porque a ordem de aplicação respeita dependência de FK, então desfazer precisa ser exatamente o espelho):
   - Antes de tocar o registro, **checa se ele foi alterado depois da importação**: compara o `atualizado_em` atual do registro oficial com o `aplicado_em` desta linha (ou, mais robusto, compara o snapshot inteiro salvo em auditoria/`valor_aplicado` contra o estado atual). Se algo mudou depois — **não sobrescreve**: marca esse item como `CONFLITO_POS_IMPORTACAO` num relatório de reversão parcial e segue para o próximo, exatamente como pedido ("Este registro foi alterado após a importação #XXXXX...").
   - Se não houve alteração posterior: para UPDATE, restaura `valor_anterior`; para INSERT, tenta apagar o registro — e se ele tiver dependente (outra FK `RESTRICT` apontando pra ele, ex. um cabo que passou a ter fibras cadastradas por outro caminho depois), o DELETE falha com FK violation, capturado e reportado como "não pôde reverter — tem dependência criada depois", nunca um erro fatal que aborta a reversão inteira.
4. A função roda em **transação única, tudo-ou-nada por padrão**, mas com um relatório detalhado por item (não é um DELETE em massa — é item a item, com resultado individual reportado: revertido / pulado por conflito posterior / pulado por dependência). Isso é diferente do reset visto na Fase 3.11.6 (que era um evento único de transição, sem dado real envolvido) — aqui há dado de produção real o tempo todo, então a reversão **nunca aborta tudo por causa de 1 item problemático**; ela reverte o que pode e relata claramente o que não pôde, deixando a decisão final (revisar manualmente) para o usuário — coerente com a regra 9 ("não sobrescrever silenciosamente").
5. Ao final: `staging.importacoes.status = 'REVERTIDA'`, `revertido_por`/`revertido_em`/`motivo_reversao` preenchidos, e um novo evento de auditoria semântica (`IMPORT_REVERT`, ver seção 9) — a auditoria da importação original **nunca é apagada** (regra explícita), a reversão só soma um evento novo.

## 7. Como evitar conflitos com alterações posteriores

Este é o mesmo mecanismo do item 3 acima, generalizado para dois momentos distintos:

- **Na aprovação** (antes de aplicar): a prévia (`importacao_itens.valor_atual`) é um snapshot tirado no momento da VALIDAÇÃO/PRÉVIA. Entre a prévia e a aprovação, alguém pode ter editado manualmente o mesmo registro oficial (ex.: Engenharia corrigiu uma fibra pela tela normal enquanto a importação ainda estava em revisão). Por isso, `app.aplicar_importacao` **revalida cada item contra o estado oficial atual imediatamente antes de aplicar** (não confia no snapshot antigo) — se o estado oficial mudou desde a prévia, aquele item específico é reclassificado ali mesmo (pode virar CONFLITO) e a aplicação pausa esse item para decisão humana, em vez de aplicar sobre uma base que já não é a que foi revisada.
- **Na reversão** (depois de aplicar): exatamente o mecanismo descrito na seção 6.3.

Em nenhum dos dois casos existe sobrescrita silenciosa — é sempre "acusa o conflito, não aplica aquele item, segue com os outros, deixa humano decidir".

## 8. Transação de aprovação (tudo-ou-nada na aplicação, diferente da reversão item-a-item)

`app.aplicar_importacao(p_importacao_id uuid)`, só ENGENHARIA/ADMINISTRADOR (mesmo perfil de escrita da infraestrutura oficial), SECURITY DEFINER:

1. Exige `status = 'PREVIA'` (nunca aplica uma importação ainda em validação, rejeitada, ou já aplicada).
2. Revalida todos os itens (seção 7). Se **qualquer** item vira CONFLITO/INVALIDO nesta revalidação, a função inteira aborta sem aplicar nada — `RAISE EXCEPTION` com a lista de itens problemáticos, `status` permanece `PREVIA` (nunca migra para um estado de erro que pareça "meio aplicado"). Isso é diferente da reversão de propósito: aprovar é um evento comercial único e completo — ou a planilha inteira homologada entra, ou nenhuma parte dela entra, para nunca deixar a infraestrutura oficial parcialmente coerente com uma prévia que já não é válida.
3. Se tudo revalida limpo: aplica os itens NOVO como INSERT e ALTERADO como UPDATE, respeitando a ordem de dependência da cadeia (cidade → POP → segmento → cabo → fibra → porta PON → poste — mesma ordem da seção 2), gravando 1 linha em `staging.importacao_alteracoes` por operação.
4. Cada INSERT/UPDATE real dispara os triggers de auditoria já existentes nas tabelas oficiais que os têm (hoje: nenhuma das 7 tabelas de infraestrutura tem `trg_aud_*` — só `usuarios`, `contratos`, `contrato_regras`, `contrato_clientes_reservados`, `pricing_parametros`, `pricing_versions`, `medicoes_mensais`, `ativos`, `integracoes` têm, conforme a migration `20260824091700_auditoria.sql`). Isso é um achado relevante: hoje uma alteração manual em `infra_fibras`/`infra_pops`/etc. pela tela normal **não** gera evento em `auditoria` automaticamente. A importação vai ser a auditada de qualquer forma (via `app.registrar_auditoria_semantica`, evento único por importação — não uma linha por registro, para não inflar a auditoria em milhares de eventos numa planilha grande), mas isso expõe uma lacuna pré-existente (infraestrutura sem auditoria automática) que vale reportar ao usuário como achado, não corrigir de propósito aqui (fora do escopo pedido).
5. Se **qualquer** DELETE/INSERT/UPDATE real falhar por qualquer motivo durante a aplicação (FK inesperada, constraint, etc.): `ROLLBACK` automático de tudo (é uma função só, uma transação implícita — mesmo mecanismo comprovado no reset de homologação da Fase 3.11.6), `status` migra para um estado de erro (`REJEITADA`, com `erro_aplicacao` preenchido com o motivo), nunca fica com `status = 'IMPORTADA'` e dado pela metade. Isso cumpre literalmente a regra "nunca deixar a infraestrutura oficial parcialmente importada".
6. Sucesso: `status = 'IMPORTADA'`, `aprovado_por`/`aprovado_em` gravados, evento de auditoria `IMPORT_APPLY`.

## 9. Auditoria e ações novas

Reaproveita 100% `public.auditoria` + `app.registrar_auditoria_semantica` (mesma tabela/função únicas do sistema desde a Fase 1 — nunca uma auditoria paralela). Só acrescenta ações à whitelist existente (mesmo padrão aditivo já usado 3 vezes nas Fases 2.3.1/2.5/2.5.1 — `ALTER TABLE ... DROP CONSTRAINT / ADD CONSTRAINT` com a lista antiga inteira + as novas, nunca removendo nenhuma):
`IMPORT_RECEIVE`, `IMPORT_VALIDATE`, `IMPORT_PREVIEW_READY`, `IMPORT_APPROVE`, `IMPORT_APPLY`, `IMPORT_APPLY_FAILED`, `IMPORT_REJECT`, `IMPORT_DISCARD`, `IMPORT_REVERT`.

Observação de compatibilidade a confirmar antes de implementar: a migration `20260920090000` mostra `app.registrar_auditoria_semantica` com assinatura de 6 parâmetros (`p_entidade, p_entidade_id, p_acao, p_motivo, p_valor_anterior, p_valor_novo`), mas migrations posteriores da Fase 3.11.x podem ter criado uma segunda versão com mais parâmetros por `CREATE OR REPLACE` com assinatura diferente (padrão de overload já visto e comentado várias vezes no próprio código do projeto — "CREATE OR REPLACE só substitui mesma assinatura"). Antes de implementar, é preciso listar as funções reais com `\df app.registrar_auditoria_semantica` para saber qual assinatura está de fato ativa hoje, em vez de presumir.

## 10. Como preservar RLS

Nenhuma policy existente é alterada. Padrão a replicar (idêntico ao já usado em `infra_pops`/`infra_cabos`/etc., migration `20260825101300_rls_fase11.sql`):

- `staging.importacoes` / `staging.importacao_itens`: `enable row level security`; `select` para `authenticated` com `using (true)` (qualquer perfil pode ver prévias — decisão a confirmar com o usuário: talvez SELECT deva ser restrito a ENGENHARIA/ADMINISTRADOR/DIRETOR, já que são dados internos de levantamento, não comerciais — sinalizo como pergunta aberta, não decido sozinho); `insert` (upload) para `ENGENHARIA`/`ADMINISTRADOR`; nenhum `update`/`delete` direto para `authenticated` — toda mudança de estado passa pelas funções `app.*` (SECURITY DEFINER), mesmo padrão de `app.restaurar_pop` etc. já comprovado necessário (evita o bug real já documentado no próprio código: perfil sem policy de escrita direta faz o UPDATE afetar 0 linhas silenciosamente se a função não for SECURITY DEFINER).
- `staging.importacao_alteracoes`: só leitura para `authenticated` (`ENGENHARIA`/`ADMINISTRADOR`/`DIRETOR`/`AUDITOR`), nenhum INSERT/UPDATE/DELETE direto — só as funções `app.aplicar_importacao`/`app.reverter_importacao` escrevem.
- Nenhuma policy de `infra_*` muda: a importação escreve nessas tabelas através de `app.aplicar_importacao`, que já roda como o dono das tabelas (SECURITY DEFINER) — não precisa e não deve ganhar uma policy nova "importação pode escrever infra", porque isso abriria um caminho de escrita que não respeita as mesmas regras de quem pode editar infraestrutura manualmente.

---

## Plano de implementação por etapas (depois de aprovado)

1. **Migration 1 — schema + tabelas de staging.** `create schema staging`; `staging.importacoes`, `staging.importacao_itens`, `staging.importacao_alteracoes`; constraints da seção 5; RLS da seção 10. 100% aditiva, zero risco à infraestrutura oficial (não referencia nada em `infra_*` com FK de escrita, só leitura).
2. **Migration 2 — auditoria.** `ALTER TABLE auditoria ADD CONSTRAINT` com as 9 ações novas (mesmo padrão das 3 migrations anteriores que já fizeram isso); confirmar antes a assinatura real de `app.registrar_auditoria_semantica` (ver nota da seção 9).
3. **Migration 3 — funções de ciclo de vida.** `app.mudar_status_importacao`, `app.revalidar_item_importacao` (a função de comparação NOVO/ALTERADO/SEM_ALTERACAO/CONFLITO/INVALIDO, chamável isoladamente para poder ser testada sozinha antes de existir aplicação real), sem ainda `aplicar`/`reverter`.
4. **Migration 4 — aplicação e reversão.** `app.aplicar_importacao`, `app.reverter_importacao`, wrappers `public.*` SECURITY INVOKER + GRANT (mesmo padrão de todas as outras funções do projeto expostas ao PostgREST).
5. **Validação local exaustiva antes de qualquer entrega** (mesmo padrão usado o projeto inteiro): fixtures reais simulando cada `classificacao` possível, teste adversarial de reversão com alteração posterior (deve bloquear, não sobrescrever), teste de aplicação parcialmente inválida (deve abortar tudo, nunca aplicar pela metade), teste do CHECK de fibra OCUPADA+disponível nas duas camadas.
6. **Camada de aplicação (Node) — fora do escopo desta análise de banco**, mas necessária para o fluxo completo: endpoint de upload (parse do Excel → popula `staging.importacao_itens` cru), endpoint de validação/classificação (chama `app.revalidar_item_importacao` por item), tela de prévia (consome os itens já classificados), endpoints de aprovar/descartar/reverter (chamam os wrappers `public.*`). Cada um destes só deve ser desenhado em detalhe quando chegarmos nesta etapa — não antecipado aqui para não misturar decisão de banco com decisão de API antes da hora.

---

## Perguntas em aberto para decidir antes de implementar

1. **SELECT de `staging.importacoes`/`importacao_itens`**: qualquer perfil autenticado, ou só ENGENHARIA/ADMINISTRADOR/DIRETOR? (Seção 10.)
2. **Confirmar a assinatura real e atual de `app.registrar_auditoria_semantica`** antes da Migration 2 — pode ter mais de uma versão (overload) hoje, e a nova ação `IMPORT_*` precisa entrar na que está de fato em uso pelo restante do código.
3. **Onde o Excel original fica fisicamente**: Supabase Storage (bucket novo, ex. `levantamentos/`) é a opção natural, mas confirmar se já existe algum padrão de bucket para uploads administrativos (a Fase 2.5 criou `storage_setup_fase25.sql` para o prefixo `propostas/`) antes de propor um novo prefixo.
4. **Tamanho esperado de planilha** (linhas por levantamento) — importa para decidir se a validação/classificação roda síncrona (resposta HTTP direta) ou precisa de um job assíncrono; não dá para dimensionar isso sem essa informação.
