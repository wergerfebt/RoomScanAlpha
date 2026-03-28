# Training Data Flow — From App Scan to Fine-Tuned Model

## Overview

To improve the BEV DNN's accuracy on real LiDAR scans, we need paired training
data: a density map + the correct room polygon for each scan. This document
explains how scans move through the system and become training data.

```
iPhone App                     GCS Bucket                    Training Pipeline
──────────                     ──────────                    ─────────────────
User scans room          ───→  scans/{rfq_id}/{scan_id}.zip
                                    │
                                    ├── mesh.ply
                                    ├── keyframes/
                                    ├── depth/
                                    └── metadata.json
                                    │
Cloud Run Processor       ←────────┘
  │
  ├── Stage 1: parse PLY
  ├── Stage 2: find planes
  ├── Stage 3: extract polygon (DNN or geometric)
  └── Write results to Cloud SQL
                                    │
Annotation (future)       ←────────┘
  │
  ├── Option A: AR annotation in-app (user taps corners)
  ├── Option B: Web tool (you draw on density map)
  └── Option C: Auto-approve geometric output for simple rooms
                                    │
                                    ▼
                           training/{scan_id}/
                                    ├── mesh.ply (copy from scans/)
                                    └── ground_truth.json
                                    │
generate_training_data.py  ←───────┘
  │
  ├── mesh.ply → BEV density map (256x256 PNG)
  ├── ground_truth.json → COCO polygon annotation
  └── + synthetic augmentation
                                    │
                                    ▼
                           training_data/
                                    ├── density/00000.png ...
                                    └── annotations.json
                                    │
finetune_roomformer.py     ←───────┘  (runs on Colab)
  │
  └── roomformer_finetuned.pt
                                    │
Deploy to Cloud Run        ←───────┘
```

---

## Step-by-Step: How a Scan Becomes Training Data

### 1. User Scans a Room (iOS App)

The app creates a scan package and uploads it to GCS:

```
gs://roomscanalpha-scans/scans/{rfq_id}/{scan_id}.zip
```

The zip contains:
- `mesh.ply` — binary LiDAR mesh with per-face ARKit classifications
- `keyframes/` — JPEG images from the scan
- `depth/` — per-frame depth maps
- `metadata.json` — camera intrinsics, device info

**This already works.** No app changes needed for the scan itself.

### 2. Processor Processes the Scan (Cloud Run)

The existing Cloud Run processor downloads the zip, parses the PLY, computes
room metrics, and writes results to the `scanned_rooms` table in Cloud SQL.

The PLY file **stays in GCS** after processing. This is our raw data archive.

### 3. Mark a Scan for Training (Manual Step — You Do This)

Not every scan should be training data. You pick which scans have reliable
room boundaries and create a ground truth annotation.

**Where to store annotated scans:**

```
gs://roomscanalpha-scans/training/{scan_id}/
    mesh.ply              # Copy from the original scan
    ground_truth.json     # You create this
```

**The `ground_truth.json` format:**

```json
{
    "corners_xz": [
        [-2.5, -1.8],
        [ 2.5, -1.8],
        [ 2.5,  1.2],
        [ 0.5,  1.2],
        [ 0.5,  3.0],
        [-2.5,  3.0]
    ],
    "scan_id": "abc123",
    "annotator": "jake",
    "annotation_method": "web_tool",
    "notes": "L-shaped kitchen, good scan coverage"
}
```

The `corners_xz` are real-world XZ coordinates in meters (ARKit coordinate
system — same as the PLY vertex positions). Order them counter-clockwise.

### 4. Three Ways to Create `ground_truth.json`

#### Option A: AR Annotation in the iOS App (Best Quality, Future Feature)

After scanning, the app prompts: "Tap each room corner at floor level."
Each tap does an ARKit raycast and records the 3D world coordinate.
The corners get saved in `metadata.json` alongside the scan.

**Pros:** Precise 3D coordinates, no post-processing, scales with user count.
**Cons:** Requires iOS development, users may tap wrong spots.
**Status:** Not built yet.

#### Option B: Web Annotation Tool (Medium Quality, Quick to Build)

A web page shows the BEV density map. You click the room corners on the image.
The tool converts pixel clicks to XZ meter coordinates and saves `ground_truth.json`.

**Pros:** No app changes, works on existing scans.
**Cons:** Less precise (you're guessing from a grayscale image), manual labor.
**Status:** Not built yet, but straightforward to implement.

#### Option C: Auto-Approve Geometric Output (Low Quality, Zero Labor)

For simple rectangular rooms where the geometric Stage 3 works well (~60-70%
of scans), auto-approve the geometric output as pseudo ground truth.

**How to identify good geometric results:**
- Floor area is between 50-2000 sqft
- Corner count is 4-8
- No self-intersecting polygon
- Wall lengths are all > 0.5m

**Pros:** Zero manual annotation, large volume immediately.
**Cons:** Only works for simple rooms, perpetuates geometric errors.
**Status:** Can be scripted today.

#### Recommended Approach

Start with **Option C** (auto-approve simple rooms) to get 200+ samples quickly.
Build **Option B** (web tool) for complex rooms where geometric fails.
Plan **Option A** (AR annotation) as a long-term iOS feature.

### 5. Download Training Data + Generate Density Maps

```bash
# Download annotated scans from GCS to local machine
gsutil -m cp -r gs://roomscanalpha-scans/training/ ./training_scans/

# Generate training data (density maps + COCO annotations)
cd cloud/processor
python scripts/generate_training_data.py \
    --scan-dir ./training_scans/ \
    --output ./training_data/ \
    --num-synthetic 500
```

This produces:
```
training_data/
    density/        # 256x256 PNGs (mix of real + synthetic)
    annotations.json  # COCO-format polygon annotations
```

### 6. Fine-Tune on Colab

Upload `training_data/` to Google Drive or directly to Colab, then run:

```python
!python finetune_roomformer.py \
    --roomformer-dir /content/RoomFormer \
    --checkpoint /content/RoomFormer/checkpoints/roomformer_stru3d.pth \
    --training-data /content/training_data/ \
    --output /content/roomformer_finetuned.pt \
    --epochs 50 --lr 1e-5
```

Download the resulting `roomformer_finetuned.pt` and place it in:
```
cloud/processor/models/roomformer_s3d.pt   (replace the pretrained one)
```

### 7. Deploy Updated Model

Upload the fine-tuned model to GCS and redeploy:

```bash
gsutil cp models/roomformer_s3d.pt gs://roomscanalpha-models/roomformer_s3d.pt
gcloud run deploy scan-processor --source=. --region=us-central1
```

---

## GCS Bucket Structure

```
gs://roomscanalpha-scans/
    scans/                          # Production scan uploads (existing)
        {rfq_id}/
            {scan_id}.zip           # Raw scan package from iOS app

    training/                       # Training data (new)
        {scan_id}/
            mesh.ply                # Copy of the production PLY
            ground_truth.json       # Annotated room polygon

gs://roomscanalpha-models/          # Model hosting (new bucket)
    roomformer_s3d.pt               # Current production model
    roomformer_s3d_v2.pt            # After first fine-tuning
    roomformer_s3d_v3.pt            # After second fine-tuning, etc.
```

---

## Database Changes (Optional — For Tracking)

To track which scans have been annotated and used for training, add a column
to `scanned_rooms`:

```sql
ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS
    training_status VARCHAR(20) DEFAULT NULL;
-- Values: NULL (not reviewed), 'approved' (good for training),
--         'rejected' (bad scan), 'annotated' (has ground_truth.json)
```

This lets you query for training candidates:

```sql
-- Scans that completed successfully but haven't been reviewed for training
SELECT id, rfq_id, floor_area_sqft, scan_dimensions
FROM scanned_rooms
WHERE scan_status = 'complete'
  AND training_status IS NULL
ORDER BY created_at DESC;
```

---

## How Many Scans Do You Need?

| Phase | Real Scans | Synthetic | Total | Expected Accuracy |
|-------|-----------|-----------|-------|-------------------|
| Current (pretrained) | 0 | 0 | 0 | ~40-60% area error |
| Phase 1 (quick start) | 0 | 500 | 500 | ~20-30% area error (maybe) |
| Phase 2 (first real data) | 10-20 | 500 | 520 | ~15-20% area error |
| Phase 3 (friends scan) | 50 | 500 | 550 | ~10-15% area error |
| Phase 4 (production) | 200+ | 500 | 700+ | < 10% area error (goal) |

Synthetic-only fine-tuning (Phase 1) can be done today — no real scans needed.
It will partially close the domain gap because our synthetic rooms are generated
with the same BEV projection code that processes real scans.
