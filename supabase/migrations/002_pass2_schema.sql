-- ============================================================
-- LFB Contractor Portal — Pass 2 Schema Migration
-- Adds PINs, tentative shift status, multi-start-times, and
-- consolidates duplicate same-date shifts from the historical import.
-- Idempotent: safe to re-run.
-- ============================================================

begin;

-- ─── 1. PIN column on contractors ────────────────────────────
alter table public.c_contractors add column if not exists pin text;

-- Generate a random 6-digit PIN for every contractor that doesn't have one.
update public.c_contractors
   set pin = lpad(floor(random() * 1000000)::int::text, 6, '0')
 where pin is null;

-- ─── 2. Tentative shift status ───────────────────────────────
-- Drop the existing check constraint and replace with the expanded set.
alter table public.c_shifts drop constraint if exists c_shifts_status_check;
alter table public.c_shifts
  add constraint c_shifts_status_check
  check (status in ('open', 'tentative', 'cancelled', 'completed'));

-- ─── 3. Stacked start times per shift ────────────────────────
-- start_time stays as the canonical "first" start time for display.
-- start_times array holds the full list of options when there are multiple.
-- If a shift has only one start time, start_times can stay NULL and the UI
-- treats it as a simple shift.
alter table public.c_shifts add column if not exists start_times time[];

-- ─── 4. Chosen start time on signup ──────────────────────────
-- When a contractor signs up for a multi-start shift, they pick one of the
-- options. Stored here on the signup row.
alter table public.c_shift_signups add column if not exists chosen_start_time time;

-- ─── 5. Consolidate duplicate same-date shifts from import ────
-- The historical import created one c_shifts row per worker per date.
-- The natural model is one c_shifts row per date with multiple signups.
-- This block finds dates with multiple BACKFILL shifts and merges them,
-- moving all signups + hour submissions onto the earliest-created shift.
do $$
declare
  v_date         date;
  v_keeper_id    uuid;
  v_other_ids    uuid[];
  v_total_signups int;
begin
  for v_date in (
    select bake_date
      from public.c_shifts
     where notes like 'BACKFILL:%'
     group by bake_date
    having count(*) > 1
  ) loop
    -- Keep the earliest-created shift on that date
    select id
      into v_keeper_id
      from public.c_shifts
     where bake_date = v_date and notes like 'BACKFILL:%'
     order by created_at, id
     limit 1;

    -- Collect the other shift IDs to merge into the keeper
    select coalesce(array_agg(id), '{}'::uuid[])
      into v_other_ids
      from public.c_shifts
     where bake_date = v_date
       and notes like 'BACKFILL:%'
       and id <> v_keeper_id;

    if cardinality(v_other_ids) > 0 then
      -- Move hour submissions first (they have FKs to both signup and shift)
      update public.c_hour_submissions
         set shift_id = v_keeper_id
       where shift_id = any(v_other_ids);

      -- Move signups
      update public.c_shift_signups
         set shift_id = v_keeper_id
       where shift_id = any(v_other_ids);

      -- Drop the empty shift rows
      delete from public.c_shifts where id = any(v_other_ids);
    end if;

    -- Update spots_total on the keeper to reflect actual signups
    select count(*) into v_total_signups
      from public.c_shift_signups
     where shift_id = v_keeper_id;

    update public.c_shifts
       set spots_total = greatest(v_total_signups, 1)
     where id = v_keeper_id;
  end loop;
end $$;

-- ─── 6. Helper RPC: set/rotate a contractor's PIN ────────────
-- Admin-only. Sets the c_contractors.pin and also calls Supabase's auth
-- update to keep auth password in sync (so contractor logs in with email+PIN).
-- Note: this RPC only updates c_contractors.pin. The actual auth password
-- update is done client-side by admin (signUpAdminWithPin) because changing
-- another user's auth password requires service role privileges that aren't
-- safe to expose via RPC. So flow is:
--   Admin sets PIN in UI -> we update c_contractors.pin -> on contractor's
--   first sign-in, they use email + that PIN as password.
--   (For NEW contractors, admin's "Add Contractor" form calls sb.auth.signUp
--   with the PIN as password, which works with anon key.)
create or replace function public.c_set_contractor_pin(p_contractor_id uuid, p_pin text)
returns text
language plpgsql security definer set search_path = public
as $$
begin
  if not c_is_admin() then raise exception 'Admin only'; end if;
  if p_pin is null or length(p_pin) < 4 or length(p_pin) > 12 then
    raise exception 'PIN must be 4-12 chars';
  end if;
  update public.c_contractors set pin = p_pin where id = p_contractor_id;
  return p_pin;
end;
$$;

-- ─── 7. Helper RPC: regenerate a random PIN ──────────────────
create or replace function public.c_regenerate_contractor_pin(p_contractor_id uuid)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_pin text;
begin
  if not c_is_admin() then raise exception 'Admin only'; end if;
  v_pin := lpad(floor(random() * 1000000)::int::text, 6, '0');
  update public.c_contractors set pin = v_pin where id = p_contractor_id;
  return v_pin;
end;
$$;

-- ─── 8. Updated grants on c_contractors so admin can write PIN field ─
-- The original migration restricted contractor self-update to specific fields.
-- We re-grant pin only to authenticated for the admin path (RLS still gates it).
revoke update on public.c_contractors from authenticated;
grant select on public.c_contractors to authenticated;
grant update (first_name, last_name, phone, address_line1, address_line2, city, state, postal_code,
              emergency_contact_name, emergency_contact_phone, emergency_contact_relationship,
              food_handler_card_expires)
  on public.c_contractors to authenticated;
-- Admin writes to pin/role/pay_rate/status/admin_notes go through the existing
-- c_contractors_admin_all RLS policy, which uses c_is_admin().

commit;

-- ============================================================
-- Verify with:
-- select first_name || ' ' || last_name as name, email, pin, status
-- from c_contractors order by first_name;
--
-- select bake_date, count(*) as shifts_on_date,
--   (select count(*) from c_shift_signups s where s.shift_id = sh.id) as signups
-- from c_shifts sh where notes like 'BACKFILL:%'
-- group by bake_date, sh.id
-- order by bake_date desc;
-- ============================================================
