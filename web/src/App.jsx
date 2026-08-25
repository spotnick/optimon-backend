import { Routes, Route } from 'react-router-dom';
import Layout from './components/Layout';
import ProtectedRoute from './components/ProtectedRoute';
import Login from './pages/Login';
import Dashboard from './pages/Dashboard';
import CityDetail from './pages/CityDetail';
import NewSimulation from './pages/NewSimulation';
import Proposals from './pages/Proposals';
import Audit from './pages/Audit';

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route
        element={
          <ProtectedRoute>
            <Layout />
          </ProtectedRoute>
        }
      >
        <Route path="/" element={<Dashboard />} />
        <Route path="/cidades/jussara" element={<CityDetail jussara />} />
        <Route path="/cidades/:id" element={<CityDetail />} />
        <Route path="/simulacao" element={<NewSimulation />} />
        <Route path="/propostas" element={<Proposals />} />
        <Route path="/auditoria" element={<Audit />} />
      </Route>
    </Routes>
  );
}
