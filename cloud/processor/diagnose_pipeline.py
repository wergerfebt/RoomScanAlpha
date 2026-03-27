#!/usr/bin/env python3
"""
Pipeline diagnostic — run Stages 1-3 on a real scan and report results.

Outputs:
  1. Text report with counts, dimensions, plane normals, etc.
  2. simplified_mesh.ply — the Stage 3 output as a viewable PLY
  3. classified_debug.ply — the raw mesh with classification colors for visual check

Usage:
  python diagnose_pipeline.py /path/to/mesh.ply [output_dir]
"""

import sys
import struct
import time
from pathlib import Path

import numpy as np

from pipeline.stage1 import (
    parse_and_classify,
    CLASSIFICATION_NAMES,
    CLASSIFICATION_FLOOR,
    CLASSIFICATION_CEILING,
    CLASSIFICATION_WALL,
)
from pipeline.stage2 import fit_planes
from pipeline.stage3 import assemble_geometry


# Colors per classification for debug PLY (RGB 0-255)
CLASS_COLORS = {
    0: (128, 128, 128),  # none — gray
    1: (200, 180, 140),  # wall — tan
    2: (100, 160, 100),  # floor — green
    3: (140, 140, 200),  # ceiling — blue
    4: (200, 100, 100),  # table — red
    5: (200, 200, 100),  # seat — yellow
    6: (100, 200, 200),  # door — cyan
    7: (200, 100, 200),  # window — magenta
}


def main():
    if len(sys.argv) < 2:
        print("Usage: python diagnose_pipeline.py <mesh.ply> [output_dir]")
        sys.exit(1)

    ply_path = sys.argv[1]
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(ply_path).parent
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"{'='*60}")
    print(f"PIPELINE DIAGNOSTIC")
    print(f"{'='*60}")
    print(f"Input: {ply_path}")
    print()

    # --- Stage 1 ---
    print(f"--- Stage 1: Parse & Classify ---")
    t0 = time.perf_counter()
    mesh = parse_and_classify(ply_path)
    t1 = time.perf_counter()
    print(f"  Time: {t1-t0:.2f}s")
    print(f"  Vertices: {mesh.vertex_count:,}")
    print(f"  Faces: {mesh.face_count:,}")
    # bbox extent keys vary (bbox_x or x_m depending on linter)
    bx = mesh.bbox.get("bbox_x", mesh.bbox.get("x_m", 0))
    by = mesh.bbox.get("bbox_y", mesh.bbox.get("y_m", 0))
    bz = mesh.bbox.get("bbox_z", mesh.bbox.get("z_m", 0))
    print(f"  BBox: X={bx:.2f}m  Y={by:.2f}m  Z={bz:.2f}m")
    print(f"  Classification groups:")
    for cls_id, group in sorted(mesh.classification_groups.items()):
        pct = 100.0 * group.face_count / mesh.face_count
        print(f"    {group.classification_name:10s} (id={cls_id}): "
              f"{group.face_count:>7,} faces ({pct:5.1f}%), "
              f"{group.vertex_count:>7,} vertices")
    print()

    # Export classified debug PLY
    debug_ply = out_dir / "classified_debug.ply"
    _export_classified_ply(mesh, debug_ply)
    print(f"  Exported: {debug_ply}")
    print()

    # --- Stage 2 ---
    print(f"--- Stage 2: Plane Fitting ---")
    t2 = time.perf_counter()
    plan = fit_planes(mesh)
    t3 = time.perf_counter()
    print(f"  Time: {t3-t2:.2f}s")
    print(f"  Planes detected: {len(plan.planes)}")
    print(f"  Objects detected: {len(plan.objects)}")

    for p in plan.floor_planes:
        print(f"    FLOOR: normal=({p.normal[0]:+.3f}, {p.normal[1]:+.3f}, {p.normal[2]:+.3f}), "
              f"Y={p.point_on_plane[1]:.3f}m, area={p.area_sqm:.1f}m², "
              f"inliers={p.inlier_count:,}")

    for p in plan.ceiling_planes:
        print(f"    CEIL:  normal=({p.normal[0]:+.3f}, {p.normal[1]:+.3f}, {p.normal[2]:+.3f}), "
              f"Y={p.point_on_plane[1]:.3f}m, area={p.area_sqm:.1f}m², "
              f"inliers={p.inlier_count:,}")

    for i, p in enumerate(plan.wall_planes):
        print(f"    WALL{i}: normal=({p.normal[0]:+.3f}, {p.normal[1]:+.3f}, {p.normal[2]:+.3f}), "
              f"area={p.area_sqm:.1f}m², inliers={p.inlier_count:,}")

    for o in plan.objects:
        print(f"    OBJ:   {o.classification}, center=({o.center[0]:.2f}, {o.center[1]:.2f}, {o.center[2]:.2f}), "
              f"dims=({o.dimensions[0]:.2f}, {o.dimensions[1]:.2f}, {o.dimensions[2]:.2f})m, "
              f"faces={o.face_count}")

    if plan.floor_planes and plan.ceiling_planes:
        floor_y = plan.floor_planes[0].point_on_plane[1]
        ceil_y = plan.ceiling_planes[0].point_on_plane[1]
        height_m = abs(ceil_y - floor_y)
        print(f"  Ceiling height: {height_m:.3f}m ({height_m * 3.28084:.1f}ft)")
    print()

    # --- Stage 3 ---
    if not plan.floor_planes or not plan.ceiling_planes:
        print("  SKIPPING Stage 3 — no floor or ceiling plane detected")
        print()
        _print_summary(mesh, plan, None)
        return

    print(f"--- Stage 3: Geometry Assembly ---")
    t4 = time.perf_counter()
    smesh = assemble_geometry(plan, mesh)
    t5 = time.perf_counter()
    print(f"  Time: {t5-t4:.3f}s")
    print(f"  Simplified vertices: {len(smesh.vertices):,} (vs {mesh.vertex_count:,} raw = "
          f"{100*len(smesh.vertices)/mesh.vertex_count:.1f}%)")
    print(f"  Simplified faces: {len(smesh.faces):,}")
    print(f"  Surface labels: {sorted(set(smesh.face_labels))}")

    label_counts = {}
    for l in smesh.face_labels:
        label_counts[l] = label_counts.get(l, 0) + 1
    for label, count in sorted(label_counts.items()):
        extra = ""
        if label in smesh.surface_map:
            sm = smesh.surface_map[label]
            orig = sm.get("original_face_count", 0)
            area = sm.get("area_sqm", 0)
            if orig:
                extra = f" (was {orig:,}, area={area:.1f}m²)"
        print(f"    {label:15s}: {count:>5} triangles{extra}")

    # Export simplified mesh PLY
    simplified_ply = out_dir / "simplified_mesh.ply"
    _export_simplified_ply(smesh, simplified_ply)
    print(f"  Exported: {simplified_ply}")
    print()

    _print_summary(mesh, plan, smesh)


def _print_summary(mesh, plan, smesh):
    """Print a final summary with key measurements."""
    print(f"{'='*60}")
    print(f"SUMMARY")
    print(f"{'='*60}")

    SQM_TO_SQFT = 10.7639
    M_TO_FT = 3.28084

    if plan.floor_planes:
        floor = plan.floor_planes[0]
        print(f"  Floor area:   {floor.area_sqm:.1f} m²  ({floor.area_sqm * SQM_TO_SQFT:.0f} sqft)")

    if plan.floor_planes and plan.ceiling_planes:
        height = abs(plan.ceiling_planes[0].point_on_plane[1] - plan.floor_planes[0].point_on_plane[1])
        print(f"  Ceiling ht:   {height:.2f} m  ({height * M_TO_FT:.1f} ft)")

    total_wall = sum(p.area_sqm for p in plan.wall_planes)
    if total_wall > 0:
        print(f"  Wall area:    {total_wall:.1f} m²  ({total_wall * SQM_TO_SQFT:.0f} sqft)")

    print(f"  Wall planes:  {len(plan.wall_planes)}")
    print(f"  Objects:      {len(plan.objects)}")

    if smesh:
        print(f"  Simplified:   {len(smesh.vertices)} verts, {len(smesh.faces)} tris")

    print()
    print("Open the PLY files in MeshLab, Blender, or any 3D viewer to inspect.")


def _export_classified_ply(mesh, path):
    """Export the raw mesh with per-vertex colors based on face classification."""
    # Assign colors per vertex (use the classification of the first face that references it)
    vertex_colors = np.full((mesh.vertex_count, 3), 128, dtype=np.uint8)
    for fi in range(mesh.face_count):
        cls = int(mesh.face_classifications[fi])
        color = CLASS_COLORS.get(cls, (128, 128, 128))
        for vi in mesh.faces[fi]:
            vertex_colors[vi] = color

    header = (
        f"ply\n"
        f"format binary_little_endian 1.0\n"
        f"element vertex {mesh.vertex_count}\n"
        f"property float x\nproperty float y\nproperty float z\n"
        f"property uchar red\nproperty uchar green\nproperty uchar blue\n"
        f"element face {mesh.face_count}\n"
        f"property list uchar uint vertex_indices\n"
        f"end_header\n"
    )
    with open(path, "wb") as f:
        f.write(header.encode("ascii"))
        for i in range(mesh.vertex_count):
            p = mesh.positions[i]
            c = vertex_colors[i]
            f.write(struct.pack("<3f3B", p[0], p[1], p[2], c[0], c[1], c[2]))
        for fi in range(mesh.face_count):
            face = mesh.faces[fi]
            f.write(struct.pack("<B3I", 3, int(face[0]), int(face[1]), int(face[2])))


def _export_simplified_ply(smesh, path):
    """Export the simplified mesh as a colored PLY (walls=tan, floor=green, ceiling=blue)."""
    LABEL_COLORS = {
        "floor": (100, 160, 100),
        "ceiling": (140, 140, 200),
    }
    n_verts = len(smesh.vertices)
    n_faces = len(smesh.faces)

    # Assign per-vertex color from face labels
    vertex_colors = np.full((n_verts, 3), 128, dtype=np.uint8)
    for fi in range(n_faces):
        label = smesh.face_labels[fi]
        if label.startswith("wall_"):
            color = (200, 180, 140)
        elif label in LABEL_COLORS:
            color = LABEL_COLORS[label]
        else:
            color = (200, 100, 100)  # objects: red
        for vi in smesh.faces[fi]:
            vertex_colors[vi] = color

    header = (
        f"ply\n"
        f"format binary_little_endian 1.0\n"
        f"element vertex {n_verts}\n"
        f"property float x\nproperty float y\nproperty float z\n"
        f"property uchar red\nproperty uchar green\nproperty uchar blue\n"
        f"element face {n_faces}\n"
        f"property list uchar uint vertex_indices\n"
        f"end_header\n"
    )
    with open(path, "wb") as f:
        f.write(header.encode("ascii"))
        for i in range(n_verts):
            p = smesh.vertices[i]
            c = vertex_colors[i]
            f.write(struct.pack("<3f3B", p[0], p[1], p[2], c[0], c[1], c[2]))
        for fi in range(n_faces):
            face = smesh.faces[fi]
            f.write(struct.pack("<B3I", 3, int(face[0]), int(face[1]), int(face[2])))


if __name__ == "__main__":
    main()
