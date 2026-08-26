// OptiMon Pricing API — rotas de Parceiro. Tabela `parceiros` já existia desde a Fase 1
// (RLS: select=todos autenticados, insert/update=COMERCIAL/DIRETOR/ADMINISTRADOR) mas
// nunca tinha sido exposta via API/frontend — gap fechado na Fase 2.4 porque a capa da
// proposta comercial precisa do nome do parceiro (seção 6). Só leitura por enquanto
// (cadastro de parceiro continua fora do escopo desta fase — a tela usa o texto livre
// parceiro_nome_capa quando não há parceiro cadastrado ainda).

const express = require('express');
const { clientForRequest } = require('../lib/supabaseClient');

const router = express.Router();

// GET /api/partners — lista parceiros ativos (para o seletor "Parceiro" da simulação/
// proposta). RLS da tabela já resolve (select = todos autenticados).
router.get('/', async (req, res) => {
  const supabase = clientForRequest(req.userJwt);
  const { data, error } = await supabase
    .from('parceiros')
    .select('id, razao_social, nome_fantasia, cnpj, responsavel_comercial, ativo')
    .is('removido_em', null)
    .eq('ativo', true)
    .order('nome_fantasia', { ascending: true });
  if (error) return res.status(400).json({ error: error.message });
  return res.json(data);
});

module.exports = router;
