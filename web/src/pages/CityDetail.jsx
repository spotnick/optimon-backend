import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { api } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import ReguaDePreco from '../components/ReguaDePreco';

const STATUS_LABEL = { ATIVA: 'Ativa', INATIVA: 'Inativa', PLANEJADA: 'Planejada' };
const CAN_EDIT_INFRA = ['ENGENHARIA', 'ADMINISTRADOR'];

function Kpi({ label, value, sub }) {
  return (
    <div className="card kpi-card">
      <div className="kpi-label">{label}</div>
      <div className="kpi-value">{value}</div>
      {sub && <div className="kpi-sub">{sub}</div>}
    </div>
  );
}

// Nenhuma cidade tem tratamento especial aqui — a página é sempre resolvida por
// :id via useParams(), igual para Jussara, Andirá ou qualquer outra (seção 34/42).
export default function CityDetail() {
  const params = useParams();
  const { role } = useAuth();
  const [city, setCity] = useState(null);
  const [fibras, setFibras] = useState(null);
  const [pricing, setPricing] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    const cidadeId = params.id;

    async function load() {
      try {
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
  }, [params.id]);

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;
  if (!city) return <div className="page"><div className="spinner" /></div>;

  return (
    <div className="page">
      <div className="page-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h1>
            {city.nome} — {city.uf}{' '}
            <span className={`badge status-${city.status === 'ATIVA' ? 'allow' : city.status === 'PLANEJADA' ? 'discount' : 'block'}`} style={{ verticalAlign: 'middle', marginLeft: 8 }}>
              {STATUS_LABEL[city.status] || city.status}
            </span>
          </h1>
          <p>{city.endereco || 'Infraestrutura, capacidade e régua de preço.'}</p>
        </div>
        {CAN_EDIT_INFRA.includes(role) && (
          <Link to={`/cidades/${city.cidade_id}/editar`} className="btn btn-primary">
            Editar Infraestrutura
          </Link>
        )}
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
