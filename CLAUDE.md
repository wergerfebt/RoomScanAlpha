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

Cloud Run: scan-processor (OIDC-protected)
  → Download scan.zip → parse PLY → compute room metrics (imperial)
  → OpenMVS TextureMesh: decimate to 10K faces (preview) + full mesh (HD)
    → Produces OBJ + texture atlas JPG per resolution level
  → WTA texture projection (fallback): per-surface JPEGs from annotation corners
  → Upload textured mesh + atlas to GCS
  → Write results to Cloud SQL → FCM notification to app

Cloud Run: scan-api (public)
  → Firebase Auth JWT on all endpoints
  → Serves contractor_view.html (Three.js OBJ viewer with HD toggle)
  → Generates signed GCS URLs for meshes and textures
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
- Preview: 10K faces, Standard: full mesh
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
1. **OBJ Mesh** (primary): Loads `textured.obj` + texture atlas via `OBJLoader`. "HD On" toggles to `standard_textured.obj`
2. **Quad Room** (fallback): Builds rectangular walls from annotation polygon, applies per-surface JPEGs

## iOS App

### Scan Flow (current working flow)
```
idle → selectingRFQ → projectOverview → scanReady → scanning
  → STOP (no pause!) → annotatingCorners → pause → labelingRoom
  → exporting → uploading → viewingResults
```

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
| `ARSessionManager.swift` | AR session lifecycle, frame capture |
| `FrameCaptureManager.swift` | Keyframe selection thresholds + quality scoring |
| `ScanPackager.swift` | Export to scan.zip (PLY + keyframes + metadata) |
| `AuthManager.swift` | Firebase Auth (Google Sign-In, email/password) |
| `CoverageReviewView.swift` | Text-based coverage % display (disabled pending ARWorldMap approach) |

## Coordinate Conventions
- **On-device**: meters (ARKit Y-up, right-handed: X=right, Y=up, Z=back)
- **Cloud output**: imperial feet/sqft (US construction convention)
- **Conversion**: once at output boundary in `compute_room_metrics()` — never mix
- **Camera transforms**: world-from-camera, 4×4 column-major
- **Image projection**: `py = -fy * cam_y / depth + cy` (negate Y for ARKit → image)

## Cloud Infrastructure

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
  ├── mesh.ply                              # Uploaded by processor
  ├── textured.obj / .mtl / _material_00_map_Kd.jpg    # OpenMVS preview (10K faces)
  └── standard_textured.obj / .mtl / ...jpg             # OpenMVS HD (full mesh)
```

## Dead Code & Known Issues

### Dead Code (iOS)
- `PanoramaSweepView.swift` — Panoramic sweep removed; replaced by denser walk-around capture. `.capturingPanorama` state kept for backward compat but never entered.
- `CoverageAudit.swift` — Surface-level coverage audit. Compiles but never called. Superseded by cloud-side coverage endpoint.
- `MeshCoverageAnalyzer.swift` — On-device mesh face coverage. Works but disabled (coverage review removed to fix texture alignment).
- `CoverageReviewView.swift` — Text-based coverage display. Disabled pending ARWorldMap-based approach.
- `RoomViewerView.swift` — Stub (5 lines). 3D viewer opens in Safari instead.

### Dead Code (Cloud)
- `pipeline/texture_projection.py` WTA path — Only runs as fallback when OpenMVS fails. Production uses OpenMVS.
- `models/roomformer_finetuned.pt` + `roomformer_pretrained.pt` — 316MB of RoomFormer DNN models baked into container. Never loaded. Phase 2 placeholder.
- `training_data/` — 500 density map images + COCO annotations. Phase 2 training data, unused.

### Known Issues
- **ARFrame retention warnings** — ARSCNView delegate retains 11-13 frames during annotation. Caused by multiple ARSCNView instances sharing one session. Needs shared ARSCNView architecture (planned).
- **"Attempting to enable an already-enabled session"** — ARSCNView auto-runs the session when `scnView.session` is set, conflicting with `startSession()`. Harmless warning.
- **Coverage review disabled** — Pausing the AR session for coverage review breaks texture alignment. Next approach: ARWorldMap-based post-upload coverage check with relocalized re-scan.
- **Polling shows "processing failed" briefly** — Fixed: result view now accepts "complete" status. May still flash briefly on slow networks.

## Remaining Docs (current)

| Document | Status | Scope |
|----------|--------|-------|
| `CLAUDE.md` | **Current** | This file — system architecture and conventions |
| `PLATFORM_ARCHITECTURE.md` | **Current** | Marketplace expansion plan (accounts, orgs, bids, search) |
| `cloud/processor/TEXTURE_PIPELINE.md` | **Current** | OpenMVS A/B test results, decimation findings |
| `cloud/DNN_COMPONENT_TAXONOMY.md` | **Future** | DNN detection classes (Phase 2, not implemented) |
| `cloud/README.md` | **Current** | Cloud operations guide |
| `docs/deprecated/` | **Archived** | 10 old planning docs moved here — do not reference |
