-- OptiMon — Fase 3, item 3.7: dados consolidados para a MINUTA DE CONTRATO (documento
-- gerado, análogo ao que proposalDocumentModel.js já faz para propostas). Junta tudo que
-- o gerador de PDF/DOCX da minuta precisa numa única chamada — contrato, config de
-- precificação, guardrails contratuais (exclusividade/fibra terceiros/rede própria,
-- Fase 1 seções 21-24), clientes reservados (inclui a exceção Prefeitura), ativos
-- (OLT/ONU) vinculados, fibras, aditivos e reajustes.
--
-- IMPORTANTE (mesma disciplina da seção 6 do prompt-mestre, já usada em
-- proposalDocumentModel.js): esta função só devolve DADOS REAIS do banco — nenhum texto
-- de cláusula jurídica vive aqui. O texto das cláusulas (incluindo os trechos que ainda
-- não têm fonte de dado nenhuma — confidencialidade, LGPD, foro, redação exata de
-- rescisão/penalidades) é responsabilidade exclusiva de api/lib/contractDocumentModel.js,
-- que rotula o documento inteiro como "MINUTA SUJEITA À APROVAÇÃO JURÍDICA" e marca
-- explicitamente, cláusula a cláusula, o que ainda não tem redação jurídica definitiva —
-- nunca inventa texto legal.

create or replace function app.contrato_documento_dados(p_contrato_id uuid)
returns jsonb
language plpgsql
stable
security invoker
as $$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'contrato', to_jsonb(c) - 'removido_em',
    'parceiro', to_jsonb(p),
    'cidade', to_jsonb(ci),
    'pricing_config', (select to_jsonb(cpc) from public.contrato_pricing_config cpc where cpc.contrato_id = c.id),
    'regras', (select to_jsonb(cr) from public.contrato_regras cr where cr.contrato_id = c.id),
    'clientes_reservados', coalesce((
      select jsonb_agg(jsonb_build_object(
        'cliente_nome', ccr.cliente_nome, 'cnpj_cpf', ccr.cnpj_cpf, 'motivo', ccr.motivo, 'status', ccr.status
      ) order by ccr.cliente_nome)
      from public.contrato_clientes_reservados ccr where ccr.contrato_id = c.id
    ), '[]'::jsonb),
    'ativos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'tipo', a.tipo, 'fabricante', a.fabricante, 'modelo', a.modelo,
        'numero_serie', a.numero_serie, 'patrimonio', a.patrimonio, 'status', a.status
      ) order by a.tipo, a.patrimonio)
      from public.ativos a where a.contrato_id = c.id and a.removido_em is null
    ), '[]'::jsonb),
    'fibras_count', (select count(*) from public.contrato_fibras cf where cf.contrato_id = c.id and cf.desvinculado_em is null),
    'pons_count', (select count(*) from public.contrato_fibras cf where cf.contrato_id = c.id and cf.desvinculado_em is null and cf.porta_pon_id is not null),
    'aditivos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'numero', ca.numero, 'tipo', ca.tipo, 'descricao', ca.descricao, 'status', ca.status, 'data', ca.data
      ) order by ca.numero)
      from public.contrato_aditivos ca where ca.contrato_id = c.id
    ), '[]'::jsonb),
    'reajustes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'competencia_base', r.competencia_base, 'percentual_aplicado', r.percentual_aplicado, 'status', r.status
      ) order by r.competencia_base desc)
      from public.reajustes r where r.contrato_id = c.id
    ), '[]'::jsonb)
  ) into v_result
  from public.contratos c
  join public.parceiros p on p.id = c.parceiro_id
  join public.cidades_infra ci on ci.id = c.cidade_id
  where c.id = p_contrato_id;

  if v_result is null then
    raise exception 'NAO_ENCONTRADO: contrato % não encontrado.', p_contrato_id;
  end if;

  return v_result;
end;
$$;

comment on function app.contrato_documento_dados(uuid) is 'Fase 3 (item 3.7): dados consolidados (nunca texto de cláusula) para gerar a minuta de contrato — ver api/lib/contractDocumentModel.js para o texto.';

create or replace function public.pricing_contrato_documento_dados(p_contrato_id uuid)
returns jsonb language sql security invoker as $$ select app.contrato_documento_dados(p_contrato_id); $$;
grant execute on function public.pricing_contrato_documento_dados(uuid) to authenticated;

-- ============================================================================
-- Registro de auditoria da exportação da minuta (PDF/DOCX), mesmo padrão de
-- app.registrar_exportacao_proposta (migration 20260909090100). Precisa antes
-- adicionar 'CONTRACT_MINUTA_EXPORT' à whitelist de app.registrar_auditoria_semantica
-- — recriada aqui com a MESMA assinatura (text,uuid,text,text,jsonb,jsonb), só a
-- whitelist interna cresce; nunca altera comportamento das ações já existentes.
-- ============================================================================

create or replace function app.registrar_auditoria_semantica(
  p_entidade text,
  p_entidade_id uuid,
  p_acao text,
  p_motivo text default null,
  p_valor_anterior jsonb default null,
  p_valor_novo jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ip inet;
begin
  if p_acao not in (
    'ARCHIVE', 'RESTORE', 'BLOCKED_ARCHIVE', 'BLOCKED_DELETE',
    'PROPOSAL_APPROVE', 'PROPOSAL_REJECT', 'PROPOSAL_STATUS_CHANGE',
    'PROPOSAL_VERSION_CREATE', 'PROPOSAL_DUPLICATE', 'PROPOSAL_EXPORT',
    'SIGNATURE_ENVELOPE_CREATE', 'SIGNATURE_ENVELOPE_SEND', 'SIGNATURE_ENVELOPE_CANCEL',
    'SIGNATURE_EVENT_RECEIVED', 'SIGNATURE_VALIDATED',
    'CONTRACT_GENERATE', 'CONTRACT_ACTIVATE', 'CONTRACT_ACTIVATE_BLOCKED',
    'CONTRACT_ADDENDUM_CREATE', 'CONTRACT_ADDENDUM_APPROVE', 'CONTRACT_ADDENDUM_ACTIVATE',
    'CONTRACT_REAJUSTE_APLICADO',
    'USER_PROFILE_CREATE', 'USER_PROFILE_UPDATE',
    'PRICE_EXCEPTION_REQUEST',
    'USER_INVITE', 'USER_INVITE_FAILED', 'USER_RESEND_INVITE',
    'USER_DEACTIVATE', 'USER_REACTIVATE', 'USER_RESET_ACCESS',
    'PARTNER_DEACTIVATE', 'PARTNER_REACTIVATE',
    'SIGNATURE_TEST_CONNECTION',
    'USER_INVITE_STARTED', 'USER_AUTH_CREATED', 'USER_PROFILE_CREATED', 'USER_INVITE_COMPLETED',
    'USER_AUTH_ROLLBACK', 'USER_AUTH_ORPHAN', 'USER_PROFILE_RECONCILED',
    'CONTRACT_MINUTA_EXPORT', 'CONTRACT_RULES_UPDATE', 'CONTRACT_RESERVED_CLIENT_ADD', 'CONTRACT_RESERVED_CLIENT_UPDATE'
  ) then
    raise exception 'app.registrar_auditoria_semantica: ação inválida %.', p_acao;
  end if;

  begin
    v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', '')::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.auditoria (usuario_id, ip, acao, entidade, entidade_id, valor_anterior, valor_novo, motivo, origem)
  values (auth.uid(), v_ip, p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, p_motivo, 'API');
end;
$$;

comment on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb) is 'Fase 3 (item 3.7): mesma função desde a Fase 2.3.1 (seção 28) — só a whitelist interna cresceu (CONTRACT_MINUTA_EXPORT + guardrails de contrato). SECURITY DEFINER para poder inserir em auditoria mesmo sem policy de INSERT para authenticated; sempre grava auth.uid() do chamador, nunca um usuario_id arbitrário vindo de parâmetro.';

create or replace function app.registrar_exportacao_contrato_minuta(p_contrato_id uuid, p_formato text, p_versao_rotulo text default null)
returns void
language plpgsql
security invoker
as $$
declare
  v_existe boolean;
begin
  if p_formato not in ('PDF', 'DOCX') then
    raise exception 'Formato % inválido — use PDF ou DOCX.', p_formato;
  end if;

  select exists(select 1 from public.contratos where id = p_contrato_id) into v_existe;
  if not v_existe then
    raise exception 'NAO_ENCONTRADO: contrato % não encontrado.', p_contrato_id;
  end if;

  perform app.registrar_auditoria_semantica(
    'contratos', p_contrato_id, 'CONTRACT_MINUTA_EXPORT',
    format('Minuta exportada como %s%s', p_formato, case when p_versao_rotulo is not null then ' (' || p_versao_rotulo || ')' else '' end)
  );
end;
$$;

comment on function app.registrar_exportacao_contrato_minuta(uuid, text, text) is 'Fase 3 (item 3.7): registra na auditoria toda exportação de minuta de contrato em PDF/DOCX — nunca ignora, mesma disciplina de app.registrar_exportacao_proposta.';

create or replace function public.pricing_contrato_registrar_exportacao_minuta(p_contrato_id uuid, p_formato text, p_versao_rotulo text default null)
returns void language sql as $$ select app.registrar_exportacao_contrato_minuta(p_contrato_id, p_formato, p_versao_rotulo); $$;
grant execute on function public.pricing_contrato_registrar_exportacao_minuta(uuid, text, text) to authenticated;
