# RoomScanAlpha (Quoterra)

iOS + cloud room scanning system. Users scan rooms with LiDAR-equipped iPhones, the cloud processes PLY meshes into textured 3D models via OpenMVS, and contractors view results in a web viewer to generate renovation quotes.

## Quick Reference

### Deploy
```bash
# Processor (uses pinned base image with OpenMVS binaries)
cd cloud/processor
gcloud run deploy scan-processor --source . --region us-central1 --project roomscanalpha

# API
cd cloud/api
gcloud run deploy scan-api --source . --region us-central1 --project roomscanalpha

# Reprocess a scan
cd cloud/processor
./reprocess.sh <rfq_id> <scan_id|all>
```

### Test RFQ
- **RFQ**: `9b46fc88-ccbe-4414-8dd9-5aeace3681e0`
- **Viewer**: `https://scan-api-839349778883.us-central1.run.app/quote/9b46fc88-ccbe-4414-8dd9-5aeace3681e0`

## Architecture Overview

### Data Flow
```
iPhone (ARKit + LiDAR)
  → Capture mesh (PLY) + keyframes (JPEG, 0.7 quality) + depth maps + camera poses
  → Dense capture: 8° rotation, 0.3s interval, up to 300 frames → select best 180
  → Export scan.zip (~70-100MB)
  → Upload to GCS via signed URL (bypasses 32MB Cloud Run limit)
  → POST /api/rfqs/{rfq_id}/scans/complete → enqueues Cloud Tasks

Cloud Run: scan-processor (OIDC-protected, 8 vCPU / 16GB / concurrency=1)
  → Download scan.zip → parse PLY → compute room metrics (imperial)
  → OpenMVS TextureMesh: decimate to 50K faces (preview) + 300K (HD)
    → Produces OBJ + MTL + texture atlas JPG(s) per resolution level
  → WTA texture projection (fallback): per-surface JPEGs from annotation corners
  → Upload textured mesh + atlas to GCS
  → Write results to Cloud SQL → FCM notification to app
  → Supplemental merge: POST /process-supplemental
    → Downloads original + supplemental zips → merges meshes (voxel+proximity filter)
    → Merges keyframes (continuous numbering) → re-textures with all frames
    → Overwrites textured outputs in GCS

Cloud Run: scan-api (public)
  → Firebase Auth JWT on all endpoints
  → Serves contractor_view.html (Three.js OBJ viewer with HD toggle, MTLLoader for multi-atlas)
  → Generates signed GCS URLs for OBJ meshes
  → Proxies MTL + atlas files via /api/rfqs/{rfq_id}/scans/{scan_id}/files/{path}
  → Proxies to processor for coverage checks
```

### Services

| Service | URL | Auth | Purpose |
|---------|-----|------|---------|
| scan-api | `https://scan-api-839349778883.us-central1.run.app` | Firebase JWT | REST API + web viewer |
| scan-processor | `https://scan-processor-839349778883.us-central1.run.app` | OIDC (Cloud Tasks) | Scan processing + OpenMVS |
| Cloud SQL | `roomscanalpha:us-central1:roomscanalpha-db` | IAM | PostgreSQL (db: `quoterra`) |
| GCS | `gs://roomscanalpha-scans/` | IAM | Scan storage |
| Artifact Registry | `us-central1-docker.pkg.dev/roomscanalpha/cloud-run-source-deploy` | IAM | Container images |

### Texture Pipeline (Production)

**Primary: OpenMVS TextureMesh** (`pipeline/openmvs_texture.py`)
- Converts ARKit poses → COLMAP format (coordinate flip: `diag(1, -1, -1)`)
- Decimates mesh via `trimesh.simplify_quadric_decimation`
- Runs `InterfaceCOLMAP` + `TextureMesh` (binaries baked into container image)
- Preview: 50K faces, Standard: 300K faces
- Multi-atlas: 2+ texture atlases for meshes exceeding 8192×8192 atlas capacity
- Orange patches (RGB 255,165,0) = faces with no viable camera view
- Black patches = zero camera data or mesh geometry gaps
- Controlled by `USE_OPENMVS=true` env var (default)

**Fallback: WTA Surface Projection** (`pipeline/texture_projection.py`)
- Projects keyframe images onto flat surfaces derived from annotation corners
- Enhanced version: mesh depth correction, photometric pose refinement, dual keyframe sources
- Outputs per-surface JPEGs (wall_0.jpg, floor.jpg, ceiling.jpg)
- Used when OpenMVS fails or `USE_OPENMVS=false`

### Contractor Web Viewer

**Two rendering paths** (contractor_view.html):
1. **OBJ Mesh** (primary): Loads `textured.obj` via signed URL + MTL/atlas via file proxy (`MTLLoader` + `OBJLoader`). "HD On" toggles to `standard_textured.obj` with multi-atlas support. File proxy: `GET /api/rfqs/{rfq_id}/scans/{scan_id}/files/{path}` — maps `standard/` prefix to `standard_` prefixed GCS blobs.
2. **Quad Room** (fallback): Builds rectangular walls from annotation polygon, applies per-surface JPEGs

## iOS App

### Scan Flow (current working flow)
```
idle → selectingRFQ → projectOverview → scanReady → scanning
  → STOP (no pause!) → annotatingCorners → pause + saveWorldMap → labelingRoom
  → exporting → uploading → viewingResults → auto coverage check
  → if <90%: Re-scan Gaps → relocalizingForRescan → rescanningGaps → viewingResults
```

### Coverage Review Flow
After cloud processing completes, coverage is automatically checked via `POST /coverage`:
1. **Untextured faces** (orange): detected via degenerate UV area in OpenMVS output OBJ
2. **Mesh holes** (red): detected via ray-casting from mesh centroid — 10K fibonacci-sphere rays, missed rays → patches at bounding box exit
3. Coverage ratio is area-weighted (not face-count-based)
4. If coverage < 90%, user must re-scan gaps before proceeding
5. ARWorldMap saved after annotation enables relocalization for gap re-scan

### Gap Re-scan Flow
1. Load saved ARWorldMap → start relocalized AR session
2. Show RelocalizationView while tracking state is `.limited`
3. Once `.normal` → show GapRescanView with orange (untextured) + red (holes) overlays
4. User walks to highlighted areas, supplemental frames captured
5. On stop → package supplemental frames + mesh → upload to GCS → trigger merge
6. Cloud merges meshes (voxel 5cm + proximity 1cm filter) + frames → re-textures
7. **Cloud endpoints**: `GET .../supplemental-upload-url`, `POST .../supplemental`
8. **Processor endpoint**: `POST /process-supplemental` — merge + re-texture
9. **File proxy**: `GET .../files/{path}` — serves MTL/atlas for multi-material OBJ rendering

### Critical Constraint
**NEVER pause the AR session between scan capture and mesh export.** Pausing + resuming causes ARKit to re-initialize the world coordinate system, introducing 1-2ft systematic texture misalignment. The session must stay running from scan start through annotation completion.

### Frame Capture Settings
- Rotation threshold: 8° (dense angular coverage)
- Time interval: 0.3s minimum
- Max capture: 300 frames
- Selection target: 180 best frames (by sharpness + feature density)
- JPEG quality: 0.7 (saves ~30% memory vs 0.8)
- Auto-stop at cap with user alert

### Key Files
| File | Purpose |
|------|---------|
| `ContentView.swift` | Main scan flow state machine |
| `ScanViewModel.swift` | Scan state + frame/upload management |
| `ARSessionManager.swift` | AR session lifecycle, frame capture, world map save/load |
| `FrameCaptureManager.swift` | Keyframe selection thresholds + quality scoring |
| `ScanPackager.swift` | Export to scan.zip (PLY + keyframes + metadata) |
| `AuthManager.swift` | Firebase Auth (Google Sign-In, email/password) |
| `RelocalizationView.swift` | ARWorldMap relocalization overlay for gap re-scan |
| `GapRescanView.swift` | AR overlay with orange (untextured) + red (hole) patches |

## Coordinate Conventions
- **On-device**: meters (ARKit Y-up, right-handed: X=right, Y=up, Z=back)
- **Cloud output**: imperial feet/sqft (US construction convention)
- **Conversion**: once at output boundary in `compute_room_metrics()` — never mix
- **Camera transforms**: world-from-camera, 4×4 column-major
- **Image projection**: `py = -fy * cam_y / depth + cy` (negate Y for ARKit → image)

## Cloud Infrastructure

### Processor Resources
The scan-processor runs with 8 vCPUs, 16GB RAM, concurrency=1, always-allocated CPU, 900s timeout. This configuration is required for merged scan texturing (418+ images, 300K+ faces, ~4 min TextureMesh).

### Container Image Pinning
The scan-processor Dockerfile uses a **digest-pinned base image** containing OpenMVS binaries:
```dockerfile
FROM us-central1-docker.pkg.dev/roomscanalpha/cloud-run-source-deploy/scan-processor@sha256:1c33750e...
```
This is necessary because OpenMVS binaries (`TextureMesh`, `InterfaceCOLMAP`) + their shared libraries (libopencv, libboost) are baked into the container image and cannot be installed via pip or apt in the simple Dockerfile.

### GCS Scan Structure
```
gs://roomscanalpha-scans/scans/{rfq_id}/{scan_id}/
  ├── scan.zip                              # Uploaded from iOS
  ├── supplemental_scan.zip                 # Uploaded from iOS (gap re-scan)
  ├── mesh.ply                              # Uploaded by processor
  ├── textured.obj / .mtl / _material_00_map_Kd.jpg    # OpenMVS preview (50K faces)
  └── standard_textured.obj / .mtl / ...jpg             # OpenMVS HD (300K faces, may have multiple atlases)
```

## Dead Code & Known Issues

### Dead Code (iOS)
- `PanoramaSweepView.swift` — Panoramic sweep removed; replaced by denser walk-around capture. `.capturingPanorama` state kept for backward compat but never entered.
- `CoverageAudit.swift` — Surface-level coverage audit. Compiles but never called. Superseded by cloud-side coverage endpoint.
- `MeshCoverageAnalyzer.swift` — On-device mesh face coverage. Works but disabled (coverage review removed to fix texture alignment).
- `CoverageReviewView.swift` — Old text-based coverage display. Superseded by cloud-based coverage check + AR overlay.
- `RoomViewerView.swift` — Stub (5 lines). 3D viewer opens in Safari instead.

### Dead Code (Cloud)
- `pipeline/texture_projection.py` WTA path — Only runs as fallback when OpenMVS fails. Production uses OpenMVS.
- `models/roomformer_finetuned.pt` + `roomformer_pretrained.pt` — 316MB of RoomFormer DNN models baked into container. Never loaded. Phase 2 placeholder.
- `training_data/` — 500 density map images + COCO annotations. Phase 2 training data, unused.
- `_load_cameras()` + `_check_face_coverage()` in `main.py` — Old camera-viability coverage check. Superseded by UV-area + atlas + ray-cast coverage endpoint.

### Known Issues
- **ARFrame retention warnings** — ARSCNView delegate retains 11-13 frames during annotation. Caused by multiple ARSCNView instances sharing one session. Needs shared ARSCNView architecture (planned).
- **"Attempting to enable an already-enabled session"** — ARSCNView auto-runs the session when `scnView.session` is set, conflicting with `startSession()`. Harmless warning.
- **Supplemental merge deployed** — Full pipeline working: iOS packages/uploads supplemental data, cloud merges meshes + frames, re-textures with OpenMVS, viewer renders multi-atlas results via MTLLoader.
- **DB_PASS deployment** — Cloud Run services use plain env var for DB_PASS (not Secret Manager) after a secret reference broke during redeploy. Should be migrated back to Secret Manager.

## Remaining Docs (current)

| Document | Status | Scope |
|----------|--------|-------|
| `CLAUDE.md` | **Current** | This file — system architecture and conventions |
| `docs/SUPPLEMENTAL_SCAN_MERGE.md` | **Archived** | Supplemental scan capture, upload & merge plan (implemented) |
| `PLATFORM_ARCHITECTURE.md` | **Current** | Marketplace expansion plan (accounts, orgs, bids, search) |
| `cloud/processor/TEXTURE_PIPELINE.md` | **Current** | OpenMVS A/B test results, decimation findings |
| `cloud/DNN_COMPONENT_TAXONOMY.md` | **Future** | DNN detection classes (Phase 2, not implemented) |
| `cloud/README.md` | **Current** | Cloud operations guide |
| `docs/deprecated/` | **Archived** | 10 old planning docs moved here — do not reference |
