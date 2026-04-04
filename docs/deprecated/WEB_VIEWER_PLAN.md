> **DEPRECATED:** Original plan for a glTF-based web viewer. Implemented differently — uses Three.js `OBJLoader` with OpenMVS texture atlases, interior camera controls, and HD toggle. See `cloud/api/web/contractor_view.html`.

# Web Viewer Plan — Interactive 3D Room Tour

> **Prerequisite**: `CLOUD_PIPELINE_PLAN.md` (Stages 1-4b + 6) and `VISUALIZATION_PLAN.md` (Stages 5, 7, 8) must produce glTF models, floor plan SVGs, and annotation JSON before this viewer has content to display.
>
> **Related**: `DNN_COMPONENT_TAXONOMY.md` defines the component labels shown in the viewer sidebar.

---

## Overview

Browser-based interactive 3D room viewer with floor plan navigation. Users can orbit/pan/zoom the textured room model, toggle measurement overlays, and navigate between rooms via the floor plan. The experience is shareable via URL — homeowners, contractors, and internal users access the same viewer.

Target experience: Zillow 3D Home Tour style room navigation with Xactimate-style measurement layer overlay.

---

## Architecture

```
web/
├── app/                           (Next.js or Vite + React)
│   ├── pages/
│   │   ├── property/[id].tsx      (property overview — floor plan + room list)
│   │   └── room/[scanId].tsx      (3D room viewer)
│   ├── components/
│   │   ├── FloorPlanViewer.tsx    (SVG floor plan with clickable rooms)
│   │   ├── RoomViewer3D.tsx       (Three.js canvas — orbit/pan/zoom)
│   │   ├── MeasurementOverlay.tsx (3D annotation layer — toggle on/off)
│   │   ├── FloorSelector.tsx      (floor tabs with transparency stacking)
│   │   ├── ComponentPanel.tsx     (detected components list + icons)
│   │   └── MeasurementPanel.tsx   (tabular measurements — Xactimate style)
│   └── lib/
│       ├── gltfLoader.ts          (fetch + load glTF from GCS signed URL)
│       ├── annotationRenderer.ts  (render annotation JSON as Three.js sprites/lines)
│       └── floorPlanInteraction.ts (SVG click → room navigation)
├── public/
│   └── icons/                     (appliance SVG icons for floor plan)
└── package.json
```

---

## 3D Room Viewer (Three.js)

1. **Model loading**: Fetch glTF from GCS via signed URL (or public CDN). Load with Three.js `GLTFLoader`.
2. **Camera**: `OrbitControls` — orbit, pan, zoom. Initial camera position: center of room, elevated 45°, looking at room center.
3. **Textured surfaces**: Each surface (wall, floor, ceiling) has its own material with the projected texture from Stage 5. Untextured surfaces get a flat material colored by classification.
4. **Object meshes**: Appliances and cabinets rendered as simple box meshes with labels. Click to show details (type, dimensions).
5. **Measurement overlay**: Load annotation JSON (Stage 8). Render as:
   - **Linear dimensions**: 3D line segments with CSS2DRenderer text labels. Leader lines with tick marks at endpoints.
   - **Area labels**: Billboard sprites centered on surfaces.
   - **Component labels**: Floating tags at object positions.
   - Toggle button: "Show Measurements" / "Hide Measurements". Sub-toggles per category (dimensions, areas, components).
6. **Lighting**: Ambient + directional light. No shadows needed for MVP.

---

## Floor Plan Navigation

1. **Property page** (`/property/{id}`):
   - Shows the stitched floor plan (SVG from Stage 7) for the active floor.
   - Floor selector tabs at top (1st Floor, 2nd Floor, Basement).
   - Non-active floors rendered at 20% opacity behind the active floor.
   - Appliance icons from adjacent floors visible through semi-transparent overlay.
   - Click a room polygon → navigate to `/room/{scanId}` (3D viewer).
   - Sidebar: property address, RFQ status, scan dates, total room count.

2. **Room page** (`/room/{scanId}`):
   - 3D viewer (Three.js) fills the main content area.
   - Sidebar:
     - Room name + floor
     - Measurements table (Xactimate-style): wall lengths, ceiling height, floor area, wall area, perimeter
     - Detected components list with icons
     - Material callouts (floor type, ceiling type)
   - Top bar: "Show Measurements" toggle, "Floor Plan" button (back to property page).

---

## Multi-Floor Semi-Transparency

The floor plan viewer composites floor SVGs in a stack:
- Active floor: 100% opacity, full color, interactive (clickable rooms).
- Floor directly above/below: 20% opacity, muted color, non-interactive but visible.
- Floors 2+ away: hidden.
- Appliance icons on adjacent floors render at 40% opacity with a subtle "through-floor" indicator line (dashed vertical).

This lets a contractor looking at the 1st floor see that there's a toilet on the 2nd floor directly above the kitchen — implying a plumbing stack.

---

## Auth & Sharing

- URLs are scoped: `/property/{property_id}` and `/room/{scan_id}`.
- Auth: Firebase Auth JWT (same as iOS app). Check that the user has access to the RFQ/property.
- Shareable links: Homeowner or contractor can generate a time-limited signed URL for read-only access (no auth required).
- Roles: homeowner sees their properties. Contractor sees RFQs they've been invited to bid on. Internal sees everything.

---

## API Additions Required

The existing Cloud Run REST API needs these new endpoints:

- `GET /api/properties/{property_id}/floor-plan` → returns plan_metadata.json
- `GET /api/properties/{property_id}/floors` → returns floor list with SVG URLs
- `GET /api/scans/{scan_id}/model-url` → returns signed URL for glTF download
- `GET /api/scans/{scan_id}/annotations` → returns measurement annotation JSON

---

## Deployment

- **Hosting**: Vercel (Next.js) or Cloud Run (static build + API proxy).
- **Asset delivery**: glTF models + textures + SVGs served from GCS with CDN (Cloud CDN or Cloudflare).
- **API**: Existing Cloud Run REST API extended with new endpoints above.

---

## Dependencies

```json
{
  "dependencies": {
    "react": "^19.0",
    "next": "^15.0",
    "three": "^0.170",
    "@react-three/fiber": "^9.0",
    "@react-three/drei": "^10.0",
    "firebase": "^11.0",
    "@tanstack/react-query": "^5.0"
  }
}
```

- **Three.js + R3F**: 3D rendering with React integration. `@react-three/drei` provides OrbitControls, CSS2DRenderer (for measurement labels), and GLTFLoader wrappers.
- **Next.js**: SSR for initial page load + dynamic routes (`/property/[id]`, `/room/[scanId]`).
- **Firebase**: Auth (JWT verification), same project as iOS app.
- **React Query**: Data fetching for scan status, measurements, and floor plan metadata.

---

## Test Cases

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S9.1 | 3D model loads in browser | Navigate to /room/{scanId} | Room model renders in Three.js canvas | glTF loads without errors; geometry visible within 3 seconds |
| S9.2 | Orbit controls work | Click-drag on 3D view | Camera orbits around room center | Camera position changes; model stays centered |
| S9.3 | Pinch/scroll zoom works | Scroll wheel or pinch on 3D view | Camera zooms in/out | FOV or distance changes; no clipping through walls at close range |
| S9.4 | Measurement overlay toggles | Click "Show Measurements" | Dimensional labels appear on surfaces | Wall lengths visible at ceiling line; floor area label centered; toggle off hides all |
| S9.5 | Floor plan renders | Navigate to /property/{id} | SVG floor plan displayed with room outlines | All rooms visible; room labels centered; doors/windows indicated |
| S9.6 | Click room → 3D viewer | Click a room polygon on floor plan | Navigate to /room/{scanId} | Correct room's 3D model loads; back button returns to floor plan |
| S9.7 | Floor selector switches floors | Click "2nd Floor" tab | 2nd floor plan becomes active at 100% opacity | 1st floor drops to 20% opacity; 2nd floor rooms are clickable |
| S9.8 | Adjacent floor appliances visible | View 1st floor with 2nd floor semi-transparent | Toilet icon from 2nd floor visible at reduced opacity | Icon position matches 2nd floor toilet XZ; opacity ≈ 20-40% |
| S9.9 | Measurement sidebar shows Xactimate-style data | Open room viewer sidebar | Table of measurements with labels + values | Ceiling height, floor area, wall area, perimeter all listed with units |
| S9.10 | Detected components listed | Room with sink + cabinets + hardwood | Components panel shows all detected items | Each item has icon, label, and relevant measurement |
| S9.11 | Auth required for viewer | Open room URL without auth | Redirected to login | HTTP 401 or redirect to Firebase Auth sign-in |
| S9.12 | Shareable link works without auth | Generate signed URL, open in incognito | Room viewer loads read-only | Model and measurements visible; no edit controls |
| S9.13 | Mobile browser responsive | Open room viewer on iPhone Safari | Layout adapts to mobile viewport | Touch orbit/zoom works; sidebar collapses to bottom sheet; floor plan is scrollable |

---

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| glTF file too large for browser | Slow page load | Simplify geometry aggressively in Stage 3 (< 200 vertices). Compress textures to JPEG at 0.85 quality. Use Draco mesh compression in glTF. Target < 10MB total. |
| Three.js performance on mobile | 3D viewer stutters on older phones | Keep triangle count low (< 500 per room). Use LOD (level of detail). Lazy-load textures. Test on iPhone 12 as baseline. |
| Auth complexity for shareable links | Signed URLs expire; Firebase Auth adds friction for casual viewers | Time-limited signed URLs (24hr) for sharing. No auth required for read-only view via signed URL. Full auth only for editing/quoting. |
| Web viewer scope creep | Stage 9 becomes a full product | MVP web viewer is read-only: view model, toggle measurements, navigate rooms. No editing, no quoting, no annotations. Quote builder is a separate frontend. |
