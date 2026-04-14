-- Migration 013: Portfolio gallery, service taxonomy, and org-service links

CREATE TABLE org_work_images (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organizations(id),
    image_type VARCHAR(20) NOT NULL DEFAULT 'single',
    image_url TEXT,
    before_image_url TEXT,
    caption TEXT,
    sort_order INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_org_work_images_org ON org_work_images(org_id);

CREATE TABLE services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(200) NOT NULL,
    description TEXT,
    icon_url TEXT,
    search_aliases TEXT[],
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT now()
);

INSERT INTO services (name, search_aliases) VALUES
    ('Kitchen Remodel', '{"kitchen renovation", "new kitchen", "kitchen cabinets", "kitchen countertops"}'),
    ('Bathroom Remodel', '{"bathroom renovation", "new bathroom", "vanity", "shower remodel", "tub replacement"}'),
    ('Basement Finish', '{"basement renovation", "basement refinish", "finish basement", "basement remodel"}'),
    ('Flooring & Tile', '{"new floors", "hardwood", "LVP", "tile install", "carpet replacement", "laminate"}'),
    ('Paint & Finish', '{"interior paint", "exterior paint", "painting", "staining", "wall paint"}'),
    ('Deck & Patio', '{"new deck", "patio", "outdoor living", "deck repair", "deck build"}'),
    ('Siding & Roof', '{"new roof", "roof repair", "siding", "gutters", "exterior"}'),
    ('Insulation & Drywall', '{"drywall repair", "insulation", "drywall install", "wall repair"}'),
    ('Water Damage Restoration', '{"flood damage", "water damage", "mold", "moisture", "leak repair"}'),
    ('Plumbing', '{"pipes", "plumber", "drain", "water heater", "faucet", "toilet"}'),
    ('Electrical', '{"electrician", "wiring", "outlets", "panel", "lighting", "breaker"}'),
    ('HVAC', '{"heating", "cooling", "air conditioning", "furnace", "AC", "ductwork"}'),
    ('Window & Door', '{"window replacement", "new doors", "door install", "window install", "storm door"}'),
    ('General Renovation', '{"home renovation", "remodel", "home improvement", "general contractor"}');

CREATE TABLE org_services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organizations(id),
    service_id UUID NOT NULL REFERENCES services(id),
    years_experience INT,
    UNIQUE(org_id, service_id)
);
