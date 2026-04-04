> **DEPRECATED:** Spec for adding bid submission to the contractor viewer. Implemented differently — the deployed `contractor_view.html` has OBJ mesh loading, HD toggle, and Firebase Auth bid submission. See the actual HTML file for current implementation.

# Contractor View Updates — Bid Submission + Auth

Spec for updating `cloud/api/web/contractor_view.html` and `cloud/api/main.py` to support contractor authentication and bid submission directly from the contractor view page.

---

## Overview

The contractor view at `/quote/{rfq_id}` currently has a "Submit Quote" button that opens a mailto: link. Replace this with:
1. Firebase Auth sign-in/create-account (same auth system as the iOS app)
2. An inline bid submission form (price, description, PDF upload)
3. A contractor profile fetch to identify the logged-in contractor

All auth uses the existing Firebase project (`roomscanalpha`) and the existing `verify_firebase_token()` helper in `main.py`. No new auth system needed.

---

## Database Changes

### Migration `007_add_bids.sql`

```sql
CREATE TABLE contractors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firebase_uid TEXT UNIQUE,
    email TEXT UNIQUE NOT NULL,
    name TEXT,
    icon_url TEXT,
    yelp_url TEXT,
    google_reviews_url TEXT,
    review_rating NUMERIC(2,1),
    review_count INTEGER,
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE rfq_invites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rfq_id UUID NOT NULL REFERENCES rfqs(id),
    contractor_id UUID NOT NULL REFERENCES contractors(id),
    sent_at TIMESTAMPTZ DEFAULT now(),
    viewed_at TIMESTAMPTZ,
    UNIQUE(rfq_id, contractor_id)
);

CREATE TABLE bids (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rfq_id UUID NOT NULL REFERENCES rfqs(id),
    contractor_id UUID NOT NULL REFERENCES contractors(id),
    price_cents INTEGER NOT NULL,
    description TEXT,
    pdf_url TEXT,
    received_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE rfqs ADD COLUMN bid_view_token UUID DEFAULT gen_random_uuid();
```

The `contractors.firebase_uid` column links to Firebase Auth. The API resolves contractors by matching the `uid` from `verify_firebase_token()` to this column.

---

## API Changes (`cloud/api/main.py`)

### Existing code to reuse
- `verify_firebase_token(authorization)` — already validates Firebase JWTs, returns `{ uid, email, ... }`
- `get_db_connection()`, `_row_to_dict()` — existing DB helpers
- `storage_client`, `BUCKET_NAME`, `SIGNING_SA_EMAIL`, signed URL generation pattern — reuse from existing endpoints

### New endpoint: `GET /api/contractors/me`

Returns the authenticated contractor's profile. Auto-creates a contractor row on first sign-in.

```python
@app.get("/api/contractors/me")
def get_contractor_profile(authorization: str = Header(None)) -> dict:
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]
    email = decoded.get("email", "")

    conn = get_db_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT id, email, name, icon_url, yelp_url, google_reviews_url, review_rating, review_count FROM contractors WHERE firebase_uid = %s",
            (uid,),
        )
        row = cursor.fetchone()

        if not row:
            # Auto-create contractor on first login
            contractor_id = str(uuid.uuid4())
            cursor.execute(
                "INSERT INTO contractors (id, firebase_uid, email) VALUES (%s, %s, %s)",
                (contractor_id, uid, email),
            )
            conn.commit()
            return {"id": contractor_id, "email": email, "name": None, "icon_url": None, "yelp_url": None, "google_reviews_url": None, "review_rating": None, "review_count": None}

        columns = ["id", "email", "name", "icon_url", "yelp_url", "google_reviews_url", "review_rating", "review_count"]
        result = _row_to_dict(columns, row)
        result["id"] = str(result["id"])
        if result["review_rating"] is not None:
            result["review_rating"] = float(result["review_rating"])
        return result
    finally:
        conn.close()
```

### New endpoint: `POST /api/rfqs/{rfq_id}/bids`

Submits a bid. Requires Firebase Auth. Accepts multipart/form-data for PDF upload.

```python
from fastapi import UploadFile, File, Form

@app.post("/api/rfqs/{rfq_id}/bids")
async def submit_bid(
    rfq_id: str,
    price_cents: int = Form(...),
    description: str = Form(...),
    pdf: Optional[UploadFile] = File(None),
    authorization: str = Header(None),
) -> dict:
    decoded = verify_firebase_token(authorization)
    uid = decoded["uid"]

    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        # Look up contractor by Firebase UID
        cursor.execute("SELECT id FROM contractors WHERE firebase_uid = %s", (uid,))
        row = cursor.fetchone()
        if not row:
            raise HTTPException(status_code=403, detail="Contractor profile not found. Call GET /api/contractors/me first.")
        contractor_id = str(row[0])

        bid_id = str(uuid.uuid4())
        pdf_url = None

        # Upload PDF to GCS if provided
        if pdf and pdf.filename:
            blob_path = f"bids/{rfq_id}/{bid_id}.pdf"
            bucket = storage_client.bucket(BUCKET_NAME)
            blob = bucket.blob(blob_path)
            content = await pdf.read()
            blob.upload_from_string(content, content_type="application/pdf")

            # Generate signed URL
            if not _credentials.token or not _credentials.valid:
                _credentials.refresh(_auth_request)
            pdf_url = blob.generate_signed_url(
                version="v4",
                expiration=datetime.timedelta(days=7),
                method="GET",
                service_account_email=SIGNING_SA_EMAIL,
                access_token=_credentials.token,
            )

        # Insert bid
        cursor.execute(
            """INSERT INTO bids (id, rfq_id, contractor_id, price_cents, description, pdf_url, received_at)
               VALUES (%s, %s, %s, %s, %s, %s, NOW())""",
            (bid_id, rfq_id, contractor_id, price_cents, description, pdf_url),
        )
        conn.commit()

        # Fetch received_at
        cursor.execute("SELECT received_at FROM bids WHERE id = %s", (bid_id,))
        received_at = cursor.fetchone()[0]
    finally:
        conn.close()

    # TODO: trigger SendGrid email + FCM push to homeowner here

    return {
        "id": bid_id,
        "rfq_id": rfq_id,
        "contractor_id": contractor_id,
        "price_cents": price_cents,
        "description": description,
        "pdf_url": pdf_url,
        "received_at": received_at.isoformat() if received_at else None,
    }
```

### New endpoint: `GET /api/rfqs/{rfq_id}/bids`

Returns all bids for an RFQ with nested contractor profiles. Authenticated via `bid_view_token` (for homeowner view), not Firebase Auth.

```python
@app.get("/api/rfqs/{rfq_id}/bids")
def list_bids(rfq_id: str, token: str = None) -> dict:
    conn = get_db_connection()
    try:
        cursor = conn.cursor()

        # Validate bid_view_token
        cursor.execute(
            "SELECT description, bid_view_token FROM rfqs WHERE id = %s",
            (rfq_id,),
        )
        rfq_row = cursor.fetchone()
        if not rfq_row:
            raise HTTPException(status_code=404, detail="RFQ not found")

        project_description, bid_view_token = rfq_row
        if not token or str(bid_view_token) != token:
            raise HTTPException(status_code=403, detail="Invalid or missing bid view token")

        # Fetch bids with contractor info
        cursor.execute(
            """SELECT b.id, b.price_cents, b.description, b.pdf_url, b.received_at,
                      c.id AS contractor_id, c.name, c.icon_url, c.yelp_url,
                      c.google_reviews_url, c.review_rating, c.review_count
               FROM bids b
               JOIN contractors c ON c.id = b.contractor_id
               WHERE b.rfq_id = %s
               ORDER BY b.price_cents ASC""",
            (rfq_id,),
        )
        rows = cursor.fetchall()
    finally:
        conn.close()

    bids = []
    for row in rows:
        bid_id, price_cents, desc, pdf_url, received_at, c_id, c_name, c_icon, c_yelp, c_google, c_rating, c_count = row
        bids.append({
            "id": str(bid_id),
            "price_cents": price_cents,
            "description": desc,
            "pdf_url": pdf_url,
            "received_at": received_at.isoformat() if received_at else None,
            "contractor": {
                "id": str(c_id),
                "name": c_name,
                "icon_url": c_icon,
                "yelp_url": c_yelp,
                "google_reviews_url": c_google,
                "review_rating": float(c_rating) if c_rating else None,
                "review_count": c_count,
            },
        })

    return {
        "rfq_id": rfq_id,
        "project_description": project_description,
        "bids": bids,
    }
```

---

## Frontend Changes (`cloud/api/web/contractor_view.html`)

### 1. Add Firebase JS SDK

Add before the Three.js `<script type="importmap">` block:

```html
<script src="https://www.gstatic.com/firebasejs/10.12.0/firebase-app-compat.js"></script>
<script src="https://www.gstatic.com/firebasejs/10.12.0/firebase-auth-compat.js"></script>
<script>
  firebase.initializeApp({
    apiKey: "YOUR_FIREBASE_API_KEY",
    authDomain: "roomscanalpha.firebaseapp.com",
    projectId: "roomscanalpha"
  });
</script>
```

### 2. Auth state management

Add to the module `<script>`:

```js
let currentContractor = null; // { uid, email, token, profile }

firebase.auth().onAuthStateChanged(async (user) => {
  if (user) {
    const token = await user.getIdToken();
    currentContractor = { uid: user.uid, email: user.email, token };
    // Auto-create/fetch contractor profile
    try {
      const resp = await fetch(`${API_BASE}/api/contractors/me`, {
        headers: { 'Authorization': `Bearer ${token}` }
      });
      if (resp.ok) currentContractor.profile = await resp.json();
    } catch (e) { console.warn('Failed to fetch contractor profile:', e); }
    renderQuoteSection();
  } else {
    currentContractor = null;
    renderQuoteSection();
  }
});

async function refreshToken() {
  const user = firebase.auth().currentUser;
  if (user) {
    currentContractor.token = await user.getIdToken(true);
  }
}
```

### 3. Replace `setupQuoteButton()` and the mailto `<a>` button

Remove the existing `setupQuoteButton()` function and the `<a class="btn btn-primary" id="btn-quote">` element.

Replace with a container in the top bar:

```html
<div id="quote-section"></div>
```

Add `renderQuoteSection()` which shows either the login form or the bid submission form:

```js
function renderQuoteSection() {
  const el = document.getElementById('quote-section');
  if (!el) return;

  if (!currentContractor) {
    // Show sign-in / create-account
    el.innerHTML = `
      <button class="btn btn-primary" onclick="showAuthModal()">Sign In to Submit Quote</button>
    `;
  } else {
    // Show submit quote button (opens modal with bid form)
    el.innerHTML = `
      <button class="btn btn-primary" onclick="showBidModal()">Submit Quote</button>
    `;
  }
}
```

### 4. Auth modal

Email + password sign-in/create-account form, matching the iOS app's flow:

```js
function showAuthModal() {
  // Create modal overlay if it doesn't exist
  let modal = document.getElementById('auth-modal');
  if (!modal) {
    modal = document.createElement('div');
    modal.id = 'auth-modal';
    modal.className = 'modal-overlay';
    document.body.appendChild(modal);
  }
  modal.innerHTML = `
    <div class="modal-content">
      <button class="modal-close" onclick="closeModal('auth-modal')">&times;</button>
      <h2 id="auth-title">Sign In</h2>
      <p class="auth-subtitle">Sign in to submit your quote</p>
      <input type="email" id="auth-email" placeholder="Email" autocomplete="email">
      <input type="password" id="auth-password" placeholder="Password" autocomplete="current-password">
      <div id="auth-error" class="auth-error"></div>
      <button class="btn btn-primary btn-full" id="auth-submit" onclick="handleAuth()">Sign In</button>
      <button class="btn-link" id="auth-toggle" onclick="toggleAuthMode()">Don't have an account? Create one</button>
      <button class="btn-link" id="auth-forgot" onclick="handleForgotPassword()">Forgot password?</button>
    </div>
  `;
  modal.style.display = 'flex';
  modal._isCreateMode = false;
}

function toggleAuthMode() {
  const modal = document.getElementById('auth-modal');
  modal._isCreateMode = !modal._isCreateMode;
  document.getElementById('auth-title').textContent = modal._isCreateMode ? 'Create Account' : 'Sign In';
  document.getElementById('auth-submit').textContent = modal._isCreateMode ? 'Create Account' : 'Sign In';
  document.getElementById('auth-toggle').textContent = modal._isCreateMode
    ? 'Already have an account? Sign In'
    : "Don't have an account? Create one";
  document.getElementById('auth-forgot').style.display = modal._isCreateMode ? 'none' : '';
  document.getElementById('auth-error').textContent = '';
}

async function handleAuth() {
  const email = document.getElementById('auth-email').value.trim();
  const password = document.getElementById('auth-password').value;
  const errorEl = document.getElementById('auth-error');
  const submitBtn = document.getElementById('auth-submit');
  const isCreate = document.getElementById('auth-modal')._isCreateMode;

  if (!email || !password) { errorEl.textContent = 'Email and password required.'; return; }

  submitBtn.disabled = true;
  submitBtn.textContent = isCreate ? 'Creating...' : 'Signing in...';
  errorEl.textContent = '';

  try {
    if (isCreate) {
      await firebase.auth().createUserWithEmailAndPassword(email, password);
    } else {
      await firebase.auth().signInWithEmailAndPassword(email, password);
    }
    closeModal('auth-modal');
    // onAuthStateChanged fires automatically and updates the UI
  } catch (e) {
    errorEl.textContent = friendlyAuthError(e.code);
    submitBtn.disabled = false;
    submitBtn.textContent = isCreate ? 'Create Account' : 'Sign In';
  }
}

async function handleForgotPassword() {
  const email = document.getElementById('auth-email').value.trim();
  const errorEl = document.getElementById('auth-error');
  if (!email) { errorEl.textContent = 'Enter your email first.'; return; }
  try {
    await firebase.auth().sendPasswordResetEmail(email);
    errorEl.style.color = '#34a853';
    errorEl.textContent = 'Reset link sent — check your email.';
  } catch (e) {
    errorEl.textContent = friendlyAuthError(e.code);
  }
}

function friendlyAuthError(code) {
  const map = {
    'auth/email-already-in-use': 'An account with this email already exists.',
    'auth/wrong-password': 'Incorrect password.',
    'auth/user-not-found': 'No account found with this email.',
    'auth/weak-password': 'Password must be at least 6 characters.',
    'auth/invalid-email': 'Please enter a valid email address.',
    'auth/too-many-requests': 'Too many attempts. Try again later.',
  };
  return map[code] || 'Authentication failed. Please try again.';
}
```

### 5. Bid submission modal

```js
function showBidModal() {
  let modal = document.getElementById('bid-modal');
  if (!modal) {
    modal = document.createElement('div');
    modal.id = 'bid-modal';
    modal.className = 'modal-overlay';
    document.body.appendChild(modal);
  }
  modal.innerHTML = `
    <div class="modal-content">
      <button class="modal-close" onclick="closeModal('bid-modal')">&times;</button>
      <h2>Submit Quote</h2>
      <p class="auth-subtitle">Submitting as ${esc(currentContractor.email)}</p>
      <label class="form-label">Price</label>
      <div class="price-input-wrap">
        <span class="price-prefix">$</span>
        <input type="number" id="bid-price" placeholder="0.00" step="0.01" min="0">
      </div>
      <label class="form-label">Description of Work</label>
      <textarea id="bid-description" rows="4" placeholder="Describe your scope of work..."></textarea>
      <label class="form-label">Estimate PDF (optional)</label>
      <input type="file" id="bid-pdf" accept="application/pdf">
      <div id="bid-error" class="auth-error"></div>
      <button class="btn btn-primary btn-full" id="bid-submit" onclick="handleBidSubmit()">Submit Quote</button>
    </div>
  `;
  modal.style.display = 'flex';
}

async function handleBidSubmit() {
  const priceStr = document.getElementById('bid-price').value;
  const description = document.getElementById('bid-description').value.trim();
  const pdfInput = document.getElementById('bid-pdf');
  const errorEl = document.getElementById('bid-error');
  const submitBtn = document.getElementById('bid-submit');

  const price = parseFloat(priceStr);
  if (!price || price <= 0) { errorEl.textContent = 'Enter a valid price.'; return; }
  if (!description) { errorEl.textContent = 'Description is required.'; return; }

  const priceCents = Math.round(price * 100);

  submitBtn.disabled = true;
  submitBtn.textContent = 'Submitting...';
  errorEl.textContent = '';

  try {
    await refreshToken();

    const formData = new FormData();
    formData.append('price_cents', priceCents);
    formData.append('description', description);
    if (pdfInput.files[0]) {
      formData.append('pdf', pdfInput.files[0]);
    }

    const rfqId = getRfqId();
    const resp = await fetch(`${API_BASE}/api/rfqs/${rfqId}/bids`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${currentContractor.token}` },
      body: formData,
    });

    if (!resp.ok) {
      const err = await resp.json().catch(() => ({}));
      throw new Error(err.detail || `HTTP ${resp.status}`);
    }

    const bid = await resp.json();
    closeModal('bid-modal');

    // Update button to show success
    const el = document.getElementById('quote-section');
    el.innerHTML = `<span class="btn btn-primary" style="opacity:0.7;cursor:default;">Quote Submitted</span>`;
  } catch (e) {
    errorEl.textContent = e.message;
    submitBtn.disabled = false;
    submitBtn.textContent = 'Submit Quote';
  }
}

function closeModal(id) {
  const modal = document.getElementById(id);
  if (modal) modal.style.display = 'none';
}
```

### 6. CSS additions

Add to the existing `<style>` block:

```css
/* Modal overlay */
.modal-overlay { display: none; position: fixed; top: 0; left: 0; right: 0; bottom: 0;
                 z-index: 100; background: rgba(0,0,0,0.5); align-items: center; justify-content: center; }
.modal-content { background: #fff; border-radius: 12px; padding: 32px; max-width: 400px; width: 90%;
                 position: relative; max-height: 90vh; overflow-y: auto; }
.modal-close { position: absolute; top: 12px; right: 16px; background: none; border: none;
               font-size: 24px; color: #8e8e93; cursor: pointer; }
.modal-close:hover { color: #1d1d1f; }
.modal-content h2 { font-size: 20px; font-weight: 700; margin-bottom: 4px; }
.modal-content .auth-subtitle { color: #8e8e93; font-size: 13px; margin-bottom: 20px; }
.modal-content input[type="email"],
.modal-content input[type="password"],
.modal-content input[type="number"],
.modal-content textarea { width: 100%; padding: 12px; border: 1px solid #e0e4ea; border-radius: 8px;
                          font-size: 14px; margin-bottom: 12px; font-family: inherit; }
.modal-content input:focus,
.modal-content textarea:focus { outline: none; border-color: #0055cc; }
.form-label { font-size: 12px; font-weight: 600; color: #6e6e73; margin-bottom: 4px; display: block; }
.price-input-wrap { position: relative; }
.price-prefix { position: absolute; left: 12px; top: 50%; transform: translateY(-70%); color: #6e6e73;
                font-size: 14px; font-weight: 600; }
.price-input-wrap input { padding-left: 28px; }
.auth-error { color: #ff3b30; font-size: 13px; min-height: 20px; margin-bottom: 8px; }
.btn-full { width: 100%; justify-content: center; padding: 12px; font-size: 15px; }
.btn-link { background: none; border: none; color: #0055cc; font-size: 13px; cursor: pointer;
            display: block; margin-top: 8px; text-align: center; width: 100%; }
.btn-link:hover { text-decoration: underline; }
```

### 7. Expose functions to `window`

The auth/bid functions are called from `onclick` attributes but defined inside the module script. Add these at the bottom of the module `<script>`:

```js
window.showAuthModal = showAuthModal;
window.showBidModal = showBidModal;
window.closeModal = closeModal;
window.toggleAuthMode = toggleAuthMode;
window.handleAuth = handleAuth;
window.handleForgotPassword = handleForgotPassword;
window.handleBidSubmit = handleBidSubmit;
```

---

## What NOT to change

- All room viewing, 3D mesh loading, floor plan, measurements, HD toggle — untouched
- `/api/rfqs/{rfq_id}/contractor-view` endpoint — untouched (stays unauthenticated)
- URL structure `/quote/{rfq_id}` — untouched
- `verify_firebase_token()` — reuse as-is

---

## Summary of all files to modify

| File | Changes |
|------|---------|
| `cloud/migrations/007_add_bids.sql` | New file — `contractors`, `rfq_invites`, `bids` tables + `bid_view_token` on `rfqs` |
| `cloud/api/main.py` | Add 3 endpoints: `GET /api/contractors/me`, `POST /api/rfqs/{rfq_id}/bids`, `GET /api/rfqs/{rfq_id}/bids` |
| `cloud/api/web/contractor_view.html` | Add Firebase JS SDK, auth state management, auth modal, bid submission modal, CSS for modals. Remove `setupQuoteButton()` and mailto link |
