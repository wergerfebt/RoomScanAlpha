"""Split an existing scan into two halves for testing supplemental merge.

Takes scan_1774895423 (60 frames) and creates:
  - scan_half_a/ — first 30 frames + full mesh (simulates original scan)
  - scan_half_b/ — last 30 frames + full mesh (simulates supplemental scan)

Both halves share the same coordinate system (same AR session) and the same
mesh, so this tests frame merge + re-texturing but not mesh hole-filling.

Usage:
    cd cloud/processor/tests/local_scan
    python3 ../split_scan.py
    python3 ../test_supplemental_merge.py \
        --original scan_half_a \
        --supplemental scan_half_b \
        --output merged_halves \
        --skip-texture
"""

import os
import sys
import json
import shutil


def main():
    scan_root = os.path.join(os.path.dirname(__file__), "local_scan", "scan_1774895423")
    base_dir = os.path.join(os.path.dirname(__file__), "local_scan")

    if not os.path.isdir(scan_root):
        print(f"ERROR: scan not found at {scan_root}")
        sys.exit(1)

    with open(os.path.join(scan_root, "metadata.json")) as f:
        meta = json.load(f)

    keyframes = meta["keyframes"]
    n = len(keyframes)
    mid = n // 2
    half_a_kf = keyframes[:mid]
    half_b_kf = keyframes[mid:]

    print(f"Splitting {n} frames → half_a ({len(half_a_kf)}) + half_b ({len(half_b_kf)})")

    for half_name, kf_list in [("scan_half_a", half_a_kf), ("scan_half_b", half_b_kf)]:
        out_dir = os.path.join(base_dir, half_name)
        if os.path.exists(out_dir):
            shutil.rmtree(out_dir)
        os.makedirs(out_dir)
        os.makedirs(os.path.join(out_dir, "keyframes"))

        # Copy mesh (same for both halves)
        shutil.copy2(os.path.join(scan_root, "mesh.ply"), os.path.join(out_dir, "mesh.ply"))

        # Copy keyframes + per-frame JSONs
        has_depth = False
        for kf in kf_list:
            fname = kf["filename"]
            json_fname = fname.replace(".jpg", ".json")

            src_jpg = os.path.join(scan_root, "keyframes", fname)
            src_json = os.path.join(scan_root, "keyframes", json_fname)
            if os.path.exists(src_jpg):
                shutil.copy2(src_jpg, os.path.join(out_dir, "keyframes", fname))
            if os.path.exists(src_json):
                shutil.copy2(src_json, os.path.join(out_dir, "keyframes", json_fname))

            # Copy depth
            if kf.get("depth_filename"):
                src_dep = os.path.join(scan_root, "depth", kf["depth_filename"])
                if os.path.exists(src_dep):
                    if not has_depth:
                        os.makedirs(os.path.join(out_dir, "depth"), exist_ok=True)
                        has_depth = True
                    shutil.copy2(src_dep, os.path.join(out_dir, "depth", kf["depth_filename"]))

        # Write metadata
        half_meta = dict(meta)
        half_meta["keyframes"] = kf_list
        half_meta["keyframe_count"] = len(kf_list)
        with open(os.path.join(out_dir, "metadata.json"), "w") as f:
            json.dump(half_meta, f, indent=2)

        total_size = sum(
            os.path.getsize(os.path.join(dp, fn))
            for dp, _, fns in os.walk(out_dir) for fn in fns
        )
        print(f"  {half_name}: {len(kf_list)} frames, {total_size / 1024 / 1024:.1f} MB")

    print(f"\nDone. Now run:")
    print(f"  cd {base_dir}")
    print(f"  python3 ../test_supplemental_merge.py \\")
    print(f"      --original scan_half_a \\")
    print(f"      --supplemental scan_half_b \\")
    print(f"      --output merged_halves \\")
    print(f"      --skip-texture")


if __name__ == "__main__":
    main()
