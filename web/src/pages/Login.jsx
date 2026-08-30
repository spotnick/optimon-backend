import { useState } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';

const ENV = import.meta.env.VITE_APP_ENVIRONMENT || 'DEMONSTRAÇÃO';

export default function Login() {
  const { signIn } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      await signIn(email, password);
      const dest = location.state?.from?.pathname || '/';
      navigate(dest, { replace: true });
    } catch (err) {
      setError(err.message || 'Não foi possível entrar. Verifique e-mail e senha.');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div
      style={{
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        background: 'radial-gradient(circle at 20% 20%, var(--color-primary-700), var(--gray-950) 65%)',
        padding: 20,
      }}
    >
      <div style={{ width: '100%', maxWidth: 400 }}>
        {/* Fase 3.9 (item 1): logo OFICIAL (pacote fornecido pelo usuário, extraído de
            IdentidadeVisual.png — ver docs/branding/). PNG, não SVG: o vetor original
            não foi disponibilizado (README-BRANDING.txt do pacote) — trocar por SVG
            quando o vetor oficial existir, sem alterar a arte. */}
        <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 28 }}>
          <img
            src="/branding/optimon-logo-lockup-dark.png"
            alt="OptiMon — Optical Asset & Pricing Management"
            width="681"
            height="195"
            style={{ width: 220, height: 'auto' }}
          />
        </div>

        <form onSubmit={handleSubmit} className="card" style={{ padding: 32 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
            <h1 style={{ fontSize: '1.15rem' }}>Entrar</h1>
            <span className={`env-badge ${ENV.toUpperCase().startsWith('PROD') ? 'production' : 'demo'}`}>{ENV}</span>
          </div>

          {error && <div className="error-banner">{error}</div>}

          <div className="field" style={{ marginBottom: 14 }}>
            <label htmlFor="email">E-mail</label>
            <input
              id="email"
              type="email"
              required
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="voce@empresa.com.br"
            />
          </div>
          <div className="field" style={{ marginBottom: 20 }}>
            <label htmlFor="password">Senha</label>
            <input
              id="password"
              type="password"
              required
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="••••••••"
            />
          </div>

          <button type="submit" className="btn btn-primary" style={{ width: '100%' }} disabled={loading}>
            {loading ? 'Entrando…' : 'Entrar'}
          </button>

          <div style={{ textAlign: 'center', marginTop: 16 }}>
            <a href="#" style={{ fontSize: '0.85rem', color: 'var(--text-muted)' }} onClick={(e) => e.preventDefault()}>
              Esqueci minha senha
            </a>
          </div>
        </form>
      </div>
    </div>
  );
}
