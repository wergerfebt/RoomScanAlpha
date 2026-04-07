# RoomScan ML Architecture — Data Capture, Training & Inference Plan

## Context

RoomScanAlpha has three ML objectives that need to work together:
1. **Component detection** — recognize appliances, materials, cabinets, trim, fixtures in scanned rooms
2. **Render quality** — reduce ghosting/moshing in textured mesh; produce photorealistic novel views
3. **Non-LiDAR device support** — enable Android phones (no LiDAR) to produce usable 3D room scans

These share overlapping data requirements. This plan designs the model architecture, data capture strategy, and training pipeline as a unified system.

---

## Architecture: Three Models, One Data Pipeline

### Model 1: 3D Scene Segmentation (Component Detection)

**Architecture**: PointNet++ or MinkowskiNet (sparse 3D convolutions)

**Why 3D-native, not 2D images:**
- Annotations are already 3D (face indices from admin annotator) — zero conversion
- No occlusion projection problem (the problem that defeated our 2D export attempts)
- 3D context is valuable: a horizontal surface at Y=0 is floor; at Y=0.9m is countertop; at Y=2.4m is ceiling
- ARKit already provides per-face classification (wall/floor/ceiling/table/seat/door/window) — strong input feature

**Input features per vertex/face:**
- XYZ position (3 floats, meters)
- Normal vector (3 floats, from PLY)
- RGB color (3 floats, sampled from texture atlas at face UV center)
- ARKit classification (8-class one-hot: wall, floor, ceiling, table, seat, door, window, none)
- Height above floor plane (1 float, from Stage 2 plane fitting)
- Distance to nearest wall plane (1 float, from Stage 2)

**Output**: per-face label from the 30+ class taxonomy (DNN_COMPONENT_TAXONOMY.md)

**Training data**: admin annotator face-index annotations (annotations.json) — already built

**Deployment**: Vertex AI custom container with PyTorch + MinkowskiEngine, or ONNX export for Cloud Run

---

### Model 2: Monocular Depth Estimation (Non-LiDAR Support)

**Architecture**: Fine-tuned DepthAnything v2 or Metric3D v2

**Why fine-tune, not use off-the-shelf:**
- Off-the-shelf models predict relative depth; we need metric (absolute meters) for room measurement
- Indoor room scans have specific characteristics (close walls, regular geometry) that benefit from domain fine-tuning
- LiDAR scans provide perfect ground truth for training — every scan produces paired RGB + depth data

**Input**: Single RGB keyframe (1920×1440)

**Output**: Per-pixel depth map in meters (same resolution as input)

**Training data**: Every LiDAR scan already captures paired data:
- RGB keyframes (frame_NNN.jpg) — 180 per scan
- LiDAR depth maps (frame_NNN.depth) — 256×192 float32, upscale to image res for supervision
- Camera intrinsics for scale-correct projection

**Additional data to capture (new)**:
- IMU (accelerometer + gyroscope) at 100Hz — provides:
  - Gravity vector → absolute orientation (which way is "up")
  - Scale cues from acceleration integration (helps bridge monocular scale ambiguity)
  - Motion blur detection (high angular velocity → reject frame)
- Depth confidence maps — ARKit provides per-pixel confidence (0/1/2), helps weight the loss function during training

**Non-LiDAR inference pipeline**:
1. Android/non-LiDAR phone captures RGB frames + IMU at walk-around cadence
2. Depth model predicts per-frame depth maps
3. Multi-view SfM (COLMAP or similar) reconstructs camera poses from RGB feature matching
4. Predicted depths + poses → mesh reconstruction (TSDF fusion or Poisson)
5. Same cloud pipeline (Stages 1-3 + texturing) processes the reconstructed mesh

**Deployment**: On-device (CoreML for iOS, TFLite for Android) for real-time depth preview, or cloud for batch processing

---

### Model 3: 3D Gaussian Splatting (Render Quality)

**Architecture**: 3DGS (per-scene optimization, not a pre-trained model)

**Why Gaussian splatting, not NeRF:**
- 10-100x faster rendering than NeRF (real-time on mobile GPUs)
- Better at sharp edges and fine detail (NeRFs tend to blur)
- Easier to edit/modify (individual Gaussians can be removed/added)
- Compatible with mesh-based pipeline (can initialize from existing mesh)
- Active ecosystem: gsplat, nerfstudio, Sugar (mesh extraction from GS)

**Input per scene:**
- RGB keyframes + camera poses (already captured)
- Optional: LiDAR depth for initialization (faster convergence, better geometry)
- Optional: mesh from Stages 1-3 as initialization (SuGaR-style mesh → Gaussian conversion)

**Output:**
- Splat file (.ply with position, color, opacity, covariance per Gaussian)
- Can render novel views at 30+ FPS
- Can extract a mesh (via SuGaR, 2DGS, or GOF) for component detection

**Training**: Per-scene optimization (30-60 seconds on GPU), not a global model

**Integration with component detection:**
- Option A: Run segmentation on the mesh, transfer labels to Gaussians by nearest-neighbor
- Option B: Train a "semantic Gaussian splatting" variant that predicts labels per-Gaussian

**Deployment**: Cloud Run with GPU (NVIDIA T4/L4), or pre-rendered views cached in GCS

---

## Data Capture Strategy

### Currently Captured (keep all)

| Data | Format | Size/frame | Used by |
|------|--------|-----------|---------|
| RGB keyframe | JPEG 0.7q | ~500KB | All 3 models |
| LiDAR depth | float32 256×192 | 192KB | Depth model training, GS init |
| Camera pose | 4×4 float64 | 128B | All 3 models |
| Camera intrinsics | fx,fy,cx,cy | 16B | All 3 models |
| PLY mesh | binary | 8-50MB/scan | Segmentation, GS init |
| ARKit face classification | uint8/face | in PLY | Segmentation input feature |

### New Data to Capture

| Data | Format | Size/frame | Needed for | Priority |
|------|--------|-----------|-----------|----------|
| **Depth confidence map** | uint8 256×192 | 48KB | Depth model loss weighting | HIGH |
| **IMU (accel + gyro)** | 6×float32 @100Hz | ~2.4KB/s | Depth scale, blur detection | HIGH |
| **ARKit tracking state** | enum per frame | 1B | Frame quality filtering | MEDIUM |
| **Light estimate** | ambient + temp | 8B | Image normalization | LOW |
| **ARKit plane anchors** | polygon + normal | ~1KB/plane | Depth supervision, segmentation | MEDIUM |

**Estimated scan.zip size increase**: ~15% (mostly from confidence maps)

### iOS Capture Changes Required

File: `RoomScanAlpha/Models/CapturedFrame.swift`
- Add `confidenceData: Data?` — from `frame.sceneDepth?.confidenceMap`
- Add `trackingState: Int` — from `frame.camera.trackingState`
- Add `lightIntensity: Float?` — from `frame.lightEstimate?.ambientIntensity`

File: `RoomScanAlpha/AR/ARSessionManager.swift`
- Start CMMotionManager for raw IMU at 100Hz
- Buffer IMU samples, export alongside keyframes

File: `RoomScanAlpha/Export/ScanPackager.swift`
- Write `frame_NNN.confidence` (uint8 binary, 256×192)
- Write `imu.csv` or `imu.bin` (timestamp, ax, ay, az, gx, gy, gz)
- Add new fields to metadata.json and per-frame JSON

---

## Training Data Pipeline

### Segmentation Training Data (Model 1)
```
Source: admin_annotator.html → annotations.json
Format: { mesh_file, annotations: [{ label_key, faces: ["0:123", ...] }] }

Processing:
1. Load OBJ mesh (vertices, faces, normals)
2. Sample RGB at each face UV center from texture atlas
3. Compute height-above-floor and dist-to-wall from Stage 2 planes
4. Export as:
   - points.npy: (N, 6+) float32 [x, y, z, nx, ny, nz, r, g, b, arkit_class, height, wall_dist]
   - labels.npy: (N,) int32 [class_id per face]
   
One scan ≈ one training sample (646K faces = 646K labeled points)
Target: 50-100 annotated scans for Tier 1 classes
```

### Depth Training Data (Model 2)
```
Source: every LiDAR scan (automatic — no manual labeling!)
Format: paired (RGB, depth, intrinsics, optional IMU)

Processing:
1. For each keyframe: (frame_NNN.jpg, frame_NNN.depth, frame_NNN.json)
2. Upscale depth 256×192 → 1920×1440 (bilinear, masking invalid pixels)
3. Weight by confidence map (if available)
4. Export as standard depth estimation training format

One scan ≈ 180 training pairs
Target: 100+ scans = 18,000+ training pairs (strong dataset)
```

### Gaussian Splatting (Model 3)
```
Source: every scan (automatic — standard GS training input)
Format: COLMAP-style (images/ + sparse/ with cameras.txt, images.txt, points3D.txt)

Processing:
1. Already generated by openmvs_texture.py for OpenMVS
2. Reuse the same COLMAP sparse directory
3. Optionally add depth supervision from LiDAR

One scan = one scene to optimize (30-60s on GPU)
```

---

## Implementation Phases

### Phase A: Capture Enrichment (iOS changes)
- Add depth confidence maps to scan.zip
- Add raw IMU capture (100Hz accelerometer + gyroscope)
- Add tracking state per frame
- Minimal app changes, backward-compatible metadata.json

### Phase B: 3D Segmentation Pipeline
1. Export training data from admin annotator (mesh + face labels → point cloud format)
2. Train PointNet++ or MinkowskiNet on annotated scans
3. Deploy on Vertex AI as custom container
4. Integrate into cloud pipeline: after Stage 3, run inference → populate detected_components

### Phase C: Depth Estimation
1. Collect paired RGB+depth from all LiDAR scans (automatic)
2. Fine-tune DepthAnything v2 on indoor room data
3. Deploy as on-device model (CoreML + TFLite)
4. Build Android capture flow: RGB + IMU → depth prediction → mesh reconstruction

### Phase D: Gaussian Splatting
1. Run 3DGS optimization on existing scans using COLMAP sparse data
2. Compare render quality vs OpenMVS textured mesh
3. If quality wins: integrate into pipeline as alternative/upgrade to OpenMVS
4. Serve splats via web viewer (Three.js GS renderer or gsplat.js)

---

## What Requires Multiple Networks vs. Single Network

**Separate models (recommended):**
- Segmentation and depth estimation solve fundamentally different problems with different input types
- Depth estimation must run on-device (real-time feedback); segmentation runs in cloud (batch)
- Gaussian splatting is per-scene optimization, not a trained model at all

**Could be combined:**
- Segmentation + depth in a multi-task network (shared encoder, separate heads) — but adds complexity for minimal benefit at this scale
- Semantic Gaussian splatting (labels embedded in the scene representation) — research-stage, not production-ready

**Recommendation**: 3 separate systems. Train and validate each independently. Combine outputs downstream in the cloud pipeline.

---

## Verification Milestones

| Milestone | How to verify |
|-----------|--------------|
| Phase A: capture enrichment | Scan a room, verify confidence maps + IMU in scan.zip |
| Phase B: segmentation | Annotate 10 scans, train model, check mAP > 0.7 on held-out scan |
| Phase C: depth | Fine-tune on 50 scans, compare predicted depth vs LiDAR (< 5% error) |
| Phase C: Android | Capture with Android phone, reconstruct mesh, compare to LiDAR ground truth |
| Phase D: Gaussian splatting | Run on 5 scans, side-by-side compare viewer quality vs OpenMVS |

---

## Key Files

| File | Current state | Changes needed |
|------|--------------|----------------|
| `RoomScanAlpha/Models/CapturedFrame.swift` | Captures RGB + depth + pose | Add confidence, tracking state |
| `RoomScanAlpha/AR/ARSessionManager.swift` | AR session config | Add IMU capture via CMMotionManager |
| `RoomScanAlpha/Export/ScanPackager.swift` | Builds scan.zip | Add confidence maps, IMU data |
| `cloud/processor/pipeline/stage1.py` | PLY parsing | No change (already extracts classification) |
| `cloud/processor/tests/local_scan/real_test/admin_annotator.html` | Face painting UI | Done — exports annotations.json |
| `cloud/processor/tests/local_scan/real_test/export_training_data.py` | 2D projection (broken) | Rewrite for 3D point cloud export |
| `cloud/DNN_COMPONENT_TAXONOMY.md` | 30+ class taxonomy | No change — use as-is for segmentation |
| `cloud/processor/pipeline/openmvs_texture.py` | OpenMVS texturing | Keep; GS is additive, not replacement |
