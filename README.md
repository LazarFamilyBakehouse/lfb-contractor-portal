# LFB Contractor Portal — Phase 1

Sister portal to [`lfb-wholesale-portal`](https://partners.lazarfamilybakehouse.com). Same stack (single-file HTML/JS, Supabase, EmailJS, Netlify), distinct visual identity (sage-green accents + a "CONTRACTOR PORTAL" top banner).

Live at → **contractors.lazarfamilybakehouse.com** (once deployed — see steps below)

---

## Architecture

| Layer | Tech | Purpose |
|---|---|---|
| Frontend | HTML/CSS/JS (single file) | Portal UI for contractors & admins |
| Hosting | **GitHub Pages** | Static deploy from `main` branch |
| Database | Supabase (PostgreSQL) | Same project as wholesale portal; new tables prefixed `c_` |
| Auth | Supabase Auth (email + password) | Both admins and contractors have individual accounts |
| Files | Supabase Storage | Private `contractor-documents` bucket |
| Email | EmailJS *(separate account from wholesale — see docs/EMAILJS.md)* | Currently stubbed; activate by flipping `EMAILJS_ENABLED` to true |

---

## Repository structure

```
lfb-contractor-portal/
├── index.html                         # Main portal (all HTML/CSS/JS in one file)
├── CNAME                              # Custom domain — read by GitHub Pages
├── .nojekyll                          # Tells GitHub Pages to skip Jekyll processing
├── favicon.ico, images/               # Brand assets (copied from wholesale portal)
├── netlify.toml                       # Unused on GitHub Pages — safe to delete
├── README.md                          # This file
├── docs/
│   ├── SUPABASE.md                    # Tables, RLS policies, RPC functions
│   └── EMAILJS.md                     # Template configuration and variables
└── supabase/
    └── migrations/
        └── 001_phase1_schema.sql      # All tables, RLS, RPCs, triggers, storage bucket
```

---

## Deploy checklist (one-time)

### 1. Run the SQL migration

1. Open the Supabase dashboard → SQL Editor → New Query
2. Paste the entire contents of `supabase/migrations/001_phase1_schema.sql`
3. Click **Run**. Idempotent — safe to re-run if something fails partway.
4. Result: 10 tables (`c_contractors`, `c_documents`, `c_shifts`, `c_shift_signups`, `c_hour_submissions`, `c_payments`, `c_payment_items`, `c_availability`, `c_audit_log`, `c_settings`), full RLS policies, RPC functions, audit triggers, and a private `contractor-documents` storage bucket.

### 2. Create the first admin

Both you and Victoria need (a) a Supabase Auth user and (b) a `c_contractors` row with `role='admin'`.

**Option A — reuse the wholesale Supabase Auth user (you, Jake):**
```sql
-- Find your existing user ID (it's the user_id used by the wholesale portal admin login)
select id, email from auth.users where email = 'info@lazarfamilybakehouse.com';

-- Insert the matching contractor row
insert into public.c_contractors
  (user_id, role, first_name, last_name, email, pay_rate, status)
values
  ('<UUID-from-above>', 'admin', 'Jake', 'Lazar', 'info@lazarfamilybakehouse.com', 0, 'active');
```

**Option B — for Victoria (and any future admin) without manual SQL:**
1. Sign in to the contractor portal as `info@lazarfamilybakehouse.com`
2. Go to **Contractors → + Add contractor**
3. Fill in her name, email, phone, pay rate; set role = Admin
4. The portal auto-sends a magic-link email; she clicks it, sets a password, and she's in.

### 3. Push to GitHub

Create a new repo at `LazarFamilyBakehouse/lfb-contractor-portal` (or under your personal account) and push everything in this folder.

```bash
# from inside the contractor-portal folder
git init
git add .
git commit -m "Initial deploy — Phase 1"
git branch -M main
git remote add origin git@github.com:LazarFamilyBakehouse/lfb-contractor-portal.git
git push -u origin main
```

### 4. Enable GitHub Pages

1. GitHub repo → **Settings → Pages**
2. **Source:** Deploy from a branch
3. **Branch:** `main`, **Folder:** `/ (root)`
4. **Save**

Within ~60 seconds GitHub builds and publishes the site. You'll see a banner at the top of the Pages settings page with the live URL — usually `https://lazarfamilybakehouse.github.io/lfb-contractor-portal/` (if under the org) or `https://<your-username>.github.io/lfb-contractor-portal/`. This temporary URL works immediately for testing.

### 5. Point the subdomain

The `CNAME` file already in the repo tells GitHub Pages to expect `contractors.lazarfamilybakehouse.com`. You need to add the matching DNS record in Hostinger.

In Hostinger DNS for `lazarfamilybakehouse.com`, add:

```
Type:    CNAME
Name:    contractors
Value:   <github-org-or-username>.github.io
         (e.g. lazarfamilybakehouse.github.io — NO https://, NO repo name, NO trailing slash)
TTL:     3600 (or default)
```

Then back in GitHub repo → Settings → Pages:
1. Confirm **Custom domain** shows `contractors.lazarfamilybakehouse.com` (GitHub reads this from your `CNAME` file)
2. Wait for the DNS check to pass (green checkmark — can take a few minutes)
3. Check **Enforce HTTPS** once available (Let's Encrypt cert provisions automatically, usually within 5–15 minutes)

### 6. Re-deploy after edits

GitHub Pages auto-rebuilds on every push to `main`. To make a change:

```bash
# edit index.html locally
git add index.html
git commit -m "Tweak"
git push
# wait ~60s → refresh contractors.lazarfamilybakehouse.com
```

### 6. Test login + admin flow

1. Visit `contractors.lazarfamilybakehouse.com`
2. Sign in with `info@lazarfamilybakehouse.com` + your wholesale-portal password
3. You should land on the Admin Dashboard with a sage-green "CONTRACTOR PORTAL" banner at the top
4. Try: Add a contractor → confirm magic-link email arrives → create a test shift → sign up as that contractor on a second device → submit hours → approve → mark paid

---

## Activating EmailJS (when ready)

See `docs/EMAILJS.md` for the full procedure. TL;DR:

1. Create a second EmailJS account (so it doesn't share the wholesale portal's 200/month free quota)
2. Create the 8 templates from `PHASE1_EMAIL_TEMPLATES.md` in that account
3. In `index.html`, find the `CONFIG` block (~line 555) and:
   - Set `EMAILJS_ENABLED = true`
   - Paste your `EMAILJS_PUBLIC_KEY` and `EMAILJS_SERVICE_ID`
   - Fill in the 8 template IDs in `EMAILJS_TEMPLATES`
4. Commit & push — GitHub Pages redeploys in ~60 seconds.

---

## What's in scope for Phase 1

**Contractor-facing:**
- Sign in via Supabase Auth (email + password), magic-link first-time setup
- Profile: name, email, phone, address, emergency contact, food handler card expiration, pay rate (read-only)
- Document uploads (W-9, ID, food handler card) to private Supabase Storage
- Browse the shift schedule, sign up for open shifts, release a spot
- Submit hours after a shift; admin reviews/approves
- Real-time payments view (earned, pending, paid, unpaid, 1099 threshold flag)
- **Availability calendar** — mark days as free / busy / tentative for the next 3 months and beyond; bulk presets

**Admin-facing:**
- Dashboard with per-contractor YTD totals, 1099 flags, food card expirations, stale-availability flags
- Create / edit / cancel shifts; notify contractors on post / cancel
- **Availability heatmap calendar** — see who's free on each day, post a shift directly from any date
- Approve / adjust submitted hours; pay rate snapshotted at approval
- Per-contractor payments view; record check / Venmo / Zelle / cash with reference number
- Add / edit / deactivate contractors; send magic-link invite
- Audit log — every shift edit, hours change, payment, admin profile edit
- Settings — default shift values, EmailJS status, maintenance

**Not in Phase 1** (kept space in the schema for future):
- 24-hour shift reminder email (needs scheduled trigger — Supabase Edge Function recommended; see Phase 2)
- Contract auto-generation + e-signature
- Referral submissions, anonymous feedback
- 1099/invoice export
- SMS notifications, geofenced clock-in, shift swap

---

## Visual distinction from wholesale portal

The wholesale portal uses red accents (`--red: #ff0000`). This portal uses sage green (`--accent: #6b8f5e`) and shows a thin sage banner reading `CONTRACTOR PORTAL` at the top of every page. Anyone using both will know at a glance which one they're in.

---

## Key configuration in index.html

| Constant (in `<script>` CONFIG block) | What it does |
|---|---|
| `SUPABASE_URL` / `SUPABASE_ANON` | Same Supabase project as wholesale portal; anon key is safe to publish — RLS protects data |
| `EMAILJS_ENABLED` | `false` until you wire in EmailJS (see above) |
| `EMAILJS_PUBLIC_KEY`, `EMAILJS_SERVICE_ID`, `EMAILJS_TEMPLATES` | Fill these when activating |
| `ADMIN_EMAIL` | Recipient for admin-facing emails (currently `info@lazarfamilybakehouse.com`) |
| `INACTIVITY_TIMEOUT_MS` | Auto-signout after this many ms of inactivity (default 60 min) |

---

## Security notes

- All RLS policies enforce that contractors only see their own data
- Admin 