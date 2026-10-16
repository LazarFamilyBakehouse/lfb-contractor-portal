-- migration 013: admins also sign in with their PIN.
-- 008 skipped admins in c_sync_auth_login_for, so the PIN shown on an
-- admin row never matched the real password. Admins now sync like
-- everyone else (edit/regenerate PIN -> login updates immediately).
-- Run after 008/012. Idempotent.
begin;
create or replace function public.c_sync_auth_login_for(p_contractor uuid)
returns void language plpgsql security definer set search_path = public, auth, extensions as $$
declare c record; v_uid uuid;
begin
  select * into c from public.c_contractors where id = p_contractor;
  if c.id is null or c.email is null or c.pin is null or length(c.pin) < 4 then return; end if;
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
    update auth.users set email = lower(c.email), encrypted_password = extensions.crypt(c.pin, extensions.gen_salt('bf')),
      email_confirmed_at = coalesce(email_confirmed_at, now()), banned_until = null, updated_at = now() where id = v_uid;
    update auth.identities set identity_data = jsonb_build_object('sub', v_uid::text, 'email', lower(c.email), 'email_verified', true), updated_at = now()
     where user_id = v_uid and provider = 'email';
    if not exists (select 1 from auth.identities where user_id = v_uid and provider = 'email') then
      insert into auth.identities (id, user_id, provider, provider_id, identity_data, last_sign_in_at, created_at, updated_at)
      values (gen_random_uuid(), v_uid, 'email', v_uid::text,
        jsonb_build_object('sub', v_uid::text, 'email', lower(c.email), 'email_verified', true), now(), now(), now());
    end if;
  end if;
  update public.c_contractors set user_id = v_uid where id = c.id and user_id is distinct from v_uid;
end $$;
select public.c_sync_auth_login_for(id) from public.c_contractors where role = 'admin';
commit;
