import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { api, apiDownload, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';

const TIPOS_ADITIVO = ['INCLUSAO_FIBRA', 'INCLUSAO_PORTA', 'EXCLUSAO_FIBRA', 'EXCLUSAO_PORTA', 'ALTERACAO_PRAZO', 'ALTERACAO_COMERCIAL', 'ALTERACAO_CAPACIDADE', 'ALTERACAO_EXCLUSIVIDADE', 'ALTERACAO_REGRAS_COBRANCA', 'OUTRO'];

const EXCLUSIVIDADE_TIPOS = ['TERRITORIAL', 'SERVICO', 'CAPACIDADE', 'MISTA'];

export default function ContractDetail() {
  const { id } = useParams();
  const { role } = useAuth();
  const podeEditarGuardrails = role === 'DIRETOR' || role === 'ADMINISTRADOR';
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

  const [showClienteForm, setShowClienteForm] = useState(false);
  const [clienteForm, setClienteForm] = useState({ cliente_nome: '', cnpj_cpf: '', motivo: '' });

  function load() {
    api.contracts.get(id).then(setContract).catch((err) => setError(err.message));
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
      setClienteForm({ cliente_nome: '', cnpj_cpf: '', motivo: '' });
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
        </div>
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
          <button className="btn btn-primary" disabled={busy || contract.status === 'ATIVO'} onClick={handleActivate}>Ativar contrato</button>
          <button className="btn btn-secondary" disabled={busy} onClick={() => setShowReajuste((s) => !s)}>{showReajuste ? 'Cancelar' : 'Aplicar reajuste'}</button>
          <button className="btn btn-secondary" disabled={busy} onClick={() => handleExportMinuta('PDF')}>Baixar Minuta (PDF)</button>
          <button className="btn btn-secondary" disabled={busy} onClick={() => handleExportMinuta('DOCX')}>Baixar Minuta (DOCX)</button>
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
            <div className="field"><label>Motivo</label><input value={clienteForm.motivo} onChange={(e) => setClienteForm({ ...clienteForm, motivo: e.target.value })} /></div>
            <div style={{ gridColumn: 'span 3' }}><button type="submit" className="btn btn-primary" disabled={busy}>Adicionar</button></div>
          </form>
        )}
        {(contract.clientes_reservados || []).length === 0 ? (
          <div className="empty-state">Nenhum cliente reservado registrado — não há exceção de atendimento nesta minuta.</div>
        ) : (
          <table>
            <thead><tr><th>Cliente</th><th>CNPJ/CPF</th><th>Motivo</th><th>Status</th>{podeEditarGuardrails && <th>Ações</th>}</tr></thead>
            <tbody>
              {contract.clientes_reservados.map((c) => (
                <tr key={c.id}>
                  <td>{c.cliente_nome}</td><td>{c.cnpj_cpf || '—'}</td><td>{c.motivo || '—'}</td>
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

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Ativos e equipamentos vinculados (OLT/ONU)</h3>
        {(contract.ativos || []).length === 0 ? (
          <div className="empty-state">Nenhum ativo (OLT/ONU/equipamento) da NICK vinculado a este contrato.</div>
        ) : (
          <table>
            <thead><tr><th>Tipo</th><th>Fabricante</th><th>Modelo</th><th>Nº série</th><th>Patrimônio</th><th>Status</th></tr></thead>
            <tbody>
              {contract.ativos.map((a) => (
                <tr key={a.id}><td>{a.tipo}</td><td>{a.fabricante || '—'}</td><td>{a.modelo || '—'}</td><td>{a.numero_serie || '—'}</td><td>{a.patrimonio || '—'}</td><td>{a.status}</td></tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
