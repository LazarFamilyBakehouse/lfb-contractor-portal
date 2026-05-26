# EmailJS Configuration — Contractor Portal

**Status:** Stubbed in this Phase 1 build. The `notify()` function in `index.html` logs to the console instead of sending. To go live, follow the steps below.

**Why a separate account from the wholesale portal?** Each EmailJS account has its own 200/month free-tier quota. Keeping the two portals on separate accounts means contractor email volume can never deplete the wholesale portal's budget, and vice versa.

---

## Step 1 — Create the second EmailJS account

1. Sign out of any existing EmailJS session
2. Go to https://dashboard.emailjs.com/admin/account/sign-up
3. Sign up using an email you own that's *not* already on EmailJS — e.g. `contractors@lazarfamilybakehouse.com` (or any personal email; the login email doesn't affect what shows up to recipients)
4. Verify the account via the confirmation email

## Step 2 — Add the email service

1. Email Services → Add New Service → Gmail (or Outlook, whichever matches the account you want emails *from*)
2. Connect `info@lazarfamilybakehouse.com` (so contractors reply to the right inbox)
3. Save the generated **Service ID** (e.g. `service_xxxxxxx`)

## Step 3 — Grab the Public Key

1. Account → API Keys → copy the **Public Key**

## Step 4 — Create the 8 templates

For each template, in EmailJS dashboard → Email Templates → Create New:
- **Settings tab:** set `To Email` to `{{to_email}}`, `From Name` to `Lazar Family Bakehouse`, `Reply To` to `info@lazarfamilybakehouse.com`
- **Content tab → Code Editor:** paste the Subject and Body from `PHASE1_EMAIL_TEMPLATES.md`
- Save and note the generated **Template ID** (e.g. `template_xxxxxxx`)

Templates to create (use these exact keys when filling in `EMAILJS_TEMPLATES` in `index.html`):

| Key | Friendly name | When sent |
|---|---|---|
| `shift_new` | New Shift Posted | Admin creates a shift → broadcast to active contractors |
| `signup_confirm` | Shift Sign-up Confirmation | A contractor signs up → confirmation to them |
| `shift_released` | Shift Released | Contractor releases a spot → broadcast to other active contractors |
| `hours_submitted` | Hours Submitted | Contractor submits hours → notification to admin |
| `hours_approved` | Hours Approved | Admin approves hours → notification to contractor with YTD totals |
| `shift_reminder` | 24-hr Reminder | Day-before reminder (requires a scheduled trigger — see below) |
| `shift_cancelled` | Shift Cancelled | Admin cancels a shift → notification to anyone signed up |
| `availability_nudge` | Availability Nudge | Monthly nudge if availability hasn't been updated in 30 days (future feature) |

## Step 5 — Wire credentials into `index.html`

Open `index.html`, find the `CONFIG` block (~line 555), and update:

```js
const EMAILJS_ENABLED   = true;
const EMAILJS_PUBLIC_KEY = 'YOUR_PUBLIC_KEY';
const EMAILJS_SERVICE_ID = 'service_xxxxxxx';
const EMAILJS_TEMPLATES = {
  shift_new:         'template_xxxxxxx',
  signup_confirm:    'template_xxxxxxx',
  shift_released:    'template_xxxxxxx',
  hours_submitted:   'template_xxxxxxx',
  hours_approved:    'template_xxxxxxx',
  shift_reminder:    'template_xxxxxxx',
  shift_cancelled:   'template_xxxxxxx',
  availability_nudge:'template_xxxxxxx'
};
```

Commit + push. Netlify auto-deploys in ~60s. Test by creating a shift → confirm the broadcast email arrives.

---

## Template variables reference

Every send passes `to_email` (the recipient) plus template-specific vars. See `PHASE1_EMAIL_TEMPLATES.md` for the full list per template.

Universal vars present on most templates: `first_name`, `bake_date`, `start_time`, `location`, `portal_url`.

---

## Monthly budget projection (free tier)

For ~8 contractors and ~2 bakes/week:

| Template | Est. sends/month |
|---|---|
| shift_new (broadcast × 8 shifts) | ~64 |
| signup_confirm | ~24 |
| shift_released (broadcast) | ~14 |
| hours_submitted | ~24 |
| hours_approved | ~24 |
| shift_reminder | ~24 |
| shift_cancelled | ~2 |
| **Total** | **~176/month** |

Fits in the 200/mo free tier with margin. If volume grows: EmailJS Personal is $11/mo for 1,000 emails, or move the `shift_reminder` batch to a Supabase Edge Function using Resend (3,000/mo free), the same pattern the wholesale portal's `weekly-reminder` function uses.

---

## Failure handling

`notify()` catches all errors silently (`.catch(err => console.warn(...))`) — a flaky email send never blocks the database write. If you suspect missing emails:

1. EmailJS dashboard → Email History → check sends + errors
2. Browser DevTools console while doing the action — `notify()` logs failures with `[notify]` prefix

---

## Future: 24-hour shift reminder

The `shift_reminder` template requires a scheduled trigger (it has to run automatically without anyone being in the portal). Recommended path:

1. Create a Supabase Edge Function (mirroring `lfb-wholesale-portal/supabase/functions/weekly-reminder/index.ts`)
2. Schedule it daily via `pg_cron` or Supabase Scheduled Functions
3. The function queries `c_shift_signups` joined to `c_shifts` for tomorrow's shifts, sends one email per signup via Resend or via HTTP POST to EmailJS

Phase 1 ships without this — contractors get the sign-up confirmation only. Add this when shift no-shows become a real problem.
