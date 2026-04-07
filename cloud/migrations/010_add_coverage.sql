-- Add coverage column for accurate UV-based coverage computed inline during processing.
-- Contains: coverage_ratio, total_faces, uncovered_count, uncovered_faces, hole_count, hole_faces.
ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS coverage JSONB;
