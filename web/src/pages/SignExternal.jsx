// OptiMon — Fase 3.11.4 (seções 12-13): área externa REAL do signatário. Página
// pública, SEM login, alcançada por /assinar/:token (fora de <ProtectedRoute>, ver
// App.jsx — mesmo padrão de /parceiro/proposta/:token). Nunca chama api.signatures.*
// (exige JWT de usuário da NICK) — usa exclusivamente api.signaturesExternal.*, que fala
// com as rotas anônimas (api/routes/signaturesExternal.js -> RPCs SECURITY DEFINER
// grant para `anon`).
//
// Fase 3.11.5 (correções de 4 problemas reais reportados pelo usuário testando em
// produção o fluxo de ponta a ponta):
//   1. "Revisar documento (PDF)" 404 — corrigido no backend (RLS bloqueava a leitura
//      anônima do caminho do arquivo); esta tela não precisou mudar para o item 1.
//   2. CPF sem validação — agora validado em tempo real (mesmo algoritmo do banco,
//      ver web/src/lib/cpf.js) antes de liberar o botão de assinar.
//   3. Assinar virou 2 passos — código de confirmação (OTP) de 6 dígitos por e-mail,
//      mirror exato de PartnerExternalProposal.jsx (Fase 3.11.2).
//   4. Depois de ASSINADO, um botão novo abre o PDF final com a página de certificado
//      de assinatura (nunca o mesmo link do documento original).

import { useCallback, useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { api, ApiError } from '../lib/api';
import { isValidCpf, formatCpf } from '../lib/cpf';

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
  // Fase 3.11.5 (item 3): confirmação por código (OTP) enviado ao e-mail cadastrado —
  // nenhuma assinatura é gravada sem essa segunda etapa.
  const [etapaOtp, setEtapaOtp] = useState(null); // null | { tentativaId, expiraEm, emailMascarado }
  const [otpInput, setOtpInput] = useState('');

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

  // Fase 3.11.5 (item 4): PDF final com a página de certificado de assinatura — só
  // aparece depois que info.documento_assinado_disponivel vier true (nunca antes de
  // existir de fato).
  async function handleVerDocumentoAssinado() {
    try {
      const { url } = await api.signaturesExternal.documentoAssinado(token);
      window.open(url, '_blank', 'noopener');
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'PDF final assinado ainda não disponível — tente novamente em instantes.');
    }
  }

  const cpfDigitado = documento.trim().length > 0;
  const cpfValido = !cpfDigitado || isValidCpf(documento);

  async function handleSolicitarOtp() {
    if (!nome.trim() || !documento.trim()) {
      setError('Nome completo e CPF são obrigatórios para confirmar a assinatura.');
      return;
    }
    if (!isValidCpf(documento)) {
      setError('CPF inválido — confira os números digitados.');
      return;
    }
    if (!declaracao) {
      setError('É necessário declarar que é você quem está assinando e que concorda com o conteúdo do documento.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const resp = await api.signaturesExternal.assinarIniciar(token, { nome: nome.trim(), documento: documento.trim(), declaracao: true });
      setEtapaOtp({ tentativaId: resp.tentativa_id, expiraEm: resp.expira_em, emailMascarado: resp.email_mascarado });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao solicitar código de confirmação.');
    } finally {
      setBusy(false);
    }
  }

  async function handleConfirmarOtp() {
    if (!otpInput || otpInput.trim().length !== 6) {
      setError('Informe o código de 6 dígitos recebido por e-mail.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await api.signaturesExternal.assinarConfirmar(token, { tentativa_id: etapaOtp.tentativaId, otp: otpInput.trim() });
      setResultado('ASSINADO');
      setModo(null);
      setEtapaOtp(null);
      setOtpInput('');
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao confirmar o código.');
    } finally {
      setBusy(false);
    }
  }

  function handleReiniciarAssinatura() {
    setEtapaOtp(null);
    setOtpInput('');
    setError(null);
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

          <div style={{ display: 'flex', gap: 8, marginBottom: 20, flexWrap: 'wrap' }}>
            <button className="btn btn-secondary" disabled={!info.documento_disponivel} onClick={handleVerDocumento}>
              {info.documento_disponivel ? 'Revisar documento (PDF)' : 'Documento indisponível'}
            </button>
            {jaAssinado && (
              <button className="btn btn-secondary" disabled={!info.documento_assinado_disponivel} onClick={handleVerDocumentoAssinado}>
                {info.documento_assinado_disponivel ? 'Ver PDF assinado (com certificado)' : 'Gerando PDF final assinado…'}
              </button>
            )}
          </div>

          <div className="card" style={{ background: 'var(--surface, #f7f8f9)' }}>
            <h2 className="section-title" style={{ marginBottom: 8 }}>Assinatura</h2>

            {jaAssinado && (
              <div style={{ padding: 10, borderRadius: 6, background: 'rgba(14,110,85,0.1)' }}>
                <strong>✓ Documento assinado.</strong> Obrigado — sua assinatura eletrônica foi registrada com sucesso.
                {!info.documento_assinado_disponivel && (
                  <p style={{ margin: '6px 0 0', fontSize: '0.8rem' }}>
                    O PDF final com o certificado de assinatura está sendo gerado — atualize esta página em alguns
                    instantes para revisá-lo.
                  </p>
                )}
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

            {modo === 'ASSINAR' && !etapaOtp && (
              <div style={{ marginTop: 12 }}>
                <div className="field-grid" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                  <div className="field">
                    <label>Nome completo *</label>
                    <input value={nome} onChange={(e) => setNome(e.target.value)} placeholder="Seu nome completo" />
                  </div>
                  <div className="field">
                    <label>CPF *</label>
                    <input
                      value={documento}
                      onChange={(e) => setDocumento(formatCpf(e.target.value))}
                      placeholder="000.000.000-00"
                      inputMode="numeric"
                      maxLength={14}
                      style={!cpfValido ? { borderColor: 'var(--text-danger, #b42828)' } : undefined}
                    />
                    {!cpfValido && (
                      <p style={{ fontSize: '0.75rem', color: 'var(--text-danger, #b42828)', margin: '4px 0 0' }}>CPF inválido — confira os números digitados.</p>
                    )}
                  </div>
                </div>
                <label style={{ display: 'flex', gap: 8, alignItems: 'flex-start', marginTop: 16, fontSize: '0.85rem' }}>
                  <input type="checkbox" checked={declaracao} onChange={(e) => setDeclaracao(e.target.checked)} style={{ marginTop: 3 }} />
                  <span>Declaro que sou eu quem está assinando e que concordo com todo o conteúdo do documento.</span>
                </label>
                <p style={{ fontSize: '0.75rem', color: 'var(--text-muted)', marginTop: 10 }}>
                  Esta é uma assinatura eletrônica simples — evidenciada pelo link único enviado ao seu e-mail
                  cadastrado, por um código de confirmação de 6 dígitos enviado ao mesmo e-mail, endereço IP e
                  data/hora da confirmação. Não é uma assinatura ICP-Brasil qualificada.
                </p>
                <p style={{ fontSize: '0.78rem', color: 'var(--text-muted)', marginTop: 6 }}>
                  Ao continuar, enviaremos um código de confirmação de 6 dígitos para o seu e-mail cadastrado — a
                  assinatura só é registrada depois de você confirmar esse código.
                </p>
                <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
                  <button className="btn btn-primary" disabled={busy || !cpfValido} onClick={handleSolicitarOtp}>Enviar código de confirmação</button>
                  <button className="btn btn-secondary" disabled={busy} onClick={() => setModo(null)}>Cancelar</button>
                </div>
              </div>
            )}

            {modo === 'ASSINAR' && etapaOtp && (
              <div style={{ marginTop: 12 }}>
                <p style={{ margin: '0 0 12px' }}>
                  Enviamos um código de 6 dígitos para <strong>{etapaOtp.emailMascarado}</strong>. Informe-o abaixo para
                  confirmar a assinatura. O código expira em {new Date(etapaOtp.expiraEm).toLocaleTimeString('pt-BR')}.
                </p>
                <div className="field" style={{ maxWidth: 220 }}>
                  <label>Código de confirmação *</label>
                  <input
                    value={otpInput}
                    onChange={(e) => setOtpInput(e.target.value.replace(/\D/g, '').slice(0, 6))}
                    placeholder="000000"
                    inputMode="numeric"
                    maxLength={6}
                    style={{ letterSpacing: '0.3em', fontSize: '1.2rem', textAlign: 'center' }}
                  />
                </div>
                <div style={{ display: 'flex', gap: 8, marginTop: 12, flexWrap: 'wrap' }}>
                  <button className="btn btn-primary" disabled={busy} onClick={handleConfirmarOtp}>Confirmar assinatura</button>
                  <button className="btn btn-secondary" disabled={busy} onClick={handleReiniciarAssinatura}>Não recebi — solicitar novo código</button>
                  <button className="btn btn-secondary" disabled={busy} onClick={() => { setModo(null); handleReiniciarAssinatura(); }}>Cancelar</button>
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
