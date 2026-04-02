"""Convert ARKit scan data to COLMAP format for OpenMVS TextureMesh.

Adapted from prepare_openmvs_input.py for the new unified capture format
(no separate panoramic directory — all frames in keyframes/).

Pipeline:
  1. Parse metadata.json + per-frame JSONs
  2. Strip PLY classification property
  3. Decimate mesh to target face count (5K default)
  4. Convert ARKit poses → COLMAP format (flip Y/Z)
  5. Output: sparse/ (COLMAP text), images/ (JPEGs), mesh_clean.ply
"""

import json
import os
import shutil
import struct
import sys
import numpy as np
from pathlib import Path


SCAN_DIR = Path(__file__).parent / "scan_new"
WORK_DIR = Path(__file__).parent / "openmvs_work_new"
TARGET_FACES = 20000


def rotation_matrix_to_quaternion(R):
    """Convert 3x3 rotation matrix to quaternion (w, x, y, z)."""
    trace = R[0, 0] + R[1, 1] + R[2, 2]
    if trace > 0:
        s = 0.5 / np.sqrt(trace + 1.0)
        w = 0.25 / s
        x = (R[2, 1] - R[1, 2]) * s
        y = (R[0, 2] - R[2, 0]) * s
        z = (R[1, 0] - R[0, 1]) * s
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        s = 2.0 * np.sqrt(1.0 + R[0, 0] - R[1, 1] - R[2, 2])
        w = (R[2, 1] - R[1, 2]) / s
        x = 0.25 * s
        y = (R[0, 1] + R[1, 0]) / s
        z = (R[0, 2] + R[2, 0]) / s
    elif R[1, 1] > R[2, 2]:
        s = 2.0 * np.sqrt(1.0 + R[1, 1] - R[0, 0] - R[2, 2])
        w = (R[0, 2] - R[2, 0]) / s
        x = (R[0, 1] + R[1, 0]) / s
        y = 0.25 * s
        z = (R[1, 2] + R[2, 1]) / s
    else:
        s = 2.0 * np.sqrt(1.0 + R[2, 2] - R[0, 0] - R[1, 1])
        w = (R[1, 0] - R[0, 1]) / s
        x = (R[0, 2] + R[2, 0]) / s
        y = (R[1, 2] + R[2, 1]) / s
        z = 0.25 * s
    return w, x, y, z


def strip_and_decimate_ply(src_ply, dst_ply, target_faces):
    """Strip ARKit classification property and decimate to target face count."""
    import trimesh

    # Load with trimesh (handles classification property stripping automatically)
    mesh = trimesh.load(str(src_ply), process=False)
    print(f"  Original: {len(mesh.vertices)} vertices, {len(mesh.faces)} faces")

    if len(mesh.faces) > target_faces:
        mesh = mesh.simplify_quadric_decimation(face_count=target_faces)
        print(f"  Decimated: {len(mesh.vertices)} vertices, {len(mesh.faces)} faces")

    mesh.export(str(dst_ply))
    print(f"  Saved: {dst_ply}")


def main():
    with open(SCAN_DIR / "metadata.json") as f:
        meta = json.load(f)

    intrinsics = meta.get("camera_intrinsics", {})
    fx = intrinsics.get("fx", 1000.0)
    fy = intrinsics.get("fy", 1000.0)
    cx = intrinsics.get("cx", 960.0)
    cy = intrinsics.get("cy", 540.0)
    img_w = meta.get("image_resolution", {}).get("width", 1920)
    img_h = meta.get("image_resolution", {}).get("height", 1440)

    print(f"Camera: PINHOLE {img_w}x{img_h} fx={fx:.1f} fy={fy:.1f} cx={cx:.1f} cy={cy:.1f}")

    # Create output directories
    sparse_dir = WORK_DIR / "sparse"
    images_dir = WORK_DIR / "images"
    for d in [sparse_dir, images_dir]:
        d.mkdir(parents=True, exist_ok=True)

    # cameras.txt
    with open(sparse_dir / "cameras.txt", "w") as f:
        f.write("# Camera list with one line of data per camera:\n")
        f.write("# CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n")
        f.write(f"1 PINHOLE {img_w} {img_h} {fx} {fy} {cx} {cy}\n")

    # Collect all keyframes
    entries = []
    for entry in meta.get("keyframes", []):
        jpg_name = entry["filename"]
        json_path = SCAN_DIR / "keyframes" / jpg_name.replace(".jpg", ".json")
        jpg_path = SCAN_DIR / "keyframes" / jpg_name
        if json_path.exists() and jpg_path.exists():
            entries.append((jpg_name, json_path, jpg_path))

    print(f"Found {len(entries)} keyframes with existing JPGs")

    # Copy images
    print("Copying images...")
    for jpg_name, _, jpg_path in entries:
        dst = images_dir / jpg_name
        if not dst.exists():
            shutil.copy2(jpg_path, dst)

    # Flip matrix: ARKit → COLMAP camera space
    flip = np.diag([1.0, -1.0, -1.0])

    # images.txt
    img_id = 0
    with open(sparse_dir / "images.txt", "w") as f:
        f.write("# IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n")
        f.write("# POINTS2D[] as (X, Y, POINT3D_ID)\n")

        for jpg_name, json_path, _ in entries:
            with open(json_path) as jf:
                frame_meta = json.load(jf)

            transform_flat = frame_meta.get("camera_transform", [])
            if len(transform_flat) != 16:
                continue

            # ARKit: world-from-camera, column-major 4x4
            T_w_from_c = np.array(transform_flat, dtype=np.float64).reshape(4, 4, order='F')
            T_c_from_w = np.linalg.inv(T_w_from_c)

            # Convert to COLMAP convention
            R = flip @ T_c_from_w[:3, :3]
            t = flip @ T_c_from_w[:3, 3]
            qw, qx, qy, qz = rotation_matrix_to_quaternion(R)

            img_id += 1
            f.write(f"{img_id} {qw} {qx} {qy} {qz} {t[0]} {t[1]} {t[2]} 1 {jpg_name}\n")
            f.write("\n")

    print(f"images.txt: {img_id} images written")

    # points3D.txt — empty
    with open(sparse_dir / "points3D.txt", "w") as f:
        f.write("# 3D point list (empty — using mesh instead)\n")

    # Strip classification and decimate mesh
    print(f"\nProcessing mesh (target: {TARGET_FACES} faces)...")
    strip_and_decimate_ply(
        SCAN_DIR / "mesh.ply",
        WORK_DIR / "mesh_clean.ply",
        TARGET_FACES,
    )

    # Verification
    entry = entries[0]
    with open(entry[1]) as jf:
        fm = json.load(jf)
    T = np.array(fm['camera_transform']).reshape(4, 4, order='F')
    look_dir = -T[:3, 2]
    cam_pos = T[:3, 3]
    front_pt = cam_pos + look_dir * 3.0
    T_inv = np.linalg.inv(T)
    R_test = flip @ T_inv[:3, :3]
    t_test = flip @ T_inv[:3, 3]
    cam_pt = R_test @ front_pt + t_test
    px = fx * cam_pt[0] / cam_pt[2] + cx
    py = fy * cam_pt[1] / cam_pt[2] + cy
    print(f"\nVerification: point 3m ahead of camera 1 → px={px:.0f}, py={py:.0f} "
          f"(should be ~{img_w//2}, {img_h//2})")

    # Compute camera centroid for viewer positioning
    positions = []
    for _, json_path, _ in entries:
        with open(json_path) as jf:
            fm = json.load(jf)
        tf = fm.get("camera_transform", [])
        if len(tf) == 16:
            T = np.array(tf).reshape(4, 4, order='F')
            positions.append(T[:3, 3])
    centroid = np.mean(positions, axis=0)
    print(f"\nCamera centroid (viewer position): x={centroid[0]:.3f}, y={centroid[1]:.3f}, z={centroid[2]:.3f}")
    print("Done!")


if __name__ == "__main__":
    main()
