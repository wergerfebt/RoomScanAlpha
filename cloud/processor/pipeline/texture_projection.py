"""
Step 7A: Per-surface texture projection from keyframe images.

Projects keyframe camera images onto simplified room surfaces (walls, floor, ceiling)
using camera poses, intrinsics, and depth maps for occlusion-aware blending.

Coordinate convention:
  - ARKit Y-up right-handed: X=right, Y=up, Z=back (toward user)
  - Camera transforms are world-from-camera (column-major 4x4)
  - Camera looks along -Z in camera space
  - Image coordinates: X-right, Y-down (standard image convention)
  - All geometry in meters
  - Intrinsics in pixels (fx, fy, cx, cy)
"""

from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass
from typing import Optional

import numpy as np
from PIL import Image, ImageOps
from scipy.optimize import least_squares


# --- Data Structures ---

@dataclass
class Surface:
    """A planar room surface (wall quad, floor polygon, or ceiling polygon)."""
    surface_id: str
    surface_type: str            # "wall", "floor", "ceiling"
    corners_3d: np.ndarray       # Nx3 world-space corners (meters)
    normal: np.ndarray           # 3D unit normal pointing into the room
    width_m: float
    height_m: float
    u_axis: np.ndarray           # 3D unit vector along U (horizontal)
    v_axis: np.ndarray           # 3D unit vector along V (vertical)
    origin: np.ndarray           # 3D world point at UV = (0, 0)


@dataclass
class Keyframe:
    """A captured camera image with pose, intrinsics, and depth."""
    index: int
    image: np.ndarray            # HxWx3 RGB uint8
    depth_map: Optional[np.ndarray]  # depth_H x depth_W float32 (meters), or None
    camera_transform: np.ndarray # 4x4 world-from-camera
    fx: float
    fy: float
    cx: float
    cy: float
    image_width: int
    image_height: int
    depth_width: int
    depth_height: int
    source: str = "walkaround"   # "walkaround" or "panoramic"


@dataclass
class TextureResult:
    """Output texture for a single surface."""
    surface_id: str
    image: np.ndarray            # HxWx3 RGB uint8
    coverage: float              # fraction of texels with data (0.0-1.0)


# --- Constants ---

WALL_PX_PER_METER = 100
FLOOR_CEIL_PX_PER_METER = 50
MAX_TEXTURE_DIM = 2048
MAX_KEYFRAMES_WALL = 20
MAX_KEYFRAMES_FLOOR_CEIL = 40   # floor/ceiling need more frames — oblique views cover narrow strips
DEPTH_TOLERANCE_M = 0.5         # depth tolerance for floor/ceiling only


# --- Main Entry Point ---

def project_textures(
    keyframes: list[Keyframe],
    surfaces: list[Surface],
    mesh: Optional[trimesh.Trimesh] = None,
) -> list[TextureResult]:
    """Project keyframe images onto surfaces with depth-aware multi-keyframe blending.

    If a trimesh is provided, texel positions are corrected using mesh raycasting
    to account for depth variation (protruding objects, recessed door frames, etc.),
    eliminating ghosting and seam artifacts from multi-view projection.
    """
    if mesh is not None:
        print(f"[TextureProjection] Mesh depth correction enabled "
              f"({len(mesh.vertices)} vertices, {len(mesh.faces)} faces)")

    # Photometric pose refinement: correct per-keyframe drift before projection
    pose_corrections = None
    if mesh is not None and len(keyframes) >= 2:
        try:
            pose_corrections = _refine_poses_photometric(surfaces, keyframes, mesh)
            if pose_corrections:
                print(f"[TextureProjection] Pose corrections computed for "
                      f"{len(pose_corrections)} keyframes")
        except Exception as e:
            print(f"[TextureProjection] Pose refinement failed, using raw poses: {e}")

    results = []
    for surface in surfaces:
        result = _project_surface(surface, keyframes, mesh=mesh,
                                  pose_corrections=pose_corrections)
        results.append(result)
        coverage_pct = result.coverage * 100
        print(f"[TextureProjection] {surface.surface_id}: "
              f"{result.image.shape[1]}x{result.image.shape[0]}px, "
              f"{coverage_pct:.0f}% coverage")
    return results


def _project_surface(
    surface: Surface,
    keyframes: list[Keyframe],
    mesh: Optional[trimesh.Trimesh] = None,
    pose_corrections: Optional[dict[int, tuple[float, float, float]]] = None,
) -> TextureResult:
    """Project and blend keyframes onto a single surface with depth validation."""
    px_per_m = WALL_PX_PER_METER if surface.surface_type == "wall" else FLOOR_CEIL_PX_PER_METER
    tex_w = min(int(surface.width_m * px_per_m), MAX_TEXTURE_DIM)
    tex_h = min(int(surface.height_m * px_per_m), MAX_TEXTURE_DIM)
    tex_w = max(tex_w, 4)
    tex_h = max(tex_h, 4)

    scored = _score_keyframes(surface, keyframes)

    # Select keyframes with guaranteed representation from both sources.
    # Panoramic frames have broad uniform coverage (further away, wider angle);
    # walk-around frames have close-up detail but narrow coverage.
    # Without reserving slots, close walk-around frames outscore panoramic ones
    # and entire wall sections get no coverage.
    # Floor/ceiling need more keyframes — oblique views cover narrow strips.
    max_kf = MAX_KEYFRAMES_FLOOR_CEIL if surface.surface_type in ("floor", "ceiling") else MAX_KEYFRAMES_WALL
    HALF = max_kf // 2
    pano_scored = [(s, kf) for s, kf in scored if kf.source == "panoramic"]
    walk_scored = [(s, kf) for s, kf in scored if kf.source != "panoramic"]
    top_keyframes = pano_scored[:HALF] + walk_scored[:HALF]
    # Fill remaining slots from whichever source has more candidates
    remaining = max_kf - len(top_keyframes)
    if remaining > 0:
        used = {id(kf) for _, kf in top_keyframes}
        extras = [(s, kf) for s, kf in scored if id(kf) not in used]
        top_keyframes.extend(extras[:remaining])

    pano_count = sum(1 for _, kf in top_keyframes if kf.source == "panoramic")
    walk_count = len(top_keyframes) - pano_count
    print(f"[TextureProjection] {surface.surface_id}: selected "
          f"{pano_count} panoramic + {walk_count} walk-around keyframes")

    if not top_keyframes:
        return TextureResult(
            surface_id=surface.surface_id,
            image=np.zeros((tex_h, tex_w, 3), dtype=np.uint8),
            coverage=0.0,
        )

    # Precompute transforms
    kf_data = []
    for score, kf in top_keyframes:
        cam_from_world = np.linalg.inv(kf.camera_transform)
        K = np.array([[kf.fx, 0, kf.cx], [0, kf.fy, kf.cy], [0, 0, 1]], dtype=np.float64)
        kf_data.append((score, kf, cam_from_world, K))

    # Build UV grid → world positions
    us = np.linspace(0, surface.width_m, tex_w, endpoint=False) + surface.width_m / (2 * tex_w)
    vs = np.linspace(0, surface.height_m, tex_h, endpoint=False) + surface.height_m / (2 * tex_h)
    uu, vv = np.meshgrid(us, vs)

    world_pts = (
        surface.origin[np.newaxis, np.newaxis, :]
        + uu[:, :, np.newaxis] * surface.u_axis[np.newaxis, np.newaxis, :]
        + vv[:, :, np.newaxis] * surface.v_axis[np.newaxis, np.newaxis, :]
    )

    if mesh is not None:
        try:
            flat_pts = _build_mesh_depth_map(surface, mesh, tex_w, tex_h)
        except Exception as e:
            print(f"[TextureProjection] Mesh raycasting failed for {surface.surface_id}, "
                  f"falling back to flat plane: {e}")
            flat_pts = world_pts.reshape(-1, 3)
    else:
        flat_pts = world_pts.reshape(-1, 3)
    N = flat_pts.shape[0]

    # Winner-takes-all: for each texel, keep the color from the single
    # highest-weight keyframe. Avoids ghosting from blending frames with
    # slightly misaligned camera poses (~1-3cm ARKit drift).
    best_color = np.zeros((N, 3), dtype=np.float64)
    best_weight = np.zeros(N, dtype=np.float64)

    for score, kf, cam_from_world, K in kf_data:
        pts_h = np.hstack([flat_pts, np.ones((N, 1))])
        cam_pts = (cam_from_world @ pts_h.T).T[:, :3]

        # Depth: distance along camera -Z axis
        depth = -cam_pts[:, 2]
        in_front = depth > 0.01

        # Project to pixel coordinates
        # ARKit: camera X-right, Y-up, looks along -Z
        # Image: X-right, Y-down → negate Y for projection
        px = K[0, 0] * cam_pts[:, 0] / depth + K[0, 2]
        py = -K[1, 1] * cam_pts[:, 1] / depth + K[1, 2]

        # Apply photometric pose correction if available
        if pose_corrections and kf.index in pose_corrections:
            dx, dy, dtheta = pose_corrections[kf.index]
            px = px + dx + dtheta * (py - kf.cy)
            py = py + dy - dtheta * (px - kf.cx)

        # Bounds check
        in_bounds = (
            in_front
            & (px >= 0) & (px < kf.image_width - 1)
            & (py >= 0) & (py < kf.image_height - 1)
        )

        if not np.any(in_bounds):
            continue

        valid_idx = np.where(in_bounds)[0]
        valid_px = px[valid_idx]
        valid_py = py[valid_idx]

        if len(valid_idx) == 0:
            continue

        # Sample image with bilinear interpolation
        colors = _bilinear_sample(kf.image, valid_px, valid_py)

        # Radial weight falloff: pixels near image center contribute more,
        # edges contribute less.
        img_cx = kf.image_width / 2.0
        img_cy = kf.image_height / 2.0
        max_dist = math.sqrt(img_cx ** 2 + img_cy ** 2)
        pixel_dist = np.sqrt((valid_px - img_cx) ** 2 + (valid_py - img_cy) ** 2)
        radial_weight = np.clip(1.0 - (pixel_dist / max_dist) ** 2, 0.1, 1.0)

        weight = score * radial_weight  # per-pixel weight

        # Only update texels where this frame has a higher weight than the current best
        better = weight > best_weight[valid_idx]
        if not np.any(better):
            continue
        better_idx = valid_idx[better]
        best_color[better_idx] = colors[better]
        best_weight[better_idx] = weight[better]

    # No normalization needed — best_color has the winning frame's raw color
    has_data = best_weight > 0
    result_flat = np.zeros((N, 3), dtype=np.uint8)
    result_flat[has_data] = np.clip(best_color[has_data], 0, 255).astype(np.uint8)

    coverage = has_data.sum() / N if N > 0 else 0.0

    return TextureResult(
        surface_id=surface.surface_id,
        image=result_flat.reshape(tex_h, tex_w, 3),
        coverage=coverage,
    )


# --- Mesh Depth Correction ---

def _build_mesh_depth_map(
    surface: Surface,
    mesh: "trimesh.Trimesh",
    tex_w: int,
    tex_h: int,
) -> np.ndarray:
    """Raycast from each texel on the flat wall plane into the mesh to find the true 3D position.

    For each texel, casts rays along the surface normal (both directions) to find
    the nearest mesh intersection. If a hit is found within MESH_TOLERANCE of the
    flat plane, the corrected 3D position is used instead. This fixes ghosting caused
    by depth variation (protruding objects, recessed door frames, etc.).

    Returns: (N, 3) array of mesh-corrected world positions, where N = tex_w * tex_h.
    """
    MESH_TOLERANCE = 0.5  # meters from wall plane

    # Build UV grid of flat wall positions (same grid as _project_surface)
    us = np.linspace(0, surface.width_m, tex_w, endpoint=False) + surface.width_m / (2 * tex_w)
    vs = np.linspace(0, surface.height_m, tex_h, endpoint=False) + surface.height_m / (2 * tex_h)
    uu, vv = np.meshgrid(us, vs)

    flat_pts = (
        surface.origin[np.newaxis, np.newaxis, :]
        + uu[:, :, np.newaxis] * surface.u_axis[np.newaxis, np.newaxis, :]
        + vv[:, :, np.newaxis] * surface.v_axis[np.newaxis, np.newaxis, :]
    ).reshape(-1, 3)

    N = flat_pts.shape[0]
    corrected = flat_pts.copy()

    normal = surface.normal.astype(np.float64)
    normals_fwd = np.tile(normal, (N, 1))

    # Raycast forward (along surface normal, into the room)
    hit_locs_fwd, ray_idx_fwd, _ = mesh.ray.intersects_location(
        ray_origins=flat_pts, ray_directions=normals_fwd, multiple_hits=False,
    )

    # Raycast backward (opposite direction, behind the wall plane)
    hit_locs_bwd, ray_idx_bwd, _ = mesh.ray.intersects_location(
        ray_origins=flat_pts, ray_directions=-normals_fwd, multiple_hits=False,
    )

    # Apply forward hits within tolerance
    if len(hit_locs_fwd) > 0:
        dists_fwd = np.linalg.norm(hit_locs_fwd - flat_pts[ray_idx_fwd], axis=1)
        valid_fwd = dists_fwd < MESH_TOLERANCE
        if np.any(valid_fwd):
            corrected[ray_idx_fwd[valid_fwd]] = hit_locs_fwd[valid_fwd]

    # Apply backward hits — only if closer than the forward hit (or no forward hit)
    if len(hit_locs_bwd) > 0:
        dists_bwd = np.linalg.norm(hit_locs_bwd - flat_pts[ray_idx_bwd], axis=1)
        valid_bwd = dists_bwd < MESH_TOLERANCE
        if np.any(valid_bwd):
            bwd_indices = ray_idx_bwd[valid_bwd]
            bwd_dists = dists_bwd[valid_bwd]
            bwd_pts = hit_locs_bwd[valid_bwd]

            # Check if forward already set a closer hit
            current_dists = np.linalg.norm(corrected[bwd_indices] - flat_pts[bwd_indices], axis=1)
            closer = bwd_dists < current_dists
            if np.any(closer):
                corrected[bwd_indices[closer]] = bwd_pts[closer]

    hit_count = np.sum(np.any(corrected != flat_pts, axis=1))
    print(f"[TextureProjection] Mesh depth correction: {hit_count}/{N} texels corrected "
          f"({hit_count * 100 / N:.0f}%)")

    return corrected


# --- Photometric Pose Refinement ---

REFINE_PX_PER_METER = 10         # downsampled grid for overlap sampling
MIN_OVERLAP_PAIRS = 50           # minimum overlap pairs to include a keyframe pair
GRADIENT_THRESHOLD = 5.0         # minimum gradient magnitude to keep a sample point
MAX_CORRECTION_PX = 30.0         # bound on dx, dy
MAX_CORRECTION_THETA = 0.02      # bound on dθ (radians)


def _refine_poses_photometric(
    surfaces: list[Surface],
    keyframes: list[Keyframe],
    mesh: "trimesh.Trimesh",
) -> dict[int, tuple[float, float, float]]:
    """Compute per-keyframe (dx, dy, dθ) corrections via photometric optimization.

    Samples points on surfaces visible in 2+ keyframes, then optimizes
    corrections to minimize color disagreement at overlap points.
    Uses the LiDAR mesh as ground truth geometry (Zhou & Koltun, SIGGRAPH 2014).

    Returns: dict mapping keyframe index → (dx, dy, dtheta).
    """
    import trimesh as _trimesh

    if len(keyframes) < 2:
        return {}

    # Precompute grayscale images + per-keyframe transforms
    kf_gray = []
    kf_transforms = []  # (cam_from_world, K, kf)
    for kf in keyframes:
        gray = np.mean(kf.image.astype(np.float64), axis=2)
        kf_gray.append(gray)
        cam_from_world = np.linalg.inv(kf.camera_transform)
        K = np.array([[kf.fx, 0, kf.cx], [0, kf.fy, kf.cy], [0, 0, 1]], dtype=np.float64)
        kf_transforms.append((cam_from_world, K, kf))

    # Collect sample points from all surfaces
    all_world_pts = []
    for surface in surfaces:
        px_per_m = REFINE_PX_PER_METER
        sw = max(int(surface.width_m * px_per_m), 2)
        sh = max(int(surface.height_m * px_per_m), 2)

        us = np.linspace(0, surface.width_m, sw, endpoint=False) + surface.width_m / (2 * sw)
        vs = np.linspace(0, surface.height_m, sh, endpoint=False) + surface.height_m / (2 * sh)
        uu, vv = np.meshgrid(us, vs)

        pts = (
            surface.origin[np.newaxis, np.newaxis, :]
            + uu[:, :, np.newaxis] * surface.u_axis[np.newaxis, np.newaxis, :]
            + vv[:, :, np.newaxis] * surface.v_axis[np.newaxis, np.newaxis, :]
        ).reshape(-1, 3)

        # Mesh-correct sample points (same logic as _build_mesh_depth_map but simplified)
        normal = surface.normal.astype(np.float64)
        normals_fwd = np.tile(normal, (len(pts), 1))
        try:
            hit_locs, ray_idx, _ = mesh.ray.intersects_location(
                ray_origins=pts, ray_directions=normals_fwd, multiple_hits=False,
            )
            if len(hit_locs) > 0:
                dists = np.linalg.norm(hit_locs - pts[ray_idx], axis=1)
                valid = dists < 0.5
                if np.any(valid):
                    pts[ray_idx[valid]] = hit_locs[valid]
        except Exception:
            pass

        all_world_pts.append(pts)

    world_pts = np.vstack(all_world_pts)
    N_pts = len(world_pts)

    if N_pts == 0:
        return {}

    # Project all sample points into all keyframes, record visibility
    # visibility[k] = (valid_mask, px_array, py_array) for keyframe k
    pts_h = np.hstack([world_pts, np.ones((N_pts, 1))])
    visibility = []

    for cam_from_world, K, kf in kf_transforms:
        cam_pts = (cam_from_world @ pts_h.T).T[:, :3]
        depth = -cam_pts[:, 2]
        in_front = depth > 0.01

        px = K[0, 0] * cam_pts[:, 0] / depth + K[0, 2]
        py = -K[1, 1] * cam_pts[:, 1] / depth + K[1, 2]

        # Margin of MAX_CORRECTION_PX to allow for correction shifts
        margin = MAX_CORRECTION_PX + 1
        in_bounds = (
            in_front
            & (px >= margin) & (px < kf.image_width - margin)
            & (py >= margin) & (py < kf.image_height - margin)
        )

        visibility.append((in_bounds, px, py))

    # Build overlap pairs: for each sample point, find keyframe pairs that both see it
    # Structure: list of (point_idx, kf_idx_i, px_i, py_i, kf_idx_j, px_j, py_j)
    overlap_point_idxs = []
    overlap_kf_i = []
    overlap_kf_j = []
    overlap_px_i = []
    overlap_py_i = []
    overlap_px_j = []
    overlap_py_j = []

    # Build per-point visibility list efficiently
    vis_masks = np.array([v[0] for v in visibility])  # (K, N_pts) bool
    n_visible = vis_masks.sum(axis=0)  # per-point count
    multi_vis = np.where(n_visible >= 2)[0]

    for pt_idx in multi_vis:
        kf_indices = np.where(vis_masks[:, pt_idx])[0]
        for ii in range(len(kf_indices)):
            for jj in range(ii + 1, len(kf_indices)):
                ki = kf_indices[ii]
                kj = kf_indices[jj]
                overlap_point_idxs.append(pt_idx)
                overlap_kf_i.append(ki)
                overlap_kf_j.append(kj)
                overlap_px_i.append(visibility[ki][1][pt_idx])
                overlap_py_i.append(visibility[ki][2][pt_idx])
                overlap_px_j.append(visibility[kj][1][pt_idx])
                overlap_py_j.append(visibility[kj][2][pt_idx])

    if len(overlap_point_idxs) == 0:
        print("[PoseRefinement] No overlap pairs found, skipping refinement")
        return {}

    overlap_px_i = np.array(overlap_px_i)
    overlap_py_i = np.array(overlap_py_i)
    overlap_px_j = np.array(overlap_px_j)
    overlap_py_j = np.array(overlap_py_j)
    overlap_kf_i = np.array(overlap_kf_i)
    overlap_kf_j = np.array(overlap_kf_j)

    # Filter out textureless regions using gradient magnitude
    keep_mask = np.ones(len(overlap_px_i), dtype=bool)
    for idx in range(len(overlap_px_i)):
        ki = overlap_kf_i[idx]
        gray = kf_gray[ki]
        ix = int(np.clip(overlap_px_i[idx], 1, kf_transforms[ki][2].image_width - 2))
        iy = int(np.clip(overlap_py_i[idx], 1, kf_transforms[ki][2].image_height - 2))
        gx = float(gray[iy, min(ix + 1, gray.shape[1] - 1)] - gray[iy, max(ix - 1, 0)])
        gy = float(gray[min(iy + 1, gray.shape[0] - 1), ix] - gray[max(iy - 1, 0), ix])
        if math.sqrt(gx * gx + gy * gy) < GRADIENT_THRESHOLD:
            keep_mask[idx] = False

    overlap_px_i = overlap_px_i[keep_mask]
    overlap_py_i = overlap_py_i[keep_mask]
    overlap_px_j = overlap_px_j[keep_mask]
    overlap_py_j = overlap_py_j[keep_mask]
    overlap_kf_i = overlap_kf_i[keep_mask]
    overlap_kf_j = overlap_kf_j[keep_mask]

    n_pairs = len(overlap_px_i)
    if n_pairs < MIN_OVERLAP_PAIRS:
        print(f"[PoseRefinement] Only {n_pairs} textured overlap pairs, skipping refinement")
        return {}

    print(f"[PoseRefinement] {N_pts} sample points, {len(multi_vis)} multi-view, "
          f"{n_pairs} textured overlap pairs across {len(keyframes)} keyframes")

    # Find reference keyframe (pin at zero correction) — use highest average visibility
    vis_counts = vis_masks.sum(axis=1)
    ref_kf_idx = int(np.argmax(vis_counts))

    # Keyframe index mapping for optimization variables
    # All keyframes get 3 params (dx, dy, dθ), but ref keyframe is pinned at 0
    n_kf = len(keyframes)

    def _sample_gray(kf_idx: int, px: np.ndarray, py: np.ndarray) -> np.ndarray:
        """Bilinear sample grayscale image at sub-pixel coords."""
        gray = kf_gray[kf_idx]
        h, w = gray.shape
        x0 = np.floor(px).astype(int)
        y0 = np.floor(py).astype(int)
        x1 = np.minimum(x0 + 1, w - 1)
        y1 = np.minimum(y0 + 1, h - 1)
        x0 = np.clip(x0, 0, w - 1)
        y0 = np.clip(y0, 0, h - 1)
        xf = px - x0
        yf = py - y0
        return (gray[y0, x0] * (1 - xf) * (1 - yf)
                + gray[y0, x1] * xf * (1 - yf)
                + gray[y1, x0] * (1 - xf) * yf
                + gray[y1, x1] * xf * yf)

    def _apply_correction(px, py, cx, cy, dx, dy, dtheta):
        """Apply 2D affine pose correction to pixel coordinates."""
        px_c = px + dx + dtheta * (py - cy)
        py_c = py + dy - dtheta * (px - cx)
        return px_c, py_c

    # Precompute cx, cy arrays for vectorized access
    cx_arr = np.array([kf_transforms[k][2].cx for k in range(n_kf)])
    cy_arr = np.array([kf_transforms[k][2].cy for k in range(n_kf)])

    # Build index mapping: exclude ref keyframe from optimization variables
    # opt_indices[k] = index into params array, or -1 for ref (pinned at 0)
    opt_indices = []
    opt_count = 0
    for k in range(n_kf):
        if k == ref_kf_idx:
            opt_indices.append(-1)
        else:
            opt_indices.append(opt_count)
            opt_count += 1
    opt_indices = np.array(opt_indices)

    def _get_corrections(params):
        """Expand optimization params to full n_kf×3 corrections array."""
        full = np.zeros((n_kf, 3), dtype=np.float64)
        for k in range(n_kf):
            if opt_indices[k] >= 0:
                full[k] = params[opt_indices[k] * 3: opt_indices[k] * 3 + 3]
        return full

    def residual_fn(params):
        """Compute photometric residuals for all overlap pairs."""
        corrections = _get_corrections(params)

        # Vectorized: apply corrections to all pairs at once
        dx_i = corrections[overlap_kf_i, 0]
        dy_i = corrections[overlap_kf_i, 1]
        dt_i = corrections[overlap_kf_i, 2]
        dx_j = corrections[overlap_kf_j, 0]
        dy_j = corrections[overlap_kf_j, 1]
        dt_j = corrections[overlap_kf_j, 2]

        cx_i = cx_arr[overlap_kf_i]
        cy_i = cy_arr[overlap_kf_i]
        cx_j = cx_arr[overlap_kf_j]
        cy_j = cy_arr[overlap_kf_j]

        px_i_c = overlap_px_i + dx_i + dt_i * (overlap_py_i - cy_i)
        py_i_c = overlap_py_i + dy_i - dt_i * (overlap_px_i - cx_i)
        px_j_c = overlap_px_j + dx_j + dt_j * (overlap_py_j - cy_j)
        py_j_c = overlap_py_j + dy_j - dt_j * (overlap_px_j - cx_j)

        # Sample each keyframe's grayscale at corrected coordinates
        val_i = np.empty(n_pairs, dtype=np.float64)
        val_j = np.empty(n_pairs, dtype=np.float64)

        for k in range(n_kf):
            mask_i = overlap_kf_i == k
            if np.any(mask_i):
                val_i[mask_i] = _sample_gray(k, px_i_c[mask_i], py_i_c[mask_i])
            mask_j = overlap_kf_j == k
            if np.any(mask_j):
                val_j[mask_j] = _sample_gray(k, px_j_c[mask_j], py_j_c[mask_j])

        return val_i - val_j

    # Set up bounds for optimized keyframes only (exclude ref)
    n_opt_params = opt_count * 3
    lower = np.empty(n_opt_params)
    upper = np.empty(n_opt_params)
    for i in range(opt_count):
        lower[i * 3] = -MAX_CORRECTION_PX
        lower[i * 3 + 1] = -MAX_CORRECTION_PX
        lower[i * 3 + 2] = -MAX_CORRECTION_THETA
        upper[i * 3] = MAX_CORRECTION_PX
        upper[i * 3 + 1] = MAX_CORRECTION_PX
        upper[i * 3 + 2] = MAX_CORRECTION_THETA

    x0 = np.zeros(n_opt_params)

    result = least_squares(
        residual_fn, x0,
        method='trf',
        bounds=(lower, upper),
        diff_step=0.5,  # finite-difference step in pixels
        max_nfev=100,
        verbose=0,
    )

    corrections = _get_corrections(result.x)

    # Build output dict mapping keyframe.index → (dx, dy, dθ)
    pose_corrections: dict[int, tuple[float, float, float]] = {}
    for k, kf in enumerate(keyframes):
        dx, dy, dtheta = corrections[k]
        if abs(dx) > 0.01 or abs(dy) > 0.01 or abs(dtheta) > 0.0001:
            pose_corrections[kf.index] = (float(dx), float(dy), float(dtheta))

    print(f"[PoseRefinement] Optimization: cost {result.cost:.1f}, "
          f"{result.nfev} evaluations, ref=keyframe {keyframes[ref_kf_idx].index}")
    for kf_idx, (dx, dy, dt) in sorted(pose_corrections.items()):
        print(f"[PoseRefinement]   keyframe {kf_idx}: dx={dx:.1f}px, dy={dy:.1f}px, dθ={dt:.4f}rad")

    return pose_corrections


# --- Keyframe Scoring ---

def _score_keyframes(
    surface: Surface,
    keyframes: list[Keyframe],
) -> list[tuple[float, Keyframe]]:
    """Score keyframes by viewing angle, distance, and coverage."""
    surface_center = surface.origin + (
        surface.u_axis * surface.width_m / 2
        + surface.v_axis * surface.height_m / 2
    )
    scored = []
    for kf in keyframes:
        cam_pos = kf.camera_transform[:3, 3]
        to_cam = cam_pos - surface_center
        dist = np.linalg.norm(to_cam)
        if dist < 0.01:
            continue
        to_cam_normalized = to_cam / dist

        angle_score = abs(float(np.dot(to_cam_normalized, surface.normal)))
        # Floor/ceiling are always viewed obliquely from eye height — accept lower angles
        min_angle = 0.02 if surface.surface_type in ("floor", "ceiling") else 0.1
        if angle_score < min_angle:
            continue

        dist_score = min(1.0, 2.0 / max(dist, 0.5))
        coverage_score = _estimate_coverage(surface, kf)

        total = angle_score * 0.5 + dist_score * 0.2 + coverage_score * 0.3
        if total > 0.05:
            scored.append((total, kf))

    scored.sort(key=lambda x: -x[0])
    return scored


def _estimate_coverage(surface: Surface, kf: Keyframe) -> float:
    """Estimate what fraction of the surface is visible in a keyframe."""
    cam_from_world = np.linalg.inv(kf.camera_transform)
    K = np.array([[kf.fx, 0, kf.cx], [0, kf.fy, kf.cy], [0, 0, 1]], dtype=np.float64)

    corners = surface.corners_3d
    pts_h = np.hstack([corners, np.ones((len(corners), 1))])
    cam_pts = (cam_from_world @ pts_h.T).T[:, :3]

    in_front = -cam_pts[:, 2] > 0.01
    if not np.any(in_front):
        return 0.0

    valid = cam_pts[in_front]
    valid_depth = -valid[:, 2]
    px = K[0, 0] * valid[:, 0] / valid_depth + K[0, 2]
    py = -K[1, 1] * valid[:, 1] / valid_depth + K[1, 2]

    px_clamped = np.clip(px, 0, kf.image_width - 1)
    py_clamped = np.clip(py, 0, kf.image_height - 1)

    if len(px_clamped) < 2:
        return 0.0

    bbox_w = px_clamped.max() - px_clamped.min()
    bbox_h = py_clamped.max() - py_clamped.min()
    img_area = kf.image_width * kf.image_height
    bbox_area = bbox_w * bbox_h

    return min(1.0, bbox_area / max(img_area * 0.01, 1))


# --- Bilinear Sampling ---

def _bilinear_sample(image: np.ndarray, px: np.ndarray, py: np.ndarray) -> np.ndarray:
    """Sample an image at sub-pixel coordinates using bilinear interpolation."""
    h, w = image.shape[:2]
    x0 = np.floor(px).astype(int)
    y0 = np.floor(py).astype(int)
    x1 = np.minimum(x0 + 1, w - 1)
    y1 = np.minimum(y0 + 1, h - 1)
    x0 = np.clip(x0, 0, w - 1)
    y0 = np.clip(y0, 0, h - 1)

    xf = (px - x0)[:, np.newaxis]
    yf = (py - y0)[:, np.newaxis]

    c00 = image[y0, x0].astype(np.float64)
    c10 = image[y0, x1].astype(np.float64)
    c01 = image[y1, x0].astype(np.float64)
    c11 = image[y1, x1].astype(np.float64)

    return c00 * (1 - xf) * (1 - yf) + c10 * xf * (1 - yf) + c01 * (1 - xf) * yf + c11 * xf * yf


# --- Surface Construction from Annotation ---

def build_surfaces_from_annotation(
    corners_xz: list[list[float]],
    corners_y: list[float],
    floor_y: float = 0.0,
    ceiling_height_m: Optional[float] = None,
) -> list[Surface]:
    """Build wall quads + floor + ceiling from a corner annotation polygon.

    corners_y are absolute Y coordinates in AR space (not wall heights).
    ceiling_height_m is the actual floor-to-ceiling distance from RANSAC.
    """
    n = len(corners_xz)
    if n < 3 or len(corners_y) < n:
        return []

    avg_ceiling_y = sum(corners_y) / n
    if ceiling_height_m and ceiling_height_m > 0:
        floor_y = avg_ceiling_y - ceiling_height_m
    else:
        ceiling_height_m = avg_ceiling_y - floor_y

    surfaces = []

    # Walls
    for i in range(n):
        j = (i + 1) % n
        x0, z0 = corners_xz[i]
        x1, z1 = corners_xz[j]
        y_top_0 = corners_y[i]
        y_top_1 = corners_y[j]
        y_bot = floor_y

        bl = np.array([x0, y_bot, z0])
        br = np.array([x1, y_bot, z1])
        tr = np.array([x1, y_top_1, z1])
        tl = np.array([x0, y_top_0, z0])

        u_vec = br - bl
        width = np.linalg.norm(u_vec)
        if width < 0.01:
            continue
        u_axis = u_vec / width

        avg_height = ((y_top_0 - y_bot) + (y_top_1 - y_bot)) / 2
        v_axis = np.array([0.0, 1.0, 0.0])

        edge_dir = np.array([x1 - x0, 0, z1 - z0])
        edge_dir_norm = edge_dir / np.linalg.norm(edge_dir)
        normal = np.cross(edge_dir_norm, np.array([0, 1, 0]))
        normal_len = np.linalg.norm(normal)
        if normal_len > 0.01:
            normal = normal / normal_len
        else:
            normal = np.array([0, 0, 1.0])

        surfaces.append(Surface(
            surface_id=f"wall_{i}",
            surface_type="wall",
            corners_3d=np.array([bl, br, tr, tl]),
            normal=normal,
            width_m=width,
            height_m=avg_height,
            u_axis=u_axis,
            v_axis=v_axis,
            origin=bl,
        ))

    # Floor
    floor_corners = np.array([[x, floor_y, z] for x, z in corners_xz])
    xs = [c[0] for c in corners_xz]
    zs = [c[1] for c in corners_xz]
    floor_min_x, floor_max_x = min(xs), max(xs)
    floor_min_z, floor_max_z = min(zs), max(zs)
    floor_w = floor_max_x - floor_min_x
    floor_h = floor_max_z - floor_min_z

    if floor_w > 0.01 and floor_h > 0.01:
        surfaces.append(Surface(
            surface_id="floor",
            surface_type="floor",
            corners_3d=floor_corners,
            normal=np.array([0.0, 1.0, 0.0]),
            width_m=floor_w,
            height_m=floor_h,
            u_axis=np.array([1.0, 0.0, 0.0]),
            v_axis=np.array([0.0, 0.0, 1.0]),
            origin=np.array([floor_min_x, floor_y, floor_min_z]),
        ))

    # Ceiling
    ceiling_corners = np.array([[x, avg_ceiling_y, z] for x, z in corners_xz])
    if floor_w > 0.01 and floor_h > 0.01:
        surfaces.append(Surface(
            surface_id="ceiling",
            surface_type="ceiling",
            corners_3d=ceiling_corners,
            normal=np.array([0.0, -1.0, 0.0]),
            width_m=floor_w,
            height_m=floor_h,
            u_axis=np.array([1.0, 0.0, 0.0]),
            v_axis=np.array([0.0, 0.0, 1.0]),
            origin=np.array([floor_min_x, avg_ceiling_y, floor_min_z]),
        ))

    return surfaces


def load_keyframes(scan_root: str, metadata: dict) -> list[Keyframe]:
    """Load keyframe images, depth maps, and camera poses from a scan package."""
    intrinsics = metadata.get("camera_intrinsics", {})
    fx = intrinsics.get("fx", 1000.0)
    fy = intrinsics.get("fy", 1000.0)
    cx = intrinsics.get("cx", 960.0)
    cy = intrinsics.get("cy", 540.0)

    img_res = metadata.get("image_resolution", {})
    img_w = img_res.get("width", 1920)
    img_h = img_res.get("height", 1440)

    depth_fmt = metadata.get("depth_format", {})
    depth_w = depth_fmt.get("width", 256)
    depth_h = depth_fmt.get("height", 192)

    keyframes_dir = os.path.join(scan_root, "keyframes")
    depth_dir = os.path.join(scan_root, "depth")
    frame_entries = metadata.get("keyframes", [])

    keyframes = []
    for entry in frame_entries:
        idx = entry["index"]
        jpg_name = entry["filename"]
        json_name = jpg_name.replace(".jpg", ".json")
        depth_name = entry.get("depth_filename", jpg_name.replace(".jpg", ".depth"))

        jpg_path = os.path.join(keyframes_dir, jpg_name)
        json_path = os.path.join(keyframes_dir, json_name)
        depth_path = os.path.join(depth_dir, depth_name)

        if not os.path.exists(jpg_path) or not os.path.exists(json_path):
            continue

        # Load image with EXIF rotation applied
        try:
            img = ImageOps.exif_transpose(Image.open(jpg_path)).convert("RGB")
            img_array = np.array(img)
        except Exception:
            continue

        # Load depth map
        depth_map = None
        if os.path.exists(depth_path):
            try:
                depth_data = np.fromfile(depth_path, dtype=np.float32)
                if depth_data.size == depth_w * depth_h:
                    depth_map = depth_data.reshape(depth_h, depth_w)
            except Exception:
                pass

        # Load camera transform (column-major 4x4)
        with open(json_path, "r") as f:
            frame_meta = json.load(f)

        transform_flat = frame_meta.get("camera_transform", [])
        if len(transform_flat) != 16:
            continue

        transform = np.array(transform_flat, dtype=np.float64).reshape(4, 4, order='F')

        keyframes.append(Keyframe(
            index=idx,
            image=img_array,
            depth_map=depth_map,
            camera_transform=transform,
            fx=fx, fy=fy, cx=cx, cy=cy,
            image_width=img_w,
            image_height=img_h,
            depth_width=depth_w,
            depth_height=depth_h,
        ))

    print(f"[TextureProjection] Loaded {len(keyframes)} keyframes "
          f"({sum(1 for k in keyframes if k.depth_map is not None)} with depth)")
    return keyframes


def load_panoramic_keyframes(scan_root: str, metadata: dict) -> list[Keyframe]:
    """Load panoramic sweep keyframes if available. Falls back to empty list."""
    pano_entries = metadata.get("panoramic_keyframes")
    if not pano_entries:
        return []

    intrinsics = metadata.get("camera_intrinsics", {})
    fx = intrinsics.get("fx", 1000.0)
    fy = intrinsics.get("fy", 1000.0)
    cx = intrinsics.get("cx", 960.0)
    cy = intrinsics.get("cy", 540.0)

    img_res = metadata.get("image_resolution", {})
    img_w = img_res.get("width", 1920)
    img_h = img_res.get("height", 1440)

    depth_fmt = metadata.get("depth_format", {})
    depth_w = depth_fmt.get("width", 256)
    depth_h = depth_fmt.get("height", 192)

    pano_dir = os.path.join(scan_root, "panoramic")
    pano_depth_dir = os.path.join(scan_root, "panoramic_depth")

    keyframes = []
    for entry in pano_entries:
        idx = entry["index"]
        jpg_name = entry["filename"]
        json_name = jpg_name.replace(".jpg", ".json")
        depth_name = entry.get("depth_filename", jpg_name.replace(".jpg", ".depth"))

        jpg_path = os.path.join(pano_dir, jpg_name)
        json_path = os.path.join(pano_dir, json_name)
        depth_path = os.path.join(pano_depth_dir, depth_name)

        if not os.path.exists(jpg_path) or not os.path.exists(json_path):
            continue

        try:
            img = ImageOps.exif_transpose(Image.open(jpg_path)).convert("RGB")
            img_array = np.array(img)
        except Exception:
            continue

        depth_map = None
        if os.path.exists(depth_path):
            try:
                depth_data = np.fromfile(depth_path, dtype=np.float32)
                if depth_data.size == depth_w * depth_h:
                    depth_map = depth_data.reshape(depth_h, depth_w)
            except Exception:
                pass

        with open(json_path, "r") as f:
            frame_meta = json.load(f)

        transform_flat = frame_meta.get("camera_transform", [])
        if len(transform_flat) != 16:
            continue

        transform = np.array(transform_flat, dtype=np.float64).reshape(4, 4, order='F')

        keyframes.append(Keyframe(
            index=idx,
            image=img_array,
            depth_map=depth_map,
            camera_transform=transform,
            fx=fx, fy=fy, cx=cx, cy=cy,
            image_width=img_w,
            image_height=img_h,
            depth_width=depth_w,
            depth_height=depth_h,
            source="panoramic",
        ))

    print(f"[TextureProjection] Loaded {len(keyframes)} panoramic keyframes "
          f"({sum(1 for k in keyframes if k.depth_map is not None)} with depth)")
    return keyframes


def save_textures(
    results: list[TextureResult],
    output_dir: str,
    quality: int = 85,
) -> dict[str, str]:
    """Save texture results as JPEG files."""
    os.makedirs(output_dir, exist_ok=True)
    manifest = {}

    for result in results:
        filename = f"{result.surface_id}.jpg"
        filepath = os.path.join(output_dir, filename)
        img = Image.fromarray(result.image)
        img.save(filepath, "JPEG", quality=quality)
        manifest[result.surface_id] = filename
        size_kb = os.path.getsize(filepath) / 1024
        print(f"[TextureProjection] Saved {filename} ({size_kb:.0f}KB)")

    return manifest
