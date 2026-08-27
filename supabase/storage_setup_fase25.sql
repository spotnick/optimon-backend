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
