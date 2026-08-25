-- OptiMon — Fase 2.2.1 (Parte 2) — correção encontrada durante validação E2E real via
-- PostgREST local (seção 39: "não parar no código", validar o ambiente publicado de
-- verdade, não só npm run build).
--
-- Achado: rodando public.pricing_cities_list() sob o papel `authenticated` de verdade
-- (via PostgREST + JWT, não como superuser em psql — nenhum teste anterior tinha
-- exercitado isso) o Postgres devolveu "permission denied for view vw_capacidade_cidade"
-- (42501). Investigando, 6 das 8 views do schema public nunca receberam
-- GRANT SELECT ... TO authenticated desde que foram criadas (Fase 1/2) — um gap
-- pré-existente que só não tinha sido percebido porque toda validação até aqui rodava
-- como o dono das tabelas (optimon_admin) ou testava RLS só em tabelas base, nunca nestas
-- views agregadas. Nunca escondido — documentado aqui e no relatório final (seção 45).
--
-- Correção mínima e aditiva: GRANT SELECT nas 6 views que faltavam. RLS das tabelas de
-- origem continua valendo (view roda com o papel de quem consulta — nenhuma dessas views
-- é SECURITY DEFINER), então isso não abre nenhum dado que RLS já não permitiria ver via
-- as tabelas base diretamente.

grant select on
  public.vw_capacidade_cidade,
  public.vw_capacidade_contrato,
  public.vw_capacidade_parceiro,
  public.vw_capacidade_pop,
  public.vw_contrato_capacidade,
  public.vw_porta_pon_detalhe
to authenticated;
