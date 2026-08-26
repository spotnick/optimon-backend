import { useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { MANUALS } from '../content/manuals';
import { GLOSSARIO } from '../content/glossario';
import { FAQ } from '../content/faq';
import { useAuth } from '../context/AuthContext';

// OptiMon — Fase 2.4 (seção 1): Central de Ajuda (/ajuda) — 4 manuais por perfil,
// glossário, FAQ e busca única sobre todo esse conteúdo.

function normalize(s) {
  return (s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}

export default function Help() {
  const { role } = useAuth();
  const [params, setParams] = useSearchParams();
  const [query, setQuery] = useState('');
  const activeSlug = params.get('manual') || MANUALS.find((m) => m.publico === role)?.slug || MANUALS[0].slug;
  const [tab, setTab] = useState('manuais');

  const searchResults = useMemo(() => {
    const q = normalize(query.trim());
    if (!q) return null;
    const results = [];
    MANUALS.forEach((m) => {
      m.secoes.forEach((s) => {
        if (normalize(s.titulo).includes(q) || normalize(s.corpo).includes(q)) {
          results.push({ tipo: 'Manual', origem: m.titulo, titulo: s.titulo, trecho: s.corpo.slice(0, 180), onClick: () => { setTab('manuais'); setParams({ manual: m.slug }); } });
        }
      });
    });
    GLOSSARIO.forEach((g) => {
      if (normalize(g.termo).includes(q) || normalize(g.definicao).includes(q)) {
        results.push({ tipo: 'Glossário', origem: 'Glossário', titulo: g.termo, trecho: g.definicao, onClick: () => setTab('glossario') });
      }
    });
    FAQ.forEach((f) => {
      if (normalize(f.pergunta).includes(q) || normalize(f.resposta).includes(q)) {
        results.push({ tipo: 'FAQ', origem: 'FAQ', titulo: f.pergunta, trecho: f.resposta, onClick: () => setTab('faq') });
      }
    });
    return results;
  }, [query, setParams]);

  const activeManual = MANUALS.find((m) => m.slug === activeSlug) || MANUALS[0];

  return (
    <div className="page">
      <div className="page-header">
        <h1>Ajuda &amp; Manuais</h1>
        <p>Manuais operacionais por perfil, glossário de termos e perguntas frequentes.</p>
      </div>

      <div className="card" style={{ marginBottom: 24 }}>
        <div className="field" style={{ maxWidth: 480 }}>
          <label>Buscar em manuais, glossário e FAQ</label>
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="ex.: piso, arquivar, revenue share…" />
        </div>
      </div>

      {searchResults ? (
        <div className="card" style={{ padding: 0 }}>
          {searchResults.length === 0 ? (
            <div className="empty-state">Nenhum resultado para "{query}".</div>
          ) : (
            <div style={{ padding: '8px 0' }}>
              {searchResults.map((r, i) => (
                <button
                  key={i}
                  onClick={r.onClick}
                  style={{ display: 'block', width: '100%', textAlign: 'left', background: 'none', border: 'none', borderBottom: '1px solid var(--border)', padding: '14px 22px', cursor: 'pointer' }}
                >
                  <div style={{ fontSize: '0.72rem', color: 'var(--text-muted)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>{r.tipo} — {r.origem}</div>
                  <div style={{ fontWeight: 600, margin: '2px 0' }}>{r.titulo}</div>
                  <div style={{ fontSize: '0.85rem', color: 'var(--text-muted)' }}>{r.trecho}…</div>
                </button>
              ))}
            </div>
          )}
        </div>
      ) : (
        <>
          <div className="chip-row" style={{ marginBottom: 20 }}>
            <button className={`chip${tab === 'manuais' ? ' active' : ''}`} onClick={() => setTab('manuais')}>Manuais</button>
            <button className={`chip${tab === 'glossario' ? ' active' : ''}`} onClick={() => setTab('glossario')}>Glossário</button>
            <button className={`chip${tab === 'faq' ? ' active' : ''}`} onClick={() => setTab('faq')}>FAQ</button>
          </div>

          {tab === 'manuais' && (
            <div style={{ display: 'grid', gridTemplateColumns: '260px 1fr', gap: 24 }}>
              <div className="card" style={{ padding: 0, height: 'fit-content' }}>
                {MANUALS.map((m) => (
                  <button
                    key={m.slug}
                    onClick={() => setParams({ manual: m.slug })}
                    style={{
                      display: 'block', width: '100%', textAlign: 'left', background: m.slug === activeSlug ? 'var(--bg)' : 'none',
                      border: 'none', borderBottom: '1px solid var(--border)', padding: '14px 18px', cursor: 'pointer',
                      fontWeight: m.slug === activeSlug ? 700 : 500,
                    }}
                  >
                    {m.titulo}
                    {m.publico === role && <span className="badge status-allow" style={{ marginLeft: 8, fontSize: '0.65rem' }}>seu perfil</span>}
                  </button>
                ))}
              </div>
              <div className="card">
                <h2 className="section-title">{activeManual.titulo}</h2>
                <p style={{ color: 'var(--text-muted)', marginBottom: 20 }}>{activeManual.resumo}</p>
                {activeManual.secoes.map((s) => (
                  <div key={s.titulo} style={{ marginBottom: 22 }}>
                    <h3 style={{ fontSize: '1rem', marginBottom: 8 }}>{s.titulo}</h3>
                    {s.corpo.split('\n\n').map((p, i) => <p key={i} style={{ marginBottom: 8, lineHeight: 1.6 }}>{p}</p>)}
                  </div>
                ))}
              </div>
            </div>
          )}

          {tab === 'glossario' && (
            <div className="card" style={{ padding: 0 }}>
              {GLOSSARIO.map((g) => (
                <div key={g.termo} style={{ padding: '14px 22px', borderBottom: '1px solid var(--border)' }}>
                  <div style={{ fontWeight: 700 }}>{g.termo}</div>
                  <div style={{ color: 'var(--text-muted)', fontSize: '0.9rem' }}>{g.definicao}</div>
                </div>
              ))}
            </div>
          )}

          {tab === 'faq' && (
            <div className="card" style={{ padding: 0 }}>
              {FAQ.map((f) => (
                <div key={f.pergunta} style={{ padding: '14px 22px', borderBottom: '1px solid var(--border)' }}>
                  <div style={{ fontWeight: 700, marginBottom: 4 }}>{f.pergunta}</div>
                  <div style={{ color: 'var(--text-muted)', fontSize: '0.9rem' }}>{f.resposta}</div>
                </div>
              ))}
            </div>
          )}
        </>
      )}
    </div>
  );
}
