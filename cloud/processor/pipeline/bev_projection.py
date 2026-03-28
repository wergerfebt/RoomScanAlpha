"""
BEV Projection — project classified LiDAR mesh to a bird's-eye-view density map.

Converts a ParsedMesh (3D vertices with ARKit classifications) into a 2D top-down
density map suitable for DNN room layout estimation (RoomFormer).

Coordinate system:
    - Input: ARKit Y-up (X=right, Y=up, Z=back). Positions in meters.
    - Output: 2D density map in XZ plane (Y axis dropped).
    - Pixel (0,0) = (xmin, zmin) corner of the padded bounding box.

Density map generation matches RoomFormer's stru3d_utils.py:generate_density():
    - 10% bbox padding, extended to square
    - np.unique pixel counting (not histogram2d)
    - uint8 round-trip normalization (float32 → uint8 → float32/255)
"""

from dataclasses import dataclass

import numpy as np

from .stage1 import (
    CLASSIFICATION_CEILING,
    CLASSIFICATION_FLOOR,
    CLASSIFICATION_NONE,
    CLASSIFICATION_WALL,
    ParsedMesh,
)

# ARKit classification IDs for furniture/unclassified (excluded from structural BEV)
_CLASSIFICATION_TABLE = 4
_CLASSIFICATION_SEAT = 5
_CLASSIFICATION_DOOR = 6
_CLASSIFICATION_WINDOW = 7

# Structural classifications: surfaces that define the room boundary.
# Includes ceiling because Structured3D training data uses all vertices —
# removing ceiling changes the density map distribution too much for the
# pretrained model.
# NOTE: Ceiling fills the room interior in BEV, which drowns interior corners
# (L-shapes, T-shapes). When fine-tuning (Step 7), experiment with wall-only
# maps as an alternative — the wall-only signal is cleaner for complex rooms.
STRUCTURAL_CLASSES = frozenset({
    CLASSIFICATION_WALL,      # 1
    CLASSIFICATION_CEILING,   # 3
    _CLASSIFICATION_DOOR,     # 6
    _CLASSIFICATION_WINDOW,   # 7
})


@dataclass
class BEVProjection:
    """Result of projecting a mesh to a bird's-eye-view density map.

    Attributes:
        density_map: (resolution x resolution) float32 array, values in [0, 1].
                     Produced via uint8 round-trip to match RoomFormer training data.
        xmin, xmax, zmin, zmax: Padded bounding box in meters (world coordinates).
        meters_per_pixel_x: Scale factor for X axis.
        meters_per_pixel_z: Scale factor for Z axis.
        resolution: Pixel resolution of the density map (e.g. 256).
    """
    density_map: np.ndarray
    xmin: float
    xmax: float
    zmin: float
    zmax: float
    meters_per_pixel_x: float
    meters_per_pixel_z: float
    resolution: int


def project_to_bev(
    mesh: ParsedMesh,
    resolution: int = 256,
    structural_only: bool = True,
) -> BEVProjection:
    """Project mesh vertices to a top-down BEV density map.

    Args:
        mesh: ParsedMesh from Stage 1.
        resolution: Output density map size (resolution x resolution pixels).
        structural_only: If True, only include structural vertices (wall, ceiling,
                         door, window). Excludes floor, table, seat, and unclassified
                         to reduce furniture noise in the density map.

    Returns:
        BEVProjection with the density map and coordinate transform parameters.
    """
    # Collect vertex positions, optionally filtered by classification
    if structural_only:
        vertex_ids = _get_structural_vertex_ids(mesh)
        if len(vertex_ids) == 0:
            return _empty_projection(resolution)
        xz = mesh.positions[vertex_ids][:, [0, 2]]  # X, Z columns
    else:
        xz = mesh.positions[:, [0, 2]]

    if len(xz) == 0:
        return _empty_projection(resolution)

    # Compute bounding box with 10% padding (matching RoomFormer)
    xmin, zmin = xz.min(axis=0)
    xmax, zmax = xz.max(axis=0)

    x_extent = xmax - xmin
    z_extent = zmax - zmin
    max_extent = max(x_extent, z_extent)

    # 10% padding on each side
    pad = 0.1 * max_extent

    # Extend to square (centered on the data)
    x_center = (xmin + xmax) / 2.0
    z_center = (zmin + zmax) / 2.0
    half_side = max_extent / 2.0 + pad

    xmin_padded = float(x_center - half_side)
    xmax_padded = float(x_center + half_side)
    zmin_padded = float(z_center - half_side)
    zmax_padded = float(z_center + half_side)

    side_length = xmax_padded - xmin_padded  # == zmax_padded - zmin_padded
    meters_per_pixel = side_length / resolution

    # Rasterize via np.unique counting (matching RoomFormer, NOT histogram2d)
    # Convert world coords to pixel coords, round to int, count unique pixels
    px_x = ((xz[:, 0] - xmin_padded) / side_length * (resolution - 1)).astype(np.int32)
    px_z = ((xz[:, 1] - zmin_padded) / side_length * (resolution - 1)).astype(np.int32)

    # Clip to valid range
    px_x = np.clip(px_x, 0, resolution - 1)
    px_z = np.clip(px_z, 0, resolution - 1)

    # Count unique pixel coordinates
    pixel_ids = px_z * resolution + px_x  # row-major: z=row, x=col
    unique_ids, counts = np.unique(pixel_ids, return_counts=True)

    density = np.zeros((resolution, resolution), dtype=np.float32)
    rows = unique_ids // resolution
    cols = unique_ids % resolution
    density[rows, cols] = counts.astype(np.float32)

    # Normalize to [0, 1]
    max_count = density.max()
    if max_count > 0:
        density = density / max_count

    # uint8 round-trip to match RoomFormer training pipeline
    # (RoomFormer saves density maps as uint8 PNGs then loads as float32/255)
    density_uint8 = (density * 255).astype(np.uint8)
    density = density_uint8.astype(np.float32) / 255.0

    return BEVProjection(
        density_map=density,
        xmin=xmin_padded,
        xmax=xmax_padded,
        zmin=zmin_padded,
        zmax=zmax_padded,
        meters_per_pixel_x=meters_per_pixel,
        meters_per_pixel_z=meters_per_pixel,
        resolution=resolution,
    )


def pixels_to_meters(px: np.ndarray, proj: BEVProjection) -> np.ndarray:
    """Convert Nx2 pixel coordinates (col, row) to XZ world coordinates in meters.

    Matches RoomFormer's normalization_dict coordinate recovery:
        x = col / (resolution - 1) * (xmax - xmin) + xmin
        z = row / (resolution - 1) * (zmax - zmin) + zmin

    Args:
        px: Nx2 array of (col, row) pixel coordinates (float or int).
        proj: BEVProjection containing the coordinate transform.

    Returns:
        Nx2 array of (x_meters, z_meters) world coordinates.
    """
    px = np.asarray(px, dtype=np.float64)
    res = proj.resolution - 1  # max pixel index

    x = px[:, 0] / res * (proj.xmax - proj.xmin) + proj.xmin
    z = px[:, 1] / res * (proj.zmax - proj.zmin) + proj.zmin

    return np.column_stack([x, z])


def meters_to_pixels(xz: np.ndarray, proj: BEVProjection) -> np.ndarray:
    """Convert Nx2 XZ world coordinates (meters) to pixel coordinates (col, row).

    Inverse of pixels_to_meters.

    Args:
        xz: Nx2 array of (x_meters, z_meters) world coordinates.
        proj: BEVProjection containing the coordinate transform.

    Returns:
        Nx2 array of (col, row) pixel coordinates (float).
    """
    xz = np.asarray(xz, dtype=np.float64)
    res = proj.resolution - 1

    col = (xz[:, 0] - proj.xmin) / (proj.xmax - proj.xmin) * res
    row = (xz[:, 1] - proj.zmin) / (proj.zmax - proj.zmin) * res

    return np.column_stack([col, row])


def _get_structural_vertex_ids(mesh: ParsedMesh) -> np.ndarray:
    """Get unique vertex IDs belonging to structural classification groups."""
    all_ids = []
    for cls_id, group in mesh.classification_groups.items():
        if cls_id in STRUCTURAL_CLASSES:
            all_ids.append(group.vertex_ids)

    if not all_ids:
        return np.array([], dtype=np.int32)

    return np.unique(np.concatenate(all_ids))


def _empty_projection(resolution: int) -> BEVProjection:
    """Return a zeroed-out BEV projection when no vertices are available."""
    return BEVProjection(
        density_map=np.zeros((resolution, resolution), dtype=np.float32),
        xmin=0.0,
        xmax=1.0,
        zmin=0.0,
        zmax=1.0,
        meters_per_pixel_x=1.0 / resolution,
        meters_per_pixel_z=1.0 / resolution,
        resolution=resolution,
    )
