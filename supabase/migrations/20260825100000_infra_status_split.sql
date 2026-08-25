-- OptiMon — Fase 1.1
-- Separa o status único de infra_fibras em 3 dimensões independentes (seção 32):
--   status_operacional: estado físico/de engenharia (a fibra funciona?)
--   status_comercial:   política comercial (pode ser oferecida a parceiros? — nunca mexido
--                        automaticamente por vínculo de contrato)
--   status_contratual:  está vinculada a um contrato agora? (isso sim o trigger de
--                        vínculo controla)
--
-- Corrige um bug real da Fase 1: fn_contrato_fibras_sync_status jogava a fibra para
-- 'LIVRE' sempre que um contrato era desvinculado, o que apagaria um bloqueio comercial
-- (ex.: fibra reservada à Prefeitura) se ela algum dia tivesse sido contratada e depois
-- desvinculada. Agora o trigger nunca mais toca status_comercial.

create type fibra_status_operacional as enum ('ATIVA', 'MANUTENCAO', 'ROMPIDA', 'DESATIVADA');
create type fibra_status_comercial as enum ('LIVRE', 'RESERVADA', 'BLOQUEADA');
create type fibra_status_contratual as enum ('DISPONIVEL', 'VINCULADA');

alter table public.infra_fibras
  add column status_operacional fibra_status_operacional not null default 'ATIVA',
  add column status_comercial   fibra_status_comercial   not null default 'LIVRE',
  add column status_contratual  fibra_status_contratual  not null default 'DISPONIVEL';

-- Backfill a partir do campo legado `status`, preservando o significado original de cada valor.
update public.infra_fibras set
  status_operacional = case when status = 'MANUTENCAO' then 'MANUTENCAO'::fibra_status_operacional else 'ATIVA' end,
  status_comercial = case
    when status = 'BLOQUEADA' then 'BLOQUEADA'::fibra_status_comercial
    when status = 'OCUPADA'   then 'BLOQUEADA'::fibra_status_comercial  -- em uso interno, não ofertável (seção 7)
    when status = 'RESERVADA' then 'RESERVADA'::fibra_status_comercial
    else 'LIVRE'::fibra_status_comercial
  end,
  status_contratual = case
    when status in ('LOCADA', 'OCUPADA') then 'VINCULADA'::fibra_status_contratual
    else 'DISPONIVEL'::fibra_status_contratual
  end;

-- Reforça a partir da realidade em contrato_fibras (fonte de verdade de vínculo ativo),
-- caso o campo legado já estivesse desatualizado em algum registro.
update public.infra_fibras f
set status_contratual = 'VINCULADA'
where exists (
  select 1 from public.contrato_fibras cf
  where cf.fibra_id = f.id and cf.desvinculado_em is null
);

create index infra_fibras_status_comercial_idx on public.infra_fibras (status_comercial);
create index infra_fibras_status_contratual_idx on public.infra_fibras (status_contratual);

comment on column public.infra_fibras.status is 'DEPRECATED a partir da Fase 1.1 — mantido só por compatibilidade com views/consultas antigas. Fonte de verdade agora é status_operacional/status_comercial/status_contratual.';
comment on column public.infra_fibras.status_operacional is 'Estado físico/de engenharia da fibra (ATIVA, MANUTENCAO, ROMPIDA, DESATIVADA). Gerido por ENGENHARIA.';
comment on column public.infra_fibras.status_comercial is 'Política comercial (LIVRE, RESERVADA, BLOQUEADA). NUNCA alterado automaticamente por vínculo/desvínculo de contrato — só por decisão de ENGENHARIA/DIRETOR.';
comment on column public.infra_fibras.status_contratual is 'DISPONIVEL ou VINCULADA — reflexo exclusivo de haver ou não um contrato_fibras ativo agora. Mantido pelo trigger fn_contrato_fibras_sync_status.';

-- Reescreve o trigger de sincronização: só mexe em status_contratual (e, por compatibilidade,
-- no campo legado `status`, mas agora revertendo para o valor coerente com status_comercial
-- em vez de sempre 'LIVRE' — é aqui que o bug da Fase 1 é corrigido de fato).
create or replace function public.fn_contrato_fibras_sync_status()
returns trigger
language plpgsql
as $$
declare
  v_comercial fibra_status_comercial;
  v_status_legado fibra_status;
begin
  if TG_OP = 'INSERT' then
    update public.infra_fibras
      set status_contratual = 'VINCULADA',
          status = 'LOCADA',
          atualizado_em = now()
      where id = new.fibra_id;
    return new;

  elsif TG_OP = 'UPDATE' and new.desvinculado_em is not null and old.desvinculado_em is null then
    select status_comercial into v_comercial from public.infra_fibras where id = new.fibra_id;

    v_status_legado := case v_comercial
      when 'BLOQUEADA' then 'BLOQUEADA'::fibra_status
      when 'RESERVADA' then 'RESERVADA'::fibra_status
      else 'LIVRE'::fibra_status
    end;

    update public.infra_fibras
      set status_contratual = 'DISPONIVEL',
          status = v_status_legado,
          atualizado_em = now()
      where id = new.fibra_id;
    return new;
  end if;

  return new;
end;
$$;

comment on function public.fn_contrato_fibras_sync_status() is 'Fase 1.1: só sincroniza status_contratual (DISPONIVEL/VINCULADA). status_comercial (política, ex.: BLOQUEADA p/ cliente reservado) nunca é tocado aqui — corrige o bug da Fase 1 onde desvincular um contrato jogava a fibra de volta para LIVRE mesmo que ela devesse continuar bloqueada/reservada.';
