// OptiMon — utilitários mínimos para os gráficos SVG "feitos à mão" (sem biblioteca
// externa, para manter o bundle do Vercel enxuto). Segue a linha do dataviz skill: um
// eixo só, marcas finas, sem depender de canvas.

export function scaleLinear(domain, range) {
  const [d0, d1] = domain;
  const [r0, r1] = range;
  const span = d1 - d0 || 1;
  return (v) => r0 + ((v - d0) / span) * (r1 - r0);
}

export function niceMax(value) {
  if (value <= 0) return 10;
  const pow = 10 ** Math.floor(Math.log10(value));
  const norm = value / pow;
  let niceNorm;
  if (norm <= 1) niceNorm = 1;
  else if (norm <= 2) niceNorm = 2;
  else if (norm <= 5) niceNorm = 5;
  else niceNorm = 10;
  return niceNorm * pow;
}

export function formatCurrencyShort(v) {
  const abs = Math.abs(v);
  if (abs >= 1_000_000) return `R$ ${(v / 1_000_000).toFixed(1)}M`;
  if (abs >= 1_000) return `R$ ${(v / 1_000).toFixed(1)}k`;
  return `R$ ${v.toFixed(0)}`;
}

export function formatCurrencyFull(v) {
  return (v ?? 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
}

export function linePath(points, x, y) {
  return points.map((p, i) => `${i === 0 ? 'M' : 'L'} ${x(p.x).toFixed(2)} ${y(p.y).toFixed(2)}`).join(' ');
}
