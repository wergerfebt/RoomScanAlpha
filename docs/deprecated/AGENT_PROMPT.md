> **DEPRECATED:** Parallel agent prompt for a platform expansion sprint. The multi-agent branch strategy and router refactoring were never fully executed. See `PLATFORM_ARCHITECTURE.md` for the current marketplace plan and `CLAUDE.md` for system architecture.

# Quoterra Platform Build — Parallel Agent Prompt

## Project Overview

You are building the Quoterra platform — a two-sided marketplace where homeowners post room renovation projects (with 3D scans from an iOS app) and contractors browse, bid, and get hired. The project is at `/Users/jakejulian/dev/RoomScanAlpha/`.

The existing codebase is an iOS scanning app + a FastAPI Cloud Run backend (`cloud/api/main.py`, ~715 lines) that handles scan uploads, processing, and a basic bid submission flow. You are extending this into a full marketplace with accounts, organizations, services taxonomy, geo-matching, notifications, and new web pages.

**Read these files before writing any code:**
- `/Users/jakejulian/dev/RoomScanAlpha/PLATFORM_ARCHITECTURE.md` — the full architecture spec (schemas, endpoints, flows, work order)
- `/Users/jakejulian/dev/RoomScanAlpha/CLAUDE.md` — project conventions, deploy commands, coordinate systems
- `/Users/jakejulian/dev/RoomScanAlpha/cloud/schema.sql` — current database schema
- `/Users/jakejulian/dev/RoomScanAlpha/cloud/api/main.py` — current API (all endpoints in one file)
- `/Users/jakejulian/dev/RoomScanAlpha/cloud/migrations/` — existing migrations 002-007

## What Already Exists

**Database tables (in schema.sql + migrations):**
- `properties`, `floors`, `rfqs`, `scanned_rooms` — core scan pipeline
- `scan_component_labels`, `line_item_templates`, `scan_component_templates`, `appliance_labels`, `room_appliances` — DNN taxonomy
- `contractors` — individual contractor profiles (auto-created on first bid, to be superseded)
- `rfq_invites` — unused, to be superseded by `rfq_contractor_matches`
- `bids` — minimal schema: `id`, `rfq_id`, `contractor_id`, `price_cents`, `description`, `pdf_url`, `received_at`. No `status`, no `org_id`, no unique constraint.

**Columns added by migrations 004-006 on rfqs:**
- `user_id` (Firebase UID string), `address`, `project_scope` (JSONB), `bid_view_token` (UUID)

**API endpoints in main.py (all working):**
- `GET/POST /api/rfqs` — list/create RFQs
- `GET /api/rfqs/{rfq_id}/scans/upload-url` — signed GCS URL
- `POST /api/rfqs/{rfq_id}/scans/complete` — enqueue Cloud Tasks job
- `GET /api/rfqs/{rfq_id}/scans/{scan_id}/status` — poll results
- `DELETE /api/rfqs/{rfq_id}/scans/{scan_id}` — soft-delete scan
- `DELETE /api/rfqs/{rfq_id}` — delete RFQ
- `GET /api/rfqs/{rfq_id}/contractor-view` — contractor data API
- `GET /api/contractors/me` — get/create contractor profile
- `POST /api/rfqs/{rfq_id}/bids` — submit bid (multipart/form-data)
- `GET /api/rfqs/{rfq_id}/bids` — list bids (token-gated, no Firebase auth)
- Page routes: `/quote/{rfq_id}`, `/bids/{rfq_id}`, favicon/og-image

**Existing web pages in cloud/api/web/:**
- `contractor_view.html` — Three.js 3D viewer + bid submission modal (1838 lines)
- `bids.html` — bid comparison cards with filtering/sorting (664 lines)
- `favicon.ico`, `og-image.png`, `apple-touch-icon.png`, `favicon-32x32.png`

**Shared infrastructure in main.py (lines 1-100):**
- Firebase Admin SDK init, GCS client, Cloud SQL connector, config vars
- `get_db_connection()`, `_row_to_dict()`, `verify_firebase_token()` helpers

## Architecture (from PLATFORM_ARCHITECTURE.md)

### New Database Tables to Create
```sql
-- accounts: unified user accounts
CREATE TABLE accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firebase_uid TEXT UNIQUE NOT NULL,
    email TEXT NOT NULL,
    name TEXT,
    phone TEXT,
    type VARCHAR(20) NOT NULL DEFAULT 'homeowner',
    icon_url TEXT,
    address TEXT,
    notification_preferences JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP
);

-- organizations: contractor organizations
CREATE TABLE organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    address TEXT,
    service_lat FLOAT,
    service_lng FLOAT,
    service_radius_miles FLOAT,
    max_travel_time_minutes INT,
    icon_url TEXT,
    website_url TEXT,
    yelp_url TEXT,
    google_reviews_url TEXT,
    avg_rating FLOAT,
    created_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP
);

-- org_members: links accounts to organizations
CREATE TABLE org_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID REFERENCES organizations(id),
    account_id UUID REFERENCES accounts(id),
    role VARCHAR(20) DEFAULT 'user',
    invited_email TEXT,
    invite_status VARCHAR(20) DEFAULT 'pending',
    invited_at TIMESTAMP DEFAULT NOW(),
    accepted_at TIMESTAMP,
    UNIQUE(org_id, account_id)
);

-- org_requests: contractor org approval requests
CREATE TABLE org_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID REFERENCES accounts(id),
    org_name TEXT NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',
    requested_at TIMESTAMP DEFAULT NOW(),
    resolved_at TIMESTAMP
);

-- org_work_images: portfolio gallery
CREATE TABLE org_work_images (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID REFERENCES organizations(id),
    image_type VARCHAR(20) DEFAULT 'single',
    image_url TEXT,
    before_image_url TEXT,
    caption TEXT,
    sort_order INT DEFAULT 0,
    created_at TIMESTAMP DEFAULT NOW()
);

-- services: platform service taxonomy
CREATE TABLE services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(200) NOT NULL,
    description TEXT,
    icon_url TEXT,
    search_aliases TEXT[],
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT NOW()
);

-- org_services: links organizations to services
CREATE TABLE org_services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID REFERENCES organizations(id),
    service_id UUID REFERENCES services(id),
    years_experience INT,
    UNIQUE(org_id, service_id)
);

-- rfq_contractor_matches: geo-matching results
CREATE TABLE rfq_contractor_matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rfq_id UUID REFERENCES rfqs(id),
    org_id UUID REFERENCES organizations(id),
    distance_miles FLOAT,
    travel_time_minutes INT,
    is_within_range BOOLEAN,
    match_status VARCHAR(20) DEFAULT 'notified',
    notified_at TIMESTAMP,
    viewed_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW()
);

-- ratings_reviews: one review per completed bid
CREATE TABLE ratings_reviews (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bid_id UUID REFERENCES bids(id),
    homeowner_account_id UUID REFERENCES accounts(id),
    org_id UUID REFERENCES organizations(id),
    rating FLOAT NOT NULL,
    review_text TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);
```

### Schema Changes to Existing Tables
```sql
-- rfqs: add columns
ALTER TABLE rfqs ADD COLUMN homeowner_account_id UUID REFERENCES accounts(id);
ALTER TABLE rfqs ADD COLUMN service_id UUID REFERENCES services(id);
ALTER TABLE rfqs ADD COLUMN hired_bid_id UUID REFERENCES bids(id);
ALTER TABLE rfqs ADD COLUMN before_images TEXT[];
ALTER TABLE rfqs ADD COLUMN listed_at TIMESTAMP;
ALTER TABLE rfqs ADD COLUMN completed_at TIMESTAMP;

-- bids: add columns for org-based model
ALTER TABLE bids ADD COLUMN org_id UUID REFERENCES organizations(id);
ALTER TABLE bids ADD COLUMN status VARCHAR(20) DEFAULT 'pending';
ALTER TABLE bids ADD COLUMN amount NUMERIC(12,2);
ALTER TABLE bids ADD COLUMN submitted_at TIMESTAMP;
ALTER TABLE bids ADD COLUMN deleted_at TIMESTAMP;
```

### Service Seed Data
Kitchen Remodel, Bathroom Remodel, Basement Finish, Flooring & Tile, Paint & Finish, Deck & Patio, Siding & Roof, Insulation & Drywall, Water Damage Restoration, Plumbing, Electrical, HVAC, Window & Door, General Renovation. Each has `search_aliases TEXT[]` with common variations (see PLATFORM_ARCHITECTURE.md for full INSERT statements).

---

## Three Agents Working in Parallel

There are 3 agents working concurrently on separate branches. To avoid merge conflicts, each agent owns exclusive files and must NOT modify files owned by other agents.

### Agent 1: Foundation (Backend Core)
**Branch name:** `platform/foundation`

**Responsibilities:**
1. **Refactor main.py into FastAPI routers** (CRITICAL — do this first, it enables the other agents to merge cleanly later):
   - Extract existing scan endpoints into `cloud/api/routers/scans.py`
   - Extract existing bid endpoints into `cloud/api/routers/bids.py`
   - Extract existing RFQ endpoints into `cloud/api/routers/rfqs.py`
   - Keep `main.py` as just: app init, config, shared helpers (`get_db_connection`, `verify_firebase_token`, `_row_to_dict`), router includes, static file routes
   - All existing behavior must be preserved exactly — same paths, same request/response shapes
2. **Fix scan processing gaps (CP-1):**
   - In `cloud/processor/main.py`: after updating a `scanned_rooms` row to `complete`, check if ALL rooms for that RFQ are now `complete`. If so, UPDATE `rfqs.status = 'scan_ready'`.
3. **Accounts system (CP-2):**
   - Migration `008_create_accounts.sql`: create `accounts` table
   - New router `cloud/api/routers/accounts.py`: `GET /api/account` (auto-creates on first call using Firebase UID), `PUT /api/account`
4. **Organizations system (CP-3):**
   - Migration `009_create_organizations.sql`: create `organizations`, `org_members`, `org_requests`, `org_work_images` tables
   - New router `cloud/api/routers/orgs.py`: full CRUD for org, members, gallery, request-org
   - `POST /api/account/request-org` (can live in accounts router)

**Files you OWN (only you modify these):**
- `cloud/api/main.py` (refactor into slim entrypoint)
- `cloud/api/routers/__init__.py` (new)
- `cloud/api/routers/scans.py` (new — extracted from main.py)
- `cloud/api/routers/rfqs.py` (new — extracted from main.py)
- `cloud/api/routers/bids.py` (new — extracted from main.py)
- `cloud/api/routers/accounts.py` (new)
- `cloud/api/routers/orgs.py` (new)
- `cloud/processor/main.py` (CP-1 fix)
- `cloud/migrations/008_create_accounts.sql` (new)
- `cloud/migrations/009_create_organizations.sql` (new)

**Do NOT touch:**
- Any files in `cloud/api/web/` (Agent 3 owns frontend)
- `cloud/api/services.py`, `cloud/api/geo.py`, `cloud/api/search.py`, `cloud/api/notifications.py` (Agent 2 owns these)
- `cloud/migrations/010+` (Agent 2 owns those migration numbers)

**Shared helpers that Agent 2 and Agent 3 will need to import from main.py:**
- `get_db_connection()`, `verify_firebase_token()`, `_row_to_dict()`
- Config vars: `PROJECT_ID`, `REGION`, `BUCKET_NAME`, `SIGNING_SA_EMAIL`, etc.
- Make sure these remain importable from a shared location after the refactor (e.g., `cloud/api/config.py` or keep in `main.py`)

---

### Agent 2: Services, Geo-Matching, Notifications (Backend Features)
**Branch name:** `platform/services-geo-notifications`

**Responsibilities:**
1. **Services taxonomy (HV-2):**
   - Migration `010_create_services.sql`: create `services` and `org_services` tables + seed data (14 service categories with search_aliases)
   - New module `cloud/api/services.py`: `GET /api/services` (public, list all active services), `GET/PUT /api/org/services` (org service selection)
   - Migration to add `service_id` column to `rfqs`
2. **Geo-matching (HV-3):**
   - Migration `011_create_rfq_contractor_matches.sql`: create `rfq_contractor_matches` table + add geo columns to organizations if not in 009
   - New module `cloud/api/geo.py`:
     - Geocoding helper: call Google Geocoding API to convert address -> lat/lng (used when org saves address)
     - Haversine distance function (pure SQL or Python)
     - `match_contractors_for_rfq(rfq_id)`: two-pass matching — haversine prefilter in SQL, then Google Maps Distance Matrix API for shortlist, write `rfq_contractor_matches` rows
3. **Notifications (HV-4):**
   - New module `cloud/api/notifications.py`:
     - `send_email(to, subject, html_body)` via SendGrid
     - `send_sms(to_phone, message)` via Twilio
     - `send_push(firebase_uid, title, body)` via FCM
     - Trigger functions: `notify_rfq_matched(rfq_id)`, `notify_new_bid(bid_id)`, `notify_bid_accepted(bid_id)`, `notify_bid_rejected(bid_id)`, `notify_org_invite(invite_id)`
     - Check `accounts.notification_preferences` before sending
   - Add `sendgrid` and `twilio` to `cloud/api/requirements.txt`
4. **Contractor search (HV-7):**
   - New module `cloud/api/search.py`:
     - `GET /api/search?q=&service_id=&lat=&lng=&rating_min=` — search endpoint
     - LLM-assisted intent mapping: send unstructured query + services list to Claude Haiku, resolve to service IDs
     - Cache LLM responses (in-memory dict or simple DB table)
     - Keyword alias fallback: match against `services.search_aliases` with ILIKE
5. **Ratings & reviews (HV-8):**
   - Migration `012_create_ratings_reviews.sql`: create `ratings_reviews` table
   - Add review endpoints to services.py or a new reviews.py: `POST /api/reviews`, `GET /api/org/{org_id}/reviews`
   - Atomic `avg_rating` update: `UPDATE organizations SET avg_rating = (SELECT AVG(rating) FROM ratings_reviews WHERE org_id = $1) WHERE id = $1` in the same transaction as the review INSERT

**Files you OWN (only you modify these):**
- `cloud/api/services.py` (new)
- `cloud/api/geo.py` (new)
- `cloud/api/notifications.py` (new)
- `cloud/api/search.py` (new)
- `cloud/migrations/010_create_services.sql` (new)
- `cloud/migrations/011_create_rfq_contractor_matches.sql` (new)
- `cloud/migrations/012_create_ratings_reviews.sql` (new)

**Do NOT touch:**
- `cloud/api/main.py` or any file in `cloud/api/routers/` (Agent 1 owns the API entrypoint and routers)
- Any files in `cloud/api/web/` (Agent 3 owns frontend)
- `cloud/processor/main.py` (Agent 1 owns this)
- `cloud/migrations/008-009` (Agent 1 owns those)

**Integration note:** Your modules will be imported and registered as routers by Agent 1's refactored `main.py` during merge. Write your endpoints as FastAPI `APIRouter` instances so they can be included with `app.include_router()`. For database access, import `get_db_connection` and `verify_firebase_token` from wherever Agent 1 puts them (likely `cloud/api/config.py` or `cloud/api/main.py`). For now, write your imports assuming:
```python
from cloud.api.config import get_db_connection, verify_firebase_token, _row_to_dict
# OR if Agent 1 keeps them in main:
# from cloud.api.main import get_db_connection, verify_firebase_token, _row_to_dict
```
Use a simple fallback import pattern so it works either way:
```python
try:
    from .config import get_db_connection, verify_firebase_token, _row_to_dict
except ImportError:
    from .main import get_db_connection, verify_firebase_token, _row_to_dict
```

**For SendGrid/Twilio/Anthropic API keys:** Read from environment variables. Do NOT hardcode. Use:
- `SENDGRID_API_KEY`
- `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`
- `ANTHROPIC_API_KEY` (for Haiku search)

---

### Agent 3: Frontend (All New Web Pages)
**Branch name:** `platform/frontend`

**Responsibilities:**
Build all new web pages as self-contained HTML files with vanilla JS + Firebase Auth JS SDK. Match the style and patterns of the existing `contractor_view.html` and `bids.html`.

1. **Login page** — `cloud/api/web/login.html`:
   - Firebase Auth JS: email/password sign-in, Google sign-in, Apple sign-in
   - Create account flow (sign-up is on the same page or a tab)
   - On success, redirect to `/projects` (homeowner) or `/org` (contractor)
   - Store Firebase JWT for API calls

2. **Account page** — `cloud/api/web/account.html`:
   - Load account: `GET /api/account` (with Firebase JWT)
   - Edit form: name, email, phone, icon_url, address, notification preferences (email/sms/push toggles)
   - Save: `PUT /api/account`
   - "Request Contractor Organization" button: `POST /api/account/request-org` (shows form for org name)
   - If user is a contractor, show link to `/org`

3. **Projects page** — `cloud/api/web/projects.html`:
   - List homeowner's RFQs: `GET /api/rfqs` (with Firebase JWT)
   - Each card shows: project description, service type, status badge (scan_pending/scan_ready/listed/completed), room count, date
   - Click -> `/projects/{rfqId}` (or link to existing `/bids/{rfqId}` for now)
   - "New Project" button (future: RFQ creation flow)

4. **Org dashboard** — `cloud/api/web/org.html`:
   - Tabbed layout or sidebar: Dashboard / Settings / Members / Gallery / Active Bids / Won Jobs
   - **Dashboard tab**: org name, avg rating, member count, active bid count, won job count
   - **Settings tab** (`/org/settings` or tab within org.html):
     - Edit: org name, description, address, website, yelp, google reviews URLs
     - Service selection: checkboxes for all services from `GET /api/services`, save via `PUT /api/org/services`
   - **Members tab** (`/org/members` or tab):
     - List members with role badges (admin/user)
     - Invite form: email input -> `POST /api/org/members/invite` (admin only)
     - Remove button -> `DELETE /api/org/members/{id}` (admin only)
   - **Gallery tab** (`/org/gallery` or tab):
     - Grid of portfolio images from `GET /api/org/gallery`
     - Upload: image file + optional before image + caption -> `POST /api/org/gallery`
     - Delete button on each image (admin only)
   - **Active Bids tab**: list from `GET /api/org/active-bids` — shows RFQ description, bid amount, status, date
   - **Won Jobs tab**: list from `GET /api/org/won-jobs` — shows completed jobs

5. **Search page** — `cloud/api/web/search.html`:
   - Search bar at top: free text input
   - Service category filter: buttons/chips from `GET /api/services`
   - Results: contractor org cards showing name, icon, avg_rating, services, description
   - On search: `GET /api/search?q={query}` or `GET /api/search?service_id={id}`
   - Each card links to org profile (future) or shows expanded detail

6. **Landing page** — `cloud/api/web/index.html`:
   - Hero section: "Compare and Save on Home Renovations" + search bar
   - Below hero: service category cards (icons + names from `/api/services`)
   - Below that: featured contractors or "How it works" section
   - Search bar and categories link to `/search` with appropriate query params

7. **Shared navigation bar** (duplicated in each page, or as a JS include):
   - Left: Quoterra logo (links to `/`)
   - Center: Search bar (links to `/search`)
   - Right: User icon dropdown
     - If signed in: Account, My Projects (homeowner) or Org Dashboard (contractor), Sign Out
     - If not signed in: Sign In, Sign Up

**Files you OWN (only you modify these):**
- `cloud/api/web/login.html` (new)
- `cloud/api/web/account.html` (new)
- `cloud/api/web/projects.html` (new)
- `cloud/api/web/org.html` (new)
- `cloud/api/web/search.html` (new)
- `cloud/api/web/index.html` (new)
- `cloud/api/web/shared.css` (new — optional shared styles)
- `cloud/api/web/shared.js` (new — optional shared nav bar, auth helpers)

**Do NOT touch:**
- `cloud/api/web/contractor_view.html` (existing, Agent 1 may update during bid migration)
- `cloud/api/web/bids.html` (existing, Agent 1 may update during bid migration)
- `cloud/api/main.py` or any Python files (Agent 1 and 2 own backend)
- Any migration files (Agent 1 and 2 own schema)

**Build against the API contract.** The endpoints may not exist yet when you're writing the frontend. That's fine — build the fetch calls, error handling, and loading states as if the API is ready. Use the endpoint specs from the architecture doc. When the backend agents merge, the pages will connect.

**For Firebase Auth JS**, use these CDN imports (same as existing pages):
```html
<script src="https://www.gstatic.com/firebasejs/10.7.1/firebase-app-compat.js"></script>
<script src="https://www.gstatic.com/firebasejs/10.7.1/firebase-auth-compat.js"></script>
```
Firebase config is already in `contractor_view.html` — use the same config values.

**Style guidance:** Look at `contractor_view.html` and `bids.html` for the existing visual style (colors, fonts, card layouts, button styles). Match that aesthetic. The existing pages use inline `<style>` blocks — follow the same pattern unless you create a `shared.css`.

---

## General Rules for All Agents

1. **Create a new git branch** for your work using the branch name specified above.
2. **Do NOT modify files owned by other agents.** If you need a function from another agent's file, write your code assuming the import and add a `# TODO: import from Agent X's module after merge` comment.
3. **Write migrations as numbered SQL files** in `cloud/migrations/` using the numbers assigned to your agent.
4. **All new tables must have `created_at TIMESTAMP DEFAULT NOW()`.**
5. **Use UUID primary keys** (`gen_random_uuid()`) for all new tables.
6. **Firebase Auth JWT validation** is required on all non-public endpoints. Use `verify_firebase_token()`.
7. **Database connections**: use `get_db_connection()` — it returns a `pg8000.Connection` via Cloud SQL Connector. Use parameterized queries (never string interpolation).
8. **GCS uploads** use signed URLs (same pattern as scan uploads). Never stream large files through the API.
9. **Do not add features beyond your scope.** If you notice something another agent should handle, add a `# TODO: Agent X should...` comment and move on.
10. **Test your work.** Write at least one basic test or verification script for each major feature.
11. **Commit frequently** with clear messages describing what was added/changed.

---

(You are Agent 2)
