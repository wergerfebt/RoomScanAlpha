"""
Stage 2: Plane Fitting — detect planar surfaces via RANSAC and object bounding boxes via PCA.

Input:  ParsedMesh from Stage 1
Output: PlaneFitResult containing DetectedPlane and DetectedObject lists

For each structural classification group (wall, floor, ceiling), iterative RANSAC
extracts dominant planes until remaining points < 5% or no plane has > min_inliers.

For object classifications (table, seat, door, window), PCA computes an oriented
bounding box (OBB).

Coordinate system: ARKit Y-up right-handed (Y=up, -Z=forward). All units in meters.
"""

from dataclasses import dataclass, field

import numpy as np
from scipy.spatial import ConvexHull

from pipeline.stage1 import (
    ParsedMesh,
    ClassificationGroup,
    CLASSIFICATION_WALL,
    CLASSIFICATION_FLOOR,
    CLASSIFICATION_CEILING,
    CLASSIFICATION_NAMES,
)


# --- Configuration ---

# RANSAC distance thresholds (meters) — how far a point can be from the plane to count as inlier.
DISTANCE_THRESHOLD_DEFAULT = 0.03  # walls, ceiling
DISTANCE_THRESHOLD_FLOOR = 0.05   # floor is noisier from LiDAR reflections

DISTANCE_THRESHOLDS: dict[int, float] = {
    CLASSIFICATION_WALL: DISTANCE_THRESHOLD_DEFAULT,
    CLASSIFICATION_FLOOR: DISTANCE_THRESHOLD_FLOOR,
    CLASSIFICATION_CEILING: DISTANCE_THRESHOLD_DEFAULT,
}

MIN_INLIERS = 50              # absolute minimum inlier count to accept a plane
MIN_INLIER_FRACTION = 0.02    # plane must have >= 2% of the group's original vertices
MAX_RANSAC_ITERATIONS = 1000  # per pass
RESIDUAL_FRACTION = 0.05      # stop when remaining points < 5% of original group

# Merge thresholds — planes with normals within this angle AND offset within this
# distance are considered duplicates. The one with more inliers survives.
MERGE_NORMAL_DOT = 0.95       # cos(~18°) — normals must be nearly parallel
MERGE_DISTANCE_M = 0.10       # planes within 10cm offset are duplicates

# Classifications treated as structural planes (RANSAC).
STRUCTURAL_CLASSES = {CLASSIFICATION_WALL, CLASSIFICATION_FLOOR, CLASSIFICATION_CEILING}

# Classifications treated as discrete objects (OBB).
OBJECT_CLASSES = {4, 5, 6, 7}  # table, seat, door, window


# --- Data classes ---

@dataclass
class DetectedPlane:
    """A planar surface detected by RANSAC within a classification group."""
    classification: str             # "wall", "floor", "ceiling"
    classification_id: int
    normal: np.ndarray              # unit normal [3]
    point_on_plane: np.ndarray      # any inlier centroid [3]
    distance: float                 # d in ax+by+cz+d=0 (signed)
    inlier_vertices: np.ndarray     # Nx3 array of inlier positions
    inlier_count: int
    boundary_polygon: np.ndarray    # Kx2 convex hull vertices projected onto plane
    area_sqm: float                 # area of boundary polygon


@dataclass
class DetectedObject:
    """An object detected as an oriented bounding box via PCA."""
    classification: str             # "table", "seat", "door", "window"
    classification_id: int
    center: np.ndarray              # [3] world position
    dimensions: np.ndarray          # [3] width, height, depth in meters (sorted descending)
    orientation: np.ndarray         # [3x3] rotation matrix (columns = principal axes)
    face_count: int


@dataclass
class PlaneFitResult:
    """Complete output of Stage 2: all detected planes and objects."""
    planes: list[DetectedPlane] = field(default_factory=list)
    objects: list[DetectedObject] = field(default_factory=list)

    @property
    def floor_planes(self) -> list[DetectedPlane]:
        return [p for p in self.planes if p.classification_id == CLASSIFICATION_FLOOR]

    @property
    def ceiling_planes(self) -> list[DetectedPlane]:
        return [p for p in self.planes if p.classification_id == CLASSIFICATION_CEILING]

    @property
    def wall_planes(self) -> list[DetectedPlane]:
        return [p for p in self.planes if p.classification_id == CLASSIFICATION_WALL]


# --- Public API ---

def fit_planes(mesh: ParsedMesh) -> PlaneFitResult:
    """Run Stage 2 plane fitting on a parsed mesh.

    Args:
        mesh: ParsedMesh from Stage 1.

    Returns:
        PlaneFitResult with detected planes and objects.
    """
    result = PlaneFitResult()

    for cls_id, group in mesh.classification_groups.items():
        if cls_id in STRUCTURAL_CLASSES:
            positions = mesh.positions[group.vertex_ids]
            threshold = DISTANCE_THRESHOLDS.get(cls_id, DISTANCE_THRESHOLD_DEFAULT)
            cls_name = CLASSIFICATION_NAMES.get(cls_id, f"unknown_{cls_id}")

            planes = _ransac_multi_plane(positions, cls_id, cls_name, threshold)
            result.planes.extend(planes)

        elif cls_id in OBJECT_CLASSES:
            positions = mesh.positions[group.vertex_ids]
            cls_name = CLASSIFICATION_NAMES.get(cls_id, f"unknown_{cls_id}")

            obj = _compute_obb(positions, cls_id, cls_name, group.face_count)
            if obj is not None:
                result.objects.append(obj)

    # Post-process: merge near-duplicate planes within each classification
    result.planes = _merge_duplicate_planes(result.planes)

    return result


# --- RANSAC Plane Fitting ---

def _ransac_multi_plane(
    positions: np.ndarray,
    cls_id: int,
    cls_name: str,
    threshold: float,
) -> list[DetectedPlane]:
    """Extract multiple planes from a point set using iterative RANSAC.

    After each dominant plane is found, its inliers are removed and RANSAC
    repeats on the residual points. Stops when remaining points < 5% of
    original or no plane exceeds MIN_INLIERS.
    """
    planes: list[DetectedPlane] = []
    remaining = positions.copy()
    original_count = len(positions)
    # Adaptive minimum: at least MIN_INLIERS, or MIN_INLIER_FRACTION of the group
    adaptive_min = max(MIN_INLIERS, int(original_count * MIN_INLIER_FRACTION))
    rng = np.random.default_rng(seed=42)  # deterministic for reproducibility

    while len(remaining) >= adaptive_min:
        if len(remaining) < RESIDUAL_FRACTION * original_count:
            break

        best_normal, best_d, best_inlier_mask = _ransac_single_plane(
            remaining, threshold, rng,
        )

        if best_inlier_mask is None or best_inlier_mask.sum() < adaptive_min:
            break

        inlier_positions = remaining[best_inlier_mask]
        plane = _build_detected_plane(
            inlier_positions, best_normal, best_d, cls_id, cls_name,
        )
        planes.append(plane)

        # Remove inliers from remaining points
        remaining = remaining[~best_inlier_mask]

    return planes


def _ransac_single_plane(
    points: np.ndarray,
    threshold: float,
    rng: np.random.Generator,
) -> tuple[np.ndarray | None, float, np.ndarray | None]:
    """Single RANSAC pass to find the dominant plane in a point set.

    Returns:
        (normal, d, inlier_mask) or (None, 0.0, None) if no valid plane found.
    """
    n_points = len(points)
    if n_points < 3:
        return None, 0.0, None

    best_inlier_count = 0
    best_normal = None
    best_d = 0.0
    best_mask = None

    for _ in range(MAX_RANSAC_ITERATIONS):
        # Sample 3 random points
        idx = rng.choice(n_points, size=3, replace=False)
        p0, p1, p2 = points[idx[0]], points[idx[1]], points[idx[2]]

        # Compute plane normal via cross product
        v1 = p1 - p0
        v2 = p2 - p0
        normal = np.cross(v1, v2)
        norm_len = np.linalg.norm(normal)

        # Skip degenerate (collinear) samples
        if norm_len < 1e-10:
            continue

        normal = normal / norm_len
        d = -np.dot(normal, p0)

        # Count inliers: |ax + by + cz + d| < threshold
        distances = np.abs(points @ normal + d)
        inlier_mask = distances < threshold
        inlier_count = inlier_mask.sum()

        if inlier_count > best_inlier_count:
            best_inlier_count = inlier_count
            best_normal = normal
            best_d = d
            best_mask = inlier_mask

    return best_normal, best_d, best_mask


def _build_detected_plane(
    inlier_positions: np.ndarray,
    normal: np.ndarray,
    d: float,
    cls_id: int,
    cls_name: str,
) -> DetectedPlane:
    """Construct a DetectedPlane from RANSAC results, including boundary polygon and area."""
    centroid = inlier_positions.mean(axis=0)

    # Project inliers onto the plane's 2D coordinate system for convex hull
    boundary_2d, area = _project_and_hull(inlier_positions, normal)

    return DetectedPlane(
        classification=cls_name,
        classification_id=cls_id,
        normal=normal,
        point_on_plane=centroid,
        distance=d,
        inlier_vertices=inlier_positions,
        inlier_count=len(inlier_positions),
        boundary_polygon=boundary_2d,
        area_sqm=area,
    )


def _project_and_hull(
    points: np.ndarray,
    normal: np.ndarray,
) -> tuple[np.ndarray, float]:
    """Project 3D points onto the plane defined by normal, compute 2D convex hull.

    Returns:
        (hull_vertices_2d, area_sqm). If hull fails, returns (empty array, 0.0).
    """
    # Build an orthonormal basis on the plane
    u, v = _plane_basis(normal)

    # Project all points to 2D
    centered = points - points.mean(axis=0)
    coords_2d = np.column_stack([centered @ u, centered @ v])

    try:
        hull = ConvexHull(coords_2d)
        hull_pts = coords_2d[hull.vertices]
        area = float(hull.volume)  # ConvexHull.volume is area in 2D
        return hull_pts, area
    except Exception:
        return np.empty((0, 2)), 0.0


def _plane_basis(normal: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Compute two orthonormal vectors (u, v) perpendicular to normal."""
    # Pick the axis least parallel to normal as seed
    abs_n = np.abs(normal)
    if abs_n[0] <= abs_n[1] and abs_n[0] <= abs_n[2]:
        seed = np.array([1.0, 0.0, 0.0])
    elif abs_n[1] <= abs_n[2]:
        seed = np.array([0.0, 1.0, 0.0])
    else:
        seed = np.array([0.0, 0.0, 1.0])

    u = np.cross(normal, seed)
    u = u / np.linalg.norm(u)
    v = np.cross(normal, u)
    v = v / np.linalg.norm(v)
    return u, v


# --- Plane Deduplication ---

def _merge_duplicate_planes(planes: list[DetectedPlane]) -> list[DetectedPlane]:
    """Merge near-duplicate planes within each classification.

    Two planes are duplicates if their normals are nearly parallel (dot > MERGE_NORMAL_DOT)
    and their offsets are within MERGE_DISTANCE_M. The plane with more inliers survives.
    """
    # Group by classification_id
    by_cls: dict[int, list[DetectedPlane]] = {}
    for p in planes:
        by_cls.setdefault(p.classification_id, []).append(p)

    merged: list[DetectedPlane] = []
    for cls_id, group_planes in by_cls.items():
        # Sort by inlier count descending — dominant planes first
        group_planes.sort(key=lambda p: p.inlier_count, reverse=True)
        kept: list[DetectedPlane] = []

        for candidate in group_planes:
            is_duplicate = False
            for existing in kept:
                # Check if normals are nearly parallel (either direction)
                dot = abs(float(np.dot(candidate.normal, existing.normal)))
                if dot < MERGE_NORMAL_DOT:
                    continue
                # Check if the planes are close together (offset distance)
                # Distance between two parallel planes = |d1 - d2| (if normals point same way)
                # Use point-to-plane distance for robustness
                dist = abs(float(np.dot(existing.normal, candidate.point_on_plane) + existing.distance))
                if dist < MERGE_DISTANCE_M:
                    is_duplicate = True
                    break
            if not is_duplicate:
                kept.append(candidate)

        merged.extend(kept)

    return merged


# --- Object Bounding Box (PCA) ---

def _compute_obb(
    positions: np.ndarray,
    cls_id: int,
    cls_name: str,
    face_count: int,
) -> DetectedObject | None:
    """Compute an oriented bounding box via PCA for an object classification group.

    Returns None if there are fewer than 3 points (degenerate geometry).
    """
    if len(positions) < 3:
        return None

    center = positions.mean(axis=0)
    centered = positions - center

    # PCA via SVD
    _, s, vt = np.linalg.svd(centered, full_matrices=False)
    orientation = vt.T  # columns are principal axes

    # Project points onto principal axes to get extents
    projected = centered @ orientation
    mins = projected.min(axis=0)
    maxs = projected.max(axis=0)
    dimensions = maxs - mins

    # Shift center to the geometric center of the OBB
    obb_center = center + orientation @ ((mins + maxs) / 2.0)

    return DetectedObject(
        classification=cls_name,
        classification_id=cls_id,
        center=obb_center,
        dimensions=dimensions,
        orientation=orientation,
        face_count=face_count,
    )
