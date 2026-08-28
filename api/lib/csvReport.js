// OptiMon — Fase 3 (item 3.6): serializador CSV mínimo para relatórios gerenciais.
// Sem dependência nova (nenhuma lib csv/xlsx existia no projeto) — RFC 4180 básico:
// vírgula como separador, aspas duplas escapando aspas/vírgula/quebra de linha, BOM UTF-8
// no início para o Excel abrir acentuação em português corretamente.

function csvEscape(value) {
  if (value === null || value === undefined) return '';
  const str = typeof value === 'object' ? JSON.stringify(value) : String(value);
  if (/[",\n;]/.test(str)) {
    return `"${str.replace(/"/g, '""')}"`;
  }
  return str;
}

/**
 * @param {object[]} rows - array de objetos planos (uma linha por item).
 * @returns {string} CSV com BOM UTF-8, cabeçalho a partir das chaves do primeiro item.
 */
function toCsv(rows) {
  if (!Array.isArray(rows) || rows.length === 0) return '﻿';
  const columns = Object.keys(rows[0]);
  const lines = [columns.join(',')];
  for (const row of rows) {
    lines.push(columns.map((c) => csvEscape(row[c])).join(','));
  }
  return `﻿${lines.join('\n')}`;
}

module.exports = { toCsv, csvEscape };
