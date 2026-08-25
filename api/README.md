# OptiMon Pricing Engine — API

Backend Node/Express publicado no **Railway**, consumido pelo frontend React publicado no
**Vercel** (`web/`). Toda a lógica de negócio (fórmulas, régua de preço, governança) vive
em funções SQL no schema `app` do Postgres (`supabase/migrations/`) — esta API é uma
camada fina de acesso: recebe o JWT do usuário autenticado, chama um wrapper SQL em
`public` via `supabase-js`, e devolve o resultado. Nunca reimplementa uma fórmula.

## Por que existe uma camada de API separada do banco

O Pricing Engine "de verdade" (as fórmulas, seções 51) vive inteiramente em funções
SQL no schema `app` — auditável, testável com `psql` puro, sem depender de nenhum
runtime além do Postgres. Só que o PostgREST do Supabase **não expõe funções fora do
schema `public`** por padrão. Por isso a migration
`supabase/migrations/20260827100900_phase_2_10_api_public_wrappers.sql` cria wrappers
finos em `public` (`SECURITY INVOKER` — nunca elevam privilégio, RLS/RBAC continuam
valendo exatamente como em qualquer chamada direta), e os arquivos aqui em `api/`
chamam esses wrappers via `supabase-js`.

## Segurança (seção 53)

- **Nunca** use `SUPABASE_SERVICE_ROLE_KEY` em código que roda no navegador. Os arquivos
  em `api/` rodam só no servidor (Node) e usam a `ANON_KEY` + o JWT do usuário logado —
  ou seja, cada requisição roda com o **RBAC/RLS do usuário real**, nunca com privilégio
  elevado. Isso é deliberado: a API não é um "atalho" para contornar RLS, é uma camada
  fina de conveniência sobre o mesmo Postgres com as mesmas regras.
- Nenhuma secret (chave de API, senha, token) é logada ou devolvida na resposta.
- `middleware/auth.js` rejeita qualquer requisição sem `Authorization: Bearer <jwt>`.

## Endpoints

| Método | Rota | Wrapper SQL chamado | Autenticação |
|---|---|---|---|
| GET | `/health` | — | nenhuma (checagem de deploy) |
| GET | `/api/version` | — | nenhuma (nunca inclui segredos) |
| GET | `/api/cities` | `public.pricing_cities_list()` | qualquer autenticado |
| GET | `/api/cities/:id` | `public.pricing_city_detail(uuid)` | qualquer autenticado |
| POST | `/api/pricing/calculate` | `public.pricing_calculate_full(jsonb)` | qualquer autenticado — Pricing Engine centralizado (nunca confia em valor vindo do cliente) |
| POST | `/api/pricing/growth-curve` | `public.pricing_growth_curve(...)` | qualquer autenticado |
| POST | `/api/pricing/horizon-table` | `public.pricing_horizon_table(...)` | qualquer autenticado |
| GET | `/api/pricing/ramp` | `public.pricing_ramp_rules_list(uuid)` | qualquer autenticado |
| GET | `/api/pricing/indices` | `public.pricing_indices_list(text, int)` | qualquer autenticado |
| GET | `/api/pricing/:id` | `public.pricing_simulation_get(uuid)` | dono da simulação ou DIRETOR/ADMINISTRADOR/AUDITOR |
| POST | `/api/pricing/simulate` | `public.pricing_simulate(jsonb)` | qualquer autenticado |
| POST | `/api/pricing/quote` | `public.pricing_quote(uuid, numeric)` | qualquer autenticado |
| POST | `/api/pricing/approve` | `public.pricing_override_approve(uuid, boolean, text)` | DIRETOR/ADMINISTRADOR (RLS + trigger) |
| GET | `/api/pricing/versions` | `public.pricing_versions_list(uuid)` | qualquer autenticado |
| GET | `/api/pricing/scenarios` | `public.pricing_scenarios_list(uuid)` | dono da simulação ou DIRETOR/ADMINISTRADOR/AUDITOR |
| POST | `/api/pricing/override` | `public.pricing_override_create(...)` | COMERCIAL/DIRETOR/ADMINISTRADOR |
| GET | `/api/pricing/roi` | `public.pricing_roi(jsonb, numeric, integer[])` | qualquer autenticado |
| GET | `/api/pricing/projection` | `public.pricing_projection(jsonb)` | qualquer autenticado |
| GET | `/api/pricing/current-role` | `public.pricing_current_user_role()` | qualquer autenticado |
| POST | `/api/simulations` | `public.pricing_simulation_save(...)` | COMERCIAL/DIRETOR/ADMINISTRADOR |
| GET | `/api/simulations` | `public.pricing_scenarios_list(uuid)` | dono ou DIRETOR/ADMINISTRADOR/AUDITOR |
| POST | `/api/proposals` | `public.pricing_proposal_create(...)` | COMERCIAL/DIRETOR/ADMINISTRADOR |
| GET | `/api/proposals` | `public.pricing_proposals_list(...)` | qualquer autenticado |
| GET | `/api/audit` | `public.pricing_audit_list(...)` | qualquer autenticado |
| POST | `/api/audit/login` | `public.pricing_log_login()` | qualquer autenticado |

## Rodando localmente

```bash
cd api
npm install
cp .env.example .env   # preencher SUPABASE_URL e SUPABASE_ANON_KEY (nunca a service_role)
npm start               # ou: npm test (smoke test) / npm run lint
```

Para desenvolvimento sem um projeto Supabase real ainda, ver
`supabase/dev-local-only/` — sobe um PostgREST local + proxy que simulam a camada REST de
um Supabase de verdade contra o Postgres local. `tests/run_tests_deploy.sh` automatiza
esse fluxo inteiro (regressão SQL + PostgREST + API + testes HTTP reais).

## Deploy (Railway)

Ver `railway.toml` na raiz do repositório e `Dockerfile` neste diretório. Variáveis a
configurar no painel do Railway: `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
`CORS_ALLOWED_ORIGINS` (a URL do Vercel), `APP_ENVIRONMENT=production`. Nunca configure
`SUPABASE_SERVICE_ROLE_KEY` — esta API não usa e não deve usar.
