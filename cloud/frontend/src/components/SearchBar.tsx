import { useState, useRef, useEffect, type FormEvent } from "react";
import { useNavigate } from "react-router-dom";
import { SERVICES } from "../api/services";
import SearchOverlay from "./SearchOverlay";
import AddressAutocomplete from "./AddressAutocomplete";

interface SearchBarProps {
  size?: "compact" | "large";
}

function useIsMobile(breakpoint = 768) {
  const [mobile, setMobile] = useState(
    () => typeof window !== "undefined" && window.innerWidth <= breakpoint,
  );
  useEffect(() => {
    const mq = window.matchMedia(`(max-width: ${breakpoint}px)`);
    const handler = (e: MediaQueryListEvent) => setMobile(e.matches);
    mq.addEventListener("change", handler);
    return () => mq.removeEventListener("change", handler);
  }, [breakpoint]);
  return mobile;
}

export default function SearchBar({ size = "compact" }: SearchBarProps) {
  const navigate = useNavigate();
  const isMobile = useIsMobile();
  const [overlayOpen, setOverlayOpen] = useState(false);
  const [service, setService] = useState("");
  const [serviceQuery, setServiceQuery] = useState("");
  const [location, setLocation] = useState("");
  const [dropdownOpen, setDropdownOpen] = useState(false);
  const wrapperRef = useRef<HTMLFormElement>(null);

  const isLarge = size === "large";
  const inputPad = isLarge ? "14px 16px 14px 40px" : "10px 14px 10px 36px";
  const fontSize = isLarge ? 16 : 14;
  const iconSize = isLarge ? 18 : 16;
  const iconLeft = isLarge ? 12 : 10;
  const height = isLarge ? 52 : 42;

  const filtered = serviceQuery
    ? SERVICES.filter((s) => s.toLowerCase().includes(serviceQuery.toLowerCase()))
    : SERVICES;

  // Close dropdown on outside click
  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (wrapperRef.current && !wrapperRef.current.contains(e.target as Node)) {
        setDropdownOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClick);
    return () => document.removeEventListener("mousedown", handleClick);
  }, []);

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    const params = new URLSearchParams();
    if (service) params.set("service", service);
    if (location.trim()) params.set("location", location.trim());
    const qs = params.toString();
    if (qs) navigate(`/search?${qs}`);
  }

  function selectService(s: string) {
    setService(s);
    setServiceQuery(s);
    setDropdownOpen(false);
  }

  // --- Mobile: compact trigger bar that opens the overlay ---
  if (isMobile) {
    return (
      <>
        <button
          type="button"
          onClick={() => setOverlayOpen(true)}
          style={{
            flex: 1,
            display: "flex",
            alignItems: "center",
            gap: 8,
            height: 42,
            padding: "0 14px",
            border: "1px solid var(--color-border)",
            borderRadius: 10,
            background: "var(--color-surface)",
            cursor: "pointer",
            overflow: "hidden",
            boxShadow: isLarge ? "0 2px 12px rgba(0,0,0,0.08)" : undefined,
          }}
        >
          <svg
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="var(--color-text-muted)"
            style={{ flexShrink: 0 }}
          >
            <path d="M15.5 14h-.79l-.28-.27A6.47 6.47 0 0016 9.5 6.5 6.5 0 109.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z" />
          </svg>
          <span
            style={{
              fontSize: 14,
              color: "var(--color-text-placeholder)",
              whiteSpace: "nowrap",
              overflow: "hidden",
              textOverflow: "ellipsis",
            }}
          >
            Search contractors...
          </span>
        </button>
        {overlayOpen && <SearchOverlay onClose={() => setOverlayOpen(false)} />}
      </>
    );
  }

  // --- Desktop: inline two-field search bar ---
  return (
    <form
      ref={wrapperRef}
      onSubmit={handleSubmit}
      style={{
        flex: isLarge ? undefined : 1,
        width: isLarge ? "100%" : undefined,
        maxWidth: isLarge ? 600 : 480,
        display: "flex",
        border: "1px solid var(--color-border)",
        borderRadius: isLarge ? 12 : 10,
        background: "var(--color-surface)",
        overflow: "visible",
        position: "relative",
        height,
        boxShadow: isLarge ? "0 2px 12px rgba(0,0,0,0.08)" : undefined,
      }}
    >
      {/* Service field */}
      <div style={{ flex: 1, position: "relative", display: "flex", alignItems: "center" }}>
        <svg
          style={{
            position: "absolute",
            left: iconLeft,
            width: iconSize,
            height: iconSize,
            fill: "var(--color-text-muted)",
            pointerEvents: "none",
          }}
          viewBox="0 0 24 24"
        >
          <path d="M15.5 14h-.79l-.28-.27A6.47 6.47 0 0016 9.5 6.5 6.5 0 109.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z" />
        </svg>
        <input
          type="text"
          placeholder="What do you need?"
          value={serviceQuery}
          onChange={(e) => {
            setServiceQuery(e.target.value);
            setService("");
            setDropdownOpen(true);
          }}
          onFocus={() => setDropdownOpen(true)}
          style={{
            width: "100%",
            padding: inputPad,
            fontSize,
            fontFamily: "inherit",
            border: "none",
            background: "transparent",
            outline: "none",
            color: "var(--color-text)",
          }}
        />

        {/* Service dropdown */}
        {dropdownOpen && filtered.length > 0 && (
          <div
            style={{
              position: "absolute",
              top: "calc(100% + 4px)",
              left: 0,
              right: 0,
              background: "var(--color-surface)",
              border: "1px solid var(--color-border)",
              borderRadius: 10,
              boxShadow: "0 8px 24px rgba(0,0,0,0.12)",
              zIndex: 200,
              maxHeight: 280,
              overflowY: "auto",
              padding: "4px 0",
            }}
          >
            {filtered.map((s) => (
              <button
                key={s}
                type="button"
                onClick={() => selectService(s)}
                style={{
                  display: "block",
                  width: "100%",
                  padding: "10px 16px",
                  fontSize: isLarge ? 15 : 14,
                  fontFamily: "inherit",
                  background: s === service ? "var(--color-info-bg)" : "transparent",
                  border: "none",
                  cursor: "pointer",
                  textAlign: "left",
                  color: "var(--color-text)",
                }}
                onMouseEnter={(e) => {
                  if (s !== service) e.currentTarget.style.background = "var(--q-surface-muted)";
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.background =
                    s === service ? "var(--color-info-bg)" : "transparent";
                }}
              >
                {s}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Divider */}
      <div
        style={{
          width: 1,
          background: "var(--color-border)",
          margin: isLarge ? "10px 0" : "8px 0",
        }}
      />

      {/* Location field */}
      <div style={{ flex: 1, position: "relative", display: "flex", alignItems: "center" }}>
        <svg
          style={{
            position: "absolute",
            left: iconLeft,
            width: iconSize,
            height: iconSize,
            fill: "var(--color-text-muted)",
            pointerEvents: "none",
          }}
          viewBox="0 0 24 24"
        >
          <path d="M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5a2.5 2.5 0 010-5 2.5 2.5 0 010 5z" />
        </svg>
        <AddressAutocomplete
          value={location}
          onChange={setLocation}
          placeholder="Zip code or city"
          className=""
          style={{
            width: "100%",
            padding: inputPad,
            fontSize,
            fontFamily: "inherit",
            border: "none",
            background: "transparent",
            outline: "none",
            color: "var(--color-text)",
          }}
          types={["(regions)"]}
        />
      </div>

      {/* Search button */}
      <button
        type="submit"
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          width: height,
          flexShrink: 0,
          background: "var(--color-primary)",
          border: "none",
          borderRadius: isLarge ? "0 12px 12px 0" : "0 10px 10px 0",
          cursor: "pointer",
          transition: "background 0.15s",
        }}
        onMouseEnter={(e) =>
          (e.currentTarget.style.background = "var(--color-primary-hover)")
        }
        onMouseLeave={(e) =>
          (e.currentTarget.style.background = "var(--color-primary)")
        }
      >
        <svg
          width={isLarge ? 22 : 18}
          height={isLarge ? 22 : 18}
          viewBox="0 0 24 24"
          fill="#fff"
        >
          <path d="M15.5 14h-.79l-.28-.27A6.47 6.47 0 0016 9.5 6.5 6.5 0 109.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z" />
        </svg>
      </button>
    </form>
  );
}
