-- OptiMon — Fase 4.1 (item 05): REVERTER IMPORTAÇÃO — desfaz só as alterações desta
-- importação, nunca o resto.
--
-- Semântica de transação corrigida pela condição do usuário: cada item de
-- staging.importacao_alteracoes é revertido dentro do seu PRÓPRIO bloco BEGIN/EXCEPTION
-- (savepoint implícito do plpgsql) — se um item falhar (ex.: o registro foi alterado por
-- outra importação/edição manual depois desta aplicação), só a tentativa de reverter
-- AQUELE item é desfeita; a reversão dos demais itens já commitados continua
-- normalmente. NUNCA um item falho derruba a reversão inteira. Status final:
-- REVERTIDA só se 100% dos itens reverteram; caso contrário REVERTIDA_PARCIALMENTE
-- (staging.importacao_alteracoes.motivo_nao_revertido registra, por item, por que não
-- reverteu).

create or replace function app.reverter_importacao(p_importacao_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = public, staging, pg_temp
as $function$
declare
  v_importacao staging.importacoes%rowtype;
  v_alt record;
  v_atual jsonb;
  v_total integer := 0;
  v_revertidos integer := 0;
  v_erro text;
begin
  select * into v_importacao from staging.importacoes where id = p_importacao_id for update;
  if not found then
    raise exception 'NAO_ENCONTRADO: importação % não encontrada.', p_importacao_id;
  end if;
  if not app.tem_perfil('ADMINISTRADOR') then
    raise exception 'NAO_AUTORIZADO: só ADMINISTRADOR pode reverter uma importação.';
  end if;
  if v_importacao.status <> 'IMPORTADA' then
    raise exception 'ESTADO_INVALIDO: só é possível reverter uma importação em IMPORTADA (atual: %).', v_importacao.status;
  end if;
  if p_motivo is null or trim(p_motivo) = '' then
    raise exception 'MOTIVO_OBRIGATORIO: reversão exige motivo.';
  end if;

  for v_alt in
    select * from staging.importacao_alteracoes
    where importacao_id = p_importacao_id and revertido = false
    -- Ordem inversa EXATA da aplicação: reverte o que foi aplicado por último primeiro
    -- (evita, ex., tentar reverter um segmento antes de já ter revertido o cabo que
    -- depende dele por FK). Usa a coluna "ordem" (bigserial), nunca aplicado_em — dentro
    -- de uma mesma transação de aplicação, now() é idêntico para todos os itens
    -- aplicados, então ordenar por timestamp é não-determinístico e pode violar FK na
    -- reversão (bug encontrado e corrigido na Fase 4.1.1, Teste 22).
    order by ordem desc
  loop
    v_total := v_total + 1;

    begin -- savepoint por item — ver comentário no topo do arquivo.
      if v_alt.tabela_oficial = 'cidades_infra' then
        select to_jsonb(c) into v_atual from public.cidades_infra c where c.id = v_alt.registro_id;
      elsif v_alt.tabela_oficial = 'infra_pops' then
        select to_jsonb(p) into v_atual from public.infra_pops p where p.id = v_alt.registro_id;
      elsif v_alt.tabela_oficial = 'infra_segmentos' then
        select to_jsonb(s) into v_atual from public.infra_segmentos s where s.id = v_alt.registro_id;
      elsif v_alt.tabela_oficial = 'infra_cabos' then
        select to_jsonb(cb) into v_atual from public.infra_cabos cb where cb.id = v_alt.registro_id;
      elsif v_alt.tabela_oficial = 'infra_fibras' then
        select to_jsonb(f) into v_atual from public.infra_fibras f where f.id = v_alt.registro_id;
      elsif v_alt.tabela_oficial = 'infra_postes' then
        select to_jsonb(p) into v_atual from public.infra_postes p where p.id = v_alt.registro_id;
      elsif v_alt.tabela_oficial = 'infra_portas_pon' then
        select to_jsonb(pp) into v_atual from public.infra_portas_pon pp where pp.id = v_alt.registro_id;
      elsif v_alt.tabela_oficial = 'contrato_clientes_reservados' then
        select to_jsonb(ccr) into v_atual from public.contrato_clientes_reservados ccr where ccr.id = v_alt.registro_id;
      else
        raise exception 'REVERSAO_NAO_IMPLEMENTADA: tabela % sem lógica de reversão nesta migration.', v_alt.tabela_oficial;
      end if;

      if v_atual is null and v_alt.operacao = 'UPDATE' then
        raise exception 'Registro % de % não existe mais — não é possível reverter um UPDATE em registro removido.', v_alt.registro_id, v_alt.tabela_oficial;
      end if;

      -- Proteção contra alteração posterior (condição do usuário: nunca sobrescrever
      -- silenciosamente uma mudança feita depois desta importação).
      if v_alt.operacao in ('UPDATE', 'INSERT') and v_atual is distinct from v_alt.valor_novo then
        raise exception 'Registro % de % foi alterado depois desta importação (por outra importação ou edição manual) — reversão automática bloqueada para este item.', v_alt.registro_id, v_alt.tabela_oficial;
      end if;

      if v_alt.operacao = 'INSERT' then
        if v_alt.tabela_oficial = 'cidades_infra' then
          delete from public.cidades_infra where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'infra_pops' then
          delete from public.infra_pops where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'infra_postes' then
          delete from public.infra_postes where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'infra_segmentos' then
          delete from public.infra_segmentos where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'infra_cabos' then
          delete from public.infra_cabos where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'infra_portas_pon' then
          delete from public.infra_portas_pon where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'contrato_clientes_reservados' then
          delete from public.contrato_clientes_reservados where id = v_alt.registro_id;
        else
          raise exception 'REVERSAO_NAO_IMPLEMENTADA: exclusão automática de INSERT em % não implementada nesta migration.', v_alt.tabela_oficial;
        end if;

      elsif v_alt.operacao = 'UPDATE' then
        if v_alt.tabela_oficial = 'cidades_infra' then
          update public.cidades_infra set
            endereco = v_alt.valor_anterior->>'endereco',
            km_rede = (v_alt.valor_anterior->>'km_rede')::numeric,
            observacoes = v_alt.valor_anterior->>'observacoes'
          where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'infra_pops' then
          update public.infra_pops set
            nome = v_alt.valor_anterior->>'nome',
            endereco = v_alt.valor_anterior->>'endereco',
            observacoes = v_alt.valor_anterior->>'observacoes'
          where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'infra_fibras' then
          update public.infra_fibras set
            status_operacional = (v_alt.valor_anterior->>'status_operacional')::fibra_status_operacional,
            observacao = v_alt.valor_anterior->>'observacao'
          where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'infra_postes' then
          update public.infra_postes set
            proprietario_terceiro = v_alt.valor_anterior->>'proprietario_terceiro',
            quantidade = (v_alt.valor_anterior->>'quantidade')::integer,
            custo_mensal = (v_alt.valor_anterior->>'custo_mensal')::numeric
          where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'infra_segmentos' then
          update public.infra_segmentos set
            extensao_km = (v_alt.valor_anterior->>'extensao_km')::numeric
          where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'infra_cabos' then
          update public.infra_cabos set
            capacidade_fo = (v_alt.valor_anterior->>'capacidade_fo')::integer,
            fabricante = v_alt.valor_anterior->>'fabricante'
          where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'infra_portas_pon' then
          -- capacidade_utilizada_assinantes nunca é tocada (dado comercial ao vivo, fora do
          -- escopo desta importação — mesma regra usada na aplicação, Migration 4).
          update public.infra_portas_pon set
            nome = v_alt.valor_anterior->>'nome',
            tecnologia = (v_alt.valor_anterior->>'tecnologia')::pon_tecnologia,
            capacidade_max_assinantes = (v_alt.valor_anterior->>'capacidade_max_assinantes')::integer
          where id = v_alt.registro_id;
        elsif v_alt.tabela_oficial = 'contrato_clientes_reservados' then
          update public.contrato_clientes_reservados set
            cnpj_cpf = v_alt.valor_anterior->>'cnpj_cpf',
            motivo = v_alt.valor_anterior->>'motivo',
            status = v_alt.valor_anterior->>'status',
            tipo = v_alt.valor_anterior->>'tipo',
            documento_referencia = v_alt.valor_anterior->>'documento_referencia'
          where id = v_alt.registro_id;
        else
          raise exception 'REVERSAO_NAO_IMPLEMENTADA: UPDATE em % sem lógica de reversão nesta migration.', v_alt.tabela_oficial;
        end if;
      end if;

      update staging.importacao_alteracoes
      set revertido = true, revertido_em = now(), revertido_por = auth.uid()
      where id = v_alt.id;

      update staging.importacao_itens set aplicado = false where id = v_alt.importacao_item_id;

      v_revertidos := v_revertidos + 1;

    exception when others then
      get stacked diagnostics v_erro = message_text;
      update staging.importacao_alteracoes set motivo_nao_revertido = v_erro where id = v_alt.id;
    end;
  end loop;

  if v_total = 0 then
    raise exception 'NADA_A_REVERTER: esta importação não tem nenhuma alteração pendente de reversão.';
  end if;

  if v_revertidos = v_total then
    update staging.importacoes
    set status = 'REVERTIDA', revertido_por = auth.uid(), revertido_em = now(), motivo_reversao = p_motivo
    where id = p_importacao_id;

    perform app.registrar_auditoria_semantica(
      p_entidade => 'staging.importacoes', p_entidade_id => p_importacao_id, p_acao => 'IMPORT_REVERT',
      p_motivo => p_motivo, p_valor_anterior => null,
      p_valor_novo => jsonb_build_object('revertidos', v_revertidos, 'total', v_total),
      p_origem => 'app', p_ip => null
    );

    return jsonb_build_object('sucesso', true, 'status', 'REVERTIDA', 'revertidos', v_revertidos, 'total', v_total);
  else
    update staging.importacoes
    set status = 'REVERTIDA_PARCIALMENTE', revertido_por = auth.uid(), revertido_em = now(), motivo_reversao = p_motivo
    where id = p_importacao_id;

    perform app.registrar_auditoria_semantica(
      p_entidade => 'staging.importacoes', p_entidade_id => p_importacao_id, p_acao => 'IMPORT_REVERT_PARTIAL',
      p_motivo => p_motivo, p_valor_anterior => null,
      p_valor_novo => jsonb_build_object('revertidos', v_revertidos, 'total', v_total),
      p_origem => 'app', p_ip => null
    );

    return jsonb_build_object('sucesso', false, 'status', 'REVERTIDA_PARCIALMENTE', 'revertidos', v_revertidos, 'total', v_total);
  end if;
end;
$function$;

grant execute on function app.reverter_importacao(uuid, text) to authenticated;

create or replace function public.reverter_importacao(p_importacao_id uuid, p_motivo text)
returns jsonb language sql security invoker as $$ select app.reverter_importacao(p_importacao_id, p_motivo); $$;

grant execute on function public.reverter_importacao(uuid, text) to authenticated;

comment on function app.reverter_importacao(uuid, text) is 'Fase 4.1: reversão item-a-item, cada item com seu próprio savepoint — falha em 1 item nunca derruba a reversão dos demais. REVERTIDA só se 100% reverteu; REVERTIDA_PARCIALMENTE caso contrário (ver staging.importacao_alteracoes.motivo_nao_revertido por item).';
