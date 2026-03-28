#!/usr/bin/env python3
"""
Visualize BEV density maps from PLY scan files.

Supports both production PLYs (per-face classifications) and debug PLYs
(per-vertex RGB colors from CLASS_COLORS).

Usage:
    python scripts/visualize_bev.py <ply_path> [--output <png_path>] [--debug-ply]
    python scripts/visualize_bev.py /path/to/classified_debug.ply --debug-ply

For BEV.H1 / BEV.H2 human-in-the-loop tests.
"""

import argparse
import struct
import sys
from pathlib import Path

import numpy as np

# Add parent dir to path so we can import pipeline modules
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pipeline.bev_projection import project_to_bev, BEVProjection
from pipeline.stage1 import ParsedMesh, ClassificationGroup, CLASSIFICATION_NAMES, parse_and_classify

# Debug PLY color → classification mapping (from diagnose_pipeline.py)
COLOR_TO_CLASS = {
    (128, 128, 128): 0,  # none
    (200, 180, 140): 1,  # wall
    (100, 160, 100): 2,  # floor
    (140, 140, 200): 3,  # ceiling
    (200, 100, 100): 4,  # table
    (200, 200, 100): 5,  # seat
    (100, 200, 200): 6,  # door
    (200, 100, 200): 7,  # window
}


def parse_debug_ply(ply_path: str) -> ParsedMesh:
    """Parse a debug PLY (vertex colors, no normals, no face classifications).

    Debug PLYs have per-vertex RGB colors encoding the classification.
    Format: x, y, z (float32) + r, g, b (uint8) per vertex.
    Faces have 3 uint32 indices, no classification byte.
    """
    with open(ply_path, "rb") as f:
        # Read header
        header_lines = []
        while True:
            line = f.readline().decode("ascii", errors="replace").strip()
            header_lines.append(line)
            if line == "end_header":
                break

        vertex_count = face_count = 0
        for line in header_lines:
            if line.startswith("element vertex"):
                vertex_count = int(line.split()[-1])
            elif line.startswith("element face"):
                face_count = int(line.split()[-1])

        # Read vertex data: x, y, z (3 floats) + r, g, b (3 uint8) = 15 bytes
        vertex_data = f.read(vertex_count * 15)
        positions = np.zeros((vertex_count, 3), dtype=np.float32)
        colors = np.zeros((vertex_count, 3), dtype=np.uint8)

        for i in range(vertex_count):
            offset = i * 15
            x, y, z = struct.unpack_from("<fff", vertex_data, offset)
            r, g, b = struct.unpack_from("<BBB", vertex_data, offset + 12)
            positions[i] = [x, y, z]
            colors[i] = [r, g, b]

        # Map vertex colors to classification IDs
        vertex_classes = np.zeros(vertex_count, dtype=np.uint8)
        for i in range(vertex_count):
            color_tuple = tuple(colors[i].tolist())
            vertex_classes[i] = COLOR_TO_CLASS.get(color_tuple, 0)

        # Read face data: 1 byte count + 3 uint32 indices = 13 bytes per face
        face_data = f.read(face_count * 13)
        faces = np.zeros((face_count, 3), dtype=np.uint32)
        for i in range(face_count):
            offset = i * 13
            _, v0, v1, v2 = struct.unpack_from("<B3I", face_data, offset)
            faces[i] = [v0, v1, v2]

    # Assign face classification from majority vote of its vertex classifications
    face_classifications = np.zeros(face_count, dtype=np.uint8)
    for i in range(face_count):
        v_classes = vertex_classes[faces[i]]
        # Majority vote (mode)
        vals, counts = np.unique(v_classes, return_counts=True)
        face_classifications[i] = vals[counts.argmax()]

    # Build classification groups
    groups = {}
    for cls_id in np.unique(face_classifications):
        cls_int = int(cls_id)
        mask = face_classifications == cls_id
        face_indices = np.nonzero(mask)[0].astype(np.int32)
        group_faces = faces[mask]
        vertex_ids = np.unique(group_faces.ravel()).astype(np.int32)
        groups[cls_int] = ClassificationGroup(
            classification_id=cls_int,
            classification_name=CLASSIFICATION_NAMES.get(cls_int, f"unknown_{cls_int}"),
            face_indices=face_indices,
            vertex_ids=vertex_ids,
        )

    # Bounding box
    min_pos = positions.min(axis=0)
    max_pos = positions.max(axis=0)
    extents = max_pos - min_pos
    bbox = {
        "min_x": float(min_pos[0]), "min_y": float(min_pos[1]), "min_z": float(min_pos[2]),
        "max_x": float(max_pos[0]), "max_y": float(max_pos[1]), "max_z": float(max_pos[2]),
        "x_m": float(extents[0]), "y_m": float(extents[1]), "z_m": float(extents[2]),
    }

    # Fake normals (not needed for BEV projection)
    normals = np.zeros_like(positions)

    return ParsedMesh(
        positions=positions,
        normals=normals,
        faces=faces,
        face_classifications=face_classifications,
        classification_groups=groups,
        bbox=bbox,
        vertex_count=vertex_count,
        face_count=face_count,
    )


def save_bev_png(bev: BEVProjection, output_path: str, title: str = "BEV Density Map"):
    """Save density map as a PNG using matplotlib."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        # Fallback: save as raw numpy
        np.save(output_path.replace(".png", ".npy"), bev.density_map)
        print(f"matplotlib not available. Saved raw density map to {output_path.replace('.png', '.npy')}")
        return

    fig, ax = plt.subplots(1, 1, figsize=(8, 8))
    im = ax.imshow(bev.density_map, cmap="hot", origin="lower", vmin=0, vmax=1)
    ax.set_title(title)
    ax.set_xlabel(f"X ({bev.xmin:.2f}m to {bev.xmax:.2f}m)")
    ax.set_ylabel(f"Z ({bev.zmin:.2f}m to {bev.zmax:.2f}m)")
    plt.colorbar(im, ax=ax, label="Normalized density")

    # Add stats text
    nonzero = np.count_nonzero(bev.density_map)
    total = bev.resolution * bev.resolution
    stats = (
        f"Resolution: {bev.resolution}x{bev.resolution}\n"
        f"Non-zero pixels: {nonzero} ({100*nonzero/total:.1f}%)\n"
        f"Scale: {bev.meters_per_pixel_x:.4f} m/px"
    )
    ax.text(0.02, 0.98, stats, transform=ax.transAxes, fontsize=8,
            verticalalignment="top", bbox=dict(boxstyle="round", facecolor="white", alpha=0.8))

    fig.tight_layout()
    fig.savefig(output_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved BEV density map to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Visualize BEV density map from PLY scan")
    parser.add_argument("ply_path", help="Path to PLY file")
    parser.add_argument("--output", "-o", help="Output PNG path (default: <ply_dir>/bev_density.png)")
    parser.add_argument("--debug-ply", action="store_true",
                        help="Parse as debug PLY (vertex colors, no face classifications)")
    parser.add_argument("--resolution", type=int, default=256, help="BEV resolution (default: 256)")
    parser.add_argument("--no-filter", action="store_true",
                        help="Include all vertices (don't filter to structural only)")
    args = parser.parse_args()

    ply_path = args.ply_path
    if not Path(ply_path).exists():
        print(f"Error: {ply_path} not found")
        sys.exit(1)

    # Parse PLY
    if args.debug_ply:
        print(f"Parsing debug PLY: {ply_path}")
        mesh = parse_debug_ply(ply_path)
    else:
        print(f"Parsing production PLY: {ply_path}")
        mesh = parse_and_classify(ply_path)

    # Print classification summary
    print(f"  Vertices: {mesh.vertex_count:,}  Faces: {mesh.face_count:,}")
    for cls_id, group in sorted(mesh.classification_groups.items()):
        print(f"  {group.classification_name} ({cls_id}): "
              f"{group.vertex_count:,} verts, {group.face_count:,} faces")

    # Project to BEV
    structural_only = not args.no_filter
    bev = project_to_bev(mesh, resolution=args.resolution, structural_only=structural_only)

    # Determine output path
    if args.output:
        output_path = args.output
    else:
        ply_dir = Path(ply_path).parent
        suffix = "structural" if structural_only else "all"
        output_path = str(ply_dir / f"bev_density_{suffix}.png")

    title = f"BEV Density Map — {Path(ply_path).name}"
    if structural_only:
        title += " (structural only)"

    save_bev_png(bev, output_path, title=title)

    # Print BEV stats
    print(f"  BEV bbox: X=[{bev.xmin:.3f}, {bev.xmax:.3f}], Z=[{bev.zmin:.3f}, {bev.zmax:.3f}]")
    print(f"  Scale: {bev.meters_per_pixel_x:.4f} m/px")
    print(f"  Non-zero pixels: {np.count_nonzero(bev.density_map)}")


if __name__ == "__main__":
    main()
