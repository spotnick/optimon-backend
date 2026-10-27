-- OptiMon — Fase 4.1 (item 04): aprovação, aplicação transacional tudo-ou-nada e as
-- funções de troca de status (RECEBIDA→EM_VALIDACAO→PREVIA→APROVADA→IMPORTADA, e
-- REJEITADA/DESCARTADA a qualquer momento antes de IMPORTADA).
--
-- app.aplicar_importacao é a única função que grava em tabela oficial. Usa um bloco
-- BEGIN/EXCEPTION (savepoint implícito do plpgsql): se QUALQUER item falhar — inclusive a
-- checagem de "o registro oficial mudou desde a prévia" (condição do usuário: revalidar no
-- momento da aplicação, não só na prévia) — TODAS as escritas já feitas nesta chamada são
-- desfeitas (rollback total, nunca aplicação parcial) e a importação permanece em APROVADA
-- (nunca volta pra PREVIA sozinha — decisão explícita do ADMINISTRADOR decide o próximo
-- passo: corrigir/revalidar/rejeitar). O evento IMPORT_APPLY_FAILED é logado DENTRO do
-- mesmo bloco de exceção, então sobrevive ao rollback dos itens (só o que a exceção desfez
-- é desfeito — o log da falha em si faz parte da conclusão bem-sucedida da própria função).

-- ---------------------------------------------------------------------------
-- app.importacao_iniciar: cria a importação (upload recebido).
-- ---------------------------------------------------------------------------
create or replace function app.importacao_iniciar(
  p_arquivo_nome_original text, p_arquivo_storage_path text, p_arquivo_hash text,
  p_arquivo_tamanho_bytes bigint default null
)
returns uuid
language plpgsql
security definer
set search_path = public, staging, pg_temp
as $function$
declare
  v_id uuid;
begin
  if not app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'NAO_AUTORIZADO: só ENGENHARIA/ADMINISTRADOR podem iniciar uma importação.';
  end if;

  insert into staging.importacoes (criado_por, arquivo_nome_original, arquivo_storage_path, arquivo_hash, arquivo_tamanho_bytes, status)
  values (auth.uid(), p_arquivo_nome_original, p_arquivo_storage_path, p_arquivo_hash, p_arquivo_tamanho_bytes, 'RECEBIDA')
  returning id into v_id;

  perform app.registrar_auditoria_semantica(
    p_entidade => 'staging.importacoes', p_entidade_id => v_id, p_acao => 'IMPORT_RECEIVE',
    p_motivo => p_arquivo_nome_original, p_valor_anterior => null,
    p_valor_novo => jsonb_build_object('arquivo_nome_original', p_arquivo_nome_original, 'arquivo_hash', p_arquivo_hash),
    p_origem => 'app', p_ip => null
  );

  return v_id;
end;
$function$;

-- ---------------------------------------------------------------------------
-- app.importacao_iniciar_validacao: RECEBIDA → EM_VALIDACAO (antes do loop de
-- app.importacao_item_registrar por linha).
-- ---------------------------------------------------------------------------
create or replace function app.importacao_iniciar_validacao(p_importacao_id uuid)
returns void
language plpgsql
security definer
set search_path = public, staging, pg_temp
as $function$
declare
  v_importacao staging.importacoes%rowtype;
begin
  select * into v_importacao from staging.importacoes where id = p_importacao_id for update;
  if not found then raise exception 'NAO_ENCONTRADO: importação % não encontrada.', p_importacao_id; end if;
  if not (app.tem_perfil('ADMINISTRADOR') or (app.tem_perfil('ENGENHARIA') and v_importacao.criado_por = auth.uid())) then
    raise exception 'NAO_AUTORIZADO.';
  end if;
  if v_importacao.status <> 'RECEBIDA' then
    raise exception 'ESTADO_INVALIDO: só é possível iniciar validação a partir de RECEBIDA (atual: %).', v_importacao.status;
  end if;

  update staging.importacoes set status = 'EM_VALIDACAO' where id = p_importacao_id;

  perform app.registrar_auditoria_semantica(
    p_entidade => 'staging.importacoes', p_entidade_id => p_importacao_id, p_acao => 'IMPORT_VALIDATE',
    p_motivo => null, p_valor_anterior => jsonb_build_object('status', 'RECEBIDA'),
    p_valor_novo => jsonb_build_object('status', 'EM_VALIDACAO'), p_origem => 'app', p_ip => null
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- app.importacao_marcar_previa: EM_VALIDACAO → PREVIA (todos os itens já registrados e
-- classificados — pronto para a tela de revisão do usuário).
-- ---------------------------------------------------------------------------
create or replace function app.importacao_marcar_previa(p_importacao_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, staging, pg_temp
as $function$
declare
  v_importacao staging.importacoes%rowtype;
  v_resumo jsonb;
begin
  select * into v_importacao from staging.importacoes where id = p_importacao_id for update;
  if not found then raise exception 'NAO_ENCONTRADO: importação % não encontrada.', p_importacao_id; end if;
  if not (app.tem_perfil('ADMINISTRADOR') or (app.tem_perfil('ENGENHARIA') and v_importacao.criado_por = auth.uid())) then
    raise exception 'NAO_AUTORIZADO.';
  end if;
  if v_importacao.status <> 'EM_VALIDACAO' then
    raise exception 'ESTADO_INVALIDO: só é possível marcar prévia a partir de EM_VALIDACAO (atual: %).', v_importacao.status;
  end if;

  select jsonb_build_object(
    'total_itens', count(*),
    'por_classificacao', jsonb_object_agg(classificacao, qtd),
    'por_tipo_entidade', (select jsonb_object_agg(tipo_entidade, qtd2) from (
      select tipo_entidade, count(*) qtd2 from staging.importacao_itens where importacao_id = p_importacao_id group by tipo_entidade
    ) t2)
  ) into v_resumo
  from (
    select classificacao, count(*) qtd from staging.importacao_itens where importacao_id = p_importacao_id group by classificacao
  ) t;

  update staging.importacoes
  set status = 'PREVIA', total_registros = (select count(*) from staging.importacao_itens where importacao_id = p_importacao_id),
      resultado_validacao = v_resumo
  where id = p_importacao_id;

  perform app.registrar_auditoria_semantica(
    p_entidade => 'staging.importacoes', p_entidade_id => p_importacao_id, p_acao => 'IMPORT_PREVIEW_READY',
    p_motivo => null, p_valor_anterior => null, p_valor_novo => v_resumo, p_origem => 'app', p_ip => null
  );

  return v_resumo;
end;
$function$;

-- ---------------------------------------------------------------------------
-- app.importacao_rejeitar / app.importacao_descartar — encerram sem aplicar nada.
-- ---------------------------------------------------------------------------
create or replace function app.importacao_rejeitar(p_importacao_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public, staging, pg_temp
as $function$
declare
  v_importacao staging.importacoes%rowtype;
begin
  select * into v_importacao from staging.importacoes where id = p_importacao_id for update;
  if not found then raise exception 'NAO_ENCONTRADO: importação % não encontrada.', p_importacao_id; end if;
  if not (app.tem_perfil('ADMINISTRADOR') or (app.tem_perfil('ENGENHARIA') and v_importacao.criado_por = auth.uid())) then
    raise exception 'NAO_AUTORIZADO.';
  end if;
  if v_importacao.status in ('IMPORTADA', 'REJEITADA', 'DESCARTADA', 'REVERTIDA', 'REVERTIDA_PARCIALMENTE') then
    raise exception 'ESTADO_INVALIDO: não é possível rejeitar uma importação em % .', v_importacao.status;
  end if;
  if p_motivo is null or trim(p_motivo) = '' then
    raise exception 'MOTIVO_OBRIGATORIO: rejeição exige motivo.';
  end if;

  update staging.importacoes set status = 'REJEITADA', rejeitado_por = auth.uid(), rejeitado_em = now(), motivo_rejeicao = p_motivo
  where id = p_importacao_id;

  perform app.registrar_auditoria_semantica(
    p_entidade => 'staging.importacoes', p_entidade_id => p_importacao_id, p_acao => 'IMPORT_REJECT',
    p_motivo => p_motivo, p_valor_anterior => jsonb_build_object('status', v_importacao.status),
    p_valor_novo => jsonb_build_object('status', 'REJEITADA'), p_origem => 'app', p_ip => null
  );
end;
$function$;

create or replace function app.importacao_descartar(p_importacao_id uuid)
returns void
language plpgsql
security definer
set search_path = public, staging, pg_temp
as $function$
declare
  v_importacao staging.importacoes%rowtype;
begin
  select * into v_importacao from staging.importacoes where id = p_importacao_id for update;
  if not found then raise exception 'NAO_ENCONTRADO: importação % não encontrada.', p_importacao_id; end if;
  if not (app.tem_perfil('ADMINISTRADOR') or (app.tem_perfil('ENGENHARIA') and v_importacao.criado_por = auth.uid())) then
    raise exception 'NAO_AUTORIZADO.';
  end if;
  if v_importacao.status in ('IMPORTADA', 'REJEITADA', 'DESCARTADA', 'REVERTIDA', 'REVERTIDA_PARCIALMENTE') then
    raise exception 'ESTADO_INVALIDO: não é possível descartar uma importação em % .', v_importacao.status;
  end if;

  update staging.importacoes set status = 'DESCARTADA', descartado_por = auth.uid(), descartado_em = now()
  where id = p_importacao_id;

  perform app.registrar_auditoria_semantica(
    p_entidade => 'staging.importacoes', p_entidade_id => p_importacao_id, p_acao => 'IMPORT_DISCARD',
    p_motivo => null, p_valor_anterior => jsonb_build_object('status', v_importacao.status),
    p_valor_novo => jsonb_build_object('status', 'DESCARTADA'), p_origem => 'app', p_ip => null
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- app.importacao_aprovar: PREVIA → APROVADA. Bloqueia se sobrar CONFLITO/INVALIDO não
-- resolvido (condição do usuário: permanece em PREVIA, mostra conflitos, permite
-- corrigir/reenviar/revalidar — nunca aprova com pendência).
-- ---------------------------------------------------------------------------
create or replace function app.importacao_aprovar(p_importacao_id uuid)
returns void
language plpgsql
security definer
set search_path = public, staging, pg_temp
as $function$
declare
  v_importacao staging.importacoes%rowtype;
  v_pendentes integer;
begin
  select * into v_importacao from staging.importacoes where id = p_importacao_id for update;
  if not found then raise exception 'NAO_ENCONTRADO: importação % não encontrada.', p_importacao_id; end if;
  if not app.tem_perfil('ADMINISTRADOR', 'DIRETOR') then
    raise exception 'NAO_AUTORIZADO: só ADMINISTRADOR/DIRETOR podem aprovar.';
  end if;
  if v_importacao.status <> 'PREVIA' then
    raise exception 'ESTADO_INVALIDO: só é possível aprovar a partir de PREVIA (atual: %).', v_importacao.status;
  end if;

  select count(*) into v_pendentes from staging.importacao_itens
  where importacao_id = p_importacao_id and classificacao in ('CONFLITO', 'INVALIDO');

  if v_pendentes > 0 then
    raise exception 'PENDENCIAS_ABERTAS: % item(ns) em CONFLITO/INVALIDO — corrija e revalide antes de aprovar.', v_pendentes;
  end if;

  update staging.importacoes set status = 'APROVADA', aprovado_por = auth.uid(), aprovado_em = now()
  where id = p_importacao_id;

  perform app.registrar_auditoria_semantica(
    p_entidade => 'staging.importacoes', p_entidade_id => p_importacao_id, p_acao => 'IMPORT_APPROVE',
    p_motivo => null, p_valor_anterior => jsonb_build_object('status', 'PREVIA'),
    p_valor_novo => jsonb_build_object('status', 'APROVADA'), p_origem => 'app', p_ip => null
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- app.aplicar_importacao: APROVADA → IMPORTADA. Única função que grava em tabela
-- oficial. Tudo-ou-nada (ver comentário no topo do arquivo).
-- ---------------------------------------------------------------------------
create or replace function app.aplicar_importacao(p_importacao_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, staging, pg_temp
as $function$
declare
  v_importacao staging.importacoes%rowtype;
  v_item record;
  v_atual jsonb;
  v_novo_id uuid;
  v_erro text;
  v_aplicados integer := 0;
begin
  select * into v_importacao from staging.importacoes where id = p_importacao_id for update;
  if not found then raise exception 'NAO_ENCONTRADO: importação % não encontrada.', p_importacao_id; end if;
  if not app.tem_perfil('ADMINISTRADOR') then
    raise exception 'NAO_AUTORIZADO: só ADMINISTRADOR pode aplicar uma importação aprovada.';
  end if;
  if v_importacao.status <> 'APROVADA' then
    raise exception 'ESTADO_INVALIDO: só é possível aplicar a partir de APROVADA (atual: %).', v_importacao.status;
  end if;

  begin -- bloco com savepoint implícito: qualquer exceção aqui dentro desfaz só o que
        -- este bloco tentou (todas as escritas de infra desta aplicação), nunca o que
        -- outras importações/edições já tinham feito antes.
    for v_item in
      select * from staging.importacao_itens
      where importacao_id = p_importacao_id and classificacao in ('NOVO', 'ALTERADO')
      order by
        case tipo_entidade
          when 'CIDADE' then 1 when 'POP' then 2 when 'SEGMENTO' then 3 when 'CABO' then 4
          when 'FIBRA' then 5 when 'POSTE' then 6 when 'PORTA_PON' then 7 else 8
        end,
        criado_em
    loop
      -- Revalidação no momento da aplicação (condição do usuário): para item ALTERADO,
      -- o registro oficial precisa continuar EXATAMENTE como estava na prévia — senão
      -- alguém alterou esse dado entre a prévia e a aplicação, e aplicar às cegas
      -- sobrescreveria essa mudança concorrente sem o usuário nunca ter visto.
      if v_item.classificacao = 'ALTERADO' then
        if v_item.tipo_entidade = 'CIDADE' then
          select to_jsonb(c) into v_atual from public.cidades_infra c where c.id = v_item.entidade_oficial_id;
        elsif v_item.tipo_entidade = 'POP' then
          select to_jsonb(p) into v_atual from public.infra_pops p where p.id = v_item.entidade_oficial_id;
        elsif v_item.tipo_entidade = 'SEGMENTO' then
          select to_jsonb(s) into v_atual from public.infra_segmentos s where s.id = v_item.entidade_oficial_id;
        elsif v_item.tipo_entidade = 'CABO' then
          select to_jsonb(cb) into v_atual from public.infra_cabos cb where cb.id = v_item.entidade_oficial_id;
        elsif v_item.tipo_entidade = 'FIBRA' then
          select to_jsonb(f) into v_atual from public.infra_fibras f where f.id = v_item.entidade_oficial_id;
        elsif v_item.tipo_entidade = 'POSTE' then
          select to_jsonb(p) into v_atual from public.infra_postes p where p.id = v_item.entidade_oficial_id;
        elsif v_item.tipo_entidade = 'PORTA_PON' then
          select to_jsonb(pp) into v_atual from public.infra_portas_pon pp where pp.id = v_item.entidade_oficial_id;
        elsif v_item.tipo_entidade = 'CLIENTE_RESERVADO' then
          select to_jsonb(ccr) into v_atual from public.contrato_clientes_reservados ccr where ccr.id = v_item.entidade_oficial_id;
        end if;

        if v_atual is null then
          raise exception 'REGISTRO_REMOVIDO: item % (%) apontava para um registro oficial que não existe mais.', v_item.id, v_item.tipo_entidade;
        end if;
        if v_atual is distinct from v_item.dados_oficiais_atuais then
          raise exception 'ALTERADO_DESDE_A_PREVIA: item % (%) — o registro oficial mudou depois da prévia; revalide a importação antes de aplicar.', v_item.id, v_item.tipo_entidade;
        end if;
      end if;

      -- Aplicação por tipo de entidade.
      if v_item.tipo_entidade = 'CIDADE' then
        if v_item.classificacao = 'NOVO' then
          insert into public.cidades_infra (nome, uf, codigo_ibge, endereco, km_rede, observacoes)
          values (v_item.dados_planilha->>'nome', v_item.dados_planilha->>'uf', v_item.dados_planilha->>'codigo_ibge',
                  v_item.dados_planilha->>'endereco', coalesce((v_item.dados_planilha->>'km_rede')::numeric, 0), v_item.dados_planilha->>'observacoes')
          returning id into v_novo_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'cidades_infra', v_novo_id, 'INSERT', null, to_jsonb(c), auth.uid() from public.cidades_infra c where c.id = v_novo_id;
        else
          update public.cidades_infra set
            endereco = coalesce(v_item.dados_planilha->>'endereco', endereco),
            km_rede = coalesce((v_item.dados_planilha->>'km_rede')::numeric, km_rede),
            observacoes = coalesce(v_item.dados_planilha->>'observacoes', observacoes)
          where id = v_item.entidade_oficial_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'cidades_infra', v_item.entidade_oficial_id, 'UPDATE', v_item.dados_oficiais_atuais, to_jsonb(c), auth.uid()
          from public.cidades_infra c where c.id = v_item.entidade_oficial_id;
        end if;

      elsif v_item.tipo_entidade = 'POP' then
        if v_item.classificacao = 'NOVO' then
          insert into public.infra_pops (cidade_id, codigo, nome, endereco, latitude, longitude, tipo, capacidade_total, observacoes)
          select c.id, v_item.dados_planilha->>'codigo', v_item.dados_planilha->>'nome', v_item.dados_planilha->>'endereco',
                 nullif(v_item.dados_planilha->>'latitude','')::numeric, nullif(v_item.dados_planilha->>'longitude','')::numeric,
                 coalesce((v_item.dados_planilha->>'tipo')::pop_tipo, 'ACESSO'), nullif(v_item.dados_planilha->>'capacidade_total','')::integer,
                 v_item.dados_planilha->>'observacoes'
          from public.cidades_infra c where lower(c.nome) = lower(v_item.dados_planilha->>'cidade_nome')
          returning id into v_novo_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'infra_pops', v_novo_id, 'INSERT', null, to_jsonb(p), auth.uid() from public.infra_pops p where p.id = v_novo_id;
        else
          update public.infra_pops set
            nome = coalesce(v_item.dados_planilha->>'nome', nome),
            endereco = coalesce(v_item.dados_planilha->>'endereco', endereco),
            observacoes = coalesce(v_item.dados_planilha->>'observacoes', observacoes)
          where id = v_item.entidade_oficial_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'infra_pops', v_item.entidade_oficial_id, 'UPDATE', v_item.dados_oficiais_atuais, to_jsonb(p), auth.uid()
          from public.infra_pops p where p.id = v_item.entidade_oficial_id;
        end if;

      elsif v_item.tipo_entidade = 'FIBRA' then
        if v_item.classificacao = 'ALTERADO' then
          update public.infra_fibras set
            status_operacional = coalesce((v_item.dados_planilha->>'status_operacional')::fibra_status_operacional, status_operacional),
            observacao = coalesce(v_item.dados_planilha->>'observacao', observacao)
          where id = v_item.entidade_oficial_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'infra_fibras', v_item.entidade_oficial_id, 'UPDATE', v_item.dados_oficiais_atuais, to_jsonb(f), auth.uid()
          from public.infra_fibras f where f.id = v_item.entidade_oficial_id;
        else
          raise exception 'FIBRA_NOVA_NAO_SUPORTADA: cadastro de fibra nova deve vir sempre junto do cabo (item % ).', v_item.id;
        end if;

      elsif v_item.tipo_entidade = 'POSTE' then
        if v_item.classificacao = 'NOVO' then
          insert into public.infra_postes (cidade_id, identificacao, proprietario_terceiro, quantidade, custo_mensal)
          select c.id, v_item.dados_planilha->>'identificacao', v_item.dados_planilha->>'proprietario_terceiro',
                 coalesce((v_item.dados_planilha->>'quantidade')::integer, 1), coalesce((v_item.dados_planilha->>'custo_mensal')::numeric, 0)
          from public.cidades_infra c where lower(c.nome) = lower(v_item.dados_planilha->>'cidade_nome')
          returning id into v_novo_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'infra_postes', v_novo_id, 'INSERT', null, to_jsonb(p), auth.uid() from public.infra_postes p where p.id = v_novo_id;
        else
          update public.infra_postes set
            proprietario_terceiro = coalesce(v_item.dados_planilha->>'proprietario_terceiro', proprietario_terceiro),
            quantidade = coalesce((v_item.dados_planilha->>'quantidade')::integer, quantidade),
            custo_mensal = coalesce((v_item.dados_planilha->>'custo_mensal')::numeric, custo_mensal)
          where id = v_item.entidade_oficial_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'infra_postes', v_item.entidade_oficial_id, 'UPDATE', v_item.dados_oficiais_atuais, to_jsonb(p), auth.uid()
          from public.infra_postes p where p.id = v_item.entidade_oficial_id;
        end if;

      elsif v_item.tipo_entidade = 'SEGMENTO' then
        if v_item.classificacao = 'NOVO' then
          insert into public.infra_segmentos (cidade_id, nome, origem, destino, extensao_km)
          select c.id, v_item.dados_planilha->>'nome', v_item.dados_planilha->>'origem', v_item.dados_planilha->>'destino',
                 coalesce((v_item.dados_planilha->>'extensao_km')::numeric, 0)
          from public.cidades_infra c where lower(c.nome) = lower(v_item.dados_planilha->>'cidade_nome')
          returning id into v_novo_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'infra_segmentos', v_novo_id, 'INSERT', null, to_jsonb(s), auth.uid() from public.infra_segmentos s where s.id = v_novo_id;
        else
          update public.infra_segmentos set
            extensao_km = coalesce((v_item.dados_planilha->>'extensao_km')::numeric, extensao_km)
          where id = v_item.entidade_oficial_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'infra_segmentos', v_item.entidade_oficial_id, 'UPDATE', v_item.dados_oficiais_atuais, to_jsonb(s), auth.uid()
          from public.infra_segmentos s where s.id = v_item.entidade_oficial_id;
        end if;

      elsif v_item.tipo_entidade = 'CABO' then
        if v_item.classificacao = 'NOVO' then
          insert into public.infra_cabos (segmento_id, identificacao, capacidade_fo, fabricante, pop_id)
          values (
            app.fn_resolver_segmento_id(v_item.dados_planilha->>'cidade_nome', v_item.dados_planilha->>'segmento_nome',
                                         v_item.dados_planilha->>'segmento_origem', v_item.dados_planilha->>'segmento_destino'),
            v_item.dados_planilha->>'identificacao', (v_item.dados_planilha->>'capacidade_fo')::integer,
            v_item.dados_planilha->>'fabricante',
            app.fn_resolver_pop_id(v_item.dados_planilha->>'cidade_nome', v_item.dados_planilha->>'pop_codigo')
          )
          returning id into v_novo_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'infra_cabos', v_novo_id, 'INSERT', null, to_jsonb(cb), auth.uid() from public.infra_cabos cb where cb.id = v_novo_id;
        else
          update public.infra_cabos set
            capacidade_fo = coalesce((v_item.dados_planilha->>'capacidade_fo')::integer, capacidade_fo),
            fabricante = coalesce(v_item.dados_planilha->>'fabricante', fabricante)
          where id = v_item.entidade_oficial_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'infra_cabos', v_item.entidade_oficial_id, 'UPDATE', v_item.dados_oficiais_atuais, to_jsonb(cb), auth.uid()
          from public.infra_cabos cb where cb.id = v_item.entidade_oficial_id;
        end if;

      elsif v_item.tipo_entidade = 'PORTA_PON' then
        if v_item.classificacao = 'NOVO' then
          insert into public.infra_portas_pon (fibra_id, pop_id, nome, codigo_porta, tecnologia, capacidade_max_assinantes)
          values (
            app.fn_resolver_fibra_id(v_item.dados_planilha->>'cabo_identificacao', (v_item.dados_planilha->>'numero_fibra')::integer),
            app.fn_resolver_pop_id(v_item.dados_planilha->>'cidade_nome', v_item.dados_planilha->>'pop_codigo'),
            v_item.dados_planilha->>'nome', v_item.dados_planilha->>'codigo_porta',
            coalesce((v_item.dados_planilha->>'tecnologia')::pon_tecnologia, 'GPON'),
            nullif(v_item.dados_planilha->>'capacidade_max_assinantes', '')::integer
          )
          returning id into v_novo_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'infra_portas_pon', v_novo_id, 'INSERT', null, to_jsonb(pp), auth.uid() from public.infra_portas_pon pp where pp.id = v_novo_id;
        else
          -- capacidade_utilizada_assinantes NUNCA é tocada aqui — é dado comercial ao vivo
          -- (conciliação HubSoft), não dado de levantamento de infraestrutura.
          update public.infra_portas_pon set
            nome = coalesce(v_item.dados_planilha->>'nome', nome),
            tecnologia = coalesce((v_item.dados_planilha->>'tecnologia')::pon_tecnologia, tecnologia),
            capacidade_max_assinantes = coalesce(nullif(v_item.dados_planilha->>'capacidade_max_assinantes', '')::integer, capacidade_max_assinantes)
          where id = v_item.entidade_oficial_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'infra_portas_pon', v_item.entidade_oficial_id, 'UPDATE', v_item.dados_oficiais_atuais, to_jsonb(pp), auth.uid()
          from public.infra_portas_pon pp where pp.id = v_item.entidade_oficial_id;
        end if;

      elsif v_item.tipo_entidade = 'CLIENTE_RESERVADO' then
        -- NUNCA grava em contrato_fibras — só em contrato_clientes_reservados, tabela
        -- separada desde a Fase 1. v_contrato_id já foi validado em app.importacao_item_
        -- registrar (item cai INVALIDO se o contrato não existir), mas é resolvido de novo
        -- aqui por segurança (o contrato pode ter sido removido entre a prévia e a aplicação
        -- — nesse caso v_contrato_id vem null e o INSERT abaixo falha por NOT NULL,
        -- corretamente abortando esta aplicação via o bloco EXCEPTION externo).
        if v_item.classificacao = 'NOVO' then
          insert into public.contrato_clientes_reservados (contrato_id, cliente_nome, cnpj_cpf, cidade_id, motivo, status, tipo, documento_referencia)
          values (
            app.fn_resolver_contrato_id(v_item.dados_planilha->>'contrato_numero'),
            v_item.dados_planilha->>'cliente_nome', v_item.dados_planilha->>'cnpj_cpf',
            app.fn_resolver_cidade_id(v_item.dados_planilha->>'cidade_nome'),
            v_item.dados_planilha->>'motivo', coalesce(v_item.dados_planilha->>'status', 'RESERVADO'),
            coalesce(v_item.dados_planilha->>'tipo', 'OUTRO'), v_item.dados_planilha->>'documento_referencia'
          )
          returning id into v_novo_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'contrato_clientes_reservados', v_novo_id, 'INSERT', null, to_jsonb(ccr), auth.uid() from public.contrato_clientes_reservados ccr where ccr.id = v_novo_id;
        else
          update public.contrato_clientes_reservados set
            cnpj_cpf = coalesce(v_item.dados_planilha->>'cnpj_cpf', cnpj_cpf),
            motivo = coalesce(v_item.dados_planilha->>'motivo', motivo),
            status = coalesce(v_item.dados_planilha->>'status', status),
            tipo = coalesce(v_item.dados_planilha->>'tipo', tipo),
            documento_referencia = coalesce(v_item.dados_planilha->>'documento_referencia', documento_referencia)
          where id = v_item.entidade_oficial_id;
          insert into staging.importacao_alteracoes (importacao_id, importacao_item_id, tabela_oficial, registro_id, operacao, valor_anterior, valor_novo, aplicado_por)
          select p_importacao_id, v_item.id, 'contrato_clientes_reservados', v_item.entidade_oficial_id, 'UPDATE', v_item.dados_oficiais_atuais, to_jsonb(ccr), auth.uid()
          from public.contrato_clientes_reservados ccr where ccr.id = v_item.entidade_oficial_id;
        end if;

      else
        raise exception 'APLICACAO_NAO_IMPLEMENTADA: tipo_entidade % (item %) não reconhecido.', v_item.tipo_entidade, v_item.id;
      end if;

      update staging.importacao_itens set aplicado = true where id = v_item.id;
      v_aplicados := v_aplicados + 1;
    end loop;

    update staging.importacoes set status = 'IMPORTADA' where id = p_importacao_id;

    perform app.registrar_auditoria_semantica(
      p_entidade => 'staging.importacoes', p_entidade_id => p_importacao_id, p_acao => 'IMPORT_APPLY',
      p_motivo => format('%s item(ns) aplicado(s)', v_aplicados), p_valor_anterior => null,
      p_valor_novo => jsonb_build_object('itens_aplicados', v_aplicados), p_origem => 'app', p_ip => null
    );

  exception when others then
    get stacked diagnostics v_erro = message_text;

    perform app.registrar_auditoria_semantica(
      p_entidade => 'staging.importacoes', p_entidade_id => p_importacao_id, p_acao => 'IMPORT_APPLY_FAILED',
      p_motivo => v_erro, p_valor_anterior => null, p_valor_novo => null, p_origem => 'app', p_ip => null
    );

    return jsonb_build_object('sucesso', false, 'erro', v_erro, 'status', v_importacao.status);
  end;

  return jsonb_build_object('sucesso', true, 'itens_aplicados', v_aplicados, 'status', 'IMPORTADA');
end;
$function$;

grant execute on function app.importacao_iniciar(text, text, text, bigint) to authenticated;
grant execute on function app.importacao_iniciar_validacao(uuid) to authenticated;
grant execute on function app.importacao_marcar_previa(uuid) to authenticated;
grant execute on function app.importacao_rejeitar(uuid, text) to authenticated;
grant execute on function app.importacao_descartar(uuid) to authenticated;
grant execute on function app.importacao_aprovar(uuid) to authenticated;
grant execute on function app.aplicar_importacao(uuid) to authenticated;

-- Wrappers finos public.* (padrão do projeto).
create or replace function public.importacao_iniciar(p_arquivo_nome_original text, p_arquivo_storage_path text, p_arquivo_hash text, p_arquivo_tamanho_bytes bigint default null)
returns uuid language sql security invoker as $$
  select app.importacao_iniciar(p_arquivo_nome_original, p_arquivo_storage_path, p_arquivo_hash, p_arquivo_tamanho_bytes);
$$;
create or replace function public.importacao_iniciar_validacao(p_importacao_id uuid)
returns void language sql security invoker as $$ select app.importacao_iniciar_validacao(p_importacao_id); $$;
create or replace function public.importacao_marcar_previa(p_importacao_id uuid)
returns jsonb language sql security invoker as $$ select app.importacao_marcar_previa(p_importacao_id); $$;
create or replace function public.importacao_rejeitar(p_importacao_id uuid, p_motivo text)
returns void language sql security invoker as $$ select app.importacao_rejeitar(p_importacao_id, p_motivo); $$;
create or replace function public.importacao_descartar(p_importacao_id uuid)
returns void language sql security invoker as $$ select app.importacao_descartar(p_importacao_id); $$;
create or replace function public.importacao_aprovar(p_importacao_id uuid)
returns void language sql security invoker as $$ select app.importacao_aprovar(p_importacao_id); $$;
create or replace function public.aplicar_importacao(p_importacao_id uuid)
returns jsonb language sql security invoker as $$ select app.aplicar_importacao(p_importacao_id); $$;

grant execute on function public.importacao_iniciar(text, text, text, bigint) to authenticated;
grant execute on function public.importacao_iniciar_validacao(uuid) to authenticated;
grant execute on function public.importacao_marcar_previa(uuid) to authenticated;
grant execute on function public.importacao_rejeitar(uuid, text) to authenticated;
grant execute on function public.importacao_descartar(uuid) to authenticated;
grant execute on function public.importacao_aprovar(uuid) to authenticated;
grant execute on function public.aplicar_importacao(uuid) to authenticated;
