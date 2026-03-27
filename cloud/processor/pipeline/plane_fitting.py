"""Stage 2: RANSAC plane fitting on classified face groups.

For each surface classification (wall, floor, ceiling), iteratively fits planes
using RANSAC. For object classifications (table, seat, door, window), computes
oriented bounding boxes via PCA.
"""

from dataclasses import dataclass
import numpy as np


@dataclass
class DetectedPlane:
    classification: str         # "wall", "floor", "ceiling"
    normal: np.ndarray          # unit normal [3]
    point_on_plane: np.ndarray  # any inlier point [3]
    distance: float             # d in ax+by+cz+d=0 (signed distance from origin)
    inlier_vertices: np.ndarray  # (K, 3) array of inlier positions
    area_sqm: float             # area of convex hull on plane


@dataclass
class DetectedObject:
    classification: str         # "table", "seat", "door", "window"
    center: np.ndarray          # [3] world position
    dimensions: np.ndarray      # [3] width, height, depth in meters
    orientation: np.ndarray     # [3, 3] rotation matrix from PCA
    face_count: int


@dataclass
class PlaneResult:
    planes: list[DetectedPlane]
    objects: list[DetectedObject]


# Thresholds
DISTANCE_THRESHOLDS = {
    "wall": 0.03,
    "floor": 0.05,
    "ceiling": 0.03,
}
DEFAULT_DISTANCE_THRESHOLD = 0.05
MIN_INLIERS = 50
MAX_ITERATIONS = 1000
RESIDUAL_FRACTION = 0.05  # stop when < 5% of points remain


def fit_planes(
    vertices: np.ndarray,
    normals: np.ndarray,
    classification: str,
    distance_threshold: float | None = None,
    min_inliers: int = MIN_INLIERS,
    max_iterations: int = MAX_ITERATIONS,
    rng: np.random.Generator | None = None,
) -> list[DetectedPlane]:
    """Iteratively fit planes to a set of vertices using RANSAC.

    Finds the dominant plane, removes its inliers, and repeats until
    the remaining points are below the residual threshold or no plane
    with enough inliers can be found.

    Args:
        vertices: (N, 3) array of vertex positions for one classification group.
        normals: (N, 3) array of vertex normals (used for validation, not fitting).
        classification: "wall", "floor", or "ceiling".
        distance_threshold: Max distance from plane for a point to be an inlier.
        min_inliers: Minimum inlier count for a plane to be accepted.
        max_iterations: RANSAC iterations per plane.
        rng: NumPy random generator (for reproducible tests).

    Returns:
        List of DetectedPlane objects, ordered by inlier count (largest first).
    """
    if rng is None:
        rng = np.random.default_rng()

    if distance_threshold is None:
        distance_threshold = DISTANCE_THRESHOLDS.get(
            classification, DEFAULT_DISTANCE_THRESHOLD
        )

    planes = []
    remaining = vertices.copy()
    # For small groups (e.g., a single floor with 36 vertices), scale down
    # min_inliers so we don't reject valid planes from sparse classification groups.
    # Scale down for sparse groups. Divide by 4 because a group (e.g., "wall")
    # may contain multiple distinct planes, each with 1/4 of the total vertices.
    effective_min_inliers = min(min_inliers, max(3, len(vertices) // 4))
    min_remaining = max(int(len(vertices) * RESIDUAL_FRACTION), effective_min_inliers)

    while len(remaining) >= min_remaining:
        result = _ransac_plane(
            remaining, distance_threshold, max_iterations, rng
        )
        if result is None or int(result[2].sum()) < effective_min_inliers:
            break

        normal, point, inlier_mask = result
        inlier_points = remaining[inlier_mask]

        area = _convex_hull_area_on_plane(inlier_points, normal)
        d = -float(np.dot(normal, point))

        planes.append(DetectedPlane(
            classification=classification,
            normal=normal,
            point_on_plane=point,
            distance=d,
            inlier_vertices=inlier_points,
            area_sqm=area,
        ))

        # Remove inliers
        remaining = remaining[~inlier_mask]

    return planes


def fit_object_bounding_box(
    vertices: np.ndarray,
    classification: str,
) -> DetectedObject | None:
    """Compute an oriented bounding box for object-classified vertices using PCA.

    Returns None if fewer than 4 vertices are provided.
    """
    if len(vertices) < 4:
        return None

    center = vertices.mean(axis=0)
    centered = vertices - center

    # PCA via covariance matrix eigenvectors
    cov = np.cov(centered.T)
    eigenvalues, eigenvectors = np.linalg.eigh(cov)
    # Sort by eigenvalue descending
    order = np.argsort(eigenvalues)[::-1]
    eigenvectors = eigenvectors[:, order]

    # Project onto principal axes to get extents
    projected = centered @ eigenvectors
    dims = projected.max(axis=0) - projected.min(axis=0)

    return DetectedObject(
        classification=classification,
        center=center,
        dimensions=dims,
        orientation=eigenvectors,
        face_count=0,  # set by caller if needed
    )


def plane_distance(plane: DetectedPlane, point: np.ndarray) -> float:
    """Signed perpendicular distance from a point to a plane."""
    return float(np.dot(plane.normal, point) + plane.distance)


def ceiling_height(floor_plane: DetectedPlane, ceiling_plane: DetectedPlane) -> float:
    """Perpendicular distance between floor and ceiling planes in meters."""
    floor_y = -floor_plane.distance / floor_plane.normal[1] if abs(floor_plane.normal[1]) > 0.01 else 0
    ceiling_y = -ceiling_plane.distance / ceiling_plane.normal[1] if abs(ceiling_plane.normal[1]) > 0.01 else 0
    return abs(ceiling_y - floor_y)


def _ransac_plane(
    points: np.ndarray,
    threshold: float,
    max_iterations: int,
    rng: np.random.Generator,
) -> tuple[np.ndarray, np.ndarray, np.ndarray] | None:
    """Single RANSAC pass: find the dominant plane in a point set.

    Returns (normal, point_on_plane, inlier_mask) or None if no plane found.
    """
    n_points = len(points)
    if n_points < 3:
        return None

    best_inlier_mask = None
    best_count = 0

    for _ in range(max_iterations):
        # Sample 3 random points
        idx = rng.choice(n_points, size=3, replace=False)
        p0, p1, p2 = points[idx]

        # Compute plane normal via cross product
        v1 = p1 - p0
        v2 = p2 - p0
        normal = np.cross(v1, v2)
        norm_len = np.linalg.norm(normal)
        if norm_len < 1e-10:
            continue  # collinear points
        normal = normal / norm_len

        # Distance from all points to this plane
        dists = np.abs((points - p0) @ normal)
        inlier_mask = dists < threshold
        count = int(inlier_mask.sum())

        if count > best_count:
            best_count = count
            best_inlier_mask = inlier_mask
            best_point = p0.copy()
            best_normal = normal.copy()

    if best_inlier_mask is None:
        return None

    # Refine normal using all inliers (least-squares refit)
    inlier_points = points[best_inlier_mask]
    centroid = inlier_points.mean(axis=0)
    centered = inlier_points - centroid
    _, _, vh = np.linalg.svd(centered)
    refined_normal = vh[-1]  # smallest singular value = plane normal

    # Ensure consistent normal direction
    if np.dot(refined_normal, best_normal) < 0:
        refined_normal = -refined_normal

    # Recompute inliers with refined normal
    dists = np.abs((points - centroid) @ refined_normal)
    refined_mask = dists < threshold

    return refined_normal, centroid, refined_mask


def _convex_hull_area_on_plane(points: np.ndarray, normal: np.ndarray) -> float:
    """Project points onto the plane and compute 2D convex hull area."""
    if len(points) < 3:
        return 0.0

    # Build 2D coordinate system on the plane
    centroid = points.mean(axis=0)
    centered = points - centroid

    # Find two orthogonal axes on the plane
    u = _orthogonal_vector(normal)
    v = np.cross(normal, u)
    v = v / np.linalg.norm(v)

    # Project to 2D
    coords_2d = np.column_stack([centered @ u, centered @ v])

    try:
        from scipy.spatial import ConvexHull
        hull = ConvexHull(coords_2d)
        return float(hull.volume)  # in 2D, volume = area
    except Exception:
        return 0.0


def _orthogonal_vector(v: np.ndarray) -> np.ndarray:
    """Find a unit vector orthogonal to v."""
    if abs(v[0]) < 0.9:
        candidate = np.array([1.0, 0.0, 0.0])
    else:
        candidate = np.array([0.0, 1.0, 0.0])
    u = np.cross(v, candidate)
    return u / np.linalg.norm(u)
