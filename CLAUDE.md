# RoomScanAlpha

iOS + cloud room scanning system for Quoterra. Users scan rooms with LiDAR-equipped iPhones, the cloud processes PLY meshes into room dimensions and textured 3D models, and contractors view results in a web viewer to generate renovation quotes.

## Quick Reference

### Deploy & Test (processor)
```bash
cd cloud/processor
./deploy.sh                                           # build + deploy (~30s with Docker, ~15min without)
./reprocess.sh <rfq_id> all                           # reprocess all scans for an RFQ
python3 -m pytest tests/test_texture_projection.py -v  # run tests
```

### Test RFQ
- **RFQ**: `d6751509-6076-439e-9d36-51c511aeb95f`
- **Viewer**: `https://scan-api-839349778883.us-central1.run.app/quote/d6751509-6076-439e-9d36-51c511aeb95f`

## Coordinate Conventions
- **On-device**: meters (ARKit Y-up, right-handed: X=right, Y=up, Z=back)
- **Cloud output**: imperial feet/sqft (US construction convention)
- **Conversion**: once at the output boundary in `compute_room_metrics()` — never mix in storage or transit
- **Camera transforms**: world-from-camera, 4×4 column-major
- **Image projection**: `py = -fy * cam_y / depth + cy` (negate Y for ARKit Y-up → image Y-down)

## Project Structure
```
RoomScanAlpha/
├── RoomScanAlpha/              # iOS app (Swift/SwiftUI/ARKit)
│   ├── AR/                     # ARSession, mesh extraction, frame capture
│   ├── Models/                 # ScanState, CapturedFrame, CornerAnnotation
│   ├── Views/                  # AR scanning, panorama sweep, annotation UIs
│   ├── ViewModels/             # ScanViewModel, CornerAnnotationViewModel
│   └── Export/                 # PLY exporter, scan packager
├── cloud/
│   ├── api/                    # FastAPI REST API (Cloud Run, public)
│   │   ├── main.py             # Auth, signed URLs, upload-complete, status, contractor view
│   │   └── web/                # contractor_view.html (Three.js room viewer)
│   ├── processor/              # FastAPI scan processor (Cloud Run, OIDC-protected)
│   │   ├── main.py             # Pipeline orchestrator: download → parse → compute → texture → upload
│   │   ├── pipeline/
│   │   │   ├── stage1.py       # PLY parsing + mesh classification
│   │   │   ├── stage2.py       # RANSAC plane fitting
│   │   │   ├── stage3.py       # Room geometry assembly
│   │   │   └── texture_projection.py  # Texture projection, mesh correction, pose refinement
│   │   ├── deploy.sh           # Fast build + deploy (Docker layer caching)
│   │   ├── reprocess.sh        # Reprocess scans via Cloud Run proxy
│   │   └── tests/
│   ├── schema.sql              # PostgreSQL schema
│   └── README.md               # Cloud operations guide
```

## Documentation Index

| Document | Scope |
|----------|-------|
| `IMPLEMENTATION_PLAN.md` | System architecture: iOS lifecycle, AR capture, PLY export, cloud pipeline, DB schema |
| `IMPLEMENTATION_PLAN_MVP.md` | 1-month Quoterra pilot: MVP features, UX flows, deferred scope |
| `IMPLEMENTATION_PLAN_PHASE_2.md` | Post-MVP: adaptive keyframe quality, coverage scoring, DNN training data |
| `TEXTURE_PIPELINE.md` | Texture capture + projection: panoramic sweep, frame merging, mesh correction, pose refinement |
| `cloud/README.md` | Cloud operations: deploy, reprocess, memory constraints, environment config |
| `cloud/CLOUD_PIPELINE_PLAN.md` | Processing Stages 1-6: PLY parsing, plane fitting, geometry, measurements |
| `cloud/VISUALIZATION_PLAN.md` | Stages 7-9: floor plans, measurement annotations, web viewer (Three.js) |
| `cloud/DNN_COMPONENT_TAXONOMY.md` | 30+ detection classes, Vertex AI deployment, training tiers |
| `cloud/ROOMPLAN_INTEGRATION_PLAN.md` | Apple RoomPlan as alternative to RANSAC for Stage 3 geometry |

## Cloud Infrastructure
- **GCP project**: `roomscanalpha` (us-central1)
- **API**: `https://scan-api-839349778883.us-central1.run.app` (public)
- **Processor**: `https://scan-processor-839349778883.us-central1.run.app` (OIDC-protected)
- **Cloud SQL**: `roomscanalpha:us-central1:roomscanalpha-db` (PostgreSQL, db: `quoterra`)
- **GCS**: `gs://roomscanalpha-scans/`
- **Artifact Registry**: `us-central1-docker.pkg.dev/roomscanalpha/cloud-run-source-deploy`

## Key Technical Decisions
- **embreex over rtree**: `rtree`/`libspatialindex` segfaults in Cloud Run containers (bug #107: uninitialized variable with degenerate LiDAR triangles). `embreex` (Intel Embree) is stable with prebuilt Linux wheels.
- **WTA over weighted blending**: Winner-takes-all avoids ghosting from ARKit pose drift. Geometric alignment (pose refinement) must be solved before blending improvements.
- **Cloud-first processing**: All CV processing runs in the cloud, not on-device. Ensures cross-platform consistency and leverages server-grade compute.
- **Exposure/WB lock during capture**: AVCaptureDevice exposure and white balance are locked when scanning starts to eliminate color shifts between keyframes. Denser capture (8° rotation, 0.3s interval) replaces the separate panoramic sweep phase.
