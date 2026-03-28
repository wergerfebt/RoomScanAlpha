# BEV DNN Stage 3 — Implementation Plan

## Context

Stage 3 (Room Geometry Assembly) extracts a closed room polygon + ceiling height from classified LiDAR meshes. Five geometric approaches have failed — RANSAC, alpha shapes, Douglas-Peucker, etc. all break on noisy LiDAR data, furniture occlusion, and ARKit classification errors. The root cause: this is a perception problem, not a geometry problem.

**Solution**: Replace the polygon extraction with a BEV DNN (RoomFormer, CVPR 2023, MIT license). Project mesh vertices to a 256x256 top-down density map, run a transformer that predicts room polygon vertices, convert back to meters. The existing wall extrusion, floor/ceiling polygon construction, and metric computation code stays unchanged — only the source of `corners_xz` changes.

**Branch**: `experiment/bev-dnn-stage3` — [pushed to GitHub](https://github.com/wergerfebt/RoomScanAlpha/tree/experiment/bev-dnn-stage3)

**Scope**: RoomFormer only. CAGE (NeurIPS 2025) is a future upgrade path.

---

## Current Status

### What's Done (Steps 1-8 + synthetic fine-tuning)

| Step | Status | Deliverables |
|------|--------|-------------|
| 1. BEV Projection | **DONE** | `bev_projection.py`, 16 tests, visualization script |
| 2. Evaluation Tooling | **DONE** | `evaluate_polygon.py`, 18 tests |
| 3. Model Export | **DONE** | TorchScript export via Colab (ONNX failed) |
| 4. Inference Wrapper | **DONE** | `bev_inference.py`, 15 tests (mock + real model) |
| 5. Stage 3 Integration | **DONE** | `use_dnn` param on `assemble_geometry()`, geometric fallback, 13 tests |
| 6. Pipeline Wiring | **DONE** | `USE_DNN_STAGE3` env var in `main.py`, 9 tests |
| 7. Fine-Tuning Pipeline | **DONE** (pipeline only) | `generate_training_data.py`, `finetune_roomformer.py`, Colab notebook |
| 8. Deployment Config | **DONE** (config only) | Dockerfile, requirements.txt, model path env var |

**107 automated tests pass.** Pipeline is wired end-to-end.

### Synthetic Fine-Tuning Results (completed)

Fine-tuned on 500 synthetic box rooms (varied dimensions, rotations, augmentation), 50 epochs on Colab T4 GPU.

| Scan | Pretrained | Fine-tuned (synthetic) | Target |
|------|-----------|----------------------|--------|
| Scan 2 (6-corner simple room) | 59% area error, 7 corners | **15% area error, 6 corners** | < 10% |
| Scan 1 (11-corner irregular room) | 41% area error, 4 corners | 39% area error, 5 corners | < 10% |

**Scan 2 improved dramatically** — correct corner count, polygon traces the room boundary. **Scan 1 is still poor** — synthetic box rooms don't teach the model about L-shapes and hallways. Real training data is needed.

### What's NOT Done

| Item | What's Needed | Blocked By |
|------|--------------|-----------|
| **Real training data** | 50+ annotated real LiDAR scans | No annotation method exists yet |
| **AR corner annotation (iOS)** | App feature for users to tap room corners during/after scan | iOS development |
| **Fine-tuning on real data** | Re-run Colab notebook with real + synthetic data | Real training data |
| **Production deployment** | `gcloud run deploy` with model in GCS | Accuracy must meet threshold first |
| **Merge to master** | All tests pass + accuracy on real scans < 10% area error | Fine-tuning on real data |

---

## What Needs to Happen Next

### Phase 1: Build Training Data Collection (iOS + Cloud)

The model works but needs real room scans with correct polygon annotations to improve accuracy on complex rooms. There are three paths to get annotations, in order of priority:

#### Path A: AR Corner Annotation in iOS App (RECOMMENDED — highest quality)

**What**: After a user finishes scanning, the app prompts "Tap each room corner at floor level." Each tap does an ARKit raycast → precise 3D world coordinate. The corners are saved in `metadata.json` alongside the scan upload.

**iOS work required**:
1. New UI screen after scan completion: "Mark Room Corners"
2. AR overlay showing the scanned room with tap targets
3. ARKit raycast on each tap → capture `worldTransform` XZ position
4. Store as `corner_annotations` array in scan metadata
5. Upload with the scan package to GCS

**Metadata format** (added to existing `metadata.json`):
```json
{
    "corner_annotations": {
        "corners_xz": [[-2.5, -1.8], [2.5, -1.8], [2.5, 3.0], [-2.5, 3.0]],
        "annotation_method": "ar_tap",
        "annotator_uid": "firebase_user_id",
        "timestamp": "2026-03-28T10:00:00Z"
    }
}
```

**Cloud work required**:
1. Processor extracts `corner_annotations` from metadata after PLY processing
2. If present, saves to `gs://roomscanalpha-scans/training/{scan_id}/ground_truth.json`
3. Adds `training_status = 'annotated'` to `scanned_rooms` row

**Pros**: Precise 3D coordinates, zero post-processing, scales with user count.
**Effort**: ~1-2 weeks iOS, ~1 day cloud.

#### Path B: Web Annotation Tool (QUICK — medium quality)

**What**: A simple web page that loads BEV density map PNGs and lets you click room corners. Converts pixel clicks to XZ meters and saves `ground_truth.json`.

**Pros**: No app changes, works on existing scans, quick to build.
**Cons**: Less precise (guessing from grayscale image), manual labor.
**Effort**: ~2-3 days web development.

#### Path C: Auto-Approve Geometric Output (ZERO EFFORT — low quality)

**What**: For simple rectangular rooms where the geometric Stage 3 succeeded, auto-approve the geometric polygon as pseudo ground truth.

**Filter criteria**:
- `scan_status = 'complete'`
- Floor area between 50-2000 sqft
- Corner count is 4-6
- No self-intersecting polygon
- All wall lengths > 0.5m

**Pros**: Zero annotation effort, immediate volume.
**Cons**: Only works for simple rooms, perpetuates geometric errors.
**Effort**: ~1 day scripting.

#### Recommended Approach

1. **Now**: Run Path C on any existing successful scans to bootstrap training data
2. **This week**: Build Path B (web tool) for manual annotation of complex rooms
3. **Next sprint**: Build Path A (AR annotation) for ongoing high-quality data collection
4. **Ongoing**: Every scan with AR annotations auto-feeds the training pipeline

### Phase 2: Fine-Tune on Real Data

Once 50+ annotated real scans exist:

```bash
# Download annotated scans from GCS
gsutil -m cp -r gs://roomscanalpha-scans/training/ ./training_scans/

# Generate training data (real + synthetic)
python scripts/generate_training_data.py \
    --scan-dir ./training_scans/ \
    --output training_data/ \
    --num-synthetic 500

# Upload to Colab and run RoomFormer_Finetune.ipynb
# Download roomformer_finetuned.pt
# Test against real scans
```

**Target accuracy**: < 10% floor area error on both test scans.

### Phase 3: Deploy

Once accuracy meets threshold:

```bash
# Upload model to GCS
gsutil cp models/roomformer_finetuned.pt gs://roomscanalpha-models/roomformer_finetuned.pt

# Deploy with DNN enabled
gcloud run deploy scan-processor \
    --source=processor/ \
    --region=us-central1 \
    --set-env-vars="USE_DNN_STAGE3=true,ROOMFORMER_MODEL_PATH=/app/models/roomformer_finetuned.pt" \
    --no-allow-unauthenticated
```

---

## Scan-to-Training Data Flow

```
iOS App (scan + optional AR annotation)
    │
    ▼
gs://roomscanalpha-scans/scans/{rfq_id}/{scan_id}.zip
    │                          ├── mesh.ply
    │                          ├── metadata.json  ← may include corner_annotations
    │                          └── keyframes/, depth/
    │
    ▼
Cloud Run Processor
    │  ├── Parse PLY, compute metrics, write to DB
    │  └── If corner_annotations in metadata:
    │         copy mesh.ply + ground_truth.json to training/
    │
    ▼
gs://roomscanalpha-scans/training/{scan_id}/
    │  ├── mesh.ply
    │  └── ground_truth.json  ← {"corners_xz": [[x,z], ...]}
    │
    ▼
generate_training_data.py (local or Colab)
    │  ├── mesh.ply → BEV density map (256x256 PNG)
    │  ├── ground_truth.json → COCO polygon annotation
    │  └── + 500 synthetic augmented samples
    │
    ▼
training_data/
    │  ├── density/00000.png ...
    │  └── annotations.json
    │
    ▼
RoomFormer_Finetune.ipynb (Colab T4 GPU, ~15 min)
    │
    ▼
roomformer_finetuned.pt → deploy to Cloud Run
```

---

## Model Versions

| File | Description | Accuracy |
|------|------------|----------|
| `roomformer_pretrained.pt` | Original Structured3D weights | 41-59% area error on real scans |
| `roomformer_finetuned.pt` | Fine-tuned on 500 synthetic rooms | 15-39% area error on real scans |
| `roomformer_finetuned_v2.pt` | *(future)* + 50 real annotated scans | Target: < 10% |
| `roomformer_finetuned_v3.pt` | *(future)* + 200 real scans | Target: < 5% |

Model path is configurable via `ROOMFORMER_MODEL_PATH` env var or `DEFAULT_MODEL_NAME` in `bev_inference.py`.

---

## Known Constraints

1. **TorchScript only** — ONNX export failed (data-dependent shapes in Deformable DETR). Inference uses `torch.jit.load()` on CPU.
2. **1-channel input** — Pretrained weights expect `[B, 1, 256, 256]`. Do NOT stack to 3 channels.
3. **Ceiling in BEV floods interior corners** — Ceiling vertices project as a filled rectangle, drowning L-shape corners. Wall-only BEV is cleaner but pretrained model can't use it (wasn't trained that way). Future fine-tuning experiment: train on wall-only density maps.
4. **Synthetic-only training insufficient for complex rooms** — Box rooms don't teach L-shapes, hallways, or irregular polygons. Real annotated scans are essential.
5. **0.20s inference on M1 CPU** — Well within the 5s target. No GPU needed.

---

## Completed Steps (Detail)

### Step 1: BEV Projection Module — COMPLETE

16/16 automated tests pass. BEV.H1/H2 visual inspection passed.

**Deliverables**: `bev_projection.py`, `test_bev_projection.py`, `visualize_bev.py`

### Step 2: Ground Truth Extraction + Baseline Metrics — COMPLETE

18/18 automated tests pass.

**Deliverables**: `evaluate_polygon.py`, `test_evaluate_polygon.py`

### Step 3: Deformable Attention Patch + Model Export — COMPLETE

TorchScript export succeeded on Colab. ONNX failed. Model verified locally.

**Deliverables**: `RoomFormer_ONNX_Export.ipynb`, `patch_roomformer.py`, `models/README.md`

### Step 4: Inference Wrapper — COMPLETE

15/15 tests pass (8 mock + 3 model-dependent + 4 helpers).

**Deliverables**: `bev_inference.py`, `test_bev_inference.py`

### Step 5: Stage 3 DNN Path + Geometric Fallback — COMPLETE

13/13 tests pass. DNN exceptions are caught and fall back to geometric silently.

**Deliverables**: Modified `stage3.py` (`use_dnn`, `model_path` params), `test_stage3_dnn.py`

### Step 6: Pipeline Integration — COMPLETE

9/9 tests pass. `USE_DNN_STAGE3` env var controls routing.

**Deliverables**: Modified `main.py`, `test_main_metrics.py`

### Step 7: Fine-Tuning Pipeline — COMPLETE (pipeline built, awaiting real data)

Scripts and Colab notebook ready. Synthetic-only fine-tuning completed and validated.

**Deliverables**: `generate_training_data.py`, `finetune_roomformer.py`, `RoomFormer_Finetune.ipynb`, `training_data.zip`

### Step 8: Deployment Config — COMPLETE (config ready, awaiting accuracy threshold)

Dockerfile updated, requirements updated, env vars configured.

**Deliverables**: Updated `Dockerfile`, `requirements.txt`

---

## Risk Register

| # | Risk | Status |
|---|------|--------|
| R1 | ~~ONNX export blocked~~ | **RESOLVED** — TorchScript succeeded |
| R2 | ~~Pure-PyTorch attention accuracy~~ | **ACCEPTED** — math is identical |
| R3 | **Domain gap: synthetic → real LiDAR** | **PARTIALLY MITIGATED** — synthetic fine-tuning closed gap on simple rooms (59%→15%). Complex rooms need real data. |
| R4 | **Partial scan coverage** | **OPEN** — augmentation simulates this but not validated on real partial scans |
| R5 | ~~Density map normalization~~ | **MITIGATED** — uint8 round-trip validated |
| R6 | ~~Python version incompatibility~~ | **RESOLVED** — TorchScript bridges the gap |
| R7 | **Ceiling floods interior corners in BEV** | **IDENTIFIED** — ceiling vertices mask L-shape corners. Wall-only BEV is cleaner but model wasn't trained on it. Experiment during next fine-tuning round. |
| R8 | **No training data collection path** | **OPEN** — need AR annotation in iOS app or web annotation tool |
| R9 | **Cold start** | **LOW RISK** — 0.20s inference verified |
| R10 | **Catastrophic forgetting** | **ACCEPTABLE** — synthetic fine-tuning at 5-14% error on held-out synthetic validation |

---

## File Structure

```
cloud/processor/
    pipeline/
        stage1.py               # Parse PLY mesh (unchanged)
        stage2.py               # Find floor/ceiling planes (unchanged)
        stage3.py               # MODIFIED — use_dnn param, _extract_dnn_polygon()
        bev_projection.py       # NEW — 3D mesh → 256x256 density map
        bev_inference.py        # NEW — TorchScript model wrapper + postprocessing

    main.py                     # MODIFIED — USE_DNN_STAGE3 env var routing

    models/
        roomformer_pretrained.pt  # Original Structured3D weights (158 MB, gitignored)
        roomformer_finetuned.pt   # Synthetic fine-tuned (165 MB, gitignored)
        .gitignore
        README.md

    scripts/
        visualize_bev.py          # BEV density map PNG generation
        evaluate_polygon.py       # Polygon comparison metrics
        generate_training_data.py # BEV + polygon pairs for training
        finetune_roomformer.py    # Fine-tuning script
        RoomFormer_ONNX_Export.ipynb   # Colab: model export
        RoomFormer_Finetune.ipynb      # Colab: fine-tuning

    tests/
        test_bev_projection.py    # 16 tests
        test_bev_inference.py     # 15 tests
        test_stage3_dnn.py        # 13 tests
        test_main_metrics.py      #  9 tests
        test_evaluate_polygon.py  # 18 tests

    Dockerfile                  # Updated for DNN dependencies
    requirements.txt            # Added torch, shapely
    BEV_DNN_GUIDE.md            # Plain-language explainer
    TRAINING_DATA_FLOW.md       # Scan → training data pipeline

cloud/dnn_comparison/
    BEV_DNN_IMPLEMENTATION_PLAN.md  # This file
    COMPARISON_FRAMEWORK.md
    HORIZONNET_PAPER.md
    ROOMFORMER_PAPER.md
    BEV_DNN_PAPER.md
```
