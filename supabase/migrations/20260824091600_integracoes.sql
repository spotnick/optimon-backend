-- OptiMon — Fase 1
-- Configuração de integrações externas (HubSoft, financeiro do parceiro, etc.) e logs.

create table public.integracoes (
  id uuid primary key default gen_random_uuid(),
  parceiro_id uuid references public.parceiros(id) on delete cascade,
  nome text not null,
  tipo integracao_tipo not null,
  endpoint text,
  credenciais_criptografadas bytea,
  frequencia text,
  campos_mapeados jsonb,
  status integracao_status not null default 'ATIVA',
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create trigger trg_integracoes_atualizado_em
  before update on public.integracoes
  for each row execute function public.set_atualizado_em();

comment on table public.integracoes is 'Config por parceiro/integração: REST API, Webhook ou SFTP/CSV. Credenciais sempre criptografadas — nunca texto puro (seção 18).';

create table public.integracao_logs (
  id uuid primary key default gen_random_uuid(),
  integracao_id uuid not null references public.integracoes(id) on delete cascade,
  executado_em timestamptz not null default now(),
  sucesso boolean not null,
  duracao_ms integer,
  registros_processados integer,
  erro_detalhe text,
  payload_resumo jsonb
);
create index integracao_logs_integracao_idx on public.integracao_logs (integracao_id, executado_em desc);
