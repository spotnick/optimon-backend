// OptiMon — Fase 3.8 (item 3.8-07): tipografia oficial da marca nos PDFs gerados
// (proposta comercial e minuta de contrato). Antes desta correção pdfProposal.js e
// pdfContrato.js usavam exclusivamente as fontes internas do pdfkit (Helvetica), que
// não têm nenhuma relação com a identidade visual real do OptiMon — o frontend usa
// Manrope (títulos/display), Inter (corpo) e IBM Plex Mono (dados técnicos/numéricos),
// carregadas via Google Fonts em web/index.html.
//
// pdfkit não sabe baixar fontes do Google Fonts em tempo de execução — as mesmas 3
// famílias foram baixadas uma única vez (pacotes @fontsource/*, subset latin, convertidas
// de woff para ttf com fontTools) e ficam versionadas em api/assets/fonts/. Cobertura de
// acentuação PT-BR (áéíóúãõâêôçàü + maiúsculas) foi conferida nas 3 famílias antes de
// serem incluídas — nenhum glifo faltando.
//
// Pesos escolhidos (mínimo necessário, para manter o pacote pequeno):
//   Manrope 700/800   → títulos, capa, headings de seção/cláusula (papel "display")
//   Inter 400/600/700 + itálico 400 → corpo de texto, rótulos, avisos (papel "body")
//   IBM Plex Mono 500 → dados técnicos/numéricos em tabelas e gráficos (valores, datas,
//                        percentuais, contagens) — nunca nomes/textos livres.

const path = require('path');
const fs = require('fs');

const FONT_DIR = path.join(__dirname, '..', 'assets', 'fonts');

const FONT_FILES = {
  'Manrope-Bold': 'Manrope-Bold.ttf',
  'Manrope-ExtraBold': 'Manrope-ExtraBold.ttf',
  'Inter-Regular': 'Inter-Regular.ttf',
  'Inter-SemiBold': 'Inter-SemiBold.ttf',
  'Inter-Bold': 'Inter-Bold.ttf',
  'Inter-Italic': 'Inter-Italic.ttf',
  'IBMPlexMono-Medium': 'IBMPlexMono-Medium.ttf',
};

// Papéis semânticos usados nos dois geradores — nunca referenciar o nome de arquivo da
// fonte diretamente fora deste módulo, para trocar peso/família num único lugar.
const FONTS = {
  display: 'Manrope-ExtraBold', // capa, título principal do documento
  displayBold: 'Manrope-Bold', // "SEÇÃO N" / "CLÁUSULA N", subtítulos de destaque
  body: 'Inter-Regular', // parágrafos, texto corrido
  bodySemibold: 'Inter-SemiBold', // rótulos em negrito, cabeçalho/rodapé, labels de tabela
  bodyBold: 'Inter-Bold', // ênfase forte pontual
  bodyItalic: 'Inter-Italic', // avisos/placeholders em itálico (ex.: cláusula-modelo)
  mono: 'IBMPlexMono-Medium', // valores numéricos/técnicos: R$, %, datas, contagens
};

// Verificado uma única vez por processo — se os arquivos não existirem (ex.: checkout
// incompleto), os geradores caem de volta para Helvetica em vez de derrubar a geração
// do documento inteiro (mesma filosofia defensiva já usada para o logo em PNG).
const FONTS_AVAILABLE = Object.values(FONT_FILES).every((f) => fs.existsSync(path.join(FONT_DIR, f)));

// Fallback caso os arquivos de fonte não estejam presentes (nunca deve acontecer em
// produção — os .ttf estão versionados no repositório — mas evita que a geração do
// PDF quebre por completo caso falte algum arquivo em algum ambiente).
const FALLBACK_FONTS = {
  display: 'Helvetica-Bold',
  displayBold: 'Helvetica-Bold',
  body: 'Helvetica',
  bodySemibold: 'Helvetica-Bold',
  bodyBold: 'Helvetica-Bold',
  bodyItalic: 'Helvetica-Oblique',
  mono: 'Helvetica',
};

function registerBrandFonts(doc) {
  if (!FONTS_AVAILABLE) return false;
  Object.entries(FONT_FILES).forEach(([name, file]) => {
    doc.registerFont(name, path.join(FONT_DIR, file));
  });
  return true;
}

// Chamar uma vez por documento logo após criar o PDFDocument — registra as fontes de
// marca (se disponíveis) e devolve o mapa de papéis semânticos já resolvido (marca ou
// Helvetica), para os geradores nunca precisarem checar FONTS_AVAILABLE eles mesmos.
function resolveFonts(doc) {
  return registerBrandFonts(doc) ? FONTS : FALLBACK_FONTS;
}

module.exports = { FONTS, FALLBACK_FONTS, registerBrandFonts, resolveFonts, FONTS_AVAILABLE };
