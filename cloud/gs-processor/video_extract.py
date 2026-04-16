"""
Extract individual JPEG frames and per-frame metadata from an HEVC video + sidecar files.

Converts the HEVC capture format (video + JSONL pose sidecar + binary depth sidecar) into
the discrete-frame format that the rest of the pipeline expects: individual JPEGs,
per-frame JSON metadata, and depth files.

This module bridges the iOS HEVC capture format to the existing cloud pipeline format.
"""

import json
import os
import struct
from typing import Optional

import av
import numpy as np


# Depth sidecar header: "DPTH" (4 bytes) + version uint32 + frame_count uint32 + bytes_per_frame uint32
DEPTH_HEADER_SIZE = 16
DEPTH_MAGIC = b"DPTH"


def extract_frames_from_hevc(
    scan_root: str,
    video_filename: str = "scan_video.mov",
    pose_filename: str = "poses.jsonl",
    depth_filename: str = "depth.bin",
    jpeg_quality: int = 95,
) -> dict:
    """Extract individual frames from HEVC video into keyframes/ and depth/ directories.

    Creates the same directory structure as the legacy JPEG capture format:
      keyframes/frame_000.jpg, frame_000.json, ...
      depth/frame_000.depth, ...

    Args:
        scan_root: Path to the extracted scan package directory.
        video_filename: Name of the HEVC video file in scan_root.
        pose_filename: Name of the JSONL pose sidecar file.
        depth_filename: Name of the binary depth sidecar file.
        jpeg_quality: JPEG compression quality for extracted frames (1-100).

    Returns:
        Dict with extraction stats: frame_count, keyframes_dir, depth_dir.

    Raises:
        ValueError: If required files are missing or malformed.
    """
    video_path = os.path.join(scan_root, video_filename)
    pose_path = os.path.join(scan_root, pose_filename)
    depth_path = os.path.join(scan_root, depth_filename)

    if not os.path.exists(video_path):
        raise ValueError(f"missing video file: {video_filename}")
    if not os.path.exists(pose_path):
        raise ValueError(f"missing pose sidecar: {pose_filename}")

    # Create output directories.
    keyframes_dir = os.path.join(scan_root, "keyframes")
    depth_dir = os.path.join(scan_root, "depth")
    os.makedirs(keyframes_dir, exist_ok=True)
    os.makedirs(depth_dir, exist_ok=True)

    # Load pose entries from JSONL sidecar.
    pose_entries = _load_pose_sidecar(pose_path)
    print(f"[VideoExtract] Loaded {len(pose_entries)} pose entries from {pose_filename}")

    # Load depth sidecar if present.
    depth_data, depth_header = _load_depth_sidecar(depth_path) if os.path.exists(depth_path) else (None, None)
    if depth_header:
        print(f"[VideoExtract] Depth sidecar: {depth_header['frame_count']} frames, {depth_header['bytes_per_frame']} bytes/frame")

    # Extract video frames using PyAV.
    frame_count = _extract_video_frames(
        video_path=video_path,
        pose_entries=pose_entries,
        keyframes_dir=keyframes_dir,
        depth_dir=depth_dir,
        depth_data=depth_data,
        depth_header=depth_header,
        jpeg_quality=jpeg_quality,
    )

    print(f"[VideoExtract] Extracted {frame_count} frames from HEVC video")

    return {
        "frame_count": frame_count,
        "keyframes_dir": keyframes_dir,
        "depth_dir": depth_dir,
    }


def _load_pose_sidecar(pose_path: str) -> list[dict]:
    """Load JSONL pose sidecar into a list of dicts, one per frame."""
    entries = []
    with open(pose_path, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))
    return entries


def _load_depth_sidecar(depth_path: str) -> tuple[Optional[bytes], Optional[dict]]:
    """Load binary depth sidecar. Returns (raw_bytes, header_dict) or (None, None)."""
    with open(depth_path, "rb") as f:
        header_bytes = f.read(DEPTH_HEADER_SIZE)

    if len(header_bytes) < DEPTH_HEADER_SIZE:
        return None, None

    magic = header_bytes[:4]
    if magic != DEPTH_MAGIC:
        print(f"[VideoExtract] Warning: depth sidecar has invalid magic: {magic}")
        return None, None

    version, frame_count, bytes_per_frame = struct.unpack("<III", header_bytes[4:16])

    with open(depth_path, "rb") as f:
        all_data = f.read()

    header = {
        "version": version,
        "frame_count": frame_count,
        "bytes_per_frame": bytes_per_frame,
    }

    return all_data, header


def _extract_video_frames(
    video_path: str,
    pose_entries: list[dict],
    keyframes_dir: str,
    depth_dir: str,
    depth_data: Optional[bytes],
    depth_header: Optional[dict],
    jpeg_quality: int,
) -> int:
    """Decode HEVC video and write individual JPEG + JSON + depth files."""
    container = av.open(video_path)
    stream = container.streams.video[0]

    # Build a mapping from video frame index to pose entry.
    # The video has one frame per pose entry, in order.
    frame_index = 0
    extracted = 0

    for frame in container.decode(stream):
        if frame_index >= len(pose_entries):
            break

        pose = pose_entries[frame_index]
        frame_name = f"frame_{frame_index:04d}"

        # Write JPEG.
        img = frame.to_image()  # PIL Image
        jpeg_path = os.path.join(keyframes_dir, f"{frame_name}.jpg")
        img.save(jpeg_path, "JPEG", quality=jpeg_quality)

        # Write per-frame JSON (compatible with legacy FrameMetadata format).
        frame_json = {
            "index": pose.get("i", frame_index),
            "timestamp": pose.get("t", 0),
            "camera_transform": pose.get("tx", []),
            "image_width": pose.get("w", 0),
            "image_height": pose.get("h", 0),
            "depth_width": pose.get("dw", 0),
            "depth_height": pose.get("dh", 0),
        }
        json_path = os.path.join(keyframes_dir, f"{frame_name}.json")
        with open(json_path, "w") as f:
            json.dump(frame_json, f)

        # Write depth file if this frame has depth data (do >= 0).
        depth_offset = pose.get("do", -1)
        if depth_data and depth_header and depth_header["bytes_per_frame"] > 0 and depth_offset >= 0:
            bpf = depth_header["bytes_per_frame"]
            if depth_offset + bpf <= len(depth_data):
                depth_bytes = depth_data[depth_offset:depth_offset + bpf]
                depth_path = os.path.join(depth_dir, f"{frame_name}.depth")
                with open(depth_path, "wb") as f:
                    f.write(depth_bytes)

        extracted += 1
        frame_index += 1

    container.close()
    return extracted
