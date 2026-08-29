import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../lib/api';
import PortfolioScenarioChart from '../components/charts/PortfolioScenarioChart';
import { formatCurrencyFull } from '../components/charts/chartUtils';

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
  const [resumo, setResumo] = useState(null);
  const [usuariosPendentes, setUsuariosPendentes] = useState(null);
  const [capacidade, setCapacidade] = useState(null);
  const [cenarios, setCenarios] = useState(null);
  const [cenariosErro, setCenariosErro] = useState(false);

  useEffect(() => {
    api.cities
      .list()
      .then(setCities)
      .catch((err) => setError(err.message));
    // Fase 2.5.1 seção 30 — indicadores comerciais/assinatura/usuários no
    // dashboard principal. Nunca bloqueia o dashboard se falhar (ex.: perfil
    // sem RLS pra alguma agregação) — cada card fica "—" nesse caso.
    api.contracts.dashboard().then(setResumo).catch(() => setResumo(null));
    // "Convite pendente" só é conhecido quando a Auth Admin API está
    // configurada E quem está olhando é ADMINISTRADOR (ver api/routes/
    // users.js) — para qualquer outro caso, status_auth vem null em toda
    // linha e o card mostra "—" honestamente, em vez de inventar um número.
    api.users.list().then((list) => {
      const withStatus = list.filter((u) => u.status_auth);
      setUsuariosPendentes(withStatus.length > 0 ? withStatus.filter((u) => u.status_auth === 'CONVITE_PENDENTE').length : null);
    }).catch(() => setUsuariosPendentes(null));
    // Fase 3 (item 3.3): capacidade agregada do portfólio e cenários de receita.
    api.contracts.dashboardCapacidade().then(setCapacidade).catch(() => setCapacidade(null));
    api.contracts.dashboardCenariosPortfolio().then(setCenarios).catch(() => setCenariosErro(true));
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
        {/* Fase 3.8 (item 1): marca OptiMon discreta no dashboard — só o ícone,
            pequeno, ao lado do título; nunca o lockup completo aqui (isso já
            fica na sidebar) para não competir com os KPIs. */}
        <h1 style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <img src="/branding/optimon-icon.svg" alt="" width="24" height="24" style={{ display: 'block' }} />
          Dashboard
        </h1>
        <p>Visão consolidada da rede, capacidade e operação comercial.</p>
      </div>

      <div className="card-grid" style={{ marginBottom: 28 }}>
        <Kpi label="Cidades" value={totals.cidades} />
        <Kpi label="Infraestruturas (POPs)" value={totals.pops} />
        <Kpi label="Postes cadastrados" value={totals.postes.toLocaleString('pt-BR')} />
        <Kpi label="Capacidade máxima" value={`${totals.capacidade.toLocaleString('pt-BR')} clientes`} />
        <Kpi label="Clientes ativos" value={totals.ativos.toLocaleString('pt-BR')} sub={`${((totals.ativos / (totals.capacidade || 1)) * 100).toFixed(1)}% de ocupação`} />
        <Kpi label="Receita mensal contratada" value={resumo ? formatCurrencyFull(resumo.valor_mensal_contratado) : '—'} sub="soma das mensalidades mínimas ativas" />
      </div>

      <h2 className="section-title">Capacidade de rede (fibra e PON)</h2>
      <div className="card-grid" style={{ marginBottom: 28 }}>
        <Kpi label="Fibras totais" value={capacidade ? capacidade.fibras_totais.toLocaleString('pt-BR') : '—'} />
        <Kpi label="Fibras livres" value={capacidade ? capacidade.fibras_livres.toLocaleString('pt-BR') : '—'} />
        <Kpi label="Fibras locadas" value={capacidade ? capacidade.fibras_locadas.toLocaleString('pt-BR') : '—'} />
        <Kpi label="PONs totais" value={capacidade ? capacidade.pons_totais.toLocaleString('pt-BR') : '—'} />
        <Kpi label="PONs ocupadas" value={capacidade ? capacidade.pons_ocupadas.toLocaleString('pt-BR') : '—'} sub={capacidade ? `${(capacidade.taxa_ocupacao_portfolio * 100).toFixed(1)}% de ocupação do portfólio` : undefined} />
        <Kpi label="Capacidade disponível" value={capacidade ? `${capacidade.capacidade_disponivel_clientes.toLocaleString('pt-BR')} clientes` : '—'} />
      </div>

      <h2 className="section-title">Comercial, assinaturas e usuários</h2>
      <div className="card-grid" style={{ marginBottom: 28 }}>
        <Kpi label="Contratos ativos" value={resumo ? resumo.contratos_ativos : '—'} />
        <Kpi label="Propostas abertas" value={resumo ? resumo.propostas_abertas : '—'} sub="todo status não terminal" />
        <Kpi label="Propostas aprovadas" value={resumo ? resumo.propostas_aprovadas : '—'} />
        <Kpi label="Assinaturas pendentes" value={resumo ? resumo.assinaturas_pendentes : '—'} sub="envelopes em andamento" />
        <Kpi label="Contratos aguardando assinatura" value={resumo ? resumo.contratos_aguardando_assinatura : '—'} />
        <Kpi label="Contratos próx. do vencimento" value={resumo ? resumo.contratos_proximos_vencimento : '—'} sub="nos próximos 60 dias" />
        <Kpi label="Reajustes pendentes" value={resumo ? resumo.reajustes_pendentes : '—'} />
        <Kpi label="Aditivos pendentes" value={resumo ? resumo.aditivos_pendentes : '—'} />
        <Kpi label="Alertas não resolvidos" value={resumo ? resumo.alertas_nao_resolvidos : '—'} />
        <Kpi label="Proponentes ativos" value={resumo ? resumo.proponentes_ativos : '—'} />
        <Kpi label="Usuários ativos" value={resumo ? resumo.usuarios_ativos : '—'} sub={usuariosPendentes !== null ? `${usuariosPendentes} com convite pendente` : undefined} />
      </div>

      <h2 className="section-title">Receita acumulada do portfólio — cenários</h2>
      <div className="card" style={{ marginBottom: 28, padding: 20 }}>
        {cenariosErro && <div className="empty-state">Não foi possível carregar os cenários agora.</div>}
        {!cenariosErro && !cenarios && <div className="spinner" />}
        {cenarios && (
          <>
            <PortfolioScenarioChart cenarios={cenarios.cenarios} />
            <p style={{ fontSize: '0.78rem', color: 'var(--text-muted)', marginTop: 12, marginBottom: 0 }}>
              {cenarios.observacao}
            </p>
          </>
        )}
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
                    <Link to={`/cidades/${c.cidade_id}`} className="link-tab" style={{ fontSize: '0.82rem' }}>
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
