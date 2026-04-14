import { Routes, Route } from "react-router-dom";
import Landing from "./pages/Landing";
import Login from "./pages/Login";
import Projects from "./pages/Projects";
import ProjectQuotes from "./pages/ProjectQuotes";
import Search from "./pages/Search";
import Account from "./pages/Account";
import OrgDashboard from "./pages/OrgDashboard";
import Invite from "./pages/Invite";
import ProtectedRoute from "./components/ProtectedRoute";

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<Landing />} />
      <Route path="/login" element={<Login />} />
      <Route path="/search" element={<Search />} />
      <Route path="/invite" element={<Invite />} />
      <Route
        path="/projects"
        element={
          <ProtectedRoute>
            <Projects />
          </ProtectedRoute>
        }
      />
      <Route
        path="/projects/:rfqId/quotes"
        element={
          <ProtectedRoute>
            <ProjectQuotes />
          </ProtectedRoute>
        }
      />
      <Route
        path="/account"
        element={
          <ProtectedRoute>
            <Account />
          </ProtectedRoute>
        }
      />
      <Route
        path="/org"
        element={
          <ProtectedRoute>
            <OrgDashboard />
          </ProtectedRoute>
        }
      />
    </Routes>
  );
}
