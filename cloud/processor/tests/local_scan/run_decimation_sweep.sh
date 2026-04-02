#!/bin/bash
# Decimation sweep: 5K / 10K / 20K / 50K / full mesh with identical TextureMesh params.
# Uses the new unified-frame scan (openmvs_work_new).
#
# Prerequisites: Docker Desktop running, prepare_new_scan.py already run
# Usage: cd tests/local_scan && bash run_decimation_sweep.sh

set -e

WORK="$(cd "$(dirname "$0")/openmvs_work_new" && pwd)"
OPENMVS_IMG="furbrain/openmvs:latest"
SMOOTHNESS=10.0
SWEEP_DIR="$WORK/sweep"

echo "=== Decimation Sweep ==="
echo "Work dir: $WORK"
echo ""

# Verify prerequisites
if [ ! -d "$WORK/sparse" ] || [ ! -d "$WORK/images" ]; then
  echo "ERROR: Run prepare_new_scan.py first"
  exit 1
fi

# Generate decimated meshes
echo "=== Generating decimated meshes ==="
python3 -c "
import trimesh, os
work = '$WORK'
src = os.path.join(work, 'mesh_original_clean.ply')
if not os.path.exists(src):
    src = os.path.join(work, 'mesh_original.ply')
mesh = trimesh.load(src, process=False)
print(f'Original: {len(mesh.faces)} faces')
for target in [5000, 10000, 20000, 50000]:
    out = os.path.join(work, f'mesh_{target//1000}k.ply')
    dec = mesh.simplify_quadric_decimation(face_count=target)
    dec.export(out)
    print(f'  {target//1000}K: {len(dec.faces)} faces → {out}')
"

echo ""

# Run TextureMesh for each decimation level
run_variant() {
  local NAME=$1
  local MESH_FILE=$2
  local DIR="$SWEEP_DIR/$NAME"

  mkdir -p "$DIR/sparse"
  cp "$WORK/sparse/cameras.txt"  "$DIR/sparse/"
  cp "$WORK/sparse/images.txt"   "$DIR/sparse/"
  cp "$WORK/sparse/points3D.txt" "$DIR/sparse/"
  cp "$WORK/$MESH_FILE"          "$DIR/mesh.ply"

  echo "--- [$NAME] InterfaceCOLMAP ---"
  docker run --rm -v "$WORK:/work" $OPENMVS_IMG \
    InterfaceCOLMAP \
      -i "/work/sweep/$NAME" \
      --image-folder /work/images \
      -o "/work/sweep/$NAME/scene.mvs" \
      -w "/work/sweep/$NAME"

  echo "--- [$NAME] TextureMesh ---"
  docker run --rm -v "$WORK:/work" $OPENMVS_IMG \
    TextureMesh \
      "/work/sweep/$NAME/scene.mvs" \
      --mesh-file "/work/sweep/$NAME/mesh.ply" \
      --export-type obj \
      -w "/work/sweep/$NAME" \
      -o "/work/sweep/$NAME/textured.mvs" \
      --resolution-level 1 \
      --cost-smoothness-ratio $SMOOTHNESS \
      --global-seam-leveling 0 \
      --local-seam-leveling 0

  # Fix MTL transparency
  local MTL="$DIR/textured.mtl"
  if [ -f "$MTL" ]; then
    chmod 644 "$MTL"
    sed -i '' 's/Tr 1\.000000/Tr 0.000000/' "$MTL"
  fi

  # Count patches from log
  echo ""
}

rm -rf "$SWEEP_DIR"

run_variant "5k"   "mesh_5k.ply"
run_variant "10k"  "mesh_10k.ply"
run_variant "20k"  "mesh_20k.ply"
run_variant "50k"  "mesh_50k.ply"

# Also copy original mesh for full variant
echo "=== Preparing full mesh variant ==="
ORIG_MESH="mesh_original_clean.ply"
if [ ! -f "$WORK/$ORIG_MESH" ]; then
  ORIG_MESH="mesh_original.ply"
fi
run_variant "full" "$ORIG_MESH"

echo ""
echo "=== Sweep Complete ==="
for d in "$SWEEP_DIR"/*/; do
  NAME=$(basename "$d")
  FACES=$(python3 -c "import trimesh; m=trimesh.load('$d/mesh.ply',process=False); print(len(m.faces))" 2>/dev/null || echo "?")
  echo "  $NAME: $FACES faces → $d/textured.obj"
done
echo ""
echo "View:"
echo "  cd openmvs_work_new/sweep && python3 -m http.server 8091"
echo "  open http://localhost:8091/compare_viewer.html"
