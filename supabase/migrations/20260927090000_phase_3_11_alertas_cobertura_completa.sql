-- OptiMon — Fase 3, item 3.11: Alertas — cobertura completa dos tipos pedidos.
--
-- CONTEXTO REAL (levantado por auditoria de código nesta fase, corrigindo uma
-- afirmação falsa do comentário de cabeçalho de 20260913090800, que dizia que
-- 'REAJUSTE, FIBRA_EM_CONFLITO, CAPACIDADE_EXCEDIDA, OPERACAO_NAO_AUTORIZADA'
-- já estavam cobertos — não estavam: nenhum código gerava esses 4 tipos).
--
-- `alerta_tipo` tem 20 valores. Antes desta migração, só 8 eram efetivamente
-- gerados: 5 por app.gerar_alertas_automaticos() (APROVACAO_PENDENTE,
-- ASSINATURA_PENDENTE, CONTRATO_PENDENTE, DOCUMENTO_RECUSADO,
-- CONTRATO_PROXIMO_VENCIMENTO) e 3 por um trigger de capacidade em
-- cliente_porta_pon (CAPACIDADE_80/90/100). Os outros 12 nunca eram inseridos
-- por nenhum caminho de código, apesar de existirem no enum.
--
-- Esta migração fecha 4 desses 12 com fontes de dado reais (sem inventar
-- nenhuma condição de disparo):
--   • FIM_CARENCIA        — contrato ATIVO cuja rampa comercial
--                           (public.pricing_ramp_rules) atinge 100% em até 30 dias.
--   • REAJUSTE             — contrato ATIVO com índice de reajuste configurado
--                           (contrato_pricing_config.indice_reajuste <>
--                           'SEM_REAJUSTE') cujo próximo ciclo de 12 meses
--                           (desde o último reajuste APLICADO, ou desde
--                           data_inicio se nunca houve um) vence em até 30 dias
--                           ou já venceu.
--   • ATIVO_NAO_DEVOLVIDO  — contrato ENCERRADO/RESCINDIDO com ativos ainda
--                           vinculados (status <> 'DEVOLVIDO', não removidos)
--                           e sem nenhuma linha correspondente em
--                           public.ativos_devolucao.
--   • OPERACAO_NAO_AUTORIZADA — via um NOVO trigger AFTER INSERT em
--                           public.auditoria (a tabela permanece imutável —
--                           o trigger só LÊ, nunca UPDATE/DELETE) que observa
--                           as ações já registradas como bloqueio de operação
--                           ('BLOCKED_ARCHIVE', 'BLOCKED_DELETE',
--                           'CONTRACT_ACTIVATE_BLOCKED') e cria o alerta
--                           correspondente automaticamente, sem exigir que
--                           cada rota da API seja alterada individualmente.
--
-- Os 8 tipos restantes NÃO são implementados nesta fase — documentando o
-- motivo real de cada um, em vez de fingir cobertura (mesma disciplina do
-- item 3.10):
--   • DIVERGENCIA_HUBSOFT      — depende da integração HubSoft, EXPLICITAMENTE
--                                ADIADA pelo usuário nesta fase ("deixando
--                                para depois"). Sem a integração não existe
--                                nenhuma fonte de dado do lado HubSoft para
--                                comparar.
--   • DIVERGENCIA_FATURAMENTO — mesma razão: depende de dados de faturamento
--                                real (HubSoft ou fatura manual), que este
--                                sistema não recebe nem armazena hoje.
--   • TAKE_OR_PAY_QUEBRADO     — depende de medições de consumo/faturamento
--                                real por contrato, inexistentes no schema
--                                atual (nenhuma tabela de medição mensal).
--                                Mesma dependência de dados de faturamento.
--   • CLIENTE_RESERVADO        — public.contrato_clientes_reservados (fase
--                                3.7) registra CLIENTES FINAIS que um parceiro
--                                está proibido de atender, mas o OptiMon não
--                                tem hoje nenhuma tabela que associe um
--                                cliente final nomeado a uma proposta/contrato
--                                real — não há como comparar automaticamente
--                                sem inventar uma ligação que não existe.
--                                Fica como checagem operacional manual (a
--                                lista de clientes reservados já é visível em
--                                Contrato → Detalhe, seção "Clientes
--                                reservados", implementada na fase 3.7).
--   • CAPACIDADE_EXCEDIDA      — o enum tem esse valor E também
--                                'CAPACIDADE_80'/'CAPACIDADE_90'/'CAPACIDADE_100'
--                                (adicionados na Fase 1.2, já gerados por
--                                trigger). CAPACIDADE_EXCEDIDA seria redundante
--                                com CAPACIDADE_100 (100% já é "capacidade
--                                excedida" na prática) — não duplicamos o
--                                mesmo evento sob dois tipos diferentes.
--   • FIBRA_EM_CONFLITO        — o conflito de FIBRA FÍSICA já é IMPOSSÍVEL de
--                                ocorrer: public.contrato_fibras tem um índice
--                                único parcial (contrato_fibras_fibra_ativa_idx
--                                / contrato_fibras_porta_ativa_idx, fase 1.1)
--                                que bloqueia no banco, no INSERT, a mesma
--                                fibra/porta PON ativa em dois contratos. Não
--                                há nada para alertar depois do fato. O
--                                conflito COMERCIAL (mesma cidade/POP/serviço,
--                                exclusividade) já é coberto pelo novo
--                                OPERACAO_NAO_AUTORIZADA via
--                                'CONTRACT_ACTIVATE_BLOCKED'.
--   • ENTRADA_PRECO_CHEIO      — é o mesmo evento comercial de FIM_CARENCIA
--                                (a rampa atinge 100%), só que observado depois
--                                do fato em vez de como aviso prévio. Gerar os
--                                dois tipos para o mesmo evento duplicaria
--                                ruído no dashboard sem informação nova — por
--                                ora só FIM_CARENCIA (aviso com antecedência,
--                                mais acionável) é gerado.
--   • ERRO_INTEGRACAO_ASSINATURA — public.signature_events não tem nenhuma
--                                coluna de erro/falha (só id, envelope_id,
--                                evento_externo_id, tipo_evento, payload,
--                                processado, recebido_em) — "processado=false"
--                                só significa "ainda não processado", não
--                                "falhou". Hoje só existe o provedor mock de
--                                homologação, que nunca falha de forma
--                                assíncrona (não há webhook real). Sem uma
--                                fonte de erro real, não há condição honesta
--                                para gerar este alerta.
--
-- Nenhuma tabela é recriada; nenhuma migração antiga é substituída;
-- `app.gerar_alertas_automaticos()` é reaplicada via CREATE OR REPLACE com a
-- MESMA assinatura, só acrescentando blocos novos aos já existentes.

-- ============================================================================
-- app.gerar_alertas_automaticos() — acrescenta FIM_CARENCIA, REAJUSTE e
-- ATIVO_NAO_DEVOLVIDO aos 5 blocos já existentes (mantidos sem alteração).
-- ============================================================================

create or replace function app.gerar_alertas_automaticos()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_criados integer := 0;
  r record;
begin
  if not app.tem_perfil('DIRETOR', 'FINANCEIRO', 'ENGENHARIA', 'ADMINISTRADOR', 'COMERCIAL') then
    raise exception 'PERMISSAO_NEGADA: sem permissão para gerar alertas.';
  end if;

  -- Propostas aguardando aprovação
  for r in
    select p.id, p.numero from public.propostas_comerciais p
    where p.status = 'EM_APROVACAO'
      and not exists (
        select 1 from public.alertas a
        where a.proposta_id = p.id and a.tipo = 'APROVACAO_PENDENTE' and a.resolvido = false
      )
  loop
    insert into public.alertas (tipo, severidade, proposta_id, titulo, descricao)
    values ('APROVACAO_PENDENTE', 'ATENCAO', r.id, 'Proposta aguardando aprovação', 'Proposta ' || r.numero || ' está em EM_APROVACAO.');
    v_criados := v_criados + 1;
  end loop;

  -- Propostas aguardando assinatura
  for r in
    select p.id, p.numero from public.propostas_comerciais p
    where p.status = 'EM_ASSINATURA'
      and not exists (
        select 1 from public.alertas a
        where a.proposta_id = p.id and a.tipo = 'ASSINATURA_PENDENTE' and a.resolvido = false
      )
  loop
    insert into public.alertas (tipo, severidade, proposta_id, titulo, descricao)
    values ('ASSINATURA_PENDENTE', 'ATENCAO', r.id, 'Proposta aguardando assinatura', 'Proposta ' || r.numero || ' está em EM_ASSINATURA.');
    v_criados := v_criados + 1;
  end loop;

  -- Contratos aguardando assinatura (envelope enviado, ainda não validado)
  for r in
    select distinct c.id, c.numero from public.contratos c
    join public.signature_envelopes e on e.contrato_id = c.id
    where e.tipo_documento = 'CONTRATO' and e.status in ('ENVIADO', 'AGUARDANDO', 'PARCIALMENTE_ASSINADO')
      and not exists (
        select 1 from public.alertas a where a.contrato_id = c.id and a.tipo = 'CONTRATO_PENDENTE' and a.resolvido = false
      )
  loop
    insert into public.alertas (tipo, severidade, contrato_id, titulo, descricao)
    values ('CONTRATO_PENDENTE', 'ATENCAO', r.id, 'Contrato aguardando assinatura', 'Contrato ' || r.numero || ' tem envelope de assinatura em andamento.');
    v_criados := v_criados + 1;
  end loop;

  -- Documento recusado (proposta ou contrato)
  for r in
    select e.id as envelope_id, e.tipo_documento, e.proposta_id, e.contrato_id
    from public.signature_envelopes e
    where e.status = 'RECUSADO'
      and not exists (
        select 1 from public.alertas a
        where a.tipo = 'DOCUMENTO_RECUSADO'
          and a.resolvido = false
          and ((a.proposta_id is not distinct from e.proposta_id) and (a.contrato_id is not distinct from e.contrato_id))
      )
  loop
    insert into public.alertas (tipo, severidade, proposta_id, contrato_id, titulo, descricao)
    values ('DOCUMENTO_RECUSADO', 'CRITICO', r.proposta_id, r.contrato_id, 'Documento recusado na assinatura', 'Envelope ' || r.envelope_id || ' (' || r.tipo_documento || ') foi recusado por um signatário.');
    v_criados := v_criados + 1;
  end loop;

  -- Vencimento próximo (60 dias)
  for r in
    select c.id, c.numero from public.contratos c
    where c.status = 'ATIVO' and c.data_fim_prevista is not null
      and c.data_fim_prevista <= current_date + interval '60 days'
      and not exists (
        select 1 from public.alertas a where a.contrato_id = c.id and a.tipo = 'CONTRATO_PROXIMO_VENCIMENTO' and a.resolvido = false
      )
  loop
    insert into public.alertas (tipo, severidade, contrato_id, titulo, descricao)
    values ('CONTRATO_PROXIMO_VENCIMENTO', 'ATENCAO', r.id, 'Contrato próximo do vencimento', 'Contrato ' || r.numero || ' vence em até 60 dias.');
    v_criados := v_criados + 1;
  end loop;

  -- ==========================================================================
  -- NOVO (Fase 3, item 3.11): FIM_CARENCIA — rampa comercial do contrato
  -- atinge 100% (fim da carência/desconto de entrada) em até 30 dias.
  -- ==========================================================================
  for r in
    select c.id, c.numero, c.data_inicio,
      (c.data_inicio + ((coalesce(
        (select min(month_start) from public.pricing_ramp_rules where contrato_id = c.id and percentage = 1.00),
        (select min(month_start) from public.pricing_ramp_rules where contrato_id is null and percentage = 1.00)
      ) - 1) || ' months')::interval)::date as v_fim_carencia
    from public.contratos c
    where c.status = 'ATIVO'
  loop
    if r.v_fim_carencia is not null
       and r.v_fim_carencia between current_date and current_date + interval '30 days'
       and not exists (
         select 1 from public.alertas a where a.contrato_id = r.id and a.tipo = 'FIM_CARENCIA' and a.resolvido = false
       )
    then
      insert into public.alertas (tipo, severidade, contrato_id, titulo, descricao)
      values ('FIM_CARENCIA', 'INFO', r.id, 'Fim da carência comercial se aproxima',
        'Contrato ' || r.numero || ' atinge 100% do preço cheio (fim da rampa de entrada) em ' || to_char(r.v_fim_carencia, 'DD/MM/YYYY') || '.');
      v_criados := v_criados + 1;
    end if;
  end loop;

  -- ==========================================================================
  -- NOVO (Fase 3, item 3.11): REAJUSTE — contrato com índice de reajuste
  -- configurado (≠ SEM_REAJUSTE) cujo ciclo anual (12 meses desde o último
  -- reajuste APLICADO, ou desde data_inicio se nunca houve nenhum) vence em
  -- até 30 dias ou já venceu.
  -- ==========================================================================
  for r in
    select c.id, c.numero,
      (coalesce(
        (select max(rj.competencia_base) from public.reajustes rj where rj.contrato_id = c.id and rj.status = 'APLICADO'),
        c.data_inicio
      ) + interval '12 months')::date as v_proximo_reajuste
    from public.contratos c
    join public.contrato_pricing_config cpc on cpc.contrato_id = c.id
    where c.status = 'ATIVO' and cpc.indice_reajuste <> 'SEM_REAJUSTE'
  loop
    if r.v_proximo_reajuste <= current_date + interval '30 days'
       and not exists (
         select 1 from public.alertas a where a.contrato_id = r.id and a.tipo = 'REAJUSTE' and a.resolvido = false
       )
    then
      insert into public.alertas (tipo, severidade, contrato_id, titulo, descricao)
      values ('REAJUSTE', 'ATENCAO', r.id, 'Reajuste anual pendente',
        'Contrato ' || r.numero || ' completa o ciclo de 12 meses de reajuste em ' || to_char(r.v_proximo_reajuste, 'DD/MM/YYYY') ||
        case when r.v_proximo_reajuste < current_date then ' (já venceu — nenhum reajuste foi aplicado desde então)' else '' end || '.');
      v_criados := v_criados + 1;
    end if;
  end loop;

  -- ==========================================================================
  -- NOVO (Fase 3, item 3.11): ATIVO_NAO_DEVOLVIDO — contrato encerrado/
  -- rescindido com ativos ainda vinculados (não devolvidos, não removidos) e
  -- sem nenhum registro de devolução. Um alerta agregado por contrato,
  -- listando cada ativo pendente pelo patrimônio/número de série.
  -- ==========================================================================
  for r in
    select c.id, c.numero,
      string_agg(coalesce(a.patrimonio, a.numero_serie, a.id::text) || ' (' || a.tipo || ')', ', ' order by a.id) as v_ativos
    from public.contratos c
    join public.ativos a on a.contrato_id = c.id
    where c.status in ('RESCINDIDO', 'ENCERRADO')
      and a.removido_em is null
      and a.status <> 'DEVOLVIDO'
      and not exists (
        select 1 from public.ativos_devolucao ad where ad.ativo_id = a.id and ad.contrato_id = c.id
      )
    group by c.id, c.numero
  loop
    if not exists (
      select 1 from public.alertas al where al.contrato_id = r.id and al.tipo = 'ATIVO_NAO_DEVOLVIDO' and al.resolvido = false
    ) then
      insert into public.alertas (tipo, severidade, contrato_id, titulo, descricao)
      values ('ATIVO_NAO_DEVOLVIDO', 'ATENCAO', r.id, 'Ativos pendentes de devolução',
        'Contrato ' || r.numero || ' foi encerrado/rescindido e ainda tem ativo(s) vinculado(s) sem registro de devolução: ' || r.v_ativos || '.');
      v_criados := v_criados + 1;
    end if;
  end loop;

  return v_criados;
end;
$$;

-- ============================================================================
-- NOVO (Fase 3, item 3.11): OPERACAO_NAO_AUTORIZADA — trigger AFTER INSERT em
-- public.auditoria que observa ações já registradas de bloqueio de operação e
-- cria o alerta correspondente automaticamente. A tabela auditoria permanece
-- imutável (trg_auditoria_imutavel, BEFORE UPDATE OR DELETE, continua
-- intocado) — este é um trigger AFTER INSERT, só leitura sobre a linha nova,
-- nunca altera/apaga nada em auditoria.
--
-- SECURITY DEFINER é necessário porque quem tenta a operação bloqueada pode
-- ser qualquer perfil autenticado (ex.: COMERCIAL tentando ativar um contrato
-- com conflito de exclusividade), mas a policy alertas_write só permite
-- INSERT para DIRETOR/FINANCEIRO/ENGENHARIA/ADMINISTRADOR — sem
-- SECURITY DEFINER o insert seria silenciosamente bloqueado pela RLS para
-- qualquer outro perfil.
-- ============================================================================

create or replace function app.fn_alerta_operacao_nao_autorizada()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_contrato_id uuid;
  v_titulo text;
begin
  v_contrato_id := case when new.entidade = 'contratos' then new.entidade_id else null end;
  v_titulo := 'Operação bloqueada: ' || new.acao;

  -- Evita duplicar alerta não resolvido para o mesmo contrato/ação (ex.: o
  -- mesmo usuário tentando repetidamente a mesma ativação bloqueada).
  if v_contrato_id is not null and exists (
    select 1 from public.alertas
    where contrato_id = v_contrato_id and tipo = 'OPERACAO_NAO_AUTORIZADA' and resolvido = false and titulo = v_titulo
  ) then
    return new;
  end if;

  insert into public.alertas (tipo, severidade, contrato_id, titulo, descricao)
  values (
    'OPERACAO_NAO_AUTORIZADA',
    'ATENCAO',
    v_contrato_id,
    v_titulo,
    coalesce(new.motivo, 'Ação ' || new.acao || ' sobre ' || new.entidade || ' (id ' || coalesce(new.entidade_id::text, '?') || ') foi bloqueada pelas regras de negócio.')
  );
  return new;
end;
$$;

comment on function app.fn_alerta_operacao_nao_autorizada() is 'Fase 3 item 3.11: gera alerta OPERACAO_NAO_AUTORIZADA a partir de ações de bloqueio já registradas em auditoria (BLOCKED_ARCHIVE, BLOCKED_DELETE, CONTRACT_ACTIVATE_BLOCKED). Só quando entidade=''contratos'' o alerta é vinculado a um contrato (alertas não tem coluna genérica entidade/entidade_id) — para outras entidades (ex.: infra_fibras em BLOCKED_ARCHIVE/BLOCKED_DELETE) o alerta é criado sem contrato_id, identificável pelo título/descrição.';

drop trigger if exists trg_auditoria_alerta_operacao_nao_autorizada on public.auditoria;
create trigger trg_auditoria_alerta_operacao_nao_autorizada
  after insert on public.auditoria
  for each row
  when (new.acao in ('BLOCKED_ARCHIVE', 'BLOCKED_DELETE', 'CONTRACT_ACTIVATE_BLOCKED'))
  execute function app.fn_alerta_operacao_nao_autorizada();

-- ============================================================================
-- NOVO (Fase 3, item 3.11): resolver um alerta individual. Faltava um
-- endpoint dedicado — antes desta fase o frontend não tinha NENHUMA tela que
-- sequer listasse alertas individuais (só um contador agregado no dashboard
-- de contratos), então a ausência de "resolver" nunca tinha sido notada.
-- ============================================================================

create or replace function app.resolver_alerta(p_alerta_id uuid)
returns public.alertas
language plpgsql
security invoker
as $$
declare
  v_alerta public.alertas;
begin
  if not app.tem_perfil('DIRETOR', 'FINANCEIRO', 'ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: sem permissão para resolver alertas.';
  end if;

  update public.alertas
    set resolvido = true, resolvido_por = auth.uid(), resolvido_em = now()
    where id = p_alerta_id and resolvido = false
    returning * into v_alerta;

  if v_alerta.id is null then
    raise exception 'NAO_ENCONTRADO: alerta não existe ou já está resolvido.';
  end if;

  return v_alerta;
end;
$$;

create or replace function public.pricing_alerta_resolver(p_alerta_id uuid)
returns public.alertas
language sql security invoker
as $$ select app.resolver_alerta(p_alerta_id); $$;

grant execute on function public.pricing_alerta_resolver(uuid) to authenticated;
