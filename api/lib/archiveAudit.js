// OptiMon — Fase 2.3.1 (seção 28): helper compartilhado por cities.js/infra.js para os
// endpoints POST .../archive de toda entidade de infraestrutura.
//
// A função SQL que arquiva (app.arquivar_*) sempre RAISE EXCEPTION quando bloqueada por
// dependência — e uma exceção desfaz a transação inteira, inclusive qualquer INSERT de
// auditoria feito antes dela dentro da mesma função (ver comentário completo na migration
// 20260902090000). Por isso o registro de BLOCKED_ARCHIVE não pode vir de dentro da
// função que bloqueou — vem daqui: depois de capturar o erro, fazemos uma SEGUNDA chamada
// RPC (public.pricing_log_blocked_action), numa transação nova, que persiste mesmo com a
// primeira tendo sido desfeita.
//
// Só chamamos pricing_log_blocked_action quando o bloqueio é de fato uma dependência de
// negócio (status 409) — nunca para 403 (permissão) ou 404 (não encontrado), que não são
// "tentativas de arquivar bloqueadas", são outra coisa.

function statusForArchiveError(message) {
  if (/PERMISSAO_NEGADA/i.test(message)) return 403;
  if (/não encontrad/i.test(message)) return 404;
  // Toda mensagem de bloqueio de dependência escrita nas migrations desta fase usa uma
  // dessas palavras — "não é possível", "possui ... ativo(s)/ocupada(s)/locada(s)",
  // "clientes ativos". Nunca uma lista fechada de strings exatas (frágil a qualquer
  // ajuste de texto futuro): o padrão comum é a ideia de "está em uso", não a frase.
  if (/não é possível arquivar|possui .* ativ|possui .* ocupad|possui .* locad|clientes ativos|contrato ativo/i.test(message)) {
    return 409;
  }
  return 400;
}

/**
 * Chama uma RPC de arquivamento e, se bloqueada por dependência (409), registra
 * BLOCKED_ARCHIVE numa chamada separada antes de responder ao cliente.
 *
 * @param {import('@supabase/supabase-js').SupabaseClient} supabase
 * @param {string} rpcName - ex.: 'pricing_pop_archive'
 * @param {object} rpcParams - ex.: { p_pop_id, p_motivo, p_observacao }
 * @param {string} entidade - ex.: 'infra_pops' (mesmo nome usado em auditoria.entidade)
 * @param {string} entidadeId
 */
async function archiveWithAudit(supabase, rpcName, rpcParams, entidade, entidadeId) {
  const { error } = await supabase.rpc(rpcName, rpcParams);
  if (!error) {
    return { ok: true };
  }
  const message = error.message || 'Erro inesperado.';
  const status = statusForArchiveError(message);
  if (status === 409) {
    // Melhor esforço: se o log do bloqueio falhar por qualquer motivo, o usuário ainda
    // recebe o 409 correto — só não teríamos o rastro extra de BLOCKED_ARCHIVE. Nunca
    // deixamos uma falha de auditoria mascarar o bloqueio real que já aconteceu.
    // Nota: o retorno de supabase.rpc(...) é "thenable" mas não implementa .catch()/
    // .finally() como uma Promise real (achado real ao testar POP/segmento com
    // dependência bloqueada — "supabase.rpc(...).catch is not a function", 500 em vez do
    // 409 esperado) — por isso try/await/catch aqui, nunca encadeado.
    try {
      await supabase.rpc('pricing_log_blocked_action', {
        p_entidade: entidade,
        p_entidade_id: entidadeId,
        p_acao: 'BLOCKED_ARCHIVE',
        p_motivo: message,
      });
    } catch {
      // melhor esforço — ver comentário acima.
    }
  }
  return { status, error: message };
}

module.exports = { archiveWithAudit, statusForArchiveError };
