# RoomScanAlpha — Implementation Plan

## Context

RoomScanAlpha is one of two companion apps (iOS + Android/ARCore) for scanning rooms using LiDAR. The iOS app captures room geometry and camera keyframes, uploads them to Google Cloud (GCS + Cloud Run), where ORB/homography stitching and Vertex AI object recognition (hardwood floors, baseboards, shoe molding, cabinets, appliances, etc.) are performed server-side. Both platforms share the same cloud pipeline. This plan covers the iOS app only.

**Key architectural decision**: All heavy CV processing (ORB, homography, stitching, texture atlas generation) happens in the cloud — NOT on-device. The iOS app's job is to capture high-quality mesh + keyframes and upload them.

**Integration requirements**: The iOS app must authenticate via Firebase Auth (JWT), upload scan packages to GCS using signed URLs (not through the REST API), and associate every scan with an RFQ context. Push notifications via Firebase Cloud Messaging (FCM) are used to notify the app when cloud processing completes.

---

## Upload Format

Each scan uploads ~75MB:
- **Keyframes**: 30-60 JPEG images selected by translation/rotation thresholds
- **Mesh**: PLY file with vertices, faces, normals, and per-face classifications (wall, floor, ceiling, etc.)
- **Metadata JSON**: Camera intrinsics, per-keyframe camera pose (4x4 transform), depth map references, device info, timestamps, RFQ context (rfq_id, floor_id, room_label, room origin coordinates)

---

## Target File Structure

```
RoomScanAlpha/
├── Package.swift                        (Firebase + GCS SDK dependencies via SPM)
├── RoomScanAlpha/
│   ├── RoomScanAlphaApp.swift           (modify: inject ScanViewModel)
│   ├── ContentView.swift                (modify: state-driven UI)
│   ├── Info.plist                       (new: camera/AR permissions)
│   │
│   ├── Models/
│   │   ├── ScanState.swift              (enum: idle/scanning/processing/uploading/viewing)
│   │   ├── CapturedFrame.swift          (keyframe data: image, pose, intrinsics, depth)
│   │   ├── RoomMesh.swift               (vertices, faces, normals, classifications)
│   │   └── RFQContext.swift             (rfq_id, floor_id, room_label, origin coordinates)
│   │
│   ├── ViewModels/
│   │   └── ScanViewModel.swift          (orchestrates scan lifecycle + upload)
│   │
│   ├── Views/
│   │   ├── RFQSelectionView.swift       (select RFQ + floor before scanning)
│   │   ├── RoomLabelView.swift          (tag room label after scan)
│   │   ├── ScanningView.swift           (SwiftUI wrapper for AR scanning)
│   │   ├── ARScanningView.swift         (UIViewRepresentable wrapping ARSCNView)
│   │   ├── ScanProgressOverlay.swift    (HUD: mesh coverage, keyframe count)
│   │   ├── ScanResultView.swift         (structured room data: dimensions, components, appliances)
│   │   └── ModelViewerView.swift        (SceneKit viewer for cloud-returned 3D model)
│   │
│   ├── AR/
│   │   ├── ARSessionManager.swift       (ARSession config + ARSessionDelegate)
│   │   ├── MeshExtractor.swift          (ARMeshAnchor → world-space vertices/faces/classifications)
│   │   └── FrameCaptureManager.swift    (keyframe selection + downsampling)
│   │
│   ├── Export/
│   │   ├── PLYExporter.swift            (mesh → PLY file)
│   │   ├── ScanPackager.swift           (bundle keyframes + mesh + metadata JSON)
│   │   ├── CloudUploader.swift          (signed URL upload to GCS, track progress)
│   │   └── AuthManager.swift           (Firebase Auth sign-in + JWT token management)
│   │
│   └── Assets.xcassets/
```

---

## Dependency & Sequencing

```
Phase 1 (Setup) ──→ Phase 2 (AR + Mesh) ──→ Phase 3 (Keyframes + Memory)
                                                    │
                                                    v
                                              Phase 4 (Export)
                                                    │
                                                    v
                                        Phase 5.1 (Cloud Stub Pipeline) ← infra setup
                                                    │
                                                    v
                                        Phase 5.2 (Cloud Smoke Test) ← manual gate
                                                    │
                                                    v
                                              Phase 6 (Upload — Happy Path)
                                                    │
                                                    v
                                              Phase 7 (Result Polling + Structured Data)
                                                    │
                                                    v
                                              Phase 8 (RFQ / Room Context Wiring)
                                                    │
                                                    v
                                              Phase 9 (Upload Resilience + Network Hardening)
                                                    │
                                                    v
                                              Phase 10 (3D Viewer, Multi-Room, Guidance, Polish)
```

Phases 1–7 form the alpha critical path. Phases 8–10 layer on business logic, resilience, and rich features.

---

## Phase 1: Project Setup & Permissions

**Goal**: Add ARKit framework, camera permissions, Firebase SDK (Auth + Cloud Messaging), GCS SDK, and verify it all compiles.

**Steps**:
1. Create `Info.plist` with `NSCameraUsageDescription`, `UIRequiredDeviceCapabilities` (arkit), and `UIBackgroundModes` (remote-notification)
2. Add dependencies via Swift Package Manager: Firebase (Auth, Cloud Messaging), Google Cloud Storage SDK
3. Add `ARKit` framework to linked frameworks
4. Configure Firebase at app launch (`FirebaseApp.configure()`)
5. Request notification permission and register for FCM push notifications
6. Check device capabilities at launch (`ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)`)

### Test Cases — Phase 1

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 1.1 | App compiles without errors | Build project via `Cmd+R` or `xcodebuild` | Build succeeds with 0 errors | Exit code 0, "BUILD SUCCEEDED" in output |
| 1.2 | Camera permission dialog appears | Launch app on physical device for the first time | iOS presents camera usage permission alert | Alert displays with text from `NSCameraUsageDescription` |
| 1.3 | LiDAR capability detection — supported device | Run app on iPhone 12 Pro or newer Pro model | Console logs "LiDAR supported: true" | `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)` returns `true` |
| 1.4 | LiDAR capability detection — unsupported device | Run app on iPhone without LiDAR (e.g., iPhone SE, simulator) | App shows user-facing error message: "This app requires a LiDAR-equipped device" | Error view is displayed, scan button is disabled |
| 1.5 | ARKit framework linked | Inspect linked frameworks in build settings | ARKit.framework is present | `import ARKit` compiles without "No such module" error |
| 1.6 | Info.plist keys present | Read generated Info.plist at runtime | Required keys exist | `Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription")` is non-nil |
| 1.7 | Firebase SDK initializes | Launch app | Firebase configures without error | `FirebaseApp.configure()` completes; console shows "Firebase initialized" |
| 1.8 | FCM notification permission requested | Launch app for first time | iOS presents notification permission prompt | `UNUserNotificationCenter` authorization status changes to `.authorized` or `.denied` |
| 1.9 | FCM token registered | Grant notification permission, check console | Device token is generated | `Messaging.messaging().token` returns a non-nil string |

> **CI workflow**: `tests.yml` — Build step covers `1.1` (compile verification). Tests `1.2`–`1.9` are device/runtime-only — no workflow changes needed for this phase.

---

## Phase 2: AR Session + Live Mesh Visualization

**Goal**: Launch AR session with LiDAR mesh reconstruction, render wireframe in real time. No business logic — pure capture UX.

**Key files**: `ARSessionManager.swift`, `MeshExtractor.swift`, `ARScanningView.swift`, `ScanningView.swift`, `ScanViewModel.swift`, `ScanState.swift`

**ARSessionManager** configures:
```swift
let config = ARWorldTrackingConfiguration()
config.sceneReconstruction = .meshWithClassification
config.frameSemantics.insert(.sceneDepth)
session.run(config)
```

**MeshExtractor** converts `ARMeshAnchor.geometry`:
- Vertices: multiply by `meshAnchor.transform` → world space
- Faces: triplets of UInt32 indices
- Classifications: per-face labels (wall, floor, ceiling, table, seat, door, window)

**ARScanningView** (`UIViewRepresentable` wrapping `ARSCNView`):
- Renders mesh as wireframe overlay (`SCNMaterial.fillMode = .lines`)
- Color-codes by classification (walls = blue, floor = green, ceiling = yellow)

**ContentView** switches on `ScanState`: idle → "Start Scan" button, scanning → AR view + overlay, etc.

> **Alpha simplification**: No RFQ/floor selection gates the scan. A hardcoded or text-input placeholder for `rfq_id` / `floor_id` is sufficient until Phase 8.

### Test Cases — Phase 2

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 2.1 | AR session starts successfully | Tap "Start Scan" on LiDAR device | Camera feed appears with AR overlay | `ARSession` state is `.running`, no `ARSessionDelegate` error callbacks fired |
| 2.2 | Mesh anchors received | Point device at walls/floor for 5 seconds | `session(_:didAdd:)` delegate called with `ARMeshAnchor` objects | At least 1 `ARMeshAnchor` received within 5 seconds |
| 2.3 | Wireframe renders in real time | Slowly pan device across a room | Wireframe overlay appears on surfaces and grows as new areas are scanned | Wireframe geometry visible within 3 seconds of pointing at a surface |
| 2.4 | Mesh vertex world-space transform | Extract vertices from an `ARMeshAnchor`, apply anchor transform | Vertices align with real-world positions | Vertex positions are within ±0.05m of expected world coordinates (verified by placing device at a known position) |
| 2.5 | Classification color coding | Point at floor, wall, and ceiling | Wireframe colors differ by surface type | Floor = green, walls = blue, ceiling = yellow (visually verified) |
| 2.6 | Mesh triangle count grows | Scan for 30 seconds across multiple surfaces | Triangle count in overlay HUD increases monotonically | Triangle count > 1,000 after 30 seconds in a typical room |
| 2.7 | Stop scan freezes session | Tap "Stop Scan" | AR session pauses, wireframe freezes in place | `ARSession.pause()` called, no new mesh anchor updates received |
| 2.8 | State transitions | Navigate idle → scanning → idle | UI correctly reflects each state | "Start Scan" button visible in idle, AR view visible in scanning, button reappears after stop |
| 2.9 | Frame rate during scanning | Monitor FPS during active scanning | App maintains usable frame rate | Render loop stays ≥ 30 FPS (measured via Xcode GPU debugger or `CADisplayLink`) |
| 2.10 | Scene depth data available | Check `ARFrame.sceneDepth` during scanning | Depth data is non-nil | `frame.sceneDepth?.depthMap` returns a valid `CVPixelBuffer` with format `kCVPixelFormatType_DepthFloat32` |

> **CI workflow**: `tests.yml` — `MeshExtractorTests` covers `2.5` (classification color mapping) and `ScanViewModelTests` covers `2.6` (mesh stats) and `2.8` (state transitions). Tests `2.1`–`2.4`, `2.7`, `2.9`–`2.10` require LiDAR hardware and are device-only.

---

## Phase 3: Keyframe Capture + Memory Management

**Goal**: During scanning, intelligently select and store keyframes with camera metadata. Convert to JPEG in-flight and release CVPixelBuffers immediately to stay within memory limits.

**Key files**: `FrameCaptureManager.swift`, `CapturedFrame.swift`

**Keyframe selection criteria**:
- Translation threshold: camera moved ≥0.15m from last keyframe
- Rotation threshold: camera rotated ≥15°
- Minimum interval: ≥0.5s between captures
- Target: 30-60 keyframes for a typical room

**CapturedFrame** stores:
- `CVPixelBuffer` (capturedImage, YCbCr format) — converted to JPEG `Data` immediately, then buffer released
- `CVPixelBuffer` (depth map, Float32) — retained as raw bytes, original buffer released
- `simd_float3x3` camera intrinsics
- `simd_float4x4` camera transform (world pose)
- `TimeInterval` timestamp

> **Critical**: Memory is the #1 crash risk (60 keyframes × ~8MB = ~480MB of raw buffers). `FrameCaptureManager` must convert each keyframe to JPEG `Data` and release the `CVPixelBuffer` in the same capture callback. Do not defer this to export.

**ScanProgressOverlay** shows keyframe count, mesh triangle count, and scanning guidance.

### Test Cases — Phase 3

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 3.1 | Keyframe captured on translation | Hold device still for 3s, then move 0.2m sideways | Keyframe count increments by 1 after movement | Counter goes from N to N+1 after ≥0.15m translation |
| 3.2 | Keyframe captured on rotation | Hold device still, then rotate 20° | Keyframe count increments by 1 after rotation | Counter increments after ≥15° rotation change |
| 3.3 | No keyframe when stationary | Hold device completely still for 10 seconds | Keyframe count does not increment | Counter remains at N for full 10 seconds (after initial capture) |
| 3.4 | Minimum interval enforced | Shake device rapidly (many small movements) | Keyframes captured no faster than 1 per 0.5 seconds | Time delta between consecutive keyframe timestamps ≥ 0.5s |
| 3.5 | Keyframe count in target range | Scan a typical room (~4m × 4m), walking perimeter once | 30-60 keyframes captured | `capturedFrames.count` is between 30 and 60 |
| 3.6 | Camera intrinsics stored | Inspect a captured keyframe's intrinsics | fx, fy, cx, cy are reasonable values | fx and fy > 500 (pixels), cx ≈ image_width/2, cy ≈ image_height/2 |
| 3.7 | Camera transform stored | Inspect a captured keyframe's transform | 4x4 matrix with valid rotation and translation | Rotation component is orthonormal (det ≈ 1.0), translation values are in meters |
| 3.8 | Pixel buffer format correct | Check `CVPixelBufferGetPixelFormatType` on captured image | YCbCr biplanar format | Format equals `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` |
| 3.9 | Depth map stored with keyframe | Check depth map on a captured keyframe | Non-nil depth buffer | `capturedFrame.depthMap` is non-nil, pixel format is `kCVPixelFormatType_DepthFloat32` |
| 3.10 | Overlay displays keyframe count | Observe HUD during scanning | Counter updates in real time | Displayed count matches `capturedFrames.count` within 0.5s |
| 3.11 | Memory stays bounded during scan | Monitor memory usage during a 60-second scan | App memory stays within acceptable limits | Total memory usage < 500MB (measured via Xcode Memory Gauge); no memory warnings fired |
| 3.12 | CVPixelBuffers released after JPEG conversion | Monitor memory per-keyframe | Memory does not grow linearly with keyframe count | Memory delta per keyframe < 0.5MB (JPEG data only, not raw buffer) |
| 3.13 | Keyframe spatial coverage | Log all keyframe camera positions after scan | Positions span the scanned area | Bounding box of keyframe positions covers ≥ 80% of the room's footprint |

> **CI workflow**: `tests.yml` — `FrameCaptureManagerTests` covers `3.1`–`3.5` (threshold constants and cap). `CapturedFrameTests` covers `3.6`–`3.9` (intrinsics, transform, depth storage), `3.11`–`3.12` (memory model — Data not CVPixelBuffer). Tests `3.3`, `3.5`, `3.10`, `3.13` require device AR session and are manual-only.
>
> **Efficiency note**: `FrameCaptureManagerTests` currently uses `Mirror` to verify private threshold constants — this is fragile and breaks on renames. Expose thresholds as a `static let configuration` struct or `internal` constants so tests verify behavior, not implementation.

---

## Phase 4: Export & Packaging

**Goal**: Convert captured data into uploadable format (JPEG keyframes + PLY mesh + metadata JSON). Export runs on a background thread.

**Key files**: `PLYExporter.swift`, `ScanPackager.swift`

**PLYExporter** writes ASCII or binary PLY with vertex positions, normals, face indices, and classification labels.

**ScanPackager** creates:
```
scan_<timestamp>/
├── mesh.ply
├── metadata.json
├── keyframes/
│   ├── frame_000.jpg
│   ├── frame_000.json
│   └── ...
└── depth/
    ├── frame_000.depth
    └── ...
```

**metadata.json** schema:
```json
{
  "device": "iPhone 15 Pro",
  "ios_version": "17.4",
  "scan_duration_seconds": 45.2,
  "camera_intrinsics": { "fx": 1234.5, "fy": 1234.5, "cx": 960, "cy": 540 },
  "image_resolution": { "width": 1920, "height": 1440 },
  "depth_format": { "pixel_format": "kCVPixelFormatType_DepthFloat32", "width": 256, "height": 192, "byte_order": "little_endian" },
  "keyframe_count": 34,
  "mesh_vertex_count": 12450,
  "mesh_face_count": 24300,
  "keyframes": [
    {
      "index": 0,
      "filename": "frame_000.jpg",
      "depth_filename": "frame_000.depth",
      "timestamp": 1234567890.123,
      "camera_transform": [ ]
    }
  ]
}
```

> **Note**: RFQ context fields (`rfq_id`, `floor_id`, `room_label`, `origin_x`, `origin_y`, `rotation_deg`) are added to the schema in Phase 8. For now, metadata.json captures device and scan data only.

### Test Cases — Phase 4

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 4.1 | PLY file is valid | Export mesh, open `mesh.ply` in MeshLab or similar | Mesh renders correctly | MeshLab opens file without parse errors; vertex/face counts match header |
| 4.2 | PLY vertex count matches mesh | Compare PLY header vertex count to `RoomMesh.vertices.count` | Counts are equal | `ply_vertex_count == mesh.vertices.count` |
| 4.3 | PLY face count matches mesh | Compare PLY header face count to `RoomMesh.faces.count / 3` | Counts are equal | `ply_face_count == mesh.faces.count / 3` |
| 4.4 | PLY coordinates are Y-up right-handed | Export mesh of a known flat floor | Floor vertices have approximately equal Y values | Y variance across floor vertices < 0.05m; Y value is near 0 (ground plane) |
| 4.5 | PLY includes classification data | Parse PLY and check classification property | Each face has a classification label | Classification values are valid integers mapping to ARMeshClassification cases |
| 4.6 | JPEG keyframes are valid images | Open each `frame_NNN.jpg` | Images display correctly | `UIImage(contentsOfFile: path)` is non-nil for all frames; image dimensions match `image_resolution` in metadata |
| 4.7 | JPEG quality is sufficient | Check file size and visual quality of exported JPEGs | Images are clear with visible room detail | JPEG file size ≥ 100KB per frame (at ~0.8 quality); no visible blocking artifacts at 100% zoom |
| 4.8 | Per-frame JSON contains valid pose | Parse `frame_000.json` | Contains 16-element camera_transform array | Array has exactly 16 float values; rotation submatrix is orthonormal (column dot products ≈ 0, magnitudes ≈ 1) |
| 4.9 | metadata.json is valid JSON | Parse `metadata.json` with `JSONSerialization` | Parses without error | All required keys present: device, ios_version, camera_intrinsics, keyframe_count, mesh_vertex_count, mesh_face_count, keyframes array |
| 4.10 | metadata.json keyframe count matches files | Count JPEG files in `keyframes/` directory | Count equals `keyframe_count` field | `directory_file_count == metadata.keyframe_count` |
| 4.11 | Depth maps exported | Check `depth/` directory | One `.depth` file per keyframe | File count matches keyframe count; each file size > 0 bytes |
| 4.12 | Package directory structure correct | List contents of `scan_<timestamp>/` | All expected subdirectories and files present | `mesh.ply`, `metadata.json`, `keyframes/`, `depth/` all exist |
| 4.13 | Export completes within timeout | Time the export process | Export finishes in reasonable time | Export completes in < 30 seconds for a 40-keyframe scan |
| 4.14 | Package total size in expected range | Check total size of scan directory | Size is ~50-100MB | Total size between 30MB and 150MB for a typical room scan |
| 4.15 | Export runs on background thread | Trigger export, interact with UI during processing | UI remains responsive | Main thread is not blocked; UI animations do not stutter (verified via Xcode Thread Checker) |
| 4.16 | Depth map format documented in metadata | Check metadata.json for depth format spec | Depth encoding details present | `depth_format` field specifies pixel format, resolution, and byte order (matching cloud pipeline's expected input) |
| 4.17 | Scan quality validation before export | Complete a scan with <10 keyframes and minimal mesh | App warns scan quality is insufficient | Warning displayed: "Scan may be incomplete"; user can retry or proceed; minimum thresholds: ≥15 keyframes, ≥500 mesh faces |

> **CI workflow**: `tests.yml` — `PLYExporterTests` covers `4.1`–`4.5` (PLY format, header, classification). `ScanPackagerTests` covers `4.6`, `4.8`–`4.12`, `4.14`, `4.16` (JPEG export, metadata JSON schema, directory structure, depth format). `ScanViewModelTests` covers `4.17` (quality thresholds). Tests `4.7` (visual JPEG quality) and `4.13` (export timeout on real data) are device-only.
>
> **Efficiency note**: `PLYExporter` and `MeshExtractor` both independently implement the anchor-to-world-space vertex transform. Have `PLYExporter` call `MeshExtractor.worldSpaceVertices()` (and add a matching `worldSpaceNormals()`) to eliminate the duplicate and maintain a single source of truth for coordinate transforms.

---

## Phase 5.1: Cloud Stub Pipeline Setup

**Goal**: Stand up the minimum cloud infrastructure needed to accept, validate, and process a scan package from the iOS app. This is a stub processor — it validates the scan format and writes mock structured data to the database, without full CV/stitching or Vertex AI. This de-risks Phase 5.2 and unblocks Phase 7 (Upload) development.

**Infrastructure to provision**:

| Component | What to do |
|-----------|-----------|
| **GCS Bucket** | Create `gs://roomscanalpha-scans/` (or use existing Firebase Storage bucket) with a `scans/` prefix for uploads |
| **Cloud SQL PostgreSQL** | Provision a `db-f1-micro` instance; create the `quoterra` database; run the `SCANNED_ROOMS` + `RFQS` table migrations from the Miro DB schema |
| **Cloud Run REST API** | Deploy a minimal Python/Node service with 3 endpoints: signed URL generation, upload-complete webhook, and status polling |
| **Cloud Tasks Queue** | Create a `scan-processing` queue in the same region as Cloud Run |
| **Cloud Run Scan Processor (stub)** | Deploy a minimal service that: unzips the package, validates PLY/JPEG/metadata structure, writes mock room data to `SCANNED_ROOMS`, and sets status to `scan_ready` |

**Cloud Run REST API endpoints** (stub):
```
GET  /api/rfqs/{rfq_id}/scans/upload-url
  → Generates a GCS signed URL (15 min TTL) for direct upload
  → Returns { "signed_url": "...", "scan_id": "uuid" }
  → Requires: Authorization: Bearer <JWT>

POST /api/rfqs/{rfq_id}/scans/complete
  → Enqueues a Cloud Tasks job for the scan processor
  → Inserts SCANNED_ROOMS row with status = "processing"
  → Returns { "scan_id": "uuid", "status": "queued" }

GET  /api/rfqs/{rfq_id}/scans/{scan_id}/status
  → Returns current scan_status from SCANNED_ROOMS
  → Returns { "status": "processing" | "scan_ready" | "failed", ... }
```

**Cloud Run Scan Processor (stub) logic**:
```
1. Download zip from GCS
2. Unzip and validate structure (reject with scan_status = "failed" + error message if any check fails):
   - mesh.ply exists and has valid PLY header (element vertex N, element face M)
   - metadata.json is valid JSON with all required keys
   - keyframes/ contains N files matching metadata.keyframe_count
   - depth/ contains N .depth files matching keyframe count
3. Validate file contents:
   - Each frame_NNN.jpg starts with JPEG SOI marker (0xFFD8) and has size > 0
   - Each frame_NNN.json is valid JSON containing a 16-element camera_transform array
   - Each depth file has size > 0
   - PLY vertex/face counts in header match metadata mesh_vertex_count / mesh_face_count
4. Parse PLY vertices and compute bounding box (min/max x, y, z extents in meters)
5. Parse metadata.json: extract device info, keyframe_count, mesh counts
6. Write MOCK room data to SCANNED_ROOMS:
   - floor_area_sqft = 150.0 (hardcoded)
   - wall_area_sqft = 400.0
   - ceiling_height_ft = 8.0
   - perimeter_linear_ft = 50.0
   - detected_components = '["wall", "floor", "ceiling"]'
   - scan_mesh_url = GCS path to uploaded zip
   - scan_dimensions = { "bbox_x": ..., "bbox_y": ..., "bbox_z": ... } (from step 4)
   - scan_status = "scan_ready"
7. Send FCM push notification to the device (scan_id + status in payload)
```

**SQL schema** (minimum for stub — from Miro DB diagrams):
```sql
CREATE TABLE rfqs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    homeowner_account_id UUID,
    property_id UUID,
    job_category_id UUID,
    description TEXT,
    status VARCHAR(50) DEFAULT 'scan_pending',
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE scanned_rooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rfq_id UUID REFERENCES rfqs(id),
    room_label VARCHAR(100),
    floor_id UUID,
    scan_status VARCHAR(50) DEFAULT 'processing',
    scan_mesh_url TEXT,
    floor_plan_url TEXT,
    origin_x FLOAT,
    origin_y FLOAT,
    rotation_deg FLOAT,
    floor_area_sqft FLOAT,
    wall_area_sqft FLOAT,
    ceiling_height_ft FLOAT,
    perimeter_linear_ft FLOAT,
    detected_components JSONB,
    scan_dimensions JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);
```

**Steps**:
1. Create GCS bucket with appropriate IAM permissions for signed URL generation
2. Provision Cloud SQL PostgreSQL instance and run the schema above
3. Deploy Cloud Run REST API with the 3 endpoints (signed URLs, upload-complete, status)
4. Create Cloud Tasks queue (`scan-processing`) and configure it to call the Scan Processor
5. Deploy Cloud Run Scan Processor stub with validation + mock data logic
6. Insert a test RFQ row: `INSERT INTO rfqs (id, status) VALUES ('test-rfq-001', 'scan_pending')`
7. Verify the full flow manually: signed URL → upload → enqueue → process → scan_ready

> **Efficiency note**: The Cloud Run REST API and Scan Processor both need a DB connection helper. Extract a shared `cloud/shared/db.py` module rather than duplicating `get_db_connection()` in both services — prevents config drift as connection settings evolve.

### Test Cases — Phase 5.1

> Tests 5.1.1–5.1.17 run in CI via GitHub Actions against the deployed stub. Tests 5.1.18–5.1.21 validate the SQL schema and can run against a local PostgreSQL instance in CI.

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 5.1.1 | GCS bucket exists and is accessible | `gsutil ls gs://roomscanalpha-scans/` | Bucket listed without permission error | Exit code 0; bucket URL returned |
| 5.1.2 | Signed URL endpoint returns valid URL | `curl -H "Authorization: Bearer <JWT>" GET /api/rfqs/test-rfq-001/scans/upload-url` | JSON response with signed_url and scan_id | HTTP 200; `signed_url` starts with `https://storage.googleapis.com/`; `scan_id` is a valid UUID |
| 5.1.3 | Signed URL accepts file upload | Upload a test zip to the signed URL via `curl -X PUT` | File appears in GCS bucket | HTTP 200; `gsutil ls` shows the uploaded file at the expected path |
| 5.1.4 | Upload-complete endpoint enqueues job | `POST /api/rfqs/test-rfq-001/scans/complete` with scan_id | Cloud Tasks job created; SCANNED_ROOMS row inserted | HTTP 200; response contains `status: "queued"`; DB row has `scan_status = 'processing'` |
| 5.1.5 | Unauthenticated request rejected | Call signed URL endpoint with no Authorization header | HTTP 401 returned | Response status is 401; no signed URL in body |
| 5.1.6 | Invalid JWT rejected | Call signed URL endpoint with an expired or malformed JWT | HTTP 401 returned | Response status is 401; error message indicates invalid token |
| 5.1.7 | Stub processor validates PLY header | Upload a valid scan zip, trigger processing | Processor logs PLY vertex/face counts | Log output: `PLY valid: N vertices, M faces`; counts match metadata.json |
| 5.1.8 | Stub processor validates metadata.json | Upload a valid scan zip, trigger processing | Processor logs all required keys found | Log output: `metadata.json valid: N keyframes, device: iPhone` |
| 5.1.9 | Stub processor validates JPEG headers | Upload a valid scan zip, trigger processing | Processor verifies each keyframe is a valid JPEG | Log output: `N/N keyframes valid JPEG`; each file starts with SOI marker (0xFFD8) |
| 5.1.10 | Stub processor validates per-frame JSON | Upload a valid scan zip, trigger processing | Processor parses each frame JSON | Log output: `N/N frame JSONs valid`; each contains 16-element `camera_transform` array |
| 5.1.11 | Stub processor computes PLY bounding box | Upload a valid scan zip, trigger processing, query DB | `scan_dimensions` populated with bbox | `scan_dimensions` contains `bbox_x`, `bbox_y`, `bbox_z` with positive float values |
| 5.1.12 | Stub processor validates keyframe count | Upload a zip with mismatched keyframe count | Processor rejects the package | `scan_status` set to `failed`; error logged: `keyframe count mismatch` |
| 5.1.13 | Stub rejects zip with missing mesh.ply | Upload a zip that has no mesh.ply file | Processor rejects the package | `scan_status` set to `failed`; error logged: `missing mesh.ply` |
| 5.1.14 | Stub rejects invalid PLY header | Upload a zip where mesh.ply has a corrupted/invalid header | Processor rejects the package | `scan_status` set to `failed`; error logged: `invalid PLY header` |
| 5.1.15 | Stub rejects non-zip file | Upload a file that is not a valid zip archive | Processor rejects the package | `scan_status` set to `failed`; error logged: `invalid zip archive` |
| 5.1.16 | Stub processor writes mock room data | Upload a valid scan zip, trigger processing, query DB | SCANNED_ROOMS row has mock dimensions | `floor_area_sqft = 150.0`, `ceiling_height_ft = 8.0`, `scan_status = 'scan_ready'`, `detected_components` contains `["wall", "floor", "ceiling"]` |
| 5.1.17 | Stub sends FCM notification on completion | Upload a valid scan zip, trigger processing, check FCM delivery | Device receives push notification | Notification payload contains `scan_id` and `status: "scan_ready"`; delivered within 10s of processing completion |
| 5.1.18 | SCANNED_ROOMS schema matches Miro ERD | Run schema SQL, inspect table columns | All columns from Miro diagram exist | Table has columns: `id`, `rfq_id`, `room_label`, `floor_id`, `scan_status`, `scan_mesh_url`, `origin_x`, `origin_y`, `rotation_deg`, `floor_area_sqft`, `wall_area_sqft`, `ceiling_height_ft`, `perimeter_linear_ft`, `detected_components`, `scan_dimensions` |
| 5.1.19 | RFQS table exists with FK relationship | Insert an RFQ, insert a SCANNED_ROOMS row referencing it | FK constraint satisfied | Insert succeeds; `rfq_id` in SCANNED_ROOMS references valid RFQS row |
| 5.1.20 | SCANNED_ROOMS rejects invalid rfq_id | Insert SCANNED_ROOMS with non-existent rfq_id | FK violation | Insert fails with foreign key constraint error |
| 5.1.21 | Status endpoint returns correct status | Poll `/api/rfqs/test-rfq-001/scans/{scan_id}/status` after processing | Returns `scan_ready` | HTTP 200; response `status` equals `scan_ready`; response includes mock room dimensions and `scan_dimensions` bbox |

> **CI workflow**: Add new workflow `cloud-stub-tests.yml`. Tests `5.1.18`–`5.1.20` (SQL schema validation) can run against a PostgreSQL service container in GitHub Actions. Tests `5.1.1`–`5.1.17`, `5.1.21` (API/processor integration) require the deployed Cloud Run stub and should run as a post-deploy smoke test workflow triggered on push to the `cloud/` directory.

---

## Phase 5.2: Cloud Integration Smoke Test

**Goal**: Manually verify that a real scan package produced by Phase 4 (from an actual on-device room scan) is consumable by the stub cloud pipeline deployed in Phase 5.1. This is the validation gate before building the upload flow in the iOS app.

**Steps**:
1. Complete a room scan on-device and export the scan package (Phase 4 output)
2. Copy the scan directory off-device (via Xcode file transfer, AirDrop, or `idevice` tools)
3. Zip the package: `zip -r scan_test.zip scan_<timestamp>/`
4. Upload to GCS manually: `gsutil cp scan_test.zip gs://roomscanalpha-scans/scans/smoke-test/`
5. Trigger the cloud processing pipeline manually (call upload-complete endpoint)
6. Verify the stub processor accepts and validates the package without errors
7. Inspect cloud output: does it produce valid mock structured room data in the DB?

### Test Cases — Phase 5.2

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 5.2.1 | Cloud pipeline accepts real scan package | Upload zipped real scan to GCS, trigger processing | Pipeline starts without parse errors | No errors in Cloud Run logs during ingestion; job status transitions to "processing" |
| 5.2.2 | PLY mesh parsed by cloud | Inspect cloud pipeline mesh ingestion logs | Mesh loaded successfully | Vertex and face counts in cloud logs match metadata.json values |
| 5.2.3 | Keyframe images readable by cloud | Inspect cloud pipeline keyframe validation logs | All JPEGs found and readable | No "failed to load image" errors; file count matches metadata.json `keyframe_count` |
| 5.2.4 | Depth maps consumed by cloud | Inspect depth map validation in pipeline | Depth maps found with correct count | Depth file count matches keyframe count; sizes are non-zero |
| 5.2.5 | Camera poses present in per-frame JSON | Inspect per-frame JSON parsing logs | Camera transforms loaded | Each frame JSON contains 16-element `camera_transform` array |
| 5.2.6 | Structured room data produced | Query SCANNED_ROOMS after processing | Mock dimensions written to DB | `scan_status = 'scan_ready'`; `floor_area_sqft`, `ceiling_height_ft`, `detected_components` are non-null |
| 5.2.7 | Status endpoint reflects completion | Poll status endpoint after processing | Returns `scan_ready` | HTTP 200; status = `scan_ready` |
| 5.2.8 | Coordinate system preserved | Compare `scan_dimensions` bbox in SCANNED_ROOMS to on-device `RoomMesh` bounding box | Spatial extents are consistent | PLY bounding box dimensions (x, y, z extents in meters) from the stub match on-device mesh bounding box within ±10%; Y-up orientation confirmed (floor vertices cluster near min Y) |

> **Ship gate**: Do not proceed to Phase 6 until the stub pipeline successfully processes at least one real scan package. If it fails, fix the export format (Phase 4) or the stub processor (Phase 5.1) before building the upload flow.

> **CI workflow**: No automated CI — Phase 5.2 is entirely manual (on-device scan → manual upload → inspect logs/DB). Results documented in a test report.

---

## Phase 6: Cloud Upload — Happy Path

**Goal**: Upload the scan package to GCS via signed URLs with Firebase Auth and progress tracking. Wi-Fi only, no resilience — just prove the end-to-end flow works programmatically.

**Key files**: `CloudUploader.swift`, `AuthManager.swift`

**Implementation**:
- Authenticate via Firebase Auth (anonymous auth for prototype, email/password for production)
- Zip the scan directory (~50-100MB compressed)
- Request a signed upload URL from the Cloud Run REST API (JWT required)
- Upload zip directly to GCS using the signed URL (bypasses Cloud Run's 32MB request limit)
- Notify the API that the upload is complete (triggers Cloud Tasks job)
- Show upload progress bar in UI
- Refactor `ContentView` so `ScanViewModel` owns `ARSessionManager` — ContentView currently wires callbacks between them manually and pulls internal state (`sessionManager.frameCaptureManager.capturedFrames`). This coupling will compound as upload logic is added in this phase. Have `ScanViewModel` expose what views need, reducing ContentView to pure UI.

**Upload flow** (matches Quoterra architecture Flow 1):
```
App → Firebase Auth (get JWT)
App → REST API: GET /api/rfqs/{rfq_id}/scans/upload-url (with JWT)
App → GCS: PUT signed_url (upload zip directly)
App → REST API: POST /api/rfqs/{rfq_id}/scans/complete (notify backend)
Backend → Cloud Tasks Queue (enqueue scan processing job)
```

**Cloud endpoints** (RFQ-scoped):
- `GET /api/rfqs/{rfq_id}/scans/upload-url` → returns `{ "signed_url": "https://storage.googleapis.com/...", "scan_id": "abc123" }`
- `POST /api/rfqs/{rfq_id}/scans/complete` → returns `{ "scan_id": "abc123", "status": "queued" }`
- `GET /api/rfqs/{rfq_id}/scans/{scan_id}/status` → returns processing status
- `GET /api/rfqs/{rfq_id}/rooms` → returns processed room data

> **Alpha simplification**: Use a hardcoded or placeholder `rfq_id` in the URL path for now. Real RFQ selection is wired in Phase 8.

### Test Cases — Phase 6

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 6.1 | Zip file created | Export a scan, trigger packaging | `.zip` file created in temp directory | Zip file exists, size > 0, and is < 120% of uncompressed size |
| 6.2 | Zip contents match source | Unzip the created archive | All original files present and intact | Every file from the scan directory is in the zip; file sizes match originals |
| 6.3 | Firebase Auth sign-in before upload | Attempt upload without being signed in | App requires authentication first | Upload blocked; sign-in flow presented; `Auth.auth().currentUser` must be non-nil before upload proceeds |
| 6.4 | JWT token attached to API requests | Initiate upload, inspect outgoing HTTP headers | Authorization header present on all API calls | Every request to Cloud Run includes `Authorization: Bearer <valid_jwt>`; token is non-expired |
| 6.5 | Signed URL obtained before upload | Initiate upload, inspect network calls | App calls API for signed URL first | `GET /api/rfqs/{rfq_id}/scans/upload-url` returns 200 with a `signed_url` field; URL points to GCS |
| 6.6 | Upload goes directly to GCS via signed URL | Monitor network during upload | 75MB payload goes to `storage.googleapis.com`, NOT to Cloud Run | Upload PUT request targets GCS domain; Cloud Run receives only the small metadata requests |
| 6.7 | Upload starts and reports progress | Initiate upload on Wi-Fi | Progress bar appears and advances | Progress callback fires with values from 0.0 to 1.0; UI updates smoothly |
| 6.8 | Upload completes successfully | Upload a full scan on Wi-Fi | Server returns scan ID | HTTP response status is 200/201; response body contains valid `scan_id` string |
| 6.9 | Upload completion notification sent | After GCS upload finishes, inspect API call | App notifies backend that upload is complete | `POST /api/rfqs/{rfq_id}/scans/complete` called with scan metadata; response confirms Cloud Tasks job enqueued |
| 6.10 | Upload speed is acceptable | Time the upload of a ~75MB scan on Wi-Fi | Completes within reasonable time | Upload completes in < 60 seconds on a 50Mbps connection |
| 6.11 | Scan ID persisted locally | Complete an upload | Scan ID saved to local storage | `UserDefaults` or local DB contains the scan ID; survives app restart |
| 6.12 | Upload fails gracefully on no network | Enable airplane mode, attempt upload | User sees error message | Error alert displayed with "No network connection" message; app does not crash |

> **CI workflow**: Update `tests.yml` — add `CloudUploaderTests` for `6.1`–`6.2` (zip creation/validation can run on simulator with mock data). Tests `6.3`–`6.12` require Firebase Auth, network, and the deployed cloud stub — add to `cloud-stub-tests.yml` as integration tests, or test manually on device. The GitHub Actions secrets required by `cloud-stub-tests.yml` (`SCAN_API_BASE_URL`, `FIREBASE_PROJECT_ID`, `FIREBASE_API_KEY`, `GOOGLE_SERVICE_INFO_PLIST`) are configured in **Phase 9** — see "GitHub Actions secrets setup" in that phase.

---

## Phase 7: Result Polling + Structured Data Display

**Goal**: After upload, poll for processing status and display the structured room data returned by the cloud pipeline. No 3D viewer yet — just prove the full loop: scan → upload → process → see results.

**Key files**: `ScanResultView.swift`

**Implementation**:
- Poll `GET /api/rfqs/{rfq_id}/scans/{scan_id}/status` until status = `scan_ready`
- Display structured room data from `SCANNED_ROOMS`: detected dimensions (sq ft, ceiling height, perimeter), detected components (hardwood, carpet, baseboards, cabinets), and appliance labels with positions
- Track `scan_status` values consistent with backend: `uploading`, `processing`, `scan_ready`, `failed`
- Receive FCM push notification when scan processing completes ("scan_ready" status); fall back to polling if notifications are disabled

### Test Cases — Phase 7

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 7.1 | Status polling works | After upload, poll status endpoint | Receives valid status response | Response contains `status` field with value in ["queued", "processing", "scan_ready", "failed"] |
| 7.2 | Handles "processing" state | Check viewer while cloud is still processing | Shows "Processing your scan..." with spinner | Status message visible; viewer does not show empty/broken state |
| 7.3 | Handles "failed" state | Mock a failed processing response | Shows error with option to retry | Error message displayed; "Retry" button is functional |
| 7.4 | Structured room data displayed | Open result for a completed scan | Screen shows detected dimensions and components | Displays: room dimensions (sq ft, ceiling height, perimeter), detected components list (hardwood, carpet, baseboards, etc.), appliance labels with positions |
| 7.5 | Scan status reflects SCANNED_ROOMS.scan_status | Check viewer at various processing stages | Status label matches backend enum | Status shows one of: `uploading`, `processing`, `scan_ready`, `failed` — consistent with DB values |
| 7.6 | FCM notification received on scan completion | Upload scan, wait for cloud processing to finish | Push notification arrives on device | Notification displays "Scan ready" message; tapping it opens the result viewer for the correct scan |
| 7.7 | FCM fallback to polling | Disable notifications, upload scan | App polls status endpoint as fallback | Polling fires every 5-10s; transitions to result view when status = `scan_ready` |

> **CI workflow**: Update `tests.yml` — add `ScanResultViewTests` for `7.2`–`7.3` (state rendering with mock responses), `7.5` (status enum mapping). Tests `7.1`, `7.4`, `7.6`–`7.7` require the deployed cloud stub and a real upload — run via `cloud-stub-tests.yml` or manually on device.
>
> **Alpha complete**: At this point the full loop works end-to-end — scan a room, upload, see structured results. The remaining phases add business context, resilience, and richer features.

---

## Phase 8: RFQ / Room Context Wiring

**Goal**: Wire real RFQ, floor, and room context into the scan flow. Replace hardcoded placeholders with proper selection UI and persist context through to metadata.json and cloud endpoints.

**Key files**: `RFQContext.swift`, `RFQSelectionView.swift`, `RoomLabelView.swift`

**Unit convention** (enforced across all phases):
- **On-device geometry** (ARKit vertices, PLY mesh, scan_dimensions bbox, origin_x/y): always **meters** — ARKit's native unit
- **Cloud-computed room dimensions** (floor_area, wall_area, ceiling_height, perimeter): always **imperial (sq ft / ft)** — matches US construction/renovation conventions
- **metadata.json**: origin coordinates in meters, no conversion
- **ScanResultView**: display raw scan bbox in meters, room dimensions in feet — label units explicitly (e.g., "150 sq ft", "3.05 m")
- **Never mix**: do not convert meters to feet in metadata.json or PLY. Do not store cloud room dimensions in meters. Each layer owns its unit and labels it.

**Implementation**:
- Build `RFQSelectionView` to select an RFQ from the backend before scanning
- Build floor selection (select or create a floor within the RFQ)
- Prompt for room label after scan completes
- Capture room origin coordinates from the AR session's world transform (in meters)
- Add RFQ context fields to metadata.json: `rfq_id`, `floor_id`, `room_label`, `origin_x`, `origin_y`, `rotation_deg`
- Validate metadata.json maps to `SCANNED_ROOMS` schema

**Full metadata.json** schema (extending Phase 4):
```json
{
  "rfq_id": "uuid-of-rfq",
  "floor_id": "uuid-of-floor",
  "room_label": "Kitchen",
  "origin_x": 3.45,
  "origin_y": 1.22,
  "rotation_deg": 90.0,
  "device": "iPhone 15 Pro",
  "ios_version": "17.4",
  "scan_duration_seconds": 45.2,
  "camera_intrinsics": { "fx": 1234.5, "fy": 1234.5, "cx": 960, "cy": 540 },
  "image_resolution": { "width": 1920, "height": 1440 },
  "depth_format": { "pixel_format": "kCVPixelFormatType_DepthFloat32", "width": 256, "height": 192, "byte_order": "little_endian" },
  "keyframe_count": 34,
  "mesh_vertex_count": 12450,
  "mesh_face_count": 24300,
  "keyframes": [
    {
      "index": 0,
      "filename": "frame_000.jpg",
      "depth_filename": "frame_000.depth",
      "timestamp": 1234567890.123,
      "camera_transform": [ ]
    }
  ]
}
```

### Test Cases — Phase 8

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 8.1 | RFQ context required before scan | Tap "Start Scan" with no RFQ selected | App blocks scan start, prompts to select an RFQ | Scan button disabled or shows "Select an RFQ first"; AR session does not start |
| 8.2 | RFQ selection flow | Tap "Select RFQ", choose from list | RFQ ID is persisted in scan session | `scanViewModel.rfqId` is non-nil and matches selected RFQ |
| 8.3 | Floor selection before scan | After RFQ selection, prompt for floor | User can select or create a floor | `scanViewModel.floorId` is set before AR session starts |
| 8.4 | Room label assigned to scan | After stopping scan, prompt for room label | User enters label (e.g., "Kitchen") | `scanViewModel.roomLabel` is a non-empty string |
| 8.5 | Room origin coordinates captured | Stop scan, inspect session data | Room origin and rotation stored from AR world origin | `origin_x`, `origin_y`, `rotation_deg` are valid floats derived from the AR session's world transform |
| 8.6 | metadata.json includes RFQ context | Export scan, parse metadata.json | RFQ and room fields present | `rfq_id`, `floor_id`, `room_label`, `origin_x`, `origin_y`, `rotation_deg` are all present and non-null |
| 8.7 | metadata.json includes all app-side SCANNED_ROOMS inputs | Compare metadata.json keys to SCANNED_ROOMS columns the app is responsible for | All app-exported fields present | Fields present for: `rfq_id`, `room_label`, `floor_id`, `origin_x`, `origin_y`, `rotation_deg`. Note: `floor_area_sqft`, `wall_area_sqft`, `ceiling_height_ft`, `perimeter_linear_ft`, `detected_components` are cloud-computed — NOT expected in app metadata.json |
| 8.8 | RFQ-scoped endpoints used | Inspect all API calls during upload flow | URLs follow RFQ-centric pattern | All endpoints include `rfq_id` in path (e.g., `/api/rfqs/{rfq_id}/scans/...`); no orphaned `/api/scans/` calls |
| 8.9 | JWT token refresh on expiry | Set token TTL to 5s (test config), wait, then make API call | Token auto-refreshes before request | New token fetched via `User.getIDToken()`; API call succeeds with refreshed token; no 401 response |

> **CI workflow**: Update `tests.yml` — add `RFQContextTests` for `8.6`–`8.7` (metadata.json schema validation with mock RFQ context data). Tests `8.1`–`8.5` (UI selection flows) and `8.8`–`8.9` (live API + JWT) are device/integration tests — manual or via `cloud-stub-tests.yml`.

---

## Phase 9: Upload Resilience + Network Hardening + Cloud Security

**Goal**: Handle real-world network conditions — retry, resume, offline queuing, cellular warnings. Lock down Cloud Run services with OIDC authentication for service-to-service calls.

**Key files**: `CloudUploader.swift`, Cloud Run service configs

**Implementation**:
- Handle network interruptions with retry and exponential backoff
- Implement resumable uploads via GCS resumable upload protocol
- Queue scan packages to disk for offline upload via `NWPathMonitor`
- Warn on cellular data before uploading ~75MB
- Prevent concurrent uploads
- Register FCM token with the backend for push notifications
- **OIDC hardening**: Redeploy scan-processor with `--no-allow-unauthenticated`. Grant `roles/run.invoker` to the App Engine default SA (`roomscanalpha@appspot.gserviceaccount.com`) so Cloud Tasks can invoke the processor with OIDC tokens. This ensures only Cloud Tasks (via the REST API's enqueue step) can trigger scan processing — not arbitrary external requests.
- **GitHub Actions secrets for CI integration tests**: Configure the secrets required by `cloud-stub-tests.yml` (Phase 6 integration tests). Without these, the cloud integration test workflow cannot authenticate with Firebase or reach the Cloud Run API.

**OIDC hardening steps**:
1. Redeploy scan-processor: `gcloud run deploy scan-processor --no-allow-unauthenticated ...`
2. Grant invoker role: `gcloud run services add-iam-policy-binding scan-processor --member="serviceAccount:roomscanalpha@appspot.gserviceaccount.com" --role="roles/run.invoker"`
3. Verify Cloud Tasks job uses OIDC token with `service_account_email=roomscanalpha@appspot.gserviceaccount.com` (already configured in API code)
4. Test: direct `curl` to `/process` should return 403; Cloud Tasks invocation should succeed

**GitHub Actions secrets setup** (required for `cloud-stub-tests.yml`):

These secrets enable the Phase 6–7 cloud integration tests (`cloud-stub-tests.yml`) to run in CI. Set them in the GitHub repo under Settings → Secrets and variables → Actions, scoped to the `staging` environment:

1. `SCAN_API_BASE_URL` — Cloud Run REST API base URL (e.g. `https://scan-api-839349778883.us-central1.run.app`). Source: `gcloud run services describe scan-api --region=us-central1 --format='value(status.url)'`
2. `FIREBASE_PROJECT_ID` — GCP project ID (e.g. `roomscanalpha`). Source: Firebase Console → Project Settings → General
3. `FIREBASE_API_KEY` — Firebase Web API key for anonymous auth in CI. Source: Firebase Console → Project Settings → General → Web API Key
4. `GOOGLE_SERVICE_INFO_PLIST` — Base64-encoded `GoogleService-Info.plist` for the iOS app. Generate with: `base64 -i RoomScanAlpha/GoogleService-Info.plist | pbcopy`, then paste as the secret value. Source: Firebase Console → Project Settings → iOS app → download `GoogleService-Info.plist`

> **Security note**: Use a separate Firebase API key with restricted permissions for CI if possible. The `staging` environment in GitHub Actions should map to a staging GCP project or Firebase project to avoid polluting production data with test uploads.

### Test Cases — Phase 9

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 9.1 | Upload resumes after interruption | Start upload, toggle airplane mode briefly, then re-enable | Upload resumes from where it left off | Final uploaded byte count equals file size; no duplicate data sent (verified via GCS resumable upload offset) |
| 9.2 | Upload retry on transient failure | Mock a 503 response from server | App retries automatically | At least 1 retry attempt within 10 seconds; retry uses exponential backoff |
| 9.3 | Upload on cellular shows warning | Attempt upload while on cellular (no Wi-Fi) | App warns user about cellular data usage | Alert or confirmation dialog appears before upload proceeds |
| 9.4 | Concurrent upload prevention | Tap upload twice rapidly | Only one upload session active | Second tap is ignored or shows "upload already in progress" |
| 9.5 | Offline scan queued for later upload | Complete scan in airplane mode, re-enable network | Scan is persisted locally and uploads automatically | Scan package saved to disk; upload triggers within 30s of connectivity restoration; no data loss |
| 9.6 | Multiple queued scans upload sequentially | Complete 3 scans offline, re-enable network | All 3 upload in order | All 3 scans reach "uploaded" status; no concurrent uploads; order matches scan timestamps |
| 9.7 | Upload runs on background thread | Start upload, navigate to other screens | Upload continues in background | Upload progress continues; completion callback fires even if user navigated away |
| 9.8 | Processor rejects unauthenticated requests | `curl -X POST .../process` with no auth | HTTP 403 returned | Direct calls without OIDC token are rejected; only Cloud Tasks invocations succeed |
| 9.9 | Cloud Tasks invokes processor via OIDC | Enqueue a job via upload-complete endpoint, check processor logs | Processor receives and processes the request | Cloud Tasks attaches OIDC token; processor logs show successful processing; scan_status transitions to `scan_ready` |
| 9.10 | CI secrets configured and cloud-stub-tests pass | Run `cloud-stub-tests.yml` workflow manually via GitHub Actions | All Phase 6 integration tests (6.3–6.12) pass in CI | Workflow completes successfully; Firebase Auth works in CI; signed URL obtained; upload reaches GCS |

> **CI workflow**: Update `tests.yml` — add `UploadResilienceTests` for `9.2` (retry with mocked 503), `9.4` (concurrent upload prevention via state check). Tests `9.1`, `9.3`, `9.5`–`9.7` require network manipulation and device — manual-only. Tests `9.8`–`9.9` run against deployed cloud services. Test `9.10` validates that `cloud-stub-tests.yml` runs end-to-end after secrets are configured.

---

## Phase 10: 3D Viewer, Multi-Room, Guidance & Polish

**Goal**: Rich features and production readiness — 3D model viewer, multi-room scanning, scanning guidance, scan history, error recovery, and accessibility.

**Key files**: `ModelViewerView.swift`, `ScanResultView.swift`

### 10a: 3D Model Viewer

**Implementation**:
- Download textured 3D model (USDZ or glTF) when available from cloud results
- Display 3D model in SceneKit via `SCNView` with `allowsCameraControl = true` (orbit/pan/zoom)
- Or use QuickLook for USDZ preview as a simpler first pass

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 10.1 | Model downloads after processing | Wait for "completed" status, tap "View Result" | Model file downloads to device | File exists in local cache; file size > 0; format is USDZ or glTF |
| 10.2 | SceneKit renders model | Open downloaded model in viewer | 3D model appears on screen | `SCNView.scene` contains at least 1 geometry node; no rendering errors |
| 10.3 | Orbit camera control | Drag finger across the model viewer | Camera orbits around the model | Camera position changes; model remains centered |
| 10.4 | Pinch to zoom | Pinch gesture on model viewer | Camera zooms in/out | Camera field of view or distance changes proportionally |
| 10.5 | Pan gesture | Two-finger drag on model viewer | Camera pans | Camera target/position translates |
| 10.6 | Model geometry matches scan | Compare rendered model to the physical room | Walls, floor, ceiling are in correct positions | Visual inspection: room proportions match reality; walls meet at approximately 90° angles |
| 10.7 | Textures are visible | Inspect model surfaces | Surfaces show camera-captured textures, not blank/white | At least 80% of visible surfaces have non-uniform texture (not solid color) |
| 10.8 | Object labels displayed | Check for Vertex AI classification labels | Labels appear on detected objects | Labels for at least 3 object categories visible (e.g., "floor", "wall", "cabinet") |
| 10.9 | Model viewer performance | Rotate model continuously for 10 seconds | Smooth rendering | Frame rate ≥ 30 FPS during interaction (measured via Xcode) |

### 10b: Multi-Room Scanning

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 10.10 | Multi-room sequential scanning | Scan 3 rooms on the same floor without leaving the session | All 3 rooms captured with distinct labels and origins | 3 separate scan packages created, each with unique `room_label` and `origin_x/y`; all share the same `floor_id` |
| 10.11 | Multi-room scans associate to same RFQ | Complete multi-room session, inspect uploads | All scans reference the same RFQ | Every scan's `metadata.json` has identical `rfq_id`; backend creates 3 `SCANNED_ROOMS` rows under one RFQ |

### 10c: Scan History & Guidance

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 10.12 | Scan history persists | Complete 3 scans, force quit app, relaunch | All 3 scans appear in history | History list shows 3 entries with correct timestamps and statuses |
| 10.13 | Scan history shows correct status | View history with scans in various states | Each scan shows its current status | Statuses correctly show "uploaded", "processing", "completed", or "failed" |
| 10.14 | Scan history shows RFQ grouping | View scan history after multi-room session | Scans grouped by RFQ/property | History UI groups scans under their RFQ; shows room labels and per-room status |
| 10.15 | Scanning guidance appears | Start scanning and stay pointed at one wall | Guidance suggests looking at unscanned areas | Visual indicator (arrow or highlight) points toward unscanned regions after 10 seconds |

### 10d: Real Room Dimensions from PLY Geometry

**Goal**: Replace the stub processor's hardcoded mock room dimensions with real values computed from the classified PLY mesh.

**Current state**: The scan processor (Phase 5.1 stub) writes `floor_area_sqft = 150.0`, `wall_area_sqft = 400.0`, `ceiling_height_ft = 8.0`, `perimeter_linear_ft = 50.0` for every scan regardless of actual geometry. The bounding box (`scan_dimensions`) is already real — computed from PLY vertices.

**Implementation** (cloud/processor/main.py):
1. Parse PLY face classifications (already stored as `uchar classification` per face)
2. Compute **floor area**: sum triangle areas for faces with classification = floor (2). Convert m² → sq ft.
3. Compute **wall area**: sum triangle areas for faces with classification = wall (1). Convert m² → sq ft.
4. Compute **ceiling height**: (max Y of ceiling vertices) minus (min Y of floor vertices). Convert m → ft.
5. Compute **perimeter**: project floor-classified vertices onto XZ plane, compute convex hull perimeter. Convert m → ft.
6. **Detected components**: enumerate unique classifications present (wall, floor, ceiling, table, seat, window, door) instead of hardcoding `["wall", "floor", "ceiling"]`.

**Unit convention**: All geometry math in meters (PLY native). Convert to imperial only when writing to `SCANNED_ROOMS` fields (`_sqft`, `_ft`).

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 10d.1 | Floor area computed from mesh | Scan a ~10x12 ft room, check results | Floor area ≈ 120 sq ft | Computed value within ±20% of measured room area |
| 10d.2 | Ceiling height derived from mesh | Scan a standard 8ft ceiling room | Ceiling height ≈ 8 ft | Computed value within ±0.5 ft of actual ceiling height |
| 10d.3 | Wall area computed from mesh | Scan a room with 4 walls | Wall area is reasonable | Wall area > 0 and proportional to room perimeter × ceiling height |
| 10d.4 | Perimeter computed from floor boundary | Scan a rectangular room | Perimeter ≈ 2×(length + width) | Computed value within ±20% of measured perimeter |
| 10d.5 | Detected components reflect actual surfaces | Scan a room with visible floor, walls, ceiling | Components list matches scanned surfaces | `detected_components` contains at least the classifications present in the PLY (not hardcoded) |
| 10d.6 | Values differ between rooms | Scan two rooms of different sizes | Dimensions differ | floor_area, wall_area, ceiling_height, perimeter are different between the two scans |

### 10e: Export Performance

> **Efficiency note**: `PLYExporter` currently accumulates all vertices, normals, faces, and classifications as Swift arrays, then iterates them again to write binary data — roughly doubling peak memory during export. For large scans (50K+ vertices), switch to a two-pass streaming approach: first pass counts totals for the header, second pass writes binary bytes directly per-anchor without intermediate arrays.

### 10e: Error Recovery & Edge Cases

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 10.16 | AR session interruption recovery | Receive a phone call during scanning, then return | AR session resumes or user is prompted | Session either auto-resumes or shows "Scan interrupted — Resume or Start Over" dialog |
| 10.17 | App backgrounding during scan | Press home button during scanning | Scan state is preserved or gracefully stopped | On return: either resumes scanning or shows saved partial scan with option to continue |
| 10.18 | Memory peak during full scan | Profile a complete scan-export cycle with Instruments | Peak memory stays within limits | Peak memory < 1GB on iPhone with 6GB RAM; no memory warnings fired |
| 10.19 | Graceful degradation on low storage | Fill device storage to < 200MB free, attempt export | User warned about low storage | Alert: "Not enough storage to export scan" before attempting write |
| 10.20 | No crashes on rapid state changes | Rapidly tap Start/Stop scan 10 times | App handles all transitions | No crashes; final state is consistent (either idle or scanning) |
| 10.21 | Accessibility — VoiceOver | Enable VoiceOver, navigate through all screens | All buttons and status elements are announced | Every interactive element has an accessibility label; state changes are announced |

> **CI workflow**: Update `tests.yml` — add `AccessibilityTests` for `10.21` (verify accessibility labels exist on all interactive elements via `XCUIApplication` accessibility audit). All other Phase 10 tests (`10.1`–`10.20`) require device hardware (SceneKit rendering, multi-room AR, phone calls, storage manipulation) and are manual-only.

---

## Key Risks & Mitigations

| Risk | Impact | Mitigation | When addressed |
|------|--------|------------|----------------|
| Memory pressure (60 keyframes × ~8MB) | App crash / termination | Convert to JPEG and release CVPixelBuffers immediately; cap at 60 keyframes | **Phase 3** (core behavior) |
| Cloud pipeline rejects scan format | Entire upload flow is wasted | Stub pipeline validates format before full CV pipeline | **Phase 5.1** (stub) → **Phase 5.2** (gate) |
| PLY coordinate system mismatch | Misaligned textures in cloud pipeline | Document and enforce ARKit Y-up right-handed; add coordinate system validation in cloud ingestion | Phase 4 + 5.2 |
| Upload size on cellular (~75MB) | Poor UX, data cost | Warn on cellular; implement resumable uploads; compress aggressively | Phase 9 |
| Cross-platform mesh format differences | Cloud pipeline breaks on Android scans | Both platforms export standardized PLY; add format validation tests on cloud side | Phase 4 |
| ARKit mesh resolution limits | Low-detail geometry for distant surfaces | Guide user to scan within 3-5m range; show mesh density indicator | Phase 10 |
| Firebase Auth token expiry during upload | Upload fails mid-stream with 401 | Auto-refresh JWT via `User.getIDToken(forceRefresh: true)` before each API call | Phase 8 |
| Offline scans lost | User scans with no connectivity and data is never uploaded | Queue scan packages to disk; auto-upload on connectivity restoration via NWPathMonitor | Phase 9 |
| metadata.json schema drift vs SCANNED_ROOMS | Cloud pipeline rejects or misparses scan data | Validate metadata.json against SCANNED_ROOMS column list; version the schema | Phase 8 |

