CREATE TABLE IF NOT EXISTS rfqs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    homeowner_account_id UUID,
    property_id UUID,
    job_category_id UUID,
    description TEXT,
    status VARCHAR(50) DEFAULT 'scan_pending',
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS scanned_rooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rfq_id UUID REFERENCES rfqs(id),
    room_label VARCHAR(100),
    floor_id UUID,
    scan_status VARCHAR(50) DEFAULT 'processing',
    scan_mesh_url TEXT,
    floor_plan_url TEXT,
    origin_x FLOAT,
    origin_y FLOAT,
    rotation_deg FLOAT,
    floor_area_sqft FLOAT,
    wall_area_sqft FLOAT,
    ceiling_height_ft FLOAT,
    perimeter_linear_ft FLOAT,
    detected_components JSONB,
    scan_dimensions JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Test RFQ for smoke testing
INSERT INTO rfqs (id, status) VALUES ('00000000-0000-0000-0000-000000000001', 'scan_pending')
ON CONFLICT (id) DO NOTHING;
