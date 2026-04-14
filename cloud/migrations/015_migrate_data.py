"""Migration 015: Migrate existing contractors → accounts + organizations + org_members.

Also backfills bids.org_id and rfqs.homeowner_account_id.

Usage:
    DB_PASS="..." python3 015_migrate_data.py
"""

import os
from google.cloud.sql.connector import Connector

CLOUD_SQL_CONNECTION = os.environ.get("CLOUD_SQL_CONNECTION", "roomscanalpha:us-central1:roomscanalpha-db")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASS = os.environ.get("DB_PASS", "")
DB_NAME = os.environ.get("DB_NAME", "quoterra")


def main():
    connector = Connector()
    conn = connector.connect(
        CLOUD_SQL_CONNECTION, "pg8000",
        user=DB_USER, password=DB_PASS, db=DB_NAME,
    )
    cursor = conn.cursor()

    # --- Step 1: Migrate contractors → accounts + organizations + org_members ---
    print("Step 1: Migrating contractors to accounts + organizations...")

    cursor.execute("""
        SELECT id, firebase_uid, email, name, icon_url, yelp_url,
               google_reviews_url, review_rating
        FROM contractors
    """)
    contractors = cursor.fetchall()
    print(f"  Found {len(contractors)} contractors")

    contractor_to_org = {}  # contractor.id → org.id

    for c_id, firebase_uid, email, name, icon_url, yelp, google, rating in contractors:
        # Create or get account
        cursor.execute("""
            INSERT INTO accounts (firebase_uid, email, name, type, icon_url)
            VALUES (%s, %s, %s, 'contractor', %s)
            ON CONFLICT (firebase_uid) DO UPDATE SET name = EXCLUDED.name
            RETURNING id
        """, (firebase_uid, email, name, icon_url))
        account_id = cursor.fetchone()[0]

        # Create organization
        org_name = name or email.split("@")[0]
        cursor.execute("""
            INSERT INTO organizations (name, icon_url, yelp_url, google_reviews_url, avg_rating)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING id
        """, (org_name, icon_url, yelp, google, float(rating) if rating else None))
        org_id = cursor.fetchone()[0]

        # Link account to org as admin
        cursor.execute("""
            INSERT INTO org_members (org_id, account_id, role, invite_status)
            VALUES (%s, %s, 'admin', 'accepted')
            ON CONFLICT (org_id, account_id) DO NOTHING
        """, (org_id, account_id))

        contractor_to_org[str(c_id)] = str(org_id)
        print(f"  {name or email}: account={account_id}, org={org_id}")

    # --- Step 2: Backfill bids.org_id ---
    print("\nStep 2: Backfilling bids.org_id...")

    cursor.execute("SELECT id, contractor_id FROM bids WHERE org_id IS NULL")
    bids = cursor.fetchall()
    updated = 0
    for bid_id, contractor_id in bids:
        org_id = contractor_to_org.get(str(contractor_id))
        if org_id:
            cursor.execute("UPDATE bids SET org_id = %s WHERE id = %s", (org_id, bid_id))
            updated += 1
    print(f"  Updated {updated}/{len(bids)} bids")

    # --- Step 3: Backfill rfqs.homeowner_account_id ---
    print("\nStep 3: Backfilling rfqs.homeowner_account_id...")

    cursor.execute("SELECT id, user_id FROM rfqs WHERE user_id IS NOT NULL AND homeowner_account_id IS NULL")
    rfqs = cursor.fetchall()
    updated = 0
    for rfq_id, firebase_uid in rfqs:
        # Find or create homeowner account
        cursor.execute("""
            INSERT INTO accounts (firebase_uid, email, name, type)
            VALUES (%s, %s || '@unknown', NULL, 'homeowner')
            ON CONFLICT (firebase_uid) DO UPDATE SET firebase_uid = EXCLUDED.firebase_uid
            RETURNING id
        """, (firebase_uid, firebase_uid))
        account_id = cursor.fetchone()[0]
        cursor.execute("UPDATE rfqs SET homeowner_account_id = %s WHERE id = %s", (account_id, rfq_id))
        updated += 1
    print(f"  Updated {updated}/{len(rfqs)} RFQs")

    conn.commit()
    conn.close()
    connector.close()
    print("\nMigration complete!")


if __name__ == "__main__":
    main()
