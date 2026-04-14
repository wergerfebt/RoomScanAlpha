import { useEffect, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import Layout from "../components/Layout";
import AuthModal from "../components/AuthModal";
import { apiFetch } from "../api/client";

export default function Invite() {
  const { user, loading: authLoading } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const token = params.get("token") || "";

  const [status, setStatus] = useState<"idle" | "accepting" | "done" | "error">("idle");
  const [error, setError] = useState("");
  const [orgName, setOrgName] = useState("");
  const attempted = useRef(false);

  useEffect(() => {
    if (authLoading || !user || !token || attempted.current) return;
    attempted.current = true;
    setStatus("accepting");

    apiFetch<{ status: string; org_name: string }>("/api/org/accept-invite", {
      method: "POST",
      body: JSON.stringify({ token }),
    })
      .then((data) => {
        setOrgName(data.org_name);
        setStatus("done");
        setTimeout(() => navigate("/org", { replace: true }), 2000);
      })
      .catch((err) => {
        setError(err.message || "Failed to accept invite");
        setStatus("error");
      });
  }, [user, authLoading, token, navigate]);

  if (!token) {
    return (
      <Layout>
        <div className="empty-state" style={{ marginTop: 80 }}>
          <h3>Invalid Invite Link</h3>
          <p>This invite link is missing or malformed.</p>
        </div>
      </Layout>
    );
  }

  if (!authLoading && !user) {
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
            subtitle="Sign in or create an account to accept your team invitation"
            onSuccess={() => {}}
          />
        </div>
      </Layout>
    );
  }

  if (status === "accepting" || authLoading) {
    return (
      <Layout>
        <div className="page-loading">
          <div className="spinner" />
        </div>
      </Layout>
    );
  }

  if (status === "error") {
    return (
      <Layout>
        <div className="empty-state" style={{ marginTop: 80 }}>
          <h3>Something went wrong</h3>
          <p>{error}</p>
        </div>
      </Layout>
    );
  }

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
        <div style={{ textAlign: "center" }}>
          <h2 style={{ fontSize: 24, fontWeight: 700, color: "var(--color-success)", marginBottom: 12 }}>
            Welcome to {orgName}!
          </h2>
          <p style={{ fontSize: 15, color: "var(--color-text-secondary)" }}>
            Redirecting to your org dashboard...
          </p>
        </div>
      </div>
    </Layout>
  );
}
