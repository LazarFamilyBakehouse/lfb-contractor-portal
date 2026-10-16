-- ============================================================
-- LFB Contractor Portal — Kitchen Rent
-- Tracks rent collected from outside kitchen users (sub-tenants,
-- side bakers, food trucks). Manual entry; admin-only.
-- Idempotent: safe to re-run.
-- ============================================================

begin;

create table if not exists public.c_kitchen_rent (
  id             uuid primary key default gen_random_uuid(),
  payer_name     text not null,
  contact        text default '',
  period_start   date not null,
  period_end     date,
  amount_due     numeric(10,2) not null default 0,
  amount_paid    numeric(10,2) not null default 0,
  status         text not null default 'pending'
                 check (status in ('pending','partial','paid','overdue','cancelled')),
  paid_on        date,
  method         text default ''
                 check (method in ('','check','venmo','zelle','cash','wire','other')),
  reference      text default '',
  notes          text default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists c_kitchen_rent_period_idx on public.c_kitchen_rent(period_start desc);
create index if not exists c_kitchen_rent_status_idx on public.c_kitchen_rent(status)
  where status in ('pending','partial','overdue');

-- keep updated_at fresh
create or replace function public.c_kitchen_rent_touch()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists c_kitchen_rent_touch_trg on public.c_kitchen_rent;
create trigger c_kitchen_rent_touch_trg
  before update on public.c_kitchen_rent
  for each row execute function public.c_kitchen_rent_touch();

alter table public.c_kitchen_rent enable row level security;

drop policy if exists c_kitchen_rent_admin_all on public.c_kitchen_rent;
create policy c_kitchen_rent_admin_all on public.c_kitchen_rent
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

commit;
