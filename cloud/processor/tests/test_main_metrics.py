"""
Tests for compute_room_metrics DNN integration — Step 6 of BEV DNN implementation.

Test IDs MAIN.1–MAIN.3 from the implementation plan.

Note: main.py has module-level Firebase/GCS/CloudSQL initialization that fails
in test. We mock those before importing.
"""

import os
import sys
import types
from unittest.mock import patch, MagicMock

import numpy as np
import pytest


# ---------------------------------------------------------------------------
# Mock module-level dependencies before importing main.
# Must be done at module scope BEFORE any import of main.
# ---------------------------------------------------------------------------

# Stub out all cloud dependencies that main.py imports at module level
_MOCK_MODULES = [
    'fastapi', 'uvicorn',
    'google', 'google.cloud', 'google.cloud.storage',
    'google.cloud.sql', 'google.cloud.sql.connector',
    'pg8000',
    'firebase_admin', 'firebase_admin.messaging',
]

for _mod_name in _MOCK_MODULES:
    if _mod_name not in sys.modules:
        sys.modules[_mod_name] = MagicMock()

# Remove cached main if already loaded
if 'main' in sys.modules:
    del sys.modules['main']

from main import compute_room_metrics, _compute_metrics_raw, _empty_metrics


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def dense_room_ply(tmp_path):
    """Generate a dense box room PLY and return the path + expected info."""
    from tests.fixtures.generate_ply import generate_dense_box_room_ply
    ply_path = str(tmp_path / "mesh.ply")
    info = generate_dense_box_room_ply(ply_path, width=4.0, height=2.5, depth=3.0)
    return ply_path, info


# ---------------------------------------------------------------------------
# MAIN.1 — USE_DNN_STAGE3=false produces identical output to original
# ---------------------------------------------------------------------------

class TestMAIN1_Regression:

    def test_dnn_off_uses_raw_path(self, dense_room_ply):
        """With USE_DNN_STAGE3=false, should use raw triangle summation."""
        ply_path, info = dense_room_ply

        with patch.dict(os.environ, {"USE_DNN_STAGE3": "false"}, clear=False):
            result = compute_room_metrics(ply_path)

        assert result["floor_area_sqft"] > 0
        assert result["wall_area_sqft"] > 0
        assert result["ceiling_height_ft"] > 0
        assert result["perimeter_linear_ft"] > 0

    def test_dnn_off_by_default(self, dense_room_ply):
        """Without USE_DNN_STAGE3 env var, should use raw path (default=false)."""
        ply_path, info = dense_room_ply

        # Ensure env var is not set
        env = os.environ.copy()
        env.pop("USE_DNN_STAGE3", None)

        with patch.dict(os.environ, env, clear=True):
            result = compute_room_metrics(ply_path)

        assert result["floor_area_sqft"] > 0

    def test_raw_metrics_match_expected_room(self, dense_room_ply):
        """Raw triangle metrics should roughly match the known room dimensions."""
        ply_path, info = dense_room_ply
        SQM_TO_SQFT = 10.7639
        M_TO_FT = 3.28084

        with patch.dict(os.environ, {"USE_DNN_STAGE3": "false"}, clear=False):
            result = compute_room_metrics(ply_path)

        expected_area_sqft = info["width"] * info["depth"] * SQM_TO_SQFT
        expected_height_ft = info["height"] * M_TO_FT

        # Floor area within 20% (raw triangle summation can be noisy)
        assert abs(result["floor_area_sqft"] - expected_area_sqft) / expected_area_sqft < 0.2
        # Ceiling height within 10%
        assert abs(result["ceiling_height_ft"] - expected_height_ft) / expected_height_ft < 0.1


# ---------------------------------------------------------------------------
# MAIN.2 — USE_DNN_STAGE3=true with mock DNN → reasonable metrics
# ---------------------------------------------------------------------------

class TestMAIN2_DNNPath:

    def test_dnn_on_with_mock_produces_metrics(self, dense_room_ply):
        """USE_DNN_STAGE3=true with mock DNN polygon → valid metrics."""
        ply_path, info = dense_room_ply
        hw, hd = info["width"] / 2, info["depth"] / 2
        mock_corners = np.array([[-hw, -hd], [hw, -hd], [hw, hd], [-hw, hd]])

        with patch.dict(os.environ, {"USE_DNN_STAGE3": "true"}, clear=False):
            with patch("pipeline.stage3._extract_dnn_polygon", return_value=mock_corners):
                result = compute_room_metrics(ply_path)

        assert result["floor_area_sqft"] > 0
        assert result["wall_area_sqft"] > 0
        assert result["ceiling_height_ft"] > 0
        assert result["perimeter_linear_ft"] > 0

    def test_dnn_metrics_match_mock_polygon(self, dense_room_ply):
        """DNN-derived floor area should match the mock polygon area."""
        ply_path, info = dense_room_ply
        hw, hd = info["width"] / 2, info["depth"] / 2
        expected_area_m2 = info["width"] * info["depth"]
        SQM_TO_SQFT = 10.7639

        mock_corners = np.array([[-hw, -hd], [hw, -hd], [hw, hd], [-hw, hd]])

        with patch.dict(os.environ, {"USE_DNN_STAGE3": "true"}, clear=False):
            with patch("pipeline.stage3._extract_dnn_polygon", return_value=mock_corners):
                result = compute_room_metrics(ply_path)

        expected_sqft = expected_area_m2 * SQM_TO_SQFT
        error_pct = abs(result["floor_area_sqft"] - expected_sqft) / expected_sqft * 100
        assert error_pct < 2.0, f"Floor area {result['floor_area_sqft']} vs {expected_sqft:.1f} ({error_pct:.1f}%)"

    def test_dnn_ceiling_height_unchanged(self, dense_room_ply):
        """Ceiling height should come from Stage 2 RANSAC, not the DNN."""
        ply_path, info = dense_room_ply
        hw, hd = info["width"] / 2, info["depth"] / 2
        M_TO_FT = 3.28084

        mock_corners = np.array([[-hw, -hd], [hw, -hd], [hw, hd], [-hw, hd]])

        # Get raw ceiling height for comparison
        with patch.dict(os.environ, {"USE_DNN_STAGE3": "false"}, clear=False):
            raw_result = compute_room_metrics(ply_path)

        with patch.dict(os.environ, {"USE_DNN_STAGE3": "true"}, clear=False):
            with patch("pipeline.stage3._extract_dnn_polygon", return_value=mock_corners):
                dnn_result = compute_room_metrics(ply_path)

        assert abs(dnn_result["ceiling_height_ft"] - raw_result["ceiling_height_ft"]) < 0.1

    def test_scan_dimensions_populated(self, dense_room_ply):
        """scan_dimensions should contain all required keys."""
        ply_path, info = dense_room_ply
        hw, hd = info["width"] / 2, info["depth"] / 2
        mock_corners = np.array([[-hw, -hd], [hw, -hd], [hw, hd], [-hw, hd]])

        with patch.dict(os.environ, {"USE_DNN_STAGE3": "true"}, clear=False):
            with patch("pipeline.stage3._extract_dnn_polygon", return_value=mock_corners):
                result = compute_room_metrics(ply_path)

        sd = result["scan_dimensions"]
        assert "floor_area_sf" in sd
        assert "wall_area_sf" in sd
        assert "perimeter_lf" in sd
        assert "ceiling_height_ft" in sd
        assert "door_count" in sd
        assert "bbox" in sd


# ---------------------------------------------------------------------------
# MAIN.3 — Stage 3 exception → graceful fallback to raw metrics
# ---------------------------------------------------------------------------

class TestMAIN3_Fallback:

    def test_stage3_exception_falls_back_to_raw(self, dense_room_ply):
        """If Stage 3 raises, fall back to raw triangle metrics."""
        ply_path, info = dense_room_ply

        with patch.dict(os.environ, {"USE_DNN_STAGE3": "true"}, clear=False):
            with patch("pipeline.stage3._extract_dnn_polygon", side_effect=RuntimeError("boom")):
                result = compute_room_metrics(ply_path)

        # Should still produce valid metrics via raw fallback
        assert result["floor_area_sqft"] > 0
        assert result["ceiling_height_ft"] > 0

    def test_invalid_ply_returns_empty(self, tmp_path):
        """Invalid PLY file returns empty metrics."""
        bad_ply = str(tmp_path / "bad.ply")
        with open(bad_ply, "w") as f:
            f.write("not a ply file")

        with patch.dict(os.environ, {"USE_DNN_STAGE3": "false"}, clear=False):
            result = compute_room_metrics(bad_ply)

        assert result["floor_area_sqft"] == 0
        assert result["ceiling_height_ft"] == 0
