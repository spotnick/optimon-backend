import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import ArchiveModal from '../components/ArchiveModal';

const MOTIVOS_DESATIVACAO = ['Encerrou operação', 'Substituído por outro proponente', 'Erro de cadastro', 'Inadimplência', 'Outro'];
const CAN_WRITE = ['COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'];

// Fase 2.5 seção 16 — /proponentes. "Proponente" = a tabela `parceiros` já
// existente, estendida (ver migration 02) — nunca uma entidade nova/paralela.
function emptyForm() {
  return { razao_social: '', nome_fantasia: '', cnpj: '', email_contato: '', telefone_contato: '', responsavel_comercial: '' };
}

export default function Partners() {
  const { role } = useAuth();
  const canWrite = CAN_WRITE.includes(role);
  const [partners, setPartners] = useState(null);
  const [error, setError] = useState(null);
  const [q, setQ] = useState('');
  const [statusFilter, setStatusFilter] = useState('true');
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState(emptyForm());
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState(null);
  const [archiveTarget, setArchiveTarget] = useState(null); // { partner, mode }

  function load() {
    setPartners(null);
    const params = { ativo: statusFilter };
    if (q) params.q = q;
    api.partners.list(params).then(setPartners).catch((err) => setError(err.message));
  }
  useEffect(load, [q, statusFilter]);

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
          <div className="field">
            <label>Status</label>
            <select value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)}>
              <option value="true">Ativos</option>
              <option value="false">Inativos</option>
              <option value="todos">Todos</option>
            </select>
          </div>
          {canWrite && <button className="btn btn-primary" onClick={() => setShowForm((s) => !s)}>{showForm ? 'Cancelar' : '+ Novo Proponente'}</button>}
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
              <thead><tr><th>Razão social</th><th>Fantasia</th><th>CNPJ</th><th>Cidade</th><th>Status</th><th>Ações</th></tr></thead>
              <tbody>
                {partners.map((p) => (
                  <tr key={p.id}>
                    <td>{p.razao_social}</td>
                    <td>{p.nome_fantasia || '—'}</td>
                    <td style={{ fontFamily: 'var(--font-mono)' }}>{p.cnpj}</td>
                    <td>{p.endereco_cidade ? `${p.endereco_cidade}/${p.endereco_uf || ''}` : '—'}</td>
                    <td><span className={`badge ${p.ativo ? 'status-allow' : 'status-block'}`}>{p.ativo ? 'Ativo' : 'Inativo'}</span></td>
                    <td>
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                        <Link className="link-tab" to={`/proponentes/${p.id}`}>Visualizar</Link>
                        {canWrite && <Link className="link-tab" to={`/proponentes/${p.id}?editar=1`}>Editar</Link>}
                        {canWrite && (p.ativo ? (
                          <button className="btn btn-danger" onClick={() => setArchiveTarget({ partner: p, mode: 'archive' })}>Desativar</button>
                        ) : (
                          <button className="btn btn-primary" onClick={() => setArchiveTarget({ partner: p, mode: 'restore' })}>Reativar</button>
                        ))}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {archiveTarget && (
        <ArchiveModal
          title={archiveTarget.mode === 'archive' ? 'Desativar proponente?' : 'Reativar proponente?'}
          subject={`${archiveTarget.partner.nome_fantasia || archiveTarget.partner.razao_social} — CNPJ ${archiveTarget.partner.cnpj}. ${archiveTarget.mode === 'archive' ? 'O proponente sai das listas ativas e não pode mais receber novas propostas — propostas e contratos já existentes são preservados integralmente.' : 'O proponente volta a poder receber novas propostas.'}`}
          mode={archiveTarget.mode}
          motivoOptions={MOTIVOS_DESATIVACAO}
          onCancel={() => setArchiveTarget(null)}
          onConfirm={async (body) => {
            if (archiveTarget.mode === 'archive') {
              await api.partners.deactivate(archiveTarget.partner.id, { motivo: body.motivo });
            } else {
              await api.partners.reactivate(archiveTarget.partner.id, { motivo: body.motivo });
            }
            setArchiveTarget(null);
            load();
          }}
        />
      )}
    </div>
  );
}
