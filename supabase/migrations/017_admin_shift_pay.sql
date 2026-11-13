-- migration 017: admin adds or edits a shift payment (approved hours) by hand.
--  * c_admin_add_shift_pay: approved hour row for a contractor on a date, with
--    hours and an optional custom amount (stored as an adjusted pay rate because
--    approved_amount is generated from hours x rate). Creates the day's shift
--    and signup when needed, same as time-clock approval.
--  * c_admin_edit_shift_pay: change hours / amount / note on an approved row
--    that has not been paid yet.
--  * c_login_email_for_username (contractor sign-in by first name) was added
--    in the same session.
begin;

create or replace function public.c_admin_add_shift_pay(
  p_contractor_id uuid, p_date date, p_hours numeric, p_amount numeric default null, p_notes text default ''
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_admin public.c_contractors%rowtype; v_rate numeric; v_shift uuid; v_signup uuid; v_sub uuid; v_start time;
begin
  select * into v_admin from public.c_contractors where user_id = auth.uid();
  if not c_is_admin() then raise exception 'Admin only'; end if;
  if p_hours is null or p_hours <= 0 or p_hours > 24 then raise exception 'Hours must be between 0 and 24'; end if;
  if p_date is null then raise exception 'Date is required'; end if;

  select pay_rate into v_rate from public.c_contractors where id = p_contractor_id;
  if v_rate is null then raise exception 'Contractor not found'; end if;
  if p_amount is not null then
    if p_amount < 0 then raise exception 'Amount cannot be negative'; end if;
    v_rate := round(p_amount / p_hours, 4);
  end if;

  select id into v_shift from public.c_shifts where bake_date = p_date and status <> 'cancelled' order by created_at limit 1;
  if v_shift is null then
    v_start := '09:00';
    insert into public.c_shifts (bake_date, start_time, location, spots_total, notes, status, created_by)
    values (p_date, v_start, 'Lazar Family Bakehouse', 4, 'Added by admin', 'completed', v_admin.id)
    returning id into v_shift;
  end if;

  select id into v_signup from public.c_shift_signups where shift_id = v_shift and contractor_id = p_contractor_id and status <> 'released' limit 1;
  if v_signup is null then
    insert into public.c_shift_signups (shift_id, contractor_id, status, signed_up_at)
    values (v_shift, p_contractor_id, 'completed', (p_date::text || ' 09:00')::timestamp at time zone 'America/Denver')
    returning id into v_signup;
  else
    update public.c_shift_signups set status = 'completed' where id = v_signup and status = 'signed_up';
  end if;

  select id into v_sub from public.c_hour_submissions where signup_id = v_signup;
  if v_sub is not null then raise exception 'This contractor already has hours on that date. Edit that entry instead.'; end if;

  insert into public.c_hour_submissions (signup_id, shift_id, contractor_id, submitted_hours, submitted_notes, submitted_at,
                                         approved_hours, approved_pay_rate, approved_at, approved_by, status, admin_notes)
  values (v_signup, v_shift, p_contractor_id, p_hours, 'Added by admin', now(),
          p_hours, v_rate, now(), v_admin.id, 'approved', coalesce(p_notes,''))
  returning id into v_sub;
  return v_sub;
end $$;
grant execute on function public.c_admin_add_shift_pay(uuid, date, numeric, numeric, text) to authenticated;

create or replace function public.c_admin_edit_shift_pay(
  p_submission_id uuid, p_hours numeric, p_amount numeric default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_admin public.c_contractors%rowtype; s public.c_hour_submissions%rowtype; v_rate numeric;
begin
  select * into v_admin from public.c_contractors where user_id = auth.uid();
  if not c_is_admin() then raise exception 'Admin only'; end if;
  select * into s from public.c_hour_submissions where id = p_submission_id for update;
  if s.id is null then raise exception 'Entry not found'; end if;
  if exists (select 1 from public.c_payment_items where hour_submission_id = s.id) then
    raise exception 'This shift has already been paid; it cannot be changed';
  end if;
  if p_hours is null or p_hours <= 0 or p_hours > 24 then raise exception 'Hours must be between 0 and 24'; end if;
  select pay_rate into v_rate from public.c_contractors where id = s.contractor_id;
  if p_amount is not null then
    if p_amount < 0 then raise exception 'Amount cannot be negative'; end if;
    v_rate := round(p_amount / p_hours, 4);
  end if;
  update public.c_hour_submissions
     set approved_hours = p_hours, approved_pay_rate = v_rate, approved_at = coalesce(approved_at, now()),
         approved_by = v_admin.id, status = 'approved',
         admin_notes = coalesce(p_notes, admin_notes)
   where id = s.id;
  return s.id;
end $$;
grant execute on function public.c_admin_edit_shift_pay(uuid, numeric, numeric, text) to authenticated;

commit;
