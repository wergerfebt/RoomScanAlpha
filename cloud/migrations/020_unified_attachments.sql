-- Migration 020: Unified attachments + scoped join tables
--
-- ADDITIVE ONLY. This migration creates the new tables and leaves legacy
-- columns (bids.pdf_url, messages.attachments JSONB) in place for safety.
-- Scan-api dual-writes both old and new shapes during the rollout window.
-- Migration 021 will drop the legacy columns once the API has been stable
-- in production for 24–48 hours.
--
-- Run order:
--   1. psql -f 020_unified_attachments.sql      (this file)
--   2. DB_PASS=... python3 020_backfill.py      (backfill legacy data)
--   3. Deploy scan-api with the unified-attachment code path

-- One row per uploaded blob. Identity independent of where it's attached.
CREATE TABLE attachments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    blob_path TEXT NOT NULL UNIQUE,
    content_type TEXT NOT NULL,
    name TEXT,
    size_bytes BIGINT,
    uploader_account_id UUID REFERENCES accounts(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_attachments_uploader ON attachments(uploader_account_id);

-- Homeowner-scoped attachments on an RFQ (reference photos, docs, etc.)
CREATE TABLE rfq_attachments (
    rfq_id UUID NOT NULL REFERENCES rfqs(id),
    attachment_id UUID NOT NULL REFERENCES attachments(id),
    added_via_message_id UUID REFERENCES messages(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (rfq_id, attachment_id)
);

CREATE INDEX idx_rfq_attachments_rfq ON rfq_attachments(rfq_id);

-- Contractor-scoped attachments on a bid (quote PDF + optional images)
CREATE TABLE bid_attachments (
    bid_id UUID NOT NULL REFERENCES bids(id),
    attachment_id UUID NOT NULL REFERENCES attachments(id),
    role VARCHAR(20) NOT NULL DEFAULT 'image',
    added_via_message_id UUID REFERENCES messages(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (bid_id, attachment_id)
);

CREATE INDEX idx_bid_attachments_bid ON bid_attachments(bid_id);
CREATE INDEX idx_bid_attachments_role ON bid_attachments(bid_id, role);

-- Message-scoped associations (replaces messages.attachments JSONB)
CREATE TABLE message_attachments (
    message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    attachment_id UUID NOT NULL REFERENCES attachments(id),
    PRIMARY KEY (message_id, attachment_id)
);

CREATE INDEX idx_message_attachments_message ON message_attachments(message_id);
