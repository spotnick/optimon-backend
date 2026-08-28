import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';
import OnboardingModal from './OnboardingModal';

const ENV = import.meta.env.VITE_APP_ENVIRONMENT || 'DEMONSTRAÇÃO';

const NAV_ITEMS = [
  { to: '/', label: 'Dashboard', icon: '◧' },
  { to: '/cidades', label: 'Cidades & Infraestrutura', icon: '◈' },
  { to: '/simulacao', label: 'Nova Simulação', icon: '✎' },
  { to: '/propostas', label: 'Propostas', icon: '▤' },
  { to: '/proponentes', label: 'Proponentes', icon: '⌂' },
  { to: '/contratos', label: 'Contratos', icon: '§' },
  { to: '/relatorios', label: 'Relatórios', icon: '▦' },
  { to: '/alertas', label: 'Alertas', icon: '⚠' },
  { to: '/assinaturas', label: 'Assinaturas', icon: '✒' },
  { to: '/usuarios', label: 'Usuários', icon: '☺' },
  { to: '/configuracoes/assinatura', label: 'Config. de Assinatura', icon: '⚙' },
  { to: '/auditoria', label: 'Auditoria', icon: '≣' },
  { to: '/ajuda', label: 'Ajuda & Manuais', icon: '?' },
];

export default function Layout() {
  const { user, role, signOut } = useAuth();
  const navigate = useNavigate();

  async function handleSignOut() {
    await signOut();
    navigate('/login');
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="sidebar-brand">
          <img src="/branding/optimon-icon.svg" alt="" className="mark" width="32" height="32" />
          <div>
            <div className="name">OptiMon</div>
            <div className="tagline">Pricing &amp; Assets</div>
          </div>
        </div>
        <nav style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
          {NAV_ITEMS.map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.to === '/'}
              className={({ isActive }) => `nav-link${isActive ? ' active' : ''}`}
            >
              <span aria-hidden="true">{item.icon}</span>
              {item.label}
            </NavLink>
          ))}
        </nav>
        <div className="sidebar-footer">
          <div style={{ fontWeight: 700, color: '#dce6f2' }}>{user?.email}</div>
          <div>{role || '—'}</div>
          <button
            onClick={handleSignOut}
            className="btn btn-secondary"
            style={{ marginTop: 10, width: '100%', background: 'transparent', borderColor: 'rgba(255,255,255,0.2)', color: '#dce6f2' }}
          >
            Sair
          </button>
        </div>
      </aside>
      <div className="main-area">
        <header className="topbar">
          <div style={{ fontWeight: 700, fontFamily: 'var(--font-display)' }}>Optical Asset &amp; Pricing Management</div>
          <span className={`env-badge ${ENV.toUpperCase().startsWith('PROD') ? 'production' : 'demo'}`}>{ENV}</span>
        </header>
        <Outlet />
      </div>
      <OnboardingModal />
    </div>
  );
}
