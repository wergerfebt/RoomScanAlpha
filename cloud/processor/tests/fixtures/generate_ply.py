"""
Generate synthetic binary PLY files for testing Stage 1 parse & classify.

Creates a simple box room (4 walls + floor + ceiling) with correct ARMeshClassification
labels, suitable for verifying the full Stage 1 pipeline.

Room dimensions (meters): 4.0 x 2.5 x 3.0 (width x height x depth)
Origin: floor center at (0, 0, 0), so Y ranges from 0 to 2.5.
"""

import struct
import numpy as np
from pathlib import Path


# ARMeshClassification values
CLASS_WALL = 1
CLASS_FLOOR = 2
CLASS_CEILING = 3


def generate_box_room_ply(
    path: str,
    width: float = 4.0,
    height: float = 2.5,
    depth: float = 3.0,
) -> dict:
    """Write a binary little-endian PLY representing a simple box room.

    The room is axis-aligned with the floor at Y=0 and ceiling at Y=height.
    Each surface (4 walls, floor, ceiling) is 2 triangles with the correct
    ARMeshClassification label.

    Args:
        path: Output file path.
        width: Room width along X axis (meters).
        height: Room height along Y axis (meters).
        depth: Room depth along Z axis (meters).

    Returns:
        Dict with expected values for test assertions:
        {vertex_count, face_count, bbox, floor_normal_y, ceiling_normal_y}
    """
    hw = width / 2.0
    hd = depth / 2.0

    # 8 corners of the box
    corners = np.array([
        [-hw, 0,      -hd],  # 0: floor front-left
        [ hw, 0,      -hd],  # 1: floor front-right
        [ hw, 0,       hd],  # 2: floor back-right
        [-hw, 0,       hd],  # 3: floor back-left
        [-hw, height, -hd],  # 4: ceiling front-left
        [ hw, height, -hd],  # 5: ceiling front-right
        [ hw, height,  hd],  # 6: ceiling back-right
        [-hw, height,  hd],  # 7: ceiling back-left
    ], dtype=np.float32)

    # Define faces as (v0, v1, v2, classification, normal)
    # Normals point inward (into the room)
    face_defs = [
        # Floor (Y=0, normal +Y)
        (0, 2, 1, CLASS_FLOOR,   [0, 1, 0]),
        (0, 3, 2, CLASS_FLOOR,   [0, 1, 0]),
        # Ceiling (Y=height, normal -Y)
        (4, 5, 6, CLASS_CEILING, [0, -1, 0]),
        (4, 6, 7, CLASS_CEILING, [0, -1, 0]),
        # Front wall (Z=-hd, normal +Z)
        (0, 1, 5, CLASS_WALL,    [0, 0, 1]),
        (0, 5, 4, CLASS_WALL,    [0, 0, 1]),
        # Back wall (Z=+hd, normal -Z)
        (2, 3, 7, CLASS_WALL,    [0, 0, -1]),
        (2, 7, 6, CLASS_WALL,    [0, 0, -1]),
        # Left wall (X=-hw, normal +X)
        (0, 4, 7, CLASS_WALL,    [1, 0, 0]),
        (0, 7, 3, CLASS_WALL,    [1, 0, 0]),
        # Right wall (X=+hw, normal -X)
        (1, 2, 6, CLASS_WALL,    [-1, 0, 0]),
        (1, 6, 5, CLASS_WALL,    [-1, 0, 0]),
    ]

    vertex_count = len(corners)
    face_count = len(face_defs)

    # Build vertex data: each vertex gets the normal from the first face that uses it.
    # For simplicity, we duplicate vertices per face so each vertex has one correct normal.
    # Actually, for a box room test the shared vertices make it tricky to assign per-vertex
    # normals. Let's duplicate vertices so each face has its own 3 vertices with correct normals.
    positions = []
    normals = []
    faces = []
    classifications = []

    vi = 0  # running vertex index
    for v0, v1, v2, cls, normal in face_defs:
        positions.extend([corners[v0], corners[v1], corners[v2]])
        normals.extend([normal, normal, normal])
        faces.append((vi, vi + 1, vi + 2, cls))
        classifications.append(cls)
        vi += 3

    vertex_count = len(positions)
    face_count = len(faces)
    positions = np.array(positions, dtype=np.float32)
    normals = np.array(normals, dtype=np.float32)

    _write_ply(path, vertex_count, face_count, positions, normals, faces)

    # Expected values for assertions
    min_pos = positions.min(axis=0)
    max_pos = positions.max(axis=0)
    extents = max_pos - min_pos

    return {
        "vertex_count": vertex_count,
        "face_count": face_count,
        "width": width,
        "height": height,
        "depth": depth,
        "bbox": {
            "min_x": round(float(min_pos[0]), 3),
            "min_y": round(float(min_pos[1]), 3),
            "min_z": round(float(min_pos[2]), 3),
            "max_x": round(float(max_pos[0]), 3),
            "max_y": round(float(max_pos[1]), 3),
            "max_z": round(float(max_pos[2]), 3),
            "x_m": round(float(extents[0]), 3),
            "y_m": round(float(extents[1]), 3),
            "z_m": round(float(extents[2]), 3),
        },
        "wall_face_count": 8,
        "floor_face_count": 2,
        "ceiling_face_count": 2,
    }


CLASS_TABLE = 4
CLASS_SEAT = 5


def generate_dense_box_room_ply(
    path: str,
    width: float = 4.0,
    height: float = 2.5,
    depth: float = 3.0,
    grid_n: int = 10,
) -> dict:
    """Generate a box room where each surface is a grid of triangles.

    Each of the 6 surfaces (4 walls + floor + ceiling) gets a grid_n × grid_n
    quad grid (2 × grid_n² triangles per surface), giving enough vertices
    for RANSAC plane fitting (MIN_INLIERS=50).

    Args:
        path: Output file path.
        width: Room width (X axis, meters).
        height: Room height (Y axis, meters).
        depth: Room depth (Z axis, meters).
        grid_n: Grid subdivisions per surface edge. Total vertices per surface ≈ (grid_n+1)².

    Returns:
        Dict with expected values for test assertions.
    """
    hw = width / 2.0
    hd = depth / 2.0

    positions = []
    normals = []
    faces = []  # (vi0, vi1, vi2, classification)
    vi = 0  # running vertex index

    def _add_grid_surface(origin, axis_u, axis_v, normal_vec, cls):
        """Add a grid_n × grid_n quad grid as 2*grid_n² triangles."""
        nonlocal vi
        base_vi = vi
        # Generate (grid_n+1)² vertices
        for j in range(grid_n + 1):
            for i in range(grid_n + 1):
                u = i / grid_n
                v = j / grid_n
                pos = origin + u * axis_u + v * axis_v
                positions.append(pos.astype(np.float32))
                normals.append(np.array(normal_vec, dtype=np.float32))
        # Generate 2*grid_n² triangles
        stride = grid_n + 1
        for j in range(grid_n):
            for i in range(grid_n):
                tl = base_vi + j * stride + i
                tr = tl + 1
                bl = tl + stride
                br = bl + 1
                faces.append((tl, br, tr, cls))
                faces.append((tl, bl, br, cls))
        vi = base_vi + (grid_n + 1) ** 2

    # Floor (Y=0): spans from (-hw, 0, -hd) along +X and +Z
    _add_grid_surface(
        origin=np.array([-hw, 0.0, -hd]),
        axis_u=np.array([width, 0.0, 0.0]),
        axis_v=np.array([0.0, 0.0, depth]),
        normal_vec=[0, 1, 0],
        cls=CLASS_FLOOR,
    )
    # Ceiling (Y=height): spans from (-hw, height, -hd) along +X and +Z
    _add_grid_surface(
        origin=np.array([-hw, height, -hd]),
        axis_u=np.array([width, 0.0, 0.0]),
        axis_v=np.array([0.0, 0.0, depth]),
        normal_vec=[0, -1, 0],
        cls=CLASS_CEILING,
    )
    # Front wall (Z=-hd): spans from (-hw, 0, -hd) along +X and +Y
    _add_grid_surface(
        origin=np.array([-hw, 0.0, -hd]),
        axis_u=np.array([width, 0.0, 0.0]),
        axis_v=np.array([0.0, height, 0.0]),
        normal_vec=[0, 0, 1],
        cls=CLASS_WALL,
    )
    # Back wall (Z=+hd): spans from (-hw, 0, +hd) along +X and +Y
    _add_grid_surface(
        origin=np.array([-hw, 0.0, hd]),
        axis_u=np.array([width, 0.0, 0.0]),
        axis_v=np.array([0.0, height, 0.0]),
        normal_vec=[0, 0, -1],
        cls=CLASS_WALL,
    )
    # Left wall (X=-hw): spans from (-hw, 0, -hd) along +Z and +Y
    _add_grid_surface(
        origin=np.array([-hw, 0.0, -hd]),
        axis_u=np.array([0.0, 0.0, depth]),
        axis_v=np.array([0.0, height, 0.0]),
        normal_vec=[1, 0, 0],
        cls=CLASS_WALL,
    )
    # Right wall (X=+hw): spans from (+hw, 0, -hd) along +Z and +Y
    _add_grid_surface(
        origin=np.array([hw, 0.0, -hd]),
        axis_u=np.array([0.0, 0.0, depth]),
        axis_v=np.array([0.0, height, 0.0]),
        normal_vec=[-1, 0, 0],
        cls=CLASS_WALL,
    )

    vertex_count = len(positions)
    face_count = len(faces)
    positions_arr = np.array(positions, dtype=np.float32)
    normals_arr = np.array(normals, dtype=np.float32)

    _write_ply(path, vertex_count, face_count, positions_arr, normals_arr, faces)

    faces_per_surface = 2 * grid_n * grid_n

    return {
        "vertex_count": vertex_count,
        "face_count": face_count,
        "width": width,
        "height": height,
        "depth": depth,
        "floor_face_count": faces_per_surface,
        "ceiling_face_count": faces_per_surface,
        "wall_face_count": 4 * faces_per_surface,
    }


def generate_room_with_objects_ply(
    path: str,
    width: float = 4.0,
    height: float = 2.5,
    depth: float = 3.0,
    table_center: tuple[float, float, float] = (0.0, 0.4, 0.0),
    table_size: tuple[float, float, float] = (1.2, 0.8, 0.7),
    seat_center: tuple[float, float, float] = (-1.0, 0.25, 0.0),
    seat_size: tuple[float, float, float] = (0.5, 0.5, 0.5),
) -> dict:
    """Generate a box room PLY with a table and a seat inside.

    Table and seat are axis-aligned boxes with the correct ARMeshClassification labels.

    Returns:
        Dict with expected values including table/seat dimensions and centers.
    """
    hw = width / 2.0
    hd = depth / 2.0

    corners = np.array([
        [-hw, 0,      -hd],
        [ hw, 0,      -hd],
        [ hw, 0,       hd],
        [-hw, 0,       hd],
        [-hw, height, -hd],
        [ hw, height, -hd],
        [ hw, height,  hd],
        [-hw, height,  hd],
    ], dtype=np.float32)

    room_faces = [
        (0, 2, 1, CLASS_FLOOR,   [0, 1, 0]),
        (0, 3, 2, CLASS_FLOOR,   [0, 1, 0]),
        (4, 5, 6, CLASS_CEILING, [0, -1, 0]),
        (4, 6, 7, CLASS_CEILING, [0, -1, 0]),
        (0, 1, 5, CLASS_WALL,    [0, 0, 1]),
        (0, 5, 4, CLASS_WALL,    [0, 0, 1]),
        (2, 3, 7, CLASS_WALL,    [0, 0, -1]),
        (2, 7, 6, CLASS_WALL,    [0, 0, -1]),
        (0, 4, 7, CLASS_WALL,    [1, 0, 0]),
        (0, 7, 3, CLASS_WALL,    [1, 0, 0]),
        (1, 2, 6, CLASS_WALL,    [-1, 0, 0]),
        (1, 6, 5, CLASS_WALL,    [-1, 0, 0]),
    ]

    positions = []
    normals = []
    faces = []
    vi = 0

    for v0, v1, v2, cls, normal in room_faces:
        positions.extend([corners[v0], corners[v1], corners[v2]])
        normals.extend([normal, normal, normal])
        faces.append((vi, vi + 1, vi + 2, cls))
        vi += 3

    def _add_box(center, size, cls):
        """Add an axis-aligned box as 12 triangles (6 faces × 2 tris)."""
        nonlocal vi
        cx, cy, cz = center
        sx, sy, sz = [s / 2.0 for s in size]
        box_corners = np.array([
            [cx - sx, cy - sy, cz - sz],
            [cx + sx, cy - sy, cz - sz],
            [cx + sx, cy - sy, cz + sz],
            [cx - sx, cy - sy, cz + sz],
            [cx - sx, cy + sy, cz - sz],
            [cx + sx, cy + sy, cz - sz],
            [cx + sx, cy + sy, cz + sz],
            [cx - sx, cy + sy, cz + sz],
        ], dtype=np.float32)
        box_faces = [
            (0, 2, 1, [0, -1, 0]),  # bottom
            (0, 3, 2, [0, -1, 0]),
            (4, 5, 6, [0, 1, 0]),   # top
            (4, 6, 7, [0, 1, 0]),
            (0, 1, 5, [0, 0, -1]),  # front
            (0, 5, 4, [0, 0, -1]),
            (2, 3, 7, [0, 0, 1]),   # back
            (2, 7, 6, [0, 0, 1]),
            (0, 4, 7, [-1, 0, 0]),  # left
            (0, 7, 3, [-1, 0, 0]),
            (1, 2, 6, [1, 0, 0]),   # right
            (1, 6, 5, [1, 0, 0]),
        ]
        for bv0, bv1, bv2, normal in box_faces:
            positions.extend([box_corners[bv0], box_corners[bv1], box_corners[bv2]])
            normals.extend([normal, normal, normal])
            faces.append((vi, vi + 1, vi + 2, cls))
            vi += 3

    _add_box(table_center, table_size, CLASS_TABLE)
    _add_box(seat_center, seat_size, CLASS_SEAT)

    vertex_count = len(positions)
    face_count = len(faces)
    positions_arr = np.array(positions, dtype=np.float32)
    normals_arr = np.array(normals, dtype=np.float32)

    _write_ply(path, vertex_count, face_count, positions_arr, normals_arr, faces)

    return {
        "vertex_count": vertex_count,
        "face_count": face_count,
        "width": width,
        "height": height,
        "depth": depth,
        "table_center": np.array(table_center, dtype=np.float32),
        "table_size": np.array(table_size, dtype=np.float32),
        "seat_center": np.array(seat_center, dtype=np.float32),
        "seat_size": np.array(seat_size, dtype=np.float32),
        "table_face_count": 12,
        "seat_face_count": 12,
    }


def _write_ply(
    path: str,
    vertex_count: int,
    face_count: int,
    positions: np.ndarray,
    normals: np.ndarray,
    faces: list[tuple],
) -> None:
    """Write a binary little-endian PLY file."""
    header = (
        f"ply\n"
        f"format binary_little_endian 1.0\n"
        f"element vertex {vertex_count}\n"
        f"property float x\n"
        f"property float y\n"
        f"property float z\n"
        f"property float nx\n"
        f"property float ny\n"
        f"property float nz\n"
        f"element face {face_count}\n"
        f"property list uchar uint vertex_indices\n"
        f"property uchar classification\n"
        f"end_header\n"
    )

    with open(path, "wb") as f:
        f.write(header.encode("ascii"))
        for i in range(vertex_count):
            f.write(struct.pack("<6f",
                positions[i][0], positions[i][1], positions[i][2],
                normals[i][0], normals[i][1], normals[i][2],
            ))
        for v0, v1, v2, cls in faces:
            f.write(struct.pack("<B3IB", 3, v0, v1, v2, cls))


def generate_rotated_dense_room_ply(
    path: str,
    width: float = 5.0,
    height: float = 2.5,
    depth: float = 4.0,
    angle_deg: float = 31.0,
    grid_n: int = 10,
) -> dict:
    """Generate a dense box room rotated by the given angle around Y axis.

    Simulates a real ARKit scan where the room is not axis-aligned.

    Returns:
        Dict with expected values including angle, true width/depth.
    """
    angle_rad = np.radians(angle_deg)
    cos_a = np.cos(angle_rad)
    sin_a = np.sin(angle_rad)

    hw = width / 2.0
    hd = depth / 2.0

    def _rotate_xz(x, z):
        return x * cos_a - z * sin_a, x * sin_a + z * cos_a

    positions = []
    normals_list = []
    faces = []
    vi = 0

    def _add_grid_surface(origin, axis_u, axis_v, normal_vec, cls):
        nonlocal vi
        base_vi = vi
        for j in range(grid_n + 1):
            for i_idx in range(grid_n + 1):
                u = i_idx / grid_n
                v = j / grid_n
                pos = origin + u * axis_u + v * axis_v
                positions.append(pos.astype(np.float32))
                normals_list.append(np.array(normal_vec, dtype=np.float32))
        stride = grid_n + 1
        for j in range(grid_n):
            for i_idx in range(grid_n):
                tl = base_vi + j * stride + i_idx
                tr = tl + 1
                bl = tl + stride
                br = bl + 1
                faces.append((tl, br, tr, cls))
                faces.append((tl, bl, br, cls))
        vi = base_vi + (grid_n + 1) ** 2

    # Rotated axis vectors
    x_axis = np.array([cos_a, 0.0, sin_a])   # rotated +X
    z_axis = np.array([-sin_a, 0.0, cos_a])   # rotated +Z
    y_axis = np.array([0.0, 1.0, 0.0])

    # Room origin (floor center)
    origin = np.array([0.0, 0.0, 0.0])
    corner_fl = origin - hw * x_axis - hd * z_axis  # floor front-left

    # Floor
    _add_grid_surface(corner_fl, width * x_axis, depth * z_axis, [0, 1, 0], CLASS_FLOOR)
    # Ceiling
    _add_grid_surface(corner_fl + height * y_axis, width * x_axis, depth * z_axis, [0, -1, 0], CLASS_CEILING)
    # Front wall (along X at Z=-hd)
    front_normal = z_axis.tolist()
    _add_grid_surface(corner_fl, width * x_axis, height * y_axis, front_normal, CLASS_WALL)
    # Back wall (along X at Z=+hd)
    back_normal = (-z_axis).tolist()
    _add_grid_surface(corner_fl + depth * z_axis, width * x_axis, height * y_axis, back_normal, CLASS_WALL)
    # Left wall (along Z at X=-hw)
    left_normal = x_axis.tolist()
    _add_grid_surface(corner_fl, depth * z_axis, height * y_axis, left_normal, CLASS_WALL)
    # Right wall (along Z at X=+hw)
    right_normal = (-x_axis).tolist()
    _add_grid_surface(corner_fl + width * x_axis, depth * z_axis, height * y_axis, right_normal, CLASS_WALL)

    vertex_count = len(positions)
    face_count = len(faces)
    positions_arr = np.array(positions, dtype=np.float32)
    normals_arr = np.array(normals_list, dtype=np.float32)

    _write_ply(path, vertex_count, face_count, positions_arr, normals_arr, faces)

    # Compute expected corners (rotated rectangle)
    expected_corners = np.array([
        _rotate_xz(-hw, -hd),
        _rotate_xz(+hw, -hd),
        _rotate_xz(+hw, +hd),
        _rotate_xz(-hw, +hd),
    ])

    return {
        "vertex_count": vertex_count,
        "face_count": face_count,
        "width": width,
        "height": height,
        "depth": depth,
        "angle_deg": angle_deg,
        "angle_rad": angle_rad,
        "expected_corners": expected_corners,
    }


if __name__ == "__main__":
    out = Path(__file__).parent / "box_room.ply"
    info = generate_box_room_ply(str(out))
    print(f"Generated {out}")
    print(f"  {info['vertex_count']} vertices, {info['face_count']} faces")
    print(f"  Room: {info['width']}×{info['height']}×{info['depth']}m")
