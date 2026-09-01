-- ============================================================================
-- OptiMon — Fase 3.11.4 (seção 5 do pedido)
-- Investigação, SOMENTE LEITURA, do envelope real 571aa526-dd1e-4345-85e5-71b30ce68e8e
--
-- REGRAS:
--   - 100% SELECT. Nenhuma linha aqui faz INSERT/UPDATE/DELETE em nada.
--   - Roda direto no SQL Editor do Supabase (produção), com o usuário/role que você já
--     usa lá (não precisa de service_role nem de anon).
--   - Rode os 7 blocos abaixo, em ordem, e cole o resultado de TODOS eles (mesmo os que
--     vierem vazios — "0 rows" também é uma resposta importante).
--   - Nenhum destes SELECTs revela API key/token/segredo: os providers só guardam o NOME
--     da variável de ambiente (api_key_ref/webhook_secret_ref), nunca o valor.
--
-- CORRIGIDO: a 1ª versão deste arquivo tinha o bloco 3 referenciando colunas
-- (email_provider_id/email_canal/token_acesso/token_expira_em) que só existem depois da
-- migration da Fase 3.11.4 — e o erro que você recebeu ("column s.email_provider_id does
-- not exist") já é, por si só, uma resposta real: confirma que a produção ainda NÃO tem
-- essa migration aplicada. O bloco 0 novo abaixo confirma isso de forma explícita; o
-- bloco 3 foi reescrito para só usar colunas que já existem desde a Fase 2.5/3.11.2 (que
-- certamente já estão em produção, já que o envelope 571aa526 existe).
-- ============================================================================

-- 0) NOVO — em qual migration de assinatura a produção está agora (nenhuma alteração,
--    só leitura de metadados do schema). Isso explica por que o bloco 3 antigo falhou.
select
  exists(select 1 from information_schema.columns where table_name='signature_signers' and column_name='entregue_em') as tem_fase_3_11_2,
  exists(select 1 from information_schema.columns where table_name='propostas_aceite_tentativas' and column_name='email_status') as tem_fase_3_11_3,
  exists(select 1 from information_schema.columns where table_name='signature_signers' and column_name='email_provider_id') as tem_fase_3_11_4;

-- 1) O envelope em si: provedor usado, IDs interno/externo, status, timestamps, erro.
select
  e.id                      as envelope_id,
  e.tipo_documento,
  e.contrato_id,
  e.proposta_id,
  e.status                  as envelope_status,
  e.provider_id,
  e.provider_envelope_id,
  e.criado_em,
  e.enviado_em,
  e.concluido_em,
  e.cancelado_em,
  e.erro_mensagem,
  e.politica_assinatura,
  e.documento_original_storage_path,
  e.documento_assinado_storage_path
from public.signature_envelopes e
where e.id = '571aa526-dd1e-4345-85e5-71b30ce68e8e';

-- 2) O provedor que criou este envelope (nome/tipo/ambiente — nunca a credencial).
select
  sp.id, sp.nome, sp.tipo, sp.papel, sp.ambiente, sp.ativo,
  sp.api_url, sp.api_key_ref, sp.webhook_url, sp.webhook_secret_ref,
  sp.timeout_segundos, sp.politica_assinatura
from public.signature_providers sp
where sp.id = (select provider_id from public.signature_envelopes where id = '571aa526-dd1e-4345-85e5-71b30ce68e8e');

-- 3) Os 3 signatários (Rodrigo/rodrigo@nicknetwork.com.br, Nadia/cussolinnadia@gmail.com,
--    Rodrigo/borghi@outlook.pt): status individual, IDs externos, timestamps de cada etapa.
--    CORRIGIDO: usa só colunas que já existem desde a Fase 2.5/3.11.2 (compatível com a
--    produção como ela está agora, sem a Fase 3.11.4 aplicada).
select
  s.id                as signer_id,
  s.nome, s.email, s.papel, s.ordem, s.status as signer_status,
  s.provider_signer_id,
  s.criado_em, s.enviado_em, s.entregue_em, s.aberto_em, s.assinado_em,
  s.erro_mensagem, s.reenvios_count
from public.signature_signers s
where s.envelope_id = '571aa526-dd1e-4345-85e5-71b30ce68e8e'
order by s.ordem;

-- 4) Eventos de webhook recebidos para este envelope (se o provedor tiver mandado algum).
select
  ev.id, ev.evento_externo_id, ev.tipo_evento, ev.processado, ev.recebido_em, ev.payload
from public.signature_events ev
where ev.envelope_id = '571aa526-dd1e-4345-85e5-71b30ce68e8e'
order by ev.recebido_em;

-- 5) Evidências/documentos anexados pelo provedor para este envelope (se existir).
select
  de.id, de.tipo, de.storage_path, de.descricao, de.criado_em
from public.documentos_evidencias de
where de.envelope_id = '571aa526-dd1e-4345-85e5-71b30ce68e8e'
order by de.criado_em;

-- 6) Trilha de auditoria (INSERT/UPDATE genéricos da tabela + eventos semânticos, se a
--    Fase 3.11.4 já estiver aplicada em produção) do envelope e de cada um dos 3 signatários.
select
  a.id, a.criado_em, a.acao, a.entidade, a.entidade_id, a.usuario_id, a.origem, a.motivo,
  a.valor_anterior, a.valor_novo
from public.auditoria a
where (a.entidade = 'signature_envelopes' and a.entidade_id = '571aa526-dd1e-4345-85e5-71b30ce68e8e')
   or (a.entidade = 'signature_signers' and a.entidade_id in (
         select id from public.signature_signers where envelope_id = '571aa526-dd1e-4345-85e5-71b30ce68e8e'
       ))
order by a.criado_em;
