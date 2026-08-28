import { useMemo, useState } from 'react';
import { scaleLinear, niceMax, formatCurrencyShort, formatCurrencyFull } from './chartUtils';

// Fase 3 (item 3.3): "receita acumulada do portfólio (NICK) em 3 cenários" — conservador/
// recomendado/otimista, nos horizontes 12/36/48/60. Barras agrupadas (não linha): só 4
// pontos por série, não igualmente espaçados no tempo — uma linha interpolando entre eles
// sugeriria continuidade que os dados não têm (dataviz: comparação categórica = barra).
// Um único eixo Y (nunca dois), legenda sempre presente (3 séries), cores consistentes com
// GrowthRevenueChart (mesma paleta do app: indigo/teal/slate).

const CENARIOS = [
  { key: 'conservador', label: 'Conservador', color: '#64748b' },
  { key: 'recomendado', label: 'Recomendado', color: '#4338ca' },
  { key: 'otimista', label: 'Otimista', color: '#0d9488' },
];

const WIDTH = 760;
const HEIGHT = 340;
const MARGIN = { top: 16, right: 16, bottom: 44, left: 72 };

export default function PortfolioScenarioChart({ cenarios }) {
  const [hover, setHover] = useState(null);

  const horizontes = useMemo(() => {
    const base = cenarios?.recomendado?.horizontes || [];
    return base.map((h) => h.meses);
  }, [cenarios]);

  if (!cenarios || horizontes.length === 0) {
    return <div className="empty-state">Sem dados de cenário ainda.</div>;
  }

  const innerW = WIDTH - MARGIN.left - MARGIN.right;
  const innerH = HEIGHT - MARGIN.top - MARGIN.bottom;

  const allValues = CENARIOS.flatMap((c) =>
    (cenarios[c.key]?.horizontes || []).map((h) => Number(h.receita_acumulada || 0))
  );
  const yMax = niceMax(Math.max(1, ...allValues));
  const y = scaleLinear([0, yMax], [innerH, 0]);

  const groupWidth = innerW / horizontes.length;
  const barPad = groupWidth * 0.12;
  const barsAreaWidth = groupWidth - barPad * 2;
  const barWidth = barsAreaWidth / CENARIOS.length;

  const yTicks = [0, 0.25, 0.5, 0.75, 1].map((t) => yMax * t);

  function cellFor(horizonte, cenarioKey) {
    const row = (cenarios[cenarioKey]?.horizontes || []).find((h) => h.meses === horizonte);
    return row || null;
  }

  return (
    <div>
      <div className="chip-row" style={{ marginBottom: 10 }}>
        {CENARIOS.map((c) => (
          <div key={c.key} style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: '0.78rem', color: 'var(--text-muted)' }}>
            <span style={{ width: 10, height: 10, borderRadius: 3, background: c.color, display: 'inline-block' }} />
            {c.label}
            {cenarios[c.key]?.crescimento_mensal_pct != null && (
              <span style={{ opacity: 0.7 }}>({(cenarios[c.key].crescimento_mensal_pct * 100).toFixed(2)}%/mês)</span>
            )}
          </div>
        ))}
      </div>
      <svg
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        style={{ width: '100%', height: 'auto', display: 'block' }}
        role="img"
        aria-label="Gráfico de receita acumulada do portfólio em três cenários, por horizonte"
      >
        <g transform={`translate(${MARGIN.left},${MARGIN.top})`}>
          {yTicks.map((t) => (
            <g key={t}>
              <line x1={0} x2={innerW} y1={y(t)} y2={y(t)} stroke="var(--gray-200)" strokeWidth={1} />
              <text x={-10} y={y(t)} dy="0.32em" textAnchor="end" fontSize="10.5" fill="var(--text-muted)">
                {formatCurrencyShort(t)}
              </text>
            </g>
          ))}

          {horizontes.map((h, gi) => {
            const groupX = gi * groupWidth;
            const isMinimo = cellFor(h, 'recomendado')?.minimo_contratual_flag;
            return (
              <g key={h}>
                {CENARIOS.map((c, ci) => {
                  const row = cellFor(h, c.key);
                  const val = Number(row?.receita_acumulada || 0);
                  const barX = groupX + barPad + ci * barWidth;
                  const barY = y(val);
                  const barH = innerH - barY;
                  const isHover = hover && hover.meses === h && hover.cenarioKey === c.key;
                  return (
                    <rect
                      key={c.key}
                      x={barX + 1}
                      y={barY}
                      width={Math.max(0, barWidth - 2)}
                      height={Math.max(0, barH)}
                      rx={3}
                      fill={c.color}
                      opacity={isHover ? 1 : 0.85}
                      onMouseEnter={() => setHover({ meses: h, cenarioKey: c.key, row })}
                      onMouseLeave={() => setHover(null)}
                      style={{ cursor: 'pointer' }}
                    />
                  );
                })}
                <text x={groupX + groupWidth / 2} y={innerH + 20} textAnchor="middle" fontSize="10.5" fill="var(--text-muted)">
                  {h}m{isMinimo ? ' *' : ''}
                </text>
              </g>
            );
          })}

          <text x={innerW / 2} y={innerH + 36} textAnchor="middle" fontSize="10.5" fill="var(--text-muted)" fontWeight="600">
            Horizonte (meses) — * 48 = prazo contratual mínimo, demais são só cenários analíticos
          </text>
        </g>
      </svg>

      {hover && hover.row && (
        <div className="card" style={{ marginTop: 10, padding: '10px 16px', display: 'inline-block' }}>
          <div style={{ fontWeight: 700, marginBottom: 4 }}>
            {CENARIOS.find((c) => c.key === hover.cenarioKey)?.label} — {hover.meses} meses
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 24, fontSize: '0.82rem' }}>
            <span style={{ color: 'var(--text-muted)' }}>Receita acumulada</span>
            <span style={{ fontFamily: 'var(--font-mono)' }}>{formatCurrencyFull(hover.row.receita_acumulada)}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 24, fontSize: '0.82rem' }}>
            <span style={{ color: 'var(--text-muted)' }}>ROI</span>
            <span style={{ fontFamily: 'var(--font-mono)' }}>{hover.row.roi?.texto ?? '—'}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 24, fontSize: '0.82rem' }}>
            <span style={{ color: 'var(--text-muted)' }}>Payback</span>
            <span style={{ fontFamily: 'var(--font-mono)' }}>{hover.row.payback?.texto ?? '—'}</span>
          </div>
        </div>
      )}
    </div>
  );
}
