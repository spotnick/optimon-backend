// OptiMon Pricing API — Pricing Engine centralizado no backend (seção 32).
//
// Esta função é o ÚNICO lugar, fora do banco, que "sabe" como pedir um cálculo de preço.
// Ela NÃO reimplementa nenhuma fórmula — é um wrapper fino sobre a RPC
// public.pricing_calculate_full(jsonb), que por sua vez chama app.simular_precificacao_completa
// (supabase/migrations/20260831090100_phase_deploy_02_calculate_pricing_full.sql). Toda a
// lógica de negócio (Infrastructure Floor, régua de preço, governança, composição
// Floor/Revenue Share) continua vivendo em SQL — a mesma fonte de verdade usada pelos
// testes (tests/run_tests_fase221.sh) e por qualquer outra chamada direta ao banco.
//
// Front-end React NUNCA chama isso diretamente nem reimplementa a fórmula em JS (seção
// 32/33) — ele chama POST /api/pricing/calculate, que chama esta função, que chama o
// banco. O banco sempre recalcula a partir do que o usuário pediu; nenhum valor vindo do
// cliente é confiado sem essa passagem pelo servidor (seção 33).

/**
 * @param {import('@supabase/supabase-js').SupabaseClient} supabase — cliente já escopado
 *   ao JWT do usuário autenticado (ver lib/supabaseClient.js#clientForRequest).
 * @param {object} input
 * @param {string} input.cidade_id — obrigatório.
 * @param {string} [input.pop_id]
 * @param {number} [input.clientes]
 * @param {number} [input.arpu]
 * @param {number} [input.faturamento] — se omitido, o banco calcula clientes × arpu.
 * @param {number} [input.revenue_share_pct] — default 0.12 (12%, seção 20).
 * @param {string} [input.composicao_mode] — FLOOR_ONLY|MINIMUM_ONLY|FLOOR_AS_MINIMUM|SUM (default FLOOR_AS_MINIMUM
 *   — Fase 3.8 item 3: "MAX" foi identificado como a inconsistência do modelo econômico
 *   a corrigir e removido; o modelo oficial agora é sempre mínimo/piso + revenue share).
 * @param {number} [input.preco_proposto] — se omitido, o banco usa o RECOMENDADO.
 * @param {number} [input.pons_count] — se omitido, o banco deriva de clientes (ceil(clientes/128)).
 * @param {string} [input.pricing_version] — se omitido, usa a versão vigente.
 * @returns {Promise<{data: object|null, error: object|null}>}
 */
async function calculatePricing(supabase, input) {
  if (!input || !input.cidade_id) {
    return { data: null, error: { message: 'cidade_id é obrigatório.' } };
  }

  const params = {
    cidade_id: input.cidade_id,
    pop_id: input.pop_id ?? null,
    clientes: input.clientes ?? 0,
    arpu: input.arpu ?? 0,
    faturamento: input.faturamento ?? null,
    revenue_share_pct: input.revenue_share_pct ?? 0.12,
    composicao_mode: input.composicao_mode ?? 'FLOOR_AS_MINIMUM',
    preco_proposto: input.preco_proposto ?? null,
    pons_count: input.pons_count ?? null,
    pricing_version: input.pricing_version ?? null,
    minimo_contratual: input.minimo_contratual ?? 0,
  };

  const { data, error } = await supabase.rpc('pricing_calculate_full', { p_params: params });
  return { data, error };
}

module.exports = { calculatePricing };
