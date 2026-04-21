"""Migration 020 runner — applies DDL and backfills legacy attachment data.

Single entry point for the unified-attachments migration. Runs the SQL DDL in
`020_unified_attachments.sql`, then invokes the backfill from `020_backfill.py`.
Safe to re-run — DDL uses IF NOT EXISTS equivalents via CREATE TABLE (will
fail on the second run; that's a feature — it signals the DDL has already
been applied. The backfill is idempotent.)

Usage:
    DB_PASS=$(gcloud secrets versions access latest --secret=db-password \
              --project=roomscanalpha) \
    python3 cloud/migrations/020_apply.py
"""

import os
import sys
from pathlib import Path

from google.cloud.sql.connector import Connector

# Import the backfill module so we reuse its logic
sys.path.insert(0, str(Path(__file__).parent))
import importlib.util
_spec = importlib.util.spec_from_file_location(
    "backfill020", Path(__file__).parent / "020_backfill.py"
)
_backfill = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_backfill)


CLOUD_SQL_CONNECTION = os.environ.get("CLOUD_SQL_CONNECTION", "roomscanalpha:us-central1:roomscanalpha-db")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASS = os.environ.get("DB_PASS", "")
DB_NAME = os.environ.get("DB_NAME", "quoterra")

DDL_FILE = Path(__file__).parent / "020_unified_attachments.sql"


def main():
    if not DB_PASS:
        print("ERROR: DB_PASS env var is required.", file=sys.stderr)
        sys.exit(1)

    ddl = DDL_FILE.read_text()

    connector = Connector()
    conn = connector.connect(
        CLOUD_SQL_CONNECTION, "pg8000",
        user=DB_USER, password=DB_PASS, db=DB_NAME,
    )
    cursor = conn.cursor()

    print("Step 0: Applying DDL from 020_unified_attachments.sql…")
    # Check whether the migration has already been applied by looking for the
    # attachments table. Skip DDL if it exists so the script is re-runnable.
    cursor.execute(
        """SELECT to_regclass('public.attachments') IS NOT NULL AS exists_"""
    )
    already = cursor.fetchone()[0]
    if already:
        print("  attachments table already exists — skipping DDL")
    else:
        # Strip SQL comments to avoid confusing the driver; execute as one script.
        cursor.execute(ddl)
        print("  DDL applied")

    # Run the backfill on the same connection
    print()
    print("Step 1: Backfilling bids.pdf_url → attachments + bid_attachments…")
    created, skipped, unparseable = _backfill.backfill_bid_pdfs(cursor)
    print(f"  created={created}  skipped_existing={skipped}  unparseable={unparseable}")

    print()
    print("Step 2: Backfilling messages.attachments JSONB → attachments + message_attachments…")
    links_created, links_skipped = _backfill.backfill_message_attachments(cursor)
    print(f"  created={links_created}  skipped_existing={links_skipped}")

    conn.commit()
    cursor.close()
    conn.close()
    connector.close()

    print()
    print("Migration 020 complete. Legacy columns (bids.pdf_url, messages.attachments)")
    print("remain in place for dual-read safety — migration 021 will drop them.")


if __name__ == "__main__":
    main()
