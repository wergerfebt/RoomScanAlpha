#!/bin/bash
# Run OpenMVS TextureMesh on Room 3 scan data via Docker.
#
# Prerequisites:
#   1. Docker Desktop running
#   2. Run: python3 prepare_openmvs_input.py  (already done if openmvs_work/ exists)
#
# Usage: cd tests/local_scan && bash run_openmvs.sh

set -e

WORK_DIR="$(cd "$(dirname "$0")/openmvs_work" && pwd)"
IMAGE="furbrain/openmvs:latest"

echo "Work dir: $WORK_DIR"
echo ""

# Step 1: Convert COLMAP sparse reconstruction to OpenMVS format
echo "=== Step 1: InterfaceCOLMAP (COLMAP → MVS) ==="
docker run --rm -v "$WORK_DIR:/work" $IMAGE \
  InterfaceCOLMAP \
  -i /work \
  --image-folder /work/images \
  -o /work/scene.mvs \
  -w /work

echo ""

# Step 2: Import mesh into the MVS scene
# OpenMVS TextureMesh needs the mesh in the scene file.
# We can pass it directly via --mesh-file flag.

echo "=== Step 2: TextureMesh ==="
docker run --rm -v "$WORK_DIR:/work" $IMAGE \
  TextureMesh \
  /work/scene.mvs \
  --mesh-file /work/mesh_clean.ply \
  --export-type obj \
  -w /work \
  -o /work/textured.mvs \
  --resolution-level 1 \
  --cost-smoothness-ratio 1.0 \
  --global-seam-leveling 1 \
  --local-seam-leveling 1

echo ""
echo "=== Done ==="
ls -lh "$WORK_DIR"/textured* 2>/dev/null || echo "No output files found — check logs above"
echo ""
echo "View: open $WORK_DIR/textured.obj"
