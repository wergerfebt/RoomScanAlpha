-- Migration 016: Add invite_token to org_members for deep-link invite acceptance
ALTER TABLE org_members ADD COLUMN IF NOT EXISTS invite_token UUID DEFAULT gen_random_uuid();
