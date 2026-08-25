-- OptiMon — Fase 1
-- Documentos (propostas, contratos assinados, aditivos) — arquivos ficam no Supabase Storage.

create table public.documentos (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid references public.contratos(id) on delete restrict,
  parceiro_id uuid references public.parceiros(id) on delete restrict,
  tipo text not null check (tipo in ('PROPOSTA','CONTRATO_ASSINADO','ADITIVO','ANEXO','OUTRO')),
  titulo text not null,
  versao integer not null default 1,
  storage_path text not null,
  validade date,
  criado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(),
  removido_em timestamptz
);
create index documentos_contrato_idx on public.documentos (contrato_id);

comment on table public.documentos is 'Metadados de documentos (proposta comercial, contrato assinado, aditivos). O binário vive no Supabase Storage; aqui só o caminho.';
