// OptiMon Pricing API — exige um JWT de usuário autenticado em toda rota de pricing.
// Nunca aceita chamadas anônimas nem tokens de service_role (a ANON_KEY sozinha nunca
// autentica como um usuário real — o RLS trataria isso como `anon`, sem perfil, e as
// policies já bloqueiam por padrão quem não é `authenticated`).

function requireAuth(req, res, next) {
  const header = req.headers.authorization || '';
  const [scheme, token] = header.split(' ');

  if (scheme !== 'Bearer' || !token) {
    return res.status(401).json({ error: 'Authorization: Bearer <jwt> obrigatório.' });
  }

  req.userJwt = token;
  next();
}

module.exports = { requireAuth };
