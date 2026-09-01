# OptiMon — Relatório Final: Fase 3.11.5 — Correções pós-deploy (teste real de produção)

Data: 01/09/2026. Escopo: os 4 problemas reais que você reportou depois do primeiro teste de
ponta a ponta em produção (e-mail recebido, contrato assinado) da Fase 3.11.4.

---

## O QUE VOCÊ REPORTOU (verbatim)

1. "Email recebido, contrato assinado, mas ao clicar em Revisar documento (PDF) — Caminho do
   documento não encontrado" (404 real, visto no console do navegador).
2. "O campo de CPF está sem validação."
3. "Para assinatura do contrato deve ter token de validação para garantir quem está assinado."
4. "Após assinado o contrato deve ter como ser visualizado em PDF com todas as informações da
   assinatura."

Os 4 são reais. Nenhum foi descartado como "não é bug" — os 3 primeiros eram gaps de fato
ausentes no código; o 4º também. Cada um foi investigado até a causa raiz (nunca só
sintoma) e corrigido usando, sempre que possível, um padrão já provado em produção — nunca
uma segunda solução onde uma primeira já funcionava.

---

## ITEM 1 — "Caminho do documento não encontrado" (404)

### Causa raiz (confirmada por leitura de código, não presumida)

A rota `GET /api/signatures/external/:token/document` (Fase 3.11.4) lia a tabela
`signature_envelopes` diretamente com o cliente anônimo (`anonClient()`). A política de RLS
`signature_envelopes_select` é `to authenticated` — não existe nenhuma permissão para `anon`.
Uma leitura assim não dá erro: ela simplesmente devolve **0 linhas**, silenciosamente. O
código então tratava "0 linhas" como "documento não tem caminho salvo" e respondia 404 com a
mensagem exata que você viu.

Ou seja: o link de assinatura inteiro (ver, assinar, recusar) já funciona pelo token porque
passa por funções `SECURITY DEFINER` — mas a rota do documento, especificamente, tinha ficado
de fora desse padrão e lia a tabela direto. É um gap de implementação da própria Fase 3.11.4,
não um problema do RLS em si (o RLS está correto — protege a tabela; era a rota que precisava
passar por uma função escopada ao token, como todas as outras já fazem).

### Correção

Nova função `app.assinatura_externa_documento_original_path(p_token text)` — `SECURITY
DEFINER`, escopada ao token (nunca lê a tabela por ID livre), com o wrapper
`public.pricing_signature_external_documento_path` liberado para `anon`. A rota agora chama
essa RPC em vez de ler a tabela direto — mesmo padrão já usado por `assinatura_externa_por_token`
desde a criação da Fase 3.11.4.

### Item 1-B — 2ª camada do MESMO bug, encontrada no seu reteste real (após aplicar a correção acima)

Depois de aplicada a correção acima, você reportou que o erro mudou de "Caminho do documento
não encontrado" para **"Falha ao gerar link de download: Object not found"** — ou seja, a
correção funcionou (a rota agora encontra o caminho salvo no banco), mas surgiu um 2º bloqueio,
uma camada abaixo: no próprio Supabase **Storage**, não mais no banco.

**Causa raiz**: `supabase/storage_setup_fase25.sql` (Fase 2.5) restringe a leitura de
`storage.objects` do bucket `documentos` só a `authenticated` — nenhuma policy libera `anon`.
Isso nunca foi um problema para as telas internas (sempre um usuário logado), mas as rotas
*externas* de assinatura (`signaturesExternal.js`) nunca têm sessão logada — usam sempre
`anonClient()`, por design (o signatário não é um usuário do sistema). Quando essa rota chama
`createSignedUrl()`, a policy filtra a linha do objeto antes mesmo de gerar a assinatura, e a
Storage API do Supabase responde exatamente com "Object not found" — mesmo o arquivo existindo
de verdade no bucket. É a mesma classe de bug do item 1 original (RLS bloqueando `anon`), só
que na camada de Storage em vez da camada de banco — por isso a correção anterior (RPC
`SECURITY DEFINER`) resolveu a leitura do *caminho*, mas não alcança o Storage, que é um
serviço à parte, fora do Postgres.

**Correção**: nova policy `documentos_bucket_select_envelopes_anon` em
`storage.objects`, liberando `select` para `anon` **só** dentro do prefixo `envelopes/` (onde
exclusivamente os PDFs de assinatura — original e assinado — são gravados; os documentos de
proponente, em outro prefixo, continuam exigindo `authenticated`, sem nenhuma mudança). A
autorização real continua sendo o token opaco do signatário, já validado pela rota Node antes
de sequer chamar `createSignedUrl()` — esta policy só estende ao Storage a mesma decisão de
confiança que o banco já toma, nunca abre o bucket inteiro.

**Não pôde ser testado neste sandbox** (mesma limitação já documentada: não existe schema
`storage` no Postgres local) — é SQL para rodar manualmente no SQL Editor do seu projeto
Supabase real, junto com o restante de `storage_setup_fase25.sql` (idempotente: pode rodar o
arquivo inteiro de novo sem risco, `drop policy if exists` antes de cada `create`).

## ITEM 2 — CPF sem validação

### Causa raiz

Busca completa no repositório (`isValidCpf`/`validarCpf`/etc.) não encontrou nenhum validador
de CPF em lugar nenhum do sistema. O campo aceitava qualquer sequência de 11 dígitos,
incluindo `000.000.000-00` ou `111.111.111-11`.

### Correção

Algoritmo real de dígito verificador (módulo 11, duplo), implementado em dois lugares —
sempre o mesmo cálculo, nunca duas regras divergentes:

- `app.cpf_valido(p_cpf text)` no banco — é a validação que **realmente vale**, dentro de
  `app.assinatura_externa_assinar_iniciar` (item 3 abaixo). Não pode ser contornada chamando a
  API direto.
- `web/src/lib/cpf.js` (`isValidCpf`) no frontend — só feedback imediato na tela (borda
  vermelha, "CPF inválido"), mesmo algoritmo, nunca a fonte de verdade.

Testado à mão contra o CPF de teste conhecido `111.444.777-35` (dígitos 3 e 5, confirmados) e
contra sequências repetidas (`111.111.111-11`), rejeitadas por regra própria.

## ITEM 3 — Token de validação para garantir quem está assinando

### O que existia antes

Nada — a "assinatura" da Fase 3.11.4 era 1 passo só: nome + CPF (sem validação, item 2) +
declaração de aceite, tudo no mesmo POST, sem nenhuma prova de posse do e-mail além do próprio
link já ter chegado lá.

### Decisão de arquitetura (mirror, não invenção)

O sistema já tinha exatamente esse problema resolvido, em produção, para o aceite de proposta
pelo parceiro (Fase 3.11.2): 2 passos — dados + declaração primeiro, depois um código OTP de 6
dígitos enviado por e-mail para confirmar. Este padrão foi replicado ponto a ponto para a
assinatura, reaproveitando a mesma variável de ambiente (`OTP_HASH_PEPPER`), o mesmo hashing
(SHA-256 com pepper), o mesmo gerador de código (`crypto.randomInt`, CSPRNG) e o mesmo
template de e-mail (agora com um parâmetro `contexto` para dizer "assinatura" em vez de
"proposta" no assunto/corpo, sem tocar no comportamento já em produção da proposta).

### Correção

- Nova tabela `signature_assinatura_tentativas` (mirror de `propostas_aceite_tentativas`):
  guarda a tentativa de assinatura, o hash do OTP, expiração (10 min), até 5 tentativas de
  código antes de bloquear.
- `app.assinatura_externa_assinar_iniciar` — valida nome/documento/CPF (item 2)/declaração,
  gera e envia o OTP, grava a tentativa.
- `app.assinatura_externa_assinar_confirmar` — valida o código digitado contra o hash, e só
  **agora** (2º passo, nunca no 1º) marca o signatário como `ASSINADO`.
- Tela (`SignExternal.jsx`) ganhou o 2º passo (campo de código de 6 dígitos), no mesmo padrão
  visual já usado na tela de aceite de proposta do parceiro.
- A função antiga de assinatura em 1 passo (`app.confirmar_assinatura_via_link`) foi
  **removida** (não deixada como código morto) — não existe mais nenhum caminho de assinar sem
  passar pelo OTP.

## ITEM 4 — PDF final com todas as informações da assinatura

### Causa raiz

Na função antiga de assinatura (Fase 3.11.4), quando o envelope terminava, o campo
`documentos_assinados.storage_path_assinado` era gravado como **cópia exata** do
`storage_path_original` — ou seja, "documento assinado" nunca foi, de fato, um arquivo
diferente do rascunho original. Clicar em "ver documento assinado" mostraria (quando
funcionasse) a mesma minuta de antes, sem nome/CPF/data/IP de quem assinou.

### Correção

Reaproveitado o mesmo motor de PDF já usado para gerar a minuta (`pdfkit`, em
`api/lib/pdfContrato.js`) — nunca uma biblioteca nova de mesclar PDFs. A função
`generateContratoPdf` passou a aceitar um parâmetro opcional `certificado`: quando presente,
ela (a) troca a capa e o cabeçalho/rodapé de "MINUTA — não vinculante" para "ASSINADO
ELETRONICAMENTE", e (b) acrescenta, no mesmo documento, uma página final "Certificado de
Assinatura Eletrônica" com nome, CPF confirmado, e-mail, papel, status, data/hora, IP e método
de cada signatário.

Fluxo: quando `POST /assinar/confirmar` fecha o envelope (todos os obrigatórios assinaram) e o
documento é um `CONTRATO`, o backend busca os dados do contrato e do certificado (2 novas RPCs
escopadas ao token: `assinatura_externa_documento_dados_contrato` e
`assinatura_externa_certificado_dados`), gera o PDF final, sobe para o Storage e registra o
caminho via `assinatura_externa_documento_assinado_registrar`. Tudo isso acontece **dentro do
try/catch da própria rota** — se falhar (por exemplo, Storage indisponível), a assinatura já
gravada **nunca é desfeita**; só fica `documento_assinado_disponivel=false` até uma tentativa
funcionar. A tela mostra "Gerando PDF final assinado…" nesse caso, nunca um erro que pareça que
a assinatura falhou.

Motor de PDF verificado isoladamente antes de entrar na rota: gerado um PDF de teste de 13
páginas com 2 signatários fictícios, capa e página de certificado conferidas visualmente
(convertidas para PNG) — ambas corretas.

### Item 4-B — 3º bug real, encontrado no seu reteste ("o link funcionou, mas os documentos não aparecem assinados")

Depois de corrigidos os itens 1 e 1-B, você conseguiu assinar de ponta a ponta — mas o PDF
final nunca ficou disponível. Mesma causa raiz da família 1-B (RLS de `storage.objects`
barrando `anon`), só que agora do lado de **escrita**, não leitura.

**Causa raiz**: `gerarDocumentoAssinadoContrato()` faz o upload do PDF final usando o mesmo
`anonClient()` da rota (nunca há sessão logada nesse fluxo, por design). A policy de INSERT em
`storage.objects` (Fase 2.5) também é só `to authenticated` — o upload é rejeitado pelo RLS, a
função lança erro, e o `try/catch` da rota (proposital, para nunca derrubar uma assinatura já
gravada por causa de uma falha de PDF) só loga e segue — resultado: a assinatura fica gravada e
válida, mas `documento_assinado_disponivel` nunca vira `true`, porque o PDF final nunca termina
de subir.

**Correção**: 2 novas policies (INSERT + UPDATE, essa última por causa do `upsert: true` do
upload) liberando `anon`, mas de forma **bem mais estreita** que a policy de leitura do item
1-B: nunca o prefixo `envelopes/` inteiro, só o padrão exato de nome que
`gerarDocumentoAssinadoContrato()` sempre usa — `envelopes/<id>/assinado-<timestamp>.pdf`. Isso
significa que mesmo alguém de posse só da anon key (pública, embutida no frontend) nunca
consegue, via Storage direto: sobrescrever um `original-*.pdf` (padrão diferente, continua
`authenticated`-only) nem fazer um upload valer como "documento oficial assinado" — isso ainda
exige a RPC `assinatura_externa_documento_assinado_registrar`, que exige um token de
signatário válido e o envelope já `ASSINADO`/`VALIDADO`. Na pior hipótese, alguém com a anon
key consegue gravar arquivos avulsos nesse padrão de nome numa pasta de envelope cujo ID já
conheça — nunca falsificar o documento oficial.

Mesma limitação de ambiente já documentada: não pôde ser testado neste sandbox (sem schema
`storage` local) — é SQL para rodar manualmente, junto com o restante de
`storage_setup_fase25.sql` (idempotente).

---

## TESTE REAL: PASS

Suíte `tests/run_tests_fase311.sh` completa (herdada das Fases 3.11–3.11.4 + nova seção
"Fase 3.11.5"): **137 PASS / 0 FAIL**, incluindo idempotência real de todas as 6 migrations.

Durante a própria execução da suíte foi encontrado (e corrigido) mais um problema real, da
mesma classe já documentada entre as Fases 3.11.3→3.11.4: rodar a suíte uma 2ª vez (banco já
com a Fase 3.11.5 aplicada) fazia a etapa de "reaplicar a migration anterior para provar
idempotência" falhar — porque a `auditoria_acao_check` da Fase 3.11.4 é mais estreita que a da
3.11.5, e o banco já tinha linhas de auditoria com ações que só a 3.11.5 criou
(`SIGNATURE_ACCEPT_OTP_REQUESTED` e afins). Corrigido subindo o corte de replay de migrations
antigas (mesmo ajuste já feito uma vez antes, entre 3.11.3 e 3.11.4): quando a Fase 3.11.5 já
está presente, nenhuma migration mais antiga — incluindo a da 3.11.4 — é replayed; só a mais
nova é reaplicada, para provar sua própria idempotência.

Cobertura nova da Fase 3.11.5:
- Item 1: RLS confirmado como causa raiz; nova RPC testada devolvendo o caminho correto.
- Item 2: CPF com dígito verificador errado rejeitado (`CPF_INVALIDO`); CPF válido aceito;
  CPF em sequência repetida (`111.111.111-11`) rejeitado.
- Item 3: fluxo completo de 2 passos — iniciar (gera OTP), OTP errado rejeitado
  (`OTP_INCORRETO`), OTP certo confirma e assina; nova tentativa num signatário já assinado
  bloqueada (`ASSINATURA_DUPLICADA`).
- Item 4: as 2 RPCs de dados (contrato + certificado) testadas devolvendo dados reais; a RPC de
  registro do PDF final testada gravando um caminho **real e diferente** do original (a
  regressão exata do bug antigo, provada corrigida).

### Limitação honesta, documentada, não escondida

Este sandbox de desenvolvimento **não tem um Supabase Storage real** — confirmado
(`curl .../storage/v1/bucket` devolve `{}`, não uma resposta real de Storage API) e por
inspeção direta do banco (`documento_original_storage_path` fica `NULL` em todo envelope de
teste local, incluindo os desta suíte). Isso significa que, localmente:

- A causa raiz e a correção do item 1 (RLS bloqueando a leitura) estão **provadas** — mas o
  round-trip real de upload/download de um arquivo não pôde ser testado aqui, só simulado via
  SQL direto (mesmo padrão de "simular indisponibilidade de serviço externo" já usado antes
  neste projeto para o Resend).
- O item 4 teve seu motor de PDF (pdfkit) e sua camada de dados (as 2 RPCs) provados
  corretos e completos — mas a geração de fato do PDF final, dentro do fluxo real de
  `POST /assinar/confirmar`, falha neste ambiente por falta de Storage (log real:
  `[documento-assinado] falha ao gerar PDF final...`), e isso é **esperado e tolerado por
  design** (try/catch — nunca derruba a assinatura já gravada).

Para fechar este item de fato: **a produção precisa ter um bucket de Storage real e
funcionando** (`documentos`, já referenciado em `supabase/storage_setup_fase25.sql`) — se ele
já existe e já funciona em produção (é onde a minuta original já é salva hoje, então
provavelmente sim), os itens 1 e 4 devem funcionar de ponta a ponta assim que o deploy sair;
se não, é a única peça que falta confirmar.

### Item 4-C — "não tem local para o administrador abrir cópias do contrato assinado dentro do sistema"

Gap real, separado dos anteriores — e da mesma classe já documentada e corrigida uma vez antes
para o botão "Cancelar envelope" (Fase 3.11.4, seção "4 gaps de UI"): a funcionalidade de abrir
o PDF assinado por um ADMINISTRADOR **já existia** (rota interna `GET
/api/signatures/envelopes/:id/document`, de volta à Fase 2.5 — sempre autenticada, nunca
passou pelo problema de RLS do `anon`, então já funciona assim que o PDF final existir), mas só
era acessível na tela separada `/assinaturas/:id` — nunca no painel embutido de
`ContractDetail.jsx`, que é de onde você estava operando. O painel embutido só mostrava o texto
"documento assinado validado ✓", sem nenhum botão para efetivamente abrir o arquivo.

**Correção**: botão **"Ver documento assinado (PDF, com certificado)"** adicionado ao painel
embutido, ao lado de "Cancelar envelope", visível sempre que `documento_assinado_disponivel`
for verdadeiro — mirror exato do botão equivalente que já existia em `SignatureDetail.jsx`
(mesmo endpoint, nenhuma rota nova). Quando o envelope já está `ASSINADO`/`VALIDADO` mas o PDF
final ainda não ficou pronto, uma nota explica que ele está sendo gerado.

---

## O que falta para "resolvido" de fato

1. **Dar `git commit` + `push`** dos 11 arquivos alterados/novos desta fase (já sincronizados
   na sua pasta OneDrive, incluindo o novo botão em `web/src/pages/ContractDetail.jsx` — item
   4-C) — não posso fazer isso a partir deste ambiente.
2. **Aplicar a migration `20261008090000_phase_3_11_05_correcoes_pos_deploy.sql`** em produção
   (Supabase) — mesmo processo já usado nas fases anteriores.
3. **Rodar de novo `supabase/storage_setup_fase25.sql` inteiro no SQL Editor do seu projeto
   Supabase** (itens 1-B e 4-B acima) — é a única forma de aplicar as novas policies
   (`documentos_bucket_select_envelopes_anon` para o "Object not found",
   `documentos_bucket_write_assinado_anon`/`..._update_assinado_anon` para o PDF final nunca
   ficar disponível); o arquivo é idempotente, pode rodar tudo de novo sem risco às policies já
   existentes.
4. **Redeploy** Railway (backend) + Vercel (frontend) — nenhuma variável de ambiente nova é
   necessária (reaproveita `OTP_HASH_PEPPER`, `RESEND_API_KEY`, `RESEND_FROM_EMAIL`, todas já
   configuradas desde a Fase 3.11.3/3.11.4).
5. Um novo teste manual real, ponta a ponta, depois do redeploy + da policy de Storage: abrir
   "Revisar documento" antes de assinar (deve abrir o PDF, não mais dar erro), assinar um
   contrato de teste, digitar um CPF inválido de propósito (deve bloquear), confirmar o OTP
   chegando por e-mail, e — depois de assinado — abrir o PDF final e conferir que ele mostra a
   página de certificado com nome/CPF/data/IP corretos.

Até esses itens serem concluídos por você, este relatório considera os 4 problemas
**corrigidos e provados no nível de código e de teste automatizado** (137/137), mas a
**confirmação real em produção (Storage + e-mail chegando) ainda pendente** — a mesma
distinção que os relatórios desta fase sempre fazem questão de manter.
