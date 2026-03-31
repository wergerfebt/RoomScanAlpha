"""Profile texture pipeline on real Room 3 data — no trimesh.

Uses 40 keyframes (mixed pano+walk), refines across all walls,
projects the 3 largest walls for visual comparison.
"""

import sys
import os
import json
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import numpy as np

scan_root = os.path.join(os.path.dirname(__file__), "local_scan", "scan_1774895423")

with open(os.path.join(scan_root, "metadata.json")) as f:
    metadata = json.load(f)
annotation = metadata.get("corner_annotation", {})

from pipeline.texture_projection import (
    build_surfaces_from_annotation,
    load_keyframes,
    load_panoramic_keyframes,
    project_textures,
    save_textures,
    _refine_poses_photometric,
    _score_keyframes,
)

surfaces = build_surfaces_from_annotation(annotation["corners_xz"], annotation["corners_y"])
walls = [s for s in surfaces if s.surface_type == "wall" and s.width_m > 1.0]
print(f"Walls for comparison: {[w.surface_id for w in walls]}")

t0 = time.time()
walk_kfs = load_keyframes(scan_root, metadata)
pano_kfs = load_panoramic_keyframes(scan_root, metadata)
print(f"[{time.time()-t0:.1f}s] {len(pano_kfs)} pano + {len(walk_kfs)} walk")

# Select top 40 keyframes (balanced pano+walk) scored against largest wall
wall_4 = [s for s in surfaces if s.surface_id == "wall_4"][0]
pano_scored = _score_keyframes(wall_4, pano_kfs)
walk_scored = _score_keyframes(wall_4, walk_kfs)
test_kfs = [kf for _, kf in pano_scored[:20]] + [kf for _, kf in walk_scored[:20]]
print(f"Using {len(test_kfs)} keyframes (20 pano + up to 20 walk)")

# --- Baseline ---
print(f"\n=== BASELINE ===")
t1 = time.time()
results_baseline = project_textures(test_kfs, walls, mesh=None)
print(f"[{time.time()-t1:.1f}s]")
out_b = os.path.join(os.path.dirname(__file__), "local_scan", "textures_baseline")
os.makedirs(out_b, exist_ok=True)
save_textures(results_baseline, out_b)

# --- Refinement ---
print(f"\n=== REFINEMENT ===")
t2 = time.time()
corrections = _refine_poses_photometric(walls, test_kfs, mesh=None)
t_r = time.time() - t2
print(f"[{t_r:.1f}s] {len(corrections)} corrections")

if corrections:
    dxs = [v[0] for v in corrections.values()]
    dys = [v[1] for v in corrections.values()]
    mags = [np.sqrt(dx**2+dy**2) for dx,dy,_ in corrections.values()]
    print(f"  magnitude: mean={np.mean(mags):.1f}px, max={max(mags):.1f}px")

    # --- Refined projection ---
    print(f"\n=== REFINED ===")
    t3 = time.time()
    results_refined = project_textures(test_kfs, walls, mesh=None,
                                       pose_corrections=corrections)
    print(f"[{time.time()-t3:.1f}s]")
    out_r = os.path.join(os.path.dirname(__file__), "local_scan", "textures_refined")
    os.makedirs(out_r, exist_ok=True)
    save_textures(results_refined, out_r)

    print(f"\n=== COMPARE ===")
    for w in walls:
        print(f"  {w.surface_id}: {out_b}/{w.surface_id}.jpg  vs  {out_r}/{w.surface_id}.jpg")
