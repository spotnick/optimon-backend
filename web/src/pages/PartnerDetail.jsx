import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { api, ApiError } from '../lib/api';

const TIPOS_RESPONSAVEL = ['REPRESENTANTE_LEGAL', 'RESPONSAVEL_COMERCIAL', 'RESPONSAVEL_FINANCEIRO', 'RESPONSAVEL_TECNICO', 'TESTEMUNHA', 'OUTRO'];
const TIPOS_DOCUMENTO = ['CONTRATO_SOCIAL', 'CARTAO_CNPJ', 'PROCURACAO', 'ATA', 'OUTRO'];

function emptyResponsavel() {
  return { nome: '', cpf: '', cargo: '', email: '', telefone: '', tipo: 'REPRESENTANTE_LEGAL', representante_legal: false };
}

export default function PartnerDetail() {
  const { id } = useParams();
  const [partner, setPartner] = useState(null);
  const [responsaveis, setResponsaveis] = useState(null);
  const [documentos, setDocumentos] = useState(null);
  const [error, setError] = useState(null);

  const [showRespForm, setShowRespForm] = useState(false);
  const [respForm, setRespForm] = useState(emptyResponsavel());
  const [savingResp, setSavingResp] = useState(false);
  const [respError, setRespError] = useState(null);

  const [docTipo, setDocTipo] = useState(TIPOS_DOCUMENTO[0]);
  const [docTitulo, setDocTitulo] = useState('');
  const [docFile, setDocFile] = useState(null);
  const [docResponsavelId, setDocResponsavelId] = useState('');
  const [uploading, setUploading] = useState(false);
  const [docError, setDocError] = useState(null);

  function load() {
    api.partners.get(id).then(setPartner).catch((err) => setError(err.message));
    api.partners.responsaveis(id).then(setResponsaveis).catch((err) => setError(err.message));
    api.partners.documentos(id).then(setDocumentos).catch((err) => setError(err.message));
  }
  useEffect(load, [id]);

  async function handleAddResponsavel(e) {
    e.preventDefault();
    setRespError(null);
    setSavingResp(true);
    try {
      await api.partners.addResponsavel(id, respForm);
      setRespForm(emptyResponsavel());
      setShowRespForm(false);
      load();
    } catch (err) {
      setRespError(err instanceof ApiError ? err.message : 'Erro inesperado.');
    } finally {
      setSavingResp(false);
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
      <div className="page-header">
        <h1>{partner.nome_fantasia || partner.razao_social}</h1>
        <p>{partner.razao_social} — CNPJ {partner.cnpj}</p>
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <h3 style={{ marginTop: 0 }}>Cadastro</h3>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
          <div><strong>E-mail:</strong> {partner.email_contato || '—'}</div>
          <div><strong>Telefone:</strong> {partner.telefone_contato || '—'}</div>
          <div><strong>Site:</strong> {partner.site || '—'}</div>
          <div><strong>IE:</strong> {partner.inscricao_estadual || '—'}</div>
          <div><strong>IM:</strong> {partner.inscricao_municipal || '—'}</div>
          <div><strong>Endereço:</strong> {partner.endereco_logradouro ? `${partner.endereco_logradouro}, ${partner.endereco_numero || 's/n'} — ${partner.endereco_cidade || ''}/${partner.endereco_uf || ''}` : '—'}</div>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h3 style={{ margin: 0 }}>Responsáveis</h3>
          <button className="btn btn-secondary" onClick={() => setShowRespForm((s) => !s)}>{showRespForm ? 'Cancelar' : '+ Adicionar responsável'}</button>
        </div>
        <p style={{ color: 'var(--text-muted, #666)' }}>
          Marcar "Representante legal" é só um indicador de papel — poder de assinar só é reconhecido com um documento comprobatório anexado (Contrato Social/Procuração/Ata).
        </p>
        {showRespForm && (
          <form onSubmit={handleAddResponsavel} style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 12, marginBottom: 12 }}>
            {respError && <div className="error-banner" style={{ gridColumn: 'span 3' }}>{respError}</div>}
            <div className="field"><label>Nome *</label><input required value={respForm.nome} onChange={(e) => setRespForm({ ...respForm, nome: e.target.value })} /></div>
            <div className="field"><label>CPF</label><input value={respForm.cpf} onChange={(e) => setRespForm({ ...respForm, cpf: e.target.value })} /></div>
            <div className="field"><label>Cargo</label><input value={respForm.cargo} onChange={(e) => setRespForm({ ...respForm, cargo: e.target.value })} /></div>
            <div className="field"><label>E-mail</label><input value={respForm.email} onChange={(e) => setRespForm({ ...respForm, email: e.target.value })} /></div>
            <div className="field"><label>Telefone</label><input value={respForm.telefone} onChange={(e) => setRespForm({ ...respForm, telefone: e.target.value })} /></div>
            <div className="field">
              <label>Tipo *</label>
              <select value={respForm.tipo} onChange={(e) => setRespForm({ ...respForm, tipo: e.target.value })}>
                {TIPOS_RESPONSAVEL.map((t) => <option key={t} value={t}>{t}</option>)}
              </select>
            </div>
            <label style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <input type="checkbox" checked={respForm.representante_legal} onChange={(e) => setRespForm({ ...respForm, representante_legal: e.target.checked })} />
              Indicar como representante legal (papel — não confere poder por si só)
            </label>
            <div style={{ gridColumn: 'span 3' }}><button type="submit" className="btn btn-primary" disabled={savingResp}>{savingResp ? 'Salvando…' : 'Salvar responsável'}</button></div>
          </form>
        )}
        {!responsaveis ? <div className="spinner" /> : responsaveis.length === 0 ? (
          <div className="empty-state">Nenhum responsável cadastrado.</div>
        ) : (
          <table>
            <thead><tr><th>Nome</th><th>Tipo</th><th>Cargo</th><th>E-mail</th><th>Repr. legal?</th><th>Documento comprobatório</th></tr></thead>
            <tbody>
              {responsaveis.map((r) => (
                <tr key={r.id}>
                  <td>{r.nome}</td>
                  <td>{r.tipo}</td>
                  <td>{r.cargo || '—'}</td>
                  <td>{r.email || '—'}</td>
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
    </div>
  );
}
