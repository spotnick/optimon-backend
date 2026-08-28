// OptiMon — Fase 3 (item 3.6): Relatórios gerenciais. Handlers finos, iguais ao padrão
// do resto do projeto: cada rota chama UM wrapper SQL (público, security invoker — roda
// sob a RLS de quem chamou, nunca decide RBAC aqui) e devolve o jsonb como veio. Nenhuma
// regra de negócio vive aqui — ver supabase/migrations/20260924090000_phase_3_06_
// relatorios_gerenciais.sql para as fontes e as limitações documentadas (receita por POP
// não é segregável; faturamento/revenue-share/take-or-pay reais e inadimplência dependem
// de medicoes_mensais, ainda schema-only).

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');
const { toCsv } = require('../lib/csvReport');

const router = express.Router();

function handleError(res, error) {
  return res.status(400).json({ error: error?.message || 'Erro inesperado.' });
}

const REPORTS = {
  'receita-por-cidade': { rpc: 'pricing_relatorio_receita_por_cidade', filename: 'receita_por_cidade' },
  'receita-por-parceiro': { rpc: 'pricing_relatorio_receita_por_parceiro', filename: 'receita_por_parceiro' },
  'capacidade-por-pop': { rpc: 'pricing_relatorio_capacidade_por_pop', filename: 'capacidade_por_pop' },
  'clientes-por-pon': { rpc: 'pricing_relatorio_clientes_por_pon', filename: 'clientes_por_pon' },
  contratos: { rpc: 'pricing_relatorio_contratos', filename: 'contratos' },
  reajustes: { rpc: 'pricing_relatorio_reajustes', filename: 'reajustes' },
};

// GET /api/reports/:tipo — retorna o relatório como jsonb (array de linhas).
router.get('/:tipo', async (req, res) => {
  const report = REPORTS[req.params.tipo];
  if (!report) return res.status(404).json({ error: `Relatório "${req.params.tipo}" não existe.` });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc(report.rpc);
  if (error) return handleError(res, error);
  return res.json(data);
});

// GET /api/reports/:tipo/csv — mesmo relatório, como download CSV.
router.get('/:tipo/csv', async (req, res) => {
  const report = REPORTS[req.params.tipo];
  if (!report) return res.status(404).json({ error: `Relatório "${req.params.tipo}" não existe.` });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc(report.rpc);
  if (error) return handleError(res, error);
  const csv = toCsv(Array.isArray(data) ? data : []);
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="OPTIMON_${report.filename}_${new Date().toISOString().slice(0, 10)}.csv"`);
  return res.send(csv);
});

// GET /api/reports/faturamento-real — não é uma lista, é um status (disponivel/não) —
// rota própria em vez de forçar no dicionário REPORTS acima (formato de retorno diferente).
router.get('/faturamento-real/status', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('pricing_relatorio_faturamento_real');
  if (error) return handleError(res, error);
  return res.json(data);
});

module.exports = router;
