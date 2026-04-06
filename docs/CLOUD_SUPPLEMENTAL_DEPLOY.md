# Cloud Deployment Plan: Supplemental Scan Merge

## Summary

Deploy the locally-validated supplemental scan merge pipeline to Cloud Run. The code changes are already committed — this plan covers the deployment steps and dependency fixes needed to get it running on cloud.

## What's Already Done (code committed)

- **Cloud API** (`cloud/api/main.py`): `GET /supplemental-upload-url` + `POST /supplemental` endpoints
- **Cloud Processor** (`cloud/processor/main.py`): `POST /process-supplemental` with two-stage voxel+proximity mesh merge + frame merge + re-texture
- **iOS** (`ContentView.swift`, `CloudUploader.swift`, `ScanPackager.swift`): `handleStopRescan()` packages + uploads supplemental data, polls for reprocessing
- **`openmvs_texture.py`**: `preview_faces` param to override 10K default → 50K for merged scans
- **Merge filter**: two-stage voxel (5cm, 0.3s) + proximity (1cm, 3.7s) = 4s total

## What Needs to Be Done

### Step 1: Fix processor container dependencies

The production container is missing two Python packages needed by the merge pipeline:

**`cloud/processor/requirements.txt`** — add:
```
rtree>=1.0.0           # trimesh.proximity.closest_point spatial index
fast-simplification>=0.1.7  # trimesh.simplify_quadric_decimation backend
```

These are already in requirements.txt from earlier commits but the container base image may also need `libspatialindex` (C library for rtree). If `pip install rtree` fails at build time, add to Dockerfile:
```dockerfile
RUN apt-get update && apt-get install -y libspatialindex-dev && rm -rf /var/lib/apt/lists/*
```

### Step 2: Update preview decimation default

**`cloud/processor/pipeline/openmvs_texture.py`** — change default preview from 10K to 50K:
```python
RESOLUTION_LEVELS = {
    "preview": 50000,   # was 10000
    "standard": 0,
}
```

This affects ALL scans (not just merged), so the preview mesh will be 5x larger (~5MB OBJ vs ~1MB). Mobile can handle 50K easily. The web viewer already loads multi-MB OBJs.

### Step 3: Update proximity threshold default

**`cloud/processor/main.py`** — `_merge_supplemental()` already uses `proximity_threshold=0.03` as default parameter. Change to `0.01` (1cm) to match local prototype results:
```python
def _merge_supplemental(orig_root, supp_root, output_dir, proximity_threshold=0.01):
```

### Step 4: Deploy processor

```bash
cd cloud/processor
gcloud run deploy scan-processor --source . --region us-central1 --project roomscanalpha
```

### Step 5: Purge old stuck tasks

```bash
gcloud tasks queues purge scan-processing --location us-central1 --project roomscanalpha
```

### Step 6: Test end-to-end

1. Do a scan on device → wait for processing → check coverage
2. Tap "Re-scan Gaps" → relocalize → walk to gaps → stop
3. App packages supplemental → uploads → triggers merge
4. Watch processor logs: `gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=scan-processor AND textPayload:supplemental"`
5. App polls → shows updated results → re-checks coverage
6. Verify coverage improved in the web viewer

### Step 7: Validate in contractor viewer

Open `https://scan-api-839349778883.us-central1.run.app/quote/{rfq_id}` — the OBJ viewer loads the merged textured mesh. Verify:
- Preview loads (50K faces, ~5MB OBJ)
- HD toggle works (full mesh)
- No visual fragmentation at merge boundary

## Key Parameters (validated locally on real data)

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Voxel pitch | 5cm | 0.3s, skips 66% of faces |
| Proximity threshold | 1cm | Tight seam without z-fighting |
| Preview faces | 50K | Clean decimation, mobile-friendly |
| Decimate target (proximity) | 50K | <2% accuracy loss, 6x faster |

## Risk Mitigation

- **Container OOM**: merged scan processing uses ~2-3GB (two zips extracted + trimesh + OpenMVS). Container has 8GB — should be fine.
- **Cloud Tasks timeout**: merge + texture takes ~3 min locally. Cloud Run has 300s default timeout. May need to increase to 600s for large scans.
- **rtree C library**: if `pip install rtree` fails, need `libspatialindex-dev` in Dockerfile.
- **Rollback**: processor is pinned by revision. If deploy fails, revert to `scan-processor-00058-fv4` (last stable).

## Files to Modify at Deploy Time

| File | Change |
|------|--------|
| `cloud/processor/requirements.txt` | Ensure `rtree`, `fast-simplification` present |
| `cloud/processor/Dockerfile` | Maybe add `libspatialindex-dev` if rtree build fails |
| `cloud/processor/pipeline/openmvs_texture.py` | Change `RESOLUTION_LEVELS["preview"]` from 10000 → 50000 |
| `cloud/processor/main.py` | Change `_merge_supplemental` default `proximity_threshold` to 0.01 |
