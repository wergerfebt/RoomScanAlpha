#!/bin/bash
# Fast deploy for scan-processor to Cloud Run.
#
# Usage:
#   ./deploy.sh              # build + deploy
#   ./deploy.sh --deploy-only  # skip build, just deploy latest image
#
# Uses local Docker build with layer caching when Docker is running.
# Falls back to gcloud builds submit (remote, slower) otherwise.
#
# Image is amd64 (Ubuntu 24.04 base with OpenMVS built from source).

set -euo pipefail

PROJECT="roomscanalpha"
REGION="us-central1"
SERVICE="scan-processor"
REPO="us-central1-docker.pkg.dev/${PROJECT}/cloud-run-source-deploy"
IMAGE="${REPO}/${SERVICE}"
MEMORY="8Gi"
CPU="4"
TIMEOUT="300"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$SCRIPT_DIR"

# --- Build ---
if [[ "${1:-}" != "--deploy-only" ]]; then
    echo "=== Building scan-processor (amd64) ==="

    if docker info &>/dev/null; then
        # Local Docker available — use layer caching (fast for code-only changes)
        echo "Using local Docker build (layer cached)..."
        gcloud auth configure-docker us-central1-docker.pkg.dev --quiet 2>/dev/null

        # Build for linux/amd64 (Cloud Run target) — cross-compile on Apple Silicon
        docker build --platform linux/amd64 -t "${IMAGE}:latest" .

        echo "Pushing image..."
        docker push "${IMAGE}:latest"
    else
        # No local Docker — use Cloud Build (slower, no layer cache)
        echo "Docker not running, using Cloud Build (slower)..."
        gcloud builds submit \
            --tag "${IMAGE}:latest" \
            --project "${PROJECT}" \
            --quiet
    fi
    echo "=== Build complete ==="
fi

# --- Deploy ---
echo "=== Deploying to Cloud Run (amd64, ${MEMORY} RAM, ${CPU} CPU) ==="
gcloud run deploy "${SERVICE}" \
    --image "${IMAGE}:latest" \
    --region "${REGION}" \
    --no-allow-unauthenticated \
    --memory "${MEMORY}" \
    --cpu "${CPU}" \
    --timeout "${TIMEOUT}" \
    --quiet

echo "=== Done ==="
gcloud run services describe "${SERVICE}" --region "${REGION}" --format='value(status.url)'
