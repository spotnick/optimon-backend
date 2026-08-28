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

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      {/* Destino do redirectTo de convite/redefinição de senha (ver
          api/routes/users.js:frontendRedirectUrl) — fora de ProtectedRoute de propósito:
          quem chega aqui só tem a sessão temporária que o próprio link do Supabase Auth
          gerou, nunca uma senha definida ainda. */}
      <Route path="/definir-senha" element={<DefinirSenha />} />
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
        <Route path="/assinaturas" element={<Signatures />} />
        <Route path="/assinaturas/:id" element={<SignatureDetail />} />
        <Route path="/usuarios" element={<Users />} />
        <Route path="/usuarios/saude" element={<UsersHealth />} />
        <Route path="/configuracoes/assinatura" element={<SignatureSettings />} />
        <Route path="/auditoria" element={<Audit />} />
        <Route path="/ajuda" element={<Help />} />
      </Route>
    </Routes>
  );
}
