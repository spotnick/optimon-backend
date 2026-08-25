-- OptiMon — Fase 1
-- Extensões necessárias no banco.
create extension if not exists "pgcrypto";   -- gen_random_uuid()
create extension if not exists "pg_trgm";    -- busca textual (nome de parceiro, cidade, etc.)
