-- ============================================================================
-- OptiMon — Fase 3.11.1: correção de bug real reportado pelo usuário testando a
-- aplicação de verdade (não um teste automatizado que passou por acidente).
--
-- SINTOMA REAL, reproduzido na tela da proposta PROP-20260831-71e55d07 (Jussara —
-- PR, parceiro HELO CONTEUDOS DIGITAIS), status "Aprovada (interna)", ao usar o
-- card "Envio ao Parceiro & Aceite Externo":
--
--     function gen_random_bytes(integer) does not exist
--
-- CAUSA RAIZ, confirmada (não suposta): `app.enviar_proposta_parceiro`, criada na
-- migration 20261002090000_phase_3_11_workflow_proposta_parceiro.sql, gera o token
-- de acesso externo com `encode(gen_random_bytes(32), 'hex')` — `gen_random_bytes`
-- vem da extensão pgcrypto. A função roda com `set search_path = public, pg_temp`
-- (padrão de segurança já usado em toda função SECURITY DEFINER deste projeto).
-- No ambiente local de desenvolvimento usado para homologar a Fase 3.11, o
-- `create extension if not exists "pgcrypto"` (migration 20260824090000) instalou
-- a extensão dentro do schema `public` — então `gen_random_bytes` resolvia normalmente
-- e os 40/40 testes automatizados + o teste visual passaram sem nunca expor o bug.
-- No banco real (produção do usuário), a extensão pgcrypto não está em `public` —
-- por isso a função nunca encontra `gen_random_bytes` lá, e todo clique em "Enviar
-- ao Parceiro" falha. Confirmado localmente: `select extnamespace::regnamespace
-- from pg_extension where extname='pgcrypto'` retorna `public` aqui, o que já
-- demonstra que essa dependência de schema é frágil e nunca deveria ter existido.
--
-- CORREÇÃO: eliminar por completo a dependência de pgcrypto nesta função. Em vez de
-- gen_random_bytes, usar gen_random_uuid() — função nativa do Postgres desde a
-- versão 13, sem precisar de NENHUMA extensão, e já usada em dezenas de outras
-- migrations deste mesmo projeto (inclusive para gerar o próprio número da proposta
-- PROP-20260831-71e55d07 e de todo número de contrato — prova de que já funciona
-- de verdade no banco real do usuário). Concatenam-se dois gen_random_uuid()
-- (sem os hífens) para manter o mesmo formato de saída (64 caracteres hexadecimais)
-- e o mesmo nível de entropia (256 bits) do design original — nenhuma mudança de
-- contrato para quem consome o token (frontend, link externo, etc.).
--
-- Regra do projeto respeitada: a migration 20261002090000 já está aplicada em
-- produção (a proposta acima só existe porque ela rodou lá) — por isso a correção
-- vai em migration NOVA (esta), nunca editando o arquivo já aplicado. Só a função
-- é recriada (CREATE OR REPLACE); nada de schema, coluna ou dado é alterado.
-- ============================================================================

create or replace function app.enviar_proposta_parceiro(p_proposta_id uuid)
returns public.propostas_comerciais
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_orig public.propostas_comerciais;
  v_row public.propostas_comerciais;
  v_token text;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode enviar proposta ao parceiro — só COMERCIAL/DIRETOR/ADMINISTRADOR.', app.perfil_atual();
  end if;

  select * into v_orig from public.propostas_comerciais where id = p_proposta_id;
  if v_orig.id is null then
    raise exception 'NAO_ENCONTRADA: proposta % não encontrada.', p_proposta_id;
  end if;

  if v_orig.status not in ('APROVADA', 'ENVIADA_AO_PARCEIRO', 'VISUALIZADA_PELO_PARCEIRO') then
    raise exception 'STATUS_INVALIDO: só é possível enviar ao parceiro uma proposta APROVADA internamente (ou reenviar uma já enviada/visualizada) — status atual: %.', v_orig.status;
  end if;

  if v_orig.parceiro_id is null then
    raise exception 'DADOS_INCOMPLETOS: proposta sem parceiro_id vinculado — não é possível enviar.';
  end if;

  -- Fase 3.11.1: token gerado sem depender de pgcrypto (ver bloco de comentário
  -- acima) — dois gen_random_uuid() concatenados (sem hífens) = 64 hex chars,
  -- mesma forma e mesma entropia (256 bits) do gen_random_bytes(32) original.
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

  update public.propostas_comerciais
     set status = 'ENVIADA_AO_PARCEIRO',
         token_acesso_externo = v_token,
         token_expira_em = now() + make_interval(days => greatest(coalesce(v_orig.validade_dias, 15), 1)),
         enviado_ao_parceiro_em = now(),
         enviado_ao_parceiro_por = auth.uid()
   where id = p_proposta_id
   returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', p_proposta_id, 'PROPOSAL_SENT_TO_PARTNER',
    null, jsonb_build_object('status', v_orig.status), jsonb_build_object('status', 'ENVIADA_AO_PARCEIRO', 'token_expira_em', v_row.token_expira_em));

  return v_row;
end;
$$;
comment on function app.enviar_proposta_parceiro(uuid) is 'Fase 3.11 (seção 5), corrigida na Fase 3.11.1: gera token de acesso externo (via gen_random_uuid(), sem depender de pgcrypto) e move a proposta para ENVIADA_AO_PARCEIRO. Reenvio (mesmo status já enviado/visualizado) gera um token NOVO — o antigo para de funcionar.';
