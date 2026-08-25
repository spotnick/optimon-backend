import { useMemo, useState } from 'react';
import { scaleLinear } from './chartUtils';

// "CLIENTES × PONs NECESSÁRIAS" (seção 25) — degrau: 1 PON até 128, 2 até 256, 3 até 384…
// Um eixo Y só (nº de PONs), série única (sem legenda obrigatória — dataviz skill: uma
// série não precisa de legenda, o título já nomeia).

const WIDTH = 720;
const HEIGHT = 220;
const MARGIN = { top: 16, right: 16, bottom: 36, left: 48 };

export default function ClientsPonsChart({ points }) {
  const [hoverIdx, setHoverIdx] = useState(null);

  const data = useMemo(
    () => (points || []).map((p) => ({ clientes: Number(p.clientes), pons: Number(p.pons_count) })),
    [points]
  );

  if (!data.length) return <div className="empty-state">Sem dados para plotar ainda.</div>;

  const innerW = WIDTH - MARGIN.left - MARGIN.right;
  const innerH = HEIGHT - MARGIN.top - MARGIN.bottom;

  const xMax = Math.max(...data.map((d) => d.clientes));
  const yMax = Math.max(4, Math.max(...data.map((d) => d.pons)) + 1);

  const x = scaleLinear([0, xMax], [0, innerW]);
  const y = scaleLinear([0, yMax], [innerH, 0]);

  // Constrói um caminho em "degrau" (step-after): sobe no ponto exato onde muda o nº de PON.
  const stepPath = data.reduce((acc, d, i) => {
    const px = x(d.clientes).toFixed(2);
    const py = y(d.pons).toFixed(2);
    if (i === 0) return `M ${px} ${py}`;
    const prevPy = y(data[i - 1].pons).toFixed(2);
    return `${acc} L ${px} ${prevPy} L ${px} ${py}`;
  }, '');

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
      <svg
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        style={{ width: '100%', height: 'auto', display: 'block' }}
        onMouseMove={handleMove}
        onMouseLeave={() => setHoverIdx(null)}
        role="img"
        aria-label="Gráfico de número de PONs necessárias por quantidade de clientes"
      >
        <g transform={`translate(${MARGIN.left},${MARGIN.top})`}>
          {Array.from({ length: yMax + 1 }, (_, i) => i).map((t) => (
            <g key={t}>
              <line x1={0} x2={innerW} y1={y(t)} y2={y(t)} stroke="var(--gray-200)" strokeWidth={1} />
              <text x={-10} y={y(t)} dy="0.32em" textAnchor="end" fontSize="10.5" fill="var(--text-muted)">
                {t}
              </text>
            </g>
          ))}
          <text x={innerW / 2} y={innerH + 34} textAnchor="middle" fontSize="10.5" fill="var(--text-muted)" fontWeight="600">
            Clientes ativos
          </text>
          <text x={-innerH / 2} y={-36} transform="rotate(-90)" textAnchor="middle" fontSize="10.5" fill="var(--text-muted)" fontWeight="600">
            PONs necessárias
          </text>

          <path d={stepPath} fill="none" stroke="var(--color-accent-600)" strokeWidth={2} strokeLinejoin="round" />

          {hover && (
            <>
              <line x1={x(hover.clientes)} x2={x(hover.clientes)} y1={0} y2={innerH} stroke="var(--gray-300)" strokeWidth={1} strokeDasharray="3,3" />
              <circle cx={x(hover.clientes)} cy={y(hover.pons)} r={4.5} fill="var(--color-accent-600)" stroke="var(--surface)" strokeWidth={2} />
            </>
          )}
        </g>
      </svg>
      {hover && (
        <div className="card" style={{ marginTop: 10, padding: '10px 16px', display: 'inline-block', fontSize: '0.85rem' }}>
          <strong>{hover.clientes}</strong> clientes → <strong>{hover.pons}</strong> {hover.pons === 1 ? 'PON' : 'PONs'}
        </div>
      )}
    </div>
  );
}
