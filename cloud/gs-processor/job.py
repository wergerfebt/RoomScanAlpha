"""
gs-processor job: Runs the GS pipeline as a Vertex AI Custom Job.

Reads SCAN_ID, ROOM_ID, RFQ_ID from environment variables,
runs the full pipeline, uploads .splat to GCS, then exits.
"""

import os
import sys
import time
import traceback

from google.cloud import storage


def main():
    scan_id = os.environ.get('SCAN_ID')
    room_id = os.environ.get('ROOM_ID')
    rfq_id = os.environ.get('RFQ_ID', scan_id)

    if not scan_id or not room_id:
        print('[gs-processor] ERROR: SCAN_ID and ROOM_ID env vars required', flush=True)
        sys.exit(1)

    print(f'[gs-processor] Starting pipeline for scan={scan_id[:8]}... room={room_id[:8]}...', flush=True)
    t0 = time.time()

    try:
        from run_pipeline import (
            pull_and_extract, run_sfm, patch_fastgs, train_fastgs,
            export_splat, align_splat_to_arkit
        )

        # Step 1: Pull + extract
        scan_dir, data_path, img_dir = pull_and_extract(scan_id, room_id, stride=4)

        # Step 2: SfM
        result = run_sfm(scan_dir, data_path, img_dir)
        if result is None:
            print('[gs-processor] SfM failed', flush=True)
            sys.exit(1)
        data_path, name_to_pos = result

        # Step 3: Train
        patch_fastgs()
        output_dir = train_fastgs(data_path, iterations=30000)

        # Step 4: Export
        splat_path = export_splat(output_dir)

        # Step 5: Align to ARKit
        aligned_path = align_splat_to_arkit(splat_path, data_path, name_to_pos)

        # Step 6: Upload to GCS
        bucket_name = 'roomscanalpha-scans'
        blob_name = f'scans/{rfq_id}/{room_id}/room_scan.splat'
        storage.Client().bucket(bucket_name).blob(blob_name).upload_from_filename(aligned_path)
        gcs_path = f'gs://{bucket_name}/{blob_name}'

        elapsed = time.time() - t0
        print(f'[gs-processor] Done in {elapsed:.0f}s ({elapsed/60:.1f} min)', flush=True)
        print(f'[gs-processor] Uploaded to {gcs_path}', flush=True)

    except Exception as e:
        print(f'[gs-processor] FAILED: {e}', flush=True)
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()
