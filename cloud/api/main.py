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
import urllib.parse
import urllib.request
from typing import Optional

from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request, UploadFile, File, Form
from fastapi.responses import JSONResponse, HTMLResponse, FileResponse, Response
from fastapi.staticfiles import StaticFiles
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
# Admin UID allowlist for the annotation tool (comma-separated Firebase UIDs)
ADMIN_UIDS = set(filter(None, os.environ.get("ADMIN_UIDS", "").split(",")))

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
    """List the current user's most recent RFQs, ordered by creation date descending."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        # Look up the user's account id (if any) so we can include RFQs that
        # are owned via homeowner_account_id (not just the legacy user_id).
        cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (uid,))
        acct_row = cursor.fetchone()
        account_id = acct_row[0] if acct_row else None

        cursor.execute(
            f"""SELECT r.id, r.title, r.description, r.status, r.created_at, r.address,
                       r.bid_view_token,
                       (SELECT count(*) FROM scanned_rooms sr WHERE sr.rfq_id = r.id) AS scan_count,
                       (SELECT count(*) FROM bids b WHERE b.rfq_id = r.id) AS bid_count
                FROM rfqs r
                WHERE r.deleted_at IS NULL
                  AND (r.user_id = %s OR (%s::uuid IS NOT NULL AND r.homeowner_account_id = %s::uuid))
                ORDER BY r.created_at DESC
                LIMIT {MAX_RFQS_PER_PAGE}""",
            (uid, account_id, account_id),
        )
        rows = cursor.fetchall()
    finally:
        conn.close()

    return {
        "rfqs": [
            {
                "id": str(row[0]),
                "title": row[1],
                "description": row[2],
                "status": row[3],
                "created_at": row[4].isoformat() if row[4] else None,
                "address": row[5],
                "bid_view_token": row[6],
                "scan_count": row[7],
                "bid_count": row[8],
            }
            for row in rows
        ]
    }


@app.post("/api/rfqs")
async def create_rfq(request: Request, authorization: str = Header(None)) -> dict:
    """Create a new RFQ (request-for-quote project) to associate scans with."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]

    body = await request.json()
    title = body.get("title", "")
    description = body.get("description", "")
    address = body.get("address", "")
    rfq_id = str(uuid.uuid4())

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """INSERT INTO rfqs (id, title, description, address, status, user_id, created_at) VALUES (%s, %s, %s, %s, 'scan_pending', %s, NOW())""",
            (rfq_id, title, description, address or None, uid),
        )
        conn.commit()
    finally:
        conn.close()

    return {"id": rfq_id, "title": title, "description": description, "address": address, "status": "scan_pending"}


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
            """INSERT INTO scanned_rooms (id, rfq_id, room_label, scan_status, scan_mesh_url, created_at)
               VALUES (%s, %s, %s, 'processing', %s, NOW())""",
            (scan_id, rfq_id, body.get("room_label", ""), blob_path),
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
      - "metrics_ready": Room dimensions + fast coverage available; texturing still running.
      - "complete": Texturing succeeded; accurate UV-based coverage available via /coverage.
      - "failed": Processing failed; detected_components contains an error description.

    The iOS app polls this endpoint. It should treat "metrics_ready" as actionable
    (show dimensions + fast coverage) and continue polling until "complete".
    """
    verify_firebase_token(authorization)

    columns = [
        "scan_status", "floor_area_sqft", "wall_area_sqft", "ceiling_height_ft",
        "perimeter_linear_ft", "detected_components", "scan_dimensions",
        "room_polygon_ft", "wall_heights_ft", "polygon_source", "scan_mesh_url",
        "fast_coverage", "coverage",
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


@app.post("/api/rfqs/{rfq_id}/scans/{scan_id}/coverage")
async def check_coverage(rfq_id: str, scan_id: str, authorization: str = Header(None)) -> dict:
    """Check texture coverage by calling the processor's /coverage endpoint.

    Proxies the request to the OIDC-protected scan-processor service.
    The processor decimates the mesh to 10K faces and checks per-face camera viability.
    Returns uncovered face centroids + normals for AR overlay on the iOS app.
    """
    verify_firebase_token(authorization)

    # Look up the blob path for this scan
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT scan_mesh_url FROM scanned_rooms WHERE id = %s AND rfq_id = %s",
            (scan_id, rfq_id),
        )
        row = cursor.fetchone()
    finally:
        conn.close()

    if not row or not row[0]:
        raise HTTPException(status_code=404, detail="Scan not found or not yet uploaded")

    # Derive blob_path from scan_mesh_url (scans/{rfq_id}/{scan_id}/mesh.ply → scans/{rfq_id}/{scan_id}/scan.zip)
    mesh_path = row[0]
    blob_path = mesh_path.rsplit("/", 1)[0] + "/scan.zip"

    # Call processor /coverage endpoint with OIDC auth
    import requests as http_requests
    try:
        if not _credentials.token or not _credentials.valid:
            _credentials.refresh(_auth_request)

        # Get OIDC token for processor
        from google.oauth2 import id_token as google_id_token
        import google.auth.transport.requests as google_transport
        oidc_request = google_transport.Request()
        token = google_id_token.fetch_id_token(oidc_request, PROCESSOR_URL)

        resp = http_requests.post(
            f"{PROCESSOR_URL}/coverage",
            json={"scan_id": scan_id, "rfq_id": rfq_id, "blob_path": blob_path},
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            timeout=60,
        )
        resp.raise_for_status()
        return resp.json()
    except Exception as e:
        print(f"[API] Coverage check failed: {e}")
        raise HTTPException(status_code=502, detail=f"Coverage check failed: {str(e)}")


@app.get("/api/rfqs/{rfq_id}/scans/{scan_id}/supplemental-upload-url")
def get_supplemental_upload_url(rfq_id: str, scan_id: str, authorization: str = Header(None)) -> dict:
    """Generate a GCS signed URL for uploading a supplemental scan zip.

    Follows the same pattern as get_upload_url but writes to
    scans/{rfq_id}/{scan_id}/supplemental_scan.zip alongside the original.
    """
    verify_firebase_token(authorization)

    blob_path = f"scans/{rfq_id}/{scan_id}/supplemental_scan.zip"

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
        "blob_path": blob_path,
    }


@app.post("/api/rfqs/{rfq_id}/scans/{scan_id}/supplemental")
async def supplemental_complete(rfq_id: str, scan_id: str,
                                request: Request, authorization: str = Header(None)) -> dict:
    """Signal that a supplemental scan upload is complete. Enqueues merge + reprocess.

    Updates scan status to 'processing' and enqueues a Cloud Task to the processor's
    /process-supplemental endpoint, which will merge meshes, merge frames, and re-texture.
    """
    verify_firebase_token(authorization)

    original_blob = f"scans/{rfq_id}/{scan_id}/scan.zip"
    supplemental_blob = f"scans/{rfq_id}/{scan_id}/supplemental_scan.zip"

    # Update scan status to processing
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            "UPDATE scanned_rooms SET scan_status = 'processing' WHERE id = %s AND rfq_id = %s",
            (scan_id, rfq_id),
        )
        conn.commit()
    finally:
        conn.close()

    # Enqueue supplemental processing via Cloud Tasks
    try:
        tasks_client = tasks_v2.CloudTasksClient()
        queue_path = tasks_client.queue_path(PROJECT_ID, REGION, TASKS_QUEUE)

        task_payload = json.dumps({
            "scan_id": scan_id,
            "rfq_id": rfq_id,
            "original_blob_path": original_blob,
            "supplemental_blob_path": supplemental_blob,
        })

        task = tasks_v2.Task(
            http_request=tasks_v2.HttpRequest(
                http_method=tasks_v2.HttpMethod.POST,
                url=f"{PROCESSOR_URL}/process-supplemental",
                headers={"Content-Type": "application/json"},
                body=task_payload.encode(),
                oidc_token=tasks_v2.OidcToken(
                    service_account_email=TASKS_INVOKER_SA,
                ),
            ),
        )

        tasks_client.create_task(parent=queue_path, task=task)
        print(f"[API] Enqueued supplemental processing for scan {scan_id}")
    except Exception as e:
        print(f"[API] Warning: Failed to enqueue supplemental task: {e}")

    return {"scan_id": scan_id, "status": "processing"}


@app.get("/api/rfqs/{rfq_id}/scans/{scan_id}/files/{filepath:path}")
def get_scan_file(rfq_id: str, scan_id: str, filepath: str):
    """Proxy GCS scan files by path. Used by the viewer for OBJ/MTL/atlas loading.

    Supports paths like:
      textured.obj              → scans/{rfq_id}/{scan_id}/textured.obj
      standard/textured.obj     → scans/{rfq_id}/{scan_id}/standard_textured.obj
      standard/textured.mtl     → scans/{rfq_id}/{scan_id}/standard_textured.mtl
      standard/textured_material_00_map_Kd.jpg → standard_textured_material_00_map_Kd.jpg
    """
    ALLOWED_EXTENSIONS = {".obj", ".mtl", ".jpg", ".jpeg", ".png", ".ply", ".splat"}
    CONTENT_TYPES = {
        ".obj": "text/plain",
        ".mtl": "text/plain",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".ply": "application/octet-stream",
        ".splat": "application/octet-stream",
    }

    ext = os.path.splitext(filepath)[1].lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400, detail="File type not allowed")

    # Map viewer path to GCS blob path
    # "standard/textured.obj" → "standard_textured.obj" in GCS (legacy naming)
    if filepath.startswith("standard/"):
        gcs_filename = "standard_" + filepath[len("standard/"):]
    else:
        gcs_filename = filepath

    gcs_path = f"scans/{rfq_id}/{scan_id}/{gcs_filename}"

    try:
        bucket = storage_client.bucket(BUCKET_NAME)
        blob = bucket.blob(gcs_path)
        data = blob.download_as_bytes()
        content_type = CONTENT_TYPES.get(ext, "application/octet-stream")
        return Response(content=data, media_type=content_type, headers={
            "Cache-Control": "public, max-age=86400",
        })
    except Exception:
        raise HTTPException(status_code=404, detail=f"File not found: {filepath}")


@app.put("/api/rfqs/{rfq_id}")
async def update_rfq(rfq_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Update RFQ title, address, or description. Flags pending bids as modified."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    body = await request.json()

    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        # Ownership via either legacy user_id or new homeowner_account_id.
        _verify_rfq_owner(cursor, rfq_id, uid)

        allowed = {"title", "description", "address"}
        updates = {k: v for k, v in body.items() if k in allowed}
        if not updates:
            raise HTTPException(400, "No valid fields to update")

        set_clauses = ", ".join(f"{k} = %s" for k in updates)
        values = list(updates.values())
        cursor.execute(f"UPDATE rfqs SET {set_clauses} WHERE id = %s", values + [rfq_id])

        # Flag pending bids that the project has changed
        cursor.execute(
            "UPDATE bids SET rfq_modified_after_bid = TRUE WHERE rfq_id = %s AND status = 'pending'",
            (rfq_id,),
        )
        flagged = cursor.rowcount

        # Notify existing threads that the project changed
        if flagged:
            try:
                _post_rfq_updated_event(cursor, rfq_id)
            except Exception as e:
                print(f"[Inbox] Failed to post rfq_updated event: {e}")

        conn.commit()
    finally:
        conn.close()

    return {"status": "updated", "bids_flagged": flagged}


@app.delete("/api/rfqs/{rfq_id}")
def delete_rfq(rfq_id: str, authorization: str = Header(None)) -> dict:
    """Soft-delete an RFQ and all its scans.

    Sets all scans to 'deleted' status, then deletes the RFQ row.
    GCS blobs are preserved for future model training.
    """
    decoded = verify_firebase_token(authorization)

    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        # Ownership via either legacy user_id or new homeowner_account_id.
        _verify_rfq_owner(cursor, rfq_id, decoded["uid"])

        # Soft-delete the RFQ (preserves all data, bids stay visible to contractors)
        cursor.execute(
            "UPDATE rfqs SET deleted_at = now() WHERE id = %s AND deleted_at IS NULL",
            (rfq_id,),
        )
        if cursor.rowcount == 0:
            conn.rollback()
            raise HTTPException(status_code=404, detail="RFQ not found")

        deleted_scans = 0
        conn.commit()
    finally:
        conn.close()

    return {"status": "deleted", "rfq_id": rfq_id, "scans_deleted": deleted_scans}


@app.put("/api/rfqs/{rfq_id}/scans/{scan_id}")
async def update_scan(rfq_id: str, scan_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Update mutable fields on a scanned room. Currently: `room_label`.

    Ownership check piggybacks on the surrounding rfqs row (scans belong
    to the RFQ owner). Returns {"status": "ok", "room_label": "..."}.
    """
    decoded = verify_firebase_token(authorization)
    body = await request.json()
    label = body.get("room_label")
    if not isinstance(label, str) or not label.strip():
        raise HTTPException(400, "room_label is required")
    label = label.strip()[:80]

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        # Ownership via either legacy user_id or new homeowner_account_id.
        _verify_rfq_owner(cursor, rfq_id, decoded["uid"])

        cursor.execute(
            """UPDATE scanned_rooms SET room_label = %s
               WHERE id = %s AND rfq_id = %s""",
            (label, scan_id, rfq_id),
        )
        if cursor.rowcount == 0:
            raise HTTPException(404, "Scan not found")
        conn.commit()
    finally:
        conn.close()

    return {"status": "ok", "room_label": label}


@app.put("/api/rfqs/{rfq_id}/scans/{scan_id}/scope")
async def save_scope(rfq_id: str, scan_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Save scope-of-work items and notes for a scanned room."""
    verify_firebase_token(authorization)

    body = await request.json()
    scope = {
        "items": body.get("items", []),
        "notes": body.get("notes", ""),
    }

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """UPDATE scanned_rooms SET scope = %s WHERE id = %s AND rfq_id = %s""",
            (json.dumps(scope), scan_id, rfq_id),
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Scan not found")
        conn.commit()
    finally:
        conn.close()

    return {"status": "ok", "scan_id": scan_id, "scope": scope}


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
            """SELECT title, description, status, project_scope, address FROM rfqs WHERE id = %s""",
            (rfq_id,),
        )
        rfq_row = cursor.fetchone()
        if not rfq_row:
            raise HTTPException(status_code=404, detail="RFQ not found")

        title, description, rfq_status, project_scope, address = rfq_row

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

        # Load features from GCS if available
        scan_id = room["scan_id"]
        try:
            feat_blob = bucket.blob(f"scans/{rfq_id}/{scan_id}/features.json")
            if feat_blob.exists():
                room["features"] = json.loads(feat_blob.download_as_text())
            else:
                room["features"] = []
        except Exception:
            room["features"] = []

        # Check if a Gaussian Splat file exists for this room. Current pipeline uploads
        # room_scan.splat; older runs may have room_scan_glomap.splat — accept either.
        try:
            room["has_splat"] = (
                bucket.blob(f"scans/{rfq_id}/{scan_id}/room_scan.splat").exists()
                or bucket.blob(f"scans/{rfq_id}/{scan_id}/room_scan_glomap.splat").exists()
            )
        except Exception:
            room["has_splat"] = False

        rooms.append(room)

    return {
        "rfq_id": rfq_id,
        "title": title,
        "address": address,
        "job_description": description,
        "project_scope": project_scope,
        "status": rfq_status,
        "rooms": rooms,
    }


@app.get("/api/contractors/me")
def get_contractor_profile(authorization: str = Header(None)) -> dict:
    """Return the authenticated contractor's profile. Auto-creates a row on first sign-in."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    email = decoded.get("email", "")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT id, email, name, icon_url, yelp_url, google_reviews_url, review_rating, review_count FROM contractors WHERE firebase_uid = %s",
            (uid,),
        )
        row = cursor.fetchone()

        if not row:
            contractor_id = str(uuid.uuid4())
            cursor.execute(
                "INSERT INTO contractors (id, firebase_uid, email) VALUES (%s, %s, %s)",
                (contractor_id, uid, email),
            )
            conn.commit()
            return {"id": contractor_id, "email": email, "name": None, "icon_url": None, "yelp_url": None, "google_reviews_url": None, "review_rating": None, "review_count": None}

        columns = ["id", "email", "name", "icon_url", "yelp_url", "google_reviews_url", "review_rating", "review_count"]
        result = _row_to_dict(columns, row)
        result["id"] = str(result["id"])
        if result["review_rating"] is not None:
            result["review_rating"] = float(result["review_rating"])
        return result
    finally:
        conn.close()


@app.post("/api/rfqs/{rfq_id}/bids")
async def submit_bid(
    rfq_id: str,
    price_cents: int = Form(...),
    description: str = Form(...),
    pdf: Optional[UploadFile] = File(None),
    images: list[UploadFile] = File(default=[]),
    authorization: str = Header(None),
) -> dict:
    """Submit (or upsert-update) a bid for an RFQ. multipart/form-data.

    Accepts a single quote PDF (`pdf` field) and zero or more images (`images[]`).
    The PDF writes to both the legacy `bids.pdf_url` column and the unified
    `attachments` + `bid_attachments` (role='quote_pdf') tables during the
    dual-phase rollout; migration 021 will drop the legacy column.
    Images only write to the unified tables with role='image'.
    """
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]

    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        # Look up contractor (legacy) and org
        cursor.execute("SELECT id FROM contractors WHERE firebase_uid = %s", (uid,))
        row = cursor.fetchone()
        contractor_id = str(row[0]) if row else None

        # Also check org membership
        org_id = None
        try:
            org_id_val, _ = _get_user_org(cursor, uid)
            org_id = str(org_id_val)
        except Exception:
            pass

        if not contractor_id and not org_id:
            raise HTTPException(status_code=403, detail="No contractor or org profile found.")

        # If no legacy contractor, auto-create one for backward compat
        if not contractor_id:
            cursor.execute(
                """INSERT INTO contractors (firebase_uid, email, name)
                   VALUES (%s, %s, %s)
                   ON CONFLICT (firebase_uid) DO UPDATE SET firebase_uid = EXCLUDED.firebase_uid
                   RETURNING id""",
                (uid, decoded.get("email", ""), None),
            )
            contractor_id = str(cursor.fetchone()[0])

        # If the caller already has a pending bid for this RFQ (same org, or
        # same contractor when no org), update it in place instead of creating
        # a second row. Accepted/rejected bids stay frozen.
        if org_id:
            cursor.execute(
                """SELECT id, pdf_url FROM bids
                   WHERE rfq_id = %s AND org_id = %s AND status = 'pending'
                   ORDER BY received_at DESC LIMIT 1""",
                (rfq_id, org_id),
            )
        else:
            cursor.execute(
                """SELECT id, pdf_url FROM bids
                   WHERE rfq_id = %s AND contractor_id = %s AND org_id IS NULL AND status = 'pending'
                   ORDER BY received_at DESC LIMIT 1""",
                (rfq_id, contractor_id),
            )
        existing = cursor.fetchone()
        is_update = existing is not None

        bid_id = str(existing[0]) if is_update else str(uuid.uuid4())
        existing_pdf_url = existing[1] if is_update else None
        pdf_url = existing_pdf_url  # keep prior PDF unless caller sends a new file

        # Resolve uploader account_id for attachment provenance (may be None
        # if this is a legacy contractor with no linked account).
        cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (uid,))
        uploader_acct_row = cursor.fetchone()
        uploader_account_id = str(uploader_acct_row[0]) if uploader_acct_row else None

        pdf_blob_path: Optional[str] = None
        if pdf and pdf.filename:
            pdf_blob_path = f"bids/{rfq_id}/{bid_id}.pdf"
            bucket = storage_client.bucket(BUCKET_NAME)
            blob = bucket.blob(pdf_blob_path)
            content = await pdf.read()
            blob.upload_from_string(content, content_type="application/pdf")

            if not _credentials.token or not _credentials.valid:
                _credentials.refresh(_auth_request)
            pdf_url = blob.generate_signed_url(
                version="v4",
                expiration=datetime.timedelta(days=7),
                method="GET",
                service_account_email=SIGNING_SA_EMAIL,
                access_token=_credentials.token,
            )

        if is_update:
            cursor.execute(
                """UPDATE bids
                   SET price_cents = %s, description = %s, pdf_url = %s,
                       received_at = NOW(), rfq_modified_after_bid = FALSE
                   WHERE id = %s""",
                (price_cents, description, pdf_url, bid_id),
            )
        else:
            cursor.execute(
                """INSERT INTO bids (id, rfq_id, contractor_id, org_id, price_cents, description, pdf_url, received_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, NOW())""",
                (bid_id, rfq_id, contractor_id, org_id, price_cents, description, pdf_url),
            )

        # Dual-write the PDF into the unified attachments tables so future reads
        # via `bid_attachments WHERE role='quote_pdf'` keep returning it. For
        # updates that reuse the same blob_path, the upsert collapses to a no-op.
        if pdf_blob_path:
            pdf_attachment_id = _register_attachment(
                cursor, blob_path=pdf_blob_path, content_type="application/pdf",
                name=pdf.filename if pdf else None,
                uploader_account_id=uploader_account_id,
            )
            _link_bid_attachment(
                cursor, bid_id=bid_id, attachment_id=pdf_attachment_id, role="quote_pdf",
            )

        # Bid images — unified tables only (no legacy column exists).
        image_attachments_info: list[dict] = []
        for image in (images or []):
            if not image or not image.filename:
                continue
            ct = image.content_type or "application/octet-stream"
            ext = ATTACHMENT_TYPES.get(ct, "")
            if ct not in ATTACHMENT_TYPES or ct == "application/pdf":
                # PDFs go through the dedicated `pdf` field; anything outside the
                # allowlist is rejected silently.
                continue
            image_id = str(uuid.uuid4())
            img_blob_path = f"bids/{rfq_id}/{bid_id}/{image_id}{ext}"
            img_content = await image.read()
            bucket = storage_client.bucket(BUCKET_NAME)
            bucket.blob(img_blob_path).upload_from_string(img_content, content_type=ct)

            attachment_id = _register_attachment(
                cursor, blob_path=img_blob_path, content_type=ct,
                name=image.filename, size_bytes=len(img_content),
                uploader_account_id=uploader_account_id,
            )
            _link_bid_attachment(
                cursor, bid_id=bid_id, attachment_id=attachment_id, role="image",
            )
            image_attachments_info.append({
                "attachment_id": attachment_id,
                "blob_path": img_blob_path,
                "content_type": ct,
                "name": image.filename,
                "size_bytes": len(img_content),
            })

        # Auto-post the bid into the inbox conversation (creating it if needed).
        # Wrapped to avoid blocking the bid insert if anything goes wrong here.
        if org_id:
            try:
                _post_bid_events(
                    cursor, rfq_id=rfq_id, org_id=org_id, bid_id=bid_id,
                    price_cents=price_cents, description=description, pdf_url=pdf_url,
                )
            except Exception as e:
                print(f"[Inbox] Failed to post bid event: {e}")

        conn.commit()

        cursor.execute("SELECT received_at FROM bids WHERE id = %s", (bid_id,))
        received_at = cursor.fetchone()[0]

        # Get homeowner email + org name for notification
        homeowner_email = None
        org_name = None
        try:
            # Try homeowner_account_id first, fall back to user_id (Firebase UID)
            cursor.execute(
                """SELECT COALESCE(ha.email, ua.email)
                   FROM rfqs r
                   LEFT JOIN accounts ha ON ha.id = r.homeowner_account_id
                   LEFT JOIN accounts ua ON ua.firebase_uid = r.user_id
                   WHERE r.id = %s""",
                (rfq_id,),
            )
            he_row = cursor.fetchone()
            if he_row and he_row[0]:
                homeowner_email = he_row[0]
            if org_id:
                cursor.execute("SELECT name FROM organizations WHERE id = %s", (org_id,))
                org_row = cursor.fetchone()
                if org_row:
                    org_name = org_row[0]
        except Exception:
            pass
    finally:
        conn.close()

    # Notify homeowner of new bid
    if homeowner_email:
        _send_bid_received_email(homeowner_email, rfq_id, org_name or "A contractor", price_cents)

    return {
        "id": bid_id,
        "rfq_id": rfq_id,
        "contractor_id": contractor_id,
        "org_id": org_id,
        "price_cents": price_cents,
        "description": description,
        "pdf_url": pdf_url,
        "attachments": _resolve_attachments(image_attachments_info),
        "received_at": received_at.isoformat() if received_at else None,
    }


@app.get("/api/rfqs/{rfq_id}/bids")
def list_bids(rfq_id: str, token: str = None, authorization: Optional[str] = Header(None)) -> dict:
    """Return all bids for an RFQ with nested contractor profiles.

    Auth: either a valid bid_view_token query param OR a Firebase JWT
    belonging to the RFQ owner.
    """
    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        cursor.execute(
            "SELECT description, bid_view_token, user_id, homeowner_account_id FROM rfqs WHERE id = %s",
            (rfq_id,),
        )
        rfq_row = cursor.fetchone()
        if not rfq_row:
            raise HTTPException(status_code=404, detail="RFQ not found")

        project_description, bid_view_token, rfq_owner_uid, rfq_account_id = rfq_row

        # Auth check: token-based OR JWT owner (via user_id OR account linkage)
        token_ok = token and str(bid_view_token) == token
        jwt_ok = False
        if authorization and not token_ok:
            try:
                decoded = verify_firebase_token(authorization)
                jwt_uid = decoded["uid"]
                if jwt_uid == rfq_owner_uid:
                    jwt_ok = True
                elif rfq_account_id:
                    cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (jwt_uid,))
                    acct = cursor.fetchone()
                    if acct and acct[0] == rfq_account_id:
                        jwt_ok = True
            except Exception:
                pass
        if not token_ok and not jwt_ok:
            raise HTTPException(status_code=403, detail="Invalid or missing authorization")

        # Prefer org data if available, fall back to contractor data
        cursor.execute(
            """SELECT b.id, b.price_cents, b.description, b.pdf_url, b.received_at,
                      c.id AS contractor_id, c.name, c.icon_url, c.yelp_url,
                      c.google_reviews_url, c.review_rating, c.review_count,
                      o.id AS org_id, o.name AS org_name, o.icon_url AS org_icon,
                      o.yelp_url AS org_yelp, o.google_reviews_url AS org_google,
                      o.avg_rating AS org_rating, o.description AS org_description
               FROM bids b
               JOIN contractors c ON c.id = b.contractor_id
               LEFT JOIN organizations o ON o.id = b.org_id
               WHERE b.rfq_id = %s
               ORDER BY b.price_cents ASC""",
            (rfq_id,),
        )
        rows = cursor.fetchall()

        # Batch-fetch bid attachments (quote PDFs + images) from the unified
        # table. Used both to refresh expired legacy pdf_url signed URLs and
        # to expose bid images to clients that render them.
        bid_ids = [row[0] for row in rows]
        attachments_by_bid: dict[str, dict] = {str(bid_id): {"pdf_blob_path": None, "images": []} for bid_id in bid_ids}
        if bid_ids:
            placeholders = ",".join(["%s"] * len(bid_ids))
            cursor.execute(
                f"""SELECT ba.bid_id, ba.role, a.id, a.blob_path, a.content_type, a.name, a.size_bytes
                    FROM bid_attachments ba
                    JOIN attachments a ON a.id = ba.attachment_id
                    WHERE ba.bid_id IN ({placeholders})
                    ORDER BY ba.created_at""",
                bid_ids,
            )
            for bid_id_val, role, aid, bp, ct, nm, sb in cursor.fetchall():
                entry = attachments_by_bid.setdefault(str(bid_id_val), {"pdf_blob_path": None, "images": []})
                if role == "quote_pdf":
                    entry["pdf_blob_path"] = bp
                else:
                    entry["images"].append({
                        "attachment_id": str(aid),
                        "blob_path": bp, "content_type": ct, "name": nm, "size_bytes": sb,
                    })

        # Fetch RFQ-level attachments so the homeowner can see media they've
        # shared (directly or via chat) alongside the bids.
        cursor.execute(
            """SELECT a.id, a.blob_path, a.content_type, a.name, a.size_bytes
               FROM rfq_attachments ra
               JOIN attachments a ON a.id = ra.attachment_id
               WHERE ra.rfq_id = %s
               ORDER BY ra.created_at""",
            (rfq_id,),
        )
        rfq_attachment_rows = [
            {"attachment_id": str(aid), "blob_path": bp, "content_type": ct, "name": nm, "size_bytes": sb}
            for aid, bp, ct, nm, sb in cursor.fetchall()
        ]

        # Collect org IDs to batch-fetch gallery images
        org_ids = [row[12] for row in rows if row[12]]
        gallery_by_org = {}
        if org_ids:
            placeholders = ",".join(["%s"] * len(org_ids))
            cursor.execute(
                f"""SELECT org_id, id, image_url, before_image_url, image_type, caption
                    FROM org_work_images
                    WHERE org_id IN ({placeholders})
                    ORDER BY sort_order, created_at
                    LIMIT 50""",
                org_ids,
            )
            for g_row in cursor.fetchall():
                g_org_id = str(g_row[0])
                if g_org_id not in gallery_by_org:
                    gallery_by_org[g_org_id] = []
                gallery_by_org[g_org_id].append({
                    "id": str(g_row[1]),
                    "image_url": g_row[2],
                    "before_image_url": g_row[3],
                    "image_type": g_row[4],
                    "caption": g_row[5],
                })
    finally:
        conn.close()

    # Sign gallery image URLs
    if gallery_by_org:
        _credentials.refresh(_auth_request)
        _bucket = storage_client.bucket(BUCKET_NAME)
        _prefix = f"https://storage.googleapis.com/{BUCKET_NAME}/"
        for org_key in gallery_by_org:
            for img in gallery_by_org[org_key]:
                for field in ("image_url", "before_image_url"):
                    val = img.get(field)
                    if val:
                        blob_path = val.replace(_prefix, "") if val.startswith("http") else val
                        img[field] = _bucket.blob(blob_path).generate_signed_url(
                            version="v4", expiration=datetime.timedelta(days=7), method="GET",
                            service_account_email=SIGNING_SA_EMAIL, access_token=_credentials.token,
                        )

    bids = []
    for row in rows:
        (bid_id, price_cents, desc, pdf_url, received_at,
         c_id, c_name, c_icon, c_yelp, c_google, c_rating, c_count,
         org_id, org_name, org_icon, org_yelp, org_google, org_rating, org_desc) = row

        # Use org data when available, fall back to contractor data
        contractor = {
            "id": str(org_id or c_id),
            "name": org_name or c_name,
            "icon_url": _sign_icon_url(org_icon or c_icon),
            "yelp_url": org_yelp or c_yelp,
            "google_reviews_url": org_google or c_google,
            "review_rating": float(org_rating) if org_rating else (float(c_rating) if c_rating else None),
            "review_count": c_count,
            "description": org_desc,
            "gallery": gallery_by_org.get(str(org_id), [])[:3] if org_id else [],
        }
        att_info = attachments_by_bid.get(str(bid_id), {"pdf_blob_path": None, "images": []})
        # Prefer a freshly-signed URL from the unified table; fall back to the
        # legacy stored URL (may be expired for bids older than 7 days).
        effective_pdf_url = pdf_url
        if att_info["pdf_blob_path"]:
            try:
                effective_pdf_url = _sign_attachment_get(att_info["pdf_blob_path"])
            except Exception:
                pass
        bids.append({
            "id": str(bid_id),
            "price_cents": price_cents,
            "description": desc,
            "pdf_url": effective_pdf_url,
            "attachments": _resolve_attachments(att_info["images"]),
            "received_at": received_at.isoformat() if received_at else None,
            "contractor": contractor,
        })

    return {
        "rfq_id": rfq_id,
        "project_description": project_description,
        "rfq_attachments": _resolve_attachments(rfq_attachment_rows),
        "bids": bids,
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


@app.get("/embed/scan/{rfq_id}", response_class=HTMLResponse)
def serve_embed_viewer(rfq_id: str) -> str:
    """Serve the chrome-less 3D scan viewer for embedding via iframe.

    URL params the page honors:
      ?view=bev|tour           (default: tour)
      ?measurements=on|off     (default: on)
      ?room=<scan_id>          (default: first room)

    Public like /quote/ — the URL itself is the access token.
    """
    html_path = Path(__file__).parent / "web" / "embed_viewer.html"
    if not html_path.exists():
        raise HTTPException(status_code=500, detail="Embed viewer page not found")
    return html_path.read_text()


@app.get("/splat/{rfq_id}", response_class=HTMLResponse)
def serve_splat_viewer(rfq_id: str) -> str:
    """Serve the Gaussian Splat viewer HTML page.

    Displays a .splat file instead of the OBJ mesh. The splat URL can be
    passed via ?splat=URL query param or defaults to the file proxy path.
    """
    html_path = Path(__file__).parent / "web" / "splat_viewer.html"
    if not html_path.exists():
        raise HTTPException(status_code=500, detail="Splat viewer page not found")
    return html_path.read_text()


@app.get("/bids/{rfq_id}", response_class=HTMLResponse)
def serve_bids_page(rfq_id: str) -> str:
    """Serve the homeowner bid comparison page.

    The page reads the bid_view_token from the ?token= query param and fetches
    bids from /api/rfqs/{rfq_id}/bids?token=... to render the comparison view.
    """
    html_path = Path(__file__).parent / "web" / "bids.html"
    if not html_path.exists():
        raise HTTPException(status_code=500, detail="Bids page not found")
    return html_path.read_text()


@app.get("/favicon.ico")
def favicon():
    return FileResponse(Path(__file__).parent / "web" / "favicon.ico", media_type="image/x-icon")


@app.get("/apple-touch-icon.png")
def apple_touch_icon():
    return FileResponse(Path(__file__).parent / "web" / "apple-touch-icon.png", media_type="image/png")


@app.get("/og-image.png")
def og_image():
    return FileResponse(Path(__file__).parent / "web" / "og-image.png", media_type="image/png")


def _verify_admin(authorization: Optional[str]) -> dict:
    """Verify Firebase JWT and check admin UID allowlist."""
    decoded = verify_firebase_token(authorization)
    if ADMIN_UIDS and decoded['uid'] not in ADMIN_UIDS:
        raise HTTPException(status_code=403, detail="Not authorized as admin")
    return decoded


@app.get("/admin/rfq/{rfq_id}", response_class=HTMLResponse)
def serve_admin_page(rfq_id: str) -> str:
    """Serve the admin annotation tool. Auth checked client-side via Firebase JS."""
    html_path = Path(__file__).parent / "web" / "admin_annotator.html"
    if not html_path.exists():
        raise HTTPException(status_code=500, detail="Admin page not found")
    return html_path.read_text()


@app.get("/api/admin/rfqs/{rfq_id}/scans/{scan_id}/annotations")
def get_annotations(rfq_id: str, scan_id: str, authorization: str = Header(None)) -> list:
    """Load annotations for a room from GCS."""
    _verify_admin(authorization)
    try:
        bucket = storage_client.bucket(BUCKET_NAME)
        blob = bucket.blob(f"scans/{rfq_id}/{scan_id}/annotations.json")
        if not blob.exists():
            return []
        return json.loads(blob.download_as_text())
    except Exception as e:
        print(f"[Admin] Failed to load annotations: {e}")
        return []


@app.put("/api/admin/rfqs/{rfq_id}/scans/{scan_id}/annotations")
async def save_annotations(rfq_id: str, scan_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Save annotations to GCS and update detected_components in the DB."""
    _verify_admin(authorization)
    body = await request.json()

    # Save raw annotations to GCS
    try:
        bucket = storage_client.bucket(BUCKET_NAME)
        blob = bucket.blob(f"scans/{rfq_id}/{scan_id}/annotations.json")
        blob.upload_from_string(json.dumps(body), content_type="application/json")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to save to GCS: {e}")

    # Build detected_components from annotations and update the DB
    # Format: { "detected": ["floor_hardwood", ...], "details": { "floor_hardwood": { "qty": 120, "unit": "SF" }, ... } }
    try:
        detected = []
        details = {}
        for ann in body:
            label_key = ann.get('k', '')
            if not label_key:
                continue
            detected.append(label_key)
            qty = ann.get('qty', 0)
            # Look up unit from taxonomy-like info (stored in the annotation color/faces structure)
            # The admin tool stores: { k, color, faces, qty, visible }
            # We need the unit — derive from the label key prefix
            unit = _unit_for_label(label_key)
            details[label_key] = {"qty": qty, "unit": unit}

        detected_components = {"detected": detected, "details": details}

        conn = get_db_connection()
        try:
            cursor = conn.cursor()
            cursor.execute(
                """UPDATE scanned_rooms
                   SET detected_components = %s
                   WHERE id = %s AND rfq_id = %s""",
                (json.dumps(detected_components), scan_id, rfq_id),
            )
            conn.commit()
        finally:
            conn.close()

        return {"status": "saved", "scan_id": scan_id, "components": len(detected)}
    except Exception as e:
        print(f"[Admin] DB update failed (GCS saved ok): {e}")
        return {"status": "saved_gcs_only", "scan_id": scan_id, "error": str(e)}


def _unit_for_label(label_key: str) -> str:
    """Derive unit type from label key based on taxonomy conventions."""
    units = {
        'sink': 'EA', 'fridge': 'EA', 'range': 'EA', 'tub': 'EA', 'toilet': 'EA',
        'shower': 'EA', 'washer': 'EA', 'dryer': 'EA',
        'door_interior': 'EA', 'door_exterior': 'EA',
        'light_recessed': 'EA', 'light_fixture': 'EA', 'light_fluorescent': 'EA',
        'baseboard': 'LF', 'toe_kick': 'LF', 'shoe_molding': 'LF',
        'cabinet_upper_skinny': 'LF', 'cabinet_upper_wide': 'LF',
        'cabinet_lower_skinny': 'LF', 'cabinet_lower_wide': 'LF',
        'cabinet_full_skinny': 'LF', 'cabinet_full_wide': 'LF',
    }
    if label_key in units:
        return units[label_key]
    # Default: surface-area labels (floor_*, ceiling_*, clutter, rug, furniture)
    return 'SF'


@app.get("/api/admin/rfqs/{rfq_id}/scans/{scan_id}/features")
def get_features(rfq_id: str, scan_id: str, authorization: str = Header(None)) -> list:
    """Load features (doors, cabinets, openings) from GCS."""
    _verify_admin(authorization)
    try:
        bucket = storage_client.bucket(BUCKET_NAME)
        blob = bucket.blob(f"scans/{rfq_id}/{scan_id}/features.json")
        if not blob.exists():
            return []
        return json.loads(blob.download_as_text())
    except Exception as e:
        print(f"[Admin] Failed to load features: {e}")
        return []


@app.put("/api/admin/rfqs/{rfq_id}/scans/{scan_id}/features")
async def save_features(rfq_id: str, scan_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Save features (doors, cabinets, openings) to GCS."""
    _verify_admin(authorization)
    body = await request.json()
    try:
        bucket = storage_client.bucket(BUCKET_NAME)
        blob = bucket.blob(f"scans/{rfq_id}/{scan_id}/features.json")
        blob.upload_from_string(json.dumps(body), content_type="application/json")
        return {"status": "saved", "count": len(body)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to save features: {e}")


@app.put("/api/admin/rfqs/{rfq_id}/scans/{scan_id}/polygon")
async def update_polygon(rfq_id: str, scan_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Update room polygon corners and recompute dimensions."""
    _verify_admin(authorization)
    body = await request.json()
    polygon_ft = body.get('room_polygon_ft', [])
    wall_heights_ft = body.get('wall_heights_ft', [])     # ceiling Y per corner
    floor_heights_ft = body.get('floor_heights_ft', [])   # floor Y per corner (new)

    if len(polygon_ft) < 3:
        raise HTTPException(status_code=400, detail="At least 3 corners required")

    # Recompute dimensions from the updated polygon
    import math
    FT_TO_M = 1.0 / 3.28084
    SQM_TO_SQFT = 10.7639

    corners_m = [[c[0] * FT_TO_M, c[1] * FT_TO_M] for c in polygon_ft]
    n = len(corners_m)

    # Floor area via shoelace formula
    signed_area = 0
    for i in range(n):
        j = (i + 1) % n
        signed_area += corners_m[i][0] * corners_m[j][1]
        signed_area -= corners_m[j][0] * corners_m[i][1]
    floor_area_sqft = round(abs(signed_area) / 2.0 * SQM_TO_SQFT, 1)

    # Perimeter
    perimeter_m = 0
    for i in range(n):
        j = (i + 1) % n
        dx = corners_m[j][0] - corners_m[i][0]
        dz = corners_m[j][1] - corners_m[i][1]
        perimeter_m += math.sqrt(dx * dx + dz * dz)
    perimeter_ft = round(perimeter_m * 3.28084, 1)

    # Ceiling height: average of (ceilingY - floorY) per corner
    if wall_heights_ft and floor_heights_ft and len(floor_heights_ft) == len(wall_heights_ft):
        wall_h_per_corner = [wall_heights_ft[i] - floor_heights_ft[i] for i in range(len(wall_heights_ft))]
        avg_height_ft = round(sum(wall_h_per_corner) / len(wall_h_per_corner), 2)
    elif wall_heights_ft:
        avg_height_ft = round(sum(wall_heights_ft) / len(wall_heights_ft), 2)
    else:
        avg_height_ft = 8.0
    wall_area_sqft = round(perimeter_ft * avg_height_ft, 1)

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """UPDATE scanned_rooms
               SET room_polygon_ft = %s, wall_heights_ft = %s,
                   floor_area_sqft = %s, wall_area_sqft = %s,
                   perimeter_linear_ft = %s, ceiling_height_ft = %s,
                   polygon_source = 'admin_edited'
               WHERE id = %s AND rfq_id = %s""",
            (json.dumps(polygon_ft), json.dumps(wall_heights_ft),
             floor_area_sqft, wall_area_sqft, perimeter_ft, avg_height_ft,
             scan_id, rfq_id),
        )
        conn.commit()
    finally:
        conn.close()

    return {
        "status": "saved",
        "floor_area_sqft": floor_area_sqft,
        "wall_area_sqft": wall_area_sqft,
        "perimeter_linear_ft": perimeter_ft,
        "ceiling_height_ft": avg_height_ft,
    }


# --- Account endpoints ---

@app.get("/api/account")
def get_account(authorization: str = Header(None)) -> dict:
    """Get or auto-create the current user's account."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    email = decoded.get("email", f"{uid}@unknown")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """INSERT INTO accounts (firebase_uid, email, type)
               VALUES (%s, %s, 'homeowner')
               ON CONFLICT (firebase_uid) DO UPDATE SET email = EXCLUDED.email
               RETURNING id, firebase_uid, email, name, phone, type, icon_url, address,
                         notification_preferences""",
            (uid, email),
        )
        row = cursor.fetchone()
        conn.commit()

        # Check if user belongs to an org
        cursor.execute(
            """SELECT o.id, o.name, om.role, o.icon_url FROM org_members om
               JOIN organizations o ON o.id = om.org_id
               JOIN accounts a ON a.id = om.account_id
               WHERE a.firebase_uid = %s AND o.deleted_at IS NULL
               LIMIT 1""",
            (uid,),
        )
        org_row = cursor.fetchone()
    finally:
        conn.close()

    return {
        "id": str(row[0]),
        "email": row[2],
        "name": row[3],
        "phone": row[4],
        "account_type": row[5],
        "icon_url": _sign_icon_url(row[6]),
        "address": row[7],
        "notification_preferences": row[8] or {},
        "org": {
            "id": str(org_row[0]), "name": org_row[1], "role": org_row[2],
            "icon_url": _sign_icon_url(org_row[3]),
        } if org_row else None,
    }


@app.put("/api/account")
async def update_account(request: Request, authorization: str = Header(None)) -> dict:
    """Update the current user's account profile."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    body = await request.json()

    allowed = {"name", "phone", "icon_url", "address", "notification_preferences"}
    updates = {k: v for k, v in body.items() if k in allowed}
    if not updates:
        raise HTTPException(400, "No valid fields to update")

    set_clauses = ", ".join(f"{k} = %s" for k in updates)
    values = list(updates.values())
    # Serialize JSONB fields
    if "notification_preferences" in updates:
        idx = list(updates.keys()).index("notification_preferences")
        values[idx] = json.dumps(values[idx])

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            f"UPDATE accounts SET {set_clauses} WHERE firebase_uid = %s RETURNING id",
            values + [uid],
        )
        if not cursor.fetchone():
            raise HTTPException(404, "Account not found")
        conn.commit()
    finally:
        conn.close()

    return {"status": "updated"}


@app.get("/api/account/icon-upload-url")
def account_icon_upload_url(content_type: str = "image/jpeg", authorization: str = Header(None)) -> dict:
    """Get a signed GCS URL for uploading an account profile picture."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]

    allowed_types = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
    if content_type not in allowed_types:
        raise HTTPException(400, f"Unsupported content type. Allowed: {', '.join(allowed_types)}")

    ext = allowed_types[content_type]
    blob_path = f"accounts/{uid}/icon{ext}"

    _credentials.refresh(_auth_request)
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(blob_path)
    url = blob.generate_signed_url(
        version="v4",
        expiration=datetime.timedelta(minutes=SIGNED_URL_EXPIRY_MINUTES),
        method="PUT",
        content_type=content_type,
        service_account_email=SIGNING_SA_EMAIL,
        access_token=_credentials.token,
    )

    return {"upload_url": url, "blob_path": blob_path, "content_type": content_type}


@app.get("/api/org/icon-upload-url")
def org_icon_upload_url(content_type: str = "image/jpeg", authorization: str = Header(None)) -> dict:
    """Get a signed GCS URL for uploading an org profile picture."""
    decoded = verify_firebase_token(authorization)

    allowed_types = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
    if content_type not in allowed_types:
        raise HTTPException(400, f"Unsupported content type. Allowed: {', '.join(allowed_types)}")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")
    finally:
        conn.close()

    ext = allowed_types[content_type]
    blob_path = f"orgs/{org_id}/icon{ext}"

    _credentials.refresh(_auth_request)
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(blob_path)
    url = blob.generate_signed_url(
        version="v4",
        expiration=datetime.timedelta(minutes=SIGNED_URL_EXPIRY_MINUTES),
        method="PUT",
        content_type=content_type,
        service_account_email=SIGNING_SA_EMAIL,
        access_token=_credentials.token,
    )

    return {"upload_url": url, "blob_path": blob_path, "content_type": content_type}


@app.post("/api/account/request-org")
async def request_org(request: Request, authorization: str = Header(None)) -> dict:
    """Request creation of a contractor organization. Sends notification email."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    body = await request.json()
    org_name = body.get("org_name", "").strip()
    if not org_name:
        raise HTTPException(400, "org_name is required")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT id, email, name, phone, address FROM accounts WHERE firebase_uid = %s",
            (uid,),
        )
        account = cursor.fetchone()
        if not account:
            raise HTTPException(404, "Account not found")

        account_id, acct_email, acct_name, acct_phone, acct_address = account

        cursor.execute(
            "INSERT INTO org_requests (account_id, org_name) VALUES (%s, %s) RETURNING id",
            (account_id, org_name),
        )
        req_id = cursor.fetchone()[0]
        conn.commit()
    finally:
        conn.close()

    # Send emails
    _send_org_request_emails(req_id, org_name, acct_email, acct_name, acct_phone, acct_address)

    return {"request_id": str(req_id), "status": "pending"}


BCC_EMAIL = "notifications@roomscanalpha.com"
FRONTEND_URL = os.environ.get("FRONTEND_URL", "https://roomscanalpha.com")


def _make_mail(from_email, to_emails, subject, html_content):
    """Create a SendGrid Mail with BCC to notifications inbox."""
    from sendgrid.helpers.mail import Mail, Bcc
    mail = Mail(
        from_email=from_email,
        to_emails=to_emails,
        subject=subject,
        html_content=html_content,
    )
    mail.add_bcc(Bcc(BCC_EMAIL))
    return mail


def _send_bid_received_email(homeowner_email, rfq_id, org_name, price_cents):
    """Notify homeowner that a contractor submitted a bid."""
    sendgrid_key = os.environ.get("SENDGRID_API_KEY", "")
    if not sendgrid_key:
        return
    try:
        from sendgrid import SendGridAPIClient

        price_str = f"${price_cents / 100:,.0f}"
        quotes_url = f"https://roomscanalpha.com/projects/{rfq_id}/quotes"
        html = f"""
<h2>New Quote Received</h2>
<p style="font-size:15px;color:#333;line-height:1.6">
  <strong>{org_name}</strong> submitted a quote of <strong>{price_str}</strong> for your project.
</p>
<a href="{quotes_url}" style="display:inline-block;padding:14px 32px;background:#0055cc;color:#fff;
   text-decoration:none;font-weight:700;font-size:16px;border-radius:8px;margin-top:16px">
  View Quotes
</a>
<p style="font-size:13px;color:#888;margin-top:24px">— The Quoterra Team</p>
"""
        sg = SendGridAPIClient(sendgrid_key)
        sg.send(_make_mail(
            from_email="notifications@roomscanalpha.com",
            to_emails=homeowner_email,
            subject=f"New quote from {org_name}",
            html_content=html,
        ))
    except Exception as e:
        print(f"Failed to send bid received email: {e}")


def _send_org_request_emails(req_id, org_name, acct_email, acct_name, acct_phone, acct_address):
    """Send request confirmation to requester + approval notification to admin."""
    sendgrid_key = os.environ.get("SENDGRID_API_KEY", "")
    if not sendgrid_key:
        return
    try:
        from sendgrid import SendGridAPIClient

        sg = SendGridAPIClient(sendgrid_key)
        base_url = os.environ.get("SERVICE_URL", "https://scan-api-839349778883.us-central1.run.app")
        approve_url = f"{base_url}/admin/approve-org/{req_id}"

        # 1. Confirmation email to the requester
        requester_html = f"""
<h2>We received your request!</h2>
<p style="font-size:15px;color:#333;line-height:1.6">
  Hi {acct_name or 'there'},<br><br>
  Your request to create a contractor account for <strong>{org_name}</strong> has been submitted.
  We'll review it shortly and you'll receive an email once approved.
</p>
<p style="font-size:13px;color:#888;margin-top:24px">— The Quoterra Team</p>
"""
        sg.send(_make_mail(
            from_email="notifications@roomscanalpha.com",
            to_emails=acct_email,
            subject=f"Request received: {org_name}",
            html_content=requester_html,
        ))

        # 2. Approval email to admin
        admin_html = f"""
<h2>New Contractor Account Request</h2>
<table style="border-collapse:collapse;font-size:15px;margin:16px 0">
  <tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Company</td><td style="padding:6px 0">{org_name}</td></tr>
  <tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Name</td><td style="padding:6px 0">{acct_name or 'Not provided'}</td></tr>
  <tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Email</td><td style="padding:6px 0">{acct_email}</td></tr>
  <tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Phone</td><td style="padding:6px 0">{acct_phone or 'Not provided'}</td></tr>
  <tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Address</td><td style="padding:6px 0">{acct_address or 'Not provided'}</td></tr>
</table>
<a href="{approve_url}" style="display:inline-block;padding:14px 32px;background:#0055cc;color:#fff;
   text-decoration:none;font-weight:700;font-size:16px;border-radius:8px;margin-top:8px">
  Approve Contractor Account
</a>
<p style="margin-top:16px;font-size:13px;color:#888">Request ID: {req_id}</p>
"""
        sg.send(_make_mail(
            from_email="notifications@roomscanalpha.com",
            to_emails="jake@roomscanalpha.com",
            subject=f"Contractor Request: {org_name}",
            html_content=admin_html,
        ))
    except Exception as e:
        print(f"[Email] Failed to send org request emails: {e}")


@app.get("/admin/approve-org/{request_id}", response_class=HTMLResponse)
def approve_org_request(request_id: str) -> str:
    """Approve a contractor org request. Creates org, migrates account, links membership.

    This is accessed via the approval link in the admin notification email.
    The request UUID serves as the auth token (unguessable).
    """
    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        # Look up the request
        cursor.execute(
            """SELECT r.id, r.account_id, r.org_name, r.status,
                      a.email, a.name, a.phone, a.address
               FROM org_requests r
               JOIN accounts a ON a.id = r.account_id
               WHERE r.id = %s""",
            (request_id,),
        )
        row = cursor.fetchone()
        if not row:
            return _approval_page("Request Not Found", "This request does not exist.", error=True)

        req_id, account_id, org_name, status, email, name, phone, address = row

        if status == "approved":
            return _approval_page("Already Approved",
                f"{org_name} ({email}) was already approved.")

        if status == "rejected":
            return _approval_page("Already Rejected",
                f"This request was previously rejected.", error=True)

        # Create the organization
        cursor.execute(
            """INSERT INTO organizations (name) VALUES (%s) RETURNING id""",
            (org_name,),
        )
        org_id = cursor.fetchone()[0]

        # Link account to org as admin
        cursor.execute(
            """INSERT INTO org_members (org_id, account_id, role, invite_status)
               VALUES (%s, %s, 'admin', 'accepted')
               ON CONFLICT (org_id, account_id) DO NOTHING""",
            (org_id, account_id),
        )

        # Update account type to contractor
        cursor.execute(
            "UPDATE accounts SET type = 'contractor' WHERE id = %s",
            (account_id,),
        )

        # Mark request as approved
        cursor.execute(
            "UPDATE org_requests SET status = 'approved', resolved_at = now() WHERE id = %s",
            (req_id,),
        )

        conn.commit()
    finally:
        conn.close()

    # Send approval email to the requester
    sendgrid_key = os.environ.get("SENDGRID_API_KEY", "")
    if sendgrid_key:
        try:
            from sendgrid import SendGridAPIClient

            org_url = f"{FRONTEND_URL}/org"

            approval_html = f"""
<h2>You're approved!</h2>
<p style="font-size:15px;color:#333;line-height:1.6">
  Hi {name or 'there'},<br><br>
  Your contractor account for <strong>{org_name}</strong> has been approved.
  You can now set up your organization profile, upload portfolio images, and start submitting bids.
</p>
<a href="{org_url}" style="display:inline-block;padding:14px 32px;background:#34c759;color:#fff;
   text-decoration:none;font-weight:700;font-size:16px;border-radius:8px;margin-top:16px">
  Go to Org Dashboard
</a>
<p style="font-size:13px;color:#888;margin-top:24px">— The Quoterra Team</p>
"""
            sg = SendGridAPIClient(sendgrid_key)
            sg.send(_make_mail(
                from_email="notifications@roomscanalpha.com",
                to_emails=email,
                subject=f"Approved: {org_name} is ready!",
                html_content=approval_html,
            ))
        except Exception as e:
            print(f"[Email] Failed to send approval notification: {e}")

    return _approval_page("Approved!",
        f"<strong>{org_name}</strong> has been created for {name or email}.<br>"
        f"They've been notified by email and can now access the Org Dashboard.")


def _approval_page(title: str, message: str, error: bool = False) -> str:
    color = "#ff3b30" if error else "#34c759"
    return f"""<!DOCTYPE html>
<html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title} — Quoterra</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
         display: flex; align-items: center; justify-content: center; min-height: 100vh;
         background: #f2f4f8; margin: 0; }}
  .card {{ background: #fff; border-radius: 12px; padding: 40px; max-width: 480px;
           text-align: center; box-shadow: 0 2px 12px rgba(0,0,0,0.08); }}
  h1 {{ font-size: 24px; margin-bottom: 12px; color: {color}; }}
  p {{ font-size: 15px; color: #555; line-height: 1.6; }}
</style></head>
<body><div class="card"><h1>{title}</h1><p>{message}</p></div></body></html>"""


# --- Organization endpoints ---

def _sign_icon_url(icon_url: str | None) -> str | None:
    """Generate a signed read URL for an icon stored in GCS. Returns None if no icon."""
    if not icon_url:
        return None
    prefix = f"https://storage.googleapis.com/{BUCKET_NAME}/"
    blob_path = icon_url.replace(prefix, "") if icon_url.startswith("http") else icon_url
    _credentials.refresh(_auth_request)
    bucket = storage_client.bucket(BUCKET_NAME)
    return bucket.blob(blob_path).generate_signed_url(
        version="v4", expiration=datetime.timedelta(days=7), method="GET",
        service_account_email=SIGNING_SA_EMAIL, access_token=_credentials.token,
    )


def _get_user_org(cursor, uid: str):
    """Look up the org and role for a Firebase UID. Returns (org_id, role) or raises 403."""
    cursor.execute(
        """SELECT o.id, om.role FROM org_members om
           JOIN organizations o ON o.id = om.org_id
           JOIN accounts a ON a.id = om.account_id
           WHERE a.firebase_uid = %s AND o.deleted_at IS NULL
           LIMIT 1""",
        (uid,),
    )
    row = cursor.fetchone()
    if not row:
        raise HTTPException(403, "Not a member of any organization")
    return row[0], row[1]


@app.get("/api/org")
def get_org(authorization: str = Header(None)) -> dict:
    """Get the current user's organization."""
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        cursor.execute(
            """SELECT id, name, description, address, icon_url, website_url,
                      yelp_url, google_reviews_url, avg_rating,
                      service_lat, service_lng, service_radius_miles,
                      banner_image_url, business_hours
               FROM organizations WHERE id = %s""",
            (org_id,),
        )
        row = cursor.fetchone()
    finally:
        conn.close()

    return {
        "id": str(row[0]),
        "name": row[1],
        "description": row[2],
        "address": row[3],
        "icon_url": _sign_icon_url(row[4]),
        "website_url": row[5],
        "yelp_url": row[6],
        "google_reviews_url": row[7],
        "avg_rating": float(row[8]) if row[8] else None,
        "service_lat": row[9],
        "service_lng": row[10],
        "service_radius_miles": row[11],
        "banner_image_url": _sign_icon_url(row[12]),
        "business_hours": row[13] or {},
        "role": role,
    }


@app.put("/api/org")
async def update_org(request: Request, authorization: str = Header(None)) -> dict:
    """Update organization profile. Requires admin role."""
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")

        body = await request.json()
        allowed = {"name", "description", "address", "icon_url", "website_url",
                    "yelp_url", "google_reviews_url", "service_radius_miles",
                    "banner_image_url", "business_hours",
                    "service_lat", "service_lng"}
        updates = {k: v for k, v in body.items() if k in allowed}
        if not updates:
            raise HTTPException(400, "No valid fields to update")

        # Serialize JSONB fields
        if "business_hours" in updates:
            idx = list(updates.keys()).index("business_hours")
            values_list = list(updates.values())
            values_list[idx] = json.dumps(values_list[idx])
            updates = dict(zip(updates.keys(), values_list))

        set_clauses = ", ".join(f"{k} = %s" for k in updates)
        values = list(updates.values())
        cursor.execute(
            f"UPDATE organizations SET {set_clauses} WHERE id = %s",
            values + [org_id],
        )
        conn.commit()
    finally:
        conn.close()

    return {"status": "updated"}


@app.get("/api/org/members")
def list_org_members(authorization: str = Header(None)) -> dict:
    """List members of the current user's org."""
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, _ = _get_user_org(cursor, decoded["uid"])
        cursor.execute(
            """SELECT om.id, a.name, a.email, a.icon_url, om.role, om.invite_status
               FROM org_members om
               JOIN accounts a ON a.id = om.account_id
               WHERE om.org_id = %s
               ORDER BY om.invited_at""",
            (org_id,),
        )
        rows = cursor.fetchall()
    finally:
        conn.close()

    return {
        "members": [
            {"id": str(r[0]), "name": r[1], "email": r[2], "icon_url": r[3],
             "role": r[4], "invite_status": r[5]}
            for r in rows
        ]
    }


@app.post("/api/org/members/invite")
async def invite_org_member(request: Request, authorization: str = Header(None)) -> dict:
    """Invite a member to the org by email. Admin role required."""
    decoded = verify_firebase_token(authorization)
    body = await request.json()
    invite_email = body.get("email", "").strip().lower()
    invite_role = body.get("role", "user")
    if not invite_email:
        raise HTTPException(400, "email is required")
    if invite_role not in ("admin", "user"):
        raise HTTPException(400, "role must be 'admin' or 'user'")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")

        # Check if this email has an account
        cursor.execute("SELECT id FROM accounts WHERE email = %s", (invite_email,))
        account_row = cursor.fetchone()

        if account_row:
            # Account exists — link directly
            account_id = account_row[0]
            cursor.execute(
                """INSERT INTO org_members (org_id, account_id, role, invited_email, invite_status)
                   VALUES (%s, %s, %s, %s, 'accepted')
                   ON CONFLICT (org_id, account_id) DO NOTHING
                   RETURNING invite_token""",
                (org_id, account_id, invite_role, invite_email),
            )
        else:
            # No account yet — create a pending invite (no placeholder account)
            # We use a NULL account_id; accept-invite will fill it in
            cursor.execute(
                """INSERT INTO org_members (org_id, account_id, role, invited_email, invite_status)
                   VALUES (%s, NULL, %s, %s, 'pending')
                   RETURNING invite_token""",
                (org_id, invite_role, invite_email),
            )

        token_row = cursor.fetchone()
        invite_token = str(token_row[0]) if token_row else None

        conn.commit()

        # Get org name for email
        cursor.execute("SELECT name FROM organizations WHERE id = %s", (org_id,))
        org_name = cursor.fetchone()[0]
    finally:
        conn.close()

    # Send invite email with deep link
    sendgrid_key = os.environ.get("SENDGRID_API_KEY", "")
    if sendgrid_key and invite_token:
        try:
            from sendgrid import SendGridAPIClient

            invite_url = f"{FRONTEND_URL}/invite?token={invite_token}"
            invite_html = f"""
<h2>You've been invited!</h2>
<p style="font-size:15px;color:#333;line-height:1.6">
  You've been invited to join <strong>{org_name}</strong> on Quoterra as a team member.
  Click below to create an account (or sign in) and join the team.
</p>
<a href="{invite_url}" style="display:inline-block;padding:14px 32px;background:#0055cc;color:#fff;
   text-decoration:none;font-weight:700;font-size:16px;border-radius:8px;margin-top:16px">
  Accept Invitation
</a>
<p style="font-size:13px;color:#888;margin-top:24px">— The Quoterra Team</p>
"""
            sg = SendGridAPIClient(sendgrid_key)
            sg.send(_make_mail(
                from_email="notifications@roomscanalpha.com",
                to_emails=invite_email,
                subject=f"You're invited to {org_name} on Quoterra",
                html_content=invite_html,
            ))
        except Exception as e:
            print(f"[Email] Failed to send invite: {e}")

    return {"status": "invited", "email": invite_email}


@app.post("/api/org/accept-invite")
async def accept_invite(request: Request, authorization: str = Header(None)) -> dict:
    """Accept an org invite using a token. Links the authenticated user to the org."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    email = decoded.get("email", "")
    body = await request.json()
    token = body.get("token", "").strip()
    if not token:
        raise HTTPException(400, "token is required")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        # Look up the invite by token
        cursor.execute(
            """SELECT om.id, om.org_id, om.invited_email, om.invite_status, om.role, o.name
               FROM org_members om
               JOIN organizations o ON o.id = om.org_id
               WHERE om.invite_token = %s""",
            (token,),
        )
        row = cursor.fetchone()
        if not row:
            raise HTTPException(404, "Invite not found or expired")

        member_id, org_id, invited_email, status, invite_role, org_name = row

        if status == "accepted":
            return {"status": "already_accepted", "org_name": org_name}

        # Ensure/create account for this Firebase user
        cursor.execute(
            """INSERT INTO accounts (firebase_uid, email, type)
               VALUES (%s, %s, 'contractor')
               ON CONFLICT (firebase_uid) DO UPDATE SET type = 'contractor'
               RETURNING id""",
            (uid, email),
        )
        account_id = cursor.fetchone()[0]

        # Link the invite to this account
        cursor.execute(
            """UPDATE org_members
               SET account_id = %s, invite_status = 'accepted', accepted_at = now()
               WHERE id = %s""",
            (account_id, member_id),
        )

        conn.commit()
    finally:
        conn.close()

    return {"status": "accepted", "org_id": str(org_id), "org_name": org_name}


@app.delete("/api/org/members/{member_id}")
def remove_org_member(member_id: str, authorization: str = Header(None)) -> dict:
    """Remove a member from the org. Admin role required. Cannot remove yourself."""
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")

        # Don't allow removing yourself
        cursor.execute(
            """SELECT om.account_id FROM org_members om
               JOIN accounts a ON a.id = om.account_id
               WHERE om.id = %s AND om.org_id = %s""",
            (member_id, org_id),
        )
        target = cursor.fetchone()
        if not target:
            raise HTTPException(404, "Member not found")

        cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (decoded["uid"],))
        my_account = cursor.fetchone()
        if my_account and target[0] == my_account[0]:
            raise HTTPException(400, "Cannot remove yourself")

        cursor.execute("DELETE FROM org_members WHERE id = %s AND org_id = %s", (member_id, org_id))
        conn.commit()
    finally:
        conn.close()

    return {"status": "removed"}


@app.delete("/api/org")
def delete_org(authorization: str = Header(None)) -> dict:
    """Soft-delete the organization. Admin role required."""
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")

        cursor.execute("UPDATE organizations SET deleted_at = now() WHERE id = %s", (org_id,))
        cursor.execute("DELETE FROM org_members WHERE org_id = %s", (org_id,))
        conn.commit()
    finally:
        conn.close()

    return {"status": "deleted"}


@app.delete("/api/account")
def delete_account(authorization: str = Header(None)) -> dict:
    """Delete the current user's account and remove org memberships."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (uid,))
        row = cursor.fetchone()
        if not row:
            raise HTTPException(404, "Account not found")
        account_id = row[0]

        # Remove org memberships
        cursor.execute("DELETE FROM org_members WHERE account_id = %s", (account_id,))
        # Delete account
        cursor.execute("DELETE FROM accounts WHERE id = %s", (account_id,))
        conn.commit()
    finally:
        conn.close()

    return {"status": "deleted"}


# --- Gallery endpoints ---

@app.get("/api/org/gallery")
def list_gallery(authorization: str = Header(None)) -> dict:
    """List portfolio images for the current user's org."""
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, _ = _get_user_org(cursor, decoded["uid"])
        cursor.execute(
            """SELECT m.id, m.image_type, m.image_url, m.before_image_url, m.caption,
                      m.sort_order, m.media_type, m.album_id,
                      a.title AS album_title, a.service_id
               FROM org_work_images m
               LEFT JOIN albums a ON a.id = m.album_id
               WHERE m.org_id = %s
               ORDER BY m.sort_order, m.created_at""",
            (org_id,),
        )
        media_rows = cursor.fetchall()

        # Fetch albums for this org
        cursor.execute(
            """SELECT a.id, a.title, a.description, a.service_id, a.rfq_id, a.created_at,
                      s.name AS service_name
               FROM albums a
               LEFT JOIN services s ON s.id = a.service_id
               WHERE a.org_id = %s
               ORDER BY a.created_at DESC""",
            (org_id,),
        )
        album_rows = cursor.fetchall()
    finally:
        conn.close()

    # Generate signed read URLs
    _credentials.refresh(_auth_request)
    bucket = storage_client.bucket(BUCKET_NAME)

    def _sign_read(url_or_path):
        if not url_or_path:
            return None
        prefix = f"https://storage.googleapis.com/{BUCKET_NAME}/"
        blob_path = url_or_path.replace(prefix, "") if url_or_path.startswith("http") else url_or_path
        return bucket.blob(blob_path).generate_signed_url(
            version="v4", expiration=datetime.timedelta(days=7), method="GET",
            service_account_email=SIGNING_SA_EMAIL, access_token=_credentials.token,
        )

    return {
        "media": [
            {"id": str(r[0]), "image_type": r[1], "image_url": _sign_read(r[2]),
             "before_image_url": _sign_read(r[3]), "caption": r[4], "sort_order": r[5],
             "media_type": r[6] or "image", "album_id": str(r[7]) if r[7] else None,
             "album_title": r[8]}
            for r in media_rows
        ],
        "albums": [
            {"id": str(r[0]), "title": r[1], "description": r[2],
             "service_id": str(r[3]) if r[3] else None, "rfq_id": str(r[4]) if r[4] else None,
             "created_at": r[5].isoformat() if r[5] else None, "service_name": r[6]}
            for r in album_rows
        ],
    }


@app.get("/api/org/gallery/upload-url")
def gallery_upload_url(content_type: str = "image/jpeg", authorization: str = Header(None)) -> dict:
    """Get a signed GCS URL for uploading a portfolio image or video."""
    decoded = verify_firebase_token(authorization)

    allowed_types = {
        "image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp",
        "video/mp4": ".mp4", "video/quicktime": ".mov", "video/webm": ".webm",
    }
    if content_type not in allowed_types:
        raise HTTPException(400, f"Unsupported content type. Allowed: {', '.join(allowed_types)}")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")
    finally:
        conn.close()

    image_id = str(uuid.uuid4())
    ext = allowed_types[content_type]
    blob_path = f"orgs/{org_id}/gallery/{image_id}{ext}"

    _credentials.refresh(_auth_request)
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(blob_path)
    url = blob.generate_signed_url(
        version="v4",
        expiration=datetime.timedelta(minutes=SIGNED_URL_EXPIRY_MINUTES),
        method="PUT",
        content_type=content_type,
        service_account_email=SIGNING_SA_EMAIL,
        access_token=_credentials.token,
    )

    return {"upload_url": url, "blob_path": blob_path, "image_id": image_id, "content_type": content_type}


@app.post("/api/org/gallery")
async def add_gallery_image(request: Request, authorization: str = Header(None)) -> dict:
    """Save a portfolio media record after uploading to GCS."""
    decoded = verify_firebase_token(authorization)
    body = await request.json()
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")

        image_url = body.get("image_url", "")
        image_type = body.get("image_type", "single")
        before_image_url = body.get("before_image_url")
        caption = body.get("caption", "")
        media_type = body.get("media_type", "image")
        album_id = body.get("album_id")

        cursor.execute(
            """INSERT INTO org_work_images (org_id, image_type, image_url, before_image_url, caption, media_type, album_id)
               VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id""",
            (org_id, image_type, image_url, before_image_url, caption, media_type, album_id),
        )
        image_id = cursor.fetchone()[0]
        conn.commit()
    finally:
        conn.close()

    return {"id": str(image_id), "status": "created"}


@app.delete("/api/org/gallery/{image_id}")
def delete_gallery_image(image_id: str, authorization: str = Header(None)) -> dict:
    """Delete a portfolio image."""
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")
        cursor.execute(
            "DELETE FROM org_work_images WHERE id = %s AND org_id = %s",
            (image_id, org_id),
        )
        conn.commit()
    finally:
        conn.close()

    return {"status": "deleted"}


# --- Album endpoints ---

@app.post("/api/org/albums")
async def create_album(request: Request, authorization: str = Header(None)) -> dict:
    """Create a new album."""
    decoded = verify_firebase_token(authorization)
    body = await request.json()
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")

        title = body.get("title", "").strip()
        if not title:
            raise HTTPException(400, "title is required")

        cursor.execute(
            """INSERT INTO albums (org_id, title, description, service_id, rfq_id)
               VALUES (%s, %s, %s, %s, %s) RETURNING id""",
            (org_id, title, body.get("description"), body.get("service_id"), body.get("rfq_id")),
        )
        album_id = cursor.fetchone()[0]
        conn.commit()
    finally:
        conn.close()

    return {"id": str(album_id), "status": "created"}


@app.put("/api/org/albums/{album_id}")
async def update_album(album_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Update album title, description, service, or job link."""
    decoded = verify_firebase_token(authorization)
    body = await request.json()
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")

        allowed = {"title", "description", "service_id", "rfq_id"}
        updates = {k: v for k, v in body.items() if k in allowed}
        if not updates:
            raise HTTPException(400, "No valid fields")

        set_clauses = ", ".join(f"{k} = %s" for k in updates)
        values = list(updates.values())
        cursor.execute(
            f"UPDATE albums SET {set_clauses} WHERE id = %s AND org_id = %s",
            values + [album_id, org_id],
        )
        conn.commit()
    finally:
        conn.close()

    return {"status": "updated"}


@app.delete("/api/org/albums/{album_id}")
def delete_album(album_id: str, authorization: str = Header(None)) -> dict:
    """Delete an album. Media items are unlinked (not deleted)."""
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")

        # Unlink media from this album
        cursor.execute("UPDATE org_work_images SET album_id = NULL WHERE album_id = %s AND org_id = %s", (album_id, org_id))
        cursor.execute("DELETE FROM albums WHERE id = %s AND org_id = %s", (album_id, org_id))
        conn.commit()
    finally:
        conn.close()

    return {"status": "deleted"}


# --- Public org search + profile ---

@app.get("/api/contractors/search")
def search_contractors(
    service: str = "",
    location: str = "",
    q: str = "",
) -> list:
    """Public contractor search. No auth required.

    Filters:
      - service: exact service name match via org_services
      - location: geocode to lat/lng, filter orgs within service_radius_miles
      - q: text search on org name or description
    """
    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        # Build query
        where_clauses = ["o.deleted_at IS NULL"]
        params: list = []
        joins = ""

        if service:
            joins += """
                JOIN org_services os ON os.org_id = o.id
                JOIN services sv ON sv.id = os.service_id"""
            where_clauses.append("sv.name = %s")
            params.append(service)

        if q:
            where_clauses.append("(o.name ILIKE %s OR o.description ILIKE %s)")
            params.extend([f"%{q}%", f"%{q}%"])

        # Location filtering: geocode then distance check
        search_lat = None
        search_lng = None
        if location:
            geo = _geocode_location(location)
            if geo:
                search_lat, search_lng = geo
                # Haversine distance filter — include orgs whose service area covers this point
                where_clauses.append("""
                    (o.service_lat IS NOT NULL AND o.service_lng IS NOT NULL AND
                     (3959 * acos(LEAST(1.0, cos(radians(%s)) * cos(radians(o.service_lat))
                       * cos(radians(o.service_lng) - radians(%s))
                       + sin(radians(%s)) * sin(radians(o.service_lat)))))
                     <= COALESCE(o.service_radius_miles, 50))
                """)
                params.extend([search_lat, search_lng, search_lat])

        where_sql = " AND ".join(where_clauses)
        cursor.execute(
            f"""SELECT DISTINCT o.id, o.name, o.description, o.address, o.icon_url,
                       o.website_url, o.yelp_url, o.google_reviews_url, o.avg_rating
                FROM organizations o
                {joins}
                WHERE {where_sql}
                ORDER BY o.avg_rating DESC NULLS LAST, o.name
                LIMIT 50""",
            params,
        )
        org_rows = cursor.fetchall()

        if not org_rows:
            return []

        org_ids = [str(r[0]) for r in org_rows]

        # Batch-fetch gallery previews (up to 6 per org, before/after first)
        cursor.execute(
            """SELECT m.org_id, m.id, m.image_url, m.before_image_url,
                      m.image_type, m.caption
               FROM org_work_images m
               WHERE m.org_id = ANY(%s)
               ORDER BY (CASE WHEN m.image_type = 'before_after' THEN 0 ELSE 1 END),
                        m.sort_order, m.created_at
            """,
            (org_ids,),
        )
        gallery_by_org: dict = {}
        for gr in cursor.fetchall():
            oid = str(gr[0])
            if oid not in gallery_by_org:
                gallery_by_org[oid] = []
            if len(gallery_by_org[oid]) < 6:
                gallery_by_org[oid].append(gr)

    finally:
        conn.close()

    # Sign image URLs
    _credentials.refresh(_auth_request)
    _bucket = storage_client.bucket(BUCKET_NAME)
    _prefix = f"https://storage.googleapis.com/{BUCKET_NAME}/"

    def _sign(val):
        if not val:
            return None
        blob_path = val.replace(_prefix, "") if val.startswith("http") else val
        return _bucket.blob(blob_path).generate_signed_url(
            version="v4", expiration=datetime.timedelta(days=7), method="GET",
            service_account_email=SIGNING_SA_EMAIL, access_token=_credentials.token,
        )

    results = []
    for row in org_rows:
        oid = str(row[0])
        gallery = gallery_by_org.get(oid, [])
        results.append({
            "id": oid,
            "name": row[1],
            "description": row[2],
            "address": row[3],
            "icon_url": _sign(row[4]),
            "website_url": row[5],
            "yelp_url": row[6],
            "google_reviews_url": row[7],
            "review_rating": float(row[8]) if row[8] else None,
            "review_count": None,
            "gallery": [
                {"id": str(g[1]), "image_url": _sign(g[2]),
                 "before_image_url": _sign(g[3]),
                 "image_type": g[4] or "image", "caption": g[5]}
                for g in gallery
            ],
        })
    return results


def _geocode_location(location: str):
    """Geocode a location string to (lat, lng) using Google Maps Geocoding API.
    Returns None if geocoding fails."""
    api_key = os.environ.get("GOOGLE_MAPS_API_KEY", "")
    if not api_key:
        return None
    try:
        encoded = urllib.parse.quote(location)
        url = f"https://maps.googleapis.com/maps/api/geocode/json?address={encoded}&key={api_key}"
        with urllib.request.urlopen(url, timeout=5) as resp:
            data = json.loads(resp.read())
        if data.get("status") == "OK" and data.get("results"):
            loc = data["results"][0]["geometry"]["location"]
            return (loc["lat"], loc["lng"])
    except Exception:
        pass
    return None


@app.get("/api/orgs/{org_id}")
def get_public_org(org_id: str) -> dict:
    """Public org profile page data. No auth required."""
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """SELECT id, name, description, address, icon_url, website_url,
                      yelp_url, google_reviews_url, avg_rating,
                      service_lat, service_lng, service_radius_miles,
                      banner_image_url, business_hours
               FROM organizations WHERE id = %s AND deleted_at IS NULL""",
            (org_id,),
        )
        row = cursor.fetchone()
        if not row:
            raise HTTPException(404, "Organization not found")

        # Services
        cursor.execute(
            """SELECT s.id, s.name FROM org_services os
               JOIN services s ON s.id = os.service_id
               WHERE os.org_id = %s ORDER BY s.name""",
            (org_id,),
        )
        svc_rows = cursor.fetchall()

        # Gallery (all media, grouped by album)
        cursor.execute(
            """SELECT m.id, m.image_url, m.before_image_url, m.caption,
                      m.media_type, m.album_id, a.title AS album_title,
                      a.service_id, s.name AS service_name
               FROM org_work_images m
               LEFT JOIN albums a ON a.id = m.album_id
               LEFT JOIN services s ON s.id = a.service_id
               WHERE m.org_id = %s
               ORDER BY m.sort_order, m.created_at""",
            (org_id,),
        )
        media_rows = cursor.fetchall()

        # Members (names only)
        cursor.execute(
            """SELECT a.name, a.icon_url, om.role FROM org_members om
               JOIN accounts a ON a.id = om.account_id
               WHERE om.org_id = %s AND om.invite_status = 'accepted'
               ORDER BY om.invited_at""",
            (org_id,),
        )
        member_rows = cursor.fetchall()
    finally:
        conn.close()

    # Sign image URLs
    _credentials.refresh(_auth_request)
    _bucket = storage_client.bucket(BUCKET_NAME)
    _prefix = f"https://storage.googleapis.com/{BUCKET_NAME}/"

    def _sign(val):
        if not val:
            return None
        blob_path = val.replace(_prefix, "") if val.startswith("http") else val
        return _bucket.blob(blob_path).generate_signed_url(
            version="v4", expiration=datetime.timedelta(days=7), method="GET",
            service_account_email=SIGNING_SA_EMAIL, access_token=_credentials.token,
        )

    return {
        "id": str(row[0]),
        "name": row[1],
        "description": row[2],
        "address": row[3],
        "icon_url": _sign(row[4]),
        "website_url": row[5],
        "yelp_url": row[6],
        "google_reviews_url": row[7],
        "avg_rating": float(row[8]) if row[8] else None,
        "service_lat": row[9],
        "service_lng": row[10],
        "service_radius_miles": row[11],
        "banner_image_url": _sign(row[12]),
        "business_hours": row[13] or {},
        "services": [{"id": str(r[0]), "name": r[1]} for r in svc_rows],
        "gallery": [
            {"id": str(r[0]), "image_url": _sign(r[1]), "before_image_url": _sign(r[2]),
             "caption": r[3], "media_type": r[4] or "image",
             "album_title": r[5], "service_name": r[8]}
            for r in media_rows
        ],
        "team": [
            {"name": r[0], "icon_url": _sign(r[1]), "role": r[2]}
            for r in member_rows
        ],
    }


@app.get("/api/org/banner-upload-url")
def org_banner_upload_url(content_type: str = "image/jpeg", authorization: str = Header(None)) -> dict:
    """Get a signed GCS URL for uploading an org banner image."""
    decoded = verify_firebase_token(authorization)
    allowed_types = {"image/jpeg": ".jpg", "image/png": ".png", "image/webp": ".webp"}
    if content_type not in allowed_types:
        raise HTTPException(400, "Unsupported content type")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")
    finally:
        conn.close()

    ext = allowed_types[content_type]
    blob_path = f"orgs/{org_id}/banner{ext}"

    _credentials.refresh(_auth_request)
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(blob_path)
    url = blob.generate_signed_url(
        version="v4", expiration=datetime.timedelta(minutes=SIGNED_URL_EXPIRY_MINUTES),
        method="PUT", content_type=content_type,
        service_account_email=SIGNING_SA_EMAIL, access_token=_credentials.token,
    )

    return {"upload_url": url, "blob_path": blob_path, "content_type": content_type}


# --- Hire / Accept bid ---

@app.post("/api/rfqs/{rfq_id}/accept-bid")
async def accept_bid(rfq_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Accept a bid. Sets bid status to 'accepted', rejects others, updates RFQ."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    body = await request.json()
    bid_id = body.get("bid_id")
    if not bid_id:
        raise HTTPException(400, "bid_id is required")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        # Verify the user owns this RFQ
        cursor.execute("SELECT user_id, homeowner_account_id FROM rfqs WHERE id = %s", (rfq_id,))
        rfq_row = cursor.fetchone()
        if not rfq_row:
            raise HTTPException(404, "RFQ not found")

        rfq_uid, rfq_account_id = rfq_row
        # Check ownership via Firebase UID or account
        if rfq_uid != uid:
            cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (uid,))
            acct = cursor.fetchone()
            if not acct or (rfq_account_id and acct[0] != rfq_account_id):
                raise HTTPException(403, "Not the owner of this RFQ")

        # Accept the chosen bid, reject all others
        cursor.execute("UPDATE bids SET status = 'accepted' WHERE id = %s AND rfq_id = %s", (bid_id, rfq_id))
        cursor.execute("UPDATE bids SET status = 'rejected' WHERE rfq_id = %s AND id != %s AND status = 'pending'", (rfq_id, bid_id))
        cursor.execute("UPDATE rfqs SET hired_bid_id = %s, status = 'completed' WHERE id = %s", (bid_id, rfq_id))

        # Post acceptance/rejection events into the relevant inbox threads
        cursor.execute("SELECT org_id FROM bids WHERE id = %s", (bid_id,))
        winning_org_row = cursor.fetchone()
        if winning_org_row and winning_org_row[0]:
            try:
                _post_bid_decision_events(
                    cursor, rfq_id=rfq_id, winning_bid_id=bid_id,
                    winning_org_id=str(winning_org_row[0]),
                )
            except Exception as e:
                print(f"[Inbox] Failed to post bid-decision events: {e}")

        conn.commit()

        # Fetch data for notification emails
        cursor.execute(
            """SELECT b.price_cents, b.description, b.pdf_url, b.received_at, b.org_id,
                      r.title, r.description AS rfq_desc, r.address, r.created_at,
                      ha.name AS ho_name, ha.email AS ho_email, ha.phone AS ho_phone,
                      o.name AS org_name
               FROM bids b
               JOIN rfqs r ON r.id = b.rfq_id
               LEFT JOIN accounts ha ON ha.id = r.homeowner_account_id
               LEFT JOIN organizations o ON o.id = b.org_id
               WHERE b.id = %s""",
            (bid_id,),
        )
        email_row = cursor.fetchone()

        # Get winning org member emails
        winning_emails = []
        if email_row and email_row[4]:
            cursor.execute(
                """SELECT a.email FROM org_members om
                   JOIN accounts a ON a.id = om.account_id
                   WHERE om.org_id = %s AND om.invite_status = 'accepted' AND a.email IS NOT NULL""",
                (email_row[4],),
            )
            winning_emails = [r[0] for r in cursor.fetchall() if r[0] and "@unknown" not in r[0]]

        # Get losing org member emails (grouped by org)
        cursor.execute(
            """SELECT DISTINCT b2.org_id FROM bids b2
               WHERE b2.rfq_id = %s AND b2.id != %s AND b2.org_id IS NOT NULL AND b2.status = 'rejected'""",
            (rfq_id, bid_id),
        )
        losing_org_ids = [str(r[0]) for r in cursor.fetchall()]
        losing_emails = []
        for lo_id in losing_org_ids:
            cursor.execute(
                """SELECT a.email FROM org_members om
                   JOIN accounts a ON a.id = om.account_id
                   WHERE om.org_id = %s AND om.invite_status = 'accepted' AND a.email IS NOT NULL""",
                (lo_id,),
            )
            losing_emails.extend([r[0] for r in cursor.fetchall() if r[0] and "@unknown" not in r[0]])
    finally:
        conn.close()

    # Send notification emails
    if email_row:
        price_cents, bid_desc, bid_pdf, bid_received, org_id_val, \
            rfq_title, rfq_desc, rfq_addr, rfq_created, \
            ho_name, ho_email, ho_phone, org_name = email_row

        _send_bid_accepted_emails(
            rfq_id=rfq_id,
            rfq_title=rfq_title or "Project",
            rfq_desc=rfq_desc,
            rfq_addr=rfq_addr,
            rfq_created=rfq_created,
            price_cents=price_cents,
            bid_desc=bid_desc,
            bid_pdf=bid_pdf,
            bid_received=bid_received,
            ho_name=ho_name,
            ho_email=ho_email,
            ho_phone=ho_phone,
            org_name=org_name or "Contractor",
            winning_emails=winning_emails,
            losing_emails=losing_emails,
        )

    return {"status": "accepted", "bid_id": bid_id}


def _send_bid_accepted_emails(*, rfq_id, rfq_title, rfq_desc, rfq_addr, rfq_created,
                               price_cents, bid_desc, bid_pdf, bid_received,
                               ho_name, ho_email, ho_phone, org_name,
                               winning_emails, losing_emails):
    """Send bid acceptance notifications to winner, homeowner, and losers."""
    sendgrid_key = os.environ.get("SENDGRID_API_KEY", "")
    if not sendgrid_key:
        return
    try:
        from sendgrid import SendGridAPIClient

        sg = SendGridAPIClient(sendgrid_key)
        base_url = os.environ.get("SERVICE_URL", "https://scan-api-839349778883.us-central1.run.app")
        scan_url = f"{base_url}/quote/{rfq_id}"
        price_str = f"${price_cents / 100:,.0f}" if price_cents else "N/A"
        now_str = datetime.datetime.now().strftime("%B %d, %Y")
        posted_str = rfq_created.strftime("%B %d, %Y") if rfq_created else "N/A"
        bid_date_str = bid_received.strftime("%B %d, %Y") if bid_received else "N/A"

        detail_rows = f"""
<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Project</td><td style="padding:6px 0">{rfq_title}</td></tr>
<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Address</td><td style="padding:6px 0">{rfq_addr or 'N/A'}</td></tr>
<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Total Price</td><td style="padding:6px 0;font-size:18px;font-weight:700">{price_str}</td></tr>
<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Posted</td><td style="padding:6px 0">{posted_str}</td></tr>
<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Quote Submitted</td><td style="padding:6px 0">{bid_date_str}</td></tr>
<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Accepted</td><td style="padding:6px 0">{now_str}</td></tr>"""

        if rfq_desc:
            detail_rows += f'\n<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Project Description</td><td style="padding:6px 0">{rfq_desc}</td></tr>'
        if bid_desc:
            detail_rows += f'\n<tr><td style="padding:6px 16px 6px 0;font-weight:600;color:#555">Work Description</td><td style="padding:6px 0">{bid_desc}</td></tr>'

        pdf_link = ""
        if bid_pdf:
            pdf_link = f'<p style="margin-top:12px"><a href="{bid_pdf}" style="color:#0055cc;font-weight:600">View Attached Quote (PDF)</a></p>'

        # 1. Email to winning contractor org members
        for email_addr in winning_emails:
            winner_html = f"""
<h2 style="color:#34c759">You won the job!</h2>
<p style="font-size:15px;color:#333;line-height:1.6">
  Congratulations! Your quote for <strong>{rfq_title}</strong> has been accepted.
</p>
<h3 style="margin-top:20px;font-size:14px;color:#555">Homeowner Contact</h3>
<table style="border-collapse:collapse;font-size:15px;margin:8px 0">
  <tr><td style="padding:4px 16px 4px 0;font-weight:600;color:#555">Name</td><td style="padding:4px 0">{ho_name or 'N/A'}</td></tr>
  <tr><td style="padding:4px 16px 4px 0;font-weight:600;color:#555">Email</td><td style="padding:4px 0"><a href="mailto:{ho_email}" style="color:#0055cc">{ho_email or 'N/A'}</a></td></tr>
  <tr><td style="padding:4px 16px 4px 0;font-weight:600;color:#555">Phone</td><td style="padding:4px 0">{ho_phone or 'N/A'}</td></tr>
</table>
<h3 style="margin-top:20px;font-size:14px;color:#555">Job Details</h3>
<table style="border-collapse:collapse;font-size:15px;margin:8px 0">
  {detail_rows}
</table>
{pdf_link}
<a href="{scan_url}" style="display:inline-block;padding:14px 32px;background:#0055cc;color:#fff;
   text-decoration:none;font-weight:700;font-size:16px;border-radius:8px;margin-top:20px">
  View 3D Scan
</a>
<p style="font-size:13px;color:#888;margin-top:24px">&mdash; The Quoterra Team</p>
"""
            sg.send(_make_mail(
                from_email="notifications@roomscanalpha.com",
                to_emails=email_addr,
                subject=f"You won the job: {rfq_title}",
                html_content=winner_html,
            ))

        # 2. Email to homeowner
        if ho_email and "@unknown" not in ho_email:
            homeowner_html = f"""
<h2>You hired {org_name}!</h2>
<p style="font-size:15px;color:#333;line-height:1.6">
  Great news! You've selected <strong>{org_name}</strong> for your project <strong>{rfq_title}</strong>.
  They'll be in touch soon to get started.
</p>
<h3 style="margin-top:20px;font-size:14px;color:#555">Contractor</h3>
<table style="border-collapse:collapse;font-size:15px;margin:8px 0">
  <tr><td style="padding:4px 16px 4px 0;font-weight:600;color:#555">Company</td><td style="padding:4px 0">{org_name}</td></tr>
</table>
<h3 style="margin-top:20px;font-size:14px;color:#555">Job Details</h3>
<table style="border-collapse:collapse;font-size:15px;margin:8px 0">
  {detail_rows}
</table>
{pdf_link}
<a href="{scan_url}" style="display:inline-block;padding:14px 32px;background:#0055cc;color:#fff;
   text-decoration:none;font-weight:700;font-size:16px;border-radius:8px;margin-top:20px">
  View Project
</a>
<p style="font-size:13px;color:#888;margin-top:24px">&mdash; The Quoterra Team</p>
"""
            sg.send(_make_mail(
                from_email="notifications@roomscanalpha.com",
                to_emails=ho_email,
                subject=f"You hired {org_name} for {rfq_title}",
                html_content=homeowner_html,
            ))

        # 3. Emails to losing contractors
        for email_addr in losing_emails:
            loser_html = f"""
<h2>Update on {rfq_title}</h2>
<p style="font-size:15px;color:#333;line-height:1.6">
  The homeowner has selected another contractor for <strong>{rfq_title}</strong>
  at <strong>{rfq_addr or 'the project address'}</strong>.
  Thank you for submitting your quote &mdash; we appreciate your time and look forward to connecting you with future opportunities.
</p>
<a href="{base_url}/org?tab=jobs" style="display:inline-block;padding:14px 32px;background:#0055cc;color:#fff;
   text-decoration:none;font-weight:700;font-size:16px;border-radius:8px;margin-top:16px">
  View Jobs
</a>
<p style="font-size:13px;color:#888;margin-top:24px">&mdash; The Quoterra Team</p>
"""
            sg.send(_make_mail(
                from_email="notifications@roomscanalpha.com",
                to_emails=email_addr,
                subject=f"Update on {rfq_title}",
                html_content=loser_html,
            ))

    except Exception as e:
        print(f"[Email] Failed to send bid acceptance emails: {e}")


# --- Jobs endpoint (contractor view of RFQs) ---

@app.get("/api/org/jobs")
def list_org_jobs(authorization: str = Header(None)) -> dict:
    """List RFQs relevant to this org: ones they've bid on + available new ones."""
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, _ = _get_user_org(cursor, decoded["uid"])

        # 1. RFQs this org has bid on (pending/won/lost)
        cursor.execute(
            """SELECT r.id, r.title, r.description, r.address, r.status, r.created_at,
                      b.id AS bid_id, b.price_cents, b.status AS bid_status, b.received_at,
                      a.name AS homeowner_name, a.icon_url AS homeowner_icon, a.email AS homeowner_email,
                      b.description AS bid_description, b.pdf_url AS bid_pdf_url,
                      b.rfq_modified_after_bid, r.deleted_at AS rfq_deleted_at
               FROM bids b
               JOIN rfqs r ON r.id = b.rfq_id
               LEFT JOIN accounts a ON a.id = r.homeowner_account_id
               WHERE b.org_id = %s
               ORDER BY b.received_at DESC""",
            (org_id,),
        )
        bid_rows = cursor.fetchall()
        bid_rfq_ids = {str(row[0]) for row in bid_rows}

        # Get org location + radius for geo-filtering
        cursor.execute(
            "SELECT service_lat, service_lng, service_radius_miles FROM organizations WHERE id = %s",
            (org_id,),
        )
        org_geo = cursor.fetchone()
        org_lat, org_lng, org_radius = org_geo if org_geo else (None, None, None)

        # Get account IDs of org members (to exclude their own RFQs)
        cursor.execute(
            "SELECT account_id FROM org_members WHERE org_id = %s AND account_id IS NOT NULL",
            (org_id,),
        )
        member_account_ids = [str(r[0]) for r in cursor.fetchall()]

        # 2. Available RFQs this org hasn't bid on (status = scan_ready)
        # If org has lat/lng, use haversine filter; otherwise show all
        # Exclude RFQs owned by org members
        exclude_clause = ""
        exclude_params: list = []
        if member_account_ids:
            placeholders = ",".join(["%s"] * len(member_account_ids))
            exclude_clause = f"AND (r.homeowner_account_id IS NULL OR r.homeowner_account_id NOT IN ({placeholders}))"
            exclude_params = member_account_ids

        cursor.execute(
            f"""SELECT r.id, r.title, r.description, r.address, r.status, r.created_at,
                      a.name AS homeowner_name, a.icon_url AS homeowner_icon, a.email AS homeowner_email
               FROM rfqs r
               LEFT JOIN accounts a ON a.id = r.homeowner_account_id
               WHERE r.status = 'scan_ready' AND r.deleted_at IS NULL {exclude_clause}
               ORDER BY r.created_at DESC
               LIMIT 50""",
            exclude_params,
        )
        avail_rows = cursor.fetchall()

        # Batch-fetch unified bid attachments so we can refresh pdf_url and
        # expose bid images. Same pattern as list_bids.
        bid_ids_for_lookup = [row[6] for row in bid_rows]
        attachments_by_bid: dict[str, dict] = {}
        if bid_ids_for_lookup:
            placeholders = ",".join(["%s"] * len(bid_ids_for_lookup))
            cursor.execute(
                f"""SELECT ba.bid_id, ba.role, a.id, a.blob_path, a.content_type, a.name, a.size_bytes
                    FROM bid_attachments ba
                    JOIN attachments a ON a.id = ba.attachment_id
                    WHERE ba.bid_id IN ({placeholders})
                    ORDER BY ba.created_at""",
                bid_ids_for_lookup,
            )
            for bid_id_val, role, aid, bp, ct, nm, sb in cursor.fetchall():
                entry = attachments_by_bid.setdefault(str(bid_id_val), {"pdf_blob_path": None, "images": []})
                if role == "quote_pdf":
                    entry["pdf_blob_path"] = bp
                else:
                    entry["images"].append({
                        "attachment_id": str(aid),
                        "blob_path": bp, "content_type": ct, "name": nm, "size_bytes": sb,
                    })

        # Batch-fetch RFQ-level attachments so contractor Job cards can surface
        # media the homeowner has shared about the project (whether via chat or
        # direct upload). Keyed by rfq_id across both bid-based and available jobs.
        all_rfq_ids = list({str(row[0]) for row in bid_rows} | {str(row[0]) for row in avail_rows})
        rfq_attachments_by_rfq: dict[str, list] = {rid: [] for rid in all_rfq_ids}
        if all_rfq_ids:
            placeholders = ",".join(["%s"] * len(all_rfq_ids))
            cursor.execute(
                f"""SELECT ra.rfq_id, a.id, a.blob_path, a.content_type, a.name, a.size_bytes
                    FROM rfq_attachments ra
                    JOIN attachments a ON a.id = ra.attachment_id
                    WHERE ra.rfq_id IN ({placeholders})
                    ORDER BY ra.created_at""",
                all_rfq_ids,
            )
            for rid, aid, bp, ct, nm, sb in cursor.fetchall():
                rfq_attachments_by_rfq.setdefault(str(rid), []).append({
                    "attachment_id": str(aid),
                    "blob_path": bp, "content_type": ct, "name": nm, "size_bytes": sb,
                })
    finally:
        conn.close()

    jobs = []

    # Add bid-based jobs
    for row in bid_rows:
        rfq_id, title, desc, addr, rfq_status, created, bid_id, price, bid_status, received, ho_name, ho_icon, ho_email, bid_desc, bid_pdf, bid_modified_flag, rfq_deleted_at = row
        job_status = "pending"
        if bid_status == "accepted":
            job_status = "won"
        elif bid_status == "rejected":
            job_status = "lost"

        att_info = attachments_by_bid.get(str(bid_id), {"pdf_blob_path": None, "images": []})
        effective_pdf_url = bid_pdf
        if att_info["pdf_blob_path"]:
            try:
                effective_pdf_url = _sign_attachment_get(att_info["pdf_blob_path"])
            except Exception:
                pass

        jobs.append({
            "rfq_id": str(rfq_id),
            "title": title or "Untitled Project",
            "description": desc,
            "address": addr,
            "created_at": created.isoformat() if created else None,
            "homeowner": {"name": ho_name, "icon_url": ho_icon, "email": ho_email},
            "bid": {
                "id": str(bid_id),
                "price_cents": price,
                "status": bid_status or "pending",
                "received_at": received.isoformat() if received else None,
                "description": bid_desc,
                "pdf_url": effective_pdf_url,
                "attachments": _resolve_attachments(att_info["images"]),
                "rfq_modified_after_bid": bool(bid_modified_flag),
            },
            "rfq_attachments": _resolve_attachments(rfq_attachments_by_rfq.get(str(rfq_id), [])),
            "job_status": job_status,
            "rfq_deleted": rfq_deleted_at is not None,
        })

    # Add available (new) jobs
    for row in avail_rows:
        rfq_id, title, desc, addr, rfq_status, created, ho_name, ho_icon, ho_email = row
        if str(rfq_id) in bid_rfq_ids:
            continue  # Already have a bid on this one

        jobs.append({
            "rfq_id": str(rfq_id),
            "title": title or "Untitled Project",
            "description": desc,
            "address": addr,
            "created_at": created.isoformat() if created else None,
            "homeowner": {"name": ho_name, "icon_url": ho_icon, "email": ho_email},
            "bid": None,
            "rfq_attachments": _resolve_attachments(rfq_attachments_by_rfq.get(str(rfq_id), [])),
            "job_status": "new",
        })

    return {"jobs": jobs}


# --- Services endpoint ---

@app.get("/api/services")
def list_services() -> dict:
    """List all active services. Public endpoint."""
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute("SELECT id, name, description, icon_url FROM services WHERE is_active = TRUE ORDER BY name")
        rows = cursor.fetchall()
    finally:
        conn.close()

    return {
        "services": [
            {"id": str(r[0]), "name": r[1], "description": r[2], "icon_url": r[3]}
            for r in rows
        ]
    }


@app.get("/api/org/services")
def get_org_services(authorization: str = Header(None)) -> dict:
    """List services declared by the current user's org."""
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, _ = _get_user_org(cursor, decoded["uid"])
        cursor.execute(
            """SELECT s.id, s.name, os.years_experience
               FROM org_services os
               JOIN services s ON s.id = os.service_id
               WHERE os.org_id = %s
               ORDER BY s.name""",
            (org_id,),
        )
        rows = cursor.fetchall()
    finally:
        conn.close()

    return {
        "services": [
            {"id": str(r[0]), "name": r[1], "years_experience": r[2]}
            for r in rows
        ]
    }


@app.put("/api/org/services")
async def update_org_services(request: Request, authorization: str = Header(None)) -> dict:
    """Update org's declared services. Body: { service_ids: [uuid, ...] }"""
    decoded = verify_firebase_token(authorization)
    body = await request.json()
    service_ids = body.get("service_ids", [])

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        org_id, role = _get_user_org(cursor, decoded["uid"])
        if role != "admin":
            raise HTTPException(403, "Admin role required")

        cursor.execute("DELETE FROM org_services WHERE org_id = %s", (org_id,))
        for sid in service_ids:
            cursor.execute(
                "INSERT INTO org_services (org_id, service_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                (org_id, sid),
            )
        conn.commit()
    finally:
        conn.close()

    return {"status": "updated", "count": len(service_ids)}


# --- Conversations / Inbox ---
#
# A conversation is a persistent thread between one homeowner and one contractor
# org, scoped to a single RFQ. Messages come in three kinds:
#   - text: user-authored message with optional attachments (images + files)
#   - event: system-generated lifecycle marker (bid submitted, accepted, etc.)
#   - bid: rich bid card embedded in the thread (snapshot of a bids row)
#
# The design calls for unified inboxes on both sides. Threads surface unread
# counts, last-message previews, and a derived kind label ('rfq' | 'bid' | 'won'
# | 'msg') computed from the current bid state of the associated RFQ.

ATTACHMENT_TYPES = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/gif": ".gif",
    "image/heic": ".heic",
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "video/webm": ".webm",
    "application/pdf": ".pdf",
}

ATTACHMENT_MAX_SIGNED_URL_HOURS = 6


def _sign_attachment_get(blob_path: str) -> str:
    """Generate a short-lived signed read URL for an attachment blob."""
    if not _credentials.token or not _credentials.valid:
        _credentials.refresh(_auth_request)
    bucket = storage_client.bucket(BUCKET_NAME)
    return bucket.blob(blob_path).generate_signed_url(
        version="v4",
        expiration=datetime.timedelta(hours=ATTACHMENT_MAX_SIGNED_URL_HOURS),
        method="GET",
        service_account_email=SIGNING_SA_EMAIL,
        access_token=_credentials.token,
    )


def _resolve_attachments(attachments: Optional[list]) -> list:
    """Add signed `download_url` to each attachment entry for client rendering.

    Accepts either legacy JSONB-shaped dicts or new attachments-table rows — both
    have `blob_path` + `content_type` + `name` + `size_bytes`.
    """
    if not attachments:
        return []
    out = []
    for a in attachments:
        if not isinstance(a, dict):
            continue
        entry = dict(a)
        bp = a.get("blob_path")
        if bp:
            try:
                entry["download_url"] = _sign_attachment_get(bp)
            except Exception:
                entry["download_url"] = None
        out.append(entry)
    return out


# --- Unified attachment helpers (migration 020) ---
#
# During the dual-phase rollout the scan-api writes both to the legacy shapes
# (bids.pdf_url, messages.attachments JSONB) AND the new unified tables
# (attachments, bid_attachments, rfq_attachments, message_attachments).
# Reads prefer the unified tables and fall back to legacy shapes so the API
# keeps working before migration 020_backfill.py has run. Migration 021 will
# drop the legacy columns once the unified path is stable in production.

def _register_attachment(cursor, *, blob_path: str, content_type: str,
                         name: Optional[str] = None, size_bytes: Optional[int] = None,
                         uploader_account_id: Optional[str] = None) -> str:
    """Upsert an `attachments` row keyed by blob_path. Returns the attachment_id."""
    cursor.execute(
        """INSERT INTO attachments (blob_path, content_type, name, size_bytes, uploader_account_id)
           VALUES (%s, %s, %s, %s, %s)
           ON CONFLICT (blob_path) DO UPDATE
             SET content_type = COALESCE(attachments.content_type, EXCLUDED.content_type),
                 name = COALESCE(attachments.name, EXCLUDED.name),
                 size_bytes = COALESCE(attachments.size_bytes, EXCLUDED.size_bytes),
                 uploader_account_id = COALESCE(attachments.uploader_account_id, EXCLUDED.uploader_account_id)
           RETURNING id""",
        (blob_path, content_type, name, size_bytes, uploader_account_id),
    )
    return str(cursor.fetchone()[0])


def _fetch_message_attachments(cursor, message_id: str) -> list:
    """Load attachments linked to a message via the join table. Empty list if none.

    Returned dict shape matches the legacy JSONB contract:
      {blob_path, content_type, name, size_bytes}
    Callers that need `download_url` should pipe through `_resolve_attachments`.
    """
    cursor.execute(
        """SELECT a.blob_path, a.content_type, a.name, a.size_bytes
           FROM message_attachments ma
           JOIN attachments a ON a.id = ma.attachment_id
           WHERE ma.message_id = %s
           ORDER BY a.created_at""",
        (message_id,),
    )
    return [
        {"blob_path": bp, "content_type": ct, "name": nm, "size_bytes": sb}
        for bp, ct, nm, sb in cursor.fetchall()
    ]


def _get_bid_pdf_url_compat(cursor, bid_id: str, legacy_pdf_url: Optional[str]) -> Optional[str]:
    """Return a signed GET URL for a bid's quote PDF, preferring the unified table.

    Compat shim for the `bid.pdf_url` field that the deployed frontend reads
    (ContractorCard, OrgDashboard, ProjectQuotes). If the unified table has a
    `quote_pdf` attachment, re-sign it fresh. Otherwise fall back to the legacy
    `bids.pdf_url` column (which stores a pre-signed URL that may be expired).
    """
    cursor.execute(
        """SELECT a.blob_path FROM bid_attachments ba
           JOIN attachments a ON a.id = ba.attachment_id
           WHERE ba.bid_id = %s AND ba.role = 'quote_pdf'
           ORDER BY ba.created_at DESC LIMIT 1""",
        (bid_id,),
    )
    row = cursor.fetchone()
    if row:
        try:
            return _sign_attachment_get(row[0])
        except Exception:
            pass
    return legacy_pdf_url


def _link_bid_attachment(cursor, *, bid_id: str, attachment_id: str, role: str,
                         added_via_message_id: Optional[str] = None) -> None:
    """Upsert a bid_attachments link. No-op if already present."""
    cursor.execute(
        """INSERT INTO bid_attachments (bid_id, attachment_id, role, added_via_message_id)
           VALUES (%s, %s, %s, %s)
           ON CONFLICT (bid_id, attachment_id) DO NOTHING""",
        (bid_id, attachment_id, role, added_via_message_id),
    )


def _link_rfq_attachment(cursor, *, rfq_id: str, attachment_id: str,
                         added_via_message_id: Optional[str] = None) -> None:
    """Upsert an rfq_attachments link. No-op if already present."""
    cursor.execute(
        """INSERT INTO rfq_attachments (rfq_id, attachment_id, added_via_message_id)
           VALUES (%s, %s, %s)
           ON CONFLICT (rfq_id, attachment_id) DO NOTHING""",
        (rfq_id, attachment_id, added_via_message_id),
    )


def _link_message_attachment(cursor, *, message_id: str, attachment_id: str) -> None:
    """Upsert a message_attachments link."""
    cursor.execute(
        """INSERT INTO message_attachments (message_id, attachment_id)
           VALUES (%s, %s)
           ON CONFLICT (message_id, attachment_id) DO NOTHING""",
        (message_id, attachment_id),
    )


def _find_pending_bid_for_org(cursor, rfq_id: str, org_id: str) -> Optional[str]:
    """Return the most recent pending/accepted bid_id for an (rfq, org), if any."""
    cursor.execute(
        """SELECT id FROM bids
           WHERE rfq_id = %s AND org_id = %s AND status IN ('pending', 'accepted')
           ORDER BY received_at DESC LIMIT 1""",
        (rfq_id, org_id),
    )
    row = cursor.fetchone()
    return str(row[0]) if row else None


def _event_preview(event_type: str, bid_snapshot: Optional[dict]) -> str:
    """Short one-line preview text for an event message, used in thread lists."""
    if event_type == "bid_submitted":
        if bid_snapshot and bid_snapshot.get("price_cents"):
            return f"New bid · ${bid_snapshot['price_cents'] / 100:,.0f}"
        return "New bid submitted"
    if event_type == "bid_accepted":
        return "Hired — bid accepted"
    if event_type == "bid_rejected":
        return "Another contractor was selected"
    if event_type == "rfq_updated":
        return "Homeowner updated the project"
    if event_type == "bid_updated":
        return "Contractor updated the bid"
    if event_type == "thread_started":
        return "Conversation started"
    return "Update"


def _resolve_rfq_homeowner(cursor, rfq_id: str) -> Optional[str]:
    """Return the RFQ owner's account_id, backfilling from legacy Firebase UID if possible."""
    cursor.execute(
        """SELECT r.homeowner_account_id, r.user_id, a.id
           FROM rfqs r
           LEFT JOIN accounts a ON a.firebase_uid = r.user_id
           WHERE r.id = %s""",
        (rfq_id,),
    )
    row = cursor.fetchone()
    if not row:
        return None
    ho_account_id, legacy_uid, legacy_account_id = row
    if ho_account_id:
        return str(ho_account_id)
    if legacy_account_id:
        cursor.execute(
            "UPDATE rfqs SET homeowner_account_id = %s WHERE id = %s",
            (legacy_account_id, rfq_id),
        )
        return str(legacy_account_id)
    return None


def _ensure_conversation(cursor, rfq_id: str, homeowner_account_id: str, org_id: str) -> str:
    """Upsert a conversation row for the (rfq, homeowner, org) tuple and return its id."""
    cursor.execute(
        """INSERT INTO conversations (rfq_id, homeowner_account_id, org_id)
           VALUES (%s, %s, %s)
           ON CONFLICT (rfq_id, homeowner_account_id, org_id)
           DO UPDATE SET rfq_id = EXCLUDED.rfq_id
           RETURNING id""",
        (rfq_id, homeowner_account_id, org_id),
    )
    return str(cursor.fetchone()[0])


def _insert_message(cursor, *, conversation_id: str, side: str, kind: str,
                    sender_account_id: Optional[str] = None,
                    body: Optional[str] = None,
                    event_type: Optional[str] = None,
                    bid_id: Optional[str] = None,
                    bid_snapshot: Optional[dict] = None,
                    attachments: Optional[list] = None) -> tuple[str, datetime.datetime]:
    """Insert a message and update the conversation's last-message + unread counters.

    Side semantics: 'homeowner' bumps org_unread_count; 'org' bumps homeowner_unread_count;
    'system' bumps both (system events are informational for both parties).
    """
    preview_source = body if body else _event_preview(event_type, bid_snapshot)
    preview = (preview_source or "")[:200]
    cursor.execute(
        """INSERT INTO messages (conversation_id, sender_account_id, side, kind, body,
                                 event_type, bid_id, bid_snapshot, attachments)
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
           RETURNING id, created_at""",
        (
            conversation_id,
            sender_account_id,
            side,
            kind,
            body,
            event_type,
            bid_id,
            json.dumps(bid_snapshot) if bid_snapshot else None,
            json.dumps(attachments) if attachments else None,
        ),
    )
    mid, created_at = cursor.fetchone()

    if side == "homeowner":
        cursor.execute(
            """UPDATE conversations
               SET last_message_at = %s, last_message_preview = %s, last_message_side = %s,
                   org_unread_count = org_unread_count + 1
               WHERE id = %s""",
            (created_at, preview, side, conversation_id),
        )
    elif side == "org":
        cursor.execute(
            """UPDATE conversations
               SET last_message_at = %s, last_message_preview = %s, last_message_side = %s,
                   homeowner_unread_count = homeowner_unread_count + 1
               WHERE id = %s""",
            (created_at, preview, side, conversation_id),
        )
    else:
        cursor.execute(
            """UPDATE conversations
               SET last_message_at = %s, last_message_preview = %s, last_message_side = %s,
                   homeowner_unread_count = homeowner_unread_count + 1,
                   org_unread_count = org_unread_count + 1
               WHERE id = %s""",
            (created_at, preview, side, conversation_id),
        )
    return str(mid), created_at


def _derive_thread_kind(latest_bid_status: Optional[str], is_hired: bool) -> tuple[str, str]:
    """Map current bid state → (kind, kindLabel) for thread list display."""
    if is_hired:
        return "won", "Hired"
    if latest_bid_status == "accepted":
        return "won", "Hired"
    if latest_bid_status == "pending":
        return "bid", "Active bid"
    if latest_bid_status == "rejected":
        return "msg", "Closed"
    return "rfq", "No bid yet"


def _check_conversation_access(cursor, conversation_id: str, uid: str) -> tuple[str, str, dict]:
    """Verify the caller can access the conversation. Returns (side, account_id, conversation_row).

    side is 'homeowner' or 'org'. Raises 403 if the caller is neither the
    homeowner nor a member of the conversation's org.
    """
    cursor.execute(
        """SELECT id, rfq_id, homeowner_account_id, org_id,
                  homeowner_last_read_at, org_last_read_at
           FROM conversations WHERE id = %s""",
        (conversation_id,),
    )
    row = cursor.fetchone()
    if not row:
        raise HTTPException(404, "Conversation not found")
    conv = {
        "id": str(row[0]), "rfq_id": str(row[1]),
        "homeowner_account_id": str(row[2]), "org_id": str(row[3]),
        "homeowner_last_read_at": row[4], "org_last_read_at": row[5],
    }

    cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (uid,))
    acct = cursor.fetchone()
    if not acct:
        raise HTTPException(403, "No account found for caller")
    account_id = str(acct[0])

    if account_id == conv["homeowner_account_id"]:
        return "homeowner", account_id, conv

    cursor.execute(
        """SELECT 1 FROM org_members
           WHERE org_id = %s AND account_id = %s AND invite_status = 'accepted'""",
        (conv["org_id"], account_id),
    )
    if cursor.fetchone():
        return "org", account_id, conv

    raise HTTPException(403, "Not a participant in this conversation")


def _send_new_message_email(*, recipients: list, sender_name: str, rfq_title: str,
                             preview: str, counterpart_label: str, is_for_homeowner: bool) -> None:
    """Notify the opposite side that a new chat message was posted."""
    sendgrid_key = os.environ.get("SENDGRID_API_KEY", "")
    if not sendgrid_key or not recipients:
        return
    try:
        from sendgrid import SendGridAPIClient

        inbox_url = f"{FRONTEND_URL}/inbox" if is_for_homeowner else f"{FRONTEND_URL}/org?tab=inbox"
        safe_preview = (preview or "").strip()[:280].replace("<", "&lt;").replace(">", "&gt;")
        html = f"""
<h2>New message from {sender_name}</h2>
<p style="font-size:13px;color:#888;margin:4px 0 16px">Project: {rfq_title}</p>
<div style="padding:14px 18px;background:#f5f6f8;border-radius:10px;font-size:15px;color:#333;line-height:1.5;margin:12px 0">
  {safe_preview or '<em>(attachment sent)</em>'}
</div>
<a href="{inbox_url}" style="display:inline-block;padding:12px 28px;background:#0055cc;color:#fff;
   text-decoration:none;font-weight:700;font-size:15px;border-radius:8px;margin-top:12px">
  Open Inbox
</a>
<p style="font-size:12px;color:#888;margin-top:20px">Replying to this email does not send a reply — open the inbox to respond.</p>
"""
        sg = SendGridAPIClient(sendgrid_key)
        for email_addr in recipients:
            if not email_addr or "@unknown" in email_addr:
                continue
            sg.send(_make_mail(
                from_email="notifications@roomscanalpha.com",
                to_emails=email_addr,
                subject=f"{sender_name}: {rfq_title}",
                html_content=html,
            ))
    except Exception as e:
        print(f"[Email] Failed to send new-message email: {e}")


def _post_bid_events(cursor, *, rfq_id: str, org_id: str, bid_id: str,
                     price_cents: int, description: Optional[str],
                     pdf_url: Optional[str]) -> Optional[str]:
    """Create (or ensure) a conversation and post bid_submitted event + bid card.

    Returns the conversation_id, or None if the RFQ has no resolvable homeowner account.
    """
    homeowner_account_id = _resolve_rfq_homeowner(cursor, rfq_id)
    if not homeowner_account_id:
        return None
    conv_id = _ensure_conversation(cursor, rfq_id, homeowner_account_id, org_id)
    bid_snapshot = {
        "price_cents": price_cents,
        "description": description,
        "pdf_url": pdf_url,
    }
    _insert_message(
        cursor, conversation_id=conv_id, side="system", kind="event",
        event_type="bid_submitted", bid_id=bid_id, bid_snapshot=bid_snapshot,
    )
    _insert_message(
        cursor, conversation_id=conv_id, side="org", kind="bid",
        bid_id=bid_id, bid_snapshot=bid_snapshot,
    )
    return conv_id


def _post_bid_decision_events(cursor, *, rfq_id: str, winning_bid_id: str,
                              winning_org_id: str) -> None:
    """Post bid_accepted event to the winning thread; bid_rejected to losing threads."""
    # Winning thread
    cursor.execute(
        """SELECT id FROM conversations
           WHERE rfq_id = %s AND org_id = %s""",
        (rfq_id, winning_org_id),
    )
    row = cursor.fetchone()
    if row:
        _insert_message(
            cursor, conversation_id=str(row[0]), side="system", kind="event",
            event_type="bid_accepted", bid_id=winning_bid_id,
        )

    # Losing threads — any conversation for this RFQ whose org is NOT the winner
    cursor.execute(
        """SELECT id FROM conversations
           WHERE rfq_id = %s AND org_id != %s""",
        (rfq_id, winning_org_id),
    )
    for loser_row in cursor.fetchall():
        _insert_message(
            cursor, conversation_id=str(loser_row[0]), side="system", kind="event",
            event_type="bid_rejected",
        )


def _post_rfq_updated_event(cursor, rfq_id: str) -> None:
    """Post an rfq_updated event into every conversation attached to this RFQ."""
    cursor.execute("SELECT id FROM conversations WHERE rfq_id = %s", (rfq_id,))
    for row in cursor.fetchall():
        _insert_message(
            cursor, conversation_id=str(row[0]), side="system", kind="event",
            event_type="rfq_updated",
        )


@app.get("/api/inbox")
def list_inbox(role: str = "auto", authorization: str = Header(None)) -> dict:
    """Return the caller's conversation threads.

    Query param `role`:
      - 'homeowner': threads where caller is the homeowner
      - 'org': threads for the caller's contractor org (any member can view)
      - 'auto' (default): org if caller belongs to one, else homeowner
    """
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    email = decoded.get("email", f"{uid}@unknown")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """INSERT INTO accounts (firebase_uid, email, type)
               VALUES (%s, %s, 'homeowner')
               ON CONFLICT (firebase_uid) DO UPDATE SET email = EXCLUDED.email
               RETURNING id""",
            (uid, email),
        )
        account_id = str(cursor.fetchone()[0])
        conn.commit()

        cursor.execute(
            """SELECT o.id FROM org_members om
               JOIN organizations o ON o.id = om.org_id
               WHERE om.account_id = %s AND om.invite_status = 'accepted' AND o.deleted_at IS NULL
               LIMIT 1""",
            (account_id,),
        )
        org_row = cursor.fetchone()
        org_id = str(org_row[0]) if org_row else None

        effective = role if role in ("homeowner", "org") else ("org" if org_id else "homeowner")
        if effective == "org" and not org_id:
            raise HTTPException(403, "Not a member of any organization")

        if effective == "homeowner":
            where_clause = "c.homeowner_account_id = %s"
            where_param = account_id
        else:
            where_clause = "c.org_id = %s"
            where_param = org_id

        cursor.execute(
            f"""SELECT c.id, c.rfq_id, c.last_message_at, c.last_message_preview,
                       c.last_message_side, c.homeowner_unread_count, c.org_unread_count,
                       c.created_at,
                       r.title, r.address, r.hired_bid_id,
                       a.id, a.name, a.email, a.icon_url,
                       o.id, o.name, o.icon_url,
                       (SELECT b.price_cents FROM bids b
                          WHERE b.rfq_id = c.rfq_id AND b.org_id = c.org_id
                          ORDER BY b.received_at DESC LIMIT 1) AS latest_price,
                       (SELECT b.status FROM bids b
                          WHERE b.rfq_id = c.rfq_id AND b.org_id = c.org_id
                          ORDER BY b.received_at DESC LIMIT 1) AS latest_bid_status,
                       (SELECT b.id FROM bids b
                          WHERE b.rfq_id = c.rfq_id AND b.org_id = c.org_id
                          ORDER BY b.received_at DESC LIMIT 1) AS latest_bid_id
                FROM conversations c
                JOIN rfqs r ON r.id = c.rfq_id
                JOIN accounts a ON a.id = c.homeowner_account_id
                JOIN organizations o ON o.id = c.org_id
                WHERE {where_clause}
                ORDER BY c.last_message_at DESC NULLS LAST, c.created_at DESC
                LIMIT 100""",
            (where_param,),
        )
        rows = cursor.fetchall()
    finally:
        conn.close()

    threads = []
    for r in rows:
        (conv_id, rfq_id, last_at, preview, last_side, ho_unread, org_unread, created_at,
         rfq_title, rfq_addr, hired_bid_id,
         ho_id, ho_name, ho_email, ho_icon,
         o_id, o_name, o_icon,
         latest_price, latest_bid_status, latest_bid_id) = r

        is_hired = hired_bid_id is not None and latest_bid_id is not None and str(hired_bid_id) == str(latest_bid_id)
        kind, kind_label = _derive_thread_kind(latest_bid_status, is_hired)
        if kind == "bid" and latest_price:
            kind_label = f"Active bid · ${latest_price / 100:,.0f}"
        if kind == "won" and latest_price:
            kind_label = f"Hired · ${latest_price / 100:,.0f}"

        unread = ho_unread if effective == "homeowner" else org_unread
        counterpart = {
            "type": "org", "id": str(o_id), "name": o_name, "icon_url": _sign_icon_url(o_icon),
        } if effective == "homeowner" else {
            "type": "homeowner", "id": str(ho_id), "name": ho_name,
            "email": ho_email, "icon_url": _sign_icon_url(ho_icon),
        }
        threads.append({
            "id": conv_id if isinstance(conv_id, str) else str(conv_id),
            "rfq_id": str(rfq_id),
            "rfq_title": rfq_title or "Untitled Project",
            "rfq_address": rfq_addr,
            "counterpart": counterpart,
            "last_message_at": last_at.isoformat() if last_at else None,
            "last_message_preview": preview,
            "last_message_side": last_side,
            "unread_count": int(unread or 0),
            "kind": kind,
            "kind_label": kind_label,
            "latest_bid": {
                "id": str(latest_bid_id), "price_cents": latest_price, "status": latest_bid_status,
            } if latest_bid_id else None,
            "created_at": created_at.isoformat() if created_at else None,
        })

    return {"conversations": threads, "role": effective, "org_id": org_id}


@app.post("/api/conversations")
async def create_conversation(request: Request, authorization: str = Header(None)) -> dict:
    """Homeowner starts a new thread with a contractor org about one of their RFQs.

    Body: { rfq_id, org_id }. Requires an authenticated account and that the caller
    owns the RFQ. Idempotent — returns the existing conversation if one already exists.
    """
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    body = await request.json()
    rfq_id = body.get("rfq_id")
    org_id = body.get("org_id")
    if not rfq_id or not org_id:
        raise HTTPException(400, "rfq_id and org_id are required")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (uid,))
        acct = cursor.fetchone()
        if not acct:
            raise HTTPException(403, "Account not found — sign in required")
        caller_account_id = str(acct[0])

        homeowner_account_id = _resolve_rfq_homeowner(cursor, rfq_id)
        if not homeowner_account_id:
            raise HTTPException(404, "RFQ not found")

        cursor.execute("SELECT 1 FROM organizations WHERE id = %s AND deleted_at IS NULL", (org_id,))
        if not cursor.fetchone():
            raise HTTPException(404, "Organization not found")

        is_owner = homeowner_account_id == caller_account_id
        is_org_member = False
        if not is_owner:
            cursor.execute(
                """SELECT 1 FROM org_members
                   WHERE org_id = %s AND account_id = %s AND invite_status = 'accepted'""",
                (org_id, caller_account_id),
            )
            is_org_member = cursor.fetchone() is not None
        if not (is_owner or is_org_member):
            raise HTTPException(403, "Only the RFQ owner or a member of the target org can start a conversation")

        conv_id = _ensure_conversation(cursor, rfq_id, homeowner_account_id, org_id)
        conn.commit()
    finally:
        conn.close()

    return {"id": conv_id, "rfq_id": rfq_id, "org_id": org_id}


@app.get("/api/conversations/{conversation_id}")
def get_conversation(conversation_id: str, authorization: str = Header(None)) -> dict:
    """Fetch full conversation with ordered messages. Marks the caller's side as read."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        side, _account_id, conv = _check_conversation_access(cursor, conversation_id, uid)

        cursor.execute(
            """SELECT c.rfq_id, r.title, r.address,
                      a.id, a.name, a.email, a.icon_url,
                      o.id, o.name, o.icon_url
               FROM conversations c
               JOIN rfqs r ON r.id = c.rfq_id
               JOIN accounts a ON a.id = c.homeowner_account_id
               JOIN organizations o ON o.id = c.org_id
               WHERE c.id = %s""",
            (conversation_id,),
        )
        meta = cursor.fetchone()

        cursor.execute(
            """SELECT m.id, m.side, m.kind, m.body, m.event_type, m.bid_id,
                      m.bid_snapshot, m.attachments, m.created_at,
                      s.id, s.name, s.email, s.icon_url
               FROM messages m
               LEFT JOIN accounts s ON s.id = m.sender_account_id
               WHERE m.conversation_id = %s
               ORDER BY m.created_at ASC""",
            (conversation_id,),
        )
        msg_rows = cursor.fetchall()

        # Load attachments from unified join table. Merge with legacy JSONB by
        # blob_path so messages keep working during the dual-phase rollout
        # (either source alone is sufficient; duplicates collapse).
        cursor.execute(
            """SELECT ma.message_id, a.blob_path, a.content_type, a.name, a.size_bytes
               FROM message_attachments ma
               JOIN attachments a ON a.id = ma.attachment_id
               JOIN messages m ON m.id = ma.message_id
               WHERE m.conversation_id = %s
               ORDER BY a.created_at""",
            (conversation_id,),
        )
        unified_by_mid: dict[str, list] = {}
        for mid_row, bp, ct, nm, sb in cursor.fetchall():
            unified_by_mid.setdefault(str(mid_row), []).append({
                "blob_path": bp, "content_type": ct, "name": nm, "size_bytes": sb,
            })

        # Participants (homeowner + accepted org members)
        cursor.execute(
            """SELECT a.id, a.name, a.email, a.icon_url, 'homeowner'
               FROM accounts a WHERE a.id = %s
               UNION ALL
               SELECT a.id, a.name, a.email, a.icon_url, om.role
               FROM org_members om JOIN accounts a ON a.id = om.account_id
               WHERE om.org_id = %s AND om.invite_status = 'accepted'""",
            (conv["homeowner_account_id"], conv["org_id"]),
        )
        participant_rows = cursor.fetchall()

        # Mark caller's side read
        if side == "homeowner":
            cursor.execute(
                """UPDATE conversations
                   SET homeowner_unread_count = 0, homeowner_last_read_at = NOW()
                   WHERE id = %s""",
                (conversation_id,),
            )
        else:
            cursor.execute(
                """UPDATE conversations
                   SET org_unread_count = 0, org_last_read_at = NOW()
                   WHERE id = %s""",
                (conversation_id,),
            )
        conn.commit()
    finally:
        conn.close()

    rfq_id, rfq_title, rfq_addr, ho_id, ho_name, ho_email, ho_icon, o_id, o_name, o_icon = meta

    messages = []
    for (mid, m_side, m_kind, m_body, ev, b_id, snap, atts, created,
         s_id, s_name, s_email, s_icon) in msg_rows:
        # Merge unified-table attachments with legacy JSONB by blob_path (unique).
        merged: dict[str, dict] = {}
        for a in (atts or []):
            if isinstance(a, dict) and a.get("blob_path"):
                merged[a["blob_path"]] = a
        for a in unified_by_mid.get(str(mid), []):
            merged[a["blob_path"]] = a
        messages.append({
            "id": str(mid),
            "side": m_side,
            "kind": m_kind,
            "body": m_body,
            "event_type": ev,
            "bid_id": str(b_id) if b_id else None,
            "bid_snapshot": snap,
            "attachments": _resolve_attachments(list(merged.values())),
            "created_at": created.isoformat() if created else None,
            "sender": {
                "id": str(s_id), "name": s_name, "email": s_email,
                "icon_url": _sign_icon_url(s_icon),
            } if s_id else None,
        })

    participants = []
    for p_id, p_name, p_email, p_icon, p_role in participant_rows:
        participants.append({
            "id": str(p_id), "name": p_name, "email": p_email,
            "icon_url": _sign_icon_url(p_icon), "role": p_role,
        })

    return {
        "id": conversation_id,
        "rfq": {"id": str(rfq_id), "title": rfq_title or "Untitled Project", "address": rfq_addr},
        "homeowner": {"id": str(ho_id), "name": ho_name, "email": ho_email, "icon_url": _sign_icon_url(ho_icon)},
        "org": {"id": str(o_id), "name": o_name, "icon_url": _sign_icon_url(o_icon)},
        "participants": participants,
        "messages": messages,
        "caller_side": side,
    }


@app.post("/api/conversations/{conversation_id}/messages")
async def post_message(conversation_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Send a text message (optionally with attachments) to a conversation."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    body_json = await request.json()
    text = (body_json.get("body") or "").strip()
    attachments = body_json.get("attachments") or []

    if not text and not attachments:
        raise HTTPException(400, "Message must have body or attachments")

    # Validate attachments — only keep sanctioned blob_path shape to prevent caller
    # from referencing arbitrary buckets/paths.
    clean_attachments = []
    for a in attachments:
        if not isinstance(a, dict):
            continue
        bp = a.get("blob_path", "")
        if not bp.startswith(f"conversations/{conversation_id}/"):
            raise HTTPException(400, f"Invalid attachment blob_path: {bp}")
        clean_attachments.append({
            "blob_path": bp,
            "content_type": a.get("content_type"),
            "name": a.get("name"),
            "size_bytes": a.get("size_bytes"),
        })

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        side, account_id, conv = _check_conversation_access(cursor, conversation_id, uid)

        mid, created_at = _insert_message(
            cursor, conversation_id=conversation_id, side=side, kind="text",
            sender_account_id=account_id, body=text or None,
            attachments=clean_attachments or None,
        )

        # Dual-write attachments into the unified tables. Also auto-link to the
        # RFQ (homeowner side) or the org's bid if one exists (contractor side),
        # so images flow through to the underlying project/bid surfaces.
        if clean_attachments:
            bid_id_for_link = None
            if side == "org":
                bid_id_for_link = _find_pending_bid_for_org(cursor, conv["rfq_id"], conv["org_id"])

            for att in clean_attachments:
                attachment_id = _register_attachment(
                    cursor,
                    blob_path=att["blob_path"],
                    content_type=att.get("content_type") or "application/octet-stream",
                    name=att.get("name"),
                    size_bytes=att.get("size_bytes"),
                    uploader_account_id=account_id,
                )
                _link_message_attachment(cursor, message_id=mid, attachment_id=attachment_id)
                if side == "homeowner":
                    _link_rfq_attachment(
                        cursor, rfq_id=conv["rfq_id"], attachment_id=attachment_id,
                        added_via_message_id=mid,
                    )
                elif side == "org" and bid_id_for_link:
                    _link_bid_attachment(
                        cursor, bid_id=bid_id_for_link, attachment_id=attachment_id,
                        role="image", added_via_message_id=mid,
                    )

        # Gather notification recipients + metadata for email
        cursor.execute(
            """SELECT r.title, a.email, a.name
               FROM conversations c
               JOIN rfqs r ON r.id = c.rfq_id
               JOIN accounts a ON a.id = %s
               WHERE c.id = %s""",
            (account_id, conversation_id),
        )
        meta = cursor.fetchone()
        rfq_title = (meta[0] if meta else None) or "your project"
        sender_name = (meta[2] if meta else None) or (meta[1].split("@")[0] if meta and meta[1] else "Someone")

        if side == "homeowner":
            cursor.execute(
                """SELECT a.email FROM org_members om
                   JOIN accounts a ON a.id = om.account_id
                   WHERE om.org_id = %s AND om.invite_status = 'accepted'""",
                (conv["org_id"],),
            )
            recipients = [r[0] for r in cursor.fetchall() if r[0]]
            is_for_homeowner = False
        else:
            cursor.execute("SELECT email FROM accounts WHERE id = %s", (conv["homeowner_account_id"],))
            row = cursor.fetchone()
            recipients = [row[0]] if row and row[0] else []
            is_for_homeowner = True

        conn.commit()
    finally:
        conn.close()

    _send_new_message_email(
        recipients=recipients,
        sender_name=sender_name,
        rfq_title=rfq_title,
        preview=text,
        counterpart_label="",
        is_for_homeowner=is_for_homeowner,
    )

    return {
        "id": mid,
        "conversation_id": conversation_id,
        "side": side,
        "kind": "text",
        "body": text or None,
        "attachments": _resolve_attachments(clean_attachments),
        "created_at": created_at.isoformat() if created_at else None,
    }


@app.post("/api/conversations/{conversation_id}/read")
def mark_conversation_read(conversation_id: str, authorization: str = Header(None)) -> dict:
    """Zero the caller's unread count on this thread."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        side, _account_id, _conv = _check_conversation_access(cursor, conversation_id, uid)
        if side == "homeowner":
            cursor.execute(
                """UPDATE conversations
                   SET homeowner_unread_count = 0, homeowner_last_read_at = NOW()
                   WHERE id = %s""",
                (conversation_id,),
            )
        else:
            cursor.execute(
                """UPDATE conversations
                   SET org_unread_count = 0, org_last_read_at = NOW()
                   WHERE id = %s""",
                (conversation_id,),
            )
        conn.commit()
    finally:
        conn.close()

    return {"status": "read"}


@app.get("/api/conversations/{conversation_id}/attachment-upload-url")
def conversation_attachment_upload_url(
    conversation_id: str,
    content_type: str = "image/jpeg",
    filename: Optional[str] = None,
    authorization: str = Header(None),
) -> dict:
    """Get a signed PUT URL for uploading a chat attachment to GCS.

    Enforces:
      - caller is a participant in the conversation
      - content_type is in the allowlist (images + PDF)
    Returned blob_path is `conversations/{conversation_id}/{uuid}{ext}` — the client
    includes this in the subsequent POST /messages call.
    """
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]

    if content_type not in ATTACHMENT_TYPES:
        raise HTTPException(400, f"Unsupported content type. Allowed: {', '.join(ATTACHMENT_TYPES)}")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        _check_conversation_access(cursor, conversation_id, uid)
    finally:
        conn.close()

    ext = ATTACHMENT_TYPES[content_type]
    attachment_id = str(uuid.uuid4())
    blob_path = f"conversations/{conversation_id}/{attachment_id}{ext}"

    _credentials.refresh(_auth_request)
    bucket = storage_client.bucket(BUCKET_NAME)
    upload_url = bucket.blob(blob_path).generate_signed_url(
        version="v4",
        expiration=datetime.timedelta(minutes=SIGNED_URL_EXPIRY_MINUTES),
        method="PUT",
        content_type=content_type,
        service_account_email=SIGNING_SA_EMAIL,
        access_token=_credentials.token,
    )

    return {
        "upload_url": upload_url,
        "blob_path": blob_path,
        "content_type": content_type,
        "filename": filename,
    }


# --- Direct RFQ attachments (homeowner-attached photos/docs outside chat) ---

def _verify_rfq_owner(cursor, rfq_id: str, uid: str) -> str:
    """Return the owner's account_id; raise 403 if caller is not the owner."""
    cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (uid,))
    acct = cursor.fetchone()
    if not acct:
        raise HTTPException(403, "Account not found")
    account_id = str(acct[0])

    owner_account_id = _resolve_rfq_homeowner(cursor, rfq_id)
    if not owner_account_id:
        raise HTTPException(404, "RFQ not found")
    if owner_account_id != account_id:
        raise HTTPException(403, "Not the owner of this RFQ")
    return account_id


@app.get("/api/rfqs/{rfq_id}/attachment-upload-url")
def rfq_attachment_upload_url(
    rfq_id: str,
    content_type: str = "image/jpeg",
    filename: Optional[str] = None,
    authorization: str = Header(None),
) -> dict:
    """Signed PUT URL for an RFQ-scoped attachment. Only the RFQ owner can upload."""
    decoded = verify_firebase_token(authorization)
    if content_type not in ATTACHMENT_TYPES:
        raise HTTPException(400, f"Unsupported content type. Allowed: {', '.join(ATTACHMENT_TYPES)}")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        _verify_rfq_owner(cursor, rfq_id, decoded["uid"])
    finally:
        conn.close()

    ext = ATTACHMENT_TYPES[content_type]
    attachment_id = str(uuid.uuid4())
    blob_path = f"rfqs/{rfq_id}/attachments/{attachment_id}{ext}"

    _credentials.refresh(_auth_request)
    bucket = storage_client.bucket(BUCKET_NAME)
    upload_url = bucket.blob(blob_path).generate_signed_url(
        version="v4",
        expiration=datetime.timedelta(minutes=SIGNED_URL_EXPIRY_MINUTES),
        method="PUT",
        content_type=content_type,
        service_account_email=SIGNING_SA_EMAIL,
        access_token=_credentials.token,
    )
    return {"upload_url": upload_url, "blob_path": blob_path, "content_type": content_type, "filename": filename}


@app.post("/api/rfqs/{rfq_id}/attachments")
async def register_rfq_attachments(rfq_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Register previously-uploaded blobs as RFQ attachments.

    Body: { attachments: [{blob_path, content_type, name?, size_bytes?}] }
    """
    decoded = verify_firebase_token(authorization)
    body = await request.json()
    items = body.get("attachments") or []
    if not items:
        raise HTTPException(400, "attachments list is required")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        uploader_account_id = _verify_rfq_owner(cursor, rfq_id, decoded["uid"])

        created = []
        for a in items:
            if not isinstance(a, dict):
                continue
            bp = a.get("blob_path", "")
            if not bp.startswith(f"rfqs/{rfq_id}/attachments/"):
                raise HTTPException(400, f"Invalid blob_path for this RFQ: {bp}")
            aid = _register_attachment(
                cursor, blob_path=bp,
                content_type=a.get("content_type") or "application/octet-stream",
                name=a.get("name"), size_bytes=a.get("size_bytes"),
                uploader_account_id=uploader_account_id,
            )
            _link_rfq_attachment(cursor, rfq_id=rfq_id, attachment_id=aid)
            created.append({"attachment_id": aid, "blob_path": bp,
                            "content_type": a.get("content_type"),
                            "name": a.get("name"), "size_bytes": a.get("size_bytes")})
        conn.commit()
    finally:
        conn.close()

    return {"attachments": _resolve_attachments(created)}


@app.get("/api/rfqs/{rfq_id}/attachments")
def list_rfq_attachments(rfq_id: str, authorization: str = Header(None)) -> dict:
    """List attachments on an RFQ. Accessible to the RFQ owner and to any org member
    whose org has a conversation or bid on this RFQ.
    """
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (uid,))
        acct = cursor.fetchone()
        if not acct:
            raise HTTPException(403, "Account not found")
        account_id = str(acct[0])

        # Access: RFQ owner, or org member of any org with a bid/conversation on this RFQ
        owner_id = _resolve_rfq_homeowner(cursor, rfq_id)
        if not owner_id:
            raise HTTPException(404, "RFQ not found")
        authorized = owner_id == account_id
        if not authorized:
            cursor.execute(
                """SELECT 1
                   FROM org_members om
                   WHERE om.account_id = %s AND om.invite_status = 'accepted'
                     AND (
                       EXISTS (SELECT 1 FROM bids b WHERE b.rfq_id = %s AND b.org_id = om.org_id)
                       OR EXISTS (SELECT 1 FROM conversations c WHERE c.rfq_id = %s AND c.org_id = om.org_id)
                     )
                   LIMIT 1""",
                (account_id, rfq_id, rfq_id),
            )
            authorized = cursor.fetchone() is not None
        if not authorized:
            raise HTTPException(403, "Not authorized to view this RFQ's attachments")

        cursor.execute(
            """SELECT a.id, a.blob_path, a.content_type, a.name, a.size_bytes,
                      a.uploader_account_id, a.created_at, ra.added_via_message_id
               FROM rfq_attachments ra
               JOIN attachments a ON a.id = ra.attachment_id
               WHERE ra.rfq_id = %s
               ORDER BY a.created_at""",
            (rfq_id,),
        )
        rows = cursor.fetchall()
    finally:
        conn.close()

    out = []
    for aid, bp, ct, nm, sb, up_id, created_at, via_mid in rows:
        entry = {
            "attachment_id": str(aid), "blob_path": bp, "content_type": ct,
            "name": nm, "size_bytes": sb,
            "uploader_account_id": str(up_id) if up_id else None,
            "added_via_message_id": str(via_mid) if via_mid else None,
            "created_at": created_at.isoformat() if created_at else None,
        }
        out.append(entry)
    return {"attachments": _resolve_attachments(out)}


@app.delete("/api/rfqs/{rfq_id}/attachments/{attachment_id}")
def delete_rfq_attachment(rfq_id: str, attachment_id: str, authorization: str = Header(None)) -> dict:
    """Unlink an attachment from an RFQ. Keeps the blob + `attachments` row if still referenced."""
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        _verify_rfq_owner(cursor, rfq_id, decoded["uid"])
        cursor.execute(
            "DELETE FROM rfq_attachments WHERE rfq_id = %s AND attachment_id = %s",
            (rfq_id, attachment_id),
        )
        conn.commit()
    finally:
        conn.close()
    return {"status": "unlinked"}


# --- Direct bid attachments (contractor image uploads outside the chat/submit flow) ---

def _verify_bid_org_access(cursor, rfq_id: str, bid_id: str, uid: str) -> tuple[str, str]:
    """Return (account_id, org_id) for a caller who is an admin/user of the bid's org."""
    cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (uid,))
    acct = cursor.fetchone()
    if not acct:
        raise HTTPException(403, "Account not found")
    account_id = str(acct[0])

    cursor.execute("SELECT org_id FROM bids WHERE id = %s AND rfq_id = %s", (bid_id, rfq_id))
    row = cursor.fetchone()
    if not row or not row[0]:
        raise HTTPException(404, "Bid not found")
    org_id = str(row[0])

    cursor.execute(
        """SELECT 1 FROM org_members
           WHERE org_id = %s AND account_id = %s AND invite_status = 'accepted'""",
        (org_id, account_id),
    )
    if not cursor.fetchone():
        raise HTTPException(403, "Not a member of the bid's organization")
    return account_id, org_id


@app.get("/api/rfqs/{rfq_id}/bids/{bid_id}/attachment-upload-url")
def bid_attachment_upload_url(
    rfq_id: str,
    bid_id: str,
    content_type: str = "image/jpeg",
    filename: Optional[str] = None,
    authorization: str = Header(None),
) -> dict:
    """Signed PUT URL for a bid-scoped attachment."""
    decoded = verify_firebase_token(authorization)
    if content_type not in ATTACHMENT_TYPES:
        raise HTTPException(400, f"Unsupported content type. Allowed: {', '.join(ATTACHMENT_TYPES)}")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        _verify_bid_org_access(cursor, rfq_id, bid_id, decoded["uid"])
    finally:
        conn.close()

    ext = ATTACHMENT_TYPES[content_type]
    attachment_id = str(uuid.uuid4())
    blob_path = f"bids/{rfq_id}/{bid_id}/{attachment_id}{ext}"

    _credentials.refresh(_auth_request)
    bucket = storage_client.bucket(BUCKET_NAME)
    upload_url = bucket.blob(blob_path).generate_signed_url(
        version="v4",
        expiration=datetime.timedelta(minutes=SIGNED_URL_EXPIRY_MINUTES),
        method="PUT",
        content_type=content_type,
        service_account_email=SIGNING_SA_EMAIL,
        access_token=_credentials.token,
    )
    return {"upload_url": upload_url, "blob_path": blob_path, "content_type": content_type, "filename": filename}


@app.post("/api/rfqs/{rfq_id}/bids/{bid_id}/attachments")
async def register_bid_attachments(rfq_id: str, bid_id: str, request: Request, authorization: str = Header(None)) -> dict:
    """Register previously-uploaded blobs as bid attachments.

    Body: { attachments: [{blob_path, content_type, name?, size_bytes?, role?}] }
    `role` defaults to 'image'. Use 'quote_pdf' to register/replace the primary quote PDF.
    On success, posts an `event(bid_updated)` in the related conversation (if any).
    """
    decoded = verify_firebase_token(authorization)
    body = await request.json()
    items = body.get("attachments") or []
    if not items:
        raise HTTPException(400, "attachments list is required")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        uploader_account_id, org_id = _verify_bid_org_access(cursor, rfq_id, bid_id, decoded["uid"])

        created = []
        created_attachment_ids: list[str] = []
        for a in items:
            if not isinstance(a, dict):
                continue
            bp = a.get("blob_path", "")
            if not bp.startswith(f"bids/{rfq_id}/{bid_id}/"):
                raise HTTPException(400, f"Invalid blob_path for this bid: {bp}")
            role = a.get("role") or "image"
            if role not in ("image", "quote_pdf", "other"):
                raise HTTPException(400, f"Invalid role: {role}")
            aid = _register_attachment(
                cursor, blob_path=bp,
                content_type=a.get("content_type") or "application/octet-stream",
                name=a.get("name"), size_bytes=a.get("size_bytes"),
                uploader_account_id=uploader_account_id,
            )
            _link_bid_attachment(cursor, bid_id=bid_id, attachment_id=aid, role=role)
            created_attachment_ids.append(aid)
            created.append({"attachment_id": aid, "blob_path": bp, "role": role,
                            "content_type": a.get("content_type"),
                            "name": a.get("name"), "size_bytes": a.get("size_bytes")})

        # Surface the update in the conversation thread, if one exists.
        cursor.execute(
            "SELECT id FROM conversations WHERE rfq_id = %s AND org_id = %s LIMIT 1",
            (rfq_id, org_id),
        )
        conv_row = cursor.fetchone()
        if conv_row:
            conv_id = str(conv_row[0])
            event_mid, _ = _insert_message(
                cursor, conversation_id=conv_id, side="system", kind="event",
                event_type="bid_updated", bid_id=bid_id,
            )
            for aid in created_attachment_ids:
                _link_message_attachment(cursor, message_id=event_mid, attachment_id=aid)

        conn.commit()
    finally:
        conn.close()

    return {"attachments": _resolve_attachments(created)}


@app.delete("/api/rfqs/{rfq_id}/bids/{bid_id}/attachments/{attachment_id}")
def delete_bid_attachment(rfq_id: str, bid_id: str, attachment_id: str, authorization: str = Header(None)) -> dict:
    """Unlink an attachment from a bid. Caller must be a member of the bid's org.

    Keeps the underlying `attachments` row + blob intact in case the same
    attachment is still linked via a message or another scope.
    """
    decoded = verify_firebase_token(authorization)
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        _verify_bid_org_access(cursor, rfq_id, bid_id, decoded["uid"])
        cursor.execute(
            "DELETE FROM bid_attachments WHERE bid_id = %s AND attachment_id = %s",
            (bid_id, attachment_id),
        )
        conn.commit()
    finally:
        conn.close()
    return {"status": "unlinked"}


@app.get("/health")
def health() -> dict:
    """Health check endpoint for Cloud Run readiness/liveness probes."""
    return {"status": "ok"}


# --- React SPA serving ---
# Vite build output is copied to spa/ during Docker build.
# Mount static assets (JS/CSS bundles) and add a catch-all for client-side routing.
_spa_dir = Path(__file__).parent / "spa"
if _spa_dir.exists() and (_spa_dir / "assets").exists():
    app.mount("/assets", StaticFiles(directory=_spa_dir / "assets"), name="spa-assets")


@app.get("/{path:path}", response_class=HTMLResponse)
def serve_spa(path: str) -> str:
    """Catch-all: serve the React SPA index.html for client-side routing.

    This MUST be defined after all other routes so that API endpoints,
    legacy HTML pages (/quote, /bids, /admin), and static assets take priority.
    """
    index_path = _spa_dir / "index.html"
    if index_path.exists():
        return index_path.read_text()
    raise HTTPException(status_code=404, detail="Not found")
