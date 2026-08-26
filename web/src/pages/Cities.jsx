import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import ArchiveModal from '../components/ArchiveModal';

const STATUS_LABEL = { ATIVA: 'Ativa', INATIVA: 'Inativa', PLANEJADA: 'Planejada' };
const CAN_CREATE = ['ENGENHARIA', 'ADMINISTRADOR'];
const CAN_ARCHIVE = ['ENGENHARIA', 'ADMINISTRADOR'];
const CAN_RESTORE = ['ADMINISTRADOR', 'DIRETOR'];
const FILTROS = [
  { value: 'ATIVOS', label: 'Ativas' },
  { value: 'ARQUIVADOS', label: 'Arquivadas' },
  { value: 'TODOS', label: 'Todas' },
];

export default function Cities() {
  const { role } = useAuth();
  const [cities, setCities] = useState(null);
  const [error, setError] = useState(null);
  const [q, setQ] = useState('');
  const [uf, setUf] = useState('');
  const [status, setStatus] = useState('');
  const [filtro, setFiltro] = useState('ATIVOS');
  const [archiveTarget, setArchiveTarget] = useState(null);
  const [actionError, setActionError] = useState(null);

  const reload = useCallback(() => {
    api.cities.list(filtro).then(setCities).catch((err) => setError(err.message));
  }, [filtro]);

  useEffect(() => { setCities(null); reload(); }, [reload]);

  async function handleRestore(city) {
    setActionError(null);
    try {
      await api.cities.restore(city.cidade_id, {});
      reload();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro ao restaurar.');
    }
  }

  const ufs = useMemo(() => [...new Set((cities || []).map((c) => c.uf))].sort(), [cities]);

  const filtered = useMemo(() => {
    if (!cities) return [];
    const needle = q.trim().toLowerCase();
    return cities.filter((c) => {
      if (uf && c.uf !== uf) return false;
      if (status && c.status !== status) return false;
      if (!needle) return true;
      return (
        c.nome?.toLowerCase().includes(needle) ||
        c.uf?.toLowerCase().includes(needle) ||
        String(c.codigo_ibge || '').toLowerCase().includes(needle)
      );
    });
  }, [cities, q, uf, status]);

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;
  if (!cities) return <div className="page"><div className="spinner" /></div>;

  return (
    <div className="page">
      <div className="page-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h1>Cidades &amp; Infraestrutura</h1>
          <p>Onde está a sua infraestrutura, e quanto dá para monetizar dela — qualquer cidade, sem lógica fixa por nome.</p>
        </div>
        {CAN_CREATE.includes(role) && (
          <Link to="/cidades/nova" className="btn btn-primary">+ Nova Cidade</Link>
        )}
      </div>

      <div className="card" style={{ marginBottom: 20 }}>
        <div className="form-grid">
          <div className="field">
            <label>Buscar (cidade, UF ou código IBGE)</label>
            <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="ex.: Jussara, PR, 4112702" />
          </div>
          <div className="field">
            <label>UF</label>
            <select value={uf} onChange={(e) => setUf(e.target.value)}>
              <option value="">Todas</option>
              {ufs.map((u) => <option key={u} value={u}>{u}</option>)}
            </select>
          </div>
          <div className="field">
            <label>Status</label>
            <select value={status} onChange={(e) => setStatus(e.target.value)}>
              <option value="">Todos</option>
              <option value="ATIVA">Ativa</option>
              <option value="INATIVA">Inativa</option>
              <option value="PLANEJADA">Planejada</option>
            </select>
          </div>
        </div>
        <div className="chip-row" style={{ marginTop: 16 }}>
          {FILTROS.map((f) => (
            <button key={f.value} type="button" className={`chip ${filtro === f.value ? 'active' : ''}`} onClick={() => setFiltro(f.value)}>
              {f.label}
            </button>
          ))}
        </div>
      </div>

      {actionError && <div className="error-banner">{actionError}</div>}

      <div className="card" style={{ padding: 0 }}>
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Nome</th>
                <th>UF</th>
                <th className="num">KM de rede</th>
                <th className="num">Postes</th>
                <th className="num">FOs</th>
                <th className="num">FOs ociosas</th>
                <th className="num">POPs</th>
                <th className="num">Portas PON</th>
                <th className="num">Capacidade</th>
                <th className="num">Clientes ativos</th>
                <th className="num">Ocupação</th>
                <th>Status</th>
                <th>Ações</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((c) => (
                <tr key={c.cidade_id}>
                  <td style={{ fontWeight: 600 }}>{c.nome}</td>
                  <td>{c.uf}</td>
                  <td className="num">{Number(c.km_rede).toLocaleString('pt-BR')}</td>
                  <td className="num">{Number(c.postes_count).toLocaleString('pt-BR')}</td>
                  <td className="num">{Number(c.fibras_totais).toLocaleString('pt-BR')}</td>
                  <td className="num">{Number(c.fibras_ociosas).toLocaleString('pt-BR')}</td>
                  <td className="num">{c.pops_count}</td>
                  <td className="num">{c.portas_pon_totais}</td>
                  <td className="num">{Number(c.capacidade_maxima_clientes).toLocaleString('pt-BR')}</td>
                  <td className="num">{Number(c.clientes_ativos).toLocaleString('pt-BR')}</td>
                  <td className="num">{(Number(c.taxa_ocupacao || 0) * 100).toFixed(1)}%</td>
                  <td>
                    {c.arquivada ? (
                      <span className="badge status-archived">Arquivada</span>
                    ) : (
                      <span className={`badge status-${c.status === 'ATIVA' ? 'allow' : c.status === 'PLANEJADA' ? 'discount' : 'block'}`}>
                        {STATUS_LABEL[c.status] || c.status}
                      </span>
                    )}
                  </td>
                  <td>
                    <div className="row-actions">
                      <Link to={`/cidades/${c.cidade_id}`} className="link-tab" style={{ fontSize: '0.82rem' }}>
                        Visualizar
                      </Link>
                      {!c.arquivada && CAN_ARCHIVE.includes(role) && (
                        <Link to={`/cidades/${c.cidade_id}/editar`} className="link-tab" style={{ fontSize: '0.82rem' }}>
                          Editar
                        </Link>
                      )}
                      {!c.arquivada && CAN_ARCHIVE.includes(role) && (
                        <button type="button" className="btn btn-danger btn-sm" onClick={() => setArchiveTarget(c)}>
                          Arquivar
                        </button>
                      )}
                      {c.arquivada && CAN_RESTORE.includes(role) && (
                        <button type="button" className="btn btn-secondary btn-sm" onClick={() => handleRestore(c)}>
                          Restaurar
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
              {filtered.length === 0 && (
                <tr><td colSpan={13} style={{ color: 'var(--text-muted)' }}>Nenhuma cidade encontrada para esse filtro.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {archiveTarget && (
        <ArchiveModal
          title="Arquivar cidade?"
          subject={`${archiveTarget.nome} — ${archiveTarget.uf}. A cidade sai das listas ativas, do Dashboard e do Pricing Engine, mas todo o histórico é preservado. Se houver contrato, proposta, parceiro ou PON em operação vinculados, o arquivamento será bloqueado.`}
          mode="archive"
          onCancel={() => setArchiveTarget(null)}
          onConfirm={async (body) => {
            await api.cities.archive(archiveTarget.cidade_id, body);
            setArchiveTarget(null);
            reload();
          }}
        />
      )}
    </div>
  );
}
