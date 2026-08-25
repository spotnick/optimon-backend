-- OptiMon — Fase 1.1
-- Aditivos contratuais (seção 11): contrato começa com 1 porta/fibra e cresce por
-- aditivos, sempre com histórico. Aditivo aprovado NUNCA altera o contrato original
-- silenciosamente — gera automaticamente uma nova contrato_versions.

create table public.contrato_aditivos (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  numero integer not null,
  tipo text not null check (tipo in (
    'INCLUSAO_FIBRA', 'INCLUSAO_PORTA', 'EXCLUSAO_FIBRA', 'EXCLUSAO_PORTA',
    'ALTERACAO_PRAZO', 'ALTERACAO_COMERCIAL', 'OUTRO'
  )),
  descricao text not null,
  data date not null default current_date,
  inicio_vigencia date,
  fim_vigencia date,
  status text not null default 'RASCUNHO' check (status in ('RASCUNHO', 'EM_APROVACAO', 'APROVADO', 'REJEITADO')),
  snapshot_anterior jsonb,
  snapshot_novo jsonb,
  aprovado_por uuid references public.usuarios(id),
  aprovado_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (contrato_id, numero),
  check (status <> 'APROVADO' or aprovado_por is not null)
);
create index contrato_aditivos_contrato_idx on public.contrato_aditivos (contrato_id);
create trigger trg_contrato_aditivos_atualizado_em
  before update on public.contrato_aditivos
  for each row execute function public.set_atualizado_em();

comment on table public.contrato_aditivos is 'Histórico de inclusão/exclusão de fibras/portas e outras alterações pós-assinatura (seção 11). Nunca sobrescreve o contrato original — sempre gera nova contrato_versions ao ser aprovado.';

-- Ao aprovar um aditivo, gera automaticamente a próxima contrato_versions e incrementa
-- contratos.versao_atual — reforça a governança da seção 37 também para o caminho de aditivo.
create or replace function public.fn_aditivo_gera_versao()
returns trigger
language plpgsql
as $$
declare
  v_nova_versao integer;
begin
  if new.status = 'APROVADO' and (TG_OP = 'INSERT' or old.status <> 'APROVADO') then
    update public.contratos
      set versao_atual = versao_atual + 1
      where id = new.contrato_id
      returning versao_atual into v_nova_versao;

    insert into public.contrato_versions (contrato_id, versao, motivo, snapshot, criado_por)
    values (
      new.contrato_id,
      v_nova_versao,
      'ADITIVO ' || new.numero || ' — ' || new.tipo,
      jsonb_build_object('aditivo', to_jsonb(new), 'contrato', (select to_jsonb(c) from public.contratos c where c.id = new.contrato_id)),
      new.aprovado_por
    );
  end if;
  return new;
end;
$$;

create trigger trg_aditivo_gera_versao
  after insert or update on public.contrato_aditivos
  for each row execute function public.fn_aditivo_gera_versao();
