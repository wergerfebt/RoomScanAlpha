"""
Tests for cloud-side frame selection pipeline.

Tests sharpness filtering, mesh-based coverage selection, and edge cases
using synthetic data (no device scan needed).
"""

import json
import math
import os
import struct
import tempfile

import numpy as np
import pytest

from pipeline.frame_selection import (
    select_frames,
    _compute_sharpness,
    _filter_by_sharpness,
    _load_mesh_for_visibility,
    _build_visibility_matrix,
    _greedy_set_cover,
    _fill_with_spacing,
)


# ---------------------------------------------------------------------------
# Synthetic fixture helpers
# ---------------------------------------------------------------------------

def _create_cube_mesh(tmpdir: str) -> str:
    """Create a simple cube PLY mesh for testing visibility."""
    ply_path = os.path.join(tmpdir, "mesh.ply")

    # Unit cube centered at origin: 8 vertices, 12 triangles
    vertices = np.array([
        [-0.5, -0.5, -0.5], [0.5, -0.5, -0.5],
        [0.5, 0.5, -0.5], [-0.5, 0.5, -0.5],
        [-0.5, -0.5, 0.5], [0.5, -0.5, 0.5],
        [0.5, 0.5, 0.5], [-0.5, 0.5, 0.5],
    ], dtype=np.float32)

    faces = np.array([
        [0, 1, 2], [0, 2, 3],  # front
        [4, 6, 5], [4, 7, 6],  # back
        [0, 4, 5], [0, 5, 1],  # bottom
        [2, 6, 7], [2, 7, 3],  # top
        [0, 3, 7], [0, 7, 4],  # left
        [1, 5, 6], [1, 6, 2],  # right
    ], dtype=np.int32)

    normals = np.zeros_like(vertices)
    for v in range(len(vertices)):
        normals[v] = vertices[v] / np.linalg.norm(vertices[v])

    header = (
        "ply\n"
        "format ascii 1.0\n"
        f"element vertex {len(vertices)}\n"
        "property float x\nproperty float y\nproperty float z\n"
        "property float nx\nproperty float ny\nproperty float nz\n"
        f"element face {len(faces)}\n"
        "property list uchar int vertex_indices\n"
        "end_header\n"
    )

    with open(ply_path, "w") as f:
        f.write(header)
        for v, n in zip(vertices, normals):
            f.write(f"{v[0]} {v[1]} {v[2]} {n[0]} {n[1]} {n[2]}\n")
        for face in faces:
            f.write(f"3 {face[0]} {face[1]} {face[2]}\n")

    return ply_path


def _create_synthetic_scan(
    tmpdir: str,
    n_frames: int = 30,
    n_blurry: int = 6,
) -> tuple[str, dict]:
    """Create a synthetic scan with cameras around a cube.

    Returns (scan_root, metadata).
    Cameras are placed in a ring around the origin at distance 2m,
    looking inward. First n_blurry frames get blurry images.
    """
    scan_dir = os.path.join(tmpdir, "scan")
    keyframes_dir = os.path.join(scan_dir, "keyframes")
    os.makedirs(keyframes_dir, exist_ok=True)

    # Create cube mesh
    mesh_path = _create_cube_mesh(scan_dir)

    keyframes_list = []

    for i in range(n_frames):
        # Camera position: ring around origin at radius 2m
        angle = 2 * math.pi * i / n_frames
        cam_x = 2.0 * math.cos(angle)
        cam_z = 2.0 * math.sin(angle)
        cam_y = 0.0
        cam_pos = np.array([cam_x, cam_y, cam_z])

        # Look at origin
        forward = -cam_pos / np.linalg.norm(cam_pos)
        right = np.cross(np.array([0, 1, 0]), forward)
        right /= np.linalg.norm(right) + 1e-8
        up = np.cross(forward, right)

        # Build world-from-camera 4x4 (column-major for ARKit convention)
        T = np.eye(4, dtype=np.float64)
        T[:3, 0] = right
        T[:3, 1] = up
        T[:3, 2] = -forward  # ARKit Z points backward
        T[:3, 3] = cam_pos

        # Flatten column-major
        tx = T.flatten(order="F").tolist()

        # Write per-frame JSON
        frame_name = f"frame_{i:04d}"
        frame_json = {
            "index": i,
            "timestamp": 1000.0 + i * 0.1,
            "camera_transform": tx,
            "image_width": 320,
            "image_height": 240,
        }
        with open(os.path.join(keyframes_dir, f"{frame_name}.json"), "w") as f:
            json.dump(frame_json, f)

        # Write synthetic JPEG (sharp or blurry)
        from PIL import Image
        if i < n_blurry:
            # Blurry: uniform gray
            img = Image.new("RGB", (320, 240), color=(128, 128, 128))
        else:
            # Sharp: high-frequency checkerboard
            arr = np.zeros((240, 320, 3), dtype=np.uint8)
            for y in range(240):
                for x in range(320):
                    if (x // 4 + y // 4) % 2 == 0:
                        arr[y, x] = [200, 200, 200]
                    else:
                        arr[y, x] = [50, 50, 50]
            img = Image.fromarray(arr)
        img.save(os.path.join(keyframes_dir, f"{frame_name}.jpg"), "JPEG", quality=95)

        keyframes_list.append({"index": i, "filename": f"{frame_name}.jpg"})

    metadata = {
        "capture_format": "hevc",
        "camera_intrinsics": {"fx": 200.0, "fy": 200.0, "cx": 160.0, "cy": 120.0},
        "image_resolution": {"width": 320, "height": 240},
        "frame_count": n_frames,
        "keyframes": keyframes_list,
    }
    with open(os.path.join(scan_dir, "metadata.json"), "w") as f:
        json.dump(metadata, f)

    return scan_dir, metadata


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestSharpness:
    def test_sharp_image_scores_higher_than_blur(self, tmp_path):
        from PIL import Image

        # Sharp: checkerboard
        arr = np.zeros((240, 320, 3), dtype=np.uint8)
        for y in range(240):
            for x in range(320):
                if (x // 4 + y // 4) % 2 == 0:
                    arr[y, x] = [200, 200, 200]
                else:
                    arr[y, x] = [50, 50, 50]
        sharp = Image.fromarray(arr)
        sharp_path = str(tmp_path / "sharp.jpg")
        sharp.save(sharp_path, "JPEG", quality=95)

        # Blurry: uniform
        blur = Image.new("RGB", (320, 240), color=(128, 128, 128))
        blur_path = str(tmp_path / "blur.jpg")
        blur.save(blur_path, "JPEG", quality=95)

        sharp_score = _compute_sharpness(sharp_path)
        blur_score = _compute_sharpness(blur_path)

        assert sharp_score > blur_score * 5, (
            f"Sharp ({sharp_score:.1f}) should be much higher than blur ({blur_score:.1f})"
        )

    def test_missing_image_returns_zero(self):
        assert _compute_sharpness("/nonexistent/path.jpg") == 0.0


class TestVisibility:
    def test_camera_sees_facing_face(self, tmp_path):
        mesh_path = _create_cube_mesh(str(tmp_path))
        centroids, normals, is_floor_ceil = _load_mesh_for_visibility(mesh_path)

        # Camera at (2, 0, 0) looking toward origin (ARKit: Z points backward)
        cam_pos = np.array([2.0, 0.0, 0.0])
        forward = -cam_pos / np.linalg.norm(cam_pos)
        right = np.cross(np.array([0, 1, 0]), forward)
        right /= np.linalg.norm(right)
        up = np.cross(forward, right)

        T = np.eye(4, dtype=np.float64)
        T[:3, 0] = right
        T[:3, 1] = up
        T[:3, 2] = -forward  # ARKit Z backward
        T[:3, 3] = cam_pos
        cfw = np.linalg.inv(T)

        cameras = [{
            "position": cam_pos,
            "cam_from_world": cfw,
            "fx": 200.0, "fy": 200.0, "cx": 160.0, "cy": 120.0,
            "img_w": 320, "img_h": 240,
        }]

        vis = _build_visibility_matrix(cameras, centroids, normals, is_floor_ceil)
        assert vis[0].any(), "Camera at (2,0,0) looking at origin should see at least one face"

    def test_cameras_around_cube_cover_all_faces(self, tmp_path):
        mesh_path = _create_cube_mesh(str(tmp_path))
        centroids, normals, is_floor_ceil = _load_mesh_for_visibility(mesh_path)

        # 6 cameras, one per face direction
        cameras = []
        for pos in [[2, 0, 0], [-2, 0, 0], [0, 2, 0], [0, -2, 0], [0, 0, 2], [0, 0, -2]]:
            T = np.eye(4)
            T[:3, 3] = pos
            cameras.append({
                "position": np.array(pos, dtype=np.float64),
                "cam_from_world": np.linalg.inv(T),
                "fx": 200.0, "fy": 200.0, "cx": 160.0, "cy": 120.0,
                "img_w": 320, "img_h": 240,
            })

        vis = _build_visibility_matrix(cameras, centroids, normals, is_floor_ceil)
        covered = vis.any(axis=0)
        assert covered.sum() >= len(centroids) * 0.5, (
            f"6 cameras should cover most faces, got {covered.sum()}/{len(centroids)}"
        )


class TestGreedySetCover:
    def test_selects_diverse_cameras(self):
        # 4 cameras, each sees a different pair of faces (out of 4 total)
        vis = np.array([
            [True, True, False, False],
            [False, False, True, True],
            [True, False, False, False],  # redundant with cam 0
            [False, False, False, True],  # redundant with cam 1
        ])
        selected = _greedy_set_cover(vis, target_count=2)
        assert len(selected) == 2
        assert 0 in selected and 1 in selected, (
            "Should pick cameras 0 and 1 for full coverage"
        )

    def test_stops_when_all_covered(self):
        vis = np.array([
            [True, True, True, True],
            [True, False, False, False],
        ])
        selected = _greedy_set_cover(vis, target_count=10)
        assert len(selected) == 1, "Should stop after 1 camera covers everything"


class TestFillWithSpacing:
    def test_fills_to_target(self):
        result = _fill_with_spacing([0, 5], total_count=10, target_count=5)
        assert len(result) == 5

    def test_no_duplicates(self):
        result = _fill_with_spacing([0, 5], total_count=10, target_count=5)
        assert len(set(result)) == len(result)


class TestEndToEnd:
    @pytest.fixture
    def synthetic_scan(self, tmp_path):
        return _create_synthetic_scan(str(tmp_path), n_frames=30, n_blurry=6)

    def test_selection_reduces_frame_count(self, synthetic_scan):
        scan_root, metadata = synthetic_scan
        mesh_path = os.path.join(scan_root, "mesh.ply")
        result = select_frames(scan_root, metadata, mesh_path, target_count=15)
        assert len(result) == 15

    def test_passthrough_when_under_target(self, synthetic_scan):
        scan_root, metadata = synthetic_scan
        mesh_path = os.path.join(scan_root, "mesh.ply")
        result = select_frames(scan_root, metadata, mesh_path, target_count=50)
        assert len(result) == 30  # All frames passed through

    def test_blurry_frames_deprioritized(self, synthetic_scan):
        scan_root, metadata = synthetic_scan
        mesh_path = os.path.join(scan_root, "mesh.ply")
        result = select_frames(scan_root, metadata, mesh_path, target_count=15)

        # The first 6 frames are blurry — they should mostly be excluded
        selected_indices = {kf["index"] for kf in result}
        blurry_selected = sum(1 for i in range(6) if i in selected_indices)
        assert blurry_selected <= 3, (
            f"Expected at most 3 of 6 blurry frames, got {blurry_selected}"
        )

    def test_result_format_matches_input(self, synthetic_scan):
        scan_root, metadata = synthetic_scan
        mesh_path = os.path.join(scan_root, "mesh.ply")
        result = select_frames(scan_root, metadata, mesh_path, target_count=15)

        for kf in result:
            assert "index" in kf
            assert "filename" in kf
            assert kf["filename"].endswith(".jpg")
