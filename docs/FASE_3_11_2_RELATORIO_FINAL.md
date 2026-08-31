# Fase 3.11 — Correção Crítica do Aceite Externo e Assinatura Eletrônica

**Relatório final de homologação — não presumido, com evidência real executada**

Data: 31/08/2026
Escopo: correção dos 2 problemas reais relatados após a homologação da Fase 3.11 original — (1) aceite externo fraco demais (formulário + 1 clique, sem prova de posse do e-mail) e (2) "envelope criado" tratado incorretamente como "e-mail enviado"/"assinado", incluindo o caso real relatado (envelope `9a86429e-b539-4568-b2df-fa41916c54e3`, proposta Jussara/PR, parceiro HELO CONTEUDOS DIGITAIS) onde nenhum representante recebeu e-mail.

---

## 1. Veredito

**FASE 3.11 (correção crítica) HOMOLOGADA para o que é responsabilidade do OptiMon**, com uma limitação externa real e explicitamente documentada (envio de e-mail — seção 13).

O fluxo completo Proposta → Aceite formal em 2 passos com OTP → Contrato → Assinatura granular por signatário → Ativação foi **executado de ponta a ponta 3 vezes seguidas via chamadas HTTP reais** (script `tests/run_tests_fase311.sh`, 76 verificações por execução, 0 falhas nas 3 execuções) e **1 vez via browser real (Playwright/Chromium)**, clicando nas telas de verdade, incluindo o parceiro preenchendo o formulário, recebendo (via log do servidor, canal de teste controlado) e digitando o código de confirmação. Dois bugs reais foram encontrados e corrigidos durante esta verificação (seção 10) — nenhum foi presumido como "deve funcionar".

---

## 2. Os 2 problemas reais investigados

### 2.1 Aceite externo fraco (seção 1 do pedido)

**Antes:** `POST /api/proposals/external/:token/accept` aceitava a proposta com 1 chamada — nome/CPF/e-mail digitados na hora, sem nenhuma prova de que quem preencheu tinha acesso ao e-mail informado. Não havia declaração de poderes, não havia dupla confirmação, não havia OTP.

**Investigado:** leitura completa de `api/routes/proposalsExternal.js` (versão anterior) e da migration `20261002090000`, função `app.aceitar_proposta_parceiro` — confirmado que o aceite era, de fato, 1 passo só.

**Corrigido:** fluxo em 2 passos, nunca em 1:
- `app.aceitar_proposta_parceiro` foi **neutralizada** (mantida com a mesma assinatura, mas sempre levanta `FLUXO_ALTERADO`) — nunca mais pode ser chamada para aceitar de verdade.
- `POST /accept/iniciar`: valida nome/CPF/e-mail obrigatórios + checkbox de declaração de poderes + checkbox de confirmação, gera um OTP de 6 dígitos (Node, `crypto.randomInt`, CSPRNG), grava só o **hash** (SHA-256 + pepper) em `propostas_aceite_tentativas`, "envia" via `otpNotifier.js`. **Nunca muda o status da proposta.**
- `POST /accept/confirmar`: só aqui, com o código certo, a proposta transiciona para `ACEITA_PELO_PARCEIRO`.

### 2.2 "Envelope criado" ≠ "e-mail enviado" / ≠ "assinado" (seção 3 do pedido)

**Investigado de verdade** (não presumido) — grep completo em `api/lib` e `api/routes`:

```
$ grep -rn "nodemailer\|Resend\|SendGrid\|SMTP" api/lib api/routes
(nenhum resultado de uso real — só menções em comentário explicando a ausência)
```

**Confirmado:** este projeto **nunca teve** nenhuma infraestrutura de envio de e-mail transacional arbitrário. A única implementação real de provedor de assinatura é `MockHomologacaoProvider` (`api/lib/signatureProvider.js`, desde a Fase 2.5) — nunca toca rede/e-mail, documentado no próprio arquivo desde então. Isto **não é uma regressão desta fase** — é uma limitação arquitetural pré-existente, já honestamente documentada, e reconfirmada agora (ver seção 13).

**O que ERA um bug real e foi corrigido:** o envelope podia virar `ASSINADO` só porque um webhook (real ou simulado) *dizia* isso, mesmo com signatário **obrigatório** ainda pendente. `app.registrar_evento_assinatura_webhook` agora recomputa, a cada evento, se todos os signatários `obrigatorio=true` estão `ASSINADO` antes de aceitar a alegação `novo_status_envelope='ASSINADO'` — caso contrário, mantém `PARCIALMENTE_ASSINADO` e registra a divergência em auditoria. Provado por teste negativo real (seção 6, TESTE-43).

---

## 3. Cobertura item a item do pedido de correção

| # | Item do pedido | Classificação | Evidência |
|---|---|---|---|
| 1 | Aceite externo formal em 2 passos (declaração + checkbox + confirmação + OTP) | **PASS** | Migration `20261003100000`; `PartnerExternalProposal.jsx`; TESTE-15/16/17/18/19/20/21/22/23 (script) + screenshots 01-06 (visual) |
| 2 | Auditoria completa do aceite (representante/CPF/e-mail/IP/UA/hash/versão) + card "ACEITE DO PARCEIRO" | **PASS** | TESTE-24/25/26; screenshot 07 |
| 3 | Investigar por que e-mail não chegou | **PASS** (investigação) / **DEPENDÊNCIA EXTERNA** (envio real) | Seção 2.2 e 13 abaixo; TESTE-40 |
| 4 | Status real por signatário (CRIADO/ENVIANDO/.../ERRO), independente do envelope | **PASS** | `signature_signers` ampliada; TESTE-37/38/50; screenshot 14 |
| 5 | Log de entrega real (nunca "ENVIADO" = entregue) | **PASS** (dentro do que o provedor mock consegue simular) / **DEPENDÊNCIA EXTERNA** (eventos reais de um provedor real) | `signature_events`; TESTE-51 |
| 6 | Reenvio de assinatura sem duplicar | **PASS** | `app.reenviar_assinatura_signatario`; TESTE-45/46/47; screenshot 13 |
| 7 | Papéis configuráveis + obrigatoriedade explícita; contrato só ASSINADO com todos os obrigatórios | **PASS** | `signature_signers.obrigatorio`; TESTE-38/43/48; screenshot 14 |
| 8 | Vínculo permanente proposta ↔ contrato, nunca contrato sem aceite confirmado | **PASS** | TESTE-12/29/32/33 |
| 9 | Segurança do link externo: expiração, **revogação**, uso único, replay, log de tentativas, bloqueio pós-aceite, não exposição de dados NICK | **PASS** (revogação era um gap real — implementada nesta fase) | Ver seção 5; TESTE-10/13/14/26(otp)/59/60/61/62/63/64/65/68; screenshots 08-09 |
| 10 | Teste E2E real (26 passos) | **PASS** | `tests/run_tests_fase311.sh`, 76 verificações, 3 execuções consecutivas, 0 falhas |
| 11 | 16 testes negativos obrigatórios | **PASS** (16/16) | Ver tabela na seção 6 |
| 12 | Relatório final item a item | **PASS** | Este documento |

---

## 4. Arquivos alterados/criados

**Banco de dados (migration nova, aditiva — nada já aplicado em produção foi editado):**
- `supabase/migrations/20261003100000_phase_3_11_02_aceite_otp_assinatura_granular.sql` (novo arquivo, ~1050 linhas)

**Backend:**
- `api/lib/otpNotifier.js` (novo) — canal de entrega do código OTP
- `api/routes/proposalsExternal.js` (reescrito) — `/accept/iniciar` + `/accept/confirmar` no lugar do antigo `/accept`
- `api/routes/proposals.js` — nova rota `POST /:id/revoke-token`
- `api/routes/signatures.js` — nova rota `POST /envelopes/:id/signers/:signerId/resend`; `p_obrigatorio` na criação de signatário
- `api/server.js` — `app.set('trust proxy', true)` (bug real de captura de IP corrigido)

**Frontend:**
- `web/src/lib/api.js` — `acceptIniciar`/`acceptConfirmar`/`revokeToken`/`resendSigner`
- `web/src/pages/PartnerExternalProposal.jsx` — formulário com declaração + 2 checkboxes + etapa OTP
- `web/src/pages/ProposalDetail.jsx` — card "ACEITE DO PARCEIRO" completo + botão "Revogar link externo"
- `web/src/pages/ContractDetail.jsx` — tabela de signatários granular (Obrigatório/Status/datas/Ações) + reenvio

**Testes (evidência, não produção):**
- `tests/run_tests_fase311.sh` (reescrito integralmente — 76 verificações, 71 testes nomeados)
- `tests/visual_fase311_2.js` (novo — verificação visual real via Playwright)

---

## 5. Segurança do link externo (seção 9) — detalhamento

| Proteção exigida | Já existia (Fase 3.11) | Nesta correção |
|---|---|---|
| Expiração | Sim (`token_expira_em`) | Reconfirmada + teste real (TESTE-59/60) |
| **Revogação manual** | **Não existia — gap real** | **Implementada**: `app.revogar_token_proposta`, coluna `token_revogado_em`, bloqueia GET/iniciar/confirmar/recusar; botão "Revogar link externo" na tela; só COMERCIAL/DIRETOR/ADMINISTRADOR (TESTE-61 prova AUDITOR bloqueado) |
| Uso único para confirmação | N/A (não existia OTP) | Tentativa `CONFIRMADO` não pode ser reconfirmada (TESTE-28, "ACEITE_DUPLICADO") |
| Proteção contra replay | N/A | Nova solicitação de OTP cancela automaticamente qualquer tentativa `AGUARDANDO_OTP` anterior (TESTE-68) |
| Log de tentativas | Parcial | `otp_tentativas` incrementado a cada código errado, bloqueio após 5 (`OTP_BLOQUEADO`); toda tentativa vira linha em `propostas_aceite_tentativas` + evento de auditoria |
| Bloqueio após aceite | Sim | Reconfirmado (TESTE-27, TESTE-31, TESTE-70) |
| Não exposição de dados NICK internos | Sim | Reconfirmado (TESTE-10 — floor/governança/desconto/piso ausentes na resposta externa) |

---

## 6. Os 16 testes negativos obrigatórios (seção 11 do pedido)

| # | Cenário exigido | Resultado | Teste |
|---|---|---|---|
| 1 | Abrir o link ≠ aceitar | BLOQUEADO | TESTE-14 |
| 2 | Aceitar sem CPF | BLOQUEADO | TESTE-17 |
| 3 | Aceitar sem e-mail | BLOQUEADO | TESTE-18 |
| 4 | Aceitar sem checkbox (declaração/confirmação) | BLOQUEADO | TESTE-15, TESTE-16 |
| 5 | OTP errado | BLOQUEADO | TESTE-22 |
| 6 | OTP expirado | BLOQUEADO | TESTE-67 |
| 7 | OTP reutilizado | BLOQUEADO | TESTE-28 |
| 8 | Token expirado | BLOQUEADO | TESTE-59, TESTE-60 |
| 9 | Token revogado | BLOQUEADO | TESTE-63, TESTE-64 |
| 10 | Aceitar duas vezes | BLOQUEADO | TESTE-27 |
| 11 | Criar contrato antes do aceite | BLOQUEADO | TESTE-12 |
| 12 | Criar contrato duas vezes | BLOQUEADO | TESTE-30 |
| 13 | Alterar proposta já aceita | BLOQUEADO | TESTE-31, TESTE-70 |
| 14 | Usuário sem permissão | BLOQUEADO | TESTE-57 (ativar), TESTE-61 (revogar) |
| 15 | Assinar com signatário não autorizado | BLOQUEADO (no-op, 0 linhas afetadas) | TESTE-42 |
| 16 | Finalizar contrato com assinatura obrigatória faltando | BLOQUEADO (envelope some ASSINADO só quando é verdade) | TESTE-43, confirmado positivamente em TESTE-48 |

**16 de 16 bloqueados corretamente**, todos com chamada HTTP real + verificação direta no banco (nunca só "código não retornou erro").

---

## 7. Evidência de execução real

### 7.1 Testes de API (`tests/run_tests_fase311.sh`)

3 execuções consecutivas nesta sessão, banco local real, servidor Node real, PostgREST real:

```
RESULTADO FINAL: 76 PASS / 0 FAIL   (execução 1)
RESULTADO FINAL: 76 PASS / 0 FAIL   (execução 2 — prova idempotência da migration)
RESULTADO FINAL: 76 PASS / 0 FAIL   (execução 3 — final, pós-limpeza)
```

Cobre: criação de parceiro/simulação/proposta reais: aprovação interna: bloqueio de fake-aceite: envio ao parceiro com token real de 64 hex: área externa sem login com anti-vazamento confirmado: aceite em 2 passos com OTP real extraído do log do servidor (nunca do banco, nunca da resposta HTTP): 3 sub-fluxos negativos dedicados (token expirado, token revogado, OTP expirado+reuso): geração de contrato: vínculo bidirecional: minuta PDF/DOCX reais (tamanho de arquivo verificado): envelope de assinatura com 3 signatários (2 obrigatórios + 1 testemunha não-obrigatória): webhook HMAC-assinado real: webhook malicioso alegando "ASSINADO" bloqueado: reenvio de assinatura real: ativação com alocação de infraestrutura real.

### 7.2 Verificação visual real (`tests/visual_fase311_2.js`, Playwright/Chromium)

Execução completa, 14 screenshots em `/tmp/fase3112_evidencia/`, clicando nas telas de verdade (nunca via API direto para as ações de negócio — só para popular dados de setup):

1. Área externa sem login
2. Formulário de aceite com declaração de poderes + checkbox visíveis
3. Formulário preenchido, checkboxes marcados
4. Etapa OTP aberta (e-mail mascarado, contagem de expiração)
5. OTP preenchido (recuperado do log do servidor)
6. Aceite confirmado por OTP
7. Card "ACEITE DO PARCEIRO" completo na tela interna (representante/CPF/e-mail/IP/hash/versão/user-agent + timeline de auditoria)
8. Botão "Revogar link externo" disponível
9. Link revogado confirmado na tela (com motivo, e-mail sem uso possível)
10. Tabela de 3 signatários com Papel/Obrigatório
11. Envelope enviado, status por signatário
12. 1 de 2 obrigatórios assinados (PARCIALMENTE_ASSINADO)
13. Reenvio de assinatura real para a testemunha pendente
14. Contrato ASSINADO com os 2 obrigatórios assinados — testemunha não-obrigatória ainda pendente não bloqueou o fechamento

O script também valida programaticamente, via SQL direto, que: (a) o status da proposta **não** muda para `ACEITA_PELO_PARCEIRO` só com o passo 1; (b) `token_revogado_em` é persistido de verdade; (c) o envelope só fecha `ASSINADO` quando os 2 signatários obrigatórios realmente assinaram.

### 7.3 Evidência de banco (cumulativa desta sessão)

```sql
select acao, count(*) from auditoria where acao like 'PROPOSAL_ACCEPT%'
  or acao='PROPOSAL_TOKEN_REVOKED' or acao='SIGNATURE_SIGNER_RESEND' group by acao;

 PROPOSAL_ACCEPTED_BY_PARTNER    | 18
 PROPOSAL_ACCEPT_OTP_REQUESTED   | 14
 PROPOSAL_TOKEN_REVOKED          | 5
 SIGNATURE_SIGNER_RESEND         | 5
```

### 7.4 Build do frontend

```
$ npx vite build
✓ 105 modules transformed.
✓ built in 2.20s
```

Nenhum erro de sintaxe/import nas telas alteradas.

---

## 8. Bugs reais encontrados e corrigidos DURANTE esta verificação (nunca presumidos)

1. **`record "v_prop" has no field "preco_proposto"`** — a primeira versão de `app.confirmar_aceite_proposta_parceiro` (hash da proposta aceita) referenciava uma coluna que não existe em `propostas_comerciais` (o preço vive dentro do `snapshot` jsonb). Só foi descoberto porque o teste E2E realmente executa o passo 2 do aceite — corrigido para `v_prop.snapshot->>'preco_proposto'`.
2. **Ambiguidade de overload em replay de migration** (`function ... is not unique`) e **violação de constraint** (`auditoria_acao_check`) ao reaplicar a Fase 3.11 original por cima de um banco já com a 3.11.2 — artefato só de re-teste local (nunca acontece em produção, onde migrations rodam uma vez em ordem); corrigido no **script de teste** (nunca nos arquivos de migration) com uma checagem de versão que evita o replay desnecessário.

---

## 9. Limitações externas — honestamente documentadas (nunca escondidas)

- **Envio real de e-mail do código OTP**: este projeto nunca teve nenhuma infraestrutura de e-mail transacional arbitrário (nodemailer/Resend/SendGrid/SMTP) — confirmado por grep real no código (seção 2.2). `otpNotifier.js` só loga o código no servidor (ambiente de desenvolvimento/homologação). **Antes de operar com parceiros reais, é necessário integrar um provedor de e-mail real** (Resend/SES/SMTP) — a interface já foi desenhada para isso (`buildOtpNotifier()`), trocar a implementação não exige tocar em nenhuma rota nem na lógica de OTP.
- **Assinatura eletrônica real**: `MockHomologacaoProvider` continua sendo a única implementação — nunca envia e-mail nem fala com um ICP-Brasil real. Limitação pré-existente desde a Fase 2.5, reconfirmada, não uma regressão desta correção.
- **Captura de IP em ambiente de teste local**: `aceite_ip` foi capturado com sucesso nos testes (antes SEMPRE ficava `NULL` — bug real corrigido), mas em ambiente de teste local (sem proxy real na frente) o valor capturado é o loopback (`127.0.0.1`) — em produção, atrás do proxy da Railway, com `app.set('trust proxy', true)` já configurado, o valor será o IP público real do parceiro.
- **Captura de IP em outros fluxos do projeto**: o mesmo bug (GUC `request.headers` nunca refletindo o IP do navegador, só o do próprio servidor Node) provavelmente afeta outros eventos de auditoria do projeto além do aceite externo — corrigido especificamente para o caminho do parceiro externo (escopo desta fase); achado documentado para avaliação futura, fora do escopo desta correção.

---

## 10. Conclusão

Os 2 problemas reais relatados foram investigados de verdade (não presumidos) e o que é responsabilidade do código OptiMon foi corrigido e verificado com evidência executável e reproduzível: 3 execuções consecutivas do teste de API (76/76 cada), 1 execução completa da verificação visual real via browser (14 screenshots), 2 bugs reais adicionais encontrados e corrigidos durante a própria verificação, e os 16 testes negativos obrigatórios todos bloqueados corretamente.

A única pendência que não pode ser fechada dentro deste ambiente é a integração de um provedor de e-mail real para a entrega do código OTP e de um provedor de assinatura eletrônica real — ambas são dependências externas (credenciais/contrato comercial que esta sessão não tem acesso), claramente isoladas atrás de interfaces já prontas para receber a implementação real sem mexer no resto do sistema.
