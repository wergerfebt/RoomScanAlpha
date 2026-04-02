#!/bin/bash
# Package OpenMVS output + keyframes for the NvDiffRast Colab notebook.
#
# Usage:
#   ./prepare_nvdiffrast_input.sh [openmvs_work_dir] [obj_basename]
#
# Example:
#   ./prepare_nvdiffrast_input.sh openmvs_work textured_smooth
#
# Output: nvdiffrast_input.zip (upload to Colab)

set -euo pipefail

WORK="${1:-openmvs_work}"
OBJ_BASE="${2:-textured_smooth}"
OUT="nvdiffrast_input.zip"

if [ ! -d "$WORK" ]; then
    echo "Error: directory '$WORK' not found" >&2
    exit 1
fi

if [ ! -f "$WORK/${OBJ_BASE}.obj" ]; then
    echo "Error: ${WORK}/${OBJ_BASE}.obj not found" >&2
    echo "Available OBJ files:"
    ls "$WORK"/*.obj 2>/dev/null || echo "  (none)"
    exit 1
fi

echo "Packaging NvDiffRast input..."
echo "  Work dir: $WORK"
echo "  Mesh:     ${OBJ_BASE}.obj"

# Build zip from the work directory
cd "$WORK"

rm -f "../$OUT"
zip -r "../$OUT" \
    "${OBJ_BASE}.obj" \
    "${OBJ_BASE}.mtl" \
    ${OBJ_BASE}*_map_Kd.* \
    sparse/cameras.txt \
    sparse/images.txt \
    images/

cd ..
SIZE=$(du -h "$OUT" | cut -f1)
IMGS=$(unzip -l "$OUT" | grep -c 'images/')
echo ""
echo "Created: $OUT ($SIZE)"
echo "  Images: $IMGS keyframes"
echo "  Upload to: https://colab.research.google.com"
echo "  Notebook:  nvdiffrast_refine.ipynb"
