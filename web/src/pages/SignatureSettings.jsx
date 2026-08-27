import { useEffect, useState } from 'react';
import { api, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';

// Fase 2.5 seção 6 — /configuracoes/assinatura. Só ADMINISTRADOR/DIRETOR
// pode alterar (RLS: signature_providers_write) — o formulário fica visível
// para leitura a qualquer perfil, mas a submissão será rejeitada pelo banco
// (403) para quem não tiver esse perfil, exatamente como o resto do projeto.
function emptyForm() {
  return {
    nome: '', tipo: 'ICP_BRASIL_HOMOLOGACAO_MOCK', papel: 'PRINCIPAL', ambiente: 'HOMOLOGACAO',
    api_url: '', api_key_ref: '', webhook_url: '', webhook_secret_ref: '', timeout_segundos: 30,
    politica_assinatura: 'ICP_BRASIL_QUALIFICADA',
  };
}

export default function SignatureSettings() {
  const { role } = useAuth();
  const canWrite = role === 'ADMINISTRADOR' || role === 'DIRETOR';
  const [providers, setProviders] = useState(null);
  const [error, setError] = useState(null);
  const [showForm, setShowForm] = useState(false);
  const [form, setForm] = useState(emptyForm());
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState(null);

  function load() {
    setProviders(null);
    api.signatures.providers().then(setProviders).catch((err) => setError(err.message));
  }
  useEffect(load, []);

  async function handleCreate(e) {
    e.preventDefault();
    setFormError(null);
    setSaving(true);
    try {
      await api.signatures.createProvider({ ...form, timeout_segundos: Number(form.timeout_segundos) });
      setForm(emptyForm());
      setShowForm(false);
      load();
    } catch (err) {
      setFormError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setSaving(false);
    }
  }

  async function toggleAtivo(p) {
    try {
      await api.signatures.updateProvider(p.id, { ativo: !p.ativo });
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    }
  }

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;

  return (
    <div className="page">
      <div className="page-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h1>Configuração de Assinatura Eletrônica</h1>
          <p>
            O OptiMon nunca implementa sua própria infraestrutura de certificação — só orquestra um provedor
            ICP-Brasil (troca de provedor sem tocar em contrato/proposta/banco/frontend). Só{' '}
            <strong>ADMINISTRADOR/DIRETOR</strong> pode alterar política/provedor.
          </p>
        </div>
        {canWrite && (
          <button className="btn btn-primary" onClick={() => setShowForm((s) => !s)}>{showForm ? 'Cancelar' : '+ Novo Provedor'}</button>
        )}
      </div>

      {showForm && (
        <div className="card" style={{ marginBottom: 16 }}>
          {formError && <div className="error-banner">{formError}</div>}
          <form onSubmit={handleCreate} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12 }}>
            <div className="field"><label>Nome *</label><input required value={form.nome} onChange={(e) => setForm({ ...form, nome: e.target.value })} placeholder="Ex.: Homologação Interna" /></div>
            <div className="field">
              <label>Tipo *</label>
              <select value={form.tipo} onChange={(e) => setForm({ ...form, tipo: e.target.value })}>
                <option value="ICP_BRASIL_HOMOLOGACAO_MOCK">ICP_BRASIL_HOMOLOGACAO_MOCK (simulado, só HOMOLOGAÇÃO)</option>
                <option value="ICP_BRASIL_PROVEDOR_EXTERNO">ICP_BRASIL_PROVEDOR_EXTERNO (integração real — ver limitações no relatório)</option>
              </select>
            </div>
            <div className="field">
              <label>Papel</label>
              <select value={form.papel} onChange={(e) => setForm({ ...form, papel: e.target.value })}>
                <option value="PRINCIPAL">PRINCIPAL</option>
                <option value="SECUNDARIO">SECUNDARIO</option>
              </select>
            </div>
            <div className="field">
              <label>Ambiente *</label>
              <select value={form.ambiente} onChange={(e) => setForm({ ...form, ambiente: e.target.value })}>
                <option value="HOMOLOGACAO">HOMOLOGACAO</option>
                <option value="PRODUCAO">PRODUCAO</option>
              </select>
            </div>
            <div className="field"><label>API URL</label><input value={form.api_url} onChange={(e) => setForm({ ...form, api_url: e.target.value })} /></div>
            <div className="field"><label>Nome da env var da API key</label><input value={form.api_key_ref} onChange={(e) => setForm({ ...form, api_key_ref: e.target.value })} placeholder="Ex.: SIGNATURE_API_KEY (nunca o valor real)" /></div>
            <div className="field"><label>Webhook URL</label><input value={form.webhook_url} onChange={(e) => setForm({ ...form, webhook_url: e.target.value })} /></div>
            <div className="field"><label>Nome da env var do webhook secret</label><input value={form.webhook_secret_ref} onChange={(e) => setForm({ ...form, webhook_secret_ref: e.target.value })} placeholder="Ex.: SIGNATURE_WEBHOOK_SECRET" /></div>
            <div className="field"><label>Timeout (segundos)</label><input type="number" min="1" value={form.timeout_segundos} onChange={(e) => setForm({ ...form, timeout_segundos: e.target.value })} /></div>
            <div style={{ gridColumn: 'span 3' }}>
              <button type="submit" className="btn btn-primary" disabled={saving}>{saving ? 'Salvando…' : 'Salvar provedor'}</button>
            </div>
          </form>
        </div>
      )}

      {!providers ? (
        <div className="card"><div className="spinner" /></div>
      ) : providers.length === 0 ? (
        <div className="card"><div className="empty-state">Nenhum provedor configurado ainda.</div></div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <div className="table-scroll">
            <table>
              <thead><tr><th>Nome</th><th>Tipo</th><th>Papel</th><th>Ambiente</th><th>Política</th><th>Timeout</th><th>Status</th></tr></thead>
              <tbody>
                {providers.map((p) => (
                  <tr key={p.id}>
                    <td>{p.nome}</td>
                    <td>{p.tipo}</td>
                    <td>{p.papel}</td>
                    <td><span className={`badge ${p.ambiente === 'PRODUCAO' ? 'status-block' : 'status-allow'}`}>{p.ambiente}</span></td>
                    <td>{p.politica_assinatura}</td>
                    <td>{p.timeout_segundos}s</td>
                    <td>
                      {canWrite ? (
                        <button className={`btn ${p.ativo ? 'btn-secondary' : 'btn-primary'}`} onClick={() => toggleAtivo(p)}>{p.ativo ? 'Ativo' : 'Inativo'}</button>
                      ) : (
                        <span className={`badge ${p.ativo ? 'status-allow' : 'status-block'}`}>{p.ativo ? 'Ativo' : 'Inativo'}</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
