#!/usr/bin/env node
// NÃO FAZ PARTE DO PRODUTO. Ferramenta só para desenvolvimento local: gera um JWT HS256
// compatível com o que o Supabase Auth (GoTrue) real emitiria, para testar a API/frontend
// contra o PostgREST local (dev-local-only/postgrest.local.conf) sem precisar de um
// projeto Supabase de verdade. Usa só o módulo `crypto` nativo do Node — sem dependência
// nova no projeto. NUNCA use o segredo deste arquivo fora deste ambiente de dev local.
//
// Uso: node mint_jwt.js <user_uuid> [role=authenticated] [ttl_seconds=3600]

const crypto = require('crypto');

const JWT_SECRET = process.env.LOCAL_JWT_SECRET || 'optimon-local-dev-jwt-secret-nao-usar-em-producao-32bytes+';

function base64url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

function mintJwt(sub, role = 'authenticated', ttlSeconds = 3600) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = { sub, role, iat: now, exp: now + ttlSeconds, aud: 'authenticated' };

  const encodedHeader = base64url(JSON.stringify(header));
  const encodedPayload = base64url(JSON.stringify(payload));
  const signature = crypto
    .createHmac('sha256', JWT_SECRET)
    .update(`${encodedHeader}.${encodedPayload}`)
    .digest('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');

  return `${encodedHeader}.${encodedPayload}.${signature}`;
}

if (require.main === module) {
  const [, , sub, role, ttl] = process.argv;
  if (!sub) {
    console.error('Uso: node mint_jwt.js <user_uuid> [role=authenticated] [ttl_seconds=3600]');
    process.exit(1);
  }
  console.log(mintJwt(sub, role || 'authenticated', ttl ? Number(ttl) : 3600));
}

module.exports = { mintJwt };
