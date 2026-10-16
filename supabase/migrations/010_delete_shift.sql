-- ============================================================
-- LFB Contractor Portal - Delete a shift outright (migration 010)
-- Cancel keeps a record; Delete removes the shift and everything
-- hanging off it (signups, unpaid hour submissions). Refuses when
-- any hours on the shift have already been paid, so payment history
-- can never be orphaned. Time clock entries keep their data and just
-- lose the shift link.
-- ============================================================
begin;

create or replace function public.c_delete_shift(p_shift_id uuid)
returns table(deleted_signups int, deleted_hours int)
language plpgsql security definer set search_path = public as $$
declare v_paid int; n_s int; n_h int;
begin
  if not c_is_admin() then raise exception 'Admin only'; end if;
  if not exists (select 1 from public.c_shifts where id = p_shift_id) then raise exception 'Shift not found'; end if;

  select count(*) into v_paid
    from public.c_payment_items pi join public.c_hour_submissions h on h.id = pi.hour_submission_id
   where h.shift_id = p_shift_id;
  if v_paid > 0 then
    raise exception 'This shift has hours that were already paid (% record%). Cancel it instead of deleting.', v_paid, case when v_paid = 1 then '' else 's' end;
  end if;

  select count(*) into n_s from public.c_shift_signups where shift_id = p_shift_id;
  select count(*) into n_h from public.c_hour_submissions where shift_id = p_shift_id;

  update public.c_time_entries set shift_id = null where shift_id = p_shift_id;
  delete from public.c_shifts where id = p_shift_id;   -- cascades signups + hour submissions

  return query select n_s, n_h;
end $$;

grant execute on function public.c_delete_shift(uuid) to authenticated;

commit;

select 'c_delete_shift ready' as result;
