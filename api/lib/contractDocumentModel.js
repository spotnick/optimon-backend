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

function buildFibraTerceirosRedePropriaTexto(regras) {
  if (!regras) return 'Guardrails não registrados para este contrato — confirmar manualmente antes da assinatura.';
  const fibraTerceiros = regras.proibe_fibra_terceiros !== false
    ? 'O parceiro está PROIBIDO de utilizar fibra óptica de terceiros para prestar o serviço objeto deste contrato, salvo autorização expressa e registrada da NICK (workflow de solicitação/aprovação).'
    : 'O parceiro está autorizado a utilizar fibra óptica de terceiros — condição não padrão, exige atenção do jurídico.';
  const redePropria = regras.proibe_rede_propria !== false
    ? 'O parceiro está PROIBIDO de construir rede própria concorrente na área deste contrato sem autorização expressa e registrada da NICK.'
    : 'O parceiro está autorizado a construir rede própria na área do contrato — condição não padrão, exige atenção do jurídico.';
  const expansao = regras.exige_aprovacao_expansao !== false
    ? 'Qualquer expansão de capacidade contratada (novas portas PON, novos POPs, aumento de área) exige aprovação prévia e formal da NICK, registrada em aditivo contratual — nunca automática.'
    : 'Expansões de capacidade não exigem aprovação prévia formal neste contrato — condição não padrão.';
  return `${fibraTerceiros} ${redePropria} ${expansao}`;
}

function buildClientesReservadosTexto(clientes) {
  if (!clientes || clientes.length === 0) {
    return 'Nenhum cliente reservado registrado para este contrato. Não há, portanto, exceção de atendimento (incluindo eventual exceção Prefeitura) registrada nesta minuta — se houver acordo verbal nesse sentido, ele deve ser formalizado aqui antes da assinatura.';
  }
  const linhas = clientes.map((c) => `${c.cliente_nome}${c.motivo ? ` (motivo: ${c.motivo})` : ''} — status: ${c.status === 'RESERVADO' ? 'reservado (fora do escopo deste contrato)' : 'liberado'}`);
  return `Os seguintes clientes/entidades são reservados — ou seja, ficam FORA do escopo de atendimento deste contrato, permanecendo sob responsabilidade direta da NICK ou de tratamento à parte: ${linhas.join('; ')}.`;
}

const CLAUSULA_MODELO_JURIDICO = (titulo) =>
  `[CLÁUSULA-MODELO — AGUARDANDO REDAÇÃO DO JURÍDICO DA NICK] Não existe, nesta versão do sistema, fonte de dado estruturada nem redação jurídica aprovada para "${titulo}". Este parágrafo é um placeholder explícito — NÃO deve ser tratado como cláusula válida. O jurídico da NICK deve inserir o texto definitivo antes de qualquer assinatura.`;

function buildContractDocumentModel(dados) {
  const { contrato, parceiro, cidade, pricing_config: pc, regras, clientes_reservados: clientes, ativos, fibras_count, pons_count, aditivos, reajustes } = dados;

  const sections = [];
  let n = 0;
  const push = (titulo, texto) => sections.push({ n: ++n, titulo, texto });
  const pushTabela = (titulo, linhas) => sections.push({ n: ++n, titulo, tipo: 'tabela', linhas });

  // 1. Capa (tratada à parte pelo renderer, número reservado)
  sections.push({ n: 0, titulo: 'Capa', tipo: 'capa' });

  push('Objeto', `O presente instrumento tem por objeto a cessão onerosa, pela NICK, de infraestrutura de rede óptica (fibras, portas PON e/ou capacidade associada) ao parceiro ${parceiro.razao_social}${parceiro.nome_fantasia ? ` ("${parceiro.nome_fantasia}")` : ''}, CNPJ ${parceiro.cnpj || '—'}, na cidade de ${cidade.nome}/${cidade.uf}, para exploração comercial de serviços de telecomunicações pelo parceiro junto a seus próprios clientes finais, nos termos e condições estabelecidos nesta minuta.`);

  push('Cessão de Rede', `A NICK cede ao parceiro o direito de uso da infraestrutura descrita na cláusula de Infraestrutura, pelo prazo e condições financeiras aqui definidos. A cessão não transfere a propriedade da infraestrutura física (fibras, cabos, postes, portas PON), que permanece integralmente da NICK — ver cláusula de Propriedade dos Ativos.`);

  push('Infraestrutura', `Este contrato está vinculado a ${fmtInt(fibras_count)} fibra(s) e ${fmtInt(pons_count)} porta(s) PON ativamente alocadas na cidade de ${cidade.nome}/${cidade.uf}. O detalhamento técnico completo (identificação de cada fibra/porta, POP de origem) consta do sistema de gestão de infraestrutura da NICK e deve ser anexado como apêndice técnico a esta minuta.`);

  push('Responsabilidades das Partes', 'A NICK é responsável por: manter a infraestrutura cedida em condições operacionais; comunicar previamente manutenções programadas; disponibilizar canal de suporte técnico. O parceiro é responsável por: atendimento aos seus clientes finais; contratação/manutenção de equipamentos ativos de sua rede (exceto ativos cedidos pela NICK, ver cláusula de Ativos); cumprimento da legislação de telecomunicações aplicável; pagamento pontual dos valores devidos nos termos desta minuta.');

  const modeloCobranca = pc?.modelo_cobranca ? `modelo de cobrança "${pc.modelo_cobranca}"` : 'modelo de cobrança a definir';
  push('Pagamento', `O parceiro pagará à NICK mensalmente, conforme o ${modeloCobranca}, o maior entre a mensalidade mínima e o valor de revenue share apurado no mês (ver cláusulas de Take-or-Pay e Revenue Share), com vencimento e forma de cobrança a serem definidos pelo jurídico/financeiro da NICK nesta minuta antes da assinatura.`);

  push('Take-or-Pay (Mínimo Contratual)', pc?.mensalidade_minima_porta != null
    ? `Fica estabelecido um valor mínimo mensal garantido (Take-or-Pay) de ${fmtBRL(pc.mensalidade_minima_porta)}, devido pelo parceiro à NICK independentemente do faturamento efetivamente apurado no período, ressalvado o período de carência aplicável (ver cláusula de Carência) e a rampa de maturação contratual.`
    : 'Valor mínimo mensal garantido (Take-or-Pay) não está configurado em contrato_pricing_config para este contrato — deve ser confirmado antes da assinatura.');

  push('Revenue Share', pc?.percentual_revenue_share != null
    ? `Adicionalmente ao mínimo mensal garantido, será apurado revenue share de ${fmtPct(pc.percentual_revenue_share)} sobre a base de cálculo "${pc.base_calculo_revenue_share || '—'}", sempre que o valor apurado superar o mínimo mensal garantido.`
    : 'Percentual de revenue share não está configurado para este contrato — deve ser confirmado antes da assinatura.');

  push('Reajuste Anual', `Os valores desta minuta serão reajustados anualmente pelo índice ${pc?.indice_reajuste || 'a definir'}, aplicado sobre a competência de referência, conforme histórico de reajustes já aplicados a este contrato (ver tabela). Reajustes futuros seguem o motor de precificação da NICK (app.aplicar_reajuste_contrato) e nunca são aplicados retroativamente.`);
  if (reajustes && reajustes.length > 0) {
    pushTabela('Histórico de Reajustes Aplicados', reajustes.map((r) => [fmtDate(r.competencia_base), fmtPct(r.percentual_aplicado), r.status]));
  }

  push('Carência', 'Fica estabelecido período de carência (rampa de maturação) durante o qual o valor mínimo mensal garantido é reduzido conforme tabela de rampa vigente no sistema da NICK (app.get_fator_rampa), até atingir 100% do valor integral. Os percentuais e prazos exatos da rampa aplicável a este contrato devem ser conferidos no sistema antes da assinatura, pois podem ser específicos deste contrato ou seguir a régua padrão global.');

  push('Prazo Mínimo Contratual (48 meses)', contrato.prazo_minimo_excecao
    ? `Este contrato tem prazo de ${fmtInt(contrato.prazo_meses)} meses, ABAIXO do mínimo contratual padrão de 48 meses, com exceção formalmente registrada (motivo: ${contrato.motivo_excecao_prazo || '—'}). Esta exceção deve ser revisada pelo jurídico antes da assinatura.`
    : `O prazo deste contrato é de ${fmtInt(contrato.prazo_meses)} meses, respeitando o prazo mínimo contratual da NICK de 48 (quarenta e oito) meses. Este prazo é contratual e vinculante — nunca deve ser confundido com os horizontes analíticos (12/36/48/60 meses) usados apenas para fins de simulação financeira, que não representam o prazo real do contrato.`);

  push('Inadimplência', CLAUSULA_MODELO_JURIDICO('Inadimplência — consequências, prazos de notificação, encargos moratórios e critérios de caracterização'));
  push('Rescisão', CLAUSULA_MODELO_JURIDICO('Rescisão — hipóteses, prazos de notificação prévia, efeitos'));
  push('Penalidades', CLAUSULA_MODELO_JURIDICO('Penalidades — multas e critérios de aplicação'));

  const ativosTexto = ativos && ativos.length > 0
    ? `Os seguintes ativos da NICK estão vinculados a este contrato: ${ativos.map((a) => `${a.tipo}${a.modelo ? ` ${a.modelo}` : ''}${a.patrimonio ? ` (patrimônio ${a.patrimonio})` : ''}`).join('; ')}.`
    : 'Nenhum ativo (OLT/ONU/equipamento) da NICK está registrado como vinculado a este contrato no sistema. Se houver equipamento cedido na prática, ele deve ser registrado e vinculado antes da assinatura.';
  push('Ativos e Equipamentos (OLT/ONU)', ativosTexto);
  if (ativos && ativos.length > 0) {
    pushTabela('Relação de Ativos Vinculados', ativos.map((a) => [a.tipo, a.modelo || '—', a.numero_serie || '—', a.patrimonio || '—', a.status]));
  }

  push('Propriedade dos Ativos', 'Todos os ativos físicos cedidos nos termos desta minuta (fibras, cabos, postes, portas PON e eventuais equipamentos OLT/ONU listados na cláusula anterior) permanecem, em qualquer hipótese, de propriedade exclusiva da NICK. A cessão de uso não constitui, em nenhuma circunstância, transferência de propriedade.');

  push('Devolução de Ativos', 'Encerrado o contrato por qualquer motivo, o parceiro se obriga a devolver à NICK, em condições operacionais normais, todos os ativos cedidos nos termos da cláusula de Ativos e Equipamentos, sujeitando-se a eventual apuração de perdas e danos conforme registro de devolução (ativos_devolucao) no sistema da NICK.');

  push('Auditoria', 'A NICK se reserva o direito de auditar, a qualquer tempo e mediante aviso razoável, o uso da infraestrutura cedida e os dados que fundamentam a apuração de faturamento e revenue share deste contrato. Todo evento relevante deste contrato é registrado de forma imutável no log de auditoria do sistema da NICK (nunca sujeito a alteração ou exclusão).');

  push('Exclusividade', buildExclusividadeTexto(regras));
  push('Rede Própria do Parceiro e Fibras de Terceiros', buildFibraTerceirosRedePropriaTexto(regras));
  push('Clientes Reservados (inclui eventual exceção Prefeitura)', buildClientesReservadosTexto(clientes));

  push('Expansão de Rede', regras?.exige_aprovacao_expansao !== false
    ? 'Qualquer expansão da infraestrutura contratada por este parceiro (novas fibras, portas PON, POPs ou área geográfica) depende de aprovação prévia e formal da NICK, sempre formalizada por aditivo contratual — nunca presumida ou automática.'
    : 'Este contrato não exige aprovação prévia formal para expansão — condição não padrão, revisar com o jurídico.');

  push('Confidencialidade', CLAUSULA_MODELO_JURIDICO('Confidencialidade'));
  push('Proteção de Dados (LGPD)', CLAUSULA_MODELO_JURIDICO('Proteção de Dados Pessoais / LGPD'));
  push('Foro', CLAUSULA_MODELO_JURIDICO('Eleição de Foro'));

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
