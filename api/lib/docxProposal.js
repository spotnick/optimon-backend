// OptiMon — Fase 2.4 (seção 9/39): geração de DOCX editável da proposta comercial.
// Pacote `docx` puro-JS — mesma estrutura de 28 seções do PDF (proposalDocumentModel.js),
// com capa, cabeçalho/rodapé com numeração de página, e tabelas. Os 4 "gráficos" (seção
// 14) são representados como TABELAS DE DADOS editáveis — o pacote `docx` não tem suporte
// nativo a gráficos vetoriais sem dependência nativa (canvas), e o objetivo declarado do
// DOCX é ser editável pelo comercial; uma tabela com os mesmos números é mais útil nesse
// contexto do que uma imagem estática, e mantém a build 100% livre de dependência nativa
// (mesma decisão arquitetural do PDF via pdfkit). O PDF continua sendo a versão com os
// gráficos desenhados como vetor.

const path = require('path');
const fs = require('fs');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, Table, TableRow, TableCell,
  WidthType, Header, Footer, PageNumber, AlignmentType, BorderStyle, ShadingType, ImageRun,
} = require('docx');
const { buildProposalDocumentModel, fmtBRL, fmtPct, fmtInt, fmtDate } = require('./proposalDocumentModel');

// Fase 3 (item 3.5): logo real da OptiMon na capa do DOCX (assets gerados pelo projeto,
// ver item 3.4 — web/public/branding/). Nunca falha a geração se o arquivo não existir —
// cai de volta para o texto "OPTIMON" simples, como era antes desta correção.
const LOGO_PATH = path.join(__dirname, '..', '..', 'web', 'public', 'branding', 'optimon-logo-lockup.png');
const LOGO_AVAILABLE = fs.existsSync(LOGO_PATH);
const LOGO_ASPECT = 1350 / 250; // proporção real do arquivo gerado (item 3.4) — nunca distorcer.

// Fase 3.8 (item 1/2 — identidade visual): paleta oficial OptiMon (mesma do PDF de
// proposta, pdfProposal.js) — antes usava um verde inventado (0E6E55) sem relação
// com a marca real (frontend/logo).
const ACCENT = '0D9488';
const ACCENT_LIGHT = 'E1F5F1';
const INK = '06263F';
const MUTED = '5B6B7F';

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
    children: [new Paragraph({ children: [new TextRun({ text: String(text), bold, color })] })],
  });
}

function dataTable(rows) {
  return new Table({
    width: { size: 100, type: WidthType.PERCENTAGE },
    rows: rows.map(([label, value], i) => new TableRow({
      children: [
        cell(label, { bold: true, shade: i % 2 === 0, width: 40 }),
        cell(value, { shade: i % 2 === 0, width: 60 }),
      ],
    })),
  });
}

function chartAsTable(chart) {
  const header = new TableRow({
    children: [cell(chart.tipo === 'barras' ? 'Categoria' : 'Período', { bold: true, shade: true, width: 40 }), cell(chart.series[0].nome, { bold: true, shade: true, width: 60 })],
  });
  const rows = chart.labels.map((label, i) => new TableRow({
    children: [cell(label, { width: 40 }), cell(fmtBRL(chart.series[0].valores[i]), { width: 60 })],
  }));
  return new Table({ width: { size: 100, type: WidthType.PERCENTAGE }, rows: [header, ...rows] });
}

function sectionHeading(n, titulo) {
  return [
    new Paragraph({ text: `SEÇÃO ${n}`, spacing: { before: 240, after: 20 }, run: { size: 16, color: ACCENT, bold: true } }),
    new Paragraph({ text: titulo, heading: HeadingLevel.HEADING_1, spacing: { after: 160 } }),
  ];
}

function paragraphsFor(section) {
  const out = sectionHeading(section.n, section.titulo);
  if (section.tipo === 'tabela') {
    out.push(dataTable(section.linhas));
  } else if (section.tipo === 'cenario') {
    out.push(dataTable([
      ['Clientes', fmtInt(section.cenario.clientes)],
      ['Faturamento mensal', fmtBRL(section.cenario.faturamento)],
      ['Total mensal pago à OptiMon', fmtBRL(section.cenario.total_payable)],
      ['Receita mensal do parceiro', fmtBRL(section.cenario.partner_revenue)],
      ['Margem do parceiro', fmtPct(section.cenario.partner_margin)],
    ]));
  } else if (section.tipo === 'projecao') {
    out.push(dataTable([
      ['Horizonte', section.projecao.rotulo],
      ['Receita bruta acumulada', fmtBRL(section.projecao.receita_bruta_acumulada)],
      ['Total pago à OptiMon (acumulado)', fmtBRL(section.projecao.total_pago_optimon_acumulado)],
      ['Receita do parceiro (acumulado)', fmtBRL(section.projecao.receita_parceiro_acumulada)],
    ]));
  } else if (section.tipo === 'grafico') {
    out.push(new Paragraph({ text: 'Dados do gráfico (versão em PDF apresenta a visualização vetorial):', spacing: { after: 80 }, run: { italics: true, color: MUTED, size: 18 } }));
    out.push(chartAsTable(section.grafico));
  } else if (section.tipo === 'assinatura') {
    out.push(new Paragraph({ text: 'A assinatura abaixo (física ou digital) formaliza o aceite desta proposta pelas partes. Esta seção fica preparada para integração futura com aceite digital.', spacing: { after: 400 } }));
    out.push(dataTable([['OptiMon', '_______________________'], ['Parceiro', '_______________________']]));
  } else if (section.texto) {
    out.push(new Paragraph({ text: section.texto, alignment: AlignmentType.JUSTIFIED }));
  }
  return out;
}

async function generateProposalDocx(proposta, opts = {}) {
  const model = buildProposalDocumentModel(proposta, opts);

  const header = new Header({
    children: [new Paragraph({
      children: [
        new TextRun({ text: 'OPTIMON', bold: true, color: MUTED, size: 16 }),
        new TextRun({ text: `  |  Proposta Comercial ${model.numero || ''} (V${model.numero_versao || 1})  |  ${model.modo === 'INTERNA' ? 'USO INTERNO' : 'PROPOSTA'}`, color: MUTED, size: 16 }),
      ],
      border: { bottom: { style: BorderStyle.SINGLE, size: 4, color: 'D8DEE5', space: 4 } },
    })],
  });

  const footer = new Footer({
    children: [new Paragraph({
      alignment: AlignmentType.RIGHT,
      children: [
        new TextRun({ text: `Válido até ${fmtDate(model.data_validade)}   —   Página `, color: MUTED, size: 16 }),
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

  const capa = [
    logoParagraph,
    new Paragraph({ text: 'Infraestrutura de Rede Óptica — Cessão de Rede', spacing: { after: 400 }, run: { size: 22, color: MUTED } }),
    new Paragraph({ text: 'Proposta Comercial', heading: HeadingLevel.TITLE, spacing: { after: 80 } }),
    new Paragraph({ text: model.modo === 'INTERNA' ? 'Documento de uso interno' : 'Documento para o parceiro', spacing: { after: 400 }, run: { size: 24, color: MUTED } }),
    dataTable([
      ['Número', `${model.numero || '—'} (V${model.numero_versao || 1})`],
      ['Cidade', `${model.cidade_nome || '—'} — ${model.cidade_uf || '—'}`],
      ['Parceiro', model.parceiro_nome],
      ['Data', fmtDate(model.criado_em)],
      ['Validade', `${model.validade_dias} dias (até ${fmtDate(model.data_validade)})`],
      ['Status', model.status_label],
    ]),
    new Paragraph({ text: '', pageBreakBefore: true }),
  ];

  const sumario = [
    new Paragraph({ text: 'Sumário', heading: HeadingLevel.HEADING_1, spacing: { after: 200 } }),
    ...model.sections.slice(1).map((s) => new Paragraph({ text: `${String(s.n).padStart(2, '0')}.  ${s.titulo}` })),
    new Paragraph({ text: '', pageBreakBefore: true }),
  ];

  const corpo = model.sections.slice(2).flatMap((s) => paragraphsFor(s));

  const doc = new Document({
    creator: 'OptiMon',
    title: `Proposta Comercial ${model.numero || ''}`,
    sections: [{
      properties: {},
      headers: { default: header },
      footers: { default: footer },
      children: [...capa, ...sumario, ...corpo],
    }],
  });

  return Packer.toBuffer(doc);
}

module.exports = { generateProposalDocx };
