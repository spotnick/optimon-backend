-- OptiMon — Fase 3.10: fechamento do fluxo Proposta → Aprovação → Contrato + cláusulas
-- jurídicas + modo externo + homologação E2E.
--
-- INVESTIGAÇÃO PRÉVIA (seção 13 do prompt — "não mexer no que já está funcionando"):
--   - app.gerar_contrato_de_proposta já existe e já bloqueia corretamente: proposta não
--     ASSINADA, proposta já com contrato_id, prazo<48 sem exceção — o botão "Criar
--     Contrato" da Fase 3.10 (Problema 3) REUSA esta função sem alterar seu gate de
--     status (ASSINADA), só ganha rótulo/UX novos no frontend e 2 lacunas reais
--     corrigidas aqui: (a) nenhum vínculo reverso contrato->proposta existia
--     (propostas_comerciais.contrato_id é a ÚNICA direção gravada — seção 3.4 do prompt
--     exige exibição bidirecional "Proposta de origem: PROP-XXXX" no lado do contrato);
--     (b) minuta não era auditada como evento próprio no momento da criação do contrato.
--   - pricing_proposal_external_view (Problema 2) já filtra corretamente no backend (não
--     é um vazamento de dado de governança) — a lacuna real é: (a) sem observações
--     comerciais/próximos passos (campos não existem no schema); (b) sem nome do POP
--     resolvido (nem sequer no modo Interna — pop_id nunca era resolvido para nome em
--     nenhum lugar). Corrigido aditivamente abaixo.
--   - parceiros JÁ TEM campo de endereço estruturado desde a Fase 2.5 (migration
--     20260913090100: endereco_logradouro/numero/complemento/bairro/cidade/uf/cep) —
--     achado real ao investigar api/routes/partners.js antes de criar uma coluna nova
--     (evitou duplicar dado que já existe): NÃO cria nenhuma coluna de endereço aqui.
--     O checklist da minuta (seção 4 do prompt) usa esses campos já existentes, ver
--     contractDocumentModel.js (cláusula de Objeto).
--   - Nenhuma tabela/função desta fase é recriada do zero — todas as alterações abaixo
--     são ADITIVAS (ALTER TABLE ADD COLUMN, CREATE OR REPLACE preservando assinatura,
--     nova função só onde não havia rota equivalente).

-- ============================================================================
-- 1) Colunas novas — todas nullable, aditivas, sem default fabricado.
-- ============================================================================

alter table public.propostas_comerciais
  add column if not exists observacoes_comerciais text,
  add column if not exists proximos_passos text;
comment on column public.propostas_comerciais.observacoes_comerciais is 'Fase 3.10 (Problema 2, seção 2.1): texto comercial livre, preenchido pelo Comercial, exibido tanto no modo Interna quanto Externa Parceiro (não é dado sensível de governança).';
comment on column public.propostas_comerciais.proximos_passos is 'Fase 3.10 (Problema 2, seção 2.1): texto comercial livre ("próximos passos"), mesmo tratamento de observacoes_comerciais.';

alter table public.contratos
  add column if not exists proposta_origem_id uuid references public.propostas_comerciais(id);
comment on column public.contratos.proposta_origem_id is 'Fase 3.10 (Problema 3, seção 3.4): vínculo reverso permanente contrato -> proposta que o originou, para exibir "Proposta de origem: PROP-XXXX" no lado do contrato (o vínculo direto propostas_comerciais.contrato_id já existia desde a Fase 2.5; este é o sentido inverso, que faltava). Populado por app.gerar_contrato_de_proposta a partir de agora; backfill abaixo cobre contratos já gerados antes desta migration.';

-- Backfill idempotente para contratos que já foram gerados a partir de uma proposta antes
-- desta migration (usa o vínculo direto já existente e confiável: propostas_comerciais.contrato_id).
update public.contratos c
   set proposta_origem_id = p.id
  from public.propostas_comerciais p
 where p.contrato_id = c.id
   and c.proposta_origem_id is null;

-- ============================================================================
-- 2) app.enriquecer_proposta — adiciona pop_nome (nunca resolvido antes, nem no modo
--    Interna) + observacoes_comerciais/proximos_passos. Mesma assinatura (CREATE OR
--    REPLACE simples). Junta infra_pops via snapshot->>'pop_id' com LEFT JOIN — proposta
--    pode não ter POP específico definido (campo opcional desde a Fase 2.4).
-- ============================================================================

-- IMPORTANTE: esta é a definição REAL e completa já existente (migration 20260909090100,
-- linhas 440-478), lida diretamente do arquivo antes de qualquer alteração (nunca
-- reconstruída de memória) — CREATE OR REPLACE preserva TODOS os campos originais e só
-- ACRESCENTA pop_nome/observacoes_comerciais/proximos_passos ao final. Mesma assinatura
-- (p public.propostas_comerciais), mesmo language sql, para não quebrar nenhum chamador.
create or replace function app.enriquecer_proposta(p public.propostas_comerciais)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'id', p.id,
    'numero', p.numero,
    'status', p.status,
    'numero_versao', p.numero_versao,
    'proposta_raiz_id', p.proposta_raiz_id,
    'duplicada_de_id', p.duplicada_de_id,
    'simulacao_id', p.simulacao_id,
    'pricing_version_id', p.pricing_version_id,
    'override_request_id', p.override_request_id,
    'contrato_id', p.contrato_id,
    'cidade_id', p.cidade_id,
    'cidade_nome', (select c.nome from public.cidades_infra c where c.id = p.cidade_id),
    'cidade_uf', (select c.uf from public.cidades_infra c where c.id = p.cidade_id),
    'parceiro_id', p.parceiro_id,
    'parceiro_razao_social', (select pa.razao_social from public.parceiros pa where pa.id = p.parceiro_id),
    'parceiro_nome_fantasia', (select pa.nome_fantasia from public.parceiros pa where pa.id = p.parceiro_id),
    'parceiro_nome_capa', p.parceiro_nome_capa,
    'parceiro_cargo_contato', p.parceiro_cargo_contato,
    'validade_dias', p.validade_dias,
    'snapshot', p.snapshot,
    'criado_por', p.criado_por,
    'criado_por_nome', (select u.nome from public.usuarios u where u.id = p.criado_por),
    'criado_em', p.criado_em,
    'autorizado_por', p.autorizado_por,
    'autorizado_por_nome', (select u.nome from public.usuarios u where u.id = p.autorizado_por),
    'autorizado_em', p.autorizado_em,
    'preco_autorizado', p.preco_autorizado,
    'motivo_autorizacao', p.motivo_autorizacao,
    'motivo_status', p.motivo_status,
    'prazo_meses', (select s.prazo_meses from public.simulacoes s where s.id = p.simulacao_id),
    -- Fase 3.10 (Problema 2, seção 4) — campos novos, aditivos:
    'pop_nome', (select pop.nome from public.infra_pops pop where pop.id::text = (p.snapshot->>'pop_id')),
    'observacoes_comerciais', p.observacoes_comerciais,
    'proximos_passos', p.proximos_passos,
    -- Fase 3.10 (Problema 3, seção 3.4) — "Contrato vinculado: CTR-XXXX" no lado da proposta:
    'contrato_numero', (select ct.numero from public.contratos ct where ct.id = p.contrato_id)
  );
$$;
comment on function app.enriquecer_proposta(public.propostas_comerciais) is 'Fase 2.4 — monta o jsonb enriquecido (join cidade/parceiro/usuários) de uma proposta. Reaproveitado por pricing_proposals_list/get_by_id/versions. Fase 3.10 (Problema 2, seção 4) acrescenta pop_nome (resolvido de snapshot->>pop_id, nunca antes exposto em lugar nenhum) e observacoes_comerciais/proximos_passos — nenhum campo pré-existente foi removido.';

-- ============================================================================
-- 3) pricing_proposal_external_view — IMPORTANTE: definição REAL lida diretamente da
--    migration 20260909090100 (linhas 573-608) antes desta alteração. O comentário
--    original já documenta a whitelist de segurança (nunca floor/opening/discount/
--    preco_minimo_autorizado/governance_status/partner_margin/autorização interna) —
--    esta fase NÃO adiciona nenhum campo de governança/margem, só 4 campos comerciais
--    não-sensíveis pedidos no Problema 2 do prompt (POP, capacidade em portas PON,
--    observações comerciais, próximos passos). pons_count já existe dentro do próprio
--    snapshot (confirmado por leitura direta de uma proposta real — chave
--    'pons_count'), então não precisa de nenhum join novo para esse campo.
-- ============================================================================

create or replace function public.pricing_proposal_external_view(p_proposta_id uuid)
returns jsonb
language sql
stable
security invoker
as $$
  select jsonb_build_object(
    'id', pc.id,
    'numero', pc.numero,
    'status', pc.status,
    'numero_versao', pc.numero_versao,
    'cidade_nome', c.nome,
    'cidade_uf', c.uf,
    'parceiro_nome_capa', coalesce(pc.parceiro_nome_capa, pa.nome_fantasia, pa.razao_social),
    'parceiro_cargo_contato', pc.parceiro_cargo_contato,
    'validade_dias', pc.validade_dias,
    'criado_em', pc.criado_em,
    -- só os campos comerciais que o parceiro tem o direito de ver — nunca
    -- floor/opening/discount/max_override_discount_percent/
    -- preco_minimo_autorizado/governance_status/partner_margin/autorizacao.
    'clientes', pc.snapshot->>'clientes',
    'arpu', pc.snapshot->>'arpu',
    'faturamento', pc.snapshot->>'faturamento',
    'preco_proposto', pc.snapshot->>'preco_proposto',
    'revenue_share_pct', pc.snapshot->>'revenue_share_pct',
    'prazo_meses', s.prazo_meses,
    -- Fase 3.10 (Problema 2, seções 2.1/2.2) — campos comerciais novos, não-sensíveis:
    'pop_nome', pop.nome,
    'pons_count', pc.snapshot->>'pons_count',
    'observacoes_comerciais', pc.observacoes_comerciais,
    'proximos_passos', pc.proximos_passos
  )
  from public.propostas_comerciais pc
  left join public.cidades_infra c on c.id = pc.cidade_id
  left join public.parceiros pa on pa.id = pc.parceiro_id
  left join public.simulacoes s on s.id = pc.simulacao_id
  left join public.infra_pops pop on pop.id::text = (pc.snapshot->>'pop_id')
  where pc.id = p_proposta_id;
$$;
comment on function public.pricing_proposal_external_view(uuid) is 'GET /api/proposals/:id/public — Fase 2.4 seção 46 (prep) + Fase 3.10 (Problema 2). Whitelist explícita de campos — NUNCA floor/opening/discount/max_override_discount_percent/preco_minimo_autorizado/governance_status/autorizado_por/motivo_autorizacao (dados internos de governança/margem). Fase 3.10 acrescenta pop_nome/pons_count/observacoes_comerciais/proximos_passos — todos comerciais, não-sensíveis, necessários para o modo Externa Parceiro parecer um documento comercial completo (Problema 2 do prompt).';

grant execute on function public.pricing_proposal_external_view(uuid) to authenticated;

-- ============================================================================
-- 4) app.contrato_documento_dados — acrescenta 'parceiro_responsaveis' (join com
--    parceiros_responsaveis, tabela já existente desde a Fase 2.5 — nunca antes
--    exposta a este payload). Cobre "representantes legais/responsáveis/contatos" do
--    checklist da minuta (seção 4 do prompt) que buildContractDocumentModel.js ainda não
--    usa diretamente (fica disponível para uso futuro da minuta/telas sem precisar de
--    outra migration). IMPORTANTE: definição REAL lida diretamente da migration
--    20260930090000 (linhas 161-270) antes desta alteração — todos os campos originais
--    preservados, só um jsonb_build_object novo acrescentado.
-- ============================================================================

create or replace function app.contrato_documento_dados(p_contrato_id uuid)
returns jsonb
language plpgsql
stable
as $function$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'contrato', to_jsonb(c) - 'removido_em',
    'parceiro', to_jsonb(p),
    'cidade', to_jsonb(ci),
    'pricing_config', (select to_jsonb(cpc) from public.contrato_pricing_config cpc where cpc.contrato_id = c.id),
    'regras', (select to_jsonb(cr) from public.contrato_regras cr where cr.contrato_id = c.id),
    'rescisao_config', (select to_jsonb(rc) from public.contrato_rescisao_config rc where rc.contrato_id = c.id),
    'clientes_reservados', coalesce((
      select jsonb_agg(jsonb_build_object(
        'cliente_nome', ccr.cliente_nome, 'cnpj_cpf', ccr.cnpj_cpf, 'motivo', ccr.motivo,
        'status', ccr.status, 'tipo', ccr.tipo, 'documento_referencia', ccr.documento_referencia
      ) order by (ccr.tipo <> 'OUTRO') desc, ccr.cliente_nome)
      from public.contrato_clientes_reservados ccr where ccr.contrato_id = c.id
    ), '[]'::jsonb),
    'ativos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'tipo', a.tipo, 'fabricante', a.fabricante, 'modelo', a.modelo,
        'numero_serie', a.numero_serie, 'patrimonio', a.patrimonio, 'status', a.status
      ) order by a.tipo, a.patrimonio)
      from public.ativos a where a.contrato_id = c.id and a.removido_em is null
    ), '[]'::jsonb),
    'ativos_devolucao', coalesce((
      select jsonb_agg(jsonb_build_object(
        'ativo_tipo', a.tipo, 'ativo_patrimonio', a.patrimonio, 'ativo_numero_serie', a.numero_serie,
        'data_solicitacao', ad.data_solicitacao, 'data_devolucao', ad.data_devolucao,
        'condicao', ad.condicao, 'valor_perdas_danos', ad.valor_perdas_danos, 'status_final', ad.status_final
      ) order by ad.data_solicitacao desc)
      from public.ativos_devolucao ad join public.ativos a on a.id = ad.ativo_id
      where ad.contrato_id = c.id
    ), '[]'::jsonb),
    'fibras_count', (select count(*) from public.contrato_fibras cf where cf.contrato_id = c.id and cf.desvinculado_em is null),
    'pons_count', (select count(*) from public.contrato_fibras cf where cf.contrato_id = c.id and cf.desvinculado_em is null and cf.porta_pon_id is not null),
    'clientes_ativos_contrato', coalesce((
      select sum(pon.capacidade_utilizada_assinantes)
      from public.contrato_fibras cf
      join public.infra_portas_pon pon on pon.id = cf.porta_pon_id
      where cf.contrato_id = c.id and cf.desvinculado_em is null and cf.porta_pon_id is not null
    ), 0),
    'infraestrutura_detalhe', coalesce((
      select jsonb_agg(jsonb_build_object(
        'cidade', ci.nome, 'uf', ci.uf,
        'pop', pop.nome,
        'rota', seg.nome, 'rota_origem', seg.origem, 'rota_destino', seg.destino,
        'cabo', cab.identificacao, 'cabo_capacidade_fo', cab.capacidade_fo,
        'recurso_cedido', case when cf.porta_pon_id is not null then 'Porta PON' else 'Fibra Apagada' end,
        'identificacao_recurso', case when cf.porta_pon_id is not null then pon2.codigo_porta else ('Fibra ' || fib.numero_fibra || ' (par ' || fib.par_numero || ')') end,
        'comprimento_km', seg.extensao_km,
        'postes_envolvidos', (select coalesce(sum(pt.quantidade), 0) from public.infra_postes pt where pt.segmento_id = seg.id),
        'capacidade_maxima', pon2.capacidade_max_assinantes,
        'data_inicio', cf.vinculado_em
      ) order by ci.nome, pop.nome, seg.nome)
      from public.contrato_fibras cf
      join public.infra_fibras fib on fib.id = cf.fibra_id
      join public.infra_cabos cab on cab.id = fib.cabo_id
      join public.infra_segmentos seg on seg.id = cab.segmento_id
      left join public.infra_pops pop on pop.id = cab.pop_id
      left join public.infra_portas_pon pon2 on pon2.id = cf.porta_pon_id
      where cf.contrato_id = c.id and cf.desvinculado_em is null
    ), '[]'::jsonb),
    'rampa', coalesce((
      select jsonb_agg(jsonb_build_object(
        'month_start', r.month_start, 'month_end', r.month_end,
        'percentage', r.percentage, 'component', r.component
      ) order by r.month_start)
      from public.pricing_ramp_rules r
      where r.contrato_id = c.id
         or (r.contrato_id is null and not exists (select 1 from public.pricing_ramp_rules r2 where r2.contrato_id = c.id))
    ), '[]'::jsonb),
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
    ), '[]'::jsonb),
    'regras_solicitacoes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'tipo', rs.tipo, 'status', rs.status, 'descricao', rs.descricao,
        'parecer_engenharia', rs.parecer_engenharia, 'parecer_comercial', rs.parecer_comercial,
        'motivo_rejeicao', rs.motivo_rejeicao, 'etapa_rejeicao', rs.etapa_rejeicao,
        'criado_em', rs.criado_em
      ) order by rs.criado_em desc)
      from public.contrato_regras_solicitacoes rs where rs.contrato_id = c.id
    ), '[]'::jsonb),
    -- Fase 3.10 (seção 4 do prompt — "responsáveis/contatos/representantes legais"):
    'parceiro_responsaveis', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nome', pr.nome, 'cargo', pr.cargo, 'tipo', pr.tipo, 'representante_legal', pr.representante_legal,
        'email', pr.email, 'telefone', pr.telefone
      ) order by pr.representante_legal desc, pr.nome)
      from public.parceiros_responsaveis pr where pr.parceiro_id = c.parceiro_id and pr.ativo = true
    ), '[]'::jsonb),
    -- Fase 3.10 (seção 3.4 — vínculo bidirecional):
    'proposta_origem', (select jsonb_build_object('id', po.id, 'numero', po.numero, 'status', po.status)
      from public.propostas_comerciais po where po.id = c.proposta_origem_id)
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
$function$;

comment on function app.contrato_documento_dados(uuid) is 'Fase 3 (item 3.7) + Fase 3.8 (3.8-08/3.8-13) + Fase 3.9 (revisão de cláusulas contratuais) + Fase 3.10 (parceiro_responsaveis e proposta_origem, seções 3.4/4 do prompt): dados consolidados para a minuta — nunca texto de cláusula, ver contractDocumentModel.js.';

-- ============================================================================
-- 5) Amplia a whitelist de ações semânticas (tabela + função) — aditivo, nunca remove
--    nenhum rótulo existente (mesmo padrão da migration 20260929110000). Só 3 rótulos
--    novos: dos 9 pedidos na seção 7 do prompt, 6 já existem sob outro nome que cobre
--    exatamente o mesmo evento de negócio (mapeamento abaixo, documentado para o
--    relatório final em vez de criar rótulos duplicados):
--      PROPOSAL_APPROVED        -> já existe como PROPOSAL_APPROVE
--      PROPOSAL_REJECTED        -> já existe como PROPOSAL_REJECT
--      CONTRACT_CREATED_FROM_PROPOSAL -> já existe como CONTRACT_GENERATE (é
--                                   literalmente "contrato gerado a partir de proposta"
--                                   — nunca gerado de outra forma no sistema)
--      CONTRACT_SENT_FOR_SIGNATURE -> já existe como SIGNATURE_ENVELOPE_SEND
--      CONTRACT_SIGNED          -> já existe como SIGNATURE_VALIDATED
--      CONTRACT_ACTIVATED       -> já existe como CONTRACT_ACTIVATE
--    Os 3 realmente novos (nenhum rótulo equivalente existia):
--      PROPOSAL_CREATED, PROPOSAL_UPDATED, CONTRACT_MINUTA_GENERATED.
-- ============================================================================
alter table public.auditoria drop constraint auditoria_acao_check;
alter table public.auditoria add constraint auditoria_acao_check check (acao = any (array[
  'INSERT','UPDATE','DELETE','LOGIN','ARCHIVE','RESTORE','BLOCKED_ARCHIVE','BLOCKED_DELETE',
  'PROPOSAL_APPROVE','PROPOSAL_REJECT','PROPOSAL_STATUS_CHANGE','PROPOSAL_VERSION_CREATE',
  'PROPOSAL_DUPLICATE','PROPOSAL_EXPORT',
  'SIGNATURE_ENVELOPE_CREATE','SIGNATURE_ENVELOPE_SEND','SIGNATURE_ENVELOPE_CANCEL',
  'SIGNATURE_EVENT_RECEIVED','SIGNATURE_VALIDATED','SIGNATURE_TEST_CONNECTION',
  'CONTRACT_GENERATE','CONTRACT_ACTIVATE','CONTRACT_ACTIVATE_BLOCKED',
  'CONTRACT_ADDENDUM_CREATE','CONTRACT_ADDENDUM_APPROVE','CONTRACT_ADDENDUM_ACTIVATE',
  'CONTRACT_REAJUSTE_APLICADO','CONTRACT_MINUTA_EXPORT','CONTRACT_RULES_UPDATE',
  'CONTRACT_RESERVED_CLIENT_ADD','CONTRACT_RESERVED_CLIENT_UPDATE',
  'USER_PROFILE_CREATE','USER_PROFILE_UPDATE','PRICE_EXCEPTION_REQUEST',
  'USER_INVITE','USER_INVITE_FAILED','USER_RESEND_INVITE','USER_DEACTIVATE','USER_REACTIVATE',
  'USER_RESET_ACCESS','PARTNER_DEACTIVATE','PARTNER_REACTIVATE',
  'USER_INVITE_STARTED','USER_AUTH_CREATED','USER_PROFILE_CREATED','USER_INVITE_COMPLETED',
  'USER_AUTH_ROLLBACK','USER_AUTH_ORPHAN','USER_PROFILE_RECONCILED','USER_HARD_DELETE',
  'PON_ADDED','PON_REMOVED','POP_ADDED','POP_REMOVED','CLIENT_RESERVED_REMOVED',
  'CONTRACT_TERMINATED','THIRD_PARTY_INFRA_REQUEST','THIRD_PARTY_INFRA_APPROVED',
  'OWN_NETWORK_EXCEPTION_REQUEST','OWN_NETWORK_EXCEPTION',
  -- Fase 3.10 (Problema 3, seção 7):
  'PROPOSAL_CREATED','PROPOSAL_UPDATED','CONTRACT_MINUTA_GENERATED'
]));

create or replace function app.registrar_auditoria_semantica(p_entidade text, p_entidade_id uuid, p_acao text, p_motivo text default null, p_valor_anterior jsonb default null, p_valor_novo jsonb default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
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
    'CONTRACT_MINUTA_EXPORT', 'CONTRACT_RULES_UPDATE', 'CONTRACT_RESERVED_CLIENT_ADD', 'CONTRACT_RESERVED_CLIENT_UPDATE',
    'USER_HARD_DELETE',
    'PON_ADDED', 'PON_REMOVED', 'POP_ADDED', 'POP_REMOVED', 'CLIENT_RESERVED_REMOVED',
    'CONTRACT_TERMINATED', 'THIRD_PARTY_INFRA_REQUEST', 'THIRD_PARTY_INFRA_APPROVED',
    'OWN_NETWORK_EXCEPTION_REQUEST', 'OWN_NETWORK_EXCEPTION',
    -- Fase 3.10 (Problema 3, seção 7):
    'PROPOSAL_CREATED', 'PROPOSAL_UPDATED', 'CONTRACT_MINUTA_GENERATED'
  ) then
    raise exception 'app.registrar_auditoria_semantica: ação inválida %.', p_acao;
  end if;

  begin
    v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for', '')::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.auditoria (usuario_id, ip, acao, entidade, entidade_id, valor_anterior, valor_novo, origem, motivo)
  values (auth.uid(), v_ip, p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, 'app', p_motivo);
end;
$function$;

comment on function app.registrar_auditoria_semantica(text, uuid, text, text, jsonb, jsonb) is 'Fase 2.3.1, ampliada nas Fases 3.8/3.10. Fase 3.10 (Problema 3, seção 7) acrescenta PROPOSAL_CREATED/PROPOSAL_UPDATED/CONTRACT_MINUTA_GENERATED — os outros 6 eventos pedidos no prompt já eram cobertos por rótulos equivalentes pré-existentes (ver comentário da migration).';

-- ============================================================================
-- 6) pricing_proposal_create — mesma definição REAL (migration 20260909090100, linhas
--    61-124, lida diretamente antes desta alteração), mesma assinatura (CREATE OR
--    REPLACE simples — não muda a lista de parâmetros, não precisa DROP), só acrescenta
--    UMA linha: perform do evento PROPOSAL_CREATED depois do INSERT (Fase 3.10, seção 7).
-- ============================================================================

create or replace function public.pricing_proposal_create(
  p_simulacao_id uuid,
  p_cidade_id uuid default null,
  p_parceiro_id uuid default null,
  p_contrato_id uuid default null,
  p_pricing_version_id uuid default null,
  p_override_request_id uuid default null,
  p_snapshot jsonb default null,
  p_parceiro_nome_capa text default null,
  p_parceiro_cargo_contato text default null,
  p_validade_dias integer default 15
)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_snapshot jsonb;
  v_row public.propostas_comerciais;
  v_floor numeric;
  v_recommended numeric;
  v_preco numeric;
  v_status text;
begin
  if p_simulacao_id is null then
    raise exception 'simulacao_id é obrigatório — proposta sempre nasce de uma simulação salva (seção 29).';
  end if;

  if p_snapshot is null then
    select resultado into v_snapshot from public.simulacoes where id = p_simulacao_id;
    if v_snapshot is null then
      raise exception 'Simulação % não encontrada ou sem resultado salvo.', p_simulacao_id;
    end if;
  else
    v_snapshot := p_snapshot;
  end if;

  v_floor := nullif(v_snapshot->>'floor', '')::numeric;
  v_recommended := nullif(v_snapshot->>'recommended', '')::numeric;
  v_preco := coalesce(nullif(v_snapshot->>'preco_proposto', '')::numeric, v_recommended);

  if v_recommended is not null and v_preco is not null and v_preco < v_recommended then
    v_status := 'EM_APROVACAO';
  else
    v_status := 'RASCUNHO';
  end if;

  insert into public.propostas_comerciais (
    simulacao_id, cidade_id, parceiro_id, contrato_id, pricing_version_id, override_request_id,
    snapshot, criado_por, status, parceiro_nome_capa, parceiro_cargo_contato, validade_dias
  )
  values (
    p_simulacao_id, p_cidade_id, p_parceiro_id, p_contrato_id, p_pricing_version_id, p_override_request_id,
    v_snapshot, auth.uid(), v_status, p_parceiro_nome_capa, p_parceiro_cargo_contato, coalesce(p_validade_dias, 15)
  )
  returning * into v_row;

  -- Fase 3.10 (Problema 3, seção 7): evento de auditoria que faltava para o nascimento
  -- da proposta — antes só a linha crua ficava no trigger genérico (fn_auditoria), sem
  -- rótulo semântico filtrável.
  perform app.registrar_auditoria_semantica('propostas_comerciais', v_row.id, 'PROPOSAL_CREATED',
    'Proposta criada a partir da simulação ' || p_simulacao_id::text,
    null, to_jsonb(v_row));

  return v_row;
end;
$$;
comment on function public.pricing_proposal_create(uuid, uuid, uuid, uuid, uuid, uuid, jsonb, text, text, integer) is 'POST /api/proposals — "GERAR PROPOSTA" (Fase 2.2.1 seção 29 + Fase 2.4 seções 6/38). Status inicial automático: preço < recomendado → EM_APROVACAO. Fase 3.10 (seção 7) acrescenta o evento de auditoria semântica PROPOSAL_CREATED.';

grant execute on function public.pricing_proposal_create(uuid, uuid, uuid, uuid, uuid, uuid, jsonb, text, text, integer) to authenticated;

-- ============================================================================
-- 7) public.pricing_proposal_update_display_fields — rota nova que faltava: hoje NÃO
--    existe nenhum jeito de editar parceiro_nome_capa/parceiro_cargo_contato/
--    observacoes_comerciais/proximos_passos depois da criação (POST /api/proposals só
--    aceita esses 2 primeiros campos na criação — confirmado por leitura direta de
--    api/routes/proposals.js, 224 linhas, nenhuma rota PATCH existe hoje). SECURITY
--    INVOKER: a policy propostas_comerciais_update já cobre exatamente o que
--    precisamos — (DIRETOR/ADMINISTRADOR) OR (dono AND status=RASCUNHO) — mesmo padrão
--    de app.duplicar_proposta/demais funções de UPDATE desta tabela (nunca SECURITY
--    DEFINER quando a RLS já cobre, ver nota da migration 20260909090100).
-- ============================================================================

create or replace function public.pricing_proposal_update_display_fields(
  p_proposta_id uuid,
  p_parceiro_nome_capa text default null,
  p_parceiro_cargo_contato text default null,
  p_observacoes_comerciais text default null,
  p_proximos_passos text default null
)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_before public.propostas_comerciais;
  v_row public.propostas_comerciais;
begin
  select * into v_before from public.propostas_comerciais where id = p_proposta_id;
  if v_before.id is null then
    raise exception 'NAO_ENCONTRADA: proposta % não encontrada ou sem permissão de leitura.', p_proposta_id;
  end if;

  -- coalesce em TODOS os 4 campos: um parâmetro omitido (null) preserva o valor atual —
  -- nunca apaga observacoes_comerciais/proximos_passos por causa de uma chamada parcial
  -- que só queria atualizar o outro campo. Para apagar de fato um campo, o chamador
  -- passa string vazia '' (nunca null) — null é reservado para "não alterar".
  update public.propostas_comerciais
     set parceiro_nome_capa = coalesce(p_parceiro_nome_capa, parceiro_nome_capa),
         parceiro_cargo_contato = coalesce(p_parceiro_cargo_contato, parceiro_cargo_contato),
         observacoes_comerciais = coalesce(p_observacoes_comerciais, observacoes_comerciais),
         proximos_passos = coalesce(p_proximos_passos, proximos_passos)
   where id = p_proposta_id
   returning * into v_row;

  if v_row.id is null then
    raise exception 'PERMISSAO_NEGADA: sem permissão de editar esta proposta (RLS propostas_comerciais_update — só o dono com status RASCUNHO, ou DIRETOR/ADMINISTRADOR).';
  end if;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_row.id, 'PROPOSAL_UPDATED',
    'Campos de exibição/comerciais atualizados (capa e/ou observações comerciais e/ou próximos passos).',
    to_jsonb(v_before), to_jsonb(v_row));

  return v_row;
end;
$$;
comment on function public.pricing_proposal_update_display_fields(uuid, text, text, text, text) is 'Fase 3.10 (Problema 2, seção 2.1): única rota de edição pós-criação para os campos de capa/comerciais da proposta (parceiro_nome_capa/parceiro_cargo_contato/observacoes_comerciais/proximos_passos) — não existia nenhuma antes desta fase. RLS propostas_comerciais_update decide quem pode (dono em RASCUNHO, ou DIRETOR/ADMINISTRADOR). Emite PROPOSAL_UPDATED.';

grant execute on function public.pricing_proposal_update_display_fields(uuid, text, text, text, text) to authenticated;

-- ============================================================================
-- 8) app.gerar_contrato_de_proposta — IMPORTANTE: definição REAL lida diretamente da
--    migration 20260913090400 (linhas 74-163) antes desta alteração. Mesma assinatura,
--    MESMO gate de negócio já existente e testado (status <> 'ASSINADA' continua
--    bloqueando — Fase 3.10 NÃO afrouxa esse gate, ver nota no topo deste arquivo e o
--    relatório final da fase, seção "decisão de design"). Duas adições apenas:
--    (a) grava proposta_origem_id no INSERT de contratos (vínculo reverso, seção 3.4);
--    (b) emite CONTRACT_MINUTA_GENERATED logo após o CONTRACT_GENERATE já existente,
--    porque a partir deste ponto a minuta já é 100% consultável via
--    app.contrato_documento_dados/GET .../minuta (nunca uma etapa manual separada).
-- ============================================================================

create or replace function app.gerar_contrato_de_proposta(p_proposta_id uuid, p_prazo_minimo_excecao boolean default false, p_motivo_excecao_prazo text default null)
returns public.contratos
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prop public.propostas_comerciais;
  v_sim public.simulacoes;
  v_contrato public.contratos;
  v_numero text;
  v_modelo contrato_modelo;
  v_prazo integer;
  v_snapshot jsonb;
  v_revenue_share numeric;
  v_faturamento numeric;
  v_recommended numeric;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem gerar contrato a partir de uma proposta.';
  end if;

  select * into v_prop from public.propostas_comerciais where id = p_proposta_id;
  if v_prop.id is null then
    raise exception 'NAO_ENCONTRADA: proposta % não encontrada ou sem permissão de leitura.', p_proposta_id;
  end if;

  if v_prop.status <> 'ASSINADA' then
    raise exception 'STATUS_INVALIDO: só é possível gerar contrato a partir de uma proposta ASSINADA (seção 52) — status atual: %.', v_prop.status;
  end if;

  if v_prop.contrato_id is not null then
    raise exception 'JA_GERADO: esta proposta já gerou o contrato % — use aditivo para alterações (seção 39), nunca gerar de novo.', v_prop.contrato_id;
  end if;

  if v_prop.parceiro_id is null or v_prop.cidade_id is null then
    raise exception 'DADOS_INCOMPLETOS: proposta sem parceiro_id/cidade_id — não é possível gerar contrato.';
  end if;

  select * into v_sim from public.simulacoes where id = v_prop.simulacao_id;
  v_snapshot := v_prop.snapshot;

  v_modelo := coalesce(v_sim.modelo, 'HIBRIDO_REVENUE_SHARE'::contrato_modelo);
  v_prazo := coalesce((v_snapshot->>'prazo_meses')::integer, v_sim.prazo_meses, 48);
  v_revenue_share := (v_snapshot->>'revenue_share_pct')::numeric;
  v_faturamento := (v_snapshot->>'faturamento')::numeric;
  v_recommended := (v_snapshot->>'recommended')::numeric;

  if v_prazo < 48 and not p_prazo_minimo_excecao then
    raise exception 'PRAZO_MINIMO: contrato mínimo é de 48 meses (seção 32) — prazo da proposta é % meses; use uma exceção autorizada para prosseguir.', v_prazo;
  end if;

  if p_prazo_minimo_excecao and (p_motivo_excecao_prazo is null or trim(p_motivo_excecao_prazo) = '') then
    raise exception 'MOTIVO_OBRIGATORIO: prazo abaixo de 48 meses exige motivo da exceção (seção 32).';
  end if;

  v_numero := 'CONTR-' || to_char(now(), 'YYYYMMDD') || '-' || substr(gen_random_uuid()::text, 1, 8);

  insert into public.contratos (
    numero, parceiro_id, cidade_id, modelo, status, prazo_meses,
    prazo_minimo_excecao, aprovado_por, aprovado_em, proposta_origem_id
  ) values (
    v_numero, v_prop.parceiro_id, v_prop.cidade_id, v_modelo, 'RASCUNHO', v_prazo,
    p_prazo_minimo_excecao,
    case when p_prazo_minimo_excecao then auth.uid() else null end,
    case when p_prazo_minimo_excecao then now() else null end,
    v_prop.id
  )
  returning * into v_contrato;

  insert into public.contrato_pricing_config (contrato_id, percentual_revenue_share, mensalidade_minima_porta)
  values (v_contrato.id, v_revenue_share, v_recommended);

  insert into public.contrato_regras (contrato_id)
  values (v_contrato.id);

  insert into public.contrato_versions (contrato_id, versao, motivo, snapshot, criado_por)
  values (v_contrato.id, 1, 'Geração automática a partir da proposta ' || v_prop.numero || ' (Fase 2.5, seção 30).', v_snapshot, auth.uid());

  update public.propostas_comerciais
     set contrato_id = v_contrato.id,
         status = 'CONTRATO_GERADO'
   where id = v_prop.id;

  perform app.registrar_auditoria_semantica('contratos', v_contrato.id, 'CONTRACT_GENERATE',
    'Gerado automaticamente a partir da proposta ' || v_prop.numero,
    null, to_jsonb(v_contrato));

  -- Fase 3.10 (Problema 3, seção 7): a minuta já está 100% consultável neste exato ponto
  -- (contrato_pricing_config/contrato_regras/contrato_versions já inseridos acima) —
  -- nunca uma etapa manual separada, por isso o evento é emitido aqui mesmo.
  perform app.registrar_auditoria_semantica('contratos', v_contrato.id, 'CONTRACT_MINUTA_GENERATED',
    'Minuta disponível imediatamente após a geração do contrato a partir da proposta ' || v_prop.numero,
    null, jsonb_build_object('contrato_id', v_contrato.id, 'proposta_origem_id', v_prop.id, 'numero_contrato', v_contrato.numero));

  return v_contrato;
end;
$$;

comment on function app.gerar_contrato_de_proposta(uuid, boolean, text) is 'Fase 2.5 seções 30-31/52 + Fase 3.10 (Problema 3): SECURITY DEFINER (com checagem de RBAC explícita no início). Fase 3.10 acrescenta proposta_origem_id (vínculo reverso contrato->proposta, seção 3.4) e o evento de auditoria CONTRACT_MINUTA_GENERATED — o gate de negócio (só proposta ASSINADA, nunca gerar 2x) permanece EXATAMENTE o mesmo da Fase 2.5, por decisão explícita de não alterar regra já testada (seção 13 do prompt da Fase 3.10).';
