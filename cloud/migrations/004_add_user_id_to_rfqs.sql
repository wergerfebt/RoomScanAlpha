-- Add user_id to rfqs so projects are scoped per user.
-- Existing rows get NULL user_id (visible to all users for backward compat).
ALTER TABLE rfqs ADD COLUMN IF NOT EXISTS user_id TEXT;
CREATE INDEX IF NOT EXISTS idx_rfqs_user_id ON rfqs(user_id);
