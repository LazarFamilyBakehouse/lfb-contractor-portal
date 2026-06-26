-- ============================================================
-- LFB Contractor Portal — Pass 2B Schema (Referrals table)
-- Adds c_referrals so contractors can submit referrals and admin can review.
-- Idempotent: safe to re-run.
-- ============================================================

begin;

create table if not exists public.c_referrals (
  id              uuid primary key default gen_random_uuid(),
  contractor_id   uuid not null references public.c_contractors(id) on delete cascade,
  referee_name    text not null,
  referee_contact text not null,
  comments        text default '',
  status          text not null default 'new' check (status in ('new','reviewed','contacted','hired','declined','archived')),
  admin_notes     text default '',
  created_at      timestamptz not null default now(),
  reviewed_at     timestamptz,
  reviewed_by     uuid references public.c_contractors(id) on delete set null
);

create index if not exists c_referrals_contractor_idx on public.c_referrals(contractor_id);
create index if not exists c_referrals_status_idx on public.c_referrals(status) where status = 'new';

alter table public.c_referrals enable row level security;

drop policy if exists c_referrals_admin_all on public.c_referrals;
create policy c_referrals_admin_all on public.c_referrals
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

drop policy if exists c_referrals_self_select on public.c_referrals;
create policy c_referrals_self_select on public.c_referrals
  for select to authenticated
  using (contractor_id in (select id from public.c_contractors where user_id = auth.uid()));

drop policy if exists c_referrals_self_insert on public.c_referrals;
create policy c_referrals_self_insert on public.c_referrals
  for insert to authenticated
  with check (contractor_id in (select id from public.c_contractors where user_id = auth.uid()));

commit;
