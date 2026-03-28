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

app = FastAPI(title="RoomScanAlpha Scan Processor (Stub)")

# --- Config ---
PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "roomscanalpha")
BUCKET_NAME = os.environ.get("GCS_BUCKET", "roomscanalpha-scans")
CLOUD_SQL_CONNECTION = os.environ.get("CLOUD_SQL_CONNECTION", "roomscanalpha:us-central1:roomscanalpha-db")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASS = os.environ.get("DB_PASS", "")
DB_NAME = os.environ.get("DB_NAME", "quoterra")

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

    Per-room scan_status lifecycle (Miro DB Board Section 3 v3):
      pending → processing → complete | failed
    The RFQ-level status transitions to 'scan_ready' only when ALL its
    scanned_rooms rows reach 'complete'.

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
                       scan_dimensions = %s
                   WHERE id = %s""",
                (
                    status,
                    room_data["floor_area_sqft"],
                    room_data["wall_area_sqft"],
                    room_data["ceiling_height_ft"],
                    room_data["perimeter_linear_ft"],
                    json.dumps(room_data["detected_components"]),
                    json.dumps(room_data["scan_dimensions"]),
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

    Steps:
      1. Download the zip from GCS.
      2. Unzip and locate the scan root directory.
      3. Validate package structure (PLY header, metadata, keyframes, depth maps).
      4. Parse the binary PLY mesh and compute room dimensions.
      5. Write results to Cloud SQL and send an FCM notification.
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
            room_metrics = compute_room_metrics(os.path.join(scan_root, "mesh.ply"))
            print(f"[Processor] Room metrics: {room_metrics}")
        except Exception as e:
            update_scan_status(scan_id, rfq_id, "failed", f"PLY parse failed: {str(e)}")
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        # Step 5: Write results to DB and notify
        room_data = {
            "floor_area_sqft": room_metrics["floor_area_sqft"],
            "wall_area_sqft": room_metrics["wall_area_sqft"],
            "ceiling_height_ft": room_metrics["ceiling_height_ft"],
            "perimeter_linear_ft": room_metrics["perimeter_linear_ft"],
            "detected_components": room_metrics["detected_components"],
            "scan_dimensions": room_metrics["scan_dimensions"],
        }
        rfq_ready = update_scan_status(scan_id, rfq_id, "complete", room_data=room_data)
        send_fcm_notification(scan_id, "complete", rfq_ready=rfq_ready)

        print(f"[Processor] Scan {scan_id} processed successfully (rfq_ready={rfq_ready})")
        return {"status": "complete", "scan_id": scan_id, "rfq_ready": rfq_ready}


def _download_from_gcs(blob_path: str, dest_path: str) -> None:
    """Download a blob from GCS to a local file path."""
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(blob_path)
    blob.download_to_filename(dest_path)
    print(f"[Processor] Downloaded {blob_path} ({os.path.getsize(dest_path)} bytes)")


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

    Checks:
      - mesh.ply exists with a valid PLY header containing vertex/face counts
      - metadata.json exists with all required keys
      - PLY vertex/face counts match metadata
      - keyframes/ directory contains the expected number of valid JPEGs
      - Per-frame JSONs contain 16-element camera_transform arrays
      - depth/ files (if present) are non-empty

    Raises:
        ValueError: If any validation check fails (message describes the failure).
    """
    _validate_ply(scan_root)
    metadata = _validate_metadata(scan_root)
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

    jpeg_files = sorted([f for f in os.listdir(keyframes_dir) if f.endswith(".jpg")])
    json_files = sorted([f for f in os.listdir(keyframes_dir) if f.endswith(".json")])

    if len(jpeg_files) != metadata["keyframe_count"]:
        raise ValueError(f"keyframe count mismatch: expected {metadata['keyframe_count']}, found {len(jpeg_files)} JPEGs")

    # Validate JPEG headers — every JPEG starts with the SOI marker (0xFFD8)
    valid_jpegs = 0
    for jpg in jpeg_files:
        jpg_path = os.path.join(keyframes_dir, jpg)
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
    """Parse a binary PLY mesh and compute real room dimensions from classified geometry.

    Uses Stage 1 (parse_and_classify) for PLY parsing and classification grouping,
    then computes surface areas, ceiling height, and perimeter from the classified mesh.

    When USE_DNN_STAGE3=true, runs Stage 3 with the BEV DNN (RoomFormer) to extract
    a room polygon and derives floor area, wall area, and perimeter from the polygon
    instead of raw triangle summation. Falls back to raw triangles if DNN fails.

    All vertex positions are in meters (ARKit Y-up, right-handed coordinate system).
    Output dimensions are converted to imperial (sq ft / ft) at the return boundary.

    Returns:
        Dict with keys: floor_area_sqft, wall_area_sqft, ceiling_height_ft,
        perimeter_linear_ft, detected_components, scan_dimensions.
    """
    try:
        mesh = parse_and_classify(ply_path)
    except ValueError:
        return _empty_metrics()

    # --- Try DNN-based Stage 3 if enabled ---
    use_dnn = os.environ.get("USE_DNN_STAGE3", "false").lower() == "true"
    model_path = os.environ.get("ROOMFORMER_MODEL_PATH", None)
    dnn_metrics = None

    if use_dnn:
        dnn_metrics = _compute_metrics_via_stage3(mesh, model_path)

    if dnn_metrics is not None:
        return dnn_metrics

    # --- Fallback: raw triangle summation (original path) ---
    return _compute_metrics_raw(mesh)


def _compute_metrics_via_stage3(mesh: ParsedMesh, model_path: str | None) -> dict | None:
    """Compute room metrics using the Stage 3 DNN polygon instead of raw triangles.

    Runs Stage 2 (RANSAC plane fitting) then Stage 3 (BEV DNN polygon extraction)
    and derives floor area, wall area, and perimeter from the resulting polygon.
    Ceiling height always comes from Stage 2 RANSAC regardless of the polygon source.

    Returns the metrics dict, or None if any step fails — which triggers the caller
    to fall back to raw triangle summation (_compute_metrics_raw).

    Note: detected_components is still a Phase 2 stub (hardcoded material map).
    It will be replaced by real DNN label detection in a future step.
    """
    try:
        from pipeline.stage2 import fit_planes
        from pipeline.stage3 import assemble_geometry

        plan_result = fit_planes(mesh)
        smesh = assemble_geometry(plan_result, mesh=mesh, use_dnn=True, model_path=model_path)

        # Derive metrics from the SimplifiedMesh surface_map
        # (surface_map keys: "floor", "ceiling", "wall_0", "wall_1", ... each with "area_sqm")
        floor_area_m2 = smesh.surface_map.get("floor", {}).get("area_sqm", 0.0)
        wall_area_m2 = sum(
            v["area_sqm"] for k, v in smesh.surface_map.items() if k.startswith("wall_")
        )

        # Ceiling height from Stage 2 RANSAC — this is the most reliable measurement
        # in the pipeline (simple Y-distance between floor and ceiling vertex clusters).
        # It does NOT depend on the room polygon and works well even when polygon fails.
        ceiling_height_m = _compute_ceiling_height(mesh)

        # Perimeter: each wall's area = width * height, so width = area / height.
        # Sum of wall widths = perimeter. The 0.01 guard prevents division by zero
        # if ceiling height detection fails (shouldn't happen, but defensive).
        perimeter_m = sum(
            v["area_sqm"] / max(ceiling_height_m, 0.01)
            for k, v in smesh.surface_map.items() if k.startswith("wall_")
        )

        # Door count: how many wall segments have a door nearby (detected via
        # proximity of door-classified vertices to each wall edge, threshold=0.5m)
        door_count = sum(
            1 for k, v in smesh.surface_map.items()
            if k.startswith("wall_") and v.get("has_door", False)
        )

        floor_area_sf = round(floor_area_m2 * SQM_TO_SQFT, 1)
        wall_area_sf = round(wall_area_m2 * SQM_TO_SQFT, 1)
        ceiling_height_ft = round(ceiling_height_m * M_TO_FT, 1)
        perimeter_lf = round(perimeter_m * M_TO_FT, 1)

        print(f"[Processor] Stage3 DNN: Floor: {floor_area_m2:.2f}m² ({floor_area_sf:.0f}sqft), "
              f"Walls: {wall_area_m2:.2f}m² ({wall_area_sf:.0f}sqft), "
              f"Ceiling: {ceiling_height_m:.2f}m ({ceiling_height_ft:.1f}ft), "
              f"Perimeter: {perimeter_m:.2f}m ({perimeter_lf:.0f}ft)")

        # Detected components (same stub as raw path)
        arkit_labels = [
            g.classification_name
            for cid, g in sorted(mesh.classification_groups.items())
            if cid != CLASSIFICATION_NONE
        ]
        PHASE2_MATERIAL_MAP = {
            "floor": ["floor_hardwood"],
            "ceiling": ["ceiling_drywall"],
        }
        detected_label_keys = []
        for arkit_class in arkit_labels:
            detected_label_keys.extend(PHASE2_MATERIAL_MAP.get(arkit_class, []))

        scan_dims = {
            "floor_area_sf": floor_area_sf,
            "wall_area_sf": wall_area_sf,
            "ceiling_sf": floor_area_sf,
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

    except Exception as e:
        import traceback
        print(f"[Processor] Stage3 DNN failed — falling back to raw triangle metrics")
        print(f"[Processor]   Error: {type(e).__name__}: {e}")
        traceback.print_exc()
        return None


def _compute_metrics_raw(mesh: ParsedMesh) -> dict:
    """Compute metrics using raw triangle area summation (original path)."""
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
    """Compute ceiling height as the Y-distance between floor and ceiling vertices."""
    floor_group = mesh.classification_groups.get(CLASSIFICATION_FLOOR)
    ceiling_group = mesh.classification_groups.get(CLASSIFICATION_CEILING)

    if floor_group and ceiling_group and len(floor_group.vertex_ids) > 0 and len(ceiling_group.vertex_ids) > 0:
        floor_min_y = mesh.positions[floor_group.vertex_ids, 1].min()
        ceiling_max_y = mesh.positions[ceiling_group.vertex_ids, 1].max()
        return float(ceiling_max_y - floor_min_y)
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


@app.get("/health")
def health() -> dict:
    """Health check endpoint for Cloud Run readiness/liveness probes."""
    return {"status": "ok"}
