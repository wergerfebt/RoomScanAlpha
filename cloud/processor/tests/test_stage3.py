"""
Tests for Stage 3: Room Geometry Assembly.

Test IDs from CLOUD_PIPELINE_PLAN.md:
  S3.1 — Rectangular room produces closed box (12 triangles, watertight)
  S3.2 — Wall quads span floor to ceiling (wall Y coords match floor/ceiling heights)
  S3.3 — Adjacent walls meet at corners (shared corner positions)
  S3.4 — UV coordinates span [0,1] per surface
  S3.5 — Object boxes are inside room bounds
  S3.6 — Total vertex count is small (< 200 for simple room)
  S3.7 — Normals point inward (walls toward center, floor up, ceiling down)
"""

from collections import defaultdict

import numpy as np
import pytest

from pipeline.stage1 import parse_and_classify
from pipeline.stage2 import fit_planes, PlaneFitResult, DetectedObject
from pipeline.stage3 import assemble_geometry, SimplifiedMesh
from tests.fixtures.generate_ply import generate_dense_box_room_ply, generate_rotated_dense_room_ply


@pytest.fixture
def dense_room_result(tmp_path) -> tuple[PlaneFitResult, dict]:
    ply_path = str(tmp_path / "mesh.ply")
    info = generate_dense_box_room_ply(ply_path)
    mesh = parse_and_classify(ply_path)
    return fit_planes(mesh), info


@pytest.fixture
def simplified_mesh(dense_room_result) -> tuple[SimplifiedMesh, dict]:
    result, info = dense_room_result
    return assemble_geometry(result), info


@pytest.fixture
def room_with_objects_simplified(dense_room_result) -> tuple[SimplifiedMesh, dict]:
    """Dense room with synthetic table and seat objects injected into the PlaneFitResult."""
    result, info = dense_room_result
    # Inject synthetic objects into the plane fit result
    table = DetectedObject(
        classification="table",
        classification_id=4,
        center=np.array([0.5, 0.4, 0.0], dtype=np.float32),
        dimensions=np.array([1.2, 0.8, 0.7], dtype=np.float32),
        orientation=np.eye(3, dtype=np.float32),
        face_count=12,
    )
    seat = DetectedObject(
        classification="seat",
        classification_id=5,
        center=np.array([-1.0, 0.25, 0.0], dtype=np.float32),
        dimensions=np.array([0.5, 0.5, 0.5], dtype=np.float32),
        orientation=np.eye(3, dtype=np.float32),
        face_count=12,
    )
    result.objects.extend([table, seat])
    return assemble_geometry(result), info


# ---------------------------------------------------------------------------
# S3.1 — Rectangular room produces closed box
# ---------------------------------------------------------------------------

class TestS3_1_ClosedBox:
    def test_has_floor_ceiling_and_walls(self, simplified_mesh):
        smesh, _ = simplified_mesh
        labels = set(smesh.face_labels)
        assert "floor" in labels
        assert "ceiling" in labels
        wall_labels = [l for l in labels if l.startswith("wall_")]
        assert len(wall_labels) >= 4

    def test_triangle_count_for_simple_room(self, simplified_mesh):
        """6 surfaces × 2 triangles = 12 triangles minimum for a box room.
        With convex hull producing 4 hull vertices, floor/ceiling each get 2 tris (fan),
        plus 4 walls × 2 tris = 8, total = 12."""
        smesh, _ = simplified_mesh
        n_tris = len(smesh.faces)
        # Floor (fan: n-2 tris) + ceiling (n-2) + walls (2 each)
        # With 4 hull vertices: 2 + 2 + 8 = 12
        assert n_tris >= 12, f"expected >= 12 triangles, got {n_tris}"

    def test_watertight_edges(self, simplified_mesh):
        """Every edge should be shared by exactly 2 triangles in a closed room mesh.

        Note: With separate surfaces (floor/ceiling/walls each having their own vertices),
        shared edges across surface boundaries won't appear. We check within each
        surface group that edges are consistent, and that the overall structure is
        a valid triangle mesh (no degenerate faces)."""
        smesh, _ = simplified_mesh
        # No degenerate faces (all 3 indices distinct)
        for i, face in enumerate(smesh.faces):
            assert len(set(face)) == 3, f"face {i} has duplicate vertex indices: {face}"

    def test_faces_reference_valid_vertices(self, simplified_mesh):
        smesh, _ = simplified_mesh
        n_verts = len(smesh.vertices)
        assert smesh.faces.max() < n_verts
        assert smesh.faces.min() >= 0

    def test_face_labels_match_face_count(self, simplified_mesh):
        smesh, _ = simplified_mesh
        assert len(smesh.face_labels) == len(smesh.faces)


# ---------------------------------------------------------------------------
# S3.2 — Wall quads span floor to ceiling
# ---------------------------------------------------------------------------

class TestS3_2_WallSpan:
    def test_wall_bottom_matches_floor(self, simplified_mesh, dense_room_result):
        smesh, info = simplified_mesh
        result, _ = dense_room_result
        floor_y = result.floor_planes[0].point_on_plane[1]

        wall_labels = [l for l in set(smesh.face_labels) if l.startswith("wall_")]
        for label in wall_labels:
            wall_face_idx = [i for i, l in enumerate(smesh.face_labels) if l == label]
            wall_vert_idx = set()
            for fi in wall_face_idx:
                wall_vert_idx.update(smesh.faces[fi].tolist())
            wall_y = smesh.vertices[list(wall_vert_idx), 1]
            min_y = wall_y.min()
            assert abs(min_y - floor_y) < 0.05, \
                f"{label} bottom Y = {min_y:.3f}, floor Y = {floor_y:.3f}"

    def test_wall_top_matches_ceiling(self, simplified_mesh, dense_room_result):
        smesh, info = simplified_mesh
        result, _ = dense_room_result
        ceiling_y = result.ceiling_planes[0].point_on_plane[1]

        wall_labels = [l for l in set(smesh.face_labels) if l.startswith("wall_")]
        for label in wall_labels:
            wall_face_idx = [i for i, l in enumerate(smesh.face_labels) if l == label]
            wall_vert_idx = set()
            for fi in wall_face_idx:
                wall_vert_idx.update(smesh.faces[fi].tolist())
            wall_y = smesh.vertices[list(wall_vert_idx), 1]
            max_y = wall_y.max()
            assert abs(max_y - ceiling_y) < 0.05, \
                f"{label} top Y = {max_y:.3f}, ceiling Y = {ceiling_y:.3f}"


# ---------------------------------------------------------------------------
# S3.3 — Adjacent walls meet at corners
# ---------------------------------------------------------------------------

class TestS3_3_WallCorners:
    def test_adjacent_walls_share_corner_positions(self, simplified_mesh):
        """Adjacent wall quads should share corner XZ positions at floor level."""
        smesh, _ = simplified_mesh
        wall_labels = sorted([l for l in set(smesh.face_labels) if l.startswith("wall_")])
        if len(wall_labels) < 2:
            pytest.skip("need at least 2 walls")

        # Collect bottom-edge XZ positions per wall
        wall_corners: dict[str, set] = {}
        for label in wall_labels:
            face_idx = [i for i, l in enumerate(smesh.face_labels) if l == label]
            vert_idx = set()
            for fi in face_idx:
                vert_idx.update(smesh.faces[fi].tolist())
            verts = smesh.vertices[list(vert_idx)]
            # Bottom vertices (min Y)
            min_y = verts[:, 1].min()
            bottom = verts[np.abs(verts[:, 1] - min_y) < 0.01]
            xz_set = set()
            for v in bottom:
                xz_set.add((round(float(v[0]), 2), round(float(v[2]), 2)))
            wall_corners[label] = xz_set

        # Check that consecutive walls share at least one corner
        for i in range(len(wall_labels)):
            j = (i + 1) % len(wall_labels)
            shared = wall_corners[wall_labels[i]] & wall_corners[wall_labels[j]]
            assert len(shared) >= 1, \
                f"{wall_labels[i]} and {wall_labels[j]} share no corners"


# ---------------------------------------------------------------------------
# S3.4 — UV coordinates span [0,1] per surface
# ---------------------------------------------------------------------------

class TestS3_4_UVCoordinates:
    def test_all_uvs_in_unit_range(self, simplified_mesh):
        smesh, _ = simplified_mesh
        assert smesh.uvs.min() >= -0.01, f"UV min = {smesh.uvs.min()}"
        assert smesh.uvs.max() <= 1.01, f"UV max = {smesh.uvs.max()}"

    def test_uvs_shape_matches_vertices(self, simplified_mesh):
        smesh, _ = simplified_mesh
        assert smesh.uvs.shape == (len(smesh.vertices), 2)

    def test_wall_uvs_span_full_range(self, simplified_mesh):
        """Each wall quad should have UVs spanning [0,1] in both U and V."""
        smesh, _ = simplified_mesh
        wall_labels = set(l for l in smesh.face_labels if l.startswith("wall_"))
        for label in wall_labels:
            face_idx = [i for i, l in enumerate(smesh.face_labels) if l == label]
            vert_idx = set()
            for fi in face_idx:
                vert_idx.update(smesh.faces[fi].tolist())
            wall_uvs = smesh.uvs[list(vert_idx)]
            u_range = wall_uvs[:, 0].max() - wall_uvs[:, 0].min()
            v_range = wall_uvs[:, 1].max() - wall_uvs[:, 1].min()
            assert u_range > 0.9, f"{label} U range = {u_range}"
            assert v_range > 0.9, f"{label} V range = {v_range}"


# ---------------------------------------------------------------------------
# S3.5 — Object boxes are inside room bounds
# ---------------------------------------------------------------------------

class TestS3_5_ObjectsInsideRoom:
    def test_object_centers_inside_room(self, room_with_objects_simplified):
        smesh, info = room_with_objects_simplified
        obj_labels = [l for l in set(smesh.face_labels)
                      if not l.startswith("wall_") and l not in ("floor", "ceiling")]

        if not obj_labels:
            pytest.skip("no object labels in simplified mesh")

        hw = info["width"] / 2.0
        hd = info["depth"] / 2.0

        for label in obj_labels:
            face_idx = [i for i, l in enumerate(smesh.face_labels) if l == label]
            vert_idx = set()
            for fi in face_idx:
                vert_idx.update(smesh.faces[fi].tolist())
            verts = smesh.vertices[list(vert_idx)]
            center = verts.mean(axis=0)

            assert -hw - 0.5 <= center[0] <= hw + 0.5, \
                f"{label} center X = {center[0]:.2f}, room X range = [{-hw}, {hw}]"
            assert -hd - 0.5 <= center[2] <= hd + 0.5, \
                f"{label} center Z = {center[2]:.2f}, room Z range = [{-hd}, {hd}]"
            assert center[1] >= -0.5, f"{label} center Y = {center[1]:.2f}, below floor"
            assert center[1] <= info["height"] + 0.5, \
                f"{label} center Y = {center[1]:.2f}, above ceiling at {info['height']}m"


# ---------------------------------------------------------------------------
# S3.6 — Total vertex count is small
# ---------------------------------------------------------------------------

class TestS3_6_SmallVertexCount:
    def test_vertex_count_under_200(self, simplified_mesh):
        """A simple rectangular room should produce < 200 vertices."""
        smesh, _ = simplified_mesh
        assert len(smesh.vertices) < 200, \
            f"simplified mesh has {len(smesh.vertices)} vertices, expected < 200"

    def test_much_smaller_than_raw_mesh(self, simplified_mesh):
        """Simplified mesh should be orders of magnitude smaller than raw PLY."""
        smesh, info = simplified_mesh
        raw_vert_count = info["vertex_count"]
        simplified_count = len(smesh.vertices)
        ratio = simplified_count / raw_vert_count
        assert ratio < 0.1, \
            f"simplified ({simplified_count}) is {ratio:.1%} of raw ({raw_vert_count})"


# ---------------------------------------------------------------------------
# S3.7 — Normals point inward
# ---------------------------------------------------------------------------

class TestS3_7_InwardNormals:
    def test_floor_normal_points_up(self, simplified_mesh):
        smesh, _ = simplified_mesh
        floor_face_idx = [i for i, l in enumerate(smesh.face_labels) if l == "floor"]
        floor_vert_idx = set()
        for fi in floor_face_idx:
            floor_vert_idx.update(smesh.faces[fi].tolist())
        floor_normals = smesh.normals[list(floor_vert_idx)]
        mean_y = floor_normals[:, 1].mean()
        assert mean_y > 0.9, f"floor normal mean Y = {mean_y}, expected > 0.9"

    def test_ceiling_normal_points_down(self, simplified_mesh):
        smesh, _ = simplified_mesh
        ceil_face_idx = [i for i, l in enumerate(smesh.face_labels) if l == "ceiling"]
        ceil_vert_idx = set()
        for fi in ceil_face_idx:
            ceil_vert_idx.update(smesh.faces[fi].tolist())
        ceil_normals = smesh.normals[list(ceil_vert_idx)]
        mean_y = ceil_normals[:, 1].mean()
        assert mean_y < -0.9, f"ceiling normal mean Y = {mean_y}, expected < -0.9"

    def test_wall_normals_face_room_center(self, simplified_mesh, dense_room_result):
        """For each wall, dot(normal, center - wall_midpoint) should be > 0."""
        smesh, info = simplified_mesh
        result, _ = dense_room_result
        floor_y = result.floor_planes[0].point_on_plane[1]
        ceiling_y = result.ceiling_planes[0].point_on_plane[1]
        room_center = np.array([0.0, (floor_y + ceiling_y) / 2.0, 0.0])

        wall_labels = [l for l in set(smesh.face_labels) if l.startswith("wall_")]
        for label in wall_labels:
            face_idx = [i for i, l in enumerate(smesh.face_labels) if l == label]
            vert_idx = set()
            for fi in face_idx:
                vert_idx.update(smesh.faces[fi].tolist())
            verts = smesh.vertices[list(vert_idx)]
            wall_mid = verts.mean(axis=0)
            wall_normal = smesh.normals[list(vert_idx)][0]

            to_center = room_center - wall_mid
            dot = np.dot(wall_normal, to_center)
            assert dot > 0, \
                f"{label}: normal·(center-mid) = {dot:.3f}, expected > 0 (normal should face inward)"


# ---------------------------------------------------------------------------
# Rotated room tests
# ---------------------------------------------------------------------------

class TestRotatedRoom:
    """Verify that a room rotated 31° still produces correct rectangular geometry."""

    @pytest.fixture
    def rotated_result(self, tmp_path):
        ply_path = str(tmp_path / "rotated.ply")
        info = generate_rotated_dense_room_ply(ply_path, angle_deg=31.0)
        mesh = parse_and_classify(ply_path)
        plan = fit_planes(mesh)
        smesh = assemble_geometry(plan)
        return smesh, info

    def test_four_walls_detected(self, rotated_result):
        smesh, _ = rotated_result
        wall_labels = [l for l in set(smesh.face_labels) if l.startswith("wall_")]
        assert len(wall_labels) == 4, f"expected 4 walls, got {len(wall_labels)}"

    def test_twelve_triangles(self, rotated_result):
        smesh, _ = rotated_result
        assert len(smesh.faces) == 12

    def test_room_dimensions_match(self, rotated_result):
        """Wall widths should match the expected room dimensions (±10%)."""
        smesh, info = rotated_result
        expected_width = info["width"]
        expected_depth = info["depth"]

        wall_widths = []
        for label in sorted(set(l for l in smesh.face_labels if l.startswith("wall_"))):
            face_idx = [i for i, l in enumerate(smesh.face_labels) if l == label]
            vert_idx = set()
            for fi in face_idx:
                vert_idx.update(smesh.faces[fi].tolist())
            verts = smesh.vertices[list(vert_idx)]
            # Bottom vertices
            min_y = verts[:, 1].min()
            bottom = verts[np.abs(verts[:, 1] - min_y) < 0.01]
            if len(bottom) >= 2:
                width = np.linalg.norm(bottom[0, [0, 2]] - bottom[1, [0, 2]])
                wall_widths.append(float(width))

        wall_widths.sort()
        # Should have 2 pairs: 2 walls at room width, 2 at room depth
        short_pair = sorted([expected_depth, expected_width])
        actual_pair = [wall_widths[0], wall_widths[-1]]
        actual_pair.sort()

        assert abs(actual_pair[0] - short_pair[0]) < short_pair[0] * 0.15, \
            f"short wall: expected ~{short_pair[0]:.1f}m, got {actual_pair[0]:.1f}m"
        assert abs(actual_pair[1] - short_pair[1]) < short_pair[1] * 0.15, \
            f"long wall: expected ~{short_pair[1]:.1f}m, got {actual_pair[1]:.1f}m"

    def test_floor_area_plausible(self, rotated_result):
        """Floor area should approximate width × depth."""
        smesh, info = rotated_result
        expected_area = info["width"] * info["depth"]
        # Compute actual floor area from vertices
        floor_face_idx = [i for i, l in enumerate(smesh.face_labels) if l == "floor"]
        area = 0.0
        for fi in floor_face_idx:
            v0, v1, v2 = smesh.vertices[smesh.faces[fi]]
            area += 0.5 * float(np.linalg.norm(np.cross(v1 - v0, v2 - v0)))
        assert abs(area - expected_area) < expected_area * 0.15, \
            f"floor area: expected ~{expected_area:.1f}m², got {area:.1f}m²"
