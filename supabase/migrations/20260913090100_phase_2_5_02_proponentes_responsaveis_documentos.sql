-- OptiMon — Fase 2.5 (2/9): Proponentes + Responsáveis + Documentos (seções 16-19).
--
-- DECISÃO DE ARQUITETURA (documentada também em docs/ARQUITETURA.md, seção 23):
-- "Proponente" (seção 16 do prompt-mestre) é, por definição, "a empresa/organização
-- que receberá a proposta e poderá celebrar o contrato" — exatamente o que a tabela
-- `parceiros` já representa desde a Fase 1 (propostas_comerciais.parceiro_id,
-- contratos.parceiro_id). Criar uma tabela `proponentes` nova, paralela a `parceiros`,
-- duplicaria a mesma entidade sob dois nomes — violando a instrução explícita da
-- seção 1 ("Não criar tabelas ou funcionalidades duplicadas"). Em vez disso:
-- `parceiros` ganha os campos cadastrais que a seção 16 pede e ainda não existiam
-- (Inscrição Estadual/Municipal, endereço completo, site, observações — Razão
-- Social/Nome Fantasia/CNPJ/E-mail/Telefone/Status já existiam desde a Fase 1).
-- `proponentes_responsaveis` e a extensão de `documentos` (abaixo) são o que
-- realmente não existia.

alter table public.parceiros
  add column if not exists inscricao_estadual text,
  add column if not exists inscricao_municipal text,
  add column if not exists endereco_logradouro text,
  add column if not exists endereco_numero text,
  add column if not exists endereco_complemento text,
  add column if not exists endereco_bairro text,
  add column if not exists endereco_cidade text,
  add column if not exists endereco_uf char(2),
  add column if not exists endereco_cep text,
  add column if not exists site text,
  add column if not exists observacoes text;

comment on column public.parceiros.inscricao_estadual is 'Fase 2.5 seção 16.';
comment on column public.parceiros.inscricao_municipal is 'Fase 2.5 seção 16.';
comment on column public.parceiros.site is 'Fase 2.5 seção 16.';

-- ============================================================================
-- 1) RESPONSÁVEIS (seção 17) — vários por proponente (parceiro)
-- ============================================================================

create table if not exists public.parceiros_responsaveis (
  id uuid primary key default gen_random_uuid(),
  parceiro_id uuid not null references public.parceiros(id) on delete restrict,
  nome text not null,
  cpf text,
  cargo text,
  departamento text,
  email text,
  telefone text,
  whatsapp text,
  tipo text not null check (tipo = any (array[
    'REPRESENTANTE_LEGAL', 'RESPONSAVEL_COMERCIAL', 'RESPONSAVEL_FINANCEIRO',
    'RESPONSAVEL_TECNICO', 'TESTEMUNHA', 'OUTRO'
  ])),
  representante_legal boolean not null default false,
  -- seção 18: indicar representante legal não implica automaticamente que ele TEM
  -- poderes — o documento que comprova isso (Contrato Social/Procuração/Ata) é
  -- registrado separadamente em `documentos`, nunca inferido daqui.
  documento_comprobatorio_id uuid,
  ativo boolean not null default true,
  removido_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

comment on table public.parceiros_responsaveis is 'Fase 2.5 seção 17: pessoas vinculadas a um proponente (parceiro) — representante legal, comercial, financeiro, técnico ou testemunha. "representante_legal=true" é só um indicador de papel; poder de fato só é atestado por um documento em `documentos` (seção 18).';
comment on column public.parceiros_responsaveis.documento_comprobatorio_id is 'Fase 2.5 seção 18: aponta para o documento (Contrato Social/Procuração/Ata) que comprova o poder de representação — FK adicionada depois de `documentos` existir, abaixo.';

create index if not exists parceiros_responsaveis_parceiro_idx on public.parceiros_responsaveis(parceiro_id) where removido_em is null;

alter table public.parceiros_responsaveis enable row level security;

drop policy if exists parceiros_responsaveis_select on public.parceiros_responsaveis;
create policy parceiros_responsaveis_select
  on public.parceiros_responsaveis for select
  to authenticated
  using (true);

drop policy if exists parceiros_responsaveis_write on public.parceiros_responsaveis;
create policy parceiros_responsaveis_write
  on public.parceiros_responsaveis for all
  to authenticated
  using (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'))
  with check (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'));

create trigger trg_parceiros_responsaveis_atualizado_em
  before update on public.parceiros_responsaveis
  for each row execute function public.set_atualizado_em();

create trigger trg_aud_parceiros_responsaveis
  after insert or delete or update on public.parceiros_responsaveis
  for each row execute function public.fn_auditoria();

-- ============================================================================
-- 2) DOCUMENTOS (seção 19) — reaproveitando a tabela `documentos` já existente
--    desde a Fase 2 (contrato_id/parceiro_id/tipo/titulo/versao/storage_path/
--    criado_por/criado_em já existiam) em vez de criar uma tabela nova.
-- ============================================================================

alter table public.documentos
  add column if not exists proponente_documento boolean not null default false,
  add column if not exists status text not null default 'VIGENTE',
  add column if not exists responsavel_id uuid references public.parceiros_responsaveis(id) on delete set null;

alter table public.documentos drop constraint if exists documentos_status_check;
alter table public.documentos add constraint documentos_status_check
  check (status = any (array['VIGENTE', 'SUBSTITUIDO', 'REMOVIDO']));

alter table public.documentos drop constraint if exists documentos_tipo_check;
alter table public.documentos add constraint documentos_tipo_check
  check (tipo = any (array[
    'PROPOSTA', 'CONTRATO_ASSINADO', 'ADITIVO', 'ANEXO', 'OUTRO',
    'CONTRATO_SOCIAL', 'CARTAO_CNPJ', 'PROCURACAO', 'ATA'
  ]));

comment on column public.documentos.proponente_documento is 'Fase 2.5 seção 19: true quando o documento pertence ao cadastro do proponente (parceiro_id preenchido, contrato_id nulo) — Contrato Social/CNPJ/Procuração/Ata/Outros.';
comment on column public.documentos.status is 'Fase 2.5 seção 19: VIGENTE/SUBSTITUIDO/REMOVIDO — nunca DELETE físico (mesma disciplina de exclusão lógica das Fases 2.3/2.3.1).';

alter table public.parceiros_responsaveis
  add constraint parceiros_responsaveis_documento_comprobatorio_fkey
  foreign key (documento_comprobatorio_id) references public.documentos(id) on delete set null;

-- documentos_write já existe (COMERCIAL/DIRETOR/ADMINISTRADOR) e cobre os
-- documentos de proponente também — mesma policy, sem necessidade de nova.
