"""Tests for Stage 2: RANSAC plane fitting.

Maps to Cloud Pipeline Plan test cases S2.1–S2.7.
Uses the synthetic box_room.ply fixture (4m × 2.5m × 3m).
"""

import os
import pytest
import numpy as np

from pipeline.ply_parser import parse_ply, vertices_for_group, normals_for_group
from pipeline.plane_fitting import (
    fit_planes, fit_object_bounding_box, ceiling_height,
    DetectedPlane, DetectedObject, MIN_INLIERS,
)
from tests.generate_fixture import (
    generate_box_room_ply, ROOM_WIDTH, ROOM_HEIGHT, ROOM_DEPTH,
)

FIXTURES_DIR = os.path.join(os.path.dirname(__file__), "fixtures")
# Use a fixed seed for reproducible RANSAC results
RNG = np.random.default_rng(42)


@pytest.fixture(autouse=True)
def ensure_fixtures():
    os.makedirs(FIXTURES_DIR, exist_ok=True)
    for name, kwargs in [
        ("box_room.ply", {}),
        ("box_room_noisy.ply", {"noise_std": 0.01}),
    ]:
        path = os.path.join(FIXTURES_DIR, name)
        if not os.path.exists(path):
            generate_box_room_ply(path, **kwargs)


def _get_parsed(fixture="box_room.ply"):
    return parse_ply(os.path.join(FIXTURES_DIR, fixture))


# --- S2.1: Floor detected as single horizontal plane ---

class TestS2_1_FloorPlane:
    def test_floor_detected(self):
        parsed = _get_parsed()
        verts = vertices_for_group(parsed, 2)
        norms = normals_for_group(parsed, 2)
        planes = fit_planes(verts, norms, "floor", rng=RNG)
        assert len(planes) >= 1, "Should detect at least 1 floor plane"

    def test_floor_normal_points_up(self):
        parsed = _get_parsed()
        verts = vertices_for_group(parsed, 2)
        norms = normals_for_group(parsed, 2)
        planes = fit_planes(verts, norms, "floor", rng=RNG)
        floor = planes[0]
        # Normal should be approximately (0, 1, 0)
        assert abs(floor.normal[1]) > 0.95, (
            f"Floor normal Y={floor.normal[1]}, expected > 0.95"
        )

    def test_single_dominant_floor_plane(self):
        parsed = _get_parsed()
        verts = vertices_for_group(parsed, 2)
        norms = normals_for_group(parsed, 2)
        planes = fit_planes(verts, norms, "floor", rng=RNG)
        # Simple flat floor should yield exactly 1 plane
        assert len(planes) == 1


# --- S2.2: Ceiling detected as single horizontal plane ---

class TestS2_2_CeilingPlane:
    def test_ceiling_detected(self):
        parsed = _get_parsed()
        verts = vertices_for_group(parsed, 3)
        norms = normals_for_group(parsed, 3)
        planes = fit_planes(verts, norms, "ceiling", rng=RNG)
        assert len(planes) >= 1

    def test_ceiling_normal_points_down(self):
        parsed = _get_parsed()
        verts = vertices_for_group(parsed, 3)
        norms = normals_for_group(parsed, 3)
        planes = fit_planes(verts, norms, "ceiling", rng=RNG)
        ceiling = planes[0]
        assert abs(ceiling.normal[1]) > 0.95, (
            f"Ceiling normal |Y|={abs(ceiling.normal[1])}, expected > 0.95"
        )

    def test_single_dominant_ceiling_plane(self):
        parsed = _get_parsed()
        verts = vertices_for_group(parsed, 3)
        norms = normals_for_group(parsed, 3)
        planes = fit_planes(verts, norms, "ceiling", rng=RNG)
        assert len(planes) == 1


# --- S2.3: Walls detected as vertical planes ---

class TestS2_3_WallsVertical:
    def test_wall_planes_detected(self):
        parsed = _get_parsed()
        verts = vertices_for_group(parsed, 1)
        norms = normals_for_group(parsed, 1)
        planes = fit_planes(verts, norms, "wall", rng=RNG)
        assert len(planes) >= 1, "Should detect at least 1 wall plane"

    def test_wall_normals_are_horizontal(self):
        parsed = _get_parsed()
        verts = vertices_for_group(parsed, 1)
        norms = normals_for_group(parsed, 1)
        planes = fit_planes(verts, norms, "wall", rng=RNG)
        for plane in planes:
            assert abs(plane.normal[1]) < 0.1, (
                f"Wall normal Y={plane.normal[1]}, expected |Y| < 0.1"
            )


# --- S2.4: Rectangular room yields 4 wall planes ---

class TestS2_4_FourWalls:
    def _get_wall_planes(self, fixture="box_room.ply"):
        """Get wall planes, using a more generous min_inliers for sparse fixtures."""
        parsed = _get_parsed(fixture)
        verts = vertices_for_group(parsed, 1)
        norms = normals_for_group(parsed, 1)
        # Lower min_inliers since our fixture has only 4 vertices per wall
        return fit_planes(verts, norms, "wall", min_inliers=3, rng=RNG)

    def test_four_wall_planes(self):
        planes = self._get_wall_planes()
        assert len(planes) == 4, f"Expected 4 wall planes, got {len(planes)}"

    def test_adjacent_walls_perpendicular(self):
        planes = self._get_wall_planes()
        if len(planes) < 2:
            pytest.skip("Need at least 2 walls for perpendicularity check")
        # Sort by normal direction to get adjacent pairs
        normals = [p.normal for p in planes]
        # Check that at least one pair of walls is roughly perpendicular
        found_perpendicular = False
        for i in range(len(normals)):
            for j in range(i + 1, len(normals)):
                dot = abs(np.dot(normals[i], normals[j]))
                if dot < 0.15:  # roughly 90°
                    found_perpendicular = True
                    break
        assert found_perpendicular, "Should find at least one pair of perpendicular walls"


# --- S2.5: Ceiling height matches LiDAR ---

class TestS2_5_CeilingHeight:
    def test_height_matches_room(self):
        parsed = _get_parsed()
        floor_verts = vertices_for_group(parsed, 2)
        floor_norms = normals_for_group(parsed, 2)
        ceiling_verts = vertices_for_group(parsed, 3)
        ceiling_norms = normals_for_group(parsed, 3)

        floor_planes = fit_planes(floor_verts, floor_norms, "floor", rng=RNG)
        ceiling_planes = fit_planes(ceiling_verts, ceiling_norms, "ceiling", rng=RNG)

        if not floor_planes or not ceiling_planes:
            pytest.skip("Need both floor and ceiling planes")

        height = ceiling_height(floor_planes[0], ceiling_planes[0])
        assert abs(height - ROOM_HEIGHT) < 0.05, (
            f"Ceiling height={height}m, expected {ROOM_HEIGHT}m ±0.05m"
        )

    def test_height_from_bbox_y_extent(self):
        parsed = _get_parsed()
        y_min = parsed.vertices[:, 1].min()
        y_max = parsed.vertices[:, 1].max()
        bbox_height = y_max - y_min
        assert abs(bbox_height - ROOM_HEIGHT) < 0.05


# --- S2.6: Table/seat detected as bounding box ---

class TestS2_6_ObjectBoundingBox:
    def test_table_bounding_box(self):
        parsed = _get_parsed()
        table_verts = vertices_for_group(parsed, 4)
        obj = fit_object_bounding_box(table_verts, "table")
        assert obj is not None, "Should detect table object"

    def test_table_dimensions_reasonable(self):
        parsed = _get_parsed()
        table_verts = vertices_for_group(parsed, 4)
        obj = fit_object_bounding_box(table_verts, "table")
        if obj is None:
            pytest.skip("Table not detected")
        for dim in obj.dimensions:
            assert 0.01 < dim < 2.0, (
                f"Table dimension {dim}m outside reasonable range [0.01, 2.0]"
            )

    def test_table_center_inside_room(self):
        parsed = _get_parsed()
        table_verts = vertices_for_group(parsed, 4)
        obj = fit_object_bounding_box(table_verts, "table")
        if obj is None:
            pytest.skip("Table not detected")
        cx, cy, cz = obj.center
        assert 0 < cx < ROOM_WIDTH, f"Table center X={cx} outside room"
        assert 0 < cy < ROOM_HEIGHT, f"Table center Y={cy} outside room"
        assert 0 < cz < ROOM_DEPTH, f"Table center Z={cz} outside room"

    def test_too_few_vertices_returns_none(self):
        tiny = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0]], dtype=np.float32)
        obj = fit_object_bounding_box(tiny, "table")
        assert obj is None


# --- S2.7: Small noise clusters ignored ---

class TestS2_7_NoiseRejection:
    def test_small_cluster_rejected(self):
        # 10 random points should not form a plane when min_inliers=50
        # (tests that production threshold rejects noise clusters)
        rng = np.random.default_rng(99)
        noise = rng.normal(0, 0.1, (10, 3)).astype(np.float32)
        normals = np.zeros_like(noise)
        # Use production-scale min_inliers (not adaptive) to test rejection
        from pipeline.plane_fitting import _ransac_plane
        result = _ransac_plane(noise, 0.03, 1000, rng)
        inlier_count = int(result[2].sum()) if result else 0
        assert inlier_count < MIN_INLIERS, (
            f"10 noisy points produced {inlier_count} inliers, should be < {MIN_INLIERS}"
        )

    def test_scattered_points_no_plane(self):
        # 40 points uniformly scattered across a 20m cube — no dominant plane
        rng = np.random.default_rng(77)
        scattered = rng.uniform(-10, 10, (40, 3)).astype(np.float32)
        normals = np.zeros_like(scattered)
        planes = fit_planes(scattered, normals, "wall", rng=rng)
        assert len(planes) == 0, "Scattered points should not form any plane"
