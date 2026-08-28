import { useEffect, useState } from 'react';
import { api, apiDownload } from '../lib/api';
import { formatCurrencyFull } from '../components/charts/chartUtils';

// Fase 3 (item 3.6): Relatórios gerenciais — cada aba é uma lista exportável (CSV) de
// uma das entidades pedidas no prompt-mestre. "Receita por POP" mostra capacidade, não
// dinheiro — ver comentário em supabase/migrations/20260924090000_..._relatorios_
// gerenciais.sql sobre por que a receita não é segregável por POP com o schema atual.
// "Faturamento real" honestamente mostra "não disponível" enquanto medicoes_mensais não
// for alimentada (integração HubSoft/financeiro, adiada) — nunca inventa um número.

const TABS = [
  { key: 'receita-por-cidade', label: 'Receita por cidade' },
  { key: 'receita-por-parceiro', label: 'Receita por parceiro' },
  { key: 'capacidade-por-pop', label: 'Capacidade por POP' },
  { key: 'clientes-por-pon', label: 'Clientes por PON' },
  { key: 'contratos', label: 'Contratos' },
  { key: 'reajustes', label: 'Reajustes' },
];

const COLUMN_LABELS = {
  cidade: 'Cidade', uf: 'UF', contratos_ativos: 'Contratos ativos',
  receita_mensal_contratada: 'Receita mensal contratada', revenue_share_medio_pct: 'Revenue share médio',
  parceiro: 'Parceiro', cidades_atendidas: 'Cidades atendidas',
  pop: 'POP', fibras_totais: 'Fibras totais', fibras_livres: 'Fibras livres', fibras_locadas: 'Fibras locadas',
  pons_totais: 'PONs totais', pons_ocupadas: 'PONs ocupadas', clientes_ativos: 'Clientes ativos',
  taxa_ocupacao: 'Ocupação', contratos_distintos: 'Contratos distintos',
  codigo_porta: 'Porta', tecnologia: 'Tecnologia', capacidade_maxima: 'Capacidade máxima',
  capacidade_disponivel: 'Capacidade disponível', contratada: 'Contratada',
  numero: 'Número', status: 'Status', prazo_meses: 'Prazo (meses)', data_inicio: 'Início',
  data_fim_prevista: 'Fim previsto', mensalidade_minima_porta: 'Mensalidade mínima',
  percentual_revenue_share: 'Revenue share', modelo_cobranca: 'Modelo de cobrança',
  contrato_numero: 'Contrato', indice: 'Índice', percentual_aplicado: 'Percentual aplicado',
  competencia_base: 'Competência', aplicado_em: 'Aplicado em',
};

const CURRENCY_COLUMNS = new Set(['receita_mensal_contratada', 'mensalidade_minima_porta']);
const PCT_COLUMNS = new Set(['revenue_share_medio_pct', 'taxa_ocupacao', 'percentual_revenue_share', 'percentual_aplicado']);
const BOOL_COLUMNS = new Set(['contratada']);

function formatCell(col, value) {
  if (value === null || value === undefined) return '—';
  if (CURRENCY_COLUMNS.has(col)) return formatCurrencyFull(value);
  if (PCT_COLUMNS.has(col)) return `${(Number(value) * 100).toFixed(1)}%`;
  if (BOOL_COLUMNS.has(col)) return value ? 'Sim' : 'Não';
  return String(value);
}

export default function Reports() {
  const [tab, setTab] = useState(TABS[0].key);
  const [rows, setRows] = useState(null);
  const [error, setError] = useState(null);
  const [faturamento, setFaturamento] = useState(null);

  useEffect(() => {
    setRows(null);
    setError(null);
    api.reports.get(tab).then(setRows).catch((err) => setError(err.message));
  }, [tab]);

  useEffect(() => {
    api.reports.faturamentoReal().then(setFaturamento).catch(() => setFaturamento(null));
  }, []);

  async function handleDownloadCsv() {
    try {
      const { blob, fileName } = await apiDownload(api.reports.csvPath(tab));
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = fileName.endsWith('.csv') ? fileName : `${tab}.csv`;
      a.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError(err.message);
    }
  }

  const columns = rows && rows.length > 0 ? Object.keys(rows[0]) : [];

  return (
    <div className="page">
      <div className="page-header">
        <h1>Relatórios gerenciais</h1>
        <p>Receita, capacidade e contratos por entidade — exportáveis em CSV.</p>
      </div>

      {faturamento && faturamento.disponivel === false && (
        <div className="card" style={{ marginBottom: 20, padding: 16, borderLeft: '4px solid var(--status-discount)' }}>
          <strong>Faturamento real, revenue share e take-or-pay calculados: não disponível.</strong>
          <p style={{ margin: '6px 0 0', fontSize: '0.85rem', color: 'var(--text-muted)' }}>{faturamento.motivo}</p>
        </div>
      )}

      <div className="chip-row" style={{ marginBottom: 18, flexWrap: 'wrap', gap: 8 }}>
        {TABS.map((t) => (
          <button
            key={t.key}
            className={`btn ${tab === t.key ? 'btn-primary' : 'btn-secondary'}`}
            onClick={() => setTab(t.key)}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === 'capacidade-por-pop' && (
        <p style={{ fontSize: '0.8rem', color: 'var(--text-muted)', marginTop: -8, marginBottom: 16 }}>
          Sem coluna de receita: a mensalidade é definida por contrato (que pode usar mais de um POP), não é segregável por POP sem inventar uma metodologia de rateio.
        </p>
      )}

      {error && <div className="error-banner">{error}</div>}
      {!error && !rows && <div className="spinner" />}

      {rows && (
        <div className="card" style={{ padding: 0 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '14px 16px' }}>
            <span style={{ fontSize: '0.82rem', color: 'var(--text-muted)' }}>{rows.length} linha(s)</span>
            <button className="btn btn-secondary" onClick={handleDownloadCsv} disabled={rows.length === 0}>
              Exportar CSV
            </button>
          </div>
          {rows.length === 0 ? (
            <div className="empty-state" style={{ padding: 24 }}>Sem dados para este relatório ainda.</div>
          ) : (
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    {columns.map((c) => (
                      <th key={c} className={CURRENCY_COLUMNS.has(c) || PCT_COLUMNS.has(c) ? 'num' : undefined}>
                        {COLUMN_LABELS[c] || c}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row, i) => (
                    <tr key={row.id || row.cidade_id || row.parceiro_id || row.pop_id || row.porta_id || row.contrato_id || row.reajuste_id || i}>
                      {columns.map((c) => (
                        <td key={c} className={CURRENCY_COLUMNS.has(c) || PCT_COLUMNS.has(c) ? 'num' : undefined}>
                          {formatCell(c, row[c])}
                        </td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
