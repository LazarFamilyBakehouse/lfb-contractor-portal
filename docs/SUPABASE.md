# Supabase Backend — Contractor Portal

**Project:** LazarFamilyBakehouse Partner Storage (shared with the wholesale portal)
**Project ID:** `ylvoswzsijigyezqvaat`
**URL:** `https://ylvoswzsijigyezqvaat.supabase.co`
**Dashboard:** https://supabase.com/dashboard/project/ylvoswzsijigyezqvaat

All contractor-portal tables are prefixed `c_` so they're visually grouped in the dashboard and never collide with the wholesale tables.

---

## Tables

### `c_contractors`
| Column | Type | Notes |
|---|---|---|
| `id` | uuid (PK) | |
| `user_id` | uuid → auth.users | Set on first sign-in by `c_me()` auto-link |
| `role` | text | `contractor` or `admin` |
| `first_name`, `last_name`, `email`, `phone` | text | |
| `address_line1/2`, `city`, `state`, `postal_code` | text | |
| `emergency_contact_name/phone/relationship` | text | |
| `pay_rate` | numeric(6,2) | Admin sets, contractor read-only |
| `status` | text | `active` / `inactive` |
| `admin_notes` | text | Admin-only |
| `food_handler_card_expires` | date | |
| `availability_last_updated_at` | timestamptz | Auto-updated by trigger |
| `created_at`, `updated_at` | timestamptz | |

### `c_documents`
File metadata; actual file in storage bucket `contractor-documents`.
Columns: `id`, `contractor_id`, `document_type` (`w9`/`id`/`food_handler_card`/`other`), `file_path`, `file_name`, `file_size_bytes`, `mime_type`, `expires_on`, `uploaded_at`, `uploaded_by`.

### `c_shifts`
Bake shifts. Columns: `id`, `bake_date`, `start_time`, `end_time`, `location`, `spots_total`, `notes`, `status` (`open`/`cancelled`/`completed`), `created_by`, `cancelled_reason`, `cancelled_at`, `created_at`, `updated_at`.

### `c_shift_signups`
Many contractors per shift. Columns: `id`, `shift_id`, `contractor_id`, `signed_up_at`, `released_at`, `status` (`signed_up`/`released`/`completed`).
**Partial unique:** `(shift_id, contractor_id) WHERE status <> 'released'` — a contractor can re-sign-up after releasing.

### `c_hour_submissions`
One row per `(signup_id)`. Columns: `signup_id` (UNIQUE), `shift_id`, `contractor_id`, `submitted_hours`, `submitted_notes`, `submitted_at`, `approved_hours`, `approved_pay_rate` (snapshot), `approved_amount` (generated column), `approved_at`, `approved_by`, `status` (`pending`/`approved`), `admin_notes`.

### `c_payments`
Admin-recorded payments. Columns: `id`, `contractor_id`, `amount`, `method` (`check`/`venmo`/`zelle`/`cash`/`other`), `paid_on`, `reference`, `notes`, `created_by`, `created_at`.

### `c_payment_items`
Joins payments to the specific approved hour records they cover. PK `(payment_id, hour_submission_id)`. `hour_submission_id` is UNIQUE so each approved-hours row can only be paid once.

### `c_availability`
Sparse — one row per (contractor, date) only when explicitly marked. Columns: `id`, `contractor_id`, `the_date`, `status` (`free`/`busy`/`tentative`), `note`, `updated_at`.
**Unique:** `(contractor_id, the_date)`.

### `c_audit_log`
Append-only. Columns: `id` (bigserial), `actor_id`, `actor_email`, `action`, `entity_type`, `entity_id`, `before` (jsonb), `after` (jsonb), `created_at`. Written exclusively by SECURITY DEFINER triggers.

### `c_settings`
Key/value config: `default_shift_location`, `default_shift_start_time`, `default_shift_end_time`, `portal_url`, `stale_availability_days`.

---

## Row Level Security

RLS is **enabled on every table**. The guard function is:

```sql
c_is_admin()  -- returns true if auth.uid() maps to a c_contractors row
              -- with role='admin' AND status='active'
```

Pattern: every table has an `admin_all` policy granting full ALL access if `c_is_admin()`, plus contractor-self policies (SELECT/INSERT/UPDATE/DELETE filtered to the caller's own row).

**Column-level grants on `c_contractors`** prevent contractor self-update of admin-only fields:

```sql
revoke update on public.c_contractors from authenticated;
grant update (first_name, last_name, phone, address_line1, address_line2, city, state, postal_code,
              emergency_contact_name, emergency_contact_phone, emergency_contact_relationship,
              food_handler_card_expires) on public.c_contractors to authenticated;
```

So even though the RLS UPDATE policy allows the row, the column grants prevent writing `role`, `pay_rate`, `status`, `admin_notes` — those go through admin-policy writes only.

---

## RPC functions

All `SECURITY DEFINER` (run as the function owner, bypassing RLS) so they can validate auth then perform privileged operations safely.

| Function | Purpose |
|---|---|
| `c_is_admin()` | Returns boolean for the calling user |
| `c_me()` | Returns the caller's contractor row; auto-links by email on first call |
| `c_can_invite(email)` | Admin-only; verifies an email exists in active contractors |
| `c_release_signup(signup_id)` | Atomic spot release; only signup owner or admin |
| `c_approve_hours(submission_id, hours, notes)` | Snapshots pay_rate, marks approved |
| `c_reopen_hours(submission_id)` | Admin re-opens an approved record (refuses if already paid) |
| `c_set_availability_bulk(dates[], status, note)` | Upsert availability for a date array |
| `c_clear_availability(start, end)` | Delete availability rows in a date range |
| `c_availability_counts(start, end)` | Per-day free/busy/tentative counts for the heatmap |
| `c_available_contractors(date)` | Admin-only; who's available on a given date |
| `c_ytd_summary(year)` | Per-contractor approved hrs, earned, paid, unpaid |
| `c_complete_past_shifts()` | Idempotent — marks past open shifts as completed |

---

## Audit triggers

Every audit-relevant change writes a row to `c_audit_log` via SECURITY DEFINER trigger functions:

| Trigger | Captures |
|---|---|
| `c_shifts_audit` | shift create / update / cancel |
| `c_signups_audit` | signup create / release |
| `c_hours_audit` | hours submit / approve / edit |
| `c_payments_audit` | payment create / update |
| `c_contractors_audit` | only logs UPDATEs where actor ≠ row owner (admin editing someone else) |

Audit log can be read only by admins (`c_audit_log_admin_select` RLS policy). No INSERT/UPDATE/DELETE policy exists — only the trigger functions can write.

---

## Storage bucket: `contractor-documents`

- **Private** bucket (not public)
- Path pattern: `<contractor_id>/<timestamp>-<filename>`
- Policies (defined in migration): SELECT/INSERT/DELETE allowed when `(storage.foldername(name))[1] = caller's contractor_id`, OR when caller is admin
- Files are served via short-lived signed URLs from `createSignedUrl()` — never directly linkable

---

## How a new contractor gets access

```
Admin clicks "+ Add contractor" in the portal
    → INSERT into c_contractors (user_id NULL initially)
Admin clicks "Send invite" (or it auto-sends after add)
    → portal calls sb.auth.signInWithOtp({ email, shouldCreateUser:true })
    → Supabase emails a magic link
Contractor clicks the link
    → Lands on the portal already signed in (PKCE flow)
    → c_me() runs: no row with user_id matches → it looks up by email → links user_id → returns the row
    → Portal boots into the contractor view
```

---

## Re-running the migration

The file `supabase/migrations/001_phase1_schema.sql` is idempotent (everything uses `IF NOT EXISTS` / `CREATE OR REPLACE` / `ON CONFLICT DO NOTHING`). Safe to re-run after edits.

---

## Rotating the anon key

The anon key is embedded in `index.html` (~line 555). To rotate:
1. Supabase Dashboard → Settings → API → Roll
2. Update `SUPABASE_ANON` in `index.html`
3. Push to GitHub — Netlify redeploys

Never embed the `service_role` key in the frontend.
