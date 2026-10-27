// OptiMap — Fase 5: empresas com contrato de compartilhamento Copel (cada ocupação de poste
// identifica a empresa responsável). Todos que veem o mapa veem a lista; só ADMINISTRADOR
// cadastra/edita. A conferência compara as ocupações ativas com a tabela do CES e com o lote
// de postes cadastrado no OptiMon.

import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import '../optimap/optimap.css';
import { api } from '../lib/api';
import { TabelaConferencia } from './OptiMapCes';

const VAZIA = { razao_social: '', nome_fantasia: '', cnpj: '', uc_copel: '', contrato_copel: '', ativa: true, observacoes: '' };
const fmtCnpj = (c) => (c && c.length === 14 ? c.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, '$1.$2.$3/$4-$5') : c || '—');

export default function OptiMapEmpresas() {
  const [sessao, setSessao] = useState({ carregando: true });
  const [lista, setLista] = useState(null);
  const [erro, setErro] = useState(null);
  const [form, setForm] = useState(null); // { id?, ...campos }
  const [salvando, setSalvando] = useState(false);
  const [erroForm, setErroForm] = useState(null);
  const [conferencia, setConferencia] = useState({}); // empresa_id -> linhas | { erro }

  useEffect(() => {
    api.optimap.sessao().then((s) => setSessao({ ...s, carregando: false })).catch((e) => setSessao({ carregando: false, erro: e.message, status: e.status }));
  }, []);
  const carregar = useCallback(() => {
    setErro(null);
    api.optimap.empresas.listar().then(setLista).catch((e) => setErro(e.message));
  }, []);
  useEffect(() => { if (sessao.pode_ver) carregar(); }, [sessao.pode_ver, carregar]);

  const salvar = async (ev) => {
    ev.preventDefault();
    setSalvando(true); setErroForm(null);
    try {
      const { id, ...campos } = form;
      await api.optimap.empresas.salvar(id || null, campos);
      setForm(null); carregar();
    } catch (e) { setErroForm(e.message); } finally { setSalvando(false); }
  };
  const verConferencia = async (id) => {
    setConferencia((c) => ({ ...c, [id]: 'carregando' }));
    try { const l = await api.optimap.empresas.conferencia(id); setConferencia((c) => ({ ...c, [id]: l })); } catch (e) { setConferencia((c) => ({ ...c, [id]: { erro: e.message } })); }
  };

  if (sessao.carregando) return <div className="page oi-carregando"><div className="spinner" /> Verificando acesso…</div>;
  if (sessao.erro) return <div className="page"><div className="card" role="alert"><h2>Sem acesso</h2><p>{sessao.erro}</p><Link to="/optimap">← voltar ao mapa</Link></div></div>;
  const podeConferir = ['ADMINISTRADOR', 'DIRETOR', 'ENGENHARIA'].includes(sessao.role);
  const campo = (k, rotulo, props = {}) => (
    <label className="oi-campo">{rotulo}
      <input type="text" value={form[k] ?? ''} onChange={(e) => setForm({ ...form, [k]: e.target.value })} {...props} data-testid={`emp-${k}`} />
    </label>
  );

  return (
    <div className="page oi-pagina" data-testid="empresas">
      <div className="page-header oi-cabecalho">
        <div>
          <div className="oi-trilha"><Link to="/optimap">OptiMap</Link> / Empresas</div>
          <h1>Empresas com contrato de compartilhamento</h1>
          <p>Cada ocupação de poste (projeto aprovado no CES ou marcação da engenharia) fica ligada a uma destas empresas.</p>
        </div>
        <div className="oi-acoes">
          {sessao.pode_gerir_empresas && !form && <button type="button" className="btn btn-primary" onClick={() => { setErroForm(null); setForm({ ...VAZIA }); }} data-testid="emp-nova">Nova empresa</button>}
        </div>
      </div>

      {form && (
        <form className="card oi-form-empresa" onSubmit={salvar} data-testid="emp-form">
          <h3>{form.id ? 'Editar empresa' : 'Nova empresa'}</h3>
          <div className="oi-form-grade">
            {campo('razao_social', 'Razão social', { required: true, maxLength: 200 })}
            {campo('nome_fantasia', 'Nome fantasia', { maxLength: 120 })}
            {campo('cnpj', 'CNPJ', { required: true, maxLength: 18, placeholder: '00.000.000/0000-00' })}
            {campo('uc_copel', 'UC Copel (unidade consumidora do contrato)', { maxLength: 30 })}
            {campo('contrato_copel', 'Nº do contrato com a Copel', { maxLength: 120 })}
            {campo('observacoes', 'Observações', { maxLength: 1000 })}
            <label className="oi-confirma"><input type="checkbox" checked={!!form.ativa} onChange={(e) => setForm({ ...form, ativa: e.target.checked })} /> Ativa</label>
          </div>
          {erroForm && <div className="error-banner" role="alert">{erroForm}</div>}
          <div className="modal-actions">
            <button type="button" className="btn btn-secondary" onClick={() => setForm(null)} disabled={salvando}>Cancelar</button>
            <button type="submit" className="btn btn-primary" disabled={salvando} data-testid="emp-salvar">{salvando ? 'Salvando…' : 'Salvar'}</button>
          </div>
        </form>
      )}

      {erro && <div className="error-banner" role="alert">{erro}</div>}
      {!lista && !erro && <div className="oi-carregando"><div className="spinner" /> Carregando…</div>}
      {lista && lista.map((e) => (
        <div key={e.id} className="card oi-empresa" data-testid="emp-item">
          <div className="oi-empresa-topo">
            <div>
              <h3>{e.nome_fantasia || e.razao_social} {!e.ativa && <span className="oi-status oi-st-neutro">inativa</span>}</h3>
              <p>{e.razao_social} · CNPJ {fmtCnpj(e.cnpj)} · UC {e.uc_copel || '—'}{e.contrato_copel ? ` · contrato ${e.contrato_copel}` : ''}</p>
              {e.observacoes && <p className="oi-muted">{e.observacoes}</p>}
            </div>
            <div className="oi-acoes">
              {podeConferir && <button type="button" className="btn btn-secondary btn-sm" onClick={() => verConferencia(e.id)} data-testid="emp-conferir">Conferir com o CES</button>}
              {sessao.pode_gerir_empresas && <button type="button" className="btn btn-secondary btn-sm" onClick={() => { setErroForm(null); setForm({ ...VAZIA, ...e, nome_fantasia: e.nome_fantasia || '', uc_copel: e.uc_copel || '', contrato_copel: e.contrato_copel || '', observacoes: e.observacoes || '' }); }}>Editar</button>}
            </div>
          </div>
          {conferencia[e.id] === 'carregando' && <div className="oi-carregando"><div className="spinner" /></div>}
          {conferencia[e.id]?.erro && <div className="error-banner">{conferencia[e.id].erro}</div>}
          {Array.isArray(conferencia[e.id]) && <TabelaConferencia linhas={conferencia[e.id]} />}
        </div>
      ))}
    </div>
  );
}
