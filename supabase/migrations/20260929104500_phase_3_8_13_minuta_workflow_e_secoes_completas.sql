-- OptiMon — Fase 3.8 (item 3.8-13): revisão completa da minuta (estrutura de 44 seções)
-- + cláusulas novas.
--
-- INVESTIGAÇÃO PRÉVIA (não presumida): a minuta hoje gera 27 seções fixas (Capa +
-- 25 cláusulas + Assinatura), mais até 3 tabelas condicionais (reajustes/ativos/aditivos,
-- só aparecem se houver dado) — abaixo do padrão de 44 seções pedido. Revisão cláusula a
-- cláusula confirmou que todo o conteúdo já corrigido nesta Fase 3.8 (modelo econômico
-- SOMA, clientes reservados/Prefeitura, ativos cedidos com devolução formal) já está
-- correto e sem texto desatualizado — a única lacuna de CONTEÚDO (não de contagem) é que
-- a cláusula "Rede Própria do Parceiro e Fibras de Terceiros" ainda descrevia só o
-- guardrail booleano antigo, sem citar o workflow formal de 3 etapas
-- (Engenharia→Comercial→Diretoria) implementado no item 3.8-09/10 desta mesma fase —
-- porque app.contrato_documento_dados() nunca expunha contrato_regras_solicitacoes.
--
-- ESTA MIGRATION: adiciona 'regras_solicitacoes' ao jsonb de dados da minuta (aditivo —
-- todo o restante da função permanece idêntico ao definido em 20260929091500). O texto da
-- cláusula em si é corrigido em api/lib/contractDocumentModel.js (código, não SQL) — essa
-- migration só abre a fonte de dado que faltava.

create or replace function app.contrato_documento_dados(p_contrato_id uuid)
returns jsonb
language plpgsql
stable
as $function$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'contrato', to_jsonb(c) - 'removido_em',
    'parceiro', to_jsonb(p),
    'cidade', to_jsonb(ci),
    'pricing_config', (select to_jsonb(cpc) from public.contrato_pricing_config cpc where cpc.contrato_id = c.id),
    'regras', (select to_jsonb(cr) from public.contrato_regras cr where cr.contrato_id = c.id),
    'clientes_reservados', coalesce((
      select jsonb_agg(jsonb_build_object(
        'cliente_nome', ccr.cliente_nome, 'cnpj_cpf', ccr.cnpj_cpf, 'motivo', ccr.motivo,
        'status', ccr.status, 'tipo', ccr.tipo, 'documento_referencia', ccr.documento_referencia
      ) order by (ccr.tipo <> 'OUTRO') desc, ccr.cliente_nome)
      from public.contrato_clientes_reservados ccr where ccr.contrato_id = c.id
    ), '[]'::jsonb),
    'ativos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'tipo', a.tipo, 'fabricante', a.fabricante, 'modelo', a.modelo,
        'numero_serie', a.numero_serie, 'patrimonio', a.patrimonio, 'status', a.status
      ) order by a.tipo, a.patrimonio)
      from public.ativos a where a.contrato_id = c.id and a.removido_em is null
    ), '[]'::jsonb),
    'fibras_count', (select count(*) from public.contrato_fibras cf where cf.contrato_id = c.id and cf.desvinculado_em is null),
    'pons_count', (select count(*) from public.contrato_fibras cf where cf.contrato_id = c.id and cf.desvinculado_em is null and cf.porta_pon_id is not null),
    'aditivos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'numero', ca.numero, 'tipo', ca.tipo, 'descricao', ca.descricao, 'status', ca.status, 'data', ca.data
      ) order by ca.numero)
      from public.contrato_aditivos ca where ca.contrato_id = c.id
    ), '[]'::jsonb),
    'reajustes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'competencia_base', r.competencia_base, 'percentual_aplicado', r.percentual_aplicado, 'status', r.status
      ) order by r.competencia_base desc)
      from public.reajustes r where r.contrato_id = c.id
    ), '[]'::jsonb),
    -- Fase 3.8 (item 3.8-13): campo novo — solicitações de exceção de fibra de terceiros/
    -- rede própria (workflow de 3 etapas do item 3.8-09/10), para a minuta poder listar
    -- exceções formalmente concedidas (ou em tramitação/rejeitadas) em vez de só citar o
    -- guardrail booleano genérico.
    'regras_solicitacoes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'tipo', rs.tipo, 'status', rs.status, 'descricao', rs.descricao,
        'parecer_engenharia', rs.parecer_engenharia, 'parecer_comercial', rs.parecer_comercial,
        'motivo_rejeicao', rs.motivo_rejeicao, 'etapa_rejeicao', rs.etapa_rejeicao,
        'criado_em', rs.criado_em
      ) order by rs.criado_em desc)
      from public.contrato_regras_solicitacoes rs where rs.contrato_id = c.id
    ), '[]'::jsonb)
  ) into v_result
  from public.contratos c
  join public.parceiros p on p.id = c.parceiro_id
  join public.cidades_infra ci on ci.id = c.cidade_id
  where c.id = p_contrato_id;

  if v_result is null then
    raise exception 'NAO_ENCONTRADO: contrato % não encontrado.', p_contrato_id;
  end if;

  return v_result;
end;
$function$;

comment on function app.contrato_documento_dados(uuid) is 'Fase 3 (item 3.7) + Fase 3.8 (itens 3.8-08/3.8-13): dados consolidados (nunca texto de cláusula) para gerar a minuta de contrato — ver api/lib/contractDocumentModel.js para o texto. regras_solicitacoes adicionado no item 3.8-13 para a cláusula de fibra de terceiros/rede própria poder citar o workflow formal de exceção.';
