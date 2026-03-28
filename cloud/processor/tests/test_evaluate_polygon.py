"""
Tests for Polygon Evaluation — Step 2 of BEV DNN implementation.

Test IDs EVAL.1–EVAL.3 map to the implementation plan.
"""

import numpy as np
import pytest

# Import from scripts — add to path
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from evaluate_polygon import (
    polygon_area,
    polygon_perimeter,
    polygon_iou,
    corner_position_error,
    corner_count_accuracy,
    evaluate_polygons,
)


# ---------------------------------------------------------------------------
# Helper: simple square polygon
# ---------------------------------------------------------------------------

def _square(side: float = 2.0, cx: float = 0.0, cz: float = 0.0) -> np.ndarray:
    """Return a CCW square polygon centered at (cx, cz)."""
    h = side / 2.0
    return np.array([
        [cx - h, cz - h],
        [cx + h, cz - h],
        [cx + h, cz + h],
        [cx - h, cz + h],
    ])


# ---------------------------------------------------------------------------
# EVAL.1 — Identical polygons → perfect scores
# ---------------------------------------------------------------------------

class TestEVAL1_IdenticalPolygons:

    def test_iou_perfect(self):
        poly = _square(2.0)
        iou = polygon_iou(poly, poly, cell_size=0.02)
        assert abs(iou - 1.0) < 0.01, f"IoU should be 1.0 for identical polygons, got {iou}"

    def test_cpe_zero(self):
        poly = _square(2.0)
        cpe = corner_position_error(poly, poly)
        assert cpe["mean_cpe"] < 0.001, f"Mean CPE should be ~0 for identical, got {cpe['mean_cpe']}"

    def test_area_error_zero(self):
        poly = _square(2.0)
        results = evaluate_polygons(poly, poly)
        assert results["area_error_pct"] < 0.01

    def test_perimeter_error_zero(self):
        poly = _square(2.0)
        results = evaluate_polygons(poly, poly)
        assert results["perimeter_error_pct"] < 0.01

    def test_corner_count_exact(self):
        poly = _square(2.0)
        results = evaluate_polygons(poly, poly)
        assert results["corner_count_accuracy"] == 1.0


# ---------------------------------------------------------------------------
# EVAL.2 — Scaled polygon → predictable area/IoU differences
# ---------------------------------------------------------------------------

class TestEVAL2_ScaledPolygon:

    def test_area_error_for_110pct_scale(self):
        """A 110% scaled polygon has 121% area → ~21% area error."""
        truth = _square(2.0)
        pred = _square(2.2)  # 110% scale
        results = evaluate_polygons(pred, truth)
        # Area ratio: (2.2^2) / (2.0^2) = 4.84 / 4.0 = 1.21 → 21% error
        assert abs(results["area_error_pct"] - 21.0) < 1.0, \
            f"Area error should be ~21%, got {results['area_error_pct']:.1f}%"

    def test_iou_less_than_one(self):
        truth = _square(2.0)
        pred = _square(2.2)
        iou = polygon_iou(pred, truth, cell_size=0.02)
        assert iou < 1.0
        # Theoretical IoU: inner=4.0, outer=4.84, IoU = 4.0/4.84 ≈ 0.826
        assert iou > 0.75, f"IoU should be ~0.83 for 10% scale, got {iou}"

    def test_perimeter_error_for_110pct_scale(self):
        truth = _square(2.0)
        pred = _square(2.2)
        results = evaluate_polygons(pred, truth)
        # Perimeter ratio: (4*2.2)/(4*2.0) = 1.10 → 10% error
        assert abs(results["perimeter_error_pct"] - 10.0) < 1.0


# ---------------------------------------------------------------------------
# EVAL.3 — Rotated polygon → positive CPE and IoU < 1
# ---------------------------------------------------------------------------

class TestEVAL3_RotatedPolygon:

    def test_rotated_has_positive_cpe(self):
        """A 45-degree rotated square should have positive corner position error."""
        truth = _square(2.0)
        angle = np.radians(45)
        cos_a, sin_a = np.cos(angle), np.sin(angle)
        rot = np.array([[cos_a, -sin_a], [sin_a, cos_a]])
        pred = (truth @ rot.T)

        cpe = corner_position_error(pred, truth)
        assert cpe["mean_cpe"] > 0.0

    def test_rotated_has_iou_less_than_one(self):
        truth = _square(2.0)
        angle = np.radians(15)
        cos_a, sin_a = np.cos(angle), np.sin(angle)
        rot = np.array([[cos_a, -sin_a], [sin_a, cos_a]])
        pred = (truth @ rot.T)

        iou = polygon_iou(pred, truth, cell_size=0.02)
        assert iou < 1.0
        assert iou > 0.5, f"15-deg rotation IoU should be > 0.5, got {iou}"

    def test_rotated_same_area(self):
        """Rotation shouldn't change the area."""
        truth = _square(2.0)
        angle = np.radians(30)
        cos_a, sin_a = np.cos(angle), np.sin(angle)
        rot = np.array([[cos_a, -sin_a], [sin_a, cos_a]])
        pred = (truth @ rot.T)

        results = evaluate_polygons(pred, truth)
        assert results["area_error_pct"] < 1.0, \
            f"Rotation shouldn't change area, got {results['area_error_pct']:.1f}% error"


# ---------------------------------------------------------------------------
# Additional: corner_count_accuracy scoring
# ---------------------------------------------------------------------------

class TestCornerCountScoring:

    def test_exact_match(self):
        assert corner_count_accuracy(4, 4) == 1.0

    def test_off_by_one(self):
        assert corner_count_accuracy(5, 4) == 0.8

    def test_off_by_two(self):
        assert corner_count_accuracy(6, 4) == 0.5

    def test_off_by_three(self):
        assert corner_count_accuracy(7, 4) == 0.0


# ---------------------------------------------------------------------------
# Additional: polygon_area and polygon_perimeter unit tests
# ---------------------------------------------------------------------------

class TestPolygonMath:

    def test_square_area(self):
        poly = _square(3.0)
        assert abs(polygon_area(poly) - 9.0) < 0.001

    def test_square_perimeter(self):
        poly = _square(3.0)
        assert abs(polygon_perimeter(poly) - 12.0) < 0.001

    def test_triangle_area(self):
        tri = np.array([[0, 0], [4, 0], [0, 3]])
        assert abs(polygon_area(tri) - 6.0) < 0.001
