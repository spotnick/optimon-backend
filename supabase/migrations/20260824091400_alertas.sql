-- OptiMon — Fase 1
-- Alertas do sistema (seção 32).

create table public.alertas (
  id uuid primary key default gen_random_uuid(),
  tipo alerta_tipo not null,
  severidade alerta_severidade not null default 'ATENCAO',
  contrato_id uuid references public.contratos(id) on delete set null,
  cidade_id uuid references public.cidades_infra(id) on delete set null,
  parceiro_id uuid references public.parceiros(id) on delete set null,
  titulo text not null,
  descricao text,
  resolvido boolean not null default false,
  resolvido_por uuid references public.usuarios(id),
  resolvido_em timestamptz,
  criado_em timestamptz not null default now()
);
create index alertas_nao_resolvidos_idx on public.alertas (tipo) where resolvido = false;
create index alertas_contrato_idx on public.alertas (contrato_id);

comment on table public.alertas is 'Alertas contratuais e operacionais: fim de carência, reajuste, Take-or-Pay quebrado, divergência HubSoft, capacidade excedida, cliente reservado, etc.';
