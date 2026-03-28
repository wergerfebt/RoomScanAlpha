#!/usr/bin/env python3
"""
Generate training data for RoomFormer fine-tuning.

Produces paired (density_map, ground_truth_polygon) samples in COCO-style format
that RoomFormer's training script expects.

Data sources:
  1. Synthetic rooms: auto-generated box rooms with varied dimensions and rotations
  2. Real scans: PLY files with manually annotated ground truth polygons

Usage:
    # Generate synthetic training data only (no real scans needed):
    python scripts/generate_training_data.py --synthetic-only --output training_data/

    # Generate from real scans with annotations:
    python scripts/generate_training_data.py \
        --scan-dir /path/to/annotated_scans/ \
        --output training_data/

    # Both synthetic + real:
    python scripts/generate_training_data.py \
        --scan-dir /path/to/annotated_scans/ \
        --output training_data/ \
        --num-synthetic 500

Annotation format (per scan directory):
    scan_001/
        mesh.ply              # The LiDAR scan (production format with normals+classifications)
        ground_truth.json     # {"corners_xz": [[x1,z1], [x2,z2], ...]} in meters

Output format:
    training_data/
        density/              # 256x256 uint8 PNGs (density maps)
            00000.png
            00001.png
            ...
        annotations.json      # COCO-style polygon annotations
"""

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline.bev_projection import project_to_bev, meters_to_pixels


def generate_synthetic_samples(
    output_dir: str,
    num_samples: int = 500,
    start_id: int = 0,
) -> list[dict]:
    """Generate synthetic box room training samples with varied dimensions.

    Creates rooms with random:
      - Width: 2-8m
      - Depth: 2-6m
      - Height: 2.4-3.5m
      - Rotation: 0-45 degrees
      - Grid density: 8-15 subdivisions

    Also applies augmentations to simulate real scan conditions:
      - Random partial scan (drop 1 wall, 10% of samples)
      - Gaussian noise on vertex positions
      - Random furniture-like noise blobs

    Returns list of COCO annotation dicts.
    """
    from tests.fixtures.generate_ply import generate_dense_box_room_ply, generate_rotated_dense_room_ply
    from pipeline.stage1 import parse_and_classify
    import tempfile

    density_dir = os.path.join(output_dir, "density")
    os.makedirs(density_dir, exist_ok=True)

    annotations = []
    np.random.seed(42)

    for i in range(num_samples):
        sample_id = start_id + i
        width = np.random.uniform(2.0, 8.0)
        depth = np.random.uniform(2.0, 6.0)
        height = np.random.uniform(2.4, 3.5)
        angle = np.random.uniform(0, 45)
        grid_n = np.random.randint(8, 16)

        with tempfile.TemporaryDirectory() as tmpdir:
            ply_path = os.path.join(tmpdir, "mesh.ply")

            if angle > 1.0:
                info = generate_rotated_dense_room_ply(
                    ply_path, width=width, height=height, depth=depth,
                    angle_deg=angle, grid_n=grid_n,
                )
                corners_xz = info["expected_corners"]  # 4x2 rotated corners
            else:
                info = generate_dense_box_room_ply(
                    ply_path, width=width, height=height, depth=depth,
                    grid_n=grid_n,
                )
                hw, hd = width / 2, depth / 2
                corners_xz = np.array([[-hw, -hd], [hw, -hd], [hw, hd], [-hw, hd]])

            mesh = parse_and_classify(ply_path)

            # Apply augmentations
            if np.random.random() < 0.10:
                # Simulate partial scan: remove vertices from one wall
                mesh = _simulate_partial_scan(mesh, info)

            if np.random.random() < 0.15:
                # Add Gaussian noise to vertex positions
                noise = np.random.normal(0, 0.02, mesh.positions.shape).astype(np.float32)
                mesh.positions = mesh.positions + noise

            # Generate BEV density map
            bev = project_to_bev(mesh, resolution=256, structural_only=True)

            # Save density map as uint8 PNG
            density_uint8 = (bev.density_map * 255).astype(np.uint8)
            png_path = os.path.join(density_dir, f"{sample_id:05d}.png")
            _save_grayscale_png(density_uint8, png_path)

            # Convert ground truth corners to pixel coordinates
            corners_px = meters_to_pixels(corners_xz, bev)

            # Create COCO annotation
            # Flatten corners to [x1, y1, x2, y2, ...] format
            segmentation = corners_px.flatten().tolist()

            annotations.append({
                "image_id": sample_id,
                "category_id": 1,  # "room"
                "segmentation": [segmentation],
                "area": float(abs(_polygon_area(corners_px))),
                "id": sample_id,
            })

        if (i + 1) % 100 == 0:
            print(f"  Generated {i + 1}/{num_samples} synthetic samples")

    return annotations


def generate_real_samples(
    scan_dir: str,
    output_dir: str,
    start_id: int = 0,
) -> list[dict]:
    """Generate training samples from real annotated scans.

    Each subdirectory in scan_dir should contain:
      - mesh.ply: the LiDAR scan (production format)
      - ground_truth.json: {"corners_xz": [[x1,z1], [x2,z2], ...]}

    Returns list of COCO annotation dicts.
    """
    from pipeline.stage1 import parse_and_classify

    density_dir = os.path.join(output_dir, "density")
    os.makedirs(density_dir, exist_ok=True)

    annotations = []
    scan_dirs = sorted(Path(scan_dir).iterdir())
    sample_id = start_id

    for scan_path in scan_dirs:
        if not scan_path.is_dir():
            continue

        ply_path = scan_path / "mesh.ply"
        gt_path = scan_path / "ground_truth.json"

        if not ply_path.exists() or not gt_path.exists():
            print(f"  Skipping {scan_path.name}: missing mesh.ply or ground_truth.json")
            continue

        try:
            mesh = parse_and_classify(str(ply_path))
            with open(gt_path) as f:
                gt = json.load(f)

            corners_xz = np.array(gt["corners_xz"], dtype=np.float64)

            bev = project_to_bev(mesh, resolution=256, structural_only=True)

            density_uint8 = (bev.density_map * 255).astype(np.uint8)
            png_path = os.path.join(density_dir, f"{sample_id:05d}.png")
            _save_grayscale_png(density_uint8, png_path)

            corners_px = meters_to_pixels(corners_xz, bev)
            segmentation = corners_px.flatten().tolist()

            annotations.append({
                "image_id": sample_id,
                "category_id": 1,
                "segmentation": [segmentation],
                "area": float(abs(_polygon_area(corners_px))),
                "id": sample_id,
            })

            print(f"  {scan_path.name}: {len(corners_xz)} corners")
            sample_id += 1

        except Exception as e:
            print(f"  Skipping {scan_path.name}: {e}")

    return annotations


def _simulate_partial_scan(mesh, info):
    """Remove vertices from one wall to simulate incomplete LiDAR coverage."""
    wall_group = mesh.classification_groups.get(1)  # WALL
    if wall_group is None or len(wall_group.vertex_ids) < 10:
        return mesh

    wall_positions = mesh.positions[wall_group.vertex_ids]

    # Pick a random axis and side to remove
    axis = np.random.choice([0, 2])  # X or Z
    if np.random.random() < 0.5:
        mask = wall_positions[:, axis] > np.median(wall_positions[:, axis])
    else:
        mask = wall_positions[:, axis] < np.median(wall_positions[:, axis])

    # Move those wall vertices far away (effectively removing them)
    remove_ids = wall_group.vertex_ids[mask]
    mesh.positions[remove_ids] = np.array([999.0, 0.0, 999.0], dtype=np.float32)

    return mesh


def _polygon_area(corners: np.ndarray) -> float:
    """Compute polygon area from Nx2 vertices."""
    x, y = corners[:, 0], corners[:, 1]
    return 0.5 * abs(float(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1))))


def _save_grayscale_png(image: np.ndarray, path: str):
    """Save a 2D uint8 array as a grayscale PNG."""
    try:
        from PIL import Image
        Image.fromarray(image, mode='L').save(path)
    except ImportError:
        # Fallback: save as .npy if PIL not available
        np.save(path.replace('.png', '.npy'), image)


def main():
    parser = argparse.ArgumentParser(description="Generate RoomFormer training data")
    parser.add_argument("--output", "-o", required=True,
                        help="Output directory for training data")
    parser.add_argument("--scan-dir",
                        help="Directory of annotated real scans")
    parser.add_argument("--num-synthetic", type=int, default=500,
                        help="Number of synthetic samples to generate (default: 500)")
    parser.add_argument("--synthetic-only", action="store_true",
                        help="Generate only synthetic data (no real scans)")
    args = parser.parse_args()

    os.makedirs(args.output, exist_ok=True)
    all_annotations = []
    all_images = []
    sample_id = 0

    # Synthetic data
    print(f"Generating {args.num_synthetic} synthetic samples...")
    synth_annotations = generate_synthetic_samples(
        args.output, num_samples=args.num_synthetic, start_id=sample_id,
    )
    all_annotations.extend(synth_annotations)
    sample_id += len(synth_annotations)
    print(f"  {len(synth_annotations)} synthetic samples generated")

    # Real data
    if args.scan_dir and not args.synthetic_only:
        print(f"\nProcessing real scans from {args.scan_dir}...")
        real_annotations = generate_real_samples(
            args.scan_dir, args.output, start_id=sample_id,
        )
        all_annotations.extend(real_annotations)
        sample_id += len(real_annotations)
        print(f"  {len(real_annotations)} real samples processed")

    # Build COCO images list
    density_dir = os.path.join(args.output, "density")
    for ann in all_annotations:
        all_images.append({
            "file_name": f"{ann['image_id']:05d}.png",
            "height": 256,
            "width": 256,
            "id": ann["image_id"],
        })

    # Write COCO annotations JSON
    coco = {
        "images": all_images,
        "annotations": all_annotations,
        "categories": [{"id": 1, "name": "room"}],
    }

    ann_path = os.path.join(args.output, "annotations.json")
    with open(ann_path, "w") as f:
        json.dump(coco, f, indent=2)

    print(f"\nTotal: {len(all_annotations)} samples")
    print(f"Density maps: {density_dir}/")
    print(f"Annotations:  {ann_path}")


if __name__ == "__main__":
    main()
