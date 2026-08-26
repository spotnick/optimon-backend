-- OptiMon — Fase 2.3.1: CRUD completo de infraestrutura.
-- Migration 2/4: ARQUIVAR/RESTAURAR para POP, segmento, cabo, poste e porta PON
-- (seções 8-17). Cada arquivamento checa dependências reais antes de bloquear — nunca
-- bloqueia só pela existência de infraestrutura "abaixo", só por infraestrutura EM USO
-- (mesmo raciocínio já documentado para cidade na Fase 2.3: bloquear por mera existência
-- tornaria o arquivamento inútil para qualquer registro real).
--
-- Poste é a única exceção deliberada: não existe nenhuma dependência estrutural real de
-- poste para outra tabela de infraestrutura (só custos_infraestrutura.poste_id, com
-- ON DELETE SET NULL — não é um vínculo operacional que impeça arquivamento), então
-- arquivar poste nunca bloqueia — "manter o modelo existente" (seção 15 do prompt).
--
-- Porta PON não tem coluna removido_em (nunca teve, desde a Fase 1.1) — seu ciclo de
-- vida já é modelado pela coluna status (ATIVA/INATIVA/MANUTENCAO, criada na Fase 1.1).
-- Em vez de duplicar o conceito com uma segunda coluna, "arquivar PON" = status para
-- INATIVA (bloqueado se houver cliente ativo, seção 17) e "restaurar" = status de volta
-- para ATIVA — nenhuma tabela/coluna nova, só reaproveita o que já existe.

-- ============================================================================
-- POP (seções 8-10)
-- ============================================================================

create or replace function app.arquivar_pop(p_pop_id uuid, p_motivo text default null, p_observacao text default null)
returns void
language plpgsql
security invoker
as $$
declare
  v_cabos integer;
  v_pons_ativas integer;
begin
  if not app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode arquivar POPs — só ENGENHARIA ou ADMINISTRADOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.infra_pops where id = p_pop_id and removido_em is null) then
    raise exception 'POP % não encontrado (ou já arquivado).', p_pop_id;
  end if;

  select count(*) into v_cabos from public.infra_cabos where pop_id = p_pop_id and removido_em is null;
  select count(*) into v_pons_ativas from public.infra_portas_pon where pop_id = p_pop_id and status <> 'INATIVA';

  if v_cabos > 0 or v_pons_ativas > 0 then
    raise exception 'Este POP possui % cabo(s) e % Porta(s) PON ativa(s) — arquive ou desative essas dependências antes.', v_cabos, v_pons_ativas;
  end if;

  update public.infra_pops set removido_em = now() where id = p_pop_id;

  perform app.registrar_auditoria_semantica(
    'infra_pops', p_pop_id, 'ARCHIVE',
    coalesce(p_motivo, 'Não informado') || coalesce(': ' || nullif(btrim(p_observacao), ''), '')
  );
end;
$$;
comment on function app.arquivar_pop(uuid, text, text) is 'Fase 2.3.1 (seção 10): bloqueia se houver cabo não arquivado ou Porta PON não INATIVA vinculados a este POP.';

-- SECURITY DEFINER (bug real encontrado em teste, mesmo caso já corrigido em
-- app.restaurar_cidade na migration anterior — ver o comentário longo lá): esta função,
-- como as outras 4 app.restaurar_* abaixo, é a autorização em si (checa
-- app.tem_perfil('ADMINISTRADOR', 'DIRETOR') sozinha, sem depender de RLS de tabela) — mas
-- rodando como SECURITY INVOKER o UPDATE que segue ainda ficava sujeito à policy de
-- escrita da tabela (ex.: "infra_pops_write"), que só inclui ENGENHARIA/ADMINISTRADOR.
-- Para ADMINISTRADOR isso por acaso batia e mascarava o bug; para DIRETOR o UPDATE
-- silenciosamente afetava 0 linhas (RLS filtra linhas, não lança erro), removido_em nunca
-- voltava a null, e mesmo assim a auditoria RESTORE era gravada e a API respondia 200 —
-- só percebido consultando o estado real da linha no banco após um "restaurar" bem
-- sucedido segundo o teste. Corrigido igual à cidade: SECURITY DEFINER (dono
-- optimon_admin, que não sofre RLS por ser dono das tabelas) + search_path fixo.
create or replace function app.restaurar_pop(p_pop_id uuid, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tem_perfil('ADMINISTRADOR', 'DIRETOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode restaurar POPs — só ADMINISTRADOR ou DIRETOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.infra_pops where id = p_pop_id and removido_em is not null) then
    raise exception 'POP % não encontrado entre os arquivados.', p_pop_id;
  end if;

  update public.infra_pops set removido_em = null where id = p_pop_id;
  perform app.registrar_auditoria_semantica('infra_pops', p_pop_id, 'RESTORE', p_motivo);
end;
$$;
comment on function app.restaurar_pop(uuid, text) is 'Fase 2.3.1 (seção 21): só ADMINISTRADOR/DIRETOR. SECURITY DEFINER (bug real corrigido em teste — ver comentário acima e em app.restaurar_cidade): DIRETOR não está na policy de escrita de infra_pops.';

-- ============================================================================
-- SEGMENTO (seção 11)
-- ============================================================================

create or replace function app.arquivar_segmento(p_segmento_id uuid, p_motivo text default null, p_observacao text default null)
returns void
language plpgsql
security invoker
as $$
declare
  v_cabos integer;
  v_postes integer;
begin
  if not app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode arquivar segmentos — só ENGENHARIA ou ADMINISTRADOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.infra_segmentos where id = p_segmento_id and removido_em is null) then
    raise exception 'Segmento % não encontrado (ou já arquivado).', p_segmento_id;
  end if;

  select count(*) into v_cabos from public.infra_cabos where segmento_id = p_segmento_id and removido_em is null;
  select count(*) into v_postes from public.infra_postes where segmento_id = p_segmento_id and removido_em is null;

  if v_cabos > 0 or v_postes > 0 then
    raise exception 'Este segmento possui % cabo(s) e % lote(s) de poste(s) ativos — arquive-os antes.', v_cabos, v_postes;
  end if;

  update public.infra_segmentos set removido_em = now() where id = p_segmento_id;
  perform app.registrar_auditoria_semantica(
    'infra_segmentos', p_segmento_id, 'ARCHIVE',
    coalesce(p_motivo, 'Não informado') || coalesce(': ' || nullif(btrim(p_observacao), ''), '')
  );
end;
$$;
comment on function app.arquivar_segmento(uuid, text, text) is 'Fase 2.3.1 (seção 11): bloqueia se houver cabo ou poste não arquivados vinculados a este segmento.';

-- SECURITY DEFINER: mesmo bug real e mesma correção de app.restaurar_pop/app.restaurar_cidade
-- acima (DIRETOR não está na policy de escrita de infra_segmentos, então como SECURITY
-- INVOKER o UPDATE silenciosamente afetava 0 linhas para DIRETOR).
create or replace function app.restaurar_segmento(p_segmento_id uuid, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tem_perfil('ADMINISTRADOR', 'DIRETOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode restaurar segmentos — só ADMINISTRADOR ou DIRETOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.infra_segmentos where id = p_segmento_id and removido_em is not null) then
    raise exception 'Segmento % não encontrado entre os arquivados.', p_segmento_id;
  end if;

  update public.infra_segmentos set removido_em = null where id = p_segmento_id;
  perform app.registrar_auditoria_semantica('infra_segmentos', p_segmento_id, 'RESTORE', p_motivo);
end;
$$;
comment on function app.restaurar_segmento(uuid, text) is 'Fase 2.3.1 (seção 21): só ADMINISTRADOR/DIRETOR. SECURITY DEFINER (bug real corrigido em teste — ver comentário em app.restaurar_pop/app.restaurar_cidade).';

-- ============================================================================
-- CABO (seções 12-13) — bloqueia por fibra OCUPADA/LOCADA, fibra associada a Porta PON,
-- ou fibra vinculada a contrato ativo (contrato_fibras.desvinculado_em is null) — a
-- leitura literal da lista da seção 13 ("fibras ocupadas, locadas, associadas a PON,
-- contratos, clientes, serviços ativos"), sem bloquear por fibra RESERVADA/MANUTENCAO/
-- BLOQUEADA isoladamente (esses estados não implicam uso comercial ativo por si só).
-- ============================================================================

create or replace function app.arquivar_cabo(p_cabo_id uuid, p_motivo text default null, p_observacao text default null)
returns void
language plpgsql
security invoker
as $$
declare
  v_fibras_em_uso integer;
  v_pons integer;
  v_contratos integer;
begin
  if not app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode arquivar cabos — só ENGENHARIA ou ADMINISTRADOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.infra_cabos where id = p_cabo_id and removido_em is null) then
    raise exception 'Cabo % não encontrado (ou já arquivado).', p_cabo_id;
  end if;

  select count(*) into v_fibras_em_uso from public.infra_fibras where cabo_id = p_cabo_id and status in ('OCUPADA', 'LOCADA');
  -- pp.status <> 'INATIVA': uma Porta PON já arquivada não é mais um vínculo ATIVO (seção
  -- 13 fala em "associada a PON ... ativos") — sem esse filtro, um cabo cuja única Porta
  -- PON já foi arquivada ficaria bloqueado para sempre, o que tornaria o arquivamento do
  -- cabo impossível mesmo depois de tratada a dependência (achado real ao testar a seção
  -- 39: arquivar a Porta PON e depois tentar arquivar o cabo continuava bloqueando).
  select count(*) into v_pons from public.infra_portas_pon pp join public.infra_fibras f on f.id = pp.fibra_id where f.cabo_id = p_cabo_id and pp.status <> 'INATIVA';
  select count(*) into v_contratos from public.contrato_fibras cf join public.infra_fibras f on f.id = cf.fibra_id where f.cabo_id = p_cabo_id and cf.desvinculado_em is null;

  if v_fibras_em_uso > 0 or v_pons > 0 or v_contratos > 0 then
    raise exception 'Este cabo possui % fibra(s) ocupada(s)/locada(s), % Porta(s) PON e % vínculo(s) de contrato ativos — trate essas dependências antes.', v_fibras_em_uso, v_pons, v_contratos;
  end if;

  update public.infra_cabos set removido_em = now() where id = p_cabo_id;
  perform app.registrar_auditoria_semantica(
    'infra_cabos', p_cabo_id, 'ARCHIVE',
    coalesce(p_motivo, 'Não informado') || coalesce(': ' || nullif(btrim(p_observacao), ''), '')
  );
end;
$$;
comment on function app.arquivar_cabo(uuid, text, text) is 'Fase 2.3.1 (seção 13): bloqueia por fibra OCUPADA/LOCADA, fibra associada a Porta PON, ou fibra com vínculo de contrato ativo.';

-- SECURITY DEFINER: mesmo bug real e mesma correção de app.restaurar_pop/app.restaurar_cidade
-- acima (DIRETOR não está na policy de escrita de infra_cabos, então como SECURITY
-- INVOKER o UPDATE silenciosamente afetava 0 linhas para DIRETOR).
create or replace function app.restaurar_cabo(p_cabo_id uuid, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tem_perfil('ADMINISTRADOR', 'DIRETOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode restaurar cabos — só ADMINISTRADOR ou DIRETOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.infra_cabos where id = p_cabo_id and removido_em is not null) then
    raise exception 'Cabo % não encontrado entre os arquivados.', p_cabo_id;
  end if;

  update public.infra_cabos set removido_em = null where id = p_cabo_id;
  perform app.registrar_auditoria_semantica('infra_cabos', p_cabo_id, 'RESTORE', p_motivo);
end;
$$;
comment on function app.restaurar_cabo(uuid, text) is 'Fase 2.3.1 (seção 21): só ADMINISTRADOR/DIRETOR. Nunca restaura a fibra física — a fibra em si nunca é arquivada isoladamente (seção 14), só o cabo inteiro. SECURITY DEFINER (bug real corrigido em teste — ver comentário em app.restaurar_pop/app.restaurar_cidade).';

-- ============================================================================
-- POSTE (seção 15) — nunca bloqueia (sem dependência estrutural real de outra tabela de
-- infraestrutura; "manter o modelo existente" — seção 15 literal).
-- ============================================================================

create or replace function app.arquivar_poste(p_poste_id uuid, p_motivo text default null, p_observacao text default null)
returns void
language plpgsql
security invoker
as $$
begin
  if not app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode arquivar postes — só ENGENHARIA ou ADMINISTRADOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.infra_postes where id = p_poste_id and removido_em is null) then
    raise exception 'Lote de postes % não encontrado (ou já arquivado).', p_poste_id;
  end if;

  update public.infra_postes set removido_em = now() where id = p_poste_id;
  perform app.registrar_auditoria_semantica(
    'infra_postes', p_poste_id, 'ARCHIVE',
    coalesce(p_motivo, 'Não informado') || coalesce(': ' || nullif(btrim(p_observacao), ''), '')
  );
end;
$$;
comment on function app.arquivar_poste(uuid, text, text) is 'Fase 2.3.1 (seção 15): sem checagem de dependência — postes não têm vínculo estrutural com outra tabela de infraestrutura no modelo atual.';

-- SECURITY DEFINER: mesmo bug real e mesma correção de app.restaurar_pop/app.restaurar_cidade
-- acima (DIRETOR não está na policy de escrita de infra_postes, então como SECURITY
-- INVOKER o UPDATE silenciosamente afetava 0 linhas para DIRETOR).
create or replace function app.restaurar_poste(p_poste_id uuid, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tem_perfil('ADMINISTRADOR', 'DIRETOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode restaurar postes — só ADMINISTRADOR ou DIRETOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.infra_postes where id = p_poste_id and removido_em is not null) then
    raise exception 'Lote de postes % não encontrado entre os arquivados.', p_poste_id;
  end if;

  update public.infra_postes set removido_em = null where id = p_poste_id;
  perform app.registrar_auditoria_semantica('infra_postes', p_poste_id, 'RESTORE', p_motivo);
end;
$$;
comment on function app.restaurar_poste(uuid, text) is 'Fase 2.3.1 (seção 21): só ADMINISTRADOR/DIRETOR. SECURITY DEFINER (bug real corrigido em teste — ver comentário em app.restaurar_pop/app.restaurar_cidade).';

-- ============================================================================
-- PORTA PON (seções 16-17) — sem coluna removido_em própria (nunca existiu). "Arquivar"
-- reaproveita a coluna status (ATIVA/INATIVA/MANUTENCAO, existente desde a Fase 1.1):
-- arquivar = status para INATIVA (bloqueado com cliente ativo); restaurar = de volta a
-- ATIVA. Nenhuma coluna nova.
-- ============================================================================

create or replace function app.arquivar_porta_pon(p_porta_id uuid, p_motivo text default null, p_observacao text default null)
returns void
language plpgsql
security invoker
as $$
declare
  v_clientes integer;
begin
  if not app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode arquivar Portas PON — só ENGENHARIA ou ADMINISTRADOR.', app.perfil_atual();
  end if;

  select capacidade_utilizada_assinantes into v_clientes from public.infra_portas_pon where id = p_porta_id;
  if not found then
    raise exception 'Porta PON % não encontrada.', p_porta_id;
  end if;

  if v_clientes > 0 then
    raise exception 'PON possui clientes ativos e não pode ser arquivada.';
  end if;

  update public.infra_portas_pon set status = 'INATIVA' where id = p_porta_id;
  perform app.registrar_auditoria_semantica(
    'infra_portas_pon', p_porta_id, 'ARCHIVE',
    coalesce(p_motivo, 'Não informado') || coalesce(': ' || nullif(btrim(p_observacao), ''), '')
  );
end;
$$;
comment on function app.arquivar_porta_pon(uuid, text, text) is 'Fase 2.3.1 (seção 17): bloqueia com a mensagem literal do prompt quando há cliente ativo (capacidade_utilizada_assinantes > 0). "Arquivar" = status → INATIVA (sem coluna removido_em própria).';

-- SECURITY DEFINER: mesmo bug real e mesma correção de app.restaurar_pop/app.restaurar_cidade
-- acima (DIRETOR não está na policy de escrita de infra_portas_pon, então como SECURITY
-- INVOKER o UPDATE silenciosamente afetava 0 linhas para DIRETOR — aqui o sintoma seria
-- status continuar INATIVA mesmo com a API respondendo 200 e a auditoria RESTORE gravada).
create or replace function app.restaurar_porta_pon(p_porta_id uuid, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tem_perfil('ADMINISTRADOR', 'DIRETOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode restaurar Portas PON — só ADMINISTRADOR ou DIRETOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.infra_portas_pon where id = p_porta_id and status = 'INATIVA') then
    raise exception 'Porta PON % não encontrada entre as arquivadas (INATIVA).', p_porta_id;
  end if;

  update public.infra_portas_pon set status = 'ATIVA' where id = p_porta_id;
  perform app.registrar_auditoria_semantica('infra_portas_pon', p_porta_id, 'RESTORE', p_motivo);
end;
$$;
comment on function app.restaurar_porta_pon(uuid, text) is 'Fase 2.3.1 (seção 21): só ADMINISTRADOR/DIRETOR. status INATIVA → ATIVA. SECURITY DEFINER (bug real corrigido em teste — ver comentário em app.restaurar_pop/app.restaurar_cidade).';

-- ============================================================================
-- Wrappers públicos SECURITY INVOKER — mesmo padrão de sempre.
-- ============================================================================

create or replace function public.pricing_pop_archive(p_pop_id uuid, p_motivo text default null, p_observacao text default null)
returns void language sql security invoker as $$ select app.arquivar_pop(p_pop_id, p_motivo, p_observacao); $$;
create or replace function public.pricing_pop_restore(p_pop_id uuid, p_motivo text default null)
returns void language sql security invoker as $$ select app.restaurar_pop(p_pop_id, p_motivo); $$;

create or replace function public.pricing_segment_archive(p_segmento_id uuid, p_motivo text default null, p_observacao text default null)
returns void language sql security invoker as $$ select app.arquivar_segmento(p_segmento_id, p_motivo, p_observacao); $$;
create or replace function public.pricing_segment_restore(p_segmento_id uuid, p_motivo text default null)
returns void language sql security invoker as $$ select app.restaurar_segmento(p_segmento_id, p_motivo); $$;

create or replace function public.pricing_cable_archive(p_cabo_id uuid, p_motivo text default null, p_observacao text default null)
returns void language sql security invoker as $$ select app.arquivar_cabo(p_cabo_id, p_motivo, p_observacao); $$;
create or replace function public.pricing_cable_restore(p_cabo_id uuid, p_motivo text default null)
returns void language sql security invoker as $$ select app.restaurar_cabo(p_cabo_id, p_motivo); $$;

create or replace function public.pricing_pole_archive(p_poste_id uuid, p_motivo text default null, p_observacao text default null)
returns void language sql security invoker as $$ select app.arquivar_poste(p_poste_id, p_motivo, p_observacao); $$;
create or replace function public.pricing_pole_restore(p_poste_id uuid, p_motivo text default null)
returns void language sql security invoker as $$ select app.restaurar_poste(p_poste_id, p_motivo); $$;

create or replace function public.pricing_pon_port_archive(p_porta_id uuid, p_motivo text default null, p_observacao text default null)
returns void language sql security invoker as $$ select app.arquivar_porta_pon(p_porta_id, p_motivo, p_observacao); $$;
create or replace function public.pricing_pon_port_restore(p_porta_id uuid, p_motivo text default null)
returns void language sql security invoker as $$ select app.restaurar_porta_pon(p_porta_id, p_motivo); $$;

grant execute on function
  public.pricing_pop_archive(uuid, text, text), public.pricing_pop_restore(uuid, text),
  public.pricing_segment_archive(uuid, text, text), public.pricing_segment_restore(uuid, text),
  public.pricing_cable_archive(uuid, text, text), public.pricing_cable_restore(uuid, text),
  public.pricing_pole_archive(uuid, text, text), public.pricing_pole_restore(uuid, text),
  public.pricing_pon_port_archive(uuid, text, text), public.pricing_pon_port_restore(uuid, text)
to authenticated;

-- GRANT explícito de EXECUTE nas 5 app.restaurar_* agora SECURITY DEFINER acima — mesmo
-- raciocínio do GRANT já feito para app.registrar_auditoria_semantica/app.restaurar_cidade
-- (migration anterior): nunca houve um REVOKE global nesta base, então EXECUTE para
-- authenticated já valia por padrão do Postgres (GRANT a PUBLIC na criação) — este GRANT
-- aqui é só defesa em profundidade, deixando explícito que authenticated PRECISA poder
-- chamar estas 5 funções (via public.pricing_*_restore, SECURITY INVOKER, que preserva
-- app.tem_perfil() avaliado como o usuário real na entrada de cada uma).
grant execute on function
  app.restaurar_pop(uuid, text),
  app.restaurar_segmento(uuid, text),
  app.restaurar_cabo(uuid, text),
  app.restaurar_poste(uuid, text),
  app.restaurar_porta_pon(uuid, text)
to authenticated;
