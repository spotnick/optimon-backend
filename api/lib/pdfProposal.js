// OptiMon — Fase 2.4 (seção 8/39): geração de PDF profissional da proposta comercial.
// pdfkit puro (sem headless-browser, sem canvas nativo) — capa, header/footer com
// numeração de página em toda página, tabelas, e os 4 gráficos desenhados como vetor
// (retângulos/linhas/texto) diretamente no documento. Nunca é "imprimir a tela do
// navegador" — o documento é montado programaticamente a partir do modelo de 28 seções
// (proposalDocumentModel.js), a mesma fonte usada pelo DOCX.

const PDFDocument = require('pdfkit');
const { buildProposalDocumentModel, fmtBRL, fmtPct, fmtInt, fmtDate } = require('./proposalDocumentModel');

const INK = '#1a2332';
const MUTED = '#5b6b7f';
const ACCENT = '#0e6e55';
const ACCENT_LIGHT = '#e4f2ee';
const LINE = '#d8dee5';
const PAGE_MARGIN = 50;

function drawHeaderFooter(doc, model, pageIndex, pageCount) {
  const { width, height } = doc.page;
  // Header
  doc.fontSize(8).fillColor(MUTED).font('Helvetica-Bold')
    .text('OPTIMON', PAGE_MARGIN, 24, { continued: true })
    .font('Helvetica').fillColor(MUTED)
    .text(`  |  Proposta Comercial ${model.numero || ''} (V${model.numero_versao || 1})`, { continued: false });
  doc.fontSize(8).fillColor(MUTED)
    .text(model.modo === 'INTERNA' ? 'USO INTERNO' : 'PROPOSTA', width - PAGE_MARGIN - 150, 24, { width: 150, align: 'right' });
  doc.moveTo(PAGE_MARGIN, 38).lineTo(width - PAGE_MARGIN, 38).strokeColor(LINE).lineWidth(0.5).stroke();
  // Footer
  doc.moveTo(PAGE_MARGIN, height - 40).lineTo(width - PAGE_MARGIN, height - 40).strokeColor(LINE).lineWidth(0.5).stroke();
  doc.fontSize(8).fillColor(MUTED)
    .text(`Gerado em ${fmtDate(new Date().toISOString())} — válido até ${fmtDate(model.data_validade)}`, PAGE_MARGIN, height - 30, { width: width - 2 * PAGE_MARGIN - 80 });
  doc.text(`Página ${pageIndex + 1} de ${pageCount}`, width - PAGE_MARGIN - 80, height - 30, { width: 80, align: 'right' });
}

function ensureSpace(doc, needed) {
  const bottom = doc.page.height - 50;
  if (doc.y + needed > bottom) {
    doc.addPage();
  }
}

function sectionHeading(doc, n, titulo) {
  ensureSpace(doc, 40);
  doc.moveDown(0.6);
  doc.fontSize(9).fillColor(ACCENT).font('Helvetica-Bold').text(`SEÇÃO ${n}`, { continued: false });
  doc.fontSize(14).fillColor(INK).font('Helvetica-Bold').text(titulo);
  doc.moveTo(doc.x, doc.y + 2).lineTo(doc.page.width - PAGE_MARGIN, doc.y + 2).strokeColor(ACCENT).lineWidth(1.2).stroke();
  doc.moveDown(0.6);
}

function drawTable(doc, rows) {
  const colLabelW = 210;
  const rowH = 20;
  ensureSpace(doc, rows.length * rowH + 10);
  const startX = PAGE_MARGIN;
  let y = doc.y;
  rows.forEach(([label, value], i) => {
    if (y + rowH > doc.page.height - 50) {
      doc.addPage();
      y = doc.y;
    }
    if (i % 2 === 0) {
      doc.rect(startX, y, doc.page.width - 2 * PAGE_MARGIN, rowH).fill(ACCENT_LIGHT);
    }
    doc.fillColor(INK).font('Helvetica-Bold').fontSize(9.5).text(String(label), startX + 8, y + 5, { width: colLabelW - 8 });
    doc.fillColor(INK).font('Helvetica').fontSize(9.5).text(String(value), startX + colLabelW, y + 5, { width: doc.page.width - 2 * PAGE_MARGIN - colLabelW - 8 });
    y += rowH;
  });
  doc.y = y + 4;
}

function drawBarChart(doc, chart) {
  const chartW = doc.page.width - 2 * PAGE_MARGIN;
  const chartH = 160;
  ensureSpace(doc, chartH + 50);
  const originX = PAGE_MARGIN + 10;
  const originY = doc.y + chartH;
  const values = chart.series[0].valores.map((v) => Number(v) || 0);
  const maxVal = Math.max(...values, 1);
  const n = values.length;
  const gap = 18;
  const barW = Math.max(24, (chartW - 20 - gap * (n - 1)) / n);

  // eixo
  doc.moveTo(originX, doc.y).lineTo(originX, originY).strokeColor(LINE).lineWidth(1).stroke();
  doc.moveTo(originX, originY).lineTo(originX + chartW - 20, originY).strokeColor(LINE).lineWidth(1).stroke();

  values.forEach((v, i) => {
    const barH = maxVal > 0 ? (v / maxVal) * (chartH - 30) : 0;
    const x = originX + 10 + i * (barW + gap);
    const y = originY - barH;
    doc.rect(x, y, barW, barH).fill(ACCENT);
    doc.fontSize(7.5).fillColor(INK).font('Helvetica-Bold').text(fmtBRL(v), x - 8, y - 12, { width: barW + 16, align: 'center' });
    doc.fontSize(8).fillColor(MUTED).font('Helvetica').text(String(chart.labels[i]), x - 8, originY + 4, { width: barW + 16, align: 'center' });
  });

  doc.y = originY + 20;
  doc.fontSize(8).fillColor(MUTED).font('Helvetica-Oblique').text(chart.series[0].nome, PAGE_MARGIN, doc.y);
  doc.moveDown(0.5);
}

function renderCoverPage(doc, model) {
  const { width, height } = doc.page;
  doc.rect(0, 0, width, height).fill('#0e6e55');
  doc.rect(0, height - 180, width, 180).fill('#0a5341');

  doc.fillColor('#ffffff').font('Helvetica-Bold').fontSize(30).text('OPTIMON', PAGE_MARGIN, 90);
  doc.fontSize(12).font('Helvetica').fillColor('#d8f2e9').text('Infraestrutura de Rede Óptica — Cessão de Rede', PAGE_MARGIN, 128);

  doc.fontSize(26).font('Helvetica-Bold').fillColor('#ffffff').text('Proposta Comercial', PAGE_MARGIN, 260, { width: width - 2 * PAGE_MARGIN });
  doc.fontSize(13).font('Helvetica').fillColor('#d8f2e9').text(model.modo === 'INTERNA' ? 'Documento de uso interno' : 'Documento para o parceiro', PAGE_MARGIN, 300);

  doc.fontSize(11).fillColor('#ffffff').font('Helvetica-Bold');
  const infoY = 360;
  const info = [
    ['Número', `${model.numero || '—'} (V${model.numero_versao || 1})`],
    ['Cidade', `${model.cidade_nome || '—'} — ${model.cidade_uf || '—'}`],
    ['Parceiro', model.parceiro_nome],
    ['Data', fmtDate(model.criado_em)],
    ['Validade', `${model.validade_dias} dias (até ${fmtDate(model.data_validade)})`],
    ['Status', model.status_label],
  ];
  let y = infoY;
  info.forEach(([label, value]) => {
    doc.font('Helvetica-Bold').fontSize(10).fillColor('#d8f2e9').text(label.toUpperCase(), PAGE_MARGIN, y);
    doc.font('Helvetica').fontSize(13).fillColor('#ffffff').text(value, PAGE_MARGIN, y + 14);
    y += 42;
  });

  doc.fontSize(8).fillColor('#a9d9c8').text('Documento gerado automaticamente pelo OptiMon Pricing Engine.', PAGE_MARGIN, height - 30);
}

function renderSummary(doc, model) {
  sectionHeading(doc, 2, 'Sumário');
  doc.fontSize(9.5).font('Helvetica').fillColor(INK);
  model.sections.slice(1).forEach((s) => {
    doc.text(`${String(s.n).padStart(2, '0')}.  ${s.titulo}`);
  });
}

function renderSignature(doc, model) {
  doc.moveDown(1);
  ensureSpace(doc, 140);
  doc.fontSize(9.5).font('Helvetica').fillColor(INK).text(
    'A assinatura abaixo (física ou digital) formaliza o aceite desta proposta pelas partes. Esta seção fica preparada para integração futura com aceite digital.'
  );
  doc.moveDown(3);
  const y = doc.y;
  doc.moveTo(PAGE_MARGIN, y).lineTo(PAGE_MARGIN + 220, y).strokeColor(LINE).stroke();
  doc.moveTo(doc.page.width - PAGE_MARGIN - 220, y).lineTo(doc.page.width - PAGE_MARGIN, y).strokeColor(LINE).stroke();
  doc.fontSize(9).fillColor(MUTED).text('OptiMon', PAGE_MARGIN, y + 4);
  doc.text(model.parceiro_nome, doc.page.width - PAGE_MARGIN - 220, y + 4, { width: 220, align: 'right' });
}

async function generateProposalPdf(proposta, opts = {}) {
  const model = buildProposalDocumentModel(proposta, opts);

  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: PAGE_MARGIN, bufferPages: true, info: {
      Title: `Proposta Comercial ${model.numero || ''}`,
      Author: 'OptiMon',
      Subject: `Proposta ${model.modo === 'INTERNA' ? 'Interna' : 'Externa'} — ${model.cidade_nome || ''}`,
    } });
    const chunks = [];
    doc.on('data', (c) => chunks.push(c));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);

    // 1) Capa
    renderCoverPage(doc, model);

    // 2) Sumário
    doc.addPage();
    renderSummary(doc, model);

    // 3-28) demais seções
    model.sections.slice(2).forEach((s) => {
      sectionHeading(doc, s.n, s.titulo);
      if (s.tipo === 'tabela') {
        drawTable(doc, s.linhas);
      } else if (s.tipo === 'cenario') {
        drawTable(doc, [
          ['Clientes', fmtInt(s.cenario.clientes)],
          ['Faturamento mensal', fmtBRL(s.cenario.faturamento)],
          ['Total mensal pago à OptiMon', fmtBRL(s.cenario.total_payable)],
          ['Receita mensal do parceiro', fmtBRL(s.cenario.partner_revenue)],
          ['Margem do parceiro', fmtPct(s.cenario.partner_margin)],
        ]);
      } else if (s.tipo === 'projecao') {
        drawTable(doc, [
          ['Horizonte', s.projecao.rotulo],
          ['Receita bruta acumulada', fmtBRL(s.projecao.receita_bruta_acumulada)],
          ['Total pago à OptiMon (acumulado)', fmtBRL(s.projecao.total_pago_optimon_acumulado)],
          ['Receita do parceiro (acumulado)', fmtBRL(s.projecao.receita_parceiro_acumulada)],
        ]);
      } else if (s.tipo === 'grafico') {
        drawBarChart(doc, s.grafico);
      } else if (s.tipo === 'assinatura') {
        renderSignature(doc, model);
      } else if (s.texto) {
        doc.fontSize(10).font('Helvetica').fillColor(INK).text(s.texto, { align: 'justify' });
      }
    });

    // Header/footer em toda página (exceto a capa, página 0)
    const range = doc.bufferedPageRange();
    const pageCount = range.count;
    for (let i = 1; i < pageCount; i++) {
      doc.switchToPage(i);
      drawHeaderFooter(doc, model, i, pageCount);
    }

    doc.end();
  });
}

module.exports = { generateProposalPdf };
