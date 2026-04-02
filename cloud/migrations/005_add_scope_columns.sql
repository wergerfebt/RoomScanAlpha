-- Add scope-of-work columns for structured renovation checklist data.
-- project_scope: project-level description/notes (on rfqs)
-- scope: per-room work items checklist (on scanned_rooms)
ALTER TABLE rfqs ADD COLUMN IF NOT EXISTS project_scope JSONB;
ALTER TABLE scanned_rooms ADD COLUMN IF NOT EXISTS scope JSONB;
