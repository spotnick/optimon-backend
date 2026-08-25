-- OptiMon — Fase 1.1
-- Seção 35: revisão de RLS.
--   1) Toda policy passa a declarar "to authenticated" explicitamente — na Fase 1 o
--      papel ficava implícito (equivale a PUBLIC), o que é seguro hoje só porque nunca
--      concedemos privilégios a anon/public, mas é uma dependência silenciosa demais
--      para "dados sensíveis sem justificativa explícita". Agora fica explícito.
--   2) Dados financeiros (medições, faturamento, recebimentos) deixam de ser legíveis
--      por todo mundo — só FINANCEIRO/DIRETOR/ADMINISTRADOR/AUDITOR.
--   3) RLS habilitada e com policy para todas as tabelas novas da Fase 1.1.
-- Nenhuma regra de escrita muda de significado — é a mesma matriz de perfis da Fase 1,
-- só reexpressa com o papel explícito.

-- 1) Remove todas as policies da Fase 1 para recriar com "to authenticated".
drop policy usuarios_select on public.usuarios;
drop policy usuarios_admin_all on public.usuarios;
drop policy cidades_infra_select on public.cidades_infra;
drop policy cidades_infra_write on public.cidades_infra;
drop policy cidades_infra_update on public.cidades_infra;
drop policy cidades_infra_delete on public.cidades_infra;
drop policy infra_segmentos_select on public.infra_segmentos;
drop policy infra_segmentos_write on public.infra_segmentos;
drop policy infra_cabos_select on public.infra_cabos;
drop policy infra_cabos_write on public.infra_cabos;
drop policy infra_fibras_select on public.infra_fibras;
drop policy infra_fibras_write on public.infra_fibras;
drop policy infra_postes_select on public.infra_postes;
drop policy infra_postes_write on public.infra_postes;
drop policy ativos_select on public.ativos;
drop policy ativos_write on public.ativos;
drop policy ativos_devolucao_select on public.ativos_devolucao;
drop policy ativos_devolucao_write on public.ativos_devolucao;
drop policy parceiros_select on public.parceiros;
drop policy parceiros_insert on public.parceiros;
drop policy parceiros_update on public.parceiros;
drop policy parceiros_delete on public.parceiros;
drop policy contratos_select on public.contratos;
drop policy contratos_insert on public.contratos;
drop policy contratos_update on public.contratos;
drop policy contratos_delete on public.contratos;
drop policy contrato_versions_select on public.contrato_versions;
drop policy contrato_versions_insert on public.contrato_versions;
drop policy contrato_fibras_select on public.contrato_fibras;
drop policy contrato_fibras_write on public.contrato_fibras;
drop policy contrato_ativos_select on public.contrato_ativos;
drop policy contrato_ativos_write on public.contrato_ativos;
drop policy contrato_regras_select on public.contrato_regras;
drop policy contrato_regras_write on public.contrato_regras;
drop policy contrato_regras_solicitacoes_select on public.contrato_regras_solicitacoes;
drop policy contrato_regras_solicitacoes_insert on public.contrato_regras_solicitacoes;
drop policy contrato_regras_solicitacoes_decide on public.contrato_regras_solicitacoes;
drop policy contrato_clientes_reservados_select on public.contrato_clientes_reservados;
drop policy contrato_clientes_reservados_write on public.contrato_clientes_reservados;
drop policy medicoes_mensais_select on public.medicoes_mensais;
drop policy medicoes_mensais_write on public.medicoes_mensais;
drop policy medicao_clientes_select on public.medicao_clientes;
drop policy medicao_clientes_write on public.medicao_clientes;
drop policy medicao_faturamento_select on public.medicao_faturamento;
drop policy medicao_faturamento_write on public.medicao_faturamento;
drop policy medicao_recebimentos_select on public.medicao_recebimentos;
drop policy medicao_recebimentos_write on public.medicao_recebimentos;
drop policy pricing_parametros_select on public.pricing_parametros;
drop policy pricing_parametros_write on public.pricing_parametros;
drop policy pricing_versions_select on public.pricing_versions;
drop policy pricing_versions_insert on public.pricing_versions;
drop policy simulacoes_select on public.simulacoes;
drop policy simulacoes_insert on public.simulacoes;
drop policy indices_economicos_select on public.indices_economicos;
drop policy indices_economicos_write on public.indices_economicos;
drop policy reajustes_select on public.reajustes;
drop policy reajustes_write on public.reajustes;
drop policy alertas_select on public.alertas;
drop policy alertas_write on public.alertas;
drop policy documentos_select on public.documentos;
drop policy documentos_write on public.documentos;
drop policy integracoes_admin_all on public.integracoes;
drop policy integracao_logs_select on public.integracao_logs;
drop policy auditoria_select on public.auditoria;

-- 2) Recria tudo com "to authenticated". Semântica idêntica à Fase 1, exceto onde
--    marcado "FASE 1.1" (dados financeiros restritos).

create policy usuarios_select on public.usuarios for select to authenticated using (true);
create policy usuarios_admin_all on public.usuarios for all to authenticated
  using (app.tem_perfil('ADMINISTRADOR')) with check (app.tem_perfil('ADMINISTRADOR'));

create policy cidades_infra_select on public.cidades_infra for select to authenticated using (true);
create policy cidades_infra_write on public.cidades_infra for insert to authenticated
  with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));
create policy cidades_infra_update on public.cidades_infra for update to authenticated
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR')) with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));
create policy cidades_infra_delete on public.cidades_infra for delete to authenticated
  using (app.tem_perfil('ADMINISTRADOR'));

create policy infra_segmentos_select on public.infra_segmentos for select to authenticated using (true);
create policy infra_segmentos_write on public.infra_segmentos for all to authenticated
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR')) with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

create policy infra_cabos_select on public.infra_cabos for select to authenticated using (true);
create policy infra_cabos_write on public.infra_cabos for all to authenticated
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR')) with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

create policy infra_fibras_select on public.infra_fibras for select to authenticated using (true);
create policy infra_fibras_write on public.infra_fibras for all to authenticated
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR')) with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

create policy infra_postes_select on public.infra_postes for select to authenticated using (true);
create policy infra_postes_write on public.infra_postes for all to authenticated
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR')) with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

create policy ativos_select on public.ativos for select to authenticated using (true);
create policy ativos_write on public.ativos for all to authenticated
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR')) with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

create policy ativos_devolucao_select on public.ativos_devolucao for select to authenticated using (true);
create policy ativos_devolucao_write on public.ativos_devolucao for all to authenticated
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR')) with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

create policy parceiros_select on public.parceiros for select to authenticated using (true);
create policy parceiros_insert on public.parceiros for insert to authenticated
  with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));
create policy parceiros_update on public.parceiros for update to authenticated
  using (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR')) with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));
create policy parceiros_delete on public.parceiros for delete to authenticated
  using (app.tem_perfil('ADMINISTRADOR'));

create policy contratos_select on public.contratos for select to authenticated using (true);
create policy contratos_insert on public.contratos for insert to authenticated
  with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));
create policy contratos_update on public.contratos for update to authenticated
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR') or (app.tem_perfil('COMERCIAL') and status = 'RASCUNHO'))
  with check (app.tem_perfil('DIRETOR','ADMINISTRADOR') or (app.tem_perfil('COMERCIAL') and status = 'RASCUNHO'));
create policy contratos_delete on public.contratos for delete to authenticated
  using (app.tem_perfil('ADMINISTRADOR'));

create policy contrato_versions_select on public.contrato_versions for select to authenticated using (true);
create policy contrato_versions_insert on public.contrato_versions for insert to authenticated
  with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

create policy contrato_fibras_select on public.contrato_fibras for select to authenticated using (true);
create policy contrato_fibras_write on public.contrato_fibras for all to authenticated
  using (app.tem_perfil('ENGENHARIA','DIRETOR','ADMINISTRADOR')) with check (app.tem_perfil('ENGENHARIA','DIRETOR','ADMINISTRADOR'));

create policy contrato_ativos_select on public.contrato_ativos for select to authenticated using (true);
create policy contrato_ativos_write on public.contrato_ativos for all to authenticated
  using (app.tem_perfil('ENGENHARIA','DIRETOR','ADMINISTRADOR')) with check (app.tem_perfil('ENGENHARIA','DIRETOR','ADMINISTRADOR'));

create policy contrato_regras_select on public.contrato_regras for select to authenticated using (true);
create policy contrato_regras_write on public.contrato_regras for all to authenticated
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR')) with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

create policy contrato_regras_solicitacoes_select on public.contrato_regras_solicitacoes for select to authenticated using (true);
create policy contrato_regras_solicitacoes_insert on public.contrato_regras_solicitacoes for insert to authenticated
  with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));
create policy contrato_regras_solicitacoes_decide on public.contrato_regras_solicitacoes for update to authenticated
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR')) with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

create policy contrato_clientes_reservados_select on public.contrato_clientes_reservados for select to authenticated using (true);
create policy contrato_clientes_reservados_write on public.contrato_clientes_reservados for all to authenticated
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR')) with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

-- FASE 1.1: medições e seus detalhes financeiros deixam de ser "select true" para todos —
-- só quem tem competência financeira/aprovação/auditoria.
create policy medicoes_mensais_select on public.medicoes_mensais for select to authenticated
  using (app.tem_perfil('FINANCEIRO','DIRETOR','ADMINISTRADOR','AUDITOR'));
create policy medicoes_mensais_write on public.medicoes_mensais for all to authenticated
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR')) with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

create policy medicao_clientes_select on public.medicao_clientes for select to authenticated
  using (app.tem_perfil('FINANCEIRO','DIRETOR','ADMINISTRADOR','AUDITOR'));
create policy medicao_clientes_write on public.medicao_clientes for all to authenticated
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR')) with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

create policy medicao_faturamento_select on public.medicao_faturamento for select to authenticated
  using (app.tem_perfil('FINANCEIRO','DIRETOR','ADMINISTRADOR','AUDITOR'));
create policy medicao_faturamento_write on public.medicao_faturamento for all to authenticated
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR')) with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

create policy medicao_recebimentos_select on public.medicao_recebimentos for select to authenticated
  using (app.tem_perfil('FINANCEIRO','DIRETOR','ADMINISTRADOR','AUDITOR'));
create policy medicao_recebimentos_write on public.medicao_recebimentos for all to authenticated
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR')) with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

create policy pricing_parametros_select on public.pricing_parametros for select to authenticated using (true);
create policy pricing_parametros_write on public.pricing_parametros for all to authenticated
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR')) with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

create policy pricing_versions_select on public.pricing_versions for select to authenticated using (true);
create policy pricing_versions_insert on public.pricing_versions for insert to authenticated
  with check (app.tem_perfil('DIRETOR','ADMINISTRADOR','FINANCEIRO'));

create policy simulacoes_select on public.simulacoes for select to authenticated
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR','AUDITOR') or criado_por = auth.uid());
create policy simulacoes_insert on public.simulacoes for insert to authenticated
  with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));

create policy indices_economicos_select on public.indices_economicos for select to authenticated using (true);
create policy indices_economicos_write on public.indices_economicos for all to authenticated
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR')) with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

create policy reajustes_select on public.reajustes for select to authenticated using (true);
create policy reajustes_write on public.reajustes for all to authenticated
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR')) with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

create policy alertas_select on public.alertas for select to authenticated using (true);
create policy alertas_write on public.alertas for all to authenticated
  using (app.tem_perfil('DIRETOR','FINANCEIRO','ENGENHARIA','ADMINISTRADOR')) with check (app.tem_perfil('DIRETOR','FINANCEIRO','ENGENHARIA','ADMINISTRADOR'));

create policy documentos_select on public.documentos for select to authenticated using (true);
create policy documentos_write on public.documentos for all to authenticated
  using (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR')) with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));

create policy integracoes_admin_all on public.integracoes for all to authenticated
  using (app.tem_perfil('ADMINISTRADOR')) with check (app.tem_perfil('ADMINISTRADOR'));

create policy integracao_logs_select on public.integracao_logs for select to authenticated
  using (app.tem_perfil('ADMINISTRADOR','AUDITOR','ENGENHARIA'));

create policy auditoria_select on public.auditoria for select to authenticated using (true);

-- 3) RLS para as tabelas novas da Fase 1.1.

alter table public.infra_pops enable row level security;
create policy infra_pops_select on public.infra_pops for select to authenticated using (true);
create policy infra_pops_write on public.infra_pops for all to authenticated
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR')) with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

alter table public.infra_portas_pon enable row level security;
create policy infra_portas_pon_select on public.infra_portas_pon for select to authenticated using (true);
create policy infra_portas_pon_write on public.infra_portas_pon for all to authenticated
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR')) with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

alter table public.contrato_pricing_config enable row level security;
create policy contrato_pricing_config_select on public.contrato_pricing_config for select to authenticated using (true);
create policy contrato_pricing_config_write on public.contrato_pricing_config for all to authenticated
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR')) with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

alter table public.contrato_aditivos enable row level security;
create policy contrato_aditivos_select on public.contrato_aditivos for select to authenticated using (true);
create policy contrato_aditivos_insert on public.contrato_aditivos for insert to authenticated
  with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));
create policy contrato_aditivos_update on public.contrato_aditivos for update to authenticated
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR') or (app.tem_perfil('COMERCIAL') and status = 'RASCUNHO'))
  with check (app.tem_perfil('DIRETOR','ADMINISTRADOR') or (app.tem_perfil('COMERCIAL') and status = 'RASCUNHO'));

alter table public.contrato_metas enable row level security;
create policy contrato_metas_select on public.contrato_metas for select to authenticated using (true);
create policy contrato_metas_write on public.contrato_metas for all to authenticated
  using (app.tem_perfil('DIRETOR','FINANCEIRO','ADMINISTRADOR')) with check (app.tem_perfil('DIRETOR','FINANCEIRO','ADMINISTRADOR'));

alter table public.medicao_faturamento_clientes enable row level security;
create policy medicao_faturamento_clientes_select on public.medicao_faturamento_clientes for select to authenticated
  using (app.tem_perfil('FINANCEIRO','DIRETOR','ADMINISTRADOR','AUDITOR'));
create policy medicao_faturamento_clientes_write on public.medicao_faturamento_clientes for all to authenticated
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR')) with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

-- Privilégios de objeto: em Supabase real, o papel "authenticated" já recebe estes
-- grants por padrão; declaramos explicitamente aqui para o schema funcionar igual em
-- qualquer Postgres (inclusive no ambiente de teste local desta entrega).
grant usage on schema public, app to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on all functions in schema app to authenticated;
