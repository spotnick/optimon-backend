-- OptiMon — Fase 2.3: Módulo de Gestão de Cidades e Infraestrutura
-- Migration 2/3: lacuna real de auditoria (seção 38) + wrapper de criação de cabo+fibras.
--
-- LACUNA ENCONTRADA (mesmo padrão de disclosure das Fases 2.1/2.2: "cidades_infra nunca
-- teve trigger", "infra_fibras nunca teve trigger"): infra_cabos, infra_segmentos e
-- infra_postes NUNCA tiveram trigger de auditoria. Até aqui isso não era exercitado
-- porque só o seed criava essas linhas; a partir desta fase, ENGENHARIA cria/edita cabos,
-- segmentos e postes pela tela "Cidades & Infraestrutura" (seção 38 exige explicitamente
-- "cabo criado/alterado" e "poste alterado" no log de auditoria). Corrigido aqui.

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_aud_infra_segmentos' and tgrelid = 'public.infra_segmentos'::regclass) then
    create trigger trg_aud_infra_segmentos
      after insert or update or delete on public.infra_segmentos
      for each row execute function public.fn_auditoria();
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'trg_aud_infra_cabos' and tgrelid = 'public.infra_cabos'::regclass) then
    create trigger trg_aud_infra_cabos
      after insert or update or delete on public.infra_cabos
      for each row execute function public.fn_auditoria();
  end if;

  if not exists (select 1 from pg_trigger where tgname = 'trg_aud_infra_postes' and tgrelid = 'public.infra_postes'::regclass) then
    create trigger trg_aud_infra_postes
      after insert or update or delete on public.infra_postes
      for each row execute function public.fn_auditoria();
  end if;
end $$;

comment on trigger trg_aud_infra_segmentos on public.infra_segmentos is 'Fase 2.3 (seção 38): lacuna real — infra_segmentos nunca teve trigger de auditoria.';
comment on trigger trg_aud_infra_cabos on public.infra_cabos is 'Fase 2.3 (seção 38): lacuna real — infra_cabos nunca teve trigger de auditoria, apesar de a seção pedir explicitamente "cabo criado/alterado" no log.';
comment on trigger trg_aud_infra_postes on public.infra_postes is 'Fase 2.3 (seção 38): lacuna real — infra_postes nunca teve trigger de auditoria, apesar de a seção pedir explicitamente "poste alterado" no log.';

-- ============================================================================
-- app.criar_cabo_com_fibras — único wrapper de infraestrutura desta fase com lógica de
-- negócio real (justifica existir per seção 13: "somente os necessários"). POP, Segmento,
-- Poste e Porta PON são INSERT/UPDATE diretos nas tabelas via supabase-js a partir da API
-- (routes/infra.js) — a RLS de cada tabela (ENGENHARIA/ADMINISTRADOR escrevem, todo
-- authenticated lê) já é a autorização real, e os triggers de auditoria já existentes
-- (ou criados acima) cobrem o log independentemente de vir por RPC ou INSERT direto —
-- duplicar isso em wrappers SQL não agregaria nada (seção 13 do prompt: "criar somente
-- wrappers necessários"). Cabo é diferente: cadastrar um cabo sem gerar as fibras
-- correspondentes deixa a cidade inconsistente (cabo "capacidade_fo=12" com 0 fibras) e
-- fazer isso em 2 chamadas separadas do frontend arrisca ficar pela metade se a segunda
-- falhar — por isso vira 1 transação atômica no banco (mesmo padrão usado no seed:
-- fibras 1..capacidade_fo, par_numero = ceil(numero/2), status LIVRE).
-- ============================================================================

create or replace function app.criar_cabo_com_fibras(
  p_segmento_id uuid,
  p_identificacao text,
  p_capacidade_fo integer,
  p_pop_id uuid default null,
  p_fabricante text default null
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_cabo_id uuid;
  i integer;
begin
  if not app.tem_perfil('ENGENHARIA', 'ADMINISTRADOR') then
    raise exception 'PERMISSAO_NEGADA: seu perfil (%) não pode cadastrar cabos — só ENGENHARIA ou ADMINISTRADOR.', app.perfil_atual();
  end if;

  if p_segmento_id is null then
    raise exception 'Segmento é obrigatório.';
  end if;
  if p_identificacao is null or btrim(p_identificacao) = '' then
    raise exception 'Identificação do cabo é obrigatória.';
  end if;
  if p_capacidade_fo is null or p_capacidade_fo <= 0 then
    raise exception 'Capacidade de FO deve ser maior que zero.';
  end if;
  if not exists (select 1 from public.infra_segmentos where id = p_segmento_id and removido_em is null) then
    raise exception 'Segmento % não encontrado.', p_segmento_id;
  end if;
  if p_pop_id is not null and not exists (select 1 from public.infra_pops where id = p_pop_id and removido_em is null) then
    raise exception 'POP % não encontrado.', p_pop_id;
  end if;

  insert into public.infra_cabos (segmento_id, pop_id, identificacao, capacidade_fo, fabricante)
  values (p_segmento_id, p_pop_id, btrim(p_identificacao), p_capacidade_fo, p_fabricante)
  returning id into v_cabo_id;

  for i in 1..p_capacidade_fo loop
    insert into public.infra_fibras (cabo_id, numero_fibra, par_numero, status)
    values (v_cabo_id, i, ceil(i / 2.0), 'LIVRE');
  end loop;

  return v_cabo_id;
end;
$$;
comment on function app.criar_cabo_com_fibras(uuid, text, integer, uuid, text) is 'Fase 2.3 (seções 15, 17, 22): cria o cabo E as N fibras (LIVRE, par = ceil(numero/2)) em uma transação — evita cabo sem fibras por falha parcial de 2 chamadas separadas.';

create or replace function public.pricing_cable_create_with_fibers(
  p_segmento_id uuid, p_identificacao text, p_capacidade_fo integer,
  p_pop_id uuid default null, p_fabricante text default null
)
returns uuid
language sql
security invoker
as $$
  select app.criar_cabo_com_fibras(p_segmento_id, p_identificacao, p_capacidade_fo, p_pop_id, p_fabricante);
$$;
comment on function public.pricing_cable_create_with_fibers(uuid, text, integer, uuid, text) is 'POST /api/infra/cables (seção 15).';

grant execute on function public.pricing_cable_create_with_fibers(uuid, text, integer, uuid, text) to authenticated;
