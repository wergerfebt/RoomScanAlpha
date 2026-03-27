"""
Tests for Stage 1: Parse & Classify.

Test IDs from CLOUD_PIPELINE_PLAN.md:
  S1.1 — Parse a known PLY file (vertex/face counts match header, no parse errors)
  S1.2 — Classification groups non-empty for wall + floor + ceiling
  S1.3 — Vertex positions match bounding box (extents within ±0.001m)
  S1.4 — Face normals consistent (floor +Y, ceiling -Y)
"""

import os
import tempfile

import numpy as np
import pytest

from pipeline.stage1 import (
    CLASSIFICATION_CEILING,
    CLASSIFICATION_FLOOR,
    CLASSIFICATION_WALL,
    ParsedMesh,
    parse_and_classify,
)
from tests.fixtures.generate_ply import generate_box_room_ply


@pytest.fixture
def box_room_ply(tmp_path):
    """Generate a box room PLY and return (ply_path, expected_info)."""
    ply_path = str(tmp_path / "mesh.ply")
    info = generate_box_room_ply(ply_path)
    return ply_path, info


@pytest.fixture
def parsed_mesh(box_room_ply) -> ParsedMesh:
    """Parse the box room PLY and return the ParsedMesh."""
    ply_path, _ = box_room_ply
    return parse_and_classify(ply_path)


# ---------------------------------------------------------------------------
# S1.1 — Parse a known PLY file
# ---------------------------------------------------------------------------

class TestS1_1_ParseKnownPLY:
    """Vertex/face counts match header; no parse errors."""

    def test_vertex_count_matches(self, box_room_ply):
        ply_path, info = box_room_ply
        mesh = parse_and_classify(ply_path)
        assert mesh.vertex_count == info["vertex_count"]

    def test_face_count_matches(self, box_room_ply):
        ply_path, info = box_room_ply
        mesh = parse_and_classify(ply_path)
        assert mesh.face_count == info["face_count"]

    def test_positions_shape(self, parsed_mesh):
        assert parsed_mesh.positions.shape == (parsed_mesh.vertex_count, 3)
        assert parsed_mesh.positions.dtype == np.float32

    def test_normals_shape(self, parsed_mesh):
        assert parsed_mesh.normals.shape == (parsed_mesh.vertex_count, 3)
        assert parsed_mesh.normals.dtype == np.float32

    def test_faces_shape(self, parsed_mesh):
        assert parsed_mesh.faces.shape == (parsed_mesh.face_count, 3)

    def test_classifications_shape(self, parsed_mesh):
        assert parsed_mesh.face_classifications.shape == (parsed_mesh.face_count,)
        assert parsed_mesh.face_classifications.dtype == np.uint8

    def test_no_out_of_bounds_indices(self, parsed_mesh):
        assert parsed_mesh.faces.max() < parsed_mesh.vertex_count
        assert parsed_mesh.faces.min() >= 0

    def test_rejects_invalid_header(self, tmp_path):
        bad_ply = str(tmp_path / "bad.ply")
        with open(bad_ply, "wb") as f:
            f.write(b"NOT A PLY FILE\n")
        with pytest.raises(ValueError, match="missing 'ply' magic"):
            parse_and_classify(bad_ply)

    def test_rejects_truncated_vertex_data(self, tmp_path):
        ply_path = str(tmp_path / "truncated.ply")
        header = (
            "ply\n"
            "format binary_little_endian 1.0\n"
            "element vertex 100\n"
            "property float x\nproperty float y\nproperty float z\n"
            "property float nx\nproperty float ny\nproperty float nz\n"
            "element face 0\n"
            "property list uchar uint vertex_indices\n"
            "property uchar classification\n"
            "end_header\n"
        )
        with open(ply_path, "wb") as f:
            f.write(header.encode("ascii"))
            f.write(b"\x00" * 10)  # way too short
        with pytest.raises(ValueError, match="truncated vertex data"):
            parse_and_classify(ply_path)


# ---------------------------------------------------------------------------
# S1.2 — Classification groups are non-empty for scanned room
# ---------------------------------------------------------------------------

class TestS1_2_ClassificationGroups:
    """At least wall + floor + ceiling groups populated with > 0 faces."""

    def test_wall_group_exists(self, parsed_mesh):
        assert CLASSIFICATION_WALL in parsed_mesh.classification_groups
        assert parsed_mesh.classification_groups[CLASSIFICATION_WALL].face_count > 0

    def test_floor_group_exists(self, parsed_mesh):
        assert CLASSIFICATION_FLOOR in parsed_mesh.classification_groups
        assert parsed_mesh.classification_groups[CLASSIFICATION_FLOOR].face_count > 0

    def test_ceiling_group_exists(self, parsed_mesh):
        assert CLASSIFICATION_CEILING in parsed_mesh.classification_groups
        assert parsed_mesh.classification_groups[CLASSIFICATION_CEILING].face_count > 0

    def test_wall_face_count(self, box_room_ply):
        ply_path, info = box_room_ply
        mesh = parse_and_classify(ply_path)
        assert mesh.classification_groups[CLASSIFICATION_WALL].face_count == info["wall_face_count"]

    def test_floor_face_count(self, box_room_ply):
        ply_path, info = box_room_ply
        mesh = parse_and_classify(ply_path)
        assert mesh.classification_groups[CLASSIFICATION_FLOOR].face_count == info["floor_face_count"]

    def test_ceiling_face_count(self, box_room_ply):
        ply_path, info = box_room_ply
        mesh = parse_and_classify(ply_path)
        assert mesh.classification_groups[CLASSIFICATION_CEILING].face_count == info["ceiling_face_count"]

    def test_group_vertex_ids_are_valid(self, parsed_mesh):
        for group in parsed_mesh.classification_groups.values():
            assert group.vertex_ids.max() < parsed_mesh.vertex_count
            assert group.vertex_ids.min() >= 0

    def test_all_faces_accounted_for(self, parsed_mesh):
        total = sum(g.face_count for g in parsed_mesh.classification_groups.values())
        assert total == parsed_mesh.face_count

    def test_classification_names(self, parsed_mesh):
        assert parsed_mesh.classification_groups[CLASSIFICATION_WALL].classification_name == "wall"
        assert parsed_mesh.classification_groups[CLASSIFICATION_FLOOR].classification_name == "floor"
        assert parsed_mesh.classification_groups[CLASSIFICATION_CEILING].classification_name == "ceiling"


# ---------------------------------------------------------------------------
# S1.3 — Vertex positions match bounding box
# ---------------------------------------------------------------------------

class TestS1_3_BoundingBox:
    """Computed bbox matches expected extents within ±0.001m."""

    def test_bbox_extents_match(self, box_room_ply):
        ply_path, info = box_room_ply
        mesh = parse_and_classify(ply_path)
        expected = info["bbox"]
        for key in ["x_m", "y_m", "z_m", "min_x", "min_y", "min_z", "max_x", "max_y", "max_z"]:
            assert abs(mesh.bbox[key] - expected[key]) < 0.001, \
                f"bbox mismatch on {key}: got {mesh.bbox[key]}, expected {expected[key]}"

    def test_bbox_x_equals_room_width(self, box_room_ply):
        ply_path, info = box_room_ply
        mesh = parse_and_classify(ply_path)
        assert abs(mesh.bbox["x_m"] - info["width"]) < 0.001

    def test_bbox_y_equals_room_height(self, box_room_ply):
        ply_path, info = box_room_ply
        mesh = parse_and_classify(ply_path)
        assert abs(mesh.bbox["y_m"] - info["height"]) < 0.001

    def test_bbox_z_equals_room_depth(self, box_room_ply):
        ply_path, info = box_room_ply
        mesh = parse_and_classify(ply_path)
        assert abs(mesh.bbox["z_m"] - info["depth"]) < 0.001

    def test_bbox_consistent_with_positions(self, parsed_mesh):
        """Verify bbox is actually derived from vertex positions."""
        actual_min = parsed_mesh.positions.min(axis=0)
        actual_max = parsed_mesh.positions.max(axis=0)
        assert abs(parsed_mesh.bbox["min_x"] - float(actual_min[0])) < 0.001
        assert abs(parsed_mesh.bbox["max_y"] - float(actual_max[1])) < 0.001


# ---------------------------------------------------------------------------
# S1.4 — Face normals are consistent
# ---------------------------------------------------------------------------

class TestS1_4_NormalConsistency:
    """Floor normals point +Y, ceiling normals point -Y."""

    def test_floor_normals_point_up(self, parsed_mesh):
        """Mean normal Y-component > 0.9 for floor vertices."""
        floor_group = parsed_mesh.classification_groups[CLASSIFICATION_FLOOR]
        floor_normals = parsed_mesh.normals[floor_group.vertex_ids]
        mean_y = float(floor_normals[:, 1].mean())
        assert mean_y > 0.9, f"floor mean normal Y = {mean_y}, expected > 0.9"

    def test_ceiling_normals_point_down(self, parsed_mesh):
        """Mean normal Y-component < -0.9 for ceiling vertices."""
        ceiling_group = parsed_mesh.classification_groups[CLASSIFICATION_CEILING]
        ceiling_normals = parsed_mesh.normals[ceiling_group.vertex_ids]
        mean_y = float(ceiling_normals[:, 1].mean())
        assert mean_y < -0.9, f"ceiling mean normal Y = {mean_y}, expected < -0.9"

    def test_wall_normals_mostly_horizontal(self, parsed_mesh):
        """Wall normals should have small Y-component (mostly horizontal)."""
        wall_group = parsed_mesh.classification_groups[CLASSIFICATION_WALL]
        wall_normals = parsed_mesh.normals[wall_group.vertex_ids]
        mean_abs_y = float(np.abs(wall_normals[:, 1]).mean())
        assert mean_abs_y < 0.1, f"wall mean |normal Y| = {mean_abs_y}, expected < 0.1"

    def test_normals_are_unit_length(self, parsed_mesh):
        """All normals should be approximately unit length."""
        lengths = np.linalg.norm(parsed_mesh.normals, axis=1)
        assert np.allclose(lengths, 1.0, atol=0.01), \
            f"normals not unit length: min={lengths.min():.3f}, max={lengths.max():.3f}"
