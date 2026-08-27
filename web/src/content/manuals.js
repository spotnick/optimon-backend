// OptiMon — conteúdo dos manuais operacionais por perfil, consumidos pela Central de
// Ajuda (/ajuda, Help.jsx) e pelo menu "Ajuda & Manuais". Cada manual é uma lista de
// seções {titulo, corpo} — corpo é texto simples (parágrafos separados por linha em
// branco), renderizado sem precisar de um parser de markdown.
//
// Criado na Fase 2.4 com 4 manuais (Engenharia/Comercial/Financeiro/Diretoria).
// Atualizado integralmente na Fase 2.5.1 (seções 22-29 do prompt): acrescenta o Manual
// do Administrador (não existia — Fase 2.5 introduziu Usuários/Proponentes/Assinatura/
// Contrato sem nenhum manual dedicado a quem administra o sistema), o guia "Como
// funciona a assinatura eletrônica" (cross-perfil), e estende os 4 manuais existentes
// com os fluxos de proponente, aprovação interna, assinatura e contrato que a Fase 2.5
// introduziu e que ainda não estavam documentados em nenhum manual.

export const MANUALS = [
  {
    slug: 'administrador',
    titulo: 'Manual do Administrador',
    publico: 'ADMINISTRADOR',
    resumo: 'Login, gestão de usuários e perfis, proponentes, aprovações, assinaturas, contratos, configuração e auditoria — a visão de quem opera o OptiMon como produto.',
    secoes: [
      {
        titulo: 'Login e perfis de acesso',
        corpo: `O OptiMon usa o Supabase Auth para autenticação — e-mail e senha, sem nenhuma senha armazenada nas tabelas do OptiMon. Cada usuário tem um perfil único que define o que ele pode ver e fazer: ADMINISTRADOR (acesso total, incluindo gestão de usuários e configuração de assinatura), DIRETOR (aprovação de propostas/contratos, exceções de preço, restauração de infraestrutura), COMERCIAL (proponentes, simulações, propostas), ENGENHARIA (infraestrutura de rede), FINANCEIRO (leitura de composição de preço, auditoria e relatórios) e AUDITOR (leitura em todo o sistema, sem poder editar nada).

Essa restrição nunca é só de interface: cada perfil é reforçado por Row-Level Security (RLS) direto no banco de dados — mesmo alguém tentando chamar a API diretamente, sem passar pela tela, é bloqueado pelas mesmas regras.`,
      },
      {
        titulo: 'Criando um usuário — nunca com UUID manual',
        corpo: `Em "Usuários" → "Criar Usuário", informe Nome, E-mail, Telefone, CPF, Cargo, Departamento, Perfil e Observações. O administrador nunca precisa conhecer, copiar ou digitar nenhum identificador técnico (UUID) do Supabase — o ID da identidade é sempre gerado automaticamente pelo Supabase Auth no momento da criação, como parte do próprio fluxo de "Criar Usuário".

Ao confirmar, o OptiMon cria a identidade de autenticação e envia um convite por e-mail; a tela mostra "Convite enviado para <e-mail>." A pessoa convidada define sua própria senha ao clicar no link do e-mail — o OptiMon nunca vê, armazena nem tem acesso a essa senha.`,
      },
      {
        titulo: 'Editando, desativando e reativando usuários',
        corpo: `Na lista de usuários, cada linha tem as ações "Editar" (nome, telefone, CPF, cargo, departamento, perfil e observações — o e-mail e o identificador de autenticação nunca são editáveis por aqui), "Desativar"/"Reativar" (nunca existe exclusão física de usuário — desativar é sempre uma ação lógica, com motivo obrigatório e confirmação explícita), "Reenviar convite" (para quem ainda não definiu senha) e "Redefinir acesso" (dispara um e-mail de redefinição de senha para quem já tem conta).

Um usuário desativado é bloqueado de executar qualquer ação que exija perfil (as regras de RLS do banco só reconhecem usuário com "ativo=true") — o efeito é imediato, sem precisar de nenhum passo extra.`,
      },
      {
        titulo: 'Status de autenticação',
        corpo: `A coluna de status mostra, quando disponível: ATIVO (login liberado e cadastro ativo), CONVITE PENDENTE (identidade criada, e-mail enviado, mas a pessoa ainda não definiu senha), INATIVO (cadastro desativado no OptiMon) e ACESSO BLOQUEADO (bloqueado diretamente na camada de autenticação). Esse detalhamento depende da integração com a Auth Admin API do Supabase estar configurada no ambiente — quando não está, o sistema nunca inventa um status: mostra só ATIVO/INATIVO com base no cadastro, honestamente.`,
      },
      {
        titulo: 'Proponentes: cadastro, responsáveis e desativação',
        corpo: `Em "Proponentes", "+ Novo Proponente" cadastra a empresa (razão social, nome fantasia, CNPJ, endereço, dados de contato). Cada proponente tem uma tela de detalhe com abas para Dados Cadastrais (editáveis a qualquer momento via "Editar cadastro"), Responsáveis, Documentos, Propostas, Contratos e Histórico & Auditoria.

Um proponente nunca é excluído fisicamente — "Desativar" é sempre uma exclusão lógica, com motivo e confirmação; o proponente desativado some da listagem padrão (filtro "Ativos") mas continua acessível pelo filtro "Todos" ou "Inativos", e pode ser reativado a qualquer momento por quem tem permissão (COMERCIAL, DIRETOR ou ADMINISTRADOR).`,
      },
      {
        titulo: 'Responsáveis do proponente',
        corpo: `Dentro do proponente, "+ Adicionar responsável" cadastra a pessoa de contato: Nome, CPF, Cargo, Departamento, E-mail, Telefone, WhatsApp, Tipo e se é Representante Legal, além de um documento comprobatório opcional. Responsáveis também nunca são excluídos fisicamente — são arquivados, preservando o histórico de quem já representou o proponente em algum momento.`,
      },
      {
        titulo: 'Documentos — sempre por link temporário',
        corpo: `O upload de documento de proponente vai para um Storage privado — nunca um link público permanente. Todo download usa uma URL assinada com expiração curta (minutos), gerada só no momento em que alguém autorizado clica em "Baixar". Substituir um documento preserva o histórico da versão anterior.`,
      },
      {
        titulo: 'Aprovação interna de propostas e contratos',
        corpo: `Uma proposta com preço abaixo do valor recomendado nasce automaticamente com status "Em Aprovação" e só avança depois que um DIRETOR ou ADMINISTRADOR clica em "Aprovar" (ou "Rejeitar", com motivo). O mesmo princípio de governança se aplica a aditivos contratuais: um aditivo passa por RASCUNHO → EM_APROVACAO → APROVADO antes de poder receber um envelope de assinatura.`,
      },
      {
        titulo: 'Assinatura eletrônica',
        corpo: `Toda proposta e todo contrato (e aditivo) que precisam de assinatura passam por um envelope de assinatura eletrônica ICP-Brasil, criado em "Assinaturas". Veja o guia dedicado "Como funciona a assinatura eletrônica" para o passo a passo completo — este manual cobre só a parte de configuração do provedor, abaixo.`,
      },
      {
        titulo: 'Configuração de Assinatura',
        corpo: `Em "Configurações → Assinatura" (só ADMINISTRADOR/DIRETOR podem editar), cada provedor mostra: Nome, Ambiente (Homologação/Produção), Status (ativo/inativo), URL de Webhook, Política de assinatura padrão, e o resultado do último teste de conexão (data e OK/Falha) e do último evento recebido. O botão "Testar Conexão" faz uma checagem real de conectividade com o provedor configurado e mostra o diagnóstico na tela — nunca expõe a chave de API nem o segredo do webhook, só o nome da variável de ambiente onde cada um está guardado.

Para o Contrato de Cessão de Uso, a política padrão é sempre Assinatura Qualificada ICP-Brasil — essa regra é fixa e não pode ser alterada por COMERCIAL nem por nenhum outro perfil comercial.`,
      },
      {
        titulo: 'Contratos: geração, ativação e aditivos',
        corpo: `Um contrato nunca é digitado do zero — ele é gerado automaticamente a partir de uma proposta aprovada, preenchendo sozinho Cedente, Cessionário, CNPJ, Representante, Cidade, POP, Fibra/PON, Valor, Mínimo, Revenue Share, Rampa, Prazo, Reajuste, Data de início e Data de término, com base nos dados já validados na proposta e na cidade. Depois de assinado e validado, o botão "Ativar contrato" fica disponível; uma vez ativo, o contrato é bloqueado para edição direta — qualquer mudança de infraestrutura, prazo ou condição comercial passa a exigir um aditivo (que tem seu próprio ciclo de aprovação e assinatura) ou um evento de reajuste (que nunca reescreve o valor histórico, sempre cria um novo registro preservando o anterior).`,
      },
      {
        titulo: 'Auditoria',
        corpo: `A tela "Auditoria" (/auditoria) registra todo evento relevante do sistema — criação, edição, desativação, reativação, aprovação, reprovação, assinatura, validação, geração, exportação e cancelamento — sempre com quem fez, quando, e o motivo quando aplicável. Cada proponente também tem sua própria aba "Histórico & Auditoria" filtrada só para os eventos daquele registro; eventos de responsáveis, propostas ou contratos vinculados a ele continuam aparecendo na tela geral de Auditoria.`,
      },
      {
        titulo: 'Exceções e segurança',
        corpo: `AUDITOR tem acesso de leitura a tudo, mas nunca pode editar nada — nem proponente, nem usuário, nem infraestrutura. ENGENHARIA nunca aprova preço nem proposta. COMERCIAL e FINANCEIRO nunca alteram infraestrutura de rede. Só ADMINISTRADOR e DIRETOR executam ações de governança (aprovação de exceção de preço, restauração de infraestrutura arquivada, configuração do provedor de assinatura). Tentar contornar essas regras trocando o ID na URL ou chamando a API diretamente não funciona — a mesma restrição está implementada como Row-Level Security no banco, não só como um botão escondido na tela.`,
      },
      {
        titulo: 'O que o administrador nunca precisa fazer no Supabase',
        corpo: `Toda operação do dia a dia — criar usuário, cadastrar proponente, aprovar proposta, configurar o provedor de assinatura, consultar auditoria — é feita inteiramente dentro do OptiMon. O painel do Supabase, o SQL Editor, o Railway e o GitHub são ferramentas de configuração técnica e de deploy, não de operação: um administrador que só usa o sistema no dia a dia nunca precisa abri-los.`,
      },
    ],
  },
  {
    slug: 'engenharia',
    titulo: 'Manual de Engenharia',
    publico: 'ENGENHARIA',
    resumo: 'Cadastro e ciclo de vida da infraestrutura de rede: cidades, POPs, segmentos, cabos, fibras, postes e portas PON — e como essa infraestrutura fica comprometida por um contrato.',
    secoes: [
      {
        titulo: 'Visão geral da infraestrutura',
        corpo: `O OptiMon organiza a rede em uma hierarquia: Cidade → POP → Segmento → Cabo → Fibra, com Postes e Portas PON associados à cidade e ao POP. Toda edição de infraestrutura fica em "Cidades & Infraestrutura", na tela de detalhe de cada cidade.

Cada entidade tem um ciclo de vida próprio: Ativa (em uso) ou Arquivada (fora de uso, mas nunca apagada). O OptiMon nunca exclui fisicamente um registro de infraestrutura — arquivar é sempre uma exclusão lógica (a linha continua existindo no banco, marcada como removida), o que preserva o histórico completo para auditoria e para consultas futuras.`,
      },
      {
        titulo: 'Cadastrando uma cidade',
        corpo: `Em "Cidades & Infraestrutura" → "Nova Cidade", informe nome, UF, código IBGE (opcional) e km de rede. Depois de criada, a cidade aparece na lista com status ATIVA e pode receber POPs, segmentos, cabos, postes e portas PON.

O código IBGE, quando informado, precisa ser único — o sistema bloqueia duplicidade.`,
      },
      {
        titulo: 'POPs, segmentos e cabos — passo a passo',
        corpo: `1) Um POP (Ponto de Presença) é criado dentro de uma cidade, com código, nome, tipo e endereço. 2) Um segmento de rede também pertence a uma cidade e conecta origem/destino. 3) Um cabo é criado dentro de um segmento e, ao ser cadastrado, já cria automaticamente as fibras que o compõem (uma linha por fibra, todas nascendo com status LIVRE).

Editar qualquer um desses itens é feito na tela "Editar Infraestrutura" da cidade — os campos são atualizados diretamente, sem afetar o histórico de auditoria (toda alteração fica registrada).`,
      },
      {
        titulo: 'Fibras e seus status',
        corpo: `Cada fibra tem um status operacional: LIVRE, OCUPADA, RESERVADA, LOCADA, MANUTENÇÃO ou BLOQUEADA. O status é alterado diretamente na tela de detalhe do cabo. Uma fibra OCUPADA, RESERVADA ou LOCADA impede o arquivamento do cabo que a contém — é preciso liberar (voltar para LIVRE) ou arquivar a fibra antes.`,
      },
      {
        titulo: 'Postes',
        corpo: `Postes são cadastrados em lote (informando quantidade, cidade e custo unitário) e podem ser editados individualmente depois (custo, status, observações). Diferente das demais entidades, arquivar um poste nunca é bloqueado por dependência — um poste não tem "filhos" na hierarquia de rede.`,
      },
      {
        titulo: 'Portas PON',
        corpo: `Uma Porta PON representa a capacidade de atendimento de clientes finais em um POP. Cada porta tem status ATIVA ou INATIVA — mas esse status nunca é alterado diretamente por PATCH: ele muda automaticamente ao arquivar (vira INATIVA) ou restaurar (volta a ATIVA) a porta pelos botões dedicados. Uma porta com clientes ativos vinculados não pode ser arquivada até que os clientes sejam desvinculados ou encerrados.`,
      },
      {
        titulo: 'Arquivar e restaurar — regras de dependência',
        corpo: `Antes de arquivar qualquer item, o sistema verifica se ele tem dependências ativas (por exemplo: um segmento com cabos ativos, ou um POP com segmentos ativos). Se houver, o arquivamento é bloqueado com uma mensagem explicando exatamente qual dependência precisa ser resolvida primeiro — e essa tentativa bloqueada também fica registrada na auditoria.

Ao arquivar, o sistema sempre pede um motivo (lista fechada de opções) e permite uma observação livre opcional. Restaurar um item arquivado é uma ação restrita — só ADMINISTRADOR ou DIRETOR podem restaurar, mesmo que ENGENHARIA tenha permissão para arquivar. Só ENGENHARIA e ADMINISTRADOR podem criar ou editar infraestrutura — COMERCIAL e FINANCEIRO nunca têm essa permissão, mesmo tentando pela API diretamente.`,
      },
      {
        titulo: 'Infraestrutura comprometida por um contrato',
        corpo: `Quando um contrato é gerado a partir de uma proposta aprovada, ele reserva (compromete) fibra e, quando aplicável, porta PON específicas — essa alocação aparece na tela de detalhe do contrato, em "Infraestrutura alocada (comprometida)", e nunca acontece automaticamente: vincular fibra/porta a um contrato é sempre um passo manual de Engenharia. Enquanto uma fibra ou porta está comprometida com um contrato ativo, ela não pode ser arquivada nem realocada para outro contrato — a mesma regra de dependência que já protege cabos e segmentos também vale aqui.`,
      },
      {
        titulo: 'Itens arquivados e o Pricing Engine',
        corpo: `Infraestrutura arquivada nunca entra nos cálculos do Pricing Engine nem nos números do Dashboard — capacidade, fibras livres e portas disponíveis sempre refletem só o que está ativo. Para ver o que foi arquivado, use o filtro "Arquivados" ou "Todos" na tela de infraestrutura da cidade.`,
      },
    ],
  },
  {
    slug: 'comercial',
    titulo: 'Manual Comercial',
    publico: 'COMERCIAL',
    resumo: 'Proponente, responsável, simulação, régua de preço, proposta, aprovação, assinatura e contrato — o ciclo comercial completo, do primeiro contato ao contrato ativo.',
    secoes: [
      {
        titulo: 'O fluxo comercial completo',
        corpo: `1) Cadastre o Proponente (a empresa) e pelo menos um Responsável (a pessoa de contato) em "Proponentes". 2) Simule o preço em "Nova Simulação" escolhendo cidade, volume de clientes e ARPU. 3) Ajuste o preço proposto (o sistema sugere o valor recomendado). 4) Vincule o proponente e o responsável e clique em "Gerar Proposta". 5) Acompanhe a proposta até ser aprovada (se necessário) e assinada. 6) Depois de assinado e validado, o contrato é gerado automaticamente a partir da proposta.`,
      },
      {
        titulo: 'Cadastrando um proponente e seu responsável',
        corpo: `Em "Proponentes" → "+ Novo Proponente", informe razão social, nome fantasia, CNPJ e dados de contato. Depois de criado, abra o proponente e use "+ Adicionar responsável" para cadastrar quem vai assinar em nome da empresa: nome, CPF, cargo, e-mail, telefone/WhatsApp e se é representante legal — esse é o signatário que entrará no envelope de assinatura do contrato.

Um proponente nunca é excluído — "Desativar" (com motivo) é a forma correta de tirá-lo de uso; ele pode ser reativado depois, se necessário.`,
      },
      {
        titulo: 'A régua de preço',
        corpo: `Toda simulação mostra três referências: o Piso (o valor mínimo absoluto que a OptiMon aceita — nunca deve ser oferecido a um parceiro sem autorização formal), o Recomendado (o preço sugerido pelo Pricing Engine, que já considera a economia com o piso de infraestrutura da cidade) e a Abertura (um preço de partida mais alto, útil como referência de negociação).

O preço proposto pode ser digitado livremente, mas o sistema sempre recalcula floor/recomendado/abertura no servidor — o comercial nunca define esses três valores manualmente.`,
      },
      {
        titulo: 'Gerando uma proposta',
        corpo: `Depois de simular, o botão "Gerar Proposta" salva a simulação e cria a proposta com um número único (padrão PROP-AAAAMMDD-xxxxxxxx), vinculada ao proponente e ao responsável escolhidos. Se o preço proposto estiver abaixo do preço recomendado, a proposta já nasce com status "Em Aprovação" — ela precisa ser aprovada por um DIRETOR ou ADMINISTRADOR antes de avançar no funil.`,
      },
      {
        titulo: 'Ciclo de vida da proposta',
        corpo: `Rascunho → Em Aprovação (se necessário) → Aprovada → Enviada → Em Negociação → Aceita (fechamento) ou Recusada/Expirada/Cancelada. Cada transição fica registrada na auditoria com quem fez, quando e por quê.

Uma proposta nunca é sobrescrita: se você precisa mudar valores depois de já ter sido enviada, use "Nova Versão" — o sistema cria V2, V3 etc., preservando o histórico completo de cada versão anterior.`,
      },
      {
        titulo: 'Assinatura da proposta e geração do contrato',
        corpo: `Depois de aprovada, a proposta segue para assinatura eletrônica (veja o guia "Como funciona a assinatura eletrônica") — o responsável cadastrado no proponente é quem assina. Depois que a assinatura é validada, o contrato é gerado automaticamente, preenchendo sozinho todos os dados já validados na proposta (cedente, cessionário, valor, prazo, cidade, infraestrutura). Depois de gerado e assinado, o contrato é bloqueado para edição direta — qualquer alteração de condição comercial passa a exigir um aditivo.`,
      },
      {
        titulo: 'Duplicar Proposta',
        corpo: `"Duplicar Proposta" cria uma proposta totalmente nova e independente (com seu próprio número, sua própria linha do tempo de versões), reaproveitando os mesmos dados de partida. Use quando quiser adaptar uma proposta existente para um parceiro ou cidade diferente, sem misturar o histórico com o da proposta original.`,
      },
      {
        titulo: 'Documento Interno x Externo',
        corpo: `Toda proposta pode ser visualizada e exportada em dois modos: Interna (mostra piso, preço recomendado, desconto aplicado e status de governança — uso exclusivo da equipe OptiMon) e Externa (mostra só o que o parceiro precisa ver: preço proposto, condições comerciais, prazo e validade — nunca piso, desconto ou dados de autorização). Sempre confira que está no modo certo antes de exportar e enviar ao parceiro.`,
      },
      {
        titulo: 'Exportando PDF e DOCX',
        corpo: `Os botões "Exportar PDF" e "Exportar DOCX" geram o documento completo (capa, sumário, 28 seções, tabelas e gráficos) no formato escolhido, respeitando o modo Interno/Externo selecionado na tela. O nome do arquivo segue sempre o padrão OPTIMON_Proposta_[Cidade]_[Parceiro]_[AAAAMMDD]. Toda exportação fica registrada na auditoria.`,
      },
    ],
  },
  {
    slug: 'financeiro',
    titulo: 'Manual Financeiro',
    publico: 'FINANCEIRO',
    resumo: 'Composição do preço, revenue share, reajuste e rampa contratual, régua de governança e relatórios de auditoria financeira.',
    secoes: [
      {
        titulo: 'A composição do preço final',
        corpo: `O total mensal pago à OptiMon (total_payable) é composto a partir do modo de composição escolhido na simulação: MAX (o maior entre o piso/mínimo e o revenue share calculado), SUM (piso mais revenue share), FLOOR_ONLY (só o piso) ou MINIMUM_ONLY (só o mínimo contratual). A receita do parceiro é sempre o faturamento total menos esse valor. Esses mesmos campos — Valor, Mínimo e Revenue Share — são os que aparecem preenchidos automaticamente no contrato gerado a partir da proposta aprovada.`,
      },
      {
        titulo: 'Rampa de clientes',
        corpo: `Contratos com crescimento gradual de clientes usam uma regra de rampa: em vez de assumir o volume final de clientes desde o mês 1, a rampa projeta a evolução mês a mês até atingir o volume contratado. A rampa é sempre calculada no servidor a partir dos parâmetros da proposta — nunca digitada manualmente mês a mês.`,
      },
      {
        titulo: 'Reajuste contratual',
        corpo: `Um reajuste é aplicado na tela de detalhe do contrato ("Aplicar reajuste"), informando o percentual. Cada reajuste gera um novo evento registrado na tabela de reajustes do contrato (competência, percentual aplicado, status) — o valor histórico anterior nunca é sobrescrito, sempre preservado para consulta e auditoria.`,
      },
      {
        titulo: 'Governança de desconto',
        corpo: `Cada simulação recebe uma avaliação automática de governança (ALLOW, REVIEW ou BLOCK) comparando o preço proposto ao piso e ao desconto máximo permitido para o perfil de quem está propondo. Propostas abaixo do piso exigem autorização formal — nunca são aprovadas automaticamente, mesmo por um DIRETOR.`,
      },
      {
        titulo: 'Autorização de propostas abaixo do piso',
        corpo: `Quando uma proposta é aprovada com preço abaixo do piso, o sistema exige uma justificativa obrigatória e registra permanentemente quem autorizou, quando e qual foi o preço efetivamente autorizado — essa informação aparece na seção "Governança e Autorização" do documento interno e nunca no documento externo.`,
      },
      {
        titulo: 'Auditoria e rastreabilidade',
        corpo: `A tela "Auditoria" lista todo evento relevante do sistema: criação, edição, arquivamento, restauração, tentativas bloqueadas, aprovações, rejeições, assinaturas, validações, geração de contrato e exportações de proposta. Cada linha mostra quem fez, quando, o que mudou (valor anterior e novo) e o motivo informado, quando aplicável. Use os filtros por entidade e ação para investigar um caso específico — inclusive eventos ligados a um proponente específico, disponíveis também na aba "Histórico & Auditoria" da tela daquele proponente.`,
      },
      {
        titulo: 'Projeções de horizonte',
        corpo: `A tabela de horizonte (12/36/48/60 meses) mostra a receita acumulada da OptiMon e do parceiro em cada prazo, junto com ROI e payback quando um investimento (CAPEX) é informado. O prazo de 48 meses é o mínimo contratual padrão; 60 meses é sempre uma projeção ilustrativa além do contrato, nunca um compromisso.`,
      },
    ],
  },
  {
    slug: 'diretoria',
    titulo: 'Manual da Diretoria',
    publico: 'DIRETOR',
    resumo: 'Aprovação de propostas e contratos, exceções de preço, assinaturas, aditivos, indicadores e governança sobre toda decisão comercial.',
    secoes: [
      {
        titulo: 'O papel do DIRETOR/ADMINISTRADOR no fluxo',
        corpo: `Somente DIRETOR e ADMINISTRADOR podem: aprovar propostas que saíram do rascunho, autorizar preços abaixo do piso, aprovar aditivos contratuais, restaurar qualquer item de infraestrutura arquivado, editar a configuração do provedor de assinatura, e mover uma proposta por qualquer transição de status além do rascunho. Essa restrição é aplicada tanto na interface quanto diretamente no banco de dados (Row-Level Security) — não é possível contornar via API.`,
      },
      {
        titulo: 'Aprovando uma proposta',
        corpo: `Na tela de detalhe da proposta, o botão "Aprovar" fica disponível para propostas em Rascunho ou Em Aprovação; "Rejeitar" está sempre disponível junto, com motivo. Se o preço proposto estiver abaixo do piso, o campo de motivo é obrigatório — o sistema recusa a aprovação sem uma justificativa. Uma vez aprovada, ficam registrados permanentemente: quem aprovou, quando, o preço autorizado e o motivo.`,
      },
      {
        titulo: 'Aprovando um aditivo contratual',
        corpo: `Um aditivo (inclusão/exclusão de fibra ou porta, alteração de prazo, condição comercial, capacidade, exclusividade ou regra de cobrança) percorre RASCUNHO → EM_APROVACAO → APROVADO antes de poder receber um envelope de assinatura, e só depois de assinado e validado pode ser ativado. A aprovação (ou rejeição) do aditivo, na tela do contrato, é restrita a DIRETOR/ADMINISTRADOR, na mesma lógica de governança das propostas.`,
      },
      {
        titulo: 'Assinaturas e contratos ativos',
        corpo: `Um contrato só pode ser ativado depois que a assinatura eletrônica correspondente está VALIDADA — o botão "Ativar contrato" fica indisponível até lá. Uma vez ativo, o contrato é bloqueado contra edição direta: qualquer mudança de condição passa a exigir um aditivo formal, com seu próprio ciclo de aprovação e assinatura, nunca uma edição silenciosa.`,
      },
      {
        titulo: 'Visão consolidada',
        corpo: `O Dashboard mostra os principais indicadores agregados — cidades ativas, capacidade de rede, contratos ativos, propostas pendentes, assinaturas pendentes, contratos pendentes de assinatura, reajustes próximos, proponentes ativos, usuários ativos e com convite pendente, e alertas não resolvidos — sempre excluindo infraestrutura arquivada dos números de capacidade. A lista de Propostas e a de Contratos podem ser filtradas por status para acompanhar o funil completo, da simulação até o contrato ativo.`,
      },
      {
        titulo: 'Documento para apresentação externa',
        corpo: `Ao compartilhar uma proposta com um parceiro, sempre use o modo "Externa" (na tela de detalhe da proposta) antes de exportar — ele remove automaticamente piso, desconto aplicado e qualquer dado de governança interna, deixando só as condições comerciais que o parceiro precisa avaliar.`,
      },
      {
        titulo: 'Trilha de auditoria como ferramenta de governança',
        corpo: `Toda decisão de exceção (autorização abaixo do piso, aprovação de aditivo, restauração de infraestrutura arquivada, rejeição de proposta, desativação de usuário ou proponente) fica permanentemente registrada com autor, data/hora e motivo — a tela de Auditoria é a fonte de verdade para qualquer revisão de compliance ou disputa comercial futura.`,
      },
    ],
  },
  {
    slug: 'assinatura-eletronica',
    titulo: 'Como funciona a assinatura eletrônica',
    publico: null,
    resumo: 'O caminho completo de uma proposta ou contrato até virar um documento assinado e validado com certificação ICP-Brasil — para qualquer perfil que precise entender o processo.',
    secoes: [
      {
        titulo: 'Visão geral: da proposta ao contrato ativo',
        corpo: `1) Proposta aprovada. 2) Documento gerado a partir da proposta (ou do contrato/aditivo, conforme o caso). 3) Signatários definidos — sempre o responsável cadastrado no proponente, do lado do parceiro, e o representante da OptiMon do outro. 4) Envelope enviado para assinatura via o provedor de assinatura configurado. 5) Cada signatário assina digitalmente com certificação ICP-Brasil. 6) O OptiMon recebe a confirmação (webhook) do provedor e atualiza o status do envelope. 7) A assinatura é validada — o sistema confirma a integridade e a autenticidade do documento assinado junto ao provedor, nunca só assume que "existe uma rota" para isso. 8) Com a assinatura validada, o contrato pode ser ativado.`,
      },
      {
        titulo: 'Arquitetura: nunca acoplado a um fornecedor específico',
        corpo: `O motor de assinatura do OptiMon é desenhado em camadas: o sistema fala sempre com uma interface interna e genérica de assinatura eletrônica, que por sua vez fala com o provedor de assinatura real configurado (o parceiro ICP-Brasil escolhido). Isso significa que trocar de fornecedor de assinatura no futuro não exige reescrever contrato, proposta, banco de dados, fluxo de aprovação, frontend nem auditoria — só a peça que conversa com o fornecedor muda. O OptiMon nunca implementa sua própria criptografia de assinatura nem guarda a chave privada de ninguém — isso é sempre responsabilidade do provedor certificado.`,
      },
      {
        titulo: 'Criando e enviando um envelope',
        corpo: `Em "Assinaturas" → "Criar envelope", vinculado a uma proposta ou contrato, o sistema monta o documento a ser assinado. Depois, em "+ Signatário", cada pessoa que precisa assinar é adicionada com nome, e-mail e ordem de assinatura. Só depois de todos os signatários necessários estarem cadastrados o botão "Enviar para assinatura" fica disponível — ele dispara o envelope para o provedor real.`,
      },
      {
        titulo: 'Recebendo e processando o evento do provedor (webhook)',
        corpo: `Quando alguém assina (ou quando o envelope muda de status no provedor), o provedor notifica o OptiMon por webhook. Esse evento é autenticado por HMAC antes de qualquer gravação — o OptiMon nunca confia cegamente no conteúdo de uma notificação externa. Se o mesmo evento chegar duplicado (reenvio do provedor, por exemplo), o OptiMon reconhece que já processou aquele evento e não duplica o registro nem o efeito colateral — o status do envelope só avança uma vez por evento real.`,
      },
      {
        titulo: 'Validando a assinatura',
        corpo: `O botão "Validar assinatura" não é decorativo: ele consulta o provedor para confirmar que o documento assinado é íntegro e que a assinatura de cada signatário é autêntica, e só então marca o envelope como VALIDADO. Um envelope apenas "assinado" (ainda não validado) não libera a ativação do contrato — só um envelope validado libera.`,
      },
      {
        titulo: 'Baixando o documento assinado e a trilha de auditoria',
        corpo: `"Baixar documento assinado" entrega o PDF final com as assinaturas. A seção "Trilha de auditoria (eventos + evidências do provedor)", na tela do envelope, mostra toda a linha do tempo — criação, envio, cada evento recebido do provedor, assinatura de cada signatário e validação — com data/hora de cada passo, a mesma fonte usada para comprovar o processo em uma eventual disputa.`,
      },
      {
        titulo: 'Política padrão para Contrato de Cessão de Uso',
        corpo: `Para o Contrato de Cessão de Uso, a política de assinatura padrão é sempre Assinatura Qualificada ICP-Brasil — o nível mais alto de certificação, equivalente a uma assinatura de próprio punho reconhecida em cartório. Essa regra é fixa no sistema e não pode ser alterada por COMERCIAL nem por nenhum outro perfil comercial; só ADMINISTRADOR/DIRETOR configuram o provedor, e mesmo assim a política mínima para esse tipo de documento não muda.`,
      },
    ],
  },
];

export function findManualBySlug(slug) {
  return MANUALS.find((m) => m.slug === slug);
}
