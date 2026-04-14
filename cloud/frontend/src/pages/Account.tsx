import { useEffect, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import Layout from "../components/Layout";
import { apiFetch } from "../api/client";

interface AccountData {
  id: string;
  email: string;
  name: string | null;
  phone: string | null;
  account_type: string;
  icon_url: string | null;
  address: string | null;
  notification_preferences: Record<string, boolean>;
  org: { id: string; name: string; role: string } | null;
}

export default function Account() {
  const [account, setAccount] = useState<AccountData | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");

  // Form fields
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [address, setAddress] = useState("");

  // Org request
  const [orgName, setOrgName] = useState("");
  const [orgRequesting, setOrgRequesting] = useState(false);
  const [orgMessage, setOrgMessage] = useState("");

  useEffect(() => {
    apiFetch<AccountData>("/api/account")
      .then((data) => {
        setAccount(data);
        setName(data.name || "");
        setPhone(data.phone || "");
        setAddress(data.address || "");
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  async function handleSave(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setMessage("");
    try {
      await apiFetch("/api/account", {
        method: "PUT",
        body: JSON.stringify({ name, phone, address }),
      });
      setMessage("Saved");
      setTimeout(() => setMessage(""), 2000);
    } catch {
      setMessage("Failed to save");
    } finally {
      setSaving(false);
    }
  }

  async function handleOrgRequest(e: FormEvent) {
    e.preventDefault();
    if (!orgName.trim()) return;
    setOrgRequesting(true);
    setOrgMessage("");
    try {
      await apiFetch("/api/account/request-org", {
        method: "POST",
        body: JSON.stringify({ org_name: orgName.trim() }),
      });
      setOrgMessage("Request submitted! We'll review and get back to you.");
    } catch {
      setOrgMessage("Failed to submit request");
    } finally {
      setOrgRequesting(false);
    }
  }

  if (loading) {
    return (
      <Layout>
        <div className="page-loading"><div className="spinner" /></div>
      </Layout>
    );
  }

  return (
    <Layout>
      <div style={{ maxWidth: 600, margin: "0 auto", padding: "32px 24px 60px" }}>
        <h1 style={{ fontSize: 24, fontWeight: 700, marginBottom: 24 }}>Account Settings</h1>

        {/* Profile form */}
        <div className="card" style={{ padding: 24, marginBottom: 20 }}>
          <h2 style={{ fontSize: 16, fontWeight: 700, marginBottom: 16 }}>Profile</h2>

          {/* Profile picture */}
          <div style={{ display: "flex", alignItems: "center", gap: 16, marginBottom: 20 }}>
            <div style={{
              width: 72, height: 72, borderRadius: "50%", background: "var(--color-info-bg)",
              display: "flex", alignItems: "center", justifyContent: "center",
              fontSize: 24, fontWeight: 700, color: "var(--color-primary)", overflow: "hidden",
              flexShrink: 0,
            }}>
              {account?.icon_url
                ? <img src={account.icon_url} alt="" style={{ width: 72, height: 72, objectFit: "cover" }} />
                : (account?.name || account?.email || "?")[0].toUpperCase()
              }
            </div>
            <div>
              <label
                className="btn"
                style={{ fontSize: 13, padding: "6px 14px", cursor: "pointer" }}
              >
                Change Photo
                <input
                  type="file"
                  accept="image/*"
                  style={{ display: "none" }}
                  onChange={async (e) => {
                    const file = e.target.files?.[0];
                    if (!file) return;
                    try {
                      const fileType = file.type || "image/jpeg";
                      const { upload_url, blob_path, content_type } = await apiFetch<{
                        upload_url: string; blob_path: string; content_type: string;
                      }>(`/api/account/icon-upload-url?content_type=${encodeURIComponent(fileType)}`);
                      await fetch(upload_url, { method: "PUT", headers: { "Content-Type": content_type }, body: file });
                      await apiFetch("/api/account", { method: "PUT", body: JSON.stringify({ icon_url: blob_path }) });
                      const updated = await apiFetch<AccountData>("/api/account");
                      setAccount(updated);
                    } catch { setMessage("Photo upload failed"); }
                    e.target.value = "";
                  }}
                />
              </label>
              <p style={{ fontSize: 12, color: "var(--color-text-muted)", marginTop: 4 }}>JPG, PNG, or WebP</p>
            </div>
          </div>

          <form onSubmit={handleSave}>
            <div style={{ marginBottom: 14 }}>
              <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>
                Email
              </label>
              <input className="form-input" value={account?.email || ""} disabled style={{ opacity: 0.6 }} />
            </div>

            <div style={{ marginBottom: 14 }}>
              <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>
                Name
              </label>
              <input className="form-input" value={name} onChange={(e) => setName(e.target.value)} placeholder="Your name" />
            </div>

            <div style={{ marginBottom: 14 }}>
              <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>
                Phone
              </label>
              <input className="form-input" value={phone} onChange={(e) => setPhone(e.target.value)} placeholder="Phone number" />
            </div>

            <div style={{ marginBottom: 14 }}>
              <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>
                Address
              </label>
              <input className="form-input" value={address} onChange={(e) => setAddress(e.target.value)} placeholder="Your address" />
            </div>

            <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
              <button className="btn btn-primary" type="submit" disabled={saving}>
                {saving ? "Saving..." : "Save Changes"}
              </button>
              {message && (
                <span style={{ fontSize: 13, fontWeight: 600, color: message === "Saved" ? "var(--color-success)" : "var(--color-danger)" }}>
                  {message}
                </span>
              )}
            </div>
          </form>
        </div>

        {/* Contractor section — show org link if contractor, or request form if homeowner */}
        {account?.org ? (
          <div className="card" style={{ padding: 24 }}>
            <h2 style={{ fontSize: 16, fontWeight: 700, marginBottom: 12 }}>Your Organization</h2>
            <p style={{ fontSize: 14, color: "var(--color-text-secondary)", marginBottom: 12 }}>
              You are a member of <strong>{account.org.name}</strong> ({account.org.role}).
            </p>
            <Link to="/org" className="btn btn-primary">
              Go to Org Dashboard
            </Link>
          </div>
        ) : account?.account_type === "homeowner" ? (
          <div className="card" style={{ padding: 24 }}>
            <h2 style={{ fontSize: 16, fontWeight: 700, marginBottom: 12 }}>Are you a contractor?</h2>
            <p style={{ fontSize: 14, color: "var(--color-text-secondary)", marginBottom: 16 }}>
              Request a contractor account to submit bids, manage your portfolio, and connect with homeowners.
              Make sure your name, phone, and address are filled in above before requesting.
            </p>
            <form onSubmit={handleOrgRequest}>
              <div style={{ marginBottom: 12 }}>
                <input
                  className="form-input"
                  value={orgName}
                  onChange={(e) => setOrgName(e.target.value)}
                  placeholder="Your company name"
                />
              </div>
              <button className="btn btn-primary" type="submit" disabled={orgRequesting || !orgName.trim()}>
                {orgRequesting ? "Submitting..." : "Request Contractor Account"}
              </button>
              {orgMessage && (
                <p style={{ fontSize: 13, marginTop: 8, color: orgMessage.includes("Failed") ? "var(--color-danger)" : "var(--color-success)" }}>
                  {orgMessage}
                </p>
              )}
            </form>
          </div>
        ) : null}

        {/* Delete account */}
        <div className="card" style={{ padding: 24 }}>
          <h2 style={{ fontSize: 14, fontWeight: 700, color: "var(--color-danger)", marginBottom: 8 }}>Danger Zone</h2>
          <p style={{ fontSize: 13, color: "var(--color-text-muted)", marginBottom: 12 }}>
            Permanently delete your account and all associated data.
          </p>
          <button
            className="btn"
            style={{ color: "var(--color-danger)", borderColor: "var(--color-danger)" }}
            onClick={async () => {
              if (!confirm("Delete your account? This cannot be undone.")) return;
              try {
                await apiFetch("/api/account", { method: "DELETE" });
                const { signOut } = await import("../api/firebase");
                await signOut();
                window.location.href = "/";
              } catch (err: unknown) {
                alert((err as Error).message || "Failed to delete");
              }
            }}
          >
            Delete Account
          </button>
        </div>
      </div>
    </Layout>
  );
}
