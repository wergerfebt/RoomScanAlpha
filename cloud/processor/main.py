"""
RoomScanAlpha Scan Processor — async Cloud Run service that processes uploaded scan packages.

Called by Cloud Tasks after the API receives an upload-complete notification. Downloads the
scan zip from GCS, validates the package structure (PLY mesh, keyframes, metadata), parses
the binary PLY to compute real room dimensions, and writes results to Cloud SQL.

Unit convention:
  - Input geometry (PLY vertices) is in meters (ARKit's native unit).
  - Output room dimensions (floor_area, wall_area, ceiling_height, perimeter) are imperial
    (sq ft / ft) to match US construction/renovation conventions.
  - Never mix: conversion happens once at the output boundary in compute_room_metrics().
"""

import os
import json
import struct
import tempfile
import zipfile
from typing import Optional

from fastapi import FastAPI, Request, HTTPException
from google.cloud import storage
from google.cloud.sql.connector import Connector
import pg8000
import numpy as np
import firebase_admin
from firebase_admin import messaging

from pipeline.stage1 import (
    parse_and_classify,
    ParsedMesh,
    CLASSIFICATION_NONE,
    CLASSIFICATION_WALL,
    CLASSIFICATION_FLOOR,
    CLASSIFICATION_CEILING,
    CLASSIFICATION_NAMES,
)
from pipeline.video_extract import extract_frames_from_hevc
from pipeline.frame_selection import select_frames

app = FastAPI(title="RoomScanAlpha Scan Processor (Stub)")

# --- Config ---
PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "roomscanalpha")
BUCKET_NAME = os.environ.get("GCS_BUCKET", "roomscanalpha-scans")
CLOUD_SQL_CONNECTION = os.environ.get("CLOUD_SQL_CONNECTION", "roomscanalpha:us-central1:roomscanalpha-db")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASS = os.environ.get("DB_PASS", "")
DB_NAME = os.environ.get("DB_NAME", "quoterra")
REGION = os.environ.get("GCP_REGION", "us-central1")
TASKS_QUEUE = os.environ.get("TASKS_QUEUE", "scan-processing")
PROCESSOR_URL = os.environ.get("PROCESSOR_URL", "")
TASKS_INVOKER_SA = os.environ.get("TASKS_INVOKER_SA", "839349778883-compute@developer.gserviceaccount.com")

firebase_admin.initialize_app()
storage_client = storage.Client()
connector = Connector()

# --- Unit Conversion ---
# Meters² → square feet, meters → feet. Applied once at the output boundary.
SQM_TO_SQFT = 10.7639
M_TO_FT = 3.28084

# --- PLY Format Constants ---
# Binary PLY vertex: 6 × float32 (x, y, z, nx, ny, nz) = 24 bytes per vertex.
PLY_FLOATS_PER_VERTEX = 6
PLY_BYTES_PER_FLOAT = 4
# Maximum header size before we consider the file corrupt (guards against malformed input).
PLY_MAX_HEADER_BYTES = 4096
# Expected elements in a per-frame camera_transform (4×4 matrix, column-major).
CAMERA_TRANSFORM_LENGTH = 16

# ARMeshClassification values — must match the iOS ARKit ARMeshClassification enum.
# See: https://developer.apple.com/documentation/arkit/armeshclassification
CLASSIFICATION_NONE = 0
CLASSIFICATION_WALL = 1
CLASSIFICATION_FLOOR = 2
CLASSIFICATION_CEILING = 3
CLASSIFICATION_NAMES = {
    0: "none",
    1: "wall",
    2: "floor",
    3: "ceiling",
    4: "table",
    5: "seat",
    6: "window",
    7: "door",
}


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


def update_scan_status(
    scan_id: str,
    rfq_id: str,
    status: str,
    error_msg: Optional[str] = None,
    room_data: Optional[dict] = None,
) -> bool:
    """Write scan processing results (or failure) to the scanned_rooms table.

    Per-room scan_status lifecycle:
      pending → processing → metrics_ready → complete | failed
    "metrics_ready" means dimensions + fast coverage are available but
    texturing is still running. The RFQ-level status transitions to
    'scan_ready' only when ALL its scanned_rooms rows reach 'complete'.

    Args:
        scan_id: UUID of the scan row to update.
        rfq_id: UUID of the parent RFQ (for status transition check).
        status: New scan_status value ("complete" or "failed").
        error_msg: If status is "failed", a human-readable error description.
        room_data: If status is "complete", dict with room dimensions and components.

    Returns:
        True if the RFQ transitioned to 'scan_ready' (all rooms complete).
    """
    conn = get_db_connection()
    rfq_ready = False
    try:
        cursor = conn.cursor()
        if status == "failed":
            cursor.execute(
                """UPDATE scanned_rooms
                   SET scan_status = %s, detected_components = %s
                   WHERE id = %s""",
                (status, json.dumps({"error": error_msg}), scan_id),
            )
        elif room_data:
            cursor.execute(
                """UPDATE scanned_rooms
                   SET scan_status = %s,
                       floor_area_sqft = %s,
                       wall_area_sqft = %s,
                       ceiling_height_ft = %s,
                       perimeter_linear_ft = %s,
                       detected_components = %s,
                       scan_dimensions = %s,
                       room_polygon_ft = %s,
                       wall_heights_ft = %s,
                       polygon_source = %s,
                       scan_mesh_url = %s,
                       texture_manifest = %s,
                       scope = %s,
                       fast_coverage = %s,
                       coverage = %s
                   WHERE id = %s""",
                (
                    status,
                    room_data["floor_area_sqft"],
                    room_data["wall_area_sqft"],
                    room_data["ceiling_height_ft"],
                    room_data["perimeter_linear_ft"],
                    json.dumps(room_data["detected_components"]),
                    json.dumps(room_data["scan_dimensions"]),
                    json.dumps(room_data.get("room_polygon_ft")),
                    json.dumps(room_data.get("wall_heights_ft")),
                    room_data.get("polygon_source"),
                    room_data.get("scan_mesh_url"),
                    json.dumps(room_data.get("texture_manifest")),
                    json.dumps(room_data.get("room_scope")),
                    json.dumps(room_data.get("fast_coverage")),
                    json.dumps(room_data.get("coverage")),
                    scan_id,
                ),
            )

        # RFQ status transition: set to 'scan_ready' only when ALL rooms are complete
        if status == "complete":
            cursor.execute(
                """UPDATE rfqs SET status = 'scan_ready'
                   WHERE id = %s
                     AND NOT EXISTS (
                       SELECT 1 FROM scanned_rooms
                       WHERE rfq_id = %s AND scan_status != 'complete'
                     )""",
                (rfq_id, rfq_id),
            )
            rfq_ready = cursor.rowcount > 0

        conn.commit()
    finally:
        conn.close()
    return rfq_ready


# --- Notifications ---

def send_fcm_notification(scan_id: str, status: str, rfq_ready: bool = False) -> None:
    """Send an FCM push notification via topic to notify the device that processing completed.

    The iOS app subscribes to the topic ``scan_{scan_id}`` after upload, so the notification
    is delivered only to the device that submitted the scan. Non-fatal on failure — the app
    falls back to polling the status endpoint.

    Args:
        scan_id: UUID of the scan.
        status: Room-level status ("complete" or "failed").
        rfq_ready: If True, all rooms for the RFQ are complete (RFQ transitioned to scan_ready).
    """
    try:
        # The iOS app polls for room-level "complete" status.
        # Include rfq_ready so the app knows when all rooms are done.
        message = messaging.Message(
            topic=f"scan_{scan_id}",
            data={"scan_id": scan_id, "status": status, "rfq_ready": str(rfq_ready).lower()},
            notification=messaging.Notification(
                title="Scan Complete" if status == "complete" else "Scan Failed",
                body="Your room scan is ready to view." if status == "complete" else "There was an error processing your scan.",
            ),
        )
        messaging.send(message)
        print(f"[Processor] FCM notification sent for scan {scan_id}")
    except Exception as e:
        print(f"[Processor] FCM notification failed: {e}")


# --- Main Processing Endpoint ---

@app.post("/process")
async def process_scan(request: Request) -> dict:
    """Process an uploaded scan package (called by Cloud Tasks, not directly by clients).

    Single-pass pipeline (~30-40s total):
      1. Download zip, parse PLY, compute room metrics (~20s)
      2. Preview-only OpenMVS texture at 50K faces (~10-15s)
      3. Inline UV-based coverage analysis (<1s)
      4. Write "complete" with dimensions + accurate coverage

    Standard texture (300K faces for web viewer) is enqueued as an optional
    background job via /process-texture — not on the critical path.
    """
    body = await request.json()
    scan_id = body.get("scan_id")
    rfq_id = body.get("rfq_id")
    blob_path = body.get("blob_path")

    if not all([scan_id, rfq_id, blob_path]):
        raise HTTPException(status_code=400, detail="Missing required fields")

    print(f"[Processor] Starting processing for scan {scan_id}")

    with tempfile.TemporaryDirectory() as tmpdir:
        zip_path = os.path.join(tmpdir, "scan.zip")
        extract_dir = os.path.join(tmpdir, "scan")

        # Step 1: Download zip from GCS
        try:
            _download_from_gcs(blob_path, zip_path)
        except Exception as e:
            update_scan_status(scan_id, rfq_id, "failed", f"download failed: {str(e)}")
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        # Step 2: Unzip
        try:
            _extract_zip(zip_path, extract_dir)
        except Exception as e:
            update_scan_status(scan_id, rfq_id, "failed", f"unzip failed: {str(e)}")
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        # Find the scan root (may be nested in a single subdirectory from zip structure)
        scan_root = extract_dir
        entries = os.listdir(extract_dir)
        if len(entries) == 1 and os.path.isdir(os.path.join(extract_dir, entries[0])):
            scan_root = os.path.join(extract_dir, entries[0])

        # Step 3: Validate structure
        try:
            validate_structure(scan_root, scan_id)
        except ValueError as e:
            update_scan_status(scan_id, rfq_id, "failed", str(e))
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        # Step 4: Parse PLY and compute room dimensions (meters → imperial at output)
        try:
            parsed_mesh = parse_and_classify(os.path.join(scan_root, "mesh.ply"))
            room_metrics = compute_room_metrics_from_parsed(parsed_mesh)
            print(f"[Processor] Room metrics: {room_metrics}")
        except Exception as e:
            update_scan_status(scan_id, rfq_id, "failed", f"PLY parse failed: {str(e)}")
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        # Step 4b: If annotated polygon is present, use it for room dimensions
        metadata_path = os.path.join(scan_root, "metadata.json")
        with open(metadata_path, "r") as f:
            metadata = json.load(f)

        annotation = metadata.get("corner_annotation")
        polygon_result = _compute_from_annotation(annotation, room_metrics)

        # Step 4c: Upload mesh.ply to a known GCS path for direct access (signed URLs)
        mesh_gcs_path = blob_path.rsplit("/", 1)[0] + "/mesh.ply"
        try:
            _upload_to_gcs(os.path.join(scan_root, "mesh.ply"), mesh_gcs_path)
        except Exception as e:
            print(f"[Processor] Warning: mesh upload failed: {e}")
            mesh_gcs_path = None

        # Step 5: Preview-only OpenMVS texture (50K faces, ~10-15s).
        # Standard (300K) is deferred to optional /process-texture for web viewer.
        texture_manifest = None
        USE_OPENMVS = os.environ.get("USE_OPENMVS", "true").lower() == "true"

        if USE_OPENMVS:
            try:
                from pipeline.openmvs_texture import texture_scan

                tex_output = texture_scan(scan_root, metadata, levels=["preview"])

                # Upload preview texture to GCS
                gcs_base = blob_path.rsplit("/", 1)[0]
                texture_manifest = {}
                for key, local_path in tex_output.items():
                    fname = os.path.basename(local_path)
                    gcs_path = f"{gcs_base}/{fname}"
                    _upload_to_gcs(local_path, gcs_path)
                    texture_manifest[key] = fname

                print(f"[Processor] Preview texturing complete: {list(texture_manifest.keys())}")
            except Exception as e:
                print(f"[Processor] Warning: OpenMVS texturing failed: {e}")
                import traceback
                traceback.print_exc()

        # Step 6: Inline UV-based coverage analysis on preview texture output.
        # Runs on local files already in memory — no GCS download needed.
        coverage_result = None
        if texture_manifest and "obj" in tex_output:
            try:
                obj_path = tex_output["obj"]
                atlas_path = tex_output.get("atlas")
                coverage_result = _compute_coverage_from_files(obj_path, atlas_path)
                print(f"[Processor] UV coverage: {int(coverage_result['coverage_ratio'] * 100)}% "
                      f"({coverage_result['uncovered_count']}/{coverage_result['total_faces']} uncovered)")
            except Exception as e:
                print(f"[Processor] Warning: inline coverage analysis failed: {e}")
                import traceback
                traceback.print_exc()

        # Step 6b: Fast camera-viability coverage as fallback if texturing failed.
        fast_coverage = None
        if coverage_result is None:
            try:
                cameras = _load_cameras(scan_root, metadata)
                if cameras:
                    import trimesh as _trimesh
                    tri_mesh = _trimesh.Trimesh(
                        vertices=parsed_mesh.positions,
                        faces=parsed_mesh.faces,
                        vertex_normals=parsed_mesh.normals,
                        process=False,
                    )
                    uncovered = _check_face_coverage(tri_mesh, cameras)
                    total_faces = len(parsed_mesh.faces)
                    ratio = 1.0 - len(uncovered) / max(total_faces, 1)
                    fast_coverage = {
                        "coverage_ratio": round(ratio, 3),
                        "total_faces": total_faces,
                        "uncovered_count": len(uncovered),
                        "uncovered_faces": uncovered[:2000],
                    }
                    print(f"[Processor] Fallback fast coverage: {int(ratio * 100)}%")
            except Exception as e:
                print(f"[Processor] Warning: fast coverage check failed: {e}")

        # Step 7: Write "complete" with dimensions + accurate coverage + texture.
        room_data = {
            "floor_area_sqft": polygon_result["floor_area_sqft"],
            "wall_area_sqft": polygon_result["wall_area_sqft"],
            "ceiling_height_ft": polygon_result["ceiling_height_ft"],
            "perimeter_linear_ft": polygon_result["perimeter_linear_ft"],
            "detected_components": room_metrics["detected_components"],
            "scan_dimensions": polygon_result["scan_dimensions"],
            "room_polygon_ft": polygon_result.get("room_polygon_ft"),
            "wall_heights_ft": polygon_result.get("wall_heights_ft"),
            "polygon_source": polygon_result["polygon_source"],
            "scan_mesh_url": mesh_gcs_path,
            "texture_manifest": texture_manifest,
            "room_scope": metadata.get("room_scope"),
            "fast_coverage": fast_coverage,
            "coverage": coverage_result,
        }
        rfq_ready = update_scan_status(scan_id, rfq_id, "complete", room_data=room_data)
        send_fcm_notification(scan_id, "complete", rfq_ready=rfq_ready)

        print(f"[Processor] Scan {scan_id} complete (rfq_ready={rfq_ready})")

        # Optionally enqueue standard texture for web viewer (not on critical path)
        _enqueue_texture_task(scan_id, rfq_id, blob_path)

        return {"status": "complete", "scan_id": scan_id, "rfq_ready": rfq_ready}


@app.post("/process-texture")
async def process_texture(request: Request) -> dict:
    """Optional background job: generate standard-resolution (300K) texture for web viewer.

    Not on the critical path — /process already writes "complete" with preview texture
    and accurate coverage. This endpoint adds higher-resolution textures for the
    contractor web viewer.
    """
    body = await request.json()
    scan_id = body.get("scan_id")
    rfq_id = body.get("rfq_id")
    blob_path = body.get("blob_path")

    if not all([scan_id, rfq_id, blob_path]):
        raise HTTPException(status_code=400, detail="Missing required fields")

    print(f"[Processor] Starting standard texture generation for scan {scan_id}")

    with tempfile.TemporaryDirectory() as tmpdir:
        zip_path = os.path.join(tmpdir, "scan.zip")
        extract_dir = os.path.join(tmpdir, "scan")

        try:
            _download_from_gcs(blob_path, zip_path)
            _extract_zip(zip_path, extract_dir)
        except Exception as e:
            print(f"[Processor] Standard texture download/unzip failed: {e}")
            return {"status": "texture_failed", "error": str(e)}

        scan_root = _find_scan_root(extract_dir)
        if not scan_root:
            print(f"[Processor] Standard texture: scan root not found")
            return {"status": "texture_failed", "error": "scan root not found"}

        metadata_path = os.path.join(scan_root, "metadata.json")
        with open(metadata_path, "r") as f:
            metadata = json.load(f)

        # HEVC scans need frame extraction before texturing.
        if metadata.get("capture_format") == "hevc":
            result = extract_frames_from_hevc(scan_root)
            metadata["keyframe_count"] = result["frame_count"]
            metadata["keyframes"] = [
                {"index": i, "filename": f"frame_{i:04d}.jpg"}
                for i in range(result["frame_count"])
            ]

        # Select best frames for texturing (no-op if <= 1500 frames)
        _select_frames_for_texturing(scan_root, metadata)

        try:
            from pipeline.openmvs_texture import texture_scan

            tex_output = texture_scan(scan_root, metadata, levels=["standard"])

            gcs_base = blob_path.rsplit("/", 1)[0]
            texture_manifest = {}
            for key, local_path in tex_output.items():
                fname = os.path.basename(local_path)
                gcs_fname = f"standard_{fname}" if "_standard" in key else fname
                gcs_path = f"{gcs_base}/{gcs_fname}"
                _upload_to_gcs(local_path, gcs_path)
                texture_manifest[key] = gcs_fname

            # Update texture manifest in DB (merge with existing preview manifest)
            _update_texture_status(scan_id, rfq_id, texture_manifest)
            print(f"[Processor] Standard texture complete: {list(texture_manifest.keys())}")
        except Exception as e:
            print(f"[Processor] Standard texture failed: {e}")
            import traceback
            traceback.print_exc()
            return {"status": "texture_failed", "error": str(e)}

        return {"status": "standard_complete", "scan_id": scan_id}


def _enqueue_texture_task(scan_id: str, rfq_id: str, blob_path: str) -> None:
    """Enqueue Phase 2 texturing as a separate Cloud Tasks job.

    Non-fatal on failure — the scan remains in "metrics_ready" status with
    dimensions and fast coverage available. Texturing can be retried manually.
    """
    try:
        from google.cloud import tasks_v2 as _tasks_v2

        tasks_client = _tasks_v2.CloudTasksClient()
        queue_path = tasks_client.queue_path(PROJECT_ID, REGION, TASKS_QUEUE)

        task_payload = json.dumps({
            "scan_id": scan_id,
            "rfq_id": rfq_id,
            "blob_path": blob_path,
        })

        task = _tasks_v2.Task(
            http_request=_tasks_v2.HttpRequest(
                http_method=_tasks_v2.HttpMethod.POST,
                url=f"{PROCESSOR_URL}/process-texture",
                headers={"Content-Type": "application/json"},
                body=task_payload.encode(),
                oidc_token=_tasks_v2.OidcToken(
                    service_account_email=TASKS_INVOKER_SA,
                ),
            ),
        )

        tasks_client.create_task(parent=queue_path, task=task)
        print(f"[Processor] Enqueued Phase 2 texture task for scan {scan_id}")
    except Exception as e:
        print(f"[Processor] Warning: Failed to enqueue texture task: {e}")


def _update_texture_status(scan_id: str, rfq_id: str, texture_manifest: Optional[dict]) -> None:
    """Merge new texture keys into the existing texture_manifest.

    Uses JSONB || operator to merge — preserves preview keys from /process
    while adding standard keys from /process-texture.
    """
    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            """UPDATE scanned_rooms
               SET texture_manifest = COALESCE(texture_manifest, '{}'::jsonb) || %s::jsonb
               WHERE id = %s""",
            (json.dumps(texture_manifest or {}), scan_id),
        )

        # RFQ status transition: set to 'scan_ready' only when ALL rooms are complete
        cursor.execute(
            """UPDATE rfqs SET status = 'scan_ready'
               WHERE id = %s
                 AND NOT EXISTS (
                   SELECT 1 FROM scanned_rooms
                   WHERE rfq_id = %s AND scan_status != 'complete'
                 )""",
            (rfq_id, rfq_id),
        )
        conn.commit()
    finally:
        conn.close()


def _download_from_gcs(blob_path: str, dest_path: str) -> None:
    """Download a blob from GCS to a local file path."""
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(blob_path)
    blob.download_to_filename(dest_path)
    print(f"[Processor] Downloaded {blob_path} ({os.path.getsize(dest_path)} bytes)")


def _upload_to_gcs(local_path: str, blob_path: str) -> None:
    """Upload a local file to GCS."""
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(blob_path)
    blob.upload_from_filename(local_path)
    print(f"[Processor] Uploaded {blob_path} ({os.path.getsize(local_path)} bytes)")


def _select_frames_for_texturing(scan_root: str, metadata: dict, max_frames: int = 1500) -> None:
    """Select best frames for OpenMVS texturing if count exceeds max_frames.

    Modifies metadata["keyframes"] and metadata["keyframe_count"] in-place.
    No-op if frame count is already within budget or mesh is unavailable.
    """
    n = len(metadata.get("keyframes", []))
    if n <= max_frames:
        return
    mesh_ply = os.path.join(scan_root, "mesh.ply")
    if not os.path.exists(mesh_ply):
        return
    selected = select_frames(scan_root, metadata, mesh_ply, target_count=max_frames)
    print(f"[Processor] Frame selection: {n} → {len(selected)} frames")
    metadata["keyframes"] = selected
    metadata["keyframe_count"] = len(selected)


def _extract_zip(zip_path: str, extract_dir: str) -> None:
    """Validate and extract a zip archive."""
    if not zipfile.is_zipfile(zip_path):
        raise ValueError("invalid zip archive")
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(extract_dir)
    print(f"[Processor] Extracted to {extract_dir}")


# --- Package Validation ---

def validate_structure(scan_root: str, scan_id: str) -> None:
    """Validate that a scan package contains all required files with correct formats.

    Supports two capture formats:
      - "hevc": HEVC video + JSONL pose sidecar + binary depth sidecar
      - "jpeg" (or absent): Legacy discrete JPEG keyframes + per-frame JSONs + depth files

    For HEVC format, extracts individual frames from the video into keyframes/ and depth/
    directories so the rest of the pipeline can process them uniformly.

    Raises:
        ValueError: If any validation check fails (message describes the failure).
    """
    _validate_ply(scan_root)
    metadata = _validate_metadata(scan_root)

    capture_format = metadata.get("capture_format", "jpeg")

    if capture_format == "hevc":
        # HEVC format: validate video + sidecars exist, then extract frames.
        video_filename = metadata.get("video_filename", "scan_video.mov")
        pose_filename = metadata.get("pose_sidecar_filename", "poses.jsonl")
        depth_filename = metadata.get("depth_sidecar_filename", "depth.bin")

        video_path = os.path.join(scan_root, video_filename)
        pose_path = os.path.join(scan_root, pose_filename)

        if not os.path.exists(video_path):
            raise ValueError(f"missing HEVC video: {video_filename}")
        if not os.path.exists(pose_path):
            raise ValueError(f"missing pose sidecar: {pose_filename}")

        print(f"[Processor] HEVC capture format detected — extracting frames from {video_filename}")
        result = extract_frames_from_hevc(
            scan_root=scan_root,
            video_filename=video_filename,
            pose_filename=pose_filename,
            depth_filename=depth_filename,
        )
        print(f"[Processor] Extracted {result['frame_count']} frames from HEVC video")

        # After extraction, validate the generated keyframes like the legacy path.
        # Update metadata to reflect extracted frame count for downstream validation.
        metadata["keyframe_count"] = result["frame_count"]
        metadata["keyframes"] = [
            {"index": i, "filename": f"frame_{i:04d}.jpg"}
            for i in range(result["frame_count"])
        ]

        # Select best frames for texturing (no-op if <= 1500 frames)
        _select_frames_for_texturing(scan_root, metadata)

        # Write updated metadata back to disk so downstream steps (texture_scan,
        # process_texture) see the keyframes manifest when they re-read metadata.json.
        metadata_path = os.path.join(scan_root, "metadata.json")
        with open(metadata_path, "w") as f:
            json.dump(metadata, f, indent=2)

        _validate_keyframes(scan_root, metadata)
        _validate_depth_files(scan_root)
    else:
        # Legacy JPEG format: validate keyframes directly.
        _validate_keyframes(scan_root, metadata)
        _validate_depth_files(scan_root)


def _validate_ply(scan_root: str) -> tuple[int, int]:
    """Validate PLY file exists and has a well-formed header. Returns (vertex_count, face_count)."""
    ply_path = os.path.join(scan_root, "mesh.ply")
    if not os.path.exists(ply_path):
        raise ValueError("missing mesh.ply")

    # Read the ASCII header (terminated by "end_header" line).
    # Guard against corrupt files by capping how much we read.
    with open(ply_path, "rb") as f:
        header = b""
        while True:
            line = f.readline()
            header += line
            if line.strip() == b"end_header":
                break
            if len(header) > PLY_MAX_HEADER_BYTES:
                raise ValueError("invalid PLY header: header too large")

    header_str = header.decode("ascii", errors="replace")
    if not header_str.startswith("ply"):
        raise ValueError("invalid PLY header: missing 'ply' magic")

    ply_vertex_count = None
    ply_face_count = None
    for line in header_str.split("\n"):
        if line.startswith("element vertex"):
            ply_vertex_count = int(line.split()[-1])
        elif line.startswith("element face"):
            ply_face_count = int(line.split()[-1])

    if ply_vertex_count is None or ply_face_count is None:
        raise ValueError("invalid PLY header: missing vertex/face element counts")

    print(f"[Processor] PLY valid: {ply_vertex_count} vertices, {ply_face_count} faces")
    return ply_vertex_count, ply_face_count


def _validate_metadata(scan_root: str) -> dict:
    """Validate metadata.json exists with all required keys. Returns parsed metadata."""
    metadata_path = os.path.join(scan_root, "metadata.json")
    if not os.path.exists(metadata_path):
        raise ValueError("missing metadata.json")

    with open(metadata_path, "r") as f:
        metadata = json.load(f)

    capture_format = metadata.get("capture_format", "jpeg")

    if capture_format == "hevc":
        # HEVC format has different required keys.
        required_keys = [
            "device", "frame_count", "mesh_vertex_count", "mesh_face_count",
            "camera_intrinsics", "image_resolution", "video_filename",
            "pose_sidecar_filename",
        ]
        missing = [k for k in required_keys if k not in metadata]
        if missing:
            raise ValueError(f"metadata.json missing keys: {missing}")
        # Normalize: set keyframe_count from frame_count for downstream compatibility.
        metadata["keyframe_count"] = metadata["frame_count"]
        print(f"[Processor] metadata.json valid (HEVC): {metadata['frame_count']} frames, device: {metadata['device']}")
    else:
        required_keys = [
            "device", "keyframe_count", "mesh_vertex_count", "mesh_face_count",
            "camera_intrinsics", "image_resolution", "keyframes",
        ]
        missing = [k for k in required_keys if k not in metadata]
        if missing:
            raise ValueError(f"metadata.json missing keys: {missing}")
        print(f"[Processor] metadata.json valid: {metadata['keyframe_count']} keyframes, device: {metadata['device']}")

    return metadata


def _validate_keyframes(scan_root: str, metadata: dict) -> None:
    """Validate keyframe JPEGs and per-frame JSONs match metadata expectations."""
    keyframes_dir = os.path.join(scan_root, "keyframes")
    if not os.path.isdir(keyframes_dir):
        raise ValueError("missing keyframes/ directory")

    # Validate keyframes listed in metadata (not all files on disk, since frame
    # selection may have reduced the manifest while extracted files remain).
    keyframes_manifest = metadata.get("keyframes", [])
    if keyframes_manifest:
        jpeg_files = [kf["filename"] for kf in keyframes_manifest]
    else:
        jpeg_files = sorted([f for f in os.listdir(keyframes_dir) if f.endswith(".jpg")])
    json_files = [f.replace(".jpg", ".json") for f in jpeg_files]

    # Validate JPEG headers — every JPEG starts with the SOI marker (0xFFD8)
    valid_jpegs = 0
    for jpg in jpeg_files:
        jpg_path = os.path.join(keyframes_dir, jpg)
        if not os.path.exists(jpg_path):
            raise ValueError(f"keyframe {jpg} listed in metadata but not found on disk")
        with open(jpg_path, "rb") as f:
            header = f.read(2)
            if header == b"\xff\xd8":
                valid_jpegs += 1
            else:
                raise ValueError(f"{jpg} is not a valid JPEG (missing SOI marker)")
    print(f"[Processor] {valid_jpegs}/{len(jpeg_files)} keyframes valid JPEG")

    # Validate per-frame JSONs contain a 16-element camera_transform (4×4 column-major matrix)
    valid_jsons = 0
    for jf in json_files:
        jf_path = os.path.join(keyframes_dir, jf)
        with open(jf_path, "r") as f:
            frame_data = json.load(f)
        transform = frame_data.get("camera_transform", [])
        if len(transform) != CAMERA_TRANSFORM_LENGTH:
            raise ValueError(f"{jf} has invalid camera_transform (expected {CAMERA_TRANSFORM_LENGTH} elements, got {len(transform)})")
        valid_jsons += 1
    print(f"[Processor] {valid_jsons}/{len(json_files)} frame JSONs valid")


def _validate_depth_files(scan_root: str) -> None:
    """Validate depth map files (if present) are non-empty."""
    depth_dir = os.path.join(scan_root, "depth")
    if os.path.isdir(depth_dir):
        depth_files = [f for f in os.listdir(depth_dir) if f.endswith(".depth")]
        for df in depth_files:
            df_path = os.path.join(depth_dir, df)
            if os.path.getsize(df_path) == 0:
                raise ValueError(f"depth file {df} is empty")
        print(f"[Processor] {len(depth_files)} depth files valid")


# --- Room Metrics Computation ---

def compute_room_metrics(ply_path: str) -> dict:
    """Parse a binary PLY mesh and compute real room dimensions from classified geometry."""
    try:
        mesh = parse_and_classify(ply_path)
    except ValueError:
        return _empty_metrics()
    return compute_room_metrics_from_parsed(mesh)


def compute_room_metrics_from_parsed(mesh: ParsedMesh) -> dict:
    """Compute real room dimensions from an already-parsed classified mesh.

    All vertex positions are in meters (ARKit Y-up, right-handed coordinate system).
    Output dimensions are converted to imperial (sq ft / ft) at the return boundary.

    Returns:
        Dict with keys: floor_area_sqft, wall_area_sqft, ceiling_height_ft,
        perimeter_linear_ft, detected_components, scan_dimensions.
    """
    # Compute surface areas by classification (in meters²)
    floor_area_m2 = _sum_triangle_area(mesh, CLASSIFICATION_FLOOR)
    wall_area_m2 = _sum_triangle_area(mesh, CLASSIFICATION_WALL)

    # Ceiling height: distance from lowest floor vertex to highest ceiling vertex (Y-axis in ARKit)
    ceiling_height_m = _compute_ceiling_height(mesh)

    # Perimeter: convex hull of floor vertices projected onto the XZ (ground) plane
    perimeter_m = _compute_floor_perimeter(mesh)

    # Detected surface/object types present in the mesh (ARKit classifications)
    arkit_labels = [
        g.classification_name
        for cid, g in sorted(mesh.classification_groups.items())
        if cid != CLASSIFICATION_NONE
    ]

    # detected_components JSONB — Miro format (DB Board Section 5 updated):
    #   { "detected": ["label_key_1", "label_key_2", ...] }
    # Phase 2 stub: map ARKit classifications to SCAN_COMPONENT_LABELS label_keys.
    # When the DNN is active, this will contain real label_keys from inference.
    PHASE2_MATERIAL_MAP = {
        "floor": ["floor_hardwood"],
        "ceiling": ["ceiling_drywall"],
    }
    detected_label_keys = []
    for arkit_class in arkit_labels:
        detected_label_keys.extend(PHASE2_MATERIAL_MAP.get(arkit_class, []))

    print(f"[Processor] Floor: {floor_area_m2:.2f}m² ({floor_area_m2 * SQM_TO_SQFT:.0f}sqft), "
          f"Walls: {wall_area_m2:.2f}m² ({wall_area_m2 * SQM_TO_SQFT:.0f}sqft), "
          f"Ceiling: {ceiling_height_m:.2f}m ({ceiling_height_m * M_TO_FT:.1f}ft), "
          f"Perimeter: {perimeter_m:.2f}m ({perimeter_m * M_TO_FT:.0f}ft)")

    floor_area_sf = round(floor_area_m2 * SQM_TO_SQFT, 1)
    wall_area_sf = round(wall_area_m2 * SQM_TO_SQFT, 1)
    ceiling_height_ft = round(ceiling_height_m * M_TO_FT, 1)
    perimeter_lf = round(perimeter_m * M_TO_FT, 1)

    # Count doors from ARKit classification (7 = door in stage1 CLASSIFICATION_NAMES)
    door_group = mesh.classification_groups.get(7)
    door_count = door_group.face_count if door_group else 0

    # scan_dimensions JSONB — standardized keys for LINE_ITEM_TEMPLATES auto-population
    # (Miro DB Board Section 5 updated). Top-level keys are the auto-population contract.
    scan_dims = {
        "floor_area_sf": floor_area_sf,
        "wall_area_sf": wall_area_sf,
        "ceiling_sf": floor_area_sf,  # flat ceiling = floor area; sloped TBD
        "perimeter_lf": perimeter_lf,
        "ceiling_height_ft": ceiling_height_ft,
        "ceiling_height_min_ft": None,
        "ceiling_height_max_ft": None,
        "door_count": door_count,
        "door_opening_lf": None,
        "transition_count": None,
        "bbox": mesh.bbox,
    }

    return {
        "floor_area_sqft": floor_area_sf,
        "wall_area_sqft": wall_area_sf,
        "ceiling_height_ft": ceiling_height_ft,
        "perimeter_linear_ft": perimeter_lf,
        "detected_components": {"detected": detected_label_keys},
        "scan_dimensions": scan_dims,
    }


def _compute_ceiling_height(mesh: ParsedMesh) -> float:
    """Compute ceiling height as the Y-distance between floor and ceiling vertices.

    Uses median floor Y and 90th percentile ceiling Y instead of min/max
    to exclude outlier mesh vertices that extend below/above the actual surfaces.
    """
    import numpy as np
    floor_group = mesh.classification_groups.get(CLASSIFICATION_FLOOR)
    ceiling_group = mesh.classification_groups.get(CLASSIFICATION_CEILING)

    if floor_group and ceiling_group and len(floor_group.vertex_ids) > 0 and len(ceiling_group.vertex_ids) > 0:
        floor_ys = mesh.positions[floor_group.vertex_ids, 1]
        ceiling_ys = mesh.positions[ceiling_group.vertex_ids, 1]
        floor_y = float(np.median(floor_ys))
        ceiling_y = float(np.percentile(ceiling_ys, 90))
        return ceiling_y - floor_y
    return 0.0


def _compute_floor_perimeter(mesh: ParsedMesh) -> float:
    """Compute floor perimeter from the convex hull of floor vertices on the XZ plane."""
    floor_group = mesh.classification_groups.get(CLASSIFICATION_FLOOR)
    if not floor_group or len(floor_group.vertex_ids) <= 2:
        return 0.0

    floor_xz = mesh.positions[floor_group.vertex_ids][:, [0, 2]]
    try:
        from scipy.spatial import ConvexHull
        hull = ConvexHull(floor_xz)
        hull_pts = floor_xz[hull.vertices]
        rolled = np.roll(hull_pts, -1, axis=0)
        return float(np.sum(np.linalg.norm(rolled - hull_pts, axis=1)))
    except Exception:
        return 2.0 * (mesh.bbox["x_m"] + mesh.bbox["z_m"])


def _sum_triangle_area(mesh: ParsedMesh, target_class: int) -> float:
    """Sum the area (in meters²) of all triangles with the given classification."""
    group = mesh.classification_groups.get(target_class)
    if not group:
        return 0.0

    group_faces = mesh.faces[group.face_indices]
    v0 = mesh.positions[group_faces[:, 0]]
    v1 = mesh.positions[group_faces[:, 1]]
    v2 = mesh.positions[group_faces[:, 2]]
    crosses = np.cross(v1 - v0, v2 - v0)
    areas = 0.5 * np.linalg.norm(crosses, axis=1)
    return float(areas.sum())


def _empty_metrics() -> dict:
    """Return zeroed-out metrics for meshes with no vertices."""
    return {
        "floor_area_sqft": 0, "wall_area_sqft": 0, "ceiling_height_ft": 0,
        "perimeter_linear_ft": 0,
        "detected_components": {"detected": []},
        "scan_dimensions": {
            "floor_area_sf": 0, "wall_area_sf": 0, "ceiling_sf": 0,
            "perimeter_lf": 0, "ceiling_height_ft": 0,
            "ceiling_height_min_ft": None, "ceiling_height_max_ft": None,
            "door_count": 0, "door_opening_lf": None, "transition_count": None,
            "bbox": {"x_m": 0, "y_m": 0, "z_m": 0},
        },
    }


def _estimate_floor_y(room_metrics: dict) -> float:
    """Estimate floor Y coordinate from ceiling height and PLY metrics."""
    ceiling_ft = room_metrics.get("ceiling_height_ft", 0)
    if ceiling_ft and ceiling_ft > 0:
        ceiling_m = ceiling_ft / M_TO_FT
        # Assume ceiling Y is roughly the average corners_y,
        # floor Y is ceiling_y - ceiling_height
        # For simplicity, assume floor is at Y=0 (ARKit origin is typically near floor)
        return 0.0
    return 0.0


def _compute_from_annotation(annotation: Optional[dict], ply_metrics: dict) -> dict:
    """Compute room dimensions from the user-annotated polygon when present.

    If annotation is present and valid, uses the polygon for floor area, perimeter,
    and wall area (polygon perimeter × ceiling height). Ceiling height still comes
    from the PLY mesh RANSAC (more accurate than corner Y values alone).

    If annotation is absent, returns the PLY-derived metrics unchanged with
    polygon_source='geometric'.

    Args:
        annotation: The corner_annotation dict from metadata.json, or None.
        ply_metrics: Room metrics already computed from the PLY mesh.

    Returns:
        Dict with the same keys as ply_metrics plus room_polygon_ft,
        wall_heights_ft, and polygon_source.
    """
    if not annotation:
        result = dict(ply_metrics)
        result["polygon_source"] = "geometric"
        result["room_polygon_ft"] = None
        result["wall_heights_ft"] = None
        return result

    corners_xz = annotation.get("corners_xz", [])
    corners_y = annotation.get("corners_y", [])

    if len(corners_xz) < 3:
        result = dict(ply_metrics)
        result["polygon_source"] = "geometric"
        result["room_polygon_ft"] = None
        result["wall_heights_ft"] = None
        return result

    # Convert polygon from meters to feet
    polygon_ft = [[round(c[0] * M_TO_FT, 2), round(c[1] * M_TO_FT, 2)] for c in corners_xz]
    wall_heights_ft = [round(y * M_TO_FT, 2) for y in corners_y] if corners_y else None

    # Floor area via shoelace formula (meters, then convert)
    n = len(corners_xz)
    signed_area = 0.0
    for i in range(n):
        j = (i + 1) % n
        signed_area += corners_xz[i][0] * corners_xz[j][1] - corners_xz[j][0] * corners_xz[i][1]
    floor_area_m2 = abs(signed_area) / 2.0

    # Perimeter (meters, then convert)
    perimeter_m = 0.0
    for i in range(n):
        j = (i + 1) % n
        dx = corners_xz[j][0] - corners_xz[i][0]
        dz = corners_xz[j][1] - corners_xz[i][1]
        perimeter_m += (dx * dx + dz * dz) ** 0.5

    # Use PLY-derived ceiling height (RANSAC is more accurate than corner Y values)
    ceiling_height_ft = ply_metrics["ceiling_height_ft"]
    ceiling_height_m = ceiling_height_ft / M_TO_FT if ceiling_height_ft else 0.0

    # Wall area = perimeter × ceiling height
    wall_area_m2 = perimeter_m * ceiling_height_m

    floor_area_sf = round(floor_area_m2 * SQM_TO_SQFT, 1)
    wall_area_sf = round(wall_area_m2 * SQM_TO_SQFT, 1)
    perimeter_lf = round(perimeter_m * M_TO_FT, 1)

    # Rebuild scan_dimensions with polygon-derived values
    scan_dims = dict(ply_metrics.get("scan_dimensions", {}))
    scan_dims["floor_area_sf"] = floor_area_sf
    scan_dims["wall_area_sf"] = wall_area_sf
    scan_dims["ceiling_sf"] = floor_area_sf
    scan_dims["perimeter_lf"] = perimeter_lf

    print(f"[Processor] Annotated polygon: {n} corners, "
          f"floor={floor_area_m2:.2f}m² ({floor_area_sf}sqft), "
          f"perimeter={perimeter_m:.2f}m ({perimeter_lf}ft)")

    return {
        "floor_area_sqft": floor_area_sf,
        "wall_area_sqft": wall_area_sf,
        "ceiling_height_ft": ceiling_height_ft,
        "perimeter_linear_ft": perimeter_lf,
        "detected_components": ply_metrics["detected_components"],
        "scan_dimensions": scan_dims,
        "room_polygon_ft": polygon_ft,
        "wall_heights_ft": wall_heights_ft,
        "polygon_source": "annotated",
    }


def _compute_coverage_from_files(obj_path: str, atlas_path: str | None) -> dict:
    """Compute UV-based texture coverage from local OBJ + atlas files.

    Analyzes the OpenMVS output: faces with degenerate UV (near-zero area) are
    untextured. Faces with valid UV but black atlas pixels are occluded.
    Also runs ray-cast hole detection with 2K rays for speed.

    Returns dict with coverage_ratio, uncovered_count, uncovered_faces, etc.
    """
    from PIL import Image

    # Parse OBJ
    vertices = []
    vt_coords = []
    face_vert_indices = []
    face_uv_indices = []

    with open(obj_path) as f:
        for line in f:
            if line.startswith("v "):
                parts = line.split()
                vertices.append([float(parts[1]), float(parts[2]), float(parts[3])])
            elif line.startswith("vt "):
                parts = line.split()
                vt_coords.append([float(parts[1]), float(parts[2])])
            elif line.startswith("f "):
                parts = line.split()[1:]
                vi, ui = [], []
                for p in parts:
                    segs = p.split("/")
                    vi.append(int(segs[0]) - 1)
                    ui.append(int(segs[1]) - 1 if len(segs) >= 2 and segs[1] else 0)
                face_vert_indices.append(vi)
                face_uv_indices.append(ui)

    vertices = np.array(vertices, dtype=np.float64)
    vt = np.array(vt_coords, dtype=np.float64)
    total_faces = len(face_vert_indices)

    # Vectorized UV area analysis
    UV_AREA_THRESHOLD = 1e-6
    face_vi = np.array(face_vert_indices, dtype=np.int64)
    face_ui = np.array(face_uv_indices, dtype=np.int64)

    v0 = vertices[face_vi[:, 0]]
    v1 = vertices[face_vi[:, 1]]
    v2 = vertices[face_vi[:, 2]]
    face_areas = 0.5 * np.linalg.norm(np.cross(v1 - v0, v2 - v0), axis=1)
    total_area = float(face_areas.sum())

    uv0 = vt[face_ui[:, 0]]
    uv1 = vt[face_ui[:, 1]]
    uv2 = vt[face_ui[:, 2]]
    uv_areas = 0.5 * np.abs(
        (uv1[:, 0] - uv0[:, 0]) * (uv2[:, 1] - uv0[:, 1]) -
        (uv2[:, 0] - uv0[:, 0]) * (uv1[:, 1] - uv0[:, 1])
    )

    degenerate_mask = uv_areas < UV_AREA_THRESHOLD

    # Black pixel check
    black_mask = np.zeros(total_faces, dtype=bool)
    if atlas_path and os.path.exists(atlas_path):
        atlas_img = Image.open(atlas_path).convert("RGB")
        atlas_pixels = np.array(atlas_img)
        atlas_h, atlas_w = atlas_pixels.shape[:2]

        valid_mask = ~degenerate_mask
        if valid_mask.any():
            uv_center_u = (uv0[valid_mask, 0] + uv1[valid_mask, 0] + uv2[valid_mask, 0]) / 3.0
            uv_center_v = (uv0[valid_mask, 1] + uv1[valid_mask, 1] + uv2[valid_mask, 1]) / 3.0
            px = np.clip((uv_center_u * atlas_w).astype(int), 0, atlas_w - 1)
            py = np.clip(((1.0 - uv_center_v) * atlas_h).astype(int), 0, atlas_h - 1)
            colors = atlas_pixels[py, px]
            color_sum = colors.astype(np.int32).sum(axis=1)
            valid_black = color_sum < 30
            black_mask[valid_mask] = valid_black

    gap_mask = degenerate_mask | black_mask
    uncovered_area = float(face_areas[gap_mask].sum())
    gap_indices = np.where(gap_mask)[0]

    uncovered = []
    for i in gap_indices[:2000]:
        vi = face_vi[i]
        uncovered.append({
            "vertices": [
                [round(float(vertices[vi[0]][0]), 4), round(float(vertices[vi[0]][1]), 4), round(float(vertices[vi[0]][2]), 4)],
                [round(float(vertices[vi[1]][0]), 4), round(float(vertices[vi[1]][1]), 4), round(float(vertices[vi[1]][2]), 4)],
                [round(float(vertices[vi[2]][0]), 4), round(float(vertices[vi[2]][1]), 4), round(float(vertices[vi[2]][2]), 4)],
            ],
        })

    n_degenerate = int(degenerate_mask.sum())
    n_black = int(black_mask.sum())
    coverage_ratio = 1.0 - (uncovered_area / max(total_area, 1e-6))

    # Reduced ray-cast hole detection (2K rays for speed, ~1-3s)
    import trimesh as _trimesh
    hole_faces = []
    try:
        tri_mesh = _trimesh.Trimesh(
            vertices=vertices,
            faces=np.array(face_vert_indices, dtype=np.int64),
            process=False,
        )
        center = vertices.mean(axis=0)
        bbox_min = vertices.min(axis=0) - 0.1
        bbox_max = vertices.max(axis=0) + 0.1

        n_rays = int(os.environ.get("HOLE_DETECTION_RAYS", "2000"))
        golden_ratio = (1 + np.sqrt(5)) / 2
        directions = np.zeros((n_rays, 3))
        for ri in range(n_rays):
            theta = np.arccos(1 - 2 * (ri + 0.5) / n_rays)
            phi = 2 * np.pi * ri / golden_ratio
            directions[ri] = [np.sin(theta) * np.cos(phi),
                              np.sin(theta) * np.sin(phi),
                              np.cos(theta)]
        origins = np.tile(center, (n_rays, 1))

        _, ray_ids, _ = tri_mesh.ray.intersects_location(origins, directions, multiple_hits=False)
        hit_set = set(ray_ids)
        miss_indices = [i for i in range(n_rays) if i not in hit_set]

        patch_size = 0.15
        for mi in miss_indices:
            d = directions[mi]
            t_max = np.inf
            for ax in range(3):
                if abs(d[ax]) < 1e-10:
                    continue
                t1 = (bbox_min[ax] - center[ax]) / d[ax]
                t2 = (bbox_max[ax] - center[ax]) / d[ax]
                t_max = min(t_max, max(t1, t2))
            if t_max <= 0 or t_max == np.inf:
                continue

            hit_pt = center + d * t_max
            up = np.array([0, 1, 0]) if abs(d[1]) < 0.9 else np.array([1, 0, 0])
            right = np.cross(d, up)
            right = right / (np.linalg.norm(right) + 1e-10) * patch_size * 0.5
            up_v = np.cross(right, d)
            up_v = up_v / (np.linalg.norm(up_v) + 1e-10) * patch_size * 0.5

            p0 = hit_pt - right - up_v
            p1 = hit_pt + right - up_v
            p2 = hit_pt + right + up_v
            p3 = hit_pt - right + up_v
            hole_faces.append({"vertices": [
                [round(float(p0[0]), 4), round(float(p0[1]), 4), round(float(p0[2]), 4)],
                [round(float(p1[0]), 4), round(float(p1[1]), 4), round(float(p1[2]), 4)],
                [round(float(p2[0]), 4), round(float(p2[1]), 4), round(float(p2[2]), 4)],
            ]})
            hole_faces.append({"vertices": [
                [round(float(p0[0]), 4), round(float(p0[1]), 4), round(float(p0[2]), 4)],
                [round(float(p2[0]), 4), round(float(p2[1]), 4), round(float(p2[2]), 4)],
                [round(float(p3[0]), 4), round(float(p3[1]), 4), round(float(p3[2]), 4)],
            ]})
    except Exception as e:
        print(f"[Coverage] Hole detection failed: {e}")

    return {
        "status": "ok",
        "coverage_ratio": round(coverage_ratio, 3),
        "total_faces": total_faces,
        "uncovered_count": len(uncovered),
        "uncovered_area_m2": round(uncovered_area, 2),
        "total_area_m2": round(total_area, 2),
        "uncovered_faces": uncovered,
        "hole_count": len(hole_faces),
        "hole_faces": hole_faces[:2000],
    }


@app.post("/coverage")
async def check_coverage(request: Request) -> dict:
    """Check texture coverage by analyzing OpenMVS UV mapping.

    OpenMVS assigns degenerate UV coordinates (near-zero UV area) to faces
    it cannot texture. This is the authoritative signal — not pixel colors.

    Downloads the preview textured OBJ from GCS, parses per-face UV triangles,
    and flags faces with near-zero UV area as uncovered.

    Returns uncovered face centroids + normals so the app can render AR overlay patches.
    """
    body = await request.json()
    scan_id = body.get("scan_id")
    rfq_id = body.get("rfq_id")
    blob_path = body.get("blob_path")

    if not all([scan_id, rfq_id, blob_path]):
        raise HTTPException(status_code=400, detail="Missing required fields")

    print(f"[Coverage] Starting coverage check for scan {scan_id}")

    from PIL import Image

    with tempfile.TemporaryDirectory() as tmpdir:
        # Download textured OBJ + atlas from GCS
        gcs_base = blob_path.rsplit("/", 1)[0]  # scans/{rfq_id}/{scan_id}
        obj_blob = f"{gcs_base}/textured.obj"
        atlas_blob = f"{gcs_base}/textured_material_00_map_Kd.jpg"
        obj_path = os.path.join(tmpdir, "textured.obj")
        atlas_path = os.path.join(tmpdir, "atlas.jpg")

        try:
            _download_from_gcs(obj_blob, obj_path)
            _download_from_gcs(atlas_blob, atlas_path)
        except Exception as e:
            return {"status": "error", "error": f"Failed to download textured mesh: {e}"}

        # Load atlas for black-face detection
        atlas_img = Image.open(atlas_path).convert("RGB")
        atlas_pixels = np.array(atlas_img)
        atlas_h, atlas_w = atlas_pixels.shape[:2]

        # Parse OBJ manually — trimesh can mangle per-face UV indices
        vertices = []
        vt_coords = []
        face_vert_indices = []
        face_uv_indices = []

        with open(obj_path) as f:
            for line in f:
                if line.startswith("v "):
                    parts = line.split()
                    vertices.append([float(parts[1]), float(parts[2]), float(parts[3])])
                elif line.startswith("vt "):
                    parts = line.split()
                    vt_coords.append([float(parts[1]), float(parts[2])])
                elif line.startswith("f "):
                    parts = line.split()[1:]
                    vi, ui = [], []
                    for p in parts:
                        segs = p.split("/")
                        vi.append(int(segs[0]) - 1)
                        ui.append(int(segs[1]) - 1 if len(segs) >= 2 and segs[1] else 0)
                    face_vert_indices.append(vi)
                    face_uv_indices.append(ui)

        vertices = np.array(vertices, dtype=np.float64)
        vt = np.array(vt_coords, dtype=np.float64)
        total_faces = len(face_vert_indices)
        print(f"[Coverage] Parsed OBJ: {len(vertices)} vertices, {len(vt)} UVs, {total_faces} faces")

        # Vectorized per-face 3D area and UV area computation
        UV_AREA_THRESHOLD = 1e-6

        face_vi = np.array(face_vert_indices, dtype=np.int64)
        face_ui = np.array(face_uv_indices, dtype=np.int64)

        # 3D face areas (vectorized cross product)
        v0 = vertices[face_vi[:, 0]]
        v1 = vertices[face_vi[:, 1]]
        v2 = vertices[face_vi[:, 2]]
        face_areas = 0.5 * np.linalg.norm(np.cross(v1 - v0, v2 - v0), axis=1)
        total_area = float(face_areas.sum())

        # UV areas (vectorized 2D cross product)
        uv0 = vt[face_ui[:, 0]]
        uv1 = vt[face_ui[:, 1]]
        uv2 = vt[face_ui[:, 2]]
        uv_areas = 0.5 * np.abs(
            (uv1[:, 0] - uv0[:, 0]) * (uv2[:, 1] - uv0[:, 1]) -
            (uv2[:, 0] - uv0[:, 0]) * (uv1[:, 1] - uv0[:, 1])
        )

        # Degenerate UV mask (OpenMVS couldn't assign a camera → orange in viewer)
        degenerate_mask = uv_areas < UV_AREA_THRESHOLD

        # Black pixel check for non-degenerate faces (valid UV but dark/occluded)
        valid_mask = ~degenerate_mask
        black_mask = np.zeros(total_faces, dtype=bool)
        if valid_mask.any():
            uv_center_u = (uv0[valid_mask, 0] + uv1[valid_mask, 0] + uv2[valid_mask, 0]) / 3.0
            uv_center_v = (uv0[valid_mask, 1] + uv1[valid_mask, 1] + uv2[valid_mask, 1]) / 3.0
            px = np.clip((uv_center_u * atlas_w).astype(int), 0, atlas_w - 1)
            py = np.clip(((1.0 - uv_center_v) * atlas_h).astype(int), 0, atlas_h - 1)
            colors = atlas_pixels[py, px]  # (N, 3)
            color_sum = colors.astype(np.int32).sum(axis=1)
            valid_black = color_sum < 30
            black_mask[valid_mask] = valid_black

        # Combined gap mask
        gap_mask = degenerate_mask | black_mask
        uncovered_area = float(face_areas[gap_mask].sum())
        gap_indices = np.where(gap_mask)[0]

        # Build uncovered face list (vertices for AR overlay)
        uncovered = []
        for i in gap_indices:
            vi = face_vi[i]
            uncovered.append({
                "vertices": [
                    [round(float(vertices[vi[0]][0]), 4), round(float(vertices[vi[0]][1]), 4), round(float(vertices[vi[0]][2]), 4)],
                    [round(float(vertices[vi[1]][0]), 4), round(float(vertices[vi[1]][1]), 4), round(float(vertices[vi[1]][2]), 4)],
                    [round(float(vertices[vi[2]][0]), 4), round(float(vertices[vi[2]][1]), 4), round(float(vertices[vi[2]][2]), 4)],
                ],
            })

        n_degenerate = int(degenerate_mask.sum())
        n_black = int(black_mask.sum())
        coverage_ratio = 1.0 - (uncovered_area / max(total_area, 1e-6))
        print(f"[Coverage] {total_faces} faces: {n_degenerate} degenerate UV + {n_black} black = "
              f"{len(uncovered)} uncovered, "
              f"area: {uncovered_area:.2f}/{total_area:.2f} m² "
              f"({int((1 - coverage_ratio) * 100)}% gaps)")

        # --- Mesh hole detection via ray casting ---
        import trimesh as _trimesh

        hole_faces = []
        try:
            tri_mesh = _trimesh.Trimesh(
                vertices=vertices,
                faces=np.array(face_vert_indices, dtype=np.int64),
                process=False,
            )
            center = vertices.mean(axis=0)
            bbox_min = vertices.min(axis=0) - 0.1
            bbox_max = vertices.max(axis=0) + 0.1

            # 10K fibonacci-sphere rays from mesh centroid
            n_rays = 10000
            golden_ratio = (1 + np.sqrt(5)) / 2
            directions = np.zeros((n_rays, 3))
            for ri in range(n_rays):
                theta = np.arccos(1 - 2 * (ri + 0.5) / n_rays)
                phi = 2 * np.pi * ri / golden_ratio
                directions[ri] = [np.sin(theta) * np.cos(phi),
                                  np.sin(theta) * np.sin(phi),
                                  np.cos(theta)]
            origins = np.tile(center, (n_rays, 1))

            _, ray_ids, _ = tri_mesh.ray.intersects_location(origins, directions, multiple_hits=False)
            hit_set = set(ray_ids)
            miss_indices = [i for i in range(n_rays) if i not in hit_set]

            patch_size = 0.15
            for mi in miss_indices:
                d = directions[mi]
                # Ray-AABB exit point
                t_max = np.inf
                for ax in range(3):
                    if abs(d[ax]) < 1e-10:
                        continue
                    t1 = (bbox_min[ax] - center[ax]) / d[ax]
                    t2 = (bbox_max[ax] - center[ax]) / d[ax]
                    t_max = min(t_max, max(t1, t2))
                if t_max <= 0 or t_max == np.inf:
                    continue

                hit_pt = center + d * t_max
                up = np.array([0, 1, 0]) if abs(d[1]) < 0.9 else np.array([1, 0, 0])
                right = np.cross(d, up)
                right = right / (np.linalg.norm(right) + 1e-10) * patch_size * 0.5
                up_v = np.cross(right, d)
                up_v = up_v / (np.linalg.norm(up_v) + 1e-10) * patch_size * 0.5

                p0, p1, p2, p3 = hit_pt - right - up_v, hit_pt + right - up_v, hit_pt + right + up_v, hit_pt - right + up_v
                hole_faces.append({"vertices": [
                    [round(float(p0[0]), 4), round(float(p0[1]), 4), round(float(p0[2]), 4)],
                    [round(float(p1[0]), 4), round(float(p1[1]), 4), round(float(p1[2]), 4)],
                    [round(float(p2[0]), 4), round(float(p2[1]), 4), round(float(p2[2]), 4)],
                ]})
                hole_faces.append({"vertices": [
                    [round(float(p0[0]), 4), round(float(p0[1]), 4), round(float(p0[2]), 4)],
                    [round(float(p2[0]), 4), round(float(p2[1]), 4), round(float(p2[2]), 4)],
                    [round(float(p3[0]), 4), round(float(p3[1]), 4), round(float(p3[2]), 4)],
                ]})

            print(f"[Coverage] Ray cast: {n_rays} rays, {len(hit_set)} hits, "
                  f"{len(miss_indices)} misses → {len(hole_faces)} hole triangles")
        except Exception as e:
            print(f"[Coverage] Hole detection failed: {e}")

        return {
            "status": "ok",
            "coverage_ratio": round(coverage_ratio, 3),
            "total_faces": total_faces,
            "uncovered_count": len(uncovered),
            "uncovered_area_m2": round(uncovered_area, 2),
            "total_area_m2": round(total_area, 2),
            "uncovered_faces": uncovered[:2000],
            "hole_count": len(hole_faces),
            "hole_faces": hole_faces[:2000],
        }


def _load_cameras(scan_root: str, metadata: dict) -> list[dict]:
    """Load camera transforms and intrinsics from scan metadata + per-frame JSONs."""
    cameras = []
    intrinsics = metadata.get("camera_intrinsics", {})
    fx = intrinsics.get("fx", 0)
    fy = intrinsics.get("fy", 0)
    cx = intrinsics.get("cx", 0)
    cy = intrinsics.get("cy", 0)
    img_res = metadata.get("image_resolution", {})
    img_w = img_res.get("width", 1920)
    img_h = img_res.get("height", 1440)

    keyframes_dir = os.path.join(scan_root, "keyframes")
    for kf in metadata.get("keyframes", []):
        frame_json_path = os.path.join(keyframes_dir, kf["filename"].replace(".jpg", ".json"))
        if not os.path.exists(frame_json_path):
            continue
        with open(frame_json_path) as f:
            frame_data = json.load(f)
        transform = frame_data.get("camera_transform")
        if not transform or len(transform) != 16:
            continue

        # camera_transform is world-from-camera, 4x4 column-major
        T = np.array(transform, dtype=np.float64).reshape(4, 4, order='F')
        cam_pos = T[:3, 3]
        cam_from_world = np.linalg.inv(T)

        cameras.append({
            "position": cam_pos,
            "cam_from_world": cam_from_world,
            "fx": fx, "fy": fy, "cx": cx, "cy": cy,
            "img_w": img_w, "img_h": img_h,
        })

    return cameras


def _check_face_coverage(mesh, cameras: list[dict]) -> list[dict]:
    """Check which mesh faces have no viable camera. Returns uncovered face data."""
    # Thresholds matching MeshCoverageAnalyzer.swift and OpenMVS criteria
    MIN_DISTANCE = 0.2
    MAX_DISTANCE = 5.0
    MIN_ANGLE_WALL = 0.1       # ~84° from perpendicular
    MIN_ANGLE_FLOOR_CEIL = 0.02  # ~89°
    IMAGE_MARGIN = 50.0

    vertices = np.array(mesh.vertices, dtype=np.float64)
    faces = np.array(mesh.faces)
    face_normals = np.array(mesh.face_normals, dtype=np.float64)

    # Compute face centroids
    v0 = vertices[faces[:, 0]]
    v1 = vertices[faces[:, 1]]
    v2 = vertices[faces[:, 2]]
    centroids = (v0 + v1 + v2) / 3.0

    # Classify faces by normal direction (Y-component > 0.7 = floor/ceiling)
    is_floor_ceil = np.abs(face_normals[:, 1]) > 0.7

    uncovered = []
    for i in range(len(faces)):
        centroid = centroids[i]
        normal = face_normals[i]
        angle_threshold = MIN_ANGLE_FLOOR_CEIL if is_floor_ceil[i] else MIN_ANGLE_WALL
        has_viable = False

        for cam in cameras:
            to_cam = cam["position"] - centroid
            dist = np.linalg.norm(to_cam)
            if dist < MIN_DISTANCE or dist > MAX_DISTANCE:
                continue

            # Viewing angle
            to_cam_norm = to_cam / dist
            angle_dot = np.dot(normal, to_cam_norm)
            if angle_dot < angle_threshold:
                continue

            # Projection bounds check
            world_pt = np.append(centroid, 1.0)
            cam_pt = cam["cam_from_world"] @ world_pt
            depth = -cam_pt[2]
            if depth < 0.1:
                continue

            px = cam["fx"] * cam_pt[0] / depth + cam["cx"]
            py = -cam["fy"] * cam_pt[1] / depth + cam["cy"]

            if (px >= IMAGE_MARGIN and px < cam["img_w"] - IMAGE_MARGIN and
                    py >= IMAGE_MARGIN and py < cam["img_h"] - IMAGE_MARGIN):
                has_viable = True
                break

        if not has_viable:
            uncovered.append({
                "centroid": [round(float(centroid[0]), 4),
                             round(float(centroid[1]), 4),
                             round(float(centroid[2]), 4)],
                "normal": [round(float(normal[0]), 4),
                           round(float(normal[1]), 4),
                           round(float(normal[2]), 4)],
            })

    return uncovered


def _find_scan_root(extract_dir: str) -> Optional[str]:
    """Find the scan root directory (contains mesh.ply + metadata.json)."""
    # Could be directly in extract_dir or one level down
    if os.path.exists(os.path.join(extract_dir, "mesh.ply")):
        return extract_dir
    for entry in os.listdir(extract_dir):
        candidate = os.path.join(extract_dir, entry)
        if os.path.isdir(candidate) and os.path.exists(os.path.join(candidate, "mesh.ply")):
            return candidate
    return None


@app.post("/process-supplemental")
async def process_supplemental(request: Request) -> dict:
    """Merge supplemental scan data with original and re-texture.

    Called by Cloud Tasks after a supplemental scan is uploaded to GCS.
    Downloads both original scan.zip and supplemental_scan.zip, merges
    meshes (additive only) and keyframes, then re-runs OpenMVS TextureMesh.

    Steps:
      1. Download original scan.zip + supplemental_scan.zip from GCS.
      2. Merge meshes: keep supplemental faces only in void regions (>3cm from original).
      3. Merge keyframes: continuous numbering, unified metadata.
      4. Re-run texture_scan() on merged data.
      5. Upload new textured OBJ/atlas to GCS (overwrites previous).
      6. Update scan status in DB.
    """
    body = await request.json()
    scan_id = body.get("scan_id")
    rfq_id = body.get("rfq_id")
    original_blob = body.get("original_blob_path")
    supplemental_blob = body.get("supplemental_blob_path")

    if not all([scan_id, rfq_id, original_blob, supplemental_blob]):
        raise HTTPException(status_code=400, detail="Missing required fields")

    print(f"[Processor] Starting supplemental merge for scan {scan_id}")

    # Mark as processing
    update_scan_status(scan_id, rfq_id, "processing")

    with tempfile.TemporaryDirectory() as tmpdir:
        orig_zip = os.path.join(tmpdir, "scan.zip")
        supp_zip = os.path.join(tmpdir, "supplemental_scan.zip")
        orig_dir = os.path.join(tmpdir, "original")
        supp_dir = os.path.join(tmpdir, "supplemental")
        merged_dir = os.path.join(tmpdir, "merged")

        # Step 1: Download both zips
        try:
            _download_from_gcs(original_blob, orig_zip)
            _download_from_gcs(supplemental_blob, supp_zip)
        except Exception as e:
            update_scan_status(scan_id, rfq_id, "failed", f"download failed: {str(e)}")
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        # Step 2: Extract both
        try:
            _extract_zip(orig_zip, orig_dir)
            _extract_zip(supp_zip, supp_dir)
        except Exception as e:
            update_scan_status(scan_id, rfq_id, "failed", f"unzip failed: {str(e)}")
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        orig_root = _find_scan_root(orig_dir)
        supp_root = _find_scan_root(supp_dir)

        if not orig_root or not supp_root:
            msg = "Could not find scan root in extracted packages"
            update_scan_status(scan_id, rfq_id, "failed", msg)
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": msg}

        # Step 2b: Extract HEVC frames if needed (both original and supplemental)
        for label, root in [("original", orig_root), ("supplemental", supp_root)]:
            meta_path = os.path.join(root, "metadata.json")
            with open(meta_path) as f:
                meta = json.load(f)
            if meta.get("capture_format") == "hevc":
                print(f"[Processor] Extracting HEVC frames from {label} scan")
                result = extract_frames_from_hevc(root)
                meta["keyframe_count"] = result["frame_count"]
                meta["keyframes"] = [
                    {"index": i, "filename": f"frame_{i:04d}.jpg"}
                    for i in range(result["frame_count"])
                ]
                with open(meta_path, "w") as f:
                    json.dump(meta, f, indent=2)
                print(f"[Processor] Extracted {result['frame_count']} frames from {label}")

        # Step 3: Merge meshes + frames
        try:
            merged_metadata = _merge_supplemental(orig_root, supp_root, merged_dir)
        except Exception as e:
            update_scan_status(scan_id, rfq_id, "failed", f"merge failed: {str(e)}")
            send_fcm_notification(scan_id, "failed")
            import traceback
            traceback.print_exc()
            return {"status": "failed", "error": str(e)}

        # Step 3b: Select best frames from merged set (no-op if <= 1500)
        _select_frames_for_texturing(merged_dir, merged_metadata)

        # Step 4: Re-texture with merged data
        texture_manifest = None
        try:
            from pipeline.openmvs_texture import texture_scan

            # Merged scans need both preview (for coverage) and standard (for web viewer).
            # Higher preview target (100K) for merged geometry to reduce decimation artifacts.
            tex_output = texture_scan(merged_dir, merged_metadata,
                                      preview_faces=100000,
                                      levels=["preview", "standard"])

            # Upload textured outputs to GCS (overwrite previous)
            gcs_base = original_blob.rsplit("/", 1)[0]
            texture_manifest = {}
            for key, local_path in tex_output.items():
                fname = os.path.basename(local_path)
                if "_standard" in key:
                    gcs_fname = f"standard_{fname}"
                else:
                    gcs_fname = fname
                gcs_path = f"{gcs_base}/{gcs_fname}"
                _upload_to_gcs(local_path, gcs_path)
                texture_manifest[key] = gcs_fname

            print(f"[Processor] Supplemental texturing complete: {list(texture_manifest.keys())}")
        except Exception as e:
            print(f"[Processor] Warning: supplemental texturing failed: {e}")
            import traceback
            traceback.print_exc()
            update_scan_status(scan_id, rfq_id, "failed", f"texturing failed: {str(e)}")
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        # Step 5: Upload merged mesh.ply
        mesh_gcs_path = original_blob.rsplit("/", 1)[0] + "/mesh.ply"
        try:
            _upload_to_gcs(os.path.join(merged_dir, "mesh.ply"), mesh_gcs_path)
        except Exception as e:
            print(f"[Processor] Warning: merged mesh upload failed: {e}")

        # Step 6: Update DB with texture_manifest (preserve existing room dimensions)
        conn = get_db_connection()
        try:
            cursor = conn.cursor()
            cursor.execute(
                """UPDATE scanned_rooms
                   SET scan_status = 'complete',
                       texture_manifest = %s,
                       scan_mesh_url = %s
                   WHERE id = %s""",
                (json.dumps(texture_manifest), mesh_gcs_path, scan_id),
            )
            conn.commit()
        finally:
            conn.close()

        send_fcm_notification(scan_id, "complete")

        return {
            "status": "complete",
            "scan_id": scan_id,
            "merged_frames": merged_metadata["keyframe_count"],
            "texture_manifest": texture_manifest,
        }


def _merge_supplemental(orig_root: str, supp_root: str, output_dir: str,
                        proximity_threshold: float = 0.01) -> dict:
    """Merge supplemental scan data with original.

    Mesh merge: keep supplemental faces only in void regions (>proximity_threshold
    from original surface). Frame merge: continuous numbering.

    Returns merged metadata dict.
    """
    import trimesh
    import shutil

    os.makedirs(output_dir, exist_ok=True)
    os.makedirs(os.path.join(output_dir, "keyframes"), exist_ok=True)

    # Load both metadata
    with open(os.path.join(orig_root, "metadata.json")) as f:
        orig_meta = json.load(f)
    with open(os.path.join(supp_root, "metadata.json")) as f:
        supp_meta = json.load(f)

    # --- Mesh merge ---
    orig_parsed = parse_and_classify(os.path.join(orig_root, "mesh.ply"))
    supp_parsed = parse_and_classify(os.path.join(supp_root, "mesh.ply"))

    orig_mesh = trimesh.Trimesh(
        vertices=orig_parsed.positions,
        faces=orig_parsed.faces,
        process=False,
    )

    # Compute supplemental face centroids
    supp_face_verts = supp_parsed.positions[supp_parsed.faces]
    supp_centroids = supp_face_verts.mean(axis=1)
    n_total = len(supp_parsed.faces)

    # Stage 1: Voxel pre-filter (fast) — faces in empty voxels are void
    vox = orig_mesh.voxelized(pitch=0.05)
    occupied = vox.is_filled(supp_centroids)
    kept_mask = ~occupied
    n_skip = int((~occupied).sum())
    print(f"[Merge] Stage 1 (voxel 5cm): {n_skip}/{n_total} void, "
          f"{int(occupied.sum())} need proximity check")

    # Stage 2: Proximity check on occupied-voxel faces only
    check_indices = np.where(occupied)[0]
    if len(check_indices) > 0:
        orig_mesh_dec = orig_mesh
        if len(orig_mesh.faces) > 50000:
            orig_mesh_dec = orig_mesh.simplify_quadric_decimation(face_count=50000)
        _, dists, _ = trimesh.proximity.closest_point(orig_mesh_dec, supp_centroids[check_indices])
        kept_mask[check_indices] = dists > proximity_threshold

    n_kept = int(kept_mask.sum())
    print(f"[Merge] Filter complete: {n_kept}/{n_total} supplemental faces kept")

    # Build merged mesh
    if n_kept > 0:
        supp_faces_kept = supp_parsed.faces[kept_mask]
        supp_class_kept = supp_parsed.face_classifications[kept_mask]

        # Compact supplemental vertices
        used_verts = np.unique(supp_faces_kept)
        old_to_new = np.full(len(supp_parsed.positions), -1, dtype=np.int64)
        old_to_new[used_verts] = np.arange(len(used_verts))

        supp_verts_compact = supp_parsed.positions[used_verts]
        supp_normals_compact = supp_parsed.normals[used_verts]
        supp_faces_remapped = old_to_new[supp_faces_kept] + len(orig_parsed.positions)

        merged_verts = np.vstack([orig_parsed.positions, supp_verts_compact])
        merged_normals = np.vstack([orig_parsed.normals, supp_normals_compact])
        merged_faces = np.vstack([orig_parsed.faces, supp_faces_remapped])
        merged_class = np.concatenate([orig_parsed.face_classifications, supp_class_kept])

        print(f"[Merge] Merged mesh: {len(merged_verts)} verts, {len(merged_faces)} faces "
              f"(+{len(supp_verts_compact)} verts, +{n_kept} faces)")
    else:
        merged_verts = orig_parsed.positions
        merged_normals = orig_parsed.normals
        merged_faces = orig_parsed.faces
        merged_class = orig_parsed.face_classifications
        print(f"[Merge] No supplemental faces added — using original mesh")

    # Export merged PLY in binary format
    import struct
    merged_ply = os.path.join(output_dir, "mesh.ply")
    vertex_count = len(merged_verts)
    face_count = len(merged_faces)

    header = (
        "ply\n"
        "format binary_little_endian 1.0\n"
        f"element vertex {vertex_count}\n"
        "property float x\nproperty float y\nproperty float z\n"
        "property float nx\nproperty float ny\nproperty float nz\n"
        f"element face {face_count}\n"
        "property list uchar uint vertex_indices\n"
        "property uchar classification\n"
        "end_header\n"
    )
    with open(merged_ply, "wb") as f:
        f.write(header.encode("ascii"))
        vertex_data = np.empty((vertex_count, 6), dtype=np.float32)
        vertex_data[:, :3] = merged_verts.astype(np.float32)
        vertex_data[:, 3:] = merged_normals.astype(np.float32)
        f.write(vertex_data.tobytes())
        for i in range(face_count):
            f.write(struct.pack("<B", 3))
            f.write(struct.pack("<III", int(merged_faces[i][0]),
                                int(merged_faces[i][1]), int(merged_faces[i][2])))
            f.write(struct.pack("<B", int(merged_class[i])))

    print(f"[Merge] Exported merged PLY: {vertex_count} verts, {face_count} faces")

    # --- Frame merge ---
    max_orig_index = max(kf["index"] for kf in orig_meta["keyframes"])
    offset = max_orig_index + 1
    out_keyframes = os.path.join(output_dir, "keyframes")
    merged_kf_list = []

    # Copy original keyframes
    orig_kf_dir = os.path.join(orig_root, "keyframes")
    for kf in orig_meta["keyframes"]:
        for ext in [".jpg", ".json"]:
            src = os.path.join(orig_kf_dir, kf["filename"].replace(".jpg", ext))
            if os.path.exists(src):
                shutil.copy2(src, os.path.join(out_keyframes, kf["filename"].replace(".jpg", ext)))
        merged_kf_list.append(dict(kf))

    # Copy supplemental keyframes with renumbering
    supp_kf_dir = os.path.join(supp_root, "keyframes")
    for kf in supp_meta["keyframes"]:
        new_index = kf["index"] + offset
        new_fname = f"frame_{new_index:03d}.jpg"
        new_json = f"frame_{new_index:03d}.json"

        src_jpg = os.path.join(supp_kf_dir, kf["filename"])
        if os.path.exists(src_jpg):
            shutil.copy2(src_jpg, os.path.join(out_keyframes, new_fname))

        src_json = os.path.join(supp_kf_dir, kf["filename"].replace(".jpg", ".json"))
        if os.path.exists(src_json):
            with open(src_json) as f:
                frame_meta = json.load(f)
            frame_meta["index"] = new_index
            with open(os.path.join(out_keyframes, new_json), "w") as f_out:
                json.dump(frame_meta, f_out)

        merged_kf_list.append({
            "filename": new_fname,
            "index": new_index,
            "timestamp": kf.get("timestamp", 0),
        })

    # Copy depth maps if present
    orig_depth = os.path.join(orig_root, "depth")
    supp_depth = os.path.join(supp_root, "depth")
    out_depth = os.path.join(output_dir, "depth")
    if os.path.isdir(orig_depth):
        os.makedirs(out_depth, exist_ok=True)
        for kf in orig_meta["keyframes"]:
            if kf.get("depth_filename"):
                src = os.path.join(orig_depth, kf["depth_filename"])
                if os.path.exists(src):
                    shutil.copy2(src, os.path.join(out_depth, kf["depth_filename"]))
    if os.path.isdir(supp_depth):
        os.makedirs(out_depth, exist_ok=True)
        for kf in supp_meta["keyframes"]:
            if kf.get("depth_filename"):
                new_depth = f"frame_{kf['index'] + offset:03d}.depth"
                src = os.path.join(supp_depth, kf["depth_filename"])
                if os.path.exists(src):
                    shutil.copy2(src, os.path.join(out_depth, new_depth))

    # Build merged metadata
    merged_meta = dict(orig_meta)
    merged_meta["keyframes"] = merged_kf_list
    merged_meta["keyframe_count"] = len(merged_kf_list)
    merged_meta["supplemental_frame_offset"] = offset

    with open(os.path.join(output_dir, "metadata.json"), "w") as f:
        json.dump(merged_meta, f, indent=2)

    print(f"[Merge] Merged frames: {len(orig_meta['keyframes'])} original + "
          f"{len(supp_meta['keyframes'])} supplemental = {len(merged_kf_list)} total")

    return merged_meta


@app.get("/health")
def health() -> dict:
    """Health check endpoint for Cloud Run readiness/liveness probes."""
    return {"status": "ok"}
