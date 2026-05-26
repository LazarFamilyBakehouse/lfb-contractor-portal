-- ============================================================================
-- LFB Contractor Portal — Phase 1 Schema
-- ============================================================================
-- Project: ylvoswzsijigyezqvaat (shared with wholesale portal; new tables
-- prefixed `c_` to keep them visually grouped)
--
-- Run this file ONCE in the Supabase SQL Editor:
--   Dashboard → SQL Editor → New Query → paste this file → Run
--
-- The file is idempotent: re-running it will skip objects that already exist
-- (uses IF NOT EXISTS / CREATE OR REPLACE everywhere).
-- ============================================================================

-- ─── 0. Extensions ──────────────────────────────────────────────────────────
create extension if not exists "pgcrypto";   -- gen_random_uuid()

-- ─── 1. Helper: is_admin() ──────────────────────────────────────────────────
-- Used in every RLS policy below. Cached per-statement for speed.

create or replace function public.c_is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from public.c_contractors
    where user_id = auth.uid()
      and role = 'admin'
      and status = 'active'
  );
$$;

-- ─── 2. Helper: c_set_updated_at() trigger ─────────────────────────────────
create or replace function public.c_set_updated_at()
returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ============================================================================
-- TABLES
-- ============================================================================

-- ─── c_contractors ──────────────────────────────────────────────────────────
create table if not exists public.c_contractors (
  id                              uuid primary key default gen_random_uuid(),
  user_id                         uuid unique references auth.users(id) on delete set null,
  role                            text not null default 'contractor' check (role in ('contractor','admin')),
  first_name                      text not null default '',
  last_name                       text not null default '',
  email                           text not null unique,
  phone                           text not null default '',
  address_line1                   text default '',
  address_line2                   text default '',
  city                            text default '',
  state                           text default '',
  postal_code                     text default '',
  emergency_contact_name          text default '',
  emergency_contact_phone         text default '',
  emergency_contact_relationship  text default '',
  pay_rate                        numeric(6,2) not null default 0,
  status                          text not null default 'active' check (status in ('active','inactive')),
  admin_notes                     text default '',
  food_handler_card_expires       date,
  availability_last_updated_at    timestamptz,
  created_at                      timestamptz not null default now(),
  updated_at                      timestamptz not null default now()
);

create index if not exists c_contractors_user_id_idx on public.c_contractors(user_id);
create index if not exists c_contractors_status_idx on public.c_contractors(status);

drop trigger if exists c_contractors_set_updated_at on public.c_contractors;
create trigger c_contractors_set_updated_at
  before update on public.c_contractors
  for each row execute function public.c_set_updated_at();

-- ─── c_documents ────────────────────────────────────────────────────────────
create table if not exists public.c_documents (
  id              uuid primary key default gen_random_uuid(),
  contractor_id   uuid not null references public.c_contractors(id) on delete cascade,
  document_type   text not null check (document_type in ('w9','id','food_handler_card','other')),
  file_path       text not null,
  file_name       text not null,
  file_size_bytes int,
  mime_type       text,
  expires_on      date,
  uploaded_at     timestamptz not null default now(),
  uploaded_by     uuid references public.c_contractors(id) on delete set null
);

create index if not exists c_documents_contractor_idx on public.c_documents(contractor_id);
create index if not exists c_documents_expires_idx on public.c_documents(expires_on) where expires_on is not null;

-- ─── c_shifts ───────────────────────────────────────────────────────────────
create table if not exists public.c_shifts (
  id                uuid primary key default gen_random_uuid(),
  bake_date         date not null,
  start_time        time not null,
  end_time          time,
  location          text not null,
  spots_total       int not null check (spots_total > 0),
  notes             text default '',
  status            text not null default 'open' check (status in ('open','cancelled','completed')),
  created_by        uuid references public.c_contractors(id) on delete set null,
  cancelled_reason  text,
  cancelled_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists c_shifts_bake_date_idx on public.c_shifts(bake_date);
create index if not exists c_shifts_status_idx on public.c_shifts(status);

drop trigger if exists c_shifts_set_updated_at on public.c_shifts;
create trigger c_shifts_set_updated_at
  before update on public.c_shifts
  for each row execute function public.c_set_updated_at();

-- ─── c_shift_signups ────────────────────────────────────────────────────────
create table if not exists public.c_shift_signups (
  id              uuid primary key default gen_random_uuid(),
  shift_id        uuid not null references public.c_shifts(id) on delete cascade,
  contractor_id   uuid not null references public.c_contractors(id) on delete cascade,
  signed_up_at    timestamptz not null default now(),
  released_at     timestamptz,
  status          text not null default 'signed_up' check (status in ('signed_up','released','completed'))
);

-- Partial unique: a contractor can have at most one ACTIVE signup per shift
create unique index if not exists c_shift_signups_active_uniq
  on public.c_shift_signups(shift_id, contractor_id)
  where status <> 'released';

create index if not exists c_shift_signups_shift_idx on public.c_shift_signups(shift_id);
create index if not exists c_shift_signups_contractor_idx on public.c_shift_signups(contractor_id, status);

-- ─── c_hour_submissions ─────────────────────────────────────────────────────
create table if not exists public.c_hour_submissions (
  id                   uuid primary key default gen_random_uuid(),
  signup_id            uuid not null unique references public.c_shift_signups(id) on delete cascade,
  shift_id             uuid not null references public.c_shifts(id) on delete cascade,
  contractor_id        uuid not null references public.c_contractors(id) on delete cascade,
  submitted_hours      numeric(5,2) not null check (submitted_hours >= 0),
  submitted_notes      text default '',
  submitted_at         timestamptz not null default now(),
  approved_hours       numeric(5,2),
  approved_pay_rate    numeric(6,2),
  approved_amount      numeric(8,2) generated always as (coalesce(approved_hours,0) * coalesce(approved_pay_rate,0)) stored,
  approved_at          timestamptz,
  approved_by          uuid references public.c_contractors(id) on delete set null,
  status               text not null default 'pending' check (status in ('pending','approved')),
  admin_notes          text default ''
);

create index if not exists c_hour_submissions_status_idx on public.c_hour_submissions(status) where status = 'pending';
create index if not exists c_hour_submissions_ytd_idx on public.c_hour_submissions(contractor_id, approved_at);

-- ─── c_payments ─────────────────────────────────────────────────────────────
create table if not exists public.c_payments (
  id              uuid primary key default gen_random_uuid(),
  contractor_id   uuid not null references public.c_contractors(id) on delete cascade,
  amount          numeric(8,2) not null check (amount >= 0),
  method          text not null check (method in ('check','venmo','zelle','cash','other')),
  paid_on         date not null,
  reference       text default '',
  notes           text default '',
  created_by      uuid references public.c_contractors(id) on delete set null,
  created_at      timestamptz not null default now()
);

create index if not exists c_payments_contractor_idx on public.c_payments(contractor_id, paid_on);

-- ─── c_payment_items ────────────────────────────────────────────────────────
create table if not exists public.c_payment_items (
  payment_id           uuid not null references public.c_payments(id) on delete cascade,
  hour_submission_id   uuid not null unique references public.c_hour_submissions(id) on delete restrict,
  amount               numeric(8,2) not null,
  primary key (payment_id, hour_submission_id)
);

create index if not exists c_payment_items_payment_idx on public.c_payment_items(payment_id);

-- ─── c_availability ─────────────────────────────────────────────────────────
create table if not exists public.c_availability (
  id              uuid primary key default gen_random_uuid(),
  contractor_id   uuid not null references public.c_contractors(id) on delete cascade,
  the_date        date not null,
  status          text not null check (status in ('free','busy','tentative')),
  note            text default '',
  updated_at      timestamptz not null default now(),
  unique (contractor_id, the_date)
);

create index if not exists c_availability_date_status_idx on public.c_availability(the_date, status);
create index if not exists c_availability_contractor_date_idx on public.c_availability(contractor_id, the_date);

drop trigger if exists c_availability_set_updated_at on public.c_availability;
create trigger c_availability_set_updated_at
  before update on public.c_availability
  for each row execute function public.c_set_updated_at();

-- ─── c_settings (key/value config) ──────────────────────────────────────────
create table if not exists public.c_settings (
  key     text primary key,
  value   text not null,
  updated_at timestamptz not null default now()
);

-- Seed defaults (safe to re-run via ON CONFLICT)
insert into public.c_settings(key, value) values
  ('default_shift_location', 'Lazar Family Bakehouse, Englewood, CO'),
  ('default_shift_start_time', '06:00'),
  ('default_shift_end_time',   '12:00'),
  ('portal_url',               'https://contractors.lazarfamilybakehouse.com'),
  ('stale_availability_days',  '30')
on conflict (key) do nothing;

-- ─── c_audit_log ────────────────────────────────────────────────────────────
create table if not exists public.c_audit_log (
  id           bigserial primary key,
  actor_id     uuid references public.c_contractors(id) on delete set null,
  actor_email  text,
  action       text not null,
  entity_type  text not null,
  entity_id    text,
  before       jsonb,
  after        jsonb,
  created_at   timestamptz not null default now()
);

create index if not exists c_audit_entity_idx on public.c_audit_log(entity_type, entity_id, created_at desc);
create index if not exists c_audit_actor_idx on public.c_audit_log(actor_id, created_at desc);

-- ============================================================================
-- AUDIT TRIGGERS
-- ============================================================================
-- These run as SECURITY DEFINER so they can always write to c_audit_log
-- regardless of the caller's RLS context.

create or replace function public.c_audit_write(
  p_action text, p_entity_type text, p_entity_id text,
  p_before jsonb, p_after jsonb
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_contractor public.c_contractors%rowtype;
begin
  select * into v_contractor from public.c_contractors where user_id = auth.uid() limit 1;
  insert into public.c_audit_log(actor_id, actor_email, action, entity_type, entity_id, before, after)
  values (v_contractor.id, coalesce(v_contractor.email, (select email from auth.users where id = auth.uid())),
          p_action, p_entity_type, p_entity_id, p_before, p_after);
end;
$$;

-- Shift change trigger
create or replace function public.c_audit_shifts() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    perform public.c_audit_write('shift.create','shift', new.id::text, null, to_jsonb(new));
  elsif TG_OP = 'UPDATE' then
    if new.status = 'cancelled' and old.status <> 'cancelled' then
      perform public.c_audit_write('shift.cancel','shift', new.id::text, to_jsonb(old), to_jsonb(new));
    else
      perform public.c_audit_write('shift.update','shift', new.id::text, to_jsonb(old), to_jsonb(new));
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists c_shifts_audit on public.c_shifts;
create trigger c_shifts_audit after insert or update on public.c_shifts
  for each row execute function public.c_audit_shifts();

-- Signup trigger (logs sign-ups and releases)
create or replace function public.c_audit_signups() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    perform public.c_audit_write('signup.create','signup', new.id::text, null, to_jsonb(new));
  elsif TG_OP = 'UPDATE' and old.status <> 'released' and new.status = 'released' then
    perform public.c_audit_write('signup.release','signup', new.id::text, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$$;
drop trigger if exists c_signups_audit on public.c_shift_signups;
create trigger c_signups_audit after insert or update on public.c_shift_signups
  for each row execute function public.c_audit_signups();

-- Hour submission trigger
create or replace function public.c_audit_hours() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    perform public.c_audit_write('hours.submit','hours', new.id::text, null, to_jsonb(new));
  elsif TG_OP = 'UPDATE' then
    if new.status = 'approved' and old.status = 'pending' then
      perform public.c_audit_write('hours.approve','hours', new.id::text, to_jsonb(old), to_jsonb(new));
    elsif new.status = 'approved' and old.status = 'approved' then
      perform public.c_audit_write('hours.edit','hours', new.id::text, to_jsonb(old), to_jsonb(new));
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists c_hours_audit on public.c_hour_submissions;
create trigger c_hours_audit after insert or update on public.c_hour_submissions
  for each row execute function public.c_audit_hours();

-- Payment trigger
create or replace function public.c_audit_payments() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if TG_OP = 'INSERT' then
    perform public.c_audit_write('payment.create','payment', new.id::text, null, to_jsonb(new));
  elsif TG_OP = 'UPDATE' then
    perform public.c_audit_write('payment.update','payment', new.id::text, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$$;
drop trigger if exists c_payments_audit on public.c_payments;
create trigger c_payments_audit after insert or update on public.c_payments
  for each row execute function public.c_audit_payments();

-- Profile-edit-by-someone-else trigger (admins editing other contractors)
create or replace function public.c_audit_profile() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if TG_OP = 'UPDATE' and new.user_id is distinct from auth.uid() then
    perform public.c_audit_write('profile.update_other','contractor', new.id::text, to_jsonb(old), to_jsonb(new));
  end if;
  return new;
end;
$$;
drop trigger if exists c_contractors_audit on public.c_contractors;
create trigger c_contractors_audit after update on public.c_contractors
  for each row execute function public.c_audit_profile();

-- Touch availability_last_updated_at on c_contractors when their availability changes
create or replace function public.c_touch_availability_timestamp() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update public.c_contractors
    set availability_last_updated_at = now()
    where id = coalesce(new.contractor_id, old.contractor_id);
  return coalesce(new, old);
end;
$$;
drop trigger if exists c_availability_touch on public.c_availability;
create trigger c_availability_touch after insert or update or delete on public.c_availability
  for each row execute function public.c_touch_availability_timestamp();

-- ============================================================================
-- RPCs
-- ============================================================================

-- Atomic shift release. Returns the affected shift_id so client can refresh
-- and (later) trigger the "spot opened" email.
create or replace function public.c_release_signup(p_signup_id uuid)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_signup public.c_shift_signups%rowtype;
  v_caller_contractor public.c_contractors%rowtype;
begin
  select * into v_caller_contractor from public.c_contractors where user_id = auth.uid();
  if v_caller_contractor.id is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_signup from public.c_shift_signups where id = p_signup_id;
  if v_signup.id is null then
    raise exception 'Signup not found';
  end if;

  -- Only the signup owner or an admin can release
  if v_signup.contractor_id <> v_caller_contractor.id and not c_is_admin() then
    raise exception 'Not authorized';
  end if;

  if v_signup.status = 'released' then
    return v_signup.shift_id;
  end if;

  update public.c_shift_signups
    set status = 'released', released_at = now()
    where id = p_signup_id;

  return v_signup.shift_id;
end;
$$;

-- Atomic approval: snapshots pay_rate, sets approved_at/by, status='approved'
create or replace function public.c_approve_hours(
  p_submission_id uuid,
  p_approved_hours numeric,
  p_admin_notes text default ''
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_caller public.c_contractors%rowtype;
  v_submission public.c_hour_submissions%rowtype;
  v_rate numeric;
begin
  select * into v_caller from public.c_contractors where user_id = auth.uid();
  if not c_is_admin() then
    raise exception 'Admin only';
  end if;

  select * into v_submission from public.c_hour_submissions where id = p_submission_id;
  if v_submission.id is null then raise exception 'Submission not found'; end if;

  select pay_rate into v_rate from public.c_contractors where id = v_submission.contractor_id;

  update public.c_hour_submissions
    set approved_hours    = p_approved_hours,
        approved_pay_rate = v_rate,
        approved_at       = now(),
        approved_by       = v_caller.id,
        status            = 'approved',
        admin_notes       = p_admin_notes
    where id = p_submission_id;

  return p_submission_id;
end;
$$;

-- Re-open an approved hours record for editing (admin only). Doesn't unlock
-- if it's already been paid (referenced in c_payment_items).
create or replace function public.c_reopen_hours(p_submission_id uuid)
returns uuid
language plpgsql security definer set search_path = public
as $$
begin
  if not c_is_admin() then raise exception 'Admin only'; end if;
  if exists (select 1 from public.c_payment_items where hour_submission_id = p_submission_id) then
    raise exception 'Already paid — cannot reopen';
  end if;
  update public.c_hour_submissions
    set status = 'pending', approved_at = null, approved_by = null
    where id = p_submission_id;
  return p_submission_id;
end;
$$;

-- Bulk-set availability for a range of dates. Used when the contractor
-- drag-selects in the calendar UI.
create or replace function public.c_set_availability_bulk(
  p_dates  date[],
  p_status text,
  p_note   text default ''
) returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_caller public.c_contractors%rowtype;
  v_count  int := 0;
  v_date   date;
begin
  select * into v_caller from public.c_contractors where user_id = auth.uid();
  if v_caller.id is null then raise exception 'Not authenticated'; end if;
  if p_status not in ('free','busy','tentative') then raise exception 'Invalid status'; end if;

  foreach v_date in array p_dates loop
    insert into public.c_availability(contractor_id, the_date, status, note)
      values (v_caller.id, v_date, p_status, p_note)
    on conflict (contractor_id, the_date)
      do update set status = excluded.status, note = excluded.note, updated_at = now();
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- Admin bulk-clear of one's own availability for a date range
create or replace function public.c_clear_availability(p_start date, p_end date)
returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_caller public.c_contractors%rowtype;
  v_count  int;
begin
  select * into v_caller from public.c_contractors where user_id = auth.uid();
  if v_caller.id is null then raise exception 'Not authenticated'; end if;

  with del as (
    delete from public.c_availability
     where contractor_id = v_caller.id
       and the_date between p_start and p_end
     returning 1
  )
  select count(*) into v_count from del;
  return coalesce(v_count, 0);
end;
$$;

-- Aggregate availability counts per day for a range. Used by the admin
-- planning calendar heatmap. Returns one row per day in the range.
create or replace function public.c_availability_counts(p_start date, p_end date)
returns table(the_date date, free_count int, busy_count int, tentative_count int, total_active int)
language plpgsql security definer set search_path = public
as $$
begin
  return query
  with all_days as (
    select generate_series(p_start, p_end, interval '1 day')::date as d
  ),
  active_total as (
    select count(*)::int as n from public.c_contractors where status = 'active'
  )
  select
    ad.d as the_date,
    coalesce(sum(case when a.status = 'free'      then 1 else 0 end)::int, 0) as free_count,
    coalesce(sum(case when a.status = 'busy'      then 1 else 0 end)::int, 0) as busy_count,
    coalesce(sum(case when a.status = 'tentative' then 1 else 0 end)::int, 0) as tentative_count,
    (select n from active_total) as total_active
  from all_days ad
  left join public.c_availability a on a.the_date = ad.d
  group by ad.d
  order by ad.d;
end;
$$;

-- Admin-only: who's free on a specific date (with emails for the email picker)
create or replace function public.c_available_contractors(p_date date)
returns table(contractor_id uuid, first_name text, last_name text, email text, status text, note text)
language plpgsql security definer set search_path = public
as $$
begin
  if not c_is_admin() then raise exception 'Admin only'; end if;
  return query
  select c.id, c.first_name, c.last_name, c.email, a.status, a.note
  from public.c_contractors c
  left join public.c_availability a on a.contractor_id = c.id and a.the_date = p_date
  where c.status = 'active' and c.role = 'contractor'
  order by
    case a.status when 'free' then 1 when 'tentative' then 2 when 'busy' then 4 else 3 end,
    c.first_name;
end;
$$;

-- Per-contractor YTD: hours, paid, pending. Used by admin dashboard and
-- contractor "My Payments" view.
create or replace function public.c_ytd_summary(p_year int default extract(year from current_date)::int)
returns table(
  contractor_id     uuid,
  first_name        text,
  last_name         text,
  email             text,
  pay_rate          numeric,
  status            text,
  approved_hours    numeric,
  pending_hours     numeric,
  earned_amount     numeric,   -- approved hours × rate
  paid_amount       numeric,   -- sum of c_payments
  unpaid_amount     numeric,   -- earned − paid
  food_handler_card_expires date,
  availability_last_updated_at timestamptz
)
language plpgsql security definer set search_path = public
as $$
begin
  -- Contractors see only their own row; admins see everyone.
  return query
  with bounds as (
    select make_date(p_year, 1, 1) as y_start,
           make_date(p_year, 12, 31) as y_end
  ),
  per_c as (
    select
      c.id                       as contractor_id,
      c.first_name, c.last_name, c.email, c.pay_rate, c.status,
      c.food_handler_card_expires, c.availability_last_updated_at,
      coalesce(sum(case when h.status = 'approved' then h.approved_hours end),0) as approved_hours,
      coalesce(sum(case when h.status = 'pending'  then h.submitted_hours end),0) as pending_hours,
      coalesce(sum(case when h.status = 'approved' then h.approved_amount end),0) as earned_amount
    from public.c_contractors c
    left join public.c_hour_submissions h
      on h.contractor_id = c.id
      and (h.approved_at is null or h.approved_at >= (select y_start from bounds))
      and (h.approved_at is null or h.approved_at <  (select y_end from bounds) + interval '1 day')
    where (c_is_admin() or c.user_id = auth.uid())
    group by c.id
  ),
  paid_per_c as (
    select p.contractor_id, coalesce(sum(p.amount),0) as paid_amount
    from public.c_payments p
    where p.paid_on between (select y_start from bounds) and (select y_end from bounds)
    group by p.contractor_id
  )
  select
    per_c.contractor_id, per_c.first_name, per_c.last_name, per_c.email,
    per_c.pay_rate, per_c.status,
    per_c.approved_hours, per_c.pending_hours, per_c.earned_amount,
    coalesce(paid_per_c.paid_amount, 0) as paid_amount,
    (per_c.earned_amount - coalesce(paid_per_c.paid_amount,0)) as unpaid_amount,
    per_c.food_handler_card_expires, per_c.availability_last_updated_at
  from per_c
  left join paid_per_c on paid_per_c.contractor_id = per_c.contractor_id
  order by per_c.first_name;
end;
$$;

-- Get the calling user's contractor row. Used for auth bootstrapping in JS.
-- On first sign-in this auto-links the auth user to their pre-created
-- c_contractors row by email (admin creates the row first; magic-link from
-- Supabase Auth creates the auth user; c_me() links them on first call).
create or replace function public.c_me()
returns public.c_contractors
language plpgsql security definer set search_path = public
as $$
declare
  v_contractor public.c_contractors%rowtype;
  v_email      text;
begin
  -- Already linked
  select * into v_contractor from public.c_contractors where user_id = auth.uid() limit 1;
  if found then return v_contractor; end if;

  -- Not linked — try to match by email
  select email into v_email from auth.users where id = auth.uid();
  if v_email is null then
    -- No auth user; return null row
    return v_contractor;
  end if;

  update public.c_contractors
     set user_id = auth.uid()
   where lower(email) = lower(v_email)
     and user_id is null
   returning * into v_contractor;

  return v_contractor;  -- may be null if no matching c_contractors row exists yet
end;
$$;

-- Send an invite to a contractor's email (admin only). Returns success;
-- the actual email is sent by Supabase Auth via the JS client.
-- This RPC is just a permissions gate — JS calls sb.auth.signInWithOtp
-- after confirming c_can_invite returns true.
create or replace function public.c_can_invite(p_email text)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not c_is_admin() then return false; end if;
  return exists (select 1 from public.c_contractors where lower(email) = lower(p_email) and status = 'active');
end;
$$;

-- Mark a shift's signups as completed once the shift date passes.
-- Called nightly by pg_cron or whenever convenient — idempotent.
create or replace function public.c_complete_past_shifts()
returns int
language plpgsql security definer set search_path = public
as $$
declare v_count int;
begin
  with upd as (
    update public.c_shifts
       set status = 'completed'
     where status = 'open' and bake_date < current_date
     returning 1
  )
  select count(*) into v_count from upd;
  return coalesce(v_count, 0);
end;
$$;

-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================

alter table public.c_contractors      enable row level security;
alter table public.c_documents        enable row level security;
alter table public.c_shifts           enable row level security;
alter table public.c_shift_signups    enable row level security;
alter table public.c_hour_submissions enable row level security;
alter table public.c_payments         enable row level security;
alter table public.c_payment_items    enable row level security;
alter table public.c_availability     enable row level security;
alter table public.c_audit_log        enable row level security;
alter table public.c_settings         enable row level security;

-- ─── c_contractors ──────────────────────────────────────────────────────────
drop policy if exists c_contractors_admin_all on public.c_contractors;
create policy c_contractors_admin_all on public.c_contractors
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

drop policy if exists c_contractors_self_select on public.c_contractors;
create policy c_contractors_self_select on public.c_contractors
  for select to authenticated using (user_id = auth.uid());

drop policy if exists c_contractors_self_update on public.c_contractors;
create policy c_contractors_self_update on public.c_contractors
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Column-level grants: contractor self-update cannot change role/pay/status/admin_notes
-- The check above allows the row, but we revoke writes on the protected columns:
revoke update on public.c_contractors from authenticated;
grant select on public.c_contractors to authenticated;
grant update (first_name, last_name, phone, address_line1, address_line2, city, state, postal_code,
              emergency_contact_name, emergency_contact_phone, emergency_contact_relationship,
              food_handler_card_expires)
  on public.c_contractors to authenticated;

-- ─── c_documents ────────────────────────────────────────────────────────────
drop policy if exists c_documents_admin_all on public.c_documents;
create policy c_documents_admin_all on public.c_documents
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

drop policy if exists c_documents_self_select on public.c_documents;
create policy c_documents_self_select on public.c_documents
  for select to authenticated
  using (contractor_id in (select id from public.c_contractors where user_id = auth.uid()));

drop policy if exists c_documents_self_insert on public.c_documents;
create policy c_documents_self_insert on public.c_documents
  for insert to authenticated
  with check (contractor_id in (select id from public.c_contractors where user_id = auth.uid()));

drop policy if exists c_documents_self_delete on public.c_documents;
create policy c_documents_self_delete on public.c_documents
  for delete to authenticated
  using (contractor_id in (select id from public.c_contractors where user_id = auth.uid()));

-- ─── c_shifts ───────────────────────────────────────────────────────────────
drop policy if exists c_shifts_admin_all on public.c_shifts;
create policy c_shifts_admin_all on public.c_shifts
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

drop policy if exists c_shifts_read_all on public.c_shifts;
create policy c_shifts_read_all on public.c_shifts
  for select to authenticated using (true);

-- ─── c_shift_signups ────────────────────────────────────────────────────────
drop policy if exists c_shift_signups_admin_all on public.c_shift_signups;
create policy c_shift_signups_admin_all on public.c_shift_signups
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

-- Contractors can read all signups (needed to compute "X / Y filled" per shift)
drop policy if exists c_shift_signups_read on public.c_shift_signups;
create policy c_shift_signups_read on public.c_shift_signups
  for select to authenticated using (true);

drop policy if exists c_shift_signups_self_insert on public.c_shift_signups;
create policy c_shift_signups_self_insert on public.c_shift_signups
  for insert to authenticated
  with check (contractor_id in (select id from public.c_contractors where user_id = auth.uid()));

-- Releases go through the c_release_signup RPC (SECURITY DEFINER); no direct update policy.

-- ─── c_hour_submissions ─────────────────────────────────────────────────────
drop policy if exists c_hour_submissions_admin_all on public.c_hour_submissions;
create policy c_hour_submissions_admin_all on public.c_hour_submissions
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

drop policy if exists c_hour_submissions_self_select on public.c_hour_submissions;
create policy c_hour_submissions_self_select on public.c_hour_submissions
  for select to authenticated
  using (contractor_id in (select id from public.c_contractors where user_id = auth.uid()));

drop policy if exists c_hour_submissions_self_insert on public.c_hour_submissions;
create policy c_hour_submissions_self_insert on public.c_hour_submissions
  for insert to authenticated
  with check (contractor_id in (select id from public.c_contractors where user_id = auth.uid())
              and status = 'pending');

drop policy if exists c_hour_submissions_self_update on public.c_hour_submissions;
create policy c_hour_submissions_self_update on public.c_hour_submissions
  for update to authenticated
  using (contractor_id in (select id from public.c_contractors where user_id = auth.uid())
         and status = 'pending')
  with check (status = 'pending');

-- ─── c_payments / c_payment_items ───────────────────────────────────────────
drop policy if exists c_payments_admin_all on public.c_payments;
create policy c_payments_admin_all on public.c_payments
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

drop policy if exists c_payments_self_select on public.c_payments;
create policy c_payments_self_select on public.c_payments
  for select to authenticated
  using (contractor_id in (select id from public.c_contractors where user_id = auth.uid()));

drop policy if exists c_payment_items_admin_all on public.c_payment_items;
create policy c_payment_items_admin_all on public.c_payment_items
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

drop policy if exists c_payment_items_self_select on public.c_payment_items;
create policy c_payment_items_self_select on public.c_payment_items
  for select to authenticated
  using (payment_id in (select id from public.c_payments
                        where contractor_id in (select id from public.c_contractors where user_id = auth.uid())));

-- ─── c_availability ─────────────────────────────────────────────────────────
drop policy if exists c_availability_admin_all on public.c_availability;
create policy c_availability_admin_all on public.c_availability
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

drop policy if exists c_availability_self_all on public.c_availability;
create policy c_availability_self_all on public.c_availability
  for all to authenticated
  using (contractor_id in (select id from public.c_contractors where user_id = auth.uid()))
  with check (contractor_id in (select id from public.c_contractors where user_id = auth.uid()));

-- ─── c_audit_log ────────────────────────────────────────────────────────────
drop policy if exists c_audit_log_admin_select on public.c_audit_log;
create policy c_audit_log_admin_select on public.c_audit_log
  for select to authenticated using (c_is_admin());
-- No insert/update/delete policies — only SECURITY DEFINER trigger function can write.

-- ─── c_settings ─────────────────────────────────────────────────────────────
drop policy if exists c_settings_admin_all on public.c_settings;
create policy c_settings_admin_all on public.c_settings
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

drop policy if exists c_settings_read_all on public.c_settings;
create policy c_settings_read_all on public.c_settings
  for select to authenticated using (true);

-- ============================================================================
-- STORAGE BUCKET FOR DOCUMENTS
-- ============================================================================
-- Bucket setup must be done via the Supabase dashboard:
--   Storage → New bucket → name: "contractor-documents" → Private (NOT public)
-- After creating the bucket, run these policies:

-- Allow authenticated users to upload to their own folder (named by contractor_id)
insert into storage.buckets (id, name, public)
  values ('contractor-documents', 'contractor-documents', false)
  on conflict (id) do nothing;

drop policy if exists "c_docs_self_select" on storage.objects;
create policy "c_docs_self_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'contractor-documents'
    and (
      c_is_admin()
      or (storage.foldername(name))[1] in (select id::text from public.c_contractors where user_id = auth.uid())
    )
  );

drop policy if exists "c_docs_self_insert" on storage.objects;
create policy "c_docs_self_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'contractor-documents'
    and (
      c_is_admin()
      or (storage.foldername(name))[1] in (select id::text from public.c_contractors where user_id = auth.uid())
    )
  );

drop policy if exists "c_docs_self_delete" on storage.objects;
create policy "c_docs_self_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'contractor-documents'
    and (
      c_is_admin()
      or (storage.foldername(name))[1] in (select id::text from public.c_contractors where user_id = auth.uid())
    )
  );

-- ============================================================================
-- BOOTSTRAP: First admin
-- ============================================================================
-- After running this migration, create the first admin manually:
--   1. Supabase Dashboard → Authentication → Users → Add user
--      Email: info@lazarfamilybakehouse.com
--      Password: (your existing wholesale-portal password — same auth user is reused)
--      (If the user already exists from wholesale portal, skip this step.)
--   2. Note the UUID for that user (Auth → Users → click row → copy ID).
--   3. Run this insert in the SQL editor, replacing <UUID>:
--
--      insert into public.c_contractors
--        (user_id, role, first_name, last_name, email, pay_rate, status)
--      values
--        ('<UUID>', 'admin', 'Jake', 'Lazar', 'info@lazarfamilybakehouse.com', 0, 'active');
--
--   4. Repeat for Victoria once you send her email address.
-- ============================================================================
