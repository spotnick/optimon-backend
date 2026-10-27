// OptiMap — Fase 3: mapa interativo inicial (visualização).
//
// Carregado sob demanda (React.lazy em App.jsx): o MapLibre e seu CSS só entram no bundle
// deste chunk — nenhuma outra tela do OptiMon baixa a biblioteca.
//
// Dados: SOMENTE pela API do OptiMon (JWT do usuário → RLS + regras de perfil no banco).
//   * camadas: vector tiles /api/optimap/tiles/... por área e zoom (nunca a base inteira);
//   * painel: /api/optimap/detalhe/... de UM elemento por vez;
//   * busca: /api/optimap/buscar; contagens: /api/optimap/resumo.
// Nada é inventado: sem dado → estado vazio explícito; sem coordenada → aviso.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import '../optimap/optimap.css';
import { api, API_URL } from '../lib/api';
import { supabase } from '../lib/supabaseClient';
import { BASEMAP, ESTILO_FALLBACK, VISTA_INICIAL, CAMADAS, ZOOM_MIN, ZOOM_REF_INDIVIDUAL, CORES, ROTULO_ELEMENTO } from '../optimap/config';
import { fontesOptimap, camadasOptimap, DESENHO_POR_CAMADA, CAMADAS_CLICAVEIS, camadaDaFeicao } from '../optimap/camadasMapa';
import PainelDetalhe from '../optimap/PainelDetalhe';

const TIPO_BUSCA = { cidade: 'Cidade', pop: 'POP', poste: 'Poste NICK', poste_referencia: 'Poste (referência)', elemento: 'Elemento', coordenada: 'Coordenada' };
const CAMADA_DA_BUSCA = { pop: 'pops', poste: 'postes', poste_referencia: 'postes_referencia', elemento: 'elementos' };
const VISIBILIDADE_KEY = 'optimap_camadas_visiveis_v1';

async function carregarEstiloBase() {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), BASEMAP.timeoutMs);
  try {
    const r = await fetch(BASEMAP.styleUrl, { signal: ctrl.signal });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const estilo = await r.json();
    if (!estilo || estilo.version !== 8 || !Array.isArray(estilo.layers)) throw new Error('estilo inválido');
    return { estilo, ok: true };
  } catch (e) {
    return { estilo: ESTILO_FALLBACK, ok: false, motivo: e.name === 'AbortError' ? 'tempo esgotado' : e.message };
  } finally {
    clearTimeout(t);
  }
}

function lerVisibilidade() {
  try {
    const v = JSON.parse(window.localStorage.getItem(VISIBILIDADE_KEY) || 'null');
    if (v && typeof v === 'object') return v;
  } catch { /* storage indisponível — usa o padrão */ }
  return Object.fromEntries(CAMADAS.map((c) => [c.id, true]));
}

function rotuloFeicao(camada, p) {
  if (camada === 'pops') return `POP ${p.codigo}${p.nome ? ` — ${p.nome}` : ''}`;
  if (camada === 'postes') return `Poste NICK ${p.codigo || ''}`.trim();
  if (camada === 'postes_referencia') return `Poste ${p.id_externo} (referência)`;
  if (camada === 'elementos') return `${ROTULO_ELEMENTO[p.tipo] || p.tipo} ${p.codigo || p.nome || ''}`.trim();
  if (camada === 'trechos') return `Trecho ${p.codigo || ''}`.trim();
  return camada;
}

export default function OptiMap() {
  const containerRef = useRef(null);
  const mapRef = useRef(null);
  const tokenRef = useRef(null);
  const marcadorRef = useRef(null);
  const detalheSeqRef = useRef(0); // descarta respostas de detalhe de cliques antigos
  const cursorRafRef = useRef(0);

  const [sessao, setSessao] = useState({ carregando: true });
  const [resumo, setResumo] = useState(null);
  const [erroResumo, setErroResumo] = useState(null);
  const [baseOk, setBaseOk] = useState(null); // null = carregando
  const [mapaPronto, setMapaPronto] = useState(false);
  const [carregandoTiles, setCarregandoTiles] = useState(false);
  const [errosCamada, setErrosCamada] = useState({});
  const [visiveis, setVisiveis] = useState(lerVisibilidade);
  const [zoom, setZoom] = useState(VISTA_INICIAL.zoom);
  const [cursor, setCursor] = useState(null);
  const [painelCamadasAberto, setPainelCamadasAberto] = useState(true);
  const [detalhe, setDetalhe] = useState(null);
  const [busca, setBusca] = useState({ texto: '', resultados: null, carregando: false, erro: null, aviso: null });

  // ---- sessão / permissão (a API recusa 403 para perfis sem acesso; o banco também) ----
  useEffect(() => {
    let vivo = true;
    api.optimap.sessao()
      .then((s) => vivo && setSessao({ ...s, carregando: false }))
      .catch((e) => vivo && setSessao({ carregando: false, erro: e.message, status: e.status }));
    return () => { vivo = false; };
  }, []);

  // ---- token sempre atualizado para os tiles (transformRequest é síncrono) ----
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { tokenRef.current = data.session?.access_token || null; });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => { tokenRef.current = s?.access_token || null; });
    return () => sub.subscription.unsubscribe();
  }, []);

  const carregarResumo = useCallback(() => {
    setErroResumo(null);
    api.optimap.resumo().then(setResumo).catch((e) => setErroResumo(e.message));
  }, []);

  // ---- mapa ----
  useEffect(() => {
    if (!sessao.pode_ver || !containerRef.current || mapRef.current) return undefined;
    let cancelado = false;
    (async () => {
      const { estilo, ok } = await carregarEstiloBase();
      if (cancelado) return;
      setBaseOk(ok);
      const map = new maplibregl.Map({
        container: containerRef.current,
        style: estilo,
        center: VISTA_INICIAL.center,
        zoom: VISTA_INICIAL.zoom,
        attributionControl: { compact: true },
        transformRequest: (url) => {
          if (url.startsWith(`${API_URL}/api/optimap/`) && tokenRef.current) {
            return { url, headers: { Authorization: `Bearer ${tokenRef.current}` } };
          }
          return { url };
        },
      });
      mapRef.current = map;
      if (import.meta.env.DEV) window.__optimapMap = map; // só para testes locais
      map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'bottom-left');
      map.addControl(new maplibregl.ScaleControl({ unit: 'metric' }), 'bottom-left');

      map.on('load', () => {
        const fontes = fontesOptimap();
        Object.entries(fontes).forEach(([id, def]) => map.addSource(id, def));
        camadasOptimap().forEach((l) => map.addLayer(l));
        setMapaPronto(true);
      });
      map.on('dataloading', () => setCarregandoTiles(true));
      map.on('idle', () => setCarregandoTiles(false));
      map.on('zoomend', () => setZoom(map.getZoom()));
      map.on('mousemove', (e) => {
        // no máximo 1 atualização por quadro (evita re-render a cada pixel)
        if (cursorRafRef.current) return;
        cursorRafRef.current = requestAnimationFrame(() => { cursorRafRef.current = 0; setCursor(e.lngLat); });
      });
      // Camada que volta a carregar com sucesso tem o aviso de erro removido.
      map.on('sourcedata', (e) => {
        if (e.isSourceLoaded && e.sourceId?.startsWith('om-') && e.tile) {
          const camada = e.sourceId.replace('om-', '');
          setErrosCamada((prev) => (prev[camada] ? { ...prev, [camada]: undefined } : prev));
        }
      });
      map.on('error', (e) => {
        const src = e.sourceId || '';
        if (src.startsWith('om-')) {
          const camada = src.replace('om-', '');
          const status = e.error?.status;
          const msg = status === 403 ? 'Sem permissão para esta camada.'
            : status === 401 ? 'Sessão expirada — recarregue a página ou entre novamente.'
              : 'Falha ao carregar dados desta camada.';
          setErrosCamada((prev) => ({ ...prev, [camada]: msg }));
        }
      });
    })();
    return () => {
      cancelado = true;
      if (cursorRafRef.current) cancelAnimationFrame(cursorRafRef.current);
      if (mapRef.current) { mapRef.current.remove(); mapRef.current = null; }
    };
  }, [sessao.pode_ver]);

  useEffect(() => { if (sessao.pode_ver) carregarResumo(); }, [sessao.pode_ver, carregarResumo]);

  // ---- visibilidade das camadas ----
  useEffect(() => {
    try { window.localStorage.setItem(VISIBILIDADE_KEY, JSON.stringify(visiveis)); } catch { /* ignora */ }
    const map = mapRef.current;
    if (!map || !mapaPronto) return;
    Object.entries(DESENHO_POR_CAMADA).forEach(([camada, ids]) => {
      ids.forEach((id) => map.getLayer(id) && map.setLayoutProperty(id, 'visibility', visiveis[camada] ? 'visible' : 'none'));
    });
  }, [visiveis, mapaPronto]);

  // ---- seleção / detalhe ----
  const destacar = useCallback((geometry) => {
    const src = mapRef.current?.getSource('om-selecao');
    if (src) src.setData({ type: 'FeatureCollection', features: geometry ? [{ type: 'Feature', geometry, properties: {} }] : [] });
  }, []);

  const abrirDetalhe = useCallback(async (camada, id) => {
    const seq = ++detalheSeqRef.current;
    setDetalhe({ carregando: true });
    try {
      const d = await api.optimap.detalhe(camada, id);
      if (seq !== detalheSeqRef.current) return; // usuário já selecionou outra coisa
      setDetalhe({ dados: { camada, ...d } });
      destacar(d.geometry);
    } catch (e) {
      if (seq !== detalheSeqRef.current) return;
      setDetalhe({ erro: e.status === 404 ? 'Elemento não encontrado (pode ter sido arquivado ou estar sem coordenadas).' : `Não foi possível carregar os detalhes: ${e.message}` });
      destacar(null);
    }
  }, [destacar]);

  const fecharDetalhe = useCallback(() => {
    detalheSeqRef.current += 1;
    setDetalhe(null);
    destacar(null);
    if (marcadorRef.current) { marcadorRef.current.remove(); marcadorRef.current = null; }
  }, [destacar]);

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !mapaPronto) return undefined;
    const onClick = (e) => {
      setBusca((b) => (b.resultados || b.aviso ? { ...b, resultados: null, aviso: null } : b));
      const caixa = [[e.point.x - 6, e.point.y - 6], [e.point.x + 6, e.point.y + 6]];
      const camadasAtivas = CAMADAS_CLICAVEIS.filter((id) => map.getLayer(id));
      const feicoes = map.queryRenderedFeatures(caixa, { layers: camadasAtivas });
      if (feicoes.length === 0) return;
      const agregado = feicoes.find((f) => f.layer.id === 'om-ref-agregado');
      const vistos = new Map();
      feicoes.forEach((f) => {
        const camada = camadaDaFeicao(f.layer.id);
        if (camada === 'postes_referencia_agregado' || !f.properties?.id) return;
        const chave = `${camada}:${f.properties.id}`;
        if (!vistos.has(chave)) vistos.set(chave, { camada, id: f.properties.id, rotulo: rotuloFeicao(camada, f.properties) });
      });
      let lista = [...vistos.values()].sort((a, b) => CAMADAS_CLICAVEIS.indexOf(`om-${a.camada}`) - CAMADAS_CLICAVEIS.indexOf(`om-${b.camada}`));
      // Pontos têm prioridade sobre linhas: clicar num POP/caixa onde um trecho começa
      // seleciona o ponto. Trecho só é selecionado clicando ao longo da linha.
      if (lista.some((f) => f.camada !== 'trechos')) lista = lista.filter((f) => f.camada !== 'trechos');
      if (lista.length === 0 && agregado) {
        map.easeTo({ center: e.lngLat, zoom: Math.max(map.getZoom() + 2, ZOOM_REF_INDIVIDUAL) });
        return;
      }
      if (lista.length === 1) abrirDetalhe(lista[0].camada, lista[0].id);
      else if (lista.length > 1) { detalheSeqRef.current += 1; setDetalhe({ candidatos: lista }); destacar(null); }
    };
    const cursorOn = () => { map.getCanvas().style.cursor = 'pointer'; };
    const cursorOff = () => { map.getCanvas().style.cursor = ''; };
    map.on('click', onClick);
    CAMADAS_CLICAVEIS.forEach((id) => { map.on('mouseenter', id, cursorOn); map.on('mouseleave', id, cursorOff); });
    return () => {
      map.off('click', onClick);
      CAMADAS_CLICAVEIS.forEach((id) => { map.off('mouseenter', id, cursorOn); map.off('mouseleave', id, cursorOff); });
    };
  }, [mapaPronto, abrirDetalhe, destacar]);

  // ---- busca ----
  useEffect(() => {
    const texto = busca.texto.trim();
    if (texto.length < 2) { setBusca((b) => ({ ...b, resultados: null, erro: null, aviso: null })); return undefined; }
    setBusca((b) => ({ ...b, carregando: true }));
    const t = setTimeout(() => {
      api.optimap.buscar(texto)
        .then((r) => setBusca((b) => (b.texto.trim() === texto ? { ...b, resultados: r, carregando: false, erro: null } : b)))
        .catch((e) => setBusca((b) => (b.texto.trim() === texto ? { ...b, resultados: null, carregando: false, erro: e.message } : b)));
    }, 300);
    return () => clearTimeout(t);
  }, [busca.texto]);

  const escolherResultado = useCallback(async (r) => {
    const map = mapRef.current;
    setBusca((b) => ({ ...b, resultados: null, aviso: null }));
    if (!map) return;
    if (marcadorRef.current) { marcadorRef.current.remove(); marcadorRef.current = null; }

    if (r.tipo === 'cidade') {
      try {
        const ext = await api.optimap.extensaoCidade(r.id);
        if (!ext.bbox) {
          setBusca((b) => ({ ...b, aviso: `${r.rotulo}: nenhuma coordenada cadastrada (POPs sem latitude/longitude). O mapa não foi movido.` }));
          return;
        }
        const [a, b2, c, d] = ext.bbox;
        if (a === c && b2 === d) map.flyTo({ center: [a, b2], zoom: 15 });
        else map.fitBounds([[a, b2], [c, d]], { padding: 80, maxZoom: 16 });
      } catch (e) {
        setBusca((b) => ({ ...b, aviso: `Não foi possível localizar a cidade: ${e.message}` }));
      }
      return;
    }
    if (typeof r.lon !== 'number' || typeof r.lat !== 'number') {
      setBusca((b) => ({ ...b, aviso: 'Resultado sem coordenadas — o mapa não foi movido.' }));
      return;
    }
    const zoomAlvo = r.tipo === 'poste_referencia' ? Math.max(ZOOM_REF_INDIVIDUAL + 1, 16) : 17;
    map.flyTo({ center: [r.lon, r.lat], zoom: zoomAlvo, essential: true });
    if (r.tipo === 'coordenada') {
      marcadorRef.current = new maplibregl.Marker({ color: CORES.selecao }).setLngLat([r.lon, r.lat]).addTo(map);
      destacar(null);
      detalheSeqRef.current += 1;
      setDetalhe({ coordenada: { lon: r.lon, lat: r.lat } });
      return;
    }
    abrirDetalhe(CAMADA_DA_BUSCA[r.tipo], r.id);
  }, [abrirDetalhe, destacar]);

  const contagem = (id) => (resumo?.camadas ? resumo.camadas[id] : null);
  const legendaEstados = useMemo(() => ['VALIDADO', 'DOCUMENTADO', 'PLANEJADO'], []);

  // ---- estados de página ----
  if (sessao.carregando) {
    return <div className="om-pagina-centro"><div className="spinner" /> <span>Verificando acesso ao OptiMap…</span></div>;
  }
  if (sessao.erro) {
    const negado = sessao.status === 403;
    return (
      <div className="om-pagina-centro">
        <div className="card om-cartao-estado" role="alert" data-testid={negado ? 'optimap-sem-acesso' : 'optimap-erro-api'}>
          <h2>{negado ? 'Sem acesso ao OptiMap' : 'OptiMap indisponível'}</h2>
          <p>{negado ? 'Seu perfil não tem permissão para visualizar o mapa da rede. Fale com um administrador se precisar de acesso.' : `Não foi possível falar com a API do OptiMon (${sessao.erro}).`}</p>
          {!negado && <button type="button" className="btn btn-primary" onClick={() => window.location.reload()}>Tentar novamente</button>}
        </div>
      </div>
    );
  }

  return (
    <div className="om-raiz" data-testid="optimap">
      <div ref={containerRef} className="om-mapa" data-testid="optimap-mapa" />

      {/* Busca */}
      <div className={`om-busca${detalhe ? ' om-busca-com-detalhe' : ''}`}>
        <input
          type="search"
          placeholder="Buscar cidade, POP, poste, elemento ou “lat, lon”"
          value={busca.texto}
          onChange={(e) => setBusca((b) => ({ ...b, texto: e.target.value, aviso: null }))}
          onKeyDown={(e) => { if (e.key === 'Enter' && busca.resultados?.length === 1) escolherResultado(busca.resultados[0]); }}
          aria-label="Buscar no mapa"
          data-testid="optimap-busca"
        />
        {busca.carregando && <span className="om-busca-status">buscando…</span>}
        {busca.erro && <div className="om-busca-lista om-alerta-erro" role="alert">Erro na busca: {busca.erro}</div>}
        {busca.resultados && busca.resultados.length === 0 && (
          <div className="om-busca-lista" data-testid="optimap-busca-vazia">
            Nenhum resultado para “{busca.texto.trim()}”. Coordenadas devem estar no formato “latitude, longitude” e dentro do Brasil.
          </div>
        )}
        {busca.resultados && busca.resultados.length > 0 && (
          <ul className="om-busca-lista" role="listbox" data-testid="optimap-busca-resultados">
            {busca.resultados.map((r) => (
              <li key={`${r.tipo}:${r.id || r.rotulo}`}>
                <button type="button" onClick={() => escolherResultado(r)}>
                  <span className="om-busca-tipo">{TIPO_BUSCA[r.tipo] || r.tipo}</span>{r.rotulo}
                </button>
              </li>
            ))}
          </ul>
        )}
        {busca.aviso && <div className="om-busca-lista om-alerta-aviso" role="status" data-testid="optimap-busca-aviso">{busca.aviso}</div>}
      </div>

      {/* Avisos globais */}
      <div className="om-avisos">
        {baseOk === false && (
          <div className="om-alerta om-alerta-aviso" role="status" data-testid="optimap-aviso-mapa-base">
            Mapa-base ({BASEMAP.provedor}) indisponível no momento — exibindo fundo neutro. As camadas do OptiMon continuam disponíveis.
          </div>
        )}
        {erroResumo && (
          <div className="om-alerta om-alerta-erro" role="alert" data-testid="optimap-erro-resumo">
            Não foi possível carregar o resumo das camadas ({erroResumo}). <button type="button" className="om-link" onClick={carregarResumo}>tentar de novo</button>
          </div>
        )}
      </div>

      {/* Camadas + legenda */}
      <aside className={`om-painel om-camadas${painelCamadasAberto ? '' : ' om-recolhido'}`} aria-label="Camadas e legenda" data-testid="optimap-camadas">
        <div className="om-camadas-topo">
          <h3>Camadas</h3>
          <button type="button" className="om-link" onClick={() => setPainelCamadasAberto((v) => !v)}>{painelCamadasAberto ? 'recolher' : 'camadas'}</button>
        </div>
        {painelCamadasAberto && (
          <>
            <ul className="om-lista-camadas">
              {CAMADAS.map((c) => {
                const n = contagem(c.id);
                const abaixoZoom = zoom < ZOOM_MIN[c.id];
                return (
                  <li key={c.id} data-testid={`camada-${c.id}`}>
                    <label>
                      <input
                        type="checkbox"
                        checked={!!visiveis[c.id]}
                        onChange={(e) => setVisiveis((v) => ({ ...v, [c.id]: e.target.checked }))}
                        data-testid={`toggle-${c.id}`}
                      />
                      <span className={`om-simbolo om-simbolo-${c.id}`} aria-hidden="true" />
                      <span className="om-camada-nome">{c.nome}</span>
                      <span className="om-contagem" data-testid={`contagem-${c.id}`}>{n == null ? '…' : n.toLocaleString('pt-BR')}</span>
                    </label>
                    <p className="om-camada-desc">{c.descricao}</p>
                    {n === 0 && <p className="om-vazio" data-testid={`vazio-${c.id}`}>{c.vazio}</p>}
                    {c.id === 'pops' && resumo?.pops_sem_coordenada > 0 && (
                      <p className="om-vazio">{resumo.pops_sem_coordenada} POP(s) cadastrado(s) sem coordenadas — não aparecem no mapa.</p>
                    )}
                    {n > 0 && visiveis[c.id] && abaixoZoom && <p className="om-dica">Aproxime o mapa (zoom ≥ {ZOOM_MIN[c.id]}) para ver esta camada.</p>}
                    {errosCamada[c.id] && <p className="om-alerta-erro om-erro-camada" role="alert">{errosCamada[c.id]}</p>}
                  </li>
                );
              })}
            </ul>
            <div className="om-legenda" data-testid="optimap-legenda">
              <h4>Estado (rede NICK)</h4>
              <ul>
                {legendaEstados.map((e) => (
                  <li key={e}><span className={`om-ponto om-ponto-${e.toLowerCase()}`} aria-hidden="true" />{e === 'PLANEJADO' ? 'Planejado (contorno / tracejado)' : e === 'VALIDADO' ? 'Validado em campo' : 'Documentado'}</li>
                ))}
              </ul>
              <h4>Elementos</h4>
              <ul className="om-legenda-elementos">
                {Object.entries(CORES.elemento).map(([t, cor]) => (
                  <li key={t}><span className="om-ponto" style={{ background: cor }} aria-hidden="true" />{ROTULO_ELEMENTO[t]}</li>
                ))}
              </ul>
              <h4>Origem</h4>
              <ul>
                <li><span className="om-ponto om-ponto-ref" aria-hidden="true" />Referência externa (concessionária)</li>
                <li><span className="om-ponto om-ponto-ref-agregado" aria-hidden="true" />Agrupamento de referências (zoom 12–14)</li>
                <li><span className="om-ponto om-ponto-pop" aria-hidden="true" />POP (cadastro OptiMon)</li>
              </ul>
            </div>
          </>
        )}
      </aside>

      <PainelDetalhe estado={detalhe} onFechar={fecharDetalhe} onSelecionar={abrirDetalhe} />

      {/* Barra de status */}
      <div className="om-status" data-testid="optimap-status">
        <span>Zoom {zoom.toFixed(1)}</span>
        {cursor && <span className="om-mono">{cursor.lat.toFixed(5)}, {cursor.lng.toFixed(5)}</span>}
        <span>Perfil {sessao.role} · visualização</span>
        {sessao.pode_ver_importacoes && <Link to="/optimap/importacoes" className="om-link-status" data-testid="optimap-link-importacoes">Importações de postes</Link>}
        {(carregandoTiles || baseOk === null) && <span className="om-carregando-chip" data-testid="optimap-carregando"><span className="spinner om-spinner-mini" />carregando…</span>}
      </div>
    </div>
  );
}
