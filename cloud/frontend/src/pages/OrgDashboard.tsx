import { useEffect, useMemo, useState, type FormEvent } from "react";
import { useSearchParams } from "react-router-dom";
import Layout from "../components/Layout";
import FloorPlan from "../components/FloorPlan";
import ContractorBidForm, { parseBidDescription } from "../components/ContractorBidForm";
import Inbox from "./Inbox";
import { apiFetch } from "../api/client";
import AddressAutocomplete from "../components/AddressAutocomplete";
import Lightbox, { type LightboxItem } from "../components/Lightbox";
import PhotosCarousel, { type CarouselAttachment } from "../components/PhotosCarousel";

interface JobAttachment {
  blob_path: string;
  content_type: string | null;
  name: string | null;
  size_bytes: number | null;
  download_url?: string | null;
}

interface Job {
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
    attachments?: JobAttachment[];
    rfq_modified_after_bid?: boolean;
  } | null;
  rfq_attachments?: JobAttachment[];
  job_status: "new" | "pending" | "won" | "lost";
  rfq_deleted?: boolean;
}

interface OrgData {
  id: string;
  name: string;
  description: string | null;
  address: string | null;
  icon_url: string | null;
  website_url: string | null;
  yelp_url: string | null;
  google_reviews_url: string | null;
  avg_rating: number | null;
  service_lat: number | null;
  service_lng: number | null;
  service_radius_miles: number | null;
  banner_image_url: string | null;
  business_hours: Record<string, string>;
  role: string;
}

interface GalleryImage {
  id: string;
  image_type: string;
  image_url: string | null;
  before_image_url: string | null;
  caption: string | null;
  sort_order: number;
  media_type: string;
  album_id: string | null;
  album_title: string | null;
}

interface Album {
  id: string;
  title: string;
  description: string | null;
  service_id: string | null;
  rfq_id: string | null;
  created_at: string | null;
  service_name: string | null;
}

interface Member {
  id: string;
  name: string | null;
  email: string;
  icon_url: string | null;
  role: string;
  invite_status: string;
}

interface Service {
  id: string;
  name: string;
  description?: string | null;
}

interface OrgService {
  id: string;
  name: string;
  years_experience: number | null;
}

type Tab = "inbox" | "jobs" | "settings" | "gallery" | "members" | "services";

export default function OrgDashboard() {
  const [org, setOrg] = useState<OrgData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [params] = useSearchParams();
  const tab = (params.get("tab") || "jobs") as Tab;

  useEffect(() => {
    apiFetch<OrgData>("/api/org")
      .then(setOrg)
      .catch((err) => setError(err.message || "Not a member of any organization"))
      .finally(() => setLoading(false));
  }, []);

  if (loading) {
    return <Layout><div className="page-loading"><div className="spinner" /></div></Layout>;
  }

  if (error || !org) {
    return (
      <Layout>
        <div className="empty-state">
          <h3>No Organization</h3>
          <p>{error || "You are not a member of any contractor organization."}</p>
        </div>
      </Layout>
    );
  }

  if (tab === "inbox") return <Inbox />;
  if (tab === "jobs") return <Layout><OrgJobsWorkspace /></Layout>;

  return (
    <Layout>
      <div style={{ maxWidth: 800, margin: "0 auto", padding: "32px 24px 60px" }}>
        {tab === "settings" && <OrgSettings org={org} onUpdate={setOrg} />}
        {tab === "gallery" && <OrgGallery />}
        {tab === "members" && <OrgMembers />}
        {tab === "services" && <OrgServices />}
      </div>
    </Layout>
  );
}


const JOB_STATUSES = ["all", "new", "pending", "won", "lost"] as const;
type JobStatusFilter = typeof JOB_STATUSES[number];

interface ContractorView {
  rfq_id: string;
  title: string;
  address: string | null;
  job_description: string | null;
  project_scope: string | null;
  rooms: {
    scan_id: string;
    room_label: string;
    floor_area_sqft: number | null;
    wall_area_sqft: number | null;
    ceiling_height_ft: number | null;
    perimeter_linear_ft: number | null;
    room_polygon_ft: number[][] | null;
    scope: { items?: string[]; notes?: string } | null;
  }[];
}

function fmtPriceCents(cents: number): string {
  return "$" + (cents / 100).toLocaleString("en-US", { minimumFractionDigits: 0 });
}

function fmtJobDate(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

function formatJobLabel(key: string): string {
  return key.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

function OrgJobsWorkspace() {
  const [jobs, setJobs] = useState<Job[]>([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState<JobStatusFilter>("all");
  const [selectedRfqId, setSelectedRfqId] = useState<string | null>(null);
  const [scanView, setScanView] = useState<"floorplan" | "bev">("floorplan");

  useEffect(() => {
    apiFetch<{ jobs: Job[] }>("/api/org/jobs")
      .then((data) => {
        setJobs(data.jobs);
        // Auto-select the first job on desktop only; on mobile we want the
        // user to land on the list and tap in.
        if (data.jobs.length > 0 && typeof window !== "undefined" && window.innerWidth > 820) {
          setSelectedRfqId(data.jobs[0].rfq_id);
        }
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const counts = useMemo(() => ({
    all: jobs.length,
    new: jobs.filter((j) => j.job_status === "new").length,
    pending: jobs.filter((j) => j.job_status === "pending").length,
    won: jobs.filter((j) => j.job_status === "won").length,
    lost: jobs.filter((j) => j.job_status === "lost").length,
  }), [jobs]);

  const filtered = useMemo(
    () => filter === "all" ? jobs : jobs.filter((j) => j.job_status === filter),
    [jobs, filter],
  );

  // Honor an explicit null selectedRfqId (mobile back, or no selection yet).
  // On desktop we want a fallback so the right panes aren't empty.
  const selectedJob = selectedRfqId === null
    ? null
    : jobs.find((j) => j.rfq_id === selectedRfqId) || filtered[0] || null;

  if (loading) return <div className="page-loading"><div className="spinner" /></div>;

  function handleJobUpdated(rfqId: string, patch: Partial<Job>) {
    setJobs((prev) => prev.map((j) => j.rfq_id === rfqId ? { ...j, ...patch } : j));
  }

  return (
    <>
      <div className={`ojw ${selectedJob ? "ojw-has-selection" : ""}`}>
        <aside className="ojw-list">
          <div className="ojw-list-head">
            <h1 className="ojw-title">Jobs</h1>
            <div className="ojw-chips">
              {JOB_STATUSES.map((s) => (
                <button
                  key={s}
                  type="button"
                  className={`ojw-chip ${filter === s ? "is-active" : ""}`}
                  onClick={() => setFilter(s)}
                >
                  {s === "all" ? "All" : s[0].toUpperCase() + s.slice(1)}
                  <span className="ojw-chip-count">{counts[s]}</span>
                </button>
              ))}
            </div>
          </div>

          {filtered.length === 0 ? (
            <div className="ojw-empty">
              <strong>{filter === "all" ? "No jobs yet" : `No ${filter} jobs`}</strong>
              <div>Jobs appear here as homeowners post projects matching your services.</div>
            </div>
          ) : (
            <div className="ojw-rows">
              {filtered.map((job) => (
                <JobRow
                  key={`${job.rfq_id}-${job.job_status}`}
                  job={job}
                  active={job.rfq_id === selectedJob?.rfq_id}
                  onClick={() => setSelectedRfqId(job.rfq_id)}
                />
              ))}
            </div>
          )}
        </aside>

        {selectedJob ? (
          <>
            <JobReviewPane
              key={`review-${selectedJob.rfq_id}`}
              job={selectedJob}
              scanView={scanView}
              setScanView={setScanView}
              onBack={() => setSelectedRfqId(null)}
            />
            <JobBidPane
              key={`bid-${selectedJob.rfq_id}`}
              job={selectedJob}
              onUpdate={handleJobUpdated}
            />
          </>
        ) : (
          <div className="ojw-nosel">
            <div>
              <strong>Select a job to review</strong>
              <div>Pick one from the list to view the 3D scan and submit a bid.</div>
            </div>
          </div>
        )}
      </div>
      <style>{OJW_CSS}</style>
    </>
  );
}

function JobRow({ job, active, onClick }: { job: Job; active: boolean; onClick: () => void }) {
  const tone =
    job.job_status === "new"     ? "ojw-tint-new" :
    job.job_status === "pending" ? "ojw-tint-pending" :
    job.job_status === "won"     ? "ojw-tint-won" : "ojw-tint-lost";
  const label = job.job_status[0].toUpperCase() + job.job_status.slice(1);
  return (
    <button type="button" className={`ojw-row ${active ? "is-active" : ""}`} onClick={onClick}>
      <div className="ojw-row-main">
        <div className="ojw-row-title">{job.title}</div>
        {job.description && <div className="ojw-row-desc">{job.description}</div>}
        {job.address && (
          <div className="ojw-row-addr">
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M12 22s7-7.5 7-13a7 7 0 00-14 0c0 5.5 7 13 7 13z" /><circle cx="12" cy="9" r="2.5" />
            </svg>
            {job.address}
          </div>
        )}
        <span className={`ojw-row-tint ${tone}`}>{label}</span>
      </div>
      {job.bid ? (
        <div className="ojw-row-price">{fmtPriceCents(job.bid.price_cents)}</div>
      ) : (
        <div className="ojw-row-view">View →</div>
      )}
    </button>
  );
}

function JobReviewPane({ job, scanView, setScanView, onBack }: { job: Job; scanView: "floorplan" | "bev"; setScanView: (v: "floorplan" | "bev") => void; onBack: () => void }) {
  const [view, setView] = useState<ContractorView | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    fetch(`/api/rfqs/${job.rfq_id}/contractor-view`)
      .then((r) => r.ok ? r.json() : null)
      .then((d) => { if (!cancelled && d) setView(d); })
      .catch(() => {})
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [job.rfq_id]);

  const totalFloor = view?.rooms.reduce((s, r) => s + (r.floor_area_sqft ?? 0), 0) ?? 0;
  const totalWall  = view?.rooms.reduce((s, r) => s + (r.wall_area_sqft ?? 0), 0) ?? 0;
  const heights    = (view?.rooms ?? []).map((r) => r.ceiling_height_ft).filter((v): v is number => v != null);
  const avgCeiling = heights.length ? heights.reduce((s, v) => s + v, 0) / heights.length : null;
  const perim      = view?.rooms.reduce((s, r) => s + (r.perimeter_linear_ft ?? 0), 0) ?? 0;
  const hasFloorplan = view?.rooms.some((r) => r.room_polygon_ft && r.room_polygon_ft.length >= 3);

  return (
    <section className="ojw-review">
      <button type="button" className="ojw-back" onClick={onBack} aria-label="Back to jobs">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M15 18l-6-6 6-6" />
        </svg>
        Back
      </button>
      <div className="ojw-review-eyebrow">
        {job.address || "Scope review"}
      </div>
      <h2 className="ojw-review-title">{job.title}</h2>

      <div className="ojw-review-card">
        <div className="ojw-review-tabs">
          <button type="button" className={`ojw-tab ${scanView === "floorplan" ? "is-active" : ""}`} onClick={() => setScanView("floorplan")}>
            Floor plan
          </button>
          <button type="button" className={`ojw-tab ${scanView === "bev" ? "is-active" : ""}`} onClick={() => setScanView("bev")}>
            Bird's eye
          </button>
        </div>
        <div className="ojw-review-viewer">
          {loading ? (
            <div className="ojw-review-empty">Loading scan…</div>
          ) : scanView === "floorplan" ? (
            hasFloorplan && view ? (
              <FloorPlan rooms={view.rooms} height={340} />
            ) : (
              <div className="ojw-review-empty">No floor plan available.</div>
            )
          ) : (
            <iframe
              title="Bird's eye"
              src={`/embed/scan/${job.rfq_id}?view=bev&measurements=on`}
              className="ojw-review-iframe"
            />
          )}
        </div>
      </div>

      {(view?.project_scope || view?.job_description || job.description) && (
        <>
          <div className="ojw-section-label">Scope from customer</div>
          <div className="ojw-review-scope">
            {view?.project_scope || view?.job_description || job.description}
            {view && view.rooms.some((r) => r.scope?.items?.length) && (
              <div className="ojw-scope-rooms">
                {view.rooms.filter((r) => r.scope?.items?.length).map((r) => (
                  <div key={r.scan_id} className="ojw-scope-room">
                    <div className="ojw-scope-room-name">{r.room_label || "Room"}</div>
                    <div className="ojw-scope-room-items">
                      {r.scope!.items!.map((it) => (
                        <span key={it} className="ojw-scope-chip">{formatJobLabel(it)}</span>
                      ))}
                    </div>
                    {r.scope?.notes && <div className="ojw-scope-note">{r.scope.notes}</div>}
                  </div>
                ))}
              </div>
            )}
          </div>
        </>
      )}

      {view && view.rooms.length > 0 && (
        <div className="ojw-metrics">
          <Metric label="Floor"     value={totalFloor ? totalFloor.toLocaleString() : "—"} unit="sqft" />
          <Metric label="Wall"      value={totalWall ? totalWall.toLocaleString() : "—"}   unit="sqft" />
          <Metric label="Ceiling"   value={avgCeiling ? avgCeiling.toFixed(1) : "—"}        unit="ft" />
          <Metric label="Perimeter" value={perim ? perim.toFixed(1) : "—"}                 unit="ft" />
        </div>
      )}
    </section>
  );
}

function BidPdfCard({ url }: { url: string }) {
  const [sizeLabel, setSizeLabel] = useState<string | null>(null);
  const fileName = decodeURIComponent(url.split("?")[0].split("/").pop() || "Project breakdown.pdf");

  useEffect(() => {
    let cancelled = false;
    fetch(url, { method: "HEAD" })
      .then((r) => {
        const bytes = parseInt(r.headers.get("content-length") || "0", 10);
        if (cancelled || !bytes) return;
        const kb = bytes / 1024;
        setSizeLabel(kb >= 1024 ? `${(kb / 1024).toFixed(1)} MB` : `${Math.round(kb)} KB`);
      })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [url]);

  return (
    <div className="cbf-file-card">
      <div className="cbf-file-icon" aria-hidden="true">PDF</div>
      <div className="cbf-file-body">
        <div className="cbf-file-name">{fileName}</div>
        <div className="cbf-file-meta">{sizeLabel ? `${sizeLabel} · ` : ""}Attached to your bid</div>
      </div>
      <a href={url} target="_blank" rel="noopener noreferrer" className="cbf-file-replace">
        View
      </a>
    </div>
  );
}

function Metric({ label, value, unit }: { label: string; value: string; unit: string }) {
  return (
    <div className="ojw-metric">
      <div className="ojw-metric-label">{label}</div>
      <div className="ojw-metric-value">{value} <span className="ojw-metric-unit">{unit}</span></div>
    </div>
  );
}

function JobBidPane({ job, onUpdate }: { job: Job; onUpdate: (rfqId: string, patch: Partial<Job>) => void }) {
  const [editing, setEditing] = useState(false);
  const hasBid = !!job.bid;
  const canUpdate = hasBid && job.job_status === "pending" && !job.rfq_deleted;
  const statusTone = job.job_status === "won"  ? "ojw-tint-won"
                   : job.job_status === "lost" ? "ojw-tint-lost"
                   : "ojw-tint-pending";
  const parsed = parseBidDescription(job.bid?.description);

  return (
    <aside className="ojw-bid">
      <div className="ojw-section-label">
        {editing ? "Update bid" : hasBid ? "Your quote" : "Submit bid"}
      </div>
      <div className="ojw-bid-title">Your proposal</div>

      {job.rfq_deleted && (
        <div className="ojw-alert ojw-alert-danger">
          <strong>Project cancelled</strong>
          <div>The homeowner has removed this project from the platform.</div>
        </div>
      )}

      {job.bid?.rfq_modified_after_bid && !job.rfq_deleted && (
        <div className="ojw-alert ojw-alert-warn">
          <strong>Project updated</strong>
          <div>The homeowner modified this project after you submitted. Review the changes.</div>
        </div>
      )}

      {editing && hasBid ? (
        <ContractorBidForm
          rfqId={job.rfq_id}
          bidId={job.bid!.id}
          initial={{
            price_cents: job.bid!.price_cents,
            timeline: parsed.timeline,
            start: parsed.start,
            note: parsed.note,
            pdf_url: job.bid!.pdf_url ?? null,
            attachments: job.bid!.attachments,
          }}
          submitLabel="Update bid"
          onCancel={() => setEditing(false)}
          onSubmitted={(bid) => {
            setEditing(false);
            onUpdate(job.rfq_id, {
              job_status: "pending",
              bid: {
                ...job.bid!,
                id: bid.id,
                price_cents: bid.price_cents,
                status: "pending",
                received_at: new Date().toISOString(),
                description: bid.description,
                rfq_modified_after_bid: false,
              },
            });
          }}
        />
      ) : hasBid ? (
        <>
          <div className="ojw-total">
            <div className="ojw-total-label">Total</div>
            <div className="ojw-total-value">{fmtPriceCents(job.bid!.price_cents)}</div>
            <span className={`ojw-row-tint ${statusTone}`} style={{ alignSelf: "flex-start" }}>
              {job.job_status[0].toUpperCase() + job.job_status.slice(1)}
            </span>
          </div>

          {(parsed.timeline || parsed.start) && (
            <div className="ojw-bid-timeline">
              {parsed.timeline && <span><strong>Timeline:</strong> {parsed.timeline}</span>}
              {parsed.timeline && parsed.start && <span className="ojw-bid-timeline-sep">·</span>}
              {parsed.start && <span><strong>Start:</strong> {parsed.start}</span>}
            </div>
          )}

          {job.bid!.received_at && (
            <div className="ojw-bid-meta">Submitted {fmtJobDate(job.bid!.received_at)}</div>
          )}

          {parsed.note && (
            <div className="ojw-bid-desc">{parsed.note}</div>
          )}

          {(() => {
            // Combine RFQ-level media (anything the homeowner shared about the
            // project) with images on the bid itself. Dedupe by blob_path so
            // chat-originated attachments that exist in both don't double up.
            const combined: JobAttachment[] = [];
            const seen = new Set<string>();
            for (const a of [...(job.rfq_attachments ?? []), ...(job.bid!.attachments ?? [])]) {
              if (!a?.blob_path || seen.has(a.blob_path)) continue;
              seen.add(a.blob_path);
              combined.push(a);
            }
            const visualCount = combined.filter((a) => (a.content_type || "").startsWith("image/")).length;
            if (!visualCount) return null;
            return (
              <>
                <div className="ojw-section-label" style={{ marginTop: 18 }}>Project media</div>
                <PhotosCarousel attachments={combined as CarouselAttachment[]} />
              </>
            );
          })()}

          {job.bid!.pdf_url && (
            <>
              <div className="ojw-section-label" style={{ marginTop: 18 }}>Project breakdown PDF</div>
              <BidPdfCard url={job.bid!.pdf_url} />
            </>
          )}

          {canUpdate && (
            <button type="button" className="ojw-bid-btn" style={{ marginTop: 18 }} onClick={() => setEditing(true)}>
              Update bid
            </button>
          )}
        </>
      ) : job.rfq_deleted ? (
        <div className="ojw-bid-placeholder">Project cancelled. Bidding is disabled.</div>
      ) : (
        <ContractorBidForm
          rfqId={job.rfq_id}
          onSubmitted={(bid) => {
            onUpdate(job.rfq_id, {
              job_status: "pending",
              bid: {
                id: bid.id,
                price_cents: bid.price_cents,
                status: "pending",
                received_at: new Date().toISOString(),
                description: bid.description,
              },
            });
          }}
        />
      )}
    </aside>
  );
}

const OJW_CSS = `
.ojw {
  display: grid; grid-template-columns: 340px 1fr 360px;
  height: calc(100dvh - 56px); background: var(--q-canvas); overflow: hidden;
}
@media (max-width: 1100px) {
  .ojw { grid-template-columns: 300px 1fr 320px; }
}
/* Mobile: single column, list OR detail (review stacked over bid). */
@media (max-width: 820px) {
  .ojw {
    display: flex; flex-direction: column; height: calc(100dvh - 56px);
  }
  .ojw-list { flex: 1; }
  .ojw-has-selection .ojw-list { display: none; }
  .ojw:not(.ojw-has-selection) .ojw-review,
  .ojw:not(.ojw-has-selection) .ojw-bid { display: none; }
  .ojw:not(.ojw-has-selection) .ojw-nosel { display: none; }
  /* Stack review above bid inside a scrollable flow. */
  .ojw-review {
    padding: 16px 16px 24px; overflow: visible; flex: none;
    border-right: none;
  }
  .ojw-bid {
    border-left: none; border-top: 0.5px solid var(--q-hairline);
    padding: 20px 16px 28px; overflow: visible; flex: none;
  }
  .ojw-has-selection {
    overflow-y: auto;
  }
}

.ojw-back {
  display: none; align-items: center; gap: 6px;
  background: transparent; border: none; cursor: pointer;
  color: var(--q-ink-soft); font-size: 13px; font-weight: 600; font-family: inherit;
  padding: 6px 10px; border-radius: 8px; margin-bottom: 10px;
}
.ojw-back:hover { background: var(--q-surface-muted); color: var(--q-ink); }
@media (max-width: 820px) { .ojw-back { display: inline-flex; } }

.ojw-list {
  border-right: 0.5px solid var(--q-hairline); background: var(--q-surface);
  overflow-y: auto; display: flex; flex-direction: column;
}
.ojw-list-head { padding: 22px 22px 12px; border-bottom: 0.5px solid var(--q-divider); }
.ojw-title { font-size: 26px; font-weight: 700; letter-spacing: -0.8px; margin: 0 0 14px; }
.ojw-chips { display: flex; gap: 4px; flex-wrap: wrap; }
.ojw-chip {
  border: none; background: transparent; color: var(--q-ink-soft);
  padding: 5px 11px; border-radius: var(--q-radius-pill); font-size: 12px; font-weight: 600;
  font-family: inherit; cursor: pointer; box-shadow: inset 0 0 0 0.5px var(--q-hairline);
  display: inline-flex; align-items: center; gap: 5px;
}
.ojw-chip.is-active { background: var(--q-primary); color: var(--q-primary-ink); box-shadow: none; }
.ojw-chip-count { opacity: 0.7; font-weight: 500; }
.ojw-chip.is-active .ojw-chip-count { opacity: 0.85; }

.ojw-rows { display: flex; flex-direction: column; }
.ojw-row {
  display: flex; gap: 12px; padding: 14px 22px; border: none; background: transparent;
  font-family: inherit; text-align: left; cursor: pointer; color: var(--q-ink);
  border-top: 0.5px solid var(--q-divider); border-left: 3px solid transparent;
  transition: background 0.12s;
  align-items: flex-start; justify-content: space-between;
}
.ojw-row:hover { background: var(--q-surface-muted); }
.ojw-row.is-active { background: var(--q-primary-soft); border-left-color: var(--q-primary); }
.ojw-row-main { flex: 1; min-width: 0; }
.ojw-row-title {
  font-size: 14px; font-weight: 700; letter-spacing: -0.2px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.ojw-row-desc {
  font-size: 12px; color: var(--q-ink-soft); margin-top: 2px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.ojw-row-addr {
  font-size: 11px; color: var(--q-ink-muted); margin-top: 4px;
  display: flex; align-items: center; gap: 4px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.ojw-row-tint {
  display: inline-block; padding: 2px 8px; border-radius: var(--q-radius-pill);
  font-size: 10px; font-weight: 700; letter-spacing: 0.3px; text-transform: uppercase;
  margin-top: 7px;
}
.ojw-tint-new     { background: #DCE8FF; color: #1E3FA5; }
.ojw-tint-pending { background: #FFEAC2; color: #8A5A00; }
.ojw-tint-won     { background: var(--q-primary-soft); color: var(--q-primary); }
.ojw-tint-lost    { background: #F1D6D6; color: #8A2A2A; }

.ojw-row-price {
  font-size: 15px; font-weight: 700; letter-spacing: -0.3px; white-space: nowrap;
  font-variant-numeric: tabular-nums;
}
.ojw-row-view {
  font-size: 12px; color: var(--q-primary); font-weight: 600; white-space: nowrap;
}

.ojw-empty, .ojw-nosel {
  padding: 40px 24px; text-align: center; color: var(--q-ink-muted); font-size: 13px;
}
.ojw-empty strong, .ojw-nosel strong { display: block; color: var(--q-ink); font-size: 15px; margin-bottom: 6px; }
.ojw-nosel { display: flex; align-items: center; justify-content: center; grid-column: 2 / -1; }

/* Review pane (center) */
.ojw-review { overflow-y: auto; padding: 24px 32px 48px; }
.ojw-review-eyebrow {
  font-size: 11px; font-weight: 700; color: var(--q-ink-muted);
  letter-spacing: 0.5px; text-transform: uppercase;
}
.ojw-review-title {
  font-size: 32px; font-weight: 700; letter-spacing: -0.8px;
  margin: 4px 0 16px;
}

.ojw-review-card {
  background: var(--q-surface); border-radius: 16px; padding: 18px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
}
.ojw-review-tabs {
  display: inline-flex; align-self: flex-start; gap: 2px; padding: 3px;
  background: var(--q-surface-muted); border-radius: var(--q-radius-pill);
  margin-bottom: 12px;
}
.ojw-tab {
  border: none; background: transparent; padding: 5px 12px;
  font-size: 13px; font-weight: 600; font-family: inherit; cursor: pointer;
  color: var(--q-ink-muted); border-radius: var(--q-radius-pill);
}
.ojw-tab:hover { color: var(--q-ink); }
.ojw-tab.is-active { background: var(--q-surface); color: var(--q-ink); box-shadow: 0 1px 2px rgba(0,0,0,0.04); }

.ojw-review-viewer {
  aspect-ratio: 16 / 9; border-radius: 12px; overflow: hidden;
  background: var(--q-scan-accent-soft); position: relative;
}
.ojw-review-viewer > div { height: 100% !important; background: transparent !important; border: none !important; border-radius: 0 !important; }
.ojw-review-viewer canvas { display: block; width: 100% !important; height: 100% !important; }
.ojw-review-iframe { width: 100%; height: 100%; border: 0; background: #000; }
.ojw-review-empty {
  height: 100%; display: flex; align-items: center; justify-content: center;
  color: var(--q-ink-muted); font-size: 13px;
}

.ojw-section-label {
  font-size: 12px; font-weight: 700; color: var(--q-ink-muted);
  letter-spacing: 0.5px; text-transform: uppercase; margin: 20px 0 8px;
}
.ojw-review-scope {
  background: var(--q-surface); border-radius: 14px; padding: 18px;
  font-size: 15px; color: var(--q-ink-soft); line-height: 1.5;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline); white-space: pre-wrap;
}
.ojw-scope-rooms { display: flex; flex-direction: column; gap: 14px; margin-top: 14px; padding-top: 14px; border-top: 0.5px solid var(--q-divider); }
.ojw-scope-room-name { font-size: 13px; font-weight: 700; color: var(--q-ink); margin-bottom: 6px; }
.ojw-scope-room-items { display: flex; flex-wrap: wrap; gap: 6px; }
.ojw-scope-chip {
  display: inline-block; font-size: 12px; font-weight: 600; padding: 3px 10px;
  border-radius: var(--q-radius-sm); background: var(--q-primary-soft); color: var(--q-primary);
}
.ojw-scope-note { font-size: 13px; color: var(--q-ink-muted); font-style: italic; margin-top: 8px; }

.ojw-metrics {
  display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-top: 16px;
}
.ojw-metric {
  background: var(--q-surface); border-radius: 12px; padding: 14px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
}
.ojw-metric-label {
  font-size: 11px; font-weight: 700; color: var(--q-ink-muted);
  letter-spacing: 0.3px; text-transform: uppercase;
}
.ojw-metric-value { font-size: 22px; font-weight: 700; letter-spacing: -0.5px; margin-top: 2px; }
.ojw-metric-unit  { font-size: 12px; color: var(--q-ink-muted); font-weight: 500; }

/* Bid pane (right) */
.ojw-bid {
  border-left: 0.5px solid var(--q-hairline); background: var(--q-surface);
  overflow-y: auto; padding: 24px;
}
.ojw-bid-title { font-size: 22px; font-weight: 700; letter-spacing: -0.5px; margin: 2px 0 18px; }
.ojw-bid-placeholder {
  font-size: 13px; color: var(--q-ink-muted); margin-bottom: 16px; line-height: 1.5;
}
.ojw-bid-btn {
  display: block; width: 100%; padding: 12px 16px; border: none;
  background: var(--q-primary); color: var(--q-primary-ink);
  font-size: 15px; font-weight: 600; font-family: inherit;
  border-radius: var(--q-radius-md); cursor: pointer;
  transition: filter 0.15s;
}
.ojw-bid-btn:hover { filter: brightness(0.92); }
.ojw-bid-btn:disabled { opacity: 0.5; cursor: not-allowed; }

.ojw-bid-timeline {
  display: flex; gap: 6px; align-items: center; flex-wrap: wrap;
  font-size: 13px; color: var(--q-ink-soft); margin-bottom: 10px;
}
.ojw-bid-timeline strong { color: var(--q-ink-muted); font-weight: 600; letter-spacing: 0.3px; text-transform: uppercase; font-size: 11px; margin-right: 4px; }
.ojw-bid-timeline-sep { color: var(--q-ink-dim); }

.ojw-total {
  background: var(--q-surface-muted); border-radius: 12px; padding: 14px;
  display: flex; flex-direction: column; gap: 4px; margin-bottom: 14px;
}
.ojw-total-label { font-size: 12px; font-weight: 600; color: var(--q-ink-muted); }
.ojw-total-value { font-size: 28px; font-weight: 700; letter-spacing: -0.8px; font-variant-numeric: tabular-nums; }
.ojw-bid-meta { font-size: 12px; color: var(--q-ink-muted); margin-bottom: 10px; }
.ojw-bid-desc {
  font-size: 13px; color: var(--q-ink-soft); line-height: 1.5; white-space: pre-wrap;
  padding-top: 12px; border-top: 0.5px solid var(--q-divider); margin-top: 4px;
}
/* PDF file card — mirrors the upload card in ContractorBidForm so the
   submitted-bid state shows the same visual treatment with a View action. */
.cbf-file-card {
  display: flex; align-items: center; gap: 12px;
  background: var(--q-surface-muted); border-radius: 12px; padding: 12px 14px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
}
.cbf-file-icon {
  width: 40px; height: 48px; border-radius: 6px;
  background: #C8342C; color: #fff;
  display: flex; align-items: center; justify-content: center;
  font-size: 11px; font-weight: 800; letter-spacing: 0.5px; flex-shrink: 0;
  box-shadow: 0 1px 2px rgba(0,0,0,0.15);
}
.cbf-file-body { flex: 1; min-width: 0; }
.cbf-file-name {
  font-size: 13px; font-weight: 600; color: var(--q-ink);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.cbf-file-meta { font-size: 11px; color: var(--q-ink-muted); margin-top: 2px; }
.cbf-file-replace {
  padding: 6px 12px; font-size: 12px; font-weight: 600; font-family: inherit;
  color: var(--q-ink); background: var(--q-surface); border-radius: 8px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
  cursor: pointer; white-space: nowrap; text-decoration: none;
}
.cbf-file-replace:hover { background: var(--q-canvas); text-decoration: none; }

.ojw-alert {
  padding: 12px; border-radius: var(--q-radius-md); margin-bottom: 14px;
  font-size: 13px; line-height: 1.4;
}
.ojw-alert strong { display: block; font-weight: 700; margin-bottom: 2px; }
.ojw-alert-danger { background: #FEEFEF; color: #8A2A2A; border: 1px solid #F1D6D6; }
.ojw-alert-warn   { background: #FFF8E8; color: #7A5500; border: 1px solid #FFE3A1; }
`;


const DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];

function OrgSettings({ org, onUpdate }: { org: OrgData; onUpdate: (o: OrgData) => void }) {
  const [name, setName] = useState(org.name);
  const [description, setDescription] = useState(org.description || "");
  const [address, setAddress] = useState(org.address || "");
  const [website, setWebsite] = useState(org.website_url || "");
  const [yelp, setYelp] = useState(org.yelp_url || "");
  const [google, setGoogle] = useState(org.google_reviews_url || "");
  const [radius, setRadius] = useState(String(org.service_radius_miles || ""));
  const [hours, setHours] = useState<Record<string, string>>(org.business_hours || {});
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [iconUrl, setIconUrl] = useState(org.icon_url);
  const [bannerUrl, setBannerUrl] = useState(org.banner_image_url);

  async function handleSave(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setMessage("");
    try {
      await apiFetch("/api/org", {
        method: "PUT",
        body: JSON.stringify({
          name, description, address,
          website_url: website, yelp_url: yelp, google_reviews_url: google,
          service_radius_miles: radius ? parseFloat(radius) : null,
          business_hours: hours,
        }),
      });
      const updated = await apiFetch<OrgData>("/api/org");
      onUpdate(updated);
      setMessage("Saved");
      setTimeout(() => setMessage(""), 2000);
    } catch {
      setMessage("Failed to save");
    } finally {
      setSaving(false);
    }
  }

  async function uploadImage(endpoint: string, file: File, onDone: (url: string) => void, saveField: string) {
    const fileType = file.type || "image/jpeg";
    const { upload_url, blob_path, content_type } = await apiFetch<{
      upload_url: string; blob_path: string; content_type: string;
    }>(`${endpoint}?content_type=${encodeURIComponent(fileType)}`);
    await fetch(upload_url, { method: "PUT", headers: { "Content-Type": content_type }, body: file });
    await apiFetch("/api/org", { method: "PUT", body: JSON.stringify({ [saveField]: blob_path }) });
    const updated = await apiFetch<OrgData>("/api/org");
    onDone(saveField === "icon_url" ? updated.icon_url! : updated.banner_image_url!);
    onUpdate(updated);
  }

  const fieldStyle = { marginBottom: 14 };
  const labelStyle = { display: "block" as const, fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 };

  return (
    <div>
      {/* Banner */}
      <div className="card" style={{ overflow: "hidden", marginBottom: 20 }}>
        <div style={{
          height: 140, background: bannerUrl
            ? `url(${bannerUrl}) center/cover no-repeat`
            : "var(--q-primary)",
          display: "flex", alignItems: "flex-end", justifyContent: "flex-end", padding: 12,
        }}>
          <label className="btn" style={{ fontSize: 12, padding: "4px 12px", cursor: "pointer", background: "rgba(255,255,255,0.9)" }}>
            Change Banner
            <input type="file" accept="image/*" style={{ display: "none" }}
              onChange={async (e) => {
                const f = e.target.files?.[0]; if (!f) return;
                try { await uploadImage("/api/org/banner-upload-url", f, setBannerUrl, "banner_image_url"); }
                catch { setMessage("Banner upload failed"); }
                e.target.value = "";
              }} />
          </label>
        </div>

        {/* Logo */}
        <div style={{ display: "flex", alignItems: "center", gap: 16, padding: "16px 24px" }}>
          <div style={{
            width: 72, height: 72, borderRadius: 12, background: "var(--color-info-bg)",
            display: "flex", alignItems: "center", justifyContent: "center",
            fontSize: 24, fontWeight: 700, color: "var(--color-primary)", overflow: "hidden", flexShrink: 0,
          }}>
            {iconUrl ? <img src={iconUrl} alt="" style={{ width: 72, height: 72, objectFit: "cover" }} /> : org.name[0].toUpperCase()}
          </div>
          <div>
            <label className="btn" style={{ fontSize: 13, padding: "6px 14px", cursor: "pointer" }}>
              Change Logo
              <input type="file" accept="image/*" style={{ display: "none" }}
                onChange={async (e) => {
                  const f = e.target.files?.[0]; if (!f) return;
                  try { await uploadImage("/api/org/icon-upload-url", f, setIconUrl, "icon_url"); }
                  catch { setMessage("Logo upload failed"); }
                  e.target.value = "";
                }} />
            </label>
            <p style={{ fontSize: 12, color: "var(--color-text-muted)", marginTop: 4 }}>JPG, PNG, or WebP</p>
          </div>
        </div>
      </div>

      {/* Profile form */}
      <div className="card" style={{ padding: 24, marginBottom: 20 }}>
        <h3 style={{ fontSize: 16, fontWeight: 700, marginBottom: 16 }}>Profile</h3>
        <form onSubmit={handleSave}>
          <div style={fieldStyle}>
            <label style={labelStyle}>Company Name</label>
            <input className="form-input" value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <div style={fieldStyle}>
            <label style={labelStyle}>About / Description</label>
            <textarea className="form-input" value={description} onChange={(e) => setDescription(e.target.value)} rows={4} style={{ resize: "vertical" }} />
          </div>
          <div style={fieldStyle}>
            <label style={labelStyle}>Website</label>
            <input className="form-input" value={website} onChange={(e) => setWebsite(e.target.value)} placeholder="https://..." />
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 14, ...fieldStyle }}>
            <div><label style={labelStyle}>Yelp URL</label><input className="form-input" value={yelp} onChange={(e) => setYelp(e.target.value)} placeholder="Yelp page" /></div>
            <div><label style={labelStyle}>Google Reviews URL</label><input className="form-input" value={google} onChange={(e) => setGoogle(e.target.value)} placeholder="Google reviews" /></div>
          </div>

          <h3 style={{ fontSize: 16, fontWeight: 700, margin: "24px 0 16px" }}>Location & Service Area</h3>
          <div style={{ display: "grid", gridTemplateColumns: "2fr 1fr", gap: 14, ...fieldStyle }}>
            <div><label style={labelStyle}>Address</label><AddressAutocomplete value={address} onChange={setAddress} placeholder="Business address" types={["address"]} /></div>
            <div><label style={labelStyle}>Job Radius (miles)</label><input className="form-input" type="number" value={radius} onChange={(e) => setRadius(e.target.value)} placeholder="e.g. 30" /></div>
          </div>

          <h3 style={{ fontSize: 16, fontWeight: 700, margin: "24px 0 16px" }}>Business Hours</h3>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, ...fieldStyle }}>
            {DAYS.map((day) => (
              <div key={day} style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{ width: 80, fontSize: 13, textTransform: "capitalize", color: "var(--color-text-secondary)" }}>{day}</span>
                <input className="form-input" value={hours[day] || ""} onChange={(e) => setHours({ ...hours, [day]: e.target.value })}
                  placeholder="e.g. 8AM - 5PM" style={{ flex: 1, padding: "6px 10px", fontSize: 13 }} />
              </div>
            ))}
          </div>

          <div style={{ display: "flex", alignItems: "center", gap: 12, marginTop: 8 }}>
            <button className="btn btn-primary" type="submit" disabled={saving}>{saving ? "Saving..." : "Save"}</button>
            {message && <span style={{ fontSize: 13, fontWeight: 600, color: message === "Saved" ? "var(--color-success)" : "var(--color-danger)" }}>{message}</span>}
          </div>

          <div style={{ marginTop: 12 }}>
            <a href={`/contractors/${org.id}`} target="_blank" style={{ fontSize: 13, fontWeight: 600 }}>
              View public profile &rarr;
            </a>
          </div>
        </form>
      </div>

      {/* Delete org */}
      <div style={{ borderTop: "1px solid var(--color-border-light)", marginTop: 24, paddingTop: 24 }}>
        <h3 style={{ fontSize: 14, fontWeight: 700, color: "var(--color-danger)", marginBottom: 8 }}>Danger Zone</h3>
        <p style={{ fontSize: 13, color: "var(--color-text-muted)", marginBottom: 12 }}>
          Permanently delete this organization and remove all members.
        </p>
        <button
          className="btn"
          style={{ color: "var(--color-danger)", borderColor: "var(--color-danger)" }}
          onClick={async () => {
            if (!confirm(`Delete "${org.name}"? This cannot be undone.`)) return;
            try {
              await apiFetch("/api/org", { method: "DELETE" });
              window.location.href = "/account";
            } catch (err: unknown) {
              alert((err as Error).message || "Failed to delete");
            }
          }}
        >
          Delete Organization
        </button>
      </div>
    </div>
  );
}


function OrgGallery() {
  const [media, setMedia] = useState<GalleryImage[]>([]);
  const [albums, setAlbums] = useState<Album[]>([]);
  const [services, setServices] = useState<Service[]>([]);
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [caption, setCaption] = useState("");
  const [uploadAlbumId, setUploadAlbumId] = useState<string>("");
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);
  const [uploadMsg, setUploadMsg] = useState("");

  // Album creation
  const [showNewAlbum, setShowNewAlbum] = useState(false);
  const [newAlbumTitle, setNewAlbumTitle] = useState("");
  const [newAlbumServiceId, setNewAlbumServiceId] = useState("");
  const [creatingAlbum, setCreatingAlbum] = useState(false);

  // Before/After upload
  const [showBA, setShowBA] = useState(false);
  const [baBeforeFile, setBaBeforeFile] = useState<File | null>(null);
  const [baAfterFile, setBaAfterFile] = useState<File | null>(null);
  const [baCaption, setBaCaption] = useState("");
  const [baAlbumId, setBaAlbumId] = useState("");
  const [baUploading, setBaUploading] = useState(false);

  // Filter
  const [filterAlbum, setFilterAlbum] = useState<string>("all");

  async function refresh() {
    const [galleryData, svcData] = await Promise.all([
      apiFetch<{ media: GalleryImage[]; albums: Album[] }>("/api/org/gallery"),
      apiFetch<{ services: Service[] }>("/api/services"),
    ]);
    setMedia(galleryData.media);
    setAlbums(galleryData.albums);
    setServices(svcData.services);
  }

  useEffect(() => {
    refresh().catch(() => {}).finally(() => setLoading(false));
  }, []);

  async function handleUpload(files: FileList) {
    setUploading(true);
    setUploadMsg("");
    const total = files.length;
    let uploaded = 0;
    let failed = 0;

    for (let i = 0; i < files.length; i++) {
      const file = files[i];
      setUploadMsg(`Uploading ${i + 1} of ${total}...`);
      try {
        const fileType = file.type || "image/jpeg";
        const isVideo = fileType.startsWith("video/");
        const { upload_url, blob_path, content_type } = await apiFetch<{
          upload_url: string; blob_path: string; image_id: string; content_type: string;
        }>(`/api/org/gallery/upload-url?content_type=${encodeURIComponent(fileType)}`);

        await fetch(upload_url, { method: "PUT", headers: { "Content-Type": content_type }, body: file });

        const gcsUrl = `https://storage.googleapis.com/roomscanalpha-scans/${blob_path}`;
        await apiFetch("/api/org/gallery", {
          method: "POST",
          body: JSON.stringify({
            image_url: gcsUrl,
            image_type: "single",
            caption: total === 1 ? (caption.trim() || null) : null,
            media_type: isVideo ? "video" : "image",
            album_id: uploadAlbumId || null,
          }),
        });
        uploaded++;
      } catch {
        failed++;
      }
    }

    await refresh();
    setCaption("");
    if (failed === 0) {
      setUploadMsg(`${uploaded} file${uploaded !== 1 ? "s" : ""} uploaded!`);
    } else {
      setUploadMsg(`${uploaded} uploaded, ${failed} failed`);
    }
    setTimeout(() => setUploadMsg(""), 3000);
    setUploading(false);
  }

  async function handleDelete(id: string) {
    await apiFetch(`/api/org/gallery/${id}`, { method: "DELETE" });
    setMedia(media.filter((m) => m.id !== id));
  }

  async function handleCreateAlbum(e: FormEvent) {
    e.preventDefault();
    if (!newAlbumTitle.trim()) return;
    setCreatingAlbum(true);
    try {
      await apiFetch("/api/org/albums", {
        method: "POST",
        body: JSON.stringify({
          title: newAlbumTitle.trim(),
          service_id: newAlbumServiceId || null,
        }),
      });
      await refresh();
      setNewAlbumTitle("");
      setNewAlbumServiceId("");
      setShowNewAlbum(false);
    } catch {}
    setCreatingAlbum(false);
  }

  async function handleBAUpload(e: FormEvent) {
    e.preventDefault();
    if (!baBeforeFile || !baAfterFile) return;
    setBaUploading(true);
    try {
      // Upload both files
      const [beforeUpload, afterUpload] = await Promise.all([
        apiFetch<{ upload_url: string; blob_path: string; content_type: string }>(
          `/api/org/gallery/upload-url?content_type=${encodeURIComponent(baBeforeFile.type || "image/jpeg")}`
        ),
        apiFetch<{ upload_url: string; blob_path: string; content_type: string }>(
          `/api/org/gallery/upload-url?content_type=${encodeURIComponent(baAfterFile.type || "image/jpeg")}`
        ),
      ]);
      await Promise.all([
        fetch(beforeUpload.upload_url, { method: "PUT", headers: { "Content-Type": beforeUpload.content_type }, body: baBeforeFile }),
        fetch(afterUpload.upload_url, { method: "PUT", headers: { "Content-Type": afterUpload.content_type }, body: baAfterFile }),
      ]);
      // Create gallery record with both URLs
      await apiFetch("/api/org/gallery", {
        method: "POST",
        body: JSON.stringify({
          image_url: afterUpload.blob_path,
          before_image_url: beforeUpload.blob_path,
          image_type: "before_after",
          caption: baCaption.trim() || null,
          media_type: "image",
          album_id: baAlbumId || null,
        }),
      });
      await refresh();
      setBaBeforeFile(null);
      setBaAfterFile(null);
      setBaCaption("");
      setBaAlbumId("");
      setShowBA(false);
    } catch {}
    setBaUploading(false);
  }

  async function handleDeleteAlbum(id: string) {
    if (!confirm("Delete this album? Media will be kept but unlinked.")) return;
    await apiFetch(`/api/org/albums/${id}`, { method: "DELETE" });
    await refresh();
  }

  if (loading) return <div className="page-loading"><div className="spinner" /></div>;

  const filtered = filterAlbum === "all"
    ? media
    : filterAlbum === "unlinked"
      ? media.filter((m) => !m.album_id)
      : media.filter((m) => m.album_id === filterAlbum);

  return (
    <div>
      {/* Upload form */}
      <div className="card" style={{ padding: 24, marginBottom: 20 }}>
        <h3 style={{ fontSize: 16, fontWeight: 700, marginBottom: 12 }}>Add Photo or Video</h3>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
          <div style={{ flex: 1, minWidth: 160 }}>
            <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>Caption</label>
            <input className="form-input" value={caption} onChange={(e) => setCaption(e.target.value)} placeholder="Optional caption" />
          </div>
          <div style={{ minWidth: 140 }}>
            <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>Album</label>
            <select className="form-input" value={uploadAlbumId} onChange={(e) => setUploadAlbumId(e.target.value)}>
              <option value="">No album</option>
              {albums.map((a) => <option key={a.id} value={a.id}>{a.title}</option>)}
            </select>
          </div>
          <label className="btn btn-primary" style={{ cursor: uploading ? "not-allowed" : "pointer", opacity: uploading ? 0.6 : 1 }}>
            {uploading ? "Uploading..." : "Choose Files"}
            <input type="file" accept="image/*,video/mp4,video/quicktime,video/webm" multiple style={{ display: "none" }} disabled={uploading}
              onChange={(e) => { const f = e.target.files; if (f && f.length) handleUpload(f); e.target.value = ""; }} />
          </label>
        </div>
        {uploadMsg && <p style={{ fontSize: 13, marginTop: 8, color: uploadMsg.includes("failed") ? "var(--color-danger)" : "var(--color-success)" }}>{uploadMsg}</p>}
      </div>

      {/* Albums section */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 12, flexWrap: "wrap", gap: 8 }}>
        <h3 style={{ fontSize: 16, fontWeight: 700 }}>Albums</h3>
        <div style={{ display: "flex", gap: 8 }}>
          <button className="btn" style={{ fontSize: 13, padding: "6px 14px" }} onClick={() => { setShowBA(!showBA); if (!showBA) setShowNewAlbum(false); }}>
            {showBA ? "Cancel" : "+ Before & After"}
          </button>
          <button className="btn" style={{ fontSize: 13, padding: "6px 14px" }} onClick={() => { setShowNewAlbum(!showNewAlbum); if (!showNewAlbum) setShowBA(false); }}>
            {showNewAlbum ? "Cancel" : "+ New Album"}
          </button>
        </div>
      </div>

      {showNewAlbum && (
        <form onSubmit={handleCreateAlbum} className="card" style={{ padding: 16, marginBottom: 16, display: "flex", gap: 8, flexWrap: "wrap" }}>
          <input className="form-input" value={newAlbumTitle} onChange={(e) => setNewAlbumTitle(e.target.value)}
            placeholder="Album title" style={{ flex: 1, minWidth: 160 }} />
          <select className="form-input" value={newAlbumServiceId} onChange={(e) => setNewAlbumServiceId(e.target.value)} style={{ width: 160 }}>
            <option value="">Service tag (optional)</option>
            {services.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
          <button className="btn btn-primary" type="submit" disabled={creatingAlbum || !newAlbumTitle.trim()}>
            {creatingAlbum ? "Creating..." : "Create"}
          </button>
        </form>
      )}

      {showBA && (
        <form onSubmit={handleBAUpload} className="card" style={{ padding: 16, marginBottom: 16 }}>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12, marginBottom: 12 }}>
            <div>
              <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>Before</label>
              <input type="file" accept="image/*" onChange={(e) => setBaBeforeFile(e.target.files?.[0] || null)}
                style={{ fontSize: 13, width: "100%" }} />
            </div>
            <div>
              <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>After</label>
              <input type="file" accept="image/*" onChange={(e) => setBaAfterFile(e.target.files?.[0] || null)}
                style={{ fontSize: 13, width: "100%" }} />
            </div>
          </div>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            <input className="form-input" value={baCaption} onChange={(e) => setBaCaption(e.target.value)}
              placeholder="Caption (optional)" style={{ flex: 1, minWidth: 140 }} />
            <select className="form-input" value={baAlbumId} onChange={(e) => setBaAlbumId(e.target.value)} style={{ width: 160 }}>
              <option value="">Album (optional)</option>
              {albums.map((a) => <option key={a.id} value={a.id}>{a.title}</option>)}
            </select>
            <button className="btn btn-primary" type="submit" disabled={baUploading || !baBeforeFile || !baAfterFile}>
              {baUploading ? "Uploading..." : "Upload"}
            </button>
          </div>
        </form>
      )}

      {albums.length > 0 && (
        <div style={{ display: "flex", gap: 8, marginBottom: 20, flexWrap: "wrap" }}>
          <button onClick={() => setFilterAlbum("all")}
            className={filterAlbum === "all" ? "btn btn-primary" : "btn"} style={{ fontSize: 12, padding: "4px 12px" }}>All</button>
          <button onClick={() => setFilterAlbum("unlinked")}
            className={filterAlbum === "unlinked" ? "btn btn-primary" : "btn"} style={{ fontSize: 12, padding: "4px 12px" }}>Unlinked</button>
          {albums.map((a) => (
            <div key={a.id} style={{ display: "flex", alignItems: "center", gap: 4 }}>
              <button onClick={() => setFilterAlbum(a.id)}
                className={filterAlbum === a.id ? "btn btn-primary" : "btn"} style={{ fontSize: 12, padding: "4px 12px" }}>
                {a.title}{a.service_name ? ` (${a.service_name})` : ""}
              </button>
              <button onClick={() => handleDeleteAlbum(a.id)}
                style={{ background: "none", border: "none", color: "var(--color-text-muted)", cursor: "pointer", fontSize: 14, padding: 0 }}>&times;</button>
            </div>
          ))}
        </div>
      )}

      {/* Media grid */}
      {filtered.length === 0 && (
        <div className="empty-state">
          <h3>No media{filterAlbum !== "all" ? " in this album" : " yet"}</h3>
          <p>Upload photos and videos of your work to showcase on your profile.</p>
        </div>
      )}

      {(() => {
        const viewable = filtered.filter((g) => g.image_url);
        const lbItems: LightboxItem[] = viewable.map((g) => ({
          url: g.image_url!,
          beforeUrl: g.before_image_url,
          type: g.before_image_url ? "before_after" : (g.media_type === "video" ? "video" : "image"),
        }));
        return (
          <>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(200px, 1fr))", gap: 16 }}>
              {viewable.map((item, i) => (
                <div key={item.id} className="card" style={{ overflow: "hidden" }}>
                  {item.media_type === "video" ? (
                    <div style={{ position: "relative", cursor: "pointer" }} onClick={() => setLightboxIndex(i)}>
                      <video src={item.image_url!} style={{ width: "100%", height: 160, objectFit: "cover", display: "block" }} muted preload="metadata" />
                      <div style={{
                        position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center",
                        background: "rgba(0,0,0,0.2)",
                      }}>
                        <div style={{ width: 40, height: 40, borderRadius: "50%", background: "rgba(0,0,0,0.6)",
                          display: "flex", alignItems: "center", justifyContent: "center" }}>
                          <span style={{ color: "#fff", fontSize: 18, marginLeft: 3 }}>&#9654;</span>
                        </div>
                      </div>
                    </div>
                  ) : (
                    <div style={{ position: "relative", cursor: "pointer" }} onClick={() => setLightboxIndex(i)}>
                      <img src={item.image_url!} alt={item.caption || ""}
                        style={{ width: "100%", height: 160, objectFit: "cover", display: "block" }} />
                      {item.before_image_url && (
                        <span style={{
                          position: "absolute", bottom: 6, left: 6, fontSize: 11, fontWeight: 700,
                          color: "#fff", background: "rgba(0,0,0,0.6)", padding: "2px 6px",
                          borderRadius: 4,
                        }}>B/A</span>
                      )}
                    </div>
                  )}
                  <div style={{ padding: 12 }}>
                    {item.caption && <p style={{ fontSize: 13, color: "var(--color-text-secondary)", marginBottom: 4 }}>{item.caption}</p>}
                    {item.album_title && (
                      <p style={{ fontSize: 11, color: "var(--color-primary)", marginBottom: 4 }}>{item.album_title}</p>
                    )}
                    <button onClick={() => handleDelete(item.id)}
                      style={{ fontSize: 12, fontWeight: 600, color: "var(--color-danger)", background: "none", border: "none", cursor: "pointer", fontFamily: "inherit" }}>
                      Delete
                    </button>
                  </div>
                </div>
              ))}
            </div>

            {lightboxIndex !== null && lbItems.length > 0 && (
              <Lightbox
                items={lbItems}
                startIndex={lightboxIndex}
                onClose={() => setLightboxIndex(null)}
                onIndexChange={(i) => setLightboxIndex(i)}
              />
            )}
          </>
        );
      })()}
    </div>
  );
}


function OrgMembers() {
  const [members, setMembers] = useState<Member[]>([]);
  const [loading, setLoading] = useState(true);
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteRole, setInviteRole] = useState("user");
  const [inviting, setInviting] = useState(false);
  const [inviteMsg, setInviteMsg] = useState("");

  useEffect(() => {
    apiFetch<{ members: Member[] }>("/api/org/members")
      .then((data) => setMembers(data.members))
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  async function handleInvite(e: FormEvent) {
    e.preventDefault();
    if (!inviteEmail.trim()) return;
    setInviting(true);
    setInviteMsg("");
    try {
      await apiFetch("/api/org/members/invite", {
        method: "POST",
        body: JSON.stringify({ email: inviteEmail.trim(), role: inviteRole }),
      });
      setInviteMsg(`Invite sent to ${inviteEmail}`);
      setInviteEmail("");
      // Refresh member list
      const data = await apiFetch<{ members: Member[] }>("/api/org/members");
      setMembers(data.members);
    } catch {
      setInviteMsg("Failed to send invite");
    } finally {
      setInviting(false);
    }
  }

  if (loading) return <div className="page-loading"><div className="spinner" /></div>;

  return (
    <div>
      {/* Invite form */}
      <div className="card" style={{ padding: 24, marginBottom: 20 }}>
        <h3 style={{ fontSize: 16, fontWeight: 700, marginBottom: 12 }}>Invite a Team Member</h3>
        <form onSubmit={handleInvite} style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <input
            className="form-input"
            type="email"
            value={inviteEmail}
            onChange={(e) => setInviteEmail(e.target.value)}
            placeholder="Email address"
            style={{ flex: 1, minWidth: 200 }}
          />
          <select
            className="form-input"
            value={inviteRole}
            onChange={(e) => setInviteRole(e.target.value)}
            style={{ width: 100 }}
          >
            <option value="user">Member</option>
            <option value="admin">Admin</option>
          </select>
          <button className="btn btn-primary" type="submit" disabled={inviting || !inviteEmail.trim()}>
            {inviting ? "Sending..." : "Invite"}
          </button>
        </form>
        {inviteMsg && (
          <p style={{ fontSize: 13, marginTop: 8, color: inviteMsg.includes("Failed") ? "var(--color-danger)" : "var(--color-success)" }}>
            {inviteMsg}
          </p>
        )}
      </div>

      {/* Member list */}
      <div className="card" style={{ padding: 24 }}>
        <h3 style={{ fontSize: 16, fontWeight: 700, marginBottom: 16 }}>Team Members</h3>
        {members.length === 0 && (
          <p style={{ fontSize: 14, color: "var(--color-text-muted)" }}>No members yet.</p>
        )}
        {members.map((m) => (
          <div key={m.id} style={{ display: "flex", alignItems: "center", gap: 12, padding: "10px 0", borderBottom: "1px solid var(--color-border-light)" }}>
            <div style={{
              width: 32, height: 32, borderRadius: "50%", background: "var(--color-info-bg)",
              display: "flex", alignItems: "center", justifyContent: "center",
              fontSize: 13, fontWeight: 700, color: "var(--color-primary)", overflow: "hidden",
            }}>
              {m.icon_url ? <img src={m.icon_url} alt="" style={{ width: 32, height: 32, objectFit: "cover" }} /> : (m.name || m.email)[0].toUpperCase()}
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 14, fontWeight: 600 }}>{m.name || m.email}</div>
              <div style={{ fontSize: 12, color: "var(--color-text-muted)" }}>{m.role} &middot; {m.invite_status}</div>
            </div>
            <button
              onClick={async () => {
                if (!confirm(`Remove ${m.name || m.email}?`)) return;
                try {
                  await apiFetch(`/api/org/members/${m.id}`, { method: "DELETE" });
                  setMembers(members.filter((x) => x.id !== m.id));
                } catch (err: unknown) {
                  alert((err as Error).message || "Failed to remove");
                }
              }}
              style={{
                fontSize: 12, fontWeight: 600, color: "var(--color-danger)",
                background: "none", border: "none", cursor: "pointer", fontFamily: "inherit",
              }}
            >
              Remove
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}


function OrgServices() {
  const [allServices, setAllServices] = useState<Service[]>([]);
  const [, setOrgServices] = useState<OrgService[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => {
    Promise.all([
      apiFetch<{ services: Service[] }>("/api/services"),
      apiFetch<{ services: OrgService[] }>("/api/org/services"),
    ])
      .then(([all, org]) => {
        setAllServices(all.services);
        setOrgServices(org.services);
        setSelected(new Set(org.services.map((s) => s.id)));
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  function toggle(id: string) {
    const next = new Set(selected);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setSelected(next);
  }

  async function handleSave() {
    setSaving(true);
    setMessage("");
    try {
      await apiFetch("/api/org/services", {
        method: "PUT",
        body: JSON.stringify({ service_ids: Array.from(selected) }),
      });
      setMessage("Saved");
      setTimeout(() => setMessage(""), 2000);
    } catch {
      setMessage("Failed to save");
    } finally {
      setSaving(false);
    }
  }

  if (loading) return <div className="page-loading"><div className="spinner" /></div>;

  return (
    <div className="card" style={{ padding: 24 }}>
      <h3 style={{ fontSize: 16, fontWeight: 700, marginBottom: 4 }}>Services You Offer</h3>
      <p style={{ fontSize: 13, color: "var(--color-text-muted)", marginBottom: 16 }}>
        Select the services your organization provides.
      </p>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(200px, 1fr))", gap: 8, marginBottom: 20 }}>
        {allServices.map((s) => (
          <label
            key={s.id}
            style={{
              display: "flex", alignItems: "center", gap: 8, padding: "10px 12px",
              border: `1px solid ${selected.has(s.id) ? "var(--color-primary)" : "var(--color-border)"}`,
              borderRadius: "var(--radius-md)", cursor: "pointer",
              background: selected.has(s.id) ? "var(--color-info-bg)" : "transparent",
              transition: "all 0.15s",
            }}
          >
            <input type="checkbox" checked={selected.has(s.id)} onChange={() => toggle(s.id)} style={{ accentColor: "var(--color-primary)" }} />
            <span style={{ fontSize: 14 }}>{s.name}</span>
          </label>
        ))}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <button className="btn btn-primary" onClick={handleSave} disabled={saving}>{saving ? "Saving..." : "Save Services"}</button>
        {message && <span style={{ fontSize: 13, fontWeight: 600, color: message === "Saved" ? "var(--color-success)" : "var(--color-danger)" }}>{message}</span>}
      </div>
    </div>
  );
}
