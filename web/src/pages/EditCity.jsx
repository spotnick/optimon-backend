import { useCallback, useEffect, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { api, ApiError } from '../lib/api';

const FIBRA_STATUS = ['LIVRE', 'OCUPADA', 'RESERVADA', 'LOCADA', 'MANUTENCAO', 'BLOQUEADA'];

function Field({ label, children }) {
  return (
    <div className="field">
      <label>{label}</label>
      {children}
    </div>
  );
}

// --- Dados da cidade -------------------------------------------------------------

function CityFieldsForm({ city, onSaved }) {
  const [nome, setNome] = useState(city.nome);
  const [uf, setUf] = useState(city.uf);
  const [codigoIbge, setCodigoIbge] = useState(city.codigo_ibge || '');
  const [endereco, setEndereco] = useState(city.endereco || '');
  const [kmRede, setKmRede] = useState(city.km_rede);
  const [observacoes, setObservacoes] = useState(city.observacoes || '');
  const [status, setStatus] = useState(city.status);
  const [saving, setSaving] = useState(false);
  const [archiving, setArchiving] = useState(false);
  const [error, setError] = useState(null);
  const navigate = useNavigate();

  async function handleSave(e) {
    e.preventDefault();
    setError(null);
    setSaving(true);
    try {
      await api.cities.update(city.cidade_id, {
        nome, uf, codigo_ibge: codigoIbge || null, endereco: endereco || null,
        km_rede: Number(kmRede), observacoes: observacoes || null, status,
      });
      onSaved();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao salvar.');
    } finally {
      setSaving(false);
    }
  }

  async function handleArchive() {
    setError(null);
    setArchiving(true);
    try {
      await api.cities.archive(city.cidade_id);
      navigate('/cidades');
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao arquivar.');
    } finally {
      setArchiving(false);
    }
  }

  return (
    <form className="card" onSubmit={handleSave} style={{ marginBottom: 28 }}>
      <h2 className="section-title">Dados da cidade</h2>
      {error && <div className="error-banner" style={{ marginBottom: 16 }}>{error}</div>}
      <div className="form-grid">
        <Field label="Nome *"><input value={nome} onChange={(e) => setNome(e.target.value)} required /></Field>
        <Field label="UF *"><input value={uf} onChange={(e) => setUf(e.target.value)} maxLength={2} required /></Field>
        <Field label="Código IBGE"><input value={codigoIbge} onChange={(e) => setCodigoIbge(e.target.value)} /></Field>
        <Field label="KM de rede *"><input type="number" min="0" step="0.001" value={kmRede} onChange={(e) => setKmRede(e.target.value)} required /></Field>
        <Field label="Status">
          <select value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="ATIVA">Ativa</option>
            <option value="PLANEJADA">Planejada</option>
            <option value="INATIVA">Inativa</option>
          </select>
        </Field>
        <Field label="Endereço/base"><input value={endereco} onChange={(e) => setEndereco(e.target.value)} /></Field>
        <div className="field" style={{ gridColumn: '1 / -1' }}>
          <label>Observações</label>
          <input value={observacoes} onChange={(e) => setObservacoes(e.target.value)} />
        </div>
      </div>
      <div style={{ display: 'flex', gap: 12, marginTop: 20, justifyContent: 'space-between' }}>
        <button type="submit" className="btn btn-primary" disabled={saving}>{saving ? 'Salvando…' : 'Salvar alterações'}</button>
        <button type="button" className="btn btn-secondary" onClick={handleArchive} disabled={archiving}>
          {archiving ? 'Arquivando…' : 'Arquivar cidade'}
        </button>
      </div>
    </form>
  );
}

// --- POPs --------------------------------------------------------------------------

function PopsSection({ cidadeId, pops, onChanged }) {
  const [codigo, setCodigo] = useState('');
  const [nome, setNome] = useState('');
  const [tipo, setTipo] = useState('ACESSO');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function handleAdd(e) {
    e.preventDefault();
    setError(null);
    if (!codigo.trim() || !nome.trim()) { setError('Código e nome são obrigatórios.'); return; }
    setSaving(true);
    try {
      await api.infra.createPop({ cidade_id: cidadeId, codigo: codigo.trim(), nome: nome.trim(), tipo });
      setCodigo(''); setNome('');
      onChanged();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao criar POP.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <h3 className="section-title">POPs</h3>
      {pops.length === 0 && <p style={{ color: 'var(--text-muted)', marginBottom: 12 }}>Nenhum POP cadastrado ainda.</p>}
      {pops.length > 0 && (
        <ul style={{ marginBottom: 16, paddingLeft: 18 }}>
          {pops.map((p) => (
            <li key={p.pop_id} style={{ marginBottom: 4 }}>
              <strong style={{ fontFamily: 'var(--font-mono)' }}>{p.codigo}</strong> — {p.nome} ({p.tipo}) · {p.cabos.length} cabo(s) · {p.portas_pon.length} porta(s) PON
            </li>
          ))}
        </ul>
      )}
      <form onSubmit={handleAdd} className="form-grid">
        {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
        <Field label="Código *"><input value={codigo} onChange={(e) => setCodigo(e.target.value)} placeholder="POP-02" /></Field>
        <Field label="Nome *"><input value={nome} onChange={(e) => setNome(e.target.value)} placeholder="POP-02 — Distribuição" /></Field>
        <Field label="Tipo">
          <select value={tipo} onChange={(e) => setTipo(e.target.value)}>
            <option value="PRINCIPAL">Principal</option>
            <option value="DISTRIBUICAO">Distribuição</option>
            <option value="ACESSO">Acesso</option>
            <option value="OUTRO">Outro</option>
          </select>
        </Field>
      </form>
      <button type="button" className="btn btn-secondary" onClick={handleAdd} disabled={saving} style={{ marginTop: 12 }}>
        {saving ? 'Adicionando…' : '+ Novo POP'}
      </button>
    </div>
  );
}

// --- Segmentos -----------------------------------------------------------------

function SegmentsSection({ cidadeId, segmentos, onChanged }) {
  const [nome, setNome] = useState('');
  const [origem, setOrigem] = useState('');
  const [destino, setDestino] = useState('');
  const [extensao, setExtensao] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function handleAdd(e) {
    e.preventDefault();
    setError(null);
    if (!nome.trim() || !origem.trim() || !destino.trim() || !extensao) {
      setError('Nome, origem, destino e extensão são obrigatórios.'); return;
    }
    setSaving(true);
    try {
      await api.infra.createSegment({ cidade_id: cidadeId, nome: nome.trim(), origem: origem.trim(), destino: destino.trim(), extensao_km: Number(extensao) });
      setNome(''); setOrigem(''); setDestino(''); setExtensao('');
      onChanged();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao criar segmento.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <h3 className="section-title">Segmentos</h3>
      {segmentos.length === 0 && <p style={{ color: 'var(--text-muted)', marginBottom: 12 }}>Nenhum segmento cadastrado ainda.</p>}
      {segmentos.length > 0 && (
        <ul style={{ marginBottom: 16, paddingLeft: 18 }}>
          {segmentos.map((s) => (
            <li key={s.segmento_id} style={{ marginBottom: 4 }}>{s.nome} — {s.origem} → {s.destino} ({Number(s.extensao_km).toLocaleString('pt-BR')} km)</li>
          ))}
        </ul>
      )}
      <form onSubmit={handleAdd} className="form-grid">
        {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
        <Field label="Nome *"><input value={nome} onChange={(e) => setNome(e.target.value)} /></Field>
        <Field label="Origem *"><input value={origem} onChange={(e) => setOrigem(e.target.value)} /></Field>
        <Field label="Destino *"><input value={destino} onChange={(e) => setDestino(e.target.value)} /></Field>
        <Field label="Extensão (km) *"><input type="number" min="0" step="0.001" value={extensao} onChange={(e) => setExtensao(e.target.value)} /></Field>
      </form>
      <button type="button" className="btn btn-secondary" onClick={handleAdd} disabled={saving} style={{ marginTop: 12 }}>
        {saving ? 'Adicionando…' : 'Novo Segmento'}
      </button>
    </div>
  );
}

// --- Cabos + fibras --------------------------------------------------------------

function FibraStatusRow({ fibra, onChanged }) {
  const [saving, setSaving] = useState(false);
  async function handleChange(e) {
    setSaving(true);
    try {
      await api.infra.updateFiber(fibra.fibra_id, { status: e.target.value });
      onChanged();
    } finally {
      setSaving(false);
    }
  }
  return (
    <tr>
      <td className="num">{fibra.numero_fibra}</td>
      <td className="num">{fibra.par_numero}</td>
      <td>
        <select value={fibra.status} onChange={handleChange} disabled={saving}>
          {FIBRA_STATUS.map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
      </td>
      <td style={{ color: 'var(--text-muted)', fontSize: '0.82rem' }}>{fibra.observacao || '—'}</td>
    </tr>
  );
}

function CablesSection({ pops, segmentos, onChanged }) {
  const [popId, setPopId] = useState('');
  const [segmentoId, setSegmentoId] = useState('');
  const [identificacao, setIdentificacao] = useState('');
  const [capacidadeFo, setCapacidadeFo] = useState('12');
  const [fabricante, setFabricante] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [expanded, setExpanded] = useState(null);

  async function handleAdd(e) {
    e.preventDefault();
    setError(null);
    if (!segmentoId || !identificacao.trim() || !capacidadeFo) {
      setError('Segmento, identificação e capacidade de FO são obrigatórios.'); return;
    }
    setSaving(true);
    try {
      await api.infra.createCable({
        segmento_id: segmentoId, pop_id: popId || null, identificacao: identificacao.trim(),
        capacidade_fo: Number(capacidadeFo), fabricante: fabricante || null,
      });
      setIdentificacao(''); setFabricante('');
      onChanged();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao criar cabo.');
    } finally {
      setSaving(false);
    }
  }

  const allCables = pops.flatMap((p) => p.cabos.map((c) => ({ ...c, pop_codigo: p.codigo })));

  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <h3 className="section-title">Cabos</h3>
      {allCables.length === 0 && <p style={{ color: 'var(--text-muted)', marginBottom: 12 }}>Nenhum cabo cadastrado ainda.</p>}
      {allCables.length > 0 && (
        <div style={{ marginBottom: 16 }}>
          {allCables.map((c) => (
            <div key={c.cabo_id} style={{ marginBottom: 8 }}>
              <button
                type="button"
                className="link-tab"
                style={{ fontSize: '0.88rem' }}
                onClick={() => setExpanded(expanded === c.cabo_id ? null : c.cabo_id)}
              >
                {expanded === c.cabo_id ? '▾' : '▸'} {c.identificacao} — {c.capacidade_fo} FO ({c.pop_codigo || 'sem POP'})
              </button>
              {expanded === c.cabo_id && (
                <div className="table-scroll" style={{ marginTop: 8 }}>
                  <table>
                    <thead><tr><th className="num">Número</th><th className="num">Par</th><th>Status</th><th>Observação</th></tr></thead>
                    <tbody>
                      {c.fibras.map((f) => <FibraStatusRow key={f.fibra_id} fibra={f} onChanged={onChanged} />)}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          ))}
        </div>
      )}
      <form onSubmit={handleAdd} className="form-grid">
        {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
        <Field label="Segmento *">
          <select value={segmentoId} onChange={(e) => setSegmentoId(e.target.value)}>
            <option value="">Selecione…</option>
            {segmentos.map((s) => <option key={s.segmento_id} value={s.segmento_id}>{s.nome}</option>)}
          </select>
        </Field>
        <Field label="POP">
          <select value={popId} onChange={(e) => setPopId(e.target.value)}>
            <option value="">(sem POP)</option>
            {pops.map((p) => <option key={p.pop_id} value={p.pop_id}>{p.codigo}</option>)}
          </select>
        </Field>
        <Field label="Identificação *"><input value={identificacao} onChange={(e) => setIdentificacao(e.target.value)} placeholder="CABO-02" /></Field>
        <Field label="Capacidade FO *"><input type="number" min="1" value={capacidadeFo} onChange={(e) => setCapacidadeFo(e.target.value)} /></Field>
        <Field label="Fabricante"><input value={fabricante} onChange={(e) => setFabricante(e.target.value)} /></Field>
      </form>
      <p style={{ fontSize: '0.8rem', color: 'var(--text-muted)', marginTop: 8 }}>
        Ao salvar, as fibras (1..capacidade) são geradas automaticamente como LIVRE.
      </p>
      <button type="button" className="btn btn-secondary" onClick={handleAdd} disabled={saving} style={{ marginTop: 8 }}>
        {saving ? 'Adicionando…' : 'Novo Cabo'}
      </button>
    </div>
  );
}

// --- Postes ------------------------------------------------------------------------

function PolesSection({ cidadeId, segmentos, postes, onChanged }) {
  const [segmentoId, setSegmentoId] = useState('');
  const [identificacao, setIdentificacao] = useState('');
  const [proprietario, setProprietario] = useState('');
  const [quantidade, setQuantidade] = useState('1');
  const [custoMensal, setCustoMensal] = useState('0');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function handleAdd(e) {
    e.preventDefault();
    setError(null);
    if (!quantidade) { setError('Quantidade é obrigatória.'); return; }
    setSaving(true);
    try {
      await api.infra.createPole({
        cidade_id: cidadeId, segmento_id: segmentoId || null, identificacao: identificacao || null,
        proprietario_terceiro: proprietario || null, quantidade: Number(quantidade), custo_mensal: Number(custoMensal),
      });
      setIdentificacao(''); setProprietario(''); setQuantidade('1'); setCustoMensal('0');
      onChanged();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao cadastrar postes.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <h3 className="section-title">Postes</h3>
      {postes.length === 0 && <p style={{ color: 'var(--text-muted)', marginBottom: 12 }}>Nenhum lote de postes cadastrado ainda.</p>}
      {postes.length > 0 && (
        <ul style={{ marginBottom: 16, paddingLeft: 18 }}>
          {postes.map((p) => (
            <li key={p.poste_id} style={{ marginBottom: 4 }}>
              {p.identificacao || 'Lote'} — {p.quantidade} poste(s){p.proprietario_terceiro ? ` (${p.proprietario_terceiro})` : ''} · R$ {Number(p.custo_mensal).toLocaleString('pt-BR')}/mês
            </li>
          ))}
        </ul>
      )}
      <form onSubmit={handleAdd} className="form-grid">
        {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
        <Field label="Identificação"><input value={identificacao} onChange={(e) => setIdentificacao(e.target.value)} placeholder="Lote de postes" /></Field>
        <Field label="Segmento">
          <select value={segmentoId} onChange={(e) => setSegmentoId(e.target.value)}>
            <option value="">(sem segmento)</option>
            {segmentos.map((s) => <option key={s.segmento_id} value={s.segmento_id}>{s.nome}</option>)}
          </select>
        </Field>
        <Field label="Proprietário terceiro"><input value={proprietario} onChange={(e) => setProprietario(e.target.value)} placeholder="Concessionária de energia" /></Field>
        <Field label="Quantidade *"><input type="number" min="1" value={quantidade} onChange={(e) => setQuantidade(e.target.value)} /></Field>
        <Field label="Custo mensal (R$)"><input type="number" min="0" step="0.01" value={custoMensal} onChange={(e) => setCustoMensal(e.target.value)} /></Field>
      </form>
      <button type="button" className="btn btn-secondary" onClick={handleAdd} disabled={saving} style={{ marginTop: 12 }}>
        {saving ? 'Adicionando…' : 'Cadastrar lote de postes'}
      </button>
    </div>
  );
}

// --- Portas PON --------------------------------------------------------------------

function PonPortsSection({ pops, onChanged }) {
  const [popId, setPopId] = useState('');
  const [fibraId, setFibraId] = useState('');
  const [codigoPorta, setCodigoPorta] = useState('');
  const [nome, setNome] = useState('');
  const [tecnologia, setTecnologia] = useState('GPON');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  const selectedPop = pops.find((p) => p.pop_id === popId);
  // Só fibras LIVRE do cabo do POP podem virar porta PON nova (unique(fibra_id) na tabela).
  const availableFibers = selectedPop
    ? selectedPop.cabos.flatMap((c) => c.fibras.filter((f) => f.status === 'LIVRE').map((f) => ({ ...f, cabo_identificacao: c.identificacao })))
    : [];

  async function handleAdd(e) {
    e.preventDefault();
    setError(null);
    if (!popId || !fibraId || !codigoPorta.trim()) { setError('POP, fibra e código da porta são obrigatórios.'); return; }
    setSaving(true);
    try {
      await api.infra.createPonPort({ fibra_id: fibraId, pop_id: popId, codigo_porta: codigoPorta.trim(), nome: nome || null, tecnologia });
      setCodigoPorta(''); setNome(''); setFibraId('');
      onChanged();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao criar porta PON.');
    } finally {
      setSaving(false);
    }
  }

  const allPorts = pops.flatMap((p) => p.portas_pon.map((pp) => ({ ...pp, pop_codigo: p.codigo })));

  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <h3 className="section-title">Portas PON</h3>
      {allPorts.length === 0 && <p style={{ color: 'var(--text-muted)', marginBottom: 12 }}>Nenhuma porta PON cadastrada ainda.</p>}
      {allPorts.length > 0 && (
        <ul style={{ marginBottom: 16, paddingLeft: 18 }}>
          {allPorts.map((pp) => (
            <li key={pp.porta_id} style={{ marginBottom: 4 }}>
              <strong style={{ fontFamily: 'var(--font-mono)' }}>{pp.codigo_porta}</strong> — {pp.pop_codigo} · {pp.cabo_identificacao} FO{pp.numero_fibra} · {pp.tecnologia} · {pp.status} · {pp.capacidade_utilizada_assinantes}/{pp.capacidade_max_assinantes} clientes
            </li>
          ))}
        </ul>
      )}
      <form onSubmit={handleAdd} className="form-grid">
        {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
        <Field label="POP *">
          <select value={popId} onChange={(e) => { setPopId(e.target.value); setFibraId(''); }}>
            <option value="">Selecione…</option>
            {pops.map((p) => <option key={p.pop_id} value={p.pop_id}>{p.codigo}</option>)}
          </select>
        </Field>
        <Field label="Fibra livre *">
          <select value={fibraId} onChange={(e) => setFibraId(e.target.value)} disabled={!popId}>
            <option value="">{popId ? 'Selecione…' : 'Selecione um POP primeiro'}</option>
            {availableFibers.map((f) => (
              <option key={f.fibra_id} value={f.fibra_id}>{f.cabo_identificacao} — FO{f.numero_fibra}</option>
            ))}
          </select>
        </Field>
        <Field label="Código da porta *"><input value={codigoPorta} onChange={(e) => setCodigoPorta(e.target.value)} placeholder="PON-XXX-001" /></Field>
        <Field label="Nome"><input value={nome} onChange={(e) => setNome(e.target.value)} /></Field>
        <Field label="Tecnologia">
          <select value={tecnologia} onChange={(e) => setTecnologia(e.target.value)}>
            <option value="GPON">GPON</option>
            <option value="XG-PON">XG-PON</option>
            <option value="XGS-PON">XGS-PON</option>
            <option value="OUTRA">Outra</option>
          </select>
        </Field>
      </form>
      <p style={{ fontSize: '0.8rem', color: 'var(--text-muted)', marginTop: 8 }}>
        Capacidade padrão: 128 clientes quando não informada (parametrizado em pricing_parametros).
      </p>
      <button type="button" className="btn btn-secondary" onClick={handleAdd} disabled={saving} style={{ marginTop: 8 }}>
        {saving ? 'Adicionando…' : 'Cadastrar Porta PON'}
      </button>
    </div>
  );
}

// --- Página --------------------------------------------------------------------

export default function EditCity() {
  const { id } = useParams();
  const [city, setCity] = useState(null);
  const [tree, setTree] = useState(null);
  const [error, setError] = useState(null);

  const reload = useCallback(async () => {
    try {
      const [cityDetail, treeData] = await Promise.all([api.cities.detail(id), api.infra.tree(id)]);
      setCity(cityDetail);
      setTree(treeData);
    } catch (err) {
      setError(err.message);
    }
  }, [id]);

  useEffect(() => { reload(); }, [reload]);

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;
  if (!city || !tree) return <div className="page"><div className="spinner" /></div>;

  return (
    <div className="page">
      <div className="page-header">
        <h1>Editar Infraestrutura — {city.nome}</h1>
        <p><Link to={`/cidades/${id}`} className="link-tab">← Voltar para o detalhe da cidade</Link></p>
      </div>

      <CityFieldsForm city={city} onSaved={reload} />
      <PopsSection cidadeId={id} pops={tree.pops} onChanged={reload} />
      <SegmentsSection cidadeId={id} segmentos={tree.segmentos} onChanged={reload} />
      <CablesSection pops={tree.pops} segmentos={tree.segmentos} onChanged={reload} />
      <PolesSection cidadeId={id} segmentos={tree.segmentos} postes={tree.postes} onChanged={reload} />
      <PonPortsSection pops={tree.pops} onChanged={reload} />
    </div>
  );
}
