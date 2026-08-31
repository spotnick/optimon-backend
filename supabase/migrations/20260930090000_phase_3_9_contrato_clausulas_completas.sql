-- OptiMon — Fase 3.9 (revisão das cláusulas contratuais + modelo de cessão de uso)
--
-- Adiciona os campos estruturados que faltavam para o novo motor de cláusulas do
-- contrato (api/lib/contractDocumentModel.js): decisão jurídica sobre multa de rescisão
-- antecipada e sobre o mecanismo de proteção da carteira quando a NICK cede ativos
-- (OLT/ONU), além de um compromisso de Take-or-Pay em QUANTIDADE de clientes (distinto
-- do Take-or-Pay monetário já existente em contrato_pricing_config.mensalidade_minima_
-- porta). Também corrige um drift real já existente entre o enum de tipos de aditivo
-- que o frontend (ContractDetail.jsx TIPOS_ADITIVO) já oferece e o CHECK do banco — 3
-- tipos que o frontend já envia sempre falhariam com violação de constraint — e estende
-- app.contrato_documento_dados() com os dados que as cláusulas novas precisam: tabela de
-- infraestrutura por recurso cedido, rampa de maturação com os valores reais aplicáveis
-- a este contrato, devoluções de ativos já registradas e contagem de clientes ativos.
--
-- REGRA MANTIDA (ver contractDocumentModel.js): nenhum texto de cláusula jurídica vive
-- em SQL — esta migration só abre fontes de dado reais. Os campos de multa e de proteção
-- da carteira ficam NULL/NAO_DEFINIDO até o jurídico da NICK decidir; a minuta sinaliza
-- isso explicitamente em vez de inventar um percentual ou mecanismo (nunca hardcoded).

-- ============================================================================
-- 1) TAKE-OR-PAY EM QUANTIDADE DE CLIENTES (distinto do Take-or-Pay monetário já
--    existente em contrato_pricing_config.mensalidade_minima_porta)
-- ============================================================================
alter table public.contrato_pricing_config
  add column take_or_pay_clientes integer check (take_or_pay_clientes is null or take_or_pay_clientes >= 0);

comment on column public.contrato_pricing_config.take_or_pay_clientes is 'Compromisso mínimo de clientes ativos (quantidade) assumido pelo parceiro, distinto e complementar ao Take-or-Pay monetário (mensalidade_minima_porta). NULL = sem compromisso de quantidade configurado para este contrato.';

-- trg_aud_contrato_pricing_config (já existente) audita qualquer UPDATE nesta tabela —
-- nenhum trigger novo necessário para esta coluna.

-- ============================================================================
-- 2) PROTEÇÃO DA CARTEIRA quando a NICK cede OLT/ativos — nunca copropriedade
--    automática da carteira de clientes. Mecanismo a ser escolhido pelo jurídico
--    dentre as opções técnico-comerciais avaliadas.
-- ============================================================================
alter table public.contrato_regras
  add column mecanismo_protecao_carteira text not null default 'NAO_DEFINIDO'
    check (mecanismo_protecao_carteira in (
      'NAO_DEFINIDO',
      'OPCAO_A_DIREITO_PREFERENCIA_AQUISICAO',
      'OPCAO_B_DIREITO_CONTINUIDADE_OPERACAO',
      'OPCAO_C_COMPENSACAO_ECONOMICA',
      'OPCAO_D_DEVOLUCAO_OU_AQUISICAO_ATIVOS'
    )),
  add column detalhe_protecao_carteira text;

comment on column public.contrato_regras.mecanismo_protecao_carteira is 'Mecanismo de proteção econômica da NICK sobre a operação do parceiro quando há ativos (OLT/ONU) cedidos — decisão do jurídico dentre as 4 opções avaliadas (direito de preferência de aquisição / direito de continuidade / compensação econômica / devolução ou aquisição de ativos). NAO_DEFINIDO (padrão) até essa decisão ser tomada. NUNCA transforma a carteira de clientes em copropriedade automática da NICK.';
comment on column public.contrato_regras.detalhe_protecao_carteira is 'Texto do jurídico detalhando a aplicação do mecanismo escolhido a este contrato específico.';

-- trg_aud_contrato_regras (Fase 1, já existente) audita qualquer UPDATE nesta tabela —
-- nenhum trigger novo necessário para estas duas colunas.

-- ============================================================================
-- 3) RESCISÃO ANTECIPADA — multa configurável, nunca um percentual fixo em código/SQL.
--    Tabela nova (não cabe em contrato_regras: é decisão jurídica específica sobre
--    encerramento, não um guardrail operacional). Todos os campos de conteúdo são
--    nullable — ficam vazios até o jurídico decidir; a minuta sinaliza isso
--    explicitamente em vez de presumir um valor.
-- ============================================================================
create table public.contrato_rescisao_config (
  id uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.contratos(id) on delete restrict,
  tipo_multa text check (tipo_multa is null or tipo_multa in ('PERCENTUAL_SALDO_MINIMO', 'VALOR_FIXO', 'FORMULA_JURIDICO')),
  percentual_multa numeric(6,4) check (percentual_multa is null or (percentual_multa >= 0 and percentual_multa <= 1)),
  base_calculo text,
  limite_multa numeric(14,2) check (limite_multa is null or limite_multa >= 0),
  aviso_previo_dias integer check (aviso_previo_dias is null or aviso_previo_dias >= 0),
  observacoes text,
  definido_por uuid references public.usuarios(id),
  definido_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (contrato_id)
);
create trigger trg_contrato_rescisao_config_atualizado_em
  before update on public.contrato_rescisao_config
  for each row execute function public.set_atualizado_em();
create trigger trg_aud_contrato_rescisao_config
  after insert or update or delete on public.contrato_rescisao_config
  for each row execute function public.fn_auditoria();

-- definido_por/definido_em nunca são aceitos vindos do cliente/rota JS (mesmo padrão já
-- usado em fn_regra_solicitacao_nasce para solicitado_por) — sempre carimbados aqui a
-- partir de auth.uid(), e só quando algum campo de conteúdo de fato mudou (evita
-- carimbar de novo, com outro usuário, um UPDATE que não alterou nada de fato).
create or replace function public.fn_rescisao_config_carimba()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'INSERT' or
     new.tipo_multa is distinct from old.tipo_multa or
     new.percentual_multa is distinct from old.percentual_multa or
     new.base_calculo is distinct from old.base_calculo or
     new.limite_multa is distinct from old.limite_multa or
     new.aviso_previo_dias is distinct from old.aviso_previo_dias or
     new.observacoes is distinct from old.observacoes then
    new.definido_por := auth.uid();
    new.definido_em := now();
  end if;
  return new;
end;
$$;

create trigger trg_rescisao_config_carimba
  before insert or update on public.contrato_rescisao_config
  for each row execute function public.fn_rescisao_config_carimba();

comment on function public.fn_rescisao_config_carimba() is 'Fase 3.9: carimba definido_por/definido_em = auth.uid()/now() automaticamente quando o conteúdo de contrato_rescisao_config muda — nunca aceito vindo do cliente/rota JS, mesmo padrão de fn_regra_solicitacao_nasce.';

comment on table public.contrato_rescisao_config is 'Parâmetros de multa por rescisão antecipada, definidos pelo jurídico da NICK por contrato — nunca hardcoded em código/SQL (seção 22 do modelo de cessão). Ausência de linha, ou campos NULL, significa "ainda não definido"; a minuta (contractDocumentModel.js) sinaliza isso explicitamente, nunca presume um percentual.';
comment on column public.contrato_rescisao_config.tipo_multa is 'Critério de cálculo escolhido pelo jurídico: percentual sobre o saldo mínimo vincendo, valor fixo, ou fórmula própria (documentada em observacoes/base_calculo).';
comment on column public.contrato_rescisao_config.base_calculo is 'Descrição textual da base de cálculo aplicável (ex.: "soma das mensalidades mínimas vincendas até o fim do prazo mínimo contratual").';
comment on column public.contrato_rescisao_config.limite_multa is 'Teto opcional em R$ para a multa calculada, se o jurídico definir um.';

alter table public.contrato_rescisao_config enable row level security;
create policy contrato_rescisao_config_select on public.contrato_rescisao_config for select to authenticated using (true);
create policy contrato_rescisao_config_write on public.contrato_rescisao_config for all to authenticated
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR')) with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

-- O GRANT em "all tables in schema public" de 20260825101300 (Fase 1.1) só cobria as
-- tabelas que já existiam naquele momento — toda tabela nova criada depois precisa do
-- próprio GRANT (mesmo padrão de 20260913090900_phase_2_5_10_grants_tabelas_novas.sql).
-- Confirmado que isso NÃO é opcional testando de verdade contra um banco real: sem esta
-- linha, um INSERT como DIRETOR falha com "permission denied for table
-- contrato_rescisao_config" (erro de GRANT, ANTES mesmo da RLS ser avaliada) — não com a
-- mensagem de RLS ("new row violates row-level security policy"), que seria o erro
-- esperado apenas para o perfil sem permissão.
grant select, insert, update, delete on public.contrato_rescisao_config to authenticated;

-- ============================================================================
-- 4) CORREÇÃO DE DRIFT: contrato_aditivos.tipo já estava desatualizado em relação ao
--    enum que o frontend (ContractDetail.jsx TIPOS_ADITIVO) já oferecia antes desta
--    fase — ALTERACAO_CAPACIDADE / ALTERACAO_EXCLUSIVIDADE / ALTERACAO_REGRAS_COBRANCA
--    sempre falhariam com violação de CHECK ao serem submetidos (bug real, encontrado
--    ao investigar se o sistema de aditivos já era genérico o bastante para o novo
--    modelo de cessão — seção 2 do prompt: "recursos adicionais sejam incorporados
--    mediante Termo Aditivo"). Corrigido para permitir formalizar por aditivo novas
--    portas PON, fibras, capacidade, exclusividade e regras de cobrança.
-- ============================================================================
alter table public.contrato_aditivos drop constraint if exists contrato_aditivos_tipo_check;
alter table public.contrato_aditivos add constraint contrato_aditivos_tipo_check check (tipo in (
  'INCLUSAO_FIBRA', 'INCLUSAO_PORTA', 'EXCLUSAO_FIBRA', 'EXCLUSAO_PORTA',
  'ALTERACAO_PRAZO', 'ALTERACAO_COMERCIAL', 'ALTERACAO_CAPACIDADE',
  'ALTERACAO_EXCLUSIVIDADE', 'ALTERACAO_REGRAS_COBRANCA', 'OUTRO'
));

-- ============================================================================
-- 5) app.contrato_documento_dados() — estende com os dados que as cláusulas novas de
--    contractDocumentModel.js precisam: tabela de infraestrutura por recurso cedido
--    (cidade/POP/rota/cabo/capacidade do cabo/fibra-ou-PON/km/postes envolvidos/
--    capacidade máxima/data de início — seção 3 do modelo de cessão), rampa de
--    maturação com os valores reais aplicáveis a este contrato (contrato-específica
--    com fallback para a régua padrão global — nunca mais "conferir no sistema"),
--    devoluções de ativos já registradas (seção 15), config de rescisão (seção 22) e
--    contagem de clientes ativos vinculados a este contrato (para a cláusula de
--    Take-or-Pay em quantidade, seção 21). Todo o restante da função permanece
--    idêntico ao definido em 20260929104500.
-- ============================================================================
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
    'rescisao_config', (select to_jsonb(rc) from public.contrato_rescisao_config rc where rc.contrato_id = c.id),
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
    'ativos_devolucao', coalesce((
      select jsonb_agg(jsonb_build_object(
        'ativo_tipo', a.tipo, 'ativo_patrimonio', a.patrimonio, 'ativo_numero_serie', a.numero_serie,
        'data_solicitacao', ad.data_solicitacao, 'data_devolucao', ad.data_devolucao,
        'condicao', ad.condicao, 'valor_perdas_danos', ad.valor_perdas_danos, 'status_final', ad.status_final
      ) order by ad.data_solicitacao desc)
      from public.ativos_devolucao ad join public.ativos a on a.id = ad.ativo_id
      where ad.contrato_id = c.id
    ), '[]'::jsonb),
    'fibras_count', (select count(*) from public.contrato_fibras cf where cf.contrato_id = c.id and cf.desvinculado_em is null),
    'pons_count', (select count(*) from public.contrato_fibras cf where cf.contrato_id = c.id and cf.desvinculado_em is null and cf.porta_pon_id is not null),
    'clientes_ativos_contrato', coalesce((
      select sum(pon.capacidade_utilizada_assinantes)
      from public.contrato_fibras cf
      join public.infra_portas_pon pon on pon.id = cf.porta_pon_id
      where cf.contrato_id = c.id and cf.desvinculado_em is null and cf.porta_pon_id is not null
    ), 0),
    'infraestrutura_detalhe', coalesce((
      select jsonb_agg(jsonb_build_object(
        'cidade', ci.nome, 'uf', ci.uf,
        'pop', pop.nome,
        'rota', seg.nome, 'rota_origem', seg.origem, 'rota_destino', seg.destino,
        'cabo', cab.identificacao, 'cabo_capacidade_fo', cab.capacidade_fo,
        'recurso_cedido', case when cf.porta_pon_id is not null then 'Porta PON' else 'Fibra Apagada' end,
        'identificacao_recurso', case when cf.porta_pon_id is not null then pon2.codigo_porta else ('Fibra ' || fib.numero_fibra || ' (par ' || fib.par_numero || ')') end,
        'comprimento_km', seg.extensao_km,
        'postes_envolvidos', (select coalesce(sum(pt.quantidade), 0) from public.infra_postes pt where pt.segmento_id = seg.id),
        'capacidade_maxima', pon2.capacidade_max_assinantes,
        'data_inicio', cf.vinculado_em
      ) order by ci.nome, pop.nome, seg.nome)
      from public.contrato_fibras cf
      join public.infra_fibras fib on fib.id = cf.fibra_id
      join public.infra_cabos cab on cab.id = fib.cabo_id
      join public.infra_segmentos seg on seg.id = cab.segmento_id
      left join public.infra_pops pop on pop.id = cab.pop_id
      left join public.infra_portas_pon pon2 on pon2.id = cf.porta_pon_id
      where cf.contrato_id = c.id and cf.desvinculado_em is null
    ), '[]'::jsonb),
    'rampa', coalesce((
      select jsonb_agg(jsonb_build_object(
        'month_start', r.month_start, 'month_end', r.month_end,
        'percentage', r.percentage, 'component', r.component
      ) order by r.month_start)
      from public.pricing_ramp_rules r
      where r.contrato_id = c.id
         or (r.contrato_id is null and not exists (select 1 from public.pricing_ramp_rules r2 where r2.contrato_id = c.id))
    ), '[]'::jsonb),
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

comment on function app.contrato_documento_dados(uuid) is 'Fase 3 (item 3.7) + Fase 3.8 (3.8-08/3.8-13) + Fase 3.9 (revisão de cláusulas contratuais): dados consolidados para a minuta — nunca texto de cláusula, ver contractDocumentModel.js. Fase 3.9 adiciona infraestrutura_detalhe (tabela por fibra/PON cedido), rampa (valores reais aplicáveis a este contrato), ativos_devolucao, rescisao_config e clientes_ativos_contrato.';

-- ============================================================================
-- Nenhuma ação nova precisa ser adicionada à whitelist de
-- app.registrar_auditoria_semantica: as tabelas/colunas novas desta migration já são
-- cobertas pelos triggers genéricos fn_auditoria() (trg_aud_contrato_regras já
-- existente desde a Fase 1 + trg_aud_contrato_rescisao_config criado acima), que
-- gravam INSERT/UPDATE/DELETE diretamente em public.auditoria.
-- ============================================================================
