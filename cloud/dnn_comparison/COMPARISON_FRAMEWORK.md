# DNN Room Layout Estimation — Technology Comparison

> **Goal**: Select the best DNN approach to replace the failed geometric Stage 3 (Room Geometry Assembly) in the RoomScanAlpha cloud pipeline. The chosen model must produce clean room polygons from noisy LiDAR scan data uploaded by iOS and Android users.

## Context

Stage 3 currently attempts to extract room perimeters from classified LiDAR meshes using geometric heuristics (RANSAC, alpha shapes, Douglas-Peucker, etc.). All five geometric approaches failed due to:
- Incomplete LiDAR coverage / mesh gaps
- ARKit classification noise (furniture misclassified as walls, cabinet edges bleeding into ceiling)
- Inability to handle non-rectangular rooms

The replacement must be a learned model that can infer room layout despite noisy/incomplete input.

---

## Candidates

| # | Technology | Paper Agent |
|---|-----------|-------------|
| 1 | **HorizonNet** — Panorama-based 1D room layout estimation | Agent A |
| 2 | **RoomFormer** — Transformer-based floorplan polygon prediction (Vertex AI) | Agent B |
| 3 | **BEV-based DNNs** — Bird's-eye-view projection + segmentation/detection | Agent C |

---

## Paper Requirements

Each agent must produce a `.md` file in this folder (`dnn_comparison/`) with the following sections. Be thorough but concise — aim for 400-800 lines.

### Required Sections

#### 1. Executive Summary (5-10 sentences)
- What the approach does at a high level
- Why it's a candidate for RoomScanAlpha's Stage 3

#### 2. Architecture & How It Works
- Model architecture (backbone, heads, loss functions)
- Input representation (what data it consumes, how it's prepared)
- Output representation (what it produces — polygons, heatmaps, corners, edges)
- Inference pipeline (preprocessing → model → postprocessing)

#### 3. Input Compatibility with RoomScanAlpha
- **What we have**: PLY mesh (vertices + faces + ARKit classifications), camera poses, depth maps, RGB keyframes, point cloud
- **What the model needs**: Describe exactly what input the model expects
- **Gap analysis**: What preprocessing/conversion is needed to bridge our scan data to the model's expected input? How lossy is this conversion?
- **Non-rectangular room support**: Can it handle L-shapes, irregular polygons, curved walls?

#### 4. Output Compatibility with RoomScanAlpha
- **What Stage 3 must produce**: A closed 2D polygon (list of vertices) representing the room floor boundary, plus ceiling height. These feed into `floor_area` (sq ft), `wall_area` (sq ft), `perimeter` (ft), `ceiling_height` (ft) in the `scanned_rooms` table.
- **What the model outputs**: Describe the raw output format
- **Postprocessing needed**: Steps to convert model output → closed polygon + height

#### 5. Accuracy & Performance
- Published accuracy metrics (IoU, corner error, edge error) on standard benchmarks (Structured3D, ScanNet, Zillow, etc.)
- Performance on non-rectangular / complex rooms specifically
- Known failure modes and limitations
- Inference latency (per-room, on GPU)

#### 6. Integration with GCP / Vertex AI
- Can this run on Vertex AI endpoints? What serving infrastructure is needed?
- GPU requirements (type, VRAM)
- Container packaging complexity
- Batch vs. real-time inference fit
- Estimated cost per prediction

#### 7. Training & Fine-Tuning
- Is the pretrained model sufficient, or must we fine-tune on our data?
- What training data do we need? How much?
- Training compute requirements
- How hard is it to fine-tune on a custom dataset (our LiDAR scans)?

#### 8. Maturity & Community
- Paper publication date and venue
- GitHub repo: stars, last commit, open issues
- License (commercial use OK?)
- Active maintenance? Community adoption?
- Any production deployments known?

#### 9. Risks & Mitigations
- Top 3-5 risks specific to this approach for our use case
- Proposed mitigations for each

#### 10. Recommendation
- Overall assessment: strong fit / moderate fit / poor fit
- Key strengths for RoomScanAlpha
- Key weaknesses for RoomScanAlpha
- Suggested proof-of-concept scope if selected

---

## Comparison Metrics

After all three papers are submitted, they will be scored on the following metrics. Each metric is rated **1-5** (1 = poor, 5 = excellent).

### Fit Metrics (weighted 3x — most important)

| Metric | What It Measures | Weight |
|--------|-----------------|--------|
| **Input compatibility** | How well does our scan data (PLY mesh, depth maps, keyframes, poses) map to the model's expected input? Less conversion = higher score. | 3x |
| **Output compatibility** | How directly does the model output map to a closed room polygon + height? Less postprocessing = higher score. | 3x |
| **Non-rectangular room support** | Can it handle L-shaped, irregular, and complex floor plans? | 3x |
| **Noise/gap tolerance** | How robust is it to incomplete LiDAR coverage, classification errors, and furniture occlusion? | 3x |

### Performance Metrics (weighted 2x)

| Metric | What It Measures | Weight |
|--------|-----------------|--------|
| **Accuracy (IoU)** | Published room layout IoU on standard benchmarks | 2x |
| **Corner/edge accuracy** | Precision of predicted corners and edges vs. ground truth | 2x |
| **Inference speed** | Time per room on a cloud GPU (target: < 10s) | 2x |

### Engineering Metrics (weighted 1x)

| Metric | What It Measures | Weight |
|--------|-----------------|--------|
| **Vertex AI deployability** | Ease of packaging and serving on Vertex AI endpoints | 1x |
| **Fine-tuning feasibility** | Can we improve it with our own data? How much data/compute? | 1x |
| **Maturity & support** | Code quality, maintenance, community, license | 1x |
| **Implementation effort** | Estimated engineering weeks to integrate into the cloud pipeline | 1x |

### Cost Metrics (weighted 1x)

| Metric | What It Measures | Weight |
|--------|-----------------|--------|
| **GPU cost per prediction** | Estimated $/room on Vertex AI | 1x |
| **Training/fine-tuning cost** | One-time cost to get the model production-ready | 1x |

### Scoring

- **Weighted total** = sum of (score x weight) across all metrics
- Maximum possible = 5 x (4x3 + 3x2 + 4x1 + 2x1) = 5 x 24 = **120**
- Minimum viable score for consideration: **72** (60%)

---

## Comparison Scorecard (to be filled after papers are submitted)

| Metric | Weight | HorizonNet | RoomFormer | BEV DNN |
|--------|--------|-----------|------------|---------|
| Input compatibility | 3x | | | |
| Output compatibility | 3x | | | |
| Non-rect room support | 3x | | | |
| Noise/gap tolerance | 3x | | | |
| Accuracy (IoU) | 2x | | | |
| Corner/edge accuracy | 2x | | | |
| Inference speed | 2x | | | |
| Vertex AI deployability | 1x | | | |
| Fine-tuning feasibility | 1x | | | |
| Maturity & support | 1x | | | |
| Implementation effort | 1x | | | |
| GPU cost per prediction | 1x | | | |
| Training/fine-tuning cost | 1x | | | |
| **Weighted Total** | | **/120** | **/120** | **/120** |

---

## File Naming Convention

| Agent | File |
|-------|------|
| Agent A | `HORIZONNET_PAPER.md` |
| Agent B | `ROOMFORMER_PAPER.md` |
| Agent C | `BEV_DNN_PAPER.md` |
| Comparison | `COMPARISON_FRAMEWORK.md` (this file) |
| Final scorecard | `SCORECARD.md` (created after all papers are in) |

---

## Decision Criteria

After scoring:
1. Any candidate below 72/120 is eliminated
2. Among remaining candidates, the highest **Fit Metrics** subtotal wins ties
3. If two candidates are within 5 points, prefer the one with higher **Noise/gap tolerance** (our biggest pain point)
4. Final decision should include a proof-of-concept plan for the winner
