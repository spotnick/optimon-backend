import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabaseClient';

// OptiMon — página que recebe o redirecionamento do Supabase Auth depois de um convite
// de usuário ("Criar Usuário") ou de uma redefinição de acesso ("Redefinir acesso"), nos
// dois casos com um token temporário na própria URL (#access_token=...&type=invite|recovery).
//
// BUG REAL reportado pelo usuário (Fase 2.5.1, correção pós-entrega): essa página nunca
// existiu — o convite funcionava (o Supabase autenticava e devolvia um token válido),
// mas não havia nenhuma tela para receber esse retorno e deixar a pessoa definir a
// própria senha, então o link "funcionava" e terminava numa tela sem sentido. O client
// Supabase do frontend (ver src/lib/supabaseClient.js) já processa esse token
// automaticamente ao carregar (detectSessionInUrl, ligado por padrão) — o trabalho desta
// página é só: confirmar que uma sessão temporária ficou disponível, e oferecer o
// formulário de "defina sua senha" antes de liberar o resto do sistema.
const ENV = import.meta.env.VITE_APP_ENVIRONMENT || 'DEMONSTRAÇÃO';

function parseHashError() {
  const hash = window.location.hash?.replace(/^#/, '');
  if (!hash) return null;
  const params = new URLSearchParams(hash);
  const description = params.get('error_description');
  if (!description) return null;
  return decodeURIComponent(description.replace(/\+/g, ' '));
}

export default function DefinirSenha() {
  const navigate = useNavigate();
  // 'loading' | 'ready' | 'invalid' | 'saving' | 'done'
  const [status, setStatus] = useState('loading');
  const [linkError, setLinkError] = useState(null);
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [formError, setFormError] = useState(null);

  useEffect(() => {
    // Um link expirado/já usado chega com #error=...&error_description=... em vez de um
    // access_token — nesse caso nunca existirá sessão, então checamos isso primeiro para
    // mostrar uma mensagem específica em vez de ficar esperando algo que nunca vai vir.
    const hashError = parseHashError();
    if (hashError) {
      setLinkError(hashError);
      setStatus('invalid');
      return;
    }

    let cancelled = false;
    supabase.auth.getSession().then(({ data }) => {
      if (cancelled) return;
      setStatus(data.session ? 'ready' : 'invalid');
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, session) => {
      if (cancelled) return;
      if (session) setStatus((s) => (s === 'invalid' ? s : 'ready'));
    });
    return () => {
      cancelled = true;
      sub.subscription.unsubscribe();
    };
  }, []);

  async function handleSubmit(e) {
    e.preventDefault();
    setFormError(null);
    if (password.length < 8) {
      setFormError('A senha precisa ter pelo menos 8 caracteres.');
      return;
    }
    if (password !== confirmPassword) {
      setFormError('As senhas não coincidem.');
      return;
    }
    setStatus('saving');
    const { error } = await supabase.auth.updateUser({ password });
    if (error) {
      setFormError(error.message || 'Não foi possível salvar a senha. Tente novamente.');
      setStatus('ready');
      return;
    }
    setStatus('done');
    setTimeout(() => navigate('/', { replace: true }), 1500);
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

        <div className="card" style={{ padding: 32 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
            <h1 style={{ fontSize: '1.15rem' }}>Definir senha</h1>
            <span className={`env-badge ${ENV.toUpperCase().startsWith('PROD') ? 'production' : 'demo'}`}>{ENV}</span>
          </div>

          {status === 'loading' && <div className="spinner" style={{ margin: '20px auto' }} />}

          {status === 'invalid' && (
            <>
              <div className="error-banner">
                {linkError || 'Este link de convite ou de redefinição de senha é inválido ou já expirou.'}
              </div>
              <p style={{ color: 'var(--text-muted)', fontSize: '0.85rem', marginTop: 12 }}>
                Peça ao administrador para reenviar o convite (botão "Reenviar convite" em Usuários) ou solicite "Redefinir acesso" novamente — cada link só pode ser usado uma vez.
              </p>
              <a href="/login" className="btn btn-secondary" style={{ width: '100%', textAlign: 'center', display: 'block', marginTop: 16 }}>
                Voltar para o login
              </a>
            </>
          )}

          {(status === 'ready' || status === 'saving') && (
            <form onSubmit={handleSubmit}>
              <p style={{ color: 'var(--text-muted)', fontSize: '0.85rem', marginBottom: 18 }}>
                Escolha uma senha para acessar o OptiMon. Ela nunca é vista nem armazenada pelo sistema — fica só no Supabase Auth.
              </p>

              {formError && <div className="error-banner">{formError}</div>}

              <div className="field" style={{ marginBottom: 14 }}>
                <label htmlFor="password">Nova senha</label>
                <input
                  id="password"
                  type="password"
                  required
                  minLength={8}
                  autoComplete="new-password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="Mínimo de 8 caracteres"
                />
              </div>
              <div className="field" style={{ marginBottom: 20 }}>
                <label htmlFor="confirmPassword">Confirmar senha</label>
                <input
                  id="confirmPassword"
                  type="password"
                  required
                  minLength={8}
                  autoComplete="new-password"
                  value={confirmPassword}
                  onChange={(e) => setConfirmPassword(e.target.value)}
                  placeholder="Digite a senha novamente"
                />
              </div>

              <button type="submit" className="btn btn-primary" style={{ width: '100%' }} disabled={status === 'saving'}>
                {status === 'saving' ? 'Salvando…' : 'Salvar senha e entrar'}
              </button>
            </form>
          )}

          {status === 'done' && (
            <div className="card" style={{ background: '#eaf7ee', border: 'none' }}>
              Senha definida com sucesso. Entrando no OptiMon…
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
