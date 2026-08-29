// OptiMon — Fase 2.4 (seção 8/39): geração de PDF profissional da proposta comercial.
// pdfkit puro (sem headless-browser, sem canvas nativo) — capa, header/footer com
// numeração de página em toda página, tabelas, e os 4 gráficos desenhados como vetor
// (retângulos/linhas/texto) diretamente no documento. Nunca é "imprimir a tela do
// navegador" — o documento é montado programaticamente a partir do modelo de 28 seções
// (proposalDocumentModel.js), a mesma fonte usada pelo DOCX.

const path = require('path');
const fs = require('fs');
const PDFDocument = require('pdfkit');
const { buildProposalDocumentModel, fmtBRL, fmtPct, fmtInt, fmtDate } = require('./proposalDocumentModel');
const { resolveFonts } = require('./pdfFonts');

// Fase 3 (item 3.5): logo real da OptiMon (assets gerados pelo projeto, ver item 3.4 —
// web/public/branding/), embutida na capa (PDF só embute raster, não SVG — pdfkit).
// Nunca falha a geração do documento se o arquivo não existir por algum motivo (ex.:
// ambiente sem o diretório web/public ainda publicado) — cai de volta para o texto
// "OPTIMON" simples, como era antes desta correção.
const LOGO_DARK_PATH = path.join(__dirname, '..', '..', 'web', 'public', 'branding', 'optimon-logo-lockup-dark.png');
const LOGO_ICON_PATH = path.join(__dirname, '..', '..', 'web', 'public', 'branding', 'optimon-icon-192.png');
const LOGO_DARK_AVAILABLE = fs.existsSync(LOGO_DARK_PATH);
const LOGO_ICON_AVAILABLE = fs.existsSync(LOGO_ICON_PATH);

// Fase 3.8 (item 1/2 — identidade visual): paleta oficial OptiMon (azul-petróleo
// #06263F, teal #0D9488/#14B8A6/#2DD4BF) — antes desta correção o PDF de proposta
// usava um verde inventado (#0e6e55) sem nenhuma relação com a marca real do
// sistema (a mesma usada no frontend e no logo, ver web/public/branding/).
const INK = '#06263F';
const MUTED = '#5b6b7f';
const ACCENT = '#0D9488';
const ACCENT_LIGHT = '#E1F5F1';
const LINE = '#d8dee5';
const PAGE_MARGIN = 50;

function drawHeaderFooter(doc, model, pageIndex, pageCount) {
  const F = doc._brandFonts;
  const { width, height } = doc.page;
  // Header
  let textStartX = PAGE_MARGIN;
  if (LOGO_ICON_AVAILABLE) {
    doc.image(LOGO_ICON_PATH, PAGE_MARGIN, 18, { width: 14, height: 14 });
    textStartX = PAGE_MARGIN + 20;
  }
  doc.fontSize(8).fillColor(MUTED).font(F.bodySemibold)
    .text('OPTIMON', textStartX, 24, { continued: true })
    .font(F.body).fillColor(MUTED)
    .text(`  |  Proposta Comercial ${model.numero || ''} (V${model.numero_versao || 1})`, { continued: false });
  doc.fontSize(8).fillColor(MUTED).font(F.bodySemibold)
    .text(model.modo === 'INTERNA' ? 'USO INTERNO' : 'PROPOSTA', width - PAGE_MARGIN - 150, 24, { width: 150, align: 'right' });
  doc.moveTo(PAGE_MARGIN, 38).lineTo(width - PAGE_MARGIN, 38).strokeColor(LINE).lineWidth(0.5).stroke();
  // Footer
  doc.moveTo(PAGE_MARGIN, height - 40).lineTo(width - PAGE_MARGIN, height - 40).strokeColor(LINE).lineWidth(0.5).stroke();
  // CORREÇÃO (Fase 3, item 3.7 — bug encontrado ao testar o gerador de minuta de
  // contrato, que copiou este mesmo padrão): o texto do rodapé fica DENTRO da margem
  // inferior reservada pelo PDFDocument (margin:50). Chamar .text() ali disparava a
  // paginação automática do pdfkit — cada página do documento ganhava 1-2 páginas EXTRA
  // em branco (uma proposta de ~8 páginas de conteúdo real virava 22 páginas no PDF
  // final). Zera margins.bottom só durante este desenho pontual do rodapé e restaura
  // logo em seguida — não muda nenhum texto/posição visível, só evita o auto-pagebreak.
  const savedBottom = doc.page.margins.bottom;
  doc.page.margins.bottom = 0;
  doc.fontSize(8).fillColor(MUTED).font(F.body)
    .text(`Gerado em ${fmtDate(new Date().toISOString())} — válido até ${fmtDate(model.data_validade)}`, PAGE_MARGIN, height - 30, { width: width - 2 * PAGE_MARGIN - 80 });
  doc.font(F.mono).text(`Página ${pageIndex + 1} de ${pageCount}`, width - PAGE_MARGIN - 80, height - 30, { width: 80, align: 'right' });
  doc.page.margins.bottom = savedBottom;
}

function ensureSpace(doc, needed) {
  const bottom = doc.page.height - 50;
  if (doc.y + needed > bottom) {
    doc.addPage();
  }
}

function sectionHeading(doc, n, titulo) {
  const F = doc._brandFonts;
  ensureSpace(doc, 40);
  doc.moveDown(0.6);
  doc.fontSize(9).fillColor(ACCENT).font(F.displayBold).text(`SEÇÃO ${n}`, { continued: false });
  doc.fontSize(14).fillColor(INK).font(F.display).text(titulo);
  doc.moveTo(doc.x, doc.y + 2).lineTo(doc.page.width - PAGE_MARGIN, doc.y + 2).strokeColor(ACCENT).lineWidth(1.2).stroke();
  doc.moveDown(0.6);
}

function drawTable(doc, rows) {
  const F = doc._brandFonts;
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
    doc.fillColor(INK).font(F.bodySemibold).fontSize(9.5).text(String(label), startX + 8, y + 5, { width: colLabelW - 8 });
    // Coluna de valor: registro tipográfico "dado técnico/numérico" (IBM Plex Mono),
    // conforme identidade visual do OptiMon — a maior parte dos valores aqui é
    // monetária/percentual/contagem; para os poucos que são texto livre (nomes), o
    // monoespaçado ainda é legível e mantém a tabela visualmente consistente.
    doc.fillColor(INK).font(F.mono).fontSize(9.5).text(String(value), startX + colLabelW, y + 5, { width: doc.page.width - 2 * PAGE_MARGIN - colLabelW - 8 });
    y += rowH;
  });
  doc.y = y + 4;
}

function drawBarChart(doc, chart) {
  const F = doc._brandFonts;
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
    doc.fontSize(7.5).fillColor(INK).font(F.mono).text(fmtBRL(v), x - 8, y - 12, { width: barW + 16, align: 'center' });
    doc.fontSize(8).fillColor(MUTED).font(F.body).text(String(chart.labels[i]), x - 8, originY + 4, { width: barW + 16, align: 'center' });
  });

  doc.y = originY + 20;
  doc.fontSize(8).fillColor(MUTED).font(F.bodyItalic).text(chart.series[0].nome, PAGE_MARGIN, doc.y);
  doc.moveDown(0.5);
}

function renderCoverPage(doc, model) {
  const F = doc._brandFonts;
  const { width, height } = doc.page;
  doc.rect(0, 0, width, height).fill('#06263F');
  doc.rect(0, height - 180, width, 180).fill('#0A3654');

  if (LOGO_DARK_AVAILABLE) {
    // Proporção real do arquivo (1350x250) — largura fixa, altura calculada para nunca
    // distorcer a marca.
    doc.image(LOGO_DARK_PATH, PAGE_MARGIN, 78, { width: 230 });
  } else {
    doc.fillColor('#ffffff').font(F.display).fontSize(30).text('OPTIMON', PAGE_MARGIN, 90);
  }
  doc.fontSize(12).font(F.body).fillColor('#B8E8DF').text('Infraestrutura de Rede Óptica — Cessão de Rede', PAGE_MARGIN, 128);

  doc.fontSize(26).font(F.display).fillColor('#ffffff').text('Proposta Comercial', PAGE_MARGIN, 260, { width: width - 2 * PAGE_MARGIN });
  doc.fontSize(13).font(F.body).fillColor('#B8E8DF').text(model.modo === 'INTERNA' ? 'Documento de uso interno' : 'Documento para o parceiro', PAGE_MARGIN, 300);

  doc.fontSize(11).fillColor('#ffffff').font(F.bodySemibold);
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
    doc.font(F.bodySemibold).fontSize(10).fillColor('#B8E8DF').text(label.toUpperCase(), PAGE_MARGIN, y);
    doc.font(F.body).fontSize(13).fillColor('#ffffff').text(value, PAGE_MARGIN, y + 14);
    y += 42;
  });

  doc.fontSize(8).font(F.body).fillColor('#7FD4C1').text('Documento gerado automaticamente pelo OptiMon Pricing Engine.', PAGE_MARGIN, height - 30);
}

function renderSummary(doc, model) {
  const F = doc._brandFonts;
  sectionHeading(doc, 2, 'Sumário');
  doc.fontSize(9.5).font(F.body).fillColor(INK);
  model.sections.slice(1).forEach((s) => {
    doc.text(`${String(s.n).padStart(2, '0')}.  ${s.titulo}`);
  });
}

function renderSignature(doc, model) {
  const F = doc._brandFonts;
  doc.moveDown(1);
  ensureSpace(doc, 140);
  doc.fontSize(9.5).font(F.body).fillColor(INK).text(
    'A assinatura abaixo (física ou digital) formaliza o aceite desta proposta pelas partes. Esta seção fica preparada para integração futura com aceite digital.'
  );
  doc.moveDown(3);
  const y = doc.y;
  doc.moveTo(PAGE_MARGIN, y).lineTo(PAGE_MARGIN + 220, y).strokeColor(LINE).stroke();
  doc.moveTo(doc.page.width - PAGE_MARGIN - 220, y).lineTo(doc.page.width - PAGE_MARGIN, y).strokeColor(LINE).stroke();
  doc.fontSize(9).font(F.body).fillColor(MUTED).text('OptiMon', PAGE_MARGIN, y + 4);
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
    // Fase 3.8 (item 3.8-07): registra Manrope/Inter/IBM Plex Mono neste documento
    // (fontes de marca) — todas as funções de desenho abaixo leem doc._brandFonts em
    // vez de referenciar 'Helvetica*' diretamente. Guardado no próprio doc porque as
    // funções de desenho são módulo-level e recebem apenas `doc` como parâmetro.
    doc._brandFonts = resolveFonts(doc);

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
        doc.fontSize(10).font(doc._brandFonts.body).fillColor(INK).text(s.texto, { align: 'justify' });
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
