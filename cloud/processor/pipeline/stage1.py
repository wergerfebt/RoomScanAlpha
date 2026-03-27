"""
Stage 1: Parse & Classify — read binary PLY mesh, extract geometry, group by classification.

Input:  mesh.ply (binary little-endian, ARKit format)
Output: ParsedMesh with classified face groups ready for Stage 2 plane fitting.

Coordinate system: ARKit Y-up right-handed (Y=up, -Z=forward).
All positions are in meters (ARKit's native unit).

Face binary layout (14 bytes per face):
  [1 byte: vertex_count (always 3)]
  [4 bytes: idx0 (uint32 LE)]
  [4 bytes: idx1 (uint32 LE)]
  [4 bytes: idx2 (uint32 LE)]
  [1 byte: classification (uint8)]
"""

from dataclasses import dataclass, field
from typing import Optional

import numpy as np


# ARMeshClassification values — must match iOS ARKit ARMeshClassification enum.
CLASSIFICATION_NONE = 0
CLASSIFICATION_WALL = 1
CLASSIFICATION_FLOOR = 2
CLASSIFICATION_CEILING = 3

CLASSIFICATION_NAMES: dict[int, str] = {
    0: "none",
    1: "wall",
    2: "floor",
    3: "ceiling",
    4: "table",
    5: "seat",
    6: "door",
    7: "window",
}

# PLY format constants.
PLY_FLOATS_PER_VERTEX = 6       # x, y, z, nx, ny, nz
PLY_BYTES_PER_VERTEX = PLY_FLOATS_PER_VERTEX * 4  # 24 bytes
PLY_BYTES_PER_FACE = 14         # 1 + 3*4 + 1
PLY_MAX_HEADER_BYTES = 4096


@dataclass
class ClassificationGroup:
    """A group of faces sharing the same ARMeshClassification label."""
    classification_id: int
    classification_name: str
    face_indices: np.ndarray        # indices into the face array (int32)
    vertex_ids: np.ndarray          # unique vertex indices referenced by these faces (int32)

    @property
    def face_count(self) -> int:
        return len(self.face_indices)

    @property
    def vertex_count(self) -> int:
        return len(self.vertex_ids)


@dataclass
class ParsedMesh:
    """Output of Stage 1: fully parsed and classified mesh ready for Stage 2.

    Attributes:
        positions: Nx3 float32 vertex positions (meters, ARKit Y-up).
        normals: Nx3 float32 vertex normals.
        faces: Fx3 uint32 vertex indices per face.
        face_classifications: F uint8 ARMeshClassification per face.
        classification_groups: dict mapping classification_id → ClassificationGroup.
        bbox: bounding box dict with min/max/extent per axis (meters).
        vertex_count: total vertices in the mesh.
        face_count: total faces in the mesh.
    """
    positions: np.ndarray
    normals: np.ndarray
    faces: np.ndarray
    face_classifications: np.ndarray
    classification_groups: dict[int, ClassificationGroup] = field(default_factory=dict)
    bbox: dict = field(default_factory=dict)
    vertex_count: int = 0
    face_count: int = 0


def parse_and_classify(ply_path: str) -> ParsedMesh:
    """Parse a binary little-endian PLY and return a classified ParsedMesh.

    Reads the full vertex block (positions + normals) and face block in bulk
    using numpy for performance, then groups faces by classification.

    Args:
        ply_path: Path to the binary PLY file.

    Returns:
        ParsedMesh with all fields populated.

    Raises:
        ValueError: If the PLY is malformed (bad header, truncated data, etc.).
    """
    vertex_count, face_count, header_end_offset = _parse_header(ply_path)

    if vertex_count == 0:
        raise ValueError("PLY has 0 vertices")

    with open(ply_path, "rb") as f:
        f.seek(header_end_offset)

        # --- Vertices: bulk read with numpy ---
        vertex_data = f.read(vertex_count * PLY_BYTES_PER_VERTEX)
        if len(vertex_data) != vertex_count * PLY_BYTES_PER_VERTEX:
            raise ValueError(
                f"truncated vertex data: expected {vertex_count * PLY_BYTES_PER_VERTEX} bytes, "
                f"got {len(vertex_data)}"
            )
        vertices = np.frombuffer(vertex_data, dtype="<f4").reshape(vertex_count, PLY_FLOATS_PER_VERTEX)
        positions = vertices[:, :3].copy()
        normals = vertices[:, 3:6].copy()

        # --- Faces: bulk read with numpy ---
        face_data = f.read(face_count * PLY_BYTES_PER_FACE)
        if len(face_data) != face_count * PLY_BYTES_PER_FACE:
            raise ValueError(
                f"truncated face data: expected {face_count * PLY_BYTES_PER_FACE} bytes, "
                f"got {len(face_data)}"
            )

    faces, face_classifications = _parse_faces_bulk(face_data, face_count)

    # --- Bounding box ---
    min_pos = positions.min(axis=0)
    max_pos = positions.max(axis=0)
    extents = max_pos - min_pos
    bbox = {
        "min_x": round(float(min_pos[0]), 3),
        "min_y": round(float(min_pos[1]), 3),
        "min_z": round(float(min_pos[2]), 3),
        "max_x": round(float(max_pos[0]), 3),
        "max_y": round(float(max_pos[1]), 3),
        "max_z": round(float(max_pos[2]), 3),
        "x_m": round(float(extents[0]), 3),
        "y_m": round(float(extents[1]), 3),
        "z_m": round(float(extents[2]), 3),
    }

    # --- Classification groups ---
    classification_groups = _build_classification_groups(faces, face_classifications)

    return ParsedMesh(
        positions=positions,
        normals=normals,
        faces=faces,
        face_classifications=face_classifications,
        classification_groups=classification_groups,
        bbox=bbox,
        vertex_count=vertex_count,
        face_count=face_count,
    )


def _parse_header(ply_path: str) -> tuple[int, int, int]:
    """Parse PLY ASCII header. Returns (vertex_count, face_count, byte offset after header)."""
    with open(ply_path, "rb") as f:
        first_line = f.readline()
        if not first_line or not first_line.decode("ascii", errors="replace").strip().startswith("ply"):
            raise ValueError("invalid PLY header: missing 'ply' magic")

        header_bytes = first_line
        while True:
            line = f.readline()
            if not line:
                raise ValueError("unexpected EOF before end_header")
            header_bytes += line
            if line.strip() == b"end_header":
                break
            if len(header_bytes) > PLY_MAX_HEADER_BYTES:
                raise ValueError("invalid PLY header: header too large")

        header_end_offset = f.tell()

    header_str = header_bytes.decode("ascii", errors="replace")

    vertex_count: Optional[int] = None
    face_count: Optional[int] = None
    for line in header_str.split("\n"):
        stripped = line.strip()
        if stripped.startswith("element vertex"):
            vertex_count = int(stripped.split()[-1])
        elif stripped.startswith("element face"):
            face_count = int(stripped.split()[-1])

    if vertex_count is None or face_count is None:
        raise ValueError("invalid PLY header: missing vertex/face element counts")

    return vertex_count, face_count, header_end_offset


def _parse_faces_bulk(face_data: bytes, face_count: int) -> tuple[np.ndarray, np.ndarray]:
    """Parse the face block in bulk using numpy structured array.

    Each face is 14 bytes: [1B count][4B idx0][4B idx1][4B idx2][1B classification].

    Returns:
        (faces, classifications) where faces is Fx3 uint32 and classifications is F uint8.
    """
    dt = np.dtype([
        ("count", "u1"),
        ("v0", "<u4"),
        ("v1", "<u4"),
        ("v2", "<u4"),
        ("classification", "u1"),
    ])
    raw = np.frombuffer(face_data, dtype=dt)
    faces = np.column_stack([raw["v0"], raw["v1"], raw["v2"]])
    classifications = raw["classification"].copy()
    return faces, classifications


def _build_classification_groups(
    faces: np.ndarray,
    face_classifications: np.ndarray,
) -> dict[int, ClassificationGroup]:
    """Group faces by classification label and compute per-group vertex sets."""
    groups: dict[int, ClassificationGroup] = {}
    unique_classes = np.unique(face_classifications)

    for cls_id in unique_classes:
        cls_int = int(cls_id)
        mask = face_classifications == cls_id
        group_face_indices = np.nonzero(mask)[0].astype(np.int32)
        group_faces = faces[mask]
        vertex_ids = np.unique(group_faces.ravel()).astype(np.int32)

        groups[cls_int] = ClassificationGroup(
            classification_id=cls_int,
            classification_name=CLASSIFICATION_NAMES.get(cls_int, f"unknown_{cls_int}"),
            face_indices=group_face_indices,
            vertex_ids=vertex_ids,
        )

    return groups
