"""OpenMVS TextureMesh pipeline for cloud processing.

Replaces the per-surface WTA texture projection with OpenMVS's MRF-based
per-face camera selection + global/local seam leveling.

Pipeline:
  1. Convert ARKit scan data → COLMAP sparse format
  2. Run InterfaceCOLMAP (COLMAP → MVS)
  3. Run TextureMesh (MRF view selection + seam leveling)
  4. Fix MTL transparency bug
  5. Return paths to output files

Requires: InterfaceCOLMAP and TextureMesh binaries in PATH
(baked into the Docker image via multi-stage build).
"""

import json
import os
import shutil
import subprocess
import tempfile

import numpy as np
import trimesh


# ARKit → COLMAP coordinate flip: diag(1, -1, -1)
_FLIP = np.diag([1.0, -1.0, -1.0])


def _rotation_matrix_to_quaternion(R: np.ndarray) -> tuple:
    """Convert 3×3 rotation matrix to quaternion (w, x, y, z)."""
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


def prepare_colmap_input(scan_root: str, metadata: dict, work_dir: str) -> int:
    """Convert ARKit scan data to COLMAP sparse format.

    Args:
        scan_root: Path to extracted scan directory (keyframes/, mesh.ply, metadata.json)
        metadata: Parsed metadata.json dict
        work_dir: Output directory for COLMAP format (sparse/, images/, mesh_clean.ply)

    Returns:
        Number of keyframes written.
    """
    intrinsics = metadata.get("camera_intrinsics", {})
    fx = intrinsics.get("fx", 1428.0)
    fy = intrinsics.get("fy", 1428.0)
    cx = intrinsics.get("cx", 960.0)
    cy = intrinsics.get("cy", 720.0)
    img_w = metadata.get("image_resolution", {}).get("width", 1920)
    img_h = metadata.get("image_resolution", {}).get("height", 1440)

    sparse_dir = os.path.join(work_dir, "sparse")
    images_dir = os.path.join(work_dir, "images")
    os.makedirs(sparse_dir, exist_ok=True)
    os.makedirs(images_dir, exist_ok=True)

    # cameras.txt
    with open(os.path.join(sparse_dir, "cameras.txt"), "w") as f:
        f.write("# Camera list with one line of data per camera:\n")
        f.write("# CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n")
        f.write(f"1 PINHOLE {img_w} {img_h} {fx} {fy} {cx} {cy}\n")

    # Collect keyframes from metadata manifest
    keyframes = metadata.get("keyframes", [])
    keyframe_dir = os.path.join(scan_root, "keyframes")

    img_id = 0
    images_lines = []

    for entry in keyframes:
        jpg_name = entry["filename"]
        json_name = jpg_name.replace(".jpg", ".json")
        jpg_path = os.path.join(keyframe_dir, jpg_name)
        json_path = os.path.join(keyframe_dir, json_name)

        if not os.path.exists(jpg_path) or not os.path.exists(json_path):
            continue

        with open(json_path) as jf:
            frame_meta = json.load(jf)

        transform_flat = frame_meta.get("camera_transform", [])
        if len(transform_flat) != 16:
            continue

        # ARKit: world-from-camera, column-major 4×4
        T_w_from_c = np.array(transform_flat, dtype=np.float64).reshape(4, 4, order="F")
        T_c_from_w = np.linalg.inv(T_w_from_c)

        # Flip to COLMAP convention
        R = _FLIP @ T_c_from_w[:3, :3]
        t = _FLIP @ T_c_from_w[:3, 3]
        qw, qx, qy, qz = _rotation_matrix_to_quaternion(R)

        img_id += 1
        images_lines.append(
            f"{img_id} {qw} {qx} {qy} {qz} {t[0]} {t[1]} {t[2]} 1 {jpg_name}\n\n"
        )

        # Symlink image (avoid copying ~500KB × 168 = 84MB)
        dst = os.path.join(images_dir, jpg_name)
        if not os.path.exists(dst):
            os.symlink(jpg_path, dst)

    # images.txt
    with open(os.path.join(sparse_dir, "images.txt"), "w") as f:
        f.write("# IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n")
        f.write("# POINTS2D[] as (X, Y, POINT3D_ID)\n")
        f.writelines(images_lines)

    # points3D.txt (empty — using mesh instead)
    with open(os.path.join(sparse_dir, "points3D.txt"), "w") as f:
        f.write("# 3D point list (empty — using mesh instead)\n")

    print(f"[OpenMVS] Prepared COLMAP input: {img_id} images, "
          f"PINHOLE {img_w}×{img_h} fx={fx:.1f}")
    return img_id


def strip_and_decimate_ply(
    src_ply: str, dst_ply: str, target_faces: int = 50000
) -> None:
    """Strip ARKit classification and decimate to target face count."""
    mesh = trimesh.load(src_ply, process=False)
    original_faces = len(mesh.faces)
    if original_faces > target_faces:
        mesh = mesh.simplify_quadric_decimation(face_count=target_faces)
    mesh.export(dst_ply)
    print(f"[OpenMVS] Mesh: {original_faces} → {len(mesh.faces)} faces")


def _run_interface_colmap(work_dir: str) -> str:
    """Run InterfaceCOLMAP once. Returns path to scene.mvs."""
    scene_mvs = os.path.join(work_dir, "scene.mvs")
    print("[OpenMVS] Running InterfaceCOLMAP...")
    subprocess.run(
        [
            "InterfaceCOLMAP",
            "-i", work_dir,
            "--image-folder", os.path.join(work_dir, "images"),
            "-o", scene_mvs,
            "-w", work_dir,
        ],
        check=True,
        timeout=60,
        capture_output=True,
        text=True,
    )
    return scene_mvs


def _run_texture_mesh(
    scene_mvs: str,
    mesh_ply: str,
    out_dir: str,
    prefix: str = "textured",
    smoothness: float = 1.0,
    max_texture_size: int = 8192,
    timeout: int = 180,
) -> dict:
    """Run TextureMesh for one resolution level.

    Returns dict with paths: {"obj", "mtl", "atlas"}
    """
    os.makedirs(out_dir, exist_ok=True)

    # TextureMesh needs -w pointing to where scene.mvs can find images
    # (the parent work_dir), but outputs go to out_dir via -o prefix
    scene_dir = os.path.dirname(scene_mvs)

    print(f"[OpenMVS] TextureMesh [{prefix}] smoothness={smoothness}...")
    result = subprocess.run(
        [
            "TextureMesh",
            scene_mvs,
            "--mesh-file", mesh_ply,
            "--export-type", "obj",
            "-w", scene_dir,
            "-o", os.path.join(out_dir, f"{prefix}.mvs"),
            "--resolution-level", "1",
            "--cost-smoothness-ratio", str(smoothness),
            "--global-seam-leveling", "1",
            "--local-seam-leveling", "1",
            "--max-texture-size", str(max_texture_size),
        ],
        check=True,
        timeout=timeout,
        capture_output=True,
        text=True,
    )
    print(f"[OpenMVS] [{prefix}] done: {result.stdout[-300:]}")

    # Fix MTL transparency bug
    mtl_path = os.path.join(out_dir, f"{prefix}.mtl")
    if os.path.exists(mtl_path):
        with open(mtl_path, "r") as f:
            content = f.read()
        content = content.replace("Tr 1.000000", "Tr 0.000000")
        with open(mtl_path, "w") as f:
            f.write(content)

    obj_path = os.path.join(out_dir, f"{prefix}.obj")
    atlas_paths = sorted([
        os.path.join(out_dir, f) for f in os.listdir(out_dir)
        if f.startswith(f"{prefix}_material") and f.endswith(".jpg")
    ])

    if not os.path.exists(obj_path):
        raise RuntimeError(f"TextureMesh did not produce {prefix}.obj")
    if not atlas_paths:
        raise RuntimeError(f"TextureMesh did not produce atlas for {prefix}")

    obj_mb = os.path.getsize(obj_path) / 1024 / 1024
    print(f"[OpenMVS] [{prefix}] OBJ: {obj_mb:.1f}MB, {len(atlas_paths)} atlas(es)")

    result = {"obj": obj_path, "mtl": mtl_path, "atlas": atlas_paths[0]}
    # Include additional atlases if OpenMVS split into multiple textures
    for i, ap in enumerate(atlas_paths[1:], 1):
        result[f"atlas_{i}"] = ap
    return result


# Resolution levels: name → target face count (0 = full mesh, no decimation)
RESOLUTION_LEVELS = {
    "preview": 50000,
    "standard": 300000,
}


def texture_scan(scan_root: str, metadata: dict, preview_faces: int = 0,
                  levels: list[str] | None = None) -> dict:
    """Top-level entry point: texture a scan at specified resolutions.

    InterfaceCOLMAP runs once; TextureMesh runs per level.

    Args:
        preview_faces: override preview decimation target. If 0, uses default
            (50K). Set higher for merged meshes to avoid fragmentation from
            decimating overlapping geometry.
        levels: which resolution levels to generate. Defaults to ["preview"]
            for fast coverage-only processing. Pass ["preview", "standard"]
            for full web viewer quality.

    Returns:
        Dict with output file paths per resolution:
        {"obj": ..., "mtl": ..., "atlas": ...,
         "obj_standard": ..., "mtl_standard": ..., "atlas_standard": ...}
    """
    if levels is None:
        levels = ["preview"]

    work_dir = os.path.join(scan_root, "openmvs_work")
    os.makedirs(work_dir, exist_ok=True)

    # Apply preview override
    resolution_levels = {k: v for k, v in RESOLUTION_LEVELS.items() if k in levels}
    if preview_faces > 0 and "preview" in resolution_levels:
        resolution_levels["preview"] = preview_faces

    # 1. Prepare COLMAP format (once)
    n_images = prepare_colmap_input(scan_root, metadata, work_dir)
    if n_images < 2:
        raise RuntimeError(f"Only {n_images} keyframes — need at least 2 for texturing")

    # 2. Run InterfaceCOLMAP (once — scene.mvs is mesh-independent)
    scene_mvs = _run_interface_colmap(work_dir)

    # 3. Strip classification from source mesh
    src_ply = os.path.join(scan_root, "mesh.ply")
    stripped_ply = os.path.join(work_dir, "mesh_stripped.ply")
    src_mesh = trimesh.load(src_ply, process=False)
    src_mesh.export(stripped_ply)
    original_faces = len(src_mesh.faces)
    print(f"[OpenMVS] Stripped mesh: {original_faces} faces")

    # 4. Generate each resolution level
    result = {}
    for level_name, target_faces in resolution_levels.items():
        level_dir = os.path.join(work_dir, level_name)
        mesh_ply = os.path.join(level_dir, "mesh.ply")
        os.makedirs(level_dir, exist_ok=True)

        # Decimate (0 = full mesh)
        if target_faces > 0 and original_faces > target_faces:
            # Clean mesh topology before decimation — merged scans have overlapping
            # geometry from supplemental merge that creates non-manifold edges.
            # Without cleanup, quadric decimation tears holes at overlap boundaries.
            dec_input = src_mesh.copy()
            dec_input.merge_vertices()

            # Remove degenerate faces (zero area)
            nondeg_mask = dec_input.nondegenerate_faces()
            if not nondeg_mask.all():
                dec_input.update_faces(nondeg_mask)

            # Remove duplicate faces (same vertices, any winding)
            sorted_faces = np.sort(dec_input.faces, axis=1)
            _, unique_idx = np.unique(sorted_faces, axis=0, return_index=True)
            if len(unique_idx) < len(dec_input.faces):
                dup_mask = np.zeros(len(dec_input.faces), dtype=bool)
                dup_mask[unique_idx] = True
                dec_input.update_faces(dup_mask)

            cleaned = len(dec_input.faces)
            if cleaned != original_faces:
                print(f"[OpenMVS] [{level_name}] Cleaned: {original_faces} → {cleaned} faces before decimation")
            dec = dec_input.simplify_quadric_decimation(face_count=target_faces)
            dec.export(mesh_ply)
            print(f"[OpenMVS] [{level_name}] Decimated: {cleaned} → {len(dec.faces)} faces")
        else:
            src_mesh.export(mesh_ply)
            print(f"[OpenMVS] [{level_name}] Full mesh: {original_faces} faces")

        atlas_size = 8192
        level_timeout = 600 if level_name == "standard" else 300
        level_result = _run_texture_mesh(
            scene_mvs, mesh_ply, level_dir, prefix="textured",
            max_texture_size=atlas_size,
            timeout=level_timeout,
        )

        if level_name == "preview":
            # Preview is the default (keys without suffix)
            result["obj"] = level_result["obj"]
            result["mtl"] = level_result["mtl"]
            result["atlas"] = level_result["atlas"]
        else:
            # Other levels get suffixed keys
            for k, v in level_result.items():
                result[f"{k}_{level_name}"] = v

    return result
