"""Retroactive association backfill for chat-sent attachments.

Migration 020_backfill populated `attachments` + `message_attachments` for
pre-existing messages, but couldn't reach back and populate `rfq_attachments`
/ `bid_attachments` because those links depend on the sender side (which
we do know) and which org has a bid on the RFQ (which we also know).

This script walks every chat-sent attachment and applies the auto-link rule
retroactively:
  - homeowner-sent → `rfq_attachments`
  - org-sent, org has a pending/accepted bid on the RFQ → `bid_attachments` (role='image')
  - org-sent, no bid → leave as message-only (same as new-message behavior)

Idempotent — uses ON CONFLICT DO NOTHING on all link inserts.

Usage:
    DB_PASS=$(gcloud secrets versions access latest --secret=db-password \
              --project=roomscanalpha) \
    python3 cloud/migrations/020_retrolink.py
"""

import os
import sys

from google.cloud.sql.connector import Connector


CLOUD_SQL_CONNECTION = os.environ.get("CLOUD_SQL_CONNECTION", "roomscanalpha:us-central1:roomscanalpha-db")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASS = os.environ.get("DB_PASS", "")
DB_NAME = os.environ.get("DB_NAME", "quoterra")


def main():
    if not DB_PASS:
        print("ERROR: DB_PASS env var is required.", file=sys.stderr)
        sys.exit(1)

    connector = Connector()
    conn = connector.connect(
        CLOUD_SQL_CONNECTION, "pg8000",
        user=DB_USER, password=DB_PASS, db=DB_NAME,
    )
    cursor = conn.cursor()

    # Walk every (message_id, attachment_id) pair and apply the auto-link rule.
    cursor.execute(
        """SELECT m.id, m.side, c.rfq_id, c.org_id, ma.attachment_id
           FROM messages m
           JOIN message_attachments ma ON ma.message_id = m.id
           JOIN conversations c ON c.id = m.conversation_id
           WHERE m.side IN ('homeowner', 'org')"""
    )
    rows = cursor.fetchall()

    rfq_linked = 0
    bid_linked = 0
    org_no_bid = 0

    for message_id, side, rfq_id, org_id, attachment_id in rows:
        if side == "homeowner":
            cursor.execute(
                """INSERT INTO rfq_attachments (rfq_id, attachment_id, added_via_message_id)
                   VALUES (%s, %s, %s)
                   ON CONFLICT (rfq_id, attachment_id) DO NOTHING""",
                (rfq_id, attachment_id, message_id),
            )
            if cursor.rowcount:
                rfq_linked += 1
        elif side == "org":
            cursor.execute(
                """SELECT id FROM bids
                   WHERE rfq_id = %s AND org_id = %s AND status IN ('pending', 'accepted')
                   ORDER BY received_at DESC LIMIT 1""",
                (rfq_id, org_id),
            )
            bid_row = cursor.fetchone()
            if not bid_row:
                org_no_bid += 1
                continue
            cursor.execute(
                """INSERT INTO bid_attachments (bid_id, attachment_id, role, added_via_message_id)
                   VALUES (%s, %s, 'image', %s)
                   ON CONFLICT (bid_id, attachment_id) DO NOTHING""",
                (str(bid_row[0]), attachment_id, message_id),
            )
            if cursor.rowcount:
                bid_linked += 1

    conn.commit()
    cursor.close()
    conn.close()
    connector.close()

    print(f"rfq_attachments linked: {rfq_linked}")
    print(f"bid_attachments linked: {bid_linked}")
    print(f"org-side messages whose org had no bid (skipped): {org_no_bid}")


if __name__ == "__main__":
    main()
