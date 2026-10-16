-- migration 015: contract e-sign functions hash the body with digest(),
-- which lives in the extensions schema on Supabase. Their search_path was
-- public only, so "Send contract" failed with "function does not exist".
alter function public.c_contract_send(uuid, uuid, text, text, jsonb, text, text) set search_path = public, extensions;
alter function public.c_contract_sign(uuid, text, text, text) set search_path = public, extensions;
alter function public.c_contract_log(uuid, text, jsonb) set search_path = public, extensions;
alter function public.c_contract_mark_viewed(uuid) set search_path = public, extensions;
alter function public.c_contract_decline(uuid, text) set search_path = public, extensions;
alter function public.c_contract_void(uuid, text) set search_path = public, extensions;
alter function public.c_contract_attach_pdf(uuid, text) set search_path = public, extensions;
