import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, ApiError } from '../lib/api';

// Fase 2.5 seção 16 — /proponentes. "Proponente" = a tabela `parceiros` já
// existente, estendida (ver migration 02) — nunca uma entidade nova/paralela.
function emptyForm() {
  return { razao_social: '', nome_fantasia: '', cnpj: '', email_contato: '', telefone_contato: '', responsavel_comercial: '' };
}

export default function Partners() {
  const [partners, setPartners] = useState(null);
  const [error, setError] = useState(null);
  const [q, setQ] = useState('');
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState(emptyForm());
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState(null);

  function load() {
    setPartners(null);
    api.partners.list(q ? { q } : {}).then(setPartners).catch((err) => setError(err.message));
  }
  useEffect(load, [q]);

  async function handleCreate(e) {
    e.preventDefault();
    setFormError(null);
    setSaving(true);
    try {
      await api.partners.create(form);
      setForm(emptyForm());
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
          <h1>Proponentes</h1>
          <p>Empresas que recebem propostas e podem celebrar contrato — com responsáveis e documentos vinculados.</p>
        </div>
        <div style={{ display: 'flex', gap: 12, alignItems: 'flex-end' }}>
          <div className="field" style={{ minWidth: 220 }}>
            <label>Buscar</label>
            <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Razão social, fantasia ou CNPJ" />
          </div>
          <button className="btn btn-primary" onClick={() => setShowForm((s) => !s)}>{showForm ? 'Cancelar' : '+ Novo Proponente'}</button>
        </div>
      </div>

      {showForm && (
        <div className="card" style={{ marginBottom: 16 }}>
          {formError && <div className="error-banner">{formError}</div>}
          <form onSubmit={handleCreate} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
            <div className="field"><label>Razão social *</label><input required value={form.razao_social} onChange={(e) => setForm({ ...form, razao_social: e.target.value })} /></div>
            <div className="field"><label>Nome fantasia</label><input value={form.nome_fantasia} onChange={(e) => setForm({ ...form, nome_fantasia: e.target.value })} /></div>
            <div className="field"><label>CNPJ *</label><input required value={form.cnpj} onChange={(e) => setForm({ ...form, cnpj: e.target.value })} placeholder="14 dígitos" /></div>
            <div className="field"><label>E-mail de contato</label><input value={form.email_contato} onChange={(e) => setForm({ ...form, email_contato: e.target.value })} /></div>
            <div className="field"><label>Telefone de contato</label><input value={form.telefone_contato} onChange={(e) => setForm({ ...form, telefone_contato: e.target.value })} /></div>
            <div className="field"><label>Responsável comercial</label><input value={form.responsavel_comercial} onChange={(e) => setForm({ ...form, responsavel_comercial: e.target.value })} /></div>
            <div style={{ gridColumn: 'span 3' }}>
              <button type="submit" className="btn btn-primary" disabled={saving}>{saving ? 'Salvando…' : 'Salvar'}</button>
            </div>
          </form>
        </div>
      )}

      {!partners ? (
        <div className="card"><div className="spinner" /></div>
      ) : partners.length === 0 ? (
        <div className="card"><div className="empty-state">Nenhum proponente encontrado.</div></div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <div className="table-scroll">
            <table>
              <thead><tr><th>Razão social</th><th>Fantasia</th><th>CNPJ</th><th>Cidade</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {partners.map((p) => (
                  <tr key={p.id}>
                    <td>{p.razao_social}</td>
                    <td>{p.nome_fantasia || '—'}</td>
                    <td style={{ fontFamily: 'var(--font-mono)' }}>{p.cnpj}</td>
                    <td>{p.endereco_cidade ? `${p.endereco_cidade}/${p.endereco_uf || ''}` : '—'}</td>
                    <td><span className={`badge ${p.ativo ? 'status-allow' : 'status-block'}`}>{p.ativo ? 'Ativo' : 'Inativo'}</span></td>
                    <td><Link className="link-tab" to={`/proponentes/${p.id}`}>Detalhe →</Link></td>
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
