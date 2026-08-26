-- OptiMon — Fase 2.4 (1/7): módulo profissional de propostas — schema base.
-- Estende `propostas_comerciais` (existente, Fase 1) com: versionamento
-- (numero_versao/proposta_raiz_id/duplicada_de_id), dados de capa (parceiro
-- nome/cargo, validade), autorização de aprovação abaixo do piso, motivo de
-- mudança de status, e o status ampliado de 4 → 9 valores (seção 36 do
-- prompt-mestre). Nenhuma tabela nova, nenhuma coluna removida, nenhum dado
-- apagado — só ALTER TABLE aditivo + backfill.

-- ============================================================================
-- 1) NOVAS COLUNAS
-- ============================================================================

alter table public.propostas_comerciais
  add column if not exists numero_versao integer not null default 1,
  add column if not exists proposta_raiz_id uuid references public.propostas_comerciais(id),
  add column if not exists duplicada_de_id uuid references public.propostas_comerciais(id),
  add column if not exists parceiro_nome_capa text,
  add column if not exists parceiro_cargo_contato text,
  add column if not exists validade_dias integer not null default 15,
  add column if not exists autorizado_por uuid references public.usuarios(id),
  add column if not exists autorizado_em timestamptz,
  add column if not exists preco_autorizado numeric(12,2),
  add column if not exists motivo_autorizacao text,
  add column if not exists motivo_status text;

comment on column public.propostas_comerciais.numero_versao is 'Fase 2.4 seção 40: V1/V2/V3... — nunca sobrescreve, cada nova versão é uma nova linha.';
comment on column public.propostas_comerciais.proposta_raiz_id is 'Fase 2.4 seção 40: aponta para a v1 da família de versões (auto-referência a si mesma quando a proposta É a v1 — trigger abaixo).';
comment on column public.propostas_comerciais.duplicada_de_id is 'Fase 2.4 seção 41: "Duplicar Proposta" — de qual proposta esta foi duplicada (família de numero/proposta_raiz_id independente da original).';
comment on column public.propostas_comerciais.parceiro_nome_capa is 'Fase 2.4 seção 6: nome do parceiro exibido na capa do documento (pode divergir de parceiros.nome_fantasia se digitado manualmente na criação).';
comment on column public.propostas_comerciais.parceiro_cargo_contato is 'Fase 2.4 seção 6: cargo do contato do parceiro exibido na capa.';
comment on column public.propostas_comerciais.validade_dias is 'Fase 2.4 seção 6: validade da proposta em dias corridos a partir de criado_em (default 15).';
comment on column public.propostas_comerciais.autorizado_por is 'Fase 2.4 seção 38: DIRETOR/ADMINISTRADOR que autorizou preço abaixo do piso.';
comment on column public.propostas_comerciais.autorizado_em is 'Fase 2.4 seção 38: timestamp da autorização.';
comment on column public.propostas_comerciais.preco_autorizado is 'Fase 2.4 seção 38: preço efetivamente autorizado (congelado no momento da aprovação).';
comment on column public.propostas_comerciais.motivo_autorizacao is 'Fase 2.4 seção 38: justificativa obrigatória quando preço < piso.';
comment on column public.propostas_comerciais.motivo_status is 'Fase 2.4 seção 37: motivo de rejeição/cancelamento/outras mudanças de status que exigem explicação.';

-- ============================================================================
-- 2) STATUS AMPLIADO (seção 36) — 4 → 9 valores
--    RASCUNHO, EM_APROVACAO, APROVADA, ENVIADA, EM_NEGOCIACAO, ACEITA,
--    RECUSADA, EXPIRADA, CANCELADA
--    'REJEITADA' (antigo) → 'RECUSADA' (novo nome do mesmo estado terminal).
-- ============================================================================

update public.propostas_comerciais set status = 'RECUSADA' where status = 'REJEITADA';

alter table public.propostas_comerciais drop constraint if exists propostas_comerciais_status_check;
alter table public.propostas_comerciais add constraint propostas_comerciais_status_check
  check (status = any (array[
    'RASCUNHO', 'EM_APROVACAO', 'APROVADA', 'ENVIADA', 'EM_NEGOCIACAO',
    'ACEITA', 'RECUSADA', 'EXPIRADA', 'CANCELADA'
  ]));

-- ============================================================================
-- 3) BACKFILL — proposta_raiz_id aponta pra si mesma nas linhas já existentes
--    (todas nasceram como v1, sem família de versões ainda).
-- ============================================================================

update public.propostas_comerciais set proposta_raiz_id = id where proposta_raiz_id is null;

create index if not exists propostas_comerciais_raiz_idx on public.propostas_comerciais(proposta_raiz_id);
create index if not exists propostas_comerciais_status_idx on public.propostas_comerciais(status);

-- ============================================================================
-- 4) TRIGGER — auto-seta proposta_raiz_id = id em INSERT quando nulo
--    (novas propostas "de raiz", i.e. não criadas via criar_versao_proposta,
--    que já vai setar o valor explicitamente antes do insert).
-- ============================================================================

create or replace function public.fn_proposta_raiz_id_default()
returns trigger
language plpgsql
as $$
begin
  if new.proposta_raiz_id is null then
    new.proposta_raiz_id := new.id;
  end if;
  return new;
end;
$$;
comment on function public.fn_proposta_raiz_id_default() is 'Fase 2.4 seção 40: garante que toda proposta tem proposta_raiz_id preenchido (aponta pra si mesma se for uma v1 nova).';

drop trigger if exists trg_proposta_raiz_id_default on public.propostas_comerciais;
create trigger trg_proposta_raiz_id_default
  before insert on public.propostas_comerciais
  for each row execute function public.fn_proposta_raiz_id_default();

-- ============================================================================
-- 5) fn_proposta_snapshot_imutavel — confirma que numero_versao/proposta_raiz_id
--    continuam alteráveis livremente por quem tem permissão de UPDATE (só
--    snapshot/simulacao_id/pricing_version_id são congelados — sem mudança
--    necessária aqui, a trigger existente já só bloqueia essas 3 colunas).
-- ============================================================================
-- (nenhuma alteração necessária — documentado por clareza)

-- ============================================================================
-- 6) AUDITORIA SEMÂNTICA — 6 novas ações de propostas
-- ============================================================================

alter table public.auditoria drop constraint if exists auditoria_acao_check;
alter table public.auditoria add constraint auditoria_acao_check
  check (acao = any (array[
    'INSERT', 'UPDATE', 'DELETE', 'LOGIN',
    'ARCHIVE', 'RESTORE', 'BLOCKED_ARCHIVE', 'BLOCKED_DELETE',
    'PROPOSAL_APPROVE', 'PROPOSAL_REJECT', 'PROPOSAL_STATUS_CHANGE',
    'PROPOSAL_VERSION_CREATE', 'PROPOSAL_DUPLICATE', 'PROPOSAL_EXPORT'
  ]));
