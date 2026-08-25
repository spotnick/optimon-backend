-- OptiMon — Fase 2.2.1 (Parte 2) — seção 34: auditoria deve registrar LOGIN.
--
-- public.auditoria já existe desde a Fase 1 (20260824091700_auditoria.sql) com
-- CHECK (acao IN ('INSERT','UPDATE','DELETE')) — pensado só para triggers de tabela.
-- Login não é uma alteração de linha, então precisa de um 4º valor permitido. Alteração
-- aditiva e mínima (DROP + ADD do mesmo CHECK com um valor a mais) — não recria a tabela,
-- não apaga dado nenhum, não afeta nenhuma linha existente (todas continuam
-- INSERT/UPDATE/DELETE).

alter table public.auditoria drop constraint auditoria_acao_check;
alter table public.auditoria add constraint auditoria_acao_check
  check (acao = any (array['INSERT'::text, 'UPDATE'::text, 'DELETE'::text, 'LOGIN'::text]));

comment on constraint auditoria_acao_check on public.auditoria is 'Seção 34 (Fase 2.2.1 Parte 2): LOGIN adicionado para public.pricing_log_login() — os 3 valores originais (INSERT/UPDATE/DELETE) continuam intactos para os triggers de tabela.';
