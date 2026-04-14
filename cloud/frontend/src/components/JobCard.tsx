import { useState, useEffect } from "react";
import FloorPlan from "./FloorPlan";
import SubmitQuoteForm from "./SubmitQuoteForm";

export interface Job {
  rfq_id: string;
  title: string;
  description: string | null;
  address: string | null;
  created_at: string | null;
  homeowner: { name: string | null; icon_url: string | null; email?: string | null };
  bid: {
    id: string;
    price_cents: number;
    status: string;
    received_at: string | null;
    description?: string | null;
    pdf_url?: string | null;
  } | null;
  job_status: "new" | "pending" | "won" | "lost";
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

interface ContractorViewData {
  rfq_id: string;
  title: string;
  address: string | null;
  job_description: string | null;
  project_scope: string | null;
  rooms: Room[];
}

function fmtPrice(cents: number): string {
  return "$" + (cents / 100).toLocaleString("en-US", { minimumFractionDigits: 0 });
}

function fmtDate(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

function fmtNum(n: number | null): string {
  if (n == null) return "—";
  return n.toLocaleString("en-US", { maximumFractionDigits: 1 });
}

function getInitials(name: string | null): string {
  if (!name) return "?";
  return name.split(/\s+/).map((w) => w[0]).slice(0, 2).join("").toUpperCase();
}

function formatLabel(key: string): string {
  return key.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

const statusConfig: Record<string, { label: string; className: string }> = {
  new: { label: "New", className: "badge-info" },
  pending: { label: "Pending", className: "badge-pending" },
  won: { label: "Won", className: "badge-won" },
  lost: { label: "Lost", className: "badge-lost" },
};

export default function JobCard({ job: initialJob }: { job: Job }) {
  const [job, setJob] = useState(initialJob);
  const [expanded, setExpanded] = useState(false);
  const [detail, setDetail] = useState<ContractorViewData | null>(null);
  const [loadingDetail, setLoadingDetail] = useState(false);
  const [expandedRooms, setExpandedRooms] = useState<Set<string>>(new Set());
  const [showQuoteForm, setShowQuoteForm] = useState(false);
  const ho = job.homeowner;
  const cfg = statusConfig[job.job_status] || statusConfig.new;

  const displayName = ho.name || ho.email?.split("@")[0] || "Homeowner";
  const cardTitle = `${displayName} — ${job.title}`;

  useEffect(() => {
    if (!expanded || detail || loadingDetail) return;
    setLoadingDetail(true);
    fetch(`/api/rfqs/${job.rfq_id}/contractor-view`)
      .then((r) => r.ok ? r.json() : null)
      .then(setDetail)
      .catch(() => {})
      .finally(() => setLoadingDetail(false));
  }, [expanded, detail, loadingDetail, job.rfq_id]);

  function toggleRoom(scanId: string) {
    const next = new Set(expandedRooms);
    if (next.has(scanId)) next.delete(scanId);
    else next.add(scanId);
    setExpandedRooms(next);
  }

  return (
    <div className={`contractor-card${expanded ? " expanded" : ""}`}>
      <div className="contractor-card-header" onClick={() => setExpanded(!expanded)}>
        <div className="contractor-card-icon">
          {ho.icon_url ? (
            <img src={ho.icon_url} alt="" />
          ) : (
            <span className="contractor-card-initials">{getInitials(displayName)}</span>
          )}
        </div>

        <div className="contractor-card-summary">
          <div className="contractor-card-name">{cardTitle}</div>
          <div className="contractor-card-meta">
            {job.address && <span>{job.address}</span>}
            <span className={`badge ${cfg.className}`}>{cfg.label}</span>
          </div>
        </div>

        <div style={{ textAlign: "right", flexShrink: 0 }}>
          {job.bid ? (
            <div className="contractor-card-price">{fmtPrice(job.bid.price_cents)}</div>
          ) : (
            <span style={{ fontSize: 13, fontWeight: 600, color: "var(--color-primary)" }}>
              View &rarr;
            </span>
          )}
        </div>
      </div>

      {expanded && (
        <div className="contractor-card-detail">
          {/* Homeowner info */}
          <div style={{ display: "flex", gap: 16, fontSize: 13, color: "var(--color-text-muted)", marginBottom: 16, paddingTop: 12, flexWrap: "wrap", alignItems: "center" }}>
            <span>Homeowner: <strong style={{ color: "var(--color-text)" }}>{displayName}</strong></span>
            {ho.email && !ho.email.includes("@unknown") && (
              <a href={`mailto:${ho.email}`} style={{ color: "var(--color-primary)", fontWeight: 600 }}>{ho.email}</a>
            )}
            {job.created_at && <span>Posted {fmtDate(job.created_at)}</span>}
            {job.bid?.received_at && <span>Bid submitted {fmtDate(job.bid.received_at)}</span>}
          </div>

          {/* Description */}
          {(job.description || detail?.job_description) && (
            <div style={{ marginBottom: 16 }}>
              <h4 style={{ fontSize: 13, fontWeight: 700, color: "var(--color-text-secondary)", marginBottom: 4, textTransform: "uppercase", letterSpacing: "0.5px" }}>Description</h4>
              <p className="contractor-card-description" style={{ marginBottom: 0 }}>
                {detail?.job_description || job.description}
              </p>
            </div>
          )}

          {/* Your bid (for pending/won/lost) */}
          {job.bid && (
            <div style={{
              marginBottom: 16, padding: 14, borderRadius: "var(--radius-md)",
              border: "1px solid var(--color-border-light)", background: "#fafbfc",
            }}>
              <h4 style={{ fontSize: 13, fontWeight: 700, color: "var(--color-text-secondary)", marginBottom: 8, textTransform: "uppercase", letterSpacing: "0.5px" }}>Your Quote</h4>
              <div style={{ display: "flex", gap: 16, alignItems: "baseline", marginBottom: 8 }}>
                <span style={{ fontSize: 20, fontWeight: 700 }}>{fmtPrice(job.bid.price_cents)}</span>
                <span className={`badge ${cfg.className}`}>{cfg.label}</span>
              </div>
              {job.bid.description && (
                <p style={{ fontSize: 14, lineHeight: 1.6, color: "#3a3a3c", whiteSpace: "pre-wrap", marginBottom: 8 }}>
                  {job.bid.description}
                </p>
              )}
              {job.bid.pdf_url && (
                <a
                  href={job.bid.pdf_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="contractor-card-pdf"
                >
                  <svg width="18" height="18" viewBox="0 0 24 24" fill="var(--color-primary)">
                    <path d="M14 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V8l-6-6zm-1 2l5 5h-5V4zm-3 9v2H8v-2h2zm6 0v2h-4v-2h4zm-6 4v2H8v-2h2zm6 0v2h-4v-2h4z" />
                  </svg>
                  View Attached PDF
                </a>
              )}
            </div>
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

          {/* Rooms (collapsed by default) */}
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
                      {/* Room header (always visible, clickable) */}
                      <div
                        onClick={() => toggleRoom(room.scan_id)}
                        style={{
                          display: "flex", justifyContent: "space-between", alignItems: "center",
                          padding: "10px 14px", cursor: "pointer",
                        }}
                      >
                        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                          <span style={{ fontSize: 14, fontWeight: 700 }}>{room.room_label || "Room"}</span>
                          {room.floor_area_sqft != null && (
                            <span style={{ fontSize: 12, color: "var(--color-text-muted)" }}>{fmtNum(room.floor_area_sqft)} sqft</span>
                          )}
                        </div>
                        <span style={{ fontSize: 12, color: "var(--color-text-muted)" }}>{isOpen ? "▲" : "▼"}</span>
                      </div>

                      {/* Room details (collapsed) */}
                      {isOpen && (
                        <div style={{ padding: "0 14px 14px" }}>
                          {/* Dimensions */}
                          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(120px, 1fr))", gap: 6, fontSize: 13, marginBottom: 8 }}>
                            {room.floor_area_sqft != null && <div><span style={{ color: "var(--color-text-muted)" }}>Floor: </span><strong>{fmtNum(room.floor_area_sqft)} sqft</strong></div>}
                            {room.wall_area_sqft != null && <div><span style={{ color: "var(--color-text-muted)" }}>Walls: </span><strong>{fmtNum(room.wall_area_sqft)} sqft</strong></div>}
                            {room.ceiling_height_ft != null && <div><span style={{ color: "var(--color-text-muted)" }}>Height: </span><strong>{fmtNum(room.ceiling_height_ft)} ft</strong></div>}
                            {room.perimeter_linear_ft != null && <div><span style={{ color: "var(--color-text-muted)" }}>Perimeter: </span><strong>{fmtNum(room.perimeter_linear_ft)} ft</strong></div>}
                          </div>

                          {/* Detected materials */}
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

                          {/* Scope items */}
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

                          {/* Scope notes */}
                          {room.scope?.notes && (
                            <div style={{ fontSize: 13, color: "#3a3a3c", fontStyle: "italic", marginTop: 4 }}>
                              Note: {room.scope.notes}
                            </div>
                          )}
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
            <a href={`/quote/${job.rfq_id}`} className="btn" style={{ fontSize: 13, padding: "8px 16px" }}>
              View 3D Scan
            </a>
            {job.job_status === "new" && !showQuoteForm && (
              <button
                className="btn btn-primary"
                style={{ fontSize: 13, padding: "8px 16px" }}
                onClick={() => setShowQuoteForm(true)}
              >
                Submit Quote
              </button>
            )}
          </div>

          {/* Submit quote form */}
          {showQuoteForm && (
            <SubmitQuoteForm
              rfqId={job.rfq_id}
              onCancel={() => setShowQuoteForm(false)}
              onSubmitted={(bid) => {
                setShowQuoteForm(false);
                setJob({
                  ...job,
                  job_status: "pending",
                  bid: {
                    id: bid.id,
                    price_cents: bid.price_cents,
                    status: "pending",
                    received_at: new Date().toISOString(),
                  },
                });
              }}
            />
          )}

          <button className="contractor-card-collapse-btn" onClick={() => setExpanded(false)} style={{ marginTop: 12 }}>
            Close
          </button>
        </div>
      )}
    </div>
  );
}
