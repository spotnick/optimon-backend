-- OptiMon — Fase 2.5 (8/9): Aditivo — cauda de assinatura + ativação (seção 39).
--
-- `contrato_aditivos` (RASCUNHO/EM_APROVACAO/APROVADO/REJEITADO) e o trigger
-- `fn_aditivo_gera_versao` (gera nova contrato_versions ao entrar em APROVADO)
-- já existem desde a Fase 1.2/2 — não duplicados. O que faltava é a cauda que
-- a seção 39 pede: RASCUNHO → APROVAÇÃO → ASSINATURA → ATIVO — os dois últimos
-- estados (ASSINATURA/ATIVO) e a função que fecha o ciclo usando o mesmo
-- Signature Engine desta fase (não um mecanismo de assinatura paralelo).
--
-- Reajuste (seção 40): `app.aplicar_reajuste_contrato` já existe, completo,
-- desde antes desta fase (índice/data-base/histórico via `reajustes` +
-- `pricing_versions`, nunca reescreve valor histórico) — só passa a ser
-- exposto via API nesta fase (migration 09), sem alteração de lógica aqui.

alter table public.contrato_aditivos drop constraint if exists contrato_aditivos_status_check;
alter table public.contrato_aditivos add constraint contrato_aditivos_status_check
  check (status = any (array['RASCUNHO', 'EM_APROVACAO', 'APROVADO', 'REJEITADO', 'ASSINATURA', 'ATIVO']));

create or replace function app.enviar_aditivo_para_assinatura(p_aditivo_id uuid, p_envelope_id uuid)
returns public.contrato_aditivos
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_aditivo public.contrato_aditivos;
  v_envelope public.signature_envelopes;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem enviar aditivo para assinatura.';
  end if;

  select * into v_aditivo from public.contrato_aditivos where id = p_aditivo_id;
  if v_aditivo.id is null then
    raise exception 'NAO_ENCONTRADO: aditivo % não encontrado.', p_aditivo_id;
  end if;
  if v_aditivo.status <> 'APROVADO' then
    raise exception 'STATUS_INVALIDO: aditivo % precisa estar APROVADO antes de ir para assinatura (status atual: %).', v_aditivo.numero, v_aditivo.status;
  end if;

  select * into v_envelope from public.signature_envelopes where id = p_envelope_id;
  if v_envelope.id is null or v_envelope.aditivo_id is distinct from v_aditivo.id then
    raise exception 'ENVELOPE_INVALIDO: envelope % não corresponde a este aditivo.', p_envelope_id;
  end if;

  update public.contrato_aditivos set status = 'ASSINATURA' where id = v_aditivo.id returning * into v_aditivo;

  return v_aditivo;
end;
$$;

create or replace function app.ativar_aditivo(p_aditivo_id uuid)
returns public.contrato_aditivos
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_aditivo public.contrato_aditivos;
  v_assinado boolean;
begin
  if not app.tem_perfil('DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só DIRETOR/ADMINISTRADOR podem ativar um aditivo.';
  end if;

  select * into v_aditivo from public.contrato_aditivos where id = p_aditivo_id;
  if v_aditivo.id is null then
    raise exception 'NAO_ENCONTRADO: aditivo % não encontrado.', p_aditivo_id;
  end if;
  if v_aditivo.status <> 'ASSINATURA' then
    raise exception 'STATUS_INVALIDO: aditivo % precisa estar em ASSINATURA para ser ativado (status atual: %).', v_aditivo.numero, v_aditivo.status;
  end if;

  select exists (
    select 1 from public.signature_envelopes e
    join public.documentos_assinados da on da.envelope_id = e.id
    where e.aditivo_id = v_aditivo.id and e.tipo_documento = 'ADITIVO' and e.status = 'VALIDADO' and da.validado = true
  ) into v_assinado;

  if not v_assinado then
    raise exception 'ASSINATURA_PENDENTE: o aditivo % ainda não tem assinatura ICP-Brasil validada.', v_aditivo.numero;
  end if;

  update public.contrato_aditivos set status = 'ATIVO' where id = v_aditivo.id returning * into v_aditivo;

  perform app.registrar_auditoria_semantica('contrato_aditivos', v_aditivo.id, 'CONTRACT_ADDENDUM_ACTIVATE', null, null, to_jsonb(v_aditivo));

  return v_aditivo;
end;
$$;

comment on function app.ativar_aditivo(uuid) is 'Fase 2.5 seção 39: fecha o ciclo RASCUNHO→APROVAÇÃO→ASSINATURA→ATIVO. Não aloca fibra/porta PON nova automaticamente — assim como na ativação do contrato original (migration 06), a alocação física de infraestrutura nova continua sendo um passo de Engenharia via contrato_fibras, deliberadamente não adivinhado aqui.';

drop function if exists public.pricing_addendum_send_signature(uuid, uuid);
create or replace function public.pricing_addendum_send_signature(p_aditivo_id uuid, p_envelope_id uuid)
returns public.contrato_aditivos
language sql security invoker
as $$ select app.enviar_aditivo_para_assinatura(p_aditivo_id, p_envelope_id); $$;

drop function if exists public.pricing_addendum_activate(uuid);
create or replace function public.pricing_addendum_activate(p_aditivo_id uuid)
returns public.contrato_aditivos
language sql security invoker
as $$ select app.ativar_aditivo(p_aditivo_id); $$;

grant execute on function public.pricing_addendum_send_signature(uuid, uuid) to authenticated;
grant execute on function public.pricing_addendum_activate(uuid) to authenticated;
