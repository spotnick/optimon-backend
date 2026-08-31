// OptiMon — Fase 3 (item 3.7): modelo de documento da MINUTA DE CONTRATO.
//
// Módulo puro (sem I/O), análogo a proposalDocumentModel.js: transforma o jsonb de
// app.contrato_documento_dados/public.pricing_contrato_documento_dados num array de
// seções {n, titulo, texto|tipo:'tabela'|'assinatura'}, consumido igualmente por
// pdfContrato.js e docxContrato.js.
//
// REGRA ABSOLUTA (nunca violar): este documento é sempre "MINUTA SUJEITA À APROVAÇÃO
// JURÍDICA" — nunca um contrato definitivo. Cada cláusula é montada só a partir de dados
// reais do banco (nunca um número/prazo/percentual inventado). Onde não existe fonte de
// dado ou redação jurídica aprovada (confidencialidade, LGPD, foro, redação exata de
// rescisão/penalidades), a seção diz isso explicitamente — "cláusula-modelo a ser
// redigida pelo jurídico da NICK" — nunca um texto genérico apresentado como se fosse
// definitivo.

function fmtBRL(v) {
  const n = Number(v);
  if (v === null || v === undefined || Number.isNaN(n)) return '—';
  return n.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
}
function fmtPct(v, digits = 1) {
  const n = Number(v);
  if (v === null || v === undefined || Number.isNaN(n)) return '—';
  return `${(n * 100).toFixed(digits)}%`;
}
function fmtDate(v) {
  if (!v) return '—';
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return '—';
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric' });
}
function fmtInt(v) {
  const n = Number(v);
  if (v === null || v === undefined || Number.isNaN(n)) return '—';
  return n.toLocaleString('pt-BR');
}

const EXCLUSIVIDADE_TIPO_LABEL = {
  TERRITORIAL: 'territorial (área geográfica)',
  SERVICO: 'por tipo de serviço',
  CAPACIDADE: 'limitada por capacidade contratada',
  MISTA: 'mista (território + serviço/capacidade)',
};

function buildExclusividadeTexto(regras) {
  if (!regras) {
    return 'Nenhum registro de guardrails contratuais encontrado para este contrato. Por padrão do sistema (seção 21-24), o parceiro NÃO tem exclusividade, é proibido de usar fibra de terceiros e de construir rede própria na área do contrato sem autorização expressa — mas isso deve ser confirmado manualmente antes da assinatura, pois o registro específico deste contrato está ausente.';
  }
  const partes = [];
  if (!regras.exclusividade_comercial) {
    partes.push('Este contrato NÃO concede exclusividade comercial ao parceiro. A NICK preserva o direito de contratar outros parceiros na mesma área/cidade/POP, ressalvados apenas os clientes reservados listados na cláusula específica.');
  } else {
    const tipo = EXCLUSIVIDADE_TIPO_LABEL[regras.exclusividade_tipo] || 'não classificada';
    partes.push(`Este contrato concede exclusividade comercial do tipo ${tipo}.`);
    if (regras.area_exclusividade) partes.push(`Área de exclusividade: ${regras.area_exclusividade}.`);
    if (regras.exclusividade_capacidade_max) partes.push(`Limite de capacidade coberto pela exclusividade: ${fmtInt(regras.exclusividade_capacidade_max)} clientes.`);
    if (regras.exclusividade_prazo_meses) partes.push(`Prazo da exclusividade: ${fmtInt(regras.exclusividade_prazo_meses)} meses (pode divergir do prazo contratual — conferir antes da assinatura).`);
    partes.push(regras.permite_outros_parceiros === false
      ? 'A NICK se obriga a não contratar outros parceiros no escopo da exclusividade acima.'
      : 'Ainda que exclusiva neste escopo, a NICK preserva o direito de contratar outros parceiros fora do escopo definido acima.');
  }
  partes.push(regras.direito_proprietario_explorar_capacidade_remanescente !== false
    ? 'A NICK preserva o direito explícito de explorar comercialmente a capacidade de infraestrutura remanescente (fibras/portas não contratadas por este parceiro), inclusive dentro da área/cidade deste contrato, ressalvado apenas o escopo específico de exclusividade acima (se houver).'
    : 'Este contrato restringe o direito da NICK de explorar a capacidade remanescente — condição não padrão, exige atenção do jurídico.');
  partes.push(regras.direito_preferencia
    ? 'O parceiro tem direito de preferência para contratar capacidade adicional antes de ela ser oferecida a terceiros, nos termos a definir pelo jurídico.'
    : 'Este contrato não concede direito de preferência ao parceiro sobre capacidade adicional.');
  return partes.join(' ');
}

const REGRA_SOLICITACAO_TIPO_LABEL = { FIBRA_TERCEIROS: 'uso de fibra de terceiros', REDE_PROPRIA: 'construção de rede própria pelo parceiro' };
const REGRA_SOLICITACAO_STATUS_LABEL = {
  AGUARDANDO_ENGENHARIA: 'em tramitação (aguardando parecer de Engenharia)',
  AGUARDANDO_COMERCIAL: 'em tramitação (aguardando parecer Comercial)',
  AGUARDANDO_DIRETORIA: 'em tramitação (aguardando decisão da Diretoria)',
  APROVADA: 'APROVADA — exceção concedida e em vigor',
  REJEITADA: 'REJEITADA',
};

// Fase 3.8 (item 3.8-13): a cláusula descrevia só o guardrail booleano
// (contrato_regras.proibe_*) sem citar o workflow formal de 3 etapas
// (Engenharia→Comercial→Diretoria) implementado nos itens 3.8-09/3.8-10 desta mesma
// fase — porque app.contrato_documento_dados() nunca expunha contrato_regras_solicitacoes
// (corrigido na migration 20260929104500). Agora a cláusula (a) explica que qualquer
// exceção só é válida se percorrer as 3 etapas formais e (b) lista, uma a uma, as
// solicitações já registradas para este contrato — nunca inventa nenhuma se não houver.
function buildFibraTerceirosRedePropriaTexto(regras, solicitacoes) {
  if (!regras) return 'Guardrails não registrados para este contrato — confirmar manualmente antes da assinatura.';
  const fibraTerceiros = regras.proibe_fibra_terceiros !== false
    ? 'O parceiro está PROIBIDO de utilizar fibra óptica de terceiros para prestar o serviço objeto deste contrato, salvo exceção formalmente concedida nos termos do workflow de aprovação descrito abaixo.'
    : 'O parceiro está autorizado a utilizar fibra óptica de terceiros — condição não padrão, exige atenção do jurídico.';
  const redePropria = regras.proibe_rede_propria !== false
    ? 'O parceiro está PROIBIDO de construir rede própria concorrente na área deste contrato, salvo exceção formalmente concedida nos termos do workflow de aprovação descrito abaixo.'
    : 'O parceiro está autorizado a construir rede própria na área do contrato — condição não padrão, exige atenção do jurídico.';
  const expansao = regras.exige_aprovacao_expansao !== false
    ? 'Qualquer expansão de capacidade contratada (novas portas PON, novos POPs, aumento de área) exige aprovação prévia e formal da NICK, registrada em aditivo contratual — nunca automática.'
    : 'Expansões de capacidade não exigem aprovação prévia formal neste contrato — condição não padrão.';

  const workflow = 'Qualquer exceção às duas proibições acima só é válida se percorrer, nesta ordem, as 3 etapas formais de aprovação da NICK: (1) parecer técnico de Engenharia; (2) parecer Comercial; (3) decisão final da Diretoria — qualquer etapa pode rejeitar diretamente, sem necessidade de percorrer as etapas seguintes, e a decisão é registrada de forma imutável no sistema. Uma exceção só entra em vigor automaticamente no momento em que a Diretoria a aprova; antes disso, a proibição permanece integralmente em vigor.';

  // Fase 3.9 (seções 5-6): o workflow de 3 etapas já existia (Fase 3.8), mas o texto não
  // listava os fundamentos válidos para uma exceção ser solicitada/aprovada — o prompt do
  // usuário pede uma lista enumerada e não-genérica dos motivos aceitáveis, para orientar
  // Engenharia/Comercial/Diretoria na avaliação de cada solicitação. Isto é texto
  // explicativo do critério de julgamento — a autorização real de cada solicitação
  // individual continua 100% do workflow em contrato_regras_solicitacoes, nunca decidida
  // por esta lista sozinha.
  const fundamentos = 'São hipóteses típicas que podem fundamentar uma solicitação de exceção (a avaliação final é sempre discricionária de Engenharia/Comercial/Diretoria, conforme a etapa, e esta lista não é exaustiva nem gera aprovação automática): indisponibilidade técnica comprovada da infraestrutura da NICK na área/rota necessária; falta de capacidade disponível (fibra ou porta PON) da NICK na área/rota necessária; indisponibilidade temporária da infraestrutura da NICK (ex.: obra, manutenção prolongada); inviabilidade econômica comprovada de atendimento via infraestrutura da NICK; determinação regulatória (Anatel ou outro órgão competente); situação de contingência ou emergência operacional; expansão para área ainda não coberta pela infraestrutura da NICK; ou autorização expressa da Diretoria da NICK, independentemente de outro fundamento específico.';

  let historico;
  if (!solicitacoes || solicitacoes.length === 0) {
    historico = 'Nenhuma solicitação de exceção foi registrada para este contrato até o momento da geração desta minuta.';
  } else {
    const linhas = solicitacoes.map((s) => {
      const tipoLabel = REGRA_SOLICITACAO_TIPO_LABEL[s.tipo] || s.tipo;
      const statusLabel = REGRA_SOLICITACAO_STATUS_LABEL[s.status] || s.status;
      let detalhe = `Solicitação de ${tipoLabel} (${fmtDate(s.criado_em)}): ${statusLabel}.`;
      if (s.status === 'REJEITADA' && s.motivo_rejeicao) detalhe += ` Motivo da rejeição (etapa ${s.etapa_rejeicao || '—'}): ${s.motivo_rejeicao}.`;
      if (s.status === 'APROVADA') detalhe += ' A proibição correspondente está SUSPENSA para este contrato em razão desta aprovação.';
      return detalhe;
    });
    historico = `Solicitações registradas: ${linhas.join(' ')}`;
  }

  return `${fibraTerceiros} ${redePropria} ${expansao} ${workflow} ${fundamentos} ${historico}`;
}

const TIPO_CLIENTE_RESERVADO_LABEL = {
  PREFEITURA: 'Prefeitura (ente municipal)',
  ORGAO_PUBLICO: 'órgão público (estadual/federal/autarquia)',
  OUTRO: 'reserva comercial',
};

// Fase 3.8 (item 3.8-08): estrutura formal de clientes reservados + regra Prefeitura.
// Antes desta correção toda reserva (Prefeitura, órgão público ou reserva comercial
// comum) recebia o mesmo texto genérico — a seção só mencionava "Prefeitura" no título,
// sem nenhuma cláusula jurídica própria para esse caso. Agora PREFEITURA/ORGAO_PUBLICO
// têm um parágrafo formal dedicado (fundamento distinto: interesse público / contrato
// administrativo preexistente, não decisão comercial da NICK) e reservas OUTRO mantêm o
// texto comercial genérico — sempre a partir de dados reais de contrato_clientes_reservados,
// nunca um texto padrão inventado quando o tipo/motivo/documento não está preenchido.
function buildClientesReservadosTexto(clientes) {
  if (!clientes || clientes.length === 0) {
    return 'Nenhum cliente reservado registrado para este contrato. Não há, portanto, exceção de atendimento (incluindo eventual exceção Prefeitura ou outro órgão público) registrada nesta minuta — se houver acordo verbal nesse sentido, ele deve ser formalizado aqui antes da assinatura.';
  }

  const publicos = clientes.filter((c) => c.tipo === 'PREFEITURA' || c.tipo === 'ORGAO_PUBLICO');
  const comerciais = clientes.filter((c) => !c.tipo || c.tipo === 'OUTRO');
  const partes = [];

  if (publicos.length > 0) {
    const linhasPublicas = publicos.map((c) => {
      const tipoLabel = TIPO_CLIENTE_RESERVADO_LABEL[c.tipo] || c.tipo;
      const doc = c.documento_referencia ? `, formalizada em ${c.documento_referencia}` : ' — sem documento de referência registrado ainda; deve ser formalizado antes da assinatura';
      const motivo = c.motivo ? `; motivo: ${c.motivo}` : '';
      return `${c.cliente_nome} (${tipoLabel}${c.cnpj_cpf ? `, CNPJ ${c.cnpj_cpf}` : ''})${doc}${motivo} — status: ${c.status === 'RESERVADO' ? 'reservado' : 'liberado'}`;
    });
    partes.push(`CLÁUSULA DE ENTES PÚBLICOS (regra Prefeitura): os seguintes entes públicos são reservados e permanecem FORA do escopo comercial deste contrato, sob atendimento e responsabilidade direta da NICK — o parceiro está expressamente proibido de vender, prospectar, atender ou migrar qualquer um deles, mesmo estando fisicamente dentro da área de cobertura deste contrato, salvo autorização expressa e por escrito da NICK: ${linhasPublicas.join('; ')}. Esta reserva decorre de interesse público e/ou contrato administrativo preexistente da NICK com o ente público — não é uma decisão comercial discricionária e não se sujeita a negociação unilateral do parceiro.`);
  }

  if (comerciais.length > 0) {
    const linhasComerciais = comerciais.map((c) => `${c.cliente_nome}${c.motivo ? ` (motivo: ${c.motivo})` : ''} — status: ${c.status === 'RESERVADO' ? 'reservado (fora do escopo deste contrato)' : 'liberado'}`);
    partes.push(`Adicionalmente, os seguintes clientes/entidades são reservados por decisão comercial da NICK — ficam FORA do escopo de atendimento deste contrato, permanecendo sob responsabilidade direta da NICK ou de tratamento à parte: ${linhasComerciais.join('; ')}.`);
  }

  // Fase 3.9 (seção 7): obrigação de notificação prévia para o caso de o parceiro ser
  // espontaneamente procurado por um cliente/ente que se enquadraria como reservado mas
  // ainda não está formalmente registrado como tal — evita a lacuna de o parceiro alegar
  // desconhecimento por o registro formal ainda não existir no momento do contato.
  partes.push('O parceiro se obriga a notificar previamente a NICK, antes de apresentar qualquer proposta comercial, sempre que for espontaneamente procurado por uma Prefeitura Municipal, órgão público, ou qualquer outro cliente/entidade que possa se enquadrar nos critérios de reserva desta cláusula — inclusive quando ainda não constar formalmente da lista acima —, para que a NICK avalie e, se for o caso, formalize a reserva antes de qualquer negociação prosseguir.');

  return partes.join(' ');
}

// Fase 3.10 (Problema 1): antigo helper que gerava um placeholder puro
// "[CLÁUSULA-MODELO — AGUARDANDO REDAÇÃO DO JURÍDICO DA NICK]" para cláusulas sem fonte
// de dado estruturada. Removido nesta fase — o prompt do usuário exige que TODA cláusula
// do checklist mínimo tenha redação profissional completa (uma "cláusula-base"), mesmo
// quando o parâmetro específico (prazo, percentual, foro) depende de decisão do jurídico;
// nesses casos, a cláusula agora tem texto substantivo completo e só marca internamente,
// com o sufixo abaixo, que aquele parâmetro específico está sujeito a validação jurídica
// — nunca mais uma cláusula vazia. Mantido como string reutilizável para consistência.
const SUJEITO_A_VALIDACAO_JURIDICA = ' Esta cláusula é uma minuta-base para orientar a redação definitiva — os parâmetros específicos indicados estão sujeitos a validação e ajuste final pelo jurídico da NICK antes de qualquer assinatura.';

function buildContractDocumentModel(dados) {
  const {
    contrato, parceiro, cidade, pricing_config: pc, regras, clientes_reservados: clientes, ativos,
    fibras_count, pons_count, aditivos, reajustes, regras_solicitacoes: solicitacoes,
    rescisao_config: rescisao, ativos_devolucao: devolucoes, clientes_ativos_contrato: clientesAtivos,
    infraestrutura_detalhe: infraDetalhe, rampa,
  } = dados;

  const sections = [];
  let n = 0;
  const push = (titulo, texto) => sections.push({ n: ++n, titulo, texto });
  const pushTabela = (titulo, linhas) => sections.push({ n: ++n, titulo, tipo: 'tabela', linhas });

  // 1. Capa (tratada à parte pelo renderer, número reservado)
  sections.push({ n: 0, titulo: 'Capa', tipo: 'capa' });

  // Fase 3.8 (item 3.8-13) + Fase 3.9 (revisão completa das cláusulas — modelo de cessão
  // onerosa de infraestrutura óptica) + Fase 3.10 (Problema 1 — eliminação de TODOS os
  // placeholders "[CLÁUSULA-MODELO — AGUARDANDO REDAÇÃO...]" e 3 cláusulas novas:
  // Implantação e Ativação, Responsabilidade por Danos, Capacidade Remanescente e Direito
  // de Cessão a Terceiros pela NICK): 52 cláusulas fixas (sempre presentes,
  // independentemente dos dados do contrato — verificado por push() direto no código,
  // nunca um número presumido) + até 6 tabelas condicionais que só aparecem quando o
  // contrato tem o dado correspondente (Detalhamento da Infraestrutura Cedida, Relação de
  // Ativos Vinculados, Rampa de Maturação Aplicável, Histórico de Reajustes Aplicados,
  // Registros de Devolução de Ativos, Aditivos Registrados) — nunca um número de seções
  // fixo e único, porque o conteúdo depende dos dados reais de cada contrato. Glossário dos termos
  // usados de forma consistente no resto desta minuta (Rede, Fibra, Porta PON, POP,
  // Take-or-Pay, Revenue Share, Aditivo). Não é cláusula-modelo à espera do jurídico: é
  // vocabulário do próprio sistema, sempre igual, nunca dependente de dado de contrato.
  push('Definições', 'Para os fins desta minuta, aplicam-se as seguintes definições: "Rede" ou "Infraestrutura" designa o conjunto de fibras ópticas, cabos, postes e equipamentos passivos de propriedade da NICK. "Fibra" designa um par óptico individual identificado no sistema de gestão de infraestrutura da NICK. "Porta PON" designa o ponto de acesso ativo (OLT) ao qual uma ou mais fibras/clientes finais se conectam, com capacidade máxima de assinantes definida tecnicamente. "POP" (Ponto de Presença) designa a instalação física da NICK onde fibras e portas PON estão concentradas. "Take-or-Pay" designa o valor mínimo mensal garantido devido pelo parceiro à NICK, independentemente do faturamento apurado. "Revenue Share" designa o percentual do faturamento do parceiro apurado e devido à NICK, sempre somado ao Take-or-Pay (nunca em substituição). "Aditivo" designa o instrumento formal de alteração desta minuta, único meio válido de modificação de seus termos.');

  // Fase 3.10 (seção 4 do prompt — "dados do parceiro: razão social, CNPJ, endereço..."):
  // parceiros já tem endereço ESTRUTURADO desde a Fase 2.5 (endereco_logradouro/numero/
  // complemento/bairro/cidade/uf/cep — confirmado por leitura direta de
  // api/routes/partners.js antes de criar qualquer coluna nova). Monta uma linha de
  // endereço só com os campos realmente preenchidos — nunca fabrica um endereço quando
  // o cadastro está incompleto ou totalmente vazio.
  const enderecoPartes = [
    parceiro.endereco_logradouro && `${parceiro.endereco_logradouro}${parceiro.endereco_numero ? `, ${parceiro.endereco_numero}` : ''}${parceiro.endereco_complemento ? ` (${parceiro.endereco_complemento})` : ''}`,
    parceiro.endereco_bairro,
    parceiro.endereco_cidade && parceiro.endereco_uf ? `${parceiro.endereco_cidade}/${parceiro.endereco_uf}` : (parceiro.endereco_cidade || parceiro.endereco_uf),
    parceiro.endereco_cep && `CEP ${parceiro.endereco_cep}`,
  ].filter(Boolean);
  const enderecoTexto = enderecoPartes.length > 0
    ? `, com endereço em ${enderecoPartes.join(', ')}`
    : ' (endereço não informado no cadastro do parceiro — deve ser confirmado antes da assinatura)';

  push('Objeto', `O presente instrumento tem por objeto a cessão onerosa, pela NICK, de infraestrutura de rede óptica (fibras, portas PON e/ou capacidade associada) ao parceiro ${parceiro.razao_social}${parceiro.nome_fantasia ? ` ("${parceiro.nome_fantasia}")` : ''}, CNPJ ${parceiro.cnpj || '—'}${enderecoTexto}, na cidade de ${cidade.nome}/${cidade.uf}, para exploração comercial de serviços de telecomunicações pelo parceiro junto a seus próprios clientes finais, nos termos e condições estabelecidos nesta minuta.`);

  // Fase 3.9 (seção 1 do modelo de cessão): a natureza jurídica do negócio precisa ser
  // afirmada de forma explícita e nunca ambígua — o prompt do usuário proíbe
  // expressamente o uso do termo "rede neutra" para caracterizar este contrato (que tem
  // uma conotação regulatória distinta: compartilhamento de infraestrutura passiva entre
  // múltiplos operadores em condições isonômicas). O que a NICK pratica é cessão onerosa
  // e não-exclusiva (por padrão) de direito de uso sobre ativos específicos e
  // identificados (fibra apagada e/ou porta PON) a UM parceiro determinado, mediante
  // contraprestação financeira — nunca a exploração compartilhada e simultânea do mesmo
  // recurso por múltiplos operadores em pé de igualdade.
  push('Natureza Jurídica da Cessão', `O presente instrumento caracteriza-se como CESSÃO ONEROSA DE DIREITO DE USO DE INFRAESTRUTURA ÓPTICA / PORTAS PON / RECURSOS DE REDE, mediante contraprestação financeira nos termos das cláusulas de Pagamento, Take-or-Pay e Revenue Share. Esta cessão NÃO caracteriza, em nenhuma hipótese, "rede neutra" (compartilhamento simultâneo e isonômico da mesma infraestrutura entre múltiplos operadores) — trata-se de cessão de uso de recursos específicos e identificados (fibra apagada e/ou porta(s) PON, conforme cláusula de Infraestrutura) a um único parceiro determinado, sob as condições de exclusividade (ou não-exclusividade) expressamente definidas na cláusula de Exclusividade. A NICK permanece, em qualquer hipótese, proprietária de toda a infraestrutura física cedida (ver cláusula de Propriedade dos Ativos).`);

  push('Cessão de Rede', `A NICK cede ao parceiro o direito de uso da infraestrutura descrita na cláusula de Infraestrutura, pelo prazo e condições financeiras aqui definidos. A cessão não transfere a propriedade da infraestrutura física (fibras, cabos, postes, portas PON), que permanece integralmente da NICK — ver cláusula de Propriedade dos Ativos.`);

  // Fase 3.9 (seção 3 do modelo de cessão): antes só havia contagem agregada
  // (fibras_count/pons_count) — agora, quando app.contrato_documento_dados() retorna o
  // detalhamento por recurso (infraestrutura_detalhe: cidade/POP/rota/cabo/capacidade do
  // cabo/recurso cedido/comprimento/postes/capacidade máxima/data de início), a minuta
  // renderiza a tabela completa em vez de só o texto agregado — nunca inventando uma
  // linha para um recurso que não está de fato vinculado no sistema.
  push('Infraestrutura e Capacidade Contratada', `Este contrato está vinculado a ${fmtInt(fibras_count)} fibra(s) e ${fmtInt(pons_count)} porta(s) PON ativamente alocadas na cidade de ${cidade.nome}/${cidade.uf} — esta é, para todos os efeitos desta minuta, a capacidade efetivamente contratada pelo parceiro, nunca um volume estimado ou presumido. O detalhamento por recurso cedido (cidade, POP, rota, cabo, fibra e/ou porta PON) consta da tabela a seguir (quando disponível) e do sistema de gestão de infraestrutura da NICK, que deve ser considerado a fonte de verdade em caso de qualquer divergência. Qualquer capacidade adicional àquela aqui descrita depende de aditivo formal, nos termos da cláusula de Expansão de Rede.`);
  if (infraDetalhe && infraDetalhe.length > 0) {
    pushTabela('Detalhamento da Infraestrutura Cedida', infraDetalhe.map((r) => [
      `${r.cidade}/${r.uf}`, r.pop || '—', r.rota || '—', r.cabo || '—',
      r.cabo_capacidade_fo != null ? `${fmtInt(r.cabo_capacidade_fo)} FO` : '—',
      r.recurso_cedido, r.identificacao_recurso || '—',
      r.comprimento_km != null ? `${Number(r.comprimento_km).toLocaleString('pt-BR')} km` : '—',
      r.postes_envolvidos != null ? fmtInt(r.postes_envolvidos) : '—',
      r.capacidade_maxima != null ? `${fmtInt(r.capacidade_maxima)} assinantes` : '—',
      fmtDate(r.data_inicio),
    ]));
  }

  // Fase 3.10 (Problema 1, seção 1.2 — "Implantação/ativação"): cláusula nova, não
  // existia antes. Não há, no schema, um prazo padrão de implantação em dias — a cláusula
  // por isso descreve o MECANISMO (o que conta como "ativação" e o que ela dispara: início
  // da vigência/carência) usando o dado real já existente (contratos.data_inicio), sem
  // inventar um prazo de SLA de implantação em dias.
  push('Implantação e Ativação', `A ativação da infraestrutura cedida (fibra apagada e/ou porta PON, conforme cláusula de Infraestrutura e Capacidade Contratada) é realizada pela NICK após a assinatura desta minuta, conforme cronograma técnico a ser acordado entre as partes e a disponibilidade de recursos na cidade/POP/rota contratada. A data de ativação efetiva, registrada no sistema da NICK como início de vigência (contratos.data_inicio)${contrato.data_inicio ? `, é ${fmtDate(contrato.data_inicio)} para este contrato` : ' — ainda não registrada para este contrato, deve ser confirmada antes da assinatura'}, é o marco que dá início à contagem do Prazo Mínimo Contratual, da eventual Carência (rampa de maturação) e da obrigação de pagamento — nunca a data de assinatura desta minuta, salvo acordo expresso em contrário entre as partes.${SUJEITO_A_VALIDACAO_JURIDICA} O prazo específico (em dias) para conclusão da implantação é cláusula-base sujeita a definição pela Engenharia/jurídico da NICK.`);

  push('Nível de Serviço (SLA)', `A NICK se compromete a manter a infraestrutura passiva cedida (fibras, cabos, postes) em condições operacionais, empregando seus melhores esforços para restabelecer o serviço em caso de rompimento de fibra ou falha de porta PON dentro do menor prazo tecnicamente possível, considerando a natureza do reparo (interno ao POP ou em campo, incluindo eventual dependência de terceiros como concessionárias de energia ou proprietários de postes). Interrupções programadas para manutenção preventiva serão comunicadas ao parceiro com antecedência razoável, preferencialmente fora do horário de maior utilização. Indisponibilidades decorrentes de causas fora do controle da NICK (rompimento por terceiros, força maior — ver cláusula de Força Maior, ou causadas pelo próprio parceiro ou seus clientes finais) não geram direito a crédito ou abatimento.${SUJEITO_A_VALIDACAO_JURIDICA} Os parâmetros quantitativos de nível de serviço (percentual de disponibilidade mínima mensal garantida, tempo-alvo de resposta a incidentes por severidade, e eventual fórmula de crédito proporcional por descumprimento) não estão configurados no sistema para este contrato e são cláusula-base sujeita a definição pela Engenharia/jurídico/Diretoria da NICK antes da assinatura.`);

  push('Responsabilidades das Partes', 'A NICK é responsável por: manter a infraestrutura cedida em condições operacionais; comunicar previamente manutenções programadas; disponibilizar canal de suporte técnico. O parceiro é responsável por: atendimento aos seus clientes finais; contratação/manutenção de equipamentos ativos de sua rede (exceto ativos cedidos pela NICK, ver cláusula de Ativos); cumprimento da legislação de telecomunicações aplicável; pagamento pontual dos valores devidos nos termos desta minuta.');

  // Fase 3.9 (seção 12 do modelo de cessão): lista exaustiva e explícita de custos de
  // instalação do cliente final — 100% do parceiro, nunca da NICK, para não deixar
  // margem a interpretação de que algum item estaria incluído na cessão de infraestrutura.
  push('Responsabilidade pela Instalação do Cliente Final', 'É de responsabilidade EXCLUSIVA e integral do parceiro, sem qualquer participação financeira ou operacional da NICK, tudo o que for necessário para conectar e manter cada cliente final, incluindo mas não se limitando a: drop (cabo de acesso do cliente), instalação e manutenção de CTO (Caixa de Terminação Óptica) do lado do cliente, splitters, conectores e demais materiais de conectorização, ONU/ONT do cliente, roteador/equipamento CPE, todo e qualquer material de instalação, mão de obra própria ou terceirizada, deslocamento e visita técnica, ativação do serviço, e manutenção e suporte técnico ao cliente final. A cessão de infraestrutura objeto desta minuta (fibra apagada e/ou porta PON — ver cláusula de Infraestrutura) não inclui, em nenhuma hipótese, qualquer um destes itens.');

  // Fase 3.9 (seção 13): a cessão de infraestrutura óptica passiva/porta PON é
  // expressamente distinta do acesso à internet (trânsito IP) — evita a interpretação
  // (comum no mercado de cessão de infraestrutura) de que "porta ativada" implica
  // "internet entregue".
  push('Acesso à Internet (Link IP)', 'A cessão objeto desta minuta compreende exclusivamente o direito de uso da infraestrutura óptica passiva e/ou porta(s) PON descritas na cláusula de Infraestrutura — NÃO compreende, em nenhuma hipótese, o fornecimento de acesso à internet (trânsito IP), CDN, upstream, BGP, CGNAT ou serviços de DNS aos clientes finais do parceiro, salvo se expressamente especificado em aditivo próprio. O parceiro é integralmente responsável por contratar, operacionalizar e manter, por conta própria, toda a conectividade IP necessária para entregar o serviço de internet a seus clientes finais.');

  // Fase 3.8 (item 3.8-13): grounded — reafirma, sem inventar prazos/valores, a divisão de
  // manutenção já estabelecida na cláusula anterior, remetendo à de Auditoria para o canal
  // formal de fiscalização. Não duplica SLA (prazos/uptime), que é a cláusula anterior.
  push('Manutenção e Assistência Técnica', 'A manutenção da infraestrutura passiva cedida (fibras, cabos, postes, portas PON) é de responsabilidade exclusiva da NICK, incluindo manutenções corretivas em caso de rompimento de fibra ou falha de porta PON. A manutenção de equipamentos ativos de propriedade do parceiro (fora dos ativos cedidos listados na cláusula de Ativos e Equipamentos) é de responsabilidade exclusiva do parceiro. Eventuais equipamentos cedidos pela NICK (OLT/ONU/ONT/fonte/switch) têm sua manutenção/substituição tratada conforme a cláusula de Devolução de Ativos e o registro formal de ativos do sistema da NICK.');

  // Fase 3.8 (item 3.8-02, refletido aqui no item 3.8-07 — a minuta ainda descrevia o
  // modelo antigo em texto livre mesmo depois da correção do motor de cálculo): a regra
  // oficial e obrigatória da NICK é SOMA — mínimo mensal garantido MAIS revenue share,
  // sempre somados. NUNCA "o maior entre os dois" (MAX) — essa opção foi removida do
  // sistema inteiro (ver migration 20260929090000). Se algum contrato legado ainda
  // trouxer modelo_cobranca diferente de SOMA (não deveria acontecer — a migration já
  // corrigiu todos os registros existentes), a minuta sinaliza isso explicitamente para
  // revisão jurídica em vez de descrever silenciosamente uma regra que pode estar errada.
  const modeloCobrancaInconsistente = pc?.modelo_cobranca && pc.modelo_cobranca !== 'SOMA';
  push('Pagamento', modeloCobrancaInconsistente
    ? `ATENÇÃO — INCONSISTÊNCIA A REVISAR: este contrato está configurado com modelo_cobranca = "${pc.modelo_cobranca}" na base de dados, diferente do modelo oficial obrigatório da NICK (SOMA). Isto não deveria ocorrer e precisa ser corrigido em contrato_pricing_config antes da assinatura. A regra oficial é: o parceiro paga à NICK mensalmente a SOMA entre a mensalidade mínima garantida (Take-or-Pay) e o revenue share apurado no mês — os dois valores são sempre somados integralmente, nunca comparados para cobrança do maior entre eles.`
    : 'O parceiro pagará à NICK mensalmente a SOMA entre a mensalidade mínima garantida (Take-or-Pay) e o valor de revenue share apurado no mês sobre o faturamento do parceiro (ver cláusulas de Take-or-Pay e Revenue Share) — os dois valores são sempre somados integralmente; a NICK nunca cobra apenas o maior entre eles, com vencimento e forma de cobrança a serem definidos pelo jurídico/financeiro da NICK nesta minuta antes da assinatura.');

  push('Take-or-Pay (Mínimo Contratual)', pc?.mensalidade_minima_porta != null
    ? `Fica estabelecido um valor mínimo mensal garantido (Take-or-Pay) de ${fmtBRL(pc.mensalidade_minima_porta)}, devido pelo parceiro à NICK independentemente do faturamento efetivamente apurado no período, ressalvado o período de carência aplicável (ver cláusula de Carência) e a rampa de maturação contratual. Este valor é somado ao revenue share apurado no mês (ver cláusula de Revenue Share) — nunca substituído por ele.`
    : 'Valor mínimo mensal garantido (Take-or-Pay) não está configurado em contrato_pricing_config para este contrato — deve ser confirmado antes da assinatura.');

  push('Revenue Share', pc?.percentual_revenue_share != null
    ? `Adicionalmente ao mínimo mensal garantido (Take-or-Pay) — e sempre SOMADO a ele, nunca em substituição —, será apurado revenue share de ${fmtPct(pc.percentual_revenue_share)} sobre a base de cálculo "${pc.base_calculo_revenue_share || '—'}", incidente sobre a totalidade do faturamento apurado no período, independentemente de esse valor superar ou não o mínimo mensal garantido.`
    : 'Percentual de revenue share não está configurado para este contrato — deve ser confirmado antes da assinatura.');

  // Fase 3.9 (seção 21): Take-or-Pay em QUANTIDADE de clientes — distinto e adicional ao
  // Take-or-Pay monetário (cláusula anterior). take_or_pay_clientes vem de
  // contrato_pricing_config (migration 20260930090000); clientes_ativos_contrato é a
  // contagem real agregada de app.contrato_documento_dados() (soma de
  // infra_portas_pon.capacidade_utilizada_assinantes das portas vinculadas a este
  // contrato) — nunca um número estimado ou hardcoded.
  push('Take-or-Pay em Quantidade de Clientes', pc?.take_or_pay_clientes != null
    ? `Independentemente do Take-or-Pay monetário (cláusula anterior), fica estabelecido um compromisso mínimo de ${fmtInt(pc.take_or_pay_clientes)} cliente(s) ativo(s) conectados através da infraestrutura cedida por este contrato. Na data de geração desta minuta, o sistema da NICK registra ${fmtInt(clientesAtivos)} cliente(s) ativo(s) vinculado(s) a este contrato${Number(clientesAtivos || 0) < Number(pc.take_or_pay_clientes) ? ` — HÁ DÉFICIT de ${fmtInt(Number(pc.take_or_pay_clientes) - Number(clientesAtivos || 0))} cliente(s) em relação ao compromisso mínimo, a ser tratado conforme regras comerciais/jurídicas aplicáveis` : ', atingindo ou superando o compromisso mínimo estabelecido'}. Este compromisso é independente e não substitui o Take-or-Pay monetário da cláusula anterior.`
    : `Este contrato não possui compromisso mínimo de quantidade de clientes (Take-or-Pay em clientes) configurado em contrato_pricing_config — aplica-se somente o Take-or-Pay monetário da cláusula anterior. Na data de geração desta minuta, o sistema da NICK registra ${fmtInt(clientesAtivos)} cliente(s) ativo(s) vinculado(s) a este contrato, para referência.`);

  push('Reajuste Anual', `Os valores desta minuta serão reajustados anualmente pelo índice ${pc?.indice_reajuste || 'a definir'}, aplicado sobre a competência de referência, conforme histórico de reajustes já aplicados a este contrato (ver tabela). Reajustes futuros seguem o motor de precificação da NICK (app.aplicar_reajuste_contrato) e nunca são aplicados retroativamente.`);
  if (reajustes && reajustes.length > 0) {
    pushTabela('Histórico de Reajustes Aplicados', reajustes.map((r) => [fmtDate(r.competencia_base), fmtPct(r.percentual_aplicado), r.status]));
  }

  // Fase 3.8 (item 3.8-13): grounded — data de término calculada a partir de dados reais
  // (data_inicio + prazo_meses), nunca um valor fixo. A regra "renovação nunca automática,
  // sempre por aditivo" é consistente com a cláusula de Aditivos Contratuais já existente
  // (não é cláusula-modelo: é a mesma regra do sistema, aqui aplicada à vigência).
  const dataFimPrevista = contrato.data_inicio && contrato.prazo_meses
    ? (() => { const d = new Date(contrato.data_inicio); d.setMonth(d.getMonth() + Number(contrato.prazo_meses)); return d; })()
    : null;
  push('Vigência e Renovação', contrato.data_inicio
    ? `Este contrato vigora a partir de ${fmtDate(contrato.data_inicio)}, pelo prazo estabelecido na cláusula de Prazo Mínimo Contratual, com término previsto em ${dataFimPrevista ? fmtDate(dataFimPrevista) : '—'}. Não há renovação automática: a continuidade da relação após o término da vigência depende de novo contrato ou de aditivo formal de prorrogação, celebrado antes do vencimento — nunca presumida pelo mero decurso do prazo ou pela continuidade de fato da prestação do serviço.`
    : 'Data de início deste contrato não está registrada no sistema — deve ser confirmada antes da assinatura. Não há renovação automática: qualquer prorrogação exige aditivo formal celebrado antes do vencimento.');

  // Fase 3.9 (seção 17): antes só descrevia o mecanismo em texto genérico ("conferir no
  // sistema") sem os valores reais. app.contrato_documento_dados() agora retorna a régua
  // efetivamente aplicável a este contrato (específica do contrato, com fallback
  // automático para a régua padrão global via app.get_fator_rampa quando não houver régua
  // própria) — a minuta renderiza os valores reais, nunca um percentual hardcoded.
  const RAMPA_COMPONENTE_LABEL = { FIXO_MINIMO: 'Take-or-Pay (mínimo mensal)', REVENUE_SHARE: 'Revenue Share', AMBOS: 'Take-or-Pay e Revenue Share' };
  const rampaTexto = rampa && rampa.length > 0
    ? `Fica estabelecido período de carência (rampa de maturação) durante o qual os valores devidos são reduzidos progressivamente conforme os degraus abaixo, aplicados pelo motor de precificação da NICK (app.get_fator_rampa), até atingir 100% do valor integral. A régua abaixo é a efetivamente vigente para este contrato (específica, quando cadastrada, ou a régua padrão global da NICK).`
    : 'Fica estabelecido período de carência (rampa de maturação) durante o qual o valor mínimo mensal garantido é reduzido conforme tabela de rampa vigente no sistema da NICK (app.get_fator_rampa), até atingir 100% do valor integral. Nenhuma régua de rampa foi encontrada no sistema (nem específica deste contrato, nem padrão global) — deve ser confirmado antes da assinatura.';
  push('Carência', rampaTexto);
  if (rampa && rampa.length > 0) {
    pushTabela('Rampa de Maturação Aplicável', rampa.map((r) => [
      r.month_end != null ? `Meses ${fmtInt(r.month_start)}–${fmtInt(r.month_end)}` : `Mês ${fmtInt(r.month_start)} em diante`,
      fmtPct(r.percentage, 0),
      RAMPA_COMPONENTE_LABEL[r.component] || r.component,
    ]));
  }

  push('Prazo Mínimo Contratual (48 meses)', contrato.prazo_minimo_excecao
    ? `Este contrato tem prazo de ${fmtInt(contrato.prazo_meses)} meses, ABAIXO do mínimo contratual padrão de 48 meses, com exceção formalmente registrada (motivo: ${contrato.motivo_excecao_prazo || '—'}). Esta exceção deve ser revisada pelo jurídico antes da assinatura.`
    : `O prazo deste contrato é de ${fmtInt(contrato.prazo_meses)} meses, respeitando o prazo mínimo contratual da NICK de 48 (quarenta e oito) meses. Este prazo é contratual e vinculante — nunca deve ser confundido com os horizontes analíticos (12/36/48/60 meses) usados apenas para fins de simulação financeira, que não representam o prazo real do contrato.`);

  push('Força Maior', `As partes não responderão pelo descumprimento ou atraso no cumprimento de qualquer obrigação prevista nesta minuta quando decorrente de caso fortuito ou força maior, assim entendidos os eventos alheios à vontade e ao controle razoável da parte afetada, imprevisíveis ou, se previsíveis, de efeitos inevitáveis — incluindo, exemplificativamente, desastres naturais, atos de autoridade pública, greves gerais, guerra, comoção civil, epidemias/pandemias, interrupção de fornecimento de energia elétrica por terceiros, e rompimento de infraestrutura de terceiros fora do controle da NICK. A parte impedida de cumprir sua obrigação por força maior deve notificar a outra parte por escrito, informando a natureza do evento e a previsão de duração, e deve empregar seus melhores esforços para mitigar os efeitos e retomar o cumprimento normal assim que cessada a causa. Persistindo o evento por prazo prolongado, qualquer das partes poderá rescindir este contrato mediante notificação escrita, sem aplicação de multa rescisória.${SUJEITO_A_VALIDACAO_JURIDICA} O prazo exato de notificação (dias úteis) e o prazo de tolerância que autoriza a rescisão sem multa são parâmetros de cláusula-base sujeitos a definição pelo jurídico da NICK.`);

  push('Inadimplência', `Considera-se em mora o parceiro que não efetuar o pagamento de qualquer valor devido nos termos das cláusulas de Pagamento, Take-or-Pay e Revenue Share até a respectiva data de vencimento. Verificada a mora, incidirão sobre o valor em atraso, independentemente de notificação prévia: (i) juros de mora; (ii) multa moratória; e (iii) atualização monetária pelo mesmo índice aplicável ao reajuste anual desta minuta (ver cláusula de Reajuste Anual) — sem prejuízo da cobrança integral da dívida por via judicial ou extrajudicial e da eventual aplicação da cláusula de Rescisão. Persistindo o inadimplemento por prazo prolongado contado do vencimento, a NICK poderá, mediante notificação prévia, suspender a prestação do serviço objeto desta minuta (fibra/porta PON) até a regularização integral do débito, sem prejuízo do direito de rescindir o contrato nos termos da cláusula de Rescisão.${SUJEITO_A_VALIDACAO_JURIDICA} Os percentuais de juros/multa moratória e os prazos de notificação e de suspensão do serviço são cláusula-base sujeita a definição pelo jurídico/financeiro da NICK — nenhum percentual foi configurado no sistema para este contrato.`);

  push('Rescisão', `Este contrato poderá ser rescindido: (a) por acordo escrito entre as partes; (b) por qualquer das partes, mediante notificação prévia por escrito, respeitado o Prazo Mínimo Contratual e, se aplicável, a Multa por Rescisão Antecipada; (c) de pleno direito, por qualquer das partes, em caso de descumprimento de obrigação essencial pela outra parte não sanado após notificação escrita específica concedendo prazo para regularização; (d) de pleno direito, em caso de inadimplemento não regularizado nos termos da cláusula de Inadimplência; (e) por qualquer das partes, em caso de falência, recuperação judicial/extrajudicial, dissolução ou insolvência da outra parte; e (f) pela NICK, em caso de descumprimento das cláusulas de Exclusividade, Rede Própria do Parceiro e Fibras de Terceiros, Clientes Reservados, ou Sublocação e Cessão de Uso a Terceiros, hipótese em que a rescisão poderá ocorrer de pleno direito, dada a natureza essencial dessas obrigações para o modelo de negócio da NICK. Rescindido o contrato por qualquer motivo, aplicam-se as cláusulas de Devolução de Ativos e, quando cabível, de Multa por Rescisão Antecipada, sem prejuízo da apuração de valores em aberto nos termos da cláusula de Inadimplência.${SUJEITO_A_VALIDACAO_JURIDICA} Os prazos exatos de notificação prévia e de cura de inadimplemento não-financeiro são cláusula-base sujeita a definição pelo jurídico da NICK.`);

  push('Penalidades', `Sem prejuízo dos encargos moratórios previstos na cláusula de Inadimplência e da eventual Multa por Rescisão Antecipada, o descumprimento de qualquer obrigação não-financeira prevista nesta minuta — incluindo, exemplificativamente, as cláusulas de Exclusividade, Rede Própria do Parceiro e Fibras de Terceiros, Clientes Reservados, Sublocação e Cessão de Uso a Terceiros, Confidencialidade e Proteção de Dados (LGPD) — sujeitará a parte infratora a notificação formal da outra parte com prazo para regularização e, não sanada a infração no prazo concedido, ao pagamento de multa proporcional à gravidade e eventual reincidência da infração, sem prejuízo da apuração de perdas e danos efetivamente comprovados (ver cláusula de Responsabilidade por Danos) e do direito de rescisão nos termos da cláusula de Rescisão, quando cabível.${SUJEITO_A_VALIDACAO_JURIDICA} Os critérios e valores específicos de multa por descumprimento não-financeiro são cláusula-base sujeita a definição pelo jurídico da NICK.`);

  // Fase 3.9 (seção 22): antes um placeholder puro. Agora, quando o jurídico já
  // configurou contrato_rescisao_config (migration 20260930090000), a minuta renderiza os
  // parâmetros reais com a moldura "SUGESTÃO PARA ANÁLISE JURÍDICA" (nunca um valor
  // definitivo apresentado como se fosse cláusula pronta); quando ainda não configurado,
  // mantém o placeholder explícito — em nenhum caso um percentual é inventado ou
  // hardcoded no código.
  const TIPO_MULTA_LABEL = { PERCENTUAL_SALDO_MINIMO: 'percentual sobre o saldo mínimo vincendo', VALOR_FIXO: 'valor fixo', FORMULA_JURIDICO: 'fórmula própria (ver observações)' };
  push('Multa por Rescisão Antecipada', rescisao && (rescisao.tipo_multa || rescisao.percentual_multa != null)
    ? `SUGESTÃO PARA ANÁLISE JURÍDICA (parâmetros registrados pela Diretoria/Jurídico da NICK no sistema, sujeitos a revisão e redação final do jurídico antes da assinatura): critério de cálculo — ${TIPO_MULTA_LABEL[rescisao.tipo_multa] || rescisao.tipo_multa || 'não especificado'}${rescisao.percentual_multa != null ? `; percentual — ${fmtPct(rescisao.percentual_multa, 2)}` : ''}${rescisao.base_calculo ? `; base de cálculo — ${rescisao.base_calculo}` : ''}${rescisao.limite_multa != null ? `; teto — ${fmtBRL(rescisao.limite_multa)}` : ''}${rescisao.aviso_previo_dias != null ? `; aviso prévio mínimo — ${fmtInt(rescisao.aviso_previo_dias)} dias` : ''}${rescisao.observacoes ? `. Observações do jurídico: ${rescisao.observacoes}` : ''}. Este parágrafo não é redação contratual definitiva — a redação final é de responsabilidade exclusiva do jurídico da NICK.`
    // Fase 3.10 (Problema 1): nenhum parâmetro específico foi registrado em
    // contrato_rescisao_config para este contrato ainda — em vez do antigo placeholder
    // vazio, a cláusula-base agora descreve a FÓRMULA supletiva usando dado real já
    // disponível (mensalidade mínima Take-or-Pay e a data de término prevista, calculada
    // acima em dataFimPrevista a partir de contratos.data_inicio/prazo_meses) — nenhum
    // percentual é inventado; o valor nasce do próprio saldo remanescente do contrato.
    : `Na ausência de parâmetros específicos definidos pela Diretoria/Jurídico da NICK para este contrato (ver cláusula de Devolução de Ativos e contrato_rescisao_config), aplica-se a seguinte fórmula-base supletiva: em caso de rescisão por iniciativa do parceiro antes do término do Prazo Mínimo Contratual, sem justa causa atribuível à NICK, o parceiro pagará à NICK, a título de multa rescisória, valor correspondente à soma das mensalidades mínimas garantidas (Take-or-Pay${pc?.mensalidade_minima_porta != null ? `, atualmente ${fmtBRL(pc.mensalidade_minima_porta)}/mês` : ', ver cláusula de Take-or-Pay'}) que seriam devidas entre a data de rescisão e o término do prazo mínimo contratual${dataFimPrevista ? ` (previsto para ${fmtDate(dataFimPrevista)})` : ' (a calcular a partir da data de início de vigência — ainda não registrada para este contrato)'}, podendo o jurídico da NICK aplicar redutor sobre esse valor a seu critério.${SUJEITO_A_VALIDACAO_JURIDICA} Este parágrafo é fórmula-base supletiva, sujeita a substituição pelos parâmetros específicos que vierem a ser registrados em contrato_rescisao_config.`);

  const ativosTexto = ativos && ativos.length > 0
    ? `Os seguintes ativos da NICK estão vinculados a este contrato: ${ativos.map((a) => `${a.tipo}${a.modelo ? ` ${a.modelo}` : ''}${a.patrimonio ? ` (patrimônio ${a.patrimonio})` : ''}`).join('; ')}.`
    : 'Nenhum ativo (OLT/ONU/equipamento) da NICK está registrado como vinculado a este contrato no sistema. Se houver equipamento cedido na prática, ele deve ser registrado e vinculado antes da assinatura.';
  push('Ativos e Equipamentos (OLT/ONU)', ativosTexto);
  if (ativos && ativos.length > 0) {
    // Fase 3.9 (seção 14): coluna "Proprietário" explícita. A tabela ativos não tem uma
    // coluna de proprietário própria — por definição de sistema (todo registro nesta
    // tabela É um ativo da NICK cedido em comodato/locação, nunca um ativo do parceiro,
    // ver comentário da migration 20260929100000), então o valor é sempre "NICK", nunca
    // inferido ou deixado em branco.
    pushTabela('Relação de Ativos Vinculados', ativos.map((a) => [a.tipo, a.modelo || '—', a.numero_serie || '—', a.patrimonio || '—', 'NICK', a.status]));
  }

  push('Propriedade dos Ativos', 'Todos os ativos físicos cedidos nos termos desta minuta (fibras, cabos, postes, portas PON e eventuais equipamentos OLT/ONU listados na cláusula anterior) permanecem, em qualquer hipótese, de propriedade exclusiva da NICK. A cessão de uso não constitui, em nenhuma circunstância, transferência de propriedade.');

  // Fase 3.9 (seção 15): antes só texto genérico. Agora renderiza os registros formais
  // reais de ativos_devolucao (migration 20260929100000 + exposto em
  // contrato_documento_dados na migration 20260930090000) quando existirem.
  push('Devolução de Ativos', devolucoes && devolucoes.length > 0
    ? `Encerrado o contrato por qualquer motivo, o parceiro se obriga a devolver à NICK, em condições operacionais normais, todos os ativos cedidos nos termos da cláusula de Ativos e Equipamentos, sujeitando-se a eventual apuração de perdas e danos conforme registro formal de devolução no sistema da NICK. Este contrato já possui ${fmtInt(devolucoes.length)} registro(s) de devolução (ver tabela).`
    : 'Encerrado o contrato por qualquer motivo, o parceiro se obriga a devolver à NICK, em condições operacionais normais, todos os ativos cedidos nos termos da cláusula de Ativos e Equipamentos, sujeitando-se a eventual apuração de perdas e danos conforme registro de devolução (ativos_devolucao) no sistema da NICK. Nenhum registro de devolução existe para este contrato até o momento da geração desta minuta.');
  if (devolucoes && devolucoes.length > 0) {
    pushTabela('Registros de Devolução de Ativos', devolucoes.map((d) => [
      `${d.ativo_tipo}${d.ativo_patrimonio ? ` (${d.ativo_patrimonio})` : ''}`,
      fmtDate(d.data_solicitacao), d.data_devolucao ? fmtDate(d.data_devolucao) : 'pendente',
      d.condicao || '—', d.status_final || 'em aberto',
      d.valor_perdas_danos != null ? fmtBRL(d.valor_perdas_danos) : '—',
    ]));
  }

  // Fase 3.10 (Problema 1, seção 1.2 — "Responsabilidade por danos"): cláusula nova, não
  // existia antes como cláusula própria (só mencionada implicitamente em Devolução de
  // Ativos). Texto padrão de responsabilidade civil contratual, sem depender de nenhum
  // dado específico do contrato além da referência cruzada às cláusulas de Ativos.
  push('Responsabilidade por Danos', 'Cada parte responde pelos danos diretos que causar à outra parte ou a terceiros em razão de culpa, dolo ou descumprimento de obrigação prevista nesta minuta, na forma da legislação civil aplicável. Em particular, o parceiro responde integralmente por danos causados à infraestrutura cedida pela NICK (fibras, cabos, postes, portas PON e eventuais equipamentos — ver cláusula de Ativos e Equipamentos) decorrentes de ação ou omissão do parceiro, de seus prepostos, empregados ou terceiros por ele contratados, devendo ressarcir a NICK pelo custo de reparo ou substituição, sem prejuízo da apuração formal via cláusula de Devolução de Ativos quando aplicável. Esta cláusula não exclui a aplicação, quando cabível, das cláusulas de Inadimplência, Penalidades e Seguro.');

  push('Seguro', ativos && ativos.length > 0
    ? `Havendo cessão de ativos da NICK a este contrato (${fmtInt(ativos.length)} ativo(s) registrado(s) — ver cláusula de Ativos e Equipamentos), o parceiro deve manter, durante toda a vigência contratual, cobertura de seguro compatível com esses ativos, incluindo no mínimo proteção contra incêndio, roubo/furto qualificado e danos elétricos, devendo apresentar a respectiva apólice à NICK sempre que solicitado. A ausência de apólice vigente não isenta o parceiro de sua responsabilidade integral pelos ativos cedidos nos termos da cláusula de Responsabilidade por Danos.${SUJEITO_A_VALIDACAO_JURIDICA} Os valores mínimos de cobertura e a eventual indicação da NICK como beneficiária/interessada na apólice são cláusula-base sujeita a definição pelo jurídico da NICK.`
    : `Este contrato não possui, no momento da geração desta minuta, ativos da NICK (OLT/ONU/equipamentos) vinculados — ver cláusula de Ativos e Equipamentos —, de modo que a obrigação específica de seguro sobre ativos cedidos não se aplica enquanto essa condição perdurar, sem prejuízo da responsabilidade geral do parceiro por danos à infraestrutura passiva cedida (fibra/porta PON) nos termos da cláusula de Responsabilidade por Danos. Caso ativos venham a ser cedidos a este contrato no futuro (via aditivo), esta cláusula deve ser revisitada pelo jurídico da NICK.`);

  // Fase 3.9 (seção 25): quando a NICK cede ativos (OLT/ONU), a proteção econômica da
  // NICK sobre a operação NÃO é copropriedade automática da carteira de clientes — é uma
  // das 4 opções estruturadas que o jurídico escolhe explicitamente em
  // contrato_regras.mecanismo_protecao_carteira (migration 20260930090000). NAO_DEFINIDO
  // (valor padrão) é sinalizado como pendência, nunca presumido como "sem proteção".
  const PROTECAO_CARTEIRA_LABEL = {
    OPCAO_A_DIREITO_PREFERENCIA_AQUISICAO: 'Opção A — Direito de Preferência de Aquisição da Operação: a NICK tem direito de preferência para adquirir a operação/carteira de clientes do parceiro, nas mesmas condições ofertadas por terceiros, antes de qualquer venda ou transferência.',
    OPCAO_B_DIREITO_CONTINUIDADE_OPERACAO: 'Opção B — Direito de Continuidade/Indicação de Terceiro: em caso de encerramento da operação do parceiro, a NICK tem o direito de assumir diretamente ou indicar terceiro para dar continuidade ao atendimento dos clientes finais conectados através da infraestrutura cedida.',
    OPCAO_C_COMPENSACAO_ECONOMICA: 'Opção C — Compensação Econômica: a NICK tem direito a uma compensação econômica calculada nos termos a definir pelo jurídico, em razão do valor agregado pelos ativos cedidos (OLT/ONU) à operação do parceiro.',
    OPCAO_D_DEVOLUCAO_OU_AQUISICAO_ATIVOS: 'Opção D — Devolução ou Aquisição Formal de Ativos: ao final do contrato ou na hipótese configurada pelo jurídico, o parceiro deve devolver os ativos cedidos pela NICK (ver cláusula de Devolução de Ativos) ou formalmente adquiri-los, nos termos a definir.',
  };
  push('Proteção da Carteira de Clientes (quando há ativos cedidos pela NICK)', (regras?.mecanismo_protecao_carteira && regras.mecanismo_protecao_carteira !== 'NAO_DEFINIDO')
    ? `Nos contratos em que a NICK cede ativos (OLT/ONU — ver cláusula de Ativos e Equipamentos), aplica-se o seguinte mecanismo de proteção econômica da NICK sobre a operação do parceiro, definido pelo jurídico/Diretoria da NICK para este contrato: ${PROTECAO_CARTEIRA_LABEL[regras.mecanismo_protecao_carteira] || regras.mecanismo_protecao_carteira}${regras.detalhe_protecao_carteira ? ` Detalhamento: ${regras.detalhe_protecao_carteira}` : ''} Este mecanismo NÃO constitui, em nenhuma hipótese, copropriedade automática da NICK sobre a carteira de clientes do parceiro.`
    : 'AGUARDANDO DEFINIÇÃO DO JURÍDICO/DIRETORIA — nenhum mecanismo de proteção da carteira de clientes foi configurado para este contrato (contrato_regras.mecanismo_protecao_carteira = NAO_DEFINIDO). Caso este contrato envolva cessão de ativos (OLT/ONU) pela NICK, o jurídico deve escolher, antes da assinatura, dentre as 4 opções estruturadas do sistema (direito de preferência de aquisição / direito de continuidade ou indicação de terceiro / compensação econômica / devolução ou aquisição formal de ativos) — em nenhuma hipótese a proteção da NICK se dá por copropriedade automática da carteira de clientes.');

  // Fase 3.9 (seção 20): quando o contrato tem remuneração variável (revenue share)
  // configurada, a cláusula passa a enumerar explicitamente os pontos de dado exigíveis
  // na auditoria, em vez de só afirmar o direito de auditar em abstrato — condição para o
  // relatório mensal servir de fato de base fiscalizável (API/relatório mensal, clientes
  // ativos, faturamento bruto/elegível, cancelamentos, inadimplência, upgrades/downgrades).
  push('Auditoria', pc?.percentual_revenue_share != null
    ? `A NICK se reserva o direito de auditar, a qualquer tempo e mediante aviso razoável, o uso da infraestrutura cedida e os dados que fundamentam a apuração de faturamento e revenue share deste contrato. Como este contrato possui remuneração variável (revenue share — ver cláusula de Revenue Share), o parceiro se obriga a fornecer mensalmente à NICK, por relatório e/ou integração de sistemas (ver cláusula de Integração com Sistemas do Parceiro), no mínimo: quantidade de clientes ativos vinculados à infraestrutura cedida; faturamento bruto e faturamento elegível (base de cálculo do revenue share) apurados no mês; cancelamentos ocorridos no período; situação de inadimplência dos clientes; e eventuais upgrades/downgrades de plano que afetem a base de cálculo. Todo evento relevante deste contrato é registrado de forma imutável no log de auditoria do sistema da NICK (nunca sujeito a alteração ou exclusão).`
    : 'A NICK se reserva o direito de auditar, a qualquer tempo e mediante aviso razoável, o uso da infraestrutura cedida e os dados que fundamentam a apuração de faturamento deste contrato. Todo evento relevante deste contrato é registrado de forma imutável no log de auditoria do sistema da NICK (nunca sujeito a alteração ou exclusão).');

  push('Exclusividade', buildExclusividadeTexto(regras));

  // Fase 3.10 (Problema 1, seção 1.3 do prompt): cláusula nova e explícita — a NICK
  // permanece proprietária, pode usar/explorar comercialmente a capacidade remanescente
  // (já coberto em parte por buildExclusividadeTexto, seção
  // direito_proprietario_explorar_capacidade_remanescente) e, adicionalmente, PODE no
  // futuro ceder essa capacidade remanescente a terceiros — ponto que a cláusula de
  // Exclusividade ainda não cobria. A cláusula é redigida com a salvaguarda explícita
  // exigida pelo próprio prompt: nunca uma autorização geral e irrestrita que contrarie as
  // cláusulas de Clientes Reservados/Prefeitura e de Exclusividade.
  push('Capacidade Remanescente e Direito de Cessão a Terceiros pela NICK', 'Sem prejuízo da cláusula de Exclusividade, fica desde já estabelecido que a NICK preserva a titularidade plena e o direito de uso e exploração comercial sobre toda a capacidade de infraestrutura remanescente — isto é, fibras, portas PON e demais recursos não expressamente contratados por este parceiro nos termos da cláusula de Infraestrutura e Capacidade Contratada —, ainda que localizados na mesma cidade, POP ou rota deste contrato. Este direito inclui, sem limitação: (i) contratar outros parceiros para uso da capacidade remanescente; (ii) explorar comercialmente, por si ou por terceiros, qualquer recurso não comprometido por este contrato; e (iii) no futuro, ceder a terceiros — inclusive mediante novos contratos de cessão onerosa de uso — o direito de uso sobre a infraestrutura remanescente não comprometida por este contrato. O exercício destes direitos pela NICK está sujeito, em qualquer caso, ao respeito integral à eventual exclusividade e aos clientes reservados expressamente concedidos a este parceiro nos termos das cláusulas de Exclusividade e de Clientes Reservados (inclui eventual exceção Prefeitura) — em nenhuma hipótese esta cláusula configura autorização geral e irrestrita que contrarie essas duas cláusulas. Este contrato não é exclusivo, salvo disposição expressa em contrário registrada na cláusula de Exclusividade.');

  push('Rede Própria do Parceiro e Fibras de Terceiros', buildFibraTerceirosRedePropriaTexto(regras, solicitacoes));
  push('Clientes Reservados (inclui eventual exceção Prefeitura)', buildClientesReservadosTexto(clientes));

  push('Expansão de Rede', regras?.exige_aprovacao_expansao !== false
    ? 'Qualquer expansão da infraestrutura contratada por este parceiro (novas fibras, portas PON, POPs ou área geográfica) depende de aprovação prévia e formal da NICK, sempre formalizada por aditivo contratual — nunca presumida ou automática.'
    : 'Este contrato não exige aprovação prévia formal para expansão — condição não padrão, revisar com o jurídico.');

  // Fase 3.8 (item 3.8-13): grounded — consequência direta e já implícita nas proibições
  // de fibra de terceiros/rede própria/exclusividade acima (o parceiro não pode ceder a um
  // terceiro o que ele próprio recebeu por cessão da NICK); torna essa consequência
  // explícita como cláusula própria em vez de deixá-la subentendida.
  push('Sublocação e Cessão de Uso a Terceiros', 'É vedado ao parceiro sublocar, ceder, emprestar ou de qualquer forma disponibilizar a terceiros, no todo ou em parte, o uso da infraestrutura cedida pela NICK nos termos desta minuta, ainda que a título gratuito, sem autorização prévia e expressa da NICK. Esta vedação é consequência direta das cláusulas de Exclusividade e de Rede Própria do Parceiro e Fibras de Terceiros: a cessão de uso concedida ao parceiro é pessoal e intransferível, não constituindo em nenhuma hipótese posição contratual cedível a terceiros sem anuência da NICK (ver também cláusula de Cessão da Posição Contratual).');

  push('Confidencialidade', `Cada parte se obriga a manter em sigilo, e a não divulgar a terceiros sem autorização prévia e expressa da outra parte, toda informação confidencial a que tiver acesso em razão deste contrato — incluindo, sem limitação, condições comerciais e econômicas (preço, revenue share, take-or-pay), dados de infraestrutura, informações técnicas, planos de negócio e dados de clientes finais —, usando tal informação exclusivamente para os fins da execução deste contrato. Esta obrigação persiste durante toda a vigência contratual e por prazo razoável após seu término, e não se aplica a informações que: (i) já eram publicamente conhecidas sem violação desta cláusula; (ii) já eram legitimamente detidas pela parte receptora antes da divulgação; (iii) forem desenvolvidas de forma independente sem uso da informação confidencial; ou (iv) tenham divulgação exigida por lei, regulação ou ordem de autoridade competente, hipótese em que a parte obrigada a divulgar deve notificar previamente a outra parte, quando legalmente possível.${SUJEITO_A_VALIDACAO_JURIDICA} O prazo exato de sobrevivência da obrigação após o término do contrato é cláusula-base sujeita a definição pelo jurídico da NICK.`);

  push('Proteção de Dados (LGPD)', 'As partes se obrigam a tratar quaisquer dados pessoais a que tiverem acesso em razão deste contrato — incluindo dados de clientes finais do parceiro eventualmente compartilhados com a NICK para fins de auditoria de faturamento (ver cláusula de Auditoria) — em conformidade com a Lei Federal nº 13.709/2018 (Lei Geral de Proteção de Dados Pessoais — LGPD) e demais normas aplicáveis, adotando medidas técnicas e administrativas adequadas para proteger tais dados contra acessos não autorizados e situações acidentais ou ilícitas de destruição, perda, alteração, comunicação ou difusão. Cada parte é responsável, na qualidade de controladora dos dados pessoais de seus próprios clientes e empregados, por garantir a existência de base legal adequada para o tratamento que realizar, e por atender às solicitações dos titulares de dados relativas aos seus próprios tratamentos. Em caso de incidente de segurança envolvendo dados pessoais tratados no âmbito deste contrato, a parte afetada deve comunicar a outra parte em prazo razoável, para viabilizar as medidas cabíveis, incluindo eventual comunicação à Autoridade Nacional de Proteção de Dados (ANPD) e aos titulares, quando exigível.');

  push('Propriedade Intelectual e Uso de Marca', 'Todas as marcas, nomes empresariais, logotipos e demais sinais distintivos da NICK permanecem de propriedade exclusiva da NICK, não sendo esta minuta interpretada, em nenhuma hipótese, como licença de uso de marca, cessão de propriedade intelectual, ou autorização para o parceiro se apresentar como filial, representante, franqueado ou agente da NICK perante terceiros ou clientes finais. O parceiro poderá fazer referência factual à utilização de infraestrutura da NICK em material comercial próprio (ex.: "rede parceira NICK" ou equivalente) exclusivamente mediante autorização prévia e por escrito da NICK quanto à forma e ao contexto de uso, podendo a autorização ser revogada a qualquer tempo em caso de uso que prejudique a imagem ou os interesses da NICK. Toda propriedade intelectual eventualmente desenvolvida pela NICK no âmbito da execução deste contrato (incluindo sistemas, processos e metodologias de gestão de infraestrutura) permanece de titularidade exclusiva da NICK.');

  push('Compliance, Ética e Anticorrupção', `As partes declaram conhecer, obrigam-se a cumprir e a fazer com que seus respectivos administradores, empregados, prepostos e terceiros contratados cumpram a legislação anticorrupção aplicável, em especial a Lei nº 12.846/2013 (Lei Anticorrupção) e a política de compliance da NICK, comprometendo-se a não oferecer, prometer, autorizar ou aceitar, direta ou indiretamente, qualquer vantagem indevida a agente público ou privado em razão deste contrato. Cada parte declara, ainda, que os recursos empregados na execução deste contrato têm origem lícita, e que não emprega mão de obra em condições análogas às de escravo ou mão de obra infantil, em conformidade com a legislação trabalhista aplicável. O descumprimento desta cláusula por qualquer das partes autoriza a outra a rescindir este contrato de pleno direito, nos termos da cláusula de Rescisão, sem prejuízo das demais medidas legais cabíveis.`);
  // Fase 3.9 (seção 24): de-placeholder — o próprio prompt do usuário forneceu a
  // enumeração exigida (não constitui sociedade, associação, joint venture, representação
  // comercial, franquia, relação trabalhista, mandato), então esta cláusula já tinha
  // redação própria e específica desde a Fase 3.9 (Fase 3.10 eliminou o helper de
  // placeholder inteiramente — todas as cláusulas agora têm redação substantiva).
  push('Independência das Partes', 'Este contrato não constitui, em nenhuma hipótese, sociedade, associação, joint venture, consórcio, representação comercial, agência, franquia, relação de emprego/vínculo empregatício, ou mandato entre a NICK e o parceiro. As partes atuam como pessoas jurídicas independentes, cada uma responsável por seus próprios empregados, prepostos, obrigações fiscais, trabalhistas e previdenciárias, não havendo solidariedade ou subsidiariedade entre elas por atos, dívidas ou obrigações da outra parte perante terceiros, ressalvado o expressamente previsto nesta minuta.');

  // Fase 3.9 (seção 26): de-placeholder — cobre tanto a cessão da posição contratual em
  // si (mecanismo geral) quanto, especificamente, a venda/transferência da operação do
  // parceiro (change of control) para um novo controlador/adquirente, que exige um rito
  // próprio (comunicação prévia, identificação do comprador, análise de crédito, anuência
  // contratual da NICK, transferência formal das obrigações, preservação dos direitos da
  // NICK) — sem o qual a mudança de controle/venda da operação poderia, na prática,
  // driblar as cláusulas de exclusividade, clientes reservados e restrição de rede
  // concorrente ao simplesmente trocar quem controla o parceiro.
  push('Cessão da Posição Contratual e Venda/Transferência da Operação do Parceiro', 'A cessão, no todo ou em parte, da posição contratual do parceiro nesta minuta a terceiro depende de anuência prévia e expressa da NICK, sem a qual é nula e ineficaz perante a NICK. Especificamente na hipótese de venda ou transferência da operação do parceiro (incluindo mudança de controle societário) que envolva, direta ou indiretamente, os direitos e obrigações desta minuta, o parceiro se obriga a: (a) comunicar formalmente a NICK com antecedência mínima a ser definida pelo jurídico; (b) identificar o comprador/novo controlador; (c) permitir que a NICK realize análise de crédito e idoneidade do comprador/novo controlador; (d) obter a anuência contratual expressa da NICK antes da conclusão da operação; (e) assegurar a transferência formal, ao comprador/novo controlador, de todas as obrigações desta minuta (incluindo exclusividade, clientes reservados, restrição de rede concorrente e take-or-pay); e (f) preservar integralmente, perante o comprador/novo controlador, todos os direitos da NICK previstos nesta minuta. A NICK pode recusar a anuência de forma fundamentada, especialmente quando o comprador/novo controlador for concorrente direto da NICK ou não oferecer garantias equivalentes de idoneidade e capacidade de cumprimento contratual.');

  // Fase 3.9 (seção 29): a cessão está sujeita à regulação de telecomunicações — o
  // parceiro mantém suas próprias outorgas/licenças perante a Anatel, e a cessão não pode
  // ser apresentada como dispensando qualquer obrigação regulatória do parceiro. A
  // validação jurídica/regulatória final é sempre do jurídico da NICK — esta cláusula
  // afirma o princípio geral, não substitui análise regulatória específica.
  push('Regulatório (Anatel)', 'A prestação de serviços de telecomunicações pelo parceiro a seus clientes finais está sujeita à regulamentação da Agência Nacional de Telecomunicações (Anatel) e demais órgãos competentes. O parceiro é integralmente responsável por obter e manter, por conta própria, todas as outorgas, licenças, autorizações e registros regulatórios exigidos para a prestação do serviço aos seus clientes finais — a cessão de infraestrutura objeto desta minuta NÃO dispensa, substitui ou supre qualquer obrigação regulatória do parceiro perante a Anatel ou outro órgão competente. Esta cláusula não constitui validação jurídica ou regulatória definitiva quanto ao enquadramento desta cessão perante a regulamentação setorial vigente — tal validação é de responsabilidade do jurídico da NICK antes da assinatura.');

  // Fase 3.9 (seção 19): apenas a POSSIBILIDADE de integração é descrita aqui — a
  // integração HubSoft real está explicitamente fora de escopo desta fase ("Deixando
  // para depois: integração HubSoft", instrução original do projeto). Esta cláusula nunca
  // altera responsabilidades contratuais: a integração, quando existir, é só automação de
  // medição, não fonte de nenhuma obrigação nova.
  push('Integração com Sistemas do Parceiro (ex.: HubSoft)', 'A NICK poderá, mediante acordo específico entre as partes e sem qualquer obrigação de fazê-lo, disponibilizar integração via API com o sistema de gestão do parceiro (ex.: HubSoft ou similar) para fins exclusivos de automação da apuração de medição de faturamento/revenue share (ver cláusula de Auditoria de Faturamento). Esta eventual integração é meramente instrumental e de automação operacional — em nenhuma hipótese altera, cria ou extingue qualquer responsabilidade, obrigação ou direito contratual das partes previstos nesta minuta. Enquanto não implementada, a apuração de faturamento/revenue share segue o processo manual/via relatório descrito na cláusula de Auditoria.');
  push('Comunicações e Notificações entre as Partes', `Todas as comunicações e notificações formais entre as partes relacionadas a esta minuta — incluindo, exemplificativamente, as previstas nas cláusulas de Força Maior, Inadimplência, Rescisão e Expansão de Rede — devem ser feitas por escrito, aos endereços/contatos formalmente registrados no cadastro da NICK para cada parte (ver dados do parceiro nesta minuta), preferencialmente por meio que permita comprovação de recebimento (ex.: e-mail com confirmação de leitura, carta com AR, ou notificação formal via sistema da NICK, quando disponível). Alteração de endereço ou contato de qualquer das partes só produz efeito perante a outra após comunicação formal da mudança, permanecendo válidas, até então, as comunicações dirigidas ao contato anteriormente registrado.${SUJEITO_A_VALIDACAO_JURIDICA} O meio específico exigido (ex.: exclusividade de carta com AR versus e-mail) é cláusula-base sujeita a definição pelo jurídico da NICK.`);

  push('Tolerância e Não Renúncia', 'A tolerância de qualquer das partes quanto ao eventual descumprimento de obrigação prevista nesta minuta pela outra parte, ainda que reiterada, não implica renúncia ao direito correspondente, novação, alteração tácita dos termos contratados, nem precedente invocável em situações futuras — configurando mera liberalidade, que pode ser exigida a qualquer tempo, salvo waiver formal e por escrito, específico para aquela situação.');

  push('Nulidade Parcial (Independência das Cláusulas)', 'A eventual invalidade, nulidade ou inexequibilidade de qualquer cláusula ou disposição desta minuta, total ou parcialmente, não afeta a validade e a exequibilidade das demais disposições, que permanecem em pleno vigor e efeito. Nessa hipótese, as partes envidarão esforços de boa-fé para substituir a disposição inválida por outra, válida, que reflita da forma mais próxima possível a intenção econômica e jurídica original das partes quanto àquele ponto.');

  push('Solução de Controvérsias e Mediação', `As partes se comprometem a buscar, previamente a qualquer medida judicial, a resolução amigável de eventuais controvérsias decorrentes desta minuta, diretamente entre seus representantes ou, não havendo êxito em prazo razoável, por meio de mediação conduzida por câmara de mediação a ser indicada de comum acordo. Não obtida solução consensual pela via direta ou pela mediação em prazo razoável, qualquer das partes poderá recorrer à via judicial competente, nos termos da cláusula de Foro, sem prejuízo do direito de qualquer das partes buscar diretamente a via judicial em caráter de urgência, quando a natureza da controvérsia assim exigir (ex.: medida cautelar).${SUJEITO_A_VALIDACAO_JURIDICA} A câmara de mediação específica, seu regulamento e os prazos exatos das etapas acima são cláusula-base sujeita a definição pelo jurídico da NICK — podendo, a critério do jurídico, prever-se cláusula arbitral em substituição à via judicial.`);

  push('Foro', `Fica eleito o foro da comarca da sede da NICK para dirimir quaisquer controvérsias oriundas desta minuta que não forem solucionadas nos termos da cláusula de Solução de Controvérsias e Mediação, com renúncia expressa a qualquer outro, por mais privilegiado que seja.${SUJEITO_A_VALIDACAO_JURIDICA} A comarca exata (cidade/UF da sede da NICK) deve ser confirmada e inserida pelo jurídico da NICK antes da assinatura — este sistema não mantém o endereço/sede formal da NICK como dado cadastrado.`);
  push('Disposições Gerais', 'Esta minuta, uma vez assinada, juntamente com seus eventuais aditivos e o apêndice técnico de infraestrutura referido na cláusula de Infraestrutura, constitui a integralidade do acordo entre as partes quanto ao seu objeto, substituindo entendimentos e negociações anteriores sobre a mesma matéria. Alterações só produzem efeito por escrito, na forma da cláusula de Aditivos Contratuais.');

  const aditivosTexto = aditivos && aditivos.length > 0
    ? `Este contrato já possui ${fmtInt(aditivos.length)} aditivo(s) registrado(s) (ver tabela e descrição de cada um abaixo). Qualquer alteração aos termos desta minuta deve ser feita exclusivamente por aditivo formal, nunca por acordo verbal ou informal. ${aditivos.map((a) => `Aditivo #${a.numero} (${a.tipo}, ${a.status}, ${fmtDate(a.data)}): ${a.descricao || 'sem descrição registrada'}.`).join(' ')}`
    : 'Este contrato não possui aditivos registrados até o momento da geração desta minuta. Qualquer alteração futura aos termos aqui descritos deve ser feita exclusivamente por aditivo formal.';
  push('Aditivos Contratuais', aditivosTexto);
  if (aditivos && aditivos.length > 0) {
    pushTabela('Aditivos Registrados', aditivos.map((a) => [`#${a.numero}`, a.tipo, a.status, fmtDate(a.data)]));
  }

  sections.push({ n: ++n, titulo: 'Assinatura', tipo: 'assinatura' });

  return {
    numero: contrato.numero,
    numero_versao: contrato.versao_atual,
    status: contrato.status,
    parceiro_nome: parceiro.nome_fantasia || parceiro.razao_social,
    cidade_nome: cidade.nome,
    cidade_uf: cidade.uf,
    prazo_meses: contrato.prazo_meses,
    data_inicio: contrato.data_inicio,
    criado_em: contrato.criado_em,
    sections,
  };
}

module.exports = { buildContractDocumentModel, fmtBRL, fmtPct, fmtInt, fmtDate };
