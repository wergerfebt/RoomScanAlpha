"""Tests for Step 7A: texture projection pipeline.

Tests surface construction from annotations, keyframe scoring,
multi-keyframe blending, and coverage thresholds.
"""

import sys
import os
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from pipeline.texture_projection import (
    Surface,
    Keyframe,
    build_surfaces_from_annotation,
    project_textures,
    _score_keyframes,
    _bilinear_sample,
)


# --- Helpers ---

def _make_keyframe(
    index: int = 0,
    position: tuple = (0, 1.5, -3),
    look_at: tuple = (0, 1.5, 0),
    image_val: int = 128,
    image_size: tuple = (100, 80),  # (w, h)
) -> Keyframe:
    """Create a synthetic keyframe at a given position looking at a target."""
    pos = np.array(position, dtype=np.float64)
    target = np.array(look_at, dtype=np.float64)

    # Build a camera transform (world-from-camera)
    forward = target - pos
    forward = forward / np.linalg.norm(forward)
    # In ARKit, camera looks along -Z. So -Z = forward → Z = -forward
    z_axis = -forward
    # Up is Y
    up = np.array([0, 1, 0], dtype=np.float64)
    x_axis = np.cross(up, z_axis)
    x_norm = np.linalg.norm(x_axis)
    if x_norm < 1e-6:
        x_axis = np.array([1, 0, 0], dtype=np.float64)
    else:
        x_axis = x_axis / x_norm
    y_axis = np.cross(z_axis, x_axis)

    transform = np.eye(4, dtype=np.float64)
    transform[:3, 0] = x_axis
    transform[:3, 1] = y_axis
    transform[:3, 2] = z_axis
    transform[:3, 3] = pos

    w, h = image_size
    image = np.full((h, w, 3), image_val, dtype=np.uint8)

    return Keyframe(
        index=index,
        image=image,
        depth_map=None,
        camera_transform=transform,
        fx=80.0, fy=80.0, cx=w / 2, cy=h / 2,
        image_width=w,
        image_height=h,
        depth_width=0,
        depth_height=0,
    )


# --- Surface Construction Tests ---

def test_build_surfaces_from_rectangle():
    """A 4-corner rectangle should produce 4 walls + floor + ceiling = 6 surfaces."""
    corners_xz = [[0, 0], [4, 0], [4, 3], [0, 3]]
    corners_y = [2.5, 2.5, 2.5, 2.5]
    surfaces = build_surfaces_from_annotation(corners_xz, corners_y)

    wall_surfaces = [s for s in surfaces if s.surface_type == "wall"]
    floor_surfaces = [s for s in surfaces if s.surface_type == "floor"]
    ceiling_surfaces = [s for s in surfaces if s.surface_type == "ceiling"]

    assert len(wall_surfaces) == 4
    assert len(floor_surfaces) == 1
    assert len(ceiling_surfaces) == 1


def test_wall_dimensions_match_polygon():
    """Wall widths should match edge lengths of the polygon."""
    corners_xz = [[0, 0], [4, 0], [4, 3], [0, 3]]
    corners_y = [2.5, 2.5, 2.5, 2.5]
    surfaces = build_surfaces_from_annotation(corners_xz, corners_y)

    walls = sorted(
        [s for s in surfaces if s.surface_type == "wall"],
        key=lambda s: s.surface_id,
    )
    # wall_0: (0,0)→(4,0) = 4m wide
    assert abs(walls[0].width_m - 4.0) < 0.01
    # wall_1: (4,0)→(4,3) = 3m wide
    assert abs(walls[1].width_m - 3.0) < 0.01
    # wall_2: (4,3)→(0,3) = 4m wide
    assert abs(walls[2].width_m - 4.0) < 0.01
    # wall_3: (0,3)→(0,0) = 3m wide
    assert abs(walls[3].width_m - 3.0) < 0.01


def test_wall_height_matches_annotation():
    """Wall height should match corner Y values."""
    corners_xz = [[0, 0], [4, 0], [4, 3], [0, 3]]
    corners_y = [2.5, 2.5, 2.5, 2.5]
    surfaces = build_surfaces_from_annotation(corners_xz, corners_y)

    for s in surfaces:
        if s.surface_type == "wall":
            assert abs(s.height_m - 2.5) < 0.01


def test_floor_dimensions_match_bounding_box():
    """Floor surface should span the polygon's bounding box."""
    corners_xz = [[0, 0], [4, 0], [4, 3], [0, 3]]
    corners_y = [2.5, 2.5, 2.5, 2.5]
    surfaces = build_surfaces_from_annotation(corners_xz, corners_y)

    floor = [s for s in surfaces if s.surface_type == "floor"][0]
    assert abs(floor.width_m - 4.0) < 0.01
    assert abs(floor.height_m - 3.0) < 0.01


def test_too_few_corners_returns_empty():
    """< 3 corners should return no surfaces."""
    surfaces = build_surfaces_from_annotation([[0, 0], [1, 0]], [2.5, 2.5])
    assert len(surfaces) == 0


def test_wall_normals_point_inward():
    """For CCW polygon, wall normals should point into the room."""
    corners_xz = [[0, 0], [4, 0], [4, 3], [0, 3]]
    corners_y = [2.5, 2.5, 2.5, 2.5]
    surfaces = build_surfaces_from_annotation(corners_xz, corners_y)

    # Room center is at (2, ?, 1.5)
    center_xz = np.array([2.0, 0, 1.5])
    for s in surfaces:
        if s.surface_type == "wall":
            wall_center = s.origin + s.u_axis * s.width_m / 2 + s.v_axis * s.height_m / 2
            to_center = center_xz - wall_center
            to_center[1] = 0  # ignore Y
            dot = np.dot(s.normal, to_center)
            assert dot > 0, f"{s.surface_id} normal should point toward room center"


# --- Keyframe Scoring Tests ---

def test_perpendicular_keyframe_scores_higher():
    """A keyframe looking straight at a wall should score higher than one at an angle."""
    corners_xz = [[0, 0], [4, 0], [4, 3], [0, 3]]
    corners_y = [2.5, 2.5, 2.5, 2.5]
    surfaces = build_surfaces_from_annotation(corners_xz, corners_y)

    # wall_0 faces inward (toward +Z). Put one camera straight-on and one at an angle.
    wall_0 = [s for s in surfaces if s.surface_id == "wall_0"][0]

    kf_straight = _make_keyframe(index=0, position=(2, 1.5, -2), look_at=(2, 1.5, 0))
    kf_oblique = _make_keyframe(index=1, position=(6, 1.5, -1), look_at=(2, 1.5, 0))

    scored = _score_keyframes(wall_0, [kf_straight, kf_oblique])
    assert len(scored) >= 1
    # The straight-on keyframe should be first (highest score)
    assert scored[0][1].index == 0


# --- Projection & Blending Tests ---

def test_single_keyframe_projects_color():
    """A keyframe with uniform color should produce a texture with that color."""
    corners_xz = [[0, 0], [4, 0], [4, 3], [0, 3]]
    corners_y = [2.5, 2.5, 2.5, 2.5]
    surfaces = build_surfaces_from_annotation(corners_xz, corners_y)

    # Camera at center of room, looking at wall_0 (the wall along Z=0)
    kf = _make_keyframe(index=0, position=(2, 1.25, 1.5), look_at=(2, 1.25, 0), image_val=200)

    wall_0 = [s for s in surfaces if s.surface_id == "wall_0"][0]
    results = project_textures([kf], [wall_0])

    assert len(results) == 1
    r = results[0]
    assert r.surface_id == "wall_0"
    # Should have some coverage (camera is looking at this wall)
    assert r.coverage > 0.0
    # Non-black pixels should be close to 200
    nonzero = r.image[r.image.sum(axis=2) > 0]
    if len(nonzero) > 0:
        avg_val = nonzero.mean()
        assert avg_val > 100, f"Expected bright pixels, got avg {avg_val}"


def test_multi_keyframe_blending_increases_coverage():
    """Two keyframes covering different parts should give more coverage than one alone."""
    corners_xz = [[0, 0], [4, 0], [4, 3], [0, 3]]
    corners_y = [2.5, 2.5, 2.5, 2.5]
    surfaces = build_surfaces_from_annotation(corners_xz, corners_y)
    wall_0 = [s for s in surfaces if s.surface_id == "wall_0"][0]

    # Two cameras at different positions along the wall
    kf_left = _make_keyframe(index=0, position=(1, 1.25, 1.5), look_at=(1, 1.25, 0), image_val=150)
    kf_right = _make_keyframe(index=1, position=(3, 1.25, 1.5), look_at=(3, 1.25, 0), image_val=180)

    result_single = project_textures([kf_left], [wall_0])
    result_both = project_textures([kf_left, kf_right], [wall_0])

    assert result_both[0].coverage >= result_single[0].coverage


# --- Bilinear Sampling Test ---

def test_bilinear_sample_center():
    """Sampling at integer coordinates should return exact pixel values."""
    img = np.zeros((10, 10, 3), dtype=np.uint8)
    img[5, 5] = [100, 150, 200]

    px = np.array([5.0])
    py = np.array([5.0])
    result = _bilinear_sample(img, px, py)

    assert abs(result[0, 0] - 100) < 1
    assert abs(result[0, 1] - 150) < 1
    assert abs(result[0, 2] - 200) < 1
