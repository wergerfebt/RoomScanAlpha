import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import Layout from "../components/Layout";
import SearchBar from "../components/SearchBar";
import FloorPlan from "../components/FloorPlan";

const PREVIEW_RFQ_ID = "c05cc122-ed26-429d-a806-5025463c0d49";

interface PreviewRoom {
  scan_id: string;
  room_label: string;
  floor_area_sqft: number | null;
  room_polygon_ft: number[][] | null;
}

function useIsMobile(breakpoint = 860) {
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

const steps: Array<[string, string, string]> = [
  ["01", "Scan", "Capture your space in under 2 minutes with the iPhone app."],
  ["02", "Describe", "Tell us what you want done — cabinets, flooring, tile."],
  ["03", "Compare", "Vetted contractors review the 3D model and submit bids within 48 hours."],
  ["04", "Hire", "Pick the bid, sign, start. All through Quoterra."],
];

export default function Landing() {
  const isMobile = useIsMobile();

  return (
    <Layout>
      <section className="ln-hero">
        <div className="ln-hero-main">
          <div className="ln-badge">
            <span className="ln-badge-dot" /> Alpha · Chicago
          </div>
          <h1 className="ln-title">
            Real quotes.<br />No site visits.<br />
            <span className="ln-title-muted">48 hours.</span>
          </h1>
          <p className="ln-sub">
            Scan your room with iPhone. Vetted local contractors review the 3D model and
            submit detailed, comparable bids — without walking your property.
          </p>

          <div className="ln-search">
            <SearchBar size="large" />
          </div>

          <div className="ln-cta-row">
            <Link to="/login" className="ln-pill ln-pill-primary">Get the iPhone app</Link>
            <Link to="/search" className="ln-pill ln-pill-secondary">Browse contractors</Link>
          </div>

          <div className="ln-stats">
            <div>
              <strong>41 min</strong>
              <span>avg scan-to-first-bid</span>
            </div>
            <div className="ln-stats-sep">
              <strong>3.2×</strong>
              <span>bids per project</span>
            </div>
            <div className="ln-stats-sep">
              <strong>19%</strong>
              <span>avg savings</span>
            </div>
          </div>
        </div>

        {!isMobile && <ProductPreview />}
      </section>

      <section className="ln-how">
        <div className="ln-how-label">How it works</div>
        <div className="ln-how-grid">
          {steps.map(([n, t, d]) => (
            <div key={n} className="ln-step">
              <div className="ln-step-n">{n}</div>
              <div className="ln-step-t">{t}</div>
              <div className="ln-step-d">{d}</div>
            </div>
          ))}
        </div>
      </section>

      <footer className="ln-footer">
        &copy; {new Date().getFullYear()} Quoterra ·{" "}
        <a href="mailto:jake@roomscanalpha.com">Contact</a>
      </footer>

      <style>{LN_CSS}</style>
    </Layout>
  );
}

function ProductPreview() {
  const [view, setView] = useState<"floorplan" | "bev">("floorplan");
  const [data, setData] = useState<{ title: string; address: string | null; rooms: PreviewRoom[] } | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetch(`/api/rfqs/${PREVIEW_RFQ_ID}/contractor-view`)
      .then((r) => r.ok ? r.json() : null)
      .then((d) => { if (!cancelled && d) setData(d); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, []);

  const bids: Array<{ initials: string; mark: string; name: string; line: string; tl: string; amt: number }> = [
    { initials: "PH", mark: "#2F6A4B", name: "Phoenix Construction",   line: "Full gut, island w/ waterfall",   tl: "6 wks", amt: 32400 },
    { initials: "ME", mark: "#7A4B2E", name: "Meridian Build Co.",      line: "Cabinet refresh, new quartz",     tl: "4 wks", amt: 28900 },
    { initials: "LN", mark: "#556B2F", name: "Linden Remodeling",       line: "Budget rebuild, stock cabinets",  tl: "5 wks", amt: 24500 },
  ];

  const eyebrow = data?.title ? `${data.title}${data.address ? ` · ${data.address}` : ""}` : "Kitchen Remodel · Sample";
  const hasFloorplan = data?.rooms?.some((r) => r.room_polygon_ft && r.room_polygon_ft.length >= 3);

  return (
    <Link to={`/projects/${PREVIEW_RFQ_ID}`} className="ln-preview">
      <div className="ln-preview-head">
        <div>
          <div className="ln-preview-eyebrow">{eyebrow}</div>
          <div className="ln-preview-title">3 bids received</div>
        </div>
        <div className="ln-preview-badge">Scan ready</div>
      </div>

      <div className="ln-preview-scan">
        <div className="ln-preview-tabs" onClick={(e) => e.preventDefault()}>
          <button
            type="button"
            className={`ln-preview-tab ${view === "floorplan" ? "is-active" : ""}`}
            onClick={(e) => { e.preventDefault(); setView("floorplan"); }}
          >
            Floor plan
          </button>
          <button
            type="button"
            className={`ln-preview-tab ${view === "bev" ? "is-active" : ""}`}
            onClick={(e) => { e.preventDefault(); setView("bev"); }}
          >
            Bird's eye
          </button>
        </div>
        <div className="ln-preview-plan">
          {view === "floorplan" ? (
            hasFloorplan && data ? (
              <FloorPlan rooms={data.rooms} height={200} />
            ) : (
              <div className="ln-preview-plan-empty" />
            )
          ) : (
            <iframe
              title="Bird's eye preview"
              src={`/embed/scan/${PREVIEW_RFQ_ID}?view=bev&measurements=on`}
              className="ln-preview-iframe"
            />
          )}
        </div>
      </div>

      {bids.map((b) => (
        <div key={b.initials} className="ln-preview-bid">
          <div className="ln-preview-mark" style={{ background: b.mark }}>{b.initials}</div>
          <div className="ln-preview-bid-body">
            <div className="ln-preview-bid-name">{b.name}</div>
            <div className="ln-preview-bid-line">{b.line} · {b.tl}</div>
          </div>
          <div className="ln-preview-bid-amt">${b.amt.toLocaleString()}</div>
        </div>
      ))}
    </Link>
  );
}

const LN_CSS = `
.ln-hero {
  max-width: 1280px; margin: 0 auto;
  padding: 56px 64px 0;
  display: grid; grid-template-columns: 1.15fr 1fr; gap: 48px;
  align-items: center;
}
.ln-hero-main { min-width: 0; }

.ln-badge {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 5px 10px; background: var(--q-primary-soft); color: var(--q-primary);
  border-radius: var(--q-radius-pill); font-size: 12px; font-weight: 700;
  letter-spacing: 0.2px; margin-bottom: 20px;
}
.ln-badge-dot {
  width: 8px; height: 8px; background: var(--q-primary); border-radius: 50%;
}

.ln-title {
  font-size: 72px; font-weight: 700; letter-spacing: -2.4px;
  line-height: 0.98; margin: 0; color: var(--q-ink);
}
.ln-title-muted { color: var(--q-ink-muted); }

.ln-sub {
  font-size: 18px; color: var(--q-ink-soft); max-width: 520px;
  margin-top: 20px; line-height: 1.5;
}

.ln-search { margin-top: 26px; max-width: 560px; }

.ln-cta-row { display: flex; gap: 10px; margin-top: 20px; flex-wrap: wrap; }
.ln-pill {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 12px 22px; font-size: 15px; font-weight: 600; font-family: inherit;
  border-radius: var(--q-radius-pill); text-decoration: none;
  border: 0.5px solid transparent; transition: filter 0.15s, background 0.15s;
}
.ln-pill-primary   { background: var(--q-primary); color: var(--q-primary-ink); }
.ln-pill-primary:hover { filter: brightness(0.92); text-decoration: none; }
.ln-pill-secondary { background: var(--q-surface); color: var(--q-ink); border-color: var(--q-hairline); }
.ln-pill-secondary:hover { background: var(--q-surface-muted); text-decoration: none; }

.ln-stats { margin-top: 40px; display: flex; gap: 28px; font-size: 13px; color: var(--q-ink-muted); flex-wrap: wrap; }
.ln-stats strong { color: var(--q-ink); font-size: 20px; font-weight: 700; display: block; margin-bottom: 2px; }
.ln-stats-sep { border-left: 0.5px solid var(--q-hairline); padding-left: 28px; }

/* Product preview */
.ln-preview {
  background: var(--q-surface); border-radius: 20px; padding: 20px;
  box-shadow: 0 1px 3px var(--q-hairline), 0 30px 60px rgba(17,18,22,0.08);
  display: flex; flex-direction: column; gap: 12px;
  text-decoration: none; color: var(--q-ink);
  transition: transform 0.15s;
}
.ln-preview:hover { text-decoration: none; transform: translateY(-1px); }
.ln-preview-head { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; }
.ln-preview-eyebrow {
  font-size: 12px; font-weight: 700; color: var(--q-ink-muted);
  letter-spacing: 0.5px; text-transform: uppercase;
}
.ln-preview-title { font-size: 22px; font-weight: 700; letter-spacing: -0.5px; margin-top: 2px; }
.ln-preview-badge {
  font-size: 11px; font-weight: 700; letter-spacing: 0.3px; text-transform: uppercase;
  color: var(--q-success); background: rgba(47,106,75,0.12);
  padding: 4px 8px; border-radius: 6px; white-space: nowrap;
}

.ln-preview-scan { display: flex; flex-direction: column; gap: 8px; }
.ln-preview-tabs {
  display: inline-flex; align-self: flex-start; gap: 2px; padding: 3px;
  background: var(--q-surface-muted); border-radius: var(--q-radius-pill);
}
.ln-preview-tab {
  border: none; background: transparent; padding: 5px 12px;
  font-size: 12px; font-weight: 600; font-family: inherit; cursor: pointer;
  color: var(--q-ink-muted); border-radius: var(--q-radius-pill);
}
.ln-preview-tab:hover { color: var(--q-ink); }
.ln-preview-tab.is-active { background: var(--q-surface); color: var(--q-ink); box-shadow: 0 1px 2px rgba(0,0,0,0.04); }

.ln-preview-plan {
  aspect-ratio: 16 / 9; background: var(--q-scan-accent-soft);
  border-radius: 14px; overflow: hidden; position: relative;
}
.ln-preview-plan > div { height: 100% !important; background: transparent !important; border: none !important; border-radius: 0 !important; }
.ln-preview-plan canvas { display: block; width: 100% !important; height: 100% !important; }
.ln-preview-plan-empty {
  height: 100%; width: 100%;
  background:
    repeating-linear-gradient(45deg, var(--q-scan-accent) 0 1px, transparent 1px 10px),
    var(--q-scan-accent-soft);
  opacity: 0.35;
}
.ln-preview-iframe {
  width: 100%; height: 100%; border: 0; display: block; background: #000;
}
.ln-preview-bid {
  display: flex; align-items: center; gap: 12px; padding: 10px 12px;
  background: var(--q-surface-muted); border-radius: 12px;
}
.ln-preview-mark {
  width: 28px; height: 28px; border-radius: 7px; color: #fff;
  display: flex; align-items: center; justify-content: center;
  font-size: 11px; font-weight: 700; flex-shrink: 0;
}
.ln-preview-bid-body { flex: 1; font-size: 13px; min-width: 0; }
.ln-preview-bid-name { font-weight: 600; color: var(--q-ink); }
.ln-preview-bid-line { color: var(--q-ink-muted); font-size: 12px; }
.ln-preview-bid-amt { font-size: 15px; font-weight: 700; letter-spacing: -0.3px; font-variant-numeric: tabular-nums; }

/* How it works */
.ln-how { max-width: 1280px; margin: 0 auto; padding: 56px 64px 0; }
.ln-how-label {
  font-size: 12px; font-weight: 700; color: var(--q-ink-muted);
  letter-spacing: 0.8px; text-transform: uppercase; margin-bottom: 16px;
}
.ln-how-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
.ln-step {
  padding: 20px 22px; border-top: 1px solid var(--q-ink);
  background: var(--q-surface);
}
.ln-step-n {
  font-size: 11px; font-weight: 700; color: var(--q-ink-muted); letter-spacing: 0.6px;
}
.ln-step-t { font-size: 22px; font-weight: 700; letter-spacing: -0.5px; margin-top: 6px; }
.ln-step-d { font-size: 14px; color: var(--q-ink-muted); margin-top: 8px; line-height: 1.45; }

.ln-footer {
  padding: 56px 24px 32px; text-align: center;
  font-size: 13px; color: var(--q-ink-muted);
}
.ln-footer a { color: var(--q-ink-muted); }

@media (max-width: 860px) {
  .ln-hero { grid-template-columns: 1fr; padding: 32px 16px 0; gap: 24px; }
  .ln-title { font-size: 44px; letter-spacing: -1.2px; }
  .ln-sub { font-size: 15px; }
  .ln-stats { gap: 16px; }
  .ln-stats-sep { border-left: none; padding-left: 0; }
  .ln-how { padding: 40px 16px 0; }
  .ln-how-grid { grid-template-columns: 1fr; gap: 0; }
  .ln-step { border-top: 1px solid var(--q-hairline); }
  .ln-step:first-child { border-top: 1px solid var(--q-ink); }
}
`;
