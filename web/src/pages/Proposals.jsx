import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../lib/api';
import { formatCurrencyFull } from '../components/charts/chartUtils';

const STATUS_CLASS = {
  RASCUNHO: 'status-discount',
  EM_APROVACAO: 'status-director',
  APROVADA: 'status-allow',
  ENVIADA: 'status-allow',
  EM_NEGOCIACAO: 'status-director',
  ACEITA: 'status-allow',
  RECUSADA: 'status-block',
  EXPIRADA: 'status-block',
  CANCELADA: 'status-block',
};

const STATUS_LABELS = {
  RASCUNHO: 'Rascunho', EM_APROVACAO: 'Em Aprovação', APROVADA: 'Aprovada', ENVIADA: 'Enviada',
  EM_NEGOCIACAO: 'Em Negociação', ACEITA: 'Aceita', RECUSADA: 'Recusada', EXPIRADA: 'Expirada', CANCELADA: 'Cancelada',
};

export default function Proposals() {
  const [proposals, setProposals] = useState(null);
  const [error, setError] = useState(null);
  const [statusFiltro, setStatusFiltro] = useState('');

  useEffect(() => {
    setProposals(null);
    api.proposals.list(statusFiltro ? { status: statusFiltro } : {}).then(setProposals).catch((err) => setError(err.message));
  }, [statusFiltro]);

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;

  return (
    <div className="page">
      <div className="page-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h1>Propostas Comerciais</h1>
          <p>Histórico de propostas geradas — cada versão fica preservada, nunca sobrescrita.</p>
        </div>
        <div className="field" style={{ minWidth: 220 }}>
          <label>Filtrar por status</label>
          <select value={statusFiltro} onChange={(e) => setStatusFiltro(e.target.value)}>
            <option value="">Todos</option>
            {Object.keys(STATUS_LABELS).map((s) => <option key={s} value={s}>{STATUS_LABELS[s]}</option>)}
          </select>
        </div>
      </div>

      {!proposals ? (
        <div className="card"><div className="spinner" /></div>
      ) : proposals.length === 0 ? (
        <div className="card"><div className="empty-state">Nenhuma proposta encontrada. Crie uma em "Nova Simulação".</div></div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Número</th>
                  <th>Versão</th>
                  <th>Status</th>
                  <th>Cidade</th>
                  <th>Parceiro</th>
                  <th className="num">Preço proposto</th>
                  <th className="num">Total a pagar</th>
                  <th>Criado em</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {proposals.map((p) => (
                  <tr key={p.id}>
                    <td style={{ fontFamily: 'var(--font-mono)' }}>{p.numero}</td>
                    <td>V{p.numero_versao || 1}</td>
                    <td><span className={`badge ${STATUS_CLASS[p.status] || ''}`}>{STATUS_LABELS[p.status] || p.status}</span></td>
                    <td>{p.cidade_nome} — {p.cidade_uf}</td>
                    <td>{p.parceiro_nome_capa || p.parceiro_nome_fantasia || p.parceiro_razao_social || '—'}</td>
                    <td className="num">{formatCurrencyFull(p.snapshot?.preco_proposto)}</td>
                    <td className="num">{formatCurrencyFull(p.snapshot?.total_payable)}</td>
                    <td>{new Date(p.criado_em).toLocaleString('pt-BR')}</td>
                    <td><Link className="link-tab" to={`/propostas/${p.id}`}>Detalhe →</Link></td>
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
