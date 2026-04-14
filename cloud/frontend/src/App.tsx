import { Routes, Route } from "react-router-dom";
import Landing from "./pages/Landing";
import Login from "./pages/Login";
import Projects from "./pages/Projects";
import ProjectQuotes from "./pages/ProjectQuotes";
import Search from "./pages/Search";
import ProtectedRoute from "./components/ProtectedRoute";

export default function App() {
  return (
    <Routes>
      <Route path="/" element={<Landing />} />
      <Route path="/login" element={<Login />} />
      <Route path="/search" element={<Search />} />
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
    </Routes>
  );
}
