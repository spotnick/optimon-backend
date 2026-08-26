import { useState } from 'react';
import { ApiError } from '../lib/api';

// Fase 2.3.1 (seção 19/29): modal de confirmação obrigatório para qualquer arquivamento
// — nunca arquiva no clique direto. Mostra nome/tipo/cidade do item (subject), pede um
// motivo (lista fechada da seção 29 + Outro) e uma observação livre opcional. Também
// reaproveitado para restauração (motivoOptions omitido → só observação/confirmação
// simples, seção 21 não pede motivo de lista fechada para restaurar).
const MOTIVOS_ARQUIVAMENTO = [
  'Infraestrutura desativada',
  'Erro de cadastro',
  'Substituição',
  'Expansão',
  'Alteração de projeto',
  'Venda',
  'Outro',
];

export default function ArchiveModal({ title, subject, mode = 'archive', onCancel, onConfirm }) {
  const [motivo, setMotivo] = useState(MOTIVOS_ARQUIVAMENTO[0]);
  const [observacao, setObservacao] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);

  async function handleConfirm() {
    setError(null);
    setSaving(true);
    try {
      if (mode === 'archive') {
        await onConfirm({ motivo, observacao: observacao || null });
      } else {
        await onConfirm({ motivo: observacao || null });
      }
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro inesperado.');
      setSaving(false);
    }
  }

  return (
    <div className="modal-overlay" role="dialog" aria-modal="true" onClick={(e) => e.target === e.currentTarget && onCancel()}>
      <div className="modal-dialog">
        <h3>{title}</h3>
        <div className="modal-subject">{subject}</div>
        {error && <div className="error-banner">{error}</div>}
        {mode === 'archive' ? (
          <>
            <div className="field" style={{ marginBottom: 12 }}>
              <label>Motivo *</label>
              <select value={motivo} onChange={(e) => setMotivo(e.target.value)}>
                {MOTIVOS_ARQUIVAMENTO.map((m) => <option key={m} value={m}>{m}</option>)}
              </select>
            </div>
            <div className="field">
              <label>Observação</label>
              <input value={observacao} onChange={(e) => setObservacao(e.target.value)} placeholder="Detalhe o motivo, se necessário" />
            </div>
          </>
        ) : (
          <div className="field">
            <label>Observação (opcional)</label>
            <input value={observacao} onChange={(e) => setObservacao(e.target.value)} placeholder="Ex.: restaurado por engano no arquivamento anterior" />
          </div>
        )}
        <div className="modal-actions">
          <button type="button" className="btn btn-secondary" onClick={onCancel} disabled={saving}>Cancelar</button>
          <button type="button" className={mode === 'archive' ? 'btn btn-danger' : 'btn btn-primary'} onClick={handleConfirm} disabled={saving}>
            {saving ? 'Confirmando…' : mode === 'archive' ? 'Confirmar Arquivamento' : 'Confirmar Restauração'}
          </button>
        </div>
      </div>
    </div>
  );
}
