# RoomPlan Integration Plan

## Context

The current cloud pipeline tries to reconstruct room geometry from the raw ARKit LiDAR mesh (RANSAC plane fitting → mesh decimation). This produces fragmented surfaces with gaps because the LiDAR mesh has incomplete coverage (furniture occlusion, scan coverage limits). Apple's RoomPlan API solves this on-device — it produces gap-free parametric surfaces (walls as positioned rectangles, doors/windows as openings, objects as bounding boxes) that are exactly what we need for the simplified mesh.

**Approach:** Run RoomPlan silently alongside the existing ARKit mesh capture, sharing the same ARSession. No new UI, no new scan mode — RoomPlan captures parametric surfaces in the background while the user scans normally. The `CapturedRoom` is serialized as `roomplan.json` and included in the scan zip. The cloud processor detects it and builds the SimplifiedMesh from parametric surfaces instead of mesh decimation. Old scans without `roomplan.json` fall back to the existing path.

## Gaps & Risks from README / IMPLEMENTATION_PLAN

1. **RoomPlan doesn't capture ceilings** — must synthesize ceiling from wall top edges + ARKit mesh ceiling vertices as fallback
2. **CapturedRoom JSON format undocumented** — key names from Apple's Codable synthesis need real-device validation before building the parser. **Must capture a real `roomplan.json` early as first step.**
3. **Race condition:** `captureSession(_:didEndWith:)` fires async after `stop()` — need completion handler to ensure `capturedRoom` is populated before packaging starts
4. **`simd_float4x4` encoding order** — Apple's simd encodes column-major, but must verify with real data. Wrong order = wrong world-space vertices
5. **RoomPlan max room size 9×9m** — log warning for large rooms, fall back to mesh decimation
6. **detected_components stubbed** — RoomPlan metrics should use `scan_dimensions` keys, not stub component labels
7. **ROOM_APPLIANCES table empty** — RoomPlan objects (sink, stove, toilet) could populate it, but not blocking for MVP
8. **Mesh not indexed in DB** — only `blob_path` stored; texture projection (Phase 3) must re-download zip from GCS

## Branch

```
git checkout -b feature/roomplan-integration
```

## Implementation

### iOS Side (Steps 1-5)

**Step 1: ARSessionManager — add RoomPlan session** (`RoomScanAlpha/AR/ARSessionManager.swift`)
- Import `RoomPlan`, add `RoomCaptureSession` + `capturedRoom: CapturedRoom?` properties
- In `startSession()`: create `RoomCaptureSession`, call `rcs.run(configuration:arSession:session)` to share the existing ARSession
- In `pauseSession()`: call `roomCaptureSession.stop()` with completion to populate `capturedRoom`
- Implement `RoomCaptureSessionDelegate`: `captureSession(_:didEndWith:error:)` stores final room
- Guard behind `RoomCaptureSession.isSupported` check
- **Risk:** Verify that RoomPlan's `run(configuration:arSession:)` accepts an already-running ARSession without restarting it

**Step 2: ScanPackager — write roomplan.json** (`RoomScanAlpha/Export/ScanPackager.swift`)
- Add `capturedRoom: CapturedRoom?` parameter to `package()`
- If non-nil, `JSONEncoder().encode(room)` → write `roomplan.json` to scan directory
- Add `"roomplan_included": true/false` to `ScanMetadata`
- CapturedRoom conforms to Codable natively (iOS 17)

**Step 3: ContentView — pass capturedRoom** (`RoomScanAlpha/ContentView.swift`)
- In `startExport()`, pass `sessionManager.capturedRoom` to `ScanPackager.package()`
- One line change

**Step 4: DeviceCapability** (`RoomScanAlpha/DeviceCapability.swift`)
- Add `static var supportsRoomPlan: Bool { RoomCaptureSession.isSupported }`

**Step 5: Link RoomPlan framework** (Xcode project)
- Add RoomPlan.framework to target's "Frameworks, Libraries, and Embedded Content"

### Cloud Side (Steps 6-9)

**Step 6: RoomPlan JSON parser** (`cloud/processor/pipeline/roomplan_parser.py` — NEW)
- `parse_roomplan_json(data: dict) -> ParsedRoomPlan`
- Dataclasses: `RoomPlanSurface` (type, dimensions, transform, world vertices, area), `RoomPlanObject`, `ParsedRoomPlan`
- `_parse_surface()`: extract dimensions + transform, build quad corners in local space, apply 4x4 transform to world space
- `_transform_points()`: 4x4 matrix × Nx3 homogeneous points
- **Critical:** Verify column-major ordering for transform reshape. Apple's `simd_float4x4` Codable encodes as flat 16-element array in column-major order → use `.reshape(4, 4, order='F')`

**Step 7: Stage 3 RoomPlan path** (`cloud/processor/pipeline/stage3.py`)
- Add `assemble_geometry_from_roomplan(roomplan_data, mesh)` → `SimplifiedMesh`
- Each wall/door/window/floor surface → quad → 2 triangles (gap-free!)
- Ceiling synthesized: mirror floor quads at wall-top Y height
- Fall back to ARKit mesh ceiling vertices if walls don't provide height
- Per-face labels: "wall", "floor", "ceiling", "door", "window"

**Step 8: Processor branching** (`cloud/processor/main.py`)
- In `process_scan()`: check for `roomplan.json` in scan root
- `compute_room_metrics(ply_path, roomplan_data=roomplan_data)`
- When roomplan_data present: floor area from floor surfaces, wall area from wall surfaces, ceiling height from median wall heights, perimeter from sum of wall widths, door/window counts directly
- Add `"data_source": "roomplan"` to scan_dimensions for traceability
- `_validate_roomplan()`: optional validation, non-fatal if absent

**Step 9: Tests**
- `tests/test_roomplan_parser.py`: parse fixture JSON, verify world-space vertex transforms, area computation
- `tests/fixtures/sample_roomplan.json`: hand-crafted 4×3×2.7m room (4 walls, 1 door, 1 window)
- `tests/test_stage3.py`: add `TestRoomPlanAssembly` class verifying gap-free quad mesh from fixture
- Existing tests unchanged (mesh decimation path still works)

## Updated Scan Package Format

```
scan_<timestamp>/
├── mesh.ply              # ARKit LiDAR mesh (always present)
├── metadata.json         # Device info, intrinsics, roomplan_included flag
├── roomplan.json         # CapturedRoom Codable JSON (when available)
├── keyframes/            # JPEGs + camera transforms (always present)
└── depth/                # Raw Float32 depth maps (always present)
```

## Verification

1. **iOS:** Build on LiDAR device, scan a room, verify `roomplan.json` appears in the scan zip (inspect temp directory before upload)
2. **Cloud:** Run `diagnose_pipeline.py` on a scan containing `roomplan.json` — verify gap-free simplified mesh
3. **Backward compat:** Process an old scan (no `roomplan.json`) — must still work via mesh decimation
4. **Tests:** `pytest tests/` — all existing + new tests pass
5. **Visual:** Export simplified_mesh.ply from RoomPlan path — should show clean rectangular walls, door/window openings, no gaps

## Parallelization

iOS steps 1-5 and cloud steps 6-9 can be built in parallel — they only communicate through the `roomplan.json` file format. The first milestone is capturing a real `roomplan.json` from a test device to validate the JSON schema before building the cloud parser.
