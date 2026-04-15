# Quoterra Platform Architecture Plan

## Context

Quoterra is expanding from an alpha iOS scanning app + simple web viewer into a full two-sided marketplace: homeowners post room renovation projects (with 3D scans), contractors browse and bid, homeowners compare bids and hire. This plan covers the web platform, accounts system, contractor organizations, notifications, search, and geo-matching — building on the existing FastAPI backend, Firebase Auth, Cloud SQL infrastructure, and the scan processing pipeline.

## User Roles

| Role | Can do |
|------|--------|
| **Homeowner** | Create projects, scan rooms (via iOS app), view bids, accept a bid (hire), leave reviews, manage account |
| **Contractor (user)** | Browse matched RFQs, submit bids (amount + description + PDF), view won jobs. Belongs to an org. |
| **Contractor (admin)** | All of the above + manage org settings, invite/remove members, edit org profile, manage gallery |
| **Platform admin** | Approve contractor org requests (manual, email-based for now) |

## Page Map

| Status | Path | Purpose |
|--------|------|---------|
| EXISTS | `/quote/{rfqId}` | Contractor RFQ view -- 3D viewer + bid modal (`contractor_view.html`) |
| EXISTS | `/bids/{rfqId}?token=` | Homeowner bid comparison (`bids.html`, token-gated, legacy) |
| DONE | `/` | Landing page with two-field search (service + location) |
| DONE | `/login` | Sign in (email/password, Google) |
| DONE | `/account` | Account settings (name, phone, address, icon upload, contractor request) |
| DONE | `/projects` | My Projects (expandable cards with floor plan, rooms, edit, delete) |
| DONE | `/projects/{rfqId}/quotes` | Bid comparison with price filters, hire button |
| DONE | `/org?tab=jobs` | Contractor jobs view (new/pending/won/lost with inline quote submission) |
| DONE | `/org?tab=settings` | Org profile editor (banner, logo, hours, address, radius, review links) |
| DONE | `/org?tab=members` | Member management (invite by email with deep links) |
| DONE | `/org?tab=gallery` | Portfolio gallery (albums, videos, multi-upload, service tags, lightbox) |
| DONE | `/org?tab=services` | Service selection from 14 categories |
| DONE | `/contractors/{orgId}` | Public org profile (banner, gallery, map with radius, hours, services, team) |
| DONE | `/search` | Contractor search/browse with filters (demo data, needs real API) |
| DONE | `/invite?token=` | Token-based org invite acceptance |
| DONE | `/info` | Original marketing landing page (static HTML) |

---

## System Flows

### Flow 1: Scan Upload & Processing

> **Status: IMPLEMENTED** -- iOS app, API endpoints, and scan processor are working.
> Two known gaps: (1) processor does not auto-transition `rfqs.status` to `scan_ready` when all rooms complete, (2) FCM push to app after processing is not wired up.

Current endpoint paths:
```
GET  /api/rfqs/{rfq_id}/scans/upload-url     -> signed GCS URL + scan_id
POST /api/rfqs/{rfq_id}/scans/complete        -> enqueues Cloud Tasks job
GET  /api/rfqs/{rfq_id}/scans/{scan_id}/status -> poll processing result
DELETE /api/rfqs/{rfq_id}/scans/{scan_id}     -> soft-delete (scan_status='deleted')
```

Flow:
```
Mobile App
  -> GET /api/rfqs/{rfq_id}/scans/upload-url (JWT) -> signed GCS URL + scan_id
  -> PUT scan.zip directly to GCS (bypasses API, avoids 32MB Cloud Run limit)
  -> POST /api/rfqs/{rfq_id}/scans/complete (scan_id, room_label)
  -> API: INSERT scanned_rooms (scan_status='processing', scan_mesh_url)
  -> API: enqueue Cloud Tasks job with OIDC token to processor
  -> Cloud Tasks -> POST {PROCESSOR_URL}/process (scan_id, rfq_id, blob_path)
  -> Processor: download zip, parse PLY, RANSAC planes, compute room metrics
  -> Processor: UPDATE scanned_rooms (dims, detected_components, scan_status='complete')
  -> Mobile App polls GET /status every 5s (max 10 min)

  TODO: Processor should UPDATE rfqs SET status='scan_ready' when all rooms complete
  TODO: FCM push to app on completion (replace polling)
```

### Flow 2: RFQ Submission & Contractor Geo-Matching

> **Status: NOT IMPLEMENTED** -- RFQ creation exists (basic INSERT) but no geo-matching, no service selection, no contractor notifications. Current RFQs are created from the iOS app with minimal metadata.

Target flow:
```
Homeowner (Web or App)
  -> POST /api/rfqs (JWT + service_id + property_id + description)
  -> Firebase Auth verifyIdToken
  -> INSERT rfqs (status=scan_pending)
  -> Lookup property lat/lng from properties table
  -> Haversine prefilter: SELECT organizations WHERE straight-line distance <= service_radius_miles
  -> Google Maps Distance Matrix API: confirm real drive time for shortlist
  -> INSERT rfq_contractor_matches for qualifying orgs
  -> UPDATE rfqs SET status=listed
  -> FCM push + email + SMS to matched contractors
  -> Contractors GET /api/rfqs/{id} to view full RFQ + scan data
```

### Flow 3: Bid Submission & Acceptance

> **Status: IMPLEMENTED** -- Bid submission works via inline form in Jobs tab or quote viewer modal (price + description + optional PDF). Bids are org-based (bids.org_id). Homeowners can accept a bid (POST /api/rfqs/{rfq_id}/accept-bid) which rejects all others, sends email notifications to winner/homeowner/losers. Bid status: pending/accepted/rejected. RFQ modification after bid submission flags bids with `rfq_modified_after_bid`. Soft-delete on RFQs shows "Cancelled" to contractors.

Current state:
```
Contractor (Web)
  -> Signs in on /quote/{rfqId} (Firebase Auth JS)
  -> Submits bid via modal -> POST /api/rfqs/{rfq_id}/bids (multipart/form-data)
     Fields: price_cents (INT), description, pdf (optional file)
  -> API: auto-creates contractors row if first bid
  -> API: uploads PDF to GCS at bids/{rfq_id}/{bid_id}.pdf
  -> API: INSERT bids (no status column, contractor_id not org_id)

Homeowner (Web)
  -> Views bids at /bids/{rfqId}?token={bid_view_token}
  -> Sees bid cards sorted by price with contractor profiles
  -> NO acceptance/rejection flow
```

Current schema gaps vs target:
| Gap | Current | Target |
|-----|---------|--------|
| Bidder identity | `contractor_id` (individual) | `org_id` (organization) |
| Price field | `price_cents INTEGER` | `amount NUMERIC(12,2)` |
| Bid status | No column | `status VARCHAR` (pending/accepted/rejected/withdrawn) |
| Uniqueness | No constraint (allows duplicates) | `UNIQUE(rfq_id, org_id)` |
| Accept flow | Not implemented | `POST /api/rfqs/{rfq_id}/accept-bid` |
| Access control | Link-based (no auth on contractor view) | Firebase Auth on all endpoints |
| Notifications | TODO in code | SendGrid + Twilio + FCM |

Target flow:
```
Contractor (Web)
  -> Views matched RFQ -> GET /api/rfqs/{id} (Firebase Auth)
  -> Submits bid -> POST /api/rfqs/{rfq_id}/bids (amount, description, PDF signed URL)
  -> INSERT bids (org_id, status='pending')
  -> Notify homeowner (email + SMS + FCM push)

Homeowner (Web or App)
  -> Views bids -> GET /api/rfqs/{rfq_id}/bids (Firebase Auth)
  -> Accepts a bid -> POST /api/rfqs/{rfq_id}/accept-bid
  -> UPDATE bids SET status=accepted (winner), status=rejected (others)
  -> UPDATE rfqs SET status=completed, hired_bid_id
  -> Notify winning contractor (email + SMS)
```

---

## Database Schema

### Existing Tables (already in cloud/schema.sql)

The following tables already exist and are managed by the scan processing pipeline. The platform tables below extend this foundation — they do not replace it.

- **`properties`** -- physical buildings, one property can anchor many RFQs
- **`floors`** -- levels within a property
- **`rfqs`** -- request-for-quote projects (extended below with new columns)
- **`scanned_rooms`** -- one row per processed room scan (source of truth for scan data)
- **`scan_component_labels`** -- platform vocabulary of DNN-detectable materials/surfaces
- **`line_item_templates`** -- master list of billable items
- **`scan_component_templates`** -- maps detected labels to line item template bundles
- **`appliance_labels`** -- vocabulary of discrete detectable objects
- **`room_appliances`** -- positioned appliance instances per room

#### Existing tables added by migrations (007):

- **`contractors`** -- individual contractor profiles (auto-created on first bid). **Will be superseded by `accounts` + `organizations` + `org_members`.** Migrate existing contractor data to new tables, then deprecate.
- **`rfq_invites`** -- links RFQs to contractors. **Will be superseded by `rfq_contractor_matches`.** Currently unused in code.
- **`bids`** -- contractor bids. **Will be migrated** to add `org_id`, `status`, `amount` (replacing `price_cents`), unique constraint. See migration notes below.

#### Existing columns added by migrations (004-006):

- **`rfqs.user_id`** -- Firebase UID scoping projects to user. **Will be replaced by `rfqs.homeowner_account_id` FK to `accounts`.** Migrate existing `user_id` values.
- **`rfqs.address`** -- property address. **Will move to `properties.address`** (already exists there). Drop from rfqs after migration.
- **`rfqs.project_scope`** -- JSONB work items checklist. **Keep as-is.**
- **`rfqs.bid_view_token`** -- UUID for token-gated bid viewing. **Keep for backward compat**, but new bid listing will use Firebase Auth.
- **`scanned_rooms.scope`** -- JSONB per-room work items. **Keep as-is.**

### New Tables

**`accounts`** -- unified user accounts
```sql
CREATE TABLE accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firebase_uid TEXT UNIQUE NOT NULL,
    email TEXT NOT NULL,
    name TEXT,
    phone TEXT,
    type VARCHAR(20) NOT NULL DEFAULT 'homeowner',  -- 'homeowner' or 'contractor'
    icon_url TEXT,
    address TEXT,
    notification_preferences JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP
);
```

**`organizations`** -- contractor organizations
```sql
CREATE TABLE organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    address TEXT,
    service_lat FLOAT,                  -- geocoded from address
    service_lng FLOAT,                  -- geocoded from address
    service_radius_miles FLOAT,         -- how far org will travel
    max_travel_time_minutes INT,        -- platform hard max: 90 min
    icon_url TEXT,
    website_url TEXT,
    yelp_url TEXT,
    google_reviews_url TEXT,
    avg_rating FLOAT,                   -- atomic update from ratings_reviews (see update rule)
    created_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP
);
```

`avg_rating` update rule -- never read-then-write (race condition). Use an atomic update within the same transaction as the review insert:
```sql
UPDATE organizations
SET avg_rating = (SELECT AVG(rating) FROM ratings_reviews WHERE org_id = $1)
WHERE id = $1;
```

**`org_members`** -- links accounts to organizations with roles
```sql
CREATE TABLE org_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID REFERENCES organizations(id),
    account_id UUID REFERENCES accounts(id),
    role VARCHAR(20) DEFAULT 'user',    -- 'admin' or 'user'
    invited_email TEXT,
    invite_status VARCHAR(20) DEFAULT 'pending',  -- 'pending', 'accepted', 'declined'
    invited_at TIMESTAMP DEFAULT NOW(),
    accepted_at TIMESTAMP,
    UNIQUE(org_id, account_id)
);
```

**`org_requests`** -- contractor org approval requests
```sql
CREATE TABLE org_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID REFERENCES accounts(id),
    org_name TEXT NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',  -- 'pending', 'approved', 'rejected'
    requested_at TIMESTAMP DEFAULT NOW(),
    resolved_at TIMESTAMP
);
```

**`org_work_images`** -- portfolio gallery (single or before/after)
```sql
CREATE TABLE org_work_images (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID REFERENCES organizations(id),
    image_type VARCHAR(20) DEFAULT 'single',  -- 'single' or 'before_after'
    image_url TEXT,              -- single image or "after" image
    before_image_url TEXT,       -- only for before_after type
    caption TEXT,
    sort_order INT DEFAULT 0,
    created_at TIMESTAMP DEFAULT NOW()
);
```

**`services`** -- platform service taxonomy
```sql
CREATE TABLE services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(200) NOT NULL,
    description TEXT,
    icon_url TEXT,
    search_aliases TEXT[],       -- keyword variations for fallback search
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT NOW()
);
```

**`org_services`** -- links organizations to their declared services
```sql
CREATE TABLE org_services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id UUID REFERENCES organizations(id),
    service_id UUID REFERENCES services(id),
    years_experience INT,
    UNIQUE(org_id, service_id)
);
```

**`rfq_contractor_matches`** -- geo-matching results, cached at RFQ listing time
```sql
CREATE TABLE rfq_contractor_matches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rfq_id UUID REFERENCES rfqs(id),
    org_id UUID REFERENCES organizations(id),
    distance_miles FLOAT,                -- straight-line (haversine)
    travel_time_minutes INT,             -- from Distance Matrix API
    is_within_range BOOLEAN,
    match_status VARCHAR(20) DEFAULT 'notified',  -- 'notified', 'viewed', 'quoted', 'passed'
    notified_at TIMESTAMP,
    viewed_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT NOW()
);
```

**`ratings_reviews`** -- one review per completed bid
```sql
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

**`rfqs`** -- add columns:
- `homeowner_account_id UUID REFERENCES accounts(id)` -- replaces `user_id` (Firebase UID string)
- `service_id UUID REFERENCES services(id)` -- what type of project
- `hired_bid_id UUID REFERENCES bids(id)` -- which bid was accepted
- `before_images TEXT[]` -- photos of current state
- `listed_at TIMESTAMP` -- when published to contractors
- `completed_at TIMESTAMP` -- when bid accepted

**`properties`** -- add:
- `homeowner_account_id UUID REFERENCES accounts(id)` (if not already present)

**`bids`** -- migrate existing table:
- Add `org_id UUID REFERENCES organizations(id)`
- Add `status VARCHAR(20) DEFAULT 'pending'` (pending/accepted/rejected/withdrawn)
- Add `amount NUMERIC(12,2)` -- migrate from `price_cents` (divide by 100)
- Add `submitted_at TIMESTAMP`
- Add `deleted_at TIMESTAMP`
- Add `UNIQUE(rfq_id, org_id)` constraint
- Deprecate `contractor_id` after migrating to org-based model
- Deprecate `price_cents` after migrating to `amount`

### Migration Strategy for Existing Data

1. Create new tables (`accounts`, `organizations`, `org_members`, etc.)
2. Migrate `contractors` rows -> create `accounts` (type='contractor') + `organizations` (one org per contractor initially) + `org_members` (admin role)
3. Migrate `bids.contractor_id` -> look up org via migrated data, set `bids.org_id`
4. Migrate `bids.price_cents` -> `bids.amount` (price_cents / 100)
5. Migrate `rfqs.user_id` -> look up or create `accounts` row, set `rfqs.homeowner_account_id`
6. Drop deprecated columns after verification

### Service Catalog (seed data)

```sql
INSERT INTO services (name, search_aliases) VALUES
    ('Kitchen Remodel', '{"kitchen renovation", "new kitchen", "kitchen cabinets", "kitchen countertops"}'),
    ('Bathroom Remodel', '{"bathroom renovation", "new bathroom", "vanity", "shower remodel", "tub replacement"}'),
    ('Basement Finish', '{"basement renovation", "basement refinish", "finish basement", "basement remodel"}'),
    ('Flooring & Tile', '{"new floors", "hardwood", "LVP", "tile install", "carpet replacement", "laminate"}'),
    ('Paint & Finish', '{"interior paint", "exterior paint", "painting", "staining", "wall paint"}'),
    ('Deck & Patio', '{"new deck", "patio", "outdoor living", "deck repair", "deck build"}'),
    ('Siding & Roof', '{"new roof", "roof repair", "siding", "gutters", "exterior"}'),
    ('Insulation & Drywall', '{"drywall repair", "insulation", "drywall install", "wall repair"}'),
    ('Water Damage Restoration', '{"flood damage", "water damage", "mold", "moisture", "leak repair"}'),
    ('Plumbing', '{"pipes", "plumber", "drain", "water heater", "faucet", "toilet"}'),
    ('Electrical', '{"electrician", "wiring", "outlets", "panel", "lighting", "breaker"}'),
    ('HVAC', '{"heating", "cooling", "air conditioning", "furnace", "AC", "ductwork"}'),
    ('Window & Door', '{"window replacement", "new doors", "door install", "window install", "storm door"}'),
    ('General Renovation', '{"home renovation", "remodel", "home improvement", "general contractor"}');
```

### Geo-Matching Logic

Two-pass approach to minimize Google Maps API costs:

1. **Haversine prefilter (SQL, no API cost):** Eliminate clearly out-of-range contractors using straight-line distance calculation in PostgreSQL
2. **Distance Matrix API (shortlist only):** Confirm real drive time for candidates that pass the haversine filter
3. **Write matches:** INSERT `rfq_contractor_matches` rows for qualifying orgs
4. **Notify:** FCM push + email + SMS to matched contractors

---

## Contractor Search

### Dual-layer search: LLM-assisted + keyword fallback

**Primary (LLM-assisted):** When a homeowner searches with unstructured text (e.g. "my basement flooded" or "new bathroom vanity"), send the query + services list to Claude Haiku to resolve intent to service IDs. Cache results for repeated queries.

**Fallback (keyword aliases):** If the LLM is unavailable or slow, match the query against `services.name` and `services.search_aliases` using PostgreSQL `ILIKE` or full-text search.

**Structured browse:** Homeowners can also browse by service category directly (no search needed -- just list active services).

**Cost estimate:** ~$0.00028 per LLM query (~$8.50/month at 1,000 searches/day). With caching, realistic costs are a fraction of this.

---

## API Endpoints

### Existing Endpoints (implemented)

| Status | Method | Path | Auth | Purpose |
|--------|--------|------|------|---------|
| DONE | GET | `/api/rfqs/{rfq_id}/scans/upload-url` | Firebase | Get signed GCS upload URL + scan_id |
| DONE | POST | `/api/rfqs/{rfq_id}/scans/complete` | Firebase | Notify upload complete, enqueue processing |
| DONE | GET | `/api/rfqs/{rfq_id}/scans/{scan_id}/status` | Firebase | Poll scan processing status |
| DONE | DELETE | `/api/rfqs/{rfq_id}/scans/{scan_id}` | Firebase | Soft-delete scan |
| DONE | GET | `/api/contractors/me` | Firebase | Get/create contractor profile (to be migrated to accounts) |
| DONE | POST | `/api/rfqs/{rfq_id}/bids` | Firebase | Submit bid (multipart, to be migrated to org-based) |
| DONE | GET | `/api/rfqs/{rfq_id}/bids` | Token | List bids (token-gated, to add Firebase Auth) |

### New Endpoints

#### Accounts
| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/api/account` | Firebase | Get current user's account (auto-creates on first call) |
| PUT | `/api/account` | Firebase | Update name, phone, icon_url, address, notification_preferences |
| POST | `/api/account/request-org` | Firebase | Request contractor org creation (sends email to admin) |

#### Organizations
| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/api/org` | Firebase (contractor) | Get current user's org |
| PUT | `/api/org` | Firebase (admin) | Update org profile, address, links |
| GET | `/api/org/members` | Firebase (member) | List org members |
| POST | `/api/org/members/invite` | Firebase (admin) | Send invite email |
| DELETE | `/api/org/members/{id}` | Firebase (admin) | Remove member |
| POST | `/api/org/members/accept` | Token | Accept invite via email link |
| GET | `/api/org/services` | Firebase (member) | List org's declared services |
| PUT | `/api/org/services` | Firebase (admin) | Update org's service selections |
| GET | `/api/org/gallery` | Firebase (member) | List portfolio images |
| POST | `/api/org/gallery` | Firebase (admin) | Upload portfolio image |
| DELETE | `/api/org/gallery/{id}` | Firebase (admin) | Remove portfolio image |
| GET | `/api/org/active-bids` | Firebase (member) | List active bids with RFQ data |
| GET | `/api/org/won-jobs` | Firebase (member) | List won jobs with RFQ data |

#### Services & Search
| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/api/services` | Public | List all active services (for picker/browse) |
| GET | `/api/search` | Public | Search contractors by query, service, location, rating |

#### Bids & Hiring (new + migrated)
| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| GET | `/api/rfqs/{rfq_id}/bids` | Firebase | List bids for an RFQ (migrate from token-gated) |
| POST | `/api/rfqs/{rfq_id}/bids` | Firebase (contractor) | Submit bid -- org-based (migrate from individual) |
| PUT | `/api/rfqs/{rfq_id}/bids/{bid_id}` | Firebase (contractor) | Update pending bid (NEW) |
| DELETE | `/api/rfqs/{rfq_id}/bids/{bid_id}` | Firebase (contractor) | Withdraw bid (NEW) |
| POST | `/api/rfqs/{rfq_id}/accept-bid` | Firebase (homeowner) | Accept a bid, reject others, notify (NEW) |

#### Reviews
| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| POST | `/api/reviews` | Firebase (homeowner) | Submit review for completed job |
| GET | `/api/org/{org_id}/reviews` | Public | List reviews for an org |

### Web Pages (served by FastAPI)

| Status | Path | Template | Purpose |
|--------|------|----------|---------|
| EXISTS | `/quote/{rfqId}` | `contractor_view.html` | 3D viewer + bid submission |
| EXISTS | `/bids/{rfqId}` | `bids.html` | Bid comparison (token-gated) |
| NEW | `/` | `index.html` | Landing page / contractor search |
| NEW | `/login` | `login.html` | Sign in |
| NEW | `/account` | `account.html` | Account settings |
| NEW | `/projects` | `projects.html` | My projects list |
| NEW | `/org` | `org.html` | Org dashboard |
| NEW | `/search` | `search.html` | Contractor browse |

---

## Notifications

### Infrastructure
- **Email:** SendGrid (API key as env var, from: `notifications@quoterra.com`)
- **SMS:** Twilio (account SID + auth token as env vars, high-value events only)
- **Push:** Firebase Cloud Messaging (already configured in iOS app)

### Triggers

| Event | Who gets notified | Channels |
|-------|-------------------|----------|
| New RFQ listed | Geo-matched contractors (from `rfq_contractor_matches`) | Email + SMS + FCM push |
| New bid received | Homeowner (RFQ owner) | Email + SMS + FCM push |
| Bid accepted (hired) | Winning contractor | Email + SMS |
| Bid rejected | Losing contractors | Email |
| Org invite | Invited email address | Email |
| Org request submitted | Platform admin (jake@) | Email |
| Org request approved | Requesting user | Email |

### Notification Preferences

Users can configure preferences via `accounts.notification_preferences` JSONB:
```json
{
    "email": true,
    "sms": true,
    "push": true
}
```

Channels are opt-out (enabled by default). Notification service checks preferences before sending.

### Notification Service (Python module)
```
cloud/api/notifications.py
  - send_email(to, subject, html_body)        -> SendGrid
  - send_sms(to_phone, message)               -> Twilio
  - send_push(firebase_uid, title, body)       -> FCM
  - notify_rfq_matched(rfq_id)                 -> geo-matched contractors
  - notify_new_bid(bid_id)                     -> homeowner
  - notify_bid_accepted(bid_id)                -> winning contractor
  - notify_bid_rejected(bid_id)                -> losing contractors
  - notify_org_invite(invite_id)               -> invited email
```

---

## Web Framework Decision

**Stay with vanilla HTML + JS for now.** Reasons:
- All existing pages are plain HTML (contractor_view, bids)
- No build step required -- deploy is just `COPY web/ ./web/`
- Firebase Auth JS SDK works in plain HTML
- Can always migrate to React/Next.js later when complexity demands it

Each page is a self-contained HTML file with Firebase Auth JS for login state. Shared CSS and the nav bar are duplicated (or inlined) per page -- acceptable for <15 pages.

---

## Key Technical Decisions

1. **Firebase Auth on web:** Use Firebase JS SDK (`firebase/auth`) in each HTML page for sign-in state. The API already validates Firebase JWTs.
2. **Google Maps APIs:** Geocoding API for address -> lat/lng on org/property creation. Distance Matrix API for real drive time during geo-matching. Maps Embed API or Maps JS API for interactive pins on org dashboard.
3. **File uploads** (org icons, gallery images, bid PDFs): Upload to GCS via signed URLs (same pattern as scan uploads).
4. **Email service:** SendGrid (generous free tier, simple API). From address: `notifications@quoterra.com`.
5. **SMS:** Twilio (pay-per-message). Only for high-value events: new RFQ match, new bid, hired.
6. **LLM search:** Claude Haiku for unstructured query intent mapping. Cached results. Keyword alias fallback ensures search always works even if LLM is unavailable.
7. **Geo-matching:** Haversine prefilter in PostgreSQL to avoid unnecessary Maps API calls. Only shortlisted candidates hit the Distance Matrix API.

---

## Work Order

### Critical Path (unblocks everything else)

**CP-1: Fix scan processing gaps** `[bugfix]`
- Processor auto-transitions `rfqs.status` to `scan_ready` when all `scanned_rooms` reach `complete`
- Wire FCM push notification to app on scan completion (replace client-side polling)
- Files: `cloud/processor/main.py`, `cloud/api/main.py`

**CP-2: Accounts + Auth migration** `[foundation]`
- Create `accounts` table
- `GET/PUT /api/account` endpoints with auto-create on first call
- Migrate existing `rfqs.user_id` (Firebase UID string) to `rfqs.homeowner_account_id` (FK)
- Migrate existing `contractors` rows to `accounts` (type='contractor')
- `login.html` with Firebase Auth JS (email/password + Google + Apple)
- Files: new migration, `cloud/api/main.py`

**CP-3: Organizations + Org Members** `[foundation]`
- Create `organizations`, `org_members`, `org_requests` tables
- `/api/org` CRUD, `/api/org/members` invite/remove
- `/api/account/request-org` + manual email approval
- Migrate each existing `contractors` row into a one-person org (admin role)
- Files: new migration, `cloud/api/main.py`

**CP-4: Migrate bids to org-based model** `[foundation]`
- Add `org_id`, `status`, `amount`, `submitted_at`, `deleted_at` columns to `bids`
- Migrate `bids.contractor_id` -> `bids.org_id` using account/org mapping from CP-3
- Migrate `bids.price_cents` -> `bids.amount` (divide by 100)
- Add `UNIQUE(rfq_id, org_id)` constraint
- Update `POST /api/rfqs/{rfq_id}/bids` to use org-based auth
- Update `GET /api/rfqs/{rfq_id}/bids` to use Firebase Auth (keep token fallback for existing links)
- Update `contractor_view.html` bid modal to work with new model
- Update `bids.html` to show org info instead of individual contractor
- Files: new migration, `cloud/api/main.py`, `contractor_view.html`, `bids.html`

### High Value (marketplace features, ordered by impact)

**HV-1: Bid acceptance flow** `[core marketplace]`
- `POST /api/rfqs/{rfq_id}/accept-bid` -- accept winner, reject others
- Update `rfqs.status` to `completed`, set `hired_bid_id`
- Add accept/reject UI to `bids.html`
- Files: `cloud/api/main.py`, `bids.html`

**HV-2: Services taxonomy** `[enables matching + search]`
- Create `services`, `org_services` tables + seed data
- Add `service_id` column to `rfqs`
- `GET /api/services` (public)
- `GET/PUT /api/org/services` (org service selection)
- Service picker on RFQ creation (app + web)
- Files: new migration, `cloud/api/main.py`

**HV-3: Geo-matching** `[enables contractor discovery]`
- Add geo fields to `organizations` (service_lat/lng, radius, max_travel_time)
- Create `rfq_contractor_matches` table
- Geocoding on org/property address save (Google Geocoding API)
- Haversine prefilter + Distance Matrix API matching logic
- Run matching on RFQ listing, write `rfq_contractor_matches` rows
- Files: new migration, `cloud/api/main.py`, new `cloud/api/geo.py`

**HV-4: Notifications** `[engagement + retention]`
- `cloud/api/notifications.py` module (SendGrid + Twilio + FCM)
- Wire triggers: new RFQ match -> contractors, new bid -> homeowner, bid accepted -> contractor
- Notification preferences on accounts
- Org invite emails
- Files: new `cloud/api/notifications.py`, `cloud/api/main.py`

**HV-5: Homeowner web experience** `[self-serve project management]`
- `/projects` page -- list user's RFQs with status
- `/projects/{rfqId}` -- project detail (scans, scope, bids, hired status)
- `/account` page -- edit profile + notification preferences
- Nav bar shared across pages
- Files: new HTML pages in `cloud/api/web/`

**HV-6: Org dashboard + gallery** `[contractor self-serve]`
- `/org` dashboard -- org profile, stats
- `/org/settings` -- edit profile, address (triggers geocoding), links
- `/org/members` -- invite/remove members
- `/org/gallery` -- portfolio upload with before/after support
- `org_work_images` table
- Files: new HTML pages, new migration, `cloud/api/main.py`

**HV-7: Contractor search** `[public discovery]`
- `GET /api/search` -- LLM-assisted (Haiku) + alias fallback + location + rating filters
- LLM response caching layer
- `/search` page -- contractor cards, filters
- `/` landing page -- hero + search
- Files: new `cloud/api/search.py`, new HTML pages

**HV-8: Ratings & reviews** `[trust + marketplace quality]`
- `ratings_reviews` table
- `POST /api/reviews` -- submit review after completed job
- `GET /api/org/{org_id}/reviews` -- public review listing
- Atomic `avg_rating` update on organizations
- Review display on search results and org profile
- Files: new migration, `cloud/api/main.py`

### Suggested Execution Order

```
CP-1 (scan bugfixes)           -- standalone, do first
  |
CP-2 (accounts)                -- foundation for everything
  |
CP-3 (organizations)           -- depends on accounts
  |
CP-4 (migrate bids)            -- depends on organizations
  |
  +-- HV-1 (bid acceptance)    -- depends on migrated bids
  |
  +-- HV-2 (services)          -- independent of bids, needs accounts
  |     |
  |     +-- HV-3 (geo-matching) -- depends on services + org geo fields
  |           |
  |           +-- HV-4 (notifications) -- depends on geo-matching for match triggers
  |
  +-- HV-5 (homeowner web)     -- depends on accounts, can parallel with HV-2/3
  |
  +-- HV-6 (org dashboard)     -- depends on organizations, can parallel with HV-2/3
  |
  +-- HV-7 (search)            -- depends on services + geo fields
  |
  +-- HV-8 (reviews)           -- depends on bid acceptance flow
```

---

## Verification

Each work item should be testable independently:
- **CP-1:** Process a scan, verify `rfqs.status` transitions to `scan_ready` automatically
- **CP-2:** Sign in on web, verify account auto-created, edit profile
- **CP-3:** Request org, approve manually, verify org + admin membership created
- **CP-4:** Submit bid as org member, verify `org_id` set, view bids with org info
- **HV-1:** Accept a bid, verify winner status=accepted, others rejected, rfq completed
- **HV-2:** Seed services, assign to org, create RFQ with service_id
- **HV-3:** Create org with address (geocoded), create RFQ, verify `rfq_contractor_matches` populated
- **HV-4:** Submit bid, verify homeowner gets email/SMS. List RFQ, verify matched contractors get push.
- **HV-5:** Sign in, see projects list, click into project detail, view bids
- **HV-6:** View org dashboard, edit settings, upload gallery images, invite member
- **HV-7:** Search "my basement flooded" -> LLM resolves to Water Damage Restoration -> show matching contractors
- **HV-8:** Leave review after hire, verify org avg_rating updates atomically
