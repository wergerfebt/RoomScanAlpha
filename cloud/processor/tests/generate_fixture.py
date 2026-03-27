"""Generate a synthetic binary PLY file representing a simple box room.

Room dimensions: 4m × 2.5m × 3m (width × height × depth)
Floor at Y=0, ceiling at Y=2.5, walls at X=0..4 and Z=0..3.

Each surface is a quad split into 2 triangles with the appropriate
ARKit classification: floor=2, ceiling=3, walls=1.
Adds a small table (classification=4) in the center.

Output matches the iOS PLYExporter binary format exactly.
"""

import struct
import os
import numpy as np


ROOM_WIDTH = 4.0   # X axis
ROOM_HEIGHT = 2.5  # Y axis
ROOM_DEPTH = 3.0   # Z axis

# ARKit classification values
CLASS_NONE = 0
CLASS_WALL = 1
CLASS_FLOOR = 2
CLASS_CEILING = 3
CLASS_TABLE = 4


def generate_box_room_ply(output_path: str, add_table: bool = True, noise_std: float = 0.0,
                          subdivisions: int = 5):
    """Generate a synthetic PLY of a box room with classified surfaces.

    Each surface quad is subdivided into a grid of (subdivisions × subdivisions)
    cells, producing enough vertices for RANSAC plane fitting (min_inliers=50).
    With subdivisions=5, each surface has 36 vertices and 50 triangles.
    """
    vertices = []
    normals = []
    faces = []  # (i0, i1, i2, classification)

    def add_subdivided_quad(p0, p1, p2, p3, normal, classification, n_sub=subdivisions):
        """Subdivide a quad into n_sub × n_sub cells of 2 triangles each."""
        p0, p1, p2, p3 = [np.array(p, dtype=np.float32) for p in [p0, p1, p2, p3]]
        base = len(vertices)
        rows = n_sub + 1
        cols = n_sub + 1
        # Generate grid vertices via bilinear interpolation
        for r in range(rows):
            for c in range(cols):
                u = c / n_sub
                v = r / n_sub
                p = (1 - u) * (1 - v) * p0 + u * (1 - v) * p1 + u * v * p2 + (1 - u) * v * p3
                vertices.append(p.tolist())
                normals.append(normal)
        # Generate triangles
        for r in range(n_sub):
            for c in range(n_sub):
                i00 = base + r * cols + c
                i10 = base + r * cols + (c + 1)
                i01 = base + (r + 1) * cols + c
                i11 = base + (r + 1) * cols + (c + 1)
                faces.append((i00, i10, i11, classification))
                faces.append((i00, i11, i01, classification))

    # Floor (Y=0, normal up)
    add_subdivided_quad(
        [0, 0, 0], [ROOM_WIDTH, 0, 0],
        [ROOM_WIDTH, 0, ROOM_DEPTH], [0, 0, ROOM_DEPTH],
        [0, 1, 0], CLASS_FLOOR,
    )

    # Ceiling (Y=height, normal down)
    add_subdivided_quad(
        [0, ROOM_HEIGHT, ROOM_DEPTH], [ROOM_WIDTH, ROOM_HEIGHT, ROOM_DEPTH],
        [ROOM_WIDTH, ROOM_HEIGHT, 0], [0, ROOM_HEIGHT, 0],
        [0, -1, 0], CLASS_CEILING,
    )

    # Wall: Z=0 (front wall, normal -Z)
    add_subdivided_quad(
        [0, 0, 0], [ROOM_WIDTH, 0, 0],
        [ROOM_WIDTH, ROOM_HEIGHT, 0], [0, ROOM_HEIGHT, 0],
        [0, 0, -1], CLASS_WALL,
    )

    # Wall: Z=depth (back wall, normal +Z)
    add_subdivided_quad(
        [ROOM_WIDTH, 0, ROOM_DEPTH], [0, 0, ROOM_DEPTH],
        [0, ROOM_HEIGHT, ROOM_DEPTH], [ROOM_WIDTH, ROOM_HEIGHT, ROOM_DEPTH],
        [0, 0, 1], CLASS_WALL,
    )

    # Wall: X=0 (left wall, normal -X)
    add_subdivided_quad(
        [0, 0, ROOM_DEPTH], [0, 0, 0],
        [0, ROOM_HEIGHT, 0], [0, ROOM_HEIGHT, ROOM_DEPTH],
        [-1, 0, 0], CLASS_WALL,
    )

    # Wall: X=width (right wall, normal +X)
    add_subdivided_quad(
        [ROOM_WIDTH, 0, 0], [ROOM_WIDTH, 0, ROOM_DEPTH],
        [ROOM_WIDTH, ROOM_HEIGHT, ROOM_DEPTH], [ROOM_WIDTH, ROOM_HEIGHT, 0],
        [1, 0, 0], CLASS_WALL,
    )

    # Table: 1.2m × 0.75m × 0.8m box centered in room
    if add_table:
        tx, ty, tz = ROOM_WIDTH / 2, 0.375, ROOM_DEPTH / 2
        tw, th, td = 0.6, 0.375, 0.4  # half-extents (1.2m × 0.75m × 0.8m)
        # 6 faces of the table box, each subdivided with 2 subdivisions
        # Top
        add_subdivided_quad(
            [tx - tw, ty + th, tz - td], [tx + tw, ty + th, tz - td],
            [tx + tw, ty + th, tz + td], [tx - tw, ty + th, tz + td],
            [0, 1, 0], CLASS_TABLE, n_sub=2,
        )
        # Front
        add_subdivided_quad(
            [tx - tw, ty - th, tz - td], [tx + tw, ty - th, tz - td],
            [tx + tw, ty + th, tz - td], [tx - tw, ty + th, tz - td],
            [0, 0, -1], CLASS_TABLE, n_sub=2,
        )
        # Back
        add_subdivided_quad(
            [tx + tw, ty - th, tz + td], [tx - tw, ty - th, tz + td],
            [tx - tw, ty + th, tz + td], [tx + tw, ty + th, tz + td],
            [0, 0, 1], CLASS_TABLE, n_sub=2,
        )
        # Left
        add_subdivided_quad(
            [tx - tw, ty - th, tz + td], [tx - tw, ty - th, tz - td],
            [tx - tw, ty + th, tz - td], [tx - tw, ty + th, tz + td],
            [-1, 0, 0], CLASS_TABLE, n_sub=2,
        )
        # Right
        add_subdivided_quad(
            [tx + tw, ty - th, tz - td], [tx + tw, ty - th, tz + td],
            [tx + tw, ty + th, tz + td], [tx + tw, ty + th, tz - td],
            [1, 0, 0], CLASS_TABLE, n_sub=2,
        )
        # Bottom
        add_subdivided_quad(
            [tx - tw, ty - th, tz + td], [tx + tw, ty - th, tz + td],
            [tx + tw, ty - th, tz - td], [tx - tw, ty - th, tz - td],
            [0, -1, 0], CLASS_TABLE, n_sub=2,
        )

    # Add noise to vertex positions if requested
    verts_array = np.array(vertices, dtype=np.float32)
    norms_array = np.array(normals, dtype=np.float32)
    if noise_std > 0:
        verts_array += np.random.default_rng(42).normal(0, noise_std, verts_array.shape).astype(np.float32)

    # Write binary PLY
    vertex_count = len(verts_array)
    face_count = len(faces)

    header = (
        "ply\n"
        "format binary_little_endian 1.0\n"
        f"element vertex {vertex_count}\n"
        "property float x\n"
        "property float y\n"
        "property float z\n"
        "property float nx\n"
        "property float ny\n"
        "property float nz\n"
        f"element face {face_count}\n"
        "property list uchar uint vertex_indices\n"
        "property uchar classification\n"
        "end_header\n"
    )

    with open(output_path, "wb") as f:
        f.write(header.encode("ascii"))

        # Vertex data: 6 floats per vertex
        for i in range(vertex_count):
            v = verts_array[i]
            n = norms_array[i]
            f.write(struct.pack("<ffffff", v[0], v[1], v[2], n[0], n[1], n[2]))

        # Face data: 1 byte count + 3 uint32 indices + 1 byte classification
        for i0, i1, i2, classification in faces:
            f.write(struct.pack("<B", 3))
            f.write(struct.pack("<III", i0, i1, i2))
            f.write(struct.pack("<B", classification))

    return {
        "vertex_count": vertex_count,
        "face_count": face_count,
        "room_width": ROOM_WIDTH,
        "room_height": ROOM_HEIGHT,
        "room_depth": ROOM_DEPTH,
    }


if __name__ == "__main__":
    fixture_dir = os.path.dirname(__file__)
    fixtures_path = os.path.join(fixture_dir, "fixtures")
    os.makedirs(fixtures_path, exist_ok=True)

    # Clean room (no noise)
    info = generate_box_room_ply(os.path.join(fixtures_path, "box_room.ply"))
    print(f"Generated box_room.ply: {info}")

    # Noisy room (simulates LiDAR noise)
    info = generate_box_room_ply(
        os.path.join(fixtures_path, "box_room_noisy.ply"),
        noise_std=0.01,
    )
    print(f"Generated box_room_noisy.ply: {info}")
