-- OptiMon — Fase 3.8 (item 3.8-11): registro formal de equipamentos cedidos
-- (OLT/ONU/ONT/fontes/switches) — distinção entre infraestrutura permanente (fibra,
-- cabos, postes, portas PON: NUNCA "devolvida", propriedade da NICK por definição) e
-- equipamento cedido (ativos: OLT/ONU/ONT/fonte/switch — ESSES SIM são devolvidos ou
-- indenizados ao fim do contrato).
--
-- ESTADO ANTES DESTA MIGRATION: public.ativos e public.ativos_devolucao já existiam
-- desde a Fase 1 (seção 26), com RLS correta (ENGENHARIA/ADMINISTRADOR) — mas, como
-- contrato_regras_solicitacoes antes da migration anterior, eram tabelas MORTAS: 0 rotas
-- de API, 0 tela de frontend (confirmado por grep). Só apareciam em modo LEITURA (GET
-- /api/contracts/:id e a cláusula "Ativos e Equipamentos" da minuta) — nunca havia como
-- de fato cadastrar um equipamento, vinculá-lo a um contrato, ou processar uma devolução.
-- Além disso, o enum de tipo de ativo (`tipo in ('OLT','ONU','SWITCH','ROTEADOR','OUTRO')`)
-- não cobria 2 dos itens explicitamente pedidos: ONT (Optical Network Terminal, distinto
-- de ONU) e FONTE (fonte de alimentação) — ambos caiam em 'OUTRO', perdendo
-- rastreabilidade formal por tipo.
--
-- ESTA MIGRATION:
--   1) Amplia o check constraint de tipo para incluir ONT e FONTE.
--   2) Adiciona auditoria (trg_aud_ativos_devolucao) — existia para `ativos` desde a Fase
--      1 mas nunca foi criada para `ativos_devolucao` (gap pré-existente).
--   3) fn_ativo_devolucao_aplica_status(): ao confirmar uma devolução (data_devolucao
--      preenchida), aplica automaticamente o status final (DEVOLVIDO ou PERDIDO) no
--      ativo correspondente — a API/frontend nunca precisam (nem devem) atualizar as
--      duas tabelas manualmente em 2 chamadas separadas, o que arriscaria ficarem
--      dessincronizadas.
--   4) Coluna `status_final` em ativos_devolucao (DEVOLVIDO/PERDIDO) — quem confirma a
--      devolução decide explicitamente qual dos dois é o desfecho real.

alter table public.ativos drop constraint ativos_tipo_check;
alter table public.ativos add constraint ativos_tipo_check
  check (tipo in ('OLT', 'ONU', 'ONT', 'FONTE', 'SWITCH', 'ROTEADOR', 'OUTRO'));
comment on column public.ativos.tipo is 'Fase 3.8 (item 3.8-11): OLT/ONU/ONT/FONTE/SWITCH/ROTEADOR/OUTRO — equipamento CEDIDO (comodato/locação), sempre devolvido ou indenizado ao fim do contrato. Nunca confundir com infraestrutura permanente (fibra/cabo/poste/porta PON — public.contrato_fibras), que nunca é "devolvida", é propriedade da NICK por definição.';

create trigger trg_aud_ativos_devolucao
  after insert or update or delete on public.ativos_devolucao
  for each row execute function public.fn_auditoria();

alter table public.ativos_devolucao
  add column status_final text check (status_final in ('DEVOLVIDO', 'PERDIDO'));
comment on column public.ativos_devolucao.status_final is 'Preenchido junto com data_devolucao ao confirmar a devolução — aplica automaticamente ativos.status (ver fn_ativo_devolucao_aplica_status).';

create or replace function public.fn_ativo_devolucao_aplica_status()
returns trigger
language plpgsql
as $$
begin
  if new.data_devolucao is not null and old.data_devolucao is null then
    if new.status_final is null then
      raise exception 'VALIDATION: status_final (DEVOLVIDO ou PERDIDO) é obrigatório ao confirmar data_devolucao.';
    end if;
    update public.ativos set status = new.status_final::ativo_status where id = new.ativo_id;
    -- BUG PRÉ-EXISTENTE (mesma classe do já corrigido em contrato_regras_solicitacoes.
    -- solicitado_por, migration anterior): registrado_por nunca era carimbado desde a
    -- Fase 1 — ficava sempre null a menos que o cliente o enviasse manualmente (nenhuma
    -- rota jamais existiu para enviar). Carimba quem CONFIRMOU a devolução.
    if new.registrado_por is null then
      new.registrado_por := auth.uid();
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_ativo_devolucao_aplica_status
  before update on public.ativos_devolucao
  for each row execute function public.fn_ativo_devolucao_aplica_status();

comment on function public.fn_ativo_devolucao_aplica_status() is 'Fase 3.8 (item 3.8-11): ao confirmar uma devolução (data_devolucao preenchida pela 1ª vez), aplica o status_final automaticamente em public.ativos — evita as 2 tabelas ficarem dessincronizadas por uma atualização manual esquecida.';
