"""Migration 020: Backfill legacy attachments into unified schema.

Populates the new `attachments` + `bid_attachments` + `message_attachments`
tables from existing `bids.pdf_url` and `messages.attachments` JSONB data.
Idempotent — skips rows that already have the corresponding entries.

Run AFTER applying 020_unified_attachments.sql. The legacy columns are NOT
dropped here; migration 021 handles that once the unified API has been stable
in production.

Usage:
    DB_PASS="..." python3 020_backfill.py

Notes on bids.pdf_url:
  The legacy column stores a pre-signed GCS URL (not a bare blob_path). We
  reconstruct the blob_path from the known layout `bids/{rfq_id}/{bid_id}.pdf`
  set by submit_bid. Bids whose pdf_url doesn't match this layout are logged
  and skipped.
"""

import json
import os
import urllib.parse
import uuid

from google.cloud.sql.connector import Connector


CLOUD_SQL_CONNECTION = os.environ.get("CLOUD_SQL_CONNECTION", "roomscanalpha:us-central1:roomscanalpha-db")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASS = os.environ.get("DB_PASS", "")
DB_NAME = os.environ.get("DB_NAME", "quoterra")
BUCKET_NAME = os.environ.get("GCS_BUCKET", "roomscanalpha-scans")


def _extract_blob_path(pdf_url: str, rfq_id, bid_id) -> str | None:
    """Best-effort recovery of the blob_path from a legacy signed URL.

    submit_bid writes PDFs at `bids/{rfq_id}/{bid_id}.pdf`. Prefer reconstructing
    from IDs over parsing the URL — safer and immune to URL-encoding differences.
    """
    reconstructed = f"bids/{rfq_id}/{bid_id}.pdf"
    # Sanity-check the URL contains the bucket + path segment we expect
    if BUCKET_NAME in pdf_url and reconstructed.replace("/", "%2F") in pdf_url:
        return reconstructed
    if BUCKET_NAME in pdf_url and reconstructed in pdf_url:
        return reconstructed
    # Fallback: parse the URL path
    try:
        parsed = urllib.parse.urlparse(pdf_url)
        # https://storage.googleapis.com/{bucket}/{path}?... — path segment is /{bucket}/{blob_path}
        parts = urllib.parse.unquote(parsed.path).lstrip("/").split("/", 1)
        if len(parts) == 2 and parts[0] == BUCKET_NAME:
            return parts[1].split("?")[0]
    except Exception:
        pass
    return None


def backfill_bid_pdfs(cursor) -> tuple[int, int, int]:
    """Create attachments + bid_attachments rows for every bid with a non-null pdf_url."""
    cursor.execute(
        """SELECT b.id, b.rfq_id, b.pdf_url, b.contractor_id, c.firebase_uid
           FROM bids b
           LEFT JOIN contractors c ON c.id = b.contractor_id
           WHERE b.pdf_url IS NOT NULL"""
    )
    rows = cursor.fetchall()
    created, skipped_existing, skipped_unparseable = 0, 0, 0

    for bid_id, rfq_id, pdf_url, contractor_id, firebase_uid in rows:
        # Skip if a quote_pdf is already linked
        cursor.execute(
            "SELECT 1 FROM bid_attachments WHERE bid_id = %s AND role = 'quote_pdf' LIMIT 1",
            (bid_id,),
        )
        if cursor.fetchone():
            skipped_existing += 1
            continue

        blob_path = _extract_blob_path(pdf_url, rfq_id, bid_id)
        if not blob_path:
            print(f"  WARN: could not recover blob_path for bid {bid_id} — skipping")
            skipped_unparseable += 1
            continue

        uploader_account_id = None
        if firebase_uid:
            cursor.execute("SELECT id FROM accounts WHERE firebase_uid = %s", (firebase_uid,))
            acct = cursor.fetchone()
            uploader_account_id = acct[0] if acct else None

        # Upsert attachment by blob_path (unique)
        cursor.execute(
            """INSERT INTO attachments (blob_path, content_type, uploader_account_id)
               VALUES (%s, 'application/pdf', %s)
               ON CONFLICT (blob_path) DO UPDATE SET blob_path = EXCLUDED.blob_path
               RETURNING id""",
            (blob_path, uploader_account_id),
        )
        attachment_id = cursor.fetchone()[0]

        cursor.execute(
            """INSERT INTO bid_attachments (bid_id, attachment_id, role)
               VALUES (%s, %s, 'quote_pdf')
               ON CONFLICT (bid_id, attachment_id) DO NOTHING""",
            (bid_id, attachment_id),
        )
        created += 1

    return created, skipped_existing, skipped_unparseable


def backfill_message_attachments(cursor) -> tuple[int, int]:
    """Create attachments + message_attachments rows for existing JSONB attachment data."""
    cursor.execute(
        """SELECT m.id, m.attachments, m.sender_account_id
           FROM messages m
           WHERE m.attachments IS NOT NULL AND jsonb_array_length(m.attachments) > 0"""
    )
    rows = cursor.fetchall()
    created_links, skipped_existing = 0, 0

    for message_id, attachments_json, sender_account_id in rows:
        # attachments_json is already a list of dicts via pg8000's JSONB adapter
        atts = attachments_json if isinstance(attachments_json, list) else json.loads(attachments_json)
        for a in atts:
            if not isinstance(a, dict):
                continue
            blob_path = a.get("blob_path")
            if not blob_path:
                continue

            cursor.execute(
                """INSERT INTO attachments (blob_path, content_type, name, size_bytes, uploader_account_id)
                   VALUES (%s, %s, %s, %s, %s)
                   ON CONFLICT (blob_path) DO UPDATE SET blob_path = EXCLUDED.blob_path
                   RETURNING id""",
                (
                    blob_path,
                    a.get("content_type") or "application/octet-stream",
                    a.get("name"),
                    a.get("size_bytes"),
                    sender_account_id,
                ),
            )
            attachment_id = cursor.fetchone()[0]

            cursor.execute(
                "SELECT 1 FROM message_attachments WHERE message_id = %s AND attachment_id = %s",
                (message_id, attachment_id),
            )
            if cursor.fetchone():
                skipped_existing += 1
                continue

            cursor.execute(
                """INSERT INTO message_attachments (message_id, attachment_id)
                   VALUES (%s, %s)""",
                (message_id, attachment_id),
            )
            created_links += 1

    return created_links, skipped_existing


def main():
    connector = Connector()
    conn = connector.connect(
        CLOUD_SQL_CONNECTION, "pg8000",
        user=DB_USER, password=DB_PASS, db=DB_NAME,
    )
    cursor = conn.cursor()

    print("Step 1: Backfilling bids.pdf_url → attachments + bid_attachments...")
    created, skipped, unparseable = backfill_bid_pdfs(cursor)
    print(f"  created={created}  skipped_existing={skipped}  unparseable={unparseable}")

    print("\nStep 2: Backfilling messages.attachments JSONB → attachments + message_attachments...")
    links_created, links_skipped = backfill_message_attachments(cursor)
    print(f"  created={links_created}  skipped_existing={links_skipped}")

    conn.commit()
    print("\nDone. Legacy columns (bids.pdf_url, messages.attachments) left in place for dual-read safety.")


if __name__ == "__main__":
    main()
