import { Link, useLocation, useNavigate } from "react-router-dom";
import UserMenu from "./UserMenu";

interface OrgInfo {
  id: string;
  name: string;
  icon_url: string | null;
}

const NAV_TABS: Array<{ key: string; label: string }> = [
  { key: "inbox",    label: "Inbox" },
  { key: "jobs",     label: "Jobs" },
  { key: "gallery",  label: "Gallery" },
  { key: "members",  label: "Team" },
  { key: "services", label: "Services" },
  { key: "settings", label: "Settings" },
];

function getInitials(name: string | null): string {
  if (!name) return "?";
  return name.split(/\s+/).map((w) => w[0]).slice(0, 2).join("").toUpperCase();
}

export default function ContractorTopBar({ org }: { org: OrgInfo }) {
  const location = useLocation();
  const navigate = useNavigate();
  const params = new URLSearchParams(location.search);
  const activeTab = location.pathname === "/org" ? (params.get("tab") || "jobs") : "jobs";

  return (
    <>
      <header className="ctb">
        {/* Left: logo + wordmark */}
        <div className="ctb-brand">
          <Link to="/" className="ctb-logo" aria-label="Quoterra home">
            <div className="ctb-logo-mark">Q</div>
            <span className="ctb-logo-word">Quoterra</span>
          </Link>

          <div className="ctb-acting">
            <span className="ctb-acting-label">Acting as</span>
            <div className="ctb-acting-chip">
              {org.icon_url ? (
                <img src={org.icon_url} alt="" className="ctb-acting-icon" />
              ) : (
                <div className="ctb-acting-initials">{getInitials(org.name)}</div>
              )}
              <span className="ctb-acting-name">{org.name}</span>
            </div>
          </div>
        </div>

        {/* Center: nav tabs (desktop) */}
        <nav className="ctb-tabs" aria-label="Contractor workspace">
          {NAV_TABS.map((t) => (
            <Link
              key={t.key}
              to={`/org?tab=${t.key}`}
              className={`ctb-tab ${activeTab === t.key ? "is-active" : ""}`}
            >
              {t.label}
            </Link>
          ))}
        </nav>

        {/* Mobile: dropdown picker (uses native <select> so iOS shows the
            scrolling picker). Positioned after the brand, before the avatar. */}
        <div className="ctb-tabs-mobile">
          <select
            aria-label="Workspace section"
            value={activeTab}
            onChange={(e) => navigate(`/org?tab=${e.target.value}`)}
            className="ctb-tabs-select"
          >
            {NAV_TABS.map((t) => (
              <option key={t.key} value={t.key}>{t.label}</option>
            ))}
          </select>
          <svg className="ctb-tabs-caret" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M6 9l6 6 6-6" />
          </svg>
        </div>

        {/* Right: switch back + avatar (dropdown) */}
        <div className="ctb-right">
          <Link to="/projects" className="ctb-switch" title="Go to personal view">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <circle cx="12" cy="8" r="4" /><path d="M4 21a8 8 0 0116 0" />
            </svg>
            <span>Personal · Switch back</span>
          </Link>

          <UserMenu />
        </div>
      </header>
      <style>{CTB_CSS}</style>
    </>
  );
}

const CTB_CSS = `
.ctb {
  display: flex; align-items: center; gap: 20px;
  background: #141A16; color: #F4F3EE;
  padding: 0 20px; height: 56px;
  border-bottom: 0.5px solid rgba(255,255,255,0.08);
  position: sticky; top: 0; z-index: 100;
}
/* Mobile dropdown (native select) — hidden on desktop. */
.ctb-tabs-mobile { display: none; position: relative; }
@media (max-width: 860px) {
  .ctb { padding: 0 12px; gap: 10px; }
  .ctb-tabs { display: none; }
  .ctb-tabs-mobile {
    display: inline-flex; align-items: center;
    background: rgba(255,255,255,0.08);
    box-shadow: inset 0 0 0 0.5px rgba(255,255,255,0.12);
    border-radius: 999px; height: 32px; min-width: 0;
  }
  .ctb-tabs-select {
    appearance: none; -webkit-appearance: none;
    background: transparent; border: none; color: #fff;
    font-size: 13px; font-weight: 600; font-family: inherit;
    padding: 0 24px 0 12px; cursor: pointer; outline: none;
    max-width: 120px;
  }
  .ctb-tabs-select option { color: #141A16; background: #fff; }
  .ctb-tabs-caret {
    position: absolute; right: 8px; top: 50%; transform: translateY(-50%);
    pointer-events: none; color: rgba(255,255,255,0.65);
  }
}

/* Brand */
.ctb-brand { display: flex; align-items: center; gap: 18px; flex-shrink: 0; }
.ctb-logo {
  display: flex; align-items: center; gap: 8px; color: #fff;
  text-decoration: none; padding-right: 4px;
}
.ctb-logo:hover { text-decoration: none; }
.ctb-logo-mark {
  width: 28px; height: 28px; border-radius: 7px;
  background: var(--q-primary); color: var(--q-primary-ink);
  display: flex; align-items: center; justify-content: center;
  font-weight: 800; font-size: 14px;
}
.ctb-logo-word { font-size: 16px; font-weight: 700; letter-spacing: -0.2px; }

.ctb-acting {
  display: flex; align-items: center; gap: 8px;
  padding-left: 16px;
  border-left: 0.5px solid rgba(255,255,255,0.12);
  height: 32px;
}
.ctb-acting-label {
  font-size: 12px; color: rgba(244,243,238,0.6); font-weight: 500;
}
.ctb-acting-chip {
  display: flex; align-items: center; gap: 8px;
  padding: 4px 10px 4px 4px; border-radius: 999px;
  background: rgba(255,255,255,0.08);
  box-shadow: inset 0 0 0 0.5px rgba(255,255,255,0.08);
}
.ctb-acting-icon {
  width: 22px; height: 22px; border-radius: 6px; object-fit: cover;
}
.ctb-acting-initials {
  width: 22px; height: 22px; border-radius: 6px;
  background: var(--q-primary); color: var(--q-primary-ink);
  display: flex; align-items: center; justify-content: center;
  font-size: 10px; font-weight: 700;
}
.ctb-acting-name { font-size: 13px; font-weight: 600; color: #fff; white-space: nowrap; }

/* Tabs */
.ctb-tabs {
  display: flex; align-items: center; gap: 2px; flex: 1; min-width: 0; overflow-x: auto;
}
.ctb-tab {
  padding: 6px 14px; font-size: 13px; font-weight: 600;
  color: rgba(244,243,238,0.65); text-decoration: none;
  border-radius: 8px; white-space: nowrap;
  transition: color 0.15s, background 0.15s;
}
.ctb-tab:hover { color: #fff; background: rgba(255,255,255,0.06); text-decoration: none; }
.ctb-tab.is-active {
  color: #fff; background: rgba(255,255,255,0.12);
  box-shadow: inset 0 0 0 0.5px rgba(255,255,255,0.16);
}

/* Right side */
.ctb-right { display: flex; align-items: center; gap: 12px; flex-shrink: 0; }
.ctb-switch {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 6px 12px; border-radius: 999px;
  background: transparent; color: rgba(244,243,238,0.75);
  text-decoration: none; font-size: 12px; font-weight: 500;
  box-shadow: inset 0 0 0 0.5px rgba(255,255,255,0.14);
  transition: background 0.15s, color 0.15s;
}
.ctb-switch:hover { background: rgba(255,255,255,0.08); color: #fff; text-decoration: none; }

.ctb-avatar {
  width: 32px; height: 32px; border-radius: 50%;
  border: none; padding: 0; overflow: hidden; cursor: pointer;
  background: var(--q-primary-soft); color: var(--q-primary);
  font-size: 12px; font-weight: 700;
  display: flex; align-items: center; justify-content: center;
}
.ctb-avatar img { width: 32px; height: 32px; object-fit: cover; border-radius: 50%; }

.ctb-signout {
  width: 32px; height: 32px; border-radius: 50%;
  border: none; padding: 0; cursor: pointer;
  background: transparent; color: rgba(244,243,238,0.6);
  display: flex; align-items: center; justify-content: center;
  transition: background 0.15s, color 0.15s;
}
.ctb-signout:hover { background: rgba(255,255,255,0.08); color: #fff; }

@media (max-width: 900px) {
  .ctb-acting-label { display: none; }
  .ctb-logo-word { display: none; }
  .ctb-switch span { display: none; }
  .ctb-switch { padding: 6px 8px; }
}
@media (max-width: 640px) {
  .ctb { padding: 0 12px; gap: 10px; }
  .ctb-acting { padding-left: 10px; }
  .ctb-acting-chip { padding: 4px 8px 4px 4px; }
  .ctb-acting-name { font-size: 12px; max-width: 100px; overflow: hidden; text-overflow: ellipsis; }
}
`;
