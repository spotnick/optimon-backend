// OptiMap — configuração central do mapa (Fase 3).
//
// Tudo que depende de serviço externo ou de decisão visual fica AQUI, para trocar sem
// mexer nos componentes.
//
// MAPA-BASE: OpenFreeMap (https://openfreemap.org) — tiles vetoriais gratuitos, sem chave
// de API, dados © OpenStreetMap / OpenMapTiles (a atribuição vem no próprio estilo e o
// MapLibre a exibe no canto do mapa). Sem SLA: se o estilo não carregar em
// BASEMAP_TIMEOUT_MS, o OptiMap troca para um fundo neutro local e avisa o usuário — as
// camadas do OptiMon (que vêm da nossa API) continuam funcionando. Para trocar de
// provedor (MapTiler, Stadia, PMTiles próprio), basta definir VITE_OPTIMAP_STYLE_URL.

export const BASEMAP = {
  styleUrl: import.meta.env.VITE_OPTIMAP_STYLE_URL || 'https://tiles.openfreemap.org/styles/positron',
  provedor: import.meta.env.VITE_OPTIMAP_STYLE_NOME || 'OpenFreeMap (Positron)',
  timeoutMs: 8000,
};

// Fundo neutro usado quando o mapa-base externo está indisponível. Sem glyphs/sprites:
// o OptiMap não usa camadas de texto, então funciona 100% offline.
export const ESTILO_FALLBACK = {
  version: 8,
  name: 'optimap-fallback',
  sources: {},
  layers: [{ id: 'fundo', type: 'background', paint: { 'background-color': '#e8edf3' } }],
};

// Vista inicial: Paraná (área de atuação da NICK). Não é posição de nenhum elemento.
export const VISTA_INICIAL = { center: [-51.7, -24.5], zoom: 6.3 };

// Zoom mínimo por camada — IGUAL aos limites aplicados no banco (app.gis_tile, Fase 2):
// postes de referência só a partir do 12 (agregados 12–14, individuais ≥ 15); rede
// própria a partir do 8. Abaixo disso o banco devolve tile vazio de propósito.
export const ZOOM_MIN = { pops: 0, trechos: 8, postes: 8, elementos: 8, postes_referencia: 12 };
export const ZOOM_REF_INDIVIDUAL = 15;
export const ZOOM_MAX_TILES = 16; // acima disso o MapLibre reaproveita (overzoom) o tile 16

export const CORES = {
  pop: '#2563eb',
  estado: { VALIDADO: '#16a34a', DOCUMENTADO: '#2563eb', PLANEJADO: '#64748b', DESATIVADO: '#94a3b8' },
  elemento: { CEO: '#7c3aed', CTO: '#0891b2', SPLITTER: '#db2777', RESERVA_TECNICA: '#b45309', DERIVACAO: '#475569', OUTRO: '#64748b' },
  referencia: '#94a3b8',
  referenciaUsada: '#2563eb',
  selecao: '#f59e0b',
};

export const ROTULO_ESTADO = { PLANEJADO: 'Planejado', DOCUMENTADO: 'Documentado', VALIDADO: 'Validado', DESATIVADO: 'Desativado' };
export const ROTULO_ELEMENTO = { CEO: 'Caixa de emenda (CEO)', CTO: 'CTO', SPLITTER: 'Splitter', RESERVA_TECNICA: 'Reserva técnica', DERIVACAO: 'Derivação', OUTRO: 'Outro' };
export const ROTULO_SYNC = {
  CONFIRMADO: 'Confirmado na última coleta', ATUALIZADO: 'Atualizado na última coleta', DESATUALIZADO: 'Desatualizado',
  DIVERGENTE: 'Divergente do levantamento da NICK', NAO_LOCALIZADO_ULTIMA_COLETA: 'Não localizado na última coleta',
  EXCLUIDO_PELA_FONTE: 'Excluído pela fonte',
};

// Camadas na ordem do painel. "fonte" = a camada do vector tile servida pela API.
export const CAMADAS = [
  { id: 'pops', nome: 'POPs', descricao: 'POPs com coordenadas cadastradas (infra_pops)',
    vazio: 'Nenhum POP com coordenadas. Cadastre latitude/longitude em Cidades & Infraestrutura.' },
  { id: 'trechos', nome: 'Trechos de cabo', descricao: 'Traçados documentados pela NICK',
    vazio: 'Nenhum trecho de cabo documentado ainda.' },
  { id: 'elementos', nome: 'Elementos de rede', descricao: 'Caixas de emenda, CTOs, splitters, reservas',
    vazio: 'Nenhum elemento de rede documentado ainda.' },
  { id: 'postes', nome: 'Postes da NICK', descricao: 'Postes usados ou projetados pela NICK',
    vazio: 'Nenhum poste da NICK georreferenciado ainda.' },
  { id: 'postes_referencia', nome: 'Postes de referência (concessionária)',
    descricao: 'Referência externa — não significa que a NICK use o poste',
    vazio: 'Nenhum poste de referência importado. A importação de fonte autorizada é feita na Fase 4.' },
];
