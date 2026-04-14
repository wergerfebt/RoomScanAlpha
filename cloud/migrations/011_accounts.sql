-- Migration 011: Unified accounts table
-- Replaces the implicit Firebase UID references with a proper accounts model.
-- Both homeowners and contractors get accounts; type distinguishes them.

CREATE TABLE accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firebase_uid TEXT UNIQUE NOT NULL,
    email TEXT NOT NULL,
    name TEXT,
    phone TEXT,
    account_type VARCHAR(20) NOT NULL DEFAULT 'homeowner',
    icon_url TEXT,
    address TEXT,
    notification_preferences JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX idx_accounts_firebase_uid ON accounts(firebase_uid);
CREATE INDEX idx_accounts_email ON accounts(email);
