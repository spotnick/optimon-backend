-- OptiMon — Fase 2.5 (4/9): Signature Engine — schema (seções 2-13, 26-28, 43).
--
-- PRINCÍPIO ICP-BRASIL FIRST (seção 2): o OptiMon é o ORQUESTRADOR do processo de
-- assinatura, nunca uma Autoridade Certificadora nem uma infraestrutura
-- criptográfica própria. Estas tabelas armazenam apenas o que o orquestrador
-- precisa controlar (seção 3): documento/versão/signatários/ordem/status/envio/
-- acompanhamento/retorno/evidências/auditoria/validação/armazenamento — nunca
-- uma chave privada, nunca um certificado .PFX, nunca uma senha de certificado
-- (seção 8). `signature_providers.api_key_ref`/`webhook_secret_ref` armazenam só
-- o NOME da variável de ambiente onde o segredo real vive no Railway — nunca o
-- valor — seguindo a mesma disciplina de nunca versionar/armazenar segredo real
-- já aplicada ao resto do projeto.

-- ============================================================================
-- 1) PROVEDORES (seção 6) — abstração de fornecedor (seção 4/5)
-- ============================================================================

create table if not exists public.signature_providers (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique,
  tipo text not null check (tipo = any (array['ICP_BRASIL_HOMOLOGACAO_MOCK', 'ICP_BRASIL_PROVEDOR_EXTERNO'])),
  papel text not null default 'PRINCIPAL' check (papel = any (array['PRINCIPAL', 'SECUNDARIO'])),
  ambiente text not null default 'HOMOLOGACAO' check (ambiente = any (array['HOMOLOGACAO', 'PRODUCAO'])),
  api_url text,
  api_key_ref text,
  webhook_url text,
  webhook_secret_ref text,
  timeout_segundos integer not null default 30 check (timeout_segundos > 0),
  politica_assinatura text not null default 'ICP_BRASIL_QUALIFICADA' check (politica_assinatura = any (array['ICP_BRASIL_QUALIFICADA'])),
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

comment on table public.signature_providers is 'Fase 2.5 seções 4-6, 50: configuração do(s) provedor(es) ICP-Brasil — nunca guarda segredo real, só a referência (nome da env var) de onde ele vem no Railway. "papel" permite PRINCIPAL + SECUNDARIO (seção 50) sem exigir integrar os dois nesta fase.';
comment on column public.signature_providers.api_key_ref is 'Nome da variável de ambiente (ex.: SIGNATURE_PROVIDER_API_KEY) — nunca o valor da credencial em si.';
comment on column public.signature_providers.webhook_secret_ref is 'Nome da variável de ambiente do segredo de validação do webhook — nunca o valor.';
comment on column public.signature_providers.politica_assinatura is 'Fase 2.5 seção 7: para contrato de cessão de uso, ICP-Brasil qualificada é a ÚNICA opção — CHECK só permite esse valor até que o jurídico da NICK aprove outra política para outro tipo de documento.';

alter table public.signature_providers enable row level security;

drop policy if exists signature_providers_select on public.signature_providers;
create policy signature_providers_select
  on public.signature_providers for select
  to authenticated
  using (true);

drop policy if exists signature_providers_write on public.signature_providers;
create policy signature_providers_write
  on public.signature_providers for all
  to authenticated
  using (app.tem_perfil('ADMINISTRADOR', 'DIRETOR'))
  with check (app.tem_perfil('ADMINISTRADOR', 'DIRETOR'));

comment on policy signature_providers_write on public.signature_providers is 'Fase 2.5 seção 7/57: só ADMINISTRADOR/DIRETOR podem alterar provedor/política de assinatura — nunca COMERCIAL.';

create trigger trg_signature_providers_atualizado_em
  before update on public.signature_providers
  for each row execute function public.set_atualizado_em();

create trigger trg_aud_signature_providers
  after insert or delete or update on public.signature_providers
  for each row execute function public.fn_auditoria();

-- ============================================================================
-- 2) ENVELOPES (seção 26, 43 "propostas_assinaturas"/"contratos_assinaturas")
--
-- Um único envelope de assinatura serve proposta, contrato OU aditivo — em vez
-- de 3 tabelas de "assinaturas" quase idênticas (uma por tipo de documento), o
-- que seria justamente a duplicação que a seção 1 proíbe. `tipo_documento` +
-- exatamente um dos 3 FKs preenchido é o que diferencia "propostas_assinaturas"
-- de "contratos_assinaturas" do desenho conceitual da seção 43 — documentado
-- aqui e em docs/ARQUITETURA.md em vez de existir como tabela separada.
-- ============================================================================

create table if not exists public.signature_envelopes (
  id uuid primary key default gen_random_uuid(),
  tipo_documento text not null check (tipo_documento = any (array['PROPOSTA', 'CONTRATO', 'ADITIVO'])),
  proposta_id uuid references public.propostas_comerciais(id) on delete restrict,
  contrato_id uuid references public.contratos(id) on delete restrict,
  aditivo_id uuid references public.contrato_aditivos(id) on delete restrict,
  provider_id uuid not null references public.signature_providers(id) on delete restrict,
  provider_envelope_id text,
  status text not null default 'CRIADO' check (status = any (array[
    'CRIADO', 'ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO', 'ASSINADO',
    'VALIDADO', 'RECUSADO', 'CANCELADO', 'EXPIRADO', 'ERRO'
  ])),
  documento_original_storage_path text,
  documento_assinado_storage_path text,
  hash_original text,
  hash_assinado text,
  politica_assinatura text not null default 'ICP_BRASIL_QUALIFICADA',
  erro_mensagem text,
  criado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  enviado_em timestamptz,
  concluido_em timestamptz,
  cancelado_em timestamptz,
  constraint signature_envelopes_um_documento_apenas check (
    (case when proposta_id is not null then 1 else 0 end
     + case when contrato_id is not null then 1 else 0 end
     + case when aditivo_id is not null then 1 else 0 end) = 1
  )
);

comment on table public.signature_envelopes is 'Fase 2.5 seção 26/43: um envelope por documento enviado à assinatura — cobre propostas_assinaturas E contratos_assinaturas do desenho conceitual (seção 43) através de tipo_documento, para não duplicar tabela por tipo de documento.';

create index if not exists signature_envelopes_proposta_idx on public.signature_envelopes(proposta_id);
create index if not exists signature_envelopes_contrato_idx on public.signature_envelopes(contrato_id);
create index if not exists signature_envelopes_aditivo_idx on public.signature_envelopes(aditivo_id);
create index if not exists signature_envelopes_status_idx on public.signature_envelopes(status);

alter table public.signature_envelopes enable row level security;

drop policy if exists signature_envelopes_select on public.signature_envelopes;
create policy signature_envelopes_select
  on public.signature_envelopes for select
  to authenticated
  using (true);

drop policy if exists signature_envelopes_insert on public.signature_envelopes;
create policy signature_envelopes_insert
  on public.signature_envelopes for insert
  to authenticated
  with check (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'));

drop policy if exists signature_envelopes_update on public.signature_envelopes;
create policy signature_envelopes_update
  on public.signature_envelopes for update
  to authenticated
  using (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'))
  with check (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'));

create trigger trg_signature_envelopes_atualizado_em
  before update on public.signature_envelopes
  for each row execute function public.set_atualizado_em();

create trigger trg_aud_signature_envelopes
  after insert or delete or update on public.signature_envelopes
  for each row execute function public.fn_auditoria();

-- ============================================================================
-- 3) SIGNATÁRIOS (seção 25/26)
-- ============================================================================

create table if not exists public.signature_signers (
  id uuid primary key default gen_random_uuid(),
  envelope_id uuid not null references public.signature_envelopes(id) on delete cascade,
  nome text not null,
  email text not null,
  cpf text,
  papel text not null check (papel = any (array['REPRESENTANTE_NICK', 'REPRESENTANTE_PROPONENTE', 'TESTEMUNHA', 'OUTRO'])),
  ordem integer not null default 1 check (ordem > 0),
  responsavel_id uuid references public.parceiros_responsaveis(id) on delete set null,
  status text not null default 'PENDENTE' check (status = any (array[
    'PENDENTE', 'ENVIADO', 'VISUALIZADO', 'ASSINADO', 'RECUSADO'
  ])),
  provider_signer_id text,
  assinado_em timestamptz,
  ip_assinatura text,
  certificado_info jsonb,
  criado_em timestamptz not null default now()
);

comment on table public.signature_signers is 'Fase 2.5 seção 25/26: signatários de um envelope, com papel e ordem de assinatura configuráveis (seção 25 — "a quantidade e os papéis devem ser configuráveis").';
comment on column public.signature_signers.certificado_info is 'Fase 2.5 seção 6 (getCertificateInfo): metadados do certificado ICP-Brasil retornados pelo provedor após a assinatura — nunca a chave/certificado em si.';

create index if not exists signature_signers_envelope_idx on public.signature_signers(envelope_id, ordem);

alter table public.signature_signers enable row level security;

drop policy if exists signature_signers_select on public.signature_signers;
create policy signature_signers_select
  on public.signature_signers for select
  to authenticated
  using (true);

drop policy if exists signature_signers_write on public.signature_signers;
create policy signature_signers_write
  on public.signature_signers for all
  to authenticated
  using (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'))
  with check (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'));

create trigger trg_aud_signature_signers
  after insert or delete or update on public.signature_signers
  for each row execute function public.fn_auditoria();

-- ============================================================================
-- 4) EVENTOS (webhook, seção 27) — a chave de idempotência é o par
--    (envelope_id, evento_externo_id): o mesmo evento do provedor nunca gera
--    duas linhas, mesmo que o webhook seja entregue mais de uma vez.
-- ============================================================================

create table if not exists public.signature_events (
  id uuid primary key default gen_random_uuid(),
  envelope_id uuid not null references public.signature_envelopes(id) on delete cascade,
  evento_externo_id text not null,
  tipo_evento text not null,
  payload jsonb,
  processado boolean not null default false,
  recebido_em timestamptz not null default now(),
  unique (envelope_id, evento_externo_id)
);

comment on table public.signature_events is 'Fase 2.5 seção 27/49: log de eventos do webhook do provedor. UNIQUE(envelope_id, evento_externo_id) é o mecanismo de idempotência — INSERT com ON CONFLICT DO NOTHING garante que um webhook duplicado nunca gera um segundo evento nem reaplica a mudança de status.';

create index if not exists signature_events_envelope_idx on public.signature_events(envelope_id);

alter table public.signature_events enable row level security;

drop policy if exists signature_events_select on public.signature_events;
create policy signature_events_select
  on public.signature_events for select
  to authenticated
  using (true);

-- Nenhuma policy de INSERT para `authenticated`: eventos de webhook só entram
-- via app.registrar_evento_assinatura_webhook() (SECURITY DEFINER, seção 5 da
-- migration seguinte) — o endpoint de webhook em si não é autenticado por JWT
-- de usuário (é uma chamada do provedor externo), então não faz sentido dar a
-- nenhum papel de `authenticated` o direito de inserir evento diretamente.

-- ============================================================================
-- 5) DOCUMENTO ASSINADO + EVIDÊNCIAS (seção 11/12/28)
-- ============================================================================

create table if not exists public.documentos_assinados (
  id uuid primary key default gen_random_uuid(),
  envelope_id uuid not null unique references public.signature_envelopes(id) on delete cascade,
  storage_path_original text,
  storage_path_assinado text,
  hash_sha256_original text,
  hash_sha256_assinado text,
  formato text not null default 'PDF',
  pades boolean not null default false,
  validado boolean not null default false,
  validado_em timestamptz,
  validado_por uuid references public.usuarios(id),
  resultado_validacao jsonb,
  criado_em timestamptz not null default now()
);

comment on table public.documentos_assinados is 'Fase 2.5 seção 11/12: preserva arquivo original + assinado + hash + resultado da validação. "validado" só vira true através de app.validar_assinatura() (seção 10/56) — nunca setado por um simples "status=ASSINADO" (seção 56: nunca tratar "Assinado" como sinônimo automático de "assinatura válida").';

alter table public.documentos_assinados enable row level security;

drop policy if exists documentos_assinados_select on public.documentos_assinados;
create policy documentos_assinados_select
  on public.documentos_assinados for select
  to authenticated
  using (true);

drop policy if exists documentos_assinados_write on public.documentos_assinados;
create policy documentos_assinados_write
  on public.documentos_assinados for all
  to authenticated
  using (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'))
  with check (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'));

create table if not exists public.documentos_evidencias (
  id uuid primary key default gen_random_uuid(),
  envelope_id uuid not null references public.signature_envelopes(id) on delete cascade,
  tipo text not null default 'RELATORIO_PROVEDOR',
  storage_path text,
  descricao text,
  criado_em timestamptz not null default now()
);

comment on table public.documentos_evidencias is 'Fase 2.5 seção 11/28: evidências fornecidas pelo provedor (relatório de auditoria do envelope, trilha de eventos, etc.) — preservadas mesmo que o provedor troque no futuro.';

alter table public.documentos_evidencias enable row level security;

drop policy if exists documentos_evidencias_select on public.documentos_evidencias;
create policy documentos_evidencias_select
  on public.documentos_evidencias for select
  to authenticated
  using (true);

drop policy if exists documentos_evidencias_write on public.documentos_evidencias;
create policy documentos_evidencias_write
  on public.documentos_evidencias for all
  to authenticated
  using (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'))
  with check (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'));
