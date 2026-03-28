#!/usr/bin/env python3
"""
Step 3c: Export patched RoomFormer to ONNX.

Requires the pure-PyTorch patched model from patch_roomformer.py.
The ONNX model runs on CPU via onnxruntime — no CUDA needed at inference.

Usage:
    # In the RoomFormer Python 3.8 env:
    cd /path/to/RoomFormer
    python /path/to/export_roomformer_onnx.py \\
        --roomformer-dir . \\
        --checkpoint roomformer_patched.pth \\
        --output roomformer_s3d.onnx

    # Then validate on CPU (can be done in any Python env with onnxruntime):
    python /path/to/export_roomformer_onnx.py --validate-only --onnx roomformer_s3d.onnx

Known challenges:
    - NestedTensor: RoomFormer wraps inputs in NestedTensor (tensor + mask).
      For ONNX export with fixed-size input (1x1x256x256), we bypass NestedTensor
      and pass the tensor + a zeros mask directly.
    - Dynamic shapes in decoder: The decoder uses variable-length queries.
      We fix batch_size=1 for export.
    - aux_outputs: Intermediate predictions are disabled for export (aux_loss=False).
"""

import argparse
import os
import sys
import time
from pathlib import Path


def export_to_onnx(roomformer_dir: str, checkpoint_path: str, output_path: str,
                   opset: int = 16, validate: bool = True):
    """Export patched RoomFormer to ONNX format."""
    import torch
    import torch.nn as nn

    sys.path.insert(0, roomformer_dir)

    # Patch attention BEFORE importing model
    from patch_roomformer_inline import patch_deformable_attention
    patch_deformable_attention(roomformer_dir)

    from models import build_model
    from main import get_args_parser

    # Build model WITHOUT aux_loss (simplifies ONNX graph)
    parser = get_args_parser()
    args = parser.parse_args([
        '--num_queries', '800',
        '--num_polys', '20',
        '--num_feature_levels', '4',
        '--backbone', 'resnet50',
        '--with_poly_refine',
        '--masked_attn',
        '--semantic_classes', '-1',
        # Disable aux_loss for cleaner ONNX graph
    ])
    args.aux_loss = False

    model = build_model(args, train=False)

    # Load checkpoint
    checkpoint = torch.load(checkpoint_path, map_location='cpu')
    state_dict = checkpoint.get('model', checkpoint)
    missing, unexpected = model.load_state_dict(state_dict, strict=False)
    print(f"[LOAD] Missing keys: {len(missing)}, Unexpected keys: {len(unexpected)}")

    model.eval()
    model.cpu()

    # Create a wrapper that bypasses NestedTensor
    class RoomFormerONNX(nn.Module):
        """Wrapper for ONNX export: takes raw tensor, creates mask internally."""

        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, density_map: torch.Tensor):
            """
            Args:
                density_map: [1, 1, 256, 256] float32 density map

            Returns:
                pred_logits: [1, 20, 40] corner validity logits
                pred_coords: [1, 20, 40, 2] normalized corner coordinates
            """
            # Create a NestedTensor-compatible input
            # The mask is all False (no padding) for a fixed-size input
            from util.misc import NestedTensor
            mask = torch.zeros(density_map.shape[0], density_map.shape[2],
                               density_map.shape[3], dtype=torch.bool,
                               device=density_map.device)
            samples = NestedTensor(density_map, mask)

            outputs = self.model(samples)
            return outputs['pred_logits'], outputs['pred_coords']

    wrapper = RoomFormerONNX(model)
    wrapper.eval()

    # Dummy input
    dummy = torch.randn(1, 1, 256, 256)

    # Test forward pass first
    print("[EXPORT] Testing forward pass...")
    with torch.no_grad():
        logits, coords = wrapper(dummy)
    print(f"[EXPORT] pred_logits: {logits.shape}, pred_coords: {coords.shape}")

    # Export
    print(f"[EXPORT] Exporting to ONNX (opset {opset})...")
    try:
        torch.onnx.export(
            wrapper,
            (dummy,),
            output_path,
            opset_version=opset,
            input_names=["density_map"],
            output_names=["pred_logits", "pred_coords"],
            dynamic_axes=None,  # Fixed batch size = 1
            do_constant_folding=True,
            verbose=False,
        )
        print(f"[EXPORT] ONNX model saved to: {output_path}")
        file_size_mb = os.path.getsize(output_path) / (1024 * 1024)
        print(f"[EXPORT] File size: {file_size_mb:.1f} MB")
    except Exception as e:
        print(f"[EXPORT] ONNX export FAILED: {e}")
        print("\n[FALLBACK] ONNX export failed. Options:")
        print("  1. Try torch.jit.trace instead (see --torchscript flag)")
        print("  2. Use TorchServe GPU deployment (Path B in the plan)")
        print("  3. Debug the specific op that failed")
        raise

    # Validate ONNX model
    if validate:
        validate_onnx(output_path, dummy, logits, coords)


def validate_onnx(onnx_path: str, dummy_input=None, expected_logits=None,
                  expected_coords=None):
    """Validate the exported ONNX model."""
    import numpy as np

    # Check model validity
    try:
        import onnx
        model = onnx.load(onnx_path)
        onnx.checker.check_model(model)
        print("[VALIDATE] ONNX model structure is valid")
    except ImportError:
        print("[VALIDATE] onnx package not installed, skipping structural check")
    except Exception as e:
        print(f"[VALIDATE] ONNX structural check FAILED: {e}")
        return False

    # Run inference with onnxruntime
    try:
        import onnxruntime as ort
    except ImportError:
        print("[VALIDATE] onnxruntime not installed, skipping inference check")
        return True

    print("[VALIDATE] Loading ONNX model in onnxruntime...")
    session = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])

    # Check input/output names and shapes
    inputs = session.get_inputs()
    outputs = session.get_outputs()
    print(f"[VALIDATE] Inputs: {[(i.name, i.shape, i.type) for i in inputs]}")
    print(f"[VALIDATE] Outputs: {[(o.name, o.shape, o.type) for o in outputs]}")

    # Run inference
    if dummy_input is None:
        import torch
        dummy_input = torch.randn(1, 1, 256, 256)

    input_np = dummy_input.numpy() if hasattr(dummy_input, 'numpy') else dummy_input
    input_name = inputs[0].name

    # Timing
    print("[VALIDATE] Running inference (3 times for timing)...")
    times = []
    for i in range(3):
        t0 = time.time()
        result = session.run(None, {input_name: input_np})
        times.append(time.time() - t0)

    logits_onnx, coords_onnx = result[0], result[1]
    print(f"[VALIDATE] pred_logits: {logits_onnx.shape}, pred_coords: {coords_onnx.shape}")
    print(f"[VALIDATE] Inference time: {np.mean(times):.3f}s ± {np.std(times):.3f}s")

    # Check determinism
    result2 = session.run(None, {input_name: input_np})
    if np.allclose(result[0], result2[0]) and np.allclose(result[1], result2[1]):
        print("[VALIDATE] Determinism check PASSED")
    else:
        print("[VALIDATE] WARNING: Non-deterministic output")

    # Check numerical parity with PyTorch if available
    if expected_logits is not None and expected_coords is not None:
        logits_pt = expected_logits.numpy() if hasattr(expected_logits, 'numpy') else expected_logits
        coords_pt = expected_coords.numpy() if hasattr(expected_coords, 'numpy') else expected_coords

        logits_close = np.allclose(logits_onnx, logits_pt, atol=1e-3)
        coords_close = np.allclose(coords_onnx, coords_pt, atol=1e-3)

        if logits_close and coords_close:
            print("[VALIDATE] PyTorch ↔ ONNX parity check PASSED (atol=1e-3)")
        else:
            logits_diff = np.abs(logits_onnx - logits_pt).max()
            coords_diff = np.abs(coords_onnx - coords_pt).max()
            print(f"[VALIDATE] PyTorch ↔ ONNX parity: logits max_diff={logits_diff:.6f}, "
                  f"coords max_diff={coords_diff:.6f}")
            if logits_diff < 0.01 and coords_diff < 0.01:
                print("[VALIDATE] Parity within acceptable tolerance (0.01)")
            else:
                print("[VALIDATE] WARNING: Large numerical difference")

    # Latency check
    if np.mean(times) < 5.0:
        print(f"[VALIDATE] Latency check PASSED ({np.mean(times):.3f}s < 5.0s)")
    else:
        print(f"[VALIDATE] WARNING: Latency {np.mean(times):.3f}s exceeds 5s target")

    return True


def export_torchscript_fallback(roomformer_dir: str, checkpoint_path: str, output_path: str):
    """Fallback: export as TorchScript if ONNX fails (Step 3d)."""
    import torch
    sys.path.insert(0, roomformer_dir)

    # Same setup as ONNX export...
    from patch_roomformer_inline import patch_deformable_attention
    patch_deformable_attention(roomformer_dir)

    from models import build_model
    from main import get_args_parser

    parser = get_args_parser()
    args = parser.parse_args([
        '--num_queries', '800', '--num_polys', '20',
        '--num_feature_levels', '4', '--backbone', 'resnet50',
        '--with_poly_refine', '--masked_attn', '--semantic_classes', '-1',
    ])
    args.aux_loss = False

    model = build_model(args, train=False)
    checkpoint = torch.load(checkpoint_path, map_location='cpu')
    model.load_state_dict(checkpoint.get('model', checkpoint), strict=False)
    model.eval()
    model.cpu()

    print("[TORCHSCRIPT] Attempting torch.jit.trace...")
    dummy = torch.randn(1, 1, 256, 256)
    mask = torch.zeros(1, 256, 256, dtype=torch.bool)

    try:
        from util.misc import NestedTensor
        nested = NestedTensor(dummy, mask)
        traced = torch.jit.trace(model, (nested,))
        traced.save(output_path)
        print(f"[TORCHSCRIPT] Saved to: {output_path}")
    except Exception as e:
        print(f"[TORCHSCRIPT] trace FAILED: {e}")
        print("[TORCHSCRIPT] Falling back to torch.jit.script...")
        try:
            scripted = torch.jit.script(model)
            scripted.save(output_path)
            print(f"[TORCHSCRIPT] Saved to: {output_path}")
        except Exception as e2:
            print(f"[TORCHSCRIPT] script also FAILED: {e2}")
            print("\n[CONCLUSION] Neither ONNX nor TorchScript export succeeded.")
            print("Proceeding with Path B: TorchServe GPU deployment.")
            sys.exit(2)


def main():
    parser = argparse.ArgumentParser(description="Export RoomFormer to ONNX")
    parser.add_argument("--roomformer-dir",
                        help="Path to cloned RoomFormer repo")
    parser.add_argument("--checkpoint",
                        help="Path to patched checkpoint (from patch_roomformer.py)")
    parser.add_argument("--output", default="roomformer_s3d.onnx",
                        help="Output ONNX path")
    parser.add_argument("--opset", type=int, default=16,
                        help="ONNX opset version (default: 16)")
    parser.add_argument("--validate-only", action="store_true",
                        help="Only validate an existing ONNX file")
    parser.add_argument("--onnx",
                        help="ONNX file to validate (with --validate-only)")
    parser.add_argument("--torchscript", action="store_true",
                        help="Export as TorchScript instead of ONNX (fallback)")
    args = parser.parse_args()

    if args.validate_only:
        if not args.onnx:
            print("Error: --onnx required with --validate-only")
            sys.exit(1)
        validate_onnx(args.onnx)
        return

    if not args.roomformer_dir or not args.checkpoint:
        print("Error: --roomformer-dir and --checkpoint required for export")
        sys.exit(1)

    # Create inline patch module so the export script can import it
    patch_inline_path = Path(args.roomformer_dir) / "patch_roomformer_inline.py"
    patch_source = Path(__file__).parent / "patch_roomformer.py"

    # Copy the patch function into the RoomFormer dir as an importable module
    import shutil
    shutil.copy2(str(patch_source), str(patch_inline_path))
    print(f"[SETUP] Copied patch module to {patch_inline_path}")

    try:
        if args.torchscript:
            output = args.output.replace('.onnx', '.pt')
            export_torchscript_fallback(args.roomformer_dir, args.checkpoint, output)
        else:
            try:
                export_to_onnx(args.roomformer_dir, args.checkpoint, args.output,
                               opset=args.opset)
            except Exception:
                print("\n[FALLBACK] Attempting TorchScript export...")
                ts_output = args.output.replace('.onnx', '.pt')
                export_torchscript_fallback(args.roomformer_dir, args.checkpoint, ts_output)
    finally:
        # Clean up inline patch
        if patch_inline_path.exists():
            patch_inline_path.unlink()


if __name__ == "__main__":
    main()
