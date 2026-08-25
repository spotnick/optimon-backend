-- OptiMon — Fase 2
-- Seções 47, 53: auditoria e RLS para todas as tabelas novas desta fase, mais o reforço
-- de RBAC pedido explicitamente na seção 53 (Comercial simula/propõe/solicita override;
-- Diretor aprova exceções; Financeiro visualiza financeiro; Engenharia visualiza custos
-- técnicos/capacidade; Auditor só leitura — em todo lugar).

-- 1) Auditoria — cobre a lista da seção 47: criação de simulação, geração de proposta,
-- override manual, alteração de pricing/margem/revenue share/mínimo (contrato_pricing_config
-- já auditado desde a Fase 1.1), aprovação (pricing_override_requests).
create trigger trg_aud_simulacoes
  after insert or update or delete on public.simulacoes
  for each row execute function public.fn_auditoria();

create trigger trg_aud_custos_infraestrutura
  after insert or update or delete on public.custos_infraestrutura
  for each row execute function public.fn_auditoria();

create trigger trg_aud_pricing_ramp_rules
  after insert or update or delete on public.pricing_ramp_rules
  for each row execute function public.fn_auditoria();

create trigger trg_aud_pricing_override_requests
  after insert or update or delete on public.pricing_override_requests
  for each row execute function public.fn_auditoria();

create trigger trg_aud_propostas_comerciais
  after insert or update or delete on public.propostas_comerciais
  for each row execute function public.fn_auditoria();

create trigger trg_aud_reajustes_fase2
  after update on public.reajustes
  for each row execute function public.fn_auditoria();
comment on trigger trg_aud_reajustes_fase2 on public.reajustes is 'reajustes já é auditado só por inserção implícita via pricing_versions/reajustes em si (Fase 1 não tinha trigger dedicado); Fase 2 fecha a lacuna para UPDATEs (correção de status/erro_detalhe).';

-- 2) RLS — tabelas novas desta fase.

alter table public.custos_infraestrutura enable row level security;
create policy custos_infraestrutura_select on public.custos_infraestrutura for select to authenticated using (true);
create policy custos_infraestrutura_write on public.custos_infraestrutura for all to authenticated
  using (app.tem_perfil('FINANCEIRO', 'ENGENHARIA', 'ADMINISTRADOR'))
  with check (app.tem_perfil('FINANCEIRO', 'ENGENHARIA', 'ADMINISTRADOR'));
comment on policy custos_infraestrutura_write on public.custos_infraestrutura is 'Classificação de custo é decisão financeira/técnica (seção 53) — Comercial nunca decide sozinho o que é custo incremental/histórico/alocado.';

alter table public.pricing_faixas_escassez enable row level security;
create policy pricing_faixas_escassez_select on public.pricing_faixas_escassez for select to authenticated using (true);
create policy pricing_faixas_escassez_write on public.pricing_faixas_escassez for all to authenticated
  using (app.tem_perfil('DIRETOR', 'ADMINISTRADOR')) with check (app.tem_perfil('DIRETOR', 'ADMINISTRADOR'));

alter table public.pricing_ramp_rules enable row level security;
create policy pricing_ramp_rules_select on public.pricing_ramp_rules for select to authenticated using (true);
create policy pricing_ramp_rules_write on public.pricing_ramp_rules for all to authenticated
  using (app.tem_perfil('DIRETOR', 'ADMINISTRADOR')) with check (app.tem_perfil('DIRETOR', 'ADMINISTRADOR'));

alter table public.pricing_override_requests enable row level security;
create policy pricing_override_requests_select on public.pricing_override_requests for select to authenticated
  using (app.tem_perfil('DIRETOR', 'ADMINISTRADOR', 'FINANCEIRO', 'AUDITOR') or solicitado_por = auth.uid());
create policy pricing_override_requests_insert on public.pricing_override_requests for insert to authenticated
  with check (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'));
create policy pricing_override_requests_update on public.pricing_override_requests for update to authenticated
  using (app.tem_perfil('DIRETOR', 'ADMINISTRADOR') or (solicitado_por = auth.uid() and status = 'PENDENTE'))
  with check (app.tem_perfil('DIRETOR', 'ADMINISTRADOR') or (solicitado_por = auth.uid() and status = 'PENDENTE'));
comment on policy pricing_override_requests_update on public.pricing_override_requests is 'RLS permite ao próprio Comercial editar a solicitação enquanto PENDENTE (ex.: refinar justificativa); a decisão em si (mudar status) é bloqueada pelo trigger fn_override_decisao para quem não é DIRETOR/ADMINISTRADOR, mesmo que a policy deixe passar a UPDATE.';

alter table public.propostas_comerciais enable row level security;
create policy propostas_comerciais_select on public.propostas_comerciais for select to authenticated using (true);
create policy propostas_comerciais_insert on public.propostas_comerciais for insert to authenticated
  with check (app.tem_perfil('COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'));
create policy propostas_comerciais_update on public.propostas_comerciais for update to authenticated
  using (app.tem_perfil('DIRETOR', 'ADMINISTRADOR') or (criado_por = auth.uid() and status = 'RASCUNHO'))
  with check (app.tem_perfil('DIRETOR', 'ADMINISTRADOR') or (criado_por = auth.uid() and status = 'RASCUNHO'));

-- 3) Reforço de grants para os objetos novos (o GRANT ... ON ALL TABLES da Fase 1.1 só
-- cobriu tabelas que existiam naquele momento — mesmo cuidado já tomado na Fase 1.2).
grant select, insert, update, delete on
  public.custos_infraestrutura,
  public.pricing_faixas_escassez,
  public.pricing_ramp_rules,
  public.pricing_override_requests,
  public.propostas_comerciais
to authenticated;
grant execute on all functions in schema app to authenticated;

-- 4) Seção 53, reforço explícito: Comercial NUNCA altera parâmetros globais de pricing.
-- pricing_parametros (seção anterior) e as tabelas globais desta fase (pricing_faixas_escassez,
-- pricing_ramp_rules sem contrato_id) já ficam fora do alcance de COMERCIAL pelas policies
-- acima (write restrito a DIRETOR/ADMINISTRADOR/FINANCEIRO/ENGENHARIA conforme o caso — nunca
-- COMERCIAL sozinho). Documentado aqui para ficar rastreável junto da RLS.
comment on table public.pricing_parametros is 'Parâmetros comerciais globais versionáveis. RLS (Fase 1.1): write só DIRETOR/ADMINISTRADOR — COMERCIAL nunca altera parâmetro global de pricing (seção 53 da Fase 2, reafirmado).';
