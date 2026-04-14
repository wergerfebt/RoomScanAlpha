import { useEffect, useState } from "react";
import Layout from "../components/Layout";
import { apiFetch } from "../api/client";

interface RFQ {
  id: string;
  title: string | null;
  description: string | null;
  status: string;
  created_at: string | null;
  address: string | null;
  scan_count?: number;
  bid_count?: number;
  bid_view_token?: string | null;
}

function fmtDate(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function statusLabel(s: string): string {
  return s.replace(/_/g, " ");
}

export default function Projects() {
  const [rfqs, setRfqs] = useState<RFQ[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    apiFetch<{ rfqs: RFQ[] }>("/api/rfqs")
      .then((data) => setRfqs(data.rfqs))
      .catch((err) => setError(err.message || "Failed to load projects"))
      .finally(() => setLoading(false));
  }, []);

  return (
    <Layout>
      <div style={{ maxWidth: "var(--max-width)", margin: "0 auto", padding: "24px 24px 60px" }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, marginBottom: 24 }}>My Projects</h1>

        {/* Loading */}
        {loading && (
          <div className="page-loading">
            <div className="spinner" />
          </div>
        )}

        {/* Error */}
        {!loading && error && (
          <div className="empty-state">
            <h3>Something went wrong</h3>
            <p>{error}</p>
          </div>
        )}

        {/* Empty state */}
        {!loading && !error && rfqs.length === 0 && (
          <div className="empty-state">
            <h3>No projects yet</h3>
            <p>
              Projects are created when you scan a room with the RoomScanAlpha iOS app. Download the
              app to get started.
            </p>
          </div>
        )}

        {/* Project cards */}
        <div style={{ display: "grid", gap: 16 }}>
          {rfqs.map((rfq) => (
            <div key={rfq.id} className="card" style={{ padding: 20 }}>
              <div
                style={{
                  display: "flex",
                  alignItems: "flex-start",
                  justifyContent: "space-between",
                  gap: 16,
                  flexWrap: "wrap",
                }}
              >
                <div style={{ flex: 1, minWidth: 200 }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 6 }}>
                    <h3 style={{ fontSize: 16, fontWeight: 700 }}>
                      {rfq.title || "Untitled Project"}
                    </h3>
                    <span className={`badge badge-${rfq.status}`}>{statusLabel(rfq.status)}</span>
                  </div>

                  {rfq.address && (
                    <p style={{ fontSize: 14, color: "var(--color-text-secondary)", marginBottom: 4 }}>
                      {rfq.address}
                    </p>
                  )}

                  {rfq.description && (
                    <p
                      style={{
                        fontSize: 13,
                        color: "var(--color-text-muted)",
                        marginBottom: 8,
                        maxWidth: 500,
                      }}
                    >
                      {rfq.description}
                    </p>
                  )}

                  <div style={{ display: "flex", gap: 16, fontSize: 13, color: "var(--color-text-muted)" }}>
                    {rfq.created_at && <span>{fmtDate(rfq.created_at)}</span>}
                    {rfq.scan_count != null && <span>{rfq.scan_count} room{rfq.scan_count !== 1 ? "s" : ""}</span>}
                    {rfq.bid_count != null && rfq.bid_count > 0 && (
                      <span>{rfq.bid_count} bid{rfq.bid_count !== 1 ? "s" : ""}</span>
                    )}
                  </div>
                  <div style={{ fontSize: 11, color: "var(--color-text-placeholder)", marginTop: 8, fontFamily: "monospace" }}>
                    {rfq.id}
                  </div>
                </div>

                {/* Action links */}
                <div style={{ display: "flex", gap: 8, flexShrink: 0 }}>
                  <a
                    href={`/quote/${rfq.id}`}
                    className="btn"
                    style={{ fontSize: 13, padding: "8px 16px" }}
                  >
                    View Scans
                  </a>
                  <a
                    href={`/projects/${rfq.id}/quotes`}
                    className="btn btn-primary"
                    style={{ fontSize: 13, padding: "8px 16px" }}
                  >
                    View Quotes
                  </a>
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>
    </Layout>
  );
}
