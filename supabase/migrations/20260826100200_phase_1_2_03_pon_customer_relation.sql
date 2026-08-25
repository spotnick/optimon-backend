-- OptiMon — Fase 1.2
-- Seções 11, 12, 13: relação Cliente → Porta PON, preparando a futura integração com o
-- HubSoft (Fase 4) sem assumir que o cliente já tem ID do HubSoft hoje. A partir desta
-- migration, clientes_ativos/capacidade_utilizada_assinantes de uma porta com pelo menos
-- 1 linha em cliente_porta_pon passam a ser calculados daqui — portas sem nenhuma linha
-- aqui (ex.: PON-JUS-001/002 do seed da Fase 1.1, alimentadas manualmente) continuam com
-- o valor que já tinham, intocado, até o dia em que ganharem sua primeira linha real.

create type public.cliente_porta_pon_status as enum ('ATIVO', 'SUSPENSO', 'CANCELADO', 'PENDENTE', 'MIGRADO');

create table public.cliente_porta_pon (
  id uuid primary key default gen_random_uuid(),
  cliente_identificador text not null,
  cliente_hubsoft_id text,
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  porta_pon_id uuid not null references public.infra_portas_pon(id) on delete restrict,
  pop_id uuid not null references public.infra_pops(id) on delete restrict,
  fibra_id uuid not null references public.infra_fibras(id) on delete restrict,
  data_ativacao date,
  data_desativacao date,
  status public.cliente_porta_pon_status not null default 'PENDENTE',
  origem text not null default 'MANUAL' check (origem in ('MANUAL', 'HUBSOFT', 'MIGRACAO')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (porta_pon_id, cliente_identificador)
);
create index cliente_porta_pon_contrato_idx on public.cliente_porta_pon (contrato_id);
create index cliente_porta_pon_porta_idx on public.cliente_porta_pon (porta_pon_id);
create index cliente_porta_pon_status_idx on public.cliente_porta_pon (status);
create index cliente_porta_pon_hubsoft_idx on public.cliente_porta_pon (cliente_hubsoft_id) where cliente_hubsoft_id is not null;

create trigger trg_cliente_porta_pon_atualizado_em
  before update on public.cliente_porta_pon
  for each row execute function public.set_atualizado_em();

comment on table public.cliente_porta_pon is 'PARCEIRO → CONTRATO → PORTA PON → CLIENTE → FATURAMENTO (seção 11). Preparação para a integração HubSoft da Fase 4 — cliente_hubsoft_id é opcional até lá (seção 11: "não assumir que o cliente já possui ID do HubSoft").';
comment on column public.cliente_porta_pon.cliente_hubsoft_id is 'Opcional. Nulo até a integração HubSoft (Fase 4) existir de fato — nunca obrigatório nesta fase.';
comment on column public.cliente_porta_pon.status is 'ATIVO consome capacidade da porta (seção 12); os demais (SUSPENSO/CANCELADO/PENDENTE/MIGRADO) não contam em clientes_ativos.';

-- item 11/33: porta_pon_id, pop_id e fibra_id precisam ser consistentes entre si (mesma
-- lógica de validação já usada em infra_portas_pon/contrato_fibras nas Fases 1/1.1) — e o
-- contrato precisa realmente ter essa porta vinculada (não dá pra ativar cliente numa
-- porta que o contrato não contratou).
create or replace function public.fn_valida_cliente_porta_pon()
returns trigger
language plpgsql
as $$
declare
  v_fibra_id uuid;
  v_pop_id uuid;
  v_tem_vinculo boolean;
begin
  select fibra_id, pop_id into v_fibra_id, v_pop_id
  from public.infra_portas_pon where id = new.porta_pon_id;

  if v_fibra_id is null then
    raise exception 'porta_pon_id % não existe.', new.porta_pon_id;
  end if;

  if new.fibra_id is distinct from v_fibra_id then
    raise exception 'fibra_id % não corresponde à fibra da porta_pon_id % (esperado %).', new.fibra_id, new.porta_pon_id, v_fibra_id;
  end if;

  if new.pop_id is distinct from v_pop_id then
    raise exception 'pop_id % não corresponde ao POP da porta_pon_id % (esperado %).', new.pop_id, new.porta_pon_id, v_pop_id;
  end if;

  select exists (
    select 1 from public.contrato_fibras cf
    where cf.contrato_id = new.contrato_id
      and cf.porta_pon_id = new.porta_pon_id
      and cf.desvinculado_em is null
  ) into v_tem_vinculo;

  if not v_tem_vinculo then
    raise exception 'Contrato % não possui vínculo ativo com a porta_pon_id % — não é possível ativar cliente nela (seção 11).', new.contrato_id, new.porta_pon_id;
  end if;

  return new;
end;
$$;

create trigger trg_valida_cliente_porta_pon
  before insert or update on public.cliente_porta_pon
  for each row execute function public.fn_valida_cliente_porta_pon();

-- Seção 13: CAPACITY_EXCEEDED tem que ser barrado no banco, não só no frontend. Roda
-- ANTES da validação de contagem para nunca deixar a porta passar de capacidade_max.
create or replace function public.fn_cliente_porta_pon_checa_capacidade()
returns trigger
language plpgsql
as $$
declare
  v_resultado text;
begin
  -- Só precisa checar quando o cliente está (ou está passando a ficar) ATIVO — mudar
  -- status entre não-ativos, ou desativar, nunca estoura capacidade.
  if new.status = 'ATIVO' and (TG_OP = 'INSERT' or old.status is distinct from 'ATIVO') then
    v_resultado := app.check_port_capacity(new.porta_pon_id, 1);
    if v_resultado = 'CAPACITY_EXCEEDED' then
      raise exception 'CAPACITY_EXCEEDED: porta PON % já está no limite de capacidade (seção 13).', new.porta_pon_id;
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_cliente_porta_pon_checa_capacidade
  before insert or update on public.cliente_porta_pon
  for each row execute function public.fn_cliente_porta_pon_checa_capacidade();

-- Auto-preenchimento de datas de ativação/desativação (conveniência, nunca sobrescreve
-- valor já informado explicitamente).
create or replace function public.fn_cliente_porta_pon_datas()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'ATIVO' and new.data_ativacao is null then
    new.data_ativacao := current_date;
  end if;
  if new.status in ('CANCELADO', 'SUSPENSO', 'MIGRADO') and new.data_desativacao is null
     and (TG_OP = 'INSERT' or old.status is distinct from new.status) then
    new.data_desativacao := current_date;
  end if;
  return new;
end;
$$;

create trigger trg_cliente_porta_pon_datas
  before insert or update on public.cliente_porta_pon
  for each row execute function public.fn_cliente_porta_pon_datas();

-- Seção 12: "clientes_ativos = COUNT(cliente_porta_pon WHERE status = ATIVO)". Depois de
-- qualquer INSERT/UPDATE/DELETE, recalcula a contagem real da porta afetada (e da porta
-- antiga, se o cliente migrou de porta) + a situacao_comercial (Fase 1.2/02) + dispara
-- alerta de capacidade quando cruza um threshold (seção 14).
create or replace function public.fn_cliente_porta_pon_sync_capacidade()
returns trigger
language plpgsql
as $$
declare
  v_porta_id uuid;
  v_porta_antiga uuid;
  v_contagem integer;
  v_max integer;
  v_taxa numeric;
  v_tipo public.alerta_tipo;
  v_severidade public.alerta_severidade;
  v_titulo text;
  v_ja_existe boolean;
begin
  if TG_OP = 'DELETE' then
    v_porta_id := old.porta_pon_id;
  else
    v_porta_id := new.porta_pon_id;
    if TG_OP = 'UPDATE' and old.porta_pon_id is distinct from new.porta_pon_id then
      v_porta_antiga := old.porta_pon_id;
    end if;
  end if;

  -- Porta antiga (cliente migrou de porta): recalcula e sai — não precisa checar alerta
  -- de crescimento numa porta que só perdeu cliente.
  if v_porta_antiga is not null then
    select count(*) into v_contagem from public.cliente_porta_pon where porta_pon_id = v_porta_antiga and status = 'ATIVO';
    update public.infra_portas_pon set capacidade_utilizada_assinantes = v_contagem where id = v_porta_antiga;
    perform app.recalcular_situacao_porta(v_porta_antiga);
  end if;

  if v_porta_id is null then
    return coalesce(new, old);
  end if;

  select count(*) into v_contagem from public.cliente_porta_pon where porta_pon_id = v_porta_id and status = 'ATIVO';
  update public.infra_portas_pon set capacidade_utilizada_assinantes = v_contagem where id = v_porta_id;
  perform app.recalcular_situacao_porta(v_porta_id);

  select capacidade_max_assinantes into v_max from public.infra_portas_pon where id = v_porta_id;
  if v_max is null or v_max = 0 then
    return coalesce(new, old);
  end if;
  v_taxa := v_contagem::numeric / v_max;

  -- Só o maior threshold cruzado gera alerta, e só se ainda não houver um alerta do
  -- mesmo tipo em aberto para esta porta (evita repetir a cada novo cliente).
  if v_taxa >= 1.0 then
    v_tipo := 'CAPACIDADE_100'; v_severidade := 'CRITICO'; v_titulo := 'Porta PON no limite máximo de capacidade';
  elsif v_taxa >= 0.90 then
    v_tipo := 'CAPACIDADE_90'; v_severidade := 'ATENCAO'; v_titulo := 'Porta PON com 90% da capacidade ocupada';
  elsif v_taxa >= 0.80 then
    v_tipo := 'CAPACIDADE_80'; v_severidade := 'ATENCAO'; v_titulo := 'Porta PON com 80% da capacidade ocupada';
  else
    v_tipo := null;
  end if;

  if v_tipo is not null then
    select exists (
      select 1 from public.alertas
      where porta_pon_id = v_porta_id and tipo = v_tipo and resolvido = false
    ) into v_ja_existe;

    if not v_ja_existe then
      insert into public.alertas (tipo, severidade, porta_pon_id, titulo, descricao)
      values (v_tipo, v_severidade, v_porta_id,
        v_titulo,
        format('Porta PON ocupada em %s%% (%s de %s assinantes) — seção 14.', round(v_taxa * 100, 1), v_contagem, v_max));
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

create trigger trg_cliente_porta_pon_sync_capacidade
  after insert or update or delete on public.cliente_porta_pon
  for each row execute function public.fn_cliente_porta_pon_sync_capacidade();

comment on function public.fn_cliente_porta_pon_sync_capacidade() is 'Fonte de verdade de capacidade_utilizada_assinantes a partir de cliente_porta_pon (seção 12) + alertas CAPACIDADE_80/90/100 (seção 14). Portas sem nenhuma linha em cliente_porta_pon nunca são tocadas por esta função — mantêm o valor herdado da Fase 1.1.';
