import { useState } from "react";

export interface Job {
  rfq_id: string;
  title: string;
  description: string | null;
  address: string | null;
  created_at: string | null;
  homeowner: { name: string | null; icon_url: string | null };
  bid: {
    id: string;
    price_cents: number;
    status: string;
    received_at: string | null;
  } | null;
  job_status: "new" | "pending" | "won" | "lost";
}

function fmtPrice(cents: number): string {
  return "$" + (cents / 100).toLocaleString("en-US", { minimumFractionDigits: 0 });
}

function fmtDate(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function getInitials(name: string | null): string {
  if (!name) return "?";
  return name
    .split(/\s+/)
    .map((w) => w[0])
    .slice(0, 2)
    .join("")
    .toUpperCase();
}

const statusConfig: Record<string, { label: string; className: string }> = {
  new: { label: "New", className: "badge-info" },
  pending: { label: "Pending", className: "badge-pending" },
  won: { label: "Won", className: "badge-won" },
  lost: { label: "Lost", className: "badge-lost" },
};

export default function JobCard({ job }: { job: Job }) {
  const [expanded, setExpanded] = useState(false);
  const ho = job.homeowner;
  const cfg = statusConfig[job.job_status] || statusConfig.new;

  return (
    <div className={`contractor-card${expanded ? " expanded" : ""}`}>
      <div className="contractor-card-header" onClick={() => setExpanded(!expanded)}>
        {/* Homeowner icon */}
        <div className="contractor-card-icon">
          {ho.icon_url ? (
            <img src={ho.icon_url} alt="" />
          ) : (
            <span className="contractor-card-initials">{getInitials(ho.name)}</span>
          )}
        </div>

        {/* Job summary */}
        <div className="contractor-card-summary">
          <div className="contractor-card-name">{job.title}</div>
          <div className="contractor-card-meta">
            {job.address && <span>{job.address}</span>}
            <span className={`badge ${cfg.className}`}>{cfg.label}</span>
          </div>
        </div>

        {/* Price / action */}
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

      {/* Expanded detail */}
      {expanded && (
        <div className="contractor-card-detail">
          {/* Meta info */}
          <div style={{ display: "flex", gap: 16, fontSize: 13, color: "var(--color-text-muted)", marginBottom: 12, paddingTop: 12, flexWrap: "wrap" }}>
            {ho.name && <span>Homeowner: {ho.name}</span>}
            {job.created_at && <span>Posted {fmtDate(job.created_at)}</span>}
            {job.bid?.received_at && <span>Bid submitted {fmtDate(job.bid.received_at)}</span>}
          </div>

          {/* Description */}
          {job.description && (
            <div className="contractor-card-description">{job.description}</div>
          )}

          {/* Actions */}
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            <a
              href={`/quote/${job.rfq_id}`}
              className="btn"
              style={{ fontSize: 13, padding: "8px 16px" }}
            >
              View 3D Scan
            </a>
            {job.job_status === "new" && (
              <a
                href={`/quote/${job.rfq_id}`}
                className="btn btn-primary"
                style={{ fontSize: 13, padding: "8px 16px" }}
              >
                Submit Quote
              </a>
            )}
          </div>

          <button
            className="contractor-card-collapse-btn"
            onClick={() => setExpanded(false)}
            style={{ marginTop: 12 }}
          >
            Close
          </button>
        </div>
      )}
    </div>
  );
}
