// OptiMon — Fase 2.4 (seção 2): Perguntas frequentes da Central de Ajuda.

export const FAQ = [
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
];
