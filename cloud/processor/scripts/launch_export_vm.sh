#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Launch a GCE spot VM, export RoomFormer to ONNX, download, tear down.
#
# Usage (from your Mac):
#   cd cloud/processor/scripts
#   bash launch_export_vm.sh
#
# Prerequisites:
#   - gcloud authenticated (gcloud auth login)
#   - Compute Engine API enabled on roomscanalpha project
#   - GPU quota in the selected zone (request at:
#     https://console.cloud.google.com/iam-admin/quotas?project=roomscanalpha)
#
# Cost: ~$0.50 (T4 spot instance for ~30 minutes)
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT="roomscanalpha"
INSTANCE="roomformer-export"
MACHINE="n1-standard-4"
GPU="nvidia-tesla-t4"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$(dirname "$SCRIPT_DIR")/models"

# Zones to try (in order) — T4s are widely available in these
ZONES=("us-central1-b" "us-central1-c" "us-central1-f" "us-east1-c" "us-west1-b" "europe-west4-a")

echo "=========================================="
echo "RoomFormer ONNX Export via GCE"
echo "=========================================="
echo "Project:  $PROJECT"
echo "Machine:  $MACHINE + $GPU"
echo "Output:   $OUTPUT_DIR/"
echo ""

# ── 1. Create the VM ──
echo "[1/5] Creating VM with T4 GPU..."
echo "      Trying multiple zones for availability..."

ZONE=""
for Z in "${ZONES[@]}"; do
    echo "      Trying $Z..."
    if gcloud compute instances create "$INSTANCE" \
        --project="$PROJECT" \
        --zone="$Z" \
        --machine-type="$MACHINE" \
        --accelerator="type=$GPU,count=1" \
        --image-family="pytorch-2-7-cu128-ubuntu-2204-nvidia-570" \
        --image-project="deeplearning-platform-release" \
        --boot-disk-size="100GB" \
        --provisioning-model="STANDARD" \
        --maintenance-policy="TERMINATE" \
        --scopes="default" \
        --metadata="install-nvidia-driver=True" \
        --quiet 2>/dev/null; then
        ZONE="$Z"
        echo "      VM created in $ZONE"
        break
    else
        echo "      $Z failed — trying next zone"
    fi
done

if [ -z "$ZONE" ]; then
    echo "ERROR: Could not create VM in any zone."
    echo "Check your GPU quota: https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT"
    echo "You need at least 1 NVIDIA_T4_GPUS in one of: ${ZONES[*]}"
    exit 1
fi

echo "      Waiting 60s for boot + GPU driver..."
sleep 60

# ── 2. Upload and run the export script ──
echo "[2/5] Running export script on VM..."
echo "      (This takes ~10-15 minutes: conda setup + build + export)"
echo ""

gcloud compute ssh "$INSTANCE" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --command="bash -s" \
    < "$SCRIPT_DIR/export_on_vm.sh" \
    2>&1 | tee /tmp/roomformer_export.log

echo ""
echo "[3/5] Export complete. Downloading model file..."

# ── 3. Download the result ──
mkdir -p "$OUTPUT_DIR"

# Try ONNX first, then TorchScript, then state_dict
DOWNLOADED=false
for REMOTE_FILE in "/tmp/roomformer_s3d.onnx" "/tmp/roomformer_s3d.pt" "/tmp/roomformer_patched.pth"; do
    LOCAL_FILE="$OUTPUT_DIR/$(basename $REMOTE_FILE)"
    if gcloud compute scp "$INSTANCE:$REMOTE_FILE" "$LOCAL_FILE" \
        --project="$PROJECT" --zone="$ZONE" 2>/dev/null; then
        SIZE=$(ls -lh "$LOCAL_FILE" | awk '{print $5}')
        echo "      Downloaded: $LOCAL_FILE ($SIZE)"
        DOWNLOADED=true
        break
    fi
done

if [ "$DOWNLOADED" = false ]; then
    echo "ERROR: No model file found on VM!"
    echo "Check the log: /tmp/roomformer_export.log"
fi

# ── 4. Tear down the VM ──
echo "[4/5] Deleting VM..."
gcloud compute instances delete "$INSTANCE" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --quiet

# ── 5. Summary ──
echo ""
echo "=========================================="
echo "[5/5] DONE"
echo "=========================================="
echo ""
echo "Export log:  /tmp/roomformer_export.log"
if [ "$DOWNLOADED" = true ]; then
    echo "Model file:  $LOCAL_FILE"
    echo ""
    echo "Next step: run the Step 4 inference wrapper tests"
else
    echo "No model downloaded — check the log for errors."
fi
