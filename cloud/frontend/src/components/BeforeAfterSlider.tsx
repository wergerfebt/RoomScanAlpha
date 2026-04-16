import { useState, useRef, useCallback, useEffect } from "react";

interface BeforeAfterSliderProps {
  beforeUrl: string;
  afterUrl: string;
  style?: React.CSSProperties;
}

export default function BeforeAfterSlider({ beforeUrl, afterUrl, style }: BeforeAfterSliderProps) {
  const [position, setPosition] = useState(50);
  const containerRef = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);

  const updatePosition = useCallback((clientX: number) => {
    const el = containerRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    let pct = ((clientX - rect.left) / rect.width) * 100;
    pct = Math.max(2, Math.min(98, pct));
    setPosition(pct);
  }, []);

  const onPointerDown = useCallback((e: React.PointerEvent) => {
    e.preventDefault();
    dragging.current = true;
    (e.target as HTMLElement).setPointerCapture(e.pointerId);
    updatePosition(e.clientX);
  }, [updatePosition]);

  const onPointerMove = useCallback((e: React.PointerEvent) => {
    if (!dragging.current) return;
    updatePosition(e.clientX);
  }, [updatePosition]);

  const onPointerUp = useCallback(() => {
    dragging.current = false;
  }, []);

  // Preload both images
  useEffect(() => {
    const a = new Image(); a.src = beforeUrl;
    const b = new Image(); b.src = afterUrl;
  }, [beforeUrl, afterUrl]);

  return (
    <div
      ref={containerRef}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      style={{
        position: "relative",
        width: "100%",
        aspectRatio: "4/3",
        overflow: "hidden",
        borderRadius: 8,
        cursor: "ew-resize",
        userSelect: "none",
        touchAction: "none",
        ...style,
      }}
    >
      {/* After image (full background) */}
      <img
        src={afterUrl}
        alt="After"
        draggable={false}
        style={{
          position: "absolute", inset: 0,
          width: "100%", height: "100%", objectFit: "cover",
        }}
      />

      {/* Before image (clipped to left of divider) */}
      <div
        style={{
          position: "absolute", inset: 0,
          width: `${position}%`, overflow: "hidden",
        }}
      >
        <img
          src={beforeUrl}
          alt="Before"
          draggable={false}
          style={{
            position: "absolute", top: 0, left: 0,
            width: `${100 / (position / 100)}%`, height: "100%",
            maxWidth: "none", objectFit: "cover",
          }}
        />
      </div>

      {/* Divider line */}
      <div
        style={{
          position: "absolute", top: 0, bottom: 0,
          left: `${position}%`, transform: "translateX(-50%)",
          width: 3, background: "#fff",
          boxShadow: "0 0 6px rgba(0,0,0,0.5)",
        }}
      />

      {/* Drag handle */}
      <div
        style={{
          position: "absolute", top: "50%",
          left: `${position}%`, transform: "translate(-50%, -50%)",
          width: 36, height: 36, borderRadius: "50%",
          background: "#fff", boxShadow: "0 2px 8px rgba(0,0,0,0.3)",
          display: "flex", alignItems: "center", justifyContent: "center",
          zIndex: 2,
        }}
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="#333">
          <path d="M8.5 8.5L5 12l3.5 3.5M15.5 8.5L19 12l-3.5 3.5" stroke="#333" strokeWidth="2" fill="none" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </div>

      {/* Labels */}
      <span style={{
        position: "absolute", top: 10, left: 10, fontSize: 12, fontWeight: 700,
        color: "#fff", background: "rgba(0,0,0,0.5)", padding: "2px 8px",
        borderRadius: 4, pointerEvents: "none",
      }}>
        Before
      </span>
      <span style={{
        position: "absolute", top: 10, right: 10, fontSize: 12, fontWeight: 700,
        color: "#fff", background: "rgba(0,0,0,0.5)", padding: "2px 8px",
        borderRadius: 4, pointerEvents: "none",
      }}>
        After
      </span>
    </div>
  );
}
