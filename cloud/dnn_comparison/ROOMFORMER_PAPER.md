# RoomFormer — Technical Evaluation for RoomScanAlpha Stage 3

> **Candidate**: RoomFormer (Agent B)
> **Paper**: "Connecting the Dots: Floorplan Reconstruction Using Two-Level Queries"
> **Authors**: Yuanwen Yue, Theodora Kontogianni, Konrad Schindler, Francis Engelmann (ETH Zurich)
> **Venue**: CVPR 2023 (pp. 845-854)
> **ArXiv**: [2211.15658](https://arxiv.org/abs/2211.15658)
> **Repository**: [github.com/ywyue/RoomFormer](https://github.com/ywyue/roomformer)
> **License**: MIT
> **Evaluator**: Agent B
> **Date**: 2026-03-27

---

## 1. Executive Summary

RoomFormer is a single-stage, end-to-end transformer model that reconstructs 2D
floorplan polygons from top-down density maps derived from 3D point clouds. Unlike
multi-stage pipelines that detect corners then group them into rooms, RoomFormer
uses a novel two-level query mechanism (room-level + corner-level) built on
Deformable DETR to directly predict a variable-size set of variable-length room
polygons in a single forward pass. It achieves 97.3% room F1 on Structured3D and
88.8% on SceneCAD (real-world RGB-D scans). The model is a strong candidate for
RoomScanAlpha's Stage 3 because it frames room boundary extraction as a learned
perception problem rather than a geometric one — directly addressing the root cause
of our five failed approaches. Its main limitation is the input gap: our pipeline
produces classified PLY meshes, while RoomFormer consumes 256x256 top-down density
maps, requiring a preprocessing conversion step whose fidelity on noisy LiDAR data
is unproven.

---

## 2. Architecture & How It Works

### 2.1 Model Architecture

RoomFormer extends Deformable DETR with a hierarchical output structure:

**Backbone**: ResNet-50 with frozen BatchNorm. Multi-scale features are extracted at
4 levels (C3-C5 from ResNet stages, plus a 4th level via 3x3 stride-2 conv on C5).
No Feature Pyramid Network (FPN) is used.

**Transformer Encoder**: 6 layers of deformable self-attention over multi-scale
feature maps. Each attention head samples 4 reference points per feature level,
making attention cost linear in the number of feature tokens rather than quadratic
(as in vanilla DETR).

**Transformer Decoder**: 6 layers with the novel two-level query structure:

- **Level 1 — Polygon queries**: M = 20 query groups, each representing a potential
  room. This caps the model at 20 rooms per scene.
- **Level 2 — Corner queries**: Each polygon group contains N = 40 corner queries
  (total: M × N = 800 queries). Each corner query predicts one vertex of the room
  polygon.
- Self-attention operates across ALL 800 queries simultaneously, capturing both
  intra-room vertex ordering and inter-room spatial relationships.

**Prediction Heads** (per query):
- **Corner coordinate MLP**: Predicts normalized (x, y) ∈ [0, 1]², scaled to pixel
  coordinates during post-processing.
- **Corner validity classifier**: Binary classification (valid corner vs. "no
  object") via linear layer + sigmoid.
- **Room type classifier** (optional): Softmax over 18 semantic categories (living
  room, bedroom, kitchen, etc.).

**Key architectural dimensions**:
- Hidden dimension: 256
- Feedforward dimension: 1024
- Attention heads: 8
- Total parameters: ~40.2M

### 2.2 Loss Functions

Three loss components, combined with Hungarian matching for polygon-to-GT
assignment:

| Loss | Weight | Purpose |
|------|--------|---------|
| Classification (focal) | λ_cls = 2 | Valid room/corner vs. "no object" |
| Coordinate (L1) | λ_coord = 5 | Corner position regression |
| Rasterization | λ_ras = 1 | Shape-level supervision via differentiable rasterization (from BoundaryFormer) |

The rasterization loss is particularly important: it renders predicted polygons as
binary masks and compares them to ground-truth masks, providing gradient signal for
the overall polygon shape even when individual corners are misplaced.

**Polygon matching**: Hungarian-style bipartite matching assigns predicted polygon
groups to ground-truth rooms during training. Within each matched pair, corner
sequences are aligned via cyclic matching (since polygons have no canonical start
vertex). This enables fully end-to-end training without heuristic corner grouping.

### 2.3 Input Representation

**Raw source**: 3D point clouds from RGB-D scans (e.g., ScanNet meshes,
Structured3D panorama reconstructions).

**Model input**: A **256 × 256 single-channel density map** — a top-down histogram
of point density when viewed from above. Walls appear as bright lines (many 3D
points project to the same 2D pixel), open floor areas appear dim, and exterior
regions are black.

**Preprocessing pipeline**:
1. Extract or generate a 3D point cloud from the scan
2. Determine the vertical (Y) axis and project all points onto the horizontal (XZ)
   plane
3. Compute a 2D histogram at 256×256 resolution over the scene's bounding box
4. Normalize to [0, 1] to produce a single-channel grayscale image
5. Store the meters-per-pixel scale factor for coordinate recovery

The density map discards vertical information (height), per-point color, and
semantic labels. Only the spatial distribution of points in the horizontal plane is
preserved.

### 2.4 Output Representation

The model produces:
- Up to **20 room polygons**, each with up to **40 ordered corner vertices**
- Each corner: (x, y) in [0, 1]² normalized coordinates + validity score (sigmoid)
- Each polygon group: room-level classification score
- Optionally: semantic room type labels, door/window detections (as 2-corner
  segments)

**Post-processing filters**:
- Validity threshold: sigmoid score > 0.5 for a corner to be kept
- Minimum corners: polygon must have ≥ 4 valid corners
- Minimum area: polygon must cover ≥ 100 pixels (in 256×256 space)
- Doors/windows: detected as exactly 2-corner line segments

### 2.5 Inference Pipeline (End-to-End)

```
3D Point Cloud
    ↓ Project onto XZ plane
256×256 Density Map (1-channel PNG)
    ↓ Normalize to [0,1], convert to tensor
ResNet-50 Backbone → Multi-scale features
    ↓
Deformable Transformer Encoder (6 layers)
    ↓
Deformable Transformer Decoder (6 layers, 800 queries)
    ↓
Prediction Heads → 20 × 40 corner coordinates + validity scores
    ↓ Filter by validity > 0.5, area ≥ 100px, corners ≥ 4
    ↓ Scale [0,1] → pixel coords → real-world meters
Room Polygons (ordered vertex lists)
```

---

## 3. Input Compatibility with RoomScanAlpha

### 3.1 What We Have

| Data Source | Format | Relevant Content |
|-------------|--------|------------------|
| PLY mesh | Binary LE, vertices + faces | XYZ positions, normals, per-face ARKit classification (floor/wall/ceiling/door/window/table/seat/none) |
| Camera poses | 4×4 column-major transforms per keyframe | Camera position and orientation |
| Depth maps | Float32, 256×192, per-keyframe | Per-pixel depth from ARKit |
| RGB keyframes | JPEG, 30-60 per scan | Color images from scan |
| Point cloud | Derivable from mesh vertices | XYZ positions + classifications |

### 3.2 What RoomFormer Needs

A single 256×256 grayscale density map — a top-down point density histogram.

### 3.3 Gap Analysis

**Conversion required**: Project mesh vertices onto the XZ plane (ARKit Y-up
coordinate system), compute a 2D density histogram at 256×256 resolution.

**Implementation complexity**: Low (~30 lines of numpy):

```python
def mesh_to_density_map(vertices: np.ndarray, resolution: int = 256):
    """Project PLY vertices to top-down density map."""
    xz = vertices[:, [0, 2]]  # ARKit: Y-up, so XZ is the floor plane
    # Compute bounding box and scale factor
    mins = xz.min(axis=0)
    maxs = xz.max(axis=0)
    span = max(maxs - mins)  # Use max span to preserve aspect ratio
    center = (mins + maxs) / 2
    # Normalize to [0, resolution-1]
    normalized = ((xz - center + span/2) / span * (resolution - 1)).astype(int)
    normalized = np.clip(normalized, 0, resolution - 1)
    # Build density histogram
    density = np.zeros((resolution, resolution), dtype=np.float32)
    np.add.at(density, (normalized[:, 1], normalized[:, 0]), 1)
    # Normalize to [0, 1]
    if density.max() > 0:
        density /= density.max()
    return density, center, span  # Keep scale for coordinate recovery
```

**How lossy is the conversion?**

| Information | Preserved? | Impact |
|-------------|-----------|--------|
| Horizontal point positions | Yes | Core input — fully preserved |
| Point density (wall vs. floor) | Yes | Walls are dense lines, floors are diffuse — this IS the signal |
| Vertical (height) info | **No** | Ceiling height must come from a separate computation (our Stage 2 RANSAC already extracts this) |
| ARKit classifications | **No** | Labels are discarded — the density pattern alone must encode room structure |
| Point color/normals | **No** | Not used by RoomFormer |
| Furniture vs. wall distinction | **Partial** | Furniture vertices appear in the density map and may look like walls — this is the key risk |

**Critical concern — furniture contamination**: Our scans include vertices
classified as table, seat, and "none" (often furniture). These will appear in the
density map and could be mistaken for walls. Two mitigation strategies:

1. **Filter by classification**: Only include wall, floor, and ceiling vertices in
   the density map. This removes furniture but also removes useful density signal
   from unclassified points.
2. **Multi-channel input**: Create a 2-3 channel density map (e.g., channel 0 =
   wall vertices, channel 1 = floor vertices, channel 2 = all other). This
   preserves more information but requires modifying the first conv layer of
   ResNet-50 (and fine-tuning).

### 3.4 Non-Rectangular Room Support

**Architecturally supported**: Each polygon can have up to 40 corners, which is
more than sufficient for L-shapes (8 corners), T-shapes (12 corners), and
irregular polygons. The Structured3D training set includes both Manhattan (axis-
aligned) and non-Manhattan layouts.

**Empirically**: RoomFormer's published metrics include non-rectangular rooms.
However, corner accuracy drops for complex shapes (corner F1 = 87.2% vs. room
F1 = 97.3% on Structured3D), indicating that vertices of complex polygons are less
precisely placed. The follow-up work PolyRoom (ECCV 2024) was specifically motivated
by RoomFormer's weaknesses on non-rectangular rooms, introducing room-aware
geometric constraints to improve corner accuracy.

**Assessment**: RoomFormer CAN produce non-rectangular rooms. It does not impose any
rectangularity constraint. But corner placement accuracy degrades for complex shapes,
and self-intersecting polygon predictions are possible due to the lack of explicit
geometric constraints on vertex ordering.

---

## 4. Output Compatibility with RoomScanAlpha

### 4.1 What Stage 3 Must Produce

| Output | Type | Unit |
|--------|------|------|
| Room floor boundary | Closed 2D polygon (ordered vertex list) | Meters (converted to imperial at output boundary) |
| Ceiling height | Scalar | Meters (converted to feet at output boundary) |

These feed into Stage 4 (Measurement Extraction), which computes `floor_area_sqft`,
`wall_area_sqft`, `perimeter_linear_ft`, and `ceiling_height_ft` for the
`scanned_rooms` table.

### 4.2 What RoomFormer Outputs

- Up to 20 room polygons, each as an ordered list of (x, y) coordinates in [0, 1]²
  normalized space.
- Per-corner validity scores.
- Per-polygon classification scores.
- Optionally: semantic room type labels.

### 4.3 Postprocessing Pipeline

```
RoomFormer output (normalized coordinates)
    ↓ Filter corners by validity > 0.5
    ↓ Filter polygons by ≥ 4 corners and area ≥ 100px
    ↓ Scale [0,1] → pixel [0,255] → real-world meters
        x_meters = (x_pixel / 255) * span - span/2 + center_x
        z_meters = (y_pixel / 255) * span - span/2 + center_z
    ↓ Select the single room polygon (our scans are one room each)
        → Pick the polygon with highest classification score
        → OR pick the polygon with largest area
    ↓ Ensure polygon closure and CCW winding
    ↓ Validate: area within plausible range (5-2000 sq ft)
Room floor boundary polygon (meters)
```

**Ceiling height**: RoomFormer does NOT output ceiling height. This must come from a
separate computation. Our existing Stage 2 RANSAC plane fitting already extracts
ceiling and floor planes with their Y-coordinates. Ceiling height =
`ceiling_plane_y - floor_plane_y`. This is already working reliably and can be kept
as-is.

### 4.4 Mapping Quality Assessment

| Aspect | Quality | Notes |
|--------|---------|-------|
| Polygon output → closed 2D boundary | **Direct** | RoomFormer outputs exactly what we need: ordered polygon vertices. Minimal postprocessing. |
| Coordinate recovery (pixel → meters) | **Straightforward** | Requires storing scale factor from density map generation. Simple linear transform. |
| Single-room selection | **Easy** | Our scans are one room — select the highest-confidence or largest-area polygon. |
| Ceiling height | **Not provided** | Must retain Stage 2 RANSAC ceiling extraction. Not a blocker — that code works. |
| Room type semantics | **Bonus** | Could populate a `room_type` field if we add one to the schema. |
| Door/window detection | **Bonus** | Could feed into `detected_components` JSONB. |

**Assessment**: Output compatibility is high. The primary output (room polygon) maps
directly to our needs with trivial postprocessing. The missing ceiling height is
handled by existing pipeline code.

---

## 5. Accuracy & Performance

### 5.1 Published Metrics

#### Structured3D (Synthetic RGB-D, 3,500 scenes)

| Metric | Precision | Recall | F1 |
|--------|-----------|--------|----|
| Room | 97.9 | 96.7 | **97.3** |
| Corner | 89.1 | 85.3 | **87.2** |
| Angle | 83.0 | 79.5 | **81.2** |

#### SceneCAD (Real-world RGB-D, ScanNet-derived)

| Metric | Value |
|--------|-------|
| Room IoU | **91.7** |
| Room P / R / F1 | 92.5 / 85.3 / **88.8** |
| Corner P / R / F1 | 78.0 / 73.7 / **75.8** |

#### Cross-Dataset Generalization (trained Structured3D → tested SceneCAD)

| Metric | Value |
|--------|-------|
| Room IoU | 74.0 |
| Room F1 | **60.3** |
| Corner F1 | **46.2** |

The cross-dataset generalization gap (97.3 → 60.3 room F1) is significant and
directly relevant: our LiDAR density maps will differ from both Structured3D
(synthetic) and SceneCAD (RGB-D reconstruction). **Fine-tuning on our data will
almost certainly be required.**

### 5.2 Performance on Non-Rectangular Rooms

The paper does not break out metrics by room shape. However:
- Structured3D includes both Manhattan and non-Manhattan layouts, and the 97.3% room
  F1 includes both.
- Corner F1 (87.2%) is notably lower than room F1 (97.3%), suggesting that while
  rooms are detected correctly (overlap-based), vertex placement is less precise —
  particularly for complex shapes where each corner matters more.
- PolyRoom (ECCV 2024) explicitly identifies RoomFormer's weakness on non-
  rectangular rooms as motivation for their improved approach.

### 5.3 Known Failure Modes

From the paper's own analysis and community reports:

1. **Self-intersecting polygons**: Predicted corner sequences can produce self-
   intersecting shapes. No explicit geometric constraint prevents this.
2. **Disordered vertices**: Random query initialization can produce polygon vertices
   in incorrect order, especially for complex shapes.
3. **Missing rooms**: The model can fail to detect rooms entirely, particularly
   small or unusually-shaped rooms.
4. **Single biased corner**: One misplaced corner can distort an entire room polygon
   — there is no mechanism to enforce local consistency.
5. **Density map quality dependency**: Sparse or noisy point clouds produce poor
   density maps, degrading accuracy. This is directly relevant to our LiDAR scans
   with coverage gaps.

### 5.4 Inference Latency

- **~0.01 seconds per scene** (10ms) reported in the FRI-Net comparison table.
- Hardware for this benchmark was likely an NVIDIA TITAN RTX (24 GB) — the GPU used
  for all experiments in the paper.
- The 256×256 input is very small by vision model standards (COCO uses 800×1333).
  Inference is fast even on modest GPUs.
- On a T4: expect ~15-30ms per scene. On an L4: ~10-20ms per scene.

**Assessment**: Inference speed is not a concern. Even with preprocessing overhead,
total latency will be well under 1 second per room.

---

## 6. Integration with GCP / Vertex AI

### 6.1 Deployment Options

| Option | Idle Cost | Per-Prediction | Cold Start | Fit |
|--------|-----------|---------------|------------|-----|
| **Cloud Run + L4 GPU** | $0 (scale to zero) | ~$0.02-0.05 | <5s | **Best** |
| Vertex AI + T4 (scale-to-zero) | $0 (beta) | ~$0.02 | 60-120s | OK |
| Vertex AI + T4 (min 1 replica) | ~$14/day | ~$0.00002 | None | Too expensive idle |
| Vertex AI Batch | $0 | Same GPU rates | 5+ min | Bulk only |

**Recommended**: Cloud Run with L4 GPU. Zero idle cost, fast cold start (<5s), pay-
per-second billing. This aligns with our existing Cloud Run architecture — the
RoomFormer model would run as a sidecar or separate service invoked by the processor.

### 6.2 GPU Requirements

- **VRAM**: ~1-1.5 GB for inference (ResNet-50 + Deformable Transformer at 256×256).
  A T4 (16 GB) or L4 (24 GB) is massively overpowered. Even concurrent requests are
  trivial.
- **Compute**: ~10-30ms per inference. GPU utilization will be very low for our
  volume (scans arrive sporadically).

### 6.3 Container Packaging

**Custom container required** (not prebuilt Vertex AI containers) because:
1. Deformable DETR compiles custom CUDA extensions (`MultiScaleDeformableAttention`)
   that must be built at container build time.
2. The differentiable rasterization module (from BoundaryFormer) also requires CUDA
   compilation.
3. Preprocessing (PLY → density map) needs custom code in the container.

**Critical compatibility issue**: RoomFormer is pinned to PyTorch 1.9 + CUDA 11.1.
CUDA 11.1 does **not** support the L4 GPU (Ada Lovelace, sm_89 — requires CUDA
11.8+). **To deploy on Cloud Run with L4, the codebase must be upgraded to PyTorch
2.x + CUDA 11.8+.** The T4 (sm_75) works with CUDA 11.1, but is not available on
Cloud Run.

Upgrade effort: The core model code uses standard PyTorch APIs compatible with 2.x.
The custom CUDA ops (deformable attention, diff rasterization) need recompilation
but the source code is architecturally compatible. Open issue #34 notes a self-
attention compatibility issue with PyTorch >2.0 that would need patching. Estimated
effort: 1-2 days.

### 6.4 Estimated Cost Per Prediction

At Cloud Run L4 pricing ($0.000187/s):
- Inference: 20ms × $0.000187/s ≈ $0.000004
- Cold start amortization (5s every ~10 minutes): ~$0.001
- Container + preprocessing overhead: ~$0.001
- **Estimated total: $0.002-0.005 per prediction** (dominated by cold start, not
  inference)

This is negligible relative to our per-scan costs (GCS storage, Cloud Tasks, DB
writes).

---

## 7. Training & Fine-Tuning

### 7.1 Is Pretrained Sufficient?

**No.** The cross-dataset generalization results (room F1 drops from 97.3% to 60.3%
when moving from Structured3D to SceneCAD) demonstrate that the model does not
generalize well across density map distributions. Our LiDAR-derived density maps
will differ from both:

- **Structured3D** (synthetic, clean, complete coverage, no furniture occlusion)
- **SceneCAD** (RGB-D reconstruction from ScanNet — closer to our data but still
  different sensor characteristics)

ARKit LiDAR produces different noise patterns, coverage gaps, and point densities
than RGB-D reconstruction. Fine-tuning is almost certainly required for production
accuracy.

### 7.2 Fine-Tuning Strategy

**Option A — Transfer learning (recommended for PoC)**:
- Start from the pretrained Structured3D checkpoint.
- Fine-tune on 50-100 manually annotated LiDAR scans.
- Annotation task: draw room polygon boundaries on top-down density maps. This is
  a standard polygon annotation task — tools like LabelMe or CVAT support it.
- Freeze backbone for the first few epochs, then fine-tune end-to-end.
- Estimated annotation time: ~5 minutes per scan × 100 scans = ~8 hours of manual
  work.

**Option B — Synthetic augmentation**:
- Generate synthetic LiDAR-like density maps from Structured3D by adding noise,
  removing random regions (simulating coverage gaps), and inserting furniture-like
  density blobs.
- Fine-tune on augmented synthetic + small real dataset.
- Higher effort but reduces manual annotation burden.

### 7.3 Training Compute

| Parameter | Value |
|-----------|-------|
| Original training | 500 epochs on single TITAN RTX (24 GB) |
| Estimated training time | ~24-48 hours (not reported, estimated from Deformable DETR baselines) |
| Fine-tuning (100 epochs, 100 samples) | ~2-4 hours on a single T4/L4 |
| Fine-tuning cost (GCP) | L4 spot: ~$0.25/hr × 4hr = **~$1-2** |

Fine-tuning compute cost is trivial. The bottleneck is annotation labor, not GPU
time.

### 7.4 Training Data Format

RoomFormer uses COCO-format annotations:

```json
{
  "images": [{"file_name": "scene_001.png", "height": 256, "width": 256, "id": 1}],
  "annotations": [{
    "image_id": 1,
    "category_id": 1,
    "segmentation": [[x1, y1, x2, y2, ..., xn, yn]],
    "area": 12345,
    "id": 1
  }],
  "categories": [{"id": 1, "name": "room"}]
}
```

Creating this from manually annotated polygons is straightforward. The main effort
is producing the density maps from our PLY files and annotating ground-truth
polygons on them.

---

## 8. Maturity & Community

| Attribute | Value | Assessment |
|-----------|-------|-----------|
| Publication | CVPR 2023 (top-tier venue) | Strong |
| Citations | ~63 (as of Mar 2026) | Moderate — healthy for a 3-year-old niche paper |
| GitHub stars | 287 | Moderate |
| GitHub forks | 43 | Active community exploration |
| Last commit | 2025-04-02 | Maintained (within last year) |
| Open issues | 4 | Low issue count |
| License | MIT | **Commercial use OK** |
| Production deployments | None known publicly | Research-stage |

**Key open issues**:
- #34: PyTorch >2.0 self-attention compatibility (workaround needed)
- #35: Newer GPU (Ada Lovelace / sm_89) support for custom CUDA ops
- #27, #28: Custom dataset adaptation questions

**Follow-up work**: PolyRoom (ECCV 2024) and FRI-Net (ECCV 2024) both cite
RoomFormer as a baseline and report improved results, particularly for non-
rectangular rooms and corner accuracy. These could be future upgrade paths if
RoomFormer's accuracy proves insufficient.

**Assessment**: RoomFormer is a well-regarded research project from a top lab, with
an MIT license suitable for commercial use. It is not a production-hardened library
— we would be among the first to deploy it in a real product pipeline. The codebase
is clean but dated (PyTorch 1.9), and the community is small but active.

---

## 9. Risks & Mitigations

### Risk 1: Density Map Quality from Noisy LiDAR (HIGH)

**Risk**: ARKit LiDAR meshes have coverage gaps (corners, behind furniture),
classification noise, and variable point density. The resulting density maps may be
too sparse or noisy for RoomFormer, which was trained on clean synthetic (Structured3D)
or RGB-D reconstruction (SceneCAD) data.

**Mitigation**:
- Fine-tune on real LiDAR-derived density maps (50-100 annotated scans).
- Augment training data with synthetic noise/gaps to improve robustness.
- Experiment with classification-filtered density maps (wall+ceiling only) to remove
  furniture contamination.
- Fall back to existing geometric Stage 3 when RoomFormer confidence is low.

### Risk 2: Furniture Contamination in Density Maps (HIGH)

**Risk**: Furniture vertices (tables, chairs, cabinets) project into the density map
and may appear as wall-like structures, causing false room boundaries. This was
exactly the problem that killed our alpha-shape approach in geometric Stage 3.

**Mitigation**:
- Filter vertices by ARKit classification before density map generation: include
  only wall, floor, ceiling, door, and window classes. This removes most furniture.
- Create a second density map channel from furniture-classified vertices so the model
  can learn to distinguish them (requires model modification: 1-channel → 2-channel
  input).
- Fine-tune on examples with heavy furniture to teach the model robustness.

### Risk 3: Single-Room Overshoot (MODERATE)

**Risk**: RoomFormer is designed for multi-room floorplans (up to 20 rooms). Our
scans are single-room. The model may hallucinate additional rooms from furniture
clusters or alcoves, or split one room into multiple polygons.

**Mitigation**:
- Post-processing: select only the largest or highest-confidence polygon.
- Fine-tune on single-room density maps to bias the model toward single-room output.
- Set `num_polys=5` (instead of 20) to reduce hallucination budget.

### Risk 4: PyTorch/CUDA Upgrade Required (MODERATE)

**Risk**: The codebase is pinned to PyTorch 1.9 + CUDA 11.1, which cannot run on
Cloud Run's L4 GPUs (require CUDA 11.8+). Upgrading may break custom CUDA ops or
introduce subtle behavior changes.

**Mitigation**:
- The Deformable Attention CUDA ops are from a well-maintained upstream project
  (Deformable-DETR) and have been ported to newer PyTorch versions by others.
- Test upgrade to PyTorch 2.1 + CUDA 12.1 in an isolated environment before
  integration.
- Open issue #34 (PyTorch 2.0 self-attention) has a known workaround.
- Estimated effort: 1-2 days.

### Risk 5: Corner Accuracy for Complex Rooms (MODERATE)

**Risk**: Corner F1 is 87.2% on Structured3D (synthetic) and 75.8% on SceneCAD
(real). For non-rectangular rooms, each corner matters more — a single misplaced
corner can significantly distort floor area and perimeter calculations.

**Mitigation**:
- Post-processing: snap corners to axis-aligned positions when close (most rooms
  have axis-aligned walls).
- Validate output polygon against plausible room dimensions (area 5-2000 sq ft,
  aspect ratio < 10:1, no self-intersections).
- Apply Douglas-Peucker simplification to smooth minor vertex jitter.
- Consider upgrading to PolyRoom (ECCV 2024) if corner accuracy is insufficient
  after fine-tuning.

---

## 10. Recommendation

### Overall Assessment: **Moderate Fit**

RoomFormer is architecturally well-suited to our problem: it directly outputs room
polygons from a top-down projection of 3D scan data, which is exactly what Stage 3
needs. The model handles non-rectangular rooms, runs fast, and is MIT-licensed.

However, significant integration work is required:
1. Building the PLY → density map preprocessing pipeline
2. Upgrading PyTorch/CUDA for Cloud Run L4 compatibility
3. Collecting and annotating 50-100 LiDAR scans for fine-tuning
4. Validating that furniture-contaminated density maps don't degrade accuracy
5. Packaging as a Cloud Run GPU service

The cross-dataset generalization gap (97.3% → 60.3% room F1) is the biggest
concern — it means the pretrained model will NOT work out-of-the-box on our data.
Fine-tuning is mandatory, and we won't know the achievable accuracy until we try.

### Key Strengths

- **Direct polygon output**: No multi-stage heuristic pipeline — exactly what we
  need.
- **Handles non-rectangular rooms**: 40 corners per polygon, trained on varied
  layouts.
- **Fast inference**: ~10-30ms per room — trivial latency.
- **Low deployment cost**: ~$0.002-0.005/prediction on Cloud Run with L4.
- **MIT license**: No commercial restrictions.
- **Proven on real data**: 88.8% room F1 on SceneCAD (real RGB-D scans).

### Key Weaknesses

- **Input gap**: Requires density map conversion; furniture contamination is
  unproven.
- **Ceiling height not provided**: Must retain Stage 2 RANSAC (minor — already
  working).
- **Fine-tuning required**: Pretrained model won't work on our LiDAR data without
  domain adaptation.
- **Corner accuracy**: 75.8% on real data is moderate — may produce imprecise room
  dimensions.
- **Dated codebase**: PyTorch 1.9 + CUDA 11.1 requires upgrade for modern GPUs.
- **No production precedent**: We would be among the first production deployments.

### Suggested Proof-of-Concept Scope

**Duration**: 1-2 weeks

**Steps**:
1. **Day 1-2**: Build PLY → density map conversion. Generate density maps from 10+
   real scans. Visually inspect — do rooms look recognizable?
2. **Day 3-4**: Run pretrained RoomFormer (Structured3D checkpoint) on our density
   maps. Evaluate zero-shot accuracy qualitatively.
3. **Day 5-7**: Annotate 20-30 scans with ground-truth polygons. Fine-tune for 100
   epochs. Evaluate on held-out set.
4. **Day 8-9**: Package as Docker container, test on Cloud Run with L4 GPU. Verify
   inference latency and cost.
5. **Day 10**: Decision gate — compare polygon quality against our best geometric
   Stage 3 output. If floor area error < 10% on test set, proceed to full
   integration.

**Go/No-Go criteria for PoC**:
- Floor area within ±10% of manual measurement on ≥ 80% of test scans
- No self-intersecting polygons on ≥ 90% of predictions
- Inference latency < 1 second end-to-end (including preprocessing)

---

## Scorecard

| Metric | Weight | Score | Justification |
|--------|--------|-------|---------------|
| **Input compatibility** | 3x | **3** | Our PLY mesh converts to density maps with ~30 lines of code, but furniture contamination is a real risk that could degrade quality. Classification filtering helps but is untested. Not a direct input match — requires preprocessing with uncertain fidelity on our data. |
| **Output compatibility** | 3x | **4** | Direct polygon output maps cleanly to our needs. Missing ceiling height is handled by existing Stage 2 code. Minor postprocessing (scale recovery, single-room selection, winding order). Near-ideal output format. |
| **Non-rectangular room support** | 3x | **4** | Architecturally supports up to 40 corners per polygon — handles L-shapes, T-shapes, and irregular rooms. Trained on non-Manhattan layouts. Knocked down from 5 because corner accuracy degrades for complex shapes and self-intersection is possible. |
| **Noise/gap tolerance** | 3x | **2** | This is the weakest point. Cross-dataset generalization drops dramatically (97% → 60% F1). Trained on clean synthetic data and RGB-D reconstruction — never seen LiDAR noise patterns or coverage gaps. Fine-tuning should help but the gap is concerning. No built-in mechanism for handling missing data. |
| **Accuracy — IoU** | 2x | **4** | 97.3% room F1 on Structured3D, 91.7% room IoU on SceneCAD. Very strong published numbers, though on data cleaner than ours. Real-world performance after fine-tuning is unknown. |
| **Corner/edge accuracy** | 2x | **3** | 87.2% corner F1 on Structured3D, 75.8% on SceneCAD. Moderate — each misplaced corner directly impacts our floor area and perimeter calculations. Self-intersecting polygon risk. |
| **Inference speed** | 2x | **5** | ~10-30ms per scene. Trivially fast. Well within our <10s target even with preprocessing overhead. |
| **Vertex AI deployability** | 1x | **3** | Cloud Run with L4 GPU is the right path, but requires PyTorch/CUDA upgrade and custom container with compiled CUDA ops. Not plug-and-play, but achievable in 2-3 days. |
| **Fine-tuning feasibility** | 1x | **4** | Standard COCO annotation format. Transfer learning from Structured3D checkpoint. 50-100 annotated scans needed. Fine-tuning compute is trivial (~$2). Annotation labor is the bottleneck (~8 hours). |
| **Maturity & support** | 1x | **3** | CVPR 2023, MIT license, 287 stars, maintained. But small community, no production deployments known, dated dependencies. Solid research code, not production-hardened. |
| **Implementation effort** | 1x | **3** | Estimated 2-3 weeks total: 1 week PoC, 1 week integration, 0.5 week testing. Major tasks: density map pipeline, PyTorch upgrade, container packaging, annotation + fine-tuning. Moderate complexity. |
| **GPU cost per prediction** | 1x | **5** | ~$0.002-0.005 per prediction on Cloud Run L4 with scale-to-zero. Negligible. |
| **Training/fine-tuning cost** | 1x | **5** | ~$2 for fine-tuning compute. Annotation labor (~8 hours) is the real cost but still trivial. No expensive pre-training needed. |

### Weighted Total

| Category | Metrics | Calculation | Subtotal |
|----------|---------|-------------|----------|
| Fit (3x) | Input (3) + Output (4) + Non-rect (4) + Noise (2) | (3+4+4+2) × 3 | **39** |
| Performance (2x) | IoU (4) + Corner (3) + Speed (5) | (4+3+5) × 2 | **24** |
| Engineering (1x) | Deploy (3) + Fine-tune (4) + Maturity (3) + Effort (3) | (3+4+3+3) × 1 | **13** |
| Cost (1x) | GPU cost (5) + Training cost (5) | (5+5) × 1 | **10** |
| | | **Total** | **86 / 120** |

**RoomFormer scores 86/120 — above the 72-point viability threshold.**

The strongest areas are inference speed (5/5), cost efficiency (5/5), and output
compatibility (4/5). The weakest area is noise/gap tolerance (2/5), which is our
single biggest pain point. Fine-tuning on real LiDAR data is the critical unknown
that will determine whether RoomFormer is viable for production.

---

## References

1. Yue, Y., Kontogianni, T., Schindler, K., & Engelmann, F. (2023). Connecting the
   Dots: Floorplan Reconstruction Using Two-Level Queries. CVPR 2023.
   [ArXiv 2211.15658](https://arxiv.org/abs/2211.15658)

2. Zhu, X., Su, W., Lu, L., Li, B., Wang, X., & Dai, J. (2021). Deformable DETR:
   Deformable Transformers for End-to-End Object Detection. ICLR 2021.

3. Zheng, J., Zhang, J., Li, J., Tang, R., Gao, S., & Zhou, Z. (2023). Structured3D:
   A Large Photorealistic Dataset for Structured 3D Modeling. ECCV 2020.

4. PolyRoom: Room-Aware Transformer for Floorplan Reconstruction. ECCV 2024.
   (Follow-up addressing RoomFormer's non-rectangular room weaknesses.)

5. FRI-Net: Floorplan Reconstruction via Room-wise Implicit Representation. ECCV 2024.
   (Alternative approach with comparative benchmarks.)
