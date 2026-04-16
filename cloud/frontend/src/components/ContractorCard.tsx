import { useState } from "react";
import { Link } from "react-router-dom";

export interface GalleryImage {
  id: string;
  image_url: string | null;
  before_image_url: string | null;
  image_type: string;
  caption: string | null;
}

export interface Contractor {
  id: string;
  name: string;
  icon_url: string | null;
  yelp_url: string | null;
  google_reviews_url: string | null;
  review_rating: number | null;
  review_count: number | null;
  description?: string | null;
  address?: string | null;
  website_url?: string | null;
  gallery?: GalleryImage[];
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
  const [lightbox, setLightbox] = useState<string | null>(null);
  const c = contractor;

  return (
    <>
      <div className={`contractor-card${expanded ? " expanded" : ""}`}>
        <div className="contractor-card-header" onClick={() => setExpanded(!expanded)}>
          {/* Icon — links to profile */}
          <Link
            to={`/contractors/${c.id}`}
            className="contractor-card-icon"
            onClick={(e) => e.stopPropagation()}
            style={{ textDecoration: "none" }}
          >
            {c.icon_url ? (
              <img src={c.icon_url} alt="" />
            ) : (
              <span className="contractor-card-initials">{getInitials(c.name)}</span>
            )}
          </Link>

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
            {/* Description */}
            {c.description && (
              <p style={{
                fontSize: 14, lineHeight: 1.6, color: "var(--color-text-secondary)",
                paddingTop: 12, marginBottom: 14, whiteSpace: "pre-wrap",
              }}>
                {c.description}
              </p>
            )}

            {/* Address & Website */}
            {(c.address || c.website_url) && (
              <div style={{
                display: "flex", gap: 16, flexWrap: "wrap", fontSize: 13,
                marginBottom: 14, color: "var(--color-text-secondary)",
              }}>
                {c.address && (
                  <span style={{ display: "flex", alignItems: "center", gap: 4 }}>
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="var(--color-text-muted)">
                      <path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5a2.5 2.5 0 010-5 2.5 2.5 0 010 5z" />
                    </svg>
                    {c.address}
                  </span>
                )}
                {c.website_url && (
                  <a href={c.website_url} target="_blank" rel="noopener noreferrer"
                    onClick={(e) => e.stopPropagation()}
                    style={{ display: "flex", alignItems: "center", gap: 4, color: "var(--color-primary)", fontWeight: 600 }}>
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="var(--color-primary)">
                      <path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zm6.93 6h-2.95a15.65 15.65 0 00-1.38-3.56A8.03 8.03 0 0118.92 8zM12 4.04c.83 1.2 1.48 2.53 1.91 3.96h-3.82c.43-1.43 1.08-2.76 1.91-3.96zM4.26 14C4.1 13.36 4 12.69 4 12s.1-1.36.26-2h3.38c-.08.66-.14 1.32-.14 2s.06 1.34.14 2H4.26zm.82 2h2.95c.32 1.25.78 2.45 1.38 3.56A7.987 7.987 0 015.08 16zm2.95-8H5.08a7.987 7.987 0 014.33-3.56A15.65 15.65 0 008.03 8zM12 19.96c-.83-1.2-1.48-2.53-1.91-3.96h3.82c-.43 1.43-1.08 2.76-1.91 3.96zM14.34 14H9.66c-.09-.66-.16-1.32-.16-2s.07-1.35.16-2h4.68c.09.65.16 1.32.16 2s-.07 1.34-.16 2zm.25 5.56c.6-1.11 1.06-2.31 1.38-3.56h2.95a8.03 8.03 0 01-4.33 3.56zM16.36 14c.08-.66.14-1.32.14-2s-.06-1.34-.14-2h3.38c.16.64.26 1.31.26 2s-.1 1.36-.26 2h-3.38z" />
                    </svg>
                    Website
                  </a>
                )}
              </div>
            )}

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
                <a href={c.yelp_url} target="_blank" rel="noopener noreferrer" className="contractor-card-review-link"
                  onClick={(e) => e.stopPropagation()}>
                  Yelp
                </a>
              )}
              {c.google_reviews_url && (
                <a href={c.google_reviews_url} target="_blank" rel="noopener noreferrer" className="contractor-card-review-link"
                  onClick={(e) => e.stopPropagation()}>
                  Google
                </a>
              )}
            </div>

            {/* Gallery thumbnails (clickable) */}
            {c.gallery && c.gallery.length > 0 && (
              <div style={{
                display: "flex", gap: 8, marginBottom: 14, overflowX: "auto",
                paddingBottom: 4,
              }}>
                {c.gallery.map((img) => (
                  <div
                    key={img.id}
                    onClick={(e) => {
                      e.stopPropagation();
                      if (img.image_url) setLightbox(img.image_url);
                    }}
                    style={{
                      flexShrink: 0, width: 120, height: 90, borderRadius: 8,
                      overflow: "hidden", background: "var(--color-border-light)",
                      cursor: img.image_url ? "pointer" : "default",
                    }}
                  >
                    {img.image_url && (
                      <img
                        src={img.image_url}
                        alt={img.caption || ""}
                        style={{ width: "100%", height: "100%", objectFit: "cover", display: "block" }}
                      />
                    )}
                  </div>
                ))}
              </div>
            )}

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
                onClick={(e) => e.stopPropagation()}
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

            {/* Get a Quote CTA */}
            <a
              href="/info"
              onClick={(e) => e.stopPropagation()}
              className="contractor-card-hire-btn"
              style={{ display: "block", textAlign: "center", textDecoration: "none", marginTop: 10 }}
            >
              Get a Quote from {c.name || "this Contractor"}
            </a>

            {/* View profile link */}
            <Link
              to={`/contractors/${c.id}`}
              className="btn btn-full"
              onClick={(e) => e.stopPropagation()}
              style={{ marginTop: 10, fontSize: 13, textAlign: "center", textDecoration: "none" }}
            >
              View Full Profile
            </Link>

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

      {/* Lightbox */}
      {lightbox && (
        <div
          onClick={() => setLightbox(null)}
          style={{
            position: "fixed", inset: 0, background: "rgba(0,0,0,0.85)",
            display: "flex", alignItems: "center", justifyContent: "center",
            zIndex: 2000, cursor: "zoom-out", padding: 24,
          }}
        >
          <img
            src={lightbox}
            alt=""
            style={{ maxWidth: "90vw", maxHeight: "90vh", objectFit: "contain", borderRadius: 8 }}
          />
          <button
            onClick={() => setLightbox(null)}
            style={{
              position: "absolute", top: 20, right: 24, background: "none",
              border: "none", color: "#fff", fontSize: 32, cursor: "pointer", lineHeight: 1,
            }}
          >
            &times;
          </button>
        </div>
      )}
    </>
  );
}
