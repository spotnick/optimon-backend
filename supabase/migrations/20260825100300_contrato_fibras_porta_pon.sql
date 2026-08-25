-- OptiMon — Fase 1.1
-- contrato_fibras passa a suportar fibra individual + porta PON (seção 10).
-- Não exige mais par: 1 fibra isolada pode ser contratada normalmente.

alter table public.contrato_fibras
  add column porta_pon_id uuid references public.infra_portas_pon(id) on delete restrict,
  add column capacidade_clientes integer check (capacidade_clientes is null or capacidade_clientes >= 0),
  add column status text not null default 'ATIVO' check (status in ('ATIVO', 'ENCERRADO', 'SUSPENSO')),
  add column observacoes text,
  add column compartilhamento_autorizado boolean not null default false;

create index contrato_fibras_porta_pon_idx on public.contrato_fibras (porta_pon_id);

comment on column public.contrato_fibras.porta_pon_id is 'Porta PON associada a este vínculo, quando a fibra estiver provisionada como acesso PON (opcional — dark fiber pura pode não ter porta).';
comment on column public.contrato_fibras.compartilhamento_autorizado is 'Quando true, permite que a mesma fibra/porta apareça em mais de um vínculo ativo simultâneo — exceção explícita a um modelo de compartilhamento autorizado (seção 10). Default false = exclusivo.';

-- Substitui os índices únicos parciais da Fase 1 por versões que respeitam a exceção
-- de compartilhamento_autorizado (seção 10: impedir dupla contratação "salvo quando
-- existir explicitamente um modelo de compartilhamento autorizado").
drop index if exists public.contrato_fibras_fibra_ativa_idx;
create unique index contrato_fibras_fibra_ativa_idx
  on public.contrato_fibras (fibra_id)
  where desvinculado_em is null and compartilhamento_autorizado = false;

create unique index contrato_fibras_porta_ativa_idx
  on public.contrato_fibras (porta_pon_id)
  where desvinculado_em is null and compartilhamento_autorizado = false and porta_pon_id is not null;

-- item 10/33: a porta PON informada precisa realmente ser a porta desta fibra.
create or replace function public.fn_valida_contrato_fibra_porta()
returns trigger
language plpgsql
as $$
declare
  v_fibra_da_porta uuid;
begin
  if new.porta_pon_id is not null then
    select fibra_id into v_fibra_da_porta from public.infra_portas_pon where id = new.porta_pon_id;
    if v_fibra_da_porta is distinct from new.fibra_id then
      raise exception 'porta_pon_id % não corresponde à fibra_id % informada em contrato_fibras.', new.porta_pon_id, new.fibra_id;
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_valida_contrato_fibra_porta
  before insert or update on public.contrato_fibras
  for each row execute function public.fn_valida_contrato_fibra_porta();
