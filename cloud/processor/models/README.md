# RoomFormer Model Export

Model files are gitignored (100-300MB). Follow these steps to export.

## Prerequisites

- A machine with **NVIDIA GPU + CUDA 11.1** (needed to build the CUDA extension for validation)
- **conda** (for isolated Python 3.8 environment)

## Setup

```bash
# 1. Clone RoomFormer
git clone https://github.com/ywyue/RoomFormer.git /tmp/roomformer
cd /tmp/roomformer

# 2. Create isolated Python 3.8 env
conda create -n roomformer python=3.8 -y
conda activate roomformer

# 3. Install PyTorch 1.9 + CUDA 11.1
pip install torch==1.9.0+cu111 torchvision==0.10.0+cu111 \
    -f https://download.pytorch.org/whl/torch_stable.html

# 4. Install RoomFormer dependencies
pip install -r requirements.txt

# 5. Build CUDA extension (for validation only — the patched model won't use it)
cd models/ops && sh make.sh && cd ../..

# 6. Install ONNX tools
pip install onnx onnxruntime
```

## Download Pretrained Weights

```bash
# Structured3D pretrained checkpoint
# Download from: https://polybox.ethz.ch/index.php/s/vlBo66X0NTrcsTC
# Save as: checkpoint_s3d.pth
```

## Step 3a: Patch Deformable Attention

```bash
python /path/to/RoomScanAlpha/cloud/processor/scripts/patch_roomformer.py \
    --roomformer-dir /tmp/roomformer \
    --checkpoint checkpoint_s3d.pth \
    --output roomformer_patched.pth
```

This replaces the CUDA `MultiScaleDeformableAttention` kernel with a pure-PyTorch
implementation using `F.grid_sample`. The patched model runs on CPU.

**Tests (PATCH.1-3)**:
- PATCH.1: Patched model loads without CUDA extension import
- PATCH.2: Output matches original within atol=1e-3
- PATCH.3: Room F1 > 96.0 on Structured3D validation

## Step 3c: Export to ONNX

```bash
python /path/to/RoomScanAlpha/cloud/processor/scripts/export_roomformer_onnx.py \
    --roomformer-dir /tmp/roomformer \
    --checkpoint roomformer_patched.pth \
    --output /path/to/RoomScanAlpha/cloud/processor/models/roomformer_s3d.onnx
```

**Tests (ONNX.1-5)**:
- ONNX.1: Valid ONNX file produced
- ONNX.2: Accepts [1, 1, 256, 256] input, produces pred_logits + pred_coords
- ONNX.3: CPU inference < 5 seconds
- ONNX.4: Deterministic output
- ONNX.5: Matches PyTorch output within atol=1e-3

## If ONNX Export Fails (Step 3d)

The export script automatically falls back to TorchScript. If both fail, use
TorchServe GPU deployment (Path B). See the implementation plan:
`cloud/dnn_comparison/BEV_DNN_IMPLEMENTATION_PLAN.md`

## Validate ONNX Model (any Python env)

```bash
pip install onnxruntime
python /path/to/scripts/export_roomformer_onnx.py \
    --validate-only \
    --onnx /path/to/models/roomformer_s3d.onnx
```

## Model Specs

| Property | Value |
|----------|-------|
| Architecture | RoomFormer (Deformable DETR, two-level queries) |
| Backbone | ResNet-50 (1-channel input) |
| Input | `[1, 1, 256, 256]` float32 density map |
| Output | `pred_logits [1, 20, 40]`, `pred_coords [1, 20, 40, 2]` |
| Parameters | ~40M |
| Expected ONNX size | 150-300 MB |
| CPU inference | 1-3 seconds (onnxruntime) |
