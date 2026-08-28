import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../lib/api';
import { formatCurrencyFull } from '../components/charts/chartUtils';

const FILTROS = ['TODOS', 'ATIVOS', 'EM_ASSINATURA', 'EXPIRANDO', 'EXPIRADOS', 'CANCELADOS', 'SUSPENSOS'];
const STATUS_CLASS = { RASCUNHO: 'status-discount', EM_APROVACAO: 'status-director', ATIVO: 'status-allow', SUSPENSO: 'status-director', ENCERRADO: 'status-block', RESCINDIDO: 'status-block' };

export default function Contracts() {
  const [contracts, setContracts] = useState(null);
  const [dashboard, setDashboard] = useState(null);
  const [error, setError] = useState(null);
  const [filtro, setFiltro] = useState('TODOS');

  useEffect(() => {
    setContracts(null);
    api.contracts.list(filtro).then(setContracts).catch((err) => setError(err.message));
  }, [filtro]);

  useEffect(() => { api.contracts.dashboard().then(setDashboard).catch(() => {}); }, []);

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;

  return (
    <div className="page">
      <div className="page-header">
        <h1>Contratos</h1>
        <p>Ciclo completo proposta → contrato → assinatura eletrônica (política ICP-Brasil configurada, provedor real ainda não integrado) → ativação — infraestrutura só é comprometida após assinatura validada.</p>
      </div>

      {dashboard && (
        <div className="card" style={{ marginBottom: 16, display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16 }}>
          <div><div style={{ fontSize: 12, color: 'var(--text-muted, #666)' }}>Contratos ativos</div><div style={{ fontSize: 24, fontWeight: 700 }}>{dashboard.contratos_ativos}</div></div>
          <div><div style={{ fontSize: 12, color: 'var(--text-muted, #666)' }}>Propostas aguardando aprovação</div><div style={{ fontSize: 24, fontWeight: 700 }}>{dashboard.propostas_aguardando_aprovacao}</div></div>
          <div><div style={{ fontSize: 12, color: 'var(--text-muted, #666)' }}>Contratos aguardando assinatura</div><div style={{ fontSize: 24, fontWeight: 700 }}>{dashboard.contratos_aguardando_assinatura}</div></div>
          <div><div style={{ fontSize: 12, color: 'var(--text-muted, #666)' }}>Próximos do vencimento (60d)</div><div style={{ fontSize: 24, fontWeight: 700 }}>{dashboard.contratos_proximos_vencimento}</div></div>
          <div><div style={{ fontSize: 12, color: 'var(--text-muted, #666)' }}>Valor mensal contratado</div><div style={{ fontSize: 24, fontWeight: 700 }}>{formatCurrencyFull(dashboard.valor_mensal_contratado)}</div></div>
          <div><div style={{ fontSize: 12, color: 'var(--text-muted, #666)' }}>PONs locadas</div><div style={{ fontSize: 24, fontWeight: 700 }}>{dashboard.pons_locadas}</div></div>
          <div><div style={{ fontSize: 12, color: 'var(--text-muted, #666)' }}>Fibras locadas</div><div style={{ fontSize: 24, fontWeight: 700 }}>{dashboard.fibras_locadas}</div></div>
          <div><div style={{ fontSize: 12, color: 'var(--text-muted, #666)' }}>Alertas não resolvidos</div><div style={{ fontSize: 24, fontWeight: 700 }}><Link className="link-tab" to="/alertas">{dashboard.alertas_nao_resolvidos} →</Link></div></div>
        </div>
      )}

      <div style={{ display: 'flex', gap: 8, marginBottom: 12, flexWrap: 'wrap' }}>
        {FILTROS.map((f) => (
          <button key={f} className={`btn ${filtro === f ? 'btn-primary' : 'btn-secondary'}`} onClick={() => setFiltro(f)}>{f.replace('_', ' ')}</button>
        ))}
      </div>

      {!contracts ? (
        <div className="card"><div className="spinner" /></div>
      ) : contracts.length === 0 ? (
        <div className="card"><div className="empty-state">Nenhum contrato encontrado para este filtro.</div></div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <div className="table-scroll">
            <table>
              <thead><tr><th>Número</th><th>Status</th><th>Proponente</th><th>Cidade</th><th>Prazo</th><th>Fim previsto</th><th>Em assinatura?</th><th></th></tr></thead>
              <tbody>
                {contracts.map((c) => (
                  <tr key={c.id}>
                    <td style={{ fontFamily: 'var(--font-mono)' }}>{c.numero}</td>
                    <td><span className={`badge ${STATUS_CLASS[c.status] || ''}`}>{c.status}</span></td>
                    <td>{c.parceiro_nome}</td>
                    <td>{c.cidade_nome}</td>
                    <td>{c.prazo_meses}m</td>
                    <td>{c.data_fim_prevista || '—'}</td>
                    <td>{c.em_assinatura ? <span className="badge status-director">Sim</span> : '—'}</td>
                    <td><Link className="link-tab" to={`/contratos/${c.id}`}>Detalhe →</Link></td>
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
