"""
RoomScanAlpha REST API — Cloud Run service that handles scan uploads and status queries.

Provides endpoints for the iOS app to:
  - List and create RFQs (request-for-quote projects)
  - Obtain GCS signed URLs for direct scan package upload
  - Signal upload completion (enqueues Cloud Tasks processing job)
  - Poll scan processing status and retrieve room dimensions

Authentication: All endpoints require a Firebase Auth JWT in the Authorization header.
The scan processor is invoked via Cloud Tasks with OIDC tokens — not directly by clients.
"""

import os
import uuid
import json
import datetime
from typing import Optional

from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse, HTMLResponse
from google.cloud import storage, tasks_v2
from google.cloud.sql.connector import Connector
from google.auth import default as default_credentials, compute_engine
import google.auth.transport.requests
import pg8000
import firebase_admin
from firebase_admin import auth as firebase_auth

app = FastAPI(title="RoomScanAlpha API")

# --- Config ---
PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "roomscanalpha")
REGION = os.environ.get("GCP_REGION", "us-central1")
BUCKET_NAME = os.environ.get("GCS_BUCKET", "roomscanalpha-scans")
CLOUD_SQL_CONNECTION = os.environ.get("CLOUD_SQL_CONNECTION", "roomscanalpha:us-central1:roomscanalpha-db")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASS = os.environ.get("DB_PASS", "")
DB_NAME = os.environ.get("DB_NAME", "quoterra")
TASKS_QUEUE = os.environ.get("TASKS_QUEUE", "scan-processing")
PROCESSOR_URL = os.environ.get("PROCESSOR_URL", "")
# Service account used for IAM-based GCS signed URL generation
SIGNING_SA_EMAIL = os.environ.get("SIGNING_SA_EMAIL", "scan-api-sa@roomscanalpha.iam.gserviceaccount.com")
# Service account used by Cloud Tasks to invoke the processor via OIDC.
# This is the Compute Engine default SA for the GCP project.
TASKS_INVOKER_SA = os.environ.get("TASKS_INVOKER_SA", "839349778883-compute@developer.gserviceaccount.com")

# Signed upload URLs expire after this duration. 15 minutes gives the client enough time
# to zip and upload ~100MB on a typical connection, with margin for retries.
SIGNED_URL_EXPIRY_MINUTES = 15

# Maximum number of RFQs returned by list_rfqs. Keeps the response size bounded
# for the mobile client.
MAX_RFQS_PER_PAGE = 50

# --- Init ---
firebase_admin.initialize_app()
storage_client = storage.Client()
connector = Connector()

# Credential objects for IAM-based signed URL generation on Cloud Run.
# _credentials: ADC credentials used to obtain an access token for signing.
# _signing_credentials: IDTokenCredentials tied to SIGNING_SA_EMAIL (not used for signing
#   directly, but initialized here for potential OIDC flows).
# _auth_request: Transport request object used to refresh credentials.
_auth_request = google.auth.transport.requests.Request()
_credentials, _ = default_credentials()
_signing_credentials = compute_engine.IDTokenCredentials(
    _auth_request, "", service_account_email=SIGNING_SA_EMAIL
)


# --- Database ---

def get_db_connection() -> pg8000.Connection:
    """Open a connection to the Cloud SQL PostgreSQL instance via the Cloud SQL Connector."""
    return connector.connect(
        CLOUD_SQL_CONNECTION,
        "pg8000",
        user=DB_USER,
        password=DB_PASS,
        db=DB_NAME,
    )


def _row_to_dict(columns: list[str], row: tuple) -> dict:
    """Map a database row tuple to a dict using the given column names.

    This avoids brittle positional indexing — if the SELECT column order changes,
    only the column list here needs to be updated.
    """
    return dict(zip(columns, row))


# --- Auth ---

def verify_firebase_token(authorization: Optional[str]) -> dict:
    """Validate a Firebase Auth JWT from the Authorization header.

    Args:
        authorization: The raw "Bearer <token>" header value.

    Returns:
        Decoded token payload (contains uid, email, etc.).

    Raises:
        HTTPException 401: If the header is missing, malformed, or the token is invalid/expired.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
    token = authorization.replace("Bearer ", "")
    try:
        decoded = firebase_auth.verify_id_token(token)
        return decoded
    except Exception as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {str(e)}")


# --- Endpoints ---

@app.get("/api/rfqs")
def list_rfqs(authorization: str = Header(None)) -> dict:
    """List the most recent RFQs, ordered by creation date descending."""
    verify_firebase_token(authorization)

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            f"""SELECT id, description, status, created_at, address
                FROM rfqs ORDER BY created_at DESC LIMIT {MAX_RFQS_PER_PAGE}"""
        )
        rows = cursor.fetchall()
    finally:
        conn.close()

    columns = ["id", "description", "status", "created_at", "address"]
    return {
        "rfqs": [
            {
                **_row_to_dict(columns, row),
                "id": str(row[0]),
                "created_at": row[3].isoformat() if row[3] else None,
            }
            for row in rows
        ]
    }


@app.post("/api/rfqs")
async def create_rfq(request: Request, authorization: str = Header(None)) -> dict:
    """Create a new RFQ (request-for-quote project) to associate scans with."""
    verify_firebase_token(authorization)

    body = await request.json()
    description = body.get("description", "")
    address = body.get("address", None)
    rfq_id = str(uuid.uuid4())

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """INSERT INTO rfqs (id, description, address, status, created_at) VALUES (%s, %s, %s, 'scan_pending', NOW())""",
            (rfq_id, description, address),
        )
        conn.commit()
    finally:
        conn.close()

    return {"id": rfq_id, "description": description, "address": address, "status": "scan_pending"}


@app.get("/api/rfqs/{rfq_id}/scans/upload-url")
def get_upload_url(rfq_id: str, authorization: str = Header(None)) -> dict:
    """Generate a GCS signed URL for the client to upload a scan zip directly to Cloud Storage.

    The signed URL bypasses Cloud Run's 32MB request size limit by letting the client
    PUT the ~75MB scan zip directly to GCS. The URL expires after SIGNED_URL_EXPIRY_MINUTES.
    """
    verify_firebase_token(authorization)

    scan_id = str(uuid.uuid4())
    blob_path = f"scans/{rfq_id}/{scan_id}/scan.zip"

    # Ensure ADC credentials have a valid access token for IAM-based signing.
    # Tokens expire periodically; refresh if missing or expired.
    if not _credentials.token or not _credentials.valid:
        _credentials.refresh(_auth_request)

    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(blob_path)
    signed_url = blob.generate_signed_url(
        version="v4",
        expiration=datetime.timedelta(minutes=SIGNED_URL_EXPIRY_MINUTES),
        method="PUT",
        content_type="application/zip",
        service_account_email=SIGNING_SA_EMAIL,
        access_token=_credentials.token,
    )

    return {
        "signed_url": signed_url,
        "scan_id": scan_id,
        "blob_path": blob_path,
    }


@app.post("/api/rfqs/{rfq_id}/scans/complete")
async def upload_complete(rfq_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Signal that a scan upload to GCS is complete. Inserts a DB row and enqueues processing.

    This endpoint:
      1. Creates a scanned_rooms row with status='processing'.
      2. Enqueues a Cloud Tasks job to invoke the scan processor with an OIDC token.
         The OIDC token ensures only authorized Cloud Tasks calls can reach the processor
         (which is deployed with --no-allow-unauthenticated).
    """
    verify_firebase_token(authorization)

    body = await request.json()
    scan_id = body.get("scan_id")
    if not scan_id:
        raise HTTPException(status_code=400, detail="scan_id required")

    blob_path = f"scans/{rfq_id}/{scan_id}/scan.zip"

    # Insert initial scan record
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """INSERT INTO scanned_rooms (id, rfq_id, scan_status, scan_mesh_url, created_at)
               VALUES (%s, %s, 'processing', %s, NOW())""",
            (scan_id, rfq_id, blob_path),
        )
        conn.commit()
    finally:
        conn.close()

    # Enqueue async processing via Cloud Tasks
    _enqueue_processing_task(scan_id, rfq_id, blob_path)

    return {"scan_id": scan_id, "status": "queued"}


def _enqueue_processing_task(scan_id: str, rfq_id: str, blob_path: str) -> None:
    """Enqueue a Cloud Tasks job to process the uploaded scan.

    Uses OIDC authentication so only Cloud Tasks (not arbitrary callers) can invoke
    the processor service. Non-fatal on failure — logged as a warning.
    """
    try:
        tasks_client = tasks_v2.CloudTasksClient()
        queue_path = tasks_client.queue_path(PROJECT_ID, REGION, TASKS_QUEUE)

        task_payload = json.dumps({
            "scan_id": scan_id,
            "rfq_id": rfq_id,
            "blob_path": blob_path,
        })

        task = tasks_v2.Task(
            http_request=tasks_v2.HttpRequest(
                http_method=tasks_v2.HttpMethod.POST,
                url=f"{PROCESSOR_URL}/process",
                headers={"Content-Type": "application/json"},
                body=task_payload.encode(),
                oidc_token=tasks_v2.OidcToken(
                    service_account_email=TASKS_INVOKER_SA,
                ),
            ),
        )

        tasks_client.create_task(parent=queue_path, task=task)
        print(f"[API] Enqueued processing task for scan {scan_id}")
    except Exception as e:
        print(f"[API] Warning: Failed to enqueue task: {e}")


@app.get("/api/rfqs/{rfq_id}/scans/{scan_id}/status")
def get_scan_status(rfq_id: str, scan_id: str, authorization: str = Header(None)) -> dict:
    """Return the current processing status and room dimensions for a scan.

    Possible room-level status values (SCANNED_ROOMS.scan_status):
      - "processing": Cloud processor is still working on this scan.
      - "complete": Processing succeeded; room dimensions and components are populated.
      - "failed": Processing failed; detected_components contains an error description.

    Note: The RFQ-level status (rfqs.status) transitions to "scan_ready" only when
    ALL scanned_rooms rows for the RFQ reach "complete". The iOS app polls for
    room-level "complete" status on this endpoint.
    """
    verify_firebase_token(authorization)

    columns = [
        "scan_status", "floor_area_sqft", "wall_area_sqft", "ceiling_height_ft",
        "perimeter_linear_ft", "detected_components", "scan_dimensions",
        "room_polygon_ft", "wall_heights_ft", "polygon_source", "scan_mesh_url",
        "scope",
    ]

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            f"""SELECT {', '.join(columns)}
                FROM scanned_rooms WHERE id = %s AND rfq_id = %s AND scan_status != 'deleted'""",
            (scan_id, rfq_id),
        )
        row = cursor.fetchone()
    finally:
        conn.close()

    if not row:
        raise HTTPException(status_code=404, detail="Scan not found")

    result = _row_to_dict(columns, row)
    result["scan_id"] = scan_id
    result["status"] = result.pop("scan_status")

    # Generate a signed URL for the PLY mesh if a GCS path is stored
    mesh_gcs_path = result.pop("scan_mesh_url", None)
    if mesh_gcs_path:
        try:
            if not _credentials.token or not _credentials.valid:
                _credentials.refresh(_auth_request)
            bucket = storage_client.bucket(BUCKET_NAME)
            blob = bucket.blob(mesh_gcs_path)
            result["scan_mesh_url"] = blob.generate_signed_url(
                version="v4",
                expiration=datetime.timedelta(days=7),
                method="GET",
                service_account_email=SIGNING_SA_EMAIL,
                access_token=_credentials.token,
            )
        except Exception:
            result["scan_mesh_url"] = None
    else:
        result["scan_mesh_url"] = None

    return result


@app.delete("/api/rfqs/{rfq_id}/scans/{scan_id}")
def delete_scan(rfq_id: str, scan_id: str, authorization: str = Header(None)) -> dict:
    """Soft-delete a scan by setting its status to 'deleted'.

    The row and GCS blobs are preserved (storage is cheap; data may be useful
    for future model training). The GET status endpoint returns 404 for deleted scans.
    """
    verify_firebase_token(authorization)

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """UPDATE scanned_rooms
               SET scan_status = 'deleted'
               WHERE id = %s AND rfq_id = %s AND scan_status != 'deleted'""",
            (scan_id, rfq_id),
        )
        conn.commit()
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Scan not found")
    finally:
        conn.close()

    return {"status": "deleted", "scan_id": scan_id}


@app.put("/api/rfqs/{rfq_id}/scans/{scan_id}/scope")
async def update_scan_scope(rfq_id: str, scan_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Update the scope of work items for a scanned room."""
    verify_firebase_token(authorization)

    body = await request.json()
    scope_data = json.dumps({"items": body.get("items", []), "notes": body.get("notes", "")})

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """UPDATE scanned_rooms SET scope = %s
               WHERE id = %s AND rfq_id = %s AND scan_status != 'deleted'""",
            (scope_data, scan_id, rfq_id),
        )
        conn.commit()
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Scan not found")
    finally:
        conn.close()

    return {"status": "ok", "scan_id": scan_id}


@app.get("/api/rfqs/{rfq_id}/contractor-view")
def contractor_view(rfq_id: str) -> dict:
    """Return all scan data for a contractor to review and quote.

    No auth required — link-based access for alpha. The link URL is the auth token
    (security by obscurity is acceptable for the 1-month pilot).
    """
    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        # Fetch RFQ info
        cursor.execute(
            """SELECT description, status FROM rfqs WHERE id = %s""",
            (rfq_id,),
        )
        rfq_row = cursor.fetchone()
        if not rfq_row:
            raise HTTPException(status_code=404, detail="RFQ not found")

        description, rfq_status = rfq_row

        # Try to fetch property address if the table exists
        address = None
        try:
            cursor.execute(
                """SELECT p.address_line1, p.city, p.state, p.zip
                   FROM properties p
                   JOIN rfqs r ON r.property_id = p.id
                   WHERE r.id = %s""",
                (rfq_id,),
            )
            addr_row = cursor.fetchone()
            if addr_row:
                address_parts = [p for p in addr_row if p]
                address = ", ".join(address_parts) if address_parts else None
        except Exception:
            conn.rollback()  # reset transaction state after failed query

        # Fetch all non-deleted scanned rooms for this RFQ
        room_columns = [
            "id", "room_label", "floor_area_sqft", "wall_area_sqft",
            "ceiling_height_ft", "perimeter_linear_ft",
            "room_polygon_ft", "wall_heights_ft", "polygon_source",
            "detected_components", "scan_mesh_url", "scan_status",
            "texture_manifest", "scope",
        ]
        cursor.execute(
            f"""SELECT {', '.join(room_columns)}
                FROM scanned_rooms
                WHERE rfq_id = %s AND scan_status != 'deleted'
                ORDER BY created_at""",
            (rfq_id,),
        )
        room_rows = cursor.fetchall()
    finally:
        conn.close()

    rooms = []
    for row in room_rows:
        room = _row_to_dict(room_columns, row)
        room["scan_id"] = room.pop("id")

        # Generate signed mesh URL if GCS path is stored
        mesh_gcs_path = room.pop("scan_mesh_url", None)
        if mesh_gcs_path:
            try:
                if not _credentials.token or not _credentials.valid:
                    _credentials.refresh(_auth_request)
                bucket = storage_client.bucket(BUCKET_NAME)
                blob = bucket.blob(mesh_gcs_path)
                room["mesh_url"] = blob.generate_signed_url(
                    version="v4",
                    expiration=datetime.timedelta(days=7),
                    method="GET",
                    service_account_email=SIGNING_SA_EMAIL,
                    access_token=_credentials.token,
                )
            except Exception:
                room["mesh_url"] = None
        else:
            room["mesh_url"] = None

        # Generate signed URLs for texture files
        tex_manifest = room.pop("texture_manifest", None)
        if tex_manifest and isinstance(tex_manifest, dict) and mesh_gcs_path:
            gcs_base = mesh_gcs_path.rsplit("/", 1)[0]  # scans/{rfq_id}/{scan_id}
            texture_urls = {}
            for surface_id, rel_path in tex_manifest.items():
                try:
                    tex_blob = bucket.blob(f"{gcs_base}/{rel_path}")
                    texture_urls[surface_id] = tex_blob.generate_signed_url(
                        version="v4",
                        expiration=datetime.timedelta(days=7),
                        method="GET",
                        service_account_email=SIGNING_SA_EMAIL,
                        access_token=_credentials.token,
                    )
                except Exception:
                    texture_urls[surface_id] = None
            room["texture_urls"] = texture_urls
        else:
            room["texture_urls"] = None

        rooms.append(room)

    return {
        "rfq_id": rfq_id,
        "address": address,
        "job_description": description,
        "status": rfq_status,
        "rooms": rooms,
    }


@app.get("/quote/{rfq_id}", response_class=HTMLResponse)
def serve_contractor_page(rfq_id: str) -> str:
    """Serve the contractor view HTML page.

    The page loads data from /api/rfqs/{rfq_id}/contractor-view via fetch().
    No auth — the unique URL is the access token for alpha.
    """
    html_path = Path(__file__).parent / "web" / "contractor_view.html"
    if not html_path.exists():
        raise HTTPException(status_code=500, detail="Contractor view page not found")
    return html_path.read_text()


@app.get("/health")
def health() -> dict:
    """Health check endpoint for Cloud Run readiness/liveness probes."""
    return {"status": "ok"}
