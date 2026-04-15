import { useEffect, useState } from "react";
import Layout from "../components/Layout";
import FloorPlan from "../components/FloorPlan";
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

interface Room {
  scan_id: string;
  room_label: string;
  floor_area_sqft: number | null;
  wall_area_sqft: number | null;
  ceiling_height_ft: number | null;
  perimeter_linear_ft: number | null;
  room_polygon_ft: number[][] | null;
  detected_components: { detected?: string[]; details?: Record<string, { qty?: number; unit?: string }> } | null;
  scope: { items?: string[]; notes?: string } | null;
  scan_status: string;
}

interface ProjectDetail {
  rfq_id: string;
  title: string;
  address: string | null;
  job_description: string | null;
  project_scope: string | null;
  rooms: Room[];
}

function fmtDate(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

function fmtNum(n: number | null): string {
  if (n == null) return "—";
  return n.toLocaleString("en-US", { maximumFractionDigits: 1 });
}

function statusLabel(s: string): string {
  return s.replace(/_/g, " ");
}

function formatLabel(key: string): string {
  return key.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
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

        {loading && <div className="page-loading"><div className="spinner" /></div>}

        {!loading && error && (
          <div className="empty-state"><h3>Something went wrong</h3><p>{error}</p></div>
        )}

        {!loading && !error && rfqs.length === 0 && (
          <div className="empty-state">
            <h3>No projects yet</h3>
            <p>Projects are created when you scan a room with the RoomScanAlpha iOS app. Download the app to get started.</p>
          </div>
        )}

        <div style={{ display: "grid", gap: 16 }}>
          {rfqs.map((rfq) => (
            <ProjectCard key={rfq.id} rfq={rfq} onDelete={(id) => setRfqs(rfqs.filter((r) => r.id !== id))} />
          ))}
        </div>
      </div>
    </Layout>
  );
}


function ProjectCard({ rfq: initialRfq, onDelete }: { rfq: RFQ; onDelete: (id: string) => void }) {
  const [rfq, setRfq] = useState(initialRfq);
  const [expanded, setExpanded] = useState(false);
  const [detail, setDetail] = useState<ProjectDetail | null>(null);
  const [loadingDetail, setLoadingDetail] = useState(false);
  const [expandedRooms, setExpandedRooms] = useState<Set<string>>(new Set());
  const [editing, setEditing] = useState(false);
  const [editTitle, setEditTitle] = useState(rfq.title || "");
  const [editAddress, setEditAddress] = useState(rfq.address || "");
  const [editDesc, setEditDesc] = useState(rfq.description || "");
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    if (!expanded || detail || loadingDetail) return;
    setLoadingDetail(true);
    fetch(`/api/rfqs/${rfq.id}/contractor-view`)
      .then((r) => r.ok ? r.json() : null)
      .then(setDetail)
      .catch(() => {})
      .finally(() => setLoadingDetail(false));
  }, [expanded, detail, loadingDetail, rfq.id]);

  function toggleRoom(scanId: string) {
    const next = new Set(expandedRooms);
    if (next.has(scanId)) next.delete(scanId); else next.add(scanId);
    setExpandedRooms(next);
  }

  return (
    <div className="card" style={{ overflow: "hidden" }}>
      {/* Header (always visible, clickable) */}
      <div
        onClick={() => setExpanded(!expanded)}
        style={{ padding: 20, cursor: "pointer", display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 16, flexWrap: "wrap" }}
      >
        <div style={{ flex: 1, minWidth: 200 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 6 }}>
            <h3 style={{ fontSize: 16, fontWeight: 700 }}>{rfq.title || "Untitled Project"}</h3>
            <span className={`badge badge-${rfq.status}`}>{statusLabel(rfq.status)}</span>
          </div>
          {rfq.address && <p style={{ fontSize: 14, color: "var(--color-text-secondary)", marginBottom: 4 }}>{rfq.address}</p>}
          {rfq.description && !expanded && (
            <p style={{ fontSize: 13, color: "var(--color-text-muted)", marginBottom: 8, maxWidth: 500 }}>{rfq.description}</p>
          )}
          <div style={{ display: "flex", gap: 16, fontSize: 13, color: "var(--color-text-muted)" }}>
            {rfq.created_at && <span>{fmtDate(rfq.created_at)}</span>}
            {rfq.scan_count != null && <span>{rfq.scan_count} room{rfq.scan_count !== 1 ? "s" : ""}</span>}
            {rfq.bid_count != null && rfq.bid_count > 0 && <span>{rfq.bid_count} bid{rfq.bid_count !== 1 ? "s" : ""}</span>}
          </div>
        </div>

        <div style={{ display: "flex", gap: 8, flexShrink: 0 }}>
          <span style={{ fontSize: 13, fontWeight: 600, color: "var(--color-primary)" }}>
            {expanded ? "Close ▲" : "Details ▼"}
          </span>
        </div>
      </div>

      {/* Expanded detail */}
      {expanded && (
        <div style={{ padding: "0 20px 20px", borderTop: "1px solid var(--color-border-light)" }}>

          {/* Edit mode */}
          {editing ? (
            <div style={{ marginTop: 16, marginBottom: 16 }}>
              <div style={{ marginBottom: 10 }}>
                <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>Title</label>
                <input className="form-input" value={editTitle} onChange={(e) => setEditTitle(e.target.value)} />
              </div>
              <div style={{ marginBottom: 10 }}>
                <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>Address</label>
                <input className="form-input" value={editAddress} onChange={(e) => setEditAddress(e.target.value)} />
              </div>
              <div style={{ marginBottom: 10 }}>
                <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>Description</label>
                <textarea className="form-input" value={editDesc} onChange={(e) => setEditDesc(e.target.value)} rows={3} style={{ resize: "vertical" }} />
              </div>
              <div style={{ display: "flex", gap: 8 }}>
                <button className="btn btn-primary" disabled={saving} onClick={async () => {
                  setSaving(true);
                  try {
                    await apiFetch(`/api/rfqs/${rfq.id}`, {
                      method: "PUT",
                      body: JSON.stringify({ title: editTitle, address: editAddress, description: editDesc }),
                    });
                    setRfq({ ...rfq, title: editTitle, address: editAddress, description: editDesc });
                    setEditing(false);
                  } catch (err: unknown) { alert((err as Error).message || "Failed to save"); }
                  setSaving(false);
                }}>{saving ? "Saving..." : "Save"}</button>
                <button className="btn" onClick={() => setEditing(false)}>Cancel</button>
              </div>
            </div>
          ) : (
            <>
              {/* Description */}
              {(rfq.description || detail?.job_description) && (
                <div style={{ marginTop: 16, marginBottom: 16 }}>
                  <h4 style={{ fontSize: 13, fontWeight: 700, color: "var(--color-text-secondary)", marginBottom: 4, textTransform: "uppercase", letterSpacing: "0.5px" }}>Description</h4>
                  <p style={{ fontSize: 14, lineHeight: 1.6, color: "#3a3a3c", whiteSpace: "pre-wrap" }}>{detail?.job_description || rfq.description}</p>
                </div>
              )}

              {/* Scope of work */}
              {detail?.project_scope && (
                <div style={{ marginBottom: 16 }}>
                  <h4 style={{ fontSize: 13, fontWeight: 700, color: "var(--color-text-secondary)", marginBottom: 4, textTransform: "uppercase", letterSpacing: "0.5px" }}>Scope of Work</h4>
                  <p style={{ fontSize: 14, lineHeight: 1.6, color: "#3a3a3c", whiteSpace: "pre-wrap" }}>{detail.project_scope}</p>
                </div>
              )}
            </>
          )}

          {/* Loading */}
          {loadingDetail && (
            <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "12px 0", color: "var(--color-text-muted)", fontSize: 13 }}>
              <div className="spinner" style={{ width: 16, height: 16, borderWidth: 2 }} /> Loading details...
            </div>
          )}

          {/* Floor Plan */}
          {detail && detail.rooms.some((r) => r.room_polygon_ft && r.room_polygon_ft.length >= 3) && (
            <div style={{ marginBottom: 16 }}>
              <h4 style={{ fontSize: 13, fontWeight: 700, color: "var(--color-text-secondary)", marginBottom: 8, textTransform: "uppercase", letterSpacing: "0.5px" }}>Floor Plan</h4>
              <FloorPlan rooms={detail.rooms} height={220} />
            </div>
          )}

          {/* Rooms */}
          {detail && detail.rooms.length > 0 && (
            <div style={{ marginBottom: 16 }}>
              <h4 style={{ fontSize: 13, fontWeight: 700, color: "var(--color-text-secondary)", marginBottom: 8, textTransform: "uppercase", letterSpacing: "0.5px" }}>
                Rooms ({detail.rooms.length})
              </h4>
              <div style={{ display: "grid", gap: 8 }}>
                {detail.rooms.map((room) => {
                  const isOpen = expandedRooms.has(room.scan_id);
                  return (
                    <div key={room.scan_id} style={{
                      border: "1px solid var(--color-border-light)", borderRadius: "var(--radius-md)",
                      background: "#fafbfc", overflow: "hidden",
                    }}>
                      <div onClick={() => toggleRoom(room.scan_id)}
                        style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "10px 14px", cursor: "pointer" }}>
                        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                          <span style={{ fontSize: 14, fontWeight: 700 }}>{room.room_label || "Room"}</span>
                          {room.floor_area_sqft != null && (
                            <span style={{ fontSize: 12, color: "var(--color-text-muted)" }}>{fmtNum(room.floor_area_sqft)} sqft</span>
                          )}
                        </div>
                        <span style={{ fontSize: 12, color: "var(--color-text-muted)" }}>{isOpen ? "▲" : "▼"}</span>
                      </div>

                      {isOpen && (
                        <div style={{ padding: "0 14px 14px" }}>
                          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(120px, 1fr))", gap: 6, fontSize: 13, marginBottom: 8 }}>
                            {room.floor_area_sqft != null && <div><span style={{ color: "var(--color-text-muted)" }}>Floor: </span><strong>{fmtNum(room.floor_area_sqft)} sqft</strong></div>}
                            {room.wall_area_sqft != null && <div><span style={{ color: "var(--color-text-muted)" }}>Walls: </span><strong>{fmtNum(room.wall_area_sqft)} sqft</strong></div>}
                            {room.ceiling_height_ft != null && <div><span style={{ color: "var(--color-text-muted)" }}>Height: </span><strong>{fmtNum(room.ceiling_height_ft)} ft</strong></div>}
                            {room.perimeter_linear_ft != null && <div><span style={{ color: "var(--color-text-muted)" }}>Perimeter: </span><strong>{fmtNum(room.perimeter_linear_ft)} ft</strong></div>}
                          </div>

                          {room.detected_components?.detected && room.detected_components.detected.length > 0 && (
                            <div style={{ marginBottom: 8 }}>
                              <span style={{ fontSize: 12, fontWeight: 600, color: "var(--color-text-muted)" }}>Materials: </span>
                              <div style={{ display: "flex", gap: 4, flexWrap: "wrap", marginTop: 4 }}>
                                {room.detected_components.detected.map((mat) => (
                                  <span key={mat} style={{ fontSize: 11, padding: "2px 8px", borderRadius: 4, background: "var(--color-info-bg)", color: "var(--color-primary)", fontWeight: 500 }}>
                                    {formatLabel(mat)}
                                  </span>
                                ))}
                              </div>
                            </div>
                          )}

                          {room.scope?.items && room.scope.items.length > 0 && (
                            <div style={{ marginBottom: 8 }}>
                              <span style={{ fontSize: 12, fontWeight: 600, color: "var(--color-text-muted)" }}>Scope: </span>
                              <div style={{ display: "flex", gap: 4, flexWrap: "wrap", marginTop: 4 }}>
                                {room.scope.items.map((item) => (
                                  <span key={item} style={{ fontSize: 11, padding: "2px 8px", borderRadius: 4, background: "#e8f5e9", color: "#2e7d32", fontWeight: 500 }}>
                                    {formatLabel(item)}
                                  </span>
                                ))}
                              </div>
                            </div>
                          )}

                          {room.scope?.notes && (
                            <div style={{ fontSize: 13, color: "#3a3a3c", fontStyle: "italic", marginTop: 4 }}>
                              Note: {room.scope.notes}
                            </div>
                          )}

                          <button
                            onClick={async () => {
                              if (!confirm(`Delete room "${room.room_label}"?`)) return;
                              try {
                                await apiFetch(`/api/rfqs/${rfq.id}/scans/${room.scan_id}`, { method: "DELETE" });
                                setDetail({ ...detail!, rooms: detail!.rooms.filter((r) => r.scan_id !== room.scan_id) });
                              } catch (err: unknown) { alert((err as Error).message || "Failed to delete"); }
                            }}
                            style={{ fontSize: 12, fontWeight: 600, color: "var(--color-danger)", background: "none", border: "none", cursor: "pointer", fontFamily: "inherit", marginTop: 10 }}
                          >Delete Room</button>
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>
            </div>
          )}

          {/* Actions */}
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            <a href={`/quote/${rfq.id}`} className="btn" style={{ fontSize: 13, padding: "8px 16px" }}>View 3D Scan</a>
            <a href={`/projects/${rfq.id}/quotes`} className="btn btn-primary" style={{ fontSize: 13, padding: "8px 16px" }}>View Quotes</a>
            {!editing && (
              <button className="btn" style={{ fontSize: 13, padding: "8px 16px" }} onClick={() => {
                setEditTitle(rfq.title || "");
                setEditAddress(rfq.address || "");
                setEditDesc(rfq.description || "");
                setEditing(true);
              }}>Edit Project</button>
            )}
            <button className="btn" style={{ fontSize: 13, padding: "8px 16px", color: "var(--color-danger)", borderColor: "var(--color-danger)" }}
              onClick={async () => {
                if (!confirm(`Delete "${rfq.title || "this project"}"? This cannot be undone.`)) return;
                try {
                  await apiFetch(`/api/rfqs/${rfq.id}`, { method: "DELETE" });
                  onDelete(rfq.id);
                } catch (err: unknown) { alert((err as Error).message || "Failed to delete"); }
              }}>Delete Project</button>
          </div>

          <div style={{ fontSize: 11, color: "var(--color-text-placeholder)", marginTop: 12, fontFamily: "monospace" }}>{rfq.id}</div>
        </div>
      )}
    </div>
  );
}
