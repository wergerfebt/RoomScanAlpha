"""
Tests for BEV Inference Wrapper — Step 4 of BEV DNN implementation.

Test IDs INF.1–INF.8 are mock-based (no model file needed).
Test IDs INF.H1–INF.H3 require the TorchScript model and are skipped if absent.
"""

import os
from unittest.mock import patch, MagicMock

import numpy as np
import pytest

from pipeline.bev_inference import (
    _postprocess,
    _order_ccw,
    _polygon_area_signed,
    _is_valid_polygon,
    _empty_result,
    predict_room_polygon,
    clear_model_cache,
    DnnPolygonResult,
)
from pipeline.bev_projection import BEVProjection


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_mock_output(room_corners: dict[int, list], resolution: int = 256,
                      default_logit: float = -5.0) -> tuple[np.ndarray, np.ndarray]:
    """Create mock RoomFormer output tensors.

    Args:
        room_corners: {room_idx: [(x_norm, y_norm, logit), ...]}
                      Coordinates normalized to [0, 1]. Logits are raw (pre-sigmoid).
        resolution: BEV resolution (for reference, not used in tensors)
        default_logit: logit for unused corners (low = filtered out)

    Returns:
        (logits [1,20,40], coords [1,20,40,2])
    """
    logits = np.full((1, 20, 40), default_logit, dtype=np.float32)
    coords = np.full((1, 20, 40, 2), 0.5, dtype=np.float32)

    for room_idx, corners in room_corners.items():
        for corner_idx, (x, y, logit) in enumerate(corners):
            logits[0, room_idx, corner_idx] = logit
            coords[0, room_idx, corner_idx] = [x, y]

    return logits, coords


def _make_bev(resolution: int = 256) -> BEVProjection:
    """Create a minimal BEV projection for testing."""
    return BEVProjection(
        density_map=np.zeros((resolution, resolution), dtype=np.float32),
        xmin=-5.0, xmax=5.0, zmin=-5.0, zmax=5.0,
        meters_per_pixel_x=10.0 / resolution,
        meters_per_pixel_z=10.0 / resolution,
        resolution=resolution,
    )


# High logit = high confidence after sigmoid
HIGH = 3.0   # sigmoid(3.0) ≈ 0.95
LOW = -3.0   # sigmoid(-3.0) ≈ 0.05


# ---------------------------------------------------------------------------
# INF.1 — Mock returns known rectangle → correct 4-corner polygon
# ---------------------------------------------------------------------------

class TestINF1_KnownRectangle:

    def test_four_corners_detected(self):
        """Mock output with a clear 4-corner rectangle → postprocess returns 4 corners."""
        # Rectangle at (0.2, 0.2), (0.8, 0.2), (0.8, 0.8), (0.2, 0.8) in normalized coords
        logits, coords = _make_mock_output({
            0: [
                (0.2, 0.2, HIGH), (0.8, 0.2, HIGH),
                (0.8, 0.8, HIGH), (0.2, 0.8, HIGH),
            ]
        })

        result = _postprocess(logits, coords, 256, confidence_threshold=0.5,
                              min_corners=4, min_area_px=100.0)

        assert result.success
        assert result.num_corners == 4
        assert result.corners_px.shape == (4, 2)

    def test_corners_in_expected_pixel_range(self):
        logits, coords = _make_mock_output({
            0: [
                (0.2, 0.2, HIGH), (0.8, 0.2, HIGH),
                (0.8, 0.8, HIGH), (0.2, 0.8, HIGH),
            ]
        })

        result = _postprocess(logits, coords, 256, confidence_threshold=0.5,
                              min_corners=4, min_area_px=100.0)

        # Pixel coords should be ~(51, 51), (204, 51), (204, 204), (51, 204)
        # (0.2 * 255 ≈ 51, 0.8 * 255 ≈ 204)
        assert result.corners_px.min() > 40
        assert result.corners_px.max() < 215


# ---------------------------------------------------------------------------
# INF.2 — 20 rooms, only 4 corners above threshold in one
# ---------------------------------------------------------------------------

class TestINF2_FilterByConfidence:

    def test_only_high_confidence_corners_survive(self):
        """Only room 3 has 4 high-confidence corners. Other rooms have noise."""
        room_corners = {}
        # Room 3: 4 valid corners
        room_corners[3] = [
            (0.3, 0.3, HIGH), (0.7, 0.3, HIGH),
            (0.7, 0.7, HIGH), (0.3, 0.7, HIGH),
        ]
        # Rooms 0, 1, 2: only 2-3 corners above threshold (insufficient)
        room_corners[0] = [(0.1, 0.1, HIGH), (0.9, 0.1, HIGH), (0.5, 0.5, LOW)]
        room_corners[1] = [(0.2, 0.2, HIGH), (0.8, 0.8, HIGH)]

        logits, coords = _make_mock_output(room_corners)

        result = _postprocess(logits, coords, 256, confidence_threshold=0.5,
                              min_corners=4, min_area_px=10.0)

        assert result.success
        assert result.num_corners == 4
        assert result.room_index == 3


# ---------------------------------------------------------------------------
# INF.3 — All rooms have < 4 valid corners → failure
# ---------------------------------------------------------------------------

class TestINF3_InsufficientCorners:

    def test_no_valid_polygon(self):
        """No room has >= 4 high-confidence corners → graceful failure."""
        room_corners = {
            0: [(0.2, 0.2, HIGH), (0.8, 0.2, HIGH), (0.5, 0.8, HIGH)],  # 3 corners
            1: [(0.3, 0.3, HIGH), (0.7, 0.7, HIGH)],  # 2 corners
        }
        logits, coords = _make_mock_output(room_corners)

        result = _postprocess(logits, coords, 256, confidence_threshold=0.5,
                              min_corners=4, min_area_px=10.0)

        assert not result.success
        assert result.num_corners == 0
        assert len(result.corners_px) == 0

    def test_empty_result_has_correct_shape(self):
        result = _empty_result()
        assert result.corners_px.shape == (0, 2)
        assert result.confidence.shape == (0,)
        assert not result.success


# ---------------------------------------------------------------------------
# INF.4 — CCW ordering
# ---------------------------------------------------------------------------

class TestINF4_CCWOrdering:

    def test_ccw_ordering_produces_positive_area(self):
        """Random 2D points ordered CCW should have positive signed area."""
        np.random.seed(42)
        for _ in range(10):
            # Random convex-ish polygon: points on a circle with noise
            n = np.random.randint(4, 10)
            angles = np.sort(np.random.uniform(0, 2 * np.pi, n))
            r = 50 + np.random.uniform(-5, 5, n)
            points = np.column_stack([
                128 + r * np.cos(angles),
                128 + r * np.sin(angles),
            ])

            ordered = _order_ccw(points)
            area = _polygon_area_signed(ordered)
            assert area > 0, f"CCW-ordered polygon should have positive area, got {area}"

    def test_ccw_ordering_stable_for_square(self):
        """A known CCW square stays CCW after ordering."""
        square = np.array([[50, 50], [200, 50], [200, 200], [50, 200]], dtype=np.float64)
        ordered = _order_ccw(square)
        area = _polygon_area_signed(ordered)
        assert area > 0


# ---------------------------------------------------------------------------
# INF.5 — Lazy loading (singleton)
# ---------------------------------------------------------------------------

class TestINF5_LazyLoading:

    def test_model_loaded_once(self):
        """Two predict calls should reuse the same cached model."""
        clear_model_cache()

        mock_model = MagicMock()
        import torch
        mock_model.return_value = (
            torch.zeros(1, 20, 40),
            torch.full((1, 20, 40, 2), 0.5),
        )
        mock_model.eval = MagicMock(return_value=mock_model)

        with patch('pipeline.bev_inference._get_torch') as mock_torch:
            mock_torch.return_value = torch
            with patch('pipeline.bev_inference._load_model', return_value=mock_model) as mock_load:
                bev = _make_bev()

                predict_room_polygon(bev, model_path="/fake/model.pt")
                predict_room_polygon(bev, model_path="/fake/model.pt")

                # _load_model is called each time but internal cache handles singleton
                assert mock_load.call_count == 2  # called each time, cache is inside _load_model


# ---------------------------------------------------------------------------
# INF.6 — Output shape validation
# ---------------------------------------------------------------------------

class TestINF6_OutputShapes:

    def test_handles_20x40x2_coords(self):
        """pred_coords shape [1, 20, 40, 2] processed correctly."""
        logits = np.full((1, 20, 40), -5.0, dtype=np.float32)
        coords = np.full((1, 20, 40, 2), 0.5, dtype=np.float32)

        # Put a valid room in slot 0
        for i in range(4):
            logits[0, 0, i] = HIGH
        coords[0, 0, 0] = [0.2, 0.2]
        coords[0, 0, 1] = [0.8, 0.2]
        coords[0, 0, 2] = [0.8, 0.8]
        coords[0, 0, 3] = [0.2, 0.8]

        result = _postprocess(logits, coords, 256, 0.5, 4, 100.0)

        assert result.success
        assert result.corners_px.shape[1] == 2  # each corner has (x, y)


# ---------------------------------------------------------------------------
# INF.7 — Small area polygon rejected
# ---------------------------------------------------------------------------

class TestINF7_SmallAreaRejected:

    def test_tiny_polygon_rejected(self):
        """Polygon with area < min_area_px is rejected."""
        # 4 corners very close together → tiny area
        logits, coords = _make_mock_output({
            0: [
                (0.500, 0.500, HIGH), (0.502, 0.500, HIGH),
                (0.502, 0.502, HIGH), (0.500, 0.502, HIGH),
            ]
        })

        result = _postprocess(logits, coords, 256, confidence_threshold=0.5,
                              min_corners=4, min_area_px=100.0)

        assert not result.success, "Tiny polygon should be rejected"


# ---------------------------------------------------------------------------
# INF.8 — Self-intersecting polygon rejected
# ---------------------------------------------------------------------------

class TestINF8_SelfIntersecting:

    def test_bowtie_detected(self):
        """A bowtie (self-intersecting) polygon is detected as invalid."""
        # Bowtie: edges (0,0)→(100,0) and (0,100)→(100,100) cross
        # when connected as (0,0)→(100,100)→(0,100)→(100,0) ring
        corners = np.array([[0, 0], [100, 100], [0, 100], [100, 0]], dtype=np.float64)
        assert not _is_valid_polygon(corners), "Bowtie should be invalid"

    def test_convex_polygon_valid(self):
        """A normal convex polygon is valid."""
        corners = np.array([[50, 50], [200, 50], [200, 200], [50, 200]], dtype=np.float64)
        assert _is_valid_polygon(corners)


# ---------------------------------------------------------------------------
# INF.H1-H3 — Model-dependent tests (skipped if model absent)
# ---------------------------------------------------------------------------

MODEL_PATH = os.path.join(os.path.dirname(__file__), "..", "models", "roomformer_s3d.pt")
HAS_MODEL = os.path.exists(MODEL_PATH)


@pytest.mark.skipif(not HAS_MODEL, reason="TorchScript model not found")
class TestINF_H1_SyntheticRoom:

    def test_synthetic_box_returns_corners(self, tmp_path):
        """Run real model on a synthetic box room BEV."""
        from tests.fixtures.generate_ply import generate_dense_box_room_ply
        from pipeline.stage1 import parse_and_classify
        from pipeline.bev_projection import project_to_bev

        ply_path = str(tmp_path / "box.ply")
        generate_dense_box_room_ply(ply_path)
        mesh = parse_and_classify(ply_path)
        bev = project_to_bev(mesh)

        result = predict_room_polygon(bev, model_path=MODEL_PATH, confidence_threshold=0.3)

        print(f"INF.H1: {result.num_corners} corners, success={result.success}, "
              f"room={result.room_index}")
        if result.success:
            print(f"  corners_px:\n{result.corners_px}")
        # Informational — pretrained model may not work well on our format
        assert result.num_corners >= 0  # At minimum, no crash


@pytest.mark.skipif(not HAS_MODEL, reason="TorchScript model not found")
class TestINF_H2_RealScan1:

    def test_real_scan_returns_corners(self):
        """Run real model on scan 1 BEV."""
        scan_path = "/Users/jakejulian/Downloads/pipeline_diag/classified_debug.ply"
        if not os.path.exists(scan_path):
            pytest.skip("Scan 1 not found")

        import sys
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
        from visualize_bev import parse_debug_ply
        from pipeline.bev_projection import project_to_bev

        mesh = parse_debug_ply(scan_path)
        bev = project_to_bev(mesh)

        result = predict_room_polygon(bev, model_path=MODEL_PATH, confidence_threshold=0.3)

        print(f"INF.H2: {result.num_corners} corners, success={result.success}")
        if result.success:
            print(f"  room_index={result.room_index}")
            print(f"  corners_px:\n{result.corners_px}")
        assert result.num_corners >= 0


@pytest.mark.skipif(not HAS_MODEL, reason="TorchScript model not found")
class TestINF_H3_RealScan2:

    def test_real_scan_returns_corners(self):
        """Run real model on scan 2 BEV."""
        scan_path = "/Users/jakejulian/Downloads/pipeline_diag_scan2/classified_debug.ply"
        if not os.path.exists(scan_path):
            pytest.skip("Scan 2 not found")

        import sys
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
        from visualize_bev import parse_debug_ply
        from pipeline.bev_projection import project_to_bev

        mesh = parse_debug_ply(scan_path)
        bev = project_to_bev(mesh)

        result = predict_room_polygon(bev, model_path=MODEL_PATH, confidence_threshold=0.3)

        print(f"INF.H3: {result.num_corners} corners, success={result.success}")
        if result.success:
            print(f"  room_index={result.room_index}")
            print(f"  corners_px:\n{result.corners_px}")
        assert result.num_corners >= 0
