import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import ArchiveModal from '../components/ArchiveModal';
import UserEditModal from '../components/UserEditModal';

// Fase 2.5.1 (seções 1-8): fluxo CORRIGIDO — nunca mais pede UUID de
// auth.users ao administrador. "+ Novo Usuário" cria a identidade no
// Supabase Auth (convite por e-mail) e completa o cadastro numa chamada só
// (POST /api/users/invite, ver api/routes/users.js e
// docs/ARQUITETURA.md seção 24 para a decisão de arquitetura por trás disso).
//
// Fase 2.5.3 (seção 14/18, ver docs/RELATORIO_FASE253.md): a tela nunca mais
// mostra "Usuário criado"/"Convite enviado" quando só a identidade Auth foi
// criada — agora o backend só retorna 201 quando as DUAS etapas (Auth +
// public.usuarios) realmente completaram (ver POST /invite). Quando o
// backend detecta uma identidade Auth órfã (Estado C — convite enviado numa
// tentativa anterior, cadastro nunca completado), a tela oferece "Recuperar
// Perfil" em vez de deixar o administrador travado em "already registered".
const PERFIS = ['ADMINISTRADOR', 'DIRETOR', 'COMERCIAL', 'FINANCEIRO', 'ENGENHARIA', 'AUDITOR'];
const MOTIVOS_DESATIVACAO = ['Desligamento', 'Mudança de função', 'Acesso indevido detectado', 'Solicitação do próprio usuário', 'Outro'];

function emptyForm(overrides = {}) {
  return { nome: '', email: '', telefone: '', cpf: '', cargo: '', departamento: '', perfil: 'COMERCIAL', observacoes: '', ...overrides };
}

const STATUS_BADGE = {
  ATIVO: 'status-allow',
  CONVITE_PENDENTE: 'status-discount',
  INATIVO: 'status-block',
  BLOQUEADO: 'status-block',
  ORFAO_SEM_PERFIL: 'status-block',
};
const STATUS_LABEL = {
  ATIVO: 'Ativo',
  CONVITE_PENDENTE: 'Convite pendente',
  INATIVO: 'Inativo',
  BLOQUEADO: 'Bloqueado',
  ORFAO_SEM_PERFIL: 'Identidade órfã (sem cadastro)',
};

export default function Users() {
  const { role } = useAuth();
  const isAdmin = role === 'ADMINISTRADOR';
  const [users, setUsers] = useState(null);
  const [error, setError] = useState(null);
  const [notice, setNotice] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState(emptyForm());
  const [recovery, setRecovery] = useState(null); // { email } quando o formulário está reconciliando um órfão (Estado C)
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState(null);
  const [formErrorState, setFormErrorState] = useState(null); // 'C_AUTH_ORFAO' etc — ver api/routes/users.js
  const [editTarget, setEditTarget] = useState(null);
  const [archiveTarget, setArchiveTarget] = useState(null); // { user, mode: 'archive'|'restore' }
  const [busyId, setBusyId] = useState(null);
  const [health, setHealth] = useState(null); // Fase 2.5.3 — indicador de integridade

  function load() {
    setUsers(null);
    api.users.list(isAdmin ? { include_orphans: 'true' } : {}).then(setUsers).catch((err) => setError(err.message));
  }
  useEffect(load, [isAdmin]);

  useEffect(() => {
    if (!isAdmin) return;
    api.users.health().then(setHealth).catch(() => setHealth(null));
  }, [isAdmin, users]);

  function startRecovery(email) {
    setRecovery({ email });
    setForm(emptyForm({ email }));
    setFormError(null);
    setFormErrorState(null);
    setNotice(null);
    setShowForm(true);
  }

  function cancelForm() {
    setShowForm(false);
    setRecovery(null);
    setForm(emptyForm());
    setFormError(null);
    setFormErrorState(null);
  }

  async function handleCreate(e) {
    e.preventDefault();
    setFormError(null);
    setFormErrorState(null);
    setNotice(null);
    setSaving(true);
    try {
      const created = recovery ? await api.users.reconcile(form) : await api.users.invite(form);
      setForm(emptyForm());
      setShowForm(false);
      setRecovery(null);
      setNotice(created.message || `Cadastro concluído para ${form.email}.`);
      load();
    } catch (err) {
      if (err instanceof ApiError) {
        setFormError(err.message);
        setFormErrorState(err.state);
      } else {
        setFormError('Erro inesperado.');
      }
    } finally {
      setSaving(false);
    }
  }

  async function handleResendInvite(u) {
    setBusyId(u.id);
    setNotice(null);
    try {
      const { message } = await api.users.resendInvite(u.id);
      setNotice(message);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusyId(null);
    }
  }

  async function handleResetAccess(u) {
    setBusyId(u.id);
    setNotice(null);
    try {
      const { message } = await api.users.resetAccess(u.id);
      setNotice(message);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusyId(null);
    }
  }

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;

  return (
    <div className="page">
      <div className="page-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h1>Usuários</h1>
          <p>RBAC de 6 perfis (ADMINISTRADOR/DIRETOR/COMERCIAL/FINANCEIRO/ENGENHARIA/AUDITOR) — aplicado sempre no servidor, nunca confiando no frontend.</p>
        </div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          {isAdmin && health && (
            <Link to="/usuarios/saude" className={`badge ${health.integro === false ? 'status-block' : health.integro === true ? 'status-allow' : ''}`} title="Diagnóstico de integridade Auth × Usuários">
              {health.integro === true && '✓ Integridade OK'}
              {health.integro === false && `⚠ ${health.identidades_auth_orfas.length + health.perfis_sem_auth.length} inconsistência(s)`}
              {health.integro === null && 'Integridade não verificável'}
            </Link>
          )}
          {isAdmin && (
            <button className="btn btn-primary" onClick={() => (showForm ? cancelForm() : setShowForm(true))}>
              {showForm ? 'Cancelar' : '+ Novo Usuário'}
            </button>
          )}
        </div>
      </div>

      {notice && <div className="card" style={{ marginBottom: 16, borderColor: 'var(--accent-success, #1a9c5e)' }}>{notice}</div>}

      {showForm && (
        <div className="card" style={{ marginBottom: 16 }}>
          {recovery ? (
            <p style={{ marginTop: 0, color: 'var(--text-muted, #666)' }}>
              Recuperando o cadastro de <strong>{recovery.email}</strong>: essa identidade já existe no Supabase Auth (o
              e-mail de convite já foi enviado numa tentativa anterior) — preencha os dados abaixo para completar o
              cadastro. Nenhum novo convite será enviado e nenhuma identidade nova será criada.
            </p>
          ) : (
            <p style={{ marginTop: 0, color: 'var(--text-muted, #666)' }}>
              O convite é enviado direto pelo Supabase Auth — o próprio usuário define a senha ao clicar no link recebido
              por e-mail. O OptiMon nunca armazena ou pede senha.
            </p>
          )}
          {formError && (
            <div className="error-banner">
              {formError}
              {formErrorState === 'C_AUTH_ORFAO' && !recovery && (
                <div style={{ marginTop: 8 }}>
                  <button type="button" className="btn btn-secondary" onClick={() => startRecovery(form.email)}>
                    Recuperar Perfil
                  </button>
                </div>
              )}
            </div>
          )}
          <form onSubmit={handleCreate} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
            <div className="field"><label>Nome *</label><input required value={form.nome} onChange={(e) => setForm({ ...form, nome: e.target.value })} /></div>
            <div className="field"><label>E-mail *</label><input required type="email" disabled={!!recovery} value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} /></div>
            <div className="field"><label>Telefone</label><input value={form.telefone} onChange={(e) => setForm({ ...form, telefone: e.target.value })} /></div>
            <div className="field"><label>CPF</label><input value={form.cpf} onChange={(e) => setForm({ ...form, cpf: e.target.value })} placeholder="11 dígitos" /></div>
            <div className="field"><label>Cargo</label><input value={form.cargo} onChange={(e) => setForm({ ...form, cargo: e.target.value })} /></div>
            <div className="field"><label>Departamento</label><input value={form.departamento} onChange={(e) => setForm({ ...form, departamento: e.target.value })} /></div>
            <div className="field">
              <label>Perfil *</label>
              <select value={form.perfil} onChange={(e) => setForm({ ...form, perfil: e.target.value })}>
                {PERFIS.map((p) => <option key={p} value={p}>{p}</option>)}
              </select>
            </div>
            <div className="field" style={{ gridColumn: 'span 3' }}><label>Observações</label><input value={form.observacoes} onChange={(e) => setForm({ ...form, observacoes: e.target.value })} /></div>
            <div style={{ gridColumn: 'span 3' }}>
              <button type="submit" className="btn btn-primary" disabled={saving}>
                {saving ? 'Enviando…' : recovery ? 'Recuperar Perfil' : 'Criar Usuário'}
              </button>
            </div>
          </form>
        </div>
      )}

      {!users ? (
        <div className="card"><div className="spinner" /></div>
      ) : users.length === 0 ? (
        <div className="card"><div className="empty-state">Nenhum usuário cadastrado ainda.</div></div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Nome</th><th>E-mail</th><th>Cargo</th><th>Perfil</th><th>Status</th><th>Último acesso</th>{isAdmin && <th>Ações</th>}
                </tr>
              </thead>
              <tbody>
                {users.map((u) => {
                  const isOrphan = u.id === null;
                  const statusKey = u.status_auth || (u.ativo ? null : 'INATIVO');
                  return (
                    <tr key={u.id || `orfao-${u.auth_user_id}`} style={isOrphan ? { opacity: 0.85 } : undefined}>
                      <td>{u.nome || <em>—</em>}</td>
                      <td>{u.email}</td>
                      <td>{u.cargo || '—'}</td>
                      <td>{u.perfil ? <span className="badge">{u.perfil}</span> : '—'}</td>
                      <td>
                        {statusKey ? (
                          <span className={`badge ${STATUS_BADGE[statusKey] || ''}`}>{STATUS_LABEL[statusKey] || statusKey}</span>
                        ) : (
                          <span className={`badge ${u.ativo ? 'status-allow' : 'status-block'}`}>{u.ativo ? 'Ativo' : 'Inativo'}</span>
                        )}
                      </td>
                      <td>{u.ultimo_acesso_em ? new Date(u.ultimo_acesso_em).toLocaleString('pt-BR') : '—'}</td>
                      {isAdmin && (
                        <td>
                          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                            {isOrphan ? (
                              <button className="btn btn-secondary" onClick={() => startRecovery(u.email)}>Recuperar Perfil</button>
                            ) : (
                              <>
                                <button className="btn btn-secondary" onClick={() => setEditTarget(u)}>Editar</button>
                                {u.ativo ? (
                                  <button className="btn btn-danger" onClick={() => setArchiveTarget({ user: u, mode: 'archive' })}>Desativar</button>
                                ) : (
                                  <button className="btn btn-primary" onClick={() => setArchiveTarget({ user: u, mode: 'restore' })}>Reativar</button>
                                )}
                                {statusKey === 'CONVITE_PENDENTE' && (
                                  <button className="btn btn-secondary" disabled={busyId === u.id} onClick={() => handleResendInvite(u)}>
                                    {busyId === u.id ? '…' : 'Reenviar convite'}
                                  </button>
                                )}
                                {u.ativo && statusKey !== 'CONVITE_PENDENTE' && (
                                  <button className="btn btn-secondary" disabled={busyId === u.id} onClick={() => handleResetAccess(u)}>
                                    {busyId === u.id ? '…' : 'Redefinir acesso'}
                                  </button>
                                )}
                              </>
                            )}
                          </div>
                        </td>
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {editTarget && (
        <UserEditModal
          user={editTarget}
          perfis={PERFIS}
          onCancel={() => setEditTarget(null)}
          onSave={async (patch) => {
            await api.users.update(editTarget.id, patch);
            setEditTarget(null);
            load();
          }}
        />
      )}

      {archiveTarget && (
        <ArchiveModal
          title={archiveTarget.mode === 'archive' ? 'Desativar usuário?' : 'Reativar usuário?'}
          subject={`${archiveTarget.user.nome} (${archiveTarget.user.email}). ${archiveTarget.mode === 'archive' ? 'O usuário perde acesso ao sistema imediatamente — o histórico e a auditoria são preservados, nada é apagado.' : 'O usuário volta a conseguir acessar o sistema com o mesmo login.'}`}
          mode={archiveTarget.mode}
          motivoOptions={MOTIVOS_DESATIVACAO}
          onCancel={() => setArchiveTarget(null)}
          onConfirm={async (body) => {
            if (archiveTarget.mode === 'archive') {
              const result = await api.users.deactivate(archiveTarget.user.id, { motivo: body.motivo });
              if (result.auth_warning) setNotice(result.auth_warning);
            } else {
              await api.users.reactivate(archiveTarget.user.id, { motivo: body.motivo });
            }
            setArchiveTarget(null);
            load();
          }}
        />
      )}
    </div>
  );
}
