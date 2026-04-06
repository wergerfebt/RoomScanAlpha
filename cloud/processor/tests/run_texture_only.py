"""Run texture_scan() on an already-merged scan directory.

Designed for Docker execution where OpenMVS binaries are available.
Optionally pre-decimates the mesh to avoid TextureMesh issues with
very large or non-manifold merged meshes.

Usage (Docker):
    docker run --rm \
      -v $(pwd)/tests:/tests \
      -v $(pwd)/pipeline:/app/pipeline \
      -w /tests/local_scan \
      scan-processor:openmvs \
      python3 -u /tests/run_texture_only.py <scan_dir> [--decimate N]
"""

import sys
import os
import json
import time
import argparse

# Add /app for Docker, parent dir for local
if os.path.isdir("/app/pipeline"):
    sys.path.insert(0, "/app")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import trimesh
from pipeline.openmvs_texture import texture_scan


def main():
    parser = argparse.ArgumentParser(description="Run texture_scan on a scan directory")
    parser.add_argument("scan_dir", help="Scan directory with mesh.ply + metadata.json + keyframes/")
    parser.add_argument("--decimate", type=int, default=0,
                        help="Pre-decimate mesh to N faces before texturing (0 = no pre-decimation)")
    parser.add_argument("--preview-faces", type=int, default=0,
                        help="Override preview decimation target (0 = default 10K)")
    args = parser.parse_args()

    scan_root = os.path.abspath(args.scan_dir)
    if not os.path.isdir(scan_root):
        print(f"ERROR: directory not found: {scan_root}")
        sys.exit(1)

    meta_path = os.path.join(scan_root, "metadata.json")
    with open(meta_path) as f:
        metadata = json.load(f)

    # Pre-decimate if requested (helps with merged meshes that are too large)
    if args.decimate > 0:
        ply_path = os.path.join(scan_root, "mesh.ply")
        mesh = trimesh.load(ply_path, process=False)
        if len(mesh.faces) > args.decimate:
            print(f"[Pre-decimate] {len(mesh.faces)} → {args.decimate} faces")
            mesh = mesh.simplify_quadric_decimation(face_count=args.decimate)
            mesh.export(ply_path)
            print(f"[Pre-decimate] Exported: {len(mesh.faces)} faces")
        else:
            print(f"[Pre-decimate] Mesh already ≤{args.decimate} faces, skipping")

    print(f"[Texture] Scan root: {scan_root}")
    print(f"[Texture] Keyframes: {metadata['keyframe_count']}")
    print(f"[Texture] Running texture_scan()...")

    t0 = time.time()
    result = texture_scan(scan_root, metadata, preview_faces=args.preview_faces)
    dt = time.time() - t0

    print(f"\n[Texture] Completed in {dt:.1f}s")
    for k, v in result.items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
