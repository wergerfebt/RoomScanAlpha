# Implementation Plan — Phase 2: Training Data Capture + BEV Corner Annotation

## Overview

This plan adds features to the RoomScanAlpha iOS app for collecting high-quality training data and BEV ground-truth annotations. It serves two training pipelines:

1. **BEV DNN (RoomFormer)** — AR corner annotations provide ground-truth room polygons for fine-tuning the BEV model on real LiDAR scans. See `cloud/dnn_comparison/BEV_DNN_IMPLEMENTATION_PLAN.md`.
2. **Object Detection / Component DNN (Vertex AI)** — Higher-quality keyframe images feed the future Stage 4b component detection model (`DNN_COMPONENT_TAXONOMY.md`), which classifies materials (floor type, ceiling type, trim, cabinets) and detects appliance instances from JPEG keyframes + camera poses.

The keyframe quality improvements match production capture conditions (60-frame cap, same thresholds) so training data mirrors what the model will receive in deployment.

---

## Step 1: Adaptive Keyframe Quality System

Replace the current "capture and keep" approach with a **score-and-replace** system. Keep the 60-frame cap. The goal: 60 high-quality, well-distributed frames covering the entire room with no spatial gaps.

### 1A: Frame Quality Scoring

**New file:** `RoomScanAlpha/AR/FrameQualityScorer.swift`

Three scoring dimensions, weighted into a composite score:

| Metric | How | Weight | Why |
|--------|-----|--------|-----|
| **Sharpness** | Laplacian variance on grayscale via Accelerate/vImage | ~0.4 | Rejects motion blur, out-of-focus. Critical for Vertex AI object detection — blurry images degrade material/surface classification accuracy |
| **Feature density** | Harris/Shi-Tomasi corner count via Accelerate on grayscale buffer, thresholded by response magnitude | ~0.3 | Frames with more visual features are more useful for ORB matching and provide richer training signal for component detection |
| **Coverage value** | How much *new or under-covered* mesh surface area this frame's frustum sees (see 1C below) | ~0.3 | Prioritizes frames that fill spatial gaps — ensures all surfaces (walls, floor, ceiling, objects) are represented in the training set |

Each dimension normalized to 0–1, composite = weighted sum. Thresholds are tunable constants — initial weights (0.4/0.3/0.3) should be calibrated against a baseline of 10+ Phase 1 scans before locking. Export raw per-dimension scores in early builds to gather calibration data.

**Important — pipeline ordering:** The scorer requires access to the raw `CVPixelBuffer` from the ARFrame, *before* JPEG conversion. Phase 1 immediately converts frames to JPEG in `FrameCaptureManager.processFrame()`. The pipeline must be reordered: (1) check movement thresholds, (2) if triggered, score the raw pixel buffer, (3) only convert to JPEG if the frame is accepted (below cap) or wins replacement (at cap). This avoids scoring already-compressed data and prevents scoring every frame at 30fps.

**Note on Vision framework:** `VNFeaturePrintObservation` is an embedding vector for image similarity, NOT a corner/feature detector. Do not use it for feature density. Use a Harris/Shi-Tomasi detector implemented via Accelerate on the grayscale buffer derived from the `CVPixelBuffer`.

### 1B: Replace-Weakest-at-Similar-Pose Logic

**File to modify:** `RoomScanAlpha/AR/FrameCaptureManager.swift`

Current logic: if translation > 0.15m OR rotation > 15° AND count < 60 → capture.

New logic:

1. **Capture triggers unchanged** — still fire on 0.15m / 15° thresholds (maintains spatial regularity for ORB feature matching overlap)
2. **Scoring runs only on threshold-passing candidates** — NOT on every 30fps ARKit frame. This reduces scoring frequency from ~30/s to ~1-2/s, keeping the performance budget manageable. Benchmark on iPhone 12 Pro (oldest LiDAR device, 3GB RAM) to verify no frame drops.
3. **Below cap (< 60):** Accept frame, score it, store it. Same as today but with score attached.
4. **At cap (= 60) and a new candidate arrives:**
   - Find the existing frame with the **most similar pose** (smallest translation + rotation delta) to the candidate
   - Compare composite scores. **Replacement requires candidate score > existing + hysteresis margin (0.05)** to prevent oscillation (A replaces B, then C replaces A in a loop). Without hysteresis, the frame set churns CPU without converging.
   - **Guard:** never replace a frame if it's the **sole coverage provider** for any mesh region (see 1C). If eviction would create a coverage gap, find the next-weakest similar-pose frame instead, or skip replacement entirely.
5. **Expose:** `replacementCount` published property so the HUD can show the user that quality is improving

**Why this doesn't break stitching or training:** The 0.15m/15° spatial triggers remain unchanged, so keyframes maintain the same spatial distribution pattern. Replacement only swaps a frame at pose P with a better frame at ~pose P — the pose coverage is preserved. ARKit's mesh reconstruction runs on the full 30fps feed regardless of which frames are saved as keyframes, so the PLY mesh is unaffected. For Vertex AI training, each keyframe is processed independently with its camera pose — there's no sequential stitching dependency.

### 1C: Coverage Gap Detection

**New file:** `RoomScanAlpha/AR/CoverageTracker.swift`

Ensures the 60 frames collectively see the entire room — no blind spots where surfaces exist but no keyframe covers them.

- Divide the AR world-space XZ bounding box into a coarse **grid** (e.g., 0.5m × 0.5m cells for BEV room boundary; consider 0.25m cells if training data needs finer object coverage for sockets/baseboards)
- **Grid cell type:** `struct GridCell: Hashable { let x: Int; let z: Int }` — defined in `CoverageTracker.swift`, used by `CapturedFrame.coverageCells`
- For each cell, track: (a) whether mesh vertices exist there (from `ARMeshAnchor` updates), and (b) which keyframes have that cell in their camera frustum
- A cell is **covered** if it has mesh vertices AND at least one keyframe sees it
- A cell is a **gap** if it has mesh vertices but zero keyframe coverage

**Live mesh anchor access during capture:** `ARSessionManager.lastMeshAnchors` is only populated at pause — it cannot be used during active scanning. Instead, `CoverageTracker` must read mesh anchors from the live `ARFrame.anchors` (filtering for `ARMeshAnchor` instances) on each candidate evaluation. This is the same data, just accessed from the current frame rather than the snapshot.

**Integration with capture logic:**
- When evaluating a candidate frame, its coverage value (the 0.3-weight component) = number of gap cells it would cover. A frame that fills a gap scores much higher.
- When considering eviction, a frame that is the **sole provider** for any cell cannot be evicted (coverage-protected).
- During scanning, if gaps exist and no new candidate has arrived recently, **lower the capture thresholds temporarily** (e.g., 0.10m / 10°) to encourage capturing frames in under-covered areas. Reset thresholds once gaps are filled.

### 1D: User Feedback During Scan

**File to modify:** `RoomScanAlpha/Views/ScanningView.swift`

- **Blur warning banner:** "Slow down — images are blurry" when the last 3+ candidates scored below the sharpness threshold (even if not captured). Auto-dismisses when motion stabilizes.
- **Coverage indicator:** Small minimap or progress bar showing % of mesh-occupied cells that have keyframe coverage. Turns green at 100%.
- **Frame quality HUD line:** "47/60 frames (8 upgraded)" — shows the system is actively improving quality.

### 1E: Data Model Changes

**File to modify:** `RoomScanAlpha/Models/CapturedFrame.swift`

Add to `CapturedFrame`:
```swift
var qualityScore: Float          // composite 0–1
var sharpnessScore: Float        // Laplacian variance normalized
var featureDensityScore: Float   // corner count normalized
var coverageCells: Set<GridCell>  // which grid cells this frame covers
var replacementCount: Int        // how many times this frame slot has been replaced (0 = original capture)
```

`replacementCount` is tracked per-slot in `FrameCaptureManager` and injected into the frame at export time — it is NOT a property of the `CapturedFrame` itself (since a replaced frame is a new frame). Track it as a parallel array `slotReplacementCounts: [Int]` in `FrameCaptureManager`, incrementing the slot index on each replacement.

These scores are also written into the per-frame JSON in the scan package — useful for cloud-side quality analysis of training data and for filtering low-quality frames during Vertex AI training set curation.

### Test Cases — Step 1

#### Automated Tests

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S1.1 | Sharpness score on synthetic sharp image | Score a crisp checkerboard pattern | Score > 0.8 | Laplacian variance above high threshold |
| S1.2 | Sharpness score on synthetic blurred image | Score a Gaussian-blurred checkerboard | Score < 0.3 | Laplacian variance below low threshold |
| S1.3 | Feature density on textured vs. blank image | Score a textured wall photo vs. a solid white image | Textured > 0.5, blank < 0.1 | Harris corner count difference is > 5× |
| S1.4 | Coverage grid cell assignment | Place 4 keyframes at known poses in a 4×4m room | Each frame covers its quadrant cells | Union of all frame coverage cells = all occupied grid cells |
| S1.5 | Sole-provider eviction guard | 1 frame is the only coverage for grid cells (2,3) and (2,4) | Eviction blocked | Frame is not replaced even if candidate scores higher |
| S1.6 | Replacement with hysteresis | Candidate scores 0.03 above existing (below 0.05 margin) | No replacement | Existing frame retained |
| S1.7 | Replacement above hysteresis | Candidate scores 0.06 above existing | Replacement occurs | Slot now contains candidate frame; `replacementCount` incremented |
| S1.8 | Similar-pose matching | Candidate at (1.0, 0, 0.5), existing frames at (1.02, 0, 0.48) and (3.0, 0, 2.0) | Nearest pose is (1.02, 0, 0.48) | Translation + rotation delta is minimized |
| S1.9 | Coverage gap threshold lowering | 5 gap cells exist, no new candidate in 3s | Capture thresholds drop to 0.10m / 10° | Threshold values updated; reset once gaps = 0 |
| S1.10 | Composite score normalization | Raw sharpness=1200, feature_count=85, gap_cells=3 | Each dimension 0–1, composite is weighted sum | composite = 0.4×sharpness_norm + 0.3×feature_norm + 0.3×coverage_norm |

#### Manual / Device Tests

| ID | Test | Procedure | Pass Criteria |
|----|------|-----------|---------------|
| S1.M1 | Blur warning appears on jerky movement | Shake device rapidly while scanning | "Slow down" banner appears within 2s | Banner auto-dismisses when device stabilized |
| S1.M2 | Coverage indicator reaches 100% | Scan a full room slowly, covering all walls + floor | Coverage bar turns green, shows 100% | No mesh-occupied cells remain uncovered |
| S1.M3 | Frame upgrade count visible in HUD | Scan a room, then re-walk slowly with better lighting | HUD shows "(N upgraded)" with N > 0 | Replacement count increments when better frames replace weaker ones |
| S1.M4 | No frame drops on iPhone 12 Pro | Scan with scoring enabled, monitor frame rate | 30fps maintained | No visible stuttering; ARKit delegate callback timing < 33ms |
| S1.M5 | Quality scores in exported JSON | Complete a scan, inspect per-frame JSON in scan package | Each frame has quality_score, sharpness_score, feature_density_score | Values are 0–1, non-zero for accepted frames |

### Files Summary — Step 1

| Action | File |
|--------|------|
| **New** | `RoomScanAlpha/AR/FrameQualityScorer.swift` |
| **New** | `RoomScanAlpha/AR/CoverageTracker.swift` |
| **Modify** | `RoomScanAlpha/AR/FrameCaptureManager.swift` — add scoring, replacement, coverage-aware eviction |
| **Modify** | `RoomScanAlpha/Models/CapturedFrame.swift` — add quality score fields |
| **Modify** | `RoomScanAlpha/Views/ScanningView.swift` — blur warning, coverage indicator, upgraded-frame count |
| **Modify** | `RoomScanAlpha/Export/ScanPackager.swift` — write quality scores to per-frame JSON |

---

## Step 2: Start / Stop / Redo Scan Controls

**Current flow:** Scanning starts automatically when entering `.scanning` state, stop button transitions to `.labelingRoom`.

### State Machine Update

**File to modify:** `RoomScanAlpha/Models/ScanState.swift`

Add `scanReady` and `scanReview` states:

```
idle → selectingRFQ → scanReady → scanning → annotatingCorners → labelingRoom → exporting → uploading → viewingResults
                         ↑            │                                                                          │
                         └── redo ────┘                                                                          │
                         ↑                                                                                       │
                         └──────────────────────── "Scan Another Room" ─────────────────────────────────────────┘
```

**Key change from earlier drafts:** Annotation happens **during** the active scan, immediately after the user taps "Stop" on the capture HUD. The AR session stays fully running — keyframe quality scoring and mesh reconstruction continue to improve data while the user traces corners. Room labeling moves to **after** annotation since the user is still interacting with the AR scene during tracing.

**Why `scanReview` was removed:** The redo/continue decision is now part of the annotation step. After the user taps "Stop," they enter annotation mode where they can either trace corners or skip. A "Redo Scan" option is available within the annotation view (clears frames + restarts scan). There's no need for a separate review state.

**"Scan Another Room" path:** Phase 1's `viewingResults` has a "Scan Another Room" action that goes directly to `.scanning`. With Phase 2, this path must route to `scanReady` instead, so the user gets the AR preview + "Start Scan" flow for the new room.

### UI Changes

**File to modify:** `RoomScanAlpha/Views/ScanningView.swift`

- **Pre-scan (`scanReady`):** AR preview visible in background. "Start Scan" button (large, centered). User can see the room in AR before committing.
- **During scan (`scanning`):** "Stop Scan" button replaces current stop button. Frame/triangle HUD + new quality indicators from Step 1.
- Tapping "Stop Scan" transitions to `annotatingCorners` (Step 4). The scan is NOT ended — AR session continues running.

### Logic Changes

**File to modify:** `RoomScanAlpha/ViewModels/ScanViewModel.swift`

- `startScan()` — transitions from `scanReady` → `scanning`, begins AR capture
- `stopScan()` — hides capture HUD, transitions to `annotatingCorners`. **Does NOT pause or end the AR session.** Keyframe scoring and mesh reconstruction continue.
- `redoScan()` — clears captured frames, resets mesh stats, resets AR session, **clears any stored `RFQContext`** (world origin is invalidated by session reset), returns to `scanReady`

**File to modify:** `RoomScanAlpha/AR/ARSessionManager.swift`

- Add `resetSession()` for redo — calls `ARSession.run(_:options: [.resetTracking, .removeExistingAnchors])`. **Note:** this resets the world origin, which invalidates any previously stored `RFQContext` origin transform. `ScanViewModel.redoScan()` must clear `rfqContext`.
- **No session pause on stop** — the session stays fully running during annotation. It is only terminated after annotation + room labeling are complete and the app transitions to `exporting`.

**File to modify:** `RoomScanAlpha/AR/FrameCaptureManager.swift`

- Add `reset()` — clears captured frames array, resets counters, resets coverage tracker

**File to modify:** `RoomScanAlpha/ContentView.swift`

- Wire `scanReady` state into the view router
- Update "Scan Another Room" action to route to `scanReady` (not directly to `.scanning`)

### Test Cases — Step 2

#### Automated Tests

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S2.1 | State transitions: idle → scanReady | Set state to selectingRFQ, select an RFQ | State becomes `scanReady` | `ScanViewModel.state == .scanReady` |
| S2.2 | State transitions: scanReady → scanning | Call `startScan()` | State becomes `scanning` | AR session is running; keyframe capture begins |
| S2.3 | State transitions: scanning → annotatingCorners | Call `stopScan()` | State becomes `annotatingCorners` | AR session still running (not paused) |
| S2.4 | Redo clears all state | Call `redoScan()` from annotatingCorners | State becomes `scanReady` | `keyframeCount == 0`, `meshTriangleCount == 0`, `rfqContext == nil` |
| S2.5 | FrameCaptureManager.reset() clears frames | Add 30 frames, call `reset()` | Frame array is empty | `capturedFrames.count == 0`, `replacementCount == 0` |
| S2.6 | "Scan Another Room" routes to scanReady | Trigger "Scan Another Room" from viewingResults | State becomes `scanReady` | NOT `.scanning` directly |

#### Manual / Device Tests

| ID | Test | Procedure | Pass Criteria |
|----|------|-----------|---------------|
| S2.M1 | Start scan button visible | Navigate to scanReady state | "Start Scan" button centered on screen, AR preview behind | Tapping starts capture; HUD appears |
| S2.M2 | Stop scan transitions to annotation | Tap "Stop Scan" during active capture | Annotation UI appears (crosshair, trace controls) | AR camera feed still live; mesh still visible |
| S2.M3 | Redo scan resets everything | Start a scan, capture 20+ frames, stop, tap "Redo Scan" | Back to scanReady; frame count reset to 0 | AR preview is clean (no old mesh anchors) |
| S2.M4 | Mesh continues refining during annotation | Stop scan, walk slowly during annotation | Triangle count in HUD continues increasing | New mesh anchors appear; existing anchors refine |

### Files Summary — Step 2

| Action | File |
|--------|------|
| **Modify** | `RoomScanAlpha/Models/ScanState.swift` — add `scanReady` state; remove `scanReview` if it was added |
| **Modify** | `RoomScanAlpha/ViewModels/ScanViewModel.swift` — `startScan()`, `stopScan()` → `.annotatingCorners` (session stays live), `redoScan()` clears RFQ context |
| **Modify** | `RoomScanAlpha/AR/ARSessionManager.swift` — `resetSession()`; no pause on stop |
| **Modify** | `RoomScanAlpha/AR/FrameCaptureManager.swift` — `reset()` |
| **Modify** | `RoomScanAlpha/Views/ScanningView.swift` — start/stop UI |
| **Modify** | `RoomScanAlpha/ContentView.swift` — route `scanReady` state |

---

## Step 3: Delete Scans in Scan History

Since this is an internal tool for training data capture, scan deletion is acceptable.

### iOS Changes

**File to modify:** `RoomScanAlpha/Views/ScanHistoryView.swift`

- Add swipe-to-delete on scan rows
- Confirmation alert: "Delete scan? This cannot be undone." For scans with `training_status == 'annotated'`, use stronger warning: "This scan has annotations. Delete anyway?"
- **Delete flow:** Call backend DELETE first, wait for 200 response, THEN delete local record. Show spinner during API call. If API call fails (offline, server error), show error and do NOT delete locally — this prevents desync where the local record is gone but the backend still has it.

**File to modify:** `RoomScanAlpha/Cloud/RFQService.swift`

- Add `deleteScan(rfqId: String, scanId: String) async throws` — calls new backend endpoint

**File to modify:** `RoomScanAlpha/Models/ScanRecord.swift` (note: `ScanHistoryStore` is a class embedded in this file, not a separate file)

- Add `deleteRecord(scanId:)` to `ScanHistoryStore` — removes entry from UserDefaults-backed local store

### Backend Changes

**File to modify:** `cloud/api/main.py`

- Add `DELETE /api/rfqs/{rfqId}/scans/{scanId}` endpoint
- Soft-delete: `UPDATE scanned_rooms SET scan_status = 'deleted' WHERE id = ?` rather than hard DELETE — preserves training data lineage for scans already routed to `training/` paths (Step 6). The status endpoint should treat `'deleted'` as 404.
- Does NOT delete GCS blob — storage is cheap and the scan data may still be valuable for training even if the user no longer wants to see it in the app
- **GCS lifecycle policy:** Add a lifecycle rule on the `scans/` prefix to transition blobs to Coldline storage after 90 days. The `training/` prefix is excluded from lifecycle rules.

### Test Cases — Step 3

#### Automated Tests

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S3.1 | ScanHistoryStore.deleteRecord removes entry | Add 3 records, delete middle one | 2 records remain | Deleted scan ID not in store; other records intact |
| S3.2 | DELETE endpoint soft-deletes | Call `DELETE /api/rfqs/{rfqId}/scans/{scanId}` | 200 response | `scanned_rooms.scan_status = 'deleted'`; row still exists |
| S3.3 | Deleted scan returns 404 on status | Soft-delete a scan, then call GET status | 404 response | Response body indicates scan not found |
| S3.4 | Training data preserved after delete | Soft-delete a scan that has `training/{scan_id}/` in GCS | GCS training files untouched | `ground_truth.json` and `mesh.ply` still exist in `training/` path |
| S3.5 | Delete fails gracefully offline | Call deleteScan with no network | Error thrown | Local record NOT deleted; error message shown |

#### Manual / Device Tests

| ID | Test | Procedure | Pass Criteria |
|----|------|-----------|---------------|
| S3.M1 | Swipe-to-delete appears | Swipe left on a scan row in history | Delete button visible | Red "Delete" button appears |
| S3.M2 | Confirmation dialog for annotated scan | Swipe-delete on a scan with training_status='annotated' | Warning dialog appears | Text mentions "This scan has annotations" |
| S3.M3 | Successful delete removes row | Confirm delete on a scan | Row disappears from list | Spinner shown during API call; row animates out on success |
| S3.M4 | Failed delete shows error | Turn on airplane mode, attempt delete | Error alert shown | Row remains in list; local data preserved |

### Files Summary — Step 3

| Action | File |
|--------|------|
| **Modify** | `RoomScanAlpha/Views/ScanHistoryView.swift` — swipe-to-delete + confirmation |
| **Modify** | `RoomScanAlpha/Cloud/RFQService.swift` — `deleteScan()` API call |
| **Modify** | `cloud/api/main.py` — `DELETE` endpoint |

---

## Step 4: AR Corner Annotation with Multi-Trace + Edge Types

This is Path A from the BEV DNN Implementation Plan — the highest-quality annotation method for training RoomFormer on real room scans. Since this is pre-production tooling for training data collection, accuracy is prioritized over workflow speed.

### Key Design Decision: Live Session During Annotation

The AR session stays **fully running** during annotation — NOT paused. This means:
- **Mesh reconstruction continues** — the mesh keeps refining while the user walks the room tracing corners. By the time annotation is complete, the mesh has had more time to fill gaps and refine surfaces.
- **Keyframe quality scoring continues** — `FrameCaptureManager` keeps evaluating and replacing keyframes in the background. The user walking slowly during annotation often produces excellent replacement candidates.
- **Raycasts hit a live, improving mesh** — corners placed later in annotation may hit a more refined mesh than corners placed earlier, which improves accuracy.
- The scan only truly ends when the user finishes all traces, labels the room, and proceeds to export.

### Multi-Trace Model

Instead of a single polygon, the annotation captures **one or more traces**, each tagged with a type:

- **`ceiling`** (default, mandatory for BEV DNN) — trace the room boundary at ceiling level. This is the primary annotation for RoomFormer training.
- **`floor`** (optional) — trace the room boundary at floor level when it differs from the ceiling (bay windows, step-downs, soffits, knee walls). Prompted via "Add Another Trace" after completing the ceiling trace.

Most rooms have identical ceiling and floor polygons — the floor trace is only needed when the user can see they differ. Ceiling is always first because it's the BEV DNN's training target.

### Edge Types

After closing a polygon trace, the user can tap any edge to cycle its type. Edge types encode what exists at each boundary:

| Edge Type | Ceiling present? | Wall below? | BEV density map | Affects wall area | Affects trim quantities |
|-----------|-----------------|-------------|-----------------|-------------------|------------------------|
| `ceiling` | Yes | Yes, full height | Bright line (wall+ceiling vertices) | No (correct as-is) | No |
| `door` | Yes (header above) | Partial (door frame) | Bright line | Yes — subtract opening area | Yes — subtract opening width from baseboard |
| `open_cased` | Yes (header above) | Partial (cased frame, no door) | Bright line | Yes — subtract opening area | Yes — subtract opening width from baseboard |
| `open_pass` | No or partial | No wall | Dim/absent in density map | Yes — subtract full edge × height | Yes — subtract full edge from perimeter |

Default edge type is `ceiling` (most edges are walls). For the `floor` trace type, the edge types are `floor`, `door`, `open_cased`, `open_pass` — same semantics but applied at floor level.

**Downstream value of edge types:**
- **Wall area correction:** subtract opening edges × height from total wall area
- **Baseboard/trim correction:** subtract opening edges from perimeter for trim quantities
- **Floor plan rendering (Stage 7):** draw opening edges as gaps in wall lines; `door` edges get swing arcs, `open_cased` edges get cased-opening symbols, `open_pass` edges are just gaps
- **Multi-room stitching:** an `open_pass` edge on room A should spatially align with an `open_pass` or `open_cased` edge on room B — this defines how rooms connect

### Interaction Model: Crosshair Aiming

The annotation uses a **center-screen crosshair** rather than direct tap-on-corner. The user physically aims the device at each corner like a surveying instrument, then taps anywhere on screen (or a "Lock Corner" button) to confirm.

**Why crosshair over direct tap:**
- Direct tap: fingertip covers ~44pt (~7mm of glass). At 1.5-2.5m phone-to-ceiling distance, the target corner is occluded by the finger during the tap. The raycast fires from the touch point, which is offset from the actual corner by however much the finger missed — several centimeters of positional error on the polygon.
- Crosshair: the target point is always visible (the crosshair IS the point). The raycast fires from the exact center pixel every time. No finger-occlusion offset. The confirmation tap can be anywhere — it just means "lock what the crosshair is on."

**Zoom loupe:** A magnified inset near the crosshair (similar to iOS text cursor positioning) shows a zoomed view of the area around the aim point. This helps the user see exactly where the wall-ceiling intersection is when the ceiling is far away.

### Corner-to-Surface Snap

The LiDAR mesh at wall-ceiling intersections is often noisy — fewer returns hit that crease precisely, so the raycast may land slightly on the wall face or ceiling face rather than the exact intersection point.

**Plane-intersection snapping:** When the raycast hit point is within ~5cm of where two classified surfaces meet (wall + ceiling, or wall + wall), compute the geometric intersection of those two planes and snap the corner to that intersection point rather than using the raw mesh hit. This gives plane-intersection precision rather than mesh-vertex precision.

Implementation: use the face classification labels from `ARMeshAnchor`. For each raycast hit, check nearby faces' classifications. If two different surface types are nearby (e.g., `ARMeshClassification.wall` and `.ceiling`), fit planes to each surface's local vertices using RANSAC (robust against noisy LiDAR data at ceiling distance) and compute their intersection line. Project the hit point onto that line.

### New UI: Corner Annotation Screen

**New file:** `RoomScanAlpha/Views/CornerAnnotationView.swift`

A SwiftUI view wrapping `ARSCNView` that appears after the user taps "Stop Scan." The AR session remains fully running.

**Prompt banner at top:** "Trace the corners of the ceiling going around the room. Aim the crosshair at each corner and tap to lock it in." Text changes dynamically based on the selected trace type.

**Core annotation controls:**
- **Center-screen crosshair** — fixed reticle that the user aims at each corner
- **Zoom loupe** — magnified inset near the crosshair showing the aim area in detail
- **"Lock Corner" button** (bottom of screen) — fires raycast from screen center, applies plane-intersection snap, places corner. Alternatively, tap anywhere on screen to lock.
- Each locked corner places a visible sphere node at the snapped hit point with a numbered label (1, 2, 3…)
- **Auto-connect lines:** each new corner automatically draws a line from the previous corner. User naturally walks the room perimeter (clockwise or counter-clockwise).
- When ≥ 3 corners placed, polygon fills with semi-transparent overlay so user can verify the room outline

**Trace type selector:** Segmented control at bottom of screen: `[Ceiling] | Floor`. Defaults to Ceiling. Changing the selector updates the prompt text and tags the current trace with the selected type. The selector is disabled while a trace is in progress (must close or discard the current trace first).

**Closing a trace:** When the user taps "Close Trace" (enabled at ≥ 3 corners), auto-draw the closing edge from last corner back to corner 1. Show the computed area: "Close trace? (X.X m²)". After closing:
- **Edge type annotation:** Each edge in the closed polygon is initially `ceiling` (or `floor` for floor traces). The user can tap any edge to cycle through: `ceiling` → `door` → `open_cased` → `open_pass` → `ceiling`. The edge visually changes: solid line for `ceiling`/`floor`, dashed for `door`, dotted for `open_cased`, gap for `open_pass`.
- **"Add Another Trace" button** — appears after the first trace is closed. Allows switching to Floor trace type and tracing a second polygon.

**Editing controls:**
- **"Undo Last"** button — removes most recent corner and its connecting line (only during active trace, before closing)
- **Corner adjustment:** Two methods for re-aiming an existing corner: (a) long-press the corner sphere node in the AR view, or (b) tap the corner number in a **2D corner list** below the AR view to select it, then tap "Re-lock" to update it to the current crosshair position. The 2D list is more ergonomic when holding the phone toward the ceiling.
- **"Redo Scan"** button — clears all traces AND captured frames, resets AR session, returns to `scanReady`

**Completion:**
- **"Done"** button — enabled when at least one trace is closed with ≥ 3 corners, validates all traces (no self-intersection, reasonable area), transitions to `labelingRoom`
- **"Skip"** button — skips annotation entirely, proceeds to `labelingRoom` without corner data

### Accuracy Feedback

During annotation, display per-corner confidence:
- If plane-intersection snap succeeded: show green indicator + "Snapped" label on the corner node
- If snap failed (no classified surface intersection nearby): show yellow indicator + "Unsnapped" — the raw mesh hit was used. User may want to undo and re-aim more precisely.
- Display running polygon area (m²) after each corner so the user can sanity-check as they go
- Display background scan stats: "60 frames (12 upgraded) · 48.2k triangles" — shows the scan is still improving

### Data Model

**New file:** `RoomScanAlpha/Models/CornerAnnotation.swift`

```swift
/// A single polygon trace (ceiling or floor boundary)
struct TraceAnnotation: Codable {
    let traceType: String            // "ceiling" or "floor"
    let corners_xz: [[Float]]       // [[x, z], ...] in meters, AR world space, always CCW winding
    let corners_y: [Float]           // per-corner Y height for validation
    let edge_types: [String]         // per-edge: "ceiling", "door", "open_cased", "open_pass" (or "floor" variants)
    let snap_status: [Bool]          // per-corner: true if plane-intersection snap succeeded
    let snap_distance: [Float]       // per-corner: distance (m) from raw hit to snapped point (0.0 if unsnapped)
}

/// Complete annotation for a scan, containing one or more traces
struct CornerAnnotation: Codable {
    let traces: [TraceAnnotation]
    let annotation_method: String    // "ar_crosshair_snap"
    let annotator_uid: String        // persistent device UUID (NOT Firebase anonymous UID)
    let timestamp: String            // ISO 8601
}
```

**Annotator UID:** Firebase anonymous UIDs change on app reinstall, which breaks training data lineage. Instead, generate a persistent `UUID().uuidString` on first launch, store it in UserDefaults under `annotator_device_id`, and use that here.

**New file:** `RoomScanAlpha/ViewModels/CornerAnnotationViewModel.swift`

- Manages multiple traces, each with its own corner array
- Active trace state: corners as `[(x: Float, y: Float, z: Float, snapped: Bool, snapDistance: Float)]`
- Performs plane-intersection snap logic using nearby mesh face classifications with RANSAC
- Validates each trace: no self-intersection (O(N²) segment check), area between 1m² and 500m², collinear corner handling
- **Winding order normalization** — always export CCW winding (RoomFormer convention). Detect via shoelace formula sign, reverse if CW.
- Edge type management: default all edges to trace type (`ceiling` or `floor`), allow cycling per-edge
- Computes running polygon area for display
- Provides `cornerAnnotation: CornerAnnotation` for export

### State Machine Integration

**File to modify:** `RoomScanAlpha/Models/ScanState.swift`

- Add `annotatingCorners` state. This now sits between `scanning` and `labelingRoom`:

```
scanning → annotatingCorners → labelingRoom → exporting → uploading → viewingResults
               ↑        │
               └ redo ──→ scanReady
```

**File to modify:** `RoomScanAlpha/ContentView.swift`

- Route `annotatingCorners` → `CornerAnnotationView`
- `stopScan()` now transitions to `annotatingCorners` (not `scanReview` or `labelingRoom`)

**File to modify:** `RoomScanAlpha/ViewModels/ScanViewModel.swift`

- `stopScan()` transitions to `.annotatingCorners`
- Store `cornerAnnotation: CornerAnnotation?`
- Wire skip/done/redo actions from annotation view

**File to modify:** `RoomScanAlpha/AR/ARSessionManager.swift`

- **Session stays running during annotation.** No pause, no reconfiguration. The user is still in the AR environment, and the session continues mesh reconstruction + camera feed.
- Session is only terminated when transitioning from `labelingRoom` → `exporting`.

### Test Cases — Step 4

#### Automated Tests (Pure Geometry — No ARKit Dependency)

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S4.1 | Polygon self-intersection detection | Square polygon with corners reordered to create a bowtie | Validation rejects | `validatePolygon()` returns false |
| S4.2 | Valid polygon accepted | 4-corner rectangle, CCW winding | Validation passes | `validatePolygon()` returns true, area > 1m² |
| S4.3 | CW winding auto-corrected to CCW | 4-corner rectangle in CW order | Exported as CCW | Shoelace area is positive after normalization |
| S4.4 | Collinear corners handled | 3 corners on a straight line + 1 offset | Valid polygon (triangle) | No crash; area > 0 |
| S4.5 | Area bounds enforced | Polygon with area = 0.5m² | Validation rejects | Below 1m² minimum |
| S4.6 | Edge type defaults correct | Close a 4-edge ceiling trace | All edges default to "ceiling" | `edge_types == ["ceiling", "ceiling", "ceiling", "ceiling"]` |
| S4.7 | Edge type cycling | Cycle edge 2 from "ceiling" | Cycles: ceiling → door → open_cased → open_pass → ceiling | State updates correctly each cycle |
| S4.8 | Multiple traces stored | Add ceiling trace (4 corners), then floor trace (5 corners) | `traces.count == 2` | First trace has 4 corners, second has 5 |
| S4.9 | Undo removes last corner | Add 5 corners, undo | 4 corners remain | Corner 5 and edge 4→5 removed |
| S4.10 | Corner re-lock updates position | Lock corner 3 at (1.0, 2.4, 0.5), re-lock at (1.1, 2.4, 0.6) | Corner 3 updated | `corners_xz[2] == [1.1, 0.6]`; edges redrawn |
| S4.11 | Snap distance computed | Raw hit at (1.0, 2.4, 0.5), snapped to (1.02, 2.44, 0.48) | `snap_distance = 0.05` (approx) | Euclidean distance between raw and snapped |
| S4.12 | Persistent annotator UID | First launch generates UUID, second launch reuses | Same UUID across launches | UserDefaults key `annotator_device_id` is stable |
| S4.13 | Floor trace has floor edge defaults | Close a floor trace | All edges default to "floor" | `edge_types == ["floor", "floor", ...]` |
| S4.14 | open_pass edge at room connection | Mark edge between corners 3→4 as open_pass | edge_types[2] == "open_pass" | Perimeter calculation excludes this edge for trim; wall area excludes this edge × height |

#### Manual / Device Tests

| ID | Test | Procedure | Pass Criteria |
|----|------|-----------|---------------|
| S4.M1 | Crosshair + Lock Corner workflow | Aim at a ceiling corner, tap Lock Corner | Sphere appears at corner; numbered label visible | Corner position matches visual aim point |
| S4.M2 | Zoom loupe shows detail | Aim at a ceiling corner from 2m away | Loupe inset shows magnified view of crosshair area | Corner details (wall-ceiling crease) visible in loupe |
| S4.M3 | Plane-intersection snap | Aim at a wall-ceiling junction, lock | Green "Snapped" indicator on corner | Corner sits precisely at the crease, not offset onto wall or ceiling face |
| S4.M4 | Unsnapped corner shows yellow | Aim at a featureless area (middle of wall), lock | Yellow "Unsnapped" indicator | Raw mesh hit used; no crash |
| S4.M5 | Auto-connect lines visible | Lock 4 corners around a room | Lines drawn between consecutive corners | Polygon outline visible in AR overlaid on room |
| S4.M6 | Edge type cycling on closed polygon | Close a 4-corner trace, tap edge 2 | Edge 2 changes: solid → dashed (door) → dotted (open_cased) → gap (open_pass) | Visual feedback matches edge type |
| S4.M7 | Trace prompt changes with selector | Switch from Ceiling to Floor | Prompt changes to "Trace the corners of the floor..." | Trace type selector updates |
| S4.M8 | Add second trace after first | Complete ceiling trace, tap "Add Another Trace", select Floor | Second trace starts; ceiling trace remains visible (dimmed) | Both traces visible; only active trace is editable |
| S4.M9 | Redo from annotation | Tap "Redo Scan" during annotation | Returns to scanReady; all data cleared | Frame count 0; no traces; AR session reset |
| S4.M10 | Skip bypasses annotation | Tap "Skip" immediately | Proceeds to labelingRoom | `cornerAnnotation == nil` in export |
| S4.M11 | Mesh continues improving during annotation | Watch triangle count while tracing corners | Count increases | Mesh visually fills gaps as user walks the room |
| S4.M12 | Keyframes upgrade during annotation | Watch frame upgrade count while tracing corners | "(N upgraded)" count increases | Replacement scoring still active |
| S4.M13 | Room with cased opening | Scan a room with a cased opening (framed, no door), trace ceiling, mark that edge as open_cased | Edge renders as dotted line | Edge type correctly stored in trace |
| S4.M14 | Room with wide open pass-through | Scan a room with a 5ft+ opening to adjacent room, trace ceiling, mark edge as open_pass | Edge renders as gap | Edge is excluded from perimeter/wall calculations |
| S4.M15 | Corner at open_pass boundary | Aim at the corner where a wall ends and open_pass begins | Snap should work (wall-ceiling intersection exists at the edge of the opening) | Corner placed precisely at the wall termination point |

### Files Summary — Step 4

| Action | File |
|--------|------|
| **New** | `RoomScanAlpha/Views/CornerAnnotationView.swift` — crosshair UI, zoom loupe, auto-connect lines, trace type selector, edge type cycling, snap indicators |
| **New** | `RoomScanAlpha/ViewModels/CornerAnnotationViewModel.swift` — multi-trace management, plane-intersection snap with RANSAC, polygon validation, winding normalization, edge type state |
| **New** | `RoomScanAlpha/Models/CornerAnnotation.swift` — `TraceAnnotation` + `CornerAnnotation` Codable models |
| **Modify** | `RoomScanAlpha/Models/ScanState.swift` — add `annotatingCorners` |
| **Modify** | `RoomScanAlpha/ContentView.swift` — route `annotatingCorners`; `stopScan()` → annotation |
| **Modify** | `RoomScanAlpha/ViewModels/ScanViewModel.swift` — `stopScan()` → `.annotatingCorners`; store annotation; wire redo/skip/done |
| **Modify** | `RoomScanAlpha/AR/ARSessionManager.swift` — session stays running during annotation; terminate only at export |

---

## Step 5: Update metadata.json with Traces + Quality Scores

**File to modify:** `RoomScanAlpha/Export/ScanPackager.swift`

Extend `ScanMetadata` to include optional `corner_annotations` block. The format now uses the multi-trace model:

```json
{
    "rfq_id": "...",
    "room_label": "Kitchen",
    "keyframe_count": 47,
    "...existing fields...",

    "corner_annotations": {
        "traces": [
            {
                "trace_type": "ceiling",
                "corners_xz": [[-2.5, -1.8], [2.5, -1.8], [2.5, 3.0], [-2.5, 3.0]],
                "corners_y": [2.44, 2.43, 2.45, 2.44],
                "edge_types": ["ceiling", "ceiling", "door", "open_pass"],
                "snap_status": [true, true, false, true],
                "snap_distance": [0.02, 0.01, 0.0, 0.03]
            },
            {
                "trace_type": "floor",
                "corners_xz": [[-2.5, -1.8], [3.0, -1.8], [3.0, 3.0], [-2.5, 3.0]],
                "corners_y": [0.01, 0.0, 0.02, 0.0],
                "edge_types": ["floor", "floor", "door", "open_pass"],
                "snap_status": [true, true, true, true],
                "snap_distance": [0.01, 0.0, 0.01, 0.0]
            }
        ],
        "annotation_method": "ar_crosshair_snap",
        "annotator_uid": "persistent-device-uuid",
        "timestamp": "2026-03-28T10:00:00Z"
    },

    "keyframes": [
        {
            "index": 0,
            "filename": "frame_000.jpg",
            "depth_filename": "frame_000.depth",
            "timestamp": 1234567890.123,
            "quality_score": 0.87,
            "sharpness_score": 0.92,
            "feature_density_score": 0.78,
            "replacement_count": 2
        }
    ]
}
```

`corner_annotations` is omitted entirely when the user skips annotation (not included as null — absent key). `replacement_count` per frame is tracked by `FrameCaptureManager.slotReplacementCounts` and injected at export time (see Step 1E).

Per-frame quality scores enable cloud-side filtering: the Vertex AI training pipeline (Stage 4b DNN) can exclude frames below a quality threshold, and the BEV pipeline uses the ceiling trace from `corner_annotations` to build `ground_truth.json`.

**Backward compatibility:** All new fields are additive and optional. The cloud processor's metadata validation must be updated to *accept* (not require) the new fields. **Deployment order matters:** deploy the cloud processor update (Steps 5, 6, 7 backend) BEFORE shipping the iOS update (Steps 1-4, 5 iOS, 7 iOS). If iOS ships first, new metadata fields could cause validation failures on the old processor.

### Test Cases — Step 5

#### Automated Tests

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S5.1 | Metadata includes traces when annotated | Package scan with ceiling trace (4 corners) + floor trace (5 corners) | `corner_annotations.traces` has 2 entries | Ceiling trace has 4 corners; floor trace has 5 |
| S5.2 | Metadata omits corner_annotations when skipped | Package scan without annotation | `corner_annotations` key absent from JSON | Not null, not empty — absent |
| S5.3 | Edge types serialized correctly | Package trace with mixed edge types | JSON array matches in-memory edge types | `["ceiling", "door", "open_pass", "ceiling"]` |
| S5.4 | Quality scores in per-frame JSON | Package scan with scored frames | Each keyframe entry has quality fields | `quality_score`, `sharpness_score`, `feature_density_score`, `replacement_count` present |
| S5.5 | Winding order is CCW in export | Package trace originally in CW order | Exported `corners_xz` is CCW | Shoelace formula on exported corners gives positive area |
| S5.6 | Backward-compatible with Phase 1 processor | Send Phase 2 metadata to Phase 1 processor (simulated) | No validation error | Processor ignores unknown fields |

### Files Summary — Step 5

| Action | File |
|--------|------|
| **Modify** | `RoomScanAlpha/Export/ScanPackager.swift` — add `corner_annotations` (multi-trace with edge types) + per-frame quality scores to metadata |

---

## Step 6: Cloud Processor — Route Annotations to Training Pipelines

Two downstream consumers of the enriched scan data:

### 6A: Schema Migration

**New file:** `cloud/migrations/002_add_training_status.sql`

Phase 1 schema has no `training_status` column. Add it before deploying the processor changes:

```sql
ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS training_status TEXT DEFAULT NULL;
-- Values: NULL (not processed for training), 'annotated', 'unannotated', 'deleted'
```

Deploy this migration before the processor update. Use `IF NOT EXISTS` for idempotency.

### 6B: BEV DNN Training Data (Room Polygons)

**File to modify:** `cloud/processor/main.py`

After PLY processing, check `metadata.json` for `corner_annotations`:
- If present: extract the **ceiling trace** (first trace with `trace_type == "ceiling"`) — this is the BEV ground truth
- Copy `mesh.ply` + write `ground_truth.json` to `gs://roomscanalpha-scans/training/{scan_id}/`
- `ground_truth.json` format:
  ```json
  {
      "corners_xz": [[-2.5, -1.8], [2.5, -1.8], [2.5, 3.0], [-2.5, 3.0]],
      "edge_types": ["ceiling", "ceiling", "door", "open_pass"],
      "collected_date": "2026-03-28",
      "batch_id": "2026-03"
  }
  ```
- Include `edge_types` in ground truth — the BEV DNN doesn't use them directly, but they're valuable metadata for future training experiments (e.g., training the model to predict which edges are openings)
- Verify that coordinate system (AR world-space meters) and winding order (CCW) are consistent with `BEV_DNN_IMPLEMENTATION_PLAN.md`
- Update DB: `UPDATE scanned_rooms SET training_status = 'annotated' WHERE id = ?`
- **Idempotency:** Use deterministic GCS paths (`training/{scan_id}/`). Re-processing overwrites the same files — no duplicates.

This feeds the existing `generate_training_data.py` → `RoomFormer_Finetune.ipynb` pipeline described in `BEV_DNN_IMPLEMENTATION_PLAN.md`.

### 6C: Vertex AI Training Data (Keyframe Images)

**File to modify:** `cloud/processor/main.py`

For every scan (regardless of corner annotation):
- Copy keyframe JPEGs + **per-frame JSONs (camera_transform + quality scores)** + depth files to `gs://roomscanalpha-scans/training_images/{scan_id}/`. The per-frame camera transforms are required by the Vertex AI pipeline to project detections into 3D world space.
- Quality scores in the per-frame JSON allow the training pipeline to filter: e.g., only use frames with `quality_score > 0.6`
- **Performance:** Copy to training paths asynchronously — AFTER the DB update and FCM notification, so the user isn't waiting for training data routing to see their results.

### 6D: API Response Extension

**File to modify:** `cloud/api/main.py`

- Include `training_status` in `GET /api/rfqs/{rfqId}/scans/{scanId}/status` response so the app knows annotation was received
- Return `NULL` / omit `training_status` for Phase 1 scans (no migration backfill needed — NULL means "pre-Phase 2")

### Test Cases — Step 6

#### Automated Tests

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S6.1 | Schema migration is idempotent | Run migration twice | No error on second run | `IF NOT EXISTS` prevents duplicate column |
| S6.2 | Ceiling trace extracted for BEV | Process scan with ceiling + floor traces | `ground_truth.json` contains ceiling `corners_xz` | Floor trace not in ground_truth.json |
| S6.3 | Edge types included in ground truth | Process scan with mixed edge types | `ground_truth.json` has `edge_types` array | Array length matches corner count |
| S6.4 | Training status set to 'annotated' | Process scan with corner_annotations | `scanned_rooms.training_status = 'annotated'` | DB value matches |
| S6.5 | Unannotated scan gets 'unannotated' status | Process scan without corner_annotations | `scanned_rooms.training_status = 'unannotated'` | Distinguishes from NULL (pre-Phase 2) |
| S6.6 | Keyframe images copied to training_images/ | Process any scan | JPEGs + per-frame JSONs in `training_images/{scan_id}/` | File count matches metadata keyframe_count |
| S6.7 | Quality scores preserved in training copy | Process scan with scored frames | Per-frame JSON in training_images/ has quality_score | Values match source metadata |
| S6.8 | Idempotent reprocessing | Process same scan twice | Same files in training/, no duplicates | File contents identical; no `_v2` suffixes |
| S6.9 | training_status in API response | GET status for annotated scan | Response includes `"training_status": "annotated"` | Field present and correct |
| S6.10 | Phase 1 scan returns null training_status | GET status for pre-Phase 2 scan | `training_status` is null or absent | No error; app hides training section |

### Files Summary — Step 6

| Action | File |
|--------|------|
| **New** | `cloud/migrations/002_add_training_status.sql` — schema migration |
| **Modify** | `cloud/processor/main.py` — extract ceiling trace → training GCS paths with edge types; copy keyframes; update DB |
| **Modify** | `cloud/api/main.py` — return `training_status` in status response |

---

## Step 7: Return BEV Density Map + Metrics to User

### Cloud Side

**File to modify:** `cloud/processor/main.py`

- **Always generate the BEV density map PNG** via `bev_projection.py` — regardless of the `USE_DNN_STAGE3` flag. Phase 1 only runs BEV projection when DNN is enabled; Phase 2 needs it for every scan to show the density map in results. Upload the PNG to `gs://roomscanalpha-scans/scans/{rfq_id}/{scan_id}/bev_density.png`.
- If the DNN ran (and `USE_DNN_STAGE3=true`), also store the predicted polygon
- **BEV coordinate transform:** Store `bev_origin_xz` (world-space XZ of the density map's [0,0] pixel) and `bev_meters_per_pixel` alongside the density map. These are needed by the iOS app to correctly overlay polygons on the density map image.

**File to modify:** `cloud/api/main.py`

- **BEV density URL:** Generate a **signed URL with 7-day expiry** (not a raw public URL) for the density map PNG, since the GCS bucket is not publicly readable.
- Extend `GET /api/rfqs/{rfqId}/scans/{scanId}/status` response:

```json
{
    "scan_id": "uuid",
    "status": "scan_ready",
    "training_status": "annotated",

    "floor_area_sqft": 250.5,
    "wall_area_sqft": 1200.0,
    "ceiling_height_ft": 8.5,
    "perimeter_linear_ft": 65.0,
    "detected_components": { "detected": ["floor_hardwood", "ceiling_drywall"] },
    "scan_dimensions": { "...existing keys..." },

    "bev_density_url": "https://storage.googleapis.com/...(signed)...",
    "bev_origin_xz": [-3.0, -2.5],
    "bev_meters_per_pixel": 0.05,
    "bev_polygon_geometric": [[-2.5, -1.8], [2.5, -1.8], [2.5, 3.0], [-2.5, 3.0]],
    "bev_polygon_predicted": null,
    "bev_polygon_annotated": [[-2.5, -1.8], [2.5, -1.8], [2.5, 3.0], [-2.5, 3.0]],
    "bev_edge_types_annotated": ["ceiling", "ceiling", "door", "open_pass"],

    "scan_mesh_url": "https://storage.googleapis.com/..."
}
```

**Polygon disambiguation:** Three separate polygon fields:
- `bev_polygon_geometric` — always present, from Stage 3 boundary extraction
- `bev_polygon_predicted` — present only if DNN ran, from RoomFormer inference
- `bev_polygon_annotated` — present only if user annotated corners (ceiling trace), for visual comparison
- `bev_edge_types_annotated` — edge types for the annotated polygon, for rendering opening styles

All existing metrics continue to be returned (floor area, wall area, ceiling height, perimeter, detected components, bounding box, 3D mesh URL). Phase 1 scans return `null` for all BEV fields — the iOS app hides the BEV section when `bev_density_url` is absent.

### iOS Side

**File to modify:** `RoomScanAlpha/Cloud/CloudUploader.swift`

- Parse new BEV fields from status response. Maintain consistency with Phase 1's manual `response["key"]` parsing pattern (not `Codable`).
- Extend `ScanResult` struct:

```swift
struct ScanResult {
    // ...existing fields...
    let bevDensityURL: URL?
    let bevOriginXZ: [Double]?
    let bevMetersPerPixel: Double?
    let bevPolygonGeometric: [[Double]]?
    let bevPolygonPredicted: [[Double]]?
    let bevPolygonAnnotated: [[Double]]?
    let bevEdgeTypesAnnotated: [String]?
    let trainingStatus: String?
}
```

**File to modify:** `RoomScanAlpha/Views/ScanResultView.swift`

- Add "BEV Density Map" section showing:
  - The 256×256 density map image (async loaded from `bevDensityURL`). Cache locally after first load to handle signed URL expiry on subsequent views.
  - Polygon overlays using `bev_origin_xz` + `bev_meters_per_pixel` to transform world-space polygon coordinates to image pixel coordinates:
    - Geometric polygon (always shown, light gray)
    - Annotated polygon (if present, green overlay) with edge types rendered: solid for ceiling, dashed for door, dotted for open_cased, gap for open_pass
    - Predicted polygon (if present, blue overlay) for visual comparison against annotated
  - Training status badge: "Annotated — included in training set" or "Not annotated"
- All existing result sections remain: room dimensions, detected components, scan stats, bounding box, "View 3D Scan" button

### Test Cases — Step 7

#### Automated Tests

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S7.1 | BEV density PNG generated for every scan | Process scan without DNN enabled | `bev_density.png` exists in GCS | File is 256×256 PNG, non-zero pixels present |
| S7.2 | BEV coordinate transform stored | Check processor output | `bev_origin_xz` and `bev_meters_per_pixel` present | Values are consistent with mesh bounding box |
| S7.3 | Signed URL has 7-day expiry | Generate BEV density URL | URL contains expiry parameter | Expiry timestamp is ~7 days from now |
| S7.4 | Annotated polygon echoed in API | Process annotated scan, GET status | `bev_polygon_annotated` matches uploaded corners | Coordinate values match within float precision |
| S7.5 | Edge types returned in API | Process annotated scan with mixed edge types | `bev_edge_types_annotated` present | Array length matches polygon corner count |
| S7.6 | Phase 1 scan returns null BEV fields | GET status for pre-Phase 2 scan | All BEV fields are null | No error; clean JSON |
| S7.7 | Polygon pixel transform correct | Convert world coords to image pixels using origin + scale | Polygon overlays on density map correctly | Wall lines in polygon align with bright lines in density map |
| S7.8 | ScanResult parses new fields | Parse sample API response with all BEV fields | All fields populated on ScanResult | No nil for present fields; correct types |

#### Manual / Device Tests

| ID | Test | Procedure | Pass Criteria |
|----|------|-----------|---------------|
| S7.M1 | BEV density map visible in results | Complete a scan with annotation, view results | Density map image loads in BEV section | 256×256 grayscale image visible; walls appear as bright lines |
| S7.M2 | Annotated polygon overlays correctly | View results for annotated scan | Green polygon overlaid on density map | Polygon edges align with bright wall lines in density map |
| S7.M3 | Edge types rendered on overlay | View results for scan with door + open_pass edges | Different line styles for different edge types | Dashed for door, gap for open_pass, solid for ceiling |
| S7.M4 | Training status badge shown | View results for annotated scan | "Annotated" badge visible | Green badge text |
| S7.M5 | BEV section hidden for Phase 1 scans | View results for an old scan | No BEV section | Section completely absent, not showing empty state |

### Files Summary — Step 7

| Action | File |
|--------|------|
| **Modify** | `cloud/processor/main.py` — generate + upload BEV density PNG with coordinate transform |
| **Modify** | `cloud/api/main.py` — return signed `bev_density_url`, coordinate transform, disambiguated polygon fields with edge types |
| **Modify** | `RoomScanAlpha/Cloud/CloudUploader.swift` — parse new response fields including edge types |
| **Modify** | `RoomScanAlpha/Views/ScanResultView.swift` — display BEV density map with polygon overlays + edge type rendering |

---

## Complete State Flow

```
idle → selectingRFQ → scanReady → scanning → annotatingCorners → labelingRoom → exporting → uploading → viewingResults
                         ↑            │                                                                          │
                         └── redo ────┘                                                                          │
                         ↑                                                                                       │
                         └──────────────────────── "Scan Another Room" ─────────────────────────────────────────┘
```

**Key difference from Phase 1:** Annotation sits between scanning and room labeling. The AR session runs continuously from `scanReady` through `annotatingCorners` — it is only terminated at the `labelingRoom` → `exporting` transition. This means the mesh and keyframes improve throughout the annotation phase.

| State | UI | AR Session | Actions Available |
|-------|-----|------------|-------------------|
| `selectingRFQ` | RFQ list + create | Not started | Select project |
| `scanReady` | AR preview + "Start Scan" | Running (preview only) | Start scan |
| `scanning` | AR wireframe + HUD (quality %, coverage %, frame count) | Running (capturing) | Stop scan |
| `annotatingCorners` | AR mesh + crosshair + trace controls + edge type selector | **Running** (mesh refining, keyframes upgrading) | Lock corner, Undo, Close trace, Add trace, Cycle edge type, Redo scan, Skip, Done |
| `labelingRoom` | Room name picker | Paused (annotation complete) | Select label → `exporting` |
| `exporting` | Progress spinner | Terminated (mesh snapshot taken) | — |
| `uploading` | Progress bar | Terminated | — |
| `viewingResults` | Dimensions + components + BEV density map + 3D viewer | Terminated | "View 3D Scan", "Scan Another Room" (→ `scanReady`), "Done" |

---

## Dependency Order

### Development Order

```
Step 1 (keyframe quality)  ──┐
Step 2 (start/stop/redo)   ──┼── independent, can be done in parallel
Step 3 (delete scans)      ──┘
                               │
Step 4 (AR corner annotation) ─── depends on Step 2 (state machine changes)
                               │
Step 5 (metadata.json)     ─── depends on Steps 1 + 4 (quality scores + traces)
                               │
Step 6 (cloud routing)     ─── depends on Step 5 (reads new metadata fields)
                               │
Step 7 (BEV display)       ─── depends on Step 6 (cloud generates + returns data)
```

Steps 1, 2, and 3 can be implemented in parallel. Steps 4–7 are sequential.

### Deployment Order (Critical)

Development and deployment order differ. Cloud changes must ship first:

1. **Deploy schema migration** (`cloud/migrations/002_add_training_status.sql`)
2. **Deploy cloud processor + API** (Steps 5 backend validation, 6, 7 backend) — must accept new metadata fields before iOS sends them
3. **Deploy iOS app** (Steps 1–4, 5 iOS, 7 iOS) — sends new metadata fields

Reversing steps 2 and 3 causes iOS to send Phase 2 metadata that the old processor rejects, breaking all uploads.

### Rollback Plan

If the Phase 2 cloud processor has a bug:
1. **Revert processor** to Phase 1 version — it will ignore new metadata fields (they're optional)
2. **Reprocess affected scans** via `POST /process` with the scan's GCS path (existing mechanism)
3. **Invalidate bad training data** by deleting the `training/{scan_id}/` and `training_images/{scan_id}/` GCS prefixes for affected scans, then reprocess

---

## Files Changed (Complete)

### New Files (6)

| File | Step | Purpose |
|------|------|---------|
| `RoomScanAlpha/AR/FrameQualityScorer.swift` | 1 | Sharpness (Laplacian) + feature density (Harris/Shi-Tomasi) + coverage scoring on raw CVPixelBuffer |
| `RoomScanAlpha/AR/CoverageTracker.swift` | 1 | XZ grid tracking (`GridCell` type) for spatial gap detection, live mesh anchor access |
| `RoomScanAlpha/Views/CornerAnnotationView.swift` | 4 | AR crosshair UI, zoom loupe, auto-connect lines, trace type selector, edge type cycling, snap indicators, multi-trace management |
| `RoomScanAlpha/ViewModels/CornerAnnotationViewModel.swift` | 4 | Multi-trace corner management, RANSAC plane-intersection snap, polygon validation, winding normalization, edge type state |
| `RoomScanAlpha/Models/CornerAnnotation.swift` | 4 | `TraceAnnotation` + `CornerAnnotation` Codable models with edge types |
| `cloud/migrations/002_add_training_status.sql` | 6 | Schema migration: add `training_status` column to `scanned_rooms` |

### Modified Files — iOS (11)

| File | Steps | Changes |
|------|-------|---------|
| `RoomScanAlpha/AR/FrameCaptureManager.swift` | 1, 2 | Score-and-replace with hysteresis, `slotReplacementCounts`, pipeline reorder (score before JPEG), `reset()`, coverage-aware capture |
| `RoomScanAlpha/AR/ARSessionManager.swift` | 2, 4 | `resetSession()`; session stays running through annotation; terminate only at export |
| `RoomScanAlpha/Models/CapturedFrame.swift` | 1 | Quality score fields + `replacementCount` |
| `RoomScanAlpha/Models/ScanState.swift` | 2, 4 | Add `scanReady`, `annotatingCorners` states |
| `RoomScanAlpha/Models/ScanRecord.swift` | 3 | Add `deleteRecord(scanId:)` to embedded `ScanHistoryStore` class |
| `RoomScanAlpha/ViewModels/ScanViewModel.swift` | 2, 4 | `startScan()`, `stopScan()` → `.annotatingCorners` (session stays live), `redoScan()` clears RFQ context, store corner annotation with traces |
| `RoomScanAlpha/Views/ScanningView.swift` | 1, 2 | Blur warning, coverage indicator, start/stop buttons |
| `RoomScanAlpha/Views/ScanHistoryView.swift` | 3 | Swipe-to-delete, API-first delete flow, stronger warning for annotated scans |
| `RoomScanAlpha/Views/ScanResultView.swift` | 7 | BEV density map display with coordinate transform overlay, polygon disambiguation (geometric/predicted/annotated), edge type rendering |
| `RoomScanAlpha/Cloud/CloudUploader.swift` | 7 | Parse BEV fields + coordinate transform + edge types + training_status from status response |
| `RoomScanAlpha/Cloud/RFQService.swift` | 3 | `deleteScan()` API call |
| `RoomScanAlpha/Export/ScanPackager.swift` | 1, 5 | Multi-trace corner annotations (with edge types, snap_distance, corners_y) + per-frame quality scores + replacement_count in metadata.json |
| `RoomScanAlpha/ContentView.swift` | 2, 4 | Route `scanReady`, `annotatingCorners` states; `stopScan()` → annotation; "Scan Another Room" → `scanReady` |

### Modified Files — Cloud (2)

| File | Steps | Changes |
|------|-------|---------|
| `cloud/processor/main.py` | 5, 6, 7 | Accept new metadata fields; extract ceiling trace → training GCS paths with edge types; copy keyframes with quality scores; always generate BEV PNG + coordinate transform; async training copy; idempotent writes |
| `cloud/api/main.py` | 3, 6, 7 | Soft-delete scan endpoint; return `training_status`, signed `bev_density_url`, `bev_origin_xz`, `bev_meters_per_pixel`, disambiguated polygon fields with edge types |

---

## Cross-Cutting Concerns

### Backward Compatibility with Phase 1 Scans
Phase 1 scans have no `training_status`, no quality scores, no corner annotations. All code paths (API, processor, iOS app) must handle `NULL`/missing values for these fields. The API returns `null` for BEV fields on Phase 1 scans; the iOS app hides the BEV section when `bev_density_url` is absent.

### ARKit Testability
Phase 2 features (coverage tracking, plane-intersection snap, raycasts) depend on ARKit types that cannot run in unit tests. Strategy: (a) extract pure-geometry logic (polygon validation, grid cell assignment, plane intersection math, winding normalization, edge type management) into testable functions with no ARKit dependency, (b) accept that raycast integration, snap accuracy, and live-session annotation are tested via manual device tests only, (c) consider protocol abstractions around `ARMeshAnchor` if mocking becomes necessary for CI.

### GCS Lifecycle
- `scans/` prefix: Coldline after 90 days (raw uploads are rarely re-accessed)
- `training/` prefix: No lifecycle rule (active training data)
- `training_images/` prefix: No lifecycle rule (active training data)

---

## Test Case Summary

| Step | Automated | Manual/Device | Total |
|------|-----------|---------------|-------|
| 1 — Keyframe Quality | 10 | 5 | 15 |
| 2 — Start/Stop/Redo | 6 | 4 | 10 |
| 3 — Delete Scans | 5 | 4 | 9 |
| 4 — AR Corner Annotation | 14 | 15 | 29 |
| 5 — Metadata Export | 6 | 0 | 6 |
| 6 — Cloud Routing | 10 | 0 | 10 |
| 7 — BEV Display | 8 | 5 | 13 |
| **Total** | **59** | **33** | **92** |
