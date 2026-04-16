import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import Layout from "../components/Layout";
import FilterSidebar, { type FilterValues } from "../components/FilterSidebar";
import ContractorCard, { type Contractor } from "../components/ContractorCard";
import { SERVICES } from "../api/services";

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
            {/* Alpha CTA banner */}
            <a
              href="/info"
              style={{
                display: "block",
                padding: "14px 20px",
                marginBottom: 14,
                background: "linear-gradient(135deg, #0055cc 0%, #0088ff 100%)",
                borderRadius: "var(--radius-lg)",
                color: "#fff",
                textDecoration: "none",
                textAlign: "center",
              }}
            >
              <strong style={{ fontSize: 15 }}>Compare quotes and save</strong>
              <span style={{ display: "block", fontSize: 13, opacity: 0.85, marginTop: 2 }}>
                Scan your room, get competing bids from local contractors. Join the alpha.
              </span>
            </a>

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
