// OptiMon Pricing API — GET /api/version (seção 6/39/40).
// Nunca inclui segredos — só metadados de build/deploy, todos seguros para expor
// publicamente (é exatamente o que um checklist de deploy usa para confirmar "a versão X
// está no ar").

const pkg = require('../package.json');

function getVersionInfo() {
  return {
    service: 'optimon-api',
    version: pkg.version,
    environment: process.env.APP_ENVIRONMENT || process.env.NODE_ENV || 'development',
    // Railway define automaticamente RAILWAY_GIT_COMMIT_SHA no ambiente de build/deploy.
    // Fora do Railway (local, CI), cai para GIT_COMMIT_SHA (setado manualmente ou pelo
    // workflow de CI) e por fim 'unknown' — nunca quebra por falta da variável.
    commit: process.env.RAILWAY_GIT_COMMIT_SHA || process.env.GIT_COMMIT_SHA || 'unknown',
    build_time: process.env.BUILD_TIME || null,
  };
}

module.exports = { getVersionInfo };
