import { useEffect, useState } from 'react';
import { api, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';

// Fase 2.5 seção 14/15 — /usuarios. Criar usuário pressupõe que o convite de
// autenticação (Supabase Auth) já foi feito pelo painel do Supabase (ver
// comentário em api/routes/users.js) — este formulário só completa o
// cadastro, pedindo o "id" gerado por aquele convite.
const PERFIS = ['ADMINISTRADOR', 'DIRETOR', 'COMERCIAL', 'FINANCEIRO', 'ENGENHARIA', 'AUDITOR'];

function emptyForm() {
  return { id: '', nome: '', email: '', telefone: '', cpf: '', cargo: '', departamento: '', perfil: 'COMERCIAL', observacoes: '' };
}

export default function Users() {
  const { role } = useAuth();
  const isAdmin = role === 'ADMINISTRADOR';
  const [users, setUsers] = useState(null);
  const [error, setError] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState(emptyForm());
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState(null);

  function load() {
    setUsers(null);
    api.users.list().then(setUsers).catch((err) => setError(err.message));
  }
  useEffect(load, []);

  async function handleCreate(e) {
    e.preventDefault();
    setFormError(null);
    setSaving(true);
    try {
      await api.users.create(form);
      setForm(emptyForm());
      setShowForm(false);
      load();
    } catch (err) {
      setFormError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setSaving(false);
    }
  }

  async function toggleAtivo(u) {
    try {
      await api.users.update(u.id, { ativo: !u.ativo });
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    }
  }

  async function changePerfil(u, perfil) {
    try {
      await api.users.update(u.id, { perfil });
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro inesperado.');
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
            {showForm ? 'Cancelar' : '+ Completar cadastro de usuário'}
          </button>
        )}
      </div>

      {showForm && (
        <div className="card" style={{ marginBottom: 16 }}>
          <p style={{ marginTop: 0 }}>
            O usuário precisa já ter sido <strong>convidado pelo Supabase Auth</strong> (painel Supabase → Authentication →
            Users → Invite user) — copie o <code>id</code> gerado e complete o cadastro aqui.
          </p>
          {formError && <div className="error-banner">{formError}</div>}
          <form onSubmit={handleCreate} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
            <div className="field"><label>ID (auth.users.id) *</label><input required value={form.id} onChange={(e) => setForm({ ...form, id: e.target.value })} /></div>
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
              <button type="submit" className="btn btn-primary" disabled={saving}>{saving ? 'Salvando…' : 'Salvar'}</button>
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
                  <th>Nome</th><th>E-mail</th><th>Cargo</th><th>Departamento</th><th>Perfil</th><th>Status</th><th>Último acesso</th>
                </tr>
              </thead>
              <tbody>
                {users.map((u) => (
                  <tr key={u.id}>
                    <td>{u.nome}</td>
                    <td>{u.email}</td>
                    <td>{u.cargo || '—'}</td>
                    <td>{u.departamento || '—'}</td>
                    <td>
                      {isAdmin ? (
                        <select value={u.perfil} onChange={(e) => changePerfil(u, e.target.value)}>
                          {PERFIS.map((p) => <option key={p} value={p}>{p}</option>)}
                        </select>
                      ) : (
                        <span className="badge">{u.perfil}</span>
                      )}
                    </td>
                    <td>
                      {isAdmin ? (
                        <button className={`btn ${u.ativo ? 'btn-secondary' : 'btn-primary'}`} onClick={() => toggleAtivo(u)}>
                          {u.ativo ? 'Ativo' : 'Inativo'}
                        </button>
                      ) : (
                        <span className={`badge ${u.ativo ? 'status-allow' : 'status-block'}`}>{u.ativo ? 'Ativo' : 'Inativo'}</span>
                      )}
                    </td>
                    <td>{u.ultimo_acesso_em ? new Date(u.ultimo_acesso_em).toLocaleString('pt-BR') : '—'}</td>
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
