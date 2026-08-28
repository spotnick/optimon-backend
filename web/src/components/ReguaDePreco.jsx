import { formatCurrencyFull } from './charts/chartUtils';

// "RÉGUA DE PREÇO" (seção 21): ABERTURA / RECOMENDADO / PISO, com a posição do preço
// proposto marcada visualmente sobre a régua.

const STATUS_LABEL = {
  ALLOW: 'Liberado',
  ALLOW_WITH_DISCOUNT: 'Liberado com desconto',
  BLOCK_FOR_COMMERCIAL: 'Bloqueado para Comercial',
  ALLOW_WITH_DIRECTOR_OVERRIDE: 'Requer aprovação do Diretor',
  BLOCK: 'Bloqueado',
};

const STATUS_CLASS = {
  ALLOW: 'status-allow',
  ALLOW_WITH_DISCOUNT: 'status-discount',
  BLOCK_FOR_COMMERCIAL: 'status-block',
  ALLOW_WITH_DIRECTOR_OVERRIDE: 'status-director',
  BLOCK: 'status-block',
};

export default function ReguaDePreco({ floor, recommended, opening, proposto, governanceStatus }) {
  const min = floor;
  // Fase 3 (seção 5/13): "Preço Proposto" pode ser MAIOR que a abertura — nunca é
  // truncado no cálculo (ver app.simular_precificacao_completa), e a régua visual
  // não pode mais esconder isso truncando a posição do marcador em 100%. Quando o
  // proposto ultrapassa a abertura, a escala da régua se estende dinamicamente até
  // o proposto, então ABERTURA deixa de estar sempre na ponta direita e o marcador
  // PROPOSTO nunca fica visualmente empilhado em cima de ABERTURA quando são
  // valores diferentes.
  const max = proposto != null ? Math.max(opening, proposto) : opening;
  const acimaDaAbertura = proposto != null && proposto > opening;
  const pct = (v) => Math.max(0, Math.min(100, ((v - min) / (max - min || 1)) * 100));

  const status = governanceStatus?.por_papel;

  return (
    <div>
      <div className="regua">
        <div className="regua-track" />
        <div className="regua-marker" style={{ left: `${pct(floor)}%` }}>
          <div className="dot" />
          <div className="label">PISO</div>
          <div className="value">{formatCurrencyFull(floor)}</div>
        </div>
        <div className="regua-marker" style={{ left: `${pct(recommended)}%` }}>
          <div className="dot" />
          <div className="label">RECOMENDADO</div>
          <div className="value">{formatCurrencyFull(recommended)}</div>
        </div>
        <div className="regua-marker" style={{ left: `${pct(opening)}%` }}>
          <div className="dot" />
          <div className="label">ABERTURA</div>
          <div className="value">{formatCurrencyFull(opening)}</div>
        </div>
        {proposto != null && (
          <div className="regua-marker proposto" style={{ left: `${pct(proposto)}%`, top: 44 }}>
            <div className="dot" />
            <div className="label">PROPOSTO</div>
            <div className="value">{formatCurrencyFull(proposto)}</div>
          </div>
        )}
      </div>
      <div style={{ marginTop: 8, display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
        {status && (
          <span className={`badge ${STATUS_CLASS[status] || ''}`}>{STATUS_LABEL[status] || status}</span>
        )}
        {acimaDaAbertura && (
          <span className="badge status-allow">✓ Preço acima da abertura</span>
        )}
      </div>
    </div>
  );
}
