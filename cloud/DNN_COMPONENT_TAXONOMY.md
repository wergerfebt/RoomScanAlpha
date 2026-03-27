# DNN Component Detection — Taxonomy & Training Spec

> **Extracted from**: `CLOUD_PIPELINE_PLAN.md` Stage 4b. This document defines the full DNN class vocabulary, detection details, and training requirements. The pipeline plan references this document but only contains the data contract (label ID format, JSONB structure, SCAN_COMPONENT_LABELS FK).

---

## Overview

The Vertex AI DNN endpoint detects construction-relevant components from keyframe images. Each detection maps to a `scan_component_label` entry in the platform vocabulary. Detected labels drive the quote auto-population flow:

```
detected_components (label IDs on SCANNED_ROOMS)
  → SCAN_COMPONENT_TEMPLATES (join: label_id → template bundle)
    → LINE_ITEM_TEMPLATES (each template has scan_dimension_key + unit_type)
      → LINE_ITEMS (seeded with quantity, priced from contractor's PRICE_LIST_ITEM)
```

The DNN returns label keys (not boolean flags), preserving specificity for template lookup. Bounding boxes are returned for object-type detections (appliances, cabinets, fixtures) in image pixel coordinates — the pipeline reprojects them to 3D using the keyframe's camera pose + depth map.

---

## Component Taxonomy (30+ classes, 7 categories)

### Appliances — discrete objects with 3D bounding box position

Appliance detections are written to the **ROOM_APPLIANCES** table (not detected_components JSONB) with room-local `pos_x`/`pos_y` coordinates and `is_confirmed = false` (contractor verifies). Each maps to an APPLIANCE_LABELS entry.

| Label Key | Display Name | Unit | Notes |
|---|---|---|---|
| `sink` | Sink | EA | Kitchen or bath. Position on floor plan indicates plumbing. |
| `fridge` | Refrigerator | EA | |
| `range` | Range/Oven | EA | Position indicates gas/electric line. |
| `tub` | Bathtub | EA | |
| `toilet` | Toilet | EA | |
| `shower` | Shower | EA | Distinguish from tub via aspect ratio. |
| `washer` | Washer | EA | Position indicates plumbing + electrical. |
| `dryer` | Dryer | EA | Position indicates venting + electrical. |

**Appliance position → utility inference**: Object positions are used for floor plan rendering and cross-floor utility inference. A sink on floor 2 at position (1.2, 2.3) suggests a plumbing stack below it on floor 1. This inference is downstream logic (not in the pipeline), but the position data must be accurate and persisted.

### Cabinets — classified by mount type and depth from wall

Cabinet detections go into **detected_components** JSONB on SCANNED_ROOMS (they're surface-associated, not freestanding objects). Cabinet run lengths are written to `scan_dimensions` as `cabinet_upper_lf`, `cabinet_lower_lf`, `cabinet_full_lf`.

| Label Key | Display Name | scan_dimension_key | Unit | Notes |
|---|---|---|---|---|
| `cabinet_upper_skinny` | Upper Cabinet (Shallow) | `cabinet_upper_lf` | LF | Depth ≤ 14" from wall face. Measured as linear feet of cabinet run. |
| `cabinet_upper_wide` | Upper Cabinet (Deep) | `cabinet_upper_lf` | LF | Depth > 14" from wall face. |
| `cabinet_lower_skinny` | Lower/Base Cabinet (Shallow) | `cabinet_lower_lf` | LF | Depth ≤ 24" from wall face. |
| `cabinet_lower_wide` | Lower/Base Cabinet (Deep) | `cabinet_lower_lf` | LF | Depth > 24" from wall face. |
| `cabinet_full_skinny` | Full Height Cabinet (Shallow) | `cabinet_full_lf` | LF | Floor-to-ceiling or pantry. Depth ≤ 18". |
| `cabinet_full_wide` | Full Height Cabinet (Deep) | `cabinet_full_lf` | LF | Depth > 18". |

> **Cabinet depth classification**: Binary (skinny/wide) per mount type. Depth is measured from the wall plane (Stage 2) to the front face of the cabinet bounding box (Stage 2 OBB). Threshold varies by mount type because upper cabinets are shallower. Cabinet run length (LF) is the horizontal extent of the bounding box along the wall.

### Floor Materials — detected on floor-classified surfaces

| Label Key | Display Name | scan_dimension_key | Unit | Notes |
|---|---|---|---|---|
| `floor_hardwood` | Hardwood Floor | `floor_area_sf` | SF | |
| `floor_carpet` | Carpet | `floor_area_sf` | SF | |
| `floor_tile` | Tile Floor | `floor_area_sf` | SF | Ceramic, porcelain, or stone. |

### Ceiling Types — detected on ceiling-classified surfaces

| Label Key | Display Name | scan_dimension_key | Unit | Notes |
|---|---|---|---|---|
| `ceiling_drywall` | Drywall Ceiling | `ceiling_sf` | SF | Flat or textured. |
| `ceiling_drop` | Drop/Suspended Ceiling | `ceiling_sf` | SF | Grid + tiles. Stage 2 may detect a gap between drop ceiling plane and structural ceiling. |

### Trim & Molding — linear elements detected along surface edges

| Label Key | Display Name | scan_dimension_key | Unit | Notes |
|---|---|---|---|---|
| `baseboard` | Baseboard | `perimeter_lf` | LF | Quantity = perimeter minus door openings. |
| `toe_kick` | Toe Kick | `cabinet_lower_lf` | LF | Quantity = lower cabinet run length. |
| `shoe_molding` | Shoe Molding | `perimeter_lf` | LF | |

### Doors & Openings — detected as objects with width

| Label Key | Display Name | scan_dimension_key | Unit | Notes |
|---|---|---|---|---|
| `door_interior` | Interior Door | `door_count` | EA | |
| `door_exterior` | Exterior Door | `door_count` | EA | Thicker frame, weather stripping visible. |

### Light Fixtures — detected from ceiling keyframes

| Label Key | Display Name | scan_dimension_key | Unit | Notes |
|---|---|---|---|---|
| `light_recessed` | Recessed Light | `ea` | EA | Count of visible cans. |
| `light_fixture` | Ceiling Light Fixture | `ea` | EA | Flush mount, pendant, chandelier. |
| `light_fluorescent` | Fluorescent Light | `ea` | EA | Tube or panel. Common in kitchens/garages. |

---

## Detection Implementation Details

### 3D Localization of Detected Objects

For each object-type detection (appliances, cabinets, fixtures):
- Use the 2D bounding box center + depth map → 3D world position
- Cross-reference with Stage 2 surface geometry to snap objects to the nearest wall/floor plane
- For cabinets: compute depth from wall plane to front face of bounding box → classify skinny vs wide
- For cabinets: compute horizontal extent along wall → linear feet

### Keyframe Selection for Inference

Choose the best keyframes for DNN inference — one per major surface (floor, each wall, ceiling). Reuse the viewing angle + coverage scoring from Stage 5's keyframe-to-surface assignment. Aim for 5-10 keyframes that collectively cover the room.

### Multi-Keyframe Aggregation & Deduplication

- A label is confirmed if detected in ≥ 2 keyframes (reduces false positives)
- Object detections are deduplicated spatially — if two keyframes detect a "sink" within 0.5m of the same 3D position, they're the same sink
- Aggregated confidence = max confidence across detections

---

## EA (Each) Quantity Flow

For items with `scan_dimension_key = "ea"` or count-based keys like `door_count`:

- **Appliances** (toilet, sink, etc.): Quantity = count of ROOM_APPLIANCES rows matching that appliance label for the room. The auto-population logic counts rows, not a scan_dimensions value.
- **Doors**: Quantity = `scan_dimensions["door_count"]` (an integer computed in Stage 4 from detected door objects).
- **Light fixtures**: Quantity = count of detections in detected_components matching that label. This count must be stored explicitly — either as a field on the detected_components entry or as a separate scan_dimensions key (e.g., `light_recessed_count`).

This means the auto-population query has two paths:
1. **Dimension-based**: `quantity = scan_dimensions[template.scan_dimension_key]` (floor_area_sf, perimeter_lf, etc.)
2. **Count-based**: `quantity = COUNT(*) FROM room_appliances WHERE label matches` or `quantity = detected_components entry count`

---

## Training Requirements

### Training Data

- 200-500 labeled examples per component class
- Prioritize high-frequency classes first

**Tier 1** (15 classes, ~500 examples each — train first):
- floor_hardwood, floor_carpet, floor_tile
- ceiling_drywall, ceiling_drop
- baseboard, shoe_molding
- sink, toilet, tub, range, fridge
- door_interior, cabinet_lower_skinny, cabinet_upper_skinny

**Tier 2** (remaining classes — train after Tier 1 validates):
- shower, washer, dryer
- cabinet_*_wide, cabinet_full_*
- toe_kick, door_exterior
- light_recessed, light_fixture, light_fluorescent

### DNN Architecture

- Object detection model (e.g., EfficientDet or YOLOv8) for appliances, cabinets, fixtures (bounding boxes)
- Classification head for surface materials (floor type, ceiling type, trim presence) — whole-image or patch-based
- Single multi-task model preferred over separate models per category

### Vertex AI Deployment

```python
from google.cloud import aiplatform

endpoint = aiplatform.Endpoint(VERTEX_ENDPOINT_ID)
# Send keyframe batch — endpoint returns detected labels per image
predictions = endpoint.predict(instances=keyframe_batch)
```

Endpoint returns per-image:
```json
{
  "labels": ["floor_hardwood", "baseboard", "sink"],
  "objects": [
    {"label": "sink", "bbox": [120, 340, 280, 480], "confidence": 0.91},
    {"label": "cabinet_upper_wide", "bbox": [50, 100, 600, 300], "confidence": 0.85}
  ]
}
```

---

## Test Cases

| ID | Test | Expected | Pass Criteria |
|----|------|----------|---------------|
| DNN.1 | DNN detects floor material | Send keyframes from room with hardwood floor | Response includes "floor_hardwood" | Label present with confidence > 0.7 |
| DNN.2 | DNN detects appliance with position | Kitchen with sink visible | "sink" detected with 3D position | Position is on/near a wall; Y ≈ counter height (0.8-1.0m) |
| DNN.3 | Cabinet depth classified correctly | Upper cabinets at 12" depth | "cabinet_upper_skinny" detected | depth_in ≤ 14; label_key ends with "_skinny" |
| DNN.4 | Cabinet run length measured | 8ft run of lower cabinets | run_lf ≈ 8.0 | Within ±10% of ground truth |
| DNN.5 | Multi-keyframe aggregation | Same label detected in 3/5 keyframes | Label is confirmed | Label appears in output with aggregated confidence |
| DNN.6 | False positive filtering | Label detected in only 1/8 keyframes | Label is excluded | Label does NOT appear in output |
| DNN.7 | Spatial deduplication | Same sink detected in 3 keyframes | One sink in output | Single entry with highest confidence; position is average of detections |
| DNN.8 | Ceiling type detected | Room with drop ceiling | "ceiling_drop" detected | Label present; ceiling_sf measurement still populated from Stage 4 |
| DNN.9 | Light fixtures counted | Room with 4 recessed lights | "light_recessed" detected with count | Count matches visible fixtures (±1) |
| DNN.10 | Door type distinguished | Interior and exterior door in same scan | Both detected | Each has distinct position; door_count in scan_dimensions = total |
| DNN.11 | Tier 1 accuracy | Test against labeled validation set | Per-class precision > 0.8 | Average precision across Tier 1 classes > 0.85 |
| DNN.12 | Cabinet depth threshold accuracy | Test skinny/wide on labeled cabinets | Correct classification | > 90% accuracy on skinny/wide split per mount type |

---

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| 30+ class taxonomy needs large training set | Model accuracy poor for rare components (dryers, full-height cabinets) | Prioritize high-frequency classes first. Train in tiers. |
| Cabinet depth classification error | Skinny/wide misclassified → wrong line items in quote | Binary threshold per mount type. Validate against labeled test set. Allow manual override in quote builder UI. |
| DNN label vocabulary drift | Labels in DNN output don't match SCAN_COMPONENT_LABELS rows | SCAN_COMPONENT_LABELS is the source of truth. Unknown labels logged for vocabulary expansion. |
| Appliance detection in cluttered rooms | False positives from objects resembling appliances | Multi-keyframe confirmation (≥ 2 keyframes). Contractor `is_confirmed` flag as safety net. |
| Training data collection bottleneck | 500 examples × 30 classes = 15,000 labeled images | Start with Tier 1 (15 classes). Use existing scan uploads for passive collection. Label in batches. |
