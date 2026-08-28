import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, ApiError } from '../lib/api';

const STATUS_CLASS = {
  CRIADO: 'status-discount', ENVIADO: 'status-director', AGUARDANDO: 'status-director',
  PARCIALMENTE_ASSINADO: 'status-director', ASSINADO: 'status-allow', VALIDADO: 'status-allow',
  RECUSADO: 'status-block', CANCELADO: 'status-block', EXPIRADO: 'status-block', ERRO: 'status-block',
};

function emptyForm() {
  return { tipo_documento: 'PROPOSTA', provider_id: '', proposta_id: '', contrato_id: '', aditivo_id: '' };
}

export default function Signatures() {
  const [envelopes, setEnvelopes] = useState(null);
  const [providers, setProviders] = useState([]);
  const [error, setError] = useState(null);
  const [statusFiltro, setStatusFiltro] = useState('');
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState(emptyForm());
  const [file, setFile] = useState(null);
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState(null);

  function load() {
    setEnvelopes(null);
    api.signatures.envelopes(statusFiltro ? { status: statusFiltro } : {}).then(setEnvelopes).catch((err) => setError(err.message));
  }
  useEffect(load, [statusFiltro]);
  useEffect(() => { api.signatures.providers().then(setProviders).catch(() => {}); }, []);

  async function handleCreate(e) {
    e.preventDefault();
    setFormError(null);
    setSaving(true);
    try {
      const fd = new FormData();
      fd.append('tipo_documento', form.tipo_documento);
      fd.append('provider_id', form.provider_id);
      if (form.tipo_documento === 'PROPOSTA' && form.proposta_id) fd.append('proposta_id', form.proposta_id);
      if (form.tipo_documento === 'CONTRATO' && form.contrato_id) fd.append('contrato_id', form.contrato_id);
      if (form.tipo_documento === 'ADITIVO' && form.aditivo_id) fd.append('aditivo_id', form.aditivo_id);
      if (file) fd.append('arquivo', file);
      await api.signatures.createEnvelope(fd);
      setForm(emptyForm());
      setFile(null);
      setShowForm(false);
      load();
    } catch (err) {
      setFormError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setSaving(false);
    }
  }

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;

  return (
    <div className="page">
      <div className="page-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h1>Assinaturas</h1>
          <p>Envelopes de assinatura eletrônica (propostas/contratos/aditivos) — o OptiMon orquestra, nunca substitui, o provedor de assinatura. Hoje só o provedor de homologação (mock) está implementado — ver <Link className="link-tab" to="/configuracoes/assinatura">Configuração de Assinatura</Link> para o status ICP-Brasil completo.</p>
        </div>
        <div style={{ display: 'flex', gap: 12, alignItems: 'flex-end' }}>
          <div className="field" style={{ minWidth: 220 }}>
            <label>Filtrar por status</label>
            <select value={statusFiltro} onChange={(e) => setStatusFiltro(e.target.value)}>
              <option value="">Todos</option>
              {Object.keys(STATUS_CLASS).map((s) => <option key={s} value={s}>{s}</option>)}
            </select>
          </div>
          <button className="btn btn-primary" onClick={() => setShowForm((s) => !s)}>{showForm ? 'Cancelar' : '+ Novo Envelope'}</button>
        </div>
      </div>

      {showForm && (
        <div className="card" style={{ marginBottom: 16 }}>
          {formError && <div className="error-banner">{formError}</div>}
          <form onSubmit={handleCreate} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
            <div className="field">
              <label>Tipo de documento *</label>
              <select value={form.tipo_documento} onChange={(e) => setForm({ ...form, tipo_documento: e.target.value })}>
                <option value="PROPOSTA">PROPOSTA (PDF gerado automaticamente)</option>
                <option value="CONTRATO">CONTRATO (requer upload de PDF)</option>
                <option value="ADITIVO">ADITIVO (requer upload de PDF)</option>
              </select>
            </div>
            <div className="field">
              <label>Provedor *</label>
              <select required value={form.provider_id} onChange={(e) => setForm({ ...form, provider_id: e.target.value })}>
                <option value="">Selecione…</option>
                {providers.map((p) => <option key={p.id} value={p.id}>{p.nome} ({p.ambiente})</option>)}
              </select>
            </div>
            {form.tipo_documento === 'PROPOSTA' && (
              <div className="field"><label>ID da proposta *</label><input required value={form.proposta_id} onChange={(e) => setForm({ ...form, proposta_id: e.target.value })} /></div>
            )}
            {form.tipo_documento === 'CONTRATO' && (
              <div className="field"><label>ID do contrato *</label><input required value={form.contrato_id} onChange={(e) => setForm({ ...form, contrato_id: e.target.value })} /></div>
            )}
            {form.tipo_documento === 'ADITIVO' && (
              <div className="field"><label>ID do aditivo *</label><input required value={form.aditivo_id} onChange={(e) => setForm({ ...form, aditivo_id: e.target.value })} /></div>
            )}
            <div className="field">
              <label>PDF {form.tipo_documento !== 'PROPOSTA' ? '*' : '(opcional — senão gera automaticamente)'}</label>
              <input type="file" accept="application/pdf" required={form.tipo_documento !== 'PROPOSTA'} onChange={(e) => setFile(e.target.files?.[0] || null)} />
            </div>
            <div style={{ gridColumn: 'span 3' }}><button type="submit" className="btn btn-primary" disabled={saving}>{saving ? 'Criando…' : 'Criar envelope'}</button></div>
          </form>
        </div>
      )}

      {!envelopes ? (
        <div className="card"><div className="spinner" /></div>
      ) : envelopes.length === 0 ? (
        <div className="card"><div className="empty-state">Nenhum envelope de assinatura ainda. Crie um a partir de uma proposta assinada ou de um contrato gerado.</div></div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <div className="table-scroll">
            <table>
              <thead><tr><th>Tipo</th><th>Status</th><th>Criado em</th><th>Enviado em</th><th>Concluído em</th><th></th></tr></thead>
              <tbody>
                {envelopes.map((e) => (
                  <tr key={e.id}>
                    <td>{e.tipo_documento}</td>
                    <td><span className={`badge ${STATUS_CLASS[e.status] || ''}`}>{e.status}</span></td>
                    <td>{new Date(e.criado_em).toLocaleString('pt-BR')}</td>
                    <td>{e.enviado_em ? new Date(e.enviado_em).toLocaleString('pt-BR') : '—'}</td>
                    <td>{e.concluido_em ? new Date(e.concluido_em).toLocaleString('pt-BR') : '—'}</td>
                    <td><Link className="link-tab" to={`/assinaturas/${e.id}`}>Detalhe →</Link></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
