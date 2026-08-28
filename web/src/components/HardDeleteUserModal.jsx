import { useState } from 'react';
import { ApiError } from '../lib/api';

// Fase 3 (item 3.8): exclusão FÍSICA controlada de usuário — deliberadamente um
// componente PRÓPRIO, não o ArchiveModal reaproveitado por toda a tela de Usuários. A
// cópia do ArchiveModal para "Desativar" é explícita sobre nada ser apagado ("o histórico
// e a auditoria são preservados"); aqui é o oposto — o cadastro é removido de verdade — e
// essa diferença precisa ficar óbvia na interface, não escondida atrás do mesmo modal
// genérico. Exige que o administrador digite o e-mail do usuário para confirmar (padrão
// comum para ações destrutivas irreversíveis) e um motivo obrigatório — o servidor recusa
// a exclusão se o usuário tiver qualquer vínculo em auditoria/aprovações (ver
// app.excluir_usuario_fisicamente), então este modal só precisa comunicar isso com
// clareza, nunca reimplementar a checagem.
export default function HardDeleteUserModal({ user, onCancel, onConfirm }) {
  const [motivo, setMotivo] = useState('');
  const [confirmEmail, setConfirmEmail] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  const emailConfere = confirmEmail.trim().toLowerCase() === (user.email || '').trim().toLowerCase();
  const podeConfirmar = motivo.trim().length > 0 && emailConfere;

  async function handleConfirm() {
    if (!podeConfirmar) return;
    setError(null);
    setSaving(true);
    try {
      await onConfirm({ motivo: motivo.trim() });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro inesperado.');
      setSaving(false);
    }
  }

  return (
    <div className="modal-overlay" role="dialog" aria-modal="true" onClick={(e) => e.target === e.currentTarget && onCancel()}>
      <div className="modal-dialog">
        <h3>Excluir usuário fisicamente?</h3>
        <div className="modal-subject">{user.nome} ({user.email})</div>
        <div className="error-banner" style={{ marginBottom: 12 }}>
          <strong>Esta ação é IRREVERSÍVEL.</strong> Diferente de "Desativar", o cadastro é removido de verdade do banco de
          dados — não é apenas bloqueio de acesso. O servidor só permite a exclusão se este usuário nunca tiver realizado
          nenhuma ação registrada em auditoria, aprovações ou criações de registros (contratos, propostas, etc.). Se houver
          qualquer vínculo, a exclusão será recusada automaticamente — use "Desativar" nesse caso, que preserva todo o
          histórico e bloqueia o acesso imediatamente.
        </div>
        {error && <div className="error-banner">{error}</div>}
        <div className="field" style={{ marginBottom: 12 }}>
          <label>Motivo *</label>
          <input value={motivo} onChange={(e) => setMotivo(e.target.value)} placeholder="Ex.: cadastro duplicado, criado por engano, nunca utilizado" />
        </div>
        <div className="field">
          <label>Digite o e-mail do usuário para confirmar *</label>
          <input value={confirmEmail} onChange={(e) => setConfirmEmail(e.target.value)} placeholder={user.email} />
        </div>
        <div className="modal-actions">
          <button type="button" className="btn btn-secondary" onClick={onCancel} disabled={saving}>Cancelar</button>
          <button type="button" className="btn btn-danger" onClick={handleConfirm} disabled={saving || !podeConfirmar}>
            {saving ? 'Excluindo…' : 'Excluir Fisicamente'}
          </button>
        </div>
      </div>
    </div>
  );
}
