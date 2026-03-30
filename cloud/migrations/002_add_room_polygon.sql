-- Step 4: Add room polygon and annotation source tracking to scanned_rooms.
-- room_polygon_ft: CCW polygon corners in feet [[x,y], ...] for floor plan display + quoting.
-- wall_heights_ft: per-corner ceiling height in feet (supports non-flat ceilings).
-- polygon_source: how the polygon was derived — 'annotated', 'geometric', or 'dnn'.

ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS room_polygon_ft JSONB DEFAULT NULL;
ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS wall_heights_ft JSONB DEFAULT NULL;
ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS polygon_source TEXT DEFAULT NULL;
