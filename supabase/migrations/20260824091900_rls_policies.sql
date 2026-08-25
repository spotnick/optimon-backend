-- OptiMon — Fase 1
-- RLS por perfil (RBAC — seção 4 do Prompt Mestre).
-- Padrão: leitura ampla para perfis internos (é uma ferramenta interna do ISP);
-- escrita restrita por perfil conforme a matriz de permissões descrita no Prompt Mestre.
-- AUDITOR sempre cai no "select true" e nunca ganha policy de escrita em nenhuma tabela.

alter table public.usuarios enable row level security;
alter table public.cidades_infra enable row level security;
alter table public.infra_segmentos enable row level security;
alter table public.infra_cabos enable row level security;
alter table public.infra_fibras enable row level security;
alter table public.infra_postes enable row level security;
alter table public.parceiros enable row level security;
alter table public.contratos enable row level security;
alter table public.contrato_versions enable row level security;
alter table public.ativos enable row level security;
alter table public.ativos_devolucao enable row level security;
alter table public.contrato_fibras enable row level security;
alter table public.contrato_ativos enable row level security;
alter table public.contrato_regras enable row level security;
alter table public.contrato_regras_solicitacoes enable row level security;
alter table public.contrato_clientes_reservados enable row level security;
alter table public.medicoes_mensais enable row level security;
alter table public.medicao_clientes enable row level security;
alter table public.medicao_faturamento enable row level security;
alter table public.medicao_recebimentos enable row level security;
alter table public.pricing_parametros enable row level security;
alter table public.pricing_versions enable row level security;
alter table public.simulacoes enable row level security;
alter table public.indices_economicos enable row level security;
alter table public.reajustes enable row level security;
alter table public.alertas enable row level security;
alter table public.documentos enable row level security;
alter table public.integracoes enable row level security;
alter table public.integracao_logs enable row level security;
alter table public.auditoria enable row level security;
-- force RLS mesmo para o dono da tabela nas tabelas mais sensíveis, exceto onde o
-- próprio trigger security definer precisa gravar (auditoria fica sem FORCE — ver seção 8 do ARQUITETURA.md).
alter table public.contratos force row level security;
alter table public.pricing_parametros force row level security;
alter table public.medicoes_mensais force row level security;

-- USUÁRIOS: diretório visível a todos os perfis internos; só ADMINISTRADOR gerencia.
create policy usuarios_select on public.usuarios for select using (true);
create policy usuarios_admin_all on public.usuarios for all
  using (app.tem_perfil('ADMINISTRADOR'))
  with check (app.tem_perfil('ADMINISTRADOR'));

-- INFRAESTRUTURA: ENGENHARIA cadastra/mantém; leitura geral; exclusão só ADMINISTRADOR.
create policy cidades_infra_select on public.cidades_infra for select using (true);
create policy cidades_infra_write on public.cidades_infra for insert
  with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));
create policy cidades_infra_update on public.cidades_infra for update
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'))
  with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));
create policy cidades_infra_delete on public.cidades_infra for delete
  using (app.tem_perfil('ADMINISTRADOR'));

create policy infra_segmentos_select on public.infra_segmentos for select using (true);
create policy infra_segmentos_write on public.infra_segmentos for all
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'))
  with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

create policy infra_cabos_select on public.infra_cabos for select using (true);
create policy infra_cabos_write on public.infra_cabos for all
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'))
  with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

create policy infra_fibras_select on public.infra_fibras for select using (true);
create policy infra_fibras_write on public.infra_fibras for all
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'))
  with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

create policy infra_postes_select on public.infra_postes for select using (true);
create policy infra_postes_write on public.infra_postes for all
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'))
  with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

-- ATIVOS: ENGENHARIA controla; leitura geral.
create policy ativos_select on public.ativos for select using (true);
create policy ativos_write on public.ativos for all
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'))
  with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

create policy ativos_devolucao_select on public.ativos_devolucao for select using (true);
create policy ativos_devolucao_write on public.ativos_devolucao for all
  using (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'))
  with check (app.tem_perfil('ENGENHARIA','ADMINISTRADOR'));

-- PARCEIROS: COMERCIAL cadastra; DIRETOR/ADMIN também; exclusão só ADMIN.
create policy parceiros_select on public.parceiros for select using (true);
create policy parceiros_insert on public.parceiros for insert
  with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));
create policy parceiros_update on public.parceiros for update
  using (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'))
  with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));
create policy parceiros_delete on public.parceiros for delete
  using (app.tem_perfil('ADMINISTRADOR'));

-- CONTRATOS: COMERCIAL cria e edita só enquanto RASCUNHO; aprovação/edição pós-aprovação é DIRETOR/ADMIN
-- (via nova versão em contrato_versions — a regra de "gerar versão" é aplicada no backend, Fase 2).
create policy contratos_select on public.contratos for select using (true);
create policy contratos_insert on public.contratos for insert
  with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));
create policy contratos_update on public.contratos for update
  using (
    app.tem_perfil('DIRETOR','ADMINISTRADOR')
    or (app.tem_perfil('COMERCIAL') and status = 'RASCUNHO')
  )
  with check (
    app.tem_perfil('DIRETOR','ADMINISTRADOR')
    or (app.tem_perfil('COMERCIAL') and status = 'RASCUNHO')
  );
create policy contratos_delete on public.contratos for delete
  using (app.tem_perfil('ADMINISTRADOR'));

create policy contrato_versions_select on public.contrato_versions for select using (true);
create policy contrato_versions_insert on public.contrato_versions for insert
  with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

-- VÍNCULOS FIBRA/ATIVO: ENGENHARIA executa o vínculo físico; DIRETOR/ADMIN também.
create policy contrato_fibras_select on public.contrato_fibras for select using (true);
create policy contrato_fibras_write on public.contrato_fibras for all
  using (app.tem_perfil('ENGENHARIA','DIRETOR','ADMINISTRADOR'))
  with check (app.tem_perfil('ENGENHARIA','DIRETOR','ADMINISTRADOR'));

create policy contrato_ativos_select on public.contrato_ativos for select using (true);
create policy contrato_ativos_write on public.contrato_ativos for all
  using (app.tem_perfil('ENGENHARIA','DIRETOR','ADMINISTRADOR'))
  with check (app.tem_perfil('ENGENHARIA','DIRETOR','ADMINISTRADOR'));

-- REGRAS DE EXCLUSIVIDADE / CLIENTES RESERVADOS: regra crítica — só DIRETOR/ADMIN escrevem.
create policy contrato_regras_select on public.contrato_regras for select using (true);
create policy contrato_regras_write on public.contrato_regras for all
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR'))
  with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

create policy contrato_regras_solicitacoes_select on public.contrato_regras_solicitacoes for select using (true);
create policy contrato_regras_solicitacoes_insert on public.contrato_regras_solicitacoes for insert
  with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));
create policy contrato_regras_solicitacoes_decide on public.contrato_regras_solicitacoes for update
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR'))
  with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

create policy contrato_clientes_reservados_select on public.contrato_clientes_reservados for select using (true);
create policy contrato_clientes_reservados_write on public.contrato_clientes_reservados for all
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR'))
  with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

-- MEDIÇÕES: FINANCEIRO valida/aprova faturamento e recebimentos; leitura geral.
create policy medicoes_mensais_select on public.medicoes_mensais for select using (true);
create policy medicoes_mensais_write on public.medicoes_mensais for all
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'))
  with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

create policy medicao_clientes_select on public.medicao_clientes for select using (true);
create policy medicao_clientes_write on public.medicao_clientes for all
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'))
  with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

create policy medicao_faturamento_select on public.medicao_faturamento for select using (true);
create policy medicao_faturamento_write on public.medicao_faturamento for all
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'))
  with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

create policy medicao_recebimentos_select on public.medicao_recebimentos for select using (true);
create policy medicao_recebimentos_write on public.medicao_recebimentos for all
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'))
  with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

-- PRICING: parâmetros globais só DIRETOR/ADMIN alteram (nunca hard-coded, mas também nunca livre para todo mundo).
create policy pricing_parametros_select on public.pricing_parametros for select using (true);
create policy pricing_parametros_write on public.pricing_parametros for all
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR'))
  with check (app.tem_perfil('DIRETOR','ADMINISTRADOR'));

create policy pricing_versions_select on public.pricing_versions for select using (true);
create policy pricing_versions_insert on public.pricing_versions for insert
  with check (app.tem_perfil('DIRETOR','ADMINISTRADOR','FINANCEIRO'));

-- SIMULAÇÕES: COMERCIAL simula e vê as próprias; DIRETOR/ADMIN/AUDITOR veem todas.
create policy simulacoes_select on public.simulacoes for select
  using (app.tem_perfil('DIRETOR','ADMINISTRADOR','AUDITOR') or criado_por = auth.uid());
create policy simulacoes_insert on public.simulacoes for insert
  with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));

-- ÍNDICES ECONÔMICOS / REAJUSTES: FINANCEIRO processa; leitura geral.
create policy indices_economicos_select on public.indices_economicos for select using (true);
create policy indices_economicos_write on public.indices_economicos for all
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'))
  with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

create policy reajustes_select on public.reajustes for select using (true);
create policy reajustes_write on public.reajustes for all
  using (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'))
  with check (app.tem_perfil('FINANCEIRO','ADMINISTRADOR'));

-- ALERTAS: leitura geral; resolução por quem tem competência operacional sobre o domínio.
create policy alertas_select on public.alertas for select using (true);
create policy alertas_write on public.alertas for all
  using (app.tem_perfil('DIRETOR','FINANCEIRO','ENGENHARIA','ADMINISTRADOR'))
  with check (app.tem_perfil('DIRETOR','FINANCEIRO','ENGENHARIA','ADMINISTRADOR'));

-- DOCUMENTOS: COMERCIAL gera propostas; DIRETOR/ADMIN tudo.
create policy documentos_select on public.documentos for select using (true);
create policy documentos_write on public.documentos for all
  using (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'))
  with check (app.tem_perfil('COMERCIAL','DIRETOR','ADMINISTRADOR'));

-- INTEGRAÇÕES: contém credenciais — só ADMINISTRADOR mexe; logs visíveis a quem opera/audita.
create policy integracoes_admin_all on public.integracoes for all
  using (app.tem_perfil('ADMINISTRADOR'))
  with check (app.tem_perfil('ADMINISTRADOR'));

create policy integracao_logs_select on public.integracao_logs for select
  using (app.tem_perfil('ADMINISTRADOR','AUDITOR','ENGENHARIA'));

-- AUDITORIA: leitura geral (é o direito central do AUDITOR); nenhuma policy de escrita —
-- INSERT só acontece via fn_auditoria() (security definer, dono da tabela contorna RLS);
-- UPDATE/DELETE são fisicamente bloqueados pelo trigger trg_auditoria_imutavel.
create policy auditoria_select on public.auditoria for select using (true);
