import { useState, useRef, useEffect, type FormEvent } from "react";
import { useNavigate } from "react-router-dom";
import { SERVICES } from "../api/services";
import AddressAutocomplete from "./AddressAutocomplete";

interface SearchOverlayProps {
  onClose: () => void;
}

export default function SearchOverlay({ onClose }: SearchOverlayProps) {
  const navigate = useNavigate();
  const [service, setService] = useState("");
  const [serviceQuery, setServiceQuery] = useState("");
  const [location, setLocation] = useState("");
  const serviceInputRef = useRef<HTMLInputElement>(null);

  const filtered = serviceQuery
    ? SERVICES.filter((s) => s.toLowerCase().includes(serviceQuery.toLowerCase()))
    : SERVICES;

  // Auto-focus service input on mount
  useEffect(() => {
    serviceInputRef.current?.focus();
  }, []);

  // Lock body scroll while overlay is open
  useEffect(() => {
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = "";
    };
  }, []);

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    const params = new URLSearchParams();
    if (service) params.set("service", service);
    if (location.trim()) params.set("location", location.trim());
    const qs = params.toString();
    if (qs) {
      onClose();
      navigate(`/search?${qs}`);
    }
  }

  function selectService(s: string) {
    setService(s);
    setServiceQuery(s);
  }

  return (
    <div
      style={{
        position: "fixed",
        top: 0,
        left: 0,
        right: 0,
        bottom: 0,
        background: "var(--color-surface)",
        zIndex: 1100,
        display: "flex",
        flexDirection: "column",
        animation: "overlay-slide-up 0.25s ease",
      }}
    >
      {/* Header */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 12,
          padding: "16px 20px",
          borderBottom: "1px solid var(--color-border)",
          flexShrink: 0,
        }}
      >
        <button
          onClick={onClose}
          style={{
            background: "none",
            border: "none",
            fontSize: 24,
            color: "var(--color-text)",
            cursor: "pointer",
            padding: 0,
            lineHeight: 1,
          }}
        >
          &times;
        </button>
        <h2 style={{ fontSize: 18, fontWeight: 700 }}>Find a Contractor</h2>
      </div>

      {/* Form */}
      <form
        onSubmit={handleSubmit}
        style={{
          flex: 1,
          minHeight: 0,
          display: "flex",
          flexDirection: "column",
          overflow: "hidden",
        }}
      >
        <div style={{ padding: "20px 20px 0", flexShrink: 0 }}>
          {/* Service input */}
          <div style={{ position: "relative", marginBottom: 12 }}>
            <svg
              style={{
                position: "absolute",
                left: 14,
                top: 15,
                width: 18,
                height: 18,
                fill: "var(--color-text-muted)",
                pointerEvents: "none",
              }}
              viewBox="0 0 24 24"
            >
              <path d="M15.5 14h-.79l-.28-.27A6.47 6.47 0 0016 9.5 6.5 6.5 0 109.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z" />
            </svg>
            <input
              ref={serviceInputRef}
              type="text"
              placeholder="What do you need?"
              value={serviceQuery}
              onChange={(e) => {
                setServiceQuery(e.target.value);
                setService("");
              }}
              className="form-input"
              style={{ paddingLeft: 42 }}
            />
          </div>

          {/* Location input */}
          <div style={{ position: "relative", marginBottom: 16 }}>
            <svg
              style={{
                position: "absolute",
                left: 14,
                top: 15,
                width: 18,
                height: 18,
                fill: "var(--color-text-muted)",
                pointerEvents: "none",
                zIndex: 1,
              }}
              viewBox="0 0 24 24"
            >
              <path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5a2.5 2.5 0 010-5 2.5 2.5 0 010 5z" />
            </svg>
            <AddressAutocomplete
              value={location}
              onChange={setLocation}
              placeholder="Zip code or city"
              style={{ paddingLeft: 42 }}
              types={["(regions)"]}
            />
          </div>
        </div>

        {/* Service list */}
        <div
          style={{
            flex: 1,
            minHeight: 0,
            overflowY: "auto",
            WebkitOverflowScrolling: "touch",
            padding: "0 20px",
            borderTop: "1px solid var(--color-border-light)",
          }}
        >
          <div
            style={{
              fontSize: 12,
              fontWeight: 700,
              color: "var(--color-text-muted)",
              textTransform: "uppercase",
              letterSpacing: "0.5px",
              padding: "16px 0 8px",
            }}
          >
            Services
          </div>
          {filtered.map((s) => (
            <button
              key={s}
              type="button"
              onClick={() => selectService(s)}
              style={{
                display: "flex",
                alignItems: "center",
                width: "100%",
                padding: "14px 0",
                fontSize: 16,
                fontFamily: "inherit",
                background: "none",
                border: "none",
                borderBottom: "1px solid var(--color-border-light)",
                cursor: "pointer",
                textAlign: "left",
                color: s === service ? "var(--color-primary)" : "var(--color-text)",
                fontWeight: s === service ? 600 : 400,
              }}
            >
              {s === service && (
                <svg
                  width="18"
                  height="18"
                  viewBox="0 0 24 24"
                  fill="var(--color-primary)"
                  style={{ marginRight: 10, flexShrink: 0 }}
                >
                  <path d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" />
                </svg>
              )}
              {s}
            </button>
          ))}
          {filtered.length === 0 && (
            <p style={{ padding: "20px 0", color: "var(--color-text-muted)", fontSize: 14 }}>
              No matching services
            </p>
          )}
        </div>

        {/* Submit button */}
        <div
          style={{
            padding: 20,
            borderTop: "1px solid var(--color-border)",
            flexShrink: 0,
          }}
        >
          <button type="submit" className="btn btn-primary btn-full" style={{ padding: 14, fontSize: 16 }}>
            Search
          </button>
        </div>
      </form>
    </div>
  );
}
