import { useEffect, useRef, useState, type FormEvent } from "react";
import { getIdToken } from "../api/firebase";
import { apiFetch } from "../api/client";
import type { CarouselAttachment } from "./PhotosCarousel";

interface Props {
  rfqId: string;
  /** bid_id for update mode — required to delete existing attachments. */
  bidId?: string;
  onSubmitted: (bid: { id: string; price_cents: number; description: string }) => void;
  onCancel?: () => void;
  initial?: {
    price_cents?: number;
    timeline?: string;
    start?: string;
    note?: string;
    pdf_url?: string | null;
    attachments?: CarouselAttachment[];
  };
  submitLabel?: string;
}

function pdfNameFromUrl(url: string): string {
  return decodeURIComponent(url.split("?")[0].split("/").pop() || "Project breakdown.pdf");
}

// Parses the "Timeline: 6 weeks · Start: May 5\n\n{note}" prefix we write on submit
// back into structured fields. Returns original description as the note if the
// prefix isn't present.
export function parseBidDescription(description: string | null | undefined): { timeline: string; start: string; note: string } {
  if (!description) return { timeline: "", start: "", note: "" };
  const match = /^Timeline:\s*([^·\n]+?)(?:\s*·\s*Start:\s*([^\n]+))?\n\n([\s\S]*)$/.exec(description);
  if (match) {
    return {
      timeline: match[1].trim(),
      start: (match[2] || "").trim(),
      note: match[3],
    };
  }
  // Also support "Start: ..." alone on a line.
  const startOnly = /^Start:\s*([^\n]+)\n\n([\s\S]*)$/.exec(description);
  if (startOnly) {
    return { timeline: "", start: startOnly[1].trim(), note: startOnly[2] };
  }
  return { timeline: "", start: "", note: description };
}

function fmtFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

export default function ContractorBidForm({ rfqId, bidId, onSubmitted, onCancel, initial, submitLabel }: Props) {
  const [total, setTotal] = useState(initial?.price_cents != null ? String(initial.price_cents / 100) : "");
  const [timeline, setTimeline] = useState(initial?.timeline ?? "");
  const [start, setStart] = useState(initial?.start ?? "");
  const [note, setNote] = useState(initial?.note ?? "");
  const [pdf, setPdf] = useState<File | null>(null);
  // When editing, the existing PDF stays attached unless the user picks a new
  // one via Replace. Null means no existing PDF.
  const [existingPdfUrl, setExistingPdfUrl] = useState<string | null>(initial?.pdf_url ?? null);
  const [existingPdfSize, setExistingPdfSize] = useState<string | null>(null);
  // Bid media: existing attachments (from the server) and newly-selected files
  // pending upload. Existing items delete immediately against the API; new
  // items upload as part of the bid multipart POST.
  const [existingMedia, setExistingMedia] = useState<CarouselAttachment[]>(
    (initial?.attachments ?? []).filter((a) => (a.content_type || "").startsWith("image/")),
  );
  const [newMedia, setNewMedia] = useState<File[]>([]);
  const [deletingBlobPath, setDeletingBlobPath] = useState<string | null>(null);
  const mediaInputRef = useRef<HTMLInputElement>(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");
  const isUpdate = !!initial;

  useEffect(() => {
    if (!existingPdfUrl) return;
    let cancelled = false;
    fetch(existingPdfUrl, { method: "HEAD" })
      .then((r) => {
        const bytes = parseInt(r.headers.get("content-length") || "0", 10);
        if (cancelled || !bytes) return;
        setExistingPdfSize(fmtFileSize(bytes));
      })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [existingPdfUrl]);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError("");
    const totalDollars = parseFloat(total.replace(/[^0-9.]/g, ""));
    if (!totalDollars || totalDollars <= 0) {
      setError("Enter a total amount");
      return;
    }
    if (!note.trim()) {
      setError("Add a note for the customer");
      return;
    }
    // Either a newly-uploaded file or an existing attachment must be present.
    if (!pdf && !existingPdfUrl) {
      setError("Attach a project breakdown PDF");
      return;
    }

    // Until the bids table gets timeline_weeks / start_date columns, fold the
    // fields into the description with a structured prefix. Any viewer can
    // still read the raw text, and a later backend migration can parse them
    // back out.
    const header: string[] = [];
    if (timeline.trim()) header.push(`Timeline: ${timeline.trim()}`);
    if (start.trim())    header.push(`Start: ${start.trim()}`);
    const description = header.length
      ? `${header.join(" · ")}\n\n${note.trim()}`
      : note.trim();

    setSubmitting(true);
    try {
      const token = await getIdToken();
      const formData = new FormData();
      formData.append("price_cents", String(Math.round(totalDollars * 100)));
      formData.append("description", description);
      if (pdf) formData.append("pdf", pdf);
      for (const img of newMedia) formData.append("images", img);
      const res = await fetch(`/api/rfqs/${rfqId}/bids`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
        body: formData,
      });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.detail || `Submit failed (${res.status})`);
      }
      const bid = await res.json();
      onSubmitted({ id: bid.id, price_cents: bid.price_cents, description });
    } catch (err: unknown) {
      setError((err as Error).message || "Submit failed");
    }
    setSubmitting(false);
  }

  return (
    <form className="cbf" onSubmit={handleSubmit}>
      <div className="cbf-label">Total</div>
      <div className="cbf-total">
        <span className="cbf-total-currency">$</span>
        <input
          type="text"
          inputMode="decimal"
          placeholder="0"
          value={total}
          onChange={(e) => setTotal(e.target.value)}
          className="cbf-total-input"
          aria-label="Total"
        />
      </div>

      <div className="cbf-row">
        <div>
          <div className="cbf-label">Timeline</div>
          <input
            type="text"
            placeholder="e.g. 6 weeks"
            value={timeline}
            onChange={(e) => setTimeline(e.target.value)}
            className="cbf-input"
          />
        </div>
        <div>
          <div className="cbf-label">Start</div>
          <input
            type="text"
            placeholder="e.g. May 5"
            value={start}
            onChange={(e) => setStart(e.target.value)}
            className="cbf-input"
          />
        </div>
      </div>

      <div className="cbf-label-row">
        <span className="cbf-label">Project breakdown PDF</span>
        <span className="cbf-required">Required</span>
      </div>

      {pdf ? (
        <div className="cbf-file-card">
          <div className="cbf-file-icon" aria-hidden="true">PDF</div>
          <div className="cbf-file-body">
            <div className="cbf-file-name">{pdf.name}</div>
            <div className="cbf-file-meta">{fmtFileSize(pdf.size)} · Uploaded just now</div>
          </div>
          <label className="cbf-file-replace">
            Replace
            <input
              type="file"
              accept="application/pdf"
              style={{ display: "none" }}
              onChange={(e) => setPdf(e.target.files?.[0] || null)}
            />
          </label>
        </div>
      ) : existingPdfUrl ? (
        <div className="cbf-file-card">
          <div className="cbf-file-icon" aria-hidden="true">PDF</div>
          <div className="cbf-file-body">
            <div className="cbf-file-name">{pdfNameFromUrl(existingPdfUrl)}</div>
            <div className="cbf-file-meta">
              {existingPdfSize ? `${existingPdfSize} · ` : ""}Previously attached
            </div>
          </div>
          <label className="cbf-file-replace">
            Replace
            <input
              type="file"
              accept="application/pdf"
              style={{ display: "none" }}
              onChange={(e) => {
                const f = e.target.files?.[0] || null;
                if (f) {
                  setPdf(f);
                  // Clear the "existing" reference so submit sends the new file.
                  setExistingPdfUrl(null);
                }
              }}
            />
          </label>
        </div>
      ) : (
        <label className="cbf-file-drop">
          <div className="cbf-file-drop-icon" aria-hidden="true">⬆</div>
          <div className="cbf-file-drop-label">Choose a PDF</div>
          <div className="cbf-file-drop-sub">or drop it here</div>
          <input
            type="file"
            accept="application/pdf"
            style={{ display: "none" }}
            onChange={(e) => setPdf(e.target.files?.[0] || null)}
          />
        </label>
      )}

      <div className="cbf-help">
        Attach a PDF with your full project breakdown and line items. Customers compare your PDF side-by-side with other bids.
      </div>

      <div className="cbf-label-row">
        <span className="cbf-label">Bid media</span>
        <span className="cbf-optional">Optional</span>
      </div>

      <div className="cbf-media-row">
        {existingMedia.map((a) => {
          const isVideo = (a.content_type || "").startsWith("video/");
          return (
          <div key={a.blob_path} className="cbf-media-tile">
            {a.download_url ? (
              isVideo ? (
                <>
                  <video src={a.download_url} preload="metadata" muted playsInline />
                  <div className="cbf-media-play">▶</div>
                </>
              ) : (
                <img src={a.download_url} alt={a.name || ""} loading="lazy" />
              )
            ) : <div className="cbf-media-fallback">{(a.name || "File").slice(0, 8)}</div>}
            <button
              type="button"
              className="cbf-media-remove"
              disabled={deletingBlobPath === a.blob_path || submitting}
              title="Remove"
              aria-label={`Remove ${a.name || "media"}`}
              onClick={async () => {
                if (!bidId || !a.attachment_id) return;
                if (!confirm(`Remove ${a.name || "this item"}?`)) return;
                setDeletingBlobPath(a.blob_path);
                try {
                  await apiFetch(`/api/rfqs/${rfqId}/bids/${bidId}/attachments/${a.attachment_id}`, { method: "DELETE" });
                  setExistingMedia((prev) => prev.filter((x) => x.blob_path !== a.blob_path));
                } catch (err) {
                  alert((err as Error).message || "Failed to remove");
                } finally {
                  setDeletingBlobPath(null);
                }
              }}
            >×</button>
          </div>
          );
        })}
        {newMedia.map((f, i) => {
          const isVideo = (f.type || "").startsWith("video/");
          const url = URL.createObjectURL(f);
          return (
          <div key={`${f.name}-${i}`} className="cbf-media-tile cbf-media-tile-pending">
            {isVideo ? (
              <>
                <video src={url} preload="metadata" muted playsInline />
                <div className="cbf-media-play">▶</div>
              </>
            ) : (
              <img src={url} alt={f.name} />
            )}
            <button
              type="button"
              className="cbf-media-remove"
              title="Remove"
              aria-label={`Remove ${f.name}`}
              onClick={() => setNewMedia((prev) => prev.filter((_, idx) => idx !== i))}
              disabled={submitting}
            >×</button>
            <div className="cbf-media-pending-badge">New</div>
          </div>
          );
        })}
        <label className="cbf-media-add" title="Add photos or videos">
          <span>+</span>
          <input
            ref={mediaInputRef}
            type="file"
            accept="image/jpeg,image/png,image/webp,image/gif,image/heic,video/mp4,video/quicktime,video/webm"
            multiple
            style={{ display: "none" }}
            onChange={(e) => {
              const files = Array.from(e.target.files || []);
              // The bid POST is a multipart Cloud Run request with a ~32MB body
              // limit. Block obvious over-sized files before the request fails
              // opaquely server-side; large videos should go through the
              // signed-URL path once we wire it up in the form.
              const MAX_BYTES = 28 * 1024 * 1024;
              const tooLarge = files.filter((f) => f.size > MAX_BYTES);
              if (tooLarge.length) {
                alert(`These files are larger than 28 MB and can't be attached this way:\n\n${tooLarge.map((f) => `• ${f.name}`).join("\n")}\n\nConsider sending them via chat instead.`);
              }
              const ok = files.filter((f) => f.size <= MAX_BYTES);
              if (ok.length) setNewMedia((prev) => [...prev, ...ok]);
              if (mediaInputRef.current) mediaInputRef.current.value = "";
            }}
          />
        </label>
      </div>
      <div className="cbf-help">
        Attach reference photos, material swatches, or example work for the customer.
      </div>

      <div className="cbf-label" style={{ marginTop: 16 }}>Note to customer</div>
      <textarea
        rows={3}
        placeholder="Full gut, island w/ waterfall, new electrical…"
        value={note}
        onChange={(e) => setNote(e.target.value)}
        className="cbf-input cbf-textarea"
      />

      {error && <div className="cbf-error">{error}</div>}

      <div className="cbf-actions">
        <button type="submit" className="cbf-submit" disabled={submitting}>
          {submitting ? "Submitting…" : (submitLabel || (isUpdate ? "Update bid" : "Submit bid"))}
        </button>
        {onCancel && (
          <button type="button" className="cbf-cancel" onClick={onCancel} disabled={submitting}>
            Cancel
          </button>
        )}
      </div>

      <style>{CBF_CSS}</style>
    </form>
  );
}

const CBF_CSS = `
.cbf { display: flex; flex-direction: column; }
.cbf-label {
  font-size: 12px; font-weight: 700; color: var(--q-ink-muted);
  letter-spacing: 0.3px; text-transform: uppercase; margin-bottom: 6px;
}
.cbf-label-row {
  display: flex; justify-content: space-between; align-items: baseline;
  margin-top: 18px; margin-bottom: 6px;
}
.cbf-required {
  font-size: 10px; font-weight: 700; letter-spacing: 0.3px; text-transform: uppercase;
  color: var(--q-danger);
}

.cbf-total {
  display: flex; align-items: baseline; gap: 4px;
  background: var(--q-surface-muted); border-radius: 12px;
  padding: 12px 16px; margin-bottom: 14px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
}
.cbf-total-currency {
  font-size: 28px; font-weight: 700; letter-spacing: -0.8px; color: var(--q-ink);
}
.cbf-total-input {
  border: none; background: transparent; outline: none;
  font-size: 28px; font-weight: 700; letter-spacing: -0.8px; color: var(--q-ink);
  font-family: inherit; font-variant-numeric: tabular-nums;
  flex: 1; min-width: 0; padding: 0;
}
.cbf-total-input::placeholder { color: var(--q-ink-dim); }

.cbf-row {
  display: grid; grid-template-columns: 1fr 1fr; gap: 10px;
  margin-bottom: 4px;
}
.cbf-input {
  width: 100%; padding: 10px 14px; font-size: 14px; font-family: inherit;
  border: none; background: var(--q-surface-muted); color: var(--q-ink);
  border-radius: 10px; box-shadow: inset 0 0 0 0.5px var(--q-hairline);
  outline: none; transition: box-shadow 0.15s;
}
.cbf-input:focus { box-shadow: inset 0 0 0 1.5px var(--q-primary); }
.cbf-input::placeholder { color: var(--q-ink-dim); }
.cbf-textarea { resize: vertical; line-height: 1.5; }

.cbf-file-card {
  display: flex; align-items: center; gap: 12px;
  background: var(--q-surface-muted); border-radius: 12px; padding: 12px 14px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
}
.cbf-file-icon {
  width: 40px; height: 48px; border-radius: 6px;
  background: #C8342C; color: #fff;
  display: flex; align-items: center; justify-content: center;
  font-size: 11px; font-weight: 800; letter-spacing: 0.5px; flex-shrink: 0;
  box-shadow: 0 1px 2px rgba(0,0,0,0.15);
}
.cbf-file-body { flex: 1; min-width: 0; }
.cbf-file-name {
  font-size: 13px; font-weight: 600; color: var(--q-ink);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.cbf-file-meta { font-size: 11px; color: var(--q-ink-muted); margin-top: 2px; }
.cbf-file-replace {
  padding: 6px 12px; font-size: 12px; font-weight: 600; font-family: inherit;
  color: var(--q-ink); background: var(--q-surface); border-radius: 8px;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
  cursor: pointer; white-space: nowrap;
}
.cbf-file-replace:hover { background: var(--q-canvas); }

.cbf-file-drop {
  display: flex; flex-direction: column; align-items: center; gap: 4px;
  padding: 20px 14px; background: var(--q-surface-muted);
  border-radius: 12px; cursor: pointer;
  box-shadow: inset 0 0 0 1px dashed var(--q-hairline);
  border: 1px dashed var(--q-hairline);
  text-align: center; transition: background 0.15s, border-color 0.15s;
}
.cbf-file-drop:hover { background: var(--q-canvas); border-color: var(--q-primary); }
.cbf-file-drop-icon {
  font-size: 22px; color: var(--q-primary); line-height: 1; margin-bottom: 2px;
}
.cbf-file-drop-label { font-size: 13px; font-weight: 600; color: var(--q-ink); }
.cbf-file-drop-sub { font-size: 11px; color: var(--q-ink-muted); }

.cbf-help {
  font-size: 12px; color: var(--q-ink-muted); line-height: 1.45;
  margin-top: 8px;
}
.cbf-optional {
  font-size: 10px; font-weight: 700; letter-spacing: 0.3px; text-transform: uppercase;
  color: var(--q-ink-muted);
}

.cbf-media-row {
  display: flex; flex-wrap: wrap; gap: 8px; margin-top: 2px;
}
.cbf-media-tile {
  position: relative; width: 84px; height: 84px; border-radius: 10px;
  overflow: hidden; box-shadow: inset 0 0 0 0.5px var(--q-hairline);
  background: var(--q-surface-muted);
}
.cbf-media-tile img, .cbf-media-tile video { width: 100%; height: 100%; object-fit: cover; display: block; }
.cbf-media-play {
  position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
  color: #fff; font-size: 22px; line-height: 1;
  text-shadow: 0 1px 6px rgba(0,0,0,0.55); pointer-events: none;
}
.cbf-media-fallback {
  width: 100%; height: 100%; display: flex; align-items: center; justify-content: center;
  font-size: 10px; color: var(--q-ink-muted);
}
.cbf-media-remove {
  position: absolute; top: 4px; right: 4px;
  width: 20px; height: 20px; padding: 0; border: none;
  background: rgba(0,0,0,0.62); color: #fff; border-radius: 50%;
  font-size: 14px; font-weight: 700; line-height: 1; cursor: pointer;
  display: flex; align-items: center; justify-content: center;
}
.cbf-media-remove:hover { background: rgba(0,0,0,0.85); }
.cbf-media-remove:disabled { cursor: wait; opacity: 0.7; }
.cbf-media-pending-badge {
  position: absolute; bottom: 4px; left: 4px;
  padding: 1px 6px; border-radius: 4px;
  font-size: 9px; font-weight: 700; letter-spacing: 0.3px;
  text-transform: uppercase; color: #fff; background: var(--q-primary);
}
.cbf-media-tile-pending { box-shadow: inset 0 0 0 1px var(--q-primary); }
.cbf-media-add {
  width: 84px; height: 84px; border-radius: 10px;
  border: 1px dashed var(--q-hairline); background: var(--q-surface-muted);
  cursor: pointer; display: flex; align-items: center; justify-content: center;
  font-size: 28px; color: var(--q-ink-muted); font-weight: 300;
  transition: border-color 0.12s, color 0.12s, background 0.12s;
}
.cbf-media-add:hover { border-color: var(--q-primary); color: var(--q-primary); background: var(--q-canvas); }

.cbf-error {
  background: rgba(176,58,46,0.08); color: var(--q-danger);
  border-radius: 8px; padding: 8px 12px; font-size: 13px;
  margin-top: 14px;
}

.cbf-actions { display: flex; gap: 8px; margin-top: 18px; }
.cbf-submit {
  display: block; flex: 1; padding: 13px 16px; border: none;
  background: var(--q-primary); color: var(--q-primary-ink);
  font-size: 15px; font-weight: 700; font-family: inherit;
  border-radius: var(--q-radius-md); cursor: pointer;
  transition: filter 0.15s;
}
.cbf-submit:hover:not(:disabled) { filter: brightness(0.92); }
.cbf-submit:disabled { opacity: 0.5; cursor: not-allowed; }
.cbf-cancel {
  padding: 13px 18px; border: none; background: var(--q-surface-muted);
  color: var(--q-ink); font-size: 14px; font-weight: 600; font-family: inherit;
  border-radius: var(--q-radius-md); cursor: pointer;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline);
}
.cbf-cancel:hover:not(:disabled) { background: var(--q-canvas); }
`;
