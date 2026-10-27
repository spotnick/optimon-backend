import { lazy, Suspense } from 'react';
import { Routes, Route } from 'react-router-dom';
import Layout from './components/Layout';
import ProtectedRoute from './components/ProtectedRoute';
import Login from './pages/Login';
import DefinirSenha from './pages/DefinirSenha';
import Dashboard from './pages/Dashboard';
import Cities from './pages/Cities';
import NewCity from './pages/NewCity';
import CityDetail from './pages/CityDetail';
import EditCity from './pages/EditCity';
import NewSimulation from './pages/NewSimulation';
import Proposals from './pages/Proposals';
import ProposalDetail from './pages/ProposalDetail';
import Audit from './pages/Audit';
import Help from './pages/Help';
import Users from './pages/Users';
import UsersHealth from './pages/UsersHealth';
import Partners from './pages/Partners';
import PartnerDetail from './pages/PartnerDetail';
import Contracts from './pages/Contracts';
import ContractDetail from './pages/ContractDetail';
import Signatures from './pages/Signatures';
import SignatureDetail from './pages/SignatureDetail';
import SignatureSettings from './pages/SignatureSettings';
import Reports from './pages/Reports';
import Alerts from './pages/Alerts';
import PartnerExternalProposal from './pages/PartnerExternalProposal';
import SignExternal from './pages/SignExternal';

// OptiMap (Fase 3): carregado sob demanda — o MapLibre (~800 kB) só é baixado por quem
// abre o mapa; as demais telas não pagam esse custo.
const OptiMap = lazy(() => import('./pages/OptiMap'));
// OptiMap Fase 4: importações de postes de referência (mesmo chunk de mapa, sob demanda).
const OptiMapImportacoes = lazy(() => import('./pages/OptiMapImportacoes'));
// OptiMap Fase 5: listas do CES e empresas com contrato Copel.
const OptiMapCes = lazy(() => import('./pages/OptiMapCes'));
const OptiMapEmpresas = lazy(() => import('./pages/OptiMapEmpresas'));

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      {/* Destino do redirectTo de convite/redefinição de senha (ver
          api/routes/users.js:frontendRedirectUrl) — fora de ProtectedRoute de propósito:
          quem chega aqui só tem a sessão temporária que o próprio link do Supabase Auth
          gerou, nunca uma senha definida ainda. */}
      <Route path="/definir-senha" element={<DefinirSenha />} />
      {/* Fase 3.11 (seções 5-9): área externa REAL do parceiro — SEM login, fora de
          <ProtectedRoute> de propósito (o parceiro nunca tem usuário/senha no OptiMon).
          Autenticação é o próprio token de alta entropia na URL, validado no servidor a
          cada chamada (ver web/src/pages/PartnerExternalProposal.jsx). */}
      <Route path="/parceiro/proposta/:token" element={<PartnerExternalProposal />} />
      {/* Fase 3.11.4 (seções 12-13): link individual de assinatura eletrônica — SEM
          login, mesmo padrão de /parceiro/proposta/:token acima (token opaco validado no
          servidor, nunca um JWT — ver web/src/pages/SignExternal.jsx). */}
      <Route path="/assinar/:token" element={<SignExternal />} />
      <Route
        element={
          <ProtectedRoute>
            <Layout />
          </ProtectedRoute>
        }
      >
        <Route path="/" element={<Dashboard />} />
        <Route path="/cidades" element={<Cities />} />
        <Route path="/cidades/nova" element={<NewCity />} />
        <Route path="/cidades/:id" element={<CityDetail />} />
        <Route path="/cidades/:id/editar" element={<EditCity />} />
        <Route path="/simulacao" element={<NewSimulation />} />
        <Route path="/propostas" element={<Proposals />} />
        <Route path="/propostas/:id" element={<ProposalDetail />} />
        <Route path="/proponentes" element={<Partners />} />
        <Route path="/proponentes/:id" element={<PartnerDetail />} />
        <Route path="/contratos" element={<Contracts />} />
        <Route path="/contratos/:id" element={<ContractDetail />} />
        <Route path="/relatorios" element={<Reports />} />
        <Route path="/alertas" element={<Alerts />} />
        <Route path="/assinaturas" element={<Signatures />} />
        <Route path="/assinaturas/:id" element={<SignatureDetail />} />
        <Route path="/usuarios" element={<Users />} />
        <Route path="/usuarios/saude" element={<UsersHealth />} />
        <Route path="/configuracoes/assinatura" element={<SignatureSettings />} />
        <Route path="/auditoria" element={<Audit />} />
        <Route path="/ajuda" element={<Help />} />
        <Route
          path="/optimap"
          element={(
            <Suspense fallback={<div className="om-carregando-pagina" style={{ padding: 48, display: 'flex', gap: 12, alignItems: 'center', color: 'var(--text-muted)' }}><div className="spinner" /> Carregando o mapa…</div>}>
              <OptiMap />
            </Suspense>
          )}
        />
        {['/optimap/importacoes', '/optimap/importacoes/:id'].map((path) => (
          <Route
            key={path}
            path={path}
            element={(
              <Suspense fallback={<div style={{ padding: 48, display: 'flex', gap: 12, alignItems: 'center', color: 'var(--text-muted)' }}><div className="spinner" /> Carregando…</div>}>
                <OptiMapImportacoes />
              </Suspense>
            )}
          />
        ))}
        {['/optimap/ces', '/optimap/ces/:id'].map((path) => (
          <Route
            key={path}
            path={path}
            element={(
              <Suspense fallback={<div style={{ padding: 48, display: 'flex', gap: 12, alignItems: 'center', color: 'var(--text-muted)' }}><div className="spinner" /> Carregando…</div>}>
                <OptiMapCes />
              </Suspense>
            )}
          />
        ))}
        {['/optimap/empresas'].map((path) => (
          <Route
            key={path}
            path={path}
            element={(
              <Suspense fallback={<div style={{ padding: 48, display: 'flex', gap: 12, alignItems: 'center', color: 'var(--text-muted)' }}><div className="spinner" /> Carregando…</div>}>
                <OptiMapEmpresas />
              </Suspense>
            )}
          />
        ))}
      </Route>
    </Routes>
  );
}
