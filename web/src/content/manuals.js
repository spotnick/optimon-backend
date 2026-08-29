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
//
// Fase 3 (item 3.10): corrige textos que descreviam a validação ICP-Brasil como real
// quando só o provedor mock de homologação existe.
//
// Fase 3 (item 3.14) — "Manuais por perfil: reescrever conteúdo completo": acrescenta o
// Manual do Auditor (o perfil AUDITOR nunca tinha um manual dedicado — via a Central de
// Ajuda sem nenhum manual marcado como "seu perfil"); corrige a seção de exclusão de
// usuário no Manual do Administrador, que ainda afirmava "nunca existe exclusão física"
// depois que o item 3.8 introduziu justamente essa função; e estende os 5 manuais
// existentes com os recursos da Fase 3 ainda não documentados em nenhum manual: minuta
// de contrato, guardrails contratuais, clientes reservados, restauração de responsável
// removido, tela de Alertas (item 3.11) e tela de Relatórios (item 3.6) — incluindo,
// sempre que relevante, a limitação honesta de que Faturamento Real/Take-or-Pay/
// Revenue Share real dependem de dados que o sistema ainda não recebe (ligados à
// integração HubSoft, explicitamente fora de escopo nesta fase).
//
// Fase 3.8 (item 3.8-16): estende os manuais com os recursos introduzidos pela Fase
// 3.8: regra de cobrança sempre SOMA (remoção do modo MAX), reserva formal de tipo
// Prefeitura/órgão público, workflow de exceção de fibra de terceiros/rede própria
// (Engenharia → Comercial → Diretoria), registro formal de ativos cedidos e sua
// devolução, consolidação Multi-POP com receita mensal rateada por POP, a minuta de
// 44 seções, os novos tipos de evento de auditoria, e a funcionalidade — antes
// inexistente — de encerrar/rescindir um contrato.

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

Ao confirmar, o OptiMon cria a identidade de autenticação e envia um convite por e-mail; a tela mostra "Convite enviado para <e-mail>." A pessoa convidada clica no link do e-mail e cai direto na tela "Definir senha" do próprio OptiMon, onde escolhe sua senha e já entra no sistema em seguida — o OptiMon nunca vê, armazena nem tem acesso a essa senha. Esse link é sempre construído a partir da URL pública real do OptiMon publicado (variável PUBLIC_APP_URL no backend) — nunca de um endereço de desenvolvimento.`,
      },
      {
        titulo: 'Editando, desativando e reativando usuários',
        corpo: `Na lista de usuários, cada linha tem as ações "Editar" (nome, telefone, CPF, cargo, departamento, perfil e observações — o e-mail e o identificador de autenticação nunca são editáveis por aqui), "Desativar"/"Reativar" (a ação do dia a dia para tirar alguém de uso — sempre lógica, com motivo obrigatório e confirmação explícita, e reversível a qualquer momento), "Reenviar convite" (para quem ainda não definiu senha) e "Redefinir acesso" (dispara um e-mail de redefinição de senha para quem já tem conta).

Um usuário desativado é bloqueado de executar qualquer ação que exija perfil (as regras de RLS do banco só reconhecem usuário com "ativo=true") — o efeito é imediato, sem precisar de nenhum passo extra.`,
      },
      {
        titulo: 'Excluir Fisicamente — irreversível, e por isso deliberadamente difícil',
        corpo: `Diferente de "Desativar" (lógico e reversível), o botão "Excluir Fisicamente" (visível só para usuários ativos) remove a linha do cadastro de verdade — não é mais possível reverter pelo sistema depois disso. Por isso o fluxo tem barreiras propositais: é preciso digitar o e-mail exato da pessoa para confirmar (nunca basta clicar em um botão de confirmação genérico) e informar um motivo obrigatório.

O sistema recusa a exclusão física — sem exceção, mesmo para ADMINISTRADOR — em três situações: tentar excluir a si mesmo, excluir o último ADMINISTRADOR ativo do sistema, ou excluir alguém que tenha qualquer vínculo de histórico (autoria de auditoria, aprovação de proposta, aprovação de aditivo, registro de reajuste, entre ~19 tabelas verificadas) — nesse último caso a mensagem de erro explica exatamente qual vínculo está bloqueando, e a alternativa correta continua sendo "Desativar". Antes de apagar a linha, o sistema grava um evento de auditoria da própria exclusão (sem o CPF, por privacidade) — então mesmo depois de excluído fisicamente, o fato de que aquele usuário existiu e foi removido, por quem e por quê, permanece na trilha de auditoria (que é sempre imutável, nunca apagada junto).`,
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
        corpo: `Dentro do proponente, "+ Adicionar responsável" cadastra a pessoa de contato: Nome, CPF, Cargo, Departamento, E-mail, Telefone, WhatsApp, Tipo e se é Representante Legal, além de um documento comprobatório opcional. Responsáveis também nunca são excluídos fisicamente — "Remover" é sempre uma remoção lógica.

Um responsável removido não fica perdido: marque "Mostrar removidos" na tela do proponente para vê-lo na lista (identificado como inativo) e usar o botão "Restaurar" a qualquer momento — o mesmo padrão usado para cidades, POPs e segmentos de infraestrutura.`,
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
        corpo: `Toda proposta e todo contrato (e aditivo) que precisam de assinatura passam por um envelope de assinatura eletrônica, criado em "Assinaturas", com política configurada para ICP-Brasil. IMPORTANTE: até hoje só existe um provedor de homologação (mock) implementado — nenhum provedor ICP-Brasil real foi integrado ou testado (ver o guia dedicado "Como funciona a assinatura eletrônica", seção "Status atual", para o detalhe completo antes de assumir validade jurídica real de qualquer assinatura feita no sistema hoje). Este manual cobre só a parte de configuração do provedor, abaixo.`,
      },
      {
        titulo: 'Configuração de Assinatura',
        corpo: `Em "Configurações → Assinatura" (só ADMINISTRADOR/DIRETOR podem editar), cada provedor mostra: Nome, Ambiente (Homologação/Produção), Status (ativo/inativo), URL de Webhook, Política de assinatura padrão, e o resultado do último teste de conexão (data e OK/Falha) e do último evento recebido. O botão "Testar Conexão" valida a configuração do provedor selecionado e mostra o diagnóstico na tela — para o provedor mock de homologação (o único implementado hoje), essa checagem NÃO faz nenhuma chamada de rede real, só confirma que a combinação tipo/ambiente é válida; nunca expõe a chave de API nem o segredo do webhook, só o nome da variável de ambiente onde cada um está guardado.

Para o Contrato de Cessão de Uso, a política configurada é sempre Assinatura Qualificada ICP-Brasil — essa regra é fixa e não pode ser alterada por COMERCIAL nem por nenhum outro perfil comercial, mas enquanto só o provedor mock estiver disponível, essa política ainda não corresponde a uma assinatura ICP-Brasil real (ver "Status atual" no guia dedicado de assinatura eletrônica).`,
      },
      {
        titulo: 'Contratos: geração, ativação, aditivos e encerramento',
        corpo: `Um contrato nunca é digitado do zero — ele é gerado automaticamente a partir de uma proposta aprovada, preenchendo sozinho Cedente, Cessionário, CNPJ, Representante, Cidade, POP, Fibra/PON, Valor, Mínimo, Revenue Share, Rampa, Prazo, Reajuste, Data de início e Data de término, com base nos dados já validados na proposta e na cidade. Depois de assinado e validado, o botão "Ativar contrato" fica disponível; uma vez ativo, o contrato é bloqueado para edição direta — qualquer mudança de infraestrutura, prazo ou condição comercial passa a exigir um aditivo (que tem seu próprio ciclo de aprovação e assinatura) ou um evento de reajuste (que nunca reescreve o valor histórico, sempre cria um novo registro preservando o anterior).

Desde a Fase 3.8, um contrato ATIVO ou SUSPENSO também pode ser formalmente encerrado ou rescindido pelo botão "Encerrar/Rescindir contrato" (restrito a quem já edita guardrails, isto é DIRETOR/ADMINISTRADOR): escolha o tipo (ENCERRADO ou RESCINDIDO) e informe um motivo — obrigatório. A data efetiva e o motivo ficam gravados no próprio contrato, e o evento é auditado com o rótulo CONTRACT_TERMINATED; antes da Fase 3.8 esses dois status existiam apenas no cadastro, sem nenhum caminho no sistema para chegar até eles.`,
      },
      {
        titulo: 'Guardrails contratuais, clientes reservados e minuta',
        corpo: `Na tela de detalhe do contrato, o card "Guardrails contratuais" reúne as regras de proteção do negócio para aquele contrato específico: exclusividade comercial (tipo, área, cidade/POP/serviço, prazo e capacidade máxima), proibição de fibra de terceiros, proibição de rede própria do parceiro, direito de preferência, exigência de aprovação para expansão, e se o proprietário pode explorar a capacidade remanescente. Editar esse card é restrito a DIRETOR/ADMINISTRADOR.

O card "Clientes reservados" lista clientes finais que aquele parceiro está proibido de atender — cada entrada tem um tipo, PREFEITURA/ORGAO_PUBLICO ou OUTRO, e pode ser marcada como RESERVADO ou LIBERADO. Uma reserva do tipo PREFEITURA/ORGAO_PUBLICO recebe automaticamente, na minuta, uma cláusula própria fundamentada em interesse público — nunca tratada como uma simples reserva comercial. É uma lista de referência operacional: o sistema não tem hoje nenhuma tabela que associe automaticamente um cliente final nomeado a uma proposta ou contrato, então a checagem de que o parceiro está respeitando essa reserva continua sendo uma verificação manual de quem opera o contrato.

A proibição padrão de fibra de terceiros e de rede própria do parceiro só pode ser suspensa, contrato a contrato, através do workflow formal de exceção introduzido na Fase 3.8: a solicitação passa obrigatoriamente por parecer da Engenharia, parecer do Comercial e decisão final da Diretoria, nessa ordem, e cada rejeição registra o motivo e a etapa em que ocorreu. Enquanto não há uma aprovação vigente, a proibição continua valendo — a minuta reflete automaticamente esse histórico completo de solicitações na cláusula correspondente.

O botão "Baixar Minuta" (PDF ou DOCX) gera o documento completo do contrato a partir dos dados já validados — sempre rotulado com destaque "MINUTA SUJEITA À APROVAÇÃO JURÍDICA — NÃO ASSINAR SEM REVISÃO" na capa e no rodapé de cada página, e desde a Fase 3.8 com uma estrutura fixa de 44 seções (de Definições a Disposições Gerais). Cláusulas para as quais o sistema ainda não tem um texto jurídico definitivo aparecem em itálico laranja, começando com "[CLÁUSULA-MODELO", justamente para nunca serem confundidas com texto já revisado e aprovado — toda minuta gerada precisa passar por revisão jurídica antes de virar o documento assinado de verdade. O gerador da minuta nunca inventa dado: cada cláusula usa só o que já está cadastrado e validado no contrato, na proposta e na cidade, ou fica marcada como modelo pendente de redação jurídica.`,
      },
      {
        titulo: 'Auditoria',
        corpo: `A tela "Auditoria" (/auditoria) registra todo evento relevante do sistema — criação, edição, desativação, reativação, aprovação, reprovação, assinatura, validação, geração, exportação e cancelamento — sempre com quem fez, quando, e o motivo quando aplicável. Cada proponente também tem sua própria aba "Histórico & Auditoria" filtrada só para os eventos daquele registro; eventos de responsáveis, propostas ou contratos vinculados a ele continuam aparecendo na tela geral de Auditoria.

Desde a Fase 3.8, a trilha também cobre explicitamente inclusão/remoção de porta PON e de POP em um cabo/cidade, remoção de cliente reservado, encerramento/rescisão de contrato, e as três etapas do workflow de exceção de fibra de terceiros/rede própria (solicitação, aprovação e a exceção de rede própria propriamente dita) — eventos que antes só ficavam implícitos em registros de infraestrutura ou de contrato mais genéricos, agora têm um rótulo semântico próprio, mais fácil de filtrar e investigar.`,
      },
      {
        titulo: 'Alertas',
        corpo: `A tela "Alertas" (menu lateral) lista, individualmente, tudo que precisa de atenção: propostas aguardando aprovação/assinatura, contratos aguardando assinatura, documentos recusados, contratos próximos do vencimento, fim de carência comercial se aproximando, reajuste anual pendente ou vencido, ativos não devolvidos após encerramento de contrato, capacidade de Porta PON em 80/90/100%, e operações bloqueadas pelas regras de negócio (ex.: tentativa de ativar contrato com conflito de exclusividade). O botão "Gerar alertas" atualiza a lista a partir do estado atual do sistema — não existe um job agendado nesta fase, então a lista só reflete a realidade depois de gerada. Cada alerta pode ser marcado como "Resolvido" (DIRETOR/FINANCEIRO/ENGENHARIA/ADMINISTRADOR) depois de tratado; alertas resolvidos ficam disponíveis no filtro "Resolvidos", nunca apagados.

Nem todo tipo de alerta previsto no desenho do sistema é gerado hoje: alertas que dependeriam de faturamento real ou da integração HubSoft (nenhuma das duas ainda existe neste sistema) não têm como ser calculados honestamente e por isso não aparecem — é uma limitação documentada, não um bug.`,
      },
      {
        titulo: 'Relatórios gerenciais',
        corpo: `A tela "Relatórios" reúne seis relatórios prontos para consulta ou exportação em CSV: Receita por Cidade, Receita por Parceiro, Capacidade por POP, Clientes por Porta PON, Contratos e Reajustes. Cada um roda sob a mesma permissão (RLS) de quem está logado — nenhum relatório expõe dado que a pessoa não veria de outra forma no sistema.

Um relatório de Faturamento Real também está previsto na arquitetura, mas seu status é "indisponível" — depende de medições mensais reais de consumo/faturamento por contrato, que este sistema ainda não recebe nem armazena (isso depende da integração com o HubSoft, hoje fora de escopo). A tela mostra esse status honestamente em vez de simular números.`,
      },
      {
        titulo: 'Exceções e segurança',
        corpo: `AUDITOR tem acesso de leitura a tudo, mas nunca pode editar nada — nem proponente, nem usuário, nem infraestrutura. ENGENHARIA nunca aprova preço nem proposta. COMERCIAL e FINANCEIRO nunca alteram infraestrutura de rede. Só ADMINISTRADOR e DIRETOR executam ações de governança (aprovação de exceção de preço, restauração de infraestrutura arquivada, configuração do provedor de assinatura, exclusão física de usuário). Tentar contornar essas regras trocando o ID na URL ou chamando a API diretamente não funciona — a mesma restrição está implementada como Row-Level Security no banco, não só como um botão escondido na tela.`,
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
      {
        titulo: 'Multi-POP: capacidade e receita consolidadas',
        corpo: `Quando um contrato usa portas PON de mais de um POP, a tela de detalhe do contrato mostra um card "Multi-POP: capacidade e receita por POP" com a consolidação Cidade → POP → Porta PON → Capacidade → Clientes ativos → Disponível para cada POP envolvido, mais uma linha de total. A coluna de receita mensal é sempre rotulada "rateada (estimativa)" — é a mensalidade mínima do contrato distribuída entre os POPs proporcionalmente à capacidade de clientes de cada vínculo ativo, nunca um valor de faturamento real medido POP a POP (isso dependeria da integração HubSoft, fora de escopo). A mesma consolidação está disponível de forma agregada, por cidade, na tela de Relatórios → Capacidade por POP.`,
      },
      {
        titulo: 'Ativos e equipamentos cedidos',
        corpo: `Diferente de fibra, cabo, poste e porta PON — que são infraestrutura permanente da NICK e nunca são "devolvidos" por definição — um ativo cedido (OLT, ONU, ONT, fonte, switch) é um equipamento emprestado ou locado ao parceiro dentro de um contrato específico, e por isso tem um ciclo de vida próprio de cessão e devolução. O registro de cada ativo cedido a um contrato fica na própria tela de detalhe do contrato, com número de patrimônio/série, tipo e data de cessão.

Quando um contrato é encerrado ou rescindido, todo ativo cedido ainda vinculado a ele e sem registro de devolução aparece automaticamente na tela "Alertas" (ver abaixo) — o registro formal da devolução (ou da indenização, em caso de perda/dano) é feito na mesma tela de detalhe do contrato, e fica na trilha de auditoria como qualquer outra decisão sobre o contrato.`,
      },
      {
        titulo: 'Alertas relevantes para Engenharia',
        corpo: `A tela "Alertas" (menu lateral) traz três tipos de interesse direto de Engenharia: capacidade de Porta PON em 80/90/100% (gerados automaticamente sempre que um cliente é vinculado/removido de uma porta — nunca precisam do botão "Gerar alertas"), e "Ativos pendentes de devolução" — quando um contrato é encerrado ou rescindido e ainda existe algum ativo (OLT, ONU, switch, roteador) vinculado a ele sem registro de devolução. Esse alerta lista exatamente qual patrimônio/número de série está pendente, para orientar a coleta física do equipamento.`,
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
      {
        titulo: 'Minuta de contrato e clientes reservados',
        corpo: `Na tela de detalhe do contrato, o botão "Baixar Minuta" gera um rascunho do contrato em PDF/DOCX a partir dos dados já validados — sempre marcado "MINUTA SUJEITA À APROVAÇÃO JURÍDICA", nunca um documento pronto para assinar sem revisão, e desde a Fase 3.8 sempre com a mesma estrutura fixa de 44 seções. O card "Clientes reservados" mostra, se existir, quais clientes finais aquele parceiro está proibido de atender, com um tipo — PREFEITURA/ORGAO_PUBLICO (reserva de interesse público, com cláusula jurídica própria na minuta) ou OUTRO (reserva comercial) — vale a pena consultar antes de fechar negócio com um cliente final específico em nome do parceiro.

Um parceiro só pode usar fibra de terceiros ou construir rede própria mediante exceção aprovada: a solicitação é feita pelo comercial mas depende de parecer da Engenharia e decisão final da Diretoria antes de valer — nunca é uma liberação automática nem informal.`,
      },
      {
        titulo: 'Acompanhando alertas do funil comercial',
        corpo: `A tela "Alertas" concentra, num único lugar, tudo que está parado ou precisa de decisão: propostas aguardando aprovação, propostas/contratos aguardando assinatura, documentos recusados na assinatura, contratos próximos do vencimento e o fim da carência comercial se aproximando (o momento em que o preço do parceiro sobe para o valor cheio). É um bom ponto de partida para o acompanhamento diário do funil, em vez de checar cada proposta/contrato individualmente.`,
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
        corpo: `O total mensal pago à OptiMon (total_payable) é composto a partir do modo de composição escolhido na simulação: FLOOR_AS_MINIMUM (padrão — o piso de infraestrutura assume o papel do mínimo contratual, somado ao revenue share), SUM (piso mais mínimo mais revenue share), FLOOR_ONLY (só o piso) ou MINIMUM_ONLY (só o mínimo contratual). Desde a Fase 3.8, a regra de cobrança da NICK é sempre SOMA — mínimo (ou piso, no modo FLOOR_AS_MINIMUM) MAIS revenue share, os dois sempre somados; a opção "MAX" (cobrar apenas o maior entre os dois) foi removida do sistema inteiro, inclusive de contratos já existentes, que foram recalculados para SOMA. A receita do parceiro é sempre o faturamento total menos esse valor. Esses mesmos campos — Valor, Mínimo e Revenue Share — são os que aparecem preenchidos automaticamente no contrato gerado a partir da proposta aprovada.`,
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
      {
        titulo: 'Relatórios',
        corpo: `A tela "Relatórios" traz seis relatórios prontos, cada um exportável em CSV: Receita por Cidade, Receita por Parceiro, Capacidade por POP, Clientes por Porta PON, Contratos e Reajustes — todos calculados a partir do que já está contratado/reajustado no sistema, nunca de faturamento real de terceiros.

Um relatório de Faturamento Real também está desenhado na arquitetura, mas hoje aparece como "indisponível": ele depende de medições mensais reais de consumo/faturamento por contrato (e, em última instância, da integração com o HubSoft), que este sistema ainda não recebe. Pelo mesmo motivo, o Revenue Share e o Take-or-Pay mostrados em telas e relatórios são sempre a condição contratual (o que está pactuado), nunca o valor realmente cobrado/pago mês a mês — essa distinção importa para conciliação financeira.

No relatório Capacidade por POP, a coluna de receita mensal para contratos Multi-POP é sempre rotulada "rateada (estimativa)": é a mensalidade mínima contratada dividida entre os POPs usados, proporcionalmente à capacidade de clientes de cada vínculo — não é faturamento real medido por POP, e a tela sempre mostra a metodologia usada ao lado do número.`,
      },
      {
        titulo: 'Alertas financeiros',
        corpo: `A tela "Alertas" traz dois tipos de interesse direto do Financeiro: "Reajuste anual pendente" (contrato com índice de reajuste configurado cujo ciclo de 12 meses está vencendo em até 30 dias, ou já venceu sem que um novo reajuste tenha sido aplicado) e "Fim da carência comercial" (aviso de que o preço do parceiro vai subir para o valor cheio em até 30 dias — útil para prever a mudança de receita). Contratos com índice de reajuste "SEM_REAJUSTE" nunca geram o alerta de reajuste, por desenho.`,
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
        corpo: `Somente DIRETOR e ADMINISTRADOR podem: aprovar propostas que saíram do rascunho, autorizar preços abaixo do piso, aprovar aditivos contratuais, restaurar qualquer item de infraestrutura arquivado, editar a configuração do provedor de assinatura, mover uma proposta por qualquer transição de status além do rascunho, decidir (última etapa) o workflow de exceção de fibra de terceiros/rede própria, e encerrar/rescindir um contrato. Essa restrição é aplicada tanto na interface quanto diretamente no banco de dados (Row-Level Security) — não é possível contornar via API.`,
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
        titulo: 'Assinaturas, contratos ativos e encerramento',
        corpo: `Um contrato só pode ser ativado depois que a assinatura eletrônica correspondente está VALIDADA — o botão "Ativar contrato" fica indisponível até lá. Uma vez ativo, o contrato é bloqueado contra edição direta: qualquer mudança de condição passa a exigir um aditivo formal, com seu próprio ciclo de aprovação e assinatura, nunca uma edição silenciosa.

Desde a Fase 3.8, um contrato ATIVO ou SUSPENSO também pode ser formalmente encerrado (ENCERRADO) ou rescindido (RESCINDIDO) pelo botão "Encerrar/Rescindir contrato", com motivo obrigatório — uma funcionalidade que antes não existia no sistema, apesar de esses dois status já constarem do cadastro desde a Fase 1. Depois de encerrado, o contrato não pode ser reativado; ativos cedidos ainda vinculados e não devolvidos aparecem automaticamente na tela Alertas.`,
      },
      {
        titulo: 'Guardrails contratuais, exceções e minuta',
        corpo: `Editar o card "Guardrails contratuais" (exclusividade comercial, proibição de fibra de terceiros/rede própria, direito de preferência, exigência de aprovação de expansão) e o cadastro de "Clientes reservados" de um contrato é restrito a DIRETOR/ADMINISTRADOR — são as regras que protegem o relacionamento comercial de longo prazo com o parceiro, então a mudança fica registrada como qualquer outra decisão de governança. A minuta de contrato gerada pelo sistema (botão "Baixar Minuta", hoje com 44 seções fixas) é sempre um rascunho sujeito a aprovação jurídica — nunca trate como o documento final pronto para assinar.

A suspensão da proibição de fibra de terceiros/rede própria para um contrato específico sempre termina na Diretoria: mesmo depois de pareceres favoráveis da Engenharia e do Comercial, a decisão final — aprovar ou rejeitar, com motivo — é sempre do DIRETOR/ADMINISTRADOR, e enquanto ela não existir a proibição continua em vigor.`,
      },
      {
        titulo: 'Visão consolidada e alertas',
        corpo: `O Dashboard mostra os principais indicadores agregados — cidades ativas, capacidade de rede, contratos ativos, propostas pendentes, assinaturas pendentes, contratos pendentes de assinatura, reajustes próximos, proponentes ativos, usuários ativos e com convite pendente, e a contagem de alertas não resolvidos (com link direto para a tela "Alertas") — sempre excluindo infraestrutura arquivada dos números de capacidade. A tela "Alertas" detalha cada item individualmente (proposta/contrato parado, documento recusado, reajuste vencendo, fim de carência, ativo não devolvido, capacidade no limite, operação bloqueada) e permite marcar como resolvido depois de tratado. A lista de Propostas e a de Contratos podem ser filtradas por status para acompanhar o funil completo, da simulação até o contrato ativo.`,
      },
      {
        titulo: 'Documento para apresentação externa',
        corpo: `Ao compartilhar uma proposta com um parceiro, sempre use o modo "Externa" (na tela de detalhe da proposta) antes de exportar — ele remove automaticamente piso, desconto aplicado e qualquer dado de governança interna, deixando só as condições comerciais que o parceiro precisa avaliar.`,
      },
      {
        titulo: 'Trilha de auditoria como ferramenta de governança',
        corpo: `Toda decisão de exceção (autorização abaixo do piso, aprovação de aditivo, restauração de infraestrutura arquivada, rejeição de proposta, desativação/exclusão física de usuário ou proponente) fica permanentemente registrada com autor, data/hora e motivo — a tela de Auditoria é a fonte de verdade para qualquer revisão de compliance ou disputa comercial futura, e nunca pode ser editada ou apagada, nem por ADMINISTRADOR. Uma tentativa de operação bloqueada pelas regras de negócio (ex.: ativar um contrato com conflito de exclusividade comercial) também gera automaticamente um alerta do tipo "Operação bloqueada" na tela Alertas, além do registro na auditoria — assim uma tentativa recorrente de contornar uma regra fica visível sem precisar vasculhar o log inteiro.`,
      },
      {
        titulo: 'Relatórios para acompanhamento executivo',
        corpo: `A tela "Relatórios" reúne Receita por Cidade, Receita por Parceiro, Capacidade por POP, Clientes por Porta PON, Contratos e Reajustes, todos exportáveis em CSV para apresentação ou análise externa. O relatório de Faturamento Real ainda aparece como indisponível nesta fase — depende de dados de faturamento/medição real que o sistema não recebe hoje (ligado à integração HubSoft, fora de escopo) — os números de receita mostrados em todo o sistema são sempre a condição contratual pactuada, nunca o valor efetivamente cobrado. Para contratos Multi-POP, o relatório de Capacidade por POP mostra também uma receita mensal "rateada (estimativa)" por POP — sempre uma distribuição proporcional da mensalidade contratada, nunca uma medição real de consumo por POP.`,
      },
    ],
  },
  {
    slug: 'auditor',
    titulo: 'Manual do Auditor',
    publico: 'AUDITOR',
    resumo: 'Acesso de leitura a todo o sistema — cidades, propostas, contratos, usuários, proponentes, assinaturas, alertas e relatórios — sem poder criar, editar, aprovar ou excluir nada.',
    secoes: [
      {
        titulo: 'O que o perfil AUDITOR pode e não pode fazer',
        corpo: `AUDITOR é o único perfil pensado exclusivamente para leitura: você enxerga tudo que os outros perfis enxergam nas telas de Cidades & Infraestrutura, Propostas, Proponentes, Contratos, Assinaturas, Usuários, Alertas, Relatórios e, principalmente, Auditoria — mas nenhum botão de criar, editar, aprovar, rejeitar, arquivar, restaurar, desativar ou excluir fica disponível para esse perfil. Essa restrição não é só visual: mesmo que uma chamada à API fosse feita diretamente (contornando a tela), a mesma regra está implementada como Row-Level Security no banco de dados e bloqueia a escrita da mesma forma.

Se você notar um botão de ação aparecendo indevidamente para o perfil AUDITOR, é uma falha de interface que vale reportar — mas mesmo nesse caso hipotético, a ação em si seria rejeitada pelo banco.`,
      },
      {
        titulo: 'Auditoria — sua principal ferramenta de trabalho',
        corpo: `A tela "Auditoria" (/auditoria) é o registro central de todo evento relevante do sistema: criação, edição, arquivamento, restauração, tentativas bloqueadas, aprovações, rejeições, assinaturas, validações, geração de contrato, exclusões físicas e exportações — cada linha mostra quem fez, quando, o valor anterior e o novo (quando aplicável) e o motivo informado. Use os filtros por entidade e ação para investigar um caso específico. Desde a Fase 3.8, o filtro de entidade também cobre diretamente infra_pops, infra_portas_pon, contrato_clientes_reservados, contrato_regras_solicitacoes, ativos e ativos_devolucao, e a tabela ganhou rótulos semânticos próprios para eventos como inclusão/remoção de porta PON ou POP, encerramento de contrato e cada etapa do workflow de exceção de fibra de terceiros/rede própria. A tabela de auditoria é estruturalmente imutável: nenhum perfil, nem ADMINISTRADOR, consegue alterar ou apagar um registro já gravado — o que você vê ali é garantidamente o que aconteceu, na ordem em que aconteceu.

Cada proponente também tem sua própria aba "Histórico & Auditoria", já filtrada só para os eventos daquele registro — útil para reconstruir o histórico de um parceiro específico sem precisar aplicar filtros manualmente na tela geral.`,
      },
      {
        titulo: 'Acompanhando o funil e os alertas',
        corpo: `A tela "Alertas" mostra tudo que está pendente de tratamento no sistema — propostas/contratos parados, documentos recusados, reajustes vencendo, fim de carência, ativos não devolvidos, capacidade no limite e operações bloqueadas — uma boa visão panorâmica para identificar padrões (por exemplo, muitas tentativas de operação bloqueada de um mesmo usuário) sem precisar vasculhar a auditoria evento a evento. O botão "Gerar alertas" e "Marcar resolvido" não ficam disponíveis para este perfil — a leitura da lista, sim.`,
      },
      {
        titulo: 'Relatórios',
        corpo: `Os seis relatórios da tela "Relatórios" (Receita por Cidade, Receita por Parceiro, Capacidade por POP, Clientes por Porta PON, Contratos e Reajustes) estão disponíveis para consulta e exportação em CSV, com os mesmos dados que qualquer outro perfil autorizado a lê-los veria — nenhum relatório é filtrado ou resumido de forma diferente para AUDITOR.`,
      },
      {
        titulo: 'Documento Interno x Externo',
        corpo: `Ao visualizar uma proposta, o modo "Interna" mostra piso, desconto aplicado e status de governança; o modo "Externa" mostra só o que o parceiro veria. Como leitor, você pode alternar entre os dois modos livremente para conferir que a proposta correta foi enviada ao parceiro — mas a exportação/geração de arquivo, quando disponível para outros perfis, segue as mesmas trilhas de auditoria que você já consegue consultar.`,
      },
    ],
  },
  {
    slug: 'assinatura-eletronica',
    titulo: 'Como funciona a assinatura eletrônica',
    publico: null,
    resumo: 'O caminho completo de uma proposta ou contrato até virar um documento assinado — arquitetura pronta para ICP-Brasil, mas leia primeiro o status atual abaixo antes de assumir que a validação é criptograficamente real.',
    secoes: [
      {
        titulo: 'STATUS ATUAL (leia antes de tudo): NÃO TESTADO com provedor real',
        corpo: `Honestidade em primeiro lugar: hoje o motor de assinatura só tem um provedor de fato implementado — um MOCK de homologação, que nunca faz nenhuma chamada de rede real e nunca lida com um certificado digital de verdade. O tipo "ICP_BRASIL_PROVEDOR_EXTERNO" existe no cadastro de provedores e na arquitetura, mas NÃO tem nenhum código de integração por trás — tentar usá-lo hoje resulta em erro controlado (PROVEDOR_NAO_IMPLEMENTADO), nunca em uma assinatura real. Isso significa: nenhuma cadeia de certificado é validada, nenhum e-CPF/e-CNPJ é conferido, nenhum carimbo de tempo (timestamp authority) é aplicado, e o PDF final não é um PAdES de verdade. O rótulo "Assinatura Qualificada ICP-Brasil" em telas e relatórios é hoje uma POLÍTICA configurada no sistema (uma regra de negócio, sempre obrigatória para o Contrato de Cessão de Uso) — não uma prova criptográfica de que uma Autoridade Certificadora real validou algo. Use o ambiente de homologação (mock) para testar o fluxo operacional completo (criação de envelope, signatários, webhook, trilha de auditoria) com total confiança — mas nenhum documento "assinado" neste ambiente tem validade jurídica real até que um provedor ICP-Brasil de verdade seja integrado e testado.`,
      },
      {
        titulo: 'Visão geral: da proposta ao contrato ativo',
        corpo: `1) Proposta aprovada. 2) Documento gerado a partir da proposta (ou do contrato/aditivo, conforme o caso). 3) Signatários definidos — sempre o responsável cadastrado no proponente, do lado do parceiro, e o representante da OptiMon do outro. 4) Envelope enviado para assinatura via o provedor de assinatura configurado (hoje, sempre o mock de homologação — ver status atual acima). 5) Cada signatário "assina" através do provedor configurado — com um provedor ICP-Brasil real (ainda não integrado), isso seria uma assinatura digital com certificação de verdade; com o mock atual, é uma simulação para testar o fluxo. 6) O OptiMon recebe a confirmação (webhook) do provedor e atualiza o status do envelope. 7) A assinatura é "validada" pelas regras de negócio do sistema (status de cada signatário, política aplicável) — isso NUNCA foi, até hoje, uma validação criptográfica junto a uma Autoridade Certificadora real, porque nenhuma foi integrada. 8) Com a assinatura validada (pelas regras acima), o contrato pode ser ativado.`,
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
        corpo: `O botão "Validar assinatura" não é decorativo: ele consulta o provedor configurado e só marca o envelope como VALIDADO se o hash do documento estiver presente, o status do envelope for compatível e todos os signatários estiverem com status ASSINADO. Um envelope apenas "assinado" (ainda não validado) não libera a ativação do contrato — só um envelope validado libera. Importante (ver status atual no topo deste guia): com o provedor mock de hoje, essa checagem é uma verificação de consistência dos dados registrados no OptiMon — nunca uma verificação criptográfica de certificado junto a uma Autoridade Certificadora real, porque nenhum provedor ICP-Brasil real está integrado ainda.`,
      },
      {
        titulo: 'Baixando o documento assinado e a trilha de auditoria',
        corpo: `"Baixar documento assinado" entrega o PDF final com as assinaturas. A seção "Trilha de auditoria (eventos + evidências do provedor)", na tela do envelope, mostra toda a linha do tempo — criação, envio, cada evento recebido do provedor, assinatura de cada signatário e validação — com data/hora de cada passo, a mesma fonte usada para comprovar o processo em uma eventual disputa.`,
      },
      {
        titulo: 'Política padrão para Contrato de Cessão de Uso',
        corpo: `Para o Contrato de Cessão de Uso, a política de assinatura configurada é sempre Assinatura Qualificada ICP-Brasil — a mais alta prevista pelo sistema, e a regra é fixa: não pode ser alterada por COMERCIAL nem por nenhum outro perfil comercial, só ADMINISTRADOR/DIRETOR configuram o provedor, e mesmo assim essa política mínima não muda. Isso garante que o sistema NUNCA aceitará silenciosamente uma política mais fraca para este tipo de documento assim que um provedor ICP-Brasil real for integrado — mas até lá (ver status atual no topo deste guia), essa política é aplicada sobre o provedor mock de homologação, então nenhum documento assinado hoje tem o nível de certificação que o rótulo sugere.`,
      },
    ],
  },
];

export function findManualBySlug(slug) {
  return MANUALS.find((m) => m.slug === slug);
}
