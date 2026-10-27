-- OptiMon — OptiMap Fase 2 (fundação geográfica) — Migration 4/4: RLS, privilégios e
-- auditoria das tabelas gis_*.
--
-- Nenhuma policy existente é alterada. Diferente das tabelas infra_* (SELECT using(true)
-- para authenticated), NENHUMA tabela gis_* usa using(true): leitura é por perfil.
--
-- Matriz aprovada (relatório Fase 1, seção 11 + Adendo 1):
--   ver mapa (rede própria + referências)  : ADMINISTRADOR, DIRETOR, ENGENHARIA, COMERCIAL, AUDITOR
--   editar rede própria / validar          : ENGENHARIA, ADMINISTRADOR
--   gravar postes de referência externos   : ADMINISTRADOR (a importação da Fase 4 terá fluxo próprio)
--   administrar fontes                     : ADMINISTRADOR
--   FINANCEIRO                             : sem acesso ao OptiMap
--   DELETE físico                          : ninguém (exceto gis_trecho_postes, que é lista de ligação)
--   gis_validacoes                         : só leitura; escrita exclusiva do trigger

-- ---------------------------------------------------------------------------
-- Privilégios de tabela (RLS só restringe; sem GRANT nada funciona — lição da Fase 2.5)
-- ---------------------------------------------------------------------------
-- Começa do zero: o Supabase concede ALL (inclusive TRUNCATE, que ignora RLS e triggers de
-- linha) a anon/authenticated em toda tabela nova do public por default privileges.
revoke all on public.gis_fontes, public.gis_postes_referencia, public.gis_postes, public.gis_elementos,
              public.gis_trechos, public.gis_trecho_postes, public.gis_validacoes from anon, authenticated;

-- Leitura: RLS por perfil (abaixo).
grant select on public.gis_fontes, public.gis_postes_referencia, public.gis_postes, public.gis_elementos,
                public.gis_trechos, public.gis_trecho_postes, public.gis_validacoes to authenticated;

-- Escrita direta SÓ onde é administrativa e restrita a ADMINISTRADOR pela RLS:
-- catálogo de fontes e postes de referência (a importação da Fase 4 terá função própria).
grant insert, update on public.gis_fontes, public.gis_postes_referencia to authenticated;

-- gis_postes, gis_elementos, gis_trechos, gis_trecho_postes: SEM INSERT/UPDATE/DELETE para
-- authenticated. Toda escrita da rede própria passa pelas funções app.gis_* (Migration 3),
-- que aplicam perfil + regras (motivo obrigatório, fonte PROPRIA, dependências, cidade...).
-- Assim nada disso pode ser contornado com um POST/PATCH direto no PostgREST.

revoke all on public.vw_gis_pops, public.vw_gis_conciliacao_lotes_postes,
              public.vw_gis_divergencia_extensao_segmento, public.vw_gis_documentacao_incompleta from anon, authenticated;
grant select on public.vw_gis_pops, public.vw_gis_conciliacao_lotes_postes,
                public.vw_gis_divergencia_extensao_segmento, public.vw_gis_documentacao_incompleta to authenticated;

-- Wrappers da API: só usuários autenticados.
do $$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'optimap\_%'
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
-- Regras de perfil vêm de app.gis_pode_ver()/app.gis_pode_editar() (Migration 3) — a mesma
-- fonte usada pelas funções de leitura espacial. Todas as checagens são escritas como
-- (select app.gis_pode_...()): o Postgres
-- avalia uma única vez por consulta (InitPlan) em vez de uma vez por linha. Sem isso, a
-- checagem de RLS (não-leakproof) impede o uso do índice espacial GiST e uma consulta de
-- bairro sobre 40 mil postes leva ~1 s (medido no sandbox) em vez de milissegundos.
alter table public.gis_fontes enable row level security;
alter table public.gis_postes_referencia enable row level security;
alter table public.gis_postes enable row level security;
alter table public.gis_elementos enable row level security;
alter table public.gis_trechos enable row level security;
alter table public.gis_trecho_postes enable row level security;
alter table public.gis_validacoes enable row level security;

-- Leitura
create policy gis_fontes_select on public.gis_fontes for select to authenticated
  using ((select app.gis_pode_ver()));
create policy gis_postes_referencia_select on public.gis_postes_referencia for select to authenticated
  using ((select app.gis_pode_ver()));
create policy gis_postes_select on public.gis_postes for select to authenticated
  using ((select app.gis_pode_ver()));
create policy gis_elementos_select on public.gis_elementos for select to authenticated
  using ((select app.gis_pode_ver()));
create policy gis_trechos_select on public.gis_trechos for select to authenticated
  using ((select app.gis_pode_ver()));
create policy gis_trecho_postes_select on public.gis_trecho_postes for select to authenticated
  using ((select app.gis_pode_ver()));
create policy gis_validacoes_select on public.gis_validacoes for select to authenticated
  using ((select app.gis_pode_ver()));

-- Fontes: só ADMINISTRADOR
create policy gis_fontes_insert on public.gis_fontes for insert to authenticated
  with check ((select app.tem_perfil('ADMINISTRADOR')));
create policy gis_fontes_update on public.gis_fontes for update to authenticated
  using ((select app.tem_perfil('ADMINISTRADOR'))) with check ((select app.tem_perfil('ADMINISTRADOR')));

-- Referência externa: só ADMINISTRADOR (Engenharia não "corrige" dado de terceiro —
-- divergência vira estado DIVERGENTE + levantamento próprio em gis_postes).
create policy gis_postes_referencia_insert on public.gis_postes_referencia for insert to authenticated
  with check ((select app.tem_perfil('ADMINISTRADOR')));
create policy gis_postes_referencia_update on public.gis_postes_referencia for update to authenticated
  using ((select app.tem_perfil('ADMINISTRADOR'))) with check ((select app.tem_perfil('ADMINISTRADOR')));

-- Rede própria: ENGENHARIA e ADMINISTRADOR. Sem GRANT de escrita direta (ver acima), estas
-- policies não são o caminho normal; ficam como segunda barreira caso algum GRANT venha a
-- ser concedido no futuro por engano.
create policy gis_postes_insert on public.gis_postes for insert to authenticated
  with check ((select app.gis_pode_editar()));
create policy gis_postes_update on public.gis_postes for update to authenticated
  using ((select app.gis_pode_editar())) with check ((select app.gis_pode_editar()));
create policy gis_elementos_insert on public.gis_elementos for insert to authenticated
  with check ((select app.gis_pode_editar()));
create policy gis_elementos_update on public.gis_elementos for update to authenticated
  using ((select app.gis_pode_editar())) with check ((select app.gis_pode_editar()));
create policy gis_trechos_insert on public.gis_trechos for insert to authenticated
  with check ((select app.gis_pode_editar()));
create policy gis_trechos_update on public.gis_trechos for update to authenticated
  using ((select app.gis_pode_editar())) with check ((select app.gis_pode_editar()));
create policy gis_trecho_postes_write on public.gis_trecho_postes for all to authenticated
  using ((select app.gis_pode_editar())) with check ((select app.gis_pode_editar()));
-- gis_validacoes: nenhuma policy de escrita (só o trigger security definer grava).

-- ---------------------------------------------------------------------------
-- Auditoria: trigger genérico já existente (public.fn_auditoria — INSERT/UPDATE/DELETE com
-- valor anterior/novo). Nenhuma alteração na whitelist de ações semânticas.
-- ---------------------------------------------------------------------------
create trigger trg_auditoria_gis_fontes after insert or update or delete on public.gis_fontes
  for each row execute function public.fn_auditoria();
-- gis_postes_referencia NÃO recebe o trigger linha-a-linha: uma coleta de cidade grava
-- dezenas de milhares de linhas e encheria public.auditoria (plano Free: 500 MB). A
-- rastreabilidade dessa tabela é o lote de importação (staging GIS, Fase 4 — quem, quando,
-- o quê, valor anterior por item) + data_referencia/ultima_coleta_em em cada linha.
create trigger trg_auditoria_gis_postes after insert or update or delete on public.gis_postes
  for each row execute function public.fn_auditoria();
create trigger trg_auditoria_gis_elementos after insert or update or delete on public.gis_elementos
  for each row execute function public.fn_auditoria();
create trigger trg_auditoria_gis_trechos after insert or update or delete on public.gis_trechos
  for each row execute function public.fn_auditoria();
create trigger trg_auditoria_gis_trecho_postes after insert or update or delete on public.gis_trecho_postes
  for each row execute function public.fn_auditoria();
