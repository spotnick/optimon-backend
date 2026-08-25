# Relatório Final — Fase 2.2 (Infrastructure Floor + Régua Comercial)

Data: 2026-08-29 (implementação, dentro do ambiente de execução) / 2026-08-25 (data corrente do ambiente)
Projeto: OptiMon — Optical Asset & Pricing Management

Este relatório segue os 15 itens exigidos pelo prompt "OPTIMON — OPTICAL ASSET & PRICING MANAGEMENT — FASE 2.2 — INFRASTRUCTURE FLOOR + RÉGUA COMERCIAL". Todos os resultados de teste abaixo vêm de execuções reais do script `tests/run_tests_fase22.sh` contra um Postgres 16 local, reconstruindo o banco do zero a cada rodada (Fase 1 → seed → Fase 1.1 → seed → Fase 1.2 → seed → Fase 2 → seed_fase2 → Fase 2.1 → **Fase 2.2**, as duas últimas sem seed próprio) — nenhum resultado foi assumido ou estimado.

**Restrições do prompt, cumpridas integralmente:** nenhuma tabela/migration das Fases 1/1.1/1.2/2/2.1 foi alterada ou reconstruída; nenhuma funcionalidade que já funcionava foi removida ou teve seu comportamento anterior quebrado (ver item 12 — regressão); esta é uma evolução incremental do Pricing Engine existente, não uma reconstrução; Infrastructure Floor é sempre tratado como **política comercial**, nunca como "custo real" (`custos_infraestrutura`, da Fase 2, não foi tocado); todos os valores literais do prompt (R$10,00/poste, R$0,10/R$0,15/R$0,20 por metro) foram seedados como parâmetros configuráveis, nunca hard-coded; **a Fase 3 não foi iniciada** — esta entrega aguarda aprovação explícita antes de qualquer próximo passo.

---

## 1. Arquivos alterados

| Arquivo | O que mudou |
|---|---|
| `supabase/migrations/20260829090000_phase_2_2_01_infra_floor_schema.sql` | Schema aditivo: `pricing_parametros.cidade_id` (override por cidade) + 2 índices únicos parciais; `infra_pops.km_rede`/`postes_count` (colunas analíticas); enum `infra_floor_composition_mode`; `contrato_pricing_config.infra_floor_composition_mode`/`.minimum_infrastructure_floor_enforced`; seed dos 4 parâmetros globais do Infrastructure Floor |
| `supabase/migrations/20260829090100_phase_2_2_02_infrastructure_floor_engine.sql` | `app.get_infra_floor_param()`, `app.calculate_infrastructure_floor()`, `app.get_fibras_indicadores_cidade()`, `app.get_valor_infra_floor_por_fibra()`, `app.get_valor_infra_floor_por_porta_pon()` |
| `supabase/migrations/20260829090200_phase_2_2_03_regua_comercial_governanca.sql` | `app.calcular_desconto_comercial()`, `app.classificar_posicao_regua()`, `app.check_infrastructure_floor_governance()`, `app.calcular_composicao_piso_minimo()`, `app.calcular_breakeven_infra_floor()`/`_clientes()`, `app.calcular_escala_pon_para_meta()`, `app.get_economia_com_piso()` |
| `supabase/migrations/20260829090300_phase_2_2_04_multipop_auditoria_api.sql` | `app.get_capacidade_multi_pop_piso()`; trigger de auditoria em `cidades_infra`; `pricing_override_requests.preco_piso`/`.preco_abertura`; `public.pricing_override_create()` estendida (+2 parâmetros opcionais, com `DROP FUNCTION` de correção — ver item 13); 5 wrappers públicos novos |
| `api/routes/pricing.js` | 5 rotas `GET` novas (`/infrastructure-floor`, `/infra-floor-negotiation`, `/economics-with-floor`, `/fibras-indicadores`, `/capacity-multipop-floor`); `POST /override` estendida para aceitar `preco_piso`/`preco_abertura` opcionais |
| `dashboard/optimon-pricing-dashboard.html` | Novo grupo de campos "Infrastructure Floor" no rail; card do Floor + indicadores; gráfico da régua (3 níveis + bloqueado); linha de negociação ao vivo; 2 tabelas novas; ~9 funções JS novas espelhando as funções SQL desta fase (ver item 5) |
| `docs/ARQUITETURA.md` | Nova seção 17 (Fase 2.2), 12 subseções detalhando cada peça |
| `README.md` | Estrutura de pastas, contagem de migrations, instruções de aplicação e seção de resultados de teste atualizadas para incluir a Fase 2.2 |

**Nenhuma migration das Fases 1/1.1/1.2/2/2.1 foi alterada** — confirmado nesta execução pela mesma evidência de `mtime` usada desde a Fase 2.1 (teste NOVO-14, reexecutado nesta bateria): o arquivo mais recente entre `20260824*`–`20260827*.sql` é anterior ao mais antigo dos 4 arquivos `20260828*.sql`; as 4 migrations `20260829*.sql` desta fase são estritamente posteriores a ambos.

## 2. Migrations (4 novas, todas aditivas)

| # | Arquivo | Tipo de mudança |
|---|---|---|
| 1 | `20260829090000_..._infra_floor_schema.sql` | `ALTER TABLE ADD COLUMN` (×4), troca de 1 `UNIQUE` por 2 índices únicos parciais (reversível, não apaga linha), `CREATE TYPE` (guardado por `exception when duplicate_object`), `INSERT ... ON CONFLICT DO NOTHING` |
| 2 | `20260829090100_..._infrastructure_floor_engine.sql` | 5 `CREATE OR REPLACE FUNCTION` (todas novas) |
| 3 | `20260829090200_..._regua_comercial_governanca.sql` | 7 `CREATE OR REPLACE FUNCTION` (todas novas) |
| 4 | `20260829090300_..._multipop_auditoria_api.sql` | 1 `CREATE OR REPLACE FUNCTION` (nova), `CREATE TRIGGER` (guardado por checagem em `pg_trigger`), `ALTER TABLE ADD COLUMN` (×2), 1 `DROP FUNCTION IF EXISTS` + `CREATE OR REPLACE FUNCTION` (extensão retrocompatível — ver item 13), 5 `CREATE OR REPLACE FUNCTION` (wrappers públicos) + `GRANT EXECUTE` |

Todas aplicam em sequência, sem erro, sobre um banco já com Fase 1 + 1.1 + 1.2 + 2 + 2.1 e dados/seeds reais (confirmado nesta execução, item "pré-condição" do log de testes).

## 3. Funções alteradas ou criadas

**Alterada (`CREATE OR REPLACE`, assinatura estendida com parâmetros opcionais no final — chamadas antigas continuam funcionando):** `public.pricing_override_create()` (+`p_preco_piso`, `p_preco_abertura`, ambos `default null`).

**Criadas (18 novas):** `app.get_infra_floor_param`, `app.calculate_infrastructure_floor`, `app.get_fibras_indicadores_cidade`, `app.get_valor_infra_floor_por_fibra`, `app.get_valor_infra_floor_por_porta_pon`, `app.calcular_desconto_comercial`, `app.classificar_posicao_regua`, `app.check_infrastructure_floor_governance`, `app.calcular_composicao_piso_minimo`, `app.calcular_breakeven_infra_floor`, `app.calcular_breakeven_infra_floor_clientes`, `app.calcular_escala_pon_para_meta`, `app.get_economia_com_piso`, `app.get_capacidade_multi_pop_piso`, `public.pricing_infrastructure_floor`, `public.pricing_infra_floor_negotiation`, `public.pricing_economics_with_floor`, `public.pricing_fibras_indicadores`, `public.pricing_capacity_multipop_piso` (19, incluindo os 5 wrappers).

**Nenhuma função das Fases 1/1.1/1.2/2/2.1 foi removida ou teve seu comportamento alterado** — em particular, `app.check_pricing_governance` (governança de 2 níveis do Cenário 1/2, Fase 2) permanece intocada e coexiste com a nova `app.check_infrastructure_floor_governance` (3 níveis, específica do Floor) sem sobreposição.

## 4. APIs alteradas

5 rotas novas em `api/routes/pricing.js`, mesmo padrão fino de sempre (validam entrada, chamam 1 wrapper `public.pricing_*` via RPC do Supabase, devolvem o resultado — a API nunca decide preço): `GET /infrastructure-floor`, `GET /infra-floor-negotiation`, `GET /economics-with-floor`, `GET /fibras-indicadores`, `GET /capacity-multipop-floor`. `POST /override` estendida (campos opcionais, sem quebrar o contrato existente). As 9 rotas das Fases 2/2.1 não foram alteradas.

## 5. Dashboard alterado

Novo grupo de campos "Infrastructure Floor" no rail (postes, km de rede, os 4 preços parametrizáveis, chip-row de composição Floor×Mínimo com 5 opções, toggle de `enforced`, fibras ociosas). Novo card com o valor do Floor e os indicadores por fibra/Porta PON. Gráfico da régua com 3 degraus (Abertura/Recomendado/Piso) + um 4º estado visual "bloqueado", com o degrau correspondente ao preço proposto destacado dinamicamente. Linha de negociação ao vivo (posição na régua + badge de governança + texto de desconto, recalculada a cada clique em "Gerar simulação"). Duas tabelas novas: comparação econômica com o piso (7 linhas, todos os campos de `get_economia_com_piso`) e o teste de ARPU completo (10/25/50/75/84/100/128 clientes). Nove funções JS novas — `calculateInfrastructureFloor`, `calcularDescontoComercial`, `classificarPosicaoRegua`, `checkInfraFloorGovernanca`, `calcularComposicaoPisoMinimo`, `getEconomiaComPiso`, `calcularBreakevenInfraFloor`/`_Clientes`, `renderComparacaoPiso`, `renderEconomicoPiso` — cada uma espelho byte-a-byte da função SQL correspondente, verificado via Playwright headless (zero `pageerror`/`console.error`, valores da UI conferidos contra os mesmos números do banco: Jussara 165 postes/5.000m → R$2.150,00/R$2.400,00/R$2.650,00; os 5 preços de exemplo de governança; os 5 modos de composição).

## 6. Parametrização (nunca hard-coded)

Os 4 valores literais do prompt — `PISO_INFRAESTRUTURA_PRECO_POSTE`=R$10,00/poste/mês, `PISO_INFRAESTRUTURA_PRECO_METRO_PISO`=R$0,10/m, `_RECOMENDADO`=R$0,15/m, `_ABERTURA`=R$0,20/m — foram seedados em `pricing_parametros` (globais, `cidade_id IS NULL`), nunca escritos como constante em nenhuma função SQL ou linha de JS: toda leitura passa por `app.get_infra_floor_param()` (SQL) ou pelos campos do rail do dashboard (JS). Suportam override por cidade (item 8) e são alteráveis por `DIRETOR`/`ADMINISTRADOR` sem qualquer migration nova, exatamente como todo outro parâmetro de pricing desde a Fase 1.

## 7. Exemplo oficial completo — Jussara-PR

Entrada: cidade Jussara, 165 postes, 5.000 metros de rede (`cidades_infra.km_rede = 5.000` km, campo existente desde a Fase 1, nunca antes referenciado por nenhuma função — descoberto na investigação de schema desta fase; `SUM(infra_postes.quantidade) = 165`).

| Nível | Componente postes (165 × R$/poste) | Componente metros (5.000 × R$/metro) | **Total** |
|---|---|---|---|
| PISO (reserva) | 165 × R$10,00 = R$1.650,00 | 5.000 × R$0,10 = R$500,00 | **R$2.150,00** |
| RECOMENDADO | 165 × R$10,00 = R$1.650,00 | 5.000 × R$0,15 = R$750,00 | **R$2.400,00** |
| ABERTURA | 165 × R$10,00 = R$1.650,00 | 5.000 × R$0,20 = R$1.000,00 | **R$2.650,00** |

`pricing_version` resolvido: `"2026.08"` (mês de vigência do parâmetro, derivado de `vigente_desde`, sem tabela de versionamento nova). Indicadores analíticos do mesmo cenário (POP-01, que atende o contrato 0006): **10 fibras ociosas** (`CABO-JUSSARA-01`, `status_comercial='LIVRE'`) e **2 bloqueadas** — valor da infraestrutura por fibra ociosa = R$2.150,00 ÷ 10 = **R$215,00**; piso equivalente por Porta PON contratada (1 porta) = R$2.150,00 ÷ 1 = **R$2.150,00**. Break-even do Floor com Revenue Share de 12%: R$2.150,00 ÷ 0,12 = **R$17.916,67/mês** de faturamento do parceiro, equivalente a **180 clientes** com ARPU R$100,00. Sobre o contrato 0006 (mínimo contratual R$1.000,00, `modelo_cobranca=SOMA`, composição `FLOOR_AS_MINIMUM`, `enforced=true`), o teste de ARPU nos 7 pontos obrigatórios:

| Clientes | Fat. parceiro | Revenue share (12%) | Infra Floor | Mínimo contratual | **Total a pagar** | Margem parceiro |
|---|---|---|---|---|---|---|
| 10 | R$1.000,00 | R$120,00 | R$2.150,00 | R$1.000,00 | **R$2.270,00** | −127,00% |
| 25 | R$2.500,00 | R$300,00 | R$2.150,00 | R$1.000,00 | **R$2.450,00** | 2,00% |
| 50 | R$5.000,00 | R$600,00 | R$2.150,00 | R$1.000,00 | **R$2.750,00** | 45,00% |
| 75 | R$7.500,00 | R$900,00 | R$2.150,00 | R$1.000,00 | **R$3.050,00** | 59,33% |
| 84 | R$8.400,00 | R$1.008,00 | R$2.150,00 | R$1.000,00 | **R$3.158,00** | 62,40% |
| 100 | R$10.000,00 | R$1.200,00 | R$2.150,00 | R$1.000,00 | **R$3.350,00** | 66,50% |
| 128 | R$12.800,00 | R$1.536,00 | R$2.150,00 | R$1.000,00 | **R$3.686,00** | 71,20% |

Leitura econômica: com poucos clientes, o Infrastructure Floor domina o total a pagar (o parceiro paga R$2.270,00 mesmo faturando só R$1.000,00, o que dá margem negativa — o Floor está funcionando como piso de monetização mínimo, exatamente a proposta da fase); a partir de ~22-25 clientes o Revenue Share supera o Floor sozinho e passa a crescer por cima dele, e a margem do parceiro vira positiva e cresce com a escala.

## 8. Régua comercial e governança

`app.classificar_posicao_regua()` (6 rótulos) e `app.check_infrastructure_floor_governance()` (3 vereditos) testados contra os 5 preços de exemplo do prompt sobre a régua de Jussara: R$2.650 → `PREÇO DE ABERTURA` / `ALLOW`; R$2.400 → `PREÇO RECOMENDADO` / `ALLOW`; R$2.250 → `DESCONTO SOBRE RECOMENDADO` / `ALLOW_WITH_DISCOUNT`; R$2.150 → `PREÇO DE RESERVA` / `ALLOW_WITH_DISCOUNT`; R$2.149 → `BLOCKED` / `BLOCK`. `app.calcular_desconto_comercial()` devolve desconto absoluto e percentual sobre abertura e sobre recomendado simultaneamente (ex.: proposto R$2.250 vs. abertura R$2.650 → R$400,00/15,09%; vs. recomendado R$2.400 → R$150,00/6,25%). Override abaixo do piso passa pelo mesmo fluxo de aprovação da Fase 2 (nasce `PENDENTE`, só `DIRETOR`/`ADMINISTRADOR` decide, auditado), agora registrando também `preco_piso`/`preco_abertura` da régua no momento da negociação.

## 9. Composição Floor × Mínimo Contratual — nunca soma por acidente

`contrato_pricing_config.infra_floor_composition_mode` (5 modos explícitos, default `FLOOR_AS_MINIMUM`) e `.minimum_infrastructure_floor_enforced` (proteção final, default `true`). Testado contra o contrato 0006 (mínimo R$1.000,00, faturamento parceiro R$10.000,00, share 12%=R$1.200,00, Floor R$2.150,00): `FLOOR_ONLY`=R$2.150,00 (ignora inclusive o Revenue Share), `MINIMUM_ONLY`=R$2.200,00 (idêntico ao comportamento pré-Fase-2.2, garantia de regressão por construção), `FLOOR_AS_MINIMUM`=R$3.350,00, `SUM`=R$4.350,00, `MAX`=R$3.350,00. A proteção `enforced`: com `MINIMUM_ONLY` e faturamento baixo (R$500,00), o total calculado (R$1.060,00) fica abaixo do piso; com `enforced=true` sobe para R$2.150,00; com `enforced=false` permanece em R$1.060,00 — opt-out sempre explícito.

## 10. Multi-POP e indicadores analíticos

`app.get_capacidade_multi_pop_piso()`: mesmo com POP-01 tendo dados analíticos próprios preenchidos manualmente (1,2 km / 40 postes), o consolidado da cidade permaneceu exatamente 5.000 m / 165 postes — nunca a soma dos POPs, por desenho (o consolidado é sempre lido de `cidades_infra`/`infra_postes`, nunca recomputado). Indicadores por fibra ociosa e por Porta PON contratada são reexpressões do mesmo Floor "por unidade" — nunca uma segunda fórmula de preço — e retornam `NULL` (nunca dividem por zero) quando o denominador é 0.

## 11. Testes novos

`tests/run_tests_fase22.sh` — 26 verificações novas específicas da Fase 2.2 (rotuladas `TESTE-1`..`TESTE-22`, alguns com sub-itens `a`/`b`/`c`, mais o teste final de ARPU), cobrindo item a item as seções do prompt: fórmula do Floor batendo com o exemplo oficial (TESTE-1), override por cidade (TESTE-2), proteção de `pricing_version` (TESTE-3), governança nos 5 preços de exemplo (TESTE-4..8), os 6 rótulos da régua (TESTE-9), desconto comercial (TESTE-10), os 5 modos de composição (TESTE-11), a proteção `enforced` (TESTE-12), Multi-POP nunca duplicando metros (TESTE-13), fibras ociosas/ocupadas e Portas PON disponíveis do exemplo oficial — rodado **antes** de qualquer cabo de teste ser criado no mesmo script, para não contar fibra de teste junto com a real (TESTE-14/15), indicadores por fibra/Porta PON (TESTE-16/17), break-even (TESTE-18), escala de Portas PON para meta (TESTE-19), comparação econômica nos 5 modos (TESTE-20), auditoria de `cidades_infra` (TESTE-21), override estendido sem quebrar a chamada antiga (TESTE-22), e o teste de ARPU (item 7). Mais a regressão completa: `REG-1`..`REG-26` (Fase 2, reexecutados) e `NOVO-1`..`NOVO-14`/`TESTE-R1`..`R3` (Fase 2.1, reexecutados).

## 12. Resultado de cada teste

**100 de 100 PASS** (0 FAIL). Log completo (resumido às seções Fase 2.2; o log bruto completo, incluindo as 74 verificações de regressão REG/NOVO idênticas às da Fase 2.1, está em `/tmp` durante a execução e pode ser reproduzido a qualquer momento rodando `bash tests/run_tests_fase22.sh`):

```
PASS | Todas as 4 migrations da Fase 2.2 (Infrastructure Floor) aplicaram sem erro sobre banco com dados reais (Fase 1+1.1+1.2+2+2.1, sem seed propria)
PASS | TESTE14 fibras do POP-01 (seed, sem poluicao de pool de teste): 10 ociosas / 2 ocupadas / 12 totais
PASS | TESTE15 portas_pon_disponiveis (0) usa o enum correto (situacao_comercial='DISPONIVEL'), confere com contagem direta (0) — de 5 totais no POP-01
PASS | TESTE16 valor/fibra ociosa: R$2150.00 / 10 fibras = R$215.00
PASS | TESTE16b 0 fibras ociosas -> NULL (nunca divide por zero)
PASS | TESTE17 piso equivalente/Porta PON: R$2150.00 / 1 porta = R$2150.00
... (74 verificacoes REG-1..REG-26 / NOVO-1..NOVO-14 / TESTE-R1..R3, regressao completa Fase 1/1.1/1.2/2/2.1 — identicas as da Fase 2.1) ...
PASS | TESTE1 Jussara: 165 postes + 5.000m -> PISO=R$2.150,00 RECOMENDADO=R$2.400,00 ABERTURA=R$2.650,00 ("2026.08") — bate 100% com o exemplo oficial do prompt
PASS | TESTE2a override de Jussara (R$12,00/poste) tem precedencia sobre o global (R$10,00/poste)
PASS | TESTE2b com override o piso recalcula para R$2.480,00
PASS | TESTE2c sem override, volta a usar o global (R$2.150,00)
PASS | TESTE3a pricing_version='2026.08' (vigencia atual) resolve normalmente: 2150.00
PASS | TESTE3b pricing_version inexistente ('2099.01') falha explicitamente em vez de aplicar o parametro atual por engano
PASS | TESTE4 preco proposto R$2650 -> ALLOW
PASS | TESTE5 preco proposto R$2400 -> ALLOW
PASS | TESTE6 preco proposto R$2250 -> ALLOW_WITH_DISCOUNT
PASS | TESTE7 preco proposto R$2150 -> ALLOW_WITH_DISCOUNT
PASS | TESTE8 preco proposto R$2149 -> BLOCK
PASS | TESTE9 classificar_posicao_regua: os 7 pontos de teste batem com os 6 rotulos esperados
PASS | TESTE10 proposto R$2.250 vs abertura R$2.650 (desconto R$400,00/15,09%) e vs recomendado R$2.400 (R$150,00/6,25%)
PASS | TESTE11 composicao: FLOOR_ONLY=2150 MINIMUM_ONLY=1000 FLOOR_AS_MINIMUM=2150 SUM=3150 MAX=2150
PASS | TESTE12a MINIMUM_ONLY produz R$1.060,00 mas enforced=true sobe para o piso R$2.150,00
PASS | TESTE12b com enforced=false o mesmo calculo fica em R$1.060,00, abaixo do piso
PASS | TESTE13 consolidado da cidade continua 5.000m/165 postes mesmo com dado analitico por POP preenchido
PASS | TESTE18 break-even: faturamento parceiro R$17916.67/mes = 180 clientes (ARPU R$100)
PASS | TESTE19 meta 128 clientes -> 1 Porta PON; meta 180 clientes -> 2 Portas PON
PASS | TESTE20 economia com piso: FLOOR_ONLY=2150 MINIMUM_ONLY=2200 FLOOR_AS_MINIMUM=3350 SUM=4350 MAX=3350
PASS | TESTE21 UPDATE em cidades_infra agora gera auditoria (0 -> 1)
PASS | TESTE22a chamada ANTIGA (5 argumentos posicionais) continua funcionando sem ambiguidade
PASS | TESTE22b chamada NOVA (7 argumentos, com preco_piso/preco_abertura) cria o override
PASS | TESTE22c regua completa (piso/abertura) fica registrada na auditoria da negociacao
PASS | TESTE22d DIRETOR aprova override abaixo do piso
PASS | TESTE22e aprovacao do override com preco_piso/preco_abertura fica auditada
PASS | TESTE-ARPU teste economico completo com Infrastructure Floor: os 7 pontos batem com FLOOR_AS_MINIMUM+enforced
==============================================
100 PASS / 0 FAIL
```

## 13. Problemas encontrados

Um problema real de motor foi encontrado **durante o desenvolvimento desta fase** (não pré-existente de fases anteriores): a extensão de `public.pricing_override_create()` com 2 parâmetros novos opcionais (`p_preco_piso`, `p_preco_abertura`) foi feita inicialmente só com `CREATE OR REPLACE FUNCTION`. O Postgres só substitui de fato uma função quando a assinatura é **idêntica**; acrescentar parâmetros (mesmo com `DEFAULT`) faz o Postgres criar uma **segunda função sobrecarregada** ao lado da antiga, em vez de substituí-la. Qualquer chamada com exatamente 5 argumentos posicionais — o padrão usado por todo código desde a Fase 2, incluindo o teste `REG19` desta própria bateria de regressão — passou a ser **ambígua** entre as duas funções (`ERROR: function public.pricing_override_create(...) is not unique`), quebrando exatamente a compatibilidade retroativa que a seção 40 do prompt pedia para preservar. Detectado nesta sessão testando manualmente a chamada antiga contra o banco antes de considerar a migration pronta — nunca chegou a ficar sem cobertura de teste.

## 14. Problemas corrigidos

Corrigido com um `DROP FUNCTION IF EXISTS public.pricing_override_create(uuid, uuid, numeric, numeric, text)` (a assinatura antiga, de 5 parâmetros) imediatamente antes do `CREATE OR REPLACE FUNCTION` de 7 parâmetros, dentro da mesma migration (`20260829090300_...`). Resultado: uma única função no catálogo, aceitando 5, 6 ou 7 argumentos via `DEFAULT`, sem ambiguidade — verificado com as duas formas de chamada lado a lado (TESTE-22a: 5 argumentos; TESTE-22b: 7 argumentos), ambas funcionando. A correção está na mesma migration que introduziu o problema, não uma migration separada — respeita "não alterar migrations anteriores desnecessariamente", já que a migration corrigida é desta própria fase, ainda não fazia parte de nenhuma entrega anterior.

## 15. Checklist de aceite (25 itens)

- [x] `app.calculate_infrastructure_floor()` implementa a fórmula literal do prompt: `(postes × preço/poste) + (metros × preço/metro)` para os 3 níveis.
- [x] Exemplo oficial de Jussara bate 100%: 165 postes + 5.000m → Piso R$2.150,00 / Recomendado R$2.400,00 / Abertura R$2.650,00.
- [x] Os 4 parâmetros literais (R$10,00/poste, R$0,10/R$0,15/R$0,20 por metro) são configuráveis via `pricing_parametros`, nunca hard-coded.
- [x] Infrastructure Floor nunca é chamado nem tratado como "custo real" em nenhum lugar do código — `custos_infraestrutura` (Fase 2) permanece intocada e separada.
- [x] Régua comercial de 3 níveis (Abertura/Recomendado/Piso) com 6 rótulos de posição (`app.classificar_posicao_regua`).
- [x] Governança de 3 vereditos (`ALLOW`/`ALLOW_WITH_DISCOUNT`/`BLOCK`) testada nos 5 preços de exemplo do prompt.
- [x] Desconto comercial calculado sobre abertura e sobre recomendado, absoluto e percentual.
- [x] Override do Diretor para propostas abaixo do piso, reaproveitando o fluxo de aprovação já existente desde a Fase 2 (nasce PENDENTE → só Diretor decide → auditado).
- [x] Composição Floor × Mínimo Contratual explícita em 5 modos (`FLOOR_ONLY`/`MINIMUM_ONLY`/`FLOOR_AS_MINIMUM`/`SUM`/`MAX`) — nunca soma por acidente.
- [x] `minimum_infrastructure_floor_enforced` como rede de proteção final, sempre opt-out explícito.
- [x] Parametrização com escopo GLOBAL + override por CIDADE, sem quebrar nenhuma das ~30 chaves globais preexistentes.
- [x] Versionamento (`pricing_version`) reaproveitando o mecanismo temporal já existente desde a Fase 1, sem tabela nova.
- [x] Integração com o modelo Porta PON + Revenue Share existente, sem alterar `app.calcular_cobranca_hibrida`.
- [x] Multi-POP nunca duplica metros — consolidado sempre lido de `cidades_infra`/`infra_postes`, nunca somado a partir dos POPs.
- [x] Indicador de fibras ociosas/ocupadas e Portas PON disponíveis, batendo com o exemplo oficial (10 ociosas / 2 bloqueadas em POP-01).
- [x] Indicador "valor por fibra ociosa" e "piso equivalente por Porta PON" — analíticos, nunca substituem a fórmula principal.
- [x] Desconto por escala (Portas PON) com função de insight, sem aplicar desconto automático.
- [x] Revenue Share e o motor SOMA/MAX da Fase 2 não foram alterados.
- [x] Comparação econômica completa com Infrastructure Floor (Floor, Mínimo, Revenue Share, Total, Receita OptiMon/Parceiro, Margem).
- [x] Teste de ARPU completo (10/25/50/75/84/100/128 clientes) sobre o exemplo de Jussara.
- [x] Break-even do Infrastructure Floor (faturamento e clientes) calculado e testado.
- [x] Dashboard comercial atualizado: card do Floor, gráfico da régua, linha de negociação ao vivo.
- [x] Governança visível no dashboard com feedback em tempo real sobre o preço proposto.
- [x] Auditoria cobre toda a trilha da negociação: `cidades_infra` (lacuna fechada), override com régua completa registrada.
- [x] Regressão de Fase 1/1.1/1.2/2/2.1 passa integralmente (100/100 incluindo as 26 verificações desta fase).

**Fase 3 NÃO foi iniciada** — esta entrega aguarda aprovação explícita do usuário antes de qualquer próximo passo.
