import { useState } from 'react';
import { ApiError } from '../lib/api';

// Fase 2.5.1 (seção 7): "Editar Usuário" — nunca permite alterar
// auth.users.id (nem sequer aparece no formulário). `status` (ativo/inativo)
// tem seu próprio fluxo com confirmação (ArchiveModal, em Users.jsx) — este
// modal só cobre os campos cadastrais + perfil.
export default function UserEditModal({ user, perfis, onCancel, onSave }) {
  const [form, setForm] = useState({
    nome: user.nome || '',
    telefone: user.telefone || '',
    cpf: user.cpf || '',
    cargo: user.cargo || '',
    departamento: user.departamento || '',
    perfil: user.perfil,
    observacoes: user.observacoes || '',
  });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function handleSave() {
    setError(null);
    setSaving(true);
    try {
      await onSave(form);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro inesperado.');
      setSaving(false);
    }
  }

  return (
    <div className="modal-overlay" role="dialog" aria-modal="true" onClick={(e) => e.target === e.currentTarget && onCancel()}>
      <div className="modal-dialog">
        <h3>Editar usuário</h3>
        <div className="modal-subject">{user.nome} — {user.email} (e-mail e identidade de login nunca são alterados aqui)</div>
        {error && <div className="error-banner">{error}</div>}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 12, marginBottom: 12 }}>
          <div className="field"><label>Nome</label><input value={form.nome} onChange={(e) => setForm({ ...form, nome: e.target.value })} /></div>
          <div className="field">
            <label>Perfil</label>
            <select value={form.perfil} onChange={(e) => setForm({ ...form, perfil: e.target.value })}>
              {perfis.map((p) => <option key={p} value={p}>{p}</option>)}
            </select>
          </div>
          <div className="field"><label>Telefone</label><input value={form.telefone} onChange={(e) => setForm({ ...form, telefone: e.target.value })} /></div>
          <div className="field"><label>CPF</label><input value={form.cpf} onChange={(e) => setForm({ ...form, cpf: e.target.value })} /></div>
          <div className="field"><label>Cargo</label><input value={form.cargo} onChange={(e) => setForm({ ...form, cargo: e.target.value })} /></div>
          <div className="field"><label>Departamento</label><input value={form.departamento} onChange={(e) => setForm({ ...form, departamento: e.target.value })} /></div>
          <div className="field" style={{ gridColumn: 'span 2' }}><label>Observações</label><input value={form.observacoes} onChange={(e) => setForm({ ...form, observacoes: e.target.value })} /></div>
        </div>
        <div className="modal-actions">
          <button type="button" className="btn btn-secondary" onClick={onCancel} disabled={saving}>Cancelar</button>
          <button type="button" className="btn btn-primary" onClick={handleSave} disabled={saving}>{saving ? 'Salvando…' : 'Salvar'}</button>
        </div>
      </div>
    </div>
  );
}
