#!/usr/bin/env bash
# OptiMap Fase 3 — sobe o ambiente LOCAL completo para testes (nunca toca o Supabase real):
#   Postgres+PostGIS (já rodando) → PostgREST :3000 → proxy /rest/v1 :54321 → API :3001 → Vite :5173
#
# Uso:
#   tests/optimap/fase3/stack.sh banco base    # 135 migrations + usuários de teste + seed_producao (estado real: camadas vazias)
#   tests/optimap/fase3/stack.sh banco dados   # idem + dados de TESTE identificados (POP/postes/elementos/trecho/referências)
#   tests/optimap/fase3/stack.sh subir         # PostgREST + proxy + API + Vite (dev)
#   tests/optimap/fase3/stack.sh parar
#
# Requer: binário `postgrest` no PATH (ou POSTGREST_BIN), node/npm, dependências instaladas em api/ e web/.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT=$(pwd)
export PGHOST="${PGHOST:-/tmp}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}"
LOGS="${OPTIMAP_LOGS:-/tmp/optimap-fase3}"
mkdir -p "$LOGS"
PGRST="${POSTGREST_BIN:-postgrest}"
ANON_KEY=$(node supabase/dev-local-only/mint_jwt.js 00000000-0000-0000-0000-000000000000 anon 86400)

case "${1:-}" in
  banco)
    tests/optimap/bootstrap_sandbox.sh >/dev/null
    psql -q -d optimon -v ON_ERROR_STOP=1 -f tests/optimap/fase3/usuarios_teste.sql
    psql -q -d optimon -v ON_ERROR_STOP=1 -f supabase/seed_producao.sql >/dev/null
    if [ "${2:-base}" = "dados" ]; then
      psql -q -d optimon -v ON_ERROR_STOP=1 -f tests/optimap/fase3/dados_teste_mapa.sql >/dev/null
    fi
    # PostgREST recarrega o cache de schema (se estiver no ar).
    psql -q -d optimon -c "notify pgrst, 'reload schema';" >/dev/null
    echo "banco pronto (${2:-base})"
    ;;
  subir)
    "$0" parar >/dev/null 2>&1 || true
    nohup "$PGRST" supabase/dev-local-only/postgrest.local.conf >"$LOGS/postgrest.log" 2>&1 &
    PGRST_TARGET=http://127.0.0.1:3000 PROXY_PORT=54321 nohup node supabase/dev-local-only/rest_v1_proxy.js >"$LOGS/proxy.log" 2>&1 &
    (cd api && SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY="$ANON_KEY" PORT=3001 nohup node server.js >"$LOGS/api.log" 2>&1 &)
    (cd web && VITE_SUPABASE_URL=http://127.0.0.1:54321 VITE_SUPABASE_ANON_KEY="$ANON_KEY" VITE_API_URL=http://localhost:3001 \
       nohup npx vite --port 5173 --strictPort --host 127.0.0.1 >"$LOGS/vite.log" 2>&1 &)
    for i in $(seq 1 40); do
      if curl -sf http://localhost:3001/health >/dev/null && curl -sf http://127.0.0.1:5173/ >/dev/null && curl -sf http://127.0.0.1:3000/ >/dev/null; then
        echo "ambiente no ar: web http://127.0.0.1:5173  api http://localhost:3001"; exit 0; fi
      sleep 0.5
    done
    echo "falha ao subir — ver $LOGS"; exit 1
    ;;
  parar)
    for pat in "postgrest supabase/dev-local-only" "rest_v1_proxy.js" "node server.js" "vite --port 5173"; do
      pids=$(ps aux | grep -F "$pat" | grep -v grep | awk '{print $2}' || true)
      [ -n "$pids" ] && kill $pids 2>/dev/null || true
    done
    echo "parado"
    ;;
  *)
    sed -n 2,12p "$0"; exit 1;;
esac
