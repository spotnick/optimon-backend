-- OptiMon — Fase 1.2
-- Seções 8, 9, 10: uma Fibra/Porta PON nunca pode estar EXCLUSIVA e COMPARTILHADA ao
-- mesmo tempo. Corrige uma lacuna real da Fase 1.1: o índice único parcial
-- contrato_fibras_porta_ativa_idx (Fase 1.1) só impede 2 vínculos com
-- compartilhamento_autorizado=false na mesma porta — mas nada impedia um vínculo
-- compartilhamento_autorizado=TRUE coexistir com outro compartilhamento_autorizado=FALSE
-- na mesma porta/fibra ao mesmo tempo (exatamente a falha descrita na seção 8). O trigger
-- abaixo fecha essa lacuna para qualquer forma de escrita, inclusive SQL direto.

create or replace function public.fn_valida_conflito_compartilhamento()
returns trigger
language plpgsql
as $$
declare
  v_recurso_coluna text;
  v_recurso_id uuid;
  v_tem_exclusiva boolean;
  v_tem_qualquer boolean;
begin
  -- Só valida vínculos ativos (desvinculado_em is null) — desvincular nunca é bloqueado.
  if new.desvinculado_em is not null then
    return new;
  end if;

  -- Porta PON é o recurso mais específico quando informado; na ausência dela (dark fiber
  -- pura, sem provisionamento PON), o recurso é a própria fibra.
  if new.porta_pon_id is not null then
    v_recurso_coluna := 'porta_pon_id';
    v_recurso_id := new.porta_pon_id;
  else
    v_recurso_coluna := 'fibra_id';
    v_recurso_id := new.fibra_id;
  end if;

  select
    bool_or(compartilhamento_autorizado = false),
    bool_or(true)
  into v_tem_exclusiva, v_tem_qualquer
  from public.contrato_fibras cf
  where cf.desvinculado_em is null
    and cf.id is distinct from new.id
    and (
      (v_recurso_coluna = 'porta_pon_id' and cf.porta_pon_id = v_recurso_id)
      or (v_recurso_coluna = 'fibra_id' and cf.fibra_id = v_recurso_id and cf.porta_pon_id is null)
    );

  if coalesce(v_tem_qualquer, false) then
    if v_tem_exclusiva then
      raise exception 'BLOCK: % % já possui vínculo EXCLUSIVO ativo — compartilhamento não é permitido simultaneamente (seção 8).', v_recurso_coluna, v_recurso_id;
    elsif new.compartilhamento_autorizado = false then
      raise exception 'BLOCK: % % já possui vínculo COMPARTILHADO ativo — não é possível vincular como EXCLUSIVO ao mesmo tempo (seção 8).', v_recurso_coluna, v_recurso_id;
    elsif not app.tem_perfil('DIRETOR', 'ADMINISTRADOR') then
      -- Ambos os vínculos (existente e novo) pedem compartilhamento=true — a ativação de
      -- compartilhamento sempre exige aprovação explícita de DIRETOR/ADMINISTRADOR
      -- (seção 9); ENGENHARIA pode solicitar via contrato_regras_solicitacoes, mas não
      -- aprovar diretamente com um INSERT/UPDATE em contrato_fibras.
      raise exception 'REQUIRES_APPROVAL: adicionar um vínculo compartilhado a % % já compartilhada exige aprovação de DIRETOR/ADMINISTRADOR (seção 9).', v_recurso_coluna, v_recurso_id;
    end if;
  elsif new.compartilhamento_autorizado = true and not app.tem_perfil('DIRETOR', 'ADMINISTRADOR') then
    -- Primeiro vínculo do recurso já nascendo compartilhado — mesma exigência de
    -- aprovação (compartilhamento_autorizado=false é o padrão desabilitado da seção 9;
    -- ativar TRUE em qualquer momento exige DIRETOR/ADMINISTRADOR).
    raise exception 'REQUIRES_APPROVAL: ativar compartilhamento_autorizado exige aprovação de DIRETOR/ADMINISTRADOR (seção 9).';
  end if;

  return new;
end;
$$;

comment on function public.fn_valida_conflito_compartilhamento() is 'Garante que uma fibra/porta PON nunca fique EXCLUSIVA e COMPARTILHADA ao mesmo tempo (seção 8), e que ativar compartilhamento_autorizado sempre exija DIRETOR/ADMINISTRADOR (seção 9) — reforço no banco, independente de RLS/backend.';

create trigger trg_valida_conflito_compartilhamento
  before insert or update on public.contrato_fibras
  for each row execute function public.fn_valida_conflito_compartilhamento();

-- app.check_resource_conflict() (seção 10): checagem PURA (não altera nada) que combina
-- a exclusividade territorial já existente (app.check_contract_conflict, Fase 1.1) com o
-- estado de compartilhamento do recurso físico (fibra/porta) — cobre os dois exemplos
-- literais da seção 10 (mesma porta exclusiva → BLOCK; portas diferentes no mesmo POP →
-- ALLOW) além dos cenários de exclusividade territorial já cobertos pela Fase 1.1.
-- BLOCK sempre vence REQUIRES_APPROVAL, que sempre vence ALLOW (mesma precedência usada
-- em check_contract_conflict).
create or replace function app.check_resource_conflict(
  p_cidade_id uuid,
  p_parceiro_id uuid,
  p_fibra_id uuid default null,
  p_porta_pon_id uuid default null,
  p_pop_id uuid default null,
  p_servico text default null
)
returns text
language plpgsql
stable
as $$
declare
  v_territorial text;
  v_recurso text := 'ALLOW';
  v_tem_exclusiva boolean;
  v_tem_compartilhada boolean;
begin
  v_territorial := app.check_contract_conflict(p_cidade_id, p_parceiro_id, p_pop_id, p_servico);

  if p_porta_pon_id is not null or p_fibra_id is not null then
    select
      bool_or(compartilhamento_autorizado = false),
      bool_or(compartilhamento_autorizado = true)
    into v_tem_exclusiva, v_tem_compartilhada
    from public.contrato_fibras cf
    where cf.desvinculado_em is null
      and (
        (p_porta_pon_id is not null and cf.porta_pon_id = p_porta_pon_id)
        or (p_porta_pon_id is null and cf.fibra_id = p_fibra_id and cf.porta_pon_id is null)
      );

    if v_tem_exclusiva then
      v_recurso := 'BLOCK';
    elsif v_tem_compartilhada then
      v_recurso := 'REQUIRES_APPROVAL';
    end if;
  end if;

  if v_territorial = 'BLOCK' or v_recurso = 'BLOCK' then
    return 'BLOCK';
  elsif v_territorial = 'REQUIRES_APPROVAL' or v_recurso = 'REQUIRES_APPROVAL' then
    return 'REQUIRES_APPROVAL';
  else
    return 'ALLOW';
  end if;
end;
$$;

comment on function app.check_resource_conflict(uuid, uuid, uuid, uuid, uuid, text) is 'ALLOW / BLOCK / REQUIRES_APPROVAL (seção 10) — combina exclusividade territorial (app.check_contract_conflict, Fase 1.1) com o estado EXCLUSIVA/COMPARTILHADA do recurso físico (fibra/porta PON, seção 8). Checagem pura, não altera dados — quem grava de fato passa pelo trigger fn_valida_conflito_compartilhamento, que é a garantia real no banco.';
