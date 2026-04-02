#!/bin/bash
# A/B test: ARKit raw poses vs COLMAP sequential BA (with Procrustes alignment).
# Uses IDENTICAL TextureMesh parameters — only poses differ.
#
# Pipeline:
#   1. COLMAP feature extraction + sequential matching (CPU, local Docker)
#   2. Triangulate points using ARKit poses as initialization
#   3. Bundle adjustment (refine poses, fix intrinsics)
#   4. Procrustes alignment: map BA-refined poses back to ARKit frame
#   5. TextureMesh both variants with identical parameters
#
# Prerequisites:
#   1. Docker Desktop running
#   2. prepare_openmvs_input.py already run (openmvs_work/sparse/ exists)
#
# Usage: cd tests/local_scan && bash run_ab_sequential.sh

set -e

WORK="$(cd "$(dirname "$0")/openmvs_work" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLMAP_IMG="colmap/colmap:latest"
OPENMVS_IMG="furbrain/openmvs:latest"
PLATFORM="--platform linux/amd64"
MESH="mesh_5k.ply"
SMOOTHNESS=10.0
AB_DIR="$WORK/ab_sequential"

echo "=== A/B Test: ARKit vs COLMAP Sequential BA ==="
echo "Work dir: $WORK"
echo "Mesh: $MESH | Smoothness: $SMOOTHNESS"
echo ""

# Verify prerequisites
for f in "$WORK/sparse/images.txt" "$WORK/$MESH" "$WORK/images"; do
  if [ ! -e "$f" ]; then
    echo "ERROR: Missing $f"
    exit 1
  fi
done

# ============================================================
echo "=== Phase 1: COLMAP Sequential BA ==="
# ============================================================

# Clean previous BA artifacts
rm -f "$WORK/database.db"
rm -rf "$WORK/sparse_triangulated" "$WORK/sparse_refined"

echo "--- Step 1: Feature Extraction (CPU) ---"
docker run --rm $PLATFORM -m 6g -v "$WORK:/work" $COLMAP_IMG \
  colmap feature_extractor \
    --database_path /work/database.db \
    --image_path /work/images \
    --ImageReader.single_camera 1 \
    --ImageReader.camera_model PINHOLE \
    --ImageReader.camera_params "1428.3756,1428.3756,958.9948,725.38055" \
    --FeatureExtraction.use_gpu 0 \
    --FeatureExtraction.num_threads 2 \
    --FeatureExtraction.max_image_size 1024

echo ""
echo "--- Step 2: Sequential Matching (overlap=10) ---"
docker run --rm $PLATFORM -m 6g -v "$WORK:/work" $COLMAP_IMG \
  colmap sequential_matcher \
    --database_path /work/database.db \
    --FeatureMatching.use_gpu 0 \
    --FeatureMatching.num_threads 2 \
    --SequentialMatching.overlap 10

echo ""
echo "--- Step 3: Triangulate Points with ARKit Poses ---"
mkdir -p "$WORK/sparse_triangulated"
docker run --rm $PLATFORM -m 6g -v "$WORK:/work" $COLMAP_IMG \
  colmap point_triangulator \
    --database_path /work/database.db \
    --image_path /work/images \
    --input_path /work/sparse \
    --output_path /work/sparse_triangulated

echo ""
echo "--- Step 4: Bundle Adjustment (refine poses only) ---"
mkdir -p "$WORK/sparse_refined"
docker run --rm $PLATFORM -m 6g -v "$WORK:/work" $COLMAP_IMG \
  colmap bundle_adjuster \
    --input_path /work/sparse_triangulated \
    --output_path /work/sparse_refined \
    --BundleAdjustment.refine_principal_point 0 \
    --BundleAdjustment.refine_focal_length 0 \
    --BundleAdjustment.refine_extra_params 0

echo ""
echo "--- Step 5: Procrustes Alignment (refined → ARKit frame) ---"
python3 "$SCRIPT_DIR/align_poses.py" \
  "$WORK/sparse/images.txt" \
  "$WORK/sparse_refined/images.txt" \
  "$WORK/sparse_aligned/images.txt"

# Copy camera and points files to aligned dir
cp "$WORK/sparse_refined/cameras.txt" "$WORK/sparse_aligned/"
cp "$WORK/sparse_refined/points3D.txt" "$WORK/sparse_aligned/"

echo ""

# ============================================================
echo "=== Phase 2: OpenMVS TextureMesh (both arms) ==="
# ============================================================

rm -rf "$AB_DIR/baseline" "$AB_DIR/colmap_seq"

# Baseline: raw ARKit poses
mkdir -p "$AB_DIR/baseline/sparse"
cp "$WORK/sparse/cameras.txt"  "$AB_DIR/baseline/sparse/"
cp "$WORK/sparse/images.txt"   "$AB_DIR/baseline/sparse/"
cp "$WORK/sparse/points3D.txt" "$AB_DIR/baseline/sparse/"
cp "$WORK/$MESH"               "$AB_DIR/baseline/mesh.ply"

# COLMAP sequential: aligned refined poses
mkdir -p "$AB_DIR/colmap_seq/sparse"
cp "$WORK/sparse_aligned/cameras.txt"  "$AB_DIR/colmap_seq/sparse/"
cp "$WORK/sparse_aligned/images.txt"   "$AB_DIR/colmap_seq/sparse/"
cp "$WORK/sparse_aligned/points3D.txt" "$AB_DIR/colmap_seq/sparse/"
cp "$WORK/$MESH"                       "$AB_DIR/colmap_seq/mesh.ply"

BASELINE_IMGS=$(grep -c '\.jpg' "$AB_DIR/baseline/sparse/images.txt")
COLMAP_IMGS=$(grep -c '\.jpg' "$AB_DIR/colmap_seq/sparse/images.txt")
echo "Baseline images: $BASELINE_IMGS"
echo "COLMAP images:   $COLMAP_IMGS"
echo ""

run_texture() {
  local NAME=$1
  local DIR="$AB_DIR/$NAME"

  echo "--- [$NAME] InterfaceCOLMAP ---"
  docker run --rm -v "$WORK:/work" $OPENMVS_IMG \
    InterfaceCOLMAP \
      -i "/work/ab_sequential/$NAME" \
      --image-folder /work/images \
      -o "/work/ab_sequential/$NAME/scene.mvs" \
      -w "/work/ab_sequential/$NAME"

  echo "--- [$NAME] TextureMesh ---"
  docker run --rm -v "$WORK:/work" $OPENMVS_IMG \
    TextureMesh \
      "/work/ab_sequential/$NAME/scene.mvs" \
      --mesh-file "/work/ab_sequential/$NAME/mesh.ply" \
      --export-type obj \
      -w "/work/ab_sequential/$NAME" \
      -o "/work/ab_sequential/$NAME/textured.mvs" \
      --resolution-level 1 \
      --cost-smoothness-ratio $SMOOTHNESS \
      --global-seam-leveling 0 \
      --local-seam-leveling 0

  # Fix MTL transparency bug
  local MTL="$DIR/textured.mtl"
  if [ -f "$MTL" ]; then
    chmod 644 "$MTL"
    sed -i '' 's/Tr 1\.000000/Tr 0.000000/' "$MTL"
  fi
  echo ""
}

run_texture "baseline"
run_texture "colmap_seq"

echo "=== A/B Test Complete ==="
echo ""
echo "Baseline:      $AB_DIR/baseline/textured.obj"
echo "COLMAP seq:    $AB_DIR/colmap_seq/textured.obj"
echo ""
echo "View:"
echo "  cd openmvs_work/ab_sequential && python3 -m http.server 8091"
echo "  open http://localhost:8091/compare_viewer.html"
