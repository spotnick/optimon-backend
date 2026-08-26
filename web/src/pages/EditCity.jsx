import { useCallback, useEffect, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { api, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import ArchiveModal from '../components/ArchiveModal';

const FIBRA_STATUS = ['LIVRE', 'OCUPADA', 'RESERVADA', 'LOCADA', 'MANUTENCAO', 'BLOQUEADA'];
const OPERACIONAL_STATUS = ['ATIVO', 'MANUTENCAO'];
const CAN_ARCHIVE = ['ENGENHARIA', 'ADMINISTRADOR'];
const CAN_RESTORE = ['ADMINISTRADOR', 'DIRETOR'];
const FILTROS = [
  { value: 'ATIVOS', label: 'Ativos' },
  { value: 'ARQUIVADOS', label: 'Arquivados' },
  { value: 'TODOS', label: 'Todos' },
];

function Field({ label, children }) {
  return (
    <div className="field">
      <label>{label}</label>
      {children}
    </div>
  );
}

function FiltroChips({ filtro, setFiltro }) {
  return (
    <div className="chip-row" style={{ marginBottom: 12 }}>
      {FILTROS.map((f) => (
        <button key={f.value} type="button" className={`chip ${filtro === f.value ? 'active' : ''}`} onClick={() => setFiltro(f.value)}>
          {f.label}
        </button>
      ))}
    </div>
  );
}

function ArchivedBadge({ arquivado }) {
  return arquivado ? <span className="badge status-archived">Arquivado</span> : <span className="badge status-allow">Ativo</span>;
}

// --- Dados da cidade -------------------------------------------------------------

function CityFieldsForm({ city, role, onSaved }) {
  const [nome, setNome] = useState(city.nome);
  const [uf, setUf] = useState(city.uf);
  const [codigoIbge, setCodigoIbge] = useState(city.codigo_ibge || '');
  const [endereco, setEndereco] = useState(city.endereco || '');
  const [kmRede, setKmRede] = useState(city.km_rede);
  const [observacoes, setObservacoes] = useState(city.observacoes || '');
  const [status, setStatus] = useState(city.status);
  const [saving, setSaving] = useState(false);
  const [restoring, setRestoring] = useState(false);
  const [showArchive, setShowArchive] = useState(false);
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

  async function handleRestore() {
    setError(null);
    setRestoring(true);
    try {
      await api.cities.restore(city.cidade_id, {});
      onSaved();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao restaurar.');
    } finally {
      setRestoring(false);
    }
  }

  if (city.arquivada) {
    return (
      <div className="card" style={{ marginBottom: 28 }}>
        <h2 className="section-title">Dados da cidade</h2>
        {error && <div className="error-banner">{error}</div>}
        <div className="error-banner" style={{ background: 'var(--gray-100)', color: 'var(--text-muted)' }}>
          Esta cidade está arquivada — os dados abaixo são só para consulta (Visualizar). Restaure para voltar a editá-la.
        </div>
        <div className="form-grid" style={{ opacity: 0.7 }}>
          <Field label="Nome"><input value={nome} disabled /></Field>
          <Field label="UF"><input value={uf} disabled /></Field>
          <Field label="Código IBGE"><input value={codigoIbge} disabled /></Field>
          <Field label="KM de rede"><input value={kmRede} disabled /></Field>
          <Field label="Endereço/base"><input value={endereco} disabled /></Field>
          <div className="field" style={{ gridColumn: '1 / -1' }}>
            <label>Observações</label>
            <input value={observacoes} disabled />
          </div>
        </div>
        {CAN_RESTORE.includes(role) && (
          <div style={{ marginTop: 20 }}>
            <button type="button" className="btn btn-primary" onClick={handleRestore} disabled={restoring}>
              {restoring ? 'Restaurando…' : 'Restaurar cidade'}
            </button>
          </div>
        )}
      </div>
    );
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
        {CAN_ARCHIVE.includes(role) && (
          <button type="button" className="btn btn-danger" onClick={() => setShowArchive(true)}>
            Arquivar cidade
          </button>
        )}
      </div>
      {showArchive && (
        <ArchiveModal
          title="Arquivar cidade?"
          subject={`${city.nome} — ${city.uf}. Sai das listas ativas, do Dashboard e do Pricing Engine (histórico preservado). Bloqueado se houver contrato, proposta, parceiro ou PON em operação vinculados.`}
          mode="archive"
          onCancel={() => setShowArchive(false)}
          onConfirm={async (body) => {
            await api.cities.archive(city.cidade_id, body);
            setShowArchive(false);
            navigate('/cidades');
          }}
        />
      )}
    </form>
  );
}

// --- POPs --------------------------------------------------------------------------

function PopEditForm({ pop, onCancel, onSaved }) {
  const [form, setForm] = useState({
    codigo: pop.codigo, nome: pop.nome, tipo: pop.tipo, endereco: pop.endereco || '',
    latitude: pop.latitude ?? '', longitude: pop.longitude ?? '', capacidade_total: pop.capacidade_total ?? '',
    status: pop.status, observacoes: pop.observacoes || '',
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function handleSave() {
    setError(null);
    setSaving(true);
    try {
      await api.infra.updatePop(pop.pop_id, {
        ...form,
        latitude: form.latitude === '' ? null : Number(form.latitude),
        longitude: form.longitude === '' ? null : Number(form.longitude),
        capacidade_total: form.capacidade_total === '' ? null : Number(form.capacidade_total),
        endereco: form.endereco || null,
        observacoes: form.observacoes || null,
      });
      onSaved();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao salvar POP.');
      setSaving(false);
    }
  }

  return (
    <tr>
      <td colSpan={7}>
        <div className="form-grid" style={{ marginBottom: 12 }}>
          {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
          <Field label="Código"><input value={form.codigo} onChange={(e) => setForm({ ...form, codigo: e.target.value })} /></Field>
          <Field label="Nome"><input value={form.nome} onChange={(e) => setForm({ ...form, nome: e.target.value })} /></Field>
          <Field label="Tipo">
            <select value={form.tipo} onChange={(e) => setForm({ ...form, tipo: e.target.value })}>
              <option value="PRINCIPAL">Principal</option>
              <option value="DISTRIBUICAO">Distribuição</option>
              <option value="ACESSO">Acesso</option>
              <option value="OUTRO">Outro</option>
            </select>
          </Field>
          <Field label="Status">
            <select value={form.status} onChange={(e) => setForm({ ...form, status: e.target.value })}>
              <option value="ATIVO">Ativo</option>
              <option value="PLANEJADO">Planejado</option>
              <option value="DESATIVADO">Desativado</option>
            </select>
          </Field>
          <Field label="Endereço"><input value={form.endereco} onChange={(e) => setForm({ ...form, endereco: e.target.value })} /></Field>
          <Field label="Latitude"><input type="number" step="0.000001" value={form.latitude} onChange={(e) => setForm({ ...form, latitude: e.target.value })} /></Field>
          <Field label="Longitude"><input type="number" step="0.000001" value={form.longitude} onChange={(e) => setForm({ ...form, longitude: e.target.value })} /></Field>
          <Field label="Capacidade total"><input type="number" min="0" value={form.capacidade_total} onChange={(e) => setForm({ ...form, capacidade_total: e.target.value })} /></Field>
          <div className="field" style={{ gridColumn: '1 / -1' }}>
            <label>Observações</label>
            <input value={form.observacoes} onChange={(e) => setForm({ ...form, observacoes: e.target.value })} />
          </div>
        </div>
        <div className="row-actions">
          <button type="button" className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>{saving ? 'Salvando…' : 'Salvar'}</button>
          <button type="button" className="btn btn-secondary btn-sm" onClick={onCancel} disabled={saving}>Cancelar</button>
        </div>
      </td>
    </tr>
  );
}

function PopsSection({ cidadeId, pops, role, onChanged }) {
  const [codigo, setCodigo] = useState('');
  const [nome, setNome] = useState('');
  const [tipo, setTipo] = useState('ACESSO');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [filtro, setFiltro] = useState('ATIVOS');
  const [editingId, setEditingId] = useState(null);
  const [archiveTarget, setArchiveTarget] = useState(null);
  const [actionError, setActionError] = useState(null);

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

  async function handleRestore(pop) {
    setActionError(null);
    try {
      await api.infra.restorePop(pop.pop_id, {});
      onChanged();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro ao restaurar POP.');
    }
  }

  const visible = pops.filter((p) => (filtro === 'ATIVOS' ? !p.arquivado : filtro === 'ARQUIVADOS' ? p.arquivado : true));

  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <h3 className="section-title">POPs</h3>
      <FiltroChips filtro={filtro} setFiltro={setFiltro} />
      {actionError && <div className="error-banner">{actionError}</div>}
      {visible.length === 0 && <p style={{ color: 'var(--text-muted)', marginBottom: 12 }}>Nenhum POP para esse filtro.</p>}
      {visible.length > 0 && (
        <div className="table-scroll" style={{ marginBottom: 16 }}>
          <table>
            <thead>
              <tr><th>Código</th><th>Nome</th><th>Tipo</th><th>Cabos/Portas</th><th>Estado</th><th></th></tr>
            </thead>
            <tbody>
              {visible.map((p) => (
                editingId === p.pop_id ? (
                  <PopEditForm key={p.pop_id} pop={p} onCancel={() => setEditingId(null)} onSaved={() => { setEditingId(null); onChanged(); }} />
                ) : (
                  <tr key={p.pop_id}>
                    <td style={{ fontFamily: 'var(--font-mono)' }}>{p.codigo}</td>
                    <td>{p.nome}</td>
                    <td>{p.tipo}</td>
                    <td>{p.cabos.length} cabo(s) · {p.portas_pon.length} porta(s)</td>
                    <td><ArchivedBadge arquivado={p.arquivado} /></td>
                    <td>
                      <div className="row-actions">
                        {!p.arquivado && CAN_ARCHIVE.includes(role) && (
                          <button type="button" className="btn btn-secondary btn-sm" onClick={() => setEditingId(p.pop_id)}>Editar</button>
                        )}
                        {!p.arquivado && CAN_ARCHIVE.includes(role) && (
                          <button type="button" className="btn btn-danger btn-sm" onClick={() => setArchiveTarget(p)}>Arquivar</button>
                        )}
                        {p.arquivado && CAN_RESTORE.includes(role) && (
                          <button type="button" className="btn btn-secondary btn-sm" onClick={() => handleRestore(p)}>Restaurar</button>
                        )}
                      </div>
                    </td>
                  </tr>
                )
              ))}
            </tbody>
          </table>
        </div>
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

      {archiveTarget && (
        <ArchiveModal
          title="Arquivar POP?"
          subject={`${archiveTarget.codigo} — ${archiveTarget.nome}. Bloqueado se houver cabo ou Porta PON ativos vinculados a este POP.`}
          mode="archive"
          onCancel={() => setArchiveTarget(null)}
          onConfirm={async (body) => {
            await api.infra.archivePop(archiveTarget.pop_id, body);
            setArchiveTarget(null);
            onChanged();
          }}
        />
      )}
    </div>
  );
}

// --- Segmentos -----------------------------------------------------------------

function SegmentEditForm({ segmento, onCancel, onSaved }) {
  const [form, setForm] = useState({
    nome: segmento.nome, origem: segmento.origem, destino: segmento.destino,
    extensao_km: segmento.extensao_km, status: segmento.status, observacoes: segmento.observacoes || '',
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function handleSave() {
    setError(null);
    setSaving(true);
    try {
      await api.infra.updateSegment(segmento.segmento_id, { ...form, extensao_km: Number(form.extensao_km), observacoes: form.observacoes || null });
      onSaved();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao salvar segmento.');
      setSaving(false);
    }
  }

  return (
    <tr>
      <td colSpan={5}>
        <div className="form-grid" style={{ marginBottom: 12 }}>
          {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
          <Field label="Nome"><input value={form.nome} onChange={(e) => setForm({ ...form, nome: e.target.value })} /></Field>
          <Field label="Origem"><input value={form.origem} onChange={(e) => setForm({ ...form, origem: e.target.value })} /></Field>
          <Field label="Destino"><input value={form.destino} onChange={(e) => setForm({ ...form, destino: e.target.value })} /></Field>
          <Field label="Extensão (km)"><input type="number" min="0" step="0.001" value={form.extensao_km} onChange={(e) => setForm({ ...form, extensao_km: e.target.value })} /></Field>
          <Field label="Status">
            <select value={form.status} onChange={(e) => setForm({ ...form, status: e.target.value })}>
              {OPERACIONAL_STATUS.map((s) => <option key={s} value={s}>{s}</option>)}
            </select>
          </Field>
          <div className="field" style={{ gridColumn: '1 / -1' }}>
            <label>Observações</label>
            <input value={form.observacoes} onChange={(e) => setForm({ ...form, observacoes: e.target.value })} />
          </div>
        </div>
        <div className="row-actions">
          <button type="button" className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>{saving ? 'Salvando…' : 'Salvar'}</button>
          <button type="button" className="btn btn-secondary btn-sm" onClick={onCancel} disabled={saving}>Cancelar</button>
        </div>
      </td>
    </tr>
  );
}

function SegmentsSection({ cidadeId, segmentos, role, onChanged }) {
  const [nome, setNome] = useState('');
  const [origem, setOrigem] = useState('');
  const [destino, setDestino] = useState('');
  const [extensao, setExtensao] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [filtro, setFiltro] = useState('ATIVOS');
  const [editingId, setEditingId] = useState(null);
  const [archiveTarget, setArchiveTarget] = useState(null);
  const [actionError, setActionError] = useState(null);

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

  async function handleRestore(segmento) {
    setActionError(null);
    try {
      await api.infra.restoreSegment(segmento.segmento_id, {});
      onChanged();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro ao restaurar segmento.');
    }
  }

  const visible = segmentos.filter((s) => (filtro === 'ATIVOS' ? !s.arquivado : filtro === 'ARQUIVADOS' ? s.arquivado : true));

  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <h3 className="section-title">Segmentos</h3>
      <FiltroChips filtro={filtro} setFiltro={setFiltro} />
      {actionError && <div className="error-banner">{actionError}</div>}
      {visible.length === 0 && <p style={{ color: 'var(--text-muted)', marginBottom: 12 }}>Nenhum segmento para esse filtro.</p>}
      {visible.length > 0 && (
        <div className="table-scroll" style={{ marginBottom: 16 }}>
          <table>
            <thead>
              <tr><th>Nome</th><th>Origem → Destino</th><th className="num">Extensão</th><th>Estado</th><th></th></tr>
            </thead>
            <tbody>
              {visible.map((s) => (
                editingId === s.segmento_id ? (
                  <SegmentEditForm key={s.segmento_id} segmento={s} onCancel={() => setEditingId(null)} onSaved={() => { setEditingId(null); onChanged(); }} />
                ) : (
                  <tr key={s.segmento_id}>
                    <td>{s.nome}</td>
                    <td>{s.origem} → {s.destino}</td>
                    <td className="num">{Number(s.extensao_km).toLocaleString('pt-BR')} km</td>
                    <td><ArchivedBadge arquivado={s.arquivado} /></td>
                    <td>
                      <div className="row-actions">
                        {!s.arquivado && CAN_ARCHIVE.includes(role) && (
                          <button type="button" className="btn btn-secondary btn-sm" onClick={() => setEditingId(s.segmento_id)}>Editar</button>
                        )}
                        {!s.arquivado && CAN_ARCHIVE.includes(role) && (
                          <button type="button" className="btn btn-danger btn-sm" onClick={() => setArchiveTarget(s)}>Arquivar</button>
                        )}
                        {s.arquivado && CAN_RESTORE.includes(role) && (
                          <button type="button" className="btn btn-secondary btn-sm" onClick={() => handleRestore(s)}>Restaurar</button>
                        )}
                      </div>
                    </td>
                  </tr>
                )
              ))}
            </tbody>
          </table>
        </div>
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

      {archiveTarget && (
        <ArchiveModal
          title="Arquivar segmento?"
          subject={`${archiveTarget.nome} (${archiveTarget.origem} → ${archiveTarget.destino}). Bloqueado se houver cabo ou lote de postes ativos vinculados a este segmento.`}
          mode="archive"
          onCancel={() => setArchiveTarget(null)}
          onConfirm={async (body) => {
            await api.infra.archiveSegment(archiveTarget.segmento_id, body);
            setArchiveTarget(null);
            onChanged();
          }}
        />
      )}
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

function CableEditForm({ cabo, pops, segmentos, onCancel, onSaved }) {
  const [form, setForm] = useState({
    identificacao: cabo.identificacao, capacidade_fo: cabo.capacidade_fo, fabricante: cabo.fabricante || '',
    segmento_id: cabo.segmento_id, pop_id: cabo.pop_id || '', status: cabo.status, observacoes: cabo.observacoes || '',
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function handleSave() {
    setError(null);
    setSaving(true);
    try {
      await api.infra.updateCable(cabo.cabo_id, {
        ...form, capacidade_fo: Number(form.capacidade_fo), pop_id: form.pop_id || null,
        fabricante: form.fabricante || null, observacoes: form.observacoes || null,
      });
      onSaved();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao salvar cabo.');
      setSaving(false);
    }
  }

  return (
    <div className="form-grid" style={{ marginBottom: 12, padding: '12px 0' }}>
      {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
      <Field label="Identificação"><input value={form.identificacao} onChange={(e) => setForm({ ...form, identificacao: e.target.value })} /></Field>
      <Field label="Capacidade FO">
        <input type="number" min="1" value={form.capacidade_fo} onChange={(e) => setForm({ ...form, capacidade_fo: e.target.value })} />
      </Field>
      <Field label="Fabricante"><input value={form.fabricante} onChange={(e) => setForm({ ...form, fabricante: e.target.value })} /></Field>
      <Field label="Segmento">
        {/* seção 40 (E2E "apenas infraestrutura ativa disponível"): nunca oferecer um
            segmento arquivado como opção NOVA de vínculo — mas sem esconder o vínculo já
            existente deste cabo (form.segmento_id), mesmo que o segmento tenha sido
            arquivado depois que este cabo foi criado/editado pela última vez. */}
        <select value={form.segmento_id} onChange={(e) => setForm({ ...form, segmento_id: e.target.value })}>
          {segmentos.filter((s) => !s.arquivado || s.segmento_id === form.segmento_id).map((s) => <option key={s.segmento_id} value={s.segmento_id}>{s.nome}{s.arquivado ? ' (arquivado)' : ''}</option>)}
        </select>
      </Field>
      <Field label="POP">
        <select value={form.pop_id} onChange={(e) => setForm({ ...form, pop_id: e.target.value })}>
          <option value="">(sem POP)</option>
          {pops.filter((p) => !p.arquivado || p.pop_id === form.pop_id).map((p) => <option key={p.pop_id} value={p.pop_id}>{p.codigo}{p.arquivado ? ' (arquivado)' : ''}</option>)}
        </select>
      </Field>
      <Field label="Status">
        <select value={form.status} onChange={(e) => setForm({ ...form, status: e.target.value })}>
          {OPERACIONAL_STATUS.map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
      </Field>
      <div className="field" style={{ gridColumn: '1 / -1' }}>
        <label>Observações</label>
        <input value={form.observacoes} onChange={(e) => setForm({ ...form, observacoes: e.target.value })} />
      </div>
      <p style={{ gridColumn: '1 / -1', fontSize: '0.78rem', color: 'var(--text-muted)', margin: 0 }}>
        Mudar a Capacidade FO aqui só corrige o rótulo do cabo — não cria nem remove fibras já geradas.
      </p>
      <div className="row-actions" style={{ gridColumn: '1 / -1' }}>
        <button type="button" className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>{saving ? 'Salvando…' : 'Salvar'}</button>
        <button type="button" className="btn btn-secondary btn-sm" onClick={onCancel} disabled={saving}>Cancelar</button>
      </div>
    </div>
  );
}

function CablesSection({ pops, segmentos, role, onChanged }) {
  const [popId, setPopId] = useState('');
  const [segmentoId, setSegmentoId] = useState('');
  const [identificacao, setIdentificacao] = useState('');
  const [capacidadeFo, setCapacidadeFo] = useState('12');
  const [fabricante, setFabricante] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [expanded, setExpanded] = useState(null);
  const [filtro, setFiltro] = useState('ATIVOS');
  const [editingId, setEditingId] = useState(null);
  const [archiveTarget, setArchiveTarget] = useState(null);
  const [actionError, setActionError] = useState(null);

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

  async function handleRestore(cabo) {
    setActionError(null);
    try {
      await api.infra.restoreCable(cabo.cabo_id, {});
      onChanged();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro ao restaurar cabo.');
    }
  }

  const allCables = pops.flatMap((p) => p.cabos.map((c) => ({ ...c, pop_codigo: p.codigo })));
  const visible = allCables.filter((c) => (filtro === 'ATIVOS' ? !c.arquivado : filtro === 'ARQUIVADOS' ? c.arquivado : true));

  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <h3 className="section-title">Cabos</h3>
      <FiltroChips filtro={filtro} setFiltro={setFiltro} />
      {actionError && <div className="error-banner">{actionError}</div>}
      {visible.length === 0 && <p style={{ color: 'var(--text-muted)', marginBottom: 12 }}>Nenhum cabo para esse filtro.</p>}
      {visible.length > 0 && (
        <div style={{ marginBottom: 16 }}>
          {visible.map((c) => (
            <div key={c.cabo_id} style={{ marginBottom: 8, borderBottom: '1px solid var(--border)', paddingBottom: 8 }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
                <button
                  type="button"
                  className="link-tab"
                  style={{ fontSize: '0.88rem' }}
                  onClick={() => setExpanded(expanded === c.cabo_id ? null : c.cabo_id)}
                >
                  {expanded === c.cabo_id ? '▾' : '▸'} {c.identificacao} — {c.capacidade_fo} FO ({c.pop_codigo || 'sem POP'})
                </button>
                <div className="row-actions">
                  <ArchivedBadge arquivado={c.arquivado} />
                  {!c.arquivado && CAN_ARCHIVE.includes(role) && (
                    <button type="button" className="btn btn-secondary btn-sm" onClick={() => setEditingId(editingId === c.cabo_id ? null : c.cabo_id)}>
                      {editingId === c.cabo_id ? 'Fechar edição' : 'Editar'}
                    </button>
                  )}
                  {!c.arquivado && CAN_ARCHIVE.includes(role) && (
                    <button type="button" className="btn btn-danger btn-sm" onClick={() => setArchiveTarget(c)}>Arquivar</button>
                  )}
                  {c.arquivado && CAN_RESTORE.includes(role) && (
                    <button type="button" className="btn btn-secondary btn-sm" onClick={() => handleRestore(c)}>Restaurar</button>
                  )}
                </div>
              </div>
              {editingId === c.cabo_id && (
                <CableEditForm cabo={c} pops={pops} segmentos={segmentos} onCancel={() => setEditingId(null)} onSaved={() => { setEditingId(null); onChanged(); }} />
              )}
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
          {/* seção 40 (E2E "apenas infraestrutura ativa disponível"): um cabo NOVO nunca
              pode ser vinculado a um segmento arquivado — diferente do form de edição
              acima, aqui não há vínculo prévio a preservar. */}
          <select value={segmentoId} onChange={(e) => setSegmentoId(e.target.value)}>
            <option value="">Selecione…</option>
            {segmentos.filter((s) => !s.arquivado).map((s) => <option key={s.segmento_id} value={s.segmento_id}>{s.nome}</option>)}
          </select>
        </Field>
        <Field label="POP">
          <select value={popId} onChange={(e) => setPopId(e.target.value)}>
            <option value="">(sem POP)</option>
            {pops.filter((p) => !p.arquivado).map((p) => <option key={p.pop_id} value={p.pop_id}>{p.codigo}</option>)}
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

      {archiveTarget && (
        <ArchiveModal
          title="Arquivar cabo?"
          subject={`${archiveTarget.identificacao}. Bloqueado se houver fibra OCUPADA/LOCADA, associada a Porta PON, ou vinculada a contrato ativo — as fibras nunca são excluídas, permanecem no histórico do cabo.`}
          mode="archive"
          onCancel={() => setArchiveTarget(null)}
          onConfirm={async (body) => {
            await api.infra.archiveCable(archiveTarget.cabo_id, body);
            setArchiveTarget(null);
            onChanged();
          }}
        />
      )}
    </div>
  );
}

// --- Postes ------------------------------------------------------------------------

function PoleEditForm({ poste, segmentos, onCancel, onSaved }) {
  const [form, setForm] = useState({
    identificacao: poste.identificacao || '', segmento_id: poste.segmento_id || '',
    proprietario_terceiro: poste.proprietario_terceiro || '', quantidade: poste.quantidade,
    custo_mensal: poste.custo_mensal, status: poste.status, observacoes: poste.observacoes || '',
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function handleSave() {
    setError(null);
    setSaving(true);
    try {
      await api.infra.updatePole(poste.poste_id, {
        ...form, segmento_id: form.segmento_id || null, proprietario_terceiro: form.proprietario_terceiro || null,
        quantidade: Number(form.quantidade), custo_mensal: Number(form.custo_mensal), observacoes: form.observacoes || null,
      });
      onSaved();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao salvar poste.');
      setSaving(false);
    }
  }

  return (
    <tr>
      <td colSpan={6}>
        <div className="form-grid" style={{ marginBottom: 12 }}>
          {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
          <Field label="Identificação"><input value={form.identificacao} onChange={(e) => setForm({ ...form, identificacao: e.target.value })} /></Field>
          <Field label="Segmento">
            {/* mesmo critério da seção 40 aplicado a PoleEditForm: preserva o vínculo já
                existente (form.segmento_id) mesmo se arquivado, mas não oferece outro
                segmento arquivado como opção nova. */}
            <select value={form.segmento_id} onChange={(e) => setForm({ ...form, segmento_id: e.target.value })}>
              <option value="">(sem segmento)</option>
              {segmentos.filter((s) => !s.arquivado || s.segmento_id === form.segmento_id).map((s) => <option key={s.segmento_id} value={s.segmento_id}>{s.nome}{s.arquivado ? ' (arquivado)' : ''}</option>)}
            </select>
          </Field>
          <Field label="Proprietário terceiro"><input value={form.proprietario_terceiro} onChange={(e) => setForm({ ...form, proprietario_terceiro: e.target.value })} /></Field>
          <Field label="Quantidade"><input type="number" min="1" value={form.quantidade} onChange={(e) => setForm({ ...form, quantidade: e.target.value })} /></Field>
          <Field label="Custo mensal (R$)"><input type="number" min="0" step="0.01" value={form.custo_mensal} onChange={(e) => setForm({ ...form, custo_mensal: e.target.value })} /></Field>
          <Field label="Status">
            <select value={form.status} onChange={(e) => setForm({ ...form, status: e.target.value })}>
              {OPERACIONAL_STATUS.map((s) => <option key={s} value={s}>{s}</option>)}
            </select>
          </Field>
          <div className="field" style={{ gridColumn: '1 / -1' }}>
            <label>Observações</label>
            <input value={form.observacoes} onChange={(e) => setForm({ ...form, observacoes: e.target.value })} />
          </div>
        </div>
        <div className="row-actions">
          <button type="button" className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>{saving ? 'Salvando…' : 'Salvar'}</button>
          <button type="button" className="btn btn-secondary btn-sm" onClick={onCancel} disabled={saving}>Cancelar</button>
        </div>
      </td>
    </tr>
  );
}

function PolesSection({ cidadeId, segmentos, postes, role, onChanged }) {
  const [segmentoId, setSegmentoId] = useState('');
  const [identificacao, setIdentificacao] = useState('');
  const [proprietario, setProprietario] = useState('');
  const [quantidade, setQuantidade] = useState('1');
  const [custoMensal, setCustoMensal] = useState('0');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [filtro, setFiltro] = useState('ATIVOS');
  const [editingId, setEditingId] = useState(null);
  const [archiveTarget, setArchiveTarget] = useState(null);
  const [actionError, setActionError] = useState(null);

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

  async function handleRestore(poste) {
    setActionError(null);
    try {
      await api.infra.restorePole(poste.poste_id, {});
      onChanged();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro ao restaurar poste.');
    }
  }

  const visible = postes.filter((p) => (filtro === 'ATIVOS' ? !p.arquivado : filtro === 'ARQUIVADOS' ? p.arquivado : true));

  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <h3 className="section-title">Postes</h3>
      <FiltroChips filtro={filtro} setFiltro={setFiltro} />
      {actionError && <div className="error-banner">{actionError}</div>}
      {visible.length === 0 && <p style={{ color: 'var(--text-muted)', marginBottom: 12 }}>Nenhum lote de postes para esse filtro.</p>}
      {visible.length > 0 && (
        <div className="table-scroll" style={{ marginBottom: 16 }}>
          <table>
            <thead><tr><th>Identificação</th><th className="num">Qtd.</th><th className="num">Custo/mês</th><th>Estado</th><th></th></tr></thead>
            <tbody>
              {visible.map((p) => (
                editingId === p.poste_id ? (
                  <PoleEditForm key={p.poste_id} poste={p} segmentos={segmentos} onCancel={() => setEditingId(null)} onSaved={() => { setEditingId(null); onChanged(); }} />
                ) : (
                  <tr key={p.poste_id}>
                    <td>{p.identificacao || 'Lote'}{p.proprietario_terceiro ? ` (${p.proprietario_terceiro})` : ''}</td>
                    <td className="num">{p.quantidade}</td>
                    <td className="num">R$ {Number(p.custo_mensal).toLocaleString('pt-BR')}</td>
                    <td><ArchivedBadge arquivado={p.arquivado} /></td>
                    <td>
                      <div className="row-actions">
                        {!p.arquivado && CAN_ARCHIVE.includes(role) && (
                          <button type="button" className="btn btn-secondary btn-sm" onClick={() => setEditingId(p.poste_id)}>Editar</button>
                        )}
                        {!p.arquivado && CAN_ARCHIVE.includes(role) && (
                          <button type="button" className="btn btn-danger btn-sm" onClick={() => setArchiveTarget(p)}>Arquivar</button>
                        )}
                        {p.arquivado && CAN_RESTORE.includes(role) && (
                          <button type="button" className="btn btn-secondary btn-sm" onClick={() => handleRestore(p)}>Restaurar</button>
                        )}
                      </div>
                    </td>
                  </tr>
                )
              ))}
            </tbody>
          </table>
        </div>
      )}
      <form onSubmit={handleAdd} className="form-grid">
        {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
        <Field label="Identificação"><input value={identificacao} onChange={(e) => setIdentificacao(e.target.value)} placeholder="Lote de postes" /></Field>
        <Field label="Segmento">
          {/* seção 40 (E2E "apenas infraestrutura ativa disponível"): lote de postes NOVO
              nunca pode ser vinculado a um segmento arquivado. */}
          <select value={segmentoId} onChange={(e) => setSegmentoId(e.target.value)}>
            <option value="">(sem segmento)</option>
            {segmentos.filter((s) => !s.arquivado).map((s) => <option key={s.segmento_id} value={s.segmento_id}>{s.nome}</option>)}
          </select>
        </Field>
        <Field label="Proprietário terceiro"><input value={proprietario} onChange={(e) => setProprietario(e.target.value)} placeholder="Concessionária de energia" /></Field>
        <Field label="Quantidade *"><input type="number" min="1" value={quantidade} onChange={(e) => setQuantidade(e.target.value)} /></Field>
        <Field label="Custo mensal (R$)"><input type="number" min="0" step="0.01" value={custoMensal} onChange={(e) => setCustoMensal(e.target.value)} /></Field>
      </form>
      <button type="button" className="btn btn-secondary" onClick={handleAdd} disabled={saving} style={{ marginTop: 12 }}>
        {saving ? 'Adicionando…' : 'Cadastrar lote de postes'}
      </button>

      {archiveTarget && (
        <ArchiveModal
          title="Arquivar lote de postes?"
          subject={`${archiveTarget.identificacao || 'Lote de postes'} — ${archiveTarget.quantidade} poste(s). Postes não têm dependência estrutural com outra infraestrutura, então o arquivamento nunca é bloqueado.`}
          mode="archive"
          onCancel={() => setArchiveTarget(null)}
          onConfirm={async (body) => {
            await api.infra.archivePole(archiveTarget.poste_id, body);
            setArchiveTarget(null);
            onChanged();
          }}
        />
      )}
    </div>
  );
}

// --- Portas PON --------------------------------------------------------------------

function PonPortEditForm({ porta, onCancel, onSaved }) {
  const [form, setForm] = useState({
    codigo_porta: porta.codigo_porta, nome: porta.nome || '', tecnologia: porta.tecnologia,
    capacidade_max_assinantes: porta.capacidade_max_assinantes ?? '',
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function handleSave() {
    setError(null);
    setSaving(true);
    try {
      await api.infra.updatePonPort(porta.porta_id, {
        ...form, nome: form.nome || null,
        capacidade_max_assinantes: form.capacidade_max_assinantes === '' ? null : Number(form.capacidade_max_assinantes),
      });
      onSaved();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao salvar Porta PON.');
      setSaving(false);
    }
  }

  return (
    <li style={{ marginBottom: 8, listStyle: 'none' }}>
      <div className="form-grid" style={{ marginBottom: 8 }}>
        {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
        <Field label="Código da porta"><input value={form.codigo_porta} onChange={(e) => setForm({ ...form, codigo_porta: e.target.value })} /></Field>
        <Field label="Nome"><input value={form.nome} onChange={(e) => setForm({ ...form, nome: e.target.value })} /></Field>
        <Field label="Tecnologia">
          <select value={form.tecnologia} onChange={(e) => setForm({ ...form, tecnologia: e.target.value })}>
            <option value="GPON">GPON</option>
            <option value="XG-PON">XG-PON</option>
            <option value="XGS-PON">XGS-PON</option>
            <option value="OUTRA">Outra</option>
          </select>
        </Field>
        <Field label="Capacidade máxima"><input type="number" min="1" value={form.capacidade_max_assinantes} onChange={(e) => setForm({ ...form, capacidade_max_assinantes: e.target.value })} /></Field>
      </div>
      <p style={{ fontSize: '0.78rem', color: 'var(--text-muted)', margin: '0 0 8px' }}>
        POP e fibra não são editáveis aqui — para reposicionar a porta, arquive-a e cadastre uma nova na fibra correta.
      </p>
      <div className="row-actions">
        <button type="button" className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>{saving ? 'Salvando…' : 'Salvar'}</button>
        <button type="button" className="btn btn-secondary btn-sm" onClick={onCancel} disabled={saving}>Cancelar</button>
      </div>
    </li>
  );
}

function PonPortsSection({ pops, role, onChanged }) {
  const [popId, setPopId] = useState('');
  const [fibraId, setFibraId] = useState('');
  const [codigoPorta, setCodigoPorta] = useState('');
  const [nome, setNome] = useState('');
  const [tecnologia, setTecnologia] = useState('GPON');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [filtro, setFiltro] = useState('ATIVOS');
  const [editingId, setEditingId] = useState(null);
  const [archiveTarget, setArchiveTarget] = useState(null);
  const [actionError, setActionError] = useState(null);

  const selectedPop = pops.find((p) => p.pop_id === popId);
  // Só fibras LIVRE do cabo do POP podem virar porta PON nova (unique(fibra_id) na tabela).
  // !c.arquivado (seção 40 — "apenas infraestrutura ativa disponível"): uma fibra de um
  // cabo já arquivado nunca deveria virar Porta PON nova, mesmo que a fibra em si ainda
  // esteja marcada LIVRE (a fibra em si nunca é arquivada isoladamente — seção 14).
  const availableFibers = selectedPop
    ? selectedPop.cabos.filter((c) => !c.arquivado).flatMap((c) => c.fibras.filter((f) => f.status === 'LIVRE').map((f) => ({ ...f, cabo_identificacao: c.identificacao })))
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

  async function handleRestore(porta) {
    setActionError(null);
    try {
      await api.infra.restorePonPort(porta.porta_id, {});
      onChanged();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro ao restaurar Porta PON.');
    }
  }

  // Sem coluna removido_em própria — "arquivado" aqui é status === INATIVA (migration 2).
  const allPorts = pops.flatMap((p) => p.portas_pon.map((pp) => ({ ...pp, pop_codigo: p.codigo, arquivado: pp.status === 'INATIVA' })));
  const visible = allPorts.filter((pp) => (filtro === 'ATIVOS' ? !pp.arquivado : filtro === 'ARQUIVADOS' ? pp.arquivado : true));

  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <h3 className="section-title">Portas PON</h3>
      <FiltroChips filtro={filtro} setFiltro={setFiltro} />
      {actionError && <div className="error-banner">{actionError}</div>}
      {visible.length === 0 && <p style={{ color: 'var(--text-muted)', marginBottom: 12 }}>Nenhuma porta PON para esse filtro.</p>}
      {visible.length > 0 && (
        <ul style={{ marginBottom: 16, paddingLeft: 0 }}>
          {visible.map((pp) => (
            editingId === pp.porta_id ? (
              <PonPortEditForm key={pp.porta_id} porta={pp} onCancel={() => setEditingId(null)} onSaved={() => { setEditingId(null); onChanged(); }} />
            ) : (
              <li key={pp.porta_id} style={{ marginBottom: 6, listStyle: 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8, borderBottom: '1px solid var(--border)', paddingBottom: 6 }}>
                <span>
                  <strong style={{ fontFamily: 'var(--font-mono)' }}>{pp.codigo_porta}</strong> — {pp.pop_codigo} · {pp.cabo_identificacao} FO{pp.numero_fibra} · {pp.tecnologia} · {pp.status} · {pp.capacidade_utilizada_assinantes}/{pp.capacidade_max_assinantes} clientes
                </span>
                <div className="row-actions">
                  {!pp.arquivado && CAN_ARCHIVE.includes(role) && (
                    <button type="button" className="btn btn-secondary btn-sm" onClick={() => setEditingId(pp.porta_id)}>Editar</button>
                  )}
                  {!pp.arquivado && CAN_ARCHIVE.includes(role) && (
                    <button type="button" className="btn btn-danger btn-sm" onClick={() => setArchiveTarget(pp)}>Arquivar</button>
                  )}
                  {pp.arquivado && CAN_RESTORE.includes(role) && (
                    <button type="button" className="btn btn-secondary btn-sm" onClick={() => handleRestore(pp)}>Restaurar</button>
                  )}
                </div>
              </li>
            )
          ))}
        </ul>
      )}
      <form onSubmit={handleAdd} className="form-grid">
        {error && <div className="error-banner" style={{ gridColumn: '1 / -1' }}>{error}</div>}
        <Field label="POP *">
          {/* seção 40 (E2E "apenas infraestrutura ativa disponível"): Porta PON NOVA nunca
              pode ser criada num POP arquivado. */}
          <select value={popId} onChange={(e) => { setPopId(e.target.value); setFibraId(''); }}>
            <option value="">Selecione…</option>
            {pops.filter((p) => !p.arquivado).map((p) => <option key={p.pop_id} value={p.pop_id}>{p.codigo}</option>)}
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

      {archiveTarget && (
        <ArchiveModal
          title="Arquivar Porta PON?"
          subject={`${archiveTarget.codigo_porta} — ${archiveTarget.pop_codigo}. Bloqueado se houver cliente ativo nesta porta (${archiveTarget.capacidade_utilizada_assinantes} hoje).`}
          mode="archive"
          onCancel={() => setArchiveTarget(null)}
          onConfirm={async (body) => {
            await api.infra.archivePonPort(archiveTarget.porta_id, body);
            setArchiveTarget(null);
            onChanged();
          }}
        />
      )}
    </div>
  );
}

// --- Página --------------------------------------------------------------------

export default function EditCity() {
  const { id } = useParams();
  const { role } = useAuth();
  const [city, setCity] = useState(null);
  const [tree, setTree] = useState(null);
  const [error, setError] = useState(null);

  const reload = useCallback(async () => {
    try {
      const [cityDetail, treeData] = await Promise.all([api.cities.detail(id), api.infra.tree(id, true)]);
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

      <CityFieldsForm city={city} role={role} onSaved={reload} />
      <PopsSection cidadeId={id} pops={tree.pops} role={role} onChanged={reload} />
      <SegmentsSection cidadeId={id} segmentos={tree.segmentos} role={role} onChanged={reload} />
      <CablesSection pops={tree.pops} segmentos={tree.segmentos} role={role} onChanged={reload} />
      <PolesSection cidadeId={id} segmentos={tree.segmentos} postes={tree.postes} role={role} onChanged={reload} />
      <PonPortsSection pops={tree.pops} role={role} onChanged={reload} />
    </div>
  );
}
