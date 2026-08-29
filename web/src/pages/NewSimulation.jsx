import { useEffect, useState, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import { api } from '../lib/api';
import { ApiError } from '../lib/api';
import ReguaDePreco from '../components/ReguaDePreco';
import GrowthRevenueChart from '../components/charts/GrowthRevenueChart';
import ClientsPonsChart from '../components/charts/ClientsPonsChart';
import { formatCurrencyFull } from '../components/charts/chartUtils';
import HelpTooltip from '../components/HelpTooltip';

const QUICK_CLIENTS = [10, 25, 50, 100, 128, 129, 200, 256, 384, 500, 1000];
// Fase 3.8 (item 3): "MAX" (greatest(piso, revenue share)) foi identificado como a
// inconsistência a corrigir no modelo econômico oficial e removido das opções — o
// modelo passa a ser sempre MÍNIMO/PISO + REVENUE SHARE (somado). FLOOR_ONLY e
// MINIMUM_ONLY continuam por não implementarem MAX (servem casos sem componente de
// Revenue Share, ex.: Dark Fiber) — ver comentário de app.get_economia_com_piso.
const COMPOSICAO_MODES = ['FLOOR_AS_MINIMUM', 'FLOOR_ONLY', 'MINIMUM_ONLY', 'SUM'];

function Field({ label, children }) {
  return (
    <div className="field">
      <label>{label}</label>
      {children}
    </div>
  );
}

export default function NewSimulation() {
  const navigate = useNavigate();

  const [cities, setCities] = useState([]);
  const [cityDetail, setCityDetail] = useState(null);
  const [cidadeId, setCidadeId] = useState('');
  const [popId, setPopId] = useState('');

  const [clientes, setClientes] = useState(128);
  const [arpu, setArpu] = useState(100);
  const [faturamentoOverride, setFaturamentoOverride] = useState('');
  const [revenueSharePct, setRevenueSharePct] = useState(0.12);
  const [composicaoMode, setComposicaoMode] = useState('FLOOR_AS_MINIMUM');
  const [prazoMeses, setPrazoMeses] = useState(48);
  const [carenciaMeses, setCarenciaMeses] = useState(0);
  const [reajusteIndice, setReajusteIndice] = useState('IPCA');
  const [capex, setCapex] = useState(50000);
  const [opexMensal, setOpexMensal] = useState(0);

  // Fase 2.4 (seção 6): dados de capa da proposta — parceiro cadastrado (opcional) ou
  // nome livre, cargo do contato, validade e preço proposto (nunca recalculado no
  // frontend — só ecoado de volta pro backend, que sempre recalcula floor/recommended).
  const [partners, setPartners] = useState([]);
  const [parceiroId, setParceiroId] = useState('');
  const [parceiroNomeCapa, setParceiroNomeCapa] = useState('');
  const [parceiroCargoContato, setParceiroCargoContato] = useState('');
  const [validadeDias, setValidadeDias] = useState(15);
  const [precoProposto, setPrecoProposto] = useState('');
  const [precoPropostoTocado, setPrecoPropostoTocado] = useState(false);

  const [pricing, setPricing] = useState(null);
  const [curve, setCurve] = useState(null);
  const [horizonTable, setHorizonTable] = useState(null);
  const [ramp, setRamp] = useState(null);

  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [proposalStatus, setProposalStatus] = useState(null);

  useEffect(() => {
    api.cities.list().then((list) => {
      setCities(list);
      // Nenhuma cidade especial — seleciona a primeira da lista (ordenada por nome pela
      // API) só como conveniência de UX, igual a qualquer outro <select> pré-preenchido.
      if (list.length > 0) setCidadeId(list[0].cidade_id);
    }).catch((err) => setError(err.message));
    api.pricing.ramp().then(setRamp).catch(() => {});
    api.partners.list().then(setPartners).catch(() => {});
  }, []);

  useEffect(() => {
    if (!cidadeId) return;
    api.cities.detail(cidadeId).then(setCityDetail).catch((err) => setError(err.message));
    setPopId('');
  }, [cidadeId]);

  const runSimulation = useCallback(async () => {
    if (!cidadeId) return;
    setLoading(true);
    setError(null);
    setProposalStatus(null);
    try {
      const baseParams = {
        cidade_id: cidadeId,
        pop_id: popId || null,
        clientes: Number(clientes),
        arpu: Number(arpu),
        faturamento: faturamentoOverride !== '' ? Number(faturamentoOverride) : null,
        revenue_share_pct: Number(revenueSharePct),
        composicao_mode: composicaoMode,
        // Fase 2.4 (seção 6/38): preço proposto — se o usuário ainda não digitou nada,
        // o backend recomenda (recommended) e o campo é prefilled com esse valor assim
        // que a resposta chega (ver efeito abaixo); nunca inventado no frontend.
        preco_proposto: precoProposto !== '' ? Number(precoProposto) : null,
      };
      const [calc, curveData, horizon] = await Promise.all([
        api.pricing.calculate(baseParams),
        api.pricing.growthCurve({ ...baseParams, passos: 16 }),
        api.pricing.horizonTable({ ...baseParams, capex: Number(capex), opex_mensal: Number(opexMensal) }),
      ]);
      setPricing(calc);
      setCurve(curveData);
      setHorizonTable(horizon);
      if (!precoPropostoTocado && calc?.recommended != null) {
        setPrecoProposto(String(calc.recommended));
      }
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Erro ao calcular. Tente novamente.');
    } finally {
      setLoading(false);
    }
  }, [cidadeId, popId, clientes, arpu, faturamentoOverride, revenueSharePct, composicaoMode, capex, opexMensal, precoProposto, precoPropostoTocado]);

  useEffect(() => {
    if (cidadeId) runSimulation();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cidadeId]);

  async function handleGerarProposta() {
    if (!pricing) return;
    setProposalStatus('salvando');
    setError(null);
    try {
      const sim = await api.simulations.save({
        cidade_id: cidadeId,
        modelo: 'HIBRIDO_REVENUE_SHARE',
        pares_ou_clientes: Number(clientes),
        arpu: Number(arpu),
        revenue_share_pct: Number(revenueSharePct),
        prazo_meses: Number(prazoMeses),
        resultado: {
          ...pricing,
          carencia_meses: Number(carenciaMeses),
          reajuste_indice: reajusteIndice,
          horizon_table: horizonTable,
          rampa: ramp,
        },
      });
      const proposta = await api.proposals.create({
        simulacao_id: sim.id,
        cidade_id: cidadeId,
        parceiro_id: parceiroId || null,
        parceiro_nome_capa: parceiroNomeCapa || null,
        parceiro_cargo_contato: parceiroCargoContato || null,
        validade_dias: Number(validadeDias) || 15,
      });
      setProposalStatus({ numero: proposta.numero, id: proposta.id });
    } catch (err) {
      setProposalStatus(null);
      setError(err instanceof ApiError ? err.message : 'Erro ao gerar proposta.');
    }
  }

  const cityName = cities.find((c) => c.cidade_id === cidadeId)?.nome;

  return (
    <div className="page">
      <div className="page-header">
        <h1>Nova Simulação</h1>
        <p>Escolha cidade, clientes e ARPU — a régua de preço recalcula automaticamente.</p>
      </div>

      {error && <div className="error-banner">{error}</div>}

      <div className="card" style={{ marginBottom: 24 }}>
        <div className="form-grid">
          <Field label="Cidade">
            <select value={cidadeId} onChange={(e) => setCidadeId(e.target.value)}>
              <option value="">Selecione…</option>
              {cities.map((c) => (
                <option key={c.cidade_id} value={c.cidade_id}>{c.nome} — {c.uf}</option>
              ))}
            </select>
          </Field>
          <Field label="POP (opcional — consolidado se vazio)">
            <select value={popId} onChange={(e) => setPopId(e.target.value)}>
              <option value="">Cidade inteira</option>
              {(cityDetail?.pops || []).map((p) => (
                <option key={p.pop_id} value={p.pop_id}>{p.codigo} — {p.nome}</option>
              ))}
            </select>
          </Field>
          <Field label="Postes (infra)">
            <input disabled value={cityDetail ? Number(cityDetail.postes_count).toLocaleString('pt-BR') : '—'} />
          </Field>
          <Field label="Rede (km)">
            <input disabled value={cityDetail ? Number(cityDetail.km_rede).toLocaleString('pt-BR') : '—'} />
          </Field>
          <Field label="Fibras totais / ociosas">
            <input disabled value={cityDetail ? `${cityDetail.fibras_totais} / ${cityDetail.fibras_livres}` : '—'} />
          </Field>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 24 }}>
        <h2 className="section-title">Simulador de clientes</h2>
        <div className="chip-row" style={{ marginBottom: 18 }}>
          {QUICK_CLIENTS.map((n) => (
            <button key={n} className={`chip${Number(clientes) === n ? ' active' : ''}`} onClick={() => setClientes(n)}>
              {n.toLocaleString('pt-BR')}
            </button>
          ))}
        </div>

        <div className="form-grid">
          <Field label="Clientes">
            <input type="number" min="0" value={clientes} onChange={(e) => setClientes(e.target.value)} />
          </Field>
          <Field label="ARPU (R$)">
            <input type="number" min="0" step="0.01" value={arpu} onChange={(e) => setArpu(e.target.value)} />
          </Field>
          <Field label="Faturamento (auto = clientes × ARPU)">
            <input type="number" min="0" step="0.01" placeholder="automático" value={faturamentoOverride} onChange={(e) => setFaturamentoOverride(e.target.value)} />
          </Field>
          <Field label={<>Revenue Share % <HelpTooltip text="Percentual do faturamento do parceiro repassado à OptiMon como parte da composição do preço mensal." /></>}>
            <input type="number" min="0" max="1" step="0.01" value={revenueSharePct} onChange={(e) => setRevenueSharePct(e.target.value)} />
          </Field>
          <Field label={<>Composição <HelpTooltip text="Regra usada para calcular o total mensal a partir do piso e do revenue share: MAX (maior entre os dois), SUM (soma), FLOOR_ONLY (só piso) ou MINIMUM_ONLY (só mínimo contratual)." /></>}>
            <select value={composicaoMode} onChange={(e) => setComposicaoMode(e.target.value)}>
              {COMPOSICAO_MODES.map((m) => <option key={m} value={m}>{m}</option>)}
            </select>
          </Field>
          <Field label="Prazo (meses)">
            <select value={prazoMeses} onChange={(e) => setPrazoMeses(Number(e.target.value))}>
              <option value={48}>48 (mínimo contratual)</option>
              <option value={36}>36</option>
              <option value={60}>60</option>
            </select>
          </Field>
          <Field label="Carência (meses)">
            <input type="number" min="0" value={carenciaMeses} onChange={(e) => setCarenciaMeses(e.target.value)} />
          </Field>
          <Field label="Índice de Reajuste">
            <select value={reajusteIndice} onChange={(e) => setReajusteIndice(e.target.value)}>
              <option value="IPCA">IPCA</option>
              <option value="IGPM">IGP-M</option>
            </select>
          </Field>
          <Field label="Investimento (CAPEX, para ROI)">
            <input type="number" min="0" step="0.01" value={capex} onChange={(e) => setCapex(e.target.value)} />
          </Field>
          <Field label="OPEX mensal">
            <input type="number" min="0" step="0.01" value={opexMensal} onChange={(e) => setOpexMensal(e.target.value)} />
          </Field>
          <Field label={<>Preço proposto (R$/mês — sugestão: recomendado) <HelpTooltip text="Valor que você pretende oferecer ao parceiro. Abaixo do recomendado, a proposta nasce em 'Em Aprovação' e precisa de aprovação de um DIRETOR/ADMINISTRADOR." /></>}>
            <input
              type="number" min="0" step="0.01" value={precoProposto}
              onChange={(e) => { setPrecoProposto(e.target.value); setPrecoPropostoTocado(true); }}
            />
          </Field>
        </div>
        <div style={{ marginTop: 18 }}>
          <button className="btn btn-primary" onClick={runSimulation} disabled={loading || !cidadeId}>
            {loading ? 'Calculando…' : 'Simular'}
          </button>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 24 }}>
        <h2 className="section-title">Parceiro (capa da proposta)</h2>
        <div className="form-grid">
          <Field label="Parceiro cadastrado (opcional)">
            <select value={parceiroId} onChange={(e) => {
              const id = e.target.value;
              setParceiroId(id);
              const p = partners.find((x) => x.id === id);
              if (p) setParceiroNomeCapa(p.nome_fantasia || p.razao_social);
            }}>
              <option value="">Nenhum — usar nome livre abaixo</option>
              {partners.map((p) => (
                <option key={p.id} value={p.id}>{p.nome_fantasia || p.razao_social}</option>
              ))}
            </select>
          </Field>
          <Field label="Nome do parceiro na capa">
            <input value={parceiroNomeCapa} onChange={(e) => setParceiroNomeCapa(e.target.value)} placeholder="Nome exibido na proposta" />
          </Field>
          <Field label="Cargo do contato">
            <input value={parceiroCargoContato} onChange={(e) => setParceiroCargoContato(e.target.value)} placeholder="ex.: Diretor Comercial" />
          </Field>
          <Field label="Validade da proposta (dias)">
            <input type="number" min="1" value={validadeDias} onChange={(e) => setValidadeDias(e.target.value)} />
          </Field>
        </div>
      </div>

      {pricing && (
        <>
          <div className="card" style={{ marginBottom: 24 }}>
            <h2 className="section-title">Régua de Preço — {cityName}</h2>
            <ReguaDePreco
              floor={pricing.floor}
              recommended={pricing.recommended}
              opening={pricing.opening}
              proposto={pricing.preco_proposto}
              governanceStatus={pricing.governance_status}
            />
          </div>

          <div className="card-grid" style={{ marginBottom: 24 }}>
            <div className="card kpi-card">
              <div className="kpi-label">PONs necessárias</div>
              <div className="kpi-value">{pricing.pons_count}</div>
            </div>
            <div className="card kpi-card">
              <div className="kpi-label">Faturamento do parceiro</div>
              <div className="kpi-value">{formatCurrencyFull(pricing.faturamento)}</div>
            </div>
            <div className="card kpi-card">
              <div className="kpi-label">Revenue Share</div>
              <div className="kpi-value">{formatCurrencyFull(pricing.revenue_share_value)}</div>
            </div>
            <div className="card kpi-card">
              <div className="kpi-label">Infrastructure Floor</div>
              <div className="kpi-value">{formatCurrencyFull(pricing.floor)}</div>
            </div>
            <div className="card kpi-card">
              <div className="kpi-label">Total a Pagar (OptiMon)</div>
              <div className="kpi-value">{formatCurrencyFull(pricing.total_payable)}</div>
            </div>
            <div className="card kpi-card">
              <div className="kpi-label">Receita do Parceiro</div>
              <div className="kpi-value">{formatCurrencyFull(pricing.partner_revenue)}</div>
              <div className="kpi-sub">margem {pricing.partner_margin != null ? `${(pricing.partner_margin * 100).toFixed(1)}%` : '—'}</div>
            </div>
          </div>

          {curve && (
            <div className="card-grid" style={{ gridTemplateColumns: '1fr 1fr', marginBottom: 24 }}>
              <div className="card">
                <h2 className="section-title">Crescimento da Base × Receita OptiMon</h2>
                <GrowthRevenueChart points={curve} />
              </div>
              <div className="card">
                <h2 className="section-title">Clientes × PONs Necessárias</h2>
                <ClientsPonsChart points={curve} />
              </div>
            </div>
          )}

          {ramp && ramp.length > 0 && (
            <div className="card" style={{ marginBottom: 24 }}>
              <h2 className="section-title">Rampa</h2>
              <div className="chip-row">
                {ramp.map((r) => (
                  <div key={r.id} className="chip" style={{ cursor: 'default' }}>
                    Meses {r.month_start}{r.month_end ? `–${r.month_end}` : '+'}: {(Number(r.percentage) * 100).toFixed(0)}%
                  </div>
                ))}
              </div>
            </div>
          )}

          {horizonTable && (
            <div className="card" style={{ marginBottom: 24, padding: 0 }}>
              <div style={{ padding: '20px 22px 0' }}>
                <h2 className="section-title">Simulação por horizonte (48 meses = prazo contratual mínimo)</h2>
              </div>
              <div className="table-scroll">
                <table>
                  <thead>
                    <tr>
                      <th>Horizonte</th>
                      <th className="num">Receita OptiMon</th>
                      <th className="num">Receita Parceiro</th>
                      <th className="num">Receita Total</th>
                      <th className="num">OPEX</th>
                      <th className="num">Resultado</th>
                      <th className="num">ROI</th>
                      <th className="num">Payback</th>
                    </tr>
                  </thead>
                  <tbody>
                    {horizonTable.linhas.map((l) => (
                      <tr key={l.meses}>
                        <td style={{ fontWeight: 600 }}>
                          {l.meses} meses {l.minimo_contratual_flag && <span className="badge status-allow" style={{ marginLeft: 6 }}>mínimo contratual</span>}
                        </td>
                        <td className="num">{formatCurrencyFull(l.receita_optimon)}</td>
                        <td className="num">{formatCurrencyFull(l.receita_parceiro)}</td>
                        <td className="num">{formatCurrencyFull(l.receita_total)}</td>
                        <td className="num">{formatCurrencyFull(l.opex)}</td>
                        <td className="num">{formatCurrencyFull(l.resultado_parceiro)}</td>
                        <td className="num">{l.roi != null ? `${(l.roi * 100).toFixed(0)}%` : '—'}</td>
                        <td className="num">{l.payback_meses != null ? `${l.payback_meses} meses` : '—'}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}

          <div className="card">
            <h2 className="section-title">Proposta Comercial</h2>
            <p style={{ color: 'var(--text-muted)', fontSize: '0.88rem', marginBottom: 16 }}>
              Gera e salva a proposta com a régua, PONs, capacidade, Revenue Share, prazo, carência e reajuste desta simulação.
            </p>
            <button className="btn btn-primary" onClick={handleGerarProposta} disabled={proposalStatus === 'salvando'}>
              {proposalStatus === 'salvando' ? 'Gerando…' : 'Gerar Proposta'}
            </button>
            {proposalStatus && proposalStatus !== 'salvando' && (
              <div style={{ marginTop: 12 }}>
                <span className="badge status-allow">Proposta {proposalStatus.numero} gerada com sucesso.</span>{' '}
                <button className="link-tab" style={{ background: 'none', border: 'none', cursor: 'pointer' }} onClick={() => navigate(`/propostas/${proposalStatus.id}`)}>
                  Ver proposta →
                </button>
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}
