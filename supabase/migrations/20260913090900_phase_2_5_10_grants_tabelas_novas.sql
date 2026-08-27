-- OptiMon — Fase 2.5 (10/9, correção): GRANT de tabela para `authenticated`
-- nas tabelas novas desta fase.
--
-- BUG REAL encontrado durante a própria validação (smoke test manual via
-- psql com `SET ROLE authenticated`, antes de escrever a API): RLS por si só
-- NUNCA concede privilégio — só restringe linhas de um privilégio que já
-- existe. Cada fase anterior que criou tabela nova precisou do próprio
-- `GRANT ... TO authenticated` (confirmado em `20260826100600` e
-- `20260827100800`) — perdido aqui nas migrations 02/04/05 desta fase. Sem
-- isso, toda escrita em parceiros_responsaveis/signature_*/modelos_contrato
-- falhava com "permission denied for table", mesmo com a policy de RLS
-- correta. Corrigido antes de qualquer API ser escrita em cima disso.

grant select, insert, update, delete on public.parceiros_responsaveis to authenticated;
grant select, insert, update, delete on public.modelos_contrato to authenticated;
grant select, insert, update, delete on public.signature_providers to authenticated;
grant select, insert, update, delete on public.signature_envelopes to authenticated;
grant select, insert, update, delete on public.signature_signers to authenticated;
grant select on public.signature_events to authenticated;
grant select, insert, update, delete on public.documentos_assinados to authenticated;
grant select, insert, update, delete on public.documentos_evidencias to authenticated;
