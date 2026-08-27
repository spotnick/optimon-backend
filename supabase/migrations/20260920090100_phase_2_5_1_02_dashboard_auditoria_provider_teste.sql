-- OptiMon — Fase 2.5.1 (2/3):
--   a) indicadores novos no dashboard (seção 30);
--   b) filtro por entidade_id em pricing_audit_list, para a aba
--      Histórico/Auditoria da tela de detalhe do proponente (seção 11) poder
--      listar só os eventos deste proponente, sem duplicar a função;
--   c) colunas de "último teste de conexão" em signature_providers (seção 18).
-- Tudo aditivo — nenhuma tabela/função recriada, nenhum dado apagado.

-- ============================================================================
-- a) app.dashboard_contratual — mesma função (Fase 2.5, migration 09), só
--    acrescenta chaves novas ao jsonb (usuários/proponentes ativos,
--    assinaturas/aditivos pendentes, alias explícito de contratos pendentes).
--    "Usuários com convite pendente" não é computável aqui — não existe FDW
--    para auth.users neste projeto e não seria seguro tentar; esse dado
--    específico só existe via a Auth Admin API (ver api/lib/supabaseAdmin.js
--    e docs/ARQUITETURA.md seção 24) e é calculado no Node, não no SQL.
-- ============================================================================
create or replace function app.dashboard_contratual()
returns jsonb
language sql
stable
security invoker
as $$
  select jsonb_build_object(
    'contratos_ativos', (select count(*) from public.contratos where status = 'ATIVO'),
    'propostas_aguardando_aprovacao', (select count(*) from public.propostas_comerciais where status = 'EM_APROVACAO'),
    'propostas_aguardando_assinatura', (select count(*) from public.propostas_comerciais where status = 'EM_ASSINATURA'),
    'propostas_pendentes', (
      select count(*) from public.propostas_comerciais where status in ('EM_APROVACAO', 'EM_ASSINATURA')
    ),
    'contratos_aguardando_assinatura', (
      select count(distinct contrato_id) from public.signature_envelopes
      where tipo_documento = 'CONTRATO' and status in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
    ),
    'contratos_pendentes', (
      select count(distinct contrato_id) from public.signature_envelopes
      where tipo_documento = 'CONTRATO' and status in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
    ),
    'contratos_proximos_vencimento', (
      select count(*) from public.contratos
      where status = 'ATIVO' and data_fim_prevista is not null and data_fim_prevista <= current_date + interval '60 days'
    ),
    'reajustes_pendentes', (select count(*) from public.reajustes where status = 'PENDENTE'),
    'valor_mensal_contratado', (
      select coalesce(sum(cpc.mensalidade_minima_porta), 0)
      from public.contratos c join public.contrato_pricing_config cpc on cpc.contrato_id = c.id
      where c.status = 'ATIVO'
    ),
    'pons_locadas', (
      select count(*) from public.contrato_fibras cf
      where cf.desvinculado_em is null and cf.porta_pon_id is not null
    ),
    'fibras_locadas', (
      select count(*) from public.infra_fibras where status = 'LOCADA'
    ),
    'alertas_nao_resolvidos', (select count(*) from public.alertas where resolvido = false),
    -- Fase 2.5.1, seção 30:
    'usuarios_ativos', (select count(*) from public.usuarios where ativo = true and removido_em is null),
    'usuarios_inativos', (select count(*) from public.usuarios where ativo = false and removido_em is null),
    'proponentes_ativos', (select count(*) from public.parceiros where ativo = true and removido_em is null),
    'assinaturas_pendentes', (
      select count(*) from public.signature_envelopes
      where status in ('CRIADO', 'ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
    ),
    'aditivos_pendentes', (
      select count(*) from public.contrato_aditivos
      where status in ('RASCUNHO', 'EM_APROVACAO', 'APROVADO', 'ASSINATURA')
    )
  );
$$;

-- public.pricing_dashboard_contratual já existe e não muda (mesma assinatura,
-- só passa a devolver mais chaves no jsonb — compatível com qualquer chamador
-- existente, que só lê as chaves que já conhecia).

-- ============================================================================
-- b) pricing_audit_list — acrescenta p_entidade_id (default null, então
--    nenhum chamador existente quebra). Precisa DROP porque a posição dos
--    parâmetros muda (novo parâmetro no meio da lista original quebraria
--    chamada posicional — acrescentado no FINAL, então na prática nem
--    precisaria de DROP, mas o padrão do projeto é sempre fazer o DROP
--    explícito ao mexer numa assinatura, para nunca depender de overload
--    acidental).
-- ============================================================================
drop function if exists public.pricing_audit_list(integer, text, uuid);
create or replace function public.pricing_audit_list(
  p_limit integer default 100, p_entidade text default null, p_usuario_id uuid default null, p_entidade_id uuid default null
)
returns setof public.auditoria
language sql
stable
security invoker
as $$
  select * from public.auditoria
  where (p_entidade is null or entidade = p_entidade)
    and (p_usuario_id is null or usuario_id = p_usuario_id)
    and (p_entidade_id is null or entidade_id = p_entidade_id)
  order by criado_em desc
  limit least(coalesce(p_limit, 100), 500);
$$;

comment on function public.pricing_audit_list(integer, text, uuid, uuid) is 'Fase 2.5.1 (seção 11): acrescenta p_entidade_id para a aba Histórico/Auditoria de /proponentes/:id filtrar só os eventos deste registro (entidade=''parceiros'' and entidade_id=:id). GET /api/audit?entidade=&usuario_id=&entidade_id= continua aceitando os filtros antigos normalmente.';

grant execute on function public.pricing_audit_list(integer, text, uuid, uuid) to authenticated;

-- ============================================================================
-- c) signature_providers — "Último teste" e "Último evento" (seção 16).
--    "Último evento" é derivado (não precisa de coluna): último
--    signature_events recebido para qualquer envelope deste provedor.
-- ============================================================================
alter table public.signature_providers add column if not exists ultimo_teste_em timestamptz;
alter table public.signature_providers add column if not exists ultimo_teste_status text check (ultimo_teste_status is null or ultimo_teste_status = any (array['OK', 'FALHA']));
alter table public.signature_providers add column if not exists ultimo_teste_mensagem text;

comment on column public.signature_providers.ultimo_teste_em is 'Fase 2.5.1 seção 18: quando o botão "Testar Conexão" foi usado pela última vez.';
comment on column public.signature_providers.ultimo_teste_status is 'OK ou FALHA — nunca expõe secret, só o diagnóstico (ver ultimo_teste_mensagem e api/routes/signatures.js).';

drop function if exists public.pricing_signature_providers_list();
create or replace function public.pricing_signature_providers_list()
returns table (
  id uuid, nome text, tipo text, papel text, ambiente text, api_url text, webhook_url text,
  timeout_segundos integer, politica_assinatura text, ativo boolean, criado_em timestamptz, atualizado_em timestamptz,
  api_key_ref text, webhook_secret_ref text,
  ultimo_teste_em timestamptz, ultimo_teste_status text, ultimo_teste_mensagem text,
  ultimo_evento_em timestamptz, ultimo_evento_tipo text
)
language sql
stable
security invoker
as $$
  select
    sp.id, sp.nome, sp.tipo, sp.papel, sp.ambiente, sp.api_url, sp.webhook_url,
    sp.timeout_segundos, sp.politica_assinatura, sp.ativo, sp.criado_em, sp.atualizado_em,
    sp.api_key_ref, sp.webhook_secret_ref,
    sp.ultimo_teste_em, sp.ultimo_teste_status, sp.ultimo_teste_mensagem,
    ev.recebido_em as ultimo_evento_em, ev.tipo_evento as ultimo_evento_tipo
  from public.signature_providers sp
  left join lateral (
    select se.recebido_em, se.tipo_evento
    from public.signature_events se
    join public.signature_envelopes envel on envel.id = se.envelope_id
    where envel.provider_id = sp.id
    order by se.recebido_em desc
    limit 1
  ) ev on true
  order by sp.papel;
$$;

comment on function public.pricing_signature_providers_list() is 'Fase 2.5.1 seção 16: GET /api/signatures/providers passa a usar esta função (em vez de SELECT direto) para trazer também "último evento" (derivado de signature_events, nunca uma coluna redundante) junto do "último teste" (colunas novas acima).';

grant execute on function public.pricing_signature_providers_list() to authenticated;
