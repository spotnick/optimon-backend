import { useEffect, useState } from 'react';
import { useParams, Link } from 'react-router-dom';
import { api, apiDownload, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import { formatCurrencyFull } from '../components/charts/chartUtils';

const TIPOS_ADITIVO = ['INCLUSAO_FIBRA', 'INCLUSAO_PORTA', 'EXCLUSAO_FIBRA', 'EXCLUSAO_PORTA', 'ALTERACAO_PRAZO', 'ALTERACAO_COMERCIAL', 'ALTERACAO_CAPACIDADE', 'ALTERACAO_EXCLUSIVIDADE', 'ALTERACAO_REGRAS_COBRANCA', 'OUTRO'];

const EXCLUSIVIDADE_TIPOS = ['TERRITORIAL', 'SERVICO', 'CAPACIDADE', 'MISTA'];

// Fase 3.8 (item 3.8-08): estrutura formal de clientes reservados. PREFEITURA/
// ORGAO_PUBLICO recebem cláusula jurídica própria na minuta (contractDocumentModel.js)
// — nunca tratados como reserva comercial comum.
const TIPOS_CLIENTE_RESERVADO = [
  { value: 'OUTRO', label: 'Reserva comercial (cliente estratégico, etc.)' },
  { value: 'PREFEITURA', label: 'Prefeitura (ente municipal)' },
  { value: 'ORGAO_PUBLICO', label: 'Órgão público (estadual/federal/autarquia)' },
];

// Fase 3.8 (itens 3.8-09/3.8-10): tipo da solicitação de exceção — mesmos 2 tipos do
// enum contrato_regras_solicitacoes.tipo.
const TIPOS_REGRA_SOLICITACAO = [
  { value: 'FIBRA_TERCEIROS', label: 'Uso de fibra de terceiros' },
  { value: 'REDE_PROPRIA', label: 'Construção de rede própria pelo parceiro' },
];
const REGRA_SOLICITACAO_STATUS_LABEL = {
  AGUARDANDO_ENGENHARIA: 'Aguardando parecer de Engenharia',
  AGUARDANDO_COMERCIAL: 'Aguardando parecer Comercial',
  AGUARDANDO_DIRETORIA: 'Aguardando decisão da Diretoria',
  APROVADA: 'Aprovada (exceção concedida)',
  REJEITADA: 'Rejeitada',
};

export default function ContractDetail() {
  const { id } = useParams();
  const { role } = useAuth();
  const podeEditarGuardrails = role === 'DIRETOR' || role === 'ADMINISTRADOR';
  const podeCriarSolicitacao = role === 'COMERCIAL' || role === 'DIRETOR' || role === 'ADMINISTRADOR';
  const podeParecerEngenharia = role === 'ENGENHARIA' || role === 'DIRETOR' || role === 'ADMINISTRADOR';
  const podeParecerComercial = role === 'COMERCIAL' || role === 'DIRETOR' || role === 'ADMINISTRADOR';
  const podeDecidirSolicitacao = role === 'DIRETOR' || role === 'ADMINISTRADOR';
  const [contract, setContract] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState(null);
  const [actionMsg, setActionMsg] = useState(null);

  const [showAditivoForm, setShowAditivoForm] = useState(false);
  const [aditivoForm, setAditivoForm] = useState({ numero: '', tipo: TIPOS_ADITIVO[0], descricao: '' });

  const [showReajuste, setShowReajuste] = useState(false);
  const [reajustePercentual, setReajustePercentual] = useState('');

  const [showRegrasForm, setShowRegrasForm] = useState(false);
  const [regrasForm, setRegrasForm] = useState(null);

  // Fase 3.8 (item 3.8-14): encerrar/rescindir contrato — não existia nenhum caminho de
  // escrita para isso antes desta fase (ver app.encerrar_contrato).
  const [showTerminateForm, setShowTerminateForm] = useState(false);
  const [terminateForm, setTerminateForm] = useState({ tipo: 'ENCERRADO', motivo: '' });

  const [showClienteForm, setShowClienteForm] = useState(false);
  const [clienteForm, setClienteForm] = useState({ cliente_nome: '', cnpj_cpf: '', motivo: '', tipo: 'OUTRO', documento_referencia: '' });

  const [showSolicitacaoForm, setShowSolicitacaoForm] = useState(false);
  const [solicitacaoForm, setSolicitacaoForm] = useState({ tipo: TIPOS_REGRA_SOLICITACAO[0].value, descricao: '' });
  // Texto do parecer/decisão em edição, por id de solicitação — evita 1 estado por linha.
  const [parecerTexto, setParecerTexto] = useState({});

  // Fase 3.8 (item 3.8-11): registro formal de ativos cedidos + devolução.
  const podeGerenciarAtivos = role === 'ENGENHARIA' || role === 'ADMINISTRADOR';
  const [showAtivoForm, setShowAtivoForm] = useState(false);
  const [ativoForm, setAtivoForm] = useState({ tipo: 'OLT', fabricante: '', modelo: '', numero_serie: '', patrimonio: '' });
  const [devolucoesPendentes, setDevolucoesPendentes] = useState({}); // ativo_id -> ordem de devolução em aberto
  const [devolucaoForm, setDevolucaoForm] = useState({}); // ativo_id -> { condicao, valor_perdas_danos, status_final }

  // Fase 3.8 (item 3.8-12): consolidação Multi-POP (capacidade + receita rateada) de um
  // contrato específico — public.pricing_capacity_by_pop já existia desde a Fase 2.1 mas
  // nunca tinha sido chamada por nenhuma tela até agora.
  const [multiPop, setMultiPop] = useState(null);

  function load() {
    api.contracts.get(id).then(setContract).catch((err) => setError(err.message));
    api.pricing.capacityByPop(id).then(setMultiPop).catch(() => setMultiPop(null));
  }
  useEffect(load, [id]);

  async function handleExportMinuta(formato) {
    setActionError(null); setBusy(true);
    try {
      const { blob, fileName } = await apiDownload(api.contracts.minutaPath(id, formato));
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = fileName; document.body.appendChild(a); a.click(); a.remove();
      URL.revokeObjectURL(url);
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro ao gerar a minuta.');
    } finally {
      setBusy(false);
    }
  }

  function openRegrasForm() {
    const r = contract.regras || {};
    setRegrasForm({
      exclusividade_comercial: !!r.exclusividade_comercial,
      exclusividade_tipo: r.exclusividade_tipo || '',
      area_exclusividade: r.area_exclusividade || '',
      proibe_fibra_terceiros: r.proibe_fibra_terceiros !== false,
      proibe_rede_propria: r.proibe_rede_propria !== false,
      direito_preferencia: !!r.direito_preferencia,
      exige_aprovacao_expansao: r.exige_aprovacao_expansao !== false,
      permite_outros_parceiros: r.permite_outros_parceiros !== false,
      direito_proprietario_explorar_capacidade_remanescente: r.direito_proprietario_explorar_capacidade_remanescente !== false,
      observacoes: r.observacoes || '',
    });
    setShowRegrasForm(true);
  }

  async function handleSaveRegras(e) {
    e.preventDefault();
    setActionError(null); setBusy(true);
    try {
      await api.contracts.updateRegras(id, {
        ...regrasForm,
        exclusividade_tipo: regrasForm.exclusividade_comercial ? (regrasForm.exclusividade_tipo || null) : null,
        area_exclusividade: regrasForm.area_exclusividade || null,
        observacoes: regrasForm.observacoes || null,
      });
      setActionMsg('Guardrails contratuais atualizados.');
      setShowRegrasForm(false);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleAddCliente(e) {
    e.preventDefault();
    setActionError(null); setBusy(true);
    try {
      await api.contracts.addClienteReservado(id, clienteForm);
      setClienteForm({ cliente_nome: '', cnpj_cpf: '', motivo: '', tipo: 'OUTRO', documento_referencia: '' });
      setShowClienteForm(false);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleToggleCliente(reservaId, statusAtual) {
    setActionError(null); setBusy(true);
    try {
      await api.contracts.updateClienteReservado(id, reservaId, { status: statusAtual === 'RESERVADO' ? 'LIBERADO' : 'RESERVADO' });
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  // Fase 3.8 (itens 3.8-09/3.8-10): workflow Engenharia → Comercial → Diretoria.
  async function handleCreateSolicitacao(e) {
    e.preventDefault();
    setActionError(null); setBusy(true);
    try {
      await api.contracts.addRegraSolicitacao(id, solicitacaoForm);
      setSolicitacaoForm({ tipo: TIPOS_REGRA_SOLICITACAO[0].value, descricao: '' });
      setShowSolicitacaoForm(false);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleSolicitacaoEtapa(solId, etapa, aprova) {
    const texto = (parecerTexto[solId] || '').trim();
    const textoObrigatorio = !(etapa === 'decidir' && aprova); // decisão final de aprovação não exige motivo escrito
    if (textoObrigatorio && !texto) {
      setActionError('Preencha o parecer/motivo antes de confirmar.');
      return;
    }
    setActionError(null); setBusy(true);
    try {
      if (etapa === 'engenharia') await api.contracts.parecerEngenharia(id, solId, { aprova, parecer: texto });
      else if (etapa === 'comercial') await api.contracts.parecerComercial(id, solId, { aprova, parecer: texto });
      else await api.contracts.decidirRegraSolicitacao(id, solId, { aprova, motivo: texto || undefined });
      setParecerTexto((s) => ({ ...s, [solId]: '' }));
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  // Fase 3.8 (item 3.8-11): registro formal de ativos cedidos + devolução.
  async function handleAddAtivo(e) {
    e.preventDefault();
    setActionError(null); setBusy(true);
    try {
      await api.assets.create({ ...ativoForm, contrato_id: id, status: 'EM_USO' });
      setAtivoForm({ tipo: 'OLT', fabricante: '', modelo: '', numero_serie: '', patrimonio: '' });
      setShowAtivoForm(false);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleIniciarDevolucao(ativoId) {
    setActionError(null); setBusy(true);
    try {
      const devolucao = await api.assets.abrirDevolucao(ativoId, { contrato_id: id });
      setDevolucoesPendentes((s) => ({ ...s, [ativoId]: devolucao }));
      setDevolucaoForm((s) => ({ ...s, [ativoId]: { condicao: '', valor_perdas_danos: '', status_final: 'DEVOLVIDO' } }));
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleConfirmarDevolucao(ativoId) {
    const devolucao = devolucoesPendentes[ativoId];
    const form = devolucaoForm[ativoId] || {};
    if (!devolucao) return;
    setActionError(null); setBusy(true);
    try {
      await api.assets.confirmarDevolucao(ativoId, devolucao.id, {
        condicao: form.condicao || null,
        valor_perdas_danos: form.valor_perdas_danos ? Number(form.valor_perdas_danos) : null,
        status_final: form.status_final || 'DEVOLVIDO',
      });
      setDevolucoesPendentes((s) => { const n = { ...s }; delete n[ativoId]; return n; });
      setDevolucaoForm((s) => { const n = { ...s }; delete n[ativoId]; return n; });
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleActivate() {
    setActionError(null); setActionMsg(null); setBusy(true);
    try {
      await api.contracts.activate(id);
      setActionMsg('Contrato ativado com sucesso.');
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleTerminate(e) {
    e.preventDefault();
    setActionError(null); setBusy(true);
    try {
      await api.contracts.terminate(id, terminateForm);
      setActionMsg(`Contrato ${terminateForm.tipo === 'RESCINDIDO' ? 'rescindido' : 'encerrado'} com sucesso.`);
      setShowTerminateForm(false);
      setTerminateForm({ tipo: 'ENCERRADO', motivo: '' });
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleCreateAditivo(e) {
    e.preventDefault();
    setActionError(null); setBusy(true);
    try {
      await api.contracts.createAditivo(id, { ...aditivoForm, numero: Number(aditivoForm.numero) });
      setAditivoForm({ numero: '', tipo: TIPOS_ADITIVO[0], descricao: '' });
      setShowAditivoForm(false);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleAditivoStatus(aditivoId, status) {
    setActionError(null); setBusy(true);
    try {
      await api.contracts.updateAditivo(id, aditivoId, { status });
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleActivateAditivo(aditivoId) {
    setActionError(null); setBusy(true);
    try {
      await api.contracts.activateAditivo(id, aditivoId);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  async function handleReajuste(e) {
    e.preventDefault();
    setActionError(null); setBusy(true);
    try {
      await api.contracts.reajuste(id, { percentual: Number(reajustePercentual) });
      setActionMsg('Reajuste aplicado — novo evento registrado, valores históricos preservados.');
      setReajustePercentual('');
      setShowReajuste(false);
      load();
    } catch (err) {
      setActionError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setBusy(false);
    }
  }

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;
  if (!contract) return <div className="page"><div className="card"><div className="spinner" /></div></div>;

  return (
    <div className="page">
      <div className="page-header">
        <h1>Contrato {contract.numero}</h1>
        <p>Status: <span className="badge">{contract.status}</span> — versão atual V{contract.versao_atual}</p>
      </div>

      {actionError && <div className="error-banner">{actionError}</div>}
      {actionMsg && <div className="card" style={{ background: '#eaf7ee', marginBottom: 16 }}>{actionMsg}</div>}

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8, marginBottom: 12 }}>
          <div><strong>Proponente:</strong> {contract.parceiros?.nome_fantasia || contract.parceiros?.razao_social}</div>
          <div><strong>CNPJ:</strong> {contract.parceiros?.cnpj}</div>
          <div><strong>Cidade:</strong> {contract.cidades_infra?.nome}/{contract.cidades_infra?.uf}</div>
          <div><strong>Prazo:</strong> {contract.prazo_meses} meses{contract.prazo_minimo_excecao ? ' (exceção ao mínimo de 48m)' : ''}</div>
          <div><strong>Início:</strong> {contract.data_inicio || '—'}</div>
          <div><strong>Fim previsto:</strong> {contract.data_fim_prevista || '—'}</div>
          {/* Fase 3.10 (Problema 3, seção 3.4): vínculo bidirecional visível — o lado da
              proposta mostra "Contrato vinculado: CTR-XXXX" (ver ProposalDetail.jsx). */}
          {contract.proposta_origem && (
            <div>
              <strong>Proposta de origem:</strong>{' '}
              <Link className="link-tab" to={`/propostas/${contract.proposta_origem.id}`}>{contract.proposta_origem.numero} →</Link>
            </div>
          )}
        </div>
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
          <button className="btn btn-primary" disabled={busy || contract.status === 'ATIVO'} onClick={handleActivate}>Ativar contrato</button>
          <button className="btn btn-secondary" disabled={busy} onClick={() => setShowReajuste((s) => !s)}>{showReajuste ? 'Cancelar' : 'Aplicar reajuste'}</button>
          <button className="btn btn-secondary" disabled={busy} onClick={() => handleExportMinuta('PDF')}>Baixar Minuta (PDF)</button>
          <button className="btn btn-secondary" disabled={busy} onClick={() => handleExportMinuta('DOCX')}>Baixar Minuta (DOCX)</button>
          {podeEditarGuardrails && ['ATIVO', 'SUSPENSO'].includes(contract.status) && (
            <button className="btn btn-danger" disabled={busy} onClick={() => setShowTerminateForm((s) => !s)}>{showTerminateForm ? 'Cancelar' : 'Encerrar/Rescindir contrato'}</button>
          )}
        </div>
        <p style={{ color: 'var(--text-muted, #666)', marginTop: 12, fontSize: 13 }}>
          A minuta é um documento gerado a partir dos dados deste contrato e está sempre <strong>sujeita à aprovação jurídica</strong> — nunca é um contrato definitivo pronto para assinatura.
        </p>
        {showReajuste && (
          <form onSubmit={handleReajuste} style={{ marginTop: 12, display: 'flex', gap: 12, alignItems: 'flex-end' }}>
            <div className="field"><label>Percentual (ex.: 0.045 = 4,5%)</label><input required type="number" step="0.00001" value={reajustePercentual} onChange={(e) => setReajustePercentual(e.target.value)} /></div>
            <button type="submit" className="btn btn-primary" disabled={busy}>Aplicar</button>
          </form>
        )}
        {showTerminateForm && (
          <form onSubmit={handleTerminate} style={{ marginTop: 12, display: 'grid', gridTemplateColumns: '1fr 2fr auto', gap: 12, alignItems: 'flex-end' }}>
            <div className="field">
              <label>Tipo *</label>
              <select value={terminateForm.tipo} onChange={(e) => setTerminateForm({ ...terminateForm, tipo: e.target.value })}>
                <option value="ENCERRADO">Encerrado (fim natural do prazo)</option>
                <option value="RESCINDIDO">Rescindido (antecipado / por descumprimento)</option>
              </select>
            </div>
            <div className="field"><label>Motivo *</label><input required value={terminateForm.motivo} onChange={(e) => setTerminateForm({ ...terminateForm, motivo: e.target.value })} /></div>
            <button type="submit" className="btn btn-danger" disabled={busy}>Confirmar</button>
          </form>
        )}
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <h3 style={{ marginTop: 0 }}>Infraestrutura alocada (comprometida)</h3>
        {(contract.fibras_alocadas || []).length === 0 ? (
          <div className="empty-state">Nenhuma fibra/porta PON alocada ainda — alocação é sempre um passo manual de Engenharia (contrato_fibras), nunca automático.</div>
        ) : (
          <table>
            <thead><tr><th>Fibra</th><th>Porta PON</th><th>Vinculado em</th></tr></thead>
            <tbody>
              {contract.fibras_alocadas.map((f) => (
                <tr key={f.id}><td>{f.fibra_id}</td><td>{f.porta_pon_id || '—'}</td><td>{new Date(f.vinculado_em).toLocaleString('pt-BR')}</td></tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {multiPop && (multiPop.pops || []).length > 1 && (
        <div className="card" style={{ marginBottom: 16 }}>
          <h3 style={{ marginTop: 0 }}>Multi-POP: capacidade e receita por POP</h3>
          <table>
            <thead><tr><th>POP</th><th>Portas</th><th>Capacidade máxima</th><th>Clientes ativos</th><th>Disponível</th><th>Receita mensal (rateada)</th></tr></thead>
            <tbody>
              {multiPop.pops.map((p) => (
                <tr key={p.pop_id}>
                  <td>{p.pop_codigo} — {p.pop_nome}</td>
                  <td>{p.portas}</td>
                  <td>{p.capacidade_maxima}</td>
                  <td>{p.clientes_ativos}</td>
                  <td>{p.capacidade_disponivel}</td>
                  <td>{formatCurrencyFull(p.receita_mensal_rateada)}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <td><strong>Consolidado ({multiPop.consolidado.pops_utilizados} POPs)</strong></td>
                <td><strong>{multiPop.consolidado.portas_total}</strong></td>
                <td><strong>{multiPop.consolidado.capacidade_maxima_total}</strong></td>
                <td><strong>{multiPop.consolidado.clientes_ativos_total}</strong></td>
                <td><strong>{multiPop.consolidado.capacidade_disponivel_total}</strong></td>
                <td><strong>{formatCurrencyFull(multiPop.consolidado.receita_mensal_total)}</strong></td>
              </tr>
            </tfoot>
          </table>
          <p style={{ color: 'var(--text-muted, #666)', marginTop: 12, fontSize: '0.85rem' }}>{multiPop.receita_metodologia}</p>
        </div>
      )}

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h3 style={{ margin: 0 }}>Aditivos (RASCUNHO → EM_APROVACAO → APROVADO → ASSINATURA → ATIVO)</h3>
          <button className="btn btn-secondary" onClick={() => setShowAditivoForm((s) => !s)}>{showAditivoForm ? 'Cancelar' : '+ Novo aditivo'}</button>
        </div>
        {showAditivoForm && (
          <form onSubmit={handleCreateAditivo} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12, margin: '12px 0' }}>
            <div className="field"><label>Número *</label><input required type="number" min="1" value={aditivoForm.numero} onChange={(e) => setAditivoForm({ ...aditivoForm, numero: e.target.value })} /></div>
            <div className="field">
              <label>Tipo *</label>
              <select value={aditivoForm.tipo} onChange={(e) => setAditivoForm({ ...aditivoForm, tipo: e.target.value })}>
                {TIPOS_ADITIVO.map((t) => <option key={t} value={t}>{t}</option>)}
              </select>
            </div>
            <div className="field"><label>Descrição *</label><input required value={aditivoForm.descricao} onChange={(e) => setAditivoForm({ ...aditivoForm, descricao: e.target.value })} /></div>
            <div style={{ gridColumn: 'span 3' }}><button type="submit" className="btn btn-primary" disabled={busy}>Criar aditivo</button></div>
          </form>
        )}
        {(contract.aditivos || []).length === 0 ? (
          <div className="empty-state">Nenhum aditivo criado ainda.</div>
        ) : (
          <table>
            <thead><tr><th>Nº</th><th>Tipo</th><th>Descrição</th><th>Status</th><th>Ações</th></tr></thead>
            <tbody>
              {contract.aditivos.map((a) => (
                <tr key={a.id}>
                  <td>{a.numero}</td><td>{a.tipo}</td><td>{a.descricao}</td>
                  <td><span className="badge">{a.status}</span></td>
                  <td style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                    {a.status === 'RASCUNHO' && <button className="btn btn-secondary" disabled={busy} onClick={() => handleAditivoStatus(a.id, 'EM_APROVACAO')}>Enviar p/ aprovação</button>}
                    {a.status === 'EM_APROVACAO' && <button className="btn btn-primary" disabled={busy} onClick={() => handleAditivoStatus(a.id, 'APROVADO')}>Aprovar</button>}
                    {a.status === 'EM_APROVACAO' && <button className="btn btn-danger" disabled={busy} onClick={() => handleAditivoStatus(a.id, 'REJEITADO')}>Rejeitar</button>}
                    {a.status === 'ASSINATURA' && <button className="btn btn-primary" disabled={busy} onClick={() => handleActivateAditivo(a.id)}>Ativar (após assinatura validada)</button>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <p style={{ color: 'var(--text-muted, #666)', marginTop: 12 }}>
          Aditivo APROVADO precisa de um envelope de assinatura (criado em Assinaturas, tipo ADITIVO) antes de poder ser ativado.
        </p>
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <h3 style={{ marginTop: 0 }}>Reajustes (histórico — nunca reescrito)</h3>
        {(contract.reajustes || []).length === 0 ? (
          <div className="empty-state">Nenhum reajuste aplicado ainda.</div>
        ) : (
          <table>
            <thead><tr><th>Competência</th><th>Percentual</th><th>Status</th><th>Aplicado em</th></tr></thead>
            <tbody>
              {contract.reajustes.map((r) => (
                <tr key={r.id}><td>{r.competencia_base}</td><td>{(r.percentual_aplicado * 100).toFixed(3)}%</td><td>{r.status}</td><td>{new Date(r.aplicado_em).toLocaleString('pt-BR')}</td></tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {/* Fase 3 (item 3.7): guardrails contratuais (exclusividade/fibra de terceiros/rede
          própria/direito de preferência) — dado que já existia desde a Fase 1 mas nunca
          era mostrado em lugar nenhum do sistema. */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h3 style={{ margin: 0 }}>Guardrails contratuais (exclusividade, fibra de terceiros, rede própria)</h3>
          {podeEditarGuardrails && (
            <button className="btn btn-secondary" disabled={busy} onClick={() => (showRegrasForm ? setShowRegrasForm(false) : openRegrasForm())}>
              {showRegrasForm ? 'Cancelar' : 'Editar'}
            </button>
          )}
        </div>
        {!showRegrasForm && (
          contract.regras ? (
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8, marginTop: 12 }}>
              <div><strong>Exclusividade comercial:</strong> {contract.regras.exclusividade_comercial ? `Sim (${contract.regras.exclusividade_tipo || 'tipo não classificado'})` : 'Não'}</div>
              <div><strong>Área de exclusividade:</strong> {contract.regras.area_exclusividade || '—'}</div>
              <div><strong>Proíbe fibra de terceiros:</strong> {contract.regras.proibe_fibra_terceiros !== false ? 'Sim' : 'Não'}</div>
              <div><strong>Proíbe rede própria:</strong> {contract.regras.proibe_rede_propria !== false ? 'Sim' : 'Não'}</div>
              <div><strong>Direito de preferência do parceiro:</strong> {contract.regras.direito_preferencia ? 'Sim' : 'Não'}</div>
              <div><strong>Exige aprovação para expansão:</strong> {contract.regras.exige_aprovacao_expansao !== false ? 'Sim' : 'Não'}</div>
              <div><strong>Permite outros parceiros:</strong> {contract.regras.permite_outros_parceiros !== false ? 'Sim' : 'Não'}</div>
              <div><strong>NICK preserva direito sobre capacidade remanescente:</strong> {contract.regras.direito_proprietario_explorar_capacidade_remanescente !== false ? 'Sim' : 'Não'}</div>
              {contract.regras.observacoes && <div style={{ gridColumn: 'span 2' }}><strong>Observações:</strong> {contract.regras.observacoes}</div>}
            </div>
          ) : (
            <div className="empty-state">Nenhum registro de guardrails para este contrato — valores padrão do sistema se aplicam (sem exclusividade, proibições de fibra de terceiros/rede própria ativas). {podeEditarGuardrails ? 'Clique em "Editar" para registrar explicitamente.' : ''}</div>
          )
        )}
        {showRegrasForm && regrasForm && (
          <form onSubmit={handleSaveRegras} style={{ marginTop: 12 }}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 12 }}>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <input type="checkbox" checked={regrasForm.exclusividade_comercial} onChange={(e) => setRegrasForm({ ...regrasForm, exclusividade_comercial: e.target.checked })} />
                Exclusividade comercial
              </label>
              {regrasForm.exclusividade_comercial && (
                <div className="field">
                  <label>Tipo de exclusividade</label>
                  <select value={regrasForm.exclusividade_tipo} onChange={(e) => setRegrasForm({ ...regrasForm, exclusividade_tipo: e.target.value })}>
                    <option value="">— selecione —</option>
                    {EXCLUSIVIDADE_TIPOS.map((t) => <option key={t} value={t}>{t}</option>)}
                  </select>
                </div>
              )}
              {regrasForm.exclusividade_comercial && (
                <div className="field" style={{ gridColumn: 'span 2' }}>
                  <label>Área de exclusividade (texto livre — cidade/POP específicos ficam no cadastro de infraestrutura)</label>
                  <input value={regrasForm.area_exclusividade} onChange={(e) => setRegrasForm({ ...regrasForm, area_exclusividade: e.target.value })} />
                </div>
              )}
              <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <input type="checkbox" checked={regrasForm.proibe_fibra_terceiros} onChange={(e) => setRegrasForm({ ...regrasForm, proibe_fibra_terceiros: e.target.checked })} />
                Proíbe fibra de terceiros
              </label>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <input type="checkbox" checked={regrasForm.proibe_rede_propria} onChange={(e) => setRegrasForm({ ...regrasForm, proibe_rede_propria: e.target.checked })} />
                Proíbe rede própria
              </label>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <input type="checkbox" checked={regrasForm.direito_preferencia} onChange={(e) => setRegrasForm({ ...regrasForm, direito_preferencia: e.target.checked })} />
                Direito de preferência do parceiro
              </label>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <input type="checkbox" checked={regrasForm.exige_aprovacao_expansao} onChange={(e) => setRegrasForm({ ...regrasForm, exige_aprovacao_expansao: e.target.checked })} />
                Exige aprovação para expansão
              </label>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <input type="checkbox" checked={regrasForm.permite_outros_parceiros} onChange={(e) => setRegrasForm({ ...regrasForm, permite_outros_parceiros: e.target.checked })} />
                Permite outros parceiros (fora do escopo de exclusividade)
              </label>
              <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <input type="checkbox" checked={regrasForm.direito_proprietario_explorar_capacidade_remanescente} onChange={(e) => setRegrasForm({ ...regrasForm, direito_proprietario_explorar_capacidade_remanescente: e.target.checked })} />
                NICK preserva direito sobre capacidade remanescente
              </label>
              <div className="field" style={{ gridColumn: 'span 2' }}>
                <label>Observações</label>
                <input value={regrasForm.observacoes} onChange={(e) => setRegrasForm({ ...regrasForm, observacoes: e.target.value })} />
              </div>
            </div>
            <button type="submit" className="btn btn-primary" disabled={busy} style={{ marginTop: 12 }}>Salvar guardrails</button>
          </form>
        )}
      </div>

      {/* Fase 3.8 (itens 3.8-09/3.8-10): workflow formal Engenharia → Comercial →
          Diretoria para autorizar exceção às proibições acima. Toda a lógica de quem pode
          fazer o quê e quando mora no banco (RLS + trigger) — esta tela só mostra o estado
          e envia a ação da etapa em que o usuário logado pode atuar. */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h3 style={{ margin: 0 }}>Solicitações de exceção (fibra de terceiros / rede própria)</h3>
          {podeCriarSolicitacao && (
            <button className="btn btn-secondary" disabled={busy} onClick={() => setShowSolicitacaoForm((s) => !s)}>{showSolicitacaoForm ? 'Cancelar' : '+ Nova solicitação'}</button>
          )}
        </div>
        {showSolicitacaoForm && (
          <form onSubmit={handleCreateSolicitacao} style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 12, margin: '12px 0' }}>
            <div className="field">
              <label>Tipo</label>
              <select value={solicitacaoForm.tipo} onChange={(e) => setSolicitacaoForm({ ...solicitacaoForm, tipo: e.target.value })}>
                {TIPOS_REGRA_SOLICITACAO.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
              </select>
            </div>
            <div className="field"><label>Descrição da exceção pedida *</label><input required value={solicitacaoForm.descricao} onChange={(e) => setSolicitacaoForm({ ...solicitacaoForm, descricao: e.target.value })} /></div>
            <div style={{ gridColumn: 'span 2' }}><button type="submit" className="btn btn-primary" disabled={busy}>Enviar para Engenharia</button></div>
          </form>
        )}
        {(contract.regras_solicitacoes || []).length === 0 ? (
          <div className="empty-state">Nenhuma solicitação de exceção registrada para este contrato.</div>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12, marginTop: 12 }}>
            {contract.regras_solicitacoes.map((s) => {
              const podeAgirNestaEtapa = (s.status === 'AGUARDANDO_ENGENHARIA' && podeParecerEngenharia)
                || (s.status === 'AGUARDANDO_COMERCIAL' && podeParecerComercial)
                || (s.status === 'AGUARDANDO_DIRETORIA' && podeDecidirSolicitacao);
              const etapa = s.status === 'AGUARDANDO_ENGENHARIA' ? 'engenharia' : s.status === 'AGUARDANDO_COMERCIAL' ? 'comercial' : 'decidir';
              return (
                <div key={s.id} style={{ border: '1px solid var(--border, #333)', borderRadius: 8, padding: 12 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
                    <div>
                      <strong>{TIPOS_REGRA_SOLICITACAO.find((t) => t.value === s.tipo)?.label || s.tipo}</strong>
                      <div style={{ fontSize: '0.9em', opacity: 0.85 }}>{s.descricao}</div>
                    </div>
                    <span className="badge">{REGRA_SOLICITACAO_STATUS_LABEL[s.status] || s.status}</span>
                  </div>
                  <div style={{ fontSize: '0.85em', marginTop: 8, display: 'grid', gap: 4 }}>
                    {s.parecer_engenharia && <div><strong>Parecer Engenharia:</strong> {s.parecer_engenharia}</div>}
                    {s.parecer_comercial && <div><strong>Parecer Comercial:</strong> {s.parecer_comercial}</div>}
                    {s.status === 'REJEITADA' && <div><strong>Rejeitada na etapa:</strong> {s.etapa_rejeicao}{s.motivo_rejeicao ? ` — ${s.motivo_rejeicao}` : ''}</div>}
                    {s.status === 'APROVADA' && <div>Exceção concedida — a proibição correspondente já foi liberada nos guardrails deste contrato.</div>}
                  </div>
                  {podeAgirNestaEtapa && (
                    <div style={{ marginTop: 10, display: 'flex', gap: 8, alignItems: 'flex-start' }}>
                      <input
                        placeholder={etapa === 'decidir' ? 'Motivo (obrigatório só ao rejeitar)' : 'Parecer (obrigatório)'}
                        style={{ flex: 1 }}
                        value={parecerTexto[s.id] || ''}
                        onChange={(e) => setParecerTexto((st) => ({ ...st, [s.id]: e.target.value }))}
                      />
                      <button className="btn btn-primary" disabled={busy} onClick={() => handleSolicitacaoEtapa(s.id, etapa, true)}>{etapa === 'decidir' ? 'Aprovar' : 'Avançar'}</button>
                      <button className="btn btn-secondary" disabled={busy} onClick={() => handleSolicitacaoEtapa(s.id, etapa, false)}>Rejeitar</button>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h3 style={{ margin: 0 }}>Clientes reservados (fora do escopo do parceiro — ex.: exceção Prefeitura)</h3>
          {podeEditarGuardrails && (
            <button className="btn btn-secondary" disabled={busy} onClick={() => setShowClienteForm((s) => !s)}>{showClienteForm ? 'Cancelar' : '+ Novo cliente reservado'}</button>
          )}
        </div>
        {showClienteForm && (
          <form onSubmit={handleAddCliente} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12, margin: '12px 0' }}>
            <div className="field"><label>Nome do cliente/entidade *</label><input required value={clienteForm.cliente_nome} onChange={(e) => setClienteForm({ ...clienteForm, cliente_nome: e.target.value })} /></div>
            <div className="field"><label>CNPJ/CPF</label><input value={clienteForm.cnpj_cpf} onChange={(e) => setClienteForm({ ...clienteForm, cnpj_cpf: e.target.value })} /></div>
            <div className="field">
              <label>Tipo</label>
              <select value={clienteForm.tipo} onChange={(e) => setClienteForm({ ...clienteForm, tipo: e.target.value })}>
                {TIPOS_CLIENTE_RESERVADO.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
              </select>
            </div>
            <div className="field"><label>Motivo</label><input value={clienteForm.motivo} onChange={(e) => setClienteForm({ ...clienteForm, motivo: e.target.value })} /></div>
            {clienteForm.tipo !== 'OUTRO' && (
              <div className="field">
                <label>Documento de referência (ofício/processo)</label>
                <input value={clienteForm.documento_referencia} onChange={(e) => setClienteForm({ ...clienteForm, documento_referencia: e.target.value })} placeholder="ex.: Ofício SEI nº 045/2026-GAB" />
              </div>
            )}
            <div style={{ gridColumn: 'span 3' }}><button type="submit" className="btn btn-primary" disabled={busy}>Adicionar</button></div>
          </form>
        )}
        {(contract.clientes_reservados || []).length === 0 ? (
          <div className="empty-state">Nenhum cliente reservado registrado — não há exceção de atendimento nesta minuta.</div>
        ) : (
          <table>
            <thead><tr><th>Cliente</th><th>Tipo</th><th>CNPJ/CPF</th><th>Motivo</th><th>Documento</th><th>Status</th>{podeEditarGuardrails && <th>Ações</th>}</tr></thead>
            <tbody>
              {contract.clientes_reservados.map((c) => (
                <tr key={c.id}>
                  <td>{c.cliente_nome}</td>
                  <td>{c.tipo && c.tipo !== 'OUTRO' ? <span className="badge">{TIPOS_CLIENTE_RESERVADO.find((t) => t.value === c.tipo)?.label || c.tipo}</span> : '—'}</td>
                  <td>{c.cnpj_cpf || '—'}</td><td>{c.motivo || '—'}</td><td>{c.documento_referencia || '—'}</td>
                  <td><span className="badge">{c.status}</span></td>
                  {podeEditarGuardrails && (
                    <td><button className="btn btn-secondary" disabled={busy} onClick={() => handleToggleCliente(c.id, c.status)}>{c.status === 'RESERVADO' ? 'Liberar' : 'Reservar novamente'}</button></td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {/* Fase 3.8 (item 3.8-11): registro formal — equipamento CEDIDO (OLT/ONU/ONT/fonte/
          switch), sempre devolvido ou indenizado ao fim do contrato. Nunca confundir com
          a infraestrutura permanente (fibra/cabo/poste/porta PON), que nunca é
          "devolvida" — é propriedade da NICK por definição (ver cláusula "Propriedade dos
          Ativos" da minuta, contractDocumentModel.js). */}
      <div className="card">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h3 style={{ margin: 0 }}>Ativos e equipamentos cedidos (OLT/ONU/ONT/fonte/switch)</h3>
          {podeGerenciarAtivos && (
            <button className="btn btn-secondary" disabled={busy} onClick={() => setShowAtivoForm((s) => !s)}>{showAtivoForm ? 'Cancelar' : '+ Novo ativo'}</button>
          )}
        </div>
        {showAtivoForm && (
          <form onSubmit={handleAddAtivo} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12, margin: '12px 0' }}>
            <div className="field">
              <label>Tipo</label>
              <select value={ativoForm.tipo} onChange={(e) => setAtivoForm({ ...ativoForm, tipo: e.target.value })}>
                {['OLT', 'ONU', 'ONT', 'FONTE', 'SWITCH', 'ROTEADOR', 'OUTRO'].map((t) => <option key={t} value={t}>{t}</option>)}
              </select>
            </div>
            <div className="field"><label>Fabricante</label><input value={ativoForm.fabricante} onChange={(e) => setAtivoForm({ ...ativoForm, fabricante: e.target.value })} /></div>
            <div className="field"><label>Modelo</label><input value={ativoForm.modelo} onChange={(e) => setAtivoForm({ ...ativoForm, modelo: e.target.value })} /></div>
            <div className="field"><label>Nº de série</label><input value={ativoForm.numero_serie} onChange={(e) => setAtivoForm({ ...ativoForm, numero_serie: e.target.value })} /></div>
            <div className="field"><label>Patrimônio</label><input value={ativoForm.patrimonio} onChange={(e) => setAtivoForm({ ...ativoForm, patrimonio: e.target.value })} /></div>
            <div style={{ gridColumn: 'span 3' }}><button type="submit" className="btn btn-primary" disabled={busy}>Cadastrar e vincular a este contrato</button></div>
          </form>
        )}
        {(contract.ativos || []).length === 0 ? (
          <div className="empty-state">Nenhum ativo (OLT/ONU/ONT/fonte/switch) da NICK vinculado a este contrato.</div>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12, marginTop: 12 }}>
            {contract.ativos.map((a) => {
              const pendente = devolucoesPendentes[a.id];
              const podeIniciarDevolucao = podeGerenciarAtivos && a.status === 'EM_USO' && !pendente;
              return (
                <div key={a.id} style={{ border: '1px solid var(--border, #333)', borderRadius: 8, padding: 12 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
                    <div>
                      <strong>{a.tipo}</strong> {a.fabricante || ''} {a.modelo || ''}
                      <div style={{ fontSize: '0.85em', opacity: 0.85 }}>Nº série: {a.numero_serie || '—'} · Patrimônio: {a.patrimonio || '—'}</div>
                    </div>
                    <span className="badge">{a.status}</span>
                  </div>
                  {podeIniciarDevolucao && (
                    <button className="btn btn-secondary" disabled={busy} style={{ marginTop: 8 }} onClick={() => handleIniciarDevolucao(a.id)}>Iniciar devolução</button>
                  )}
                  {pendente && (
                    <div style={{ marginTop: 10, display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                      <div className="field" style={{ gridColumn: 'span 3' }}>
                        <label>Condição do equipamento devolvido</label>
                        <input value={devolucaoForm[a.id]?.condicao || ''} onChange={(e) => setDevolucaoForm((s) => ({ ...s, [a.id]: { ...s[a.id], condicao: e.target.value } }))} />
                      </div>
                      <div className="field">
                        <label>Valor de perdas/danos (R$, se houver)</label>
                        <input type="number" step="0.01" min="0" value={devolucaoForm[a.id]?.valor_perdas_danos || ''} onChange={(e) => setDevolucaoForm((s) => ({ ...s, [a.id]: { ...s[a.id], valor_perdas_danos: e.target.value } }))} />
                      </div>
                      <div className="field">
                        <label>Desfecho</label>
                        <select value={devolucaoForm[a.id]?.status_final || 'DEVOLVIDO'} onChange={(e) => setDevolucaoForm((s) => ({ ...s, [a.id]: { ...s[a.id], status_final: e.target.value } }))}>
                          <option value="DEVOLVIDO">Devolvido</option>
                          <option value="PERDIDO">Perdido (não devolvido)</option>
                        </select>
                      </div>
                      <div style={{ display: 'flex', alignItems: 'flex-end' }}>
                        <button className="btn btn-primary" disabled={busy} onClick={() => handleConfirmarDevolucao(a.id)}>Confirmar devolução</button>
                      </div>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
