import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext';

// OptiMon — Fase 2.4 (seção 3): onboarding de primeiro acesso — um modal simples,
// mostrado uma única vez por navegador (localStorage), com um resumo do que o app faz
// e um atalho direto para o manual do próprio perfil do usuário.
const STORAGE_KEY = 'optimon_onboarding_visto_v1';

export default function OnboardingModal() {
  const { role, user } = useAuth();
  const navigate = useNavigate();
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    if (!user) return;
    let jaViu = true;
    try { jaViu = localStorage.getItem(STORAGE_KEY) === '1'; } catch { /* storage indisponível — não bloqueia o app */ }
    if (!jaViu) setVisible(true);
  }, [user]);

  function dismiss(irParaAjuda) {
    try { localStorage.setItem(STORAGE_KEY, '1'); } catch { /* melhor esforço */ }
    setVisible(false);
    if (irParaAjuda) navigate('/ajuda');
  }

  if (!visible) return null;

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(10,15,25,0.55)', zIndex: 100, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div className="card" style={{ maxWidth: 480, width: '92%' }}>
        <h2 className="section-title">Bem-vindo(a) ao OptiMon</h2>
        <p style={{ marginBottom: 12, lineHeight: 1.6 }}>
          O OptiMon centraliza cadastro de infraestrutura de rede, simulação de preços e geração de propostas comerciais — tudo com trilha de auditoria completa e controle de acesso por perfil.
        </p>
        <p style={{ marginBottom: 20, lineHeight: 1.6, color: 'var(--text-muted)' }}>
          Seu perfil atual é <strong>{role || '—'}</strong>. Preparamos um manual com o passo a passo específico para o seu dia a dia em "Ajuda &amp; Manuais" — você pode acessá-lo a qualquer momento pelo menu lateral.
        </p>
        <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
          <button className="btn btn-secondary" onClick={() => dismiss(false)}>Explorar sozinho</button>
          <button className="btn btn-primary" onClick={() => dismiss(true)}>Ver meu manual</button>
        </div>
      </div>
    </div>
  );
}
