-- Step 7A: Add texture manifest column to scanned_rooms.
-- texture_manifest: JSONB mapping surface_id to GCS-relative path
-- e.g. {"wall_0": "textures/wall_0.jpg", "floor": "textures/floor.jpg", ...}

ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS texture_manifest JSONB DEFAULT NULL;
