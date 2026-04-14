import { useState } from "react";

export interface Contractor {
  id: string;
  name: string;
  icon_url: string | null;
  yelp_url: string | null;
  google_reviews_url: string | null;
  review_rating: number | null;
  review_count: number | null;
}

export interface Bid {
  id: string;
  price_cents: number;
  description: string | null;
  pdf_url: string | null;
  received_at: string | null;
  contractor: Contractor;
}

interface ContractorCardProps {
  contractor: Contractor;
  bid?: Bid;
  isLowest?: boolean;
  onHire?: (bidId: string, contractorName: string) => void;
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

export default function ContractorCard({
  contractor,
  bid,
  isLowest = false,
  onHire,
}: ContractorCardProps) {
  const [expanded, setExpanded] = useState(false);
  const c = contractor;

  return (
    <div className={`contractor-card${expanded ? " expanded" : ""}`}>
      <div className="contractor-card-header" onClick={() => setExpanded(!expanded)}>
        {/* Icon */}
        <div className="contractor-card-icon">
          {c.icon_url ? (
            <img src={c.icon_url} alt="" />
          ) : (
            <span className="contractor-card-initials">{getInitials(c.name)}</span>
          )}
        </div>

        {/* Summary */}
        <div className="contractor-card-summary">
          <div className="contractor-card-name">{c.name || "Contractor"}</div>
          <div className="contractor-card-meta">
            {c.review_rating && (
              <span className="contractor-card-stars">
                {c.review_rating.toFixed(1)} &#9733;
              </span>
            )}
            {c.review_count != null && <span>({c.review_count})</span>}
            {isLowest && <span className="contractor-card-badge-low">Lowest</span>}
          </div>
        </div>

        {/* Price (if bid) */}
        {bid && (
          <div style={{ textAlign: "right", flexShrink: 0 }}>
            <div className="contractor-card-price">{fmtPrice(bid.price_cents)}</div>
            {!expanded && (
              <button
                className="contractor-card-details-btn"
                onClick={(e) => {
                  e.stopPropagation();
                  setExpanded(true);
                }}
              >
                See details
              </button>
            )}
          </div>
        )}

        {/* No bid — just show rating prominently */}
        {!bid && c.review_rating && (
          <div style={{ textAlign: "right", flexShrink: 0 }}>
            <div className="contractor-card-price" style={{ fontSize: 16 }}>
              {c.review_rating.toFixed(1)} &#9733;
            </div>
          </div>
        )}
      </div>

      {/* Expanded detail */}
      {expanded && (
        <div className="contractor-card-detail">
          {/* Review links */}
          <div className="contractor-card-reviews">
            {c.review_rating && (
              <span className="contractor-card-stars">
                {c.review_rating.toFixed(1)} &#9733;
              </span>
            )}
            {c.review_count != null && (
              <span style={{ fontSize: 13, color: "var(--color-text-secondary)" }}>
                {c.review_count} reviews
              </span>
            )}
            {c.yelp_url && (
              <a href={c.yelp_url} target="_blank" rel="noopener noreferrer" className="contractor-card-review-link">
                Yelp
              </a>
            )}
            {c.google_reviews_url && (
              <a href={c.google_reviews_url} target="_blank" rel="noopener noreferrer" className="contractor-card-review-link">
                Google
              </a>
            )}
          </div>

          {/* Bid description */}
          {bid?.description && (
            <div className="contractor-card-description">{bid.description}</div>
          )}

          {/* PDF link */}
          {bid?.pdf_url && (
            <a
              href={bid.pdf_url}
              target="_blank"
              rel="noopener noreferrer"
              className="contractor-card-pdf"
            >
              <svg width="18" height="18" viewBox="0 0 24 24" fill="var(--color-primary)">
                <path d="M14 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V8l-6-6zm-1 2l5 5h-5V4zm-3 9v2H8v-2h2zm6 0v2h-4v-2h4zm-6 4v2H8v-2h2zm6 0v2h-4v-2h4z" />
              </svg>
              View Quote (PDF)
            </a>
          )}

          {/* Received date */}
          {bid?.received_at && (
            <div className="contractor-card-date">Received {fmtDate(bid.received_at)}</div>
          )}

          {/* Hire button */}
          {bid && onHire && (
            <button
              className="contractor-card-hire-btn"
              onClick={() => onHire(bid.id, c.name || "Contractor")}
            >
              Hire {c.name || "Contractor"}
            </button>
          )}

          {/* Collapse */}
          <button
            className="contractor-card-collapse-btn"
            onClick={() => setExpanded(false)}
          >
            Close
          </button>
        </div>
      )}
    </div>
  );
}
