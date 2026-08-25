-- OptiMon — Fase 1
-- Vínculo entre contratos e fibras/ativos, com sincronização automática de status.

create table public.contrato_fibras (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  fibra_id uuid not null references public.infra_fibras(id) on delete restrict,
  vinculado_em timestamptz not null default now(),
  desvinculado_em timestamptz
);
-- Uma fibra só pode estar ativamente vinculada a um único contrato por vez.
create unique index contrato_fibras_fibra_ativa_idx
  on public.contrato_fibras (fibra_id) where desvinculado_em is null;
create index contrato_fibras_contrato_idx on public.contrato_fibras (contrato_id);

comment on table public.contrato_fibras is 'Qual contrato usa qual fibra/par, agora ou historicamente (seção 6 do Prompt Mestre).';

create or replace function public.fn_contrato_fibras_sync_status()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'INSERT' then
    update public.infra_fibras
      set status = 'LOCADA', atualizado_em = now()
      where id = new.fibra_id;
    return new;
  elsif TG_OP = 'UPDATE' and new.desvinculado_em is not null and old.desvinculado_em is null then
    update public.infra_fibras
      set status = 'LIVRE', atualizado_em = now()
      where id = new.fibra_id;
    return new;
  end if;
  return new;
end;
$$;

create trigger trg_contrato_fibras_sync
  after insert or update on public.contrato_fibras
  for each row execute function public.fn_contrato_fibras_sync_status();

comment on function public.fn_contrato_fibras_sync_status() is 'Mantém infra_fibras.status coerente com o vínculo contratual: LOCADA ao vincular, LIVRE ao desvincular.';

create table public.contrato_ativos (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  ativo_id uuid not null references public.ativos(id) on delete restrict,
  vinculado_em timestamptz not null default now(),
  desvinculado_em timestamptz
);
create unique index contrato_ativos_ativo_ativo_idx
  on public.contrato_ativos (ativo_id) where desvinculado_em is null;
create index contrato_ativos_contrato_idx on public.contrato_ativos (contrato_id);

comment on table public.contrato_ativos is 'Equipamentos (ativos) vinculados a um contrato, agora ou historicamente.';
