import { useEffect, useState } from 'react';
import { useParams, useSearchParams, Link } from 'react-router-dom';
import { api, ApiError } from '../lib/api';
import { useAuth } from '../context/AuthContext';
import ArchiveModal from '../components/ArchiveModal';

const TIPOS_RESPONSAVEL = ['REPRESENTANTE_LEGAL', 'RESPONSAVEL_COMERCIAL', 'RESPONSAVEL_FINANCEIRO', 'RESPONSAVEL_TECNICO', 'TESTEMUNHA', 'OUTRO'];
const TIPOS_DOCUMENTO = ['CONTRATO_SOCIAL', 'CARTAO_CNPJ', 'PROCURACAO', 'ATA', 'OUTRO'];
const MOTIVOS_DESATIVACAO = ['Encerrou operação', 'Substituído por outro proponente', 'Erro de cadastro', 'Inadimplência', 'Outro'];
const CAN_WRITE = ['COMERCIAL', 'DIRETOR', 'ADMINISTRADOR'];
const CADASTRO_FIELDS = [
  ['razao_social', 'Razão social'], ['nome_fantasia', 'Nome fantasia'], ['email_contato', 'E-mail'], ['telefone_contato', 'Telefone'],
  ['site', 'Site'], ['inscricao_estadual', 'IE'], ['inscricao_municipal', 'IM'], ['responsavel_comercial', 'Responsável comercial'],
  ['endereco_logradouro', 'Logradouro'], ['endereco_numero', 'Número'], ['endereco_bairro', 'Bairro'],
  ['endereco_cidade', 'Cidade'], ['endereco_uf', 'UF'], ['endereco_cep', 'CEP'],
];

function emptyResponsavel() {
  return { nome: '', cpf: '', cargo: '', departamento: '', email: '', telefone: '', whatsapp: '', tipo: 'REPRESENTANTE_LEGAL', representante_legal: false };
}

export default function PartnerDetail() {
  const { id } = useParams();
  const { role } = useAuth();
  const canWrite = CAN_WRITE.includes(role);
  const [searchParams, setSearchParams] = useSearchParams();
  const [partner, setPartner] = useState(null);
  const [responsaveis, setResponsaveis] = useState(null);
  const [documentos, setDocumentos] = useState(null);
  const [propostas, setPropostas] = useState(null);
  const [contratos, setContratos] = useState(null);
  const [historico, setHistorico] = useState(null);
  const [error, setError] = useState(null);

  const [editingCadastro, setEditingCadastro] = useState(searchParams.get('editar') === '1');
  const [cadastroForm, setCadastroForm] = useState(null);
  const [savingCadastro, setSavingCadastro] = useState(false);
  const [cadastroError, setCadastroError] = useState(null);
  const [archiveTarget, setArchiveTarget] = useState(null); // 'archive' | 'restore'

  const [showRespForm, setShowRespForm] = useState(false);
  const [respForm, setRespForm] = useState(emptyResponsavel());
  const [savingResp, setSavingResp] = useState(false);
  const [respError, setRespError] = useState(null);
  const [editingRespId, setEditingRespId] = useState(null); // Fase 3 (item 3.9): edição de responsável já existente
  const [incluirRemovidos, setIncluirRemovidos] = useState(false); // idem — mostrar responsáveis removidos, com opção de restaurar

  const [docTipo, setDocTipo] = useState(TIPOS_DOCUMENTO[0]);
  const [docTitulo, setDocTitulo] = useState('');
  const [docFile, setDocFile] = useState(null);
  const [docResponsavelId, setDocResponsavelId] = useState('');
  const [uploading, setUploading] = useState(false);
  const [docError, setDocError] = useState(null);

  function load() {
    api.partners.get(id).then((p) => { setPartner(p); setCadastroForm(p); }).catch((err) => setError(err.message));
    api.partners.responsaveis(id, incluirRemovidos).then(setResponsaveis).catch((err) => setError(err.message));
    api.partners.documentos(id).then(setDocumentos).catch((err) => setError(err.message));
    // Fase 2.5.1 seção 11: abas Propostas/Contratos/Histórico-Auditoria.
    api.proposals.list({ parceiro_id: id, todas_versoes: 'true' }).then(setPropostas).catch(() => setPropostas([]));
    api.contracts.list('TODOS').then((all) => setContratos((all || []).filter((c) => c.parceiro_id === id))).catch(() => setContratos([]));
    api.audit.list({ entidade: 'parceiros', entidade_id: id, limit: 50 }).then(setHistorico).catch(() => setHistorico([]));
  }
  useEffect(load, [id, incluirRemovidos]);

  async function handleSaveCadastro(e) {
    e.preventDefault();
    setCadastroError(null);
    setSavingCadastro(true);
    try {
      const patch = {};
      for (const [f] of CADASTRO_FIELDS) patch[f] = cadastroForm[f];
      await api.partners.update(id, patch);
      setEditingCadastro(false);
      searchParams.delete('editar');
      setSearchParams(searchParams, { replace: true });
      load();
    } catch (err) {
      setCadastroError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setSavingCadastro(false);
    }
  }

  async function handleSaveResponsavel(e) {
    e.preventDefault();
    setRespError(null);
    setSavingResp(true);
    try {
      if (editingRespId) {
        await api.partners.updateResponsavel(id, editingRespId, respForm);
      } else {
        await api.partners.addResponsavel(id, respForm);
      }
      setRespForm(emptyResponsavel());
      setShowRespForm(false);
      setEditingRespId(null);
      load();
    } catch (err) {
      setRespError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setSavingResp(false);
    }
  }

  function startEditResponsavel(r) {
    setRespForm({
      nome: r.nome || '', cpf: r.cpf || '', cargo: r.cargo || '', departamento: r.departamento || '',
      email: r.email || '', telefone: r.telefone || '', whatsapp: r.whatsapp || '',
      tipo: r.tipo, representante_legal: !!r.representante_legal,
    });
    setEditingRespId(r.id);
    setRespError(null);
    setShowRespForm(true);
  }

  function cancelResponsavelForm() {
    setShowRespForm(false);
    setEditingRespId(null);
    setRespForm(emptyResponsavel());
    setRespError(null);
  }

  async function handleRemoveResponsavel(r) {
    setRespError(null);
    try {
      await api.partners.removeResponsavel(id, r.id);
      load();
    } catch (err) {
      setRespError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    }
  }

  async function handleRestoreResponsavel(r) {
    setRespError(null);
    try {
      await api.partners.restoreResponsavel(id, r.id);
      load();
    } catch (err) {
      setRespError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    }
  }

  async function handleUploadDoc(e) {
    e.preventDefault();
    setDocError(null);
    if (!docFile || !docTitulo) { setDocError('Selecione um arquivo e informe o título.'); return; }
    setUploading(true);
    try {
      const fd = new FormData();
      fd.append('arquivo', docFile);
      fd.append('tipo', docTipo);
      fd.append('titulo', docTitulo);
      if (docResponsavelId) fd.append('responsavel_id', docResponsavelId);
      await api.partners.uploadDocumento(id, fd);
      setDocTitulo(''); setDocFile(null); setDocResponsavelId('');
      load();
    } catch (err) {
      setDocError(err instanceof ApiError ? err.message : 'Erro inesperado — verifique se o Storage do Supabase já foi configurado (supabase/storage_setup_fase25.sql).');
    } finally {
      setUploading(false);
    }
  }

  async function handleDownload(docId) {
    try {
      const { url } = await api.partners.documentoDownloadUrl(docId);
      window.open(url, '_blank', 'noopener');
    } catch (err) {
      setDocError(err instanceof ApiError ? err.message : 'Erro ao gerar link de download.');
    }
  }

  async function setDocumentoComprobatorio(respId, documentoId) {
    try {
      await api.partners.updateResponsavel(id, respId, { documento_comprobatorio_id: documentoId });
      load();
    } catch (err) {
      setRespError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    }
  }

  if (error) return <div className="page"><div className="error-banner">{error}</div></div>;
  if (!partner) return <div className="page"><div className="card"><div className="spinner" /></div></div>;

  return (
    <div className="page">
      <div className="page-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', flexWrap: 'wrap', gap: 12 }}>
        <div>
          <h1>{partner.nome_fantasia || partner.razao_social}</h1>
          <p>{partner.razao_social} — CNPJ {partner.cnpj} — <span className={`badge ${partner.ativo ? 'status-allow' : 'status-block'}`}>{partner.ativo ? 'Ativo' : 'Inativo'}</span></p>
        </div>
        {canWrite && (
          <div style={{ display: 'flex', gap: 8 }}>
            {!editingCadastro && <button className="btn btn-secondary" onClick={() => setEditingCadastro(true)}>Editar cadastro</button>}
            {partner.ativo ? (
              <button className="btn btn-danger" onClick={() => setArchiveTarget('archive')}>Desativar</button>
            ) : (
              <button className="btn btn-primary" onClick={() => setArchiveTarget('restore')}>Reativar</button>
            )}
          </div>
        )}
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <h3 style={{ marginTop: 0 }}>Cadastro</h3>
        {editingCadastro ? (
          <form onSubmit={handleSaveCadastro}>
            {cadastroError && <div className="error-banner">{cadastroError}</div>}
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12, marginBottom: 12 }}>
              {CADASTRO_FIELDS.map(([f, label]) => (
                <div className="field" key={f}>
                  <label>{label}</label>
                  <input value={cadastroForm?.[f] || ''} onChange={(e) => setCadastroForm({ ...cadastroForm, [f]: e.target.value })} />
                </div>
              ))}
            </div>
            <button type="submit" className="btn btn-primary" disabled={savingCadastro}>{savingCadastro ? 'Salvando…' : 'Salvar cadastro'}</button>{' '}
            <button type="button" className="btn btn-secondary" onClick={() => { setEditingCadastro(false); setCadastroForm(partner); }}>Cancelar</button>
          </form>
        ) : (
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
            <div><strong>E-mail:</strong> {partner.email_contato || '—'}</div>
            <div><strong>Telefone:</strong> {partner.telefone_contato || '—'}</div>
            <div><strong>Site:</strong> {partner.site || '—'}</div>
            <div><strong>IE:</strong> {partner.inscricao_estadual || '—'}</div>
            <div><strong>IM:</strong> {partner.inscricao_municipal || '—'}</div>
            <div><strong>Endereço:</strong> {partner.endereco_logradouro ? `${partner.endereco_logradouro}, ${partner.endereco_numero || 's/n'} — ${partner.endereco_cidade || ''}/${partner.endereco_uf || ''}` : '—'}</div>
          </div>
        )}
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
          <h3 style={{ margin: 0 }}>Responsáveis</h3>
          <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 13, color: 'var(--text-muted, #666)' }}>
              <input type="checkbox" checked={incluirRemovidos} onChange={(e) => setIncluirRemovidos(e.target.checked)} />
              Mostrar removidos
            </label>
            <button className="btn btn-secondary" onClick={() => (showRespForm ? cancelResponsavelForm() : setShowRespForm(true))}>
              {showRespForm ? 'Cancelar' : '+ Adicionar responsável'}
            </button>
          </div>
        </div>
        <p style={{ color: 'var(--text-muted, #666)' }}>
          Marcar "Representante legal" é só um indicador de papel — poder de assinar só é reconhecido com um documento comprobatório anexado (Contrato Social/Procuração/Ata).
        </p>
        {showRespForm && (
          <form onSubmit={handleSaveResponsavel} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12, marginBottom: 12 }}>
            {respError && <div className="error-banner" style={{ gridColumn: 'span 3' }}>{respError}</div>}
            {editingRespId && <div style={{ gridColumn: 'span 3', color: 'var(--text-muted, #666)', fontSize: 13 }}>Editando responsável existente — a classificação (Tipo) também pode ser corrigida aqui.</div>}
            <div className="field"><label>Nome *</label><input required value={respForm.nome} onChange={(e) => setRespForm({ ...respForm, nome: e.target.value })} /></div>
            <div className="field"><label>CPF</label><input value={respForm.cpf} onChange={(e) => setRespForm({ ...respForm, cpf: e.target.value })} /></div>
            <div className="field"><label>Cargo</label><input value={respForm.cargo} onChange={(e) => setRespForm({ ...respForm, cargo: e.target.value })} /></div>
            <div className="field"><label>Departamento</label><input value={respForm.departamento} onChange={(e) => setRespForm({ ...respForm, departamento: e.target.value })} /></div>
            <div className="field"><label>E-mail</label><input value={respForm.email} onChange={(e) => setRespForm({ ...respForm, email: e.target.value })} /></div>
            <div className="field"><label>Telefone</label><input value={respForm.telefone} onChange={(e) => setRespForm({ ...respForm, telefone: e.target.value })} /></div>
            <div className="field"><label>WhatsApp</label><input value={respForm.whatsapp} onChange={(e) => setRespForm({ ...respForm, whatsapp: e.target.value })} /></div>
            <div className="field">
              <label>Tipo (classificação) *</label>
              <select value={respForm.tipo} onChange={(e) => setRespForm({ ...respForm, tipo: e.target.value })}>
                {TIPOS_RESPONSAVEL.map((t) => <option key={t} value={t}>{t}</option>)}
              </select>
            </div>
            <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <input type="checkbox" checked={respForm.representante_legal} onChange={(e) => setRespForm({ ...respForm, representante_legal: e.target.checked })} />
              Indicar como representante legal (papel — não confere poder por si só)
            </label>
            <div style={{ gridColumn: 'span 3' }}>
              <button type="submit" className="btn btn-primary" disabled={savingResp}>{savingResp ? 'Salvando…' : editingRespId ? 'Salvar alterações' : 'Salvar responsável'}</button>
            </div>
          </form>
        )}
        {!responsaveis ? <div className="spinner" /> : responsaveis.length === 0 ? (
          <div className="empty-state">Nenhum responsável cadastrado.</div>
        ) : (
          <table>
            <thead><tr><th>Nome</th><th>Tipo</th><th>Cargo</th><th>Departamento</th><th>E-mail</th><th>Telefone/WhatsApp</th><th>Repr. legal?</th><th>Documento comprobatório</th><th>Status</th><th>Ações</th></tr></thead>
            <tbody>
              {responsaveis.map((r) => (
                <tr key={r.id} style={!r.ativo ? { opacity: 0.6 } : undefined}>
                  <td>{r.nome}</td>
                  <td>{r.tipo}</td>
                  <td>{r.cargo || '—'}</td>
                  <td>{r.departamento || '—'}</td>
                  <td>{r.email || '—'}</td>
                  <td>{r.telefone || r.whatsapp ? [r.telefone, r.whatsapp && `WhatsApp: ${r.whatsapp}`].filter(Boolean).join(' — ') : '—'}</td>
                  <td>{r.representante_legal ? 'Sim (papel)' : '—'}</td>
                  <td>
                    {r.documento_comprobatorio_id ? (
                      <span className="badge status-allow">Anexado</span>
                    ) : documentos && documentos.length > 0 ? (
                      <select defaultValue="" onChange={(e) => e.target.value && setDocumentoComprobatorio(r.id, e.target.value)}>
                        <option value="">Vincular documento…</option>
                        {documentos.map((d) => <option key={d.id} value={d.id}>{d.titulo} ({d.tipo})</option>)}
                      </select>
                    ) : (
                      <span className="badge status-block">Nenhum — sem poder atestado</span>
                    )}
                  </td>
                  <td><span className={`badge ${r.ativo ? 'status-allow' : 'status-block'}`}>{r.ativo ? 'Ativo' : 'Removido'}</span></td>
                  <td>
                    <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                      {r.ativo ? (
                        <>
                          <button className="btn btn-secondary" onClick={() => startEditResponsavel(r)}>Editar</button>
                          <button className="btn btn-danger" onClick={() => handleRemoveResponsavel(r)}>Remover</button>
                        </>
                      ) : (
                        <button className="btn btn-primary" onClick={() => handleRestoreResponsavel(r)}>Restaurar</button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Documentos (Storage privado — link de download expira em 5 min)</h3>
        {docError && <div className="error-banner">{docError}</div>}
        <form onSubmit={handleUploadDoc} style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12, marginBottom: 12 }}>
          <div className="field">
            <label>Tipo</label>
            <select value={docTipo} onChange={(e) => setDocTipo(e.target.value)}>
              {TIPOS_DOCUMENTO.map((t) => <option key={t} value={t}>{t}</option>)}
            </select>
          </div>
          <div className="field"><label>Título *</label><input required value={docTitulo} onChange={(e) => setDocTitulo(e.target.value)} /></div>
          <div className="field">
            <label>Responsável (opcional)</label>
            <select value={docResponsavelId} onChange={(e) => setDocResponsavelId(e.target.value)}>
              <option value="">—</option>
              {(responsaveis || []).map((r) => <option key={r.id} value={r.id}>{r.nome}</option>)}
            </select>
          </div>
          <div className="field"><label>Arquivo (PDF) *</label><input required type="file" accept="application/pdf" onChange={(e) => setDocFile(e.target.files?.[0] || null)} /></div>
          <div style={{ gridColumn: 'span 4' }}><button type="submit" className="btn btn-primary" disabled={uploading}>{uploading ? 'Enviando…' : 'Enviar documento'}</button></div>
        </form>
        {!documentos ? <div className="spinner" /> : documentos.length === 0 ? (
          <div className="empty-state">Nenhum documento anexado.</div>
        ) : (
          <table>
            <thead><tr><th>Título</th><th>Tipo</th><th>Status</th><th>Enviado em</th><th></th></tr></thead>
            <tbody>
              {documentos.map((d) => (
                <tr key={d.id}>
                  <td>{d.titulo}</td>
                  <td>{d.tipo}</td>
                  <td><span className="badge">{d.status}</span></td>
                  <td>{new Date(d.criado_em).toLocaleString('pt-BR')}</td>
                  <td><button className="btn btn-secondary" onClick={() => handleDownload(d.id)}>Baixar</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <h3 style={{ marginTop: 0 }}>Propostas</h3>
        {!propostas ? <div className="spinner" /> : propostas.length === 0 ? (
          <div className="empty-state">Nenhuma proposta vinculada a este proponente ainda.</div>
        ) : (
          <table>
            <thead><tr><th>Número</th><th>Versão</th><th>Status</th><th>Criada em</th><th></th></tr></thead>
            <tbody>
              {propostas.map((p) => (
                <tr key={p.id}>
                  <td>{p.numero}</td>
                  <td>v{p.numero_versao || 1}</td>
                  <td><span className="badge">{p.status}</span></td>
                  <td>{new Date(p.criado_em).toLocaleDateString('pt-BR')}</td>
                  <td><Link className="link-tab" to={`/propostas/${p.id}`}>Ver →</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <h3 style={{ marginTop: 0 }}>Contratos</h3>
        {!contratos ? <div className="spinner" /> : contratos.length === 0 ? (
          <div className="empty-state">Nenhum contrato vinculado a este proponente ainda.</div>
        ) : (
          <table>
            <thead><tr><th>Número</th><th>Status</th><th>Prazo</th><th>Vencimento</th><th></th></tr></thead>
            <tbody>
              {contratos.map((c) => (
                <tr key={c.id}>
                  <td>{c.numero}</td>
                  <td><span className="badge">{c.status}</span></td>
                  <td>{c.prazo_meses} meses</td>
                  <td>{c.data_fim_prevista ? new Date(c.data_fim_prevista).toLocaleDateString('pt-BR') : '—'}</td>
                  <td><Link className="link-tab" to={`/contratos/${c.id}`}>Ver →</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Histórico &amp; Auditoria</h3>
        <p style={{ color: 'var(--text-muted, #666)', marginTop: 0 }}>
          Eventos registrados diretamente sobre o cadastro deste proponente (criação, edição, desativação/reativação).
          Eventos de responsáveis, documentos, propostas e contratos individuais ficam na auditoria de cada um deles —
          ver a tela geral de <Link className="link-tab" to="/auditoria">Auditoria</Link>.
        </p>
        {!historico ? <div className="spinner" /> : historico.length === 0 ? (
          <div className="empty-state">Nenhum evento registrado ainda.</div>
        ) : (
          <table>
            <thead><tr><th>Quando</th><th>Ação</th><th>Motivo</th></tr></thead>
            <tbody>
              {historico.map((h) => (
                <tr key={h.id}>
                  <td>{new Date(h.criado_em).toLocaleString('pt-BR')}</td>
                  <td><span className="badge">{h.acao}</span></td>
                  <td>{h.motivo || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {archiveTarget && (
        <ArchiveModal
          title={archiveTarget === 'archive' ? 'Desativar proponente?' : 'Reativar proponente?'}
          subject={`${partner.nome_fantasia || partner.razao_social} — CNPJ ${partner.cnpj}. ${archiveTarget === 'archive' ? 'O proponente sai das listas ativas e não pode mais receber novas propostas — propostas e contratos já existentes são preservados integralmente.' : 'O proponente volta a poder receber novas propostas.'}`}
          mode={archiveTarget}
          motivoOptions={MOTIVOS_DESATIVACAO}
          onCancel={() => setArchiveTarget(null)}
          onConfirm={async (body) => {
            if (archiveTarget === 'archive') {
              await api.partners.deactivate(id, { motivo: body.motivo });
            } else {
              await api.partners.reactivate(id, { motivo: body.motivo });
            }
            setArchiveTarget(null);
            load();
          }}
        />
      )}
    </div>
  );
}
