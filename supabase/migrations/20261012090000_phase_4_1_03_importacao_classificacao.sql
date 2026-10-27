-- OptiMon — Fase 4.1 (item 03, revisado na Fase 4.1.1 de fechamento): classificação/
-- comparação (NOVO/ALTERADO/SEM_ALTERACAO/CONFLITO/INVALIDO) + regras de negócio
-- obrigatórias de POP, fibra e poste + matching real de CLIENTE_RESERVADO.
--
-- app.importacao_item_registrar(...) é chamada 1x por linha da planilha (pelo backend Node,
-- depois de parsear o Excel) — nunca escreve em tabela oficial, só em staging.importacao_itens.
-- Todo o casamento planilha↔oficial usa chave_natural (sem nenhuma constraint nova nas
-- tabelas oficiais — condição do usuário). CLIENTE_RESERVADO casa por (contrato_id,
-- cliente_nome), que já é UNIQUE em produção desde a Fase 1 — não é uma chave nova.
--
-- MUDANÇA da Fase 4.1.1 (fechamento, item 6 do pedido do usuário): app.fn_importacao_diff
-- agora só compara os "campos de aplicação" de cada tipo_entidade (app.
-- fn_importacao_campos_aplicados) — os únicos campos que app.aplicar_importacao realmente
-- grava. Campos de identificação (usados só para achar a linha, ex. cidade_nome/codigo) e
-- campos de informação (usados só nas regras de validação, ex. disponivel/tipo_planilha)
-- nunca entram no diff nem contam como "alteração" — evita a prévia mostrar como "campo
-- alterado" algo que não é de fato uma coluna gravável ou que é só um sinal de validação.
--
-- Regras de negócio (inalteradas desde a Migration 3 original):
--   POP: PAÇO não é POP. Códigos "E-*" (caixas de emenda) não são POP. Rota/segmento/
--        caixa-de-emenda/referência física nunca é auto-classificado como POP — INVALIDO.
--   FIBRA: status=OCUPADA + disponivel=SIM é contradição de dados — sempre INVALIDO.
--          status=LIVRE + disponivel=NAO é válido e NUNCA auto-corrigido — só alerta INFO.
--   POSTE: projeto_aprovado=NAO significa REDE EXISTE mas projeto não aprovado — nunca
--          "sem rede". Nunca bloqueia, nunca gera INVALIDO.
--
-- CONFLITO dispara quando a mudança não pode ser aplicada às cegas mesmo sendo legítima:
--   (a) o registro oficial já é alvo de outra importação ainda aberta;
--   (b) para FIBRA: existe contrato_fibras ATIVO (desvinculado_em is null) e a planilha
--       propõe mudar status_comercial/status_contratual — decisão humana obrigatória.
--       Testado agora (Fase 4.1.1) contra o schema REAL de contrato_fibras/contratos/
--       parceiros, não mais um stub — inclusive o caso explícito pedido: importar uma
--       fibra como LIVRE quando existe vínculo contratual ativo (Teste 21).

-- ---------------------------------------------------------------------------
-- app.fn_importacao_campos_aplicados: os únicos campos que app.aplicar_importacao grava
-- de fato, por tipo_entidade — usado para escopar o diff (ver comentário acima).
-- ---------------------------------------------------------------------------
create or replace function app.fn_importacao_campos_aplicados(p_tipo_entidade text)
returns text[]
language sql
immutable
as $$
  select case p_tipo_entidade
    when 'CIDADE' then array['endereco', 'km_rede', 'observacoes']
    when 'POP' then array['nome', 'endereco', 'latitude', 'longitude', 'tipo', 'capacidade_total', 'observacoes']
    when 'SEGMENTO' then array['extensao_km']
    when 'CABO' then array['capacidade_fo', 'fabricante']
    when 'FIBRA' then array['status_operacional', 'observacao']
    when 'POSTE' then array['proprietario_terceiro', 'quantidade', 'custo_mensal']
    when 'PORTA_PON' then array['nome', 'tecnologia', 'capacidade_max_assinantes']
    when 'CLIENTE_RESERVADO' then array['cnpj_cpf', 'motivo', 'status', 'tipo', 'documento_referencia']
    else array[]::text[]
  end;
$$;

comment on function app.fn_importacao_campos_aplicados(text) is 'Fase 4.1.1: lista de colunas que app.aplicar_importacao realmente grava para cada tipo_entidade — usada para escopar app.fn_importacao_diff. Mudar o que é aplicado em Migration 4 exige atualizar esta lista também.';

-- ---------------------------------------------------------------------------
-- Helper genérico: diff campo a campo, restrito aos campos de aplicação do tipo_entidade.
-- ---------------------------------------------------------------------------
create or replace function app.fn_importacao_diff(p_oficial jsonb, p_planilha jsonb, p_campos_aplicados text[])
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'campo', k, 'valor_anterior', p_oficial -> k, 'valor_novo', p_planilha -> k
  )), '[]'::jsonb)
  from unnest(p_campos_aplicados) as k
  where p_planilha ? k
    and (p_oficial is null or (p_oficial -> k) is distinct from (p_planilha -> k));
$$;

-- ---------------------------------------------------------------------------
-- Resolvers de chave estrangeira por nome — usados tanto na classificação (POP/PORTA_PON,
-- que antes casavam sem escopar por cidade) quanto em app.aplicar_importacao (Migration 4)
-- para resolver o id real ao inserir um registro NOVO que referencia outra entidade.
-- ---------------------------------------------------------------------------
create or replace function app.fn_resolver_cidade_id(p_cidade_nome text)
returns uuid language sql stable as $$
  select id from public.cidades_infra where lower(nome) = lower(p_cidade_nome) and removido_em is null limit 1;
$$;

create or replace function app.fn_resolver_pop_id(p_cidade_nome text, p_codigo text)
returns uuid language sql stable as $$
  select p.id from public.infra_pops p join public.cidades_infra c on c.id = p.cidade_id
  where lower(c.nome) = lower(p_cidade_nome) and p.codigo = p_codigo and p.removido_em is null limit 1;
$$;

create or replace function app.fn_resolver_segmento_id(p_cidade_nome text, p_nome text, p_origem text, p_destino text)
returns uuid language sql stable as $$
  select s.id from public.infra_segmentos s join public.cidades_infra c on c.id = s.cidade_id
  where lower(c.nome) = lower(p_cidade_nome) and lower(s.nome) = lower(p_nome)
    and lower(s.origem) = lower(p_origem) and lower(s.destino) = lower(p_destino) and s.removido_em is null
  limit 1;
$$;

-- Simplificação documentada: infra_cabos.identificacao é UNIQUE só por (segmento_id,
-- identificacao), não globalmente — este resolver assume identificação efetivamente única
-- no universo de cabos ativos (prática real da equipe até hoje). Se 2 segmentos tiverem
-- cabos com a mesma identificação, o resolver pega o primeiro encontrado — sinalizado como
-- risco remanescente no relatório final desta fase.
create or replace function app.fn_resolver_cabo_id(p_identificacao text)
returns uuid language sql stable as $$
  select id from public.infra_cabos where identificacao = p_identificacao and removido_em is null limit 1;
$$;

create or replace function app.fn_resolver_fibra_id(p_cabo_identificacao text, p_numero_fibra integer)
returns uuid language sql stable as $$
  select f.id from public.infra_fibras f join public.infra_cabos cb on cb.id = f.cabo_id
  where cb.identificacao = p_cabo_identificacao and cb.removido_em is null and f.numero_fibra = p_numero_fibra
  limit 1;
$$;

create or replace function app.fn_resolver_contrato_id(p_contrato_numero text)
returns uuid language sql stable as $$
  select id from public.contratos where numero = p_contrato_numero and removido_em is null limit 1;
$$;

-- ---------------------------------------------------------------------------
-- Regra POP: PAÇO ≠ POP; códigos "E-*" (caixa de emenda) ≠ POP; nada que pareça
-- rota/segmento/referência física é auto-classificado como POP.
-- ---------------------------------------------------------------------------
create or replace function app.fn_valida_regra_pop(p_dados jsonb)
returns table(valido boolean, motivo text, alertas jsonb)
language plpgsql
immutable
as $$
declare
  v_codigo text := upper(trim(coalesce(p_dados->>'codigo', '')));
  v_nome text := upper(trim(coalesce(p_dados->>'nome', '')));
  v_tipo_planilha text := upper(trim(coalesce(p_dados->>'tipo_planilha', '')));
  v_alertas jsonb := '[]'::jsonb;
begin
  if v_codigo like 'E-%' then
    return query select false,
      format('Código "%s" começa com "E-" — é caixa de emenda, não POP (regra de negócio explícita: E-* nunca é POP).', v_codigo),
      v_alertas;
    return;
  end if;

  if v_nome like '%PACO%' or v_nome like '%PAÇO%' or v_tipo_planilha like '%PACO%' or v_tipo_planilha like '%PAÇO%' then
    return query select false,
      'PAÇO não é POP (regra de negócio explícita) — registro rejeitado como POP.',
      v_alertas;
    return;
  end if;

  if v_tipo_planilha in ('ROTA', 'SEGMENTO', 'CAIXA_EMENDA', 'REFERENCIA_FISICA', 'REFERENCIA') then
    return query select false,
      format('Linha classificada na planilha como "%s" — rota/segmento/caixa-de-emenda/referência física nunca é auto-classificada como POP.', v_tipo_planilha),
      v_alertas;
    return;
  end if;

  return query select true, null::text, v_alertas;
end;
$$;

-- ---------------------------------------------------------------------------
-- Regra FIBRA: OCUPADA + disponivel=SIM é sempre inválido. LIVRE + disponivel=NAO é
-- válido e nunca é auto-corrigido (só alerta informativo).
-- ---------------------------------------------------------------------------
create or replace function app.fn_valida_regra_fibra(p_dados jsonb)
returns table(valido boolean, motivo text, alertas jsonb)
language plpgsql
immutable
as $$
declare
  v_status text := upper(trim(coalesce(p_dados->>'status', '')));
  v_disponivel text := upper(trim(coalesce(p_dados->>'disponivel', '')));
  v_alertas jsonb := '[]'::jsonb;
begin
  if v_status = 'OCUPADA' and v_disponivel = 'SIM' then
    return query select false,
      'Combinação inválida: status=OCUPADA e disponivel=SIM na mesma linha — uma fibra ocupada não pode estar simultaneamente disponível (erro de digitação na planilha de origem; corrija e reenvie).',
      v_alertas;
    return;
  end if;

  if v_status = 'LIVRE' and v_disponivel = 'NAO' then
    v_alertas := v_alertas || jsonb_build_object(
      'tipo', 'INFO',
      'mensagem', 'status=LIVRE com disponivel=NAO — combinação aceita como informada, NUNCA auto-corrigida. Confirme se é intencional (ex.: fibra reservada por outro motivo).'
    );
  end if;

  return query select true, null::text, v_alertas;
end;
$$;

-- ---------------------------------------------------------------------------
-- Regra POSTE: projeto_aprovado=NAO significa rede existente com projeto não aprovado —
-- nunca "sem rede". Nunca bloqueia, nunca gera INVALIDO por causa disso.
-- ---------------------------------------------------------------------------
create or replace function app.fn_valida_regra_poste(p_dados jsonb)
returns table(valido boolean, motivo text, alertas jsonb)
language plpgsql
immutable
as $$
declare
  v_projeto_aprovado text := upper(trim(coalesce(p_dados->>'projeto_aprovado', '')));
  v_alertas jsonb := '[]'::jsonb;
begin
  if v_projeto_aprovado = 'NAO' then
    v_alertas := v_alertas || jsonb_build_object(
      'tipo', 'INFO',
      'mensagem', 'projeto_aprovado=NAO: rede existe, projeto ainda não aprovado. NÃO significa ausência de rede — não bloqueia a importação.'
    );
  end if;
  return query select true, null::text, v_alertas;
end;
$$;

-- ---------------------------------------------------------------------------
-- app.importacao_item_registrar: ponto de entrada único — 1 chamada por linha da planilha.
-- ---------------------------------------------------------------------------
create or replace function app.importacao_item_registrar(
  p_importacao_id uuid,
  p_tipo_entidade text,
  p_linha_planilha integer,
  p_dados_planilha jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, staging, pg_temp
as $function$
declare
  v_importacao staging.importacoes%rowtype;
  v_chave_natural jsonb;
  v_entidade_oficial_id uuid;
  v_dados_oficiais jsonb;
  v_valido boolean := true;
  v_motivo_invalido text;
  v_alertas jsonb := '[]'::jsonb;
  v_diffs jsonb;
  v_classificacao text;
  v_item_id uuid;
  v_regra record;
  v_tem_conflito_concorrente boolean := false;
  v_tem_contrato_ativo boolean := false;
  v_contrato_id uuid;
  v_pop_id uuid;
begin
  select * into v_importacao from staging.importacoes where id = p_importacao_id for update;
  if not found then
    raise exception 'NAO_ENCONTRADO: importação % não encontrada.', p_importacao_id;
  end if;

  if v_importacao.status not in ('RECEBIDA', 'EM_VALIDACAO') then
    raise exception 'ESTADO_INVALIDO: só é possível adicionar itens a uma importação em RECEBIDA/EM_VALIDACAO (atual: %).', v_importacao.status;
  end if;

  if not (
    app.tem_perfil('ADMINISTRADOR')
    or (app.tem_perfil('ENGENHARIA') and v_importacao.criado_por = auth.uid())
  ) then
    raise exception 'NAO_AUTORIZADO: só ENGENHARIA (dono da importação) ou ADMINISTRADOR podem registrar itens.';
  end if;

  -- 1) chave natural + casamento com o oficial, por tipo de entidade.
  if p_tipo_entidade = 'CIDADE' then
    v_chave_natural := jsonb_build_object('nome', p_dados_planilha->>'nome', 'uf', p_dados_planilha->>'uf');
    select id, to_jsonb(c) into v_entidade_oficial_id, v_dados_oficiais
    from public.cidades_infra c
    where lower(c.nome) = lower(p_dados_planilha->>'nome') and upper(c.uf) = upper(p_dados_planilha->>'uf')
      and c.removido_em is null;

  elsif p_tipo_entidade = 'POP' then
    select * into v_regra from app.fn_valida_regra_pop(p_dados_planilha);
    v_valido := v_regra.valido; v_motivo_invalido := v_regra.motivo; v_alertas := v_alertas || v_regra.alertas;

    v_chave_natural := jsonb_build_object('cidade_nome', p_dados_planilha->>'cidade_nome', 'codigo', p_dados_planilha->>'codigo');
    if v_valido then
      v_entidade_oficial_id := app.fn_resolver_pop_id(p_dados_planilha->>'cidade_nome', p_dados_planilha->>'codigo');
      if v_entidade_oficial_id is not null then
        select to_jsonb(p) into v_dados_oficiais from public.infra_pops p where p.id = v_entidade_oficial_id;
      end if;
    end if;

  elsif p_tipo_entidade = 'SEGMENTO' then
    v_chave_natural := jsonb_build_object(
      'cidade_nome', p_dados_planilha->>'cidade_nome',
      'nome', p_dados_planilha->>'nome',
      'origem', p_dados_planilha->>'origem',
      'destino', p_dados_planilha->>'destino'
    );
    -- infra_segmentos não tem chave natural/UNIQUE (proposital — condição do usuário: nenhuma
    -- constraint nova em tabela oficial). Casamento aqui é só por comparação exata dos 4 campos.
    v_entidade_oficial_id := app.fn_resolver_segmento_id(
      p_dados_planilha->>'cidade_nome', p_dados_planilha->>'nome', p_dados_planilha->>'origem', p_dados_planilha->>'destino'
    );
    if v_entidade_oficial_id is not null then
      select to_jsonb(s) into v_dados_oficiais from public.infra_segmentos s where s.id = v_entidade_oficial_id;
    end if;

  elsif p_tipo_entidade = 'CABO' then
    v_chave_natural := jsonb_build_object('segmento_nome', p_dados_planilha->>'segmento_nome', 'identificacao', p_dados_planilha->>'identificacao');
    v_entidade_oficial_id := app.fn_resolver_cabo_id(p_dados_planilha->>'identificacao');
    if v_entidade_oficial_id is not null then
      select to_jsonb(cb) into v_dados_oficiais from public.infra_cabos cb where cb.id = v_entidade_oficial_id;
    end if;

  elsif p_tipo_entidade = 'FIBRA' then
    select * into v_regra from app.fn_valida_regra_fibra(p_dados_planilha);
    v_valido := v_regra.valido; v_motivo_invalido := v_regra.motivo; v_alertas := v_alertas || v_regra.alertas;

    v_chave_natural := jsonb_build_object('cabo_identificacao', p_dados_planilha->>'cabo_identificacao', 'numero_fibra', p_dados_planilha->>'numero_fibra');
    v_entidade_oficial_id := app.fn_resolver_fibra_id(p_dados_planilha->>'cabo_identificacao', (p_dados_planilha->>'numero_fibra')::integer);
    if v_entidade_oficial_id is not null then
      select to_jsonb(f) into v_dados_oficiais from public.infra_fibras f where f.id = v_entidade_oficial_id;
      select exists (
        select 1 from public.contrato_fibras cf where cf.fibra_id = v_entidade_oficial_id and cf.desvinculado_em is null
      ) into v_tem_contrato_ativo;
    end if;

  elsif p_tipo_entidade = 'POSTE' then
    select * into v_regra from app.fn_valida_regra_poste(p_dados_planilha);
    v_valido := v_regra.valido; v_motivo_invalido := v_regra.motivo; v_alertas := v_alertas || v_regra.alertas;

    v_chave_natural := jsonb_build_object(
      'cidade_nome', p_dados_planilha->>'cidade_nome', 'identificacao', p_dados_planilha->>'identificacao'
    );
    -- infra_postes não tem chave natural (condição do usuário) — casamento só quando
    -- identificacao está presente e é não-ambígua; lote sem identificação é sempre NOVO.
    if p_dados_planilha->>'identificacao' is not null then
      select p.id, to_jsonb(p) into v_entidade_oficial_id, v_dados_oficiais
      from public.infra_postes p
      join public.cidades_infra c on c.id = p.cidade_id
      where lower(c.nome) = lower(p_dados_planilha->>'cidade_nome')
        and p.identificacao = p_dados_planilha->>'identificacao'
        and p.removido_em is null;
    end if;

  elsif p_tipo_entidade = 'PORTA_PON' then
    v_chave_natural := jsonb_build_object('cidade_nome', p_dados_planilha->>'cidade_nome', 'pop_codigo', p_dados_planilha->>'pop_codigo', 'codigo_porta', p_dados_planilha->>'codigo_porta');
    -- Correção Fase 4.1.1: antes casava só por pop.codigo (globalmente), sem escopar por
    -- cidade — infra_pops só é único por (cidade_id, codigo), então dois POPs de cidades
    -- diferentes com o mesmo código podiam colidir. Agora resolve o POP escopado pela
    -- cidade informada na planilha, igual ao resto do arquivo.
    v_pop_id := app.fn_resolver_pop_id(p_dados_planilha->>'cidade_nome', p_dados_planilha->>'pop_codigo');
    if v_pop_id is not null then
      select pp.id, to_jsonb(pp) into v_entidade_oficial_id, v_dados_oficiais
      from public.infra_portas_pon pp
      where pp.pop_id = v_pop_id and pp.codigo_porta = p_dados_planilha->>'codigo_porta';
    end if;

  elsif p_tipo_entidade = 'CLIENTE_RESERVADO' then
    v_chave_natural := jsonb_build_object('contrato_numero', p_dados_planilha->>'contrato_numero', 'cliente_nome', p_dados_planilha->>'cliente_nome');

    v_contrato_id := app.fn_resolver_contrato_id(p_dados_planilha->>'contrato_numero');
    if v_contrato_id is null then
      v_valido := false;
      v_motivo_invalido := format('Contrato "%s" não encontrado — CLIENTE_RESERVADO sempre precisa de um contrato existente.', p_dados_planilha->>'contrato_numero');
    else
      -- casamento por (contrato_id, cliente_nome) — UNIQUE já existente desde a Fase 1,
      -- não é chave nova criada por esta feature.
      select id, to_jsonb(ccr) into v_entidade_oficial_id, v_dados_oficiais
      from public.contrato_clientes_reservados ccr
      where ccr.contrato_id = v_contrato_id and lower(ccr.cliente_nome) = lower(p_dados_planilha->>'cliente_nome');
    end if;

  else
    raise exception 'TIPO_ENTIDADE_INVALIDO: % não é um tipo de entidade suportado.', p_tipo_entidade;
  end if;

  -- 2) diff (só os campos de aplicação — ver app.fn_importacao_campos_aplicados) + classificação.
  if v_valido then
    if v_entidade_oficial_id is null then
      v_classificacao := 'NOVO';
      v_diffs := '[]'::jsonb;
    else
      v_diffs := app.fn_importacao_diff(v_dados_oficiais, p_dados_planilha, app.fn_importacao_campos_aplicados(p_tipo_entidade));
      if v_diffs = '[]'::jsonb then
        v_classificacao := 'SEM_ALTERACAO';
      else
        -- 2 gatilhos de CONFLITO (nunca aplicado às cegas, mesmo sendo alteração legítima):
        select exists (
          select 1 from staging.importacao_itens ii
          join staging.importacoes i2 on i2.id = ii.importacao_id
          where ii.entidade_oficial_id = v_entidade_oficial_id
            and ii.importacao_id <> p_importacao_id
            and i2.status in ('RECEBIDA', 'EM_VALIDACAO', 'PREVIA', 'APROVADA')
        ) into v_tem_conflito_concorrente;

        if v_tem_conflito_concorrente then
          v_classificacao := 'CONFLITO';
          v_alertas := v_alertas || jsonb_build_object('tipo', 'CONFLITO',
            'mensagem', 'Este registro oficial já é alvo de outra importação ainda aberta — resolva/finalize a outra importação antes de aprovar esta.');
        elsif p_tipo_entidade = 'FIBRA' and v_tem_contrato_ativo
          and upper(trim(coalesce(p_dados_planilha->>'status', ''))) = 'LIVRE' then
          -- MUDANÇA Fase 4.1.1: checa o campo bruto da planilha (status), não mais o diff
          -- escopado — status_comercial/status_contratual nunca são "campos de aplicação"
          -- de FIBRA (app.aplicar_importacao só grava status_operacional/observacao; quem
          -- governa status_comercial/status_contratual é o vínculo contratual em si, nunca
          -- a importação), então nunca apareceriam no diff escopado (item 6 do fechamento).
          -- A contradição real é: levantamento diz "LIVRE" (disponível) mas existe
          -- contrato_fibras ATIVO para esta fibra agora — decisão humana obrigatória, nunca
          -- aplicado automaticamente (Teste 21: "importar uma fibra como LIVRE quando existe
          -- vínculo contratual ativo").
          v_classificacao := 'CONFLITO';
          v_alertas := v_alertas || jsonb_build_object('tipo', 'CONFLITO',
            'mensagem', 'Levantamento diz status=LIVRE mas esta fibra tem contrato_fibras ATIVO agora — contradição entre o levantamento e o vínculo comercial real. Decisão humana obrigatória, nunca aplicado automaticamente.');
        else
          v_classificacao := 'ALTERADO';
        end if;
      end if;
    end if;
  else
    v_classificacao := 'INVALIDO';
  end if;

  insert into staging.importacao_itens (
    importacao_id, tipo_entidade, linha_planilha, chave_natural, dados_planilha,
    entidade_oficial_id, dados_oficiais_atuais, classificacao, diffs, alertas, valido, motivo_invalido
  ) values (
    p_importacao_id, p_tipo_entidade, p_linha_planilha, v_chave_natural, p_dados_planilha,
    v_entidade_oficial_id, v_dados_oficiais, v_classificacao, v_diffs, v_alertas, v_valido, v_motivo_invalido
  ) returning id into v_item_id;

  return v_item_id;
end;
$function$;

grant execute on function app.importacao_item_registrar(uuid, text, integer, jsonb) to authenticated;

-- Wrapper fino para PostgREST (padrão do projeto: public.* invoca app.*).
create or replace function public.importacao_item_registrar(
  p_importacao_id uuid, p_tipo_entidade text, p_linha_planilha integer, p_dados_planilha jsonb
)
returns uuid
language sql
security invoker
as $$
  select app.importacao_item_registrar(p_importacao_id, p_tipo_entidade, p_linha_planilha, p_dados_planilha);
$$;

grant execute on function public.importacao_item_registrar(uuid, text, integer, jsonb) to authenticated;
