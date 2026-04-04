> **DEPRECATED:** Original system architecture plan from project inception. Superseded by actual implementation. See `CLAUDE.md` for current architecture, data flow, and conventions.

# RoomScanAlpha

iOS room scanning app using LiDAR. Captures room geometry and camera keyframes on-device, uploads to Google Cloud for CV processing (ORB/homography stitching, Vertex AI object recognition), and displays structured room data (dimensions, detected components, appliances).

Companion Android/ARCore app shares the same cloud pipeline. This repo covers iOS + cloud services.

## System Architecture

```
iOS App (capture + upload)
  │
  ├─ Firebase Auth (JWT)
  ├─ GCS (signed URL upload, ~75MB zip)
  │
  └─ Cloud Run REST API
       ├─ Cloud Tasks → Scan Processor (Cloud Run, OIDC-protected)
       │                     ├─ PLY parsing + room metrics
       │                     └─ Cloud SQL (PostgreSQL)
       └─ FCM push notification → iOS App (scan complete)
```

**Key decision**: All heavy CV processing happens in the cloud, not on-device. The iOS app's job is to capture high-quality mesh + keyframes and upload them.

## Unit Convention

| Layer | Unit | Examples |
|-------|------|----------|
| On-device geometry (ARKit, PLY, metadata origin) | **meters** | Vertex positions, bounding box, origin_x/y |
| Cloud-computed room dimensions | **imperial (sq ft / ft)** | floor_area_sqft, ceiling_height_ft, perimeter_linear_ft |

Never mix. Conversion happens once at the output boundary in `compute_room_metrics()`.

---

## Application Lifecycle

The app follows a linear state machine defined in `ScanState`. `ContentView` switches on this state, and `ScanViewModel` owns all session data.

```
idle → selectingRFQ → scanning → labelingRoom → exporting → uploading → viewingResults
         ↑                                                                     │
         └──── (done) ──────────────────────────────────────────────────────────┘
         ↑                                                                     │
         └──── (scan another room, same RFQ) ──────────────────────────────────┘
```

### State Transitions

| From | To | Trigger |
|------|----|---------|
| `idle` | `selectingRFQ` | User taps "Select Project" (or no RFQ selected yet) |
| `selectingRFQ` | `scanning` | User selects an RFQ in `RFQSelectionView` |
| `scanning` | `labelingRoom` | User stops scan and quality is sufficient (≥15 keyframes, ≥500 triangles) |
| `scanning` | quality warning | Quality insufficient — user chooses "Continue Scanning" or "Export Anyway" |
| `labelingRoom` | `exporting` | User confirms room label; storage check passes (≥200MB free) |
| `exporting` | `uploading` | Package built; network available (Wi-Fi or user confirms cellular) |
| `uploading` | `viewingResults` | Upload succeeds; polling begins |
| `viewingResults` | `idle` | User taps "Done" |
| `viewingResults` | `scanning` | User taps "Scan Another Room" (keeps same RFQ) |

---

## iOS App Internals

### AR Capture Layer

Three components work together during the `scanning` state:

**`ARSessionManager`** owns the `ARSession` and coordinates capture.
- Configures `ARWorldTrackingConfiguration` with `.meshWithClassification` and `.sceneDepth`
- On each frame update, forwards the `ARFrame` to `FrameCaptureManager`
- On pause, snapshots `lastMeshAnchors` for export and 3D preview

**`FrameCaptureManager`** selects keyframes based on camera movement.
- Thresholds tuned for 30–60 keyframes when walking a ~4×4m room:
  - Translation: ≥0.15m (enough overlap for ORB feature matching)
  - Rotation: ≥15° (captures corner turns and up/down views)
  - Minimum interval: ≥0.5s (suppresses hand tremor bursts)
  - Hard cap: 60 frames (keeps package under ~100MB)
- Each captured frame is immediately converted to a `CapturedFrame` — JPEG image + raw depth bytes + camera pose — and the original `CVPixelBuffer` is released. This is critical: 60 raw buffers would be ~480MB and crash the app.

**`ARScanningView`** renders the live wireframe overlay via `ARSCNView`.
- Coordinator caches geometry signatures per anchor to avoid rebuilding unchanged meshes
- Maintains an incremental triangle count (delta updates, not full recomputation)
- Color-codes wireframe by `ARMeshClassification`: walls = blue, floor = green, ceiling = yellow, etc.
- Pushes stats to `ScanViewModel` on the main thread for HUD display

**Data flow during scanning:**
```
ARSession frame update
  → FrameCaptureManager.processFrame()
      → CapturedFrame (JPEG + depth + 4×4 pose)
  → ScanViewModel.updateKeyframeCount()
  → ARScanningView renders wireframe + pushes triangle count
```

### RFQ & Room Context

Before scanning, the user selects a project (RFQ) and after scanning, labels the room.

**`RFQSelectionView`** loads RFQs from the backend via `RFQService.listRFQs()` (authenticated with Firebase JWT). Users can select an existing project or create a new one. The selected `RFQ` is bound to `ScanViewModel.selectedRFQ`.

**`RoomLabelView`** prompts for a room name (text field + preset suggestions like Kitchen, Bedroom, etc.). On confirmation, `ScanViewModel.buildRFQContext()` captures:
- `rfq_id`, `floor_id` (auto-generated per scan), `room_label`
- Room origin (`origin_x`, `origin_y`) from the AR session's camera position in world space (meters)
- Heading (`rotation_deg`) extracted from the camera transform's X-axis basis vector: `atan2(col0.z, col0.x)`

This `RFQContext` is written into `metadata.json` during export and stored in the `scanned_rooms` DB row.

### Export Pipeline

After room labeling, `ContentView.startExport()` runs the packaging on a background thread:

**`ScanPackager.package()`** assembles the upload directory:
1. Calls `PLYExporter.export()` to write `mesh.ply`
2. Writes each keyframe: `frame_NNN.jpg` (JPEG data), `frame_NNN.json` (camera transform, intrinsics), `frame_NNN.depth` (raw Float32 bytes)
3. Builds `metadata.json` from `ScanMetadata.build()` — device info, camera intrinsics, image/depth resolution, keyframe list, RFQ context, mesh counts

**`PLYExporter.export()`** writes binary little-endian PLY using a two-pass streaming approach (no intermediate arrays):
- Pass 1: count total vertices/faces across all anchors; write ASCII header
- Pass 2: stream binary data per-anchor directly to a file handle
- Vertex format: 6 × float32 (x, y, z, nx, ny, nz) = 24 bytes. Positions transformed from anchor-local to world space; normals use only the 3×3 rotation submatrix.
- Face format: 1 byte count + 3 × uint32 indices (offset to global space) + 1 byte ARMeshClassification = 14 bytes per triangle

After export, `ContentView` checks network state: proceeds on Wi-Fi, prompts on cellular, or shows an error if offline.

### Upload & Result Polling

**`CloudUploader.upload()`** runs the full upload sequence:

| Step | Progress | Action |
|------|----------|--------|
| Auth | 0.00–0.05 | `AuthManager.signInAnonymously()` + `getToken()` |
| Zip | 0.05–0.10 | `NSFileCoordinator` with `.forUploading` → temp zip |
| Signed URL | 0.10–0.15 | `GET /api/rfqs/{rfq_id}/scans/upload-url` (with retry) |
| GCS upload | 0.15–0.90 | `PUT` zip to signed URL; `UploadProgressDelegate` tracks bytes |
| Notify | 0.90–1.00 | `POST /api/rfqs/{rfq_id}/scans/complete` (with retry) |

All HTTP requests use `executeWithRetry()` — exponential backoff (1s, 2s, 4s… up to 30s) for status codes 408, 429, 500–504. Only one upload is allowed at a time (`isUploading` flag).

After upload, `CloudUploader.pollForResult()` hits `GET .../status` every 5 seconds until the scan reaches `"complete"` or `"failed"`. The app also subscribes to FCM topic `scan_{scan_id}` for push notification delivery as a faster path.

### Results Display

**`ScanResultView`** renders three states based on `viewModel.scanResult`:
- **Processing**: spinner + "Processing your scan…"
- **Complete**: room dimensions (floor area, wall area, ceiling height, perimeter in imperial), detected components as flow-layout tags, scan stats (keyframe count, triangle count), bounding box in meters
- **Failed**: error message with option to return

A "View 3D Scan" button opens `MeshViewerSheet`, which renders the captured mesh anchors in a `SCNView` with orbit/pan/zoom (`allowsCameraControl`), color-coded by classification.

"Scan Another Room" keeps the current RFQ selected and starts a new scan — enabling multi-room sessions where each room gets its own `scanned_rooms` row under the same RFQ.

### Scan History

`ScanHistoryStore` persists `ScanRecord` entries to `UserDefaults` (last 100). Each record captures scan_id, RFQ, room label, status, keyframe/triangle counts, and timestamp. `ScanHistoryView` groups records by RFQ and displays status icons + relative timestamps. History survives app restarts.

### Authentication

`AuthManager` wraps Firebase Auth. The app uses anonymous auth — `signInAnonymously()` on first launch, then `getToken()` before every API call to get a fresh JWT. The backend validates tokens via `firebase_auth.verify_id_token()`.

---

## Cloud Services

See [`cloud/README.md`](cloud/README.md) for setup, local dev, and deployment instructions.

### REST API (`cloud/api/main.py`)

FastAPI service on Cloud Run. All endpoints require a Firebase JWT except `/health`.

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/rfqs` | List RFQs (most recent 50) |
| POST | `/api/rfqs` | Create RFQ |
| GET | `/api/rfqs/{rfq_id}/scans/upload-url` | Generate GCS signed URL (15 min TTL, IAM-based signing) |
| POST | `/api/rfqs/{rfq_id}/scans/complete` | Insert `scanned_rooms` row + enqueue Cloud Tasks job |
| GET | `/api/rfqs/{rfq_id}/scans/{scan_id}/status` | Return scan status + room dimensions + components |

On `upload-complete`, the API inserts a `scanned_rooms` row with `scan_status='processing'` and enqueues a Cloud Tasks job targeting the processor's `/process` endpoint with an OIDC token (ensuring only Cloud Tasks can invoke the processor).

### Scan Processor (`cloud/processor/main.py`)

FastAPI service on Cloud Run, deployed with `--no-allow-unauthenticated`. Invoked exclusively by Cloud Tasks.

**Processing pipeline:**
1. Download zip from GCS
2. Unzip and locate scan root
3. **Validate structure**: PLY header, metadata.json keys, JPEG SOI markers, per-frame camera transforms (16-element arrays), depth file sizes
4. **Parse binary PLY**: bulk-read vertices (Nx6 float32) and faces with per-face classification bytes
5. **Compute room metrics** (all geometry in meters, converted to imperial at output):
   - Floor/wall area: sum triangle areas by classification (m² → sq ft)
   - Ceiling height: Y-distance between floor-classified and ceiling-classified vertices (m → ft)
   - Perimeter: convex hull of floor vertices projected onto XZ plane (m → ft; falls back to bounding-box approximation on degenerate geometry)
   - Detected components: map ARKit classification values to label names
6. **Update DB**: write dimensions + components to `scanned_rooms`, set `scan_status='complete'`. If all rooms for the RFQ are complete, transition `rfqs.status` to `'scan_ready'`.
7. **Send FCM notification**: topic `scan_{scan_id}` with status + `rfq_ready` flag

### Database Schema (`cloud/schema.sql`)

Core tables for the scan pipeline:

| Table | Purpose |
|-------|---------|
| `rfqs` | Request-for-quote projects. Status: `scan_pending` → `scan_ready` (when all rooms complete) |
| `scanned_rooms` | One row per room scan. FK to `rfqs`. Holds dimensions, components, scan_dimensions, origin coordinates |
| `scan_component_labels` | Vocabulary of detectable component types (e.g., `floor_hardwood`, `ceiling_drywall`) |

Room-level status (`scanned_rooms.scan_status`): `processing` → `complete` | `failed`
RFQ-level status (`rfqs.status`): `scan_pending` → `scan_ready` (aggregated from all rooms)

---

## Upload Format

Each scan uploads ~75MB as a zip:

```
scan_<timestamp>/
├── mesh.ply              # Binary PLY: vertices (x,y,z,nx,ny,nz), faces + classification
├── metadata.json         # Device info, intrinsics, keyframe list, RFQ context
├── keyframes/
│   ├── frame_000.jpg     # 30-60 JPEGs selected by movement thresholds
│   ├── frame_000.json    # Per-frame camera_transform (4×4, column-major)
│   └── ...
└── depth/
    ├── frame_000.depth   # Raw Float32 depth maps (little-endian)
    └── ...
```

### metadata.json

```json
{
  "rfq_id": "uuid", "floor_id": "uuid", "room_label": "Kitchen",
  "origin_x": 3.45, "origin_y": 1.22, "rotation_deg": 90.0,
  "device": "iPhone 15 Pro", "ios_version": "17.4",
  "scan_duration_seconds": 45.2,
  "camera_intrinsics": { "fx": 1234.5, "fy": 1234.5, "cx": 960, "cy": 540 },
  "image_resolution": { "width": 1920, "height": 1440 },
  "depth_format": { "pixel_format": "kCVPixelFormatType_DepthFloat32", "width": 256, "height": 192, "byte_order": "little_endian" },
  "keyframe_count": 34, "mesh_vertex_count": 12450, "mesh_face_count": 24300,
  "keyframes": [{ "index": 0, "filename": "frame_000.jpg", "depth_filename": "frame_000.depth", "timestamp": 1234567890.123, "camera_transform": [] }]
}
```

---

## Project Structure

```
RoomScanAlpha/
├── RoomScanAlphaApp.swift          # Entry point, Firebase init
├── ContentView.swift               # State-driven root view, orchestrates lifecycle
├── DeviceCapability.swift          # LiDAR + ARKit detection
│
├── Models/
│   ├── ScanState.swift             # Lifecycle enum with transition docs
│   ├── CapturedFrame.swift         # Keyframe: JPEG + depth + pose
│   ├── ScanRecord.swift            # Persisted scan history
│   └── RFQContext.swift            # RFQ/floor/room metadata
│
├── ViewModels/
│   └── ScanViewModel.swift         # Scan session state + quality thresholds
│
├── Views/
│   ├── ScanningView.swift          # SwiftUI AR wrapper + HUD overlay
│   ├── ARScanningView.swift        # UIViewRepresentable → ARSCNView wireframe
│   ├── RFQSelectionView.swift      # Project picker (loads from API)
│   ├── RoomLabelView.swift         # Room name tagging post-scan
│   ├── ExportingView.swift         # Export progress overlay
│   ├── ScanResultView.swift        # Dimensions + components + 3D preview
│   ├── MeshViewerView.swift        # SceneKit 3D mesh viewer (orbit/pan/zoom)
│   └── ScanHistoryView.swift       # Past scans grouped by RFQ
│
├── AR/
│   ├── ARSessionManager.swift      # Session config + delegate + frame forwarding
│   ├── MeshExtractor.swift         # Anchor → geometry, classification colors
│   └── FrameCaptureManager.swift   # Keyframe selection (movement thresholds)
│
├── Export/
│   ├── PLYExporter.swift           # Streaming binary PLY writer
│   └── ScanPackager.swift          # Bundle keyframes + mesh + metadata.json
│
└── Cloud/
    ├── CloudUploader.swift         # Signed URL upload + retry + polling
    ├── AuthManager.swift           # Firebase Auth + JWT
    └── RFQService.swift            # RFQ list/create API calls

cloud/
├── api/main.py                     # REST API (FastAPI on Cloud Run)
├── processor/main.py               # Scan processor (FastAPI on Cloud Run)
├── schema.sql                      # PostgreSQL schema
└── README.md                       # Cloud setup & deploy guide
```

## Testing

12 test suites covering the full application:

| Suite | Coverage |
|-------|----------|
| `FrameCaptureManagerTests` | Keyframe selection thresholds, cap, intervals |
| `MeshExtractorTests` | Classification colors, vertex transforms |
| `PLYExporterTests` | Binary PLY format, header, classification values |
| `ScanPackagerTests` | Package structure, metadata schema, JPEG/depth export |
| `CapturedFrameTests` | Frame data structure, intrinsics, memory model |
| `ScanViewModelTests` | State transitions, quality thresholds, mesh stats |
| `CloudUploaderTests` | Zip creation, retry logic, signed URL handling |
| `ScanHistoryTests` | Persistence, status display, RFQ grouping |
| `ScanResultViewTests` | Result rendering, status enum mapping |
| `AccessibilityTests` | VoiceOver labels on all interactive elements |
| `ErrorRecoveryTests` | State reset, rapid transitions, storage checks |
| `UploadResilienceTests` | Retry with mocked 503, concurrent upload prevention |

### CI Workflows

- **`tests.yml`**: Builds on macOS, runs all unit tests on iPhone simulator
- **`cloud-stub-tests.yml`**: Integration tests against deployed cloud services (requires GitHub Actions secrets: `SCAN_API_BASE_URL`, `FIREBASE_PROJECT_ID`, `FIREBASE_API_KEY`, `GOOGLE_SERVICE_INFO_PLIST`)

## Key Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Memory pressure (60 × ~8MB buffers) | JPEG conversion + buffer release in capture callback; 60-frame cap |
| Cloud rejects scan format | Processor validates PLY header, metadata keys, JPEG markers, depth files before processing |
| PLY coordinate system mismatch | ARKit Y-up right-handed enforced; cloud validates orientation |
| ~75MB upload on cellular | Cellular warning dialog; retry with exponential backoff |
| Firebase token expiry mid-upload | Fresh JWT fetched before each API call via `getToken()` |
| Offline scans lost | Scan packages persisted to disk; upload retries on connectivity |
| metadata.json ↔ DB schema drift | Processor validates required keys; metadata schema matches `scanned_rooms` columns |

## Related Documentation

- [`cloud/README.md`](cloud/README.md) — Cloud service setup, local dev, deployment
- [`cloud/CLOUD_PIPELINE_PLAN.md`](cloud/CLOUD_PIPELINE_PLAN.md) — Full CV processing pipeline spec
- [`cloud/DNN_COMPONENT_TAXONOMY.md`](cloud/DNN_COMPONENT_TAXONOMY.md) — ML component detection taxonomy
- [`cloud/VISUALIZATION_PLAN.md`](cloud/VISUALIZATION_PLAN.md) — Texture projection + floor plans
- [`cloud/WEB_VIEWER_PLAN.md`](cloud/WEB_VIEWER_PLAN.md) — Interactive 3D web viewer
