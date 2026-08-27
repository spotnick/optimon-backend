import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { api, ApiError } from '../lib/api';

const TIPOS_ADITIVO = ['INCLUSAO_FIBRA', 'INCLUSAO_PORTA', 'EXCLUSAO_FIBRA', 'EXCLUSAO_PORTA', 'ALTERACAO_PRAZO', 'ALTERACAO_COMERCIAL', 'ALTERACAO_CAPACIDADE', 'ALTERACAO_EXCLUSIVIDADE', 'ALTERACAO_REGRAS_COBRANCA', 'OUTRO'];

export default function ContractDetail() {
  const { id } = useParams();
  const [contract, setContract] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState(null);
  const [actionMsg, setActionMsg] = useState(null);

  const [showAditivoForm, setShowAditivoForm] = useState(false);
  const [aditivoForm, setAditivoForm] = useState({ numero: '', tipo: TIPOS_ADITIVO[0], descricao: '' });

  const [showReajuste, setShowReajuste] = useState(false);
  const [reajustePercentual, setReajustePercentual] = useState('');

  function load() {
    api.contracts.get(id).then(setContract).catch((err) => setError(err.message));
  }
  useEffect(load, [id]);

  async function handleActivate() {
    setActionError(null); setActionMsg(null); setBusy(true);
    try {
      await api.contracts.activate(id);
      setActionMsg('Contrato ativado com sucesso.');
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleCreateAditivo(e) {
    e.preventDefault();
    setActionError(null); setBusy(true);
    try {
      await api.contracts.createAditivo(id, { ...aditivoForm, numero: Number(aditivoForm.numero) });
      setAditivoForm({ numero: '', tipo: TIPOS_ADITIVO[0], descricao: '' });
      setShowAditivoForm(false);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleAditivoStatus(aditivoId, status) {
    setActionError(null); setBusy(true);
    try {
      await api.contracts.updateAditivo(id, aditivoId, { status });
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleActivateAditivo(aditivoId) {
    setActionError(null); setBusy(true);
    try {
      await api.contracts.activateAditivo(id, aditivoId);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleReajuste(e) {
    e.preventDefault();
    setActionError(null); setBusy(true);
    try {
      await api.contracts.reajuste(id, { percentual: Number(reajustePercentual) });
      setActionMsg('Reajuste aplicado — novo evento registrado, valores históricos preservados.');
      setReajustePercentual('');
      setShowReajuste(false);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;
  if (!contract) return <div className="page"><div className="card"><div className="spinner" /></div></div>;

  return (
    <div className="page">
      <div className="page-header">
        <h1>Contrato {contract.numero}</h1>
        <p>Status: <span className="badge">{contract.status}</span> — versão atual V{contract.versao_atual}</p>
      </div>

      {actionError && <div className="error-banner">{actionError}</div>}
      {actionMsg && <div className="card" style={{ background: '#eaf7ee', marginBottom: 16 }}>{actionMsg}</div>}

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8, marginBottom: 12 }}>
          <div><strong>Proponente:</strong> {contract.parceiros?.nome_fantasia || contract.parceiros?.razao_social}</div>
          <div><strong>CNPJ:</strong> {contract.parceiros?.cnpj}</div>
          <div><strong>Cidade:</strong> {contract.cidades_infra?.nome}/{contract.cidades_infra?.uf}</div>
          <div><strong>Prazo:</strong> {contract.prazo_meses} meses{contract.prazo_minimo_excecao ? ' (exceção ao mínimo de 48m)' : ''}</div>
          <div><strong>Início:</strong> {contract.data_inicio || '—'}</div>
          <div><strong>Fim previsto:</strong> {contract.data_fim_prevista || '—'}</div>
        </div>
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
          <button className="btn btn-primary" disabled={busy || contract.status === 'ATIVO'} onClick={handleActivate}>Ativar contrato</button>
          <button className="btn btn-secondary" disabled={busy} onClick={() => setShowReajuste((s) => !s)}>{showReajuste ? 'Cancelar' : 'Aplicar reajuste'}</button>
        </div>
        {showReajuste && (
          <form onSubmit={handleReajuste} style={{ marginTop: 12, display: 'flex', gap: 12, alignItems: 'flex-end' }}>
            <div className="field"><label>Percentual (ex.: 0.045 = 4,5%)</label><input required type="number" step="0.00001" value={reajustePercentual} onChange={(e) => setReajustePercentual(e.target.value)} /></div>
            <button type="submit" className="btn btn-primary" disabled={busy}>Aplicar</button>
          </form>
        )}
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <h3 style={{ marginTop: 0 }}>Infraestrutura alocada (comprometida)</h3>
        {(contract.fibras_alocadas || []).length === 0 ? (
          <div className="empty-state">Nenhuma fibra/porta PON alocada ainda — alocação é sempre um passo manual de Engenharia (contrato_fibras), nunca automático.</div>
        ) : (
          <table>
            <thead><tr><th>Fibra</th><th>Porta PON</th><th>Vinculado em</th></tr></thead>
            <tbody>
              {contract.fibras_alocadas.map((f) => (
                <tr key={f.id}><td>{f.fibra_id}</td><td>{f.porta_pon_id || '—'}</td><td>{new Date(f.vinculado_em).toLocaleString('pt-BR')}</td></tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h3 style={{ margin: 0 }}>Aditivos (RASCUNHO → EM_APROVACAO → APROVADO → ASSINATURA → ATIVO)</h3>
          <button className="btn btn-secondary" onClick={() => setShowAditivoForm((s) => !s)}>{showAditivoForm ? 'Cancelar' : '+ Novo aditivo'}</button>
        </div>
        {showAditivoForm && (
          <form onSubmit={handleCreateAditivo} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12, margin: '12px 0' }}>
            <div className="field"><label>Número *</label><input required type="number" min="1" value={aditivoForm.numero} onChange={(e) => setAditivoForm({ ...aditivoForm, numero: e.target.value })} /></div>
            <div className="field">
              <label>Tipo *</label>
              <select value={aditivoForm.tipo} onChange={(e) => setAditivoForm({ ...aditivoForm, tipo: e.target.value })}>
                {TIPOS_ADITIVO.map((t) => <option key={t} value={t}>{t}</option>)}
              </select>
            </div>
            <div className="field"><label>Descrição *</label><input required value={aditivoForm.descricao} onChange={(e) => setAditivoForm({ ...aditivoForm, descricao: e.target.value })} /></div>
            <div style={{ gridColumn: 'span 3' }}><button type="submit" className="btn btn-primary" disabled={busy}>Criar aditivo</button></div>
          </form>
        )}
        {(contract.aditivos || []).length === 0 ? (
          <div className="empty-state">Nenhum aditivo criado ainda.</div>
        ) : (
          <table>
            <thead><tr><th>Nº</th><th>Tipo</th><th>Descrição</th><th>Status</th><th>Ações</th></tr></thead>
            <tbody>
              {contract.aditivos.map((a) => (
                <tr key={a.id}>
                  <td>{a.numero}</td><td>{a.tipo}</td><td>{a.descricao}</td>
                  <td><span className="badge">{a.status}</span></td>
                  <td style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                    {a.status === 'RASCUNHO' && <button className="btn btn-secondary" disabled={busy} onClick={() => handleAditivoStatus(a.id, 'EM_APROVACAO')}>Enviar p/ aprovação</button>}
                    {a.status === 'EM_APROVACAO' && <button className="btn btn-primary" disabled={busy} onClick={() => handleAditivoStatus(a.id, 'APROVADO')}>Aprovar</button>}
                    {a.status === 'EM_APROVACAO' && <button className="btn btn-danger" disabled={busy} onClick={() => handleAditivoStatus(a.id, 'REJEITADO')}>Rejeitar</button>}
                    {a.status === 'ASSINATURA' && <button className="btn btn-primary" disabled={busy} onClick={() => handleActivateAditivo(a.id)}>Ativar (após assinatura validada)</button>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <p style={{ color: 'var(--text-muted, #666)', marginTop: 12 }}>
          Aditivo APROVADO precisa de um envelope de assinatura (criado em Assinaturas, tipo ADITIVO) antes de poder ser ativado.
        </p>
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Reajustes (histórico — nunca reescrito)</h3>
        {(contract.reajustes || []).length === 0 ? (
          <div className="empty-state">Nenhum reajuste aplicado ainda.</div>
        ) : (
          <table>
            <thead><tr><th>Competência</th><th>Percentual</th><th>Status</th><th>Aplicado em</th></tr></thead>
            <tbody>
              {contract.reajustes.map((r) => (
                <tr key={r.id}><td>{r.competencia_base}</td><td>{(r.percentual_aplicado * 100).toFixed(3)}%</td><td>{r.status}</td><td>{new Date(r.aplicado_em).toLocaleString('pt-BR')}</td></tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
