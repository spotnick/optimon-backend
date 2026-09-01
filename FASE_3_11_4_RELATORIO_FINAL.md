# OptiMon — Relatório Final: Fase 3.11.4 — Auditoria e Correção do Envio Real de Assinatura Eletrônica

Data: 31/08/2026. Escopo: envelope real `571aa526-dd1e-4345-85e5-71b30ce68e8e` (3 signatários
mostrados como ENVIADO, nenhum recebeu e-mail) e a correção definitiva da causa raiz.

---

## PROVEDOR

Nenhum provedor de assinatura ICP-Brasil qualificado (D4Sign/Clicksign/DocuSign/ZapSign/
Autentique) está contratado ou parcialmente integrado neste projeto — confirmado por grep em
todo o repositório: esses nomes só aparecem como exemplos em comentário, nunca em código real.

O único provedor que já existia (`MockHomologacaoProvider`, Fase 2.5) nunca toca rede — cria
apenas estado local e um ID sintético (`MOCK-ENV-...`). É o motor usado por toda a homologação
funcional das Fases 2.5–3.10, mas nunca teve — e nunca teve a intenção de ter — capacidade de
enviar e-mail real.

Decisão de arquitetura tomada nesta fase, **com sua aprovação explícita e ciente do trade-off
legal**: o OptiMon passa a enviar o link de assinatura por e-mail diretamente via **Resend**
(mesmo client transacional já em produção desde a Fase 3.11.3 para o OTP de aceite de
proposta) — sem depender de nenhum provedor ICP-Brasil terceirizado. Isso é rotulado de forma
consistente e honesta em todo o sistema (banco, e-mail, tela de assinatura) como **assinatura
eletrônica simples**, não ICP-Brasil qualificada. Se no futuro for necessário ICP-Brasil
qualificada para algum tipo de documento, a integração é feita através do tipo de provedor
`ICP_BRASIL_PROVEDOR_EXTERNO`, que já existe no schema para essa finalidade futura.

## ARQUITETURA

```
CRIAR CONTRATO → CRIAR ENVELOPE (signature_envelopes, status=CRIADO)
  → ADICIONAR SIGNATÁRIOS (signature_signers, status=PENDENTE)
  → ENVIAR ENVELOPE (POST /envelopes/:id/send)
      → provider.tipo = OPTIMON_INTERNO_RESEND?
          → para cada signatário: gera token de acesso individual (64 hex, CSPRNG,
            30 dias) → monta link {PUBLIC_APP_URL}/assinar/{token} → envia por Resend
            (api/lib/emailService.js) → só grava ENVIADO se o Resend de fato aceitou
            (retornou email_id) — qualquer outro resultado grava ERRO_ENVIO com a causa
          → envelope só vira ENVIADO se ≥1 signatário teve envio real aceito; senão
            ERRO_ENVIO
      → provider.tipo = ICP_BRASIL_HOMOLOGACAO_MOCK (legado)?
          → comportamento original preservado (seção 17 — nada quebrado)
  → WEBHOOK do Resend (mesmo endpoint da Fase 3.11.3, reaproveitado): email.delivered/
    bounced/complained/failed → ENTREGUE / erro registrado no signatário
  → signatário abre o link (/assinar/:token, página pública) → ABERTO
  → signatário assina (nome+CPF+declaração explícita) → ASSINADO
  → quando todos os OBRIGATÓRIOS assinaram → envelope ASSINADO → validação → VALIDADO
```

Nenhuma segunda solução foi criada onde já existia uma: o webhook do Resend é o mesmo
endpoint da Fase 3.11.3 (só ganhou um fallback de busca); a URL base do link é a mesma
`PUBLIC_APP_URL`/`CORS_ALLOWED_ORIGINS` já usada para o e-mail de redefinição de senha.

## ENVELOPE 571AA526 (status real — CONFIRMADO com dados reais de produção em 01/09/2026)

Produção está na **Fase 3.11.3** (`tem_fase_3_11_2=true`, `tem_fase_3_11_3=true`,
`tem_fase_3_11_4=false`) — a migration desta fase (`20261006090000...sql`) ainda **não foi
aplicada** lá.

O envelope usou o provider **"Teste Interno"** (`id=a2b1ca4a-...`), **tipo
ICP_BRASIL_HOMOLOGACAO_MOCK**, ambiente HOMOLOGACAO — ou seja, mesmo em produção, nenhum
provedor real (nem ICP-Brasil terceirizado, nem o novo `OPTIMON_INTERNO_RESEND`) jamais foi
usado para este contrato. `provider_envelope_id = "MOCK-ENV-d59e0a68-..."` confirma o formato
sintético gerado pelo `MockHomologacaoProvider`, que nunca toca rede.

A trilha de auditoria completa prova a causa raiz de forma definitiva: às 23:03:46.73603 (UTC,
31/08), o envelope e os 3 signatários mudam de CRIADO→ENVIADO **na mesma linha de auditoria,
no mesmíssimo timestamp, até o microssegundo** — só possível numa única transação de banco que
marca tudo de uma vez, nunca 3 chamadas HTTP reais e independentes a um provedor de e-mail
(essas teriam timestamps ligeiramente diferentes por causa do round-trip de rede). Zero
eventos em `signature_events` (nenhum webhook jamais recebido) e zero linhas em
`documentos_evidencias` — nenhum provedor real jamais foi contatado.

Depois disso, alguém tentou **"Reenviar"** duas vezes — para Rodrigo (borghi@outlook.pt) às
01/09 00:13:35 e para Rodrigo (rodrigo@nicknetwork.com.br) às 01/09 00:14:15
(`reenvios_count: 0→1` em ambos, ação `SIGNATURE_SIGNER_RESEND`) — mas como a função legada
`app.reenviar_assinatura_signatario` (Fase 3.11.2) também marca ENVIADO de forma incondicional,
esses 2 reenvios **também não dispararam nenhum e-mail real**, pelo mesmíssimo motivo. Nadia
(cussolinnadia@gmail.com) nunca teve nenhum reenvio tentado — segue com o `enviado_em`
original de 31/08 23:03:46.

**Status atual (01/09/2026)**: envelope `571aa526` continua com `status=ENVIADO`,
`erro_mensagem=null` (o sistema não registra erro porque, do ponto de vista do código antigo,
"deu certo" — mesmo sem nada ter sido enviado). Os 3 signatários continuam `status=ENVIADO`,
`entregue_em`/`aberto_em`/`assinado_em` todos `null`. Nenhum documento assinado existe.

### O que fazer com este envelope específico

Ele não pode simplesmente "virar" `OPTIMON_INTERNO_RESEND` — o provider de um envelope é fixo
desde a criação. O caminho limpo, usando o que esta fase já entrega, é: (1) aplicar a
migration `20261006090000...sql` em produção; (2) cadastrar (ou confirmar que já existe) um
provider com `tipo=OPTIMON_INTERNO_RESEND`; (3) cancelar o envelope 571aa526 (ação
DIRETOR/ADMINISTRADOR — o histórico dele fica preservado, nunca apagado); (4) criar um novo
envelope para o mesmo contrato (`b0001737-a415-413c-b7d9-75ddde36a398`) com o provider novo,
adicionar os mesmos 3 signatários e enviar de verdade.

## CAUSA RAIZ (provada, não presumida)

`app.enviar_envelope_para_assinatura` (Fase 2.5/3.11.2) marcava `status='ENVIADO'` no
envelope e em **todos** os signatários de forma **incondicional**, no mesmo instante em que a
rota era chamada — independente de o provider ter, de fato, feito qualquer chamada de rede.
Como o único provider implementado (`MockHomologacaoProvider`) nunca toca rede, todo envelope
deste sistema, desde sempre, ficava ENVIADO sem nenhuma prova de envio real. Isso explica
exatamente o sintoma relatado: 3 signatários com `Status: ENVIADO` / `Enviado em:
31/08/2026 20:03:46` e `Entregue: — / Aberto: — / Assinado: —`.

Confirmado por leitura de código, não presumido — grep completo do repositório não encontrou
nenhuma referência real (só em comentário) a nodemailer/Resend/SendGrid/SMTP em nenhum lugar
do motor de assinatura anterior a esta fase.

## CORREÇÃO (mudanças reais aplicadas)

- **Migration** `20261006090000_phase_3_11_04_assinatura_envio_real_resend.sql`: novo status
  `ERRO_ENVIO` (envelope e signatário); novo tipo de provider `OPTIMON_INTERNO_RESEND`;
  colunas `token_acesso`/`token_expira_em`/`email_provider_id`/`email_canal` em
  `signature_signers`; 10 novas ações de auditoria semântica; 7 novas funções `SECURITY
  DEFINER`/`SECURITY INVOKER` (gerar link, registrar envio real, finalizar envio do
  envelope, ver/assinar/recusar pelo link, status de e-mail por `provider_id`); extensão de
  `app.contrato_assinatura_status` com `provider_nome`/`provider_tipo`/`ultimo_evento`.
- **`api/lib/signatureProvider.js`**: novo `ResendInternoProvider` (usa
  `api/lib/emailService.js`, o mesmo client Resend da Fase 3.11.3).
- **`api/lib/signatureLinkNotifier.js` + `signatureLinkEmailTemplate.js`** (novos, mirror
  direto de `otpNotifier.js`/`otpEmailTemplate.js`): envio real do link por e-mail, com
  fallback DEV_LOG que nunca finge sucesso em produção.
- **`api/routes/signatures.js`**: `POST /envelopes/:id/send` e `.../resend` reescritos para
  o provider `OPTIMON_INTERNO_RESEND` — envio real por signatário, `ENVIADO` só gravado após
  confirmação (`registrar_envio_signatario`).
- **`api/routes/signaturesExternal.js`** (novo, sem autenticação, mirror de
  `proposalsExternal.js`): visualizar/assinar/recusar pelo link individual.
- **`web/src/pages/SignExternal.jsx`** (novo) + rota `/assinar/:token` em `App.jsx`.
- **`web/src/pages/ContractDetail.jsx`**: painel "Assinatura eletrônica do contrato" agora
  mostra Provedor/Criado em/Último evento em nível de envelope, e um banner "⚠️ FALHA NO
  ENVIO" com detalhes técnicos visíveis só para ADMINISTRADOR quando `status=ERRO_ENVIO`.
- **`api/routes/emailWebhooks.js`**: mesmo endpoint da Fase 3.11.3, com fallback para eventos
  de e-mail de assinatura.

### 2 bugs reais encontrados e corrigidos durante os próprios testes desta fase (nunca escondidos)

1. **Bug introduzido nesta mesma fase, pego pelos testes antes da entrega**: o código inicial
   de `enviarLinksAssinatura` gravava `p_sucesso: true` sempre que o notifier não lançava
   erro — mas o fallback DEV_LOG (sem `RESEND_API_KEY`) retorna normalmente com
   `enviado: false`, sem lançar. Resultado: em ambiente sem Resend configurado, o sistema
   voltaria a marcar ENVIADO sem prova real — exatamente a classe de bug que esta fase existe
   para eliminar. Corrigido: só grava sucesso quando `envio.enviado === true` (canal RESEND);
   DEV_LOG vira `ERRO_ENVIO` com a mensagem honesta, mesmo padrão já usado para o OTP de
   proposta (`email_status=EMAIL_SOLICITADO`, nunca `EMAIL_ACEITO_PELO_RESEND`, em DEV_LOG).
2. **Gap real na função legada `app.reenviar_assinatura_signatario`** (Fase 3.11.2): sua
   lista de status do envelope que admitem reenvio não incluía o novo `ERRO_ENVIO` — um
   envelope que falhasse o envio ficaria com o botão "Reenviar" bloqueado exatamente quando
   mais se precisa dele. Corrigido acrescentando `ERRO_ENVIO` à lista.

Ambos encontrados pelos TESTE-99/100 (o primeiro) e TESTE-115 (o segundo) na suíte automatizada
abaixo, corrigidos, e a suíte inteira re-executada até 0 FAIL.

## TESTE REAL: PASS

Suíte `tests/run_tests_fase311.sh` completa (herdada das Fases 3.11–3.11.3 + nova seção
"FASE 3.11.4"): **125 PASS / 0 FAIL**, incluindo idempotência real das 5 migrations (rodada 2
vezes, a 2ª contra um banco que já tinha a Fase 3.11.4 aplicada). Cobre o envelope
`TESTE-E2E-ASSINATURA-3114` (2 signatários, provider `OPTIMON_INTERNO_RESEND`) de ponta a
ponta: criar → adicionar signatários → enviar → **confirmar ERRO_ENVIO real (nunca ENVIADO
falso) neste ambiente sem `RESEND_API_KEY`** → abrir link → assinar (1º signatário) → recusar
(2º signatário) → envelope RECUSADO. Mais 10 cenários negativos (seção 14): token inexistente,
declaração ausente, CPF ausente, assinatura duplicada, token de outro signatário, motivo de
recusa ausente, reenvio de quem já assinou, provider inexistente, envelope sem signatário.

**Limitação honesta, documentada, não escondida**: este sandbox de desenvolvimento não tem
`RESEND_API_KEY` real configurada (nenhuma conta Resend disponível aqui) — por isso o teste
prova que o sistema **nunca finge ENVIADO sem prova real** (o resultado correto e esperado
neste ambiente é `ERRO_ENVIO`), mas não prova, sozinho, que um e-mail chega de verdade numa
caixa de entrada. Para provar isso ponta a ponta, os passos abaixo do RESEND_API_KEY real em
produção (já configurada, confirmado pelo usuário na Fase 3.11.3) e o teste manual com um
e-mail de homologação real ainda precisam ser feitos por você em produção ou stage.

## E-MAIL RECEBIDO: PENDENTE (não é PASS nem FAIL — não testado com credencial real)

Nenhum e-mail real foi enviado nesta sessão porque este ambiente não tem `RESEND_API_KEY`.
Isso é uma limitação de ambiente, documentada, nunca apresentada como sucesso. Para fechar
este item (seção 19, obrigatório para "resolvido"): crie um envelope de teste em
produção/stage com o novo provider `OPTIMON_INTERNO_RESEND` e confirme o recebimento real em
uma caixa de entrada de homologação.

## WEBHOOK: PASS

Assinatura Svix válida aceita (200); assinatura adulterada rejeitada (401); sem
`RESEND_WEBHOOK_SECRET` configurado, recusa processar (500 controlado); evento
`email.delivered` com `email_provider_id` de e-mail de assinatura (não de OTP de proposta)
atualiza corretamente o signatário para `ENTREGUE` via o fallback novo, no mesmo endpoint já
existente — nenhum segundo webhook criado.

## ASSINATURA: PASS (assinatura eletrônica simples — nunca apresentada como ICP-Brasil qualificada)

Fluxo completo testado: abrir link → `ABERTO` (nunca confundido com assinar) → assinar com
nome+CPF+declaração explícita → `ASSINADO` com `certificado_info.tipo =
'ASSINATURA_ELETRONICA_SIMPLES'`, `metodo = 'LINK_UNICO_EMAIL_RESEND'` → envelope só vira
`ASSINADO`/`VALIDADO` quando **todos** os signatários obrigatórios assinaram de verdade
(testado com um signatário obrigatório recusando — envelope corretamente vira `RECUSADO`,
nunca `ASSINADO`). Assinatura duplicada bloqueada; token de um signatário nunca afeta outro.

## E2E: 125/125 PASS

Suíte completa herdada (Fases 3.11/3.11.2/3.11.3) + nova seção Fase 3.11.4 — 0 regressão em
tudo que já funcionava (OTP da proposta, Resend do OTP, aceite externo, auditoria, contrato,
vínculo proposta↔contrato, permissões, segurança).

---

## O que falta para "resolvido" de fato (seção 19 do pedido — nunca declarado sem prova)

1. ~~Investigar o envelope 571aa526~~ — **feito**, com dados reais de produção (ver seção
   acima): causa raiz confirmada, provider MOCK/homologação, zero envio real, 2 reenvios que
   também não enviaram nada.
2. Aplicar a migration `20261006090000_phase_3_11_04_assinatura_envio_real_resend.sql` em
   produção (Supabase) — ainda não aplicada lá, confirmado pelo bloco 0 do SQL
   (`tem_fase_3_11_4=false`).
3. ~~Confirmar `RESEND_API_KEY`/`RESEND_FROM_EMAIL` na Railway~~ — **confirmado por você**:
   já configuradas há tempo (é o que faz o resto do envio de e-mail do sistema funcionar
   hoje). Nenhuma variável nova é necessária — o link de assinatura usa exatamente a mesma
   chave. Falta só confirmar `PUBLIC_APP_URL` (usada para montar o link
   `{PUBLIC_APP_URL}/assinar/{token}`) — se não estiver setada, o sistema tenta um fallback
   a partir de `CORS_ALLOWED_ORIGINS`, mas não é recomendado depender dele em produção.
4. Cadastrar um provider `tipo=OPTIMON_INTERNO_RESEND` em produção (ou confirmar que já
   existe) e decidir o que fazer com o envelope 571aa526 (cancelar + recriar — ver seção
   acima) e com os 3 signatários reais (Rodrigo/rodrigo@nicknetwork.com.br,
   Nadia/cussolinnadia@gmail.com, Rodrigo/borghi@outlook.pt).
5. Um teste manual real em produção/stage: enviar o novo envelope, confirmar o e-mail
   chegando numa caixa real, abrir o link, assinar.

Até esses itens serem concluídos por você, este relatório considera a correção **provada no
nível de código e de teste automatizado, e a causa raiz do envelope 571aa526 confirmada com
dados reais**, mas a **entrega real de e-mail em produção ainda não confirmada** — exatamente
a distinção que esta fase inteira existe para impor.
