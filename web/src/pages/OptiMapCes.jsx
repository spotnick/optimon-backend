// OptiMap — Fase 5: listas de postes com PROJETO APROVADO no CES (Copel), por empresa.
//
// /optimap/ces       lista + envio do arquivo coletado no CES (formato optimap-ocupacoes-ces/1)
// /optimap/ces/:id   prévia: contagens, bloqueios/avisos, conferência por município, itens e ações
//
// Mesmo fluxo das importações de postes: o envio gera uma PRÉVIA; só a aprovação
// (ADMINISTRADOR/DIRETOR) cria ou atualiza ocupações. Ocupação que sai da lista nunca é
// apagada: vira "não consta na última lista do CES".

import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import '../optimap/optimap.css';
import { api } from '../lib/api';
import { Modal, Status } from './OptiMapImportacoes';

const CLASSES = [
  { id: 'NOVA', nome: 'Novas', cor: '#2563eb', desc: 'Poste com projeto aprovado que ainda não estava registrado para esta empresa.' },
  { id: 'MANTIDA', nome: 'Mantidas', cor: '#64748b', desc: 'Já registradas — só renova a data da lista.' },
  { id: 'REATIVADA', nome: 'Reativadas', cor: '#7c3aed', desc: 'Tinham saído de uma lista anterior e voltaram.' },
  { id: 'AUSENTE', nome: 'Não constam', cor: '#d97706', desc: 'Registradas e fora desta lista — viram “não consta na última lista”. Nunca são apagadas.' },
  { id: 'INVALIDO', nome: 'Inválidos', cor: '#111827', desc: 'Sem número ou coordenada válida — nunca aplicados.' },
  { id: 'DUPLICADO', nome: 'Duplicados', cor: '#9ca3af', desc: 'Número repetido no arquivo — vale a primeira ocorrência.' },
];
const NOME = Object.fromEntries(CLASSES.map((c) => [c.id, c.nome]));
const COR = Object.fromEntries(CLASSES.map((c) => [c.id, c.cor]));
const ALERTAS = {
  FORA_DO_MAPA_PUBLICO: 'número não encontrado nos postes da Copel importados (fica com a posição do CES)',
  ENCERRA_MARCACAO_SEM_PROJETO: 'tinha marcação “sem projeto” desta empresa — será encerrada',
};
const MOTIVOS = {
  SEM_NUMERO_DO_POSTE: 'Sem número do poste', SEM_COORDENADA: 'Sem coordenada', COORDENADA_INVALIDA: 'Coordenada inválida / fora do Brasil',
  ALTERADO_POR_IMPORTACAO_POSTERIOR: 'Alterado por lista posterior', ALTERADO_MANUALMENTE_DEPOIS: 'Alterado depois', REGISTRO_NAO_ENCONTRADO: 'Registro não encontrado',
};
const motivo = (m) => (m ? MOTIVOS[m] || m.replace(/_/g, ' ').toLowerCase() : '');
const n = (v) => (v == null ? '—' : Number(v).toLocaleString('pt-BR'));
const dataHora = (v) => (v ? new Date(v).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : '—');
const empresaNome = (e) => (e ? e.nome_fantasia || e.razao_social : '—');

function Lista({ sessao }) {
  const navigate = useNavigate();
  const [lista, setLista] = useState(null);
  const [erro, setErro] = useState(null);
  const [envio, setEnvio] = useState({ arquivo: null, observacoes: '', enviando: false, erro: null });

  const carregar = useCallback(() => {
    setErro(null);
    api.optimap.ces.listar().then(setLista).catch((e) => setErro(e.message));
  }, []);
  useEffect(carregar, [carregar]);

  const enviar = async (ev) => {
    ev.preventDefault();
    if (!envio.arquivo) return;
    setEnvio((x) => ({ ...x, enviando: true, erro: null }));
    try {
      const fd = new FormData();
      fd.append('arquivo', envio.arquivo);
      if (envio.observacoes.trim()) fd.append('observacoes', envio.observacoes.trim());
      const r = await api.optimap.ces.enviar(fd);
      navigate(`/optimap/ces/${r.id}`);
    } catch (e) {
      setEnvio((x) => ({ ...x, enviando: false, erro: e.message }));
    }
  };

  return (
    <div className="page oi-pagina" data-testid="ces">
      <div className="page-header oi-cabecalho">
        <div>
          <div className="oi-trilha"><Link to="/optimap">OptiMap</Link> / Listas do CES</div>
          <h1>Postes com projeto aprovado (CES)</h1>
          <p>Uma lista por empresa, coletada no sistema de Compartilhamento de Estruturas da Copel. Cada lista vira uma prévia; nada muda no mapa antes da aprovação.</p>
        </div>
      </div>

      {sessao.pode_importar && (
        <form className="card oi-envio" onSubmit={enviar} data-testid="ces-envio">
          <h3>Enviar lista coletada no CES</h3>
          <p className="oi-muted">Arquivo <code>ces_&lt;cnpj&gt;_&lt;empresa&gt;_&lt;data&gt;.geojson</code> da pasta <code>tools\optimap\saida\ces</code>. A empresa é identificada pelo CNPJ gravado no arquivo.</p>
          <div className="oi-envio-linha">
            <input type="file" accept=".geojson,.json,application/geo+json,application/json"
              onChange={(e) => setEnvio((x) => ({ ...x, arquivo: e.target.files?.[0] || null, erro: null }))} data-testid="ces-arquivo" />
            <input type="text" placeholder="Observações (opcional)" value={envio.observacoes} maxLength={1000}
              onChange={(e) => setEnvio((x) => ({ ...x, observacoes: e.target.value }))} />
            <button type="submit" className="btn btn-primary" disabled={!envio.arquivo || envio.enviando} data-testid="ces-enviar">
              {envio.enviando ? 'Enviando e calculando a prévia…' : 'Enviar e gerar prévia'}
            </button>
          </div>
          {envio.erro && <div className="error-banner" role="alert" data-testid="ces-envio-erro">{envio.erro}</div>}
        </form>
      )}

      {erro && <div className="error-banner" role="alert">{erro} <button type="button" className="om-link" onClick={carregar}>tentar de novo</button></div>}
      {!lista && !erro && <div className="oi-carregando"><div className="spinner" /> Carregando…</div>}
      {lista && lista.length === 0 && <div className="card oi-vazio" data-testid="ces-lista-vazia">Nenhuma lista do CES enviada ainda.</div>}
      {lista && lista.length > 0 && (
        <div className="card table-scroll">
          <table className="oi-tabela" data-testid="ces-lista">
            <thead><tr><th>Empresa</th><th>Coleta</th><th>Postes</th><th>Resultado</th><th>Status</th><th>Enviado</th></tr></thead>
            <tbody>
              {lista.map((i) => (
                <tr key={i.id} className="oi-clicavel" onClick={() => navigate(`/optimap/ces/${i.id}`)}>
                  <td><Link to={`/optimap/ces/${i.id}`} onClick={(e) => e.stopPropagation()}>{i.nome_fantasia || i.razao_social}</Link><div className="oi-muted">{i.razao_social}</div></td>
                  <td>{dataHora(i.data_referencia)}</td>
                  <td>{n(i.total_recebido)}</td>
                  <td className="oi-contagens-mini">
                    {i.contagens ? CLASSES.filter((c) => i.contagens[c.id]).map((c) => <span key={c.id} title={c.nome}><i style={{ background: c.cor }} />{n(i.contagens[c.id])}</span>) : '—'}
                  </td>
                  <td><Status s={i.status} /></td>
                  <td>{dataHora(i.criado_em)}<div className="oi-muted">{i.criado_por_nome || ''}</div></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

export function TabelaConferencia({ linhas }) {
  if (!Array.isArray(linhas) || linhas.length === 0) return <p className="oi-muted">Sem dados para conferir ainda.</p>;
  const comLista = linhas.some((l) => l.na_lista != null);
  return (
    <div className="table-scroll">
      <table className="oi-tabela" data-testid="ces-conferencia">
        <thead><tr><th>Município</th>{comLista && <th>Postes nesta lista</th>}<th>Ativas no OptiMap</th><th>Tabela do CES (faturados)</th><th>Diferença</th><th>Lote de postes no OptiMon</th></tr></thead>
        <tbody>
          {linhas.map((l) => {
            // Diferença: o que a lista (ou, sem lista, o OptiMap) tem a mais/menos que a tabela do CES.
            const base = l.na_lista != null ? l.na_lista : (l.ativas_optimap || 0);
            const dif = l.tabela_ces == null ? null : base - l.tabela_ces;
            const difLote = l.lote_optimap == null || l.tabela_ces == null ? null : l.lote_optimap - l.tabela_ces;
            return (
              <tr key={l.municipio}>
                <td>{l.municipio}</td>
                {comLista && <td>{n(l.na_lista)}</td>}
                <td>{n(l.ativas_optimap)}</td>
                <td>{n(l.tabela_ces)}</td>
                <td className={dif ? 'oi-dif' : ''}>{dif == null ? '—' : dif > 0 ? `+${n(dif)}` : n(dif)}</td>
                <td>{n(l.lote_optimap)}{difLote ? <span className="oi-muted"> ({difLote > 0 ? '+' : ''}{n(difLote)} vs CES)</span> : null}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
      <p className="oi-muted">“Diferença” compara {comLista ? 'os postes desta lista' : 'as ocupações ativas'} com a tabela do CES. “Tabela do CES” é a contagem por cidade da tela Consulta Pontos, gravada no arquivo na hora da coleta. “Lote de postes” é a quantidade cadastrada em Cidades &amp; Infraestrutura (o OptiMap não altera esse valor).</p>
    </div>
  );
}

function Detalhe({ id, sessao }) {
  const navigate = useNavigate();
  const [imp, setImp] = useState(null);
  const [erro, setErro] = useState(null);
  const [filtro, setFiltro] = useState(null);
  const [itens, setItens] = useState(null);
  const [pagina, setPagina] = useState(0);
  const [busca, setBusca] = useState('');
  const [modal, setModal] = useState(null);
  const [mensagem, setMensagem] = useState(null);
  const [confirma, setConfirma] = useState(false);
  const POR_PAGINA = 50;

  const carregar = useCallback(async () => {
    setErro(null);
    try { setImp(await api.optimap.ces.detalhe(id)); } catch (e) { setErro(e.status === 404 ? 'Lista não encontrada (ou sem permissão para vê-la).' : e.message); }
  }, [id]);
  useEffect(() => { carregar(); }, [carregar]);
  const carregarItens = useCallback(() => {
    api.optimap.ces.itens(id, { classificacao: filtro, busca: busca.trim(), limite: POR_PAGINA, offset: pagina * POR_PAGINA })
      .then(setItens).catch((e) => setItens({ erro: e.message }));
  }, [id, filtro, busca, pagina]);
  useEffect(() => { const t = setTimeout(carregarItens, busca ? 300 : 0); return () => clearTimeout(t); }, [carregarItens, busca]);

  if (erro) return <div className="page"><div className="error-banner" role="alert">{erro}</div><Link to="/optimap/ces">← Listas do CES</Link></div>;
  if (!imp) return <div className="page oi-carregando"><div className="spinner" /> Carregando a prévia…</div>;

  const resumo = imp.resumo || {};
  const contagens = resumo.contagens || {};
  const bloqueios = resumo.bloqueios || [];
  const avisos = resumo.avisos || [];
  const exigeConfirmacao = avisos.some((a) => a.exige_confirmacao);
  const podeEditar = ['ADMINISTRADOR', 'ENGENHARIA'].includes(sessao.role);
  const emPrevia = imp.status === 'PREVIA';
  const meta = imp.metadados_coletor || {};
  const depois = async (msg) => { setModal(null); setMensagem(msg); await carregar(); carregarItens(); };

  return (
    <div className="page oi-pagina" data-testid="ces-detalhe">
      <div className="page-header oi-cabecalho">
        <div>
          <div className="oi-trilha"><Link to="/optimap">OptiMap</Link> / <Link to="/optimap/ces">Listas do CES</Link> / {empresaNome(imp.empresa)}</div>
          <h1>{empresaNome(imp.empresa)} <Status s={imp.status} /></h1>
          <p>{imp.empresa?.razao_social} · CNPJ {imp.empresa?.cnpj} · UC {imp.empresa?.uc_copel || '—'}{imp.empresa?.contrato_copel ? ` · contrato ${imp.empresa.contrato_copel}` : ''}</p>
          <p>Coleta de {dataHora(imp.data_referencia)} · {n(imp.total_recebido)} postes na lista{meta.referencia_ces?.total_tabela_consulta_pontos != null ? ` · ${n(meta.referencia_ces.total_tabela_consulta_pontos)} na tabela Consulta Pontos do CES` : ''}</p>
          <p className="oi-muted">
            Arquivo {imp.arquivo_nome_original} · enviado por {imp.usuarios?.[imp.criado_por] || '—'} em {dataHora(imp.criado_em)}
            {imp.aprovado_em && ` · aprovado por ${imp.usuarios?.[imp.aprovado_por] || '—'} em ${dataHora(imp.aprovado_em)}`}
            {imp.revertido_em && ` · revertido em ${dataHora(imp.revertido_em)} (${imp.motivo_reversao})`}
            {imp.rejeitado_em && ` · rejeitado: ${imp.motivo_rejeicao}`}
          </p>
        </div>
        <div className="oi-acoes" data-testid="ces-acoes">
          {emPrevia && podeEditar && <button type="button" className="btn btn-secondary btn-sm" onClick={() => setModal('reprocessar')}>Recalcular prévia</button>}
          {['RECEBIDA', 'PREVIA'].includes(imp.status) && podeEditar && <button type="button" className="btn btn-secondary btn-sm" onClick={() => setModal('descartar')}>Descartar</button>}
          {['RECEBIDA', 'PREVIA'].includes(imp.status) && sessao.pode_aprovar_importacao && <button type="button" className="btn btn-danger btn-sm" onClick={() => setModal('rejeitar')}>Rejeitar</button>}
          {emPrevia && sessao.pode_aprovar_importacao && (
            <button type="button" className="btn btn-primary" disabled={!resumo.pode_aprovar || (exigeConfirmacao && !confirma)} onClick={() => setModal('aprovar')} data-testid="ces-aprovar">Aprovar e aplicar</button>
          )}
          {['IMPORTADA', 'REVERTIDA_PARCIALMENTE'].includes(imp.status) && sessao.pode_reverter_importacao && (
            <button type="button" className="btn btn-danger btn-sm" onClick={() => setModal('reverter')} data-testid="ces-reverter">{imp.status === 'IMPORTADA' ? 'Reverter lista' : 'Tentar reverter o restante'}</button>
          )}
        </div>
      </div>

      {mensagem && <div className="oi-sucesso" role="status" data-testid="ces-mensagem">{mensagem}</div>}
      {emPrevia && (bloqueios.length > 0 || avisos.length > 0) && (
        <div className="oi-alertas">
          {bloqueios.map((b) => <div key={b.codigo} className="oi-bloqueio" role="alert">⛔ {b.mensagem}</div>)}
          {avisos.map((a) => (
            <div key={a.codigo} className="oi-aviso">⚠ {a.mensagem}
              {a.exige_confirmacao && sessao.pode_aprovar_importacao && (
                <label className="oi-confirma"><input type="checkbox" checked={confirma} onChange={(e) => setConfirma(e.target.checked)} /> Confirmo que a coleta está completa (os postes fora da lista viram “não consta”, nada é apagado).</label>
              )}
            </div>
          ))}
        </div>
      )}
      {emPrevia && bloqueios.length === 0 && !sessao.pode_aprovar_importacao && <div className="oi-aviso">Prévia pronta. A aprovação é feita por ADMINISTRADOR ou DIRETOR.</div>}
      {resumo.alertas_por_tipo && Object.keys(resumo.alertas_por_tipo).length > 0 && (
        <div className="oi-aviso">{Object.entries(resumo.alertas_por_tipo).map(([k, v]) => `${n(v)} ${ALERTAS[k] || k}`).join(' · ')}</div>
      )}

      <div className="oi-cartoes" data-testid="ces-contagens">
        {CLASSES.map((c) => (
          <button key={c.id} type="button" className={`oi-cartao${filtro === c.id ? ' oi-ativo' : ''}`} title={c.desc}
            onClick={() => { setFiltro((f) => (f === c.id ? null : c.id)); setPagina(0); }} data-testid={`ces-cartao-${c.id}`}>
            <span className="oi-cartao-cor" style={{ background: c.cor }} />
            <span className="oi-cartao-nome">{c.nome}</span>
            <span className="oi-cartao-valor">{n(contagens[c.id] || 0)}</span>
          </button>
        ))}
      </div>

      <div className="card">
        <h3>Conferência por município</h3>
        <TabelaConferencia linhas={imp.conferencia} />
      </div>

      <div className="card oi-itens">
        <div className="oi-itens-topo">
          <b>{filtro ? NOME[filtro] : 'Todos os itens'}</b>
          <input type="search" placeholder="Número do poste" value={busca} onChange={(e) => { setBusca(e.target.value); setPagina(0); }} />
        </div>
        {itens?.erro && <div className="error-banner">{itens.erro}</div>}
        {!itens && <div className="oi-carregando"><div className="spinner" /></div>}
        {itens?.itens && (
          <>
            <div className="table-scroll">
              <table className="oi-tabela oi-tabela-itens" data-testid="ces-itens">
                <thead><tr><th>Poste</th><th>Classificação</th><th>Situação Copel</th><th>Detalhe</th></tr></thead>
                <tbody>
                  {itens.itens.length === 0 && <tr><td colSpan={4} className="oi-muted">Nenhum item.</td></tr>}
                  {itens.itens.map((i) => (
                    <tr key={i.id}>
                      <td className="om-mono">{i.id_externo || '(sem número)'}{i.linha != null && <div className="oi-muted">linha {i.linha + 1}</div>}</td>
                      <td><span className="oi-classe" style={{ borderColor: COR[i.classificacao], color: COR[i.classificacao] }}>{NOME[i.classificacao] || i.classificacao}</span></td>
                      <td>{i.situacao_copel || '—'}</td>
                      <td className="oi-detalhe-item">
                        {i.motivo && <div>{motivo(i.motivo)}</div>}
                        {(i.alertas || []).map((a, k) => <div key={k} className="oi-alerta-item">⚠ {ALERTAS[a.tipo] || a.tipo}</div>)}
                        {i.aplicado && <div className="oi-muted">aplicado</div>}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <div className="oi-paginacao">
              <span className="oi-muted">{n(itens.total)} itens</span>
              <button type="button" className="btn btn-sm btn-secondary" disabled={pagina === 0} onClick={() => setPagina((p) => p - 1)}>anterior</button>
              <span>página {pagina + 1} de {Math.max(1, Math.ceil(itens.total / POR_PAGINA))}</span>
              <button type="button" className="btn btn-sm btn-secondary" disabled={(pagina + 1) * POR_PAGINA >= itens.total} onClick={() => setPagina((p) => p + 1)}>próxima</button>
            </div>
          </>
        )}
      </div>

      {modal === 'aprovar' && (
        <Modal titulo="Aprovar e aplicar a lista do CES"
          texto={`${n(contagens.NOVA || 0)} ocupações novas, ${n((contagens.MANTIDA || 0) + (contagens.REATIVADA || 0))} confirmadas e ${n(contagens.AUSENTE || 0)} marcadas como “não consta na última lista”. Tudo é registrado e pode ser revertido.`}
          rotulo="Aprovar e aplicar" onFechar={() => setModal(null)}
          onConfirmar={async () => {
            const r = await api.optimap.ces.aprovar(id, { confirmar_ausencias: confirma });
            await depois(`Lista aplicada: ${n(r.novas)} novas, ${n(r.mantidas)} confirmadas, ${n(r.nao_constam)} não constam, ${n(r.marcacoes_encerradas)} marcações “sem projeto” encerradas.`);
          }} />
      )}
      {modal === 'reprocessar' && (
        <Modal titulo="Recalcular prévia" texto="Compara de novo a lista com as ocupações atuais." rotulo="Recalcular"
          onFechar={() => setModal(null)} onConfirmar={async () => { await api.optimap.ces.reprocessar(id); await depois('Prévia recalculada.'); }} />
      )}
      {modal === 'descartar' && (
        <Modal titulo="Descartar lista" texto="A prévia fica no histórico como descartada. Nada foi aplicado." rotulo="Descartar"
          onFechar={() => setModal(null)} onConfirmar={async (m) => { await api.optimap.ces.descartar(id, m || null); await depois('Lista descartada.'); }} />
      )}
      {modal === 'rejeitar' && (
        <Modal titulo="Rejeitar lista" texto="Nada será aplicado. O motivo fica registrado na auditoria." rotulo="Rejeitar" perigo exigeMotivo
          onFechar={() => setModal(null)} onConfirmar={async (m) => { await api.optimap.ces.rejeitar(id, m); await depois('Lista rejeitada.'); }} />
      )}
      {modal === 'reverter' && (
        <Modal titulo="Reverter lista do CES"
          texto="Desfaz, em ordem inversa, só o que esta lista gravou e que continua como ela deixou. Ocupações alteradas depois (por outra lista) não são tocadas."
          rotulo="Reverter" perigo exigeMotivo onFechar={() => setModal(null)}
          onConfirmar={async (m) => {
            const r = await api.optimap.ces.reverter(id, m);
            await depois(r.status === 'REVERTIDA' ? `Reversão completa (${n(r.revertidas_agora)} alterações desfeitas).` : `Reversão parcial: ${n(r.revertidas_agora)} desfeitas, ${n(r.pendentes)} mantidas.`);
          }} />
      )}
      <div className="oi-rodape"><button type="button" className="om-link" onClick={() => navigate('/optimap/ces')}>← voltar às listas do CES</button></div>
    </div>
  );
}

export default function OptiMapCes() {
  const { id } = useParams();
  const [sessao, setSessao] = useState({ carregando: true });
  useEffect(() => {
    let vivo = true;
    api.optimap.sessao().then((s) => vivo && setSessao({ ...s, carregando: false }))
      .catch((e) => vivo && setSessao({ carregando: false, erro: e.message, status: e.status }));
    return () => { vivo = false; };
  }, []);
  if (sessao.carregando) return <div className="page oi-carregando"><div className="spinner" /> Verificando acesso…</div>;
  if (sessao.erro || !sessao.pode_ver_importacoes) {
    return (
      <div className="page"><div className="card" role="alert" data-testid="ces-sem-acesso">
        <h2>Sem acesso às listas do CES</h2>
        <p>{sessao.erro && sessao.status !== 403 ? `Não foi possível falar com a API (${sessao.erro}).` : 'Listas do CES são acessíveis a ENGENHARIA, DIRETOR e ADMINISTRADOR.'}</p>
        <Link to="/optimap">← voltar ao mapa</Link>
      </div></div>
    );
  }
  return id ? <Detalhe key={id} id={id} sessao={sessao} /> : <Lista sessao={sessao} />;
}
