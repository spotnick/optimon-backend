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
const infraRoutes = require('./routes/infra');
const simulationsRoutes = require('./routes/simulations');
const proposalsRoutes = require('./routes/proposals');
const partnersRoutes = require('./routes/partners');
const auditRoutes = require('./routes/audit');
const usersRoutes = require('./routes/users');
const { router: signaturesRoutes, webhookRouter: signaturesWebhookRoutes } = require('./routes/signatures');
const contractsRoutes = require('./routes/contracts');
const { getVersionInfo } = require('./lib/version');

const app = express();

// Fase 2.5 seção 27/49: o webhook de assinatura precisa do CORPO BRUTO (para
// validar o HMAC — ver api/routes/signatures.js) e nunca passa por
// `requireAuth` (quem chama é o provedor externo, sem JWT de usuário) — por
// isso é montado ANTES do `express.json()` global abaixo. Se estivesse depois,
// o express.json() já teria consumido o stream da requisição e o
// express.raw() interno da rota chegaria com um buffer vazio.
app.use('/api/signatures', signaturesWebhookRoutes);

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
    // Fase 2.4: exportação de proposta (GET /api/proposals/:id/export) manda o nome do
    // arquivo em Content-Disposition — por padrão o navegador não expõe esse header pro
    // JS em requisição cross-origin (frontend Vercel x API Railway), então o fetch() do
    // frontend (web/src/lib/api.js:apiDownload) sempre caía no nome genérico de
    // fallback. Precisa expor explicitamente.
    exposedHeaders: ['Content-Disposition'],
  })
);

// Toda rota de negócio exige um usuário autenticado — nunca anônimo, nunca service_role
// (seção 33/53). RBAC/RLS de verdade acontecem no Postgres; esta API só encaminha o JWT.
app.use('/api/pricing', requireAuth, pricingRoutes);
app.use('/api/cities', requireAuth, citiesRoutes);
app.use('/api/infra', requireAuth, infraRoutes);
app.use('/api/simulations', requireAuth, simulationsRoutes);
app.use('/api/proposals', requireAuth, proposalsRoutes);
app.use('/api/partners', requireAuth, partnersRoutes);
app.use('/api/audit', requireAuth, auditRoutes);
app.use('/api/users', requireAuth, usersRoutes);
app.use('/api/signatures', requireAuth, signaturesRoutes);
app.use('/api/contracts', requireAuth, contractsRoutes);

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
