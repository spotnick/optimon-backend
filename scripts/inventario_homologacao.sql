-- =====================================================================
-- OPTIMON — FASE 3.11.6 — SEÇÕES 10 A 13 e 20
-- INVENTÁRIO DO BANCO (somente leitura — NÃO apaga nada)
-- =====================================================================
-- Objetivo: produzir, para cada tabela relevante, quantidade atual,
-- quantidade PROVÁVEL de homologação/teste (por heurística de nome/
-- padrão, nunca por certeza), dependências (FKs) e uma recomendação
-- inicial de "preservar / revisar manualmente / candidato a limpeza".
--
-- Este script é 100% SELECT. Não contém DELETE, UPDATE, TRUNCATE nem
-- DROP. Deve ser executado ANTES de qualquer decisão de exclusão,
-- conforme Seção 16: "apresentar os registros que serão excluídos
-- ANTES de excluí-los".
--
-- IMPORTANTE (limitação declarada — ver RELATÓRIO FINAL, seção LIMPEZA):
-- este script foi validado contra o banco local de testes (sandbox de
-- desenvolvimento), que contém apenas fixtures determinísticas geradas
-- pela suíte automatizada (tests/run_tests_fase311.sh). Ele NÃO foi
-- executado contra o banco real de homologação do OptiMon (Supabase),
-- ao qual este ambiente de execução não tem acesso de rede. Antes de
-- usar o resultado para decidir qualquer exclusão, rode este arquivo
-- diretamente no console SQL do projeto Supabase de homologação e
-- reveja a saída com atenção — os números abaixo, quando vierem do
-- sandbox local, NÃO representam o volume real de homologação.
--
-- O schema não possui nenhuma coluna do tipo is_test / environment /
-- test_run_id em nenhuma das tabelas de negócio (confirmado via
-- information_schema.columns). Por isso, conforme Seção 16, este
-- script NÃO inventa um marcador ad-hoc: ele apenas SINALIZA
-- candidatos por padrão de nome/e-mail/razão social, para revisão
-- humana. A decisão de excluir é sempre manual (ver
-- scripts/cleanup_homologacao.sql).
-- =====================================================================

\pset border 2
\pset format aligned

-- ---------------------------------------------------------------------
-- 0) Cidades de infraestrutura REAL que NUNCA devem ser auto-classificadas
--    como teste, mesmo que estejam ligadas a um parceiro/proposta de teste.
--    Fonte: Fase 3.11.6, Seção 20 ("Cianorte, Jussara, Piraí do Sul,
--    Ribeirão Claro podem conter DADOS REAIS").
-- ---------------------------------------------------------------------
-- Comparação sem dependência de extensão (unaccent pode não estar
-- instalada no projeto Supabase de homologação): compara em minúsculas
-- e aceita a grafia com e sem acento para "Piraí do Sul" e "Ribeirão Claro".
create temporary table _cidades_protegidas as
select id, nome
from cidades_infra
where lower(nome) in (
  'cianorte',
  'jussara',
  'pirai do sul', 'piraí do sul',
  'ribeirao claro', 'ribeirão claro'
);

-- ---------------------------------------------------------------------
-- 1) Padrão de heurística "provável teste" (nunca 100% certeza):
--    nome/razão social/e-mail contendo TESTE, E2E, HOMOLOG, DEMO,
--    FASE (seguido de número), ou o parceiro fixture citado no prompt
--    ("HELO CONTEUDOS DIGITAIS").
-- ---------------------------------------------------------------------
create temporary view _padrao_teste as
select unnest(array[
  '%TESTE%', '%TEST %', '%-TEST-%', '%E2E%', '%HOMOLOG%', '%DEMO%',
  '%FASE-3%', '%FASE 3%', '%HELO CONTEUDOS DIGITAIS%', '%QA-%', '%SANDBOX%'
]) as padrao;

-- =====================================================================
-- 2) USUÁRIOS
-- =====================================================================
select 'usuarios' as tabela,
  count(*) as quantidade_atual,
  count(*) filter (
    where exists (select 1 from _padrao_teste p where upper(u.nome) like p.padrao or upper(u.email) like p.padrao)
      and u.perfil <> 'ADMINISTRADOR'
  ) as quantidade_provavel_teste,
  count(*) filter (where u.perfil = 'ADMINISTRADOR') as quantidade_administradores_NUNCA_APAGAR,
  'Nunca remover perfil ADMINISTRADOR (Seção 18/REGRA FINAL). Demais perfis: revisar nome/e-mail manualmente.' as observacao
from usuarios u;

-- Lista nominal dos administradores (para conferência humana de que
-- nenhum será afetado por qualquer limpeza futura).
select id, nome, email, perfil, ativo, criado_em
from usuarios
where perfil = 'ADMINISTRADOR'
order by criado_em;

-- =====================================================================
-- 3) PARCEIROS
-- =====================================================================
select 'parceiros' as tabela,
  count(*) as quantidade_atual,
  count(*) filter (
    where exists (select 1 from _padrao_teste p
      where upper(coalesce(razao_social,'')) like p.padrao
         or upper(coalesce(nome_fantasia,'')) like p.padrao
         or upper(coalesce(email_contato,'')) like p.padrao)
  ) as quantidade_provavel_teste,
  'Dependências: propostas_comerciais.parceiro_id, contratos.parceiro_id. Revisar manualmente antes de excluir.' as observacao
from parceiros;

select id, razao_social, nome_fantasia, cnpj, email_contato, criado_em,
  (exists (select 1 from _padrao_teste p
     where upper(coalesce(razao_social,'')) like p.padrao
        or upper(coalesce(nome_fantasia,'')) like p.padrao
        or upper(coalesce(email_contato,'')) like p.padrao)) as provavel_teste
from parceiros
order by criado_em desc;

-- =====================================================================
-- 4) CIDADES_INFRA (com proteção explícita das 4 cidades reais citadas)
-- =====================================================================
select 'cidades_infra' as tabela,
  count(*) as quantidade_atual,
  count(*) filter (where exists (select 1 from _padrao_teste p where upper(nome) like p.padrao)) as quantidade_provavel_teste,
  count(*) filter (where id in (select id from _cidades_protegidas)) as quantidade_protegidas_dado_real,
  'Cianorte/Jussara/Piraí do Sul/Ribeirão Claro NUNCA classificar automaticamente como teste — revisão manual obrigatória (Seção 20).' as observacao
from cidades_infra;

select c.id, c.nome, c.uf, c.status, c.criado_em,
  (c.id in (select id from _cidades_protegidas)) as protegida_dado_real_provavel,
  (exists (select 1 from _padrao_teste p where upper(c.nome) like p.padrao)) as provavel_teste_por_nome
from cidades_infra c
order by c.criado_em desc;

-- =====================================================================
-- 5) INFRAESTRUTURA (pops, cabos, fibras, postes, portas pon)
--    — associadas a cidade; herdam a classificação da cidade-mãe.
-- =====================================================================
select 'infra_pops' as tabela, count(*) as quantidade_atual,
  count(*) filter (where cidade_id in (select id from _cidades_protegidas)) as quantidade_em_cidade_protegida,
  'Nunca excluir infraestrutura vinculada a cidade real sem revisão individual.' as observacao
from infra_pops
union all
select 'infra_cabos', count(*), count(*) filter (where pop_id in (select id from infra_pops where cidade_id in (select id from _cidades_protegidas))), 'idem'
from infra_cabos
union all
select 'infra_fibras', count(*), count(*) filter (where cabo_id in (
    select id from infra_cabos where pop_id in (select id from infra_pops where cidade_id in (select id from _cidades_protegidas))
  )), 'idem'
from infra_fibras
union all
select 'infra_postes', count(*), count(*) filter (where cidade_id in (select id from _cidades_protegidas)), 'idem'
from infra_postes
union all
select 'infra_portas_pon', count(*), count(*) filter (where pop_id in (select id from infra_pops where cidade_id in (select id from _cidades_protegidas))), 'idem'
from infra_portas_pon;

-- =====================================================================
-- 6) PROPOSTAS / ACEITE / CONTRATOS
-- =====================================================================
select 'propostas_comerciais' as tabela,
  count(*) as quantidade_atual,
  count(*) filter (where exists (select 1 from _padrao_teste p where upper(coalesce(numero,'')) like p.padrao)
    or parceiro_id in (select id from parceiros pa where exists (select 1 from _padrao_teste p
        where upper(coalesce(pa.razao_social,'')) like p.padrao or upper(coalesce(pa.nome_fantasia,'')) like p.padrao))
  ) as quantidade_provavel_teste,
  'Dependências: contratos.proposta_origem_id, propostas_aceite_tentativas, propostas_documentos_assinados, signature_envelopes.proposta_id.' as observacao
from propostas_comerciais;

select 'propostas_aceite_tentativas' as tabela, count(*) as quantidade_atual,
  count(*) filter (where proposta_id in (
    select id from propostas_comerciais pc where exists (select 1 from _padrao_teste p where upper(coalesce(pc.numero,'')) like p.padrao)
  )) as quantidade_provavel_teste,
  'Depende de propostas_comerciais. Contém tentativas de OTP — nunca contém OTP em texto puro (apenas hash).' as observacao
from propostas_aceite_tentativas;

select 'contratos' as tabela, count(*) as quantidade_atual,
  count(*) filter (where exists (select 1 from _padrao_teste p where upper(coalesce(numero,'')) like p.padrao)
    or parceiro_id in (select id from parceiros pa where exists (select 1 from _padrao_teste p
        where upper(coalesce(pa.razao_social,'')) like p.padrao or upper(coalesce(pa.nome_fantasia,'')) like p.padrao))
  ) as quantidade_provavel_teste,
  'Dependências: contrato_fibras, reajustes, signature_envelopes.contrato_id.' as observacao
from contratos;

select 'contrato_fibras' as tabela, count(*) as quantidade_atual,
  count(*) filter (where contrato_id in (
    select id from contratos c where exists (select 1 from _padrao_teste p where upper(coalesce(c.numero,'')) like p.padrao)
  )) as quantidade_provavel_teste,
  'Depende de contratos e infra_fibras/infra_portas_pon. Excluir libera fibra/porta para religação real — confirmar antes.' as observacao
from contrato_fibras;

select 'reajustes' as tabela, count(*) as quantidade_atual,
  count(*) filter (where contrato_id in (
    select id from contratos c where exists (select 1 from _padrao_teste p where upper(coalesce(c.numero,'')) like p.padrao)
  )) as quantidade_provavel_teste,
  'Depende de contratos.' as observacao
from reajustes;

-- ---------------------------------------------------------------------
-- 6b) ACHADO IMPORTANTE — propostas/contratos vinculados a uma cidade
--    protegida (Cianorte/Jussara/Piraí do Sul/Ribeirão Claro) NÃO são
--    capturados pela heurística de nome acima (o número da proposta/
--    contrato normalmente não contém "TESTE"/"E2E"). Isso é
--    proposital (nunca super-classificar como teste), mas significa
--    que a lista abaixo PRECISA ser revisada manualmente uma a uma:
--    a suíte automatizada de testes (tests/run_tests_fase311.sh)
--    seleciona a cidade chamada "Jussara" (ou, na ausência dela, a
--    primeira cidade disponível) como alvo do fluxo principal — ou
--    seja, se o banco de homologação tiver uma "Jussara" real, os
--    testes automatizados podem ter criado propostas/contratos de
--    teste vinculados a infraestrutura real dessa cidade.
-- ---------------------------------------------------------------------
select 'propostas_comerciais (cidade protegida)' as tabela, count(*) as quantidade_atual,
  'ACHADO: revisar manualmente cada uma — pode ser proposta de teste vinculada a cidade real, ou proposta real da própria cidade.' as observacao
from propostas_comerciais where cidade_id in (select id from _cidades_protegidas);

select pc.id, pc.numero, pc.status, c.nome as cidade, pc.criado_em
from propostas_comerciais pc join cidades_infra c on c.id = pc.cidade_id
where pc.cidade_id in (select id from _cidades_protegidas)
order by pc.criado_em desc;

select 'contratos (cidade protegida)' as tabela, count(*) as quantidade_atual,
  'ACHADO: mesmo alerta acima — revisar manualmente antes de qualquer exclusão.' as observacao
from contratos where cidade_id in (select id from _cidades_protegidas);

select c2.id, c2.numero, c2.status, c.nome as cidade, c2.criado_em
from contratos c2 join cidades_infra c on c.id = c2.cidade_id
where c2.cidade_id in (select id from _cidades_protegidas)
order by c2.criado_em desc;

-- =====================================================================
-- 7) ASSINATURA ELETRÔNICA (envelopes, signatários, eventos, documentos)
-- =====================================================================
select 'signature_envelopes' as tabela, count(*) as quantidade_atual,
  count(*) filter (where
    proposta_id in (select id from propostas_comerciais pc where exists (select 1 from _padrao_teste p where upper(coalesce(pc.numero,'')) like p.padrao))
    or contrato_id in (select id from contratos c where exists (select 1 from _padrao_teste p where upper(coalesce(c.numero,'')) like p.padrao))
  ) as quantidade_provavel_teste,
  'Dependências: signature_signers, signature_events, documentos_assinados (todos referenciam envelope_id).' as observacao
from signature_envelopes;

select 'signature_signers' as tabela, count(*) as quantidade_atual,
  count(*) filter (where envelope_id in (
    select id from signature_envelopes se where
      se.proposta_id in (select id from propostas_comerciais pc where exists (select 1 from _padrao_teste p where upper(coalesce(pc.numero,'')) like p.padrao))
      or se.contrato_id in (select id from contratos c where exists (select 1 from _padrao_teste p where upper(coalesce(c.numero,'')) like p.padrao))
  )) as quantidade_provavel_teste,
  'Depende de signature_envelopes. signature_events.signer_id também depende desta tabela.' as observacao
from signature_signers;

select 'signature_events' as tabela, count(*) as quantidade_atual,
  count(*) filter (where provider like 'LEGADO_FASE_2_5_TESTE:%') as quantidade_legado_fase25_sintetico,
  count(*) filter (where envelope_id in (
    select id from signature_envelopes se where
      se.proposta_id in (select id from propostas_comerciais pc where exists (select 1 from _padrao_teste p where upper(coalesce(pc.numero,'')) like p.padrao))
      or se.contrato_id in (select id from contratos c where exists (select 1 from _padrao_teste p where upper(coalesce(c.numero,'')) like p.padrao))
  )) as quantidade_provavel_teste,
  'Contém a trilha de recebimento de webhook (Fase 3.11.6). Preservar linhas ligadas a envelopes/contratos reais.' as observacao
from signature_events;

select 'documentos_assinados' as tabela, count(*) as quantidade_atual,
  'Depende de signature_envelopes.' as observacao
from documentos_assinados;

select 'propostas_documentos_assinados' as tabela, count(*) as quantidade_atual,
  'Depende de propostas_comerciais. Nunca perde storage_path_original mesmo em reprocessamento (ver TESTE-150).' as observacao
from propostas_documentos_assinados;

-- =====================================================================
-- 8) AUDITORIA — NUNCA é candidata a limpeza (é a própria trilha de
--    evidência exigida pela Seção 17). Apenas contabilizada aqui.
-- =====================================================================
select 'auditoria' as tabela, count(*) as quantidade_atual,
  min(criado_em) as evento_mais_antigo, max(criado_em) as evento_mais_recente,
  'NUNCA excluir — é a trilha de auditoria/evidência. Preservar integralmente (Seção 17).' as observacao
from auditoria;

-- =====================================================================
-- 9) RESUMO CONSOLIDADO — visão única para revisão humana
-- =====================================================================
select
  'RESUMO' as secao,
  'Este relatório é um PONTO DE PARTIDA para revisão humana, não uma decisão automática.' as linha1,
  'Nenhuma linha acima deve ser excluída sem confirmação explícita do responsável.' as linha2,
  'cidades_infra Cianorte/Jussara/Piraí do Sul/Ribeirão Claro exigem revisão manual individual, nunca exclusão em lote.' as linha3,
  'usuarios com perfil ADMINISTRADOR nunca entram em nenhuma lista de exclusão.' as linha4;
