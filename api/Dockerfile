# OptiMon Pricing API — imagem para Railway (seção 6).
# Multi-stage simples: só produção, sem devDependencies, imagem final enxuta.
#
# Contexto de build = RAIZ do repositório (railway.toml na raiz aponta
# dockerfilePath="api/Dockerfile" sem mudar o Root Directory do serviço no Railway) — por
# isso todo COPY abaixo usa o prefixo "api/", não caminhos relativos a este arquivo.

FROM node:20-alpine AS deps
WORKDIR /app
COPY api/package.json api/package-lock.json* ./
RUN npm ci --omit=dev

FROM node:20-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY api/ .

# Nunca copiar .env para a imagem — variáveis reais vêm do painel do Railway (seção 8/53).
RUN rm -f .env

EXPOSE 3001
# Railway injeta PORT automaticamente; server.js já lê process.env.PORT com fallback 3001.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:'+(process.env.PORT||3001)+'/health', r => process.exit(r.statusCode===200?0:1)).on('error', () => process.exit(1))"

CMD ["node", "server.js"]
