// OptiMon — Fase 2.4 (seção 2): Perguntas frequentes da Central de Ajuda.
// Fase 2.5.1 (seção 29): acrescenta as perguntas sobre o novo fluxo de usuário sem
// UUID, onde a senha fica guardada, proponente/exclusão lógica, alteração de contrato
// e o que significa uma assinatura validada.
// Fase 3.8 (item 3.8-16): acrescenta as perguntas sobre a reserva formal de Prefeitura/
// órgão público, o workflow de exceção de fibra de terceiros/rede própria, como encerrar
// ou rescindir um contrato, o que significa a receita rateada por POP, e o novo número
// de seções da minuta.

export const FAQ = [
  {
    pergunta: 'Preciso cadastrar o UUID do usuário?',
    resposta: 'Não. O identificador de autenticação (UUID) é sempre gerado automaticamente pelo Supabase Auth no momento em que você clica em "Criar Usuário" — o administrador nunca precisa conhecer, copiar ou digitar esse valor em nenhuma tela do OptiMon.',
  },
  {
    pergunta: 'Onde a senha fica armazenada?',
    resposta: 'A senha nunca é armazenada em nenhuma tabela do OptiMon. Ela fica exclusivamente no Supabase Auth, o serviço de autenticação — cada usuário define a própria senha pelo link do convite (ou de redefinição), e só ele a conhece.',
  },
  {
    pergunta: 'O OptiMon guarda minha senha?',
    resposta: 'Não. Nenhuma senha é lida, guardada ou processada pelo OptiMon em nenhum momento — a autenticação acontece sempre direto contra o Supabase Auth.',
  },
  {
    pergunta: 'O que acontece se o contrato for alterado?',
    resposta: 'Um contrato ativo é bloqueado para edição direta. Qualquer mudança de condição (infraestrutura, prazo, condição comercial) passa a exigir um aditivo formal, com seu próprio ciclo de aprovação e assinatura, preservando a versão anterior. Uma alteração de valor por reajuste também nunca sobrescreve o histórico — sempre cria um novo evento.',
  },
  {
    pergunta: 'Posso excluir um proponente?',
    resposta: 'Não fisicamente. O OptiMon nunca faz exclusão física de proponente — "Desativar" é sempre uma exclusão lógica, com motivo obrigatório: o registro some da listagem padrão de ativos, mas continua existindo (visível pelo filtro "Todos"/"Inativos") e pode ser reativado depois por quem tem permissão.',
  },
  {
    pergunta: 'O que significa assinatura validada?',
    resposta: 'Significa que o OptiMon confirmou, junto ao provedor de assinatura, que o documento assinado é íntegro e que a assinatura de cada signatário é autêntica — não é o mesmo que "assinado": um envelope apenas assinado ainda não libera a ativação do contrato, só um envelope validado libera.',
  },
  {
    pergunta: 'Por que não consigo arquivar um POP/segmento/cabo?',
    resposta: 'O arquivamento é bloqueado quando o item tem alguma dependência ainda ativa (por exemplo, um segmento com cabos ativos, ou um cabo com fibras ocupadas). A mensagem de erro explica exatamente qual dependência precisa ser resolvida primeiro.',
  },
  {
    pergunta: 'Por que só ADMINISTRADOR e DIRETOR conseguem restaurar um item arquivado?',
    resposta: 'É uma decisão de governança deliberada: qualquer perfil autorizado pode arquivar, mas restaurar (reverter essa decisão) exige um nível de aprovação maior, para evitar reversões acidentais ou não supervisionadas.',
  },
  {
    pergunta: 'O que acontece se eu excluir um item de infraestrutura?',
    resposta: 'O OptiMon nunca exclui fisicamente nenhum registro de infraestrutura ou proposta — toda "exclusão" é lógica (arquivamento). O dado continua no banco, marcado como removido, preservando o histórico completo para auditoria.',
  },
  {
    pergunta: 'Qual a diferença entre Preço Recomendado e Preço Proposto?',
    resposta: 'O Recomendado é calculado automaticamente pelo Pricing Engine. O Proposto é o valor que o comercial efetivamente digita para oferecer ao parceiro — pode ser igual, maior ou menor que o recomendado. Se for menor, a proposta pode precisar de aprovação.',
  },
  {
    pergunta: 'Por que minha proposta nasceu com status "Em Aprovação"?',
    resposta: 'Isso acontece automaticamente quando o preço proposto está abaixo do preço recomendado. Um DIRETOR ou ADMINISTRADOR precisa aprovar a proposta antes que ela possa avançar para Aprovada/Enviada.',
  },
  {
    pergunta: 'O que preciso informar para aprovar uma proposta abaixo do piso?',
    resposta: 'Um motivo/justificativa é obrigatório nesse caso — o sistema recusa a aprovação sem ele. Quem aprovou, quando e o preço autorizado ficam registrados permanentemente.',
  },
  {
    pergunta: 'Qual a diferença entre "Nova Versão" e "Duplicar Proposta"?',
    resposta: '"Nova Versão" cria V2, V3 etc. dentro da mesma proposta (mesmo número, histórico ligado). "Duplicar Proposta" cria uma proposta totalmente nova e independente, com seu próprio número e sua própria linha de versões.',
  },
  {
    pergunta: 'Qual a diferença entre o documento Interno e o Externo?',
    resposta: 'O documento Interno mostra piso, desconto aplicado e dados de governança/autorização — uso exclusivo da equipe OptiMon. O Externo mostra só as condições comerciais que o parceiro precisa avaliar, sem nenhum dado sensível de margem ou governança.',
  },
  {
    pergunta: 'Como o PDF/DOCX exportado é gerado?',
    resposta: 'O documento é montado inteiramente no servidor a partir dos dados da proposta — nunca é uma captura de tela do navegador. Segue sempre a mesma estrutura de 28 seções, com capa, cabeçalho, rodapé, numeração de página, tabelas e gráficos.',
  },
  {
    pergunta: 'Os 4 gráficos aparecem também no arquivo DOCX?',
    resposta: 'No DOCX, os mesmos dados dos 4 gráficos aparecem como tabelas editáveis (o formato DOCX é pensado para ser editado pelo comercial). No PDF, os 4 gráficos aparecem desenhados como gráficos de barras.',
  },
  {
    pergunta: 'O que significam os 3 cenários (Conservador/Base/Agressivo)?',
    resposta: 'São variações de sensibilidade comercial em torno do volume de clientes simulado (-15% / valor simulado / +15%), úteis para planejamento — nunca substituem o preço e o total contratual já calculados pelo Pricing Engine.',
  },
  {
    pergunta: 'Por que a projeção de 60 meses aparece marcada como "projeção"?',
    resposta: 'O prazo contratual mínimo padrão é 48 meses. Qualquer horizonte além disso (como 60 meses) é sempre uma estimativa ilustrativa, não um compromisso contratual.',
  },
  {
    pergunta: 'Por que uma Prefeitura recebe uma cláusula diferente no contrato?',
    resposta: 'Desde a Fase 3.8, um cliente reservado pode ter o tipo PREFEITURA/ORGAO_PUBLICO — nesse caso a minuta gera uma cláusula própria fundamentada em interesse público, nunca tratada como uma reserva comercial comum (tipo OUTRO). É uma distinção jurídica deliberada, não apenas uma etiqueta.',
  },
  {
    pergunta: 'Posso liberar um parceiro para usar fibra de terceiros ou construir rede própria?',
    resposta: 'Só através do workflow formal de exceção: a solicitação passa obrigatoriamente por parecer da Engenharia, parecer do Comercial e decisão final da Diretoria, nessa ordem. Enquanto não há uma aprovação vigente para aquele contrato, a proibição padrão continua valendo integralmente — não existe liberação verbal ou por fora do sistema.',
  },
  {
    pergunta: 'Como encerro ou rescindo um contrato?',
    resposta: 'Na tela de detalhe do contrato (para contratos ATIVO ou SUSPENSO), use o botão "Encerrar/Rescindir contrato", escolha o tipo (ENCERRADO ou RESCINDIDO) e informe um motivo — obrigatório. A ação fica registrada na auditoria com o motivo e a data efetiva de encerramento, e o contrato deixa de poder ser ativado novamente.',
  },
  {
    pergunta: 'O que significa a "receita mensal rateada" no relatório de Capacidade por POP?',
    resposta: 'É uma estimativa: para contratos que usam mais de um POP (Multi-POP), a mensalidade mínima contratada é distribuída entre os POPs proporcionalmente à capacidade de clientes de cada vínculo. Não é faturamento real medido — o OptiMon não recebe dados de consumo/faturamento efetivo por POP (isso depende da integração HubSoft, fora de escopo). A tela sempre explica a metodologia usada ao lado do número.',
  },
  {
    pergunta: 'Quantas seções tem a minuta de contrato gerada pelo sistema?',
    resposta: '44 seções, cobrindo desde Definições e Objeto até Foro e Disposições Gerais — incluindo cláusulas com texto jurídico definitivo (quando derivam de dados/regras já existentes no sistema) e cláusulas ainda marcadas "[CLÁUSULA-MODELO — AGUARDANDO REDAÇÃO DO JURÍDICO DA NICK]" para os pontos que dependem de redação jurídica específica. Em ambos os casos, a minuta inteira continua sujeita a aprovação jurídica antes de virar documento assinável.',
  },
];
