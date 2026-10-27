// OptiMap — painel lateral de detalhes. Mostra SÓ os campos que existem no registro
// devolvido pela API (schema real da Fase 2); campo ausente/nulo não é exibido nem
// inventado. Dado externo (postes de referência) recebe destaque próprio.

import { useState } from 'react';
import { ROTULO_ESTADO, ROTULO_ELEMENTO, ROTULO_SYNC, ROTULO_OCUPACAO, CORES } from './config';
import { api } from '../lib/api';

const fmtData = (v) => (v ? new Date(v).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : null);
const fmtCoord = (lon, lat) => `${Number(lat).toFixed(6)}, ${Number(lon).toFixed(6)}`;

function Campo({ rotulo, children, mono }) {
  if (children === null || children === undefined || children === '' || children === false) return null;
  return (
    <div className="om-campo">
      <dt>{rotulo}</dt>
      <dd className={mono ? 'om-mono' : undefined}>{children}</dd>
    </div>
  );
}

function Coordenadas({ geometry }) {
  if (!geometry) return null;
  if (geometry.type === 'Point') {
    const [lon, lat] = geometry.coordinates;
    const txt = fmtCoord(lon, lat);
    return (
      <Campo rotulo="Coordenadas (lat, lon — WGS84)" mono>
        {txt}{' '}
        <button type="button" className="om-link" onClick={() => navigator.clipboard?.writeText(txt)} title="Copiar">copiar</button>
      </Campo>
    );
  }
  if (geometry.type === 'LineString') {
    const n = geometry.coordinates.length;
    const [lonA, latA] = geometry.coordinates[0];
    const [lonB, latB] = geometry.coordinates[n - 1];
    return (
      <>
        <Campo rotulo="Traçado">{`${n} vértices`}</Campo>
        <Campo rotulo="Início (lat, lon)" mono>{fmtCoord(lonA, latA)}</Campo>
        <Campo rotulo="Fim (lat, lon)" mono>{fmtCoord(lonB, latB)}</Campo>
      </>
    );
  }
  return null;
}

function Estado({ estado }) {
  if (!estado) return null;
  return <span className={`om-badge om-estado-${estado.toLowerCase()}`}>{ROTULO_ESTADO[estado] || estado}</span>;
}

function Fonte({ fonte, dataReferencia }) {
  if (!fonte) return null;
  return (
    <section className="om-secao">
      <h4>Origem do dado</h4>
      <dl>
        <Campo rotulo="Fonte">{fonte.nome}</Campo>
        <Campo rotulo="Tipo">{fonte.tipo === 'EXTERNA' ? 'Externa (referência)' : 'Própria (NICK)'}</Campo>
        <Campo rotulo="Atribuição">{fonte.atribuicao}</Campo>
        <Campo rotulo="Data de referência">{fmtData(dataReferencia)}</Campo>
        <Campo rotulo="Termos verificados em">{fonte.termos_verificados_em ? new Date(`${fonte.termos_verificados_em}T12:00:00`).toLocaleDateString('pt-BR') : null}</Campo>
      </dl>
      {fonte.termos_uso && <p className="om-nota">{fonte.termos_uso}</p>}
    </section>
  );
}

function Validacao({ d }) {
  const nome = (id) => (id ? d.usuarios?.[id] || 'usuário não identificado' : null);
  return (
    <section className="om-secao">
      <h4>Validação e registro</h4>
      <dl>
        <Campo rotulo="Validado por">{nome(d.validado_por)}</Campo>
        <Campo rotulo="Validado em">{fmtData(d.validado_em)}</Campo>
        <Campo rotulo="Cadastrado por">{nome(d.criado_por)}</Campo>
        <Campo rotulo="Cadastrado em">{fmtData(d.criado_em)}</Campo>
        <Campo rotulo="Última atualização">{fmtData(d.atualizado_em)}</Campo>
      </dl>
      {Array.isArray(d.historico_estado) && d.historico_estado.length > 0 && (
        <>
          <h5>Histórico de estado</h5>
          <ol className="om-historico">
            {d.historico_estado.map((h, i) => (
              <li key={i}>
                <strong>{h.estado_anterior ? `${ROTULO_ESTADO[h.estado_anterior] || h.estado_anterior} → ` : ''}{ROTULO_ESTADO[h.estado_novo] || h.estado_novo}</strong>
                <span>{fmtData(h.criado_em)} · {nome(h.usuario_id) || '—'}</span>
                {h.motivo && <em>{h.motivo}</em>}
              </li>
            ))}
          </ol>
        </>
      )}
    </section>
  );
}

function Ponta({ p }) {
  if (!p) return null;
  if (p.tipo === 'pop') return `POP ${nomeVinculo(p, 'codigo', 'nome')}`;
  return `${ROTULO_ELEMENTO[p.tipo_elemento] || 'Elemento'} ${nomeVinculo(p, 'codigo', 'nome')}`;
}

const nomeVinculo = (v, ...campos) => (v ? campos.map((c) => v[c]).filter(Boolean).join(' — ') || v.id : null);

export default function PainelDetalhe({ estado, onFechar, onSelecionar, sessao = {}, empresas = [], onOcupacaoAlterada }) {
  if (!estado) return null;
  const { carregando, erro, dados: d, candidatos, coordenada } = estado;

  return (
    <aside className="om-painel om-detalhe" aria-label="Detalhes do elemento" data-testid="painel-detalhe">
      <button type="button" className="om-fechar" onClick={onFechar} aria-label="Fechar detalhes">×</button>
      {carregando && <div className="om-carregando"><div className="spinner" /> Carregando detalhes…</div>}
      {erro && <div className="om-alerta om-alerta-erro" role="alert">{erro}</div>}

      {coordenada && (
        <>
          <p className="om-sobretitulo">Coordenada pesquisada</p>
          <h3 className="om-mono">{fmtCoord(coordenada.lon, coordenada.lat)}</h3>
          <p className="om-nota">Nenhum elemento selecionado. O marcador indica só a posição digitada; clique num elemento do mapa para ver detalhes.</p>
        </>
      )}

      {candidatos && (
        <>
          <p className="om-sobretitulo">Seleção</p>
          <h3>{candidatos.length} elementos neste ponto</h3>
          <ul className="om-candidatos">
            {candidatos.map((c) => (
              <li key={`${c.camada}:${c.id}`}>
                <button type="button" onClick={() => onSelecionar(c.camada, c.id)}>{c.rotulo}</button>
              </li>
            ))}
          </ul>
        </>
      )}

      {d && !carregando && <Conteudo d={d} onSelecionar={onSelecionar} sessao={sessao} empresas={empresas} onOcupacaoAlterada={onOcupacaoAlterada} />}
    </aside>
  );
}

function Conteudo({ d, onSelecionar, sessao, empresas, onOcupacaoAlterada }) {
  const v = d.vinculos || {};
  if (d.camada === 'postes_referencia') {
    return (
      <>
        <div className="om-faixa-externa" role="note">
          Poste da concessionária. A ocupação por empresa aparece abaixo: vem da lista de projetos aprovados do CES ou de marcação da engenharia.
        </div>
        <p className="om-sobretitulo">Poste de referência externa</p>
        <h3>Poste {d.id_externo}</h3>
        <dl>
          <Campo rotulo="Número do poste (fonte)" mono>{d.id_externo}</Campo>
          <Campo rotulo="Situação informada pela fonte">{d.situacao_fonte}</Campo>
          <Campo rotulo="Sincronização">{ROTULO_SYNC[d.estado_sincronizacao] || d.estado_sincronizacao}</Campo>
          <Campo rotulo="Cidade">{nomeVinculo(v.cidade, 'nome', 'uf')}</Campo>
          <Coordenadas geometry={d.geometry} />
          <Campo rotulo="Primeira coleta">{fmtData(d.primeira_coleta_em)}</Campo>
          <Campo rotulo="Última coleta">{fmtData(d.ultima_coleta_em)}</Campo>
          <Campo rotulo="Vinculado a poste da NICK no OptiMap">
            {d.poste_nick
              ? <button type="button" className="om-link" onClick={() => onSelecionar('postes', d.poste_nick.id)}>Sim — ver poste da NICK ({ROTULO_ESTADO[d.poste_nick.estado]})</button>
              : 'Não há poste da NICK vinculado a esta referência'}
          </Campo>
        </dl>
        <Ocupacoes d={d} sessao={sessao} empresas={empresas} onAlterada={() => onOcupacaoAlterada?.(d.id)} />
        {d.atributos_fonte && Object.keys(d.atributos_fonte).length > 0 && (
          <section className="om-secao">
            <h4>Atributos como recebidos da fonte</h4>
            <dl>{Object.entries(d.atributos_fonte).map(([k, val]) => <Campo key={k} rotulo={k} mono>{String(val)}</Campo>)}</dl>
          </section>
        )}
        <Fonte fonte={d.fonte} dataReferencia={d.data_referencia} />
      </>
    );
  }

  if (d.camada === 'pops') {
    return (
      <>
        <p className="om-sobretitulo">POP</p>
        <h3>{d.codigo}</h3>
        <dl>
          <Campo rotulo="Nome">{d.nome}</Campo>
          <Campo rotulo="Tipo">{d.tipo}</Campo>
          <Campo rotulo="Status">{d.status}</Campo>
          <Campo rotulo="Cidade">{nomeVinculo(d.cidade, 'nome', 'uf')}</Campo>
          <Campo rotulo="Endereço">{d.endereco}</Campo>
          <Coordenadas geometry={d.geometry} />
          <Campo rotulo="Capacidade (informativa)">{d.capacidade_total}</Campo>
          <Campo rotulo="Observações">{d.observacoes}</Campo>
          <Campo rotulo="Última atualização">{fmtData(d.atualizado_em)}</Campo>
        </dl>
        <Fonte fonte={d.fonte} />
      </>
    );
  }

  const titulo = {
    postes: ['Poste da NICK', d.codigo || 'sem código'],
    elementos: [ROTULO_ELEMENTO[d.tipo] || d.tipo, d.codigo || d.nome || 'sem código'],
    trechos: ['Trecho de cabo', d.codigo || 'sem código'],
  }[d.camada] || ['Elemento', d.id];

  return (
    <>
      <p className="om-sobretitulo">{titulo[0]} · Rede NICK</p>
      <h3>{titulo[1]} <Estado estado={d.estado} /></h3>
      <dl>
        {d.camada === 'elementos' && <Campo rotulo="Nome">{d.nome}</Campo>}
        {d.camada === 'trechos' && <Campo rotulo="Instalação">{d.tipo_instalacao}</Campo>}
        {d.camada === 'trechos' && <Campo rotulo="Comprimento do traçado">{d.comprimento_geo_m != null ? `${Number(d.comprimento_geo_m).toLocaleString('pt-BR')} m` : null}</Campo>}
        <Campo rotulo="Cidade">{nomeVinculo(v.cidade, 'nome', 'uf')}</Campo>
        <Coordenadas geometry={d.geometry} />
        {d.camada === 'postes' && <Campo rotulo="Proprietário">{d.proprietario}</Campo>}
        <Campo rotulo="Lote de faturamento">{nomeVinculo(v.lote_postes, 'identificacao') && `${nomeVinculo(v.lote_postes, 'identificacao')}${v.lote_postes.quantidade ? ` (${v.lote_postes.quantidade} postes no lote)` : ''}`}</Campo>
        {d.camada === 'postes' && d.poste_referencia_id && (
          <Campo rotulo="Poste de referência">
            <button type="button" className="om-link" onClick={() => onSelecionar('postes_referencia', d.poste_referencia_id)}>ver referência da concessionária</button>
          </Campo>
        )}
        <Campo rotulo="Poste">{v.poste && <button type="button" className="om-link" onClick={() => onSelecionar('postes', v.poste.id)}>{v.poste.codigo || v.poste.id}</button>}</Campo>
        <Campo rotulo="POP">{nomeVinculo(v.pop, 'codigo', 'nome')}</Campo>
        <Campo rotulo="Segmento">{nomeVinculo(v.segmento, 'nome')}</Campo>
        <Campo rotulo="Cabo">{nomeVinculo(v.cabo, 'identificacao')}</Campo>
        <Campo rotulo="Ponta A"><Ponta p={v.ponta_a} /></Campo>
        <Campo rotulo="Ponta B"><Ponta p={v.ponta_b} /></Campo>
        <Campo rotulo="Observações">{d.observacoes}</Campo>
      </dl>
      {d.camada === 'elementos' && d.atributos && Object.keys(d.atributos).length > 0 && (
        <section className="om-secao">
          <h4>Atributos técnicos</h4>
          <dl>{Object.entries(d.atributos).map(([k, val]) => <Campo key={k} rotulo={k} mono>{typeof val === 'object' ? JSON.stringify(val) : String(val)}</Campo>)}</dl>
        </section>
      )}
      <Fonte fonte={d.fonte} />
      <Validacao d={d} />
    </>
  );
}

// ---------------------------------------------------------------------------
// Fase 5 — ocupações do poste (empresa / contrato / UC) e marcação pela engenharia.
// ---------------------------------------------------------------------------
const EMPRESA_KEY = 'optimap_ultima_empresa_marcacao_v1';
// Pré-seleciona a última empresa usada nesta máquina (comodidade; a escolha é sempre visível).
function empresaPadrao(lista) {
  try {
    const u = window.localStorage.getItem(EMPRESA_KEY);
    if (u && lista.some((e) => e.id === u)) return u;
  } catch { /* storage indisponível */ }
  return lista[0].id;
}

function Ocupacoes({ d, sessao, empresas, onAlterada }) {
  const lista = Array.isArray(d.ocupacoes) ? d.ocupacoes : [];
  const ativas = lista.filter((o) => o.estado !== 'ENCERRADA');
  const historico = lista.filter((o) => o.estado === 'ENCERRADA');
  const [form, setForm] = useState(null); // { modo: 'marcar', empresa_id, motivo } | { modo: 'encerrar', id, motivo }
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState(null);
  const nome = (id) => (id ? d.usuarios?.[id] || 'usuário não identificado' : null);
  const ativasEmpresas = empresas.filter((e) => e.ativa);

  const enviar = async () => {
    setEnviando(true); setErro(null);
    try {
      if (form.modo === 'marcar') {
        await api.optimap.ocupacoes.marcar({ poste_referencia_id: d.id, empresa_id: form.empresa_id, motivo: form.motivo });
        try { window.localStorage.setItem(EMPRESA_KEY, form.empresa_id); } catch { /* ignora */ }
      }
      else await api.optimap.ocupacoes.encerrar(form.id, form.motivo);
      setForm(null);
      onAlterada?.();
    } catch (e) {
      setErro(e.message);
    } finally {
      setEnviando(false);
    }
  };

  return (
    <section className="om-secao" data-testid="painel-ocupacoes">
      <h4>Ocupação por empresa</h4>
      {ativas.length === 0 && <p className="om-nota">Nenhuma empresa cadastrada ocupa este poste (nem na lista do CES, nem marcada pela engenharia).</p>}
      <ul className="om-ocupacoes">
        {ativas.map((o) => (
          <li key={o.id} className={`om-ocupacao om-ocupacao-${o.tipo.toLowerCase()}`} data-testid="ocupacao">
            <span className="om-ponto" style={{ background: CORES.categoria[o.estado === 'ATIVA' ? o.tipo : 'OUTRO'] }} aria-hidden="true" />
            <div>
              <strong>{o.empresa?.nome_fantasia || o.empresa?.razao_social}</strong>
              <span>{ROTULO_OCUPACAO.tipo[o.tipo]}{o.estado !== 'ATIVA' ? ` · ${ROTULO_OCUPACAO.estado[o.estado]}` : ''}</span>
              <dl>
                <Campo rotulo="Razão social">{o.empresa?.razao_social}</Campo>
                <Campo rotulo="UC Copel" mono>{o.empresa?.uc_copel}</Campo>
                <Campo rotulo="Contrato">{o.empresa?.contrato_copel}</Campo>
                <Campo rotulo={o.origem === 'CES' ? 'Lista do CES de' : 'Marcado em'}>{fmtData(o.origem === 'CES' ? o.data_referencia : o.criado_em)}</Campo>
                {o.origem === 'MARCACAO' && <Campo rotulo="Marcado por">{nome(o.criado_por)}</Campo>}
                {o.origem === 'MARCACAO' && <Campo rotulo="Descrição">{o.motivo}</Campo>}
              </dl>
              {o.origem === 'MARCACAO' && o.estado === 'ATIVA' && sessao.pode_marcar_ocupacao && !form && (
                <button type="button" className="om-link" onClick={() => { setErro(null); setForm({ modo: 'encerrar', id: o.id, motivo: '' }); }} data-testid="ocupacao-encerrar">encerrar marcação</button>
              )}
            </div>
          </li>
        ))}
      </ul>

      {sessao.pode_marcar_ocupacao && !form && ativasEmpresas.length > 0 && (
        <button type="button" className="btn btn-secondary om-btn-marcar" onClick={() => { setErro(null); setForm({ modo: 'marcar', empresa_id: empresaPadrao(ativasEmpresas), motivo: '' }); }} data-testid="ocupacao-marcar">
          Marcar “ocupado sem projeto aprovado”
        </button>
      )}

      {form && (
        <div className="om-form-ocupacao" data-testid="form-ocupacao">
          {form.modo === 'marcar' ? (
            <>
              <label>Empresa
                <select value={form.empresa_id} onChange={(e) => setForm({ ...form, empresa_id: e.target.value })} data-testid="form-ocupacao-empresa">
                  {ativasEmpresas.map((e) => <option key={e.id} value={e.id}>{e.nome_fantasia || e.razao_social} — UC {e.uc_copel || '—'}</option>)}
                </select>
              </label>
              <label>Descrição (obrigatória)
                <textarea rows={2} maxLength={1000} value={form.motivo} placeholder="Ex.: cabo existente, levantamento de campo de 20/10" onChange={(e) => setForm({ ...form, motivo: e.target.value })} data-testid="form-ocupacao-motivo" />
              </label>
            </>
          ) : (
            <label>Motivo do encerramento (obrigatório)
              <textarea rows={2} maxLength={1000} value={form.motivo} placeholder="Ex.: cabo retirado / marcado no poste errado" onChange={(e) => setForm({ ...form, motivo: e.target.value })} data-testid="form-ocupacao-motivo" />
            </label>
          )}
          {erro && <div className="om-alerta om-alerta-erro" role="alert">{erro}</div>}
          <div className="om-form-acoes">
            <button type="button" className="btn btn-primary" disabled={enviando || form.motivo.trim().length < 3} onClick={enviar} data-testid="form-ocupacao-confirmar">
              {enviando ? 'Salvando…' : form.modo === 'marcar' ? 'Marcar ocupação' : 'Encerrar marcação'}
            </button>
            <button type="button" className="btn btn-secondary" disabled={enviando} onClick={() => setForm(null)}>Cancelar</button>
          </div>
        </div>
      )}

      {historico.length > 0 && (
        <details className="om-historico-ocupacoes">
          <summary>{historico.length} marcação(ões) encerrada(s)</summary>
          <ol className="om-historico">
            {historico.map((o) => (
              <li key={o.id}>
                <strong>{o.empresa?.nome_fantasia || o.empresa?.razao_social} — {ROTULO_OCUPACAO.tipo[o.tipo]}</strong>
                <span>{fmtData(o.criado_em)} → {fmtData(o.encerrado_em)}</span>
                {o.motivo_encerramento && <em>{o.motivo_encerramento}</em>}
              </li>
            ))}
          </ol>
        </details>
      )}
    </section>
  );
}
