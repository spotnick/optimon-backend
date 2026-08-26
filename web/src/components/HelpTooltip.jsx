import { useState } from 'react';

// OptiMon — Fase 2.4 (seção 3): ajuda contextual — ícone "?" ao lado de campos-chave,
// com popover ao clique/hover explicando o conceito em 1-2 frases. Nunca navega pra fora
// da tela atual — texto suficiente pra decidir sem precisar abrir a Central de Ajuda.

export default function HelpTooltip({ text }) {
  const [open, setOpen] = useState(false);
  return (
    <span style={{ position: 'relative', display: 'inline-block', marginLeft: 6 }}>
      <button
        type="button"
        aria-label="Ajuda"
        onMouseEnter={() => setOpen(true)}
        onMouseLeave={() => setOpen(false)}
        onClick={() => setOpen((o) => !o)}
        style={{
          width: 16, height: 16, borderRadius: '50%', border: '1px solid var(--border)', background: 'var(--bg)',
          color: 'var(--text-muted)', fontSize: '0.65rem', lineHeight: '14px', cursor: 'help', padding: 0,
        }}
      >
        ?
      </button>
      {open && (
        <span
          role="tooltip"
          style={{
            position: 'absolute', zIndex: 20, bottom: '140%', left: '50%', transform: 'translateX(-50%)',
            width: 220, background: 'var(--ink, #1a2332)', color: '#fff', fontSize: '0.78rem', lineHeight: 1.4,
            padding: '8px 10px', borderRadius: 6, boxShadow: '0 4px 12px rgba(0,0,0,0.2)',
          }}
        >
          {text}
        </span>
      )}
    </span>
  );
}
