> **DEPRECATED:** Panoramic sweep was removed and replaced by denser walk-around capture (8° rotation, 0.3s interval). The code still exists (`PanoramaSweepView.swift`) but is never entered in the scan flow.

## Panoramic Sweep — Implementation Status (2026-03-30)

### What Was Built

A dedicated 360° panoramic sweep capture step was added between corner annotation and room labeling in the iOS scan flow. The purpose: provide co-located keyframe images from a single position with a known start heading (facing the first annotation corner) so the cloud texture projection can map images onto wall/floor/ceiling surfaces accurately.

### iOS Changes

**New state: `.capturingPanorama`** in `RoomScanAlpha/Models/ScanState.swift`
- Inserted between `.annotatingCorners` and `.labelingRoom`

**New view: `RoomScanAlpha/Views/PanoramaSweepView.swift`**
- Shows AR camera feed with alignment prompt ("Face the first corner you marked")
- "Start Sweep" button records `panoramaStartTransform` (camera transform facing corner 0)
- Captures frames at 5° rotation intervals during 360° user rotation
- Progress ring shows yaw from 0° to 360°
- "Done" button appears at ≥330° coverage
- "Skip" button bypasses the sweep entirely

**Modified: `RoomScanAlpha/AR/ARSessionManager.swift`**
- `isPanoramicCapture` flag, `panoramicFrames` array, `panoramaStartTransform`
- `startPanoramicCapture()` / `stopPanoramicCapture()` / `resetPanoramicCapture()`
- `onPanoramicFrameCaptured` callback for UI updates (frame count + yaw degrees)
- Panoramic capture runs in `session(_:didUpdate:)` when `isPanoramicCapture` is true

**Modified: `RoomScanAlpha/AR/FrameCaptureManager.swift`**
- `processPanoramicFrame(_:startTransform:)` — rotation-only threshold (5° vs 15° for walk-around), no translation check
- `PanoramicCaptureResult` struct with `frame` + `yawDegrees` relative to start heading
- `resetPanoramicState()` clears panoramic tracking state
- Max 120 panoramic frames, 0.15s minimum interval

**Modified: `RoomScanAlpha/ViewModels/ScanViewModel.swift`**
- `panoramaStartTransform: simd_float4x4?` — camera transform when sweep started
- `panoramaFrameCount: Int` — live frame count for UI
- Both cleared in `prepareScan()` and `redoScan()`

**Modified: `RoomScanAlpha/ContentView.swift`**
- `.capturingPanorama` case renders `PanoramaSweepView`
- `handleAnnotationDone()` now transitions to `.capturingPanorama` (not directly to labeling)
- `handleAnnotationSkip()` still goes directly to labeling (no panorama)
- `handlePanoramaDone()` / `handlePanoramaSkip()` added
- `firstAnnotationCorner` computed property for alignment guide
- `startExport()` passes `panoramicFrames` + `panoramaStartTransform` to ScanPackager
- `ScanningView.onDisappear` allows session to stay running for `.capturingPanorama`

**Modified: `RoomScanAlpha/Export/ScanPackager.swift`**
- `package()` accepts optional `panoramicFrames` + `panoramaStartTransform`
- Exports panoramic frames to `panoramic/pano_NNN.jpg` + `panoramic/pano_NNN.json`
- Exports panoramic depth to `panoramic_depth/pano_NNN.depth`
- `ScanMetadata` includes `panoramic_keyframe_count`, `panorama_start_transform` (16-float column-major array), `panoramic_keyframes` array
- All panoramic fields use `encodeIfPresent` (absent when no sweep)

### Cloud Changes

**Modified: `cloud/processor/pipeline/texture_projection.py`**
- `load_panoramic_keyframes(scan_root, metadata)` — loads from `panoramic/` directory
- `load_keyframes()` unchanged — loads walk-around frames from `keyframes/`
- Processor prefers panoramic frames when available, falls back to walk-around

**Modified: `cloud/processor/main.py`**
- Step 7A imports `load_panoramic_keyframes` alongside existing loaders
- Tries `load_panoramic_keyframes()` first; if empty, uses `load_keyframes()`

### What Still Needs Work

**Texture alignment is not yet validated end-to-end.** The per-surface texture projection (`texture_projection.py`) has had multiple iterations of bugs:
1. Y-axis projection formula: `py = -fy * cam_y / depth + cy` — verified correct numerically
2. Depth filtering: disabled entirely (depth maps measure furniture, not wall planes)
3. Radial weight falloff: added for smooth blending at frame edges
4. Image flip: NO flip in save_textures (Three.js flipY handles the V-axis mapping)
5. Max 15 keyframes per surface, angle threshold 0.02 for floor/ceiling

**The projection math has been verified numerically** (annotation corners project to correct pixel positions in keyframe images), but the rendered textures in the Three.js viewer still show orientation issues. The panoramic sweep should fix this because:
- All frames share the same camera position (eliminates parallax)
- Start heading aligns with corner 0 (known coordinate anchor)
- Even angular spacing (5°) ensures uniform coverage

**The Three.js viewer (`cloud/web/contractor_view.html`)** builds room-shaped geometry (wall quads + floor/ceiling polygons from the floor plan polygon + ceiling height) and applies per-surface texture JPEGs. It uses `MeshBasicMaterial` (no lighting) with `DoubleSide`. Camera is placed inside the room at eye height.

**Key coordinate relationship:** annotation corners and keyframe camera_transforms are in the same ARKit world space (Y-up, right-handed). The `panorama_start_transform` records which direction the user was facing when they started the sweep — this is aligned to annotation corner 0.

### Scan Package Structure (with panoramic frames)

```
scan_TIMESTAMP/
  metadata.json          — includes panoramic_keyframes, panorama_start_transform
  mesh.ply
  keyframes/             — walk-around frames (60 frames, 15° rotation threshold)
    frame_000.jpg
    frame_000.json       — {index, timestamp, camera_transform[16], image_width, image_height, depth_width, depth_height}
    ...
  depth/                 — walk-around depth maps
    frame_000.depth      — float32 binary, 256×192
    ...
  panoramic/             — sweep frames (up to 120 frames, 5° rotation threshold)
    pano_000.jpg
    pano_000.json        — same format as frame JSONs
    ...
  panoramic_depth/       — sweep depth maps
    pano_000.depth
    ...
```

### How to Test

Build and install the updated iOS app. Scan a room → annotate corners → do the panoramic sweep → label → upload. The cloud processor will prefer panoramic frames for texture projection.

**Why panoramic sweep matters:** Recorded camera transforms from the panoramic sweep (in AR world space) project keyframe images onto wall/floor/ceiling surfaces defined by the annotation polygon (also in AR world space). The start heading alignment to corner 0 ensures the texture content lands on the correct walls.
