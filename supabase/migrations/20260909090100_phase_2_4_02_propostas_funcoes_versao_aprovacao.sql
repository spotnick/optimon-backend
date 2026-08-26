-- OptiMon — Fase 2.4 (2/7): funções de negócio do módulo de propostas —
-- versionamento (duplicar/nova versão), aprovação com autorização abaixo do
-- piso, rejeição, mudança de status, registro de exportação, e a atualização
-- de pricing_proposal_create para aceitar os campos de capa (seções 6/36/
-- 37/38/40/41 do prompt-mestre).
--
-- Regra de SECURITY DEFINER vs INVOKER (estabelecida na Fase 2.3.1, CRUD-CB0):
-- só é preciso SECURITY DEFINER quando a função autoriza um perfil que a RLS
-- da tabela-alvo NÃO cobre para aquela operação. A policy
-- propostas_comerciais_update já cobre exatamente (DIRETOR/ADMINISTRADOR) OR
-- (dono AND RASCUNHO) — todas as transições de status abaixo usam só esses
-- dois grupos, então TODAS as funções de UPDATE aqui permanecem SECURITY
-- INVOKER (a RLS já faz o trabalho; a checagem app.tem_perfil() dentro delas
-- é só para dar uma mensagem de erro amigável antes do erro genérico de RLS).
-- INSERT (duplicar/criar versão) usa a policy propostas_comerciais_insert
-- (COMERCIAL/DIRETOR/ADMINISTRADOR) — também já cobre o que precisamos.

-- ============================================================================
-- 1) registrar_auditoria_semantica — estende a lista de ações permitidas
--    (mesma assinatura — CREATE OR REPLACE simples, sem overload).
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
begin
  if p_acao not in (
    'ARCHIVE', 'RESTORE', 'BLOCKED_ARCHIVE', 'BLOCKED_DELETE',
    'PROPOSAL_APPROVE', 'PROPOSAL_REJECT', 'PROPOSAL_STATUS_CHANGE',
    'PROPOSAL_VERSION_CREATE', 'PROPOSAL_DUPLICATE', 'PROPOSAL_EXPORT'
  ) then
    raise exception 'app.registrar_auditoria_semantica: ação inválida %.', p_acao;
  end if;

  insert into public.auditoria (usuario_id, acao, entidade, entidade_id, valor_anterior, valor_novo, motivo, origem)
  values (auth.uid(), p_acao, p_entidade, p_entidade_id, p_valor_anterior, p_valor_novo, p_motivo, 'API');
end;
$$;

-- ============================================================================
-- 2) pricing_proposal_create — adiciona campos de capa (parceiro_nome_capa,
--    parceiro_cargo_contato, validade_dias) e calcula o status inicial a
--    partir do preço proposto no snapshot (seção 38): abaixo do recomendado
--    (piso incluso) → EM_APROVACAO; senão → RASCUNHO. Assinatura mudou
--    (3 params novos) — precisa DROP explícito antes (Postgres cria overload
--    em vez de substituir quando a lista de parâmetros muda).
-- ============================================================================

drop function if exists public.pricing_proposal_create(uuid, uuid, uuid, uuid, uuid, uuid, jsonb);

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

  -- Sem snapshot explícito, monta a partir do resultado já salvo na simulação — a
  -- proposta nunca precisa recalcular nada (fonte única: o que a simulação já congelou).
  if p_snapshot is null then
    select resultado into v_snapshot from public.simulacoes where id = p_simulacao_id;
    if v_snapshot is null then
      raise exception 'Simulação % não encontrada ou sem resultado salvo.', p_simulacao_id;
    end if;
  else
    v_snapshot := p_snapshot;
  end if;

  -- Status inicial (seção 38): preço proposto abaixo do recomendado (o que
  -- inclui abaixo do piso) nasce EM_APROVACAO; senão, RASCUNHO normal.
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

  return v_row;
end;
$$;
comment on function public.pricing_proposal_create(uuid, uuid, uuid, uuid, uuid, uuid, jsonb, text, text, integer) is 'POST /api/proposals — "GERAR PROPOSTA" (Fase 2.2.1 seção 29 + Fase 2.4 seções 6/38). Status inicial automático: preço < recomendado → EM_APROVACAO.';

grant execute on function public.pricing_proposal_create(uuid, uuid, uuid, uuid, uuid, uuid, jsonb, text, text, integer) to authenticated;

-- ============================================================================
-- 3) app.duplicar_proposta — seção 41 "Duplicar Proposta": cria uma proposta
--    NOVA e independente (própria família de versão) a partir de outra,
--    sempre em RASCUNHO, referenciando duplicada_de_id.
-- ============================================================================

create or replace function app.duplicar_proposta(p_proposta_id uuid, p_motivo text default null)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_orig public.propostas_comerciais;
  v_row public.propostas_comerciais;
begin
  select * into v_orig from public.propostas_comerciais where id = p_proposta_id;
  if v_orig.id is null then
    raise exception 'Proposta % não encontrada.', p_proposta_id;
  end if;

  insert into public.propostas_comerciais (
    simulacao_id, cidade_id, parceiro_id, contrato_id, pricing_version_id, override_request_id,
    snapshot, criado_por, status, parceiro_nome_capa, parceiro_cargo_contato, validade_dias,
    duplicada_de_id, numero_versao
  )
  values (
    v_orig.simulacao_id, v_orig.cidade_id, v_orig.parceiro_id, v_orig.contrato_id,
    v_orig.pricing_version_id, v_orig.override_request_id, v_orig.snapshot, auth.uid(), 'RASCUNHO',
    v_orig.parceiro_nome_capa, v_orig.parceiro_cargo_contato, v_orig.validade_dias,
    v_orig.id, 1
  )
  returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_row.id, 'PROPOSAL_DUPLICATE', p_motivo, null, jsonb_build_object('duplicada_de_id', v_orig.id, 'duplicada_de_numero', v_orig.numero));

  return v_row;
end;
$$;
comment on function app.duplicar_proposta(uuid, text) is 'Fase 2.4 seção 41 — "Duplicar Proposta": nova proposta independente (própria numeração/família de versão), RASCUNHO, com duplicada_de_id apontando para a origem.';

-- ============================================================================
-- 4) app.criar_versao_proposta — seção 40 "histórico e controle de versões":
--    cria V2/V3/... dentro da MESMA família (proposta_raiz_id), nunca
--    sobrescreve a anterior.
-- ============================================================================

create or replace function app.criar_versao_proposta(p_proposta_id uuid, p_motivo text default null)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_orig public.propostas_comerciais;
  v_raiz_id uuid;
  v_raiz_numero text;
  v_proxima_versao integer;
  v_numero text;
  v_row public.propostas_comerciais;
begin
  select * into v_orig from public.propostas_comerciais where id = p_proposta_id;
  if v_orig.id is null then
    raise exception 'Proposta % não encontrada.', p_proposta_id;
  end if;

  v_raiz_id := coalesce(v_orig.proposta_raiz_id, v_orig.id);
  select numero into v_raiz_numero from public.propostas_comerciais where id = v_raiz_id;
  select coalesce(max(numero_versao), 0) + 1 into v_proxima_versao
    from public.propostas_comerciais where proposta_raiz_id = v_raiz_id;
  -- numero (mesmo prefixo da raiz da família + sufixo -V<n>) — mantém a identidade visual
  -- da proposta consistente entre versões (V1/V2/V3 do "mesmo" documento) e ao mesmo
  -- tempo satisfaz a constraint UNIQUE(numero) já existente desde a Fase 2.2.1 (cada
  -- versão continua sendo uma linha própria, com seu próprio numero).
  v_numero := v_raiz_numero || '-V' || v_proxima_versao;

  insert into public.propostas_comerciais (
    numero, simulacao_id, cidade_id, parceiro_id, contrato_id, pricing_version_id, override_request_id,
    snapshot, criado_por, status, parceiro_nome_capa, parceiro_cargo_contato, validade_dias,
    proposta_raiz_id, numero_versao
  )
  values (
    v_numero, v_orig.simulacao_id, v_orig.cidade_id, v_orig.parceiro_id, v_orig.contrato_id,
    v_orig.pricing_version_id, v_orig.override_request_id, v_orig.snapshot, auth.uid(), 'RASCUNHO',
    v_orig.parceiro_nome_capa, v_orig.parceiro_cargo_contato, v_orig.validade_dias,
    v_raiz_id, v_proxima_versao
  )
  returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', v_row.id, 'PROPOSAL_VERSION_CREATE', p_motivo, null, jsonb_build_object('versao_anterior_id', v_orig.id, 'numero_versao', v_proxima_versao));

  return v_row;
end;
$$;
comment on function app.criar_versao_proposta(uuid, text) is 'Fase 2.4 seção 40 — nova versão (V2/V3...) na mesma família (proposta_raiz_id), nunca sobrescreve a versão anterior.';

-- ============================================================================
-- 5) app.aprovar_proposta — seção 38: aprovação. Exige DIRETOR/ADMINISTRADOR
--    (mesma exigência que a RLS já impõe para sair de RASCUNHO — checagem
--    aqui só antecipa uma mensagem amigável). Preço abaixo do piso exige
--    motivo obrigatório (autorização registrada com quem/quando/preço/razão).
-- ============================================================================

create or replace function app.aprovar_proposta(p_proposta_id uuid, p_motivo text default null)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_orig public.propostas_comerciais;
  v_floor numeric;
  v_preco numeric;
  v_row public.propostas_comerciais;
begin
  if not app.tem_perfil('DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode aprovar propostas — só DIRETOR ou ADMINISTRADOR.', app.perfil_atual();
  end if;

  select * into v_orig from public.propostas_comerciais where id = p_proposta_id;
  if v_orig.id is null then
    raise exception 'Proposta % não encontrada.', p_proposta_id;
  end if;
  if v_orig.status not in ('RASCUNHO', 'EM_APROVACAO') then
    raise exception 'Proposta % está em status % — só é possível aprovar a partir de RASCUNHO ou EM_APROVACAO.', v_orig.numero, v_orig.status;
  end if;

  v_floor := nullif(v_orig.snapshot->>'floor', '')::numeric;
  v_preco := coalesce(nullif(v_orig.snapshot->>'preco_proposto', '')::numeric, nullif(v_orig.snapshot->>'recommended', '')::numeric);

  if v_floor is not null and v_preco is not null and v_preco < v_floor and (p_motivo is null or trim(p_motivo) = '') then
    raise exception 'MOTIVO_OBRIGATORIO: preço proposto (%) está abaixo do piso (%) — autorização exige justificativa.', v_preco, v_floor;
  end if;

  update public.propostas_comerciais
    set status = 'APROVADA',
        autorizado_por = auth.uid(),
        autorizado_em = now(),
        preco_autorizado = v_preco,
        motivo_autorizacao = p_motivo
    where id = p_proposta_id
    returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', p_proposta_id, 'PROPOSAL_APPROVE', p_motivo, jsonb_build_object('status', v_orig.status), jsonb_build_object('status', 'APROVADA', 'preco_autorizado', v_preco));

  return v_row;
end;
$$;
comment on function app.aprovar_proposta(uuid, text) is 'Fase 2.4 seção 38 — aprovação de proposta. SECURITY INVOKER: a policy propostas_comerciais_update já restringe a DIRETOR/ADMINISTRADOR a saída de RASCUNHO; checagem app.tem_perfil aqui só antecipa mensagem amigável. Abaixo do piso exige motivo.';

-- ============================================================================
-- 6) app.rejeitar_proposta — seção 37: motivo sempre obrigatório.
-- ============================================================================

create or replace function app.rejeitar_proposta(p_proposta_id uuid, p_motivo text)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_orig public.propostas_comerciais;
  v_row public.propostas_comerciais;
begin
  if p_motivo is null or trim(p_motivo) = '' then
    raise exception 'MOTIVO_OBRIGATORIO: motivo é obrigatório para rejeitar uma proposta.';
  end if;

  select * into v_orig from public.propostas_comerciais where id = p_proposta_id;
  if v_orig.id is null then
    raise exception 'Proposta % não encontrada.', p_proposta_id;
  end if;
  if v_orig.status in ('ACEITA', 'RECUSADA', 'EXPIRADA', 'CANCELADA') then
    raise exception 'Proposta % já está em estado terminal (%) — não pode ser rejeitada.', v_orig.numero, v_orig.status;
  end if;

  update public.propostas_comerciais
    set status = 'RECUSADA', motivo_status = p_motivo
    where id = p_proposta_id
    returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', p_proposta_id, 'PROPOSAL_REJECT', p_motivo, jsonb_build_object('status', v_orig.status), jsonb_build_object('status', 'RECUSADA'));

  return v_row;
end;
$$;
comment on function app.rejeitar_proposta(uuid, text) is 'Fase 2.4 seção 37 — rejeição de proposta; motivo sempre obrigatório.';

-- ============================================================================
-- 7) app.mudar_status_proposta — demais transições do ciclo de vida (seção
--    36): ENVIADA, EM_NEGOCIACAO, ACEITA, EXPIRADA, CANCELADA. RASCUNHO,
--    EM_APROVACAO, APROVADA e RECUSADA só via as funções dedicadas acima.
-- ============================================================================

create or replace function app.mudar_status_proposta(p_proposta_id uuid, p_novo_status text, p_motivo text default null)
returns public.propostas_comerciais
language plpgsql
security invoker
as $$
declare
  v_orig public.propostas_comerciais;
  v_row public.propostas_comerciais;
begin
  if p_novo_status not in ('ENVIADA', 'EM_NEGOCIACAO', 'ACEITA', 'EXPIRADA', 'CANCELADA') then
    raise exception 'Status % inválido para app.mudar_status_proposta — use app.aprovar_proposta/app.rejeitar_proposta para RASCUNHO/EM_APROVACAO/APROVADA/RECUSADA.', p_novo_status;
  end if;

  select * into v_orig from public.propostas_comerciais where id = p_proposta_id;
  if v_orig.id is null then
    raise exception 'Proposta % não encontrada.', p_proposta_id;
  end if;
  if v_orig.status in ('ACEITA', 'RECUSADA', 'EXPIRADA', 'CANCELADA') then
    raise exception 'Proposta % já está em estado terminal (%) — não pode mudar de status.', v_orig.numero, v_orig.status;
  end if;
  if p_novo_status = 'CANCELADA' and (p_motivo is null or trim(p_motivo) = '') then
    raise exception 'MOTIVO_OBRIGATORIO: motivo é obrigatório para cancelar uma proposta.';
  end if;

  update public.propostas_comerciais
    set status = p_novo_status, motivo_status = coalesce(p_motivo, motivo_status)
    where id = p_proposta_id
    returning * into v_row;

  perform app.registrar_auditoria_semantica('propostas_comerciais', p_proposta_id, 'PROPOSAL_STATUS_CHANGE', p_motivo, jsonb_build_object('status', v_orig.status), jsonb_build_object('status', p_novo_status));

  return v_row;
end;
$$;
comment on function app.mudar_status_proposta(uuid, text, text) is 'Fase 2.4 seção 36 — transições ENVIADA/EM_NEGOCIACAO/ACEITA/EXPIRADA/CANCELADA. Bloqueia saída de estados terminais.';

-- ============================================================================
-- 8) app.registrar_exportacao_proposta — seção 39/42: toda exportação
--    PDF/DOCX fica registrada na auditoria (não escreve na tabela de
--    propostas — só auditoria — por isso não precisa de checagem de RLS
--    de UPDATE, qualquer usuário autenticado que pode VER a proposta
--    (policy _select = true) pode exportá-la).
-- ============================================================================

create or replace function app.registrar_exportacao_proposta(p_proposta_id uuid, p_formato text, p_versao_rotulo text default null)
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

  select exists(select 1 from public.propostas_comerciais where id = p_proposta_id) into v_existe;
  if not v_existe then
    raise exception 'Proposta % não encontrada.', p_proposta_id;
  end if;

  perform app.registrar_auditoria_semantica(
    'propostas_comerciais', p_proposta_id, 'PROPOSAL_EXPORT',
    format('Exportado como %s%s', p_formato, case when p_versao_rotulo is not null then ' (' || p_versao_rotulo || ')' else '' end)
  );
end;
$$;
comment on function app.registrar_exportacao_proposta(uuid, text, text) is 'Fase 2.4 seções 39/42 — registra na auditoria toda exportação de proposta em PDF/DOCX.';

-- ============================================================================
-- 9) WRAPPERS public.* (expostos via PostgREST/RPC) + GRANTs
-- ============================================================================

create or replace function public.pricing_proposal_duplicate(p_proposta_id uuid, p_motivo text default null)
returns public.propostas_comerciais
language sql
as $$
  select app.duplicar_proposta(p_proposta_id, p_motivo);
$$;

create or replace function public.pricing_proposal_new_version(p_proposta_id uuid, p_motivo text default null)
returns public.propostas_comerciais
language sql
as $$
  select app.criar_versao_proposta(p_proposta_id, p_motivo);
$$;

create or replace function public.pricing_proposal_approve(p_proposta_id uuid, p_motivo text default null)
returns public.propostas_comerciais
language sql
as $$
  select app.aprovar_proposta(p_proposta_id, p_motivo);
$$;

create or replace function public.pricing_proposal_reject(p_proposta_id uuid, p_motivo text)
returns public.propostas_comerciais
language sql
as $$
  select app.rejeitar_proposta(p_proposta_id, p_motivo);
$$;

create or replace function public.pricing_proposal_change_status(p_proposta_id uuid, p_novo_status text, p_motivo text default null)
returns public.propostas_comerciais
language sql
as $$
  select app.mudar_status_proposta(p_proposta_id, p_novo_status, p_motivo);
$$;

create or replace function public.pricing_proposal_register_export(p_proposta_id uuid, p_formato text, p_versao_rotulo text default null)
returns void
language sql
as $$
  select app.registrar_exportacao_proposta(p_proposta_id, p_formato, p_versao_rotulo);
$$;

-- ============================================================================
-- 10) app.enriquecer_proposta — monta o jsonb completo de UMA proposta (join
--     com cidade/parceiro/usuários) reaproveitado por list/detail/versions/
--     view externa, pra nunca repetir a lógica de join em 4 lugares.
-- ============================================================================

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
    'prazo_meses', (select s.prazo_meses from public.simulacoes s where s.id = p.simulacao_id)
  );
$$;
comment on function app.enriquecer_proposta(public.propostas_comerciais) is 'Fase 2.4 — monta o jsonb enriquecido (join cidade/parceiro/usuários) de uma proposta. Reaproveitado por pricing_proposals_list/get_by_id/versions/external_view.';

-- ============================================================================
-- 11) pricing_proposal_versions — histórico de versões, já enriquecido.
-- ============================================================================

drop function if exists public.pricing_proposal_versions(uuid);

create or replace function public.pricing_proposal_versions(p_proposta_id uuid)
returns setof jsonb
language sql
stable
security invoker
as $$
  select app.enriquecer_proposta(pc) from public.propostas_comerciais pc
  where pc.proposta_raiz_id = (select coalesce(proposta_raiz_id, id) from public.propostas_comerciais where id = p_proposta_id)
  order by pc.numero_versao asc;
$$;
comment on function public.pricing_proposal_versions(uuid) is 'GET /api/proposals/:id/versions — Fase 2.4 seção 40: histórico completo de versões da mesma família (proposta_raiz_id), enriquecido.';

-- ============================================================================
-- 12) pricing_proposals_list — filtros adicionais (status, parceiro) +
--     opção de só a última versão de cada família (tela de lista, seção 6),
--     agora enriquecido (cidade_nome/parceiro_nome direto na lista).
--     Assinatura muda (2 params novos) — precisa DROP antes; tipo de retorno
--     também muda (setof public.propostas_comerciais → setof jsonb) — DROP
--     cobre os dois casos.
-- ============================================================================

drop function if exists public.pricing_proposals_list(uuid, uuid);
drop function if exists public.pricing_proposals_list(uuid, uuid, text, uuid, boolean);

create or replace function public.pricing_proposals_list(
  p_contrato_id uuid default null,
  p_cidade_id uuid default null,
  p_status text default null,
  p_parceiro_id uuid default null,
  p_somente_ultima_versao boolean default true
)
returns setof jsonb
language sql
stable
security invoker
as $$
  select app.enriquecer_proposta(pc) from public.propostas_comerciais pc
  where (p_contrato_id is null or pc.contrato_id = p_contrato_id)
    and (p_cidade_id is null or pc.cidade_id = p_cidade_id)
    and (p_status is null or pc.status = p_status)
    and (p_parceiro_id is null or pc.parceiro_id = p_parceiro_id)
    and (
      not p_somente_ultima_versao
      or pc.numero_versao = (
        select max(pc2.numero_versao) from public.propostas_comerciais pc2
        where pc2.proposta_raiz_id = coalesce(pc.proposta_raiz_id, pc.id)
      )
    )
  order by pc.criado_em desc;
$$;
comment on function public.pricing_proposals_list(uuid, uuid, text, uuid, boolean) is 'GET /api/proposals — lista de propostas (Fase 2.2.1 seção 31 + Fase 2.4 seção 6), enriquecida. Por padrão só mostra a última versão de cada família (proposta_raiz_id); p_somente_ultima_versao=false mostra todas.';

grant execute on function public.pricing_proposals_list(uuid, uuid, text, uuid, boolean) to authenticated;

-- ============================================================================
-- 13) pricing_proposal_get_by_id — GET /api/proposals/:id (tela de detalhe,
--     seção 6/28 seções do documento), enriquecido — não existia antes da
--     Fase 2.4.
-- ============================================================================

drop function if exists public.pricing_proposal_get_by_id(uuid);

create or replace function public.pricing_proposal_get_by_id(p_proposta_id uuid)
returns jsonb
language sql
stable
security invoker
as $$
  select app.enriquecer_proposta(pc) from public.propostas_comerciais pc where pc.id = p_proposta_id;
$$;
comment on function public.pricing_proposal_get_by_id(uuid) is 'GET /api/proposals/:id — Fase 2.4 seção 6/28: detalhe completo de uma proposta (documento de 28 seções é montado no frontend a partir do snapshot + colunas desta linha), enriquecido.';

grant execute on function public.pricing_proposal_get_by_id(uuid) to authenticated;

-- ============================================================================
-- 14) pricing_proposal_external_view — GET /api/proposals/:id/public (prep,
--     seção 46). NUNCA inclui piso/abertura/desconto/limite de desconto/
--     preço mínimo autorizado/governance_status/dados de autorização interna
--     — filtragem feita aqui no banco (nunca só no frontend) porque esta é
--     literalmente a fronteira "dado que o parceiro não pode ver" (mesmo
--     princípio de "backend nunca confia em frontend", aplicado ao sentido
--     inverso: o backend nunca DEIXA o frontend decidir o que esconder de
--     dado sensível). security invoker: select policy já é `true` pra todo
--     authenticated — quando esta rota virar de fato pública (fora da Fase
--     2.4, "prep" apenas), o acesso via link/token é decidido na camada API.
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
    'prazo_meses', s.prazo_meses
  )
  from public.propostas_comerciais pc
  left join public.cidades_infra c on c.id = pc.cidade_id
  left join public.parceiros pa on pa.id = pc.parceiro_id
  left join public.simulacoes s on s.id = pc.simulacao_id
  where pc.id = p_proposta_id;
$$;
comment on function public.pricing_proposal_external_view(uuid) is 'GET /api/proposals/:id/public — Fase 2.4 seção 46 (prep). Whitelist explícita de campos — NUNCA floor/opening/discount/max_override_discount_percent/preco_minimo_autorizado/governance_status/autorizado_por/motivo_autorizacao (dados internos de governança/margem).';

grant execute on function public.pricing_proposal_external_view(uuid) to authenticated;

grant execute on function public.pricing_proposal_duplicate(uuid, text) to authenticated;
grant execute on function public.pricing_proposal_new_version(uuid, text) to authenticated;
grant execute on function public.pricing_proposal_approve(uuid, text) to authenticated;
grant execute on function public.pricing_proposal_reject(uuid, text) to authenticated;
grant execute on function public.pricing_proposal_change_status(uuid, text, text) to authenticated;
grant execute on function public.pricing_proposal_register_export(uuid, text, text) to authenticated;
grant execute on function public.pricing_proposal_versions(uuid) to authenticated;
