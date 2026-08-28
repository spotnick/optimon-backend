-- OptiMon — Fase 3, item 3.2 (auditoria de prazo contratual mínimo)
--
-- CONTEXTO: durante a auditoria do item 3.2 (prazo contratual mínimo de 48 meses vs.
-- horizontes analíticos de simulação 12/36/48/60), confirmou-se que a separação entre
-- "horizonte de simulação" e "prazo real do contrato" já está correta em todas as
-- camadas (frontend, API, jsonb da simulação, função de geração de contrato e CHECK
-- da tabela contratos — ver contratos_prazo_minimo em 20260824090700_contratos.sql).
--
-- Uma lacuna adjacente e menor foi encontrada, não relacionada à confusão
-- horizonte/prazo, mas à integridade da auditoria de exceções: `app.gerar_contrato_de_proposta`
-- já exige motivo (p_motivo_excecao_prazo) sempre que uma exceção de prazo mínimo é usada
-- (ver 20260922090000_phase_3_01_preco_proposto_correcao_critica.sql, linha ~219), mas
-- esse motivo nunca era persistido em lugar nenhum — a tabela public.contratos não tinha
-- coluna para isso. Como a RLS de public.contratos permite INSERT/UPDATE direto por
-- COMERCIAL/DIRETOR/ADMINISTRADOR (contratos_insert/contratos_update,
-- 20260824091900_rls_policies.sql e 20260825101300_rls_fase11.sql), um contrato com
-- prazo_minimo_excecao=true podia ser criado sem nenhum motivo auditável, mesmo que
-- viesse pela função (que já validava o motivo, mas não tinha onde gravá-lo) ou por
-- escrita direta.
--
-- CORREÇÃO (aditiva, sem remover nem alterar nenhuma regra existente):
-- 1. Nova coluna public.contratos.motivo_excecao_prazo (nullable).
-- 2. Novo CHECK: toda exceção de prazo mínimo (prazo_minimo_excecao=true) agora exige
--    um motivo não vazio também no nível do schema — reforça em SQL a mesma regra que
--    app.gerar_contrato_de_proposta já aplicava em runtime, e passa a valer também para
--    qualquer escrita direta via RLS.
-- 3. app.gerar_contrato_de_proposta (mesma assinatura, create or replace) passa a gravar
--    p_motivo_excecao_prazo na nova coluna — nenhuma outra linha da função foi alterada.

alter table public.contratos
  add column motivo_excecao_prazo text;

alter table public.contratos
  add constraint contratos_motivo_excecao_prazo
  check (
    prazo_minimo_excecao = false
    or (motivo_excecao_prazo is not null and trim(motivo_excecao_prazo) <> '')
  );

comment on column public.contratos.motivo_excecao_prazo is
  'Fase 3 (item 3.2): motivo obrigatório sempre que prazo_minimo_excecao=true — auditoria de por que o contrato ficou abaixo do prazo mínimo de 48 meses (seção 32).';

create or replace function app.gerar_contrato_de_proposta(p_proposta_id uuid, p_prazo_minimo_excecao boolean default false, p_motivo_excecao_prazo text default null)
returns public.contratos
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_prop public.propostas_comerciais;
  v_sim public.simulacoes;
  v_contrato public.contratos;
  v_numero text;
  v_modelo contrato_modelo;
  v_prazo integer;
  v_snapshot jsonb;
  v_revenue_share numeric;
  v_faturamento numeric;
  v_preco_negociado numeric;
begin
  if not app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só COMERCIAL/DIRETOR/ADMINISTRADOR podem gerar contrato a partir de uma proposta.';
  end if;

  select * into v_prop from public.propostas_comerciais where id = p_proposta_id;
  if v_prop.id is null then
    raise exception 'NAO_ENCONTRADA: proposta % não encontrada ou sem permissão de leitura.', p_proposta_id;
  end if;

  if v_prop.status <> 'ASSINADA' then
    raise exception 'STATUS_INVALIDO: só é possível gerar contrato a partir de uma proposta ASSINADA (seção 52) — status atual: %.', v_prop.status;
  end if;

  if v_prop.contrato_id is not null then
    raise exception 'JA_GERADO: esta proposta já gerou o contrato % — use aditivo para alterações (seção 39), nunca gerar de novo.', v_prop.contrato_id;
  end if;

  if v_prop.parceiro_id is null or v_prop.cidade_id is null then
    raise exception 'DADOS_INCOMPLETOS: proposta sem parceiro_id/cidade_id — não é possível gerar contrato.';
  end if;

  select * into v_sim from public.simulacoes where id = v_prop.simulacao_id;
  v_snapshot := v_prop.snapshot;

  v_modelo := coalesce(v_sim.modelo, 'HIBRIDO_REVENUE_SHARE'::contrato_modelo);
  v_prazo := coalesce((v_snapshot->>'prazo_meses')::integer, v_sim.prazo_meses, 48);
  v_revenue_share := (v_snapshot->>'revenue_share_pct')::numeric;
  v_faturamento := (v_snapshot->>'faturamento')::numeric;
  v_preco_negociado := coalesce(
    nullif(v_snapshot->>'preco_proposto', '')::numeric,
    nullif(v_snapshot->>'total_payable', '')::numeric,
    nullif(v_snapshot->>'recommended', '')::numeric
  );

  if v_prazo < 48 and not p_prazo_minimo_excecao then
    raise exception 'PRAZO_MINIMO: contrato mínimo é de 48 meses (seção 32) — prazo da proposta é % meses; use uma exceção autorizada para prosseguir.', v_prazo;
  end if;

  if p_prazo_minimo_excecao and (p_motivo_excecao_prazo is null or trim(p_motivo_excecao_prazo) = '') then
    raise exception 'MOTIVO_OBRIGATORIO: prazo abaixo de 48 meses exige motivo da exceção (seção 32).';
  end if;

  v_numero := 'CONTR-' || to_char(now(), 'YYYYMMDD') || '-' || substr(gen_random_uuid()::text, 1, 8);

  insert into public.contratos (
    numero, parceiro_id, cidade_id, modelo, status, prazo_meses,
    prazo_minimo_excecao, motivo_excecao_prazo, aprovado_por, aprovado_em
  ) values (
    v_numero, v_prop.parceiro_id, v_prop.cidade_id, v_modelo, 'RASCUNHO', v_prazo,
    p_prazo_minimo_excecao,
    case when p_prazo_minimo_excecao then p_motivo_excecao_prazo else null end,
    case when p_prazo_minimo_excecao then auth.uid() else null end,
    case when p_prazo_minimo_excecao then now() else null end
  )
  returning * into v_contrato;

  insert into public.contrato_pricing_config (contrato_id, percentual_revenue_share, mensalidade_minima_porta)
  values (v_contrato.id, v_revenue_share, v_preco_negociado);

  insert into public.contrato_regras (contrato_id)
  values (v_contrato.id);

  insert into public.contrato_versions (contrato_id, versao, motivo, snapshot, criado_por)
  values (v_contrato.id, 1, 'Geração automática a partir da proposta ' || v_prop.numero || ' (Fase 2.5, seção 30).', v_snapshot, auth.uid());

  update public.propostas_comerciais
     set contrato_id = v_contrato.id,
         status = 'CONTRATO_GERADO'
   where id = v_prop.id;

  perform app.registrar_auditoria_semantica('contratos', v_contrato.id, 'CONTRACT_GENERATE',
    'Gerado automaticamente a partir da proposta ' || v_prop.numero,
    null, to_jsonb(v_contrato));

  return v_contrato;
end;
$$;

comment on function app.gerar_contrato_de_proposta(uuid, boolean, text) is 'Fase 2.5 seções 30-31/52. FASE 3 (seção 4/15): mensalidade_minima_porta agora vem do preço efetivamente negociado/aprovado na proposta (preco_proposto), nunca do recomendado. FASE 3 (item 3.2): motivo_excecao_prazo agora é persistido em public.contratos, nunca apenas validado e descartado. SECURITY DEFINER (com checagem de RBAC explícita no início): escreve em duas tabelas com policies diferentes (ver comentário anterior desta função, preservado).';
