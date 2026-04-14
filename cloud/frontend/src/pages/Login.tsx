import { useEffect } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import Layout from "../components/Layout";
import AuthModal from "../components/AuthModal";

export default function Login() {
  const { user, loading } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const redirect = params.get("redirect") || "/projects";

  useEffect(() => {
    if (!loading && user) {
      navigate(redirect, { replace: true });
    }
  }, [user, loading, navigate, redirect]);

  if (loading) {
    return (
      <Layout>
        <div className="page-loading">
          <div className="spinner" />
        </div>
      </Layout>
    );
  }

  if (user) return null;

  return (
    <Layout>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          minHeight: "calc(100vh - 60px)",
          padding: 24,
        }}
      >
        <AuthModal
          inline
          onSuccess={() => navigate(redirect, { replace: true })}
          subtitle="Sign in to manage your projects"
        />
      </div>
    </Layout>
  );
}
