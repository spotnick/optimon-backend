-- OptiMon — Fase 1.1
-- Exclusividade precisa de escopo explícito (seção 14) — nunca "cidade inteira" por
-- default. E o direito do proprietário de explorar capacidade remanescente / permitir
-- outros parceiros precisa ser parametrizável por contrato (seção 18).

alter table public.contrato_regras
  add column exclusividade_cidade_id uuid references public.cidades_infra(id) on delete restrict,
  add column exclusividade_pop_id uuid references public.infra_pops(id) on delete restrict,
  add column exclusividade_servico text,
  add column exclusividade_capacidade_max integer check (exclusividade_capacidade_max is null or exclusividade_capacidade_max >= 0),
  add column exclusividade_prazo_meses integer check (exclusividade_prazo_meses is null or exclusividade_prazo_meses > 0),
  add column direito_proprietario_explorar_capacidade_remanescente boolean not null default true,
  add column permite_outros_parceiros boolean not null default true;

-- Exclusividade sem nenhum escopo definido é o erro que a seção 14 quer evitar:
-- não pode significar "toda a cidade" implicitamente por omissão.
alter table public.contrato_regras
  add constraint contrato_regras_exclusividade_precisa_escopo
  check (
    exclusividade_comercial = false
    or area_exclusividade is not null
    or exclusividade_cidade_id is not null
    or exclusividade_pop_id is not null
  );

comment on column public.contrato_regras.exclusividade_pop_id is 'Quando definido, a exclusividade vale só para este POP — não para toda exclusividade_cidade_id (seção 14: "não assumir que contratar uma fibra dá exclusividade sobre toda a cidade").';
comment on column public.contrato_regras.direito_proprietario_explorar_capacidade_remanescente is 'Se true (padrão), o proprietário pode seguir explorando capacidade não comprometida por este contrato mesmo havendo exclusividade (seção 18).';
comment on column public.contrato_regras.permite_outros_parceiros is 'Se true (padrão), o proprietário pode contratar outros parceiros na área/POP não coberta pela exclusividade deste contrato, sujeito a checkContractConflict (seção 19).';
