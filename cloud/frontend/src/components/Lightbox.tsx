import { useEffect, useCallback, useRef, useState } from "react";
import BeforeAfterSlider from "./BeforeAfterSlider";

export interface LightboxItem {
  url: string;
  beforeUrl?: string | null;
  type?: string; // "image" | "video" | "before_after"
}

interface LightboxProps {
  items: LightboxItem[];
  startIndex: number;
  onClose: () => void;
  onIndexChange?: (index: number) => void;
}

export default function Lightbox({ items, startIndex, onClose, onIndexChange }: LightboxProps) {
  const [idx, setIdx] = useState(startIndex);
  const touchStartX = useRef<number | null>(null);

  const goPrev = useCallback(() => {
    setIdx((cur) => {
      if (cur <= 0) return cur;
      const next = cur - 1;
      onIndexChange?.(next);
      return next;
    });
  }, [onIndexChange]);

  const goNext = useCallback(() => {
    setIdx((cur) => {
      if (cur >= items.length - 1) return cur;
      const next = cur + 1;
      onIndexChange?.(next);
      return next;
    });
  }, [items.length, onIndexChange]);

  // Keyboard navigation
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
      if (e.key === "ArrowLeft") goPrev();
      if (e.key === "ArrowRight") goNext();
    }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose, goPrev, goNext]);

  // Lock body scroll
  useEffect(() => {
    document.body.style.overflow = "hidden";
    return () => { document.body.style.overflow = ""; };
  }, []);

  const item = items[idx];
  if (!item) return null;

  const isBeforeAfter = !!(item.beforeUrl && item.url);
  const isVideo = item.type === "video";

  return (
    <div
      onClick={onClose}
      onTouchStart={(e) => { touchStartX.current = e.touches[0].clientX; }}
      onTouchEnd={(e) => {
        if (touchStartX.current === null) return;
        const dx = e.changedTouches[0].clientX - touchStartX.current;
        touchStartX.current = null;
        if (Math.abs(dx) > 50) {
          if (dx > 0) goPrev();
          else goNext();
        }
      }}
      style={{
        position: "fixed", top: 0, left: 0, right: 0, bottom: 0,
        background: "rgba(0,0,0,0.9)", display: "flex",
        alignItems: "center", justifyContent: "center",
        zIndex: 2000, padding: 16,
      }}
    >
      {/* Close button */}
      <button
        onClick={onClose}
        style={{
          position: "absolute", top: 16, right: 20, background: "none",
          border: "none", color: "#fff", fontSize: 32, cursor: "pointer",
          lineHeight: 1, zIndex: 3,
        }}
      >
        &times;
      </button>

      {/* Counter */}
      {items.length > 1 && (
        <div style={{
          position: "absolute", top: 20, left: "50%", transform: "translateX(-50%)",
          color: "rgba(255,255,255,0.7)", fontSize: 14, fontWeight: 600, zIndex: 3,
        }}>
          {idx + 1} / {items.length}
        </div>
      )}

      {/* Prev arrow */}
      {idx > 0 && (
        <button
          onClick={(e) => { e.stopPropagation(); goPrev(); }}
          style={{
            position: "absolute", left: 12, top: "50%", transform: "translateY(-50%)",
            background: "rgba(0,0,0,0.5)", border: "none", color: "#fff",
            width: 44, height: 44, borderRadius: "50%", cursor: "pointer",
            display: "flex", alignItems: "center", justifyContent: "center",
            fontSize: 22, zIndex: 3,
          }}
        >
          &#8249;
        </button>
      )}

      {/* Next arrow */}
      {idx < items.length - 1 && (
        <button
          onClick={(e) => { e.stopPropagation(); goNext(); }}
          style={{
            position: "absolute", right: 12, top: "50%", transform: "translateY(-50%)",
            background: "rgba(0,0,0,0.5)", border: "none", color: "#fff",
            width: 44, height: 44, borderRadius: "50%", cursor: "pointer",
            display: "flex", alignItems: "center", justifyContent: "center",
            fontSize: 22, zIndex: 3,
          }}
        >
          &#8250;
        </button>
      )}

      {/* Content */}
      <div onClick={(e) => e.stopPropagation()} style={{ maxWidth: "90vw", maxHeight: "85vh", width: "100%" }}>
        {isBeforeAfter ? (
          <BeforeAfterSlider
            beforeUrl={item.beforeUrl!}
            afterUrl={item.url}
            style={{ maxHeight: "85vh", width: "100%", borderRadius: 8 }}
          />
        ) : isVideo ? (
          <video
            src={item.url}
            controls
            autoPlay
            style={{ maxWidth: "90vw", maxHeight: "85vh", borderRadius: 8, display: "block", margin: "0 auto" }}
          />
        ) : (
          <img
            src={item.url}
            alt=""
            style={{ maxWidth: "90vw", maxHeight: "85vh", objectFit: "contain", borderRadius: 8, display: "block", margin: "0 auto" }}
          />
        )}
      </div>
    </div>
  );
}
