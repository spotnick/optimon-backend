import { useEffect, useState } from 'react';
import { api, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import ArchiveModal from '../components/ArchiveModal';
import UserEditModal from '../components/UserEditModal';

// Fase 2.5.1 (seções 1-8): fluxo CORRIGIDO — nunca mais pede UUID de
// auth.users ao administrador. "+ Novo Usuário" cria a identidade no
// Supabase Auth (convite por e-mail) e completa o cadastro numa chamada só
// (POST /api/users/invite, ver api/routes/users.js e
// docs/ARQUITETURA.md seção 24 para a decisão de arquitetura por trás disso).
const PERFIS = ['ADMINISTRADOR', 'DIRETOR', 'COMERCIAL', 'FINANCEIRO', 'ENGENHARIA', 'AUDITOR'];
const MOTIVOS_DESATIVACAO = ['Desligamento', 'Mudança de função', 'Acesso indevido detectado', 'Solicitação do próprio usuário', 'Outro'];

function emptyForm() {
  return { nome: '', email: '', telefone: '', cpf: '', cargo: '', departamento: '', perfil: 'COMERCIAL', observacoes: '' };
}

const STATUS_BADGE = {
  ATIVO: 'status-allow',
  CONVITE_PENDENTE: 'status-discount',
  INATIVO: 'status-block',
  BLOQUEADO: 'status-block',
};
const STATUS_LABEL = {
  ATIVO: 'Ativo',
  CONVITE_PENDENTE: 'Convite pendente',
  INATIVO: 'Inativo',
  BLOQUEADO: 'Bloqueado',
};

export default function Users() {
  const { role } = useAuth();
  const isAdmin = role === 'ADMINISTRADOR';
  const [users, setUsers] = useState(null);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState(emptyForm());
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState(null);
  const [editTarget, setEditTarget] = useState(null);
  const [archiveTarget, setArchiveTarget] = useState(null); // { user, mode: 'archive'|'restore' }
  const [busyId, setBusyId] = useState(null);

  function load() {
    setUsers(null);
    api.users.list().then(setUsers).catch((err) => setError(err.message));
  }
  useEffect(load, []);

  async function handleCreate(e) {
    e.preventDefault();
    setFormError(null);
    setNotice(null);
    setSaving(true);
    try {
      const created = await api.users.invite(form);
      setForm(emptyForm());
      setShowForm(false);
      setNotice(created.message || `Convite enviado para ${form.email}.`);
      load();
    } catch (err) {
      setFormError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setSaving(false);
    }
  }

  async function handleResendInvite(u) {
    setBusyId(u.id);
    setNotice(null);
    try {
      const { message } = await api.users.resendInvite(u.id);
      setNotice(message);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusyId(null);
    }
  }

  async function handleResetAccess(u) {
    setBusyId(u.id);
    setNotice(null);
    try {
      const { message } = await api.users.resetAccess(u.id);
      setNotice(message);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusyId(null);
    }
  }

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;

  return (
    <div className="page">
      <div className="page-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h1>Usuários</h1>
          <p>RBAC de 6 perfis (ADMINISTRADOR/DIRETOR/COMERCIAL/FINANCEIRO/ENGENHARIA/AUDITOR) — aplicado sempre no servidor, nunca confiando no frontend.</p>
        </div>
        {isAdmin && (
          <button className="btn btn-primary" onClick={() => setShowForm((s) => !s)}>
            {showForm ? 'Cancelar' : '+ Novo Usuário'}
          </button>
        )}
      </div>

      {notice && <div className="card" style={{ marginBottom: 16, borderColor: 'var(--accent-success, #1a9c5e)' }}>{notice}</div>}

      {showForm && (
        <div className="card" style={{ marginBottom: 16 }}>
          <p style={{ marginTop: 0, color: 'var(--text-muted, #666)' }}>
            O convite é enviado direto pelo Supabase Auth — o próprio usuário define a senha ao clicar no link recebido
            por e-mail. O OptiMon nunca armazena ou pede senha.
          </p>
          {formError && <div className="error-banner">{formError}</div>}
          <form onSubmit={handleCreate} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
            <div className="field"><label>Nome *</label><input required value={form.nome} onChange={(e) => setForm({ ...form, nome: e.target.value })} /></div>
            <div className="field"><label>E-mail *</label><input required type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} /></div>
            <div className="field"><label>Telefone</label><input value={form.telefone} onChange={(e) => setForm({ ...form, telefone: e.target.value })} /></div>
            <div className="field"><label>CPF</label><input value={form.cpf} onChange={(e) => setForm({ ...form, cpf: e.target.value })} placeholder="11 dígitos" /></div>
            <div className="field"><label>Cargo</label><input value={form.cargo} onChange={(e) => setForm({ ...form, cargo: e.target.value })} /></div>
            <div className="field"><label>Departamento</label><input value={form.departamento} onChange={(e) => setForm({ ...form, departamento: e.target.value })} /></div>
            <div className="field">
              <label>Perfil *</label>
              <select value={form.perfil} onChange={(e) => setForm({ ...form, perfil: e.target.value })}>
                {PERFIS.map((p) => <option key={p} value={p}>{p}</option>)}
              </select>
            </div>
            <div className="field" style={{ gridColumn: 'span 3' }}><label>Observações</label><input value={form.observacoes} onChange={(e) => setForm({ ...form, observacoes: e.target.value })} /></div>
            <div style={{ gridColumn: 'span 3' }}>
              <button type="submit" className="btn btn-primary" disabled={saving}>{saving ? 'Enviando convite…' : 'Criar Usuário'}</button>
            </div>
          </form>
        </div>
      )}

      {!users ? (
        <div className="card"><div className="spinner" /></div>
      ) : users.length === 0 ? (
        <div className="card"><div className="empty-state">Nenhum usuário cadastrado ainda.</div></div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Nome</th><th>E-mail</th><th>Cargo</th><th>Perfil</th><th>Status</th><th>Último acesso</th>{isAdmin && <th>Ações</th>}
                </tr>
              </thead>
              <tbody>
                {users.map((u) => {
                  const statusKey = u.status_auth || (u.ativo ? null : 'INATIVO');
                  return (
                    <tr key={u.id}>
                      <td>{u.nome}</td>
                      <td>{u.email}</td>
                      <td>{u.cargo || '—'}</td>
                      <td><span className="badge">{u.perfil}</span></td>
                      <td>
                        {statusKey ? (
                          <span className={`badge ${STATUS_BADGE[statusKey] || ''}`}>{STATUS_LABEL[statusKey] || statusKey}</span>
                        ) : (
                          <span className={`badge ${u.ativo ? 'status-allow' : 'status-block'}`}>{u.ativo ? 'Ativo' : 'Inativo'}</span>
                        )}
                      </td>
                      <td>{u.ultimo_acesso_em ? new Date(u.ultimo_acesso_em).toLocaleString('pt-BR') : '—'}</td>
                      {isAdmin && (
                        <td>
                          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                            <button className="btn btn-secondary" onClick={() => setEditTarget(u)}>Editar</button>
                            {u.ativo ? (
                              <button className="btn btn-danger" onClick={() => setArchiveTarget({ user: u, mode: 'archive' })}>Desativar</button>
                            ) : (
                              <button className="btn btn-primary" onClick={() => setArchiveTarget({ user: u, mode: 'restore' })}>Reativar</button>
                            )}
                            {statusKey === 'CONVITE_PENDENTE' && (
                              <button className="btn btn-secondary" disabled={busyId === u.id} onClick={() => handleResendInvite(u)}>
                                {busyId === u.id ? '…' : 'Reenviar convite'}
                              </button>
                            )}
                            {u.ativo && statusKey !== 'CONVITE_PENDENTE' && (
                              <button className="btn btn-secondary" disabled={busyId === u.id} onClick={() => handleResetAccess(u)}>
                                {busyId === u.id ? '…' : 'Redefinir acesso'}
                              </button>
                            )}
                          </div>
                        </td>
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {editTarget && (
        <UserEditModal
          user={editTarget}
          perfis={PERFIS}
          onCancel={() => setEditTarget(null)}
          onSave={async (patch) => {
            await api.users.update(editTarget.id, patch);
            setEditTarget(null);
            load();
          }}
        />
      )}

      {archiveTarget && (
        <ArchiveModal
          title={archiveTarget.mode === 'archive' ? 'Desativar usuário?' : 'Reativar usuário?'}
          subject={`${archiveTarget.user.nome} (${archiveTarget.user.email}). ${archiveTarget.mode === 'archive' ? 'O usuário perde acesso ao sistema imediatamente — o histórico e a auditoria são preservados, nada é apagado.' : 'O usuário volta a conseguir acessar o sistema com o mesmo login.'}`}
          mode={archiveTarget.mode}
          motivoOptions={MOTIVOS_DESATIVACAO}
          onCancel={() => setArchiveTarget(null)}
          onConfirm={async (body) => {
            if (archiveTarget.mode === 'archive') {
              const result = await api.users.deactivate(archiveTarget.user.id, { motivo: body.motivo });
              if (result.auth_warning) setNotice(result.auth_warning);
            } else {
              await api.users.reactivate(archiveTarget.user.id, { motivo: body.motivo });
            }
            setArchiveTarget(null);
            load();
          }}
        />
      )}
    </div>
  );
}
