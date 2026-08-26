// OptiMon — Fase 2.4: modelo de documento da proposta comercial.
//
// Módulo puro (sem I/O, sem chamada a banco) que transforma o jsonb devolvido por
// pricing_proposal_get_by_id/pricing_proposal_external_view num modelo estruturado de
// 28 seções, consumido igualmente por pdfProposal.js e docxProposal.js — uma única fonte
// de verdade para o conteúdo do documento, pra nunca divergir PDF x DOCX.
//
// IMPORTANTE — fronteira INTERNA x EXTERNA (seção 6 do prompt-mestre): todo campo de
// governança (piso, abertura, desconto, desconto máximo permitido, preço mínimo
// autorizado, governance_status) e todo dado de autorização (autorizado_por/em,
// motivo_autorizacao) só aparece quando modo === 'INTERNA'. Em modo 'EXTERNA' esses
// campos nunca são lidos do snapshot — a função buildSections() simplesmente não os
// inclui em nenhuma seção, então um bug de template não pode vazá-los por engano.

const STATUS_LABELS = {
  RASCUNHO: 'Rascunho',
  EM_APROVACAO: 'Em Aprovação',
  APROVADA: 'Aprovada',
  ENVIADA: 'Enviada',
  EM_NEGOCIACAO: 'Em Negociação',
  ACEITA: 'Aceita',
  RECUSADA: 'Recusada',
  EXPIRADA: 'Expirada',
  CANCELADA: 'Cancelada',
};

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

function fmtInt(v) {
  const n = Number(v);
  if (v === null || v === undefined || Number.isNaN(n)) return '—';
  return n.toLocaleString('pt-BR');
}

function fmtDate(v) {
  if (!v) return '—';
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return '—';
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric' });
}

function addDays(dateStr, days) {
  const d = dateStr ? new Date(dateStr) : new Date();
  d.setDate(d.getDate() + (Number(days) || 0));
  return d;
}

// Composição de preço total a partir de piso/revenue-share (mesma regra usada por
// app.simular_precificacao_completa para os modos MAX/SUM — os únicos que dependem só de
// piso+revenue-share; os demais modos (COMPOSICAO_PADRAO/FLOOR_ONLY/MINIMUM_ONLY) recaem
// no fallback max(piso, revenue share), sinalizado como estimativa nos cenários — a
// composição contratual real e definitiva é sempre snapshot.total_payable, nunca
// recalculada aqui).
function composeTotalPayable(mode, floor, revenueShareValue) {
  if (mode === 'FLOOR_ONLY') return floor ?? 0;
  if (mode === 'SUM') return (floor ?? 0) + (revenueShareValue ?? 0);
  return Math.max(floor ?? 0, revenueShareValue ?? 0); // MAX e demais modos (estimativa)
}

// 3 cenários de sensibilidade comercial (seção 12 do prompt-mestre) — SEMPRE ilustrativos,
// nunca substituem snapshot.total_payable/preco_proposto (que são os valores contratuais
// reais, já calculados e congelados pelo Pricing Engine). Conservador/Agressivo variam o
// volume de clientes em ±15% como cenário de planejamento comercial.
function buildScenarios(snapshot) {
  const clientesBase = Number(snapshot.clientes) || 0;
  const arpu = Number(snapshot.arpu) || 0;
  const floor = Number(snapshot.floor) || 0;
  const revenueSharePct = Number(snapshot.revenue_share_pct) || 0;
  const mode = snapshot.composicao_mode;

  const cenarios = [
    { chave: 'CONSERVADOR', nome: 'Conservador', fator: 0.85 },
    { chave: 'BASE', nome: 'Base', fator: 1.0 },
    { chave: 'AGRESSIVO', nome: 'Agressivo', fator: 1.15 },
  ];

  return cenarios.map((c) => {
    const clientes = Math.round(clientesBase * c.fator);
    const faturamento = round2(clientes * arpu);
    const revenueShareValue = round2(faturamento * revenueSharePct);
    const totalPayable = c.chave === 'BASE' && snapshot.total_payable != null
      ? Number(snapshot.total_payable)
      : round2(composeTotalPayable(mode, floor, revenueShareValue));
    const partnerRevenue = round2(faturamento - totalPayable);
    return {
      chave: c.chave,
      nome: c.nome,
      clientes,
      faturamento,
      total_payable: totalPayable,
      partner_revenue: partnerRevenue,
      partner_margin: faturamento > 0 ? partnerRevenue / faturamento : null,
    };
  });
}

function round2(n) {
  return Math.round((Number(n) || 0) * 100) / 100;
}

// Projeções 12/36/48/60 meses (seção 13) — 48 é o mínimo contratual (prazo_meses padrão
// do contrato), 60 é projeção além do prazo mínimo, sempre marcada como estimativa.
function buildProjections(snapshot, prazoMeses) {
  const horizontes = [12, 36, 48, 60];
  const totalMensal = Number(snapshot.total_payable) || 0;
  const receitaMensal = Number(snapshot.faturamento) || 0;
  const partnerMensal = Number(snapshot.partner_revenue) || 0;
  const minimoContratual = Number(prazoMeses) || 48;

  return horizontes.map((meses) => ({
    meses,
    rotulo: meses === minimoContratual ? `${meses} meses (mínimo contratual)` : meses > minimoContratual ? `${meses} meses (projeção)` : `${meses} meses`,
    receita_bruta_acumulada: round2(receitaMensal * meses),
    total_pago_optimon_acumulado: round2(totalMensal * meses),
    receita_parceiro_acumulada: round2(partnerMensal * meses),
  }));
}

// Dados-fonte dos 4 gráficos (seção 14) — formato genérico {titulo, tipo, labels, series:
// [{nome, valores}]} consumido igualmente por chartDraw.js (PDF) e pela tabela-substituta
// no DOCX (ver docxProposal.js).
function buildCharts(model) {
  const charts = [];

  charts.push({
    titulo: 'Receita Acumulada por Horizonte de Prazo',
    tipo: 'barras',
    labels: model.projections.map((p) => `${p.meses}m`),
    series: [{ nome: 'Receita bruta acumulada', valores: model.projections.map((p) => p.receita_bruta_acumulada) }],
  });

  charts.push({
    titulo: 'Comparativo de Cenários — Faturamento Mensal',
    tipo: 'barras',
    labels: model.scenarios.map((s) => s.nome),
    series: [{ nome: 'Faturamento mensal estimado', valores: model.scenarios.map((s) => s.faturamento) }],
  });

  if (model.modo === 'INTERNA') {
    charts.push({
      titulo: 'Composição de Preço — Piso x Abertura x Recomendado x Proposto',
      tipo: 'barras',
      labels: ['Piso', 'Recomendado', 'Abertura', 'Proposto'],
      series: [{ nome: 'R$/mês', valores: [model.snapshot.floor, model.snapshot.recommended, model.snapshot.opening, model.snapshot.preco_proposto] }],
    });
  } else {
    charts.push({
      titulo: 'Investimento Mensal x Valor Total do Contrato',
      tipo: 'barras',
      labels: ['Mensal', `Total (${model.prazo_meses}m)`],
      series: [{ nome: 'R$', valores: [model.snapshot.total_payable, round2((model.snapshot.total_payable || 0) * model.prazo_meses)] }],
    });
  }

  charts.push({
    titulo: 'Receita do Parceiro por Cenário',
    tipo: 'barras',
    labels: model.scenarios.map((s) => s.nome),
    series: [{ nome: 'Receita do parceiro (mensal)', valores: model.scenarios.map((s) => s.partner_revenue) }],
  });

  return charts;
}

/**
 * Monta o modelo completo de 28 seções do documento de proposta.
 * @param {object} proposta - jsonb de pricing_proposal_get_by_id (modo INTERNA) ou
 *   pricing_proposal_external_view (modo EXTERNA — já vem sem campos de governança).
 * @param {{modo: 'INTERNA'|'EXTERNA'}} opts
 */
function buildProposalDocumentModel(proposta, opts = {}) {
  const modo = opts.modo === 'EXTERNA' ? 'EXTERNA' : 'INTERNA';
  const snapshot = proposta.snapshot || {};
  const prazoMeses = proposta.prazo_meses || 48;
  const validadeDias = proposta.validade_dias ?? 15;
  const dataValidade = addDays(proposta.criado_em, validadeDias);

  const base = { modo, snapshot, prazo_meses: prazoMeses };
  const scenarios = buildScenarios(snapshot);
  const projections = buildProjections(snapshot, prazoMeses);
  const charts = buildCharts({ ...base, scenarios, projections });

  const parceiroNome = proposta.parceiro_nome_capa || proposta.parceiro_nome_fantasia || proposta.parceiro_razao_social || 'A definir';

  const sections = [
    { n: 1, titulo: 'Capa', tipo: 'capa' },
    { n: 2, titulo: 'Sumário', tipo: 'sumario' },
    { n: 3, titulo: 'Apresentação da OptiMon', texto: 'A OptiMon é uma operadora de infraestrutura de rede óptica (cessão de rede) que conecta parceiros comerciais a praças estrategicamente selecionadas, oferecendo capilaridade FTTH sem exigir investimento em rede própria do parceiro.' },
    { n: 4, titulo: 'Objetivo da Proposta', texto: `Formalizar as condições comerciais de cessão de rede para operação do parceiro ${parceiroNome} na praça de ${proposta.cidade_nome || '—'}/${proposta.cidade_uf || '—'}, com base na simulação técnico-comercial realizada em ${fmtDate(proposta.criado_em)}.` },
    { n: 5, titulo: 'Dados do Parceiro', tipo: 'tabela', linhas: [
      ['Parceiro', parceiroNome],
      ['Contato', proposta.parceiro_cargo_contato || '—'],
    ] },
    { n: 6, titulo: 'Dados da Praça', tipo: 'tabela', linhas: [
      ['Cidade', proposta.cidade_nome || '—'],
      ['UF', proposta.cidade_uf || '—'],
      ['Versão de precificação', snapshot.pricing_version || '—'],
    ] },
    { n: 7, titulo: 'Escopo da Rede Cedida', texto: `Infraestrutura óptica ativa disponibilizada na praça, com capacidade para até ${fmtInt(snapshot.clientes)} clientes finais distribuídos em ${fmtInt(snapshot.pons_count)} porta(s) PON.` },
    { n: 8, titulo: 'Modelo Comercial', tipo: 'tabela', linhas: [
      ['Modelo', modo === 'INTERNA' ? (snapshot.composicao_mode || '—') : 'Cessão de rede com revenue share'],
      ['Revenue share', fmtPct(snapshot.revenue_share_pct)],
      ['Prazo contratual mínimo', `${prazoMeses} meses`],
    ] },
    { n: 9, titulo: 'Volumetria', tipo: 'tabela', linhas: [
      ['Clientes projetados', fmtInt(snapshot.clientes)],
      ['Portas PON', fmtInt(snapshot.pons_count)],
    ] },
    { n: 10, titulo: 'ARPU e Faturamento Estimado', tipo: 'tabela', linhas: [
      ['ARPU', fmtBRL(snapshot.arpu)],
      ['Faturamento mensal estimado', fmtBRL(snapshot.faturamento)],
    ] },
    modo === 'INTERNA'
      ? { n: 11, titulo: 'Composição de Preço (Interna)', tipo: 'tabela', linhas: [
          ['Piso', fmtBRL(snapshot.floor)],
          ['Preço recomendado', fmtBRL(snapshot.recommended)],
          ['Preço de abertura', fmtBRL(snapshot.opening)],
          ['Preço proposto', fmtBRL(snapshot.preco_proposto)],
          ['Desconto vs. abertura', fmtPct(snapshot.discount?.desconto_percentual_abertura, 2)],
          ['Desconto máximo permitido', fmtPct(snapshot.max_override_discount_percent)],
          ['Preço mínimo autorizável', fmtBRL(snapshot.preco_minimo_autorizado)],
          ['Governança (avaliação automática)', snapshot.governance_status?.tri_state || '—'],
        ] }
      : { n: 11, titulo: 'Condições Comerciais', tipo: 'tabela', linhas: [
          ['Preço proposto', fmtBRL(snapshot.preco_proposto)],
          ['Total mensal do contrato', fmtBRL(snapshot.total_payable)],
        ] },
    { n: 12, titulo: 'Cenário Conservador (-15% de volume)', tipo: 'cenario', cenario: scenarios[0] },
    { n: 13, titulo: 'Cenário Base', tipo: 'cenario', cenario: scenarios[1] },
    { n: 14, titulo: 'Cenário Agressivo (+15% de volume)', tipo: 'cenario', cenario: scenarios[2] },
    { n: 15, titulo: 'Projeção — 12 meses', tipo: 'projecao', projecao: projections[0] },
    { n: 16, titulo: 'Projeção — 36 meses', tipo: 'projecao', projecao: projections[1] },
    { n: 17, titulo: 'Projeção — 48 meses (mínimo contratual)', tipo: 'projecao', projecao: projections[2] },
    { n: 18, titulo: 'Projeção — 60 meses (projeção, além do mínimo)', tipo: 'projecao', projecao: projections[3] },
    { n: 19, titulo: charts[0].titulo, tipo: 'grafico', grafico: charts[0] },
    { n: 20, titulo: charts[1].titulo, tipo: 'grafico', grafico: charts[1] },
    { n: 21, titulo: charts[2].titulo, tipo: 'grafico', grafico: charts[2] },
    { n: 22, titulo: charts[3].titulo, tipo: 'grafico', grafico: charts[3] },
    { n: 23, titulo: 'Revenue Share e Condições de Pagamento', texto: modo === 'INTERNA'
        ? `Repasse mensal de ${fmtPct(snapshot.revenue_share_pct)} sobre o faturamento do parceiro na praça, com piso mínimo mensal garantido conforme seção de composição de preço. Faturamento e cobrança em ciclo mensal, vencimento a combinar em contrato.`
        : `Repasse mensal de ${fmtPct(snapshot.revenue_share_pct)} sobre o faturamento do parceiro na praça, com valor mensal mínimo garantido à OptiMon conforme condições comerciais. Faturamento e cobrança em ciclo mensal, vencimento a combinar em contrato.` },
    { n: 24, titulo: 'Prazo e Vigência', texto: `Vigência contratual mínima de ${prazoMeses} meses a partir da data de assinatura, renovável mediante acordo entre as partes.` },
    { n: 25, titulo: 'Validade desta Proposta', texto: `Esta proposta é válida por ${validadeDias} dias a partir de ${fmtDate(proposta.criado_em)}, com vencimento em ${fmtDate(dataValidade)}. Após esse prazo, os valores e condições aqui apresentados podem ser revistos.` },
    modo === 'INTERNA'
      ? { n: 26, titulo: 'Governança e Autorização (uso interno)', tipo: 'tabela', linhas: [
          ['Status', STATUS_LABELS[proposta.status] || proposta.status],
          ['Autorizado por', proposta.autorizado_por_nome || '—'],
          ['Autorizado em', fmtDate(proposta.autorizado_em)],
          ['Preço autorizado', fmtBRL(proposta.preco_autorizado)],
          ['Motivo da autorização', proposta.motivo_autorizacao || '—'],
        ] }
      : { n: 26, titulo: 'Status da Proposta', tipo: 'tabela', linhas: [
          ['Status', STATUS_LABELS[proposta.status] || proposta.status],
        ] },
    { n: 27, titulo: 'Termos e Condições Gerais', texto: 'Esta proposta é um instrumento comercial preliminar e não substitui o contrato definitivo de cessão de rede, que detalhará SLA, penalidades, condições de reajuste e demais cláusulas jurídicas. Os valores aqui apresentados foram calculados pelo Pricing Engine da OptiMon a partir dos parâmetros de rede e comerciais informados.' },
    { n: 28, titulo: 'Aceite e Assinaturas', tipo: 'assinatura' },
  ];

  return {
    modo,
    numero: proposta.numero,
    status: proposta.status,
    status_label: STATUS_LABELS[proposta.status] || proposta.status,
    numero_versao: proposta.numero_versao,
    cidade_nome: proposta.cidade_nome,
    cidade_uf: proposta.cidade_uf,
    parceiro_nome: parceiroNome,
    parceiro_cargo_contato: proposta.parceiro_cargo_contato,
    criado_em: proposta.criado_em,
    validade_dias: validadeDias,
    data_validade: dataValidade,
    prazo_meses: prazoMeses,
    snapshot,
    scenarios,
    projections,
    charts,
    sections,
  };
}

module.exports = { buildProposalDocumentModel, fmtBRL, fmtPct, fmtInt, fmtDate, STATUS_LABELS };
