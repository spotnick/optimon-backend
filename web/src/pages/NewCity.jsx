import { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { api, ApiError } from '../lib/api';

export default function NewCity() {
  const navigate = useNavigate();
  const [nome, setNome] = useState('');
  const [uf, setUf] = useState('');
  const [codigoIbge, setCodigoIbge] = useState('');
  const [endereco, setEndereco] = useState('');
  const [kmRede, setKmRede] = useState('');
  const [observacoes, setObservacoes] = useState('');
  const [status, setStatus] = useState('ATIVA');
  const [error, setError] = useState(null);
  const [saving, setSaving] = useState(false);

  async function handleSubmit(e) {
    e.preventDefault();
    setError(null);
    if (!nome.trim() || !uf.trim() || !kmRede) {
      setError('Nome, UF e KM de rede são obrigatórios.');
      return;
    }
    setSaving(true);
    try {
      const { cidade_id } = await api.cities.create({
        nome: nome.trim(),
        uf: uf.trim().toUpperCase(),
        km_rede: Number(kmRede),
        codigo_ibge: codigoIbge.trim() || undefined,
        endereco: endereco.trim() || undefined,
        observacoes: observacoes.trim() || undefined,
        status,
      });
      // Fluxo da seção 22: cidade criada -> segue direto para cadastrar a infraestrutura
      // (POP, segmento, cabo, fibras, postes, PON) na mesma tela de edição.
      navigate(`/cidades/${cidade_id}/editar`);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao criar cidade. Tente novamente.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="page">
      <div className="page-header">
        <h1>Nova Cidade</h1>
        <p>Primeiro passo do fluxo: Cidade → POP → Segmento → Cabo → Fibras → Postes → PON → pronta para o Pricing Engine.</p>
      </div>

      <form className="card" onSubmit={handleSubmit} style={{ maxWidth: 640 }}>
        {error && <div className="error-banner" style={{ marginBottom: 16 }}>{error}</div>}
        <div className="form-grid">
          <div className="field">
            <label>Nome da cidade *</label>
            <input value={nome} onChange={(e) => setNome(e.target.value)} placeholder="ex.: Andirá" required />
          </div>
          <div className="field">
            <label>UF *</label>
            <input value={uf} onChange={(e) => setUf(e.target.value)} maxLength={2} placeholder="PR" required />
          </div>
          <div className="field">
            <label>Código IBGE</label>
            <input value={codigoIbge} onChange={(e) => setCodigoIbge(e.target.value)} placeholder="4101408" />
          </div>
          <div className="field">
            <label>KM de rede *</label>
            <input type="number" min="0" step="0.001" value={kmRede} onChange={(e) => setKmRede(e.target.value)} placeholder="10" required />
          </div>
          <div className="field">
            <label>Status</label>
            <select value={status} onChange={(e) => setStatus(e.target.value)}>
              <option value="ATIVA">Ativa</option>
              <option value="PLANEJADA">Planejada</option>
              <option value="INATIVA">Inativa</option>
            </select>
          </div>
          <div className="field" style={{ gridColumn: '1 / -1' }}>
            <label>Endereço/base</label>
            <input value={endereco} onChange={(e) => setEndereco(e.target.value)} placeholder="Sede/base operacional (opcional)" />
          </div>
          <div className="field" style={{ gridColumn: '1 / -1' }}>
            <label>Observações</label>
            <input value={observacoes} onChange={(e) => setObservacoes(e.target.value)} placeholder="Opcional" />
          </div>
        </div>
        <div style={{ display: 'flex', gap: 12, marginTop: 20 }}>
          <button type="submit" className="btn btn-primary" disabled={saving}>
            {saving ? 'Salvando…' : 'Salvar e cadastrar infraestrutura →'}
          </button>
          <Link to="/cidades" className="btn btn-secondary">Cancelar</Link>
        </div>
      </form>
    </div>
  );
}
