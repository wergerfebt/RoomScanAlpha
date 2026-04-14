-- Migration 014: Add org_id to bids and account references to rfqs
-- These columns coexist with the old contractor_id/user_id columns during migration.

ALTER TABLE bids ADD COLUMN IF NOT EXISTS org_id UUID REFERENCES organizations(id);
ALTER TABLE bids ADD COLUMN IF NOT EXISTS status VARCHAR(20) DEFAULT 'pending';

ALTER TABLE rfqs ADD COLUMN IF NOT EXISTS homeowner_account_id UUID REFERENCES accounts(id);
ALTER TABLE rfqs ADD COLUMN IF NOT EXISTS service_id UUID REFERENCES services(id);
ALTER TABLE rfqs ADD COLUMN IF NOT EXISTS hired_bid_id UUID REFERENCES bids(id);
