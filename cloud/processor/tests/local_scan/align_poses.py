#!/usr/bin/env python3
"""Procrustes-align COLMAP BA poses back to the ARKit coordinate frame.

COLMAP BA has 7 degrees of freedom (3 translation + 3 rotation + 1 scale)
that are undetermined. After BA, the reconstruction may have drifted in
scale and position. This script computes the optimal similarity transform
(scale + rotation + translation) that maps the refined camera positions
back onto the original ARKit camera positions, then applies it to all
refined poses.

Usage:
    python3 align_poses.py <original_images.txt> <refined_images.txt> <output_images.txt>
"""

import sys
import os
import numpy as np
from scipy.spatial.transform import Rotation


def parse_images_txt(path):
    """Parse COLMAP images.txt → {name: (qw,qx,qy,qz, tx,ty,tz), ...} + lines."""
    poses = {}
    lines = []
    with open(path) as f:
        for line in f:
            lines.append(line)
            if line.startswith('#') or line.strip() == '':
                continue
            parts = line.strip().split()
            if len(parts) >= 10 and parts[9].endswith('.jpg'):
                name = parts[9]
                poses[name] = [float(x) for x in parts[1:8]]
    return poses, lines


def cam_position(qw, qx, qy, qz, tx, ty, tz):
    """COLMAP cam-from-world → camera center in world coords."""
    R = Rotation.from_quat([qx, qy, qz, qw]).as_matrix()
    t = np.array([tx, ty, tz])
    return -R.T @ t


def procrustes(src, dst):
    """Compute similarity transform: dst ≈ scale * R @ src + t.

    Returns (scale, R_3x3, t_3x1).
    """
    mu_src = src.mean(axis=0)
    mu_dst = dst.mean(axis=0)
    src_c = src - mu_src
    dst_c = dst - mu_dst

    # Optimal rotation (Kabsch)
    H = src_c.T @ dst_c
    U, S, Vt = np.linalg.svd(H)
    d = np.linalg.det(Vt.T @ U.T)
    D = np.diag([1, 1, d])
    R = Vt.T @ D @ U.T

    # Optimal scale
    scale = np.trace(R @ H) / np.trace(src_c.T @ src_c)

    # Translation
    t = mu_dst - scale * R @ mu_src

    return scale, R, t


def apply_similarity_to_pose(qw, qx, qy, qz, tx, ty, tz, scale, R_sim, t_sim):
    """Apply similarity transform to a COLMAP cam-from-world pose.

    Given: cam-from-world as (R_c, t_c) where p_cam = R_c @ p_world + t_c
    Similarity: p_world_new = s * R_s @ p_world_old + t_s
    So: p_world_old = R_s^T @ (p_world_new - t_s) / s
    New cam-from-world: p_cam = R_c @ [R_s^T @ (p_new - t_s) / s] + t_c
                              = (R_c @ R_s^T / s) @ p_new + (t_c - R_c @ R_s^T @ t_s / s)
    """
    R_c = Rotation.from_quat([qx, qy, qz, qw]).as_matrix()
    t_c = np.array([tx, ty, tz])

    R_new = R_c @ R_sim.T / scale
    t_new = t_c - R_new @ t_sim

    # Re-normalize rotation (R_new may not be exactly orthogonal after scaling)
    U, _, Vt = np.linalg.svd(R_new)
    R_new = U @ Vt

    q = Rotation.from_matrix(R_new).as_quat()  # [qx, qy, qz, qw]
    return q[3], q[0], q[1], q[2], t_new[0], t_new[1], t_new[2]


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <original_images.txt> <refined_images.txt> <output_images.txt>")
        sys.exit(1)

    orig_path, refined_path, output_path = sys.argv[1], sys.argv[2], sys.argv[3]

    orig_poses, _ = parse_images_txt(orig_path)
    refined_poses, refined_lines = parse_images_txt(refined_path)

    # Find common images
    common = sorted(set(orig_poses) & set(refined_poses))
    if len(common) < 3:
        print(f"ERROR: Only {len(common)} common images — need at least 3 for Procrustes")
        sys.exit(1)

    # Extract camera positions
    src_pts = np.array([cam_position(*refined_poses[n]) for n in common])
    dst_pts = np.array([cam_position(*orig_poses[n]) for n in common])

    # Compute similarity transform
    scale, R_sim, t_sim = procrustes(src_pts, dst_pts)

    # Verify alignment
    aligned = scale * (R_sim @ src_pts.T).T + t_sim
    errors = np.linalg.norm(aligned - dst_pts, axis=1)
    print(f"Procrustes alignment: {len(common)} common images")
    print(f"  Scale: {scale:.4f}")
    print(f"  Rotation angle: {np.degrees(np.arccos(np.clip((np.trace(R_sim) - 1) / 2, -1, 1))):.2f} deg")
    print(f"  Translation: [{t_sim[0]:.3f}, {t_sim[1]:.3f}, {t_sim[2]:.3f}] m")
    print(f"  Residual — Mean: {errors.mean()*100:.2f} cm | Max: {errors.max()*100:.2f} cm")

    # Apply transform to all refined poses and write output
    os.makedirs(os.path.dirname(output_path) or '.', exist_ok=True)
    with open(output_path, 'w') as out:
        for line in refined_lines:
            if line.startswith('#') or line.strip() == '':
                out.write(line)
                continue
            parts = line.strip().split()
            if len(parts) >= 10 and parts[9].endswith('.jpg'):
                img_id = parts[0]
                qw, qx, qy, qz = [float(x) for x in parts[1:5]]
                tx, ty, tz = [float(x) for x in parts[5:8]]
                cam_id = parts[8]
                name = parts[9]

                qw2, qx2, qy2, qz2, tx2, ty2, tz2 = apply_similarity_to_pose(
                    qw, qx, qy, qz, tx, ty, tz, scale, R_sim, t_sim)

                out.write(f"{img_id} {qw2:.17e} {qx2:.17e} {qy2:.17e} {qz2:.17e} "
                          f"{tx2:.17e} {ty2:.17e} {tz2:.17e} {cam_id} {name}\n")
            else:
                # Points2D line — pass through unchanged
                out.write(line)

    total = sum(1 for n, p in refined_poses.items())
    print(f"  Wrote {total} aligned poses to {output_path}")


if __name__ == '__main__':
    main()
