# Supplemental Scan Capture, Upload & Merge

## Context

After a room scan is processed, coverage review shows untextured faces (orange) and mesh holes (red). The user does a gap re-scan via ARWorldMap relocalization, capturing supplemental frames while walking to highlighted areas. These supplemental frames and LiDAR mesh data need to be packaged, uploaded, and merged with the original scan data on the cloud for reprocessing.

**Two problems solved:**
1. **Untextured faces (orange)** — mesh exists but OpenMVS couldn't assign a camera. Fix: add supplemental keyframes and re-run TextureMesh with the merged frame set.
2. **Mesh holes (red)** — geometry is missing. Fix: merge supplemental LiDAR mesh data (from the relocalized session) with the original mesh, adding faces only in void regions.

## Architecture

```
iOS: Gap rescan captures supplemental frames + LiDAR mesh
  → Package as supplemental_scan.zip (keyframes + mesh + metadata)
  → Upload to GCS alongside original scan.zip
  → POST /api/rfqs/{rfq_id}/scans/{scan_id}/supplemental
  → Cloud merges: original mesh + supplemental mesh (holes only)
  → Re-runs OpenMVS TextureMesh with ALL frames (original + supplemental)
  → Uploads new textured OBJ/atlas → polls for completion
```

## Implementation Steps

### Step 1: iOS — Package supplemental scan
**Files: `ScanPackager.swift`, `ContentView.swift`, `GapRescanView.swift`**

Add `packageSupplemental()` to ScanPackager that exports:
```
supplemental_scan_TIMESTAMP/
├── mesh.ply                    # LiDAR mesh from relocalized session
├── metadata.json               # Supplemental metadata (intrinsics, frame list)
├── keyframes/
│   ├── frame_000.jpg           # Supplemental JPEG keyframes  
│   ├── frame_000.json          # Per-frame camera_transform (in original world coords)
│   └── frame_000.depth         # Depth maps
```

This is structurally identical to the original package — same format, same conventions. The key difference: these frames are captured in the relocalized coordinate system (same world origin as original via ARWorldMap).

Update `handleStopRescan()` to:
1. Snapshot mesh anchors from the relocalized session
2. Call `packageSupplemental()` with the captured frames + mesh
3. Upload to GCS
4. Notify backend to merge + reprocess

### Step 2: iOS — Upload supplemental package
**Files: `CloudUploader.swift`, `ContentView.swift`**

Add `uploadSupplemental(scanDirectoryURL:rfqId:scanId:)` that:
1. Zips the supplemental package
2. Gets a signed URL (new endpoint or reuse existing with a `supplemental=true` param)
3. Uploads zip to GCS at `scans/{rfq_id}/{scan_id}/supplemental_scan.zip`
4. Calls `POST /api/rfqs/{rfq_id}/scans/{scan_id}/supplemental` to trigger merge

### Step 3: Cloud API — Supplemental endpoint
**File: `cloud/api/main.py`**

Add `POST /api/rfqs/{rfq_id}/scans/{scan_id}/supplemental`:
1. Verify Firebase JWT
2. Get signed upload URL for `supplemental_scan.zip`
3. After upload complete, enqueue Cloud Task to processor's `/process-supplemental`

### Step 4: Cloud Processor — Merge & reprocess
**File: `cloud/processor/main.py`**

Add `POST /process-supplemental` endpoint:

**Mesh merge (Path A — additive only):**
1. Download original `scan.zip` + `supplemental_scan.zip`
2. Parse both PLY meshes with trimesh
3. Find void regions in the original mesh (reuse ray-casting from coverage)
4. From the supplemental mesh, keep only faces whose centroids fall in void regions
5. Merge: `combined_mesh = original_faces + filtered_supplemental_faces`
6. Export merged mesh as `mesh.ply`

**Frame merge:**
1. Extract keyframes from both packages
2. Combine into a single `keyframes/` directory with continuous numbering
3. Build unified `metadata.json` with all frames listed
4. Original frames: `frame_000.jpg` through `frame_179.jpg`
5. Supplemental frames: `frame_180.jpg` through `frame_N.jpg`

**Re-texture:**
1. Run `texture_scan()` with merged mesh + merged frames
2. Upload new textured OBJ/atlas to GCS (overwrites previous)
3. Update scan status in DB

### Step 5: iOS — Poll and show results
**File: `ContentView.swift`**

After supplemental upload completes:
1. Show processing UI (reuse existing `processingView` with updated messages)
2. Poll for completion (reuse `pollForResult`)
3. Re-run coverage check to verify improvement
4. Show updated coverage % and re-scan option if still below threshold

## Mesh Merge Filter: "Don't overwrite, only add"

The critical constraint: supplemental mesh data should only ADD geometry in void regions, never replace existing good mesh.

```python
# Pseudo-code for mesh merge
original = trimesh.load("original/mesh.ply")
supplemental = trimesh.load("supplemental/mesh.ply")

# Find void regions using ray-casting (reuse from coverage)
center = original.vertices.mean(axis=0)
rays = fibonacci_sphere(10000)
_, hit_rays, _ = original.ray.intersects_location(origins, rays)
miss_directions = [rays[i] for i in range(10000) if i not in hit_rays]

# For each supplemental face, check if its centroid is in a void region
keep_faces = []
for face in supplemental.faces:
    centroid = supplemental.vertices[face].mean(axis=0)
    direction = centroid - center
    direction /= np.linalg.norm(direction)
    # Cast ray from center toward this face — does it hit original mesh first?
    hits = original.ray.intersects_any([center], [direction])
    if not hits[0]:  # Ray escapes = void region = keep this face
        keep_faces.append(face)

# Merge
merged = trimesh.util.concatenate([original, trimesh.Trimesh(
    vertices=supplemental.vertices,
    faces=np.array(keep_faces)
)])
```

## Files to Modify

| File | Change |
|------|--------|
| `ScanPackager.swift` | Add `packageSupplemental()` method |
| `ContentView.swift` | Update `handleStopRescan()` to package + upload |
| `CloudUploader.swift` | Add `uploadSupplemental()` method |
| `ScanViewModel.swift` | Add supplemental upload state |
| `cloud/api/main.py` | Add `/supplemental` endpoint + signed URL |
| `cloud/processor/main.py` | Add `/process-supplemental` endpoint |
| `ScanResultView.swift` | Show reprocessing state after supplemental upload |

## Prototype Strategy

Start with a **local prototype** for the mesh merge logic:
1. Download an original `scan.zip` and manually create a supplemental package from a second scan of the same room
2. Test mesh merge: load both PLY files, filter supplemental faces, export merged mesh
3. Test frame merge: combine keyframes, build unified metadata
4. Run `texture_scan()` locally on the merged data
5. Compare textured output against original — verify coverage improvement

## Key Constraints

1. **Never pause AR session between scan and export** — texture alignment constraint
2. **ARWorldMap relocalization** ensures supplemental frames share the same coordinate system
3. **Supplemental mesh filter** only adds faces in void regions — never overwrites existing mesh
4. **Frame numbering** continues from original (180+) to avoid name collisions
5. **Same camera intrinsics** guaranteed (same device, same session config)
6. **Coordinate conventions**: ARKit meters Y-up, COLMAP flip `diag(1,-1,-1)` for camera poses

## Verification

1. Scan a room → process → see coverage gaps (orange + red)
2. Tap "Re-scan Gaps" → relocalize → walk to gaps → stop
3. App packages supplemental data → uploads → shows "Reprocessing..."
4. Cloud merges mesh + frames → re-textures → new result
5. Coverage check shows improved % with fewer orange/red patches
6. Repeat if needed until coverage is acceptable
