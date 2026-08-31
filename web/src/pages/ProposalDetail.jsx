import { useCallback, useEffect, useMemo, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { api, apiDownload, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import { formatCurrencyFull } from '../components/charts/chartUtils';
import HelpTooltip from '../components/HelpTooltip';

const STATUS_CLASS = {
  RASCUNHO: 'status-discount',
  EM_APROVACAO: 'status-director',
  APROVADA: 'status-allow',
  ENVIADA: 'status-allow',
  EM_NEGOCIACAO: 'status-director',
  ACEITA: 'status-allow',
  RECUSADA: 'status-block',
  EXPIRADA: 'status-block',
  CANCELADA: 'status-block',
  EM_ASSINATURA: 'status-director',
  ASSINADA: 'status-allow',
  CONTRATO_GERADO: 'status-allow',
};

const STATUS_LABELS = {
  RASCUNHO: 'Rascunho', EM_APROVACAO: 'Em Aprovação', APROVADA: 'Aprovada', ENVIADA: 'Enviada',
  EM_NEGOCIACAO: 'Em Negociação', ACEITA: 'Aceita', RECUSADA: 'Recusada', EXPIRADA: 'Expirada', CANCELADA: 'Cancelada',
  EM_ASSINATURA: 'Em Aceite/Assinatura', ASSINADA: 'Assinada', CONTRATO_GERADO: 'Contrato Gerado',
};

const MUDAR_STATUS_OPCOES = ['ENVIADA', 'EM_NEGOCIACAO', 'ACEITA', 'EXPIRADA', 'CANCELADA'];

// Cenários de sensibilidade (±15% de volume) e projeções de horizonte — mesma lógica de
// proposalDocumentModel.js no backend, reimplementada aqui só para a pré-visualização em
// tela (o documento oficial exportado em PDF/DOCX é sempre gerado no servidor).
function buildScenarios(snapshot) {
  const clientesBase = Number(snapshot?.clientes) || 0;
  const arpu = Number(snapshot?.arpu) || 0;
  const floor = Number(snapshot?.floor) || 0;
  const revenueSharePct = Number(snapshot?.revenue_share_pct) || 0;
  return [
    { nome: 'Conservador', fator: 0.85 },
    { nome: 'Base', fator: 1.0 },
    { nome: 'Agressivo', fator: 1.15 },
  ].map((c) => {
    const clientes = Math.round(clientesBase * c.fator);
    const faturamento = Math.round(clientes * arpu * 100) / 100;
    const revenueShareValue = Math.round(faturamento * revenueSharePct * 100) / 100;
    const totalPayable = c.nome === 'Base' && snapshot?.total_payable != null ? Number(snapshot.total_payable) : Math.max(floor, revenueShareValue);
    const partnerRevenue = Math.round((faturamento - totalPayable) * 100) / 100;
    return { nome: c.nome, clientes, faturamento, total_payable: totalPayable, partner_revenue: partnerRevenue };
  });
}

function buildProjections(snapshot, prazoMeses) {
  const totalMensal = Number(snapshot?.total_payable) || 0;
  const receitaMensal = Number(snapshot?.faturamento) || 0;
  const minimo = Number(prazoMeses) || 48;
  return [12, 36, 48, 60].map((meses) => ({
    meses,
    rotulo: meses === minimo ? `${meses}m (mín. contratual)` : meses > minimo ? `${meses}m (projeção)` : `${meses}m`,
    receita_bruta_acumulada: Math.round(receitaMensal * meses * 100) / 100,
    total_pago_acumulado: Math.round(totalMensal * meses * 100) / 100,
  }));
}

function BarChart({ title, labels, values }) {
  const max = Math.max(...values.map((v) => Number(v) || 0), 1);
  return (
    <div className="card">
      <h3 className="section-title" style={{ fontSize: '0.95rem' }}>{title}</h3>
      <div style={{ display: 'flex', alignItems: 'flex-end', gap: 16, height: 160, padding: '8px 4px' }}>
        {values.map((v, i) => {
          const h = max > 0 ? (Math.max(Number(v) || 0, 0) / max) * 130 : 0;
          return (
            <div key={i} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', flex: 1 }}>
              <div style={{ fontSize: '0.72rem', marginBottom: 4, fontWeight: 600 }}>{formatCurrencyFull(v)}</div>
              <div style={{ width: '70%', height: h, background: 'var(--accent, #0e6e55)', borderRadius: '3px 3px 0 0' }} />
              <div style={{ fontSize: '0.72rem', color: 'var(--text-muted)', marginTop: 6 }}>{labels[i]}</div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

export default function ProposalDetail() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { role } = useAuth();

  const [modo, setModo] = useState('INTERNA');
  const [proposta, setProposta] = useState(null);
  const [versions, setVersions] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [motivo, setMotivo] = useState('');
  const [novoStatus, setNovoStatus] = useState(MUDAR_STATUS_OPCOES[0]);
  const [confirmCriarContrato, setConfirmCriarContrato] = useState(false);

  const canApprove = role === 'DIRETOR' || role === 'ADMINISTRADOR';

  const load = useCallback(() => {
    setError(null);
    const req = modo === 'INTERNA' ? api.proposals.get(id) : api.proposals.getPublic(id);
    req.then(setProposta).catch((err) => setError(err.message));
    api.proposals.versions(id).then(setVersions).catch(() => {});
  }, [id, modo]);

  useEffect(() => { load(); }, [load]);

  // Fase 3.10 (Problema 2): BUG REAL corrigido — em modo EXTERNA, `proposta` vem de
  // GET /:id/public (pricing_proposal_external_view), que devolve um objeto PLANO (sem
  // chave `snapshot`) com campos comerciais já filtrados no backend — nunca `total_payable`
  // (esse nome só existe no modo Interna). O código antigo fazia
  // `proposta?.snapshot || (modo==='EXTERNA' ? proposta : null)`, então em modo Externa
  // `snapshot` virava o objeto `proposta` inteiro — e `snapshot.total_payable` sempre
  // `undefined`, quebrando o KPI "Total mensal" e as tabelas de Cenários/Projeções (que
  // leem snapshot.total_payable/floor). A correção monta um objeto no MESMO formato que
  // buildScenarios/buildProjections esperam, usando os campos reais devolvidos pela view
  // externa — `total_payable` é sempre igual a `preco_proposto` desde a correção da Fase
  // 3.01 (migration 20260922090000: "total_payable agora É preco_proposto"), então usar
  // preco_proposto aqui é o valor correto, nunca um número inventado. `floor` fica
  // ausente de propósito — a view externa nunca o expõe (dado interno de governança).
  const snapshot = modo === 'EXTERNA'
    ? (proposta ? {
        clientes: proposta.clientes,
        arpu: proposta.arpu,
        faturamento: proposta.faturamento,
        preco_proposto: proposta.preco_proposto,
        total_payable: proposta.preco_proposto,
        revenue_share_pct: proposta.revenue_share_pct,
        floor: null,
      } : null)
    : (proposta?.snapshot || null);
  const prazoMeses = proposta?.prazo_meses || 48;
  const scenarios = useMemo(() => (snapshot ? buildScenarios(snapshot) : []), [snapshot]);
  const projections = useMemo(() => (snapshot ? buildProjections(snapshot, prazoMeses) : []), [snapshot, prazoMeses]);

  async function runAction(fn, successMsg) {
    setBusy(true);
    setError(null);
    try {
      await fn();
      setMotivo('');
      load();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao processar ação.');
    } finally {
      setBusy(false);
    }
  }

  async function handleExport(formato) {
    setBusy(true);
    setError(null);
    try {
      const { blob, fileName } = await apiDownload(api.proposals.exportPath(id, formato, modo === 'EXTERNA' ? 'externa' : 'interna'));
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = fileName; document.body.appendChild(a); a.click(); a.remove();
      URL.revokeObjectURL(url);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao exportar documento.');
    } finally {
      setBusy(false);
    }
  }

  if (error && !proposta) return <div className="page"><div className="error-banner">{error}</div></div>;
  if (!proposta) return <div className="page"><div className="spinner" /></div>;

  const numero = proposta.numero;
  const status = proposta.status;
  const parceiroNome = proposta.parceiro_nome_capa || proposta.parceiro_nome_fantasia || proposta.parceiro_razao_social || 'A definir';

  return (
    <div className="page">
      <div className="page-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h1>Proposta {numero} <span style={{ fontWeight: 400, fontSize: '0.6em', color: 'var(--text-muted)' }}>V{proposta.numero_versao || 1}</span></h1>
          <p>{proposta.cidade_nome} — {proposta.cidade_uf} · Parceiro: {parceiroNome}</p>
        </div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <span className={`badge ${STATUS_CLASS[status] || ''}`}>{STATUS_LABELS[status] || status}</span>
          <div className="chip-row">
            <button className={`chip${modo === 'INTERNA' ? ' active' : ''}`} onClick={() => setModo('INTERNA')}>Interna</button>
            <button className={`chip${modo === 'EXTERNA' ? ' active' : ''}`} onClick={() => setModo('EXTERNA')}>Externa (parceiro)</button>
          </div>
        </div>
      </div>

      {error && <div className="error-banner">{error}</div>}

      {/* Fase 3.10 (Problema 2, seção 2.3): exportar PDF/DOCX precisa continuar disponível
          nos DOIS modos — é assim que o comercial gera o documento para mandar ao
          parceiro a partir do próprio modo Externa Parceiro, sem precisar voltar pro
          Interna. As demais ações (aprovar/rejeitar/duplicar/criar contrato/mudar status)
          são exclusivamente internas — nunca aparecem no modo Externa Parceiro. */}
      {modo === 'EXTERNA' && (
        <div style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
          <button className="btn btn-secondary" disabled={busy} onClick={() => handleExport('PDF')}>Exportar PDF (comercial)</button>
          <button className="btn btn-secondary" disabled={busy} onClick={() => handleExport('DOCX')}>Exportar DOCX (comercial)</button>
        </div>
      )}

      {modo === 'INTERNA' && (
      <>
      <div className="card" style={{ marginBottom: 24 }}>
        <h2 className="section-title">Ações</h2>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 12 }}>
          <button className="btn btn-secondary" disabled={busy} onClick={() => handleExport('PDF')}>Exportar PDF</button>
          <button className="btn btn-secondary" disabled={busy} onClick={() => handleExport('DOCX')}>Exportar DOCX</button>
          <button className="btn btn-secondary" disabled={busy} onClick={() => runAction(() => api.proposals.duplicate(id, { motivo }), 'duplicada')}>Duplicar Proposta</button>
          <button className="btn btn-secondary" disabled={busy} onClick={() => runAction(() => api.proposals.newVersion(id, { motivo }), 'nova versão')}>Nova Versão</button>
          {canApprove && ['RASCUNHO', 'EM_APROVACAO'].includes(status) && (
            <button className="btn btn-primary" disabled={busy} onClick={() => runAction(() => api.proposals.approve(id, { motivo }))}>Aprovar</button>
          )}
          {canApprove && !['ACEITA', 'RECUSADA', 'EXPIRADA', 'CANCELADA'].includes(status) && (
            <button className="btn btn-danger" disabled={busy} onClick={() => runAction(() => api.proposals.reject(id, { motivo }))}>Rejeitar</button>
          )}
          {/* Fase 3.10 (Problema 3): botão "CRIAR CONTRATO" — reaproveita 100% a mesma
              regra de negócio já existente e testada (app.gerar_contrato_de_proposta só
              aceita proposta ASSINADA, nunca ASSINADA->duplicar) — só ganhou rótulo novo e
              uma confirmação com checklist legível antes de disparar. */}
          {status === 'ASSINADA' && !proposta.contrato_id && (
            <button className="btn btn-primary" disabled={busy} onClick={() => setConfirmCriarContrato(true)}>
              CRIAR CONTRATO
            </button>
          )}
          {proposta.contrato_id && (
            <Link className="btn btn-secondary" to={`/contratos/${proposta.contrato_id}`}>ABRIR CONTRATO →</Link>
          )}
          {['ACEITA', 'ASSINADA'].includes(status) && (
            <Link className="btn btn-secondary" to="/assinaturas">Ir para Assinaturas</Link>
          )}
        </div>
        {canApprove && !['ACEITA', 'RECUSADA', 'EXPIRADA', 'CANCELADA'].includes(status) && (
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
            <select value={novoStatus} onChange={(e) => setNovoStatus(e.target.value)}>
              {MUDAR_STATUS_OPCOES.map((s) => <option key={s} value={s}>{STATUS_LABELS[s]}</option>)}
            </select>
            <button className="btn btn-secondary" disabled={busy} onClick={() => runAction(() => api.proposals.changeStatus(id, { status: novoStatus, motivo }))}>Mudar status</button>
          </div>
        )}
        <div className="field" style={{ marginTop: 12, maxWidth: 480 }}>
          <label>Motivo (obrigatório para rejeitar/cancelar; exigido em aprovação abaixo do piso)</label>
          <input value={motivo} onChange={(e) => setMotivo(e.target.value)} placeholder="Justificativa…" />
        </div>

        {/* Fase 3.10 (Problema 3, seção 3.4): vínculo bidirecional visível — o lado do
            contrato mostra "Proposta de origem: PROP-XXXX" (ver ContractDetail.jsx). */}
        {proposta.contrato_id && (
          <p style={{ marginTop: 12, fontSize: '0.9rem', color: 'var(--text-muted)' }}>
            Contrato vinculado: <strong>{proposta.contrato_numero || proposta.contrato_id}</strong>
          </p>
        )}
      </div>

      {confirmCriarContrato && (
        <div className="card" style={{ marginBottom: 24, borderColor: 'var(--accent, #0e6e55)' }}>
          <h2 className="section-title">Confirmar criação do contrato</h2>
          <p style={{ marginBottom: 8 }}>Ao confirmar, o sistema irá, nesta ordem (seção 3.3 do fluxo Proposta → Contrato):</p>
          <ul style={{ marginBottom: 12, paddingLeft: 20, lineHeight: 1.7 }}>
            <li>Verificar que a proposta está ASSINADA e ainda sem contrato vinculado (bloqueado automaticamente pelo servidor caso contrário)</li>
            <li>Verificar parceiro, cidade, prazo (mínimo contratual de 48 meses, salvo exceção autorizada) e dados econômicos da proposta</li>
            <li>Criar o registro do contrato e vinculá-lo permanentemente a esta proposta (nos dois sentidos)</li>
            <li>Transportar automaticamente os dados aprovados (parceiro, cidade, prazo, revenue share, mensalidade mínima) — nunca um contrato vazio</li>
            <li>Disponibilizar a minuta (PDF/DOCX) imediatamente após a criação</li>
            <li>Registrar o evento na auditoria (CONTRACT_GENERATE + CONTRACT_MINUTA_GENERATED)</li>
          </ul>
          <div style={{ display: 'flex', gap: 8 }}>
            <button
              className="btn btn-primary"
              disabled={busy}
              onClick={() => {
                setConfirmCriarContrato(false);
                runAction(async () => { const c = await api.contracts.generate({ proposta_id: id }); navigate(`/contratos/${c.id}`); });
              }}
            >
              Confirmar e criar contrato
            </button>
            <button className="btn btn-secondary" disabled={busy} onClick={() => setConfirmCriarContrato(false)}>Cancelar</button>
          </div>
        </div>
      )}
      </>
      )}

      {modo === 'INTERNA' && (
      <>
      <div className="card-grid" style={{ marginBottom: 24 }}>
        <div className="card kpi-card">
          <div className="kpi-label">Preço proposto</div>
          <div className="kpi-value">{formatCurrencyFull(snapshot?.preco_proposto)}</div>
        </div>
        <div className="card kpi-card">
          <div className="kpi-label">Faturamento mensal estimado</div>
          <div className="kpi-value">{formatCurrencyFull(snapshot?.faturamento)}</div>
        </div>
        <div className="card kpi-card">
          <div className="kpi-label">Total mensal (OptiMon)</div>
          <div className="kpi-value">{formatCurrencyFull(snapshot?.total_payable)}</div>
        </div>
        <div className="card kpi-card">
          <div className="kpi-label">Piso (uso interno) <HelpTooltip text="Valor mínimo absoluto que a OptiMon aceita cobrar — nunca deve ser oferecido ao parceiro sem autorização formal." /></div>
          <div className="kpi-value">{formatCurrencyFull(snapshot?.floor)}</div>
        </div>
        <div className="card kpi-card">
          <div className="kpi-label">Validade</div>
          <div className="kpi-value">{proposta.validade_dias} dias</div>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 24, padding: 0 }}>
        <div style={{ padding: '20px 22px 0' }}><h2 className="section-title">Cenários (Conservador / Base / Agressivo)</h2></div>
        <div className="table-scroll">
          <table>
            <thead><tr><th>Cenário</th><th className="num">Clientes</th><th className="num">Faturamento</th><th className="num">Total OptiMon</th><th className="num">Receita Parceiro</th></tr></thead>
            <tbody>
              {scenarios.map((s) => (
                <tr key={s.nome}>
                  <td style={{ fontWeight: 600 }}>{s.nome}</td>
                  <td className="num">{s.clientes.toLocaleString('pt-BR')}</td>
                  <td className="num">{formatCurrencyFull(s.faturamento)}</td>
                  <td className="num">{formatCurrencyFull(s.total_payable)}</td>
                  <td className="num">{formatCurrencyFull(s.partner_revenue)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 24, padding: 0 }}>
        <div style={{ padding: '20px 22px 0' }}><h2 className="section-title">Projeções (12 / 36 / 48 / 60 meses)</h2></div>
        <div className="table-scroll">
          <table>
            <thead><tr><th>Horizonte</th><th className="num">Receita bruta acumulada</th><th className="num">Total pago à OptiMon</th></tr></thead>
            <tbody>
              {projections.map((p) => (
                <tr key={p.meses}>
                  <td style={{ fontWeight: 600 }}>{p.rotulo}</td>
                  <td className="num">{formatCurrencyFull(p.receita_bruta_acumulada)}</td>
                  <td className="num">{formatCurrencyFull(p.total_pago_acumulado)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className="card-grid" style={{ gridTemplateColumns: '1fr 1fr', marginBottom: 24 }}>
        <BarChart title="Receita Acumulada por Horizonte" labels={projections.map((p) => `${p.meses}m`)} values={projections.map((p) => p.receita_bruta_acumulada)} />
        <BarChart title="Faturamento Mensal por Cenário" labels={scenarios.map((s) => s.nome)} values={scenarios.map((s) => s.faturamento)} />
      </div>

      {versions && versions.length > 1 && (
        <div className="card" style={{ marginBottom: 24, padding: 0 }}>
          <div style={{ padding: '20px 22px 0' }}><h2 className="section-title">Histórico de Versões</h2></div>
          <div className="table-scroll">
            <table>
              <thead><tr><th>Versão</th><th>Status</th><th>Criado em</th><th></th></tr></thead>
              <tbody>
                {versions.map((v) => (
                  <tr key={v.id}>
                    <td>V{v.numero_versao}</td>
                    <td><span className={`badge ${STATUS_CLASS[v.status] || ''}`}>{STATUS_LABELS[v.status] || v.status}</span></td>
                    <td>{new Date(v.criado_em).toLocaleString('pt-BR')}</td>
                    <td>{v.id !== id ? <Link className="link-tab" to={`/propostas/${v.id}`}>Abrir →</Link> : '(atual)'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
      </>
      )}

      {/* Fase 3.10 (Problema 2): modo Externa Parceiro — documento comercial autônomo,
          visualmente distinto da tela administrativa (identidade OptiMon já existente:
          mesma logo/tipografia/cards — "não criar identidade visual nova"). Nunca mostra
          margem/piso/preço recomendado/régua de negociação/parecer interno/governança/
          auditoria — a própria view do backend (pricing_proposal_external_view) já não
          devolve esses campos, então não há como este bloco vazar o que nunca recebeu. */}
      {modo === 'EXTERNA' && (
        <div className="card" style={{ marginBottom: 24, padding: 0, overflow: 'hidden', background: '#fff' }}>
          <div style={{ padding: '28px 32px', borderBottom: '1px solid var(--border)', display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 16 }}>
            <img src="/branding/optimon-logo-lockup.png" alt="OptiMon" style={{ height: 40 }} />
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: '0.75rem', letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--text-muted)' }}>Proposta Comercial</div>
              <div style={{ fontSize: '1.1rem', fontWeight: 700 }}>{numero} <span style={{ fontWeight: 400, fontSize: '0.8rem', color: 'var(--text-muted)' }}>V{proposta.numero_versao || 1}</span></div>
            </div>
          </div>

          <div style={{ padding: '28px 32px' }}>
            <div className="card-grid" style={{ marginBottom: 24 }}>
              <div className="card kpi-card">
                <div className="kpi-label">Parceiro</div>
                <div className="kpi-value" style={{ fontSize: '1.1rem' }}>{parceiroNome}</div>
                {proposta.parceiro_cargo_contato && <div className="kpi-sub">{proposta.parceiro_cargo_contato}</div>}
              </div>
              <div className="card kpi-card">
                <div className="kpi-label">Cidade</div>
                <div className="kpi-value" style={{ fontSize: '1.1rem' }}>{proposta.cidade_nome} — {proposta.cidade_uf}</div>
                {proposta.pop_nome && <div className="kpi-sub">POP: {proposta.pop_nome}</div>}
              </div>
              <div className="card kpi-card">
                <div className="kpi-label">Prazo contratual</div>
                <div className="kpi-value" style={{ fontSize: '1.1rem' }}>{proposta.prazo_meses ? `${proposta.prazo_meses} meses` : '—'}</div>
              </div>
              <div className="card kpi-card">
                <div className="kpi-label">Validade da proposta</div>
                <div className="kpi-value" style={{ fontSize: '1.1rem' }}>{proposta.validade_dias} dias</div>
              </div>
            </div>

            <h2 className="section-title">Infraestrutura e capacidade</h2>
            <div className="card-grid" style={{ marginBottom: 24 }}>
              <div className="card kpi-card">
                <div className="kpi-label">Clientes (capacidade proposta)</div>
                <div className="kpi-value">{snapshot?.clientes ? Number(snapshot.clientes).toLocaleString('pt-BR') : '—'}</div>
              </div>
              {proposta.pons_count != null && (
                <div className="card kpi-card">
                  <div className="kpi-label">Porta(s) PON</div>
                  <div className="kpi-value">{proposta.pons_count}</div>
                </div>
              )}
              <div className="card kpi-card">
                <div className="kpi-label">ARPU de referência</div>
                <div className="kpi-value">{formatCurrencyFull(snapshot?.arpu)}</div>
              </div>
            </div>

            <h2 className="section-title">Condições comerciais</h2>
            <div className="card-grid" style={{ marginBottom: 24 }}>
              <div className="card kpi-card">
                <div className="kpi-label">Mensalidade proposta</div>
                <div className="kpi-value" style={{ fontSize: '1.3rem', color: 'var(--accent, #0e6e55)' }}>{formatCurrencyFull(snapshot?.preco_proposto)}</div>
              </div>
              {snapshot?.revenue_share_pct != null && (
                <div className="card kpi-card">
                  <div className="kpi-label">Revenue share</div>
                  <div className="kpi-value">{(Number(snapshot.revenue_share_pct) * 100).toFixed(1)}%</div>
                </div>
              )}
              <div className="card kpi-card">
                <div className="kpi-label">Faturamento mensal estimado</div>
                <div className="kpi-value">{formatCurrencyFull(snapshot?.faturamento)}</div>
              </div>
            </div>

            {(proposta.observacoes_comerciais || proposta.proximos_passos) && (
              <>
                <h2 className="section-title">Observações e próximos passos</h2>
                <div className="card-grid" style={{ marginBottom: 24, gridTemplateColumns: '1fr 1fr' }}>
                  {proposta.observacoes_comerciais && (
                    <div className="card">
                      <div className="kpi-label" style={{ marginBottom: 8 }}>Observações comerciais</div>
                      <p style={{ margin: 0, whiteSpace: 'pre-wrap' }}>{proposta.observacoes_comerciais}</p>
                    </div>
                  )}
                  {proposta.proximos_passos && (
                    <div className="card">
                      <div className="kpi-label" style={{ marginBottom: 8 }}>Próximos passos</div>
                      <p style={{ margin: 0, whiteSpace: 'pre-wrap' }}>{proposta.proximos_passos}</p>
                    </div>
                  )}
                </div>
              </>
            )}

            <div className="card" style={{ background: 'var(--surface, #f7f8f9)' }}>
              <h2 className="section-title" style={{ marginBottom: 8 }}>Aceite da proposta</h2>
              <p style={{ margin: 0 }}>
                Esta proposta é válida por {proposta.validade_dias} dias a partir de {new Date(proposta.criado_em).toLocaleDateString('pt-BR')}.
                Para formalizar o aceite, entre em contato com o consultor comercial responsável — o próximo passo do fluxo é a assinatura eletrônica
                e a geração automática do contrato a partir desta proposta.
              </p>
            </div>
          </div>

          <div style={{ padding: '16px 32px', borderTop: '1px solid var(--border)', fontSize: '0.78rem', color: 'var(--text-muted)', display: 'flex', justifyContent: 'space-between' }}>
            <span>OptiMon — documento comercial, gerado em {new Date().toLocaleDateString('pt-BR')}</span>
            <span>{numero} · V{proposta.numero_versao || 1}</span>
          </div>
        </div>
      )}

      <div style={{ marginBottom: 24 }}>
        <button className="link-tab" style={{ background: 'none', border: 'none', cursor: 'pointer' }} onClick={() => navigate('/propostas')}>← Voltar para a lista</button>
      </div>
    </div>
  );
}
