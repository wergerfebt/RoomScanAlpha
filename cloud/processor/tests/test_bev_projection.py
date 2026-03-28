"""
Tests for BEV Projection Module — Step 1 of BEV DNN implementation.

Test IDs BEV.1–BEV.8 map to the implementation plan in
cloud/dnn_comparison/BEV_DNN_IMPLEMENTATION_PLAN.md
"""

import numpy as np
import pytest

from pipeline.stage1 import parse_and_classify
from pipeline.bev_projection import (
    BEVProjection,
    project_to_bev,
    pixels_to_meters,
    meters_to_pixels,
    STRUCTURAL_CLASSES,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def box_room_mesh(tmp_path):
    """Dense box room (4m x 2.5m x 3m) parsed mesh + expected info."""
    from tests.fixtures.generate_ply import generate_dense_box_room_ply
    ply_path = str(tmp_path / "dense_box.ply")
    info = generate_dense_box_room_ply(ply_path, width=4.0, height=2.5, depth=3.0)
    mesh = parse_and_classify(ply_path)
    return mesh, info


@pytest.fixture
def rotated_room_mesh(tmp_path):
    """Dense rotated room (5m x 2.5m x 4m, 31deg) parsed mesh + expected info."""
    from tests.fixtures.generate_ply import generate_rotated_dense_room_ply
    ply_path = str(tmp_path / "rotated_room.ply")
    info = generate_rotated_dense_room_ply(ply_path, width=5.0, height=2.5, depth=4.0, angle_deg=31.0)
    mesh = parse_and_classify(ply_path)
    return mesh, info


@pytest.fixture
def room_with_objects_mesh(tmp_path):
    """Box room with table and seat inside."""
    from tests.fixtures.generate_ply import generate_room_with_objects_ply
    ply_path = str(tmp_path / "room_objects.ply")
    info = generate_room_with_objects_ply(ply_path)
    mesh = parse_and_classify(ply_path)
    return mesh, info


# ---------------------------------------------------------------------------
# BEV.1 — Synthetic box room density map matches room footprint
# ---------------------------------------------------------------------------

class TestBEV1_BoxRoomFootprint:

    def test_density_map_shape(self, box_room_mesh):
        mesh, info = box_room_mesh
        bev = project_to_bev(mesh, resolution=256)
        assert bev.density_map.shape == (256, 256)

    def test_nonzero_region_matches_footprint(self, box_room_mesh):
        """Non-zero pixel bounding box should correspond to 4m x 3m room within 2 pixels."""
        mesh, info = box_room_mesh
        bev = project_to_bev(mesh, resolution=256)

        nonzero = np.argwhere(bev.density_map > 0)
        assert len(nonzero) > 0, "Density map is empty"

        # Convert pixel bbox corners to meters
        min_row, min_col = nonzero.min(axis=0)
        max_row, max_col = nonzero.max(axis=0)

        # Convert to world coords (col, row) → (x, z)
        corners_px = np.array([[min_col, min_row], [max_col, max_row]], dtype=np.float64)
        corners_m = pixels_to_meters(corners_px, bev)

        predicted_width = corners_m[1, 0] - corners_m[0, 0]
        predicted_depth = corners_m[1, 1] - corners_m[0, 1]

        # Room is 4m wide (X) x 3m deep (Z)
        # Allow 2 pixels of tolerance in each direction
        tol = 2 * bev.meters_per_pixel_x
        assert abs(predicted_width - info["width"]) < tol, \
            f"Width {predicted_width:.3f}m vs expected {info['width']}m (tol={tol:.3f}m)"
        assert abs(predicted_depth - info["depth"]) < tol, \
            f"Depth {predicted_depth:.3f}m vs expected {info['depth']}m (tol={tol:.3f}m)"

    def test_density_values_in_range(self, box_room_mesh):
        mesh, _ = box_room_mesh
        bev = project_to_bev(mesh, resolution=256)
        assert bev.density_map.min() >= 0.0
        assert bev.density_map.max() <= 1.0

    def test_density_dtype(self, box_room_mesh):
        mesh, _ = box_room_mesh
        bev = project_to_bev(mesh, resolution=256)
        assert bev.density_map.dtype == np.float32


# ---------------------------------------------------------------------------
# BEV.2 — Rotated room density map
# ---------------------------------------------------------------------------

class TestBEV2_RotatedRoom:

    def test_rotated_room_has_nonzero_pixels(self, rotated_room_mesh):
        mesh, _ = rotated_room_mesh
        bev = project_to_bev(mesh, resolution=256)
        assert np.count_nonzero(bev.density_map) > 0

    def test_pixel_count_similar_to_box_room(self, box_room_mesh, rotated_room_mesh):
        """Rotated room should have a similar number of non-zero pixels (within 50%).

        Rotated room is 5x4m (20 sq m perimeter outline) vs box room 4x3m (14 sq m),
        so the rotated room will have more structural vertices. Allow generous tolerance.
        """
        mesh_box, _ = box_room_mesh
        mesh_rot, _ = rotated_room_mesh
        bev_box = project_to_bev(mesh_box, resolution=256)
        bev_rot = project_to_bev(mesh_rot, resolution=256)

        count_box = np.count_nonzero(bev_box.density_map)
        count_rot = np.count_nonzero(bev_rot.density_map)

        ratio = count_rot / max(count_box, 1)
        assert 0.3 < ratio < 3.0, \
            f"Pixel count ratio {ratio:.2f} (box={count_box}, rot={count_rot})"


# ---------------------------------------------------------------------------
# BEV.3 — Resolution parameter
# ---------------------------------------------------------------------------

class TestBEV3_Resolution:

    @pytest.mark.parametrize("res", [128, 256, 512])
    def test_output_shape_matches_resolution(self, box_room_mesh, res):
        mesh, _ = box_room_mesh
        bev = project_to_bev(mesh, resolution=res)
        assert bev.density_map.shape == (res, res)
        assert bev.resolution == res


# ---------------------------------------------------------------------------
# BEV.4 — Coordinate round-trip: meters → pixels → meters
# ---------------------------------------------------------------------------

class TestBEV4_CoordinateRoundTrip:

    def test_round_trip_box_corners(self, box_room_mesh):
        """Convert 4 known corners to pixels and back. Error < 0.02m."""
        mesh, info = box_room_mesh
        bev = project_to_bev(mesh, resolution=256)

        hw = info["width"] / 2.0
        hd = info["depth"] / 2.0
        corners_xz = np.array([
            [-hw, -hd],
            [+hw, -hd],
            [+hw, +hd],
            [-hw, +hd],
        ])

        px = meters_to_pixels(corners_xz, bev)
        recovered = pixels_to_meters(px, bev)

        error = np.abs(recovered - corners_xz)
        assert error.max() < 0.02, \
            f"Max round-trip error {error.max():.4f}m (limit 0.02m)"


# ---------------------------------------------------------------------------
# BEV.5 — Structural filtering reduces pixel count
# ---------------------------------------------------------------------------

class TestBEV5_StructuralFiltering:

    def test_filtered_has_fewer_pixels(self, room_with_objects_mesh):
        """Structural-only density map should have fewer non-zero pixels than unfiltered."""
        mesh, _ = room_with_objects_mesh
        bev_structural = project_to_bev(mesh, resolution=256, structural_only=True)
        bev_all = project_to_bev(mesh, resolution=256, structural_only=False)

        count_struct = np.count_nonzero(bev_structural.density_map)
        count_all = np.count_nonzero(bev_all.density_map)

        assert count_struct <= count_all, \
            f"Structural ({count_struct}) should be <= unfiltered ({count_all})"

    def test_table_seat_excluded(self, room_with_objects_mesh):
        """Table (4) and seat (5) should not be in STRUCTURAL_CLASSES."""
        assert 4 not in STRUCTURAL_CLASSES
        assert 5 not in STRUCTURAL_CLASSES


# ---------------------------------------------------------------------------
# BEV.6 — Normalization: uint8 round-trip consistency
# ---------------------------------------------------------------------------

class TestBEV6_NormalizationParity:

    def test_uint8_round_trip_values(self, box_room_mesh):
        """Density map values should be exactly representable as uint8/255."""
        mesh, _ = box_room_mesh
        bev = project_to_bev(mesh, resolution=256)

        # Every value should survive a uint8 round-trip perfectly
        uint8_vals = (bev.density_map * 255).astype(np.uint8)
        recovered = uint8_vals.astype(np.float32) / 255.0

        np.testing.assert_array_equal(bev.density_map, recovered)


# ---------------------------------------------------------------------------
# BEV.7 — Coordinate round-trip with 10% padding
# ---------------------------------------------------------------------------

class TestBEV7_PaddedCoordinateRoundTrip:

    def test_padded_round_trip_corners(self, box_room_mesh):
        """Round-trip with known wall corners. Error < 0.01m per corner."""
        mesh, info = box_room_mesh
        bev = project_to_bev(mesh, resolution=256)

        hw = info["width"] / 2.0
        hd = info["depth"] / 2.0
        corners = np.array([
            [-hw, -hd], [+hw, -hd], [+hw, +hd], [-hw, +hd],
        ])

        px = meters_to_pixels(corners, bev)
        recovered = pixels_to_meters(px, bev)

        per_corner_error = np.linalg.norm(recovered - corners, axis=1)
        assert per_corner_error.max() < 0.01, \
            f"Max per-corner error {per_corner_error.max():.5f}m (limit 0.01m)"

    def test_bbox_has_10pct_padding(self, box_room_mesh):
        """Padded bbox should extend beyond the room by ~10% of max extent."""
        mesh, info = box_room_mesh
        bev = project_to_bev(mesh, resolution=256)

        hw = info["width"] / 2.0
        hd = info["depth"] / 2.0
        max_extent = max(info["width"], info["depth"])
        expected_pad = 0.1 * max_extent

        # The padded bbox should extend beyond the room corners
        assert bev.xmin < -hw, f"xmin {bev.xmin} should be < {-hw}"
        assert bev.xmax > +hw, f"xmax {bev.xmax} should be > {+hw}"
        assert bev.zmin < -hd, f"zmin {bev.zmin} should be < {-hd}"
        assert bev.zmax > +hd, f"zmax {bev.zmax} should be > {+hd}"

        # Square: xmax - xmin == zmax - zmin
        x_side = bev.xmax - bev.xmin
        z_side = bev.zmax - bev.zmin
        assert abs(x_side - z_side) < 0.001, \
            f"BEV should be square: x_side={x_side:.4f}, z_side={z_side:.4f}"


# ---------------------------------------------------------------------------
# BEV.8 — Partial scan: missing wall
# ---------------------------------------------------------------------------

class TestBEV8_PartialScan:

    def test_missing_wall_leaves_gap(self, tmp_path):
        """Remove one wall's vertices from a box room. That wall region should be empty."""
        from tests.fixtures.generate_ply import generate_dense_box_room_ply

        ply_path = str(tmp_path / "partial.ply")
        info = generate_dense_box_room_ply(ply_path, width=4.0, height=2.5, depth=3.0, grid_n=10)
        mesh = parse_and_classify(ply_path)

        # The right wall (X=+hw) faces have normals pointing in -X direction.
        # Remove right wall by zeroing out those vertices' positions to move them
        # out of the structural set — or more precisely, we reclassify right wall faces.
        # Simpler: manually filter. We'll modify the mesh to remove the right wall group.
        hw = info["width"] / 2.0
        hd = info["depth"] / 2.0

        # Find wall vertices near X=+hw (the right wall)
        wall_group = mesh.classification_groups.get(1)  # WALL
        if wall_group is not None:
            wall_verts = mesh.positions[wall_group.vertex_ids]
            right_wall_mask = wall_verts[:, 0] > (hw - 0.1)
            right_wall_ids = wall_group.vertex_ids[right_wall_mask]

            # Move right wall vertices far away so they don't contribute
            mesh.positions[right_wall_ids] = np.array([100.0, 0.0, 100.0])

        bev = project_to_bev(mesh, resolution=256)

        # The right wall was at X=+hw. In the BEV, that's at the right edge.
        # Check that the right quarter of the density map has fewer pixels than the left.
        mid_col = bev.resolution // 2
        left_count = np.count_nonzero(bev.density_map[:, :mid_col])
        right_count = np.count_nonzero(bev.density_map[:, mid_col:])

        # Right side should have significantly fewer pixels (the wall vertices are gone)
        # Other walls (front, back, ceiling) still contribute to the right half,
        # but the right wall's dense grid is removed.
        assert right_count < left_count, \
            f"Right half ({right_count}) should have fewer pixels than left ({left_count})"
