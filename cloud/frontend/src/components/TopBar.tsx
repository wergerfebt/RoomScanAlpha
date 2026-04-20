import { Link } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import { useAccount } from "../hooks/useAccount";
import SearchBar from "./SearchBar";
import UserMenu from "./UserMenu";

function getInitials(name: string | null): string {
  if (!name) return "?";
  return name.split(/\s+/).map((w) => w[0]).slice(0, 2).join("").toUpperCase();
}

export default function TopBar() {
  const { user, loading } = useAuth();
  const { account } = useAccount();
  const org = account?.org;

  return (
    <header
      style={{
        background: "var(--color-surface)",
        borderBottom: "1px solid var(--color-border)",
        padding: "10px 24px",
        position: "sticky",
        top: 0,
        zIndex: 500,
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 16,
        }}
      >
        {/* Logo */}
        <Link
          to="/"
          style={{
            display: "flex",
            alignItems: "center",
            gap: 8,
            textDecoration: "none",
            flexShrink: 0,
          }}
        >
          <div
            style={{
              width: 36,
              height: 36,
              borderRadius: 8,
              background: "var(--q-primary)",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              color: "var(--q-primary-ink)",
              fontSize: 18,
              fontWeight: 800,
            }}
          >
            Q
          </div>
          <span className="topbar-wordmark">
            Quoterra
          </span>
        </Link>

        {/* Search */}
        <SearchBar />

        {/* Nav links */}
        <nav style={{ display: "flex", alignItems: "center", gap: 10, marginLeft: "auto" }}>
          {!loading && user && (
            <Link to="/inbox" className="topbar-icon-btn" aria-label="Inbox" title="Inbox">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                <path d="M22 12h-6l-2 3h-4l-2-3H2" />
                <path d="M5.45 5.11L2 12v6a2 2 0 002 2h16a2 2 0 002-2v-6l-3.45-6.89A2 2 0 0016.76 4H7.24a2 2 0 00-1.79 1.11z" />
              </svg>
            </Link>
          )}
          {!loading && user && org && (
            <Link to="/org?tab=jobs" className="topbar-workspace-chip" title={`Switch to ${org.name} workspace`}>
              <span className="topbar-workspace-icon">
                {org.icon_url ? (
                  <img src={org.icon_url} alt="" />
                ) : (
                  <span>{getInitials(org.name)}</span>
                )}
              </span>
              <span className="topbar-workspace-label">Workspace</span>
            </Link>
          )}
          {!loading && !user && (
            <Link to="/login" className="btn btn-primary" style={{ whiteSpace: "nowrap" }}>
              Sign In
            </Link>
          )}
          {!loading && user && <UserMenu />}
        </nav>
        <style>{WORKSPACE_CHIP_CSS}</style>
      </div>
    </header>
  );
}

const WORKSPACE_CHIP_CSS = `
.topbar-workspace-chip {
  display: inline-flex; align-items: center; gap: 8px;
  padding: 4px 12px 4px 4px; border-radius: 999px;
  background: var(--q-surface); color: var(--q-ink);
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
  text-decoration: none; font-size: 13px; font-weight: 600;
  transition: background 0.15s;
}
.topbar-workspace-chip:hover { background: var(--q-surface-muted); text-decoration: none; }
.topbar-workspace-icon {
  width: 26px; height: 26px; border-radius: 6px; overflow: hidden;
  background: var(--q-primary-soft); color: var(--q-primary);
  display: flex; align-items: center; justify-content: center;
  font-size: 10px; font-weight: 700; flex-shrink: 0;
}
.topbar-workspace-icon img { width: 26px; height: 26px; object-fit: cover; }
.topbar-icon-btn {
  width: 36px; height: 36px; border-radius: 50%;
  display: inline-flex; align-items: center; justify-content: center;
  color: var(--q-ink-soft); text-decoration: none;
  transition: background 0.15s, color 0.15s;
}
.topbar-icon-btn:hover { background: var(--q-surface-muted); color: var(--q-ink); text-decoration: none; }
@media (max-width: 640px) {
  .topbar-workspace-label { display: none; }
  .topbar-workspace-chip { padding: 4px; }
}
`;
