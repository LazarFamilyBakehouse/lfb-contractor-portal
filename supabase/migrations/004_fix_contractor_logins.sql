-- ============================================================
-- LFB Contractor Portal — Fix Contractor Logins
-- Creates auth.users for every c_contractors row missing one,
-- using their stored PIN as password, with email already confirmed.
-- Also repairs existing unconfirmed accounts.
-- Safe & idempotent — re-run any time PINs are added or rotated.
-- ============================================================

create extension if not exists pgcrypto;

do $$
declare
  c record;
  v_uid uuid;
begin
  for c in
    select id, email, pin
      from public.c_contractors
     where email is not null
       and pin   is not null
  loop
    -- Does an auth.users row already exist for this email?
    select id into v_uid from auth.users where email = c.email;

    if v_uid is null then
      -- Create the auth user with confirmed email.
      v_uid := gen_random_uuid();

      insert into auth.users (
        id, instance_id, aud, role,
        email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data,
        confirmation_token, recovery_token,
        email_change_token_new, email_change, email_change_token_current,
        reauthentication_token,
        created_at, updated_at
      ) values (
        v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        c.email, crypt(c.pin, gen_salt('bf')), now(),
        jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
        '{}'::jsonb,
        '', '', '', '', '', '',
        now(), now()
      );

      -- Identity row is required for email/password login to work.
      insert into auth.identities (
        id, user_id, provider, provider_id,
        identity_data,
        last_sign_in_at, created_at, updated_at
      ) values (
        gen_random_uuid(), v_uid, 'email', v_uid::text,
        jsonb_build_object('sub', v_uid::text, 'email', c.email, 'email_verified', true),
        now(), now(), now()
      );
    else
      -- Repair existing row: reset password to current PIN, confirm email.
      update auth.users
         set encrypted_password = crypt(c.pin, gen_salt('bf')),
             email_confirmed_at = coalesce(email_confirmed_at, now()),
             updated_at         = now()
       where id = v_uid;

      -- Make sure an email identity exists for this user.
      if not exists (
        select 1 from auth.identities
         where user_id = v_uid and provider = 'email'
      ) then
        insert into auth.identities (
          id, user_id, provider, provider_id,
          identity_data,
          last_sign_in_at, created_at, updated_at
        ) values (
          gen_random_uuid(), v_uid, 'email', v_uid::text,
          jsonb_build_object('sub', v_uid::text, 'email', c.email, 'email_verified', true),
          now(), now(), now()
        );
      end if;
    end if;

    -- Link the contractor row to the auth user.
    update public.c_contractors
       set user_id = v_uid
     where id = c.id
       and (user_id is null or user_id <> v_uid);
  end loop;
end $$;

-- ────────────────────────────────────────────────────────────
-- Verify with:
--   select c.first_name||' '||c.last_name as name, c.email, c.pin,
--          u.email_confirmed_at is not null as confirmed,
--          c.user_id is not null as linked
--     from c_contractors c
--     left join auth.users u on u.id = c.user_id
--    order by c.first_name;
-- ────────────────────────────────────────────────────────────
