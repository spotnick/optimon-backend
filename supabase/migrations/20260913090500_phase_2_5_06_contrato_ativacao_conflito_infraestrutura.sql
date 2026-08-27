-- OptiMon — Fase 2.5 (6/9): Ativação de contrato — assinatura validada +
-- infraestrutura alocada + verificação de conflito antes de ativar (seções
-- 35-36).
--
-- O que já existia desde a Fase 1.2/2.1 e NÃO foi duplicado aqui:
--   - `contrato_fibras` já vincula fibra/porta PON a um contrato, e o trigger
--     `fn_contrato_fibras_sync_status` já marca `infra_fibras.status = 'LOCADA'`
--     automaticamente assim que a linha é inserida — essa é a "infraestrutura
--     comprometida" da seção 35. Continua sendo ENGENHARIA quem aloca a fibra/
--     porta PON específica a um contrato (RLS `contrato_fibras_write` já exige
--     ENGENHARIA/DIRETOR/ADMINISTRADOR) — a proposta/simulação trabalha em nível
--     agregado (quantidade de clientes/PONs necessárias), nunca escolhe QUAL
--     fibra física alocar, então `app.ativar_contrato()` abaixo não inventa essa
--     escolha: ele exige que a alocação já tenha sido feita antes de ativar.
--   - o índice parcial único `contrato_fibras_porta_ativa_idx` já impede duas
--     linhas ativas (sem compartilhamento autorizado) para a mesma porta PON —
--     é o que garante o "TESTE 21: tentar contratar mesma PON novamente" da
--     seção 66, sem precisar de nenhuma lógica nova de bloqueio de capacidade.
--   - `app.check_contract_conflict()` já verifica conflito de EXCLUSIVIDADE
--     comercial entre parceiros/cidade/POP (desde a Fase 1.2) — reaproveitado
--     abaixo, não reimplementado.

create or replace function app.ativar_contrato(p_contrato_id uuid)
returns public.contratos
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_contrato public.contratos;
  v_envelope_ok boolean;
  v_infra_alocada boolean;
  v_conflito text;
begin
  if not app.tem_perfil('DIRETOR', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: só DIRETOR/ADMINISTRADOR podem ativar um contrato.';
  end if;

  select * into v_contrato from public.contratos where id = p_contrato_id;
  if v_contrato.id is null then
    raise exception 'NAO_ENCONTRADO: contrato % não encontrado.', p_contrato_id;
  end if;

  if v_contrato.status not in ('RASCUNHO', 'EM_APROVACAO') then
    raise exception 'STATUS_INVALIDO: contrato % já está em status % — não pode ser reativado por aqui.', v_contrato.numero, v_contrato.status;
  end if;

  -- 1) Assinatura ICP-Brasil do contrato precisa estar VALIDADA (seção 10/12/56
  --    — nunca tratar "ASSINADO" como sinônimo automático de "assinatura válida").
  select exists (
    select 1
    from public.signature_envelopes e
    join public.documentos_assinados da on da.envelope_id = e.id
    where e.contrato_id = v_contrato.id
      and e.tipo_documento = 'CONTRATO'
      and e.status = 'VALIDADO'
      and da.validado = true
  ) into v_envelope_ok;

  if not v_envelope_ok then
    perform public.pricing_log_blocked_action('contratos', v_contrato.id, 'CONTRACT_ACTIVATE_BLOCKED', 'Assinatura ICP-Brasil do contrato ainda não validada.');
    raise exception 'ASSINATURA_PENDENTE: o contrato % ainda não tem uma assinatura ICP-Brasil validada — envie para assinatura e valide antes de ativar (seção 10/56).', v_contrato.numero;
  end if;

  -- 2) Infraestrutura já precisa estar alocada (seção 35) — pelo menos uma
  --    fibra/porta PON vinculada e ativa neste contrato.
  select exists (
    select 1 from public.contrato_fibras cf
    where cf.contrato_id = v_contrato.id and cf.desvinculado_em is null
  ) into v_infra_alocada;

  if not v_infra_alocada then
    perform public.pricing_log_blocked_action('contratos', v_contrato.id, 'CONTRACT_ACTIVATE_BLOCKED', 'Nenhuma fibra/porta PON alocada a este contrato ainda.');
    raise exception 'INFRA_NAO_ALOCADA: nenhuma fibra/porta PON foi vinculada ao contrato % ainda — Engenharia precisa alocar a infraestrutura (contrato_fibras) antes da ativação (seção 35).', v_contrato.numero;
  end if;

  -- 3) Conflito de exclusividade (seção 36) — reaproveita app.check_contract_conflict,
  --    já existente desde a Fase 1.2.
  v_conflito := app.check_contract_conflict(v_contrato.cidade_id, v_contrato.parceiro_id);
  if v_conflito = 'BLOCK' then
    perform public.pricing_log_blocked_action('contratos', v_contrato.id, 'CONTRACT_ACTIVATE_BLOCKED', 'Conflito de exclusividade comercial com outro parceiro na mesma cidade/POP/serviço.');
    raise exception 'CONFLITO_INFRAESTRUTURA: existe exclusividade comercial ativa de outro parceiro cobrindo a cidade/POP/serviço deste contrato — ativação bloqueada (seção 36).';
  end if;
  -- v_conflito = 'REQUIRES_APPROVAL' é permitido continuar: quem está ativando
  -- já é DIRETOR/ADMINISTRADOR (checagem no topo desta função), que é a mesma
  -- autoridade que a seção 57 exige para aprovar exceção.

  update public.contratos
     set status = 'ATIVO',
         data_inicio = coalesce(data_inicio, current_date),
         data_fim_prevista = coalesce(data_fim_prevista, coalesce(data_inicio, current_date) + (prazo_meses || ' months')::interval)
   where id = v_contrato.id
   returning * into v_contrato;

  perform app.registrar_auditoria_semantica('contratos', v_contrato.id, 'CONTRACT_ACTIVATE', null, null, to_jsonb(v_contrato));

  return v_contrato;
end;
$$;

comment on function app.ativar_contrato(uuid) is 'Fase 2.5 seções 35-36/54/57. SECURITY DEFINER com checagem de RBAC explícita (DIRETOR/ADMINISTRADOR) — mesma razão documentada em app.gerar_contrato_de_proposta: escreve em auditoria via função interna e a policy contratos_update já restringe UPDATE fora de RASCUNHO a DIRETOR/ADMINISTRADOR mesmo, então o DEFINER aqui é só para dar mensagem de erro clara e consistente com o padrão de bloqueio (pricing_log_blocked_action) em vez de depender de uma exceção genérica de RLS.';

-- Amplia pricing_log_blocked_action para aceitar o novo tipo de bloqueio.
create or replace function public.pricing_log_blocked_action(p_entidade text, p_entidade_id uuid, p_acao text, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if p_acao not in ('BLOCKED_ARCHIVE', 'BLOCKED_DELETE', 'CONTRACT_ACTIVATE_BLOCKED') then
    raise exception 'pricing_log_blocked_action: ação inválida % (aceita BLOCKED_ARCHIVE, BLOCKED_DELETE ou CONTRACT_ACTIVATE_BLOCKED).', p_acao;
  end if;
  perform app.registrar_auditoria_semantica(p_entidade, p_entidade_id, p_acao, p_motivo);
end;
$$;

drop function if exists public.pricing_contract_activate(uuid);
create or replace function public.pricing_contract_activate(p_contrato_id uuid)
returns public.contratos
language sql
security invoker
as $$
  select app.ativar_contrato(p_contrato_id);
$$;

grant execute on function public.pricing_contract_activate(uuid) to authenticated;
