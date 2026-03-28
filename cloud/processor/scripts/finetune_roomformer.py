#!/usr/bin/env python3
"""
Fine-tune RoomFormer on custom training data and re-export to TorchScript.

This script runs in the same environment as the Colab export notebook
(needs the RoomFormer repo + PyTorch + stubs for CUDA extensions).

Usage (on Colab or any PyTorch environment):
    python scripts/finetune_roomformer.py \
        --roomformer-dir /content/RoomFormer \
        --checkpoint /content/RoomFormer/checkpoints/roomformer_stru3d.pth \
        --training-data /content/training_data/ \
        --output /content/roomformer_finetuned.pt \
        --epochs 50 \
        --lr 1e-5

Training data format (from generate_training_data.py):
    training_data/
        density/          # 256x256 uint8 PNGs
        annotations.json  # COCO-style polygons

The fine-tuned model is exported as TorchScript (.pt) for deployment.
"""

import argparse
import json
import os
import sys
from pathlib import Path


def finetune(
    roomformer_dir: str,
    checkpoint_path: str,
    training_data_dir: str,
    output_path: str,
    epochs: int = 50,
    lr: float = 1e-5,
    batch_size: int = 4,
    val_split: float = 0.1,
):
    """Fine-tune RoomFormer on custom density maps + polygon annotations.

    This function must run in an environment with:
      - The RoomFormer repo on sys.path
      - The CUDA extension stubs applied (see Colab notebook)
      - PyTorch installed

    Args:
        roomformer_dir: Path to cloned RoomFormer repo.
        checkpoint_path: Path to pretrained checkpoint (.pth).
        training_data_dir: Directory with density/ PNGs + annotations.json.
        output_path: Where to save the fine-tuned TorchScript model.
        epochs: Number of fine-tuning epochs.
        lr: Learning rate (use small value like 1e-5 to avoid catastrophic forgetting).
        batch_size: Training batch size.
        val_split: Fraction of data to hold out for validation.
    """
    import torch
    import torch.nn as nn
    import torch.optim as optim
    from torch.utils.data import Dataset, DataLoader, random_split
    import numpy as np

    sys.path.insert(0, roomformer_dir)

    # --- Stub CUDA extensions (same as Colab notebook) ---
    import types
    for mod_name in ['MultiScaleDeformableAttention', 'native_rasterizer']:
        if mod_name not in sys.modules:
            stub = types.ModuleType(mod_name)
            def _raise(*a, **k): raise RuntimeError(f"{mod_name} stub")
            for attr in ['ms_deform_attn_forward', 'ms_deform_attn_backward',
                         'forward', 'backward', 'rasterize_forward', 'rasterize_backward']:
                setattr(stub, attr, _raise)
            sys.modules[mod_name] = stub

    # Patch deformable attention
    from models.ops.functions.ms_deform_attn_func import ms_deform_attn_core_pytorch
    from models.ops.modules import ms_deform_attn as attn_module
    import torch.nn.functional as F

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
            raise ValueError(f'bad ref_points dim {reference_points.shape[-1]}')
        output = ms_deform_attn_core_pytorch(
            value, input_spatial_shapes, sampling_locations, attention_weights)
        output = self.output_proj(output)
        return output

    attn_module.MSDeformAttn.forward = _patched_forward
    print("[PATCH] Deformable attention patched to pure-PyTorch")

    # --- Load training data ---
    print(f"\nLoading training data from {training_data_dir}...")
    dataset = DensityMapDataset(training_data_dir)
    print(f"  {len(dataset)} samples loaded")

    # Split into train/val
    val_size = max(1, int(len(dataset) * val_split))
    train_size = len(dataset) - val_size
    train_dataset, val_dataset = random_split(dataset, [train_size, val_size])
    print(f"  Train: {train_size}, Val: {val_size}")

    train_loader = DataLoader(train_dataset, batch_size=batch_size, shuffle=True)
    val_loader = DataLoader(val_dataset, batch_size=batch_size, shuffle=False)

    # --- Build model + load checkpoint ---
    print("\nBuilding model...")
    from models import build_model
    from main import get_args_parser

    parser_rf = get_args_parser()
    args = parser_rf.parse_args([
        '--num_queries', '800', '--num_polys', '20',
        '--num_feature_levels', '4', '--backbone', 'resnet50',
        '--with_poly_refine', '--masked_attn', '--semantic_classes', '-1',
    ])
    args.aux_loss = False

    model = build_model(args, train=True)

    ckpt = torch.load(checkpoint_path, map_location='cpu', weights_only=False)
    model.load_state_dict(ckpt['model'], strict=False)
    print("  Checkpoint loaded")

    # Freeze backbone for first 1/3 of training (prevents catastrophic forgetting)
    freeze_until_epoch = max(1, epochs // 3)

    # --- Optimizer ---
    # Small LR to avoid destroying pretrained features
    optimizer = optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-4)
    scheduler = optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs)

    # --- Simple training loop ---
    # Uses L1 loss on corner coordinates (simplified from full RoomFormer loss)
    print(f"\nFine-tuning for {epochs} epochs (lr={lr})...")
    print(f"  Backbone frozen for first {freeze_until_epoch} epochs\n")

    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    model.to(device)

    from util.misc import NestedTensor

    for epoch in range(epochs):
        # Freeze/unfreeze backbone
        if epoch < freeze_until_epoch:
            for name, param in model.named_parameters():
                if 'backbone' in name:
                    param.requires_grad = False
        elif epoch == freeze_until_epoch:
            for param in model.parameters():
                param.requires_grad = True
            print(f"  Epoch {epoch}: backbone unfrozen")

        model.train()
        total_loss = 0.0

        for batch in train_loader:
            density_maps = batch['density_map'].to(device)  # [B, 1, 256, 256]
            gt_corners = batch['corners']  # list of Kx2 tensors

            # Create NestedTensor
            masks = torch.zeros(density_maps.shape[0], 256, 256,
                                dtype=torch.bool, device=device)
            samples = NestedTensor(density_maps, masks)

            outputs = model(samples)
            pred_coords = outputs['pred_coords']  # [B, 20, 40, 2]

            # Simple L1 loss: compare first room's first K corners to GT
            loss = _compute_corner_loss(pred_coords, gt_corners, device)

            optimizer.zero_grad()
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=0.1)
            optimizer.step()

            total_loss += loss.item()

        scheduler.step()
        avg_loss = total_loss / max(len(train_loader), 1)

        # Validation
        if (epoch + 1) % 5 == 0 or epoch == epochs - 1:
            model.eval()
            val_loss = 0.0
            with torch.no_grad():
                for batch in val_loader:
                    density_maps = batch['density_map'].to(device)
                    gt_corners = batch['corners']
                    masks = torch.zeros(density_maps.shape[0], 256, 256,
                                        dtype=torch.bool, device=device)
                    samples = NestedTensor(density_maps, masks)
                    outputs = model(samples)
                    loss = _compute_corner_loss(outputs['pred_coords'], gt_corners, device)
                    val_loss += loss.item()
            avg_val = val_loss / max(len(val_loader), 1)
            print(f"  Epoch {epoch+1}/{epochs}: train_loss={avg_loss:.4f}, val_loss={avg_val:.4f}")
        else:
            print(f"  Epoch {epoch+1}/{epochs}: train_loss={avg_loss:.4f}")

    # --- Export to TorchScript ---
    print(f"\nExporting to TorchScript: {output_path}")
    model.eval()
    model.cpu()

    class ExportWrapper(nn.Module):
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

    wrapper = ExportWrapper(model)
    wrapper.eval()

    dummy = torch.randn(1, 1, 256, 256)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy,))
    traced.save(output_path)

    size_mb = os.path.getsize(output_path) / (1024 * 1024)
    print(f"  Saved: {output_path} ({size_mb:.1f} MB)")
    print("\nFine-tuning complete!")


def _compute_corner_loss(pred_coords, gt_corners_list, device):
    """Simple L1 loss between predicted and ground truth corner positions.

    For each sample in the batch, matches the first room query's corners
    to the ground truth corners via Hungarian matching, then computes L1 loss.
    """
    import torch
    from scipy.optimize import linear_sum_assignment

    total_loss = torch.tensor(0.0, device=device, requires_grad=True)
    batch_size = pred_coords.shape[0]

    for b in range(batch_size):
        gt = gt_corners_list[b].to(device).float()  # [K, 2]
        if len(gt) == 0:
            continue

        # Use room 0's predictions (our scans are single-room)
        pred = pred_coords[b, 0, :len(gt), :]  # [K, 2]

        # Normalize GT to [0, 1] to match pred scale
        gt_norm = gt / 255.0

        # L1 loss
        loss = torch.nn.functional.l1_loss(pred, gt_norm)
        total_loss = total_loss + loss

    return total_loss / max(batch_size, 1)


class DensityMapDataset:
    """Dataset of density maps + polygon annotations for fine-tuning."""

    def __init__(self, data_dir: str):
        import torch

        self.data_dir = Path(data_dir)
        with open(self.data_dir / "annotations.json") as f:
            coco = json.load(f)

        self.images = {img["id"]: img for img in coco["images"]}
        self.annotations = {ann["image_id"]: ann for ann in coco["annotations"]}
        self.sample_ids = sorted(self.images.keys())

    def __len__(self):
        return len(self.sample_ids)

    def __getitem__(self, idx):
        import torch

        sample_id = self.sample_ids[idx]
        img_info = self.images[sample_id]
        ann = self.annotations[sample_id]

        # Load density map
        png_path = self.data_dir / "density" / img_info["file_name"]
        if png_path.exists():
            from PIL import Image
            density = np.array(Image.open(png_path)).astype(np.float32) / 255.0
        else:
            npy_path = png_path.with_suffix('.npy')
            density = np.load(npy_path).astype(np.float32) / 255.0

        # Parse polygon corners from COCO segmentation format
        seg = ann["segmentation"][0]  # flat list [x1, y1, x2, y2, ...]
        corners = np.array(seg, dtype=np.float32).reshape(-1, 2)

        return {
            "density_map": torch.from_numpy(density).unsqueeze(0),  # [1, 256, 256]
            "corners": torch.from_numpy(corners),  # [K, 2] in pixel coords
        }


def main():
    parser = argparse.ArgumentParser(description="Fine-tune RoomFormer")
    parser.add_argument("--roomformer-dir", required=True,
                        help="Path to cloned RoomFormer repo")
    parser.add_argument("--checkpoint", required=True,
                        help="Path to pretrained checkpoint (.pth)")
    parser.add_argument("--training-data", required=True,
                        help="Directory with density/ + annotations.json")
    parser.add_argument("--output", default="roomformer_finetuned.pt",
                        help="Output TorchScript model path")
    parser.add_argument("--epochs", type=int, default=50)
    parser.add_argument("--lr", type=float, default=1e-5)
    parser.add_argument("--batch-size", type=int, default=4)
    args = parser.parse_args()

    finetune(
        roomformer_dir=args.roomformer_dir,
        checkpoint_path=args.checkpoint,
        training_data_dir=args.training_data,
        output_path=args.output,
        epochs=args.epochs,
        lr=args.lr,
        batch_size=args.batch_size,
    )


if __name__ == "__main__":
    main()
