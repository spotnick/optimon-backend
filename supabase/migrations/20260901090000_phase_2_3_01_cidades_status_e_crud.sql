-- OptiMon — Fase 2.3: Módulo de Gestão de Cidades e Infraestrutura
-- Migration 1/3: status da cidade (ATIVA/INATIVA/PLANEJADA) + CRUD real de cidade
-- (criar/atualizar/arquivar), substituindo a tela hard-coded de Jussara por um fluxo
-- genérico por cidade_id (seções 3, 8, 10, 11 do prompt desta fase).
--
-- public.cidades_infra já existe desde a Fase 1 — NÃO recriada. Esta migration só
-- adiciona a coluna de status (nunca existiu) e wrappers incrementais para o que o
-- frontend precisa fazer que hoje só é possível manualmente via SQL Editor.

-- ============================================================================
-- 1) STATUS DA CIDADE (seção 8) — ATIVA/INATIVA/PLANEJADA. Distinto de removido_em:
--    status é o ciclo de vida comercial/operacional; removido_em é arquivamento (seção 10).
-- ============================================================================

alter table public.cidades_infra
  add column if not exists status text not null default 'ATIVA'
    check (status in ('ATIVA', 'INATIVA', 'PLANEJADA'));

comment on column public.cidades_infra.status is 'Fase 2.3 (seção 8): ciclo de vida comercial da cidade. Independente de removido_em — uma cidade PLANEJADA/INATIVA continua visível e editável; só o arquivamento (removido_em) a esconde da listagem padrão.';

-- ============================================================================
-- 2) app.criar_cidade — INSERT validado. RLS (cidades_infra_write, já existente desde a
--    Fase 1.1) já restringe a ENGENHARIA/ADMINISTRADOR; a checagem explícita aqui só
--    troca a mensagem genérica de RLS ("new row violates row-level security policy") por
--    um erro claro que a API consegue mapear para 403 (seção 9).
-- ============================================================================

create or replace function app.criar_cidade(
  p_nome text,
  p_uf char(2),
  p_km_rede numeric,
  p_codigo_ibge text default null,
  p_endereco text default null,
  p_observacoes text default null,
  p_status text default 'ATIVA'
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_id uuid;
begin
  if not app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode cadastrar cidades — só ENGENHARIA ou ADMINISTRADOR.', app.perfil_atual();
  end if;

  -- seção 8: "Não permitir cidade sem: nome, UF, KM de rede". nome/uf já são NOT NULL na
  -- tabela; km_rede tem DEFAULT 0 (histórico da Fase 1, não quebrar), então esta fase
  -- exige explicitamente um valor informado e positivo aqui, sem alterar a coluna.
  if p_nome is null or btrim(p_nome) = '' then
    raise exception 'Nome da cidade é obrigatório.';
  end if;
  if p_uf is null or length(btrim(p_uf)) <> 2 then
    raise exception 'UF é obrigatória e deve ter 2 letras.';
  end if;
  if p_km_rede is null or p_km_rede <= 0 then
    raise exception 'KM de rede é obrigatório e deve ser maior que zero.';
  end if;
  if p_status not in ('ATIVA', 'INATIVA', 'PLANEJADA') then
    raise exception 'Status inválido: % (use ATIVA, INATIVA ou PLANEJADA).', p_status;
  end if;

  insert into public.cidades_infra (nome, uf, codigo_ibge, endereco, km_rede, observacoes, status)
  values (btrim(p_nome), upper(btrim(p_uf)), nullif(btrim(p_codigo_ibge), ''), p_endereco, p_km_rede, p_observacoes, p_status)
  returning id into v_id;

  return v_id;
end;
$$;
comment on function app.criar_cidade(text, char, numeric, text, text, text, text) is 'Fase 2.3 (seção 8/11): POST /api/cities. Valida nome/UF/km_rede, insere em cidades_infra (RLS já restringe a ENGENHARIA/ADMINISTRADOR). Nunca cria POP/infra — isso é um passo separado do fluxo (seção 22).';

-- ============================================================================
-- 3) app.atualizar_cidade — UPDATE parcial (semântica PATCH: parâmetro null = não
--    altera aquele campo). RLS (cidades_infra_update) já restringe a ENGENHARIA/ADMIN.
-- ============================================================================

create or replace function app.atualizar_cidade(
  p_cidade_id uuid,
  p_nome text default null,
  p_uf char(2) default null,
  p_codigo_ibge text default null,
  p_endereco text default null,
  p_km_rede numeric default null,
  p_observacoes text default null,
  p_status text default null
)
returns void
language plpgsql
security invoker
as $$
begin
  if not app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode editar cidades — só ENGENHARIA ou ADMINISTRADOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.cidades_infra where id = p_cidade_id and removido_em is null) then
    raise exception 'Cidade % não encontrada.', p_cidade_id;
  end if;

  if p_nome is not null and btrim(p_nome) = '' then
    raise exception 'Nome da cidade não pode ficar vazio.';
  end if;
  if p_uf is not null and length(btrim(p_uf)) <> 2 then
    raise exception 'UF deve ter 2 letras.';
  end if;
  if p_km_rede is not null and p_km_rede <= 0 then
    raise exception 'KM de rede deve ser maior que zero.';
  end if;
  if p_status is not null and p_status not in ('ATIVA', 'INATIVA', 'PLANEJADA') then
    raise exception 'Status inválido: % (use ATIVA, INATIVA ou PLANEJADA).', p_status;
  end if;

  update public.cidades_infra set
    nome = coalesce(btrim(p_nome), nome),
    uf = coalesce(upper(btrim(p_uf)), uf),
    codigo_ibge = case when p_codigo_ibge is not null then nullif(btrim(p_codigo_ibge), '') else codigo_ibge end,
    endereco = coalesce(p_endereco, endereco),
    km_rede = coalesce(p_km_rede, km_rede),
    observacoes = coalesce(p_observacoes, observacoes),
    status = coalesce(p_status, status)
  where id = p_cidade_id;
end;
$$;
comment on function app.atualizar_cidade(uuid, text, char, text, text, numeric, text, text) is 'Fase 2.3 (seção 11): PATCH /api/cities/:id. Semântica parcial — parâmetro omitido/null preserva o valor atual. Usado tanto pelo formulário "Editar Cidade" quanto pelo botão "Editar Infraestrutura" quando ele mexe em campos da própria cidade (ex.: km_rede).';

-- ============================================================================
-- 4) app.arquivar_cidade — nunca DELETE físico (seção 10). Marca removido_em; bloqueia
--    se houver contrato ATIVO na cidade (seções 10, 31, 32, 41). A checagem é
--    deliberadamente sobre CONTRATO ativo, não sobre a mera existência de POP/cabo/
--    fibra/poste/PON — toda cidade com infraestrutura cadastrada teria essas linhas por
--    definição, e bloquear nesse caso tornaria o arquivamento inútil para qualquer cidade
--    real. O que a seção 10 realmente protege é o compromisso comercial em andamento
--    (contrato), que é também exatamente o que as seções 31/32/41 testam.
-- ============================================================================

create or replace function app.arquivar_cidade(p_cidade_id uuid)
returns void
language plpgsql
security invoker
as $$
declare
  v_contratos_ativos integer;
begin
  if not app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode arquivar cidades — só ENGENHARIA ou ADMINISTRADOR.', app.perfil_atual();
  end if;

  if not exists (select 1 from public.cidades_infra where id = p_cidade_id and removido_em is null) then
    raise exception 'Cidade % não encontrada (ou já arquivada).', p_cidade_id;
  end if;

  select count(*) into v_contratos_ativos
  from public.contratos
  where cidade_id = p_cidade_id and status = 'ATIVO';

  if v_contratos_ativos > 0 then
    raise exception 'Não é possível arquivar uma cidade com contrato ativo.';
  end if;

  update public.cidades_infra set removido_em = now() where id = p_cidade_id;
end;
$$;
comment on function app.arquivar_cidade(uuid) is 'Fase 2.3 (seção 10/31/32): POST /api/cities/:id/archive. Nunca DELETE físico. Bloqueia com contrato ATIVO na cidade — mensagem literal "Não é possível arquivar uma cidade com contrato ativo." (seção 32).';

-- ============================================================================
-- 5) Wrappers públicos SECURITY INVOKER — a API só chama estes, nunca app.* diretamente
--    (mesmo padrão de public.pricing_* usado em todas as fases anteriores).
-- ============================================================================

create or replace function public.pricing_city_create(
  p_nome text, p_uf char(2), p_km_rede numeric, p_codigo_ibge text default null,
  p_endereco text default null, p_observacoes text default null, p_status text default 'ATIVA'
)
returns uuid
language sql
security invoker
as $$
  select app.criar_cidade(p_nome, p_uf, p_km_rede, p_codigo_ibge, p_endereco, p_observacoes, p_status);
$$;
comment on function public.pricing_city_create(text, char, numeric, text, text, text, text) is 'POST /api/cities (seção 11).';

create or replace function public.pricing_city_update(
  p_cidade_id uuid, p_nome text default null, p_uf char(2) default null, p_codigo_ibge text default null,
  p_endereco text default null, p_km_rede numeric default null, p_observacoes text default null, p_status text default null
)
returns void
language sql
security invoker
as $$
  select app.atualizar_cidade(p_cidade_id, p_nome, p_uf, p_codigo_ibge, p_endereco, p_km_rede, p_observacoes, p_status);
$$;
comment on function public.pricing_city_update(uuid, text, char, text, text, numeric, text, text) is 'PATCH /api/cities/:id (seção 11).';

create or replace function public.pricing_city_archive(p_cidade_id uuid)
returns void
language sql
security invoker
as $$
  select app.arquivar_cidade(p_cidade_id);
$$;
comment on function public.pricing_city_archive(uuid) is 'POST /api/cities/:id/archive (seção 11).';

grant execute on function
  public.pricing_city_create(text, char, numeric, text, text, text, text),
  public.pricing_city_update(uuid, text, char, text, text, numeric, text, text),
  public.pricing_city_archive(uuid)
to authenticated;
