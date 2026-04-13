"""
Cloud-side frame selection for HEVC capture pipeline.

Selects the best ~1500 frames from 2000-4000+ HEVC-extracted frames for
OpenMVS TextureMesh. Two-phase approach:
  1. Quality filter: remove bottom 20% by Laplacian sharpness
  2. Greedy set-cover: maximize mesh surface coverage

Runs after extract_frames_from_hevc() and before prepare_colmap_input().
"""

import json
import os
from typing import Optional

import numpy as np
from PIL import Image
from scipy.ndimage import convolve
import trimesh


# Visibility thresholds matching _check_face_coverage() in main.py
MIN_DISTANCE = 0.2
MAX_DISTANCE = 5.0
MIN_ANGLE_WALL = 0.1        # ~84° from perpendicular
MIN_ANGLE_FLOOR_CEIL = 0.02  # ~89°
IMAGE_MARGIN = 50.0

# Laplacian kernel for sharpness scoring
LAPLACIAN_KERNEL = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]], dtype=np.float64)

# Sharpness scoring resolution (downscale for speed)
SHARPNESS_WIDTH = 480
SHARPNESS_HEIGHT = 360

# Mesh decimation target for visibility checks (approximate is fine)
VISIBILITY_MESH_FACES = 10_000

# Bottom percentage of frames to cull by sharpness
SHARPNESS_CULL_PERCENT = 20


def select_frames(
    scan_root: str,
    metadata: dict,
    mesh_ply_path: str,
    target_count: int = 1500,
) -> list[dict]:
    """Select optimal frames for texturing from a larger HEVC-extracted set.

    Args:
        scan_root: Path to extracted scan directory with keyframes/ and depth/.
        metadata: Parsed metadata dict with "keyframes" and "camera_intrinsics".
        mesh_ply_path: Path to the mesh PLY file for coverage computation.
        target_count: Maximum number of frames to select.

    Returns:
        Filtered keyframes list in the same format as metadata["keyframes"].
    """
    keyframes = metadata.get("keyframes", [])
    n_total = len(keyframes)

    if n_total <= target_count:
        return keyframes

    print(f"[FrameSelection] Starting selection: {n_total} frames → target {target_count}")

    # Step 1: Load camera poses
    cameras, valid_indices = _load_camera_poses(scan_root, metadata)
    print(f"[FrameSelection] Loaded {len(cameras)} valid camera poses")

    if len(cameras) == 0:
        print("[FrameSelection] No valid cameras — returning all frames")
        return keyframes

    # Step 2: Sharpness filtering
    min_keep = int(target_count * 1.5)
    sharp_indices = _filter_by_sharpness(
        scan_root, keyframes, valid_indices,
        cull_percent=SHARPNESS_CULL_PERCENT,
        min_keep=min_keep,
    )
    print(f"[FrameSelection] After sharpness filter: {len(sharp_indices)} frames")

    if len(sharp_indices) <= target_count:
        return [keyframes[i] for i in sorted(sharp_indices)]

    # Step 3: Load mesh for visibility
    centroids, normals, is_floor_ceil = _load_mesh_for_visibility(mesh_ply_path)
    print(f"[FrameSelection] Mesh loaded: {len(centroids)} faces for visibility checks")

    # Step 4: Build visibility matrix
    # Map sharp_indices back to camera data
    sharp_cam_indices = [valid_indices.index(i) for i in sharp_indices if i in valid_indices]
    sharp_cameras = [cameras[ci] for ci in sharp_cam_indices]
    sharp_frame_indices = [valid_indices[ci] for ci in sharp_cam_indices]

    visibility = _build_visibility_matrix(sharp_cameras, centroids, normals, is_floor_ceil)
    print(f"[FrameSelection] Visibility matrix: {visibility.shape[0]} frames × {visibility.shape[1]} faces")

    # Step 5: Greedy set-cover selection
    selected_local = _greedy_set_cover(visibility, target_count)
    coverage = visibility[selected_local].any(axis=0).sum()
    total_coverable = visibility.any(axis=0).sum()
    print(f"[FrameSelection] Greedy selected {len(selected_local)} frames, "
          f"covering {coverage}/{total_coverable} faces "
          f"({coverage / max(total_coverable, 1) * 100:.1f}%)")

    # Step 6: Fill to target with temporal spacing if greedy stopped early
    if len(selected_local) < target_count:
        selected_local = _fill_with_spacing(
            selected_local, len(sharp_frame_indices), target_count
        )
        print(f"[FrameSelection] After fill: {len(selected_local)} frames")

    # Step 7: Map back to original keyframe indices and return
    selected_global = sorted(sharp_frame_indices[i] for i in selected_local)
    result = [keyframes[i] for i in selected_global]
    print(f"[FrameSelection] Final selection: {len(result)} frames from {n_total} total")
    return result


def _load_camera_poses(
    scan_root: str, metadata: dict
) -> tuple[list[dict], list[int]]:
    """Load camera poses from per-frame JSONs. Returns (cameras, valid_keyframe_indices)."""
    intrinsics = metadata.get("camera_intrinsics", {})
    fx = intrinsics.get("fx", 0)
    fy = intrinsics.get("fy", 0)
    cx = intrinsics.get("cx", 0)
    cy = intrinsics.get("cy", 0)
    img_res = metadata.get("image_resolution", {})
    img_w = img_res.get("width", 1920)
    img_h = img_res.get("height", 1440)

    keyframes_dir = os.path.join(scan_root, "keyframes")
    cameras = []
    valid_indices = []

    for i, kf in enumerate(metadata.get("keyframes", [])):
        json_path = os.path.join(keyframes_dir, kf["filename"].replace(".jpg", ".json"))
        if not os.path.exists(json_path):
            continue
        with open(json_path) as f:
            frame_data = json.load(f)
        transform = frame_data.get("camera_transform")
        if not transform or len(transform) != 16:
            continue

        T = np.array(transform, dtype=np.float64).reshape(4, 4, order="F")
        cam_pos = T[:3, 3].copy()
        cam_from_world = np.linalg.inv(T)

        cameras.append({
            "position": cam_pos,
            "cam_from_world": cam_from_world,
            "fx": fx, "fy": fy, "cx": cx, "cy": cy,
            "img_w": img_w, "img_h": img_h,
        })
        valid_indices.append(i)

    return cameras, valid_indices


def _filter_by_sharpness(
    scan_root: str,
    keyframes: list[dict],
    valid_indices: list[int],
    cull_percent: int = 20,
    min_keep: int = 2250,
) -> list[int]:
    """Score frames by Laplacian sharpness, remove bottom cull_percent%.

    Processes one image at a time to avoid memory issues.
    Returns list of keyframe indices that passed the filter.
    """
    keyframes_dir = os.path.join(scan_root, "keyframes")
    scores = []

    for idx in valid_indices:
        jpg_path = os.path.join(keyframes_dir, keyframes[idx]["filename"])
        score = _compute_sharpness(jpg_path)
        scores.append((idx, score))

    if not scores:
        return valid_indices

    # Compute threshold
    all_scores = np.array([s for _, s in scores])
    threshold = np.percentile(all_scores, cull_percent)

    # Sort by score descending, keep at least min_keep
    sorted_scores = sorted(scores, key=lambda x: x[1], reverse=True)
    kept = []
    for idx, score in sorted_scores:
        if len(kept) >= min_keep and score < threshold:
            continue
        kept.append(idx)

    return kept


def _compute_sharpness(jpg_path: str) -> float:
    """Compute Laplacian variance sharpness score for a single JPEG."""
    try:
        img = Image.open(jpg_path).convert("L")
        img = img.resize((SHARPNESS_WIDTH, SHARPNESS_HEIGHT), Image.BILINEAR)
        arr = np.array(img, dtype=np.float64)
        lap = convolve(arr, LAPLACIAN_KERNEL)
        return float(lap.var())
    except Exception:
        return 0.0


def _load_mesh_for_visibility(
    mesh_ply_path: str,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Load mesh, decimate for fast visibility, return centroids + normals.

    Returns:
        centroids: (N, 3) face centroids
        normals: (N, 3) face normals
        is_floor_ceil: (N,) boolean mask for floor/ceiling faces
    """
    mesh = trimesh.load(mesh_ply_path, process=False)

    if len(mesh.faces) > VISIBILITY_MESH_FACES:
        mesh = mesh.simplify_quadric_decimation(face_count=VISIBILITY_MESH_FACES)

    vertices = np.array(mesh.vertices, dtype=np.float64)
    faces = np.array(mesh.faces)
    face_normals = np.array(mesh.face_normals, dtype=np.float64)

    v0 = vertices[faces[:, 0]]
    v1 = vertices[faces[:, 1]]
    v2 = vertices[faces[:, 2]]
    centroids = (v0 + v1 + v2) / 3.0

    is_floor_ceil = np.abs(face_normals[:, 1]) > 0.7

    return centroids, face_normals, is_floor_ceil


def _build_visibility_matrix(
    cameras: list[dict],
    centroids: np.ndarray,
    normals: np.ndarray,
    is_floor_ceil: np.ndarray,
) -> np.ndarray:
    """Build boolean visibility matrix: (n_cameras, n_faces).

    Vectorized per-camera: checks distance, viewing angle, and projection
    bounds for all faces simultaneously.
    """
    n_cameras = len(cameras)
    n_faces = len(centroids)
    visibility = np.zeros((n_cameras, n_faces), dtype=np.bool_)

    # Pre-compute angle thresholds per face
    angle_thresholds = np.where(is_floor_ceil, MIN_ANGLE_FLOOR_CEIL, MIN_ANGLE_WALL)

    for ci, cam in enumerate(cameras):
        pos = cam["position"]
        cfw = cam["cam_from_world"]
        fx, fy = cam["fx"], cam["fy"]
        cx, cy = cam["cx"], cam["cy"]
        img_w, img_h = cam["img_w"], cam["img_h"]

        # Vector from centroid to camera
        to_cam = pos - centroids  # (N, 3)
        dists = np.linalg.norm(to_cam, axis=1)  # (N,)

        # Distance filter
        valid_dist = (dists > MIN_DISTANCE) & (dists < MAX_DISTANCE)

        # Viewing angle filter
        to_cam_norm = to_cam / np.maximum(dists[:, None], 1e-8)
        angle_dots = (normals * to_cam_norm).sum(axis=1)
        valid_angle = angle_dots > angle_thresholds

        # Combined pre-filter to avoid unnecessary projection
        pre_valid = valid_dist & valid_angle
        if not pre_valid.any():
            continue

        # Project centroids into camera image (only for pre-valid faces)
        # cam_pt = cfw[:3,:3] @ centroid + cfw[:3,3]
        R = cfw[:3, :3]
        t = cfw[:3, 3]
        cam_pts = (R @ centroids[pre_valid].T).T + t  # (M, 3)

        depth = -cam_pts[:, 2]
        valid_depth = depth > 0.1

        px = fx * cam_pts[:, 0] / np.maximum(depth, 1e-8) + cx
        py = -fy * cam_pts[:, 1] / np.maximum(depth, 1e-8) + cy

        in_frame = (
            (px >= IMAGE_MARGIN) & (px < img_w - IMAGE_MARGIN) &
            (py >= IMAGE_MARGIN) & (py < img_h - IMAGE_MARGIN) &
            valid_depth
        )

        # Write back to full-size mask
        pre_indices = np.where(pre_valid)[0]
        visibility[ci, pre_indices[in_frame]] = True

    return visibility


def _greedy_set_cover(
    visibility: np.ndarray,
    target_count: int,
) -> list[int]:
    """Greedy set-cover: iteratively pick the frame covering the most uncovered faces.

    Returns list of local indices into the visibility matrix.
    """
    n_cameras, n_faces = visibility.shape
    covered = np.zeros(n_faces, dtype=np.bool_)
    selected = []
    remaining = list(range(n_cameras))

    while len(selected) < target_count and remaining:
        # Vectorized: count new coverage for all remaining frames at once
        remaining_vis = visibility[remaining]  # (R, F)
        new_counts = (remaining_vis & ~covered).sum(axis=1)  # (R,)

        best_local = int(np.argmax(new_counts))
        if new_counts[best_local] == 0:
            break

        best_idx = remaining[best_local]
        selected.append(best_idx)
        covered |= visibility[best_idx]
        remaining.pop(best_local)

    return selected


def _fill_with_spacing(
    selected: list[int],
    total_count: int,
    target_count: int,
) -> list[int]:
    """Fill remaining quota with evenly-spaced frames from unselected pool."""
    if len(selected) >= target_count:
        return selected

    selected_set = set(selected)
    unselected = [i for i in range(total_count) if i not in selected_set]

    needed = target_count - len(selected)
    if needed >= len(unselected):
        return selected + unselected

    # Evenly space through unselected pool
    step = len(unselected) / needed
    additions = [unselected[int(i * step)] for i in range(needed)]

    return selected + additions
