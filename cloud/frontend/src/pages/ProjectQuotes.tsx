import { useEffect, useState } from "react";
import { useParams, Link } from "react-router-dom";
import Layout from "../components/Layout";
import FilterSidebar, { type FilterValues } from "../components/FilterSidebar";
import ContractorCard, { type Bid } from "../components/ContractorCard";
import { apiFetch } from "../api/client";

interface BidsResponse {
  rfq_id: string;
  project_description: string | null;
  bids: Bid[];
}

export default function ProjectQuotes() {
  const { rfqId } = useParams<{ rfqId: string }>();
  const [data, setData] = useState<BidsResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [sort, setSort] = useState("price_asc");
  const [filters, setFilters] = useState<FilterValues>({
    minPrice: 0,
    maxPrice: Infinity,
    minRating: "all",
  });

  useEffect(() => {
    if (!rfqId) return;
    // Fetch the user's RFQs to get the bid_view_token, then use it to load bids
    apiFetch<{ rfqs: { id: string; bid_view_token: string | null }[] }>("/api/rfqs")
      .then((rfqData) => {
        const rfq = rfqData.rfqs.find((r) => r.id === rfqId);
        const token = rfq?.bid_view_token;
        if (!token) throw new Error("No bid view token found for this project");
        return apiFetch<BidsResponse>(`/api/rfqs/${rfqId}/bids?token=${encodeURIComponent(token)}`);
      })
      .then((d) => {
        setData(d);
        const prices = d.bids.map((b) => b.price_cents);
        if (prices.length) {
          setFilters({
            minPrice: Math.min(...prices),
            maxPrice: Math.max(...prices),
            minRating: "all",
          });
        }
      })
      .catch((err) => setError(err.message || "Failed to load quotes"))
      .finally(() => setLoading(false));
  }, [rfqId]);

  const bids = data?.bids || [];
  const prices = bids.map((b) => b.price_cents);

  // Apply filters
  const filtered = bids.filter((b) => {
    if (b.price_cents < filters.minPrice || b.price_cents > filters.maxPrice) return false;
    if (filters.minRating !== "all") {
      const r = b.contractor?.review_rating || 0;
      if (r < parseFloat(filters.minRating)) return false;
    }
    return true;
  });

  // Sort
  const sorted = [...filtered].sort((a, b) => {
    switch (sort) {
      case "price_desc":
        return b.price_cents - a.price_cents;
      case "rating":
        return (b.contractor.review_rating || 0) - (a.contractor.review_rating || 0);
      case "date":
        return (b.received_at || "").localeCompare(a.received_at || "");
      default:
        return a.price_cents - b.price_cents;
    }
  });

  const lowestPrice = filtered.length ? Math.min(...filtered.map((b) => b.price_cents)) : 0;

  return (
    <Layout>
      {/* Project header strip */}
      <div
        style={{
          background: "var(--color-surface)",
          borderBottom: "1px solid var(--color-border-light)",
          padding: "16px 24px",
        }}
      >
        <div style={{ maxWidth: "var(--max-width)", margin: "0 auto" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
            <h1 style={{ fontSize: 20, fontWeight: 700 }}>
              {data?.project_description || "Project Quotes"}
            </h1>
            <Link
              to={`/quote/${rfqId}`}
              style={{ fontSize: 13, fontWeight: 600, color: "var(--color-primary)" }}
            >
              View scans &rarr;
            </Link>
          </div>
          {bids.length > 0 && (
            <p style={{ fontSize: 13, color: "var(--color-text-muted)", marginTop: 4 }}>
              {bids.length} quote{bids.length !== 1 ? "s" : ""} received
            </p>
          )}
        </div>
      </div>

      {loading && (
        <div className="page-loading">
          <div className="spinner" />
        </div>
      )}

      {!loading && error && (
        <div className="empty-state">
          <h3>Something went wrong</h3>
          <p>{error}</p>
        </div>
      )}

      {!loading && !error && bids.length === 0 && (
        <div className="empty-state">
          <h3>No quotes yet</h3>
          <p>Contractor quotes will appear here once they review your 3D scan.</p>
        </div>
      )}

      {!loading && !error && bids.length > 0 && (
        <div className="list-page-layout">
          <FilterSidebar prices={prices} filters={filters} onChange={setFilters} />

          <div className="list-page-main">
            <div className="list-page-sort">
              <label>Sort:</label>
              <select value={sort} onChange={(e) => setSort(e.target.value)}>
                <option value="price_asc">Price &uarr;</option>
                <option value="price_desc">Price &darr;</option>
                <option value="rating">Rating</option>
                <option value="date">Date</option>
              </select>
            </div>

            {sorted.length === 0 && (
              <div className="empty-state" style={{ padding: "40px 20px" }}>
                <h3>No quotes match filters</h3>
                <p>Try adjusting your price range or rating.</p>
              </div>
            )}

            {sorted.map((bid) => (
              <ContractorCard
                key={bid.id}
                contractor={bid.contractor}
                bid={bid}
                isLowest={bid.price_cents === lowestPrice && sorted.length > 1}
              />
            ))}
          </div>
        </div>
      )}
    </Layout>
  );
}
