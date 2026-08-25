-- OptiMon — Fase 1
-- Enums de domínio. Nunca usar strings livres para status conhecidos (Prompt Mestre, seção 44).

create type perfil_usuario as enum (
  'ADMINISTRADOR', 'DIRETOR', 'COMERCIAL', 'FINANCEIRO', 'ENGENHARIA', 'AUDITOR'
);

create type fibra_status as enum (
  'LIVRE', 'OCUPADA', 'RESERVADA', 'LOCADA', 'MANUTENCAO', 'BLOQUEADA'
);

create type contrato_status as enum (
  'RASCUNHO', 'EM_APROVACAO', 'ATIVO', 'SUSPENSO', 'ENCERRADO', 'RESCINDIDO'
);

create type contrato_modelo as enum (
  'DARK_FIBER', 'HIBRIDO_REVENUE_SHARE'
);

create type revenue_share_base as enum (
  'BASE_FATURAMENTO', 'BASE_RECEBIMENTO'
);

create type solicitacao_status as enum (
  'PENDENTE', 'APROVADA', 'REJEITADA'
);

create type ativo_status as enum (
  'ESTOQUE', 'EM_USO', 'MANUTENCAO', 'DEVOLVIDO', 'PERDIDO'
);

create type alerta_tipo as enum (
  'FIM_CARENCIA', 'ENTRADA_PRECO_CHEIO', 'REAJUSTE', 'TAKE_OR_PAY_QUEBRADO',
  'DIVERGENCIA_HUBSOFT', 'DIVERGENCIA_FATURAMENTO', 'CONTRATO_PROXIMO_VENCIMENTO',
  'ATIVO_NAO_DEVOLVIDO', 'CAPACIDADE_EXCEDIDA', 'FIBRA_EM_CONFLITO',
  'CLIENTE_RESERVADO', 'OPERACAO_NAO_AUTORIZADA'
);

create type alerta_severidade as enum ('INFO', 'ATENCAO', 'CRITICO');

create type integracao_tipo as enum ('REST_API', 'WEBHOOK', 'SFTP_CSV');

create type integracao_status as enum ('ATIVA', 'INATIVA', 'COM_ERRO');
