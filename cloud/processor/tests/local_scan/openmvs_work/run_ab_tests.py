"""Run A/B tests for texture duplication diagnosis.

Tests:
  A: Baseline (312K faces, 180 images) — already done as textured_smooth.*
  B: Decimated mesh (5K faces, 180 images)
  C: Walk-only (312K faces, 60 walk images)
  D: Pano-only (312K faces, 120 pano images)
  E: Decimated + Walk-only (5K faces, 60 walk images)
"""

import os
import shutil
import subprocess
import trimesh

WORK = os.path.dirname(os.path.abspath(__file__))
OPENMVS_IMG = "furbrain/openmvs:latest"
SMOOTHNESS = 10.0


def filter_images_txt(src_path, dst_path, prefix_filter=None):
    """Copy images.txt, optionally filtering to only names matching prefix."""
    with open(src_path) as f:
        lines = f.readlines()

    out = []
    img_id = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith('#'):
            out.append(line)
            i += 1
            continue
        if line.strip() == '':
            i += 1
            continue
        parts = line.strip().split()
        if len(parts) >= 10 and parts[9].endswith('.jpg'):
            name = parts[9]
            keep = prefix_filter is None or name.startswith(prefix_filter)
            # Skip next line (POINTS2D)
            next_line = lines[i + 1] if i + 1 < len(lines) else '\n'
            if keep:
                img_id += 1
                parts[0] = str(img_id)
                out.append(' '.join(parts) + '\n')
                out.append('\n')
            i += 2
        else:
            i += 1

    with open(dst_path, 'w') as f:
        f.writelines(out)
    return img_id


def run_openmvs(test_name, mesh_file, images_txt, cameras_txt):
    """Run InterfaceCOLMAP + TextureMesh for a test variant."""
    test_dir = os.path.join(WORK, f"test_{test_name}")
    os.makedirs(test_dir, exist_ok=True)

    # Set up COLMAP sparse dir
    sparse_dir = os.path.join(test_dir, "sparse")
    os.makedirs(sparse_dir, exist_ok=True)
    shutil.copy(images_txt, os.path.join(sparse_dir, "images.txt"))
    shutil.copy(cameras_txt, os.path.join(sparse_dir, "cameras.txt"))
    with open(os.path.join(sparse_dir, "points3D.txt"), 'w') as f:
        f.write("# empty\n")

    # Copy mesh
    mesh_dst = os.path.join(test_dir, "mesh.ply")
    if not os.path.exists(mesh_dst):
        shutil.copy(mesh_file, mesh_dst)

    # InterfaceCOLMAP
    print(f"  [{test_name}] InterfaceCOLMAP...")
    subprocess.run([
        "docker", "run", "--rm", "-v", f"{WORK}:/work", OPENMVS_IMG,
        "InterfaceCOLMAP",
        "-i", f"/work/test_{test_name}",
        "--image-folder", "/work/images",
        "-o", f"/work/test_{test_name}/scene.mvs",
        "-w", f"/work/test_{test_name}",
    ], capture_output=True)

    # TextureMesh
    print(f"  [{test_name}] TextureMesh...")
    result = subprocess.run([
        "docker", "run", "--rm", "-v", f"{WORK}:/work", OPENMVS_IMG,
        "TextureMesh",
        f"/work/test_{test_name}/scene.mvs",
        "--mesh-file", f"/work/test_{test_name}/mesh.ply",
        "--export-type", "obj",
        "-w", f"/work/test_{test_name}",
        "-o", f"/work/test_{test_name}/textured.mvs",
        "--resolution-level", "1",
        "--cost-smoothness-ratio", str(SMOOTHNESS),
        "--global-seam-leveling", "0",
        "--local-seam-leveling", "0",
    ], capture_output=True, text=True)

    # Print key stats
    for line in result.stdout.split('\n'):
        if 'patches' in line or 'faces' in line:
            print(f"  [{test_name}] {line.strip()}")

    # Fix MTL
    mtl_path = os.path.join(test_dir, "textured.mtl")
    if os.path.exists(mtl_path):
        os.chmod(mtl_path, 0o644)
        with open(mtl_path, 'w') as f:
            f.write("newmtl material_00\n")
            f.write("Ka 1.0 1.0 1.0\nKd 1.0 1.0 1.0\nKs 0.0 0.0 0.0\n")
            f.write("Tr 0.0\nd 1.0\nillum 1\nNs 1.0\n")
            f.write("map_Kd textured_material_00_map_Kd.jpg\n")


def main():
    cameras_txt = os.path.join(WORK, "sparse", "cameras.txt")
    images_txt = os.path.join(WORK, "sparse", "images.txt")
    full_mesh = os.path.join(WORK, "mesh_clean.ply")

    # Decimate mesh for tests B and E
    decimated_mesh = os.path.join(WORK, "mesh_5k.ply")
    if not os.path.exists(decimated_mesh):
        print("Decimating mesh to 5K faces...")
        mesh = trimesh.load(full_mesh)
        print(f"  Original: {len(mesh.faces)} faces")
        mesh_dec = mesh.simplify_quadric_decimation(face_count=5000)
        mesh_dec.export(decimated_mesh)
        print(f"  Decimated: {len(mesh_dec.faces)} faces")

    # Filter images for walk-only and pano-only
    walk_images = os.path.join(WORK, "images_walk.txt")
    pano_images = os.path.join(WORK, "images_pano.txt")

    n_walk = filter_images_txt(images_txt, walk_images, prefix_filter="walk_")
    n_pano = filter_images_txt(images_txt, pano_images, prefix_filter="pano_")
    print(f"Walk-only: {n_walk} images, Pano-only: {n_pano} images")

    # --- Test B: Decimated mesh, all images ---
    print("\n=== Test B: Decimated 5K faces, 180 images ===")
    run_openmvs("B", decimated_mesh, images_txt, cameras_txt)

    # --- Test C: Full mesh, walk-only ---
    print("\n=== Test C: Full mesh, walk-only (60 images) ===")
    run_openmvs("C", full_mesh, walk_images, cameras_txt)

    # --- Test D: Full mesh, pano-only ---
    print("\n=== Test D: Full mesh, pano-only (120 images) ===")
    run_openmvs("D", full_mesh, pano_images, cameras_txt)

    # --- Test E: Decimated + walk-only ---
    print("\n=== Test E: Decimated 5K + walk-only ===")
    run_openmvs("E", decimated_mesh, walk_images, cameras_txt)

    print("\n=== All tests complete ===")
    for t in ['B', 'C', 'D', 'E']:
        obj = os.path.join(WORK, f"test_{t}", "textured.obj")
        tex = os.path.join(WORK, f"test_{t}", "textured_material_00_map_Kd.jpg")
        print(f"  Test {t}: obj={'YES' if os.path.exists(obj) else 'NO'} tex={'YES' if os.path.exists(tex) else 'NO'}")


if __name__ == "__main__":
    main()
