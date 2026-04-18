"""
Submit a Gaussian Splatting job to Vertex AI.

Usage:
    python submit_job.py --scan_id SCAN_ID --room_id ROOM_ID [--rfq_id RFQ_ID]

Can be called from scan-processor after mesh processing completes,
or manually for reprocessing.
"""

import argparse
import time
from google.cloud import aiplatform


PROJECT_ID = 'roomscanalpha'
REGION = 'us-central1'
IMAGE_URI = f'{REGION}-docker.pkg.dev/{PROJECT_ID}/gs-pipeline/gs-processor:latest'
MACHINE_TYPE = 'g2-standard-8'  # 8 vCPU, 32GB RAM, 1x L4 GPU
ACCELERATOR_TYPE = 'NVIDIA_L4'
ACCELERATOR_COUNT = 1


def submit_gs_job(scan_id: str, room_id: str, rfq_id: str = None) -> str:
    """Submit a Vertex AI Custom Job for Gaussian Splatting.

    Returns the job resource name.
    """
    aiplatform.init(
        project=PROJECT_ID,
        location=REGION,
        staging_bucket='gs://roomscanalpha-scans',
    )

    job_name = f'gs-{scan_id[:8]}-{int(time.time())}'

    job = aiplatform.CustomJob(
        display_name=job_name,
        worker_pool_specs=[{
            'machine_spec': {
                'machine_type': MACHINE_TYPE,
                'accelerator_type': ACCELERATOR_TYPE,
                'accelerator_count': ACCELERATOR_COUNT,
            },
            'replica_count': 1,
            'container_spec': {
                'image_uri': IMAGE_URI,
                'env': [
                    {'name': 'SCAN_ID', 'value': scan_id},
                    {'name': 'ROOM_ID', 'value': room_id},
                    {'name': 'RFQ_ID', 'value': rfq_id or scan_id},
                ],
            },
        }],
    )

    # Submit async (don't wait for completion)
    job.submit()
    print(f'Submitted job: {job.resource_name}')
    print(f'Monitor: https://console.cloud.google.com/vertex-ai/training/custom-jobs?project={PROJECT_ID}')
    return job.resource_name


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--scan_id', required=True)
    parser.add_argument('--room_id', required=True)
    parser.add_argument('--rfq_id', default=None)
    args = parser.parse_args()

    submit_gs_job(args.scan_id, args.room_id, args.rfq_id)
