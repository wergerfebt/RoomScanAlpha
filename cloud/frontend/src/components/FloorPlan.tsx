import { useRef, useEffect } from "react";

interface Room {
  room_label: string;
  room_polygon_ft?: number[][] | null;
}

interface FloorPlanProps {
  rooms: Room[];
  width?: number;
  height?: number;
}

export default function FloorPlan({ rooms, width = 400, height = 300 }: FloorPlanProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.parentElement?.getBoundingClientRect();
    const w = rect?.width || width;
    const h = height;
    canvas.width = w * dpr;
    canvas.height = h * dpr;
    canvas.style.width = `${w}px`;
    canvas.style.height = `${h}px`;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.scale(dpr, dpr);

    // Collect room polygons with horizontal layout
    const GAP_FT = 3;
    const roomPolys: { poly: number[][]; label: string }[] = [];
    let cursorX = 0;

    rooms.forEach((r) => {
      if (!r.room_polygon_ft || r.room_polygon_ft.length < 3) return;
      const poly = r.room_polygon_ft;
      let rMinX = Infinity, rMaxX = -Infinity, rMinY = Infinity, rMaxY = -Infinity;
      poly.forEach(([x, y]) => {
        rMinX = Math.min(rMinX, x); rMaxX = Math.max(rMaxX, x);
        rMinY = Math.min(rMinY, y); rMaxY = Math.max(rMaxY, y);
      });
      const offX = cursorX - rMinX;
      const offY = -rMinY;
      roomPolys.push({
        poly: poly.map(([x, y]) => [x + offX, y + offY]),
        label: r.room_label,
      });
      cursorX += (rMaxX - rMinX) + GAP_FT;
    });

    if (roomPolys.length === 0) return;

    // Compute bounds
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    roomPolys.forEach((rp) => rp.poly.forEach(([x, y]) => {
      minX = Math.min(minX, x); maxX = Math.max(maxX, x);
      minY = Math.min(minY, y); maxY = Math.max(maxY, y);
    }));
    const polyW = maxX - minX || 1;
    const polyH = maxY - minY || 1;
    const pad = 0.15;
    const scale = Math.min(w * (1 - 2 * pad) / polyW, h * (1 - 2 * pad) / polyH);
    const cx = (minX + maxX) / 2;
    const cy = (minY + maxY) / 2;
    const tx = (x: number) => w / 2 + (x - cx) * scale;
    const ty = (y: number) => h / 2 + (y - cy) * scale;

    // Draw each room
    roomPolys.forEach(({ poly, label }) => {
      ctx.beginPath();
      ctx.moveTo(tx(poly[0][0]), ty(poly[0][1]));
      poly.slice(1).forEach(([x, y]) => ctx.lineTo(tx(x), ty(y)));
      ctx.closePath();
      ctx.fillStyle = "rgba(43,79,224,0.08)"; // --q-scan-accent @ 8%
      ctx.fill();
      ctx.strokeStyle = "#2B4FE0"; // --q-scan-accent
      ctx.lineWidth = 1.5;
      ctx.stroke();

      // Wall measurements
      ctx.fillStyle = "#66726B"; // --q-ink-muted
      ctx.font = `${Math.max(9, Math.min(11, scale * 0.8))}px -apple-system, sans-serif`;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      for (let j = 0; j < poly.length; j++) {
        const k = (j + 1) % poly.length;
        const [x0, y0] = poly[j];
        const [x1, y1] = poly[k];
        const wallFt = Math.sqrt((x1 - x0) ** 2 + (y1 - y0) ** 2);
        if (wallFt < 1) continue;
        const mx = (tx(x0) + tx(x1)) / 2;
        const my = (ty(y0) + ty(y1)) / 2;
        const dx = tx(x1) - tx(x0);
        const dy = ty(y1) - ty(y0);
        const len = Math.sqrt(dx * dx + dy * dy);
        if (len < 20) continue;
        const nx = -dy / len * 10;
        const ny = dx / len * 10;
        ctx.fillText(`${wallFt.toFixed(1)}'`, mx + nx, my + ny);
      }

      // Room label
      let labelX = 0, labelY = 0;
      poly.forEach(([x, y]) => { labelX += x; labelY += y; });
      labelX /= poly.length; labelY /= poly.length;
      ctx.fillStyle = "#141A16"; // --q-ink
      ctx.font = `600 ${Math.max(10, Math.min(13, scale * 1.2))}px -apple-system, sans-serif`;
      ctx.fillText(label, tx(labelX), ty(labelY));
    });
  }, [rooms, width, height]);

  return (
    <div style={{ background: "transparent", borderRadius: 8, overflow: "hidden" }}>
      <canvas ref={canvasRef} />
    </div>
  );
}
