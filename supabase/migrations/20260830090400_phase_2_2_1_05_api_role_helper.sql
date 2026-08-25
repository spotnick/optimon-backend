-- OptiMon — Fase 2.2.1: Ajuste Final de Governança + Precificação por Porta PON
-- Migration 5/6: wrapper mínimo para a API/dashboard saberem o papel (role) do usuário
-- autenticado atual — apoia o requisito da seção 14/35 de a API devolver 403 (não 409)
-- quando COMERCIAL tenta executar uma decisão de override, sem duplicar a lógica de
-- permissão em JavaScript (a decisão de quem pode aprovar continua 100% no banco —
-- RLS + trg_override_decisao; isto só expõe o papel para a API escolher o envelope HTTP
-- certo em cima de um erro que o banco já produziu, e para o dashboard mostrar/esconder
-- a UI de aprovação de forma role-aware).
create or replace function public.pricing_current_user_role()
returns text
language sql
stable
as $function$
  select app.perfil_atual()::text;
$function$;
comment on function public.pricing_current_user_role() is 'Fase 2.2.1 (seção 14/35): papel (perfil_usuario) do usuário autenticado atual, resolvido no servidor via app.perfil_atual() (nunca informado pelo cliente). Não decide preço nem aprovação — apoia a API (status HTTP 403 vs 409) e o dashboard (UI role-aware).';
