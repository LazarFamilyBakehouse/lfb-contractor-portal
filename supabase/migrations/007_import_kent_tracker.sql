-- ============================================================
-- LFB Contractor Portal — Import "Kent Tracker.xlsm" (migration 007)
-- 1) Kitchen hours LFB owes Kent Denver ($10/hr) -> new table c_kitchen_hours
-- 2) Contractor hours (Sheet2) -> c_shifts / c_shift_signups / c_hour_submissions
--    (approved), paid rows -> c_payments (one per contractor per month) + items,
--    expense reimbursements -> c_payments with notes.
-- Idempotent: re-running skips rows that already exist.
-- ============================================================
begin;

-- ─── Kent Denver kitchen hours (what LFB pays Kent) ─────────────────
create table if not exists public.c_kitchen_hours (
  id         uuid primary key default gen_random_uuid(),
  use_date   date not null,
  hours      numeric(6,2) not null check (hours >= 0),
  rate       numeric(6,2) not null default 10,
  total      numeric(8,2) generated always as (hours * rate) stored,
  batch      text default '',
  paid       boolean not null default false,
  paid_on    date,
  notes      text default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists c_kitchen_hours_date_idx on public.c_kitchen_hours(use_date desc);
drop trigger if exists c_kitchen_hours_touch on public.c_kitchen_hours;
create trigger c_kitchen_hours_touch before update on public.c_kitchen_hours
  for each row execute function public.c_set_updated_at();
alter table public.c_kitchen_hours enable row level security;
drop policy if exists c_kitchen_hours_admin_all on public.c_kitchen_hours;
create policy c_kitchen_hours_admin_all on public.c_kitchen_hours
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

insert into public.c_kitchen_hours (use_date, hours, rate, batch, notes)
select v.d::date, v.h, v.r, v.b, 'Imported from Kent Tracker'
from (values
  ('2025-12-28', 4.0, 10.0, '69, 369'),
  ('2025-12-29', 4.0, 10.0, '69, 369'),
  ('2026-01-10', 2.45, 10.0, '70'),
  ('2026-01-11', 3.5, 10.0, '71'),
  ('2026-01-13', 3.0, 10.0, '72'),
  ('2026-01-28', 4.0, 10.0, '74'),
  ('2026-01-31', 5.0, 10.0, '75'),
  ('2026-02-01', 3.0, 10.0, '75'),
  ('2026-02-09', 4.0, 10.0, '77'),
  ('2026-02-10', 4.0, 10.0, '78'),
  ('2026-02-14', 2.5, 10.0, '79'),
  ('2026-02-15', 2.5, 10.0, '80'),
  ('2026-02-21', 3.0, 10.0, '81'),
  ('2026-02-25', 2.5, 10.0, 'Minis Nick'),
  ('2026-03-07', 3.0, 10.0, '84'),
  ('2026-03-08', 2.5, 10.0, '85'),
  ('2026-03-27', 3.0, 10.0, '87'),
  ('2026-03-28', 3.0, 10.0, '88'),
  ('2026-04-26', 5.0, 10.0, '90'),
  ('2026-04-27', 3.0, 10.0, '91'),
  ('2026-04-28', 2.5, 10.0, '92'),
  ('2026-05-13', 3.0, 10.0, '94'),
  ('2026-05-15', 4.0, 10.0, '95'),
  ('2026-05-17', 3.5, 10.0, '96'),
  ('2026-05-25', 4.0, 10.0, '97'),
  ('2026-06-07', 3.0, 10.0, '100'),
  ('2026-06-13', 5.0, 10.0, '101'),
  ('2026-06-15', 3.0, 10.0, '102'),
  ('2026-06-26', 4.0, 10.0, '103'),
  ('2026-06-29', 4.0, 10.0, '106'),
  ('2026-06-30', 5.0, 10.0, '107'),
  ('2026-07-05', 4.5, 10.0, '108'),
  ('2026-07-11', 5.5, 10.0, '109'),
  ('2026-07-12', 3.5, 10.0, '110'),
  ('2026-07-15', 4.0, 10.0, '111'),
  ('2026-08-04', 3.0, 10.0, '112'),
  ('2026-08-05', 3.0, 10.0, '114'),
  ('2026-08-09', 4.0, 10.0, '115'),
  ('2026-08-14', 3.5, 10.0, '118'),
  ('2026-08-15', 4.0, 10.0, '119'),
  ('2026-08-23', 4.5, 10.0, '122'),
  ('2026-09-07', 3.5, 10.0, '128'),
  ('2026-09-08', 3.0, 10.0, '129'),
  ('2026-09-13', 4.5, 10.0, ''),
  ('2026-09-14', 3.0, 10.0, ''),
  ('2026-09-26', 4.0, 10.0, '135'),
  ('2026-09-27', 3.0, 10.0, '136'),
  ('2026-09-28', 3.5, 10.0, '137'),
  ('2026-10-03', 4.0, 10.0, '139'),
  ('2026-10-04', 4.0, 10.0, '140'),
  ('2026-10-10', 3.0, 10.0, '142'),
  ('2026-10-11', 3.0, 10.0, '143'),
  ('2026-10-12', 4.5, 10.0, '144')
) as v(d,h,r,b)
where not exists (select 1 from public.c_kitchen_hours x where x.use_date = v.d::date and x.hours = v.h and x.batch = v.b);

-- ─── Make sure Cheri exists (new in the tracker; last name unknown) ──
insert into public.c_contractors (role, first_name, last_name, email, pay_rate, status, pin, admin_notes)
select 'contractor', 'Cheri', '', 'cheri@pending.lfb', 20, 'active',
       lpad((floor(random()*1000000))::int::text, 6, '0'),
       'Created by Kent Tracker import. Add last name + real email, then Activate login.'
where not exists (select 1 from public.c_contractors where lower(first_name) = 'cheri');

-- ─── Contractor hours ───────────────────────────────────────────────
create temp table _kt (first_name text, bake_date date, rate numeric, hours numeric, comp numeric, paid boolean) on commit drop;
insert into _kt values
  ('Roxanne', '2025-07-02', 18.0, 4.25, 76.5, true),
  ('Roxanne', '2025-07-09', 18.0, 1.0, 18.0, true),
  ('Roxanne', '2025-07-16', 18.0, 5.0, 90.0, true),
  ('Roxanne', '2025-07-23', 18.0, 6.0, 108.0, true),
  ('Roxanne', '2025-07-29', 18.0, 5.0, 90.0, true),
  ('Roxanne', '2025-08-06', 18.0, 5.0, 90.0, true),
  ('Roxanne', '2025-08-30', 18.0, 4.0, 72.0, true),
  ('Roxanne', '2025-10-04', 18.0, 4.33, 77.94, true),
  ('Roxanne', '2025-11-14', 21.6, 4.75, 102.6, true),
  ('Roxanne', '2026-01-11', 18.0, 2.33, 41.94, true),
  ('Roxanne', '2026-05-17', 20.0, 2.0, 40.0, true),
  ('Roxanne', '2026-06-20', 20.0, 2.5, 50.0, true),
  ('Roxanne', '2026-07-19', 20.0, 3.42, 68.32, true),
  ('Roxanne', '2026-10-04', 20.0, 4.25, 85.0, false),
  ('Zoe', '2025-07-23', 16.0, 5.0, 80.0, true),
  ('Zoe', '2025-07-29', 16.0, 6.0, 96.0, true),
  ('Zoe', '2025-08-06', 16.0, 5.66, 90.56, true),
  ('Zoe', '2025-08-16', 16.0, 8.0, 128.0, true),
  ('Zoe', '2025-10-04', 16.0, 7.0, 112.0, true),
  ('Zoe', '2025-10-26', 16.0, 5.25, 84.0, true),
  ('Zoe', '2025-11-09', 16.0, 2.33, 37.28, true),
  ('Zoe', '2025-11-22', 16.0, 6.0, 96.0, true),
  ('Zoe', '2026-01-31', 16.0, 4.5, 72.0, true),
  ('Ari', '2025-08-16', 17.5, 5.5, 96.25, true),
  ('Ari', '2025-08-30', 17.5, 4.17, 72.91, true),
  ('Ari', '2025-09-07', 17.5, 4.0, 70.0, true),
  ('Ari', '2025-09-21', 17.5, 4.75, 83.13, true),
  ('Ari', '2025-09-28', 17.5, 5.5, 96.25, true),
  ('Ari', '2025-10-04', 17.5, 4.0, 70.0, true),
  ('Ari', '2025-11-09', 17.5, 2.58, 45.24, true),
  ('Ari', '2025-11-22', 17.5, 3.92, 68.6, true),
  ('Ari', '2025-12-07', 17.5, 3.33, 58.28, true),
  ('Dalia', '2025-08-16', 17.5, 6.25, 109.38, true),
  ('Dalia', '2025-09-13', 17.5, 5.83, 102.08, true),
  ('Dalia', '2025-09-20', 17.5, 1.0, 17.5, true),
  ('Kyle', '2025-08-24', 17.5, 4.33, 75.83, true),
  ('Kyle', '2025-09-07', 17.5, 4.0, 70.0, true),
  ('Kyle', '2025-09-13', 17.5, 2.5, 43.75, true),
  ('Kyle', '2025-09-20', 17.5, 7.5, 131.25, true),
  ('Kyle', '2025-09-21', 17.5, 4.75, 83.13, true),
  ('Kyle', '2025-09-28', 17.5, 5.5, 96.25, true),
  ('Kyle', '2025-10-19', 17.5, 2.17, 37.92, true),
  ('Kyle', '2025-11-08', 17.5, 4.92, 86.01, true),
  ('Kyle', '2025-11-16', 17.5, 5.5, 96.25, true),
  ('Kyle', '2025-11-22', 17.5, 4.5, 78.75, true),
  ('Kyle', '2025-12-07', 17.5, 3.5, 61.25, true),
  ('Kyle', '2026-03-28', 19.0, 4.0, 76.0, true),
  ('Kyle', '2026-04-28', 19.0, 3.0, 57.0, true),
  ('Kyle', '2026-05-17', 20.0, 4.66, 93.2, true),
  ('Kyle', '2026-05-25', 20.0, 1.5, 30.0, true),
  ('Kyle', '2026-06-07', 20.0, 1.5, 30.0, true),
  ('Kyle', '2026-06-20', 20.0, 6.0, 120.0, true),
  ('Kyle', '2026-07-17', 20.0, 3.43, 68.6, true),
  ('Kyle', '2026-08-15', 20.0, 4.0, 80.0, true),
  ('Kyle', '2026-09-07', 20.0, 4.0, 80.0, true),
  ('Kyle', '2026-09-26', 20.0, 4.08, 81.6, true),
  ('Kyle', '2026-10-12', 20.0, 3.67, 73.33, true),
  ('Zack', '2025-08-30', 20.0, 1.75, 35.0, true),
  ('Zack', '2026-05-17', 20.0, 4.0, 80.0, true),
  ('Kiarra', '2025-09-07', 17.5, 6.0, 105.0, true),
  ('Kiarra', '2025-09-28', 17.5, 8.0, 140.0, true),
  ('Kiarra', '2025-10-19', 17.5, 5.33, 93.28, true),
  ('Kiarra', '2025-11-16', 17.5, 7.5, 131.25, true),
  ('Kiarra', '2026-02-09', 17.5, 4.5, 78.75, true),
  ('Kiarra', '2026-02-25', 17.5, 4.0, 70.0, true),
  ('Kiarra', '2026-03-07', 17.5, 3.0, 52.5, true),
  ('Kiarra', '2026-04-27', 17.5, 3.0, 52.2, true),
  ('Kiarra', '2026-05-25', 19.0, 2.5, 47.5, true),
  ('Kiarra', '2026-06-13', 19.0, 5.0, 95.0, true),
  ('Kiarra', '2026-07-05', 19.0, 3.5, 66.5, true),
  ('Kiarra', '2026-09-08', 19.0, 5.0, 95.0, true),
  ('Kiarra', '2026-09-27', 19.0, 4.25, 80.75, true),
  ('Mara', '2025-11-08', 17.5, 5.79, 101.33, true),
  ('Mara', '2025-11-22', 17.5, 7.33, 128.28, true),
  ('Mara', '2025-12-16', 17.5, 4.6, 80.5, true),
  ('Mara', '2026-01-13', 17.5, 2.5, 43.75, true),
  ('Mara', '2026-01-28', 17.5, 6.16, 107.8, true),
  ('Sloane', '2025-11-09', 17.5, 4.0, 70.0, true),
  ('Danielle', '2026-06-13', 19.0, 3.0, 57.0, true),
  ('Danielle', '2026-06-15', 19.0, 2.76, 52.44, true),
  ('Danielle', '2026-06-30', 19.0, 3.56, 67.64, true),
  ('Danielle', '2026-07-05', 19.0, 3.61, 68.72, true),
  ('Danielle', '2026-07-19', 19.0, 3.16, 60.04, true),
  ('Danielle', '2026-08-14', 19.0, 2.83, 53.83, true),
  ('Danielle', '2026-08-23', 19.0, 5.58, 106.08, false),
  ('Ethan', '2026-06-20', 19.0, 3.0, 57.0, true),
  ('Ethan', '2026-06-30', 19.0, 3.78, 71.88, true),
  ('Ethan', '2026-08-23', 19.0, 5.58, 106.08, false),
  ('Talia', '2026-05-17', 19.0, 2.5, 47.5, true),
  ('Talia', '2026-06-20', 19.0, 3.5, 66.5, true),
  ('Talia', '2026-06-29', 19.0, 3.6, 68.4, true),
  ('Talia', '2026-07-11', 19.0, 4.75, 90.25, true),
  ('Meishan', '2026-05-17', 19.0, 2.5, 47.5, true),
  ('Meishan', '2026-06-20', 19.0, 3.5, 66.5, true),
  ('Meishan', '2026-06-29', 19.0, 3.6, 68.4, true),
  ('Meishan', '2026-07-11', 19.0, 4.75, 90.25, true),
  ('Sadie', '2026-06-29', 19.0, 4.33, 82.27, true),
  ('Cheri', '2026-09-26', 20.0, 5.16, 103.33, true),
  ('Cheri', '2026-10-04', 20.0, 4.25, 85.0, false);

do $$
declare
  rec record; v_cid uuid; v_admin uuid; v_shift uuid; v_signup uuid; v_sub uuid; v_pay uuid;
  n_shifts int := 0; n_signups int := 0; n_hours int := 0; n_pay int := 0; n_skip int := 0;
begin
  select id into v_admin from public.c_contractors where email = 'info@lazarfamilybakehouse.com' limit 1;

  for rec in select * from _kt order by bake_date, first_name loop
    select id into v_cid from public.c_contractors where lower(first_name) = lower(rec.first_name) order by created_at limit 1;
    if v_cid is null then raise notice 'no contractor for %', rec.first_name; continue; end if;

    -- shift for that date (one per bake day)
    select id into v_shift from public.c_shifts where bake_date = rec.bake_date and status <> 'cancelled' order by created_at limit 1;
    if v_shift is null then
      insert into public.c_shifts (bake_date, start_time, location, spots_total, notes, status, created_by)
      values (rec.bake_date, '06:00', 'Lazar Family Bakehouse', 4, 'Imported from Kent Tracker', 'completed', v_admin)
      returning id into v_shift;
      n_shifts := n_shifts + 1;
    end if;

    -- signup
    select id into v_signup from public.c_shift_signups where shift_id = v_shift and contractor_id = v_cid and status <> 'released' limit 1;
    if v_signup is null then
      insert into public.c_shift_signups (shift_id, contractor_id, status, signed_up_at)
      values (v_shift, v_cid, 'completed', rec.bake_date::timestamptz)
      returning id into v_signup;
      n_signups := n_signups + 1;
    else
      update public.c_shift_signups set status = 'completed' where id = v_signup and status = 'signed_up';
    end if;

    -- hours (one per signup)
    select id into v_sub from public.c_hour_submissions where signup_id = v_signup;
    if v_sub is not null then n_skip := n_skip + 1; continue; end if;
    insert into public.c_hour_submissions (signup_id, shift_id, contractor_id, submitted_hours, submitted_notes, submitted_at,
                                           approved_hours, approved_pay_rate, approved_at, approved_by, status, admin_notes)
    values (v_signup, v_shift, v_cid, rec.hours, 'Imported from Kent Tracker', rec.bake_date::timestamptz + interval '20 hours',
            rec.hours, rec.rate, rec.bake_date::timestamptz + interval '1 day', v_admin, 'approved', 'Imported from Kent Tracker')
    returning id into v_sub;
    n_hours := n_hours + 1;

    -- payment (grouped per contractor per month)
    if rec.paid then
      select p.id into v_pay from public.c_payments p
       where p.contractor_id = v_cid and p.reference = 'Kent Tracker import'
         and date_trunc('month', p.paid_on) = date_trunc('month', rec.bake_date) limit 1;
      if v_pay is null then
        insert into public.c_payments (contractor_id, amount, method, paid_on, reference, notes, created_by)
        values (v_cid, 0, 'other', (date_trunc('month', rec.bake_date) + interval '1 month - 1 day')::date, 'Kent Tracker import',
                'Marked paid in the Kent Tracker sheet; exact pay date/method not recorded.', v_admin)
        returning id into v_pay;
        n_pay := n_pay + 1;
      end if;
      insert into public.c_payment_items (payment_id, hour_submission_id, amount) values (v_pay, v_sub, rec.comp);
      update public.c_payments set amount = (select coalesce(sum(amount),0) from public.c_payment_items where payment_id = v_pay) where id = v_pay;
    end if;
  end loop;

  -- expense reimbursements (Kyle)
  for rec in select * from (values ('Kyle','2025-11-16'::date,46.66,'Walmart'), ('Kyle','2026-03-28'::date,24.99,'KS GF flour')) as e(first_name, d, amt, what) loop
    select id into v_cid from public.c_contractors where lower(first_name) = lower(rec.first_name) order by created_at limit 1;
    if v_cid is not null and not exists (select 1 from public.c_payments where contractor_id = v_cid and paid_on = rec.d and notes like 'Expense reimbursement: ' || rec.what || '%') then
      insert into public.c_payments (contractor_id, amount, method, paid_on, reference, notes, created_by)
      values (v_cid, rec.amt, 'other', rec.d, 'Kent Tracker import', 'Expense reimbursement: ' || rec.what || ' (from Kent Tracker)', v_admin);
    end if;
  end loop;

  raise notice 'shifts=% signups=% hours=% payments=% skipped_existing=%', n_shifts, n_signups, n_hours, n_pay, n_skip;
end $$;

commit;

select (select count(*) from c_hour_submissions) as hour_rows,
       (select round(sum(approved_amount),2) from c_hour_submissions) as total_comp,
       (select count(*) from c_payments) as payments,
       (select count(*) from c_kitchen_hours) as kent_rows,
       (select round(sum(total),2) from c_kitchen_hours) as kent_total;