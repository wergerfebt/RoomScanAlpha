import { Link } from "react-router-dom";
import { useAuth } from "../hooks/useAuth";
import SearchBar from "./SearchBar";
import UserMenu from "./UserMenu";

export default function TopBar() {
  const { user, loading } = useAuth();

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
              background: "linear-gradient(135deg, #0055cc 0%, #0088ff 100%)",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              color: "#fff",
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
        <nav style={{ display: "flex", alignItems: "center", gap: 8, marginLeft: "auto" }}>
          {!loading && !user && (
            <Link to="/login" className="btn btn-primary" style={{ whiteSpace: "nowrap" }}>
              Sign In
            </Link>
          )}
          {!loading && user && <UserMenu />}
        </nav>
      </div>
    </header>
  );
}
