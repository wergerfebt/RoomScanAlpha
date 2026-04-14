import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import Layout from "../components/Layout";
import FilterSidebar, { type FilterValues } from "../components/FilterSidebar";
import ContractorCard, { type Contractor } from "../components/ContractorCard";
import { SERVICES } from "../api/services";

// Placeholder contractors for now — will be replaced by GET /api/contractors search endpoint
const DEMO_CONTRACTORS: Contractor[] = [
  { id: "c1", name: "Mike's Renovations", icon_url: null, yelp_url: "https://yelp.com", google_reviews_url: "https://google.com", review_rating: 4.8, review_count: 142 },
  { id: "c2", name: "ABC Contracting", icon_url: null, yelp_url: "https://yelp.com", google_reviews_url: "https://google.com", review_rating: 4.7, review_count: 128 },
  { id: "c3", name: "Lakefront Builders", icon_url: null, yelp_url: null, google_reviews_url: "https://google.com", review_rating: 4.9, review_count: 87 },
  { id: "c4", name: "Quick Fix Pro", icon_url: null, yelp_url: null, google_reviews_url: null, review_rating: 4.2, review_count: 34 },
  { id: "c5", name: "Chicago Home Pros", icon_url: null, yelp_url: "https://yelp.com", google_reviews_url: "https://google.com", review_rating: 4.6, review_count: 203 },
  { id: "c6", name: "Urban Remodel Co", icon_url: null, yelp_url: null, google_reviews_url: "https://google.com", review_rating: 3.9, review_count: 56 },
];

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
    // TODO: Replace with GET /api/contractors?q=...&service=...&location=...
    // For now, use demo data
    setTimeout(() => {
      setContractors(DEMO_CONTRACTORS);
      setLoading(false);
    }, 300);
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
      <div
        style={{
          background: "var(--color-surface)",
          borderBottom: "1px solid var(--color-border-light)",
          padding: "16px 24px",
        }}
      >
        <div style={{ maxWidth: "var(--max-width)", margin: "0 auto" }}>
          <h1 style={{ fontSize: 20, fontWeight: 700 }}>
            {serviceParam
              ? `${serviceParam} contractors`
              : "Browse Contractors"}
            {locationParam ? ` near ${locationParam}` : ""}
          </h1>
          {!loading && (
            <p style={{ fontSize: 13, color: "var(--color-text-muted)", marginTop: 4 }}>
              {filtered.length} contractor{filtered.length !== 1 ? "s" : ""} found
            </p>
          )}
        </div>
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
