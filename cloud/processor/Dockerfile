# Use the original working container as base (has OpenMVS binaries + all dependencies).
# Pinned by digest to avoid :latest being overwritten by broken builds.
FROM us-central1-docker.pkg.dev/roomscanalpha/cloud-run-source-deploy/scan-processor@sha256:1c33750e703dc3760eb26ee9585010e6b282d8ce11e4bf9aa06b46419abcd6a9

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Update Python dependencies (adds trimesh, embreex if missing)
COPY requirements.txt .
RUN pip install --no-cache-dir --break-system-packages -r requirements.txt

# Update application code (overwrites old versions)
COPY main.py .
COPY pipeline/ pipeline/

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
