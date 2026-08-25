-- OptiMon — Fase 1.2
-- Seções 25, 26, 27: auditoria e RLS para a tabela nova desta fase (cliente_porta_pon —
-- "reserva de porta PON / ativação / desativação" da seção 25). Todas as outras ações
-- listadas na seção 25 (criação de porta PON, contratação de fibra/porta, aditivo,
-- pricing/revenue share/mínimo, exclusividade, aprovação de compartilhamento/rede
-- própria/fibra de terceiros/cliente reservado) já são cobertas pelos triggers de
-- auditoria existentes desde a Fase 1 e Fase 1.1 (trg_aud_infra_portas_pon,
-- trg_aud_contrato_fibras, trg_aud_contrato_aditivos, trg_aud_contrato_pricing_config,
-- trg_aud_contrato_regras, trg_aud_contrato_regras_solicitacoes,
-- trg_aud_contrato_clientes_reservados) — nada precisa ser recriado.

alter table public.cliente_porta_pon enable row level security;

create policy cliente_porta_pon_select on public.cliente_porta_pon for select to authenticated using (true);
create policy cliente_porta_pon_write on public.cliente_porta_pon for insert to authenticated
  with check (app.tem_perfil('COMERCIAL', 'ENGENHARIA', 'DIRETOR', 'ADMINISTRADOR'));
create policy cliente_porta_pon_update on public.cliente_porta_pon for update to authenticated
  using (app.tem_perfil('COMERCIAL', 'ENGENHARIA', 'DIRETOR', 'ADMINISTRADOR'))
  with check (app.tem_perfil('COMERCIAL', 'ENGENHARIA', 'DIRETOR', 'ADMINISTRADOR'));
create policy cliente_porta_pon_delete on public.cliente_porta_pon for delete to authenticated
  using (app.tem_perfil('ADMINISTRADOR'));

comment on policy cliente_porta_pon_write on public.cliente_porta_pon is 'COMERCIAL/ENGENHARIA podem ativar clientes em portas já contratadas (seção 26); FINANCEIRO/AUDITOR permanecem somente leitura, como em toda a matriz de RBAC.';

create trigger trg_aud_cliente_porta_pon
  after insert or update or delete on public.cliente_porta_pon
  for each row execute function public.fn_auditoria();

-- Privilégios de objeto para a tabela nova (o GRANT ... ON ALL TABLES da Fase 1.1 só
-- cobriu as tabelas que existiam naquele momento) e reforço do GRANT em app para as
-- funções novas desta fase (get_contract_capacity, check_port_capacity,
-- check_resource_conflict, calcular_minimo_contratual, calcular_cobranca_hibrida, etc.).
grant select, insert, update, delete on public.cliente_porta_pon to authenticated;
grant execute on all functions in schema app to authenticated;

-- Seção 27: nada muda aqui — service_role nunca chega ao frontend, secrets nunca em
-- endpoints, RLS restringe por RBAC — tudo isso já valia desde a Fase 1/1.1 e continua
-- valendo (vw_integracoes_seguro, tabela integracoes ADMINISTRADOR-only). O teste
-- automatizado de GET /api/integracoes depende de backend, que ainda não existe nesta
-- fase (seção 32) — mesma limitação já documentada na Fase 1.1.

-- Seções 18/19: a policy de INSERT em contrato_regras_solicitacoes (Fase 1) permite que
-- COMERCIAL crie a solicitação, mas nunca restringia o STATUS informado nesse INSERT —
-- ou seja, nada impedia (por SQL direto) um COMERCIAL inserir a própria solicitação já
-- como 'APROVADA', contornando a regra de que só DIRETOR/ADMINISTRADOR decide (a policy
-- de UPDATE "decide" já era restrita, mas o INSERT não). Fecha essa lacuna: toda
-- solicitação nasce PENDENTE, a menos que quem a crie já seja DIRETOR/ADMINISTRADOR.
create or replace function public.fn_solicitacao_nasce_pendente()
returns trigger
language plpgsql
as $$
begin
  if new.status <> 'PENDENTE' and not app.tem_perfil('DIRETOR', 'ADMINISTRADOR') then
    raise exception 'REQUIRES_APPROVAL: solicitação de % só pode nascer PENDENTE — decisão exige DIRETOR/ADMINISTRADOR (seções 18/19).', new.tipo;
  end if;
  return new;
end;
$$;

comment on function public.fn_solicitacao_nasce_pendente() is 'Fase 1.2 (seções 18/19): fecha a lacuna em que a policy de INSERT de contrato_regras_solicitacoes (Fase 1) não restringia o status — só a policy de UPDATE "decide" era restrita a DIRETOR/ADMINISTRADOR.';

create trigger trg_solicitacao_nasce_pendente
  before insert on public.contrato_regras_solicitacoes
  for each row execute function public.fn_solicitacao_nasce_pendente();
