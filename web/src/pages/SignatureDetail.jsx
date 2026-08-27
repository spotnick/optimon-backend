import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { api, ApiError } from '../lib/api';

const PAPEIS = ['REPRESENTANTE_NICK', 'REPRESENTANTE_PROPONENTE', 'TESTEMUNHA', 'OUTRO'];

const CHECK_LABELS = {
  documento_integro: 'Documento íntegro (hash presente)',
  assinatura_valida: 'Assinatura no provedor confirmada',
  certificado_valido: 'Certificado ICP-Brasil qualificado',
  signatarios_confirmados: 'Todos os signatários confirmaram',
  documento_nao_alterado: 'Documento não foi alterado após assinado',
};

function emptySigner() {
  return { nome: '', email: '', cpf: '', papel: 'REPRESENTANTE_PROPONENTE', ordem: 1 };
}

export default function SignatureDetail() {
  const { id } = useParams();
  const [envelope, setEnvelope] = useState(null);
  const [audit, setAudit] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState(null);
  const [validation, setValidation] = useState(null);

  const [showSignerForm, setShowSignerForm] = useState(false);
  const [signerForm, setSignerForm] = useState(emptySigner());

  function load() {
    api.signatures.envelope(id).then(setEnvelope).catch((err) => setError(err.message));
    api.signatures.audit(id).then(setAudit).catch(() => {});
  }
  useEffect(load, [id]);

  async function handleAddSigner(e) {
    e.preventDefault();
    setActionError(null);
    setBusy(true);
    try {
      await api.signatures.addSigner(id, { ...signerForm, ordem: Number(signerForm.ordem) });
      setSignerForm(emptySigner());
      setShowSignerForm(false);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleSend() {
    setActionError(null); setBusy(true);
    try { await api.signatures.send(id); load(); }
    catch (err) { setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.'); }
    finally { setBusy(false); }
  }

  async function handleCancel() {
    const motivo = window.prompt('Motivo do cancelamento (obrigatório):');
    if (!motivo) return;
    setActionError(null); setBusy(true);
    try { await api.signatures.cancel(id, { motivo }); load(); }
    catch (err) { setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.'); }
    finally { setBusy(false); }
  }

  async function handleValidate() {
    setActionError(null); setBusy(true);
    try { setValidation(await api.signatures.validate(id)); load(); }
    catch (err) { setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.'); }
    finally { setBusy(false); }
  }

  async function handleDownload() {
    setActionError(null);
    try {
      const { url } = await api.signatures.document(id);
      window.open(url, '_blank', 'noopener');
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Documento assinado ainda não disponível.');
    }
  }

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;
  if (!envelope) return <div className="page"><div className="card"><div className="spinner" /></div></div>;

  return (
    <div className="page">
      <div className="page-header">
        <h1>Envelope de Assinatura — {envelope.tipo_documento}</h1>
        <p>Status atual: <span className="badge">{envelope.status}</span></p>
      </div>

      {actionError && <div className="error-banner">{actionError}</div>}

      <div className="card" style={{ marginBottom: 16, display: 'flex', gap: 12, flexWrap: 'wrap' }}>
        <button className="btn btn-secondary" disabled={busy} onClick={() => setShowSignerForm((s) => !s)}>{showSignerForm ? 'Cancelar' : '+ Signatário'}</button>
        <button className="btn btn-primary" disabled={busy || envelope.status !== 'CRIADO'} onClick={handleSend}>Enviar para assinatura</button>
        <button className="btn btn-secondary" disabled={busy} onClick={handleValidate}>Validar assinatura</button>
        <button className="btn btn-secondary" disabled={busy} onClick={handleDownload}>Baixar documento assinado</button>
        <button className="btn btn-danger" disabled={busy || ['ASSINADO', 'VALIDADO', 'CANCELADO'].includes(envelope.status)} onClick={handleCancel}>Cancelar envelope</button>
      </div>

      {showSignerForm && (
        <div className="card" style={{ marginBottom: 16 }}>
          <form onSubmit={handleAddSigner} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
            <div className="field"><label>Nome *</label><input required value={signerForm.nome} onChange={(e) => setSignerForm({ ...signerForm, nome: e.target.value })} /></div>
            <div className="field"><label>E-mail *</label><input required type="email" value={signerForm.email} onChange={(e) => setSignerForm({ ...signerForm, email: e.target.value })} /></div>
            <div className="field"><label>CPF</label><input value={signerForm.cpf} onChange={(e) => setSignerForm({ ...signerForm, cpf: e.target.value })} /></div>
            <div className="field">
              <label>Papel *</label>
              <select value={signerForm.papel} onChange={(e) => setSignerForm({ ...signerForm, papel: e.target.value })}>
                {PAPEIS.map((p) => <option key={p} value={p}>{p}</option>)}
              </select>
            </div>
            <div className="field"><label>Ordem</label><input type="number" min="1" value={signerForm.ordem} onChange={(e) => setSignerForm({ ...signerForm, ordem: e.target.value })} /></div>
            <div style={{ gridColumn: 'span 3' }}><button type="submit" className="btn btn-primary" disabled={busy}>Adicionar</button></div>
          </form>
        </div>
      )}

      {validation && (
        <div className="card" style={{ marginBottom: 16 }}>
          <h3 style={{ marginTop: 0 }}>Resultado da validação</h3>
          <ul style={{ listStyle: 'none', padding: 0, margin: 0 }}>
            {Object.entries(CHECK_LABELS).map(([key, label]) => (
              <li key={key} style={{ padding: '4px 0' }}>
                <span style={{ color: validation[key] ? '#1a7f37' : '#c92a2a', fontWeight: 700 }}>{validation[key] ? '✓' : '✕'}</span> {label}
              </li>
            ))}
          </ul>
          <p style={{ fontWeight: 700 }}>{validation.validado ? '✓ Assinatura VALIDADA — todos os critérios confirmados.' : '✕ Assinatura ainda NÃO pode ser considerada válida — nem todo status=ASSINADO garante isso por si só.'}</p>
        </div>
      )}

      <div className="card" style={{ marginBottom: 16 }}>
        <h3 style={{ marginTop: 0 }}>Signatários</h3>
        {(envelope.signatarios || []).length === 0 ? (
          <div className="empty-state">Nenhum signatário adicionado ainda.</div>
        ) : (
          <table>
            <thead><tr><th>Ordem</th><th>Nome</th><th>E-mail</th><th>Papel</th><th>Status</th><th>Assinado em</th></tr></thead>
            <tbody>
              {envelope.signatarios.map((s) => (
                <tr key={s.id}>
                  <td>{s.ordem}</td><td>{s.nome}</td><td>{s.email}</td><td>{s.papel}</td>
                  <td><span className="badge">{s.status}</span></td>
                  <td>{s.assinado_em ? new Date(s.assinado_em).toLocaleString('pt-BR') : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Trilha de auditoria (eventos + evidências do provedor)</h3>
        {!audit ? <div className="spinner" /> : (
          <>
            <table style={{ marginBottom: 16 }}>
              <thead><tr><th>Evento</th><th>Recebido em</th><th>Processado</th></tr></thead>
              <tbody>
                {(audit.eventos || []).length === 0 ? (
                  <tr><td colSpan={3} className="empty-state">Nenhum evento recebido ainda.</td></tr>
                ) : audit.eventos.map((ev) => (
                  <tr key={ev.id}><td>{ev.tipo_evento}</td><td>{new Date(ev.recebido_em).toLocaleString('pt-BR')}</td><td>{ev.processado ? 'Sim' : 'Não'}</td></tr>
                ))}
              </tbody>
            </table>
          </>
        )}
      </div>
    </div>
  );
}
