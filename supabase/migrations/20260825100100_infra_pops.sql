-- OptiMon — Fase 1.1
-- POPs: uma cidade pode ter N POPs (seções 7 e 8). Cadeia atualizada:
-- CIDADE → POP → CABO → FIBRA → PORTA PON → CONTRATO.

create type pop_tipo as enum ('PRINCIPAL', 'DISTRIBUICAO', 'ACESSO', 'OUTRO');

create table public.infra_pops (
  id uuid primary key default gen_random_uuid(),
  cidade_id uuid not null references public.cidades_infra(id) on delete restrict,
  codigo text not null,
  nome text not null,
  endereco text,
  latitude numeric(9,6),
  longitude numeric(9,6),
  tipo pop_tipo not null default 'ACESSO',
  capacidade_total integer check (capacidade_total is null or capacidade_total >= 0),
  status text not null default 'ATIVO' check (status in ('ATIVO', 'PLANEJADO', 'DESATIVADO')),
  observacoes text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  removido_em timestamptz,
  unique (cidade_id, codigo)
);
create index infra_pops_cidade_idx on public.infra_pops (cidade_id);
create trigger trg_infra_pops_atualizado_em
  before update on public.infra_pops
  for each row execute function public.set_atualizado_em();

comment on table public.infra_pops is 'Ponto de Presença. Uma cidade pode ter vários POPs — não assumir 1:1 cidade/POP (seção 7 do prompt de Fase 1.1).';
comment on column public.infra_pops.capacidade_total is 'Capacidade agregada informativa do POP (opcional). A capacidade real é sempre recalculada a partir de infra_portas_pon via view — este campo nunca é fonte de verdade.';

-- Um cabo passa a pertencer a um POP. Nullable por compatibilidade com cabos já
-- cadastrados na Fase 1 (ex.: CABO-JUSSARA-01) — o backfill abaixo resolve o caso existente.
alter table public.infra_cabos
  add column pop_id uuid references public.infra_pops(id) on delete restrict;
create index infra_cabos_pop_idx on public.infra_cabos (pop_id);

comment on column public.infra_cabos.pop_id is 'POP ao qual este cabo pertence. Obrigatório para cabos novos a partir da Fase 1.1 (aplicação deve sempre informar); nullable no schema só para não quebrar cabos herdados da Fase 1 antes do backfill.';

-- Backfill não-destrutivo: cria um POP-01 (PRINCIPAL) para cada cidade que já tinha cabo
-- sem POP, e associa esses cabos a ele. Não altera nenhum outro dado existente.
do $$
declare
  r record;
  v_pop_id uuid;
begin
  for r in
    select distinct s.cidade_id
    from public.infra_cabos c
    join public.infra_segmentos s on s.id = c.segmento_id
    where c.pop_id is null
  loop
    insert into public.infra_pops (cidade_id, codigo, nome, tipo, observacoes)
    values (r.cidade_id, 'POP-01', 'POP-01', 'PRINCIPAL', 'Criado automaticamente pelo backfill da Fase 1.1 para cabos pré-existentes sem POP.')
    on conflict (cidade_id, codigo) do update set nome = public.infra_pops.nome
    returning id into v_pop_id;

    update public.infra_cabos c
    set pop_id = v_pop_id
    from public.infra_segmentos s
    where c.segmento_id = s.id
      and s.cidade_id = r.cidade_id
      and c.pop_id is null;
  end loop;
end $$;
