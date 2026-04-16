import { useEffect, useState, type FormEvent } from "react";
import { useSearchParams } from "react-router-dom";
import Layout from "../components/Layout";
import JobCard, { type Job } from "../components/JobCard";
import { apiFetch } from "../api/client";
import AddressAutocomplete from "../components/AddressAutocomplete";
import Lightbox, { type LightboxItem } from "../components/Lightbox";

interface OrgData {
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
  role: string;
}

interface GalleryImage {
  id: string;
  image_type: string;
  image_url: string | null;
  before_image_url: string | null;
  caption: string | null;
  sort_order: number;
  media_type: string;
  album_id: string | null;
  album_title: string | null;
}

interface Album {
  id: string;
  title: string;
  description: string | null;
  service_id: string | null;
  rfq_id: string | null;
  created_at: string | null;
  service_name: string | null;
}

interface Member {
  id: string;
  name: string | null;
  email: string;
  icon_url: string | null;
  role: string;
  invite_status: string;
}

interface Service {
  id: string;
  name: string;
  description?: string | null;
}

interface OrgService {
  id: string;
  name: string;
  years_experience: number | null;
}

type Tab = "jobs" | "settings" | "gallery" | "members" | "services";

export default function OrgDashboard() {
  const [org, setOrg] = useState<OrgData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [params] = useSearchParams();
  const tab = (params.get("tab") || "jobs") as Tab;

  useEffect(() => {
    apiFetch<OrgData>("/api/org")
      .then(setOrg)
      .catch((err) => setError(err.message || "Not a member of any organization"))
      .finally(() => setLoading(false));
  }, []);

  if (loading) {
    return <Layout><div className="page-loading"><div className="spinner" /></div></Layout>;
  }

  if (error || !org) {
    return (
      <Layout>
        <div className="empty-state">
          <h3>No Organization</h3>
          <p>{error || "You are not a member of any contractor organization."}</p>
        </div>
      </Layout>
    );
  }

  return (
    <Layout>
      <div style={{ maxWidth: 800, margin: "0 auto", padding: "32px 24px 60px" }}>
        {tab === "jobs" && <OrgJobs />}
        {tab === "settings" && <OrgSettings org={org} onUpdate={setOrg} />}
        {tab === "gallery" && <OrgGallery />}
        {tab === "members" && <OrgMembers />}
        {tab === "services" && <OrgServices />}
      </div>
    </Layout>
  );
}


const JOB_STATUSES = ["all", "new", "pending", "won", "lost"] as const;

function OrgJobs() {
  const [jobs, setJobs] = useState<Job[]>([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState<string>("all");

  useEffect(() => {
    apiFetch<{ jobs: Job[] }>("/api/org/jobs")
      .then((data) => setJobs(data.jobs))
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  const filtered = filter === "all" ? jobs : jobs.filter((j) => j.job_status === filter);

  const counts = {
    all: jobs.length,
    new: jobs.filter((j) => j.job_status === "new").length,
    pending: jobs.filter((j) => j.job_status === "pending").length,
    won: jobs.filter((j) => j.job_status === "won").length,
    lost: jobs.filter((j) => j.job_status === "lost").length,
  };

  if (loading) return <div className="page-loading"><div className="spinner" /></div>;

  return (
    <div>
      {/* Status filter chips */}
      <div style={{ display: "flex", gap: 8, marginBottom: 20, flexWrap: "wrap" }}>
        {JOB_STATUSES.map((s) => (
          <button
            key={s}
            onClick={() => setFilter(s)}
            style={{
              padding: "6px 16px",
              fontSize: 13,
              fontWeight: 600,
              fontFamily: "inherit",
              borderRadius: 20,
              border: "1px solid",
              borderColor: filter === s ? "var(--color-primary)" : "var(--color-border)",
              background: filter === s ? "var(--color-primary)" : "var(--color-surface)",
              color: filter === s ? "#fff" : "var(--color-text)",
              cursor: "pointer",
              textTransform: "capitalize",
              transition: "all 0.15s",
            }}
          >
            {s === "all" ? "All" : s.charAt(0).toUpperCase() + s.slice(1)} ({counts[s]})
          </button>
        ))}
      </div>

      {filtered.length === 0 && (
        <div className="empty-state">
          <h3>{filter === "all" ? "No jobs yet" : `No ${filter} jobs`}</h3>
          <p>Jobs from homeowners will appear here as they post projects.</p>
        </div>
      )}

      {filtered.map((job) => (
        <JobCard key={`${job.rfq_id}-${job.job_status}`} job={job} />
      ))}
    </div>
  );
}


const DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];

function OrgSettings({ org, onUpdate }: { org: OrgData; onUpdate: (o: OrgData) => void }) {
  const [name, setName] = useState(org.name);
  const [description, setDescription] = useState(org.description || "");
  const [address, setAddress] = useState(org.address || "");
  const [website, setWebsite] = useState(org.website_url || "");
  const [yelp, setYelp] = useState(org.yelp_url || "");
  const [google, setGoogle] = useState(org.google_reviews_url || "");
  const [radius, setRadius] = useState(String(org.service_radius_miles || ""));
  const [hours, setHours] = useState<Record<string, string>>(org.business_hours || {});
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [iconUrl, setIconUrl] = useState(org.icon_url);
  const [bannerUrl, setBannerUrl] = useState(org.banner_image_url);

  async function handleSave(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setMessage("");
    try {
      await apiFetch("/api/org", {
        method: "PUT",
        body: JSON.stringify({
          name, description, address,
          website_url: website, yelp_url: yelp, google_reviews_url: google,
          service_radius_miles: radius ? parseFloat(radius) : null,
          business_hours: hours,
        }),
      });
      const updated = await apiFetch<OrgData>("/api/org");
      onUpdate(updated);
      setMessage("Saved");
      setTimeout(() => setMessage(""), 2000);
    } catch {
      setMessage("Failed to save");
    } finally {
      setSaving(false);
    }
  }

  async function uploadImage(endpoint: string, file: File, onDone: (url: string) => void, saveField: string) {
    const fileType = file.type || "image/jpeg";
    const { upload_url, blob_path, content_type } = await apiFetch<{
      upload_url: string; blob_path: string; content_type: string;
    }>(`${endpoint}?content_type=${encodeURIComponent(fileType)}`);
    await fetch(upload_url, { method: "PUT", headers: { "Content-Type": content_type }, body: file });
    await apiFetch("/api/org", { method: "PUT", body: JSON.stringify({ [saveField]: blob_path }) });
    const updated = await apiFetch<OrgData>("/api/org");
    onDone(saveField === "icon_url" ? updated.icon_url! : updated.banner_image_url!);
    onUpdate(updated);
  }

  const fieldStyle = { marginBottom: 14 };
  const labelStyle = { display: "block" as const, fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 };

  return (
    <div>
      {/* Banner */}
      <div className="card" style={{ overflow: "hidden", marginBottom: 20 }}>
        <div style={{
          height: 140, background: bannerUrl
            ? `url(${bannerUrl}) center/cover no-repeat`
            : "linear-gradient(135deg, #0055cc 0%, #0088ff 100%)",
          display: "flex", alignItems: "flex-end", justifyContent: "flex-end", padding: 12,
        }}>
          <label className="btn" style={{ fontSize: 12, padding: "4px 12px", cursor: "pointer", background: "rgba(255,255,255,0.9)" }}>
            Change Banner
            <input type="file" accept="image/*" style={{ display: "none" }}
              onChange={async (e) => {
                const f = e.target.files?.[0]; if (!f) return;
                try { await uploadImage("/api/org/banner-upload-url", f, setBannerUrl, "banner_image_url"); }
                catch { setMessage("Banner upload failed"); }
                e.target.value = "";
              }} />
          </label>
        </div>

        {/* Logo */}
        <div style={{ display: "flex", alignItems: "center", gap: 16, padding: "16px 24px" }}>
          <div style={{
            width: 72, height: 72, borderRadius: 12, background: "var(--color-info-bg)",
            display: "flex", alignItems: "center", justifyContent: "center",
            fontSize: 24, fontWeight: 700, color: "var(--color-primary)", overflow: "hidden", flexShrink: 0,
          }}>
            {iconUrl ? <img src={iconUrl} alt="" style={{ width: 72, height: 72, objectFit: "cover" }} /> : org.name[0].toUpperCase()}
          </div>
          <div>
            <label className="btn" style={{ fontSize: 13, padding: "6px 14px", cursor: "pointer" }}>
              Change Logo
              <input type="file" accept="image/*" style={{ display: "none" }}
                onChange={async (e) => {
                  const f = e.target.files?.[0]; if (!f) return;
                  try { await uploadImage("/api/org/icon-upload-url", f, setIconUrl, "icon_url"); }
                  catch { setMessage("Logo upload failed"); }
                  e.target.value = "";
                }} />
            </label>
            <p style={{ fontSize: 12, color: "var(--color-text-muted)", marginTop: 4 }}>JPG, PNG, or WebP</p>
          </div>
        </div>
      </div>

      {/* Profile form */}
      <div className="card" style={{ padding: 24, marginBottom: 20 }}>
        <h3 style={{ fontSize: 16, fontWeight: 700, marginBottom: 16 }}>Profile</h3>
        <form onSubmit={handleSave}>
          <div style={fieldStyle}>
            <label style={labelStyle}>Company Name</label>
            <input className="form-input" value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <div style={fieldStyle}>
            <label style={labelStyle}>About / Description</label>
            <textarea className="form-input" value={description} onChange={(e) => setDescription(e.target.value)} rows={4} style={{ resize: "vertical" }} />
          </div>
          <div style={fieldStyle}>
            <label style={labelStyle}>Website</label>
            <input className="form-input" value={website} onChange={(e) => setWebsite(e.target.value)} placeholder="https://..." />
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 14, ...fieldStyle }}>
            <div><label style={labelStyle}>Yelp URL</label><input className="form-input" value={yelp} onChange={(e) => setYelp(e.target.value)} placeholder="Yelp page" /></div>
            <div><label style={labelStyle}>Google Reviews URL</label><input className="form-input" value={google} onChange={(e) => setGoogle(e.target.value)} placeholder="Google reviews" /></div>
          </div>

          <h3 style={{ fontSize: 16, fontWeight: 700, margin: "24px 0 16px" }}>Location & Service Area</h3>
          <div style={{ display: "grid", gridTemplateColumns: "2fr 1fr", gap: 14, ...fieldStyle }}>
            <div><label style={labelStyle}>Address</label><AddressAutocomplete value={address} onChange={setAddress} placeholder="Business address" types={["address"]} /></div>
            <div><label style={labelStyle}>Job Radius (miles)</label><input className="form-input" type="number" value={radius} onChange={(e) => setRadius(e.target.value)} placeholder="e.g. 30" /></div>
          </div>

          <h3 style={{ fontSize: 16, fontWeight: 700, margin: "24px 0 16px" }}>Business Hours</h3>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, ...fieldStyle }}>
            {DAYS.map((day) => (
              <div key={day} style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{ width: 80, fontSize: 13, textTransform: "capitalize", color: "var(--color-text-secondary)" }}>{day}</span>
                <input className="form-input" value={hours[day] || ""} onChange={(e) => setHours({ ...hours, [day]: e.target.value })}
                  placeholder="e.g. 8AM - 5PM" style={{ flex: 1, padding: "6px 10px", fontSize: 13 }} />
              </div>
            ))}
          </div>

          <div style={{ display: "flex", alignItems: "center", gap: 12, marginTop: 8 }}>
            <button className="btn btn-primary" type="submit" disabled={saving}>{saving ? "Saving..." : "Save"}</button>
            {message && <span style={{ fontSize: 13, fontWeight: 600, color: message === "Saved" ? "var(--color-success)" : "var(--color-danger)" }}>{message}</span>}
          </div>

          <div style={{ marginTop: 12 }}>
            <a href={`/contractors/${org.id}`} target="_blank" style={{ fontSize: 13, fontWeight: 600 }}>
              View public profile &rarr;
            </a>
          </div>
        </form>
      </div>

      {/* Delete org */}
      <div style={{ borderTop: "1px solid var(--color-border-light)", marginTop: 24, paddingTop: 24 }}>
        <h3 style={{ fontSize: 14, fontWeight: 700, color: "var(--color-danger)", marginBottom: 8 }}>Danger Zone</h3>
        <p style={{ fontSize: 13, color: "var(--color-text-muted)", marginBottom: 12 }}>
          Permanently delete this organization and remove all members.
        </p>
        <button
          className="btn"
          style={{ color: "var(--color-danger)", borderColor: "var(--color-danger)" }}
          onClick={async () => {
            if (!confirm(`Delete "${org.name}"? This cannot be undone.`)) return;
            try {
              await apiFetch("/api/org", { method: "DELETE" });
              window.location.href = "/account";
            } catch (err: unknown) {
              alert((err as Error).message || "Failed to delete");
            }
          }}
        >
          Delete Organization
        </button>
      </div>
    </div>
  );
}


function OrgGallery() {
  const [media, setMedia] = useState<GalleryImage[]>([]);
  const [albums, setAlbums] = useState<Album[]>([]);
  const [services, setServices] = useState<Service[]>([]);
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [caption, setCaption] = useState("");
  const [uploadAlbumId, setUploadAlbumId] = useState<string>("");
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);
  const [uploadMsg, setUploadMsg] = useState("");

  // Album creation
  const [showNewAlbum, setShowNewAlbum] = useState(false);
  const [newAlbumTitle, setNewAlbumTitle] = useState("");
  const [newAlbumServiceId, setNewAlbumServiceId] = useState("");
  const [creatingAlbum, setCreatingAlbum] = useState(false);

  // Before/After upload
  const [showBA, setShowBA] = useState(false);
  const [baBeforeFile, setBaBeforeFile] = useState<File | null>(null);
  const [baAfterFile, setBaAfterFile] = useState<File | null>(null);
  const [baCaption, setBaCaption] = useState("");
  const [baAlbumId, setBaAlbumId] = useState("");
  const [baUploading, setBaUploading] = useState(false);

  // Filter
  const [filterAlbum, setFilterAlbum] = useState<string>("all");

  async function refresh() {
    const [galleryData, svcData] = await Promise.all([
      apiFetch<{ media: GalleryImage[]; albums: Album[] }>("/api/org/gallery"),
      apiFetch<{ services: Service[] }>("/api/services"),
    ]);
    setMedia(galleryData.media);
    setAlbums(galleryData.albums);
    setServices(svcData.services);
  }

  useEffect(() => {
    refresh().catch(() => {}).finally(() => setLoading(false));
  }, []);

  async function handleUpload(files: FileList) {
    setUploading(true);
    setUploadMsg("");
    const total = files.length;
    let uploaded = 0;
    let failed = 0;

    for (let i = 0; i < files.length; i++) {
      const file = files[i];
      setUploadMsg(`Uploading ${i + 1} of ${total}...`);
      try {
        const fileType = file.type || "image/jpeg";
        const isVideo = fileType.startsWith("video/");
        const { upload_url, blob_path, content_type } = await apiFetch<{
          upload_url: string; blob_path: string; image_id: string; content_type: string;
        }>(`/api/org/gallery/upload-url?content_type=${encodeURIComponent(fileType)}`);

        await fetch(upload_url, { method: "PUT", headers: { "Content-Type": content_type }, body: file });

        const gcsUrl = `https://storage.googleapis.com/roomscanalpha-scans/${blob_path}`;
        await apiFetch("/api/org/gallery", {
          method: "POST",
          body: JSON.stringify({
            image_url: gcsUrl,
            image_type: "single",
            caption: total === 1 ? (caption.trim() || null) : null,
            media_type: isVideo ? "video" : "image",
            album_id: uploadAlbumId || null,
          }),
        });
        uploaded++;
      } catch {
        failed++;
      }
    }

    await refresh();
    setCaption("");
    if (failed === 0) {
      setUploadMsg(`${uploaded} file${uploaded !== 1 ? "s" : ""} uploaded!`);
    } else {
      setUploadMsg(`${uploaded} uploaded, ${failed} failed`);
    }
    setTimeout(() => setUploadMsg(""), 3000);
    setUploading(false);
  }

  async function handleDelete(id: string) {
    await apiFetch(`/api/org/gallery/${id}`, { method: "DELETE" });
    setMedia(media.filter((m) => m.id !== id));
  }

  async function handleCreateAlbum(e: FormEvent) {
    e.preventDefault();
    if (!newAlbumTitle.trim()) return;
    setCreatingAlbum(true);
    try {
      await apiFetch("/api/org/albums", {
        method: "POST",
        body: JSON.stringify({
          title: newAlbumTitle.trim(),
          service_id: newAlbumServiceId || null,
        }),
      });
      await refresh();
      setNewAlbumTitle("");
      setNewAlbumServiceId("");
      setShowNewAlbum(false);
    } catch {}
    setCreatingAlbum(false);
  }

  async function handleBAUpload(e: FormEvent) {
    e.preventDefault();
    if (!baBeforeFile || !baAfterFile) return;
    setBaUploading(true);
    try {
      // Upload both files
      const [beforeUpload, afterUpload] = await Promise.all([
        apiFetch<{ upload_url: string; blob_path: string; content_type: string }>(
          `/api/org/gallery/upload-url?content_type=${encodeURIComponent(baBeforeFile.type || "image/jpeg")}`
        ),
        apiFetch<{ upload_url: string; blob_path: string; content_type: string }>(
          `/api/org/gallery/upload-url?content_type=${encodeURIComponent(baAfterFile.type || "image/jpeg")}`
        ),
      ]);
      await Promise.all([
        fetch(beforeUpload.upload_url, { method: "PUT", headers: { "Content-Type": beforeUpload.content_type }, body: baBeforeFile }),
        fetch(afterUpload.upload_url, { method: "PUT", headers: { "Content-Type": afterUpload.content_type }, body: baAfterFile }),
      ]);
      // Create gallery record with both URLs
      await apiFetch("/api/org/gallery", {
        method: "POST",
        body: JSON.stringify({
          image_url: afterUpload.blob_path,
          before_image_url: beforeUpload.blob_path,
          image_type: "before_after",
          caption: baCaption.trim() || null,
          media_type: "image",
          album_id: baAlbumId || null,
        }),
      });
      await refresh();
      setBaBeforeFile(null);
      setBaAfterFile(null);
      setBaCaption("");
      setBaAlbumId("");
      setShowBA(false);
    } catch {}
    setBaUploading(false);
  }

  async function handleDeleteAlbum(id: string) {
    if (!confirm("Delete this album? Media will be kept but unlinked.")) return;
    await apiFetch(`/api/org/albums/${id}`, { method: "DELETE" });
    await refresh();
  }

  if (loading) return <div className="page-loading"><div className="spinner" /></div>;

  const filtered = filterAlbum === "all"
    ? media
    : filterAlbum === "unlinked"
      ? media.filter((m) => !m.album_id)
      : media.filter((m) => m.album_id === filterAlbum);

  return (
    <div>
      {/* Upload form */}
      <div className="card" style={{ padding: 24, marginBottom: 20 }}>
        <h3 style={{ fontSize: 16, fontWeight: 700, marginBottom: 12 }}>Add Photo or Video</h3>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "flex-end" }}>
          <div style={{ flex: 1, minWidth: 160 }}>
            <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>Caption</label>
            <input className="form-input" value={caption} onChange={(e) => setCaption(e.target.value)} placeholder="Optional caption" />
          </div>
          <div style={{ minWidth: 140 }}>
            <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>Album</label>
            <select className="form-input" value={uploadAlbumId} onChange={(e) => setUploadAlbumId(e.target.value)}>
              <option value="">No album</option>
              {albums.map((a) => <option key={a.id} value={a.id}>{a.title}</option>)}
            </select>
          </div>
          <label className="btn btn-primary" style={{ cursor: uploading ? "not-allowed" : "pointer", opacity: uploading ? 0.6 : 1 }}>
            {uploading ? "Uploading..." : "Choose Files"}
            <input type="file" accept="image/*,video/mp4,video/quicktime,video/webm" multiple style={{ display: "none" }} disabled={uploading}
              onChange={(e) => { const f = e.target.files; if (f && f.length) handleUpload(f); e.target.value = ""; }} />
          </label>
        </div>
        {uploadMsg && <p style={{ fontSize: 13, marginTop: 8, color: uploadMsg.includes("failed") ? "var(--color-danger)" : "var(--color-success)" }}>{uploadMsg}</p>}
      </div>

      {/* Albums section */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 12, flexWrap: "wrap", gap: 8 }}>
        <h3 style={{ fontSize: 16, fontWeight: 700 }}>Albums</h3>
        <div style={{ display: "flex", gap: 8 }}>
          <button className="btn" style={{ fontSize: 13, padding: "6px 14px" }} onClick={() => { setShowBA(!showBA); if (!showBA) setShowNewAlbum(false); }}>
            {showBA ? "Cancel" : "+ Before & After"}
          </button>
          <button className="btn" style={{ fontSize: 13, padding: "6px 14px" }} onClick={() => { setShowNewAlbum(!showNewAlbum); if (!showNewAlbum) setShowBA(false); }}>
            {showNewAlbum ? "Cancel" : "+ New Album"}
          </button>
        </div>
      </div>

      {showNewAlbum && (
        <form onSubmit={handleCreateAlbum} className="card" style={{ padding: 16, marginBottom: 16, display: "flex", gap: 8, flexWrap: "wrap" }}>
          <input className="form-input" value={newAlbumTitle} onChange={(e) => setNewAlbumTitle(e.target.value)}
            placeholder="Album title" style={{ flex: 1, minWidth: 160 }} />
          <select className="form-input" value={newAlbumServiceId} onChange={(e) => setNewAlbumServiceId(e.target.value)} style={{ width: 160 }}>
            <option value="">Service tag (optional)</option>
            {services.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
          <button className="btn btn-primary" type="submit" disabled={creatingAlbum || !newAlbumTitle.trim()}>
            {creatingAlbum ? "Creating..." : "Create"}
          </button>
        </form>
      )}

      {showBA && (
        <form onSubmit={handleBAUpload} className="card" style={{ padding: 16, marginBottom: 16 }}>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12, marginBottom: 12 }}>
            <div>
              <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>Before</label>
              <input type="file" accept="image/*" onChange={(e) => setBaBeforeFile(e.target.files?.[0] || null)}
                style={{ fontSize: 13, width: "100%" }} />
            </div>
            <div>
              <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>After</label>
              <input type="file" accept="image/*" onChange={(e) => setBaAfterFile(e.target.files?.[0] || null)}
                style={{ fontSize: 13, width: "100%" }} />
            </div>
          </div>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            <input className="form-input" value={baCaption} onChange={(e) => setBaCaption(e.target.value)}
              placeholder="Caption (optional)" style={{ flex: 1, minWidth: 140 }} />
            <select className="form-input" value={baAlbumId} onChange={(e) => setBaAlbumId(e.target.value)} style={{ width: 160 }}>
              <option value="">Album (optional)</option>
              {albums.map((a) => <option key={a.id} value={a.id}>{a.title}</option>)}
            </select>
            <button className="btn btn-primary" type="submit" disabled={baUploading || !baBeforeFile || !baAfterFile}>
              {baUploading ? "Uploading..." : "Upload"}
            </button>
          </div>
        </form>
      )}

      {albums.length > 0 && (
        <div style={{ display: "flex", gap: 8, marginBottom: 20, flexWrap: "wrap" }}>
          <button onClick={() => setFilterAlbum("all")}
            className={filterAlbum === "all" ? "btn btn-primary" : "btn"} style={{ fontSize: 12, padding: "4px 12px" }}>All</button>
          <button onClick={() => setFilterAlbum("unlinked")}
            className={filterAlbum === "unlinked" ? "btn btn-primary" : "btn"} style={{ fontSize: 12, padding: "4px 12px" }}>Unlinked</button>
          {albums.map((a) => (
            <div key={a.id} style={{ display: "flex", alignItems: "center", gap: 4 }}>
              <button onClick={() => setFilterAlbum(a.id)}
                className={filterAlbum === a.id ? "btn btn-primary" : "btn"} style={{ fontSize: 12, padding: "4px 12px" }}>
                {a.title}{a.service_name ? ` (${a.service_name})` : ""}
              </button>
              <button onClick={() => handleDeleteAlbum(a.id)}
                style={{ background: "none", border: "none", color: "var(--color-text-muted)", cursor: "pointer", fontSize: 14, padding: 0 }}>&times;</button>
            </div>
          ))}
        </div>
      )}

      {/* Media grid */}
      {filtered.length === 0 && (
        <div className="empty-state">
          <h3>No media{filterAlbum !== "all" ? " in this album" : " yet"}</h3>
          <p>Upload photos and videos of your work to showcase on your profile.</p>
        </div>
      )}

      {(() => {
        const viewable = filtered.filter((g) => g.image_url);
        const lbItems: LightboxItem[] = viewable.map((g) => ({
          url: g.image_url!,
          beforeUrl: g.before_image_url,
          type: g.before_image_url ? "before_after" : (g.media_type === "video" ? "video" : "image"),
        }));
        return (
          <>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(200px, 1fr))", gap: 16 }}>
              {viewable.map((item, i) => (
                <div key={item.id} className="card" style={{ overflow: "hidden" }}>
                  {item.media_type === "video" ? (
                    <div style={{ position: "relative", cursor: "pointer" }} onClick={() => setLightboxIndex(i)}>
                      <video src={item.image_url!} style={{ width: "100%", height: 160, objectFit: "cover", display: "block" }} muted preload="metadata" />
                      <div style={{
                        position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center",
                        background: "rgba(0,0,0,0.2)",
                      }}>
                        <div style={{ width: 40, height: 40, borderRadius: "50%", background: "rgba(0,0,0,0.6)",
                          display: "flex", alignItems: "center", justifyContent: "center" }}>
                          <span style={{ color: "#fff", fontSize: 18, marginLeft: 3 }}>&#9654;</span>
                        </div>
                      </div>
                    </div>
                  ) : (
                    <div style={{ position: "relative", cursor: "pointer" }} onClick={() => setLightboxIndex(i)}>
                      <img src={item.image_url!} alt={item.caption || ""}
                        style={{ width: "100%", height: 160, objectFit: "cover", display: "block" }} />
                      {item.before_image_url && (
                        <span style={{
                          position: "absolute", bottom: 6, left: 6, fontSize: 11, fontWeight: 700,
                          color: "#fff", background: "rgba(0,0,0,0.6)", padding: "2px 6px",
                          borderRadius: 4,
                        }}>B/A</span>
                      )}
                    </div>
                  )}
                  <div style={{ padding: 12 }}>
                    {item.caption && <p style={{ fontSize: 13, color: "var(--color-text-secondary)", marginBottom: 4 }}>{item.caption}</p>}
                    {item.album_title && (
                      <p style={{ fontSize: 11, color: "var(--color-primary)", marginBottom: 4 }}>{item.album_title}</p>
                    )}
                    <button onClick={() => handleDelete(item.id)}
                      style={{ fontSize: 12, fontWeight: 600, color: "var(--color-danger)", background: "none", border: "none", cursor: "pointer", fontFamily: "inherit" }}>
                      Delete
                    </button>
                  </div>
                </div>
              ))}
            </div>

            {lightboxIndex !== null && lbItems.length > 0 && (
              <Lightbox
                items={lbItems}
                startIndex={lightboxIndex}
                onClose={() => setLightboxIndex(null)}
                onIndexChange={(i) => setLightboxIndex(i)}
              />
            )}
          </>
        );
      })()}
    </div>
  );
}


function OrgMembers() {
  const [members, setMembers] = useState<Member[]>([]);
  const [loading, setLoading] = useState(true);
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteRole, setInviteRole] = useState("user");
  const [inviting, setInviting] = useState(false);
  const [inviteMsg, setInviteMsg] = useState("");

  useEffect(() => {
    apiFetch<{ members: Member[] }>("/api/org/members")
      .then((data) => setMembers(data.members))
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  async function handleInvite(e: FormEvent) {
    e.preventDefault();
    if (!inviteEmail.trim()) return;
    setInviting(true);
    setInviteMsg("");
    try {
      await apiFetch("/api/org/members/invite", {
        method: "POST",
        body: JSON.stringify({ email: inviteEmail.trim(), role: inviteRole }),
      });
      setInviteMsg(`Invite sent to ${inviteEmail}`);
      setInviteEmail("");
      // Refresh member list
      const data = await apiFetch<{ members: Member[] }>("/api/org/members");
      setMembers(data.members);
    } catch {
      setInviteMsg("Failed to send invite");
    } finally {
      setInviting(false);
    }
  }

  if (loading) return <div className="page-loading"><div className="spinner" /></div>;

  return (
    <div>
      {/* Invite form */}
      <div className="card" style={{ padding: 24, marginBottom: 20 }}>
        <h3 style={{ fontSize: 16, fontWeight: 700, marginBottom: 12 }}>Invite a Team Member</h3>
        <form onSubmit={handleInvite} style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <input
            className="form-input"
            type="email"
            value={inviteEmail}
            onChange={(e) => setInviteEmail(e.target.value)}
            placeholder="Email address"
            style={{ flex: 1, minWidth: 200 }}
          />
          <select
            className="form-input"
            value={inviteRole}
            onChange={(e) => setInviteRole(e.target.value)}
            style={{ width: 100 }}
          >
            <option value="user">Member</option>
            <option value="admin">Admin</option>
          </select>
          <button className="btn btn-primary" type="submit" disabled={inviting || !inviteEmail.trim()}>
            {inviting ? "Sending..." : "Invite"}
          </button>
        </form>
        {inviteMsg && (
          <p style={{ fontSize: 13, marginTop: 8, color: inviteMsg.includes("Failed") ? "var(--color-danger)" : "var(--color-success)" }}>
            {inviteMsg}
          </p>
        )}
      </div>

      {/* Member list */}
      <div className="card" style={{ padding: 24 }}>
        <h3 style={{ fontSize: 16, fontWeight: 700, marginBottom: 16 }}>Team Members</h3>
        {members.length === 0 && (
          <p style={{ fontSize: 14, color: "var(--color-text-muted)" }}>No members yet.</p>
        )}
        {members.map((m) => (
          <div key={m.id} style={{ display: "flex", alignItems: "center", gap: 12, padding: "10px 0", borderBottom: "1px solid var(--color-border-light)" }}>
            <div style={{
              width: 32, height: 32, borderRadius: "50%", background: "var(--color-info-bg)",
              display: "flex", alignItems: "center", justifyContent: "center",
              fontSize: 13, fontWeight: 700, color: "var(--color-primary)", overflow: "hidden",
            }}>
              {m.icon_url ? <img src={m.icon_url} alt="" style={{ width: 32, height: 32, objectFit: "cover" }} /> : (m.name || m.email)[0].toUpperCase()}
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 14, fontWeight: 600 }}>{m.name || m.email}</div>
              <div style={{ fontSize: 12, color: "var(--color-text-muted)" }}>{m.role} &middot; {m.invite_status}</div>
            </div>
            <button
              onClick={async () => {
                if (!confirm(`Remove ${m.name || m.email}?`)) return;
                try {
                  await apiFetch(`/api/org/members/${m.id}`, { method: "DELETE" });
                  setMembers(members.filter((x) => x.id !== m.id));
                } catch (err: unknown) {
                  alert((err as Error).message || "Failed to remove");
                }
              }}
              style={{
                fontSize: 12, fontWeight: 600, color: "var(--color-danger)",
                background: "none", border: "none", cursor: "pointer", fontFamily: "inherit",
              }}
            >
              Remove
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}


function OrgServices() {
  const [allServices, setAllServices] = useState<Service[]>([]);
  const [, setOrgServices] = useState<OrgService[]>([]);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => {
    Promise.all([
      apiFetch<{ services: Service[] }>("/api/services"),
      apiFetch<{ services: OrgService[] }>("/api/org/services"),
    ])
      .then(([all, org]) => {
        setAllServices(all.services);
        setOrgServices(org.services);
        setSelected(new Set(org.services.map((s) => s.id)));
      })
      .catch(() => {})
      .finally(() => setLoading(false));
  }, []);

  function toggle(id: string) {
    const next = new Set(selected);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setSelected(next);
  }

  async function handleSave() {
    setSaving(true);
    setMessage("");
    try {
      await apiFetch("/api/org/services", {
        method: "PUT",
        body: JSON.stringify({ service_ids: Array.from(selected) }),
      });
      setMessage("Saved");
      setTimeout(() => setMessage(""), 2000);
    } catch {
      setMessage("Failed to save");
    } finally {
      setSaving(false);
    }
  }

  if (loading) return <div className="page-loading"><div className="spinner" /></div>;

  return (
    <div className="card" style={{ padding: 24 }}>
      <h3 style={{ fontSize: 16, fontWeight: 700, marginBottom: 4 }}>Services You Offer</h3>
      <p style={{ fontSize: 13, color: "var(--color-text-muted)", marginBottom: 16 }}>
        Select the services your organization provides.
      </p>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(200px, 1fr))", gap: 8, marginBottom: 20 }}>
        {allServices.map((s) => (
          <label
            key={s.id}
            style={{
              display: "flex", alignItems: "center", gap: 8, padding: "10px 12px",
              border: `1px solid ${selected.has(s.id) ? "var(--color-primary)" : "var(--color-border)"}`,
              borderRadius: "var(--radius-md)", cursor: "pointer",
              background: selected.has(s.id) ? "var(--color-info-bg)" : "transparent",
              transition: "all 0.15s",
            }}
          >
            <input type="checkbox" checked={selected.has(s.id)} onChange={() => toggle(s.id)} style={{ accentColor: "var(--color-primary)" }} />
            <span style={{ fontSize: 14 }}>{s.name}</span>
          </label>
        ))}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <button className="btn btn-primary" onClick={handleSave} disabled={saving}>{saving ? "Saving..." : "Save Services"}</button>
        {message && <span style={{ fontSize: 13, fontWeight: 600, color: message === "Saved" ? "var(--color-success)" : "var(--color-danger)" }}>{message}</span>}
      </div>
    </div>
  );
}
