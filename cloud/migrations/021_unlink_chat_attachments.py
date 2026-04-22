"""Migration 021: Unlink chat-originated rfq / bid attachments.

The unified-attachment system originally auto-linked chat messages to
`rfq_attachments` (homeowner side) and `bid_attachments` (contractor side).
That design has been reversed — chat stays in chat, promotion is now an
explicit user action. This script removes the legacy auto-links so the new
model starts from a consistent state.

Leaves `attachments`, `message_attachments`, and GCS blobs intact; only the
scope-level join rows with a non-null `added_via_message_id` are deleted.
Idempotent.

Usage:
    DB_PASS=$(gcloud secrets versions access latest --secret=db-password \
              --project=roomscanalpha) \
    python3 cloud/migrations/021_unlink_chat_attachments.py
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

    cursor.execute("DELETE FROM rfq_attachments WHERE added_via_message_id IS NOT NULL")
    rfq_removed = cursor.rowcount
    cursor.execute(
        "DELETE FROM bid_attachments WHERE added_via_message_id IS NOT NULL AND role = 'image'"
    )
    bid_removed = cursor.rowcount

    conn.commit()
    cursor.close()
    conn.close()
    connector.close()

    print(f"rfq_attachments rows removed: {rfq_removed}")
    print(f"bid_attachments rows removed: {bid_removed}")
    print("(attachments table + message_attachments + GCS blobs untouched)")


if __name__ == "__main__":
    main()
