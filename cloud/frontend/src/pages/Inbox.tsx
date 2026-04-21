import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import Layout from "../components/Layout";
import { apiFetch } from "../api/client";
import { getIdToken } from "../api/firebase";

// --- Types ---

type Role = "homeowner" | "org";

interface Counterpart {
  type: "org" | "homeowner";
  id: string;
  name: string | null;
  email?: string | null;
  icon_url: string | null;
}

interface ThreadSummary {
  id: string;
  rfq_id: string;
  rfq_title: string;
  rfq_address: string | null;
  counterpart: Counterpart;
  last_message_at: string | null;
  last_message_preview: string | null;
  last_message_side: "homeowner" | "org" | "system" | null;
  unread_count: number;
  kind: "rfq" | "bid" | "won" | "msg";
  kind_label: string;
  latest_bid: { id: string; price_cents: number; status: string | null } | null;
  created_at: string | null;
}

interface Attachment {
  blob_path: string;
  download_url?: string | null;
  content_type: string | null;
  name: string | null;
  size_bytes: number | null;
}

interface Message {
  id: string;
  side: "homeowner" | "org" | "system";
  kind: "text" | "event" | "bid";
  body: string | null;
  event_type: string | null;
  bid_id: string | null;
  bid_snapshot: { price_cents?: number; status?: string; description?: string } | null;
  attachments: Attachment[];
  created_at: string | null;
  sender: { id: string; name: string | null; email: string | null; icon_url: string | null } | null;
}

interface ConversationDetail {
  id: string;
  rfq: { id: string; title: string; address: string | null };
  homeowner: { id: string; name: string | null; email: string | null; icon_url: string | null };
  org: { id: string; name: string | null; icon_url: string | null };
  participants: Array<{ id: string; name: string | null; email: string | null; icon_url: string | null; role: string }>;
  messages: Message[];
  caller_side: Role;
}

// --- Helpers ---

function fmtRelative(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  const now = Date.now();
  const diffMs = now - d.getTime();
  if (diffMs < 60_000) return "just now";
  if (diffMs < 60 * 60_000) return `${Math.floor(diffMs / 60_000)}m ago`;
  if (diffMs < 24 * 60 * 60_000) return `${Math.floor(diffMs / (60 * 60_000))}h ago`;
  if (diffMs < 7 * 24 * 60 * 60_000) return `${Math.floor(diffMs / (24 * 60 * 60_000))}d ago`;
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}

function fmtPriceCents(cents: number): string {
  return "$" + (cents / 100).toLocaleString("en-US", { minimumFractionDigits: 0 });
}

function getInitials(name: string | null): string {
  if (!name) return "?";
  return name.split(/\s+/).map((w) => w[0]).slice(0, 2).join("").toUpperCase();
}

// --- Page ---

export default function Inbox() {
  const [params, setParams] = useSearchParams();
  const navigate = useNavigate();
  // Role hinted by URL: /inbox → homeowner, /org?tab=inbox → org. Server still
  // resolves and returns the effective role, which we honor.
  const urlRole: Role | "auto" = typeof window !== "undefined" && window.location.pathname.startsWith("/org")
    ? "org"
    : "homeowner";

  const [threads, setThreads] = useState<ThreadSummary[]>([]);
  const [effectiveRole, setEffectiveRole] = useState<Role>(urlRole === "org" ? "org" : "homeowner");
  const [loadingList, setLoadingList] = useState(true);
  const [error, setError] = useState("");
  const selectedId = params.get("thread");
  const [detail, setDetail] = useState<ConversationDetail | null>(null);
  const [loadingDetail, setLoadingDetail] = useState(false);

  // Load thread list on mount.
  useEffect(() => {
    let cancelled = false;
    setLoadingList(true);
    apiFetch<{ conversations: ThreadSummary[]; role: Role }>(`/api/inbox?role=${urlRole}`)
      .then((data) => {
        if (cancelled) return;
        setThreads(data.conversations);
        setEffectiveRole(data.role);
        if (!selectedId && data.conversations.length > 0) {
          // Preserve existing params (like ?tab=inbox) when auto-selecting.
          setParams((prev) => {
            prev.set("thread", data.conversations[0].id);
            return prev;
          }, { replace: true });
        }
      })
      .catch((err) => { if (!cancelled) setError((err as Error).message || "Failed to load"); })
      .finally(() => { if (!cancelled) setLoadingList(false); });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [urlRole]);

  // Load selected thread.
  useEffect(() => {
    if (!selectedId) { setDetail(null); return; }
    let cancelled = false;
    setLoadingDetail(true);
    apiFetch<ConversationDetail>(`/api/conversations/${selectedId}`)
      .then((d) => { if (!cancelled) setDetail(d); })
      .catch(() => {})
      .finally(() => { if (!cancelled) setLoadingDetail(false); });
    return () => { cancelled = true; };
  }, [selectedId]);

  // On successful fetch, server already marked caller's side read. Clear the
  // local unread count so the sidebar reflects it.
  useEffect(() => {
    if (!selectedId || !detail) return;
    setThreads((prev) => prev.map((t) => t.id === selectedId ? { ...t, unread_count: 0 } : t));
  }, [selectedId, detail]);

  function handleSelect(threadId: string) {
    setParams((prev) => {
      prev.set("thread", threadId);
      return prev;
    }, { replace: true });
  }

  async function handleSend(body: string, attachments: Attachment[]) {
    if (!selectedId) return;
    const payload = {
      body: body.trim(),
      attachments: attachments.map((a) => ({
        blob_path: a.blob_path,
        content_type: a.content_type,
        name: a.name,
        size_bytes: a.size_bytes,
      })),
    };
    await apiFetch(`/api/conversations/${selectedId}/messages`, {
      method: "POST",
      body: JSON.stringify(payload),
    });
    // Refetch conversation + inbox list to update previews
    const [d, list] = await Promise.all([
      apiFetch<ConversationDetail>(`/api/conversations/${selectedId}`),
      apiFetch<{ conversations: ThreadSummary[]; role: Role }>(`/api/inbox?role=${urlRole}`),
    ]);
    setDetail(d);
    setThreads(list.conversations);
  }

  const totalUnread = useMemo(
    () => threads.reduce((s, t) => s + (t.unread_count || 0), 0),
    [threads],
  );

  return (
    <Layout>
      <div className={`ib ib-role-${effectiveRole} ${selectedId ? "ib-has-selection" : ""}`}>
        {/* Thread list */}
        <aside className="ib-list">
          <div className="ib-list-head">
            <h1 className="ib-title">Inbox</h1>
            {totalUnread > 0 && <span className="ib-unread-total">{totalUnread}</span>}
          </div>

          {loadingList && <div className="ib-empty">Loading…</div>}
          {!loadingList && error && <div className="ib-empty">{error}</div>}
          {!loadingList && !error && threads.length === 0 && (
            <div className="ib-empty">
              <strong>No conversations yet</strong>
              <div>
                {effectiveRole === "homeowner"
                  ? "Reach out to a contractor from their profile to start a message."
                  : "Messages from homeowners appear here when they respond to your bids."}
              </div>
            </div>
          )}

          <div className="ib-rows">
            {threads.map((t) => (
              <ThreadRow
                key={t.id}
                thread={t}
                active={t.id === selectedId}
                onClick={() => handleSelect(t.id)}
              />
            ))}
          </div>
        </aside>

        {/* Conversation view */}
        <section className="ib-conv">
          {!selectedId ? (
            <div className="ib-nosel">Select a conversation to view messages.</div>
          ) : loadingDetail && !detail ? (
            <div className="ib-nosel">Loading…</div>
          ) : detail ? (
            <Conversation
              detail={detail}
              role={effectiveRole}
              onOpenProject={() => {
                if (effectiveRole === "homeowner") {
                  navigate(`/projects/${detail.rfq.id}`);
                } else {
                  navigate(`/org?tab=jobs`);
                }
              }}
              onBack={() => {
                setParams((prev) => {
                  prev.delete("thread");
                  return prev;
                }, { replace: true });
              }}
              onSend={handleSend}
            />
          ) : null}
        </section>
      </div>
      <style>{IB_CSS}</style>
    </Layout>
  );
}

// --- Thread row ---

function ThreadRow({ thread, active, onClick }: { thread: ThreadSummary; active: boolean; onClick: () => void }) {
  const cp = thread.counterpart;
  return (
    <button type="button" className={`ib-row ${active ? "is-active" : ""}`} onClick={onClick}>
      <div className="ib-row-avatar">
        {cp.icon_url ? (
          <img src={cp.icon_url} alt="" />
        ) : (
          <span>{getInitials(cp.name)}</span>
        )}
        {thread.unread_count > 0 && <span className="ib-unread-dot" aria-label={`${thread.unread_count} unread`} />}
      </div>
      <div className="ib-row-body">
        <div className="ib-row-head">
          <span className="ib-row-name">{cp.name || "Unknown"}</span>
          <span className="ib-row-time">{fmtRelative(thread.last_message_at || thread.created_at)}</span>
        </div>
        <div className="ib-row-project">{thread.rfq_title}</div>
        <div className={`ib-row-kind ib-kind-${thread.kind}`}>{thread.kind_label}</div>
        {thread.last_message_preview && (
          <div className="ib-row-preview">
            {thread.last_message_side === "homeowner" && <span className="ib-preview-you">You: </span>}
            {thread.last_message_preview}
          </div>
        )}
      </div>
    </button>
  );
}

// --- Conversation ---

function Conversation({ detail, role, onOpenProject, onBack, onSend }: {
  detail: ConversationDetail;
  role: Role;
  onOpenProject: () => void;
  onBack: () => void;
  onSend: (body: string, attachments: Attachment[]) => Promise<void>;
}) {
  const counterpart = role === "homeowner" ? detail.org : detail.homeowner;
  const cpName = counterpart.name || (counterpart as { email?: string }).email || "Unknown";
  const cpIcon = counterpart.icon_url;
  const scrollRef = useRef<HTMLDivElement>(null);

  // Autoscroll to bottom when messages arrive / conversation switches.
  useEffect(() => {
    const el = scrollRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [detail.id, detail.messages.length]);

  return (
    <>
      <header className="ib-conv-head">
        <button type="button" className="ib-back" onClick={onBack} aria-label="Back to inbox">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M15 18l-6-6 6-6" />
          </svg>
        </button>
        <div className="ib-conv-avatar">
          {cpIcon ? (
            <img src={cpIcon} alt="" />
          ) : (
            <span>{getInitials(cpName)}</span>
          )}
        </div>
        <div className="ib-conv-title-wrap">
          <div className="ib-conv-title">{cpName}</div>
          <div className="ib-conv-sub">{detail.rfq.title}{detail.rfq.address ? ` · ${detail.rfq.address}` : ""}</div>
        </div>
        <button type="button" className="ib-conv-action" onClick={onOpenProject}>
          {role === "homeowner" ? "Open project" : "View job"}
        </button>
      </header>

      <div className="ib-stream" ref={scrollRef}>
        {detail.messages.map((m) => (
          <MessageItem key={m.id} msg={m} role={role} />
        ))}
        {detail.messages.length === 0 && (
          <div className="ib-empty" style={{ textAlign: "center", padding: 40 }}>
            No messages yet. Say hi.
          </div>
        )}
      </div>

      <Composer conversationId={detail.id} onSend={onSend} />
    </>
  );
}

function MessageItem({ msg, role }: { msg: Message; role: Role }) {
  const mine = msg.side === role;
  if (msg.kind === "event") {
    return (
      <div className="ib-event">
        <span className="ib-event-dot" />
        <span>{formatEventBody(msg)}</span>
        <span className="ib-event-time">{fmtRelative(msg.created_at)}</span>
      </div>
    );
  }
  if (msg.kind === "bid") {
    const snap = msg.bid_snapshot || {};
    return (
      <div className={`ib-msg ${mine ? "is-mine" : ""}`}>
        <div className="ib-bid-card">
          <div className="ib-bid-label">Bid submitted</div>
          {typeof snap.price_cents === "number" && (
            <div className="ib-bid-price">{fmtPriceCents(snap.price_cents)}</div>
          )}
          {snap.description && <div className="ib-bid-desc">{snap.description}</div>}
        </div>
        <div className="ib-msg-time">{fmtRelative(msg.created_at)}</div>
      </div>
    );
  }
  // Text
  return (
    <div className={`ib-msg ${mine ? "is-mine" : ""}`}>
      <div className="ib-bubble">
        {msg.body && <div className="ib-bubble-text">{msg.body}</div>}
        {msg.attachments.length > 0 && (
          <div className="ib-bubble-atts">
            {msg.attachments.map((a, i) => <AttachmentView key={a.blob_path + i} att={a} />)}
          </div>
        )}
      </div>
      <div className="ib-msg-time">{fmtRelative(msg.created_at)}</div>
    </div>
  );
}

function AttachmentView({ att }: { att: Attachment }) {
  const url = att.download_url || undefined;
  const isImage = (att.content_type || "").startsWith("image/");
  const isPdf = (att.content_type || "") === "application/pdf";
  const filename = att.name || (isPdf ? "Document.pdf" : "Attachment");

  async function triggerDownload(e: React.MouseEvent) {
    if (!url) return;
    e.preventDefault();
    try {
      const resp = await fetch(url);
      const blob = await resp.blob();
      const objectUrl = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = objectUrl;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(objectUrl);
    } catch {
      // Cross-origin download failed — fall back to opening in new tab.
      window.open(url, "_blank", "noopener,noreferrer");
    }
  }

  if (isImage && url) {
    return (
      <div className="ib-att ib-att-image">
        <a href={url} target="_blank" rel="noopener noreferrer" aria-label={`Open ${filename}`}>
          <img src={url} alt={filename} />
        </a>
        <button
          type="button"
          className="ib-att-download"
          onClick={triggerDownload}
          aria-label={`Download ${filename}`}
          title="Download"
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4" /><path d="M7 10l5 5 5-5" /><path d="M12 15V3" />
          </svg>
        </button>
      </div>
    );
  }

  return (
    <div className="ib-att ib-att-file">
      <span className="ib-att-ico">{isPdf ? "PDF" : "FILE"}</span>
      <div className="ib-att-info">
        <a href={url} target="_blank" rel="noopener noreferrer" className="ib-att-name">{filename}</a>
        {att.size_bytes ? (
          <span className="ib-att-size">{fmtFileSize(att.size_bytes)}</span>
        ) : null}
      </div>
      <button type="button" className="ib-att-download" onClick={triggerDownload} title="Download" aria-label={`Download ${filename}`}>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4" /><path d="M7 10l5 5 5-5" /><path d="M12 15V3" />
        </svg>
      </button>
    </div>
  );
}

function fmtFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function formatEventBody(m: Message): string {
  if (m.body) return m.body;
  switch (m.event_type) {
    case "bid_submitted": return "Contractor submitted a bid.";
    case "bid_accepted":  return "Bid accepted.";
    case "bid_rejected":  return "Bid not selected.";
    case "rfq_updated":   return "Homeowner updated the project.";
    default:              return m.event_type || "Event";
  }
}

// --- Composer ---

function Composer({ conversationId, onSend }: { conversationId: string; onSend: (body: string, attachments: Attachment[]) => Promise<void> }) {
  const [text, setText] = useState("");
  const [pending, setPending] = useState<Attachment[]>([]);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState("");

  async function addFile(file: File) {
    setError("");
    try {
      const token = await getIdToken();
      const res = await fetch(
        `/api/conversations/${conversationId}/attachment-upload-url?content_type=${encodeURIComponent(file.type)}&filename=${encodeURIComponent(file.name)}`,
        { headers: { Authorization: `Bearer ${token}` } },
      );
      if (!res.ok) throw new Error(`Upload URL failed (${res.status})`);
      const { upload_url, blob_path } = await res.json();
      const put = await fetch(upload_url, {
        method: "PUT",
        headers: { "Content-Type": file.type },
        body: file,
      });
      if (!put.ok) throw new Error(`Upload failed (${put.status})`);
      setPending((prev) => [...prev, {
        blob_path, content_type: file.type, name: file.name, size_bytes: file.size,
      }]);
    } catch (err) {
      setError((err as Error).message || "Upload failed");
    }
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!text.trim() && pending.length === 0) return;
    setSending(true);
    setError("");
    try {
      await onSend(text, pending);
      setText("");
      setPending([]);
    } catch (err) {
      setError((err as Error).message || "Send failed");
    }
    setSending(false);
  }

  return (
    <form className="ib-composer" onSubmit={submit}>
      {pending.length > 0 && (
        <div className="ib-pending-atts">
          {pending.map((a, i) => (
            <div key={a.blob_path} className="ib-pending-chip">
              <span>{a.name || "File"}</span>
              <button type="button" className="ib-pending-x" onClick={() => setPending((prev) => prev.filter((_, j) => j !== i))}>×</button>
            </div>
          ))}
        </div>
      )}
      {error && <div className="ib-composer-error">{error}</div>}
      <div className="ib-composer-row">
        <label className="ib-attach-btn" title="Attach image or PDF">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M21.44 11.05l-9.19 9.19a6 6 0 01-8.49-8.49l9.19-9.19a4 4 0 015.66 5.66l-9.2 9.19a2 2 0 01-2.83-2.83l8.49-8.48" />
          </svg>
          <input
            type="file"
            accept="image/*,application/pdf"
            style={{ display: "none" }}
            onChange={(e) => {
              const f = e.target.files?.[0];
              if (f) addFile(f);
              e.target.value = "";
            }}
          />
        </label>
        <textarea
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="Message…"
          rows={1}
          className="ib-composer-input"
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              submit(e as unknown as FormEvent);
            }
          }}
        />
        <button type="submit" className="ib-send" disabled={sending || (!text.trim() && pending.length === 0)}>
          {sending ? "Sending…" : "Send"}
        </button>
      </div>
    </form>
  );
}

// Expose navigation so TopBar can deep-link
export function inboxPathForRole(role: Role): string {
  return role === "org" ? "/org?tab=inbox" : "/inbox";
}

// Helper so the Link import above stays used even without direct JSX usage here.
void Link;

// --- CSS ---

const IB_CSS = `
.ib {
  display: grid; grid-template-columns: 340px 1fr;
  height: calc(100dvh - 56px); background: var(--q-canvas); overflow: hidden;
}
/* Mobile: show either the list OR the conversation, not both. The body has
   .ib-has-selection when a thread is selected. */
@media (max-width: 760px) {
  .ib { grid-template-columns: 1fr; }
  /* Regular TopBar is ~56px; contractor top bar wraps to ~96px on mobile. */
  .ib-role-homeowner { height: calc(100dvh - 56px); }
  .ib-role-org { height: calc(100dvh - 96px); }
  .ib-has-selection .ib-list { display: none; }
  .ib:not(.ib-has-selection) .ib-conv { display: none; }
}
.ib-back {
  display: none; width: 36px; height: 36px; margin-right: 4px;
  border: none; background: transparent; cursor: pointer;
  color: var(--q-ink); border-radius: 50%;
  align-items: center; justify-content: center; flex-shrink: 0;
}
.ib-back:hover { background: var(--q-surface-muted); }
@media (max-width: 760px) { .ib-back { display: inline-flex; } }

/* List */
.ib-list {
  border-right: 0.5px solid var(--q-hairline); background: var(--q-surface);
  display: flex; flex-direction: column; overflow: hidden;
}
.ib-list-head {
  display: flex; align-items: baseline; justify-content: space-between;
  padding: 22px 22px 12px; border-bottom: 0.5px solid var(--q-divider);
}
.ib-title { font-size: 26px; font-weight: 700; letter-spacing: -0.8px; margin: 0; }
.ib-unread-total {
  background: var(--q-primary); color: var(--q-primary-ink);
  font-size: 12px; font-weight: 700; padding: 2px 8px; border-radius: 999px;
}
.ib-empty {
  padding: 28px 22px; color: var(--q-ink-muted); font-size: 13px; line-height: 1.5;
}
.ib-empty strong { display: block; color: var(--q-ink); font-size: 15px; margin-bottom: 4px; }

.ib-rows { flex: 1; overflow-y: auto; }
.ib-row {
  display: flex; gap: 12px; padding: 14px 22px; width: 100%; text-align: left;
  border: none; background: transparent; font-family: inherit; cursor: pointer;
  border-top: 0.5px solid var(--q-divider); border-left: 3px solid transparent;
  color: var(--q-ink); transition: background 0.12s;
}
.ib-row:hover { background: var(--q-surface-muted); }
.ib-row.is-active { background: var(--q-primary-soft); border-left-color: var(--q-primary); }

.ib-row-avatar {
  width: 40px; height: 40px; border-radius: 10px; flex-shrink: 0;
  background: var(--q-primary-soft); color: var(--q-primary);
  display: flex; align-items: center; justify-content: center;
  font-size: 13px; font-weight: 700; overflow: hidden; position: relative;
}
.ib-row-avatar img { width: 40px; height: 40px; object-fit: cover; }
.ib-unread-dot {
  position: absolute; top: -2px; right: -2px; width: 10px; height: 10px;
  border-radius: 50%; background: var(--q-primary);
  box-shadow: 0 0 0 2px var(--q-surface);
}

.ib-row-body { flex: 1; min-width: 0; }
.ib-row-head {
  display: flex; align-items: baseline; justify-content: space-between; gap: 8px;
}
.ib-row-name {
  font-size: 14px; font-weight: 700; letter-spacing: -0.2px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.ib-row-time { font-size: 11px; color: var(--q-ink-muted); flex-shrink: 0; }
.ib-row-project {
  font-size: 12px; color: var(--q-ink-soft); margin-top: 2px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.ib-row-kind {
  display: inline-block; margin-top: 5px; font-size: 10px; font-weight: 700;
  padding: 2px 7px; border-radius: 999px; letter-spacing: 0.3px; text-transform: uppercase;
}
.ib-kind-rfq { background: #DCE8FF; color: #1E3FA5; }
.ib-kind-bid { background: #FFEAC2; color: #8A5A00; }
.ib-kind-won { background: var(--q-primary-soft); color: var(--q-primary); }
.ib-kind-msg { background: var(--q-surface-muted); color: var(--q-ink-muted); box-shadow: inset 0 0 0 0.5px var(--q-hairline); }

.ib-row-preview {
  font-size: 12px; color: var(--q-ink-muted); margin-top: 4px; line-height: 1.4;
  overflow: hidden; text-overflow: ellipsis;
  display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;
}
.ib-preview-you { color: var(--q-ink-dim); font-weight: 500; }

/* Conversation */
.ib-conv { display: flex; flex-direction: column; overflow: hidden; }
.ib-conv-head {
  display: flex; align-items: center; gap: 12px; padding: 16px 24px;
  border-bottom: 0.5px solid var(--q-hairline); background: var(--q-surface);
}
.ib-conv-avatar {
  width: 40px; height: 40px; border-radius: 10px; flex-shrink: 0; overflow: hidden;
  background: var(--q-primary-soft); color: var(--q-primary);
  display: flex; align-items: center; justify-content: center;
  font-size: 13px; font-weight: 700;
}
.ib-conv-avatar img { width: 40px; height: 40px; object-fit: cover; }
.ib-conv-title-wrap { flex: 1; min-width: 0; }
.ib-conv-title {
  font-size: 16px; font-weight: 700; letter-spacing: -0.2px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.ib-conv-sub {
  font-size: 12px; color: var(--q-ink-muted); margin-top: 2px;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.ib-conv-action {
  padding: 8px 14px; font-size: 13px; font-weight: 600; font-family: inherit;
  border: 0.5px solid var(--q-hairline); background: var(--q-surface);
  color: var(--q-ink); border-radius: 999px; cursor: pointer;
}
.ib-conv-action:hover { background: var(--q-surface-muted); }

.ib-nosel {
  flex: 1; display: flex; align-items: center; justify-content: center;
  color: var(--q-ink-muted); font-size: 13px;
}

.ib-stream {
  flex: 1; overflow-y: auto; padding: 24px 24px 12px;
  display: flex; flex-direction: column; gap: 10px;
}

/* Messages */
.ib-msg { display: flex; flex-direction: column; max-width: 72%; align-self: flex-start; }
.ib-msg.is-mine { align-self: flex-end; align-items: flex-end; }
.ib-bubble {
  background: var(--q-surface); color: var(--q-ink); padding: 10px 14px;
  border-radius: 14px; box-shadow: inset 0 0 0 0.5px var(--q-hairline);
  font-size: 14px; line-height: 1.45; word-wrap: break-word;
}
.ib-msg.is-mine .ib-bubble {
  background: var(--q-primary); color: var(--q-primary-ink); box-shadow: none;
}
.ib-bubble-text { white-space: pre-wrap; }
.ib-bubble-atts { display: flex; flex-direction: column; gap: 8px; margin-top: 8px; }
.ib-bubble:has(.ib-att-image:only-child) { padding: 4px; }

.ib-att-image {
  position: relative; display: block; border-radius: 12px; overflow: hidden;
  line-height: 0;
}
.ib-att-image img {
  display: block; width: 100%; height: auto;
  max-height: 320px; object-fit: cover; border-radius: 12px;
}
.ib-att-download {
  position: absolute; top: 8px; right: 8px; width: 28px; height: 28px;
  border-radius: 50%; border: none; cursor: pointer;
  background: rgba(20, 26, 22, 0.6); color: #fff;
  display: flex; align-items: center; justify-content: center;
  opacity: 0; transition: opacity 0.15s, background 0.15s;
  backdrop-filter: blur(6px);
}
.ib-att-image:hover .ib-att-download { opacity: 1; }
.ib-att-download:hover { background: rgba(20, 26, 22, 0.85); }

.ib-att-file {
  display: flex; align-items: center; gap: 10px; padding: 8px 10px;
  background: rgba(255,255,255,0.18); color: inherit;
  border-radius: 10px; font-size: 12px;
}
.ib-msg:not(.is-mine) .ib-att-file { background: var(--q-surface-muted); }
.ib-att-ico {
  font-size: 9px; font-weight: 800; padding: 3px 5px; border-radius: 4px;
  background: #C8342C; color: #fff; letter-spacing: 0.3px; flex-shrink: 0;
}
.ib-att-info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.ib-att-name {
  font-size: 13px; font-weight: 600; color: inherit; text-decoration: none;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.ib-att-name:hover { text-decoration: underline; }
.ib-att-size { font-size: 11px; opacity: 0.7; }
.ib-att-file .ib-att-download {
  position: static; opacity: 1; width: 28px; height: 28px;
  background: rgba(0,0,0,0.08); color: inherit;
  backdrop-filter: none; flex-shrink: 0;
}
.ib-att-file .ib-att-download:hover { background: rgba(0,0,0,0.16); }
.ib-msg.is-mine .ib-att-file .ib-att-download { background: rgba(255,255,255,0.2); color: #fff; }
.ib-msg.is-mine .ib-att-file .ib-att-download:hover { background: rgba(255,255,255,0.32); }
.ib-msg-time {
  font-size: 10px; color: var(--q-ink-muted); margin-top: 4px; padding: 0 4px;
}

/* Event separator */
.ib-event {
  align-self: center; display: flex; align-items: center; gap: 8px;
  font-size: 11px; color: var(--q-ink-muted); padding: 6px 12px;
  background: var(--q-surface); border-radius: 999px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
  margin: 4px 0;
}
.ib-event-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--q-ink-dim); }
.ib-event-time { color: var(--q-ink-dim); }

/* Bid card inside conversation */
.ib-bid-card {
  background: var(--q-surface); border-radius: 14px; padding: 14px 16px;
  box-shadow: inset 0 0 0 1.5px var(--q-primary-soft);
  min-width: 200px;
}
.ib-msg.is-mine .ib-bid-card {
  background: var(--q-primary-soft); color: var(--q-primary);
  box-shadow: inset 0 0 0 1.5px var(--q-primary);
}
.ib-bid-label {
  font-size: 11px; font-weight: 700; color: var(--q-ink-muted);
  letter-spacing: 0.5px; text-transform: uppercase;
}
.ib-msg.is-mine .ib-bid-label { color: var(--q-primary); }
.ib-bid-price { font-size: 26px; font-weight: 700; letter-spacing: -0.6px; margin-top: 2px; font-variant-numeric: tabular-nums; color: var(--q-ink); }
.ib-msg.is-mine .ib-bid-price { color: var(--q-primary); }
.ib-bid-desc { font-size: 13px; color: var(--q-ink-soft); margin-top: 6px; line-height: 1.45; }
.ib-msg.is-mine .ib-bid-desc { color: var(--q-ink); }

/* Composer */
.ib-composer {
  padding: 12px 20px 18px; border-top: 0.5px solid var(--q-hairline);
  background: var(--q-surface);
}
.ib-pending-atts { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 8px; }
.ib-pending-chip {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 4px 10px; background: var(--q-surface-muted); border-radius: 999px;
  font-size: 12px; color: var(--q-ink-soft);
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
}
.ib-pending-x {
  border: none; background: transparent; color: var(--q-ink-muted); cursor: pointer;
  font-size: 14px; padding: 0; line-height: 1;
}
.ib-composer-error {
  font-size: 12px; color: var(--q-danger); margin-bottom: 6px;
}
.ib-composer-row {
  display: flex; gap: 8px; align-items: flex-end;
  background: var(--q-surface-muted); border-radius: 14px; padding: 6px 8px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
}
.ib-attach-btn {
  width: 34px; height: 34px; border-radius: 8px; cursor: pointer;
  display: flex; align-items: center; justify-content: center;
  color: var(--q-ink-muted); flex-shrink: 0;
}
.ib-attach-btn:hover { background: var(--q-surface); color: var(--q-ink); }
.ib-composer-input {
  flex: 1; border: none; background: transparent; outline: none;
  font-family: inherit; font-size: 14px; color: var(--q-ink);
  resize: none; padding: 9px 6px; line-height: 1.4; max-height: 160px;
}
.ib-composer-input::placeholder { color: var(--q-ink-dim); }
.ib-send {
  padding: 9px 18px; border: none; background: var(--q-primary);
  color: var(--q-primary-ink); font-size: 13px; font-weight: 700;
  font-family: inherit; border-radius: 999px; cursor: pointer; flex-shrink: 0;
}
.ib-send:disabled { opacity: 0.5; cursor: not-allowed; }
.ib-send:hover:not(:disabled) { filter: brightness(0.92); }
`;
