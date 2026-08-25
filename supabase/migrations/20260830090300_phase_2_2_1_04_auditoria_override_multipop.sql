-- OptiMon — Fase 2.2.1: Ajuste Final de Governança + Precificação por Porta PON
-- Migration 4/4: auditoria detalhada do override (seção 15) + verificação de Multi-POP
-- consolidado (seção 23/24/39 — os cálculos por POP e por cidade já não duplicam
-- infraestrutura desde a Fase 2.2/TESTE-13; esta migration só fecha as colunas de
-- rastreabilidade do override que ainda faltavam).
--
-- ESCOPO (seção 15) — campos pedidos vs. o que já existia em pricing_override_requests
-- desde a Fase 2.2:
--   opportunity_id  -> mapeado para contrato_id (já existia). OptiMon não tem uma entidade
--                      "oportunidade" separada de CRM; contrato_id é o identificador de
--                      negócio disponível. Simplificação deliberada, documentada aqui e no
--                      relatório de entrega.
--   contract_id     -> contrato_id (já existia).
--   city_id         -> NOVO nesta migration: cidade_id (snapshot).
--   pop_id          -> NOVO nesta migration.
--   requested/approved/opening/recommended/floor prices
--                   -> preco_solicitado, preco_recomendado, preco_abertura, preco_piso já
--                      existiam (Fase 2.2). "approved price" É preco_solicitado quando
--                      status='APROVADA' (o sistema não permite aprovar um valor diferente
--                      do solicitado — aprovação é binária: aprova o que foi pedido, ou
--                      rejeita). Documentado no relatório para não sugerir um campo
--                      "preco_aprovado" redundante.
--   discount amount/percent
--                   -> desconto_percentual (generated) já existia; desconto_absoluto (em
--                      R$) é NOVO nesta migration.
--   requested_by/approved_by/approved_at
--                   -> solicitado_por, decidido_por, decidido_em já existiam (decidido_por/
--                      decidido_em cobrem tanto aprovação quanto rejeição — "approved_at"
--                      quando status='APROVADA', "rejected_at" quando status='REJEITADA';
--                      um único par de colunas, sem duplicar por status).
--   reason          -> justificativa já existia.
--   status          -> status já existia.
--   "nunca apagar registros de override"
--                   -> já garantido estruturalmente desde a Fase 2.2: não existe policy de
--                      DELETE em pricing_override_requests (RLS nega implicitamente).
--                      Reverificado nesta fase (seção 5 do relatório) sem necessidade de
--                      nova migration.

-- 1) Colunas novas de rastreabilidade (seção 15).
alter table public.pricing_override_requests
  add column if not exists cidade_id uuid references public.cidades_infra(id),
  add column if not exists pop_id uuid references public.infra_pops(id);

alter table public.pricing_override_requests
  add column if not exists desconto_absoluto numeric(12,2)
    generated always as (preco_recomendado - preco_solicitado) stored;

comment on column public.pricing_override_requests.cidade_id is 'Fase 2.2.1 (seção 15): snapshot da cidade do contrato no momento da solicitação — resolvido no servidor a partir de contratos.cidade_id (nunca informado pelo cliente), para nunca divergir do contrato real.';
comment on column public.pricing_override_requests.pop_id is 'Fase 2.2.1 (seção 15/23): POP específico do override, quando a negociação é por POP (Multi-POP). Opcional — nulo quando o override é no nível da cidade (POP único ou negociação consolidada).';
comment on column public.pricing_override_requests.desconto_absoluto is 'Fase 2.2.1 (seção 15): desconto solicitado em R$ (preco_recomendado - preco_solicitado) — complementa desconto_percentual (Fase 2.2), que é relativo.';

-- Backfill: overrides já existentes (Fase 2.2, antes de cidade_id/pop_id existirem) ganham
-- cidade_id resolvido retroativamente a partir do contrato — nunca perdem rastreabilidade;
-- pop_id fica nulo (não havia essa granularidade quando foram criados, e não há como
-- inferir com segurança qual POP estava em negociação).
--
-- trg_override_decisao bloqueia QUALQUER UPDATE em uma linha já decidida (imutabilidade —
-- seção 15: "nunca apagar/alterar registros de override" aplicado desde a Fase 2.2 a toda
-- a linha, não só ao status), então este backfill administrativo (preencher só a NOVA
-- coluna cidade_id, sem tocar status/preços/decisão) precisa desabilitar o trigger
-- momentaneamente. Isto é só para este backfill de migração — o comportamento em runtime
-- da aplicação (imutabilidade de decisões já tomadas) continua idêntico depois daqui, o
-- trigger é reabilitado logo em seguida.
alter table public.pricing_override_requests disable trigger trg_override_decisao;

update public.pricing_override_requests r
   set cidade_id = c.cidade_id
  from public.contratos c
 where r.contrato_id = c.id
   and r.cidade_id is null;

alter table public.pricing_override_requests enable trigger trg_override_decisao;

-- 2) public.pricing_override_create(): DROP + CREATE (assinatura muda — novo parâmetro
-- final p_pop_id) para evitar o bug de ambiguidade de overload já visto na Fase 2.2
-- (dois pricing_override_create coexistindo com aridades diferentes deixaria chamadas
-- antigas ambíguas). cidade_id é sempre resolvido no servidor a partir do contrato —
-- nunca aceito como parâmetro — mesma filosofia de "papel/role nunca informado pelo
-- cliente" já aplicada à governança (seção 12/35).
drop function if exists public.pricing_override_create(uuid, uuid, numeric, numeric, text, numeric, numeric);

create or replace function public.pricing_override_create(
  p_contrato_id uuid,
  p_simulacao_id uuid,
  p_preco_recomendado numeric,
  p_preco_solicitado numeric,
  p_justificativa text,
  p_preco_piso numeric default null,
  p_preco_abertura numeric default null,
  p_pop_id uuid default null
)
returns uuid
language plpgsql
as $function$
declare
  v_id uuid;
  v_cidade_id uuid;
  v_pop_cidade_id uuid;
begin
  select cidade_id into v_cidade_id from public.contratos where id = p_contrato_id;
  if v_cidade_id is null then
    raise exception 'Contrato % não encontrado (ou sem cidade associada).', p_contrato_id;
  end if;

  if p_pop_id is not null then
    select cidade_id into v_pop_cidade_id from public.infra_pops where id = p_pop_id and removido_em is null;
    if v_pop_cidade_id is null then
      raise exception 'POP % não encontrado.', p_pop_id;
    end if;
    if v_pop_cidade_id <> v_cidade_id then
      raise exception 'POP % não pertence à cidade do contrato % (POP é da cidade %, contrato é da cidade %).', p_pop_id, p_contrato_id, v_pop_cidade_id, v_cidade_id;
    end if;
  end if;

  insert into public.pricing_override_requests
    (contrato_id, simulacao_id, preco_recomendado, preco_solicitado, justificativa, preco_piso, preco_abertura, cidade_id, pop_id)
  values
    (p_contrato_id, p_simulacao_id, p_preco_recomendado, p_preco_solicitado, p_justificativa, p_preco_piso, p_preco_abertura, v_cidade_id, p_pop_id)
  returning id into v_id;

  return v_id;
end;
$function$;
comment on function public.pricing_override_create(uuid, uuid, numeric, numeric, text, numeric, numeric, uuid) is 'Fase 2.2 (base) + Fase 2.2.1 (seção 15: adiciona p_pop_id opcional; cidade_id é sempre resolvido no servidor a partir do contrato, nunca informado pelo cliente). Cria uma solicitação de override de preço, sempre nascendo PENDENTE (trigger trg_override_nasce_pendente).';

-- 3) Multi-POP consolidado: NENHUMA mudança de função necessária aqui — a não-duplicação
-- (seção 23/24/39) já é garantida por construção desde a Fase 2.2 (TESTE-13 de
-- run_tests_fase22.sh): calculate_infrastructure_floor_by_pop() lê infra_pops.km_rede /
-- infra_pops.postes_count (colunas próprias, preenchidas manualmente por POP quando a
-- cidade tem Multi-POP), enquanto calculate_city_infrastructure_floor() lê
-- cidades_infra.km_rede / soma(infra_postes.quantidade) — duas fontes de dado
-- independentes, nunca somadas uma com a outra em nenhuma função. A suíte de testes da
-- Fase 2.2.1 (run_tests_fase221.sh) adiciona um cenário próprio com PONs por POP
-- (POP-01/02/03) para confirmar que essa garantia se mantém agora que o Floor inclui o
-- componente PON.
