-- OptiMon — Fase 1.1
-- Seção 34: credenciais nunca podem ser expostas, nem por engano num endpoint de leitura
-- genérico. A tabela integracoes continua ADMINISTRADOR-only via RLS (Fase 1). Esta view
-- expõe tudo MENOS a coluna de credenciais, para uso operacional por outros perfis
-- (ex.: ENGENHARIA conferir status de uma integração sem nunca ter acesso ao segredo).
--
-- Views não têm RLS própria — o filtro de perfil é embutido diretamente na consulta
-- (equivalente a uma policy, só que expresso na view). A tabela base não precisa de
-- FORCE ROW LEVEL SECURITY para isto funcionar; o filtro abaixo já garante o RBAC
-- independentemente de como a permissão de leitura da tabela subjacente é resolvida.
--
-- A camada IntegrationCredentialService citada na seção 34, e o teste automatizado de
-- que GET /api/integracoes não retorna secrets, são trabalho de backend (Fase 2+) —
-- não existem ainda porque não existe backend nesta entrega (seção 42). Esta view é a
-- garantia possível no nível de banco, hoje.

create or replace view public.vw_integracoes_seguro as
select
  id,
  parceiro_id,
  nome,
  tipo,
  endpoint,
  frequencia,
  campos_mapeados,
  status,
  criado_em,
  atualizado_em
from public.integracoes
where app.tem_perfil('ADMINISTRADOR', 'ENGENHARIA', 'DIRETOR', 'AUDITOR');

comment on view public.vw_integracoes_seguro is 'Mesma informação de integracoes, sem a coluna credenciais_criptografadas, e restrita a ADMINISTRADOR/ENGENHARIA/DIRETOR/AUDITOR (filtro embutido na view, já que view não tem RLS própria).';
