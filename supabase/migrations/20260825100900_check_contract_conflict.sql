-- OptiMon — Fase 1.1
-- checkContractConflict() (seção 19). Como ainda não existe backend (Fase 1.1 continua
-- sendo só banco, por instrução explícita da seção 42), a regra crítica de exclusividade
-- é garantida aqui, no banco — o backend da Fase 2 chama esta função antes de aprovar
-- qualquer nova contratação, mas mesmo um acesso direto ao banco fica coberto.
--
-- Cobre os 3 exemplos literais da seção 19 (exclusividade só no POP-01 permite POP-02;
-- exclusividade na cidade toda bloqueia; permite_outros_parceiros=true vira aprovação).
-- Fora de escopo aqui (fica para a Fase 2/backend, que tem mais contexto de negócio):
-- checagem fina de capacidade numérica remanescente e correspondência exata de serviço
-- quando múltiplos serviços coexistem — o parâmetro p_servico já é considerado quando
-- informado, mas o matching de capacidade fica para o Pricing Engine.

create or replace function app.check_contract_conflict(
  p_cidade_id uuid,
  p_parceiro_id uuid,
  p_pop_id uuid default null,
  p_servico text default null
)
returns text
language plpgsql
stable
as $$
declare
  r record;
  v_resultado text := 'ALLOW';
begin
  for r in
    select cr.*, c.parceiro_id, c.numero as contrato_numero
    from public.contrato_regras cr
    join public.contratos c on c.id = cr.contrato_id
    where cr.exclusividade_comercial = true
      and c.status = 'ATIVO'
      and c.parceiro_id <> p_parceiro_id
      and (
        cr.exclusividade_cidade_id = p_cidade_id
        or c.cidade_id = p_cidade_id
      )
  loop
    -- Escopo por serviço: se a regra define serviço e o pedido também, e são diferentes,
    -- essa regra não conflita com o pedido.
    if r.exclusividade_servico is not null and p_servico is not null and r.exclusividade_servico <> p_servico then
      continue;
    end if;

    -- Escopo por POP: se a regra é restrita a um POP específico, só conflita se o pedido
    -- for para o mesmo POP. Se a regra não tem POP definido, ela vale para a cidade toda.
    if r.exclusividade_pop_id is not null and (p_pop_id is null or r.exclusividade_pop_id <> p_pop_id) then
      continue;
    end if;

    -- Chegou aqui: há exclusividade ativa de outro parceiro cobrindo o escopo pedido.
    if r.permite_outros_parceiros then
      v_resultado := 'REQUIRES_APPROVAL';
      -- não retorna ainda: uma outra regra mais restritiva (permite_outros_parceiros=false)
      -- pode existir e deve prevalecer (BLOCK é mais forte que REQUIRES_APPROVAL).
    else
      return 'BLOCK';
    end if;
  end loop;

  return v_resultado;
end;
$$;

comment on function app.check_contract_conflict(uuid, uuid, uuid, text) is 'ALLOW / BLOCK / REQUIRES_APPROVAL — checa exclusividade escopada de outros parceiros ativos antes de aprovar uma nova contratação (seção 19). BLOCK sempre prevalece sobre REQUIRES_APPROVAL quando há mais de uma regra concorrente.';
