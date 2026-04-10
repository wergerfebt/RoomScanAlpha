"""
Integration tests for HEVC video extraction pipeline.

Tests the full flow: HEVC video + pose sidecar + depth sidecar → individual JPEGs +
per-frame JSONs + depth files, validating that the extracted data matches the original
pose sidecar and produces the same format the legacy JPEG pipeline expects.

Uses the real scan data from a device test when available, otherwise generates synthetic
test fixtures.
"""

import json
import math
import os
import shutil
import struct
import tempfile

import numpy as np
import pytest

from pipeline.video_extract import (
    extract_frames_from_hevc,
    _load_pose_sidecar,
    _load_depth_sidecar,
)


# Path to a real scan package from device testing (if available).
REAL_SCAN_PATH = os.environ.get(
    "HEVC_TEST_SCAN",
    os.path.expanduser("~/Downloads/scan_1775530944"),
)

has_real_scan = os.path.isdir(REAL_SCAN_PATH) and os.path.exists(
    os.path.join(REAL_SCAN_PATH, "scan_video.mov")
)


# ---------------------------------------------------------------------------
# Synthetic fixture helpers
# ---------------------------------------------------------------------------

def _create_synthetic_scan(tmpdir: str, frame_count: int = 10) -> str:
    """Create a minimal synthetic HEVC scan package for testing without device data.

    Generates:
      - A tiny HEVC video (solid color frames) via PyAV
      - A JSONL pose sidecar with identity transforms and incremental positions
      - A binary depth sidecar with uniform depth values
      - A minimal mesh.ply and metadata.json
    """
    import av

    scan_dir = os.path.join(tmpdir, "synthetic_scan")
    os.makedirs(scan_dir, exist_ok=True)

    # Generate HEVC video with solid-color frames.
    video_path = os.path.join(scan_dir, "scan_video.mov")
    container = av.open(video_path, mode="w")
    stream = container.add_stream("hevc", rate=10)
    stream.width = 320
    stream.height = 240
    stream.pix_fmt = "yuv420p"

    for i in range(frame_count):
        frame = av.VideoFrame.from_ndarray(
            np.full((240, 320, 3), fill_value=(50 + i * 10) % 256, dtype=np.uint8),
            format="rgb24",
        )
        frame.pts = i
        for packet in stream.encode(frame):
            container.mux(packet)

    for packet in stream.encode():
        container.mux(packet)
    container.close()

    # Generate JSONL pose sidecar with incremental X translation.
    pose_path = os.path.join(scan_dir, "poses.jsonl")
    depth_interval = 1  # Depth every frame (matches iOS VideoFrameWriter default)
    with open(pose_path, "w") as f:
        for i in range(frame_count):
            x_pos = i * 0.15  # 15cm per frame
            # Identity rotation, incremental X translation
            tx = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x_pos, 0, 0, 1]
            has_depth = (i % depth_interval == 0)
            depth_offset = 16 + (i // depth_interval) * (64 * 48 * 4) if has_depth else -1
            entry = {
                "i": i,
                "t": 1000.0 + i * 0.1,
                "tx": tx,
                "fx": 500.0,
                "fy": 500.0,
                "cx": 160.0,
                "cy": 120.0,
                "w": 320,
                "h": 240,
                "dw": 64,
                "dh": 48,
                "do": depth_offset,
            }
            f.write(json.dumps(entry) + "\n")

    # Generate binary depth sidecar.
    depth_path = os.path.join(scan_dir, "depth.bin")
    bytes_per_frame = 64 * 48 * 4  # Float32
    depth_frame_count = (frame_count + depth_interval - 1) // depth_interval
    with open(depth_path, "wb") as f:
        # Header
        f.write(b"DPTH")
        f.write(struct.pack("<III", 1, depth_frame_count, bytes_per_frame))
        # Depth frames (uniform 2.0m depth)
        for _ in range(depth_frame_count):
            f.write(np.full(64 * 48, 2.0, dtype=np.float32).tobytes())

    # Minimal PLY (empty mesh).
    ply_path = os.path.join(scan_dir, "mesh.ply")
    with open(ply_path, "w") as f:
        f.write("ply\nformat ascii 1.0\nelement vertex 0\nelement face 0\nend_header\n")

    # Metadata.
    metadata = {
        "capture_format": "hevc",
        "device": "Test",
        "device_name": "Test",
        "ios_version": "18.0",
        "frame_count": frame_count,
        "mesh_vertex_count": 0,
        "mesh_face_count": 0,
        "camera_intrinsics": {"fx": 500, "fy": 500, "cx": 160, "cy": 120},
        "image_resolution": {"width": 320, "height": 240},
        "depth_format": {"pixel_format": "kCVPixelFormatType_DepthFloat32", "width": 64, "height": 48, "byte_order": "little_endian"},
        "video_filename": "scan_video.mov",
        "pose_sidecar_filename": "poses.jsonl",
        "depth_sidecar_filename": "depth.bin",
        "scan_duration_seconds": frame_count * 0.1,
    }
    with open(os.path.join(scan_dir, "metadata.json"), "w") as f:
        json.dump(metadata, f)

    return scan_dir


# ---------------------------------------------------------------------------
# Tests using REAL device scan data
# ---------------------------------------------------------------------------

@pytest.mark.skipif(not has_real_scan, reason="No real scan data at HEVC_TEST_SCAN")
class TestRealScanExtraction:
    """Tests using the actual scan.zip from device testing."""

    @pytest.fixture
    def scan_copy(self, tmp_path):
        """Copy the real scan to a temp dir so extraction doesn't modify the original."""
        dest = str(tmp_path / "scan")
        shutil.copytree(REAL_SCAN_PATH, dest)
        return dest

    def test_extraction_produces_keyframes_dir(self, scan_copy):
        result = extract_frames_from_hevc(scan_copy)
        assert os.path.isdir(result["keyframes_dir"])
        assert result["frame_count"] > 0

    def test_extracted_frame_count_matches_pose_sidecar(self, scan_copy):
        poses = _load_pose_sidecar(os.path.join(scan_copy, "poses.jsonl"))
        result = extract_frames_from_hevc(scan_copy)
        assert result["frame_count"] == len(poses)

    def test_extracted_jpegs_are_valid(self, scan_copy):
        extract_frames_from_hevc(scan_copy)
        keyframes_dir = os.path.join(scan_copy, "keyframes")
        jpegs = sorted(f for f in os.listdir(keyframes_dir) if f.endswith(".jpg"))
        assert len(jpegs) > 0

        # Check first, middle, and last frames have valid JPEG SOI marker.
        for idx in [0, len(jpegs) // 2, len(jpegs) - 1]:
            path = os.path.join(keyframes_dir, jpegs[idx])
            with open(path, "rb") as f:
                header = f.read(2)
            assert header == b"\xff\xd8", f"{jpegs[idx]} missing JPEG SOI marker"

    def test_extracted_jpegs_are_not_black(self, scan_copy):
        """Verify extracted frames contain real image data (not solid black)."""
        from PIL import Image
        extract_frames_from_hevc(scan_copy)
        keyframes_dir = os.path.join(scan_copy, "keyframes")
        jpegs = sorted(f for f in os.listdir(keyframes_dir) if f.endswith(".jpg"))

        # Sample 5 frames evenly across the scan.
        indices = [int(i * (len(jpegs) - 1) / 4) for i in range(5)]
        for idx in indices:
            path = os.path.join(keyframes_dir, jpegs[idx])
            img = Image.open(path)
            arr = np.array(img)
            mean_val = arr.mean()
            assert mean_val > 5, f"Frame {jpegs[idx]} appears black (mean pixel={mean_val:.1f})"
            assert arr.max() > 10, f"Frame {jpegs[idx]} has no bright pixels"

    def test_per_frame_json_has_valid_transform(self, scan_copy):
        """Each extracted per-frame JSON must have a 16-element camera_transform."""
        extract_frames_from_hevc(scan_copy)
        keyframes_dir = os.path.join(scan_copy, "keyframes")
        jsons = sorted(f for f in os.listdir(keyframes_dir) if f.endswith(".json"))
        assert len(jsons) > 0

        for jf in [jsons[0], jsons[len(jsons) // 2], jsons[-1]]:
            with open(os.path.join(keyframes_dir, jf)) as f:
                data = json.load(f)
            assert len(data["camera_transform"]) == 16, f"{jf} transform is not 16 elements"
            assert data["image_width"] > 0
            assert data["image_height"] > 0

    def test_extracted_transforms_match_pose_sidecar(self, scan_copy):
        """Camera transforms in extracted JSONs must exactly match the pose sidecar."""
        poses = _load_pose_sidecar(os.path.join(scan_copy, "poses.jsonl"))
        extract_frames_from_hevc(scan_copy)
        keyframes_dir = os.path.join(scan_copy, "keyframes")

        # Check 10 evenly spaced frames.
        total = len(poses)
        indices = [int(i * (total - 1) / 9) for i in range(10)]

        for idx in indices:
            json_path = os.path.join(keyframes_dir, f"frame_{idx:04d}.json")
            assert os.path.exists(json_path), f"Missing frame_{idx:04d}.json"

            with open(json_path) as f:
                extracted = json.load(f)

            original_tx = poses[idx]["tx"]
            extracted_tx = extracted["camera_transform"]

            for j in range(16):
                assert abs(original_tx[j] - extracted_tx[j]) < 1e-4, (
                    f"Frame {idx} transform[{j}] mismatch: "
                    f"original={original_tx[j]}, extracted={extracted_tx[j]}"
                )

    def test_extracted_positions_show_movement(self, scan_copy):
        """Camera positions across the scan should show the user walked around."""
        extract_frames_from_hevc(scan_copy)
        keyframes_dir = os.path.join(scan_copy, "keyframes")
        jsons = sorted(f for f in os.listdir(keyframes_dir) if f.endswith(".json"))

        first_path = os.path.join(keyframes_dir, jsons[0])
        last_path = os.path.join(keyframes_dir, jsons[-1])

        with open(first_path) as f:
            first = json.load(f)
        with open(last_path) as f:
            last = json.load(f)

        # Position is at indices 12, 13, 14 of the column-major 4x4 transform.
        first_pos = first["camera_transform"][12:15]
        last_pos = last["camera_transform"][12:15]
        distance = math.sqrt(sum((a - b) ** 2 for a, b in zip(first_pos, last_pos)))

        assert distance > 0.5, (
            f"Camera should have moved > 0.5m across scan, got {distance:.2f}m"
        )

    def test_depth_files_extracted(self, scan_copy):
        """Depth files should be extracted for frames that have depth data."""
        result = extract_frames_from_hevc(scan_copy)
        depth_dir = result["depth_dir"]

        if os.path.isdir(depth_dir):
            depth_files = [f for f in os.listdir(depth_dir) if f.endswith(".depth")]
            # Should have some depth files (every 5th frame).
            assert len(depth_files) > 0, "No depth files extracted"

            # Each depth file should be non-empty and correct size.
            for df in depth_files[:5]:
                path = os.path.join(depth_dir, df)
                size = os.path.getsize(path)
                assert size > 0, f"{df} is empty"
                # 256×192×4 = 196608 bytes per depth frame
                assert size == 196608, f"{df} unexpected size: {size} (expected 196608)"

    def test_depth_values_are_plausible(self, scan_copy):
        """Extracted depth values should be in a reasonable range (0.1m - 10m)."""
        extract_frames_from_hevc(scan_copy)
        depth_dir = os.path.join(scan_copy, "depth")

        if not os.path.isdir(depth_dir):
            pytest.skip("No depth directory")

        depth_files = sorted(f for f in os.listdir(depth_dir) if f.endswith(".depth"))
        if not depth_files:
            pytest.skip("No depth files")

        # Check first depth file.
        path = os.path.join(depth_dir, depth_files[0])
        with open(path, "rb") as f:
            raw = f.read()
        depth = np.frombuffer(raw, dtype=np.float32).reshape(192, 256)

        # Filter out zeros/inf and check range.
        valid = depth[(depth > 0) & (depth < 100)]
        assert len(valid) > 100, "Too few valid depth values"
        assert valid.min() > 0.05, f"Depth too close: {valid.min():.2f}m"
        assert valid.max() < 20.0, f"Depth too far: {valid.max():.2f}m"


# ---------------------------------------------------------------------------
# Tests using SYNTHETIC data (always run)
# ---------------------------------------------------------------------------

class TestSyntheticExtraction:
    """Tests using generated synthetic scan data — no device data needed."""

    @pytest.fixture
    def synthetic_scan(self, tmp_path):
        return _create_synthetic_scan(str(tmp_path), frame_count=20)

    def test_extraction_frame_count(self, synthetic_scan):
        result = extract_frames_from_hevc(synthetic_scan)
        assert result["frame_count"] == 20

    def test_extracted_jpegs_exist(self, synthetic_scan):
        extract_frames_from_hevc(synthetic_scan)
        keyframes_dir = os.path.join(synthetic_scan, "keyframes")
        jpegs = [f for f in os.listdir(keyframes_dir) if f.endswith(".jpg")]
        assert len(jpegs) == 20

    def test_per_frame_json_transform_matches_sidecar(self, synthetic_scan):
        poses = _load_pose_sidecar(os.path.join(synthetic_scan, "poses.jsonl"))
        extract_frames_from_hevc(synthetic_scan)
        keyframes_dir = os.path.join(synthetic_scan, "keyframes")

        for i in range(20):
            with open(os.path.join(keyframes_dir, f"frame_{i:04d}.json")) as f:
                extracted = json.load(f)
            original_tx = poses[i]["tx"]
            extracted_tx = extracted["camera_transform"]
            for j in range(16):
                assert abs(original_tx[j] - extracted_tx[j]) < 1e-6

    def test_positions_increment_correctly(self, synthetic_scan):
        """Synthetic scan has 0.15m X increment per frame."""
        extract_frames_from_hevc(synthetic_scan)
        keyframes_dir = os.path.join(synthetic_scan, "keyframes")

        with open(os.path.join(keyframes_dir, "frame_0000.json")) as f:
            first = json.load(f)
        with open(os.path.join(keyframes_dir, "frame_0019.json")) as f:
            last = json.load(f)

        # X position: index 12 in column-major 4x4
        assert abs(first["camera_transform"][12] - 0.0) < 1e-6
        assert abs(last["camera_transform"][12] - 19 * 0.15) < 1e-6

    def test_depth_files_extracted_every_frame(self, synthetic_scan):
        """Depth should exist for every frame (depth_interval=1)."""
        extract_frames_from_hevc(synthetic_scan)
        depth_dir = os.path.join(synthetic_scan, "depth")
        depth_files = sorted(f for f in os.listdir(depth_dir) if f.endswith(".depth"))
        assert len(depth_files) == 20  # every frame

    def test_depth_values_match_synthetic_input(self, synthetic_scan):
        """Synthetic depth is uniform 2.0m — extracted values should match."""
        extract_frames_from_hevc(synthetic_scan)
        depth_dir = os.path.join(synthetic_scan, "depth")
        path = os.path.join(depth_dir, "frame_0000.depth")
        with open(path, "rb") as f:
            raw = f.read()
        depth = np.frombuffer(raw, dtype=np.float32)
        assert np.allclose(depth, 2.0, atol=1e-5)

    def test_missing_video_raises(self, tmp_path):
        scan_dir = str(tmp_path / "empty_scan")
        os.makedirs(scan_dir, exist_ok=True)
        # Create pose sidecar but no video.
        with open(os.path.join(scan_dir, "poses.jsonl"), "w") as f:
            f.write("{}\n")
        with pytest.raises(ValueError, match="missing video file"):
            extract_frames_from_hevc(scan_dir)

    def test_missing_poses_raises(self, tmp_path):
        scan_dir = str(tmp_path / "no_poses")
        os.makedirs(scan_dir, exist_ok=True)
        # Create video but no poses.
        with open(os.path.join(scan_dir, "scan_video.mov"), "wb") as f:
            f.write(b"\x00" * 100)
        with pytest.raises(ValueError, match="missing pose sidecar"):
            extract_frames_from_hevc(scan_dir)


# ---------------------------------------------------------------------------
# Pose sidecar parsing tests
# ---------------------------------------------------------------------------

class TestPoseSidecar:
    def test_load_pose_sidecar(self, tmp_path):
        path = str(tmp_path / "poses.jsonl")
        with open(path, "w") as f:
            f.write('{"i":0,"t":100.0,"tx":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}\n')
            f.write('{"i":1,"t":100.1,"tx":[1,0,0,0,0,1,0,0,0,0,1,0,0.1,0,0,1]}\n')
        entries = _load_pose_sidecar(path)
        assert len(entries) == 2
        assert entries[0]["i"] == 0
        assert entries[1]["tx"][12] == 0.1  # X position


class TestDepthSidecar:
    def test_load_depth_sidecar_valid(self, tmp_path):
        path = str(tmp_path / "depth.bin")
        bpf = 64 * 48 * 4
        with open(path, "wb") as f:
            f.write(b"DPTH")
            f.write(struct.pack("<III", 1, 2, bpf))
            f.write(b"\x00" * bpf * 2)

        data, header = _load_depth_sidecar(path)
        assert header["version"] == 1
        assert header["frame_count"] == 2
        assert header["bytes_per_frame"] == bpf

    def test_load_depth_sidecar_invalid_magic(self, tmp_path):
        path = str(tmp_path / "bad.bin")
        with open(path, "wb") as f:
            f.write(b"XXXX" + b"\x00" * 12)
        data, header = _load_depth_sidecar(path)
        assert header is None
