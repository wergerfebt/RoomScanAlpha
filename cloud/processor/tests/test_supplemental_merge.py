"""Local prototype: supplemental scan merge — mesh merge + frame merge + re-texture.

Tests the merge logic that will power the cloud /process-supplemental endpoint.
Loads an original scan and a supplemental scan, filters supplemental mesh faces
to void regions only, merges keyframes, and optionally re-runs OpenMVS texturing.

Usage:
    cd cloud/processor/tests/local_scan
    python3 ../test_supplemental_merge.py --skip-texture

    # With explicit paths:
    python3 ../test_supplemental_merge.py \
        --original scan_1774895423 \
        --supplemental scan_1774895423 \
        --output merged_scan \
        --skip-texture
"""

import sys
import os
import json
import shutil
import struct
import argparse
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
# Also add /app for Docker container runs where pipeline is mounted there
if os.path.isdir("/app/pipeline"):
    sys.path.insert(0, "/app")

import numpy as np
import trimesh

from pipeline.stage1 import parse_and_classify


# ---------------------------------------------------------------------------
# Fibonacci sphere (adapted from main.py:966-973)
# ---------------------------------------------------------------------------

def fibonacci_sphere(n_rays: int) -> np.ndarray:
    """Generate uniformly distributed directions on a sphere."""
    golden_ratio = (1 + np.sqrt(5)) / 2
    indices = np.arange(n_rays)
    theta = np.arccos(1 - 2 * (indices + 0.5) / n_rays)
    phi = 2 * np.pi * indices / golden_ratio
    directions = np.column_stack([
        np.sin(theta) * np.cos(phi),
        np.sin(theta) * np.sin(phi),
        np.cos(theta),
    ])
    return directions


# ---------------------------------------------------------------------------
# Void region detection + face filtering
# ---------------------------------------------------------------------------

def filter_supplemental_faces(original_parsed, supplemental_parsed,
                              proximity_threshold=0.03, decimate_target=50000,
                              voxel_pitch=0.05):
    """Filter supplemental mesh faces — keep only those in void regions.

    Two-stage filter for performance:
    1. Voxel occupancy (fast): faces in empty voxels are definitely void — keep.
    2. Closest-point proximity (precise): only on faces in occupied voxels.

    Args:
        proximity_threshold: minimum distance from original surface in meters.
        decimate_target: decimate original mesh for faster closest_point queries.
        voxel_pitch: voxel grid resolution in meters for pre-filter.

    Returns:
        kept_mask: boolean array (len = supplemental face count)
    """
    t0 = time.time()

    orig_mesh = trimesh.Trimesh(
        vertices=original_parsed.positions,
        faces=original_parsed.faces,
        vertex_normals=original_parsed.normals,
        process=False,
    )

    # Compute supplemental face centroids
    supp_positions = supplemental_parsed.positions
    supp_faces = supplemental_parsed.faces
    face_verts = supp_positions[supp_faces]  # (F, 3, 3)
    centroids = face_verts.mean(axis=1)      # (F, 3)
    n_faces = len(centroids)

    # --- Stage 1: Voxel pre-filter (fast, coarse) ---
    t1 = time.time()
    vox = orig_mesh.voxelized(pitch=voxel_pitch)
    occupied = vox.is_filled(centroids)
    n_skip = int((~occupied).sum())
    n_check = int(occupied.sum())
    dt1 = time.time() - t1
    print(f"[Merge] Stage 1 (voxel {voxel_pitch*100:.0f}cm): "
          f"{n_skip} void ({100*n_skip/n_faces:.0f}%), "
          f"{n_check} need check ({100*n_check/n_faces:.0f}%) — {dt1:.2f}s")

    # Faces in empty voxels are definitely void — keep
    kept_mask = ~occupied

    # --- Stage 2: Proximity check on occupied-voxel faces only ---
    check_indices = np.where(occupied)[0]
    if len(check_indices) > 0:
        t2 = time.time()
        # Decimate for faster closest_point
        if decimate_target > 0 and len(orig_mesh.faces) > decimate_target:
            orig_mesh_dec = orig_mesh.simplify_quadric_decimation(face_count=decimate_target)
        else:
            orig_mesh_dec = orig_mesh

        _, dists, _ = trimesh.proximity.closest_point(orig_mesh_dec, centroids[check_indices])
        void_in_occupied = dists > proximity_threshold
        kept_mask[check_indices] = void_in_occupied
        dt2 = time.time() - t2

        n_kept_stage2 = int(void_in_occupied.sum())
        print(f"[Merge] Stage 2 (proximity {proximity_threshold*100:.0f}cm): "
              f"{n_check} checked, {n_kept_stage2} kept, "
              f"{n_check - n_kept_stage2} rejected — {dt2:.2f}s")

    dt = time.time() - t0
    n_kept = int(kept_mask.sum())
    n_rejected = n_faces - n_kept

    print(f"[Merge] Total: {n_faces} faces, {n_kept} kept (void), "
          f"{n_rejected} rejected (overlap) — {dt:.2f}s")

    return kept_mask


# ---------------------------------------------------------------------------
# Mesh merge
# ---------------------------------------------------------------------------

def merge_meshes(original_parsed, supplemental_parsed, kept_mask):
    """Merge original mesh with filtered supplemental faces.

    Returns:
        (positions, normals, faces, classifications) — merged arrays
    """
    orig_verts = original_parsed.positions
    orig_normals = original_parsed.normals
    orig_faces = original_parsed.faces
    orig_class = original_parsed.face_classifications

    supp_verts = supplemental_parsed.positions
    supp_normals = supplemental_parsed.normals
    supp_faces = supplemental_parsed.faces[kept_mask]
    supp_class = supplemental_parsed.face_classifications[kept_mask]

    if len(supp_faces) == 0:
        print("[Merge] No supplemental faces to add (all rejected)")
        return orig_verts, orig_normals, orig_faces, orig_class

    # Keep only vertices referenced by kept supplemental faces
    used_vert_ids = np.unique(supp_faces)
    old_to_new = np.full(len(supp_verts), -1, dtype=np.int64)
    old_to_new[used_vert_ids] = np.arange(len(used_vert_ids))

    supp_verts_compact = supp_verts[used_vert_ids]
    supp_normals_compact = supp_normals[used_vert_ids]
    supp_faces_remapped = old_to_new[supp_faces]

    # Offset remapped face indices by original vertex count
    vertex_offset = len(orig_verts)
    supp_faces_offset = supp_faces_remapped + vertex_offset

    merged_verts = np.vstack([orig_verts, supp_verts_compact])
    merged_normals = np.vstack([orig_normals, supp_normals_compact])
    merged_faces = np.vstack([orig_faces, supp_faces_offset])
    merged_class = np.concatenate([orig_class, supp_class])

    print(f"[Merge] Merged mesh: {len(merged_verts)} vertices, {len(merged_faces)} faces")
    print(f"[Merge]   Original: {len(orig_verts)} verts, {len(orig_faces)} faces")
    print(f"[Merge]   Added:    {len(supp_verts_compact)} verts (compacted from {len(supp_verts)}), "
          f"{len(supp_faces)} faces")

    return merged_verts, merged_normals, merged_faces, merged_class


# ---------------------------------------------------------------------------
# Binary PLY export (matches stage1.py format exactly)
# ---------------------------------------------------------------------------

def export_binary_ply(positions, normals, faces, classifications, output_path):
    """Write binary PLY in the exact ARKit format stage1.py expects.

    Format: generate_fixture.py:160-189
      - 24 bytes/vertex: 6 × float32 (x, y, z, nx, ny, nz)
      - 14 bytes/face: 1B count + 3×uint32 indices + 1B classification
    """
    vertex_count = len(positions)
    face_count = len(faces)

    header = (
        "ply\n"
        "format binary_little_endian 1.0\n"
        f"element vertex {vertex_count}\n"
        "property float x\n"
        "property float y\n"
        "property float z\n"
        "property float nx\n"
        "property float ny\n"
        "property float nz\n"
        f"element face {face_count}\n"
        "property list uchar uint vertex_indices\n"
        "property uchar classification\n"
        "end_header\n"
    )

    with open(output_path, "wb") as f:
        f.write(header.encode("ascii"))

        # Vertex data: interleave positions and normals
        vertex_data = np.empty((vertex_count, 6), dtype=np.float32)
        vertex_data[:, :3] = positions.astype(np.float32)
        vertex_data[:, 3:] = normals.astype(np.float32)
        f.write(vertex_data.tobytes())

        # Face data: 1B count + 3×uint32 + 1B classification
        for i in range(face_count):
            f.write(struct.pack("<B", 3))
            f.write(struct.pack("<III", int(faces[i][0]), int(faces[i][1]), int(faces[i][2])))
            f.write(struct.pack("<B", int(classifications[i])))

    file_size = os.path.getsize(output_path)
    print(f"[Export] Wrote {output_path} ({vertex_count} verts, {face_count} faces, "
          f"{file_size / 1024 / 1024:.1f} MB)")

    # Verify round-trip
    verify = parse_and_classify(output_path)
    assert verify.vertex_count == vertex_count, \
        f"PLY round-trip failed: expected {vertex_count} verts, got {verify.vertex_count}"
    assert verify.face_count == face_count, \
        f"PLY round-trip failed: expected {face_count} faces, got {verify.face_count}"
    print(f"[Export] Round-trip verification passed")


# ---------------------------------------------------------------------------
# Frame merge
# ---------------------------------------------------------------------------

def merge_frames(original_root, supplemental_root, output_root, merged_ply_path):
    """Merge keyframes from original and supplemental scans.

    Copies original keyframes as-is, then copies supplemental keyframes
    with renumbered indices to avoid collisions.

    Returns:
        Merged metadata dict (ready for texture_scan).
    """
    # Load metadata from both scans
    with open(os.path.join(original_root, "metadata.json")) as f:
        orig_meta = json.load(f)
    with open(os.path.join(supplemental_root, "metadata.json")) as f:
        supp_meta = json.load(f)

    # Find max frame index in original
    max_orig_index = 0
    for kf in orig_meta["keyframes"]:
        max_orig_index = max(max_orig_index, kf["index"])
    offset = max_orig_index + 1

    print(f"[Frames] Original: {len(orig_meta['keyframes'])} frames "
          f"(max index {max_orig_index})")
    print(f"[Frames] Supplemental: {len(supp_meta['keyframes'])} frames "
          f"(will be renumbered starting at {offset})")

    # Prepare output directory
    os.makedirs(output_root, exist_ok=True)
    out_keyframes = os.path.join(output_root, "keyframes")
    out_depth = os.path.join(output_root, "depth")
    os.makedirs(out_keyframes, exist_ok=True)

    orig_keyframes = os.path.join(original_root, "keyframes")
    orig_depth = os.path.join(original_root, "depth")
    supp_keyframes = os.path.join(supplemental_root, "keyframes")
    supp_depth = os.path.join(supplemental_root, "depth")

    # Copy original keyframes
    merged_keyframes_list = []
    for kf in orig_meta["keyframes"]:
        fname = kf["filename"]
        json_fname = fname.replace(".jpg", ".json")

        src_jpg = os.path.join(orig_keyframes, fname)
        src_json = os.path.join(orig_keyframes, json_fname)
        if os.path.exists(src_jpg):
            shutil.copy2(src_jpg, os.path.join(out_keyframes, fname))
        if os.path.exists(src_json):
            shutil.copy2(src_json, os.path.join(out_keyframes, json_fname))

        # Copy depth if present
        if kf.get("depth_filename") and os.path.isdir(orig_depth):
            src_dep = os.path.join(orig_depth, kf["depth_filename"])
            if os.path.exists(src_dep):
                os.makedirs(out_depth, exist_ok=True)
                shutil.copy2(src_dep, os.path.join(out_depth, kf["depth_filename"]))

        merged_keyframes_list.append(dict(kf))

    # Copy supplemental keyframes with renumbering
    for kf in supp_meta["keyframes"]:
        new_index = kf["index"] + offset
        new_fname = f"frame_{new_index:03d}.jpg"
        new_json_fname = f"frame_{new_index:03d}.json"
        new_depth_fname = f"frame_{new_index:03d}.depth"

        # Copy and rename JPEG
        src_jpg = os.path.join(supp_keyframes, kf["filename"])
        if os.path.exists(src_jpg):
            shutil.copy2(src_jpg, os.path.join(out_keyframes, new_fname))

        # Copy and rename per-frame JSON
        src_json = os.path.join(supp_keyframes, kf["filename"].replace(".jpg", ".json"))
        if os.path.exists(src_json):
            # Update index inside the JSON
            with open(src_json) as f:
                frame_meta = json.load(f)
            frame_meta["index"] = new_index
            with open(os.path.join(out_keyframes, new_json_fname), "w") as f:
                json.dump(frame_meta, f)

        # Copy depth if present
        if kf.get("depth_filename") and os.path.isdir(supp_depth):
            src_dep = os.path.join(supp_depth, kf["depth_filename"])
            if os.path.exists(src_dep):
                os.makedirs(out_depth, exist_ok=True)
                shutil.copy2(src_dep, os.path.join(out_depth, new_depth_fname))

        merged_kf = {
            "filename": new_fname,
            "index": new_index,
            "timestamp": kf.get("timestamp", 0),
        }
        if kf.get("depth_filename"):
            merged_kf["depth_filename"] = new_depth_fname
        merged_keyframes_list.append(merged_kf)

    # Copy merged PLY (skip if already in output_root)
    dest_ply = os.path.join(output_root, "mesh.ply")
    if os.path.abspath(merged_ply_path) != os.path.abspath(dest_ply):
        shutil.copy2(merged_ply_path, dest_ply)

    # Build merged metadata
    merged_meta = dict(orig_meta)
    merged_meta["keyframes"] = merged_keyframes_list
    merged_meta["keyframe_count"] = len(merged_keyframes_list)
    merged_meta["supplemental_frame_offset"] = offset

    with open(os.path.join(output_root, "metadata.json"), "w") as f:
        json.dump(merged_meta, f, indent=2)

    print(f"[Frames] Merged: {len(merged_keyframes_list)} total frames")
    print(f"[Frames] Output: {output_root}")

    return merged_meta


# ---------------------------------------------------------------------------
# Coverage comparison
# ---------------------------------------------------------------------------

def compare_coverage(original_parsed, merged_verts, merged_faces, n_rays=5000,
                     decimate_target=20000):
    """Compare geometric coverage (ray hits) before and after merge."""
    directions = fibonacci_sphere(n_rays)

    def ray_coverage(positions, faces):
        mesh = trimesh.Trimesh(vertices=positions, faces=faces, process=False)
        if len(mesh.faces) > decimate_target:
            mesh = mesh.simplify_quadric_decimation(face_count=decimate_target)
        center = positions.mean(axis=0)
        origins = np.tile(center, (n_rays, 1))
        _, ray_ids, _ = mesh.ray.intersects_location(origins, directions, multiple_hits=False)
        return len(set(ray_ids))

    orig_hits = ray_coverage(original_parsed.positions, original_parsed.faces)
    merged_hits = ray_coverage(merged_verts, merged_faces)

    orig_pct = 100 * orig_hits / n_rays
    merged_pct = 100 * merged_hits / n_rays
    delta = merged_pct - orig_pct

    print(f"\n[Coverage] Original: {orig_hits}/{n_rays} rays hit ({orig_pct:.1f}%)")
    print(f"[Coverage] Merged:   {merged_hits}/{n_rays} rays hit ({merged_pct:.1f}%)")
    print(f"[Coverage] Delta:    {delta:+.1f}%")

    return {"original_pct": orig_pct, "merged_pct": merged_pct, "delta": delta}


# ---------------------------------------------------------------------------
# Texturing (optional)
# ---------------------------------------------------------------------------

def run_texturing(merged_root, metadata):
    """Run OpenMVS texture_scan on the merged data."""
    if not shutil.which("InterfaceCOLMAP"):
        print("\n[Texture] SKIPPED — InterfaceCOLMAP not found in PATH")
        print("[Texture] To run texturing, use the Docker container or install OpenMVS binaries")
        return None

    from pipeline.openmvs_texture import texture_scan

    print("\n[Texture] Running texture_scan on merged data...")
    t0 = time.time()
    result = texture_scan(merged_root, metadata)
    dt = time.time() - t0
    print(f"[Texture] Completed in {dt:.1f}s")
    for k, v in result.items():
        print(f"[Texture]   {k}: {v}")
    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Supplemental scan merge prototype",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--original", default="scan_1774895423",
                        help="Path to original scan directory (default: scan_1774895423)")
    parser.add_argument("--supplemental", default=None,
                        help="Path to supplemental scan directory (default: same as original)")
    parser.add_argument("--output", default="merged_scan",
                        help="Output directory for merged scan (default: merged_scan)")
    parser.add_argument("--skip-texture", action="store_true",
                        help="Skip OpenMVS texturing step")
    parser.add_argument("--proximity-threshold", type=float, default=0.03,
                        help="Min distance from original surface in meters (default: 0.03)")
    args = parser.parse_args()

    if args.supplemental is None:
        args.supplemental = args.original
        print("[Info] No --supplemental specified — using same scan (self-merge smoke test)")

    # Validate paths
    for name, path in [("original", args.original), ("supplemental", args.supplemental)]:
        if not os.path.isdir(path):
            print(f"ERROR: {name} scan directory not found: {path}")
            print(f"  Run from cloud/processor/tests/local_scan/ or provide absolute path")
            sys.exit(1)
        if not os.path.exists(os.path.join(path, "mesh.ply")):
            print(f"ERROR: mesh.ply not found in {path}")
            sys.exit(1)
        if not os.path.exists(os.path.join(path, "metadata.json")):
            print(f"ERROR: metadata.json not found in {path}")
            sys.exit(1)

    orig_ply = os.path.join(args.original, "mesh.ply")
    supp_ply = os.path.join(args.supplemental, "mesh.ply")

    print("=" * 60)
    print("Supplemental Scan Merge Prototype")
    print("=" * 60)
    print(f"  Original:     {os.path.abspath(args.original)}")
    print(f"  Supplemental: {os.path.abspath(args.supplemental)}")
    print(f"  Output:       {os.path.abspath(args.output)}")
    print(f"  Proximity:    {args.proximity_threshold}m threshold")
    print(f"  Texture:      {'skip' if args.skip_texture else 'enabled'}")
    print()

    # Step 1: Parse both PLY files
    print("--- Step 1: Parse PLY meshes ---")
    t0 = time.time()
    orig_parsed = parse_and_classify(orig_ply)
    supp_parsed = parse_and_classify(supp_ply)
    print(f"  Original:     {orig_parsed.vertex_count} verts, {orig_parsed.face_count} faces")
    print(f"  Supplemental: {supp_parsed.vertex_count} verts, {supp_parsed.face_count} faces")
    print(f"  Parsed in {time.time() - t0:.2f}s")

    # Bounding box overlap check
    orig_min = np.array([orig_parsed.bbox["min_x"], orig_parsed.bbox["min_y"], orig_parsed.bbox["min_z"]])
    orig_max = np.array([orig_parsed.bbox["max_x"], orig_parsed.bbox["max_y"], orig_parsed.bbox["max_z"]])
    supp_min = np.array([supp_parsed.bbox["min_x"], supp_parsed.bbox["min_y"], supp_parsed.bbox["min_z"]])
    supp_max = np.array([supp_parsed.bbox["max_x"], supp_parsed.bbox["max_y"], supp_parsed.bbox["max_z"]])

    overlap_min = np.maximum(orig_min, supp_min)
    overlap_max = np.minimum(orig_max, supp_max)
    if np.all(overlap_max > overlap_min):
        overlap_vol = np.prod(overlap_max - overlap_min)
        orig_vol = np.prod(orig_max - orig_min)
        print(f"  BBox overlap: {100 * overlap_vol / orig_vol:.0f}% of original volume")
    else:
        print("  WARNING: No bounding box overlap — scans may be in different coordinate systems!")
    print()

    # Step 2: Filter supplemental faces
    print("--- Step 2: Filter supplemental faces to void regions ---")
    kept_mask = filter_supplemental_faces(
        orig_parsed, supp_parsed,
        proximity_threshold=args.proximity_threshold,
    )
    print()

    # Step 3: Merge meshes
    print("--- Step 3: Merge meshes ---")
    merged_verts, merged_normals, merged_faces, merged_class = merge_meshes(
        orig_parsed, supp_parsed, kept_mask
    )
    print()

    # Step 4: Export merged PLY
    print("--- Step 4: Export merged PLY ---")
    os.makedirs(args.output, exist_ok=True)
    merged_ply = os.path.join(args.output, "mesh.ply")
    export_binary_ply(merged_verts, merged_normals, merged_faces, merged_class, merged_ply)
    print()

    # Step 5: Merge frames
    print("--- Step 5: Merge keyframes ---")
    merged_meta = merge_frames(args.original, args.supplemental, args.output, merged_ply)
    print()

    # Step 6: Coverage comparison
    print("--- Step 6: Coverage comparison ---")
    compare_coverage(orig_parsed, merged_verts, merged_faces)
    print()

    # Step 7: Texture (optional)
    if not args.skip_texture:
        print("--- Step 7: Texturing ---")
        run_texturing(args.output, merged_meta)
    else:
        print("--- Step 7: Texturing (skipped) ---")

    print()
    print("=" * 60)
    print(f"Done. Merged scan at: {os.path.abspath(args.output)}")
    print("=" * 60)


if __name__ == "__main__":
    main()
