-- Migration 017: Albums + video support for portfolio gallery

CREATE TABLE IF NOT EXISTS albums (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organizations(id),
    title TEXT NOT NULL,
    description TEXT,
    service_id UUID REFERENCES services(id),
    rfq_id UUID REFERENCES rfqs(id),
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_albums_org ON albums(org_id);
CREATE INDEX IF NOT EXISTS idx_albums_service ON albums(service_id);

-- Add album + video columns to existing media table
ALTER TABLE org_work_images ADD COLUMN IF NOT EXISTS album_id UUID REFERENCES albums(id);
ALTER TABLE org_work_images ADD COLUMN IF NOT EXISTS media_type VARCHAR(10) DEFAULT 'image';
