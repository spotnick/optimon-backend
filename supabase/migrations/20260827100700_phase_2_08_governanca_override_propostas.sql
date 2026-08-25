-- OptiMon — Fase 2
-- Seções 46-49, 60: governança de preço, override manual e versionamento/snapshot de
-- proposta. Mesma disciplina de workflow já usada em contrato_regras_solicitacoes (Fase
-- 1) e reforçada na Fase 1.2 (toda solicitação nasce PENDENTE, decisão exige
-- DIRETOR/ADMINISTRADOR).

-- Seção 49: função pura de governança — ALLOW / REQUIRES_APPROVAL / BLOCK. Não grava
-- nada, só classifica; quem decide agir sobre um BLOCK/REQUIRES_APPROVAL é o workflow de
-- pricing_override_requests abaixo.
create or replace function app.check_pricing_governance(p_preco_proposto numeric, p_preco_minimo numeric, p_preco_recomendado numeric default null)
returns text
language plpgsql
stable
as $$
begin
  if p_preco_proposto is null or p_preco_minimo is null then
    return 'PARAMETRIZÁVEL — preço mínimo não definido, governança não pode ser avaliada.';
  end if;
  if p_preco_proposto < p_preco_minimo then
    return 'BLOCK';
  end if;
  if p_preco_recomendado is not null and p_preco_proposto < p_preco_recomendado then
    return 'REQUIRES_APPROVAL';
  end if;
  return 'ALLOW';
end;
$$;

comment on function app.check_pricing_governance(numeric, numeric, numeric) is 'Seção 49: preço >= recomendado → ALLOW; entre mínimo e recomendado → REQUIRES_APPROVAL; abaixo do mínimo → BLOCK (só contornável via pricing_override_requests aprovado por DIRETOR/ADMINISTRADOR).';

-- Seção 48: pricing_override_requests — desconto calculado (nunca editável diretamente),
-- justificativa obrigatória, aprovação sempre de DIRETOR/ADMINISTRADOR.
create table public.pricing_override_requests (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  simulacao_id uuid references public.simulacoes(id) on delete set null,
  preco_recomendado numeric(12,2) not null check (preco_recomendado >= 0),
  preco_solicitado numeric(12,2) not null check (preco_solicitado >= 0),
  desconto_percentual numeric(6,4) generated always as (
    case when preco_recomendado > 0 then round((preco_recomendado - preco_solicitado) / preco_recomendado, 4) else null end
  ) stored,
  justificativa text not null check (length(btrim(justificativa)) > 0),
  status public.solicitacao_status not null default 'PENDENTE',
  solicitado_por uuid references public.usuarios(id),
  decidido_por uuid references public.usuarios(id),
  decidido_em timestamptz,
  criado_em timestamptz not null default now()
);
create index pricing_override_requests_contrato_idx on public.pricing_override_requests (contrato_id);
create index pricing_override_requests_status_idx on public.pricing_override_requests (status);

comment on table public.pricing_override_requests is 'Seção 48: Comercial solicita preço diferente do recomendado — desconto sempre visível (coluna gerada), justificativa obrigatória (CHECK), decisão sempre de DIRETOR/ADMINISTRADOR (seção 49).';
comment on column public.pricing_override_requests.desconto_percentual is 'Calculado automaticamente (preco_recomendado - preco_solicitado) / preco_recomendado — nunca informado manualmente, para não haver divergência entre o "desconto exibido" e o preço real solicitado.';

-- Nasce sempre PENDENTE, salvo quando quem cria já é DIRETOR/ADMINISTRADOR (mesmo padrão
-- da correção aplicada em contrato_regras_solicitacoes na Fase 1.2).
create or replace function public.fn_override_nasce_pendente()
returns trigger
language plpgsql
as $$
begin
  if new.status <> 'PENDENTE' and not app.tem_perfil('DIRETOR', 'ADMINISTRADOR') then
    raise exception 'REQUIRES_APPROVAL: override de preço só pode nascer PENDENTE — decisão exige DIRETOR/ADMINISTRADOR (seção 49).';
  end if;
  if new.solicitado_por is null then
    new.solicitado_por := auth.uid();
  end if;
  return new;
end;
$$;

create trigger trg_override_nasce_pendente
  before insert on public.pricing_override_requests
  for each row execute function public.fn_override_nasce_pendente();

-- Decisão (PENDENTE → APROVADA/REJEITADA) sempre de DIRETOR/ADMINISTRADOR, e imutável
-- depois de decidida (nunca se reabre uma decisão silenciosamente).
create or replace function public.fn_override_decisao()
returns trigger
language plpgsql
as $$
begin
  if old.status <> 'PENDENTE' then
    raise exception 'BLOCK: solicitação de override % já foi decidida (%) — decisões são imutáveis.', old.id, old.status;
  end if;
  if new.status <> old.status then
    if not app.tem_perfil('DIRETOR', 'ADMINISTRADOR') then
      raise exception 'REQUIRES_APPROVAL: decisão sobre override de preço exige DIRETOR/ADMINISTRADOR (seção 49).';
    end if;
    new.decidido_por := auth.uid();
    new.decidido_em := now();
  end if;
  return new;
end;
$$;

create trigger trg_override_decisao
  before update on public.pricing_override_requests
  for each row execute function public.fn_override_decisao();

-- Seção 60: propostas_comerciais — snapshot IMUTÁVEL da simulação no momento em que vira
-- proposta formal. "GERAR PROPOSTA" usa exatamente os parâmetros da simulação (seção 59) —
-- nunca recalcula com regras novas no futuro (seção 60, mesma disciplina de
-- contrato_versions/pricing_versions).
create table public.propostas_comerciais (
  id uuid primary key default gen_random_uuid(),
  numero text not null unique default ('PROP-' || to_char(now(), 'YYYYMMDD') || '-' || substr(gen_random_uuid()::text, 1, 8)),
  simulacao_id uuid not null references public.simulacoes(id) on delete restrict,
  pricing_version_id uuid references public.pricing_versions(id) on delete set null,
  override_request_id uuid references public.pricing_override_requests(id) on delete set null,
  contrato_id uuid references public.contratos(id) on delete set null,
  parceiro_id uuid references public.parceiros(id) on delete set null,
  cidade_id uuid references public.cidades_infra(id) on delete set null,
  snapshot jsonb not null,
  status text not null default 'RASCUNHO' check (status in ('RASCUNHO', 'ENVIADA', 'APROVADA', 'REJEITADA')),
  criado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now()
);
create index propostas_comerciais_contrato_idx on public.propostas_comerciais (contrato_id);
create index propostas_comerciais_parceiro_idx on public.propostas_comerciais (parceiro_id);

comment on table public.propostas_comerciais is 'Seção 60: snapshot da proposta (cidade/POP/fibras/portas/capacidade/modelo/mínimo/revenue share/ARPU/clientes/rampa/reajuste/prazo/preço/ROI/payback/pricing_version) — tudo dentro de snapshot (jsonb), imutável (trigger abaixo). Só status pode mudar depois de criada.';
comment on column public.propostas_comerciais.snapshot is 'Cópia completa dos parâmetros e resultado da simulação de origem no momento da geração da proposta — nunca recalculado com regras futuras (seção 60).';

create or replace function public.fn_proposta_snapshot_imutavel()
returns trigger
language plpgsql
as $$
begin
  if new.snapshot is distinct from old.snapshot
     or new.simulacao_id is distinct from old.simulacao_id
     or new.pricing_version_id is distinct from old.pricing_version_id then
    raise exception 'BLOCK: snapshot de proposta comercial é imutável após criação (seção 60) — proposta %.', old.id;
  end if;
  return new;
end;
$$;

create trigger trg_proposta_snapshot_imutavel
  before update on public.propostas_comerciais
  for each row execute function public.fn_proposta_snapshot_imutavel();
