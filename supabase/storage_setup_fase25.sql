-- OptiMon — Fase 2.5 (11/11): Storage privado para documentos de proponente e
-- documentos assinados (seções 19-20, 45).
--
-- IMPORTANTE — este arquivo NÃO faz parte de `supabase/migrations/` de propósito
-- e não é aplicado por `tests/run_tests_fase25.sh`: o schema `storage` só existe
-- num projeto Supabase real (Storage API), nunca no Postgres puro usado pelo
-- harness de teste local desta e de todas as fases anteriores (confirmado nesta
-- sessão: `\dn` no Postgres local só lista app/auth/public — sem `storage`).
-- ARQUITETURA.md já registrava Storage como escopo da "Fase 8" desde a Fase 2;
-- esta fase entrega o SQL de configuração pronto (para rodar manualmente contra
-- o projeto Supabase real, uma única vez, via SQL Editor do painel Supabase ou
-- `supabase db execute`) e o código Node já preparado para usá-lo — mas a
-- integração de Storage em si não pôde ser smoke-testada nesta sessão, por essa
-- limitação de ambiente. Documentado sem rodeios no relatório final (seção
-- "Limitações") em vez de escondida.
--
-- Nenhum bucket de Storage existia ainda no projeto (greenfield). Cria UM bucket
-- privado (`documentos`, public=false) reaproveitado por TODOS os tipos de
-- documento desta fase (proponente: Contrato Social/CNPJ/Procuração/Ata;
-- assinatura: original/assinado) — não um bucket por tipo, para não duplicar
-- infraestrutura de storage sem necessidade real.
--
-- Caminho: {parceiro_id}/{tipo}/{uuid}-{nome_arquivo} para documento de
-- proponente; envelopes/{envelope_id}/{original|assinado}.pdf para assinatura.
-- Nunca uma URL pública fixa — toda leitura passa por
-- supabase.storage.createSignedUrl() (curto prazo), chamado só depois que a
-- rota Node já validou, via RLS, que o usuário pode ver a linha de metadado
-- correspondente em `documentos`/`documentos_assinados` (seção 45: "nenhum
-- documento deve ser acessível adivinhando/alterando um ID na URL" — o ID por
-- si só nunca basta, precisa da assinatura temporária).

insert into storage.buckets (id, name, public)
values ('documentos', 'documentos', false)
on conflict (id) do nothing;

-- RLS de storage.objects (seção 45): só authenticated pode ler/escrever, e só
-- dentro do bucket `documentos` — o controle fino de "este usuário pode ver
-- ESTE proponente" já acontece na camada de metadado (`documentos`/RLS) antes
-- da rota Node sequer chamar createSignedUrl(); aqui só barra o acesso direto
-- ao Storage por alguém sem nenhum vínculo de authenticated (ex.: anon).
drop policy if exists documentos_bucket_select on storage.objects;
create policy documentos_bucket_select
  on storage.objects for select
  to authenticated
  using (bucket_id = 'documentos');

drop policy if exists documentos_bucket_write on storage.objects;
create policy documentos_bucket_write
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'documentos');

drop policy if exists documentos_bucket_update on storage.objects;
create policy documentos_bucket_update
  on storage.objects for update
  to authenticated
  using (bucket_id = 'documentos' and app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'))
  with check (bucket_id = 'documentos' and app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'));

-- Nunca DELETE físico de objeto de storage por política padrão (mesma
-- disciplina de "documentos.status=REMOVIDO" em vez de apagar a linha) — sem
-- policy de delete para authenticated em geral; só ADMINISTRADOR, para expurgo
-- administrativo raro.
drop policy if exists documentos_bucket_delete on storage.objects;
create policy documentos_bucket_delete
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'documentos' and app.tem_perfil('ADMINISTRADOR'));

comment on policy documentos_bucket_select on storage.objects is 'Fase 2.5 seção 45: barreira de authenticated no bucket como um todo — o controle real de "quem pode ver qual documento" acontece na tabela documentos (RLS) antes da rota Node emitir um signed URL; nenhum objeto deste bucket é público.';

-- Fase 3.11.5 (correção de um 2º bug real de produção — "Falha ao gerar link de
-- download: Object not found", visto DEPOIS de já corrigido o 404 "Caminho do
-- documento não encontrado" da mesma fase): as rotas de assinatura/proposta
-- EXTERNAS (api/routes/signaturesExternal.js, api/routes/proposalsExternal.js)
-- não têm — e nunca tiveram, por design — uma sessão logada do Supabase Auth;
-- o signatário/parceiro nunca é um "authenticated" do Supabase, é validado só
-- pelo token opaco de 64 hex do link (mesmo modelo de "capability token" já
-- usado em toda essa funcionalidade, seção 45/documentos.md). A política
-- documentos_bucket_select acima (só `to authenticated`) barra exatamente esse
-- caso: o cliente anônimo (anonClient(), a única opção nessas rotas) chama
-- createSignedUrl() para um objeto que EXISTE de verdade no bucket, mas a
-- policy filtra a linha correspondente em storage.objects antes mesmo da
-- assinatura ser calculada — e a Storage API do Supabase reporta isso como
-- "Object not found" (não como um erro de permissão), exatamente o sintoma
-- reportado. Confirmado por leitura de código: signaturesExternal.js só chama
-- createSignedUrl() depois de já ter validado o token contra o banco (RPC
-- SECURITY DEFINER da Fase 3.11.5) — ou seja, a única coisa que faltava era
-- estender, para o Storage, a mesma decisão de confiança que o banco já toma.
--
-- Correção: uma 2ª policy de SELECT, só para `anon`, escopada estritamente ao
-- prefixo `envelopes/` (onde SOMENTE os PDFs de assinatura — original e
-- assinado — são gravados; nunca os documentos de proponente, que continuam
-- em `{parceiro_id}/{tipo}/...` e seguem exigindo authenticated). O nome do
-- objeto embute um UUID de envelope aleatório (128 bits) mais um timestamp —
-- inadivinhável na prática — e a rota Node só revela um caminho específico
-- depois de validar o token do signatário no banco; esta policy não abre o
-- bucket, só estende para `anon` a MESMA superfície (prefixo `envelopes/`) que
-- essas rotas já expõem publicamente via signed URL de qualquer forma. Nenhum
-- outro documento (proponente) fica acessível por este caminho.
drop policy if exists documentos_bucket_select_envelopes_anon on storage.objects;
create policy documentos_bucket_select_envelopes_anon
  on storage.objects for select
  to anon
  using (bucket_id = 'documentos' and name like 'envelopes/%');

comment on policy documentos_bucket_select_envelopes_anon on storage.objects is 'Fase 3.11.5: permite ao cliente anônimo (rotas externas de assinatura, sem sessão logada) gerar signed URL para os PDFs de assinatura (prefixo envelopes/) — a autorização real já foi verificada pelo token opaco do signatário antes da rota Node chamar createSignedUrl(); documentos de proponente (fora de envelopes/) continuam exigindo authenticated.';

-- Fase 3.11.5 (correção de um 3º bug real de produção — "link funcionou, mas os
-- documentos não aparecem assinados"): mesma causa raiz do item 1-B (RLS de
-- storage.objects barrando `anon`), agora do lado de ESCRITA, não leitura.
--
-- `gerarDocumentoAssinadoContrato()` (api/routes/signaturesExternal.js, chamada
-- dentro de POST /:token/assinar/confirmar, sempre com anonClient() — a rota
-- nunca tem sessão logada) faz `supabase.storage.from('documentos').upload(...,
-- { upsert: true })` para gravar o PDF final (com a página de certificado) logo
-- depois de fechar a assinatura. A policy documentos_bucket_write acima (só
-- `to authenticated`) bloqueia esse upload — a Storage API rejeita por RLS, o
-- upload lança erro, o try/catch da rota (propositalmente, para nunca derrubar
-- uma assinatura já gravada por causa de uma falha de PDF) engole o erro e só
-- loga — resultado visível: a assinatura em si funciona, mas
-- documento_assinado_disponivel nunca vira true, porque o PDF final nunca
-- termina de ser gravado.
--
-- Correção: policies de INSERT/UPDATE para `anon`, escopadas de forma BEM mais
-- estreita que a de leitura acima — nunca o prefixo `envelopes/` inteiro, só o
-- padrão exato `envelopes/<id>/assinado-<timestamp>.pdf` (o nome que
-- gerarDocumentoAssinadoContrato() sempre usa). Isso significa que, mesmo
-- alguém de posse só da anon key (pública, embutida no frontend) tentando
-- chamar a Storage API diretamente, NUNCA consegue: (a) sobrescrever um
-- `original-*.pdf` (esse prefixo não bate no padrão — continua protegido só
-- para authenticated, gravado apenas pela rota interna de criar envelope); (b)
-- fazer esse upload valer como "o documento assinado oficial" do envelope —
-- isso exige registrar o caminho via
-- app.assinatura_externa_documento_assinado_registrar, uma função SECURITY
-- DEFINER que exige um token de signatário válido e o envelope já
-- ASSINADO/VALIDADO (mesma trava de todas as outras RPCs externas desta fase).
-- Na pior hipótese, alguém com a anon key consegue gravar arquivos avulsos
-- nesse padrão de nome dentro de uma pasta de envelope que ele já saiba o ID
-- (uso indevido de espaço, nunca falsificação do documento oficial).
drop policy if exists documentos_bucket_write_assinado_anon on storage.objects;
create policy documentos_bucket_write_assinado_anon
  on storage.objects for insert
  to anon
  with check (bucket_id = 'documentos' and name similar to 'envelopes/[0-9a-f-]+/assinado-[0-9]+\.pdf');

drop policy if exists documentos_bucket_update_assinado_anon on storage.objects;
create policy documentos_bucket_update_assinado_anon
  on storage.objects for update
  to anon
  using (bucket_id = 'documentos' and name similar to 'envelopes/[0-9a-f-]+/assinado-[0-9]+\.pdf')
  with check (bucket_id = 'documentos' and name similar to 'envelopes/[0-9a-f-]+/assinado-[0-9]+\.pdf');

comment on policy documentos_bucket_write_assinado_anon on storage.objects is 'Fase 3.11.5: permite ao cliente anônimo gravar SOMENTE o PDF final de assinatura (padrão exato envelopes/<id>/assinado-<timestamp>.pdf, gerado por gerarDocumentoAssinadoContrato) — nunca original-*.pdf nem qualquer outro nome; registrar esse caminho como o documento oficial ainda exige a RPC com token válido.';
comment on policy documentos_bucket_update_assinado_anon on storage.objects is 'Fase 3.11.5: companion da policy de insert acima — necessária porque o upload usa upsert:true (o cliente Storage pode fazer UPDATE quando o mesmo caminho já existe).';

-- ============================================================================
-- Fase 3.11.6 (seção 5): mesmo padrão de RLS de Storage acima, agora para o
-- prefixo `propostas/` — os 2 PDFs de aceite da proposta (original + aceite com
-- certificado), gerados por gerarDocumentosPropostaAceite()
-- (api/routes/proposalsExternal.js), SEMPRE chamada com anonClient() (a rota de
-- confirmação de aceite nunca tem sessão logada). DIFERENÇA real em relação ao
-- padrão de envelopes/: ali o `original-*.pdf` é gravado por uma rota
-- AUTENTICADA (criar envelope) e só o `assinado-*.pdf` precisa de escrita anon;
-- aqui NÃO EXISTE nenhuma rota autenticada que pré-grave a minuta da proposta em
-- Storage — a minuta original também é gerada, pela primeira vez, dentro da
-- própria rota anônima de confirmação de aceite. Por isso `propostas/` precisa
-- de escrita anon para AMBOS os padrões (original-*.pdf E aceite-*.pdf) — nunca
-- um prefixo aberto: cada padrão é validado por `similar to` exatamente como no
-- padrão assinado-*.pdf acima, e registrar qualquer um dos dois caminhos como
-- oficial ainda exige a RPC app.registrar_documentos_proposta_aceite, escopada
-- por token e só depois de aceite_em já preenchido.
drop policy if exists documentos_bucket_select_propostas_anon on storage.objects;
create policy documentos_bucket_select_propostas_anon
  on storage.objects for select
  to anon
  using (bucket_id = 'documentos' and name like 'propostas/%');

drop policy if exists documentos_bucket_write_propostas_anon on storage.objects;
create policy documentos_bucket_write_propostas_anon
  on storage.objects for insert
  to anon
  with check (
    bucket_id = 'documentos' and (
      name similar to 'propostas/[0-9a-f-]+/original-[0-9]+\.pdf'
      or name similar to 'propostas/[0-9a-f-]+/aceite-[0-9]+\.pdf'
    )
  );

drop policy if exists documentos_bucket_update_propostas_anon on storage.objects;
create policy documentos_bucket_update_propostas_anon
  on storage.objects for update
  to anon
  using (
    bucket_id = 'documentos' and (
      name similar to 'propostas/[0-9a-f-]+/original-[0-9]+\.pdf'
      or name similar to 'propostas/[0-9a-f-]+/aceite-[0-9]+\.pdf'
    )
  )
  with check (
    bucket_id = 'documentos' and (
      name similar to 'propostas/[0-9a-f-]+/original-[0-9]+\.pdf'
      or name similar to 'propostas/[0-9a-f-]+/aceite-[0-9]+\.pdf'
    )
  );

comment on policy documentos_bucket_select_propostas_anon on storage.objects is 'Fase 3.11.6: permite ao cliente anônimo (área externa do parceiro) gerar signed URL para os PDFs de aceite da proposta (prefixo propostas/) — autorização real já verificada pelo token opaco da proposta antes da rota Node chamar createSignedUrl().';
comment on policy documentos_bucket_write_propostas_anon on storage.objects is 'Fase 3.11.6: permite ao cliente anônimo gravar SOMENTE os 2 padrões de nome exatos usados por gerarDocumentosPropostaAceite() (original-<timestamp>.pdf e aceite-<timestamp>.pdf) — nunca outro nome; registrar qualquer um dos 2 caminhos como oficial ainda exige a RPC com token válido e aceite_em já preenchido.';
comment on policy documentos_bucket_update_propostas_anon on storage.objects is 'Fase 3.11.6: companion da policy de insert acima — necessária porque o upload usa upsert:true.';
