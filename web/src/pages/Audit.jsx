import { useEffect, useState } from 'react';
import { api } from '../lib/api';

const ACAO_CLASS = {
  LOGIN: 'status-director',
  INSERT: 'status-allow',
  UPDATE: 'status-discount',
  DELETE: 'status-block',
};

export default function Audit() {
  const [entries, setEntries] = useState(null);
  const [error, setError] = useState(null);
  const [filtroEntidade, setFiltroEntidade] = useState('');

  useEffect(() => {
    api.audit
      .list({ limit: 200, ...(filtroEntidade ? { entidade: filtroEntidade } : {}) })
      .then(setEntries)
      .catch((err) => setError(err.message));
  }, [filtroEntidade]);

  // Fase 3.8 (item 3.8-14): lista ampliada — infra_pops/infra_portas_pon/
  // contrato_clientes_reservados/contrato_regras_solicitacoes já eram auditadas
  // genericamente desde fases anteriores, mas não tinham atalho de filtro nesta tela.
  const entidades = ['', 'auth', 'simulacoes', 'propostas_comerciais', 'pricing_override_requests', 'contratos', 'pricing_parametros', 'infra_pops', 'infra_portas_pon', 'contrato_clientes_reservados', 'contrato_regras_solicitacoes', 'ativos', 'ativos_devolucao'];

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;

  return (
    <div className="page">
      <div className="page-header">
        <h1>Auditoria</h1>
        <p>Login, simulações, alterações de preço, overrides, aprovações, propostas, contratos e parâmetros — trilha imutável.</p>
      </div>

      <div className="chip-row" style={{ marginBottom: 18 }}>
        {entidades.map((e) => (
          <button key={e || 'todas'} className={`chip${filtroEntidade === e ? ' active' : ''}`} onClick={() => setFiltroEntidade(e)}>
            {e || 'Todas'}
          </button>
        ))}
      </div>

      {!entries ? (
        <div className="spinner" />
      ) : entries.length === 0 ? (
        <div className="card"><div className="empty-state">Nenhum evento para este filtro.</div></div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Quando</th>
                  <th>Ação</th>
                  <th>Entidade</th>
                  <th>Id da entidade</th>
                  <th>Motivo</th>
                </tr>
              </thead>
              <tbody>
                {entries.map((e) => (
                  <tr key={e.id}>
                    <td>{new Date(e.criado_em).toLocaleString('pt-BR')}</td>
                    <td><span className={`badge ${ACAO_CLASS[e.acao] || ''}`}>{e.acao}</span></td>
                    <td>{e.entidade}</td>
                    <td style={{ fontFamily: 'var(--font-mono)', fontSize: '0.78rem' }}>{e.entidade_id}</td>
                    <td>{e.motivo || '—'}</td>
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
