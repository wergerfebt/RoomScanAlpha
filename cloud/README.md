# RoomScanAlpha Cloud Services

Two Cloud Run services that process uploaded room scans and serve the REST API for the iOS app.

## Architecture

```
iOS App → REST API (Cloud Run) → GCS (signed URL upload)
                                → Cloud Tasks → Scan Processor (Cloud Run)
                                                      ↓
                                                Cloud SQL (PostgreSQL)
```

- **API** (`api/`): Handles authentication, signed URL generation, upload completion, and status polling.
- **Processor** (`processor/`): Downloads scan packages from GCS, validates structure, parses PLY mesh, computes room dimensions, and writes results to the database.

## Prerequisites

- Google Cloud SDK (`gcloud`) authenticated to the `roomscanalpha` project
- Python 3.12+
- PostgreSQL client (for local schema setup)
- Firebase project configured (for auth token validation)

## Local Development

### API Service

```bash
cd api
pip install -r requirements.txt

# Set required environment variables
export GCP_PROJECT_ID=roomscanalpha
export GCS_BUCKET=roomscanalpha-scans
export CLOUD_SQL_CONNECTION=roomscanalpha:us-central1:roomscanalpha-db
export DB_USER=postgres
export DB_PASS=<password>
export DB_NAME=quoterra
export TASKS_QUEUE=scan-processing
export PROCESSOR_URL=https://scan-processor-....run.app
export SIGNING_SA_EMAIL=scan-api-sa@roomscanalpha.iam.gserviceaccount.com

# Run locally (requires Cloud SQL Proxy for DB access)
uvicorn main:app --reload --port 8080
```

### Processor Service

```bash
cd processor
pip install -r requirements.txt

# Set required environment variables (same DB vars as API)
export GCP_PROJECT_ID=roomscanalpha
export GCS_BUCKET=roomscanalpha-scans
export CLOUD_SQL_CONNECTION=roomscanalpha:us-central1:roomscanalpha-db
export DB_USER=postgres
export DB_PASS=<password>
export DB_NAME=quoterra

uvicorn main:app --reload --port 8081
```

### Database Setup

```bash
# Apply the schema to a local or Cloud SQL PostgreSQL instance
psql -h <host> -U postgres -d quoterra -f schema.sql
```

## Deploying

```bash
# API
gcloud run deploy scan-api \
  --source=api/ \
  --region=us-central1 \
  --allow-unauthenticated

# Processor (OIDC-protected — only Cloud Tasks can invoke it)
gcloud run deploy scan-processor \
  --source=processor/ \
  --region=us-central1 \
  --no-allow-unauthenticated
```

## Unit Convention

- **Input geometry** (PLY vertices, bounding box): meters (ARKit's native unit)
- **Output room dimensions** (floor_area, wall_area, ceiling_height, perimeter): imperial (sq ft / ft)
- Conversion happens once at the output boundary in `compute_room_metrics()` — never mix units in storage or transit

## Key Files

| File | Purpose |
|------|---------|
| `api/main.py` | REST API: auth, signed URLs, upload-complete, status polling |
| `processor/main.py` | Scan processor: PLY parsing, room metrics, DB writes |
| `schema.sql` | PostgreSQL schema for `rfqs` and `scanned_rooms` tables |
