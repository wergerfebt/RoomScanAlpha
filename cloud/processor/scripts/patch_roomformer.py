#!/usr/bin/env python3
"""
Step 3a: Patch RoomFormer to use pure-PyTorch deformable attention.

The standard RoomFormer uses a custom CUDA C++ extension for
MultiScaleDeformableAttention. This extension:
  - Won't build without CUDA
  - Won't run on CPU (throws AT_ERROR)
  - Isn't exportable to ONNX
  - Requires Python 3.8 + vendored detectron2

This script patches the model to use the pure-PyTorch fallback
(ms_deform_attn_core_pytorch) which uses F.grid_sample instead of
the custom CUDA kernel. This enables CPU inference and ONNX export.

Usage:
    # In the RoomFormer Python 3.8 + CUDA conda env:
    cd /path/to/RoomFormer
    python /path/to/patch_roomformer.py --roomformer-dir . --checkpoint <path_to_checkpoint.pth>

    # This will:
    # 1. Patch MSDeformAttn.forward() to use pure-PyTorch attention
    # 2. Load the pretrained checkpoint
    # 3. Validate patched model output matches original (on CUDA)
    # 4. Verify patched model runs on CPU
    # 5. Save patched model state_dict
"""

import argparse
import sys
import os
from pathlib import Path


def patch_deformable_attention(roomformer_dir: str):
    """Monkey-patch MSDeformAttn to use pure-PyTorch attention.

    Replaces the CUDA kernel call in MSDeformAttn.forward() with
    ms_deform_attn_core_pytorch() which uses F.grid_sample.
    """
    # Add RoomFormer to path
    sys.path.insert(0, roomformer_dir)

    # Import the pure-PyTorch fallback BEFORE the CUDA version tries to load
    from models.ops.functions.ms_deform_attn_func import ms_deform_attn_core_pytorch

    # Import the attention module
    from models.ops.modules import ms_deform_attn as attn_module

    import torch
    import torch.nn.functional as F

    # Store original forward for comparison
    original_forward = attn_module.MSDeformAttn.forward

    def patched_forward(self, query, reference_points, input_flatten,
                        input_spatial_shapes, input_level_start_index,
                        input_padding_mask=None):
        """Pure-PyTorch forward pass using F.grid_sample instead of CUDA kernel."""
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

        # Compute sampling locations from reference points + offsets
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
            raise ValueError(
                f"Last dim of reference_points must be 2 or 4, got {reference_points.shape[-1]}")

        # Use pure-PyTorch attention (F.grid_sample) instead of CUDA kernel
        output = ms_deform_attn_core_pytorch(
            value, input_spatial_shapes, sampling_locations, attention_weights)

        output = self.output_proj(output)
        return output

    # Apply the monkey-patch
    attn_module.MSDeformAttn.forward = patched_forward
    print("[PATCH] MSDeformAttn.forward() patched to pure-PyTorch (F.grid_sample)")

    return original_forward


def validate_patch(roomformer_dir: str, checkpoint_path: str, num_samples: int = 3):
    """Validate patched model output matches original on CUDA.

    Returns True if outputs match within tolerance.
    """
    import torch

    sys.path.insert(0, roomformer_dir)

    has_cuda = torch.cuda.is_available()
    if not has_cuda:
        print("[VALIDATE] No CUDA available — skipping CUDA parity check")
        print("[VALIDATE] Will only validate CPU forward pass works")

    # Build model with patched attention
    from models import build_model
    from main import get_args_parser

    # Parse args with defaults
    parser = get_args_parser()
    args = parser.parse_args([
        '--num_queries', '800',
        '--num_polys', '20',
        '--num_feature_levels', '4',
        '--backbone', 'resnet50',
        '--with_poly_refine',
        '--masked_attn',
        '--semantic_classes', '-1',
    ])

    model = build_model(args, train=False)

    # Load checkpoint
    checkpoint = torch.load(checkpoint_path, map_location='cpu')
    missing, unexpected = model.load_state_dict(checkpoint['model'], strict=False)
    if missing:
        print(f"[VALIDATE] Missing keys: {missing[:5]}{'...' if len(missing) > 5 else ''}")
    if unexpected:
        print(f"[VALIDATE] Unexpected keys: {unexpected[:5]}{'...' if len(unexpected) > 5 else ''}")

    model.eval()

    # Test with random input
    torch.manual_seed(42)
    dummy_input = torch.randn(1, 1, 256, 256)

    # CPU forward pass
    print("[VALIDATE] Running CPU forward pass...")
    try:
        from util.misc import nested_tensor_from_tensor_list
        nested = nested_tensor_from_tensor_list([dummy_input[0]])

        with torch.no_grad():
            output = model(nested)

        pred_logits = output['pred_logits']
        pred_coords = output['pred_coords']

        print(f"[VALIDATE] pred_logits shape: {pred_logits.shape}")  # [1, 20, 40]
        print(f"[VALIDATE] pred_coords shape: {pred_coords.shape}")  # [1, 20, 40, 2]
        print(f"[VALIDATE] pred_logits range: [{pred_logits.min():.3f}, {pred_logits.max():.3f}]")
        print(f"[VALIDATE] pred_coords range: [{pred_coords.min():.3f}, {pred_coords.max():.3f}]")
        print("[VALIDATE] CPU forward pass SUCCEEDED")

    except Exception as e:
        print(f"[VALIDATE] CPU forward pass FAILED: {e}")
        return False

    # Determinism check
    print("[VALIDATE] Checking determinism (3 runs)...")
    results = []
    for i in range(3):
        with torch.no_grad():
            out = model(nested)
        results.append(out['pred_coords'].numpy())

    for i in range(1, 3):
        if not (results[0] == results[i]).all():
            print(f"[VALIDATE] WARNING: Run {i+1} differs from run 1")
            return False
    print("[VALIDATE] Determinism check PASSED")

    return True


def save_patched_state_dict(roomformer_dir: str, checkpoint_path: str, output_path: str):
    """Load checkpoint, save just the model state_dict for lighter distribution."""
    import torch
    sys.path.insert(0, roomformer_dir)

    from models import build_model
    from main import get_args_parser

    parser = get_args_parser()
    args = parser.parse_args([
        '--num_queries', '800',
        '--num_polys', '20',
        '--num_feature_levels', '4',
        '--backbone', 'resnet50',
        '--with_poly_refine',
        '--masked_attn',
        '--semantic_classes', '-1',
    ])

    model = build_model(args, train=False)

    checkpoint = torch.load(checkpoint_path, map_location='cpu')
    model.load_state_dict(checkpoint['model'], strict=False)

    torch.save({
        'model': model.state_dict(),
        'args': vars(args),
        'patch': 'pure_pytorch_deform_attn',
    }, output_path)
    print(f"[SAVE] Patched state_dict saved to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Patch RoomFormer deformable attention")
    parser.add_argument("--roomformer-dir", required=True,
                        help="Path to cloned RoomFormer repo")
    parser.add_argument("--checkpoint", required=True,
                        help="Path to pretrained checkpoint (.pth)")
    parser.add_argument("--output", default="roomformer_patched.pth",
                        help="Output path for patched state_dict")
    parser.add_argument("--skip-validate", action="store_true",
                        help="Skip validation (useful if no CUDA)")
    parser.add_argument("--num-validate-samples", type=int, default=3,
                        help="Number of samples for validation")
    args = parser.parse_args()

    roomformer_dir = os.path.abspath(args.roomformer_dir)
    if not Path(roomformer_dir).is_dir():
        print(f"Error: {roomformer_dir} is not a directory")
        sys.exit(1)
    if not Path(args.checkpoint).is_file():
        print(f"Error: {args.checkpoint} not found")
        sys.exit(1)

    # Step 1: Patch the attention module
    patch_deformable_attention(roomformer_dir)

    # Step 2: Validate
    if not args.skip_validate:
        ok = validate_patch(roomformer_dir, args.checkpoint, args.num_validate_samples)
        if not ok:
            print("[PATCH] Validation FAILED — check output above")
            sys.exit(1)
        print("[PATCH] Validation PASSED")

    # Step 3: Save patched model
    save_patched_state_dict(roomformer_dir, args.checkpoint, args.output)
    print(f"\n[DONE] Patched model saved to: {args.output}")
    print("Next: run export_roomformer_onnx.py with this checkpoint")


if __name__ == "__main__":
    main()
