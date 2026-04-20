-- Migration 019: Inbox / chat messaging
-- Threads between a homeowner and a contractor org, scoped to an RFQ.
-- Messages are text (user-authored), events (system-generated lifecycle markers),
-- or bid cards (rich embed of a submitted bid).

CREATE TABLE conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rfq_id UUID NOT NULL REFERENCES rfqs(id),
    homeowner_account_id UUID NOT NULL REFERENCES accounts(id),
    org_id UUID NOT NULL REFERENCES organizations(id),
    last_message_at TIMESTAMPTZ,
    last_message_preview TEXT,
    last_message_side VARCHAR(16),
    homeowner_unread_count INT NOT NULL DEFAULT 0,
    org_unread_count INT NOT NULL DEFAULT 0,
    homeowner_last_read_at TIMESTAMPTZ,
    org_last_read_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(rfq_id, homeowner_account_id, org_id)
);

CREATE INDEX idx_conversations_homeowner ON conversations(homeowner_account_id, last_message_at DESC NULLS LAST);
CREATE INDEX idx_conversations_org ON conversations(org_id, last_message_at DESC NULLS LAST);
CREATE INDEX idx_conversations_rfq ON conversations(rfq_id);

CREATE TABLE messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    sender_account_id UUID REFERENCES accounts(id),
    side VARCHAR(16) NOT NULL,
    kind VARCHAR(16) NOT NULL,
    body TEXT,
    event_type VARCHAR(32),
    bid_id UUID REFERENCES bids(id),
    bid_snapshot JSONB,
    attachments JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_messages_conversation ON messages(conversation_id, created_at);
