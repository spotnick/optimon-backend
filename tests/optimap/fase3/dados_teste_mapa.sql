-- OptiMap Fase 3 — DADOS DE TESTE, SOMENTE AMBIENTE LOCAL. Nunca rodar no Supabase real.
-- Tudo aqui é identificado como teste ("TESTE-E2E", fonte TESTE_LOCAL_REFERENCIA) e existe
-- só para exercitar a interface nos testes automatizados. Não representa a rede real.
-- Escrita da rede própria feita pelas funções oficiais (como ENGENHARIA), nunca por INSERT
-- direto — o mesmo caminho que a interface usará.
\set ON_ERROR_STOP 1

-- POP de teste com coordenada (o POP-01 real do seed de produção NÃO tem coordenada).
insert into public.infra_pops (cidade_id, codigo, nome, tipo, latitude, longitude, observacoes)
select id, 'TESTE-E2E-POP', 'POP de teste (E2E)', 'ACESSO', -23.621800, -52.469400, 'DADO DE TESTE LOCAL — não é infraestrutura real.'
from public.cidades_infra where nome = 'Jussara';

-- Fonte externa de TESTE (não é a Copel; nenhum dado da Copel é usado nos testes).
insert into public.gis_fontes (codigo, nome, tipo, descricao, termos_uso, atribuicao)
values ('TESTE_LOCAL_REFERENCIA', 'TESTE — referência fictícia para testes automatizados', 'EXTERNA',
        'Somente ambiente local de teste.', 'Dados fictícios de teste.', 'Fonte: teste local');

-- 25 postes de referência de teste, em grade, a leste do POP de teste.
insert into public.gis_postes_referencia (fonte_id, id_externo, geom, cidade_id, situacao_fonte, data_referencia)
select f.id, 'TESTE-' || (900000 + g), ST_SetSRID(ST_MakePoint(-52.4690 + (g % 5) * 0.0004, -23.6214 - (g / 5) * 0.0004), 4326),
       c.id, case when g % 3 = 0 then 'OCUPADO' else 'DISPONIVEL' end, now() - interval '2 days'
from generate_series(0, 24) g
cross join public.gis_fontes f cross join public.cidades_infra c
where f.codigo = 'TESTE_LOCAL_REFERENCIA' and c.nome = 'Jussara';

set role authenticated;
set app.current_user_id = 'a0000000-0000-0000-0000-000000000003';
select set_config('optimap_teste.cid', (select id::text from public.cidades_infra where nome='Jussara'), false);
select set_config('optimap_teste.lote', (select id::text from public.infra_postes limit 1), false);
select set_config('optimap_teste.r0', (select id::text from public.gis_postes_referencia where id_externo='TESTE-900000'), false);
select set_config('optimap_teste.r1', (select id::text from public.gis_postes_referencia where id_externo='TESTE-900001'), false);
select set_config('optimap_teste.p1', public.optimap_promover_poste_referencia(current_setting('optimap_teste.r0')::uuid, 'DOCUMENTADO', null, current_setting('optimap_teste.lote')::uuid, 'TESTE-E2E')::text, false);
select set_config('optimap_teste.p2', public.optimap_promover_poste_referencia(current_setting('optimap_teste.r1')::uuid, 'DOCUMENTADO', null, current_setting('optimap_teste.lote')::uuid, 'TESTE-E2E')::text, false);
select set_config('optimap_teste.p3', public.optimap_criar_poste(current_setting('optimap_teste.cid')::uuid, -52.4698, -23.6218, 'TESTE-E2E-P3', 'NICK_LEVANTAMENTO_CAMPO', 'PLANEJADO', null, null, 'DADO DE TESTE LOCAL')::text, false);
select public.optimap_alterar_estado('gis_postes', current_setting('optimap_teste.p1')::uuid, 'VALIDADO', 'Teste E2E: validação');
select set_config('optimap_teste.e1', public.optimap_criar_elemento('CEO', current_setting('optimap_teste.cid')::uuid, null, null, 'TESTE-E2E-CEO-01', 'Caixa de emenda de teste', current_setting('optimap_teste.p1')::uuid, null, 'NICK_LEVANTAMENTO_CAMPO', 'DOCUMENTADO', '{"bandejas": 2}', 'DADO DE TESTE LOCAL')::text, false);
select public.optimap_criar_elemento('CTO', current_setting('optimap_teste.cid')::uuid, -52.4686, -23.6222, 'TESTE-E2E-CTO-01', null, null, null, 'NICK_PROJETO', 'PLANEJADO', '{"portas": 16}', 'DADO DE TESTE LOCAL');
select public.optimap_criar_trecho(current_setting('optimap_teste.cid')::uuid,
  '{"type":"LineString","coordinates":[[-52.4694,-23.6218],[-52.4690,-23.6214],[-52.4686,-23.6214]]}',
  null, (select id from public.infra_cabos limit 1), null,
  (select id from public.infra_pops where codigo='TESTE-E2E-POP'), current_setting('optimap_teste.e1')::uuid, null,
  array[current_setting('optimap_teste.p1')::uuid, current_setting('optimap_teste.p2')::uuid],
  'AEREO', 'NICK_LEVANTAMENTO_CAMPO', 'DOCUMENTADO', 'TESTE-E2E-TRECHO-01', 'DADO DE TESTE LOCAL');
reset role;
