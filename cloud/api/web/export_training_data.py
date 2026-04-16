#!/usr/bin/env python3
"""
Export 3D face annotations to 2D keyframe segmentation masks for DNN training.

Uses a painter's algorithm: projects ALL mesh faces to 2D, sorts by depth
(back-to-front), and draws them as filled polygons. Closer faces naturally
overwrite farther ones, solving the occlusion problem per-pixel.

Usage:
    python3 export_training_data.py [--annotations annotations.json] [--scan-dir merged] [--output training_output]

Coordinate conventions (from texture_projection.py):
  - ARKit Y-up right-handed: X=right, Y=up, Z=back
  - camera_transform is world-from-camera, 4×4, stored as 16 floats column-major
  - Camera looks along -Z in camera space
  - Image: X-right, Y-down
  - Projection: px = fx * x_cam / depth + cx,  py = -fy * y_cam / depth + cy
"""

import argparse
import json
import os
import glob
import time
from pathlib import Path

import numpy as np
import trimesh
from PIL import Image, ImageDraw


def load_mesh(mesh_path):
    """Load OBJ mesh as a single merged geometry to match Three.js OBJLoader indexing."""
    mesh = trimesh.load(mesh_path, process=False, force='mesh')
    print(f"Loaded mesh: {len(mesh.vertices)} verts, {len(mesh.faces)} faces")
    return mesh


def load_intrinsics(metadata_path):
    """Load camera intrinsics from metadata.json."""
    with open(metadata_path) as f:
        meta = json.load(f)
    intr = meta['camera_intrinsics']
    res = meta['image_resolution']
    return {
        'fx': intr['fx'], 'fy': intr['fy'],
        'cx': intr['cx'], 'cy': intr['cy'],
        'width': res['width'], 'height': res['height'],
    }


def load_keyframe(json_path):
    """Load a keyframe's camera pose. Returns cam_from_world 4×4 matrix."""
    with open(json_path) as f:
        kf = json.load(f)
    world_from_cam = np.array(kf['camera_transform'], dtype=np.float64).reshape(4, 4, order='F')
    cam_from_world = np.linalg.inv(world_from_cam)
    return cam_from_world, kf


def project_all_faces(vertices, faces, cam_from_world, intr):
    """Batch-project ALL mesh faces to 2D pixel coords using vectorized numpy.

    Returns:
        px: (M, 3) x pixel coords per face vertex
        py: (M, 3) y pixel coords per face vertex
        avg_depths: (M,) average depth per face (for sorting)
        valid: (M,) boolean mask — True if all 3 vertices are in front of camera
    """
    fx, fy, cx, cy = intr['fx'], intr['fy'], intr['cx'], intr['cy']
    M = len(faces)

    # Get all triangle vertices: (M, 3, 3) — M faces, 3 verts, 3 coords
    tri = vertices[faces]

    # Transform to camera space: flatten to (M*3, 3), add homogeneous, multiply
    flat = tri.reshape(-1, 3)
    pts_h = np.hstack([flat, np.ones((len(flat), 1))])  # (M*3, 4)
    cam_pts = (cam_from_world @ pts_h.T).T[:, :3].reshape(M, 3, 3)  # (M, 3, 3)

    # Depth = -Z (camera looks along -Z in ARKit)
    depths = -cam_pts[:, :, 2]  # (M, 3)

    # Valid = all 3 vertices in front of camera
    valid = np.all(depths > 0.05, axis=1)  # (M,)

    # Project to pixels (compute for all, mask later)
    with np.errstate(divide='ignore', invalid='ignore'):
        px = fx * cam_pts[:, :, 0] / depths + cx  # (M, 3)
        py = -fy * cam_pts[:, :, 1] / depths + cy  # (M, 3)

    avg_depths = depths.mean(axis=1)  # (M,) — for reference
    min_depths = depths.min(axis=1)   # (M,) — closest vertex, used for sort

    return px, py, min_depths, valid


def render_face_id_buffer(px, py, avg_depths, valid, face_labels, W, H):
    """Painter's algorithm: draw all faces back-to-front, returning per-pixel face ID.

    Args:
        px, py: (M, 3) projected pixel coords per face vertex
        avg_depths: (M,) average depth per face
        valid: (M,) boolean mask
        face_labels: dict mapping face_index → class_id (only for annotated faces)
        W, H: image dimensions

    Returns:
        label_img: (H, W) uint8 array, pixel value = class_id (0 = background)
    """
    M = len(px)

    # Filter to valid faces that are at least partially in frame
    in_frame = valid.copy()
    for v in range(3):
        in_frame &= (px[:, v] > -100) & (px[:, v] < W + 100)
        in_frame &= (py[:, v] > -100) & (py[:, v] < H + 100)

    visible_indices = np.where(in_frame)[0]
    if len(visible_indices) == 0:
        return np.zeros((H, W), dtype=np.uint8)

    # Sort back-to-front (farthest first → closest drawn last → overwrites)
    visible_depths = avg_depths[visible_indices]
    sort_order = np.argsort(-visible_depths)  # descending depth = back-to-front
    sorted_indices = visible_indices[sort_order]

    # Draw into a face-ID image using Pillow
    # Encode face index as 24-bit RGB: R = low byte, G = mid byte, B = high byte
    face_id_img = Image.new('RGB', (W, H), (0, 0, 0))
    draw = ImageDraw.Draw(face_id_img)

    for fi in sorted_indices:
        # Encode face index + 1 (so 0,0,0 = background)
        idx = int(fi) + 1
        r = idx & 0xFF
        g = (idx >> 8) & 0xFF
        b = (idx >> 16) & 0xFF

        polygon = [
            (float(px[fi, 0]), float(py[fi, 0])),
            (float(px[fi, 1]), float(py[fi, 1])),
            (float(px[fi, 2]), float(py[fi, 2])),
        ]
        draw.polygon(polygon, fill=(r, g, b))

    # Decode face-ID image back to face indices
    id_arr = np.array(face_id_img)  # (H, W, 3) uint8
    face_ids = id_arr[:, :, 0].astype(np.int32) | \
               (id_arr[:, :, 1].astype(np.int32) << 8) | \
               (id_arr[:, :, 2].astype(np.int32) << 16)
    face_ids -= 1  # back to 0-indexed, -1 = background

    # Build label mask: look up class_id for each pixel's face
    label_img = np.zeros((H, W), dtype=np.uint8)
    for fi, class_id in face_labels.items():
        mask = (face_ids == fi)
        label_img[mask] = class_id

    return label_img


def build_class_map(annotations):
    """Build label_key → class_id mapping (1-indexed, 0 = background)."""
    return {ann['label_key']: i + 1 for i, ann in enumerate(annotations)}


def parse_face_key(face_key):
    """Parse 'child_idx:face_idx' string → (child_idx, face_idx)."""
    parts = face_key.split(':')
    return int(parts[0]), int(parts[1])


def main():
    parser = argparse.ArgumentParser(description='Export 3D annotations to 2D keyframe masks')
    parser.add_argument('--annotations', default='annotations.json')
    parser.add_argument('--scan-dir', default='merged')
    parser.add_argument('--output', default='training_output')
    parser.add_argument('--max-frames', type=int, default=0, help='Max keyframes (0 = all)')
    parser.add_argument('--skip-viz', action='store_true', help='Skip visualization overlays')
    args = parser.parse_args()

    # Load annotations
    with open(args.annotations) as f:
        ann_data = json.load(f)

    annotations = ann_data['annotations']
    print(f"Annotations: {len(annotations)} labels")
    for a in annotations:
        print(f"  {a['label_key']}: {len(a['faces'])} faces, {a['quantity']} {a['unit']}")

    if not annotations:
        print("No annotations. Nothing to export.")
        return

    # Load mesh
    mesh = load_mesh(ann_data['mesh_file'])
    vertices = np.array(mesh.vertices, dtype=np.float64)
    faces = np.array(mesh.faces, dtype=np.int32)
    num_faces = len(faces)

    # Build class map and face → class_id lookup
    class_map = build_class_map(annotations)
    print(f"Class map: {class_map}")

    face_labels = {}  # face_index → class_id
    for ann in annotations:
        class_id = class_map[ann['label_key']]
        for fk in ann['faces']:
            ci, fi = parse_face_key(fk)
            if ci == 0 and fi < num_faces:
                face_labels[fi] = class_id

    print(f"Total labeled faces: {len(face_labels)}")

    # Load intrinsics
    intr = load_intrinsics(os.path.join(args.scan_dir, 'metadata.json'))
    W, H = intr['width'], intr['height']
    print(f"Camera: {W}x{H}, fx={intr['fx']:.1f}")

    # Find keyframes
    kf_jsons = sorted(glob.glob(os.path.join(args.scan_dir, 'keyframes', 'frame_*.json')))
    if args.max_frames > 0:
        kf_jsons = kf_jsons[:args.max_frames]
    print(f"Keyframes: {len(kf_jsons)}")

    # Output dirs
    out_dir = Path(args.output)
    (out_dir / 'images').mkdir(parents=True, exist_ok=True)
    (out_dir / 'masks').mkdir(parents=True, exist_ok=True)
    if not args.skip_viz:
        (out_dir / 'visualizations').mkdir(parents=True, exist_ok=True)

    # COCO structure
    coco = {'images': [], 'categories': [], 'annotations': []}
    for label_key, cid in class_map.items():
        ann = next(a for a in annotations if a['label_key'] == label_key)
        coco['categories'].append({
            'id': cid, 'name': label_key,
            'display_name': ann['display_name'],
            'unit': ann['unit'],
            'supercategory': ann.get('category', ''),
        })

    # Viz colors
    viz_colors = {}
    for ann in annotations:
        h = ann['color'].lstrip('#')
        viz_colors[ann['label_key']] = (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))

    # Class ID → color for viz
    class_colors = {}
    for ann in annotations:
        class_colors[class_map[ann['label_key']]] = viz_colors[ann['label_key']]

    ann_id_counter = 0
    frames_with_labels = 0

    for frame_idx, kf_json_path in enumerate(kf_jsons):
        frame_name = os.path.splitext(os.path.basename(kf_json_path))[0]
        frame_jpg = kf_json_path.replace('.json', '.jpg')
        if not os.path.exists(frame_jpg):
            continue

        t0 = time.time()
        cam_from_world, kf_meta = load_keyframe(kf_json_path)

        # Project all faces
        px, py, avg_depths, valid = project_all_faces(vertices, faces, cam_from_world, intr)

        # Render with painter's algorithm
        label_img = render_face_id_buffer(px, py, avg_depths, valid, face_labels, W, H)

        dt = time.time() - t0
        has_labels = label_img.max() > 0

        if has_labels:
            frames_with_labels += 1

        # Save mask
        mask = Image.fromarray(label_img)
        mask.save(str(out_dir / 'masks' / f'{frame_name}.png'))

        # Symlink keyframe image
        img_link = out_dir / 'images' / f'{frame_name}.jpg'
        if not img_link.exists():
            try:
                os.symlink(os.path.abspath(frame_jpg), str(img_link))
            except OSError:
                import shutil
                shutil.copy2(frame_jpg, str(img_link))

        # Visualization
        if not args.skip_viz and has_labels:
            try:
                base = Image.open(frame_jpg).convert('RGBA')
                overlay = Image.new('RGBA', (W, H), (0, 0, 0, 0))
                overlay_np = np.array(overlay)
                for cid, color in class_colors.items():
                    cmask = (label_img == cid)
                    overlay_np[cmask] = (*color, 100)
                overlay = Image.fromarray(overlay_np, 'RGBA')
                composite = Image.alpha_composite(base, overlay)
                composite.convert('RGB').save(
                    str(out_dir / 'visualizations' / f'{frame_name}_overlay.jpg'), quality=85)
            except Exception as e:
                print(f"  Viz failed for {frame_name}: {e}")

        # COCO entries
        coco['images'].append({
            'id': frame_idx, 'file_name': f'{frame_name}.jpg', 'width': W, 'height': H,
        })

        for ann in annotations:
            cid = class_map[ann['label_key']]
            cmask = (label_img == cid)
            if not cmask.any():
                continue
            ys, xs = np.where(cmask)
            coco['annotations'].append({
                'id': ann_id_counter,
                'image_id': frame_idx,
                'category_id': cid,
                'bbox': [int(xs.min()), int(ys.min()), int(xs.max()-xs.min()) + 1, int(ys.max()-ys.min()) + 1],
                'area': int(cmask.sum()),
                'iscrowd': 0,
            })
            ann_id_counter += 1

        if (frame_idx + 1) % 10 == 0 or frame_idx == len(kf_jsons) - 1:
            print(f"  {frame_idx + 1}/{len(kf_jsons)} ({dt:.1f}s/frame)")

    # Save COCO
    with open(str(out_dir / 'annotations.json'), 'w') as f:
        json.dump(coco, f, indent=2)

    print(f"\nDone!")
    print(f"  Keyframes: {len(kf_jsons)}, with labels: {frames_with_labels}")
    print(f"  COCO annotations: {ann_id_counter}")
    print(f"  Output: {out_dir}/")


if __name__ == '__main__':
    main()
