// OptiMon — Fase 3 (item 3.7): geração de DOCX editável da MINUTA DE CONTRATO.
// Mesma arquitetura de docxProposal.js (pacote `docx` puro-JS, capa/sumário/corpo,
// cabeçalho+rodapé com numeração), mas arquivo próprio — nunca importa nem altera
// docxProposal.js, que já está em produção e testado.
//
// Diferença estrutural: as tabelas da minuta (reajustes, ativos, aditivos) têm entre 2 e 5
// colunas de dados "linha a linha", não pares label/valor — por isso este arquivo usa um
// dataTableGeneric(linhas) próprio em vez do dataTable(label,valor) da proposta.

const path = require('path');
const fs = require('fs');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, Table, TableRow, TableCell,
  WidthType, Header, Footer, PageNumber, AlignmentType, BorderStyle, ShadingType, ImageRun,
} = require('docx');
const { buildContractDocumentModel, fmtDate } = require('./contractDocumentModel');

const LOGO_PATH = path.join(__dirname, '..', '..', 'web', 'public', 'branding', 'optimon-logo-lockup.png');
const LOGO_AVAILABLE = fs.existsSync(LOGO_PATH);
const LOGO_ASPECT = 695 / 195; // proporção real do PNG oficial (pacote de marca, Fase 3.9) — nunca distorcer.

// Fase 3.8 (item 1/2 — identidade visual): paleta oficial OptiMon, igual ao
// pdfContrato.js. Antes usava marrom/terracota (7C2D12), sem relação com a marca
// real — a diferenciação visual entre minuta e proposta comercial (preservada)
// agora usa o AZUL oficial (a proposta usa o TEAL, ver docxProposal.js), os dois
// dentro da mesma família de marca.
const ACCENT = '2563EB';
const ACCENT_LIGHT = 'E5ECFD';
const INK = '0F172A';
const MUTED = '5B6B7F';
const WARN = 'B45309';

function noBorders() {
  const b = { style: BorderStyle.NONE, size: 0, color: 'FFFFFF' };
  return { top: b, bottom: b, left: b, right: b };
}

function cell(text, { bold = false, shade = false, color = INK, width } = {}) {
  return new TableCell({
    width: width ? { size: width, type: WidthType.PERCENTAGE } : undefined,
    shading: shade ? { type: ShadingType.CLEAR, fill: ACCENT_LIGHT } : undefined,
    borders: noBorders(),
    margins: { top: 80, bottom: 80, left: 100, right: 100 },
    children: [new Paragraph({ children: [new TextRun({ text: String(text ?? '—'), bold, color })] })],
  });
}

// Tabela label/valor (2 colunas) — usada na capa e em campos avulsos.
function dataTable(rows) {
  return new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    rows: rows.map(([label, value], i) => new TableRow({
      children: [cell(label, { bold: true, shade: i % 2 === 0, width: 40 }), cell(value, { shade: i % 2 === 0, width: 60 })],
    })),
  });
}

// Tabela de N colunas (linhas cruas, sem cabeçalho de nomes — o mesmo formato de
// api/lib/contractDocumentModel.js's pushTabela, que já produz arrays de valores prontos
// para exibição).
function dataTableGeneric(linhas) {
  const cols = linhas[0].length;
  const width = Math.floor(100 / cols);
  return new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    rows: linhas.map((cols_, i) => new TableRow({
      children: cols_.map((v) => cell(v, { shade: i % 2 === 0, width })),
    })),
  });
}

function sectionHeading(n, titulo) {
  return [
    new Paragraph({ text: `CLÁUSULA ${n}`, spacing: { before: 240, after: 20 }, run: { size: 16, color: ACCENT, bold: true } }),
    new Paragraph({ text: titulo, heading: HeadingLevel.HEADING_1, spacing: { after: 160 } }),
  ];
}

function paragraphsFor(section) {
  const out = sectionHeading(section.n, section.titulo);
  if (section.tipo === 'tabela') {
    out.push(dataTableGeneric(section.linhas));
  } else if (section.tipo === 'assinatura') {
    out.push(new Paragraph({
      text: 'Este espaço está reservado para assinatura das partes SOMENTE após a revisão e aprovação jurídica desta minuta e a inclusão de todas as cláusulas pendentes indicadas ao longo deste documento.',
      spacing: { after: 400 },
    }));
    out.push(dataTable([['OptiMon (NICK)', '_______________________'], ['Parceiro', '_______________________']]));
  } else if (section.texto) {
    const isPlaceholder = section.texto.startsWith('[CLÁUSULA-MODELO');
    out.push(new Paragraph({
      alignment: AlignmentType.JUSTIFIED,
      children: [new TextRun({ text: section.texto, italics: isPlaceholder, color: isPlaceholder ? WARN : INK })],
    }));
  }
  return out;
}

async function generateContratoDocx(dados) {
  const model = buildContractDocumentModel(dados);

  const header = new Header({
    children: [new Paragraph({
      children: [
        new TextRun({ text: 'OPTIMON', bold: true, color: MUTED, size: 16 }),
        new TextRun({ text: `  |  Minuta de Contrato ${model.numero || ''} (V${model.numero_versao || 1})  |  `, color: MUTED, size: 16 }),
        new TextRun({ text: 'SUJEITA À APROVAÇÃO JURÍDICA', bold: true, color: WARN, size: 16 }),
      ],
      border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: 'D8DEE5', space: 4 } },
    })],
  });

  const footer = new Footer({
    children: [new Paragraph({
      alignment: AlignmentType.RIGHT,
      children: [
        new TextRun({ text: `Gerado em ${fmtDate(new Date().toISOString())} — não assinado, não vinculante   —   Página `, color: MUTED, size: 16 }),
        new TextRun({ children: [PageNumber.CURRENT], color: MUTED, size: 16 }),
        new TextRun({ text: ' de ', color: MUTED, size: 16 }),
        new TextRun({ children: [PageNumber.TOTAL_PAGES], color: MUTED, size: 16 }),
      ],
    })],
  });

  const logoParagraph = LOGO_AVAILABLE
    ? new Paragraph({
        spacing: { after: 120 },
        children: [new ImageRun({
          data: fs.readFileSync(LOGO_PATH),
          transformation: { width: 260, height: Math.round(260 / LOGO_ASPECT) },
          type: 'png',
        })],
      })
    : new Paragraph({ text: 'OPTIMON', spacing: { after: 40 }, run: { size: 56, bold: true, color: ACCENT } });

  const avisoJuridico = new Paragraph({
    spacing: { after: 300 },
    shading: { type: ShadingType.CLEAR, fill: 'FEF3C7' },
    children: [new TextRun({
      text: 'MINUTA PARA ANÁLISE JURÍDICA — NÃO ASSINAR SEM REVISÃO DO JURÍDICO. Este documento é gerado automaticamente a partir dos dados do sistema OptiMon e não constitui, em nenhuma hipótese, um contrato definitivo ou vinculante até revisão e aprovação do departamento jurídico da NICK.',
      bold: true, color: WARN, size: 20,
    })],
  });

  const capa = [
    logoParagraph,
    new Paragraph({ text: 'Cessão de Infraestrutura de Rede Óptica', spacing: { after: 300 }, run: { size: 22, color: MUTED } }),
    new Paragraph({ text: 'Minuta de Contrato', heading: HeadingLevel.TITLE, spacing: { after: 200 } }),
    avisoJuridico,
    dataTable([
      ['Número', `${model.numero || '—'} (V${model.numero_versao || 1})`],
      ['Parceiro', model.parceiro_nome],
      ['Cidade', `${model.cidade_nome || '—'} — ${model.cidade_uf || '—'}`],
      ['Prazo', `${model.prazo_meses || '—'} meses`],
      ['Status atual', model.status],
      ['Gerado em', fmtDate(new Date().toISOString())],
    ]),
    new Paragraph({ text: '', pageBreakBefore: true }),
  ];

  const sumario = [
    new Paragraph({ text: 'Sumário', heading: HeadingLevel.HEADING_1, spacing: { after: 200 } }),
    ...model.sections.filter((s) => s.n > 0).map((s) => new Paragraph({ text: `${String(s.n).padStart(2, '0')}.  ${s.titulo}` })),
    new Paragraph({ text: '', pageBreakBefore: true }),
  ];

  const corpo = model.sections.filter((s) => s.n > 0).flatMap((s) => paragraphsFor(s));

  const doc = new Document({
    creator: 'OptiMon',
    title: `Minuta de Contrato ${model.numero || ''}`,
    sections: [{
      properties: {},
      headers: { default: header },
      footers: { default: footer },
      children: [...capa, ...sumario, ...corpo],
    }],
  });

  return Packer.toBuffer(doc);
}

module.exports = { generateContratoDocx };
