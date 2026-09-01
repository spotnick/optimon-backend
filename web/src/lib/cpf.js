// OptiMon — Fase 3.11.5 (item 2 do relato de produção: "o campo de CPF está sem
// validação"): mesmo algoritmo (dígitos verificadores, mod 11) da função SQL
// app.cpf_valido (supabase/migrations/20261008090000_phase_3_11_05_correcoes_pos_deploy.sql)
// — nunca uma 2ª regra divergente. Isto é só feedback imediato na tela: a validação que
// realmente vale é sempre a do banco (app.assinatura_externa_assinar_iniciar), que
// nunca pode ser contornada chamando a API direto.
export function isValidCpf(value) {
  const v = String(value || '').replace(/\D/g, '');
  if (v.length !== 11) return false;
  if (/^(\d)\1{10}$/.test(v)) return false;

  let soma = 0;
  for (let i = 0; i < 9; i += 1) soma += Number(v[i]) * (10 - i);
  let resto = (soma * 10) % 11;
  if (resto === 10) resto = 0;
  if (resto !== Number(v[9])) return false;

  soma = 0;
  for (let i = 0; i < 10; i += 1) soma += Number(v[i]) * (11 - i);
  resto = (soma * 10) % 11;
  if (resto === 10) resto = 0;
  if (resto !== Number(v[10])) return false;

  return true;
}

export function formatCpf(value) {
  const v = String(value || '').replace(/\D/g, '').slice(0, 11);
  return v
    .replace(/(\d{3})(\d)/, '$1.$2')
    .replace(/(\d{3})(\d)/, '$1.$2')
    .replace(/(\d{3})(\d{1,2})$/, '$1-$2');
}
