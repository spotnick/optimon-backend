-- OptiMap Fase 3 — SOMENTE AMBIENTE LOCAL DE TESTE. Nunca rodar no Supabase real.
-- Um usuário por perfil (+ um usuário autenticado sem perfil) para os testes de acesso.
insert into auth.users (id, email) values
 ('a0000000-0000-0000-0000-000000000001','adm@teste.local'),('a0000000-0000-0000-0000-000000000002','dir@teste.local'),
 ('a0000000-0000-0000-0000-000000000003','eng@teste.local'),('a0000000-0000-0000-0000-000000000004','com@teste.local'),
 ('a0000000-0000-0000-0000-000000000005','fin@teste.local'),('a0000000-0000-0000-0000-000000000006','aud@teste.local'),
 ('a0000000-0000-0000-0000-000000000007','semperfil@teste.local');
insert into public.usuarios (id, nome, email, perfil) values
 ('a0000000-0000-0000-0000-000000000001','Teste Administrador','adm@teste.local','ADMINISTRADOR'),
 ('a0000000-0000-0000-0000-000000000002','Teste Diretor','dir@teste.local','DIRETOR'),
 ('a0000000-0000-0000-0000-000000000003','Teste Engenharia','eng@teste.local','ENGENHARIA'),
 ('a0000000-0000-0000-0000-000000000004','Teste Comercial','com@teste.local','COMERCIAL'),
 ('a0000000-0000-0000-0000-000000000005','Teste Financeiro','fin@teste.local','FINANCEIRO'),
 ('a0000000-0000-0000-0000-000000000006','Teste Auditor','aud@teste.local','AUDITOR');
