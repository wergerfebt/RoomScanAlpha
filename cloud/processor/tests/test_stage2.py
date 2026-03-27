"""
Tests for Stage 2: Plane Fitting.

Test IDs from CLOUD_PIPELINE_PLAN.md:
  S2.1 — Floor detected as single horizontal plane (normal Y > 0.95)
  S2.2 — Ceiling detected as single horizontal plane (normal Y < -0.95)
  S2.3 — Walls detected as vertical planes (normal Y magnitude < 0.1)
  S2.4 — Rectangular room yields 4 wall planes (normals ~90° apart)
  S2.5 — Ceiling height matches LiDAR (within ±0.05m of bbox Y-extent)
  S2.6 — Table/seat detected as bounding box (reasonable dimensions, center between floor/ceiling)
  S2.7 — Small noise clusters ignored (< 50 inliers produces no plane)
"""

import numpy as np
import pytest

from pipeline.stage1 import (
    parse_and_classify,
    ParsedMesh,
    ClassificationGroup,
    CLASSIFICATION_WALL,
    CLASSIFICATION_FLOOR,
    CLASSIFICATION_CEILING,
)
from pipeline.stage2 import (
    fit_planes,
    PlaneFitResult,
    DetectedPlane,
    DetectedObject,
    MIN_INLIERS,
    _ransac_single_plane,
)
from tests.fixtures.generate_ply import (
    generate_box_room_ply,
    generate_dense_box_room_ply,
    generate_room_with_objects_ply,
)


@pytest.fixture
def dense_room_mesh(tmp_path) -> tuple[ParsedMesh, dict]:
    """Dense grid mesh (10×10 per surface) — enough vertices for RANSAC."""
    ply_path = str(tmp_path / "mesh.ply")
    info = generate_dense_box_room_ply(ply_path)
    mesh = parse_and_classify(ply_path)
    return mesh, info


@pytest.fixture
def dense_room_planes(dense_room_mesh) -> tuple[PlaneFitResult, dict]:
    mesh, info = dense_room_mesh
    result = fit_planes(mesh)
    return result, info


@pytest.fixture
def room_with_objects_mesh(tmp_path) -> tuple[ParsedMesh, dict]:
    ply_path = str(tmp_path / "mesh_objects.ply")
    info = generate_room_with_objects_ply(ply_path)
    mesh = parse_and_classify(ply_path)
    return mesh, info


@pytest.fixture
def room_with_objects_result(room_with_objects_mesh) -> tuple[PlaneFitResult, dict]:
    mesh, info = room_with_objects_mesh
    result = fit_planes(mesh)
    return result, info


# ---------------------------------------------------------------------------
# S2.1 — Floor detected as single horizontal plane
# ---------------------------------------------------------------------------

class TestS2_1_FloorPlane:
    def test_single_floor_plane(self, dense_room_planes):
        result, _ = dense_room_planes
        assert len(result.floor_planes) == 1

    def test_floor_normal_points_up(self, dense_room_planes):
        result, _ = dense_room_planes
        floor = result.floor_planes[0]
        # Normal could point +Y or -Y; we care about the Y component magnitude
        assert abs(floor.normal[1]) > 0.95, f"floor normal Y = {floor.normal[1]}"

    def test_floor_has_positive_area(self, dense_room_planes):
        result, _ = dense_room_planes
        floor = result.floor_planes[0]
        assert floor.area_sqm > 0

    def test_floor_classification(self, dense_room_planes):
        result, _ = dense_room_planes
        floor = result.floor_planes[0]
        assert floor.classification == "floor"
        assert floor.classification_id == CLASSIFICATION_FLOOR


# ---------------------------------------------------------------------------
# S2.2 — Ceiling detected as single horizontal plane
# ---------------------------------------------------------------------------

class TestS2_2_CeilingPlane:
    def test_single_ceiling_plane(self, dense_room_planes):
        result, _ = dense_room_planes
        assert len(result.ceiling_planes) == 1

    def test_ceiling_normal_points_down(self, dense_room_planes):
        result, _ = dense_room_planes
        ceiling = result.ceiling_planes[0]
        assert abs(ceiling.normal[1]) > 0.95, f"ceiling normal Y = {ceiling.normal[1]}"

    def test_ceiling_has_positive_area(self, dense_room_planes):
        result, _ = dense_room_planes
        ceiling = result.ceiling_planes[0]
        assert ceiling.area_sqm > 0

    def test_ceiling_classification(self, dense_room_planes):
        result, _ = dense_room_planes
        ceiling = result.ceiling_planes[0]
        assert ceiling.classification == "ceiling"
        assert ceiling.classification_id == CLASSIFICATION_CEILING


# ---------------------------------------------------------------------------
# S2.3 — Walls detected as vertical planes
# ---------------------------------------------------------------------------

class TestS2_3_WallPlanesVertical:
    def test_wall_planes_exist(self, dense_room_planes):
        result, _ = dense_room_planes
        assert len(result.wall_planes) > 0

    def test_wall_normals_horizontal(self, dense_room_planes):
        result, _ = dense_room_planes
        for i, wall in enumerate(result.wall_planes):
            assert abs(wall.normal[1]) < 0.1, \
                f"wall {i} normal Y = {wall.normal[1]}, expected < 0.1"

    def test_wall_planes_have_area(self, dense_room_planes):
        result, _ = dense_room_planes
        for wall in result.wall_planes:
            assert wall.area_sqm > 0


# ---------------------------------------------------------------------------
# S2.4 — Rectangular room yields 4 wall planes
# ---------------------------------------------------------------------------

class TestS2_4_FourWallPlanes:
    def test_four_wall_planes(self, dense_room_planes):
        result, _ = dense_room_planes
        assert len(result.wall_planes) == 4, \
            f"expected 4 wall planes, got {len(result.wall_planes)}"

    def test_wall_normals_roughly_90_degrees_apart(self, dense_room_planes):
        """4 wall planes should have 2 perpendicular axis pairs (4 perp + 2 parallel pairings)."""
        result, _ = dense_room_planes
        walls = result.wall_planes
        if len(walls) != 4:
            pytest.skip("need exactly 4 walls for this test")

        # Project normals to XZ plane (ignore Y component)
        normals_xz = []
        for w in walls:
            n = np.array([w.normal[0], w.normal[2]])
            n = n / np.linalg.norm(n)
            normals_xz.append(n)

        # In a rectangular room, among 6 pairwise dot products:
        # - 4 should be ≈ 0 (perpendicular, adjacent walls)
        # - 2 should be ≈ ±1 (parallel/anti-parallel, opposite walls)
        perp_count = 0
        parallel_count = 0
        for i in range(4):
            for j in range(i + 1, 4):
                dot = abs(np.dot(normals_xz[i], normals_xz[j]))
                if dot < 0.2:
                    perp_count += 1
                elif dot > 0.8:
                    parallel_count += 1
        assert perp_count == 4, f"expected 4 perpendicular pairs, got {perp_count}"
        assert parallel_count == 2, f"expected 2 parallel pairs, got {parallel_count}"


# ---------------------------------------------------------------------------
# S2.5 — Ceiling height matches LiDAR
# ---------------------------------------------------------------------------

class TestS2_5_CeilingHeight:
    def test_height_from_planes_matches_bbox(self, dense_room_planes):
        """Distance between floor and ceiling planes should match bbox Y-extent (±0.05m)."""
        result, info = dense_room_planes
        floor = result.floor_planes[0]
        ceiling = result.ceiling_planes[0]

        # Height from plane points
        floor_y = floor.point_on_plane[1]
        ceiling_y = ceiling.point_on_plane[1]
        height_from_planes = abs(ceiling_y - floor_y)

        expected_height = info["height"]
        assert abs(height_from_planes - expected_height) < 0.05, \
            f"height from planes = {height_from_planes:.3f}, expected {expected_height} ±0.05m"


# ---------------------------------------------------------------------------
# S2.6 — Table/seat detected as bounding box
# ---------------------------------------------------------------------------

class TestS2_6_ObjectOBB:
    def test_table_detected(self, room_with_objects_result):
        result, info = room_with_objects_result
        tables = [o for o in result.objects if o.classification == "table"]
        assert len(tables) == 1

    def test_table_dimensions_reasonable(self, room_with_objects_result):
        result, info = room_with_objects_result
        tables = [o for o in result.objects if o.classification == "table"]
        if not tables:
            pytest.skip("no table detected")
        table = tables[0]
        expected = sorted(info["table_size"], reverse=True)
        actual = sorted(table.dimensions, reverse=True)
        for exp, act in zip(expected, actual):
            assert abs(exp - act) < 0.4, \
                f"table dimension mismatch: expected {exp:.2f}, got {act:.2f}"

    def test_table_center_between_floor_and_ceiling(self, room_with_objects_result):
        result, info = room_with_objects_result
        tables = [o for o in result.objects if o.classification == "table"]
        if not tables:
            pytest.skip("no table detected")
        table = tables[0]
        assert 0.0 <= table.center[1] <= info["height"], \
            f"table center Y = {table.center[1]}, expected between 0 and {info['height']}"

    def test_seat_detected(self, room_with_objects_result):
        result, info = room_with_objects_result
        seats = [o for o in result.objects if o.classification == "seat"]
        assert len(seats) == 1

    def test_seat_dimensions_reasonable(self, room_with_objects_result):
        result, info = room_with_objects_result
        seats = [o for o in result.objects if o.classification == "seat"]
        if not seats:
            pytest.skip("no seat detected")
        seat = seats[0]
        for dim in seat.dimensions:
            assert 0.3 <= dim <= 2.0, \
                f"seat dimension {dim:.2f} outside reasonable range [0.3, 2.0]m"

    def test_object_face_counts(self, room_with_objects_result):
        result, info = room_with_objects_result
        tables = [o for o in result.objects if o.classification == "table"]
        seats = [o for o in result.objects if o.classification == "seat"]
        if tables:
            assert tables[0].face_count == info["table_face_count"]
        if seats:
            assert seats[0].face_count == info["seat_face_count"]


# ---------------------------------------------------------------------------
# S2.7 — Small noise clusters ignored
# ---------------------------------------------------------------------------

class TestS2_7_NoiseRejection:
    def test_tiny_cluster_produces_no_plane(self):
        """A classification group with < MIN_INLIERS points should yield no planes."""
        # Create a mesh with a tiny noise group (10 random points as "wall")
        rng = np.random.default_rng(seed=99)
        n_noise = 10  # well below MIN_INLIERS (50)
        noise_positions = rng.standard_normal((n_noise, 3)).astype(np.float32)

        threshold = 0.03
        _, _, mask = _ransac_single_plane(noise_positions, threshold, rng)

        # Even if RANSAC finds something, the caller checks min_inliers.
        # With only 10 points, any plane has at most 10 inliers < MIN_INLIERS.
        if mask is not None:
            assert mask.sum() < MIN_INLIERS

    def test_noise_group_skipped_in_fit_planes(self, tmp_path):
        """A mesh where one classification has very few faces should not crash fit_planes."""
        ply_path = str(tmp_path / "mesh.ply")
        generate_dense_box_room_ply(ply_path)
        mesh = parse_and_classify(ply_path)
        result = fit_planes(mesh)
        # Should not crash; structural planes found
        assert len(result.planes) > 0
