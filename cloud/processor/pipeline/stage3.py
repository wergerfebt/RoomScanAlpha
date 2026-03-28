"""
Stage 3: Room Geometry Assembly — extract room footprint from floor boundary, extrude walls.

Input:  ParsedMesh from Stage 1, PlaneFitResult from Stage 2
Output: SimplifiedMesh with gap-free walls, floor polygon, and parallel ceiling polygon.

Approach:
  1. Extract floor-classified faces from the mesh
  2. Find boundary edges (edges belonging to only 1 triangle) = room perimeter
  3. Chain boundary edges into polygon loops; take the largest = room outline
  4. Simplify to corner points via Douglas-Peucker
  5. Build floor polygon from corners at floor Y
  6. Build ceiling polygon from SAME corners at ceiling Y (enforced parallelism)
  7. Extrude wall quads between consecutive corners, floor to ceiling

This handles L-shapes, T-shapes, and any floor plan naturally.
Floor and ceiling are always parallel (flat ceiling assumption for MVP).

Coordinate system: ARKit Y-up right-handed (Y=up, -Z=forward). All units in meters.
"""

from dataclasses import dataclass, field

import numpy as np

from pipeline.stage1 import (
    ParsedMesh,
    CLASSIFICATION_NAMES,
    CLASSIFICATION_NONE,
    CLASSIFICATION_WALL,
    CLASSIFICATION_FLOOR,
    CLASSIFICATION_CEILING,
)
from pipeline.stage2 import PlaneFitResult, DetectedPlane

# Alpha shape value for concave hull. Higher = tighter fit (captures internal corners).
# 0.0 = convex hull. Too high fragments into multiple polygons.
ALPHA_SHAPE_VALUE = 0.5

# Douglas-Peucker simplification tolerance (meters).
# Controls how aggressively the boundary polygon is simplified.
# Smaller = more detail, larger = fewer corners.
SIMPLIFY_TOLERANCE = 0.15

# Minimum edge length in the simplified polygon (meters).
# Edges shorter than this are collapsed to remove noise corners.
MIN_EDGE_LENGTH = 0.3


@dataclass
class SimplifiedMesh:
    """Output of Stage 3: simplified room mesh with per-face labels."""
    vertices: np.ndarray
    normals: np.ndarray
    faces: np.ndarray
    uvs: np.ndarray
    face_labels: list[str] = field(default_factory=list)
    surface_map: dict = field(default_factory=dict)


def assemble_geometry(
    plan_result: PlaneFitResult,
    mesh: ParsedMesh | None = None,
    use_dnn: bool = False,
    model_path: str | None = None,
) -> SimplifiedMesh:
    """Build a simplified mesh from the floor boundary polygon extruded to ceiling.

    Args:
        plan_result: PlaneFitResult from Stage 2 (for floor/ceiling Y heights).
        mesh: ParsedMesh from Stage 1 (required — provides classified faces).
        use_dnn: If True, use BEV DNN (RoomFormer) to extract the room polygon.
                 Falls back to geometric extraction if DNN fails.
        model_path: Path to TorchScript model file (optional, uses default if None).

    Returns:
        SimplifiedMesh with gap-free walls, floor, and parallel ceiling.
    """
    if mesh is None:
        raise ValueError("ParsedMesh is required for boundary extraction")
    if not plan_result.floor_planes:
        raise ValueError("no floor plane detected")
    if not plan_result.ceiling_planes:
        raise ValueError("no ceiling plane detected")

    floor_y = float(plan_result.floor_planes[0].point_on_plane[1])
    ceiling_y = float(plan_result.ceiling_planes[0].point_on_plane[1])

    # --- Extract room polygon ---
    corners_xz = None

    if use_dnn:
        try:
            corners_xz = _extract_dnn_polygon(mesh, model_path)
        except Exception as e:
            print(f"[Stage3] DNN exception: {e} — falling back to geometric")
            corners_xz = None

        if corners_xz is not None and len(corners_xz) >= 3:
            print(f"[Stage3] DNN polygon: {len(corners_xz)} corners")
        else:
            print("[Stage3] DNN failed or insufficient corners — falling back to geometric")
            corners_xz = None

    if corners_xz is None:
        corners_xz = _extract_classification_boundary(mesh)

    if len(corners_xz) < 3:
        raise ValueError(f"floor boundary has only {len(corners_xz)} corners, need >= 3")

    # Room center for normal orientation
    room_center_xz = corners_xz.mean(axis=0)
    room_center = np.array([room_center_xz[0], (floor_y + ceiling_y) / 2.0, room_center_xz[1]])
    n_corners = len(corners_xz)

    # Accumulators
    all_verts: list[np.ndarray] = []
    all_normals: list[np.ndarray] = []
    all_uvs: list[np.ndarray] = []
    all_faces: list[np.ndarray] = []
    all_labels: list[str] = []
    surface_map: dict = {}
    vi = 0

    # --- Floor polygon (at floor Y) ---
    vi, _ = _add_horizontal_polygon(
        corners_xz=corners_xz, y=floor_y, normal_y=1.0, label="floor", vi=vi,
        all_verts=all_verts, all_normals=all_normals, all_uvs=all_uvs,
        all_faces=all_faces, all_labels=all_labels,
    )
    floor_area = _polygon_area(corners_xz)
    surface_map["floor"] = {
        "plane": plan_result.floor_planes[0],
        "area_sqm": round(floor_area, 2),
        "material_id": None,
    }

    # --- Ceiling polygon (SAME corners at ceiling Y — enforced parallelism) ---
    vi, _ = _add_horizontal_polygon(
        corners_xz=corners_xz, y=ceiling_y, normal_y=-1.0, label="ceiling", vi=vi,
        all_verts=all_verts, all_normals=all_normals, all_uvs=all_uvs,
        all_faces=all_faces, all_labels=all_labels,
    )
    surface_map["ceiling"] = {
        "plane": plan_result.ceiling_planes[0],
        "area_sqm": round(floor_area, 2),  # parallel → same area
        "material_id": None,
    }

    # --- Wall quads (extrude each polygon edge floor to ceiling) ---
    door_positions = _get_door_positions(mesh)

    for i in range(n_corners):
        j = (i + 1) % n_corners
        p0_xz = corners_xz[i]
        p1_xz = corners_xz[j]

        label = f"wall_{i}"
        vi, wall_area = _add_wall_quad(
            p0_xz=p0_xz, p1_xz=p1_xz, floor_y=floor_y, ceiling_y=ceiling_y,
            room_center=room_center, label=label, vi=vi,
            all_verts=all_verts, all_normals=all_normals, all_uvs=all_uvs,
            all_faces=all_faces, all_labels=all_labels,
        )

        has_door = _wall_has_door(p0_xz, p1_xz, door_positions)
        surface_map[label] = {
            "area_sqm": round(wall_area, 2),
            "material_id": None,
            "has_door": has_door,
        }

    # --- Merge ---
    vertices = np.vstack(all_verts).astype(np.float32)
    normals_arr = np.vstack(all_normals).astype(np.float32)
    uvs = np.vstack(all_uvs).astype(np.float32)
    faces = np.vstack(all_faces).astype(np.uint32)

    return SimplifiedMesh(
        vertices=vertices, normals=normals_arr, faces=faces, uvs=uvs,
        face_labels=all_labels, surface_map=surface_map,
    )


# --- DNN Polygon Extraction ---

def _extract_dnn_polygon(
    mesh: ParsedMesh,
    model_path: str | None = None,
) -> np.ndarray | None:
    """Extract room polygon using BEV DNN (RoomFormer).

    How it works:
      1. Project mesh vertices to a 256x256 bird's-eye-view density map
         (top-down view where walls appear as bright lines)
      2. Run the RoomFormer neural network, which predicts room corner positions
      3. Convert predicted pixel coordinates back to real-world XZ meters

    The 256x256 resolution matches RoomFormer's training data (Structured3D).
    Using a different resolution would require retraining the model.

    Args:
        mesh: ParsedMesh from Stage 1 with classified vertices.
        model_path: Path to TorchScript .pt model file. If None, uses the
                     default location: cloud/processor/models/roomformer_s3d.pt

    Returns:
        Kx2 array of XZ corner positions (meters) in CCW order,
        or None if the DNN fails or produces an invalid polygon.
        Callers must handle the None case (typically by falling back
        to geometric extraction).
    """
    try:
        from pipeline.bev_projection import project_to_bev, pixels_to_meters
        from pipeline.bev_inference import predict_room_polygon

        bev = project_to_bev(mesh, resolution=256, structural_only=True)

        result = predict_room_polygon(bev, model_path=model_path)

        if not result.success or result.num_corners < 3:
            return None

        # Convert pixel corners to XZ meters
        corners_xz = pixels_to_meters(result.corners_px, bev)

        # Ensure CCW winding
        signed_area = _polygon_signed_area(corners_xz)
        if signed_area < 0:
            corners_xz = corners_xz[::-1].copy()

        return corners_xz

    except Exception as e:
        print(f"[Stage3] DNN extraction error: {e}")
        return None


# --- Classification Boundary Extraction ---

def _extract_classification_boundary(mesh: ParsedMesh) -> np.ndarray:
    """Extract the room footprint from where ceiling meets walls.

    Finds edges shared between ceiling-classified and wall-classified faces.
    These trace the ceiling-wall junction — the cleanest room perimeter because
    the ceiling is rarely occluded by furniture.

    Falls back to floor-wall boundary, then to ceiling convex hull.

    Returns:
        Kx2 array of simplified XZ corner positions, ordered CCW.
    """
    # Find where ceiling meets structural surfaces (wall + door + window).
    # Excludes ceiling-none edges (cabinets/furniture against walls) which
    # would pull the boundary inward to the cabinet face.
    boundary_verts = _find_ceiling_structural_boundary(mesh)

    # Fallback: ceiling-wall only
    if len(boundary_verts) < 10:
        boundary_verts = _find_cross_classification_edges(
            mesh, CLASSIFICATION_CEILING, CLASSIFICATION_WALL
        )

    if len(boundary_verts) < 3:
        return np.empty((0, 2))

    # Project boundary vertices to XZ
    boundary_xz = mesh.positions[list(boundary_verts)][:, [0, 2]]

    # Use alpha shape (concave hull) to trace the room perimeter
    # This captures internal corners that convex hull would bridge
    import alphashape
    shape = alphashape.alphashape(boundary_xz, ALPHA_SHAPE_VALUE)

    # If alpha shape fragments, fall back to less aggressive alpha, then convex hull
    if not hasattr(shape, 'exterior'):
        shape = alphashape.alphashape(boundary_xz, ALPHA_SHAPE_VALUE / 2)
    if not hasattr(shape, 'exterior'):
        shape = alphashape.alphashape(boundary_xz, 0.0)  # convex hull fallback
    if not hasattr(shape, 'exterior'):
        return np.empty((0, 2))

    # Extract ordered boundary coordinates (remove closing duplicate)
    loop_xz = np.array(shape.exterior.coords)[:-1].astype(np.float64)

    if len(loop_xz) < 3:
        return np.empty((0, 2))

    # Simplify the closed polygon with Douglas-Peucker
    simplified = _simplify_closed_polygon(loop_xz, SIMPLIFY_TOLERANCE)

    # Remove short edges
    simplified = _remove_short_edges(simplified, MIN_EDGE_LENGTH)

    if len(simplified) < 3:
        return np.empty((0, 2))

    # Ensure CCW winding
    if _polygon_signed_area(simplified) < 0:
        simplified = simplified[::-1]

    return simplified


def _find_ceiling_structural_boundary(mesh: ParsedMesh) -> set[int]:
    """Find vertices where ceiling faces share edges with structural surfaces.

    Structural surfaces = wall (1) + door (6) + window (7).
    Excludes none/cabinet (0) which would pull the boundary to furniture faces.
    """
    STRUCTURAL_IDS = {CLASSIFICATION_WALL, 6, 7}  # wall, door, window
    edge_classes: dict[tuple[int, int], set[int]] = {}

    for fi in range(mesh.face_count):
        cls = int(mesh.face_classifications[fi])
        if cls != CLASSIFICATION_CEILING and cls not in STRUCTURAL_IDS:
            continue
        face = mesh.faces[fi]
        for k in range(3):
            v0, v1 = int(face[k]), int(face[(k + 1) % 3])
            edge = (min(v0, v1), max(v0, v1))
            edge_classes.setdefault(edge, set()).add(cls)

    boundary_verts: set[int] = set()
    for (v0, v1), classes in edge_classes.items():
        if CLASSIFICATION_CEILING in classes and classes & STRUCTURAL_IDS:
            boundary_verts.add(v0)
            boundary_verts.add(v1)

    return boundary_verts


def _find_cross_classification_boundary_edges(
    mesh: ParsedMesh,
    class_a: int,
    class_b: int,
) -> list[tuple[int, int]]:
    """Find edges shared between faces of two different classifications.

    Returns list of (v0, v1) edge tuples for chaining into loops.
    """
    edge_classes: dict[tuple[int, int], set[int]] = {}
    for fi in range(mesh.face_count):
        cls = int(mesh.face_classifications[fi])
        if cls != class_a and cls != class_b:
            continue
        face = mesh.faces[fi]
        for k in range(3):
            v0, v1 = int(face[k]), int(face[(k + 1) % 3])
            edge = (min(v0, v1), max(v0, v1))
            edge_classes.setdefault(edge, set()).add(cls)

    return [e for e, classes in edge_classes.items()
            if class_a in classes and class_b in classes]


def _find_cross_classification_edges(
    mesh: ParsedMesh,
    class_a: int,
    class_b: int,
) -> set[int]:
    """Find vertices on edges shared between faces of two different classifications.

    Returns the set of vertex indices that lie on the boundary between class_a and class_b.
    """
    # Build edge → set of classifications touching it
    edge_classes: dict[tuple[int, int], set[int]] = {}
    for fi in range(mesh.face_count):
        cls = int(mesh.face_classifications[fi])
        if cls != class_a and cls != class_b:
            continue
        face = mesh.faces[fi]
        for k in range(3):
            v0, v1 = int(face[k]), int(face[(k + 1) % 3])
            edge = (min(v0, v1), max(v0, v1))
            edge_classes.setdefault(edge, set()).add(cls)

    # Collect vertices on boundary edges (edges touching both classifications)
    boundary_verts: set[int] = set()
    for (v0, v1), classes in edge_classes.items():
        if class_a in classes and class_b in classes:
            boundary_verts.add(v0)
            boundary_verts.add(v1)

    return boundary_verts


def _chain_edges(edges: list[tuple[int, int]]) -> list[list[int]]:
    """Chain boundary edges into ordered vertex loops."""
    # Build adjacency: vertex → set of connected vertices
    adj: dict[int, list[int]] = {}
    for v0, v1 in edges:
        adj.setdefault(v0, []).append(v1)
        adj.setdefault(v1, []).append(v0)

    visited_edges = set()
    loops = []

    for start in adj:
        if all((min(start, n), max(start, n)) in visited_edges for n in adj[start]):
            continue

        loop = [start]
        current = start
        prev = -1

        while True:
            neighbors = adj.get(current, [])
            next_v = None
            for n in neighbors:
                edge = (min(current, n), max(current, n))
                if edge not in visited_edges and n != prev:
                    next_v = n
                    break

            if next_v is None:
                break

            visited_edges.add((min(current, next_v), max(current, next_v)))
            if next_v == start:
                break  # closed loop

            loop.append(next_v)
            prev = current
            current = next_v

        if len(loop) >= 3:
            loops.append(loop)

    return loops


def _simplify_closed_polygon(points: np.ndarray, tolerance: float) -> np.ndarray:
    """Simplify a closed polygon using Douglas-Peucker on each half.

    Standard DP fails on closed polygons because start==end makes the
    reference line zero-length. Instead, split the polygon at the two
    farthest-apart points and simplify each half independently.
    """
    n = len(points)
    if n <= 4:
        return points

    # Find the two points farthest apart (polygon diameter)
    max_dist = 0.0
    split_a, split_b = 0, n // 2
    for i in range(n):
        for j in range(i + 1, n):
            d = np.linalg.norm(points[i] - points[j])
            if d > max_dist:
                max_dist = d
                split_a, split_b = i, j

    # Ensure split_a < split_b
    if split_a > split_b:
        split_a, split_b = split_b, split_a

    # Split into two halves and simplify each
    half1 = points[split_a:split_b + 1]
    half2 = np.vstack([points[split_b:], points[:split_a + 1]])

    simp1 = _douglas_peucker(half1, tolerance)
    simp2 = _douglas_peucker(half2, tolerance)

    # Merge (remove duplicate junction points)
    result = np.vstack([simp1, simp2[1:-1]]) if len(simp2) > 2 else simp1
    return result


def _douglas_peucker(points: np.ndarray, tolerance: float) -> np.ndarray:
    """Simplify a polygon using the Douglas-Peucker algorithm."""
    if len(points) <= 3:
        return points

    # Find the point farthest from the line between first and last
    start = points[0]
    end = points[-1]
    line_vec = end - start
    line_len = np.linalg.norm(line_vec)

    if line_len < 1e-10:
        return points[[0]]

    line_dir = line_vec / line_len

    # Perpendicular distances
    vecs = points - start
    along = vecs @ line_dir
    projections = start + np.outer(along, line_dir)
    distances = np.linalg.norm(points - projections, axis=1)

    max_idx = int(np.argmax(distances))
    max_dist = distances[max_idx]

    if max_dist > tolerance:
        # Recursively simplify both halves
        left = _douglas_peucker(points[:max_idx + 1], tolerance)
        right = _douglas_peucker(points[max_idx:], tolerance)
        return np.vstack([left[:-1], right])
    else:
        return points[[0, -1]]


def _remove_short_edges(points: np.ndarray, min_length: float) -> np.ndarray:
    """Remove points that create edges shorter than min_length."""
    if len(points) <= 3:
        return points

    kept = [0]
    for i in range(1, len(points)):
        dist = np.linalg.norm(points[i] - points[kept[-1]])
        if dist >= min_length:
            kept.append(i)

    # Check last-to-first edge
    if len(kept) > 1:
        dist = np.linalg.norm(points[kept[0]] - points[kept[-1]])
        if dist < min_length:
            kept = kept[:-1]

    return points[kept] if len(kept) >= 3 else points


def _polygon_signed_area(points: np.ndarray) -> float:
    """Compute signed area of a 2D polygon (positive = CCW)."""
    n = len(points)
    area = 0.0
    for i in range(n):
        j = (i + 1) % n
        area += points[i][0] * points[j][1]
        area -= points[j][0] * points[i][1]
    return area / 2.0


def _polygon_area(points: np.ndarray) -> float:
    """Compute unsigned area of a 2D polygon."""
    return abs(_polygon_signed_area(points))


# --- Door Detection ---

def _get_door_positions(mesh: ParsedMesh) -> list[np.ndarray]:
    """Get XZ centroid positions of door-classified face clusters."""
    door_cls_id = 6
    if door_cls_id not in mesh.classification_groups:
        return []

    group = mesh.classification_groups[door_cls_id]
    door_verts = mesh.positions[group.vertex_ids]
    if len(door_verts) == 0:
        return []

    # Cluster door vertices by XZ proximity (simple: split by large gaps)
    door_xz = door_verts[:, [0, 2]]
    centroids = [door_xz.mean(axis=0)]  # TODO: proper clustering for multiple doors
    return centroids


def _wall_has_door(
    p0_xz: np.ndarray,
    p1_xz: np.ndarray,
    door_positions: list[np.ndarray],
    threshold: float = 0.5,
) -> bool:
    """Check if any door position is close to this wall segment."""
    if not door_positions:
        return False

    wall_vec = p1_xz - p0_xz
    wall_len = np.linalg.norm(wall_vec)
    if wall_len < 1e-6:
        return False

    wall_dir = wall_vec / wall_len

    for door_xz in door_positions:
        to_door = door_xz - p0_xz
        along = float(np.dot(to_door, wall_dir))
        if along < -threshold or along > wall_len + threshold:
            continue
        perp = abs(float(to_door[0] * (-wall_dir[1]) + to_door[1] * wall_dir[0]))
        if perp < threshold:
            return True
    return False


# --- Horizontal Polygon (floor / ceiling) ---

def _add_horizontal_polygon(
    corners_xz: np.ndarray,
    y: float,
    normal_y: float,
    label: str,
    vi: int,
    all_verts: list,
    all_normals: list,
    all_uvs: list,
    all_faces: list,
    all_labels: list,
) -> tuple[int, int]:
    """Triangulate a convex/concave polygon at a given Y height using fan triangulation."""
    n = len(corners_xz)
    normal = np.array([0.0, normal_y, 0.0], dtype=np.float32)

    verts = np.zeros((n, 3), dtype=np.float32)
    verts[:, 0] = corners_xz[:, 0]
    verts[:, 1] = y
    verts[:, 2] = corners_xz[:, 1]

    norms = np.tile(normal, (n, 1))

    xz_min = corners_xz.min(axis=0)
    xz_max = corners_xz.max(axis=0)
    xz_range = xz_max - xz_min
    xz_range[xz_range < 1e-6] = 1.0
    uvs = (corners_xz - xz_min) / xz_range

    n_tris = n - 2
    tris = np.zeros((n_tris, 3), dtype=np.uint32)
    for i in range(n_tris):
        if normal_y > 0:
            tris[i] = [vi, vi + i + 1, vi + i + 2]
        else:
            tris[i] = [vi, vi + i + 2, vi + i + 1]

    all_verts.append(verts)
    all_normals.append(norms)
    all_uvs.append(uvs)
    all_faces.append(tris)
    all_labels.extend([label] * n_tris)

    return vi + n, n_tris


# --- Wall Quads ---

def _add_wall_quad(
    p0_xz: np.ndarray,
    p1_xz: np.ndarray,
    floor_y: float,
    ceiling_y: float,
    room_center: np.ndarray,
    label: str,
    vi: int,
    all_verts: list,
    all_normals: list,
    all_uvs: list,
    all_faces: list,
    all_labels: list,
) -> tuple[int, float]:
    """Add a wall quad spanning floor to ceiling, with inward-facing normal."""
    bl = np.array([p0_xz[0], floor_y, p0_xz[1]], dtype=np.float32)
    br = np.array([p1_xz[0], floor_y, p1_xz[1]], dtype=np.float32)
    tl = np.array([p0_xz[0], ceiling_y, p0_xz[1]], dtype=np.float32)
    tr = np.array([p1_xz[0], ceiling_y, p1_xz[1]], dtype=np.float32)

    edge = br - bl
    wall_normal = np.array([-edge[2], 0.0, edge[0]], dtype=np.float32)
    norm_len = np.linalg.norm(wall_normal)
    if norm_len > 1e-10:
        wall_normal /= norm_len

    wall_mid = (bl + br + tl + tr) / 4.0
    to_center = room_center - wall_mid
    if np.dot(wall_normal, to_center) < 0:
        wall_normal = -wall_normal

    verts = np.array([bl, br, tr, tl], dtype=np.float32)
    norms = np.tile(wall_normal, (4, 1))
    uvs = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], dtype=np.float32)

    tris = np.array([
        [vi, vi + 1, vi + 2],
        [vi, vi + 2, vi + 3],
    ], dtype=np.uint32)

    all_verts.append(verts)
    all_normals.append(norms)
    all_uvs.append(uvs)
    all_faces.append(tris)
    all_labels.extend([label, label])

    width = float(np.linalg.norm(br - bl))
    return vi + 4, width * (ceiling_y - floor_y)
