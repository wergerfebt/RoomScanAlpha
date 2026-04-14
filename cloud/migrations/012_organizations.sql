-- Migration 012: Organizations, members, and org creation requests
-- Contractors belong to organizations. One contractor can be in one org.
-- Orgs have their own profile (icon, address, review links) separate from
-- individual accounts.

CREATE TABLE organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    address TEXT,
    service_lat FLOAT,
    service_lng FLOAT,
    service_radius_miles FLOAT,
    icon_url TEXT,
    website_url TEXT,
    yelp_url TEXT,
    google_reviews_url TEXT,
    avg_rating FLOAT,
    created_at TIMESTAMPTZ DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE TABLE org_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID NOT NULL REFERENCES organizations(id),
    account_id UUID NOT NULL REFERENCES accounts(id),
    role VARCHAR(20) NOT NULL DEFAULT 'user',
    invited_email TEXT,
    invite_status VARCHAR(20) NOT NULL DEFAULT 'accepted',
    invited_at TIMESTAMPTZ DEFAULT now(),
    accepted_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(org_id, account_id)
);

CREATE TABLE org_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id),
    org_name TEXT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    requested_at TIMESTAMPTZ DEFAULT now(),
    resolved_at TIMESTAMPTZ
);

CREATE INDEX idx_org_members_account ON org_members(account_id);
CREATE INDEX idx_org_members_org ON org_members(org_id);
