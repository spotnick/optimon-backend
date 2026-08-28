import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { api, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';

// Fase 2.5.3 (seção 10/18): /usuarios/saude — painel de diagnóstico de
// integridade entre auth.users e public.usuarios (GET /api/users/health,
// ver api/routes/users.js). Só ADMINISTRADOR — a própria API já recusa
// qualquer outro perfil (403), esta tela só evita nem tentar.
export default function UsersHealth() {
  const { role } = useAuth();
  const navigate = useNavigate();
  const isAdmin = role === 'ADMINISTRADOR';
  const [health, setHealth] = useState(null);
  const [error, setError] = useState(null);

  function load() {
    setHealth(null);
    setError(null);
    api.users.health().then(setHealth).catch((err) => setError(err instanceof ApiError ? err.message : 'Erro inesperado.'));
  }
  useEffect(load, []);

  if (!isAdmin) {
    return (
      <div className="page">
        <div className="error-banner">Só ADMINISTRADOR pode ver o diagnóstico de integridade de usuários.</div>
      </div>
    );
  }

  return (
    <div className="page">
      <div className="page-header">
        <h1>Integridade de Usuários</h1>
        <p>
          Compara <code>auth.users</code> (Supabase Auth) com <code>public.usuarios</code> (cadastro OptiMon) — a
          REGRA 1:1 do sistema (Fase 2.5.3, ver docs/RELATORIO_FASE253.md). Nada aqui altera dados; use{' '}
          <Link to="/usuarios">Usuários</Link> para recuperar um cadastro.
        </p>
      </div>

      {error && <div className="error-banner">{error}</div>}

      {!health ? (
        <div className="card"><div className="spinner" /></div>
      ) : (
        <>
          <div className="card" style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'center' }}>
              <div>
                <span className={`badge ${health.integro === false ? 'status-block' : health.integro === true ? 'status-allow' : ''}`} style={{ fontSize: '1rem', padding: '6px 14px' }}>
                  {health.integro === true && '✓ Integridade OK'}
                  {health.integro === false && '⚠ Inconsistências encontradas'}
                  {health.integro === null && 'Não verificável neste ambiente'}
                </span>
              </div>
              <div><strong>{health.total_perfis}</strong> perfil(is) em Usuários</div>
              <div><strong>{health.total_auth ?? '—'}</strong> identidade(s) em Auth</div>
              <div style={{ color: 'var(--text-muted, #666)', fontSize: '0.9em' }}>
                Verificado em {new Date(health.verificado_em).toLocaleString('pt-BR')}
              </div>
            </div>
            {health.auth_admin_disponivel === false && (
              <p style={{ marginBottom: 0 }}>
                A Auth Admin API não está configurada neste backend — não é possível comparar com{' '}
                <code>auth.users</code> aqui. Configure as credenciais de administração de identidade no ambiente do
                servidor (nunca no frontend) para habilitar esta comparação.
              </p>
            )}
            {health.auth_check_erro && (
              <p style={{ marginBottom: 0 }}>Falha ao consultar a Auth Admin API: {health.auth_check_erro}</p>
            )}
          </div>

          <div className="card" style={{ marginBottom: 16 }}>
            <h3 style={{ marginTop: 0 }}>Identidades Auth sem cadastro (Estado C)</h3>
            <p style={{ color: 'var(--text-muted, #666)' }}>
              Existe identidade no Supabase Auth (e-mail de convite já enviado), mas nenhum registro correspondente em
              Usuários — normalmente uma tentativa de convite anterior que falhou só na última etapa. Recuperável sem
              reenviar convite.
            </p>
            {health.identidades_auth_orfas.length === 0 ? (
              <div className="empty-state">Nenhuma encontrada.</div>
            ) : (
              <table>
                <thead><tr><th>E-mail</th><th>auth_user_id</th><th>Criado em</th><th></th></tr></thead>
                <tbody>
                  {health.identidades_auth_orfas.map((o) => (
                    <tr key={o.auth_user_id}>
                      <td>{o.email}</td>
                      <td><code>{o.auth_user_id}</code></td>
                      <td>{o.criado_em ? new Date(o.criado_em).toLocaleString('pt-BR') : '—'}</td>
                      <td>
                        <button className="btn btn-secondary" onClick={() => navigate('/usuarios')}>
                          Recuperar em Usuários
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>

          <div className="card">
            <h3 style={{ marginTop: 0 }}>Cadastros sem identidade Auth (Estado D)</h3>
            <p style={{ color: 'var(--text-muted, #666)' }}>
              Inconsistência crítica: existe um registro em Usuários sem identidade correspondente no Supabase Auth — não
              deveria acontecer sob a REGRA 1:1 do sistema. Requer recuperação administrativa (nunca criação automática de
              UUID novo).
            </p>
            {health.perfis_sem_auth.length === 0 ? (
              <div className="empty-state">Nenhum encontrado.</div>
            ) : (
              <table>
                <thead><tr><th>Nome</th><th>E-mail</th><th>id</th></tr></thead>
                <tbody>
                  {health.perfis_sem_auth.map((p) => (
                    <tr key={p.id}>
                      <td>{p.nome}</td>
                      <td>{p.email}</td>
                      <td><code>{p.id}</code></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </>
      )}
    </div>
  );
}
