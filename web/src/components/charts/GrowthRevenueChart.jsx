import { useMemo, useState } from 'react';
import { scaleLinear, niceMax, formatCurrencyShort, formatCurrencyFull, linePath } from './chartUtils';

// "CRESCIMENTO DA BASE × RECEITA OPTIMON" (seção 24) — X = clientes, Y = R$, uma série por
// linha (Revenue Share, Infrastructure Floor, Total a Pagar, Receita do Parceiro). Um
// único eixo Y (nunca dois eixos — dataviz skill), legenda sempre presente para ≥2 séries,
// crosshair + tooltip no hover.

const SERIES = [
  { key: 'revenue_share_value', label: 'Revenue Share', color: '#0d9488' },
  { key: 'floor', label: 'Infrastructure Floor', color: '#4338ca' },
  { key: 'total_payable', label: 'Total a Pagar (OptiMon)', color: '#1e293b' },
  { key: 'partner_revenue', label: 'Receita do Parceiro', color: '#db2777' },
];

const WIDTH = 720;
const HEIGHT = 320;
const MARGIN = { top: 16, right: 16, bottom: 36, left: 64 };

export default function GrowthRevenueChart({ points }) {
  const [hoverIdx, setHoverIdx] = useState(null);

  const data = useMemo(() => (points || []).map((p) => ({
    clientes: Number(p.clientes),
    revenue_share_value: Number(p.revenue_share_value),
    floor: Number(p.floor),
    total_payable: Number(p.total_payable),
    partner_revenue: Number(p.partner_revenue),
  })), [points]);

  if (!data.length) return <div className="empty-state">Sem dados para plotar ainda.</div>;

  const innerW = WIDTH - MARGIN.left - MARGIN.right;
  const innerH = HEIGHT - MARGIN.top - MARGIN.bottom;

  const xMax = Math.max(...data.map((d) => d.clientes));
  const yMax = niceMax(Math.max(...data.flatMap((d) => SERIES.map((s) => d[s.key]))));

  const x = scaleLinear([0, xMax], [0, innerW]);
  const y = scaleLinear([0, yMax], [innerH, 0]);

  const yTicks = [0, 0.25, 0.5, 0.75, 1].map((t) => yMax * t);
  const xTicks = [0, 0.25, 0.5, 0.75, 1].map((t) => Math.round(xMax * t));

  const hover = hoverIdx != null ? data[hoverIdx] : null;

  function handleMove(evt) {
    const svg = evt.currentTarget;
    const rect = svg.getBoundingClientRect();
    const px = ((evt.clientX - rect.left) / rect.width) * WIDTH - MARGIN.left;
    const clienteAtCursor = (px / innerW) * xMax;
    let closest = 0;
    let closestDist = Infinity;
    data.forEach((d, i) => {
      const dist = Math.abs(d.clientes - clienteAtCursor);
      if (dist < closestDist) {
        closestDist = dist;
        closest = i;
      }
    });
    setHoverIdx(closest);
  }

  return (
    <div>
      <div className="chip-row" style={{ marginBottom: 10 }}>
        {SERIES.map((s) => (
          <div key={s.key} style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: '0.78rem', color: 'var(--text-muted)' }}>
            <span style={{ width: 10, height: 10, borderRadius: 3, background: s.color, display: 'inline-block' }} />
            {s.label}
          </div>
        ))}
      </div>
      <svg
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        style={{ width: '100%', height: 'auto', display: 'block' }}
        onMouseMove={handleMove}
        onMouseLeave={() => setHoverIdx(null)}
        role="img"
        aria-label="Gráfico de crescimento da base de clientes versus receita OptiMon e do parceiro"
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
          {xTicks.map((t) => (
            <text key={t} x={x(t)} y={innerH + 20} textAnchor="middle" fontSize="10.5" fill="var(--text-muted)">
              {t}
            </text>
          ))}
          <text x={innerW / 2} y={innerH + 34} textAnchor="middle" fontSize="10.5" fill="var(--text-muted)" fontWeight="600">
            Clientes ativos
          </text>

          {SERIES.map((s) => (
            <path
              key={s.key}
              d={linePath(data.map((d) => ({ x: d.clientes, y: d[s.key] })), x, y)}
              fill="none"
              stroke={s.color}
              strokeWidth={2}
              strokeLinejoin="round"
              strokeLinecap="round"
            />
          ))}

          {hover && (
            <>
              <line x1={x(hover.clientes)} x2={x(hover.clientes)} y1={0} y2={innerH} stroke="var(--gray-300)" strokeWidth={1} strokeDasharray="3,3" />
              {SERIES.map((s) => (
                <circle key={s.key} cx={x(hover.clientes)} cy={y(hover[s.key])} r={4} fill={s.color} stroke="var(--surface)" strokeWidth={2} />
              ))}
            </>
          )}
        </g>
      </svg>

      {hover && (
        <div className="card" style={{ marginTop: 10, padding: '10px 16px', display: 'inline-block' }}>
          <div style={{ fontWeight: 700, marginBottom: 4 }}>{hover.clientes} clientes</div>
          {SERIES.map((s) => (
            <div key={s.key} style={{ display: 'flex', justifyContent: 'space-between', gap: 24, fontSize: '0.82rem' }}>
              <span style={{ color: 'var(--text-muted)' }}>{s.label}</span>
              <span style={{ fontFamily: 'var(--font-mono)' }}>{formatCurrencyFull(hover[s.key])}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
