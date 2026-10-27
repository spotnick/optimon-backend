// OptiMap — Fase 5: empresas com contrato de compartilhamento Copel e ocupações de postes.
//
//   GET  /api/optimap/empresas                     todos que veem o mapa
//   POST /api/optimap/empresas                     ADMINISTRADOR (cria)
//   PUT  /api/optimap/empresas/:id                 ADMINISTRADOR (edita)
//   GET  /api/optimap/empresas/:id/conferencia     ADMIN/DIRETOR/ENGENHARIA — CES × OptiMap × lotes
//   POST /api/optimap/ocupacoes                    ENGENHARIA/ADMIN — "ocupamos sem projeto aprovado"
//   POST /api/optimap/ocupacoes/:id/encerrar       ENGENHARIA/ADMIN
// A regra efetiva (perfil, duplicidade, origem) está no banco; aqui só validação de formato.

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');
const { _erro: erro } = require('./optimapImportacoes');

const router = express.Router();
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PERFIS_EDITAR = new Set(['ADMINISTRADOR', 'ENGENHARIA']);
const idValido = (req, res, next) => (UUID_RE.test(req.params.id) ? next() : res.status(400).json({ error: 'id inválido.' }));
const texto = (v, max) => (v === undefined || v === null ? null : typeof v === 'string' ? v.slice(0, max) : undefined);

router.get('/empresas', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.from('gis_empresas')
    .select('id, razao_social, nome_fantasia, cnpj, uc_copel, contrato_copel, ativa, observacoes')
    .order('razao_social');
  if (error) return erro(res, error);
  return res.json(data || []);
});

async function salvarEmpresa(req, res, id) {
  if (req.optimapRole !== 'ADMINISTRADOR') return res.status(403).json({ error: 'Apenas ADMINISTRADOR cadastra empresas.' });
  const b = req.body || {};
  const campos = {
    razao_social: texto(b.razao_social, 200), nome_fantasia: texto(b.nome_fantasia, 120), cnpj: texto(b.cnpj, 30),
    uc_copel: texto(b.uc_copel, 30), contrato_copel: texto(b.contrato_copel, 120), observacoes: texto(b.observacoes, 1000),
  };
  if (Object.values(campos).some((v) => v === undefined) || (b.ativa !== undefined && typeof b.ativa !== 'boolean')) {
    return res.status(400).json({ error: 'Campos inválidos.' });
  }
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_empresa_salvar', {
    p_id: id, p_razao_social: campos.razao_social, p_nome_fantasia: campos.nome_fantasia, p_cnpj: campos.cnpj,
    p_uc_copel: campos.uc_copel, p_contrato_copel: campos.contrato_copel, p_ativa: b.ativa ?? true, p_observacoes: campos.observacoes,
  });
  if (error) return erro(res, error);
  return res.status(id ? 200 : 201).json({ id: data });
}
router.post('/empresas', (req, res) => salvarEmpresa(req, res, null));
router.put('/empresas/:id', idValido, (req, res) => salvarEmpresa(req, res, req.params.id));

router.get('/empresas/:id/conferencia', idValido, async (req, res) => {
  if (!['ADMINISTRADOR', 'DIRETOR', 'ENGENHARIA'].includes(req.optimapRole)) return res.status(403).json({ error: 'Sem permissão para esta ação.' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_ces_conferencia', { p_empresa_id: req.params.id });
  if (error) return erro(res, error);
  return res.json(data || []);
});

router.post('/ocupacoes', async (req, res) => {
  if (!PERFIS_EDITAR.has(req.optimapRole)) return res.status(403).json({ error: 'Apenas ENGENHARIA ou ADMINISTRADOR marcam ocupações.' });
  const { poste_referencia_id: poste, empresa_id: empresa, motivo } = req.body || {};
  if (!UUID_RE.test(poste || '') || !UUID_RE.test(empresa || '')) return res.status(400).json({ error: 'Informe o poste e a empresa.' });
  if (typeof motivo !== 'string' || motivo.trim().length < 3) return res.status(400).json({ error: 'Descreva a ocupação (mínimo 3 caracteres).' });
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase.rpc('optimap_ocupacao_marcar', { p_poste_referencia_id: poste, p_empresa_id: empresa, p_motivo: motivo.slice(0, 1000) });
  if (error) return erro(res, error);
  return res.status(201).json({ id: data });
});

router.post('/ocupacoes/:id/encerrar', idValido, async (req, res) => {
  if (!PERFIS_EDITAR.has(req.optimapRole)) return res.status(403).json({ error: 'Apenas ENGENHARIA ou ADMINISTRADOR encerram marcações.' });
  const motivo = req.body?.motivo;
  if (typeof motivo !== 'string' || motivo.trim().length < 3) return res.status(400).json({ error: 'Informe o motivo.' });
  const supabase = clientForRequest(req.userJwt);
  const { error } = await supabase.rpc('optimap_ocupacao_encerrar', { p_ocupacao_id: req.params.id, p_motivo: motivo.slice(0, 1000) });
  if (error) return erro(res, error);
  return res.json({ ok: true });
});

module.exports = router;
