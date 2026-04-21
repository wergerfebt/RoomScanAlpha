import { useState, useRef, useCallback, useEffect } from "react";

function useIsMobile(breakpoint = 768) {
  const [mobile, setMobile] = useState(
    () => typeof window !== "undefined" && window.innerWidth <= breakpoint,
  );
  useEffect(() => {
    const mq = window.matchMedia(`(max-width: ${breakpoint}px)`);
    const handler = (e: MediaQueryListEvent) => setMobile(e.matches);
    mq.addEventListener("change", handler);
    return () => mq.removeEventListener("change", handler);
  }, [breakpoint]);
  return mobile;
}

export interface FilterValues {
  minPrice: number;
  maxPrice: number;
  minRating: string;
  service?: string;
}

interface FilterSidebarProps {
  prices: number[];
  filters: FilterValues;
  onChange: (f: FilterValues) => void;
  showService?: boolean;
  services?: string[];
}

function fmtPrice(cents: number): string {
  return "$" + (cents / 100).toLocaleString("en-US", { minimumFractionDigits: 0 });
}

function parsePrice(s: string): number {
  const n = parseInt(s.replace(/[^0-9]/g, ""), 10);
  return isNaN(n) ? 0 : n * 100;
}

export default function FilterSidebar({
  prices,
  filters,
  onChange,
  showService = false,
  services = [],
}: FilterSidebarProps) {
  const absMin = prices.length ? Math.min(...prices) : 0;
  const absMax = prices.length ? Math.max(...prices) : 0;
  const range = absMax - absMin || 1;

  function clearAll() {
    onChange({ minPrice: absMin, maxPrice: absMax, minRating: "all", service: undefined });
  }

  function setRating(r: string) {
    onChange({ ...filters, minRating: r });
  }

  function setService(s: string) {
    onChange({ ...filters, service: s === "" ? undefined : s });
  }

  // --- Price histogram ($3K buckets) ---
  const bucketWidth = 300000; // $3,000 in cents
  const bucketStart = Math.floor(absMin / bucketWidth) * bucketWidth;
  const bucketCount = Math.max(1, Math.ceil((absMax - bucketStart) / bucketWidth));
  const counts = new Array(bucketCount).fill(0);
  prices.forEach((p) => {
    let idx = Math.floor((p - bucketStart) / bucketWidth);
    idx = Math.max(0, Math.min(bucketCount - 1, idx));
    counts[idx]++;
  });
  const maxCount = Math.max(...counts, 1);

  // --- Range slider ---
  const minPct = absMax > absMin ? ((filters.minPrice - absMin) / range) * 100 : 0;
  const maxPct = absMax > absMin ? ((filters.maxPrice - absMin) / range) * 100 : 100;
  const trackRef = useRef<HTMLDivElement>(null);
  const dragging = useRef<"min" | "max" | null>(null);

  const handleDrag = useCallback(
    (clientX: number) => {
      if (!dragging.current || !trackRef.current) return;
      const rect = trackRef.current.getBoundingClientRect();
      let pct = ((clientX - rect.left) / rect.width) * 100;
      pct = Math.max(0, Math.min(100, pct));
      const val = Math.round(absMin + (pct / 100) * range);

      if (dragging.current === "min") {
        onChange({ ...filters, minPrice: Math.min(val, filters.maxPrice) });
      } else {
        onChange({ ...filters, maxPrice: Math.max(val, filters.minPrice) });
      }
    },
    [absMin, range, filters, onChange],
  );

  useEffect(() => {
    function onMove(e: MouseEvent) {
      handleDrag(e.clientX);
    }
    function onTouchMove(e: TouchEvent) {
      handleDrag(e.touches[0].clientX);
    }
    function onUp() {
      dragging.current = null;
    }
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
    document.addEventListener("touchmove", onTouchMove);
    document.addEventListener("touchend", onUp);
    return () => {
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      document.removeEventListener("touchmove", onTouchMove);
      document.removeEventListener("touchend", onUp);
    };
  }, [handleDrag]);

  const isMobile = useIsMobile();
  const [mobileOpen, setMobileOpen] = useState(false);

  // Price filter content — visible as soon as there's any bid. With a single
  // bid the slider is degenerate (min === max), but the text inputs + rating
  // controls still work, so we show it rather than hiding the whole section.
  const priceFilter = prices.length >= 1 && (
    <div className="filter-section">
      <div style={{ padding: "14px 16px" }}><h4 style={{ fontSize: 14, fontWeight: 600 }}>Price</h4></div>
      <div className="filter-section-body">
        <div className="filter-histogram">
          {counts.map((c, i) => {
            const bMin = bucketStart + bucketWidth * i;
            const bMax = bucketStart + bucketWidth * (i + 1);
            const active = bMax >= filters.minPrice && bMin <= filters.maxPrice;
            const h = Math.max(3, (c / maxCount) * 50);
            return (
              <div key={i} className={`filter-hist-bar${active ? " active" : ""}`} style={{ height: h }} />
            );
          })}
        </div>
        <div className="filter-range-track" ref={trackRef}>
          <div className="filter-range-fill" style={{ left: `${minPct}%`, right: `${100 - maxPct}%` }} />
          <div className="filter-range-thumb" style={{ left: `${minPct}%` }}
            onMouseDown={() => (dragging.current = "min")} onTouchStart={() => (dragging.current = "min")} />
          <div className="filter-range-thumb" style={{ left: `${maxPct}%` }}
            onMouseDown={() => (dragging.current = "max")} onTouchStart={() => (dragging.current = "max")} />
        </div>
        <div className="filter-price-inputs">
          <div>
            <label>Min price</label>
            <input className="filter-price-input" value={fmtPrice(filters.minPrice)}
              onChange={(e) => onChange({ ...filters, minPrice: parsePrice(e.target.value) })} />
          </div>
          <span className="filter-price-dash">&mdash;</span>
          <div>
            <label>Max price</label>
            <input className="filter-price-input" value={fmtPrice(filters.maxPrice)}
              onChange={(e) => onChange({ ...filters, maxPrice: parsePrice(e.target.value) })} />
          </div>
        </div>
      </div>
    </div>
  );

  // Rating filter content
  const ratingFilter = (
    <div className="filter-section">
      <div style={{ padding: "14px 16px" }}><h4 style={{ fontSize: 14, fontWeight: 600 }}>Rating</h4></div>
      <div className="filter-section-body">
        <div className="filter-rating-options">
          {[
            { value: "all", label: "All" },
            { value: "4.5", label: "4.5+" },
            { value: "4.0", label: "4.0+" },
            { value: "3.5", label: "3.5+" },
          ].map((opt) => (
            <label key={opt.value} className="filter-rating-option">
              <input type="radio" name="rating" checked={filters.minRating === opt.value}
                onChange={() => setRating(opt.value)} />
              {opt.value !== "all" && <span className="filter-star">&#9733;</span>}
              {opt.label}
            </label>
          ))}
        </div>
      </div>
    </div>
  );

  // Service filter content
  const serviceFilter = showService && services.length > 0 && (
    <div className="filter-section">
      <div style={{ padding: "14px 16px" }}><h4 style={{ fontSize: 14, fontWeight: 600 }}>Service</h4></div>
      <div className="filter-section-body">
        <select className="filter-service-select" value={filters.service || ""}
          onChange={(e) => setService(e.target.value)}>
          <option value="">All services</option>
          {services.map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
      </div>
    </div>
  );

  if (isMobile) {
    return (
      <div className="filter-sidebar">
        <div className="filter-sidebar-header" onClick={() => setMobileOpen(!mobileOpen)}
          style={{ cursor: "pointer" }}>
          <h3>Filters</h3>
          <span className={`filter-chevron${mobileOpen ? "" : " collapsed"}`}>&#9650;</span>
        </div>
        {mobileOpen && (
          <>
            {priceFilter}
            {ratingFilter}
            {serviceFilter}
            <div style={{ padding: "8px 16px 12px" }}>
              <button className="filter-clear-btn" onClick={clearAll}>Clear all</button>
            </div>
          </>
        )}
      </div>
    );
  }

  return (
    <div className="filter-sidebar">
      <div className="filter-sidebar-header">
        <h3>Filters</h3>
        <button className="filter-clear-btn" onClick={clearAll}>
          Clear all
        </button>
      </div>
      {priceFilter}
      {ratingFilter}
      {serviceFilter}
    </div>
  );
}
