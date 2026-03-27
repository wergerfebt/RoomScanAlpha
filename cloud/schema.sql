-- ============================================================
-- Quoterra Schema — matches Miro DB Board (Sections 3v3, 5, 5b)
-- Migration order satisfies FK constraints:
--   1. PROPERTIES
--   2. FLOORS → PROPERTIES
--   3. RFQS → PROPERTIES
--   4. SCANNED_ROOMS → RFQS, FLOORS
--   5. SCAN_COMPONENT_LABELS, LINE_ITEM_TEMPLATES, APPLIANCE_LABELS
--   6. SCAN_COMPONENT_TEMPLATES → SCAN_COMPONENT_LABELS, LINE_ITEM_TEMPLATES
--   7. ROOM_APPLIANCES → SCANNED_ROOMS, APPLIANCE_LABELS
-- ============================================================

-- 1. PROPERTIES — physical buildings, decoupled from RFQs
CREATE TABLE IF NOT EXISTS properties (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    homeowner_account_id UUID,
    address_line1 TEXT,
    address_line2 TEXT,
    city VARCHAR(100),
    state VARCHAR(2),
    zip VARCHAR(10),
    lat FLOAT,
    lng FLOAT,
    created_at TIMESTAMP DEFAULT NOW()
);

-- 2. FLOORS — levels within a property
CREATE TABLE IF NOT EXISTS floors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    property_id UUID REFERENCES properties(id),
    floor_number INT NOT NULL,
    label VARCHAR(100),
    stitched_plan_url TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);

-- 3. RFQS — request-for-quote projects
CREATE TABLE IF NOT EXISTS rfqs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    homeowner_account_id UUID,
    property_id UUID REFERENCES properties(id),
    job_category_id UUID,
    description TEXT,
    status VARCHAR(50) DEFAULT 'scan_pending',
    created_at TIMESTAMP DEFAULT NOW()
);

-- 4. SCANNED_ROOMS — one row per processed room scan
-- scan_status lifecycle: pending → processing → complete → failed
-- RFQ status transitions to 'scan_ready' only when ALL rooms reach 'complete'
CREATE TABLE IF NOT EXISTS scanned_rooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rfq_id UUID REFERENCES rfqs(id),
    room_label VARCHAR(100),
    floor_id UUID REFERENCES floors(id),
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

-- 5a. SCAN_COMPONENT_LABELS — platform vocabulary of DNN-detectable materials/surfaces
CREATE TABLE IF NOT EXISTS scan_component_labels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    label_key VARCHAR(100) UNIQUE NOT NULL,
    display_name VARCHAR(200),
    work_type_id UUID,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT NOW()
);

-- 5b. LINE_ITEM_TEMPLATES — master list of billable items
CREATE TABLE IF NOT EXISTS line_item_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(200) NOT NULL,
    work_type_id UUID,
    scan_dimension_key VARCHAR(50),
    unit_type VARCHAR(20),
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT NOW()
);

-- 5c. SCAN_COMPONENT_TEMPLATES — maps detected labels to line item template bundles
CREATE TABLE IF NOT EXISTS scan_component_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    scan_component_label_id UUID REFERENCES scan_component_labels(id),
    line_item_template_id UUID REFERENCES line_item_templates(id),
    presence_required BOOLEAN DEFAULT false,
    created_at TIMESTAMP DEFAULT NOW()
);

-- 5d. APPLIANCE_LABELS — vocabulary of discrete detectable objects
CREATE TABLE IF NOT EXISTS appliance_labels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    label_key VARCHAR(100) UNIQUE NOT NULL,
    display_name VARCHAR(200),
    work_type_id UUID,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT NOW()
);

-- 5e. ROOM_APPLIANCES — positioned appliance instances per room
CREATE TABLE IF NOT EXISTS room_appliances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    scanned_room_id UUID REFERENCES scanned_rooms(id),
    appliance_label_id UUID REFERENCES appliance_labels(id),
    pos_x FLOAT,
    pos_y FLOAT,
    is_confirmed BOOLEAN DEFAULT false,
    created_at TIMESTAMP DEFAULT NOW()
);

-- ============================================================
-- Seed data — initial component label vocabulary for Phase 2 stub
-- ============================================================
INSERT INTO scan_component_labels (label_key, display_name) VALUES
    ('floor_hardwood', 'Hardwood Floor'),
    ('ceiling_drywall', 'Drywall Ceiling')
ON CONFLICT (label_key) DO NOTHING;

-- Test RFQ for smoke testing
INSERT INTO rfqs (id, status) VALUES ('00000000-0000-0000-0000-000000000001', 'scan_pending')
ON CONFLICT (id) DO NOTHING;
