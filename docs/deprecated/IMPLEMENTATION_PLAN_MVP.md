> **DEPRECATED:** MVP plan for the 1-month Quoterra pilot. Most features were implemented but the app has since evolved significantly (auth, project overview, coverage review, OpenMVS integration). See `CLAUDE.md` for current state.

# Implementation Plan — MVP Alpha (Quoterra Chicago Test)

## Overview

This plan gets RoomScanAlpha from its current state (scan → upload → cloud dimensions) to a testable alpha for the 1-month Chicago Quoterra pilot. The goal is to validate two hypotheses:

1. **Value:** Contractors will pay 2% of GMV for leads with room scans + remote quotes
2. **Growth:** Homeowners will convert on the promise of fast, transparent, remote quotes

Everything in this plan serves the funnel: **Ad → Email signup → TestFlight install → Scan submitted → Quotes received → Job won.** If a feature doesn't move a homeowner or contractor through that funnel, it's cut.

### What Already Works (Phase 1)

- AR scanning with LiDAR mesh + keyframes + depth
- Upload to GCS via signed URLs
- 3-stage cloud processing (PLY parse → RANSAC plane fit → room geometry)
- Room dimensions returned: floor area, wall area, ceiling height, perimeter (imperial)
- 3D mesh viewer (SceneKit, classification-colored)
- FCM push notifications on processing complete
- Firebase anonymous auth, RFQ management

### What's Missing for the Alpha Funnel

| Gap | Why it matters |
|-----|---------------|
| No usable room polygon | The DNN polygon is non-functional. Users must trace the room shape on-device via AR corner annotation. |
| No scan controls | Users have never done this before — they need start/stop/redo to feel in control |
| No post-scan frame selection | Current approach keeps all frames; need to capture ~80 and keep the best 60 |
| Floor plan not displayed | Contractors need a 2D layout to understand the room and quote accurately |
| No scan deletion | Users stuck with bad scans forever |
| No quote delivery to homeowners | The funnel breaks at step 5 — no way to get bids back to homeowners |
| No scan notification to contractors | Contractors don't know when a new scan arrives to quote on |
| No contractor-facing view of scans | Contractors need to see dimensions + floor plan + 3D to write quotes |
| No textured room visualization | Polygon outlines and numbers aren't enough — contractors need to see the actual room surfaces |
| No interactive 3D viewer | Static page can't compete; contractors need orbit/zoom/measure to write accurate quotes |
| No job-won tracking | Can't measure the test's core metric (won jobs, 2% GMV) |

### What's Cut (Deferred Post-Alpha)

- ~~Real-time frame quality scoring during scan~~ — post-scan selection of best 60 from ~80 is sufficient
- ~~Coverage gap detection + adaptive capture thresholds~~ — overcomplicated for alpha
- ~~Multi-trace annotation (ceiling + floor)~~ — single ceiling trace gets the room polygon
- ~~Edge types (door/open_cased/open_pass)~~ — every edge is a wall for now
- ~~Zoom loupe + per-corner confidence badges~~ — nice polish, not needed to get corners
- ~~Training pipeline routing (GCS training paths, training_status, batch IDs)~~ — no model retraining during the 1-month test
- ~~Seam blending between adjacent surfaces~~ — visible seams are acceptable for alpha
- ~~Depth-based occlusion masking~~ — furniture blocking surfaces is rare in empty renovation rooms
- ~~Multi-floor semi-transparency stacking~~ — most alpha scans are single-floor
- ~~React/Next.js web app~~ — vanilla JS + Three.js CDN is faster to ship and sufficient for alpha
- ~~SVG floor plan generation (Stage 7)~~ — Canvas 2D rendering in the browser is good enough
- ~~Component panel with icons~~ — detected components list is sufficient without custom icons

---

## Step 1: Start / Stop / Redo Scan Controls

Users are doing this for the first time. They need to feel in control of when scanning starts, when it stops, and the ability to redo if something went wrong.

### State Machine Update

**File to modify:** `RoomScanAlpha/Models/ScanState.swift`

Add `scanReady` state. The annotation state slots in after scanning (see Step 3):

```
idle → selectingRFQ → scanReady → scanning → annotatingCorners → labelingRoom → exporting → uploading → viewingResults
                         ↑            │                                                                          │
                         └── redo ────┘                                                                          │
                         ↑                                                                                       │
                         └──────────────────────── "Scan Another Room" ─────────────────────────────────────────┘
```

### UI Changes

**File to modify:** `RoomScanAlpha/Views/ScanningView.swift`

- **Pre-scan (`scanReady`):** AR preview visible in background. "Start Scan" button (large, centered). User can see the room in AR before committing.
- **During scan (`scanning`):** "Stop Scan" button replaces current stop button. Frame count + triangle count HUD visible.
- Tapping "Stop Scan" transitions to `annotatingCorners` (Step 3). The AR session stays running.

### Logic Changes

**File to modify:** `RoomScanAlpha/ViewModels/ScanViewModel.swift`

- `startScan()` — transitions from `scanReady` → `scanning`, begins AR capture
- `stopScan()` — hides capture HUD, transitions to `annotatingCorners`. **Does NOT pause or end the AR session.** Mesh reconstruction continues.
- `redoScan()` — clears captured frames, resets mesh stats, resets AR session, returns to `scanReady`

**File to modify:** `RoomScanAlpha/AR/ARSessionManager.swift`

- Add `resetSession()` for redo — calls `ARSession.run(_:options: [.resetTracking, .removeExistingAnchors])`
- **No session pause on stop** — session stays fully running during annotation

**File to modify:** `RoomScanAlpha/AR/FrameCaptureManager.swift`

- Add `reset()` — clears captured frames array, resets counters
- Raise capture cap from 60 to ~80 (best 60 selected post-scan in Step 2)

**File to modify:** `RoomScanAlpha/ContentView.swift`

- Wire `scanReady` and `annotatingCorners` states into the view router
- Update "Scan Another Room" action to route to `scanReady`

### Test Cases — Step 1

| ID | Test | Pass Criteria |
|----|------|---------------|
| 1.1 | State: idle → scanReady | After selecting RFQ, state is `scanReady` |
| 1.2 | State: scanReady → scanning | `startScan()` begins AR capture |
| 1.3 | State: scanning → annotatingCorners | `stopScan()` transitions; AR session still running |
| 1.4 | Redo clears all state | `redoScan()` returns to `scanReady`; `keyframeCount == 0` |
| 1.5 | FrameCaptureManager.reset() clears frames | After reset, `capturedFrames.count == 0` |
| 1.6 | "Scan Another Room" routes to scanReady | From viewingResults, goes to `scanReady` not `.scanning` |

| ID | Manual Test | Pass Criteria |
|----|-------------|---------------|
| 1.M1 | Start scan button visible | "Start Scan" centered on screen, AR preview behind |
| 1.M2 | Stop scan transitions to annotation | Annotation UI appears; AR camera feed still live |
| 1.M3 | Redo resets everything | Back to scanReady; frame count 0; AR preview clean |

### Files Summary — Step 1

| Action | File |
|--------|------|
| **Modify** | `RoomScanAlpha/Models/ScanState.swift` — add `scanReady`, `annotatingCorners` |
| **Modify** | `RoomScanAlpha/ViewModels/ScanViewModel.swift` — `startScan()`, `stopScan()`, `redoScan()` |
| **Modify** | `RoomScanAlpha/AR/ARSessionManager.swift` — `resetSession()`; no pause on stop |
| **Modify** | `RoomScanAlpha/AR/FrameCaptureManager.swift` — `reset()`; raise cap to ~80 |
| **Modify** | `RoomScanAlpha/Views/ScanningView.swift` — start/stop UI |
| **Modify** | `RoomScanAlpha/ContentView.swift` — route new states |

---

## Step 2: Post-Scan Frame Selection (Best 60 of ~80)

Instead of real-time quality scoring with coverage tracking and adaptive thresholds, take a simpler approach: capture ~80 frames during the scan, then after the scan stops, score them all and keep the best 60.

### Frame Quality Scoring

**New file:** `RoomScanAlpha/AR/FrameQualityScorer.swift`

Score each captured frame on two dimensions:

| Metric | How | Weight |
|--------|-----|--------|
| **Sharpness** | Laplacian variance on grayscale via Accelerate/vImage | 0.5 |
| **Feature density** | Harris/Shi-Tomasi corner count via Accelerate | 0.5 |

Each dimension normalized to 0–1, composite = weighted sum. Scoring runs on the stored JPEG data — no need to intercept the capture pipeline or score raw pixel buffers in real time.

### Post-Scan Selection Logic

**File to modify:** `RoomScanAlpha/AR/FrameCaptureManager.swift`

After `stopScan()` is called (transition to `annotatingCorners`):

1. Score all ~80 captured frames using `FrameQualityScorer`
2. Sort by composite score descending
3. Keep the top 60, discard the rest
4. This runs in the background while the user begins corner annotation — no blocking

The capture thresholds (0.15m / 15°) remain unchanged. The only change is capturing ~80 instead of 60, then pruning.

### Test Cases — Step 2

| ID | Test | Pass Criteria |
|----|------|---------------|
| 2.1 | Sharpness: sharp image scores high | Crisp checkerboard > 0.8 |
| 2.2 | Sharpness: blurry image scores low | Gaussian-blurred < 0.3 |
| 2.3 | Feature density: textured > blank | Textured wall > 0.5, solid white < 0.1 |
| 2.4 | Post-scan selection keeps 60 | Start with 80 frames, end with 60 after selection |
| 2.5 | Kept frames are highest-scoring | Lowest-scoring kept frame > highest-scoring discarded frame |
| 2.6 | Selection runs async | User can begin annotation before selection completes |

### Files Summary — Step 2

| Action | File |
|--------|------|
| **New** | `RoomScanAlpha/AR/FrameQualityScorer.swift` — sharpness + feature density scoring |
| **Modify** | `RoomScanAlpha/AR/FrameCaptureManager.swift` — post-scan prune to best 60 |

---

## Step 3: AR Corner Annotation (Crosshair)

The DNN room polygon is non-functional. The user traces the room boundary by aiming a crosshair at each ceiling corner and locking it in. This is how we get a usable room shape for the floor plan.

Simplified from the original Phase 2 plan: single ceiling trace only, no edge types, no zoom loupe, no per-corner confidence badges. Plane-intersection snap is kept because it meaningfully improves corner accuracy at wall-ceiling junctions.

### Interaction Model

The AR session stays **fully running** during annotation — mesh reconstruction continues improving while the user walks the room tracing corners.

**Center-screen crosshair:** The user physically aims the device at each ceiling corner, then taps a "Lock Corner" button (or anywhere on screen) to confirm. The raycast fires from the exact center pixel.

**Why crosshair over direct tap:** At 1.5–2.5m phone-to-ceiling distance, the user's fingertip occludes the target corner during a direct tap, causing several centimeters of positional error. The crosshair keeps the target visible; the confirmation tap can be anywhere.

### Plane-Intersection Snap

LiDAR mesh at wall-ceiling intersections is noisy. When the raycast hit point is within ~5cm of where two classified surfaces meet (wall + ceiling, or wall + wall), compute the geometric intersection of those two planes and snap the corner to that intersection point.

Implementation: use face classification labels from `ARMeshAnchor`. For each raycast hit, check nearby faces' classifications. If two different surface types are nearby, fit planes to each surface's local vertices using RANSAC and compute their intersection line. Project the hit point onto that line.

### New UI

**New file:** `RoomScanAlpha/Views/CornerAnnotationView.swift`

A SwiftUI view wrapping `ARSCNView` that appears after the user taps "Stop Scan." The AR session remains fully running.

**Prompt banner:** "Walk around the room and aim at each ceiling corner. Tap to lock it in."

**Controls:**
- **Center-screen crosshair** — fixed reticle
- **"Lock Corner" button** (bottom of screen) — fires raycast from screen center, applies plane-intersection snap, places corner
- Each locked corner places a visible sphere node at the hit point with a numbered label (1, 2, 3…)
- **Auto-connect lines:** each new corner draws a line from the previous corner
- When ≥ 3 corners placed, polygon fills with semi-transparent overlay so user can verify the room outline

**Closing the polygon:** "Close Trace" button (enabled at ≥ 3 corners) — auto-draws closing edge from last corner back to corner 1. Shows computed area for sanity check.

**Editing:**
- **"Undo Last"** button — removes most recent corner (only before closing)
- **"Redo Scan"** button — clears all corners + captured frames, returns to `scanReady`

**Completion:**
- **"Done"** button — enabled when polygon is closed with ≥ 3 corners, validates polygon (no self-intersection, area between 1m² and 500m²), transitions to `labelingRoom`
- **"Skip"** button — skips annotation entirely, proceeds to `labelingRoom` without corner data (scan still uploads; dimensions come from cloud processing alone)

### Data Model

**New file:** `RoomScanAlpha/Models/CornerAnnotation.swift`

```swift
struct CornerAnnotation: Codable {
    let corners_xz: [[Float]]       // [[x, z], ...] in meters, AR world space, CCW winding
    let corners_y: [Float]           // per-corner Y height for validation
    let annotation_method: String    // "ar_crosshair_snap"
    let timestamp: String            // ISO 8601
}
```

**New file:** `RoomScanAlpha/ViewModels/CornerAnnotationViewModel.swift`

- Manages corner array: `[(x: Float, y: Float, z: Float)]`
- Performs plane-intersection snap logic using nearby mesh face classifications with RANSAC
- Validates polygon: no self-intersection, area between 1m² and 500m²
- **Winding order normalization** — always export CCW (detect via shoelace formula sign, reverse if CW)
- Computes running polygon area for display
- Provides `cornerAnnotation: CornerAnnotation` for export

### Test Cases — Step 3

| ID | Test | Pass Criteria |
|----|------|---------------|
| 3.1 | Self-intersection detection | Bowtie polygon → validation rejects |
| 3.2 | Valid polygon accepted | 4-corner rectangle, CCW → validation passes, area > 1m² |
| 3.3 | CW winding auto-corrected to CCW | CW input → exported as CCW |
| 3.4 | Area bounds enforced | Polygon with area = 0.5m² → rejected |
| 3.5 | Undo removes last corner | 5 corners → undo → 4 corners remain |
| 3.6 | Skip produces nil annotation | Skip → `cornerAnnotation == nil` |

| ID | Manual Test | Pass Criteria |
|----|-------------|---------------|
| 3.M1 | Crosshair + Lock Corner | Aim at ceiling corner, tap → sphere appears at correct position |
| 3.M2 | Plane-intersection snap | Aim at wall-ceiling junction → corner sits precisely at the crease |
| 3.M3 | Auto-connect lines visible | Lock 4 corners → polygon outline visible in AR |
| 3.M4 | Close trace shows area | Close polygon → area displayed (m²) |
| 3.M5 | Redo from annotation | Tap "Redo Scan" → scanReady; all data cleared |
| 3.M6 | Mesh continues improving | Watch triangle count during annotation → count increases |

### Files Summary — Step 3

| Action | File |
|--------|------|
| **New** | `RoomScanAlpha/Views/CornerAnnotationView.swift` — crosshair UI, auto-connect lines, close/undo/skip/done |
| **New** | `RoomScanAlpha/ViewModels/CornerAnnotationViewModel.swift` — corner management, RANSAC snap, polygon validation, winding normalization |
| **New** | `RoomScanAlpha/Models/CornerAnnotation.swift` — `CornerAnnotation` Codable model |
| **Modify** | `RoomScanAlpha/ViewModels/ScanViewModel.swift` — `stopScan()` → `.annotatingCorners`; store annotation; wire redo/skip/done |
| **Modify** | `RoomScanAlpha/AR/ARSessionManager.swift` — session stays running during annotation; terminate only at export |

---

## Step 4: Upload Annotation + Compute Dimensions from Polygon

The user-traced polygon is the source of truth for the room shape. Upload it with the scan package and use it in cloud processing to compute accurate room dimensions.

### Metadata Update

**File to modify:** `RoomScanAlpha/Export/ScanPackager.swift`

Add `corner_annotation` to `metadata.json`:

```json
{
    "rfq_id": "...",
    "room_label": "Kitchen",
    "keyframe_count": 60,
    "...existing fields...",

    "corner_annotation": {
        "corners_xz": [[-2.5, -1.8], [2.5, -1.8], [2.5, 3.0], [-2.5, 3.0]],
        "corners_y": [2.44, 2.43, 2.45, 2.44],
        "annotation_method": "ar_crosshair_snap",
        "timestamp": "2026-04-10T10:00:00Z"
    }
}
```

`corner_annotation` is omitted entirely when the user skips annotation (absent key, not null).

### Cloud Processor Changes

**File to modify:** `cloud/processor/main.py`

After PLY processing, check `metadata.json` for `corner_annotation`:
- **If present:** Use the annotated polygon as the room shape. Compute floor area, perimeter, and wall area from this polygon + ceiling height (from Stage 2 RANSAC). This replaces the Stage 3 geometric/DNN polygon for dimension calculations.
- **If absent:** Fall back to existing Stage 3 pipeline (geometric boundary extraction)
- Convert annotated polygon from meters to feet
- Store polygon + dimensions in `scanned_rooms` DB row

**New file:** `cloud/migrations/002_add_room_polygon.sql`

```sql
ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS room_polygon_ft JSON DEFAULT NULL;
ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS wall_heights_ft JSON DEFAULT NULL;
ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS polygon_source TEXT DEFAULT NULL;
-- polygon_source: 'annotated', 'geometric', 'dnn'
```

### Cloud API Changes

**File to modify:** `cloud/api/main.py`

Extend `GET /api/rfqs/{rfqId}/scans/{scanId}/status` response:

```json
{
    "scan_id": "uuid",
    "status": "scan_ready",
    "floor_area_sqft": 250.5,
    "wall_area_sqft": 1200.0,
    "ceiling_height_ft": 8.5,
    "perimeter_linear_ft": 65.0,
    "detected_components": { "...existing..." },
    "scan_dimensions": { "...existing..." },

    "room_polygon_ft": [[0, 0], [12.5, 0], [12.5, 18.0], [0, 18.0]],
    "wall_heights_ft": [8.5, 8.5, 8.5, 8.5],
    "polygon_source": "annotated",
    "scan_mesh_url": "https://storage.googleapis.com/...(signed 7-day)..."
}
```

### iOS Changes

**File to modify:** `RoomScanAlpha/Cloud/CloudUploader.swift`

- Parse `room_polygon_ft`, `wall_heights_ft`, `scan_mesh_url` from status response
- Add to `ScanResult` struct

### Test Cases — Step 4

| ID | Test | Pass Criteria |
|----|------|---------------|
| 4.1 | Annotated polygon in metadata.json | `corner_annotation` block present with CCW corners |
| 4.2 | Skipped annotation omits block | `corner_annotation` key absent from JSON |
| 4.3 | Cloud uses annotated polygon for dimensions | Floor area computed from annotation polygon, not Stage 3 |
| 4.4 | Dimensions match polygon geometry | Polygon area × 10.7639 ≈ `floor_area_sqft` |
| 4.5 | Fallback to Stage 3 when no annotation | Unannotated scan uses geometric polygon |
| 4.6 | API returns polygon in feet | `room_polygon_ft` values are in feet |
| 4.7 | Signed mesh URL works | URL returns PLY, expires after 7 days |
| 4.8 | Phase 1 scans return null | `room_polygon_ft` is null for old scans |

### Files Summary — Step 4

| Action | File |
|--------|------|
| **Modify** | `RoomScanAlpha/Export/ScanPackager.swift` — add `corner_annotation` to metadata |
| **Modify** | `cloud/processor/main.py` — use annotated polygon for dimensions; store in DB |
| **Modify** | `cloud/api/main.py` — return polygon + signed mesh URL in status response |
| **New** | `cloud/migrations/002_add_room_polygon.sql` — polygon + source columns |
| **Modify** | `RoomScanAlpha/Cloud/CloudUploader.swift` — parse new response fields |

---

## Step 5: Delete Scans

Users will make mistakes, especially first-timers. They need to be able to delete bad scans.

### iOS Changes

**File to modify:** `RoomScanAlpha/Views/ScanHistoryView.swift`

- Swipe-to-delete on scan rows
- Confirmation alert: "Delete scan? This cannot be undone."
- Delete flow: call backend DELETE first, wait for 200, THEN delete local record. If API call fails, show error and keep local record (prevents desync).

**File to modify:** `RoomScanAlpha/Cloud/RFQService.swift`

- Add `deleteScan(rfqId: String, scanId: String) async throws`

### Backend Changes

**File to modify:** `cloud/api/main.py`

- `DELETE /api/rfqs/{rfqId}/scans/{scanId}`
- Soft-delete: `UPDATE scanned_rooms SET scan_status = 'deleted' WHERE id = ?`
- Does NOT delete GCS blob (storage is cheap; data may be useful for future training)

### Test Cases — Step 5

| ID | Test | Pass Criteria |
|----|------|---------------|
| 5.1 | DELETE endpoint soft-deletes | `scan_status = 'deleted'`; row still exists |
| 5.2 | Deleted scan returns 404 on status | GET status → 404 |
| 5.3 | Delete fails gracefully offline | Error shown; local record NOT deleted |

| ID | Manual Test | Pass Criteria |
|----|-------------|---------------|
| 5.M1 | Swipe-to-delete appears | Red "Delete" button on swipe |
| 5.M2 | Successful delete removes row | Spinner during API call; row animates out |

### Files Summary — Step 5

| Action | File |
|--------|------|
| **Modify** | `RoomScanAlpha/Views/ScanHistoryView.swift` — swipe-to-delete + confirmation |
| **Modify** | `RoomScanAlpha/Cloud/RFQService.swift` — `deleteScan()` API call |
| **Modify** | `cloud/api/main.py` — DELETE endpoint |

---

## Step 6: Floor Plan View in App

Display the user-annotated room polygon as a 2D floor plan with labeled dimensions. Tapping a room opens its 3D view.

### Floor Plan View

**New file:** `RoomScanAlpha/Views/FloorPlanView.swift`

A SwiftUI view that renders all scanned rooms for the current RFQ as 2D polygons:

- **Room polygons** drawn as filled shapes with room labels (e.g., "Kitchen")
- **Wall dimensions** labeled on each edge in feet/inches (e.g., "12' 6\"")
- **Total area** shown inside each room polygon
- **Tap a room** → opens the 3D mesh viewer for that room (modal sheet)
- **Pinch to zoom / drag to pan** — standard gesture handling
- Rooms positioned relative to each other using `origin_x`, `origin_y`, `rotation_deg` from each scan's RFQ context (already captured in Phase 1)

**Layout logic:** Each room's polygon is in its own local coordinate space (origin at first corner). Transform to the shared floor plan space using the RFQ context origin + rotation. If only one room is scanned, it's centered.

### Integration

**File to modify:** `RoomScanAlpha/Views/ScanResultView.swift`

- Add "View Floor Plan" button (enabled when `room_polygon_ft` is non-nil)

**File to modify:** `RoomScanAlpha/ContentView.swift`

- After all rooms are scanned ("Done"), show floor plan as summary view

### 3D Viewer from Floor Plan

**File to modify:** `RoomScanAlpha/Views/MeshViewerView.swift`

- Accept an optional `scanMeshURL: URL?` parameter
- If mesh anchors available (just scanned), use them directly (existing behavior)
- If mesh URL provided (viewing from history/floor plan), download the PLY and render it
- Add PLY-to-SceneKit loader (vertices + faces → SCNGeometry)

### Test Cases — Step 6

| ID | Test | Pass Criteria |
|----|------|---------------|
| 6.1 | Single room renders as polygon | Correct shape with room label |
| 6.2 | Wall dimensions labeled | Each edge shows feet/inches |
| 6.3 | Area shown inside room | Floor area (sq ft) centered in polygon |
| 6.4 | Tap room opens 3D viewer | Modal sheet with MeshViewerView |
| 6.5 | Multi-room layout | Two rooms positioned correctly via RFQ origins |
| 6.6 | Pinch zoom + pan | Standard gestures work |
| 6.7 | PLY download + render from URL | 3D viewer loads mesh from signed GCS URL |
| 6.8 | Floor plan hidden when no polygon | Button absent for scans without polygon |

### Files Summary — Step 6

| Action | File |
|--------|------|
| **New** | `RoomScanAlpha/Views/FloorPlanView.swift` — 2D floor plan with dimensions + tap-to-3D |
| **Modify** | `RoomScanAlpha/Views/ScanResultView.swift` — add floor plan button |
| **Modify** | `RoomScanAlpha/Views/MeshViewerView.swift` — accept mesh URL, PLY loader |
| **Modify** | `RoomScanAlpha/ContentView.swift` — floor plan summary view |

---

## Step 7: Contractor Web View

Contractors need to see the scan results to write quotes. A simple web page (not an app) that shows everything a contractor needs.

### Contractor Scan Page

**New file:** `cloud/web/contractor_view.html` (static HTML + JS, served from Cloud Run or GCS)

Accessed via unique link (e.g., `https://app.quoterra.co/quote/{rfq_id}`). No login required — the link IS the auth (obscurity is fine for alpha).

**Page content:**
- Job description + address (from RFQ)
- **For each scanned room:**
  - Room label
  - Floor plan polygon with labeled wall dimensions
  - Room metrics: floor area, wall area, ceiling height, perimeter
  - Detected components
  - "View 3D Scan" button → embedded 3D viewer (three.js with PLY loader) or download link
- **"Submit Quote" button** → opens pre-filled email or simple form

### API Endpoint

**File to modify:** `cloud/api/main.py`

- `GET /api/rfqs/{rfqId}/contractor-view` — returns all scan data for all rooms on this RFQ. No auth (link-based for alpha).

```json
{
    "rfq_id": "uuid",
    "address": "123 Main St, Chicago IL",
    "job_description": "Kitchen and bathroom remodel",
    "rooms": [
        {
            "scan_id": "uuid",
            "room_label": "Kitchen",
            "floor_area_sqft": 250.5,
            "wall_area_sqft": 1200.0,
            "ceiling_height_ft": 8.5,
            "perimeter_linear_ft": 65.0,
            "room_polygon_ft": [[0,0], [12.5,0], [12.5,18.0], [0,18.0]],
            "detected_components": {"detected": ["floor_hardwood"]},
            "mesh_url": "https://storage.googleapis.com/...(signed)..."
        }
    ]
}
```

### Test Cases — Step 7

| ID | Test | Pass Criteria |
|----|------|---------------|
| 7.1 | Contractor link loads page | Page renders with job description + address |
| 7.2 | Room dimensions displayed | All metrics shown per room |
| 7.3 | Floor plan polygon rendered | 2D polygon with wall lengths |
| 7.4 | 3D viewer loads mesh | PLY renders in browser or downloads |
| 7.5 | Submit quote works | Opens email or form with RFQ ID pre-filled |
| 7.6 | Invalid RFQ ID → 404 | Friendly error page |

### Files Summary — Step 7

| Action | File |
|--------|------|
| **New** | `cloud/web/contractor_view.html` — static page with polygon + 3D rendering |
| **Modify** | `cloud/api/main.py` — contractor-view endpoint |

---

## Step 7A: Wall/Floor/Ceiling Texture Projection

Without textures, the contractor sees polygon outlines and numbers but can't see the actual room. Texture projection gives each surface a camera-captured image — turning abstract geometry into a recognizable photo of each wall, the floor, and the ceiling. This is the difference between "dimensions of a room" and "I can see the room."

Scoped from `VISUALIZATION_PLAN.md` Stage 5, cut down for alpha: multi-keyframe blending (required — no single keyframe covers a full surface), no seam blending between adjacent surfaces, no depth-based occlusion.

### Cloud Processor Changes

**New file:** `cloud/processor/pipeline/texture_projection.py`

Core function: `project_textures(keyframes, simplified_surfaces, camera_intrinsics) → dict[surface_id, texture_jpg_bytes]`

For each simplified surface (wall quad, floor polygon, ceiling polygon):

1. **Build surface UV space**: For a wall — U = horizontal position along wall edge, V = vertical from floor to ceiling. For floor/ceiling — U = X position, V = Z position within the polygon bounding box.

2. **Score and rank keyframes per surface**: For each surface, score every keyframe by:
   - Viewing angle (prefer perpendicular to surface normal)
   - Distance (prefer closer)
   - Coverage (prefer keyframes where surface occupies more pixels in the image)
   - Select the top 3-5 keyframes per surface (a single keyframe can't cover a full wall/floor).

3. **Project texels with multi-keyframe blending**: For each pixel in the output texture image:
   - UV → 3D world position on the surface
   - For each selected keyframe, project 3D → 2D pixel using `P = K × [R|t]`
   - Check if the projected pixel falls within the keyframe image bounds
   - Sample the keyframe JPEG at those pixel coordinates (bilinear interpolation)
   - Blend contributions from multiple keyframes using weighted average (weight = viewing angle score × distance score). This fills the full surface even when no single keyframe sees it all.
   - Texels with zero keyframe coverage are marked as missing (black).

4. **Output**: One JPEG per surface (`wall_0.jpg`, `wall_1.jpg`, `floor.jpg`, `ceiling.jpg`). Resolution: ~100 px/meter for walls, ~50 px/meter for floor/ceiling. Max 2048×2048 per texture. Target ≥ 90% texel coverage per surface.

**File to modify:** `cloud/processor/main.py`

After `compute_room_metrics()`, if annotation polygon is present:
- Build simplified surfaces from the polygon edges (walls) + polygon face (floor/ceiling)
- Call `project_textures()` with the scan's keyframes
- Upload texture JPEGs to GCS: `scans/{rfq_id}/{scan_id}/textures/wall_0.jpg`, etc.
- Store texture manifest in DB (or alongside scan results)

**File to modify:** `cloud/processor/requirements.txt`

Add `Pillow>=10.0` for JPEG encoding and image sampling.

### Database Changes

**New file:** `cloud/migrations/003_add_texture_urls.sql`

```sql
ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS texture_manifest JSONB DEFAULT NULL;
-- texture_manifest: {"wall_0": "textures/wall_0.jpg", "floor": "textures/floor.jpg", ...}
```

### API Changes

**File to modify:** `cloud/api/main.py`

- Include `texture_manifest` in contractor-view response per room
- Generate signed URLs for each texture file

### Test Cases — Step 7A

| ID | Test | Pass Criteria |
|----|------|---------------|
| 7A.1 | Wall texture is recognizable | wall_0.jpg shows actual wall from scan (paint, outlets visible) |
| 7A.2 | Floor texture covers polygon | floor.jpg has ≥ 90% non-black texels |
| 7A.3 | Texture resolution scales with surface | Larger walls get more pixels; ~100 px/m |
| 7A.4 | Multi-keyframe blending fills surface | No large gaps where single keyframe lacks coverage |
| 7A.5 | Textures uploaded to GCS | Files exist at scans/{rfq_id}/{scan_id}/textures/*.jpg |
| 7A.6 | Texture manifest stored in DB | texture_manifest JSONB is populated for processed scan |

### Files Summary — Step 7A

| Action | File |
|--------|------|
| **New** | `cloud/processor/pipeline/texture_projection.py` — per-surface texture extraction |
| **New** | `cloud/migrations/003_add_texture_urls.sql` — texture manifest column |
| **Modify** | `cloud/processor/main.py` — call texture projection after metrics, upload to GCS |
| **Modify** | `cloud/processor/requirements.txt` — add Pillow |
| **Modify** | `cloud/api/main.py` — return texture URLs in contractor-view |

---

## Step 7B: Interactive Contractor Web Viewer

Replace the static contractor page with an interactive 3D room experience. The contractor sees textured walls/floor/ceiling, can orbit and zoom, toggle measurement annotations, and navigate between rooms via the floor plan. This is what makes the scan worth paying for.

Scoped from `WEB_VIEWER_PLAN.md` Stage 9, cut to MVP: single-page vanilla JS (no React/Next.js), Three.js for 3D, annotation overlay, floor plan sidebar. No multi-floor stacking, no auth, no component panel.

### Web Viewer Page

**File to modify:** `cloud/web/contractor_view.html` (replace current static page)

The page becomes an interactive viewer with two panels:

**Left panel — Floor Plan (25% width):**
- Canvas 2D floor plan (existing polygon renderer)
- Clickable rooms — click a room to load its 3D model in the main panel
- Active room highlighted, inactive rooms dimmed
- Room labels + area inside each polygon

**Main panel — 3D Room Viewer (75% width):**
- Three.js scene with OrbitControls (orbit, pan, zoom)
- Textured surfaces: each wall/floor/ceiling as a quad with its projected texture JPEG
- If no textures available, fall back to classification-colored flat surfaces
- Measurement overlay (toggle on/off):
  - Wall lengths as 3D labels at ceiling line
  - Ceiling height as vertical label in corner
  - Floor area label centered on floor
- Room metrics sidebar: floor area, wall area, ceiling height, perimeter

**Bottom bar:**
- "Submit Quote" email button (existing)
- Room label + status

### API Changes

**File to modify:** `cloud/api/main.py`

Extend contractor-view response per room:
- `texture_urls`: dict of signed URLs for each surface texture (`{"wall_0": "https://...", ...}`)
- `wall_segments_ft`: array of `{start: [x,z], end: [x,z], length_ft: float, height_ft: float}` for 3D wall construction

### Three.js Dependencies

Load via CDN (no build step for alpha):
- `three.min.js` — core renderer
- `OrbitControls.js` — camera controls
- `CSS2DRenderer.js` — measurement label overlay

### Test Cases — Step 7B

| ID | Test | Pass Criteria |
|----|------|---------------|
| 7B.1 | 3D model loads in browser | Textured room renders within 3 seconds |
| 7B.2 | Orbit/pan/zoom controls work | Camera moves smoothly; no clipping through walls |
| 7B.3 | Measurement labels visible | Wall lengths at ceiling, floor area centered, ceiling height in corner |
| 7B.4 | Measurement toggle works | "Show/Hide Measurements" button toggles all labels |
| 7B.5 | Floor plan room click → 3D | Clicking room in floor plan loads that room's model |
| 7B.6 | Untextured fallback | Room without textures shows colored flat surfaces |
| 7B.7 | Mobile browser works | Touch orbit/zoom on iOS Safari; responsive layout |

### Files Summary — Step 7B

| Action | File |
|--------|------|
| **Modify** | `cloud/web/contractor_view.html` — replace static page with Three.js interactive viewer |
| **Modify** | `cloud/api/main.py` — add texture URLs + wall segments to contractor-view response |

---

## Step 8: Twilio + Email Automation

The glue that connects homeowners to contractors. Everything outside the app and the FB ad landing page happens over email and text.

### 8A: Homeowner Scan Notification → Contractors

When a scan finishes processing, notify all signed contractors for that job type / area.

**New file:** `cloud/notifications/twilio_service.py`

- Twilio SMS + SendGrid email wrapper
- Functions: `send_sms(to, body)`, `send_email(to, subject, body_html)`
- Credentials via environment variables / Secret Manager

**File to modify:** `cloud/processor/main.py`

After processing completes (where FCM notification is sent today):
- Look up contractors for this RFQ's area/job type
- Send each contractor:
  - **SMS:** "New scan ready for quoting: Kitchen at 123 Main St. View & quote: https://app.quoterra.co/quote/{rfq_id}"
  - **Email:** Same info + floor plan image + room dimensions table

### 8B: Quote Delivery → Homeowner

**New file:** `cloud/api/quotes.py`

- `POST /api/rfqs/{rfqId}/quotes` — contractor submits quote (amount, scope, timeline, contractor name/phone)
- Stores quote in DB
- Triggers notification to homeowner:
  - **SMS:** "You received a quote for your Kitchen remodel: $12,500 from ABC Contractors. Reply YES to accept or view all quotes: [link]"
  - **Email:** Detailed quote breakdown + contractor info + accept/decline buttons

### 8C: Contractor & Quote Database

**New file:** `cloud/migrations/003_contractors_and_quotes.sql`

```sql
CREATE TABLE IF NOT EXISTS contractors (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    service_area TEXT,
    job_types TEXT,
    agreement_signed BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS quotes (
    id TEXT PRIMARY KEY,
    rfq_id TEXT NOT NULL REFERENCES rfqs(id),
    contractor_id TEXT NOT NULL REFERENCES contractors(id),
    amount_cents INTEGER NOT NULL,
    scope_description TEXT,
    timeline_days INTEGER,
    status TEXT DEFAULT 'submitted',   -- submitted, accepted, declined
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### 8D: Job Won Tracking

**File to modify:** `cloud/api/quotes.py`

- `POST /api/quotes/{quoteId}/accept` — marks quote as accepted
- Notifies contractor via SMS + email: "Your quote was accepted! Contact homeowner: [phone/email]"
- Logs the won job for 2% GMV tracking

**Twilio webhook for SMS replies:**

**New file:** `cloud/api/twilio_webhooks.py`

- `POST /api/webhooks/twilio/sms` — handles incoming SMS replies
- Parses "YES" / "ACCEPT" responses, matches to pending quote via phone number

### 8E: Homeowner Onboarding (Email → TestFlight)

**File to modify:** `cloud/api/main.py`

- `POST /api/signup` — homeowner submits email from landing page
- Stores email, sends email with TestFlight link + brief instructions

### Test Cases — Step 8

| ID | Test | Pass Criteria |
|----|------|---------------|
| 8.1 | Scan complete triggers contractor SMS | All area contractors receive SMS with link |
| 8.2 | Scan complete triggers contractor email | Email includes floor plan + dimensions |
| 8.3 | Quote submission stores in DB | Quote row created with correct IDs |
| 8.4 | Quote triggers homeowner SMS | Homeowner receives SMS with quote amount |
| 8.5 | Quote triggers homeowner email | Email includes details + accept button |
| 8.6 | SMS "YES" reply accepts quote | Webhook parses reply, updates status |
| 8.7 | Accepted quote notifies contractor | Contractor gets SMS + email confirmation |
| 8.8 | Signup email sends TestFlight link | Email delivered with correct URL |

### Files Summary — Step 8

| Action | File |
|--------|------|
| **New** | `cloud/notifications/twilio_service.py` |
| **New** | `cloud/api/quotes.py` |
| **New** | `cloud/api/twilio_webhooks.py` |
| **New** | `cloud/migrations/003_contractors_and_quotes.sql` |
| **Modify** | `cloud/processor/main.py` — trigger contractor notifications |
| **Modify** | `cloud/api/main.py` — signup endpoint, mount quote + webhook routes |

---

## Step 9: Landing Page

Simple landing page for Facebook ads. Just enough to capture email and set expectations.

**New file:** `cloud/web/landing.html` (static, served from same domain)

- Headline: "Get renovation quotes in 48 hours — no contractor visit needed"
- 3-step explainer: Scan your room → Get quotes → Pick your contractor
- Email capture form → calls `POST /api/signup`
- Thank-you state: "Check your email for the TestFlight link"
- Mobile-optimized (100% of traffic is from Facebook mobile ads)

### Test Cases — Step 9

| ID | Test | Pass Criteria |
|----|------|---------------|
| 9.1 | Page loads on mobile | Renders correctly on iPhone Safari |
| 9.2 | Email submit calls API | `POST /api/signup` fires, email stored |
| 9.3 | Thank-you state shown | Form replaced with confirmation |
| 9.4 | Invalid email rejected | Client-side validation |

### Files Summary — Step 9

| Action | File |
|--------|------|
| **New** | `cloud/web/landing.html` |

---

## Step 10: Funnel Analytics

Track every step of the funnel. Without this, you can't tell what's working.

### Event Tracking

**New file:** `cloud/api/analytics.py`

- `POST /api/events` — generic event endpoint
- Events: `ad_click`, `email_signup`, `testflight_install`, `app_open`, `scan_started`, `scan_submitted`, `scan_processed`, `quote_sent_to_contractors`, `quote_received`, `quote_accepted`, `job_won`
- Each event: `event_type`, `timestamp`, `rfq_id` (optional), `homeowner_email` (optional), `metadata` (JSON)

**New file:** `cloud/migrations/004_funnel_events.sql`

```sql
CREATE TABLE IF NOT EXISTS funnel_events (
    id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    rfq_id TEXT,
    homeowner_email TEXT,
    metadata JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### iOS Events

**New file:** `RoomScanAlpha/Cloud/AnalyticsService.swift`

- Fire events at key moments: `app_open`, `scan_started`, `scan_submitted`
- Lightweight — POST to `/api/events`, fire-and-forget

### Dashboard

No custom dashboard for alpha. Query the DB directly:

```sql
SELECT event_type, COUNT(*) as count
FROM funnel_events
WHERE created_at >= '2026-04-01'
GROUP BY event_type
ORDER BY count DESC;
```

### Test Cases — Step 10

| ID | Test | Pass Criteria |
|----|------|---------------|
| 10.1 | Event stored in DB | POST event, verify row exists |
| 10.2 | iOS fires scan_started | Event appears in DB when scan begins |
| 10.3 | Quote accepted creates job_won event | Accept flow logs event with GMV |

### Files Summary — Step 10

| Action | File |
|--------|------|
| **New** | `cloud/api/analytics.py` |
| **New** | `cloud/migrations/004_funnel_events.sql` |
| **New** | `RoomScanAlpha/Cloud/AnalyticsService.swift` |
| **Modify** | `cloud/api/main.py` — mount analytics routes |

---

## Dependency Order

```
Step 1 (start/stop/redo)  ──┐
Step 2 (frame selection)  ──┼── independent, can be done in parallel
Step 5 (scan deletion)    ──┘
         │
Step 3 (AR corner annotation) ── depends on Step 1 (state machine)
         │
Step 4 (upload polygon + cloud dimensions) ── depends on Step 3 (annotation data)
         │
Step 6 (floor plan view)  ──┐
Step 7 (contractor web)   ──┼── both depend on Step 4 (polygon in API); can be parallel
         │                  ┘
Step 8 (Twilio automation) ── depends on Step 7 (contractor view link in notifications)
         │
Step 9 (landing page)  ──┐
Step 10 (analytics)     ──┼── independent, can be done anytime
                          ┘
```

**Recommended build order:**
1. Steps 1 + 2 + 5 in parallel (scan controls + frame selection + deletion)
2. Step 3 (AR corner annotation)
3. Step 4 (upload + cloud polygon processing)
4. Steps 6 + 7 in parallel (floor plan view + contractor web view)
5. Step 8 (Twilio)
6. Steps 9 + 10 in parallel (landing page + analytics)

### Deployment Order

1. **DB migrations** (002, 003, 004)
2. **Cloud processor + API** (Steps 4, 5, 7, 8, 10 backend)
3. **iOS app** (Steps 1, 2, 3, 5, 6, 10 iOS)
4. **Static web** (Steps 7 page, 9 landing page)

---

## Files Changed (Complete)

### New Files (14)

| File | Step | Purpose |
|------|------|---------|
| `RoomScanAlpha/AR/FrameQualityScorer.swift` | 2 | Sharpness + feature density scoring |
| `RoomScanAlpha/Views/CornerAnnotationView.swift` | 3 | AR crosshair UI, auto-connect lines, close/undo/done/skip |
| `RoomScanAlpha/ViewModels/CornerAnnotationViewModel.swift` | 3 | Corner management, RANSAC snap, polygon validation |
| `RoomScanAlpha/Models/CornerAnnotation.swift` | 3 | `CornerAnnotation` Codable model |
| `RoomScanAlpha/Views/FloorPlanView.swift` | 6 | 2D floor plan with dimensions + tap-to-3D |
| `RoomScanAlpha/Cloud/AnalyticsService.swift` | 10 | iOS event firing |
| `cloud/migrations/002_add_room_polygon.sql` | 4 | Polygon + wall heights + source columns |
| `cloud/migrations/003_contractors_and_quotes.sql` | 8 | Contractor + quote tables |
| `cloud/migrations/004_funnel_events.sql` | 10 | Funnel event tracking |
| `cloud/web/contractor_view.html` | 7 | Contractor scan review + quote submission |
| `cloud/web/landing.html` | 9 | FB ad landing page |
| `cloud/notifications/twilio_service.py` | 8 | SMS + email wrapper |
| `cloud/api/quotes.py` | 8 | Quote submission + acceptance |
| `cloud/api/twilio_webhooks.py` | 8 | Inbound SMS handling |

### Modified Files — iOS (10)

| File | Steps | Changes |
|------|-------|---------|
| `RoomScanAlpha/Models/ScanState.swift` | 1 | Add `scanReady`, `annotatingCorners` states |
| `RoomScanAlpha/ViewModels/ScanViewModel.swift` | 1, 3 | `startScan()`, `stopScan()`, `redoScan()`; store annotation |
| `RoomScanAlpha/AR/ARSessionManager.swift` | 1, 3 | `resetSession()`; session stays running during annotation |
| `RoomScanAlpha/AR/FrameCaptureManager.swift` | 1, 2 | `reset()`; raise cap to ~80; post-scan prune to 60 |
| `RoomScanAlpha/Views/ScanningView.swift` | 1 | Start/stop UI |
| `RoomScanAlpha/ContentView.swift` | 1, 6 | Route new states; floor plan summary view |
| `RoomScanAlpha/Export/ScanPackager.swift` | 4 | Add `corner_annotation` to metadata |
| `RoomScanAlpha/Cloud/CloudUploader.swift` | 4 | Parse polygon + mesh URL from response |
| `RoomScanAlpha/Views/ScanResultView.swift` | 6 | Floor plan button |
| `RoomScanAlpha/Views/MeshViewerView.swift` | 6 | Accept mesh URL, PLY loader |
| `RoomScanAlpha/Views/ScanHistoryView.swift` | 5 | Swipe-to-delete |
| `RoomScanAlpha/Cloud/RFQService.swift` | 5 | `deleteScan()` API call |

### Modified Files — Cloud (2)

| File | Steps | Changes |
|------|-------|---------|
| `cloud/processor/main.py` | 4, 8 | Use annotated polygon for dimensions; store in DB; trigger contractor notifications |
| `cloud/api/main.py` | 4, 5, 7, 8, 10 | Return polygon in status; DELETE endpoint; contractor-view; signup; mount quote + webhook + analytics routes |

---

## What This Tests

| Step | Funnel stage | What it validates |
|------|-------------|-------------------|
| Steps 1–3 (scan + annotate) | Scan submitted | Will homeowners do the work of scanning + tracing corners? |
| Step 4 (polygon → dimensions) | Scan submitted → value | Are user-traced room dimensions accurate enough for contractors to quote? |
| Step 5 (deletion) | Scan submitted | Can users recover from mistakes without support? |
| Step 6 (floor plan) | Scan submitted → value | Does seeing the floor plan make the scan feel worthwhile? |
| Step 7 (contractor view) | Quotes received | Can contractors quote accurately from remote scan data? |
| Step 8 (Twilio) | Quotes received → Job won | 48hr SLA; do homeowners convert on remote quotes? |
| Step 9 (landing page) | Ad click → Email signup | Does the message resonate? Is the promise credible? |
| Step 10 (analytics) | All stages | Conversion rates at every step; LTV:CAC |

## What This Does NOT Test (Deferred)

- Whether the DNN polygon can replace manual annotation (needs training data from this alpha)
- Real-time frame quality scoring during scan (post-scan selection is sufficient)
- Edge types / opening detection (every edge is a wall for MVP)
- Multi-floor / multi-story support
- Payment collection automation (manual invoicing for 2% GMV during alpha)
- Coverage gap detection and adaptive capture thresholds

---

## Known Issues — Fix After MVP Steps Complete

### High CPU / Energy Usage During AR Scanning

**Observed:** During Xcode debug profiling, CPU utilization exceeded 140% and energy impact was rated "High." Mesh triangle count exceeded 300K during a single room scan.

**Impact:** Battery drain on device; potential thermal throttling on sustained scans; poor user experience for first-time users who may scan slowly.

**Likely causes:**
- Unbounded mesh reconstruction — ARKit's `meshWithClassification` generates increasingly dense meshes with no cap on triangle count
- Continuous mesh anchor processing in `session(_:didUpdate:)` forwarding every frame's mesh anchors to `onMeshUpdate`
- SceneKit rendering of 300K+ classified triangles in real-time overlay

**Recommended fixes (post-MVP):**
1. **Mesh decimation / LOD** — Downsample mesh anchors for display (e.g., only update SceneKit geometry every N frames or when triangle delta exceeds threshold)
2. **Throttle `onMeshUpdate` callbacks** — Skip mesh processing if last update was < 0.5s ago; only snapshot full mesh on stop
3. **Cap mesh complexity for display** — Use simplified geometry for AR overlay; keep full-res only for export
4. **Profile with Instruments** — Use Time Profiler + Energy Log to isolate whether cost is in ARKit delegate callbacks, SceneKit rendering, or keyframe JPEG encoding
5. **Consider `sceneReconstruction = .mesh`** — Drop classification during scanning if vertex colors aren't displayed in the AR overlay (re-enable for export if needed)
