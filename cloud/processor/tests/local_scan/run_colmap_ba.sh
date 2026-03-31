#!/bin/bash
# COLMAP Bundle Adjustment pipeline for refining ARKit camera poses.
#
# Prerequisites: Docker Desktop running, prepare_openmvs_input.py already run
# Usage: cd tests/local_scan && bash run_colmap_ba.sh

set -e

WORK="$(cd "$(dirname "$0")/openmvs_work" && pwd)"
COLMAP_IMG="colmap/colmap:latest"
PLATFORM="--platform linux/amd64"

echo "Work dir: $WORK"
echo ""

# Clean previous BA artifacts
rm -f "$WORK/database.db"
rm -rf "$WORK/sparse_triangulated" "$WORK/sparse_refined"

# ============================================================
echo "=== Step 1: Feature Extraction ==="
# ============================================================
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

# ============================================================
echo "=== Step 2: Feature Matching (sequential, overlap=10) ==="
# ============================================================
docker run --rm $PLATFORM -m 6g -v "$WORK:/work" $COLMAP_IMG \
  colmap sequential_matcher \
    --database_path /work/database.db \
    --FeatureMatching.use_gpu 0 \
    --FeatureMatching.num_threads 2 \
    --SequentialMatching.overlap 10

echo ""

# ============================================================
echo "=== Step 3: Triangulate Points with ARKit Poses ==="
# ============================================================
mkdir -p "$WORK/sparse_triangulated"
docker run --rm $PLATFORM -m 6g -v "$WORK:/work" $COLMAP_IMG \
  colmap point_triangulator \
    --database_path /work/database.db \
    --image_path /work/images \
    --input_path /work/sparse \
    --output_path /work/sparse_triangulated

echo ""

# ============================================================
echo "=== Step 4: Bundle Adjustment (refine poses only) ==="
# ============================================================
mkdir -p "$WORK/sparse_refined"
docker run --rm $PLATFORM -m 6g -v "$WORK:/work" $COLMAP_IMG \
  colmap bundle_adjuster \
    --input_path /work/sparse_triangulated \
    --output_path /work/sparse_refined \
    --BundleAdjustment.refine_principal_point 0 \
    --BundleAdjustment.refine_focal_length 0 \
    --BundleAdjustment.refine_extra_params 0

echo ""
echo "=== Done ==="
echo "Refined poses: $WORK/sparse_refined/"
echo ""
echo "Next: run run_openmvs_refined.sh to texture with refined poses"
