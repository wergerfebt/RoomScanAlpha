# BEV-Based DNN Approaches for Room Layout Estimation

> **Agent C Evaluation** — Technology comparison for RoomScanAlpha Stage 3 replacement
> Generated: 2026-03-27

---

## 1. Executive Summary

BEV (Bird's-Eye-View) DNN methods project 3D point clouds vertically onto a 2D density map (typically 256x256 pixels), then feed that image into a deep network that directly predicts room polygons as ordered vertex sequences. This family of approaches has become the dominant paradigm for indoor floorplan reconstruction since 2019, with eight major methods published at top venues (ICCV, CVPR, NeurIPS, ECCV). The current state-of-the-art, CAGE (NeurIPS 2025), achieves 99.1% Room F1, 91.7% Corner F1, and 89.3% Angle F1 on the Structured3D benchmark at 0.01s inference per scene. BEV methods are strong candidates for RoomScanAlpha because our PLY mesh vertices can be projected to a density map with ~30 lines of code — no panorama stitching, no camera model, no equirectangular reprojection. The output is ordered polygon vertices per room, which maps directly to Stage 3's required closed 2D polygon. The primary risk is the synthetic-to-real domain gap: all models are trained on Structured3D (synthetic renders), and published cross-dataset transfer experiments show Corner F1 dropping from 91.7% to 76.7% on real-world SceneCAD data without fine-tuning. The two most promising specific methods are **RoomFormer** (CVPR 2023 — mature, MIT-licensed, battle-tested) and **CAGE** (NeurIPS 2025 — current SOTA accuracy, same inference speed, but less mature).

---

## 2. Architecture & How It Works

### 2.1 The General BEV Pipeline

All modern BEV floorplan methods share a common three-stage pipeline:

```
3D Point Cloud
    │
    ▼
[BEV Projection] ─── Project vertices onto XZ plane ─── 256x256 density map
    │                   (single-channel grayscale)
    ▼
[DNN Backbone + Decoder] ─── Extract features ─── Predict room polygons
    │                         (ResNet-50 or Swin-V2)
    ▼
[Output] ─── Ordered (x,y) corner coordinates per room polygon
```

**BEV density map construction** (consistent across all methods):

1. Take all 3D points and project onto the horizontal plane (drop the gravity axis)
2. Compute axis-aligned bounding box, pad by ~2.5% per edge, extend to square
3. Rasterize into a 256x256 grid: each pixel value = count of 3D points in that cell
4. Normalize to [0, 1] by dividing by the maximum count

Walls appear as bright lines because they create dense vertical stacks of points that project onto narrow bands. Furniture and floor surfaces create diffuse fills. This simple representation is remarkably effective — no multi-channel encoding (height, normals, occupancy) has been shown to improve over single-channel density for indoor floorplan tasks.

### 2.2 Method Survey (Chronological)

| Method       | Year | Venue   | Approach                         | Room F1 | Corner F1 | Angle F1 | Inference |
|-------------|------|---------|----------------------------------|---------|-----------|----------|-----------|
| Floor-SP    | 2019 | ICCV    | Mask R-CNN + shortest path       | 88.5    | 76.0      | 75.0     | 785s      |
| MonteFloor  | 2021 | ICCV    | MCTS + metric network            | 95.0    | 82.5      | 80.5     | 71s       |
| HEAT        | 2022 | CVPR    | Transformer corner + edge graph  | 95.4    | 82.5      | 78.3     | 0.11s     |
| RoomFormer  | 2023 | CVPR    | Deformable DETR, two-level query | 97.3    | 87.2      | 81.2     | 0.01s     |
| SLIBO-Net   | 2023 | NeurIPS | Slicing box decomposition        | 98.4    | 85.4      | 84.4     | 0.17s     |
| PolyRoom    | 2024 | ECCV    | Room-aware Transformer           | 98.3    | 90.2      | 85.2     | 0.02s     |
| FRI-Net     | 2024 | ECCV    | Room-wise implicit functions     | 99.1    | 87.8      | 86.9     | 0.09s     |
| **CAGE**    | 2025 | NeurIPS | Directed edge + denoising        | **99.1**| **91.7**  | **89.3** | **0.01s** |

All metrics on Structured3D benchmark. Floor-SP and MonteFloor are too slow for production use. HEAT outputs a planar graph, not room polygons. The field has clearly converged: modern methods achieve >98% Room F1 at sub-second inference.

### 2.3 Deep Dive: RoomFormer (CVPR 2023) — Best-Established

**Paper:** "Connecting the Dots: Floorplan Reconstruction Using Two-Level Queries"
**GitHub:** [ywyue/RoomFormer](https://github.com/ywyue/RoomFormer) — 287 stars, MIT license

**Architecture:**

- **Backbone:** ResNet-50 extracting multi-scale features from last 3 stages + 1 additional via stride-2 conv
- **Encoder:** 6-layer Deformable Transformer encoder (256 channels, multi-scale deformable self-attention)
- **Decoder:** 6-layer Deformable Transformer decoder with two-level queries:
  - Level 1: M = 20 room polygon queries (each represents a potential room)
  - Level 2: N = 40 corner queries per room (ordered vertices of the room polygon)
  - FFN heads classify each query: room-exists / corner-exists / padding
- **Differentiable rasterization** module (from BoundaryFormer) provides a rasterization loss that supervises the overall polygon shape, not just individual corners

**Loss functions:**

| Loss | Weight | Purpose |
|------|--------|---------|
| L_cls (cross-entropy) | λ = 2 | Room/corner existence classification |
| L_coord (L1) | λ = 5 | Corner coordinate regression |
| L_ras (Dice) | λ = 1 | Rasterized polygon shape matching |

**Inference pipeline:**

1. Construct 256x256 density map from point cloud
2. Forward pass through backbone + encoder + decoder (~0.01s on GPU)
3. Filter room queries by classification score > threshold
4. For each valid room, filter corner queries by classification score
5. Output: variable-length list of (x, y) corner coordinates per room

**Key strengths:** End-to-end, single-stage, no post-processing needed. Handles variable numbers of rooms and variable numbers of corners per room. Directly outputs polygon vertices.

### 2.4 Deep Dive: CAGE (NeurIPS 2025) — Current SOTA

**Paper:** "CAGE: Continuity-Aware edGe Network Unlocks Robust Floorplan Reconstruction"
**GitHub:** [ee-Liu/CAGE](https://github.com/ee-Liu/CAGE) — 15 stars

**Architecture:**

- **Backbone:** Swin Transformer V2 (heavier than ResNet-50 but better feature extraction)
- **Key innovation:** Edge-centric formulation — predicts directed edge segments (wall segments) rather than corners
  - Each edge: e^n = (p1^n, p2^n, c^n) where p1, p2 are endpoints and c is a binary validity label
  - Directed edges enforce geometric continuity: the end of one edge is the start of the next
  - This naturally produces watertight, topologically valid room boundaries
- **Dual-query Transformer decoder:** Integrates perturbed queries (denoising-based augmentation) with latent queries in a joint decoder
- **No post-processing:** Edge direction and continuity constraints eliminate the need for polygon cleanup

**Loss functions:**

| Loss | Purpose |
|------|---------|
| BCE | Edge validity classification |
| L1 | Edge endpoint coordinate regression |
| Dice | Rasterized shape matching |
| Denoising | Regularization via perturbed query reconstruction |

**Why CAGE outperforms:** Corner-centric methods (RoomFormer, PolyRoom) predict corners independently, then connect them. If a corner is missed or misplaced, the polygon breaks. Edge-centric prediction ensures each wall segment is a continuous directed entity — the polygon is structurally guaranteed to close.

### 2.5 Deep Dive: PolyRoom (ECCV 2024) — Best Corner Accuracy Before CAGE

**Paper:** "PolyRoom: Room-aware Transformer for Floorplan Reconstruction"
**GitHub:** [3dv-casia/PolyRoom](https://github.com/3dv-casia/PolyRoom) — 87 stars

**Architecture:**

- **Backbone:** ResNet-50 (same as RoomFormer)
- **Uniform sampling representation:** Each room polygon = N=40 uniformly sampled vertices along the contour. Each vertex carries a binary corner label. This enables dense supervision along wall segments, not just at corners.
- **Room-aware query initialization:** Pretrained Mask2Former predicts room instance masks, which are sampled into N vertices as initial queries (better than random initialization)
- **Room-aware self-attention:** Splits attention into intra-room (corners within one room attend to each other) and inter-room (rooms attend to neighboring rooms). Reduces complexity from O((MN)^2) to O(M^2 + N^2).
- **Post-processing:** Vertex selection via probability threshold (0.01) + angle constraints + Douglas-Peucker simplification

**Loss functions:**

| Loss | Weight | Purpose |
|------|--------|---------|
| L_cls (CE) | λ = 2 | Corner classification |
| L_coord (L1) | λ = 5 | Vertex coordinate regression |
| L_ang | λ = 1 | Angle regularization |
| L_ras (Dice) | λ = 1 | Rasterized shape matching |

**Trade-off vs. CAGE:** PolyRoom's dense vertex supervision provides strong wall accuracy, but its corner classification step can miss subtle corners. CAGE's edge formulation avoids this. However, PolyRoom requires a two-stage training (Mask2Former pre-training + main training) adding complexity.

### 2.6 Notable Mention: FloorSAM (2025) — Zero-Shot

**GitHub:** [Silentbarber/FloorSAM](https://github.com/Silentbarber/FloorSAM) — 16 stars

FloorSAM uses SAM (Segment Anything Model) for zero-shot room segmentation — no task-specific training. Pipeline: ceiling-height point filtering → adaptive density map → SAM with generated prompt points → contour extraction + regularization. Key advantage: no domain gap because no domain-specific training. Key limitation: immature (code partially released, metrics not on standard benchmarks). Worth monitoring but not production-ready.

---

## 3. Input Compatibility with RoomScanAlpha

### 3.1 What BEV Models Expect

All BEV floorplan models expect a **single-channel 256x256 grayscale image** — a density map where pixel intensity represents the count of 3D points projecting into that cell. That's it. No RGB. No depth. No normals. No semantic labels.

Some notes on construction:
- Points are typically filtered to a wall-height band (e.g., 0.5m–2.5m above floor) to suppress floor/ceiling clutter and emphasize wall structure
- The bounding box is padded and squared so the entire room fits with margin
- Normalization is min-max to [0, 1]

### 3.2 What RoomScanAlpha Has

| Data Source | Available | Useful for BEV? |
|-------------|-----------|-----------------|
| PLY vertex positions (Nx3, meters) | Yes | **Primary input** — project XZ directly |
| Per-face ARKit classifications | Yes | Can filter to wall/ceiling/door vertices only |
| Camera poses (4x4 transforms) | Yes | Not needed for BEV projection |
| Depth maps (per-keyframe) | Yes | Not needed — we already have 3D vertices |
| RGB keyframes | Yes | Not needed for BEV |
| Point cloud (from mesh vertices) | Derivable | Same as PLY vertices |

### 3.3 Gap Analysis: PLY Mesh → BEV Density Map

**The conversion is almost trivially simple.** Our PLY mesh vertices are already 3D points in meters (ARKit Y-up coordinate system). The BEV projection is:

```python
def mesh_to_bev(mesh: ParsedMesh, resolution: int = 256) -> np.ndarray:
    """Project classified mesh vertices to a BEV density map."""
    # Filter to structural vertices only (wall=1, ceiling=3, door=7, window=6)
    structural_ids = set()
    for cid in [1, 3, 6, 7]:  # skip floor (2) — adds diffuse noise
        group = mesh.classification_groups.get(cid)
        if group:
            structural_ids.update(group.vertex_ids)

    if not structural_ids:
        # Fallback: use all non-furniture vertices
        structural_ids = set(range(len(mesh.positions)))

    pts = mesh.positions[list(structural_ids)]
    xz = pts[:, [0, 2]]  # drop Y (height axis in ARKit)

    # Compute bounds, pad, square
    mn, mx = xz.min(axis=0), xz.max(axis=0)
    pad = 0.025 * (mx - mn).max()
    mn -= pad; mx += pad
    span = max(mx[0] - mn[0], mx[1] - mn[1])
    center = (mn + mx) / 2
    mn = center - span / 2; mx = center + span / 2

    # Rasterize
    grid = np.zeros((resolution, resolution), dtype=np.float32)
    indices = ((xz - mn) / (mx - mn) * (resolution - 1)).astype(int)
    indices = np.clip(indices, 0, resolution - 1)
    for i in range(len(indices)):
        grid[indices[i, 1], indices[i, 0]] += 1  # row=Z, col=X

    # Normalize
    if grid.max() > 0:
        grid /= grid.max()

    return grid  # 256x256 float32, values [0, 1]
```

**Conversion quality assessment:**

| Factor | Impact | Notes |
|--------|--------|-------|
| We already have 3D points | Excellent | No depth estimation, no multi-view reconstruction needed |
| ARKit classifications available | Bonus | Can filter to structural vertices for cleaner signal |
| Single-room scans | Neutral | Models expect multi-room; we just get M=1 room queries |
| Partial scan coverage | Risk | LiDAR gaps → missing lines in density map → possible incomplete walls |
| Furniture occlusion | Moderate risk | Furniture vertices create noise, but wall-height filtering helps |

**Key advantage over HorizonNet/panorama approaches:** No panorama stitching, no equirectangular reprojection, no camera model needed. We skip the entire image-domain conversion and go directly from 3D geometry to 2D density.

### 3.4 Non-Rectangular Room Support

All modern BEV methods (RoomFormer, CAGE, PolyRoom, FRI-Net) natively support non-rectangular rooms:

- **Variable corner count:** RoomFormer uses N=40 corner queries per room, filtered by classification score. A room can have 3 to 40 corners.
- **No Manhattan constraint:** Unlike LayoutNet, no axis-alignment is assumed. Walls can be at any angle.
- **Structured3D training data** includes L-shaped, T-shaped, and irregular rooms across 21,835 room instances.
- **CAGE's edge formulation** is particularly strong for non-rectangular rooms because each wall is an independent directed edge — arbitrary angles are first-class.

This is a significant advantage over our failed geometric approaches, several of which assumed or biased toward rectangularity.

---

## 4. Output Compatibility with RoomScanAlpha

### 4.1 What Stage 3 Must Produce

From `compute_room_metrics()` and the `scanned_rooms` schema:

| Output | Format | Source |
|--------|--------|--------|
| Room floor boundary | Closed 2D polygon (ordered XZ vertices, meters) | → floor_area, perimeter |
| Ceiling height | Single float (meters) | → ceiling_height_ft |
| Wall surfaces | Per-wall quads from polygon extrusion | → wall_area |

### 4.2 What BEV Models Output

**RoomFormer:** Variable-length list of ordered (x, y) corner coordinates per room, in pixel space (0–255).

**CAGE:** Ordered sequence of directed edge segments per room — each edge has two endpoints. Adjacent edges share endpoints, forming a closed polygon. Also in pixel space.

**PolyRoom:** N=40 uniformly sampled vertices per room, each with a corner probability. Post-processing extracts true corners via thresholding + Douglas-Peucker.

### 4.3 Postprocessing: Model Output → Stage 3 Requirements

**Step 1 — Pixel-to-meter coordinate recovery:**

The BEV projection establishes a mapping from meters to pixels. Inverting it:

```python
corner_meters_xz = corner_pixels / 255.0 * (bbox_max - bbox_min) + bbox_min
```

This gives us XZ coordinates in meters — exactly what Stage 3's wall extrusion code (`_add_wall_quad`) already consumes.

**Step 2 — Ceiling height:**

BEV models do not predict ceiling height (the Y axis is collapsed in the projection). We still need the existing `_compute_ceiling_height()` from the geometric pipeline:

```python
ceiling_height_m = max(ceiling_Y) - min(floor_Y)  # from classified vertices
```

This is the simplest and most reliable measurement in the current pipeline — it never failed. It remains unchanged.

**Step 3 — Polygon closure validation:**

Verify the output polygon is closed (first vertex ≈ last vertex or explicitly close it). Check winding order (CCW). Both RoomFormer and CAGE produce closed polygons by design — CAGE guarantees this structurally via directed edge continuity.

**Step 4 — Metric computation:**

With a closed XZ polygon + ceiling height, the existing metric functions work unchanged:

| Metric | Computation |
|--------|------------|
| floor_area_sqft | Shoelace formula on XZ polygon × SQM_TO_SQFT |
| perimeter_linear_ft | Sum of edge lengths × M_TO_FT |
| wall_area_sqft | perimeter × ceiling_height × SQM_TO_SQFT |
| ceiling_height_ft | ceiling_height_m × M_TO_FT |

**Output compatibility is excellent.** The model output (ordered polygon vertices) is a strict superset of what Stage 3 needs. No heatmap decoding, no contour tracing, no post-processing segmentation masks. The only conversion is a linear pixel-to-meter rescaling.

---

## 5. Accuracy & Performance

### 5.1 Structured3D Benchmark (Synthetic)

| Method | Room F1 | Corner F1 | Angle F1 | Inference |
|--------|---------|-----------|----------|-----------|
| RoomFormer | 97.3 | 87.2 | 81.2 | 0.01s |
| SLIBO-Net | 98.4 | 85.4 | 84.4 | 0.17s |
| PolyRoom | 98.3 | 90.2 | 85.2 | 0.02s |
| FRI-Net | 99.1 | 87.8 | 86.9 | 0.09s |
| **CAGE** | **99.1** | **91.7** | **89.3** | **0.01s** |

### 5.2 SceneCAD Benchmark (Real-World RGB-D Scans)

| Method | Room IoU | Corner F1 | Angle F1 |
|--------|----------|-----------|----------|
| Floor-SP | 91.6 | 87.6 | 73.1 |
| RoomFormer | 91.7 | 88.8 | 75.8 |
| PolyRoom | 92.8 | 78.0 | 78.0 |
| CAGE | **93.7** | **90.6** | **79.2** |

These SceneCAD numbers are with models fine-tuned on SceneCAD training data. Cross-dataset (train on Structured3D only, test on SceneCAD) shows significant degradation.

### 5.3 Cross-Dataset Generalization (Domain Gap)

CAGE's published cross-dataset experiment (train Structured3D → test SceneCAD, no fine-tuning):

| Metric | In-Domain (S3D) | Cross-Dataset (SceneCAD) | Drop |
|--------|-----------------|--------------------------|------|
| Room IoU | ~99 | 85.6 | -13.4 |
| Corner F1 | 91.7 | 76.7 | -15.0 |
| Angle F1 | 89.3 | 61.6 | -27.7 |

This is the critical risk for RoomScanAlpha. Our LiDAR scans will exhibit different noise characteristics than either Structured3D (synthetic) or SceneCAD (Kinect RGB-D). Fine-tuning on our data is essential.

### 5.4 Complex Room Shapes

BEV methods handle non-rectangular rooms well on Structured3D because the training set includes them. The Angle F1 metric specifically measures wall-angle accuracy — CAGE's 89.3% indicates strong performance on non-90° corners. However, extremely irregular rooms (curved walls, >8 corners) are underrepresented in training data.

### 5.5 Known Failure Modes

1. **Thin walls between adjacent rooms:** Can merge into a single line in the density map, confusing the model about room boundaries. Less relevant for our single-room scans.
2. **Large open spaces:** Very large rooms with sparse wall points produce faint density lines. Mobile LiDAR has limited range (~5m effective), so large rooms may have gaps.
3. **Glass walls / open doorways:** No physical structure to produce points. The model may hallucinate a wall or leave a gap.
4. **Heavy furniture against walls:** Creates thick density bands that shift the predicted wall position inward. Height filtering (using only points between 0.5m–2.5m) mitigates this for floor-standing furniture but not wall-mounted cabinets.
5. **Partial scans:** If the user doesn't scan a full 360° of the room, one or more walls will be missing from the density map entirely.

### 5.6 Inference Latency

| Method | GPU Time | CPU Estimate | Meets <10s Target? |
|--------|----------|-------------|-------------------|
| RoomFormer | 0.01s | 0.5–2s | Yes |
| CAGE | 0.01s | 1–3s | Yes |
| PolyRoom | 0.02s | 1–3s | Yes |

All viable methods comfortably meet the <10s per-room target, even on CPU. The BEV projection itself adds <0.1s. Total pipeline (projection + inference + coordinate recovery) would be <5s on a T4 GPU.

---

## 6. Integration with GCP / Vertex AI

### 6.1 Deployment Architecture Options

**Option A: Vertex AI Endpoint (managed)**

```
Cloud Tasks → Processor (Cloud Run)
                  │
                  ├── Stage 1: PLY parse (existing)
                  ├── BEV projection (new, ~30 lines)
                  ├── Vertex AI Predict call (gRPC)
                  │      └── Model endpoint (T4 GPU)
                  ├── Coordinate recovery (new, ~20 lines)
                  ├── Ceiling height (existing)
                  └── Metric computation (existing)
```

- Pre-built PyTorch GPU containers available (PyTorch 2.4, CUDA 12.x)
- Deploy via TorchServe with custom handler for density map preprocessing
- Auto-scaling with min/max replicas
- Machine type: `n1-standard-4` + `NVIDIA_TESLA_T4` (16GB VRAM, cheapest GPU)

**Option B: ONNX Runtime in Cloud Run (serverless)**

```
Cloud Tasks → Processor (Cloud Run, CPU)
                  │
                  ├── Stage 1: PLY parse
                  ├── BEV projection
                  ├── ONNX Runtime inference (CPU)
                  ├── Coordinate recovery
                  └── Metric computation
```

- Export model to ONNX format
- Add `onnxruntime` to processor requirements.txt
- No separate GPU service needed
- Inference ~1-3s on CPU — still well within the <10s target
- Simplest deployment: no new infrastructure, no GPU costs

**Option C: Cloud Run with GPU (hybrid)**

- Cloud Run now supports GPU instances (L4 GPU)
- Keep everything in one service
- Pay per request (GPU spins down when idle)

### 6.2 Recommended: Option B (ONNX in Cloud Run)

For our single-room, low-throughput use case, ONNX Runtime on CPU is the pragmatic choice:

| Factor | Vertex AI Endpoint | ONNX in Cloud Run |
|--------|-------------------|-------------------|
| Latency | ~0.01s (GPU) | ~1-3s (CPU) |
| Cold start | GPU spin-up: 30-60s | Already warm (processor is running) |
| Cost | ~$0.35/hr minimum (T4) | $0 marginal (CPU already allocated) |
| Complexity | New service, IAM, endpoint management | pip install onnxruntime |
| Scaling | Managed auto-scale | Existing Cloud Run scaling |

At our current volume (room scans, not real-time), the 1-3s CPU inference is perfectly acceptable, and the deployment is trivially simple.

### 6.3 Cost Estimates

**Option B (ONNX in Cloud Run):**
- Marginal cost per prediction: ~$0.00 (CPU time included in existing Cloud Run allocation)
- One-time: model export + integration: ~1-2 engineering days
- Storage: ONNX model file ~100-300MB in container image

**Option A (Vertex AI, if needed later):**
- T4 GPU endpoint: ~$0.35/hr (on-demand), ~$0.17/hr (committed)
- At 100 scans/day: ~$0.004 per prediction (amortized)
- At 10 scans/day: ~$0.04 per prediction (amortized)

### 6.4 Container Packaging

For ONNX option, the only additions to the existing processor Dockerfile:

```dockerfile
# Add to existing requirements.txt
RUN pip install onnxruntime==1.18.0

# Add ONNX model file
COPY models/roomformer.onnx /app/models/
```

Model file size: ~100-300MB. This increases the container image but stays well within Cloud Run limits (32GB max).

---

## 7. Training & Fine-Tuning

### 7.1 Pretrained Model Availability

| Method | Pretrained Weights | Dataset | Download |
|--------|-------------------|---------|----------|
| RoomFormer | Yes | Structured3D, SceneCAD | Google Drive (repo README) |
| CAGE | Yes | Structured3D, SceneCAD | Google Drive (repo README) |
| PolyRoom | Yes | Structured3D, SceneCAD | Google Drive (Mask2Former + PolyRoom) |
| FRI-Net | Yes | Structured3D, SceneCAD | Included in repo |

All top methods provide pretrained weights. The Structured3D-pretrained model can be used as-is for initial testing.

### 7.2 Fine-Tuning on Our LiDAR Data

**Why fine-tuning is necessary:**

The domain gap is real. Structured3D density maps are generated from synthetic renders with perfect geometry. Our ARKit LiDAR scans produce density maps with:
- Irregular point density (dense near scanner, sparse at range)
- Coverage gaps (walls behind furniture, areas user didn't scan)
- Classification noise (furniture vertices mixed with wall vertices)
- Single-room scans (vs. multi-room floor plans in training data)

**Ground truth generation strategy:**

We have a bootstrapping advantage: our geometric pipeline (Stage 2+3), while imperfect, produces reasonable polygons for ~60-70% of scans (simple rectangular rooms). These can serve as pseudo ground truth:

1. Run existing pipeline on all historical scans
2. Filter to scans where geometric output passed QA (manual or heuristic)
3. Use these as training pairs: (density_map, polygon_vertices)
4. Fine-tune pretrained model on this data

**Data requirements:**

| Phase | Scans Needed | Source |
|-------|-------------|--------|
| Initial fine-tuning | 200–500 | Historical scans with verified polygons |
| Production quality | 1,000–2,000 | Accumulated over time with correction loop |

**Compute requirements:**

RoomFormer training specs (from paper):
- 500 epochs on Structured3D (3,000 scenes)
- Single TITAN RTX (24GB)
- Training time: ~24-48 hours (estimated from epoch count and batch size)

Fine-tuning on 200-500 rooms would be much faster:
- ~50-100 epochs sufficient (weights already pretrained)
- Single T4 or V100: ~2-8 hours
- Estimated cost: $5-20 on Vertex AI Training or similar

### 7.3 Self-Supervised Improvement Loop

Once deployed, the model can improve over time:

1. Model predicts polygon for new scan
2. User reviews/edits polygon in-app (future feature)
3. Corrected polygon becomes new training sample
4. Periodic fine-tuning batch job

This is a natural fit for the cloud pipeline — training data accumulates automatically.

---

## 8. Maturity & Community

### 8.1 RoomFormer

| Attribute | Value |
|-----------|-------|
| Published | CVPR 2023 (top-tier venue) |
| GitHub stars | 287 |
| Last commit | 2025-04-02 |
| License | MIT (commercial use OK) |
| Open issues | ~15 |
| Dependencies | PyTorch, Deformable-DETR, detectron2 |
| Code quality | Clean, well-documented, reproducible |
| Citations | 100+ (Google Scholar) |
| Known deployments | Academic benchmarks; no known production systems |

### 8.2 CAGE

| Attribute | Value |
|-----------|-------|
| Published | NeurIPS 2025 (top-tier venue) |
| GitHub stars | 15 |
| Last commit | 2025-11-19 |
| License | Not specified (risk for commercial use) |
| Open issues | ~3 |
| Dependencies | PyTorch, Swin-V2, mmdet |
| Code quality | Research-grade; less polished than RoomFormer |
| Citations | New — limited citations |
| Known deployments | None known |

### 8.3 PolyRoom

| Attribute | Value |
|-----------|-------|
| Published | ECCV 2024 (top-tier venue) |
| GitHub stars | 87 |
| Last commit | 2025-05-15 |
| License | Not specified |
| Dependencies | PyTorch, Mask2Former, Deformable-DETR |
| Code quality | Good; two-stage training adds complexity |
| Known deployments | None known |

### 8.4 Assessment

RoomFormer is the clear winner on maturity: MIT license, most stars, actively maintained, clean codebase. CAGE has better accuracy but is too new and lacks a commercial license. For a production system, **RoomFormer is the safer bet** with CAGE as a future upgrade path once it matures.

---

## 9. Risks & Mitigations

### Risk 1: Synthetic-to-Real Domain Gap (HIGH)

**Risk:** All models are trained on Structured3D (synthetic). Cross-dataset Corner F1 drops ~15 points. Our mobile LiDAR data is noisier than even SceneCAD (Kinect RGB-D).

**Mitigation:**
- Fine-tune on 200-500 real scans using geometric pipeline output as pseudo ground truth
- Use ARKit classifications to filter density map to structural vertices only (reduces noise)
- Start with RoomFormer's SceneCAD-pretrained weights (closer to real-world than Structured3D weights)
- Implement confidence scoring + geometric fallback for low-confidence predictions

### Risk 2: Partial Scan Coverage (MEDIUM-HIGH)

**Risk:** Users may not scan all walls (didn't turn 360°, furniture blocking access). Missing walls = missing lines in density map. Model may hallucinate walls or produce open polygons.

**Mitigation:**
- Augment training data with simulated partial scans (randomly drop wall segments from density maps)
- Add scan-completeness check: if <3 distinct wall-normal directions detected in Stage 2, warn user to continue scanning
- Post-process: if predicted polygon is not closed or has edges >5m (unreasonably long), fall back to geometric pipeline

### Risk 3: Single-Room vs. Multi-Room Training Mismatch (MEDIUM)

**Risk:** Models are trained on multi-room floor plans (3-10 rooms per scene). Our input is always a single room. The model may be confused by the simpler topology or waste capacity on room-separation logic.

**Mitigation:**
- Set M=1 (single room query) during inference — skip multi-room decoding
- Fine-tuning on single-room data naturally adapts the model
- Alternatively: crop multi-room Structured3D scenes to individual rooms for training

### Risk 4: Furniture Creates False Wall Signal (MEDIUM)

**Risk:** Large furniture (bookshelves, kitchen cabinets) against walls creates thick density bands that shift predicted wall position inward, reducing floor area accuracy.

**Mitigation:**
- Height-band filtering: only use points between 0.5m–2.5m above floor (removes floor-standing furniture legs and tabletops)
- ARKit classification filtering: exclude table (4) and seat (5) classified vertices from the density map
- Fine-tuning on real scans with furniture naturally teaches the model to distinguish wall from furniture density patterns

### Risk 5: Model Export / ONNX Conversion Issues (LOW)

**Risk:** Deformable attention operators may not export cleanly to ONNX. Custom CUDA kernels in Deformable-DETR are not standard ONNX ops.

**Mitigation:**
- RoomFormer community has reported successful ONNX export (check GitHub issues)
- Alternative: use TorchScript export instead of ONNX
- Fallback: serve via TorchServe on Vertex AI if ONNX fails (Option A deployment)
- Test export early in the proof-of-concept phase

---

## 10. Recommendation

### Overall Assessment: **Strong Fit**

BEV-based DNN approaches are the strongest candidate for replacing Stage 3's geometric pipeline. The input conversion is trivial (project mesh vertices to XZ, rasterize), the output is exactly what we need (ordered polygon vertices), and the accuracy on standard benchmarks is excellent.

### Key Strengths for RoomScanAlpha

1. **Input alignment is near-perfect.** We already have 3D point clouds. The BEV projection is ~30 lines of NumPy. No panorama stitching, no camera model, no equirectangular math.
2. **Output alignment is near-perfect.** Model produces ordered polygon vertices → directly usable for floor_area, perimeter, wall_area computation. Only ceiling height needs the existing geometric approach (which works reliably).
3. **Non-rectangular rooms handled natively.** Variable corner count, no Manhattan assumption, trained on diverse room shapes.
4. **Sub-second inference.** Even on CPU (ONNX), inference is 1-3s. On GPU, 0.01s. Well within our processing budget.
5. **Natural fine-tuning path.** We can generate BEV density maps from our existing scans and use geometric pipeline outputs as pseudo ground truth.

### Key Weaknesses for RoomScanAlpha

1. **Domain gap is the primary risk.** Pretrained models will underperform on our LiDAR data without fine-tuning. Budget 2-4 weeks for data preparation and fine-tuning.
2. **Partial scans.** Models assume complete room visibility. Partial scans need augmentation strategy.
3. **No ceiling height from BEV.** The Y-axis is collapsed. We still need the geometric ceiling height computation (but this is the most reliable part of the existing pipeline).

### Recommended Architecture: RoomFormer (CVPR 2023)

While CAGE achieves higher accuracy, **RoomFormer is the recommended starting point** because:

- MIT license (commercial use clear)
- Mature codebase (287 stars, 2+ years of community use)
- ResNet-50 backbone (lighter, easier to export to ONNX than Swin-V2)
- Pretrained weights for both Structured3D and SceneCAD
- Same inference speed as CAGE (0.01s)
- Upgrade path to CAGE later if/when it matures and clarifies licensing

### Proof-of-Concept Scope

**Week 1: Validate input pipeline**
- Implement `mesh_to_bev()` projection function
- Generate density maps from 10-20 historical scans
- Visually inspect: do walls appear as clear lines?

**Week 2: Run pretrained model**
- Load RoomFormer Structured3D pretrained weights
- Run inference on our density maps
- Evaluate: does it produce reasonable polygons? Compare to Stage 3 geometric output.
- Test ONNX export

**Week 3: Fine-tune**
- Prepare training set: 200+ scans with geometric pipeline output as pseudo ground truth
- Fine-tune RoomFormer on our data (50-100 epochs)
- Evaluate improvement on held-out scans

**Week 4: Integrate**
- Add ONNX model to processor pipeline
- Implement confidence-based fallback to geometric pipeline
- Deploy to staging, run A/B comparison

---

## Scorecard

| Metric | Weight | Score | Justification |
|--------|--------|-------|---------------|
| **Input compatibility** | 3x | **5** | PLY vertices → XZ projection → density map is ~30 lines of NumPy. No lossy conversion. ARKit classifications enable structural filtering. The most natural input mapping of any approach. |
| **Output compatibility** | 3x | **5** | Model outputs ordered polygon vertices — exactly what Stage 3 needs. Linear pixel-to-meter rescaling. Ceiling height still from geometric pipeline (reliable). No heatmap decoding or contour tracing. |
| **Non-rectangular room support** | 3x | **5** | Variable corner count (up to 40 per room). No Manhattan assumption. Trained on 21,835 rooms including L-shapes, T-shapes, irregular layouts. CAGE's edge formulation handles arbitrary angles as first-class. |
| **Noise/gap tolerance** | 3x | **3** | Strong on furniture noise (height filtering + classification filtering). Moderate on coverage gaps — models assume complete visibility. Partial scans are the main vulnerability. Fine-tuning with augmented partial scans should improve this, but unproven on our data. |
| **Accuracy — IoU** | 2x | **4** | Room F1 99.1% (CAGE) / 97.3% (RoomFormer) on Structured3D. 91.7-93.7% Room IoU on real-world SceneCAD. Cross-dataset drop is significant but addressable with fine-tuning. Docked one point for domain gap uncertainty. |
| **Corner/edge accuracy** | 2x | **4** | Corner F1 91.7% (CAGE) / 87.2% (RoomFormer) on Structured3D. Drops to 76.7-90.6% on real-world data. Strong but not yet validated on mobile LiDAR. |
| **Inference speed** | 2x | **5** | 0.01s on GPU, 1-3s on CPU via ONNX. Total pipeline (projection + inference + recovery) < 5s. Far exceeds the <10s target. |
| **Vertex AI deployability** | 1x | **5** | Pre-built PyTorch GPU containers. But even simpler: ONNX Runtime in existing Cloud Run container — zero new infrastructure. Model is ~100-300MB. |
| **Fine-tuning feasibility** | 1x | **4** | Pretrained weights available. Standard PyTorch training loop. 200-500 scans sufficient for initial fine-tuning. Pseudo ground truth from geometric pipeline. Single GPU, 2-8 hours. Docked one point: deformable attention makes training setup non-trivial. |
| **Maturity & support** | 1x | **4** | RoomFormer: MIT, 287 stars, CVPR 2023, actively maintained. CAGE: NeurIPS 2025 but only 15 stars, no license specified. PolyRoom: ECCV 2024, 87 stars. Well-established research area with clear SOTA progression. No known production deployments. |
| **Implementation effort** | 1x | **4** | BEV projection: 1 day. Model integration: 2-3 days. ONNX export: 1 day. Fine-tuning pipeline: 3-5 days. Total: ~2-3 weeks to production. Docked one point for deformable attention ONNX export uncertainty. |
| **GPU cost per prediction** | 1x | **5** | ONNX on CPU: $0.00 marginal (runs in existing Cloud Run container). Vertex AI T4 if needed: ~$0.004/prediction at 100 scans/day. Negligible either way. |
| **Training/fine-tuning cost** | 1x | **4** | Initial fine-tuning: $5-20 (single T4, 2-8 hours). Ongoing retraining: similar. Data preparation is the real cost — estimating 1-2 weeks of engineering for pseudo ground truth pipeline. |

### Weighted Total

| Category | Calculation | Subtotal |
|----------|------------|----------|
| Fit (3x) | (5+5+5+3) × 3 | **54** |
| Performance (2x) | (4+4+5) × 2 | **26** |
| Engineering (1x) | (5+4+4+4) × 1 | **17** |
| Cost (1x) | (5+4) × 1 | **9** |
| **Total** | | **106 / 120** |

---

*End of BEV DNN evaluation — Agent C*
