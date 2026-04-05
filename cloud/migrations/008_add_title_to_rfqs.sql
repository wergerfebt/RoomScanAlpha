-- Add separate title column to rfqs (previously title was concatenated into description)
ALTER TABLE rfqs ADD COLUMN IF NOT EXISTS title TEXT;

-- Backfill: extract title from "Title — Description" format in existing rows
UPDATE rfqs
SET title = split_part(description, ' — ', 1),
    description = CASE
        WHEN position(' — ' IN description) > 0
        THEN substring(description FROM position(' — ' IN description) + 3)
        ELSE description
    END
WHERE title IS NULL AND description IS NOT NULL;
