# RoomScanAlpha (Quoterra)

iOS + cloud room scanning system. Users scan rooms with LiDAR-equipped iPhones, the cloud processes PLY meshes into textured 3D models via OpenMVS, and contractors view results in a web viewer to generate renovation quotes.

## Branching

All work branches from and merges into **`mvp-alpha`**, not `master`/`main`. The `mvp-alpha` branch has significant divergence from master (iOS app, cloud pipeline, admin tooling). Branching from master creates massive diffs and merge conflicts.

## Quick Reference

### Deploy
```bash
# Processor (uses pinned base image with OpenMVS binaries)
cd cloud/processor
gcloud run deploy scan-processor --source . --region us-central1 --project roomscanalpha \
  --set-secrets="DB_PASS=db-password:latest"

# API (includes SendGrid + DB secrets)
cd cloud/api
gcloud run deploy scan-api --source . --region us-central1 --project roomscanalpha \
  --set-secrets="SENDGRID_API_KEY=SENDGRID_API_KEY:latest,DB_PASS=db-password:latest"

# Frontend (Firebase Hosting — fast, no API rebuild)
cd cloud/frontend
npm run build
firebase deploy --only hosting

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
  → Serves splat_viewer.html (Gaussian Splatting viewer with 2D covariance projection)
  → Generates signed GCS URLs for OBJ meshes
  → Proxies MTL + atlas + splat files via /api/rfqs/{rfq_id}/scans/{scan_id}/files/{path}
  → Proxies to processor for coverage checks

React SPA (Firebase Hosting: roomscanalpha.com / roomscanalpha.web.app)
  → Vite + React + TypeScript frontend
  → Firebase Auth (email/password + Google OAuth)
  → Shared components: TopBar, SearchBar, AuthModal, FilterSidebar, ContractorCard, JobCard
  → Pages: Landing, Login, Projects, ProjectQuotes, Search, Account, OrgDashboard, OrgProfile, Invite
  → Persistent org sidebar for contractor accounts
  → /api/* proxied to Cloud Run scan-api via Firebase Hosting rewrites
```

### Services

| Service | URL | Auth | Purpose |
|---------|-----|------|---------|
| scan-api | `https://scan-api-839349778883.us-central1.run.app` | Firebase JWT | REST API + web viewer |
| scan-processor | `https://scan-processor-839349778883.us-central1.run.app` | OIDC (Cloud Tasks) | Scan processing + OpenMVS |
| Firebase Hosting | `https://roomscanalpha.com` / `https://roomscanalpha.web.app` | — | React SPA frontend |
| Cloud SQL | `roomscanalpha:us-central1:roomscanalpha-db` | IAM | PostgreSQL (db: `quoterra`) |
| GCS | `gs://roomscanalpha-scans/` | IAM | Scan storage + portfolio images |
| Artifact Registry | `us-central1-docker.pkg.dev/roomscanalpha/cloud-run-source-deploy` | IAM | Container images |
| SendGrid | — | API key (Secret Manager) | Email notifications |

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

### Gaussian Splat Viewer

**3D Gaussian Splatting viewer** (`splat_viewer.html`) at `/splat/{rfq_id}` for viewing `.splat` files as an alternative to OBJ meshes. Uses proper 3DGS rendering math for photorealistic room visualization.

- **Rendering**: Three.js `RawShaderMaterial` (GLSL ES 1.00) with instanced billboards. Vertex shader builds 3D covariance from quaternion + scale, projects to 2D via Jacobian, computes eigenvalues for billboard sizing. Fragment shader uses Mahalanobis distance (conic) for elliptical Gaussian falloff. Premultiplied alpha blending (`ONE, ONE_MINUS_SRC_ALPHA`).
- **Scale detection**: Auto-detects linear vs log-encoded scales (GLOMAP outputs linear, standard 3DGS uses log). Filters outlier splats (position >50 units, scale >1.0, alpha <10).
- **Depth sorting**: Web Worker with O(n) counting sort (16-bit quantized). Worker receives camera matrix, sorts + reorders all attribute buffers off main thread, transfers results back. Main thread only does buffer upload (~5ms), never blocks on sort.
- **Room alignment**: Cyan wireframe overlay of room polygon in the 3D scene. Orientation controls (rotation, translation, scale) to align splat with room geometry. "Snap to Center" aligns splat bbox center to room polygon centroid. Values persist to localStorage.
- **Features**: Locked to single room per splat. Same sidebar (job info, floor plan, metrics), isometric 3D model thumbnail, bird's eye view, WASD/arrow movement, measurements toggle.
- **File proxy**: `.splat` files served via the same proxy endpoint as OBJ/MTL. Splats stored in GCS at `scans/{rfq_id}/{scan_id}/room_scan_glomap.splat`.

### Admin Component Annotator

**Admin-only tool** (`admin_annotator.html`) at `/admin/rfq/{rfq_id}` for manually labeling 3D room scans with component types. Serves dual purpose: Wizard of Oz alpha (consumers see "detected" components) and DNN training data.

- **Auth**: Firebase JWT + `ADMIN_UIDS` env var allowlist (comma-separated Firebase UIDs)
- **Face painting**: Raycaster-based click+drag painting on OBJ mesh faces. 30+ component taxonomy (appliances, cabinets, floor materials, ceiling types, trim, doors, lights, occlusions/clutter). Spatial grid index for fast brush queries on 600K+ face meshes.
- **Corner editing**: Room polygon corners with independent floor/ceiling Y per corner. Edge-click insertion. Corners stored as `room_polygon_ft` + `wall_heights_ft` + `floor_heights_ft` in `scanned_rooms`.
- **Features layer**: Door frames, cased openings, windows, cabinet outlines as separate 3D polylines. Stored in GCS as `features.json` per room.
- **Keyboard shortcuts**: Hold P/N/E/C for momentary paint/navigate/erase/corners. Ctrl+P/N/E/C to latch. Ctrl+Z undo.
- **Save**: Annotations → GCS (`annotations.json`) + DB (`detected_components` JSONB on `scanned_rooms`). Polygon → DB (`room_polygon_ft`, `wall_heights_ft`). Features → GCS (`features.json`).
- **Detected materials**: Admin annotations update `detected_components` with `{ detected: [...labels], details: { label: { qty, unit } } }`. Contractor view and iOS app read this for display.

**Admin API endpoints** (all require Firebase JWT + admin UID check):
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/admin/rfq/{rfq_id}` | Serve admin annotator HTML |
| GET/PUT | `/api/admin/rfqs/{rfq_id}/scans/{scan_id}/annotations` | Annotation CRUD (GCS + DB) |
| GET/PUT | `/api/admin/rfqs/{rfq_id}/scans/{scan_id}/features` | Feature CRUD (GCS) |
| PUT | `/api/admin/rfqs/{rfq_id}/scans/{scan_id}/polygon` | Update room polygon + recompute dimensions |

**Planned**: Merge features into room polygon so door frames/openings connect to wall edges for segment-level measurements (trim linear feet). See `docs/ML_ARCHITECTURE.md` for the full ML training pipeline plan.

## React Frontend (Quoterra Platform)

### Tech Stack
- **Framework**: React 18 + TypeScript + Vite
- **Auth**: Firebase Auth (email/password + Google OAuth)
- **Hosting**: Firebase Hosting (roomscanalpha.com) with Cloud Run rewrites for `/api/*`
- **State**: React Context (AuthProvider, AccountProvider)
- **Styling**: CSS custom properties (tokens.css) + inline styles

### Deploy
```bash
cd cloud/frontend
npm run build
firebase deploy --only hosting    # ~10 seconds, no API rebuild needed
```

### Key Files
| File | Purpose |
|------|---------|
| `cloud/frontend/src/App.tsx` | Route definitions |
| `cloud/frontend/src/api/firebase.ts` | Firebase singleton + auth helpers |
| `cloud/frontend/src/api/client.ts` | `apiFetch()` with JWT injection |
| `cloud/frontend/src/hooks/useAuth.ts` | Auth context (user, signIn, signOut) |
| `cloud/frontend/src/hooks/useAccount.ts` | Account/org context for sidebar |
| `cloud/frontend/src/components/TopBar.tsx` | Shared nav bar |
| `cloud/frontend/src/components/SearchBar.tsx` | Two-field search (service + location) with mobile overlay |
| `cloud/frontend/src/components/AuthModal.tsx` | Sign in/create account/Google/forgot password |
| `cloud/frontend/src/components/FilterSidebar.tsx` | Price histogram, rating, service filters |
| `cloud/frontend/src/components/ContractorCard.tsx` | Expandable bid card with gallery + hire |
| `cloud/frontend/src/components/JobCard.tsx` | Expandable RFQ card for contractors with floor plan |
| `cloud/frontend/src/components/FloorPlan.tsx` | Canvas-rendered room polygon floor plan |
| `cloud/frontend/src/components/SubmitQuoteForm.tsx` | Inline quote submission (price + desc + PDF) |
| `cloud/frontend/src/components/OrgSidebar.tsx` | Persistent left sidebar for org members |

### Pages
| Path | Page | Auth | Purpose |
|------|------|------|---------|
| `/` | Landing | Public | Hero + search + how it works |
| `/login` | Login | Public | Firebase auth (email/password + Google) |
| `/search` | Search | Public | Contractor discovery with filters |
| `/contractors/{orgId}` | OrgProfile | Public | Public org profile with gallery, map, hours |
| `/projects` | Projects | Auth | Homeowner RFQ list with expandable details, edit, delete |
| `/projects/{rfqId}/quotes` | ProjectQuotes | Auth | Bid comparison with filters, hire button |
| `/account` | Account | Auth | Profile editor, contractor request |
| `/org` | OrgDashboard | Auth+Org | Tabs: Jobs, Settings, Gallery, Members, Services |
| `/invite` | Invite | Public | Token-based org invite acceptance |
| `/info` | (static) | Public | Original marketing landing page |

### Marketplace Database (implemented)
| Table | Purpose |
|-------|---------|
| `accounts` | Unified user accounts (homeowner/contractor) |
| `organizations` | Contractor orgs with profile, address, geo, hours |
| `org_members` | Account-to-org links with roles (admin/user) |
| `org_requests` | Org creation approval workflow |
| `org_work_images` | Portfolio gallery (images + videos, albums) |
| `albums` | Groups media with service tags + job links |
| `services` | 14 service categories (Kitchen Remodel, etc.) |
| `org_services` | Org-to-service links |
| `bids.org_id` | Links bids to orgs (added to existing bids table) |
| `bids.status` | pending/accepted/rejected |
| `bids.rfq_modified_after_bid` | Flag when homeowner edits project after bid |
| `rfqs.homeowner_account_id` | Links RFQs to account system |
| `rfqs.deleted_at` | Soft-delete (preserves bids for contractors) |

### Email Notifications (SendGrid via `notifications@roomscanalpha.com`)
- **Contractor request**: Confirmation to requester + approval link to admin (jake@roomscanalpha.com)
- **Org approval**: One-click approve URL → auto-creates org + welcome email with dashboard link
- **Member invite**: Deep link token → `/invite?token=...` → sign in + auto-join org
- **Bid accepted**: Winner gets full project details + homeowner contact; homeowner gets contractor info; losers get brief notification

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
  ├── standard_textured.obj / .mtl / ...jpg             # OpenMVS HD (300K faces, may have multiple atlases)
  └── room_scan_glomap.splat                            # Gaussian Splat (optional, from GLOMAP pipeline)
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
- **DB_PASS deployment** — Both Cloud Run services use `db-password` from Secret Manager via `--set-secrets`. Always include `--set-secrets` in deploy commands.

## Remaining Docs (current)

| Document | Status | Scope |
|----------|--------|-------|
| `CLAUDE.md` | **Current** | This file — system architecture and conventions |
| `docs/SUPPLEMENTAL_SCAN_MERGE.md` | **Archived** | Supplemental scan capture, upload & merge plan (implemented) |
| `PLATFORM_ARCHITECTURE.md` | **Current** | Marketplace expansion plan (accounts, orgs, bids, search) |
| `cloud/processor/TEXTURE_PIPELINE.md` | **Current** | OpenMVS A/B test results, decimation findings |
| `cloud/DNN_COMPONENT_TAXONOMY.md` | **Future** | DNN detection classes (Phase 2, not implemented) |
| `docs/ML_ARCHITECTURE.md` | **Current** | ML strategy: 3D segmentation, monocular depth, Gaussian splatting, data capture |
| `cloud/README.md` | **Current** | Cloud operations guide |
| `docs/deprecated/` | **Archived** | 10 old planning docs moved here — do not reference |
