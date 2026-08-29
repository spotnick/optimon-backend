-- OptiMon — Fase 3.8 (itens 3.8-09 e 3.8-10): workflow formal de solicitação de uso de
-- infraestrutura de terceiros (tipo FIBRA_TERCEIROS) e mecanismo de exceção para rede
-- própria do parceiro (tipo REDE_PROPRIA).
--
-- ESTADO ANTES DESTA MIGRATION: public.contrato_regras_solicitacoes existe desde a Fase 1
-- (seções 21-24), com RLS e auditoria já corretas, mas é uma tabela MORTA — 0 linhas,
-- 0 rotas de API, 0 tela de frontend a referenciam (confirmado por grep em api/ e
-- web/src/). O fluxo de decisão que existe é de UMA ETAPA só (PENDENTE →
-- APROVADA/REJEITADA, decidido só por DIRETOR/ADMINISTRADOR) — não corresponde ao fluxo
-- formal pedido: Engenharia → Comercial → Diretoria → auditoria.
--
-- ESTA MIGRATION:
--   1) Troca o enum de status de `solicitacao_status` (genérico, compartilhado com
--      pricing_override_requests) para um novo `regra_solicitacao_status` próprio desta
--      tabela, com uma etapa por papel: AGUARDANDO_ENGENHARIA → AGUARDANDO_COMERCIAL →
--      AGUARDANDO_DIRETORIA → APROVADA/REJEITADA (qualquer etapa pode rejeitar
--      diretamente, sem precisar passar pelas etapas seguintes). Tabela tinha 0 linhas
--      (confirmado antes de escrever esta migration) — não há necessidade de migrar dados.
--   2) Adiciona colunas de parecer por etapa (parecer_engenharia*, parecer_comercial*) e
--      etapa_rejeicao (registra em qual etapa uma solicitação foi rejeitada).
--   3) fn_regra_solicitacao_transicao(): trigger BEFORE UPDATE que é a ÚNICA forma de
--      avançar de etapa — valida a transição (nunca pula etapa, nunca decide já decidido)
--      e o perfil de quem está fazendo aquela etapa especificamente, e carimba
--      quem/quando automaticamente (nunca aceita esses campos vindos do cliente).
--   4) fn_regra_solicitacao_aplica_excecao(): trigger AFTER UPDATE — no momento em que a
--      Diretoria aprova (status vira APROVADA), aplica o EFEITO REAL da exceção:
--      contrato_regras.proibe_fibra_terceiros ou .proibe_rede_propria vira FALSE para
--      aquele contrato (upsert — cria a linha de contrato_regras se ainda não existir).
--      Sem isso a "aprovação" seria só um registro histórico sem efeito prático nas
--      cláusulas 21-23 do contrato — o pedido do prompt é explicitamente um MECANISMO DE
--      EXCEÇÃO, não só um registro de decisão.
--   5) RLS de UPDATE ampliada para ENGENHARIA/COMERCIAL (mesma lição da Fase 3.16: a RLS
--      precisa deixar a linha alcançável para quem o trigger pretende autorizar, senão a
--      autorização "existe" no trigger mas nunca dispara — 0 linhas afetadas
--      silenciosamente). A autorização real de qual role pode fazer qual transição
--      continua 100% no trigger, não na RLS (RLS só garante que a linha é alcançável).

create type regra_solicitacao_status as enum (
  'AGUARDANDO_ENGENHARIA', 'AGUARDANDO_COMERCIAL', 'AGUARDANDO_DIRETORIA', 'APROVADA', 'REJEITADA'
);

drop trigger trg_solicitacao_nasce_pendente on public.contrato_regras_solicitacoes;
drop function public.fn_solicitacao_nasce_pendente();
drop policy contrato_regras_solicitacoes_decide on public.contrato_regras_solicitacoes;

alter table public.contrato_regras_solicitacoes
  drop column status;
alter table public.contrato_regras_solicitacoes
  add column status regra_solicitacao_status not null default 'AGUARDANDO_ENGENHARIA',
  add column parecer_engenharia text,
  add column parecer_engenharia_por uuid references public.usuarios(id),
  add column parecer_engenharia_em timestamptz,
  add column parecer_comercial text,
  add column parecer_comercial_por uuid references public.usuarios(id),
  add column parecer_comercial_em timestamptz,
  add column motivo_rejeicao text,
  add column etapa_rejeicao text check (etapa_rejeicao in ('ENGENHARIA', 'COMERCIAL', 'DIRETORIA'));
create index contrato_regras_solicitacoes_status_idx on public.contrato_regras_solicitacoes (status);

comment on table public.contrato_regras_solicitacoes is 'Fase 1 (seções 21-24) + estrutura formal Fase 3.8 (itens 3.8-09/3.8-10): workflow de 3 etapas (Engenharia → Comercial → Diretoria) para autorizar exceção a "proibe_fibra_terceiros" (tipo FIBRA_TERCEIROS) ou "proibe_rede_propria" (tipo REDE_PROPRIA) em contrato_regras. Aprovação pela Diretoria aplica o efeito automaticamente (ver fn_regra_solicitacao_aplica_excecao).';
comment on column public.contrato_regras_solicitacoes.status is 'AGUARDANDO_ENGENHARIA → AGUARDANDO_COMERCIAL → AGUARDANDO_DIRETORIA → APROVADA/REJEITADA. Qualquer etapa pode rejeitar diretamente (etapa_rejeicao registra qual). Transição só ocorre via fn_regra_solicitacao_transicao — nunca é um UPDATE livre.';

-- Nasce sempre na primeira etapa — ninguém (nem DIRETOR/ADMINISTRADOR) pula a avaliação
-- técnica de Engenharia no INSERT. A elevação de perfil para agir em qualquer etapa está
-- disponível DENTRO do fluxo (ver fn_regra_solicitacao_transicao), não pulando o fluxo.
alter table public.contrato_regras_solicitacoes
  alter column status set default 'AGUARDANDO_ENGENHARIA';

create or replace function public.fn_regra_solicitacao_transicao()
returns trigger
language plpgsql
as $$
begin
  if old.status in ('APROVADA', 'REJEITADA') then
    raise exception 'BLOCK: solicitação % já foi decidida (%) — decisões são imutáveis.', old.id, old.status;
  end if;

  if new.status = old.status then
    -- Atualização que não é uma transição de etapa (ex.: só editar a descrição) — nunca
    -- permite que o cliente escreva diretamente os campos de parecer/decisão fora do
    -- fluxo (só os ramos abaixo, disparados por uma transição real, podem fazer isso).
    if new.parecer_engenharia_por is distinct from old.parecer_engenharia_por
      or new.parecer_engenharia_em is distinct from old.parecer_engenharia_em
      or new.parecer_comercial_por is distinct from old.parecer_comercial_por
      or new.parecer_comercial_em is distinct from old.parecer_comercial_em
      or new.decidido_por is distinct from old.decidido_por
      or new.decidido_em is distinct from old.decidido_em
      or new.etapa_rejeicao is distinct from old.etapa_rejeicao then
      raise exception 'BLOCK: pareceres e decisão só podem ser registrados através de uma transição de etapa válida.';
    end if;
    return new;
  end if;

  if old.status = 'AGUARDANDO_ENGENHARIA' and new.status in ('AGUARDANDO_COMERCIAL', 'REJEITADA') then
    if not app.tem_perfil('ENGENHARIA', 'DIRETOR', 'ADMINISTRADOR') then
      raise exception 'REQUIRES_APPROVAL: parecer de Engenharia exige perfil ENGENHARIA (ou DIRETOR/ADMINISTRADOR).';
    end if;
    if new.parecer_engenharia is null or btrim(new.parecer_engenharia) = '' then
      raise exception 'VALIDATION: parecer_engenharia é obrigatório para avançar ou rejeitar nesta etapa.';
    end if;
    new.parecer_engenharia_por := auth.uid();
    new.parecer_engenharia_em := now();
    if new.status = 'REJEITADA' then new.etapa_rejeicao := 'ENGENHARIA'; end if;

  elsif old.status = 'AGUARDANDO_COMERCIAL' and new.status in ('AGUARDANDO_DIRETORIA', 'REJEITADA') then
    if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
      raise exception 'REQUIRES_APPROVAL: parecer Comercial exige perfil COMERCIAL (ou DIRETOR/ADMINISTRADOR).';
    end if;
    if new.parecer_comercial is null or btrim(new.parecer_comercial) = '' then
      raise exception 'VALIDATION: parecer_comercial é obrigatório para avançar ou rejeitar nesta etapa.';
    end if;
    new.parecer_comercial_por := auth.uid();
    new.parecer_comercial_em := now();
    if new.status = 'REJEITADA' then new.etapa_rejeicao := 'COMERCIAL'; end if;

  elsif old.status = 'AGUARDANDO_DIRETORIA' and new.status in ('APROVADA', 'REJEITADA') then
    if not app.tem_perfil('DIRETOR', 'ADMINISTRADOR') then
      raise exception 'REQUIRES_APPROVAL: decisão final exige DIRETOR/ADMINISTRADOR (seções 21-24).';
    end if;
    if new.status = 'REJEITADA' and (new.motivo_rejeicao is null or btrim(new.motivo_rejeicao) = '') then
      raise exception 'VALIDATION: motivo_rejeicao é obrigatório quando a Diretoria rejeita.';
    end if;
    new.decidido_por := auth.uid();
    new.decidido_em := now();
    if new.status = 'REJEITADA' then new.etapa_rejeicao := 'DIRETORIA'; end if;

  else
    raise exception 'BLOCK: transição de status inválida (% -> %) para solicitação %.', old.status, new.status, old.id;
  end if;

  return new;
end;
$$;

create trigger trg_regra_solicitacao_transicao
  before update on public.contrato_regras_solicitacoes
  for each row execute function public.fn_regra_solicitacao_transicao();

-- BUG PRÉ-EXISTENTE encontrado ao testar esta migration via PostgREST local (não
-- introduzido por ela): ao contrário de pricing_override_requests (que tem
-- fn_override_nasce_pendente carimbando solicitado_por := auth.uid() automaticamente),
-- contrato_regras_solicitacoes NUNCA teve esse carimbo desde a Fase 1 — a coluna ficava
-- sempre null a menos que o cliente a enviasse manualmente (a rota de API não enviava).
-- Corrigido aqui, no mesmo espírito do padrão já usado no resto do sistema.
create or replace function public.fn_regra_solicitacao_nasce()
returns trigger
language plpgsql
as $$
begin
  if new.solicitado_por is null then
    new.solicitado_por := auth.uid();
  end if;
  return new;
end;
$$;

create trigger trg_regra_solicitacao_nasce
  before insert on public.contrato_regras_solicitacoes
  for each row execute function public.fn_regra_solicitacao_nasce();

comment on function public.fn_regra_solicitacao_nasce() is 'BUGFIX Fase 3.8 (item 3.8-09/3.8-10): carimba solicitado_por = auth.uid() automaticamente no INSERT — gap pré-existente desde a Fase 1 (a coluna nunca era preenchida, mesma classe de correção já aplicada em pricing_override_requests via fn_override_nasce_pendente).';

-- Efeito real da aprovação: concede a exceção em contrato_regras. AFTER UPDATE (não
-- BEFORE) porque precisa da linha já persistida como APROVADA antes de aplicar o efeito
-- colateral em outra tabela — e roda com upsert porque contrato_regras pode nunca ter
-- sido criada explicitamente para este contrato (guardrails ainda nos valores padrão).
create or replace function public.fn_regra_solicitacao_aplica_excecao()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'APROVADA' and old.status <> 'APROVADA' then
    if new.tipo = 'FIBRA_TERCEIROS' then
      insert into public.contrato_regras (contrato_id, proibe_fibra_terceiros)
      values (new.contrato_id, false)
      on conflict (contrato_id) do update set proibe_fibra_terceiros = false;
    elsif new.tipo = 'REDE_PROPRIA' then
      insert into public.contrato_regras (contrato_id, proibe_rede_propria)
      values (new.contrato_id, false)
      on conflict (contrato_id) do update set proibe_rede_propria = false;
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_regra_solicitacao_aplica_excecao
  after update on public.contrato_regras_solicitacoes
  for each row execute function public.fn_regra_solicitacao_aplica_excecao();

comment on function public.fn_regra_solicitacao_aplica_excecao() is 'Fase 3.8 (itens 3.8-09/3.8-10): quando a Diretoria aprova uma solicitação, concede automaticamente a exceção correspondente em contrato_regras (proibe_fibra_terceiros/proibe_rede_propria = false) — upsert, pois contrato_regras pode ainda não existir para o contrato.';

-- RLS: ver comentário no topo do arquivo — a policy precisa deixar a linha alcançável
-- para ENGENHARIA e COMERCIAL também (não só DIRETOR/ADMINISTRADOR), senão o trigger
-- acima nunca é alcançado para essas duas etapas (mesma classe de bug da Fase 3.16).
create policy contrato_regras_solicitacoes_transicao on public.contrato_regras_solicitacoes for update to authenticated
  using (app.tem_perfil('ENGENHARIA', 'COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'))
  with check (app.tem_perfil('ENGENHARIA', 'COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'));
comment on policy contrato_regras_solicitacoes_transicao on public.contrato_regras_solicitacoes is 'Deixa a linha alcançável para as 3 roles do workflow (Engenharia/Comercial/Diretoria+Administrador) — a autorização real de QUAL role pode agir em QUAL etapa é 100% do trigger fn_regra_solicitacao_transicao, nunca da RLS.';
