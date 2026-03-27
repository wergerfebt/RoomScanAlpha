# Visualization Plan — Floor Plans & Measurement Annotations

> **Prerequisite**: `CLOUD_PIPELINE_PLAN.md` Stages 1-4b + 6 must be complete (real measurements + detected components in DB). This plan covers Layer 3 visual output — textured geometry, 2D floor plans, and 3D measurement annotations.
>
> **Related**: `WEB_VIEWER_PLAN.md` (Stage 9) consumes the outputs defined here. `DNN_COMPONENT_TAXONOMY.md` defines the component labels used for appliance icons and labels.

---

## Stage 5: Texture Projection

**Goal**: Project keyframe images onto the simplified surfaces so each wall/floor/ceiling has a camera-captured texture. This turns the smooth geometry from Stage 3 into a recognizable visual representation of the room.

**Input**: SimplifiedMesh (with UVs) + keyframes (JPEGs + camera poses + intrinsics)
**Output**: Per-surface texture images (one texture atlas per surface, or one per face group)

**Implementation**:

1. **Camera pose recovery**: Load each keyframe's 4x4 camera transform (column-major, world-to-camera). Build projection matrix: `P = K × [R|t]` where K is the 3x3 intrinsics matrix.

2. **Keyframe-to-surface assignment**: For each simplified surface:
   - For each keyframe, check if the camera's view frustum intersects the surface
   - Score by: (a) viewing angle — prefer near-perpendicular views, (b) distance — prefer closer, (c) coverage — prefer keyframes where the surface occupies more pixels
   - Select the top 1-3 keyframes per surface

3. **Texture extraction per surface**:
   - Define the surface's UV space (e.g., for a wall quad: U = horizontal position along wall, V = vertical position from floor to ceiling)
   - For each texel in the output texture:
     - Transform UV → 3D world position on the surface
     - Project world position → pixel coordinates in the selected keyframe using `P`
     - Sample the keyframe image at those pixel coordinates (bilinear interpolation)
   - Where multiple keyframes cover the same texel, blend using weighted average (weight = viewing angle score)

4. **Seam blending**: Where adjacent surfaces meet (wall-floor, wall-wall corners), apply a narrow Gaussian blend along the edge to reduce visible seams.

5. **Output**: One texture image per surface (e.g., `wall_0.jpg`, `floor.jpg`, `ceiling.jpg`). Resolution proportional to surface area — target ~100 pixels/meter for walls, ~50 pixels/meter for floor/ceiling.

**Depth-based occlusion** (stretch goal): Use depth maps to detect occluded regions (e.g., table blocking the floor behind it) and mask those texels as "no data" so blending picks a different keyframe.

### Test Cases — Stage 5

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S5.1 | Wall texture is recognizable | View wall_0.jpg | Image shows the actual wall from the scan | Visual inspection: wall features (outlets, trim, paint color) are visible |
| S5.2 | Floor texture covers full polygon | View floor.jpg | No large black/missing regions | ≥ 90% of texels have non-zero values |
| S5.3 | Texture alignment with geometry | Load textured model, compare to keyframe | Textures align with surface edges | Feature edges in texture (baseboards, corners) align with mesh edges within ±5 pixels |
| S5.4 | Multiple keyframes blended smoothly | Wall covered by 2+ keyframes | No hard seam where coverage overlaps | Blended region has no visible brightness/color discontinuity |
| S5.5 | Texture resolution scales with surface area | Compare texture size for large wall vs small wall | Larger surface gets more pixels | Pixels-per-meter ratio is consistent across surfaces (±20%) |
| S5.6 | Viewing angle weighting works | Wall viewed at sharp angle from one keyframe and straight-on from another | Straight-on keyframe dominates the texture | Texture is sharp (not stretched/skewed from oblique projection) |

---

## Stage 7: Floor Plan Generation

**Goal**: Generate a 2D top-down architectural floor plan from the simplified geometry. The floor plan serves as the primary navigation map in the web viewer and as a standalone deliverable. Multi-room plans are stitched using room origins. Multi-floor plans stack with semi-transparency so utility lines (plumbing, electrical) can be inferred from appliance positions on adjacent floors.

**Input**: SimplifiedMesh + DetectedPlanes + DetectedComponents (with positions) + room origin/rotation from metadata.json + floor_id
**Output**: Per-floor SVG + PNG floor plan, uploaded to GCS

### Single-Room Plan

1. **Project room polygon to 2D**: Take the floor polygon from Stage 3, project onto XZ plane (drop Y axis). This gives the room outline in meters.
2. **Draw walls as thick lines**: Wall segments from the floor polygon edges. Wall thickness = 0.15m (6") default for interior walls.
3. **Door openings**: For each detected door (Stage 4b), cut a gap in the wall line at the door's position. Draw standard architectural door swing arc.
4. **Window indicators**: For each detected window (Stage 2 objects), draw a double-line symbol on the wall at the window's position.
5. **Appliance icons**: For each detected appliance (ROOM_APPLIANCES), place a standardized icon at the object's XZ position:
   - Sink: rectangle with oval basin
   - Fridge: rectangle with hinge line
   - Range: rectangle with 4 burner circles
   - Tub: rounded rectangle
   - Toilet: oval with tank
   - Shower: square with spray icon
   - Washer/Dryer: circles
   - Cabinets: shaded rectangles along walls (width = run_lf, depth from wall)
6. **Room label**: Center the room_label text inside the polygon.
7. **Scale bar**: Include a scale indicator (e.g., 1m reference line).

### Multi-Room Floor Plan (stitched)

When multiple rooms share the same `floor_id`:

1. For each room, apply its `origin_x`, `origin_y`, `rotation_deg` transform to place it in building-global XZ coordinates.
2. Merge wall segments: where two rooms share a wall (overlapping wall lines within 0.3m tolerance), collapse to a single wall line.
3. Render all rooms in a single SVG with unified coordinate space.
4. Each room polygon is a clickable region in the web viewer (Stage 9).

### Multi-Floor Stacking

When a property has multiple floors:

1. Render each floor as a separate SVG layer.
2. In the web viewer, the selected floor is rendered at full opacity. Other floors are rendered at 15-25% opacity behind/below it.
3. Appliance icons from adjacent floors are visible through the semi-transparent layer — a sink on floor 2 visually overlays floor 1, hinting at plumbing stack locations.
4. Floor selector UI in the web viewer switches the active floor.

### Output Format

```
results/{rfq_id}/floor_plans/
├── floor_1.svg          (vector — zoomable, clickable rooms)
├── floor_1.png          (raster — 300 DPI for print/PDF)
├── floor_2.svg
├── floor_2.png
└── plan_metadata.json   (room polygons, click regions, appliance positions)
```

**plan_metadata.json** (consumed by web viewer for interactivity):
```json
{
  "floors": [
    {
      "floor_id": "uuid",
      "floor_number": 1,
      "label": "1st Floor",
      "svg_url": "floor_1.svg",
      "rooms": [
        {
          "scan_id": "uuid",
          "room_label": "Kitchen",
          "polygon_2d": [[0,0], [4.2,0], [4.2,3.8], [0,3.8]],
          "center_2d": [2.1, 1.9],
          "appliances": [
            {"type": "sink", "position_2d": [1.2, 2.3], "on_wall": "wall_2"},
            {"type": "range", "position_2d": [2.8, 3.7], "on_wall": "wall_1"}
          ]
        }
      ]
    }
  ]
}
```

### Test Cases — Stage 7

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S7.1 | Single room floor plan generated | Process one room scan | SVG file created with room outline | SVG contains a closed polygon; dimensions proportional to LiDAR measurements |
| S7.2 | Room dimensions match measurements | Compare SVG polygon to Stage 4 measurements | Floor area from polygon ≈ floor_area_sf | Within ±3% |
| S7.3 | Door openings rendered | Room with 2 doors | 2 gaps in wall lines with swing arcs | Gaps at correct positions; opening width matches door bounding box |
| S7.4 | Appliance icons placed correctly | Kitchen with sink + range | Icons at correct positions relative to walls | Icon XZ position within ±0.3m of detected position |
| S7.5 | Cabinet runs drawn along walls | Kitchen with 8ft lower cabinet run | Shaded rectangle along wall | Rectangle length ≈ 8ft; depth matches skinny/wide classification |
| S7.6 | Multi-room plan stitched | 3 rooms on same floor | All 3 rooms in one SVG with correct relative positions | Room positions match origin_x/y offsets; shared walls collapsed |
| S7.7 | Multi-floor stacking | 2-floor property | Both floor SVGs generated; plan_metadata.json has both floors | Floor selector can switch between them; appliance positions preserved per floor |
| S7.8 | plan_metadata.json is valid | Parse the output JSON | All rooms, polygons, and appliance positions present | Polygon vertex count ≥ 3 per room; appliance positions are inside room polygons |
| S7.9 | PNG renders at print quality | Check floor_1.png | Clean, readable at 300 DPI | Image resolution ≥ 3000px on longest axis; text is legible |

---

## Stage 8: Measurement Annotations

**Goal**: Generate positioned 3D dimensional annotations for every measurable element in the room. These are rendered as an overlay layer in the web viewer — toggled on/off like an Xactimate measurement layer.

**Input**: SimplifiedMesh + RoomMeasurements + DetectedPlanes + DetectedComponents
**Output**: Annotation JSON file uploaded to GCS alongside the model

### Annotation Types

| Type | Geometry | Label Format | Attachment Points |
|------|----------|-------------|-------------------|
| **Wall length** | Horizontal line along top of wall | `12' 6"` | Wall-wall corner to corner, at ceiling height |
| **Ceiling height** | Vertical line in room corner | `8' 0"` | Floor plane to ceiling plane, at a corner vertex |
| **Floor area** | Centered text on floor polygon | `129 SF` | Center of floor polygon, Y = floor + 0.1m |
| **Wall area** | Centered text on wall quad | `96 SF` | Center of wall face |
| **Ceiling area** | Centered text on ceiling polygon | `129 SF` | Center of ceiling, Y = ceiling - 0.1m |
| **Perimeter** | Dashed line at floor edge | `46 LF` | Along floor polygon perimeter, Y = floor + 0.05m |
| **Cabinet run** | Line along cabinet front face | `6' 6" LF` | Start to end of cabinet bounding box along wall |
| **Object dimension** | Bracket across object | `2' 4" × 3' 0"` | Object bounding box edges (appliances, tables) |

### Annotation JSON Format

```json
{
  "annotations": [
    {
      "id": "wall_0_length",
      "type": "linear",
      "label": "12' 6\"",
      "value_ft": 12.5,
      "unit": "LF",
      "start": [0, 2.44, 0],
      "end": [3.81, 2.44, 0],
      "normal": [0, 0, 1],
      "category": "dimension"
    },
    {
      "id": "ceiling_height",
      "type": "linear",
      "label": "8' 0\"",
      "value_ft": 8.0,
      "unit": "FT",
      "start": [0, 0, 0],
      "end": [0, 2.44, 0],
      "normal": [1, 0, 0],
      "category": "dimension"
    },
    {
      "id": "floor_area",
      "type": "area",
      "label": "129 SF",
      "value_sf": 129.2,
      "unit": "SF",
      "position": [2.1, 0.1, 1.9],
      "category": "area"
    },
    {
      "id": "sink_0",
      "type": "object_label",
      "label": "Sink",
      "position": [1.2, 0.9, -2.3],
      "category": "component"
    }
  ],
  "categories": {
    "dimension": {"color": "#2196F3", "default_visible": false},
    "area":      {"color": "#4CAF50", "default_visible": false},
    "component": {"color": "#FF9800", "default_visible": true}
  }
}
```

### Implementation

1. **Wall lengths**: For each pair of adjacent wall-wall corner vertices (at ceiling height), compute distance. Format as feet-inches.
2. **Ceiling height**: Pick the corner with the clearest vertical span. Start = floor plane Y at that XZ, end = ceiling plane Y.
3. **Area labels**: Center position of each surface polygon. Floor area, wall area (per wall), ceiling area.
4. **Perimeter**: Place a dashed annotation path along the floor polygon edges at Y = floor + 0.05m.
5. **Object labels**: For each detected component with a 3D position, create a label annotation at that position.
6. **Cabinet run labels**: For each cabinet detection, place a linear annotation along the wall at the cabinet's run extent.
7. **Feet-inches formatting**: `round(ft) → whole_feet, (ft - whole_feet) * 12 → inches`. Display as `12' 6"`.

### Test Cases — Stage 8

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| S8.1 | Wall length annotations generated | Process a rectangular room | 4 wall length annotations | Each annotation has start/end points at ceiling height; labels are in feet-inches format |
| S8.2 | Ceiling height annotation generated | Room with 8ft ceiling | Vertical annotation in corner | value_ft ≈ 8.0; start Y ≈ floor, end Y ≈ ceiling |
| S8.3 | Floor area annotation positioned | Check floor_area annotation | Label centered on floor polygon | Position XZ is inside floor polygon; Y ≈ floor + 0.1m |
| S8.4 | Object labels at correct positions | Kitchen with sink | "Sink" label annotation | Position matches detected_components sink position (±0.3m) |
| S8.5 | Annotations JSON is valid | Parse the output | All required fields present per annotation | Each annotation has id, type, label, category; positions are valid float arrays |
| S8.6 | Feet-inches formatting correct | 12.5 feet | "12' 6\"" | No decimal feet in labels; inches rounded to nearest inch |
| S8.7 | Category visibility defaults | Check categories object | Dimensions default off, components default on | dimension.default_visible = false; component.default_visible = true |

---

## Dependencies (additions for Layer 3)

```python
# Added to cloud/processor/requirements.txt for Stages 5, 7, 8
svgwrite>=1.4.0          # Stage 7: SVG floor plan generation
cairosvg>=2.7.0          # Stage 7: SVG → PNG rasterization at 300 DPI
```

Stages 5 and 8 use deps already in the pipeline plan: `Pillow`, `numpy`, `trimesh`.

---

## Risks

| Risk | Impact | Mitigation | Stage |
|------|--------|------------|-------|
| Camera pose drift across 60 keyframes | Textures misalign with geometry | ARKit world tracking is typically accurate to ±2cm. If drift is visible, implement pose refinement via feature matching (OpenCV) as a later stage. | 5 |
| Large texture atlas size | Slow download to device/browser | Cap texture resolution at 2048×2048 per surface. Compress as JPEG at 0.85 quality. Target < 20MB total textures. Lazy-load textures in web viewer. | 5 |
| Multi-room origin alignment drift | Floor plan shows rooms overlapping or with gaps | Validate by checking that room polygons don't overlap by > 0.1m. Log misalignment for manual adjustment. Multi-room stitching is best-effort initially. | 7 |
| SVG rendering inconsistencies across browsers | Floor plan looks different in Chrome vs Safari | Use basic SVG features only (paths, rects, text). Test in Chrome, Safari, Firefox. Avoid filters/gradients. | 7 |
