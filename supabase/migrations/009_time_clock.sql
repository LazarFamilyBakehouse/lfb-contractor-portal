-- ============================================================
-- LFB Contractor Portal - Clock in / clock out (migration 009)
-- Contractors clock in and out from the portal (phone or desktop).
-- Each clock-out becomes a "submitted" time entry that an admin
-- approves (or adjusts, or rejects). Approval creates the approved
-- c_hour_submissions row (plus the shift + signup it hangs off), so
-- pay, YTD and Payments all keep working exactly as before.
-- Idempotent.
-- ============================================================
begin;

create table if not exists public.c_time_entries (
  id                  uuid primary key default gen_random_uuid(),
  contractor_id       uuid not null references public.c_contractors(id) on delete cascade,
  shift_id            uuid references public.c_shifts(id) on delete set null,
  work_date           date not null,                      -- clock-in day, Denver time
  clock_in            timestamptz not null default now(),
  clock_out           timestamptz,
  break_minutes       int not null default 0 check (break_minutes >= 0 and break_minutes <= 480),
  worked_hours        numeric(5,2),                       -- filled at clock-out (minus break)
  notes               text default '',
  in_lat              double precision, in_lng double precision,
  out_lat             double precision, out_lng double precision,
  status              text not null default 'open' check (status in ('open','submitted','approved','rejected')),
  approved_hours      numeric(5,2),
  approved_at         timestamptz,
  approved_by         uuid references public.c_contractors(id) on delete set null,
  admin_notes         text default '',
  hour_submission_id  uuid references public.c_hour_submissions(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists c_time_entries_contractor_idx on public.c_time_entries(contractor_id, clock_in desc);
create index if not exists c_time_entries_status_idx on public.c_time_entries(status) where status in ('open','submitted');
-- only one open entry per contractor at a time
create unique index if not exists c_time_entries_one_open on public.c_time_entries(contractor_id) where status = 'open';

drop trigger if exists c_time_entries_touch on public.c_time_entries;
create trigger c_time_entries_touch before update on public.c_time_entries
  for each row execute function public.c_set_updated_at();

alter table public.c_time_entries enable row level security;
drop policy if exists c_time_entries_admin_all on public.c_time_entries;
create policy c_time_entries_admin_all on public.c_time_entries
  for all to authenticated using (c_is_admin()) with check (c_is_admin());
drop policy if exists c_time_entries_own_read on public.c_time_entries;
create policy c_time_entries_own_read on public.c_time_entries
  for select to authenticated
  using (contractor_id in (select id from public.c_contractors where user_id = auth.uid()));
-- all writes go through the RPCs below (security definer)

-- ── helper: hours between two stamps minus break, 2 decimals ───────
create or replace function public.c_hours_between(p_in timestamptz, p_out timestamptz, p_break int default 0)
returns numeric language sql immutable as $$
  select greatest(0, round((extract(epoch from (p_out - p_in)) / 3600.0 - coalesce(p_break,0) / 60.0)::numeric, 2));
$$;

-- ── Contractor: clock in ───────────────────────────────────────────
create or replace function public.c_clock_in(p_shift_id uuid default null, p_notes text default '', p_lat double precision default null, p_lng double precision default null)
returns public.c_time_entries
language plpgsql security definer set search_path = public as $$
declare me public.c_contractors%rowtype; v_today date; v_shift uuid; te public.c_time_entries%rowtype;
begin
  select * into me from public.c_contractors where user_id = auth.uid();
  if me.id is null or me.status <> 'active' then raise exception 'No active contractor profile'; end if;
  if exists (select 1 from public.c_time_entries where contractor_id = me.id and status = 'open') then
    raise exception 'You are already clocked in';
  end if;
  v_today := (now() at time zone 'America/Denver')::date;

  v_shift := p_shift_id;
  if v_shift is null then
    -- auto-match: a shift today that this contractor is signed up for
    select s.shift_id into v_shift
      from public.c_shift_signups s join public.c_shifts sh on sh.id = s.shift_id
     where s.contractor_id = me.id and s.status <> 'released' and sh.bake_date = v_today and sh.status <> 'cancelled'
     order by sh.start_time limit 1;
  end if;

  insert into public.c_time_entries (contractor_id, shift_id, work_date, clock_in, notes, in_lat, in_lng, status)
  values (me.id, v_shift, v_today, now(), coalesce(p_notes,''), p_lat, p_lng, 'open')
  returning * into te;
  return te;
end $$;

-- ── Contractor: clock out (entry becomes "submitted") ──────────────
create or replace function public.c_clock_out(p_entry_id uuid default null, p_notes text default null, p_break_minutes int default 0, p_lat double precision default null, p_lng double precision default null)
returns public.c_time_entries
language plpgsql security definer set search_path = public as $$
declare me public.c_contractors%rowtype; te public.c_time_entries%rowtype;
begin
  select * into me from public.c_contractors where user_id = auth.uid();
  if me.id is null then raise exception 'No contractor profile'; end if;
  if p_entry_id is null then
    select * into te from public.c_time_entries where contractor_id = me.id and status = 'open' limit 1;
  else
    select * into te from public.c_time_entries where id = p_entry_id;
  end if;
  if te.id is null then raise exception 'No open time entry'; end if;
  if te.contractor_id <> me.id and not c_is_admin() then raise exception 'Not your entry'; end if;
  if te.status <> 'open' then raise exception 'Already clocked out'; end if;

  update public.c_time_entries set
    clock_out     = now(),
    break_minutes = greatest(0, coalesce(p_break_minutes,0)),
    worked_hours  = c_hours_between(clock_in, now(), greatest(0, coalesce(p_break_minutes,0))),
    notes         = case when p_notes is null then notes else trim(both from concat_ws(' / ', nullif(notes,''), nullif(p_notes,''))) end,
    out_lat = p_lat, out_lng = p_lng,
    status        = 'submitted'
  where id = te.id
  returning * into te;
  return te;
end $$;

-- ── Contractor: cancel an accidental clock-in (open entries only) ──
create or replace function public.c_time_entry_cancel(p_entry_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me public.c_contractors%rowtype; te public.c_time_entries%rowtype;
begin
  select * into me from public.c_contractors where user_id = auth.uid();
  select * into te from public.c_time_entries where id = p_entry_id;
  if te.id is null then raise exception 'Entry not found'; end if;
  if te.contractor_id <> me.id and not c_is_admin() then raise exception 'Not your entry'; end if;
  if te.status not in ('open','submitted') then raise exception 'Only open or unapproved entries can be removed'; end if;
  delete from public.c_time_entries where id = te.id;
end $$;

-- ── Admin: approve (optionally adjusting times/hours) ──────────────
-- Creates or reuses: the shift for that date, the contractor's signup,
-- and the c_hour_submissions row (approved, pay rate snapshotted).
create or replace function public.c_time_entry_approve(
  p_entry_id uuid,
  p_approved_hours numeric default null,
  p_admin_notes text default '',
  p_clock_in timestamptz default null,
  p_clock_out timestamptz default null,
  p_break_minutes int default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_admin public.c_contractors%rowtype; e public.c_time_entries%rowtype;
  v_hours numeric; v_rate numeric; v_shift uuid; v_signup uuid; v_sub uuid; v_date date;
  v_in timestamptz; v_out timestamptz; v_break int;
begin
  select * into v_admin from public.c_contractors where user_id = auth.uid();
  if not c_is_admin() then raise exception 'Admin only'; end if;

  select * into e from public.c_time_entries where id = p_entry_id for update;
  if e.id is null then raise exception 'Entry not found'; end if;
  if e.status = 'approved' then raise exception 'Already approved'; end if;

  v_in    := coalesce(p_clock_in, e.clock_in);
  v_out   := coalesce(p_clock_out, e.clock_out, now());
  v_break := coalesce(p_break_minutes, e.break_minutes, 0);
  if v_out <= v_in then raise exception 'Clock-out must be after clock-in'; end if;
  v_hours := coalesce(p_approved_hours, c_hours_between(v_in, v_out, v_break));
  if v_hours < 0 or v_hours > 24 then raise exception 'Approved hours must be between 0 and 24'; end if;
  v_date  := (v_in at time zone 'America/Denver')::date;

  select pay_rate into v_rate from public.c_contractors where id = e.contractor_id;

  -- shift for that day
  v_shift := e.shift_id;
  if v_shift is null then
    select id into v_shift from public.c_shifts where bake_date = v_date and status <> 'cancelled' order by created_at limit 1;
  end if;
  if v_shift is null then
    insert into public.c_shifts (bake_date, start_time, location, spots_total, notes, status, created_by)
    values (v_date, (v_in at time zone 'America/Denver')::time, 'Lazar Family Bakehouse', 4, 'Created from time clock', 'completed', v_admin.id)
    returning id into v_shift;
  end if;

  -- signup
  select id into v_signup from public.c_shift_signups where shift_id = v_shift and contractor_id = e.contractor_id and status <> 'released' limit 1;
  if v_signup is null then
    insert into public.c_shift_signups (shift_id, contractor_id, status, signed_up_at)
    values (v_shift, e.contractor_id, 'completed', v_in) returning id into v_signup;
  else
    update public.c_shift_signups set status = 'completed' where id = v_signup and status = 'signed_up';
  end if;

  -- hour submission (one per signup): create approved, or approve the existing pending one
  select id into v_sub from public.c_hour_submissions where signup_id = v_signup;
  if v_sub is null then
    insert into public.c_hour_submissions (signup_id, shift_id, contractor_id, submitted_hours, submitted_notes, submitted_at,
                                           approved_hours, approved_pay_rate, approved_at, approved_by, status, admin_notes)
    values (v_signup, v_shift, e.contractor_id, coalesce(e.worked_hours, v_hours), 'Time clock: ' || coalesce(e.notes,''), coalesce(e.clock_out, now()),
            v_hours, v_rate, now(), v_admin.id, 'approved', coalesce(p_admin_notes,''))
    returning id into v_sub;
  else
    if exists (select 1 from public.c_payment_items where hour_submission_id = v_sub) then
      raise exception 'Hours for this shift were already approved and paid';
    end if;
    update public.c_hour_submissions
       set approved_hours = v_hours, approved_pay_rate = v_rate, approved_at = now(), approved_by = v_admin.id,
           status = 'approved', admin_notes = coalesce(p_admin_notes,'')
     where id = v_sub;
  end if;

  update public.c_time_entries set
    clock_in = v_in, clock_out = v_out, break_minutes = v_break,
    worked_hours = c_hours_between(v_in, v_out, v_break),
    shift_id = v_shift, work_date = v_date,
    status = 'approved', approved_hours = v_hours, approved_at = now(), approved_by = v_admin.id,
    admin_notes = coalesce(p_admin_notes,''), hour_submission_id = v_sub
  where id = e.id;

  return v_sub;
end $$;

-- ── Admin: reject ──────────────────────────────────────────────────
create or replace function public.c_time_entry_reject(p_entry_id uuid, p_admin_notes text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not c_is_admin() then raise exception 'Admin only'; end if;
  update public.c_time_entries set status = 'rejected', admin_notes = coalesce(p_admin_notes,''),
         clock_out = coalesce(clock_out, now())
   where id = p_entry_id and status in ('open','submitted');
  if not found then raise exception 'Entry not found or already approved'; end if;
end $$;

grant execute on function public.c_clock_in(uuid, text, double precision, double precision) to authenticated;
grant execute on function public.c_clock_out(uuid, text, int, double precision, double precision) to authenticated;
grant execute on function public.c_time_entry_cancel(uuid) to authenticated;
grant execute on function public.c_time_entry_approve(uuid, numeric, text, timestamptz, timestamptz, int) to authenticated;
grant execute on function public.c_time_entry_reject(uuid, text) to authenticated;

commit;

select 'c_time_entries ready' as result, count(*) as rows from public.c_time_entries;
