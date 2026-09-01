-- =====================================================================
-- OPTIMON — FASE 3.11.6 — SEÇÕES 14 A 19
-- LIMPEZA CONTROLADA DO BANCO DE HOMOLOGAÇÃO
-- =====================================================================
-- COMO USAR (leia antes de rodar):
--
-- 1. Rode primeiro scripts/inventario_homologacao.sql no banco de
--    homologação e revise a saída com um responsável humano.
-- 2. A partir dessa revisão, preencha a tabela temporária
--    "_cleanup_homologacao_aprovados" (passo 1 abaixo) com os PARES
--    (tabela, id) explicitamente aprovados para exclusão — um id por
--    linha. Este script NUNCA decide sozinho o que é teste: ele só
--    apaga o que foi listado explicitamente. Isso é proposital —
--    o schema atual não tem nenhuma coluna is_test/environment/
--    test_run_id (confirmado por consulta ao information_schema), e a
--    Seção 16 do prompt proíbe inventar um marcador ad-hoc frágil.
--    A lista de IDs aprovados FAZ o papel desse marcador, mas de forma
--    auditável e sempre humana.
-- 3. Rode o script inteiro dentro de UMA transação (BEGIN já está no
--    arquivo). Ao final, ele mostra um resumo de quantas linhas seriam
--    afetadas em cada tabela.
-- 4. Por padrão o script termina com ROLLBACK, não com COMMIT — ou
--    seja, por padrão NADA é apagado de verdade, mesmo rodando o
--    arquivo inteiro. Revise o resumo impresso. Só depois de conferir
--    que os números batem com o que foi aprovado, troque manualmente
--    a última linha de ROLLBACK para COMMIT e rode de novo (ou rode
--    interativamente e digite COMMIT você mesmo).
-- 5. O script registra um evento CLEANUP_HOMOLOGACAO em auditoria ANTES
--    de qualquer exclusão (Seção 17) — mesmo que a transação seja
--    revertida (ROLLBACK), o que é esperado no modo de simulação.
--
-- GARANTIAS DESTE SCRIPT:
--   - Nunca contém DROP DATABASE, DROP SCHEMA, TRUNCATE ... CASCADE
--     nem DELETE sem WHERE.
--   - Nunca apaga de "auditoria" (a própria trilha de evidência).
--   - Nunca apaga usuarios com perfil = 'ADMINISTRADOR' — há uma
--     verificação (RAISE EXCEPTION) que aborta a transação inteira se
--     algum id de administrador acabar entrando na lista aprovada por
--     engano.
--   - Respeita a ordem de dependência de chaves estrangeiras (filhos
--     antes dos pais).
--   - Termina em ROLLBACK por padrão (ver passo 4 acima).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- PASSO 1 — lista de IDs explicitamente aprovados para exclusão.
-- Preencha aqui, após revisar scripts/inventario_homologacao.sql com
-- um responsável humano. Exemplo (comentado):
--
--   insert into _cleanup_homologacao_aprovados (tabela, id) values
--     ('propostas_comerciais', '11111111-1111-1111-1111-111111111111'),
--     ('contratos',            '22222222-2222-2222-2222-222222222222');
--
-- Deixe vazio (como está abaixo) para rodar o script em modo "somente
-- validação" — ele vai rodar sem apagar nada, só para conferir que a
-- lógica de dependências e a rotina de auditoria funcionam.
-- ---------------------------------------------------------------------
create temporary table _cleanup_homologacao_aprovados (
  tabela text not null,
  id uuid not null,
  primary key (tabela, id)
) on commit drop;

-- >>> INSERTS APROVADOS MANUALMENTE VÃO AQUI <<<
-- insert into _cleanup_homologacao_aprovados (tabela, id) values (...);

-- ---------------------------------------------------------------------
-- PASSO 2 — trava de segurança: aborta a transação inteira se qualquer
-- id aprovado corresponder a um usuário ADMINISTRADOR, ou a qualquer
-- linha de "auditoria" (nenhuma das duas tabelas deveria nunca
-- aparecer em _cleanup_homologacao_aprovados, mas a verificação é
-- redundante de propósito).
-- ---------------------------------------------------------------------
do $$
declare
  v_qtd_admin_bloqueado int;
  v_qtd_auditoria_bloqueada int;
begin
  select count(*) into v_qtd_admin_bloqueado
  from _cleanup_homologacao_aprovados a
  join usuarios u on u.id = a.id and a.tabela = 'usuarios'
  where u.perfil = 'ADMINISTRADOR';

  if v_qtd_admin_bloqueado > 0 then
    raise exception 'BLOQUEADO: % usuário(s) ADMINISTRADOR encontrados na lista de exclusão aprovada. Abortando (Seção 18/REGRA FINAL).', v_qtd_admin_bloqueado;
  end if;

  select count(*) into v_qtd_auditoria_bloqueada
  from _cleanup_homologacao_aprovados
  where tabela = 'auditoria';

  if v_qtd_auditoria_bloqueada > 0 then
    raise exception 'BLOQUEADO: a tabela auditoria nunca deve constar na lista de exclusão (Seção 17). Abortando.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- PASSO 3 — registra o evento de auditoria ANTES de excluir qualquer
-- coisa (Seção 17: "mesmo em homologação"; se o próprio rastro de
-- auditoria fosse apagado, o relatório precisa existir antes da
-- limpeza — por isso o registro acontece aqui, no início da transação).
-- Usa a função já existente app.registrar_auditoria_semantica
-- (mesmo padrão usado em todo o restante do sistema — nunca uma
-- gravação direta e paralela em auditoria).
-- ---------------------------------------------------------------------
do $$
declare
  v_resumo jsonb;
begin
  select jsonb_build_object(
    'tabelas_afetadas', (select jsonb_agg(distinct tabela) from _cleanup_homologacao_aprovados),
    'total_ids_aprovados', (select count(*) from _cleanup_homologacao_aprovados),
    'executado_em', now()
  ) into v_resumo;

  -- Assinatura real: registrar_auditoria_semantica(p_entidade, p_entidade_id,
  -- p_acao, p_motivo, p_valor_anterior, p_valor_novo, p_origem, p_ip).
  -- usuario_id é preenchido pela própria função via auth.uid() (sessão do
  -- responsável que estiver executando este script no console do projeto).
  perform app.registrar_auditoria_semantica(
    'sistema',
    null,
    'CLEANUP_HOMOLOGACAO',
    'Limpeza controlada de dados de homologação — Fase 3.11.6',
    null,
    v_resumo,
    'scripts/cleanup_homologacao.sql',
    null
  );
end $$;

-- ---------------------------------------------------------------------
-- PASSO 4 — exclusão em ordem de dependência (filhos antes dos pais).
-- Cada DELETE só afeta linhas cujo id está na lista aprovada — nunca
-- um DELETE por padrão de nome, nunca um DELETE sem WHERE.
-- ---------------------------------------------------------------------

-- 4.1 Assinatura eletrônica (mais dependente primeiro)
delete from signature_events se
using _cleanup_homologacao_aprovados a
where a.tabela = 'signature_envelopes' and se.envelope_id = a.id;

delete from documentos_assinados da
using _cleanup_homologacao_aprovados a
where a.tabela = 'signature_envelopes' and da.envelope_id = a.id;

delete from signature_signers ss
using _cleanup_homologacao_aprovados a
where a.tabela = 'signature_envelopes' and ss.envelope_id = a.id;

delete from signature_envelopes se
using _cleanup_homologacao_aprovados a
where a.tabela = 'signature_envelopes' and se.id = a.id;

-- também remove eventos/signatários/envelopes referenciados diretamente
delete from signature_events se
using _cleanup_homologacao_aprovados a
where a.tabela = 'signature_events' and se.id = a.id;

delete from signature_signers ss
using _cleanup_homologacao_aprovados a
where a.tabela = 'signature_signers' and ss.id = a.id;

-- 4.2 Documentos e tentativas de aceite de proposta
delete from propostas_documentos_assinados pda
using _cleanup_homologacao_aprovados a
where a.tabela = 'propostas_comerciais' and pda.proposta_id = a.id;

delete from propostas_aceite_tentativas pat
using _cleanup_homologacao_aprovados a
where a.tabela = 'propostas_comerciais' and pat.proposta_id = a.id;

-- 4.3 Reajustes e vínculos de fibra do contrato
delete from reajustes r
using _cleanup_homologacao_aprovados a
where a.tabela = 'contratos' and r.contrato_id = a.id;

delete from contrato_fibras cf
using _cleanup_homologacao_aprovados a
where a.tabela = 'contratos' and cf.contrato_id = a.id;

-- 4.4 Contratos (após remover o que depende deles)
delete from contratos c
using _cleanup_homologacao_aprovados a
where a.tabela = 'contratos' and c.id = a.id;

-- 4.5 Propostas comerciais (após remover o que depende delas, inclusive
-- envelopes que ainda apontem para propostas ainda não cobertas acima)
delete from signature_envelopes se
using _cleanup_homologacao_aprovados a
where a.tabela = 'propostas_comerciais' and se.proposta_id = a.id;

delete from propostas_comerciais pc
using _cleanup_homologacao_aprovados a
where a.tabela = 'propostas_comerciais' and pc.id = a.id;

-- 4.6 Parceiros (só depois de remover propostas/contratos que os referenciam)
delete from parceiros p
using _cleanup_homologacao_aprovados a
where a.tabela = 'parceiros' and p.id = a.id;

-- 4.7 Infraestrutura — só se explicitamente aprovada linha a linha
-- (nunca em lote; ver Seção 20 sobre Cianorte/Jussara/Piraí do
-- Sul/Ribeirão Claro). Ordem: portas_pon/fibras -> cabos/postes -> pops -> cidade.
delete from infra_portas_pon ip
using _cleanup_homologacao_aprovados a
where a.tabela = 'infra_portas_pon' and ip.id = a.id;

delete from infra_fibras inf
using _cleanup_homologacao_aprovados a
where a.tabela = 'infra_fibras' and inf.id = a.id;

delete from infra_cabos ic
using _cleanup_homologacao_aprovados a
where a.tabela = 'infra_cabos' and ic.id = a.id;

delete from infra_postes ipo
using _cleanup_homologacao_aprovados a
where a.tabela = 'infra_postes' and ipo.id = a.id;

delete from infra_pops ipp
using _cleanup_homologacao_aprovados a
where a.tabela = 'infra_pops' and ipp.id = a.id;

delete from cidades_infra ci
using _cleanup_homologacao_aprovados a
where a.tabela = 'cidades_infra' and ci.id = a.id;

-- 4.8 Usuários de teste (nunca ADMINISTRADOR — já bloqueado no Passo 2)
delete from usuarios u
using _cleanup_homologacao_aprovados a
where a.tabela = 'usuarios' and u.id = a.id;

-- ---------------------------------------------------------------------
-- PASSO 5 — resumo do que foi (ou seria) afetado, para conferência
-- antes de decidir entre COMMIT e ROLLBACK.
-- ---------------------------------------------------------------------
select
  (select count(*) from _cleanup_homologacao_aprovados) as total_ids_na_lista_aprovada,
  (select count(distinct tabela) from _cleanup_homologacao_aprovados) as total_tabelas_afetadas,
  now() as executado_em;

select tabela, count(*) as ids_aprovados
from _cleanup_homologacao_aprovados
group by tabela
order by tabela;

-- ---------------------------------------------------------------------
-- PASSO 6 — decisão final.
-- Por padrão este arquivo termina em ROLLBACK (nada é apagado de
-- verdade). Depois de revisar o resumo do Passo 5 e confirmar que
-- corresponde exatamente ao aprovado na revisão humana do inventário,
-- troque a linha abaixo para COMMIT; e rode de novo.
-- ---------------------------------------------------------------------
rollback;
-- commit;
