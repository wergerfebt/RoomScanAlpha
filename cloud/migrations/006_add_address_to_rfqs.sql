-- Add address field directly to rfqs (simpler than the properties table for MVP).
ALTER TABLE rfqs ADD COLUMN IF NOT EXISTS address TEXT;
