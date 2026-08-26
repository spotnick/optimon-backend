// OptiMon Pricing API — bootstrap.
//
// Publicado no Railway (seção 6). Consumido pelo frontend React publicado no Vercel
// (seção 7) — CORS liberado só para as origens configuradas em CORS_ALLOWED_ORIGINS
// (nunca "*", para não abrir a API para qualquer site — seção 33).

require('dotenv').config();
const express = require('express');
// Faz o Express (v4) encaminhar automaticamente qualquer erro/rejeição de handler async
// para o middleware de erro abaixo — sem isso, um throw síncrono dentro de uma rota async
// (ex.: SUPABASE_URL mal configurada quebrando createClient()) nunca gera resposta, e o
// Railway derruba a conexão com 502 depois do timeout em vez de um erro limpo. Precisa
// ser importado antes de qualquer `express.Router()` (routes/*.js) ser criado.
require('express-async-errors');
const cors = require('cors');
const { requireAuth } = require('./middleware/auth');
const pricingRoutes = require('./routes/pricing');
const citiesRoutes = require('./routes/cities');
const simulationsRoutes = require('./routes/simulations');
const proposalsRoutes = require('./routes/proposals');
const auditRoutes = require('./routes/audit');
const { getVersionInfo } = require('./lib/version');

const app = express();
app.use(express.json());

const allowedOrigins = (process.env.CORS_ALLOWED_ORIGINS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

app.use(
  cors({
    origin(origin, callback) {
      // Requisições sem header Origin (ex.: health check, curl, Server-to-Server) sempre
      // passam — CORS é uma proteção de navegador, não uma autenticação.
      if (!origin) return callback(null, true);
      if (allowedOrigins.length === 0 || allowedOrigins.includes(origin)) {
        return callback(null, true);
      }
      return callback(new Error(`Origem não autorizada: ${origin}`));
    },
    credentials: false,
  })
);

// Toda rota de negócio exige um usuário autenticado — nunca anônimo, nunca service_role
// (seção 33/53). RBAC/RLS de verdade acontecem no Postgres; esta API só encaminha o JWT.
app.use('/api/pricing', requireAuth, pricingRoutes);
app.use('/api/cities', requireAuth, citiesRoutes);
app.use('/api/simulations', requireAuth, simulationsRoutes);
app.use('/api/proposals', requireAuth, proposalsRoutes);
app.use('/api/audit', requireAuth, auditRoutes);

// GET /health — seção 6/40: contrato exato exigido pelo checklist de deploy.
app.get('/health', (_req, res) => res.json({ status: 'ok', service: 'optimon-api' }));

// GET /api/version — seção 6/39/40: nunca inclui segredos.
app.get('/api/version', (_req, res) => res.json(getVersionInfo()));

app.use((err, _req, res, _next) => {
  // Nunca vazar stack trace / detalhes internos na resposta (seção 53).
  if (err && /Origem não autorizada/.test(err.message)) {
    return res.status(403).json({ error: err.message });
  }
  console.error('[optimon-api] erro não tratado:', err);
  return res.status(500).json({ error: 'Erro interno.' });
});

const PORT = process.env.PORT || 3001;
if (require.main === module) {
  app.listen(PORT, () => console.log(`OptiMon Pricing API ouvindo na porta ${PORT}`));
}

module.exports = app;
