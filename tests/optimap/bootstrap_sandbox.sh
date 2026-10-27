#!/usr/bin/env bash
# OptiMap — Fase 2: recria o banco do sandbox do zero e aplica TODAS as migrations do
# repositório em ordem (as 131 pré-existentes + as novas do OptiMap), exatamente como
# uma instalação nova faria. NUNCA rode contra o Supabase real.
#
# Variáveis: PGHOST/PGPORT/PGUSER (superusuário local). Padrão: socket /tmp, porta 5432.
set -euo pipefail
cd "$(dirname "$0")/../.."
export PGHOST="${PGHOST:-/tmp}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}"
DB="${OPTIMAP_DB:-optimon}"
ONLY_BASE="${ONLY_BASE:-0}"   # 1 = só as migrations pré-existentes (baseline de regressão)

psql -q -d postgres -c "drop database if exists $DB with (force);" -c "create database $DB;"
# Simula o search_path padrão de um projeto Supabase ("$user", public, extensions) e o
# schema `extensions` onde o Supabase instala extensões.
psql -q -d "$DB" -v ON_ERROR_STOP=1 -v db="$DB" <<'SQL'
create schema if not exists extensions;
alter database :"db" set search_path = "$user", public, extensions;
SQL
psql -q -d "$DB" -v ON_ERROR_STOP=1 -f supabase/dev-local-only/shim_supabase_auth.sql
# Simula os default privileges de um projeto Supabase real: toda tabela/função/sequência
# nova em public recebe ALL para anon/authenticated (é por isso que as migrations do
# OptiMap revogam explicitamente o que não deve existir, ex.: TRUNCATE).
psql -q -d "$DB" -v ON_ERROR_STOP=1 <<'SQL'
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end $$;
grant usage on schema public to service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
SQL

n=0
for f in supabase/migrations/*.sql; do
  base=$(basename "$f")
  if [ "$ONLY_BASE" = "1" ] && [[ "$base" > "20261013999999" ]]; then continue; fi
  if ! out=$(psql -q -d "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1); then
    echo "ERRO ao aplicar $base"; echo "$out" | tail -20; exit 1
  fi
  n=$((n+1))
done
echo "OK: $n migrations aplicadas em $DB"
