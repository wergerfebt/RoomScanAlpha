> **DEPRECATED:** Original pipeline design doc from early development. The actual pipeline (stages 1-3 + OpenMVS texturing) is implemented in `cloud/processor/pipeline/` and documented in `CLAUDE.md`.

# Cloud Pipeline Plan — Scan Processing & Measurement Extraction

## MVP Scope & Build Order

This plan covers the cloud-side scan processing pipeline — **Stages 1-4b + 6** — which replaces the current stub processor. The goal is: real measurements + detected components in the DB so quote auto-population works end-to-end.

**What this plan covers (MVP)**:
- Parse PLY mesh → detect planes → extract room measurements → detect components (stub) → write to SCANNED_ROOMS → notify

**What this plan does NOT cover** (separate documents):
- Texture projection, floor plans, measurement annotations → `VISUALIZATION_PLAN.md`
- Interactive 3D web viewer → `WEB_VIEWER_PLAN.md`
- Full DNN taxonomy, training spec, cabinet depth classification → `DNN_COMPONENT_TAXONOMY.md`

### Build Order

1. **Schema additions** → PROPERTIES, FLOORS, SCAN_COMPONENT_LABELS, SCAN_COMPONENT_TEMPLATES, LINE_ITEM_TEMPLATES, APPLIANCE_LABELS, ROOM_APPLIANCES tables. Seed SCAN_COMPONENT_LABELS with initial vocabulary.
2. **Stages 1-4** → real measurements in DB with scan_dimensions using standard keys
3. **Stage 4b (stub)** → hardcoded detected_components with correct label ID format + appliance rows in ROOM_APPLIANCES
4. **Stage 6 DB update** → wire real values + label IDs into `update_scan_status`, per-room status lifecycle, RFQ transition logic
5. **End-to-end validation**: scan → upload → process → real measurements + detected components in DB → quote auto-population produces seeded line items with correct quantities

**Later layers** (not blocking MVP):
- DNN training + real component detection (replaces Stage 4b stub) — see `DNN_COMPONENT_TAXONOMY.md`
- Texture projection + floor plans + measurement annotations — see `VISUALIZATION_PLAN.md`
- Web viewer — see `WEB_VIEWER_PLAN.md`

---

## Context

The pipeline takes a scan package uploaded from the iOS app (PLY mesh + JPEG keyframes + depth maps + metadata) and produces:

1. **Simplified room geometry** — walls, floor, ceiling, and objects as smooth planar/box surfaces with accurate LiDAR dimensions
2. **Structured room data** — real measurements written to `SCANNED_ROOMS` with standardized `scan_dimensions` keys that LINE_ITEM_TEMPLATES reference for auto-population
3. **Detected components** — material/surface labels (via DNN, stubbed for Phase 2) written to `detected_components` JSONB, driving the SCAN_COMPONENT_LABELS → SCAN_COMPONENT_TEMPLATES → LINE_ITEM_TEMPLATES auto-population chain
4. **Detected appliances** — discrete object instances (sink, toilet, range, etc.) written to `ROOM_APPLIANCES` with room-local positions for floor plan rendering and cross-floor utility inference

The iOS app currently exports:
- **mesh.ply** — binary little-endian, vertices (x,y,z,nx,ny,nz), faces (3 vertex indices + 1 classification byte). Classification values follow `ARMeshClassification`: 0=none, 1=wall, 2=floor, 3=ceiling, 4=table, 5=seat, 6=door, 7=window
- **keyframes/** — 30-60 JPEGs at 0.8 quality + per-frame JSON with 16-element camera transform (column-major 4x4) and image/depth dimensions
- **depth/** — raw Float32 depth maps (256x192, little-endian)
- **metadata.json** — camera intrinsics (fx, fy, cx, cy), image resolution, keyframe count, mesh counts, device info

Coordinate system: ARKit Y-up right-handed (Y=up, -Z=forward).

---

## Pipeline Stages

```
Stage 1: Parse & Classify            → classified point cloud + face groups
Stage 2: Plane Fitting               → detected planar surfaces with equations
Stage 3: Room Geometry Assembly      → simplified mesh (walls/floor/ceiling/objects)
Stage 4: Measurement Extraction      → floor area, wall area, ceiling height, perimeter
Stage 4b: Component Detection (stub) → detected material/surface labels + appliance instances
Stage 6: Export & Persist            → DB update + GCS upload + FCM notification
```

---

## Stage 1: Parse & Classify

**Goal**: Read the binary PLY, extract vertices/faces/normals/classifications, and group faces by classification label.

**Input**: `mesh.ply` (binary little-endian)
**Output**: In-memory classified face groups

**Implementation**:
- Parse PLY header for vertex/face counts (existing `compute_ply_bounding_box` already does the header part)
- Read all vertices (x,y,z,nx,ny,nz as float32) into numpy array
- Read all faces: each face is 1 byte (count=3) + 3 uint32 indices + 1 uint8 classification
- Group faces by classification into dictionaries: `{ classification_id: [face_indices] }`
- Compute per-group vertex sets (unique vertices referenced by each group's faces)

**Face binary layout** (per face, 14 bytes):
```
[1 byte: vertex_count (always 3)]
[4 bytes: idx0 (uint32 LE)]
[4 bytes: idx1 (uint32 LE)]
[4 bytes: idx2 (uint32 LE)]
[1 byte: classification (uint8)]
```

**Classification map**:
```python
CLASSIFICATION = {
    0: "none",
    1: "wall",
    2: "floor",
    3: "ceiling",
    4: "table",
    5: "seat",
    6: "door",
    7: "window",
}
```

### Test Cases — Stage 1

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S1.1 | Parse a known PLY file | All vertices and faces loaded | Vertex/face counts match header; no parse errors |
| S1.2 | Classification groups are non-empty for scanned room | At least wall + floor + ceiling groups populated | Groups 1, 2, 3 each have > 0 faces |
| S1.3 | Vertex positions match bounding box | Computed bbox matches existing `compute_ply_bounding_box` output | Extents within ±0.001m |
| S1.4 | Face normals are consistent | Normals for floor faces point approximately +Y, ceiling faces point approximately -Y | Mean normal Y-component > 0.9 for floor, < -0.9 for ceiling |

---

## Stage 2: Plane Fitting

**Goal**: For each classification group, fit planar surfaces using RANSAC. Each surface gets a plane equation and the set of inlier faces that belong to it.

**Input**: Classified face groups from Stage 1
**Output**: List of `DetectedPlane` objects

**Implementation**:
- For each classification group (wall, floor, ceiling):
  - Collect all vertex positions belonging to that group
  - Run iterative RANSAC plane fitting:
    1. Sample 3 random non-collinear points
    2. Fit plane: `ax + by + cz + d = 0` via cross-product normal
    3. Count inliers within distance threshold (0.03m for walls/ceiling, 0.05m for floor)
    4. After finding the dominant plane, remove its inliers and repeat to find additional planes (e.g., 4 wall planes in a rectangular room)
  - Stop when remaining points < 5% of original group or no plane with > 50 inliers
- For object classifications (table, seat, door, window):
  - Compute oriented bounding box (OBB) from face vertices using PCA
  - Store as position + dimensions + orientation

**DetectedPlane** schema:
```python
@dataclass
class DetectedPlane:
    classification: str         # "wall", "floor", "ceiling"
    normal: np.ndarray          # unit normal [3]
    point_on_plane: np.ndarray  # any inlier point [3]
    distance: float             # d in ax+by+cz+d=0
    inlier_vertices: np.ndarray # Nx3 array of inlier positions
    boundary_polygon: list      # 2D convex hull projected onto plane
    area_sqm: float             # area of boundary polygon

@dataclass
class DetectedObject:
    classification: str         # "table", "seat", "door", "window"
    center: np.ndarray          # [3] world position
    dimensions: np.ndarray      # [3] width, height, depth in meters
    orientation: np.ndarray     # [3x3] rotation matrix (from PCA)
    face_count: int
```

**Why RANSAC and not least-squares**: LiDAR mesh is noisy near edges and corners. RANSAC naturally ignores outlier faces at wall-floor junctions, door frames, etc. Least-squares would pull the plane toward those outliers.

**Tuning**:
- Distance threshold: 0.03m (walls/ceiling), 0.05m (floor — tends to be noisier)
- Min inliers: 50 faces to count as a surface
- Max iterations: 1000 per RANSAC pass

### Test Cases — Stage 2

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S2.1 | Floor detected as single horizontal plane | One floor plane with normal ≈ (0,1,0) | Normal Y > 0.95; single dominant plane |
| S2.2 | Ceiling detected as single horizontal plane | One ceiling plane with normal ≈ (0,-1,0) | Normal Y < -0.95; single dominant plane |
| S2.3 | Walls detected as vertical planes | Multiple wall planes with normals ≈ horizontal | Normal Y magnitude < 0.1 for each wall plane |
| S2.4 | Rectangular room yields 4 wall planes | RANSAC finds 4 distinct wall planes | 4 planes with normals roughly 90° apart (dot products ≈ 0 for adjacent pairs) |
| S2.5 | Ceiling height matches LiDAR | Distance between floor plane and ceiling plane | Height within ±0.05m of PLY bounding box Y-extent |
| S2.6 | Table/seat detected as bounding box | OBB computed for table classification | Dimensions are reasonable (0.3m-2.0m per axis); center is between floor and ceiling |
| S2.7 | Small noise clusters ignored | Scattered faces with < 50 inliers | No plane or object returned for clusters below threshold |

---

## Stage 3: Room Geometry Assembly

**Goal**: Build a clean simplified mesh from the detected planes and objects. Walls, floor, and ceiling become flat quads. Objects become boxes.

**Input**: DetectedPlanes and DetectedObjects from Stage 2
**Output**: Simplified triangle mesh (vertices + faces + UV coordinates)

**Implementation**:
1. **Floor polygon**: Project floor inlier vertices onto the floor plane, compute 2D convex hull, triangulate with ear clipping or Delaunay
2. **Ceiling polygon**: Same as floor, projected onto ceiling plane. In a simple room, use the floor polygon outline projected up to ceiling height
3. **Wall quads**: For each wall plane, intersect with the floor and ceiling planes to get top/bottom edges. Clip to adjacent wall intersections to get a rectangular (or polygonal) quad. Triangulate into 2 triangles per wall
4. **Wall-wall intersections**: Find pairwise intersections of adjacent wall planes. The intersection line + floor/ceiling planes give the vertical corner edges
5. **Object boxes**: For each DetectedObject, generate a 12-triangle box mesh from center + dimensions + orientation
6. **Merge**: Combine all surfaces into a single indexed triangle mesh with per-face classification labels and UV coordinates

**Simplifications for MVP**:
- Assume convex room footprint (handles rectangles, L-shapes come later)
- Walls extend floor-to-ceiling (no partial walls or soffits)
- Objects are axis-aligned bounding boxes (PCA orientation is a stretch goal)
- No doors/windows as cutouts — they're separate box objects for now

**Output format**: In-memory mesh ready for texture projection:
```python
@dataclass
class SimplifiedMesh:
    vertices: np.ndarray      # Nx3
    normals: np.ndarray       # Nx3
    faces: np.ndarray         # Mx3 (triangle indices)
    uvs: np.ndarray           # Nx2 (texture coordinates)
    face_labels: list[str]    # M labels: "wall_0", "floor", "ceiling", "table_0", etc.
    surface_map: dict         # { "wall_0": { plane, area, material_id }, ... }
```

### Test Cases — Stage 3

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S3.1 | Rectangular room produces closed box | 4 walls + floor + ceiling = 12 triangles (6 quads) | Mesh is watertight (every edge shared by exactly 2 triangles); 12 triangles for a simple box |
| S3.2 | Wall quads span floor to ceiling | Wall vertex Y-coordinates match floor and ceiling plane heights | Wall quad bottom Y ≈ floor plane Y; top Y ≈ ceiling plane Y |
| S3.3 | Adjacent walls meet at corners | Wall-wall intersection lines are vertical | Corner vertices shared between adjacent wall quads; X/Z positions match intersection |
| S3.4 | UV coordinates span [0,1] per surface | Check UV range per face label | All UVs in [0,1]; UVs are proportional to surface dimensions (no stretching) |
| S3.5 | Object boxes are inside room bounds | Table/seat box centers inside room polygon | Object center XZ within floor convex hull; Y between floor and ceiling |
| S3.6 | Total vertex count is small | Count vertices in simplified mesh | < 200 vertices for a simple room (vs 10K+ in raw PLY) |
| S3.7 | Normals point inward | Wall normals face into the room; floor normal faces up | Dot product of (wall normal, center-to-wall vector) < 0 for each wall |

---

## Stage 4: Measurement Extraction

**Goal**: Compute real room measurements from the simplified geometry. These replace the hardcoded mock values in the current stub.

**Input**: SimplifiedMesh + DetectedPlanes from previous stages
**Output**: Measurements written to `SCANNED_ROOMS`

**Measurements**:
```python
@dataclass
class RoomMeasurements:
    floor_area_sqft: float        # area of floor polygon (convex hull)
    wall_area_sqft: float         # sum of all wall quad areas
    ceiling_height_ft: float      # distance from floor plane to ceiling plane (flat rooms)
    ceiling_height_min_ft: float  # min ceiling height (sloped/attic rooms, else None)
    ceiling_height_max_ft: float  # max ceiling height (sloped/attic rooms, else None)
    ceiling_sqft: float           # actual ceiling surface area (≥ floor_area for sloped)
    perimeter_linear_ft: float    # perimeter of floor polygon
    door_count: int               # number of detected door objects
    door_opening_lf: float        # total linear feet of door openings
    transition_count: int         # number of floor transition points
    geometric_components: list    # ARKit classifications present: ["wall", "floor", "ceiling", "table", ...]
    object_details: list          # [{ "type": "table", "dimensions": {...}, "position": {...} }, ...]
```

**scan_dimensions JSONB keys** (must match LINE_ITEM_TEMPLATES.scan_dimension_key):

The `scan_dimensions` JSONB on SCANNED_ROOMS uses a standardized set of keys that the quote auto-population logic references. Each LINE_ITEM_TEMPLATE has a `scan_dimension_key` field (e.g., `"floor_area_sf"`) that tells the system which measurement to use as the line item quantity.

```python
# MVP scan_dimensions keys (populated by Stage 4 geometry analysis)
SCAN_DIMENSION_KEYS = {
    "floor_area_sf":          # float — floor polygon area in square feet
    "wall_area_sf":           # float — total wall surface area in square feet
    "ceiling_sf":             # float — ceiling surface area (> floor_area_sf for sloped)
    "perimeter_lf":           # float — floor polygon perimeter in linear feet
    "ceiling_height_ft":      # float — floor-to-ceiling distance (flat rooms)
    "ceiling_height_min_ft":  # float — min ceiling height (sloped rooms, else null)
    "ceiling_height_max_ft":  # float — max ceiling height (sloped rooms, else null)
    "door_count":             # int   — number of detected doors
    "door_opening_lf":        # float — total linear feet of door openings
    "transition_count":       # int   — number of floor transitions
}

# Future keys (populated when DNN detects cabinets — see DNN_COMPONENT_TAXONOMY.md)
# These are null/absent until Stage 4b DNN is active:
#   "cabinet_upper_lf"    — total linear feet of upper cabinet runs
#   "cabinet_lower_lf"    — total linear feet of lower/base cabinet runs
#   "cabinet_full_lf"     — total linear feet of full-height cabinet runs
```

**Conversion**: All LiDAR/ARKit data is in meters. Convert: `sqft = sqm * 10.7639`, `ft = m * 3.28084`.

**Implementation**:
1. Floor area: area of floor convex hull polygon (Shoelace formula on 2D projected vertices)
2. Wall area: sum of each wall quad's width × height
3. Ceiling height: perpendicular distance between floor and ceiling planes. If ceiling plane is not parallel to floor (slope detected via normal divergence > 5°), compute min/max heights and actual ceiling surface area
4. Ceiling surface area: area of ceiling polygon projected onto its plane. For sloped ceilings this exceeds the floor area
5. Perimeter: sum of floor polygon edge lengths
6. Door count / openings: count DetectedObjects with classification=6 (door). Sum widths for door_opening_lf
7. Transition count: count floor-level boundary changes (where floor classification meets "none" at room edges)
8. Geometric components: unique ARKit classification labels present with > 50 faces (distinct from DNN-detected components in Stage 4b)
9. Object details: for each DetectedObject, output classification + dimensions + center position

### Test Cases — Stage 4

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S4.1 | Floor area of known room | Scan a 3m × 4m room | Floor area ≈ 129 sqft (12 sqm) | Measured area within ±5% of ground truth |
| S4.2 | Ceiling height of known room | Scan a room with 2.44m (8ft) ceiling | Ceiling height ≈ 8.0 ft | Within ±0.15 ft (±0.05m) |
| S4.3 | Perimeter of rectangular room | 3m × 4m room | Perimeter ≈ 46 ft (14m) | Within ±5% |
| S4.4 | Wall area sums correctly | 4 walls, each width × height | Total wall area ≈ walls × ceiling height | Within ±5% of sum of individual wall areas |
| S4.5 | Geometric components list | Room with floor, walls, ceiling, table | List contains all observed ARKit classifications | At least ["wall", "floor", "ceiling"]; "table" present if table scanned |
| S4.6 | Object dimensions are reasonable | Table in scan | Reported table dimensions match reality | Within ±15% per axis (LiDAR object accuracy is lower than surface accuracy) |
| S4.7 | Measurements written to DB | Check SCANNED_ROOMS after processing | Real values, not mock data | `floor_area_sqft` != 150.0 (the old hardcoded value); values are plausible |
| S4.8 | scan_dimensions JSONB uses standard keys | Check scan_dimensions after processing | Keys match SCAN_DIMENSION_KEYS | `floor_area_sf`, `wall_area_sf`, `ceiling_sf`, `perimeter_lf`, `ceiling_height_ft` all present |
| S4.9 | Sloped ceiling detected | Room with non-parallel floor/ceiling | ceiling_height_min_ft and ceiling_height_max_ft populated | ceiling_sf > floor_area_sf; min < max; single ceiling_height_ft is null |
| S4.10 | Door count and openings | Room with 2 doors | door_count = 2; door_opening_lf reasonable | door_opening_lf ≈ sum of door widths in feet (±10%) |

---

## Stage 4b: Component Detection (Stub)

**Goal**: Detect construction-relevant materials, surfaces, and appliances. For MVP, this stage returns hardcoded labels to validate the full auto-population pipeline. When the DNN is trained and deployed, it replaces the stub with real inference — a config change, not a code rewrite.

**Input**: Keyframe images (JPEGs) + camera poses + SimplifiedMesh
**Output**: Material/surface labels → `detected_components` JSONB on SCANNED_ROOMS. Appliance instances → `ROOM_APPLIANCES` table rows.

> **Full DNN taxonomy, training requirements, and detection details**: See `DNN_COMPONENT_TAXONOMY.md`.

### Two output paths: materials vs. appliances

The Miro database schema (Section 5 and 5b) distinguishes between:

1. **Materials and surfaces** (floor type, ceiling type, trim, cabinets) → written to `detected_components` JSONB on SCANNED_ROOMS as label IDs referencing `SCAN_COMPONENT_LABELS`. These drive quote auto-population via the SCAN_COMPONENT_TEMPLATES → LINE_ITEM_TEMPLATES chain.

2. **Discrete appliance instances** (sink, toilet, range, fridge, etc.) → written to **ROOM_APPLIANCES** table rows, each with `pos_x`/`pos_y` (room-local coordinates), `appliance_label_id` FK to APPLIANCE_LABELS, and `is_confirmed = false` (contractor verifies/corrects). These are used for floor plan rendering (Stage 7) and cross-floor utility inference.

This distinction matters because:
- Appliances have room-local positions needed for spatial queries and floor plan placement
- Contractors need `is_confirmed` to verify what the DNN detected
- Appliance labels map to work types (Plumbing, Electrical) differently than material labels

### Data contracts

**detected_components JSONB** (materials/surfaces on SCANNED_ROOMS):

Per Miro DB Board Section 5 (updated), the format is a list of `label_key` strings inside a `detected` wrapper — **not** an array of objects with label_id/confidence:
```json
{ "detected": ["floor_hardwood", "baseboard", "shoe_molding"] }
```

The auto-population logic iterates `detected_components.detected` and looks up each `label_key` in `SCAN_COMPONENT_LABELS` → `SCAN_COMPONENT_TEMPLATES` → `LINE_ITEM_TEMPLATES` → seeds LINE_ITEMS with `quantity = scan_dimensions[template.scan_dimension_key]`.

During Phase 2 (mock DNN), this is hardcoded as a list of label_key strings — same format the real DNN will return.

**ROOM_APPLIANCES rows** (appliance instances):
```sql
INSERT INTO room_appliances (scanned_room_id, appliance_label_id, pos_x, pos_y, is_confirmed)
VALUES (:scan_id, :label_id, :x, :y, false);
```

Appliance label IDs reference `APPLIANCE_LABELS`. Positions are in the room's local coordinate space.

### Downstream auto-population flow (Miro Flow 2)

**Dimension-based quantities** (most line items):
```
detected_components (label IDs on SCANNED_ROOMS)
  → SCAN_COMPONENT_TEMPLATES (join: label_id → template bundle)
    → LINE_ITEM_TEMPLATES (each has scan_dimension_key + unit_type)
      → LINE_ITEMS (quantity = scan_dimensions[scan_dimension_key],
                     unit_price from contractor's PRICE_LIST_ITEM)
```

The `presence_required` flag on SCAN_COMPONENT_TEMPLATES controls whether a line item is always included when the parent label is detected (false — consumables like poly coat, nails, wood filler) or only when the DNN explicitly returned that specific label (true — shoe molding, baseboards, T-molding).

**Count-based quantities** (appliances, doors, fixtures):

For items where the quantity is a count rather than a dimension:
- **Doors**: `quantity = scan_dimensions["door_count"]` (integer from Stage 4)
- **Appliances**: `quantity = COUNT(*) FROM room_appliances WHERE appliance_label_id = :label AND scanned_room_id = :scan_id` — the auto-population query counts matching ROOM_APPLIANCES rows
- **Light fixtures**: `quantity = count of entries in detected_components matching that label` (stored as a count field on the detected_components entry)

### Phase 2 stub implementation

```python
# Hardcoded fallback when VERTEX_ENDPOINT_ID is not configured
PHASE2_MATERIAL_MAP = {
    # ARKit classification → default material label_keys (from SCAN_COMPONENT_LABELS)
    "floor":   ["floor_hardwood"],
    "wall":    [],                   # no wall material detection yet
    "ceiling": ["ceiling_drywall"],
}

PHASE2_APPLIANCES = []  # no appliance detection until DNN is active

def detect_components_stub(classified_groups):
    """Phase 2: return hardcoded label_keys based on ARKit classifications.

    Returns the Miro-compliant format: { "detected": ["label_key_1", ...] }
    """
    detected_keys = []
    for arkit_class, label_keys in PHASE2_MATERIAL_MAP.items():
        if arkit_class in classified_groups:
            detected_keys.extend(label_keys)
    return {"detected": detected_keys}
    # ROOM_APPLIANCES: no rows written in Phase 2 stub
```

### Test Cases — Stage 4b

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S4b.1 | Phase 2 stub returns labels | Process room with floor + ceiling | detected_components has `{ "detected": ["floor_hardwood", "ceiling_drywall"] }` | label_keys are valid entries in SCAN_COMPONENT_LABELS |
| S4b.2 | detected_components JSONB format correct | Check SCANNED_ROOMS after processing | Object with `detected` array of label_key strings | `detected_components.detected` is a non-empty array |
| S4b.3 | Label keys resolve against SCAN_COMPONENT_LABELS | Stub returns "floor_hardwood" | label_key exists in SCAN_COMPONENT_LABELS | `SELECT id FROM scan_component_labels WHERE label_key = 'floor_hardwood'` returns a row |
| S4b.4 | Auto-population chain works end-to-end | detected_components written → quote created | Line items seeded with correct quantities | LINE_ITEMS.quantity matches scan_dimensions[template.scan_dimension_key] |
| S4b.5 | Unknown label keys are skipped | Stub tries a key not in SCAN_COMPONENT_LABELS | No entry in detected_components for that key | No error; label is logged and skipped |
| S4b.6 | ROOM_APPLIANCES empty in Phase 2 | Check ROOM_APPLIANCES after stub processing | No rows for this scan_id | Count = 0 (appliance detection requires DNN) |

---

## Stage 6: Export & Persist

**Goal**: Package the simplified mesh into a downloadable format and write real measurements to the database. This replaces the current stub's mock data path.

**Input**: SimplifiedMesh + RoomMeasurements + DetectedComponents
**Output**: glTF file in GCS + SCANNED_ROOMS row updated + ROOM_APPLIANCES rows + FCM notification

**Implementation**:

1. **glTF export**:
   - Use `trimesh` + `pygltflib` to build a glTF scene with:
     - Simplified geometry (vertices, faces, normals, UVs)
     - Object bounding boxes as separate mesh nodes with labels
   - For MVP, surfaces get flat materials colored by classification (textures come in Stage 5)
   - Export glTF directly (USDZ conversion deferred — problematic in Linux containers)

2. **Upload result to GCS**:
   - Upload glTF to `gs://roomscanalpha-scans/results/{rfq_id}/{scan_id}/model.gltf`

3. **Update SCANNED_ROOMS** with real measurements:
   ```sql
   UPDATE scanned_rooms SET
     scan_status = 'complete',                -- per-room status (not RFQ-level)
     floor_area_sqft = :floor_area,
     wall_area_sqft = :wall_area,
     ceiling_height_ft = :ceiling_height,
     perimeter_linear_ft = :perimeter,
     detected_components = :components,        -- JSONB: array of {label_id, label_key, confidence}
     scan_dimensions = :dimensions,            -- JSONB: standardized keys for auto-population
     scan_mesh_url = :model_gcs_path           -- path to glTF in GCS
   WHERE id = :scan_id
   ```

4. **Write ROOM_APPLIANCES** (when DNN is active — empty in Phase 2 stub):
   ```sql
   INSERT INTO room_appliances (scanned_room_id, appliance_label_id, pos_x, pos_y, is_confirmed)
   VALUES (:scan_id, :appliance_label_id, :pos_x, :pos_y, false);
   ```

5. **Pass through building coordinates** from metadata.json (if provided by mobile app):
   ```sql
   UPDATE scanned_rooms SET
     floor_id = :floor_id,
     origin_x = :origin_x,
     origin_y = :origin_y,
     rotation_deg = :rotation_deg
   WHERE id = :scan_id;
   ```
   These can be NULL for MVP. They enable cross-floor visualization later (see `VISUALIZATION_PLAN.md`).

6. **Per-room scan_status lifecycle**:
   - `pending` — row created by API when scan upload starts
   - `processing` — set by processor at start of pipeline
   - `complete` — all stages succeeded for this room
   - `failed` — pipeline error; error details stored in a separate error field

   The RFQ's own `status` field transitions to `scan_ready` only when **all** its SCANNED_ROOMS rows reach `complete`. Partial failures are preserved — if room 12 of 27 fails, rooms 1-11 are already written and the job can be retried from the failure point.

7. **RFQ status transition** (after updating SCANNED_ROOMS):
   ```sql
   -- Check if all rooms for this RFQ are complete
   UPDATE rfqs SET status = 'scan_ready'
   WHERE id = :rfq_id
     AND NOT EXISTS (
       SELECT 1 FROM scanned_rooms
       WHERE rfq_id = :rfq_id AND scan_status != 'complete'
     );
   ```

8. **Send FCM notification** (existing logic in stub is reusable) — only when RFQ transitions to `scan_ready`

**Downstream FK: ROOMS.source_scan_id → SCANNED_ROOMS.id**

When a contractor creates a quote, quote ROOMS are seeded from SCANNED_ROOMS. Each quote ROOM carries a `source_scan_id` FK pointing back to the SCANNED_ROOMS row it was created from. This makes the lineage traceable — the API team uses this to join back to original scan data and to pull `scan_dimensions` for auto-populating line item quantities.

**scan_dimensions JSONB format** (standardized keys for LINE_ITEM_TEMPLATES.scan_dimension_key lookup):
```json
{
  "floor_area_sf": 129.2,
  "wall_area_sf": 400.5,
  "ceiling_sf": 129.2,
  "perimeter_lf": 46.0,
  "ceiling_height_ft": 8.0,
  "ceiling_height_min_ft": null,
  "ceiling_height_max_ft": null,
  "door_count": 2,
  "door_opening_lf": 6.0,
  "transition_count": 1,
  "bbox": { "x_m": 4.2, "y_m": 2.5, "z_m": 3.8 },
  "surfaces": [
    { "label": "wall_0", "normal": [1,0,0], "area_sqm": 9.6, "width_m": 3.8, "height_m": 2.5 },
    { "label": "floor", "normal": [0,1,0], "area_sqm": 12.0 }
  ],
  "objects": [
    { "label": "table", "center": [1.2, 0.4, -2.0], "dimensions": [1.2, 0.75, 0.8] }
  ]
}
```

> The top-level keys (`floor_area_sf`, `wall_area_sf`, etc.) are the **auto-population contract** — LINE_ITEM_TEMPLATES reference these by name via `scan_dimension_key`. The `surfaces` and `objects` arrays are supplementary detail for visualization and debugging. Cabinet LF keys (`cabinet_upper_lf`, etc.) will be added when the DNN detects cabinets — see `DNN_COMPONENT_TAXONOMY.md`.

### Test Cases — Stage 6

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S6.1 | glTF file is valid | Open output in a glTF viewer | Model renders with geometry | File opens without error; surfaces visible |
| S6.2 | glTF uploaded to GCS | Check bucket after processing | Model file exists at expected path | `gs://roomscanalpha-scans/results/{rfq_id}/{scan_id}/model.gltf` exists; size > 0 |
| S6.3 | DB updated with real measurements | Query SCANNED_ROOMS after processing | Values differ from mock data | `floor_area_sqft` != 150.0; values are positive and plausible for a room |
| S6.4 | scan_mesh_url points to result model | Check scan_mesh_url column | URL is a valid GCS path | Path matches `results/{rfq_id}/{scan_id}/model.gltf` |
| S6.5 | FCM notification sent with scan_ready | Check device after processing | Push notification received | Notification arrives with scan_id and status = "scan_ready" |
| S6.6 | Per-room scan_status set to complete | Query SCANNED_ROOMS.scan_status | Status is 'complete' for successful rooms | scan_status = 'complete'; not 'processing' or 'scan_ready' |
| S6.7 | RFQ status transitions only when all rooms complete | Process 3-room RFQ, fail room 3 | RFQ status stays 'scan_pending' | RFQ status != 'scan_ready' until room 3 is retried and succeeds |
| S6.8 | detected_components contains label IDs | Query detected_components JSONB | Array of objects with label_id, label_key, confidence | label_ids are valid UUIDs referencing SCAN_COMPONENT_LABELS |
| S6.9 | scan_dimensions uses standard keys | Query scan_dimensions JSONB | Contains floor_area_sf, wall_area_sf, ceiling_sf, perimeter_lf | All MVP keys present; values match column values (after rounding) |
| S6.10 | source_scan_id FK works for quote seeding | Create quote from completed scan | Quote ROOM has source_scan_id = SCANNED_ROOMS.id | JOIN succeeds; scan data accessible from quote room |
| S6.11 | Building coordinates passed through | metadata.json includes floor_id + origin | SCANNED_ROOMS has floor_id, origin_x, origin_y populated | Values match metadata.json; NULL when not provided |

---

## Dependencies

```python
# New additions to cloud/processor/requirements.txt
scipy>=1.14.0            # RANSAC, spatial algorithms, convex hull
trimesh>=4.4.0           # mesh construction, export to glTF
Pillow>=10.4.0           # keyframe image loading
shapely>=2.0.0           # 2D polygon operations (floor hull, wall clipping)
pygltflib>=1.16.0        # glTF scene construction
google-cloud-aiplatform>=1.60.0  # Vertex AI endpoint calls (Stage 4b when DNN is active)
```

Existing deps (already in requirements.txt): `numpy`, `fastapi`, `uvicorn`, `google-cloud-storage`, `pg8000`, `cloud-sql-python-connector`, `firebase-admin`

**No OpenCV needed for MVP.** ORB feature matching and homography stitching are not required — we're projecting images directly using the camera poses from ARKit, which are already in world space. OpenCV becomes relevant later if we need to refine camera poses or do multi-image blending beyond simple weighted averaging.

---

## Proposed File Structure

```
cloud/processor/
├── main.py                      (FastAPI entrypoint — modify existing)
├── requirements.txt             (add new deps)
├── Dockerfile                   (may need system deps for trimesh/Pillow)
├── pipeline/
│   ├── __init__.py
│   ├── ply_parser.py            (Stage 1: parse PLY, group by classification)
│   ├── plane_fitting.py         (Stage 2: RANSAC plane detection + OBB for objects)
│   ├── room_assembly.py         (Stage 3: build simplified mesh from planes)
│   ├── measurements.py          (Stage 4: compute floor area, wall area, height, perimeter)
│   ├── component_detection.py   (Stage 4b: stub now, Vertex AI DNN later)
│   └── exporter.py              (Stage 6: build glTF, upload to GCS, update DB)
└── tests/
    ├── test_ply_parser.py
    ├── test_plane_fitting.py
    ├── test_room_assembly.py
    ├── test_measurements.py
    ├── test_component_detection.py
    └── fixtures/
        └── sample_scan/         (small real scan package for integration tests)
```

---

## Staging & Priorities

| Stage | MVP? | Risk | Notes |
|-------|------|------|-------|
| 1 — Parse & Classify | Yes | Low | Extends existing PLY parsing. Straightforward. |
| 2 — Plane Fitting | Yes | **Medium** | RANSAC tuning is the main variable. Noisy mesh edges near corners will need threshold tweaking. |
| 3 — Room Assembly | Yes | **Medium** | Convex hull + wall clipping geometry. Non-convex rooms (L-shapes) are deferred. |
| 4 — Measurements | Yes | Low | Math is simple once planes exist. scan_dimensions keys must match standard (floor_area_sf, etc.). |
| 4b — Component Detection | Yes (stub) | Low | Hardcoded labels. Data contract (label IDs, JSONB format, ROOM_APPLIANCES) must be correct from day one. |
| 6 — Export & Persist | Yes | Low (DB), Medium (glTF) | DB update includes per-room status, detected_components as label IDs, scan_dimensions with standard keys. |

---

## Key Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| RANSAC fails on complex rooms (curves, alcoves) | No planes detected; measurements wrong | Fall back to bounding box measurements if < 3 planes found. Log for manual review. |
| Non-convex floor plan (L-shape, hallway) | Convex hull overestimates floor area | Detect non-convexity via concavity ratio. Later: use alpha shapes instead of convex hull. |
| Faces classified as "none" (classification=0) | Unclassified geometry is ignored | Group "none" faces, check if they cluster near walls/floor. If > 20% of mesh is "none", run plane fitting on them too and assign by normal direction. |
| scan_dimension_key mismatch | LINE_ITEM_TEMPLATES reference a key not present in scan_dimensions | Validate scan_dimensions output against SCAN_DIMENSION_KEYS at write time. Log warnings for any template referencing a missing key. |
| Schema tables not created before pipeline runs | Processor writes label IDs referencing non-existent SCAN_COMPONENT_LABELS table | Schema additions must be applied before pipeline deployment. Phase 2 stub validates label resolution with seed data. |
| Partial room failure leaves RFQ stuck | One room fails repeatedly, RFQ never reaches scan_ready | Add a max_retries counter. After 3 failures, mark room as `failed` and allow RFQ to transition to `scan_ready` with a `partial_failure` flag so the homeowner sees available rooms. |

---

## Schema Additions Required

The following tables are defined in the Miro database board but do not yet exist in `cloud/schema.sql`. They must be created before the pipeline can write label IDs or the quote builder can auto-populate line items.

### PROPERTIES

Decouples the physical building from individual RFQs. A homeowner can submit multiple RFQs for the same property over time. RFQs now carry a `property_id` FK instead of storing the address directly.

```sql
CREATE TABLE IF NOT EXISTS properties (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    homeowner_account_id UUID,
    address_line1 TEXT,
    address_line2 TEXT,
    city VARCHAR(100),
    state VARCHAR(2),
    zip VARCHAR(10),
    lat FLOAT,
    lng FLOAT,
    created_at TIMESTAMP DEFAULT NOW()
);
```

### FLOORS

Gives each level of a building a floor number and optional stitched floor plan. Enables cross-floor visualization.

```sql
CREATE TABLE IF NOT EXISTS floors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id UUID REFERENCES properties(id),
    floor_number INT NOT NULL,          -- 0=basement, 1=ground, 2=second, etc.
    label VARCHAR(100),                 -- "Basement", "1st Floor", etc.
    stitched_plan_url TEXT,             -- whole-floor image from scan registration
    created_at TIMESTAMP DEFAULT NOW()
);
```

> **Impact on SCANNED_ROOMS**: The existing `floor_id UUID` column on `scanned_rooms` should reference `floors(id)`. The `origin_x`, `origin_y`, and `rotation_deg` columns (already in schema) are populated by the scan registration step — the processor should pass these through from `metadata.json` if provided by the mobile app.

### SCAN_COMPONENT_LABELS

The platform's vocabulary of DNN-detectable materials and surfaces. Each label maps to a work type for trade-level grouping. See `DNN_COMPONENT_TAXONOMY.md` for the full label vocabulary.

```sql
CREATE TABLE IF NOT EXISTS scan_component_labels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    label_key VARCHAR(100) UNIQUE NOT NULL,  -- "floor_hardwood", "baseboard", etc.
    display_name VARCHAR(200),               -- "Hardwood Floor", "Baseboard"
    work_type_id UUID,                       -- FK to work_types (Flooring, Trim, etc.)
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT NOW()
);
```

### LINE_ITEM_TEMPLATES

The platform's master list of billable items. Each template knows which scan dimension drives its quantity.

```sql
CREATE TABLE IF NOT EXISTS line_item_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(200) NOT NULL,              -- "Sand & Finish Hardwood Floor"
    work_type_id UUID,                       -- FK to work_types
    scan_dimension_key VARCHAR(50),          -- "floor_area_sf", "perimeter_lf", etc.
    unit_type VARCHAR(20),                   -- "SF", "LF", "EA", etc.
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT NOW()
);
```

### SCAN_COMPONENT_TEMPLATES

Join table mapping a detected label to its bundle of line item templates. The `presence_required` flag controls auto-population behavior.

```sql
CREATE TABLE IF NOT EXISTS scan_component_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    scan_component_label_id UUID REFERENCES scan_component_labels(id),
    line_item_template_id UUID REFERENCES line_item_templates(id),
    presence_required BOOLEAN DEFAULT false,
    -- false: always include when parent label detected (consumables: poly coat, nails, filler)
    -- true:  only include if DNN explicitly returned this label (shoe molding, baseboards)
    created_at TIMESTAMP DEFAULT NOW()
);
```

### APPLIANCE_LABELS

Platform vocabulary of discrete detectable objects. Separate from SCAN_COMPONENT_LABELS because appliances are stored as positioned instances in ROOM_APPLIANCES (with pos_x/pos_y and contractor confirmation), not as surface-level material labels.

```sql
CREATE TABLE IF NOT EXISTS appliance_labels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    label_key VARCHAR(100) UNIQUE NOT NULL,  -- "toilet", "sink", "range", etc.
    display_name VARCHAR(200),               -- "Toilet", "Kitchen Sink"
    work_type_id UUID,                       -- FK to work_types (Plumbing, Electrical, etc.)
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT NOW()
);
```

### ROOM_APPLIANCES

Instance table for discrete objects detected in a room. Each row represents one appliance at a specific position in the room's local coordinate space.

```sql
CREATE TABLE IF NOT EXISTS room_appliances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    scanned_room_id UUID REFERENCES scanned_rooms(id),
    appliance_label_id UUID REFERENCES appliance_labels(id),
    pos_x FLOAT,                            -- room-local X position (meters)
    pos_y FLOAT,                            -- room-local Y position (meters)
    is_confirmed BOOLEAN DEFAULT false,     -- contractor verifies/corrects DNN output
    created_at TIMESTAMP DEFAULT NOW()
);
```

> **Building-global coordinates**: To find an appliance's position in building space, combine with the room's origin: `building_x = scanned_rooms.origin_x + room_appliances.pos_x`. This enables cross-floor queries like "what's directly below this toilet on floor 1?"

### FK additions to existing tables

```sql
-- SCANNED_ROOMS.floor_id should reference FLOORS
ALTER TABLE scanned_rooms
    ADD CONSTRAINT fk_scanned_rooms_floor
    FOREIGN KEY (floor_id) REFERENCES floors(id);

-- RFQS.property_id should reference PROPERTIES
ALTER TABLE rfqs
    ADD CONSTRAINT fk_rfqs_property
    FOREIGN KEY (property_id) REFERENCES properties(id);

-- Quote ROOMS need source_scan_id (add to ROOMS table when it's created)
-- ROOMS.source_scan_id UUID REFERENCES scanned_rooms(id)
```

---

## Stale References to Address

The Miro architecture board (Board 1, Flow 1) still references writing to `room_scans` JSONB on the RFQ. The database board (Board 2, Section 3 v3) explicitly replaced this with the relational `SCANNED_ROOMS` table. This pipeline plan correctly targets `SCANNED_ROOMS`, but the architecture board's Flow 1 diagram should be updated to match.
