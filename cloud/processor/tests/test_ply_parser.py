"""Tests for Stage 1: PLY parsing and classification grouping.

Maps to Cloud Pipeline Plan test cases S1.1–S1.4.
"""

import os
import pytest
import numpy as np

from pipeline.ply_parser import parse_ply, vertices_for_group, normals_for_group, bounding_box
from tests.generate_fixture import generate_box_room_ply, ROOM_WIDTH, ROOM_HEIGHT, ROOM_DEPTH

FIXTURES_DIR = os.path.join(os.path.dirname(__file__), "fixtures")


@pytest.fixture(autouse=True)
def ensure_fixtures():
    """Generate fixtures if they don't exist."""
    os.makedirs(FIXTURES_DIR, exist_ok=True)
    clean_path = os.path.join(FIXTURES_DIR, "box_room.ply")
    if not os.path.exists(clean_path):
        generate_box_room_ply(clean_path)
    noisy_path = os.path.join(FIXTURES_DIR, "box_room_noisy.ply")
    if not os.path.exists(noisy_path):
        generate_box_room_ply(noisy_path, noise_std=0.01)


# --- S1.1: Parse a known PLY file ---

class TestS1_1_ParseKnownPLY:
    def test_vertex_count_matches_header(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        # 6 room surfaces × 36 verts + 6 table faces × 9 verts = 270
        assert parsed.vertices.shape[0] == 270

    def test_face_count_matches_header(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        # 6 room surfaces × 50 tris + 6 table faces × 8 tris = 348
        assert parsed.face_indices.shape[0] == 348

    def test_no_parse_errors(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        assert parsed.vertices.shape == (270, 3)
        assert parsed.normals.shape == (270, 3)
        assert parsed.face_indices.shape == (348, 3)
        assert parsed.face_classifications.shape == (348,)

    def test_vertex_positions_are_finite(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        assert np.all(np.isfinite(parsed.vertices))

    def test_normals_are_unit_length(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        lengths = np.linalg.norm(parsed.normals, axis=1)
        np.testing.assert_allclose(lengths, 1.0, atol=0.01)


# --- S1.2: Classification groups non-empty ---

class TestS1_2_ClassificationGroups:
    def test_wall_group_nonempty(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        assert 1 in parsed.classification_groups  # wall
        assert len(parsed.classification_groups[1]) > 0

    def test_floor_group_nonempty(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        assert 2 in parsed.classification_groups  # floor
        assert len(parsed.classification_groups[2]) > 0

    def test_ceiling_group_nonempty(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        assert 3 in parsed.classification_groups  # ceiling
        assert len(parsed.classification_groups[3]) > 0

    def test_table_group_nonempty(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        assert 4 in parsed.classification_groups  # table
        assert len(parsed.classification_groups[4]) > 0

    def test_wall_has_expected_faces(self):
        """4 walls × 50 triangles each = 200 wall faces."""
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        assert len(parsed.classification_groups[1]) == 200

    def test_floor_has_expected_faces(self):
        """1 floor × 50 triangles = 50 floor faces."""
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        assert len(parsed.classification_groups[2]) == 50

    def test_ceiling_has_expected_faces(self):
        """1 ceiling × 50 triangles = 50 ceiling faces."""
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        assert len(parsed.classification_groups[3]) == 50


# --- S1.3: Bounding box matches expected dimensions ---

class TestS1_3_BoundingBox:
    def test_bbox_matches_room_dimensions(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        bbox = bounding_box(parsed.vertices)
        assert abs(bbox["bbox_x"] - ROOM_WIDTH) < 0.01
        assert abs(bbox["bbox_y"] - ROOM_HEIGHT) < 0.01
        assert abs(bbox["bbox_z"] - ROOM_DEPTH) < 0.01

    def test_bbox_min_at_origin(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        bbox = bounding_box(parsed.vertices)
        assert abs(bbox["min_x"]) < 0.01
        assert abs(bbox["min_y"]) < 0.01
        assert abs(bbox["min_z"]) < 0.01

    def test_bbox_max_at_room_extents(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        bbox = bounding_box(parsed.vertices)
        assert abs(bbox["max_x"] - ROOM_WIDTH) < 0.01
        assert abs(bbox["max_y"] - ROOM_HEIGHT) < 0.01
        assert abs(bbox["max_z"] - ROOM_DEPTH) < 0.01


# --- S1.4: Face normals are consistent ---

class TestS1_4_NormalConsistency:
    def test_floor_normals_point_up(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        floor_normals = normals_for_group(parsed, 2)
        mean_y = floor_normals[:, 1].mean()
        assert mean_y > 0.9, f"Floor normal mean Y={mean_y}, expected > 0.9"

    def test_ceiling_normals_point_down(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        ceiling_normals = normals_for_group(parsed, 3)
        mean_y = ceiling_normals[:, 1].mean()
        assert mean_y < -0.9, f"Ceiling normal mean Y={mean_y}, expected < -0.9"

    def test_wall_normals_are_horizontal(self):
        parsed = parse_ply(os.path.join(FIXTURES_DIR, "box_room.ply"))
        wall_normals = normals_for_group(parsed, 1)
        y_magnitudes = np.abs(wall_normals[:, 1])
        assert y_magnitudes.mean() < 0.1, (
            f"Wall normal mean |Y|={y_magnitudes.mean()}, expected < 0.1"
        )
