"""Seed 10 fake contractor bids for a given RFQ.

Usage:
    python seed_bids.py

Requires gcloud ADC (Application Default Credentials) to connect to Cloud SQL.
"""

import os
import uuid
import random
from google.cloud.sql.connector import Connector

RFQ_ID = "8e796478-0fe8-4bbf-8c4c-bb8896f21d6d"
GCS_BUCKET = "roomscanalpha-scans"
PDF_BLOB = "bids/seed/sample-quote.pdf"
SIGNING_SA_EMAIL = "scan-api-sa@roomscanalpha.iam.gserviceaccount.com"

CLOUD_SQL_CONNECTION = os.environ.get("CLOUD_SQL_CONNECTION", "roomscanalpha:us-central1:roomscanalpha-db")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASS = os.environ.get("DB_PASS", "")
DB_NAME = os.environ.get("DB_NAME", "quoterra")

CONTRACTORS = [
    {"name": "Windy City Remodeling", "email": "bids@windycityremodel.com", "rating": 4.9, "reviews": 187, "yelp": "https://yelp.com/biz/windy-city-remodeling", "google": "https://g.co/windycity"},
    {"name": "Lakeview Builders", "email": "info@lakeviewbuilders.com", "rating": 4.7, "reviews": 142, "yelp": "https://yelp.com/biz/lakeview-builders", "google": "https://g.co/lakeview"},
    {"name": "Prairie State Construction", "email": "quotes@prairiestateco.com", "rating": 4.5, "reviews": 98, "yelp": None, "google": "https://g.co/prairiestate"},
    {"name": "O'Brien & Sons Contracting", "email": "contact@obrienandsons.com", "rating": 4.8, "reviews": 203, "yelp": "https://yelp.com/biz/obrien-sons", "google": "https://g.co/obrien"},
    {"name": "Northshore Home Pros", "email": "bids@northshorehomepros.com", "rating": 4.3, "reviews": 67, "yelp": "https://yelp.com/biz/northshore-home-pros", "google": None},
    {"name": "Loop Renovations LLC", "email": "hello@looprenovations.com", "rating": 4.6, "reviews": 112, "yelp": None, "google": "https://g.co/loopreno"},
    {"name": "MidWest Quality Build", "email": "info@mwqualitybuild.com", "rating": 3.9, "reviews": 41, "yelp": None, "google": "https://g.co/mwquality"},
    {"name": "Blue Island Contractors", "email": "bids@blueislandgc.com", "rating": 4.4, "reviews": 89, "yelp": "https://yelp.com/biz/blue-island-gc", "google": "https://g.co/blueisland"},
    {"name": "Cornerstone Interiors", "email": "quotes@cornerstonechi.com", "rating": 4.7, "reviews": 156, "yelp": "https://yelp.com/biz/cornerstone-interiors", "google": "https://g.co/cornerstone"},
    {"name": "Southside Renovation Co", "email": "info@southsidereno.com", "rating": 4.1, "reviews": 53, "yelp": None, "google": "https://g.co/southside"},
]

DESCRIPTIONS = [
    "Full kitchen gut and remodel. Custom shaker cabinets, quartz countertops, subway tile backsplash, new LVP flooring throughout. Includes all demo, electrical, and plumbing.",
    "Complete renovation with semi-custom cabinetry, granite countertops, tile backsplash, and new lighting fixtures. Appliance installation included.",
    "Premium remodel — soft-close custom cabinets, waterfall quartz island, under-cabinet LED lighting, new plumbing fixtures, and flooring.",
    "Budget-friendly refresh: cabinet refacing, new hardware, laminate countertops, and fresh paint. Ideal for a quick turnaround.",
    "Mid-range kitchen remodel with stock cabinets, butcher block counters, open shelving feature wall, and updated lighting.",
    "High-end renovation including custom walnut cabinets, marble countertops, professional-grade appliance hookups, and radiant floor heating.",
    "Standard remodel package: new cabinets, quartz counters, ceramic tile backsplash, and updated electrical to code.",
    "Modern farmhouse style remodel with two-tone cabinets, farmhouse sink, butcher block island, and shiplap accent wall.",
    "Complete demo and rebuild. Commercial-grade ventilation, stainless steel countertops, concrete floors. Restaurant-style kitchen.",
    "Eco-friendly remodel using reclaimed wood cabinets, recycled glass countertops, low-VOC finishes, and energy-efficient lighting.",
]

# Price range: $8,500 to $28,000
PRICES_CENTS = [850000, 1120000, 1350000, 1580000, 1690000, 1890000, 2150000, 2380000, 2560000, 2800000]


def main():
    connector = Connector()
    conn = connector.connect(
        CLOUD_SQL_CONNECTION, "pg8000",
        user=DB_USER, password=DB_PASS, db=DB_NAME,
    )
    cursor = conn.cursor()

    # Use public GCS URL — signed URLs require Cloud Run IAM permissions
    pdf_url = f"https://storage.googleapis.com/{GCS_BUCKET}/{PDF_BLOB}"
    print(f"PDF URL: {pdf_url}")

    # Shuffle prices for variety
    prices = PRICES_CENTS[:]
    random.shuffle(prices)

    print(f"\nSeeding {len(CONTRACTORS)} contractors and bids for RFQ {RFQ_ID}...\n")

    for i, c in enumerate(CONTRACTORS):
        fake_uid = f"seed_{uuid.uuid4().hex[:12]}"

        # Insert contractor (ON CONFLICT skip if email exists)
        cursor.execute(
            """INSERT INTO contractors (firebase_uid, email, name, yelp_url, google_reviews_url, review_rating, review_count)
               VALUES (%s, %s, %s, %s, %s, %s, %s)
               ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name
               RETURNING id""",
            (fake_uid, c["email"], c["name"], c["yelp"], c["google"], c["rating"], c["reviews"]),
        )
        contractor_id = cursor.fetchone()[0]

        # Give some bids a PDF, some not
        bid_pdf = pdf_url if i < 7 else None

        cursor.execute(
            """INSERT INTO bids (rfq_id, contractor_id, price_cents, description, pdf_url)
               VALUES (%s, %s, %s, %s, %s)
               RETURNING id""",
            (RFQ_ID, contractor_id, prices[i], DESCRIPTIONS[i], bid_pdf),
        )
        bid_id = cursor.fetchone()[0]
        print(f"  [{i+1}] {c['name']:30s}  ${prices[i]/100:>10,.0f}  bid={bid_id}")

    conn.commit()
    conn.close()
    connector.close()
    print("\nDone! Refresh your projects page to see the bids.")


if __name__ == "__main__":
    main()
