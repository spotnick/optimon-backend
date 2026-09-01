// OptiMon — Fase 3.11.4 (seções 12-13): área externa REAL do signatário. Página
// pública, SEM login, alcançada por /assinar/:token (fora de <ProtectedRoute>, ver
// App.jsx — mesmo padrão de /parceiro/proposta/:token). Nunca chama api.signatures.*
// (exige JWT de usuário da NICK) — usa exclusivamente api.signaturesExternal.*, que fala
// com as rotas anônimas (api/routes/signaturesExternal.js -> RPCs SECURITY DEFINER grant
// para `anon`).

import { useCallback, useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { api, ApiError } from '../lib/api';

const DOC_LABEL = { PROPOSTA: 'Proposta comercial', CONTRATO: 'Contrato', ADITIVO: 'Aditivo contratual' };

export default function SignExternal() {
  const { token } = useParams();
  const [info, setInfo] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [modo, setModo] = useState(null); // null | 'ASSINAR' | 'RECUSAR'
  const [nome, setNome] = useState('');
  const [documento, setDocumento] = useState('');
  const [declaracao, setDeclaracao] = useState(false);
  const [motivoRecusa, setMotivoRecusa] = useState('');
  const [resultado, setResultado] = useState(null); // 'ASSINADO' | 'RECUSADO'

  const load = useCallback(() => {
    setError(null);
    api.signaturesExternal.get(token).then(setInfo).catch((err) => setError(err.message));
  }, [token]);

  useEffect(() => { load(); }, [load]);

  async function handleVerDocumento() {
    try {
      const { url } = await api.signaturesExternal.document(token);
      window.open(url, '_blank', 'noopener');
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Documento ainda não disponível.');
    }
  }

  async function handleAssinar() {
    if (!nome.trim() || !documento.trim()) {
      setError('Nome completo e CPF são obrigatórios para confirmar a assinatura.');
      return;
    }
    if (!declaracao) {
      setError('É necessário declarar que é você quem está assinando e que concorda com o conteúdo do documento.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await api.signaturesExternal.assinar(token, { nome: nome.trim(), documento: documento.trim(), declaracao: true });
      setResultado('ASSINADO');
      setModo(null);
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao confirmar a assinatura.');
    } finally {
      setBusy(false);
    }
  }

  async function handleRecusar() {
    if (!motivoRecusa.trim()) {
      setError('Informe o motivo da recusa.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await api.signaturesExternal.recusar(token, { motivo: motivoRecusa.trim() });
      setResultado('RECUSADO');
      setModo(null);
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao registrar a recusa.');
    } finally {
      setBusy(false);
    }
  }

  if (error && !info) {
    return (
      <div style={{ maxWidth: 560, margin: '80px auto', padding: 24, textAlign: 'center' }}>
        <img src="/branding/optimon-logo-lockup.png" alt="OptiMon" style={{ height: 40, marginBottom: 24 }} />
        <div className="error-banner">{error}</div>
        <p style={{ color: 'var(--text-muted)', marginTop: 12 }}>
          Este link pode ter expirado, já ter sido usado, ou o endereço pode estar incorreto. Entre em contato
          com quem enviou este documento para solicitar um novo link.
        </p>
      </div>
    );
  }
  if (!info) return <div className="page"><div className="spinner" /></div>;

  const jaAssinado = info.ja_assinado;
  const jaRecusado = info.ja_recusado;
  const podeDecidir = !jaAssinado && !jaRecusado;
  const docLabel = DOC_LABEL[info.tipo_documento] || 'Documento';

  return (
    <div style={{ maxWidth: 720, margin: '0 auto', padding: '32px 20px 80px' }}>
      <div className="card" style={{ marginBottom: 24, padding: 0, overflow: 'hidden', background: '#fff' }}>
        <div style={{ padding: '28px 32px', borderBottom: '1px solid var(--border)', display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 16 }}>
          <img src="/branding/optimon-logo-lockup.png" alt="OptiMon" style={{ height: 40 }} />
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontSize: '0.75rem', letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--text-muted)' }}>Assinatura eletrônica</div>
            <div style={{ fontSize: '1.1rem', fontWeight: 700 }}>{docLabel} {info.proposta_numero || info.contrato_numero || ''}</div>
          </div>
        </div>

        <div style={{ padding: '28px 32px' }}>
          {error && <div className="error-banner" style={{ marginBottom: 16 }}>{error}</div>}

          <p style={{ margin: '0 0 16px' }}>Olá, <strong>{info.nome}</strong>. Você foi convidado(a) a assinar eletronicamente este documento.</p>

          <div style={{ display: 'flex', gap: 8, marginBottom: 20 }}>
            <button className="btn btn-secondary" disabled={!info.documento_disponivel} onClick={handleVerDocumento}>
              {info.documento_disponivel ? 'Revisar documento (PDF)' : 'Documento indisponível'}
            </button>
          </div>

          <div className="card" style={{ background: 'var(--surface, #f7f8f9)' }}>
            <h2 className="section-title" style={{ marginBottom: 8 }}>Assinatura</h2>

            {jaAssinado && (
              <div style={{ padding: 10, borderRadius: 6, background: 'rgba(14,110,85,0.1)' }}>
                <strong>✓ Documento assinado.</strong> Obrigado — sua assinatura eletrônica foi registrada com sucesso.
              </div>
            )}
            {jaRecusado && (
              <div style={{ padding: 10, borderRadius: 6, background: 'rgba(180,40,40,0.1)' }}>
                <strong>Assinatura recusada.</strong> Você recusou este documento.
              </div>
            )}

            {podeDecidir && !modo && (
              <>
                <p style={{ margin: '0 0 12px' }}>
                  Revise o documento acima antes de assinar. Ao assinar, você concorda com todo o conteúdo do
                  documento — este é o passo final e não pode ser desfeito.
                </p>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button className="btn btn-primary" onClick={() => setModo('ASSINAR')}>Assinar eletronicamente</button>
                  <button className="btn btn-danger" onClick={() => setModo('RECUSAR')}>Recusar</button>
                </div>
              </>
            )}

            {modo === 'ASSINAR' && (
              <div style={{ marginTop: 12 }}>
                <div className="field-grid" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                  <div className="field">
                    <label>Nome completo *</label>
                    <input value={nome} onChange={(e) => setNome(e.target.value)} placeholder="Seu nome completo" />
                  </div>
                  <div className="field">
                    <label>CPF *</label>
                    <input value={documento} onChange={(e) => setDocumento(e.target.value)} placeholder="000.000.000-00" />
                  </div>
                </div>
                <label style={{ display: 'flex', gap: 8, alignItems: 'flex-start', marginTop: 16, fontSize: '0.85rem' }}>
                  <input type="checkbox" checked={declaracao} onChange={(e) => setDeclaracao(e.target.checked)} style={{ marginTop: 3 }} />
                  <span>Declaro que sou eu quem está assinando e que concordo com todo o conteúdo do documento.</span>
                </label>
                <p style={{ fontSize: '0.75rem', color: 'var(--text-muted)', marginTop: 10 }}>
                  Esta é uma assinatura eletrônica simples — evidenciada pelo link único enviado ao seu e-mail
                  cadastrado, endereço IP e data/hora da confirmação. Não é uma assinatura ICP-Brasil qualificada.
                </p>
                <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
                  <button className="btn btn-primary" disabled={busy} onClick={handleAssinar}>Confirmar assinatura</button>
                  <button className="btn btn-secondary" disabled={busy} onClick={() => setModo(null)}>Cancelar</button>
                </div>
              </div>
            )}

            {modo === 'RECUSAR' && (
              <div style={{ marginTop: 12 }}>
                <div className="field">
                  <label>Motivo da recusa *</label>
                  <input value={motivoRecusa} onChange={(e) => setMotivoRecusa(e.target.value)} placeholder="Explique o motivo…" />
                </div>
                <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
                  <button className="btn btn-danger" disabled={busy} onClick={handleRecusar}>Confirmar recusa</button>
                  <button className="btn btn-secondary" disabled={busy} onClick={() => setModo(null)}>Cancelar</button>
                </div>
              </div>
            )}

            {resultado && (
              <p style={{ marginTop: 12, fontSize: '0.85rem', color: 'var(--text-muted)' }}>
                Sua resposta foi registrada com sucesso.
              </p>
            )}
          </div>
        </div>

        <div style={{ padding: '16px 32px', borderTop: '1px solid var(--border)', fontSize: '0.78rem', color: 'var(--text-muted)', display: 'flex', justifyContent: 'space-between' }}>
          <span>OptiMon — assinatura eletrônica</span>
          <span>{docLabel} {info.proposta_numero || info.contrato_numero || ''}</span>
        </div>
      </div>
    </div>
  );
}
