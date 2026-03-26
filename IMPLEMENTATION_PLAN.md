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
                                              Phase 5 (Cloud Smoke Test) ← manual gate
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

---

## Phase 5: Cloud Integration Smoke Test

**Goal**: Manually verify that the scan package produced by Phase 4 is consumable by the cloud pipeline. This is not app code — it is a manual validation gate that de-risks everything downstream.

**Steps**:
1. Complete a room scan on-device and export the scan package (Phase 4 output)
2. Copy the scan directory off-device (via Xcode file transfer, AirDrop, or `idevice` tools)
3. Zip the package: `zip -r scan_test.zip scan_<timestamp>/`
4. Upload to GCS manually: `gsutil cp scan_test.zip gs://<bucket>/scans/smoke-test/`
5. Trigger the cloud processing pipeline manually (Cloud Run endpoint or Cloud Tasks enqueue)
6. Verify the pipeline accepts and processes the package without errors
7. Inspect cloud output: does it produce valid stitched results, object detections, and structured room data?

### Test Cases — Phase 5

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 5.1 | Cloud pipeline accepts scan package | Upload zipped scan to GCS, trigger processing | Pipeline starts without parse errors | No errors in Cloud Run logs during ingestion; job status transitions to "processing" |
| 5.2 | PLY mesh parsed by cloud | Inspect cloud pipeline mesh ingestion logs | Mesh loaded successfully | Vertex and face counts in cloud logs match metadata.json values |
| 5.3 | Keyframe images readable by cloud | Inspect cloud ORB/homography step logs | All JPEGs loaded and feature-extracted | No "failed to load image" errors; feature extraction runs on all keyframes |
| 5.4 | Depth maps consumed by cloud | Inspect depth map loading in pipeline | Depth maps loaded with correct format | Depth resolution and pixel format match `depth_format` in metadata.json |
| 5.5 | Camera poses used for stitching | Inspect homography/alignment logs | Camera transforms used for image registration | Stitching step references camera_transform values from per-frame JSONs |
| 5.6 | Vertex AI object recognition runs | Check Vertex AI step output | Objects detected and classified | At least 1 classification returned (e.g., "floor", "wall", "cabinet") |
| 5.7 | Structured room data produced | Inspect final pipeline output | Room dimensions and components generated | Output includes floor area, wall area, ceiling height, detected components |
| 5.8 | Coordinate system alignment correct | Compare cloud output geometry to on-device mesh | Surfaces and dimensions are consistent | Cloud-reconstructed room dimensions within ±10% of on-device mesh bounding box |

> **Ship gate**: Do not proceed to Phase 6 until the cloud pipeline successfully processes at least one real scan package. If it fails, fix the export format (Phase 4) before building the upload flow.

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
| 7.1 | Status polling works | After upload, poll status endpoint | Receives valid status response | Response contains `status` field with value in ["queued", "processing", "completed", "failed"] |
| 7.2 | Handles "processing" state | Check viewer while cloud is still processing | Shows "Processing your scan..." with spinner | Status message visible; viewer does not show empty/broken state |
| 7.3 | Handles "failed" state | Mock a failed processing response | Shows error with option to retry | Error message displayed; "Retry" button is functional |
| 7.4 | Structured room data displayed | Open result for a completed scan | Screen shows detected dimensions and components | Displays: room dimensions (sq ft, ceiling height, perimeter), detected components list (hardwood, carpet, baseboards, etc.), appliance labels with positions |
| 7.5 | Scan status reflects SCANNED_ROOMS.scan_status | Check viewer at various processing stages | Status label matches backend enum | Status shows one of: `uploading`, `processing`, `scan_ready`, `failed` — consistent with DB values |
| 7.6 | FCM notification received on scan completion | Upload scan, wait for cloud processing to finish | Push notification arrives on device | Notification displays "Scan ready" message; tapping it opens the result viewer for the correct scan |
| 7.7 | FCM fallback to polling | Disable notifications, upload scan | App polls status endpoint as fallback | Polling fires every 5-10s; transitions to result view when status = `scan_ready` |

> **Alpha complete**: At this point the full loop works end-to-end — scan a room, upload, see structured results. The remaining phases add business context, resilience, and richer features.

---

## Phase 8: RFQ / Room Context Wiring

**Goal**: Wire real RFQ, floor, and room context into the scan flow. Replace hardcoded placeholders with proper selection UI and persist context through to metadata.json and cloud endpoints.

**Key files**: `RFQContext.swift`, `RFQSelectionView.swift`, `RoomLabelView.swift`

**Implementation**:
- Build `RFQSelectionView` to select an RFQ from the backend before scanning
- Build floor selection (select or create a floor within the RFQ)
- Prompt for room label after scan completes
- Capture room origin coordinates from the AR session's world transform
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
| 8.7 | metadata.json maps to SCANNED_ROOMS schema | Compare metadata.json keys to SCANNED_ROOMS columns | All DB-required fields are represented | Fields present for: `rfq_id`, `room_label`, `floor_id`, `scan_mesh_url` (path), `floor_plan_url` (if applicable), `origin_x`, `origin_y`, `rotation_deg`, `floor_area_sqft`, `wall_area_sqft`, `ceiling_height_ft`, `perimeter_linear_ft`, `detected_components` |
| 8.8 | RFQ-scoped endpoints used | Inspect all API calls during upload flow | URLs follow RFQ-centric pattern | All endpoints include `rfq_id` in path (e.g., `/api/rfqs/{rfq_id}/scans/...`); no orphaned `/api/scans/` calls |
| 8.9 | JWT token refresh on expiry | Set token TTL to 5s (test config), wait, then make API call | Token auto-refreshes before request | New token fetched via `User.getIDToken()`; API call succeeds with refreshed token; no 401 response |

---

## Phase 9: Upload Resilience + Network Hardening

**Goal**: Handle real-world network conditions — retry, resume, offline queuing, cellular warnings.

**Key files**: `CloudUploader.swift`

**Implementation**:
- Handle network interruptions with retry and exponential backoff
- Implement resumable uploads via GCS resumable upload protocol
- Queue scan packages to disk for offline upload via `NWPathMonitor`
- Warn on cellular data before uploading ~75MB
- Prevent concurrent uploads
- Register FCM token with the backend for push notifications

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

### 10d: Error Recovery & Edge Cases

| ID | Test Case | Steps | Expected Result | Pass Criteria |
|----|-----------|-------|-----------------|---------------|
| 10.16 | AR session interruption recovery | Receive a phone call during scanning, then return | AR session resumes or user is prompted | Session either auto-resumes or shows "Scan interrupted — Resume or Start Over" dialog |
| 10.17 | App backgrounding during scan | Press home button during scanning | Scan state is preserved or gracefully stopped | On return: either resumes scanning or shows saved partial scan with option to continue |
| 10.18 | Memory peak during full scan | Profile a complete scan-export cycle with Instruments | Peak memory stays within limits | Peak memory < 1GB on iPhone with 6GB RAM; no memory warnings fired |
| 10.19 | Graceful degradation on low storage | Fill device storage to < 200MB free, attempt export | User warned about low storage | Alert: "Not enough storage to export scan" before attempting write |
| 10.20 | No crashes on rapid state changes | Rapidly tap Start/Stop scan 10 times | App handles all transitions | No crashes; final state is consistent (either idle or scanning) |
| 10.21 | Accessibility — VoiceOver | Enable VoiceOver, navigate through all screens | All buttons and status elements are announced | Every interactive element has an accessibility label; state changes are announced |

---

## Key Risks & Mitigations

| Risk | Impact | Mitigation | When addressed |
|------|--------|------------|----------------|
| Memory pressure (60 keyframes × ~8MB) | App crash / termination | Convert to JPEG and release CVPixelBuffers immediately; cap at 60 keyframes | **Phase 3** (core behavior) |
| Cloud pipeline rejects scan format | Entire upload flow is wasted | Manual smoke test before building upload code | **Phase 5** (gate) |
| PLY coordinate system mismatch | Misaligned textures in cloud pipeline | Document and enforce ARKit Y-up right-handed; add coordinate system validation in cloud ingestion | Phase 4 + 5 |
| Upload size on cellular (~75MB) | Poor UX, data cost | Warn on cellular; implement resumable uploads; compress aggressively | Phase 9 |
| Cross-platform mesh format differences | Cloud pipeline breaks on Android scans | Both platforms export standardized PLY; add format validation tests on cloud side | Phase 4 |
| ARKit mesh resolution limits | Low-detail geometry for distant surfaces | Guide user to scan within 3-5m range; show mesh density indicator | Phase 10 |
| Firebase Auth token expiry during upload | Upload fails mid-stream with 401 | Auto-refresh JWT via `User.getIDToken(forceRefresh: true)` before each API call | Phase 8 |
| Offline scans lost | User scans with no connectivity and data is never uploaded | Queue scan packages to disk; auto-upload on connectivity restoration via NWPathMonitor | Phase 9 |
| metadata.json schema drift vs SCANNED_ROOMS | Cloud pipeline rejects or misparses scan data | Validate metadata.json against SCANNED_ROOMS column list; version the schema | Phase 8 |
