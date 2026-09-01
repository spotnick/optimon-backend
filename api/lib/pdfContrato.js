// OptiMon — Fase 3 (item 3.7): geração de PDF da MINUTA DE CONTRATO. pdfkit puro, mesmo
// padrão de pdfProposal.js (capa/header/footer/seções/tabelas) — arquivo próprio (não
// importa de pdfProposal.js) para nunca arriscar alterar o gerador de proposta, que já
// funciona e está testado.
//
// Fase 3.11.5 (item 4 do relato de produção: "após assinado o contrato deve ter como ser
// visualizado em PDF com todas as informações da assinatura"): generateContratoPdf agora
// aceita um 2º argumento opcional opts.certificado — quando presente, o MESMO motor (nunca
// um 2º gerador) reaproveita todo o conteúdo do contrato, troca a capa/rodapé do modo
// "MINUTA, não vinculante" para "ASSINADO ELETRONICAMENTE" e acrescenta uma página de
// CERTIFICADO DE ASSINATURA ELETRÔNICA (nome/CPF confirmados, e-mail, IP, data/hora,
// método, por signatário — dados vindos de app.assinatura_externa_certificado_dados,
// nunca inventados). Sem opts.certificado, o comportamento é idêntico ao de antes
// (usado para a minuta original, pré-assinatura).

const path = require('path');
const fs = require('fs');
const PDFDocument = require('pdfkit');
const { buildContractDocumentModel, fmtDate } = require('./contractDocumentModel');
const { resolveFonts } = require('./pdfFonts');

const LOGO_DARK_PATH = path.join(__dirname, '..', '..', 'web', 'public', 'branding', 'optimon-logo-lockup-dark.png');
const LOGO_ICON_PATH = path.join(__dirname, '..', '..', 'web', 'public', 'branding', 'optimon-icon-192.png');
const LOGO_DARK_AVAILABLE = fs.existsSync(LOGO_DARK_PATH);
const LOGO_ICON_AVAILABLE = fs.existsSync(LOGO_ICON_PATH);

// Fase 3.8 (item 1/2 — identidade visual): paleta oficial OptiMon. Antes desta
// correção usava marrom/terracota (#7c2d12), uma cor sem nenhuma relação com a
// marca real — a diferenciação visual entre minuta e proposta comercial (item
// intencional, preservado) agora usa o AZUL da paleta oficial (a proposta usa o
// TEAL, ver pdfProposal.js) — os dois dentro da mesma família de marca, nunca mais
// uma cor inventada. WARN/WARN_BG (âmbar) são cor semântica de alerta, separada de
// propósito do accent de marca — mantidas.
const INK = '#0F172A';
const MUTED = '#5b6b7f';
const ACCENT = '#2563EB';
const ACCENT_LIGHT = '#E5ECFD';
const WARN = '#b45309';
const WARN_BG = '#fef3c7';
const LINE = '#d8dee5';
const PAGE_MARGIN = 50;

function ensureSpace(doc, needed) {
  if (doc.y + needed > doc.page.height - 50) doc.addPage();
}

// Fase 3.11.5: no certificado de assinatura, a HORA importa (evidência, não só a
// data) — fmtDate (contractDocumentModel.js) só formata dia/mês/ano, reservado para o
// resto do documento; este helper local nunca substitui fmtDate, só complementa.
function fmtDateTime(v) {
  if (!v) return '—';
  const d = new Date(v);
  if (Number.isNaN(d.getTime())) return '—';
  return d.toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit', timeZoneName: 'short' });
}

function drawHeaderFooter(doc, model, pageIndex, pageCount, opts = {}) {
  const F = doc._brandFonts;
  const { width, height } = doc.page;
  const assinado = Boolean(opts.certificado);
  let textStartX = PAGE_MARGIN;
  if (LOGO_ICON_AVAILABLE) {
    doc.image(LOGO_ICON_PATH, PAGE_MARGIN, 18, { width: 14, height: 14 });
    textStartX = PAGE_MARGIN + 20;
  }
  doc.fontSize(8).fillColor(MUTED).font(F.bodySemibold)
    .text('OPTIMON', textStartX, 24, { continued: true })
    .font(F.body).fillColor(MUTED)
    .text(`  |  ${assinado ? 'Contrato Assinado' : 'Minuta de Contrato'} ${model.numero || ''} (V${model.numero_versao || 1})`, { continued: false });
  doc.fontSize(8).fillColor(assinado ? '#0e6e55' : WARN).font(F.bodySemibold)
    .text(assinado ? 'ASSINADO ELETRONICAMENTE' : 'PARA ANÁLISE JURÍDICA', width - PAGE_MARGIN - 200, 24, { width: 200, align: 'right' });
  doc.moveTo(PAGE_MARGIN, 38).lineTo(width - PAGE_MARGIN, 38).strokeColor(LINE).lineWidth(0.5).stroke();
  doc.moveTo(PAGE_MARGIN, height - 40).lineTo(width - PAGE_MARGIN, height - 40).strokeColor(LINE).lineWidth(0.5).stroke();
  // O texto do rodapé fica DENTRO da margem inferior da página (área reservada pelo
  // PDFDocument, margin:50) — chamar .text() ali dispara a paginação automática do
  // pdfkit (ele acha que o conteúdo não coube e insere uma página em branco extra).
  // Zera margins.bottom só durante este desenho pontual e restaura em seguida.
  const savedBottom = doc.page.margins.bottom;
  doc.page.margins.bottom = 0;
  const rodape = assinado
    ? `Gerado em ${fmtDate(new Date().toISOString())} — assinatura eletrônica simples, ver certificado no final deste documento`
    : `Gerado em ${fmtDate(new Date().toISOString())} — documento não assinado, não vinculante`;
  doc.fontSize(8).fillColor(MUTED).font(F.body)
    .text(rodape, PAGE_MARGIN, height - 30, { width: width - 2 * PAGE_MARGIN - 80 });
  doc.font(F.mono).text(`Página ${pageIndex + 1} de ${pageCount}`, width - PAGE_MARGIN - 80, height - 30, { width: 80, align: 'right' });
  doc.page.margins.bottom = savedBottom;
  doc.x = PAGE_MARGIN;
}

function sectionHeading(doc, n, titulo) {
  const F = doc._brandFonts;
  // doc.x pode ter ficado deslocado por uma tabela anterior (drawTableRows posiciona
  // células com x explícito, o que move o cursor doc.x para perto da margem direita) —
  // sempre resetar para a margem esquerda antes de qualquer novo bloco de texto.
  doc.x = PAGE_MARGIN;
  ensureSpace(doc, 40);
  doc.moveDown(0.6);
  doc.fontSize(9).fillColor(ACCENT).font(F.displayBold).text(`CLÁUSULA ${n}`, { continued: false });
  doc.fontSize(14).fillColor(INK).font(F.display).text(titulo);
  doc.moveTo(doc.x, doc.y + 2).lineTo(doc.page.width - PAGE_MARGIN, doc.y + 2).strokeColor(ACCENT).lineWidth(1.2).stroke();
  doc.moveDown(0.6);
}

// Fase 3.9 (seção 3 do modelo de cessão): a nova tabela "Detalhamento da Infraestrutura
// Cedida" tem 11 colunas (cidade/POP/rota/cabo/capacidade do cabo/recurso cedido/
// identificação/comprimento/postes/capacidade máxima/data início — exigidas
// explicitamente pelo prompt) — muito mais que as tabelas anteriores (aditivos,
// reajustes: 3-5 colunas). Com fonte/altura de linha fixas, 11 colunas ficariam
// ilegíveis (colunas de ~40pt de largura, texto cortado/sobreposto). Corrigido para: (a)
// reduzir a fonte quando há muitas colunas; (b) calcular a altura de cada linha a partir
// do texto que efetivamente mais quebra (doc.heightOfString), em vez de uma altura fixa —
// nunca sobrepondo texto entre linhas. Verificado visualmente (não só por não lançar
// erro) renderizando um PDF real e inspecionando o PNG resultante.
function drawTableRows(doc, rows) {
  const F = doc._brandFonts;
  const numCols = rows[0].length;
  const fontSize = numCols >= 9 ? 6.5 : numCols >= 7 ? 7.5 : 9;
  const colW = (doc.page.width - 2 * PAGE_MARGIN) / numCols;
  const cellPad = 4;
  doc.font(F.mono).fontSize(fontSize);
  const rowHeights = rows.map((cols) => Math.max(
    ...cols.map((val) => doc.heightOfString(String(val ?? '—'), { width: colW - 2 * cellPad }))
  ) + 2 * cellPad);
  ensureSpace(doc, Math.min(rowHeights.reduce((a, b) => a + b, 0), 200));
  let y = doc.y;
  rows.forEach((cols, i) => {
    const rowH = rowHeights[i];
    if (y + rowH > doc.page.height - 50) { doc.addPage(); y = doc.y; }
    if (i % 2 === 0) doc.rect(PAGE_MARGIN, y, doc.page.width - 2 * PAGE_MARGIN, rowH).fill(ACCENT_LIGHT);
    cols.forEach((val, ci) => {
      // Registro tipográfico "dado técnico" (IBM Plex Mono) — mesma decisão de
      // pdfProposal.js (ver comentário lá): tabelas de minuta (reajustes, ativos,
      // aditivos, infraestrutura) são majoritariamente numéricas/datas.
      doc.fillColor(INK).font(F.mono).fontSize(fontSize).text(String(val ?? '—'), PAGE_MARGIN + ci * colW + cellPad, y + cellPad, { width: colW - 2 * cellPad });
    });
    y += rowH;
  });
  doc.x = PAGE_MARGIN;
  doc.y = y + 4;
}

// Fase 3.9 (seção 30/capa do modelo de cessão): layout exigido — "OPTIMON" / "MINUTA DE
// CONTRATO DE CESSÃO ONEROSA DE USO DE INFRAESTRUTURA ÓPTICA" / "MINUTA PARA ANÁLISE E
// VALIDAÇÃO JURÍDICA" + campos NICK NETWORK / PARCEIRO / CIDADE(S) / Nº DO CONTRATO /
// VERSÃO / DATA. O banner âmbar "NÃO ASSINAR SEM REVISÃO DO JURÍDICO" da Fase 3.8 é
// mantido — é um complemento operacional ao aviso da capa, não uma duplicação (a capa
// nomeia O QUE é o documento; o banner instrui o QUE NÃO FAZER com ele).
function renderCoverPage(doc, model, opts = {}) {
  const F = doc._brandFonts;
  const { width, height } = doc.page;
  const assinado = Boolean(opts.certificado);
  const bandColor = assinado ? '#DCF3EA' : WARN_BG;
  const bandInk = assinado ? '#0e6e55' : WARN;
  doc.rect(0, 0, width, height).fill(ACCENT);
  doc.rect(0, height - 200, width, 200).fill(bandColor);
  // Texto sobre o retângulo de fundo claro — precisa de tinta escura para contraste,
  // nunca branco (diferente do restante da capa, que fica sobre o azul).
  doc.fillColor(bandInk).font(F.displayBold).fontSize(13).text(
    assinado ? 'DOCUMENTO ASSINADO ELETRONICAMENTE' : 'NÃO ASSINAR SEM REVISÃO DO JURÍDICO',
    PAGE_MARGIN, height - 180, { width: width - 2 * PAGE_MARGIN }
  );
  doc.fontSize(9).font(F.body).fillColor(INK).text(
    assinado
      ? 'Este documento foi assinado eletronicamente por todos os signatários obrigatórios através do OptiMon. É uma ASSINATURA ELETRÔNICA SIMPLES (link único enviado ao e-mail cadastrado + código de confirmação) — não é uma assinatura ICP-Brasil qualificada validada por Autoridade Certificadora. Ver página de certificado ao final para os detalhes de cada assinatura.'
      : 'Este documento é gerado automaticamente a partir dos dados do sistema OptiMon e não constitui, em nenhuma hipótese, um contrato definitivo ou vinculante até revisão e aprovação do departamento jurídico da NICK.',
    PAGE_MARGIN, height - 158, { width: width - 2 * PAGE_MARGIN }
  );

  if (LOGO_DARK_AVAILABLE) {
    doc.image(LOGO_DARK_PATH, PAGE_MARGIN, 60, { width: 200 });
  } else {
    doc.fillColor('#ffffff').font(F.display).fontSize(26).text('OPTIMON', PAGE_MARGIN, 78);
  }
  doc.fontSize(20).font(F.display).fillColor('#ffffff').text(
    `${assinado ? 'CONTRATO' : 'MINUTA'} DE CESSÃO ONEROSA DE USO DE INFRAESTRUTURA ÓPTICA`,
    PAGE_MARGIN, 130, { width: width - 2 * PAGE_MARGIN }
  );
  doc.fontSize(12).font(F.bodySemibold).fillColor('#C7DFF2').text(
    assinado ? 'ASSINADO ELETRONICAMENTE POR TODAS AS PARTES' : 'MINUTA PARA ANÁLISE E VALIDAÇÃO JURÍDICA',
    PAGE_MARGIN, doc.y + 8
  );

  const info = [
    ['NICK Network', 'Cedente'],
    ['Parceiro', model.parceiro_nome],
    ['Cidade(s)', `${model.cidade_nome || '—'} — ${model.cidade_uf || '—'}`],
    ['Nº do Contrato', model.numero || '—'],
    ['Versão', `V${model.numero_versao || 1}`],
    ['Data', fmtDate(new Date().toISOString())],
    ['Prazo', `${model.prazo_meses || '—'} meses`],
    ['Status atual', model.status],
  ];
  let y = Math.max(doc.y + 30, 300);
  info.forEach(([label, value]) => {
    doc.font(F.bodySemibold).fontSize(10).fillColor('#C7DFF2').text(label.toUpperCase(), PAGE_MARGIN, y);
    doc.font(F.body).fontSize(13).fillColor('#ffffff').text(String(value), PAGE_MARGIN, y + 14);
    y += 38;
  });
}

// Fase 3.11.5 (item 4 do relato de produção): página final de CERTIFICADO DE
// ASSINATURA ELETRÔNICA — um bloco por signatário, com exatamente os dados que
// app.assinatura_externa_certificado_dados devolve (nunca inventado, nunca enriquecido
// além do que o banco realmente registrou no momento da assinatura).
function renderCertificatePage(doc, model, certificado) {
  const F = doc._brandFonts;
  doc.x = PAGE_MARGIN;
  doc.moveDown(0.6);
  doc.fontSize(9).fillColor(ACCENT).font(F.displayBold).text('CERTIFICADO', { continued: false });
  doc.fontSize(14).fillColor(INK).font(F.display).text('Certificado de Assinatura Eletrônica');
  doc.moveTo(doc.x, doc.y + 2).lineTo(doc.page.width - PAGE_MARGIN, doc.y + 2).strokeColor(ACCENT).lineWidth(1.2).stroke();
  doc.moveDown(0.8);

  doc.fontSize(9.5).font(F.body).fillColor(INK).text(
    'Este é um certificado de ASSINATURA ELETRÔNICA SIMPLES, gerado pelo OptiMon — evidenciada por um link único enviado ao e-mail cadastrado de cada signatário, seguido de um código de confirmação (OTP) de 6 dígitos enviado ao mesmo e-mail, com IP e data/hora de cada etapa registrados. NÃO é uma assinatura ICP-Brasil qualificada validada por Autoridade Certificadora.',
    { align: 'justify' }
  );
  doc.moveDown(0.6);

  const linhaMeta = [
    ['ID do envelope', certificado.envelope_id || '—'],
    ['Provedor', certificado.provider_nome || '—'],
    ['Hash SHA-256 do documento original', certificado.hash_original || '—'],
    ['Criado em', fmtDateTime(certificado.criado_em)],
    ['Concluído em', fmtDateTime(certificado.concluido_em)],
  ];
  linhaMeta.forEach(([label, value]) => {
    ensureSpace(doc, 16);
    doc.font(F.bodySemibold).fontSize(8.5).fillColor(MUTED).text(`${label}: `, { continued: true }).font(F.mono).fillColor(INK).text(String(value));
  });
  doc.moveDown(0.8);

  (certificado.signatarios || []).forEach((s, idx) => {
    ensureSpace(doc, 120);
    doc.x = PAGE_MARGIN;
    doc.rect(PAGE_MARGIN, doc.y, doc.page.width - 2 * PAGE_MARGIN, 1).fill(LINE);
    doc.moveDown(0.5);
    doc.font(F.bodySemibold).fontSize(11).fillColor(INK).text(`${idx + 1}. ${s.nome || '—'} (${s.papel || '—'})`);
    const info = s.certificado_info || {};
    const status = s.status === 'ASSINADO' ? 'ASSINOU' : s.status === 'RECUSADO' ? 'RECUSOU' : s.status;
    const campos = [
      ['Status', status],
      ['E-mail', s.email || '—'],
      ['CPF confirmado', info.documento_confirmado || '—'],
      ['Data/hora', fmtDateTime(s.assinado_em)],
      ['Endereço IP', s.ip_assinatura || '—'],
      ['Navegador/dispositivo', info.user_agent || '—'],
      ['Método', info.metodo || '—'],
    ];
    campos.forEach(([label, value]) => {
      ensureSpace(doc, 14);
      doc.font(F.bodySemibold).fontSize(8.5).fillColor(MUTED).text(`${label}: `, PAGE_MARGIN + 10, doc.y, { continued: true }).font(F.mono).fillColor(INK).text(String(value));
    });
    doc.moveDown(0.6);
  });
}

function renderSignature(doc, model, opts = {}) {
  const F = doc._brandFonts;
  const assinado = Boolean(opts.certificado);
  doc.moveDown(1);
  ensureSpace(doc, 140);
  doc.fontSize(9.5).font(F.body).fillColor(INK).text(
    assinado
      ? 'Este documento foi assinado eletronicamente por todas as partes — ver a página de CERTIFICADO DE ASSINATURA ELETRÔNICA ao final deste documento para os detalhes de cada assinatura (nome, CPF confirmado, e-mail, IP e data/hora).'
      : 'Este espaço está reservado para assinatura das partes SOMENTE após a revisão e aprovação jurídica desta minuta e a inclusão de todas as cláusulas pendentes indicadas ao longo deste documento.'
  );
  doc.moveDown(3);
  const y = doc.y;
  doc.moveTo(PAGE_MARGIN, y).lineTo(PAGE_MARGIN + 220, y).strokeColor(LINE).stroke();
  doc.moveTo(doc.page.width - PAGE_MARGIN - 220, y).lineTo(doc.page.width - PAGE_MARGIN, y).strokeColor(LINE).stroke();
  doc.fontSize(9).font(F.body).fillColor(MUTED).text(assinado ? 'OptiMon (NICK) — assinado' : 'OptiMon (NICK)', PAGE_MARGIN, y + 4);
  doc.text(assinado ? `${model.parceiro_nome} — assinado` : model.parceiro_nome, doc.page.width - PAGE_MARGIN - 220, y + 4, { width: 220, align: 'right' });
  doc.x = PAGE_MARGIN;
}

async function generateContratoPdf(dados, opts = {}) {
  const model = buildContractDocumentModel(dados);
  const assinado = Boolean(opts.certificado);

  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'A4', margin: PAGE_MARGIN, bufferPages: true, info: {
      Title: `${assinado ? 'Contrato Assinado' : 'Minuta de Contrato'} ${model.numero || ''}`,
      Author: 'OptiMon',
      Subject: `${assinado ? 'ASSINADO ELETRONICAMENTE' : 'MINUTA PARA ANÁLISE JURÍDICA'} — ${model.cidade_nome || ''}`,
    } });
    // Fase 3.8 (item 3.8-07): registra Manrope/Inter/IBM Plex Mono neste documento —
    // ver comentário equivalente em pdfProposal.js.
    doc._brandFonts = resolveFonts(doc);
    const F = doc._brandFonts;

    const chunks = [];
    doc.on('data', (c) => chunks.push(c));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);

    renderCoverPage(doc, model, opts);
    doc.addPage();

    model.sections.filter((s) => s.n > 0).forEach((s) => {
      sectionHeading(doc, s.n, s.titulo);
      if (s.tipo === 'tabela') {
        drawTableRows(doc, s.linhas);
      } else if (s.tipo === 'assinatura') {
        renderSignature(doc, model, opts);
      } else if (s.texto) {
        const isPlaceholder = s.texto.startsWith('[CLÁUSULA-MODELO');
        if (isPlaceholder) doc.fillColor(WARN);
        doc.fontSize(10).font(isPlaceholder ? F.bodyItalic : F.body).fillColor(isPlaceholder ? WARN : INK).text(s.texto, { align: 'justify' });
      }
    });

    if (assinado) {
      doc.addPage();
      renderCertificatePage(doc, model, opts.certificado);
    }

    const range = doc.bufferedPageRange();
    for (let i = 0; i < range.count; i++) {
      doc.switchToPage(range.start + i);
      drawHeaderFooter(doc, model, i, range.count, opts);
    }

    doc.end();
  });
}

module.exports = { generateContratoPdf };
