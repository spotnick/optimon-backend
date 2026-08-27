-- OptiMon — Fase 2.5 (5/9): Modelos de contrato + geração automática a partir
-- da proposta assinada (seções 29-33, 52).
--
-- IMPORTANTE (seção 29/34): o OptiMon não inventa cláusula jurídica nenhuma. O
-- `corpo_template` abaixo é uma MINUTA-ESQUELETO claramente identificada como
-- placeholder, para permitir gerar/testar o fluxo de ponta a ponta — o texto
-- jurídico definitivo tem que vir do jurídico da NICK antes de qualquer uso
-- real (documentado de novo no relatório final, seção "Limitações").

create table if not exists public.modelos_contrato (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  tipo text not null default 'CESSAO_USO_INFRAESTRUTURA' check (tipo = any (array['CESSAO_USO_INFRAESTRUTURA'])),
  versao integer not null default 1,
  corpo_template text not null,
  aprovado_por uuid references public.usuarios(id),
  aprovado_em timestamptz,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  unique (tipo, versao)
);

comment on table public.modelos_contrato is 'Fase 2.5 seção 29: modelo jurídico de contrato. `corpo_template` é minuta-placeholder (seção 29/34) — o texto definitivo precisa ser fornecido/aprovado pelo jurídico da NICK antes de uso real; `aprovado_por` fica nulo até isso acontecer.';

alter table public.modelos_contrato enable row level security;

drop policy if exists modelos_contrato_select on public.modelos_contrato;
create policy modelos_contrato_select
  on public.modelos_contrato for select
  to authenticated
  using (true);

drop policy if exists modelos_contrato_write on public.modelos_contrato;
create policy modelos_contrato_write
  on public.modelos_contrato for all
  to authenticated
  using (app.tem_perfil('ADMINISTRADOR', 'DIRETOR'))
  with check (app.tem_perfil('ADMINISTRADOR', 'DIRETOR'));

insert into public.modelos_contrato (nome, tipo, versao, corpo_template, ativo)
values (
  'Contrato de Cessão de Uso de Infraestrutura Óptica — MINUTA PLACEHOLDER (seção 29)',
  'CESSAO_USO_INFRAESTRUTURA',
  1,
  '[MINUTA-ESQUELETO — NÃO É TEXTO JURÍDICO APROVADO. O OptiMon não redige cláusula jurídica automaticamente (seção 29/34 do prompt-mestre da Fase 2.5); este corpo existe só para permitir gerar e testar o documento de ponta a ponta. Antes de qualquer uso real, o jurídico da NICK deve fornecer/aprovar o texto definitivo, cobrindo pelo menos: Objeto; Infraestrutura (Fibras/PON/Localização/Capacidade); Prazo; Carência; Rampa; Remuneração (Mínimo mensal/Revenue Share); Reajuste; Responsabilidades (Instalação/Manutenção/Equipamentos/Acesso); Expansão (novas fibras/PONs/POPs); Aditivos; Rescisão; Penalidades; Inadimplência; Confidencialidade; LGPD; Auditoria; Condições de uso; Responsabilidades regulatórias; Foro; Assinatura.]

CONTRATO DE CESSÃO DE USO DE INFRAESTRUTURA ÓPTICA Nº {{numero_contrato}}

CEDENTE: {{cedente_razao_social}}
CESSIONÁRIO: {{cessionario_razao_social}}, CNPJ {{cessionario_cnpj}}, representado por {{representante_nome}} ({{representante_cargo}}).

CIDADE: {{cidade_nome}}/{{cidade_uf}}
INFRAESTRUTURA: {{infraestrutura_resumo}}
PRAZO: {{prazo_meses}} meses, de {{data_inicio}} a {{data_fim_prevista}}.
VALOR MÍNIMO MENSAL: {{valor_minimo_mensal}}
REVENUE SHARE: {{revenue_share_pct}}
ÍNDICE DE REAJUSTE: {{indice_reajuste}}
CONDIÇÕES ESPECIAIS: {{condicoes_especiais}}

[As cláusulas de Objeto, Responsabilidades, Expansão, Aditivos, Rescisão, Penalidades, Confidencialidade, LGPD, Auditoria, Foro e Assinatura aguardam o texto definitivo do jurídico da NICK.]',
  true
)
on conflict (tipo, versao) do nothing;

-- ============================================================================
-- Geração automática (seção 30-31, 52): proposta ASSINADA -> contrato RASCUNHO
-- preenchido automaticamente. Reaproveita a tabela `contratos` já existente
-- desde a Fase 2 (não cria uma tabela paralela) e cria também as linhas de
-- `contrato_pricing_config`/`contrato_versions` (V1) que já existiam para
-- contratos criados manualmente — a proposta só passa a alimentar o MESMO
-- modelo, em vez de duplicá-lo.
-- ============================================================================

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
  v_recommended numeric;
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
  v_recommended := (v_snapshot->>'recommended')::numeric;

  if v_prazo < 48 and not p_prazo_minimo_excecao then
    raise exception 'PRAZO_MINIMO: contrato mínimo é de 48 meses (seção 32) — prazo da proposta é % meses; use uma exceção autorizada para prosseguir.', v_prazo;
  end if;

  if p_prazo_minimo_excecao and (p_motivo_excecao_prazo is null or trim(p_motivo_excecao_prazo) = '') then
    raise exception 'MOTIVO_OBRIGATORIO: prazo abaixo de 48 meses exige motivo da exceção (seção 32).';
  end if;

  v_numero := 'CONTR-' || to_char(now(), 'YYYYMMDD') || '-' || substr(gen_random_uuid()::text, 1, 8);

  insert into public.contratos (
    numero, parceiro_id, cidade_id, modelo, status, prazo_meses,
    prazo_minimo_excecao, aprovado_por, aprovado_em
  ) values (
    v_numero, v_prop.parceiro_id, v_prop.cidade_id, v_modelo, 'RASCUNHO', v_prazo,
    p_prazo_minimo_excecao,
    case when p_prazo_minimo_excecao then auth.uid() else null end,
    case when p_prazo_minimo_excecao then now() else null end
  )
  returning * into v_contrato;

  insert into public.contrato_pricing_config (contrato_id, percentual_revenue_share, mensalidade_minima_porta)
  values (v_contrato.id, v_revenue_share, v_recommended);

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

comment on function app.gerar_contrato_de_proposta(uuid, boolean, text) is 'Fase 2.5 seções 30-31/52. SECURITY DEFINER (com checagem de RBAC explícita no início, mesmo padrão das seções 21.3/22.3 já documentadas em ARQUITETURA.md): a função escreve em DUAS tabelas com policies diferentes — INSERT em contratos (contratos_insert já cobre COMERCIAL/DIRETOR/ADMINISTRADOR) e UPDATE em propostas_comerciais (propostas_comerciais_update só permite o dono quando status=RASCUNHO — a proposta já está ASSINADA neste ponto, então COMERCIAL ficaria bloqueado silenciosamente na segunda escrita se a função rodasse como SECURITY INVOKER, repetindo exatamente o bug já documentado na Fase 2.3.1). A constraint contratos_prazo_minimo (CHECK já existente desde a Fase 2) também bloqueia prazo<48 meses sem prazo_minimo_excecao=true — por isso a função valida o mesmo antes do INSERT, para dar um erro claro (PRAZO_MINIMO) em vez de deixar a constraint estourar sem contexto.';

drop function if exists public.pricing_contract_generate_from_proposal(uuid);
create or replace function public.pricing_contract_generate_from_proposal(
  p_proposta_id uuid,
  p_prazo_minimo_excecao boolean default false,
  p_motivo_excecao_prazo text default null
)
returns public.contratos
language sql
security invoker
as $$
  select app.gerar_contrato_de_proposta(p_proposta_id, p_prazo_minimo_excecao, p_motivo_excecao_prazo);
$$;

grant execute on function public.pricing_contract_generate_from_proposal(uuid, boolean, text) to authenticated;
