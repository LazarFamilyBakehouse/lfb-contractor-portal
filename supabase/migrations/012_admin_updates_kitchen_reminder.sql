-- ============================================================
-- LFB Contractor Portal - migration 012
-- 1) c_admin_update_contractor: admins could not change status, role,
--    pay rate, email or notes from the UI because column-level grants on
--    c_contractors only allow the self-service profile fields. This
--    security-definer RPC does the admin edit server-side.
-- 2) c_shifts.kitchen_reminder_sent_at: tracks the "log the kitchen hours"
--    email sent to the team after a shift completes.
-- 3) Victoria gets an admin login (created as contractor so the login
--    trigger builds the auth user, then promoted to admin).
-- Idempotent.
-- ============================================================
begin;

create or replace function public.c_admin_update_contractor(p_id uuid, p_patch jsonb)
returns public.c_contractors
language plpgsql security definer set search_path = public as $$
declare r public.c_contractors;
begin
  if not c_is_admin() then raise exception 'Admin only'; end if;
  if p_patch ? 'status' and (p_patch->>'status') not in ('active','inactive') then raise exception 'Bad status'; end if;
  if p_patch ? 'role' and (p_patch->>'role') not in ('admin','contractor') then raise exception 'Bad role'; end if;
  if p_patch ? 'email' and exists (select 1 from public.c_contractors where lower(email) = lower(p_patch->>'email') and id <> p_id) then
    raise exception 'That email is already used by another contractor';
  end if;

  update public.c_contractors set
    first_name  = case when p_patch ? 'first_name'  then p_patch->>'first_name'  else first_name end,
    last_name   = case when p_patch ? 'last_name'   then p_patch->>'last_name'   else last_name end,
    email       = case when p_patch ? 'email' and length(trim(p_patch->>'email')) > 3 then lower(trim(p_patch->>'email')) else email end,
    phone       = case when p_patch ? 'phone'       then p_patch->>'phone'       else phone end,
    pay_rate    = case when p_patch ? 'pay_rate'    then (p_patch->>'pay_rate')::numeric else pay_rate end,
    role        = case when p_patch ? 'role'        then p_patch->>'role'        else role end,
    status      = case when p_patch ? 'status'      then p_patch->>'status'      else status end,
    admin_notes = case when p_patch ? 'admin_notes' then p_patch->>'admin_notes' else admin_notes end,
    address_line1 = case when p_patch ? 'address_line1' then p_patch->>'address_line1' else address_line1 end,
    city        = case when p_patch ? 'city'        then p_patch->>'city'        else city end,
    state       = case when p_patch ? 'state'       then p_patch->>'state'       else state end,
    postal_code = case when p_patch ? 'postal_code' then p_patch->>'postal_code' else postal_code end,
    food_handler_card_expires = case when p_patch ? 'food_handler_card_expires' then nullif(p_patch->>'food_handler_card_expires','')::date else food_handler_card_expires end
  where id = p_id
  returning * into r;
  if r.id is null then raise exception 'Contractor not found'; end if;
  return r;
end $$;
grant execute on function public.c_admin_update_contractor(uuid, jsonb) to authenticated;

alter table public.c_shifts add column if not exists kitchen_reminder_sent_at timestamptz;

-- Victoria: admin login
insert into public.c_contractors (role, first_name, last_name, email, pay_rate, status, pin, admin_notes)
select 'contractor', 'Victoria', 'Lazar', 'victoria@lazarfamilybakehouse.com', 0, 'active',
       lpad((floor(random()*1000000))::int::text, 6, '0'), 'Admin (kitchen lead). Signs in through the Admin login with email + PIN.'
where not exists (select 1 from public.c_contractors where lower(email) = 'victoria@lazarfamilybakehouse.com');
update public.c_contractors set role = 'admin' where lower(email) = 'victoria@lazarfamilybakehouse.com' and role <> 'admin';

commit;

select first_name, role, status, (user_id is not null) as login_ready from public.c_contractors where role = 'admin' order by first_name;
