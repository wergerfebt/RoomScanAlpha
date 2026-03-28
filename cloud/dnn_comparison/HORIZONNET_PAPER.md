# HorizonNet — Technical Evaluation for RoomScanAlpha Stage 3

> **Agent A Evaluation** | Model: HorizonNet (CVPR 2019)
> Evaluated against: RoomScanAlpha cloud pipeline Stage 3 (Room Geometry Assembly)

---

## 1. Executive Summary

HorizonNet is a panoramic room layout estimation model that predicts 3D room structure from a single 360-degree equirectangular RGB image. It encodes room layout as three 1D vectors — floor-wall boundary, ceiling-wall boundary, and wall-wall corner existence — one value per image column, enabling extremely fast inference (~20ms on a GTX 1080 Ti). The model uses a ResNet-50 backbone with a bidirectional LSTM to capture horizontal context, followed by lightweight post-processing that enforces Manhattan World constraints (orthogonal walls) to recover 3D room corners. It is a candidate for RoomScanAlpha's Stage 3 because it directly produces a closed room polygon plus ceiling height — exactly what Stage 3 needs. However, the critical gap is input format: HorizonNet requires a complete 360x180-degree equirectangular panorama, while RoomScanAlpha has a LiDAR mesh, depth maps, and posed RGB keyframes that cover only 40-70% of the viewing sphere. This conversion is lossy and introduces significant quality degradation. Additionally, the Manhattan World constraint limits it to rooms with orthogonal walls, excluding angled or curved geometries.

---

## 2. Architecture & How It Works

### 2.1 Model Architecture

| Component | Details |
|-----------|---------|
| **Backbone** | ResNet-50 (configurable: ResNet-18/34/101/152, ResNeXt, DenseNet) |
| **Feature compression** | Per-block convolutions (4x1, 2x1, 2x1 kernels with stride) reduce height by 16x and channels by 8x |
| **Feature fusion** | Multi-scale features from all ResNet blocks upsampled to width 256, concatenated → 1024 x 1 x 256 bottleneck |
| **Sequence model** | Bidirectional LSTM, 2 layers, hidden size 512, processes 4 columns per timestep |
| **Output heads** | 3 parallel 1D vectors, each length 1024 (one value per image column) |
| **Parameters** | ~28M with RNN; ~25M without |
| **Checkpoint size** | ~110 MB (FP32) |

### 2.2 Output Heads & Loss Functions

| Head | Semantics | Activation | Loss |
|------|-----------|------------|------|
| **y_c** | Ceiling-wall boundary latitude at each column | Identity (regression) | L1 |
| **y_f** | Floor-wall boundary latitude at each column | Identity (regression) | L1 |
| **y_w** | Wall-wall corner existence probability at each column | Sigmoid | Binary Cross-Entropy |

The wall-wall corner signal uses exponential decay encoding: `y_w(i) = 0.96^|dx|` where `dx` is distance in columns to the nearest corner. This soft encoding addresses the extreme sparsity problem — a 4-wall room has only 4 nonzero values out of 1024 in a hard binary encoding.

### 2.3 Input Representation

- **Format**: RGB equirectangular panorama
- **Resolution**: 512 x 1024 (height x width), mandatory 2:1 aspect ratio
- **FOV**: Full 360-degree horizontal x 180-degree vertical
- **Preprocessing**: Manhattan alignment via vanishing point detection from LSD line segments. The provided `preprocess.py` script detects vanishing points and rotates the panorama so that walls align vertically in the equirectangular projection. This is critical — the 1D representation assumes vertical wall-wall boundaries.

### 2.4 Inference Pipeline

```
Input panorama (any resolution)
  ↓ Resize to 512x1024
  ↓ Manhattan alignment (vanishing point detection + rotation)
  ↓ Normalize (ImageNet mean/std)
  ↓ ResNet-50 feature extraction
  ↓ Multi-scale feature fusion → 1D bottleneck
  ↓ BiLSTM horizontal context
  ↓ 3 output heads → y_c, y_f, y_w (each 1024 values)
  ↓ Peak detection on y_w → wall corner column indices
  ↓ Project y_c/y_f to 3D using camera height assumption (1.6m)
  ↓ PCA on wall segments → dominant room axis angle
  ↓ Voting for wall positions along perpendicular axes
  ↓ Manhattan constraint enforcement (orthogonal walls)
  ↓ Corner computation from wall-line intersections
  → Output: 3D room corners (floor polygon + ceiling height)
```

**Post-processing detail** (from `misc/post_proc.py`):

1. **Peak detection**: Morphological maximum filter on y_w, threshold > 0.05, local maximum within 5-degree H-FOV.
2. **3D projection**: Each column's ceiling/floor boundary latitude is un-projected to the ceiling/floor plane using assumed camera height (1.6m default).
3. **PCA alignment**: `PCA(n_components=1)` on each wall segment's projected points extracts the dominant direction. The room is rotated to align with Manhattan axes.
4. **Plane voting**: The `vote()` function builds a pairwise distance matrix of candidate wall positions, finds the largest cluster where >=40% of samples fall within tolerance, and returns the cluster mean as the wall position.
5. **Manhattan constraint**: Adjacent walls are forced to alternate between two orthogonal types. Three consecutive same-type walls trigger a forced orientation change on the middle wall.
6. **Corner computation**: Final 3D corners computed from constrained wall-line intersections.

Total post-processing time: <20ms.

---

## 3. Input Compatibility with RoomScanAlpha

### 3.1 What We Have

| Data | Format | Coverage |
|------|--------|----------|
| PLY mesh | Vertices + faces + per-face ARKit classification (floor/wall/ceiling/door/window/table/seat) | Partial sphere (where user pointed device) |
| RGB keyframes | JPEG images, ~60-degree FOV each | 10-50 keyframes per scan |
| Camera poses | 4x4 transform matrices per keyframe | Full 6-DOF |
| Depth maps | Per-keyframe ARKit depth | Same FOV as keyframes |
| Point cloud | Derivable from mesh vertices with per-vertex color | Same coverage as mesh |

### 3.2 What HorizonNet Needs

A single, complete, high-quality 512x1024 RGB equirectangular panorama covering the full 360x180-degree sphere with visible floor-wall and ceiling-wall boundaries at every azimuth.

### 3.3 Gap Analysis

**The gap is large.** Three conversion paths exist, all with significant quality loss:

**Path A — Point cloud spherical projection:**
Project each colored 3D point onto the unit sphere from a chosen viewpoint (room center), map to equirectangular coordinates. Tools: `points2pano`, or ~50 lines of NumPy (`theta = atan2(x, z)`, `phi = atan2(y, sqrt(x^2+z^2))`).

*Problems:*
- iPhone LiDAR point density (~300K-1M points per room) yields a very sparse panorama. At 512x1024 = 524K pixels, many pixels will be empty.
- LiDAR coverage is typically 40-70% of the sphere — the remaining 30-60% will be black voids.
- Point colors come from different keyframes captured at different times/exposures, producing patchwork color inconsistencies.
- LiDAR struggles with reflective surfaces, producing phantom points at incorrect depths.

**Path B — Perspective keyframe warping:**
Warp each posed RGB keyframe into equirectangular space using known camera intrinsics/extrinsics, composite overlapping regions. Libraries: `Perspective-and-Equirectangular`, OpenCV `warpPerspective`.

*Problems:*
- Same coverage gap: keyframes collectively cover only what the user pointed at.
- Exposure/white-balance differences between keyframes produce visible seams.
- No keyframe captures the floor directly below or ceiling directly above the device.

**Path C — Hybrid (recommended if attempting this path):**
Combine point cloud projection (for geometry/coverage map) with keyframe warping (for texture quality), z-buffer by LiDAR depth, then inpaint remaining gaps.

*Problems:*
- Inpainting must hallucinate plausible wall-floor and wall-ceiling boundaries in uncovered regions. Standard inpainting (OpenCV, LaMa) cannot reliably synthesize architectural boundaries.
- HorizonNet's 1D representation reads every column — a hallucinated boundary at any azimuth produces a garbage prediction at that column.

**Path D — NeRF-based rendering:**
Train a NeRF on posed RGB images, render an equirectangular view. Highest quality, but adds minutes of compute per scan (NeRF training), and still cannot extrapolate to unseen regions.

### 3.4 Coverage Gap Quantification

HorizonNet was trained on **complete, high-quality panoramas** from real 360-degree cameras (Ricoh Theta, Insta360) or synthetic renderers (Structured3D). It has **zero built-in robustness** to missing regions. The 1D representation processes every column independently through the LSTM — a black column propagates error to neighboring columns via the recurrent state.

A typical RoomScanAlpha scan covers ~40-70% of the sphere. The missing 30-60% means:
- 30-60% of the 1024 output columns will have unreliable predictions
- Floor boundary below the device holder is almost always missing
- Ceiling directly above is often poorly covered
- Corners behind furniture have occlusion gaps

**This is the single largest risk for this approach.**

### 3.5 Non-Rectangular Room Support

HorizonNet's general layout mode supports L-shapes, T-shapes, and polygons with 4-10+ corners. However:

- **Manhattan constraint is enforced**: All walls must be at 90-degree angles to each other. Angled walls, 45-degree corners, and curved walls are not supported.
- **Performance degrades with complexity**: 94.1% IoU for 4-corner rooms → 80.0% for 10+ corners on Structured3D; 81.9% → 68.3% on MatterportLayout.
- **Original non-cuboid training**: Only 65 re-labeled samples. Requires Structured3D or ZInD pretraining for decent general layout performance.

For RoomScanAlpha's residential rooms, most are rectangular or L-shaped with orthogonal walls, so the Manhattan constraint is acceptable for ~80% of use cases. But rooms with bay windows, angled walls, or curved features will fail.

---

## 4. Output Compatibility with RoomScanAlpha

### 4.1 What Stage 3 Must Produce

- A **closed 2D polygon** (list of XZ vertices in meters) representing the room floor boundary
- **Ceiling height** (single float, in meters, converted to feet at output boundary)
- These feed into: `floor_area_sqft`, `wall_area_sqft`, `perimeter_linear_ft`, `ceiling_height_ft` in the `scanned_rooms` table

### 4.2 What HorizonNet Outputs (Raw)

After post-processing, HorizonNet produces a JSON with room corners:
```json
{
  "z0": 1.234,    // floor y-coordinate
  "z1": -1.456,   // ceiling y-coordinate
  "uv": [         // corner positions in normalized equirectangular coordinates
    [0.125, 0.45],
    [0.375, 0.42],
    ...
  ]
}
```

Corners are in normalized UV coordinates on the equirectangular image, with associated floor/ceiling depths.

### 4.3 Postprocessing to Room Polygon + Height

The conversion from HorizonNet output to Stage 3's required format is **moderately straightforward**:

1. **Unproject UV corners to 3D**: Each corner's `u` coordinate gives azimuth angle, `z0`/`z1` give floor/ceiling depth. Using the camera height assumption (1.6m), compute XZ coordinates on the floor plane.

2. **Scale calibration**: HorizonNet assumes a fixed camera height (1.6m). The actual scanner height is unknown. However, RoomScanAlpha's Stage 2 already detects the floor and ceiling planes via RANSAC, giving us the true floor-to-ceiling distance. We can use this to scale HorizonNet's output proportionally.

3. **Coordinate system alignment**: HorizonNet's output is relative to the panorama's center viewpoint. We need to translate to the mesh's ARKit coordinate system. If we render the panorama from a known position in the mesh, this is a simple translation.

4. **Polygon formation**: The corners are already ordered (clockwise or counter-clockwise around the room). Connect them to form the closed polygon.

5. **Ceiling height**: `|z0 - z1|` scaled by the camera height ratio gives ceiling height in meters.

**Mapping quality**: This is a fairly clean mapping. The main complication is the camera height calibration — an incorrect assumption introduces a systematic scale error on all XZ coordinates. Using Stage 2's floor/ceiling plane distances as ground truth for calibration mitigates this well.

---

## 5. Accuracy & Performance

### 5.1 Published Benchmarks

#### Cuboid Layout (PanoContext + Stanford 2D-3D)

| Dataset | 3D IoU (%) | Corner Error (%) | Pixel Error (%) |
|---------|-----------|-----------------|-----------------|
| PanoContext | 82.17 | 0.76 | 2.20 |
| Stanford 2D-3D | 83.51 | 0.62 | 1.97 |
| Combined test | 84.23 | 0.69 | 1.90 |

#### General Layout (Non-Cuboid) — Structured3D

| Room Complexity | 3D IoU (%) | 2D IoU (%) | Count |
|-----------------|-----------|-----------|-------|
| 4 corners | 94.14 | 95.50 | 1,067 |
| 6 corners | 90.34 | 91.54 | 290 |
| 8 corners | 87.98 | 89.43 | 130 |
| 10+ corners | 79.95 | 81.10 | 202 |
| **Overall** | **91.31** | **92.63** | **1,693** |

#### General Layout — MatterportLayout (Real-World)

| Method | 2D IoU (%) | 3D IoU (%) | RMSE | delta_1 |
|--------|-----------|-----------|------|---------|
| HorizonNet | 81.71 | 79.11 | 0.197 | 0.929 |
| LED2-Net (successor) | 82.61 | 80.14 | 0.207 | 0.947 |
| LGT-Net (latest) | 83.52 | 81.11 | 0.204 | 0.951 |

#### General Layout — Zillow Indoor (ZInD)

| Method | 2D IoU (%) | 3D IoU (%) |
|--------|-----------|-----------|
| HorizonNet | 90.44 | 88.59 |
| LED2-Net | 90.36 | 88.49 |
| LGT-Net | **91.77** | **89.95** |

### 5.2 MatterportLayout by Corner Count (HorizonNet)

| Corners | 3D IoU (%) | RMSE |
|---------|-----------|------|
| 4 corners | 81.88 | 0.166 |
| 6 corners | 82.26 | 0.173 |
| 8 corners | 71.78 | 0.243 |
| 10+ corners | 68.32 | 0.345 |

### 5.3 Context: HorizonNet vs. Successors

HorizonNet has been **surpassed** on most benchmarks:
- **LED2-Net** (CVPR 2021): Same backbone, replaces coordinate loss with differentiable depth rendering loss. +1-3 points 3D IoU. Can pre-train on Structured3D depth data for better cross-dataset generalization.
- **LGT-Net** (CVPR 2022): Replaces BiLSTM with SWG-Transformer, adds geometry-aware loss with surface normals. +2-3 points 3D IoU. Current state-of-the-art in the HorizonNet family.

All three share the same input format (equirectangular panorama) and output format (1D boundary vectors), so the input compatibility gap applies equally to all of them.

### 5.4 Known Failure Modes

1. **Mirrors/reflective surfaces**: Reflected room boundaries confuse the model, producing phantom wall detections.
2. **Non-Manhattan geometry**: Curved walls, angled walls, bay windows — any non-90-degree junction fails.
3. **Complex rooms (10+ corners)**: Accuracy drops from 94% to 68-80% IoU as corner count increases.
4. **Camera misalignment**: Vanishing point detection failure propagates to layout errors.
5. **Fixed camera height**: Assumes 1.6m; deviations cause systematic scale error.
6. **Single floor/ceiling**: Cannot handle multi-level rooms, lofts, stairs, or sloped ceilings.
7. **Heavy occlusion**: Extremely cluttered rooms where walls are barely visible degrade predictions.
8. **Incomplete panoramas**: Not trained on partial views — missing regions produce unreliable columns (our biggest concern).

### 5.5 Inference Latency

| Component | Time (GTX 1080 Ti) |
|-----------|-------------------|
| Forward pass (with RNN) | ~8 ms |
| Post-processing | ~12 ms |
| **Total** | **~20 ms** |

On a cloud T4 GPU: ~50-80ms total. On CPU: ~500-1500ms. Either is well within the <10s target.

---

## 6. Integration with GCP / Vertex AI

### 6.1 Deployment Options

**Option 1 — Cloud Run with L4 GPU (recommended):**
- True scale-to-zero, per-second billing
- Cold start: ~10-15 seconds (GPU driver pre-installed, small model)
- Cost: ~$0.67/hr when active
- Simplest deployment: just a Docker container with Flask/FastAPI

**Option 2 — Vertex AI Prediction with T4 GPU:**
- Scale-to-zero via `min_replica_count=0` (v1beta1 API)
- Cold start: 60-180 seconds (VM + GPU provisioning)
- Cost: ~$0.55-0.65/hr when active
- More complex: model registry, endpoint configuration

**Option 3 — Vertex AI CPU-only:**
- Cheapest: ~$0.19/hr on n1-standard-4
- Inference: ~1-1.5 seconds per image (acceptable for async processing)
- Cold start: ~30-60 seconds

### 6.2 GPU Requirements

| Metric | Value |
|--------|-------|
| VRAM needed | ~200-400 MB (single image inference) |
| Minimum GPU | Any NVIDIA GPU with CUDA support |
| Recommended | T4 (16 GB) or L4 (24 GB) — both massively over-provisioned |
| CPU-only | Feasible at ~1 second per image |

### 6.3 Container Packaging

Straightforward. The model is pure PyTorch with standard dependencies (torch, torchvision, numpy, scipy, scikit-learn, opencv, shapely). A Dockerfile with `pytorch/pytorch:2.x-cuda12.x` base, pip install requirements, copy model weights + inference code, expose HTTP endpoint. Estimated effort: 1-2 days.

### 6.4 Cost per Prediction (at 100 predictions/day)

| Deployment | Monthly Cost | Cold Start |
|------------|-------------|------------|
| **Cloud Run + L4** | **$1.50-17** | ~10-15s |
| Vertex AI CPU-only | $3-15 | ~30-60s |
| Vertex AI T4 | $17-83 | ~60-180s |

Cloud Run with L4 is the clear winner for this workload profile. At 100 requests/day, estimated cost is **$0.01-0.06 per prediction**.

---

## 7. Training & Fine-Tuning

### 7.1 Is Pretrained Sufficient?

**No.** The pretrained models were trained on complete, high-quality equirectangular panoramas from 360-degree cameras. Our input will be synthetic panoramas rendered from LiDAR point clouds with significant coverage gaps and quality degradation. The domain gap is large enough that fine-tuning (or at minimum, domain adaptation) is almost certainly required.

Three pretrained checkpoints are available:
1. `resnet50_rnn__panos2d3d.pth` — 817 PanoContext/Stanford2D3D images, 300 epochs (cuboid only)
2. `resnet50_rnn__st3d.pth` — 18,362 Structured3D images, 50 epochs (general layout, synthetic)
3. `resnet50_rnn__zind.pth` — 20,077 ZInD images, 50 epochs (general layout, real-world)

### 7.2 Training Data Requirements

To fine-tune for our LiDAR-derived panoramas, we would need:
- **Paired data**: LiDAR scans with ground-truth room polygons
- **Panorama rendering pipeline**: Convert each LiDAR scan to a synthetic equirectangular panorama (same conversion we'd use in production)
- **Ground truth labels**: Room corner positions in equirectangular coordinates
- **Estimated quantity**: 200-500 annotated room scans for fine-tuning (based on the demonstrated success with 65 non-cuboid samples)
- **Data collection cost**: Each scan requires a user + LiDAR device + manual ground-truth polygon annotation. Estimated 15-30 minutes per room including annotation.

### 7.3 Training Compute

| Parameter | Value |
|-----------|-------|
| Hardware (original) | 3x NVIDIA GTX 1080 Ti |
| Training time (817 images, 300 epochs) | ~4 hours |
| Training time (18K images, 50 epochs) | ~8-12 hours |
| Fine-tuning (500 images, 100 epochs) | ~1-2 hours on a single T4/L4 |
| Optimizer | Adam, LR=0.0003 (full training) or 5e-5 (fine-tuning) |
| Batch size | 24 (full) or 2 (fine-tuning) |

Fine-tuning is computationally cheap. The expensive part is creating the paired training data.

### 7.4 Fine-Tuning Difficulty

**Moderate-high.** The training scripts are provided and well-documented. The codebase includes custom dataset preparation tutorials. However:

1. Building the LiDAR → panorama rendering pipeline is non-trivial (the preprocessing gap from Section 3).
2. Creating ground-truth annotations requires manual polygon labeling in equirectangular space — no existing tool is designed for this workflow.
3. The domain gap between real 360-degree photos and LiDAR-rendered panoramas may require architectural modifications (e.g., adding a depth channel, modifying the input to handle missing regions).
4. There is no guarantee fine-tuning bridges the gap — the model may need fundamental changes to handle partial coverage.

---

## 8. Maturity & Community

### 8.1 Publication

| Field | Value |
|-------|-------|
| **Paper** | "HorizonNet: Learning Room Layout with 1D Representation and Pano Stretch Data Augmentation" |
| **Venue** | CVPR 2019 (top-tier computer vision conference) |
| **Authors** | Cheng Sun, Chi-Wei Hsiao, Min Sun, Hwann-Tzong Chen (National Tsing Hua University, Taiwan) |
| **arXiv** | [1901.03861](https://arxiv.org/abs/1901.03861) |
| **Citations** | ~350+ (highly cited in room layout estimation) |

### 8.2 GitHub Repository

| Metric | Value |
|--------|-------|
| **URL** | [github.com/sunset1995/HorizonNet](https://github.com/sunset1995/HorizonNet) |
| **Stars** | ~358 |
| **Forks** | ~95 |
| **License** | **MIT** (commercial use OK) |
| **Open issues** | ~33 |
| **Last push** | 2024-02-27 (updated pretrained weight links) |
| **Last code change** | 2023-11-16 (multi-GPU support) |
| **Language** | Python (PyTorch) |

### 8.3 Maintenance & Ecosystem

- **Maintenance**: Low-frequency but not abandoned. Author (sunset1995) is also the author of py360convert and related panorama tools.
- **Community**: Active in panoramic room layout research. HorizonNet is the baseline that LED2-Net and LGT-Net build upon.
- **Production deployments**: No known large-scale production deployments. Primarily used in research.
- **Successors**: LED2-Net (CVPR 2021 Oral) and LGT-Net (CVPR 2022) offer strictly better accuracy with the same input/output format. LED2-Net's differentiable depth rendering loss is particularly relevant since we have depth data.

### 8.4 Dependencies

PyTorch 1.8.1+, Python 3.7.6+, NumPy, SciPy, scikit-learn, OpenCV >=3.1, pylsd-nova, Open3D >=0.7, Shapely. All standard, no exotic dependencies.

---

## 9. Risks & Mitigations

### Risk 1: Incomplete Panorama Coverage (CRITICAL)

**Risk**: RoomScanAlpha scans cover 40-70% of the viewing sphere. HorizonNet was trained on 100% coverage panoramas. Missing regions will produce unreliable boundary predictions at those azimuths, potentially corrupting the entire layout via LSTM state propagation.

**Severity**: High — this is a fundamental input mismatch, not an edge case.

**Mitigation**:
- Inpaint missing regions before inference (LaMa, OpenCV). However, inpainting cannot reliably synthesize architectural boundaries.
- Fine-tune on panoramas with synthetic gaps (data augmentation: randomly black out 30-60% of columns during training). This requires custom training pipeline development.
- Use depth-channel augmented input (render LiDAR depth as a 4th channel) to help the model reason about geometry even where RGB is missing.
- **Verdict**: Mitigation is possible but unproven. Significant R&D risk.

### Risk 2: Manhattan World Constraint

**Risk**: HorizonNet enforces orthogonal walls. Rooms with angled walls, bay windows, or non-90-degree junctions will produce incorrect layouts.

**Severity**: Medium — most residential rooms (~80%) have orthogonal walls, but the 20% that don't will fail silently (producing a confidently wrong rectangular approximation).

**Mitigation**:
- Use the general layout mode (supports arbitrary polygon shapes) but walls within it are still Manhattan-constrained.
- Consider AtlantaNet for non-Manhattan rooms (supports gravity-aligned but non-orthogonal walls).
- Detect failure cases by comparing HorizonNet polygon area against Stage 2's RANSAC floor area — large discrepancies flag non-Manhattan rooms.

### Risk 3: Scale Calibration

**Risk**: HorizonNet assumes a fixed camera height (1.6m) for 3D unprojection. The iPhone/iPad scanning height varies by user (1.0-1.8m for handheld, ~0.3m if placed on a surface). Incorrect height scales all XZ dimensions proportionally.

**Severity**: Medium — produces systematically incorrect room dimensions.

**Mitigation**:
- Use Stage 2's RANSAC floor-ceiling distance as ground truth to calibrate scale.
- Record device height from ARKit's floor plane detection (available in the scan metadata).
- Apply a post-hoc scale correction: `true_dimensions = predicted_dimensions * (true_height / 1.6)`.

### Risk 4: Domain Gap (LiDAR-Rendered vs. Real Panoramas)

**Risk**: Even with complete coverage, a panorama rendered from LiDAR point cloud looks nothing like a real 360-degree photo. Sparse points, patchwork colors, structured dot patterns from the dToF array, and missing textures all differ from training data.

**Severity**: Medium-High — the model has never seen inputs like this. Pretrained weights will likely perform poorly without fine-tuning.

**Mitigation**:
- Fine-tune on LiDAR-rendered panoramas paired with ground-truth layouts.
- Alternatively, render panoramas from RGB keyframes (better visual quality) rather than from the point cloud.
- Consider style transfer or domain adaptation techniques to make synthetic panoramas look more like real 360-degree photos.

### Risk 5: Preprocessing Pipeline Complexity

**Risk**: The conversion pipeline (LiDAR mesh → panorama rendering → Manhattan alignment → HorizonNet inference → 3D unprojection → scale calibration → polygon output) is complex, with multiple failure points and quality-degrading steps.

**Severity**: Medium — each step adds latency, potential errors, and maintenance burden. The conversion pipeline may be harder to build and maintain than the model integration itself.

**Mitigation**:
- Modularize each step with clear interfaces and fallback behaviors.
- Log intermediate results (rendered panorama, alignment quality, confidence scores) for debugging.
- Consider whether alternative approaches (BEV projection, RoomFormer) avoid this conversion entirely.

---

## 10. Recommendation

### Overall Assessment: **Poor Fit** for RoomScanAlpha

### Key Strengths

1. **Output format is exactly what we need**: A closed room polygon plus ceiling height maps directly to Stage 3's output contract with minimal postprocessing.
2. **Extremely fast inference**: ~20ms on GPU, ~1s on CPU. Well within latency budget.
3. **Strong accuracy on clean input**: 88-94% 3D IoU on standard benchmarks with complete panoramas.
4. **Low deployment cost**: ~$0.01-0.06 per prediction on Cloud Run with L4 GPU.
5. **MIT license**: No commercial use restrictions.
6. **Well-understood model**: 5+ years of research, clear successors (LED2-Net, LGT-Net) with strictly better accuracy.

### Key Weaknesses

1. **Critical input mismatch**: Requires complete 360-degree equirectangular panorama. Our scans cover 40-70% of the sphere. The conversion is lossy, complex, and introduces failure modes that don't exist in the original pipeline. This alone makes HorizonNet a poor fit.
2. **Manhattan constraint**: Limits to orthogonal walls only. ~20% of residential rooms will fail.
3. **No depth/point-cloud awareness**: The model uses RGB only. We have rich 3D geometry (LiDAR mesh, depth maps, classified surfaces) that is entirely discarded during the panorama conversion. This is the opposite of playing to our data's strengths.
4. **Unproven on synthetic panoramas**: No published results on panoramas rendered from LiDAR or posed keyframes. The domain gap is a significant unknown.
5. **Preprocessing pipeline complexity**: The conversion pipeline adds 4-5 non-trivial steps, each with its own failure modes.

### Suggested Proof-of-Concept Scope (if selected despite recommendation)

1. **Week 1**: Build a LiDAR → equirectangular rendering pipeline using a hybrid approach (point cloud projection + keyframe warping + simple inpainting for gaps).
2. **Week 2**: Run HorizonNet pretrained on 10 test scans. Evaluate output polygon quality against manually-measured ground truth.
3. **Week 3**: If results are promising, fine-tune on 50 annotated LiDAR-rendered panoramas with synthetic gap augmentation.
4. **Total estimated effort**: 3-4 weeks for POC, 6-8 weeks for production integration.
5. **Go/no-go criteria**: If pretrained HorizonNet on rendered panoramas achieves <70% IoU on 10 test rooms, abandon this path.

### Bottom Line

HorizonNet is an excellent model for its designed use case (complete 360-degree panoramas). But for RoomScanAlpha, it requires discarding our richest data (3D LiDAR geometry) to synthesize a degraded version of data we don't have (complete panoramas). The conversion pipeline is the weakest link, and it's load-bearing. Approaches that consume point clouds or BEV projections directly — like RoomFormer — would leverage our data's actual strengths rather than working around its limitations.

---

## Appendix: Comparison Scorecard

| Metric | Weight | Score (1-5) | Weighted | Justification |
|--------|--------|-------------|----------|---------------|
| **Input compatibility** | 3x | **1** | 3 | Requires complete 360 panorama; we have partial LiDAR mesh. Conversion is lossy and complex — the largest gap of any metric. |
| **Output compatibility** | 3x | **4** | 12 | Produces closed polygon + height directly. Minor postprocessing for scale calibration and coordinate transform. Clean mapping. |
| **Non-rectangular room support** | 3x | **2** | 6 | Supports general polygons but enforces Manhattan constraint (90-degree walls only). L-shapes work; angled/curved walls fail. Performance drops sharply above 8 corners. |
| **Noise/gap tolerance** | 3x | **1** | 3 | Zero built-in tolerance for missing panorama regions. Trained exclusively on complete, high-quality images. LSTM propagates errors from gap columns. Our biggest pain point is its biggest weakness. |
| **Accuracy (IoU)** | 2x | **4** | 8 | 79-94% 3D IoU on benchmarks with clean input. Strong on 4-6 corner rooms, degrades on complex layouts. But these numbers are on complete panoramas — actual performance on our data is unknown. |
| **Corner/edge accuracy** | 2x | **4** | 8 | 0.62-0.76% corner error on benchmarks. Manhattan constraint ensures clean 90-degree corners (a strength for rectangular rooms). |
| **Inference speed** | 2x | **5** | 10 | ~20ms on GPU, ~1s on CPU. Fastest model in its class by an order of magnitude. Trivially meets <10s target. |
| **Vertex AI deployability** | 1x | **4** | 4 | Small model (28M params, 110MB), standard PyTorch, MIT license. Cloud Run with L4 GPU is straightforward. Only complexity is the preprocessing pipeline container. |
| **Fine-tuning feasibility** | 1x | **2** | 2 | Training scripts provided, but creating paired LiDAR-panorama training data is labor-intensive. Fine-tuning on partial panoramas is uncharted territory — may require architectural changes. |
| **Maturity & support** | 1x | **3** | 3 | CVPR 2019, MIT license, 358 stars, well-cited. Low-frequency maintenance. No production deployments known. Successors (LED2-Net, LGT-Net) are strictly better. |
| **Implementation effort** | 1x | **2** | 2 | Model integration is easy. But the panorama conversion pipeline (rendering + alignment + inpainting + calibration) is 3-4 weeks of work with significant R&D risk. Total: 6-8 weeks to production. |
| **GPU cost per prediction** | 1x | **5** | 5 | $0.01-0.06 per prediction on Cloud Run L4. CPU-only is viable at ~$0.003/prediction. Negligible cost. |
| **Training/fine-tuning cost** | 1x | **3** | 3 | Compute is cheap (~$10-50 for fine-tuning). But data collection (200-500 annotated LiDAR scans with panorama rendering + ground truth polygons) is the real cost — estimated 100-200 person-hours. |
| | | | | |
| **Weighted Total** | | | **69/120** | Below the 72-point minimum viable threshold |

---

*Evaluation prepared for RoomScanAlpha DNN comparison. See `COMPARISON_FRAMEWORK.md` for scoring criteria and `SCORECARD.md` for cross-candidate comparison.*
