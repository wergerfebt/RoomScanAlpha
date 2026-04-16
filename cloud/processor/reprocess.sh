#!/bin/bash
# Reprocess a scan via the Cloud Run proxy.
#
# Usage:
#   ./reprocess.sh <rfq_id> <scan_id>
#   ./reprocess.sh d6751509-6076-439e-9d36-51c511aeb95f a6062d38-dc79-4975-ba03-9cc8e1fe86b5
#   ./reprocess.sh <rfq_id> all     # reprocess all scans for an RFQ

set -euo pipefail

REGION="us-central1"
SERVICE="scan-processor"
API_URL="https://scan-api-839349778883.us-central1.run.app"
PORT=9090

RFQ_ID="${1:?Usage: $0 <rfq_id> <scan_id|all>}"
SCAN_ID="${2:?Usage: $0 <rfq_id> <scan_id|all>}"

# Kill any existing proxy on our port
lsof -ti:${PORT} 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 1

# Start proxy in background
gcloud run services proxy "${SERVICE}" --region="${REGION}" --port="${PORT}" &
PROXY_PID=$!
trap "kill ${PROXY_PID} 2>/dev/null; wait ${PROXY_PID} 2>/dev/null" EXIT
sleep 6

# Verify proxy
if ! curl -sf http://localhost:${PORT}/health >/dev/null; then
    echo "ERROR: Proxy failed to start"
    exit 1
fi

reprocess_one() {
    local sid="$1"
    local base_path="scans/${RFQ_ID}/${sid}"
    local supp_gcs="gs://roomscanalpha-scans/${base_path}/supplemental_scan.zip"

    # Check if supplemental scan exists — route to merge endpoint if so
    if gsutil ls "${supp_gcs}" >/dev/null 2>&1; then
        echo "Reprocessing scan ${sid} (with supplemental merge)..."
        RESULT=$(curl -s --max-time 900 -X POST "http://localhost:${PORT}/process-supplemental" \
            -H "Content-Type: application/json" \
            -d "{\"scan_id\":\"${sid}\",\"rfq_id\":\"${RFQ_ID}\",\"original_blob_path\":\"${base_path}/scan.zip\",\"supplemental_blob_path\":\"${base_path}/supplemental_scan.zip\"}")
    else
        echo "Reprocessing scan ${sid}..."
        RESULT=$(curl -s --max-time 300 -X POST "http://localhost:${PORT}/process" \
            -H "Content-Type: application/json" \
            -d "{\"scan_id\":\"${sid}\",\"rfq_id\":\"${RFQ_ID}\",\"blob_path\":\"${base_path}/scan.zip\"}")
    fi
    echo "  ${RESULT}"
}

if [[ "${SCAN_ID}" == "all" ]]; then
    # Look up all scan IDs for this RFQ
    SCAN_IDS=$(curl -s "${API_URL}/api/rfqs/${RFQ_ID}/contractor-view" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for room in data.get('rooms', []):
    print(room['scan_id'])
")
    for sid in ${SCAN_IDS}; do
        reprocess_one "${sid}"
    done
else
    reprocess_one "${SCAN_ID}"
fi

echo "Done. View at: ${API_URL}/quote/${RFQ_ID}"
