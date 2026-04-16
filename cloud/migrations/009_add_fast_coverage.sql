-- Add fast_coverage column for Phase 1 camera-viability coverage estimate.
-- Populated during "metrics_ready" status before full OpenMVS texturing completes.
-- JSONB contains: coverage_ratio, total_faces, uncovered_count, uncovered_faces.
ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS fast_coverage JSONB;
