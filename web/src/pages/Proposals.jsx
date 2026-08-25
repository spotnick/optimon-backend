import { Fragment, useEffect, useState } from 'react';
import { api } from '../lib/api';
import { formatCurrencyFull } from '../components/charts/chartUtils';

const STATUS_CLASS = {
  RASCUNHO: 'status-discount',
  ENVIADA: 'status-director',
  APROVADA: 'status-allow',
  REJEITADA: 'status-block',
};

export default function Proposals() {
  const [proposals, setProposals] = useState(null);
  const [error, setError] = useState(null);
  const [expanded, setExpanded] = useState(null);

  useEffect(() => {
    api.proposals.list().then(setProposals).catch((err) => setError(err.message));
  }, []);

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;
  if (!proposals) return <div className="page"><div className="spinner" /></div>;

  return (
    <div className="page">
      <div className="page-header">
        <h1>Propostas Comerciais</h1>
        <p>Histórico de propostas geradas — snapshot imutável no momento da criação.</p>
      </div>

      {proposals.length === 0 ? (
        <div className="card"><div className="empty-state">Nenhuma proposta gerada ainda. Crie uma em "Nova Simulação".</div></div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Número</th>
                  <th>Status</th>
                  <th className="num">Preço proposto</th>
                  <th className="num">PONs</th>
                  <th className="num">Total a pagar</th>
                  <th>Criado em</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {proposals.map((p) => (
                  <Fragment key={p.id}>
                    <tr>
                      <td style={{ fontFamily: 'var(--font-mono)' }}>{p.numero}</td>
                      <td><span className={`badge ${STATUS_CLASS[p.status] || ''}`}>{p.status}</span></td>
                      <td className="num">{formatCurrencyFull(p.snapshot?.preco_proposto)}</td>
                      <td className="num">{p.snapshot?.pons_count ?? '—'}</td>
                      <td className="num">{formatCurrencyFull(p.snapshot?.total_payable)}</td>
                      <td>{new Date(p.criado_em).toLocaleString('pt-BR')}</td>
                      <td>
                        <button
                          className="link-tab"
                          style={{ background: 'none', border: 'none', cursor: 'pointer', fontSize: '0.82rem' }}
                          onClick={() => setExpanded(expanded === p.id ? null : p.id)}
                        >
                          {expanded === p.id ? 'Ocultar' : 'Detalhe'}
                        </button>
                      </td>
                    </tr>
                    {expanded === p.id && (
                      <tr>
                        <td colSpan={7} style={{ background: 'var(--bg)' }}>
                          <div className="card-grid" style={{ padding: '12px 0' }}>
                            <div><strong>PISO:</strong> {formatCurrencyFull(p.snapshot?.floor)}</div>
                            <div><strong>RECOMENDADO:</strong> {formatCurrencyFull(p.snapshot?.recommended)}</div>
                            <div><strong>ABERTURA:</strong> {formatCurrencyFull(p.snapshot?.opening)}</div>
                            <div><strong>Revenue Share:</strong> {formatCurrencyFull(p.snapshot?.revenue_share_value)}</div>
                            <div><strong>Receita do parceiro:</strong> {formatCurrencyFull(p.snapshot?.partner_revenue)}</div>
                            <div><strong>Carência:</strong> {p.snapshot?.carencia_meses ?? 0} meses</div>
                            <div><strong>Reajuste:</strong> {p.snapshot?.reajuste_indice ?? '—'}</div>
                            <div><strong>Governança:</strong> {p.snapshot?.governance_status?.por_papel ?? '—'}</div>
                          </div>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
