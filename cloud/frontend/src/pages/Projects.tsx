import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
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

interface RoomMini {
  scan_id: string;
  room_label: string;
  floor_area_sqft: number | null;
  room_polygon_ft: number[][] | null;
}

function fmtDate(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

type FilterKey = "all" | "awaiting" | "active" | "hired";

export default function Projects() {
  const [rfqs, setRfqs] = useState<RFQ[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [filter, setFilter] = useState<FilterKey>("all");

  useEffect(() => {
    apiFetch<{ rfqs: RFQ[] }>("/api/rfqs")
      .then((data) => setRfqs(data.rfqs))
      .catch((err) => setError(err.message || "Failed to load projects"))
      .finally(() => setLoading(false));
  }, []);

  const counts = useMemo(() => ({
    all: rfqs.length,
    awaiting: rfqs.filter((r) => (r.bid_count ?? 0) === 0 && r.status !== "completed").length,
    active: rfqs.filter((r) => (r.bid_count ?? 0) > 0 && r.status !== "completed").length,
    hired: rfqs.filter((r) => r.status === "completed").length,
  }), [rfqs]);

  const filtered = useMemo(() => rfqs.filter((r) => {
    switch (filter) {
      case "awaiting": return (r.bid_count ?? 0) === 0 && r.status !== "completed";
      case "active":   return (r.bid_count ?? 0) > 0 && r.status !== "completed";
      case "hired":    return r.status === "completed";
      default:         return true;
    }
  }), [rfqs, filter]);

  return (
    <Layout>
      <div className="pl-wrap">
        <header className="pl-header">
          <div>
            <div className="pl-eyebrow">Your projects</div>
            <h1 className="pl-title">Projects</h1>
          </div>
        </header>

        {loading && <div className="page-loading"><div className="spinner" /></div>}
        {!loading && error && (
          <div className="empty-state"><h3>Something went wrong</h3><p>{error}</p></div>
        )}
        {!loading && !error && rfqs.length === 0 && (
          <div className="empty-state">
            <h3>No projects yet</h3>
            <p>Projects are created when you scan a room with the Quoterra iOS app.</p>
          </div>
        )}

        {!loading && !error && rfqs.length > 0 && (
          <>
            <div className="pl-filter-row">
              <FilterChip active={filter === "all"}      onClick={() => setFilter("all")}      label="All"            count={counts.all} />
              <FilterChip active={filter === "awaiting"} onClick={() => setFilter("awaiting")} label="Awaiting bids"  count={counts.awaiting} />
              <FilterChip active={filter === "active"}   onClick={() => setFilter("active")}   label="Bids in"        count={counts.active} />
              <FilterChip active={filter === "hired"}    onClick={() => setFilter("hired")}    label="Hired"          count={counts.hired} />
            </div>

            {filtered.length === 0 ? (
              <div className="empty-state" style={{ padding: "40px 20px" }}>
                <h3>No projects in this view</h3>
                <p>Try another filter.</p>
              </div>
            ) : (
              <div className="pl-list">
                {filtered.map((rfq) => <ProjectCard key={rfq.id} rfq={rfq} />)}
              </div>
            )}
          </>
        )}
      </div>

      <style>{PL_CSS}</style>
    </Layout>
  );
}

function FilterChip({ active, onClick, label, count }: { active: boolean; onClick: () => void; label: string; count: number }) {
  return (
    <button type="button" onClick={onClick} className={`pl-chip ${active ? "is-active" : ""}`}>
      {label} <span className="pl-chip-count">{count}</span>
    </button>
  );
}

function ProjectCard({ rfq }: { rfq: RFQ }) {
  const [rooms, setRooms] = useState<RoomMini[] | null>(null);
  const [totalSqft, setTotalSqft] = useState<number>(0);

  useEffect(() => {
    let cancelled = false;
    fetch(`/api/rfqs/${rfq.id}/contractor-view`)
      .then((r) => r.ok ? r.json() : null)
      .then((data) => {
        if (cancelled || !data) return;
        setRooms(data.rooms);
        setTotalSqft(data.rooms.reduce((s: number, r: RoomMini) => s + (r.floor_area_sqft ?? 0), 0));
      })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [rfq.id]);

  const hasBids = (rfq.bid_count ?? 0) > 0;
  const hired = rfq.status === "completed";
  const statusLabel = hired ? "Hired" : hasBids ? "Bids in" : "Awaiting";
  const statusTone  = hired ? "pl-status-hired" : hasBids ? "pl-status-active" : "pl-status-wait";

  const hasFloorplan = rooms && rooms.some((r) => r.room_polygon_ft && r.room_polygon_ft.length >= 3);

  return (
    <Link to={`/projects/${rfq.id}`} className="pl-card">
      <div className="pl-thumb" aria-hidden="true">
        {hasFloorplan ? (
          <FloorPlan rooms={rooms!} height={64} />
        ) : (
          <div className="pl-thumb-empty">▦</div>
        )}
      </div>

      <div className="pl-body">
        <div className="pl-card-head">
          <div className="pl-card-title-wrap">
            <div className="pl-card-title-row">
              <h3 className="pl-card-title">{rfq.title || "Untitled project"}</h3>
              <span className={`pl-status ${statusTone}`}>{statusLabel}</span>
            </div>
            {rfq.address && <div className="pl-card-address">{rfq.address}</div>}
          </div>
        </div>

        <div className="pl-card-meta">
          {rfq.created_at && <span>Submitted {fmtDate(rfq.created_at)}</span>}
          {rooms != null && (
            <>
              <span className="pl-dot" />
              <span>{rooms.length} {rooms.length === 1 ? "room" : "rooms"}</span>
            </>
          )}
          {totalSqft > 0 && (
            <>
              <span className="pl-dot" />
              <span>{totalSqft.toLocaleString()} sqft</span>
            </>
          )}
          {hasBids && (
            <>
              <span className="pl-dot" />
              <span><strong>{rfq.bid_count}</strong> bid{rfq.bid_count !== 1 ? "s" : ""}</span>
            </>
          )}
        </div>

        {rfq.description && (
          <p className="pl-card-description">{rfq.description}</p>
        )}
      </div>

      <div className="pl-card-chev" aria-hidden="true">›</div>
    </Link>
  );
}

const PL_CSS = `
.pl-wrap { max-width: 860px; margin: 0 auto; padding: var(--q-space-5) var(--q-space-5) var(--q-space-8); }

.pl-header {
  display: flex; align-items: flex-end; justify-content: space-between;
  gap: 16px; margin-bottom: 22px; flex-wrap: wrap;
}
.pl-eyebrow {
  font-size: 13px; font-weight: 600; color: var(--q-ink-muted); margin-bottom: 4px;
}
.pl-title {
  font-size: 40px; line-height: 1; letter-spacing: -1.2px;
  font-weight: 700; margin: 0;
}

.pl-filter-row { display: flex; gap: 8px; margin-bottom: 20px; flex-wrap: wrap; }
.pl-chip {
  padding: 6px 14px; border-radius: var(--q-radius-pill);
  font-size: 14px; font-weight: 500; font-family: inherit; cursor: pointer;
  background: transparent; color: var(--q-ink-muted);
  box-shadow: inset 0 0 0 0.5px var(--q-hairline); border: none;
  transition: background 0.15s, color 0.15s;
}
.pl-chip:hover { color: var(--q-ink); }
.pl-chip.is-active { background: var(--q-ink); color: var(--q-surface); box-shadow: none; }
.pl-chip-count { opacity: 0.7; margin-left: 4px; }

.pl-list { display: flex; flex-direction: column; gap: 12px; }

.pl-card {
  background: var(--q-surface); border-radius: var(--q-radius-xl);
  padding: 20px 22px; display: flex; gap: 18px; align-items: flex-start;
  text-decoration: none; color: var(--q-ink);
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
  transition: box-shadow 0.15s, transform 0.15s;
}
.pl-card:hover {
  box-shadow: inset 0 0 0 0.5px var(--q-hairline), 0 6px 18px rgba(17,18,22,0.06);
  text-decoration: none;
}
.pl-card:active { transform: translateY(1px); }

.pl-thumb {
  width: 72px; height: 72px; border-radius: 12px; overflow: hidden;
  background: var(--q-scan-accent-soft); flex-shrink: 0;
}
.pl-thumb > div { height: 100% !important; background: transparent !important; border: none !important; border-radius: 0 !important; }
.pl-thumb canvas { display: block; width: 100% !important; height: 100% !important; }
.pl-thumb-empty {
  height: 100%; display: flex; align-items: center; justify-content: center;
  color: var(--q-scan-accent); opacity: 0.4; font-size: 26px;
}

.pl-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 8px; }

.pl-card-title-row {
  display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
}
.pl-card-title {
  font-size: 19px; font-weight: 700; letter-spacing: -0.3px; line-height: 1.2;
  margin: 0; overflow-wrap: break-word;
}
.pl-card-address { font-size: 13px; color: var(--q-ink-muted); margin-top: 4px; }

.pl-status {
  font-size: 11px; font-weight: 700; letter-spacing: 0.4px; text-transform: uppercase;
  padding: 3px 8px; border-radius: 6px; white-space: nowrap;
}
.pl-status-wait   { background: rgba(184,116,20,0.1); color: var(--q-warning); }
.pl-status-active { background: var(--q-primary-soft); color: var(--q-primary); }
.pl-status-hired  { background: rgba(47,106,75,0.12);  color: var(--q-success); }

.pl-card-meta {
  display: flex; gap: 10px; font-size: 13px; color: var(--q-ink-muted);
  align-items: center; flex-wrap: wrap;
}
.pl-card-meta strong { color: var(--q-ink); font-weight: 700; }
.pl-dot { width: 3px; height: 3px; background: var(--q-ink-dim); border-radius: 50%; }

.pl-card-description {
  font-size: 14px; line-height: 1.55; color: var(--q-ink-soft); margin: 0;
  display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical;
  overflow: hidden; white-space: pre-wrap;
}

.pl-card-chev {
  align-self: center; font-size: 28px; color: var(--q-ink-dim); font-weight: 300;
  line-height: 1; flex-shrink: 0;
}

@media (max-width: 640px) {
  .pl-wrap { padding: var(--q-space-4); }
  .pl-title { font-size: 32px; letter-spacing: -0.8px; }
  .pl-card { padding: 16px; gap: 12px; }
  .pl-thumb { width: 56px; height: 56px; }
  .pl-card-title { font-size: 17px; }
  .pl-card-chev { display: none; }
}
`;
