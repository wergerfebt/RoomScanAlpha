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
        cursor.execute(
            f"""SELECT r.id, r.title, r.description, r.status, r.created_at, r.address,
                       r.bid_view_token,
                       (SELECT count(*) FROM scanned_rooms sr WHERE sr.rfq_id = r.id) AS scan_count,
                       (SELECT count(*) FROM bids b WHERE b.rfq_id = r.id) AS bid_count
                FROM rfqs r WHERE r.user_id = %s ORDER BY r.created_at DESC LIMIT {MAX_RFQS_PER_PAGE}""",
            (uid,),
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
    ALLOWED_EXTENSIONS = {".obj", ".mtl", ".jpg", ".jpeg", ".png", ".ply"}
    CONTENT_TYPES = {
        ".obj": "text/plain",
        ".mtl": "text/plain",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".ply": "application/octet-stream",
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


@app.delete("/api/rfqs/{rfq_id}")
def delete_rfq(rfq_id: str, authorization: str = Header(None)) -> dict:
    """Soft-delete an RFQ and all its scans.

    Sets all scans to 'deleted' status, then deletes the RFQ row.
    GCS blobs are preserved for future model training.
    """
    verify_firebase_token(authorization)

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        # Soft-delete all scans for this RFQ
        cursor.execute(
            """UPDATE scanned_rooms
               SET scan_status = 'deleted'
               WHERE rfq_id = %s AND scan_status != 'deleted'""",
            (rfq_id,),
        )
        deleted_scans = cursor.rowcount

        # Delete the RFQ itself
        cursor.execute("DELETE FROM rfqs WHERE id = %s", (rfq_id,))
        if cursor.rowcount == 0:
            conn.rollback()
            raise HTTPException(status_code=404, detail="RFQ not found")

        conn.commit()
    finally:
        conn.close()

    return {"status": "deleted", "rfq_id": rfq_id, "scans_deleted": deleted_scans}


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
    authorization: str = Header(None),
) -> dict:
    """Submit a bid for an RFQ. Requires Firebase Auth. Accepts multipart/form-data for PDF upload."""
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]

    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        cursor.execute("SELECT id FROM contractors WHERE firebase_uid = %s", (uid,))
        row = cursor.fetchone()
        if not row:
            raise HTTPException(status_code=403, detail="Contractor profile not found. Call GET /api/contractors/me first.")
        contractor_id = str(row[0])

        bid_id = str(uuid.uuid4())
        pdf_url = None

        if pdf and pdf.filename:
            blob_path = f"bids/{rfq_id}/{bid_id}.pdf"
            bucket = storage_client.bucket(BUCKET_NAME)
            blob = bucket.blob(blob_path)
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

        cursor.execute(
            """INSERT INTO bids (id, rfq_id, contractor_id, price_cents, description, pdf_url, received_at)
               VALUES (%s, %s, %s, %s, %s, %s, NOW())""",
            (bid_id, rfq_id, contractor_id, price_cents, description, pdf_url),
        )
        conn.commit()

        cursor.execute("SELECT received_at FROM bids WHERE id = %s", (bid_id,))
        received_at = cursor.fetchone()[0]
    finally:
        conn.close()

    # TODO: trigger SendGrid email + FCM push to homeowner here

    return {
        "id": bid_id,
        "rfq_id": rfq_id,
        "contractor_id": contractor_id,
        "price_cents": price_cents,
        "description": description,
        "pdf_url": pdf_url,
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
            "SELECT description, bid_view_token, user_id FROM rfqs WHERE id = %s",
            (rfq_id,),
        )
        rfq_row = cursor.fetchone()
        if not rfq_row:
            raise HTTPException(status_code=404, detail="RFQ not found")

        project_description, bid_view_token, rfq_owner_uid = rfq_row

        # Auth check: token-based OR JWT owner
        token_ok = token and str(bid_view_token) == token
        jwt_ok = False
        if authorization and not token_ok:
            try:
                decoded = verify_firebase_token(authorization)
                jwt_ok = decoded["uid"] == rfq_owner_uid
            except Exception:
                pass
        if not token_ok and not jwt_ok:
            raise HTTPException(status_code=403, detail="Invalid or missing authorization")

        cursor.execute(
            """SELECT b.id, b.price_cents, b.description, b.pdf_url, b.received_at,
                      c.id AS contractor_id, c.name, c.icon_url, c.yelp_url,
                      c.google_reviews_url, c.review_rating, c.review_count
               FROM bids b
               JOIN contractors c ON c.id = b.contractor_id
               WHERE b.rfq_id = %s
               ORDER BY b.price_cents ASC""",
            (rfq_id,),
        )
        rows = cursor.fetchall()
    finally:
        conn.close()

    bids = []
    for row in rows:
        bid_id, price_cents, desc, pdf_url, received_at, c_id, c_name, c_icon, c_yelp, c_google, c_rating, c_count = row
        bids.append({
            "id": str(bid_id),
            "price_cents": price_cents,
            "description": desc,
            "pdf_url": pdf_url,
            "received_at": received_at.isoformat() if received_at else None,
            "contractor": {
                "id": str(c_id),
                "name": c_name,
                "icon_url": c_icon,
                "yelp_url": c_yelp,
                "google_reviews_url": c_google,
                "review_rating": float(c_rating) if c_rating else None,
                "review_count": c_count,
            },
        })

    return {
        "rfq_id": rfq_id,
        "project_description": project_description,
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
