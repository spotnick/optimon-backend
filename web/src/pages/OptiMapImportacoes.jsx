// OptiMap — Fase 4: importações de postes de referência.
//
// /optimap/importacoes       lista + envio do arquivo do coletor (tools/optimap/coletar_copel.mjs)
// /optimap/importacoes/:id   prévia: resumo, bloqueios/avisos, mapa, itens, conflitos e ações
//
// Nada aqui grava dado oficial por conta própria: o envio gera uma PRÉVIA no staging e só a
// aprovação (ADMINISTRADOR/DIRETOR) aplica em gis_postes_referencia. Os botões exibidos
// seguem o perfil, mas a regra efetiva é do banco (a API devolve 403 se o perfil não pode).

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import '../optimap/optimap.css';
import { api } from '../lib/api';
import { BASEMAP, ESTILO_FALLBACK } from '../optimap/config';

const CLASSES = [
  { id: 'NOVO', nome: 'Novos', cor: '#2563eb', desc: 'Número ainda não cadastrado — será incluído.' },
  { id: 'ATUALIZADO', nome: 'Atualizados', cor: '#7c3aed', desc: 'Situação, atributo ou posição mudou na fonte.' },
  { id: 'SEM_ALTERACAO', nome: 'Sem alteração', cor: '#64748b', desc: 'Igual ao cadastrado — só renova a data da coleta.' },
  { id: 'CONFLITO', nome: 'Conflitos', cor: '#dc2626', desc: 'Exigem decisão (aplicar ou ignorar) antes da aprovação.' },
  { id: 'AUSENTE', nome: 'Ausentes', cor: '#d97706', desc: 'Cadastrados no município e fora do arquivo — viram “não localizado na última coleta”. Nunca são apagados.' },
  { id: 'INVALIDO', nome: 'Inválidos', cor: '#111827', desc: 'Sem número ou coordenada válida — nunca aplicados.' },
  { id: 'DUPLICADO', nome: 'Duplicados', cor: '#9ca3af', desc: 'Número repetido no arquivo — vale a primeira ocorrência.' },
];
const COR = Object.fromEntries(CLASSES.map((c) => [c.id, c.cor]));
const NOME = Object.fromEntries(CLASSES.map((c) => [c.id, c.nome]));

const STATUS = {
  RECEBIDA: { rotulo: 'Recebida', classe: 'oi-st-neutro' },
  PREVIA: { rotulo: 'Prévia — aguardando aprovação', classe: 'oi-st-aviso' },
  IMPORTADA: { rotulo: 'Importada', classe: 'oi-st-ok' },
  REJEITADA: { rotulo: 'Rejeitada', classe: 'oi-st-erro' },
  DESCARTADA: { rotulo: 'Descartada', classe: 'oi-st-neutro' },
  REVERTIDA: { rotulo: 'Revertida', classe: 'oi-st-neutro' },
  REVERTIDA_PARCIALMENTE: { rotulo: 'Revertida parcialmente', classe: 'oi-st-aviso' },
};

const MOTIVOS = {
  SEM_NUMERO_DO_POSTE: 'Sem número do poste',
  SEM_COORDENADA: 'Sem coordenada',
  COORDENADA_INVALIDA: 'Coordenada inválida / fora do Brasil',
  DESLOCAMENTO_GRANDE: 'Mudou mais de 30 m de lugar',
  DESLOCADO_COM_POSTE_NICK: 'Mudou mais de 5 m e é usado pela rede NICK',
  REAPARECEU_APOS_EXCLUSAO: 'Reapareceu depois de marcado como excluído pela fonte',
  MUNICIPIO_DIFERENTE: 'Já cadastrado em outro município',
  ALTERADO_POR_IMPORTACAO_POSTERIOR: 'Alterado por importação posterior',
  ALTERADO_MANUALMENTE_DEPOIS: 'Editado manualmente depois',
  PROMOVIDO_A_POSTE_NICK: 'Virou poste da rede NICK',
  REGISTRO_NAO_ENCONTRADO: 'Registro não encontrado',
};
const ALERTAS = {
  POSTE_PROXIMO_COM_OUTRO_NUMERO: 'outro poste a menos de 1 m com número diferente',
  NUMERO_REPETIDO_COM_POSICAO_DIFERENTE: 'número repetido no arquivo em outra posição',
  POSTE_NICK_VINCULADO: 'usado pela rede NICK',
  AUSENTE_COM_POSTE_NICK: 'ausente, mas usado pela rede NICK',
  JA_NAO_LOCALIZADO: 'já estava não localizado',
};
// Textos de aviso mais claros que os gravados pelo banco (mesmo código).
const AVISOS = {
  MUNICIPIO_SEM_CIDADE_NICK: 'Este município ainda não está cadastrado como cidade no OptiMon. Os postes aparecem normalmente no mapa; só não ficam vinculados a uma cidade. Ao cadastrar a cidade (com o código IBGE), a próxima coleta faz o vínculo.',
};
const motivo = (m) => (m ? MOTIVOS[m] || m.replace(/_/g, ' ').toLowerCase() : '');
const n = (v) => (v == null ? '—' : Number(v).toLocaleString('pt-BR'));
const dataHora = (v) => (v ? new Date(v).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : '—');
const data = (v) => (v ? new Date(v).toLocaleDateString('pt-BR') : '—');

function Status({ s }) {
  const st = STATUS[s] || { rotulo: s, classe: 'oi-st-neutro' };
  return <span className={`oi-status ${st.classe}`} data-testid="imp-status">{st.rotulo}</span>;
}

// ===========================================================================
// Lista + envio
// ===========================================================================
function Lista({ sessao }) {
  const navigate = useNavigate();
  const [lista, setLista] = useState(null);
  const [erro, setErro] = useState(null);
  const [envio, setEnvio] = useState({ arquivo: null, observacoes: '', enviando: false, erro: null });
  const inputRef = useRef(null);

  const carregar = useCallback(() => {
    setErro(null);
    api.optimap.importacoes.listar().then(setLista).catch((e) => setErro(e.message));
  }, []);
  useEffect(carregar, [carregar]);

  const enviar = async (ev) => {
    ev.preventDefault();
    if (!envio.arquivo) return;
    setEnvio((x) => ({ ...x, enviando: true, erro: null }));
    try {
      const fd = new FormData();
      fd.append('arquivo', envio.arquivo);
      if (envio.observacoes.trim()) fd.append('observacoes', envio.observacoes.trim());
      const r = await api.optimap.importacoes.enviar(fd);
      navigate(`/optimap/importacoes/${r.id}`);
    } catch (e) {
      setEnvio((x) => ({ ...x, enviando: false, erro: e.message }));
    }
  };

  return (
    <div className="page oi-pagina" data-testid="importacoes">
      <div className="page-header oi-cabecalho">
        <div>
          <div className="oi-trilha"><Link to="/optimap">OptiMap</Link> / Importações</div>
          <h1>Importações de postes de referência</h1>
          <p>Arquivos gerados pelo coletor por município. Cada arquivo vira uma prévia; nada entra no mapa antes da aprovação.</p>
        </div>
      </div>

      {sessao.pode_importar && (
        <form className="card oi-envio" onSubmit={enviar} data-testid="imp-envio">
          <h3>Enviar arquivo do coletor</h3>
          <p className="oi-muted">Arquivo <code>copel_&lt;ibge&gt;_&lt;cidade&gt;_&lt;data&gt;.geojson</code> da pasta <code>tools\optimap\saida</code>. Um município por arquivo.</p>
          <div className="oi-envio-linha">
            <input
              ref={inputRef}
              type="file"
              accept=".geojson,.json,application/geo+json,application/json"
              onChange={(e) => setEnvio((x) => ({ ...x, arquivo: e.target.files?.[0] || null, erro: null }))}
              data-testid="imp-arquivo"
            />
            <input
              type="text"
              placeholder="Observações (opcional)"
              value={envio.observacoes}
              maxLength={1000}
              onChange={(e) => setEnvio((x) => ({ ...x, observacoes: e.target.value }))}
            />
            <button type="submit" className="btn btn-primary" disabled={!envio.arquivo || envio.enviando} data-testid="imp-enviar">
              {envio.enviando ? 'Enviando e calculando a prévia…' : 'Enviar e gerar prévia'}
            </button>
          </div>
          {envio.arquivo && <p className="oi-muted">{envio.arquivo.name} · {(envio.arquivo.size / 1024 / 1024).toFixed(1)} MB</p>}
          {envio.erro && <div className="error-banner" role="alert" data-testid="imp-envio-erro">{envio.erro}</div>}
        </form>
      )}

      {erro && <div className="error-banner" role="alert">{erro} <button type="button" className="om-link" onClick={carregar}>tentar de novo</button></div>}
      {!lista && !erro && <div className="oi-carregando"><div className="spinner" /> Carregando…</div>}
      {lista && lista.length === 0 && (
        <div className="card oi-vazio" data-testid="imp-lista-vazia">Nenhuma importação ainda.{sessao.pode_importar ? ' Envie o primeiro arquivo acima.' : ''}</div>
      )}
      {lista && lista.length > 0 && (
        <div className="card table-scroll">
          <table className="oi-tabela" data-testid="imp-lista">
            <thead><tr><th>Município</th><th>Coleta</th><th>Postes</th><th>Resultado</th><th>Status</th><th>Enviado</th></tr></thead>
            <tbody>
              {lista.map((i) => (
                <tr key={i.id} className="oi-clicavel" onClick={() => navigate(`/optimap/importacoes/${i.id}`)}>
                  <td><Link to={`/optimap/importacoes/${i.id}`} onClick={(e) => e.stopPropagation()}>{i.municipio_nome}-{i.uf}</Link><div className="oi-muted">IBGE {i.municipio_ibge}</div></td>
                  <td>{data(i.data_referencia)}</td>
                  <td>{n(i.total_recebido)}</td>
                  <td className="oi-contagens-mini">
                    {i.contagens ? CLASSES.filter((c) => i.contagens[c.id]).map((c) => (
                      <span key={c.id} title={c.nome}><i style={{ background: c.cor }} />{n(i.contagens[c.id])}</span>
                    )) : '—'}
                  </td>
                  <td><Status s={i.status} /></td>
                  <td>{dataHora(i.criado_em)}<div className="oi-muted">{i.criado_por_nome || ''}</div></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

// ===========================================================================
// Mapa da prévia
// ===========================================================================
function MapaPrevia({ geojson, filtro }) {
  const ref = useRef(null);
  const mapRef = useRef(null);
  const [pronto, setPronto] = useState(false);

  useEffect(() => {
    let cancelado = false;
    (async () => {
      let estilo = ESTILO_FALLBACK;
      try {
        const r = await fetch(BASEMAP.styleUrl);
        if (r.ok) estilo = await r.json();
      } catch { /* fundo neutro */ }
      if (cancelado || !ref.current) return;
      const map = new maplibregl.Map({ container: ref.current, style: estilo, center: [-51.7, -24.5], zoom: 6, attributionControl: { compact: true } });
      mapRef.current = map;
      map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
      map.on('load', () => {
        map.addSource('previa', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
        map.addSource('deslocamento', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
        map.addLayer({ id: 'deslocamento', type: 'line', source: 'deslocamento', paint: { 'line-color': '#dc2626', 'line-width': 2, 'line-dasharray': [2, 1] } });
        map.addLayer({
          id: 'previa', type: 'circle', source: 'previa',
          paint: {
            'circle-radius': ['interpolate', ['linear'], ['zoom'], 10, 1.5, 15, 4, 18, 7],
            'circle-color': ['match', ['get', 'classificacao'], ...CLASSES.flatMap((c) => [c.id, c.cor]), '#000'],
            'circle-stroke-color': '#fff', 'circle-stroke-width': ['interpolate', ['linear'], ['zoom'], 12, 0, 15, 1],
          },
        });
        const popup = new maplibregl.Popup({ closeButton: false, closeOnClick: true });
        map.on('click', 'previa', (e) => {
          const p = e.features[0].properties;
          popup.setLngLat(e.lngLat).setHTML(`<b>Poste ${p.id_externo ?? '(sem número)'}</b><br>${NOME[p.classificacao] || p.classificacao}${p.situacao ? ` · ${p.situacao}` : ''}${p.motivo ? `<br>${motivo(p.motivo)}` : ''}`).addTo(map);
        });
        map.on('mouseenter', 'previa', () => { map.getCanvas().style.cursor = 'pointer'; });
        map.on('mouseleave', 'previa', () => { map.getCanvas().style.cursor = ''; });
        setPronto(true);
      });
    })();
    return () => { cancelado = true; if (mapRef.current) { mapRef.current.remove(); mapRef.current = null; } };
  }, []);

  useEffect(() => {
    const map = mapRef.current;
    if (!pronto || !geojson) return;
    map.getSource('previa').setData(geojson);
    const linhas = geojson.features
      .filter((f) => Array.isArray(f.properties?.anterior) && f.geometry)
      .map((f) => ({ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: [f.properties.anterior, f.geometry.coordinates] } }));
    map.getSource('deslocamento').setData({ type: 'FeatureCollection', features: linhas });
    // Enquadra pelos pontos válidos (ignora coordenadas fora do Brasil).
    const pts = geojson.features.map((f) => f.geometry?.coordinates).filter((c) => c && c[0] > -74 && c[0] < -28 && c[1] > -34 && c[1] < 6);
    if (pts.length) {
      const b = pts.reduce((a, [x, y]) => [Math.min(a[0], x), Math.min(a[1], y), Math.max(a[2], x), Math.max(a[3], y)], [180, 90, -180, -90]);
      map.fitBounds([[b[0], b[1]], [b[2], b[3]]], { padding: 30, maxZoom: 16, duration: 0 });
    }
  }, [pronto, geojson]);

  useEffect(() => {
    const map = mapRef.current;
    if (!pronto) return;
    map.setFilter('previa', filtro ? ['==', ['get', 'classificacao'], filtro] : null);
    // Enquadra o que está filtrado (ex.: os poucos conflitos no meio de milhares de postes).
    const pts = (geojson?.features || [])
      .filter((f) => !filtro || f.properties?.classificacao === filtro)
      .flatMap((f) => [f.geometry?.coordinates, f.properties?.anterior])
      .filter((c) => Array.isArray(c) && c[0] > -74 && c[0] < -28 && c[1] > -34 && c[1] < 6);
    if (pts.length) {
      const b = pts.reduce((a, [x, y]) => [Math.min(a[0], x), Math.min(a[1], y), Math.max(a[2], x), Math.max(a[3], y)], [180, 90, -180, -90]);
      map.fitBounds([[b[0], b[1]], [b[2], b[3]]], { padding: 40, maxZoom: 17, duration: 300 });
    }
  }, [pronto, filtro, geojson]);

  return <div ref={ref} className="oi-mapa" data-testid="imp-mapa" />;
}

// ===========================================================================
// Detalhe / prévia
// ===========================================================================
function Modal({ titulo, texto, rotulo, perigo, exigeMotivo, extra, onConfirmar, onFechar }) {
  const [motivoTxt, setMotivoTxt] = useState('');
  const [ocupado, setOcupado] = useState(false);
  const [erro, setErro] = useState(null);
  const ok = !exigeMotivo || motivoTxt.trim().length >= 3;
  return (
    <div className="modal-overlay" role="dialog" aria-modal="true">
      <div className="modal-dialog" data-testid="imp-modal">
        <h3>{titulo}</h3>
        <p className="modal-subject">{texto}</p>
        {extra}
        {exigeMotivo && (
          <label className="oi-campo">Motivo (obrigatório)
            <textarea rows={3} value={motivoTxt} onChange={(e) => setMotivoTxt(e.target.value)} maxLength={1000} data-testid="imp-motivo" />
          </label>
        )}
        {erro && <div className="error-banner" role="alert" data-testid="imp-modal-erro">{erro}</div>}
        <div className="modal-actions">
          <button type="button" className="btn btn-secondary" onClick={onFechar} disabled={ocupado}>Cancelar</button>
          <button
            type="button"
            className={`btn ${perigo ? 'btn-danger' : 'btn-primary'}`}
            disabled={!ok || ocupado}
            data-testid="imp-modal-confirmar"
            onClick={async () => {
              setOcupado(true); setErro(null);
              try { await onConfirmar(motivoTxt.trim()); } catch (e) { setErro(e.message); setOcupado(false); }
            }}
          >{ocupado ? 'Processando…' : rotulo}</button>
        </div>
      </div>
    </div>
  );
}

function Detalhe({ id, sessao }) {
  const navigate = useNavigate();
  const [imp, setImp] = useState(null);
  const [erro, setErro] = useState(null);
  const [geojson, setGeojson] = useState(null);
  const [filtro, setFiltro] = useState(null);
  const [itens, setItens] = useState(null);
  const [pagina, setPagina] = useState(0);
  const [busca, setBusca] = useState('');
  const [modal, setModal] = useState(null);
  const [mensagem, setMensagem] = useState(null);
  const [confirmaAusencias, setConfirmaAusencias] = useState(false);
  const POR_PAGINA = 50;

  const carregar = useCallback(async () => {
    setErro(null);
    try {
      const d = await api.optimap.importacoes.detalhe(id);
      setImp(d);
      api.optimap.importacoes.previa(id).then(setGeojson).catch(() => setGeojson({ type: 'FeatureCollection', features: [] }));
    } catch (e) {
      setErro(e.status === 404 ? 'Importação não encontrada (ou sem permissão para vê-la).' : e.message);
    }
  }, [id]);
  useEffect(() => { carregar(); }, [carregar]);

  const carregarItens = useCallback(() => {
    api.optimap.importacoes.itens(id, { classificacao: filtro || undefined, busca: busca.trim() || undefined, limite: POR_PAGINA, offset: pagina * POR_PAGINA })
      .then(setItens).catch((e) => setItens({ erro: e.message }));
  }, [id, filtro, busca, pagina]);
  useEffect(() => {
    const t = setTimeout(carregarItens, busca ? 300 : 0);
    return () => clearTimeout(t);
  }, [carregarItens, busca]);

  const resumo = imp?.resumo || {};
  const contagens = resumo.contagens || {};
  const exigeConfirmacao = (resumo.avisos || []).some((a) => a.exige_confirmacao);
  const papel = sessao.role;
  // ENGENHARIA só enxerga (RLS) as próprias importações — se vê, é dona.
  const podeEditar = papel === 'ADMINISTRADOR' || papel === 'ENGENHARIA';
  const podeDecidir = podeEditar || papel === 'DIRETOR';
  const emPrevia = imp?.status === 'PREVIA';

  const depois = async (msg) => { setModal(null); setMensagem(msg); await carregar(); carregarItens(); };
  const decidir = async (itemIds, decisao) => {
    try {
      await api.optimap.importacoes.decidir(id, itemIds, decisao);
      await carregar(); carregarItens();
    } catch (e) { setMensagem(`Erro: ${e.message}`); }
  };

  if (erro) return <div className="page"><div className="error-banner" role="alert" data-testid="imp-erro">{erro}</div><Link to="/optimap/importacoes">← Importações</Link></div>;
  if (!imp) return <div className="page oi-carregando"><div className="spinner" /> Carregando a prévia…</div>;

  const pendentes = resumo.conflitos_pendentes || 0;
  const bloqueios = resumo.bloqueios || [];
  const avisos = resumo.avisos || [];
  const meta = imp.metadados_coletor || {};

  return (
    <div className="page oi-pagina" data-testid="importacao-detalhe">
      <div className="page-header oi-cabecalho">
        <div>
          <div className="oi-trilha"><Link to="/optimap">OptiMap</Link> / <Link to="/optimap/importacoes">Importações</Link> / {imp.municipio_nome}</div>
          <h1>{imp.municipio_nome}-{imp.uf} <Status s={imp.status} /></h1>
          <p>
            Fonte {imp.fonte} · coleta de {dataHora(imp.data_referencia)} · {n(imp.total_recebido)} postes no arquivo
            {imp.cidade_nome ? ` · cidade OptiMon: ${imp.cidade_nome}` : ' · sem cidade OptiMon correspondente'}
          </p>
          <p className="oi-muted">
            Arquivo {imp.arquivo_nome_original} · SHA-256 <code title={imp.arquivo_hash}>{imp.arquivo_hash.slice(0, 12)}…</code>
            {' '}· enviado por {imp.usuarios?.[imp.criado_por] || '—'} em {dataHora(imp.criado_em)}
            {imp.aprovado_em && ` · aprovado por ${imp.usuarios?.[imp.aprovado_por] || '—'} em ${dataHora(imp.aprovado_em)}`}
            {imp.revertido_em && ` · revertido por ${imp.usuarios?.[imp.revertido_por] || '—'} em ${dataHora(imp.revertido_em)} (${imp.motivo_reversao})`}
            {imp.rejeitado_em && ` · rejeitado: ${imp.motivo_rejeicao}`}
          </p>
          {meta.baixados != null && (
            <p className="oi-muted">Coletor: {n(meta.baixados)} baixados no retângulo, {n(meta.fora_do_municipio)} fora do limite municipal, {n(meta.duplicados)} duplicados e {n(meta.invalidos)} inválidos descartados na origem.</p>
          )}
          {resumo.situacao_no_arquivo && Object.keys(resumo.situacao_no_arquivo).length > 0 && (
            <p className="oi-muted" data-testid="imp-situacoes">
              Situação informada pela fonte: {Object.entries(resumo.situacao_no_arquivo).sort((x, y) => y[1] - x[1]).map(([k, v]) => `${k} ${n(v)}`).join(' · ')}
            </p>
          )}
        </div>
        <div className="oi-acoes" data-testid="imp-acoes">
          {emPrevia && podeEditar && <button type="button" className="btn btn-secondary btn-sm" onClick={() => setModal('reprocessar')}>Recalcular prévia</button>}
          {['RECEBIDA', 'PREVIA'].includes(imp.status) && podeEditar && <button type="button" className="btn btn-secondary btn-sm" onClick={() => setModal('descartar')}>Descartar</button>}
          {['RECEBIDA', 'PREVIA'].includes(imp.status) && sessao.pode_aprovar_importacao && <button type="button" className="btn btn-danger btn-sm" onClick={() => setModal('rejeitar')} data-testid="imp-rejeitar">Rejeitar</button>}
          {emPrevia && sessao.pode_aprovar_importacao && (
            <button type="button" className="btn btn-primary" disabled={!resumo.pode_aprovar || (exigeConfirmacao && !confirmaAusencias)} onClick={() => setModal('aprovar')} data-testid="imp-aprovar">Aprovar e importar</button>
          )}
          {['IMPORTADA', 'REVERTIDA_PARCIALMENTE'].includes(imp.status) && sessao.pode_reverter_importacao && (
            <button type="button" className="btn btn-danger btn-sm" onClick={() => setModal('reverter')} data-testid="imp-reverter">{imp.status === 'IMPORTADA' ? 'Reverter importação' : 'Tentar reverter o restante'}</button>
          )}
        </div>
      </div>

      {mensagem && <div className={mensagem.startsWith('Erro') ? 'error-banner' : 'oi-sucesso'} role="status" data-testid="imp-mensagem">{mensagem}</div>}

      {emPrevia && (bloqueios.length > 0 || avisos.length > 0) && (
        <div className="oi-alertas">
          {bloqueios.map((b) => <div key={b.codigo} className="oi-bloqueio" role="alert" data-testid={`imp-bloqueio-${b.codigo}`}>⛔ {b.mensagem}</div>)}
          {avisos.map((a) => (
            <div key={a.codigo} className="oi-aviso" data-testid={`imp-aviso-${a.codigo}`}>
              ⚠ {AVISOS[a.codigo] || a.mensagem}
              {a.exige_confirmacao && sessao.pode_aprovar_importacao && (
                <label className="oi-confirma"><input type="checkbox" checked={confirmaAusencias} onChange={(e) => setConfirmaAusencias(e.target.checked)} data-testid="imp-confirma-ausencias" /> Confirmo que a coleta está completa e esses postes devem ser marcados como não localizados (nada é apagado).</label>
              )}
            </div>
          ))}
        </div>
      )}
      {emPrevia && bloqueios.length === 0 && !sessao.pode_aprovar_importacao && (
        <div className="oi-aviso">Prévia pronta. A aprovação é feita por ADMINISTRADOR ou DIRETOR.</div>
      )}

      {imp.alteracoes?.total > 0 && (
        <div className="card oi-log" data-testid="imp-log">
          <b>Registro de alterações aplicadas:</b> {n(imp.alteracoes.total)} ({n(imp.alteracoes.inserts)} inclusões, {n(imp.alteracoes.updates)} atualizações) · {n(imp.alteracoes.revertidas)} revertidas
          {Object.keys(imp.nao_revertidas_por_motivo || {}).length > 0 && (
            <div className="oi-muted">Não revertidas: {Object.entries(imp.nao_revertidas_por_motivo).map(([k, v]) => `${motivo(k)}: ${n(v)}`).join(' · ')}</div>
          )}
        </div>
      )}

      <div className="oi-cartoes" data-testid="imp-contagens">
        {CLASSES.map((c) => (
          <button
            key={c.id}
            type="button"
            className={`oi-cartao${filtro === c.id ? ' oi-ativo' : ''}`}
            onClick={() => { setFiltro((f) => (f === c.id ? null : c.id)); setPagina(0); }}
            title={c.desc}
            data-testid={`imp-cartao-${c.id}`}
          >
            <span className="oi-cartao-cor" style={{ background: c.cor }} />
            <span className="oi-cartao-nome">{c.nome}</span>
            <span className="oi-cartao-valor">{n(contagens[c.id] || 0)}</span>
            {c.id === 'CONFLITO' && pendentes > 0 && <span className="oi-cartao-sub">{n(pendentes)} sem decisão</span>}
          </button>
        ))}
      </div>

      <div className="oi-grade">
        <div className="card oi-mapa-card">
          <MapaPrevia geojson={geojson} filtro={filtro} />
          <div className="oi-legenda-mapa">Clique num cartão para filtrar · linha tracejada = deslocamento (posição anterior → nova)</div>
        </div>

        <div className="card oi-itens">
          <div className="oi-itens-topo">
            <b>{filtro ? NOME[filtro] : 'Todos os itens'}</b>
            <input type="search" placeholder="Número do poste" value={busca} onChange={(e) => { setBusca(e.target.value); setPagina(0); }} data-testid="imp-busca" />
            {filtro === 'CONFLITO' && emPrevia && podeDecidir && itens?.itens?.some((i) => !i.decisao) && (
              <span className="oi-lote">
                Pendentes desta página:
                <button type="button" className="btn btn-sm btn-secondary" onClick={() => decidir(itens.itens.filter((i) => !i.decisao).map((i) => i.id), 'APLICAR')}>aplicar</button>
                <button type="button" className="btn btn-sm btn-secondary" onClick={() => decidir(itens.itens.filter((i) => !i.decisao).map((i) => i.id), 'IGNORAR')}>ignorar</button>
              </span>
            )}
          </div>
          {itens?.erro && <div className="error-banner">{itens.erro}</div>}
          {!itens && <div className="oi-carregando"><div className="spinner" /></div>}
          {itens?.itens && (
            <>
              <div className="table-scroll">
                <table className="oi-tabela oi-tabela-itens" data-testid="imp-itens">
                  <thead><tr><th>Poste</th><th>Classificação</th><th>Situação</th><th>Detalhe</th>{filtro === 'CONFLITO' && <th>Decisão</th>}</tr></thead>
                  <tbody>
                    {itens.itens.length === 0 && <tr><td colSpan={5} className="oi-muted">Nenhum item.</td></tr>}
                    {itens.itens.map((i) => (
                      <tr key={i.id} data-testid="imp-item">
                        <td className="om-mono">{i.id_externo || '(sem número)'}{i.linha != null && <div className="oi-muted">linha {i.linha + 1}</div>}</td>
                        <td><span className="oi-classe" style={{ borderColor: COR[i.classificacao], color: COR[i.classificacao] }}>{NOME[i.classificacao]}</span></td>
                        <td>{i.situacao_fonte || '—'}</td>
                        <td className="oi-detalhe-item">
                          {i.motivo && <div>{motivo(i.motivo)}</div>}
                          {i.diffs?.situacao_fonte && <div>situação: {i.diffs.situacao_fonte.anterior ?? '—'} → <b>{i.diffs.situacao_fonte.novo ?? '—'}</b></div>}
                          {i.diffs?.posicao && <div>posição: deslocou {n(i.diffs.posicao.distancia_m)} m</div>}
                          {i.diffs?.atributos_fonte && <div>atributos da fonte alterados</div>}
                          {i.diffs?.codigo_ibge && <div>passa a ter município {i.diffs.codigo_ibge.novo}</div>}
                          {!i.diffs && i.distancia_m > 0 && i.classificacao === 'CONFLITO' && <div>distância {n(i.distancia_m)} m</div>}
                          {(i.alertas || []).map((a, k) => <div key={k} className="oi-alerta-item">⚠ {ALERTAS[a.tipo] || a.tipo}{a.id_externo ? ` (${a.id_externo}${a.distancia_m != null ? `, ${n(a.distancia_m)} m` : ''})` : ''}</div>)}
                          {i.aplicado && imp.status === 'IMPORTADA' && <div className="oi-muted">aplicado</div>}
                        </td>
                        {filtro === 'CONFLITO' && (
                          <td className="oi-decisao">
                            {i.decisao ? <b data-testid="imp-decisao">{i.decisao === 'APLICAR' ? 'Aplicar' : 'Ignorar'}</b> : <span className="oi-muted">pendente</span>}
                            {emPrevia && podeDecidir && (
                              <div>
                                <button type="button" className="btn btn-sm btn-secondary" disabled={i.decisao === 'APLICAR'} onClick={() => decidir([i.id], 'APLICAR')} data-testid="imp-aplicar">Aplicar</button>
                                <button type="button" className="btn btn-sm btn-secondary" disabled={i.decisao === 'IGNORAR'} onClick={() => decidir([i.id], 'IGNORAR')} data-testid="imp-ignorar">Ignorar</button>
                              </div>
                            )}
                          </td>
                        )}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <div className="oi-paginacao">
                <span className="oi-muted">{n(itens.total)} itens</span>
                <button type="button" className="btn btn-sm btn-secondary" disabled={pagina === 0} onClick={() => setPagina((p) => p - 1)}>anterior</button>
                <span>página {pagina + 1} de {Math.max(1, Math.ceil(itens.total / POR_PAGINA))}</span>
                <button type="button" className="btn btn-sm btn-secondary" disabled={(pagina + 1) * POR_PAGINA >= itens.total} onClick={() => setPagina((p) => p + 1)}>próxima</button>
              </div>
            </>
          )}
        </div>
      </div>

      {modal === 'aprovar' && (
        <Modal
          titulo="Aprovar e importar"
          texto={`Serão incluídos ${n(contagens.NOVO || 0)} postes, atualizados ${n(contagens.ATUALIZADO || 0)} (+ conflitos marcados “aplicar”), confirmados ${n(contagens.SEM_ALTERACAO || 0)} e marcados como não localizados os ausentes. Tudo é registrado e pode ser revertido.`}
          rotulo="Aprovar e importar"
          onFechar={() => setModal(null)}
          onConfirmar={async () => {
            const r = await api.optimap.importacoes.aprovar(id, { confirmar_ausencias: confirmaAusencias });
            await depois(`Importação aplicada: ${n(r.inseridos)} incluídos, ${n(r.atualizados)} atualizados, ${n(r.confirmados)} confirmados, ${n(r.nao_localizados)} marcados como não localizados, ${n(r.conflitos_ignorados)} conflitos ignorados.`);
          }}
        />
      )}
      {modal === 'reprocessar' && (
        <Modal titulo="Recalcular prévia" texto="Compara de novo o arquivo com o cadastro atual. Decisões de conflito iguais são mantidas." rotulo="Recalcular"
          onFechar={() => setModal(null)} onConfirmar={async () => { await api.optimap.importacoes.reprocessar(id); await depois('Prévia recalculada.'); }} />
      )}
      {modal === 'descartar' && (
        <Modal titulo="Descartar importação" texto="A prévia fica no histórico como descartada. Nada foi aplicado." rotulo="Descartar"
          onFechar={() => setModal(null)} onConfirmar={async (m) => { await api.optimap.importacoes.descartar(id, m || null); await depois('Importação descartada.'); }} />
      )}
      {modal === 'rejeitar' && (
        <Modal titulo="Rejeitar importação" texto="Nada será aplicado. O motivo fica registrado na auditoria." rotulo="Rejeitar" perigo exigeMotivo
          onFechar={() => setModal(null)} onConfirmar={async (m) => { await api.optimap.importacoes.rejeitar(id, m); await depois('Importação rejeitada.'); }} />
      )}
      {modal === 'reverter' && (
        <Modal
          titulo="Reverter importação"
          texto="Desfaz, em ordem inversa, só o que esta importação gravou e que continua exatamente como ela deixou. Postes alterados depois (por outra importação ou à mão) ou que viraram poste da rede NICK não são tocados — ficam listados para análise."
          rotulo="Reverter"
          perigo
          exigeMotivo
          onFechar={() => setModal(null)}
          onConfirmar={async (m) => {
            const r = await api.optimap.importacoes.reverter(id, m);
            await depois(r.status === 'REVERTIDA' ? `Reversão completa (${n(r.revertidas_agora)} alterações desfeitas).` : `Reversão parcial: ${n(r.revertidas_agora)} desfeitas, ${n(r.pendentes)} mantidas (${Object.entries(r.motivos || {}).map(([k, v]) => `${motivo(k)}: ${n(v)}`).join(' · ')}).`);
          }}
        />
      )}
      <div className="oi-rodape"><button type="button" className="om-link" onClick={() => navigate('/optimap/importacoes')}>← voltar às importações</button></div>
    </div>
  );
}

// ===========================================================================
export default function OptiMapImportacoes() {
  const { id } = useParams();
  const [sessao, setSessao] = useState({ carregando: true });
  useEffect(() => {
    let vivo = true;
    api.optimap.sessao()
      .then((s) => vivo && setSessao({ ...s, carregando: false }))
      .catch((e) => vivo && setSessao({ carregando: false, erro: e.message, status: e.status }));
    return () => { vivo = false; };
  }, []);
  const conteudo = useMemo(() => {
    if (sessao.carregando) return <div className="page oi-carregando"><div className="spinner" /> Verificando acesso…</div>;
    if (sessao.erro || !sessao.pode_ver_importacoes) {
      return (
        <div className="page"><div className="card" role="alert" data-testid="imp-sem-acesso">
          <h2>Sem acesso às importações</h2>
          <p>{sessao.erro && sessao.status !== 403 ? `Não foi possível falar com a API (${sessao.erro}).` : 'Importações de postes são acessíveis a ENGENHARIA, DIRETOR e ADMINISTRADOR.'}</p>
          <Link to="/optimap">← voltar ao mapa</Link>
        </div></div>
      );
    }
    return id ? <Detalhe key={id} id={id} sessao={sessao} /> : <Lista sessao={sessao} />;
  }, [sessao, id]);
  return conteudo;
}
