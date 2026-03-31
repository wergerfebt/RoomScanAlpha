#!/bin/bash
# Texture mesh using COLMAP-refined poses.
# Run after run_colmap_ba.sh completes.

set -e

WORK="$(cd "$(dirname "$0")/openmvs_work" && pwd)"
OPENMVS_IMG="furbrain/openmvs:latest"

echo "Work dir: $WORK"

# Verify refined poses exist
if [ ! -f "$WORK/sparse_refined/images.txt" ]; then
  echo "ERROR: No refined poses found. Run run_colmap_ba.sh first."
  exit 1
fi

# ============================================================
echo "=== InterfaceCOLMAP (refined poses → MVS) ==="
# ============================================================
rm -f "$WORK/scene_refined.mvs"
docker run --rm -v "$WORK:/work" $OPENMVS_IMG \
  InterfaceCOLMAP \
    -i /work \
    --image-folder /work/images \
    -o /work/scene_refined.mvs \
    -w /work \
    --input-file sparse_refined

echo ""

# ============================================================
echo "=== TextureMesh (refined poses, smoothness=10) ==="
# ============================================================
rm -f "$WORK/textured_refined"*
docker run --rm -v "$WORK:/work" $OPENMVS_IMG \
  TextureMesh \
    /work/scene_refined.mvs \
    --mesh-file /work/mesh_clean.ply \
    --export-type obj \
    -w /work \
    -o /work/textured_refined.mvs \
    --resolution-level 1 \
    --cost-smoothness-ratio 10.0 \
    --global-seam-leveling 0 \
    --local-seam-leveling 0

# Fix transparency
chmod 644 "$WORK/textured_refined.mtl"
sed -i '' 's/Tr 1.000000/Tr 0.000000/' "$WORK/textured_refined.mtl"

echo ""
echo "=== Done ==="
echo "Output: $WORK/textured_refined.obj"
echo ""
echo "View: open compare_viewer.html (after starting http server)"
