import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import Layout from "../components/Layout";
import Lightbox, { type LightboxItem } from "../components/Lightbox";

interface OrgProfile {
  id: string;
  name: string;
  description: string | null;
  address: string | null;
  icon_url: string | null;
  website_url: string | null;
  yelp_url: string | null;
  google_reviews_url: string | null;
  avg_rating: number | null;
  service_lat: number | null;
  service_lng: number | null;
  service_radius_miles: number | null;
  banner_image_url: string | null;
  business_hours: Record<string, string>;
  services: { id: string; name: string }[];
  gallery: {
    id: string; image_url: string | null; before_image_url: string | null; caption: string | null;
    media_type: string; album_title: string | null; service_name: string | null;
  }[];
  team: { name: string | null; icon_url: string | null; role: string }[];
}

const DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
const DAY_LABELS: Record<string, string> = {
  monday: "Mon", tuesday: "Tue", wednesday: "Wed", thursday: "Thu",
  friday: "Fri", saturday: "Sat", sunday: "Sun",
};

function getTodayDay(): string {
  return DAYS[new Date().getDay() === 0 ? 6 : new Date().getDay() - 1];
}

function isOpenNow(hours: Record<string, string>): { open: boolean; todayHours: string } {
  const today = getTodayDay();
  const todayHours = hours[today];
  if (!todayHours || todayHours.toLowerCase() === "closed") {
    return { open: false, todayHours: "Closed" };
  }

  // Try to parse "8AM - 5PM" style hours
  const match = todayHours.match(/(\d{1,2})\s*(am|pm)\s*[-–]\s*(\d{1,2})\s*(am|pm)/i);
  if (!match) return { open: true, todayHours }; // Can't parse, assume open

  const now = new Date();
  const currentMinutes = now.getHours() * 60 + now.getMinutes();

  let openHour = parseInt(match[1]);
  if (match[2].toLowerCase() === "pm" && openHour !== 12) openHour += 12;
  if (match[2].toLowerCase() === "am" && openHour === 12) openHour = 0;

  let closeHour = parseInt(match[3]);
  if (match[4].toLowerCase() === "pm" && closeHour !== 12) closeHour += 12;
  if (match[4].toLowerCase() === "am" && closeHour === 12) closeHour = 0;

  const open = currentMinutes >= openHour * 60 && currentMinutes < closeHour * 60;
  return { open, todayHours };
}

export default function OrgProfilePage() {
  const { orgId } = useParams<{ orgId: string }>();
  const [org, setOrg] = useState<OrgProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);
  const [serviceFilter, setServiceFilter] = useState<string>("all");

  useEffect(() => {
    fetch(`/api/orgs/${orgId}`)
      .then((r) => {
        if (!r.ok) throw new Error("Not found");
        return r.json();
      })
      .then(setOrg)
      .catch((e) => setError(e.message))
      .finally(() => setLoading(false));
  }, [orgId]);

  if (loading) return <Layout><div className="page-loading"><div className="spinner" /></div></Layout>;
  if (error || !org) return <Layout><div className="empty-state" style={{ marginTop: 80 }}><h3>Organization Not Found</h3><p>{error}</p></div></Layout>;

  const serviceNames = [...new Set(org.gallery.map((g) => g.service_name).filter(Boolean))] as string[];
  const filteredGallery = serviceFilter === "all"
    ? org.gallery
    : org.gallery.filter((g) => g.service_name === serviceFilter);

  const hasHours = Object.values(org.business_hours).some((v) => v);
  const openStatus = hasHours ? isOpenNow(org.business_hours) : null;
  const today = getTodayDay();

  return (
    <Layout>
      {/* Banner */}
      <div className="org-profile-banner" style={{
        background: org.banner_image_url
          ? `url(${org.banner_image_url}) center/cover no-repeat`
          : "var(--q-primary)",
      }} />

      {/* Header */}
      <div className="org-profile-header-wrap">
        <div className="org-profile-header">
          <div className="org-profile-icon">
            {org.icon_url
              ? <img src={org.icon_url} alt="" />
              : org.name[0].toUpperCase()
            }
          </div>
          <div className="org-profile-info">
            <h1 className="org-profile-name">{org.name}</h1>
            <div className="org-profile-meta">
              {org.avg_rating && (
                <span style={{ color: "#f5a623", fontWeight: 700 }}>{org.avg_rating.toFixed(1)} &#9733;</span>
              )}
              {org.address && <span style={{ color: "var(--color-text-secondary)" }}>{org.address}</span>}
              {openStatus && (
                <span style={{
                  fontSize: 12, fontWeight: 700, padding: "2px 8px", borderRadius: 4,
                  background: openStatus.open ? "#d4edda" : "#f8d7da",
                  color: openStatus.open ? "#155724" : "#721c24",
                }}>
                  {openStatus.open ? "Open Now" : "Closed"}
                </span>
              )}
            </div>
          </div>
        </div>

        {/* Links */}
        <div className="org-profile-links">
          {org.website_url && <a href={org.website_url} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 13, padding: "6px 14px" }}>Website</a>}
          {org.yelp_url && <a href={org.yelp_url} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 13, padding: "6px 14px" }}>Yelp</a>}
          {org.google_reviews_url && <a href={org.google_reviews_url} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 13, padding: "6px 14px" }}>Google Reviews</a>}
        </div>
      </div>

      <div className="org-profile-body">
        {/* Left column */}
        <div>
          {/* CTA */}
          <section className="card" style={{ padding: 16, marginBottom: 32 }}>
            <h3 style={{ fontSize: 15, fontWeight: 700, marginBottom: 12 }}>Get a Quote</h3>
            <p style={{ fontSize: 13, color: "var(--color-text-secondary)", marginBottom: 12 }}>
              Scan your room with the RoomScanAlpha app and {org.name} can provide a detailed quote.
            </p>
            <a href="/info" className="btn btn-primary btn-full" style={{ fontSize: 14, textDecoration: "none" }}>
              Join the Alpha
            </a>
          </section>

          {/* About */}
          {org.description && (
            <section style={{ marginBottom: 32 }}>
              <h2 style={{ fontSize: 18, fontWeight: 700, marginBottom: 12 }}>About</h2>
              <p style={{ fontSize: 15, lineHeight: 1.7, color: "var(--color-text-secondary)", whiteSpace: "pre-wrap" }}>{org.description}</p>
            </section>
          )}

          {/* Services */}
          {org.services.length > 0 && (
            <section style={{ marginBottom: 32 }}>
              <h2 style={{ fontSize: 18, fontWeight: 700, marginBottom: 12 }}>Services</h2>
              <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                {org.services.map((s) => (
                  <span key={s.id} className="badge badge-info" style={{ fontSize: 13, padding: "5px 12px" }}>{s.name}</span>
                ))}
              </div>
            </section>
          )}

          {/* Gallery */}
          {org.gallery.length > 0 && (
            <section style={{ marginBottom: 32 }}>
              <h2 style={{ fontSize: 18, fontWeight: 700, marginBottom: 12 }}>Portfolio</h2>
              {serviceNames.length > 0 && (
                <div style={{ display: "flex", gap: 6, marginBottom: 16, flexWrap: "wrap" }}>
                  <button onClick={() => setServiceFilter("all")}
                    className={serviceFilter === "all" ? "btn btn-primary" : "btn"}
                    style={{ fontSize: 12, padding: "4px 12px" }}>All</button>
                  {serviceNames.map((s) => (
                    <button key={s} onClick={() => setServiceFilter(s)}
                      className={serviceFilter === s ? "btn btn-primary" : "btn"}
                      style={{ fontSize: 12, padding: "4px 12px" }}>{s}</button>
                  ))}
                </div>
              )}
              {(() => {
                const viewable = filteredGallery.filter((g) => g.image_url);
                const lbItems: LightboxItem[] = viewable.map((g) => ({
                  url: g.image_url!,
                  beforeUrl: g.before_image_url,
                  type: g.before_image_url ? "before_after" : g.media_type,
                }));
                return (
                  <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(180px, 1fr))", gap: 12 }}>
                    {viewable.map((item, i) => (
                      <div key={item.id} style={{ borderRadius: 10, overflow: "hidden", cursor: "pointer", position: "relative" }}
                        onClick={() => setLightboxIndex(i)}>
                        {item.media_type === "video" ? (
                          <>
                            <video src={item.image_url!} style={{ width: "100%", height: 140, objectFit: "cover", display: "block" }} muted preload="metadata" />
                            <div style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center", background: "rgba(0,0,0,0.2)" }}>
                              <div style={{ width: 36, height: 36, borderRadius: "50%", background: "rgba(0,0,0,0.6)", display: "flex", alignItems: "center", justifyContent: "center" }}>
                                <span style={{ color: "#fff", fontSize: 16, marginLeft: 2 }}>&#9654;</span>
                              </div>
                            </div>
                          </>
                        ) : (
                          <img src={item.image_url!} alt={item.caption || ""} style={{ width: "100%", height: 140, objectFit: "cover", display: "block" }} />
                        )}
                        {item.before_image_url && (
                          <span style={{
                            position: "absolute", bottom: 6, left: 6, fontSize: 11, fontWeight: 700,
                            color: "#fff", background: "rgba(0,0,0,0.6)", padding: "2px 6px",
                            borderRadius: 4,
                          }}>B/A</span>
                        )}
                      </div>
                    ))}

                    {lightboxIndex !== null && lbItems.length > 0 && (
                      <Lightbox
                        items={lbItems}
                        startIndex={lightboxIndex}
                        onClose={() => setLightboxIndex(null)}
                        onIndexChange={(i) => setLightboxIndex(i)}
                      />
                    )}
                  </div>
                );
              })()}
            </section>
          )}

          {/* Team */}
          {org.team.length > 0 && (
            <section>
              <h2 style={{ fontSize: 18, fontWeight: 700, marginBottom: 12 }}>Team</h2>
              <div style={{ display: "flex", gap: 16, flexWrap: "wrap" }}>
                {org.team.map((m, i) => (
                  <div key={i} style={{ display: "flex", alignItems: "center", gap: 10 }}>
                    <div style={{
                      width: 36, height: 36, borderRadius: "50%", background: "var(--color-info-bg)",
                      display: "flex", alignItems: "center", justifyContent: "center",
                      fontSize: 14, fontWeight: 700, color: "var(--color-primary)", overflow: "hidden",
                    }}>
                      {m.icon_url ? <img src={m.icon_url} alt="" style={{ width: 36, height: 36, objectFit: "cover" }} /> : (m.name || "?")[0].toUpperCase()}
                    </div>
                    <div>
                      <div style={{ fontSize: 14, fontWeight: 600 }}>{m.name || "Team Member"}</div>
                      <div style={{ fontSize: 12, color: "var(--color-text-muted)", textTransform: "capitalize" }}>{m.role}</div>
                    </div>
                  </div>
                ))}
              </div>
            </section>
          )}
        </div>

        {/* Right sidebar */}
        <div>
          {/* Map */}
          {org.service_lat && org.service_lng && (
            <div className="card" style={{ marginBottom: 16, overflow: "hidden" }}>
              <div id="org-map" style={{ height: 240 }} ref={(el) => {
                if (!el || el.dataset.loaded) return;
                el.dataset.loaded = "1";
                const L = (window as unknown as Record<string, unknown>).L as unknown;
                if (!L) {
                  const link = document.createElement("link");
                  link.rel = "stylesheet";
                  link.href = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css";
                  document.head.appendChild(link);
                  const script = document.createElement("script");
                  script.src = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js";
                  script.onload = () => initMap(el);
                  document.head.appendChild(script);
                } else {
                  initMap(el);
                }
                function initMap(container: HTMLElement) {
                  const LL = (window as unknown as Record<string, unknown>).L as any;
                  const radiusMiles = org!.service_radius_miles || 25;
                  const zoom = radiusMiles > 50 ? 8 : radiusMiles > 20 ? 9 : radiusMiles > 10 ? 10 : 11;
                  const map = LL.map(container).setView([org!.service_lat, org!.service_lng], zoom);
                  LL.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
                    attribution: "&copy; OpenStreetMap",
                  }).addTo(map);
                  LL.marker([org!.service_lat, org!.service_lng]).addTo(map);
                  LL.circle([org!.service_lat, org!.service_lng], {
                    radius: radiusMiles * 1609.34,
                    color: "#0055cc", fillOpacity: 0.08, weight: 2,
                  }).addTo(map);
                }
              }} />
              <div style={{ padding: 14 }}>
                <p style={{ fontSize: 14, fontWeight: 600 }}>{org.address}</p>
                {org.service_radius_miles && (
                  <p style={{ fontSize: 13, color: "var(--color-text-muted)", marginTop: 4 }}>
                    Serves a {org.service_radius_miles}-mile radius
                  </p>
                )}
              </div>
            </div>
          )}

          {/* Business Hours */}
          {hasHours && (
            <div className="card" style={{ padding: 16, marginBottom: 16 }}>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}>
                <h3 style={{ fontSize: 15, fontWeight: 700 }}>Hours</h3>
                {openStatus && (
                  <span style={{
                    fontSize: 12, fontWeight: 700, padding: "2px 8px", borderRadius: 4,
                    background: openStatus.open ? "#d4edda" : "#f8d7da",
                    color: openStatus.open ? "#155724" : "#721c24",
                  }}>
                    {openStatus.open ? "Open" : "Closed"}
                  </span>
                )}
              </div>
              {DAYS.map((day) => {
                const isToday = day === today;
                return (
                  <div key={day} style={{
                    display: "flex", justifyContent: "space-between", padding: "5px 0",
                    fontSize: 13, fontWeight: isToday ? 700 : 400,
                    color: isToday ? "var(--color-text)" : "var(--color-text-secondary)",
                  }}>
                    <span>{DAY_LABELS[day]}</span>
                    <span>{org.business_hours[day] || "Closed"}</span>
                  </div>
                );
              })}
            </div>
          )}

        </div>
      </div>

      {/* Lightbox is now rendered inside the gallery section */}
    </Layout>
  );
}
