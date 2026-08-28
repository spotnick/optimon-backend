// OptiMon — Fase 3 (item 3.7): geração de PDF da MINUTA DE CONTRATO. pdfkit puro, mesmo
// padrão de pdfProposal.js (capa/header/footer/seções/tabelas) — arquivo próprio (não
// importa de pdfProposal.js) para nunca arriscar alterar o gerador de proposta, que já
// funciona e está testado.

const path = require('path');
const fs = require('fs');
const PDFDocument = require('pdfkit');
const { buildContractDocumentModel, fmtDate } = require('./contractDocumentModel');

const LOGO_DARK_PATH = path.join(__dirname, '..', '..', 'web', 'public', 'branding', 'optimon-logo-lockup-dark.png');
const LOGO_ICON_PATH = path.join(__dirname, '..', '..', 'web', 'public', 'branding', 'optimon-icon-192.png');
const LOGO_DARK_AVAILABLE = fs.existsSync(LOGO_DARK_PATH);
const LOGO_ICON_AVAILABLE = fs.existsSync(LOGO_ICON_PATH);

const INK = '#1a2332';
const MUTED = '#5b6b7f';
const ACCENT = '#7c2d12'; // marrom/terracota — deliberadamente distinto do verde da proposta comercial, para nunca confundir os dois documentos visualmente.
const ACCENT_LIGHT = '#fdf1ea';
const WARN = '#b45309';
const WARN_BG = '#fef3c7';
const LINE = '#d8dee5';
const PAGE_MARGIN = 50;

function ensureSpace(doc, needed) {
  if (doc.y + needed > doc.page.height - 50) doc.addPage();
}

function drawHeaderFooter(doc, model, pageIndex, pageCount) {
  const { width, height } = doc.page;
  let textStartX = PAGE_MARGIN;
  if (LOGO_ICON_AVAILABLE) {
    doc.image(LOGO_ICON_PATH, PAGE_MARGIN, 18, { width: 14, height: 14 });
    textStartX = PAGE_MARGIN + 20;
  }
  doc.fontSize(8).fillColor(MUTED).font('Helvetica-Bold')
    .text('OPTIMON', textStartX, 24, { continued: true })
    .font('Helvetica').fillColor(MUTED)
    .text(`  |  Minuta de Contrato ${model.numero || ''} (V${model.numero_versao || 1})`, { continued: false });
  doc.fontSize(8).fillColor(WARN).font('Helvetica-Bold')
    .text('SUJEITA À APROVAÇÃO JURÍDICA', width - PAGE_MARGIN - 200, 24, { width: 200, align: 'right' });
  doc.moveTo(PAGE_MARGIN, 38).lineTo(width - PAGE_MARGIN, 38).strokeColor(LINE).lineWidth(0.5).stroke();
  doc.moveTo(PAGE_MARGIN, height - 40).lineTo(width - PAGE_MARGIN, height - 40).strokeColor(LINE).lineWidth(0.5).stroke();
  // O texto do rodapé fica DENTRO da margem inferior da página (área reservada pelo
  // PDFDocument, margin:50) — chamar .text() ali dispara a paginação automática do
  // pdfkit (ele acha que o conteúdo não coube e insere uma página em branco extra).
  // Zera margins.bottom só durante este desenho pontual e restaura em seguida.
  const savedBottom = doc.page.margins.bottom;
  doc.page.margins.bottom = 0;
  doc.fontSize(8).fillColor(MUTED)
    .text(`Gerado em ${fmtDate(new Date().toISOString())} — documento não assinado, não vinculante`, PAGE_MARGIN, height - 30, { width: width - 2 * PAGE_MARGIN - 80 });
  doc.text(`Página ${pageIndex + 1} de ${pageCount}`, width - PAGE_MARGIN - 80, height - 30, { width: 80, align: 'right' });
  doc.page.margins.bottom = savedBottom;
  doc.x = PAGE_MARGIN;
}

function sectionHeading(doc, n, titulo) {
  // doc.x pode ter ficado deslocado por uma tabela anterior (drawTableRows posiciona
  // células com x explícito, o que move o cursor doc.x para perto da margem direita) —
  // sempre resetar para a margem esquerda antes de qualquer novo bloco de texto.
  doc.x = PAGE_MARGIN;
  ensureSpace(doc, 40);
  doc.moveDown(0.6);
  doc.fontSize(9).fillColor(ACCENT).font('Helvetica-Bold').text(`CLÁUSULA ${n}`, { continued: false });
  doc.fontSize(14).fillColor(INK).font('Helvetica-Bold').text(titulo);
  doc.moveTo(doc.x, doc.y + 2).lineTo(doc.page.width - PAGE_MARGIN, doc.y + 2).strokeColor(ACCENT).lineWidth(1.2).stroke();
  doc.moveDown(0.6);
}

function drawTableRows(doc, rows) {
  const rowH = 20;
  const colW = (doc.page.width - 2 * PAGE_MARGIN) / rows[0].length;
  ensureSpace(doc, rows.length * rowH + 10);
  let y = doc.y;
  rows.forEach((cols, i) => {
    if (y + rowH > doc.page.height - 50) { doc.addPage(); y = doc.y; }
    if (i % 2 === 0) doc.rect(PAGE_MARGIN, y, doc.page.width - 2 * PAGE_MARGIN, rowH).fill(ACCENT_LIGHT);
    cols.forEach((val, ci) => {
      doc.fillColor(INK).font('Helvetica').fontSize(9).text(String(val ?? '—'), PAGE_MARGIN + ci * colW + 6, y + 5, { width: colW - 8 });
    });
    y += rowH;
  });
  doc.x = PAGE_MARGIN;
  doc.y = y + 4;
}

function renderCoverPage(doc, model) {
  const { width, height } = doc.page;
  doc.rect(0, 0, width, height).fill('#7c2d12');
  doc.rect(0, height - 200, width, 200).fill(WARN_BG);
  doc.fillColor('#7c2d12').font('Helvetica-Bold').fontSize(13).text('MINUTA SUJEITA À APROVAÇÃO JURÍDICA — NÃO ASSINAR SEM REVISÃO', PAGE_MARGIN, height - 180, { width: width - 2 * PAGE_MARGIN });
  doc.fontSize(9).font('Helvetica').fillColor('#7c2d12').text('Este documento é gerado automaticamente a partir dos dados do sistema OptiMon e não constitui, em nenhuma hipótese, um contrato definitivo ou vinculante até revisão e aprovação do departamento jurídico da NICK.', PAGE_MARGIN, height - 158, { width: width - 2 * PAGE_MARGIN });

  if (LOGO_DARK_AVAILABLE) {
    doc.image(LOGO_DARK_PATH, PAGE_MARGIN, 70, { width: 220 });
  } else {
    doc.fillColor('#ffffff').font('Helvetica-Bold').fontSize(28).text('OPTIMON', PAGE_MARGIN, 90);
  }
  doc.fontSize(26).font('Helvetica-Bold').fillColor('#ffffff').text('Minuta de Contrato', PAGE_MARGIN, 250, { width: width - 2 * PAGE_MARGIN });
  doc.fontSize(12).font('Helvetica').fillColor('#fde3d3').text('Cessão de Infraestrutura de Rede Óptica', PAGE_MARGIN, 288);

  const info = [
    ['Número', `${model.numero || '—'} (V${model.numero_versao || 1})`],
    ['Parceiro', model.parceiro_nome],
    ['Cidade', `${model.cidade_nome || '—'} — ${model.cidade_uf || '—'}`],
    ['Prazo', `${model.prazo_meses || '—'} meses`],
    ['Status atual', model.status],
    ['Gerado em', fmtDate(new Date().toISOString())],
  ];
  let y = 340;
  info.forEach(([label, value]) => {
    doc.font('Helvetica-Bold').fontSize(10).fillColor('#fde3d3').text(label.toUpperCase(), PAGE_MARGIN, y);
    doc.font('Helvetica').fontSize(13).fillColor('#ffffff').text(String(value), PAGE_MARGIN, y + 14);
    y += 40;
  });
}

function renderSignature(doc, model) {
  doc.moveDown(1);
  ensureSpace(doc, 140);
  doc.fontSize(9.5).font('Helvetica').fillColor(INK).text(
    'Este espaço está reservado para assinatura das partes SOMENTE após a revisão e aprovação jurídica desta minuta e a inclusão de todas as cláusulas pendentes indicadas ao longo deste documento.'
  );
  doc.moveDown(3);
  const y = doc.y;
  doc.moveTo(PAGE_MARGIN, y).lineTo(PAGE_MARGIN + 220, y).strokeColor(LINE).stroke();
  doc.moveTo(doc.page.width - PAGE_MARGIN - 220, y).lineTo(doc.page.width - PAGE_MARGIN, y).strokeColor(LINE).stroke();
  doc.fontSize(9).fillColor(MUTED).text('OptiMon (NICK)', PAGE_MARGIN, y + 4);
  doc.text(model.parceiro_nome, doc.page.width - PAGE_MARGIN - 220, y + 4, { width: 220, align: 'right' });
  doc.x = PAGE_MARGIN;
}

async function generateContratoPdf(dados) {
  const model = buildContractDocumentModel(dados);

  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: PAGE_MARGIN, bufferPages: true, info: {
      Title: `Minuta de Contrato ${model.numero || ''}`,
      Author: 'OptiMon',
      Subject: `MINUTA SUJEITA A APROVAÇÃO JURÍDICA — ${model.cidade_nome || ''}`,
    } });
    const chunks = [];
    doc.on('data', (c) => chunks.push(c));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);

    renderCoverPage(doc, model);
    doc.addPage();

    model.sections.filter((s) => s.n > 0).forEach((s) => {
      sectionHeading(doc, s.n, s.titulo);
      if (s.tipo === 'tabela') {
        drawTableRows(doc, s.linhas);
      } else if (s.tipo === 'assinatura') {
        renderSignature(doc, model);
      } else if (s.texto) {
        const isPlaceholder = s.texto.startsWith('[CLÁUSULA-MODELO');
        if (isPlaceholder) doc.fillColor(WARN);
        doc.fontSize(10).font(isPlaceholder ? 'Helvetica-Oblique' : 'Helvetica').fillColor(isPlaceholder ? WARN : INK).text(s.texto, { align: 'justify' });
      }
    });

    const range = doc.bufferedPageRange();
    for (let i = 0; i < range.count; i++) {
      doc.switchToPage(range.start + i);
      drawHeaderFooter(doc, model, i, range.count);
    }

    doc.end();
  });
}

module.exports = { generateContratoPdf };
