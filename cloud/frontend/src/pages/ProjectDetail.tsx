import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import Layout from "../components/Layout";
import FloorPlan from "../components/FloorPlan";
import FilterSidebar, { type FilterValues } from "../components/FilterSidebar";
import ContractorCard, { type Bid } from "../components/ContractorCard";
import PhotosCarousel, { type CarouselAttachment } from "../components/PhotosCarousel";
import { apiFetch } from "../api/client";

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

interface ProjectView {
  rfq_id: string;
  title: string;
  address: string | null;
  job_description: string | null;
  project_scope: string | null;
  rooms: Room[];
}

interface BidsResponse {
  rfq_id: string;
  project_description: string | null;
  rfq_attachments?: CarouselAttachment[];
  bids: Bid[];
}

function fmtDate(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

function fmtPrice(cents: number): string {
  return "$" + (cents / 100).toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: 0 });
}

function sum(nums: (number | null | undefined)[]): number {
  return nums.reduce<number>((s, n) => s + (n ?? 0), 0);
}

function formatScopeLabel(key: string): string {
  return key.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

export default function ProjectDetail() {
  const { rfqId } = useParams<{ rfqId: string }>();
  const navigate = useNavigate();
  const [project, setProject] = useState<ProjectView | null>(null);
  const [bids, setBids] = useState<Bid[]>([]);
  const [rfqAttachments, setRfqAttachments] = useState<CarouselAttachment[]>([]);
  const [uploadingPhotos, setUploadingPhotos] = useState(false);
  const photoInputRef = useRef<HTMLInputElement>(null);
  const [rfqMeta, setRfqMeta] = useState<{ title: string | null; description: string | null; address: string | null; created_at: string | null } | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [sort, setSort] = useState<"price_asc" | "price_desc" | "rating" | "date">("price_asc");
  const [filters, setFilters] = useState<FilterValues>({ minPrice: 0, maxPrice: Infinity, minRating: "all" });
  const [hiring, setHiring] = useState(false);
  const [scanView, setScanView] = useState<"floorplan" | "bev">("floorplan");
  const [editing, setEditing] = useState(false);
  const [editTitle, setEditTitle] = useState("");
  const [editAddress, setEditAddress] = useState("");
  const [editDescription, setEditDescription] = useState("");
  const [saving, setSaving] = useState(false);
  const bidsRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!rfqId) return;
    let cancelled = false;

    (async () => {
      try {
        // Primary: contractor-view is public (link-based access). Load first so
        // non-owners signed in against their own account can still view the page.
        const viewRes = await fetch(`/api/rfqs/${rfqId}/contractor-view`);
        if (!viewRes.ok) {
          throw new Error(viewRes.status === 404 ? "Project not found" : "Failed to load project");
        }
        const view = (await viewRes.json()) as ProjectView;
        if (cancelled) return;
        setProject(view);

        // Meta + token path (owner list). May miss RFQs linked only via account.
        try {
          const rfqList = await apiFetch<{ rfqs: { id: string; title: string | null; description: string | null; address: string | null; created_at: string | null; bid_view_token: string | null }[] }>("/api/rfqs");
          const rfq = rfqList.rfqs.find((r) => r.id === rfqId);
          if (rfq && !cancelled) {
            setRfqMeta({ title: rfq.title, description: rfq.description, address: rfq.address, created_at: rfq.created_at });
            if (rfq.bid_view_token) {
              const b = await apiFetch<BidsResponse>(`/api/rfqs/${rfqId}/bids?token=${encodeURIComponent(rfq.bid_view_token)}`);
              if (!cancelled) {
                setBids(b.bids);
                setRfqAttachments(b.rfq_attachments ?? []);
              }
              return;
            }
          }
        } catch {
          // Signed-out — fall through to JWT path below.
        }

        // Fallback: attempt bids with JWT only. Works when the user owns the
        // RFQ via user_id match even if /api/rfqs list didn't surface it.
        try {
          const b = await apiFetch<BidsResponse>(`/api/rfqs/${rfqId}/bids`);
          if (!cancelled) {
            setBids(b.bids);
            setRfqAttachments(b.rfq_attachments ?? []);
          }
        } catch {
          // Not authorized — read-only view with no bids panel.
        }
      } catch (err: unknown) {
        if (!cancelled) setError((err as Error).message || "Failed to load project");
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => { cancelled = true; };
  }, [rfqId]);

  // Reset price filter range when bids load so the slider covers actual prices.
  useEffect(() => {
    if (!bids.length) return;
    const prices = bids.map((b) => b.price_cents);
    setFilters((f) => ({
      minPrice: Math.min(...prices),
      maxPrice: Math.max(...prices),
      minRating: f.minRating,
    }));
  }, [bids]);

  async function handlePhotoUpload(files: FileList | null) {
    if (!files || !files.length || !rfqId) return;
    setUploadingPhotos(true);
    try {
      const registered: CarouselAttachment[] = [];
      for (const file of Array.from(files)) {
        const ct = file.type || "image/jpeg";
        const qs = new URLSearchParams({ content_type: ct, filename: file.name });
        const { upload_url, blob_path } = await apiFetch<{ upload_url: string; blob_path: string }>(
          `/api/rfqs/${rfqId}/attachment-upload-url?${qs.toString()}`,
        );
        const put = await fetch(upload_url, {
          method: "PUT",
          headers: { "Content-Type": ct },
          body: file,
        });
        if (!put.ok) throw new Error(`Upload failed for ${file.name}`);
        registered.push({ blob_path, content_type: ct, name: file.name, size_bytes: file.size });
      }
      const res = await apiFetch<{ attachments: CarouselAttachment[] }>(
        `/api/rfqs/${rfqId}/attachments`,
        {
          method: "POST",
          body: JSON.stringify({ attachments: registered }),
        },
      );
      setRfqAttachments((prev) => {
        const byPath = new Map<string, CarouselAttachment>();
        for (const a of prev) byPath.set(a.blob_path, a);
        for (const a of res.attachments) byPath.set(a.blob_path, a);
        return Array.from(byPath.values());
      });
    } catch (err: unknown) {
      alert((err as Error).message || "Failed to upload photos");
    } finally {
      setUploadingPhotos(false);
      if (photoInputRef.current) photoInputRef.current.value = "";
    }
  }

  async function reloadBids() {
    if (!rfqId) return;
    const rfqList = await apiFetch<{ rfqs: { id: string; bid_view_token: string | null }[] }>("/api/rfqs");
    const token = rfqList.rfqs.find((r) => r.id === rfqId)?.bid_view_token;
    if (!token) return;
    const b = await apiFetch<BidsResponse>(`/api/rfqs/${rfqId}/bids?token=${encodeURIComponent(token)}`);
    setBids(b.bids);
    setRfqAttachments(b.rfq_attachments ?? []);
  }

  function openEdit() {
    setEditTitle(rfqMeta?.title || project?.title || "");
    setEditAddress(rfqMeta?.address || project?.address || "");
    setEditDescription(rfqMeta?.description || project?.job_description || "");
    setEditing(true);
  }

  async function saveEdit() {
    if (!rfqId) return;
    setSaving(true);
    try {
      await apiFetch(`/api/rfqs/${rfqId}`, {
        method: "PUT",
        body: JSON.stringify({ title: editTitle, address: editAddress, description: editDescription }),
      });
      setRfqMeta((prev) => prev ? { ...prev, title: editTitle, address: editAddress, description: editDescription } : prev);
      setProject((prev) => prev ? { ...prev, title: editTitle, address: editAddress, job_description: editDescription } : prev);
      setEditing(false);
    } catch (err: unknown) {
      alert((err as Error).message || "Failed to save");
    }
    setSaving(false);
  }

  async function handleDelete() {
    if (!rfqId) return;
    const name = rfqMeta?.title || project?.title || "this project";
    if (!confirm(`Delete "${name}"? This cannot be undone.`)) return;
    try {
      await apiFetch(`/api/rfqs/${rfqId}`, { method: "DELETE" });
      navigate("/projects");
    } catch (err: unknown) {
      alert((err as Error).message || "Failed to delete");
    }
  }

  async function handleHire(bidId: string, contractorName: string) {
    if (!rfqId) return;
    if (!confirm(`Accept the quote from ${contractorName}? Other bidders will be notified.`)) return;
    setHiring(true);
    try {
      await apiFetch(`/api/rfqs/${rfqId}/accept-bid`, {
        method: "POST",
        body: JSON.stringify({ bid_id: bidId }),
      });
      await reloadBids();
    } catch {
      alert("Failed to hire contractor. Please try again.");
    }
    setHiring(false);
  }

  const prices = useMemo(() => bids.map((b) => b.price_cents), [bids]);
  const filtered = useMemo(() => bids.filter((b) => {
    if (b.price_cents < filters.minPrice || b.price_cents > filters.maxPrice) return false;
    if (filters.minRating !== "all") {
      const r = b.contractor?.review_rating ?? 0;
      if (r < parseFloat(filters.minRating)) return false;
    }
    return true;
  }), [bids, filters]);

  const sorted = useMemo(() => [...filtered].sort((a, b) => {
    switch (sort) {
      case "price_desc": return b.price_cents - a.price_cents;
      case "rating":     return (b.contractor.review_rating ?? 0) - (a.contractor.review_rating ?? 0);
      case "date":       return (b.received_at || "").localeCompare(a.received_at || "");
      default:           return a.price_cents - b.price_cents;
    }
  }), [filtered, sort]);

  const lowestCents = bids.length ? Math.min(...bids.map((b) => b.price_cents)) : 0;
  const title = rfqMeta?.title || project?.title || "Project";
  const description = rfqMeta?.description || project?.job_description;
  const address = rfqMeta?.address || project?.address;
  const createdAt = rfqMeta?.created_at;
  const scope = project?.project_scope;

  const totalFloor = project ? sum(project.rooms.map((r) => r.floor_area_sqft)) : 0;
  const totalWall  = project ? sum(project.rooms.map((r) => r.wall_area_sqft))  : 0;
  const ceilingHeights = project ? project.rooms.map((r) => r.ceiling_height_ft).filter((v): v is number => v != null) : [];
  const avgCeiling = ceilingHeights.length ? ceilingHeights.reduce((s, v) => s + v, 0) / ceilingHeights.length : null;

  return (
    <Layout>
      {loading && <div className="page-loading"><div className="spinner" /></div>}
      {!loading && error && (
        <div className="empty-state"><h3>Couldn't load this project</h3><p>{error}</p></div>
      )}

      {!loading && !error && (
        <div style={{ maxWidth: "var(--max-width)", margin: "0 auto", padding: "var(--q-space-5) var(--q-space-5) var(--q-space-8)" }}>
          {/* Breadcrumb */}
          <div className="pd-crumb">
            <Link to="/projects">Projects</Link>
            <span className="pd-crumb-sep">›</span>
            <span>{title}</span>
          </div>

          {/* Header */}
          <header className="pd-header">
            <div className="pd-header-main">
              <h1 className="pd-title">{title}</h1>
              {description && <p className="pd-description">{description}</p>}
              <div className="pd-meta">
                {address && <span className="pd-meta-item">📍 {address}</span>}
                {project && project.rooms.length > 0 && (
                  <>
                    <span className="pd-dot" />
                    <span>{project.rooms.length} room{project.rooms.length !== 1 ? "s" : ""}</span>
                  </>
                )}
                {createdAt && (
                  <>
                    <span className="pd-dot" />
                    <span>Created {fmtDate(createdAt)}</span>
                  </>
                )}
              </div>
            </div>
            <div className="pd-header-actions">
              <a href={`/quote/${rfqId}`} className="pd-pill pd-pill-secondary">View 3D scan</a>
              {rfqMeta && (
                <button type="button" className="pd-pill pd-pill-secondary" onClick={openEdit}>Edit</button>
              )}
              {bids.length > 0 && (
                <button
                  type="button"
                  className="pd-pill pd-pill-primary"
                  onClick={() => bidsRef.current?.scrollIntoView({ behavior: "smooth", block: "start" })}
                >
                  Compare bids ({bids.length})
                </button>
              )}
            </div>
          </header>

          {editing && (
            <div className="pd-edit-overlay" onClick={() => !saving && setEditing(false)}>
              <div className="pd-edit-card" onClick={(e) => e.stopPropagation()}>
                <div className="pd-section-label" style={{ marginBottom: 14 }}>Edit project</div>
                <label className="pd-edit-label">Title</label>
                <input className="pd-edit-input" value={editTitle} onChange={(e) => setEditTitle(e.target.value)} />
                <label className="pd-edit-label">Address</label>
                <input className="pd-edit-input" value={editAddress} onChange={(e) => setEditAddress(e.target.value)} />
                <label className="pd-edit-label">Description</label>
                <textarea className="pd-edit-input" rows={4} value={editDescription} onChange={(e) => setEditDescription(e.target.value)} />
                <div className="pd-edit-actions">
                  <button type="button" className="pd-pill pd-pill-secondary" onClick={() => setEditing(false)} disabled={saving}>Cancel</button>
                  <button type="button" className="pd-pill pd-pill-primary" onClick={saveEdit} disabled={saving}>
                    {saving ? "Saving…" : "Save"}
                  </button>
                </div>

                <div className="pd-edit-danger">
                  <div className="pd-edit-danger-text">
                    <div className="pd-edit-danger-title">Delete project</div>
                    <div className="pd-edit-danger-sub">This removes the project and its scans. Cannot be undone.</div>
                  </div>
                  <button type="button" className="pd-pill pd-pill-danger" onClick={handleDelete} disabled={saving}>Delete</button>
                </div>
              </div>
            </div>
          )}

          {/* Scan band */}
          {project && project.rooms.length > 0 && (
            <section className="pd-band">
              <div className="pd-band-scan">
                <div className="pd-scan-tabs" role="tablist">
                  <button
                    type="button"
                    role="tab"
                    aria-selected={scanView === "floorplan"}
                    className={`pd-scan-tab ${scanView === "floorplan" ? "is-active" : ""}`}
                    onClick={() => setScanView("floorplan")}
                  >
                    Floor plan
                  </button>
                  <button
                    type="button"
                    role="tab"
                    aria-selected={scanView === "bev"}
                    className={`pd-scan-tab ${scanView === "bev" ? "is-active" : ""}`}
                    onClick={() => setScanView("bev")}
                  >
                    Bird's eye
                  </button>
                </div>
                <div className="pd-scan-view">
                  {scanView === "floorplan" ? (
                    project.rooms.some((r) => r.room_polygon_ft && r.room_polygon_ft.length >= 3) ? (
                      <FloorPlan rooms={project.rooms} height={320} />
                    ) : (
                      <div className="pd-scan-empty">Floor plan will appear after the scan processes.</div>
                    )
                  ) : (
                    <iframe
                      key={`bev-${rfqId}`}
                      title="Bird's eye 3D view"
                      src={`/embed/scan/${rfqId}?view=bev&measurements=on`}
                      className="pd-scan-iframe"
                    />
                  )}
                </div>
              </div>

              <div className="pd-band-stats">
                <div className="pd-section-label">Scan data</div>
                <div className="pd-stat-grid">
                  <Stat label="Total floor" value={totalFloor.toLocaleString()} unit="sqft" show={totalFloor > 0} />
                  <Stat label="Rooms" value={String(project.rooms.length)} unit="" show={project.rooms.length > 0} />
                  <Stat label="Wall area" value={totalWall.toLocaleString()} unit="sqft" show={totalWall > 0} />
                  <Stat label="Ceiling" value={avgCeiling ? avgCeiling.toFixed(1) : "—"} unit="ft" show={avgCeiling != null} />
                </div>

                <div className="pd-section-label" style={{ marginTop: 18 }}>Rooms</div>
                <div className="pd-rooms">
                  {project.rooms.map((r, i) => {
                    const items = r.scope?.items ?? [];
                    return (
                      <div key={r.scan_id} className="pd-room-row" style={{ borderTop: i > 0 ? "0.5px solid var(--q-divider)" : "none" }}>
                        <div className="pd-room-check">✓</div>
                        <div className="pd-room-body">
                          <div className="pd-room-name">{r.room_label || "Room"}</div>
                          <div className="pd-room-sub">
                            {r.floor_area_sqft != null ? `${r.floor_area_sqft.toFixed(0)} sqft · ` : ""}
                            {r.scan_status === "completed" || r.scan_status === "complete" ? "Scan complete" : r.scan_status.replace(/_/g, " ")}
                          </div>
                          {items.length > 0 && (
                            <div className="pd-room-chips">
                              {items.map((it) => (
                                <span key={it} className="pd-chip">{formatScopeLabel(it)}</span>
                              ))}
                              {r.scope?.notes && <span className="pd-chip pd-chip-note" title={r.scope.notes}>+ note</span>}
                            </div>
                          )}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            </section>
          )}

          {/* Scope of work */}
          {(scope || (project && project.rooms.some((r) => r.scope?.items?.length))) && (
            <section style={{ marginTop: 32 }}>
              <div className="pd-section-label">Scope of work</div>
              <div className="pd-scope">
                {scope && <div className="pd-scope-text">{scope}</div>}
                {project && project.rooms.some((r) => r.scope?.items?.length) && (
                  <div className={`pd-scope-rooms ${scope ? "pd-scope-rooms-bordered" : ""}`}>
                    {project.rooms
                      .filter((r) => r.scope?.items?.length)
                      .map((r) => (
                        <div key={r.scan_id} className="pd-scope-room">
                          <div className="pd-scope-room-name">{r.room_label || "Room"}</div>
                          <div className="pd-scope-room-items">
                            {r.scope!.items!.map((it) => (
                              <span key={it} className="pd-chip pd-chip-scope">{formatScopeLabel(it)}</span>
                            ))}
                          </div>
                          {r.scope?.notes && <div className="pd-scope-room-note">{r.scope.notes}</div>}
                        </div>
                      ))}
                  </div>
                )}
              </div>
            </section>
          )}

          {/* Project media — homeowner-shared media (direct upload + chat).
              Owners always see this section (with an add-photos affordance);
              non-owners only see it when photos exist. */}
          {(rfqMeta || rfqAttachments.some((a) => (a.content_type || "").startsWith("image/"))) && (
            <section style={{ marginTop: 32 }}>
              <div className="pd-photos-head">
                <div className="pd-section-label">Project media</div>
                {rfqMeta && (
                  <>
                    <input
                      ref={photoInputRef}
                      type="file"
                      accept="image/jpeg,image/png,image/webp,image/gif,image/heic"
                      multiple
                      style={{ display: "none" }}
                      onChange={(e) => handlePhotoUpload(e.target.files)}
                    />
                    <button
                      type="button"
                      className="pd-pill pd-pill-secondary pd-pill-sm"
                      disabled={uploadingPhotos}
                      onClick={() => photoInputRef.current?.click()}
                    >
                      {uploadingPhotos ? "Uploading…" : "Add media"}
                    </button>
                  </>
                )}
              </div>
              {rfqAttachments.length > 0 ? (
                <PhotosCarousel
                  attachments={rfqAttachments}
                  onDelete={rfqMeta ? async (att) => {
                    if (!att.attachment_id) return;
                    await apiFetch(`/api/rfqs/${rfqId}/attachments/${att.attachment_id}`, { method: "DELETE" });
                    setRfqAttachments((prev) => prev.filter((a) => a.blob_path !== att.blob_path));
                  } : undefined}
                />
              ) : (
                <div className="pd-photos-empty">
                  Share photos or videos of the space, reference inspiration, or materials — contractors will see these when reviewing your project.
                </div>
              )}
            </section>
          )}

          {/* Bids */}
          <section ref={bidsRef} style={{ marginTop: 40 }}>
            <div className="pd-bids-head">
              <div>
                <div className="pd-section-label">Bids</div>
                <h2 className="pd-bids-title">
                  {bids.length === 0 ? "No bids yet" : (
                    <>
                      {bids.length} bid{bids.length !== 1 ? "s" : ""} · low <span style={{ color: "var(--q-success)" }}>{fmtPrice(lowestCents)}</span>
                    </>
                  )}
                </h2>
              </div>
            </div>

            {bids.length === 0 ? (
              <div className="pd-bids-empty">
                <strong>Waiting on contractors</strong>
                <p>Bids will appear here as contractors review your 3D scan. Most arrive within 48 hours.</p>
              </div>
            ) : (
              <div className="pd-bids-layout">
                <FilterSidebar prices={prices} filters={filters} onChange={setFilters} />
                <div className="pd-bids-list">
                  {bids.length > 1 && (
                    <div className="list-page-sort">
                      <label>Sort:</label>
                      <select value={sort} onChange={(e) => setSort(e.target.value as typeof sort)}>
                        <option value="price_asc">Price ↑</option>
                        <option value="price_desc">Price ↓</option>
                        <option value="rating">Rating</option>
                        <option value="date">Newest</option>
                      </select>
                    </div>
                  )}

                  {sorted.length === 0 ? (
                    <div className="empty-state" style={{ padding: "40px 20px" }}>
                      <h3>No bids match filters</h3>
                      <p>Try adjusting your price range or rating.</p>
                    </div>
                  ) : (
                    sorted.map((bid) => (
                      <ContractorCard
                        key={bid.id}
                        contractor={bid.contractor}
                        bid={bid}
                        isLowest={bid.price_cents === lowestCents && sorted.length > 1}
                        onHire={bid.status !== "accepted" && !hiring && !bids.some((b) => b.status === "accepted") ? handleHire : undefined}
                      />
                    ))
                  )}
                </div>
              </div>
            )}
          </section>
        </div>
      )}

      <style>{PD_CSS}</style>
    </Layout>
  );
}

function Stat({ label, value, unit, show }: { label: string; value: string; unit: string; show: boolean }) {
  if (!show) return null;
  return (
    <div className="pd-stat">
      <div className="pd-stat-label">{label}</div>
      <div className="pd-stat-value">{value} <span className="pd-stat-unit">{unit}</span></div>
    </div>
  );
}

const PD_CSS = `
.pd-crumb {
  font-size: 13px; color: var(--q-ink-muted); margin-bottom: 12px;
  display: flex; align-items: center; gap: 6px; flex-wrap: wrap;
}
.pd-crumb a { color: var(--q-ink-muted); text-decoration: none; }
.pd-crumb a:hover { color: var(--q-ink); text-decoration: underline; }
.pd-crumb-sep { color: var(--q-ink-dim); }

.pd-header {
  display: flex; justify-content: space-between; align-items: flex-end;
  gap: 24px; flex-wrap: wrap; margin-bottom: 24px;
}
.pd-header-main { flex: 1; min-width: 280px; }
.pd-title {
  font-size: var(--q-fs-display); line-height: var(--q-lh-display);
  letter-spacing: var(--q-tr-display); font-weight: 700; margin: 0;
}
.pd-description {
  font-size: 16px; line-height: 1.5; color: var(--q-ink-soft);
  margin: 12px 0 0; max-width: 680px; white-space: pre-wrap;
}
.pd-meta {
  display: flex; gap: 10px; flex-wrap: wrap; align-items: center;
  margin-top: 10px; font-size: 14px; color: var(--q-ink-muted);
}
.pd-meta-item { display: inline-flex; align-items: center; gap: 5px; }
.pd-dot { width: 3px; height: 3px; background: var(--q-ink-dim); border-radius: 50%; }

.pd-header-actions { display: flex; gap: 8px; flex-wrap: wrap; }

/* Pills */
.pd-pill {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 10px 18px; font-size: 14px; font-weight: 600;
  border-radius: var(--q-radius-pill); cursor: pointer;
  border: 0.5px solid transparent; font-family: inherit;
  text-decoration: none; transition: filter 0.15s, background 0.15s;
  white-space: nowrap;
}
.pd-pill:disabled { opacity: 0.5; cursor: not-allowed; }
.pd-pill-primary   { background: var(--q-primary); color: var(--q-primary-ink); }
.pd-pill-primary:hover:not(:disabled)   { filter: brightness(0.92); text-decoration: none; }
.pd-pill-secondary { background: var(--q-surface); color: var(--q-ink); border-color: var(--q-hairline); }
.pd-pill-secondary:hover { background: var(--q-surface-muted); text-decoration: none; }
.pd-pill-soft      { background: var(--q-primary-soft); color: var(--q-primary); }
.pd-pill-soft:hover { filter: brightness(0.96); text-decoration: none; }
.pd-pill-muted     { background: transparent; color: var(--q-ink-muted); border-color: var(--q-hairline); cursor: default; }
.pd-pill-danger    { background: var(--q-surface); color: var(--q-danger); border-color: var(--q-hairline); }
.pd-pill-danger:hover:not(:disabled) { background: var(--q-danger); color: var(--q-primary-ink); border-color: var(--q-danger); }
.pd-pill-sm { padding: 6px 12px; font-size: 12px; font-weight: 600; }

/* Project media section — section header row with inline Add button */
.pd-photos-head {
  display: flex; align-items: center; justify-content: space-between; gap: 12px;
  margin-bottom: 10px;
}
.pd-photos-head .pd-section-label { margin-bottom: 0; }
.pd-photos-empty {
  padding: 16px 18px; background: var(--q-surface-muted); border-radius: 12px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
  font-size: 13px; color: var(--q-ink-muted); line-height: 1.5;
}

/* Edit modal */
.pd-edit-overlay {
  position: fixed; inset: 0; background: rgba(20, 26, 22, 0.45);
  display: flex; align-items: center; justify-content: center; z-index: 1000; padding: 20px;
}
.pd-edit-card {
  background: var(--q-surface); border-radius: var(--q-radius-xl); padding: 24px;
  width: 100%; max-width: 480px; box-shadow: 0 20px 60px rgba(0,0,0,0.25);
}
.pd-edit-label {
  display: block; font-size: 12px; font-weight: 700; letter-spacing: 0.3px;
  text-transform: uppercase; color: var(--q-ink-muted); margin: 12px 0 6px;
}
.pd-edit-input {
  width: 100%; padding: 10px 12px; font-size: 14px; font-family: inherit;
  border: 1px solid var(--q-hairline); border-radius: var(--q-radius-md);
  background: var(--q-surface); color: var(--q-ink); resize: vertical;
}
.pd-edit-input:focus { outline: none; border-color: var(--q-primary); }
.pd-edit-actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 20px; }
.pd-edit-danger {
  display: flex; align-items: center; justify-content: space-between; gap: 16px;
  margin-top: 24px; padding-top: 20px; border-top: 0.5px solid var(--q-divider);
}
.pd-edit-danger-title { font-size: 14px; font-weight: 700; color: var(--q-ink); }
.pd-edit-danger-sub { font-size: 12px; color: var(--q-ink-muted); margin-top: 2px; }

/* Band */
.pd-band {
  background: var(--q-surface); border-radius: var(--q-radius-xl);
  padding: 24px; display: grid; grid-template-columns: 1.3fr 1fr; gap: 32px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
}
@media (max-width: 860px) {
  .pd-band { grid-template-columns: 1fr; gap: 20px; padding: 18px; }
}
.pd-band-scan { display: flex; flex-direction: column; }
.pd-scan-tabs {
  display: inline-flex; align-self: flex-start; gap: 2px; padding: 3px;
  background: var(--q-surface-muted); border-radius: var(--q-radius-pill);
  margin-bottom: 12px;
}
.pd-scan-tab {
  border: none; background: transparent; padding: 6px 14px;
  font-size: 13px; font-weight: 600; font-family: inherit; cursor: pointer;
  color: var(--q-ink-muted); border-radius: var(--q-radius-pill);
  transition: background 0.15s, color 0.15s;
}
.pd-scan-tab:hover { color: var(--q-ink); }
.pd-scan-tab.is-active { background: var(--q-surface); color: var(--q-ink); box-shadow: 0 1px 2px rgba(0,0,0,0.04); }

.pd-scan-view {
  aspect-ratio: 16 / 10; border-radius: 14px; overflow: hidden;
  background: var(--q-scan-accent-soft); position: relative;
}
.pd-scan-view > div { height: 100% !important; background: transparent !important; border: none !important; border-radius: 0 !important; }
.pd-scan-view canvas { display: block; width: 100% !important; height: 100% !important; }
.pd-scan-iframe {
  width: 100%; height: 100%; border: 0; display: block; background: #000;
}
.pd-scan-empty {
  height: 100%; display: flex; align-items: center; justify-content: center;
  color: var(--q-ink-muted); font-size: 13px; padding: 24px; text-align: center;
}

.pd-section-label {
  font-size: var(--q-fs-label); font-weight: 700; letter-spacing: var(--q-tr-label);
  text-transform: uppercase; color: var(--q-ink-muted); margin-bottom: 10px;
}

.pd-stat-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
.pd-stat { padding: 12px 14px; background: var(--q-surface-muted); border-radius: 12px; }
.pd-stat-label {
  font-size: 11px; font-weight: 700; color: var(--q-ink-muted);
  letter-spacing: 0.3px; text-transform: uppercase;
}
.pd-stat-value { font-size: 22px; font-weight: 700; letter-spacing: -0.5px; margin-top: 2px; }
.pd-stat-unit { font-size: 13px; color: var(--q-ink-muted); font-weight: 500; }

.pd-rooms { background: var(--q-surface-muted); border-radius: 12px; overflow: hidden; }
.pd-room-row { display: flex; align-items: center; gap: 10px; padding: 12px 14px; }
.pd-room-check {
  width: 22px; height: 22px; border-radius: 50%; background: var(--q-success);
  color: #fff; display: flex; align-items: center; justify-content: center; font-size: 12px; font-weight: 700;
}
.pd-room-body { flex: 1; min-width: 0; }
.pd-room-name { font-size: 14px; font-weight: 600; }
.pd-room-sub { font-size: 12px; color: var(--q-ink-muted); text-transform: capitalize; }
.pd-room-chips { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 6px; }

.pd-chip {
  display: inline-block; font-size: 11px; font-weight: 600;
  padding: 2px 8px; border-radius: var(--q-radius-sm);
  background: var(--q-primary-soft); color: var(--q-primary);
}
.pd-chip-note { background: var(--q-surface); color: var(--q-ink-muted); box-shadow: inset 0 0 0 0.5px var(--q-hairline); cursor: help; }
.pd-chip-scope { font-size: 12px; padding: 3px 10px; }

/* Scope */
.pd-scope {
  background: var(--q-surface); border-radius: var(--q-radius-xl);
  padding: 24px; max-width: 820px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
}
.pd-scope-text {
  font-size: 16px; line-height: 1.55; color: var(--q-ink-soft);
  white-space: pre-wrap;
}
.pd-scope-rooms { display: flex; flex-direction: column; gap: 18px; }
.pd-scope-rooms-bordered { margin-top: 20px; padding-top: 20px; border-top: 0.5px solid var(--q-divider); }
.pd-scope-room {}
.pd-scope-room-name { font-size: 13px; font-weight: 700; color: var(--q-ink); margin-bottom: 6px; }
.pd-scope-room-items { display: flex; flex-wrap: wrap; gap: 6px; }
.pd-scope-room-note {
  font-size: 13px; color: var(--q-ink-muted); font-style: italic; margin-top: 8px;
  white-space: pre-wrap;
}

/* Bids */
.pd-bids-head {
  display: flex; justify-content: space-between; align-items: flex-end;
  gap: 16px; margin-bottom: 16px; flex-wrap: wrap;
}
.pd-bids-title {
  font-size: var(--q-fs-headline); line-height: var(--q-lh-headline);
  letter-spacing: var(--q-tr-headline); font-weight: 700; margin: 4px 0 0;
}

.pd-bids-empty {
  background: var(--q-surface); border-radius: var(--q-radius-xl); padding: 40px 24px;
  text-align: center; box-shadow: inset 0 0 0 0.5px var(--q-hairline);
}
.pd-bids-empty strong { display: block; font-size: 18px; margin-bottom: 6px; }
.pd-bids-empty p { font-size: 14px; color: var(--q-ink-muted); max-width: 380px; margin: 0 auto; }

.pd-bids-layout {
  display: flex; gap: 20px; align-items: flex-start;
}
.pd-bids-list { flex: 1; min-width: 0; }
@media (max-width: 768px) {
  .pd-bids-layout { flex-direction: column; }
}
`;
