import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../lib/api';

function Kpi({ label, value, sub }) {
  return (
    <div className="card kpi-card">
      <div className="kpi-label">{label}</div>
      <div className="kpi-value">{value}</div>
      {sub && <div className="kpi-sub">{sub}</div>}
    </div>
  );
}

export default function Dashboard() {
  const [cities, setCities] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    api.cities
      .list()
      .then(setCities)
      .catch((err) => setError(err.message));
  }, []);

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;
  if (!cities) return <div className="page"><div className="spinner" /></div>;

  const totals = cities.reduce(
    (acc, c) => ({
      cidades: acc.cidades + 1,
      postes: acc.postes + Number(c.postes_count || 0),
      pops: acc.pops + Number(c.pops_count || 0),
      capacidade: acc.capacidade + Number(c.capacidade_maxima_clientes || 0),
      ativos: acc.ativos + Number(c.clientes_ativos || 0),
    }),
    { cidades: 0, postes: 0, pops: 0, capacidade: 0, ativos: 0 }
  );

  return (
    <div className="page">
      <div className="page-header">
        <h1>Dashboard</h1>
        <p>Visão consolidada da rede, capacidade e operação comercial.</p>
      </div>

      <div className="card-grid" style={{ marginBottom: 28 }}>
        <Kpi label="Cidades" value={totals.cidades} />
        <Kpi label="Infraestruturas (POPs)" value={totals.pops} />
        <Kpi label="Postes cadastrados" value={totals.postes.toLocaleString('pt-BR')} />
        <Kpi label="Capacidade máxima" value={`${totals.capacidade.toLocaleString('pt-BR')} clientes`} />
        <Kpi label="Clientes ativos" value={totals.ativos.toLocaleString('pt-BR')} sub={`${((totals.ativos / (totals.capacidade || 1)) * 100).toFixed(1)}% de ocupação`} />
        <Kpi label="Revenue Share padrão" value="12%" sub="configurável por contrato" />
      </div>

      <h2 className="section-title">Cidades</h2>
      <div className="card" style={{ padding: 0 }}>
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Cidade</th>
                <th>UF</th>
                <th className="num">Postes</th>
                <th className="num">POPs</th>
                <th className="num">Capacidade</th>
                <th className="num">Clientes ativos</th>
                <th className="num">Ocupação</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {cities.map((c) => (
                <tr key={c.cidade_id}>
                  <td style={{ fontWeight: 600 }}>{c.nome}</td>
                  <td>{c.uf}</td>
                  <td className="num">{Number(c.postes_count).toLocaleString('pt-BR')}</td>
                  <td className="num">{c.pops_count}</td>
                  <td className="num">{Number(c.capacidade_maxima_clientes).toLocaleString('pt-BR')}</td>
                  <td className="num">{Number(c.clientes_ativos).toLocaleString('pt-BR')}</td>
                  <td className="num">{(Number(c.taxa_ocupacao || 0) * 100).toFixed(1)}%</td>
                  <td>
                    <Link
                      to={c.nome === 'Jussara' ? '/cidades/jussara' : `/cidades/${c.cidade_id}`}
                      className="link-tab"
                      style={{ fontSize: '0.82rem' }}
                    >
                      Ver detalhe →
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
