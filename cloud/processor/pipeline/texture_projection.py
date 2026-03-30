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

import json
import math
import os
from dataclasses import dataclass
from typing import Optional

import numpy as np
from PIL import Image, ImageOps


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
MAX_KEYFRAMES_PER_SURFACE = 15
DEPTH_TOLERANCE_M = 0.5         # depth tolerance for floor/ceiling only


# --- Main Entry Point ---

def project_textures(
    keyframes: list[Keyframe],
    surfaces: list[Surface],
) -> list[TextureResult]:
    """Project keyframe images onto surfaces with depth-aware multi-keyframe blending."""
    results = []
    for surface in surfaces:
        result = _project_surface(surface, keyframes)
        results.append(result)
        coverage_pct = result.coverage * 100
        print(f"[TextureProjection] {surface.surface_id}: "
              f"{result.image.shape[1]}x{result.image.shape[0]}px, "
              f"{coverage_pct:.0f}% coverage")
    return results


def _project_surface(surface: Surface, keyframes: list[Keyframe]) -> TextureResult:
    """Project and blend keyframes onto a single surface with depth validation."""
    px_per_m = WALL_PX_PER_METER if surface.surface_type == "wall" else FLOOR_CEIL_PX_PER_METER
    tex_w = min(int(surface.width_m * px_per_m), MAX_TEXTURE_DIM)
    tex_h = min(int(surface.height_m * px_per_m), MAX_TEXTURE_DIM)
    tex_w = max(tex_w, 4)
    tex_h = max(tex_h, 4)

    scored = _score_keyframes(surface, keyframes)
    top_keyframes = scored[:MAX_KEYFRAMES_PER_SURFACE]

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

    flat_pts = world_pts.reshape(-1, 3)
    N = flat_pts.shape[0]

    accum_color = np.zeros((N, 3), dtype=np.float64)
    accum_weight = np.zeros(N, dtype=np.float64)

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
        valid_depth = depth[valid_idx]

        # Depth validation disabled: depth maps measure distance to whatever is
        # in view (furniture, objects), not necessarily the target surface.
        # Rely on viewing angle + coverage scoring to select good keyframes.

        if len(valid_idx) == 0:
            continue

        # Sample image with bilinear interpolation
        colors = _bilinear_sample(kf.image, valid_px, valid_py)

        # Radial weight falloff: pixels near image center contribute more,
        # edges contribute less. This creates smooth blending in overlap regions.
        img_cx = kf.image_width / 2.0
        img_cy = kf.image_height / 2.0
        max_dist = math.sqrt(img_cx ** 2 + img_cy ** 2)
        pixel_dist = np.sqrt((valid_px - img_cx) ** 2 + (valid_py - img_cy) ** 2)
        radial_weight = np.clip(1.0 - (pixel_dist / max_dist) ** 2, 0.1, 1.0)

        weight = score * radial_weight  # per-pixel weight
        accum_color[valid_idx] += colors * weight[:, np.newaxis]
        accum_weight[valid_idx] += weight

    # Normalize
    has_data = accum_weight > 0
    result_flat = np.zeros((N, 3), dtype=np.uint8)
    result_flat[has_data] = np.clip(
        accum_color[has_data] / accum_weight[has_data, np.newaxis],
        0, 255
    ).astype(np.uint8)

    coverage = has_data.sum() / N if N > 0 else 0.0

    return TextureResult(
        surface_id=surface.surface_id,
        image=result_flat.reshape(tex_h, tex_w, 3),
        coverage=coverage,
    )


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
