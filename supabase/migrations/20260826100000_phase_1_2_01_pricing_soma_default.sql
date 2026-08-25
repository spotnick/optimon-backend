-- OptiMon — Fase 1.2
-- Seções 2/3/6/21/23/24: SOMA passa a ser o modelo híbrido PADRÃO (mínimo + revenue
-- share), mas 100% parametrizável — nunca hard-coded no código/controller. MAX continua
-- disponível para contratos específicos. Não altera modelo_cobranca de nenhum contrato
-- já existente: só muda o DEFAULT usado em INSERTs futuros que não especificarem o
-- valor (ALTER COLUMN ... SET DEFAULT nunca reescreve linhas já gravadas).

alter table public.contrato_pricing_config
  alter column modelo_cobranca set default 'SOMA';

comment on column public.contrato_pricing_config.modelo_cobranca is 'MAX = Modelo A: cobrança = MAX(mensalidade mínima, revenue share). SOMA = Modelo B (PADRÃO a partir da Fase 1.2): cobrança = mensalidade mínima + revenue share. Contratos existentes mantêm o valor com que foram criados — este DEFAULT só vale para novos INSERTs sem valor explícito.';

-- Seção 6: reserva de porta não é gratuita por padrão — mínimo calculado sobre as portas
-- CONTRATADAS (não só as ativas). Parametrizável por contrato, nunca lógica fixa no código.
alter table public.contrato_pricing_config
  add column cobranca_portas_reservadas boolean not null default true;

comment on column public.contrato_pricing_config.cobranca_portas_reservadas is 'Se true (padrão), o mínimo financeiro é calculado sobre TODAS as portas PON contratadas (reservadas + ativas), não só as efetivamente ativas — reserva de capacidade não é gratuita (seção 6). Se false, permite negociar contratos especiais que cobram só pelas portas ativas.';

-- Seção 21: estrutura de preparação para o Pricing Engine da Fase 2 — apenas os campos,
-- sem lógica de cálculo além do que já existe (percentual_revenue_share, modelo_cobranca,
-- base_calculo_revenue_share, rampa_aplica_a já existiam desde a Fase 1.1). O Pricing
-- Engine definitivo (dark fiber completo, ROI, payback, simulação de cenários) fica para
-- a Fase 2 — aqui só preparamos onde esses valores vão morar.
alter table public.contrato_pricing_config
  add column preco_minimo_porta numeric(12,2) check (preco_minimo_porta is null or preco_minimo_porta >= 0),
  add column preco_recomendado_porta numeric(12,2) check (preco_recomendado_porta is null or preco_recomendado_porta >= 0),
  add column preco_premium_porta numeric(12,2) check (preco_premium_porta is null or preco_premium_porta >= 0);

comment on column public.contrato_pricing_config.preco_minimo_porta is 'Preparação Fase 2 (seção 21): faixa mínima de preço por porta para o Pricing Engine. Sem lógica de cálculo nesta fase — só estrutura.';
comment on column public.contrato_pricing_config.preco_recomendado_porta is 'Preparação Fase 2 (seção 21): faixa recomendada de preço por porta.';
comment on column public.contrato_pricing_config.preco_premium_porta is 'Preparação Fase 2 (seção 21): faixa premium de preço por porta.';

alter table public.contrato_pricing_config
  add constraint contrato_pricing_config_faixas_preco_coerentes
  check (
    preco_minimo_porta is null or preco_recomendado_porta is null or preco_minimo_porta <= preco_recomendado_porta
  );

-- Referência global do percentual de revenue share padrão (seção 2/23) — 12%, mas
-- só como parâmetro consultável, nunca hard-coded em função/trigger. O trigger abaixo
-- só o usa como fallback quando o contrato não informa percentual_revenue_share.
insert into public.pricing_parametros (chave, valor, unidade, descricao) values
  ('REVENUE_SHARE_PADRAO', 0.12, 'percentual', 'Percentual padrão de revenue share (seção 2/23) quando o contrato não define percentual_revenue_share explicitamente. Valores comuns aceitos pelo negócio: 5%, 8%, 10%, 12%, 15%, 20% — não há CHECK restringindo a esses valores, a decisão de faixa é comercial, não técnica.')
on conflict (chave) do nothing;

create or replace function public.fn_pricing_config_default_revenue_share()
returns trigger
language plpgsql
as $$
begin
  if new.percentual_revenue_share is null then
    select valor into new.percentual_revenue_share
    from public.pricing_parametros
    where chave = 'REVENUE_SHARE_PADRAO'
      and (vigente_ate is null or vigente_ate >= current_date);
  end if;
  return new;
end;
$$;

comment on function public.fn_pricing_config_default_revenue_share() is 'Preenche percentual_revenue_share a partir do parâmetro REVENUE_SHARE_PADRAO quando o contrato não informa um valor — mantém os 12% fora do código (seção 23), só como fallback de conveniência.';

create trigger trg_pricing_config_default_revenue_share
  before insert on public.contrato_pricing_config
  for each row execute function public.fn_pricing_config_default_revenue_share();

-- Seção 24: base do revenue share já era um enum parametrizável desde a Fase 1.1
-- (base_calculo_revenue_share: FATURAMENTO_BRUTO/FATURAMENTO_LIQUIDO/FATURAMENTO_ELEGIVEL,
-- default FATURAMENTO_BRUTO) — nada a mudar aqui, só reconfirmando o requisito.
comment on type public.base_calculo_revenue_share is 'FATURAMENTO_BRUTO (padrão) / FATURAMENTO_LIQUIDO / FATURAMENTO_ELEGIVEL — base do revenue share, sempre parametrizável por contrato (seção 24, criado na Fase 1.1).';
