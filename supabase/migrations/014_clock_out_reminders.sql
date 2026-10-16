-- ============================================================
-- LFB Contractor Portal - migration 014
-- Clock-out reminders + contractor self-edit of time entries.
--  * c_time_entries.expected_end: when the clocked-in window ends
--    (set at clock-in from the matched shift window; 8h fallback)
--  * clock out at an earlier "actually finished at" time
--  * c_time_entry_edit: fix your own times before admin approves
--    (originals kept, admin sees the edit)
--  * c_clock_out_reminders_due(): what the cron emails
--  * pg_cron pings the notify function every 10 minutes
-- Idempotent.
-- ============================================================
begin;

alter table public.c_time_entries add column if not exists expected_end timestamptz;
alter table public.c_time_entries add column if not exists reminder_count int not null default 0;
alter table public.c_time_entries add column if not exists last_reminder_at timestamptz;
alter table public.c_time_entries add column if not exists edited_at timestamptz;
alter table public.c_time_entries add column if not exists original_clock_in timestamptz;
alter table public.c_time_entries add column if not exists original_clock_out timestamptz;

-- expected end of a shift window for a contractor on a given shift (Denver wall time -> instant)
create or replace function public.c_shift_window_end(p_shift uuid, p_contractor uuid, p_clock_in timestamptz)
returns timestamptz language plpgsql stable as $$
declare sh public.c_shifts; v_chosen time; v_end time; i int;
begin
  if p_shift is null then return p_clock_in + interval '8 hours'; end if;
  select * into sh from public.c_shifts where id = p_shift;
  if sh.id is null then return p_clock_in + interval '8 hours'; end if;
  select chosen_start_time into v_chosen from public.c_shift_signups
   where shift_id = p_shift and contractor_id = p_contractor and status <> 'released' limit 1;
  v_end := sh.end_time;
  if sh.start_times is not null and array_length(sh.start_times, 1) > 0 then
    i := null;
    if v_chosen is not null then
      for k in 1..array_length(sh.start_times, 1) loop
        if sh.start_times[k] = v_chosen then i := k; end if;
      end loop;
    end if;
    if i is null then i := 1; end if;
    if sh.end_times is not null and array_length(sh.end_times, 1) >= i and sh.end_times[i] is not null then v_end := sh.end_times[i]; end if;
  end if;
  if v_end is null then return p_clock_in + interval '8 hours'; end if;
  return ((sh.bake_date::text || ' ' || v_end::text)::timestamp at time zone 'America/Denver');
end $$;

-- clock in: same as before, plus expected_end
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
    select s.shift_id into v_shift
      from public.c_shift_signups s join public.c_shifts sh on sh.id = s.shift_id
     where s.contractor_id = me.id and s.status <> 'released' and sh.bake_date = v_today and sh.status <> 'cancelled'
     order by sh.start_time limit 1;
  end if;
  insert into public.c_time_entries (contractor_id, shift_id, work_date, clock_in, notes, in_lat, in_lng, status, expected_end)
  values (me.id, v_shift, v_today, now(), coalesce(p_notes,''), p_lat, p_lng, 'open', public.c_shift_window_end(v_shift, me.id, now()))
  returning * into te;
  return te;
end $$;

-- clock out: optional "actually finished at" (must be after clock-in and not in the future)
drop function if exists public.c_clock_out(uuid, text, int, double precision, double precision);
create or replace function public.c_clock_out(p_entry_id uuid default null, p_notes text default null, p_break_minutes int default 0, p_lat double precision default null, p_lng double precision default null, p_clock_out timestamptz default null)
returns public.c_time_entries
language plpgsql security definer set search_path = public as $$
declare me public.c_contractors%rowtype; te public.c_time_entries%rowtype; v_out timestamptz;
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
  v_out := coalesce(p_clock_out, now());
  if v_out > now() + interval '2 minutes' then raise exception 'Clock-out time cannot be in the future'; end if;
  if v_out <= te.clock_in then raise exception 'Clock-out must be after clock-in'; end if;

  update public.c_time_entries set
    clock_out     = v_out,
    break_minutes = greatest(0, coalesce(p_break_minutes,0)),
    worked_hours  = c_hours_between(clock_in, v_out, greatest(0, coalesce(p_break_minutes,0))),
    notes         = case when p_notes is null then notes else trim(both from concat_ws(' / ', nullif(notes,''), nullif(p_notes,''))) end,
    out_lat = p_lat, out_lng = p_lng,
    status        = 'submitted'
  where id = te.id
  returning * into te;
  return te;
end $$;
grant execute on function public.c_clock_out(uuid, text, int, double precision, double precision, timestamptz) to authenticated;

-- contractor edits their own not-yet-approved entry
create or replace function public.c_time_entry_edit(p_entry_id uuid, p_clock_in timestamptz, p_clock_out timestamptz, p_notes text default null)
returns public.c_time_entries
language plpgsql security definer set search_path = public as $$
declare me public.c_contractors%rowtype; te public.c_time_entries%rowtype;
begin
  select * into me from public.c_contractors where user_id = auth.uid();
  select * into te from public.c_time_entries where id = p_entry_id;
  if te.id is null then raise exception 'Entry not found'; end if;
  if te.contractor_id <> me.id and not c_is_admin() then raise exception 'Not your entry'; end if;
  if te.status <> 'submitted' then raise exception 'Only entries waiting for approval can be edited'; end if;
  if p_clock_in is null or p_clock_out is null then raise exception 'Both times are required'; end if;
  if p_clock_out <= p_clock_in then raise exception 'Clock-out must be after clock-in'; end if;
  if p_clock_out > now() + interval '2 minutes' then raise exception 'Clock-out time cannot be in the future'; end if;
  if p_clock_out - p_clock_in > interval '24 hours' then raise exception 'A shift cannot be longer than 24 hours'; end if;
  update public.c_time_entries set
    original_clock_in  = coalesce(original_clock_in, clock_in),
    original_clock_out = coalesce(original_clock_out, clock_out),
    clock_in = p_clock_in, clock_out = p_clock_out,
    work_date = (p_clock_in at time zone 'America/Denver')::date,
    worked_hours = c_hours_between(p_clock_in, p_clock_out, break_minutes),
    notes = case when p_notes is null then notes else trim(both from concat_ws(' / ', nullif(notes,''), nullif(p_notes,''))) end,
    edited_at = now()
  where id = te.id
  returning * into te;
  return te;
end $$;
grant execute on function public.c_time_entry_edit(uuid, timestamptz, timestamptz, text) to authenticated;

-- what the reminder job should email right now (service role only)
create or replace function public.c_clock_out_reminders_due()
returns table(entry_id uuid, email text, first_name text, clock_in timestamptz, expected_end timestamptz, reminder_count int)
language sql security definer set search_path = public as $$
  select e.id, c.email, c.first_name, e.clock_in, coalesce(e.expected_end, e.clock_in + interval '8 hours'), e.reminder_count
  from public.c_time_entries e join public.c_contractors c on c.id = e.contractor_id
  where e.status = 'open' and c.status = 'active'
    and now() >= coalesce(e.expected_end, e.clock_in + interval '8 hours') + interval '5 minutes'
    and e.reminder_count < 3
    and (e.last_reminder_at is null or e.last_reminder_at < now() - interval '3 hours')
    and c.email not like '%@pending.lfb'
$$;
revoke all on function public.c_clock_out_reminders_due() from public, anon, authenticated;

commit;

-- cron: every 10 minutes ask the notify function to send due reminders
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.unschedule(jobid) from cron.job where jobname = 'lfb-clock-out-reminders';
select cron.schedule('lfb-clock-out-reminders', '*/10 * * * *', $cron$
  select net.http_post(
    url := 'https://ylvoswzsijigyezqvaat.supabase.co/functions/v1/contractor-notify',
    headers := '{"Content-Type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inlsdm9zd3pzaWppZ3llenF2YWF0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM2Mjk5MTAsImV4cCI6MjA4OTIwNTkxMH0.iA4QMZkxTsqArV3CgHb-YluiBeiIq5RppGV6kBe8G8g","apikey":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inlsdm9zd3pzaWppZ3llenF2YWF0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM2Mjk5MTAsImV4cCI6MjA4OTIwNTkxMH0.iA4QMZkxTsqArV3CgHb-YluiBeiIq5RppGV6kBe8G8g"}'::jsonb,
    body := '{"event":"clock_out_reminder","cron":true}'::jsonb
  );
$cron$);

select jobname, schedule, active from cron.job where jobname = 'lfb-clock-out-reminders';
