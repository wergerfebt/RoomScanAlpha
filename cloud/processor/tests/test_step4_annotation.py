"""Tests for Step 4: annotated polygon → room dimensions.

Test IDs from IMPLEMENTATION_PLAN_MVP.md:
  4.3  Cloud uses annotated polygon for dimensions
  4.4  Dimensions match polygon geometry
  4.5  Fallback to Stage 3 when no annotation
  4.6  API returns polygon in feet
  4.8  Phase 1 scans return null polygon

These tests extract _compute_from_annotation and its constants without
importing the full main.py (which requires FastAPI, GCS, etc.).
"""

import importlib.util
import os
import sys
import types


def _load_compute_function():
    """Load _compute_from_annotation and constants from main.py without triggering
    top-level imports (FastAPI, GCS, Firebase, etc.)."""
    main_path = os.path.join(os.path.dirname(__file__), "..", "main.py")
    with open(main_path, "r") as f:
        source = f.read()

    # Extract just the constants and the function we need
    # by creating a minimal module with only stdlib imports
    module = types.ModuleType("main_extract")
    module.__dict__["Optional"] = None  # type hint compat

    # Execute only the lines we need
    exec_source = ""
    # Grab constant definitions
    for line in source.split("\n"):
        if line.startswith("SQM_TO_SQFT") or line.startswith("M_TO_FT"):
            exec_source += line + "\n"

    # Grab the function
    in_func = False
    func_lines = []
    for line in source.split("\n"):
        if line.startswith("def _compute_from_annotation("):
            in_func = True
        if in_func:
            func_lines.append(line)
            # Function ends at next top-level def or class or decorator
            if len(func_lines) > 1 and (line.startswith("def ") or line.startswith("@app.") or line.startswith("class ")):
                func_lines.pop()  # remove the next function's def
                break

    exec_source += "\n".join(func_lines)

    exec(exec_source, module.__dict__)
    return module


_mod = _load_compute_function()
_compute_from_annotation = _mod._compute_from_annotation
M_TO_FT = _mod.M_TO_FT
SQM_TO_SQFT = _mod.SQM_TO_SQFT


def _ply_metrics(floor_sqft=120.0, wall_sqft=480.0, ceiling_ft=8.0, perimeter_ft=50.0):
    return {
        "floor_area_sqft": floor_sqft,
        "wall_area_sqft": wall_sqft,
        "ceiling_height_ft": ceiling_ft,
        "perimeter_linear_ft": perimeter_ft,
        "detected_components": {"detected": ["floor_hardwood"]},
        "scan_dimensions": {
            "floor_area_sf": floor_sqft,
            "wall_area_sf": wall_sqft,
            "ceiling_sf": floor_sqft,
            "perimeter_lf": perimeter_ft,
            "ceiling_height_ft": ceiling_ft,
            "ceiling_height_min_ft": None,
            "ceiling_height_max_ft": None,
            "door_count": 0,
            "door_opening_lf": None,
            "transition_count": None,
            "bbox": {"x_m": 4, "y_m": 2.5, "z_m": 3},
        },
    }


# --- 4.3: Cloud uses annotated polygon for dimensions ---

def test_annotated_polygon_used_for_dimensions():
    annotation = {
        "corners_xz": [[0, 0], [4, 0], [4, 3], [0, 3]],
        "corners_y": [2.5, 2.5, 2.5, 2.5],
        "annotation_method": "ar_crosshair_snap",
        "timestamp": "2026-03-30T10:00:00Z",
    }
    result = _compute_from_annotation(annotation, _ply_metrics())
    assert result["polygon_source"] == "annotated"
    assert result["room_polygon_ft"] is not None
    assert len(result["room_polygon_ft"]) == 4


# --- 4.4: Dimensions match polygon geometry ---

def test_dimensions_match_polygon_geometry():
    annotation = {
        "corners_xz": [[0, 0], [4, 0], [4, 3], [0, 3]],
        "corners_y": [2.5, 2.5, 2.5, 2.5],
        "annotation_method": "ar_crosshair_snap",
        "timestamp": "2026-03-30T10:00:00Z",
    }
    ply = _ply_metrics()
    result = _compute_from_annotation(annotation, ply)

    expected_floor_sqft = round(12.0 * SQM_TO_SQFT, 1)
    assert result["floor_area_sqft"] == expected_floor_sqft

    expected_perimeter_ft = round(14.0 * M_TO_FT, 1)
    assert result["perimeter_linear_ft"] == expected_perimeter_ft

    ceiling_height_m = ply["ceiling_height_ft"] / M_TO_FT
    expected_wall_sqft = round(14.0 * ceiling_height_m * SQM_TO_SQFT, 1)
    assert result["wall_area_sqft"] == expected_wall_sqft


# --- 4.5: Fallback to Stage 3 when no annotation ---

def test_fallback_when_no_annotation():
    ply = _ply_metrics(floor_sqft=150.0, perimeter_ft=55.0)
    result = _compute_from_annotation(None, ply)
    assert result["polygon_source"] == "geometric"
    assert result["room_polygon_ft"] is None
    assert result["wall_heights_ft"] is None
    assert result["floor_area_sqft"] == 150.0
    assert result["perimeter_linear_ft"] == 55.0


def test_fallback_when_too_few_corners():
    annotation = {
        "corners_xz": [[0, 0], [4, 0]],
        "corners_y": [2.5, 2.5],
        "annotation_method": "ar_crosshair_snap",
        "timestamp": "2026-03-30T10:00:00Z",
    }
    result = _compute_from_annotation(annotation, _ply_metrics())
    assert result["polygon_source"] == "geometric"
    assert result["room_polygon_ft"] is None


# --- 4.6: Polygon in feet ---

def test_polygon_converted_to_feet():
    annotation = {
        "corners_xz": [[0, 0], [4, 0], [4, 3], [0, 3]],
        "corners_y": [2.5, 2.5, 2.5, 2.5],
        "annotation_method": "ar_crosshair_snap",
        "timestamp": "2026-03-30T10:00:00Z",
    }
    result = _compute_from_annotation(annotation, _ply_metrics())
    polygon = result["room_polygon_ft"]
    assert polygon[0] == [0, 0]
    assert abs(polygon[1][0] - round(4 * M_TO_FT, 2)) < 0.01


def test_wall_heights_converted_to_feet():
    annotation = {
        "corners_xz": [[0, 0], [4, 0], [4, 3], [0, 3]],
        "corners_y": [2.5, 2.5, 2.5, 2.5],
        "annotation_method": "ar_crosshair_snap",
        "timestamp": "2026-03-30T10:00:00Z",
    }
    result = _compute_from_annotation(annotation, _ply_metrics())
    expected = round(2.5 * M_TO_FT, 2)
    for h in result["wall_heights_ft"]:
        assert abs(h - expected) < 0.01


# --- 4.8: Phase 1 scans ---

def test_phase1_scans_return_null_polygon():
    result = _compute_from_annotation(None, _ply_metrics())
    assert result["room_polygon_ft"] is None
    assert result["wall_heights_ft"] is None
    assert result["polygon_source"] == "geometric"
