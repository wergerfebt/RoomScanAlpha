import { useMemo, useState } from "react";
import Lightbox, { type LightboxItem } from "./Lightbox";

export interface CarouselAttachment {
  blob_path: string;
  content_type: string | null;
  name: string | null;
  size_bytes?: number | null;
  download_url?: string | null;
}

interface PhotosCarouselProps {
  attachments: CarouselAttachment[];
  /** Optional className for the scroller; defaults to the ojw- scoped style. */
  className?: string;
  /** Optional size override for thumbnails (CSS length). */
  tileSize?: number;
}

/**
 * Horizontal-scroll thumbnail strip that opens the shared Lightbox on click.
 * Filters attachments down to image types with a usable download_url. Renders
 * nothing if no images are present — callers can wrap in their own section
 * header with a visibility guard if they want.
 */
export default function PhotosCarousel({ attachments, className, tileSize }: PhotosCarouselProps) {
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);

  const images = useMemo(
    () => attachments.filter((a) => (a.content_type || "").startsWith("image/") && a.download_url),
    [attachments],
  );
  if (!images.length) return null;

  const lbItems: LightboxItem[] = images.map((a) => ({ url: a.download_url!, type: "image" }));
  const style = tileSize ? ({ ["--pc-tile-size" as string]: `${tileSize}px` } as React.CSSProperties) : undefined;

  return (
    <>
      <div className={`pc-scroll ${className || ""}`} style={style} role="list">
        {images.map((a, i) => (
          <button
            key={a.blob_path}
            type="button"
            role="listitem"
            className="pc-tile"
            onClick={() => setLightboxIndex(i)}
            aria-label={`Open photo ${i + 1} of ${images.length}`}
          >
            <img src={a.download_url!} alt={a.name || `Photo ${i + 1}`} loading="lazy" />
          </button>
        ))}
      </div>
      {lightboxIndex !== null && (
        <Lightbox items={lbItems} startIndex={lightboxIndex} onClose={() => setLightboxIndex(null)} />
      )}
      <style>{PC_CSS}</style>
    </>
  );
}

const PC_CSS = `
.pc-scroll {
  --pc-tile-size: 108px;
  display: flex; gap: 8px; overflow-x: auto; padding: 4px 2px 8px;
  scroll-snap-type: x proximity;
}
.pc-scroll::-webkit-scrollbar { height: 6px; }
.pc-scroll::-webkit-scrollbar-thumb { background: var(--q-hairline); border-radius: 3px; }
.pc-tile {
  flex: 0 0 auto; width: var(--pc-tile-size); height: var(--pc-tile-size);
  padding: 0; border: none;
  background: var(--q-surface-muted); border-radius: 10px; overflow: hidden;
  box-shadow: inset 0 0 0 0.5px var(--q-hairline); cursor: pointer;
  scroll-snap-align: start; transition: transform 0.12s ease, box-shadow 0.12s ease;
}
.pc-tile:hover { transform: translateY(-1px); box-shadow: 0 2px 8px rgba(0,0,0,0.08), inset 0 0 0 0.5px var(--q-hairline); }
.pc-tile:focus-visible { outline: 2px solid var(--q-primary); outline-offset: 2px; }
.pc-tile img { width: 100%; height: 100%; object-fit: cover; display: block; }
`;
