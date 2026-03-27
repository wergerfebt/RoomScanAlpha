"""Stage 1: Parse binary PLY files and group faces by ARKit classification.

Reads the binary little-endian PLY format exported by the iOS app's PLYExporter.
Vertices are 6 floats (x, y, z, nx, ny, nz).
Faces are: 1 byte count (always 3) + 3 uint32 indices + 1 uint8 classification.

Classification values follow ARMeshClassification:
    0=none, 1=wall, 2=floor, 3=ceiling, 4=table, 5=seat, 6=door, 7=window
"""

from dataclasses import dataclass, field
import numpy as np

CLASSIFICATION_NAMES = {
    0: "none",
    1: "wall",
    2: "floor",
    3: "ceiling",
    4: "table",
    5: "seat",
    6: "door",
    7: "window",
}


@dataclass
class ParsedPLY:
    vertices: np.ndarray          # (N, 3) float32 — world-space positions
    normals: np.ndarray           # (N, 3) float32 — world-space normals
    face_indices: np.ndarray      # (M, 3) uint32 — triangle vertex indices
    face_classifications: np.ndarray  # (M,) uint8 — per-face classification
    classification_groups: dict = field(default_factory=dict)
    # { classification_id: np.ndarray of face indices into face_indices }


def parse_ply(ply_path: str) -> ParsedPLY:
    """Parse a binary little-endian PLY file into structured arrays."""
    with open(ply_path, "rb") as f:
        header_lines, vertex_count, face_count = _read_header(f)

        # Read vertex data: N × 6 floats (x, y, z, nx, ny, nz)
        vertex_bytes = vertex_count * 6 * 4
        vertex_data = np.frombuffer(f.read(vertex_bytes), dtype=np.float32)
        vertex_data = vertex_data.reshape(vertex_count, 6)

        vertices = vertex_data[:, :3].copy()
        normals = vertex_data[:, :3].copy()
        normals = vertex_data[:, 3:6].copy()

        # Read face data: M × 14 bytes each
        # [1 byte count] [3 × 4 byte uint32 indices] [1 byte classification]
        face_indices = np.zeros((face_count, 3), dtype=np.uint32)
        face_classifications = np.zeros(face_count, dtype=np.uint8)

        for i in range(face_count):
            count_byte = np.frombuffer(f.read(1), dtype=np.uint8)[0]
            if count_byte != 3:
                raise ValueError(
                    f"Face {i}: expected 3 vertices, got {count_byte}"
                )
            indices = np.frombuffer(f.read(12), dtype=np.uint32)
            face_indices[i] = indices
            face_classifications[i] = np.frombuffer(f.read(1), dtype=np.uint8)[0]

    # Group faces by classification
    classification_groups = {}
    for class_id in np.unique(face_classifications):
        mask = face_classifications == class_id
        classification_groups[int(class_id)] = np.where(mask)[0]

    return ParsedPLY(
        vertices=vertices,
        normals=normals,
        face_indices=face_indices,
        face_classifications=face_classifications,
        classification_groups=classification_groups,
    )


def vertices_for_group(parsed: ParsedPLY, classification_id: int) -> np.ndarray:
    """Get unique vertices belonging to faces of the given classification.

    Returns (K, 3) float32 array of vertex positions.
    """
    if classification_id not in parsed.classification_groups:
        return np.zeros((0, 3), dtype=np.float32)
    group_face_indices = parsed.classification_groups[classification_id]
    vertex_ids = np.unique(parsed.face_indices[group_face_indices].flatten())
    return parsed.vertices[vertex_ids]


def normals_for_group(parsed: ParsedPLY, classification_id: int) -> np.ndarray:
    """Get normals for vertices belonging to faces of the given classification.

    Returns (K, 3) float32 array of vertex normals.
    """
    if classification_id not in parsed.classification_groups:
        return np.zeros((0, 3), dtype=np.float32)
    group_face_indices = parsed.classification_groups[classification_id]
    vertex_ids = np.unique(parsed.face_indices[group_face_indices].flatten())
    return parsed.normals[vertex_ids]


def bounding_box(vertices: np.ndarray) -> dict:
    """Compute axis-aligned bounding box from (N, 3) vertices."""
    if len(vertices) == 0:
        return {"bbox_x": 0, "bbox_y": 0, "bbox_z": 0}
    min_pos = vertices.min(axis=0)
    max_pos = vertices.max(axis=0)
    extents = max_pos - min_pos
    return {
        "bbox_x": round(float(extents[0]), 3),
        "bbox_y": round(float(extents[1]), 3),
        "bbox_z": round(float(extents[2]), 3),
        "min_x": round(float(min_pos[0]), 3),
        "min_y": round(float(min_pos[1]), 3),
        "min_z": round(float(min_pos[2]), 3),
        "max_x": round(float(max_pos[0]), 3),
        "max_y": round(float(max_pos[1]), 3),
        "max_z": round(float(max_pos[2]), 3),
    }


def _read_header(f) -> tuple:
    """Read PLY header, return (header_lines, vertex_count, face_count)."""
    header_lines = []
    vertex_count = 0
    face_count = 0

    while True:
        line = f.readline()
        if not line:
            raise ValueError("Unexpected end of file in PLY header")
        decoded = line.decode("ascii", errors="replace").strip()
        header_lines.append(decoded)
        if decoded == "end_header":
            break
        if len(b"".join(l.encode() for l in header_lines)) > 4096:
            raise ValueError("PLY header too large")
        if decoded.startswith("element vertex"):
            vertex_count = int(decoded.split()[-1])
        elif decoded.startswith("element face"):
            face_count = int(decoded.split()[-1])

    if not header_lines[0].startswith("ply"):
        raise ValueError("Invalid PLY: missing 'ply' magic")

    return header_lines, vertex_count, face_count
