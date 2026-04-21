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

# GS Processor (GPU — Gaussian Splatting, Vertex AI)
cd cloud/gs-processor
gcloud builds submit --tag us-central1-docker.pkg.dev/roomscanalpha/gs-pipeline/gs-processor:latest \
  --project roomscanalpha --timeout=3600 --machine-type=e2-highcpu-32
# Then submit a test job:
python submit_job.py --scan_id SCAN_ID --room_id ROOM_ID --rfq_id RFQ_ID

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
  → WTA texture projection (fallback): per-surface JPEGs from annotation corners (killed)
  → Upload textured mesh + atlas to GCS
  → Write results to Cloud SQL → FCM notification to app
  → Enqueue gs-processor via Cloud Tasks for Gaussian Splatting
  → Supplemental merge: POST /process-supplemental
    → Downloads original + supplemental zips → merges meshes (voxel+proximity filter)
    → Merges keyframes (continuous numbering) → re-textures with all frames
    → Overwrites textured outputs in GCS

Vertex AI Custom Job: gs-processor (g2-standard-8, L4 GPU, on-demand)
  → Triggered by scan-processor via Vertex AI API after mesh processing
  → Download scan data from GCS
  → HEVC video → extract frames → sharpness filter + stride-4 subsampling
  → ALIKED feature extraction (GPU, 8192 keypoints, 1600px)
  → LightGlue matching (GPU, sequential ±10 + spatial 30 neighbors)
  → GLOMAP global SfM mapper (CPU, via bundled binary)
  → FastGS training (GPU, 30K iterations, color correction)
  → Procrustes alignment to ARKit world frame (post-training)
  → Upload .splat to GCS
  → ~18 min end-to-end, auto-terminates after completion, ~$0.35/job

Cloud Run: scan-api (public)
  → Firebase Auth JWT on most endpoints; `/quote/` + `/embed/scan/` are link-as-auth
  → Serves contractor_view.html (full OBJ viewer with HD toggle, sidebar, MTLLoader)
  → Serves embed_viewer.html (chrome-less embed; URL params ?view=bev|tour, ?measurements, ?room)
  → Serves splat_viewer.html (Gaussian Splatting viewer with 2D covariance projection)
  → Generates signed GCS URLs for OBJ meshes + signed PUT URLs for chat attachments
  → Proxies MTL + atlas + splat files via /api/rfqs/{rfq_id}/scans/{scan_id}/files/{path}
  → Hosts /api/inbox + /api/conversations/* for homeowner ↔ contractor messaging
  → Auto-posts lifecycle events (bid_submitted, bid_accepted/rejected, rfq_updated) into threads
  → Proxies to processor for coverage checks

React SPA (Firebase Hosting: roomscanalpha.com / roomscanalpha.web.app)
  → Vite + React + TypeScript frontend
  → Firebase Auth (email/password + Google OAuth)
  → Design system: forest palette, iOS type scale (44/28/17/15/12), soft-white cards on warm canvas.
    --q-primary is marketplace accent; --q-scan-accent is locked to indigo across palettes.
  → Two Layout modes:
      - regular TopBar: homeowners + contractors on personal pages
      - dark ContractorTopBar with inline/dropdown nav + UserMenu: triggered only on /org*
  → Pages: Landing, Login, Projects, ProjectDetail, ProjectQuotes, Search, Inbox,
           Account, OrgDashboard, OrgProfile, Invite
  → Mobile: single-row contractor topbar (tabs → native <select>), Inbox + Jobs adopt a
    list→detail 2-page pattern with back button
  → Address autocomplete via Google Places API (key in .env: VITE_GOOGLE_MAPS_API_KEY)
  → /api/*, /quote/**, /embed/**, /splat/**, /bids/**, /admin/** rewritten to scan-api via
    Firebase Hosting. All links into those paths use <a href> (full-page nav) so the
    rewrite fires; react-router Link falls through to the SPA catch-all.
```

### Services

| Service | URL | Auth | Purpose |
|---------|-----|------|---------|
| scan-api | `https://scan-api-839349778883.us-central1.run.app` | Firebase JWT | REST API + web viewer |
| scan-processor | `https://scan-processor-839349778883.us-central1.run.app` | OIDC (Cloud Tasks) | Scan processing + OpenMVS |
| gs-processor | Vertex AI Custom Job | Service Account | Gaussian Splatting (L4 GPU) |
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

### Gaussian Splatting Pipeline (Production)

**Service: gs-processor** (Vertex AI Custom Job with L4 GPU)
- Source: `cloud/gs-processor/`
- Image: `us-central1-docker.pkg.dev/roomscanalpha/gs-pipeline/gs-processor:latest`
- Triggered by scan-processor via `submit_job.py` after mesh processing completes
- Runs on g2-standard-8 (8 vCPU, 32GB RAM, 1x L4 GPU), auto-terminates
- Produces a `.splat` file aligned to ARKit world frame for the 3D viewer

**Pipeline stages:**
```
1. GCS pull (~5s)           — Download scan.zip + mesh.ply from GCS
2. HEVC extract (~90s)      — Decode video frames via PyAV
3. Frame selection (~75s)    — Sharpness filter (bottom 20%) + stride-4 subsampling → ~475 frames
4. ALIKED features (~45s)   — GPU feature extraction, 8192 keypoints at 1600px (hloc)
5. LightGlue matching (~8m) — GPU matching, sequential ±10 + spatial 30 neighbors (~10K pairs)
6. COLMAP DB build (~5s)    — sqlite3 DB with ARKit intrinsics + pose priors
7. Geometric verify (~35s)  — pycolmap RANSAC verification
8. GLOMAP mapping (~4m)     — Global SfM (CPU, via GLOMAP binary built from source)
9. FastGS training (~5m)    — 30K iterations, color correction, resolution 2
10. Splat export (<1s)      — PLY → .splat (32 bytes/Gaussian)
11. ARKit alignment (<1s)   — Umeyama (Procrustes) transform to ARKit world frame
12. GCS upload (<5s)        — Upload .splat to scan bucket
```

**Key design decisions:**
- **ALIKED over SIFT/SuperPoint**: Deformable convolutions handle indoor textureless surfaces better. 8192 keypoints at 1600px resolution for dense coverage.
- **GLOMAP over COLMAP mapper**: Global SfM in ~4 min vs 15-30 min incremental. Registers ~75% of images (room interior well-covered, drops hallway/transition frames).
- **Post-training alignment**: Train in native SfM frame for best quality, then apply Umeyama similarity transform (scale + rotation + translation) to the final `.splat` file. Preserves relative Gaussian positions. RMS alignment error ~3cm.
- **ARKit intrinsics**: Read real fx/fy/cx/cy from `poses.jsonl` (not estimated). Prior focal length flag set in COLMAP DB.
- **ARKit pose priors**: Injected into `pose_priors` table to help GLOMAP converge near ARKit frame.
- **Color correction**: Per-frame white balance + brightness (LighthouseGS-inspired). Critical for quality — without it, Gaussian count drops from ~500K to ~160K.
- **Rasterizer guard**: FastGS CUDA rasterizer crashes when a camera sees 0 Gaussians. Patched backward to return `[N, 4]` zero gradient (not `[N, 3]`).

**Coordinate frames:**
- Training: native SfM frame (arbitrary, from GLOMAP)
- Output `.splat`: ARKit world frame (Y-up, meters) — aligned via Procrustes
- Measurement overlays: ARKit world frame (feet → meters in viewer)
- mesh.ply: ARKit world frame (unchanged from iOS)

**Dependencies (in Docker):**
- PyTorch 2.4.0+cu118, hloc (ALIKED + LightGlue), pycolmap 3.13, GLOMAP (built from source in Ubuntu 24.04 layer), FastGS + CUDA rasterizer, h5py, scipy

**Dev/test environment:**
- Vertex AI Workbench `gs-pipeline` (g2-standard-8, L4, us-central1-a)
- Auto-shutdown: 1hr idle. Start: `gcloud workbench instances start gs-pipeline --location=us-central1-a`
- Script: `/home/jake_a_julian_gmail_com/gs-pipeline/run_pipeline.py`
- GLOMAP Docker: `glomap:local` (pre-built on instance)

### Contractor Web Viewer

**Two rendering paths** (contractor_view.html):
1. **OBJ Mesh** (primary): Loads `textured.obj` via signed URL + MTL/atlas via file proxy (`MTLLoader` + `OBJLoader`). "HD On" toggles to `standard_textured.obj` with multi-atlas support. File proxy: `GET /api/rfqs/{rfq_id}/scans/{scan_id}/files/{path}` — maps `standard/` prefix to `standard_` prefixed GCS blobs.
2. **Quad Room** (fallback): Builds rectangular walls from annotation polygon, applies per-surface JPEGs

**URL params** on `/quote/{rfq_id}`:
- `?bev=1` — auto-enter Bird's Eye View once the mesh loads (used when iframed)
- `?embed=1` — legacy CSS-hide hack for chrome (superseded by the dedicated embed viewer below)

### Minimal Embed Viewer (`embed_viewer.html`)

**Route**: `GET /embed/scan/{rfq_id}` serves a chrome-less version of the Three.js viewer for iframing from any page (project detail, iOS WebView, future contractor review page). Shares the viewer math with `contractor_view.html` but has no sidebar, top-bar, modals, joystick, WASD, teleport, or iso thumbnail. Auth is link-based — no JWT required.

**URL params**:
| Param | Values | Default | Behavior |
|---|---|---|---|
| `view` | `bev` \| `tour` | `tour` | View mode is applied after the mesh finishes loading (so scene bounds are real) |
| `measurements` | `on` \| `off` | `on` | Controls CSS2D label visibility |
| `room` | `<scan_id>` | first room | Picks which room to show |

Used by `ProjectDetail.tsx` for the "Bird's eye" tab and by the Landing page's product preview. `contractor_view.html` and `splat_viewer.html` still exist as separate viewers — a later consolidation can merge them.

### Gaussian Splat Viewer

**3D Gaussian Splatting viewer** (`splat_viewer.html`) at `/splat/{rfq_id}` for viewing `.splat` files as an alternative to OBJ meshes. Uses proper 3DGS rendering math for photorealistic room visualization. Linked from contractor view via "View Splat" button (shown only for rooms with `.splat` files).

- **Rendering**: Three.js `RawShaderMaterial` (GLSL ES 1.00) with ~520K instanced billboards. Vertex shader builds 3D covariance from quaternion + scale, projects to 2D via Jacobian, computes eigenvalues for billboard sizing. Fragment shader uses Mahalanobis distance (conic) for elliptical Gaussian falloff. Premultiplied alpha blending (`ONE, ONE_MINUS_SRC_ALPHA`).
- **Scale detection**: Auto-detects linear vs log-encoded scales (GLOMAP/Procrustes outputs linear, standard 3DGS uses log). Filters outlier splats (position >50m, scale >1.0, alpha <10).
- **Depth sorting**: Web Worker with O(n) counting sort (16-bit quantized). Worker receives camera matrix, sorts + reorders all attribute buffers off main thread, transfers results back. Main thread only does buffer upload (~5ms), never blocks on sort.
- **Room alignment**: Splat and room polygon are both in ARKit world frame (Y-up, meters) — no manual alignment needed. Cyan wireframe overlay of room polygon rendered directly in the 3D scene for visual verification. Camera positioned at room polygon centroid at 6ft eye level, looking toward first wall (matches OBJ viewer positioning).
- **Room filtering**: Sidebar and floor plan only show rooms with `.splat` files available (`has_splat` field from API). Room switching disabled — viewer locked to the room whose splat is loaded.
- **Features**: Same sidebar (job info, floor plan, metrics), isometric 3D model thumbnail, bird's eye view, WASD/arrow movement, measurements toggle.
- **File proxy**: `.splat` files served via the same proxy endpoint as OBJ/MTL. Splats stored in GCS at `scans/{rfq_id}/{scan_id}/room_scan_glomap.splat`.
- **GPU usage**: ~520K splats with per-vertex covariance computation is GPU-intensive (~5-6GB GPU memory in Firefox). Future optimization: pre-compute covariance on CPU and store in GPU texture to simplify vertex shader.

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

**Public API endpoints** (no auth required):
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/contractors/search?service=&location=&q=` | Search orgs by service, location (geocoded), text. Returns org profiles with gallery preview. |
| GET | `/api/orgs/{org_id}` | Full public org profile (services, gallery, team, hours, map) |
| GET | `/api/rfqs/{rfq_id}/contractor-view` | RFQ detail (rooms, mesh URLs, features). Link-as-auth. |

Location search geocodes via Google Maps Geocoding API (`GOOGLE_MAPS_API_KEY` env var on scan-api) and filters by Haversine distance against each org's `service_radius_miles`.

**Inbox / messaging endpoints** (Firebase JWT required):
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/inbox?role=homeowner\|org\|auto` | Thread list for caller's side, with `kind`/`kind_label` (rfq/bid/won/msg) |
| POST | `/api/conversations` | `{ rfq_id, org_id }` — homeowner-initiated thread. Idempotent. Returns `{ id }`. |
| GET | `/api/conversations/{id}` | Full thread + ordered messages. Auto-marks caller's side read. |
| POST | `/api/conversations/{id}/messages` | Send `{ body, attachments }`. Bumps counterpart unread + emails them. |
| POST | `/api/conversations/{id}/read` | Manual mark-read. |
| GET | `/api/conversations/{id}/attachment-upload-url?content_type=&filename=` | Signed PUT URL for GCS. Blob path is scoped to the conversation. |

Messages can be `kind = text | event | bid`. Event messages are auto-posted from lifecycle hooks in `submit_bid`, `accept_bid`, and `update_rfq` (when pending bids get flagged). Bid messages embed a `bid_snapshot` JSONB so the card renders inline in the thread without re-fetching.

**Account-linked ownership** (important): `list_rfqs` and `list_bids` accept JWT ownership via *either* `rfqs.user_id == firebase_uid` (legacy) *or* `rfqs.homeowner_account_id == accounts.id` linked to the calling `firebase_uid`. New homeowner accounts go through the account table; older RFQs still pivot on the Firebase UID directly.

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
| `cloud/frontend/src/hooks/useAccount.ts` | Account/org context for TopBar workspace chip |
| `cloud/frontend/src/styles/tokens.css` | Design tokens — forest palette, iOS type scale, radii, spacing, `data-q-palette` swap attr |
| `cloud/frontend/src/components/Layout.tsx` | Mode switcher: dark ContractorTopBar on `/org*`, regular TopBar elsewhere |
| `cloud/frontend/src/components/TopBar.tsx` | Regular nav bar (logo, search, Inbox icon, Workspace chip for contractors, UserMenu) |
| `cloud/frontend/src/components/ContractorTopBar.tsx` | Dark contractor chrome: Q + "Acting as" + tabs (native `<select>` on mobile) + UserMenu |
| `cloud/frontend/src/components/SearchBar.tsx` | Two-field search (service + location) with mobile overlay |
| `cloud/frontend/src/components/SearchOverlay.tsx` | Full-screen mobile search with service list + location |
| `cloud/frontend/src/components/AddressAutocomplete.tsx` | Google Places autocomplete for address/location inputs |
| `cloud/frontend/src/components/AuthModal.tsx` | Sign in/create account/Google/forgot password |
| `cloud/frontend/src/components/FilterSidebar.tsx` | Price histogram, rating, service filters (collapsed on mobile) |
| `cloud/frontend/src/components/ContractorCard.tsx` | Expandable contractor card with profile, gallery, CTA |
| `cloud/frontend/src/components/ContractorBidForm.tsx` | Wireframe bid form: big Total + Timeline/Start + PDF card + Note. Exports `parseBidDescription` to round-trip structured fields through the description column. |
| `cloud/frontend/src/components/FloorPlan.tsx` | Canvas-rendered room polygon, responsive to parent size via ResizeObserver |
| `cloud/frontend/src/components/SubmitQuoteForm.tsx` | Legacy quote submission form (kept for /quote/ legacy embed) |
| `cloud/frontend/src/components/UserMenu.tsx` | Avatar dropdown (My Projects / Account / Sign out); prefers `account.icon_url` over Firebase photoURL |

### Pages
| Path | Page | Auth | Purpose |
|------|------|------|---------|
| `/` | Landing | Public | 72px hero + Google Places search + real-data product preview (c05cc122) + 4-step "How it works" |
| `/login` | Login | Public | Firebase auth (email/password + Google) |
| `/search` | Search | Public | Contractor discovery via `GET /api/contractors/search`. Gradient "Compare quotes" CTA banner. |
| `/contractors/{orgId}` | OrgProfile | Public | Public org profile + **Message** button (starts conversation; auto-creates a stub RFQ for "general inquiry") |
| `/projects` | Projects | Auth | Single-column card list (floor-plan thumb + title + status chip + meta + description). Cards link to `/projects/:rfqId`. |
| `/projects/{rfqId}` | ProjectDetail | Auth/link | Long-scroll: header + scan band (Floor plan / Bird's eye toggle) + scope + bids (ContractorCard + filters). Owner-only Edit modal contains Delete. |
| `/projects/{rfqId}/quotes` | ProjectQuotes | Auth | Legacy bid-only page (email deep links still land here) |
| `/inbox` | Inbox | Auth | Homeowner messaging; 2-pane desktop, list↔conversation on mobile |
| `/account` | Account | Auth | Profile editor, contractor request |
| `/org` | OrgDashboard | Auth+Org | Tab router for the contractor workspace (default `jobs`). All tabs render inside the dark ContractorTopBar chrome. |
| `/org?tab=inbox` | Inbox (org mode) | Auth+Org | Contractor-side messaging |
| `/org?tab=jobs` | OrgJobsWorkspace | Auth+Org | 3-pane: jobs list · scan review (embed viewer) · bid form. Mobile: list→detail |
| `/org?tab=gallery\|members\|services\|settings` | Org admin tabs | Auth+Org | Legacy admin surfaces (not yet redesigned) |
| `/invite` | Invite | Public | Token-based org invite acceptance |
| `/info` | (static) | Public | Original marketing landing page |

### Design system & tokens

`cloud/frontend/src/styles/tokens.css` is the source of truth. Forest palette is default; swap via `<html data-q-palette="indigo|terra|graphite">`.

Key variables: `--q-primary / --q-primary-soft / --q-primary-ink`, `--q-canvas / --q-surface / --q-surface-muted`, `--q-ink / --q-ink-soft / --q-ink-muted / --q-ink-dim`, `--q-hairline / --q-divider`, `--q-success / --q-warning / --q-danger`, `--q-scan-accent / --q-scan-accent-soft` (always indigo — scans/floor plans never adopt the marketplace palette).

Type scale: `--q-fs-display 44px / --q-fs-headline 28px / --q-fs-title 17px / --q-fs-body 15px / --q-fs-label 12px`. Radii: 8/12/16/20 + ios:26 + pill:9999. Legacy `--color-*` aliases still exist; migrate to `--q-*` when touching a file.

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
| `conversations` | One per (rfq_id, homeowner_account, org). Per-side unread counts + last-message preview (migration 019). |
| `messages` | Text / event / bid card. `attachments` JSONB stores `blob_path`; `/api/conversations/*` signs `download_url` at read time. `bid_snapshot` JSONB embeds price/desc for inline rendering. |

**Bid submission is now an upsert.** `POST /api/rfqs/{id}/bids` updates the caller's existing *pending* bid in place (keeps `bid_id`, preserves prior `pdf_url` unless a new file is attached, clears `rfq_modified_after_bid`). Only accepted/rejected bids are frozen. Timeline + start are stored as a structured prefix in `bids.description` (`Timeline: 6 weeks · Start: May 5\n\n{note}`) — `parseBidDescription()` in `ContractorBidForm.tsx` round-trips them.

### Email Notifications (SendGrid via `notifications@roomscanalpha.com`)
- **Contractor request**: Confirmation to requester + approval link to admin (jake@roomscanalpha.com)
- **Org approval**: One-click approve URL → auto-creates org + welcome email with dashboard link
- **Member invite**: Deep link token → `/invite?token=...` → sign in + auto-join org
- **Bid accepted**: Winner gets full project details + homeowner contact; homeowner gets contractor info; losers get brief notification
- **New inbox message**: fires only on user-authored `text` messages (not events/bid cards) — notifies the counterpart side with a deep link to the thread

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
gs://roomscanalpha-scans/
  ├── scans/{rfq_id}/{scan_id}/                         # Per-scan data
  │   ├── scan.zip                                      # Uploaded from iOS
  │   ├── supplemental_scan.zip                         # Uploaded from iOS (gap re-scan)
  │   ├── mesh.ply                                      # Uploaded by processor
  │   ├── textured.obj / .mtl / _material_00_map_Kd.jpg # OpenMVS preview (50K faces)
  │   ├── standard_textured.obj / .mtl / ...jpg         # OpenMVS HD (300K faces, multi-atlas ok)
  │   └── room_scan_glomap.splat                        # Gaussian Splat (ARKit world frame)
  ├── conversations/{conversation_id}/                  # Inbox attachments
  │   └── {uuid}.{jpg|png|pdf|...}                      # Per-message blobs, caller-validated paths
  └── bids/{rfq_id}/{bid_id}.pdf                        # Bid breakdown PDFs
```

### Hosting Rewrites (Firebase → scan-api)
The SPA lives at the root; these prefixes proxy to the Cloud Run scan-api so the backend can serve raw HTML viewers + legacy endpoints without leaking through React Router:
- `/api/**`, `/quote/**`, `/embed/**`, `/splat/**`, `/bids/**`, `/admin/**`

**Gotcha**: links into these prefixes must use `<a href>` (full-page navigation). `<Link>` from react-router does a pushState that React matches against its SPA routes, hits the catch-all (`index.html`), and renders blank. Reloading the same URL does a real HTTP GET that hits the rewrite and works — which is the classic "broken until I refresh" bug. `X-Frame-Options: SAMEORIGIN` lets these pages be iframed by the SPA (BEV thumbnail).

### Migrations
Numbered files in `cloud/migrations/` (019 = `conversations` + `messages`). Applied manually via:
```bash
# Start Cloud SQL Auth Proxy then psql (PGPASSWORD from Secret Manager)
cloud-sql-proxy --port=5433 roomscanalpha:us-central1:roomscanalpha-db &
PGPASSWORD="$(gcloud secrets versions access latest --secret=db-password --project=roomscanalpha)" \
  psql -h 127.0.0.1 -p 5433 -U postgres -d quoterra -f cloud/migrations/019_conversations.sql
pkill -f cloud-sql-proxy
```
Apply migrations *before* deploying scan-api if the new revision references new tables/columns.

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
- `contractor_view.html` `?embed=1` CSS-hide mode — superseded by dedicated `/embed/scan/` viewer; kept as fallback for any stale bookmarks.
- `splat_viewer.html` is a 1792-line copy-paste fork of contractor_view.html. Future: consolidate both + embed_viewer into one module with a `?mode=mesh|splat` param.

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
