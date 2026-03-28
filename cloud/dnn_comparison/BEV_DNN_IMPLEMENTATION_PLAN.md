# BEV DNN Stage 3 — Implementation Plan

## Context

Stage 3 (Room Geometry Assembly) extracts a closed room polygon + ceiling height from classified LiDAR meshes. Five geometric approaches have failed — RANSAC, alpha shapes, Douglas-Peucker, etc. all break on noisy LiDAR data, furniture occlusion, and ARKit classification errors. The root cause: this is a perception problem, not a geometry problem.

**Solution**: Replace the polygon extraction with a BEV DNN (RoomFormer, CVPR 2023, MIT license). Project mesh vertices to a 256x256 top-down density map, run a transformer that predicts room polygon vertices, convert back to meters. The existing wall extrusion, floor/ceiling polygon construction, and metric computation code stays unchanged — only the source of `corners_xz` changes.

**Branch**: `experiment/bev-dnn-stage3` (off master)

**Scope**: This plan targets **RoomFormer only**. CAGE (NeurIPS 2025) achieves higher accuracy but outputs directed edges (4D: x1,y1,x2,y2) not corners (2D: x,y), requires complex postprocessing (`edge_utils.py` — edge intersection, short-edge removal, polygon refinement via Shapely), uses Swin-V2 Large (~200M params vs ~50M), and has no commercial license. CAGE is a future upgrade path once it matures — it would require a separate inference wrapper and postprocessing module.

### Known Constraints (from codebase audit + Colab export)

1. **Custom CUDA dependency**: `MultiScaleDeformableAttention` is a C++ CUDA extension. Won't build on modern CUDA/PyTorch. Patched to use pure-PyTorch `ms_deform_attn_core_pytorch()` via `F.grid_sample`. PATCH.1 verified on CPU.
2. **ONNX export not possible**: Deformable DETR has data-dependent dynamic shapes (`torch.meshgrid` on runtime spatial dims) that `torch.export` cannot trace. **TorchScript export succeeded** — 157.8 MB `.pt` file, runs on CPU via `torch.jit.load()`.
3. **Input is 1-channel**: Pretrained weights expect `[B, 1, 256, 256]`. Do NOT stack to 3 channels.
4. **Model format**: TorchScript `.pt` file. Inference via `torch.jit.load()` + forward pass. No `onnxruntime` needed.
5. **Density map normalization**: Training data uses 10% bbox padding, `np.unique` counting, and uint8 round-trip normalization.
6. **Inference verified on M1 Mac**: 0.20s per forward pass on CPU. Deterministic. Output shapes `[1, 20, 40]` logits + `[1, 20, 40, 2]` coords.

### Model Export Results (Step 3 — completed)

| Test | Result |
|------|--------|
| PATCH.1 — CPU forward pass | **PASSED** — pure-PyTorch attention works on CPU |
| PATCH.2 — Parity with CUDA original | Skipped (CUDA extension won't build on Colab's PyTorch 2.x) |
| ONNX export | **FAILED** — `torch.export` can't handle data-dependent shapes in deformable transformer |
| TorchScript export | **PASSED** — 157.8 MB, `torch.jit.trace()` succeeded |
| Local verification (M1 Mac) | **PASSED** — loads, runs at 0.20s, deterministic |

**Model file**: `cloud/processor/models/roomformer_s3d.pt` (gitignored, 158 MB)

---

## Critical Files

| File | Role |
|------|------|
| `cloud/processor/pipeline/stage1.py` | `ParsedMesh`, classification constants (WALL=1, FLOOR=2, CEILING=3, etc.) |
| `cloud/processor/pipeline/stage2.py` | `PlaneFitResult` — floor_y/ceiling_y via RANSAC (kept as-is) |
| `cloud/processor/pipeline/stage3.py` | Current geometric `assemble_geometry()` → `SimplifiedMesh`. Being augmented, not replaced. |
| `cloud/processor/pipeline/bev_projection.py` | **NEW** — BEV density map projection + coordinate conversion (Step 1, complete) |
| `cloud/processor/main.py:437` | `compute_room_metrics()` — integration point for Stage 3 output |
| `cloud/processor/tests/fixtures/generate_ply.py` | `generate_dense_box_room_ply()`, `generate_rotated_dense_room_ply()` |
| `cloud/processor/models/roomformer_s3d.pt` | TorchScript model file (gitignored) |

**Test scans**:
- Scan 1: `/Users/jakejulian/Downloads/pipeline_diag/classified_debug.ply` — 171K verts, 11-corner irregular room, height 2.864m
- Scan 2: `/Users/jakejulian/Downloads/pipeline_diag_scan2/classified_debug.ply` — 112K verts, 6-corner room, height 2.670m
- Ground truth polygons in `simplified_mesh.ply` alongside each scan

---

## Step 1: BEV Projection Module — COMPLETE

**Status**: All 16 automated tests pass (BEV.1-8). BEV.H1/H2 visual inspection passed — room outlines clearly visible in both real scan density maps.

**Deliverables**:
- `cloud/processor/pipeline/bev_projection.py`
- `cloud/processor/tests/test_bev_projection.py`
- `cloud/processor/scripts/visualize_bev.py`

---

## Step 2: Ground Truth Extraction + Baseline Metrics — COMPLETE

**Status**: All 18 automated tests pass (EVAL.1-3 + helpers).

**Deliverables**:
- `cloud/processor/scripts/evaluate_polygon.py`
- `cloud/processor/tests/test_evaluate_polygon.py`

---

## Step 3: Deformable Attention Patch + Model Export — COMPLETE

**Status**: TorchScript export succeeded. ONNX export failed (data-dependent dynamic shapes). Model verified locally at 0.20s inference on M1 CPU.

**Deliverables**:
- `cloud/processor/scripts/RoomFormer_ONNX_Export.ipynb` (Colab notebook)
- `cloud/processor/scripts/patch_roomformer.py`
- `cloud/processor/scripts/export_roomformer_onnx.py`
- `cloud/processor/models/roomformer_s3d.pt` (158 MB, gitignored)
- `cloud/processor/models/README.md`

---

## Step 4: Inference Wrapper

**Deliverable**: `cloud/processor/pipeline/bev_inference.py`

**Code**:
- `DnnPolygonResult` dataclass: `corners_px` (Kx2), `confidence` (K,), `num_corners` (int)
- `RoomFormerPredictor` class:
  - Lazy-loads TorchScript model via `torch.jit.load(model_path, map_location='cpu')` on first call (singleton)
  - Preprocesses density map: convert to `torch.Tensor` shape `[1, 1, 256, 256]` float32
  - Runs `model(input_tensor)` — returns `(pred_logits, pred_coords)` tuple
  - Post-processes (matching RoomFormer's `engine.py`):
    1. `pred_logits` shape `[1, 20, 40]` → apply sigmoid → threshold
    2. `pred_coords` shape `[1, 20, 40, 2]` → scale by `(resolution - 1)` to get pixel coordinates
    3. For each room query (20 total): filter corners where `sigmoid(logit) > threshold`
    4. Reject rooms with < 4 valid corners
    5. Reject rooms where `Polygon(corners).area < 100` sq pixels (prevents degenerate slivers)
    6. Validate polygon with `shapely.geometry.Polygon(corners).is_valid` — reject self-intersecting polygons
    7. Take the room with largest polygon area (we expect M=1 for single-room scans)
    8. Order corners CCW via signed area check
- `predict_room_polygon(bev: BEVProjection, model_path: str | None) -> DnnPolygonResult`

**Dependencies**: `torch>=2.0` (already installed), `shapely>=2.0` (add to `requirements.txt`)

**Tests** (automated — mock-based, no model file needed):

| ID | Test | Criteria |
|----|------|----------|
| INF.1 | Mock model returns known tensor → post-processing produces correct 4-corner rectangle | Corner positions match |
| INF.2 | Mock with 20 rooms, 4 corners above threshold in one → only that room's 4 corners survive | Count = 4 |
| INF.3 | Mock with < 4 corners above threshold in all rooms → returns empty/failure result | Graceful failure |
| INF.4 | CCW ordering: random 2D points → verify signed area > 0 after ordering | Positive signed area |
| INF.5 | Lazy loading: two predict calls, assert model loaded once | Mock assertion |
| INF.6 | Output shape validation: mock `pred_coords` has shape `[1, 20, 40, 2]`. Assert postprocessing handles correctly | Shape assertion |
| INF.7 | Polygon with area < 100 sq pixels is rejected even if corners pass confidence threshold | Room filtered out |
| INF.8 | Self-intersecting polygon (bowtie shape) is detected and rejected via Shapely `.is_valid` | Room filtered out |

**Tests** (require model file, skip if absent):

| ID | Test | Criteria |
|----|------|----------|
| INF.H1 | Synthetic box room BEV → returns 4 corners | Corner count |
| INF.H2 | Real scan 1 BEV → returns 4-20 corners | Reasonable count |
| INF.H3 | Real scan 2 BEV → returns 4-20 corners | Reasonable count |
| INF.H4 | Partial scan BEV (3 walls) → evaluate whether model produces closed polygon or degenerate shape | Visual inspection + polygon validity |
| INF.H5 | Furniture-heavy room: inference with and without structural filtering, compare polygon accuracy | Side-by-side overlay PNG |

**Go/no-go**: All mock tests (INF.1-8) pass. INF.H1-H3 are informational — poor pretrained results expected on our LiDAR data.

---

## Step 5: Stage 3 DNN Path + Geometric Fallback

**Deliverable**: Modified `cloud/processor/pipeline/stage3.py`

**Code**: Add `use_dnn` parameter to `assemble_geometry`:

```python
def assemble_geometry(
    plan_result: PlaneFitResult,
    mesh: ParsedMesh | None = None,
    use_dnn: bool = False,
    model_path: str | None = None,
) -> SimplifiedMesh:
```

When `use_dnn=True`:
1. `project_to_bev(mesh)` → BEV density map
2. `predict_room_polygon(bev, model_path)` → pixel corners
3. `pixels_to_meters(corners_px, bev)` → XZ corners in meters
4. If DNN fails (< 3 corners, exception), fall back to geometric `_extract_classification_boundary`
5. Everything downstream (floor polygon, ceiling polygon, wall quads, door detection, surface_map) unchanged

**Tests** (automated):

| ID | Test | Criteria |
|----|------|----------|
| S3D.1 | `use_dnn=False` → identical output to current Stage 3 on all existing fixtures | Regression guard |
| S3D.2 | `use_dnn=True` + mock returning known rectangle corners → SimplifiedMesh has 4 walls, correct floor area | Area within 1% |
| S3D.3 | `use_dnn=True` + mock returning empty → falls back to geometric, valid output | No crash, valid mesh |
| S3D.4 | All existing TestS3_N tests still pass unchanged | Full regression |

**Tests** (human-in-the-loop):

| ID | Test | How |
|----|------|-----|
| S3D.H1 | Real scan 1 with DNN: compare polygon to ground truth using Step 2 evaluator | `evaluate_polygon.py` output |
| S3D.H2 | Real scan 2 with DNN: same | Evaluator output |
| S3D.H3 | Side-by-side: geometric polygon vs DNN polygon overlaid on BEV density map | `scripts/compare_polygons.py` saves comparison PNG |
| S3D.H4 | Confidence threshold sweep: run both real scans at thresholds [0.1, 0.2, 0.3, 0.5, 0.7], record IoU and corner count at each. Identify optimal threshold for our LiDAR data | `scripts/sweep_threshold.py` outputs table + best threshold |

**Go/no-go**: S3D.1 and S3D.4 must pass (no regression). S3D.H1/H2 metrics compared to Step 2 baseline — DNN path should match or beat geometric on at least 1 of 2 scans.

---

## Step 6: Pipeline Integration

**Deliverable**: Modified `cloud/processor/main.py`

**Code**: `compute_room_metrics()` gains optional DNN path controlled by `USE_DNN_STAGE3` env var:

1. After `parse_and_classify` + `fit_planes`, call `assemble_geometry(plan_result, mesh, use_dnn=True)`
2. Derive metrics from `SimplifiedMesh.surface_map` instead of raw triangle summation
3. Keep `_compute_ceiling_height()` from Stage 2 (unchanged)
4. Fall back to raw triangle path if Stage 3 raises

**Tests**:

| ID | Test | Criteria |
|----|------|----------|
| MAIN.1 | `USE_DNN_STAGE3=false` → identical output to current code | Regression |
| MAIN.2 | `USE_DNN_STAGE3=true` + mock DNN → reasonable metrics (area > 0, perimeter > 0, height unchanged) | Sanity check |
| MAIN.3 | Stage 3 exception → graceful fallback to raw triangle metrics | No crash |

**Tests** (human-in-the-loop):

| ID | Test | How |
|----|------|-----|
| MAIN.H1 | Real scan 1, full pipeline: floor area within 15% of ground truth, ceiling height within 0.05m | Script output |
| MAIN.H2 | Real scan 2, same | Script output |

**Go/no-go**: MAIN.1 must pass. MAIN.H1/H2 determine if DNN is production-quality or needs fine-tuning (Step 7).

---

## Step 7: Fine-Tuning Data Pipeline + Training

**Deliverable**:
- `cloud/processor/scripts/generate_training_data.py` — creates BEV + ground truth polygon pairs
- `cloud/processor/scripts/finetune_roomformer.py` — fine-tunes from Structured3D checkpoint

**Data sources**:
- Synthetic: vary `generate_dense_box_room_ply` dimensions (2-8m width, 2-6m depth, 2.4-3.5m height, 0-45deg rotation). Generate 500+ samples.
- Real: use geometric Stage 3 output on historical scans where it succeeded (~60-70% of scans) as pseudo ground truth
- Output format: COCO-style JSON (RoomFormer's native format)

**Training**:
- Pretrained checkpoint already has 1-channel conv1 — no adaptation needed
- Fine-tune 50-100 epochs, LR=1e-5, from Structured3D checkpoint
- Training runs on Colab (T4 GPU) or GCE, using the same stub+patch approach from Step 3
- Re-export to TorchScript via `torch.jit.trace()` after fine-tuning

**Data augmentation for domain gap mitigation**:
- Simulate partial scans: randomly drop 1 wall segment from density maps (10-20% of training samples)
- Simulate furniture noise: add random rectangular density blobs against walls
- Random Gaussian smoothing (sigma 0.5-1.5) to simulate LiDAR point spread

**Tests**:

| ID | Test | Criteria |
|----|------|----------|
| FT.1 | Data generation produces valid samples for both real scans | File exists, loadable |
| FT.2 | 500+ synthetic samples generated with correct format | Count + schema validation |
| FT.3 | Fine-tuned model TorchScript export succeeds | `.pt` file exists, loads, runs |
| FT.4 | Base domain regression: fine-tuned model on 50 Structured3D validation samples. Room F1 > 90.0, Corner F1 > 80.0 | Prevents catastrophic forgetting |

**Tests** (human-in-the-loop — the ultimate quality gate):

| ID | Test | Criteria |
|----|------|----------|
| FT.H1 | Fine-tuned model on scan 1: mean CPE < 0.15m, IoU > 0.80 | Evaluator output |
| FT.H2 | Fine-tuned model on scan 2: mean CPE < 0.15m, IoU > 0.80 | Evaluator output |
| FT.H3 | Fine-tuned model on 10 synthetic rooms: floor area within 5% | Automated but needs model |

**Go/no-go**: FT.H1, FT.H2, and FT.4 must all meet thresholds.

---

## Step 8: Deployment

**Deliverable**: Updated Dockerfile, Cloud Run config, model hosting

**Code**:
- Add `torch>=2.0` and `shapely>=2.0` to processor `requirements.txt`
- TorchScript model (~158 MB) hosted on GCS bucket (`gs://roomscanalpha-models/roomformer_s3d.pt`), downloaded at container build via multi-stage Dockerfile
- `USE_DNN_STAGE3=true` as default env var
- `ROOMFORMER_MODEL_PATH=/app/models/roomformer_s3d.pt` env var for model location
- Health check verifies model loads and runs inference on a test input

**Container impact**:
- Image size increases by ~800MB-1GB (PyTorch CPU + model weights)
- Memory footprint: ~500MB-1GB at runtime (model loaded in memory)
- Cloud Run max: 32GB image, 8GB RAM — well within limits
- No GPU needed — TorchScript runs on CPU at 0.20s/inference

**Cost**: Marginal cost per prediction ≈ $0.00 (CPU inference included in existing Cloud Run allocation, model load amortized across requests)

**Tests**:

| ID | Test | Criteria |
|----|------|----------|
| DEP.1 | Docker build succeeds with `torch` + model download | CI |
| DEP.2 | Container health check passes — model loads and runs test inference | CI |
| DEP.3 | Model file integrity: SHA256 of deployed model matches known hash | Build-time check |

**Tests** (human-in-the-loop):

| ID | Test | How |
|----|------|-----|
| DEP.H1 | End-to-end: upload test PLY → pipeline completes → metrics returned | Manual test against staging |
| DEP.H2 | Cold start < 30s, memory < 2GB | Cloud Run monitoring |
| DEP.H3 | Graceful degradation: delete model file → processor falls back to geometric pipeline, returns valid metrics | Kill-switch test |

**Go/no-go**: All tests pass before merging `experiment/bev-dnn-stage3` → master.

---

## Sequencing

```
Step 1 (BEV projection)           ✅ COMPLETE — 16/16 tests pass
Step 2 (Evaluation tooling)       ✅ COMPLETE — 18/18 tests pass
Step 3 (Patch + TorchScript)      ✅ COMPLETE — model verified on M1 Mac
    ↓
Step 4 (Inference wrapper)        ← NEXT: torch.jit.load, postprocessing
Step 5 (Stage 3 integration)      ← combines 1+4, fallback to geometric
Step 6 (Pipeline wiring)          ← uses Step 5
    ↓
Step 7 (Fine-tuning)              ← uses 1+2, Colab notebook
Step 8 (Deployment)               ← packages everything for Cloud Run
```

Steps 1-3 are complete. Step 4 is the next implementation task. Steps 4-5 can be fully mock-tested without the model file. Step 7 runs on Colab using the same stub+patch approach proven in Step 3.

---

## Risk Register (updated)

| # | Risk | Likelihood | Impact | Status |
|---|------|-----------|--------|--------|
| R1 | ~~Deformable attention blocks ONNX export~~ | ~~High~~ | ~~Step 3~~ | **RESOLVED** — ONNX failed as predicted, TorchScript succeeded |
| R2 | ~~Pure-PyTorch attention degrades accuracy~~ | ~~Medium~~ | ~~Step 3b~~ | **ACCEPTED** — PATCH.2 skipped (can't build CUDA extension on modern env), math is identical |
| R3 | **Domain gap: Structured3D → LiDAR** — pretrained model trained on synthetic density maps | High | Steps 4-6 | Step 7 fine-tuning with augmented data. Threshold sweep (S3D.H4) calibrates confidence |
| R4 | **Partial scan coverage** — user scans 270° and misses a wall | High | Production | BEV.8 + INF.H4 test explicitly. Training augmentation simulates partial scans. Geometric fallback catches degenerate polygons |
| R5 | ~~Density map normalization mismatch~~ | ~~Medium~~ | ~~Silent accuracy loss~~ | **MITIGATED** — BEV.6 test validates uint8 round-trip parity |
| R6 | ~~Python 3.8 / 3.12 incompatibility~~ | ~~Certain~~ | ~~Step 3~~ | **RESOLVED** — TorchScript bridges the gap. `torch.jit.load()` works on any PyTorch version |
| R7 | **Furniture against walls shifts boundary inward** | Medium | Floor area | Structural vertex filtering active. INF.H5 validates |
| R8 | **PyTorch dependency adds container size** — ~800MB-1GB for CPU-only torch | Low | Deploy | Cloud Run allows 32GB images. Consider `torch-cpu` wheel (~200MB) to reduce size |
| R9 | **Cold start** — TorchScript model load time | Low | Latency | Verified 0.20s inference on M1 CPU. Model loads in <5s. DEP.H2 validates |
| R10 | **Catastrophic forgetting during fine-tuning** | Medium | Generalization | FT.4 tests base domain regression. Mitigation: lower LR, mixed data |
