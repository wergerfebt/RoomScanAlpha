"""
gs-processor: Gaussian Splatting pipeline for Cloud Run GPU.

Receives scan processing requests via HTTP (from Cloud Tasks),
runs the ALIKED + GLOMAP + FastGS pipeline, and uploads the
resulting .splat file to GCS.
"""

import json
import os
import sys
import traceback
from http.server import HTTPServer, BaseHTTPRequestHandler

# Pipeline imports are deferred to avoid slow startup for health checks


PORT = int(os.environ.get('PORT', 8080))
GCS_BUCKET = os.environ.get('GCS_BUCKET', 'gs://roomscanalpha-scans')


class Handler(BaseHTTPRequestHandler):

    def do_GET(self):
        """Health check."""
        if self.path == '/health' or self.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'ok', 'service': 'gs-processor'}).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        """Process a scan — expects JSON body with scan_id and room_id."""
        if self.path != '/process':
            self.send_response(404)
            self.end_headers()
            return

        # Read request body
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body) if body else {}
            scan_id = data.get('scan_id')
            room_id = data.get('room_id')
            rfq_id = data.get('rfq_id')

            if not scan_id or not room_id:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'error': 'Missing scan_id or room_id'
                }).encode())
                return

            # Respond immediately (Cloud Tasks expects 2xx within timeout)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'status': 'processing',
                'scan_id': scan_id,
                'room_id': room_id,
            }).encode())

            # Run pipeline in-process (Cloud Run handles concurrency=1)
            print(f'[gs-processor] Starting pipeline for scan={scan_id[:8]}... room={room_id[:8]}...',
                  flush=True)

            from run_pipeline import pull_and_extract, run_sfm, patch_fastgs, train_fastgs, \
                export_splat, align_splat_to_arkit
            import time
            import subprocess

            t0 = time.time()

            # Configure paths
            os.environ['SCAN_ID'] = scan_id
            os.environ['ROOM_ID'] = room_id

            # Step 1: Pull + extract
            scan_dir, data_path, img_dir = pull_and_extract(scan_id, room_id, stride=4)

            # Step 2: SfM
            result = run_sfm(scan_dir, data_path, img_dir)
            if result is None:
                print('[gs-processor] SfM failed', flush=True)
                return
            data_path, name_to_pos = result

            # Step 3: Train
            patch_fastgs()
            output_dir = train_fastgs(data_path, iterations=30000)

            # Step 4: Export
            splat_path = export_splat(output_dir)

            # Step 5: Align to ARKit
            aligned_path = align_splat_to_arkit(splat_path, data_path, name_to_pos)

            # Step 6: Upload to GCS
            gcs_path = f'{GCS_BUCKET}/scans/{rfq_id or scan_id}/{room_id}/room_scan.splat'
            subprocess.run(f'gsutil cp {aligned_path} {gcs_path}', shell=True, check=True)

            elapsed = time.time() - t0
            print(f'[gs-processor] Done in {elapsed:.0f}s — uploaded to {gcs_path}', flush=True)

        except Exception as e:
            print(f'[gs-processor] Error: {e}', flush=True)
            traceback.print_exc()


def main():
    server = HTTPServer(('0.0.0.0', PORT), Handler)
    print(f'[gs-processor] Listening on port {PORT}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
