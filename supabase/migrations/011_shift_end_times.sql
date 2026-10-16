-- LFB Contractor Portal - per-start-time end times (migration 011)
-- start_times[] already exists; end_times[] is the matching list of
-- end times (same order, nulls allowed). Single-window shifts keep
-- using start_time / end_time.
alter table public.c_shifts add column if not exists end_times time[];
select 'end_times ready' as result;
