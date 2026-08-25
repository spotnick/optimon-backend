import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { api } from '../lib/api';
import ReguaDePreco from '../components/ReguaDePreco';

function Kpi({ label, value, sub }) {
  return (
    <div className="card kpi-card">
      <div className="kpi-label">{label}</div>
      <div className="kpi-value">{value}</div>
      {sub && <div className="kpi-sub">{sub}</div>}
    </div>
  );
}

export default function CityDetail({ jussara = false }) {
  const params = useParams();
  const [city, setCity] = useState(null);
  const [fibras, setFibras] = useState(null);
  const [pricing, setPricing] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    let cidadeId = params.id;

    async function load() {
      try {
        if (jussara) {
          const cities = await api.cities.list();
          const jussaraCity = cities.find((c) => c.nome === 'Jussara');
          if (!jussaraCity) throw new Error('Cidade Jussara não encontrada.');
          cidadeId = jussaraCity.cidade_id;
        }
        const [cityDetail, fibrasData] = await Promise.all([
          api.cities.detail(cidadeId),
          api.pricing.fibrasIndicadores({ cidade_id: cidadeId }),
        ]);
        setCity(cityDetail);
        setFibras(fibrasData);

        const pons = cityDetail.portas_pon_totais > 0 ? Math.min(1, cityDetail.portas_pon_totais) : 1;
        const calc = await api.pricing.calculate({ cidade_id: cidadeId, pons_count: pons, clientes: 0, arpu: 0 });
        setPricing(calc);
      } catch (err) {
        setError(err.message);
      }
    }
    load();
  }, [params.id, jussara]);

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;
  if (!city) return <div className="page"><div className="spinner" /></div>;

  return (
    <div className="page">
      <div className="page-header">
        <h1>{city.nome} — {city.uf}</h1>
        <p>{city.endereco || 'Infraestrutura, capacidade e régua de preço.'}</p>
      </div>

      <div className="card-grid" style={{ marginBottom: 28 }}>
        <Kpi label="Rede (km)" value={Number(city.km_rede).toLocaleString('pt-BR')} />
        <Kpi label="Postes" value={Number(city.postes_count).toLocaleString('pt-BR')} />
        <Kpi label="Fibras totais" value={fibras?.fibras_totais ?? '—'} sub={`${fibras?.fibras_ociosas ?? 0} ociosas`} />
        <Kpi label="Portas PON" value={fibras?.portas_pon_totais ?? '—'} sub={`${fibras?.portas_pon_disponiveis ?? 0} disponíveis`} />
        <Kpi label="Capacidade máxima" value={Number(city.capacidade_maxima_clientes).toLocaleString('pt-BR')} sub="clientes" />
        <Kpi label="Clientes ativos" value={Number(city.clientes_ativos).toLocaleString('pt-BR')} sub={`${(Number(city.taxa_ocupacao || 0) * 100).toFixed(1)}% de ocupação`} />
      </div>

      {pricing && (
        <div className="card" style={{ marginBottom: 28 }}>
          <h2 className="section-title">Régua de Preço</h2>
          <ReguaDePreco floor={pricing.floor} recommended={pricing.recommended} opening={pricing.opening} governanceStatus={pricing.governance_status} />
          <div style={{ marginTop: 16, fontSize: '0.85rem', color: 'var(--text-muted)' }}>
            Baseado em {pricing.pons_count} {pricing.pons_count === 1 ? 'porta PON' : 'portas PON'} provisionada(s) — versão de precificação{' '}
            <strong>{pricing.pricing_version}</strong>.
          </div>
        </div>
      )}

      <h2 className="section-title">Infraestruturas (POPs)</h2>
      <div className="card" style={{ padding: 0, marginBottom: 28 }}>
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Código</th>
                <th>Nome</th>
                <th>Tipo</th>
                <th className="num">Postes</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {(city.pops || []).map((p) => (
                <tr key={p.pop_id}>
                  <td style={{ fontFamily: 'var(--font-mono)' }}>{p.codigo}</td>
                  <td>{p.nome}</td>
                  <td>{p.tipo}</td>
                  <td className="num">{p.postes_count}</td>
                  <td>{p.status}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <Link to="/simulacao" className="btn btn-primary">Simular preço para {city.nome} →</Link>
    </div>
  );
}
