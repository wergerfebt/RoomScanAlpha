import { useState, type FormEvent } from "react";
import { getIdToken } from "../api/firebase";

interface SubmitQuoteFormProps {
  rfqId: string;
  onSubmitted: (bid: { id: string; price_cents: number; description: string }) => void;
  onCancel: () => void;
}

export default function SubmitQuoteForm({ rfqId, onSubmitted, onCancel }: SubmitQuoteFormProps) {
  const [price, setPrice] = useState("");
  const [description, setDescription] = useState("");
  const [pdf, setPdf] = useState<File | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    const priceDollars = parseFloat(price);
    if (!priceDollars || priceDollars <= 0) {
      setError("Enter a valid price");
      return;
    }
    if (!description.trim()) {
      setError("Description is required");
      return;
    }

    setSubmitting(true);
    setError("");

    try {
      const token = await getIdToken();
      const formData = new FormData();
      formData.append("price_cents", String(Math.round(priceDollars * 100)));
      formData.append("description", description.trim());
      if (pdf) formData.append("pdf", pdf);

      const res = await fetch(`/api/rfqs/${rfqId}/bids`, {
        method: "POST",
        headers: token ? { Authorization: `Bearer ${token}` } : {},
        body: formData,
      });

      if (!res.ok) {
        const text = await res.text();
        throw new Error(text || `HTTP ${res.status}`);
      }

      const data = await res.json();
      onSubmitted({
        id: data.id,
        price_cents: data.price_cents,
        description: data.description,
      });
    } catch (err: unknown) {
      setError((err as Error).message || "Failed to submit quote");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div style={{
      border: "1px solid var(--color-border)", borderRadius: "var(--radius-md)",
      padding: 20, background: "var(--color-surface)", marginTop: 12,
    }}>
      <h4 style={{ fontSize: 15, fontWeight: 700, marginBottom: 14 }}>Submit a Quote</h4>
      <form onSubmit={handleSubmit}>
        <div style={{ marginBottom: 12 }}>
          <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>
            Price *
          </label>
          <div style={{ position: "relative" }}>
            <span style={{ position: "absolute", left: 12, top: "50%", transform: "translateY(-50%)", fontSize: 14, color: "var(--color-text-muted)" }}>$</span>
            <input
              className="form-input"
              type="number"
              step="0.01"
              min="0"
              value={price}
              onChange={(e) => setPrice(e.target.value)}
              placeholder="e.g. 12500"
              style={{ paddingLeft: 24 }}
            />
          </div>
        </div>

        <div style={{ marginBottom: 12 }}>
          <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>
            Description *
          </label>
          <textarea
            className="form-input"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="Describe your approach, materials, timeline..."
            rows={4}
            style={{ resize: "vertical" }}
          />
        </div>

        <div style={{ marginBottom: 14 }}>
          <label style={{ display: "block", fontSize: 13, fontWeight: 600, color: "var(--color-text-secondary)", marginBottom: 4 }}>
            Quote PDF (optional)
          </label>
          <input
            type="file"
            accept=".pdf"
            onChange={(e) => setPdf(e.target.files?.[0] || null)}
            style={{ fontSize: 13 }}
          />
        </div>

        {error && (
          <p style={{ fontSize: 13, color: "var(--color-danger)", marginBottom: 10 }}>{error}</p>
        )}

        <div style={{ display: "flex", gap: 8 }}>
          <button className="btn btn-primary" type="submit" disabled={submitting}>
            {submitting ? "Submitting..." : "Submit Quote"}
          </button>
          <button className="btn" type="button" onClick={onCancel}>
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
}
