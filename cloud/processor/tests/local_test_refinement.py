"""Local test: run photometric pose refinement on real Room 3 scan data.

Usage: cd cloud/processor/tests/local_scan && python3 ../local_test_refinement.py

Outputs:
  - textures_before/  — textures WITHOUT refinement (baseline)
  - textures_after/   — textures WITH refinement
  - refinement_log.txt — per-keyframe corrections
"""

import sys
import os
import json
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import numpy as np
import trimesh

from pipeline.texture_projection import (
    build_surfaces_from_annotation,
    load_keyframes,
    load_panoramic_keyframes,
    project_textures,
    save_textures,
    _refine_poses_photometric,
)


def main():
    scan_root = os.path.join(os.path.dirname(__file__), "local_scan", "scan_1774895423")

    if not os.path.exists(scan_root):
        print(f"Scan data not found at {scan_root}")
        print("Download with: gsutil -m cp -r gs://roomscanalpha-scans/scans/d6751509.../f717c754.../scan.zip .")
        sys.exit(1)

    # Load metadata
    with open(os.path.join(scan_root, "metadata.json")) as f:
        metadata = json.load(f)

    annotation = metadata.get("corner_annotation", {})
    corners_xz = annotation["corners_xz"]
    corners_y = annotation["corners_y"]

    print(f"Room: {len(corners_xz)} corners")
    print(f"Corners Y (ceiling heights): {[f'{y:.2f}' for y in corners_y]}")

    # Build surfaces
    surfaces = build_surfaces_from_annotation(corners_xz, corners_y)
    print(f"Surfaces: {[s.surface_id for s in surfaces]}")
    for s in surfaces:
        print(f"  {s.surface_id}: {s.width_m:.1f}m x {s.height_m:.1f}m")

    # Load keyframes (limit to save memory)
    print("\nLoading keyframes...")
    walk_kfs = load_keyframes(scan_root, metadata)
    pano_kfs = load_panoramic_keyframes(scan_root, metadata)
    all_kfs = pano_kfs + walk_kfs
    print(f"Total: {len(pano_kfs)} panoramic + {len(walk_kfs)} walk = {len(all_kfs)} keyframes")

    # Estimate memory
    if all_kfs:
        kf = all_kfs[0]
        mem_per_kf_mb = kf.image.nbytes / 1024 / 1024
        total_img_mb = mem_per_kf_mb * len(all_kfs)
        print(f"Image memory: {mem_per_kf_mb:.1f}MB/kf x {len(all_kfs)} = {total_img_mb:.0f}MB")

    # Build mesh
    print("\nBuilding mesh...")
    ply_path = os.path.join(scan_root, "mesh.ply")
    mesh = trimesh.load(ply_path)
    print(f"Mesh: {len(mesh.vertices)} vertices, {len(mesh.faces)} faces")

    # === STEP 1: Baseline textures (no refinement) ===
    print("\n=== BASELINE: project_textures WITHOUT refinement ===")
    out_before = os.path.join(os.path.dirname(__file__), "local_scan", "textures_before")
    t0 = time.time()
    results_before = project_textures(all_kfs, surfaces, mesh=mesh)
    t_baseline = time.time() - t0
    save_textures(results_before, out_before)
    print(f"Baseline done in {t_baseline:.1f}s")

    # === STEP 2: Compute refinement corrections only (log, don't apply yet) ===
    print("\n=== REFINEMENT: computing pose corrections ===")
    t0 = time.time()
    try:
        corrections = _refine_poses_photometric(surfaces, all_kfs, mesh)
        t_refine = time.time() - t0
        print(f"Refinement done in {t_refine:.1f}s")
        print(f"Corrections for {len(corrections)} keyframes:")

        log_lines = []
        for kf_idx, (dx, dy, dt) in sorted(corrections.items()):
            line = f"  kf {kf_idx}: dx={dx:+.1f}px  dy={dy:+.1f}px  dθ={dt:+.5f}rad"
            print(line)
            log_lines.append(line)

        # Stats
        if corrections:
            dxs = [v[0] for v in corrections.values()]
            dys = [v[1] for v in corrections.values()]
            dts = [v[2] for v in corrections.values()]
            print(f"\n  dx range: [{min(dxs):+.1f}, {max(dxs):+.1f}] px")
            print(f"  dy range: [{min(dys):+.1f}, {max(dys):+.1f}] px")
            print(f"  dθ range: [{min(dts):+.5f}, {max(dts):+.5f}] rad")

        # Save log
        log_path = os.path.join(os.path.dirname(__file__), "local_scan", "refinement_log.txt")
        with open(log_path, "w") as f:
            f.write("\n".join(log_lines))
        print(f"\nLog saved to {log_path}")

    except Exception as e:
        import traceback
        print(f"Refinement FAILED: {e}")
        traceback.print_exc()
        t_refine = time.time() - t0
        corrections = {}

    # === STEP 3: Textures WITH refinement ===
    if corrections:
        print("\n=== REFINED: project_textures WITH corrections ===")
        out_after = os.path.join(os.path.dirname(__file__), "local_scan", "textures_after")
        t0 = time.time()
        results_after = project_textures(all_kfs, surfaces, mesh=mesh)
        t_refined = time.time() - t0
        save_textures(results_after, out_after)
        print(f"Refined projection done in {t_refined:.1f}s")
    else:
        print("\nNo corrections computed — skipping refined projection")

    print("\n=== SUMMARY ===")
    print(f"Baseline time: {t_baseline:.1f}s")
    print(f"Refinement time: {t_refine:.1f}s")
    print(f"Corrections: {len(corrections)} keyframes")
    print(f"\nCompare textures:")
    print(f"  Before: {out_before}/")
    if corrections:
        print(f"  After:  {out_after}/")


if __name__ == "__main__":
    main()
