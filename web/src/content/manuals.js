// OptiMon — Fase 2.4 (seção 2-5): conteúdo dos 4 manuais operacionais por perfil.
// Consumido por Help.jsx (Central de Ajuda, /ajuda) e pelo menu "Ajuda & Manuais".
// Cada manual é uma lista de seções {titulo, corpo} — corpo é texto simples (parágrafos
// separados por linha em branco), renderizado pelo componente de manual sem precisar de
// um parser de markdown.

export const MANUALS = [
  {
    slug: 'engenharia',
    titulo: 'Manual de Engenharia',
    publico: 'ENGENHARIA',
    resumo: 'Cadastro e ciclo de vida da infraestrutura de rede: cidades, POPs, segmentos, cabos, fibras, postes e portas PON.',
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
        titulo: 'POPs, segmentos e cabos',
        corpo: `Um POP (Ponto de Presença) é criado dentro de uma cidade, com código, nome, tipo e endereço. Um segmento de rede também pertence a uma cidade e conecta origem/destino. Um cabo é criado dentro de um segmento e, ao ser cadastrado, já cria automaticamente as fibras que o compõem (uma linha por fibra, todas nascendo com status LIVRE).

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

Ao arquivar, o sistema sempre pede um motivo (lista fechada de opções) e permite uma observação livre opcional. Restaurar um item arquivado é uma ação restrita — só ADMINISTRADOR ou DIRETOR podem restaurar, mesmo que ENGENHARIA tenha permissão para arquivar.`,
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
    resumo: 'Como simular preços, gerar propostas comerciais profissionais e acompanhar o status de cada proposta até o fechamento.',
    secoes: [
      {
        titulo: 'O fluxo comercial em 4 passos',
        corpo: `1) Simule o preço em "Nova Simulação" escolhendo cidade, volume de clientes e ARPU. 2) Ajuste o preço proposto (o sistema sugere o valor recomendado). 3) Informe os dados do parceiro e clique em "Gerar Proposta". 4) Acompanhe, edite e exporte a proposta em "Propostas".`,
      },
      {
        titulo: 'A régua de preço',
        corpo: `Toda simulação mostra três referências: o Piso (o valor mínimo absoluto que a OptiMon aceita — nunca deve ser oferecido a um parceiro sem autorização formal), o Recomendado (o preço sugerido pelo Pricing Engine, que já considera a economia com o piso de infraestrutura da cidade) e a Abertura (um preço de partida mais alto, útil como referência de negociação).

O preço proposto pode ser digitado livremente, mas o sistema sempre recalcula floor/recomendado/abertura no servidor — o comercial nunca define esses três valores manualmente.`,
      },
      {
        titulo: 'Gerando uma proposta',
        corpo: `Depois de simular, o botão "Gerar Proposta" salva a simulação e cria a proposta com um número único (padrão PROP-AAAAMMDD-xxxxxxxx). Informe o parceiro (cadastrado ou nome livre), o cargo do contato e a validade em dias — esses dados aparecem na capa do documento exportado.

Se o preço proposto estiver abaixo do preço recomendado, a proposta já nasce com status "Em Aprovação" — ela precisa ser aprovada por um DIRETOR ou ADMINISTRADOR antes de avançar no funil.`,
      },
      {
        titulo: 'Ciclo de vida da proposta',
        corpo: `Rascunho → Em Aprovação (se necessário) → Aprovada → Enviada → Em Negociação → Aceita (fechamento) ou Recusada/Expirada/Cancelada. Cada transição fica registrada na auditoria com quem fez, quando e por quê.

Uma proposta nunca é sobrescrita: se você precisa mudar valores depois de já ter sido enviada, use "Nova Versão" — o sistema cria V2, V3 etc., preservando o histórico completo de cada versão anterior.`,
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
    resumo: 'Como interpretar a composição de preço, a régua de governança e os relatórios de auditoria financeira.',
    secoes: [
      {
        titulo: 'A composição do preço final',
        corpo: `O total mensal pago à OptiMon (total_payable) é composto a partir do modo de composição escolhido na simulação: MAX (o maior entre o piso e o revenue share calculado), SUM (piso mais revenue share), FLOOR_ONLY (só o piso) ou MINIMUM_ONLY (só o mínimo contratual). A receita do parceiro é sempre o faturamento total menos esse valor.`,
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
        corpo: `A tela "Auditoria" lista todo evento relevante do sistema: criação, edição, arquivamento, restauração, tentativas bloqueadas, aprovações, rejeições e exportações de proposta. Cada linha mostra quem fez, quando, o que mudou (valor anterior e novo) e o motivo informado, quando aplicável. Use os filtros por entidade e ação para investigar um caso específico.`,
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
    resumo: 'Visão executiva: aprovação de propostas, exceções de preço, e como o OptiMon garante controle sobre toda decisão comercial.',
    secoes: [
      {
        titulo: 'O papel do DIRETOR/ADMINISTRADOR no fluxo',
        corpo: `Somente DIRETOR e ADMINISTRADOR podem: aprovar propostas que saíram do rascunho, autorizar preços abaixo do piso, restaurar qualquer item de infraestrutura arquivado, e mover uma proposta por qualquer transição de status além do rascunho. Essa restrição é aplicada tanto na interface quanto diretamente no banco de dados (Row-Level Security) — não é possível contornar via API.`,
      },
      {
        titulo: 'Aprovando uma proposta',
        corpo: `Na tela de detalhe da proposta, o botão "Aprovar" fica disponível para propostas em Rascunho ou Em Aprovação. Se o preço proposto estiver abaixo do piso, o campo de motivo é obrigatório — o sistema recusa a aprovação sem uma justificativa. Uma vez aprovada, ficam registrados permanentemente: quem aprovou, quando, o preço autorizado e o motivo.`,
      },
      {
        titulo: 'Visão consolidada',
        corpo: `O Dashboard mostra os principais indicadores agregados (cidades ativas, capacidade de rede, propostas por status) sempre excluindo infraestrutura arquivada dos números de capacidade. A lista de Propostas pode ser filtrada por status para acompanhar o funil completo, da simulação até o fechamento.`,
      },
      {
        titulo: 'Documento para apresentação externa',
        corpo: `Ao compartilhar uma proposta com um parceiro, sempre use o modo "Externa" (na tela de detalhe da proposta) antes de exportar — ele remove automaticamente piso, desconto aplicado e qualquer dado de governança interna, deixando só as condições comerciais que o parceiro precisa avaliar.`,
      },
      {
        titulo: 'Trilha de auditoria como ferramenta de governança',
        corpo: `Toda decisão de exceção (autorização abaixo do piso, restauração de infraestrutura arquivada, rejeição de proposta) fica permanentemente registrada com autor, data/hora e motivo — a tela de Auditoria é a fonte de verdade para qualquer revisão de compliance ou disputa comercial futura.`,
      },
    ],
  },
];

export function findManualBySlug(slug) {
  return MANUALS.find((m) => m.slug === slug);
}
