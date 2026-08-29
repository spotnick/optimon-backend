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

  return `${fibraTerceiros} ${redePropria} ${expansao} ${workflow} ${historico}`;
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

  return partes.join(' ');
}

const CLAUSULA_MODELO_JURIDICO = (titulo) =>
  `[CLÁUSULA-MODELO — AGUARDANDO REDAÇÃO DO JURÍDICO DA NICK] Não existe, nesta versão do sistema, fonte de dado estruturada nem redação jurídica aprovada para "${titulo}". Este parágrafo é um placeholder explícito — NÃO deve ser tratado como cláusula válida. O jurídico da NICK deve inserir o texto definitivo antes de qualquer assinatura.`;

function buildContractDocumentModel(dados) {
  const { contrato, parceiro, cidade, pricing_config: pc, regras, clientes_reservados: clientes, ativos, fibras_count, pons_count, aditivos, reajustes, regras_solicitacoes: solicitacoes } = dados;

  const sections = [];
  let n = 0;
  const push = (titulo, texto) => sections.push({ n: ++n, titulo, texto });
  const pushTabela = (titulo, linhas) => sections.push({ n: ++n, titulo, tipo: 'tabela', linhas });

  // 1. Capa (tratada à parte pelo renderer, número reservado)
  sections.push({ n: 0, titulo: 'Capa', tipo: 'capa' });

  // Fase 3.8 (item 3.8-13): estrutura completa de 44 seções fixas — glossário dos termos
  // usados de forma consistente no resto desta minuta (Rede, Fibra, Porta PON, POP,
  // Take-or-Pay, Revenue Share, Aditivo). Não é cláusula-modelo à espera do jurídico: é
  // vocabulário do próprio sistema, sempre igual, nunca dependente de dado de contrato.
  push('Definições', 'Para os fins desta minuta, aplicam-se as seguintes definições: "Rede" ou "Infraestrutura" designa o conjunto de fibras ópticas, cabos, postes e equipamentos passivos de propriedade da NICK. "Fibra" designa um par óptico individual identificado no sistema de gestão de infraestrutura da NICK. "Porta PON" designa o ponto de acesso ativo (OLT) ao qual uma ou mais fibras/clientes finais se conectam, com capacidade máxima de assinantes definida tecnicamente. "POP" (Ponto de Presença) designa a instalação física da NICK onde fibras e portas PON estão concentradas. "Take-or-Pay" designa o valor mínimo mensal garantido devido pelo parceiro à NICK, independentemente do faturamento apurado. "Revenue Share" designa o percentual do faturamento do parceiro apurado e devido à NICK, sempre somado ao Take-or-Pay (nunca em substituição). "Aditivo" designa o instrumento formal de alteração desta minuta, único meio válido de modificação de seus termos.');

  push('Objeto', `O presente instrumento tem por objeto a cessão onerosa, pela NICK, de infraestrutura de rede óptica (fibras, portas PON e/ou capacidade associada) ao parceiro ${parceiro.razao_social}${parceiro.nome_fantasia ? ` ("${parceiro.nome_fantasia}")` : ''}, CNPJ ${parceiro.cnpj || '—'}, na cidade de ${cidade.nome}/${cidade.uf}, para exploração comercial de serviços de telecomunicações pelo parceiro junto a seus próprios clientes finais, nos termos e condições estabelecidos nesta minuta.`);

  push('Cessão de Rede', `A NICK cede ao parceiro o direito de uso da infraestrutura descrita na cláusula de Infraestrutura, pelo prazo e condições financeiras aqui definidos. A cessão não transfere a propriedade da infraestrutura física (fibras, cabos, postes, portas PON), que permanece integralmente da NICK — ver cláusula de Propriedade dos Ativos.`);

  push('Infraestrutura', `Este contrato está vinculado a ${fmtInt(fibras_count)} fibra(s) e ${fmtInt(pons_count)} porta(s) PON ativamente alocadas na cidade de ${cidade.nome}/${cidade.uf}. O detalhamento técnico completo (identificação de cada fibra/porta, POP de origem) consta do sistema de gestão de infraestrutura da NICK e deve ser anexado como apêndice técnico a esta minuta.`);

  // Fase 3.8 (item 3.8-13): sem fonte de dado estruturada para SLA (tempo de resposta,
  // uptime mínimo, janela de manutenção) — nenhum desses valores existe no schema hoje;
  // placeholder explícito em vez de inventar um número.
  push('Nível de Serviço (SLA)', CLAUSULA_MODELO_JURIDICO('Nível de Serviço — uptime mínimo garantido, tempo de resposta a incidentes, janelas de manutenção programada e eventuais créditos por descumprimento'));

  push('Responsabilidades das Partes', 'A NICK é responsável por: manter a infraestrutura cedida em condições operacionais; comunicar previamente manutenções programadas; disponibilizar canal de suporte técnico. O parceiro é responsável por: atendimento aos seus clientes finais; contratação/manutenção de equipamentos ativos de sua rede (exceto ativos cedidos pela NICK, ver cláusula de Ativos); cumprimento da legislação de telecomunicações aplicável; pagamento pontual dos valores devidos nos termos desta minuta.');

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

  push('Carência', 'Fica estabelecido período de carência (rampa de maturação) durante o qual o valor mínimo mensal garantido é reduzido conforme tabela de rampa vigente no sistema da NICK (app.get_fator_rampa), até atingir 100% do valor integral. Os percentuais e prazos exatos da rampa aplicável a este contrato devem ser conferidos no sistema antes da assinatura, pois podem ser específicos deste contrato ou seguir a régua padrão global.');

  push('Prazo Mínimo Contratual (48 meses)', contrato.prazo_minimo_excecao
    ? `Este contrato tem prazo de ${fmtInt(contrato.prazo_meses)} meses, ABAIXO do mínimo contratual padrão de 48 meses, com exceção formalmente registrada (motivo: ${contrato.motivo_excecao_prazo || '—'}). Esta exceção deve ser revisada pelo jurídico antes da assinatura.`
    : `O prazo deste contrato é de ${fmtInt(contrato.prazo_meses)} meses, respeitando o prazo mínimo contratual da NICK de 48 (quarenta e oito) meses. Este prazo é contratual e vinculante — nunca deve ser confundido com os horizontes analíticos (12/36/48/60 meses) usados apenas para fins de simulação financeira, que não representam o prazo real do contrato.`);

  push('Força Maior', CLAUSULA_MODELO_JURIDICO('Força Maior e Caso Fortuito — eventos excludentes de responsabilidade e procedimento de comunicação entre as partes'));

  push('Inadimplência', CLAUSULA_MODELO_JURIDICO('Inadimplência — consequências, prazos de notificação, encargos moratórios e critérios de caracterização'));
  push('Rescisão', CLAUSULA_MODELO_JURIDICO('Rescisão — hipóteses, prazos de notificação prévia, efeitos'));
  push('Penalidades', CLAUSULA_MODELO_JURIDICO('Penalidades — multas e critérios de aplicação'));
  push('Multa por Rescisão Antecipada', CLAUSULA_MODELO_JURIDICO('Multa por Rescisão Antecipada — critério de cálculo (ex.: proporcional ao saldo do prazo mínimo contratual) em caso de encerramento por iniciativa do parceiro antes do fim da vigência'));

  const ativosTexto = ativos && ativos.length > 0
    ? `Os seguintes ativos da NICK estão vinculados a este contrato: ${ativos.map((a) => `${a.tipo}${a.modelo ? ` ${a.modelo}` : ''}${a.patrimonio ? ` (patrimônio ${a.patrimonio})` : ''}`).join('; ')}.`
    : 'Nenhum ativo (OLT/ONU/equipamento) da NICK está registrado como vinculado a este contrato no sistema. Se houver equipamento cedido na prática, ele deve ser registrado e vinculado antes da assinatura.';
  push('Ativos e Equipamentos (OLT/ONU)', ativosTexto);
  if (ativos && ativos.length > 0) {
    pushTabela('Relação de Ativos Vinculados', ativos.map((a) => [a.tipo, a.modelo || '—', a.numero_serie || '—', a.patrimonio || '—', a.status]));
  }

  push('Propriedade dos Ativos', 'Todos os ativos físicos cedidos nos termos desta minuta (fibras, cabos, postes, portas PON e eventuais equipamentos OLT/ONU listados na cláusula anterior) permanecem, em qualquer hipótese, de propriedade exclusiva da NICK. A cessão de uso não constitui, em nenhuma circunstância, transferência de propriedade.');

  push('Devolução de Ativos', 'Encerrado o contrato por qualquer motivo, o parceiro se obriga a devolver à NICK, em condições operacionais normais, todos os ativos cedidos nos termos da cláusula de Ativos e Equipamentos, sujeitando-se a eventual apuração de perdas e danos conforme registro de devolução (ativos_devolucao) no sistema da NICK.');

  push('Seguro', CLAUSULA_MODELO_JURIDICO('Seguro — obrigatoriedade e cobertura mínima de seguro sobre os ativos cedidos (OLT/ONU/ONT/fonte/switch) durante a vigência do contrato'));

  push('Auditoria', 'A NICK se reserva o direito de auditar, a qualquer tempo e mediante aviso razoável, o uso da infraestrutura cedida e os dados que fundamentam a apuração de faturamento e revenue share deste contrato. Todo evento relevante deste contrato é registrado de forma imutável no log de auditoria do sistema da NICK (nunca sujeito a alteração ou exclusão).');

  push('Exclusividade', buildExclusividadeTexto(regras));
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

  push('Confidencialidade', CLAUSULA_MODELO_JURIDICO('Confidencialidade'));
  push('Proteção de Dados (LGPD)', CLAUSULA_MODELO_JURIDICO('Proteção de Dados Pessoais / LGPD'));
  push('Propriedade Intelectual e Uso de Marca', CLAUSULA_MODELO_JURIDICO('Propriedade Intelectual e Uso de Marca — condições para o parceiro referenciar a marca/rede da NICK em material comercial próprio'));
  push('Compliance, Ética e Anticorrupção', CLAUSULA_MODELO_JURIDICO('Compliance, Ética e Anticorrupção — declarações e obrigações das partes nos termos da Lei 12.846/2013 e política de compliance da NICK'));
  push('Independência das Partes', CLAUSULA_MODELO_JURIDICO('Independência das Partes — este contrato não constitui sociedade, consórcio, vínculo empregatício ou relação de representação entre NICK e parceiro'));
  push('Cessão da Posição Contratual', CLAUSULA_MODELO_JURIDICO('Cessão da Posição Contratual — condições (se houver) para o parceiro ceder sua posição contratual a terceiro, sempre sujeita a anuência prévia da NICK'));
  push('Comunicações e Notificações entre as Partes', CLAUSULA_MODELO_JURIDICO('Comunicações e Notificações — meios válidos de comunicação formal entre as partes e seus efeitos'));
  push('Tolerância e Não Renúncia', CLAUSULA_MODELO_JURIDICO('Tolerância e Não Renúncia — a tolerância de uma parte quanto ao descumprimento da outra não implica renúncia ao direito nem novação'));
  push('Nulidade Parcial (Independência das Cláusulas)', CLAUSULA_MODELO_JURIDICO('Nulidade Parcial — a invalidade de uma cláusula não compromete a validade das demais'));
  push('Solução de Controvérsias e Mediação', CLAUSULA_MODELO_JURIDICO('Solução de Controvérsias e Mediação — etapa de tentativa de resolução amigável/mediação previamente ao ajuizamento de ação judicial, se aplicável'));
  push('Foro', CLAUSULA_MODELO_JURIDICO('Eleição de Foro'));
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
