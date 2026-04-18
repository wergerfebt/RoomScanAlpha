#!/usr/bin/env python3
"""
Post-training floater filter for Gaussian splats.

Culls Gaussians that are both far from the ARKit LiDAR mesh AND look "floater-y"
(low opacity or large scale). The conjunction preserves fine geometry the mesh
missed (fan blades, plant leaves, cords) while deleting spurious air Gaussians.

Input .splat must already be in ARKit world frame (meters, Y-up), matching the
mesh.ply coordinate system.

Usage:
    python3 cull_floaters.py --splat room_scan_arkit.splat --mesh mesh.ply
    python3 cull_floaters.py --splat ... --mesh ... --save-culled
    python3 cull_floaters.py --splat ... --mesh ... --margin 0.10 --opacity-threshold 0.2
"""

import argparse
import sys
import time
import numpy as np
import trimesh
from scipy.spatial import cKDTree


def parse_splat(path):
    with open(path, 'rb') as f:
        buf = bytearray(f.read())
    n = len(buf) // 32
    arr = np.frombuffer(buf, dtype=np.uint8).reshape(n, 32).copy()
    xyz = np.frombuffer(arr[:, 0:12].tobytes(), dtype=np.float32).reshape(n, 3).copy()
    scales = np.frombuffer(arr[:, 12:24].tobytes(), dtype=np.float32).reshape(n, 3).copy()
    rgba = arr[:, 24:28].copy()
    return arr, xyz, scales, rgba


def quartiles(x, label):
    if len(x) == 0:
        return f'  {label}: (empty)'
    q = np.quantile(x, [0.0, 0.25, 0.5, 0.75, 1.0])
    return f'  {label}: min={q[0]:.3f} q25={q[1]:.3f} med={q[2]:.3f} q75={q[3]:.3f} max={q[4]:.3f}'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--splat', required=True, help='Input .splat (ARKit frame)')
    ap.add_argument('--mesh', required=True, help='mesh.ply (ARKit frame)')
    ap.add_argument('--bbox-margin', type=float, default=0.10,
                    help='Cull Gaussians more than this far beyond the mesh bounding box in meters (default: 0.10)')
    ap.add_argument('--fog-margin', type=float, default=0.30,
                    help='Inside the bbox, cull Gaussians farther than this from any mesh surface IF they are also low-opacity. Default: 0.30')
    ap.add_argument('--fog-opacity', type=float, default=0.30,
                    help='In-bbox fog detection: sigmoid opacity threshold (default: 0.30)')
    ap.add_argument('--surface-samples', type=int, default=500_000,
                    help='Points to sample on mesh surface for KDTree (default: 500000)')
    ap.add_argument('--save-culled', action='store_true',
                    help='Also write a _culled.splat with the removed Gaussians for inspection')
    ap.add_argument('--output', default=None, help='Output path (default: {splat}_filtered.splat)')
    args = ap.parse_args()

    t0 = time.time()

    print(f'Loading splat: {args.splat}')
    arr, xyz, scales, rgba = parse_splat(args.splat)
    n = len(xyz)
    print(f'  {n:,} Gaussians')

    print(f'Loading mesh: {args.mesh}')
    mesh = trimesh.load(args.mesh, force='mesh')
    if not hasattr(mesh, 'faces'):
        print(f'ERROR: loaded object is not a mesh (got {type(mesh).__name__})')
        sys.exit(1)
    print(f'  {len(mesh.vertices):,} verts, {len(mesh.faces):,} faces, bbox={mesh.bounds.tolist()}')

    print(f'Sampling {args.surface_samples:,} points on mesh surface...')
    t_sample = time.time()
    surface_pts = mesh.sample(args.surface_samples)
    print(f'  done in {time.time()-t_sample:.1f}s')

    print(f'Building KDTree + querying distances...')
    t_dist = time.time()
    tree = cKDTree(surface_pts)
    dist_abs, _ = tree.query(xyz, k=1, workers=-1)
    print(f'  done in {time.time()-t_dist:.1f}s')

    opacity_norm = rgba[:, 3].astype(np.float32) / 255.0
    max_scale = scales.max(axis=1)

    mesh_min = mesh.bounds[0]
    mesh_max = mesh.bounds[1]
    outside_bbox = ((xyz < (mesh_min - args.bbox_margin)) | (xyz > (mesh_max + args.bbox_margin))).any(axis=1)

    far_in_room = dist_abs > args.fog_margin
    low_op = opacity_norm < args.fog_opacity
    fog = (~outside_bbox) & far_in_room & low_op

    cull_mask = outside_bbox | fog
    keep_mask = ~cull_mask

    n_cull = int(cull_mask.sum())
    n_keep = int(keep_mask.sum())

    print()
    print(f'=== Filter results ===')
    print(f'  Kept:   {n_keep:,} ({100*n_keep/n:.1f}%)')
    print(f'  Culled: {n_cull:,} ({100*n_cull/n:.1f}%)')
    print()
    print(f'=== Cull breakdown (among {n_cull:,} culled) ===')
    if n_cull > 0:
        n_outside = int(outside_bbox.sum())
        n_fog = int(fog.sum())
        print(f'  Outside-bbox outliers: {n_outside:,} ({100*n_outside/n_cull:.1f}%)')
        print(f'  In-bbox fog (far+low-opacity): {n_fog:,} ({100*n_fog/n_cull:.1f}%)')
    print()
    print(f'=== Population stats ===')
    print(f'  All Gaussians:')
    print(quartiles(dist_abs, 'dist_to_mesh (m)'))
    print(quartiles(opacity_norm, 'opacity (sigmoid)'))
    print(quartiles(max_scale, 'max_scale (m)'))
    if n_cull > 0:
        print(f'  Culled Gaussians:')
        print(quartiles(dist_abs[cull_mask], 'dist_to_mesh (m)'))
        print(quartiles(opacity_norm[cull_mask], 'opacity (sigmoid)'))
        print(quartiles(max_scale[cull_mask], 'max_scale (m)'))

    if n_cull > 0:
        far_positions = xyz[cull_mask][np.argsort(-dist_abs[cull_mask])[:5]]
        print()
        print(f'=== Top 5 culled (by distance) ===')
        for p in far_positions:
            print(f'  xyz=({p[0]:+.2f}, {p[1]:+.2f}, {p[2]:+.2f})')

        print()
        print(f'=== Culled position distribution ===')
        cp = xyz[cull_mask]
        mesh_min = mesh.bounds[0]
        mesh_max = mesh.bounds[1]
        in_bbox = ((cp >= mesh_min) & (cp <= mesh_max)).all(axis=1)
        print(f'  Inside mesh bbox:  {int(in_bbox.sum()):,} ({100*in_bbox.mean():.1f}%)')
        print(f'  Outside mesh bbox: {int((~in_bbox).sum()):,} ({100*(~in_bbox).mean():.1f}%)')
        print(f'  Mesh bbox Y (height): {mesh_min[1]:+.2f} -> {mesh_max[1]:+.2f}')
        # Y histogram: 6 bins from floor to ceiling
        y_in = cp[in_bbox, 1]
        if len(y_in) > 0:
            bins = np.linspace(mesh_min[1], mesh_max[1], 7)
            hist, _ = np.histogram(y_in, bins=bins)
            print(f'  Y-histogram (in-bbox culls, floor->ceiling):')
            for i, c in enumerate(hist):
                bar = '#' * int(40 * c / max(1, hist.max()))
                print(f'    [{bins[i]:+.2f}, {bins[i+1]:+.2f}]: {c:>6,} {bar}')

    out_path = args.output or args.splat.replace('.splat', '_filtered.splat')
    with open(out_path, 'wb') as f:
        f.write(arr[keep_mask].tobytes())
    print()
    print(f'Wrote: {out_path} ({n_keep:,} Gaussians)')

    if args.save_culled and n_cull > 0:
        culled_path = args.splat.replace('.splat', '_culled.splat')
        with open(culled_path, 'wb') as f:
            f.write(arr[cull_mask].tobytes())
        print(f'Wrote: {culled_path} ({n_cull:,} Gaussians)')

    print(f'Total: {time.time()-t0:.1f}s')


if __name__ == '__main__':
    main()
