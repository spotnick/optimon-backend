import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, ApiError } from '../lib/api';

// Fase 3 (item 3.11): primeira tela dedicada a alertas individuais — antes
// desta fase o frontend só mostrava um contador agregado ("Alertas não
// resolvidos") no dashboard de Contratos, sem nenhuma forma de ver, entender
// ou resolver um alerta específico. `api.contracts.gerarAlertas()`/`alertas()`
// já existiam na API há tempo, mas eram código morto do ponto de vista da UI.

const SEVERIDADE_CLASS = { INFO: 'status-director', ATENCAO: 'status-discount', CRITICO: 'status-block' };

const TIPO_LABELS = {
  APROVACAO_PENDENTE: 'Proposta aguardando aprovação',
  ASSINATURA_PENDENTE: 'Proposta aguardando assinatura',
  CONTRATO_PENDENTE: 'Contrato aguardando assinatura',
  DOCUMENTO_RECUSADO: 'Documento recusado na assinatura',
  CONTRATO_PROXIMO_VENCIMENTO: 'Contrato próximo do vencimento',
  CAPACIDADE_80: 'Capacidade em 80%',
  CAPACIDADE_90: 'Capacidade em 90%',
  CAPACIDADE_100: 'Capacidade esgotada',
  FIM_CARENCIA: 'Fim da carência comercial',
  REAJUSTE: 'Reajuste anual pendente',
  ATIVO_NAO_DEVOLVIDO: 'Ativo pendente de devolução',
  OPERACAO_NAO_AUTORIZADA: 'Operação bloqueada',
};

export default function Alerts() {
  const [alertas, setAlertas] = useState(null);
  const [error, setError] = useState(null);
  const [statusFiltro, setStatusFiltro] = useState('false');
  const [gerando, setGerando] = useState(false);
  const [resolvendo, setResolvendo] = useState(null);
  const [actionError, setActionError] = useState(null);

  function load() {
    setAlertas(null);
    api.contracts.alertas({ resolvido: statusFiltro }).then(setAlertas).catch((err) => setError(err.message));
  }
  useEffect(load, [statusFiltro]);

  async function handleGerar() {
    setActionError(null);
    setGerando(true);
    try {
      await api.contracts.gerarAlertas();
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setGerando(false);
    }
  }

  async function handleResolver(id) {
    setActionError(null);
    setResolvendo(id);
    try {
      await api.contracts.resolverAlerta(id);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setResolvendo(null);
    }
  }

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;

  return (
    <div className="page">
      <div className="page-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h1>Alertas</h1>
          <p>
            Contratos, propostas, ativos e operações que precisam de atenção. Gerados sob demanda a partir do estado
            atual do sistema (não há job agendado nesta fase) — clique em "Gerar alertas" para atualizar.
          </p>
        </div>
        <div style={{ display: 'flex', gap: 12, alignItems: 'flex-end' }}>
          <div className="field" style={{ minWidth: 200 }}>
            <label>Mostrar</label>
            <select value={statusFiltro} onChange={(e) => setStatusFiltro(e.target.value)}>
              <option value="false">Não resolvidos</option>
              <option value="true">Resolvidos</option>
            </select>
          </div>
          <button className="btn btn-primary" disabled={gerando} onClick={handleGerar}>
            {gerando ? 'Gerando…' : 'Gerar alertas'}
          </button>
        </div>
      </div>

      {actionError && <div className="error-banner">{actionError}</div>}

      {!alertas ? (
        <div className="card"><div className="spinner" /></div>
      ) : alertas.length === 0 ? (
        <div className="card">
          <div className="empty-state">
            {statusFiltro === 'false' ? 'Nenhum alerta pendente. Clique em "Gerar alertas" para verificar o estado atual.' : 'Nenhum alerta resolvido ainda.'}
          </div>
        </div>
      ) : (
        <div className="card" style={{ padding: 0 }}>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Severidade</th>
                  <th>Tipo</th>
                  <th>Descrição</th>
                  <th>Contrato</th>
                  <th>Criado em</th>
                  {statusFiltro === 'true' && <th>Resolvido em</th>}
                  {statusFiltro === 'false' && <th></th>}
                </tr>
              </thead>
              <tbody>
                {alertas.map((a) => (
                  <tr key={a.id}>
                    <td><span className={`badge ${SEVERIDADE_CLASS[a.severidade] || ''}`}>{a.severidade}</span></td>
                    <td>{TIPO_LABELS[a.tipo] || a.tipo}</td>
                    <td>{a.titulo}{a.descricao ? <div style={{ color: 'var(--text-muted, #666)', fontSize: 13 }}>{a.descricao}</div> : null}</td>
                    <td>{a.contrato_id ? <Link className="link-tab" to={`/contratos/${a.contrato_id}`}>Ver contrato →</Link> : '—'}</td>
                    <td>{new Date(a.criado_em).toLocaleString('pt-BR')}</td>
                    {statusFiltro === 'true' && <td>{a.resolvido_em ? new Date(a.resolvido_em).toLocaleString('pt-BR') : '—'}</td>}
                    {statusFiltro === 'false' && (
                      <td>
                        <button className="btn btn-secondary" disabled={resolvendo === a.id} onClick={() => handleResolver(a.id)}>
                          {resolvendo === a.id ? 'Resolvendo…' : 'Marcar resolvido'}
                        </button>
                      </td>
                    )}
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
