CREATE TABLE contractors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firebase_uid TEXT UNIQUE,
    email TEXT UNIQUE NOT NULL,
    name TEXT,
    icon_url TEXT,
    yelp_url TEXT,
    google_reviews_url TEXT,
    review_rating NUMERIC(2,1),
    review_count INTEGER,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE rfq_invites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rfq_id UUID NOT NULL REFERENCES rfqs(id),
    contractor_id UUID NOT NULL REFERENCES contractors(id),
    sent_at TIMESTAMPTZ DEFAULT now(),
    viewed_at TIMESTAMPTZ,
    UNIQUE(rfq_id, contractor_id)
);

CREATE TABLE bids (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rfq_id UUID NOT NULL REFERENCES rfqs(id),
    contractor_id UUID NOT NULL REFERENCES contractors(id),
    price_cents INTEGER NOT NULL,
    description TEXT,
    pdf_url TEXT,
    received_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE rfqs ADD COLUMN bid_view_token UUID DEFAULT gen_random_uuid();
