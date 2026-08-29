-- OptiMon — Fase 3.8 (item 3.8-08): estrutura formal de clientes reservados + regra
-- Prefeitura.
--
-- ESTADO ANTES DESTA MIGRATION: public.contrato_clientes_reservados já existia (Fase 3,
-- item 3.7) mas era só texto livre — cliente_nome/cnpj_cpf/motivo/status, sem nenhuma
-- classificação formal do TIPO de reserva. Na minuta gerada (contractDocumentModel.js),
-- a cláusula "Clientes Reservados" tratava toda reserva do mesmo jeito, mencionando
-- "Prefeitura" só no título da seção, nunca com um tratamento jurídico próprio — ou seja,
-- não existia, de fato, nenhuma "regra Prefeitura" formal, só um exemplo hipotético em
-- comentário de código.
--
-- ESTA MIGRATION adiciona:
--   1) coluna `tipo` (PREFEITURA / ORGAO_PUBLICO / OUTRO) — obrigatória, default 'OUTRO'
--      (não quebra as linhas já existentes: ADD COLUMN ... DEFAULT em Postgres 11+ não
--      reescreve a tabela, só passa a valer para leituras/novas linhas);
--   2) coluna `documento_referencia` — nº de ofício/processo administrativo/lei municipal
--      que formaliza a reserva (ex.: "Ofício SEI nº 123/2026-GAB"), opcional (nem toda
--      reserva tem um documento formal ainda, mas quando existir deve ser rastreável);
--   3) atualização de app.contrato_documento_dados() para incluir os 2 campos novos no
--      jsonb consumido pelo gerador de minuta (contractDocumentModel.js, corrigido na
--      mesma leva desta migration para dar tratamento formal e distinto a PREFEITURA).
--
-- Por que uma classificação formal e não só texto livre em `motivo`: reservas do tipo
-- PREFEITURA/órgão público têm implicação jurídica distinta de uma reserva comercial
-- comum (ex.: cliente estratégico da NICK) — o motivo típico é interesse público /
-- contrato administrativo preexistente, não uma decisão comercial da NICK, e a cláusula
-- correspondente na minuta precisa deixar isso explícito para o jurídico (ver
-- contractDocumentModel.js).

alter table public.contrato_clientes_reservados
  add column tipo text not null default 'OUTRO'
    check (tipo in ('PREFEITURA', 'ORGAO_PUBLICO', 'OUTRO')),
  add column documento_referencia text;

comment on column public.contrato_clientes_reservados.tipo is
  'Classificação formal da reserva — PREFEITURA (ente municipal), ORGAO_PUBLICO (outro ente público: estadual/federal/autarquia) ou OUTRO (reserva comercial comum, ex.: cliente estratégico). Determina o tratamento jurídico da cláusula na minuta (ver contractDocumentModel.js).';
comment on column public.contrato_clientes_reservados.documento_referencia is
  'Nº do ofício/processo administrativo/lei municipal que formaliza esta reserva, quando existir (ex.: "Ofício SEI nº 123/2026-GAB"). Nunca obrigatório — nem toda reserva tem documento formal registrado ainda — mas quando presente fica citável na minuta.';

create index contrato_clientes_reservados_tipo_idx on public.contrato_clientes_reservados (tipo) where tipo <> 'OUTRO';

-- app.contrato_documento_dados(): inclui tipo/documento_referencia no jsonb de
-- clientes_reservados. Todo o restante da função é idêntico ao definido em
-- 20260925090000_phase_3_07_minuta_contrato_dados.sql (nenhuma outra seção tocada).
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
