-- ============================================================
-- LFB Contractor Portal — Keep logins in sync with email + PIN (migration 008)
-- Root cause of "Email or PIN is wrong": editing/regenerating a PIN (or an
-- email) only changed c_contractors, never the auth password, so the two
-- drifted apart. This trigger makes c_contractors the source of truth:
--   * insert with email+pin  -> auth user created, confirmed, linked
--   * pin changed            -> auth password updated
--   * email changed          -> auth email + identity updated
-- Also adds c_sync_all_logins() for the admin "Activate" button.
-- Idempotent.
-- ============================================================
begin;
create extension if not exists pgcrypto;

create or replace function public.c_sync_auth_login_for(p_contractor uuid)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
declare c record; v_uid uuid;
begin
  select * into c from public.c_contractors where id = p_contractor;
  if c.id is null or c.email is null or c.pin is null or length(c.pin) < 4 then return; end if;
  if c.role = 'admin' then return; end if;  -- admins keep their own password

  v_uid := c.user_id;
  if v_uid is null then select id into v_uid from auth.users where lower(email) = lower(c.email); end if;

  if v_uid is null then
    v_uid := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token, email_change_token_new,
      email_change, email_change_token_current, reauthentication_token, created_at, updated_at)
    values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', lower(c.email),
      extensions.crypt(c.pin, extensions.gen_salt('bf')), now(), jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
      '{}'::jsonb, '', '', '', '', '', '', now(), now());
    insert into auth.identities (id, user_id, provider, provider_id, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_uid, 'email', v_uid::text,
      jsonb_build_object('sub', v_uid::text, 'email', lower(c.email), 'email_verified', true), now(), now(), now());
  else
    update auth.users set
      email = lower(c.email),
      encrypted_password = extensions.crypt(c.pin, extensions.gen_salt('bf')),
      email_confirmed_at = coalesce(email_confirmed_at, now()),
      banned_until = null,
      updated_at = now()
    where id = v_uid;
    update auth.identities set
      identity_data = jsonb_build_object('sub', v_uid::text, 'email', lower(c.email), 'email_verified', true),
      updated_at = now()
    where user_id = v_uid and provider = 'email';
    if not exists (select 1 from auth.identities where user_id = v_uid and provider = 'email') then
      insert into auth.identities (id, user_id, provider, provider_id, identity_data, last_sign_in_at, created_at, updated_at)
      values (gen_random_uuid(), v_uid, 'email', v_uid::text,
        jsonb_build_object('sub', v_uid::text, 'email', lower(c.email), 'email_verified', true), now(), now(), now());
    end if;
  end if;

  update public.c_contractors set user_id = v_uid where id = c.id and user_id is distinct from v_uid;
end $$;

create or replace function public.c_sync_auth_login_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.pin is distinct from old.pin or lower(new.email) is distinct from lower(old.email) or (new.user_id is null) then
    perform public.c_sync_auth_login_for(new.id);
  end if;
  return new;
end $$;

drop trigger if exists c_contractors_sync_login on public.c_contractors;
create trigger c_contractors_sync_login
  after insert or update of pin, email on public.c_contractors
  for each row execute function public.c_sync_auth_login_trg();

-- Admin RPC: sync everyone (replaces the old signUp-based "Activate all" button)
create or replace function public.c_sync_all_logins()
returns table(first_name text, email text, linked boolean)
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not c_is_admin() then raise exception 'admin only'; end if;
  for r in select id from public.c_contractors where role = 'contractor' and email is not null and pin is not null loop
    perform public.c_sync_auth_login_for(r.id);
  end loop;
  return query select c.first_name, c.email, (c.user_id is not null) from public.c_contractors c where c.role = 'contractor' order by c.first_name;
end $$;

-- run once now so every existing row is consistent
select count(*) from public.c_contractors c where c.role='contractor' and c.email is not null and c.pin is not null and (select public.c_sync_auth_login_for(c.id)) is null;

commit;

select c.first_name, c.email, (u.encrypted_password = extensions.crypt(c.pin, u.encrypted_password)) as pin_ok, lower(u.email) = lower(c.email) as email_ok
from public.c_contractors c join auth.users u on u.id = c.user_id where c.role='contractor' order by 1;
