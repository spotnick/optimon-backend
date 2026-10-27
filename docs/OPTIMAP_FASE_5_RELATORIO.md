# OptiMap — Fase 5: empresas, ocupações, CES e cores dos postes

Aprovada pelo usuário em 27/10/2026 ("aprovado"). Implementada e testada no ambiente local. **Ainda não aplicada em produção**: a publicação depende da sua autorização (seção 7).

## 1. O que muda para quem usa

### Cores do mapa

Os postes da Copel ganham cor a partir do zoom 15. Quando mais de uma regra vale para o mesmo poste, vence a primeira desta lista:

| Cor | Significado | De onde vem |
|---|---|---|
| Azul | Ocupamos, com projeto aprovado | Lista do CES da empresa |
| Vermelho | Ocupamos, sem projeto aprovado | Marcação feita pela engenharia no mapa |
| Cinza | Copel: indisponível | Situação no mapa público da Copel |
| Amarelo | Copel: possível disponibilidade | Idem |
| Verde | Copel: disponível | Idem |
| Cinza-claro | Sem situação informada | — |

Outros comportamentos do mapa:

- **Legenda clicável:** cada cor pode ser ligada ou desligada. A escolha fica salva no navegador.
- **Filtro por empresa:** "Todas" ou uma empresa. Com uma empresa escolhida, só as ocupações *dela* pintam o poste de azul ou vermelho; os demais postes mostram a situação da Copel.
- **Contorno escuro:** poste vinculado a um poste da NICK cadastrado no OptiMap.
- **Agrupamentos (zoom 12–14):** ficam azuis quando há postes ocupados no grupo.

### Painel do poste

O painel mostra a seção **Ocupação por empresa**. Para cada empresa aparecem:

- nome fantasia e razão social;
- UC Copel e contrato;
- data da lista do CES, ou quem marcou e quando.

Quando duas empresas ocupam o mesmo poste, as duas aparecem.

ENGENHARIA e ADMINISTRADOR também têm dois botões no painel:

- **Marcar "ocupado sem projeto aprovado":**
  - escolhe-se a empresa;
  - a descrição é obrigatória;
  - o poste fica vermelho na hora.
- **Encerrar marcação:**
  - o motivo é obrigatório;
  - nada é apagado: a marcação vai para o histórico.

### Listas do CES

Tela nova em `/optimap/ces`, com o mesmo fluxo das importações de postes:

1. **Enviar:** ENGENHARIA ou ADMINISTRADOR envia o arquivo, que vira uma prévia.
2. **Aprovar:** ADMINISTRADOR ou DIRETOR aprova a prévia.
3. **Reverter:** só ADMINISTRADOR pode reverter uma lista aplicada.

Comportamentos da lista:

- **Empresa:** é identificada pelo CNPJ gravado no arquivo.
- **Poste que sai da lista:** vira "não consta na última lista do CES". **Nunca é apagado.**
- **Projeto aprovado sobre marcação:** quando um poste com marcação "sem projeto" aparece aprovado no CES para a mesma empresa, a marcação é encerrada automaticamente. Isso fica registrado e é desfeito se a lista for revertida.
- **Conferência por município**, com quatro colunas:
  - postes da lista;
  - ocupações ativas;
  - tabela "Consulta Pontos" do CES (o que é faturado);
  - lote de postes cadastrado no OptiMon.

### Empresas

Tela nova em `/optimap/empresas`:

- todos os perfis do mapa veem a lista;
- só ADMINISTRADOR cadastra e edita;
- a tela tem o botão "Conferir com o CES".

Duas empresas já vêm cadastradas:

| Empresa | UC Copel | CNPJ |
|---|---|---|
| RODRIGO BORGHI DA SILVA CIA LTDA (NICK NETWORK) | 515903403178 | 08.930.086/0001-63 |
| AYOTECH TELECOMUNICACOES LTDA | 638231603159 | 30.353.855/0001-67 |

## 2. Coleta no CES (27/10/2026)

Método usado:

- O CES não exporta a lista. A coleta foi feita no navegador, com você logado, consultando a camada de pontos do próprio CES.
- O filtro usa o código da empresa que o CES fornece depois que a empresa é escolhida.
- A busca foi feita por área dos municípios, com pausa entre páginas.
- Nenhum dado de outra empresa foi consultado.

| Empresa | Coletados | Tabela "Consulta Pontos" | Arquivo |
|---|---|---|---|
| NICK | 5.341 | 5.350 | `tools\optimap\saida\ces\ces_08930086000163_nick_2026-10-27.geojson` |
| AYOTECH | 391 (todos em Cianorte) | 391 | `tools\optimap\saida\ces\ces_30353855000167_ayotech_2026-10-27.geojson` |

**55 postes** estão nas listas das duas empresas.

Conferência da NICK por município:

| Município | Coletado | Tabela CES | Diferença |
|---|---|---|---|
| Cianorte | 2.847 | 2.838 | +9 |
| Santo Antônio da Platina | 1.526 | 1.544 | −18 |
| Andirá | 628 | 628 | 0 |
| Jussara | 188 | 188 | 0 |
| Piraí do Sul | 152 | 152 | 0 |

O lote de Jussara cadastrado no OptiMon tem **165** postes, contra **188** faturados pela Copel. Vale revisar.

## 3. Banco (migrations novas e aditivas)

### `20261027090000_optimap_5_01_empresas_ocupacoes.sql`

| Objeto | O que é |
|---|---|
| fonte `COPEL_CES` (EXTERNA) | Nova fonte de dados |
| `public.gis_empresas` | Empresas, com auditoria e as 2 empresas acima |
| `public.gis_ocupacoes` | Ocupações (detalhes abaixo) |
| `staging.gis_ces_importacoes`, `staging.gis_ces_itens`, `staging.gis_ces_alteracoes` | Prévias e log de alterações do CES (detalhes abaixo) |

`public.gis_ocupacoes` (uma ocupação por empresa e poste):

- Tipos:
  - `PROJETO_APROVADO`, que vem do CES;
  - `SEM_PROJETO`, que vem de marcação.
- Estados: `ATIVA`, `NAO_CONSTA_ULTIMA_LISTA`, `ENCERRADA`.
- Regras garantidas por *check constraints* e triggers:
  - marcação exige motivo;
  - marcação não pode ser apagada.

Tabelas de staging do CES:

- o log de alterações é imutável;
- nenhuma delas aceita DELETE.

RLS:

- todos os perfis do mapa leem empresas e ocupações;
- nas listas do CES, ENGENHARIA vê só as que enviou; ADMINISTRADOR e DIRETOR veem todas;
- nenhuma escrita direta: tudo passa por funções.

### `20261027090100_optimap_5_02_funcoes_ces_ocupacoes.sql`

- **Funções `app.gis_*`:**
  - `app.gis_empresa_salvar`;
  - `app.gis_ocupacao_marcar` e `app.gis_ocupacao_encerrar`;
  - `app.gis_ces_*`: iniciar, adicionar_itens, processar, aprovar, rejeitar, descartar, reverter, listar, detalhe, itens, conferencia;
  - `app.gis_ocupacoes_do_poste`.
- **Wrappers:** `public.optimap_*`, com `statement_timeout` de 120 s nas funções pesadas.
- **`app.gis_tile` (CREATE OR REPLACE):**
  - só a camada de postes de referência mudou;
  - ganhou `categoria`, `cat_fonte`, `emp_ap` e `emp_sp`, e `ocupados` no agregado;
  - as outras camadas ficaram idênticas.
- **Reversão:** usa o mesmo método da Fase 4 (*md5* do retrato). Desfaz só o que continua como a lista deixou.

### O que não muda

- `infra_postes`, `cidades_infra.km_rede`, `infra_segmentos.extensao_km`, `contrato_fibras`;
- `gis_postes_referencia`;
- as migrations históricas.

## 4. API

| Rota | Quem usa | Função |
|---|---|---|
| `/api/optimap/ces` (+ `/:id`, `/itens`, `/previa.geojson`, `/reprocessar`, `/aprovar`, `/rejeitar`, `/descartar`, `/reverter`) | ADMIN, DIRETOR, ENGENHARIA | Listas do CES. Confere o hash gravado na coleta e envia em lotes de 2.000. |
| `GET /api/optimap/empresas` | Todos os perfis do mapa | Lista de empresas |
| `POST`/`PUT /api/optimap/empresas` | ADMIN | Cadastro e edição |
| `GET /api/optimap/empresas/:id/conferencia` | ADMIN, DIRETOR, ENGENHARIA | Conferência com o CES |
| `POST /api/optimap/ocupacoes` | ENGENHARIA, ADMIN | Marcar "sem projeto" |
| `POST /api/optimap/ocupacoes/:id/encerrar` | ENGENHARIA, ADMIN | Encerrar marcação |

Outras mudanças na API:

- `/api/optimap/detalhe/postes_referencia/:id` devolve `ocupacoes`;
- `/sessao` ganhou `pode_marcar_ocupacao` e `pode_gerir_empresas`.

## 5. Testes

| Suíte | Resultado |
|---|---|
| SQL Fase 5 (`tests/optimap/run_tests_optimap_fase5.sh`) | **72/72** |
| E2E Fase 5 (`tests/optimap/fase5/e2e_fase5.js`), com os postes reais da Copel de Cianorte e as listas reais do CES das duas empresas | **23/23** |
| Regressão SQL Fase 2 / Fase 4 | 112/112 · 67/67 |
| Regressão E2E Fase 3 / Fase 4 | 60/60 · 23/23 |
| Smoke da API | todos |

Desempenho: o tile agregado com 40 mil postes leva **70 ms** (o limite é 500 ms).

Simulação do deploy: as 2 migrations aplicadas numa única transação sobre um banco igual ao de produção terminaram sem erro.

O que a suíte SQL cobre:

- permissões por perfil;
- duplicidade e prioridade de cor;
- duas empresas no mesmo poste;
- ausências e ausência em massa (pede confirmação acima de 20%);
- lista mais antiga que a última aplicada (é bloqueada);
- reversão total e parcial;
- conferência;
- imutabilidade do log;
- tabelas oficiais intactas.

Capturas: `tests/optimap/fase5/screenshots/`.

## 6. Limites conhecidos

- **Coleta no CES:** depende do seu login no navegador, porque o CES não tem exportação. Para atualizar, repita a coleta com você logado e envie o arquivo novo pela tela.
- **Postes fora do mapa público:** a ocupação de um poste que ainda não foi importado do mapa público da Copel fica na posição do CES e não aparece colorida. Ela já conta na conferência, como "(poste fora do mapa público)". Ao importar o município, a próxima lista do CES faz o vínculo.
- **Área da CPFL:** o mapa da CPFL continua pendente do arquivo BDGD da ANEEL (Adendo 1 da Fase 4).

## 7. Publicação (precisa da sua autorização)

1. Rode `.\scripts\optimap_deploy_producao.ps1 -SoVerificar`. O grupo "OptiMap Fase 5" deve aparecer como **PENDENTE**.
2. Rode o script sem `-SoVerificar` e digite `APLICAR`.
3. Faça `git push` do código: API, web, migrations, testes, docs e script.
4. Abra o OptiMap → **Listas do CES** e envie os 2 arquivos de `tools\optimap\saida\ces\`. Como ADMINISTRADOR ou DIRETOR, aprove cada um.
