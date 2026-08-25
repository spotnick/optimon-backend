#!/usr/bin/env node
// NÃO FAZ PARTE DO PRODUTO. Um projeto Supabase real serve PostgREST atrás do gateway
// Kong, sob o prefixo /rest/v1 — é esse prefixo que @supabase/supabase-js sempre monta
// (`${SUPABASE_URL}/rest/v1/...`). O PostgREST puro que rodamos localmente (dev-local-only)
// não tem esse prefixo. Este proxy HTTP mínimo (só módulos nativos do Node, sem
// dependência nova) só remove o prefixo /rest/v1 antes de encaminhar para o PostgREST
// local — assim api/lib/supabaseClient.js (feito para apontar para um Supabase real) pode
// ser testado sem nenhuma alteração, contra este ambiente local.
//
// Uso: PGRST_TARGET=http://127.0.0.1:3000 PROXY_PORT=54321 node rest_v1_proxy.js

const http = require('http');

const TARGET = new URL(process.env.PGRST_TARGET || 'http://127.0.0.1:3000');
const PORT = Number(process.env.PROXY_PORT || 54321);

const server = http.createServer((req, res) => {
  const strippedPath = req.url.replace(/^\/rest\/v1/, '') || '/';
  const options = {
    hostname: TARGET.hostname,
    port: TARGET.port,
    path: strippedPath,
    method: req.method,
    headers: req.headers,
  };
  const proxyReq = http.request(options, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res, { end: true });
  });
  proxyReq.on('error', (err) => {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: `proxy: ${err.message}` }));
  });
  req.pipe(proxyReq, { end: true });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[rest_v1_proxy] :${PORT} -> ${TARGET} (strip /rest/v1)`);
});
