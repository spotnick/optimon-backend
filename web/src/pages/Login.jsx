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
        <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 28, justifyContent: 'center' }}>
          <div
            style={{
              width: 40,
              height: 40,
              borderRadius: 10,
              background: 'linear-gradient(135deg, var(--color-accent-400), var(--color-primary-500))',
            }}
          />
          <div>
            <div style={{ fontFamily: 'var(--font-display)', fontWeight: 800, fontSize: '1.3rem', color: '#fff' }}>OptiMon</div>
            <div style={{ fontSize: '0.68rem', color: '#9db4d1', letterSpacing: '0.06em', textTransform: 'uppercase' }}>
              Optical Asset &amp; Pricing Management
            </div>
          </div>
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
