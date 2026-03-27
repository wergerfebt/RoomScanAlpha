import os
import json
import struct
import tempfile
import zipfile

from fastapi import FastAPI, Request, HTTPException
from google.cloud import storage
from google.cloud.sql.connector import Connector
import pg8000
import numpy as np
import firebase_admin
from firebase_admin import messaging

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


def get_db_connection():
    return connector.connect(
        CLOUD_SQL_CONNECTION,
        "pg8000",
        user=DB_USER,
        password=DB_PASS,
        db=DB_NAME,
    )


def update_scan_status(scan_id: str, status: str, error_msg: str = None, room_data: dict = None):
    conn = get_db_connection()
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
        conn.commit()
    finally:
        conn.close()


def send_fcm_notification(scan_id: str, status: str):
    """Send FCM notification via topic (device subscribes to scan_id topic)."""
    try:
        message = messaging.Message(
            topic=f"scan_{scan_id}",
            data={"scan_id": scan_id, "status": status},
            notification=messaging.Notification(
                title="Scan Complete" if status == "scan_ready" else "Scan Failed",
                body=f"Your room scan is ready to view." if status == "scan_ready" else "There was an error processing your scan.",
            ),
        )
        messaging.send(message)
        print(f"[Processor] FCM notification sent for scan {scan_id}")
    except Exception as e:
        print(f"[Processor] FCM notification failed: {e}")


@app.post("/process")
async def process_scan(request: Request):
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

        # 1. Download zip from GCS
        try:
            bucket = storage_client.bucket(BUCKET_NAME)
            blob = bucket.blob(blob_path)
            blob.download_to_filename(zip_path)
            print(f"[Processor] Downloaded {blob_path} ({os.path.getsize(zip_path)} bytes)")
        except Exception as e:
            update_scan_status(scan_id, "failed", f"download failed: {str(e)}")
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        # 2. Unzip
        try:
            if not zipfile.is_zipfile(zip_path):
                raise ValueError("invalid zip archive")
            with zipfile.ZipFile(zip_path, "r") as zf:
                zf.extractall(extract_dir)
            print(f"[Processor] Extracted to {extract_dir}")
        except Exception as e:
            update_scan_status(scan_id, "failed", f"unzip failed: {str(e)}")
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        # Find the scan root (may be nested in a subdirectory)
        scan_root = extract_dir
        entries = os.listdir(extract_dir)
        if len(entries) == 1 and os.path.isdir(os.path.join(extract_dir, entries[0])):
            scan_root = os.path.join(extract_dir, entries[0])

        # 3. Validate structure
        try:
            validate_structure(scan_root, scan_id)
        except ValueError as e:
            update_scan_status(scan_id, "failed", str(e))
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        # 4. Parse PLY and compute real room dimensions
        try:
            room_metrics = compute_room_metrics(os.path.join(scan_root, "mesh.ply"))
            print(f"[Processor] Room metrics: {room_metrics}")
        except Exception as e:
            update_scan_status(scan_id, "failed", f"PLY parse failed: {str(e)}")
            send_fcm_notification(scan_id, "failed")
            return {"status": "failed", "error": str(e)}

        room_data = {
            "floor_area_sqft": room_metrics["floor_area_sqft"],
            "wall_area_sqft": room_metrics["wall_area_sqft"],
            "ceiling_height_ft": room_metrics["ceiling_height_ft"],
            "perimeter_linear_ft": room_metrics["perimeter_linear_ft"],
            "detected_components": room_metrics["detected_components"],
            "scan_dimensions": room_metrics["scan_dimensions"],
        }
        update_scan_status(scan_id, "scan_ready", room_data=room_data)
        send_fcm_notification(scan_id, "scan_ready")

        print(f"[Processor] Scan {scan_id} processed successfully")
        return {"status": "scan_ready", "scan_id": scan_id}


def validate_structure(scan_root: str, scan_id: str):
    """Validate the scan package structure and file contents."""

    # mesh.ply exists
    ply_path = os.path.join(scan_root, "mesh.ply")
    if not os.path.exists(ply_path):
        raise ValueError("missing mesh.ply")

    # Validate PLY header
    with open(ply_path, "rb") as f:
        header = b""
        while True:
            line = f.readline()
            header += line
            if line.strip() == b"end_header":
                break
            if len(header) > 4096:
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

    # metadata.json
    metadata_path = os.path.join(scan_root, "metadata.json")
    if not os.path.exists(metadata_path):
        raise ValueError("missing metadata.json")

    with open(metadata_path, "r") as f:
        metadata = json.load(f)

    required_keys = ["device", "keyframe_count", "mesh_vertex_count", "mesh_face_count",
                     "camera_intrinsics", "image_resolution", "keyframes"]
    missing = [k for k in required_keys if k not in metadata]
    if missing:
        raise ValueError(f"metadata.json missing keys: {missing}")

    print(f"[Processor] metadata.json valid: {metadata['keyframe_count']} keyframes, device: {metadata['device']}")

    # Verify vertex/face counts match
    if metadata["mesh_vertex_count"] != ply_vertex_count:
        print(f"[Processor] Warning: vertex count mismatch — metadata: {metadata['mesh_vertex_count']}, PLY: {ply_vertex_count}")
    if metadata["mesh_face_count"] != ply_face_count:
        print(f"[Processor] Warning: face count mismatch — metadata: {metadata['mesh_face_count']}, PLY: {ply_face_count}")

    # Keyframes directory
    keyframes_dir = os.path.join(scan_root, "keyframes")
    if not os.path.isdir(keyframes_dir):
        raise ValueError("missing keyframes/ directory")

    jpeg_files = sorted([f for f in os.listdir(keyframes_dir) if f.endswith(".jpg")])
    json_files = sorted([f for f in os.listdir(keyframes_dir) if f.endswith(".json")])

    if len(jpeg_files) != metadata["keyframe_count"]:
        raise ValueError(f"keyframe count mismatch: expected {metadata['keyframe_count']}, found {len(jpeg_files)} JPEGs")

    # Validate JPEG headers (SOI marker 0xFFD8)
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

    # Validate per-frame JSONs
    valid_jsons = 0
    for jf in json_files:
        jf_path = os.path.join(keyframes_dir, jf)
        with open(jf_path, "r") as f:
            frame_data = json.load(f)
        transform = frame_data.get("camera_transform", [])
        if len(transform) != 16:
            raise ValueError(f"{jf} has invalid camera_transform (expected 16 elements, got {len(transform)})")
        valid_jsons += 1
    print(f"[Processor] {valid_jsons}/{len(json_files)} frame JSONs valid")

    # Depth directory
    depth_dir = os.path.join(scan_root, "depth")
    if os.path.isdir(depth_dir):
        depth_files = [f for f in os.listdir(depth_dir) if f.endswith(".depth")]
        for df in depth_files:
            df_path = os.path.join(depth_dir, df)
            if os.path.getsize(df_path) == 0:
                raise ValueError(f"depth file {df} is empty")
        print(f"[Processor] {len(depth_files)} depth files valid")


SQM_TO_SQFT = 10.7639
M_TO_FT = 3.28084

# ARMeshClassification values (matches iOS ARKit enum)
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


def compute_room_metrics(ply_path: str) -> dict:
    """Parse binary PLY and compute real room dimensions from classified mesh."""
    with open(ply_path, "rb") as f:
        # Read header
        header_lines = []
        while True:
            line = f.readline().decode("ascii", errors="replace").strip()
            header_lines.append(line)
            if line == "end_header":
                break

        vertex_count = 0
        face_count = 0
        for line in header_lines:
            if line.startswith("element vertex"):
                vertex_count = int(line.split()[-1])
            elif line.startswith("element face"):
                face_count = int(line.split()[-1])

        if vertex_count == 0:
            return _empty_metrics()

        # Read vertex data (6 floats per vertex: x,y,z,nx,ny,nz)
        vertex_data = f.read(vertex_count * 6 * 4)
        vertices = np.frombuffer(vertex_data, dtype=np.float32).reshape(vertex_count, 6)
        positions = vertices[:, :3]

        # Read face data: each face = 1 byte (count=3) + 3 uint32 (indices) + 1 byte (classification)
        # Total per face: 1 + 12 + 1 = 14 bytes
        face_indices = []
        face_classifications = []
        for _ in range(face_count):
            count_byte = struct.unpack("<B", f.read(1))[0]
            indices = struct.unpack(f"<{count_byte}I", f.read(count_byte * 4))
            classification = struct.unpack("<B", f.read(1))[0]
            face_indices.append(indices)
            face_classifications.append(classification)

    face_classifications = np.array(face_classifications, dtype=np.uint8)

    # Bounding box
    min_pos = positions.min(axis=0)
    max_pos = positions.max(axis=0)
    extents = max_pos - min_pos

    bbox = {
        "bbox_x": round(float(extents[0]), 3),
        "bbox_y": round(float(extents[1]), 3),
        "bbox_z": round(float(extents[2]), 3),
        "min_x": round(float(min_pos[0]), 3),
        "min_y": round(float(min_pos[1]), 3),
        "min_z": round(float(min_pos[2]), 3),
        "max_x": round(float(max_pos[0]), 3),
        "max_y": round(float(max_pos[1]), 3),
        "max_z": round(float(max_pos[2]), 3),
    }

    # Compute triangle areas by classification
    floor_area_m2 = _sum_triangle_area(positions, face_indices, face_classifications, 2)
    wall_area_m2 = _sum_triangle_area(positions, face_indices, face_classifications, 1)

    # Ceiling height: max Y of ceiling vertices minus min Y of floor vertices
    floor_vertex_ids = _vertices_for_classification(face_indices, face_classifications, 2)
    ceiling_vertex_ids = _vertices_for_classification(face_indices, face_classifications, 3)

    ceiling_height_m = 0.0
    if len(floor_vertex_ids) > 0 and len(ceiling_vertex_ids) > 0:
        floor_min_y = positions[list(floor_vertex_ids), 1].min()
        ceiling_max_y = positions[list(ceiling_vertex_ids), 1].max()
        ceiling_height_m = ceiling_max_y - floor_min_y

    # Perimeter: convex hull of floor vertices projected onto XZ plane
    perimeter_m = 0.0
    if len(floor_vertex_ids) > 2:
        floor_xz = positions[list(floor_vertex_ids)][:, [0, 2]]
        try:
            from scipy.spatial import ConvexHull
            hull = ConvexHull(floor_xz)
            # Sum edge lengths around the hull
            hull_pts = floor_xz[hull.vertices]
            rolled = np.roll(hull_pts, -1, axis=0)
            perimeter_m = float(np.sum(np.linalg.norm(rolled - hull_pts, axis=1)))
        except Exception:
            # Fallback: approximate from bounding box
            perimeter_m = 2.0 * (float(extents[0]) + float(extents[2]))

    # Detected components
    unique_classes = set(face_classifications.tolist())
    detected = [CLASSIFICATION_NAMES.get(c, f"unknown_{c}") for c in sorted(unique_classes) if c != 0]

    print(f"[Processor] Floor: {floor_area_m2:.2f}m² ({floor_area_m2 * SQM_TO_SQFT:.0f}sqft), "
          f"Walls: {wall_area_m2:.2f}m² ({wall_area_m2 * SQM_TO_SQFT:.0f}sqft), "
          f"Ceiling: {ceiling_height_m:.2f}m ({ceiling_height_m * M_TO_FT:.1f}ft), "
          f"Perimeter: {perimeter_m:.2f}m ({perimeter_m * M_TO_FT:.0f}ft)")

    return {
        "floor_area_sqft": round(floor_area_m2 * SQM_TO_SQFT, 1),
        "wall_area_sqft": round(wall_area_m2 * SQM_TO_SQFT, 1),
        "ceiling_height_ft": round(ceiling_height_m * M_TO_FT, 1),
        "perimeter_linear_ft": round(perimeter_m * M_TO_FT, 1),
        "detected_components": detected,
        "scan_dimensions": bbox,
    }


def _sum_triangle_area(positions, face_indices, classifications, target_class):
    """Sum the area of all triangles with the given classification."""
    total = 0.0
    for i, indices in enumerate(face_indices):
        if classifications[i] != target_class or len(indices) < 3:
            continue
        v0, v1, v2 = positions[indices[0]], positions[indices[1]], positions[indices[2]]
        total += 0.5 * np.linalg.norm(np.cross(v1 - v0, v2 - v0))
    return total


def _vertices_for_classification(face_indices, classifications, target_class):
    """Return the set of vertex indices for faces with the given classification."""
    vertex_ids = set()
    for i, indices in enumerate(face_indices):
        if classifications[i] == target_class:
            vertex_ids.update(indices)
    return vertex_ids


def _empty_metrics():
    return {
        "floor_area_sqft": 0, "wall_area_sqft": 0, "ceiling_height_ft": 0,
        "perimeter_linear_ft": 0, "detected_components": [],
        "scan_dimensions": {"bbox_x": 0, "bbox_y": 0, "bbox_z": 0},
    }


@app.get("/health")
def health():
    return {"status": "ok"}
