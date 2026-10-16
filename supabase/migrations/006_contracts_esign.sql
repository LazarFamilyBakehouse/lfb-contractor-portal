-- ============================================================
-- LFB Contractor Portal — Contracts + E-Signature (migration 006)
-- Templates with merge fields, per-contractor contracts, signing
-- RPCs that capture IP / user agent / document hash server-side,
-- and an append-only event log per contract (the "audit certificate").
-- Designed around ESIGN Act / Colorado UETA (C.R.S. 24-71.3):
--   intent to sign, consent to electronic records, signature
--   attributed to and logically associated with the record,
--   record retained in a form both parties can reproduce.
-- Idempotent: safe to re-run.
-- ============================================================

begin;

create extension if not exists pgcrypto;

-- ─── c_contract_templates ────────────────────────────────────────────────
create table if not exists public.c_contract_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  version     int  not null default 1,
  body        text not null,            -- markdown-lite with {{merge_fields}}
  is_active   boolean not null default true,
  created_by  uuid references public.c_contractors(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

drop trigger if exists c_contract_templates_set_updated_at on public.c_contract_templates;
create trigger c_contract_templates_set_updated_at
  before update on public.c_contract_templates
  for each row execute function public.c_set_updated_at();

-- ─── c_contracts ─────────────────────────────────────────────────────────
create table if not exists public.c_contracts (
  id                   uuid primary key default gen_random_uuid(),
  contractor_id        uuid not null references public.c_contractors(id) on delete cascade,
  template_id          uuid references public.c_contract_templates(id) on delete set null,
  template_version     int,
  title                text not null,
  body_rendered        text not null,       -- frozen text the signer actually saw
  body_sha256          text not null,       -- hash of body_rendered, computed server-side
  merge_values         jsonb not null default '{}'::jsonb,
  status               text not null default 'sent'
                       check (status in ('sent','viewed','signed','declined','voided')),
  -- company side (pre-signed at send time, mirrors the paper flow)
  company_signer_name  text not null default 'Jake Lazar',
  company_signer_title text not null default 'CEO',
  company_signed_at    timestamptz not null default now(),
  -- contractor side
  sent_at              timestamptz not null default now(),
  first_viewed_at      timestamptz,
  signed_at            timestamptz,
  signer_typed_name    text,
  signer_email         text,
  signer_user_id       uuid,
  signer_ip            text,
  signer_user_agent    text,
  consent_text         text,
  decline_reason       text,
  voided_at            timestamptz,
  void_reason          text,
  pdf_path             text,                -- storage path in contractor-documents
  created_by           uuid references public.c_contractors(id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index if not exists c_contracts_contractor_idx on public.c_contracts(contractor_id);
create index if not exists c_contracts_status_idx     on public.c_contracts(status);

drop trigger if exists c_contracts_set_updated_at on public.c_contracts;
create trigger c_contracts_set_updated_at
  before update on public.c_contracts
  for each row execute function public.c_set_updated_at();

-- ─── c_contract_events (append-only) ─────────────────────────────────────
create table if not exists public.c_contract_events (
  id           bigserial primary key,
  contract_id  uuid not null references public.c_contracts(id) on delete cascade,
  event        text not null,   -- created | sent | viewed | signed | declined | voided | pdf_attached | reminder
  at           timestamptz not null default now(),
  actor_id     uuid,
  actor_email  text,
  ip           text,
  user_agent   text,
  meta         jsonb not null default '{}'::jsonb
);
create index if not exists c_contract_events_contract_idx on public.c_contract_events(contract_id, at);

-- ─── helper: request metadata from PostgREST headers ─────────────────────
create or replace function public.c_request_ip()
returns text language sql stable as $$
  select nullif(split_part(coalesce(
    current_setting('request.headers', true)::json->>'x-forwarded-for',
    current_setting('request.headers', true)::json->>'cf-connecting-ip',
    ''), ',', 1), '');
$$;

create or replace function public.c_request_ua()
returns text language sql stable as $$
  select left(coalesce(current_setting('request.headers', true)::json->>'user-agent',''), 400);
$$;

create or replace function public.c_my_contractor_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.c_contractors where user_id = auth.uid() limit 1;
$$;

create or replace function public.c_contract_log(
  p_contract uuid, p_event text, p_meta jsonb default '{}'::jsonb
) returns void language plpgsql security definer set search_path = public as $$
declare v_c public.c_contractors%rowtype;
begin
  select * into v_c from public.c_contractors where user_id = auth.uid() limit 1;
  insert into public.c_contract_events(contract_id, event, actor_id, actor_email, ip, user_agent, meta)
  values (p_contract, p_event, v_c.id,
          coalesce(v_c.email, (select email from auth.users where id = auth.uid())),
          c_request_ip(), c_request_ua(), coalesce(p_meta,'{}'::jsonb));
end; $$;

-- ─── RPC: admin creates + sends a contract ───────────────────────────────
create or replace function public.c_contract_send(
  p_contractor_id uuid,
  p_template_id   uuid,
  p_title         text,
  p_body          text,
  p_merge         jsonb default '{}'::jsonb,
  p_company_signer text default 'Jake Lazar',
  p_company_title  text default 'CEO'
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_ver int;
begin
  if not c_is_admin() then raise exception 'admin only'; end if;
  select version into v_ver from public.c_contract_templates where id = p_template_id;
  insert into public.c_contracts(contractor_id, template_id, template_version, title, body_rendered, body_sha256,
                                 merge_values, company_signer_name, company_signer_title, created_by)
  values (p_contractor_id, p_template_id, v_ver, p_title, p_body, encode(digest(p_body,'sha256'),'hex'),
          coalesce(p_merge,'{}'::jsonb), p_company_signer, p_company_title, c_my_contractor_id())
  returning id into v_id;
  perform c_contract_log(v_id, 'sent', jsonb_build_object('sha256', encode(digest(p_body,'sha256'),'hex')));
  return v_id;
end; $$;

-- ─── RPC: contractor opens the contract (first view timestamp) ───────────
create or replace function public.c_contract_mark_viewed(p_contract uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_row public.c_contracts%rowtype;
begin
  select * into v_row from public.c_contracts where id = p_contract;
  if v_row.id is null then raise exception 'not found'; end if;
  if v_row.contractor_id <> c_my_contractor_id() and not c_is_admin() then raise exception 'forbidden'; end if;
  if v_row.first_viewed_at is null and v_row.contractor_id = c_my_contractor_id() then
    update public.c_contracts set first_viewed_at = now(),
      status = case when status = 'sent' then 'viewed' else status end
      where id = p_contract;
    perform c_contract_log(p_contract, 'viewed');
  end if;
end; $$;

-- ─── RPC: contractor signs ───────────────────────────────────────────────
-- Verifies the hash the client saw matches what is stored (the signer is
-- signing exactly the text on record), requires explicit consent text,
-- records typed name + IP + UA + timestamp, and logs the event.
create or replace function public.c_contract_sign(
  p_contract     uuid,
  p_typed_name   text,
  p_consent_text text,
  p_client_sha   text
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_row public.c_contracts%rowtype; v_me public.c_contractors%rowtype;
begin
  select * into v_me from public.c_contractors where user_id = auth.uid() limit 1;
  select * into v_row from public.c_contracts where id = p_contract for update;
  if v_row.id is null then raise exception 'Contract not found'; end if;
  if v_row.contractor_id <> v_me.id then raise exception 'This contract is not addressed to you'; end if;
  if v_row.status in ('signed') then raise exception 'Already signed'; end if;
  if v_row.status in ('voided','declined') then raise exception 'This contract is no longer open for signature'; end if;
  if coalesce(trim(p_typed_name),'') = '' then raise exception 'Type your full legal name to sign'; end if;
  if coalesce(trim(p_consent_text),'') = '' then raise exception 'Consent to electronic signature is required'; end if;
  if p_client_sha is distinct from v_row.body_sha256 then
    raise exception 'The document changed since you opened it. Please reload and review again.';
  end if;

  update public.c_contracts set
    status            = 'signed',
    signed_at         = now(),
    signer_typed_name = trim(p_typed_name),
    signer_email      = v_me.email,
    signer_user_id    = auth.uid(),
    signer_ip         = c_request_ip(),
    signer_user_agent = c_request_ua(),
    consent_text      = p_consent_text,
    first_viewed_at   = coalesce(first_viewed_at, now())
  where id = p_contract;

  perform c_contract_log(p_contract, 'signed', jsonb_build_object(
    'typed_name', trim(p_typed_name), 'sha256', v_row.body_sha256));

  return (select to_jsonb(c) from public.c_contracts c where c.id = p_contract);
end; $$;

-- ─── RPC: contractor declines ────────────────────────────────────────────
create or replace function public.c_contract_decline(p_contract uuid, p_reason text default '')
returns void language plpgsql security definer set search_path = public as $$
declare v_row public.c_contracts%rowtype;
begin
  select * into v_row from public.c_contracts where id = p_contract for update;
  if v_row.contractor_id <> c_my_contractor_id() then raise exception 'forbidden'; end if;
  if v_row.status not in ('sent','viewed') then raise exception 'Not open'; end if;
  update public.c_contracts set status='declined', decline_reason=left(coalesce(p_reason,''),500) where id=p_contract;
  perform c_contract_log(p_contract, 'declined', jsonb_build_object('reason', left(coalesce(p_reason,''),500)));
end; $$;

-- ─── RPC: admin voids ────────────────────────────────────────────────────
create or replace function public.c_contract_void(p_contract uuid, p_reason text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not c_is_admin() then raise exception 'admin only'; end if;
  update public.c_contracts set status='voided', voided_at=now(), void_reason=left(coalesce(p_reason,''),500)
    where id=p_contract and status <> 'voided';
  perform c_contract_log(p_contract, 'voided', jsonb_build_object('reason', left(coalesce(p_reason,''),500)));
end; $$;

-- ─── RPC: attach the generated PDF path (owner after signing, or admin) ──
create or replace function public.c_contract_attach_pdf(p_contract uuid, p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare v_row public.c_contracts%rowtype;
begin
  select * into v_row from public.c_contracts where id = p_contract;
  if v_row.id is null then raise exception 'not found'; end if;
  if not (c_is_admin() or (v_row.contractor_id = c_my_contractor_id() and v_row.status='signed')) then
    raise exception 'forbidden';
  end if;
  update public.c_contracts set pdf_path = p_path where id = p_contract;
  perform c_contract_log(p_contract, 'pdf_attached', jsonb_build_object('path', p_path));
end; $$;

-- ─── RLS ─────────────────────────────────────────────────────────────────
alter table public.c_contract_templates enable row level security;
alter table public.c_contracts          enable row level security;
alter table public.c_contract_events    enable row level security;

drop policy if exists c_tpl_admin_all on public.c_contract_templates;
create policy c_tpl_admin_all on public.c_contract_templates
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

drop policy if exists c_contracts_admin_all on public.c_contracts;
create policy c_contracts_admin_all on public.c_contracts
  for all to authenticated using (c_is_admin()) with check (c_is_admin());

drop policy if exists c_contracts_self_select on public.c_contracts;
create policy c_contracts_self_select on public.c_contracts
  for select to authenticated
  using (contractor_id in (select id from public.c_contractors where user_id = auth.uid()));
-- contractors have NO direct insert/update/delete; they go through the RPCs above

drop policy if exists c_events_admin_select on public.c_contract_events;
create policy c_events_admin_select on public.c_contract_events
  for select to authenticated using (c_is_admin());

drop policy if exists c_events_self_select on public.c_contract_events;
create policy c_events_self_select on public.c_contract_events
  for select to authenticated
  using (contract_id in (select id from public.c_contracts
                         where contractor_id in (select id from public.c_contractors where user_id = auth.uid())));

-- allow 'contract' as a document type so signed PDFs show in Documents
alter table public.c_documents drop constraint if exists c_documents_document_type_check;
alter table public.c_documents add constraint c_documents_document_type_check
  check (document_type in ('w9','id','food_handler_card','contract','other'));

-- ─── Seed: Independent Contractor Agreement (from the July 2026 execution version) ──
insert into public.c_contract_templates (name, version, body, is_active)
select 'Independent Contractor Agreement', 1, $TPL$
# LAZAR FAMILY BAKEHOUSE LLC
# INDEPENDENT CONTRACTOR AGREEMENT

This Independent Contractor Agreement (this "Agreement") is made effective as of {{effective_date}} by and between LAZAR FAMILY BAKEHOUSE LLC ("LAZAR FAMILY BAKEHOUSE"), a Limited Liability Company under the law of Colorado and having its principal office at 4000 E. Quincy Ave. Englewood, CO 80113, and {{contractor_name}} (the "Contractor"), under the law of Colorado residing at {{contractor_address}}. In this Agreement, the party who is contracting to receive the services shall be referred to as "Lazar Family Bakehouse", and the party who will be providing the services shall be referred to as "Contractor."

## 1. DESCRIPTION OF CONTRACTOR SERVICES.
From time to time during the term of this Agreement, Contractor shall provide services and act on behalf of LAZAR FAMILY BAKEHOUSE in the execution of its Client relationship(s) ("Client") for the services requested and approved by Contractor as set forth in an applicable Statement of Work ("SOW").

Each SOW shall be drafted and executed in a format substantially similar to the initial SOW #1 included in Exhibit A. This Agreement and the exhibits attached hereto (collectively "Agreement") contain terms and conditions applicable to each SOW executed by the parties while this Agreement is in effect. SOW's become part of this Agreement upon approval by all parties; provided, however, that any provision of any SOW that is inconsistent with any provision herein shall be deemed superseded by this Agreement (collectively, the "Services").

Furthermore, the Contractor has the right of control over how the Contractor will perform the services set forth in each SOW. LAZAR FAMILY BAKEHOUSE does not have this right of control over how the Contractor will perform the services.

The Contractor will not need to provide any equipment or materials necessary to provide said services to LAZAR FAMILY BAKEHOUSE.

## 2. PAYMENT FOR SERVICES.
LAZAR FAMILY BAKEHOUSE and Contractor agree that any fees and expenses incurred and billed during the term of this Agreement shall be as set forth in the Fee Section included as part of each SOW incorporated into this Agreement.

NO OTHER FEES AND/OR EXPENSES WILL BE PAID TO THE CONTRACTOR, UNLESS SUCH FEES AND/OR EXPENSES HAVE BEEN APPROVED IN ADVANCE BY THE APPROPRIATE EXECUTIVE ON BEHALF OF LAZAR FAMILY BAKEHOUSE IN WRITING AND DOCUMENTED VIA EMAIL. THE CONTRACTOR SHALL BE SOLELY RESPONSIBLE FOR ANY AND ALL TAXES, SOCIAL SECURITY CONTRIBUTIONS OR PAYMENTS, DISABILITY INSURANCE, UNEMPLOYMENT TAXES, AND OTHER PAYROLL TYPE TAXES APPLICABLE TO SUCH COMPENSATION. THE CONTRACTOR HAS THE RIGHT OF CONTROL OVER THE METHOD OF PAYMENT FOR SERVICES.

## 3. TERM/TERMINATION.
This Agreement may be terminated by either party upon 30 days' written notice to the other party.

A regular, ongoing relationship of indefinite term is not contemplated. LAZAR FAMILY BAKEHOUSE has no right to assign services to the Contractor other than as specifically contemplated by this Agreement and specified and mutually agreed in each SOW. However, the parties may mutually agree that the Contractor shall perform other services for LAZAR FAMILY BAKEHOUSE, pursuant to the terms of this Agreement.

## 4. RELATIONSHIP OF PARTIES.
IT IS UNDERSTOOD BY THE PARTIES THAT THE CONTRACTOR IS AN INDEPENDENT CONTRACTOR WITH RESPECT TO LAZAR FAMILY BAKEHOUSE, AND NOT AN EMPLOYEE OF LAZAR FAMILY BAKEHOUSE. LAZAR FAMILY BAKEHOUSE WILL NOT PROVIDE FRINGE BENEFITS, INCLUDING HEALTH INSURANCE BENEFITS, PAID VACATION, OR ANY OTHER EMPLOYEE BENEFIT, FOR THE BENEFIT OF THE CONTRACTOR.

IT IS CONTEMPLATED THAT THE RELATIONSHIP BETWEEN THE CONTRACTOR AND LAZAR FAMILY BAKEHOUSE SHALL BE A NON-EXCLUSIVE ONE. THE CONTRACTOR ALSO PERFORMS SERVICES FOR OTHER ORGANIZATIONS AND/OR INDIVIDUALS. LAZAR FAMILY BAKEHOUSE HAS NO RIGHT TO FURTHER INQUIRE INTO THE CONTRACTOR'S OTHER ACTIVITIES.

## 5. LAZAR FAMILY BAKEHOUSE'S CONTROL.
LAZAR FAMILY BAKEHOUSE has no right or power to control or otherwise interfere with the Contractor's mode of affecting performance under this Agreement. LAZAR FAMILY BAKEHOUSE's concern is the process and result of the Contractor's work. In some circumstances and when necessary, the Contractor shall perform the Services without direct supervision by LAZAR FAMILY BAKEHOUSE.

## 6. PROFESSIONAL CAPACITY.
The Contractor is a professional who uses his or her own professional methods to perform services. The Contractor will receive instructions on how to perform actions related to LAZAR FAMILY BAKEHOUSE by the Company.

## 7. PERSONAL SERVICES NOT REQUIRED.
The Contractor is required to render the Services personally and may not employ others to perform the Services on behalf of LAZAR FAMILY BAKEHOUSE without LAZAR FAMILY BAKEHOUSE's knowledge or consent. If the Contractor has assistants, it is the Contractor's responsibility to hire them and to provide materials for them.

## 8. NO LOCATION ON PREMISES.
The Contractor has no desk or other equipment either located at or furnished by LAZAR FAMILY BAKEHOUSE. Except to the extent that the Contractor works in a territory as defined by LAZAR FAMILY BAKEHOUSE, his or her services are not integrated into the mainstream of LAZAR FAMILY BAKEHOUSE's business.

## 9. NO SET WORK HOURS.
The Contractor has no set hours of work. There is no requirement that the Contractor work full time or otherwise account for work hours.

## 10. PRE-APPROVED EXPENSES PAID BY LAZAR FAMILY BAKEHOUSE.
The Contractor's pre-approved business and travel expenses solely related to this Agreement and the Services herein shall be paid by LAZAR FAMILY BAKEHOUSE. Such expenses shall be approved in writing by a LAZAR FAMILY BAKEHOUSE executive. Email shall be deemed an acceptable form of approval. Such expenses shall be reimbursed within 30 days after Contractor invoices LAZAR FAMILY BAKEHOUSE for such expenses. All expenses must include documented receipts and explanation for each expense.

## 11. OWNERSHIP OF SOCIAL MEDIA CONTACTS.
Any social media contacts, including "followers" or "friends," that are acquired through accounts (including, but not limited to email addresses, blogs, Twitter, Facebook, YouTube, or other social media networks) used or created on behalf of LAZAR FAMILY BAKEHOUSE are the property of LAZAR FAMILY BAKEHOUSE and/or its clients.

## 12. CONFIDENTIALITY.
Contractor may have had access to proprietary, private and/or otherwise confidential information ("Confidential Information") of LAZAR FAMILY BAKEHOUSE and its clients provided under specific non-disclosure agreements or in other means. Confidential Information shall mean all non-public information which constitutes, relates or refers to the operation of the business of LAZAR FAMILY BAKEHOUSE, including without limitation, all financial, investment, operational, personnel, sales, marketing, managerial, written/typed, and statistical information of LAZAR FAMILY BAKEHOUSE, and any and all trade secrets, customer lists, or pricing information of LAZAR FAMILY BAKEHOUSE. The nature of the information and the manner of disclosure are such that a reasonable person would understand it to be confidential. The Contractor will not at any time or in any manner, either directly or indirectly, use for the personal benefit of the Contractor, or divulge, disclose, or communicate in any manner any Confidential Information. The Contractor will protect such information and treat the Confidential Information as strictly confidential. This provision shall continue to be effective after the termination of this Agreement. Upon termination of this Agreement, the Contractor will return to LAZAR FAMILY BAKEHOUSE all Confidential Information, whether physical or electronic, and other items that were used, created, or controlled by the Contractor during the term of this Agreement.

This Agreement is in compliance with the Defend Trade Secrets Act and provides civil or criminal immunity to any individual for the disclosure of trade secrets: (i) made in confidence to a federal, state, or local government official, or to an attorney when the disclosure is to report suspected violations of the law; or (ii) in a complaint or other document filed in a lawsuit if made under seal.

## 13. OWNERSHIP OF WORK.
The parties intend that, to the extent the Services or a portion of the Services qualify as a "work made for hire," within the definition of Section 101 of the Copyright Act of the United States (17 U.S.C. § 101), it will be deemed a work made for hire.

If the Services do not qualify as work made for hire, and/or as otherwise necessary to ensure LAZAR FAMILY BAKEHOUSE's complete ownership of all rights, titles and interest in the Services, the Contractor shall transfer and assign to LAZAR FAMILY BAKEHOUSE and/or its Client(s) all rights, titles and interests throughout the world in and to any and all Services. This transfer and assignment includes, but is not limited to, the right to publish, distribute, make derivative works of, edit, alter or otherwise use the Services in any way LAZAR FAMILY BAKEHOUSE sees fit.

## 14. SOLICITING CLIENTS AFTER TERMINATION OF AGREEMENT.
For a period of one (1) year following the termination of your Agreement and your relationship with LAZAR FAMILY BAKEHOUSE, Contractor shall not, directly or indirectly, disclose to any person, firm or corporation the names or addresses of any of the customers or Clients of LAZAR FAMILY BAKEHOUSE or any other information pertaining to them. Neither shall you call on, solicit, take away, or attempt to call on, solicit, or take away any Client of the Company on whom Contractor has called or with whom Contractor has become acquainted during the term of your Agreement, as the direct or indirect result of your Agreement with LAZAR FAMILY BAKEHOUSE.

## 15. INJURIES.
The Contractor acknowledges the Contractor's obligation to obtain appropriate insurance coverage for the benefit of the Contractor (and the Contractor's employees, if any). The Contractor waives any rights to recovery from LAZAR FAMILY BAKEHOUSE for any injuries that the Contractor (and/or Contractor's employees) may sustain while performing services under this Agreement and that are a result of the negligence of the Contractor or the Contractor's employees. Contractor will provide LAZAR FAMILY BAKEHOUSE with a certificate naming LAZAR FAMILY BAKEHOUSE as an additional insured party.

## 16. INDEMNIFICATION.
The Contractor agrees to indemnify and hold harmless LAZAR FAMILY BAKEHOUSE from all claims, losses, expenses, fees including attorney fees, costs, and judgments that may be asserted against LAZAR FAMILY BAKEHOUSE that result from the acts or omissions of the Contractor, the Contractor's employees, if any, and the Contractor's agents.

## 17. NO RIGHT TO ACT AS AGENT.
An "employer-employee" or "principal-agent" relationship is not created merely because (1) LAZAR FAMILY BAKEHOUSE has or retains the right to supervise or inspect the work as it progresses in order to ensure compliance with the terms of the contract or (2) LAZAR FAMILY BAKEHOUSE has or retains the right to stop work done improperly. The Contractor has no right to act as an agent for LAZAR FAMILY BAKEHOUSE and has an obligation to notify any involved parties that it is not an agent of LAZAR FAMILY BAKEHOUSE.

## 18. ENTIRE AGREEMENT.
This Agreement constitutes the entire contract between the parties. All terms and conditions contained in any other writings previously executed by the parties regarding the matters contemplated herein shall be deemed to be merged herein and superseded hereby. No modification of this Agreement shall be deemed effective unless in writing and signed by the parties hereto.

## 19. WAIVER OF BREACH.
The waiver by LAZAR FAMILY BAKEHOUSE of a breach of any provision of this Agreement by Contractor shall not operate or be construed as a waiver of any subsequent breach by Contractor.

## 20. SEVERABILITY.
If any provision of this Agreement shall be held to be invalid or unenforceable for any reason, the remaining provisions shall continue to be valid and enforceable. If a court finds that any provision of this Agreement is invalid or unenforceable, but that by limiting such provision it would become valid and enforceable, then such provision shall be deemed to be written, construed, and enforced as so limited.

## 21. APPLICABLE LAW.
This Agreement shall be governed by the laws of the State of Colorado.

## 22. ELECTRONIC SIGNATURES.
The parties agree that this Agreement and any SOW may be executed by electronic signature, and that electronic signatures and electronic records have the same legal effect as handwritten signatures and paper records under the federal Electronic Signatures in Global and National Commerce Act and the Colorado Uniform Electronic Transactions Act. Either party may request a paper copy of this Agreement at any time.

## 23. SIGNATORIES.
This Agreement shall be signed by {{company_signer}}, {{company_title}} on behalf of LAZAR FAMILY BAKEHOUSE LLC and by Contractor. This Agreement is effective as of the date first above written.

# EXHIBIT A
# STATEMENT OF WORK #1

Beginning on {{effective_date}}, the Contractor will provide the following services incorporated herein and act on behalf of LAZAR FAMILY BAKEHOUSE in the execution of its Client relationship ("Client"). This Statement of Work (SOW), once executed between the parties, shall evidence the Services to be provided hereunder pursuant to the terms and conditions of the Independent Contractor Agreement dated {{effective_date}} (the "Agreement"). Moreover, on execution, this Statement of Work shall be fully incorporated into the Agreement and become part of the Agreement between the parties.

For LAZAR FAMILY BAKEHOUSE as agreed:

## 1. Baking & Related Functions:
A. Weighing, Mixing, Forming, and Baking: The Contractor will be responsible for accurately weighing ingredients, operating the mixer and related equipment, forming the dough, and baking the product. They will monitor the baking process closely and handle the product with care to ensure quality and safety.

B. Slicing of Product: The Contractor shall precisely slice the baked product, maintaining portion consistency according to company standards.

C. Dishwashing: The Contractor may assist with washing dishes, baking tools, and utensils, ensuring all equipment is cleaned and sanitized following industry guidelines.

D. Cleanliness Standards: The Contractor is expected to maintain an organized, safe, and hygienic work environment at all times. All jewelry, including bracelets, necklaces, and earrings, must be removed during the baking process. If the Contractor has facial hair, it must either be fully removed or completely covered with a beard net while working. Fingernails must be kept clean and neatly trimmed at all times. Longer hair must be tied up. A hat/hair net must be worn.

## 2. Packaging Functions:
A. Package Assembly: The Contractor shall be responsible for the accurate and efficient assembly of packages. This includes correct product placement, labeling, and ensuring all packaging materials meet company standards for quality and presentation.

B. Shipping and Shipment Preparation: The Contractor may assist in preparing packages for shipment by labeling and organizing completed packages. However, the Contractor will not be responsible for coordinating with shipping carriers or managing the actual shipping process.

## 3. Additional Tasks:
A. Additional Agreed-Upon Duties: If the Contractor expresses interest in taking on additional responsibilities, and LAZAR FAMILY BAKEHOUSE approves, the Contractor may assume these tasks as mutually agreed upon.

## 4. Compensation:
LAZAR FAMILY BAKEHOUSE agrees to compensate the Contractor for services performed at a rate of {{pay_rate}} per hour. The Contractor's hours will be recorded by LAZAR FAMILY BAKEHOUSE through a time in/time out sheet. Any adjustments to the compensation rate will be made based on the following conditions:

A. Management and Oversight of Baking Operations: If the Contractor assumes responsibility for managing the baking process or overseeing other contractors/employees, reflecting additional managerial duties and leadership responsibilities.

B. Additional Coverage During CEO's Absence: If the CEO is traveling or unavailable, the Contractor may be required to take on additional responsibilities or coverage during this period, based on the Company's operational needs.

Payments will be made as follows: At the completion of each baking session or deliverable as agreed between the parties in writing, Contractor shall invoice LAZAR FAMILY BAKEHOUSE for the services rendered. Upon invoice, LAZAR FAMILY BAKEHOUSE will pay Contractor within 15 days of receipt unless a specific Client has alternative payment arrangements extending this timeframe longer. In such cases, LAZAR FAMILY BAKEHOUSE shall notify the Contractor of such circumstances. For the avoidance of doubt, LAZAR FAMILY BAKEHOUSE's intention is to pay the Contractor in a timely manner upon invoice.

NO OTHER FEES AND/OR EXPENSES WILL BE PAID TO THE CONTRACTOR, UNLESS SUCH FEES AND/OR EXPENSES HAVE BEEN APPROVED IN ADVANCE BY THE APPROPRIATE EXECUTIVE ON BEHALF OF LAZAR FAMILY BAKEHOUSE IN WRITING AND DOCUMENTED VIA EMAIL. THE CONTRACTOR SHALL BE SOLELY RESPONSIBLE FOR ANY AND ALL TAXES, SOCIAL SECURITY CONTRIBUTIONS OR PAYMENTS, DISABILITY INSURANCE, UNEMPLOYMENT TAXES, AND OTHER PAYROLL TYPE TAXES APPLICABLE TO SUCH COMPENSATION. THE CONTRACTOR HAS THE RIGHT OF CONTROL OVER THE METHOD OF PAYMENT FOR SERVICES.
$TPL$, true
where not exists (select 1 from public.c_contract_templates where name = 'Independent Contractor Agreement');

commit;

-- Verify:
--   select name, version, length(body) from c_contract_templates;
