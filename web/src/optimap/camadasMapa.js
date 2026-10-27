// OptiMap — fontes (vector tiles da API) e camadas de desenho do MapLibre.
// Sem camadas de texto (symbol): o mapa não depende de glyphs do provedor externo e
// continua funcional com o fundo neutro de contingência.

import { optimapTileUrl } from '../lib/api';
import { CORES, ZOOM_MIN, ZOOM_MAX_TILES, ZOOM_REF_INDIVIDUAL } from './config';

const corEstado = ['match', ['get', 'estado'],
  'VALIDADO', CORES.estado.VALIDADO, 'DOCUMENTADO', CORES.estado.DOCUMENTADO,
  'PLANEJADO', CORES.estado.PLANEJADO, CORES.estado.DESATIVADO];

const corElemento = ['match', ['get', 'tipo'],
  ...Object.entries(CORES.elemento).flat(), CORES.elemento.OUTRO];

export function fontesOptimap() {
  const fonte = (camada) => ({
    type: 'vector',
    tiles: [optimapTileUrl(camada)],
    minzoom: ZOOM_MIN[camada],
    maxzoom: ZOOM_MAX_TILES,
  });
  return {
    'om-pops': fonte('pops'),
    'om-trechos': fonte('trechos'),
    'om-elementos': fonte('elementos'),
    'om-postes': fonte('postes'),
    'om-postes_referencia': fonte('postes_referencia'),
    'om-selecao': { type: 'geojson', data: { type: 'FeatureCollection', features: [] } },
  };
}

// camada (painel) → ids das camadas de desenho que ela controla
export const DESENHO_POR_CAMADA = {
  postes_referencia: ['om-ref-agregado', 'om-ref'],
  postes: ['om-postes'],
  trechos: ['om-trechos', 'om-trechos-planejados'],
  elementos: ['om-elementos'],
  pops: ['om-pops'],
};

// Ordem de desenho: referência (fundo) → trechos → postes NICK → elementos → POPs → seleção.
export function camadasOptimap() {
  return [
    {
      id: 'om-ref-agregado', type: 'circle', source: 'om-postes_referencia', 'source-layer': 'postes_referencia_agregado',
      minzoom: ZOOM_MIN.postes_referencia, maxzoom: ZOOM_REF_INDIVIDUAL,
      paint: {
        'circle-color': CORES.referencia, 'circle-opacity': 0.35,
        'circle-stroke-color': '#64748b', 'circle-stroke-width': 1,
        'circle-radius': ['interpolate', ['linear'], ['get', 'quantidade'], 1, 4, 20, 9, 200, 16],
      },
    },
    {
      id: 'om-ref', type: 'circle', source: 'om-postes_referencia', 'source-layer': 'postes_referencia',
      minzoom: ZOOM_REF_INDIVIDUAL,
      paint: {
        'circle-radius': 4, 'circle-color': '#ffffff', 'circle-opacity': 0.9,
        'circle-stroke-width': 1.6,
        'circle-stroke-color': ['case', ['boolean', ['get', 'usado_pela_nick'], false], CORES.referenciaUsada, CORES.referencia],
      },
    },
    {
      id: 'om-trechos', type: 'line', source: 'om-trechos', 'source-layer': 'trechos',
      filter: ['!=', ['get', 'estado'], 'PLANEJADO'],
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': corEstado, 'line-width': ['interpolate', ['linear'], ['zoom'], 10, 2, 17, 4.5] },
    },
    {
      id: 'om-trechos-planejados', type: 'line', source: 'om-trechos', 'source-layer': 'trechos',
      filter: ['==', ['get', 'estado'], 'PLANEJADO'],
      layout: { 'line-join': 'round' },
      paint: { 'line-color': CORES.estado.PLANEJADO, 'line-width': ['interpolate', ['linear'], ['zoom'], 10, 2, 17, 4], 'line-dasharray': [2, 1.5] },
    },
    {
      id: 'om-postes', type: 'circle', source: 'om-postes', 'source-layer': 'postes',
      paint: {
        'circle-radius': ['interpolate', ['linear'], ['zoom'], 10, 2.5, 17, 5.5],
        'circle-color': ['case', ['==', ['get', 'estado'], 'PLANEJADO'], '#ffffff', corEstado],
        'circle-stroke-width': 1.5,
        'circle-stroke-color': ['case', ['==', ['get', 'estado'], 'PLANEJADO'], CORES.estado.PLANEJADO, '#ffffff'],
      },
    },
    {
      id: 'om-elementos', type: 'circle', source: 'om-elementos', 'source-layer': 'elementos',
      paint: {
        'circle-radius': ['interpolate', ['linear'], ['zoom'], 10, 4, 17, 8],
        'circle-color': ['case', ['==', ['get', 'estado'], 'PLANEJADO'], '#ffffff', corElemento],
        'circle-stroke-width': 2.2,
        'circle-stroke-color': ['case', ['==', ['get', 'estado'], 'PLANEJADO'], corElemento,
          ['==', ['get', 'estado'], 'VALIDADO'], CORES.estado.VALIDADO, '#ffffff'],
      },
    },
    {
      id: 'om-pops', type: 'circle', source: 'om-pops', 'source-layer': 'pops',
      paint: {
        'circle-radius': ['interpolate', ['linear'], ['zoom'], 5, 5, 15, 10],
        'circle-color': CORES.pop, 'circle-stroke-color': '#ffffff', 'circle-stroke-width': 2.5,
      },
    },
    {
      id: 'om-selecao-linha', type: 'line', source: 'om-selecao', filter: ['==', ['geometry-type'], 'LineString'],
      paint: { 'line-color': CORES.selecao, 'line-width': 9, 'line-opacity': 0.45 },
    },
    {
      id: 'om-selecao-ponto', type: 'circle', source: 'om-selecao', filter: ['==', ['geometry-type'], 'Point'],
      paint: { 'circle-radius': 13, 'circle-color': 'rgba(0,0,0,0)', 'circle-stroke-color': CORES.selecao, 'circle-stroke-width': 3 },
    },
  ];
}

// Ordem de prioridade ao clicar sobre feições sobrepostas.
export const CAMADAS_CLICAVEIS = ['om-elementos', 'om-pops', 'om-postes', 'om-ref', 'om-ref-agregado', 'om-trechos', 'om-trechos-planejados'];

export function camadaDaFeicao(layerId) {
  return {
    'om-elementos': 'elementos', 'om-pops': 'pops', 'om-postes': 'postes', 'om-ref': 'postes_referencia',
    'om-ref-agregado': 'postes_referencia_agregado', 'om-trechos': 'trechos', 'om-trechos-planejados': 'trechos',
  }[layerId];
}
