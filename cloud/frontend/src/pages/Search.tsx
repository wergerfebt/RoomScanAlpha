import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import Layout from "../components/Layout";
import FilterSidebar, { type FilterValues } from "../components/FilterSidebar";
import ContractorCard, { type Contractor } from "../components/ContractorCard";
import { SERVICES } from "../api/services";

const SEARCH_CTA_CSS = `
.search-alpha-cta {
  display: flex; align-items: center; gap: 16px;
  padding: 18px 22px; margin-bottom: 18px;
  background: linear-gradient(135deg, #245239 0%, #2F6A4B 55%, #3d8a63 100%);
  border-radius: var(--q-radius-lg);
  color: var(--q-primary-ink); text-decoration: none;
  box-shadow:
    0 8px 24px rgba(47,106,75,0.28),
    0 2px 6px rgba(20,34,26,0.12),
    inset 0 1px 0 rgba(255,255,255,0.12);
  position: relative; overflow: hidden;
  transition: transform 0.2s ease, box-shadow 0.2s ease;
}
.search-alpha-cta::after {
  content: ""; position: absolute; inset: 0;
  background:
    radial-gradient(circle at 100% 0%, rgba(255,255,255,0.18) 0%, transparent 40%),
    radial-gradient(circle at 0% 100%, rgba(255,255,255,0.08) 0%, transparent 50%);
  pointer-events: none;
}
.search-alpha-cta:hover {
  transform: translateY(-2px);
  box-shadow:
    0 14px 32px rgba(47,106,75,0.36),
    0 3px 8px rgba(20,34,26,0.16),
    inset 0 1px 0 rgba(255,255,255,0.14);
  text-decoration: none;
}
.search-alpha-cta:active { transform: translateY(0); }

.search-alpha-cta-icon {
  flex-shrink: 0; width: 48px; height: 48px; border-radius: 12px;
  background: rgba(255,255,255,0.14); color: #fff;
  display: flex; align-items: center; justify-content: center;
  box-shadow: inset 0 1px 0 rgba(255,255,255,0.18);
  position: relative; z-index: 1;
}
.search-alpha-cta-body { flex: 1; min-width: 0; position: relative; z-index: 1; }
.search-alpha-cta-title {
  font-size: 18px; font-weight: 700; letter-spacing: -0.3px; line-height: 1.2;
}
.search-alpha-cta-sub {
  font-size: 13px; opacity: 0.88; margin-top: 4px; line-height: 1.4;
}
.search-alpha-cta-arrow {
  flex-shrink: 0; font-size: 24px; font-weight: 300; opacity: 0.85;
  position: relative; z-index: 1;
  transition: transform 0.2s ease;
}
.search-alpha-cta:hover .search-alpha-cta-arrow { transform: translateX(4px); opacity: 1; }

@media (max-width: 640px) {
  .search-alpha-cta { padding: 14px 16px; gap: 12px; }
  .search-alpha-cta-icon { width: 40px; height: 40px; }
  .search-alpha-cta-title { font-size: 16px; }
  .search-alpha-cta-sub { font-size: 12px; }
}
`;

export default function Search() {
  const [params] = useSearchParams();
  const serviceParam = params.get("service") || "";
  const locationParam = params.get("location") || "";

  const [contractors, setContractors] = useState<Contractor[]>([]);
  const [loading, setLoading] = useState(true);
  const [sort, setSort] = useState("rating");
  const [filters, setFilters] = useState<FilterValues>({
    minPrice: 0,
    maxPrice: Infinity,
    minRating: "all",
    service: serviceParam || undefined,
  });

  useEffect(() => {
    setLoading(true);
    const qs = new URLSearchParams();
    if (serviceParam) qs.set("service", serviceParam);
    if (locationParam) qs.set("location", locationParam);
    fetch(`/api/contractors/search?${qs}`)
      .then((r) => r.json())
      .then((data) => setContractors(data))
      .catch(() => setContractors([]))
      .finally(() => setLoading(false));
  }, [serviceParam, locationParam]);

  // Apply filters
  const filtered = contractors.filter((c) => {
    if (filters.minRating !== "all") {
      const r = c.review_rating || 0;
      if (r < parseFloat(filters.minRating)) return false;
    }
    return true;
  });

  // Sort
  const sorted = [...filtered].sort((a, b) => {
    switch (sort) {
      case "name":
        return (a.name || "").localeCompare(b.name || "");
      case "reviews":
        return (b.review_count || 0) - (a.review_count || 0);
      default:
        return (b.review_rating || 0) - (a.review_rating || 0);
    }
  });

  return (
    <Layout>
      {/* Results header */}
      <div style={{
        maxWidth: "var(--max-width)", margin: "0 auto",
        padding: "var(--q-space-5) var(--q-space-5) 0",
      }}>
        {locationParam && (
          <div style={{ fontSize: 13, fontWeight: 600, color: "var(--q-ink-muted)" }}>
            {locationParam}
          </div>
        )}
        <h1 style={{
          fontSize: 36, fontWeight: 700, letterSpacing: "-1px",
          margin: "2px 0 0", lineHeight: 1.1,
        }}>
          {serviceParam ? `${serviceParam} contractors` : "Browse contractors"}
        </h1>
        {!loading && (
          <div style={{ fontSize: 14, color: "var(--q-ink-muted)", marginTop: 6 }}>
            {filtered.length} contractor{filtered.length !== 1 ? "s" : ""}
            {" near you"} · sorted by rating
          </div>
        )}
      </div>

      {loading && (
        <div className="page-loading">
          <div className="spinner" />
        </div>
      )}

      {!loading && (
        <div className="list-page-layout">
          <FilterSidebar
            prices={[]}
            filters={filters}
            onChange={setFilters}
            showService
            services={SERVICES}
          />

          <div className="list-page-main">
            {/* Alpha CTA banner */}
            <a href="/info" className="search-alpha-cta">
              <div className="search-alpha-cta-icon" aria-hidden="true">
                <svg viewBox="0 0 24 24" width="32" height="32" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M3 10l9-6 9 6v10a1 1 0 01-1 1H4a1 1 0 01-1-1V10z" />
                  <path d="M9 21v-6h6v6" />
                </svg>
              </div>
              <div className="search-alpha-cta-body">
                <div className="search-alpha-cta-title">Compare quotes and save</div>
                <div className="search-alpha-cta-sub">
                  Scan your room, get competing bids from local contractors. Join the alpha.
                </div>
              </div>
              <div className="search-alpha-cta-arrow" aria-hidden="true">→</div>
            </a>
            <style>{SEARCH_CTA_CSS}</style>

            <div className="list-page-sort">
              <label>Sort:</label>
              <select value={sort} onChange={(e) => setSort(e.target.value)}>
                <option value="rating">Rating</option>
                <option value="reviews">Most Reviews</option>
                <option value="name">Name</option>
              </select>
            </div>

            {sorted.length === 0 && (
              <div className="empty-state" style={{ padding: "40px 20px" }}>
                <h3>No contractors match filters</h3>
                <p>Try adjusting your filters.</p>
              </div>
            )}

            {sorted.map((c) => (
              <ContractorCard key={c.id} contractor={c} />
            ))}
          </div>
        </div>
      )}
    </Layout>
  );
}
