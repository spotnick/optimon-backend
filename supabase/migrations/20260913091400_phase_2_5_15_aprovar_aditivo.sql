-- OptiMon — Fase 2.5 (15, correção aditiva): transição RASCUNHO/EM_APROVACAO
-- → APROVADO de um aditivo (seção 39), com `aprovado_por` definido no
-- servidor (nunca aceito do frontend — regra permanente do projeto).
--
-- Faltava isso na migration 08: aquela migration só cobria a CAUDA (ASSINATURA
-- →ATIVO); a cabeça do fluxo (RASCUNHO→EM_APROVACAO→APROVADO) já existia
-- desde a Fase 1.2/2 só como tabela + RLS, sem nenhuma função dedicada — o que
-- deixaria a rota Node tendo que adivinhar/aceitar `aprovado_por` do corpo da
-- requisição para satisfazer a constraint `contrato_aditivos_check`, quebrando
-- a regra "backend sempre recalcula, nunca confia no frontend". Fechado aqui.

create or replace function app.aprovar_aditivo(p_aditivo_id uuid, p_novo_status text default 'APROVADO')
returns public.contrato_aditivos
language plpgsql
security invoker
as $$
declare
  v_aditivo public.contrato_aditivos;
begin
  if p_novo_status not in ('EM_APROVACAO', 'APROVADO', 'REJEITADO') then
    raise exception 'STATUS_INVALIDO: transição % não é permitida por esta função (use EM_APROVACAO/APROVADO/REJEITADO).', p_novo_status;
  end if;

  select * into v_aditivo from public.contrato_aditivos where id = p_aditivo_id;
  if v_aditivo.id is null then
    raise exception 'NAO_ENCONTRADO: aditivo % não encontrado.', p_aditivo_id;
  end if;

  if p_novo_status = 'APROVADO' then
    update public.contrato_aditivos
       set status = 'APROVADO', aprovado_por = auth.uid(), aprovado_em = now()
     where id = p_aditivo_id
     returning * into v_aditivo;
  else
    update public.contrato_aditivos
       set status = p_novo_status
     where id = p_aditivo_id
     returning * into v_aditivo;
  end if;

  return v_aditivo;
end;
$$;

comment on function app.aprovar_aditivo(uuid, text) is 'Fase 2.5 seção 39: SECURITY INVOKER — só escreve em contrato_aditivos, coberta pela policy contrato_aditivos_update já existente (DIRETOR/ADMINISTRADOR sempre; COMERCIAL só enquanto RASCUNHO). aprovado_por é sempre auth.uid(), nunca um valor vindo do frontend.';

drop function if exists public.pricing_addendum_change_status(uuid, text);
create or replace function public.pricing_addendum_change_status(p_aditivo_id uuid, p_novo_status text default 'APROVADO')
returns public.contrato_aditivos
language sql security invoker
as $$ select app.aprovar_aditivo(p_aditivo_id, p_novo_status); $$;

grant execute on function public.pricing_addendum_change_status(uuid, text) to authenticated;
