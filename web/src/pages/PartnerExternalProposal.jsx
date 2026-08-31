// OptiMon — Fase 3.11 (seções 5-9): área externa REAL do parceiro. Página pública,
// SEM login, alcançada por /parceiro/proposta/:token (fora de <ProtectedRoute>, ver
// App.jsx — mesmo padrão de /definir-senha). Nunca chama api.proposals.* (essas rotas
// exigem JWT de usuário da NICK) — usa exclusivamente api.proposalsExternal.*, que fala
// com as 3 rotas anônimas (api/routes/proposalsExternal.js -> RPCs SECURITY DEFINER
// grant para `anon`). O backend já devolve só os campos comerciais liberados (nunca
// piso/margem/desconto máximo/governança/custo interno/auditoria) — esta tela nunca
// precisa (e nunca deve) filtrar nada aqui, só exibir o que veio.

import { useCallback, useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { api, ApiError } from '../lib/api';
import { formatCurrencyFull } from '../components/charts/chartUtils';

export default function PartnerExternalProposal() {
  const { token } = useParams();
  const [proposta, setProposta] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [modoForm, setModoForm] = useState(null); // null | 'ACEITAR' | 'RECUSAR'
  const [form, setForm] = useState({ nome: '', documento: '', cargo: '', email: '', telefone: '' });
  const [declaracao, setDeclaracao] = useState(false);
  const [confirmacao, setConfirmacao] = useState(false);
  const [motivoRecusa, setMotivoRecusa] = useState('');
  const [confirmado, setConfirmado] = useState(null); // 'ACEITA' | 'RECUSADA'
  // Fase 3.11.2 (seção 1, itens 5-11): aceite agora exige confirmação por código (OTP)
  // enviado ao e-mail informado — nenhum aceite é registrado sem essa segunda etapa.
  const [etapaOtp, setEtapaOtp] = useState(null); // null | { tentativaId, expiraEm, emailMascarado }
  const [otpInput, setOtpInput] = useState('');

  const load = useCallback(() => {
    setError(null);
    api.proposalsExternal.get(token).then(setProposta).catch((err) => setError(err.message));
  }, [token]);

  useEffect(() => { load(); }, [load]);

  async function handleSolicitarOtp() {
    if (!form.nome || !form.documento || !form.email) {
      setError('Nome completo, CPF e e-mail são obrigatórios.');
      return;
    }
    if (!declaracao) {
      setError('É necessário declarar que você é representante autorizado da empresa e possui poderes para manifestar o aceite.');
      return;
    }
    if (!confirmacao) {
      setError('É necessário confirmar o aceite e autorizar o prosseguimento para elaboração do contrato.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const resp = await api.proposalsExternal.acceptIniciar(token, { ...form, declaracao, confirmacao });
      setEtapaOtp({ tentativaId: resp.tentativa_id, expiraEm: resp.expira_em, emailMascarado: resp.email_mascarado });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao solicitar código de confirmação.');
    } finally {
      setBusy(false);
    }
  }

  async function handleConfirmarOtp() {
    if (!otpInput || otpInput.trim().length !== 6) {
      setError('Informe o código de 6 dígitos recebido.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await api.proposalsExternal.acceptConfirmar(token, { tentativa_id: etapaOtp.tentativaId, otp: otpInput.trim() });
      setConfirmado('ACEITA');
      setModoForm(null);
      setEtapaOtp(null);
      setOtpInput('');
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao confirmar código.');
    } finally {
      setBusy(false);
    }
  }

  function handleReiniciarAceite() {
    setEtapaOtp(null);
    setOtpInput('');
    setError(null);
  }

  async function handleRecusar() {
    if (!motivoRecusa) {
      setError('Informe o motivo da recusa.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await api.proposalsExternal.decline(token, { motivo: motivoRecusa });
      setConfirmado('RECUSADA');
      setModoForm(null);
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao registrar recusa.');
    } finally {
      setBusy(false);
    }
  }

  if (error && !proposta) {
    return (
      <div style={{ maxWidth: 560, margin: '80px auto', padding: 24, textAlign: 'center' }}>
        <img src="/branding/optimon-logo-lockup.png" alt="OptiMon" style={{ height: 40, marginBottom: 24 }} />
        <div className="error-banner">{error}</div>
        <p style={{ color: 'var(--text-muted)', marginTop: 12 }}>
          Este link pode ter expirado, ter sido cancelado, ou o endereço pode estar incorreto. Entre em contato
          com o consultor comercial da OptiMon responsável por esta proposta.
        </p>
      </div>
    );
  }
  if (!proposta) return <div className="page"><div className="spinner" /></div>;

  const jaAceita = proposta.ja_aceita || proposta.status === 'ACEITA_PELO_PARCEIRO';
  const jaRecusada = proposta.ja_recusada || proposta.status === 'RECUSADA_PELO_PARCEIRO';
  const podeDecidir = !jaAceita && !jaRecusada;

  return (
    <div style={{ maxWidth: 820, margin: '0 auto', padding: '32px 20px 80px' }}>
      <div className="card" style={{ marginBottom: 24, padding: 0, overflow: 'hidden', background: '#fff' }}>
        <div style={{ padding: '28px 32px', borderBottom: '1px solid var(--border)', display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 16 }}>
          <img src="/branding/optimon-logo-lockup.png" alt="OptiMon" style={{ height: 40 }} />
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontSize: '0.75rem', letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--text-muted)' }}>Proposta Comercial</div>
            <div style={{ fontSize: '1.1rem', fontWeight: 700 }}>{proposta.numero} <span style={{ fontWeight: 400, fontSize: '0.8rem', color: 'var(--text-muted)' }}>V{proposta.numero_versao || 1}</span></div>
          </div>
        </div>

        <div style={{ padding: '28px 32px' }}>
          {error && <div className="error-banner" style={{ marginBottom: 16 }}>{error}</div>}

          <div className="card-grid" style={{ marginBottom: 24 }}>
            <div className="card kpi-card">
              <div className="kpi-label">Parceiro</div>
              <div className="kpi-value" style={{ fontSize: '1.1rem' }}>{proposta.parceiro_nome_capa || '—'}</div>
              {proposta.parceiro_cargo_contato && <div className="kpi-sub">{proposta.parceiro_cargo_contato}</div>}
            </div>
            <div className="card kpi-card">
              <div className="kpi-label">Cidade</div>
              <div className="kpi-value" style={{ fontSize: '1.1rem' }}>{proposta.cidade_nome} — {proposta.cidade_uf}</div>
              {proposta.pop_nome && <div className="kpi-sub">POP: {proposta.pop_nome}</div>}
            </div>
            <div className="card kpi-card">
              <div className="kpi-label">Prazo contratual</div>
              <div className="kpi-value" style={{ fontSize: '1.1rem' }}>{proposta.prazo_meses ? `${proposta.prazo_meses} meses` : '—'}</div>
            </div>
            <div className="card kpi-card">
              <div className="kpi-label">Validade da proposta</div>
              <div className="kpi-value" style={{ fontSize: '1.1rem' }}>{proposta.validade_dias} dias</div>
            </div>
          </div>

          <h2 className="section-title">Condições comerciais</h2>
          <div className="card-grid" style={{ marginBottom: 24 }}>
            <div className="card kpi-card">
              <div className="kpi-label">Mensalidade proposta</div>
              <div className="kpi-value" style={{ fontSize: '1.3rem', color: 'var(--accent, #0e6e55)' }}>{formatCurrencyFull(proposta.preco_proposto)}</div>
            </div>
            {proposta.revenue_share_pct != null && (
              <div className="card kpi-card">
                <div className="kpi-label">Revenue share</div>
                <div className="kpi-value">{(Number(proposta.revenue_share_pct) * 100).toFixed(1)}%</div>
              </div>
            )}
            <div className="card kpi-card">
              <div className="kpi-label">Faturamento mensal estimado</div>
              <div className="kpi-value">{formatCurrencyFull(proposta.faturamento)}</div>
            </div>
            {proposta.pons_count != null && (
              <div className="card kpi-card">
                <div className="kpi-label">Porta(s) PON</div>
                <div className="kpi-value">{proposta.pons_count}</div>
              </div>
            )}
          </div>

          {(proposta.observacoes_comerciais || proposta.proximos_passos) && (
            <>
              <h2 className="section-title">Observações e próximos passos</h2>
              <div className="card-grid" style={{ marginBottom: 24, gridTemplateColumns: '1fr 1fr' }}>
                {proposta.observacoes_comerciais && (
                  <div className="card">
                    <div className="kpi-label" style={{ marginBottom: 8 }}>Observações comerciais</div>
                    <p style={{ margin: 0, whiteSpace: 'pre-wrap' }}>{proposta.observacoes_comerciais}</p>
                  </div>
                )}
                {proposta.proximos_passos && (
                  <div className="card">
                    <div className="kpi-label" style={{ marginBottom: 8 }}>Próximos passos</div>
                    <p style={{ margin: 0, whiteSpace: 'pre-wrap' }}>{proposta.proximos_passos}</p>
                  </div>
                )}
              </div>
            </>
          )}

          <div className="card" style={{ background: 'var(--surface, #f7f8f9)' }}>
            <h2 className="section-title" style={{ marginBottom: 8 }}>Aceite da proposta</h2>

            {jaAceita && (
              <div style={{ padding: 10, borderRadius: 6, background: 'rgba(14,110,85,0.1)' }}>
                <strong>✓ Proposta aceita.</strong> Obrigado — em breve nosso time comercial entrará em contato
                para os próximos passos (geração do contrato e assinatura eletrônica).
                {proposta.aceite_em && <div style={{ fontSize: '0.85rem', marginTop: 4 }}>Confirmado em {new Date(proposta.aceite_em).toLocaleString('pt-BR')}.</div>}
              </div>
            )}
            {jaRecusada && (
              <div style={{ padding: 10, borderRadius: 6, background: 'rgba(180,40,40,0.1)' }}>
                <strong>Proposta recusada.</strong>
                {proposta.recusa_em && <div style={{ fontSize: '0.85rem', marginTop: 4 }}>Registrado em {new Date(proposta.recusa_em).toLocaleString('pt-BR')}.</div>}
              </div>
            )}

            {podeDecidir && !modoForm && (
              <>
                <p style={{ margin: '0 0 12px' }}>
                  Esta proposta é válida por {proposta.validade_dias} dias a partir de {new Date(proposta.criado_em).toLocaleDateString('pt-BR')}.
                  Ao aceitar, você confirma o interesse comercial nas condições acima — o próximo passo será a
                  geração do contrato e o envio para assinatura eletrônica.
                </p>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button className="btn btn-primary" onClick={() => setModoForm('ACEITAR')}>Aceitar proposta</button>
                  <button className="btn btn-danger" onClick={() => setModoForm('RECUSAR')}>Recusar proposta</button>
                </div>
              </>
            )}

            {modoForm === 'ACEITAR' && !etapaOtp && (
              <div style={{ marginTop: 12 }}>
                <div className="field-grid" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                  <div className="field">
                    <label>Nome completo do representante *</label>
                    <input value={form.nome} onChange={(e) => setForm((f) => ({ ...f, nome: e.target.value }))} placeholder="Seu nome completo" />
                  </div>
                  <div className="field">
                    <label>CPF *</label>
                    <input value={form.documento} onChange={(e) => setForm((f) => ({ ...f, documento: e.target.value }))} placeholder="000.000.000-00" />
                  </div>
                  <div className="field">
                    <label>Cargo/função</label>
                    <input value={form.cargo} onChange={(e) => setForm((f) => ({ ...f, cargo: e.target.value }))} placeholder="Ex.: Diretor" />
                  </div>
                  <div className="field">
                    <label>E-mail *</label>
                    <input required type="email" value={form.email} onChange={(e) => setForm((f) => ({ ...f, email: e.target.value }))} placeholder="voce@empresa.com.br" />
                  </div>
                  <div className="field">
                    <label>Telefone</label>
                    <input value={form.telefone} onChange={(e) => setForm((f) => ({ ...f, telefone: e.target.value }))} placeholder="(00) 00000-0000" />
                  </div>
                </div>

                <label style={{ display: 'flex', gap: 8, alignItems: 'flex-start', marginTop: 16, fontSize: '0.85rem' }}>
                  <input type="checkbox" checked={declaracao} onChange={(e) => setDeclaracao(e.target.checked)} style={{ marginTop: 3 }} />
                  <span>Declaro que sou representante autorizado da empresa e que possuo poderes para manifestar o aceite desta proposta.</span>
                </label>
                <label style={{ display: 'flex', gap: 8, alignItems: 'flex-start', marginTop: 10, fontSize: '0.85rem' }}>
                  <input type="checkbox" checked={confirmacao} onChange={(e) => setConfirmacao(e.target.checked)} style={{ marginTop: 3 }} />
                  <span>Confirmo o aceite desta proposta e autorizo o prosseguimento para elaboração do contrato.</span>
                </label>

                <p style={{ fontSize: '0.78rem', color: 'var(--text-muted)', marginTop: 10 }}>
                  Ao continuar, enviaremos um código de confirmação de 6 dígitos para o e-mail informado acima —
                  o aceite só é registrado depois de você confirmar esse código.
                </p>

                <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
                  <button className="btn btn-primary" disabled={busy} onClick={handleSolicitarOtp}>Enviar código de confirmação</button>
                  <button className="btn btn-secondary" disabled={busy} onClick={() => setModoForm(null)}>Cancelar</button>
                </div>
              </div>
            )}

            {modoForm === 'ACEITAR' && etapaOtp && (
              <div style={{ marginTop: 12 }}>
                <p style={{ margin: '0 0 12px' }}>
                  Enviamos um código de 6 dígitos para <strong>{etapaOtp.emailMascarado}</strong>. Informe-o abaixo para
                  confirmar o aceite. O código expira em {new Date(etapaOtp.expiraEm).toLocaleTimeString('pt-BR')}.
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
                <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
                  <button className="btn btn-primary" disabled={busy} onClick={handleConfirmarOtp}>Confirmar aceite</button>
                  <button className="btn btn-secondary" disabled={busy} onClick={handleReiniciarAceite}>Não recebi — solicitar novo código</button>
                  <button className="btn btn-secondary" disabled={busy} onClick={() => { setModoForm(null); handleReiniciarAceite(); }}>Cancelar</button>
                </div>
              </div>
            )}

            {modoForm === 'RECUSAR' && (
              <div style={{ marginTop: 12 }}>
                <div className="field">
                  <label>Motivo da recusa *</label>
                  <input value={motivoRecusa} onChange={(e) => setMotivoRecusa(e.target.value)} placeholder="Explique o motivo…" />
                </div>
                <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
                  <button className="btn btn-danger" disabled={busy} onClick={handleRecusar}>Confirmar recusa</button>
                  <button className="btn btn-secondary" disabled={busy} onClick={() => setModoForm(null)}>Cancelar</button>
                </div>
              </div>
            )}

            {confirmado && (
              <p style={{ marginTop: 12, fontSize: '0.85rem', color: 'var(--text-muted)' }}>
                Sua resposta foi registrada com sucesso.
              </p>
            )}
          </div>
        </div>

        <div style={{ padding: '16px 32px', borderTop: '1px solid var(--border)', fontSize: '0.78rem', color: 'var(--text-muted)', display: 'flex', justifyContent: 'space-between' }}>
          <span>OptiMon — proposta comercial</span>
          <span>{proposta.numero} · V{proposta.numero_versao || 1}</span>
        </div>
      </div>
    </div>
  );
}
