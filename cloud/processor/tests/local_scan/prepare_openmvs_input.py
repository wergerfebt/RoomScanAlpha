"""Convert ARKit scan data to COLMAP format for OpenMVS TextureMesh.

Key convention conversion:
  ARKit camera: X-right, Y-up, looks along -Z
  COLMAP camera: X-right, Y-down, looks along +Z

  To convert camera-from-world: multiply by diag(1,-1,-1) on the left,
  which flips the Y and Z axes in camera space.

  The mesh stays in ARKit world coordinates (unchanged).
"""

import json
import os
import shutil
import numpy as np
from pathlib import Path

SCAN_DIR = Path(__file__).parent / "scan_1774895423"
WORK_DIR = Path(__file__).parent / "openmvs_work"


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

    # Collect keyframes — ONLY those where the source JPG actually exists
    entries = []

    for entry in meta.get("keyframes", []):
        jpg_name = entry["filename"]
        json_path = SCAN_DIR / "keyframes" / jpg_name.replace(".jpg", ".json")
        jpg_path = SCAN_DIR / "keyframes" / jpg_name
        if json_path.exists() and jpg_path.exists():
            unique_name = f"walk_{jpg_name}"
            entries.append((unique_name, json_path, jpg_path))

    seen_pano = set()
    for entry in meta.get("panoramic_keyframes", []):
        jpg_name = entry["filename"]
        if jpg_name in seen_pano:
            continue  # skip duplicate entries for same image
        seen_pano.add(jpg_name)
        json_path = SCAN_DIR / "panoramic" / jpg_name.replace(".jpg", ".json")
        jpg_path = SCAN_DIR / "panoramic" / jpg_name
        if json_path.exists() and jpg_path.exists():
            unique_name = f"pano_{jpg_name}"
            entries.append((unique_name, json_path, jpg_path))

    print(f"Found {len(entries)} keyframes with existing JPGs")

    # Copy images (not symlinks — Docker can't follow host symlinks)
    for unique_name, _, jpg_path in entries:
        dst = images_dir / unique_name
        if not dst.exists():
            shutil.copy2(jpg_path, dst)

    # Flip matrix: converts ARKit camera space → COLMAP camera space
    # ARKit: X-right, Y-up, -Z forward
    # COLMAP: X-right, Y-down, +Z forward
    flip = np.diag([1.0, -1.0, -1.0])

    # images.txt
    img_id = 0
    with open(sparse_dir / "images.txt", "w") as f:
        f.write("# IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n")
        f.write("# POINTS2D[] as (X, Y, POINT3D_ID)\n")

        for unique_name, json_path, _ in entries:
            with open(json_path) as jf:
                frame_meta = json.load(jf)

            transform_flat = frame_meta.get("camera_transform", [])
            if len(transform_flat) != 16:
                continue

            # ARKit: world-from-camera, column-major 4x4
            T_w_from_c = np.array(transform_flat, dtype=np.float64).reshape(4, 4, order='F')

            # camera-from-world (ARKit convention)
            T_c_from_w = np.linalg.inv(T_w_from_c)

            # Convert to COLMAP convention by flipping Y and Z in camera space
            R = flip @ T_c_from_w[:3, :3]
            t = flip @ T_c_from_w[:3, 3]

            qw, qx, qy, qz = rotation_matrix_to_quaternion(R)

            img_id += 1
            f.write(f"{img_id} {qw} {qx} {qy} {qz} {t[0]} {t[1]} {t[2]} 1 {unique_name}\n")
            f.write("\n")

    print(f"images.txt: {img_id} images written")

    # points3D.txt — empty
    with open(sparse_dir / "points3D.txt", "w") as f:
        f.write("# 3D point list (empty — using mesh instead)\n")

    # Copy clean mesh (stripped of classification property)
    print(f"Sparse reconstruction: {sparse_dir}")

    # Verification: project a point in front of camera 1 and check it hits image center
    entry = entries[0]
    with open(entry[1]) as jf:
        fm = json.load(jf)
    T = np.array(fm['camera_transform']).reshape(4, 4, order='F')
    look_dir = -T[:3, 2]  # ARKit: camera looks along -Z
    cam_pos = T[:3, 3]
    front_pt = cam_pos + look_dir * 3.0

    T_inv = np.linalg.inv(T)
    R_test = flip @ T_inv[:3, :3]
    t_test = flip @ T_inv[:3, 3]
    cam_pt = R_test @ front_pt + t_test
    px = fx * cam_pt[0] / cam_pt[2] + cx
    py = fy * cam_pt[1] / cam_pt[2] + cy
    print(f"Verification: point 3m ahead of camera 1 → px={px:.0f}, py={py:.0f} "
          f"(should be ~{img_w//2}, {img_h//2})")


if __name__ == "__main__":
    main()
