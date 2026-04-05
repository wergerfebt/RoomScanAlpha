"""Local prototype: Detect mesh holes via volumetric voxel analysis.

The mesh is highly fragmented (~600 disconnected components). Boundary edge
detection can't find "holes" because the gaps are BETWEEN fragments, not
within them. Instead, we voxelize the mesh's bounding volume and identify
empty voxels surrounded by occupied ones as holes.

Usage:
    python tests/test_hole_detection.py
"""

import os
import sys
import numpy as np
from collections import defaultdict
from pathlib import Path

# Test data — adjust paths as needed
OBJ_PATH = "/tmp/hole_test/textured.obj"
OUTPUT_PATH = "/tmp/hole_test/holes_overlay.obj"

# Voxel resolution in meters — smaller = more precise but more voxels
VOXEL_SIZE = 0.15  # 15cm voxels


def parse_obj(path: str):
    """Parse OBJ vertices and face vertex indices."""
    vertices = []
    face_vert_indices = []

    with open(path) as f:
        for line in f:
            if line.startswith("v "):
                parts = line.split()
                vertices.append([float(parts[1]), float(parts[2]), float(parts[3])])
            elif line.startswith("f "):
                parts = line.split()[1:]
                vi = []
                for p in parts:
                    segs = p.split("/")
                    vi.append(int(segs[0]) - 1)
                face_vert_indices.append(vi)

    return np.array(vertices, dtype=np.float64), face_vert_indices


def voxelize_mesh(vertices, faces, voxel_size):
    """Mark voxels that contain mesh geometry (triangle rasterization).

    For each face, we sample points along the triangle surface and mark
    the voxels they fall into as occupied.
    """
    # Compute grid bounds
    v_min = vertices.min(axis=0) - voxel_size
    v_max = vertices.max(axis=0) + voxel_size
    grid_origin = v_min
    grid_size = np.ceil((v_max - v_min) / voxel_size).astype(int)

    print(f"Voxel grid: {grid_size[0]}x{grid_size[1]}x{grid_size[2]} = {np.prod(grid_size)} voxels")
    print(f"Bounds: ({v_min[0]:.2f},{v_min[1]:.2f},{v_min[2]:.2f}) → ({v_max[0]:.2f},{v_max[1]:.2f},{v_max[2]:.2f})")

    occupied = set()

    for face in faces:
        v0, v1, v2 = vertices[face[0]], vertices[face[1]], vertices[face[2]]

        # Sample points on the triangle surface using barycentric coordinates
        # Adaptive density based on triangle size
        edge_len = max(
            np.linalg.norm(v1 - v0),
            np.linalg.norm(v2 - v0),
            np.linalg.norm(v2 - v1),
        )
        n_samples = max(int(edge_len / (voxel_size * 0.5)), 2)

        for i in range(n_samples + 1):
            for j in range(n_samples + 1 - i):
                u = i / n_samples
                v = j / n_samples
                if u + v > 1.0:
                    continue
                w = 1.0 - u - v
                pt = u * v0 + v * v1 + w * v2
                voxel = tuple(((pt - grid_origin) / voxel_size).astype(int))
                occupied.add(voxel)

    print(f"Occupied voxels: {len(occupied)}")
    return occupied, grid_origin, grid_size


def find_interior_voids(occupied, grid_size, dilation=1):
    """Find empty voxels enclosed by mesh geometry (interior voids).

    The mesh is highly fragmented (~600 disconnected components), so small
    gaps between fragments allow exterior flood fill to penetrate inside.
    We dilate the occupied voxels first to seal these inter-fragment gaps,
    then flood fill from the boundary to find exterior space. Any empty
    voxel not reached is an interior void.

    The final void set is computed against the ORIGINAL (undilated) occupied
    set, so voids include the sealed gap spaces.
    """
    gx, gy, gz = grid_size
    directions = [(1,0,0),(-1,0,0),(0,1,0),(0,-1,0),(0,0,1),(0,0,-1)]

    # Dilate occupied voxels to seal inter-fragment gaps
    blocked = set(occupied)  # Start with original occupied
    for _ in range(dilation):
        new_blocked = set()
        for vx, vy, vz in blocked:
            for dx, dy, dz in directions:
                nv = (vx+dx, vy+dy, vz+dz)
                new_blocked.add(nv)
        blocked |= new_blocked

    print(f"Occupied: {len(occupied)}, After dilation({dilation}): {len(blocked)}")

    # Flood fill from boundary using the dilated blockage
    exterior = set()
    queue = []

    for x in range(gx):
        for y in range(gy):
            for z in [0, gz - 1]:
                v = (x, y, z)
                if v not in blocked:
                    exterior.add(v)
                    queue.append(v)
            for z in range(gz):
                if x == 0 or x == gx - 1 or y == 0 or y == gy - 1:
                    v = (x, y, z)
                    if v not in blocked:
                        exterior.add(v)
                        queue.append(v)

    head = 0
    while head < len(queue):
        cx, cy, cz = queue[head]
        head += 1
        for dx, dy, dz in directions:
            nx, ny, nz = cx+dx, cy+dy, cz+dz
            if 0 <= nx < gx and 0 <= ny < gy and 0 <= nz < gz:
                nv = (nx, ny, nz)
                if nv not in blocked and nv not in exterior:
                    exterior.add(nv)
                    queue.append(nv)

    # Interior voids = not exterior, not occupied (original, undilated)
    interior = set()
    for x in range(gx):
        for y in range(gy):
            for z in range(gz):
                v = (x, y, z)
                if v not in occupied and v not in exterior:
                    interior.add(v)

    print(f"Exterior: {len(exterior)}, Interior voids: {len(interior)}")
    return interior


def voxels_to_triangles(void_voxels, occupied, grid_origin, voxel_size):
    """Convert interior void voxels to surface quads (only faces adjacent to occupied voxels).

    Only generates faces on the boundary between void and occupied voxels,
    so the red overlay sits flush against the mesh surface.
    """
    triangles = []
    directions = [(1,0,0),(-1,0,0),(0,1,0),(0,-1,0),(0,0,1),(0,0,-1)]

    # For each void voxel, check which faces are adjacent to occupied voxels
    for vx, vy, vz in void_voxels:
        base = grid_origin + np.array([vx, vy, vz]) * voxel_size

        for dx, dy, dz in directions:
            neighbor = (vx+dx, vy+dy, vz+dz)
            if neighbor in occupied:
                # This face borders the mesh — emit a quad (2 triangles)
                # The face is on the side of the void voxel facing the neighbor
                if dx == 1:  # +X face
                    p0 = base + [voxel_size, 0, 0]
                    p1 = base + [voxel_size, voxel_size, 0]
                    p2 = base + [voxel_size, voxel_size, voxel_size]
                    p3 = base + [voxel_size, 0, voxel_size]
                elif dx == -1:  # -X face
                    p0 = base + [0, 0, 0]
                    p1 = base + [0, 0, voxel_size]
                    p2 = base + [0, voxel_size, voxel_size]
                    p3 = base + [0, voxel_size, 0]
                elif dy == 1:  # +Y face
                    p0 = base + [0, voxel_size, 0]
                    p1 = base + [voxel_size, voxel_size, 0]
                    p2 = base + [voxel_size, voxel_size, voxel_size]
                    p3 = base + [0, voxel_size, voxel_size]
                elif dy == -1:  # -Y face
                    p0 = base + [0, 0, 0]
                    p1 = base + [0, 0, voxel_size]
                    p2 = base + [voxel_size, 0, voxel_size]
                    p3 = base + [voxel_size, 0, 0]
                elif dz == 1:  # +Z face
                    p0 = base + [0, 0, voxel_size]
                    p1 = base + [voxel_size, 0, voxel_size]
                    p2 = base + [voxel_size, voxel_size, voxel_size]
                    p3 = base + [0, voxel_size, voxel_size]
                else:  # -Z face
                    p0 = base + [0, 0, 0]
                    p1 = base + [0, voxel_size, 0]
                    p2 = base + [voxel_size, voxel_size, 0]
                    p3 = base + [voxel_size, 0, 0]

                triangles.append([p0, p1, p2])
                triangles.append([p0, p2, p3])

    return triangles


def detect_holes(vertices, faces):
    """Detect mesh holes by ray casting from the room center.

    Casts rays outward from the mesh centroid in a spherical pattern.
    Rays that escape without hitting any mesh face indicate gaps.
    A quad is placed at the bounding box intersection point for each
    escaping ray, showing where coverage is missing.
    """
    import trimesh

    mesh = trimesh.Trimesh(
        vertices=vertices,
        faces=np.array(faces),
        process=False,
    )

    # Room center = centroid of all vertices
    center = vertices.mean(axis=0)
    print(f"Room center: ({center[0]:.2f}, {center[1]:.2f}, {center[2]:.2f})")
    print(f"Mesh bounds: {vertices.min(axis=0)} → {vertices.max(axis=0)}")

    # Generate ray directions in a spherical pattern
    # Use a fibonacci sphere for even distribution
    # High density needed — rays spread apart with distance from center
    n_rays = 10000
    directions = []
    golden_ratio = (1 + np.sqrt(5)) / 2
    for i in range(n_rays):
        theta = np.arccos(1 - 2 * (i + 0.5) / n_rays)
        phi = 2 * np.pi * i / golden_ratio
        dx = np.sin(theta) * np.cos(phi)
        dy = np.sin(theta) * np.sin(phi)
        dz = np.cos(theta)
        directions.append([dx, dy, dz])

    directions = np.array(directions)
    origins = np.tile(center, (n_rays, 1))

    # Cast all rays
    hits, ray_ids, _ = mesh.ray.intersects_location(origins, directions, multiple_hits=False)

    hit_ray_set = set(ray_ids)
    miss_indices = [i for i in range(n_rays) if i not in hit_ray_set]
    print(f"Rays cast: {n_rays}, Hits: {len(hit_ray_set)}, Misses: {len(miss_indices)}")

    if not miss_indices:
        print("All rays hit mesh — no holes detected.")
        return []

    # For each missed ray, find where it intersects the bounding box
    # and place a patch there
    bbox_min = vertices.min(axis=0) - 0.1
    bbox_max = vertices.max(axis=0) + 0.1
    patch_size = VOXEL_SIZE

    hole_triangles = []
    for i in miss_indices:
        d = directions[i]

        # Ray-AABB intersection to find where the ray exits the bounding box
        t_min_all = -np.inf
        t_max_all = np.inf
        for axis in range(3):
            if abs(d[axis]) < 1e-10:
                continue
            t1 = (bbox_min[axis] - center[axis]) / d[axis]
            t2 = (bbox_max[axis] - center[axis]) / d[axis]
            t_near = min(t1, t2)
            t_far = max(t1, t2)
            t_min_all = max(t_min_all, t_near)
            t_max_all = min(t_max_all, t_far)

        if t_max_all <= 0:
            continue

        # Place patch at the bounding box exit point
        t = max(t_max_all, 0.1)
        hit_point = center + d * t

        # Create a small quad oriented perpendicular to the ray direction
        # Find two perpendicular vectors to the ray direction
        if abs(d[1]) < 0.9:
            up = np.array([0, 1, 0])
        else:
            up = np.array([1, 0, 0])

        right = np.cross(d, up)
        right = right / (np.linalg.norm(right) + 1e-10) * patch_size * 0.5
        up_vec = np.cross(right, d)
        up_vec = up_vec / (np.linalg.norm(up_vec) + 1e-10) * patch_size * 0.5

        p0 = hit_point - right - up_vec
        p1 = hit_point + right - up_vec
        p2 = hit_point + right + up_vec
        p3 = hit_point - right + up_vec

        hole_triangles.append([p0, p1, p2])
        hole_triangles.append([p0, p2, p3])

    hole_area = len(hole_triangles) * (patch_size ** 2) * 0.5
    print(f"\nHole patches: {len(miss_indices)} missed rays → {len(hole_triangles)} triangles")
    print(f"Approximate hole area: {hole_area:.1f} m²")
    return hole_triangles


def export_holes_obj(hole_triangles, output_path):
    """Export hole fill triangles as a colored OBJ for visualization."""
    with open(output_path, "w") as f:
        f.write("# Mesh hole fill triangles (red)\n")
        f.write("mtllib holes.mtl\n")
        f.write("usemtl hole_fill\n")
        vi = 1
        for tri in hole_triangles:
            for v in tri:
                f.write(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
            f.write(f"f {vi} {vi+1} {vi+2}\n")
            vi += 3

    # Write MTL
    mtl_path = output_path.replace(".obj", ".mtl")
    with open(mtl_path, "w") as f:
        f.write("newmtl hole_fill\n")
        f.write("Kd 1.0 0.0 0.0\n")  # Red
        f.write("Tr 0.5\n")

    print(f"Exported {len(hole_triangles)} triangles to {output_path}")


def export_combined_obj(obj_path, hole_triangles, output_path):
    """Export the original textured mesh + red hole fills as a single OBJ."""
    # Read original OBJ lines
    with open(obj_path) as f:
        original_lines = f.readlines()

    # Count original vertices
    orig_vert_count = sum(1 for l in original_lines if l.startswith("v "))

    with open(output_path, "w") as f:
        # Write combined MTL reference
        f.write("mtllib combined.mtl\n")

        # Write original geometry (skip any existing mtllib line)
        for line in original_lines:
            if line.startswith("mtllib"):
                continue
            f.write(line)

        # Append hole fill geometry with a different material
        f.write("\n# --- Hole fill triangles (red) ---\n")
        f.write("usemtl hole_fill\n")
        vi = orig_vert_count + 1
        for tri in hole_triangles:
            for v in tri:
                f.write(f"v {v[0]:.6f} {v[1]:.6f} {v[2]:.6f}\n")
            f.write(f"f {vi} {vi+1} {vi+2}\n")
            vi += 3

    # Write combined MTL (original material + red hole fill)
    mtl_path = output_path.replace(".obj", ".mtl")
    with open(mtl_path, "w") as f:
        # Original textured material
        f.write("newmtl material_00\n")
        f.write("Ka 1.0 1.0 1.0\n")
        f.write("Kd 1.0 1.0 1.0\n")
        f.write("Ks 0.0 0.0 0.0\n")
        f.write("Tr 0.0\n")
        f.write("illum 1\n")
        f.write("Ns 1.0\n")
        f.write("map_Kd textured_material_00_map_Kd.jpg\n\n")
        # Red hole fill material
        f.write("newmtl hole_fill\n")
        f.write("Ka 1.0 0.0 0.0\n")
        f.write("Kd 1.0 0.0 0.0\n")
        f.write("Ks 0.0 0.0 0.0\n")
        f.write("Tr 0.3\n")
        f.write("illum 1\n")

    print(f"Exported combined mesh to {output_path}")


def main():
    if not os.path.exists(OBJ_PATH):
        print(f"OBJ not found at {OBJ_PATH}")
        print("Download with: gsutil cp gs://roomscanalpha-scans/scans/4bdfb9e8-.../textured.obj /tmp/hole_test/")
        sys.exit(1)

    print(f"Loading {OBJ_PATH}...")
    vertices, faces = parse_obj(OBJ_PATH)
    print(f"Parsed: {len(vertices)} vertices, {len(faces)} faces")

    hole_triangles = detect_holes(vertices, faces)

    if hole_triangles:
        export_holes_obj(hole_triangles, OUTPUT_PATH)
        combined_path = "/tmp/hole_test/combined.obj"
        export_combined_obj(OBJ_PATH, hole_triangles, combined_path)
    else:
        print("No interior holes detected.")


if __name__ == "__main__":
    main()
