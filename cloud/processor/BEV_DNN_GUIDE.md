# How the BEV DNN Works — A Plain-Language Guide

## What Problem Does This Solve?

When a user scans a room with their iPhone/iPad, we get a 3D mesh — millions of tiny triangles representing the walls, floor, ceiling, and furniture. We need to figure out the **room's floor plan**: where are the walls? What shape is the room? How many square feet?

This sounds simple — just find the walls and trace the outline. But in practice, the raw scan data is messy:
- Furniture gets misclassified as walls (cabinets look like walls to the sensor)
- Some walls are only partially scanned (the user didn't point the phone there)
- The sensor puts random noise triangles everywhere

We tried five different math-based approaches (geometric algorithms) to trace the room outline. All five failed on real scans. The walls are too noisy, the furniture pulls the boundary inward, and coverage gaps leave holes.

**The BEV DNN is a different approach**: instead of writing rules to find walls, we use a neural network (AI model) that was trained on thousands of room layouts. It looks at the scan data from above — like a bird looking down at a building without a roof — and predicts where the room corners are.

## How It Works, Step by Step

### Step 1: Make a Bird's-Eye Picture

Imagine looking straight down at the room from above. The walls would appear as lines, and the floor would be the space between them.

We take all the 3D points from the scan and "flatten" them onto a 2D grid (256x256 pixels), keeping only the X and Z coordinates (dropping the height). Points that belong to walls, doors, and windows are included. Points that belong to furniture (tables, chairs) are filtered out.

The result is a small grayscale image called a **density map** where bright pixels = lots of 3D points stacked up there (walls), and dark pixels = empty space.

**File**: `pipeline/bev_projection.py`

```
3D scan (millions of points)
    |
    v
Filter to wall/door/window points only
    |
    v
Look straight down (drop the height axis)
    |
    v
256x256 grayscale image (density map)
```

### Step 2: Ask the AI "Where Are the Room Corners?"

The density map goes into **RoomFormer**, a neural network published by ETH Zurich in 2023. It was trained on 21,000+ synthetic room layouts (the Structured3D dataset). The model looks at the density map image and predicts:

- **Up to 20 rooms** (we only care about 1 — our scan is a single room)
- **Up to 40 corners per room** (a typical room has 4-11)
- **A confidence score** for each corner (how sure the model is)

The model runs on CPU — no GPU needed. It takes about 0.2 seconds on a Mac and would take 1-3 seconds on Cloud Run.

**File**: `pipeline/bev_inference.py`

### Step 3: Convert Back to Real-World Measurements

The model outputs corner positions in pixel coordinates (e.g., "pixel 51, pixel 204"). We convert these back to real-world meters using the scale factor from Step 1. The corners form a closed polygon — the room's floor plan.

Ceiling height comes from a separate, simpler calculation (just measuring the Y-distance between floor and ceiling points — this already works well).

**File**: `pipeline/bev_projection.py` (the `pixels_to_meters` function)

### Step 4: Build the 3D Room Model

The 2D polygon + ceiling height are used to construct a simplified 3D room: flat floor, flat ceiling, vertical walls connecting them. This is the same wall-extrusion code we've always had — only the polygon source changed.

**File**: `pipeline/stage3.py`

## Where Does the Model Run?

**The model runs locally in the Cloud Run processor container.** There is no external API call, no separate GPU server, and no internet connection needed at inference time.

```
User's phone scan
    |
    v
Upload to GCS (Cloud Storage)
    |
    v
Cloud Run Processor (this is where the model runs)
    |-- Stage 1: Parse the PLY mesh file
    |-- Stage 2: Find floor/ceiling planes (RANSAC)
    |-- Stage 3: Extract room polygon  <-- THE BEV DNN LIVES HERE
    |-- Stage 4: Compute measurements (sq ft, perimeter, etc.)
    |
    v
Write results to Cloud SQL database
```

The model file (`roomformer_s3d.pt`, 158 MB) is baked into the Docker container image at build time. When the container starts, it loads the model into memory once. Every subsequent scan reuses the loaded model.

## Where Does the Model Come From?

The model was **trained by researchers at ETH Zurich** on 21,000 synthetic rooms. We downloaded their pretrained weights and converted them to a format (TorchScript) that runs on any machine with PyTorch — no GPU, no CUDA, no special hardware.

The conversion was done on Google Colab (a free cloud notebook with a GPU). The Colab notebook is saved at `scripts/RoomFormer_ONNX_Export.ipynb` in case we ever need to re-export.

**The model needs fine-tuning.** The pretrained model was trained on clean, synthetic rooms. Our real LiDAR scans are noisier, have coverage gaps, and look different. Right now the model gets rooms roughly right but is off by 40-60% on area. Step 7 of the implementation plan covers fine-tuning on our own scan data to improve accuracy.

## How Is It Turned On/Off?

An environment variable controls whether the DNN is used:

```bash
# In Cloud Run or local development:
USE_DNN_STAGE3=true   # Use the neural network
USE_DNN_STAGE3=false  # Use the old geometric approach (default)
```

If the DNN fails for any reason (model file missing, bad input, network produces garbage), it **automatically falls back** to the geometric approach. The pipeline never crashes.

## File Structure

```
cloud/processor/
    pipeline/
        stage1.py               # Parse PLY mesh (unchanged)
        stage2.py               # Find floor/ceiling planes (unchanged)
        stage3.py               # Room polygon extraction (MODIFIED)
                                #   - assemble_geometry() now accepts use_dnn=True
                                #   - _extract_dnn_polygon() calls BEV → model → meters
                                #   - Falls back to geometric if DNN fails
        bev_projection.py       # NEW: 3D mesh → 256x256 density map
        bev_inference.py        # NEW: Load model, run inference, post-process corners

    main.py                     # MODIFIED: USE_DNN_STAGE3 env var routing

    models/
        roomformer_s3d.pt       # The neural network weights (158 MB, gitignored)
        .gitignore              # Keeps .pt/.onnx files out of git
        README.md               # How to reproduce the model export

    scripts/
        visualize_bev.py        # Generate density map PNGs for debugging
        evaluate_polygon.py     # Compare predicted vs ground truth polygons
        patch_roomformer.py     # Patches RoomFormer for CPU inference
        export_roomformer_onnx.py  # Exports model (used by Colab notebook)
        launch_export_vm.sh     # Alternative: export on a GCE VM
        export_on_vm.sh         # Script that runs on the VM
        RoomFormer_ONNX_Export.ipynb  # Colab notebook for model export

    tests/
        test_bev_projection.py  # 16 tests: density map generation
        test_bev_inference.py   # 15 tests: model inference + post-processing
        test_stage3_dnn.py      # 13 tests: Stage 3 DNN path + fallback
        test_main_metrics.py    #  9 tests: pipeline integration
        test_evaluate_polygon.py # 18 tests: polygon comparison metrics

cloud/dnn_comparison/
    COMPARISON_FRAMEWORK.md     # Scoring rubric for technology comparison
    HORIZONNET_PAPER.md         # HorizonNet evaluation (rejected: needs panoramas)
    ROOMFORMER_PAPER.md         # RoomFormer evaluation (selected)
    BEV_DNN_PAPER.md            # BEV DNN family evaluation (selected)
    BEV_DNN_IMPLEMENTATION_PLAN.md  # Step-by-step plan with test matrix
```

## Current Status

| Step | Status | What It Does |
|------|--------|-------------|
| 1. BEV Projection | Done | Converts 3D mesh to bird's-eye-view image |
| 2. Evaluation Tooling | Done | Measures how good the predicted polygon is |
| 3. Model Export | Done | Converted RoomFormer to run on CPU (TorchScript) |
| 4. Inference Wrapper | Done | Loads model, runs prediction, filters results |
| 5. Stage 3 Integration | Done | Plugged DNN into the room geometry pipeline |
| 6. Pipeline Wiring | Done | Connected to compute_room_metrics() with env var |
| 7. Fine-Tuning | Not started | Train the model on OUR scans to improve accuracy |
| 8. Deployment | Not started | Package into Docker for Cloud Run |

**107 automated tests pass.** The pretrained model produces results but needs fine-tuning (Step 7) to be accurate on our LiDAR data.

## Glossary

| Term | Meaning |
|------|---------|
| **BEV** | Bird's-Eye View — looking straight down from above |
| **DNN** | Deep Neural Network — an AI model that learns patterns from data |
| **Density map** | A 256x256 grayscale image where brightness = point density |
| **RoomFormer** | The specific neural network model we use (by ETH Zurich, 2023) |
| **TorchScript** | A format for saving PyTorch models so they run without Python overhead |
| **RANSAC** | A math algorithm for finding flat surfaces (planes) in noisy data |
| **PLY** | The 3D file format our scanner produces (mesh of triangles) |
| **Polygon** | The room floor plan — a closed shape defined by corner points |
| **Fine-tuning** | Re-training a model on our specific data to improve accuracy |
| **Structured3D** | The synthetic dataset (21,000 rooms) the model was originally trained on |
