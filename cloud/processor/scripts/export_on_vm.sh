#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# RoomFormer ONNX Export — runs on the GCE VM
#
# This script is piped into the VM via SSH. It:
#   1. Installs conda + Python 3.8 + PyTorch 1.9 + CUDA 11.1
#   2. Clones RoomFormer + builds CUDA extension
#   3. Downloads pretrained checkpoint
#   4. Patches deformable attention to pure-PyTorch
#   5. Validates patch (PATCH.1-2)
#   6. Exports to ONNX (ONNX.1-5)
#   7. Copies the .onnx file to /tmp for download
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

echo "=========================================="
echo "RoomFormer ONNX Export — GCE VM"
echo "=========================================="

# ── 1. Install Miniconda ──
if [ ! -d "$HOME/miniconda3" ]; then
    echo "[1/7] Installing Miniconda..."
    wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh
    bash /tmp/miniconda.sh -b -p $HOME/miniconda3
    rm /tmp/miniconda.sh
fi
export PATH="$HOME/miniconda3/bin:$PATH"
eval "$(conda shell.bash hook)"

# ── 2. Create Python 3.8 env with PyTorch 1.9 + CUDA 11.1 ──
if ! conda env list | grep -q roomformer; then
    echo "[2/7] Creating conda env (Python 3.8 + PyTorch 1.9 + CUDA 11.1)..."
    conda create -n roomformer python=3.8 -y -q
fi
conda activate roomformer

echo "[2/7] Installing PyTorch 1.9..."
pip install -q torch==1.9.0+cu111 torchvision==0.10.0+cu111 \
    -f https://download.pytorch.org/whl/torch_stable.html

pip install -q shapely scipy opencv-python-headless pillow onnx onnxruntime numpy

python -c "import torch; print(f'PyTorch {torch.__version__}, CUDA {torch.cuda.is_available()}')"

# ── 3. Clone RoomFormer + build CUDA extension ──
cd /tmp
if [ ! -d "RoomFormer" ]; then
    echo "[3/7] Cloning RoomFormer..."
    git clone --depth 1 https://github.com/ywyue/RoomFormer.git
fi
cd RoomFormer

# Install detectron2 if vendored
if [ -d "detectron2" ] && [ -f "detectron2/setup.py" ]; then
    echo "[3/7] Installing vendored detectron2..."
    pip install -q -e detectron2/
elif [ -d "detectron2" ]; then
    echo "[3/7] detectron2 dir exists but no setup.py — installing from source..."
    pip install -q 'git+https://github.com/facebookresearch/detectron2.git@v0.6'
fi

echo "[3/7] Building CUDA extension..."
cd models/ops
python setup.py build_ext --inplace 2>&1 | tail -3
cd ../..

# Verify CUDA extension
python -c "
import sys; sys.path.insert(0, '.')
from models.ops.functions import MSDeformAttnFunction
print('[3/7] CUDA extension loaded OK')
"

# ── 4. Download checkpoint ──
if [ ! -f "checkpoint_s3d.pth" ]; then
    echo "[4/7] Downloading Structured3D checkpoint..."
    curl -L -o checkpoint_s3d.pth \
        "https://polybox.ethz.ch/index.php/s/vlBo66X0NTrcsTC/download"
fi

# Verify checkpoint is a real file (not HTML)
SIZE=$(stat -c%s checkpoint_s3d.pth)
if [ "$SIZE" -lt 1000000 ]; then
    echo "ERROR: Checkpoint too small (${SIZE} bytes) — download failed"
    echo "First 200 bytes:"
    head -c 200 checkpoint_s3d.pth
    exit 1
fi
echo "[4/7] Checkpoint: $(ls -lh checkpoint_s3d.pth | awk '{print $5}')"

# ── 5. Run patch + validation + ONNX export ──
echo "[5/7] Patching, validating, and exporting..."

python3 -c "
import sys, os
sys.path.insert(0, '/tmp/RoomFormer')
os.chdir('/tmp/RoomFormer')

import torch
import torch.nn.functional as F
import numpy as np

# ── Import pure-PyTorch fallback ──
from models.ops.functions.ms_deform_attn_func import ms_deform_attn_core_pytorch
from models.ops.modules import ms_deform_attn as attn_module

# ── Save original forward for PATCH.2 comparison ──
_original_forward = attn_module.MSDeformAttn.forward

# ── Define patched forward ──
def _patched_forward(self, query, reference_points, input_flatten,
                     input_spatial_shapes, input_level_start_index,
                     input_padding_mask=None):
    N, Len_q, _ = query.shape
    N, Len_in, _ = input_flatten.shape
    value = self.value_proj(input_flatten)
    if input_padding_mask is not None:
        value = value.masked_fill(input_padding_mask[..., None], float(0))
    value = value.view(N, Len_in, self.n_heads, self.d_model // self.n_heads)
    sampling_offsets = self.sampling_offsets(query).view(
        N, Len_q, self.n_heads, self.n_levels, self.n_points, 2)
    attention_weights = self.attention_weights(query).view(
        N, Len_q, self.n_heads, self.n_levels * self.n_points)
    attention_weights = F.softmax(attention_weights, -1).view(
        N, Len_q, self.n_heads, self.n_levels, self.n_points)
    if reference_points.shape[-1] == 2:
        offset_normalizer = torch.stack(
            [input_spatial_shapes[..., 1], input_spatial_shapes[..., 0]], -1)
        sampling_locations = (
            reference_points[:, :, None, :, None, :]
            + sampling_offsets / offset_normalizer[None, None, None, :, None, :]
        )
    elif reference_points.shape[-1] == 4:
        sampling_locations = (
            reference_points[:, :, None, :, None, :2]
            + sampling_offsets / self.n_points
            * reference_points[:, :, None, :, None, 2:]
            * 0.5
        )
    else:
        raise ValueError(f'ref_points last dim must be 2 or 4, got {reference_points.shape[-1]}')
    output = ms_deform_attn_core_pytorch(
        value, input_spatial_shapes, sampling_locations, attention_weights)
    output = self.output_proj(output)
    return output

# ── Build model + load checkpoint ──
from models import build_model
from main import get_args_parser
from util.misc import NestedTensor, nested_tensor_from_tensor_list

parser = get_args_parser()
args = parser.parse_args([
    '--num_queries', '800', '--num_polys', '20',
    '--num_feature_levels', '4', '--backbone', 'resnet50',
    '--with_poly_refine', '--masked_attn', '--semantic_classes', '-1',
])

ckpt = torch.load('checkpoint_s3d.pth', map_location='cpu')

# ── PATCH.2: Run ORIGINAL model on CUDA, collect reference outputs ──
print('[PATCH.2] Running original (CUDA) model...')
model_orig = build_model(args, train=False)
model_orig.load_state_dict(ckpt['model'], strict=False)
model_orig.eval().cuda()

torch.manual_seed(42)
test_inputs = [torch.randn(1, 256, 256) for _ in range(3)]
orig_outputs = []
for inp in test_inputs:
    nested = nested_tensor_from_tensor_list([inp.cuda()])
    with torch.no_grad():
        out = model_orig(nested)
    orig_outputs.append({
        'logits': out['pred_logits'].cpu().numpy(),
        'coords': out['pred_coords'].cpu().numpy(),
    })
del model_orig
torch.cuda.empty_cache()

# ── Apply patch ──
attn_module.MSDeformAttn.forward = _patched_forward
print('[PATCH] Applied pure-PyTorch attention')

# ── PATCH.2: Run PATCHED model on CUDA, compare ──
model_patched = build_model(args, train=False)
model_patched.load_state_dict(ckpt['model'], strict=False)
model_patched.eval().cuda()

max_ld, max_cd = 0, 0
for i, inp in enumerate(test_inputs):
    nested = nested_tensor_from_tensor_list([inp.cuda()])
    with torch.no_grad():
        out = model_patched(nested)
    ld = np.abs(out['pred_logits'].cpu().numpy() - orig_outputs[i]['logits']).max()
    cd = np.abs(out['pred_coords'].cpu().numpy() - orig_outputs[i]['coords']).max()
    max_ld, max_cd = max(max_ld, ld), max(max_cd, cd)
    print(f'  Sample {i+1}: logits diff={ld:.6f}, coords diff={cd:.6f}')

if max_ld < 1e-3 and max_cd < 1e-3:
    print(f'[PATCH.2] PASSED (atol=1e-3)')
elif max_ld < 0.01 and max_cd < 0.01:
    print(f'[PATCH.2] ACCEPTABLE (atol=0.01)')
else:
    print(f'[PATCH.2] WARNING — large diff: logits={max_ld:.6f}, coords={max_cd:.6f}')

del model_patched
torch.cuda.empty_cache()

# ── PATCH.1: Verify CPU forward pass ──
print('[PATCH.1] Testing CPU forward pass...')
model_cpu = build_model(args, train=False)
model_cpu.load_state_dict(ckpt['model'], strict=False)
model_cpu.eval().cpu()

dummy = torch.randn(1, 1, 256, 256)
mask = torch.zeros(1, 256, 256, dtype=torch.bool)
with torch.no_grad():
    cpu_out = model_cpu(NestedTensor(dummy, mask))
print(f'  pred_logits: {cpu_out[\"pred_logits\"].shape}')
print(f'  pred_coords: {cpu_out[\"pred_coords\"].shape}')
print('[PATCH.1] PASSED')
del model_cpu

# ── ONNX Export ──
print()
print('[ONNX] Exporting...')
import torch.nn as nn
args.aux_loss = False
model_export = build_model(args, train=False)
model_export.load_state_dict(ckpt['model'], strict=False)
model_export.eval().cpu()

class RoomFormerONNX(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model
    def forward(self, density_map):
        mask = torch.zeros(density_map.shape[0], density_map.shape[2],
                           density_map.shape[3], dtype=torch.bool,
                           device=density_map.device)
        samples = NestedTensor(density_map, mask)
        outputs = self.model(samples)
        return outputs['pred_logits'], outputs['pred_coords']

wrapper = RoomFormerONNX(model_export)
wrapper.eval()

dummy = torch.randn(1, 1, 256, 256)
with torch.no_grad():
    pt_logits, pt_coords = wrapper(dummy)
print(f'  PyTorch: logits {pt_logits.shape}, coords {pt_coords.shape}')

ONNX_PATH = '/tmp/roomformer_s3d.onnx'
try:
    torch.onnx.export(
        wrapper, (dummy,), ONNX_PATH,
        opset_version=13,
        input_names=['density_map'],
        output_names=['pred_logits', 'pred_coords'],
        dynamic_axes=None,
        do_constant_folding=True,
        verbose=False,
    )
    size_mb = os.path.getsize(ONNX_PATH) / (1024*1024)
    print(f'[ONNX.1] PASSED — {size_mb:.1f} MB')
except Exception as e:
    print(f'[ONNX.1] FAILED — {e}')
    print('Trying TorchScript...')
    TS_PATH = '/tmp/roomformer_s3d.pt'
    try:
        traced = torch.jit.trace(wrapper, (dummy,))
        traced.save(TS_PATH)
        print(f'TorchScript saved: {TS_PATH}')
    except Exception as e2:
        print(f'TorchScript also failed: {e2}')
        SD_PATH = '/tmp/roomformer_patched.pth'
        torch.save({'model': model_export.state_dict(), 'args': vars(args)}, SD_PATH)
        print(f'Saved state_dict: {SD_PATH}')
    sys.exit(0)

# ── ONNX Validation ──
import onnx
import onnxruntime as ort
import time

onnx_model = onnx.load(ONNX_PATH)
onnx.checker.check_model(onnx_model)
print('[ONNX.1] Structural check PASSED')

session = ort.InferenceSession(ONNX_PATH, providers=['CPUExecutionProvider'])
for inp in session.get_inputs():
    print(f'[ONNX.2] Input:  {inp.name} {inp.shape} {inp.type}')
for out in session.get_outputs():
    print(f'[ONNX.2] Output: {out.name} {out.shape} {out.type}')

result = session.run(None, {'density_map': dummy.numpy()})
onnx_logits, onnx_coords = result[0], result[1]
print(f'[ONNX.2] PASSED — logits {onnx_logits.shape}, coords {onnx_coords.shape}')

times = []
for _ in range(5):
    t0 = time.time()
    session.run(None, {'density_map': dummy.numpy()})
    times.append(time.time() - t0)
avg = np.mean(times)
print(f'[ONNX.3] Latency: {avg:.3f}s — {\"PASSED\" if avg < 5.0 else \"FAILED\"}')

r1 = session.run(None, {'density_map': dummy.numpy()})
r2 = session.run(None, {'density_map': dummy.numpy()})
det = np.allclose(r1[0], r2[0]) and np.allclose(r1[1], r2[1])
print(f'[ONNX.4] Determinism: {\"PASSED\" if det else \"FAILED\"}')

ld = np.abs(onnx_logits - pt_logits.numpy()).max()
cd = np.abs(onnx_coords - pt_coords.numpy()).max()
print(f'[ONNX.5] Parity: logits diff={ld:.6f}, coords diff={cd:.6f}')
if ld < 1e-3 and cd < 1e-3:
    print('[ONNX.5] PASSED')
elif ld < 0.01 and cd < 0.01:
    print('[ONNX.5] ACCEPTABLE')
else:
    print('[ONNX.5] WARNING')

print()
print('='*50)
print('EXPORT COMPLETE')
print('='*50)
"

echo "[6/7] Export done. Checking for output files..."
ls -lh /tmp/roomformer_s3d.* 2>/dev/null || ls -lh /tmp/roomformer_patched.pth 2>/dev/null || echo "No output file!"

echo "[7/7] Done. Files ready for download."
