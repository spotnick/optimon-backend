# OptiMap — Fase 4: coleta por município e importação de postes de referência

**Status:** construída, testada e com **piloto real concluído no sandbox local** (17 municípios coletados, 15 importados, 130.727 postes). Aguarda a sua **aprovação expressa**.
**Produção:** nada foi aplicado no Supabase de produção.

---

## 1. Resumo

| Item | Situação |
|---|---|
| Coletor por município (`tools/optimap/coletar_copel.mjs`) | ✅ pronto e testado com servidor simulado. Já está na sua pasta. |
| Banco: área de prévia (staging) + funções de importação | ✅ 2 migrations novas e aditivas, aplicadas só no sandbox |
| API: envio, prévia, decisões, aprovação, rejeição, descarte e reversão | ✅ |
| Telas `/optimap/importacoes` e `/optimap/importacoes/:id` | ✅ |
| Testes | ✅ SQL 67/67 · E2E 23/23 · smoke 14/14 · regressão Fase 2 112/112 · regressão Fase 3 60/60 |
| Piloto com dados reais | ✅ 15 municípios, 130.727 postes, só no sandbox local (seção 14) |

Fluxo completo:

**coletar → enviar arquivo → prévia (comparação + validação) → decidir conflitos → aprovar → (se preciso) reverter**

Nenhum poste entra no mapa antes da aprovação. Postes externos nunca viram rede da NICK.

---

## 2. Coletor por município

```powershell
cd "E:\OneDrive\Downloads\Projetos Claude\OptiMon - Cessão de Rede\optimon"
$env:OPTIMAP_CONTATO = "seu-email@nicknetwork"   # opcional, identifica a NICK no acesso
node tools\optimap\coletar_copel.mjs --cidade "Jussara"
#   se for interrompido:  node tools\optimap\coletar_copel.mjs --cidade "Jussara" --continuar
```

Como ele trabalha:

1. Busca no IBGE o código e o **limite oficial** do município.
2. Conta os postes no retângulo do município antes de baixar.
3. Baixa em páginas de 2.000 postes, **1 requisição a cada 3 s**, uma de cada vez.
4. Identifica a NICK no User-Agent.
5. **Para no primeiro erro ou bloqueio, sem tentar contornar.** O progresso fica salvo para `--continuar`.
6. Mantém só os postes dentro do limite municipal. Descarta duplicados (pelo número do poste) e registros inválidos.

O que ele gera, em `tools\optimap\saida\copel_<ibge>_<cidade>\`:

- **`copel_<ibge>_<cidade>_<data>.geojson`.** O arquivo carrega um cabeçalho `optimap` com o município, a data da coleta, as contagens e o **SHA-256 da lista de postes**.
- **`resumo.txt`**, com as contagens da coleta.

Na importação, a API recalcula esse hash. **Um arquivo editado depois da coleta é recusado.**

Os campos usados são os mesmos validados no teste de viabilidade:

- `num_seq_geo`, o número do poste. É a chave.
- `latitude` e `longitude`.
- `situacao`.
- `indic_ps_particular`.

O `objectid` é guardado, mas nunca é usado como chave.

---

## 3. Banco de dados (migrations novas e aditivas)

| Migration | Conteúdo |
|---|---|
| `20261022090000_optimap_4_01_staging_importacao_gis.sql` | Cria `staging.gis_importacoes`, `staging.gis_importacao_itens` e `staging.gis_importacao_alteracoes` (log imutável). Adiciona a FK `gis_postes_referencia.ultima_importacao_id`, prevista na Fase 2. Define RLS e privilégios. |
| `20261022090100_optimap_4_02_funcoes_importacao_gis.sql` | Funções `app.gis_importacao_*` (SECURITY DEFINER, com checagem de perfil própria) e wrappers `public.optimap_importacao_*` |

Garantias:

- Nenhuma migration histórica foi editada.
- Nenhuma alteração em `infra_postes`, `cidades_infra` (inclusive `km_rede`), `infra_segmentos.extensao_km` ou `contrato_fibras`. Os testes conferem por hash do conteúdo e da estrutura.
- `cidades_infra` só é **lida**, para casar o município: primeiro pelo código IBGE, depois por nome+UF sem acento. A Jussara do seed real não tem código IBGE e casou pelo nome.
- Nenhuma policy `using(true)`. Ninguém escreve direto no staging. Toda escrita passa pelas funções.
- As importações rejeitadas, descartadas e revertidas ficam no histórico. As tabelas de importação e de log **não aceitam DELETE**.

---

## 4. Regras da prévia

Dois postes são o mesmo **somente** se tiverem a mesma fonte e o mesmo número (`num_seq_geo`). Coordenada próxima nunca une postes; no máximo gera um alerta.

| Classificação | Quando | O que a aprovação faz |
|---|---|---|
| **NOVO** | Número ainda não cadastrado | Inclui como referência `CONFIRMADO` |
| **ATUALIZADO** | Mudou a situação, um atributo da fonte ou a posição (> 0,5 m) | Atualiza; estado `ATUALIZADO` |
| **SEM_ALTERACAO** | Igual ao cadastrado (o `objectid` é ignorado) | Só renova a data da coleta; estado `CONFIRMADO` |
| **CONFLITO** | Ver tabela abaixo | Exige uma decisão por item: **APLICAR** ou **IGNORAR** (IGNORAR não altera nada) |
| **AUSENTE** | Está cadastrado no município, mas não veio no arquivo | Marca `NAO_LOCALIZADO_ULTIMA_COLETA`. **Nunca apaga.** |
| **INVALIDO** | Sem número, sem coordenada ou fora do Brasil | Nunca aplicado |
| **DUPLICADO** | Número repetido no arquivo | Vale a 1ª ocorrência |

Motivos de conflito:

| Motivo | Condição |
|---|---|
| `DESLOCAMENTO_GRANDE` | O poste mudou mais de 30 m de lugar |
| `DESLOCADO_COM_POSTE_NICK` | Mudou mais de 5 m e já foi promovido a poste da rede NICK |
| `REAPARECEU_APOS_EXCLUSAO` | Estava marcado como `EXCLUIDO_PELA_FONTE` |
| `MUNICIPIO_DIFERENTE` | Já está cadastrado em outro município |

Alertas, que não mudam a classificação:

- outro poste a menos de 1 m com número diferente;
- poste usado pela rede NICK;
- poste ausente, mas usado pela rede NICK;
- número repetido no arquivo em outra posição.

**Bloqueios** (a aprovação fica impossível):

- conflitos sem decisão;
- coleta mais antiga do que a última já aplicada no município;
- arquivo com menos postes do que o cabeçalho declara;
- nenhum poste válido.

**Confirmação explícita exigida:**

- **Ausência em massa:** mais de 20% dos postes já cadastrados no município não vieram no arquivo. Isso protege contra uma coleta incompleta.

**Proteção da prévia:**

- Só pode haver uma importação aberta por município.
- Na aprovação, a prévia é **recalculada com o cadastro travado**. Se algo mudou desde a revisão, a aprovação é abortada (`OPTIMAP_PREVIA_DESATUALIZADA`) e nada é gravado.

A gravação de inclusões, atualizações, confirmações e não localizados é **atômica**: ou tudo é gravado, ou nada.

---

## 5. Permissões

| Ação | ENGENHARIA | DIRETOR | ADMINISTRADOR | COMERCIAL / AUDITOR / FINANCEIRO |
|---|---|---|---|---|
| Ver importações | só as próprias | todas | todas | não |
| Enviar arquivo, recalcular, descartar | ✅ (as próprias) | — | ✅ | não |
| Decidir conflitos | ✅ (as próprias) | ✅ | ✅ | não |
| Aprovar / rejeitar | — | ✅ | ✅ | não |
| Reverter | — | — | ✅ | não |

Mesma matriz da importação de infraestrutura da Fase 4.1.

---

## 6. Reversão (sem reset)

O log `staging.gis_importacao_alteracoes` guarda cada inclusão e atualização com **apenas os campos que mudaram** (valor anterior e novo) e uma ordem crescente. Ele é imutável: só os campos da reversão podem mudar.

Para reverter, o sistema percorre o log em **ordem inversa** e só desfaz o que **continua exatamente como a importação deixou**. Fica intocado, com o motivo registrado:

- o que foi alterado por uma **importação posterior**;
- o que foi **editado manualmente** depois;
- o poste incluído que **virou poste da rede NICK**.

O resultado é `REVERTIDA` ou `REVERTIDA_PARCIALMENTE`.

Se a reversão foi parcial, ela pode ser **tentada de novo depois**. Por exemplo, depois de reverter a importação posterior. Isso foi testado.

Reverter uma inclusão remove só o poste que aquela importação criou e que ninguém tocou depois. O conteúdo completo continua guardado no log.

---

## 7. Auditoria

Todas as ações vão para `public.auditoria` (entidade `gis_importacoes`), usando as ações IMPORT_* que já existiam na whitelist:

- RECEIVE;
- PREVIEW_READY;
- APPROVE e APPLY;
- REJECT;
- DISCARD;
- REVERT e REVERT_PARTIAL.

Os dados registrados são o usuário, as contagens, a confirmação de ausências e se quem aprovou foi quem enviou.

Postes individuais **não** geram linha em `public.auditoria`, para não encher o plano Free. A rastreabilidade por poste está no log de alterações.

---

## 8. API (`/api/optimap/importacoes`, sempre com o JWT do usuário)

| Método | Rota | Função |
|---|---|---|
| POST | `/` (multipart `arquivo`) | Confere formato e hash, carrega em lotes de 2.000 e calcula a prévia. Se a carga falhar no meio, a importação é descartada. |
| GET | `/` · `/:id` · `/:id/itens` · `/:id/previa.geojson` | Lista, detalhe, itens paginados e filtrados, e pontos para o mapa |
| POST | `/:id/decisoes` · `/:id/reprocessar` · `/:id/aprovar` · `/:id/rejeitar` · `/:id/descartar` · `/:id/reverter` | Ações |

Erros de domínio (`OPTIMAP_*`) chegam ao usuário. Erros internos nunca vazam. Nenhuma resposta vai para cache (`no-store`).

---

## 9. Telas

**Acesso:** pelo link **“Importações de postes”** na barra inferior do mapa, visível só para ENGENHARIA, DIRETOR e ADMINISTRADOR.

**Lista:**

- envio do arquivo;
- todas as importações, com município, data da coleta, contagens por classificação, status e quem enviou.

**Prévia:**

- origem: arquivo, hash, coleta, quem enviou, aprovou ou reverteu;
- bloqueios em vermelho e avisos em amarelo, com a caixa de confirmação das ausências;
- cartões por classificação, que também servem de filtro;
- **mapa** com os pontos coloridos e uma linha tracejada do deslocamento (posição anterior → nova). Ao filtrar, o mapa enquadra os itens filtrados;
- tabela paginada com busca por número;
- decisões “Aplicar” e “Ignorar”, por item ou para os pendentes da página;
- botões conforme o perfil: Recalcular, Descartar, Rejeitar, **Aprovar e importar**, **Reverter** (com motivo obrigatório);
- após a importação: registro das alterações aplicadas e, numa reversão parcial, os motivos do que ficou.

Capturas de tela: `tests/optimap/fase4/screenshots/01..09`.

---

## 10. Testes

| Suíte | Resultado | Arquivo |
|---|---|---|
| SQL da Fase 4 (fluxo completo, permissões, RLS, conflitos, prévia desatualizada, ausências, bloqueios, reversões encadeadas, imutabilidade, auditoria, preservação das tabelas oficiais, escala de 15 mil postes) | **67/67** | `tests/optimap/run_tests_optimap_fase4.sh` · `fase4/resultado_sql.log` |
| E2E das telas (Playwright) | **23/23** | `tests/optimap/fase4/e2e_importacoes.js` · `resultado_e2e.log` |
| Smoke da API (inclui o leitor do arquivo e a recusa por hash) | **14/14** | `api/test/smoke.js` |
| Regressão Fase 2 | **112/112** | Ajuste: os testes passam a considerar as FKs internas do staging GIS, que não alteram as tabelas oficiais |
| Regressão Fase 3 (mapa) | **60/60** | — |

Os testes E2E usam **arquivos de teste** com números de poste `99xxxxxxxx`, fora da faixa da Copel. Nenhum dado fictício é apresentado como real.

---

## 11. Desempenho e espaço no Supabase

Medido no sandbox com os **arquivos reais** (seção 14):

| Etapa | Cidade pequena (Jussara, 2.981) | Maior cidade (Cianorte, 27.775) |
|---|---|---|
| Envio + prévia (1ª carga) | ~1,0 s | ~4,6 s |
| Aprovação (1ª carga) | ~1,9 s | ~6,7 s |
| Recoleta: envio + prévia | ~0,9 s | ~5,2 s |
| Recoleta: aprovação | ~1,6 s | ~10,7 s |

O papel `authenticated` do Supabase corta consultas em 8 s. Por isso a prévia, a aprovação e a reversão declaram `statement_timeout = 120s` na própria função. O PostgREST aplica isso só a essas chamadas (*Function Settings*), sem mudar o limite global.

> ⚠ **Verificar no primeiro uso real:** esse recurso depende da versão do PostgREST do projeto, que é recente no Supabase. Se aparecer “A operação demorou demais”, nada terá sido aplicado.

**Otimizações feitas depois do piloto** (o primeiro piloto mostrou espaço demais):

- a classificação passou a gravar cada item **uma única vez**, e só se o resultado mudou. Recalcular uma prévia igual (como acontece na aprovação) não reescreve nenhuma linha;
- o log guarda o valor anterior dos campos alterados e só uma **impressão (md5)** do valor novo, que basta para a reversão saber se o poste continua como a importação deixou;
- removido um índice que impedia atualizações “HOT” nas recoletas.

Resultado medido (espaço real, sem inchaço):

| Situação (15 municípios, 130.727 postes) | Espaço aproximado |
|---|---|
| Postes de referência | ~63 MB |
| 1ª carga (postes + itens da prévia + log) | ~150 MB |
| Cada **recoleta completa** dos 15 municípios | **+~100 MB** (itens ~62 MB + log ~40 MB) |

> ⚠ **Plano Free (500 MB, hoje 37 MB em uso):** comporta a 1ª carga e mais **uma ou duas recoletas completas**. Para manter o mapa atualizado periodicamente, as saídas são:
> - **(a)** passar para o plano Pro (8 GB) — recomendado com este volume;
> - **(b)** uma rotina de compactação que, depois de uma recoleta aprovada, apague os itens “sem alteração” de importações antigas. Ainda **não implementada**: ela apaga dados do histórico, então depende da sua decisão;
> - **(c)** recoletar só os municípios onde houver mudança relevante.

## 12. Pontos para sua validação

1. **Limiares:** 0,5 m (mudança de posição), 5 m (conflito com poste NICK), 30 m (conflito geral), 1 m (alerta de proximidade) e 20% (ausência em massa). Ajustáveis.
2. **Reverter uma inclusão remove o poste de referência** criado pela importação. O conteúdo fica no log, e o poste não é removido se tiver virado poste NICK ou tiver sido alterado depois.
3. **Quem aprova pode ser quem enviou**, se for ADMINISTRADOR. Isso fica registrado na auditoria. Se você preferir exigir duas pessoas, é uma regra simples de acrescentar.
4. **Robots.txt da Copel:** continua valendo a decisão registrada na Fase 1 (Adendo 2). O coletor respeita as salvaguardas acordadas.

---

## 13. Próximo passo

1. Você revisa este relatório e as telas do piloto (`tests/optimap/fase4/piloto/`).
2. Decide os pontos da seção 12, o plano do Supabase (seção 11) e se Jacarezinho e Ribeirão Claro entram (seção 14).
3. Com a sua **aprovação expressa**, aplico as migrations no Supabase de produção, publico API e telas e você faz as importações pela tela.

---

## 14. Piloto real (somente sandbox local)

O coletor rodou na sua máquina para 17 municípios em 22/10/2026. Todos os arquivos passaram na conferência de hash e foram importados pela API, com prévia e aprovação, no banco local.

| Município | IBGE | Postes no município | Fora do limite (descartados) |
|---|---|---|---|
| Cianorte | 4105508 | 27.775 | 13.785 |
| Santo Antônio da Platina | 4124103 | 15.607 | 1.816 |
| Cornélio Procópio | 4106407 | 12.927 | 11.942 |
| Piraí do Sul | 4119400 | 12.441 | 13.312 |
| Bandeirantes | 4102406 | 10.318 | 7.199 |
| Carlópolis | 4104709 | 9.630 | 1.577 |
| Cambará | 4103602 | 7.295 | 390 |
| Terra Boa | 4127205 | 6.924 | 7.732 |
| Andirá | 4101101 | 6.387 | 2.362 |
| Santa Mariana | 4123907 | 5.386 | 4.301 |
| Joaquim Távora | 4112801 | 5.365 | 4.326 |
| Ribeirão do Pinhal | 4121901 | 5.156 | 6.746 |
| Jussara | 4113007 | 2.981 | 7.222 |
| Jundiaí do Sul | 4112900 | 2.222 | 1.326 |
| Barra do Jacaré | 4102703 | 313 | 605 |
| **Total importado** | | **130.727** | |
| Jacarezinho | 4111803 | **63** | 16.823 |
| Ribeirão Claro | 4121802 | **100** | 5.871 |

O que o piloto mostrou:

- **Resultado limpo:** nenhum inválido, nenhum duplicado, nenhum conflito e nenhum alerta de proximidade nos 15 municípios. Situações da fonte: “Disponível”, “Possível disponibilidade” e “Indisponível”.
- **Idempotência:** reenviar o mesmo arquivo de Jussara resultou em 2.981 “sem alteração” e no aviso “arquivo já importado”. Uma recoleta completa dos 15 municípios com os mesmos arquivos também resultou só em “sem alteração”.
- **Cidade OptiMon:** Jussara casou com a cidade do seed real pelo nome. Os outros 14 municípios ainda não existem em `cidades_infra`; a importação avisa e grava os postes sem cidade associada. Cadastrar essas cidades depois não exige reimportar: a próxima coleta preenche o vínculo.
- **Jacarezinho e Ribeirão Claro — não importados.** A camada da Copel quase não tem postes dentro desses dois municípios (63 e 100). Os milhares de postes do retângulo de busca estão nas cidades vizinhas (Santo Antônio da Platina, Cambará e Carlópolis). Ou seja, os centros urbanos de Jacarezinho e Ribeirão Claro praticamente não aparecem no mapa público da Copel. Vale você confirmar qual concessionária atende a rede nesses dois municípios. Se quiser, importo esses poucos postes mesmo assim.
- **Mapa:** os postes aparecem a partir do zoom 12. As capturas estão em `tests/optimap/fase4/piloto/`. O mapa-base aparece neutro nas capturas porque o ambiente de teste não tem internet; no seu navegador, o OpenFreeMap é carregado normalmente.

Sugestão para depois (não implementada, muda o visual aprovado na Fase 3): colorir os postes de referência pela situação informada pela fonte (disponível / possível / indisponível). A informação já chega no mapa.

---

### Arquivos desta fase

- `tools/optimap/coletar_copel.mjs`
- `supabase/migrations/20261022090000_optimap_4_01_staging_importacao_gis.sql`
- `supabase/migrations/20261022090100_optimap_4_02_funcoes_importacao_gis.sql`
- `api/routes/optimapImportacoes.js` (novo)
- `api/routes/optimap.js` (sessão com permissões de importação + montagem da sub-rota)
- `api/test/smoke.js`
- `web/src/pages/OptiMapImportacoes.jsx` (novo)
- `web/src/pages/OptiMap.jsx` (link)
- `web/src/App.jsx` (rotas lazy)
- `web/src/lib/api.js`
- `web/src/optimap/optimap.css`
- `tests/optimap/run_tests_optimap_fase4.sh` (novo)
- `tests/optimap/run_tests_optimap_fase2.sh` (ajuste de regressão)
- `tests/optimap/fase4/` (E2E, logs, capturas e `piloto/`)
- `docs/OPTIMAP_FASE_4_RELATORIO.md`

---

## Adendo 1 — Decisões do usuário e fonte para a área da CPFL (23/10/2026)

**Decisões:**
1. Supabase passa para o plano **Pro**.
2. **Importar** também os postes da Copel encontrados em Jacarezinho (63) e Ribeirão Claro (100).
3. Pontos da seção 12 **aprovados** como estão.
4. **Publicação em produção autorizada.** Passo a passo em `docs/OPTIMAP_DEPLOY_PRODUCAO.md`, com o script `scripts/optimap_deploy_producao.ps1`.

**Área da CPFL:** em Jacarezinho, Ribeirão Claro e Barra do Jacaré, os postes são da **CPFL Santa Cruz**. Isso explica por que quase não aparecem no mapa da Copel.

O que a pesquisa encontrou:

- **Não foi encontrado** um mapa público de postes da CPFL equivalente ao da Copel. O compartilhamento de postes da CPFL é tratado por contrato e pelo site de projetos particulares. Ali o ocupante envia projetos, mas não há consulta pública ao cadastro de postes.
- **Melhor caminho público: BDGD da ANEEL** (Base de Dados Geográfica da Distribuidora).
  - Dado aberto, licença ODbL, publicado **por distribuidora** em arquivo geodatabase (.gdb), com atualização anual.
  - A camada **PONNOT** (pontos notáveis da rede) traz os pontos da rede com coordenadas, entre eles os postes.
  - **Limitações:**
    - o identificador é o código interno da distribuidora, que pode não ser o número da plaqueta;
    - não há status de disponibilidade;
    - a data de referência é 31/12 do ano anterior;
    - o arquivo cobre toda a concessão, então precisa ser recortado por município (o coletor já faz isso com o limite do IBGE);
    - ainda é preciso abrir o arquivo para confirmar se a camada cobre todos os postes de baixa tensão.
- **Caminho formal:** como ocupante com contrato com a CPFL Santa Cruz, solicitar formalmente o cadastro georreferenciado dos postes contratados ou da área de interesse.

**Próximo passo proposto:**

1. Você baixa o BDGD da **CPFL Santa Cruz** no portal de dados abertos da ANEEL. Este ambiente não tem acesso ao portal.
2. Eu crio um conversor do BDGD para o mesmo formato do coletor, com a fonte nova `ANEEL_BDGD_CPFL_SANTA_CRUZ` (EXTERNA).
3. Os postes entram pelo mesmo fluxo de prévia e aprovação.
