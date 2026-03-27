"""
Stage 3: Room Geometry Assembly — simplify the classified mesh per surface type.

Input:  ParsedMesh from Stage 1 (classified faces), PlaneFitResult from Stage 2
Output: SimplifiedMesh with decimated sub-meshes per classification, combined into
        a single scene with per-face labels.

Approach: split the raw mesh by ARKit classification (wall, floor, ceiling, door,
window, etc.), apply quadric-error-metric decimation to each sub-mesh independently,
then merge into one indexed triangle mesh. This preserves the actual room shape
(L-shapes, door openings, bay windows, furniture) while reducing polygon count.

Stage 2 planes are still used for measurements (Stage 4) but not for geometry
construction.

Coordinate system: ARKit Y-up right-handed (Y=up, -Z=forward). All units in meters.
"""

from dataclasses import dataclass, field

import numpy as np
import trimesh

from pipeline.stage1 import (
    ParsedMesh,
    CLASSIFICATION_NAMES,
    CLASSIFICATION_NONE,
    CLASSIFICATION_WALL,
    CLASSIFICATION_FLOOR,
    CLASSIFICATION_CEILING,
)
from pipeline.stage2 import PlaneFitResult, DetectedPlane

# Target face count per classification group after decimation.
# Groups with fewer faces than the target are kept as-is.
DEFAULT_TARGET_FACES: dict[int, int] = {
    CLASSIFICATION_FLOOR: 2000,
    CLASSIFICATION_CEILING: 2000,
    CLASSIFICATION_WALL: 5000,
}
# Default for unlisted classifications (door, window, table, seat, none)
DEFAULT_TARGET_OTHER = 1000

# Minimum faces to bother decimating (below this, keep original)
MIN_FACES_TO_DECIMATE = 20

# Classifications to include in the simplified mesh.
# CLASSIFICATION_NONE (0) is excluded — it's unclassified noise/furniture.
INCLUDED_CLASSIFICATIONS = {1, 2, 3, 4, 5, 6, 7}  # wall, floor, ceiling, table, seat, door, window


@dataclass
class SimplifiedMesh:
    """Output of Stage 3: simplified mesh scene with per-face classification labels.

    Attributes:
        vertices: Nx3 float32 vertex positions (meters).
        normals: Nx3 float32 per-vertex normals.
        faces: Mx3 uint32 triangle indices.
        uvs: Nx2 float32 texture coordinates in [0,1].
        face_labels: M labels like "floor", "ceiling", "wall", "door", "window".
        surface_map: per-label metadata (classification_id, face_count, area_sqm).
    """
    vertices: np.ndarray
    normals: np.ndarray
    faces: np.ndarray
    uvs: np.ndarray
    face_labels: list[str] = field(default_factory=list)
    surface_map: dict = field(default_factory=dict)


def assemble_geometry(
    plan_result: PlaneFitResult,
    mesh: ParsedMesh | None = None,
) -> SimplifiedMesh:
    """Build a simplified mesh by decimating each classification group independently.

    Args:
        plan_result: PlaneFitResult from Stage 2 (used for surface_map metadata).
        mesh: ParsedMesh from Stage 1 (required — provides classified faces).

    Returns:
        SimplifiedMesh with all classification groups merged.

    Raises:
        ValueError: If mesh is None.
    """
    if mesh is None:
        raise ValueError("ParsedMesh is required for mesh simplification")

    all_verts: list[np.ndarray] = []
    all_normals: list[np.ndarray] = []
    all_faces: list[np.ndarray] = []
    all_labels: list[str] = []
    surface_map: dict = {}
    vertex_offset = 0

    for cls_id, group in sorted(mesh.classification_groups.items()):
        if cls_id not in INCLUDED_CLASSIFICATIONS:
            continue

        cls_name = CLASSIFICATION_NAMES.get(cls_id, f"unknown_{cls_id}")

        # Extract sub-mesh for this classification
        sub_verts, sub_faces, sub_normals = _extract_submesh(mesh, group.face_indices)

        if len(sub_faces) == 0:
            continue

        # Decimate
        target = DEFAULT_TARGET_FACES.get(cls_id, DEFAULT_TARGET_OTHER)
        if len(sub_faces) > target and len(sub_faces) >= MIN_FACES_TO_DECIMATE:
            sub_verts, sub_faces, sub_normals = _decimate(sub_verts, sub_faces, sub_normals, target)

        n_faces = len(sub_faces)
        if n_faces == 0:
            continue

        # Offset face indices
        offset_faces = sub_faces + vertex_offset

        all_verts.append(sub_verts)
        all_normals.append(sub_normals)
        all_faces.append(offset_faces)
        all_labels.extend([cls_name] * n_faces)

        # Compute area
        area = _compute_mesh_area(sub_verts, sub_faces)

        surface_map[cls_name] = {
            "classification_id": cls_id,
            "face_count": n_faces,
            "area_sqm": round(area, 2),
            "original_face_count": int(group.face_count),
        }

        # Attach Stage 2 plane info for structural surfaces
        if cls_id == CLASSIFICATION_FLOOR and plan_result.floor_planes:
            surface_map[cls_name]["plane"] = plan_result.floor_planes[0]
        elif cls_id == CLASSIFICATION_CEILING and plan_result.ceiling_planes:
            surface_map[cls_name]["plane"] = plan_result.ceiling_planes[0]

        vertex_offset += len(sub_verts)

    # Merge
    vertices = np.vstack(all_verts).astype(np.float32) if all_verts else np.empty((0, 3), dtype=np.float32)
    normals = np.vstack(all_normals).astype(np.float32) if all_normals else np.empty((0, 3), dtype=np.float32)
    faces = np.vstack(all_faces).astype(np.uint32) if all_faces else np.empty((0, 3), dtype=np.uint32)

    # Generate basic UVs (planar projection per vertex, normalized to [0,1])
    uvs = _generate_uvs(vertices)

    return SimplifiedMesh(
        vertices=vertices,
        normals=normals,
        faces=faces,
        uvs=uvs,
        face_labels=all_labels,
        surface_map=surface_map,
    )


def _extract_submesh(
    mesh: ParsedMesh,
    face_indices: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Extract a sub-mesh from the ParsedMesh for the given face indices.

    Re-indexes vertices so the sub-mesh is self-contained.

    Returns:
        (vertices, faces, normals) — all with compact indexing.
    """
    # Get faces for this group
    group_faces = mesh.faces[face_indices]

    # Get unique vertex indices and build a remapping
    unique_verts, inverse = np.unique(group_faces.ravel(), return_inverse=True)
    new_faces = inverse.reshape(-1, 3)

    vertices = mesh.positions[unique_verts]
    normals = mesh.normals[unique_verts]

    return vertices.astype(np.float32), new_faces.astype(np.uint32), normals.astype(np.float32)


def _decimate(
    vertices: np.ndarray,
    faces: np.ndarray,
    normals: np.ndarray,
    target_faces: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Decimate a mesh using quadric error metrics via trimesh + fast_simplification.

    Returns:
        (vertices, faces, normals) after decimation.
    """
    n_faces = len(faces)
    if n_faces <= target_faces:
        return vertices, faces, normals

    tm = trimesh.Trimesh(vertices=vertices, faces=faces, vertex_normals=normals, process=False)
    target_reduction = 1.0 - (target_faces / n_faces)

    try:
        simplified = tm.simplify_quadric_decimation(target_reduction)
    except Exception:
        return vertices, faces, normals

    if len(simplified.faces) == 0:
        return vertices, faces, normals

    out_verts = np.array(simplified.vertices, dtype=np.float32)
    out_faces = np.array(simplified.faces, dtype=np.uint32)
    out_normals = np.array(simplified.vertex_normals, dtype=np.float32)

    return out_verts, out_faces, out_normals


def _compute_mesh_area(vertices: np.ndarray, faces: np.ndarray) -> float:
    """Compute total surface area of a triangle mesh."""
    v0 = vertices[faces[:, 0]]
    v1 = vertices[faces[:, 1]]
    v2 = vertices[faces[:, 2]]
    crosses = np.cross(v1 - v0, v2 - v0)
    return float(0.5 * np.linalg.norm(crosses, axis=1).sum())


def _generate_uvs(vertices: np.ndarray) -> np.ndarray:
    """Generate basic UV coordinates via XZ planar projection, normalized to [0,1]."""
    if len(vertices) == 0:
        return np.empty((0, 2), dtype=np.float32)

    xz = vertices[:, [0, 2]]
    xz_min = xz.min(axis=0)
    xz_max = xz.max(axis=0)
    xz_range = xz_max - xz_min
    xz_range[xz_range < 1e-6] = 1.0

    uvs = (xz - xz_min) / xz_range
    return uvs.astype(np.float32)
